import AppKit
import SwiftUI

/// AppKit owns the hover bezel, hit testing, accessibility and tooltip.
struct NativeLivePlaybackButton: NSViewRepresentable {
    let paused: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = LivePlaybackNSButton(image: NSImage(), target: context.coordinator, action: #selector(Coordinator.activate))
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .white
        button.setAccessibilityIdentifier("player.live.playPause")
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let title = paused ? L10n.string("common.play", fallback: "Play") : L10n.string("common.pause", fallback: "Pause")
        button.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

/// Keep the actual AppKit hit area as large as the SwiftUI layout slot.
/// Drawing, tracking and keyboard activation remain owned by NSButton.
private final class LivePlaybackNSButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }
}

/// Observe hover without intercepting the mute button's pointer events.
struct PlayerVolumeOverlayAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct PlayerVolumeHoverTracking: NSViewRepresentable {
    var role = "button"
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> PlayerVolumeHoverNSView { PlayerVolumeHoverNSView() }
    func updateNSView(_ view: PlayerVolumeHoverNSView, context: Context) {
        view.role = role; view.onHover = onHover
    }
}

final class PlayerVolumeHoverNSView: NSView {
    var role = "button"
    var onHover: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
