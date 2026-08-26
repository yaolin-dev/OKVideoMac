import Foundation

public struct SearchFailure: Equatable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var message: String

    public init(siteKey: String, siteName: String, message: String) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.message = message
    }
}

public enum MultiSiteSearchTermination: String, Equatable, Sendable {
    case completed
    case completedWithProviderFailures
    case deadlineReached
    case cancelled
    case supersededByNewSearch
}

public struct MultiSiteSearchSnapshot: Equatable, Sendable {
    public var items: [VideoSummary]
    public var receivedCandidateCount: Int
    public var maximumRetainedCandidates: Int
    public var maximumResultsPerSite: Int
    public var didDiscardCandidates: Bool

    public init(
        items: [VideoSummary],
        receivedCandidateCount: Int,
        maximumRetainedCandidates: Int,
        maximumResultsPerSite: Int,
        didDiscardCandidates: Bool
    ) {
        self.items = items
        self.receivedCandidateCount = receivedCandidateCount
        self.maximumRetainedCandidates = maximumRetainedCandidates
        self.maximumResultsPerSite = maximumResultsPerSite
        self.didDiscardCandidates = didDiscardCandidates
    }
}

public enum MultiSiteSearchEvent: Equatable, Sendable {
    case snapshot(MultiSiteSearchSnapshot)
    case failure(SearchFailure)
    case siteFirstPageCompleted(siteKey: String)
    case siteCompleted(siteKey: String)
    case finished(MultiSiteSearchTermination)
}

/// Per-provider aggregate-search limits. Providers that share one runtime can
/// use a common group to avoid flooding that runtime without slowing unrelated
/// native/Jar/Dex providers.
public struct MultiSiteSearchProviderPolicy: Equatable, Sendable {
    public var concurrencyGroup: String?
    public var maximumGroupConcurrency: Int?
    public var maximumPagesPerSite: Int?

    public init(
        concurrencyGroup: String? = nil,
        maximumGroupConcurrency: Int? = nil,
        maximumPagesPerSite: Int? = nil
    ) {
        self.concurrencyGroup = concurrencyGroup
        self.maximumGroupConcurrency = maximumGroupConcurrency.map { max(1, $0) }
        self.maximumPagesPerSite = maximumPagesPerSite.map { max(1, $0) }
    }
}

private enum PageSearchOutcome: Sendable {
    case page(VideoPage, keyword: String)
    case failure(String)
    case deadlineReached
    case cancelled
}

private actor FirstPageSearchOutcome {
    private var bufferedOutcome: PageSearchOutcome?
    private var waiter: CheckedContinuation<PageSearchOutcome, Never>?
    private var isResolved = false

    func wait() async -> PageSearchOutcome {
        if let bufferedOutcome {
            self.bufferedOutcome = nil
            return bufferedOutcome
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ outcome: PageSearchOutcome) {
        guard !isResolved else { return }
        isResolved = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: outcome)
        } else {
            bufferedOutcome = outcome
        }
    }
}

private struct InitialPageResult: Sendable {
    var providerIndex: Int
    var outcome: PageSearchOutcome
}

private struct BackgroundSearchState: Sendable {
    var providerIndex: Int
    var keyword: String
    var nextPage: Int
    var explicitPageCount: Int?
    var seenIDs: Set<String>
    var candidateCount: Int
    var relevance: FirstPageRelevance
}

private struct BackgroundSearchResult: Sendable {
    var providerIndex: Int
    var items: [VideoSummary]
    var failureMessage: String?
    var reachedDeadline: Bool
}

private struct FirstPageRelevance: Comparable, Sendable {
    var exactCount = 0
    var prefixCount = 0
    var containsCount = 0
    var totalCount = 0

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.exactCount != rhs.exactCount {
            return lhs.exactCount < rhs.exactCount
        }
        if lhs.prefixCount != rhs.prefixCount {
            return lhs.prefixCount < rhs.prefixCount
        }
        if lhs.containsCount != rhs.containsCount {
            return lhs.containsCount < rhs.containsCount
        }
        return lhs.totalCount < rhs.totalCount
    }
}

