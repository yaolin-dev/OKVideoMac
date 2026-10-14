import AppKit
import SwiftUI
import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlaybackInformationNativeTests: XCTestCase {
    private var nativeDiagnostics: (() -> String)?
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PlaybackInformationNativeTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Playback information did not reach the expected state at line \(line); \(nativeDiagnostics?() ?? "")"])
    }

    private final class SurfaceMount: ObservableObject {
        @Published var mounted = true
        var readyCount = 0
        var unavailableCount = 0
    }
    private struct HostedSurface: View {
        @ObservedObject var mount: SurfaceMount
        let player: MPVPlayerClient
        var body: some View {
            ZStack {
                Color.black
                if mount.mounted {
                    MPVRenderView(player: player, onError: { XCTFail($0.localizedDescription) },
                        onSurfaceReady: { _ in mount.readyCount += 1 },
                        onSurfaceUnavailable: { _ in mount.unavailableCount += 1 })
                        .id(player.renderOwnerID).ignoresSafeArea()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    func testHostedSurfaceRemountReleasesNextMediaWithoutWindowResize() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OKVIDEO_MEDIA_INFO_FIXTURES"],
              let network = ProcessInfo.processInfo.environment["OKVIDEO_MEDIA_INFO_HTTP"] else {
            throw XCTSkip("Requires the explicit local/network playback-information fixture gate")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, renderControlMode: .advanced,
            audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        let mount = SurfaceMount()
        let host = NSHostingView(rootView: HostedSurface(mount: mount, player: player))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = NSView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        container.wantsLayer = true
        host.frame = container.bounds; host.autoresizingMask = [.width, .height]
        container.addSubview(host); window.contentView = container
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        var latest = PlayerSnapshot()
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event { latest = snapshot }
            }
        }
        nativeDiagnostics = {
            func surfaces(_ view: NSView) -> [MPVOpenGLView] {
                (view as? MPVOpenGLView).map { [$0] } ?? view.subviews.flatMap(surfaces)
            }
            return "active=\(NSApp.isActive) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) frame=\(window.frame) host=\(host.bounds) ready=\(mount.readyCount) unavailable=\(mount.unavailableCount) surfaces=\(surfaces(host).map { "\($0.readinessDiagnosticsForTesting) attached=\($0.window != nil) sameWindow=\($0.window === window) superview=\($0.superview != nil) mini=\($0.window?.isMiniaturized == true) backing=\($0.convertToBacking($0.bounds))" })"
        }
        do {
            try await waitUntil { mount.readyCount == 1 }
            try await player.load(ResolvedMedia(url: URL(fileURLWithPath: directory).appendingPathComponent("fixture-A.mp4"),
                headers: [:], siteKey: "info-fixture", sourceName: "A", episodeName: "A"), startPosition: nil, requestID: UUID())
            try await waitUntil { latest.mediaInfo?.width == 640 }
            let originalFrame = window.frame
            for cycle in 1...3 {
                mount.mounted = false
                try await waitUntil { mount.unavailableCount == cycle }
                mount.mounted = true
                await player.stop()
                try await waitUntil({ mount.readyCount == cycle + 1 }, timeout: 3)
                XCTAssertEqual(window.frame, originalFrame, "Readiness must not require moving or resizing the user's window")
                try await player.load(ResolvedMedia(url: URL(string: network + "/fixture-B.mp4")!, headers: [:],
                    siteKey: "info-fixture", sourceName: "B", episodeName: "B"), startPosition: nil, requestID: UUID())
                try await waitUntil { latest.mediaInfo?.width == 1280 && latest.mediaInfo?.videoCodec == "hevc" }
            }
            reader.cancel(); window.close(); await player.shutdown()
        } catch {
            reader.cancel(); window.close(); await player.shutdown(); throw error
        }
    }

    func testBundledMPVLocalNetworkAudioReplacementAndHiddenPolling() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OKVIDEO_MEDIA_INFO_FIXTURES"],
              let network = ProcessInfo.processInfo.environment["OKVIDEO_MEDIA_INFO_HTTP"] else {
            throw XCTSkip("Requires the explicit local/network playback-information fixture gate")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        var ready = false, latest = PlayerSnapshot()
        var samples: [(PlayerSnapshot, UUID?)] = []
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, let owner) = event { latest = snapshot; samples.append((snapshot, owner)) }
            }
        }
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) },
            onSurfaceReady: { _ in ready = true }, onSurfaceUnavailable: { _ in })
        window.contentView = surface
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        nativeDiagnostics = {
            "active=\(NSApp.isActive) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) frame=\(window.frame) surface=\(surface.bounds) attached=\(surface.window != nil) sameWindow=\(surface.window === window) superview=\(surface.superview != nil) mini=\(surface.window?.isMiniaturized == true) backing=\(surface.convertToBacking(surface.bounds)) \(surface.readinessDiagnosticsForTesting)"
        }
        do {
            try await waitUntil { ready }
            let a = UUID()
            try await player.load(ResolvedMedia(url: URL(fileURLWithPath: directory).appendingPathComponent("fixture-A.mp4"),
                headers: [:], siteKey: "info-fixture", sourceName: "A", episodeName: "A"), startPosition: nil, requestID: a)
            try await waitUntil { latest.mediaInfo?.width == 640 && latest.mediaInfo?.audioCodec == "aac" }
            XCTAssertEqual(latest.mediaInfo?.height, 360)
            XCTAssertEqual(latest.mediaInfo?.videoCodec, "h264")
            let aFPS = Double(await player.diagnosticPropertyForTesting("current-tracks/video/demux-fps") ?? "")
            XCTAssertNotNil(aFPS)
            XCTAssertEqual(latest.mediaInfo?.nominalFrameRate, aFPS, "Preserve the actual metadata value instead of rounding it to the fixture generator setting")
            XCTAssertEqual(latest.mediaInfo?.nominalFrameRate ?? 0, 24, accuracy: 0.05)
            XCTAssertNotNil(latest.mediaInfo?.fileSizeBytes)
            XCTAssertNil(latest.mediaInfo?.statistics)
            player.setMediaInfoVisible(true)
            try await waitUntil { latest.mediaInfo?.statistics?.videoBitrate != nil }
            XCTAssertGreaterThan(latest.mediaInfo?.statistics?.videoBitrate ?? 0, 0)
            XCTAssertNil(latest.mediaInfo?.statistics?.networkBytesPerSecond)
            try await player.setAspectRatio("4:3")
            try await waitUntil { latest.videoHeight > 0 && abs(Double(latest.videoWidth) / Double(latest.videoHeight) - 4.0/3.0) < 0.01 }
            XCTAssertNotEqual(latest.videoHeight, 360, "The fixture must actually exercise a display aspect change")
            XCTAssertEqual(latest.mediaInfo?.width, 640, "Aspect override must not change source dimensions")
            try await player.setAspectRatio(nil)
            player.setMediaInfoVisible(false)
            try await waitUntil { latest.mediaInfo?.statistics == nil }
            try await Task.sleep(nanoseconds: 200_000_000)
            let before = await player.mediaInfoRefreshCountForTesting()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let after = await player.mediaInfoRefreshCountForTesting()
            XCTAssertEqual(before, after, "Closing the inspector must remove its polling loop")

            let b = UUID()
            try await player.load(ResolvedMedia(url: URL(string: network + "/fixture-B.mp4?token=PRIVATE_TEST_TOKEN")!,
                headers: [:], siteKey: "info-fixture", sourceName: "B", episodeName: "B"), startPosition: nil, requestID: b)
            try await waitUntil { latest.mediaInfo?.width == 1280 && latest.mediaInfo?.videoCodec == "hevc" && latest.mediaInfo?.audioSampleRate == 48_000 }
            XCTAssertEqual(latest.mediaInfo?.height, 720)
            XCTAssertEqual(latest.mediaInfo?.audioSampleRate, 48_000)
            let bFPS = Double(await player.diagnosticPropertyForTesting("current-tracks/video/demux-fps") ?? "")
            XCTAssertEqual(latest.mediaInfo?.nominalFrameRate, bFPS)
            XCTAssertEqual(latest.mediaInfo?.nominalFrameRate ?? 0, 30, accuracy: 0.05)
            XCTAssertTrue(samples.contains { $0.1 == b && $0.0.status == .loading && $0.0.mediaInfo == nil })
            XCTAssertFalse(samples.contains { $0.1 == b && $0.0.mediaInfo?.width == 640 }, "No old technical data may acquire the new request owner")
            XCTAssertEqual(latest.mediaInfo?.fileName, "fixture-B.mp4")
            player.setMediaInfoVisible(true)
            try await waitUntil { latest.mediaInfo?.statistics?.networkBytesPerSecond != nil }

            let c = UUID()
            try await player.load(ResolvedMedia(url: URL(fileURLWithPath: directory).appendingPathComponent("fixture-audio.wav"),
                headers: [:], siteKey: "info-fixture", sourceName: "Audio", episodeName: "Audio"), startPosition: nil, requestID: c)
            try await waitUntil { latest.mediaInfo?.audioCodec == "pcm_s16le" }
            XCTAssertNil(latest.mediaInfo?.width); XCTAssertNil(latest.mediaInfo?.height); XCTAssertNil(latest.mediaInfo?.videoCodec)
            XCTAssertFalse(samples.contains { $0.1 == c && $0.0.mediaInfo?.videoCodec != nil })
            await player.stop()
            try await waitUntil { latest.status == .stopped && latest.mediaInfo == nil }
            reader.cancel(); surface.tearDown(); window.close(); await player.shutdown()
        } catch {
            reader.cancel(); surface.tearDown(); window.close(); await player.shutdown(); throw error
        }
    }
}

