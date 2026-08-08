import SwiftUI
import OKVideoCore

struct SearchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()

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
        .navigationTitle("首页")
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .onDisappear {
            state.cancelSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                state.returnFromSearchToHome()
            } label: {
                Label("返回首页", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索所有已启用站点", text: $state.searchKeyword)
                    .textFieldStyle(.plain)
                    .onSubmit { state.search(state.searchKeyword) }
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

            Button("搜索") {
                state.search(state.searchKeyword)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            Button("取消") {
                state.cancelSearch()
            }
            .disabled(!state.isSearching)

            if state.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text(
                    "\(state.searchCompletedSiteCount)/"
                        + "\(state.searchTotalSiteCount) 站"
                )
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(AppSurfacePalette.background)
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
                    if !state.searchFailures.isEmpty {
                        SearchFailureSummary(
                            failures: state.searchFailures
                        )
                    }
                    SearchClusterGrid(
                        clusters: state.visibleSearchClusters
                    ) { summary in
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
                Text("\(options.count) 个站点")
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
        DisclosureGroup(
            "\(failures.count) 个站点失败，其他结果仍可使用"
        ) {
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
            .padding(.top, 6)
        }
        .font(.caption)
        .foregroundColor(.orange)
    }
}

private struct SearchClusterGrid: View {
    let clusters: [SearchResultCluster]
    let onSelect: (VideoSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(clusters) { cluster in
                SearchClusterCell(cluster: cluster, onSelect: onSelect)
            }
        }
    }
}

private struct SearchClusterCell: View {
    let cluster: SearchResultCluster
    let onSelect: (VideoSummary) -> Void

    @ViewBuilder
    var body: some View {
        if let primary = cluster.primary {
            Button {
                onSelect(primary)
            } label: {
                clusterLabel(primary: primary)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ForEach(cluster.sources) { source in
                    Button("从 \(source.siteName) 打开") {
                        onSelect(source)
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
