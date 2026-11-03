import AppKit
import SwiftUI
import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlayerStatusPresentationTests: XCTestCase {
    private func settle(_ milliseconds: UInt64 = 100) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
    private func fixture(size: CGSize = .init(width: 1200, height: 675)) -> (AppState, NSWindow, NSView) {
        let state = AppState(environment: nil)
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 60, duration: 600))
        let host = PlayerOverlayHostingView(rootView: PlayerView(playerSnapshotState: state.playerSnapshotState,
            onWindowChromeRestored: {}).environmentObject(state).background(Color.black))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setFrameOrigin(.init(x: (NSScreen.screens.map { $0.frame.maxX }.max() ?? 2000) + 500, y: 0))
        window.orderBack(nil); window.setContentSize(size); host.layoutSubtreeIfNeeded()
        return (state, window, host)
    }
    private func probes(_ window: NSWindow) -> [PlayerPresentationProbeView] {
        guard let host = window.contentView else { return [] }
        return BrowserKeyboardView.descendants(of: host).compactMap { $0 as? PlayerPresentationProbeView }
    }
    private func labels(_ window: NSWindow) -> [String] { probes(window).map(\.title) }
    private func status(_ window: NSWindow, title: String) throws -> CGRect {
        window.contentView?.layoutSubtreeIfNeeded()
        let found = probes(window).first { $0.title == title }
        if found == nil, let host = window.contentView {
            try capture(host, "missing-" + title)
            print("STATUS_DIAGNOSTIC bounds=\(host.bounds) expected=\(title) labels=\(labels(window))")
        }
        let probe = try XCTUnwrap(found, title)
        return probe.convert(probe.bounds, to: nil)
    }
    private func assertAboveTimeline(_ frame: CGRect, in window: NSWindow) throws {
        let track = try status(window, title: "timeline")
        XCTAssertGreaterThanOrEqual(frame.minY, track.maxY + 7, "Status must sit clearly above the entire timeline hit area")
        XCTAssertEqual(frame.minX, track.minX + 6, accuracy: 1, "Status aligns with the track's left inset")
        XCTAssertEqual(frame.height, 20, accuracy: 1, "All status kinds share one line height")
    }
    private func capture(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Status185-Visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func cleanup(_ window: NSWindow) { window.contentView = nil; window.close() }

    func testPreparationSeekAndFailureShareTrackAnchorWithoutSpeedOverlay() async throws {
        let (state, window, host) = fixture(); defer { cleanup(window) }
        var anchor: CGRect?
        for phase: PlaybackResolutionState in [.resolving, .validating, .loading, .restoringHistory, .retrying] {
            state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .loading), resolution: phase, hasStarted: false)
            try await settle()
            try capture(host, "vod-phase-\(phase)")
            let frame = try status(window, title: state.playbackStageDescription)
            try assertAboveTimeline(frame, in: window)
            XCTAssertLessThan(frame.minX, 100); XCTAssertLessThan(frame.maxY, 180)
            if let anchor { XCTAssertEqual(frame.minX, anchor.minX, accuracy: 1); XCTAssertEqual(frame.minY, anchor.minY, accuracy: 1) }
            else { anchor = frame }
            XCTAssertFalse(labels(window).contains(state.playerNetworkSpeedDescription))
        }
        try capture(host, "vod-loading")
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 60, duration: 600, isSeeking: true, seekTarget: 300))
        try await settle(450)
        let seek = try status(window, title: L10n.string("player.status.seeking-to", fallback: "Seeking to %@", "05:00"))
        XCTAssertEqual(seek.minX, try XCTUnwrap(anchor).minX, accuracy: 1)
        XCTAssertEqual(seek.minY, try XCTUnwrap(anchor).minY, accuracy: 1)
        try assertAboveTimeline(seek, in: window)
        try capture(host, "vod-seeking")
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .failed("Fixture failure")), resolution: .failed)
        try await settle()
        let failed = try status(window, title: L10n.string("player.stage.failed", fallback: "Playback Failed"))
        XCTAssertEqual(failed.minY, seek.minY, accuracy: 1)
        try assertAboveTimeline(failed, in: window)
        try capture(host, "vod-failure")
    }

    func testFastSeekAndReplacedSessionCancelDelayedStatus() async throws {
        let (state, window, _) = fixture(); defer { cleanup(window) }
        try await settle()
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 60, duration: 600, isSeeking: true, seekTarget: 300))
        try await settle(80)
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 300, duration: 600))
        try await settle(450)
        let title = L10n.string("player.status.seeking-to", fallback: "Seeking to %@", "05:00")
        XCTAssertFalse(labels(window).contains(title))
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 300, duration: 600, isSeeking: true, seekTarget: 400))
        try await settle(80)
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 1, duration: 900), newSession: true)
        try await settle(450)
        XCTAssertFalse(labels(window).contains(where: { $0.contains("06:40") }))
        XCTAssertFalse(labels(window).contains(state.playerNetworkSpeedDescription))
    }

    func testLiveBufferingReplacesModeLabelAndKeepsAnchorThroughAutoHide() async throws {
        let (state, window, host) = fixture(); defer { cleanup(window) }
        state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .playing, position: 60))
        try await settle()
        let normal = L10n.string("player.live", fallback: "Live")
        XCTAssertTrue(labels(window).contains(where: { $0.contains(normal) }))
        state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .playing, position: 60, isPausedForCache: true))
        let buffering = L10n.string("player.status.buffering", fallback: "Buffering")
        try await settle(100); XCTAssertFalse(labels(window).contains(buffering))
        try await settle(600)
        let frame = try status(window, title: buffering)
        XCTAssertGreaterThan(frame.minX, 100); XCTAssertLessThan(frame.maxY, 90)
        XCTAssertFalse(labels(window).contains(normal))
        try capture(host, "live-buffering")
        try await settle(2500)
        let hidden = try status(window, title: buffering)
        XCTAssertEqual(hidden.minX, frame.minX, accuracy: 1); XCTAssertEqual(hidden.minY, frame.minY, accuracy: 1)
        try capture(host, "live-controls-hidden")
        try await settle(2200)
        let slow = try status(window, title: L10n.string("player.status.slow", fallback: "Connection is slow"))
        XCTAssertEqual(slow.minX, frame.minX, accuracy: 1); XCTAssertEqual(slow.minY, frame.minY, accuracy: 1)
        state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .playing, position: 61))
        try await settle()
        XCTAssertFalse(labels(window).contains(buffering))
        XCTAssertFalse(labels(window).contains(L10n.string("player.status.slow", fallback: "Connection is slow")))
    }

    func testStatusAnchorsFitNarrowAndFullscreenSizedWindows() async throws {
        for size in [CGSize(width: 640, height: 360), CGSize(width: 1200, height: 675), CGSize(width: 1920, height: 1080)] {
            let (state, window, host) = fixture(size: size)
            defer { cleanup(window) }
            var anchor: CGRect?
            func checkVOD(_ title: String, _ name: String) throws {
                let frame = try status(window, title: title)
                try assertAboveTimeline(frame, in: window)
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThan(frame.maxX, size.width)
                XCTAssertGreaterThan(frame.minY, 55); XCTAssertLessThan(frame.maxY, size.height / 2)
                if let anchor { XCTAssertEqual(frame.minY, anchor.minY, accuracy: 1); XCTAssertEqual(frame.minX, anchor.minX, accuracy: 1) }
                else { anchor = frame }
                try capture(host, "vod-\(Int(size.width))-\(name)")
            }
            for phase: PlaybackResolutionState in [.resolving, .validating, .loading, .restoringHistory, .retrying] {
                state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .loading), resolution: phase, hasStarted: false)
                try await settle()
                try checkVOD(state.playbackStageDescription, "\(phase)")
            }
            state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 60, duration: 600, isSeeking: true, seekTarget: 300))
            try await settle(450)
            try checkVOD(L10n.string("player.status.seeking-to", fallback: "Seeking to %@", "05:00"), "seeking")
            state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .playing, position: 300, duration: 600, isPausedForCache: true))
            try await settle(450)
            try checkVOD(state.playbackStageDescription, "buffering")
            state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .failed("Fixture failure")), resolution: .failed,
                failure: "播放暂时失败，请重试或返回历史记录。已保存的播放进度会保留。")
            try await settle()
            try checkVOD(L10n.string("player.stage.failed", fallback: "Playback Failed"), "failed")
            let description = try status(window, title: "failure-description")
            XCTAssertEqual(description.minX, try XCTUnwrap(anchor).minX, accuracy: 1)
            XCTAssertGreaterThan(description.minY, try XCTUnwrap(anchor).maxY)
            let episode = PlayEpisode(name: "第 3 集", url: "https://example.invalid/fixture.mp4")
            let source = PlaySource(name: "原线路", episodes: [episode])
            let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "fixture", title: "原始文件"), playSources: [source])
            state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .loading), resolution: .restoringHistory, hasStarted: false,
                choices: [.init(detail: detail, source: source, episode: episode)])
            try await settle()
            try checkVOD(L10n.string("player.status.choose-history", fallback: "Choose the original file"), "history-choice")
            state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .loading), hasStarted: false, newSession: true)
            try await settle(700)
            let live = try status(window, title: L10n.string("player.status.connecting", fallback: "Connecting"))
            XCTAssertGreaterThan(live.minX, try XCTUnwrap(anchor).minX); XCTAssertLessThan(live.maxX, size.width - 140)
            XCTAssertGreaterThan(live.minY, 0); XCTAssertLessThan(live.maxY, 90)
            try capture(host, "live-\(Int(size.width))-connecting")
            state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .playing, isPausedForCache: true))
            try await settle(700)
            let buffering = try status(window, title: L10n.string("player.status.buffering", fallback: "Buffering"))
            XCTAssertEqual(buffering.minX, live.minX, accuracy: 1); XCTAssertEqual(buffering.minY, live.minY, accuracy: 1)
            try capture(host, "live-\(Int(size.width))-buffering")
            state.seedPlaybackStatusForTesting(live: true, snapshot: .init(status: .failed("Fixture failure")), resolution: .failed,
                failure: "连接暂时失败，请重试。")
            try await settle()
            let failed = try status(window, title: L10n.string("player.stage.failed", fallback: "Playback Failed"))
            XCTAssertEqual(failed.minX, live.minX, accuracy: 1); XCTAssertEqual(failed.minY, live.minY, accuracy: 1)
            try capture(host, "live-\(Int(size.width))-failed")
        }
    }
}
