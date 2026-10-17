import AppKit
import QuartzCore
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class FullscreenRecoveryTests: XCTestCase {
    private final class Window: NSWindow {
        var resizing = false
        var toggles = 0
        override var inLiveResize: Bool { resizing }
        override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
    }
    private func makeWindow() -> Window {
        let window = Window(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    func testMissingCompletionReleasesUIAndAcceptsNextToggle() async {
        for entering in [true, false] {
            let window = makeWindow(); defer { window.close() }
            let state = WindowTransitionCoordinator.state(for: window)
            let originalFrame = window.frame, originalStyle = window.styleMask
            var cleanup = 0, deferred = 0
            state.onFullScreenRecovery = { _ in cleanup += 1 }
            state.beginFullScreen(entering: entering)
            state.whenStable(key: UUID()) { _ in deferred += 1 }
            await drain()
            XCTAssertEqual(deferred, 0)
            XCTAssertFalse(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime))
            XCTAssertTrue(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
            await drain()
            XCTAssertTrue(state.canChangeGeometry)
            XCTAssertEqual(cleanup, 1); XCTAssertEqual(deferred, 1)
            XCTAssertEqual(window.frame, originalFrame); XCTAssertEqual(window.styleMask, originalStyle)
            XCTAssertEqual(window.toggles, 0, "Recovery must not start a retry loop")
            state.requestFullScreenToggle(); await drain()
            XCTAssertEqual(window.toggles, 1)
            state.fullScreenDidFail()
        }
    }
    func testNativeResizeMustEndBeforeRecoveryAndCloseCancelsRecovery() {
        let window = makeWindow(); defer { window.close() }
        let state = WindowTransitionCoordinator.state(for: window)
        state.beginFullScreen(entering: true)
        window.resizing = true
        XCTAssertFalse(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
        XCTAssertTrue(state.isTransitioning)
        window.resizing = false
        XCTAssertTrue(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
        state.beginFullScreen(entering: true)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
    }
    func testSuccessfulCompletionDisarmsRecovery() {
        let window = makeWindow(); defer { window.close() }
        let state = WindowTransitionCoordinator.state(for: window)
        state.onFullScreenRecovery = { _ in XCTFail("Completed transition must not recover") }
        state.beginFullScreen(entering: true)
        state.completeFullScreen(isFullScreen: true)
        XCTAssertFalse(state.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
        XCTAssertFalse(state.isTransitioning)
    }
}

@MainActor final class FullscreenOverlayLifecycleTests: XCTestCase {
    private func makeWindow() -> (NSWindow, PlayerFullscreenOverlayView) {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 960, height: 540),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let overlay = PlayerFullscreenOverlayView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(overlay)
        return (window, overlay)
    }
    private func drain() async {
        for _ in 0..<6 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    func testNativePhaseHidesBeforeResizeAndRestoresAfterCompletion() async {
        let (window, overlay) = makeWindow(); defer { window.close() }
        let transition = WindowTransitionCoordinator.state(for: window)
        for entering in [true, false] {
            transition.beginFullScreen(entering: entering)
            XCTAssertEqual(overlay.alphaValue, 0)
            window.setContentSize(entering ? .init(width: 1440, height: 900) : .init(width: 960, height: 540))
            await drain()
            XCTAssertEqual(overlay.alphaValue, 0)
            XCTAssertTrue(CATransform3DIsIdentity(overlay.layer!.transform))
            transition.completeFullScreen(isFullScreen: entering)
            XCTAssertEqual(overlay.alphaValue, 0, "Completion must not expose a pending SwiftUI layout")
            await drain()
            XCTAssertEqual(overlay.alphaValue, 1)
            XCTAssertEqual(overlay.frame, window.contentView!.bounds)
        }
    }
    func testRapidToggleRejectsOldRevealAndFailureRecovers() async {
        let (window, overlay) = makeWindow(); defer { window.close() }
        let transition = WindowTransitionCoordinator.state(for: window)
        transition.beginFullScreen(entering: true)
        transition.completeFullScreen(isFullScreen: true)
        transition.beginFullScreen(entering: false)
        await drain()
        XCTAssertEqual(overlay.alphaValue, 0)
        transition.fullScreenDidFail()
        await drain()
        XCTAssertEqual(overlay.alphaValue, 1)
        transition.beginFullScreen(entering: true)
        XCTAssertTrue(transition.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime + 6))
        await drain()
        XCTAssertEqual(overlay.alphaValue, 1)
    }
    func testClosingOrMovingOverlayInvalidatesPendingReveal() async {
        let (window, overlay) = makeWindow(); defer { window.close() }
        let (other, _) = makeWindow(); defer { other.close() }
        let transition = WindowTransitionCoordinator.state(for: window)
        transition.beginFullScreen(entering: true)
        transition.completeFullScreen(isFullScreen: true)
        overlay.removeFromSuperview()
        WindowTransitionCoordinator.state(for: other).beginFullScreen(entering: true)
        other.contentView!.addSubview(overlay)
        await drain()
        XCTAssertEqual(overlay.alphaValue, 0, "The old window cannot reveal controls in the new transition")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        await drain()
        XCTAssertEqual(overlay.alphaValue, 1)
        XCTAssertNil(overlay.layer?.animation(forKey: "com.okvideomac.controls.reveal"))
    }
    func testAlreadyHiddenOverlayRemainsHiddenAfterTransition() async {
        let (window, overlay) = makeWindow(); defer { window.close() }
        overlay.alphaValue = 0
        let transition = WindowTransitionCoordinator.state(for: window)
        transition.beginFullScreen(entering: true)
        transition.completeFullScreen(isFullScreen: true)
        await drain()
        XCTAssertEqual(overlay.alphaValue, 0)
    }
}

@MainActor final class FullscreenPlaybackTests: XCTestCase {
    private func renderHost(in view: NSView) -> MPVRenderHostView? {
        if let host = view as? MPVRenderHostView { return host }
        for child in view.subviews {
            if let host = renderHost(in: child) { return host }
        }
        return nil
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Fullscreen playback condition timed out", line: line)
        throw NSError(domain: "FullscreenPlayback", code: 1)
    }

    /// The upper-right portion of the isolated overlay contains only the card.
    /// A stray centered live title also expands these bounds and fails the check.
    private func renderedProgrammeBounds(_ bitmap: NSBitmapImageRep, viewport: NSSize) throws -> NSRect {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in stride(from: 0, to: bitmap.pixelsHigh / 3, by: 2) {
            for x in stride(from: bitmap.pixelsWide / 2, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      max(color.redComponent, color.greenComponent, color.blueComponent) > 0.03 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            XCTFail("Programme card was not rendered")
            throw NSError(domain: "FullscreenPlayback", code: 2)
        }
        let sx = CGFloat(bitmap.pixelsWide) / viewport.width, sy = CGFloat(bitmap.pixelsHigh) / viewport.height
        return NSRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
            width: CGFloat(maxX + 1 - minX) / sx, height: CGFloat(maxY + 1 - minY) / sy)
    }

    func testLiveUsesNativeFullscreenWithContinuousPlayback() async throws { try await exercise(live: true) }
    func testOnDemandKeepsCustomFullscreenWithContinuousPlayback() async throws { try await exercise(live: false) }

    private func exercise(live: Bool) async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"] else {
            throw XCTSkip("Requires the synthetic video fixture and an unlocked desktop")
        }
        let state = AppState(environment: nil)
        state.playerWindowPreferences.setMode(.automaticAspect)
        if live {
            let source = StoredLiveSource(name: "Fullscreen fixture", sourceKind: .pasted, rawData: Data())
            let channel = LiveChannel(groupName: "Fixture", name: "Live fullscreen", streams: [
                LiveStream(name: "Fixture", url: URL(fileURLWithPath: fixture))])
            state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u,
                groups: [.init(name: "Fixture", channels: [channel])]))
            state.importedRouteLoadForTesting = { _, _, _ in }
            await state.playImportedLive(state.acceptedImportedCatalogs[source.id]!.selections(for: channel)[0], navigationChannels: [channel])
            let liveSource = LiveSourceID.imported(source.id), now = Date()
            let generation = state.liveEPG.prepare(source: liveSource, revision: "fixture")
            let incarnation = UUID(), demand = UUID()
            XCTAssertTrue(state.liveEPG.publish(.init(token: .init(serviceIncarnation: incarnation,
                resourceIdentity: "fixture", sourceEpoch: "fixture", dataVersion: "1", demandRevision: demand),
                items: [.init(match: .init(kind: .exact, channelID: "fixture"),
                    current: .init(channelID: "fixture", title: "当前节目 · 自然与旅行", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)),
                    next: .init(channelID: "fixture", title: "下一节目 · 晚间新闻", start: now.addingTimeInterval(900), end: now.addingTimeInterval(2700)))]),
                channels: [channel], source: liveSource, revision: "fixture", generation: generation,
                demandRevision: demand, serviceIncarnation: incarnation))
        } else {
            state.seedHistoryPlaybackForTesting(configuration: .init(name: "Fullscreen fixture", sourceKind: .pasted,
                rawData: Data("{}".utf8)), position: 0, duration: 120)
        }
        XCTAssertEqual(state.isLivePlayback, live)
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        var latest = PlayerSnapshot(), errors: [String] = []
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event {
                    latest = snapshot
                    state.playerSnapshotState.update(snapshot)
                }
            }
        }
        let controller = PlayerPlaybackWindowController(appState: state)
        controller.prewarm()
        let window = try XCTUnwrap(controller.windowForTesting)
        window.setContentSize(.init(width: 960, height: 540))
        let content = try XCTUnwrap(window.contentView)
        let composition = try XCTUnwrap(content.subviews.compactMap { $0 as? PlayerFullscreenContentView }.first)
        let overlay = try XCTUnwrap(content.subviews.compactMap { $0 as? PlayerFullscreenOverlayView }.first)
        // Match the production window's finite AppKit container and retained
        // hosting controller, including the SwiftUI-owned render host.
        let videoController = NSHostingController(rootView: ZStack {
            Color.black
            MPVRenderView(player: player, onError: { errors.append($0.localizedDescription) },
                onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
                .ignoresSafeArea().allowsHitTesting(false)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black))
        if #available(macOS 13.0, *) { videoController.sizingOptions = [] }
        let videoView = videoController.view
        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.frame = composition.bounds; videoView.autoresizingMask = [.width, .height]
        composition.addSubview(videoView)
        let host = PlayerOverlayHostingView(rootView: PlayerView(playerSnapshotState: state.playerSnapshotState,
            onWindowChromeRestored: {}).environmentObject(state))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.frame = overlay.bounds; host.autoresizingMask = [.width, .height]; overlay.addSubview(host)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let transition = WindowTransitionCoordinator.state(for: window)
        try await waitFor { self.renderHost(in: composition) != nil }
        let renderHost = try XCTUnwrap(renderHost(in: composition))
        let surface = renderHost.surface
        do {
            try await waitFor { surface.canAnimateFullscreen }
            let media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], siteKey: live ? "live" : "fullscreen-fixture",
                sourceName: "Synthetic", episodeName: "Fullscreen")
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await waitFor { latest.status == .playing && latest.position > 0.1 }
            let context = surface.openGLContext
            if live {
                XCTAssertNil(controller.customWindowsToEnterFullScreen(for: window, on: try XCTUnwrap(window.screen)))
            }
            // Exercise the neutral prewarmed shell, fixed sizing, automatic
            // aspect, and switching back to fixed sizing while paused.
            for round in 0..<4 {
                if round > 0 {
                    let mode: PlayerWindowMode = round == 2 ? .automaticAspect : .fixedFrame
                    state.playerWindowPreferences.setMode(mode)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    try await waitFor {
                        mode == .fixedFrame ? window.contentAspectRatio == .zero : window.contentAspectRatio.width > 0
                    }
                }
                if round == 3 { try await player.pause(); try await waitFor { latest.status == .paused } }
                let originalFrame = window.frame
                let position = latest.position
                for entering in [true, false] {
                    NSLog("FullscreenPlayback live=%@ round=%d entering=%@ frame=%@ min=%@ max=%@ aspect=%@",
                        String(live), round, String(entering), NSStringFromRect(window.frame),
                        NSStringFromSize(window.contentMinSize), NSStringFromSize(window.contentMaxSize),
                        NSStringFromSize(window.contentAspectRatio))
                    transition.requestFullScreenToggle()
                    try await waitFor { transition.phase == (entering ? .enteringFullScreen : .exitingFullScreen) }
                    XCTAssertEqual(overlay.alphaValue, 0)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if transition.isTransitioning { XCTAssertEqual(overlay.alphaValue, 0) }
                    if live {
                        XCTAssertNil(composition.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
                        XCTAssertNil(content.layer?.mask, "Native live transition must not acquire the custom video mask")
                    }
                    try await waitFor { transition.phase == (entering ? .fullScreen : .windowed) && !transition.isTransitioning && overlay.alphaValue == 1 }
                    XCTAssertEqual(window.styleMask.contains(.fullScreen), entering)
                    XCTAssertTrue(surface.openGLContext === context)
                    XCTAssertTrue(surface.superview === renderHost)
                    XCTAssertTrue(renderHost.isDescendant(of: composition))
                    XCTAssertTrue(host.superview === overlay)
                    XCTAssertEqual(host.frame, overlay.bounds)
                    XCTAssertTrue(CATransform3DIsIdentity(overlay.layer!.transform))
                    try await Task.sleep(nanoseconds: 180_000_000)
                    if live && round == 0 {
                        host.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        // Measure the actual SwiftUI rendering: removing the live
                        // header must not anchor this card to the control row.
                        let card = try renderedProgrammeBounds(bitmap, viewport: host.bounds.size)
                        let layout = PlayerOverlayLayout(viewportSize: host.bounds.size)
                        XCTAssertEqual(host.bounds.width - card.maxX, layout.programmeTrailingInset, accuracy: 2,
                            "Programme card must align with the inset control content")
                        XCTAssertEqual(card.minY, layout.programmeTopInset + (entering ? (window.screen?.safeAreaInsets.top ?? 0) : 0), accuracy: 2)
                        if !entering {
                            XCTAssertEqual(host.bounds.width - card.maxX, 40, accuracy: 2)
                            XCTAssertEqual(card.minY, 44, accuracy: 2)
                        }
                        XCTAssertEqual(card.width, 310, accuracy: 2, "Original programme card width must be retained")
                        let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                        image.name = entering ? "live-programme-fullscreen" : "live-programme-windowed"
                        image.lifetime = .keepAlways
                        add(image)
                    }
                }
                if round < 3 { XCTAssertGreaterThan(latest.position, position + 0.2) }
                else { XCTAssertEqual(latest.position, position, accuracy: 0.1) }
                XCTAssertEqual(window.frame.width, originalFrame.width, accuracy: 1)
                XCTAssertEqual(window.frame.height, originalFrame.height, accuracy: 1)
                XCTAssertTrue(errors.isEmpty, "Render errors: \(errors)")
            }
            withExtendedLifetime(videoController) {}
            surface.tearDown(); controller.dismiss(); reader.cancel(); await player.shutdown(); await state.closePlayer()
        } catch {
            surface.tearDown(); controller.dismiss(); reader.cancel(); await player.shutdown(); await state.closePlayer(); throw error
        }
    }
}

