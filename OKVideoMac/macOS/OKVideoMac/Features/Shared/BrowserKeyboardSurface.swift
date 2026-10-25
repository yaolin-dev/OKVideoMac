import AppKit
import SwiftUI

@MainActor
protocol BrowserHoverTarget: AnyObject {
    func setBrowserHovered(_ hovered: Bool)
}

enum BrowserHoverStyle {
    static let cornerRadius: CGFloat = 8
    static var color: NSColor { .labelColor.withAlphaComponent(0.035) }
}

/// A single tracker per scroll surface. Scrolling never changes selection,
/// layout, image requests, or SwiftUI state, and only the old/new targets redraw.
@MainActor
final class BrowserHoverController: NSObject {
    private static var associationKey: UInt8 = 0
    static func attached(to scroll: NSScrollView) -> BrowserHoverController {
        if let existing = objc_getAssociatedObject(scroll, &associationKey) as? BrowserHoverController { return existing }
        let controller = BrowserHoverController(scroll: scroll)
        objc_setAssociatedObject(scroll, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
    private weak var scroll: NSScrollView?
    private var inputMonitor: Any?
    private weak var observedWindow: NSWindow?
    private let backgrounds = NSHashTable<NSView>.weakObjects()
    var resolveTarget: (() -> NSView?)?

    private var hoverTracking: NSTrackingArea?
    private weak var hoveredView: NSView?
    private var settleTimer: Timer?
    private var gestureActive = false
    private var momentumActive = false
    private var liveScrollActive = false
    private(set) var hoverSuppressed = false

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init()
        configureHover()
        updateWindow()
        updateTrackingAreas()
        if !(scroll is BrowserHoverScrollView) {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scroll = self.scroll, event.window === scroll.window,
                      !scroll.isHiddenOrHasHiddenAncestor,
                      (self.gestureActive || self.momentumActive || self.liveScrollActive ||
                       scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))) else { return event }
                self.noteHoverScroll(phase: event.phase, momentumPhase: event.momentumPhase)
                return event
            }
        }
    }
    func register(_ background: NSView) {
        if observedWindow !== scroll?.window { updateWindow() }
        backgrounds.add(background); refreshBrowserHover()
    }
    func unregister(_ background: NSView) {
        backgrounds.remove(background)
        if hoveredView === background { setHoverTarget(nil) }
    }
    private func configureHover() {
        guard let scroll else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewportMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(liveScrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    deinit {
        settleTimer?.invalidate()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
    func updateWindow() {
        observedWindow = scroll?.window
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        resetBrowserHover()
        if let window = scroll?.window {
            center.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowActivated), name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }
    func resetBrowserHover() {
        settleTimer?.invalidate(); settleTimer = nil
        gestureActive = false; momentumActive = false; liveScrollActive = false
        hoverSuppressed = false
        setHoverTarget(nil)
    }
    @objc private func windowResigned() { resetBrowserHover() }
    @objc private func windowActivated() { refreshBrowserHover() }
    func updateTrackingAreas() {
        guard let scroll else { return }
        if let hoverTracking { scroll.removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        scroll.addTrackingArea(tracking); hoverTracking = tracking
        refreshBrowserHover()
    }
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { refreshBrowserHover() }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { refreshBrowserHover() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { setHoverTarget(nil) }
    func noteHoverScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        if !phase.intersection([.began, .changed, .stationary]).isEmpty { gestureActive = true }
        if !phase.intersection([.ended, .cancelled]).isEmpty { gestureActive = false }
        if !momentumPhase.intersection([.began, .changed]).isEmpty { momentumActive = true }
        if !momentumPhase.intersection([.ended, .cancelled]).isEmpty { momentumActive = false }
        suppressAndScheduleHover()
    }
    @objc private func liveScrollBegan() {
        liveScrollActive = true
        suppressAndScheduleHover()
    }
    @objc private func liveScrollEnded() {
        liveScrollActive = false
        suppressAndScheduleHover()
    }
    @objc private func viewportMoved() { suppressAndScheduleHover() }
    private func suppressAndScheduleHover() {
        hoverSuppressed = true
        setHoverTarget(nil)
        settleTimer?.invalidate(); settleTimer = nil
        guard !gestureActive, !momentumActive, !liveScrollActive else { return }
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleTimer = nil
                self.hoverSuppressed = false
                self.refreshBrowserHover()
            }
        }
        settleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func refreshBrowserHover() {
        guard !hoverSuppressed else { return }
        if let resolveTarget { setHoverTarget(resolveTarget()) }
        else { setHoverTarget(hoverTargetUnderMouse()) }
    }
    func hoverTargetUnderMouse() -> NSView? {
        guard let scroll, let window = scroll.window, window.isKeyWindow,
              !scroll.isHiddenOrHasHiddenAncestor else { return nil }
        return hoverTarget(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }
    func hoverTarget(atWindowPoint point: NSPoint) -> NSView? {
        guard let scroll, let document = scroll.documentView else { return nil }
        let clipPoint = scroll.contentView.convert(point, from: nil)
        guard scroll.contentView.bounds.contains(clipPoint) else { return nil }
        // Legacy SwiftUI card backgrounds are siblings of their hit-test views.
        // Check only mounted backgrounds; they never publish SwiftUI hover state.
        for view in backgrounds.allObjects where !view.isHiddenOrHasHiddenAncestor {
            let local = view.convert(point, from: nil)
            if view.bounds.contains(local), view.visibleRect.contains(local) { return view }
        }
        var hit = document.hitTest(clipPoint)
        while let view = hit, view !== document {
            if view is BrowserHoverTarget { return view }
            hit = view.superview
        }
        return nil
    }
    private func setHoverTarget(_ target: NSView?) {
        // Reapply true for a reused view whose content reset its own highlight.
        guard hoveredView !== target else {
            (target as? BrowserHoverTarget)?.setBrowserHovered(true)
            return
        }
        (hoveredView as? BrowserHoverTarget)?.setBrowserHovered(false)
        hoveredView = target
        (target as? BrowserHoverTarget)?.setBrowserHovered(true)
    }
}

class BrowserHoverScrollView: NSScrollView {
    private var hoverController: BrowserHoverController { BrowserHoverController.attached(to: self) }
    var hoverSuppressed: Bool { hoverController.hoverSuppressed }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverController.resolveTarget = { [weak self] in self?.hoverTargetUnderMouse() }
        hoverController.updateWindow()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverController.updateTrackingAreas()
    }
    override func scrollWheel(with event: NSEvent) {
        noteHoverScroll(phase: event.phase, momentumPhase: event.momentumPhase)
        super.scrollWheel(with: event)
    }
    func noteHoverScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        hoverController.noteHoverScroll(phase: phase, momentumPhase: momentumPhase)
    }
    func resetBrowserHover() { hoverController.resetBrowserHover() }
    func refreshBrowserHover() {
        hoverController.resolveTarget = { [weak self] in self?.hoverTargetUnderMouse() }
        hoverController.refreshBrowserHover()
    }
    func hoverTargetUnderMouse() -> NSView? { hoverController.hoverTargetUnderMouse() }
}

struct BrowserHoverBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> Background { Background() }
    func updateNSView(_ view: Background, context: Context) {}
    static func dismantleNSView(_ view: Background, coordinator: ()) { view.detach() }
    final class Background: NSView, BrowserHoverTarget {
        private weak var controller: BrowserHoverController?
        private var hovered = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func layout() { super.layout(); if controller == nil { attach() } }
        private func attach() {
            detach()
            guard window != nil, let scroll = enclosingScrollView else { return }
            let controller = BrowserHoverController.attached(to: scroll)
            self.controller = controller
            controller.register(self)
        }
        func detach() { controller?.unregister(self); controller = nil; setBrowserHovered(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func setBrowserHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value; needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard hovered else { return }
            BrowserHoverStyle.color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: BrowserHoverStyle.cornerRadius,
                         yRadius: BrowserHoverStyle.cornerRadius).fill()
        }
    }
}

