import XCTest
@testable import OKVideoCore

final class TMDBCapturedTests: XCTestCase {
    func testRealLanxiangNormalAndColorAutomaticallyMatchInSeparateEmptyStores() async throws {
        guard let prefix = ProcessInfo.processInfo.environment["OKVIDEOMAC_TMDB_CAPTURE_PREFIX"] else { throw XCTSkip("Opt-in captured provider acceptance") }
        let site = SiteConfiguration(key: "nodejs_huban", name: "虎斑|4K", type: 3, api: "/spider/huban/3")
        for variant in ["provider", "color-provider"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: prefix + variant + ".json"))
            let detail = try SpiderResponseMapper.detail(JSONDecoder().decode(JSONValue.self, from: data), site: site, baseURL: nil)
            let transport = CapturedTMDBTransport(prefix: prefix)
            let repository = TMDBRepository(client: TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport))
            let result = try await repository.resolve(key: variant, input: .init(detail: detail))
            guard case .matched(let candidate, let binding) = result else { return XCTFail("Automatic matching failed: \(detail.summary.title)") }
            XCTAssertEqual(candidate.reference, .init(type: .tv, id: 282326))
            XCTAssertFalse(binding.manual)
            let seasonData = try Data(contentsOf: URL(fileURLWithPath: prefix + "tmdb-season.json"))
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let season = try decoder.decode(TMDBSeason.self, from: seasonData)
            let mappedCounts = detail.playSources.map { TMDBEpisodeMapper.episodes($0.episodes, category: detail.summary.categoryName, season: season).count }
            XCTAssertEqual(mappedCounts, variant == "provider" ? [47, 47, 47] : [94, 94, 47, 47])
            for source in detail.playSources {
                XCTAssertEqual(TMDBEpisodeMapper.season(work: candidate.work, input: .init(detail: detail), source: source), 1)
            }
            print("Captured mapping counts: \(mappedCounts)")
            let requests = await transport.events
            XCTAssertEqual(requests, ["/3/search/multi?兰香如故", "/3/tv/282326?"])
            print("Captured acceptance: \(detail.summary.title), automatic=\(!binding.manual), TMDB=\(candidate.reference.id), source counts=\(detail.playSources.map { $0.episodes.count })")
        }
    }
}
private actor CapturedTMDBTransport: HTTPClient {
    let prefix: String
    var events: [String] = []
    init(prefix: String) { self.prefix = prefix }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        events.append(request.url.path + "?" + query)
        let file: String
        switch request.url.path {
        case "/3/search/multi", "/3/search/tv": file = query == "兰香如故" ? "tmdb-search" : "color-tmdb-search"
        case "/3/tv/282326": file = "tmdb-detail"
        default: throw TMDBError.invalidInput
        }
        return HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: try Data(contentsOf: URL(fileURLWithPath: prefix + file + ".json")))
    }
}