@MainActor final class PlaybackInformationPresentationTests: XCTestCase {
    private func info(width: Int = 1920, codec: String = "hevc", statistics: Bool = true) -> PlaybackMediaInfo {
        PlaybackMediaInfo(properties: ["filename": "https://user:PRIVATE_PASSWORD@example.invalid/private/movie.mp4?token=PRIVATE_TOKEN",
            "video-dec-params/w": String(width), "video-dec-params/h": "1080", "current-tracks/video/codec": codec,
            "container-fps": "23.976", "video-bitrate": "8000000", "cache-speed": "2000000",
            "current-tracks/audio/codec": "aac", "audio-params/channels": "stereo", "audio-params/samplerate": "48000"],
            includeStatistics: statistics, isNetwork: true)
    }
    private func key(configuration: UUID = UUID(), source: String = "A", episode: String = "1", revision: Date = Date(timeIntervalSince1970: 0)) -> PlaybackMediaInfoCache.Key {
        .init(configurationID: configuration, configurationUpdatedAt: revision, videoID: "site::movie", sourceID: source, episodeID: episode)
    }
    func testCopyUsesCorrectBitAndByteUnitsWithoutCredentialsOrPaths() {
        let text = PlaybackInfoPresentation.copyText(info: info(), originalName: "/Users/private/movie.mp4", duration: 3601, selectedTrack: nil)
        XCTAssertTrue(text.contains("8.00 Mb/s")); XCTAssertTrue(text.contains("2.00 MB/s"))
        XCTAssertTrue(text.contains("1920 × 1080")); XCTAssertTrue(text.contains("23.976 fps"))
        for secret in ["PRIVATE_PASSWORD", "PRIVATE_TOKEN", "/Users/", "/private/", "https://", "example.invalid"] { XCTAssertFalse(text.contains(secret)) }
        let pasteboard = NSPasteboard(name: .init("PlaybackInfo-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        PlaybackInfoPresentation.copy(text, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
    }
    func testUnknownAndAudioOnlyNeverInventVideoStatistics() {
        XCTAssertNil(PlaybackInfoPresentation.summary(nil))
        let audio = PlaybackMediaInfo(properties: ["current-tracks/audio/codec":"aac","audio-params/samplerate":"44100"])
        XCTAssertTrue(PlaybackInfoPresentation.videoRows(audio).isEmpty)
        XCTAssertFalse(PlaybackInfoPresentation.summary(audio)!.contains("1080"))
        XCTAssertTrue(PlaybackInfoPresentation.statisticRows(audio).allSatisfy { $0.value == nil })
        XCTAssertEqual(PlaybackInfoPresentation.frameRate(30), "30 fps")
        XCTAssertEqual(PlaybackInfoPresentation.frameRate(100), "100 fps")
    }
    func testSummaryCannotBleedAcrossConfigurationRevisionSourceOrEpisode() {
        let cache = PlaybackMediaInfoCache(), configuration = UUID()
        let a = key(configuration: configuration)
        cache.store(info(), for: a)
        XCTAssertNotNil(cache.info(for: a)); XCTAssertNil(cache.info(for: a)?.statistics)
        for other in [key(), key(configuration: configuration, source: "B"), key(configuration: configuration, episode: "2"),
                      key(configuration: configuration, revision: Date(timeIntervalSince1970: 1))] { XCTAssertNil(cache.info(for: other)) }
        cache.store(info(width: 1280, codec: "h264"), for: a)
        XCTAssertEqual(cache.info(for: a)?.width, 1280)
        XCTAssertEqual(cache.info(for: a)?.videoCodec, "h264")
    }
    func testSessionCacheIsBoundedAndIgnoresUnavailableSpecifications() {
        let cache = PlaybackMediaInfoCache(), configuration = UUID(), first = key(configuration: configuration, episode: "0")
        cache.store(info(), for: first)
        for i in 1...100 { cache.store(info(), for: key(configuration: configuration, episode: String(i))) }
        XCTAssertNil(cache.info(for: first))
        let unknown = key(configuration: configuration, episode: "unknown")
        cache.store(PlaybackMediaInfo(properties: [:]), for: unknown)
        XCTAssertNil(cache.info(for: unknown))
    }
    func testProductionInformationPanelRendersKnownAndUnknownValues() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-PlaybackInfo/Renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in [("known", Optional(info())), ("unknown", nil)] {
            let host = NSHostingView(rootView: ZStack {
                Color(white: 0.08)
                PlaybackInformationPanel(info: data, originalName: data == nil ? nil : "movie.mp4", duration: data == nil ? 0 : 3601,
                    selectedAudioTrack: nil).padding(16)
            }.environment(\.colorScheme, .dark))
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 420, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.setContentSize(.init(width: 420, height: 520))
            try await Task.sleep(nanoseconds: 120_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("info-\(name).png"))
            XCTAssertEqual(host.bounds.width, 420); XCTAssertEqual(host.bounds.height, 520)
            window.close()
        }
    }
}
