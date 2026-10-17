import AppKit
import Combine
import OKVideoCore
import SwiftUI

/// A generation belongs to a render owner, not a URL or a title. Late native
/// callbacks from a retired player must never control its replacement.
struct PictureInPictureSession: Equatable {
    enum Phase { case inline, preparing, entering, active, returning }
    private(set) var phase: Phase = .inline
    private(set) var generation = UUID()
    private(set) var owner: UUID?
    var isPresented: Bool { phase != .inline }
    mutating func begin(owner: UUID) -> UUID? {
        guard phase == .inline else { return nil }
        generation = UUID(); self.owner = owner; phase = .preparing
        return generation
    }
    func owns(_ token: UUID, owner: UUID?) -> Bool {
        isPresented && generation == token && self.owner == owner
    }
    mutating func advance(_ phase: Phase, token: UUID) {
        guard generation == token, isPresented else { return }
        self.phase = phase
    }
    mutating func finish() { generation = UUID(); owner = nil; phase = .inline }
}

@MainActor
final class PlayerPictureInPictureCoordinator: ObservableObject {
    // AppKit may detach the surface while SwiftUI is destroying its view graph.
    // Publishing synchronously there re-enters SwiftUI and violates exclusivity.
    // State/ownership still change immediately; one deferred notification updates
    // both the direct controls and AppState after that lifecycle callback returns.
    let objectWillChange = ObservableObjectPublisher()
    private var changeNotificationPending = false
    private(set) var session = PictureInPictureSession() {
        didSet { if oldValue != session { scheduleChangeNotification() } }
    }
    private(set) var canEnter = false {
        didSet { if oldValue != canEnter { scheduleChangeNotification() } }
    }
    private(set) var errorMessage: String? {
        didSet { if oldValue != errorMessage { scheduleChangeNotification() } }
    }
    private func scheduleChangeNotification() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            self.objectWillChange.send()
        }
    }
    let isAvailable: Bool
    private weak var host: MPVRenderHostView?
    private weak var sourceWindow: NSWindow?
    private var bridge: OKNativePiPBridge?
    private var content: NSViewController?
    private var timeout: DispatchWorkItem?
    private let transitionKey = UUID()
    private var snapshot = PlayerSnapshot()
    private var title = ""
    private let playbackAction: (Bool, UUID) -> Void

    init(playbackAction: @escaping (Bool, UUID) -> Void) {
        isAvailable = OKNativePiPBridge().isAvailable
        self.playbackAction = playbackAction
    }
    var isPresented: Bool { session.isPresented }
    var isTransitioning: Bool { [.preparing, .entering, .returning].contains(session.phase) }
    var buttonTitle: String {
        isPresented ? L10n.string("player.pip.return", fallback: "Return to Player")
            : L10n.string("player.pip.enter", fallback: "Picture in Picture")
    }
    func attach(_ host: MPVRenderHostView) {
        if self.host !== host { end(); self.host = host }
        refreshReadiness()
    }
    func detach(_ host: MPVRenderHostView) {
        guard self.host === host else { return }
        end(); self.host = nil; canEnter = false
    }
    func refreshReadiness() {
        let ready = isAvailable && host?.surface.isReadyForPictureInPicture == true
            && host?.window != nil && snapshot.videoWidth > 0 && snapshot.videoHeight > 0
            && [.playing, .paused, .buffering, .ended].contains(snapshot.status)
        if canEnter != ready { canEnter = ready }
        if session.phase == .entering, let window = host?.surface.window, window !== sourceWindow {
            timeout?.cancel(); timeout = nil
            session.advance(.active, token: session.generation)
        }
    }
    func update(snapshot: PlayerSnapshot, title: String) {
        let oldPlaying = isPlaying, oldAspect = aspect, oldTitle = self.title
        self.snapshot = snapshot; self.title = title
        refreshReadiness()
        if case .failed = snapshot.status, isPresented { showSourceWindow(); end(); return }
        guard isPresented, oldPlaying != isPlaying || oldAspect != aspect || oldTitle != title else { return }
        if bridge?.update(playing: isPlaying, aspect: aspect, title: title) != nil { failAndRestore() }
    }
    func playerWillChange(to owner: UUID?) {
        if isPresented && owner != session.owner { end() }
    }
    private var isPlaying: Bool { snapshot.status == .playing || snapshot.status == .buffering }
    private var aspect: NSSize {
        guard snapshot.videoWidth > 0, snapshot.videoHeight > 0 else { return NSSize(width: 16, height: 9) }
        return NSSize(width: snapshot.videoWidth, height: snapshot.videoHeight)
    }
    func toggle() { isPresented ? returnToPlayer() : enter() }
    private func enter() {
        refreshReadiness()
        guard canEnter, let host, let window = host.window,
              let token = session.begin(owner: host.ownerID) else { return }
        errorMessage = nil; sourceWindow = window
        // A native Space animation must settle before changing the video view's parent.
        let transition = WindowTransitionCoordinator.state(for: window)
        if window.styleMask.contains(.fullScreen) || transition.phase == .enteringFullScreen {
            transition.requestFullScreenToggle()
        }
        armTimeout(token, seconds: 8)
        transition.whenStable(key: transitionKey, windowedOnly: true) { [weak self, weak host] window in
            guard let self, let host, let window,
                  self.host === host, self.session.owns(token, owner: host.ownerID) else { return }
            self.present(host, window: window, token: token)
        }
    }
    private func present(_ host: MPVRenderHostView, window: NSWindow, token: UUID) {
        session.advance(.entering, token: token)
        host.surface.finishFullscreenPresentation()
        let bridge = OKNativePiPBridge()
        self.bridge = bridge
        bridge.onWillClose = { [weak self] in self?.willClose(token: token) }
        bridge.onDidClose = { [weak self] in self?.didClose(token: token) }
        bridge.onPlay = { [weak self] in self?.control(playing: true, token: token) }
        bridge.onPause = { [weak self] in self?.control(playing: false, token: token) }
        bridge.onStop = { [weak self] in self?.control(playing: false, token: token) }
        let content = NSViewController()
        self.content = content
        host.surface.setPictureInPicturePresentation(true)
        content.view = host.surface
        if bridge.present(content, window: window, rect: sourceRect, aspect: aspect, playing: isPlaying, title: title) != nil {
            failAndRestore(); return
        }
        host.surface.synchronizeDrawableAfterWindowLayout()
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, self.session.owns(token, owner: host.ownerID) else { return }
            guard let pipWindow = host.surface.window, pipWindow !== window else { return }
            self.timeout?.cancel(); self.timeout = nil
            self.session.advance(.active, token: token)
        }
    }
    private var sourceRect: NSRect { host?.convert(host?.bounds ?? .zero, to: nil) ?? .zero }
    private func showSourceWindow() {
        guard let sourceWindow else { return }
        if sourceWindow.isMiniaturized { sourceWindow.deminiaturize(nil) }
        sourceWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bridge?.setReturn(sourceWindow, rect: sourceRect)
    }
    func returnToPlayer() {
        guard isPresented else { return }
        guard let content, let sourceWindow else { end(); return }
        let token = session.generation
        session.advance(.returning, token: token)
        showSourceWindow(); armTimeout(token, seconds: 4)
        if bridge?.dismiss(content, window: sourceWindow, rect: sourceRect) != nil { failAndRestore() }
    }
    private func willClose(token: UUID) {
        guard session.owns(token, owner: host?.ownerID) else { return }
        session.advance(.returning, token: token); showSourceWindow(); armTimeout(token, seconds: 4)
    }
    private func didClose(token: UUID) {
        guard session.owns(token, owner: host?.ownerID) else { return }
        end()
    }
    private func control(playing: Bool, token: UUID) {
        guard let owner = host?.ownerID, session.owns(token, owner: owner) else { return }
        playbackAction(playing, owner)
    }
    private func armTimeout(_ token: UUID, seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session.generation == token, self.isPresented else { return }
            self.failAndRestore()
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func failAndRestore() {
        showSourceWindow(); end()
        errorMessage = L10n.string("player.pip.failed", fallback: "Picture in Picture could not be opened. Playback has returned to the player.")
    }
    /// Also used for player replacement, explicit stop, renderer dismantling and quit.
    /// Invalidates ownership before a native callback can touch the next session.
    func end() {
        timeout?.cancel(); timeout = nil
        if let sourceWindow { WindowTransitionCoordinator.state(for: sourceWindow).cancel(transitionKey) }
        if session.isPresented { session.finish() }
        bridge?.invalidate(); bridge = nil
        host?.surface.setPictureInPicturePresentation(false)
        host?.restoreSurface()
        content = nil; sourceWindow = nil
        refreshReadiness()
    }
    func clearError() { errorMessage = nil }
}

