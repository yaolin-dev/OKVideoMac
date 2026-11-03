import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class PlayerStatusInteractionTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(nanoseconds: 180_000_000) }

    private func fixture(size: CGSize) async throws -> (AppState, NSWindow) {
        let state = AppState(environment: nil)
        let host = PlayerOverlayHostingView(rootView: PlayerView(
            playerSnapshotState: state.playerSnapshotState, onWindowChromeRestored: {})
            .environmentObject(state).background(Color.black))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        let window = NSWindow(contentRect: .init(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(.init(x: 40, y: 80))
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        state.setPlayerWindowKey(true)
        try await settle()
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<30 where !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            try await settle()
        }
        guard window.isKeyWindow else {
            window.contentView = nil; window.close()
            throw NSError(domain: "DesktopTestPrerequisite", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture must receive native input"])
        }
        return (state, window)
    }

    private func seedChoice(_ state: AppState) {
        let episode = PlayEpisode(name: "[6.50GB]4K.HDR.mp4", url: "https://example.invalid/fixture.mp4")
        let source = PlaySource(name: "Original", episodes: [episode])
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture",
            videoID: "original", title: "Original File"), playSources: [source])
        let configuration = StoredConfiguration(name: "Recovery Fixture", sourceKind: .pasted, rawData: Data("{}".utf8))
        state.setLiveConfigurationForTesting(configuration, providers: [:])
        let record = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "original",
            title: "Original File", sourceName: "Original", episodeName: episode.name,
            position: 312.375, duration: 6245.44)
        state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .loading),
            resolution: .restoringHistory, hasStarted: false,
            choices: [.init(detail: detail, source: source, episode: episode, requiresRelink: true)],
            failure: "Check the original file before restoring playback. Saved progress is retained.",
            historyRecord: record)
    }

    private func frame(_ name: String, in window: NSWindow) throws -> CGRect {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let probe = try XCTUnwrap(BrowserKeyboardView.descendants(of: host)
            .compactMap { $0 as? PlayerPresentationProbeView }.first { $0.title == name })
        return probe.convert(probe.bounds, to: nil)
    }

    private func click(_ point: NSPoint, in window: NSWindow) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: now + 0.05, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Dispatch pointer events through AppKit's normal hit testing. An AX
        // press or calling the action directly misses the visible-but-dead UI.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        try await settle()
    }

    func testHistoryChoiceRespondsToMouseAcrossCardAndWindowSizes() async throws {
        for size in [CGSize(width: 640, height: 360), .init(width: 1200, height: 675), .init(width: 1920, height: 1080)] {
            let (state, window) = try await fixture(size: size)
            defer { window.contentView = nil; window.close() }
            // File title, resume label, and empty card space all belong to the button.
            for location in [CGPoint(x: 0.08, y: 0.8), .init(x: 0.15, y: 0.2), .init(x: 0.85, y: 0.5)] {
                seedChoice(state)
                try await settle()
                let card = try frame("history-recovery-choice", in: window)
                XCTAssertGreaterThan(card.height, 30)
                try await click(.init(x: card.minX + card.width * location.x,
                    y: card.minY + card.height * location.y), in: window)
                XCTAssertFalse(state.hasHistoryPlaybackChoices,
                    "Visible card must handle pointer at \(location), viewport \(size)")
            }
            await state.closePlayer()
        }
    }

    func testCancelRecoveryRespondsToMouseAndLeavesTransportUsable() async throws {
        for size in [CGSize(width: 640, height: 360), .init(width: 1200, height: 675), .init(width: 1920, height: 1080)] {
            let (state, window) = try await fixture(size: size)
            defer { window.contentView = nil; window.close() }
            seedChoice(state)
            try await settle()
            let cancel = try frame("history-recovery-cancel", in: window)
            try await click(.init(x: cancel.midX, y: cancel.midY), in: window)
            XCTAssertFalse(state.hasHistoryPlaybackChoices, "Cancel must receive the mouse at \(size)")
            // The larger recovery layer must not swallow ordinary transport input.
            let volume = try frame("volume-button", in: window)
            let wasMuted = state.playerAudioPreference.muted
            try await click(.init(x: volume.midX, y: volume.midY), in: window)
            XCTAssertEqual(state.playerAudioPreference.muted, !wasMuted,
                "Recovery overlay must leave transport clickable at \(size)")
            await state.closePlayer()
        }
    }

    func testFailureRetryOriginalDetailsAndReturnReceiveMouse() async throws {
        for size in [CGSize(width: 640, height: 360), .init(width: 1200, height: 675), .init(width: 1920, height: 1080)] {
            let (state, window) = try await fixture(size: size)
            defer { window.contentView = nil; window.close() }
            for action in ["retry", "original", "return"] {
                seedChoice(state)
                state.seedPlaybackStatusForTesting(live: false, snapshot: .init(status: .failed("Fixture failure")),
                    resolution: .failed, hasStarted: false, failure: "Unable to restore. Saved progress is retained.")
                try await settle()
                XCTAssertTrue(state.canRetryHistoryPlayback)
                let previousRequest = state.playbackDiagnosticRecordsForTesting.last?.currentRequestID
                let button = try frame("history-recovery-" + action, in: window)
                try await click(.init(x: button.midX, y: button.midY), in: window)
                if action == "retry" {
                    XCTAssertNotEqual(state.playbackDiagnosticRecordsForTesting.last?.currentRequestID, previousRequest,
                        "Retry must create a fresh restore request")
                } else {
                    XCTAssertFalse(state.isPlayerPresented, "\(action) must leave the failed player")
                    if action == "return" { XCTAssertEqual(state.selectedSection, .history) }
                    else { XCTAssertEqual(state.selectedSection, .home) }
                }
            }
            await state.closePlayer()
        }
    }

    func testCompactVolumeHoverDoesNotMoveTimeAndMuteRemainsClickable() async throws {
        let (state, window) = try await fixture(size: .init(width: 960, height: 540))
        defer { window.contentView = nil; window.close() }
        seedChoice(state)
        state.seedPlaybackStatusForTesting(live: false,
            snapshot: .init(status: .paused, position: 62, duration: 600))
        try await settle()
        let before = try frame("playback-time", in: window)
        let volume = try frame("volume-button", in: window)
        XCTAssertEqual(volume.width, 36, accuracy: 1)
        XCTAssertEqual(volume.height, 36, accuracy: 1)
        XCTAssertFalse(BrowserKeyboardView.descendants(of: window.contentView!).contains { $0 is NSSlider })
        let muted = state.playerAudioPreference.muted
        try await click(.init(x: volume.midX, y: volume.midY), in: window)
        XCTAssertEqual(state.playerAudioPreference.muted, !muted)
        let tracking = try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView!)
            .compactMap { $0 as? PlayerVolumeHoverNSView }.first)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered,
            location: .init(x: volume.midX, y: volume.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        tracking.mouseEntered(with: event)
        try await settle()
        XCTAssertEqual(try frame("playback-time", in: window), before,
            "Floating volume must never push the time or toolbar")
        func volumeIsVisible() -> Bool {
            BrowserKeyboardView.descendants(of: window.contentView!).contains {
                ($0 as? PlayerPresentationProbeView)?.title == "volume-popover"
            }
        }
        XCTAssertTrue(volumeIsVisible())
        let slider = try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView!)
            .compactMap { $0 as? NSSlider }.first)
        let popupTracking = try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView!)
            .compactMap { $0 as? PlayerVolumeHoverNSView }.first { $0.role == "popover" })
        popupTracking.mouseEntered(with: event)
        tracking.mouseExited(with: event)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(volumeIsVisible(), "Moving from the button into the slider must keep it open")
        let sliderFrame = slider.convert(slider.bounds, to: nil)
        let previous = state.playerAudioPreference.volume
        let panelFrame = try frame("volume-popover", in: window)
        XCTAssertTrue(panelFrame.contains(sliderFrame), "Slider must be inside its panel's interactive bounds")
        XCTAssertTrue(window.contentView?.superview?.hitTest(.init(x: sliderFrame.minX + 8, y: sliderFrame.midY)) === slider,
            "Decorative volume panel layers must not intercept the native slider")
        try await click(.init(x: sliderFrame.minX + 8, y: sliderFrame.midY), in: window)
        XCTAssertTrue(volumeIsVisible(), "Clicking the slider must not dismiss its panel")
        XCTAssertNotEqual(state.playerAudioPreference.volume, previous)
        tracking.mouseExited(with: event)
        popupTracking.mouseExited(with: event)
        for _ in 0..<40 where volumeIsVisible() { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertFalse(volumeIsVisible())
        XCTAssertEqual(try frame("playback-time", in: window), before)
        // A real user hovers before clicking. The volume panel must not
        // consume that first mute click while it dismisses itself.
        tracking.mouseEntered(with: event)
        try await settle()
        let mutedWhileOpen = state.playerAudioPreference.muted
        try await click(.init(x: volume.midX, y: volume.midY), in: window)
        XCTAssertEqual(state.playerAudioPreference.muted, !mutedWhileOpen,
            "Mute must work on the first click with the volume popover open")
        tracking.mouseEntered(with: event)
        try await settle()
        state.requestPlayerEscapeHandling()
        try await settle()
        XCTAssertFalse(volumeIsVisible(), "Escape dismisses the volume panel first")
        await state.closePlayer()
    }
}