private enum SearchMatchTier: Int, Comparable, Sendable {
    case unrelated = 0
    case relaxedContains = 1
    case strictContains = 2
    case relaxedPrefix = 3
    case strictPrefix = 4
    case relaxedExact = 5
    case strictExact = 6

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct RetainedSearchCandidate: Sendable {
    var item: VideoSummary
    var tier: SearchMatchTier
    var arrivalOrder: Int
}

private struct SearchCandidatePool: Sendable {
    let keyword: String
    let maximumRetainedCandidates: Int
    let maximumResultsPerSite: Int

    private var candidates: [String: RetainedSearchCandidate] = [:]
    private var siteCounts: [String: Int] = [:]
    private var seenCandidateIDs: Set<String> = []
    private var nextArrivalOrder = 0
    private(set) var receivedCandidateCount = 0
    private(set) var didDiscardCandidates = false

    init(
        keyword: String,
        maximumRetainedCandidates: Int,
        maximumResultsPerSite: Int
    ) {
        self.keyword = keyword
        self.maximumRetainedCandidates = maximumRetainedCandidates
        self.maximumResultsPerSite = maximumResultsPerSite
    }

    var snapshot: MultiSiteSearchSnapshot {
        MultiSiteSearchSnapshot(
            items: candidates.values.sorted(by: orderedBefore).map(\.item),
            receivedCandidateCount: receivedCandidateCount,
            maximumRetainedCandidates: maximumRetainedCandidates,
            maximumResultsPerSite: maximumResultsPerSite,
            didDiscardCandidates: didDiscardCandidates
        )
    }

    mutating func ingest(_ items: [VideoSummary]) -> Bool {
        let previousIDs = Set(candidates.keys)
        let wasDiscarding = didDiscardCandidates

        receivedCandidateCount += items.count
        for item in items {
            let candidateID = item.id
            guard seenCandidateIDs.insert(candidateID).inserted else { continue }

            let candidate = RetainedSearchCandidate(
                item: item,
                tier: Self.matchTier(title: item.title, keyword: keyword),
                arrivalOrder: nextArrivalOrder
            )
            nextArrivalOrder += 1
            retain(candidate, id: candidateID)
        }

        return previousIDs != Set(candidates.keys)
            || wasDiscarding != didDiscardCandidates
    }

    func retainedCount(for siteKey: String) -> Int {
        siteCounts[siteKey, default: 0]
    }

    private mutating func retain(
        _ incoming: RetainedSearchCandidate,
        id: String
    ) {
        let siteKey = incoming.item.siteKey
        let incomingSiteCount = siteCounts[siteKey, default: 0]

        if incomingSiteCount >= maximumResultsPerSite {
            guard let worstSameSite = worstCandidateID(siteKey: siteKey),
                  let retained = candidates[worstSameSite],
                  incoming.tier > retained.tier else {
                didDiscardCandidates = true
                return
            }
            removeCandidate(id: worstSameSite)
            insertCandidate(incoming, id: id)
            didDiscardCandidates = true
            return
        }

        if candidates.count < maximumRetainedCandidates {
            insertCandidate(incoming, id: id)
            return
        }

        guard let worstID = worstCandidateID(),
              let worst = candidates[worstID] else {
            didDiscardCandidates = true
            return
        }
        let worstSiteCount = siteCounts[worst.item.siteKey, default: 0]
        let improvesRelevance = incoming.tier > worst.tier
        let improvesDiversity = incoming.tier == worst.tier
            && incomingSiteCount + 1 < worstSiteCount
        guard improvesRelevance || improvesDiversity else {
            didDiscardCandidates = true
            return
        }

        removeCandidate(id: worstID)
        insertCandidate(incoming, id: id)
        didDiscardCandidates = true
    }

