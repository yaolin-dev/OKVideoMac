import AppKit
import Foundation
import ObjectiveC

/// Tracks the whole AppKit transition, including intervals where inLiveResize
/// is already false. It never replaces a window's existing delegate.
@MainActor
final class WindowTransitionCoordinator {
    enum Phase { case windowed, enteringFullScreen, fullScreen, exitingFullScreen }
    private static var associationKey: UInt8 = 0
    static let didFailFullScreen = Notification.Name("com.okvideomac.window.fullscreen-failed")
    static let fullScreenPhaseDidChange = Notification.Name("com.okvideomac.window.fullscreen-phase-changed")

    static func state(for window: NSWindow) -> WindowTransitionCoordinator {
        if let state = objc_getAssociatedObject(window, &associationKey) as? WindowTransitionCoordinator {
            return state
        }
        let state = WindowTransitionCoordinator(window: window)
        objc_setAssociatedObject(window, &associationKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    private weak var window: NSWindow?
    private(set) var phase: Phase
    private(set) var isClosing = false
    private(set) var generation: UInt64 = 0
    private var isLiveResizing = false
    private var observations: [NSObjectProtocol] = []
    private var scheduled = false
    private var desiredFullScreen: Bool?
    private var fullscreenStartedAt: TimeInterval?
    private var fullscreenRecovery: DispatchWorkItem?
    var onFullScreenRecovery: ((NSWindow) -> Void)?
    private struct Pending {
        let windowedOnly: Bool
        let action: (NSWindow?) -> Void
    }
    private var pending: [UUID: Pending] = [:]
    private var pendingOrder: [UUID] = []
    var chromeOwner: UUID?
    var browserChromeConfigured = false

    var isTransitioning: Bool {
        phase == .enteringFullScreen || phase == .exitingFullScreen ||
            isLiveResizing || window?.inLiveResize == true
    }
    var canApplyChrome: Bool { !isClosing && !isTransitioning }
    var canChangeGeometry: Bool {
        canApplyChrome && phase == .windowed && window?.styleMask.contains(.fullScreen) == false
    }

    private init(window: NSWindow) {
        self.window = window
        phase = window.styleMask.contains(.fullScreen) ? .fullScreen : .windowed
        let names: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            observations.append(NotificationCenter.default.addObserver(forName: name,
                object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.receive(note.name) }
                })
        }
    }

    deinit { fullscreenRecovery?.cancel(); observations.forEach(NotificationCenter.default.removeObserver) }

    private func receive(_ name: Notification.Name) {
        guard !isClosing else { return }
        switch name {
        case NSWindow.willEnterFullScreenNotification: beginFullScreen(entering: true)
        case NSWindow.willExitFullScreenNotification: beginFullScreen(entering: false)
        case NSWindow.didEnterFullScreenNotification: completeFullScreen(isFullScreen: true)
        case NSWindow.didExitFullScreenNotification: completeFullScreen(isFullScreen: false)
        case NSWindow.willStartLiveResizeNotification:
            isLiveResizing = true
            generation &+= 1
        case NSWindow.didEndLiveResizeNotification:
            isLiveResizing = false
            scheduleDrain()
        case NSWindow.willCloseNotification:
            fullscreenRecovery?.cancel(); fullscreenRecovery = nil; fullscreenStartedAt = nil
            isClosing = true
            generation &+= 1
            desiredFullScreen = nil
            let actions = pending.values
            pending.removeAll()
            pendingOrder.removeAll()
            actions.forEach { $0.action(nil) }
            publishFullScreenPhase()
        default: break
        }
    }

    func beginFullScreen(entering: Bool) {
        guard !isClosing else { return }
        let next: Phase = entering ? .enteringFullScreen : .exitingFullScreen
        guard phase != next else { return }
        phase = next
        generation &+= 1
        fullscreenStartedAt = ProcessInfo.processInfo.systemUptime
        scheduleFullscreenRecovery()
        publishFullScreenPhase()
    }

    func completeFullScreen(isFullScreen: Bool) {
        guard !isClosing else { return }
        fullscreenRecovery?.cancel(); fullscreenRecovery = nil; fullscreenStartedAt = nil
        phase = isFullScreen ? .fullScreen : .windowed
        isLiveResizing = window?.inLiveResize == true
        if desiredFullScreen == isFullScreen { desiredFullScreen = nil }
        scheduleDrain()
        publishFullScreenPhase()
    }

