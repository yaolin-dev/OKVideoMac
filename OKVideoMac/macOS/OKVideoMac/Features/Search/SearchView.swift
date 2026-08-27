import SwiftUI
import OKVideoCore

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @State private var sortOrder: SearchResultSortOrder = .relevance
    @AppStorage(SearchDisplayPreferences.mergesDuplicateTitlesKey)
    private var mergesDuplicateTitles = true
    @State private var sourceSelectionCluster: SearchResultCluster?
    @State private var showingSearchScope = false

    var body: some View {
        VStack(spacing: 0) {
            if !state.searchKeyword.isEmpty,
               let notice = state.searchRuntimeProfileNotice {
                SearchRuntimeProfileNotice(message: notice)
                Divider()
            }
            if let folder = state.currentSearchFolder {
                SearchFolderBrowser(
                    page: folder,
                    path: state.searchFolderPath
                )
                .environmentObject(state)
            } else if state.searchResults.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: emptyStateTitle,
                        message: emptyStateMessage
                    )
                    if !state.searchSiteOutcomes.isEmpty {
                        SearchSiteOutcomeSummary(
                            outcomes: Array(state.searchSiteOutcomes.values)
                        )
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
            } else {
                searchResults
            }
        }
        .navigationTitle("搜索结果")
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup {
                searchToolbar
            }
        }
        .onDisappear {
            state.cancelSearch()
        }
        .overlay {
            if let cluster = sourceSelectionCluster {
                SearchSourcePicker(
                    cluster: cluster,
                    onSelect: openSearchSource,
                    onDismiss: { sourceSelectionCluster = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: sourceSelectionCluster?.id)
    }

    @ViewBuilder
    private var searchToolbar: some View {
        Button {
            state.returnFromSearchToHome()
        } label: {
            Label("返回首页", systemImage: "chevron.left")
        }
        .help("返回首页")

        TextField("搜索影视内容", text: $state.searchKeyword)
            .textFieldStyle(.roundedBorder)
            .onSubmit { state.search(state.searchKeyword) }
            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)

        Button {
            showingSearchScope.toggle()
        } label: {
            Label(state.searchScopeSummary, systemImage: "checklist")
        }
        .help("选择本次搜索使用的站点")
        .popover(isPresented: $showingSearchScope, arrowEdge: .bottom) {
            SearchScopePopover()
                .environmentObject(state)
        }

        Button {
            state.search(state.searchKeyword)
        } label: {
            Label("搜索", systemImage: "magnifyingglass")
        }
        .disabled(
            state.searchKeyword
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )

        if state.isSearching {
            Button {
                state.cancelSearch()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .help("停止当前搜索")

            SearchProgressIndicator(
                firstPageCompleted: state.searchFirstPageCompletedSiteCount,
                completed: state.searchCompletedSiteCount,
                total: state.searchTotalSiteCount
            )
        }
    }

    private var searchResults: some View {
        HSplitView {
            SearchSiteSidebar(
                options: state.searchSiteOptions,
                selectedKey: state.selectedSearchSiteKey,
                totalCount: state.searchResults.count
            ) { key in
                state.selectSearchSite(key)
            }
            .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SearchResultToolbar(
                        title: selectedResultTitle,
                        resultCount: presentedClusters.count,
                        rawResultCount: visibleRawResults.count,
                        completedSiteCount: state.searchCompletedSiteCount,
                        totalSiteCount: state.searchTotalSiteCount,
                        resultSiteCount: state.searchSiteOptions.count,
                        isSearching: state.isSearching,
                        maximumRetainedCandidates:
                            state.searchMaximumRetainedCandidates,
                        maximumResultsPerSite:
                            state.searchMaximumResultsPerSite,
                        didDiscardCandidates:
                            state.searchDidDiscardCandidates,
                        termination: state.searchTermination,
                        sortOrder: $sortOrder,
                        mergesDuplicateTitles: $mergesDuplicateTitles
                    )

                    if !state.searchSiteOutcomes.isEmpty {
                        SearchSiteOutcomeSummary(
                            outcomes: Array(state.searchSiteOutcomes.values)
                        )
                    }
                    SearchClusterGrid(
                        clusters: presentedClusters
                    ) { cluster in
                        if SearchClusterOpenPolicy.requiresSourceSelection(cluster) {
                            sourceSelectionCluster = cluster
                        } else if let summary = cluster.primary {
                            state.openSearchResult(summary)
                        }
                    } onSelectSource: { summary in
                        state.openSearchResult(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .frame(minWidth: 480)
            .background(AppSurfacePalette.background)
        }
        .background(AppSurfacePalette.background)
    }

    private var visibleRawResults: [VideoSummary] {
        guard let selectedSiteKey = state.selectedSearchSiteKey else {
            return state.searchResults
        }
        return state.searchResults.filter { $0.siteKey == selectedSiteKey }
    }

    private var presentedClusters: [SearchResultCluster] {
        SearchResultPresentation.clusters(
            from: visibleRawResults,
            keyword: state.searchKeyword,
            mergesDuplicates: mergesDuplicateTitles,
            sortOrder: sortOrder
        )
    }

    private var selectedResultTitle: String {
        guard let key = state.selectedSearchSiteKey,
              let option = state.searchSiteOptions.first(where: { $0.key == key }) else {
            return "全部结果"
        }
        return option.name
    }

    private func openSearchSource(_ summary: VideoSummary) {
        sourceSelectionCluster = nil
        state.openSearchResult(summary)
    }

    private var emptyStateTitle: String {
        if state.searchKeyword.isEmpty {
            return "搜索影视内容"
        }
        return state.isSearching ? "正在搜索" : "暂无结果"
    }

    private var emptyStateMessage: String {
        if state.searchKeyword.isEmpty {
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

private struct SearchSiteSidebar: View {
    let options: [SearchSiteOption]
    let selectedKey: String?
    let totalCount: Int
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("结果来源")
                    .font(.headline)
                Text("\(options.count) 个站点有结果")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    sourceButton(
                        key: nil,
                        name: "全部搜索结果",
                        count: totalCount,
                        systemImage: "rectangle.stack"
                    )
                    ForEach(options) { option in
                        sourceButton(
                            key: option.key,
                            name: option.name,
                            count: option.resultCount,
                            systemImage: "network"
                        )
                    }
                }
                .padding(10)
            }
        }
        .background(AppSurfacePalette.background)
    }

    private func sourceButton(
        key: String?,
        name: String,
        count: Int,
        systemImage: String
    ) -> some View {
        let isSelected = selectedKey == key
        return Button {
            onSelect(key)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(count) 项")
                        .font(.caption2)
                        .foregroundColor(
                            isSelected ? .white.opacity(0.8) : .secondary
                        )
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 9, selected: isSelected)
    }
}

private struct SearchProgressIndicator: View {
    let firstPageCompleted: Int
    let completed: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("首批 \(firstPageCompleted) / \(total) · 已结束 \(completed) / \(total)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
        .frame(width: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("搜索进度")
        .accessibilityValue(
            "首批已完成 \(firstPageCompleted) / \(total) 个站点，"
                + "站点处理已结束 \(completed) / \(total) 个站点"
        )
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

private struct SearchRuntimeProfileNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.07))
        .accessibilityElement(children: .combine)
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
                            state.search(state.searchKeyword)
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

private struct SearchResultToolbar: View {
    let title: String
    let resultCount: Int
    let rawResultCount: Int
    let completedSiteCount: Int
    let totalSiteCount: Int
    let resultSiteCount: Int
    let isSearching: Bool
    let maximumRetainedCandidates: Int
    let maximumResultsPerSite: Int
    let didDiscardCandidates: Bool
    let termination: MultiSiteSearchTermination?
    @Binding var sortOrder: SearchResultSortOrder
    @Binding var mergesDuplicateTitles: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(retentionSummary)
                    .font(.caption2)
                    .foregroundColor(didDiscardCandidates ? .orange : .secondary)
            }

            Spacer(minLength: 12)

            Toggle("合并重复影片", isOn: $mergesDuplicateTitles)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("将片名和年份相同的跨站结果合并为一张卡片")

            Picker("排序", selection: $sortOrder) {
                ForEach(SearchResultSortOrder.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 132)
        }
        .padding(.horizontal, 2)
    }

    private var summary: String {
        let resultSummary = mergesDuplicateTitles
            ? "\(resultCount) 部影片 · \(rawResultCount) 条来源结果"
            : "\(rawResultCount) 条结果"
        if isSearching {
            return "\(resultSummary) · 已搜索 \(completedSiteCount) / \(totalSiteCount) 个站点"
        }
        return "\(resultSummary) · \(resultSiteCount) 个站点有结果"
            + terminationSuffix
    }

    private var retentionSummary: String {
        if maximumRetainedCandidates == .max,
           maximumResultsPerSite == .max {
            return "完整保留各站首批结果 · 未进行每站或总量裁剪"
        }
        if didDiscardCandidates, rawResultCount >= maximumRetainedCandidates {
            return "已展示相关度最高的前 \(maximumRetainedCandidates) 条"
                + " · 每站最多 \(maximumResultsPerSite) 条"
        }
        if didDiscardCandidates {
            return "已按相关度保留 \(rawResultCount) 条"
                + " · 每站最多 \(maximumResultsPerSite) 条，超额结果已裁剪"
        }
        return "最多展示相关度最高的前 \(maximumRetainedCandidates) 条"
            + " · 每站最多 \(maximumResultsPerSite) 条"
    }

    private var terminationSuffix: String {
        switch termination {
        case .completedWithProviderFailures:
            return " · 部分站点失败"
        case .deadlineReached:
            return " · 后台补页已到达时间上限"
        case .cancelled:
            return " · 已取消"
        case .supersededByNewSearch:
            return " · 已被新搜索替代"
        default:
            return ""
        }
    }
}

private struct SearchFolderBrowser: View {
    @EnvironmentObject private var state: AppState
    @State private var isBackHovered = false
    let page: SearchFolderPage
    let path: [SearchFolderPage]
    private let folderScrollCoordinateSpace = "search-folder-scroll"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    state.navigateBackSearchFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(path.count > 1 ? "上一级" : "返回搜索结果")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(
                        isBackHovered ? Color.accentColor : Color.secondary
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                Color.primary.opacity(isBackHovered ? 0.07 : 0)
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isBackHovered = $0 }
                .animation(.easeOut(duration: 0.14), value: isBackHovered)
                .help(path.count > 1 ? "返回上一级目录" : "返回全部搜索结果")

                Divider()
                    .frame(height: 18)

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

private struct SearchSiteOutcomeSummary: View {
    let outcomes: [SearchSiteOutcome]

    private var ordered: [SearchSiteOutcome] {
        outcomes.sorted { $0.siteKey.localizedStandardCompare($1.siteKey) == .orderedAscending }
    }

    private var failureCount: Int {
        outcomes.reduce(into: 0) { count, outcome in
            if case .failure = outcome { count += 1 }
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(
                    ordered,
                    id: \.siteKey
                ) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.title)
                            .font(.caption.bold())
                        if let detail = outcome.detail {
                            Text(detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: failureCount == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                    .foregroundColor(failureCount == 0 ? .green : .orange)
                Text("站点结果 \(outcomes.count) 个")
                    .fontWeight(.medium)
                Text(
                    failureCount == 0
                        ? "均已完成"
                        : "其中 \(failureCount) 个失败"
                )
                    .foregroundColor(.secondary)
                Spacer()
                Text("查看详情")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .foregroundColor(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background((failureCount == 0 ? Color.green : Color.orange).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    (failureCount == 0 ? Color.green : Color.orange).opacity(0.2),
                    lineWidth: 1
                )
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
}

enum SearchDisplayPreferences {
    static let mergesDuplicateTitlesKey = "search.mergesDuplicateTitles"
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
        .contentShape(Rectangle())
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
