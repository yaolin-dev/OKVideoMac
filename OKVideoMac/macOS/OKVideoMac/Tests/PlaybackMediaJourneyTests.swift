import AppKit
import SwiftUI
import QuartzCore
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

/// Uses the real resolver, AppState, libmpv/render surface and isolated SQLite.
/// Only the content provider and HTTP server are deterministic local fixtures.
@MainActor final class PlaybackMediaJourneyTests: XCTestCase {
    private struct Surface: View {
        @ObservedObject var state: AppState
        var body: some View {
            ZStack {
                Color.black
                if state.isPlayerPresented, state.isPlayerRenderSurfaceMountEnabled, let player = state.embeddedPlayer {
                    MPVRenderView(player: player, onError: { state.reportPlayerRenderError($0) },
                        onSurfaceReady: { state.playerRenderSurfaceDidBecomeReady($0) },
                        onSurfaceUnavailable: { state.playerRenderSurfaceDidBecomeUnavailable($0) },
                        pictureInPicture: state.pictureInPicture).id(player.renderOwnerID)
                }
                PlayerView(playerSnapshotState: state.playerSnapshotState, onWindowChromeRestored: {}).environmentObject(state)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // The isolated window does not own the app scene's menu bar.
                // Mount its production command to test the same Space binding.
                PlaybackPlayPauseCommand(state: state)
                    .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
            }
        }
    }
    private struct Provider: SiteProvider {
        let site = SiteConfiguration(key: "media-journey", name: "Local media fixture", type: 1, api: "http://127.0.0.1")
        let capability: SiteCapability = .standardJSON
        func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
        func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { VideoPage(items: [], pagination: Pagination(page: 1, pageCount: 1)) }
        func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: keyword, page: page, filters: [:]) }
        func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused fixture detail") }
        func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
            SitePlaybackResult(url: episodeURL, needsParsing: false, flag: flag,
                validationPolicy: .playerAuthoritative)
        }
    }
    private func wait(_ label: String, seconds: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw NSError(domain: "MediaJourney", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
    private func fixture() async throws -> (AppState, AppEnvironment, NSWindow, String) {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OKVIDEO_JOURNEY_HTTP"])
        XCTAssertTrue(base.hasPrefix("http://127.0.0.1:"))
        let environment = try AppEnvironment.live(), state = AppState(environment: environment)
        let record = StoredConfiguration(name: "Media journey", sourceKind: .pasted, rawData: Data("{}".utf8))
        state.seedCategoryHomeForTesting(record: record, provider: Provider(), home: SiteHome(categories: [], recommendations: []))
        state.startPlaybackEventsForTesting()
        await state.setPlayerVolume(0)
        let host = NSHostingView(rootView: Surface(state: state))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 540), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.setActivationPolicy(.regular); NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        state.setPlayerWindowKey(true)
        for _ in 0..<60 where !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        guard window.isKeyWindow else {
            let detail = "Native window prerequisite: active=\(NSApp.isActive), hidden=\(NSApp.isHidden), visible=\(window.isVisible), canKey=\(window.canBecomeKey), modal=\(NSApp.modalWindow != nil)"
            await state.shutdown(); window.contentView = nil; window.close()
            throw NSError(domain: "MediaJourneyDesktop", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return (state, environment, window, base)
    }
    private func content(_ base: String, prefix: String = "") -> (VideoDetail, PlaySource) {
        let source = PlaySource(name: "Fixture", episodes: (1...3).map {
            PlayEpisode(name: "E\($0).mp3", url: base + prefix + "/seek/manifest.mpd?episode=\($0)")
        })
        return (VideoDetail(summary: VideoSummary(siteKey: "media-journey", siteName: "Fixture", videoID: "journey", title: "Journey", categoryName: "电视剧"), playSources: [source]), source)
    }
    private func cleanup(_ state: AppState, _ environment: AppEnvironment, _ window: NSWindow) async {
        await state.closePlayer(); await state.shutdown()
        window.contentView = nil; window.close()
    }
    func testPlaySeekPauseCloseResumeAndNextEpisode() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            let (detail, source) = content(base)
            await state.startPlayback(detail: detail, source: source, episode: source.episodes[0])
            try await wait("First frame and decoded video") { state.hasCurrentPlaybackStarted && state.playerSnapshot.position > 0.3 && state.hasNextEpisode }
            await state.seek(to: 30)
            try await wait("Seek reaches requested position") { !state.playerSnapshot.isSeeking && state.playerSnapshot.position >= 29 }
            // Exercise the production floating button with a real pointer event.
            // At this viewport the transport is centered on the single control row.
            let layout = PlayerOverlayLayout(viewportSize: window.contentView!.bounds.size)
            let point = NSPoint(x: window.contentView!.bounds.midX, y: layout.bottomInset + 9 + 30)
            for (type, offset) in [(NSEvent.EventType.mouseMoved, 0.0), (.leftMouseDown, 0.01), (.leftMouseUp, 0.06)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + offset, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            try await wait("Pause is confirmed by the native player") {
                state.playerSnapshot.status == .paused && state.playbackDiagnosticRecordsForTesting.last?.events.last?.stage == .paused
            }
            await state.closePlayer()
            XCTAssertFalse(state.isPlayerPresented)
            let trace = try XCTUnwrap(state.playbackDiagnosticRecordsForTesting.last)
            let stages = trace.events.map(\.stage)
            for stage: PlaybackDiagnostics.Stage in [.requested, .resolving, .resolved, .loading, .fileLoaded, .firstFrame, .paused, .closed] {
                XCTAssertTrue(stages.contains(stage), "Missing actual playback stage: \(stage)")
            }
            XCTAssertTrue(trace.finished)
            let history = try await environment.database.history()
            XCTAssertTrue(history.contains { $0.position >= 29 })
            await state.startPlayback(detail: detail, source: source, episode: source.episodes[0])
            try await wait("Resume uses persisted progress") { state.playerSnapshot.status == .playing && state.playerSnapshot.position >= 29 }
            await state.playAdjacentEpisode(offset: 1)
            try await wait("Next episode decodes") { state.currentPlayerEpisodeID == source.episodes[1].id && state.hasCurrentPlaybackStarted }
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }
    func testHTTPFailureThenRetryAndSlowReplacement() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            let (bad, badSource) = content(base, prefix: "/recoverable")
            await state.startPlayback(detail: bad, source: badSource, episode: badSource.episodes[0])
            XCTAssertFalse(state.hasCurrentPlaybackStarted)
            var request = URLRequest(url: URL(string: base + "/control/recover")!); request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
            await state.retryCurrentPlayback()
            try await wait("Retry reaches a decoded frame") { state.hasCurrentPlaybackStarted }
            let retryTrace = try XCTUnwrap(state.playbackDiagnosticRecordsForTesting.last)
            XCTAssertTrue(retryTrace.events.contains { $0.stage == .failed })
            XCTAssertTrue(retryTrace.events.contains { $0.stage == .retry && $0.retry == .user })
            XCTAssertTrue(retryTrace.events.contains { $0.stage == .firstFrame })
            let (slow, slowSource) = content(base, prefix: "/slow")
            let old = Task { await state.startPlayback(detail: slow, source: slowSource, episode: slowSource.episodes[0]) }
            try await wait("Slow request entered the player") { state.currentPlayerEpisodeID == slowSource.episodes[0].id }
            var slowRequestReachedServer = false
            for _ in 0..<100 {
                let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/control/status")!)
                let status = try JSONDecoder().decode([String: Int].self, from: data)
                if (status["slowRequests"] ?? 0) > 0 { slowRequestReachedServer = true; break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertTrue(slowRequestReachedServer, "Replace only after the old request is blocked in real HTTP")
            let (good, goodSource) = content(base)
            await state.startPlayback(detail: good, source: goodSource, episode: goodSource.episodes[2])
            await old.value
            try await wait("Replacement keeps playing") { state.currentPlayerEpisodeID == goodSource.episodes[2].id && state.hasCurrentPlaybackStarted }
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }
    func testRepeatedRealOpenSeekAndCloseReleasesNativePlayer() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            let (detail, source) = content(base)
            for index in 0..<10 {
                await state.startPlayback(detail: detail, source: source, episode: source.episodes[index % 3])
                try await wait("Round \(index) starts") { state.hasCurrentPlaybackStarted }
                await state.seek(to: TimeInterval(10 + index))
                try await wait("Round \(index) seek") { !state.playerSnapshot.isSeeking && state.playerSnapshot.position >= Double(9 + index) }
                await state.closePlayer()
                XCTAssertNil(state.embeddedPlayer, "Ordinary source must release the native client")
                XCTAssertFalse(state.isPlayerPresented)
            }
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }
    func testOrdinaryLiveNativeButtonAndCatchupLayout() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            let stored = StoredLiveSource(name: "Local live", sourceKind: .pasted, rawData: Data())
            let channel = LiveChannel(groupName: "Fixture", name: "Local channel", streams: [LiveStream(name: "Local",
                url: URL(string: base + "/seek/manifest.mpd")!,
                catchup: .init(mode: "append", template: "?start={utc}&end={utcend}", retentionDays: 7, seekPolicy: .request))])
            state.acceptImportedRoutesForTesting(stored, playlist: .init(format: .m3u, groups: [.init(name: "Fixture", channels: [channel])]))
            let catalog = try XCTUnwrap(state.acceptedImportedCatalogs[stored.id])
            let selection = try XCTUnwrap(catalog.selections(for: channel).first)
            await state.playImportedLive(selection, navigationChannels: [channel])
            try await wait("Live first frame") { state.hasCurrentPlaybackStarted }
            let host = try XCTUnwrap(window.contentView)
            func button() -> NSButton? {
                BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSButton }
                    .first { $0.accessibilityIdentifier() == "player.live.playPause" }
            }
            for width in [640.0, 900.0, 1400.0] {
                window.setContentSize(.init(width: width, height: width * 9 / 16))
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                let control = try XCTUnwrap(button())
                let rect = control.convert(control.bounds, to: host)
                XCTAssertGreaterThanOrEqual(rect.width, 36)
                XCTAssertGreaterThanOrEqual(rect.height, 36)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThan(rect.maxX, host.bounds.midX)
                XCTAssertTrue(control.showsBorderOnlyWhileMouseInside)
                XCTAssertEqual(control.toolTip, L10n.string("common.pause", fallback: "Pause"))
                if width == 900 {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "live-controls-left"; attachment.lifetime = .keepAlways; add(attachment)
                    try png.write(to: URL(fileURLWithPath: "/private/tmp/OKVideoMac-live-controls-left.png"))
                }
            }
            let control = try XCTUnwrap(button())
            let point = control.convert(.init(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: time + offset, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            try await wait("Native live button pauses playback") { state.playerSnapshot.status == .paused }
            try await wait("Paused button title updates") { button()?.toolTip == L10n.string("common.play", fallback: "Play") }
            let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            NSApp.postEvent(space, atStart: false)
            try await wait("Space resumes live playback") { state.playerSnapshot.status == .playing }
            let programme = EPGProgramme(channelID: channel.id, title: "Local catchup",
                start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600))
            await state.playImportedCatchup(selection, programme: programme, navigationChannels: [channel])
            try await wait("Catchup first frame") { state.hasCurrentPlaybackStarted }
            XCTAssertFalse(state.isLivePlayback)
            try await wait("Catchup keeps the existing transport layout") { button() == nil }
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }


    @discardableResult
    private func captureTimeline(_ window: NSWindow, expectedFraction: Double, name: String,
                                 assertPosition: Bool = true) throws -> Bool {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
        let track = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).first { $0 is ProgressHoverTrackingNSView })
        let rect = track.convert(track.bounds, to: host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: "/private/tmp/seek165-timeline-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        var blueMaxX: Int?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.blueComponent > 0.6, c.blueComponent > c.redComponent * 1.5,
                   c.greenComponent > c.redComponent * 1.3 {
                    blueMaxX = max(blueMaxX ?? 0, x)
                }
            }
        }
        let edge = try XCTUnwrap(blueMaxX, "Blue timeline must be visibly rendered")
        let scale = Double(bitmap.pixelsWide) / rect.width
        let expected = (6 + (rect.width - 12) * expectedFraction) * scale
        let matches = abs(Double(edge) - expected) < 10 * scale
        if assertPosition {
            XCTAssertTrue(matches,
                          "Rendered track must stay at released pointer: \(name), edge=\(edge), expected=\(expected)")
        }
        print("SEEK_PIXELS \(name) blueEdge=\(edge) expected=\(expected)")
        return matches
    }

    private func captureCompletedTimeline(_ window: NSWindow, expectedFraction: Double, name: String) async throws {
        // Model delivery and SwiftUI display occur on separate run-loop turns.
        // Wait only for completed-state rendering, preserving the exact pixel
        // tolerance and the synchronous pending-target checks above.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while !(try captureTimeline(window, expectedFraction: expectedFraction, name: name, assertPosition: false)) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Completed native position was not rendered within 250 ms: \(name)")
                return
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func drag(_ window: NSWindow, from: Double, to: Double) async throws {
        let host = try XCTUnwrap(window.contentView)
        let track = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).first { $0 is ProgressHoverTrackingNSView })
        func point(_ fraction: Double) -> NSPoint {
            track.convert(.init(x: 6 + (track.bounds.width - 12) * fraction, y: track.bounds.midY), to: nil)
        }
        for (type, fraction) in [(NSEvent.EventType.mouseMoved, from), (.leftMouseDown, from),
                                  (.leftMouseDragged, to), (.leftMouseUp, to)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point(fraction), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func testRealMouseDragsHoldTargetAndMatchDecodedFrameAcrossFormats() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            for (index, path) in ["/legacy.mp4", "/hls/manifest.m3u8", "/seek/manifest.mpd"].enumerated() {
                let source = PlaySource(name: "Seek fixture", episodes: [.init(name: "E1.mp4", url: base + path)])
                let detail = VideoDetail(summary: .init(siteKey: "media-journey", siteName: "Fixture", videoID: "seek-\(index)", title: "Seek \(index)", categoryName: "电视剧"), playSources: [source])
                await state.startPlayback(detail: detail, source: source, episode: source.episodes[0])
                try await wait("Seek fixture starts") { state.hasCurrentPlaybackStarted && state.playerSnapshot.duration > 5 }
                await state.togglePlayPause()
                try await wait("Native paused") { state.playerSnapshot.status == .paused }
                for fraction in [0.72, 0.26] {
                    let previousID = state.playerSnapshotState.requestedSeek?.id
                    let expected = fraction * state.playerSnapshot.duration
                    // The MP4/HLS fixtures have independently verified 2-second
                    // keyframes; DASH retains its exact A/V alignment policy.
                    let decodedTarget = index == 2 ? expected : floor(expected / 2) * 2
                    let monitor = Task { @MainActor in
                        var frame = 0
                        while !Task.isCancelled {
                            let display = state.playerSnapshotState
                            if let request = display.requestedSeek, request.id != previousID {
                                if display.pendingSeekTarget != nil {
                                    XCTAssertEqual(display.displayedPosition, expected, accuracy: 0.12, "Native old samples must never pull the released thumb back")
                                    do {
                                        try captureTimeline(window, expectedFraction: fraction,
                                            name: "format\(index)-target\(Int(fraction * 100))-waiting\(frame)")
                                    } catch { XCTFail("Timeline capture: \(error)") }
                                    frame += 1
                                } else if request.phase == .completed {
                                    XCTAssertEqual(display.displayedPosition, display.snapshot.position)
                                    XCTAssertEqual(display.displayedPosition, decodedTarget, accuracy: 0.35)
                                }
                            }
                            try? await Task.sleep(nanoseconds: 16_000_000)
                        }
                    }
                    do {
                        try await drag(window, from: state.playerSnapshot.position / state.playerSnapshot.duration, to: fraction)
                        try await wait("Mouse release issued a new seek") { state.playerSnapshotState.requestedSeek?.id != previousID }
                        try await wait("Current native frame confirmed") { state.playerSnapshotState.requestedSeek?.phase == .completed }
                        monitor.cancel()
                    } catch { monitor.cancel(); throw error }
                    try await captureCompletedTimeline(window, expectedFraction: state.playerSnapshot.position / state.playerSnapshot.duration, name: "format\(index)-target\(Int(fraction * 100))-completed")
                    XCTAssertEqual(state.playerSnapshot.status, .paused)
                    XCTAssertEqual(state.playerSnapshot.position, decodedTarget, accuracy: 0.35)
                    let player = try XCTUnwrap(state.embeddedPlayer)
                    let frameTime = state.playerSnapshot.position
                    let screenshot = URL(fileURLWithPath: "/private/tmp/seek165-format\(index)-\(Int(fraction * 100)).png")
                    try await player.screenshot(to: screenshot)
                    let fixtures = try XCTUnwrap(ProcessInfo.processInfo.environment["OKVIDEO_JOURNEY_FIXTURES"])
                    let reference = URL(fileURLWithPath: fixtures).appendingPathComponent(index == 2 ? "seek/manifest-stream0.mp4" : "legacy.mp4")
                    print("SEEK_REFERENCE nativeTime=\(frameTime) screenshot=\(screenshot.lastPathComponent) reference=\(reference.path)")
                    let attachment = XCTAttachment(data: try Data(contentsOf: screenshot), uniformTypeIdentifier: "public.png")
                    attachment.name = "format\(index)-target\(expected)-videoPTS\(frameTime)"; attachment.lifetime = .keepAlways; add(attachment)
                    print("SEEK_FRAME format=\(index) target=\(expected) decoded=\(frameTime) display=\(state.playerSnapshotState.displayedPosition)")
                }
                await state.closePlayer()
            }
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }

    func testRapidExactSeeksAtTwoTimesSpeedAndCloseDoNotRestoreOldTargets() async throws {
        let (state, environment, window, base) = try await fixture()
        do {
            let (detail, source) = content(base)
            await state.startPlayback(detail: detail, source: source, episode: source.episodes[0])
            try await wait("Rapid fixture starts") { state.hasCurrentPlaybackStarted }
            try await environment.player.setSpeed(2)
            for target in [100.25, 40.125, 130.375, 130.375, 50.125] { await state.seek(to: target) }
            try await wait("Last operation owns exact playback") { state.playerSnapshotState.requestedSeek?.phase == .completed }
            XCTAssertEqual(state.playerSnapshotState.requestedSeek?.target, 50.125)
            XCTAssertLessThan(abs(state.playerSnapshot.position - 50.125), 0.6)
            XCTAssertNil(state.playerSnapshotState.pendingSeekTarget)
            await state.seek(to: 220)
            await state.closePlayer()
            XCTAssertNil(state.playerSnapshotState.requestedSeek)
            await state.startPlayback(detail: detail, source: source, episode: source.episodes[1])
            try await wait("Next file has its own timeline") { state.hasCurrentPlaybackStarted }
            XCTAssertNil(state.playerSnapshotState.requestedSeek)
            XCTAssertLessThan(state.playerSnapshot.position, 5)
            await cleanup(state, environment, window)
        } catch { await cleanup(state, environment, window); throw error }
    }

}
