import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import WebKit

enum AppSurfacePalette {
    static var background: Color {
        // Keep the browse surface in the native window palette. Using the
        // control background here turns the entire detail column paper-white
        // and visually disconnects the category strip from the titlebar.
        Color(nsColor: .windowBackgroundColor)
    }
}

enum AppSidebarMetrics {
    static let minimumWidth: CGFloat = 224
    static let idealWidth: CGFloat = 224
    static let maximumWidth: CGFloat = 280
    static let horizontalInset: CGFloat = 16
    static let searchHeight: CGFloat = 32
    static let rowHeight: CGFloat = 26
    static let labelFontSize: CGFloat = 14
    static let iconWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static let rowContentMinimumWidth: CGFloat = 168
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

enum SidebarRowHoverPolicy {
    static let cornerRadius: CGFloat = 6
    static let animationDuration: TimeInterval = 0.11
    static let selectionBackgroundOpacity = 0.10

    static func hoverOverlayOpacity(
        isSelected: Bool,
        isHovering: Bool,
        isEnabled: Bool
    ) -> Double {
        guard isEnabled, isHovering else { return 0 }
        return isSelected ? 0.04 : 0.06
    }
}

/// A compact hover treatment for sidebar navigation rows. Selection remains
/// owned by the native List whenever possible; this modifier only supplies a
/// stable, layout-neutral hover overlay. Selection stays native so every row
/// receives exactly the same width, height, and neutral sidebar appearance.
struct SidebarRowHoverModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let isSelected: Bool

    func body(content: Content) -> some View {
        let hoverOpacity = SidebarRowHoverPolicy.hoverOverlayOpacity(
            isSelected: isSelected,
            isHovering: isHovering,
            isEnabled: isEnabled
        )

        content
            .background {
                ZStack {
                    if isSelected {
                        RoundedRectangle(
                            cornerRadius: SidebarRowHoverPolicy.cornerRadius,
                            style: .continuous
                        )
                        .fill(
                            Color.primary.opacity(
                                SidebarRowHoverPolicy.selectionBackgroundOpacity
                            )
                        )
                    }

                    RoundedRectangle(
                        cornerRadius: SidebarRowHoverPolicy.cornerRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(hoverOpacity))
                }
            }
            .animation(
                .easeOut(duration: SidebarRowHoverPolicy.animationDuration),
                value: hoverOpacity
            )
            .onHover { isHovering = isEnabled && $0 }
    }
}

