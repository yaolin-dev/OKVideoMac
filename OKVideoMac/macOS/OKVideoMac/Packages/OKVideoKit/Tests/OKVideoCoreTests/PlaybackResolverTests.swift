import XCTest
@testable import OKVideoCore

final class PlaybackResolverTests: XCTestCase {
    func testPlaybackResourceReferenceRoundTripsWithoutRuntimeSecrets() throws {
        let reference = PlaybackResourceReference(
            configurationIdentity: "configuration-v1",
            siteIdentity: "site-v1",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "provider://opaque/item/42",
            sourceIdentity: "source-hash",
            episodeIdentity: "episode-hash",
            stability: .providerStable,
            expiresAt: Date(timeIntervalSince1970: 123_456)
        )

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(
            PlaybackResourceReference.self,
            from: data
        )

        XCTAssertEqual(decoded, reference)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cookie"))
    }

    func testPlaybackMediaSessionKeepsRequestContextRuntimeOnly() {
        let reference = PlaybackResourceReference(
            configurationIdentity: "configuration-v1",
            siteIdentity: "site-v1",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "provider://opaque/item/42",
            sourceIdentity: "source-hash",
            episodeIdentity: "episode-hash",
            stability: .providerReplay
        )
        let session = PlaybackMediaSession(
            sessionID: "session-1",
            transport: .providerLoopback,
            mediaURL: "http://127.0.0.1:19978/proxy/media/session-1",
            headers: ["Authorization": "runtime-only"],
            authorizationContextReference: "bridge-context-1",
            proxyRequestID: "request-1",
            upstreamResourceFingerprint: String(repeating: "a", count: 64),
            refreshPerformed: true,
            redirectPolicy: .follow,
            rangePolicy: .forward,
            resourceReference: reference
        )
        let result = SitePlaybackResult(
            url: session.mediaURL,
            needsParsing: false,
            flag: "opaque",
            headers: session.headers,
            validationPolicy: .playerAuthoritative,
            resourceReference: reference,
            mediaSession: session
        )

        XCTAssertEqual(result.resourceReference, reference)
        XCTAssertEqual(result.mediaSession, session)
        XCTAssertEqual(result.mediaSession?.transport, .providerLoopback)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .forward)
        XCTAssertEqual(
            result.mediaSession?.upstreamResourceFingerprint,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(result.mediaSession?.refreshPerformed, true)
    }

    func testPlayerAuthoritativeDirectMediaBypassesGenericPreflight() async {
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(results: [:]),
            mediaProbe: FixtureMediaProbe(validURLs: [])
        )
        let result = SitePlaybackResult(
            url: "https://authenticated.example.invalid/movie.mp4",
            needsParsing: false,
            flag: "authenticated",
            headers: ["Cookie": "session=fixture"],
            validationPolicy: .playerAuthoritative
        )
        let request = PlaybackResolutionRequest(
            candidates: [
                PlaybackCandidate(
                    siteKey: "node",
                    siteName: "Node",
                    sourceName: "Authenticated",
                    episodeName: "Episode 1",
                    result: result
                )
            ],
            parsers: []
        )

        let events = await collect(resolver.resolve(request))

