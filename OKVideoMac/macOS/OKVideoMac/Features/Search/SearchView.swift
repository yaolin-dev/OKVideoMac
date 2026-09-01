import AppKit
import SwiftUI
import OKVideoCore

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var presentationCache = SearchResultPresentationCache()
    @State private var sortOrder: SearchResultSortOrder = .relevance
    @AppStorage(SearchDisplayPreferences.mergesDuplicateTitlesKey)
    private var mergesDuplicateTitles = true
    @State private var sourceSelectionCluster: SearchResultCluster?
    @State private var showingSearchScope = false
    private let resultsScrollCoordinateSpace = "search-results-scroll"

    var body: some View {
        GeometryReader { proxy in
            let toolbarLayout = SearchToolbarLayoutPolicy.layout(
                contentWidth: proxy.size.width
            )
            searchContent
                .navigationTitle("")
                .background(AppSurfacePalette.background.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        SearchToolbarLeadingItem(
                            title: toolbarTitle,
                            backHelp: state.homeSearchBackHelp,
                            onBack: state.navigateBackHomeSearch
                        )
                    }
                    ToolbarItem(placement: .principal) {
                        Spacer(minLength: 0)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if state.currentSearchFolder == nil {
                            searchScopeButton()
                            searchMergeControl(layout: toolbarLayout)
                            searchSortControl(layout: toolbarLayout)
                        }
                        SearchToolbarStatusView(
                            layout: toolbarLayout,
                            isSearching: state.isSearching,
                            firstPageCompleted: state.searchFirstPageCompletedSiteCount,
                            completed: state.searchCompletedSiteCount,
                            total: state.searchTotalSiteCount,
                            termination: state.searchTermination,
                            resultCount: state.searchResults.count,
                            outcomes: Array(state.searchSiteOutcomes.values),
                            runtimeNotice: state.searchRuntimeProfileNotice,
                            maximumRetainedCandidates:
                                state.searchMaximumRetainedCandidates,
                            maximumResultsPerSite:
                                state.searchMaximumResultsPerSite,
                            didDiscardCandidates:
                                state.searchDidDiscardCandidates,
                            onCancel: state.cancelSearch
                        )
                    }
                }
                .overlay {
                    if let cluster = sourceSelectionCluster {
                        SearchSourcePicker(
                            cluster: cluster,
                            onSelect: openSearchSource,
                            onDismiss: { sourceSelectionCluster = nil }
                        )
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.98))
                        )
                    }
                }
                .animation(
                    .easeOut(duration: 0.14),
                    value: sourceSelectionCluster?.id
                )
                .transaction { transaction in
                    // Toolbar state changes replace symbols and text inside
                    // fixed slots; they never insert or remove AppKit items.
                    transaction.disablesAnimations = true
                }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if let folder = state.currentSearchFolder {
            SearchFolderBrowser(
                page: folder,
                path: state.searchFolderPath
            )
            .environmentObject(state)
        } else if state.searchResults.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: emptyStateTitle,
                message: emptyStateMessage
            )
        } else {
            searchResults
        }
    }

    private var toolbarTitle: String {
        state.currentSearchFolder?.folder.title ?? "搜索结果"
    }

    @ViewBuilder
    private func searchScopeButton() -> some View {
        Button {
            showingSearchScope.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(width: 42, height: 40)
        .help("选择本次搜索使用的站点")
        .accessibilityLabel("搜索范围：\(state.searchScopeSummary)")
        .popover(isPresented: $showingSearchScope, arrowEdge: .bottom) {
            SearchScopePopover()
                .environmentObject(state)
        }
    }

    private func searchMergeControl(
        layout: SearchToolbarLayout
    ) -> some View {
        Picker("重复影片", selection: $mergesDuplicateTitles) {
            Text("合并重复")
                .tag(true)
            Text("分别显示")
                .tag(false)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .frame(width: layout.mergeWidth, height: 40)
        .help(
            mergesDuplicateTitles
                ? "将片名和年份相同的跨站结果合并为一张卡片"
                : "按来源分别显示搜索结果"
        )
        .accessibilityLabel("重复影片显示方式")
        .accessibilityValue(
            mergesDuplicateTitles ? "合并重复影片" : "按来源分别显示"
        )
    }

    @ViewBuilder
    private func searchSortControl(
        layout: SearchToolbarLayout
    ) -> some View {
        Picker("排序", selection: $sortOrder) {
            ForEach(SearchResultSortOrder.allCases) { option in
                Text(option.toolbarTitle).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .frame(width: layout.sortWidth, height: 40)
        .help("排序：\(sortOrder.title)")
    }

    private var searchResults: some View {
        let clusters = presentedClusters
        return ScrollView {
            BrowserToolbarScrollMarker(
                coordinateSpaceName: resultsScrollCoordinateSpace
            )
            VStack(alignment: .leading, spacing: 0) {
                SearchSourceNavigation(
                    options: state.searchSiteOptions,
                    selectedKey: state.selectedSearchSiteKey,
                    totalCount: state.searchResults.count
                ) { key in
                    state.selectSearchSite(key)
                }

                SearchClusterGrid(
                    clusters: clusters
                ) { cluster in
                    if SearchClusterOpenPolicy.requiresSourceSelection(cluster) {
                        sourceSelectionCluster = cluster
                    } else if let summary = cluster.primary {
                        state.openSearchResult(summary)
                    }
                } onSelectSource: { summary in
                    state.openSearchResult(summary)
                }
                .padding(.horizontal, HomeBrowseGridMetrics.contentPadding)
                // Search has no permanent status/error row. Eight points from
                // the card plus sixteen here create the approved 24-point gap
                // between the navigation separator and visible posters.
                .padding(.top, 16)
                .padding(.bottom, HomeBrowseGridMetrics.contentPadding)
            }
        }
        .browserToolbarScrollSurface(named: resultsScrollCoordinateSpace)
        .background(AppSurfacePalette.background)
    }

    private var visibleRawResults: [VideoSummary] {
        guard let selectedSiteKey = state.selectedSearchSiteKey else {
            return state.searchResults
        }
        return state.searchResults.filter { $0.siteKey == selectedSiteKey }
    }

    private var presentedClusters: [SearchResultCluster] {
        presentationCache.clusters(
            from: visibleRawResults,
            keyword: state.activeSearchKeyword,
            mergesDuplicates: mergesDuplicateTitles,
            sortOrder: sortOrder
        )
    }

    private func openSearchSource(_ summary: VideoSummary) {
        sourceSelectionCluster = nil
        state.openSearchResult(summary)
    }

    private var emptyStateTitle: String {
        if state.activeSearchKeyword.isEmpty {
            return "搜索影视内容"
        }
        return state.isSearching ? "正在搜索" : "暂无结果"
    }

    private var emptyStateMessage: String {
        if state.activeSearchKeyword.isEmpty {
            return "输入关键词后将并发搜索当前范围内已启用的站点。"
        }
        if state.isSearching {
            return "首批已完成 \(state.searchFirstPageCompletedSiteCount)/"
                + "\(state.searchTotalSiteCount) 个站点；站点处理已结束 "
                + "\(state.searchCompletedSiteCount)/"
                + "\(state.searchTotalSiteCount)，结果会增量显示。"
        }
        return state.searchFailures.isEmpty
            ? emptyCompletionMessage
            : "\(state.searchFailures.count) 个站点搜索失败，"
                + "其余站点没有返回结果。"
    }

    private var emptyCompletionMessage: String {
        switch state.searchTermination {
        case .deadlineReached:
            return "首轮搜索已完成；后台补页已到达时间上限。"
        case .cancelled:
            return "搜索已取消。"
        case .supersededByNewSearch:
            return "本次搜索已被新搜索替代。"
        default:
            return "当前搜索范围内没有站点返回匹配内容。"
        }
    }
}

enum SearchToolbarLayout: Equatable, Sendable {
    case expanded
    case compact
    case minimal

    var mergeWidth: CGFloat {
        switch self {
        case .expanded: return 126
        case .compact: return 112
        case .minimal: return 102
        }
    }

    var sortWidth: CGFloat {
        switch self {
        case .expanded: return 112
        case .compact: return 100
        case .minimal: return 90
        }
    }

    var statusWidth: CGFloat {
        switch self {
        case .expanded: return 226
        case .compact: return 166
        case .minimal: return 104
        }
    }
}

enum SearchToolbarLayoutPolicy {
    static func layout(contentWidth: CGFloat) -> SearchToolbarLayout {
        if contentWidth >= 1_050 { return .expanded }
        if contentWidth >= 760 { return .compact }
        return .minimal
    }
}

private struct SearchToolbarLeadingItem: View {
    let title: String
    let backHelp: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help(backHelp)
            .accessibilityLabel(backHelp)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 40)
        .offset(x: 4)
    }
}

struct SearchSourceNavigationCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let width: CGFloat
}

