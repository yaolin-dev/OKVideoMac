import XCTest
@testable import OKVideoCore

final class LiveSourceLoaderTests: XCTestCase {
    func testRemoteM3ULoadUsesFinalResponseURLAsBase() async throws {
        let finalURL = URL(string: "https://cdn.example.invalid/live/main.m3u")!
        let client = LiveLoaderStubHTTPClient(
            response: HTTPResponse(
                url: finalURL,
                statusCode: 200,
                headers: ["Content-Type": "application/x-mpegURL"],
                body: Data(
                    """
                    #EXTM3U
                    #EXTINF:-1 group-title="Fixture",Channel
                    stream/index.m3u8
                    """.utf8
                )
            )
        )

        let loaded = try await LiveSourceLoader(httpClient: client)
            .load(.remote(URL(string: "http://example.invalid/live")!))

        XCTAssertEqual(
            loaded.baseURL?.absoluteString,
            "https://cdn.example.invalid/live/"
        )
        XCTAssertEqual(
            loaded.playlist.groups.first?.channels.first?.streams.first?.url?
                .absoluteString,
            "https://cdn.example.invalid/live/stream/index.m3u8"
        )
    }
}

private struct LiveLoaderStubHTTPClient: HTTPClient {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}


private actor SettingsBudgetCaptureHTTP: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        let body = requests.count == 1 ? #"{"url":"https://fixture.invalid/list.m3u"}"# : "#EXTM3U\n#EXTINF:-1,Channel\nhttps://fixture.invalid/media\n"
        return HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

final class SettingsSourceBudgetTests: XCTestCase {
    func testNestedLiveSourceSharesOneBudgetAndBoundsBothDownloads() async throws {
        let transport = SettingsBudgetCaptureHTTP()
        _ = try await LiveSourceLoader(httpClient: transport).load(.remote(URL(string: "https://fixture.invalid/root")!))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertLessThan(try XCTUnwrap(requests[1].totalTimeout), try XCTUnwrap(requests[0].totalTimeout))
        XCTAssertLessThanOrEqual(requests[0].totalTimeout!, 30)
        XCTAssertTrue(requests.allSatisfy { $0.earlyResponseLimitBytes == LiveSourceLoader.maximumSourceSize })
    }
}
