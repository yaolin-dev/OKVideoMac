import AppKit
import SwiftUI
import OKVideoCore

private struct CategoryBrowsePresentationKey: Hashable {
    let query: CategoryQueryKey?
    let revision: UInt64
}

private struct HomePosterGridIdentity: Hashable {
    let configurationID: UUID?
    let siteKey: String?
    let query: CategoryQueryKey?
}

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
    }

    @ViewBuilder
    private var homeContent: some View {
        if !state.hasCompletedStartup && state.activeConfiguration == nil {
            AppActivityLabel(L10n.string("home.restoring-last-content", fallback: "Restoring your last content…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.activeConfiguration == nil {
            VStack(spacing: 18) {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: L10n.string("home.no-configuration.title", fallback: "No Video Provider Configuration"),
                    message: L10n.string("home.no-configuration.message", fallback: "Open Settings → Video Providers to import a configuration you are authorized to use from a URL, pasted content, or a local file.")
                )
                Button {
                    state.selectedSettingsPane = .configurations
                    state.selectSection(.settings)
                } label: {
                    Label(L10n.string("home.open-provider-settings", fallback: "Open Video Provider Settings"), systemImage: "gearshape")
                }
            }
        } else if state.visibleSites.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.slash",
                    title: L10n.string("home.no-visible-providers.title", fallback: "No Visible Providers"),
                    message: L10n.string("home.no-visible-providers.message", fallback: "The current configuration has no available providers, or all providers are hidden.")
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
                title: L10n.string("home.provider-unavailable.title", fallback: "Provider Unavailable"),
                message: L10n.string("home.provider-unavailable.message", fallback: "This provider cannot run on the current Mac version. Choose another provider from the toolbar.")
            )
        } else if let home = state.siteHome {
            if home.recommendations.isEmpty
                && mediaCategories.isEmpty
                && home.actionItems.isEmpty {
                if let message = state.homeLoadErrorMessage {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            systemImage: "wifi.exclamationmark",
                            title: L10n.string("provider.load.failed", fallback: "Provider Failed to Load"),
                            message: message
                        )

                    }
                } else {
                    EmptyStateView(
                        systemImage: "tray",
                        title: L10n.string("home.no-playable-content.title", fallback: "No Playable Content"),
                        message: L10n.string("home.no-playable-content.message", fallback: "Refresh to try again, or check the configuration and provider status.")
                    )
                }
            } else if state.homePresentationNeedsRecovery {
                homeRecoveryContent
            } else if let category = selectedCategory,
                      let page = state.categoryPage,
                      !page.items.isEmpty,
                      page.items.allSatisfy({ $0.resolvedContentKind == .media }),
                      home.actionItems.isEmpty,
                      !HomeItemPresentationPolicy.prefersCompactCards(page.items) {
                let tokens = HomeFilterPresentationPolicy.activeTokens(
                    filters: category.filters,
                    selection: filterSelection
                )
                let headerKey = PosterNativeHeaderKey(
                    categories: mediaCategories,
                    selectedCategoryID: state.selectedCategoryID,
                    showsRecommendations: !home.recommendations.isEmpty,
                    filterSelection: filterSelection
                )
                let footerKey = PosterNativeFooterKey(
                    hasMore: page.pagination.hasMore,
                    isLoading: state.isLoadingNextCategoryPage,
                    isRefreshing: state.isLoading,
                    errorMessage: state.categoryPaginationError,
                    itemCount: page.items.count,
                    hasPendingUpdate: state.categoryHasPendingUpdate,
                    issueKind: state.categoryPaginationIssueKind
                )
                PosterNativePage(
                    items: page.items,
                    headerKey: headerKey,
                    headerHeight: HomeBrowseGridMetrics.headerHeight(hasFilters: !tokens.isEmpty),
                    activeFilters: tokens,
                    footerKey: footerKey,
                    nextPage: page.pagination.page + 1,
                    initialAnchor: state.categoryBrowseAnchor,
                    presentationRevision: state.categoryPresentationRevision,
                    onCategorySelect: { categoryID in
                        selectHomeCategory(categoryID,
                            categories: mediaCategories)
                    },
                    onFilterReset: { filterID in
                        let selection = HomeFilterPresentationPolicy.resetting(
                            filterID: filterID,
                            filters: category.filters,
                            selection: filterSelection)
                        filterSelection = selection
                        scheduleFilterLoad(categoryID: category.id,
                            filters: selection)
                    },
                    onClearFilters: {
                        let selection = HomeFilterPresentationPolicy.defaultSelection(
                            filters: category.filters)
                        filterSelection = selection
                        scheduleFilterLoad(categoryID: category.id,
                            filters: selection)
                    },
                    onAcceptUpdate: { state.acceptCategoryUpdate() },
                    onBrowse: { anchor, atTop, interacted in
                        if let key = state.categoryBrowsingKey {
                            state.recordCategoryViewport(for: key,
                                anchor: anchor, atTop: atTop,
                                interacted: interacted)
                        }
                    },
                    onLoad: {
                        await state.loadCategory(id: category.id,
                            page: page.pagination.page + 1,
                            filters: filterSelection)
                    },
                    onSelect: { summary in
                        Task { await state.openHomeItem(summary) }
                    }
                )
                .id(HomePosterGridIdentity(
                    configurationID: state.activeConfigurationRecord?.id,
                    siteKey: state.selectedSiteKey,
                    query: state.categoryBrowsingKey
                ))
                .onAppear(perform: synchronizeFilterSelection)
                .onChange(of: state.selectedCategoryID) { _ in
                    synchronizeFilterSelection()
                }
                .onChange(of: state.selectedCategoryFilters) { _ in
                    synchronizeFilterSelection()
                }
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        HomeBrowseScrollContent(coordinateSpaceName: categoryScrollCoordinateSpace) {
                            if !home.recommendations.isEmpty
                                || !mediaCategories.isEmpty {
                                VStack(spacing: 0) {
                                    HomeCategoryNavigation(
                                        showsRecommendations:
                                            !home.recommendations.isEmpty,
                                        categories: mediaCategories,
                                        selectedCategoryID:
                                            state.selectedCategoryID,
                                        isRecommendationSelected:
                                            state.homePresentationSelection
                                                == .recommendation
                                    ) { categoryID in
                                        selectHomeCategory(
                                            categoryID,
                                            categories: mediaCategories
                                        )
                                    }
                                    BrowseSegmentedNavigationBottomDivider()
                                }
                            }
                            if !home.actionItems.isEmpty {
                                Text(L10n.string("home.actions", fallback: "Actions"))
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
                                if let page = state.categoryPage {
                                    if page.items.isEmpty {
                                        Text(L10n.string("home.category.empty", fallback: "No titles in this category."))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, minHeight: 180)
                                    } else {
                                        homeItemGrid(page.items)
                                    }
                                    HomePaginationFooter(
                                        hasMore: page.pagination.hasMore,
                                        isLoading: state.isLoadingNextCategoryPage,
                                        isRefreshing: state.isLoading,
                                        errorMessage: state.categoryPaginationError,
                                        itemCount: page.items.count,
                                        viewportHeight: viewport.size.height,
                                        coordinateSpaceName: categoryScrollCoordinateSpace,
                                        nextPage: page.pagination.page + 1,
                                        issueKind: state.categoryPaginationIssueKind,
                                        hasPendingUpdate: state.categoryHasPendingUpdate,
                                        onAcceptUpdate: { state.acceptCategoryUpdate() }
                                    ) {
                                        await state.loadCategory(id: category.id, page: page.pagination.page + 1, filters: filterSelection)
                                    }
                                    .id(CategoryBrowsePresentationKey(query: state.categoryBrowsingKey, revision: state.categoryPresentationRevision))
                                } else if state.isLoading
                                    || state.isRecoveringHome {
                                    PosterInitialSkeleton(
                                        width: max(0, viewport.size.width - HomeBrowseGridMetrics.contentPadding * 2),
                                        height: max(0, viewport.size.height - 70)
                                    )
                                } else if let message = state.homeLoadErrorMessage {
                                    categoryRecoveryError(
                                        message: message
                                    )
                                } else {
                                    AppActivityLabel(L10n.string("home.loading-categories", fallback: "Loading categories…"))
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
                    }
                    .browserToolbarScrollSurface(
                        named: categoryScrollCoordinateSpace
                    )
                    .overlay(alignment: .topTrailing) {
                        if state.categoryHasPendingUpdate {
                            Button(L10n.string("home.category.view-update", fallback: "Content Updated — View")) {
                                state.acceptCategoryUpdate()
                            }
                            .buttonStyle(.bordered)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(10)
                        }
                    }
                }
                .onAppear(perform: synchronizeFilterSelection)
                .onChange(of: state.selectedCategoryID) { _ in
                    synchronizeFilterSelection()
                }
                .onChange(of: state.selectedCategoryFilters) { _ in
                    synchronizeFilterSelection()
                }
            }
        } else if state.isHomeLoading || !state.hasCompletedStartup {
            AppActivityLabel(L10n.string("home.loading-provider", fallback: "Loading provider…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = state.homeLoadErrorMessage {
            EmptyStateView(
                systemImage: state.homeLoadErrorIsLocalPluginCache
                    ? "externaldrive.badge.exclamationmark"
                    : "wifi.exclamationmark",
                title: state.homeLoadErrorIsLocalPluginCache
                    ? L10n.string("home.dex-cache-failed.title", fallback: "Local Plugin Cache Failed")
                    : L10n.string("home.provider-temporarily-unavailable.title", fallback: "Provider Temporarily Unavailable"),
                message: L10n.string("home.provider-temporarily-unavailable.message", fallback: "Your local configuration was preserved. Use Refresh in the upper-right corner to try again.\n%@", message)
            )
        } else {
            EmptyStateView(
                systemImage: "arrow.clockwise",
                title: L10n.string("home.not-loaded.title", fallback: "Not Loaded"),
                message: L10n.string("home.not-loaded.message", fallback: "Choose a provider or select Refresh.")
            )
        }
    }

    @ViewBuilder
    private var homeRecoveryContent: some View {
        if state.isRecoveringHome || state.isHomeLoading || state.isLoading {
            AppActivityLabel(L10n.string("home.restoring", fallback: "Restoring Home…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = state.homeLoadErrorMessage {
            VStack(spacing: 14) {
                EmptyStateView(
                    systemImage: "arrow.clockwise.circle",
                    title: L10n.string("home.recovery.title", fallback: "Home Needs to Be Restored"),
                    message: message
                )
                Button(L10n.string("common.retry", fallback: "Try Again")) {
                    Task {
                        await state.resumeHomeIfNeeded(reportErrors: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AppActivityLabel(L10n.string("home.restoring", fallback: "Restoring Home…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await state.resumeHomeIfNeeded()
                }
        }
    }

    private func categoryRecoveryError(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("home.categories.failed", fallback: "Categories Failed to Load"), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            Button(L10n.string("common.retry", fallback: "Try Again")) {
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

    private func selectHomeCategory(
        _ categoryID: String?,
        categories: [VideoCategory]
    ) {
        guard let categoryID,
              let category = categories.first(where: {
                  $0.id == categoryID
              }) else {
            filterSelection = [:]
            state.clearCategory()
            return
        }
        Task {
            await state.loadCategory(id: category.id)
        }
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
                let browseKey = state.categoryBrowsingKey
                VideoGrid(items: mediaItems, initialAnchor: state.categoryBrowseAnchor,
                          presentationRevision: state.categoryPresentationRevision,
                          onBrowse: { anchor, atTop, interacted in
                    if let browseKey { state.recordCategoryViewport(for: browseKey, anchor: anchor, atTop: atTop, interacted: interacted) }
                }) { summary in
                    Task { await state.openHomeItem(summary) }
                }
                .id(HomePosterGridIdentity(configurationID: state.activeConfigurationRecord?.id,
                                           siteKey: state.selectedSiteKey, query: browseKey))
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
                            Text(L10n.string("home.filter.token", fallback: "%@: %@", token.filterName, token.optionName))
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.string("home.filter.remove", fallback: "Remove filter: %@, %@", token.filterName, token.optionName))
                }

                Button(L10n.string("home.filter.clear", fallback: "Clear Filters")) {
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
        state.scheduleCategoryFilterLoad(id: categoryID, filters: filters)
    }
}

private enum HomeContentAlignment {
    static let visualLeadingInset: CGFloat = 8
}

/// One shared horizontal rhythm for the category strip, filter rows, and card
/// grid. The filter labels stay on the cards' visible leading edge while every
/// category cell starts on the same column as its corresponding filter chip.
/// The observer is a background, so a zero-height bridge cannot introduce
/// ScrollView's implicit spacing above the category row.
struct HomeBrowseScrollContent<Content: View>: View {
    let coordinateSpaceName: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: HomeBrowseGridMetrics.sectionSpacing) {
            content
        }
        .padding(.horizontal, HomeBrowseGridMetrics.contentPadding)
        .padding(.bottom, HomeBrowseGridMetrics.contentPadding)
        .background(alignment: .top) {
            BrowserToolbarScrollMarker(coordinateSpaceName: coordinateSpaceName)
        }
    }
}

enum HomeBrowseGridMetrics {
    static let categoryRowHeight: CGFloat = 64
    static let sectionSpacing: CGFloat = 20
    static let dividerHeight: CGFloat = 0.5
    static func headerHeight(hasFilters: Bool) -> CGFloat {
        categoryRowHeight + dividerHeight + sectionSpacing
            + (hasFilters ? chipHeight + sectionSpacing : 0)
    }
    static let contentPadding: CGFloat = 16
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

struct HomeCategoryNavigationCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let width: CGFloat
}

struct HomeCategoryNavigationPartition: Equatable, Sendable {
    let visibleIDs: [String]
    let hiddenIDs: [String]
}

enum HomeCategoryNavigationLayoutPolicy {
    static let recommendationID = "__home-recommendations__"

    static func partition(
        candidates: [HomeCategoryNavigationCandidate],
        selectedID: String?,
        availableWidth: CGFloat,
        spacing: CGFloat = BrowseSegmentedNavigationMetrics.separatorWidth,
        containerInset: CGFloat = BrowseSegmentedNavigationMetrics.containerInset,
        moreWidth: CGFloat = BrowseSegmentedNavigationMetrics.moreWidth
    ) -> HomeCategoryNavigationPartition {
        guard !candidates.isEmpty else {
            return HomeCategoryNavigationPartition(
                visibleIDs: [],
                hiddenIDs: []
            )
        }
        let availableWidth = max(0, availableWidth - containerInset * 2)
        let allWidth = candidates.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, candidates.count - 1))
        if allWidth <= availableWidth {
            return HomeCategoryNavigationPartition(
                visibleIDs: candidates.map(\.id),
                hiddenIDs: []
            )
        }

        let tabBudget = max(
            0,
            availableWidth
                - moreWidth
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

        if let selectedID,
           !visible.contains(selectedID),
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
                visible = [selected.id]
            }
        }

        let visibleSet = Set(visible)
        return HomeCategoryNavigationPartition(
            visibleIDs: visible,
            hiddenIDs: candidates.compactMap {
                visibleSet.contains($0.id) ? nil : $0.id
            }
        )
    }
}

private struct HomeCategoryNavigation: View {
    let showsRecommendations: Bool
    let categories: [VideoCategory]
    let selectedCategoryID: String?
    let isRecommendationSelected: Bool
    let onSelect: (String?) -> Void

    private var items: [Item] {
        let recommendations = showsRecommendations
            ? [Item(
                id: HomeCategoryNavigationLayoutPolicy.recommendationID,
                title: L10n.string("home.recommended", fallback: "Recommended"),
                categoryID: nil
            )]
            : []
        return recommendations + categories.map {
            Item(id: $0.id, title: $0.name, categoryID: $0.id)
        }
    }

    private var selectedID: String? {
        if let selectedCategoryID { return selectedCategoryID }
        return isRecommendationSelected && showsRecommendations
            ? HomeCategoryNavigationLayoutPolicy.recommendationID
            : nil
    }

    var body: some View {
        NativeBrowseCategoryNavigationRepresentable(items: items, selectedID: selectedID, onSelect: onSelect)
            .padding(.leading, HomeBrowseGridMetrics.categoryLeadingInset)
            .padding(.trailing, 8)
            .frame(height: HomeBrowseGridMetrics.categoryRowHeight)
    }

    private typealias Item = BrowseCategoryNavigationItem
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
        CategoryFilterCanonicalizer.canonicalSelection(
            filters: filters,
            selection: [:]
        )
    }

    static func normalizedSelection(
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [String: String] {
        CategoryFilterCanonicalizer.canonicalSelection(
            filters: filters,
            selection: selection
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
                    Label(L10n.string("home.filter.reset", fallback: "Reset Filters"), systemImage: "arrow.counterclockwise")
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
                            Text(L10n.string("home.filter.more-count", fallback: "%d More", hiddenOptions.count))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(FilterChipButtonStyle(isSelected: false))
                    .help(L10n.string("home.filter.more-options.help", fallback: "Show %d more options for “%@”", hiddenOptions.count, filter.name))
                    .accessibilityLabel(L10n.string("home.filter.more-options.accessibility", fallback: "%@, %d more options", filter.name, hiddenOptions.count))
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
        .help(L10n.string("home.filter.option", fallback: "%@: %@", filter.name, option.name))
        .accessibilityLabel(L10n.string("home.filter.option-accessibility", fallback: "%@, %@", filter.name, option.name))
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
                TextField(L10n.string("home.filter.search-options", fallback: "Search %@ options", filterName), text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                if filteredOptions.isEmpty {
                    Text(L10n.string("home.filter.no-options", fallback: "No Matching Options"))
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
                            .accessibilityLabel(L10n.string("home.filter.option-accessibility", fallback: "%@, %@", filterName, option.name))
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

typealias HomeToolbarLayout = PrimaryToolbarLayout

enum HomeToolbarLayoutPolicy {
    static func layout(contentWidth: CGFloat) -> HomeToolbarLayout {
        PrimaryToolbarLayoutPolicy.layout(contentWidth: contentWidth)
    }
}

struct HomeSiteToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    var body: some View {
        if !state.visibleSites.isEmpty {
            switch layout {
            case .expanded, .compact:
                Picker(L10n.string("common.provider", fallback: "Provider"), selection: selection) {
                    ForEach(state.visibleSites) { site in
                        Text(displayName(for: site))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(site.key)
                    }
                }
                .labelsHidden()
                .frame(width: layout.sitePickerWidth)
                .controlSize(.regular)
                .help(siteHelp)
                .accessibilityLabel(L10n.string("home.provider.choose", fallback: "Choose Content Provider"))

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
                }
                .primaryToolbarMenuControl()
                .help(siteHelp)
                .accessibilityLabel(L10n.string("home.provider.choose", fallback: "Choose Content Provider"))
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
        let currentName = state.currentSite.map(displayName(for:))
            ?? L10n.string("common.not-selected", fallback: "Not Selected")
        return L10n.string("home.provider.current", fallback: "Current provider: %@; %d providers available", currentName, state.visibleSites.count)
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
            Image(systemName: "line.3.horizontal.decrease.circle")
                .overlay(alignment: .topTrailing) {
                    if activeCount > 0 {
                        Text("\(min(activeCount, 9))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color.accentColor))
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .primaryToolbarIconControl(isSelected: activeCount > 0)
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
            isPresented = false
        }
    }

    private var filterHelp: String {
        guard category?.filters.isEmpty == false else {
            return L10n.string("home.filter.none", fallback: "This category has no filters")
        }
        return activeCount == 0
            ? L10n.string("home.filter.current", fallback: "Filter Current Category")
            : L10n.string("home.filter.current-active", fallback: "Filter Current Category; %d active", activeCount)
    }

    private func scheduleFilterLoad(
        categoryID: String,
        filters: [String: String]
    ) {
        state.scheduleCategoryFilterLoad(id: categoryID, filters: filters)
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
                Text(L10n.string("home.filter.title", fallback: "Filters"))
                    .font(.headline)
                Spacer()
                if activeCount > 0 {
                    Button(L10n.string("common.reset", fallback: "Reset")) {
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
    let layout: HomeToolbarLayout

    var body: some View {
        if !state.configurations.isEmpty {
            switch layout {
            case .expanded, .compact:
                Picker(L10n.string("common.configuration", fallback: "Configuration"), selection: selection) {
                    ForEach(state.configurations) { record in
                        Text(record.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(record.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: layout.configurationPickerWidth)
                .disabled(state.isSwitchingConfiguration)
                .help(configurationStatusHelp)
                .accessibilityLabel(configurationStatusHelp)

            case .minimal:
                Menu {
                    ForEach(state.configurations) { record in
                        Button {
                            Task {
                                await state.activateConfiguration(record.id)
                            }
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
                .primaryToolbarMenuControl()
                .help(configurationStatusHelp)
                .accessibilityLabel(configurationStatusHelp)
            }
        }
    }

    private var selection: Binding<UUID> {
        Binding(
            get: {
                state.configurationMenuSelectionID
                    ?? state.configurations[0].id
            },
            set: { id in
                Task { await state.activateConfiguration(id) }
            }
        )
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
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.secondary)
        }
    }

    private var configurationStatusHelp: String {
        switch state.configurationSwitchFeedback {
        case .switching(_, let name):
            return L10n.string("home.configuration.switching", fallback: "Switching to %@", name)
        case .success(_, let name):
            return L10n.string("home.configuration.switched", fallback: "Switched to %@", name)
        case .failure(_, let name, let message):
            return L10n.string("home.configuration.failed", fallback: "Could not switch to %@: %@", name, message)
        case .idle:
            return L10n.string("home.configuration.switch", fallback: "Switch Video Provider Configuration")
        }
    }
}

struct HomeRefreshToolbarItem: View {
    @EnvironmentObject private var state: AppState
    let layout: HomeToolbarLayout

    var body: some View {
        BrowserRefreshToolbarControl(
            isLoading: state.isLoading || state.isHomeLoading || state.isLoadingNextCategoryPage,
            error: state.homeLoadErrorMessage ?? state.categoryPaginationError,
            action: { Task { await state.refreshHomePage() } }
        )
        .disabled(state.currentSite == nil)

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
                    Text(L10n.string("home.configuration.switching-ellipsis", fallback: "Switching to %@…", name))
                }
                .accessibilityLabel(L10n.string("home.configuration.switching", fallback: "Switching to %@", name))
            case .success(_, let name):
                if compact {
                    Label(L10n.string("home.configuration.switched-short", fallback: "Switched"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .help(L10n.string("home.configuration.switched", fallback: "Switched to %@", name))
                        .accessibilityLabel(Text(L10n.string("home.configuration.switched", fallback: "Switched to %@", name)))
                } else {
                    Label(
                        L10n.string("home.configuration.switched", fallback: "Switched to %@", name),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundColor(.green)
                }
            case .failure(_, let name, let message):
                if compact {
                    Label(
                        L10n.string("home.configuration.failed-short", fallback: "Switch Failed"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(.red)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .help(L10n.string("home.configuration.failed", fallback: "Could not switch to %@: %@", name, message))
                    .accessibilityLabel(
                        Text(L10n.string("home.configuration.failed", fallback: "Could not switch to %@: %@", name, message))
                    )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            L10n.string("home.configuration.failed-accessibility", fallback: "Failed to switch to %@", name),
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
    @EnvironmentObject private var state: AppState
    let item: SiteActionItem
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                            Text(L10n.string("home.action-menu", fallback: "Provider Actions"))
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
            .disabled(state.isTVBoxConfigurationActionPending(item))
            .accessibilityLabel(L10n.string("home.action-accessibility", fallback: "Action: %@", item.title))
            TVBoxActionProgressControls(item: item)
                .padding(.horizontal, 12)
        }
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
                        Text(
                            summary.isFolder
                                ? L10n.string("common.folder", fallback: "Folder")
                                : L10n.string("home.content-entry", fallback: "Content")
                        )
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
            ? L10n.string("home.provider.unavailable-name", fallback: "%@ (Unavailable)", siteName)
            : siteName
    }
}
