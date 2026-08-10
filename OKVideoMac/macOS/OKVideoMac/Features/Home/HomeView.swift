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
    }

    @ViewBuilder
    private var homeContent: some View {
        if !state.hasCompletedStartup && state.activeConfiguration == nil {
            ProgressView("正在恢复上次内容…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.activeConfiguration == nil {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: "尚未导入配置",
                    message: "前往“设置 > 点播配置”导入你有权使用的 FongMi JSON 配置。"
                )
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
        if let key = state.selectedSiteKey,
           state.siteCapability(for: key) == .unsupportedSpider {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "该站点暂不可用",
                message: "当前 Mac 版本暂时无法运行这个站点，请从工具栏选择其他站点。"
            )
        } else if let home = state.siteHome {
            if home.recommendations.isEmpty && home.categories.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "站点没有返回内容",
                    message: "可以刷新重试，或检查配置和站点状态。"
                )
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if !home.categories.isEmpty {
                                Text("分类")
                                    .font(.title2)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        Button("推荐") {
                                            filterSelection = [:]
                                            state.clearCategory()
                                        }
                                        .buttonStyle(
                                            HomeCategoryButtonStyle(
                                                isSelected: state.selectedCategoryID == nil
                                            )
                                        )
                                        ForEach(home.categories) { category in
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
                            if let category = selectedCategory {
                                if !category.filters.isEmpty {
                                    filterControls(category)
                                }
                                Text(category.name)
                                    .font(.title2)
                                if let page = state.categoryPage {
                                    VideoGrid(items: page.items) { summary in
                                        Task { await state.loadDetail(summary) }
                                    }
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
                                    ProgressView("正在加载分类…")
                                }
                            } else if !home.recommendations.isEmpty {
                                Text("推荐")
                                    .font(.title2)
                                VideoGrid(items: home.recommendations) { summary in
                                    Task { await state.loadDetail(summary) }
                                }
                            }
                        }
                        .padding()
                    }
                    .coordinateSpace(name: categoryScrollCoordinateSpace)
                }
            }
        } else if state.isHomeLoading || !state.hasCompletedStartup {
            ProgressView("正在加载站点…")
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
        return state.siteHome?.categories.first { $0.id == id }
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

struct HomeToolbarView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        if !state.isHomeSearchPresented,
           state.activeConfiguration != nil,
           !state.visibleSites.isEmpty {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .foregroundColor(.secondary)
                    Picker(
                        "站点",
                        selection: Binding(
                            get: { state.selectedSiteKey ?? "" },
                            set: { key in
                                Task { await state.selectSite(key) }
                            }
                        )
                    ) {
                        ForEach(state.visibleSites) { site in
                            Text(
                                HomeSitePresentation.displayName(
                                    siteName: site.name,
                                    capability: state.siteCapability(for: site.key)
                                )
                            )
                            .tag(site.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                .help("选择内容站点，共 \(state.visibleSites.count) 个")

                TextField("搜索全部站点", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .onSubmit(performSearch)
                    .frame(minWidth: 190, idealWidth: 280, maxWidth: 360)

                Button(action: performSearch) {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(
                    state.searchKeyword
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )

                if state.isLoading || state.isHomeLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await state.refreshHome() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(state.currentSite == nil)
            }
        }
    }

    private func performSearch() {
        let keyword = state.searchKeyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            isSearchFieldFocused = true
            return
        }
        state.searchFromHome(keyword)
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