struct PlayerPictureInPictureButton: View {
    @ObservedObject var coordinator: PlayerPictureInPictureCoordinator
    var body: some View {
        if coordinator.isAvailable {
            Button { coordinator.toggle() } label: {
                Image(systemName: coordinator.isPresented ? "pip.exit" : "pip.enter")
                    .font(.system(size: 18, weight: .medium)).frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isTransitioning || (!coordinator.isPresented && !coordinator.canEnter))
            .accessibilityIdentifier("player.picture-in-picture")
            .accessibilityLabel(coordinator.buttonTitle)
            .help(coordinator.buttonTitle)
        }
    }
}

struct PlayerPictureInPicturePlaceholder: View {
    @ObservedObject var coordinator: PlayerPictureInPictureCoordinator
    var body: some View {
        if coordinator.isPresented {
            VStack(spacing: 14) {
                Image(systemName: "pip").font(.system(size: 32))
                Text(L10n.string("player.pip.active", fallback: "Playing in Picture in Picture"))
                Button(L10n.string("player.pip.return", fallback: "Return to Player")) { coordinator.returnToPlayer() }
                    .buttonStyle(.bordered).disabled(coordinator.isTransitioning)
            }
            .foregroundColor(.white.opacity(0.85)).padding(24)
            .accessibilityIdentifier("player.picture-in-picture.placeholder")
        } else if let message = coordinator.errorMessage {
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center)
                Button(L10n.string("common.ok", fallback: "OK")) { coordinator.clearError() }
            }.padding(20).frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct PlayerPictureInPictureMenuItem: View {
    @ObservedObject var coordinator: PlayerPictureInPictureCoordinator
    var body: some View {
        if coordinator.isAvailable {
            Button(coordinator.buttonTitle) { coordinator.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(coordinator.isTransitioning || (!coordinator.isPresented && !coordinator.canEnter))
        }
    }
}
