import SwiftUI
import OKVideoCore

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @State private var sortOrder: SearchResultSortOrder = .relevance
    @AppStorage(SearchDisplayPreferences.mergesDuplicateTitlesKey)
    private var mergesDuplicateTitles = true
    @State private var sourceSelectionCluster: SearchResultCluster?

    var body: some View {
        VStack(spacing: 0) {
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
                    if !state.searchFailures.isEmpty {
                        SearchFailureSummary(
                            failures: state.searchFailures
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

        TextField("搜索全部站点", text: $state.searchKeyword)
            .textFieldStyle(.roundedBorder)
            .onSubmit { state.search(state.searchKeyword) }
            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)

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
                        sortOrder: $sortOrder,
                        mergesDuplicateTitles: $mergesDuplicateTitles
                    )

                    if !state.searchFailures.isEmpty {
                        SearchFailureSummary(
                            failures: state.searchFailures
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
            return "输入关键词后将并发搜索当前配置中已启用的站点。"
        }
        if state.isSearching {
            return "已完成 \(state.searchCompletedSiteCount)/"
                + "\(state.searchTotalSiteCount) 个站点，结果会增量显示。"
        }
        return state.searchFailures.isEmpty
            ? "所有已启用站点均未返回匹配内容。"
            : "\(state.searchFailures.count) 个站点搜索失败，"
                + "其余站点没有返回结果。"
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
                Text("搜索来源")
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
    }
}

private struct SearchProgressIndicator: View {
    let completed: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("正在搜索 \(completed) / \(total)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
        .frame(width: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("搜索进度")
        .accessibilityValue("已完成 \(completed) / \(total) 个站点")
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
                Button {
                    state.navigateBackSearchFolder()
                } label: {
                    Label(
                        path.count > 1 ? "上一级" : "返回搜索结果",
                        systemImage: "chevron.left"
                    )
                }

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
                    ProgressView()
                        .controlSize(.small)
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
            ProgressView("正在展开网盘目录…")
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
                        if item.isFolder {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.1))
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.accentColor)
                            }
                            .aspectRatio(2 / 3, contentMode: .fit)
                        } else {
                            VideoPosterView(item: item)
                        }
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
            }
        }
    }
}

private struct SearchFailureSummary: View {
    let failures: [SearchFailure]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(
                    Array(failures.enumerated()),
                    id: \.offset
                ) { _, failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.siteName)
                            .font(.caption.bold())
                        Text(failure.message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("\(failures.count) 个站点未响应")
                    .fontWeight(.medium)
                Text("其他结果仍可使用")
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
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
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
            let leftScore = relevanceScore(lhs.element.title, keyword: keyword)
            let rightScore = relevanceScore(rhs.element.title, keyword: keyword)
            return leftScore == rightScore
                ? lhs.offset < rhs.offset
                : leftScore > rightScore
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

    private static func relevanceScore(_ title: String, keyword: String) -> Int {
        let foldedTitle = folded(title)
        let foldedKeyword = folded(keyword)
        guard !foldedKeyword.isEmpty else { return 0 }
        if foldedTitle == foldedKeyword { return 3 }
        if foldedTitle.hasPrefix(foldedKeyword) { return 2 }
        if foldedTitle.contains(foldedKeyword) { return 1 }
        return 0
    }

    private static func folded(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
