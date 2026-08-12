import AppKit
import Darwin
import OpenGL
import SwiftUI

extension Notification.Name {
    static let mpvPlayerWillShutdown = Notification.Name(
        "com.okvideomac.player.will-shutdown"
    )
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

    /// AppKit already owns display-region bookkeeping during a live window
    /// resize. Suspending mpv invalidations avoids racing that private region
    /// transaction; the view requests one fresh frame when resizing ends.
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
            if self.view?.window?.inLiveResize != true {
                // libmpv's update callback is a wake-up signal: consume it
                // promptly on the OpenGL render thread instead of waiting for
                // AppKit to eventually call draw(_:). A detail sheet can be
                // dismissed while this persistent surface is still becoming
                // visible; AppKit may coalesce that first needsDisplay without
                // drawing. If renderUpdate is deferred until draw, libmpv can
                // then wait for an acknowledgement and video advances only on
                // unrelated UI redraws while audio continues normally.
                self.view?.consumeRenderUpdateAndRequestDisplay()
            }
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
        isInLiveResize: Bool,
        isAttachedToWindow: Bool
    ) -> (width: Int32, height: Int32)? {
        guard isAttachedToWindow,
              !isInLiveResize else { return nil }
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

final class MPVOpenGLView: NSOpenGLView {
    private let player: MPVPlayerClient
    private let renderOwnerID: String
    private let onError: (Error) -> Void
    private var renderContext: OpaquePointer?
    private var callbackBox: MPVRenderCallbackBox?
    private var didReportRenderError = false

    init(
        player: MPVPlayerClient,
        onError: @escaping (Error) -> Void
    ) {
        self.player = player
        renderOwnerID = player.renderOwnerID.uuidString
        self.onError = onError
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
        guard renderContext == nil else { return }
        openGLContext?.makeCurrentContext()
        let box = MPVRenderCallbackBox(view: self)
        callbackBox = box
        do {
            let opaque = Unmanaged.passUnretained(box).toOpaque()
            let context = try player.makeRenderContext(
                getProcAddress: mpvOpenGLGetProcAddress,
                context: opaque
            )
            renderContext = context
            player.setRenderUpdateCallback(
                renderContext: context,
                callback: mpvRenderUpdateCallback,
                context: opaque
            )
        } catch {
            report(error)
        }
    }

    override func reshape() {
        super.reshape()
        guard window?.inLiveResize != true else { return }
        needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        callbackBox?.setDisplaySuspended(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        callbackBox?.setDisplaySuspended(false)
        needsDisplay = true
        // A callback received while live resize was suspended was deliberately
        // ignored. Consume any pending render update now so libmpv can resume
        // issuing frame notifications without requiring another AppKit redraw.
        callbackBox?.requestDisplay()
    }

    /// Window chrome changes (notably toggling `fullSizeContentView`) can move
    /// an NSOpenGLView without producing the same drawable update as an
    /// ordinary user resize. Keep the OpenGL drawable in lockstep with the
    /// final AppKit layout instead of waiting for a full-screen round trip.
    func synchronizeDrawableAfterWindowLayout() {
        guard window?.inLiveResize != true else { return }
        openGLContext?.update()
        needsDisplay = true
        callbackBox?.requestDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit can deliver one final layer-backed draw after this view has
        // detached from its drawable. At that point NSGraphicsContext has no
        // current CGContext, so even a fallback NSColor fill traps. A nil mpv
        // context means teardown owns the surface and there is nothing left
        // for this view to draw.
        guard let renderContext,
              let openGLContext,
              let framebufferSize = MPVRenderSafetyPolicy.framebufferSize(
                backingBounds: convertToBacking(bounds),
                isInLiveResize: window?.inLiveResize == true,
                isAttachedToWindow: window != nil
              ) else { return }
        openGLContext.makeCurrentContext()
        do {
            try player.render(
                renderContext,
                framebuffer: 0,
                width: framebufferSize.width,
                height: framebufferSize.height,
                flipY: true
            )
            openGLContext.flushBuffer()
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
        guard window != nil,
              window?.inLiveResize != true,
              let renderContext,
              let openGLContext else { return }
        openGLContext.makeCurrentContext()
        let flags = player.renderUpdate(renderContext)
        if flags & mpvRenderUpdateFrame != 0 {
            needsDisplay = true
        }
    }

    func tearDown() {
        guard let renderContext else { return }
        // Fence both queued libmpv wake-ups and AppKit draws before freeing the
        // native render context. `draw(_:)` may still be called once by the
        // backing layer, but it will observe nil and return without touching
        // an already-detached NSGraphicsContext.
        callbackBox?.setDisplaySuspended(true)
        needsDisplay = false
        self.renderContext = nil
        openGLContext?.makeCurrentContext()
        player.setRenderUpdateCallback(
            renderContext: renderContext,
            callback: nil,
            context: nil
        )
        player.destroyRenderContext(renderContext)
        callbackBox = nil
        NSOpenGLContext.clearCurrentContext()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tearDown()
    }

    @objc private func playerWillShutdown(_ notification: Notification) {
        guard notification.userInfo?["renderOwnerID"] as? String
                == renderOwnerID else { return }
        tearDown()
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

    func makeNSView(context: Context) -> MPVOpenGLView {
        MPVOpenGLView(player: player, onError: onError)
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {}

    static func dismantleNSView(
        _ nsView: MPVOpenGLView,
        coordinator: ()
    ) {
        nsView.tearDown()
    }
}
