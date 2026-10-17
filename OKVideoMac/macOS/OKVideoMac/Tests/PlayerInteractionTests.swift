import AppKit
import SwiftUI
import OKVideoCore
import OKVideoPersistence
import XCTest
@testable import OKVideoMac

@MainActor
final class PlayerProgressInteractionTests: XCTestCase {
    private final class PointerView: ProgressHoverTrackingNSView {
        var point: NSPoint?
        var active = true
        override var pointerInWindow: NSPoint? { point.map { convert($0, to: nil) } }
        override var isTrackingWindowActive: Bool { active }
    }

    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func fixture() -> (NSWindow, PointerView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PointerView(frame: NSRect(x: 0, y: 0, width: 212, height: 24))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    func testAllEdgesAndDragReleaseUseActualPointerInsteadOfStaleEvent() async {
        let (window, view) = fixture(); defer { view.detach(); window.close() }
        var latest: Double?
        view.configure(enabled: true, revision: 0) { latest = $0 }
        for outside in [NSPoint(x: -1, y: 12), NSPoint(x: 213, y: 12),
                        NSPoint(x: 106, y: -1), NSPoint(x: 106, y: 25)] {
            view.point = NSPoint(x: 106, y: 12); view.pointerDidMove(); await drain()
            XCTAssertEqual(latest, 0.5)
            view.point = outside; view.pointerDidMove(); await drain()
            XCTAssertNil(latest, "Leaving any edge, including drag release, clears preview")
        }
        view.point = NSPoint(x: 56, y: 12); view.pointerDidMove()
        view.point = NSPoint(x: 56, y: 50); view.pointerDidMove()
        await drain()
        XCTAssertNil(latest, "Queued entry must not resurrect a preview outside the track")
    }

    func testHiddenDisabledAndRebuiltTrackClearStationaryHover() async {
        let (window, view) = fixture(); defer { view.detach(); window.close() }
        var latest: Double?
        view.configure(enabled: true, revision: 0) { latest = $0 }
        view.point = NSPoint(x: 106, y: 12); view.pointerDidMove(); await drain()
        XCTAssertEqual(latest, 0.5)
        view.configure(enabled: false, revision: 0) { latest = $0 }; await drain()
        XCTAssertNil(latest)
        view.configure(enabled: true, revision: 0) { latest = $0 }; await drain()
        XCTAssertEqual(latest, 0.5)
        view.isHidden = true; view.updateTrackingAreas(); await drain()
        XCTAssertNil(latest)
        view.isHidden = false; view.updateTrackingAreas(); await drain()
        XCTAssertEqual(latest, 0.5)
        view.setFrameSize(NSSize(width: 80, height: 24)); view.updateTrackingAreas(); await drain()
        XCTAssertNil(latest, "A stationary cursor can leave the track when geometry changes")
    }

    func testFocusFullscreenAndDetachInvalidateHover() async {
        let (window, view) = fixture(); defer { window.close() }
        var latest: Double?
        view.configure(enabled: true, revision: 0) { latest = $0 }
        view.point = NSPoint(x: 106, y: 12); view.pointerDidMove(); await drain()
        XCTAssertEqual(latest, 0.5)
        view.active = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await drain(); XCTAssertNil(latest)
        view.active = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drain(); XCTAssertEqual(latest, 0.5)
        for entering in [true, false] {
            NotificationCenter.default.post(name: entering ? NSWindow.willEnterFullScreenNotification : NSWindow.willExitFullScreenNotification, object: window)
            view.pointerDidMove(); await drain(); XCTAssertNil(latest)
            NotificationCenter.default.post(name: entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification, object: window)
            await drain(); XCTAssertEqual(latest, 0.5)
        }
        view.detach(); await drain(); XCTAssertNil(latest)
    }

    func testNewPlaybackRejectsPendingHoverUntilNewMovement() async {
        let (window, view) = fixture(); defer { view.detach(); window.close() }
        var latest: Double?
        view.configure(enabled: true, revision: 0) { latest = $0 }
        view.point = NSPoint(x: 106, y: 12); view.pointerDidMove(); await drain()
        XCTAssertEqual(latest, 0.5)
        view.point = NSPoint(x: 56, y: 12); view.pointerDidMove()
        view.configure(enabled: true, revision: 1) { latest = $0 }
        await drain(); XCTAssertNil(latest)
        view.pointerDidMove(); await drain(); XCTAssertEqual(latest, 0.25)
    }

    func testPreviewAndSeekUseIdenticalCoordinatesAcrossTrack() {
        for width: CGFloat in [212, 600, 1400] {
            for x: CGFloat in [0, 6, 56, width / 2, width - 6, width] {
                XCTAssertEqual(PlayerProgressHoverPolicy.fraction(x: x, width: width),
                               PlayerTimelinePolicy.fraction(x: x, width: width, horizontalInset: 6))
            }
        }
    }
}

@MainActor
final class PlayerOverlayLayoutTests: XCTestCase {
    func testConsecutiveFullscreenTransitionsFreezeTheLatestViewport() {
        var viewport = PlayerOverlayViewportState()
        let windowed = CGSize(width: 960, height: 540)
        let full = CGSize(width: 1728, height: 1117)
        viewport.update(windowed)
        viewport.setTransitioning(true)
        viewport.update(full)
        XCTAssertEqual(viewport.frozenSize, windowed)
        viewport.setTransitioning(false)
        XCTAssertNil(viewport.frozenSize)
        // No additional geometry notification arrives after completion.
        viewport.setTransitioning(true)
        XCTAssertEqual(viewport.frozenSize, full)
        viewport.update(.zero)
        XCTAssertEqual(viewport.latestSize, full)
        viewport.update(windowed)
        viewport.setTransitioning(false)
        viewport.setTransitioning(true)
        XCTAssertEqual(viewport.frozenSize, windowed)
    }

