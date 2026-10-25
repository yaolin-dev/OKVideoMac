import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage<Content: View>: View {
    @EnvironmentObject private var navigation: SettingsNavigationState
    let title: String
    let subtitle: String
    let content: Content
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 2)
                    content
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .task(id: navigation.focus?.id) {
                guard let focus = navigation.focus else { return }
                await Task.yield()
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(focus.sectionID, anchor: .center) }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                navigation.finishFocus(focus.id)
            }
        }
        .font(.system(size: 13))
        .accessibilityLabel(title)
    }
}

private struct SettingsAnchor: ViewModifier {
    @EnvironmentObject private var navigation: SettingsNavigationState
    let id: String
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(navigation.focus?.sectionID == id ? 0.8 : 0), lineWidth: 2)
                .allowsHitTesting(false))
            .id(id)
            .accessibilityIdentifier("settings.section.\(id)")
    }
}

extension View {
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

struct SettingsDisclosure<Content: View>: View {
    @EnvironmentObject private var navigation: SettingsNavigationState
    @State private var expanded = false
    let id: String
    let title: String
    let content: Content
    init(_ id: String, title: String, @ViewBuilder content: () -> Content) {
        self.id = id; self.title = title; self.content = content()
    }
    var body: some View {
        SettingsCard {
            SettingsDisclosureHeader(id: id, title: title, expanded: $expanded)
            if expanded {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsAnchor(id)
        .onAppear { revealSearchResult() }
        .onChange(of: navigation.focus) { _ in revealSearchResult() }
    }
    private func revealSearchResult() {
        if navigation.focus?.sectionID == id { expanded = true }
    }
}

/// The complete row is a native button; the chevron only communicates state.
struct SettingsDisclosureHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let id: String
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(hovering ? 0.035 : 0))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(expanded
            ? SettingsL10n.string("settings.organized.disclosure.expanded", "Expanded")
            : SettingsL10n.string("settings.organized.disclosure.collapsed", "Collapsed"))
        .accessibilityIdentifier("settings.disclosure.\(id)")
    }
}

struct SettingsSheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsL10n {
    static func string(
        _ key: String,
        _ fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        AppLocalizer.shared.string(
            L10nKey(rawValue: key),
            fallback: fallback,
            arguments: arguments
        )
    }
}

enum HistoryRetentionPresets {
    static let standardDays = [30, 60, 90, 180, 365, 3_650]

    static func options(including currentDays: Int) -> [Int] {
        guard !standardDays.contains(currentDays) else { return standardDays }
        return (standardDays + [currentDays]).sorted()
    }

    static func title(for days: Int) -> String {
        switch days {
        case 365:
            return SettingsL10n.string("settings.history.retention.one-year", "1 year")
        case 3_650:
            return SettingsL10n.string("settings.history.retention.ten-years", "10 years")
        default:
            return SettingsL10n.string("settings.history.retention.days", "%d days", days)
        }
    }
}

struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 12).padding(.top, 8)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        }
    }
}

struct SettingsControlRow<Control: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let control: Control

    init(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if !subtitle.isEmpty { Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SettingsInfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if !subtitle.isEmpty { Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .frame(maxWidth: 250, alignment: .trailing)
                .help(value)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SettingsRowIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 12)
    }
}

/// Use AppKit's search field so focus, cancel, keyboard input and appearance
/// follow the host macOS version instead of a painted imitation.
struct SettingsAppearancePicker: View {
    @Binding var selection: AppTheme
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach([AppTheme.light, .dark, .system]) { theme in
                Button { selection = theme } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            ThemeSample(dark: theme == .dark)
                            if theme == .system {
                                HStack(spacing: 0) {
                                    Color.clear
                                    ThemeSample(dark: true)
                                }
                            }
                        }
                        .frame(width: 66, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(selection == theme ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: selection == theme ? 2 : 0.5))
                        Text(theme.title).font(.system(size: 11,
                            weight: selection == theme ? .semibold : .regular))
                            .foregroundStyle(selection == theme ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SettingsL10n.string("settings.appearance.theme.title", "Appearance"))
    }
    private struct ThemeSample: View {
        let dark: Bool
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(0..<3) { _ in Circle().fill(Color.gray.opacity(0.6)).frame(width: 3, height: 3) }
                    Spacer()
                }.padding(4).background(dark ? Color(white: 0.24) : Color(white: 0.9))
                HStack(spacing: 0) {
                    Rectangle().fill(dark ? Color(white: 0.2) : Color(white: 0.86)).frame(width: 17)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.8)).frame(height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.35)).frame(height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.25)).frame(width: 20, height: 3)
                    }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(dark ? Color(white: 0.13) : Color(white: 0.98))
                }
            }
            .accessibilityHidden(true)
        }
    }
}


