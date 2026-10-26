import XCTest
import Network
@testable import OKVideoCore

final class HTTPClientTests: XCTestCase {
    func testTotalDeadlineCancelsActiveNetworkAndLeavesSessionUsable() async throws {
        let server = try BoundedKeepAliveServer()
        defer { server.stop() }
        let port = try await server.port()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        let client = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        var request = server.request(port: port, path: "slow-deadline")
        request.totalTimeout = 0.03
        do { _ = try await client.send(request); XCTFail("Deadline was ignored") }
        catch { XCTAssertEqual(error as? HTTPClientError, .timeout) }
        let response = try await client.send(server.request(port: port, path: "after-deadline"))
        XCTAssertEqual(try response.text(), "after-deadline")
    }

    func testTotalDeadlineIncludesRetryBackoff() async throws {
        let attempts = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = attempts.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = URLSessionHTTPClient(configuration: configuration)
        let request = HTTPRequest(url: URL(string: "https://fixture.invalid/retry")!, timeout: 3, totalTimeout: 0.03,
            retryPolicy: .init(maximumRetries: 2, initialDelay: 1))
        do { _ = try await client.send(request); XCTFail("Retry delay escaped the deadline") }
        catch { XCTAssertEqual(error as? HTTPClientError, .timeout) }
        XCTAssertEqual(attempts.value, 1)
    }

    func testExplicitCancellationWithDeadlineStillReportsCancellation() async throws {
        let server = try BoundedKeepAliveServer()
        defer { server.stop() }
        let port = try await server.port()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        let client = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        var request = server.request(port: port, path: "slow-user-cancel")
        request.totalTimeout = 5
        let task = Task { try await client.send(request) }
        try await server.waitForRequests(1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request escaped") }
        catch { XCTAssertEqual(error as? HTTPClientError, .cancelled) }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPooledBoundedRequestsReuseTCPConnectionAndKeepBodiesSeparate() async throws {
        let server = try BoundedKeepAliveServer()
        defer { server.stop() }
        let port = try await server.port()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0] // Loopback fixture must not use a machine-wide upstream proxy.
        let client = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        for path in ["first", "second", "third"] {
            let response = try await client.send(server.request(port: port, path: path))
            XCTAssertEqual(try response.text(), path)
        }
        XCTAssertEqual(server.connectionCount, 1, "The bounded path must keep the TCP connection alive")
    }

    func testPooledCancellationDoesNotCancelConcurrentOrSubsequentRequests() async throws {
        let server = try BoundedKeepAliveServer()
        defer { server.stop() }
        let port = try await server.port()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0] // Loopback fixture must not use a machine-wide upstream proxy.
        let client = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        let cancelled = Task { try await client.send(server.request(port: port, path: "slow-cancel")) }
        try await server.waitForRequests(1)
        let retained = Task { try await client.send(server.request(port: port, path: "slow-retained")) }
        try await server.waitForRequests(2)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled response escaped") }
        catch { XCTAssertEqual(error as? HTTPClientError, .cancelled) }
        let response = try await retained.value
        XCTAssertEqual(try response.text(), "slow-retained")
        let next = try await client.send(server.request(port: port, path: "after-cancel"))
        XCTAssertEqual(try next.text(), "after-cancel")
    }

    func testPooledBoundedLimitsAndRedirectRejectionDoNotPoisonSession() async throws {
        let server = try BoundedKeepAliveServer()
        defer { server.stop() }
        let port = try await server.port()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0] // Loopback fixture must not use a machine-wide upstream proxy.
        let client = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        for path in ["oversize", "chunked-oversize", "redirect"] {
            do { _ = try await client.send(server.request(port: port, path: path, limit: 10)); XCTFail("Accepted " + path) }
            catch {
                guard let error = error as? HTTPClientError else { return XCTFail("Unexpected error: \(error)") }
                if path == "redirect" { XCTAssertEqual(error, .tooManyRedirects(0)) }
                else if case .responseTooLarge(let limit, let actual) = error { XCTAssertEqual(limit, 10); XCTAssertGreaterThan(actual, 10) }
                else { XCTFail("Unexpected error: \(error)") }
            }
            let healthy = try await client.send(server.request(port: port, path: "healthy"))
            XCTAssertEqual(try healthy.text(), "healthy")
        }
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