    func testAdaptiveControlsAndPanelsFitLongDurationsAndSmallWindows() {
        var modes = Set<String>()
        for time in ["06:47 / 46:44", "1:26:59 / 3:12:08", "99:59:59 / 999:59:59"] {
            for width in stride(from: 640.0, through: 2400.0, by: 8) {
                let layout = PlayerOverlayLayout(viewportSize: .init(width: width, height: 360),
                                                 timeLabelWidth: PlayerOverlayLayout.timeWidth(time))
                modes.insert(String(describing: layout.mode))
                let leading = (layout.mode == .expanded ? 121.0 : 38.0) + 10 + layout.timeLabelWidth
                let trailing = layout.showsAllTools ? 213.0 : 120.0
                if layout.mode == .stacked {
                    XCTAssertLessThanOrEqual(leading + trailing + 24, layout.innerWidth)
                } else {
                    XCTAssertLessThanOrEqual(leading, layout.sideWidth)
                    XCTAssertLessThanOrEqual(trailing, layout.sideWidth)
                    XCTAssertEqual(layout.sideWidth * 2 + PlayerOverlayLayout.transportWidth + 24, layout.innerWidth)
                }
                XCTAssertLessThanOrEqual(layout.controlWidth + 36, width)
                XCTAssertLessThanOrEqual(layout.panelMaximumSize.width + layout.panelTrailingInset, width)
                XCTAssertLessThanOrEqual(layout.panelMaximumSize.height + layout.panelBottomInset + 24, 360)
            }
        }
        // Extremely long media durations retain the transport in a second row.
        let long = PlayerOverlayLayout(viewportSize: .init(width: 640, height: 360), timeLabelWidth: 180)
        XCTAssertEqual(long.mode, .stacked)
        let middle = PlayerOverlayLayout(viewportSize: .init(width: 800, height: 450), timeLabelWidth: 190)
        XCTAssertEqual(middle.mode, .compactVolume)
        XCTAssertTrue(modes.contains("expanded")); XCTAssertTrue(modes.contains("compactTools"))
    }

    func testSupersededCompletionCannotRevealOverlayDuringNextTransition() async {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let overlay = PlayerFullscreenOverlayView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(overlay)
        defer { window.close() }
        overlay.suspendPresentation(); overlay.resumePresentation(); overlay.suspendPresentation()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(overlay.alphaValue, 0)
        overlay.resumePresentation()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(overlay.alphaValue, 1)
    }

