import XCTest
@testable import OKVideoCore

final class MultiSiteSearchTests: XCTestCase {
    func testDefaultSearchBudgetIsBoundedForDesktopResources() {
        XCTAssertEqual(MultiSiteSearch().maximumConcurrency, 12)
        XCTAssertEqual(MultiSiteSearch().siteTimeout, 20)
        XCTAssertEqual(MultiSiteSearch().overallDeadline, 25)
        XCTAssertEqual(MultiSiteSearch().maximumPagesPerSite, 3)
        XCTAssertEqual(MultiSiteSearch().maximumResultsPerSite, 40)
        XCTAssertEqual(MultiSiteSearch().maximumRetainedCandidates, 500)
        XCTAssertEqual(MultiSiteSearch().maximumDeepPageSites, 12)
    }

    func testSearchIsolatesFailureAndDeduplicatesSiteResults() async {
        let good = SearchFixtureProvider(
            site: SiteConfiguration(key: "good", name: "Good", type: 1, api: "https://example.invalid"),
            result: .success([
                VideoSummary(siteKey: "good", siteName: "Good", videoID: "1", title: "One"),
                VideoSummary(siteKey: "good", siteName: "Good", videoID: "1", title: "Duplicate")
            ])
        )
        let bad = SearchFixtureProvider(
            site: SiteConfiguration(key: "bad", name: "Bad", type: 1, api: "https://example.invalid"),
            result: .failure(.site("fixture failure"))
        )

        var events: [MultiSiteSearchEvent] = []
        for await event in MultiSiteSearch(maximumConcurrency: 2).search(
            providers: [good, bad],
            keyword: "fixture"
        ) {
            events.append(event)
        }

        XCTAssertEqual(
            finalSnapshot(in: events)?.items,
            [VideoSummary(siteKey: "good", siteName: "Good", videoID: "1", title: "One")]
        )
        XCTAssertTrue(events.contains { event in
            guard case .failure(let failure) = event else { return false }
            return failure.siteKey == "bad"
        })
        XCTAssertEqual(events.last, .finished(.completedWithProviderFailures))
    }

