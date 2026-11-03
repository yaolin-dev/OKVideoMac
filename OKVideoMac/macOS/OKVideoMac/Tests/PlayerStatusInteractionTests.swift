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
            let host = try XCTUnwrap(window.contentView)
            if let slider = BrowserKeyboardView.descendants(of: host).compactMap({ $0 as? NSSlider })
                .first(where: { $0.bounds.width < 100 }) {
                let rect = slider.convert(slider.bounds, to: nil)
                let wasMuted = state.playerAudioPreference.muted
                try await click(.init(x: rect.minX - 26, y: rect.midY), in: window)
                XCTAssertEqual(state.playerAudioPreference.muted, !wasMuted,
                    "Recovery overlay must leave transport clickable at \(size)")
            }
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
}
