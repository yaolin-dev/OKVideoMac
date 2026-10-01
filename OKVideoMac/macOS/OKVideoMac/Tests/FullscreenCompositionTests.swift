import AppKit
import QuartzCore
import SwiftUI
import XCTest
import OKVideoCore
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
    func testBackingCoversDividerWithoutChangingNativeGeometry() throws {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        split.isVertical = true; split.dividerStyle = .thin
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        AppSidebarNativePolicy.configure(background: sidebar)
        let content = NSView(frame: NSRect(x: 221, y: 0, width: 739, height: 600))
        split.addArrangedSubview(sidebar); split.addArrangedSubview(content)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split
        defer { window.close() }
        split.adjustSubviews()
        let frames = split.arrangedSubviews.map(\.frame)
        let probe = BrowserSplitDividerBacking.Probe(frame: sidebar.bounds)
        sidebar.addSubview(probe)
        XCTAssertEqual(split.arrangedSubviews.map(\.frame), frames)
        XCTAssertTrue(probe.backing.superlayer === split.layer)
        for width: CGFloat in [900, 1280, 1537] {
            split.setFrameSize(NSSize(width: width, height: 601))
            split.adjustSubviews()
            probe.refresh()
            XCTAssertFalse(probe.backing.isHidden)
            XCTAssertLessThan(probe.backing.frame.minX, sidebar.frame.maxX)
            XCTAssertGreaterThan(probe.backing.frame.maxX, content.frame.minX)
            XCTAssertEqual(probe.backing.frame.height, split.bounds.height)
            XCTAssertEqual(probe.backing.backgroundColor?.alpha, 1)
            XCTAssertEqual(split.arrangedSubviews.count, 2, "Backing must never become a third pane")
            XCTAssertEqual(sidebar.material, .sidebar)
            XCTAssertEqual(sidebar.blendingMode, .behindWindow)
        }
        sidebar.isHidden = true; probe.refresh()
        XCTAssertTrue(probe.backing.isHidden)
        sidebar.isHidden = false; split.adjustSubviews(); probe.refresh()
        XCTAssertFalse(probe.backing.isHidden)
        probe.detach()
        XCTAssertNil(probe.backing.superlayer)
    }

    func testRealRootDividerAppearanceAndNarrowWindow() async throws {
        let state = AppState(environment: nil)
        let host = NSHostingController(rootView: RootView().environmentObject(state).environmentObject(state.navigation))
        let window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 1280, height: 720),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        window.title = "OKVideoMac 分栏验证 126"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let directory = URL(fileURLWithPath: "/private/tmp/ok126-seam-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [900, 1280] {
                window.appearance = NSAppearance(named: name)
                window.setContentSize(NSSize(width: width, height: 720))
                try await Task.sleep(nanoseconds: 150_000_000)
                let probe = try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView)
                    .compactMap { $0 as? BrowserSplitDividerBacking.Probe }.first)
                probe.attach()
                XCTAssertNotNil(probe.backing.superlayer, "Must attach inside the actual NavigationSplitView hierarchy")
                XCTAssertFalse(probe.backing.isHidden)
                XCTAssertGreaterThan(probe.backing.bounds.height, 500)
                XCTAssertEqual(probe.backing.backgroundColor?.alpha, 1)
                let color = try XCTUnwrap(probe.backing.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.deviceRGB))
                if name == .aqua { XCTAssertGreaterThan(color.redComponent, 0.9) }
                else { XCTAssertLessThan(color.redComponent, 0.3) }
                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appendingPathComponent("root-\(name.rawValue)-\(Int(width)).png"))
            }
        }
        window.appearance = NSAppearance(named: .aqua)

    }
}
