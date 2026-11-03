import SwiftUI

/// The status never supplies a background or intercepts transport input.
/// Its parent owns the VOD track / live control-row anchor.
struct PlayerPlaybackStatusLine: View {
    enum Kind { case waiting, failure, choice }
    let title: String
    var kind: Kind = .waiting

    var body: some View {
        HStack(spacing: 7) {
            if kind == .waiting {
                AppActivityIndicator(size: .mini, tint: .white.opacity(0.9))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: kind == .failure ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 12)).accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundColor(.white.opacity(0.94))
        .shadow(color: .black.opacity(0.65), radius: 1, y: 1)
        .frame(height: 20, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("player.status.line")
        .playerPresentationProbe(title)
        .allowsHitTesting(false)
    }
}

/// Leave control geometry in place so status anchors do not jump on auto-hide.
struct PlayerControlsVisibility: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

struct PlayerStatusActionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Read rendered geometry in isolated test hosts, whose offscreen windows do not
// publish a macOS accessibility tree. No probe is present in delivered builds.
extension View {
    @ViewBuilder func playerPresentationProbe(_ title: String) -> some View {
        #if DEBUG || OKVIDEO_PERFORMANCE_TEST
        background(PlayerPresentationProbe(title: title))
        #else
        self
        #endif
    }
}
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
private struct PlayerPresentationProbe: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> PlayerPresentationProbeView { PlayerPresentationProbeView() }
    func updateNSView(_ view: PlayerPresentationProbeView, context: Context) { view.title = title }
}
final class PlayerPresentationProbeView: NSView {
    var title = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

/// A single anchor is supplied by the active VOD timeline or live status slot.
/// Interactive status content is rendered by their full-viewport ancestor.
struct PlayerStatusOverlayAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
