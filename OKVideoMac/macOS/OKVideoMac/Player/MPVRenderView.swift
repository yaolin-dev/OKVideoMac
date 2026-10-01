import AppKit
import Darwin
import OpenGL
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let mpvPlayerWillShutdown = Notification.Name(
        "com.okvideomac.player.will-shutdown"
    )
}

/// Serializes playback startup against the native render-surface lifecycle.
/// AppState owns this gate on the main actor while MPVOpenGLView is the only
/// component allowed to publish readiness.
@MainActor
final class PlayerRenderSurfaceReadinessGate {
    private struct PendingWait {
        let requestID: UUID
        let renderOwnerID: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var readyRenderOwnerID: UUID?
    private(set) var pendingRequestID: UUID?
    private var pendingWait: PendingWait?

    func waitUntilReady(
        requestID: UUID,
        renderOwnerID: UUID
    ) async throws {
        try Task.checkCancellation()
        if readyRenderOwnerID == renderOwnerID {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if readyRenderOwnerID == renderOwnerID {
                    continuation.resume()
                    return
                }
                pendingWait?.continuation.resume(
                    throwing: CancellationError()
                )
                pendingWait = PendingWait(
                    requestID: requestID,
                    renderOwnerID: renderOwnerID,
                    continuation: continuation
                )
                pendingRequestID = requestID
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    func markReady(renderOwnerID: UUID) {
        readyRenderOwnerID = renderOwnerID
        guard let pendingWait,
              pendingWait.renderOwnerID == renderOwnerID else { return }
        self.pendingWait = nil
        pendingRequestID = nil
        pendingWait.continuation.resume()
    }

    func markUnavailable(renderOwnerID: UUID) {
        if readyRenderOwnerID == renderOwnerID {
            readyRenderOwnerID = nil
        }
    }

    func reset() {
        readyRenderOwnerID = nil
        pendingWait?.continuation.resume(throwing: CancellationError())
        pendingWait = nil
        pendingRequestID = nil
    }

    private func cancel(requestID: UUID) {
        guard pendingWait?.requestID == requestID else { return }
        pendingWait?.continuation.resume(throwing: CancellationError())
        pendingWait = nil
        pendingRequestID = nil
    }
}

/// Collapses render callbacks while a frame is already waiting on the main
/// thread. libmpv may produce callbacks faster than AppKit can draw a 4K
/// surface; queueing every callback makes buttons and sliders wait behind an
/// ever-growing list of `needsDisplay` blocks.
final class PlayerDisplayUpdateGate {
    private let lock = NSLock()
    private var isUpdateScheduled = false
    private var needsFollowUpUpdate = false
    private var isSuspended = false

    /// Returns true only when the caller should schedule a new display block.
    func requestUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSuspended else { return false }
        if isUpdateScheduled {
            needsFollowUpUpdate = true
            return false
        }
        isUpdateScheduled = true
        return true
    }

    /// Completes one main-thread scheduling block and returns true when one
    /// coalesced follow-up block is still needed. This deliberately does not
    /// wait for `draw(_:)`: AppKit may consume `needsDisplay` while a view is
    /// being resized or hidden without invoking a draw. Tying the reset to a
    /// draw can therefore wedge the gate until an unrelated UI redraw occurs.
    func finishScheduling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if needsFollowUpUpdate {
            needsFollowUpUpdate = false
            return true
        }
        isUpdateScheduled = false
        return false
    }

    /// Teardown fences queued callbacks before releasing the render context.
    /// Live resize must continue servicing updates and must not use this gate.
    func setSuspended(_ suspended: Bool) {
        lock.lock()
        isSuspended = suspended
        if suspended {
            isUpdateScheduled = false
            needsFollowUpUpdate = false
        }
        lock.unlock()
    }
}

private final class MPVRenderCallbackBox {
    weak var view: MPVOpenGLView?
    let openGLHandle: UnsafeMutableRawPointer?
    private let updateGate = PlayerDisplayUpdateGate()

    init(view: MPVOpenGLView) {
        self.view = view
        openGLHandle = dlopen(
            "/System/Library/Frameworks/OpenGL.framework/OpenGL",
            RTLD_NOW | RTLD_LOCAL
        )
    }