struct SearchSourceNavigationPartition: Equatable, Sendable {
    let visibleIDs: [String]
    let hiddenIDs: [String]
}

enum SearchSourceNavigationLayoutPolicy {
    static let spacing = BrowseSegmentedNavigationMetrics.separatorWidth

    static func partition(
        candidates: [SearchSourceNavigationCandidate],
        selectedID: String,
        availableWidth: CGFloat
    ) -> SearchSourceNavigationPartition {
        guard !candidates.isEmpty else {
            return SearchSourceNavigationPartition(
                visibleIDs: [],
                hiddenIDs: []
            )
        }

        let availableWidth = BrowseSegmentedNavigationMetrics
            .innerAvailableWidth(availableWidth)
        let allWidth = candidates.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, candidates.count - 1))
        if allWidth <= availableWidth {
            return SearchSourceNavigationPartition(
                visibleIDs: candidates.map(\.id),
                hiddenIDs: []
            )
        }

        let tabBudget = max(
            0,
            availableWidth
                - BrowseSegmentedNavigationMetrics.moreWidth
                - spacing
        )
        var visible = [candidates[0].id]
        var consumed = candidates[0].width

        for candidate in candidates.dropFirst() {
            let proposed = consumed + spacing + candidate.width
            guard proposed <= tabBudget else { break }
            visible.append(candidate.id)
            consumed = proposed
        }

        if !visible.contains(selectedID),
           let selected = candidates.first(where: { $0.id == selectedID }) {
            while visible.count > 1,
                  consumed + spacing + selected.width > tabBudget {
                guard let removedID = visible.popLast(),
                      let removed = candidates.first(where: {
                          $0.id == removedID
                      }) else {
                    break
                }
                consumed -= spacing + removed.width
            }
            if consumed + spacing + selected.width <= tabBudget {
                visible.append(selected.id)
            } else {
                // On a narrow window the active source is more useful than
                // keeping “all results” visible. The latter remains in More.
                visible = [selected.id]
            }
        }

        let visibleSet = Set(visible)
        return SearchSourceNavigationPartition(
            visibleIDs: visible,
            hiddenIDs: candidates.compactMap {
                visibleSet.contains($0.id) ? nil : $0.id
            }
        )
    }
}