extension TMDBCapturedTests {
    func testDirectRealProviderReplayWithoutSavedBindings() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECT_SOURCE_FIXTURES"],
              let responsePath = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECT_API_FIXTURES"] else {
            throw XCTSkip("Private provider/API captures are required for replay acceptance")
        }
        let sources = URL(fileURLWithPath: sourcePath), responses = URL(fileURLWithPath: responsePath)
        for kind in TMDBCredential.Kind.allCases {
            for (name, expected, automatic) in [("suspect-wogg", 319851, true), ("kingfisher-wogg", 283319, false), ("last-wogg", 1284041, true), ("wogg-tv", 289078, true)] {
                let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: sources.appendingPathComponent(name + "-detail.json")))
                let detail = try SpiderResponseMapper.detail(raw, site: .init(key: "wogg", name: "Wogg", type: 3, api: "csp_WoGGGuard"), baseURL: nil)
                let input = TMDBMatchInput(detail: detail)
                var withoutResources = detail; withoutResources.playSources = []
                XCTAssertTrue(input == TMDBMatchInput(detail: withoutResources), "Resource filenames influenced identity")
                let transport = try TMDBDirectReplayTransport(directory: responses, expected: expected, names: Set(input.searchNames))
                let client = TMDBClient(credential: try TMDBCredential(kind: kind, value: "replay-only-credential"), httpClient: transport)
                let repo = TMDBRepository(client: client)
                var result = try await repo.prepare(key: name, input: input)
                if !automatic {
                    if case .matched = result { XCTFail("Ambiguous translated cast was accepted automatically") }
                    result = try await repo.choose(.init(type: .tv, id: expected), key: name, input: input)
                }
                guard case .matched(let candidate, let binding) = result else { XCTFail("Expected verified work: \(name)"); continue }
                XCTAssertEqual(candidate.reference.id, expected)
                XCTAssertEqual(binding.manual, !automatic)
                if candidate.reference.type == .tv {
                    var totalStills = 0
                    for (index, line) in detail.playSources.enumerated() {
                        var lineStills = 0
                        for number in TMDBEpisodeMapper.seasonNumbers(work: candidate.work, input: input, source: line) {
                            let season = try await repo.season(tvID: expected, number: number, ongoing: true)
                            let map = TMDBEpisodeMapper.episodes(line.episodes, category: detail.summary.categoryName, season: season)
                            lineStills += map.values.filter { $0.stillPath != nil }.count
                        }
                        if index == 0 {
                            if name == "suspect-wogg" { XCTAssertEqual(lineStills, 6) }
                            if name == "wogg-tv" { XCTAssertEqual(lineStills, 22) }
                            if name == "kingfisher-wogg" { XCTAssertEqual(lineStills, 0, "Conflicting S03 resources must not borrow S01 artwork") }
                        }
                        totalStills += lineStills
                    }
                    XCTAssertGreaterThan(totalStills, 0)
                }
                let requests = await transport.requests
                XCTAssertTrue(requests.allSatisfy { $0.url.host == "api.themoviedb.org" && $0.method == .get && $0.maximumRedirects == 0 })
                XCTAssertTrue(requests.allSatisfy { request in
                    if kind == .readAccessToken { return request.headers["Authorization"] == "Bearer replay-only-credential" }
                    return request.headers["Authorization"] == nil && URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "api_key" && $0.value == "replay-only-credential" } == true
                })
            }
        }
    }
}
private actor TMDBDirectReplayTransport: HTTPClient {
    let files: [URL]
    let expected: Int
    let names: Set<String>
    var requests: [HTTPRequest] = []
    init(directory: URL, expected: Int, names: Set<String>) throws {
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        self.expected = expected; self.names = names
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let data: Data
        if request.url.path.hasPrefix("/3/search/") {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            guard names.contains(query), let file = files.first(where: { file in
                guard file.lastPathComponent.hasPrefix("_3_search_"), let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else { return false }
                return results.first?["id"] as? Int == expected
            }) else { throw TMDBError.invalidInput }
            data = try Data(contentsOf: file)
        } else {
            let prefix = request.url.path.replacingOccurrences(of: "/", with: "_") + "-"
            guard let file = files.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else { throw TMDBError.invalidInput }
            data = try Data(contentsOf: file)
        }
        return HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: data)
    }
}


