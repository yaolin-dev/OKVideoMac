import AppKit
import SwiftUI
import OKVideoCore

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @State private var projection: [SearchResultCluster] = []
    @State private var projectionKey: String?
    @State private var projectionWorker = SearchPresentationWorker()
    @State private var sortOrder: SearchResultSortOrder = .relevance
    @AppStorage(SearchDisplayPreferences.mergesDuplicateTitlesKey)
    private var mergesDuplicateTitles = true
    @State private var sourceSelectionCluster: SearchResultCluster?
    @State private var showingSearchScope = false
    @State private var acceptedOrderRevision: UInt64 = 0
    private let resultsScrollCoordinateSpace = "search-results-scroll"

    var body: some View {
        GeometryReader { proxy in
            let toolbarLayout = SearchToolbarLayoutPolicy.layout(
                contentWidth: proxy.size.width
            )
            searchContent
                .task(id: presentationInput) {
                    let input = presentationInput
                    let result = await projectionWorker.clusters(input)
                    guard !Task.isCancelled else { return }
                    projectionKey = input.key
                    projection = result
                }
                .navigationTitle("")
                .background(AppSurfacePalette.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        SearchToolbarLeadingItem(
                            title: toolbarTitle,
                            backHelp: state.homeSearchBackHelp,
                            onBack: {
                                _ = state.performSearchBackAction()
                            }
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
                        refreshToolbarControl
                    }
                }
                .overlay {
                    if let cluster = sourceSelectionCluster {
                        SearchSourcePicker(
                            cluster: presentedClusters.first(where: { $0.id == cluster.id }) ?? cluster,
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

    private var refreshToolbarControl: some View {
        BrowserRefreshToolbarControl(
            isLoading: state.searchPageIsLoading,
            error: state.searchPageError,
            status: state.currentSearchFolder == nil ? state.searchPaginationFooter.statusText : nil,
            title: state.searchRefreshTitle,
            cancel: state.currentSearchFolder == nil ? { state.cancelSearch() } : nil,
            restart: { Task { await state.refreshSearchPage(force: true) } },
            action: {
                acceptLatestOrder()
                Task { await state.refreshSearchPage() }
            })
    }

    @ViewBuilder
    private var searchContent: some View {
        if let folder = state.currentSearchFolder {
            SearchFolderBrowser(
                page: folder,
                path: state.searchFolderPath
            )
            .environmentObject(state)
        } else {
            searchResults
        }
    }

    private var toolbarTitle: String {
        state.currentSearchFolder?.folder.title
            ?? L10n.string("search.results.title", fallback: "Search Results")
    }

    @ViewBuilder
    private func searchScopeButton() -> some View {
        Button {
            showingSearchScope.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .primaryToolbarIconControl()
        .help(L10n.string("search.scope.choose", fallback: "Choose providers for this search"))
        .accessibilityLabel(L10n.string("search.scope.value", fallback: "Search scope: %@", state.searchScopeSummary))
        .popover(isPresented: $showingSearchScope, arrowEdge: .bottom) {
            SearchScopePopover()
                .environmentObject(state)
        }
    }

    private func searchMergeControl(
        layout: SearchToolbarLayout
    ) -> some View {
        Picker(L10n.string("search.duplicates.label", fallback: "Duplicate Titles"), selection: $mergesDuplicateTitles) {
            Text(L10n.string("search.duplicates.merge", fallback: "Merge Duplicates"))
                .tag(true)
            Text(L10n.string("search.duplicates.separate", fallback: "Show Separately"))
                .tag(false)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(
            width: layout.mergeWidth,
            height: PrimaryToolbarMetrics.itemHeight
        )
        .help(
            mergesDuplicateTitles
                ? L10n.string("search.duplicates.merge.help", fallback: "Combine results with the same title and year into one card")
                : L10n.string("search.duplicates.separate.help", fallback: "Show a separate result for each provider")
        )
        .accessibilityLabel(L10n.string("search.duplicates.accessibility", fallback: "Duplicate Title Display"))
        .accessibilityValue(
            mergesDuplicateTitles
                ? L10n.string("search.duplicates.merge", fallback: "Merge Duplicates")
                : L10n.string("search.duplicates.separate", fallback: "Show Separately")
        )
    }

    @ViewBuilder
    private func searchSortControl(
        layout: SearchToolbarLayout
    ) -> some View {
        Picker(L10n.string("common.sort", fallback: "Sort"), selection: $sortOrder) {
            ForEach(SearchResultSortOrder.allCases) { option in
                Text(option.toolbarTitle).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(
            width: layout.sortWidth,
            height: PrimaryToolbarMetrics.itemHeight
        )
        .help(L10n.string("search.sort.help", fallback: "Sort: %@", sortOrder.title))
    }

    private func acceptLatestOrder() {
        state.searchBrowseMemory.presentation(for: browserKey).acceptOrder()
        acceptedOrderRevision &+= 1
    }

    private var browserKey: String {
        let source = state.selectedSearchSiteKey.map { "source:\($0)" } ?? "all"
        return "\(state.searchBrowseSessionID)/\(source)/\(sortOrder.rawValue)/\(mergesDuplicateTitles)"
    }

    private var searchResults: some View {
        let key = browserKey
        let presentation = state.searchBrowseMemory.presentation(for: key)
        let clusters = presentation.update(presentedClusters)
        let summaries = clusters.compactMap(\.primary)
        let sourceOptions = state.searchBrowseMemory.orderedSources(state.searchSiteOptions)
        let navigation = [BrowseCategoryNavigationItem(id: "all",
            title: L10n.string("search.filters.all", fallback: "All Results"), categoryID: nil)] +
            sourceOptions.map { BrowseCategoryNavigationItem(id: "source:\($0.key)",
                title: $0.name, selectionValue: $0.key,
                help: L10n.string("search.browse.provider-count", fallback: "%@: %d results", $0.name, $0.resultCount)) }
        let header = PosterNativeHeaderKey(categories: [], selectedCategoryID: nil,
            showsRecommendations: false, filterSelection: [:], navigationItems: navigation,
            navigationSelectedID: state.selectedSearchSiteKey.map { "source:\($0)" } ?? "all")
        var footer = state.searchPaginationFooter
        if presentation.hasPendingOrder {
            footer.hasPendingUpdate = true
            footer.statusText = nil
            footer.actionTitle = nil
        }
        return PosterNativePage(items: summaries, headerKey: header,
            headerHeight: HomeBrowseGridMetrics.headerHeight(hasFilters: false),
            activeFilters: [], footerKey: footer, nextPage: state.searchPaging.revision,
            initialAnchor: state.searchBrowseMemory.anchors[key],
            presentationRevision: acceptedOrderRevision,
            onCategorySelect: state.selectSearchSite, onFilterReset: { _ in }, onClearFilters: {},
            onAcceptUpdate: {
                presentation.acceptOrder()
                acceptedOrderRevision &+= 1
            },
            onBrowse: { anchor, atTop, _ in
                state.searchBrowseMemory.anchors[key] = anchor
                presentation.atTop = atTop
            },
            onLoad: { await state.loadMoreSearchResults() },
            onSelect: { summary in
                guard let cluster = clusters.first(where: { $0.primary?.id == summary.id }) else { return }
                if SearchClusterOpenPolicy.requiresSourceSelection(cluster) {
                    sourceSelectionCluster = cluster
                } else { state.openSearchResult(summary) }
            },
            cardPresentations: clusters.map {
                PosterNativeCardPresentation(id: $0.id,
                    subtitle: [$0.year, $0.sources.count == 1 ? $0.primary?.siteName : L10n.string("search.browse.sources", fallback: "%d sources", $0.sources.count)]
                        .compactMap { $0 }.joined(separator: " · "), sources: $0.sources)
            }, onSelectSource: state.openSearchResult,
            onManualLoad: { await state.loadMoreSearchResults(retry: true) })
        .id(key)
        .overlay {
            if summaries.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass", title: emptyStateTitle,
                    message: state.selectedSearchSiteKey == nil ? emptyStateMessage :
                        L10n.string("search.browse.source-empty", fallback: "This provider has no results yet. Check its search status or retry below."))
                    .padding(.top, HomeBrowseGridMetrics.headerHeight(hasFilters: false))
                    .allowsHitTesting(false)
            }
        }
        .background(AppSurfacePalette.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
    }

    private var visibleRawResults: [VideoSummary] {
        guard let selectedSiteKey = state.selectedSearchSiteKey else {
            return state.searchResults
        }
        return state.searchResults.filter { $0.siteKey == selectedSiteKey }
    }

    private var presentationInput: SearchPresentationInput {
        SearchPresentationInput(key: browserKey, items: visibleRawResults,
            keyword: state.activeSearchKeyword, mergesDuplicates: mergesDuplicateTitles, sortOrder: sortOrder)
    }

    private var presentedClusters: [SearchResultCluster] {
        projectionKey == browserKey ? projection : state.searchBrowseMemory.presentation(for: browserKey).displayed
    }

    private func openSearchSource(_ summary: VideoSummary) {
        sourceSelectionCluster = nil
        state.openSearchResult(summary)
    }

    private var emptyStateTitle: String {
        if state.activeSearchKeyword.isEmpty {
            return L10n.string("search.empty.start.title", fallback: "Search Movies and Shows")
        }
        return state.isSearching
            ? L10n.string("search.searching.title", fallback: "Searching")
            : L10n.string("search.empty.no-results.title", fallback: "No Results")
    }

    private var emptyStateMessage: String {
        if state.activeSearchKeyword.isEmpty {
            return L10n.string("search.empty.start.message", fallback: "Enter a title to search the enabled providers in the current scope.")
        }
        if state.isSearching {
            return L10n.string(
                "search.progress.message",
                fallback: "First pages: %d/%d providers. Finished: %d/%d. Results appear as they arrive.",
                state.searchFirstPageCompletedSiteCount,
                state.searchTotalSiteCount,
                state.searchCompletedSiteCount,
                state.searchTotalSiteCount
            )
        }
        return state.searchFailures.isEmpty
            ? emptyCompletionMessage
            : L10n.string("search.failures.no-results", fallback: "%d providers failed; the remaining providers returned no results.", state.searchFailures.count)
    }

    private var emptyCompletionMessage: String {
        switch state.searchTermination {
        case .deadlineReached:
            return L10n.string("search.completion.deadline", fallback: "The initial search finished; background pagination reached its time limit.")
        case .cancelled:
            return L10n.string("search.completion.cancelled", fallback: "Search stopped.")
        case .supersededByNewSearch:
            return L10n.string("search.completion.superseded", fallback: "A newer search replaced this search.")
        default:
            return L10n.string("search.completion.empty", fallback: "No providers in the current scope returned matching content.")
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
        HStack(spacing: PrimaryToolbarMetrics.itemSpacing) {
            BrowserToolbarBackButton(
                help: backHelp,
                identifier: "search.back",
                action: onBack
            )
            .frame(
                width: PrimaryToolbarMetrics.iconControlSize,
                height: PrimaryToolbarMetrics.iconControlSize
            )

            BrowserToolbarTitle(title)
                .lineLimit(1)
        }
        .frame(height: PrimaryToolbarMetrics.itemHeight)
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
            if termination == .cancelled
                || termination == .supersededByNewSearch {
                return SearchToolbarStatusPresentation(
                    phase: .stopped,
                    text: L10n.string("search.status.stopped", fallback: "Stopped"),
                    accessibilityValue: L10n.string("search.status.stopped-accessibility", fallback: "Search stopped")
                )
            }
            return SearchToolbarStatusPresentation(
                phase: .preparing,
                text: L10n.string("search.status.preparing", fallback: "Preparing"),
                accessibilityValue: L10n.string("search.status.preparing-accessibility", fallback: "Preparing search")
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
            text = L10n.string("search.status.expanded.searching", fallback: "First pages %d/%d · Finished %d/%d", firstPageCompleted, total, completed, total)
        case (.expanded, .completed):
            text = L10n.string("search.status.completed", fallback: "✓ Completed %d/%d", completed, total)
        case (.expanded, .stopped):
            text = L10n.string("search.status.stopped-count", fallback: "Stopped %d/%d", completed, total)
        case (.compact, .searching):
            text = L10n.string("search.status.finished-count", fallback: "Finished %d/%d", completed, total)
        case (.compact, .completed):
            text = L10n.string("search.status.completed", fallback: "✓ Completed %d/%d", completed, total)
        case (.compact, .stopped):
            text = L10n.string("search.status.stopped-count", fallback: "Stopped %d/%d", completed, total)
        case (.minimal, .stopped):
            text = L10n.string("search.status.stopped", fallback: "Stopped")
        case (.minimal, _):
            text = "\(completed)/\(total)"
        case (_, .preparing):
            text = L10n.string("search.status.preparing", fallback: "Preparing")
        }

        let accessibilityValue: String
        switch phase {
        case .preparing:
            accessibilityValue = L10n.string("search.status.preparing-accessibility", fallback: "Preparing search")
        case .searching:
            accessibilityValue = L10n.string("search.status.searching-accessibility", fallback: "First pages completed for %d of %d providers; %d of %d providers finished", firstPageCompleted, total, completed, total)
        case .completed:
            accessibilityValue = L10n.string("search.status.completed-accessibility", fallback: "Search completed; %d of %d providers processed", completed, total)
        case .stopped:
            accessibilityValue = L10n.string("search.status.stopped-count-accessibility", fallback: "Search stopped; %d of %d providers processed", completed, total)
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
            .help(L10n.string("search.status.details.help", fallback: "View search progress details"))
            .accessibilityLabel(L10n.string("search.status.progress", fallback: "Search Progress"))
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
            .help(L10n.string("search.stop", fallback: "Stop Search"))
        }
        .frame(
            width: layout.statusWidth,
            height: PrimaryToolbarMetrics.itemHeight,
            alignment: .trailing
        )
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
                    Text(L10n.string("search.status.title", fallback: "Search Status"))
                        .font(.headline)
                    Text(presentation.accessibilityValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(L10n.string("search.status.result-count", fallback: "%d results currently shown", resultCount))
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
                Text(L10n.string("search.status.provider-details", fallback: "Provider Details"))
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
            return L10n.string("search.retention.complete", fallback: "All provider results are retained")
        }
        return L10n.string("search.retention.limited", fallback: "Results are retained by relevance: %d total, up to %d per provider", maximumRetainedCandidates, maximumResultsPerSite)
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
            Picker(L10n.string("search.scope.title", fallback: "Search Scope"), selection: modeSelection) {
                Text(L10n.string("search.scope.all", fallback: "All Providers")).tag(SearchSiteScopeMode.all)
                Text(L10n.string("search.scope.custom", fallback: "Custom")).tag(SearchSiteScopeMode.custom)
            }
            .pickerStyle(.segmented)

            if mode == .custom {
                HStack(spacing: 8) {
                    Button(L10n.string("common.select-all", fallback: "Select All")) {
                        selectedKeys.formUnion(searchableKeys)
                    }
                    Button(L10n.string("common.clear", fallback: "Clear")) {
                        selectedKeys.subtract(searchableKeys)
                    }
                    Button(L10n.string("common.invert-selection", fallback: "Invert Selection")) {
                        let selected = selectedKeys.intersection(searchableKeys)
                        selectedKeys.subtract(searchableKeys)
                        selectedKeys.formUnion(searchableKeys.subtracting(selected))
                    }
                    Spacer()
                    Text(L10n.string("search.scope.selected-count", fallback: "%d of %d selected", selectedKeys.intersection(searchableKeys).count, searchableKeys.count))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .controlSize(.small)
            } else {
                Text(L10n.string("search.scope.all.note", fallback: "Every runnable provider in this configuration will be searched, including providers disabled for browsing. Choose Custom to exclude any provider."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField(L10n.string("search.scope.filter", fallback: "Filter provider names"), text: $filterText)
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
                                ? L10n.string("search.scope.disabled-all", fallback: "Disabled for browsing · Still searched in All mode")
                                : L10n.string("search.scope.disabled-custom", fallback: "Disabled for browsing · Can be enabled for search")
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
                Text(L10n.string("search.scope.title", fallback: "Search Scope"))
                    .font(.headline)
                Text(L10n.string("search.scope.sheet.note", fallback: "Only selected providers receive requests. Filtering result providers does not start a new search."))
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
                Button(L10n.string(.commonCancel)) { dismiss() }
                Spacer()
                if !hasValidSelection {
                    Text(L10n.string("search.scope.minimum-one", fallback: "A custom search scope requires at least one currently available provider."))
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button(
                    state.isSearching
                        ? L10n.string("search.scope.save-and-restart", fallback: "Save and Search Again")
                        : L10n.string("common.save", fallback: "Save")
                ) {
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
                    title: L10n.string("search.folder.failed.title", fallback: "Cloud Folder Failed to Load"),
                    message: errorMessage
                )

            }
        } else if page.isLoading, page.items.isEmpty {
            AppActivityLabel(L10n.string("search.folder.loading", fallback: "Opening cloud folder…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page.items.isEmpty {
            EmptyStateView(
                systemImage: "folder",
                title: L10n.string("search.folder.empty.title", fallback: "Empty Folder"),
                message: L10n.string("search.folder.empty.message", fallback: "This search result did not return any browsable cloud items.")
            )
        } else {
            let key = "folder:\(page.id)"
            PosterNativePage(items: page.items,
                headerKey: PosterNativeHeaderKey(categories: [], selectedCategoryID: nil,
                    showsRecommendations: false, filterSelection: [:]),
                headerHeight: HomeBrowseGridMetrics.contentPadding, activeFilters: [],
                footerKey: PosterNativeFooterKey(hasMore: page.pagination?.hasMore == true,
                    isLoading: page.isLoading, isRefreshing: false, errorMessage: page.errorMessage,
                    itemCount: page.items.count, hasPendingUpdate: false, issueKind: page.paginationIssueKind),
                nextPage: (page.pagination?.page ?? 0) + 1,
                initialAnchor: state.searchBrowseMemory.anchors[key], presentationRevision: 0,
                onCategorySelect: { _ in }, onFilterReset: { _ in }, onClearFilters: {}, onAcceptUpdate: {},
                onBrowse: { anchor, _, _ in state.searchBrowseMemory.anchors[key] = anchor },
                onLoad: { await state.loadNextSearchFolderPageAndWait() },
                onSelect: state.openSearchFolderItem,
                cardPresentations: page.items.map {
                    PosterNativeCardPresentation(id: $0.id,
                        subtitle: $0.isFolder ? L10n.string("search.folder.title", fallback: "Folder") : ($0.remarks ?? $0.siteName),
                        sources: [])
                })
                .id(page.id)

        }
    }
}

private extension SearchSiteOutcome {
    var title: String {
        switch self {
        case .success(_, let siteName, let resultCount):
            return resultCount == 0
                ? L10n.string("search.outcome.empty", fallback: "%@ · Search succeeded with no results", siteName)
                : L10n.string("search.outcome.success", fallback: "%@ · Search succeeded with %d results", siteName, resultCount)
        case .failure(let failure):
            return "\(failure.siteName) · \(failure.categoryTitle)"
        case .cancelled(_, let siteName):
            return L10n.string("search.outcome.cancelled", fallback: "%@ · Cancelled", siteName)
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
        case .unsupportedRoute: return L10n.string("search.failure.unsupported-route", fallback: "No Search Route")
        case .configurationRequired: return L10n.string("search.failure.configuration", fallback: "Configuration or Sign-In Required")
        case .scriptError: return L10n.string("search.failure.script", fallback: "Script Error")
        case .upstreamUnavailable: return L10n.string("search.failure.upstream", fallback: "Upstream Unavailable")
        case .timeout: return L10n.string("search.failure.timeout", fallback: "Search Timed Out")
        case .transport: return L10n.string("search.failure.transport", fallback: "Network Connection Failed")
        case .provider: return L10n.string("search.failure.provider", fallback: "Provider Error")
        }
    }
}

enum SearchResultSortOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case sourceCount
    case newest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return L10n.string("search.sort.relevance.title", fallback: "Relevance")
        case .sourceCount: return L10n.string("search.sort.source-count.title", fallback: "Number of Providers")
        case .newest: return L10n.string("search.sort.newest.title", fallback: "Newest Year")
        case .title: return L10n.string("search.sort.title.title", fallback: "Title")
        }
    }

    var toolbarTitle: String {
        switch self {
        case .relevance: return L10n.string("search.sort.relevance.toolbar", fallback: "Relevance")
        case .sourceCount: return L10n.string("search.sort.source-count.toolbar", fallback: "Providers")
        case .newest: return L10n.string("search.sort.newest.toolbar", fallback: "Newest")
        case .title: return L10n.string("search.sort.title.toolbar", fallback: "Title")
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
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 13) {
            if let primary = cluster.primary {
                VideoPosterView(item: primary)
                    .frame(width: 58, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("search.source.choose", fallback: "Choose a Provider"))
                    .font(.title3.weight(.semibold))
                Text(cluster.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(L10n.string("search.source.choose-message", fallback: "%d providers found. Choose one to view details.", cluster.sources.count))
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
            .help(L10n.string("search.source.close", fallback: "Close Provider Selection"))
            .accessibilityLabel(L10n.string("search.source.close", fallback: "Close Provider Selection"))
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

                Text(L10n.string("search.source.view-details", fallback: "View Details"))
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
        .accessibilityLabel(L10n.string("search.source.open-accessibility", fallback: "Open %@ from %@", source.title, source.siteName))
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