    private mutating func insertCandidate(
        _ candidate: RetainedSearchCandidate,
        id: String
    ) {
        candidates[id] = candidate
        siteCounts[candidate.item.siteKey, default: 0] += 1
    }

    private mutating func removeCandidate(id: String) {
        guard let removed = candidates.removeValue(forKey: id) else { return }
        let siteKey = removed.item.siteKey
        let count = siteCounts[siteKey, default: 0] - 1
        if count > 0 {
            siteCounts[siteKey] = count
        } else {
            siteCounts.removeValue(forKey: siteKey)
        }
    }

    private func worstCandidateID(siteKey: String? = nil) -> String? {
        candidates.lazy
            .filter { siteKey == nil || $0.value.item.siteKey == siteKey }
            .min { lhs, rhs in
                worseThan(lhs.value, rhs.value)
            }?
            .key
    }

    private func worseThan(
        _ lhs: RetainedSearchCandidate,
        _ rhs: RetainedSearchCandidate
    ) -> Bool {
        if lhs.tier != rhs.tier {
            return lhs.tier < rhs.tier
        }
        let lhsSiteCount = siteCounts[lhs.item.siteKey, default: 0]
        let rhsSiteCount = siteCounts[rhs.item.siteKey, default: 0]
        if lhsSiteCount != rhsSiteCount {
            return lhsSiteCount > rhsSiteCount
        }
        return lhs.arrivalOrder > rhs.arrivalOrder
    }

    private func orderedBefore(
        _ lhs: RetainedSearchCandidate,
        _ rhs: RetainedSearchCandidate
    ) -> Bool {
        if lhs.tier != rhs.tier {
            return lhs.tier > rhs.tier
        }
        return lhs.arrivalOrder < rhs.arrivalOrder
    }

    static func relevance(
        of items: [VideoSummary],
        keyword: String
    ) -> FirstPageRelevance {
        var relevance = FirstPageRelevance(totalCount: items.count)
        for item in items {
            switch matchTier(title: item.title, keyword: keyword) {
            case .strictExact, .relaxedExact:
                relevance.exactCount += 1
            case .strictPrefix, .relaxedPrefix:
                relevance.prefixCount += 1
            case .strictContains, .relaxedContains:
                relevance.containsCount += 1
            case .unrelated:
                break
            }
        }
        return relevance
    }

    private static func matchTier(
        title: String,
        keyword: String
    ) -> SearchMatchTier {
        let strictTitle = SearchTitleNormalizer.strictKey(title)
        let strictKeyword = SearchTitleNormalizer.strictKey(keyword)
        guard !strictKeyword.isEmpty else { return .unrelated }
        if strictTitle == strictKeyword { return .strictExact }
        if strictTitle.hasPrefix(strictKeyword) { return .strictPrefix }
        if strictTitle.contains(strictKeyword) { return .strictContains }

        let relaxedTitle = SearchTitleNormalizer.comparisonKey(title)
        let relaxedKeyword = SearchTitleNormalizer.comparisonKey(keyword)
        guard !relaxedKeyword.isEmpty else { return .unrelated }
        if relaxedTitle == relaxedKeyword { return .relaxedExact }
        if relaxedTitle.hasPrefix(relaxedKeyword) { return .relaxedPrefix }
        if relaxedTitle.contains(relaxedKeyword) { return .relaxedContains }
        return .unrelated
    }

    static func hasMeaningfulMatch(
        in items: [VideoSummary],
        keyword: String
    ) -> Bool {
        items.contains { matchTier(title: $0.title, keyword: keyword) != .unrelated }
    }
}

public struct MultiSiteSearch {
    public let maximumConcurrency: Int
    public let siteTimeout: TimeInterval
    public let overallDeadline: TimeInterval
    public let maximumPagesPerSite: Int
    public let maximumResultsPerSite: Int
    public let maximumRetainedCandidates: Int
    public let maximumDeepPageSites: Int