struct PosterBrowseAnchor: Equatable, Sendable {
    let itemID: String
    let offset: CGFloat
    let atTop: Bool

    static func capture(ids: [String], metrics: PosterScrollMetrics, showsSubtitle: Bool = false) -> Self? {
        guard !ids.isEmpty, metrics.regionSize.width > 0 else { return nil }
        let columns = PosterGridMetrics.columnCount(width: metrics.regionSize.width)
        let stride = PosterGridMetrics.cardHeight(width: PosterGridMetrics.cardWidth(width: metrics.regionSize.width), showsSubtitle: showsSubtitle) + PosterGridMetrics.rowSpacing
        let relative = metrics.offset - metrics.regionTop
        let row = max(0, Int(floor(relative / stride)))
        let index = min(ids.count - 1, row * columns)
        return .init(itemID: ids[index], offset: relative - CGFloat(index / columns) * stride, atTop: metrics.offset <= 1)
    }

    func targetOffset(ids: [String], width: CGFloat, regionTop: CGFloat, showsSubtitle: Bool = false) -> CGFloat? {
        if atTop { return 0 }
        guard let index = ids.firstIndex(of: itemID), width > 0 else { return nil }
        let columns = PosterGridMetrics.columnCount(width: width)
        let stride = PosterGridMetrics.cardHeight(width: PosterGridMetrics.cardWidth(width: width), showsSubtitle: showsSubtitle) + PosterGridMetrics.rowSpacing
        return regionTop + CGFloat(index / columns) * stride + offset
    }
}

