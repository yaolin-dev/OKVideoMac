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
            loaded.playlist.groups.first?.channels.first?.streams.first?.url
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
