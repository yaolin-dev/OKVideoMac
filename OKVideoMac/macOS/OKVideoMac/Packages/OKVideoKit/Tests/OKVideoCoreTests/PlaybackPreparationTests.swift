import XCTest
@testable import OKVideoCore

final class PlaybackPreparationTests: XCTestCase {
    private let site = SiteConfiguration(key: "renamed-fixture", name: "Renamed provider", type: 3, api: "fixture")
    private let media = "https://media.example.invalid/video.mp4"
    private let mp4 = Data([0, 0, 0, 24] + Array("ftypisom".utf8))

    func testProviderFailureFieldsWinOverStaleURLAndPreserveExplanation() throws {
        for field in ["message", "msg", "error"] {
            for nested in [false, true] {
                let reason = "播放解析失败：HTTP 403：上游拒绝请求，请稍后重试"
                let value: JSONValue = nested ? .object(["message": .string(reason)]) : .string(reason)
                XCTAssertThrowsError(try SpiderResponseMapper.player(.object([
                    "url": .string(media), "parse": .integer(1), field: value
                ]), site: site)) { error in
                    XCTAssertEqual(error as? ProviderPlaybackError, ProviderPlaybackError(reason))
                }
            }
        }
    }

    func testSuccessAndInformationalMessagesDoNotDisableValidMedia() throws {
        for field in ["message", "msg"] {
            for message in ["OK", "success", "解析成功"] {
                let result = try SpiderResponseMapper.player(.object([
                    "url": .string(media), "parse": .integer(0), field: .string(message)
                ]), site: site)
                XCTAssertEqual(result.url, media)
            }
        }
        for message in ["采用备用 CDN", "已登录，返回原画", "No error", "登录成功"] {
            let result = try SpiderResponseMapper.player(.object([
                "url": .string(media), "parse": .integer(0), "message": .string(message)
            ]), site: site)
            XCTAssertEqual(result.url, media)
        }
    }

    func testExplicitFailureWithoutMessageCannotLoadFallbackURL() throws {
        XCTAssertThrowsError(try SpiderResponseMapper.player(.object([
            "url": .string(media), "success": .bool(false)
        ]), site: site)) { XCTAssertNotNil($0 as? ProviderPlaybackError) }
    }

    // Sanitized protocol shapes of all eleven choices in the reported item.
    // No provider identity, account credential or actual playback URL is needed.
    func testElevenReportedResponseShapesCannotReachDecoderAsRawPages() async throws {
        for index in 0..<11 {
            let url = index < 4 ? "https://gateway.example.invalid/\(index).mp4"
                : "https://page.example.invalid/watch/\(index)"
            var object: [String: JSONValue] = ["parse": .integer(1), "jx": .integer(1), "url": .string(url)]
            if index < 4 { object["message"] = .string("播放解析失败：HTTP 403：您已被封禁") }
            do {
                let result = try SpiderResponseMapper.player(.object(object), site: site)
                XCTAssertGreaterThanOrEqual(index, 4)
                let events = await resolve(result)
                XCTAssertTrue(events.contains(.preparationIssue(.missingParser)))
                XCTAssertFalse(events.contains { if case .resolved = $0 { return true }; return false })
            } catch {
                XCTAssertLessThan(index, 4)
                XCTAssertNotNil(error as? ProviderPlaybackError)
            }
        }
    }

    func testParsingRequiredMP4UsesConfiguredParserBeforeDirectFallback() async throws {
        let result = SitePlaybackResult(url: media, needsParsing: true, flag: "fixture", validationPolicy: .playerAuthoritative)
        let parser = ParseConfiguration(name: "Generic", type: 1, url: "https://parser.example.invalid/?url=")
        let events = await resolve(result, parsers: [parser], responseBody: mp4)
        let resolved = try XCTUnwrap(events.compactMap { event -> ResolvedMedia? in
            if case .resolved(let media) = event { return media }; return nil
        }.first)
        XCTAssertEqual(resolved.parserName, "Generic")
        XCTAssertEqual(resolved.url.absoluteString, "https://parsed.example.invalid/stream.mp4")
    }