    deinit {
        if let openGLHandle {
            dlclose(openGLHandle)
        }
    }

    func requestDisplay() {
        guard updateGate.requestUpdate() else { return }
        scheduleDisplay()
    }

    func setDisplaySuspended(_ suspended: Bool) {
        updateGate.setSuspended(suspended)
    }

    private func scheduleDisplay() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Update servicing must continue while presentation is suspended:
            // advanced render control also uses it for decoder texture work.
            self.view?.consumeRenderUpdateAndRequestDisplay()
            if self.updateGate.finishScheduling() {
                self.scheduleDisplay()
            }
        }
    }
}

private let mpvOpenGLGetProcAddress: MPVGetProcAddress = {
    rawContext,
    rawName in
    guard let rawContext, let rawName else { return nil }
    let box = Unmanaged<MPVRenderCallbackBox>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
    guard let handle = box.openGLHandle else { return nil }
    return dlsym(handle, String(cString: rawName))
}

private let mpvRenderUpdateCallback: MPVRenderUpdateCallback = { rawContext in
    guard let rawContext else { return }
    let box = Unmanaged<MPVRenderCallbackBox>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
    box.requestDisplay()
}

private let mpvRenderUpdateFrame: UInt64 = 1 << 0

enum MPVRenderSafetyPolicy {
    static func framebufferSize(
        backingBounds: NSRect,
        isInLiveResize _: Bool,
        isAttachedToWindow: Bool
    ) -> (width: Int32, height: Int32)? {
        guard isAttachedToWindow else { return nil }
        let width = backingBounds.width.rounded()
        let height = backingBounds.height.rounded()
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= CGFloat(Int32.max),
              height <= CGFloat(Int32.max) else {
            return nil
        }
        return (Int32(width), Int32(height))
    }
}

enum MPVRenderSurfaceReadinessPolicy {
    static func isReady(
        isAttachedToWindow: Bool,
        hasSuperview: Bool,
        hasOpenGLContext: Bool,
        hasRenderContext: Bool,
        drawableWidth: Int32,
        drawableHeight: Int32
    ) -> Bool {
        isAttachedToWindow
            && hasSuperview
            && hasOpenGLContext
            && hasRenderContext
            && drawableWidth > 0
            && drawableHeight > 0
    }
}

enum MPVRenderVisibilityPolicy {
    static func shouldRequestDisplay(
        isAttachedToWindow: Bool,
        isWindowVisible: Bool,
        isMiniaturized: Bool,
        isOcclusionVisible: Bool
    ) -> Bool {
        isAttachedToWindow
            && isWindowVisible
            && !isMiniaturized
            && isOcclusionVisible
    }
}

/// The video composition scales uniformly during custom fullscreen. Controls
/// live in a sibling viewport so their point sizes never inherit this transform.
final class PlayerFullscreenContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
}

/// The overlay's own finite viewport defines its layout, including while it
/// occupies a subrectangle of the temporary fullscreen-sized window.
final class PlayerOverlayHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// Keep interactive chrome out of the video's scale transform. During a
/// fullscreen transition SwiftUI may commit a resized layout a frame later
/// than Core Animation; suppress that intermediate layout and reveal only the
/// settled controls. Video and danmaku continue rendering throughout.
final class PlayerFullscreenOverlayView: NSView {
    private var presentationRevision = 0
    private var savedAlpha: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    func suspendPresentation() {
        presentationRevision &+= 1
        if savedAlpha == nil { savedAlpha = alphaValue }
        layer?.removeAnimation(forKey: "com.okvideomac.controls.reveal")
        alphaValue = 0
    }

    func resumePresentation() {
        guard let alpha = savedAlpha else { return }
        presentationRevision &+= 1
        let ticket = presentationRevision
        // Allow AppKit's final frame and the hosting view's finite layout to
        // settle outside the fullscreen completion notification stack.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.presentationRevision == ticket else { return }
                self.layoutSubtreeIfNeeded()
                self.savedAlpha = nil
                self.alphaValue = alpha
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = alpha; fade.duration = 0.16
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.layer?.add(fade, forKey: "com.okvideomac.controls.reveal")
            }
        }
    }
}