struct PosterScrollRestoration {
    let id: UUID
    let anchor: PosterBrowseAnchor?
}

struct PosterScrollMetrics: Equatable {
    var offset: CGFloat
    var viewport: CGSize
    var regionTop: CGFloat
    var regionSize: CGSize
    var interactionRevision: UInt64 = 0
    var remaining: CGFloat { regionTop - offset - viewport.height }
}

/// Scoped to this view's enclosing scroll view; never searches another window
/// or changes native scroll physics. Coalesces native notifications off layout.
struct PosterScrollObserver: NSViewRepresentable {
    var itemIDs: [String] = []
    var restoration: PosterScrollRestoration? = nil
    var onUpdate: (PosterScrollMetrics) -> Void
    func makeNSView(context: Context) -> PosterScrollProbe { PosterScrollProbe() }
    func updateNSView(_ view: PosterScrollProbe, context: Context) {
        view.onUpdate = onUpdate
        view.itemIDs = itemIDs
        view.receive(restoration)
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: PosterScrollProbe, coordinator: ()) { view.stop() }
}

final class PosterScrollProbe: NSView {
    var onUpdate: ((PosterScrollMetrics) -> Void)?
    var itemIDs: [String] = []
    private var receivedRestorationID: UUID?
    private var pendingRestoration: (request: PosterScrollRestoration, revision: UInt64)?
    private var lastMetrics: PosterScrollMetrics?
    private var lastAnchor: PosterBrowseAnchor?
    private weak var observedClip: NSClipView?
    private var observations: [NSObjectProtocol] = []
    private var inputMonitor: Any?
    private var pending = false
    private var revision: UInt64 = 0
    func receive(_ restoration: PosterScrollRestoration?) {
        guard let restoration, restoration.id != receivedRestorationID else { return }
        receivedRestorationID = restoration.id
        pendingRestoration = (restoration, revision)
        scheduleUpdate()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bind(); scheduleUpdate() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
    override func layout() { super.layout(); scheduleUpdate() }
    func stop() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        observedClip = nil
    }
    private func bind() {
        guard let scroll = enclosingScrollView, window != nil else { stop(); return }
        let clip = scroll.contentView
        guard observedClip !== clip else {
            updateInputMonitor()
            return
        }
        stop()
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                self?.scheduleUpdate()
            })
        }
        updateInputMonitor()
    }
    private func updateInputMonitor() {
        // The footer and toolbar need clip bounds only. Only a grid with item
        // anchors needs an input generation to cancel a pending restoration.
        guard !itemIDs.isEmpty else {
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            return
        }
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let scroll = self.enclosingScrollView, event.window === self.window else { return event }
            let inRegion: Bool
            if event.type == .keyDown {
                inRegion = (self.window?.firstResponder as? NSView)?.isDescendant(of: scroll) == true
            } else {
                inRegion = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            }
            if inRegion { self.revision &+= 1; self.scheduleUpdate() }
            return event
        }
    }
    func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.bind()
            guard let scroll = self.enclosingScrollView, let document = scroll.documentView, self.window != nil else { return }
            let clip = scroll.contentView
            let region = self.convert(self.bounds, to: document)
            // A unified title bar gives the native scroll view a top inset.
            // Its real resting origin is -topInset, not zero. Use logical
            // document coordinates for policies, and preserve the native inset
            // when converting an explicit restore back to clip coordinates.
            let topInset = scroll.contentInsets.top
            let bottomInset = scroll.contentInsets.bottom
            var offset = (document.isFlipped ? clip.bounds.minY - document.bounds.minY : document.bounds.maxY - clip.bounds.maxY) + topInset
            let top = (document.isFlipped ? region.minY - document.bounds.minY : document.bounds.maxY - region.maxY) + topInset
            var target: CGFloat?
            if let pending = self.pendingRestoration, self.bounds.width > 0, self.bounds.height > 0, !self.itemIDs.isEmpty {
                self.pendingRestoration = nil
                if pending.revision == self.revision {
                    target = pending.request.anchor?.targetOffset(ids: self.itemIDs, width: self.bounds.width, regionTop: top) ?? 0
                }
            } else if let last = self.lastMetrics, let anchor = self.lastAnchor,
                      abs(last.regionSize.width - self.bounds.width) > 1,
                      last.interactionRevision == self.revision {
                target = anchor.targetOffset(ids: self.itemIDs, width: self.bounds.width, regionTop: top)
            }
            if let target {
                let clamped = min(max(0, target), max(0, document.bounds.height + topInset + bottomInset - clip.bounds.height))
                let y = document.isFlipped ? document.bounds.minY + clamped - topInset : document.bounds.maxY - clip.bounds.height - clamped + topInset
                if abs(clamped - offset) > 0.5 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                    scroll.reflectScrolledClipView(clip)
                    offset = clamped
                }
            }
            let metrics = PosterScrollMetrics(offset: max(0, offset), viewport: clip.bounds.size,
                regionTop: top, regionSize: self.bounds.size, interactionRevision: self.revision)
            self.lastMetrics = metrics
            self.lastAnchor = PosterBrowseAnchor.capture(ids: self.itemIDs, metrics: metrics)
            self.onUpdate?(metrics)
        }
    }
    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
}