    public init(
        maximumConcurrency: Int = 12,
        siteTimeout: TimeInterval = 20,
        overallDeadline: TimeInterval = 25,
        maximumPagesPerSite: Int = 3,
        maximumResultsPerSite: Int = 40,
        maximumRetainedCandidates: Int = 500,
        maximumDeepPageSites: Int = 12
    ) {
        self.maximumConcurrency = max(1, maximumConcurrency)
        self.siteTimeout = max(0.05, siteTimeout)
        self.overallDeadline = max(0.05, overallDeadline)
        self.maximumPagesPerSite = max(1, maximumPagesPerSite)
        self.maximumResultsPerSite = max(1, maximumResultsPerSite)
        self.maximumRetainedCandidates = max(1, maximumRetainedCandidates)
        self.maximumDeepPageSites = max(0, maximumDeepPageSites)
    }

    public func search(
        providers: [SiteProvider],
        keyword: String,
        quick: Bool = false,
        providerPolicies: [String: MultiSiteSearchProviderPolicy] = [:]
    ) -> AsyncStream<MultiSiteSearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                let enabled = providers.filter { $0.site.searchable == 1 }
                let deadline = Date().addingTimeInterval(overallDeadline)
                var pool = SearchCandidatePool(
                    keyword: keyword,
                    maximumRetainedCandidates: maximumRetainedCandidates,
                    maximumResultsPerSite: maximumResultsPerSite
                )
                var backgroundStates: [BackgroundSearchState] = []
                var providerFailureCount = 0
                var reachedDeadline = false