/// The window keeps a full-size drawable, but only the animated viewport is
/// opaque. This prevents a full-screen black rectangle around the moving player.
@MainActor
private final class PlayerFullscreenBackdrop {
    private weak var window: NSWindow?
    private let root: NSView
    private let rootLayer: CALayer
    private let oldMask: CALayer?
    private let oldLayerColor: CGColor?
    private let oldBackground: NSColor
    private let oldOpaque: Bool
    private let oldShadow: Bool
    private let mask = CAShapeLayer()
    private let overlays: [PlayerFullscreenOverlayView]

    init?(window: NSWindow, entering: Bool, expectedFrame: NSRect, windowedFrame: NSRect) {
        guard let root = window.contentView, let rootLayer = root.layer else { return nil }
        self.window = window; self.root = root; self.rootLayer = rootLayer
        overlays = root.subviews.compactMap { $0 as? PlayerFullscreenOverlayView }
        oldMask = rootLayer.mask; oldLayerColor = rootLayer.backgroundColor
        oldBackground = window.backgroundColor; oldOpaque = window.isOpaque; oldShadow = window.hasShadow
        let full = NSRect(origin: .zero, size: expectedFrame.size)
        let small = windowedFrame.offsetBy(dx: -expectedFrame.minX, dy: -expectedFrame.minY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = full
        mask.fillColor = NSColor.black.cgColor
        mask.path = CGPath(rect: entering ? small : full, transform: nil)
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.mask = mask
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        overlays.forEach { $0.suspendPresentation() }
        CATransaction.commit()
    }

    func animate(entering: Bool, windowedFrame: NSRect, beginTime: CFTimeInterval, duration: TimeInterval) {
        guard let window else { return }
        let small = root.convert(window.convertFromScreen(windowedFrame), from: nil)
        let full = root.bounds
        mask.frame = full
        let start = CGPath(rect: entering ? small : full, transform: nil)
        let end = CGPath(rect: entering ? full : small, transform: nil)
        mask.path = end
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start; animation.toValue = end
        animation.beginTime = mask.convertTime(beginTime, from: nil)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(animation, forKey: "com.okvideomac.fullscreen.viewport")
    }

    func restore() {
        guard let window else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlays.forEach { $0.resumePresentation() }
        if rootLayer.mask === mask { rootLayer.mask = oldMask }
        mask.removeAllAnimations()
        rootLayer.backgroundColor = oldLayerColor
        window.backgroundColor = oldBackground
        window.isOpaque = oldOpaque
        window.hasShadow = oldShadow
        root.needsDisplay = true
        CATransaction.commit()
        self.window = nil
    }
}

/// Owns only the geometry explicitly delegated by AppKit's custom fullscreen
/// API. Business window sizing/chrome still use WindowTransitionCoordinator.
@MainActor
final class PlayerFullscreenPresentation {
    private weak var window: NSWindow?
    private weak var surface: MPVOpenGLView?
    private weak var presentationView: NSView?
    private var windowedFrame: NSRect?
    private var windowedSurfaceFrame: NSRect?
    private var aspectRatio = 1.0

    func prepareToEnter(window: NSWindow, surface: MPVOpenGLView?, aspectRatio: Double,
                        presentationView: NSView? = nil) -> Bool {
        guard let surface, surface.canAnimateFullscreen,
              surface.window === window, aspectRatio.isFinite, aspectRatio > 0,
              !WindowTransitionCoordinator.state(for: window).isClosing,
              let frame = surface.surfaceFrameOnScreen else { return false }
        let composition = presentationView ?? surface
        guard composition.window === window, composition.layer != nil,
              surface === composition || surface.isDescendant(of: composition) else { return false }
        cancel()
        self.presentationView = composition
        self.window = window
        self.surface = surface
        windowedFrame = window.frame
        windowedSurfaceFrame = frame
        self.aspectRatio = aspectRatio
        return true
    }