    private func publishFullScreenPhase() {
        if let window {
            NotificationCenter.default.post(name: Self.fullScreenPhaseDidChange, object: window)
        }
    }

    /// Called by the app-owned player delegate for both public failure hooks.
    func fullScreenDidFail() {
        desiredFullScreen = nil
        completeFullScreen(isFullScreen: window?.styleMask.contains(.fullScreen) == true)
        if let window {
            NotificationCenter.default.post(name: Self.didFailFullScreen, object: window)
        }
    }

    func requestFullScreenToggle() {
        guard !isClosing else { return }
        recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime)
        let target = desiredFullScreen ?? (phase == .fullScreen || phase == .enteringFullScreen)
        desiredFullScreen = !target
        scheduleDrain()
    }

    private func scheduleFullscreenRecovery() {
        fullscreenRecovery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fullscreenStartedAt != nil, !self.isClosing else { return }
            self.recoverStalledFullscreen(at: ProcessInfo.processInfo.systemUptime)
            if self.fullscreenStartedAt != nil { self.scheduleFullscreenRecovery() }
        }
        fullscreenRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Completion/failure notifications can be lost when AppKit abandons a
    /// Space transition. Reconcile only once native live resize is finished;
    /// never rewrite styleMask or start a competing fullscreen animation.
    @discardableResult
    func recoverStalledFullscreen(at now: TimeInterval) -> Bool {
        guard !isClosing, let window, let started = fullscreenStartedAt,
              now - started >= 5, !window.inLiveResize,
              phase == .enteringFullScreen || phase == .exitingFullScreen else { return false }
        onFullScreenRecovery?(window)
        fullScreenDidFail()
        return true
    }

    /// Same key replaces an obsolete request. Every action runs outside the
    /// originating layout/notification stack and is rechecked at execution.
    func whenStable(key: UUID, windowedOnly: Bool = false,
                    action: @escaping (NSWindow?) -> Void) {
        guard !isClosing else { action(nil); return }
        if pending[key] == nil { pendingOrder.append(key) }
        pending[key] = Pending(windowedOnly: windowedOnly, action: action)
        scheduleDrain()
    }

    func cancel(_ key: UUID) {
        pending[key] = nil
        pendingOrder.removeAll { $0 == key }
    }

    private func scheduleDrain() {
        guard !scheduled, !isClosing else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let window = self.window, self.canApplyChrome else { return }
            if let target = self.desiredFullScreen,
               target != window.styleMask.contains(.fullScreen) {
                self.beginFullScreen(entering: target)
                window.toggleFullScreen(nil)
                return
            }
            self.desiredFullScreen = nil
            for key in self.pendingOrder {
                guard self.canApplyChrome, let entry = self.pending[key] else { break }
                if entry.windowedOnly && !self.canChangeGeometry { continue }
                self.cancel(key)
                entry.action(window)
            }
        }
    }
}

enum PlayerWindowMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automaticAspect
    case fixedFrame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automaticAspect: return L10n.string("player.window-sizing.automatic", fallback: "Match Video Automatically")
        case .fixedFrame: return L10n.string("player.window-sizing.fixed", fallback: "Use Last Window Size")
        }
    }
}

struct PlayerWindowPreference: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultViewingWidth = 1_152.0
    static let defaultFixedWidth = 1_152.0
    static let defaultFixedHeight = 648.0

    var version: Int
    var mode: PlayerWindowMode
    var viewingWidth: Double
    var fixedWidth: Double
    var fixedHeight: Double
    var screenIdentifier: UInt32?
    var normalizedCenterX: Double?
    var normalizedCenterY: Double?

    static let `default` = PlayerWindowPreference(
        version: currentVersion,
        mode: .automaticAspect,
        viewingWidth: defaultViewingWidth,
        fixedWidth: defaultFixedWidth,
        fixedHeight: defaultFixedHeight,
        screenIdentifier: nil,
        normalizedCenterX: nil,
        normalizedCenterY: nil
    )
}

enum PlayerWindowPreferencePolicy {
    static let minimumContentWidth = 640.0
    static let minimumContentHeight = 360.0
    static let screenMargin = 40.0
    static let fallbackAspectRatio = 16.0 / 9.0