                // Page one is progressive, but bounded. Providers sharing a
                // constrained runtime (for example CatPawOpen's Node process)
                // can declare a tighter group limit while unrelated providers
                // retain the normal desktop concurrency budget.
                await withTaskGroup(of: InitialPageResult.self) { group in
                    var pendingIndexes = Array(enabled.indices)
                    var activeCount = 0
                    var activeGroupCounts: [String: Int] = [:]

                    func canStart(_ index: Int) -> Bool {
                        guard activeCount < maximumConcurrency else { return false }
                        guard let policy = providerPolicies[enabled[index].site.key],
                              let groupKey = policy.concurrencyGroup,
                              let groupLimit = policy.maximumGroupConcurrency else {
                            return true
                        }
                        return activeGroupCounts[groupKey, default: 0] < groupLimit
                    }

                    func recordStarted(_ index: Int) {
                        activeCount += 1
                        guard let groupKey = providerPolicies[
                            enabled[index].site.key
                        ]?.concurrencyGroup else { return }
                        activeGroupCounts[groupKey, default: 0] += 1
                    }

                    func recordFinished(_ index: Int) {
                        activeCount = max(0, activeCount - 1)
                        guard let groupKey = providerPolicies[
                            enabled[index].site.key
                        ]?.concurrencyGroup else { return }
                        let remaining = activeGroupCounts[groupKey, default: 0] - 1
                        if remaining > 0 {
                            activeGroupCounts[groupKey] = remaining
                        } else {
                            activeGroupCounts.removeValue(forKey: groupKey)
                        }
                    }

                    func scheduleAvailable() {
                        while activeCount < maximumConcurrency,
                              let pendingPosition = pendingIndexes.firstIndex(
                                where: canStart
                              ) {
                            let index = pendingIndexes.remove(at: pendingPosition)
                            recordStarted(index)
                            group.addTask {
                                InitialPageResult(
                                    providerIndex: index,
                                    outcome: await initialPageOutcome(
                                        provider: enabled[index],
                                        keyword: keyword,
                                        quick: quick,
                                        deadline: deadline
                                    )
                                )
                            }
                        }
                    }

                    scheduleAvailable()

                    while let result = await group.next() {
                        recordFinished(result.providerIndex)
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        let provider = enabled[result.providerIndex]
                        switch result.outcome {
                        case .page(let page, let resolvedKeyword):
                            let items = Self.deduplicatedWithinSite(page.items)
                            if pool.ingest(items) {
                                continuation.yield(.snapshot(pool.snapshot))
                            }
                            let pageCount = page.pagination.pageCount.flatMap {
                                $0 > 0 ? $0 : nil
                            }
                            let hasDeclaredNextPage = pageCount.map { $0 > 1 } ?? true
                            let providerMaximumPages = providerPolicies[
                                provider.site.key
                            ]?.maximumPagesPerSite ?? maximumPagesPerSite
                            if !items.isEmpty,
                               hasDeclaredNextPage,
                               providerMaximumPages > 1,
                               pool.retainedCount(for: provider.site.key)
                                    < maximumResultsPerSite {
                                backgroundStates.append(
                                    BackgroundSearchState(
                                        providerIndex: result.providerIndex,
                                        keyword: resolvedKeyword,
                                        nextPage: 2,
                                        explicitPageCount: pageCount,
                                        seenIDs: Set(items.map(\.id)),
                                        candidateCount: min(
                                            items.count,
                                            maximumResultsPerSite
                                        ),
                                        relevance: SearchCandidatePool.relevance(
                                            of: items,
                                            keyword: resolvedKeyword
                                        )
                                    )
                                )
                            } else {
                                continuation.yield(
                                    .siteCompleted(siteKey: provider.site.key)
                                )
                            }
                        case .failure(let message):
                            providerFailureCount += 1
                            continuation.yield(
                                .failure(
                                    SearchFailure(
                                        siteKey: provider.site.key,
                                        siteName: provider.site.name,
                                        message: message
                                    )
                                )
                            )
                            continuation.yield(
                                .siteCompleted(siteKey: provider.site.key)
                            )
                        case .deadlineReached:
                            reachedDeadline = true
                            continuation.yield(
                                .siteCompleted(siteKey: provider.site.key)
                            )
                        case .cancelled:
                            break
                        }

                        if case .cancelled = result.outcome {
                            // Cancelled work is not reported as completed.
                        } else {
                            continuation.yield(
                                .siteFirstPageCompleted(siteKey: provider.site.key)
                            )
                        }
                        scheduleAvailable()
                    }
                }

                guard !Task.isCancelled else {
                    continuation.yield(.finished(.cancelled))
                    return
                }

                if deadline.timeIntervalSinceNow <= 0 {
                    reachedDeadline = true
                }

                if !reachedDeadline,
                   maximumDeepPageSites > 0,
                   deadline.timeIntervalSinceNow > 0 {
                    let selectedStates = backgroundStates
                        .sorted { lhs, rhs in
                            if lhs.relevance != rhs.relevance {
                                return lhs.relevance > rhs.relevance
                            }
                            return lhs.providerIndex < rhs.providerIndex
                        }
                        .prefix(min(maximumDeepPageSites, maximumConcurrency))

                    let selectedProviderIndexes = Set(
                        selectedStates.map(\.providerIndex)
                    )
                    for state in backgroundStates
                        where !selectedProviderIndexes.contains(state.providerIndex) {
                        continuation.yield(
                            .siteCompleted(
                                siteKey: enabled[state.providerIndex].site.key
                            )
                        )
                    }

                    await withTaskGroup(of: BackgroundSearchResult.self) { group in
                        for state in selectedStates {
                            group.addTask {
                                await searchBackgroundPages(
                                    state: state,
                                    providers: enabled,
                                    quick: quick,
                                    deadline: deadline,
                                    providerPolicies: providerPolicies
                                )
                            }
                        }

                        while let result = await group.next() {
                            guard !Task.isCancelled else {
                                group.cancelAll()
                                break
                            }
                            let provider = enabled[result.providerIndex]
                            if pool.ingest(result.items) {
                                continuation.yield(.snapshot(pool.snapshot))
                            }
                            if let message = result.failureMessage {
                                providerFailureCount += 1
                                continuation.yield(
                                    .failure(
                                        SearchFailure(
                                            siteKey: provider.site.key,
                                            siteName: provider.site.name,
                                            message: message
                                        )
                                    )
                                )
                            }
                            reachedDeadline = reachedDeadline || result.reachedDeadline
                            continuation.yield(
                                .siteCompleted(siteKey: provider.site.key)
                            )
                        }
                    }
                } else {
                    for state in backgroundStates {
                        continuation.yield(
                            .siteCompleted(
                                siteKey: enabled[state.providerIndex].site.key
                            )
                        )
                    }
                }