    func testProductionControlsRenderAtMinimumAndWideViewports() async throws {
        let state = AppState(environment: nil)
        let configuration = StoredConfiguration(name: "Player Layout Fixture", sourceKind: .pasted, rawData: Data("{}".utf8))
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 4067, duration: 11528)
        let host = PlayerOverlayHostingView(rootView: ZStack {
            LinearGradient(colors: [.init(white: 0.9), .init(white: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            PlayerView(playerSnapshotState: state.playerSnapshotState, onWindowChromeRestored: {})
                .environmentObject(state)
        }.environment(\.colorScheme, .dark))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        let window = NSWindow(contentRect: .init(x: -2500, y: -2000, width: 960, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        for size in [CGSize(width: 640, height: 360), .init(width: 800, height: 450), .init(width: 1200, height: 675), .init(width: 2240, height: 1260)] {
            window.setContentSize(size)
            try await Task.sleep(nanoseconds: 120_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, size)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            image.name = "player-\(Int(size.width))"
            image.lifetime = .keepAlways
            add(image)
            let track = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? ProgressHoverTrackingNSView }.first)
            let trackRect = host.convert(track.bounds, from: track)
            XCTAssertTrue(host.bounds.contains(trackRect), "Timeline must remain entirely within viewport")
            XCTAssertGreaterThanOrEqual(track.bounds.height, 24)
        }
    }
}

@MainActor final class PlayerSeekRecoveryTests: XCTestCase {
    func testLongKeyframeLandingIsReadyButOldSeekOwnerIsNot() {
        var owner = PlayerSeekActivityOwner()
        owner.begin(request: 1, seek: 1)
        owner.markStarted(request: 1, seek: 1)
        owner.begin(request: 1, seek: 2)
        owner.markStarted(request: 1, seek: 1)
        XCTAssertFalse(owner.hasRestarted(request: 1, seek: 2))
        owner.markStarted(request: 1, seek: 2)
        XCTAssertFalse(owner.hasRestarted(request: 1, seek: 2), "A seek-start event is not playback recovery")
        owner.markRestarted(request: 1, seek: 1)
        XCTAssertFalse(owner.hasRestarted(request: 1, seek: 2))
        owner.markRestarted(request: 1, seek: 2)
        XCTAssertTrue(PlayerSeekCompletionPolicy.accepts(target: 2398, position: 2390,
            nativeSeeking: false, pausedForCache: false, seekRestarted: owner.hasRestarted(request: 1, seek: 2)))
        for busy in [true, false] {
            XCTAssertFalse(PlayerSeekCompletionPolicy.accepts(target: 2398, position: 2390,
                nativeSeeking: busy, pausedForCache: !busy, seekRestarted: true))
        }
        owner.begin(request: 2, seek: 3)
        owner.markStarted(request: 1, seek: 2)
        XCTAssertFalse(owner.hasRestarted(request: 2, seek: 3))
        owner.reset()
        XCTAssertFalse(owner.hasRestarted(request: 2, seek: 3))
    }
    func testBundledMPVLongGOPPlayingPausedAndRapidSeekRecovery() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEOMAC_SEEK_FIXTURE"] else {
            throw XCTSkip("Requires generated long-GOP fixture and a visible OpenGL surface")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var ready = false
        var latest = PlayerSnapshot()
        var snapshots: [PlayerSnapshot] = []
        var ends: [PlaybackEndOrigin] = []
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event { latest = snapshot; snapshots.append(snapshot) }
                if case .ended(_, let origin) = event { ends.append(origin) }
            }
        }
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) }, onSurfaceReady: { _ in ready = true }, onSurfaceUnavailable: { _ in })
        surface.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        window.contentView = surface
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        do {
            for _ in 0..<100 where !ready {
                window.displayIfNeeded()
                surface.needsDisplay = true
                surface.displayIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(ready, "visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) bounds=\(surface.bounds) backing=\(surface.convertToBacking(surface.bounds)) mini=\(window.isMiniaturized) superview=\(surface.superview != nil) \(surface.readinessDiagnosticsForTesting)")
            try await player.setMuted(true)
            var media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], format: "mov", siteKey: "seek-fixture", sourceName: "Fixture", episodeName: "1")
            media.transportProfile = .tvBox
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await player.play()
            try await Task.sleep(nanoseconds: 300_000_000)
            for paused in [false, true] {
                if paused { try await player.pause() }
                try await player.seek(to: 8)
                try await Task.sleep(nanoseconds: 100_000_000)
                for _ in 0..<100 where latest.isSeeking { try await Task.sleep(nanoseconds: 20_000_000) }
                XCTAssertNil(latest.seekTarget)
                XCTAssertFalse(latest.isSeeking)
                XCTAssertGreaterThan(abs(latest.position - 8), 5, "Fixture must exercise the previously rejected keyframe offset")
                XCTAssertEqual(latest.status, paused ? .paused : .playing)
            }
            try await player.play()
            for target in [8.0, 28, 9, 29] { try await player.seek(to: target) }
            try await Task.sleep(nanoseconds: 200_000_000)
            for _ in 0..<100 where latest.isSeeking { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(latest.isSeeking)
            XCTAssertNil(latest.seekTarget)
            XCTAssertGreaterThan(latest.position, 15, "Last requested seek must win")
            try await Task.sleep(nanoseconds: 15_100_000_000)
            XCTAssertFalse(snapshots.contains { if case .failed = $0.status { return true }; return false }, "Recovered seeks must never fire the old 15-second timeout")
            try await player.seek(to: 45)
            for _ in 0..<100 where ends.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(ends, [.userSeekBoundary], "Native EOF after seeking to the tail must be emitted once and allow the next episode")
            XCTAssertEqual(latest.status, .ended)
        } catch {
            reader.cancel(); surface.tearDown(); window.close(); await player.shutdown(); throw error
        }
        reader.cancel(); surface.tearDown(); window.close(); await player.shutdown()
    }
}

