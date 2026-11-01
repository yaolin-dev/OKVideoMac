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
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
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
    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 38) }
}