    func testEarlyResponseLimitIsOptInAndStopsOversizedResponse() async {
        let ordinary = HTTPRequest(
            url: URL(string: "https://example.invalid/ordinary")!
        )
        XCTAssertNil(ordinary.earlyResponseLimitBytes)
        XCTAssertEqual(ordinary.redirectPolicy, .follow)

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "11"]
                )!,
                Data(repeating: 1, count: 11)
            )
        }

        do {
            _ = try await makeClient().send(
                HTTPRequest(
                    url: URL(string: "https://example.invalid/large")!,
                    maximumResponseBytes: 10,
                    earlyResponseLimitBytes: 10,
                    retryPolicy: .none
                )
            )
            XCTFail("Expected early size error")
        } catch {
            XCTAssertEqual(
                error as? HTTPClientError,
                .responseTooLarge(limit: 10, actual: 11)
            )
        }
    }

    func testDefaultTransportRetainsSharedCookieAndCacheSemantics() {
        let original = URLSessionConfiguration.default
        let originalCache = original.urlCache
        let originalCredentials = original.urlCredentialStorage
        let client = URLSessionHTTPClient(configuration: original)
        let configuration = client.transportConfiguration

        XCTAssertTrue(configuration.httpShouldSetCookies)
        XCTAssertTrue(configuration.httpCookieStorage === HTTPCookieStorage.shared)
        XCTAssertTrue(configuration.urlCache === originalCache)
        XCTAssertTrue(configuration.urlCredentialStorage === originalCredentials)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testIsolatedEphemeralFactoryDisablesAllSessionStorage() {
        let client = URLSessionHTTPClient.isolatedEphemeral()
        let configuration = client.transportConfiguration

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        // Mutating an inspection copy must not weaken subsequent bounded loads.
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        XCTAssertFalse(client.transportConfiguration.httpShouldSetCookies)
        XCTAssertNil(client.transportConfiguration.httpCookieStorage)
    }

    func testIsolatedTransportIgnoresSharedAndResponseCookiesInBothLoadPaths() async throws {
        let host = "xtream-isolation-\(UUID().uuidString.lowercased()).invalid"
        let url = try XCTUnwrap(URL(string: "https://\(host)/player_api.php"))
        let sharedCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "existing_shared_session",
            .value: "test-only-cookie",
            .secure: "TRUE"
        ]))
        HTTPCookieStorage.shared.setCookie(sharedCookie)
        defer {
            // Remove only the unique fixture inserted by this test. Never
            // clear the application's or any other provider's shared cookies.
            HTTPCookieStorage.shared.deleteCookie(sharedCookie)
        }

        let requests = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = requests.increment()
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Set-Cookie": "xtream_response_session=private; Path=/; Secure",
                        "Content-Length": "2"
                    ]
                )!,
                Data("ok".utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let firstAccount = URLSessionHTTPClient(isolatedConfiguration: configuration)
        let secondAccount = URLSessionHTTPClient(isolatedConfiguration: configuration)
        let pooledAccount = URLSessionHTTPClient(isolatedConfiguration: configuration, reusesBoundedConnections: true)
        for client in [firstAccount, secondAccount, pooledAccount] {
            // The second request in each path also proves a Set-Cookie
            // response does not become account/session state.
            for limit: Int? in [nil, nil, 1_024, 1_024] {
                let response = try await client.send(HTTPRequest(
                    url: url,
                    earlyResponseLimitBytes: limit,
                    retryPolicy: .none
                ))
                XCTAssertEqual(try response.text(), "ok")
            }
        }
        XCTAssertEqual(requests.value, 12)
        let remaining = HTTPCookieStorage.shared.cookies(for: url) ?? []
        XCTAssertTrue(remaining.contains { $0.name == sharedCookie.name })
        XCTAssertFalse(remaining.contains { $0.name == "xtream_response_session" })
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

    func testRedirectDiagnosticsDescribeUpgradeDowngradeAndCrossHost() throws {
        let http = try XCTUnwrap(URL(string: "http://origin.invalid/bundle"))
        let https = try XCTUnwrap(URL(string: "https://cdn.invalid/bundle"))
        let downgrade = try XCTUnwrap(URL(string: "http://cdn.invalid/object.jpg"))
        let diagnostics = HTTPResponseDiagnostics(
            originalURL: http,
            redirects: [
                HTTPRedirectHop(statusCode: 301, sourceURL: http, destinationURL: https),
                HTTPRedirectHop(statusCode: 302, sourceURL: https, destinationURL: downgrade)
            ],
            finalURL: downgrade,
            statusCode: 200,
            contentType: "image/jpeg",
            contentLength: 42,
            duration: 0.75
        )

        XCTAssertTrue(diagnostics.crossedScheme)
        XCTAssertTrue(diagnostics.crossedHost)
        XCTAssertTrue(diagnostics.redirectedFromHTTPSIntoHTTP)
        XCTAssertEqual(diagnostics.redirects.map(\.statusCode), [301, 302])
        XCTAssertEqual(diagnostics.contentType, "image/jpeg")
    }

    func testRedirectDelegateReappliesOptInMediaHeadersAcrossOrigin() throws {
        let origin = try XCTUnwrap(
            URL(string: "https://d.pcs.baidu.com/file/signed")
        )
        let destination = try XCTUnwrap(
            URL(string: "https://appall01.baidupcs.com/file/signed")
        )
        var proposed = URLRequest(url: destination)
        proposed.setValue("URLSession", forHTTPHeaderField: "User-Agent")
        proposed.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let delegate = RedirectDelegate(
            maximumRedirects: 4,
            redirectedHeaders: [
                "Range": "bytes=0-0",
                "Referer": "https://pan.baidu.com/",
                "User-Agent": "netdisk;P2SP;android-android;"
            ]
        )

        let redirected = delegate.preparedRedirectRequest(
            proposed,
            originalURL: origin
        )

        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Range"),
            "bytes=0-0"
        )
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Referer"),
            "https://pan.baidu.com/"
        )
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "User-Agent"),
            "netdisk;P2SP;android-android;"
        )
        XCTAssertNil(
            redirected.value(forHTTPHeaderField: "Authorization")
        )
    }

    func testStrictRedirectPolicyAllowsOnlyOriginalOrigin() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.invalid/api"))

        XCTAssertTrue(
            HTTPRedirectSecurity.isAllowed(
                URL(string: "https://example.invalid:443/other"),
                from: origin,
                policy: .sameOriginNoDowngrade
            )
        )
        XCTAssertFalse(
            HTTPRedirectSecurity.isAllowed(
                URL(string: "http://example.invalid/other"),
                from: origin,
                policy: .sameOriginNoDowngrade
            )
        )
        XCTAssertFalse(
            HTTPRedirectSecurity.isAllowed(
                URL(string: "https://cdn.example.invalid/other"),
                from: origin,
                policy: .sameOriginNoDowngrade
            )
        )
    }

    func testXMLTVRedirectPolicyAllowsCDNButNeverHTTPSDowngrade() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.invalid/guide.xml?token=fixture"))
        XCTAssertTrue(HTTPRedirectSecurity.isAllowed(URL(string: "https://cdn.invalid/guide.gz"), from: origin, policy: .noDowngrade))
        XCTAssertFalse(HTTPRedirectSecurity.isAllowed(URL(string: "http://cdn.invalid/guide.gz"), from: origin, policy: .noDowngrade))
        XCTAssertFalse(HTTPRedirectSecurity.isAllowed(URL(string: "file:///tmp/guide.xml"), from: origin, policy: .noDowngrade))
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

