import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import WebKit

enum AppSurfacePalette {
    static var background: Color {
        // Keep the right-hand content canvas bright while leaving the native
        // split-view titlebar untouched. In particular, this must not tint the
        // independent sidebar titlebar or its system controls.
        Color(nsColor: .textBackgroundColor)
    }
}

enum AppSidebarMetrics {
    // App Store uses a stable source-list column rather than presenting a
    // prominent, freely resizable divider. Keep the primary column fixed;
    // AppKit still owns the geometry within the chosen large source-list
    // treatment used by the current App Store navigation.
    static let width: CGFloat = 220
    static let horizontalInset: CGFloat = 10
    static let topInset: CGFloat = 0
    static let searchToListSpacing: CGFloat = 16
    static let rowHeight: CGFloat = 36
}

enum SidebarSearchEscapeAction: Equatable {
    case clearText
    case exitSearch
}

enum SidebarSearchEscapePolicy {
    static func action(for text: String) -> SidebarSearchEscapeAction {
        text.isEmpty ? .exitSearch : .clearText
    }
}

@MainActor
enum AppSidebarNativePolicy {
    static var iconTint: NSColor { .systemBlue }
    static let rowSizeStyle = NSTableView.RowSizeStyle.large

    static func configure(background: NSVisualEffectView) {
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.isEmphasized = true
    }

    static func configure(searchField: NSSearchField) {
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
    }

    static func configure(outlineView: NSOutlineView) {
        outlineView.style = .sourceList
        // Keep AppKit's large source-list text and symbol metrics. The delegate
        // supplies the App Store-matched 36 pt row rhythm because AppKit pins
        // the `rowHeight` property itself to the selected semantic size.
        outlineView.rowSizeStyle = rowSizeStyle
        outlineView.headerView = nil
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.autosaveExpandedItems = false
    }
}

private struct BrowserWindowVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != .underWindowBackground {
            view.material = .underWindowBackground
        }
        if view.blendingMode != .behindWindow {
            view.blendingMode = .behindWindow
        }
        if view.state != .followsWindowActiveState {
            view.state = .followsWindowActiveState
        }
    }
}

/// Back the native divider at its actual AppKit coordinates. A canvas behind
/// NavigationSplitView does not cover every independently composited edge of
/// the sidebar's behind-window material during window overview scaling.
struct BrowserSplitDividerBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private weak var split: NSSplitView?
        let backing = CALayer()
        private let separator = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            backing.name = "OKVideoMac.opaqueSidebarDivider"
            backing.zPosition = 1 // Stay above AppKit-owned divider/material layers.
            backing.isOpaque = true
            separator.isOpaque = true
            backing.addSublayer(separator)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        deinit {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            backing.removeFromSuperlayer()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func layout() { super.layout(); attach() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

        func attach() {
            guard window != nil else { detach(); return }
            var ancestor = superview
            while let view = ancestor {
                if let candidate = view as? NSSplitView, candidate.isVertical {
                    if split !== candidate {
                        detach()
                        split = candidate
                        candidate.wantsLayer = true
                        candidate.layer?.addSublayer(backing)
                        let center = NotificationCenter.default
                        center.addObserver(self, selector: #selector(refresh),
                            name: NSSplitView.didResizeSubviewsNotification, object: candidate)
                        center.addObserver(self, selector: #selector(refresh),
                            name: NSWindow.didChangeBackingPropertiesNotification, object: window)
                    }
                    refresh()
                    return
                }
                ancestor = view.superview
            }
            detach()
        }
        func detach() {
            NotificationCenter.default.removeObserver(self)
            backing.removeFromSuperlayer()
            split = nil
        }
        @objc func refresh() {
            guard let split else { return }
            let panes = split.arrangedSubviews
            guard panes.count == 2, !panes[0].isHidden, !panes[1].isHidden,
                  !split.isSubviewCollapsed(panes[0]), !split.isSubviewCollapsed(panes[1]) else {
                backing.isHidden = true
                return
            }
            let scale = max(1, window?.backingScaleFactor ?? 1)
            let pixel = 1 / scale
            let left = panes[0].frame.maxX
            let right = panes[1].frame.minX
            guard right >= left, left > split.bounds.minX, right < split.bounds.maxX else {
                backing.isHidden = true
                return
            }
            // One physical pixel of overlap on each side closes fractional
            // sampling edges without adding a layout gap or a hit-test view.
            let start = floor(left * scale) / scale - pixel
            let end = ceil(right * scale) / scale + pixel
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backing.isHidden = false
            backing.contentsScale = scale
            backing.frame = NSRect(x: start, y: split.bounds.minY,
                                   width: end - start, height: split.bounds.height)
            separator.contentsScale = scale
            separator.frame = NSRect(x: floor((left + right) * 0.5 * scale) / scale - start,
                                     y: 0, width: pixel, height: split.bounds.height)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let background = NSColor.textBackgroundColor
                let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let line = background.blended(withFraction: contrast ? 0.35 : 0.12, of: .labelColor) ?? background
                backing.backgroundColor = background.withAlphaComponent(1).cgColor
                separator.backgroundColor = line.withAlphaComponent(1).cgColor
            }
            CATransaction.commit()
        }
    }
}

/// A shared, low-presence hover treatment for the browsing interface. It does
/// not replace selected, destructive, or disabled states; it only adds the
/// small amount of motion and contrast needed to make an interactive surface
/// feel responsive on macOS.
struct AppInteractiveHoverModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let cornerRadius: CGFloat
    let selected: Bool
    let destructive: Bool

    func body(content: Content) -> some View {
        let active = isEnabled && isHovering
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        destructive
                            ? Color.red.opacity(active ? 0.10 : 0)
                            : Color.primary.opacity(active ? (selected ? 0.08 : 0.065) : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color.primary.opacity(active ? 0.075 : 0),
                        lineWidth: 1
                    )
            }
            .scaleEffect(active ? 1.018 : 1)
            .shadow(
                color: Color.black.opacity(active ? 0.10 : 0),
                radius: active ? 7 : 0,
                y: active ? 3 : 0
            )
            .animation(.easeOut(duration: 0.14), value: active)
            .onHover { isHovering = isEnabled && $0 }
    }
}

extension View {
    func appInteractiveHover(
        cornerRadius: CGFloat = 9,
        selected: Bool = false,
        destructive: Bool = false
    ) -> some View {
        modifier(
            AppInteractiveHoverModifier(
                cornerRadius: cornerRadius,
                selected: selected,
                destructive: destructive
            )
        )
    }
}

struct AppHoverTooltipModifier: ViewModifier {
    let text: String
    let delay: TimeInterval

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var hoverGeneration = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if isPresented {
                    tooltip
                        .alignmentGuide(.bottom) { dimensions in
                            dimensions[.top] - 6
                        }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .zIndex(isPresented ? 1_000 : 0)
            .onHover(perform: handleHover)
            .onDisappear {
                hoverGeneration &+= 1
                isHovering = false
                isPresented = false
            }
            .accessibilityHint(text)
    }

    private var tooltip: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Color(nsColor: .labelColor))
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .allowsHitTesting(false)
    }

    private func handleHover(_ inside: Bool) {
        hoverGeneration &+= 1
        let generation = hoverGeneration
        isHovering = inside

        guard inside else {
            isPresented = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isHovering, hoverGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                isPresented = true
            }
        }
    }
}

extension View {
    func appHoverTooltip(
        _ text: String,
        delay: TimeInterval = 0.1
    ) -> some View {
        modifier(AppHoverTooltipModifier(text: text, delay: delay))
    }
}

enum AppConfigurationSheetScope: Equatable {
    case browser
    case player
}

enum AppConfigurationSheetPresentationKind: Equatable {
    case category
    case cloudAuthorization
    case nodeConfiguration
}

enum AppConfigurationSheetPresentationPolicy {
    static func kind(
        hasCategory: Bool,
        hasCloudAuthorization: Bool,
        hasNodeConfiguration: Bool
    ) -> AppConfigurationSheetPresentationKind? {
        // Match the former overlay z-order while presenting only one native
        // sheet. A provider-owned page supersedes an authorization surface,
        // which in turn supersedes its configuration-category launcher.
        if hasNodeConfiguration { return .nodeConfiguration }
        if hasCloudAuthorization { return .cloudAuthorization }
        if hasCategory { return .category }
        return nil
    }
}