    func testCrossSiteSameTitleAndYearIsClusteredWithoutLosingSources() {
        let values = [
            VideoSummary(
                siteKey: "a",
                siteName: "Site A",
                videoID: "1",
                title: "Fixture Movie",
                year: "2026"
            ),
            VideoSummary(
                siteKey: "b",
                siteName: "Site B",
                videoID: "9",
                title: "fixture movie",
                year: "2026"
            ),
            VideoSummary(
                siteKey: "b",
                siteName: "Site B",
                videoID: "10",
                title: "Fixture Movie",
                year: "2025"
            )
        ]

        let clusters = SearchResultAggregator.cluster(values)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first { $0.year == "2026" }?.sources.map(\.siteKey), ["a", "b"])
        XCTAssertEqual(clusters.first { $0.year == "2025" }?.sources.map(\.videoID), ["10"])
    }

    func testSymbolVariantsRemainSeparateAndPrimarySourceStaysStable() {
        let values = [
            VideoSummary(
                siteKey: "z",
                siteName: "Site Z",
                videoID: "1",
                title: "《群体》",
                posterURL: URL(string: "https://example.invalid/first.jpg"),
                year: "2026"
            ),
            VideoSummary(
                siteKey: "a",
                siteName: "Site A",
                videoID: "2",
                title: "《群体》",
                posterURL: URL(string: "https://example.invalid/later.jpg"),
                year: "2026"
            ),
            VideoSummary(
                siteKey: "plain",
                siteName: "Plain",
                videoID: "3",
                title: "群体",
                year: "2026"
            )
        ]

        let clusters = SearchResultAggregator.cluster(values)

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].primary?.siteKey, "z")
        XCTAssertEqual(
            clusters[0].primary?.posterURL?.absoluteString,
            "https://example.invalid/first.jpg"
        )
        XCTAssertEqual(clusters[0].sources.map(\.siteKey), ["z", "a"])
        XCTAssertEqual(clusters[1].title, "群体")
    }

    func testSearchableValueTwoIsExcludedLikeFongMi() async {
        let disabled = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "disabled",
                name: "Disabled",
                type: 1,
                api: "https://example.invalid",
                searchable: 2
            ),
            result: .success([
                VideoSummary(
                    siteKey: "disabled",
                    siteName: "Disabled",
                    videoID: "1",
                    title: "Should not appear"
                )
            ])
        )

        var events: [MultiSiteSearchEvent] = []
        for await event in MultiSiteSearch().search(
            providers: [disabled],
            keyword: "fixture"
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [.finished(.completed)])
    }

    func testRetainedSnapshotKeepsCompletionOrderWithinSameRelevanceTier() async {
        let slow = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "slow",
                name: "Slow",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([
                VideoSummary(
                    siteKey: "slow",
                    siteName: "Slow",
                    videoID: "2",
                    title: "Second"
                ),
                VideoSummary(
                    siteKey: "slow",
                    siteName: "Slow",
                    videoID: "1",
                    title: "First"
                )
            ]),
            delayNanoseconds: 50_000_000
        )
        let fast = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "fast",
                name: "Fast",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([
                VideoSummary(
                    siteKey: "fast",
                    siteName: "Fast",
                    videoID: "9",
                    title: "Fast result"
                )
            ])
        )

        var snapshots: [MultiSiteSearchSnapshot] = []
        for await event in MultiSiteSearch(maximumConcurrency: 2).search(
            providers: [slow, fast],
            keyword: "fixture"
        ) {
            guard case .snapshot(let snapshot) = event else { continue }
            snapshots.append(snapshot)
        }

        XCTAssertEqual(snapshots.first?.items.map(\.siteKey), ["fast"])
        XCTAssertEqual(
            snapshots.last?.items.map(\.videoID),
            ["9", "2", "1"]
        )
    }

    func testSlowSiteTimesOutWithoutBlockingCompletion() async {
        let slow = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "slow",
                name: "Slow",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([]),
            delayNanoseconds: 500_000_000
        )

        var events: [MultiSiteSearchEvent] = []
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            siteTimeout: 0.05
        ).search(providers: [slow], keyword: "fixture") {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            guard case .failure(let failure) = event else { return false }
            return failure.siteKey == "slow"
                && failure.message.contains("搜索超时")
        })
        XCTAssertEqual(events.last, .finished(.completedWithProviderFailures))
    }

    func testTimeoutDoesNotWaitForProviderThatIgnoresCancellation() async {
        let uncooperative = UncooperativeSearchFixtureProvider()
        let fast = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "fast-after-timeout",
                name: "Fast After Timeout",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([])
        )

        let startedAt = Date()
        var events: [MultiSiteSearchEvent] = []
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            siteTimeout: 0.05
        ).search(
            providers: [uncooperative, fast],
            keyword: "fixture"
        ) {
            events.append(event)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
        XCTAssertTrue(events.contains { event in
            guard case .failure(let failure) = event else { return false }
            return failure.siteKey == uncooperative.site.key
                && failure.message.contains("搜索超时")
        })
        XCTAssertTrue(events.contains(.siteCompleted(siteKey: fast.site.key)))
        XCTAssertTrue(events.contains(.siteFirstPageCompleted(siteKey: fast.site.key)))
        XCTAssertEqual(events.last, .finished(.completedWithProviderFailures))
    }

    func testJavaDexSearchUsesBridgeLengthTimeout() async {
        let dex = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "dex",
                name: "Dex",
                type: 3,
                api: "csp_Fixture"
            ),
            result: .success([
                VideoSummary(
                    siteKey: "dex",
                    siteName: "Dex",
                    videoID: "1",
                    title: "Dex result"
                )
            ]),
            delayNanoseconds: 100_000_000,
            capability: .javaDexSpider
        )

        var events: [MultiSiteSearchEvent] = []
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            siteTimeout: 0.05
        ).search(providers: [dex], keyword: "fixture") {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            guard case .snapshot(let snapshot) = event else { return false }
            return snapshot.items.map(\.videoID) == ["1"]
        })
        XCTAssertFalse(events.contains { event in
            guard case .failure(let failure) = event else { return false }
            return failure.siteKey == "dex"
        })
    }

    func testJavaScriptSearchUsesGenericTimeout() {
        XCTAssertEqual(
            MultiSiteSearch.effectiveSiteTimeout(
                base: 30,
                capability: .javaScriptSpider
            ),
            30
        )
        XCTAssertEqual(
            MultiSiteSearch.effectiveSiteTimeout(
                base: 30,
                capability: .javaDexSpider
            ),
            30
        )
    }

    func testSearchCollectsMultiplePagesWhenJavaScriptSourceOmitsPageCount() async {
        let recorder = SearchPageRecorder()
        let provider = PagedSearchFixtureProvider(recorder: recorder)

        var resultIDs: [String] = []
        var firstPageCompletedCount = 0
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            maximumPagesPerSite: 6
        ).search(providers: [provider], keyword: "fixture") {
            switch event {
            case .snapshot(let snapshot):
                resultIDs = snapshot.items.map(\.videoID)
            case .siteFirstPageCompleted:
                firstPageCompletedCount += 1
            default:
                break
            }
        }

        let requestedPages = await recorder.pages
        XCTAssertEqual(resultIDs, ["1", "2", "3"])
        XCTAssertEqual(requestedPages, [1, 2, 3])
        XCTAssertEqual(firstPageCompletedCount, 1)
    }

    func testEveryEligibleProviderGetsFirstPageRequestOpportunity() async {
        let recorder = FirstPageInvocationRecorder()
        let providers: [SiteProvider] = (0..<20).map {
            FirstPageRecordingProvider(index: $0, recorder: recorder)
        }

        for await _ in MultiSiteSearch(
            maximumConcurrency: 1,
            siteTimeout: 1,
            overallDeadline: 1
        ).search(providers: providers, keyword: "fixture") {}

        let invokedKeys = await recorder.keys
        XCTAssertEqual(invokedKeys, Set((0..<20).map { "site-\($0)" }))
    }

    func testFirstPageRetainsAtMostFortyResultsFromOneSite() async {
        let provider = SearchFixtureProvider(
            site: fixtureSite(key: "bulk"),
            result: .success(makeItems(siteKey: "bulk", count: 75))
        )

        let events = await collect(
            MultiSiteSearch().search(providers: [provider], keyword: "fixture")
        )
        let snapshot = finalSnapshot(in: events)

        XCTAssertEqual(snapshot?.items.count, 40)
        XCTAssertEqual(snapshot?.maximumResultsPerSite, 40)
        XCTAssertEqual(snapshot?.didDiscardCandidates, true)
    }

    func testRetainedCandidatePoolNeverExceedsFiveHundred() async {
        let providers: [SiteProvider] = (0..<15).map { siteIndex in
            let key = "site-\(siteIndex)"
            return SearchFixtureProvider(
                site: fixtureSite(key: key),
                result: .success(makeItems(siteKey: key, count: 60))
            )
        }

        let events = await collect(
            MultiSiteSearch().search(providers: providers, keyword: "fixture")
        )
        let snapshot = finalSnapshot(in: events)
        let siteCounts = Dictionary(grouping: snapshot?.items ?? [], by: \.siteKey)

        XCTAssertEqual(snapshot?.items.count, 500)
        XCTAssertTrue(siteCounts.values.allSatisfy { $0.count <= 40 })
        XCTAssertEqual(snapshot?.didDiscardCandidates, true)
    }

    func testLateExactMatchReplacesRetainedLowRelevanceResult() async {
        let early = SearchFixtureProvider(
            site: fixtureSite(key: "early"),
            result: .success(
                makeItems(siteKey: "early", count: 10, titlePrefix: "无关内容")
            )
        )
        let late = SearchFixtureProvider(
            site: fixtureSite(key: "late"),
            result: .success([
                VideoSummary(
                    siteKey: "late",
                    siteName: "late",
                    videoID: "exact",
                    title: "机器人总动员"
                )
            ]),
            delayNanoseconds: 50_000_000
        )

        let events = await collect(
            MultiSiteSearch(
                maximumResultsPerSite: 10,
                maximumRetainedCandidates: 10
            ).search(providers: [early, late], keyword: "机器人总动员")
        )
        let snapshot = finalSnapshot(in: events)

        XCTAssertEqual(snapshot?.items.count, 10)
        XCTAssertEqual(snapshot?.items.first?.videoID, "exact")
        XCTAssertFalse(snapshot?.items.contains { $0.videoID == "9" } ?? true)
    }

    func testOneSiteCannotMonopolizeRetainedPool() async {
        let dominant = SearchFixtureProvider(
            site: fixtureSite(key: "dominant"),
            result: .success(makeItems(siteKey: "dominant", count: 100))
        )
        let diverse = SearchFixtureProvider(
            site: fixtureSite(key: "diverse"),
            result: .success(makeItems(siteKey: "diverse", count: 20)),
            delayNanoseconds: 40_000_000
        )

        let events = await collect(
            MultiSiteSearch(
                maximumResultsPerSite: 40,
                maximumRetainedCandidates: 50
            ).search(providers: [dominant, diverse], keyword: "fixture")
        )
        let items = finalSnapshot(in: events)?.items ?? []
        let counts = Dictionary(grouping: items, by: \.siteKey)

        XCTAssertEqual(items.count, 50)
        XCTAssertLessThanOrEqual(counts["dominant"]?.count ?? 0, 40)
        XCTAssertGreaterThan(counts["diverse"]?.count ?? 0, 0)
    }

    func testGlobalDeadlineStopsSearchAndReportsDeadlineState() async {
        let startedAt = Date()
        let events = await collect(
            MultiSiteSearch(
                siteTimeout: 5,
                overallDeadline: 0.05
            ).search(
                providers: [UncooperativeSearchFixtureProvider()],
                keyword: "fixture"
            )
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
        XCTAssertEqual(events.last, .finished(.deadlineReached))
    }

    func testOnlyTopTwelveFirstPageProvidersReceiveDeepRequests() async {
        let recorder = DeepPageInvocationRecorder()
        let providers: [SiteProvider] = (0..<15).map {
            DeepPageRecordingProvider(index: $0, recorder: recorder)
        }

        for await _ in MultiSiteSearch(
            maximumConcurrency: 12,
            overallDeadline: 2,
            maximumPagesPerSite: 2,
            maximumDeepPageSites: 12
        ).search(providers: providers, keyword: "fixture") {}

        let deepKeys = await recorder.deepPageKeys
        XCTAssertEqual(deepKeys.count, 12)
        XCTAssertEqual(deepKeys, Set((0..<12).map { "deep-\($0)" }))
    }

    func testCancellingConsumerCancelsInFlightProviderSearch() async throws {
        let recorder = SearchCancellationRecorder()
        let provider = CancellableSearchFixtureProvider(recorder: recorder)
        let stream = MultiSiteSearch(
            maximumConcurrency: 1,
            siteTimeout: 5
        ).search(providers: [provider], keyword: "fixture")
        let consumer = Task {
            for await _ in stream {}
        }

        for _ in 0..<100 where !(await recorder.started) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let didStart = await recorder.started
        XCTAssertTrue(didStart)

        consumer.cancel()
        await consumer.value

        for _ in 0..<100 where !(await recorder.cancelled) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let didCancel = await recorder.cancelled
        XCTAssertTrue(didCancel)
    }

    func testCancelRejectsLateUncooperativeProviderResult() async throws {
        let recorder = SearchEventRecorder()
        let stream = MultiSiteSearch(
            siteTimeout: 5,
            overallDeadline: 5
        ).search(
            providers: [UncooperativeResultSearchFixtureProvider()],
            keyword: "fixture"
        )
        let consumer = Task {
            for await event in stream {
                await recorder.record(event)
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        await consumer.value
        try await Task.sleep(nanoseconds: 600_000_000)

        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .snapshot = event { return true }
            return false
        })
    }

    private func collect(
        _ stream: AsyncStream<MultiSiteSearchEvent>
    ) async -> [MultiSiteSearchEvent] {
        var events: [MultiSiteSearchEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func finalSnapshot(
        in events: [MultiSiteSearchEvent]
    ) -> MultiSiteSearchSnapshot? {
        events.reversed().compactMap { event in
            guard case .snapshot(let snapshot) = event else { return nil }
            return snapshot
        }.first
    }

    private func fixtureSite(key: String) -> SiteConfiguration {
        SiteConfiguration(
            key: key,
            name: key,
            type: 1,
            api: "https://example.invalid"
        )
    }

    private func makeItems(
        siteKey: String,
        count: Int,
        titlePrefix: String = "fixture"
    ) -> [VideoSummary] {
        (0..<count).map { index in
            VideoSummary(
                siteKey: siteKey,
                siteName: siteKey,
                videoID: "\(index)",
                title: "\(titlePrefix) \(index)"
            )
        }
    }
}

private actor FirstPageInvocationRecorder {
    private(set) var keys: Set<String> = []

    func record(_ key: String) {
        keys.insert(key)
    }
}

private actor DeepPageInvocationRecorder {
    private(set) var deepPageKeys: Set<String> = []

    func record(siteKey: String, page: Int) {
        if page > 1 {
            deepPageKeys.insert(siteKey)
        }
    }
}

private actor SearchEventRecorder {
    private(set) var events: [MultiSiteSearchEvent] = []

    func record(_ event: MultiSiteSearchEvent) {
        events.append(event)
    }
}

private struct FirstPageRecordingProvider: SiteProvider {
    let site: SiteConfiguration
    let recorder: FirstPageInvocationRecorder
    let capability: SiteCapability = .standardJSON

    init(index: Int, recorder: FirstPageInvocationRecorder) {
        site = SiteConfiguration(
            key: "site-\(index)",
            name: "Site \(index)",
            type: 1,
            api: "https://example.invalid"
        )
        self.recorder = recorder
    }

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record(site.key)
        try await Task.sleep(nanoseconds: 50_000_000)
        return VideoPage(
            items: [],
            pagination: Pagination(page: page, pageCount: 1)
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private struct DeepPageRecordingProvider: SiteProvider {
    let site: SiteConfiguration
    let recorder: DeepPageInvocationRecorder
    let capability: SiteCapability = .standardJSON

    init(index: Int, recorder: DeepPageInvocationRecorder) {
        site = SiteConfiguration(
            key: "deep-\(index)",
            name: "Deep \(index)",
            type: 1,
            api: "https://example.invalid"
        )
        self.recorder = recorder
    }

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record(siteKey: site.key, page: page)
        return VideoPage(
            items: [
                VideoSummary(
                    siteKey: site.key,
                    siteName: site.name,
                    videoID: "\(page)",
                    title: "fixture \(page)"
                )
            ],
            pagination: Pagination(page: page, pageCount: 2)
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private struct UncooperativeResultSearchFixtureProvider: SiteProvider {
    let site = SiteConfiguration(
        key: "late-result",
        name: "Late Result",
        type: 1,
        api: "https://example.invalid"
    )
    let capability: SiteCapability = .standardJSON

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(
                    returning: VideoPage(
                        items: [
                            VideoSummary(
                                siteKey: site.key,
                                siteName: site.name,
                                videoID: "late",
                                title: keyword
                            )
                        ],
                        pagination: Pagination(page: page, pageCount: 1)
                    )
                )
            }
        }
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private actor SearchPageRecorder {
    private(set) var pages: [Int] = []

    func record(_ page: Int) {
        pages.append(page)
    }
}

private actor SearchCancellationRecorder {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }
}

private struct CancellableSearchFixtureProvider: SiteProvider {
    let recorder: SearchCancellationRecorder
    let site = SiteConfiguration(
        key: "cancellable",
        name: "Cancellable",
        type: 1,
        api: "https://example.invalid"
    )
    let capability: SiteCapability = .standardJSON

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.markStarted()
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            await recorder.markCancelled()
            throw error
        }
        return VideoPage(items: [], pagination: Pagination(page: page, pageCount: 1))
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private struct UncooperativeSearchFixtureProvider: SiteProvider {
    let site = SiteConfiguration(
        key: "uncooperative",
        name: "Uncooperative",
        type: 1,
        api: "https://example.invalid"
    )
    let capability: SiteCapability = .standardJSON

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(
                    returning: VideoPage(
                        items: [],
                        pagination: Pagination(page: page, pageCount: 1)
                    )
                )
            }
        }
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private struct PagedSearchFixtureProvider: SiteProvider {
    let recorder: SearchPageRecorder
    let site = SiteConfiguration(
        key: "paged",
        name: "Paged",
        type: 4,
        api: "http://127.0.0.1:18989/spider/paged"
    )
    let capability: SiteCapability = .javaScriptSpider

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record(page)
        let ids: [String]
        switch page {
        case 1: ids = ["1", "2"]
        case 2: ids = ["2", "3"]
        default: ids = []
        }
        return VideoPage(
            items: ids.map {
                VideoSummary(
                    siteKey: site.key,
                    siteName: site.name,
                    videoID: $0,
                    title: "Result \($0)"
                )
            },
            pagination: Pagination(page: page, pageCount: 0)
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}

private struct SearchFixtureProvider: SiteProvider {
    let site: SiteConfiguration
    let result: Result<[VideoSummary], AppError>
    var delayNanoseconds: UInt64 = 0
    var capability: SiteCapability = .standardJSON

    func home() async throws -> SiteHome {
        SiteHome(categories: [], recommendations: [])
    }

    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
        VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
    }

    func detail(id: String) async throws -> VideoDetail {
        throw AppError.site("unused")
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return VideoPage(
            items: try result.get(),
            pagination: Pagination(page: page, pageCount: 1)
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw AppError.site("unused")
    }
}