extension TMDBCapturedTests {
    func testRemainingRealDirectorAliasDoesNotInventChineseTranslation() async throws {
        guard let path = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECTOR_FIXTURES"] else {
            throw XCTSkip("Private unedited provider and TMDB captures required")
        }
        let folder = URL(fileURLWithPath: path), source = try Data(contentsOf: folder.appendingPathComponent("remaining-wogg-detail.json"))
        let detail = try SpiderResponseMapper.detail(JSONDecoder().decode(JSONValue.self, from: source), site: .init(key: "wogg", name: "玩偶哥哥", type: 3, api: "csp_WoGGGuard"), baseURL: nil)
        let input = TMDBMatchInput(detail: detail), transport = TMDBDirectorReplayTransport(folder: folder)
        XCTAssertNil(input.type); XCTAssertEqual(input.principalActors.count, 0)
        XCTAssertEqual(detail.director, "小阿多弗·亚历克斯")
        var without = detail; without.playSources = []
        XCTAssertEqual(input, TMDBMatchInput(detail: without))
        let repo = TMDBRepository(client: TMDBClient(credential: try .init(kind: .readAccessToken, value: "replay-only"), httpClient: transport))
        let result = try await repo.prepare(key: "real-remaining", input: input)
        guard case .candidates(let candidates) = result else { return XCTFail("TMDB lacks the Chinese director alias; automatic approval would be unsafe") }
        XCTAssertEqual(candidates.map(\.reference.id), [1550223])
        XCTAssertNotNil(candidates.first?.work.posterPath)
        XCTAssertFalse(TMDBMatcher.assess(try XCTUnwrap(candidates.first), input: input).corroboratedDirector)
        let requests = await transport.paths
        XCTAssertEqual(requests.filter { $0 == "/3/person/424258" }.count, 1)
        let before = await repo.binding(key: "real-remaining", input: input); XCTAssertNil(before)
        let confirmed = try await repo.choose(.init(type: .movie, id: 1550223), key: "real-remaining", input: input)
        guard case .matched(let movie, let binding) = confirmed else { return XCTFail("Explicit confirmation should load the candidate") }
        XCTAssertTrue(binding.manual); XCTAssertEqual(movie.reference.id, 1550223)
    }
}
private actor TMDBDirectorReplayTransport: HTTPClient {
    let folder: URL
    var paths: [String] = []
    init(folder: URL) { self.folder = folder }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.url.host, "api.themoviedb.org")
        paths.append(request.url.path)
        let file: String
        switch request.url.path {
        case "/3/search/multi": file = "search-remaining.json"
        case "/3/movie/1550223": file = "movie-1550223.json"
        case "/3/person/424258": file = "person-424258.json"
        default: throw TMDBError.invalidInput
        }
        return .init(url: request.url, statusCode: 200, headers: [:], body: try Data(contentsOf: folder.appendingPathComponent(file)))
    }
}


extension TMDBCapturedTests {
    func testRemainingRealUniqueTitleMatchesBeforeSourceLinesOnlyWhenRelaxed() async throws {
        guard let path = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECTOR_FIXTURES"] else { throw XCTSkip("Private captures required") }
        let folder = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: folder.appendingPathComponent("remaining-wogg-detail.json"))
        let detail = try SpiderResponseMapper.detail(JSONDecoder().decode(JSONValue.self, from: data), site: .init(key: "wogg", name: "玩偶哥哥", type: 3, api: "csp_WoGGGuard"), baseURL: nil)
        let sourceBefore = detail.playSources
        let transport = TMDBDirectorReplayTransport(folder: folder)
        let repo = TMDBRepository(client: TMDBClient(credential: try .init(kind: .readAccessToken, value: "replay-only"), httpClient: transport))
        let card = VideoSummary(siteKey: "wogg", siteName: "玩偶哥哥", videoID: detail.summary.videoID, title: "余光珍爱")
        let early = try await repo.prepare(key: "real", input: .init(detail: .init(summary: card)), persistBinding: false, policy: .relaxed)
        guard case .matched(let movie, let preview) = early else { return XCTFail("Title-only unique result should appear before provider details") }
        XCTAssertEqual(movie.reference.id, 1550223); XCTAssertTrue(preview.isRelaxed); XCTAssertNotNil(movie.work.artworkPath(.backdrop))
        let input = TMDBMatchInput(detail: detail)
        let final = try await repo.prepare(key: "real", input: input, policy: .relaxed)
        guard case .matched(let confirmed, let binding) = final else { return XCTFail("Missing Chinese director alias must not withdraw the relaxed match") }
        XCTAssertEqual(confirmed.reference.id, 1550223); XCTAssertTrue(binding.isRelaxed)
        let requests = await transport.paths
        XCTAssertEqual(requests, ["/3/search/multi", "/3/movie/1550223"])
        let strictCache = await repo.cachedResolution(key: "real", input: input); XCTAssertNil(strictCache)
        let strict = try await repo.prepare(key: "real", input: input)
        guard case .candidates = strict else { return XCTFail("Turning off must reverify with strict rules") }
        XCTAssertEqual(detail.playSources, sourceBefore)
    }
}
