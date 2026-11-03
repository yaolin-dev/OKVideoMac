import AppKit
import SwiftUI
import XCTest
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class PlayerPanelDismissalTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(nanoseconds: 180_000_000) }

    private func fixture(size: CGSize = .init(width: 1200, height: 675)) async throws -> (AppState, NSWindow) {
        let state = AppState(environment: nil)
        state.seedHistoryPlaybackForTesting(configuration: StoredConfiguration(name: "Outside Click Fixture",
            sourceKind: .pasted, rawData: Data("{}".utf8)), position: 60, duration: 600)
        let host = PlayerOverlayHostingView(rootView: PlayerView(playerSnapshotState: state.playerSnapshotState,
            onWindowChromeRestored: {}).environmentObject(state))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        let window = NSWindow(contentRect: .init(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI's mouse handling requires a rendered, active window.
        window.setFrameOrigin(.init(x: 100, y: 200))
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        state.setPlayerWindowKey(true)
        try await settle()
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        try await settle()
        for _ in 0..<60 where !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            try await settle()
        }
        guard window.isKeyWindow else {
            let detail = "Fixture must receive native input: active=\(NSApp.isActive), hidden=\(NSApp.isHidden), visible=\(window.isVisible), canKey=\(window.canBecomeKey), modal=\(NSApp.modalWindow != nil)"
            window.contentView = nil
            window.close()
            // Fail this prerequisite once instead of generating misleading
            // downstream interaction failures. This is never an XCTSkip.
            throw NSError(domain: "DesktopTestPrerequisite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        host.display()
        return (state, window)
    }

    private func cleanup(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func boundaries(_ window: NSWindow) -> [PlayerPanelBoundaryNSView] {
        guard let content = window.contentView else { return [] }
        return BrowserKeyboardView.descendants(of: content).compactMap { $0 as? PlayerPanelBoundaryNSView }
    }

    private func panels(_ window: NSWindow) -> [PlayerPanelBoundaryNSView] {
        boundaries(window).filter { $0.role == .panel }
    }

    private func click(_ name: String, in window: NSWindow) async throws {
        let presenter = try XCTUnwrap(boundaries(window).first { $0.role == .presenter(name) })
        try await click(at: presenter.convert(.init(x: presenter.bounds.midX, y: presenter.bounds.midY), to: nil), in: window)
    }

    private func click(at point: NSPoint, in window: NSWindow, right: Bool = false) async throws {
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: right ? .rightMouseDown : .leftMouseDown,
            location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: right ? .rightMouseUp : .leftMouseUp,
            location: point, modifierFlags: [], timestamp: time + 0.05, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native mouse-down/up catches toggle reopening and click swallowing;
        // invoking SwiftUI actions directly would miss both regressions.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        try await settle()
    }

    private func clickPanel(in window: NSWindow, x: CGFloat, fromTop: CGFloat) async throws {
        let panel = try XCTUnwrap(panels(window).first)
        try await click(at: panel.convert(.init(x: x, y: panel.bounds.height - fromTop), to: nil), in: window)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-OutsideDismissTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func testOutsideClickClosesEachPanelWithoutChangingPlayback() async throws {
        let (state, window) = try await fixture()
        defer { cleanup(window) }
        for name in ["episodes", "subtitles", "settings"] {
            try await click(name, in: window)
            XCTAssertEqual(panels(window).count, 1)
            try await click(at: .init(x: 150, y: 400), in: window)
            XCTAssertTrue(panels(window).isEmpty, "Outside click closes \(name)")
            XCTAssertEqual(state.playerSnapshot.position, 60)
            XCTAssertEqual(state.playerSnapshot.status, .playing)
        }
        try await click("settings", in: window)
        try await click(at: .init(x: 150, y: 400), in: window, right: true)
        XCTAssertTrue(panels(window).isEmpty, "Right-click outside also dismisses")
        await state.closePlayer()
    }

    func testPresentingButtonTogglesAndOtherButtonsSwitchDirectly() async throws {
        let (state, window) = try await fixture()
        defer { cleanup(window) }
        for name in ["episodes", "subtitles", "settings"] {
            for _ in 0..<2 {
                try await click(name, in: window)
                XCTAssertEqual(panels(window).count, 1)
                try await click(name, in: window)
                XCTAssertTrue(panels(window).isEmpty, "Presenter must close, not reopen \(name)")
            }
        }
        for name in ["episodes", "subtitles", "settings", "subtitles"] {
            try await click(name, in: window)
            XCTAssertEqual(panels(window).count, 1, "One click switches directly to \(name)")
            let expectedWidth: CGFloat = name == "episodes" ? 500 : name == "subtitles" ? 360 : 370
            XCTAssertEqual(try XCTUnwrap(panels(window).first).bounds.width, expectedWidth, accuracy: 1,
                "The newly selected panel must replace the previous content")
        }
        await state.closePlayer()
    }

    func testInsidePanelNavigationAndCloseStillWork() async throws {
        let (state, window) = try await fixture()
        defer { cleanup(window) }
        try await click("settings", in: window)
        try capture(window, name: "settings-open")
        // Resolve the current rendered row after each navigation. ScrollView
        // geometry and localization must not turn old pixel offsets into a
        // click on a different destination. Still deliver real mouse events.
        for (destination, width) in [("audio", 340.0), ("danmaku", 390.0), ("information", 420.0)] {
            try await click("settings.\(destination)", in: window)
            XCTAssertEqual(panels(window).count, 1, "Inside click navigates without dismissing")
            let panel = try XCTUnwrap(panels(window).first)
            XCTAssertEqual(panel.bounds.width, width, accuracy: 1, "Destination actually opened")
            try await click(at: panel.convert(.init(x: 5, y: panel.bounds.midY), to: nil), in: window)
            XCTAssertEqual(panels(window).count, 1, "Panel padding also belongs to the panel")
            try await click("settings.back", in: window)
            XCTAssertEqual(try XCTUnwrap(panels(window).first).bounds.width, 370, accuracy: 1, "Back returns to settings")
        }
        try await click("settings.close", in: window)
        XCTAssertTrue(panels(window).isEmpty)
        await state.closePlayer()
    }

    func testOutsideToolbarControlReceivesTheSameClick() async throws {
        let (state, window) = try await fixture()
        defer { cleanup(window) }
        try await click("subtitles", in: window)
        let wasMuted = state.playerAudioPreference.muted
        let volume = try XCTUnwrap(BrowserKeyboardView.descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? PlayerPresentationProbeView }.first { $0.title == "volume-button" })
        let volumeRect = volume.convert(volume.bounds, to: nil)
        // The collapsed mute button must receive the same outside click.
        try await click(at: .init(x: volumeRect.midX, y: volumeRect.midY), in: window)
        XCTAssertTrue(panels(window).isEmpty)
        XCTAssertEqual(state.playerAudioPreference.muted, !wasMuted, "Outside click also activates the chosen control once")
        await state.closePlayer()
    }

    func testBoundaryUsesCurrentGeometryAndDetachesFromWindow() async throws {
        let window = NSWindow(contentRect: .init(x: -2500, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .init(x: -3000, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { cleanup(window); cleanup(other) }
        let panel = PlayerPanelBoundaryNSView(role: .panel)
        panel.frame = .init(x: 200, y: 100, width: 200, height: 150)
        var dismissals = 0
        panel.onDismiss = { dismissals += 1 }
        window.contentView?.addSubview(panel)
        XCTAssertNil(panel.hitTest(.init(x: 10, y: 10)), "Boundary never intercepts controls")
        try await click(at: .init(x: 250, y: 150), in: window)
        XCTAssertEqual(dismissals, 0)
        panel.setFrameOrigin(.init(x: 300, y: 100))
        try await click(at: .init(x: 250, y: 150), in: window)
        XCTAssertEqual(dismissals, 1, "Use live bounds after layout changes")
        try await click(at: .init(x: 20, y: 20), in: other)
        XCTAssertEqual(dismissals, 1, "Events in other windows must not affect this player's panel")
        panel.removeFromSuperview()
        try await click(at: .init(x: 20, y: 20), in: window)
        XCTAssertEqual(dismissals, 1, "Removed panel has no surviving event monitor")
        panel.detach()
    }
}