@MainActor final class PlayerEpisodeContinuationTests: XCTestCase {
    func testMixedNamingSkipsBonusAudioSubtitlesAndMissingUploads() {
        let items = ["21.mkv", "NEW22.mp4", "别名 23.mkv", "第24集 花絮.mkv", "EP24.mp3", "EP24.srt", "另一前缀 25.mkv"]
            .map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[2].id, enabled: true)?.id, items[6].id)
        for excluded in items[3...5] {
            XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: excluded.id, enabled: true))
        }
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[6].id, enabled: true))
    }

    func testDuplicateEpisodeNumbersDoNotChooseAnArbitraryUpload() {
        let items = ["21.mkv", "22.mkv", "NEW22.mkv", "23.mkv"]
            .map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[0].id, enabled: true))
    }

    func testSeasonOrderingAndMergedEpisodesRemainUnambiguous() {
        let items = ["S02E01.mkv", "S01E22.mkv", "S01E21.mkv", "S02E02-E03.mkv", "S02E04.mkv"]
            .map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[2].id, enabled: true)?.id, items[1].id)
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[1].id, enabled: true)?.id, items[0].id)
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[3].id, enabled: true))
    }

    func testAutoplayFollowsNumbersWhenPrefixesChange() async {
        let items = ["[4.7GB] 24.mkv", "[4.8GB] NEW 23.mkv", "[4.93GB] ZIYA 22.mkv", "[4.6GB] EP25.mkv"]
            .map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[2].id, enabled: true)?.id, items[1].id)
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[1].id, enabled: true)?.id, items[0].id)
        let snapshot = await EpisodePresentationRepository.shared.snapshot(videoID: "mixed-names", source: .init(name: "line", episodes: items))
        XCTAssertEqual(snapshot.playbackOrder.map(\.id), [items[2].id, items[1].id, items[0].id, items[3].id])
        XCTAssertEqual(snapshot.versionOrders[""]?.map(\.id), snapshot.playbackOrder.map(\.id))
    }

    func testNamedVideoFamilyAdvances22To23AndPreparesTheSameQueue() async {
        let items = (1...38).reversed().map {
            PlayEpisode(name: "[4.93GB] ZIYA \($0).mkv", url: "fixture:ziya:\($0)")
        }
        let current = items.first { $0.name == "[4.93GB] ZIYA 22.mkv" }!
        let next = PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: current.id, enabled: true, categoryName: "剧情 爱情 古装")
        XCTAssertEqual(next?.name, "[4.93GB] ZIYA 23.mkv")
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: current.id, enabled: false))
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[0].id, enabled: true))
        let snapshot = await EpisodePresentationRepository.shared.snapshot(videoID: "ziya-fixture", source: .init(name: "line", episodes: items), categoryName: "剧情 爱情 古装")
        XCTAssertEqual(snapshot.valuesByEpisodeID[current.id]?.episodeNumber, 22)
        XCTAssertEqual(snapshot.playbackOrder.count, 38)
        XCTAssertEqual(snapshot.versionOrders[""]?.count, 38, "Version queue reanalysis must retain list evidence")
        XCTAssertEqual(snapshot.playbackOrder[22].id, next?.id)
        XCTAssertNil(PlaybackResourceAnalyzer.trustedEpisode(current))
    }

    func testNamedVideoAutoplayStaysInTheCurrentVersion() {
        let high = (21...23).map { PlayEpisode(name: "[4.93GB] ZIYA \($0)_4K.mkv", url: "4k:\($0)") }
        let low = (21...23).map { PlayEpisode(name: "[1.50GB] ZIYA \($0)_1080p.mkv", url: "hd:\($0)") }
        let items = Array((high + low).reversed())
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: high[1].id, enabled: true)?.id, high[2].id)
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: low[1].id, enabled: true)?.id, low[2].id)
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: high[2].id, enabled: true))
    }

    private func files(_ numbers: [Int], quality: String = "4K") -> [PlayEpisode] {
        numbers.map { .init(name: "[1.11GB]\($0)_\(quality).mp4", url: "\(quality):\($0)") }
    }
    func testNumberedFileFamilyOrders32To33WithoutInventingPersistentIdentity() async {
        let items = files(Array((1...38).reversed()))
        let current = items.first { $0.name.contains("]32_") }!
        let next = PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: current.id, enabled: true, categoryName: "剧情 爱情 古装")
        XCTAssertEqual(next?.name, "[1.11GB]33_4K.mp4")
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: current.id, enabled: false))
        XCTAssertNil(PlaybackResourceAnalyzer.trustedEpisode(current, categoryName: "剧情 爱情 古装"), "Local list evidence must not rewrite cross-source history identity")
        let snapshot = await EpisodePresentationRepository.shared.snapshot(videoID: "fixture", source: .init(name: "line", episodes: items), categoryName: "剧情 爱情 古装")
        XCTAssertEqual(snapshot.playbackOrder, PlayerEpisodeAdvancePolicy.orderedEpisodes(in: items, categoryName: "剧情 爱情 古装"))
        XCTAssertEqual(snapshot.versionOrders["4K"]?.count, 38)
    }
    func testAutoplayKeepsVersionAndRejectsAmbiguousNumbers() {
        let high = files([31, 32, 33]), low = files([31, 32, 33], quality: "1080p")
        let next = PlayerEpisodeAdvancePolicy.nextEpisode(in: high + low, currentEpisodeID: high[1].id, enabled: true)
        XCTAssertEqual(next?.id, high[2].id)
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: high + low, currentEpisodeID: high[2].id, enabled: true))
        for items in [files([1, 3, 9]), files([2024, 2025, 2026]), files([1, 2]), files([1, 2, 2, 3])] {
            XCTAssertTrue(PlayerEpisodeAdvancePolicy.orderedEpisodes(in: items).isEmpty)
        }
        XCTAssertTrue(PlayerEpisodeAdvancePolicy.orderedEpisodes(in: high, categoryName: "电影").isEmpty)
        let bare = (1...10).map { PlayEpisode(name: String($0), url: String($0)) }
        XCTAssertTrue(PlayerEpisodeAdvancePolicy.orderedEpisodes(in: bare).isEmpty)
    }
    func testConfirmedSeekToEndHonorsAutoplayButBrokenStreamCannotAdvance() {
        let items = files([31, 32, 33])
        XCTAssertEqual(MPVPlayerClient.seekCommand(to: 45, duration: 45).last, "absolute+exact")
        XCTAssertEqual(MPVPlayerClient.seekCommand(to: 40, duration: 45).last, "absolute+keyframes")
        for origin in [PlaybackEndOrigin.natural, .userSeekBoundary] {
            XCTAssertNotNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[1].id, enabled: origin.permitsAutomaticAdvance))
        }
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items, currentEpisodeID: items[1].id, enabled: PlaybackEndOrigin.premature("disconnect").permitsAutomaticAdvance))
    }
}