struct AppConfigurationSheetModifier: ViewModifier {
    @EnvironmentObject private var state: AppState
    let scope: AppConfigurationSheetScope

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            AppConfigurationSheetHost(scope: scope)
                .environmentObject(state)
                // Every surface provides an explicit cancel action. Prevent
                // AppKit's implicit dismissal from hiding request-owned state
                // without cancelling the corresponding provider operation.
                .interactiveDismissDisabled()
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { presentationKind != nil },
            set: { presented in
                guard !presented else { return }
                dismissActivePresentation()
            }
        )
    }

    private var presentationKind: AppConfigurationSheetPresentationKind? {
        switch scope {
        case .browser:
            return AppConfigurationSheetPresentationPolicy.kind(
                hasCategory: state.configurationCategoryPresentation != nil,
                hasCloudAuthorization:
                    state.mainWindowCloudAuthorizationPrompt != nil
                        || state.detailCloudAuthorizationPrompt != nil,
                hasNodeConfiguration:
                    state.mainWindowNodeWebPresentation != nil
                        || state.detailNodeWebPresentation != nil
            )
        case .player:
            return AppConfigurationSheetPresentationPolicy.kind(
                hasCategory: false,
                hasCloudAuthorization:
                    state.playerCloudAuthorizationPrompt != nil,
                hasNodeConfiguration:
                    state.playerNodeWebPresentation != nil
            )
        }
    }

    private func dismissActivePresentation() {
        switch presentationKind {
        case .nodeConfiguration:
            state.cancelNodeConfiguration()
        case .cloudAuthorization:
            Task { await state.cancelCloudAuthorization() }
        case .category:
            state.closeConfigurationCategory()
        case nil:
            break
        }
    }
}

extension View {
    func appConfigurationSheet(
        scope: AppConfigurationSheetScope
    ) -> some View {
        modifier(AppConfigurationSheetModifier(scope: scope))
    }
}

struct AppConfigurationSheetHost: View {
    @EnvironmentObject private var state: AppState
    let scope: AppConfigurationSheetScope