extension View {
    func sidebarRowHover(isSelected: Bool) -> some View {
        modifier(
            SidebarRowHoverModifier(
                isSelected: isSelected
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

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var liveSession = LiveBrowserSession()

    var body: some View {
        ZStack {
            BrowserWindowVibrancyBackground()
                .ignoresSafeArea()

            browsingContent
        }
        .alert(item: $state.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
        .overlay {
            if let presentation = state.configurationCategoryPresentation {
                ConfigurationCategoryView(presentation: presentation)
                    .environmentObject(state)
            }
        }
        .overlay {
            if let prompt = state.mainWindowCloudAuthorizationPrompt {
                CloudAuthorizationView(prompt: prompt)
                    .environmentObject(state)
            }
        }
        .overlay(alignment: .bottom) {
            if let status = state.siteActionStatus {
                TransientSiteActionStatusView(status: status)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let presentation = state.mainWindowNodeWebPresentation {
                NodeConfigurationView(presentation: presentation)
                    .environmentObject(state)
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
                    TextField("切换配置、站点或直播源", text: $query)
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
                    .help("关闭")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !matchingConfigurations.isEmpty {
                            switcherHeader("点播配置")
                            ForEach(matchingConfigurations) { configuration in
                                switcherRow(
                                    title: configuration.name,
                                    subtitle: configuration.isActive
                                        ? "当前配置" : nil,
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
                            switcherHeader("点播站点")
                            ForEach(matchingSites, id: \.key) { site in
                                switcherRow(
                                    title: site.name,
                                    subtitle: site.key == state.selectedSiteKey
                                        ? "当前站点" : nil,
                                    systemImage: "play.rectangle"
                                ) {
                                    state.dismissQuickSwitcher()
                                    state.selectSection(.home)
                                    Task { await state.selectSite(site.key) }
                                }
                            }
                        }

                        if !matchingLiveSources.isEmpty {
                            switcherHeader("直播源")
                            ForEach(matchingLiveSources) { source in
                                switcherRow(
                                    title: source.name,
                                    subtitle: "进入直播",
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
                                title: "没有匹配项目",
                                message: "请尝试输入其他名称。"
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
                    Text("输入名称筛选  ·  Return 打开首项  ·  Esc 关闭")
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

    private var matchingLiveSources: [StoredLiveSource] {
        state.liveSources.filter { matches($0.name) }
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
        ("导航", [
            ("⌘1…⌘5", "点播、直播、收藏、历史、设置"),
            ("⌘F", "搜索"),
            ("⌘K", "快速切换配置、站点或直播源"),
            ("⌘L", "打开点播配置"),
            ("⌘R", "刷新当前页面"),
            ("⌘[", "返回"),
            ("⌘.", "停止当前搜索"),
            ("Esc", "停止搜索；再按返回进入前的页面")
        ]),
        ("播放器", [
            ("Space", "播放或暂停"),
            ("← / →", "快退或快进 10 秒"),
            ("⇧← / ⇧→", "快退或快进 30 秒"),
            ("⌥← / ⌥→", "上一集或下一集"),
            ("↑ / ↓", "上一个或下一个直播频道"),
            ("M", "静音"),
            ("− / =", "音量减小或增大"),
            ("C / A", "字幕开关 / 下一音轨"),
            ("F", "进入或退出全屏"),
            ("Esc", "关闭播放面板或退出全屏"),
            ("⇧, / ⇧.", "降低或提高播放速度"),
            ("⌘W", "关闭播放器窗口")
        ]),
        ("系统", [
            ("⌘,", "打开设置"),
            ("⌘/", "显示本快捷键列表")
        ])
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { state.dismissShortcutHelp() }

            VStack(spacing: 0) {
                HStack {
                    Label("键盘快捷键", systemImage: "keyboard")
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
        ZStack {
            backdrop
            card
        }
        .zIndex(900)
    }

    private var backdrop: some View {
        Color.black.opacity(0.42)
            .ignoresSafeArea()
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 28, y: 12)
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text("配置中心")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
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
            Text("正在读取当前配置操作…")
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
            Button("重试") {
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
                        item: item,
                        isDisabled: state.isConfigurationInteractionActive
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
            Text("关闭后会回到原来的内容页和浏览位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("关闭") {
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

private struct ConfigurationCategoryRow: View {
    let item: SiteActionItem
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
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
        .disabled(isDisabled)
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
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.person.crop")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isPlayerAuthorization ? "等待网盘授权" : presentation.title)
                            .font(.headline)
                        Text(
                            isPlayerAuthorization
                                ? "请使用对应网盘 App 扫码，授权成功后会自动继续播放。"
                                : presentation.message
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
                        Label("刷新", systemImage: "arrow.clockwise")
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
                        pageState: $pageState
                    )
                    .background(Color(nsColor: .textBackgroundColor))

                    switch pageState {
                    case .loading:
                        VStack(spacing: 12) {
                            AppActivityIndicator(size: .regular)
                            Text("正在打开配置页…")
                                .font(.callout.weight(.semibold))
                            Text("正在连接当前 CatPaw Runtime")
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
                            Text("配置页不可用")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                            Button("重新加载") {
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
                           ).isEmpty {
                            Text(status)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("关闭") {
                        state.cancelNodeConfiguration()
                    }
                    Button {
                        Task { await state.completeNodeConfigurationAndRetry() }
                    } label: {
                        Label(
                            isPlayerAuthorization
                                ? "我已授权，立即验证"
                                : "应用配置并重试",
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
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 36, y: 14)
            .padding(26)
        }
        .zIndex(2_000)
    }

    private var footerTitle: String {
        switch presentation.lifecycleState {
        case .waiting:
            return presentation.allowsAutomaticRetry
                ? "正在等待授权完成信号"
                : "请确认授权状态后手动验证"
        case .saved:
            return isPlayerAuthorization
                ? "配置已保存，等待授权验证"
                : "配置已保存"
        case .verifying:
            return "正在验证授权并恢复原请求"
        case .needsManualRetry:
            return "需要手动确认"
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
    @Binding var pageState: NodeConfigurationPageState

    func makeCoordinator() -> Coordinator {
        Coordinator(origin: url, pageState: $pageState)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.lastRevision = revision
        context.coordinator.origin = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.origin = url
        context.coordinator.pageState = $pageState
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
        var pageState: Binding<NodeConfigurationPageState>

        init(origin: URL, pageState: Binding<NodeConfigurationPageState>) {
            self.origin = origin
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
                return "Node 已重启或配置页地址已经失效，请关闭后重新打开配置入口。"
            }
            return "配置页加载失败：\(error.localizedDescription)"
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        // Resizing while SwiftUI is mounting this representable can re-enter
        // AppKit layout. Configure on the next run-loop turn, after the
        // browser hierarchy has completed its current layout transaction.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            AppWindowLayoutPolicy.configure(window, target: .mainWindow)
            BrowserWindowChromeController.configure(window)
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
                  (!Self.isEditingText(in: window) || event.keyCode == 53),
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
            ZStack {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A modal authorization surface owns the whole window.
                        // Consume backdrop clicks so they never reach content.
                    }
                    .accessibilityHidden(true)

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
            }
            .contentShape(Rectangle())
        }
        .zIndex(1_000)
    }

    private func authorizationCard(
        maximumSurfaceHeight: CGFloat,
        availableSurfaceWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: usesDialogCropLayout ? 12 : 16) {
            HStack {
                Label(
                    isAuthorization
                        ? "网盘授权"
                        : "配置操作",
                    systemImage: isAuthorization
                        ? "externaldrive.badge.person.crop"
                        : "slider.horizontal.3"
                )
                    .font(.title2.bold())
                Spacer()
                Button {
                    Task { await state.refreshCloudAuthorization() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy || isTerminal)
            }

            Text(prompt.title)
                .font(.headline)

            if prompt.lifecyclePhase == .completed {
                Label(
                    isAuthorization ? "授权已完成" : "配置操作已完成",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.headline)
                .foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            } else if prompt.lifecyclePhase == .failed {
                Label(
                    isAuthorization ? "授权尚未完成" : "配置操作尚未完成",
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
                        Text("这是站点原生 Android 界面，可直接点击或拖动。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            isTextEntryExpanded.toggle()
                        } label: {
                            Label(
                                isTextEntryExpanded ? "收起输入" : "输入文字",
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
                            Label("返回上一层", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isTerminal)
                    }
                }
                if isTextEntryExpanded {
                    HStack(spacing: 8) {
                        TextField(
                            "点击 Android 输入框后，可在这里发送文字",
                            text: $state.cloudAuthorizationInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(isTerminal)
                        Button("发送文字") {
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
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || prompt.lifecyclePhase == .completed)
                }
                if prompt.allowsCompletionConfirmation,
                   !isTerminal {
                    Button {
                        Task {
                            await state.confirmCloudAuthorizationCompletion()
                        }
                    } label: {
                        Label("完成并刷新", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.lifecyclePhase == .submitting)
                }
                Spacer()
                Button(isPlayerAuthorization ? "取消播放" : "关闭") {
                    Task { await state.cancelCloudAuthorization() }
                }
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
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 12)
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
            return "正在提交配置命令"
        case .awaitingInterface:
            return "正在等待下一步操作界面"
        case .submitting:
            return "正在提交当前操作"
        case .processing:
            return "正在等待站点确认结果"
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
                .accessibilityLabel("站点 Android 配置界面")
                .accessibilityHint("点击或拖动以操作；下方按钮可返回上一层")
            } else {
                Label(
                    "Android 配置画面暂时不可用",
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

    private let primarySections: [AppSection] = [.home, .live]
    private let personalSections: [AppSection] = [
        .favorites,
        .history,
        .settings
    ]

    var body: some View {
        VStack(spacing: 0) {
            SidebarSearchControl(
                text: searchText,
                presentation: searchPresentation,
                isEnabled: searchIsEnabled,
                focusRequest: state.globalSearchFocusRequest,
                onTextChange: handleSearchTextChange,
                onSubmit: submitSearch
            )
            .frame(height: AppSidebarMetrics.searchHeight)
            .padding(.horizontal, AppSidebarMetrics.horizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 8)

            List {
                Section("浏览") {
                    ForEach(primarySections) { section in
                        sidebarNavigationRow(section)
                    }
                }

                Section("资料库") {
                    ForEach(personalSections) { section in
                        sidebarNavigationRow(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, AppSidebarMetrics.rowHeight)
        }
        .modifier(SidebarColumnWidthModifier())
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
            return !state.liveSources.isEmpty
        }
    }

    private func sidebarNavigationRow(_ section: AppSection) -> some View {
        let isSelected = navigation.selectedSection == section
        return Button {
            state.selectSection(section)
        } label: {
            SidebarRowContent(
                section: section,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
}

private struct SidebarRowContent: View {
    let section: AppSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: AppSidebarMetrics.iconTextSpacing) {
            Image(systemName: section.systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(Color(nsColor: .systemBlue))
                .frame(width: AppSidebarMetrics.iconWidth, alignment: .center)

            Text(section.rawValue)
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
            .font(.system(size: AppSidebarMetrics.labelFontSize, weight: .regular))
            // A finite proposal avoids SwiftUI's sidebar table collapsing the
            // text column to its truncation glyph when the split view restores
            // a saved width. The row can still expand naturally with the list.
            .frame(
                minWidth: AppSidebarMetrics.rowContentMinimumWidth,
                maxWidth: .infinity,
                alignment: .leading
            )
            .frame(height: AppSidebarMetrics.rowHeight - 2)
            .contentShape(Rectangle())
            .sidebarRowHover(isSelected: isSelected)
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
        .help("\(searchPresentation.help)（⌘F）")
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
            return !state.liveSources.isEmpty
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
                min: AppSidebarMetrics.minimumWidth,
                ideal: AppSidebarMetrics.idealWidth,
                max: AppSidebarMetrics.maximumWidth
            )
        } else {
            content.frame(
                minWidth: AppSidebarMetrics.minimumWidth,
                idealWidth: AppSidebarMetrics.idealWidth,
                maxWidth: AppSidebarMetrics.maximumWidth
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
                StandardBrowserSectionContainer {
                    FavoritesView()
                }
            case .history:
                StandardBrowserSectionContainer {
                    HistoryView()
                }
            case .settings:
                StandardBrowserSectionContainer {
                    SettingsView()
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

    init(@ViewBuilder content: () -> Content) {
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
                        isWindowActive: state.isBrowserWindowKey
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
        Group {
            if let detail = state.selectedDetail {
                DetailView(detail: detail)
            } else if let summary = state.pendingDetailSummary {
                DetailLoadingView(summary: summary)
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
        PrimaryPageToolbarLeadingContent(title: "点播")
        ToolbarItemGroup(placement: .primaryAction) {
            HomeConfigurationToolbarItem(layout: layout)
                .frame(height: 40)
                .disabled(isInteractionBlocked)
            HomeSiteToolbarItem(layout: layout)
                .frame(height: 40)
                .disabled(isInteractionBlocked)
            HomeFilterToolbarItem(layout: layout)
                .frame(height: 40)
                .disabled(isInteractionBlocked)
            HomeRefreshToolbarItem(layout: layout)
                .frame(height: 40)
                .disabled(isInteractionBlocked)
        }
    }
}

private struct LiveBrowserToolbarContent: ToolbarContent {
    @ObservedObject var session: LiveBrowserSession
    let isInteractionBlocked: Bool

    var body: some ToolbarContent {
        PrimaryPageToolbarLeadingContent(title: "直播")
        ToolbarItemGroup(placement: .primaryAction) {
            LiveToolbarView(session: session)
                .disabled(isInteractionBlocked)
        }
    }
}