    func prepareToExit(window: NSWindow, surface: MPVOpenGLView?, aspectRatio: Double) -> Bool {
        guard self.window === window, windowedFrame != nil, windowedSurfaceFrame != nil,
              !WindowTransitionCoordinator.state(for: window).isClosing else { return false }
        self.surface?.finishFullscreenPresentation()
        self.surface = surface
        if aspectRatio.isFinite && aspectRatio > 0 { self.aspectRatio = aspectRatio }
        return true
    }

    func startEntering(window: NSWindow, screen: NSScreen, duration: TimeInterval) {
        guard self.window === window,
              !WindowTransitionCoordinator.state(for: window).isClosing else { return }
        if let windowedSurfaceFrame {
            surface?.beginFullscreenPresentation(entering: true, duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration,
                windowedSurfaceFrame: windowedSurfaceFrame, aspectRatio: aspectRatio,
                expectedWindowFrame: screen.frame, presentationView: presentationView)
        }
        // Keep one full-sized drawable throughout the animation. Only the
        // live composition is uniformly transformed; video pixels keep changing.
        window.setFrame(screen.frame, display: false)
    }

    func startExiting(window: NSWindow, duration: TimeInterval) {
        guard self.window === window, let windowedSurfaceFrame,
              !WindowTransitionCoordinator.state(for: window).isClosing else { return }
        surface?.beginFullscreenPresentation(entering: false, duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration,
            windowedSurfaceFrame: windowedSurfaceFrame, aspectRatio: aspectRatio,
            expectedWindowFrame: window.frame, presentationView: presentationView)
    }