        XCTAssertTrue(events.contains { event in
            guard case .resolved(let media) = event else { return false }
            return media.url.absoluteString
                == "https://authenticated.example.invalid/movie.mp4"
                && media.headers["Cookie"] == "session=fixture"
        })
    }

    func testAndroidCloudOriginalProxyBypassesBrokenRangePreflight() async throws {
        let probe = DefaultMediaProbe(httpClient: FailingProbeHTTPClient())
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:16677/proxy/play/%E5%A4%B8%E7%88%B6%E7%9B%98/movie/1.mp4")
        )

        let isValid = try await probe.validate(url: url, headers: [:])

        XCTAssertTrue(isValid)
    }

    func testAndroidKaiserProxyBypassesBrokenRangePreflight() async throws {
        let probe = DefaultMediaProbe(httpClient: FailingProbeHTTPClient())
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:18096/kaiser?url=https%3A%2F%2Fexample.invalid%2Fmovie.mp4")
        )

        let isValid = try await probe.validate(url: url, headers: [:])

        XCTAssertTrue(isValid)
    }

    func testAndroidBridgeMediaProxyBypassesBrokenRangePreflight() async throws {
        let probe = DefaultMediaProbe(httpClient: FailingProbeHTTPClient())
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:19978/v1/media?url=https%3A%2F%2Fexample.invalid%2Fmovie.mp4")
        )

        let isValid = try await probe.validate(url: url, headers: [:])

        XCTAssertTrue(isValid)
    }

    func testNodeRuntimeMediaProxyBypassesUnsupportedHeadPreflight() async throws {
        let probe = DefaultMediaProbe(httpClient: FailingProbeHTTPClient())
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:18989/spider/wexyueyue/proxy/media?id=fixture")
        )

        let isValid = try await probe.validate(url: url, headers: [:])

        XCTAssertTrue(isValid)
        XCTAssertTrue(DefaultMediaProbe.isNodeRuntimeMediaProxy(url))
    }

    func testAndroidBridgeMediaSessionIsNotMisclassifiedAsNodeProxy() throws {
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:19978/proxy/media/session-123")
        )

        XCTAssertTrue(DefaultMediaProbe.isAndroidBridgeMediaSession(url))
        XCTAssertFalse(DefaultMediaProbe.isNodeRuntimeMediaProxy(url))
    }

    func testAndroidBridgeMediaSessionRequiresReadableMediaBytes() async throws {
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:19978/proxy/media/session-readable")
        )
        let client = ScriptedProbeHTTPClient(responses: [
            HTTPResponse(
                url: url,
                statusCode: 200,
                headers: ["Content-Type": "video/mp4"],
                body: Data()
            ),
            HTTPResponse(
                url: url,
                statusCode: 206,
                headers: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes 0-3/4096"
                ],
                body: Data([0, 0, 0, 24])
            )
        ])

        let isValid = try await DefaultMediaProbe(httpClient: client)
            .validate(url: url, headers: [:])

        XCTAssertTrue(isValid)
        let requests = await client.requests()
        XCTAssertEqual(requests.map(\.method), [.head, .get])
        XCTAssertEqual(requests.last?.headers["Range"], "bytes=0-65535")
    }

    func testAndroidBridgeMediaSessionRejectsJSONErrorBody() async throws {
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:19978/proxy/media/session-error")
        )
        let client = ScriptedProbeHTTPClient(responses: [
            HTTPResponse(
                url: url,
                statusCode: 200,
                headers: ["Content-Type": "video/mp4"],
                body: Data()
            ),
            HTTPResponse(
                url: url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"login required"}"#.utf8)
            )
        ])

        let isValid = try await DefaultMediaProbe(httpClient: client)
            .validate(url: url, headers: [:])

        XCTAssertFalse(isValid)
    }

    func testAndroidCloudOriginalProxyBypassIsRestrictedToExpectedEndpoint() throws {
        let matchingURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:16677/proxy/play/%E5%98%9F%E5%98%9F/movie/1.mp4")
        )
        XCTAssertTrue(DefaultMediaProbe.isAndroidCloudOriginalProxy(matchingURL))

        let nonMatchingURLs = try [
            "http://127.0.0.1:19978/proxy/play/cloud/movie/1.mp4",
            "http://127.0.0.1:19978/v1/media-other?url=https://example.invalid/1.mp4",
            "http://127.0.0.1:16677/not-proxy/play/cloud/movie/1.mp4",
            "http://example.invalid:16677/proxy/play/cloud/movie/1.mp4",
            "https://127.0.0.1:16677/proxy/play/cloud/movie/1.mp4"
        ].map { try XCTUnwrap(URL(string: $0)) }

        XCTAssertTrue(nonMatchingURLs.allSatisfy {
            !DefaultMediaProbe.isAndroidCloudOriginalProxy($0)
        })
    }

    func testDirectCandidateSucceedsWithoutParser() async {
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(results: [:]),
            mediaProbe: FixtureMediaProbe(validURLs: ["https://media.example.invalid/direct.m3u8"])
        )
        let request = PlaybackResolutionRequest(
            candidates: [
                candidate(
                    url: "https://media.example.invalid/direct.m3u8",
                    needsParsing: false
                )
            ],
            parsers: []
        )

        let events = await collect(resolver.resolve(request))
        XCTAssertTrue(events.contains { event in
            guard case .resolved(let media) = event else { return false }
            return media.url.absoluteString == "https://media.example.invalid/direct.m3u8"
                && media.parserName == nil
        })
    }

    func testParserRequiredCandidateExplainsMissingParser() async {
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(results: [:]),
            mediaProbe: FixtureMediaProbe(validURLs: [])
        )
        let request = PlaybackResolutionRequest(
            candidates: [candidate(
                source: "QY",
                url: "https://player.example.invalid/watch/42",
                needsParsing: true
            )],
            parsers: []
        )

        let events = await collect(resolver.resolve(request))

        XCTAssertTrue(events.contains { event in
            guard case .failed(let message) = event else { return false }
            return message.contains("线路返回待解析地址")
                && message.contains("没有可用解析器")
        })
    }

    func testAndroidBridgeFailureDiagnosesUpstreamBeforeReportingMPVError() async {
        let url = "http://127.0.0.1:19978/proxy/media/session-123"
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(results: [:]),
            mediaProbe: FixtureMediaProbe(validURLs: [])
        )
        let result = SitePlaybackResult(
            url: url,
            needsParsing: false,
            flag: "fixture",
            validationPolicy: .playerAuthoritative
        )
        let request = PlaybackResolutionRequest(
            candidates: [PlaybackCandidate(
                siteKey: "fixture",
                siteName: "Fixture",
                sourceName: "VIP",
                episodeName: "Episode 2",
                result: result
            )],
            parsers: []
        )

        let events = await collect(resolver.resolve(request) { _, _ in
            throw AppError.playback("loading failed")
        })

        XCTAssertTrue(events.contains { event in
            guard case .failed(let message) = event else { return false }
            return message.contains("Android 内部播放代理")
                && message.contains("没有返回媒体数据")
        })
    }

    func testFirstParserFailsAndSecondSucceeds() async {
        let first = ParseConfiguration(
            name: "First",
            type: 1,
            url: "https://parser.example.invalid/first?url=",
            ext: .object(["flag": .array([.string("fixture")])])
        )
        let second = ParseConfiguration(
            name: "Second",
            type: 1,
            url: "https://parser.example.invalid/second?url="
        )
        let successURL = URL(string: "https://media.example.invalid/success.mp4")!
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(
                results: [
                    "First": .failure(.parsing("fixture failure")),
                    "Second": .success(ParsedMedia(url: successURL))
                ]
            ),
            mediaProbe: FixtureMediaProbe(validURLs: [successURL.absoluteString])
        )
        let request = PlaybackResolutionRequest(
            candidates: [candidate(url: "https://provider.example.invalid/watch/1", needsParsing: true)],
            parsers: [second, first]
        )

        let events = await collect(resolver.resolve(request))
        let attempts = events.compactMap { event -> PlaybackAttempt? in
            guard case .attempting(let attempt) = event else { return nil }
            return attempt
        }
        XCTAssertEqual(attempts.map(\.parserName), ["First", "Second"])
        XCTAssertTrue(events.contains { event in
            guard case .resolved(let media) = event else { return false }
            return media.parserName == "Second"
        })
    }

    func testMovesToNextSourceAfterFailure() async {
        let parser = ParseConfiguration(
            name: "Parser",
            type: 1,
            url: "https://parser.example.invalid/?url="
        )
        let finalURL = URL(string: "https://media.example.invalid/final.mp4")!
        let executor = SourceAwareFixtureParseExecutor(finalURL: finalURL)
        let resolver = PlaybackResolver(
            parseExecutor: executor,
            mediaProbe: FixtureMediaProbe(validURLs: [finalURL.absoluteString])
        )
        let request = PlaybackResolutionRequest(
            candidates: [
                candidate(
                    source: "Line 1",
                    url: "https://provider.example.invalid/bad",
                    needsParsing: true
                ),
                candidate(
                    source: "Line 2",
                    url: "https://provider.example.invalid/good",
                    needsParsing: true
                )
            ],
            parsers: [parser]
        )
        let events = await collect(resolver.resolve(request))

        XCTAssertTrue(events.contains { event in
            guard case .resolved(let media) = event else { return false }
            return media.sourceName == "Line 2"
        })
    }

    func testMaximumAttemptLimitIsEnforced() async {
        let parsers = (1...5).map {
            ParseConfiguration(
                name: "Parser \($0)",
                type: 1,
                url: "https://parser.example.invalid/\($0)?url="
            )
        }
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(
                results: Dictionary(
                    uniqueKeysWithValues: parsers.map {
                        ($0.name, .failure(AppError.parsing("failed")))
                    }
                )
            ),
            mediaProbe: FixtureMediaProbe(validURLs: [])
        )
        let events = await collect(
            resolver.resolve(
                PlaybackResolutionRequest(
                    candidates: [candidate(url: "https://provider.example.invalid/watch", needsParsing: true)],
                    parsers: parsers,
                    maximumAttempts: 2
                )
            )
        )
        XCTAssertEqual(events.filter {
            if case .attempting = $0 { return true }
            return false
        }.count, 2)
        XCTAssertTrue(events.contains(.state(.exhausted)))
    }

    func testPlayerLoadFailureRetriesNextSource() async {
        let firstURL = "https://media.example.invalid/first.mp4"
        let secondURL = "https://media.example.invalid/second.mp4"
        let resolver = PlaybackResolver(
            parseExecutor: FixtureParseExecutor(results: [:]),
            mediaProbe: FixtureMediaProbe(validURLs: [firstURL, secondURL])
        )
        let request = PlaybackResolutionRequest(
            candidates: [
                candidate(source: "Line 1", url: firstURL, needsParsing: false),
                candidate(source: "Line 2", url: secondURL, needsParsing: false)
            ],
            parsers: []
        )

        let events = await collect(
            resolver.resolve(
                request,
                mediaLoader: { media, _ in
                    if media.sourceName == "Line 1" {
                        throw AppError.playback("fixture player failure")
                    }
                }
            )
        )

        XCTAssertTrue(events.contains { event in
            guard case .attemptFailed(let attempt, _) = event else {
                return false
            }
            return attempt.sourceName == "Line 1"
        })
        XCTAssertTrue(events.contains(.state(.playing)))
        XCTAssertTrue(events.contains { event in
            guard case .resolved(let media) = event else { return false }
            return media.sourceName == "Line 2"
        })
    }

    private func candidate(
        source: String = "Line",
        url: String,
        needsParsing: Bool
    ) -> PlaybackCandidate {
        PlaybackCandidate(
            siteKey: "fixture",
            siteName: "Fixture",
            sourceName: source,
            episodeName: "Episode",
            result: SitePlaybackResult(
                url: url,
                needsParsing: needsParsing,
                flag: "fixture"
            )
        )
    }

    private func collect(
        _ stream: AsyncStream<PlaybackResolutionEvent>
    ) async -> [PlaybackResolutionEvent] {
        var values: [PlaybackResolutionEvent] = []
        for await event in stream {
            values.append(event)
        }
        return values
    }
}

private struct FailingProbeHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPClientError.transport("the preflight client must not be called")
    }
}

private actor ScriptedProbeHTTPClient: HTTPClient {
    private var remaining: [HTTPResponse]
    private var recorded: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        remaining = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !remaining.isEmpty else {
            throw HTTPClientError.transport("missing scripted response")
        }
        return remaining.removeFirst()
    }

    func requests() -> [HTTPRequest] {
        recorded
    }
}

private struct FixtureParseExecutor: ParseExecutor {
    let results: [String: Result<ParsedMedia, AppError>]

    func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        guard let result = results[parser.name] else {
            throw AppError.parsing("missing fixture")
        }
        return try result.get()
    }
}

private struct SourceAwareFixtureParseExecutor: ParseExecutor {
    let finalURL: URL

    func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        if inputURL.hasSuffix("/good") {
            return ParsedMedia(url: finalURL)
        }
        throw AppError.parsing("bad source")
    }
}

private struct FixtureMediaProbe: MediaProbe {
    let validURLs: Set<String>

    init(validURLs: Set<String>) {
        self.validURLs = validURLs
    }

    func validate(url: URL, headers: HTTPHeaders) async throws -> Bool {
        validURLs.contains(url.absoluteString)
    }
}
