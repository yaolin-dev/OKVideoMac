import AppKit
import SwiftUI
import OKVideoCore

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var filterSelection: [String: String] = [:]
    private let categoryScrollCoordinateSpace = "home-category-scroll"

    var body: some View {
        Group {
            if state.isHomeSearchPresented {
                SearchView()
            } else {
                homeContent
            }
        }
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .sheet(
            item: Binding(
                get: { state.nativeMyDriveOrderEditor },
                set: { value in
                    if value == nil {
                        state.dismissNativeMyDriveOrderEditor()
                    }
                }
            )
        ) { editor in
            NativeMyDriveOrderSheet(editor: editor)
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if !state.hasCompletedStartup && state.activeConfiguration == nil {
            AppActivityLabel("正在恢复上次内容…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.activeConfiguration == nil {
            VStack(spacing: 18) {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: "尚未导入配置",
                    message: "前往“设置 → 点播配置”，通过 URL、粘贴内容或本地文件导入你有权使用的点播配置。"
                )
                Button {
                    state.selectedSettingsPane = .configurations
                    state.selectedSection = .settings
                } label: {
                    Label("打开点播配置设置", systemImage: "gearshape")
                }
            }
        } else if state.visibleSites.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.slash",
                    title: "没有可见站点",
                    message: "当前配置没有可用站点，或所有站点都被隐藏。"
                )
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let descriptor = state.activeCloudDriveDirectory {
            cloudDriveDirectory(descriptor)
        } else if let key = state.selectedSiteKey,
           state.siteCapability(for: key) == .unsupportedSpider {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "该站点暂不可用",
                message: "当前 Mac 版本暂时无法运行这个站点，请从工具栏选择其他站点。"
            )
        } else if let home = state.siteHome {
            if home.recommendations.isEmpty
                && mediaCategories.isEmpty
                && home.actionItems.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "站点没有返回可播放内容",
                    message: "可以刷新重试，或检查配置和站点状态。"
                )
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if state.isNativeMyDriveHome {
                                NativeMyDriveDashboard()
                            }
                            if !state.isNativeMyDriveHome
                                && (!home.recommendations.isEmpty
                                    || !mediaCategories.isEmpty) {
                                Text("分类")
                                    .font(.title2)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        if !home.recommendations.isEmpty {
                                            Button("推荐") {
                                                filterSelection = [:]
                                                state.clearCategory()
                                            }
                                            .buttonStyle(
                                                HomeCategoryButtonStyle(
                                                    isSelected:
                                                        state.homePresentationSelection
                                                        == .recommendation
                                                )
                                            )
                                        }
                                        ForEach(mediaCategories) { category in
                                            Button(category.name) {
                                                filterSelection = Dictionary(
                                                    uniqueKeysWithValues: category.filters.compactMap {
                                                        filter in
                                                        filter.options.first.map {
                                                            (filter.id, $0.value)
                                                        }
                                                    }
                                                )
                                                Task {
                                                    await state.loadCategory(
                                                        id: category.id,
                                                        filters: filterSelection
                                                    )
                                                }
                                            }
                                            .buttonStyle(
                                                HomeCategoryButtonStyle(
                                                    isSelected: state.selectedCategoryID == category.id
                                                )
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 8)
                                }
                            }
                            if !visibleHomeActionItems.isEmpty {
                                Text(state.isNativeMyDriveHome ? "高级操作" : "功能")
                                    .font(.title2)
                                LazyVGrid(
                                    columns: [
                                        GridItem(
                                            .adaptive(minimum: 240, maximum: 360),
                                            spacing: 12
                                        )
                                    ],
                                    alignment: .leading,
                                    spacing: 12
                                ) {
                                    ForEach(visibleHomeActionItems) { item in
                                        HomeActionCard(item: item) {
                                            Task {
                                                await state.performHomeAction(item)
                                            }
                                        }
                                        .disabled(state.isConfigurationInteractionActive)
                                    }
                                }
                            }
                            if let category = selectedCategory {
                                if !category.filters.isEmpty {
                                    filterControls(category)
                                }
                                Text(category.name)
                                    .font(.title2)
                                if let page = state.categoryPage {
                                    homeItemGrid(page.items)
                                    if page.pagination.hasMore {
                                        AutomaticPageLoader(
                                            isLoading: state.isLoadingNextCategoryPage,
                                            errorMessage: state.categoryPaginationError,
                                            viewportHeight: viewport.size.height,
                                            coordinateSpaceName: categoryScrollCoordinateSpace
                                        ) {
                                            Task {
                                                await state.loadCategory(
                                                    id: category.id,
                                                    page: page.pagination.page + 1,
                                                    filters: filterSelection
                                                )
                                            }
                                        }
                                        .id("\(category.id):\(page.pagination.page)")
                                    } else {
                                        PaginationCompletionFooter(
                                            itemCount: page.items.count
                                        )
                                    }
                                } else {
                                    AppActivityLabel("正在加载分类…")
                                }
                            } else if state.homePresentationSelection
                                == .recommendation,
                                !home.recommendations.isEmpty {
                                Text("推荐")
                                    .font(.title2)
                                homeItemGrid(home.recommendations)
                            }
                        }
                        .padding()
                    }
                    .coordinateSpace(name: categoryScrollCoordinateSpace)
                }
                .onAppear(perform: synchronizeFilterSelection)
                .onChange(of: state.selectedCategoryID) { _ in
                    synchronizeFilterSelection()
                }
            }
        } else if state.isHomeLoading || !state.hasCompletedStartup {
            AppActivityLabel("正在加载站点…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = state.homeLoadErrorMessage {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "站点暂时不可用",
                message: "已保留本地配置，可点击右上角刷新重试。\n\(message)"
            )
        } else {
            EmptyStateView(
                systemImage: "arrow.clockwise",
                title: "尚未加载",
                message: "选择站点或点击刷新。"
            )
        }
    }

    private var selectedCategory: VideoCategory? {
        guard let id = state.selectedCategoryID else { return nil }
        return mediaCategories.first { $0.id == id }
    }

    private var mediaCategories: [VideoCategory] {
        state.siteHome?.categories.filter {
            $0.resolvedContentKind == .media
        } ?? []
    }

    private var visibleHomeActionItems: [SiteActionItem] {
        let items = state.siteHome?.actionItems ?? []
        guard state.isNativeMyDriveHome else { return items }
        let representedIDs = Set(state.cloudDriveDescriptors.flatMap {
            [$0.loginAction?.id, $0.logoutAction?.id].compactMap { $0 }
        })
        return items.filter {
            !representedIDs.contains($0.id)
                && MyDriveGuardActionContract.nativeOrderKind(for: $0.action) == nil
        }
    }

    private func cloudDriveDirectory(
        _ descriptor: CloudDriveDescriptor
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Button {
                        state.closeCloudDriveDirectory()
                    } label: {
                        Label("返回我的网盘", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Divider().frame(height: 20)
                    Image(systemName: descriptor.systemImage)
                        .foregroundColor(.accentColor)
                    Text(descriptor.displayName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await state.retryCloudDriveDirectory() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isLoadingCloudDriveDirectory)
                }

                if state.isLoadingCloudDriveDirectory {
                    AppActivityLabel("正在连接 Spider 并加载根目录…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let error = state.cloudDriveDirectoryError {
                    EmptyStateView(
                        systemImage: "externaldrive.badge.exclamationmark",
                        title: "网盘目录暂不可用",
                        message: error
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else if let page = state.categoryPage {
                    if page.items.isEmpty {
                        EmptyStateView(
                            systemImage: "folder",
                            title: "目录为空",
                            message: "Spider 已响应，但没有返回可显示的文件或目录。"
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        homeItemGrid(page.items)
                    }
                }
            }
            .padding()
        }
    }

    private func synchronizeFilterSelection() {
        filterSelection = state.selectedCategoryFilters
    }

    @ViewBuilder
    private func homeItemGrid(_ items: [VideoSummary]) -> some View {
        let actionItems = items
            .filter { $0.resolvedContentKind == .action }
            .map(SiteActionItem.init(summary:))
        let mediaItems = items.filter { $0.resolvedContentKind == .media }

        if !actionItems.isEmpty {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(actionItems) { item in
                    HomeActionCard(item: item) {
                        Task { await state.performHomeAction(item) }
                    }
                    .disabled(state.isConfigurationInteractionActive)
                }
            }
        }

        if !mediaItems.isEmpty {
            if HomeItemPresentationPolicy.prefersCompactCards(mediaItems) {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(mediaItems) { summary in
                        HomeCompactItemCard(summary: summary) {
                            Task { await state.openHomeItem(summary) }
                        }
                    }
                }
            } else {
                VideoGrid(items: mediaItems) { summary in
                    Task { await state.openHomeItem(summary) }
                }
            }
        }
    }

    private func filterControls(_ category: VideoCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(category.filters) { filter in
                HStack {
                    Text(filter.name)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Picker(
                        filter.name,
                        selection: Binding(
                            get: { filterSelection[filter.id] ?? filter.options.first?.value ?? "" },
                            set: { value in
                                filterSelection[filter.id] = value
                                Task {
                                    await state.loadCategory(
                                        id: category.id,
                                        filters: filterSelection
                                    )
                                }
                            }
                        )
                    ) {
                        ForEach(filter.options) { option in
                            Text(option.name).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }
        }
    }
}

enum HomeToolbarLayout: Equatable, Sendable {
    case expanded
    case compact
    case minimal

    var sitePickerWidth: CGFloat {
        switch self {
        case .expanded: return 210
        case .compact: return 150
        case .minimal: return 0
        }
    }

    var searchFieldWidth: CGFloat {
        switch self {
        case .expanded: return 280
        case .compact: return 190
        case .minimal: return 0
        }
    }
}

enum HomeToolbarLayoutPolicy {
    static func layout(contentWidth: CGFloat) -> HomeToolbarLayout {
        if contentWidth >= 900 { return .expanded }
        if contentWidth >= 650 { return .compact }
        return .minimal
    }
}

struct HomeSiteToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    var body: some View {
        if !state.visibleSites.isEmpty {
            switch layout {
            case .expanded, .compact:
                Picker("站点", selection: selection) {
                    ForEach(state.visibleSites) { site in
                        Text(displayName(for: site))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(site.key)
                    }
                }
                .labelsHidden()
                .frame(width: layout.sitePickerWidth)
                .help(siteHelp)
                .accessibilityLabel("选择内容站点")

            case .minimal:
                Menu {
                    ForEach(state.visibleSites) { site in
                        Button {
                            Task { await state.selectSite(site.key) }
                        } label: {
                            if state.selectedSiteKey == site.key {
                                Label(displayName(for: site), systemImage: "checkmark")
                            } else {
                                Text(displayName(for: site))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(siteHelp)
                .accessibilityLabel("选择内容站点")
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { state.selectedSiteKey ?? "" },
            set: { key in Task { await state.selectSite(key) } }
        )
    }

    private var siteHelp: String {
        let currentName = state.currentSite.map(displayName(for:)) ?? "未选择"
        return "当前站点：\(currentName)，共 \(state.visibleSites.count) 个"
    }

    private func displayName(for site: SiteConfiguration) -> String {
        HomeSitePresentation.displayName(
            siteName: site.name,
            capability: state.siteCapability(for: site.key)
        )
    }
}

struct HomeSearchToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    @State private var showingCompactSearch = false
    @State private var compactFocusRequest: UInt64 = 0

    var body: some View {
        Group {
            if layout == .minimal {
                Button {
                    compactFocusRequest &+= 1
                    showingCompactSearch = true
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .help("搜索全部站点（⌘F）")
                .accessibilityLabel("搜索全部站点")
                .disabled(state.visibleSites.isEmpty)
                .popover(isPresented: $showingCompactSearch, arrowEdge: .top) {
                    HomeToolbarSearchField(
                        text: $state.searchKeyword,
                        focusRequest: state.homeToolbarSearchFocusRequest
                            &+ compactFocusRequest,
                        onSubmit: performSearch
                    )
                    .frame(width: 280, height: 28)
                    .padding(14)
                }
            } else {
                HomeToolbarSearchField(
                    text: $state.searchKeyword,
                    focusRequest: state.homeToolbarSearchFocusRequest,
                    onSubmit: performSearch
                )
                .frame(width: layout.searchFieldWidth, height: 28)
                .disabled(state.visibleSites.isEmpty)
                .help("搜索全部站点，按 Return 开始（⌘F 聚焦）")
            }
        }
        .onChange(of: state.homeToolbarSearchFocusRequest) { _ in
            if layout == .minimal {
                compactFocusRequest &+= 1
                showingCompactSearch = true
            }
        }
        .onChange(of: layout) { newLayout in
            if newLayout != .minimal {
                showingCompactSearch = false
            }
        }
    }

    private func performSearch() {
        let keyword = state.searchKeyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        showingCompactSearch = false
        state.searchFromHome(keyword)
    }
}

private struct HomeToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt64
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索全部站点"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setAccessibilityLabel("搜索全部站点")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        guard focusRequest > 0,
              context.coordinator.lastFocusRequest != focusRequest else {
            return
        }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: HomeToolbarSearchField
        var lastFocusRequest: UInt64 = 0

        init(_ parent: HomeToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

struct HomeConfigurationToolbarItem: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if !state.configurations.isEmpty {
            Menu {
                ForEach(state.configurations) { record in
                    Button {
                        Task { await state.activateConfiguration(record.id) }
                    } label: {
                        if state.configurationMenuSelectionID == record.id {
                            Label(record.name, systemImage: "checkmark")
                        } else {
                            Text(record.name)
                        }
                    }
                    .disabled(
                        state.activeConfigurationRecord?.id == record.id
                            && !state.isSwitchingConfiguration
                    )
                }
            } label: {
                configurationStatusIcon
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(configurationStatusHelp)
            .accessibilityLabel(configurationStatusHelp)
        }
    }

    @ViewBuilder
    private var configurationStatusIcon: some View {
        switch state.configurationSwitchFeedback {
        case .switching:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .idle:
            Image(systemName: "play.rectangle.on.rectangle")
                .foregroundColor(.secondary)
        }
    }

    private var configurationStatusHelp: String {
        switch state.configurationSwitchFeedback {
        case .switching(_, let name):
            return "正在切换到 \(name)"
        case .success(_, let name):
            return "已切换到 \(name)"
        case .failure(_, let name, let message):
            return "切换到 \(name) 失败：\(message)"
        case .idle:
            return "切换点播配置"
        }
    }
}

struct HomeRefreshToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    var body: some View {
        Button {
            Task { await state.refreshHome() }
        } label: {
            if state.isLoading || state.isHomeLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("刷新", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
        }
        .disabled(state.currentSite == nil || state.isHomeLoading)
        .help(layout == .minimal ? "刷新当前站点（⌘R，可能收入更多菜单）" : "刷新当前站点（⌘R）")
        .accessibilityLabel(state.isHomeLoading ? "正在刷新当前站点" : "刷新当前站点")
    }
}

struct SourceSwitchFeedbackView: View {
    let feedback: ConfigurationSwitchFeedback
    var compact = false

    var body: some View {
        Group {
            switch feedback {
            case .idle:
                EmptyView()
            case .switching(_, let name):
                HStack(spacing: 5) {
                    AppActivityIndicator(size: .small)
                    Text("正在切换到 \(name)…")
                }
                .accessibilityLabel("正在切换到 \(name)")
            case .success(_, let name):
                if compact {
                    Label("已切换", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .help("已切换到 \(name)")
                        .accessibilityLabel(Text("已切换到 \(name)"))
                } else {
                    Label(
                        "已切换到 \(name)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundColor(.green)
                }
            case .failure(_, let name, let message):
                if compact {
                    Label(
                        "切换失败",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(.red)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .help("切换到 \(name) 失败：\(message)")
                    .accessibilityLabel(
                        Text("切换到 \(name) 失败：\(message)")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            "切换 \(name) 失败",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(.red)
                        Text(message)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: compact ? 190 : nil, alignment: .leading)
    }
}

private struct NativeMyDriveDashboard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的网盘")
                        .font(.title2)
                    Text("账号授权与目录可用性分开显示")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.refreshMyDriveDirectory() }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(state.isRefreshingMyDriveDirectory)
                Button {
                    state.presentNativeMyDriveOrderEditor(.cloudProviders)
                } label: {
                    Label("网盘优先级", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    state.presentNativeMyDriveOrderEditor(.playbackSources)
                } label: {
                    Label("播放线路优先级", systemImage: "list.number")
                }
            }

            if let message = state.myDriveDirectoryStatusMessage {
                HStack(spacing: 8) {
                    if state.isRefreshingMyDriveDirectory {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                    }
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(state.cloudDriveDescriptors) { account in
                    NativeMyDriveAccountCard(account: account)
                }
            }
        }
    }
}

private struct NativeMyDriveAccountCard: View {
    @EnvironmentObject private var state: AppState
    let account: CloudDriveDescriptor
    @State private var confirmsLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: account.systemImage)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        statusBadge(
                            account.authorizationText,
                            active: account.authorizationStatus == .authenticated
                        )
                        statusBadge(
                            account.canBrowse ? "可浏览" : "暂不可浏览",
                            active: account.canBrowse
                        )
                    }
                }
                Spacer()
                Menu {
                    Button("退出登录", role: .destructive) {
                        confirmsLogout = true
                    }
                    .disabled(
                        account.authorizationStatus == .unauthenticated
                            || account.logoutAction == nil
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(account.availabilityText)
                .font(.callout)
                .foregroundColor(account.canBrowse ? .secondary : .orange)

            HStack {
                if account.canBrowse {
                    Button("进入网盘") {
                        Task { await state.openCloudDrive(account) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(
                    account.authorizationStatus == .authenticated
                        ? "重新授权"
                        : "登录"
                ) {
                    Task { await state.authorizeCloudDrive(account) }
                }
                .disabled(account.loginAction == nil)
                Spacer()
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .alert("退出\(account.displayName)？", isPresented: $confirmsLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                Task { await state.logoutCloudDrive(account) }
            }
        } message: {
            Text("将由 Spider 删除该网盘的本地授权信息。")
        }
    }

    private func statusBadge(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundColor(active ? .green : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((active ? Color.green : Color.secondary).opacity(0.1))
            .clipShape(Capsule())
    }
}

private struct NativeMyDriveOrderSheet: View {
    @EnvironmentObject private var state: AppState
    let editor: NativeMyDriveOrderEditor
    @State private var items: [NativeMyDriveOrderItem]

    init(editor: NativeMyDriveOrderEditor) {
        self.editor = editor
        _items = State(initialValue: editor.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(editor.title)
                    .font(.title2.weight(.semibold))
                Text(editor.subtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                        Text(item.title)
                        Spacer()
                        Button {
                            move(index: index, offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("上移\(item.title)")
                        Button {
                            move(index: index, offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == items.count - 1)
                        .help("下移\(item.title)")
                    }
                    .padding(.vertical, 5)
                }
                .onMove { source, destination in
                    items.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)

            HStack {
                Button("恢复默认") {
                    restoreDefaultOrder()
                }
                Spacer()
                Button("取消") {
                    state.dismissNativeMyDriveOrderEditor()
                }
                Button("保存") {
                    Task {
                        await state.saveNativeMyDriveOrder(
                            kind: editor.kind,
                            items: items
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }

    private func move(index: Int, offset: Int) {
        let destination = index + offset
        guard items.indices.contains(index),
              items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
    }

    private func restoreDefaultOrder() {
        let defaults: [String]
        switch editor.kind {
        case .cloudProviders:
            defaults = state.cloudDriveDescriptors.map(\.id)
        case .playbackSources:
            defaults = ["original", "unlimited", "smart"]
        }
        let order = NativeMyDrivePreferenceStore.reconciledOrder(
            preferred: defaults,
            available: items.map(\.id)
        )
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = order.compactMap { byID[$0] }
    }
}

private struct HomeActionCard: View {
    let item: SiteActionItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let remarks = item.remarks,
                       !remarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(remarks)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("功能操作")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("功能：\(item.title)")
    }
}

enum HomeItemPresentationPolicy {
    /// A provider that supplies no artwork should not produce a wall of fake
    /// poster placeholders. This is presentation-only: the provider remains
    /// the semantic owner of whether an item is media or an action.
    static func prefersCompactCards(_ items: [VideoSummary]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.posterURL == nil }
    }
}

private struct HomeCompactItemCard: View {
    let summary: VideoSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: summary.isFolder ? "folder" : "rectangle.stack")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    if let remarks = summary.remarks?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !remarks.isEmpty {
                        Text(remarks)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(summary.isFolder ? "目录" : "内容入口")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.title)
    }
}

enum HomeSitePresentation {
    static func displayName(
        siteName: String,
        capability: SiteCapability?
    ) -> String {
        capability == .unsupportedSpider
            ? "\(siteName)（暂不可用）"
            : siteName
    }
}

private struct HomeCategoryButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HomeCategoryButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct HomeCategoryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let highlighted = isHovering && !configuration.isPressed
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color.accentColor
                        .opacity(configuration.isPressed ? 0.78 : 1)
                    : highlighted
                        ? Color.accentColor.opacity(0.075)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.86)
            )
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        highlighted
                            ? Color.accentColor.opacity(0.30)
                            : isSelected
                                ? Color.white.opacity(isHovering ? 0.18 : 0)
                                : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            }
            .scaleEffect(
                configuration.isPressed ? 0.97 : (isHovering ? 1.012 : 1)
            )
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(isHovering ? 0.12 : 0)
                    : Color.black.opacity(isHovering ? 0.055 : 0),
                radius: isHovering ? 4 : 0,
                y: isHovering ? 1 : 0
            )
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