    func complete(window: NSWindow, isFullScreen: Bool) {
        guard self.window === window else { return }
        guard !WindowTransitionCoordinator.state(for: window).isClosing else { cancel(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface?.finishFullscreenPresentation()
        if !isFullScreen, let windowedFrame {
            let visibleFrames = NSScreen.screens.map(\.visibleFrame)
            let frame = AppWindowLayoutPolicy.adjustedFrame(windowedFrame,
                visibleFrames: visibleFrames,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? windowedFrame)
            window.setFrame(frame, display: false)
        }
        CATransaction.commit()
        if !isFullScreen { cancel() }
    }

    func failed(window: NSWindow) {
        complete(window: window, isFullScreen: window.styleMask.contains(.fullScreen))
    }

    func cancel() {
        surface?.finishFullscreenPresentation()
        surface = nil
        presentationView = nil
        window = nil
        windowedFrame = nil
        windowedSurfaceFrame = nil
    }
}

final class MPVOpenGLView: NSOpenGLView {
    private let player: MPVPlayerClient
    private let renderOwnerID: UUID
    private let onError: (Error) -> Void
    private let onSurfaceReady: (UUID) -> Void
    private let onSurfaceUnavailable: (UUID) -> Void
    private var renderContext: OpaquePointer?
    private var renderOpenGLContext: NSOpenGLContext?
    private var callbackBox: MPVRenderCallbackBox?
    private var didReportRenderError = false
    private var isSurfaceReady = false
    private var hasPendingRenderFrame = false
    private var geometryRevision: UInt64 = 0
    private var synchronizedGeometryRevision: UInt64?
    private var presentedGeometryRevision: UInt64?
    private var lastBackingBounds: NSRect?
    private var isTornDown = false
    private struct FullscreenRequest {
        let entering: Bool
        let deadline: TimeInterval
        let windowID: ObjectIdentifier
        let windowedSurfaceFrame: NSRect
        let aspectRatio: Double
        let expectedWindowFrame: NSRect
    }
    private var fullscreenRequest: FullscreenRequest?
    private weak var fullscreenPresentationView: NSView?
    private var fullscreenAnimationLayer: CALayer?
    private var fullscreenBackdrop: PlayerFullscreenBackdrop?
    private static let fullscreenAnimationKey = "com.okvideomac.video.fullscreen"
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
    private(set) var renderUpdatesForTesting = 0
    private(set) var skippedFramesForTesting = 0
    private(set) var renderedFramesForTesting = 0
    private(set) var lastPresentedPixelSizeForTesting: NSSize?
    var readinessDiagnosticsForTesting: String {
        "canPresent=\(canPresent) contextMatches=\(openGLContext === renderOpenGLContext) renderContext=\(renderContext != nil) needsDisplay=\(needsDisplay) renders=\(renderedFramesForTesting) updates=\(renderUpdatesForTesting) closing=\(window.map { WindowTransitionCoordinator.state(for: $0).isClosing } ?? false)"
    }
    var collectRenderTimingsForTesting = false
    private(set) var renderTimingsForTesting: [String] = []
#endif

    init(
        player: MPVPlayerClient,
        onError: @escaping (Error) -> Void,
        onSurfaceReady: @escaping (UUID) -> Void,
        onSurfaceUnavailable: @escaping (UUID) -> Void
    ) {
        self.player = player
        renderOwnerID = player.renderOwnerID
        self.onError = onError
        self.onSurfaceReady = onSurfaceReady
        self.onSurfaceUnavailable = onSurfaceUnavailable
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            99,     // NSOpenGLPFAOpenGLProfile
            0x3200, // NSOpenGLProfileVersion3_2Core
            73,     // NSOpenGLPFAAccelerated
            5,      // NSOpenGLPFADoubleBuffer
            8,      // NSOpenGLPFAColorSize
            24,
            11,     // NSOpenGLPFAAlphaSize
            8,
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attributes)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
        // AppKit can temporarily reuse the last drawable while changing the
        // view's bounds. Its default independently scales both axes.
        layerContentsPlacement = .scaleProportionallyToFit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWillShutdown(_:)),
            name: .mpvPlayerWillShutdown,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard renderContext == nil, !isTornDown, let openGLContext else { return }
        openGLContext.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext.setValues(
            &swapInterval,
            for: NSOpenGLContext.Parameter.swapInterval
        )
        let box = MPVRenderCallbackBox(view: self)
        callbackBox = box
        do {
            let opaque = Unmanaged.passUnretained(box).toOpaque()
            let context = try player.makeRenderContext(
                getProcAddress: mpvOpenGLGetProcAddress,
                context: opaque
            )
            renderContext = context
            renderOpenGLContext = openGLContext
            player.setRenderUpdateCallback(
                renderContext: context,
                callback: mpvRenderUpdateCallback,
                context: opaque
            )
            evaluateSurfaceReadiness()
        } catch {
            report(error)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        evaluateSurfaceReadiness()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservers()
        if window == nil {
            finishFullscreenPresentation()
            markSurfaceUnavailable()
        }
        synchronizeDrawableAfterWindowLayout()
        evaluateSurfaceReadiness()
    }

    override func layout() {
        super.layout()
        invalidateChangedGeometry()
        evaluateSurfaceReadiness()
    }

    override func reshape() {
        super.reshape()
        synchronizeDrawableAfterWindowLayout()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        synchronizeDrawableAfterWindowLayout()
        consumeRenderUpdateAndRequestDisplay()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        synchronizeDrawableAfterWindowLayout()
    }

    /// Called after AppKit's normal layout; never forces layout of the host tree.
    func synchronizeDrawableAfterWindowLayout() {
        guard !isTornDown else { return }
        geometryRevision &+= 1
        lastBackingBounds = convertToBacking(bounds)
        // Do not force SwiftUI layout or update a drawable from a window
        // notification. AppKit's next draw synchronizes and presents it.
        needsDisplay = true
    }

    private func invalidateChangedGeometry() {
        if lastBackingBounds != convertToBacking(bounds) {
            synchronizeDrawableAfterWindowLayout()
        }
    }

    private var canPresent: Bool {
        guard !isTornDown, let window,
              !WindowTransitionCoordinator.state(for: window).isClosing,
              renderOpenGLContext != nil, openGLContext === renderOpenGLContext,
              superview != nil else { return false }
        let phase = WindowTransitionCoordinator.state(for: window).phase
        // AppKit marks the source window occluded while its live surface is
        // being composited into the fullscreen animation in another Space.
        let isFullScreenAnimation = phase == .enteringFullScreen || phase == .exitingFullScreen
        return MPVRenderVisibilityPolicy.shouldRequestDisplay(
            isAttachedToWindow: true,
            isWindowVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOcclusionVisible: window.occlusionState.contains(.visible) || isFullScreenAnimation
        ) && MPVRenderSafetyPolicy.framebufferSize(
            backingBounds: convertToBacking(bounds),
            isInLiveResize: window.inLiveResize,
            isAttachedToWindow: true
        ) != nil
    }

    var canAnimateFullscreen: Bool {
        !isTornDown && isSurfaceReady && layer != nil && canPresent
    }

    var surfaceFrameOnScreen: NSRect? {
        window.map { $0.convertToScreen(convert(bounds, to: nil)) }
    }

    func beginFullscreenPresentation(entering: Bool, duration: TimeInterval,
        windowedSurfaceFrame: NSRect, aspectRatio: Double, expectedWindowFrame: NSRect,
        presentationView: NSView? = nil) {
        guard !isTornDown, let window else { return }
        finishFullscreenPresentation()
        fullscreenPresentationView = presentationView ?? self
        fullscreenBackdrop = PlayerFullscreenBackdrop(window: window, entering: entering,
            expectedFrame: expectedWindowFrame, windowedFrame: windowedSurfaceFrame)
        fullscreenRequest = FullscreenRequest(entering: entering,
            deadline: ProcessInfo.processInfo.systemUptime + max(0, duration),
            windowID: ObjectIdentifier(window), windowedSurfaceFrame: windowedSurfaceFrame,
            aspectRatio: aspectRatio, expectedWindowFrame: expectedWindowFrame)
        synchronizeDrawableAfterWindowLayout()
    }

    func finishFullscreenPresentation() {
        guard fullscreenRequest != nil || fullscreenAnimationLayer != nil || fullscreenBackdrop != nil else { return }
        fullscreenRequest = nil
        fullscreenPresentationView = nil
        if let animationLayer = fullscreenAnimationLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            animationLayer.removeAnimation(forKey: Self.fullscreenAnimationKey)
            animationLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            fullscreenAnimationLayer = nil
        }
        fullscreenBackdrop?.restore()
        fullscreenBackdrop = nil
        synchronizeDrawableAfterWindowLayout()
    }