enum BrowserGridNavigation {
    static func destination(index: Int?, count: Int, columns: Int, key: UInt16) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let columns = max(1, columns)
        switch key {
        case 123: return index % columns == 0 ? index : index - 1
        case 124: return min(count - 1, index + 1)
        case 125: return min(count - 1, index + columns)
        case 126: return max(0, index - columns)
        default: return index
        }
    }
}

enum BrowserFocusOwnershipPolicy {
    static func mayClaimDefaultFocus(
        initial: NSResponder?,
        current: NSResponder?,
        window: NSWindow
    ) -> Bool {
        let initialIsNeutral = initial === window || initial === window.contentView
        return initialIsNeutral && current === initial
    }
}

/// A real first responder for one content region. Unlike window key monitors,
/// it cannot consume arrows or Delete while the sidebar/search owns focus.
private struct BrowserNavigationSelectionKey: EnvironmentKey {
    static let defaultValue: NavigationSelection? = nil
}

extension EnvironmentValues {
    var browserNavigationSelection: NavigationSelection? {
        get { self[BrowserNavigationSelectionKey.self] }
        set { self[BrowserNavigationSelectionKey.self] = newValue }
    }
}

@MainActor
protocol BrowserContentKeyTarget: AnyObject {
    var navigationSelection: NavigationSelection? { get }
}

struct BrowserKeyboardSurface: NSViewRepresentable {
    @Environment(\.browserNavigationSelection) private var navigationSelection
    var handler: (NSEvent) -> Bool
    var onFocus: (Bool) -> Void = { _ in }
    var onWidth: (CGFloat) -> Void = { _ in }
    var onViewport: (CGRect) -> Void = { _ in }

    func makeNSView(context: Context) -> BrowserKeyboardView { BrowserKeyboardView() }
    func updateNSView(_ view: BrowserKeyboardView, context: Context) {
        view.navigationSelection = navigationSelection
        view.handler = handler
        view.onFocus = onFocus
        view.onWidth = onWidth
        view.onViewport = onViewport
        view.notifySidebarOfContentUpdate()
    }
}

