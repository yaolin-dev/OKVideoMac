import AppKit
import SwiftUI

/// One material for the programme card and utility panels. Blend with this
/// window's video, never the desktop behind it. AppKit composites the blur;
/// there is no video readback, screenshot timer or extra player instance.
struct PlayerGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(white: 0.12)
            } else {
                PlayerGlassMaterial(cornerRadius: cornerRadius)
                Color.black.opacity(0.16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .allowsHitTesting(false)
    }
}

struct PlayerGlassMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}

/// Hover, press and persistent selection are separate states, with no change
/// to the label's geometry. Used by rows, option grids and small panel actions.
struct PlayerPanelButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 7
    var restingOpacity: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, selected: selected,
             cornerRadius: cornerRadius, restingOpacity: restingOpacity)
    }

    private struct StyledLabel: View {
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let cornerRadius: CGFloat
        let restingOpacity: Double

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.30) : Color.white.opacity(restingOpacity))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(enabled ? (configuration.isPressed ? 0.20 : hovering ? 0.11 : 0) : 0))
                }
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(focused && enabled ? 0.65 : 0), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
