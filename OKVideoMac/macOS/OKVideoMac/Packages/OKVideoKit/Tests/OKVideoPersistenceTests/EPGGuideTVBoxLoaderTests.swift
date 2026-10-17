import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class EPGGuideTVBoxLoaderTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1704067200)
    private func channel(_ id: String, api: Bool = true) -> LiveChannel {
        .init(groupName: "Synthetic", name: id, tvgID: id, streams: [],
              epgAPI: api ? .init(template: "https://guide.example.invalid/?channel=\(id)&date={date}", timeZoneID: "UTC") : nil,
              explicitID: id)
    }
    private func demand(_ channels: [LiveChannel], source: LiveSourceID, twoSlices: Bool = true) throws -> EPGGuideDemand {
        var slices = [try EPGGuideTimeSlice(start: anchor, end: anchor.addingTimeInterval(12 * 3600))]
        if twoSlices { slices.append(try .init(start: anchor.addingTimeInterval(12 * 3600), end: anchor.addingTimeInterval(24 * 3600))) }
        return try .init(source: .init(source), revision: String(repeating: "a", count: 64),
                         demandRevision: UUID(), capability: .tvboxDay, channels: channels,
                         visibleRange: 0..<channels.count, slices: slices)
    }

    func testTwoSlicesCacheDailyFetchesAndKeepOvernightProgramme() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-TVBox-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let client = DayClient()
        let source = LiveSourceID.imported(UUID())
        let channels = (0..<8).map { channel("fixture-\($0)") }
        let request = try demand(channels, source: source)
        let snapshot = try await EPGGuideTVBoxLoader.load(repository: repository, demand: request,
                                                        httpClient: client, xmltvKey: nil)
        XCTAssertEqual(snapshot.rows.count, 8)
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.state == .ready && $0.programmes.count == 3 })
        XCTAssertTrue(snapshot.rows[0].programmes[0].start < anchor)
        XCTAssertEqual(Set(snapshot.rows[0].programmes.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.rows[0].token?.demandRevision, request.demandRevision)
        let before = await client.metrics()
        XCTAssertEqual(before.calls, 16)
        XCTAssertLessThanOrEqual(before.peak, EPGGuideLimits.maximumRunning)
        XCTAssertEqual(before.maximumDuplicate, 1)
        let batch = try await EPGGuideTVBoxLoader.nowNext(repository: repository, source: source, revision: request.revision,
            channel: channels[0], at: anchor.addingTimeInterval(11.5 * 3600), demandRevision: UUID(), httpClient: client)
        XCTAssertEqual(batch.items.first?.current?.title, "Synthetic morning")
        XCTAssertEqual(batch.items.first?.next?.title, "Synthetic overnight")
        let after = await client.metrics()
        XCTAssertEqual(after.calls, before.calls)
        _ = await repository.close()
    }

    func testXMLTVFallbackAndAPIRowsAreDeliveredTogether() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-TVBox-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let xml = Data("""
        <tv><channel id="xml"><display-name>xml</display-name></channel>
        <programme channel="xml" start="20240101110000 +0000" stop="20240101120000 +0000"><title>Synthetic XML</title></programme></tv>
        """.utf8)
        let server = try EPGImportTestServer(xml: xml, gzip: Data()); defer { server.close() }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let source = LiveSourceID.imported(UUID())
        let request = try demand([channel("api"), channel("xml", api: false)], source: source, twoSlices: false)
        let key = EPGRequestKey(source: source, revision: request.revision, resource: "xmltv")
        _ = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"), force: true)
        let snapshot = try await EPGGuideTVBoxLoader.load(repository: repository, demand: request,
                                                        httpClient: DayClient(), xmltvKey: key)
        XCTAssertEqual(snapshot.rows.map(\.state), [.ready, .ready])
        XCTAssertEqual(snapshot.rows[1].programmes.map(\.title), ["Synthetic XML"])
        XCTAssertEqual(snapshot.coherence, .perRowToken)
        XCTAssertNotEqual(snapshot.rows[0].token?.resourceIdentity, snapshot.rows[1].token?.resourceIdentity)
        _ = await repository.close()
    }

    func testOneBadDateResponseDoesNotHideOtherChannels() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-TVBox-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let request = try demand([channel("good"), channel("broken"), channel("no-guide", api: false)],
                                 source: .imported(UUID()), twoSlices: false)
        let result = try await EPGGuideTVBoxLoader.load(repository: repository, demand: request,
                                                       httpClient: DayClient(broken: "broken"), xmltvKey: nil)
        XCTAssertEqual(result.rows[0].state, .ready)
        XCTAssertEqual(result.rows[1].state, .failed(.unavailable))
        XCTAssertTrue(result.rows[1].programmes.isEmpty)
        XCTAssertEqual(result.rows[2].state, .unsupported)
        _ = await repository.close()
    }

    func testUnavailableDateKeepsKnownProgrammesAndMarksCoverage() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-TVBox-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let request = try demand([channel("fixture")], source: .imported(UUID()), twoSlices: false)
        let client = DayClient(missingDay: "2023-12-31")
        let value = try await EPGGuideTVBoxLoader.load(repository: repository, demand: request,
                                                     httpClient: client, xmltvKey: nil)
        XCTAssertEqual(value.rows[0].state, .truncated(.sourceCoverage))
        XCTAssertEqual(value.rows[0].programmes.map(\.title), ["Synthetic morning"])
        let before = await client.metrics()
        _ = try await EPGGuideTVBoxLoader.load(repository: repository, demand: request, httpClient: client, xmltvKey: nil)
        let after = await client.metrics()
        XCTAssertEqual(before.calls, after.calls)
        _ = await repository.close()
    }

    func testCancellationDoesNotPublishACompletedOldDemand() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-TVBox-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let request = try demand([channel("fixture")], source: .imported(UUID()))
        let task = Task { try await EPGGuideTVBoxLoader.load(repository: repository, demand: request,
                                                            httpClient: DayClient(), xmltvKey: nil) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled demand must not return a snapshot") } catch {}
        _ = await repository.close()
    }
}

private actor DayClient: HTTPClient {
    let broken: String?
    let missingDay: String?
    init(broken: String? = nil, missingDay: String? = nil) { self.broken = broken; self.missingDay = missingDay }
    private var counts: [String: Int] = [:]
    private var active = 0, peak = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        active += 1; peak = max(peak, active); defer { active -= 1 }
        counts[request.url.absoluteString, default: 0] += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let day = query.first { $0.name == "date" }?.value ?? ""
        let channel = query.first { $0.name == "channel" }?.value ?? ""
        if day == missingDay { return .init(url: request.url, statusCode: 404, headers: [:], body: Data()) }
        let object: [String: Any] = ["date": channel == broken ? "wrong" : day, "epg_data": [
            ["start":"11:00", "end":"12:00", "title":"Synthetic morning"],
            ["start":"23:30", "end":"00:30", "title":"Synthetic overnight"]]]
        return .init(url: request.url, statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
    func metrics() -> (calls: Int, peak: Int, maximumDuplicate: Int) {
        (counts.values.reduce(0,+), peak, counts.values.max() ?? 0)
    }
}