final class BrowserKeyboardView: NSView, BrowserContentKeyTarget {
    var navigationSelection: NavigationSelection?
    var handler: ((NSEvent) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onViewport: ((CGRect) -> Void)?
    private var mouseMonitor: Any?
    private var lastWidth: CGFloat = 0
    private weak var cachedSidebar: BrowserSidebarOutlineView?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        notifySidebarOfContentUpdate()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        let width = lastWidth
        DispatchQueue.main.async { [weak self] in self?.onWidth?(width) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard let window else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            window.makeFirstResponder(self)
            return event
        }
        let initialResponder = window.firstResponder
        guard BrowserFocusOwnershipPolicy.mayClaimDefaultFocus(
            initial: initialResponder,
            current: initialResponder,
            window: window
        ) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  !self.isHiddenOrHasHiddenAncestor else { return }
            let responder = window.firstResponder
            // Mounting is asynchronous. Only take the default focus when the
            // responder has stayed at the same neutral window/content view;
            // a sidebar, search field, toolbar item or another content region
            // selected meanwhile always wins.
            guard BrowserFocusOwnershipPolicy.mayClaimDefaultFocus(
                initial: initialResponder,
                current: responder,
                window: window
            ) else { return }
            window.makeFirstResponder(self)
        }
    }

    func notifySidebarOfContentUpdate() {
        if cachedSidebar?.window !== window || cachedSidebar == nil {
            cachedSidebar = Self.descendants(of: window?.contentView).first { $0 is BrowserSidebarOutlineView } as? BrowserSidebarOutlineView
        }
        cachedSidebar?.scheduleContentFocus()
    }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.onFocus?(true)
        }
        return true
    }
    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self else { return }
            self.onFocus?(false)
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        let rect = visibleRect
        onViewport?(CGRect(x: rect.minX, y: isFlipped ? rect.minY : bounds.maxY - rect.maxY,
                           width: rect.width, height: rect.height))
        if handler?(event) == true { return }
        // A content boundary never transfers ordinary arrows to navigation.
        if [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { return }
        super.keyDown(with: event)
    }
    static func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }
}

/// Explicit actions own navigation; native selection notifications only mirror it.
final class BrowserSidebarOutlineView: NSOutlineView {
    var onActivateRow: ((Int) -> Void)?
    var currentNavigationSelection: (() -> NavigationSelection)?
    private var pendingFocus: (selection: NavigationSelection, isCurrent: () -> Bool)?
    private var focusWork: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        focusWork?.cancel()
        pendingFocus = nil
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0, clickedRow < numberOfRows else { return }
        window?.makeFirstResponder(self)
        // Source-list rows are commands. Do not enter NSTableView's tracking
        // loop, which can replay a selection after the SwiftUI route changed.
        onActivateRow?(clickedRow)
    }

    func requestContentFocus(for selection: NavigationSelection, isCurrent: @escaping () -> Bool) {
        focusWork?.cancel()
        pendingFocus = (selection, isCurrent)
        scheduleContentFocus()
    }

    func scheduleContentFocus() {
        guard pendingFocus != nil else { return }
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.completeContentFocus() }
        focusWork = work
        DispatchQueue.main.async(execute: work)
    }

    func completeContentFocus() {
        guard let pending = pendingFocus else { return }
        guard pending.isCurrent(), window?.firstResponder === self else {
            pendingFocus = nil
            return
        }
        guard let target = contentTarget(selection: pending.selection) else { return }
        pendingFocus = nil
        window?.makeFirstResponder(target)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           [123, 124, 125, 126].contains(event.keyCode) {
            if let target = contentTarget(selection: currentNavigationSelection?()) {
                window?.makeFirstResponder(target)
                target.keyDown(with: event)
            }
            // Empty/loading pages have no content responder yet. Never fall
            // back to NSOutlineView's built-in arrow selection in that case.
            return
        }
        super.keyDown(with: event)
    }

    private func contentTarget(selection: NavigationSelection? = nil) -> NSView? {
        BrowserKeyboardView.descendants(of: window?.contentView).first(where: {
            guard let target = $0 as? BrowserContentKeyTarget else { return false }
            return (selection == nil || target.navigationSelection == selection)
                && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        })
    }
}

/// Bounded diagnostics, deliberately not published into SwiftUI/AppState.
/// Only event names, revisions and opaque request identifiers belong here.
@MainActor
enum BrowserInteractionTrace {
    struct Entry {
        let event: String
        let revision: UInt64?
        let request: UUID?
        let time: TimeInterval
    }
    private(set) static var entries: [Entry] = []
    static func record(_ event: String, revision: UInt64? = nil, request: UUID? = nil) {
        if entries.count == 128 { entries.removeFirst() }
        entries.append(Entry(event: event, revision: revision, request: request,
                             time: ProcessInfo.processInfo.systemUptime))
    }
}