private struct SearchSourceNavigation: View {
    private static let allResultsID = "__all-search-results__"

    let options: [SearchSiteOption]
    let selectedKey: String?
    let totalCount: Int
    let onSelect: (String?) -> Void

    private var selectedID: String {
        selectedKey ?? Self.allResultsID
    }

    private var items: [Item] {
        [
            Item(
                id: Self.allResultsID,
                key: nil,
                title: "全部结果",
                count: totalCount
            )
        ] + options.map {
            Item(id: $0.key, key: $0.key, title: $0.name, count: $0.resultCount)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let currentItems = items
            let partition = SearchSourceNavigationLayoutPolicy.partition(
                candidates: currentItems.map {
                    SearchSourceNavigationCandidate(
                        id: $0.id,
                        width: Self.measuredWidth(for: $0.title)
                    )
                },
                selectedID: selectedID,
                availableWidth: max(
                    0,
                    proxy.size.width
                        - HomeBrowseGridMetrics.contentPadding * 2
                        - HomeBrowseGridMetrics.categoryLeadingInset
                )
            )
            let byID = Dictionary(uniqueKeysWithValues: currentItems.map {
                ($0.id, $0)
            })

            HStack(spacing: 0) {
                BrowseSegmentedNavigationContainer {
                    ForEach(
                        Array(partition.visibleIDs.enumerated()),
                        id: \.element
                    ) { index, id in
                        if index > 0 {
                            BrowseSegmentedNavigationDivider()
                        }
                        if let item = byID[id] {
                            sourceButton(item)
                        }
                    }

                    if !partition.hiddenIDs.isEmpty {
                        BrowseSegmentedNavigationDivider()
                        Menu {
                            ForEach(partition.hiddenIDs, id: \.self) { id in
                                if let item = byID[id] {
                                    Button {
                                        onSelect(item.key)
                                    } label: {
                                        HStack {
                                            Text(item.title)
                                            Spacer()
                                            Text("\(item.count)")
                                        }
                                    }
                                }
                            }
                        } label: {
                            BrowseSegmentedMoreLabel()
                        }
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("显示另外 \(partition.hiddenIDs.count) 个结果来源")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, HomeBrowseGridMetrics.contentPadding
                + HomeBrowseGridMetrics.categoryLeadingInset)
            .padding(.trailing, HomeBrowseGridMetrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: BrowseSegmentedNavigationMetrics.rowHeight)
        .overlay(alignment: .bottom) {
            BrowseSegmentedNavigationBottomDivider()
        }
    }

    private func sourceButton(_ item: Item) -> some View {
        Button {
            onSelect(item.key)
        } label: {
            BrowseSegmentedNavigationLabel(
                title: item.title,
                isSelected: item.id == selectedID
            )
        }
        .buttonStyle(
            BrowseSegmentedNavigationButtonStyle(
                isSelected: item.id == selectedID
            )
        )
        .help("\(item.title)，\(item.count) 项")
        .accessibilityLabel("\(item.title)，\(item.count) 项")
    }

    private static func measuredWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return BrowseSegmentedNavigationMetrics.segmentWidth(
            textWidth: (title as NSString)
                .size(withAttributes: [.font: font])
                .width
        )
    }

    private struct Item: Identifiable {
        let id: String
        let key: String?
        let title: String
        let count: Int
    }
}

struct SearchToolbarStatusPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case searching
        case completed
        case stopped
    }

