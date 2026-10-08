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
    private func withBrowser(_ run: (AppState, NSWindow) async throws -> Void) async throws {
        let state = AppState(environment: nil)
        state.selectSection(.settings)
        let host = NSHostingController(rootView: RootView()
            .environmentObject(state).environmentObject(state.navigation))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1370, height: 780),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        BrowserWindowChromeController.configure(window)
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

    private func primarySplit(in window: NSWindow) throws -> NSSplitView {
        try XCTUnwrap(BrowserKeyboardView.descendants(of: window.contentView)
            .compactMap { $0 as? NSSplitView }.first { split in
                split.isVertical && split.arrangedSubviews.count == 2 &&
                BrowserKeyboardView.descendants(of: split.arrangedSubviews[0])
                    .contains { $0 is BrowserSidebarOutlineView }
            })
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
                    let material = try XCTUnwrap(BrowserKeyboardView.descendants(of: panes[1])
                        .compactMap { $0 as? NSVisualEffectView }.first { $0.material == .titlebar })
                    XCTAssertEqual(material.blendingMode, .withinWindow)
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
            for theme: AppTheme in [.dark, .light, .dark, .light, .system] {
                AppAppearanceController.apply(theme)
                let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