/// One current item for both input methods; hover is transient and never adds
/// a second highlight. Focus ownership itself does not select an item.
struct BrowserItemSelection: Equatable {
    private(set) var currentID: String?
    private(set) var hoveredID: String?
    var highlightedID: String? { hoveredID ?? currentID }
    mutating func select(_ id: String) { currentID = id; hoveredID = nil }
    mutating func hover(_ id: String, inside: Bool) {
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
    }
    mutating func reconcile(_ ids: [String]) {
        if let currentID, !ids.contains(currentID) { self.currentID = nil }
        if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
    }
}

/// Measure plain, single-line AppKit labels only when their text/font/width changes.
/// Tooltip tracking is owned by AppKit; no mouse-move measurement or polling.
enum BrowserTextOverflow {
    static func tooltip(for field: NSTextField) -> String? {
        guard !field.stringValue.isEmpty, field.bounds.width > 0, field.bounds.height > 0 else { return nil }
        let drawingWidth = field.cell?.drawingRect(forBounds: field.bounds).width ?? field.bounds.width
        let naturalWidth = field.attributedStringValue.size().width
        return naturalWidth > drawingWidth + 0.5 || field.stringValue.contains("\n") ? field.stringValue : nil
    }
}

final class NativeOverflowTooltipField: NSTextField {
    var supplementalToolTip: String? {
        didSet { if supplementalToolTip != oldValue { refreshOverflowToolTip() } }
    }
    private var previousText: NSAttributedString?
    private var previousSize: NSSize?
    private var previousSupplement: String?

    override var stringValue: String {
        didSet {
            if stringValue != oldValue { previousText = nil; toolTip = nil; needsLayout = true }
        }
    }
    override func layout() {
        super.layout()
        refreshOverflowToolTip()
    }
    func refreshOverflowToolTip() {
        let text = attributedStringValue
        guard previousText != text || previousSize != bounds.size || previousSupplement != supplementalToolTip else { return }
        previousText = text.copy() as? NSAttributedString
        previousSize = bounds.size
        previousSupplement = supplementalToolTip
        let pieces = [BrowserTextOverflow.tooltip(for: self), supplementalToolTip == stringValue ? nil : supplementalToolTip]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let value = pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        if toolTip != value { toolTip = value }
    }
}

private struct TextOverflowMeasurement: Equatable {
    let text: String
    let truncated: Bool
}
private struct TextOverflowPreference: PreferenceKey {
    static let defaultValue: TextOverflowMeasurement? = nil
    static func reduce(value: inout TextOverflowMeasurement?, nextValue: () -> TextOverflowMeasurement?) {
        if let next = nextValue() { value = next }
    }
}

/// Uses the same SwiftUI font/layout for visible and full text, including CJK,
/// multiline titles and accessibility text sizes. Only this label keeps state.
struct TruncationAwareText: View {
    let text: String
    let font: Font
    var lineLimit: Int = 1
    var minimumScaleFactor: CGFloat = 1
    @State private var measurement: TextOverflowMeasurement?

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
            .background {
                GeometryReader { visible in
                    Text(text)
                        .font(font)
                        .lineLimit(nil)
                        .fixedSize(horizontal: lineLimit == 1, vertical: true)
                        .background {
                            GeometryReader { full in
                                Color.clear.preference(key: TextOverflowPreference.self, value:
                                    TextOverflowMeasurement(text: text, truncated: lineLimit == 1
                                        ? full.size.width * minimumScaleFactor > visible.size.width + 0.5
                                        : full.size.height > visible.size.height + 0.5))
                            }
                        }
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .onPreferenceChange(TextOverflowPreference.self) { value in
                if measurement != value { measurement = value }
            }
            .background {
                OverflowToolTipRegion(text: measurement?.text == text && measurement?.truncated == true ? text : nil)
                    .accessibilityHidden(true)
            }
    }
}

struct OverflowToolTipRegion: NSViewRepresentable {
    let text: String?
    func makeNSView(context: Context) -> OverflowToolTipView { OverflowToolTipView() }
    func updateNSView(_ view: OverflowToolTipView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
    static func dismantleNSView(_ view: OverflowToolTipView, coordinator: ()) { view.toolTip = nil }
}

/// A tooltip region participates in native tracking, but never takes a click
/// from its enclosing poster, filter, or person button.
final class OverflowToolTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
