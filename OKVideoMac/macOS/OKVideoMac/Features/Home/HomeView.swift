import AppKit
import SwiftUI
import OKVideoCore

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var filterSelection: [String: String] = [:]
    @State private var filterLoadTask: Task<Void, Never>?
    private let categoryScrollCoordinateSpace = "home-category-scroll"

    var body: some View {
        Group {
            if state.isHomeSearchPresented {
                SearchView()
            } else {
                homeContent
            }
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
                    state.selectSection(.settings)
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
        if let key = state.selectedSiteKey,
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
            } else if state.homePresentationNeedsRecovery {
                homeRecoveryContent
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        BrowserToolbarScrollMarker(
                            coordinateSpaceName: categoryScrollCoordinateSpace
                        )
                        VStack(alignment: .leading, spacing: 20) {
                            if !home.recommendations.isEmpty
                                || !mediaCategories.isEmpty {
                                VStack(spacing: 0) {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: HomeBrowseGridMetrics.categorySpacing) {
                                            if !home.recommendations.isEmpty {
                                                Button("推荐") {
                                                    filterLoadTask?.cancel()
                                                    filterSelection = [:]
                                                    state.clearCategory()
                                                }
                                                .buttonStyle(
                                                    BrowseNavigationButtonStyle(
                                                        isSelected:
                                                            state.homePresentationSelection
                                                            == .recommendation
                                                    )
                                                )
                                            }
                                            ForEach(mediaCategories) { category in
                                                Button(category.name) {
                                                    filterLoadTask?.cancel()
                                                    filterSelection =
                                                        HomeFilterPresentationPolicy
                                                        .defaultSelection(
                                                            filters: category.filters
                                                        )
                                                    Task {
                                                        await state.loadCategory(
                                                            id: category.id,
                                                            filters: filterSelection
                                                        )
                                                    }
                                                }
                                                .buttonStyle(
                                                    BrowseNavigationButtonStyle(
                                                        isSelected:
                                                            state.selectedCategoryID
                                                            == category.id
                                                    )
                                                )
                                            }
                                        }
                                        .padding(
                                            .leading,
                                            HomeBrowseGridMetrics.categoryLeadingInset
                                        )
                                        .padding(.trailing, 8)
                                        .padding(
                                            .vertical,
                                            HomeBrowseGridMetrics.categoryVerticalPadding
                                        )
                                    }
                                    Divider()
                                }
                            }
                            if !home.actionItems.isEmpty {
                                Text("功能")
                                    .font(.title2)
                                    .padding(
                                        .leading,
                                        HomeContentAlignment.visualLeadingInset
                                    )
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
                                    ForEach(home.actionItems) { item in
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
                                let activeFilters =
                                    HomeFilterPresentationPolicy.activeTokens(
                                        filters: category.filters,
                                        selection: filterSelection
                                    )
                                if !activeFilters.isEmpty {
                                    activeFilterBar(
                                        category: category,
                                        tokens: activeFilters
                                    )
                                }
                                if state.isLoading,
                                   state.categoryPage != nil {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("正在更新…")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(
                                        .leading,
                                        HomeContentAlignment.visualLeadingInset
                                    )
                                }
                                if let page = state.categoryPage {
                                    homeItemGrid(page.items)
                                    if page.pagination.hasMore,
                                       !state.isLoading {
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
                                } else if state.isLoading
                                    || state.isRecoveringHome {
                                    AppActivityLabel("正在加载分类…")
                                } else if let message = state.homeLoadErrorMessage {
                                    categoryRecoveryError(
                                        message: message
                                    )
                                } else {
                                    AppActivityLabel("正在加载分类…")
                                        .task {
                                            await state.resumeHomeIfNeeded()
                                        }
                                }
                            } else if state.homePresentationSelection
                                == .recommendation,
                                !home.recommendations.isEmpty {
                                homeItemGrid(home.recommendations)
                            }
                        }
                        .padding(
                            .horizontal,
                            HomeBrowseGridMetrics.contentPadding
                        )
                        // The ScrollView extends behind the unified titlebar
                        // so posters can participate in the native material
                        // blur while scrolling. This scrollable inset keeps
                        // the category row in its original resting position.
                        .padding(.top, BrowserToolbarMetrics.height)
                        .padding(.bottom, HomeBrowseGridMetrics.contentPadding)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .browserToolbarScrollSurface(
                        named: categoryScrollCoordinateSpace
                    )
                }
                .onAppear(perform: synchronizeFilterSelection)
                .onChange(of: state.selectedCategoryID) { _ in
                    filterLoadTask?.cancel()
                    synchronizeFilterSelection()
                }
                .onChange(of: state.selectedCategoryFilters) { _ in
                    synchronizeFilterSelection()
                }
                .onDisappear {
                    filterLoadTask?.cancel()
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

    @ViewBuilder
    private var homeRecoveryContent: some View {
        if state.isRecoveringHome || state.isHomeLoading || state.isLoading {
            AppActivityLabel("正在恢复首页…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = state.homeLoadErrorMessage {
            VStack(spacing: 14) {
                EmptyStateView(
                    systemImage: "arrow.clockwise.circle",
                    title: "首页状态需要恢复",
                    message: message
                )
                Button("重试") {
                    Task {
                        await state.resumeHomeIfNeeded(reportErrors: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AppActivityLabel("正在恢复首页…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await state.resumeHomeIfNeeded()
                }
        }
    }

    private func categoryRecoveryError(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分类加载失败", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task {
                    await state.resumeHomeIfNeeded(reportErrors: true)
                }
            }
        }
        .padding(.vertical, 8)
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

    private func activeFilterBar(
        category: VideoCategory,
        tokens: [HomeActiveFilterToken]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tokens) { token in
                    Button {
                        let selection =
                            HomeFilterPresentationPolicy.resetting(
                                filterID: token.filterID,
                                filters: category.filters,
                                selection: filterSelection
                            )
                        filterSelection = selection
                        scheduleFilterLoad(
                            categoryID: category.id,
                            filters: selection
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(token.filterName)：\(token.optionName)")
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("移除筛选：\(token.filterName)，\(token.optionName)")
                }

                Button("清除筛选") {
                    let selection =
                        HomeFilterPresentationPolicy.defaultSelection(
                            filters: category.filters
                        )
                    filterSelection = selection
                    scheduleFilterLoad(
                        categoryID: category.id,
                        filters: selection
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.leading, HomeContentAlignment.visualLeadingInset)
            .padding(.trailing, 8)
        }
    }

    private func scheduleFilterLoad(
        categoryID: String,
        filters: [String: String]
    ) {
        filterLoadTask?.cancel()
        state.stageCategoryFilters(id: categoryID, filters: filters)
        filterLoadTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state.selectedCategoryID == categoryID else {
                return
            }
            await state.loadCategory(id: categoryID, filters: filters)
        }
    }
}

private enum HomeContentAlignment {
    static let visualLeadingInset: CGFloat = 8
}

/// One shared horizontal rhythm for the category strip, filter rows, and card
/// grid. The filter labels stay on the cards' visible leading edge while every
/// category cell starts on the same column as its corresponding filter chip.
enum HomeBrowseGridMetrics {
    static let contentPadding: CGFloat = 16
    // The navigation is one quiet, coherent strip rather than a run of
    // individual pills. A wider inter-item rhythm lets dynamic labels read as
    // columns while the strip can still scroll for long provider lists.
    static let categorySpacing: CGFloat = 32
    // 32-point labels plus 10 points above and below reproduce the reference
    // navigation strip's relaxed 52-point height.
    static let categoryVerticalPadding: CGFloat = 10
    static let labelWidth: CGFloat = 54
    static let labelContentSpacing: CGFloat = 10
    static let chipWidth: CGFloat = 78
    static let chipHeight: CGFloat = 28
    static let columnSpacing: CGFloat = 7
    static let cellTextInset: CGFloat = 9
    static let cellTextWidth = chipWidth - cellTextInset * 2

    static let optionLeadingInset = labelWidth + labelContentSpacing
    // VideoCard reserves eight points around the visible poster. Starting the
    // category strip at the same inset keeps navigation, active filters, and
    // the first poster on one optical baseline.
    static let categoryLeadingInset = HomeContentAlignment.visualLeadingInset
}

struct HomeActiveFilterToken: Equatable, Identifiable, Sendable {
    let filterID: String
    let filterName: String
    let optionName: String
    let value: String
    let defaultValue: String

    var id: String { filterID }
}

/// Presentation-only helpers for dynamic provider filters. The first option in
/// each provider-defined dimension is its default; labels are never inspected
/// or hard-coded.
enum HomeFilterPresentationPolicy {
    static func defaultSelection(
        filters: [VideoFilter]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: filters.compactMap { filter in
                filter.options.first.map { (filter.id, $0.value) }
            }
        )
    }

    static func normalizedSelection(
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: filters.compactMap { filter in
                guard let defaultOption = filter.options.first else {
                    return nil
                }
                let value = selection[filter.id].flatMap { selectedValue in
                    filter.options.first { $0.value == selectedValue }?.value
                } ?? defaultOption.value
                return (filter.id, value)
            }
        )
    }

    static func activeTokens(
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [HomeActiveFilterToken] {
        filters.compactMap { filter in
            guard let defaultOption = filter.options.first,
                  let selectedValue = selection[filter.id],
                  selectedValue != defaultOption.value,
                  let selectedOption = filter.options.first(where: {
                      $0.value == selectedValue
                  }) else {
                return nil
            }
            return HomeActiveFilterToken(
                filterID: filter.id,
                filterName: filter.name,
                optionName: selectedOption.name,
                value: selectedOption.value,
                defaultValue: defaultOption.value
            )
        }
    }

    static func resetting(
        filterID: String,
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [String: String] {
        var result = normalizedSelection(
            filters: filters,
            selection: selection
        )
        if let defaultValue = filters
            .first(where: { $0.id == filterID })?
            .options.first?.value {
            result[filterID] = defaultValue
        }
        return result
    }
}

struct FilterOptionVisibility: Equatable {
    let visibleValues: [String]
    let hiddenValues: [String]
}

enum FilterOverflowLayoutPolicy {
    static let chipSpacing = HomeBrowseGridMetrics.columnSpacing
    static let uniformChipWidth = HomeBrowseGridMetrics.chipWidth

    static func visibility(
        options: [VideoFilterOption],
        selectedValue: String?,
        availableWidth: CGFloat
    ) -> FilterOptionVisibility {
        visibility(
            options: options,
            selectedValue: selectedValue,
            columnCapacity: columnCapacity(availableWidth: availableWidth)
        )
    }

    static func visibility(
        options: [VideoFilterOption],
        selectedValue: String?,
        columnCapacity: Int
    ) -> FilterOptionVisibility {
        guard !options.isEmpty else {
            return FilterOptionVisibility(
                visibleValues: [],
                hiddenValues: []
            )
        }
        let capacity = max(1, columnCapacity)
        if options.count <= capacity {
            return FilterOptionVisibility(
                visibleValues: options.map(\.value),
                hiddenValues: []
            )
        }

        let selectedIndex = options.firstIndex {
            $0.value == selectedValue
        } ?? 0
        // One cell belongs to the adjacent overflow button. In the normal
        // expanded layout at least two option cells remain, so both "全部"
        // and an overflow selection stay visible. For pathological widths a
        // single cell favors the active selection rather than hiding state.
        let visibleSlotCount = max(1, capacity - 1)
        var selectedIndices = Set<Int>()
        if visibleSlotCount == 1 {
            selectedIndices.insert(selectedIndex)
        } else {
            selectedIndices.insert(options.startIndex)
            selectedIndices.insert(selectedIndex)
        }
        for index in options.indices where selectedIndices.count < visibleSlotCount {
            selectedIndices.insert(index)
        }

        let visible = options.indices.filter(selectedIndices.contains)
        let hidden = options.indices.filter { !selectedIndices.contains($0) }
        return FilterOptionVisibility(
            visibleValues: visible.map { options[$0].value },
            hiddenValues: hidden.map { options[$0].value }
        )
    }

    static func chipWidth(title _: String) -> CGFloat {
        uniformChipWidth
    }

    static func columnCapacity(availableWidth: CGFloat) -> Int {
        guard availableWidth >= uniformChipWidth else { return 1 }
        return max(
            1,
            Int(
                floor(
                    (availableWidth + chipSpacing)
                        / (uniformChipWidth + chipSpacing)
                )
            )
        )
    }
}

private struct AdaptiveFilterPanel: View {
    let filters: [VideoFilter]
    @Binding var selection: [String: String]
    let availableWidth: CGFloat
    let onSelectionChanged: ([String: String]) -> Void

    private var usesCompactLayout: Bool {
        availableWidth < 560
    }

    private var optionColumnCapacity: Int {
        let optionWidth = max(
            FilterOverflowLayoutPolicy.uniformChipWidth,
            availableWidth - AdaptiveFilterLayoutMetrics.contentLeadingInset
        )
        return FilterOverflowLayoutPolicy.columnCapacity(
            availableWidth: optionWidth
        )
    }

    private var defaultSelection: [String: String] {
        Dictionary(
            uniqueKeysWithValues: filters.compactMap { filter in
                filter.options.first.map { (filter.id, $0.value) }
            }
        )
    }

    private var hasCustomSelection: Bool {
        filters.contains { filter in
            guard let defaultValue = filter.options.first?.value else {
                return false
            }
            return resolvedValue(for: filter) != defaultValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(filters) { filter in
                AdaptiveFilterRow(
                    filter: filter,
                    selectedValue: resolvedValue(for: filter),
                    usesCompactLayout: usesCompactLayout,
                    columnCapacity: optionColumnCapacity
                ) { value in
                    apply(value: value, to: filter)
                }
                .equatable()
            }

            HStack {
                Spacer()
                Button {
                    let defaults = defaultSelection
                    selection = defaults
                    onSelectionChanged(defaults)
                } label: {
                    Label("重置筛选", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .opacity(hasCustomSelection ? 1 : 0)
                .disabled(!hasCustomSelection)
                .accessibilityHidden(!hasCustomSelection)
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolvedValue(for filter: VideoFilter) -> String {
        selection[filter.id] ?? filter.options.first?.value ?? ""
    }

    private func apply(value: String, to filter: VideoFilter) {
        guard resolvedValue(for: filter) != value else { return }
        selection[filter.id] = value
        onSelectionChanged(selection)
    }
}

private enum AdaptiveFilterLayoutMetrics {
    static let labelWidth = HomeBrowseGridMetrics.labelWidth
    static let labelContentSpacing = HomeBrowseGridMetrics.labelContentSpacing
    static let contentLeadingInset = HomeBrowseGridMetrics.optionLeadingInset
}

private struct AdaptiveFilterRow: View, Equatable {
    let filter: VideoFilter
    let selectedValue: String
    let usesCompactLayout: Bool
    let columnCapacity: Int
    let onSelect: (String) -> Void

    @State private var isOverflowPresented = false
    @State private var overflowSearchText = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filter == rhs.filter
            && lhs.selectedValue == rhs.selectedValue
            && lhs.usesCompactLayout == rhs.usesCompactLayout
            && lhs.columnCapacity == rhs.columnCapacity
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                compactRow
            } else {
                expandedRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(filter.name)
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            filterLabel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FilterOverflowLayoutPolicy.chipSpacing) {
                    ForEach(filter.options) { option in
                        optionButton(option)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var expandedRow: some View {
        let visibility = FilterOverflowLayoutPolicy.visibility(
            options: filter.options,
            selectedValue: selectedValue,
            columnCapacity: columnCapacity
        )
        let visibleOptions = options(for: visibility.visibleValues)
        let hiddenOptions = options(for: visibility.hiddenValues)

        return HStack(spacing: AdaptiveFilterLayoutMetrics.labelContentSpacing) {
            filterLabel
                .frame(
                    width: AdaptiveFilterLayoutMetrics.labelWidth,
                    alignment: .leading
                )
            HStack(spacing: FilterOverflowLayoutPolicy.chipSpacing) {
                ForEach(visibleOptions) { option in
                    optionButton(option)
                }
                if !hiddenOptions.isEmpty {
                    Button {
                        isOverflowPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("更多 \(hiddenOptions.count)")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(FilterChipButtonStyle(isSelected: false))
                    .help("显示“\(filter.name)”的其余 \(hiddenOptions.count) 个选项")
                    .accessibilityLabel("\(filter.name)更多选项，共 \(hiddenOptions.count) 项")
                    .popover(
                        isPresented: $isOverflowPresented,
                        arrowEdge: .bottom
                    ) {
                        FilterOverflowPopover(
                            filterName: filter.name,
                            options: hiddenOptions,
                            selectedValue: selectedValue,
                            searchText: $overflowSearchText
                        ) { value in
                            onSelect(value)
                            isOverflowPresented = false
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }

    private var filterLabel: some View {
        Text(filter.name)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    private func options(for values: [String]) -> [VideoFilterOption] {
        let included = Set(values)
        return filter.options.filter { included.contains($0.value) }
    }

    private func optionButton(_ option: VideoFilterOption) -> some View {
        Button(option.name) {
            onSelect(option.value)
        }
        .buttonStyle(
            FilterChipButtonStyle(isSelected: option.value == selectedValue)
        )
        .help("\(filter.name)：\(option.name)")
        .accessibilityLabel("\(filter.name)，\(option.name)")
        .accessibilityAddTraits(
            option.value == selectedValue ? .isSelected : []
        )
    }
}

private struct FilterOverflowPopover: View {
    let filterName: String
    let options: [VideoFilterOption]
    let selectedValue: String
    @Binding var searchText: String
    let onSelect: (String) -> Void

    private var filteredOptions: [VideoFilterOption] {
        let keyword = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !keyword.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(filterName)
                .font(.headline)
            if options.count > 20 {
                TextField("搜索\(filterName)选项", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                if filteredOptions.isEmpty {
                    Text("没有匹配选项")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 76, maximum: 150),
                                spacing: 8
                            )
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(filteredOptions) { option in
                            Button(option.name) {
                                onSelect(option.value)
                            }
                            .buttonStyle(
                                FilterChipButtonStyle(
                                    isSelected: option.value == selectedValue
                                )
                            )
                            .accessibilityLabel("\(filterName)，\(option.name)")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: options.count > 20 ? 330 : 250)
        .onDisappear {
            searchText = ""
        }
    }
}

private struct FilterChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        FilterChipButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct FilterChipButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(
                width: HomeBrowseGridMetrics.cellTextWidth,
                alignment: .leading
            )
            .frame(
                width: HomeBrowseGridMetrics.chipWidth,
                height: HomeBrowseGridMetrics.chipHeight,
                alignment: .center
            )
            .background(
                isSelected
                    ? Color.primary.opacity(configuration.isPressed ? 0.16 : 0.12)
                    : Color.secondary.opacity(isHovering ? 0.16 : 0.10)
            )
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(
                    isSelected
                        ? Color.primary.opacity(isHovering ? 0.24 : 0.14)
                        : Color.secondary.opacity(isHovering ? 0.28 : 0.14),
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
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
                .controlSize(.large)
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

struct HomeFilterToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    @State private var isPresented = false
    @State private var filterLoadTask: Task<Void, Never>?

    private var category: VideoCategory? {
        guard let categoryID = state.selectedCategoryID else { return nil }
        return state.siteHome?.categories.first {
            $0.id == categoryID && $0.resolvedContentKind == .media
        }
    }

    private var activeCount: Int {
        guard let category else { return 0 }
        return HomeFilterPresentationPolicy.activeTokens(
            filters: category.filters,
            selection: state.selectedCategoryFilters
        ).count
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            switch layout {
            case .expanded, .compact:
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("筛选")
                    if activeCount > 0 {
                        filterCountBadge
                    }
                }
            case .minimal:
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        if activeCount > 0 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -3)
                        }
                    }
            }
        }
        .controlSize(.large)
        .disabled(category?.filters.isEmpty != false)
        .help(filterHelp)
        .accessibilityLabel(filterHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let category, !category.filters.isEmpty {
                HomeFilterPopover(
                    filters: category.filters,
                    selection: state.selectedCategoryFilters
                ) { selection in
                    scheduleFilterLoad(
                        categoryID: category.id,
                        filters: selection
                    )
                }
            }
        }
        .onChange(of: state.selectedCategoryID) { _ in
            filterLoadTask?.cancel()
            isPresented = false
        }
        .onDisappear {
            filterLoadTask?.cancel()
        }
    }

    private var filterCountBadge: some View {
        Text("\(activeCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 17, minHeight: 17)
            .background(Circle().fill(Color.blue))
    }

    private var filterHelp: String {
        guard category?.filters.isEmpty == false else {
            return "当前分类没有筛选项"
        }
        return activeCount == 0
            ? "筛选当前分类"
            : "筛选当前分类，已启用 \(activeCount) 项"
    }

    private func scheduleFilterLoad(
        categoryID: String,
        filters: [String: String]
    ) {
        filterLoadTask?.cancel()
        state.stageCategoryFilters(id: categoryID, filters: filters)
        filterLoadTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state.selectedCategoryID == categoryID else {
                return
            }
            await state.loadCategory(id: categoryID, filters: filters)
        }
    }
}

private struct HomeFilterPopover: View {
    let filters: [VideoFilter]
    let selection: [String: String]
    let onSelectionChanged: ([String: String]) -> Void

    private var activeCount: Int {
        HomeFilterPresentationPolicy.activeTokens(
            filters: filters,
            selection: selection
        ).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("筛选")
                    .font(.headline)
                Spacer()
                if activeCount > 0 {
                    Button("重置") {
                        onSelectionChanged(
                            HomeFilterPresentationPolicy.defaultSelection(
                                filters: filters
                            )
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filters) { filter in
                        if !filter.options.isEmpty {
                            Picker(
                                filter.name,
                                selection: selectionBinding(for: filter)
                            ) {
                                ForEach(filter.options) { option in
                                    Text(option.name)
                                        .tag(option.value)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 360)
    }

    private func selectionBinding(for filter: VideoFilter) -> Binding<String> {
        Binding(
            get: {
                selection[filter.id]
                    ?? filter.options.first?.value
                    ?? ""
            },
            set: { value in
                var updated =
                    HomeFilterPresentationPolicy.normalizedSelection(
                        filters: filters,
                        selection: selection
                    )
                updated[filter.id] = value
                onSelectionChanged(updated)
            }
        )
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
            .menuIndicator(.hidden)
            .controlSize(.large)
            .frame(width: 42)
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
            Image(systemName: "slider.horizontal.3")
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
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(width: 42)
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
