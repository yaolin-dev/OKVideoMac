import XCTest
@testable import OKVideoCore

final class HTTPClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testGETPassesHeadersAndReturnsBody() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.invalid/")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"]
                )!,
                Data("ok".utf8)
            )
        }
        let response = try await makeClient().send(
            HTTPRequest(
                url: URL(string: "https://example.invalid/get")!,
                headers: ["Referer": "https://example.invalid/"]
            )
        )
        XCTAssertEqual(try response.text(), "ok")
    }

    func testNon2xxIsNotSilentlyAccepted() async {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            _ = try await makeClient().send(
                HTTPRequest(
                    url: URL(string: "https://example.invalid/missing")!,
                    retryPolicy: .none
                )
            )
            XCTFail("Expected status error")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .statusCode(404))
        }
    }

    func testExplicitNon2xxAcceptancePreservesResponseBody() async throws {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"请先登录网盘"}"#.utf8)
            )
        }

        let response = try await makeClient().send(
            HTTPRequest(
                url: URL(string: "https://example.invalid/node")!,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )

        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(try response.text(), #"{"message":"请先登录网盘"}"#)
    }

    func testResponseSizeLimit() async {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(repeating: 1, count: 11)
            )
        }

        do {
            _ = try await makeClient().send(
                HTTPRequest(
                    url: URL(string: "https://example.invalid/large")!,
                    maximumResponseBytes: 10,
                    retryPolicy: .none
                )
            )
            XCTFail("Expected size error")
        } catch {
            XCTAssertEqual(
                error as? HTTPClientError,
                .responseTooLarge(limit: 10, actual: 11)
            )
        }
    }

    func testIdempotentRequestRetriesServerError() async throws {
        let counter = LockedCounter()
        MockURLProtocol.handler = { request in
            let value = counter.increment()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: value == 1 ? 503 : 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("ok".utf8)
            )
        }

        let response = try await makeClient().send(
            HTTPRequest(
                url: URL(string: "https://example.invalid/retry")!,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 1, initialDelay: 0)
            )
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(counter.value, 2)
    }

    func testUnsafeSchemeIsRejected() async {
        do {
            _ = try await makeClient().send(
                HTTPRequest(url: URL(string: "file:///tmp/secret")!)
            )
            XCTFail("Expected scheme error")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .invalidScheme("file"))
        }
    }

    func testConfigurationHeaderRuleAppliesWithoutReplacingRequestHeaders() async throws {
        let recorder = HeaderRecordingHTTPClient()
        let client = ConfigurationPolicyHTTPClient(
            base: recorder,
            rules: [
                HeaderRuleConfiguration(
                    host: "*.example.invalid",
                    header: .object([
                        "Referer": .string("https://policy.example.invalid/"),
                        "User-Agent": .string("PolicyAgent")
                    ])
                )
            ]
        )
        _ = try await client.send(
            HTTPRequest(
                url: URL(string: "https://media.example.invalid/video")!,
                headers: ["User-Agent": "RequestAgent"]
            )
        )
        let recordedRequest = await recorder.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.headers["Referer"], "https://policy.example.invalid/")
        XCTAssertEqual(request.headers["User-Agent"], "PolicyAgent")
    }

    private func makeClient() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSessionHTTPClient(configuration: configuration)
    }
}

private actor HeaderRecordingHTTPClient: HTTPClient {
    private(set) var lastRequest: HTTPRequest?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lastRequest = request
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: [:],
            body: Data()
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}