    private func prepareFullscreenPresentation() {
        guard let request = fullscreenRequest, let window,
              let composition = fullscreenPresentationView, composition.window === window,
              let layer = composition.layer,
              request.windowID == ObjectIdentifier(window),
              !WindowTransitionCoordinator.state(for: window).isClosing,
              abs(window.frame.width - request.expectedWindowFrame.width) < 1,
              abs(window.frame.height - request.expectedWindowFrame.height) < 1,
              abs(bounds.width - request.expectedWindowFrame.width) < 1,
              let screenFrame = surfaceFrameOnScreen else { return }
        fullscreenRequest = nil
        let smallHeight = min(request.windowedSurfaceFrame.height,
                              request.windowedSurfaceFrame.width / request.aspectRatio)
        let fullHeight = min(screenFrame.height, screenFrame.width / request.aspectRatio)
        guard smallHeight > 0, fullHeight > 0 else { return }
        let scale = smallHeight / fullHeight
        // Express the shared transform around its actual anchor, even if the
        // video view is offset within the AppKit composition container.
        let anchor = window.convertPoint(toScreen: composition.convert(NSPoint(
            x: composition.bounds.minX + layer.anchorPoint.x * composition.bounds.width,
            y: composition.bounds.minY + layer.anchorPoint.y * composition.bounds.height), to: nil))
        let transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: request.windowedSurfaceFrame.midX - screenFrame.midX
                + (1-scale) * (screenFrame.midX - anchor.x),
            ty: request.windowedSurfaceFrame.midY - screenFrame.midY
                + (1-scale) * (screenFrame.midY - anchor.y)))
        let start = request.entering ? transform : CATransform3DIdentity
        let end = request.entering ? CATransform3DIdentity : transform
        fullscreenAnimationLayer = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = end
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: end)
        let beginTime = CACurrentMediaTime()
        animation.beginTime = layer.convertTime(beginTime, from: nil)
        animation.duration = max(0, request.deadline - ProcessInfo.processInfo.systemUptime)
        fullscreenBackdrop?.animate(entering: request.entering, windowedFrame: request.windowedSurfaceFrame,
            beginTime: beginTime, duration: animation.duration)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.fullscreenAnimationKey)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit can deliver one final layer-backed draw after this view has
        // detached from its drawable. At that point NSGraphicsContext has no
        // current CGContext, so even a fallback NSColor fill traps. A nil mpv
        // context means teardown owns the surface and there is nothing left
        // for this view to draw.
        guard canPresent, let window,
              let renderContext,
              let openGLContext, openGLContext === renderOpenGLContext else { return }
        invalidateChangedGeometry()
        prepareFullscreenPresentation()
        let revision = geometryRevision
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
        let started = ProcessInfo.processInfo.systemUptime
