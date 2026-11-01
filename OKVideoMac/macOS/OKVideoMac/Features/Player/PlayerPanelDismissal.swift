import AppKit
import SwiftUI

/// Observes clicks without placing a hit-testing layer over the player controls.
struct PlayerPanelDismissalBoundary: NSViewRepresentable {
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> PlayerPanelBoundaryNSView {
        PlayerPanelBoundaryNSView(role: .panel)
    }

    func updateNSView(_ view: PlayerPanelBoundaryNSView, context: Context) {
        view.onDismiss = onDismiss
    }

    static func dismantleNSView(_ view: PlayerPanelBoundaryNSView, coordinator: ()) {
        view.detach()
    }
}

/// Presenters handle their own toggle/switch action on mouse-up. Dismissing them
/// on mouse-down would change that action into opening the same panel again.
struct PlayerPanelPresenterBoundary: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> PlayerPanelBoundaryNSView {
        PlayerPanelBoundaryNSView(role: .presenter(name))
    }

    func updateNSView(_ view: PlayerPanelBoundaryNSView, context: Context) {}
}

final class PlayerPanelBoundaryNSView: NSView {
    enum Role: Equatable {
        case panel
        case presenter(String)
    }

    let role: Role
    var onDismiss: (() -> Void)?
    private var eventMonitor: Any?

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard role == .panel, window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            // Seek, volume, playback and window controls still receive this click.
            return event
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let window, event.window === window,
              !isHiddenOrHasHiddenAncestor,
              !contains(windowPoint: event.locationInWindow),
              let contentView = window.contentView,
              !containsPresenter(in: contentView, windowPoint: event.locationInWindow) else { return }
        onDismiss?()
    }

    private func contains(windowPoint: NSPoint) -> Bool {
        !isHiddenOrHasHiddenAncestor && bounds.contains(convert(windowPoint, from: nil))
    }

    private func containsPresenter(in view: NSView, windowPoint: NSPoint) -> Bool {
        if let boundary = view as? PlayerPanelBoundaryNSView,
           case .presenter = boundary.role,
           boundary.contains(windowPoint: windowPoint) { return true }
        return view.subviews.contains { containsPresenter(in: $0, windowPoint: windowPoint) }
    }

    func detach() {
        stopMonitoring()
        onDismiss = nil
    }

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}