    static func minimumContentSize(aspectRatio: Double) -> NSSize {
        let ratio = validAspectRatio(aspectRatio) ?? fallbackAspectRatio
        let width = max(minimumContentWidth, minimumContentHeight * ratio)
        return NSSize(width: width, height: width / ratio)
    }

    static func sanitized(
        _ preference: PlayerWindowPreference
    ) -> PlayerWindowPreference {
        var result = preference
        result.version = PlayerWindowPreference.currentVersion
        result.viewingWidth = validLength(
            result.viewingWidth,
            fallback: PlayerWindowPreference.defaultViewingWidth
        )
        result.fixedWidth = validLength(
            result.fixedWidth,
            fallback: PlayerWindowPreference.defaultFixedWidth
        )
        result.fixedHeight = validLength(
            result.fixedHeight,
            fallback: PlayerWindowPreference.defaultFixedHeight
        )
        result.normalizedCenterX = normalized(result.normalizedCenterX)
        result.normalizedCenterY = normalized(result.normalizedCenterY)
        return result
    }

    static func contentSize(
        preference: PlayerWindowPreference,
        aspectRatio: Double,
        maximum: NSSize
    ) -> NSSize {
        let preference = sanitized(preference)
        let maximumWidth = max(1, Double(maximum.width))
        let maximumHeight = max(1, Double(maximum.height))

        switch preference.mode {
        case .automaticAspect:
            let ratio = validAspectRatio(aspectRatio)
                ?? fallbackAspectRatio
            let requestedWidth = max(
                Double(minimumContentSize(aspectRatio: ratio).width),
                preference.viewingWidth
            )
            let width = min(
                requestedWidth,
                maximumWidth,
                maximumHeight * ratio
            )
            return NSSize(
                width: CGFloat(width),
                height: CGFloat(width / ratio)
            )

        case .fixedFrame:
            let requestedWidth = max(
                minimumContentWidth,
                preference.fixedWidth
            )
            let requestedHeight = max(
                minimumContentHeight,
                preference.fixedHeight
            )
            let scale = min(
                1,
                maximumWidth / requestedWidth,
                maximumHeight / requestedHeight
            )
            return NSSize(
                width: CGFloat(requestedWidth * scale),
                height: CGFloat(requestedHeight * scale)
            )
        }
    }

    static func normalizedCenter(
        frame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint? {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else { return nil }
        return NSPoint(
            x: min(
                1,
                max(0, (frame.midX - visibleFrame.minX) / visibleFrame.width)
            ),
            y: min(
                1,
                max(0, (frame.midY - visibleFrame.minY) / visibleFrame.height)
            )
        )
    }

    static func frameOrigin(
        frameSize: NSSize,
        visibleFrame: NSRect,
        normalizedCenterX: Double?,
        normalizedCenterY: Double?
    ) -> NSPoint {
        let centerX = normalized(normalizedCenterX) ?? 0.5
        let centerY = normalized(normalizedCenterY) ?? 0.5
        let desired = NSPoint(
            x: visibleFrame.minX + visibleFrame.width * CGFloat(centerX)
                - frameSize.width / 2,
            y: visibleFrame.minY + visibleFrame.height * CGFloat(centerY)
                - frameSize.height / 2
        )
        return NSPoint(
            x: min(
                max(desired.x, visibleFrame.minX),
                visibleFrame.maxX - frameSize.width
            ),
            y: min(
                max(desired.y, visibleFrame.minY),
                visibleFrame.maxY - frameSize.height
            )
        )
    }

    static func ratiosMatch(
        _ lhs: Double?,
        _ rhs: Double,
        tolerance: Double = 0.01
    ) -> Bool {
        guard let lhs = validAspectRatio(lhs),
              let rhs = validAspectRatio(rhs) else { return false }
        return abs(lhs - rhs) / max(lhs, rhs) < tolerance
    }

    static func validAspectRatio(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              value > 0 else { return nil }
        return value
    }

    private static func validLength(
        _ value: Double,
        fallback: Double
    ) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

@MainActor
final class PlayerWindowPreferenceStore: ObservableObject {
    static let storageKey = "OKVideoMac.PlayerWindowPreference.v1"
    static let legacyFrameAutosaveName = "OKVideoMac.PlayerWindow.v2"

    @Published private(set) var preference: PlayerWindowPreference
    private(set) var hasPersistedPreference: Bool

    private let defaults: UserDefaults
    private let storageKey: String
    private var hasPendingUserFrame = false

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "OKVideoMac.PlayerWindowPreference.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
                PlayerWindowPreference.self,
                from: data
           ) {
            preference = PlayerWindowPreferencePolicy.sanitized(decoded)
            hasPersistedPreference = true
        } else {
            preference = .default
            hasPersistedPreference = false
        }
    }