#endif
        openGLContext.makeCurrentContext()
        if synchronizedGeometryRevision != revision {
            openGLContext.update()
            synchronizedGeometryRevision = revision
        }
        guard let framebufferSize = MPVRenderSafetyPolicy.framebufferSize(
                backingBounds: convertToBacking(bounds),
                isInLiveResize: window.inLiveResize,
                isAttachedToWindow: true
              ) else { return }
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
        let synchronized = ProcessInfo.processInfo.systemUptime
#endif
        do {
            try player.render(
                renderContext,
                framebuffer: 0,
                width: framebufferSize.width,
                height: framebufferSize.height,
                flipY: true
            )
            hasPendingRenderFrame = false
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
            renderedFramesForTesting += 1
            let rendered = ProcessInfo.processInfo.systemUptime
#endif
            openGLContext.flushBuffer()
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
            lastPresentedPixelSizeForTesting = NSSize(width: Int(framebufferSize.width), height: Int(framebufferSize.height))
            if collectRenderTimingsForTesting {
                renderTimingsForTesting.append("\(started),\(synchronized - started),\(rendered - synchronized),\(ProcessInfo.processInfo.systemUptime - rendered),\(revision),\(framebufferSize.width),\(framebufferSize.height)")
            }
#endif
            presentedGeometryRevision = revision
            if geometryRevision != revision { needsDisplay = true }
            markSurfaceReadyAfterRenderProbe(framebufferSize: framebufferSize)
            player.reportSwap(renderContext)
        } catch {
            report(error)
        }
    }

    /// Acknowledges libmpv's render wake-up before asking AppKit to draw.
    ///
    /// All mpv render functions for the OpenGL backend must run with the same
    /// OpenGL context current. The callback itself can arrive on an arbitrary
    /// native thread, so `MPVRenderCallbackBox` always invokes this method on
    /// the main render thread rather than calling into libmpv directly.
    fileprivate func consumeRenderUpdateAndRequestDisplay() {
        guard !isTornDown,
              let renderContext,
              let openGLContext = renderOpenGLContext else { return }
        openGLContext.makeCurrentContext()
        let flags = player.renderUpdate(renderContext)
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
        renderUpdatesForTesting += 1
#endif
        if flags & mpvRenderUpdateFrame != 0 { hasPendingRenderFrame = true }
        guard hasPendingRenderFrame || presentedGeometryRevision != geometryRevision else { return }
        if canPresent {
            needsDisplay = true
        } else if hasPendingRenderFrame {
            // Advanced render control requires every announced frame to be
            // acknowledged. Skip it without touching the drawable so hidden
            // or miniaturized playback cannot block the mpv core.
            do {
                try player.skipRender(renderContext)
                hasPendingRenderFrame = false
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
                skippedFramesForTesting += 1
#endif
            } catch {
                report(error)
            }
        }
    }

    func tearDown() {
        isTornDown = true
        finishFullscreenPresentation()
        geometryRevision &+= 1
        markSurfaceUnavailable()
        guard let renderContext else { return }
        // Fence both queued libmpv wake-ups and AppKit draws before freeing the
        // native render context. `draw(_:)` may still be called once by the
        // backing layer, but it will observe nil and return without touching
        // an already-detached NSGraphicsContext.
        callbackBox?.setDisplaySuspended(true)
        hasPendingRenderFrame = false
        needsDisplay = false
        self.renderContext = nil
        renderOpenGLContext?.makeCurrentContext()
        player.setRenderUpdateCallback(
            renderContext: renderContext,
            callback: nil,
            context: nil
        )
        player.destroyRenderContext(renderContext)
        renderOpenGLContext = nil
        callbackBox = nil
        NSOpenGLContext.clearCurrentContext()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tearDown()
    }

    @objc private func playerWillShutdown(_ notification: Notification) {
        guard notification.userInfo?["renderOwnerID"] as? String
                == renderOwnerID.uuidString else { return }
        tearDown()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window,
              MPVRenderVisibilityPolicy.shouldRequestDisplay(
                  isAttachedToWindow: window != nil,
                  isWindowVisible: window?.isVisible == true,
                  isMiniaturized: window?.isMiniaturized == true,
                  isOcclusionVisible:
                      window?.occlusionState.contains(.visible) == true
              ) else { return }
        synchronizeDrawableAfterWindowLayout()
    }

    private func updateWindowObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            WindowTransitionCoordinator.didFailFullScreen
        ]
        for name in names {
            center.removeObserver(self, name: name, object: nil)
            if let window {
                center.addObserver(
                    self,
                    selector: #selector(windowVisibilityChanged(_:)),
                    name: name,
                    object: window
                )
            }
        }
    }

    private func evaluateSurfaceReadiness() {
        guard !isSurfaceReady,
              openGLContext != nil,
              renderContext != nil,
              MPVRenderSafetyPolicy.framebufferSize(
                  backingBounds: convertToBacking(bounds),
                  isInLiveResize: window?.inLiveResize == true,
                  isAttachedToWindow: window != nil
              ) != nil else { return }
        // `NSOpenGLView` has no standalone "drawable is ready" callback.
        // Schedule an actual empty mpv render + drawable flush. Only that
        // successful render probe may publish readiness and release loadfile.
        needsDisplay = true
    }

    private func markSurfaceReadyAfterRenderProbe(
        framebufferSize: (width: Int32, height: Int32)
    ) {
        guard !isSurfaceReady,
              openGLContext != nil,
              renderContext != nil,
              MPVRenderSurfaceReadinessPolicy.isReady(
                  isAttachedToWindow: window != nil,
                  hasSuperview: superview != nil,
                  hasOpenGLContext: true,
                  hasRenderContext: true,
                  drawableWidth: framebufferSize.width,
                  drawableHeight: framebufferSize.height
              ) else { return }
        isSurfaceReady = true
        PlayerExperimentLogger.lifecycle(
            "render surface ready after render probe "
                + "drawable=\(framebufferSize.width)x\(framebufferSize.height)",
            playerID: renderOwnerID,
            mode: player.teardownMode
        )
        onSurfaceReady(renderOwnerID)
    }

    private func markSurfaceUnavailable() {
        guard isSurfaceReady else { return }
        isSurfaceReady = false
        PlayerExperimentLogger.lifecycle(
            "render surface unavailable",
            playerID: renderOwnerID,
            mode: player.teardownMode
        )
        onSurfaceUnavailable(renderOwnerID)
    }

    private func report(_ error: Error) {
        guard !didReportRenderError else { return }
        didReportRenderError = true
        DispatchQueue.main.async {
            self.onError(error)
        }
    }
}

struct MPVRenderView: NSViewRepresentable {
    let player: MPVPlayerClient
    let onError: (Error) -> Void
    let onSurfaceReady: (UUID) -> Void
    let onSurfaceUnavailable: (UUID) -> Void

    func makeNSView(context: Context) -> MPVOpenGLView {
        MPVOpenGLView(
            player: player,
            onError: onError,
            onSurfaceReady: onSurfaceReady,
            onSurfaceUnavailable: onSurfaceUnavailable
        )
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {}

    static func dismantleNSView(
        _ nsView: MPVOpenGLView,
        coordinator: ()
    ) {
        nsView.tearDown()
    }
}