@MainActor final class FullscreenCompositionTests: XCTestCase {
    // Direct lifecycle tests invoke the delegate without entering a Space.
    // Real fullscreen windows are not constrained to the desktop's Dock/menu
    // rectangle; give this fixture the same geometry contract.
    private final class AnimationWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    private struct Surface: NSViewRepresentable {
        let view: MPVOpenGLView
        func makeNSView(context: Context) -> MPVOpenGLView { view }
        func updateNSView(_ nsView: MPVOpenGLView, context: Context) {}
    }
    private func withComposition(_ run: (NSWindow, PlayerFullscreenContentView, MPVOpenGLView, NSButton, PlayerFullscreenPresentation) async throws -> Void) async throws {
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, renderControlMode: .advanced)
        try await player.setMuted(true)
        let window = AnimationWindow(contentRect: NSRect(x: 150, y: 160, width: 640, height: 420),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.contentView?.wantsLayer = true
        window.level = .floating
        var ready = false
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) },
            onSurfaceReady: { _ in ready = true }, onSurfaceUnavailable: { _ in })
        let container = PlayerFullscreenContentView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView?.addSubview(container)
        // Exercise the actual NSHostingView + representable hierarchy used by
        // production, not just two CALayers with equivalent transforms.
        let root = ZStack {
            Color.black
            Surface(view: surface).ignoresSafeArea()
        }
        let host = NSHostingView(rootView: root)
        host.frame = container.bounds; host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let overlay = PlayerFullscreenOverlayView(frame: container.frame)
        window.contentView?.addSubview(overlay)
        let controls = PlayerOverlayHostingView(rootView: VStack {
            Text("原生控制层同步验收").foregroundColor(.white)
            Spacer()
            Slider(value: .constant(0.4)).padding(40)
        }.ignoresSafeArea())
        controls.frame = overlay.bounds; controls.autoresizingMask = [.width, .height]
        overlay.addSubview(controls)
        let button = NSButton(title: "播放", target: nil, action: nil)
        button.frame = NSRect(x: 280, y: 12, width: 80, height: 28)
        button.wantsLayer = true; overlay.addSubview(button)
        let presentation = PlayerFullscreenPresentation()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            for _ in 0..<100 where !ready { try await Task.sleep(nanoseconds: 30_000_000) }
            XCTAssertTrue(ready, "A real OpenGL drawable must be ready; visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) window=\(window.frame) surface=\(surface.bounds) visibleRect=\(surface.visibleRect) overlayOpaque=\(overlay.isOpaque) controlsOpaque=\(controls.isOpaque) render=\(surface.readinessDiagnosticsForTesting)")
            try await run(window, container, surface, button, presentation)
        } catch {
            presentation.cancel(); surface.tearDown(); window.close(); await player.shutdown(); throw error
        }
        presentation.cancel(); surface.tearDown(); window.close(); await player.shutdown()
    }
    private func waitForAnimation(_ container: NSView) async throws -> CABasicAnimation {
        for _ in 0..<100 {
            if let animation = container.layer?.animation(forKey: "com.okvideomac.video.fullscreen") as? CABasicAnimation { return animation }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        func tree(_ view: NSView) -> String { "\(type(of:view)): frame=\(view.frame) bounds=\(view.bounds) animations=\(view.layer?.animationKeys() ?? [])\n" + view.subviews.map(tree).joined() }
        return try XCTUnwrap(nil as CABasicAnimation?, "Shared composition must receive fullscreen animation; window=\(String(describing: container.window?.frame)) tree=\(tree(container))")
    }
    func testVideoScalesWhileControlsWaitForSettledLayoutAtFixedSize() async throws {
        try await withComposition { window, container, surface, button, presentation in
            let original = window.frame
            let originalOpaque = window.isOpaque
            let originalShadow = window.hasShadow
            XCTAssertTrue(presentation.prepareToEnter(window: window, surface: surface, aspectRatio: 4.0/3, presentationView: container))
            let transition = WindowTransitionCoordinator.state(for: window)
            transition.beginFullScreen(entering: true)
            presentation.startEntering(window: window, screen: try XCTUnwrap(window.screen), duration: 2)
            let animation = try await self.waitForAnimation(container)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            XCTAssertFalse(window.hasShadow)
            let mask = try XCTUnwrap(window.contentView?.layer?.mask as? CAShapeLayer)
            let clipping = try XCTUnwrap(mask.animation(forKey: "com.okvideomac.fullscreen.viewport") as? CABasicAnimation)
            let initialClip = (try XCTUnwrap(clipping.fromValue) as! CGPath).boundingBoxOfPath
            XCTAssertEqual(initialClip.size.width, original.width, accuracy: 1)
            XCTAssertEqual(clipping.duration, animation.duration, accuracy: 0.001)
            let from = try XCTUnwrap(animation.fromValue as? NSValue).caTransform3DValue
            XCTAssertGreaterThan(from.m11, 0); XCTAssertLessThan(from.m11, 1)
            XCTAssertEqual(from.m11, from.m22, accuracy: 0.000001)
            XCTAssertTrue(surface.isDescendant(of: container))
            let overlay = try XCTUnwrap(button.superview as? PlayerFullscreenOverlayView)
            XCTAssertFalse(overlay.isDescendant(of: container), "Controls must not inherit video scaling")
            XCTAssertTrue(CATransform3DIsIdentity(overlay.layer!.transform))
            XCTAssertNil(surface.layer?.animation(forKey: "com.okvideomac.video.fullscreen"), "Never scale video a second time")
            XCTAssertTrue(CATransform3DIsIdentity(surface.layer!.transform))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(button.frame.size, NSSize(width: 80, height: 28))
            XCTAssertEqual(overlay.alphaValue, 0, "Intermediate SwiftUI layouts must not flash during video animation")
            XCTAssertTrue(CATransform3DIsIdentity(overlay.layer!.transform))
            let live = try XCTUnwrap(container.layer?.presentation()).transform
            XCTAssertGreaterThan(live.m11, from.m11); XCTAssertLessThan(live.m11, 1)
            XCTAssertEqual(live.m11, live.m22, accuracy: 0.000001)
            presentation.complete(window: window, isFullScreen: true); transition.completeFullScreen(isFullScreen: true)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(overlay.alphaValue, 1)
            XCTAssertTrue(CATransform3DIsIdentity(container.layer!.transform))
            XCTAssertEqual(window.isOpaque, originalOpaque)
            XCTAssertEqual(window.hasShadow, originalShadow)
            XCTAssertEqual(window.backgroundColor, NSColor.black)
            XCTAssertNil(window.contentView?.layer?.mask)
            XCTAssertNil(container.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
            XCTAssertTrue(presentation.prepareToExit(window: window, surface: surface, aspectRatio: 4.0/3))
            transition.beginFullScreen(entering: false)
            presentation.startExiting(window: window, duration: 2)
            let exiting = try await self.waitForAnimation(container)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            XCTAssertNotNil(window.contentView?.layer?.mask)
            let to = try XCTUnwrap(exiting.toValue as? NSValue).caTransform3DValue
            XCTAssertLessThan(to.m11, 1); XCTAssertEqual(to.m11, to.m22, accuracy: 0.000001)
            XCTAssertNil(surface.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
            presentation.complete(window: window, isFullScreen: false); transition.completeFullScreen(isFullScreen: false)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(overlay.alphaValue, 1)
            XCTAssertEqual(window.frame, original)
            XCTAssertEqual(overlay.frame, window.contentView?.bounds)
            XCTAssertEqual(button.frame.size, NSSize(width: 80, height: 28))
            XCTAssertTrue(CATransform3DIsIdentity(container.layer!.transform))
            XCTAssertEqual(window.isOpaque, originalOpaque)
            XCTAssertEqual(window.hasShadow, originalShadow)
            XCTAssertEqual(window.backgroundColor, NSColor.black)
            XCTAssertNil(window.contentView?.layer?.mask)
            XCTAssertNil(container.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
        }
    }
    func testFailureAndSurfaceTeardownCleanTheSharedLayer() async throws {
        try await withComposition { window, container, surface, _, presentation in
            let original = window.frame
            let originalOpaque = window.isOpaque
            let originalShadow = window.hasShadow
            XCTAssertTrue(presentation.prepareToEnter(window: window, surface: surface, aspectRatio: 16.0/9, presentationView: container))
            presentation.startEntering(window: window, screen: try XCTUnwrap(window.screen), duration: 2)
            _ = try await self.waitForAnimation(container)
            presentation.failed(window: window)
            XCTAssertEqual(window.frame, original)
            XCTAssertNil(container.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
            XCTAssertTrue(CATransform3DIsIdentity(container.layer!.transform))
            XCTAssertEqual(window.isOpaque, originalOpaque)
            XCTAssertEqual(window.hasShadow, originalShadow)
            XCTAssertEqual(window.backgroundColor, NSColor.black)
            XCTAssertNil(window.contentView?.layer?.mask)
            XCTAssertTrue(presentation.prepareToEnter(window: window, surface: surface, aspectRatio: 9.0/16, presentationView: container))
            presentation.startEntering(window: window, screen: try XCTUnwrap(window.screen), duration: 2)
            _ = try await self.waitForAnimation(container)
            surface.tearDown()
            XCTAssertNil(container.layer?.animation(forKey: "com.okvideomac.video.fullscreen"))
            XCTAssertTrue(CATransform3DIsIdentity(container.layer!.transform))
            XCTAssertEqual(window.isOpaque, originalOpaque)
            XCTAssertEqual(window.hasShadow, originalShadow)
            XCTAssertEqual(window.backgroundColor, NSColor.black)
            XCTAssertNil(window.contentView?.layer?.mask)
            presentation.cancel()
        }
    }
    func testCancellationRestoresExistingWindowAndLayerAppearance() async throws {
        try await withComposition { window, container, surface, _, presentation in
            let rootLayer = try XCTUnwrap(window.contentView?.layer)
            let previousMask = CALayer()
            previousMask.frame = rootLayer.bounds
            previousMask.backgroundColor = NSColor.white.cgColor
            rootLayer.mask = previousMask
            rootLayer.backgroundColor = NSColor.darkGray.cgColor
            window.backgroundColor = .darkGray; window.isOpaque = false; window.hasShadow = false
            XCTAssertTrue(presentation.prepareToEnter(window: window, surface: surface, aspectRatio: 16.0/9, presentationView: container))
            presentation.startEntering(window: window, screen: try XCTUnwrap(window.screen), duration: 2)
            _ = try await self.waitForAnimation(container)
            XCTAssertFalse(rootLayer.mask === previousMask)
            presentation.cancel()
            XCTAssertTrue(rootLayer.mask === previousMask)
            XCTAssertEqual(rootLayer.backgroundColor, NSColor.darkGray.cgColor)
            XCTAssertEqual(window.backgroundColor, NSColor.darkGray)
            XCTAssertFalse(window.isOpaque); XCTAssertFalse(window.hasShadow)
            presentation.cancel()
            XCTAssertTrue(rootLayer.mask === previousMask)
        }
    }

    func testUnrelatedViewCannotOwnFullscreenAnimation() async throws {
        try await withComposition { window, _, surface, _, presentation in
            let unrelated = PlayerFullscreenContentView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            window.contentView?.addSubview(unrelated)
            XCTAssertFalse(presentation.prepareToEnter(window: window, surface: surface, aspectRatio: 1, presentationView: unrelated))
        }
    }
    func testProductionWindowMountsSharedNativeComposition() throws {
        let state = AppState(environment: nil)
        let controller = PlayerPlaybackWindowController(appState: state)
        controller.prewarm(); defer { controller.dismiss() }
        let content = try XCTUnwrap(controller.windowForTesting?.contentView)
        XCTAssertEqual(content.subviews.filter { $0 is PlayerFullscreenContentView }.count, 1)
        XCTAssertEqual(content.subviews.filter { $0 is PlayerFullscreenOverlayView }.count, 1)
    }
}

@MainActor
final class BrowserSplitDividerTests: XCTestCase {
    private func withBrowser(initialSection: AppSection = .settings, suppliedState: AppState? = nil, configureChromeImmediately: Bool = true, imageRepository: ImageRepository? = nil, _ run: (AppState, NSWindow) async throws -> Void) async throws {
        let state = suppliedState ?? AppState(environment: nil)
        state.selectSection(initialSection)
        let host = NSHostingController(rootView: RootView()
            .environment(\.imageRepository, imageRepository)
            .environmentObject(state).environmentObject(state.navigation))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1370, height: 780),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        if configureChromeImmediately { BrowserWindowChromeController.configure(window) }
        window.title = "OKVideoMac native sidebar verification"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await run(state, window)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func assertTitlebarMaterial(_ window: NSWindow, line: UInt = #line) throws {
        XCTAssertTrue(window.titlebarAppearsTransparent, line: line)
        let content = try XCTUnwrap(window.contentView)
        let backdrop = try XCTUnwrap(BrowserKeyboardView.descendants(of: content)
            .compactMap { $0 as? BrowserTitlebarMaterialView }.first)
        let painted = backdrop.materialView.convert(backdrop.materialView.bounds, to: nil)
        let contentTop = window.contentLayoutRect.maxY
        XCTAssertEqual(painted.minY, contentTop, accuracy: 0.5, line: line)
        XCTAssertEqual(painted.maxY, content.convert(content.bounds, to: nil).maxY, accuracy: 0.5, line: line)
        XCTAssertGreaterThan(painted.height, 0, line: line)
        XCTAssertEqual(backdrop.materialView.material, .titlebar, line: line)
        XCTAssertEqual(backdrop.materialView.blendingMode, .behindWindow, line: line)
        XCTAssertFalse(backdrop.materialView.isHiddenOrHasHiddenAncestor, line: line)
        XCTAssertNil(backdrop.hitTest(.zero), "The background must never intercept content clicks", line: line)
    }

    private func primarySplit(in window: NSWindow) throws -> NSSplitView {
        try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView)
            .compactMap { $0 as? NSSplitView }.first { split in
                split.isVertical && split.arrangedSubviews.count == 2 &&
                BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
                    .contains { $0 is BrowserSidebarOutlineView }
            })
    }

    func testActualWindowGroupStartupNavigationAndReopen() async throws {
        // This window is created by OKVideoMacApp.WindowGroup before XCTest,
        // unlike withBrowser's manually hosted windows. XCTest runtime data is
        // isolated by AppEnvironment.runtimeDirectories().
        var window: NSWindow?
        for _ in 0..<50 {
            window = AppWindowLayoutPolicy.window(for: .mainWindow)
            if window != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let original = try XCTUnwrap(window)
        XCTAssertNotNil(original.windowController)
        original.makeKeyAndOrderFront(nil)
        try await settle(original)
        let split = try primarySplit(in: original)
        let controller = try XCTUnwrap(split.delegate as? BrowserRootSplitController)
        let container = try XCTUnwrap(BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
            .compactMap { $0 as? NativeSidebarSourceList.ContainerView }.first)
        let button = controller.sidebarTitlebar.toggleButton
        let initial = button.convert(button.bounds, to: nil)
        let height = original.frame.height - original.contentLayoutRect.height
        // Cross the reported eight-second startup interval while exercising
        // real native navigation callbacks and SwiftUI toolbar updates.
        for _ in 0..<4 {
            for row in 0..<container.outlineView.numberOfRows {
                container.outlineView.onActivateRow?(row)
                try await Task.sleep(nanoseconds: 450_000_000)
                original.layoutIfNeeded()
                XCTAssertFalse(try XCTUnwrap(original.toolbar).items.isEmpty)
                XCTAssertEqual(original.titlebarAccessoryViewControllers.filter { $0 is BrowserSidebarTitlebarController }.count, 1)
                XCTAssertEqual(original.frame.height - original.contentLayoutRect.height, height, accuracy: 0.5)
                let current = button.convert(button.bounds, to: nil)
                XCTAssertEqual(current.minX, initial.minX, accuracy: 0.5)
                XCTAssertEqual(current.midY, initial.midY, accuracy: 0.5)
            }
        }
        func newWindowCommand(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "n", item.keyEquivalentModifierMask == .command,
                   item.action != nil { return (menu, index) }
                if let submenu = item.submenu, let match = newWindowCommand(in: submenu) { return match }
            }
            return nil
        }
        let command = try XCTUnwrap(newWindowCommand(in: try XCTUnwrap(NSApp.mainMenu)))
        original.close()
        command.0.performActionForItem(at: command.1)
        var reopened: NSWindow?
        for _ in 0..<50 {
            reopened = NSApp.windows.first { $0 !== original && $0.isVisible &&
                $0.identifier == AppWindowLayoutPolicy.descriptor(for: .mainWindow).identifier }
            if reopened != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let next = try XCTUnwrap(reopened, "The real WindowGroup must reopen through its New Window command")
        try await settle(next)
        let nextController = try XCTUnwrap(try primarySplit(in: next).delegate as? BrowserRootSplitController)
        XCTAssertEqual(next.titlebarAccessoryViewControllers.filter { $0 is BrowserSidebarTitlebarController }.count, 1)
        XCTAssertTrue(nextController.sidebarTitlebar.toggleButton.target === nextController)
        nextController.sidebarTitlebar.toggleButton.performClick(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(nextController.splitViewItems[0].isCollapsed)
        nextController.sidebarTitlebar.toggleButton.performClick(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(nextController.splitViewItems[0].isCollapsed)
    }

    private func attachWindowSnapshot(_ window: NSWindow, name: String) throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStartupRestoresEmptyValidAndInvalidStoredConfigurations() async throws {
        for data: Data? in [nil, Data("{\"sites\":[]}".utf8), Data("invalid configuration".utf8)] {
            let environment = try AppEnvironment.live()
            if let data {
                try await environment.database.saveConfiguration(StoredConfiguration(
                    name: "Startup fixture", sourceKind: .pasted, rawData: data, isActive: true))
            }
            let state = AppState(environment: environment)
            try await withBrowser(initialSection: .home, suppliedState: state) { state, window in
                try await self.settle(window)
                let height = window.frame.height - window.contentLayoutRect.height
                XCTAssertEqual(window.toolbar?.items.count, 2)
                await state.start()
                try await self.settle(window)
                XCTAssertTrue(state.hasCompletedStartup)
                XCTAssertFalse(try XCTUnwrap(window.toolbar).items.isEmpty)
                XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, height, accuracy: 0.5)
                try self.attachWindowSnapshot(window, name: "startup-\(data == nil ? "fresh" : state.activeConfiguration == nil ? "invalid" : "restored")")
            }
            await state.shutdown()
        }
    }

    func testSplitControllerDoesNotInstallOrRestoreWindowToolbar() async throws {
        let controller = BrowserRootSplitController()
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 700),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        BrowserWindowChromeController.configure(window)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(window)
        XCTAssertNil(window.toolbar, "Attaching sidebar chrome must not create an AppKit toolbar")
        for _ in 0..<3 {
            window.toolbar = NSToolbar(identifier: "toolbar-owner-fixture")
            window.toolbar = nil
            XCTAssertNil(window.toolbar, "Never reenter the owner's toolbar removal synchronously")
            try await settle(window)
            XCTAssertNil(window.toolbar, "Deferring the fallback would still violate toolbar ownership")
        }
    }

    func testLoadingHomeHasRealToolbarAndSearchDoesNotMergeHomeItems() async throws {
        try await withBrowser(initialSection: .home) { state, window in
            XCTAssertNil(state.activeConfiguration)
            XCTAssertFalse(state.hasCompletedStartup)
            try await self.settle(window)
            let controller = try XCTUnwrap(try self.primarySplit(in: window).delegate as? BrowserRootSplitController)
            let button = controller.sidebarTitlebar.toggleButton
            let position = button.convert(button.bounds, to: nil)
            let height = window.frame.height - window.contentLayoutRect.height
            let homeItems = try XCTUnwrap(window.toolbar).items
            // Actual production title + principal spacer; no provider group.
            XCTAssertEqual(homeItems.count, 2)
            try self.attachWindowSnapshot(window, name: "home-loading-toolbar")
            for iteration in 0..<3 {
                state.presentHomeSearch()
                try await self.settle(window)
                XCTAssertTrue(state.isHomeSearchPresented)
                let searchItems = try XCTUnwrap(window.toolbar).items
                XCTAssertGreaterThan(searchItems.count, homeItems.count)
                // System flexible-space identifiers are shared, unlike the
                // actual home title. Do not treat spacing as a leaked page item.
                let homeTitleIDs = Set(homeItems.map(\.itemIdentifier)).subtracting([.flexibleSpace, .space])
                XCTAssertEqual(homeTitleIDs.count, 1)
                XCTAssertTrue(homeTitleIDs.isDisjoint(with: searchItems.map(\.itemIdentifier)))
                // Compare against SearchView hosted on its own, so a parent
                // title or action group cannot hide behind regenerated IDs.
                let reference = NSWindow(contentRect: .init(x: 100, y: 100, width: 1150, height: 780),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                reference.isReleasedWhenClosed = false
                reference.contentViewController = NSHostingController(rootView: SearchView()
                    .environmentObject(state).environmentObject(state.navigation))
                BrowserWindowChromeController.configure(reference)
                reference.makeKeyAndOrderFront(nil)
                try await self.settle(reference)
                XCTAssertEqual(searchItems.count, try XCTUnwrap(reference.toolbar).items.count,
                    "Parent toolbar content leaked into the Search route")
                reference.close()
                window.makeKeyAndOrderFront(nil)
                if iteration == 0 { try self.attachWindowSnapshot(window, name: "search-owned-toolbar") }
                state.returnFromSearchToHome()
                try await self.settle(window)
                XCTAssertEqual(window.toolbar?.items.count, homeItems.count)
                XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, height, accuracy: 0.5)
                let current = button.convert(button.bounds, to: nil)
                XCTAssertEqual(current.minX, position.minX, accuracy: 0.5)
                XCTAssertEqual(current.midY, position.midY, accuracy: 0.5)
            }
        }
    }

    func testFirstHomeScrollKeepsTitlebarMaterialBeforeAnyNavigation() async throws {
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 80, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<120 {
            for x in 0..<80 {
                pixels.setColor((x / 10 + y / 10).isMultiple(of: 2) ? .systemRed : .systemBlue, atX: x, y: y)
            }
        }
        let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-posters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: directory,
            httpClient: ToolbarPosterHTTPClient(body: png)))
        let posterURL = try XCTUnwrap(URL(string: "https://toolbar.fixture.invalid/poster.png"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Let the production WindowCloseObserver schedule window setup.
            // Synchronous configuration in the other helpers hid this race.
            try await withBrowser(initialSection: .home, configureChromeImmediately: false, imageRepository: repository) { state, window in
                window.appearance = NSAppearance(named: appearance)
                let provider = ToolbarFixtureProvider()
                let record = StoredConfiguration(name: "Scrolling toolbar fixture", sourceKind: .pasted,
                    rawData: try JSONEncoder().encode(FongMiConfiguration(sites: [provider.site])))
                let posters = (0..<120).map { index in
                    VideoSummary(siteKey: provider.site.key, siteName: provider.site.name,
                        videoID: "poster-\(index)", title: "Poster \(index)", posterURL: posterURL)
                }
                state.seedCategoryHomeForTesting(record: record, provider: provider,
                    home: SiteHome(categories: [], recommendations: posters))
                try await self.settle(window)
                let split = try self.primarySplit(in: window)
                XCTAssertFalse(HomeItemPresentationPolicy.prefersCompactCards(posters),
                    "Exercise the recommendation poster wall, not compact entry cards")
                let scroll = try XCTUnwrap(BrowserKeyboardView.descendants(of: split.arrangedSubviews[1])
                    .compactMap { $0 as? NSScrollView }.first {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 500
                    })
                XCTAssertTrue(WindowTransitionCoordinator.state(for: window).browserChromeConfigured)
                // Let initial viewport measurement/anchor restoration finish,
                // just as it does while startup artwork loads. Never navigate.
                try await self.settle(window)
                try await self.settle(window)
                for offset: CGFloat in [180, 640, 1200, 0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await self.settle(window)
                    XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
                    try self.assertTitlebarMaterial(window)
                    XCTAssertFalse(try XCTUnwrap(window.toolbar).items.isEmpty)
                    if offset == 640 {
                        let stats = await repository.posterPipelineStats()
                        XCTAssertGreaterThan(stats.decoded, 0, "Render colored poster images without a network dependency")
                        try self.attachWindowSnapshot(window, name: "first-home-scroll-\(appearance.rawValue)")
                    }
                }
                for section: AppSection in [.live, .home, .favorites, .history, .settings, .home] {
                    state.selectSection(section)
                    try await self.settle(window)
                    try self.assertTitlebarMaterial(window)
                }
                state.presentHomeSearch()
                try await self.settle(window)
                try self.assertTitlebarMaterial(window)
                state.returnFromSearchToHome()
                try await self.settle(window)
                try self.assertTitlebarMaterial(window)
            }
        }
    }

    func testConfigurationArrivalAndRemovalKeepHomeTitlebarStable() async throws {
        try await withBrowser(initialSection: .home) { state, window in
            try await self.settle(window)
            let height = window.frame.height - window.contentLayoutRect.height
            let count = try XCTUnwrap(window.toolbar).items.count
            XCTAssertEqual(count, 2)
            let provider = ToolbarFixtureProvider()
            let record = StoredConfiguration(name: "Toolbar fixture", sourceKind: .pasted,
                rawData: try JSONEncoder().encode(FongMiConfiguration(sites: [provider.site])))
            state.seedFavoriteConfigurationsForTesting([record])
            state.seedCategoryHomeForTesting(record: record, provider: provider, home: try await provider.home())
            try await self.settle(window)
            XCTAssertNotNil(state.activeConfiguration)
            XCTAssertGreaterThan(try XCTUnwrap(window.toolbar).items.count, count)
            XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, height, accuracy: 0.5)
            state.setLiveConfigurationForTesting(nil, providers: [:])
            try await self.settle(window)
            XCTAssertNil(state.activeConfiguration)
            XCTAssertTrue(state.hasCompletedStartup, "Exercise settled empty state, not only loading")
            XCTAssertEqual(window.toolbar?.items.count, count)
            XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, height, accuracy: 0.5)
        }
    }

    func testSidebarAccessoryMovesToNewWindowWithoutDuplication() async throws {
        let controller = BrowserRootSplitController()
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 700),
                styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            BrowserWindowChromeController.configure(window)
            return window
        }
        let first = makeWindow(), second = makeWindow()
        defer { first.close(); second.close() }
        first.contentViewController = controller
        first.makeKeyAndOrderFront(nil)
        try await settle(first)
        let accessory = controller.sidebarTitlebar
        XCTAssertEqual(first.titlebarAccessoryViewControllers.filter { $0 === accessory }.count, 1)
        first.contentViewController = nil
        second.contentViewController = controller
        second.makeKeyAndOrderFront(nil)
        try await settle(second)
        XCTAssertFalse(first.titlebarAccessoryViewControllers.contains { $0 === accessory })
        for _ in 0..<3 {
            controller.viewDidLayout()
            XCTAssertEqual(second.titlebarAccessoryViewControllers.filter { $0 === accessory }.count, 1)
            XCTAssertTrue(accessory.toggleButton.target === controller)
        }
        accessory.toggleButton.performClick(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(controller.splitViewItems[0].isCollapsed)
        accessory.toggleButton.performClick(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(controller.splitViewItems[0].isCollapsed)
    }

    func testRepeatedBrowserCreationKeepsOneWorkingSidebarAccessory() async throws {
        for _ in 0..<3 {
            try await withBrowser(initialSection: .home) { _, window in
                try await self.settle(window)
                let controller = try XCTUnwrap(try self.primarySplit(in: window).delegate as? BrowserRootSplitController)
                let accessories = window.titlebarAccessoryViewControllers.compactMap { $0 as? BrowserSidebarTitlebarController }
                XCTAssertEqual(accessories.count, 1)
                XCTAssertTrue(accessories.first?.toggleButton.target === controller)
                accessories.first?.toggleButton.performClick(nil)
                try await Task.sleep(nanoseconds: 400_000_000)
                XCTAssertTrue(controller.splitViewItems[0].isCollapsed)
                accessories.first?.toggleButton.performClick(nil)
                try await Task.sleep(nanoseconds: 400_000_000)
                XCTAssertFalse(controller.splitViewItems[0].isCollapsed)
            }
        }
    }

    func testSettingsBoundaryHasNoBrightBand() async throws {
        try await withBrowser { _, window in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for width: CGFloat in [1120, 1370, 1537] {
                    window.setContentSize(NSSize(width: width, height: 780))
                    try await self.settle(window)
                    let split = try self.primarySplit(in: window)
                    let view = try XCTUnwrap(window.contentView)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let left = view.convert(NSPoint(x: split.arrangedSubviews[0].frame.maxX, y: 0), from: split).x
                    let right = view.convert(NSPoint(x: split.arrangedSubviews[1].frame.minX, y: 0), from: split).x
                    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                    let start = Int(floor(left * scale)) - 2
                    let end = Int(ceil(right * scale)) + 2
                    // Sample empty areas next to the primary boundary. Compare
                    // against both adjacent surfaces instead of hardcoding a
                    // theme color, so native materials can follow the system.
                    for fraction: CGFloat in [0.60, 0.75, 0.90] {
                        let y = Int(CGFloat(bitmap.pixelsHigh) * fraction)
                        func brightness(_ x: Int) throws -> CGFloat {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        }
                        let adjacent = max(try brightness(start - 6), try brightness(end + 6))
                        for x in start...end {
                            XCTAssertLessThanOrEqual(try brightness(x), adjacent + 0.075,
                                "Bright stripe at x=\(x), y=\(y), \(appearance.rawValue), width=\(width)")
                        }
                    }
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "settings-\(appearance.rawValue)-\(Int(width))"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
            }
        }
    }

    func testNativeSidebarGeometrySurvivesPageAndSizeChanges() async throws {
        try await withBrowser { state, window in
            for section: AppSection in [.home, .live, .favorites, .history, .settings] {
                state.selectSection(section)
                for width: CGFloat in [1120, 1370] {
                    window.setContentSize(NSSize(width: width, height: 780))
                    try await self.settle(window)
                    let split = try self.primarySplit(in: window)
                    let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
                    XCTAssertEqual(controller.splitViewItems.first?.behavior, .sidebar,
                        "AppKit must own the primary sidebar's material and divider")
                    let panes = split.arrangedSubviews
                    XCTAssertFalse(split.isSubviewCollapsed(panes[0]))
                    XCTAssertEqual(panes[0].frame.width, AppSidebarMetrics.width, accuracy: 1)
                    XCTAssertEqual(split.dividerThickness, 0)
                    XCTAssertEqual(panes[1].frame.minX, panes[0].frame.maxX, accuracy: 0.001,
                        "The fixed sidebar must not reserve a separator slot")
                    XCTAssertEqual(panes[1].frame.maxX, split.bounds.maxX, accuracy: 1)
                    let sidebar = try XCTUnwrap(BrowserKeyboardView.descendants(of: panes[0])
                        .compactMap { $0 as? NSVisualEffectView }.first { $0.material == .sidebar })
                    XCTAssertEqual(sidebar.blendingMode, .behindWindow)
                    XCTAssertTrue(window.isOpaque)
                    XCTAssertTrue(controller.splitViewItems[0].allowsFullHeightLayout)
                    let sidebarFrame = sidebar.convert(sidebar.bounds, to: window.contentView)
                    XCTAssertEqual(sidebarFrame.maxY, window.contentView!.bounds.maxY, accuracy: 0.5)
                    try self.assertTitlebarMaterial(window)
                    let items = try XCTUnwrap(window.toolbar?.items)
                    XCTAssertFalse(items.contains { $0.itemIdentifier == .sidebarTrackingSeparator })
                    XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is BrowserSidebarTitlebarController }.count, 1)
                }
            }
        }
    }

    func testTitlebarBoundaryAcrossPagesAndAppearances() async throws {
        try await withBrowser { state, window in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for section: AppSection in [.home, .live, .favorites, .history, .settings] {
                    state.selectSection(section)
                    try await self.settle(window)
                    let split = try self.primarySplit(in: window)
                    // Include the native titlebar: contentView-only snapshots
                    // missed the user's remaining stripe above the body.
                    let frame = try XCTUnwrap(window.contentView?.superview)
                    let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    let boundary = frame.convert(NSPoint(x: split.arrangedSubviews[1].frame.minX, y: 0), from: split).x
                    let scale = CGFloat(bitmap.pixelsWide) / frame.bounds.width
                    let x = Int((boundary * scale).rounded())
                    for yPoint: CGFloat in [8, 16, 32, 40] {
                        let y = Int(yPoint * scale)
                        func brightness(_ column: Int) throws -> CGFloat {
                            let color = try XCTUnwrap(bitmap.colorAt(x: column, y: y)?.usingColorSpace(.sRGB))
                            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        }
                        let adjacent = max(try brightness(x - 8), try brightness(x + 8))
                        for column in (x - 2)...(x + 3) {
                            XCTAssertLessThanOrEqual(try brightness(column), adjacent + 0.01,
                                "Titlebar stripe: \(section), \(appearance), x=\(column), y=\(y)")
                        }
                    }
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "whole-window-\(section)-\(appearance.rawValue)"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
            }
        }
    }

    func testSidebarButtonRemainsMountedDuringNavigation() async throws {
        try await withBrowser { state, window in
            try await self.settle(window)
            let split = try self.primarySplit(in: window)
            let controller = try XCTUnwrap(split.delegate as? BrowserRootSplitController)
            let accessory = controller.sidebarTitlebar
            let button = accessory.toggleButton
            let parent = button.superview
            let originalFrame = button.convert(button.bounds, to: nil)
            for section: AppSection in [.home, .live, .favorites, .history, .settings, .home] {
                state.selectSection(section)
                // Sample intermediate run-loop turns, not just settled views.
                for _ in 0..<20 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    window.contentView?.layoutSubtreeIfNeeded()
                    XCTAssertTrue(button.window === window)
                    XCTAssertTrue(button.superview === parent)
                    XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0 === accessory })
                    XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                    XCTAssertEqual(button.alphaValue, 1)
                    let current = button.convert(button.bounds, to: nil)
                    XCTAssertEqual(current.minX, originalFrame.minX, accuracy: 0.5)
                    XCTAssertEqual(current.midY, originalFrame.midY, accuracy: 0.5)
                }
            }
        }
    }

    func testSidebarControlsKeepNativeVibrantAppearance() async throws {
        try await withBrowser { _, window in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                try await self.settle(window)
                let split = try self.primarySplit(in: window)
                let container = try XCTUnwrap(BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
                    .compactMap { $0 as? NativeSidebarSourceList.ContainerView }.first)
                let search = container.searchField
                XCTAssertEqual(search.effectiveAppearance.bestMatch(from: [.vibrantLight, .vibrantDark]),
                               appearance == .darkAqua ? .vibrantDark : .vibrantLight)
                search.isEnabled = true
                window.makeFirstResponder(nil)
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(search.bitmapImageRepForCachingDisplay(in: search.bounds))
                search.cacheDisplay(in: search.bounds, to: bitmap)
                let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 30, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                if appearance == .aqua {
                    XCTAssertLessThan(color.redComponent, 0.97, "The resting sidebar search must not regress to an opaque white field")
                }
                let outline = container.outlineView
                for row in 0..<outline.numberOfRows {
                    let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
                    let symbol = try XCTUnwrap(cell.imageView)
                    let image = try XCTUnwrap(symbol.bitmapImageRepForCachingDisplay(in: symbol.bounds))
                    symbol.cacheDisplay(in: symbol.bounds, to: image)
                    let hasBlue = (0..<image.pixelsHigh).contains { y in
                        (0..<image.pixelsWide).contains { x in
                            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { return false }
                            return color.blueComponent - color.redComponent > 0.2
                        }
                    }
                    XCTAssertTrue(hasBlue, "Sidebar glyph \(row) lost its native blue palette")
                }
            }
        }
    }

    func testSearchPlaceholderRemainsReadableAcrossThemeChanges() async throws {
        try await withBrowser { _, window in
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                window.appearance = NSAppearance(named: appearance)
                try await self.settle(window)
                let split = try self.primarySplit(in: window)
                let container = try XCTUnwrap(BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
                    .compactMap { $0 as? NativeSidebarSourceList.ContainerView }.first)
                let search = container.searchField
                XCTAssertFalse(search.placeholderAttributedString?.string.isEmpty ?? true)
                search.isEnabled = true
                search.stringValue = ""
                window.makeFirstResponder(nil)
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(search.bitmapImageRepForCachingDisplay(in: search.bounds))
                search.cacheDisplay(in: search.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / search.bounds.width
                let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 30, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                // Ignore the magnifier, border and empty trailing area. Require
                // actual placeholder glyphs to contrast with the field fill.
                var readablePixels = 0
                for y in Int(6 * scale)..<Int((search.bounds.height - 6) * scale) {
                    for x in Int(30 * scale)..<Int(120 * scale) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(color.redComponent - background.redComponent) > 0.16 { readablePixels += 1 }
                    }
                }
                XCTAssertGreaterThan(readablePixels, 30, "Placeholder disappeared in \(appearance.rawValue)")
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "Readable search placeholder \(appearance.rawValue)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
    }

    func testThemeSwitchUpdatesMaterialsAndContentTogether() async throws {
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        try await withBrowser { _, window in
            window.appearance = nil
            try await self.settle(window)
            let split = try self.primarySplit(in: window)
            let container = try XCTUnwrap(BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
                .compactMap { $0 as? NativeSidebarSourceList.ContainerView }.first)
            let frame = try XCTUnwrap(window.contentView?.superview)
            AppAppearanceController.apply(.system)
            try await self.settle(window)
            let systemIsDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            for theme: AppTheme in [.dark, .light, .dark, .light, .system] {
                // AppKit propagates application appearance on its next turn.
                // Derive the expected theme from the requested value, rather
                // than accidentally recording the previous frame's appearance.
                let dark = theme == .system ? systemIsDark : theme == .dark
                AppAppearanceController.apply(theme)
                // Assert the first frames after the actual app-level theme
                // change, without waiting for a settled 200 ms screenshot.
                for sample in 0..<3 {
                    try await Task.sleep(nanoseconds: 16_000_000)
                    frame.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    XCTAssertNil(container.appearance, "The container must inherit live window appearance")
                    XCTAssertEqual(container.searchField.effectiveAppearance.bestMatch(from: [.vibrantLight, .vibrantDark]),
                                   dark ? .vibrantDark : .vibrantLight)
                    let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / frame.bounds.width
                    let points = [
                        NSPoint(x: 20, y: frame.bounds.height * 0.7),
                        NSPoint(x: frame.bounds.width - 25, y: 18),
                        NSPoint(x: frame.bounds.width - 25, y: frame.bounds.height * 0.7)
                    ]
                    for (region, point) in points.enumerated() {
                        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
                        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if dark {
                            XCTAssertLessThan(brightness, 0.55, "Stale light region \(region), frame \(sample)")
                        } else {
                            XCTAssertGreaterThan(brightness, 0.65, "Stale dark region \(region), frame \(sample)")
                        }
                    }
                    if sample == 0 {
                        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                       uniformTypeIdentifier: "public.png")
                        attachment.name = "theme-first-frame-\(theme)"
                        attachment.lifetime = .keepAlways
                        self.add(attachment)
                    }
                }
            }
        }
    }

    func testSidebarCollapseAndExpandPreservesZeroGap() async throws {
        try await withBrowser { _, window in
            try await self.settle(window)
            let split = try self.primarySplit(in: window)
            let controller = try XCTUnwrap(split.delegate as? BrowserRootSplitController)
            let item = controller.splitViewItems[0]
            for _ in 0..<3 {
                controller.sidebarTitlebar.toggleButton.performClick(nil)
                try await Task.sleep(nanoseconds: 350_000_000)
                try await self.settle(window)
                XCTAssertTrue(item.isCollapsed)
                XCTAssertEqual(controller.detailHost.view.convert(controller.detailHost.view.bounds, to: split).minX, 0, accuracy: 0.001)
                controller.sidebarTitlebar.toggleButton.performClick(nil)
                try await Task.sleep(nanoseconds: 350_000_000)
                try await self.settle(window)
                XCTAssertFalse(item.isCollapsed)
                let panes = split.arrangedSubviews
                XCTAssertEqual(panes[0].frame.width, 220, accuracy: 0.001)
                XCTAssertEqual(panes[1].frame.minX, panes[0].frame.maxX, accuracy: 0.001)
            }
        }
    }
}

private struct ToolbarFixtureProvider: SiteProvider {
    let site = SiteConfiguration(key: "toolbar-fixture", name: "Toolbar fixture", type: 1, api: "https://example.invalid/api")
    let capability = SiteCapability.standardJSON
    func home() async throws -> SiteHome { .init(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
        .init(items: [], pagination: .init(page: page, pageCount: 0))
    }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        try await category(id: keyword, page: page, filters: [:])
    }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("fixture") }
    func detail(id: String) async throws -> VideoDetail {
        .init(summary: .init(siteKey: site.key, siteName: site.name, videoID: id, title: "Fixture"), synopsis: "", playSources: [])
    }
}

private struct ToolbarPosterHTTPClient: HTTPClient {
    let body: Data
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(url: request.url, statusCode: 200, headers: ["Content-Type": "image/png"], body: body)
    }
}