                guard !Task.isCancelled else {
                    continuation.yield(.finished(.cancelled))
                    return
                }
                if deadline.timeIntervalSinceNow <= 0 {
                    reachedDeadline = true
                }
                if pool.receivedCandidateCount > 0 {
                    continuation.yield(.snapshot(pool.snapshot))
                }
                let termination: MultiSiteSearchTermination
                if reachedDeadline {
                    termination = .deadlineReached
                } else if providerFailureCount > 0 {
                    termination = .completedWithProviderFailures
                } else {
                    termination = .completed
                }
                continuation.yield(.finished(termination))
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func initialPageOutcome(
        provider: SiteProvider,
        keyword: String,
        quick: Bool,
        deadline: Date
    ) async -> PageSearchOutcome {
        let plan = SearchQueryPlan(keyword)
        let providerTimeout = Self.effectiveSiteTimeout(
            base: siteTimeout,
            capability: provider.capability
        )
        let siteDeadline = min(
            deadline,
            Date().addingTimeInterval(providerTimeout)
        )
        let remaining = siteDeadline.timeIntervalSinceNow
        guard remaining > 0 else { return .deadlineReached }
        let originalOutcome = await searchPageWithTimeout(
            provider: provider,
            keyword: plan.original,
            page: 1,
            quick: quick,
            timeout: remaining,
            deadlineLimited: siteDeadline == deadline
        )
        guard case .page(let originalPage, _) = originalOutcome,
              let fallback = plan.fallback,
              originalPage.items.isEmpty
                || !SearchCandidatePool.hasMeaningfulMatch(
                    in: originalPage.items,
                    keyword: plan.original
                ) else {
            return originalOutcome
        }

        let fallbackRemaining = siteDeadline.timeIntervalSinceNow
        guard fallbackRemaining > 0 else { return originalOutcome }
        let fallbackOutcome = await searchPageWithTimeout(
            provider: provider,
            keyword: fallback,
            page: 1,
            quick: quick,
            timeout: fallbackRemaining,
            deadlineLimited: siteDeadline == deadline
        )
        switch fallbackOutcome {
        case .page(let fallbackPage, _):
            var seenIDs = Set<String>()
            let mergedItems = (originalPage.items + fallbackPage.items).filter {
                seenIDs.insert($0.id).inserted
            }
            return .page(
                VideoPage(
                    items: mergedItems,
                    pagination: fallbackPage.pagination
                ),
                keyword: fallback
            )
        case .cancelled:
            return .cancelled
        case .failure, .deadlineReached:
            return originalOutcome
        }
    }

