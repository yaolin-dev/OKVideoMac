import XCTest
@testable import OKVideoCore

final class SearchContinuationTests: XCTestCase {
    func testOversizedPageKeepsCursorMemoryBoundedAndRepeatedReorderedPageIsUncertain() {
        let items = (0..<10_000).map { VideoSummary(siteKey: "large", siteName: "Large", videoID: String($0), title: "Film \($0)") }
        var cursor = SearchPageCursor(keyword: "film")
        XCTAssertTrue(cursor.accept(VideoPage(items: items, pagination: Pagination(page: 1, pageCount: 3)), requestedPage: 1))
        XCTAssertLessThanOrEqual(cursor.seenIDs.count, SearchPageCursor.maximumRememberedIDs)
        XCTAssertFalse(cursor.accept(VideoPage(items: Array(items.reversed()), pagination: Pagination(page: 2, pageCount: 3)), requestedPage: 2))
        XCTAssertTrue(cursor.uncertain)
        XCTAssertEqual(cursor.nextPage, 2)
        var replay = cursor.replaying(from: 1)
        XCTAssertTrue(replay.accept(VideoPage(items: items, pagination: Pagination(page: 1, pageCount: 3)), requestedPage: 1))
        XCTAssertLessThanOrEqual(replay.seenIDs.count, SearchPageCursor.maximumRememberedIDs)
    }

    func testBudgetTracksEvictedSourceAndCanRecoverItsFinalPage() {
        func item(_ site: String, _ id: Int, _ title: String) -> VideoSummary {
            VideoSummary(siteKey: site, siteName: site, videoID: String(id), title: title)
        }
        let old = (0..<4).map { item("a", $0, "other") }
        let incoming = [item("b", 0, "film")]
        let first = MultiSiteSearch.merging(existing: old, incoming: incoming, keyword: "film",
            maximumRetainedCandidates: 4, maximumResultsPerSite: 4, incomingPage: 2)
        XCTAssertEqual(first.items.count, 4)
        XCTAssertEqual(first.deferredPages, ["a": 1])
        let expanded = MultiSiteSearch.merging(existing: first.items, incoming: old, keyword: "film",
            maximumRetainedCandidates: 8, maximumResultsPerSite: 8)
        XCTAssertEqual(Set(expanded.items.map(\.id)), Set((old + incoming).map(\.id)))
        XCTAssertTrue(expanded.deferredPages.isEmpty)
    }

    let site = SiteConfiguration(key: "fixture", name: "Fixture", type: 3, api: "csp_Test")
    func page(_ number: Int, ids: [String], end: CategoryPageContinuation = .unknown) -> VideoPage {
        var pagination = Pagination(page: number, pageCount: nil)
        pagination.continuation = end
        pagination.hasMore = end != .end
        return VideoPage(items: ids.map { VideoSummary(siteKey: "fixture", siteName: "Fixture", videoID: $0, title: $0) }, pagination: pagination)
    }

    func testRepeatRemainsRetryableButExplicitRepeatedFinalPageEnds() {
        var cursor = SearchPageCursor(keyword: "k")
        XCTAssertTrue(cursor.accept(page(1, ids: ["a"]), requestedPage: 1))
        XCTAssertFalse(cursor.accept(page(2, ids: ["a"]), requestedPage: 2))
        XCTAssertEqual(cursor.nextPage, 2)
        XCTAssertTrue(cursor.uncertain)
        XCTAssertFalse(cursor.ended)
        XCTAssertTrue(cursor.accept(page(2, ids: ["a"], end: .end), requestedPage: 2))
        XCTAssertTrue(cursor.ended)
    }

    func testEmptyDeclaredMoreAndWrongPageDoNotAdvance() {
        var cursor = SearchPageCursor(keyword: "k")
        XCTAssertFalse(cursor.accept(page(1, ids: [], end: .more), requestedPage: 1))
        XCTAssertFalse(cursor.accept(page(2, ids: ["a"]), requestedPage: 1))
        XCTAssertEqual(cursor.nextPage, 1)
        XCTAssertTrue(cursor.accept(page(1, ids: [], end: .end), requestedPage: 1))
        XCTAssertTrue(cursor.ended)
    }

