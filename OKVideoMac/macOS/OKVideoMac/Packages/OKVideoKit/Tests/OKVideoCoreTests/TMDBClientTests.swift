import XCTest
@testable import OKVideoCore

final class TMDBClientTests: XCTestCase {

    func testSearchEnvelopeKeepsGlobalCountAndObservedWrapperDoesNotLoseIt() async throws {
        for total in [1, 21] {
            let body = "{\"page\":1,\"total_pages\":\(total == 1 ? 1 : 2),\"total_results\":\(total),\"results\":[{\"id\":1,\"title\":\"最后孤屋\"}]}"
            let service = TMDBObservedService(base: TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: TMDBHTTPProbe(override: (200, body))), availability: TMDBAvailability())
            let page = try await service.searchPage(query: "最后孤屋", type: .movie, year: nil)
            XCTAssertEqual(page.totalResults, total)
            XCTAssertEqual(page.isUnique, total == 1)
        }
        XCTAssertFalse(TMDBSearchPage(results: []).isUnique)
    }

    func testDirectRequestsUseOnlyOfficialPathsAndCredential() async throws {
        let transport = TMDBHTTPProbe()
        let client = TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport)
        _ = try await client.search(query: "阿索卡 & Ahsoka", type: .tv, year: nil)
        _ = try await client.detail(.init(type: .movie, id: 11))
        _ = try await client.detail(.init(type: .tv, id: 114461))
        _ = try await client.season(tvID: 114461, number: 0)
        let configuration = try await client.imageConfiguration()
        XCTAssertEqual(configuration.size(for: .still), "w300")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.path), ["/3/search/tv", "/3/movie/11", "/3/tv/114461", "/3/tv/114461/season/0", "/3/configuration"])
        for request in requests {
            XCTAssertEqual(request.url.host, "api.themoviedb.org")
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(request.headers.dictionary, ["Accept": "application/json", "Authorization": "Bearer test-only-token"])
            XCTAssertEqual(request.maximumRedirects, 0)
            XCTAssertEqual(request.retryPolicy, .none)
            XCTAssertEqual(request.earlyResponseLimitBytes, 5 * 1024 * 1024)
            XCTAssertEqual(request.timeout, 10)
        }
        func query(_ index: Int) -> [String: String] {
            Dictionary(uniqueKeysWithValues: URLComponents(url: requests[index].url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        }
        XCTAssertEqual(query(0)["query"], "阿索卡 & Ahsoka")
        XCTAssertNil(query(0)["first_air_date_year"])
        XCTAssertEqual(query(1)["append_to_response"], "credits,images,alternative_titles,translations")
        XCTAssertEqual(query(2)["append_to_response"], "aggregate_credits,images,alternative_titles,translations")
        XCTAssertEqual(query(3), ["language": "zh-CN"])
        XCTAssertNil(requests[4].url.query)
    }

    func testPersonAliasesRequireTheRequestedUpstreamID() async throws {
        let transport = TMDBHTTPProbe(override: (200, #"{"id":15740,"name":"Tim McMullan","also_known_as":["蒂姆·迈克穆兰"]}"#))
        let client = TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport)
        let value = try await client.personIdentity(id: 15740)
        XCTAssertEqual(value.alsoKnownAs, ["蒂姆·迈克穆兰"])
        let request = await transport.requests.first
        XCTAssertEqual(request?.url.absoluteString, "https://api.themoviedb.org/3/person/15740?language=zh-CN")
        do { _ = try await client.personIdentity(id: 15741); XCTFail("Wrong person response accepted") } catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
        do { _ = try await client.personIdentity(id: 0); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .invalidInput) }
    }

    func testPersonCreditsUsesBoundedReadOnlyAPIAndRejectsWrongIdentity() async throws {
        let body = #"{"id":31,"cast":[{"id":1,"media_type":"movie","title":"电影","release_date":"2020-01-01"},{"id":1,"media_type":"tv","name":"电视剧","first_air_date":"2024-01-01"},{"id":2,"media_type":"movie","title":"不展示","adult":true}],"crew":[{"id":1,"media_type":"movie","title":"电影"}]}"#
        let transport = TMDBHTTPProbe(override: (200, body)), client = TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport)
        let credits = try await client.personCredits(id: 31)
        XCTAssertEqual(credits.works.map(\.reference.type), [.tv, .movie])
        XCTAssertEqual(credits.works.count, 2)
        let first = await transport.requests.first
        let request = try XCTUnwrap(first)
        XCTAssertEqual(request.url.absoluteString, "https://api.themoviedb.org/3/person/31/combined_credits?language=zh-CN")
        XCTAssertEqual(request.headers.dictionary, ["Accept": "application/json", "Authorization": "Bearer test-only-token"])
        do { _ = try await client.personCredits(id: 0); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .invalidInput) }
        do { _ = try await client.personCredits(id: 32); XCTFail() } catch {}
    }

    func testUnavailableMalformedAndWrongIdentityNeverBecomeUsableDetails() async throws {
        for (status, body) in [(403, "{}"), (404, "{}"), (429, "{}"), (502, "{}"), (200, "not json"),
                               (200, "{\"id\":12,\"title\":\"wrong\"}"), (200, "{\"id\":11,\"name\":\"wrong type\"}")] {
            let transport = TMDBHTTPProbe(override: (status, body))
            do { _ = try await TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport).detail(.init(type: .movie, id: 11)); XCTFail("Accepted \(status): \(body)") }
            catch { /* Caller keeps provider detail on every failure. */ }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "No unbounded retry or upstream bypass")
        }
    }

    func testInvalidInputAndImageHostInjectionAreRejected() async throws {
        let transport = TMDBHTTPProbe(), client = TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: TMDBHTTPProbe())
        do { _ = try await client.detail(.init(type: .movie, id: 0)); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .invalidInput) }
        do { _ = try await client.season(tvID: 1, number: -1); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .invalidInput) }
        do { _ = try await TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport).search(query: "", type: nil); XCTFail() } catch {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        for path in ["https://other.example/a.jpg", "/../a.jpg", "/a.jpg?token=x", "//other/a.jpg"] {
            XCTAssertNil(TMDBClient.imageURL(path: path, size: "w500"))
        }
        XCTAssertEqual(TMDBClient.imageURL(path: "/abc.png", size: "w500")?.absoluteString, "https://image.tmdb.org/t/p/w500/abc.png")
    }

    func testTranslationsAndAggregateCreditsDecodeRealTMDBFieldNames() async throws {
        let body = #"{"id":114461,"name":"阿索卡","translations":{"translations":[{"iso_639_1":"zh","data":{"name":"阿索卡","overview":"中文简介"}}]},"aggregate_credits":{"cast":[{"id":1,"name":"演员","roles":[{"character":"角色"}]}]},"images":{"logos":[{"file_path":"/abc.png","iso_639_1":"zh"}]}}"#
        let work = try await TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: TMDBHTTPProbe(override: (200, body))).detail(.init(type: .tv, id: 114461))
        XCTAssertEqual(work.chineseOverview, "中文简介")
        XCTAssertEqual(work.cast.first?.role, "角色")
        XCTAssertEqual(work.images?.logos?.first?.iso6391, "zh")
    }

    func testCancelledPageDoesNotAcceptLateTransportResponse() async throws {
        let probe = TMDBHTTPProbe(delay: 100_000_000)
        let task = Task { try await TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: probe).detail(.init(type: .movie, id: 11)) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled enrichment became visible") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingCredentialNeverSendsAnyRequest() async throws {
        let transport = TMDBHTTPProbe(), client = TMDBClient(httpClient: TMDBHTTPProbe())
        let empty = TMDBClient(httpClient: transport)
        do { _ = try await empty.imageConfiguration(); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .credentialMissing) }
        do { _ = try await client.search(query: "Title", type: nil); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .credentialMissing) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testV3KeyIsOnlyInOfficialAPIQueryAndNeverImageURL() async throws {
        let transport = TMDBHTTPProbe()
        let client = TMDBClient(credential: try TMDBCredential(kind: .apiKey, value: "test-v3-key"), httpClient: transport)
        _ = try await client.imageConfiguration()
        _ = try await client.search(query: "A & B", type: .movie, year: 2026)
        for request in await transport.requests {
            XCTAssertEqual(request.url.host, "api.themoviedb.org")
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.filter { $0.name == "api_key" }.map(\.value), ["test-v3-key"])
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertEqual(request.maximumRedirects, 0)
        }
        XCTAssertNil(TMDBClient.imageURL(path: "/example.jpg", size: "w500")?.query)
    }

    func testCredentialCodecRejectsInjectionAndRedactsDescription() throws {
        for value in ["", "Bearer secret", "secret\r\nHeader: x", "https://example/key", "秘密", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try TMDBCredential(kind: .readAccessToken, value: value))
        }
        let credential = try TMDBCredential(kind: .readAccessToken, value: "  private-token\n")
        XCTAssertEqual(try TMDBCredential(keychainData: credential.keychainData()), credential)
        XCTAssertFalse(String(describing: credential).contains("private-token"))
        XCTAssertFalse(String(reflecting: credential).contains("private-token"))
        var dumped = ""; dump(credential, to: &dumped)
        XCTAssertFalse(dumped.contains("private-token"))
        XCTAssertThrowsError(try TMDBCredential(keychainData: Data("broken".utf8)))
    }

    func testReplacingAndRemovingCredentialRejectsLateResponses() async throws {
        let transport = TMDBHTTPProbe(delay: 100_000_000)
        let client = TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "old-token"), httpClient: transport)
        let old = Task { try await client.detail(.init(type: .movie, id: 11)) }
        while await transport.requests.isEmpty { await Task.yield() }
        await client.updateCredential(try TMDBCredential(kind: .readAccessToken, value: "new-token"))
        do { _ = try await old.value; XCTFail("Old session published a late result") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.imageConfiguration()
        await client.updateCredential(nil)
        do { _ = try await client.imageConfiguration(); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .credentialMissing) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer old-token", "Bearer new-token"])
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "api.themoviedb.org" })
    }

    func testCredentialBearingTransportErrorsAreSanitized() async throws {
        let client = TMDBClient(credential: try TMDBCredential(kind: .apiKey, value: "private-key"), httpClient: LeakyTMDBTransport())
        do { _ = try await client.imageConfiguration(); XCTFail() }
        catch {
            XCTAssertFalse(String(reflecting: error).contains("private-key"))
            XCTAssertEqual(TMDBLinkOutcome.error(error), .failure(.network))
        }
    }

    /// Explicit opt-in: actual Foundation transport, no shell-proxy assumptions.
    func testLiveDirectThroughSystemNetworkConfiguration() async throws {
        guard ProcessInfo.processInfo.environment["OKVIDEO_TMDB_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in live network check") }
        guard let path = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_CREDENTIAL_FILE"] else { throw XCTSkip("A private credential file is required for direct acceptance") }
        let client = TMDBClient(credential: try TMDBCredential(keychainData: Data(contentsOf: URL(fileURLWithPath: path))))
        let movie = try await client.detail(.init(type: .movie, id: 11))
        XCTAssertEqual(movie.year, 1977)
        XCTAssertFalse(movie.displayTitle.isEmpty)
        let tv = try await client.detail(.init(type: .tv, id: 114461))
        XCTAssertEqual(tv.id, 114461)
        let season = try await client.season(tvID: 114461, number: 1)
        XCTAssertEqual(season.episodes.count, 8)
        let matches = try await client.search(query: "阿索卡", type: .tv)
        XCTAssertTrue(matches.contains { $0.id == 114461 })
        _ = try await client.imageConfiguration()
    }
}

private actor TMDBHTTPProbe: HTTPClient {
    var requests: [HTTPRequest] = []
    let override: (Int, String)?
    let delay: UInt64
    init(override: (Int, String)? = nil, delay: UInt64 = 0) { self.override = override; self.delay = delay }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) } // Deliberately ignores cancellation.
        let body: String
        switch request.url.path {
        case "/3/configuration": body = #"{"images":{"still_sizes":["w92","w185","w300","original"]}}"#
        case "/3/movie/11": body = #"{"id":11,"title":"星球大战","release_date":"1977-05-25"}"#
        case "/3/tv/114461": body = #"{"id":114461,"name":"阿索卡"}"#
        case "/3/tv/114461/season/0": body = #"{"season_number":0,"episodes":[]}"#
        default: body = #"{"results":[]}"#
        }
        return HTTPResponse(url: request.url, statusCode: override?.0 ?? 200, headers: [:], body: Data((override?.1 ?? body).utf8))
    }
}

private struct LeakyTMDBTransport: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw HTTPClientError.transport(request.url.absoluteString) }
}
