import SwiftUI
import OKVideoCore

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var filterSelection: [String: String] = [:]
    @FocusState private var isSearchFieldFocused: Bool
    private let categoryScrollCoordinateSpace = "home-category-scroll"

    var body: some View {
        Group {
            if state.isHomeSearchPresented {
                SearchView()
            } else {
                VStack(spacing: 0) {
                    homeSearchBar
                    Divider()
                    homeContent
                }
            }
        }
        .navigationTitle("首页")
        .background(AppSurfacePalette.background.ignoresSafeArea())
    }

    private var homeSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索所有已启用站点", text: $state.searchKeyword)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit(performSearch)
                if !state.searchKeyword.isEmpty {
                    Button {
                        state.searchKeyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: 520, minHeight: 34)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22))
            }

            Button("搜索", action: performSearch)
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.activeConfiguration == nil
                        || state.searchKeyword
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )

            Text("跨站搜索")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppSurfacePalette.background)
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
                VStack(spacing: 0) {
                    sitePicker
                    Divider()
                    content
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

    private var sitePicker: some View {
        HStack {
            Text("站点")
                .foregroundColor(.secondary)
            Picker(
                "站点",
                selection: Binding(
                    get: { state.selectedSiteKey ?? "" },
                    set: { key in Task { await state.selectSite(key) } }
                )
            ) {
                ForEach(state.visibleSites) { site in
                    Text(siteLabel(site)).tag(site.key)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer()
            Text("\(state.visibleSites.count) 个站点 · \(state.supportedSites.count) 个当前可运行")
                .font(.caption)
                .foregroundColor(.secondary)
            if let count = state.siteHome?.recommendations.count {
                Text("\(count) 项")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private func siteLabel(_ site: SiteConfiguration) -> String {
        switch state.siteCapability(for: site.key) {
        case .javaScriptSpider:
            return "\(site.name) · JavaScript"
        case .javaDexSpider:
            return "\(site.name) · Java/Dex"
        case .standardXML:
            return "\(site.name) · XML"
        case .standardJSON:
            return "\(site.name) · JSON"
        case .base64JSON:
            return "\(site.name) · T4"
        case .unsupportedSpider:
            return "\(site.name) · Java/Dex（暂未实现）"
        case .none:
            return "\(site.name) · 未知"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let key = state.selectedSiteKey,
           state.siteCapability(for: key) == .unsupportedSpider {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "该站点需要 Java/Dex Spider",
                message: "站点已完整保留并显示，但当前原生 Mac 版本尚未实现 Android 的 Java/Dex 运行时。请选择标有“JavaScript”的站点。"
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
                                        .buttonStyle(.bordered)
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
                                            .buttonStyle(.bordered)
                                            .tint(
                                                state.selectedCategoryID == category.id
                                                    ? .accentColor
                                                    : .secondary
                                            )
                                        }
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