    func testSearchDecoderRejectsErrorsInsteadOfReportingEmptyEnd() throws {
        for json in ["null", "not-json", "{}", #"{"list":null}"#, #"{"success":false,"list":[]}"#] {
            XCTAssertThrowsError(try SpiderResponseMapper.searchPage(.string(json), site: site, baseURL: nil, page: 1), json)
        }
        let valid = try SpiderResponseMapper.searchPage(.string(#"{"list":[]}"#), site: site, baseURL: nil, page: 1)
        XCTAssertEqual(valid.pagination.continuation, .end)
        let unknown = try SpiderResponseMapper.searchPage(.string(#"{"list":[{"vod_id":"a","vod_name":"A"}]}"#), site: site, baseURL: nil, page: 1)
        XCTAssertEqual(unknown.pagination.continuation, .unknown)
    }

    func testSearchDecoderRetainsLegacyZeroCountAsUnknownWhenResultsExist() throws {
        let result = try SpiderResponseMapper.searchPage(.string(#"{"pagecount":0,"list":[{"vod_id":"a","vod_name":"A"}]}"#), site: site, baseURL: nil, page: 1)
        XCTAssertEqual(result.pagination.continuation, .unknown)
    }

    func testInitialBudgetKeepsCursorForPageFourAndExplicitEndStops() async {
        let recorder = SearchCursorRecorder()
        let provider = ContinuationFixture(site: site)
        let search = MultiSiteSearch(maximumPagesPerSite: 3)
        var initial: [VideoSummary] = []
        for await event in search.search(providers: [provider], keyword: "film", onPage: { await recorder.accept($0) }) {
            if case .snapshot(let snapshot) = event { initial = snapshot.items }
        }
        var cursor = await recorder.cursor
        XCTAssertEqual(initial.count, 3)
        XCTAssertEqual(cursor.nextPage, 4)
        XCTAssertFalse(cursor.ended)
        switch await search.nextPage(provider: provider, cursor: cursor) {
        case .success(let page, let keyword):
            XCTAssertEqual(keyword, "film")
            XCTAssertEqual(page.pagination.page, 4)
            XCTAssertTrue(cursor.accept(page, requestedPage: 4))
            XCTAssertTrue(cursor.ended)
            XCTAssertEqual(MultiSiteSearch.merging(existing: initial, incoming: page.items,
                keyword: keyword, maximumRetainedCandidates: 100, maximumResultsPerSite: 100).items.count, 4)
        default: XCTFail("Expected resumable page four")
        }
    }

    func testCancelledContinuationDoesNotCommitAResponse() async {
        let task = Task { await MultiSiteSearch().nextPage(provider: ContinuationFixture(site: site, delay: 1_000_000_000), cursor: SearchPageCursor(keyword: "film")) }
        task.cancel()
        if case .cancelled = await task.value {} else { XCTFail("Cancellation must remain cancellation") }
    }
}

private actor SearchCursorRecorder {
    var cursor = SearchPageCursor(keyword: "film")
    func accept(_ progress: SearchPageProgress) {
        cursor.keyword = progress.keyword
        cursor.accept(progress.page, requestedPage: progress.requestedPage)
    }
}

private struct ContinuationFixture: SiteProvider {
    let site: SiteConfiguration
    var delay: UInt64 = 0
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { try await search(keyword: "film", page: page, quick: false) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        var pagination = Pagination(page: page, pageCount: 4)
        pagination.continuation = page < 4 ? .more : .end
        return VideoPage(items: [VideoSummary(siteKey: site.key, siteName: site.name, videoID: "\(page)", title: "\(keyword) \(page)")], pagination: pagination)
    }
}
