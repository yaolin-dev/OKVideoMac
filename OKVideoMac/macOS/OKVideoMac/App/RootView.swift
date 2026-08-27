import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import WebKit

enum AppSurfacePalette {
    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
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

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            AppSurfacePalette.background
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
        .sheet(
            isPresented: Binding(
                get: {
                    state.selectedDetail != nil
                        || state.pendingDetailSummary != nil
                },
                set: { if !$0 { state.dismissDetail() } }
            )
        ) {
            if let detail = state.selectedDetail {
                DetailView(detail: detail)
                    .environmentObject(state)
                    .frame(minWidth: 820, minHeight: 600)
            } else if let summary = state.pendingDetailSummary {
                DetailLoadingView(summary: summary)
                    .environmentObject(state)
                    .frame(minWidth: 820, minHeight: 600)
            }
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
            NavigationSplitView {
                SidebarView()
            } detail: {
                SectionContentView()
            }
        } else {
            NavigationView {
                SidebarView()
                SectionContentView()
            }
            .navigationViewStyle(.columns)
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
            ("⌘1…⌘5", "首页、直播、收藏、历史、设置"),
            ("⌘F", "搜索"),
            ("⌘K", "快速切换配置、站点或直播源"),
            ("⌘L", "打开点播配置"),
            ("⌘R", "刷新当前页面"),
            ("⌘[", "返回"),
            ("⌘.", "停止当前搜索"),
            ("Esc", "停止搜索；再按返回首页")
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
            Text("关闭后会回到原来的网盘目录和浏览位置。")
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
                        Label("我已授权，立即验证", systemImage: "arrow.right.circle.fill")
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
        case .verifying:
            return "正在验证授权并恢复原请求"
        case .needsManualRetry:
            return "需要手动确认"
        }
    }

    private var footerSystemImage: String {
        switch presentation.lifecycleState {
        case .waiting: return "qrcode.viewfinder"
        case .verifying: return "arrow.triangle.2.circlepath"
        case .needsManualRetry: return "exclamationmark.triangle.fill"
        }
    }

    private var footerColor: Color {
        presentation.lifecycleState == .needsManualRetry ? .orange : .accentColor
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

struct CloudAuthorizationView: View {
    @EnvironmentObject private var state: AppState
    let prompt: CloudAuthorizationPrompt

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
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
                } else if isBusy {
                    HStack(spacing: 10) {
                        AppActivityIndicator(size: .small)
                        Text(lifecycleStatus)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                } else if prompt.credentialPush {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本机安全提交")
                                .font(.headline)
                            Text("凭据不会写入 Mac 配置，也不会通过局域网传输。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if prompt.qrState == .ready,
                          prompt.displaysLoginQRCode,
                   let data = prompt.snapshot,
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .padding(14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.18))
                        }
                        .frame(maxWidth: .infinity)
                } else if prompt.qrState == .generating {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            AppActivityIndicator(size: .regular)
                            Text("正在生成二维码…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 280, height: 220)
                        Spacer()
                    }
                } else if prompt.qrState == .expired
                            || prompt.qrState == .notFound {
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 42))
                            .foregroundColor(.orange)
                        Text(prompt.qrState == .expired
                             ? "二维码已过期"
                             : "暂时没有捕获到登录二维码")
                            .font(.headline)
                        Text("请刷新或重试，当前播放请求会保持不变。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                if let status = prompt.status,
                   !status.isEmpty,
                   !prompt.structuredRows.flatMap(\.labels)
                    .contains(where: { $0.title == status }) {
                    Text(status)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                if prompt.hasTextInput {
                    Group {
                        if prompt.usesSecureInput {
                            SecureField(
                                inputPlaceholder,
                                text: $state.cloudAuthorizationInput
                            )
                        } else {
                            TextField(
                                inputPlaceholder,
                                text: $state.cloudAuthorizationInput
                            )
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy || isTerminal)
                    Text(prompt.usesSecureInput
                         ? "内容直接提交给本机 Java/Dex 插件，Mac 端不会另行保存。"
                         : "内容仅用于当前配置操作。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if prompt.credentialPush {
                    Button {
                        Task { await state.submitCloudCredential() }
                    } label: {
                        Label(
                            isAuthorization ? "提交授权" : "提交配置",
                            systemImage: "arrow.right.circle.fill"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        state.cloudAuthorizationInput
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty || isBusy || isTerminal
                    )
                } else if prompt.uiSchemaVersion ?? 0 >= 2,
                          !prompt.structuredRows.isEmpty {
                    AndroidConfigurationSurfaceView(
                        rows: prompt.structuredRows,
                        actions: prompt.actions,
                        disabled: isBusy || isTerminal
                    ) { action in
                        Task {
                            await state.submitCloudAuthorization(action: action)
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 130), spacing: 8)
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(prompt.actions) { action in
                            Button(action.title) {
                                Task {
                                    await state.submitCloudAuthorization(action: action)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(isBusy || isTerminal)
                        }
                    }
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
                    Spacer()
                    Button(isPlayerAuthorization ? "取消播放" : "关闭") {
                        Task { await state.cancelCloudAuthorization() }
                    }
                }
            }
            .padding(22)
            .frame(minWidth: 560, idealWidth: 700, maxWidth: 780)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 24)
            .padding()
        }
        .zIndex(1_000)
    }

    private var isAuthorization: Bool {
        prompt.semantic.isAuthorization || prompt.qrState != .idle
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

    private var inputPlaceholder: String {
        prompt.usesSecureInput ? "粘贴凭据" : "输入配置内容"
    }
}

/// A native macOS projection of the Android provider's configuration view.
/// The bridge supplies geometry and hierarchy instead of a flattened button
/// list, allowing labels, state and ordering controls to stay associated.
private struct AndroidConfigurationSurfaceView: View {
    let rows: [AndroidConfigurationSurfaceRow]
    let actions: [CloudAuthorizationAction]
    let disabled: Bool
    let submit: (CloudAuthorizationAction) -> Void

    private var actionsByID: [String: CloudAuthorizationAction] {
        Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    AndroidConfigurationSurfaceRowView(
                        row: row,
                        actionsByID: actionsByID,
                        disabled: disabled,
                        submit: submit
                    )
                    if row.id != rows.last?.id {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .frame(minHeight: 80, maxHeight: 440)
    }
}

private struct AndroidConfigurationSurfaceRowView: View {
    let row: AndroidConfigurationSurfaceRow
    let actionsByID: [String: CloudAuthorizationAction]
    let disabled: Bool
    let submit: (CloudAuthorizationAction) -> Void

    private var labels: [AndroidBridgeUIElement] {
        row.labels.filter {
            !["textfield", "securefield"].contains($0.normalizedType)
        }
    }

    private var inputElements: [AndroidBridgeUIElement] {
        row.elements.filter {
            ["textfield", "securefield"].contains($0.normalizedType)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if labels.isEmpty, let namedAction = namedStandaloneAction {
                    Text(namedAction.title)
                        .font(.body.weight(.medium))
                } else {
                    ForEach(Array(labels.enumerated()), id: \.element.id) { index, label in
                        Text(label.title)
                            .font(index == 0 ? .body.weight(.medium) : .caption)
                            .foregroundColor(index == 0 ? .primary : .secondary)
                            .lineLimit(index == 0 ? 2 : 3)
                    }
                }

                ForEach(inputElements) { input in
                    HStack(spacing: 6) {
                        Image(systemName: input.normalizedType == "securefield"
                            ? "lock.fill" : "text.cursor")
                        Text(input.hint.flatMap {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty ? nil : $0
                        } ?? input.title)
                        if input.hasValue == true {
                            Text("已填写")
                                .foregroundColor(.green)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(row.actions) { element in
                    if let action = actionsByID[element.id] {
                        actionButton(element: element, action: action)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }

    private var namedStandaloneAction: AndroidBridgeUIElement? {
        guard row.actions.count == 1,
              let action = row.actions.first,
              !isArrowTitle(action.title) else { return nil }
        return action
    }

    @ViewBuilder
    private func actionButton(
        element: AndroidBridgeUIElement,
        action: CloudAuthorizationAction
    ) -> some View {
        if element.normalizedType == "toggle" {
            Button {
                submit(action)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: element.checked == true
                        ? "checkmark.circle.fill" : "circle")
                    Text(element.checked == true ? "已开启" : "已关闭")
                }
            }
            .buttonStyle(.bordered)
            .tint(element.checked == true ? .accentColor : .secondary)
            .disabled(disabled || element.enabled == false)
            .accessibilityLabel(action.title)
        } else if let symbol = arrowSymbol(for: action.title) {
            Button {
                submit(action)
            } label: {
                Image(systemName: symbol)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(disabled || element.enabled == false)
            .help(arrowHelp(for: action.title))
            .accessibilityLabel(arrowHelp(for: action.title))
        } else {
            if isPrimary(action) {
                Button(action.title) {
                    submit(action)
                }
                .buttonStyle(.borderedProminent)
                .disabled(disabled || element.enabled == false)
            } else {
                Button(action.title) {
                    submit(action)
                }
                .buttonStyle(.bordered)
                .disabled(disabled || element.enabled == false)
            }
        }
    }

    private func isPrimary(_ action: CloudAuthorizationAction) -> Bool {
        let value = [action.title, action.role ?? ""]
            .joined(separator: " ")
            .lowercased()
        return value.contains("保存") || value.contains("确定")
            || value.contains("登录") || value.contains("save")
            || value.contains("confirm")
    }

    private func isArrowTitle(_ title: String) -> Bool {
        arrowSymbol(for: title) != nil
    }

    private func arrowSymbol(for title: String) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["▲", "↑", "上移", "向上", "up"].contains(normalized) {
            return "chevron.up"
        }
        if ["▼", "↓", "下移", "向下", "down"].contains(normalized) {
            return "chevron.down"
        }
        return nil
    }

    private func arrowHelp(for title: String) -> String {
        arrowSymbol(for: title) == "chevron.up" ? "上移" : "下移"
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @Environment(\.colorScheme) private var colorScheme

    private var selectionColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.38, green: 0.40, blue: 0.72)
        }
        return Color(red: 0.29, green: 0.31, blue: 0.58)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
        }
        .frame(minWidth: 160)
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .modifier(SidebarColumnWidthModifier())
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = navigation.selectedSection == section
        return Button {
            state.selectSection(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 23)
                    .foregroundColor(isSelected ? .white : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? selectionColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 8, selected: isSelected)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarColumnWidthModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 230)
        } else {
            content.frame(idealWidth: 190, maxWidth: 230)
        }
    }
}

private struct SectionContentView: View {
    @EnvironmentObject private var navigation: AppNavigationState
    @StateObject private var liveSession = LiveBrowserSession()

    var body: some View {
        Group {
            switch navigation.selectedSection {
            case .home, .live:
                HomeLiveSectionContainer(liveSession: liveSession)
            case .favorites:
                FavoritesView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurfacePalette.background.ignoresSafeArea())
    }
}

/// Home and live are the two largest browsing trees. Keeping them mounted
/// avoids tearing down dozens of live cards while simultaneously constructing
/// the poster grid. The navigation store is intentionally observed only here,
/// so changing sections does not invalidate either content subtree.
private struct HomeLiveSectionContainer: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession

    private var showsHome: Bool {
        navigation.selectedSection == .home
    }

    private var showsHomeToolbar: Bool {
        showsHome
            && !state.isHomeSearchPresented
            && state.activeConfiguration != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let toolbarLayout = HomeToolbarLayoutPolicy.layout(
                contentWidth: proxy.size.width
            )
            ZStack {
                HomeView()
                    .opacity(showsHome ? 1 : 0)
                    .allowsHitTesting(showsHome)
                    .accessibilityHidden(!showsHome)
                    .zIndex(showsHome ? 1 : 0)

                LiveView(session: liveSession)
                    .opacity(showsHome ? 0 : 1)
                    .allowsHitTesting(!showsHome)
                    .accessibilityHidden(showsHome)
                    .zIndex(showsHome ? 0 : 1)
            }
            .navigationTitle(navigation.selectedSection.rawValue)
            .toolbar {
                // Separate ToolbarItems are intentional: a narrow window can
                // overflow low-priority actions without hiding the essential
                // site and search entries as one indivisible group.
                ToolbarItem {
                    if showsHomeToolbar {
                        HomeSiteToolbarItem(layout: toolbarLayout)
                    }
                }
                ToolbarItem {
                    if showsHomeToolbar {
                        HomeSearchToolbarItem(layout: toolbarLayout)
                    }
                }
                ToolbarItem {
                    if showsHomeToolbar {
                        HomeConfigurationToolbarItem()
                    }
                }
                ToolbarItem {
                    if showsHomeToolbar {
                        HomeRefreshToolbarItem(layout: toolbarLayout)
                    }
                }
                ToolbarItem {
                    if !showsHome {
                        LiveToolbarView(session: liveSession)
                    }
                }
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
        }
    }
}
