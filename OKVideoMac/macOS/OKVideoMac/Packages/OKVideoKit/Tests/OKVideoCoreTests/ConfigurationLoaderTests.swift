import XCTest
@testable import OKVideoCore

final class ConfigurationLoaderTests: XCTestCase {
    func testRemoteLoadUsesFinalResponseAsBaseURL() async throws {
        let finalURL = URL(string: "https://cdn.example.invalid/config/main.json")!
        let client = StubHTTPClient(
            response: HTTPResponse(
                url: finalURL,
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {"sites":[{"key":"fixture","name":"Fixture","type":1,"api":"./api"}]}
                    """.utf8
                )
            )
        )
        let date = Date(timeIntervalSince1970: 123)
        let loaded = try await ConfigurationLoader(
            httpClient: client,
            now: { date }
        ).load(.remote(URL(string: "https://example.invalid/start.json")!))

        XCTAssertEqual(loaded.baseURL?.absoluteString, "https://cdn.example.invalid/config/")
        XCTAssertEqual(loaded.loadedAt, date)
        XCTAssertEqual(loaded.configuration.sites.first?.api, "./api")
    }

    func testRemoteLoadDecodesFongMiBase64ImageWrapper() async throws {
        let json = Data(
            #"{"sites":[{"key":"wrapped","name":"Wrapped","type":1,"api":"https://example.invalid/api"}]}"#
                .utf8
        )
        var wrapped = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        wrapped.append(Data("Fixture1**".utf8))
        wrapped.append(Data(json.base64EncodedString().utf8))
        let client = StubHTTPClient(
            response: HTTPResponse(
                url: URL(string: "http://example.invalid/tv")!,
                statusCode: 200,
                headers: ["Content-Type": "image/x-ms-bmp"],
                body: wrapped
            )
        )

        let loaded = try await ConfigurationLoader(httpClient: client)
            .load(.remote(URL(string: "http://example.invalid/tv")!))

        XCTAssertEqual(loaded.rawData, json)
        XCTAssertEqual(loaded.configuration.sites.first?.key, "wrapped")
    }

    func testRemoteLoadDecodesImageWrappedTVBoxJSONC() async throws {
        let jsonc = Data(
            #"""
            {
              "sites": [
                {"key":"first","name":"First","type":1,"api":"https://example.invalid/api"},
                // {"key":"disabled","name":"Disabled","type":1,"api":"https://example.invalid/off"},
              ],
              "lives": [],
            }
            """#.utf8
        )
        var wrapped = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        wrapped.append(Data("Random42**".utf8))
        wrapped.append(Data(jsonc.base64EncodedString().utf8))
        let client = StubHTTPClient(
            response: HTTPResponse(
                url: URL(string: "http://example.invalid/tv")!,
                statusCode: 200,
                headers: ["Content-Type": "image/x-ms-bmp"],
                body: wrapped
            )
        )

        let loaded = try await ConfigurationLoader(httpClient: client)
            .load(.remote(URL(string: "http://example.invalid/tv")!))

        XCTAssertEqual(loaded.rawData, jsonc)
        XCTAssertEqual(loaded.configuration.sites.map(\.key), ["first"])
    }

    func testImageWithoutFongMiPayloadIsRejectedClearly() async {
        let client = StubHTTPClient(
            response: HTTPResponse(
                url: URL(string: "https://example.invalid/avatar.jpg")!,
                statusCode: 200,
                headers: ["Content-Type": "image/jpeg"],
                body: Data([0xFF, 0xD8, 0xFF, 0xD9])
            )
        )

        do {
            _ = try await ConfigurationLoader(httpClient: client)
                .load(.remote(URL(string: "https://example.invalid/avatar.jpg")!))
            XCTFail("Expected image payload rejection")
        } catch {
            XCTAssertEqual(
                error as? AppError,
                .configuration(
                    "远程地址返回了图片，但没有找到有效的 FongMi Base64 配置"
                )
            )
        }
    }

    func testRemoteLoadHonorsCancellationAfterNetworkAwait() async throws {
        let response = HTTPResponse(
            url: URL(string: "https://example.invalid/config.json")!,
            statusCode: 200,
            headers: [:],
            body: Data(#"{"sites":[]}"#.utf8)
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ConfigurationLoader(
                httpClient: StubHTTPClient(response: response)
            ).load(.remote(response.url))
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation after HTTP response")
        } catch is CancellationError {
            // Expected: the loader observes cancellation before decode/parse.
        }
    }

    func testPastedLoadHonorsCancellationAfterParse() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ConfigurationLoader(
                httpClient: StubHTTPClient(
                    response: HTTPResponse(
                        url: URL(string: "https://example.invalid/")!,
                        statusCode: 200,
                        headers: [:],
                        body: Data()
                    )
                )
            ).load(.pasted(text: #"{"sites":[]}"#, baseURL: nil))
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation after parse")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private struct StubHTTPClient: HTTPClient {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}
