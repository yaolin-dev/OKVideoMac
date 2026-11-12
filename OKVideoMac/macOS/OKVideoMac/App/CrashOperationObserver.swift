import AppKit
import Combine
import OKCrashDiagnostics
import OKVideoCore

/// Diagnostics only: observes existing publications and returns every input event unchanged.
/// Never reads text, hit-tests views, changes layout, or publishes business/UI state.
@MainActor
final class CrashOperationObserver {
    private let record: (CrashOperation.Kind, CrashOperation.Window) -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var notifications: [NSObjectProtocol] = []
    private var inputMonitor: Any?

    init(record: @escaping (CrashOperation.Kind, CrashOperation.Window) -> Void,
         observeWindows: Bool = true) {
        self.record = record
        guard observeWindows else { return }
        let events: [(Notification.Name, CrashOperation.Kind)] = [
            (NSWindow.didBecomeKeyNotification, .windowKey),
            (NSWindow.willCloseNotification, .windowClose),
            (NSWindow.willStartLiveResizeNotification, .windowResizeBegin),
            (NSWindow.didEndLiveResizeNotification, .windowResizeEnd),
            (NSWindow.willEnterFullScreenNotification, .windowFullscreenEnter),
            (NSWindow.willExitFullScreenNotification, .windowFullscreenExit),
            (NSWindow.willMiniaturizeNotification, .windowMiniaturize),
            (NSWindow.didDeminiaturizeNotification, .windowRestore)
        ]
        for (name, kind) in events {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.record(kind, Self.role(note.object as? NSWindow))
                }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSSplitView.willResizeSubviewsNotification,
            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.record(.splitViewResize, Self.role((note.object as? NSSplitView)?.window))
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installInputMonitor() }
        })
        if NSApp?.isRunning == true { installInputMonitor() }
    }

    private func installInputMonitor() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.modifierFlags.contains(.command) { self?.record(.keyboardCommand, Self.role(event.window)) }
                } else {
                    self?.record(event.type == .scrollWheel ? .scroll : .pointerDown, Self.role(event.window))
                }
            }
            return event
        }
    }

    func observe(_ state: AppState) {
        subscriptions.removeAll()
        state.navigation.$selection.map(\.section).removeDuplicates().sink { [weak self] section in
            let kind: CrashOperation.Kind
            switch section {
            case .home: kind = .navigationHome
            case .live: kind = .navigationLive
            case .favorites: kind = .navigationFavorites
            case .history: kind = .navigationHistory
            case .settings: kind = .navigationSettings
            }
            self?.record(kind, .browser)
        }.store(in: &subscriptions)
        state.$pendingDetailSummary.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] present in
            if present { self?.record(.detailRequested, .browser) }
        }.store(in: &subscriptions)
        state.$selectedDetail.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] present in
            self?.record(present ? .detailPresented : .detailClosed, .browser)
        }.store(in: &subscriptions)
        state.$isSearching.removeDuplicates().dropFirst().sink { [weak self] active in
            self?.record(active ? .searchStarted : .searchFinished, .browser)
        }.store(in: &subscriptions)
        state.$playbackResolutionState.removeDuplicates().dropFirst().sink { [weak self] phase in
            if phase == .resolving || phase == .restoringHistory { self?.record(.playbackRequested, .player) }
        }.store(in: &subscriptions)
        state.playerSnapshotState.$snapshot.map { Self.playbackKind($0.status) }.removeDuplicates().dropFirst().sink { [weak self] kind in
            self?.record(kind, .player)
        }.store(in: &subscriptions)
        state.playerSnapshotState.$snapshot.map { $0.isSeeking }.removeDuplicates().dropFirst().sink { [weak self] seeking in
            if seeking { self?.record(.playbackSeek, .player) }
        }.store(in: &subscriptions)
        record(.ready, .none)
    }

    static func playbackKind(_ status: PlayerStatus) -> CrashOperation.Kind {
        switch status {
        case .idle, .ended, .stopped: return .playbackStopped
        case .loading, .buffering: return .playbackPreparing
        case .playing: return .playbackPlaying
        case .paused: return .playbackPaused
        case .failed: return .playbackFailed
        }
    }

    static func role(_ window: NSWindow?) -> CrashOperation.Window {
        guard let window else { return .none }
        switch window.identifier?.rawValue {
        case "OKVideoMac.MainWindow": return .browser
        case "OKVideoMac.PlayerWindow": return .player
        default: return .other
        }
    }

    deinit {
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
}
