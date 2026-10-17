import AppKit
import Combine
import SwiftUI
import XCTest
import OKVideoCore
@testable import OKVideoMac

final class PictureInPictureOwnershipTests: XCTestCase {
    func testRetiredCallbacksCannotAdvanceOrControlReplacement() {
        var session = PictureInPictureSession()
        let first = UUID(), second = UUID()
        let old = session.begin(owner: first)!
        session.advance(.active, token: old)
        XCTAssertNil(session.begin(owner: first), "Double entry must not create another presentation")
        XCTAssertFalse(session.owns(old, owner: second))
        session.finish()
        let current = session.begin(owner: second)!
        session.advance(.returning, token: old)
        XCTAssertEqual(session.phase, .preparing)
        XCTAssertFalse(session.owns(old, owner: first))
        XCTAssertTrue(session.owns(current, owner: second))
        session.finish()
        session.advance(.active, token: current)
        XCTAssertFalse(session.isPresented)
    }
}

@MainActor final class PictureInPictureNativeTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool, timeout: Double = 8, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("PiP native condition timed out", line: line)
        throw NSError(domain: "PiPNativeGate", code: 1)
    }
    func testUnavailableSurfaceCannotEnter() {
        let coordinator = PlayerPictureInPictureCoordinator { _, _ in XCTFail("No player may be controlled") }
        coordinator.toggle()
        XCTAssertFalse(coordinator.canEnter)
        XCTAssertFalse(coordinator.isPresented)
        coordinator.end(); coordinator.returnToPlayer()
        XCTAssertFalse(coordinator.isPresented)
    }
    func testSameDimensionsReloadRestoresReadinessAfterMediaReset() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"] else {
            throw XCTSkip("Requires the synthetic PiP fixture")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        try await player.enableLocalRenderDiagnosticsForTesting()
        let coordinator = PlayerPictureInPictureCoordinator { _, _ in }
        var latest = PlayerSnapshot(), latestRequest: UUID?
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, let request) = event {
                    latest = snapshot; latestRequest = request
                    coordinator.update(snapshot: snapshot, title: "Same-size media reload")
                }
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 140, y: 160, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = MPVRenderHostView(player: player, pictureInPicture: coordinator,
            onError: { XCTFail($0.localizedDescription) }, onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        do {
            try await waitFor { host.surface.isReadyForPictureInPicture }
            for site in ["pip-fixture", "live", "live", "live-catchup"] {
                let request = UUID()
                let media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], siteKey: site, sourceName: "Synthetic", episodeName: site)
                try await player.load(media, startPosition: nil, requestID: request)
                try await waitFor { latestRequest == request && latest.status == .playing && latest.position > 0.1 }
                XCTAssertGreaterThan(latest.videoWidth, 0, "Same-size \(site) reload must repopulate display width")
                XCTAssertGreaterThan(latest.videoHeight, 0)
                try await waitFor { coordinator.canEnter }
                try await player.pause()
                try await waitFor { latest.status == .paused }
                XCTAssertTrue(coordinator.canEnter, "Readiness must also survive pausing the new channel")
            }
            coordinator.end(); host.tearDown(); window.close(); reader.cancel(); await player.shutdown()
        } catch {
            NSLog("[PiP-TEST] reload failure: request=%@ status=%@ position=%f dimensions=%dx%d visible=%d occlusion=%lu render=%@", String(describing: latestRequest), String(describing: latest.status), latest.position, latest.videoWidth, latest.videoHeight, window.isVisible, window.occlusionState.rawValue, host.surface.readinessDiagnosticsForTesting)
            coordinator.end(); host.tearDown(); window.close(); reader.cancel(); await player.shutdown(); throw error
        }
    }

    private func renderHost(in view: NSView?) -> MPVRenderHostView? {
        if let host = view as? MPVRenderHostView { return host }
        for child in view?.subviews ?? [] {
            if let found = renderHost(in: child) { return found }
        }
        return nil
    }
    private struct HostedPlayer: View {
        @ObservedObject var state: AppState
        let player: MPVPlayerClient
        var body: some View {
            ZStack {
                MPVRenderView(player: player, onError: { XCTFail($0.localizedDescription) },
                    onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in },
                    pictureInPicture: state.pictureInPicture)
                PlayerPictureInPictureButton(coordinator: state.pictureInPicture)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    func testSwiftUIWindowTeardownCannotPublishIntoDestroyingViewGraph() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"] else {
            throw XCTSkip("Requires the synthetic PiP fixture and an unlocked desktop")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        try await player.enableLocalRenderDiagnosticsForTesting()
        let state = AppState(environment: nil)
        let coordinator = state.pictureInPicture // Keep the real AppState forwarding subscription.
        guard coordinator.isAvailable else { await player.shutdown(); throw XCTSkip("Native PiP unavailable") }
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event { coordinator.update(snapshot: snapshot, title: "SwiftUI lifecycle fixture") }
            }
        }
        var inTeardown = false, synchronousNotifications = 0, notifications = 0
        let observation = state.objectWillChange.sink {
            notifications += 1
            if inTeardown { synchronousNotifications += 1 }
        }
        defer { observation.cancel(); reader.cancel() }
        let media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], siteKey: "pip-fixture", sourceName: "Synthetic", episodeName: "Synthetic")
        for _ in 0..<3 {
            let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 640, height: 360),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var hosting: NSHostingView<AnyView>? = NSHostingView(rootView: AnyView(HostedPlayer(state: state, player: player)))
            hosting?.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            hosting?.autoresizingMask = [.width, .height]
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            do {
                try await waitFor { self.renderHost(in: hosting)?.surface.isReadyForPictureInPicture == true }
                try await player.load(media, startPosition: nil, requestID: UUID())
                try await waitFor { coordinator.canEnter }
                coordinator.toggle()
                try await waitFor { coordinator.session.phase == .active }
                coordinator.returnToPlayer()
                try await waitFor { !coordinator.isPresented }
                // Match the production crash: the hosting tree owns the representable,
                // and dismantling it changes readiness while AppState is observed.
                try await waitFor { coordinator.canEnter }
                weak var retiredSurface = self.renderHost(in: hosting)
                let before = notifications
                inTeardown = true
                autoreleasepool {
                    // Explicitly destroy the SwiftUI subtree before releasing the
                    // window; AppKit can otherwise retain a closed hosting view.
                    hosting?.rootView = AnyView(EmptyView())
                    hosting?.layoutSubtreeIfNeeded()
                    window.close(); window.contentView = nil; hosting = nil
                }
                inTeardown = false
                do {
                    try await waitFor { retiredSurface == nil && !coordinator.canEnter && notifications > before }
                } catch {
                    XCTFail("Teardown state: surfaceRetained=\(retiredSurface != nil) canEnter=\(coordinator.canEnter) notifications=\(notifications) before=\(before)")
                    throw error
                }
                XCTAssertEqual(synchronousNotifications, 0, "Never notify SwiftUI synchronously during NSViewRepresentable teardown")
                XCTAssertFalse(coordinator.isPresented)
                XCTAssertNil(coordinator.errorMessage)
            } catch {
                inTeardown = false; coordinator.end(); window.contentView = nil; hosting = nil; window.close()
                reader.cancel(); await player.shutdown(); throw error
            }
        }
        reader.cancel(); await player.shutdown()
    }
    func testSameRendererPlaybackPauseReplacementAndTeardown() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"] else {
            throw XCTSkip("Requires an explicit synthetic PiP fixture and an unlocked desktop")
        }
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        try await player.enableLocalRenderDiagnosticsForTesting()
        let coordinator = PlayerPictureInPictureCoordinator { playing, _ in
            Task { if playing { try await player.play() } else { try await player.pause() } }
        }
        guard coordinator.isAvailable else { await player.shutdown(); throw XCTSkip("Native PiP is unavailable on this OS") }
        var latest = PlayerSnapshot(), errors: [String] = []
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event {
                    latest = snapshot; coordinator.update(snapshot: snapshot, title: "Synthetic PiP acceptance")
                }
            }
        }
        let state = AppState(environment: nil)
        state.pictureInPicture = coordinator
        state.isPlayerPresented = true
        let windowController = PlayerPlaybackWindowController(appState: state)
        windowController.prewarm()
        let window = try XCTUnwrap(windowController.windowForTesting)
        window.setContentSize(NSSize(width: 640, height: 360))
        let host = MPVRenderHostView(player: player, pictureInPicture: coordinator,
            onError: { errors.append($0.localizedDescription) }, onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do {
            try await waitFor { host.surface.isReadyForPictureInPicture }
            var media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], siteKey: "pip-fixture", sourceName: "Synthetic", episodeName: "Synthetic")
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await waitFor { coordinator.canEnter && latest.position > 0.5 }
            let subtitles = FileManager.default.temporaryDirectory.appendingPathComponent("PiP-fixture-\(UUID()).srt")
            try "1\n00:00:00,000 --> 00:00:12,000\nPiP synthetic subtitle\n".write(to: subtitles, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: subtitles) }
            try await player.addSubtitle(url: subtitles)
            try await waitFor { latest.tracks.contains { $0.type == .subtitle && $0.isSelected } }
            let selectedSubtitle = latest.tracks.first { $0.type == .subtitle && $0.isSelected }?.id
            let gl = host.surface.openGLContext
            try await waitFor { coordinator.canEnter }
            coordinator.toggle()
            try await waitFor { coordinator.session.phase == .active }
            XCTAssertTrue(host.surface.window !== window)
            let before = latest.position
            let framesBefore = host.surface.renderedFramesForTesting
            window.miniaturize(nil)
            try await waitFor { latest.position > before + 1 && host.surface.renderedFramesForTesting > framesBefore + 10 }
            XCTAssertTrue(window.isMiniaturized)
            XCTAssertTrue(coordinator.isPresented)
            XCTAssertTrue(host.surface.openGLContext === gl)
            coordinator.returnToPlayer()
            try await waitFor { !coordinator.isPresented && host.surface.window === window }
            XCTAssertFalse(window.isMiniaturized)
            XCTAssertEqual(latest.tracks.first { $0.type == .subtitle && $0.isSelected }?.id, selectedSubtitle)
            try await waitFor { coordinator.canEnter }
            coordinator.toggle()
            try await waitFor { coordinator.session.phase == .active }
            let framesBeforeClose = host.surface.renderedFramesForTesting
            window.performClose(nil)
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(state.isPlayerPresented, "Closing the main window must retain PiP playback")
            try await waitFor { host.surface.renderedFramesForTesting > framesBeforeClose + 10 }
            coordinator.returnToPlayer()
            try await waitFor { !coordinator.isPresented && window.isVisible }
            try await player.pause()
            try await waitFor { latest.status == .paused }
            let paused = latest.position
            try await waitFor { coordinator.canEnter }
            coordinator.toggle()
            try await waitFor { coordinator.session.phase == .active }
            coordinator.returnToPlayer()
            try await waitFor { !coordinator.isPresented }
            XCTAssertEqual(latest.position, paused, accuracy: 0.1)
            XCTAssertTrue(host.surface.openGLContext === gl)
            window.toggleFullScreen(nil)
            try await waitFor { WindowTransitionCoordinator.state(for: window).phase == .fullScreen }
            try await waitFor { coordinator.canEnter }
            coordinator.toggle()
            try await waitFor { coordinator.session.phase == .active }
            XCTAssertFalse(window.styleMask.contains(.fullScreen))
            // Source changes using the same client keep the same native PiP view.
            media.siteKey = "live"
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await waitFor { latest.status == .playing && latest.position > 0.5 }
            XCTAssertTrue(coordinator.isPresented)
            XCTAssertTrue(host.surface.openGLContext === gl)
            media.siteKey = "live-catchup"; media.playbackDurationLimit = 2
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await waitFor { latest.status == .ended }
            XCTAssertTrue(coordinator.isPresented)
            // Client replacement retires callbacks and restores the old surface first.
            coordinator.playerWillChange(to: UUID())
            XCTAssertFalse(coordinator.isPresented)
            XCTAssertTrue(host.surface.superview === host)
            XCTAssertTrue(host.surface.openGLContext === gl)
            host.tearDown()
            XCTAssertFalse(coordinator.canEnter)
            XCTAssertNil(coordinator.errorMessage)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            reader.cancel(); window.close(); await player.shutdown()
        } catch {
            NSLog("[PiP-TEST] native failure: status=%@ position=%f dimensions=%dx%d canEnter=%d visible=%d occlusion=%lu render=%@", String(describing: latest.status), latest.position, latest.videoWidth, latest.videoHeight, coordinator.canEnter, window.isVisible, window.occlusionState.rawValue, host.surface.readinessDiagnosticsForTesting)
            coordinator.end(); host.tearDown(); reader.cancel(); window.close(); await player.shutdown(); throw error
        }
    }
}