    let phase: Phase
    let text: String
    let accessibilityValue: String
}

enum SearchToolbarStatusPolicy {
    static func presentation(
        layout: SearchToolbarLayout,
        isSearching: Bool,
        firstPageCompleted: Int,
        completed: Int,
        total: Int,
        termination: MultiSiteSearchTermination?
    ) -> SearchToolbarStatusPresentation {
        guard total > 0 else {
            return SearchToolbarStatusPresentation(
                phase: .preparing,
                text: "准备搜索",
                accessibilityValue: "正在准备搜索"
            )
        }

        let phase: SearchToolbarStatusPresentation.Phase
        if isSearching {
            phase = .searching
        } else if termination == .cancelled
            || termination == .supersededByNewSearch {
            phase = .stopped
        } else {
            phase = .completed
        }

        let text: String
        switch (layout, phase) {
        case (.expanded, .searching):
            text = "首批 \(firstPageCompleted)/\(total) · 已结束 \(completed)/\(total)"
        case (.expanded, .completed):
            text = "✓ 已完成 \(completed)/\(total)"
        case (.expanded, .stopped):
            text = "已停止 \(completed)/\(total)"
        case (.compact, .searching):
            text = "已结束 \(completed)/\(total)"
        case (.compact, .completed):
            text = "✓ 已完成 \(completed)/\(total)"
        case (.compact, .stopped):
            text = "已停止 \(completed)/\(total)"
        case (.minimal, _):
            text = "\(completed)/\(total)"
        case (_, .preparing):
            text = "准备搜索"
        }

        let accessibilityValue: String
        switch phase {
        case .preparing:
            accessibilityValue = "正在准备搜索"
        case .searching:
            accessibilityValue = "首批已完成 \(firstPageCompleted) / \(total) 个站点，站点处理已结束 \(completed) / \(total) 个站点"
        case .completed:
            accessibilityValue = "搜索已完成，共处理 \(completed) / \(total) 个站点"
        case .stopped:
            accessibilityValue = "搜索已停止，共处理 \(completed) / \(total) 个站点"
        }

        return SearchToolbarStatusPresentation(
            phase: phase,
            text: text,
            accessibilityValue: accessibilityValue
        )
    }
}

private struct SearchToolbarStatusView: View {
    let layout: SearchToolbarLayout
    let isSearching: Bool
    let firstPageCompleted: Int
    let completed: Int
    let total: Int
    let termination: MultiSiteSearchTermination?
    let resultCount: Int
    let outcomes: [SearchSiteOutcome]
    let runtimeNotice: String?
    let maximumRetainedCandidates: Int
    let maximumResultsPerSite: Int
    let didDiscardCandidates: Bool
    let onCancel: () -> Void

    @State private var showingDetails = false