    func testLegacyParsingFlagCanUseVerifiedRealMP4WithoutParser() async {
        let events = await resolve(SitePlaybackResult(url: media, needsParsing: true, flag: "fixture",
            validationPolicy: .playerAuthoritative), responseBody: mp4)
        XCTAssertTrue(events.contains { if case .resolved = $0 { return true }; return false })
    }

    func testMP4SuffixWrongContentTypeAndPartialStatusCannotProveMedia() async throws {
        for body in [Data("<html>rejected</html>".utf8), Data("{\"error\":\"denied\"}".utf8), Data("unknown body".utf8)] {
            let result = SitePlaybackResult(url: media, needsParsing: true, flag: "fixture", validationPolicy: .playerAuthoritative)
            let events = await resolve(result, responseBody: body, status: 206)
            XCTAssertTrue(events.contains(.preparationIssue(.missingParser)))
            XCTAssertFalse(events.contains { if case .resolved = $0 { return true }; return false })
        }
    }

    func testHTTPFailurePreservesStatusAndAllowsBoundedCapabilityRefresh() async {
        for status in [401, 403, 404, 410, 503] {
            let result = SitePlaybackResult(url: media, needsParsing: true, flag: "fixture")
            let events = await resolve(result, status: status)
            XCTAssertTrue(events.contains(.preparationIssue(.httpStatus(status))))
            XCTAssertTrue(PlaybackPreparationIssue.httpStatus(status).allowsAutomaticRefresh)
        }
        XCTAssertFalse(PlaybackPreparationIssue.missingParser.allowsAutomaticRefresh)
        XCTAssertFalse(PlaybackPreparationIssue.nonMedia.allowsAutomaticRefresh)
    }

    func testExplicitParserURLWorksWithoutGlobalParserList() async throws {
        for playURL in ["https://parser.example.invalid/?url=", "json:https://parser.example.invalid/?url="] {
            var result = SitePlaybackResult(url: "https://page.example.invalid/watch", needsParsing: true, flag: "fixture")
            result.playURL = playURL
            let events = await resolve(result, responseBody: mp4)
            XCTAssertTrue(events.contains { if case .resolved(let media) = $0 { return media.parserName != nil }; return false })
        }
    }

    private func resolve(_ result: SitePlaybackResult, parsers: [ParseConfiguration] = [],
                         responseBody: Data = Data(), status: Int = 200) async -> [PlaybackResolutionEvent] {
        let probe = DefaultMediaProbe(httpClient: PreparationHTTPFixture(body: responseBody, status: status))
        let resolver = PlaybackResolver(parseExecutor: PreparationParseFixture(), mediaProbe: probe)
        let request = PlaybackResolutionRequest(candidates: [PlaybackCandidate(siteKey: site.key,
            siteName: site.name, sourceName: "任意线路", episodeName: "任意分集", result: result)], parsers: parsers)
        var events: [PlaybackResolutionEvent] = []
        for await event in resolver.resolve(request, mediaLoader: { media, _ in
            XCTAssertFalse(media.url.path.contains("watch"), "Unresolved pages must never reach the decoder")
        }) { events.append(event) }
        return events
    }
}

private struct PreparationHTTPFixture: HTTPClient {
    let body: Data
    let status: Int
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(url: request.url, statusCode: status, headers: ["Content-Type": "video/mp4"], body: body)
    }
}
private struct PreparationParseFixture: ParseExecutor {
    func resolve(parser: ParseConfiguration, inputURL: String, headers: HTTPHeaders) async throws -> ParsedMedia {
        ParsedMedia(url: URL(string: "https://parsed.example.invalid/stream.mp4")!)
    }
}
