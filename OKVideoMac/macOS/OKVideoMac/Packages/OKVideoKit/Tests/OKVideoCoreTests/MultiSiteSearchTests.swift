import XCTest
@testable import OKVideoCore

final class MultiSiteSearchTests: XCTestCase {
    func testDefaultConcurrencyMatchesFongMiLargeSearchPool() {
        XCTAssertEqual(MultiSiteSearch().maximumConcurrency, 20)
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

        XCTAssertTrue(events.contains(.results(siteKey: "good", items: [
            VideoSummary(siteKey: "good", siteName: "Good", videoID: "1", title: "One")
        ])))
        XCTAssertTrue(events.contains { event in
            guard case .failure(let failure) = event else { return false }
            return failure.siteKey == "bad"
        })
        XCTAssertEqual(events.last, .completed)
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

        XCTAssertEqual(events, [.completed])
    }

    func testResultsKeepProviderOrderAndSitesEmitByCompletionOrder() async {
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

        var resultEvents: [(String, [String])] = []
        for await event in MultiSiteSearch(maximumConcurrency: 2).search(
            providers: [slow, fast],
            keyword: "fixture"
        ) {
            guard case .results(let siteKey, let items) = event else { continue }
            resultEvents.append((siteKey, items.map(\.videoID)))
        }

        XCTAssertEqual(resultEvents.map(\.0), ["fast", "slow"])
        XCTAssertEqual(resultEvents.last?.1, ["2", "1"])
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
        XCTAssertEqual(events.last, .completed)
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
        XCTAssertTrue(events.contains(.results(
            siteKey: fast.site.key,
            items: []
        )))
        XCTAssertEqual(events.last, .completed)
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
            guard case .results(let siteKey, let items) = event else { return false }
            return siteKey == "dex" && items.map(\.videoID) == ["1"]
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
            75
        )
    }

    func testSearchCollectsMultiplePagesWhenJavaScriptSourceOmitsPageCount() async {
        let recorder = SearchPageRecorder()
        let provider = PagedSearchFixtureProvider(recorder: recorder)

        var resultIDs: [String] = []
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            maximumPagesPerSite: 6
        ).search(providers: [provider], keyword: "fixture") {
            guard case .results(_, let items) = event else { continue }
            resultIDs = items.map(\.videoID)
        }

        let requestedPages = await recorder.pages
        XCTAssertEqual(resultIDs, ["1", "2", "3"])
        XCTAssertEqual(requestedPages, [1, 2, 3])
    }

    func testNodeAggregateSearchPublishesOnlyFirstPage() async {
        let recorder = SearchPageRecorder()
        let provider = PagedSearchFixtureProvider(
            recorder: recorder,
            capability: .nodeHTTPSpider
        )

        var resultIDs: [String] = []
        for await event in MultiSiteSearch(
            maximumConcurrency: 1,
            maximumPagesPerSite: 10
        ).search(providers: [provider], keyword: "fixture") {
            guard case .results(_, let items) = event else { continue }
            resultIDs = items.map(\.videoID)
        }

        let requestedPages = await recorder.pages
        XCTAssertEqual(resultIDs, ["1", "2"])
        XCTAssertEqual(requestedPages, [1])
    }

    func testMovingWindowStartsQueuedSiteBeforeSlowPeerFinishes() async {
        let slow = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "slow",
                name: "Slow",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([]),
            delayNanoseconds: 300_000_000
        )
        let fast = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "fast",
                name: "Fast",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([]),
            delayNanoseconds: 30_000_000
        )
        let queued = SearchFixtureProvider(
            site: SiteConfiguration(
                key: "queued",
                name: "Queued",
                type: 1,
                api: "https://example.invalid"
            ),
            result: .success([])
        )

        var completedKeys: [String] = []
        for await event in MultiSiteSearch(maximumConcurrency: 2).search(
            providers: [slow, fast, queued],
            keyword: "fixture"
        ) {
            guard case .results(let siteKey, _) = event else { continue }
            completedKeys.append(siteKey)
        }

        XCTAssertEqual(completedKeys, ["fast", "queued", "slow"])
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
    var capability: SiteCapability = .javaScriptSpider

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