    @ViewBuilder
    var body: some View {
        switch scope {
        case .browser:
            if let presentation = state.mainWindowNodeWebPresentation
                ?? state.detailNodeWebPresentation {
                NodeConfigurationView(presentation: presentation)
            } else if let prompt = state.mainWindowCloudAuthorizationPrompt
                ?? state.detailCloudAuthorizationPrompt {
                CloudAuthorizationView(prompt: prompt)
            } else if let presentation =
                state.configurationCategoryPresentation {
                ConfigurationCategoryView(presentation: presentation)
            }
        case .player:
            if let presentation = state.playerNodeWebPresentation {
                NodeConfigurationView(presentation: presentation)
                    .environment(\.colorScheme, .dark)
            } else if let prompt = state.playerCloudAuthorizationPrompt {
                CloudAuthorizationView(prompt: prompt)
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var liveSession = LiveBrowserSession()

    var body: some View {
        ZStack {
            // Base canvas; the native divider has its own opaque edge backing.
            AppSurfacePalette.background
                .ignoresSafeArea()

            browsingContent
        }
        .alert(item: $state.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text(L10n.string(.commonOK)))
            )
        }
        .sheet(isPresented: $state.isAndroidRuntimeInstallSheetPresented) {
            AndroidRuntimeInstallView()
                .environmentObject(state)
        }
        .appConfigurationSheet(scope: .browser)
        .overlay(alignment: .bottom) {
            if let status = state.siteActionStatus {
                TransientSiteActionStatusView(status: status)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if state.isQuickSwitcherPresented {
                QuickSwitcherView()
                    .environmentObject(state)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(200)
            }
        }
        .overlay {
            if state.isShortcutHelpPresented {
                ShortcutHelpView()
                    .environmentObject(state)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(210)
            }
        }
        .animation(
            .easeOut(duration: 0.14),
            value: state.isQuickSwitcherPresented
        )
        .animation(
            .easeOut(duration: 0.14),
            value: state.isShortcutHelpPresented
        )
        .animation(
            .easeOut(duration: 0.18),
            value: state.siteActionStatus?.id
        )
        .background {
            ZStack {
                WindowCloseObserver(
                    onClose: {},
                    onKeyChange: { isKey in
                        state.setBrowserWindowKey(isKey)
                    }
                )
                AppKeyCommandMonitor { event in
                    let modifiers = event.modifierFlags.intersection(
                        [.command, .option, .control, .shift]
                    )
                    guard modifiers.isEmpty, event.keyCode == 53 else {
                        return false
                    }
                    // Do not let a held Escape key close the detail and then
                    // route a repeated key-down to the search page beneath it.
                    guard !event.isARepeat else { return true }
                    return state.performBrowserEscapeShortcut()
                }
                .frame(width: 0, height: 0)
            }
        }
    }

    @ViewBuilder
    private var browsingContent: some View {
        if #available(macOS 13.0, *) {
            ModernRootSplitView(liveSession: liveSession)
        } else {
            NavigationView {
                SidebarView(liveSession: liveSession)
                SectionContentView(
                    liveSession: liveSession,
                    showsCollapsedSearch: false
                )
            }
            .navigationViewStyle(.columns)
        }
    }
}

@available(macOS 13.0, *)
private struct ModernRootSplitView: View {
    @ObservedObject var liveSession: LiveBrowserSession
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(liveSession: liveSession)
        } detail: {
            SectionContentView(
                liveSession: liveSession,
                showsCollapsedSearch: columnVisibility == .detailOnly
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct QuickSwitcherView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { state.dismissQuickSwitcher() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                    TextField(L10n.string("switcher.search.placeholder", fallback: "Switch configurations, providers, or Live TV sources"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($searchIsFocused)
                        .onSubmit { activateFirstMatch() }
                    Button {
                        state.dismissQuickSwitcher()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help(L10n.string("common.close", fallback: "Close"))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !matchingConfigurations.isEmpty {
                            switcherHeader(L10n.string("switcher.configurations", fallback: "Video Provider Configurations"))
                            ForEach(matchingConfigurations) { configuration in
                                switcherRow(
                                    title: configuration.name,
                                    subtitle: configuration.isActive
                                        ? L10n.string("switcher.current-configuration", fallback: "Current Configuration") : nil,
                                    systemImage: "square.stack.3d.up"
                                ) {
                                    state.dismissQuickSwitcher()
                                    Task {
                                        await state.activateConfiguration(
                                            configuration.id
                                        )
                                    }
                                }
                            }
                        }

                        if !matchingSites.isEmpty {
                            switcherHeader(L10n.string("switcher.providers", fallback: "Video Providers"))
                            ForEach(matchingSites, id: \.key) { site in
                                switcherRow(
                                    title: site.name,
                                    subtitle: site.key == state.selectedSiteKey
                                        ? L10n.string("switcher.current-provider", fallback: "Current Provider") : nil,
                                    systemImage: "play.rectangle"
                                ) {
                                    state.dismissQuickSwitcher()
                                    state.selectSection(.home)
                                    Task { await state.selectSite(site.key) }
                                }
                            }
                        }

                        if !matchingLiveSources.isEmpty {
                            switcherHeader(L10n.string("switcher.live-sources", fallback: "Live TV Sources"))
                            ForEach(matchingLiveSources) { source in
                                switcherRow(
                                    title: source.name,
                                    subtitle: L10n.string("switcher.open-live", fallback: "Open Live TV"),
                                    systemImage: "dot.radiowaves.left.and.right"
                                ) {
                                    state.dismissQuickSwitcher()
                                    state.requestLiveSourceSelection(source.id)
                                }
                            }
                        }

                        if matchingConfigurations.isEmpty,
                           matchingSites.isEmpty,
                           matchingLiveSources.isEmpty {
                            EmptyStateView(
                                systemImage: "magnifyingglass",
                                title: L10n.string("switcher.empty.title", fallback: "No Matches"),
                                message: L10n.string("switcher.empty.message", fallback: "Try another name.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 480)

                Divider()
                HStack {
                    Text(L10n.string("switcher.footer", fallback: "Type to filter  ·  Return opens the first item  ·  Esc closes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘K")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
            }
            .frame(width: 560)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .onAppear { searchIsFocused = true }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingConfigurations: [StoredConfiguration] {
        state.configurations.filter { matches($0.name) }
    }

    private var matchingSites: [SiteConfiguration] {
        state.supportedSites.filter { matches($0.name) || matches($0.key) }
    }

    private var matchingLiveSources: [LiveSourceDescriptor] {
        state.liveSourceDescriptors.filter { matches($0.name) }
    }

    private func matches(_ value: String) -> Bool {
        normalizedQuery.isEmpty
            || value.localizedCaseInsensitiveContains(normalizedQuery)
    }

    private func activateFirstMatch() {
        if let configuration = matchingConfigurations.first {
            state.dismissQuickSwitcher()
            Task { await state.activateConfiguration(configuration.id) }
        } else if let site = matchingSites.first {
            state.dismissQuickSwitcher()
            state.selectSection(.home)
            Task { await state.selectSite(site.key) }
        } else if let source = matchingLiveSources.first {
            state.dismissQuickSwitcher()
            state.requestLiveSourceSelection(source.id)
        }
    }

    private func switcherHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func switcherRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 8)
    }
}

private struct ShortcutHelpView: View {
    @EnvironmentObject private var state: AppState

    private let sections: [(String, [(String, String)])] = [
        (L10n.string("shortcuts.navigation", fallback: "Navigation"), [
            ("⌘1…⌘5", L10n.string("shortcuts.navigation.sections", fallback: "Browse, Live TV, Favorites, History, Settings")),
            ("⌘F", L10n.string("shortcuts.search", fallback: "Search")),
            ("⌘K", L10n.string("shortcuts.quick-switcher", fallback: "Quickly switch configurations, providers, or Live TV sources")),
            ("⌘L", L10n.string("shortcuts.open-configurations", fallback: "Open Video Providers")),
            ("⌘R", L10n.string("shortcuts.refresh", fallback: "Refresh the current page")),
            ("⌘[", L10n.string("shortcuts.back", fallback: "Back")),
            ("⌘.", L10n.string("shortcuts.stop-search", fallback: "Stop the current search")),
            ("Esc", L10n.string("shortcuts.escape-search", fallback: "Stop search; press again to return to the previous page"))
        ]),
        (L10n.string("shortcuts.player", fallback: "Player"), [
            ("Space", L10n.string("shortcuts.player.play-pause", fallback: "Play or pause")),
            ("← / →", L10n.string("shortcuts.player.seek-10", fallback: "Back or forward 10 seconds")),
            ("⇧← / ⇧→", L10n.string("shortcuts.player.seek-30", fallback: "Back or forward 30 seconds")),
            ("⌥← / ⌥→", L10n.string("shortcuts.player.episode", fallback: "Previous or next episode")),
            ("↑ / ↓", L10n.string("shortcuts.player.channel", fallback: "Previous or next Live TV channel")),
            ("M", L10n.string("shortcuts.player.mute", fallback: "Mute")),
            ("− / =", L10n.string("shortcuts.player.volume", fallback: "Decrease or increase volume")),
            ("C / A", L10n.string("shortcuts.player.tracks", fallback: "Toggle subtitles / next audio track")),
            ("F", L10n.string("shortcuts.player.full-screen", fallback: "Enter or exit full screen")),
            ("Esc", L10n.string("shortcuts.player.escape", fallback: "Close the player panel or exit full screen")),
            ("⇧, / ⇧.", L10n.string("shortcuts.player.speed", fallback: "Decrease or increase playback speed")),
            ("⌘W", L10n.string("shortcuts.player.close-window", fallback: "Close the player window"))
        ]),
        (L10n.string("shortcuts.system", fallback: "System"), [
            ("⌘,", L10n.string("shortcuts.system.settings", fallback: "Open Settings")),
            ("⌘/", L10n.string("shortcuts.system.show", fallback: "Show this keyboard shortcut list"))
        ])
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { state.dismissShortcutHelp() }

            VStack(spacing: 0) {
                HStack {
                    Label(L10n.string("shortcuts.title", fallback: "Keyboard Shortcuts"), systemImage: "keyboard")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        state.dismissShortcutHelp()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(18)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(sections.enumerated()), id: \.offset) {
                            _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.0)
                                    .font(.headline)
                                ForEach(
                                    Array(section.1.enumerated()),
                                    id: \.offset
                                ) { _, shortcut in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(shortcut.0)
                                            .font(.body.monospaced())
                                            .frame(width: 110, alignment: .trailing)
                                        Text(shortcut.1)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(maxHeight: 610)
            }
            .frame(width: 620)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
    }
}

private struct ConfigurationCategoryView: View {
    @EnvironmentObject private var state: AppState
    let presentation: ConfigurationCategoryPresentation

    var body: some View {
        card
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minHeight: 300)
            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(L10n.string("configuration.center", fallback: "Configuration Center"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Label(L10n.string("common.refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(refreshIsDisabled)
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        if presentation.isLoading {
            loadingContent
        } else if let message = presentation.errorMessage {
            errorContent(message)
        } else {
            actionList
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("configuration.actions.loading", fallback: "Loading configuration actions…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button(L10n.string("common.retry", fallback: "Try Again")) {
                refresh()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(presentation.items.enumerated()), id: \.element.id) { index, item in
                    ConfigurationCategoryRow(
                        item: item
                    ) {
                        Task { await state.performHomeAction(item) }
                    }
                    if index < presentation.items.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .padding(18)
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.string("configuration.actions.close-note", fallback: "Closing returns to the previous content page and browsing position."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.string("common.close", fallback: "Close")) {
                state.closeConfigurationCategory()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var refreshIsDisabled: Bool {
        presentation.isLoading || state.isConfigurationInteractionActive
    }

    private func refresh() {
        Task { await state.refreshConfigurationCategory() }
    }
}

/// Pending provider work is visible and cancellable without inventing a sheet.
struct TVBoxActionProgressControls: View {
    @EnvironmentObject private var state: AppState
    let item: SiteActionItem

    var body: some View {
        if state.isTVBoxConfigurationActionPending(item),
           let pending = state.pendingTVBoxConfigurationAction {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.string("configuration.action.executing", fallback: "Performing configuration action…"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(L10n.string(.commonCancel)) {
                    state.cancelPendingTVBoxConfigurationAction(pending.id)
                }
                .accessibilityIdentifier("tvbox.cancel.\(item.id)")
            }
            .font(.caption)
            .padding(.bottom, 8)
        }
    }
}

private struct ConfigurationCategoryRow: View {
    let item: SiteActionItem
    @EnvironmentObject private var state: AppState
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .foregroundStyle(.primary)
                        if let remarks = item.remarks?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !remarks.isEmpty {
                            Text(remarks)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 18)
                .frame(minHeight: 58)
            }
            .buttonStyle(.plain)
            .disabled(state.isTVBoxConfigurationActionPending(item))
            TVBoxActionProgressControls(item: item)
                .padding(.horizontal, 18)
        }
    }
}

enum PlayerSurfaceMountPolicy {
    static func shouldMount(
        isPlayerPresented: Bool,
        isMountEnabled: Bool,
        hasRenderPlayer: Bool
    ) -> Bool {
        isPlayerPresented && isMountEnabled && hasRenderPlayer
    }
}

enum PlayerSurfaceBackdropPolicy {
    static func shouldShow(isPlayerPresented: Bool) -> Bool {
        isPlayerPresented
    }
}

struct NodeConfigurationView: View {
  @EnvironmentObject private var state: AppState
  let presentation: NodeWebPresentation
  @State private var pageState: NodeConfigurationPageState = .loading

  private var isVerifying: Bool {
    presentation.lifecycleState == .verifying
  }

  private var isPlayerAuthorization: Bool {
    if case .player = presentation.presentationTarget { return true }
    return false
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "externaldrive.badge.person.crop")
          .font(.system(size: 23, weight: .semibold))
          .foregroundColor(.accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(presentation.title)
            .font(.headline)
          Text(
            presentation.message
          )
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(2)
        }
        Spacer(minLength: 12)
        Button {
          pageState = .loading
          state.refreshNodeConfigurationWebsite()
        } label: {
          Label(L10n.string("common.refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(isVerifying)
      }
      .padding(.horizontal, 18)
      .frame(height: 68)

      Divider()

      ZStack {
        NodeConfigurationWebView(
          url: presentation.url,
          revision: presentation.revision,
          preferredProviderID: presentation.preferredProviderID,
          pageState: $pageState
        )
        .background(Color(nsColor: .textBackgroundColor))

        switch pageState {
        case .loading:
          VStack(spacing: 12) {
            AppActivityIndicator(size: .regular)
            Text(L10n.string("node.configuration.opening", fallback: "Opening configuration page…"))
              .font(.callout.weight(.semibold))
            Text(L10n.string("node.configuration.connecting", fallback: "Connecting to the current CatPaw Runtime"))
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(24)
          .background(.regularMaterial)
          .clipShape(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
        case .failed(let message):
          VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 28, weight: .semibold))
              .foregroundColor(.orange)
            Text(L10n.string("node.configuration.unavailable", fallback: "Configuration Page Unavailable"))
              .font(.headline)
            Text(message)
              .font(.caption)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 420)
            Button(L10n.string("common.reload", fallback: "Reload")) {
              pageState = .loading
              state.refreshNodeConfigurationWebsite()
            }
          }
          .padding(28)
          .background(.regularMaterial)
          .clipShape(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
        case .ready:
          EmptyView()
        }
      }

      Divider()

      HStack(spacing: 12) {
        if isVerifying {
          AppActivityIndicator(size: .small)
        } else {
          Image(systemName: footerSystemImage)
            .foregroundColor(footerColor)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(footerTitle)
            .font(.caption.weight(.semibold))
          if let status = presentation.status,
            !status.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
          {
            Text(status)
              .font(.caption2)
              .foregroundColor(.secondary)
              .lineLimit(2)
          }
        }
        Spacer()
        Button(L10n.string("common.close", fallback: "Close")) {
          state.cancelNodeConfiguration()
        }
        .keyboardShortcut(.cancelAction)
        Button {
          Task { await state.completeNodeConfigurationAndRetry() }
        } label: {
          Label(
            isPlayerAuthorization
              ? L10n.string("node.authorization.verify", fallback: "I Authorized — Verify Now")
              : L10n.string("node.configuration.apply-retry", fallback: "Apply Configuration and Try Again"),
            systemImage: "arrow.right.circle.fill"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(isVerifying)
      }
      .padding(.horizontal, 18)
      .frame(height: 64)
    }
    .frame(
      minWidth: 820,
      idealWidth: 1_040,
      maxWidth: 1_160,
      minHeight: 580,
      idealHeight: 760,
      maxHeight: 840
    )
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var footerTitle: String {
    switch presentation.lifecycleState {
    case .waiting:
      return presentation.allowsAutomaticRetry
        ? L10n.string("node.authorization.waiting", fallback: "Waiting for authorization confirmation")
        : L10n.string("node.authorization.verify-manually", fallback: "Confirm authorization, then verify manually")
    case .saved:
      return isPlayerAuthorization
        ? L10n.string("node.configuration.saved-awaiting-authorization", fallback: "Configuration saved; waiting to verify authorization")
        : L10n.string("node.configuration.saved", fallback: "Configuration Saved")
    case .verifying:
      return L10n.string("node.authorization.verifying", fallback: "Verifying authorization and resuming the original request")
    case .needsManualRetry:
      return L10n.string("node.authorization.manual-confirmation", fallback: "Manual Confirmation Required")
    }
  }

  private var footerSystemImage: String {
    switch presentation.lifecycleState {
    case .waiting: return "qrcode.viewfinder"
    case .saved: return "checkmark.circle.fill"
    case .verifying: return "arrow.triangle.2.circlepath"
    case .needsManualRetry: return "exclamationmark.triangle.fill"
    }
  }

  private var footerColor: Color {
    switch presentation.lifecycleState {
    case .saved: return .green
    case .needsManualRetry: return .orange
    case .waiting, .verifying: return .accentColor
    }
  }
}

enum NodeConfigurationPageState: Equatable {
    case loading
    case ready
    case failed(String)
}

enum NodeConfigurationNavigationPolicy {
    static func isOwnedRuntimeURL(_ candidate: URL, origin: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "http",
              origin.scheme?.lowercased() == "http",
              let candidateHost = candidate.host?.lowercased(),
              let originHost = origin.host?.lowercased(),
              candidateHost == originHost else {
            return false
        }
        return effectivePort(candidate) == effectivePort(origin)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}

private struct NodeConfigurationWebView: NSViewRepresentable {
    let url: URL
    let revision: Int
    let preferredProviderID: String?
    @Binding var pageState: NodeConfigurationPageState

    func makeCoordinator() -> Coordinator {
        Coordinator(
            origin: url,
            preferredProviderID: preferredProviderID,
            pageState: $pageState
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.lastRevision = revision
        context.coordinator.origin = url
        context.coordinator.preferredProviderID = preferredProviderID
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.origin = url
        context.coordinator.pageState = $pageState
        if context.coordinator.preferredProviderID != preferredProviderID {
            context.coordinator.preferredProviderID = preferredProviderID
            context.coordinator.selectPreferredProvider(in: webView)
        }
        guard context.coordinator.lastRevision != revision else { return }
        context.coordinator.lastRevision = revision
        DispatchQueue.main.async {
            context.coordinator.pageState.wrappedValue = .loading
        }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastRevision = -1
        var origin: URL
        var preferredProviderID: String?
        var pageState: Binding<NodeConfigurationPageState>

        init(
            origin: URL,
            preferredProviderID: String?,
            pageState: Binding<NodeConfigurationPageState>
        ) {
            self.origin = origin
            self.preferredProviderID = preferredProviderID
            self.pageState = pageState
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation?
        ) {
            pageState.wrappedValue = .loading
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation?
        ) {
            pageState.wrappedValue = .ready
            selectPreferredProvider(in: webView)
        }

        func selectPreferredProvider(in webView: WKWebView) {
            guard let preferredProviderID,
                  CatPawCloudProvider(rawValue: preferredProviderID) != nil else {
                return
            }
            let tabID = "account-tab-\(preferredProviderID)"
            let script = """
            (() => {
              const tabID = \(Self.javaScriptString(tabID));
              const select = () => {
                const tab = document.getElementById(tabID);
                if (!tab) return false;
                tab.click();
                return true;
              };
              if (select()) return true;
              const observer = new MutationObserver(() => {
                if (select()) observer.disconnect();
              });
              observer.observe(document.documentElement, {
                childList: true,
                subtree: true
              });
              setTimeout(() => observer.disconnect(), 5000);
              return false;
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private static func javaScriptString(_ value: String) -> String {
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\""
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            guard !Self.isCancellation(error) else { return }
            pageState.wrappedValue = .failed(Self.message(for: error))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            guard !Self.isCancellation(error) else { return }
            pageState.wrappedValue = .failed(Self.message(for: error))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                url,
                origin: origin
            ) {
                decisionHandler(.allow)
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }
            if NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                url,
                origin: origin
            ) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private static func message(for error: Error) -> String {
            let urlError = error as? URLError
            if [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost]
                .contains(urlError?.code) {
                return L10n.string("node.configuration.runtime-restarted", fallback: "Node restarted or the configuration page address expired. Close this page and open the configuration action again.")
            }
            return L10n.string(
                "node.configuration.load-failed",
                fallback: "Configuration page failed to load: %@",
                RuntimeUserFacingMessageMapper.message(for: error)
            )
        }

        private static func isCancellation(_ error: Error) -> Bool {
            (error as? URLError)?.code == .cancelled
        }
    }
}

private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowCloseObserverView {
        let view = WindowCloseObserverView()
        view.onClose = onClose
        view.onKeyChange = onKeyChange
        return view
    }

    func updateNSView(
        _ nsView: WindowCloseObserverView,
        context: Context
    ) {
        nsView.onClose = onClose
        nsView.onKeyChange = onKeyChange
    }
}

private final class WindowCloseObserverView: NSView {
    var onClose: (() -> Void)?
    var onKeyChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let configurationKey = UUID()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        // Resizing while SwiftUI is mounting this representable can re-enter
        // AppKit layout. Configure on the next run-loop turn, after the
        // browser hierarchy has completed its current layout transaction.
        WindowTransitionCoordinator.state(for: window).whenStable(
            key: configurationKey, windowedOnly: true
        ) { [weak self] stableWindow in
            guard let self, let stableWindow, self.window === stableWindow else { return }
            AppWindowLayoutPolicy.configure(stableWindow, target: .mainWindow)
            BrowserWindowChromeController.configure(stableWindow)
        }
        onKeyChange?(window.isKeyWindow)
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onKeyChange?(false)
                self?.onClose?()
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onKeyChange?(true)
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onKeyChange?(false)
            }
        ]
    }

    deinit {
        removeObservers()
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

struct AppKeyCommandMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> AppKeyCommandMonitorView {
        let view = AppKeyCommandMonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(
        _ nsView: AppKeyCommandMonitorView,
        context: Context
    ) {
        nsView.handler = handler
    }
}

final class AppKeyCommandMonitorView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.window === window,
                  !Self.isEditingText(in: window),
                  self.handler?(event) == true else {
                return event
            }
            return nil
        }
    }

    deinit {
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func isEditingText(in window: NSWindow) -> Bool {
        if window.firstResponder is NSTextField { return true }
        guard let textView = window.firstResponder as? NSTextView else {
            return false
        }
        return textView.isEditable || textView.isFieldEditor
    }
}

private struct TransientSiteActionStatusView: View {
    let status: TransientSiteActionStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.message)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }
}

struct CloudAuthorizationView: View {
    @EnvironmentObject private var state: AppState
    @State private var isTextEntryExpanded = false
    let prompt: CloudAuthorizationPrompt

    var body: some View {
        GeometryReader { geometry in
            authorizationCard(
                maximumSurfaceHeight:
                    CloudAuthorizationPresentationPolicy
                        .maximumSurfaceHeight(
                            containerHeight: geometry.size.height
                        ),
                availableSurfaceWidth:
                    CloudAuthorizationPresentationPolicy
                        .availableSurfaceWidth(
                            containerWidth: geometry.size.width
                        )
            )
            .padding(CloudAuthorizationPresentationPolicy.outerInset)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
        }
        .frame(
            minWidth: 520,
            idealWidth: 820,
            maxWidth: 900,
            minHeight: 420,
            idealHeight: 720,
            maxHeight: 840
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func authorizationCard(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: usesDialogCropLayout ? 12 : 16) {
            HStack {
                Label(
                    isAuthorization
                        ? L10n.string("cloud.authorization.title", fallback: "Cloud Authorization")
                        : L10n.string("cloud.configuration-action.title", fallback: "Configuration Action"),
                    systemImage: isAuthorization
                        ? "externaldrive.badge.person.crop"
                        : "slider.horizontal.3"
                )
                    .font(.title2.bold())
                Spacer()
                Button {
                    Task { await state.refreshCloudAuthorization() }
                } label: {
                    Label(L10n.string("common.refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isBusy || isTerminal)
            }

            Text(prompt.title)
                .font(.headline)

            if prompt.lifecyclePhase == .completed {
                Label(
                    isAuthorization
                        ? L10n.string("cloud.authorization.completed", fallback: "Authorization Complete")
                        : L10n.string("cloud.configuration-action.completed", fallback: "Configuration Action Complete"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.headline)
                .foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            } else if prompt.lifecyclePhase == .failed {
                Label(
                    isAuthorization
                        ? L10n.string("cloud.authorization.incomplete", fallback: "Authorization Incomplete")
                        : L10n.string("cloud.configuration-action.incomplete", fallback: "Configuration Action Incomplete"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            } else if let surfaceFrame {
                VStack(spacing: 9) {
                    AndroidActionSurfaceView(
                        frame: surfaceFrame,
                        disabled: isTerminal,
                        maximumHeight: maximumSurfaceHeight,
                        availableWidth: availableSurfaceWidth,
                        onTap: { x, y in
                            Task {
                                await state.tapCloudAuthorizationSurface(
                                    x: x,
                                    y: y,
                                    frame: surfaceFrame
                                )
                            }
                        },
                        onSwipe: { fromX, fromY, toX, toY in
                            Task {
                                await state.swipeCloudAuthorizationSurface(
                                    fromX: fromX,
                                    fromY: fromY,
                                    toX: toX,
                                    toY: toY,
                                    frame: surfaceFrame
                                )
                            }
                        }
                    )
                    .overlay(alignment: .topTrailing) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: Circle())
                                .padding(8)
                                .accessibilityLabel(lifecycleStatus)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(L10n.string("cloud.android-surface.note", fallback: "This is the provider's native Android interface. Click or drag to interact."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            isTextEntryExpanded.toggle()
                        } label: {
                            Label(
                                isTextEntryExpanded
                                    ? L10n.string("cloud.text-entry.collapse", fallback: "Hide Text Entry")
                                    : L10n.string("cloud.text-entry.show", fallback: "Enter Text"),
                                systemImage: "keyboard"
                            )
                        }
                        .disabled(isTerminal)
                        Button {
                            Task {
                                await state.backCloudAuthorizationSurface(
                                    frame: surfaceFrame
                                )
                            }
                        } label: {
                            Label(L10n.string("common.back-one-level", fallback: "Back One Level"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isTerminal)
                    }
                }
                if isTextEntryExpanded {
                    HStack(spacing: 8) {
                        TextField(
                            L10n.string("cloud.text-entry.placeholder", fallback: "Click an Android text field, then send text from here"),
                            text: $state.cloudAuthorizationInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(isTerminal)
                        Button(L10n.string("cloud.text-entry.send", fallback: "Send Text")) {
                            Task {
                                await state.typeCloudAuthorizationSurfaceText(
                                    frame: surfaceFrame
                                )
                            }
                        }
                        .disabled(
                            isTerminal
                                || state.cloudAuthorizationInput.isEmpty
                        )
                    }
                }
            } else if isBusy {
                HStack(spacing: 10) {
                    AppActivityIndicator(size: .small)
                    Text(lifecycleStatus)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            }

            if let status = prompt.status,
               !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            HStack {
                if prompt.allowsRetry {
                    Button {
                        Task { await state.retryCloudAuthorizationOperation() }
                    } label: {
                        Label(L10n.string("common.retry", fallback: "Try Again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || prompt.lifecyclePhase == .completed)
                }
                if !prompt.webLinks.isEmpty, !isTerminal {
                    Menu {
                        ForEach(Array(prompt.webLinks.enumerated()), id: \.offset) { index, link in
                            Button(URL(string: link)?.host ?? "Web") {
                                Task { await state.openCloudConfigurationWebLink(index, interactionID: prompt.interactionID) }
                            }
                        }
                    } label: {
                        Label(L10n.string("cloud.configuration.open-web", fallback: "Open Configuration Web Page"), systemImage: "globe")
                    }
                }
                if prompt.allowsCompletionConfirmation,
                   !isTerminal {
                    Button {
                        Task {
                            await state.confirmCloudAuthorizationCompletion()
                        }
                    } label: {
                        Label(isPlayerAuthorization
                            ? L10n.string("cloud.complete-resume", fallback: "Check Login and Resume")
                            : L10n.string("cloud.complete-refresh", fallback: "Finish and Refresh"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.lifecyclePhase == .submitting)
                }
                Spacer()
                Button(
                    isPlayerAuthorization
                        ? L10n.string("player.cancel-playback", fallback: "Cancel Playback")
                        : L10n.string("common.close", fallback: "Close")
                ) {
                    Task { await state.cancelCloudAuthorization() }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(usesDialogCropLayout ? 18 : 22)
        .frame(
            minWidth: minimumCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            ),
            idealWidth: idealCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            ),
            maxWidth: maximumCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            )
        )
        .onChange(of: prompt.interactionID) { _ in
            isTextEntryExpanded = false
        }
    }

    private var isAuthorization: Bool {
        prompt.semantic.isAuthorization || isPlayerAuthorization
    }

    private var isPlayerAuthorization: Bool {
        if case .player = prompt.presentationTarget { return true }
        return false
    }

    private var isBusy: Bool {
        prompt.lifecyclePhase.isBusy
    }

    private var isTerminal: Bool {
        prompt.lifecyclePhase.isTerminal
    }

    private var surfaceFrame: AndroidActionSurfaceFrame? {
        guard let frame = state.cloudAuthorizationSurfaceFrame,
              frame.interactionID == prompt.interactionID else {
            return nil
        }
        return frame
    }

    private var usesCompactSurfaceLayout: Bool {
        guard let surfaceFrame else { return false }
        return surfaceFrame.pixelHeight > surfaceFrame.pixelWidth
    }

    private var usesDialogCropLayout: Bool {
        surfaceFrame?.presentationMode == .dialogCrop
    }

    private func minimumCardWidth(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> CGFloat {
        if usesDialogCropLayout {
            return dialogCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            )
        }
        return usesCompactSurfaceLayout ? 440 : 560
    }

    private func idealCardWidth(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> CGFloat {
        if usesDialogCropLayout {
            return dialogCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            )
        }
        return usesCompactSurfaceLayout ? 500 : 700
    }

    private func maximumCardWidth(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> CGFloat {
        if usesDialogCropLayout {
            return dialogCardWidth(
                maximumSurfaceHeight: maximumSurfaceHeight,
                availableSurfaceWidth: availableSurfaceWidth
            )
        }
        return usesCompactSurfaceLayout ? 580 : 780
    }

    private func dialogCardWidth(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> CGFloat {
        guard let surfaceFrame else {
            return min(440, availableSurfaceWidth)
        }
        let surfaceSize = AndroidActionSurfacePresentationPolicy.preferredSize(
            pixelWidth: surfaceFrame.pixelWidth,
            pixelHeight: surfaceFrame.pixelHeight,
            maximumHeight: maximumSurfaceHeight,
            availableWidth: availableSurfaceWidth,
            presentationMode: surfaceFrame.presentationMode
        )
        return CloudAuthorizationPresentationPolicy.dialogCardWidth(
            surfaceWidth: surfaceSize.width,
            availableSurfaceWidth: availableSurfaceWidth
        )
    }

    private var lifecycleStatus: String {
        switch prompt.lifecyclePhase {
        case .invoking:
            return L10n.string("cloud.lifecycle.submitting-command", fallback: "Submitting configuration command")
        case .awaitingInterface:
            return L10n.string("cloud.lifecycle.waiting-interface", fallback: "Waiting for the next action screen")
        case .submitting:
            return L10n.string("cloud.lifecycle.submitting-action", fallback: "Submitting the current action")
        case .processing:
            return L10n.string("cloud.lifecycle.waiting-provider", fallback: "Waiting for provider confirmation")
        case .presenting, .completed, .failed, .cancelled:
            return ""
        }
    }

}

enum CloudAuthorizationPresentationPolicy {
    static let outerInset: CGFloat = 30
    static let cardHorizontalPadding: CGFloat = 44
    private static let cardChromeAndMargins: CGFloat = 280
    private static let maximumDialogLayoutWidth: CGFloat = 780

    static func maximumSurfaceHeight(containerHeight: CGFloat) -> CGFloat {
        min(
            480,
            max(200, containerHeight - cardChromeAndMargins)
        )
    }

    static func availableSurfaceWidth(containerWidth: CGFloat) -> CGFloat {
        min(
            maximumDialogLayoutWidth,
            max(
                240,
                containerWidth
                    - outerInset * 2
                    - cardHorizontalPadding
            )
        )
    }

    static func dialogCardWidth(
        surfaceWidth: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> CGFloat {
        min(
            availableSurfaceWidth + cardHorizontalPadding,
            max(440, surfaceWidth + cardHorizontalPadding)
        )
    }
}

enum AndroidActionSurfacePresentationPolicy {
    static func preferredSize(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumHeight: CGFloat = 520,
        availableWidth: CGFloat = 700,
        presentationMode: AndroidActionSurfacePresentationMode = .fullDisplay
    ) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return CGSize(width: 260, height: 260)
        }
        let ratio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        let heightLimit = max(260, maximumHeight)
        if presentationMode == .dialogCrop {
            let widthLimit = max(1, availableWidth)
            let proportionalLower = widthLimit * 0.65
            let proportionalUpper = widthLimit * 0.80
            let softTarget = min(
                560,
                max(480, widthLimit * 0.72)
            )
            let targetWidth = min(
                proportionalUpper,
                max(proportionalLower, softTarget)
            )
            let width = min(targetWidth, heightLimit * ratio)
            return CGSize(width: width, height: width / ratio)
        }
        let targetHeight = min(
            heightLimit,
            max(260, 700 / max(0.2, ratio))
        )
        let width = min(max(1, availableWidth), 700, targetHeight * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

enum AndroidActionSurfaceGeometryPolicy {
    static func fittedRect(
        container: CGSize,
        pixels: CGSize
    ) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              pixels.width > 0,
              pixels.height > 0 else {
            return .zero
        }
        let scale = min(
            container.width / pixels.width,
            container.height / pixels.height
        )
        let size = CGSize(
            width: pixels.width * scale,
            height: pixels.height * scale
        )
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func pixelPoint(
        location: CGPoint,
        fittedRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> (x: Int, y: Int)? {
        guard fittedRect.width > 0,
              fittedRect.height > 0,
              pixelWidth > 0,
              pixelHeight > 0,
              fittedRect.contains(location) else {
            return nil
        }
        let normalizedX = (location.x - fittedRect.minX) / fittedRect.width
        let normalizedY = (location.y - fittedRect.minY) / fittedRect.height
        return (
            x: min(
                pixelWidth - 1,
                max(0, Int(normalizedX * CGFloat(pixelWidth)))
            ),
            y: min(
                pixelHeight - 1,
                max(0, Int(normalizedY * CGFloat(pixelHeight)))
            )
        )
    }
}

/// Full-surface compatibility view for opaque FongMi/TVBox provider UI. It
/// forwards geometry only; button names, QR images and window text remain
/// provider-owned presentation and never select host behavior.
private struct AndroidActionSurfaceView: View {
    let frame: AndroidActionSurfaceFrame
    let disabled: Bool
    let maximumHeight: CGFloat
    let availableWidth: CGFloat
    let onTap: (Int, Int) -> Void
    let onSwipe: (Int, Int, Int, Int) -> Void

    var body: some View {
        Group {
            if let image = NSImage(data: frame.pngData) {
                let preferredSize =
                    AndroidActionSurfacePresentationPolicy.preferredSize(
                        pixelWidth: frame.pixelWidth,
                        pixelHeight: frame.pixelHeight,
                        maximumHeight: maximumHeight,
                        availableWidth: availableWidth,
                        presentationMode: frame.presentationMode
                    )
                GeometryReader { geometry in
                    let fitted = AndroidActionSurfaceGeometryPolicy.fittedRect(
                        container: geometry.size,
                        pixels: CGSize(
                            width: frame.pixelWidth,
                            height: frame.pixelHeight
                        )
                    )
                    ZStack(alignment: .topLeading) {
                        if frame.presentationMode == .fullDisplay {
                            Color.black.opacity(0.82)
                        }
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .offset(x: fitted.minX, y: fitted.minY)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onEnded { value in
                                submitGesture(
                                    from: value.startLocation,
                                    to: value.location,
                                    fittedRect: fitted
                                )
                            }
                    )
                    .allowsHitTesting(!disabled)
                }
                .frame(
                    width: preferredSize.width,
                    height: preferredSize.height
                )
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                }
                .accessibilityLabel(L10n.string("cloud.android-surface.accessibility", fallback: "Provider Android Configuration Interface"))
                .accessibilityHint(L10n.string("cloud.android-surface.hint", fallback: "Click or drag to interact; use the button below to go back one level"))
            } else {
                Label(
                    L10n.string("cloud.android-surface.unavailable", fallback: "Android configuration screen temporarily unavailable"),
                    systemImage: "rectangle.slash"
                )
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    private func submitGesture(
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        fittedRect: CGRect
    ) {
        guard let start = AndroidActionSurfaceGeometryPolicy.pixelPoint(
                location: startLocation,
                fittedRect: fittedRect,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight
              ),
              let end = AndroidActionSurfaceGeometryPolicy.pixelPoint(
                location: endLocation,
                fittedRect: fittedRect,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight
              ) else {
            return
        }
        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        if sqrt(dx * dx + dy * dy) < 7 {
            onTap(end.x, end.y)
        } else {
            onSwipe(start.x, start.y, end.x, end.y)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession

    var body: some View {
        NativeSidebarSourceList(
            text: searchText,
            presentation: searchPresentation,
            isSearchEnabled: searchIsEnabled,
            focusRequest: state.globalSearchFocusRequest,
            selection: navigation.selection,
            navigation: navigation,
            onTextChange: handleSearchTextChange,
            onSubmit: submitSearch,
            onExitSearch: exitSearchField,
            onSelect: state.selectSection
        )
        .modifier(SidebarColumnWidthModifier())
        .background { BrowserSplitDividerBacking() }
    }

    private var searchPresentation: SidebarSearchPresentation {
        SidebarSearchPresentationPolicy.presentation(
            for: navigation.selectedSection
        )
    }

    private var searchText: Binding<String> {
        switch searchPresentation.kind {
        case .video:
            return $state.searchDraftKeyword
        case .liveChannels:
            return $liveSession.searchText
        }
    }

    private var searchIsEnabled: Bool {
        switch searchPresentation.kind {
        case .video:
            return !state.visibleSites.isEmpty
        case .liveChannels:
            return !state.liveSourceDescriptors.isEmpty
        }
    }

    private func handleSearchTextChange(_ value: String) {
        guard searchPresentation.kind == .video,
              value.isEmpty else { return }
        state.clearGlobalVideoSearch()
    }

    private func submitSearch() {
        guard searchPresentation.kind == .video else { return }
        let keyword = state.searchDraftKeyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        state.searchFromSidebar(keyword)
    }

    private func exitSearchField() -> Bool {
        if searchPresentation.kind == .video,
           state.isHomeSearchPresented {
            state.returnFromSearchToOrigin()
        }
        return true
    }
}

/// Hosts the browser navigation in the same native source-list controls used
/// by AppKit applications. AppKit owns the sidebar material, row size, text,
/// glyph, selection, inactive-window, accent-color, and accessibility states.
/// The only explicit size choices are AppKit's large search control, semantic
/// `large` source-list metrics, and the App Store-matched 36 pt row rhythm;
/// text, glyph slots, and selection rendering remain native.
@MainActor
struct NativeSidebarSourceList: NSViewRepresentable {
    @Binding var text: String
    let presentation: SidebarSearchPresentation
    let isSearchEnabled: Bool
    let focusRequest: UInt64
    let selection: NavigationSelection
    let navigation: AppNavigationState
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onExitSearch: () -> Bool
    let onSelect: (AppSection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView(coordinator: context.coordinator)
        context.coordinator.attach(to: view)
        context.coordinator.synchronize(view)
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(view)
    }

    final class ItemNode: NSObject {
        let section: AppSection

        init(section: AppSection) {
            self.section = section
        }
    }

    final class ContainerView: NSVisualEffectView {
        let searchField = NSSearchField()
        let scrollView = NSScrollView()
        let outlineView = BrowserSidebarOutlineView()

        init(coordinator: Coordinator) {
            super.init(frame: .zero)

            AppSidebarNativePolicy.configure(background: self)

            searchField.translatesAutoresizingMaskIntoConstraints = false
            AppSidebarNativePolicy.configure(searchField: searchField)
            searchField.delegate = coordinator
            searchField.target = coordinator
            searchField.action = #selector(Coordinator.submit(_:))

            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("AppSidebar.column")
            )
            column.resizingMask = .autoresizingMask
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            AppSidebarNativePolicy.configure(outlineView: outlineView)
            outlineView.dataSource = coordinator
            outlineView.delegate = coordinator
            outlineView.setAccessibilityLabel(L10n.string("sidebar.accessibility", fallback: "Sidebar"))

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.documentView = outlineView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false

            addSubview(searchField)
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                searchField.topAnchor.constraint(
                    equalTo: topAnchor,
                    constant: AppSidebarMetrics.topInset
                ),
                searchField.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: AppSidebarMetrics.horizontalInset
                ),
                searchField.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -AppSidebarMetrics.horizontalInset
                ),
                scrollView.topAnchor.constraint(
                    equalTo: searchField.bottomAnchor,
                    constant: AppSidebarMetrics.searchToListSpacing
                ),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class ItemCellView: NSTableCellView {
        private let symbolView = NSImageView()
        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            rowSizeStyle = AppSidebarNativePolicy.rowSizeStyle
            symbolView.imageScaling = .scaleProportionallyDown
            symbolView.contentTintColor = AppSidebarNativePolicy.iconTint

            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1

            imageView = symbolView
            textField = label
            addSubview(symbolView)
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(section: AppSection) {
            label.stringValue = section.title
            label.setAccessibilityLabel(section.title)
            symbolView.image = NSImage(
                systemSymbolName: section.systemImage,
                accessibilityDescription: section.title
            )
        }
    }

    final class SourceListRowView: NSTableRowView {
        var activate: (() -> Void)?
        override func accessibilityPerformPress() -> Bool {
            guard let activate else { return false }
            activate()
            return true
        }
        // App Store keeps the navigation selection neutral while the glyph
        // continues to use its adaptive blue semantic color. This asks AppKit
        // for its native neutral source-list selection instead of painting
        // our own.
        override var isEmphasized: Bool {
            get { false }
            set { super.isEmphasized = false }
        }
    }

    @MainActor
    final class Coordinator: NSObject,
        NSSearchFieldDelegate,
        NSOutlineViewDataSource,
        NSOutlineViewDelegate {
        var parent: NativeSidebarSourceList
        var lastFocusRequest: UInt64 = 0
        private var isSynchronizingSelection = false
        private var latestUserSelection: NavigationSelection?
        private let items = AppSection.allCases.map(ItemNode.init(section:))

        init(_ parent: NativeSidebarSourceList) {
            self.parent = parent
        }

        func attach(to view: ContainerView) {
            view.outlineView.reloadData()
            view.outlineView.currentNavigationSelection = { [weak self] in
                self?.parent.navigation.selection ?? NavigationSelection(section: .home, revision: 0)
            }
            view.outlineView.onActivateRow = { [weak self, weak view] row in
                guard let self, let view else { return }
                self.activate(row: row, in: view.outlineView)
            }
        }

        private func activate(row: Int, in outlineView: NSOutlineView) {
            guard let item = outlineView.item(atRow: row) as? ItemNode else { return }
            parent.onSelect(item.section)
            let selection = parent.navigation.selection
            latestUserSelection = selection
            BrowserInteractionTrace.record("navigation.action", revision: selection.revision)
            synchronizeSelection(outlineView)
            let navigation = parent.navigation
            (outlineView as? BrowserSidebarOutlineView)?.requestContentFocus(for: selection) {
                navigation.selection == selection
            }
        }

        func synchronize(_ view: ContainerView) {
            // A Representable value may predate a newer AppKit click. Never
            // replay that value into either the selection or search control.
            guard parent.selection == parent.navigation.selection,
                  parent.selection.revision >= (latestUserSelection?.revision ?? 0) else { return }
            let field = view.searchField
            field.placeholderString = parent.presentation.placeholder
            field.setAccessibilityLabel(parent.presentation.accessibilityLabel)
            field.toolTip = parent.presentation.help
            field.isEnabled = parent.isSearchEnabled
            if field.stringValue != parent.text {
                field.stringValue = parent.text
            }
            synchronizeSelection(view.outlineView)
            if let selected = latestUserSelection, selected == parent.selection {
                let navigation = parent.navigation
                view.outlineView.requestContentFocus(for: selected) {
                    navigation.selection == selected
                }
                latestUserSelection = nil
            }

            guard parent.focusRequest > 0,
                  lastFocusRequest != parent.focusRequest else { return }
            lastFocusRequest = parent.focusRequest
            let request = parent.focusRequest
            let selection = parent.selection
            let navigation = parent.navigation
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, self.parent.focusRequest == request,
                      navigation.selection == selection,
                      let field, let window = field.window,
                      field.isEnabled else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }

        private func synchronizeSelection(_ outlineView: NSOutlineView) {
            guard let row = row(
                for: parent.navigation.selection.section,
                in: outlineView
            ), outlineView.selectedRow != row else { return }
            isSynchronizingSelection = true
            outlineView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            outlineView.scrollRowToVisible(row)
            isSynchronizingSelection = false
        }

        private func row(
            for section: AppSection,
            in outlineView: NSOutlineView
        ) -> Int? {
            guard let item = items.first(
                where: { $0.section == section }
            ) else { return nil }
            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            item == nil ? items.count : 0
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            items[index]
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            isItemExpandable item: Any
        ) -> Bool {
            false
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            shouldSelectItem item: Any
        ) -> Bool {
            item is ItemNode
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            heightOfRowByItem item: Any
        ) -> CGFloat {
            AppSidebarMetrics.rowHeight
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? ItemNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("AppSidebar.item")
            let cell = outlineView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? ItemCellView ?? ItemCellView()
            cell.identifier = identifier
            cell.configure(section: item.section)
            return cell
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            rowViewForItem item: Any
        ) -> NSTableRowView? {
            guard let item = item as? ItemNode else { return nil }
            let view = SourceListRowView()
            view.activate = { [weak self, weak outlineView] in
                guard let self, let outlineView else { return }
                self.activate(row: outlineView.row(forItem: item), in: outlineView)
            }
            return view
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection,
                  let outlineView = notification.object as? NSOutlineView else { return }
            // A delayed native callback is not a new user command. Restore the
            // authoritative row without manufacturing a newer navigation revision.
            BrowserInteractionTrace.record("navigation.nativeSelection", revision: parent.navigation.selection.revision)
            synchronizeSelection(outlineView)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }
            parent.text = field.stringValue
            parent.onTextChange(field.stringValue)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSSearchField else {
                return false
            }

            switch SidebarSearchEscapePolicy.action(for: textView.string) {
            case .clearText:
                // Match App Store search: the first Escape clears the query
                // while preserving the field editor and its focus. Do not
                // route this through onTextChange because an empty video query
                // intentionally exits the search presentation when it comes
                // from the clear button or normal editing.
                textView.string = ""
                field.stringValue = ""
                parent.text = ""
                return true
            case .exitSearch:
                guard parent.onExitSearch() else { return false }
                field.window?.makeFirstResponder(nil)
                return true
            }
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onTextChange(sender.stringValue)
            parent.onSubmit()
        }
    }
}

private struct CollapsedSidebarSearchButton: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession
    @State private var isPresented = false
    @State private var popoverFocusRequest: UInt64 = 0

    var body: some View {
        Button {
            popoverFocusRequest &+= 1
            isPresented = true
        } label: {
            Label(searchPresentation.accessibilityLabel, systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
        }
        .help(
            L10n.string(
                "sidebar.search.shortcut-help",
                fallback: "%@ (⌘F)",
                searchPresentation.help
            )
        )
        .accessibilityLabel(searchPresentation.accessibilityLabel)
        .disabled(!searchIsEnabled)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            SidebarSearchControl(
                text: searchText,
                presentation: searchPresentation,
                isEnabled: searchIsEnabled,
                focusRequest: state.globalSearchFocusRequest
                    &+ popoverFocusRequest,
                onTextChange: handleSearchTextChange,
                onSubmit: submitSearch
            )
            .frame(width: 300, height: 28)
            .padding(14)
        }
        .onChange(of: state.globalSearchFocusRequest) { _ in
            popoverFocusRequest &+= 1
            isPresented = true
        }
    }

    private var searchPresentation: SidebarSearchPresentation {
        SidebarSearchPresentationPolicy.presentation(
            for: navigation.selectedSection
        )
    }

    private var searchText: Binding<String> {
        switch searchPresentation.kind {
        case .video:
            return $state.searchDraftKeyword
        case .liveChannels:
            return $liveSession.searchText
        }
    }

    private var searchIsEnabled: Bool {
        switch searchPresentation.kind {
        case .video:
            return !state.visibleSites.isEmpty
        case .liveChannels:
            return !state.liveSourceDescriptors.isEmpty
        }
    }

    private func handleSearchTextChange(_ value: String) {
        guard searchPresentation.kind == .video,
              value.isEmpty else { return }
        state.clearGlobalVideoSearch()
    }

    private func submitSearch() {
        defer { isPresented = false }
        guard searchPresentation.kind == .video else { return }
        let keyword = state.searchDraftKeyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        state.searchFromSidebar(keyword)
    }
}

private struct SidebarSearchControl: NSViewRepresentable {
    @Binding var text: String
    let presentation: SidebarSearchPresentation
    let isEnabled: Bool
    let focusRequest: UInt64
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .regular
        field.font = NSFont.systemFont(ofSize: 14)
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = presentation.placeholder
        field.setAccessibilityLabel(presentation.accessibilityLabel)
        field.toolTip = presentation.help
        field.isEnabled = isEnabled
        if field.stringValue != text {
            field.stringValue = text
        }
        guard focusRequest > 0,
              context.coordinator.lastFocusRequest != focusRequest else {
            return
        }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            guard let window = field.window,
                  field.isEnabled else { return }
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarSearchControl
        var lastFocusRequest: UInt64 = 0

        init(_ parent: SidebarSearchControl) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            parent.onTextChange(field.stringValue)
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onTextChange(sender.stringValue)
            parent.onSubmit()
        }
    }
}

private struct SidebarColumnWidthModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.navigationSplitViewColumnWidth(
                min: AppSidebarMetrics.width,
                ideal: AppSidebarMetrics.width,
                max: AppSidebarMetrics.width
            )
        } else {
            content.frame(
                minWidth: AppSidebarMetrics.width,
                idealWidth: AppSidebarMetrics.width,
                maxWidth: AppSidebarMetrics.width
            )
        }
    }
}

private struct SectionContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession
    let showsCollapsedSearch: Bool

    var body: some View {
        Group {
            if state.isDetailPagePresented {
                BrowserDetailRouteContainer()
            } else {
                baseSectionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurfacePalette.background)
        .environment(\.browserNavigationSelection, navigation.selection)
        .transaction { transaction in
            // AppKit hosts SwiftUI toolbar items in constraint-based views.
            // A structural detail-route animation can invalidate those
            // constraints again while the display cycle is already updating.
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var baseSectionContent: some View {
        Group {
            switch navigation.selectedSection {
            case .home, .live:
                HomeLiveSectionContainer(liveSession: liveSession)
            case .favorites:
                StandardBrowserSectionContainer(nativeChrome: true) {
                    FavoritesView()
                }
            case .history:
                StandardBrowserSectionContainer(nativeChrome: true) {
                    HistoryView()
                }
            case .settings:
                StandardBrowserSectionContainer {
                    SettingsView(navigation: state.settingsNavigation)
                }
            }
        }
    }
}

/// Applies the same right-column titlebar material used by the home browser to
/// the remaining primary sections without changing the independent Sidebar.
private struct StandardBrowserSectionContainer<Content: View>: View {
    @EnvironmentObject private var state: AppState
    @State private var isContentScrolled = false
    private let content: Content
    private let nativeChrome: Bool

    init(nativeChrome: Bool = false, @ViewBuilder content: () -> Content) {
        self.nativeChrome = nativeChrome
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .environment(
                    \.primaryToolbarLayout,
                    PrimaryToolbarLayoutPolicy.layout(
                        contentWidth: proxy.size.width
                    )
                )
                .environment(\.browserToolbarScrollReporter) { isScrolled in
                    if isContentScrolled != isScrolled {
                        isContentScrolled = isScrolled
                    }
                }
                .modifier(
                    BrowserToolbarChromeModifier(
                        isScrolled: isContentScrolled,
                        isWindowActive: state.isBrowserWindowKey,
                        usesSystemChrome: nativeChrome
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Presents details as a page inside the split view's detail column. Browser
/// state lives in AppState/LiveBrowserSession, so the expensive originating
/// grid can be unmounted instead of continuing to lay out invisibly.
private struct BrowserDetailRouteContainer: View {
    @EnvironmentObject private var state: AppState
    @State private var isContentScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            if state.selectedDetail != nil, state.detailLoadState.message != nil {
                DetailRequestStatusView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            if let detail = state.selectedDetail {
                DetailView(detail: detail)
                    .id(detail.summary.id)
            } else if let summary = state.detailRouteSummary ?? state.pendingDetailSummary {
                DetailLoadingView(summary: summary)
            }
        }
        // A concrete container owns both navigation preferences and toolbar
        // items. Attaching the back item to a Group while its children own
        // their titles/toolbars drops it during loading -> detail on macOS.
        .navigationTitle("")
        .toolbar {
            ToolbarItem(id: "detail.back", placement: .navigation) {
                BrowserToolbarBackButton(
                    help: L10n.string(
                        "common.back-previous",
                        fallback: "Back to the previous page"
                    ),
                    identifier: "detail.back",
                    action: { state.dismissDetail() }
                )
                .frame(
                    width: PrimaryToolbarMetrics.iconControlSize,
                    height: PrimaryToolbarMetrics.iconControlSize
                )
            }
            ToolbarItem(id: "detail.space", placement: .principal) {
                Spacer(minLength: 0).frame(maxWidth: .infinity)
            }
            ToolbarItem(id: "detail.refresh", placement: .primaryAction) {
                DetailRefreshButton(isLoading: state.isRefreshingDetail) {
                    Task { await state.refreshDetail() }
                }
                .frame(width: PrimaryToolbarMetrics.iconControlSize, height: PrimaryToolbarMetrics.iconControlSize)
            }

        }
        .environment(\.browserToolbarScrollReporter) { isScrolled in
            if isContentScrolled != isScrolled {
                isContentScrolled = isScrolled
            }
        }
        .modifier(
            BrowserToolbarChromeModifier(
                isScrolled: isContentScrolled,
                isWindowActive: state.isBrowserWindowKey
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurfacePalette.background)
    }
}

/// Home and live are the two largest browsing trees. Keep their lightweight
/// session state here, but mount only the visible tree: an opacity-hidden live
/// grid still participates in SwiftUI updates and can contend with playback.
private struct HomeLiveSectionContainer: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession
    @State private var isBrowserContentScrolled = false

    private var showsHome: Bool {
        navigation.selectedSection == .home
    }

    private var showsHomeToolbar: Bool {
        showsHome
            && !state.isHomeSearchPresented
            && !state.isDetailPagePresented
            && state.activeConfiguration != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let toolbarLayout = HomeToolbarLayoutPolicy.layout(
                contentWidth: proxy.size.width
            )
            Group {
                if showsHome {
                    HomeView()
                } else {
                    LiveView(session: liveSession)
                }
            }
            .environment(\.primaryToolbarLayout, toolbarLayout)
            .environment(\.browserToolbarScrollReporter) { isScrolled in
                if isBrowserContentScrolled != isScrolled {
                    isBrowserContentScrolled = isScrolled
                }
            }
            .navigationTitle("")
            .modifier(
                HomeLiveToolbarModifier(
                    showsHomeToolbar: showsHomeToolbar,
                    showsLiveToolbar: !showsHome,
                    isInteractionBlocked:
                        state.mainWindowCloudAuthorizationPrompt != nil,
                    layout: toolbarLayout,
                    liveSession: liveSession
                )
            )
            .modifier(
                BrowserToolbarChromeModifier(
                    isScrolled: isBrowserContentScrolled,
                    isWindowActive: state.isBrowserWindowKey
                )
            )
            .onChange(of: navigation.selectedSection) { _ in
                isBrowserContentScrolled = false
            }
            .onChange(of: state.isHomeSearchPresented) { _ in
                isBrowserContentScrolled = false
            }
            .onChange(of: state.shortcutLiveSourceSelection) { request in
                guard let request else { return }
                liveSession.selectedSourceID = request.sourceID
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct HomeLiveToolbarModifier: ViewModifier {
    let showsHomeToolbar: Bool
    let showsLiveToolbar: Bool
    let isInteractionBlocked: Bool
    let layout: HomeToolbarLayout
    @ObservedObject var liveSession: LiveBrowserSession

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsHomeToolbar {
            content.toolbar {
                HomeBrowserToolbarContent(
                    layout: layout,
                    isInteractionBlocked: isInteractionBlocked
                )
            }
        } else if showsLiveToolbar {
            content.toolbar {
                LiveBrowserToolbarContent(
                    session: liveSession,
                    isInteractionBlocked: isInteractionBlocked
                )
            }
        } else {
            // Search and detail pages own their toolbars. Do not attach empty
            // parent items: AppKit otherwise exposes a stray capsule beside
            // the native sidebar button when it merges nested toolbars.
            content
        }
    }
}

private struct HomeBrowserToolbarContent: ToolbarContent {
    let layout: HomeToolbarLayout
    let isInteractionBlocked: Bool

    var body: some ToolbarContent {
        PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionBrowse))
        ToolbarItemGroup(placement: .primaryAction) {
            HomeConfigurationToolbarItem(layout: layout)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .disabled(isInteractionBlocked)
            HomeSiteToolbarItem(layout: layout)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .disabled(isInteractionBlocked)
            HomeFilterToolbarItem(layout: layout)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .disabled(isInteractionBlocked)
            PrimaryToolbarDivider()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
            HomeRefreshToolbarItem(layout: layout)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .disabled(isInteractionBlocked)
        }
    }
}

private struct LiveBrowserToolbarContent: ToolbarContent {
    @ObservedObject var session: LiveBrowserSession
    let isInteractionBlocked: Bool

    var body: some ToolbarContent {
        PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionLiveTV))
        ToolbarItemGroup(placement: .primaryAction) {
            LiveToolbarView(session: session)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .disabled(isInteractionBlocked)
        }
    }
}
