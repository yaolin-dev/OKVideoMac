import XCTest
@testable import OKVideoCore

final class XtreamArchiveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1704157200)
    private var programme: EPGProgramme {
        .init(channelID: "fixture", title: "Synthetic", start: Date(timeIntervalSince1970: 1704067217),
              end: Date(timeIntervalSince1970: 1704069017))
    }
    private func builder() throws -> XtreamURLBuilder {
        try .init(endpoint: .init(serverURL: URL(string: "https://example.invalid/subpath")!))
    }
    func testMinuteAddressKeepsSecondAccuratePlaybackBounds() throws {
        let request = try builder().archiveRequest(credentials: .init(username: "synthetic", password: "fixture"),
            streamID: "42", outputFormat: "ts", programme: programme, offset: 601.5, now: now, serverTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(request.url.path, "/subpath/timeshift/synthetic/fixture/21/2024-01-01:08-10/42.ts")
        XCTAssertEqual(request.leadIn, 18.5, accuracy: 0.001)
        XCTAssertEqual(request.remainingDuration, 1198.5, accuracy: 0.001)
        XCTAssertEqual(request.remainingDuration + request.leadIn, 1217, accuracy: 0.001)
        let query = URLComponents(url: request.legacyURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "start" }?.value, "2024-01-01:08-10")
        XCTAssertEqual(query.first { $0.name == "duration" }?.value, "21")
        XCTAssertEqual(request.legacyURL.path, "/subpath/streaming/timeshift.php")
    }
    func testCredentialsStayInTheirOwnEncodedSegmentsAndDiagnosticsRedactThem() throws {
        let request = try builder().archiveRequest(credentials: .init(username: "user/one", password: "secret&/?#%"),
            streamID: "42", outputFormat: "m3u8", programme: programme, now: now, serverTimeZoneID: "UTC")
        XCTAssertTrue(request.url.absoluteString.contains("user%2Fone/secret&%2F%3F%23%25/"))
        XCTAssertNil(request.url.query)
        XCTAssertNil(request.url.fragment)
        XCTAssertFalse(String(reflecting: request).contains("secret"))
    }
    func testPHPQueriesPreserveLiteralPlusInAccountValues() throws {
        let credentials = XtreamCredentials(username: "user+name", password: "p+word")
        let api = try builder().playerAPIURL(credentials: credentials, action: .simpleDataTable)
        let archive = try builder().archiveRequest(credentials: credentials, streamID: "42", outputFormat: "ts",
            programme: programme, now: now, serverTimeZoneID: "UTC")
        for url in [api, archive.legacyURL] {
            let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
            XCTAssertTrue(encoded.contains("user%2Bname"))
            XCTAssertTrue(encoded.contains("p%2Bword"))
        }
    }
    func testUnknownTimezoneAmbiguousClockAndInvalidIntervalsAreRejected() throws {
        for zone in [nil, "invalid-zone"] as [String?] {
            XCTAssertThrowsError(try builder().archiveRequest(credentials: .init(username: "u", password: "p"),
                streamID: "42", outputFormat: "ts", programme: programme, now: now, serverTimeZoneID: zone))
        }
        let folded = EPGProgramme(channelID: "fixture", title: "Synthetic fold",
            start: Date(timeIntervalSince1970: 1730615400), end: Date(timeIntervalSince1970: 1730617200))
        XCTAssertThrowsError(try builder().archiveRequest(credentials: .init(username: "u", password: "p"), streamID: "42",
            outputFormat: "ts", programme: folded, now: folded.end.addingTimeInterval(3600), serverTimeZoneID: "America/New_York"))
        XCTAssertThrowsError(try builder().archiveRequest(credentials: .init(username: "u", password: "p"), streamID: "42",
            outputFormat: "ts", programme: programme, offset: .nan, now: now, serverTimeZoneID: "UTC"))
        XCTAssertThrowsError(try builder().archiveRequest(credentials: .init(username: "u", password: "p"), streamID: "42",
            outputFormat: "ts", programme: programme, offset: 1800, now: now, serverTimeZoneID: "UTC"))
    }
    func testProgrammeTimelineNeverMovesBeforeRequestedPointOrPastEnd() {
        XCTAssertEqual(XtreamArchivePolicy.programmePosition(mediaPosition: 0, offset: 601.5, leadIn: 18.5, duration: 1800), 601.5)
        XCTAssertEqual(XtreamArchivePolicy.programmePosition(mediaPosition: 18.5, offset: 601.5, leadIn: 18.5, duration: 1800), 601.5)
        XCTAssertEqual(XtreamArchivePolicy.programmePosition(mediaPosition: 1217, offset: 601.5, leadIn: 18.5, duration: 1800), 1800)
    }
    func testArchiveAvailabilityRequiresDeclaredCapabilityAndProgrammeFlag() throws {
        let locator = try XtreamLivePlaybackLocator(providerID: UUID(), streamID: "42", outputFormat: .ts)
        let stream = try LiveStream(name: "TS", target: .provider(.xtreamLive(locator)),
                                    archive: .init(retentionDays: 7))
        XCTAssertNil(stream.url)
        XCTAssertEqual(LiveCatchupPolicy.availability(stream: stream, programme: programme, now: now), .available)
        var denied = programme; denied.catchupAvailable = false
        XCTAssertEqual(LiveCatchupPolicy.availability(stream: stream, programme: denied, now: now), .unsupported)
        XCTAssertEqual(stream.catchupSeekPolicy, .request)
        XCTAssertEqual(try JSONDecoder().decode(LiveStream.self, from: JSONEncoder().encode(stream)), stream)
        let expired = now.addingTimeInterval(8 * 86400)
        XCTAssertEqual(LiveCatchupPolicy.availability(stream: stream, programme: programme, now: expired), .expired)
    }
    func testArchiveDTOReadsOnlyMetadata() throws {
        let data = Data(#"[{"stream_id":"42","name":"Synthetic","tv_archive":"1","tv_archive_duration":"7","direct_source":"https://example.invalid/private"}]"#.utf8)
        let value = try JSONDecoder().decode([XtreamLiveStreamDTO].self, from: data)[0]
        XCTAssertEqual(value.tvArchive, true)
        XCTAssertEqual(value.tvArchiveDuration, 7)
    }
    func testFullGuideEndpointPreservesArchiveFlagWithoutShortLimit() async throws {
        let fixture = ArchiveAPIClient()
        let client = XtreamClient(endpoint: try .init(serverURL: URL(string: "https://example.invalid")!),
                                  credentials: .init(username: "synthetic", password: "fixture"),
                                  httpClient: fixture, userAgent: "Fixture")
        let short = try await client.shortEPG(streamID: "42")
        let full = try await client.archiveEPG(streamID: "42")
        XCTAssertEqual(short.guide.programmes.count, 1)
        XCTAssertEqual(full.guide.programmes.count, 20)
        XCTAssertEqual(full.guide.programmes[0].catchupAvailable, false)
        XCTAssertEqual(full.guide.programmes[1].catchupAvailable, true)
        let actions = await fixture.actions
        XCTAssertEqual(actions, ["get_short_epg", "get_simple_data_table"])
        let hasLimit = await fixture.archiveHadLimit
        XCTAssertFalse(hasLimit)
    }
}
private actor ArchiveAPIClient: HTTPClient {
    var actions: [String] = []
    var archiveHadLimit = false
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        let action = items.first { $0.name == "action" }!.value!
        actions.append(action)
        let archive = action == "get_simple_data_table"
        if archive { archiveHadLimit = items.contains { $0.name == "limit" } }
        let rows: [[String: Any]] = (0..<(archive ? 20 : 1)).map { index in
            ["title": "Synthetic \(index)", "start_timestamp": 1704067200 + index * 3600,
             "stop_timestamp": 1704067200 + (index + 1) * 3600, "has_archive": index == 0 ? 0 : 1]
        }
        return .init(url: request.url, statusCode: 200, headers: [:],
                     body: try JSONSerialization.data(withJSONObject: ["epg_listings": rows]))
    }
}
