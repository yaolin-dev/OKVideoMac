import XCTest
@testable import OKVideoCore

final class CategoryIdentityRegressionTests: XCTestCase {
    func testProviderHomeKeepsFirstDuplicateCategoryAndDropsBlankIDs() throws {
        let site = SiteConfiguration(key: "duplicate-fixture", name: "Fixture", type: 3, api: "csp_Fixture")
        let payload = #"{"class":[{"type_id":"movie","type_name":"First"},{"type_id":"movie","type_name":"Duplicate"},{"type_id":" ","type_name":"Blank"},{"type_id":"series","type_name":"Series"}]}"#
        let home = try SpiderResponseMapper.home(.string(payload), homeVideoValue: nil, site: site, baseURL: nil)
        XCTAssertEqual(home.categories.map(\.id), ["movie", "series"])
        XCTAssertEqual(home.categories.map(\.name), ["First", "Series"])
    }

    func testLegacyCachedDuplicatesPreserveFirstCompletePayloadAndOpaqueIDs() throws {
        let first = VideoCategory(id: "action", name: "Configure", filters: [
            VideoFilter(id: "mode", name: "Mode", options: [.init(name: "First", value: "1")])
        ], contentKind: .action)
        var legacy = SiteHome(categories: [], recommendations: [])
        // Simulate a snapshot persisted before normalization existed.
        legacy.categories = [first, .init(id: "action", name: "Duplicate", contentKind: .media),
                             .init(id: "", name: "Blank"), .init(id: " action ", name: "Opaque")]
        let restored = try JSONDecoder().decode(SiteHome.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored.categories, [first, .init(id: " action ", name: "Opaque")])
        XCTAssertEqual(SiteHome(categories: legacy.categories, recommendations: []).categories, restored.categories)
        XCTAssertEqual(try JSONDecoder().decode(SiteHome.self, from: JSONEncoder().encode(restored)), restored)
    }
}

final class CategoryPaginationTests: XCTestCase {
    private let site = SiteConfiguration(key: "fixture", name: "Fixture", type: 3, api: "csp_Fixture")
    private func page(_ json: String, requested: Int = 2) throws -> VideoPage {
        try SpiderResponseMapper.javaDexCategoryPage(.string(json), site: site, baseURL: nil, page: requested)
    }

    func testUnknownLengthNonemptyListCanContinueUntilValidEmptyList() throws {
        let result = try page(#"{"list":[{"vod_id":"one","vod_name":"One"}]}"#)
        XCTAssertTrue(result.pagination.hasMore)
        XCTAssertEqual(result.pagination.continuation, .unknown)
        let end = try page(#"{"list":[]}"#)
        XCTAssertFalse(end.pagination.hasMore)
        XCTAssertEqual(end.pagination.continuation, .end)
    }

    func testExplicitEndAndMoreArePreservedForStoreClassification() throws {
        XCTAssertEqual(try page(#"{"page":2,"pagecount":2,"list":[{"vod_id":"one","vod_name":"One"}]}"#).pagination.continuation, .end)
        XCTAssertEqual(try page(#"{"pagecount":99,"list":[]}"#).pagination.continuation, .more)
        XCTAssertTrue(try page(#"{"hasMore":true,"list":[]}"#).pagination.hasMore)
        XCTAssertTrue(try page(#"{"total":100,"limit":20,"list":[]}"#).pagination.hasMore)
        XCTAssertFalse(try page(#"{"has_more":false,"list":[]}"#).pagination.hasMore)
    }

    func testInvalidOrErrorResponsesNeverBecomeSuccessfulEmptyPages() throws {
        for input in ["", "null", "not-json", "{}", #"{"list":null}"#,
                      #"{"list":[42]}"#, #"{"error":"timeout","list":[]}"#,
                      #"{"success":false,"msg":"denied","list":[]}"#] {
            XCTAssertThrowsError(try page(input), input)
        }
        XCTAssertThrowsError(try SpiderResponseMapper.javaDexCategoryPage(.null, site: site, baseURL: nil, page: 2))
        // A descriptive success message is not, by itself, a failure.
        XCTAssertEqual(try page(#"{"msg":"success","list":[]}"#).pagination.continuation, .end)
    }

    func testWrongPageOrContradictoryMetadataIsUncertain() {
        for input in [#"{"page":1,"pagecount":99,"list":[]}"#,
                      #"{"pagecount":2,"hasMore":true,"list":[]}"#] {
            XCTAssertThrowsError(try page(input)) { XCTAssertTrue($0 is CategoryPageResponseError) }
        }
    }

    func testLegacyPaginationCacheDecodesAndNewEvidenceRoundTrips() throws {
        let legacy = try JSONDecoder().decode(Pagination.self, from: Data(#"{"page":1,"pageCount":3,"hasMore":true}"#.utf8))
        XCTAssertNil(legacy.continuation)
        let value = try page(#"{"list":[{"vod_id":"one","vod_name":"One"}]}"#).pagination
        XCTAssertEqual(try JSONDecoder().decode(Pagination.self, from: JSONEncoder().encode(value)), value)
    }

    func testXMLMustContainARealListToConfirmEnd() throws {
        let errorDocument = try UpstreamResponseDecoder.decodeXML(Data("<rss><error>offline</error></rss>".utf8), site: site)
        XCTAssertThrowsError(try errorDocument.categoryPagination(requestedPage: 2))
        let terminal = try UpstreamResponseDecoder.decodeXML(Data("<rss><list page=\"2\" pagecount=\"2\"></list></rss>".utf8), site: site)
        XCTAssertEqual(try terminal.categoryPagination(requestedPage: 2).continuation, .end)
    }

    func testHomeAndSearchCompatibilityPathsRemainTolerant() throws {
        XCTAssertTrue(try SpiderResponseMapper.page(.string("not-json"), site: site, baseURL: nil, page: 2).items.isEmpty)
        XCTAssertTrue(try SpiderResponseMapper.home(.null, homeVideoValue: nil, site: site, baseURL: nil).recommendations.isEmpty)
    }
}