    private func searchBackgroundPages(
        state initialState: BackgroundSearchState,
        providers: [SiteProvider],
        quick: Bool,
        deadline: Date,
        providerPolicies: [String: MultiSiteSearchProviderPolicy]
    ) async -> BackgroundSearchResult {
        var state = initialState
        let provider = providers[state.providerIndex]
        var collected: [VideoSummary] = []

        let providerMaximumPages = providerPolicies[
            provider.site.key
        ]?.maximumPagesPerSite ?? maximumPagesPerSite
        searchLoop: while state.nextPage <= providerMaximumPages,
                          state.candidateCount < maximumResultsPerSite,
                          !Task.isCancelled {
            if let pageCount = state.explicitPageCount,
               pageCount > 0,
               state.nextPage > pageCount {
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return BackgroundSearchResult(
                    providerIndex: state.providerIndex,
                    items: collected,
                    failureMessage: nil,
                    reachedDeadline: true
                )
            }
            let providerTimeout = Self.effectiveSiteTimeout(
                base: siteTimeout,
                capability: provider.capability
            )
            switch await searchPageWithTimeout(
                provider: provider,
                keyword: state.keyword,
                page: state.nextPage,
                quick: quick,
                timeout: min(providerTimeout, remaining),
                deadlineLimited: remaining <= providerTimeout
            ) {
            case .page(let page, _):
                guard !page.items.isEmpty else { break searchLoop }
                var newItems: [VideoSummary] = []
                for item in page.items where state.seenIDs.insert(item.id).inserted {
                    newItems.append(item)
                    state.candidateCount += 1
                    if state.candidateCount >= maximumResultsPerSite { break }
                }
                guard !newItems.isEmpty else { break searchLoop }
                collected.append(contentsOf: newItems)
                if let pageCount = page.pagination.pageCount,
                   pageCount > 0 {
                    state.explicitPageCount = pageCount
                }
                state.nextPage += 1
            case .failure(let message):
                return BackgroundSearchResult(
                    providerIndex: state.providerIndex,
                    items: collected,
                    failureMessage: message,
                    reachedDeadline: false
                )
            case .deadlineReached:
                return BackgroundSearchResult(
                    providerIndex: state.providerIndex,
                    items: collected,
                    failureMessage: nil,
                    reachedDeadline: true
                )
            case .cancelled:
                return BackgroundSearchResult(
                    providerIndex: state.providerIndex,
                    items: [],
                    failureMessage: nil,
                    reachedDeadline: false
                )
            }
        }

        return BackgroundSearchResult(
            providerIndex: state.providerIndex,
            items: collected,
            failureMessage: nil,
            reachedDeadline: false
        )
    }

    private static func deduplicatedWithinSite(
        _ items: [VideoSummary]
    ) -> [VideoSummary] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func effectiveSiteTimeout(
        base: TimeInterval,
        capability: SiteCapability
    ) -> TimeInterval {
        switch capability {
        case .javaDexSpider:
            return min(max(base, 30), 45)
        default:
            return base
        }
    }

    private func searchPageWithTimeout(
        provider: SiteProvider,
        keyword: String,
        page: Int,
        quick: Bool,
        timeout: TimeInterval,
        deadlineLimited: Bool
    ) async -> PageSearchOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let firstOutcome = FirstPageSearchOutcome()
        let providerTask = Task {
            do {
                let result = try await provider.search(
                    keyword: keyword,
                    page: page,
                    quick: quick
                )
                await firstOutcome.resolve(.page(result, keyword: keyword))
            } catch is CancellationError {
                await firstOutcome.resolve(.cancelled)
            } catch {
                await firstOutcome.resolve(.failure(error.localizedDescription))
            }
        }
        let timeoutTask = Task {
            do {
                let nanoseconds = UInt64(
                    min(max(timeout, 0.01), 300) * 1_000_000_000
                )
                try await Task.sleep(nanoseconds: nanoseconds)
                if deadlineLimited {
                    await firstOutcome.resolve(.deadlineReached)
                } else {
                    await firstOutcome.resolve(
                        .failure("搜索超时（\(max(1, Int(timeout))) 秒）")
                    )
                }
            } catch {
                // Winning provider result or cancellation stops this timer.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await firstOutcome.wait()
        } onCancel: {
            providerTask.cancel()
            timeoutTask.cancel()
            Task {
                await firstOutcome.resolve(.cancelled)
            }
        }
        providerTask.cancel()
        timeoutTask.cancel()
        return outcome
    }
}