@MainActor final class PlayerProgressPreviewRenderTests: XCTestCase {
    func testTimestampIsFullyRenderedOutsideClippedControlsAtBothEdges() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/okvideo-oct1-fixes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width: CGFloat in [640, 2240] {
            for fraction in [0.0, 0.5, 1.0] {
                let layout = PlayerOverlayLayout(viewportSize: .init(width: width, height: 240))
                let text = fraction == 0 ? "00:00" : "12:34:56"
                let host = NSHostingView(rootView:
                    ZStack {
                        Color(red: 0.18, green: 0.25, blue: 0.30)
                        VStack {
                            Spacer()
                            VStack(spacing: 3) {
                                PlayerTimelineControl(value: .constant(3600), total: 46000, bufferedPercent: 20, accentColor: .blue, isEmphasized: true, onEditingChanged: { _ in })
                                    .frame(height: 24)
                                    .anchorPreference(key: PlayerProgressTrackAnchorKey.self, value: .bounds) { $0 }
                                Color.clear.frame(height: 44)
                            }.padding(12).frame(width: layout.controlWidth)
                                .background(Color.black.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .padding(.bottom, 16)
                        }
                    }.modifier(PlayerProgressPreviewOverlay(fraction: fraction, text: text)))
                let window = NSWindow(contentRect: .init(x: -3000, y: -2000, width: width, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                if #available(macOS 13.0, *) { host.sizingOptions = [] }
                try await Task.sleep(nanoseconds: 100_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("hover-\(Int(width))-\(Int(fraction * 100)).png"))
                // Controls begin at y=133 (top-origin). White glyphs must be
                // rendered above their clipping boundary, not a black sliver.
                let scale = CGFloat(bitmap.pixelsWide) / width
                var glyphPixels = 0
                for y in Int(90 * scale)..<Int(133 * scale) {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.75, color.greenComponent > 0.75, color.blueComponent > 0.75 { glyphPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(glyphPixels, 10, "Timestamp must be visible above the clipped parent, width=\(width) fraction=\(fraction)")
                window.close()
            }
        }
    }
    func testTooltipBoundsAndWideFullscreenProportions() {
        for width: CGFloat in [640, 1200, 2240, 3440] {
            let layout = PlayerOverlayLayout(viewportSize: .init(width: width, height: 1260))
            XCTAssertGreaterThanOrEqual(layout.controlWidth / width, 0.85)
            XCTAssertLessThanOrEqual(layout.controlWidth / width, 0.95)
            for fraction in [0.0, 0.5, 1.0] {
                let rect = PlayerProgressPreviewOverlay.rect(track: .init(x: layout.horizontalInset, y: 1140, width: layout.controlWidth, height: 24), viewport: layout.viewportSize, fraction: fraction, text: "999:59:59")
                XCTAssertTrue(CGRect(origin: .zero, size: layout.viewportSize).contains(rect))
                XCTAssertLessThan(rect.maxY, 1140)
                XCTAssertEqual(rect.height, 28)
            }
        }
    }
}

@MainActor final class PlayerChannelPickerTests: XCTestCase {
    private func channel(_ name: String, group: String = "央视", number: String? = nil, alias: String? = nil) -> LiveChannel {
        LiveChannel(groupName: group, name: name, number: number, tvgName: alias,
            streams: [.init(name: "主线路", url: URL(string: "https://example.invalid/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!)])
    }
    func testNormalizedSearchRanksExactAndPreservesPlusChannel() {
        let plus = channel("CCTV-5+"), exact = channel("CCTV-5", number: "5"), other = channel("浙江卫视", group: "卫视", number: "101", alias: "ZJTV")
        let channels = [plus, other, exact]
        XCTAssertEqual(PlayerChannelSearch.results(channels, query: " ｃｃｔｖ－５ ").map(\.name), ["CCTV-5", "CCTV-5+"])
        XCTAssertEqual(PlayerChannelSearch.results(channels, query: "cctv5+").map(\.id), [plus.id])
        for query in ["101", "zjtv", "卫视"] { XCTAssertEqual(PlayerChannelSearch.results(channels, query: query).map(\.id), [other.id]) }
        XCTAssertEqual(PlayerChannelSearch.results(channels, query: ""), channels)
        XCTAssertTrue(PlayerChannelSearch.results(channels, query: "不存在").isEmpty)
    }
    func testPickerSearchesOtherGroupsAndUsesPlayingSnapshot() async throws {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Fixture", sourceKind: .pasted, rawData: Data())
        let a = channel("CCTV-5"), b = channel("浙江卫视", group: "卫视"), locked = channel("加密", group: "Protected")
        let playlist = LivePlaylist(format: .m3u, groups: [.init(name: "央视", channels: [a]), .init(name: "卫视", channels: [b]), .init(name: "Protected", password: "fixture", channels: [locked])])
        state.acceptImportedRoutesForTesting(source, playlist: playlist)
        let catalog = try XCTUnwrap(state.acceptedImportedCatalogs[source.id])
        var played: [URL] = []
        state.importedRouteLoadForTesting = { _, media, _ in played.append(media.url) }
        await state.playImportedLive(catalog.selections(for: a)[0], navigationChannels: [a])
        XCTAssertEqual(state.playerLiveChannels.map(\.id), [a.id, b.id])
        // A refresh must not change the routes offered by an already playing snapshot.
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "New", channels: [channel("新频道")])]))
        XCTAssertEqual(state.playerLiveChannels.map(\.id), [a.id, b.id])
        await state.selectPlayerLiveChannel(locked.id, source: .imported(source.id))
        await state.selectPlayerLiveChannel(b.id, source: .imported(UUID()))
        XCTAssertEqual(played.count, 1)
        await state.selectPlayerLiveChannel(b.id, source: .imported(source.id))
        XCTAssertEqual(played.last, b.streams[0].url)
        XCTAssertEqual(state.livePlaybackChannel?.id, b.id)
        await state.switchLiveChannel(by: -1)
        XCTAssertEqual(state.livePlaybackChannel?.id, a.id)
        await state.closePlayer()
    }
    func testNativeSearchCommandsYieldToIMEAndOrdinaryTyping() {
        var text = "", moves: [Int] = [], submissions = 0, escapes = 0
        let view = PlayerChannelSearchField(text: .init(get: { text }, set: { text = $0 }),
            move: { moves.append($0) }, submit: { submissions += 1 }, escape: { escapes += 1 })
        let delegate = view.makeCoordinator(), field = NSSearchField(), editor = NSTextView()
        editor.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(submissions, 0); XCTAssertTrue(moves.isEmpty); XCTAssertEqual(escapes, 0)
        editor.unmarkText()
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: command))
        }
        XCTAssertEqual(moves, [1, -1]); XCTAssertEqual(submissions, 1); XCTAssertEqual(escapes, 1)
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    }
    func testNativeEditingKeepsPanelSizeAndDoesNotStartPlayback() async throws {
        let channels = (1...30).map { channel("CCTV-\($0)") }
        var selections: [String] = [], closes = 0
        let host = NSHostingView(rootView: PlayerChannelPicker(channels: channels, currentID: channels[15].id,
            title: "频道", select: { selections.append($0) }, close: { closes += 1 })
            .padding(14).frame(width: 370, height: 490).background(Color.black).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: .init(x: -2500, y: -2000, width: 370, height: 490), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 180_000_000)
        let field = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSSearchField }.first)
        let delegate = try XCTUnwrap(field.delegate as? PlayerChannelSearchField.Coordinator)
        let original = host.bounds.size
        for query in ["cctv5", "不存在", ""] {
            field.stringValue = query; delegate.changed(field)
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, original)
            XCTAssertTrue(selections.isEmpty)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            image.name = "channel-search-\(query.isEmpty ? "all" : query)"; image.lifetime = .keepAlways; add(image)
        }
        let editor = NSTextView()
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(selections, [channels[15].id], "Clearing search must return keyboard selection to the playing channel")
        selections.removeAll()
        field.stringValue = "cctv5"; delegate.changed(field)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(selections, [channels[4].id])
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(field.stringValue, ""); XCTAssertEqual(closes, 0)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(closes, 1)
    }
}
