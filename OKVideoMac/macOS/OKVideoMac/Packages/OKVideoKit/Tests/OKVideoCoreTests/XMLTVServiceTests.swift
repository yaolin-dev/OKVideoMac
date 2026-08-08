import XCTest
@testable import OKVideoCore

final class XMLTVServiceTests: XCTestCase {
    func testFreshDiskCacheAvoidsSecondRequest() async throws {
        let counter = EPGRequestCounter()
        let client = EPGFixtureHTTPClient(counter: counter)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OKVideoMacEPGTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = URL(string: "https://example.invalid/epg.xml")!
        let date = Date(timeIntervalSince1970: 100)

        let first = try XMLTVService(
            httpClient: client,
            cacheDirectory: directory,
            now: { date }
        )
        _ = try await first.guide(for: url)

        let second = try XMLTVService(
            httpClient: client,
            cacheDirectory: directory,
            now: { date.addingTimeInterval(60) }
        )
        let guide = try await second.guide(for: url)

        XCTAssertEqual(guide.programmes.first?.title, "Fixture")
        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 1)
    }
}

private actor EPGRequestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct EPGFixtureHTTPClient: HTTPClient {
    let counter: EPGRequestCounter

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await counter.increment()
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data(
                """
                <tv>
                  <channel id="fixture"><display-name>Fixture TV</display-name></channel>
                  <programme channel="fixture" start="20260729200000 +0800" stop="20260729210000 +0800">
                    <title>Fixture</title>
                  </programme>
                </tv>
                """.utf8
            )
        )
    }
}