/// Loopback HTTP/1.1 fixture verifies real connection reuse and cancellation;
/// URLProtocol alone cannot exercise the connection pool.
private final class BoundedKeepAliveServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bounded-http-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var requests = 0
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }
    func port() async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw URLError(.cannotConnectToHost)
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1000 {
            if requestCount >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw URLError(.timedOut)
    }
    func request(port: UInt16, path: String, limit: Int = 1024) -> HTTPRequest {
        HTTPRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, timeout: 3,
                    maximumResponseBytes: limit, earlyResponseLimitBytes: limit, maximumRedirects: 0, retryPolicy: .none)
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete else { return }
            var buffer = buffered; buffer.append(data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { self.receive(connection, buffered: buffer); return }
            let header = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
            let path = header.components(separatedBy: " ").dropFirst().first?.dropFirst().description ?? ""
            self.lock.lock(); self.requests += 1; self.lock.unlock()
            let response: String
            if path == "redirect" { response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\n\r\n" }
            else if path == "oversize" { response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n12345678901" }
            else if path == "chunked-oversize" { response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nB\r\n12345678901\r\n0\r\n\r\n" }
            else { response = "HTTP/1.1 200 OK\r\nContent-Length: \(path.utf8.count)\r\n\r\n\(path)" }
            self.queue.asyncAfter(deadline: .now() + (path.hasPrefix("slow") ? 0.2 : 0)) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            }
            self.receive(connection, buffered: Data(buffer[end.upperBound...]))
        }
    }
    func stop() {
        listener.cancel()
        lock.lock(); let copy = connections; lock.unlock()
        copy.forEach { $0.cancel() }
    }
}
