import XCTest
@testable import OKVideoCore

final class PlaybackResolverTests: XCTestCase {
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