    func setMode(_ mode: PlayerWindowMode) {
        guard preference.mode != mode else { return }
        preference.mode = mode
        persist()
    }

    func captureModeTransition(
        to mode: PlayerWindowMode,
        currentContentSize: NSSize
    ) {
        guard currentContentSize.width.isFinite,
              currentContentSize.height.isFinite,
              currentContentSize.width > 0,
              currentContentSize.height > 0 else { return }
        switch mode {
        case .automaticAspect:
            preference.viewingWidth = Double(currentContentSize.width)
        case .fixedFrame:
            preference.fixedWidth = Double(currentContentSize.width)
            preference.fixedHeight = Double(currentContentSize.height)
        }
        persist()
    }

    func saveUserFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) {
        guard updateUserFrame(
            contentSize: contentSize,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            screenIdentifier: screenIdentifier
        ) else { return }
        persist()
    }

    /// Update the authority used by subsequent aspect-ratio work immediately,
    /// while leaving disk writes to the window controller's debounce.
    func stageUserFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) {
        guard updateUserFrame(
            contentSize: contentSize,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            screenIdentifier: screenIdentifier
        ) else { return }
        hasPendingUserFrame = true
    }

    func flushPendingUserFrame() {
        guard hasPendingUserFrame else { return }
        persist()
    }

    @discardableResult
    private func updateUserFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) -> Bool {
        guard contentSize.width.isFinite,
              contentSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else { return false }

        switch preference.mode {
        case .automaticAspect:
            preference.viewingWidth = Double(contentSize.width)
        case .fixedFrame:
            preference.fixedWidth = Double(contentSize.width)
            preference.fixedHeight = Double(contentSize.height)
        }

        preference.screenIdentifier = screenIdentifier
        if let center = PlayerWindowPreferencePolicy.normalizedCenter(
            frame: windowFrame,
            visibleFrame: visibleFrame
        ) {
            preference.normalizedCenterX = Double(center.x)
            preference.normalizedCenterY = Double(center.y)
        }
        return true
    }

    func migrateLegacyFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) {
        guard !hasPersistedPreference else {
            clearLegacyFrame()
            return
        }
        preference = .default
        preference.mode = .automaticAspect
        preference.viewingWidth = Double(contentSize.width)
        preference.fixedWidth = Double(contentSize.width)
        preference.fixedHeight = Double(contentSize.height)
        preference.screenIdentifier = screenIdentifier
        if let center = PlayerWindowPreferencePolicy.normalizedCenter(
            frame: windowFrame,
            visibleFrame: visibleFrame
        ) {
            preference.normalizedCenterX = Double(center.x)
            preference.normalizedCenterY = Double(center.y)
        }
        persist()
        clearLegacyFrame()
    }

    func ensurePersisted() {
        guard !hasPersistedPreference else { return }
        persist()
    }

    func reset() {
        preference = .default
        defaults.removeObject(forKey: storageKey)
        hasPersistedPreference = false
        clearLegacyFrame()
        persist()
    }

    func clearLegacyFrame() {
        defaults.removeObject(
            forKey: "NSWindow Frame \(Self.legacyFrameAutosaveName)"
        )
    }

    func legacyFrame() -> NSRect? {
        guard let value = defaults.string(
            forKey: "NSWindow Frame \(Self.legacyFrameAutosaveName)"
        ) else { return nil }
        let components = value
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard components.count >= 4,
              components[0].isFinite,
              components[1].isFinite,
              components[2].isFinite,
              components[3].isFinite,
              components[2] > 0,
              components[3] > 0 else { return nil }
        return NSRect(
            x: components[0],
            y: components[1],
            width: components[2],
            height: components[3]
        )
    }

    private func persist() {
        preference = PlayerWindowPreferencePolicy.sanitized(preference)
        if let data = try? JSONEncoder().encode(preference) {
            defaults.set(data, forKey: storageKey)
            hasPersistedPreference = true
            hasPendingUserFrame = false
        }
    }
}

extension NSScreen {
    var okVideoScreenIdentifier: UInt32? {
        (deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
    }
}