    private var presentation: SearchToolbarStatusPresentation {
        SearchToolbarStatusPolicy.presentation(
            layout: layout,
            isSearching: isSearching,
            firstPageCompleted: firstPageCompleted,
            completed: completed,
            total: total,
            termination: termination
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    statusSymbol
                    Text(presentation.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看搜索进度详情")
            .accessibilityLabel("搜索进度")
            .accessibilityValue(presentation.accessibilityValue)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                SearchProgressDetailsPopover(
                    presentation: presentation,
                    resultCount: resultCount,
                    outcomes: outcomes,
                    runtimeNotice: runtimeNotice,
                    maximumRetainedCandidates: maximumRetainedCandidates,
                    maximumResultsPerSite: maximumResultsPerSite,
                    didDiscardCandidates: didDiscardCandidates
                )
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .opacity(isSearching ? 1 : 0)
            .allowsHitTesting(isSearching)
            .accessibilityHidden(!isSearching)
            .help("停止搜索")
        }
        .frame(width: layout.statusWidth, height: 40, alignment: .trailing)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if presentation.phase == .searching {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: statusSymbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private var statusSymbolName: String {
        switch presentation.phase {
        case .preparing: return "magnifyingglass"
        case .searching: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }
}

private struct SearchProgressDetailsPopover: View {
    let presentation: SearchToolbarStatusPresentation
    let resultCount: Int
    let outcomes: [SearchSiteOutcome]
    let runtimeNotice: String?
    let maximumRetainedCandidates: Int
    let maximumResultsPerSite: Int
    let didDiscardCandidates: Bool

    private var orderedOutcomes: [SearchSiteOutcome] {
        outcomes.sorted {
            $0.siteKey.localizedStandardCompare($1.siteKey)
                == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: headerSymbol)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("搜索状态")
                        .font(.headline)
                    Text(presentation.accessibilityValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("当前已显示 \(resultCount) 条结果")
                .font(.callout)

            if let runtimeNotice, !runtimeNotice.isEmpty {
                detailRow(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    text: runtimeNotice
                )
            }

            if didDiscardCandidates {
                detailRow(
                    systemImage: "line.3.horizontal.decrease.circle",
                    text: retentionSummary
                )
            }

            if !orderedOutcomes.isEmpty {
                Divider()
                Text("站点详情")
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(orderedOutcomes, id: \.siteKey) { outcome in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outcome.title)
                                    .font(.caption.weight(.medium))
                                if let detail = outcome.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var headerSymbol: String {
        switch presentation.phase {
        case .preparing: return "magnifyingglass"
        case .searching: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    private var retentionSummary: String {
        if maximumRetainedCandidates == .max,
           maximumResultsPerSite == .max {
            return "完整保留各站结果"
        }
        return "已按相关度保留结果；总量上限 \(maximumRetainedCandidates)，每站上限 \(maximumResultsPerSite)"
    }

    private func detailRow(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

private extension SearchSiteOutcome {
    var siteKey: String {
        switch self {
        case .success(let siteKey, _, _): return siteKey
        case .failure(let failure): return failure.siteKey
        case .cancelled(let siteKey, _): return siteKey
        }
    }
}

struct SearchScopeEditorContent: View {
    let options: [SearchScopeSiteOption]
    @Binding var mode: SearchSiteScopeMode
    @Binding var selectedKeys: Set<String>
    @Binding var filterText: String

    private var searchableKeys: Set<String> {
        Set(options.lazy.filter(\.isSearchable).map(\.key))
    }

    private var filteredOptions: [SearchScopeSiteOption] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
        }
    }

    private var modeSelection: Binding<SearchSiteScopeMode> {
        Binding(
            get: { mode },
            set: { newMode in
                if newMode == .custom,
                   selectedKeys.intersection(searchableKeys).isEmpty {
                    selectedKeys.formUnion(searchableKeys)
                }
                mode = newMode
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("搜索范围", selection: modeSelection) {
                Text("全部站点").tag(SearchSiteScopeMode.all)
                Text("自定义").tag(SearchSiteScopeMode.custom)
            }
            .pickerStyle(.segmented)

            if mode == .custom {
                HStack(spacing: 8) {
                    Button("全选") {
                        selectedKeys.formUnion(searchableKeys)
                    }
                    Button("清空") {
                        selectedKeys.subtract(searchableKeys)
                    }
                    Button("反选") {
                        let selected = selectedKeys.intersection(searchableKeys)
                        selectedKeys.subtract(searchableKeys)
                        selectedKeys.formUnion(searchableKeys.subtracting(selected))
                    }
                    Spacer()
                    Text("已选 \(selectedKeys.intersection(searchableKeys).count) / \(searchableKeys.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .controlSize(.small)
            } else {
                Text("当前目录中所有可运行站点都会发起搜索，包括源中标记为停用的站点；如需排除请切换到自定义。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField("筛选站点名称", text: $filterText)
                .textFieldStyle(.roundedBorder)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredOptions) { option in
                        siteRow(option)
                    }
                }
            }
        }
    }

    private func siteRow(_ option: SearchScopeSiteOption) -> some View {
        let isSelected = mode == .all
            ? option.isSearchable
            : selectedKeys.contains(option.key)
        return Button {
            guard option.isSearchable, mode == .custom else { return }
            if selectedKeys.contains(option.key) {
                selectedKeys.remove(option.key)
            } else {
                selectedKeys.insert(option.key)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(
                        option.isSearchable
                            ? (isSelected ? .accentColor : .secondary)
                            : .secondary.opacity(0.55)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.callout.weight(.medium))
                    if let reason = option.unavailableReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if option.isUserDisabled {
                        Text(
                            mode == .all
                                ? "源中已停用 · 全部模式仍会搜索"
                                : "源中已停用 · 可为搜索单独启用"
                        )
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(option.key)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.07 : 0.025))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isSearchable || mode == .all)
        .appInteractiveHover(cornerRadius: 8, selected: isSelected)
    }
}

private struct SearchScopePopover: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SearchSiteScopeMode
    @State private var selectedKeys: Set<String>
    @State private var filterText = ""
    @State private var isSaving = false

    init(scope: SearchSiteScope = .all) {
        _mode = State(initialValue: scope.mode)
        _selectedKeys = State(initialValue: scope.selectedSiteKeys)
    }

    private var draft: SearchSiteScope {
        SearchSiteScope(mode: mode, selectedSiteKeys: selectedKeys)
    }

    private var hasValidSelection: Bool {
        mode == .all || !SearchSiteScopePolicy.effectiveSiteKeys(
            scope: draft,
            options: state.searchScopeSiteOptions
        ).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索范围")
                    .font(.headline)
                Text("只会请求这里选中的站点；结果来源筛选不会发起新搜索。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SearchScopeEditorContent(
                options: state.searchScopeSiteOptions,
                mode: $mode,
                selectedKeys: $selectedKeys,
                filterText: $filterText
            )

            Divider()

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                if !hasValidSelection {
                    Text("至少选择一个可用站点")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button(state.isSearching ? "保存并重新搜索" : "保存") {
                    let shouldRestart = state.isSearching
                    isSaving = true
                    Task {
                        let saved = await state.saveSearchSiteScope(draft)
                        isSaving = false
                        guard saved else { return }
                        dismiss()
                        if shouldRestart {
                            state.search(state.activeSearchKeyword)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasValidSelection || isSaving || draft == state.searchSiteScope)
            }
        }
        .padding(16)
        .frame(width: 440, height: 520)
        .onAppear {
            mode = state.searchSiteScope.mode
            selectedKeys = state.searchSiteScope.selectedSiteKeys
        }
    }
}

private struct SearchFolderBrowser: View {
    @EnvironmentObject private var state: AppState
    let page: SearchFolderPage
    let path: [SearchFolderPage]
    private let folderScrollCoordinateSpace = "search-folder-scroll"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                Text(path.map { $0.folder.title }.joined(separator: " / "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()

                if page.isLoading {
                    AppActivityIndicator(size: .small)
                }
                Text(page.folder.siteName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            folderContent
        }
    }

    @ViewBuilder
    private var folderContent: some View {
        if let errorMessage = page.errorMessage, page.items.isEmpty {
            VStack(spacing: 14) {
                EmptyStateView(
                    systemImage: "externaldrive.badge.exclamationmark",
                    title: "网盘目录加载失败",
                    message: errorMessage
                )
                Button("重试") {
                    state.retryCurrentSearchFolder()
                }
            }
        } else if page.isLoading, page.items.isEmpty {
            AppActivityLabel("正在展开网盘目录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page.items.isEmpty {
            EmptyStateView(
                systemImage: "folder",
                title: "目录为空",
                message: "该搜索结果没有返回可浏览的网盘条目。"
            )
        } else {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 18) {
                        SearchFolderGrid(items: page.items) { summary in
                            state.openSearchFolderItem(summary)
                        }

                        if page.pagination?.hasMore == true {
                            AutomaticPageLoader(
                                isLoading: page.isLoading,
                                errorMessage: page.errorMessage,
                                viewportHeight: viewport.size.height,
                                coordinateSpaceName: folderScrollCoordinateSpace
                            ) {
                                state.loadNextSearchFolderPage()
                            }
                            .id(page.pagination?.page ?? 0)
                        } else {
                            PaginationCompletionFooter(
                                itemCount: page.items.count
                            )
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: folderScrollCoordinateSpace)
            }
        }
    }
}

private struct SearchFolderGrid: View {
    let items: [VideoSummary]
    let onSelect: (VideoSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        VideoPosterView(item: item)
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let remarks = VideoCardMetadata.secondaryText(
                            from: item.remarks
                        ) {
                            Text(remarks)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Label(
                            item.isFolder ? "文件夹" : item.siteName,
                            systemImage: item.isFolder
                                ? "folder"
                                : "play.rectangle"
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appInteractiveHover(cornerRadius: 10)
            }
        }
    }
}

private extension SearchSiteOutcome {
    var title: String {
        switch self {
        case .success(_, let siteName, let resultCount):
            return resultCount == 0
                ? "\(siteName) · 搜索成功但结果为空"
                : "\(siteName) · 搜索成功并返回 \(resultCount) 条"
        case .failure(let failure):
            return "\(failure.siteName) · \(failure.categoryTitle)"
        case .cancelled(_, let siteName):
            return "\(siteName) · 用户取消"
        }
    }

    var detail: String? {
        guard case .failure(let failure) = self else { return nil }
        return failure.message
    }
}

private extension SearchFailure {
    var categoryTitle: String {
        switch category {
        case .unsupportedRoute: return "未提供搜索路由"
        case .configurationRequired: return "需要配置或登录"
        case .scriptError: return "脚本错误"
        case .upstreamUnavailable: return "上游不可用"
        case .timeout: return "搜索超时"
        case .transport: return "网络连接失败"
        case .provider: return "站点返回错误"
        }
    }
}

enum SearchResultSortOrder: String, CaseIterable, Identifiable {
    case relevance
    case sourceCount
    case newest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "相关度排序"
        case .sourceCount: return "来源数量"
        case .newest: return "年份最新"
        case .title: return "片名排序"
        }
    }

    var toolbarTitle: String {
        switch self {
        case .relevance: return "相关度"
        case .sourceCount: return "来源数"
        case .newest: return "最新"
        case .title: return "片名"
        }
    }
}

enum SearchDisplayPreferences {
    static let mergesDuplicateTitlesKey = "search.mergesDuplicateTitles"
}

final class SearchResultPresentationCache: ObservableObject {
    private struct Input: Equatable {
        let items: [VideoSummary]
        let keyword: String
        let mergesDuplicates: Bool
        let sortOrder: SearchResultSortOrder
    }

    private var lastInput: Input?
    private var lastClusters: [SearchResultCluster] = []
    private(set) var computationCount = 0

    func clusters(
        from items: [VideoSummary],
        keyword: String,
        mergesDuplicates: Bool,
        sortOrder: SearchResultSortOrder
    ) -> [SearchResultCluster] {
        let input = Input(
            items: items,
            keyword: keyword,
            mergesDuplicates: mergesDuplicates,
            sortOrder: sortOrder
        )
        if input == lastInput {
            return lastClusters
        }
        let clusters = SearchResultPresentation.clusters(
            from: items,
            keyword: keyword,
            mergesDuplicates: mergesDuplicates,
            sortOrder: sortOrder
        )
        lastInput = input
        lastClusters = clusters
        computationCount += 1
        return clusters
    }
}

enum SearchClusterOpenPolicy {
    static func requiresSourceSelection(_ cluster: SearchResultCluster) -> Bool {
        cluster.sources.count > 1
    }
}

enum SearchResultPresentation {
    static func clusters(
        from items: [VideoSummary],
        keyword: String,
        mergesDuplicates: Bool,
        sortOrder: SearchResultSortOrder
    ) -> [SearchResultCluster] {
        let clusters = mergesDuplicates
            ? SearchResultAggregator.cluster(items)
            : items.map { item in
                SearchResultCluster(
                    id: item.id,
                    title: item.title,
                    year: normalizedYear(item.year),
                    sources: [item]
                )
            }

        return clusters.enumerated().sorted { lhs, rhs in
            orderedBefore(
                lhs: lhs,
                rhs: rhs,
                keyword: keyword,
                sortOrder: sortOrder
            )
        }.map(\.element)
    }

    private static func orderedBefore(
        lhs: (offset: Int, element: SearchResultCluster),
        rhs: (offset: Int, element: SearchResultCluster),
        keyword: String,
        sortOrder: SearchResultSortOrder
    ) -> Bool {
        switch sortOrder {
        case .relevance:
            // MultiSiteSearch is the single semantic owner of relevance.
            // Clustering preserves its retained-pool order.
            return lhs.offset < rhs.offset
        case .sourceCount:
            return lhs.element.sources.count == rhs.element.sources.count
                ? lhs.offset < rhs.offset
                : lhs.element.sources.count > rhs.element.sources.count
        case .newest:
            let leftYear = yearValue(lhs.element.year)
            let rightYear = yearValue(rhs.element.year)
            return leftYear == rightYear
                ? lhs.offset < rhs.offset
                : leftYear > rightYear
        case .title:
            let comparison = lhs.element.title.localizedStandardCompare(
                rhs.element.title
            )
            return comparison == .orderedSame
                ? lhs.offset < rhs.offset
                : comparison == .orderedAscending
        }
    }

    private static func yearValue(_ year: String?) -> Int {
        guard let year else { return Int.min }
        let digits = year.filter(\.isNumber)
        return Int(digits.prefix(4)) ?? Int.min
    }

    private static func normalizedYear(_ year: String?) -> String? {
        guard let value = year?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct SearchClusterGrid: View {
    let clusters: [SearchResultCluster]
    let onSelectCluster: (SearchResultCluster) -> Void
    let onSelectSource: (VideoSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(clusters) { cluster in
                SearchClusterCell(
                    cluster: cluster,
                    onSelectCluster: onSelectCluster,
                    onSelectSource: onSelectSource
                )
            }
        }
    }
}

private struct SearchClusterCell: View {
    let cluster: SearchResultCluster
    let onSelectCluster: (SearchResultCluster) -> Void
    let onSelectSource: (VideoSummary) -> Void

    @ViewBuilder
    var body: some View {
        if let primary = cluster.primary {
            Button {
                onSelectCluster(cluster)
            } label: {
                clusterLabel(primary: primary)
            }
            .buttonStyle(.plain)
            .appInteractiveHover(cornerRadius: 10)
            .contextMenu {
                ForEach(cluster.sources) { source in
                    Button("从 \(source.siteName) 打开") {
                        onSelectSource(source)
                    }
                }
            }
            .accessibilityLabel(
                "\(cluster.title)，\(cluster.sources.count) 个来源"
            )
        }
    }

    private func clusterLabel(primary: VideoSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VideoPosterView(item: primary)
            Text(cluster.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year = cluster.year {
                Text(year)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(sourceDescription(primary: primary))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sourceDescription(primary: VideoSummary) -> String {
        cluster.sources.count == 1
            ? primary.siteName
            : "\(cluster.sources.count) 个来源"
    }
}

private struct SearchSourcePicker: View {
    let cluster: SearchResultCluster
    let onSelect: (VideoSummary) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(cluster.sources) { source in
                            sourceButton(source)
                        }
                    }
                    .padding(16)
                }
            }
            .frame(width: 520, height: pickerHeight)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 26, y: 10)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 13) {
            if let primary = cluster.primary {
                VideoPosterView(item: primary)
                    .frame(width: 58, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("选择来源")
                    .font(.title3.weight(.semibold))
                Text(cluster.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("找到 \(cluster.sources.count) 个来源，请选择一个进入详情")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .appInteractiveHover(cornerRadius: 14)
            .help("关闭来源选择")
            .accessibilityLabel("关闭来源选择")
        }
        .padding(16)
    }

    private func sourceButton(_ source: VideoSummary) -> some View {
        Button {
            onSelect(source)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.siteName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let description = sourceDescription(source) {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                Text("进入详情")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 10)
        .accessibilityLabel("从 \(source.siteName) 打开 \(source.title)")
    }

    private var pickerHeight: CGFloat {
        let rowsHeight = CGFloat(min(cluster.sources.count, 6)) * 64
        return min(540, max(300, 116 + rowsHeight))
    }

    private func sourceDescription(_ source: VideoSummary) -> String? {
        [source.year, source.categoryName, source.remarks]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .prefix(2)
            .joined(separator: " · ")
            .nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
