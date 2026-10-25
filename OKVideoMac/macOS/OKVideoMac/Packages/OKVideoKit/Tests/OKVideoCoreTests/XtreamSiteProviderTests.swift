import XCTest
@testable import OKVideoCore

final class XtreamSiteProviderTests: XCTestCase {
    func testHomeRejectsExplicitExpiredStatusBeforeLoadingCatalogs() async throws {
        let httpClient = try XtreamProviderFixtureHTTPClient(
            responses: [
                "auth": Data(
                    #"{"user_info":{"auth":1,"status":"Expired","exp_date":"4102444800"}}"#.utf8
                ),
                "get_vod_categories": Data("[]".utf8),
                "get_series_categories": Data("[]".utf8)
            ]
        )
        let provider = try makeProvider(httpClient: httpClient)

        await XCTAssertThrowsErrorAsync(
            try await provider.home()
        ) { error in
            XCTAssertEqual(
                error as? XtreamClientError,
                .accountUnavailable(status: "Expired")
            )
        }
        let movieCategoryRequests = await httpClient.requestCount(
            action: "get_vod_categories"
        )
        let seriesCategoryRequests = await httpClient.requestCount(
            action: "get_series_categories"
        )
        XCTAssertEqual(movieCategoryRequests, 0)
        XCTAssertEqual(seriesCategoryRequests, 0)
    }

    func testHomeLoadsCatalogsForActiveAccountWithPastExpiration() async throws {
        let httpClient = try XtreamProviderFixtureHTTPClient(
            responses: [
                "auth": Data(
                    #"{"user_info":{"auth":1,"status":"Active","exp_date":"1"}}"#.utf8
                ),
                "get_vod_categories": Data(
                    #"[{"category_id":"10","category_name":"Movies"}]"#.utf8
                ),
                "get_series_categories": Data(
                    #"[{"category_id":"20","category_name":"Series"}]"#.utf8
                )
            ]
        )
        let provider = try makeProvider(httpClient: httpClient)

        let home = try await provider.home()
        let movieCategoryRequests = await httpClient.requestCount(action: "get_vod_categories")
        let seriesCategoryRequests = await httpClient.requestCount(action: "get_series_categories")
        XCTAssertEqual(home.categories.map(\.name), ["Movies", "Series"])
        XCTAssertEqual(movieCategoryRequests, 1)
        XCTAssertEqual(seriesCategoryRequests, 1)
    }

    func testHomePropagatesCategoryAuthorizationFailureAfterActivePastExpiration() async throws {
        for statusCode in [401, 403] {
            let httpClient = try XtreamProviderFixtureHTTPClient(
                responses: [
                    "auth": Data(
                        #"{"user_info":{"auth":1,"status":"Active","exp_date":"1"}}"#.utf8
                    ),
                    "get_vod_categories": Data("[]".utf8),
                    "get_series_categories": Data("[]".utf8)
                ],
                statusCodes: ["get_vod_categories": statusCode]
            )
            let provider = try makeProvider(httpClient: httpClient)

            await XCTAssertThrowsErrorAsync(try await provider.home()) { error in
                XCTAssertEqual(error as? HTTPClientError, .statusCode(statusCode))
            }
            let movieCategoryRequests = await httpClient.requestCount(
                action: "get_vod_categories"
            )
            XCTAssertEqual(movieCategoryRequests, 1)
        }
    }

    func testMovieCatalogUsesNamespacedIdentityAndLocalPagination() async throws {
        let httpClient = try fixtureHTTPClient()
        let provider = try makeProvider(httpClient: httpClient, pageSize: 1)

        let home = try await provider.home()
        XCTAssertEqual(
            home.categories.map(\.name),
            ["Drama", "Documentary", "Drama Series", "Sparse Series"]
        )
        XCTAssertEqual(
            home.categories.filter { $0.id.hasPrefix("xtr.vod.category.") }.count,
            2
        )
        XCTAssertEqual(
            home.categories.filter { $0.id.hasPrefix("xtr.series.category.") }.count,
            2
        )
        XCTAssertTrue(home.recommendations.isEmpty)

        let first = try await provider.category(
            id: try XCTUnwrap(home.categories.first?.id),
            page: 1,
            filters: [:]
        )
        let second = try await provider.category(
            id: try XCTUnwrap(home.categories.first?.id),
            page: 2,
            filters: [:]
        )

        XCTAssertEqual(first.items.map(\.title), ["Fixture Movie One"])
        XCTAssertEqual(second.items.map(\.title), ["Fixture Movie Two"])
        XCTAssertTrue(first.items[0].videoID.hasPrefix("xtr.movie."))
        XCTAssertEqual(first.pagination.pageCount, 2)
        XCTAssertTrue(first.pagination.hasMore)
        let streamRequestCount = await httpClient.requestCount(
            action: "get_vod_streams"
        )
        XCTAssertEqual(
            streamRequestCount,
            1,
            "Page two must reuse the bounded catalog response instead of refetching it"
        )
    }

    func testMovieDetailAndPlaybackKeepCredentialsOutOfDurableModels() async throws {
        let httpClient = try fixtureHTTPClient()
        let provider = try makeProvider(httpClient: httpClient)
        let home = try await provider.home()
        let page = try await provider.category(
            id: try XCTUnwrap(home.categories.first?.id),
            page: 1,
            filters: [:]
        )

        let detail = try await provider.detail(
            id: try XCTUnwrap(page.items.first?.videoID)
        )

        XCTAssertEqual(detail.summary.title, "Fixture Movie One")
        XCTAssertEqual(detail.summary.year, "2024")
        XCTAssertEqual(detail.summary.categoryName, "Drama")
        XCTAssertEqual(TMDBMatchInput(detail: detail).type, .movie)
        XCTAssertEqual(detail.director, "Director One")
        XCTAssertEqual(detail.actors, "Actor One, Actor Two")
        XCTAssertEqual(detail.synopsis, "Fixture plot")
        XCTAssertEqual(detail.playSources.count, 1)
        XCTAssertEqual(detail.playSources[0].episodes.count, 1)

        let episode = detail.playSources[0].episodes[0]
        XCTAssertEqual(episode.metadata?.form, .movie)
        let reference = try XCTUnwrap(episode.providerResourceReference)
        let persistedJSON = String(
            decoding: try JSONEncoder().encode(detail),
            as: UTF8.self
        )
        XCTAssertFalse(persistedJSON.contains("user name"))
        XCTAssertFalse(persistedJSON.contains("p/word"))
        XCTAssertFalse(episode.url.contains("example.invalid"))
        XCTAssertEqual(reference.providerKind, "xtream")
        XCTAssertEqual(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(reference),
            reference
        )
        XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))

        let result = try await provider.player(
            flag: detail.playSources[0].name,
            episodeURL: episode.url
        )
        XCTAssertEqual(
            result.url,
            "https://example.invalid:8443/iptv/movie/user%20name/p%2Fword/1001.mkv"
        )
        XCTAssertFalse(result.needsParsing)
        XCTAssertEqual(result.networkPolicy, .systemHTTPProxy)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
        XCTAssertEqual(result.resourceReference, reference)
        XCTAssertEqual(result.headers["User-Agent"], "OKVideoMac/XtreamTests")
    }

    func testMovieProviderRejectsForeignOrMalformedReferences() async throws {
        let provider = try makeProvider(httpClient: try fixtureHTTPClient())
        await XCTAssertThrowsErrorAsync(
            try await provider.detail(id: "1001")
        ) { error in
            XCTAssertEqual(
                error as? XtreamSiteProviderError,
                .invalidVideoIdentifier
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await provider.player(flag: "Movie", episodeURL: "https://bad.invalid/movie")
        ) { error in
            XCTAssertEqual(
                error as? XtreamSiteProviderError,
                .invalidPlaybackLocator
            )
        }

        let home = try await provider.home()
        let page = try await provider.category(
            id: try XCTUnwrap(home.categories.first?.id),
            page: 1,
            filters: [:]
        )
        let detail = try await provider.detail(
            id: try XCTUnwrap(page.items.first?.videoID)
        )
        var foreign = try XCTUnwrap(
            detail.playSources.first?.episodes.first?.providerResourceReference
        )
        foreign.configurationIdentity = UUID().uuidString.lowercased()
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(foreign))
    }

    func testMovieHistoryRefreshRebuildsCredentialURLFromOpaqueReference()
        async throws {
        let provider = try makeProvider(httpClient: try fixtureHTTPClient())
        let detail = try await provider.detail(id: "xtr.movie.31303031")
        let source = try XCTUnwrap(detail.playSources.first)
        let episode = try XCTUnwrap(source.episodes.first)
        let reference = try XCTUnwrap(episode.providerResourceReference)
        let serializedReference = String(
            decoding: try JSONEncoder().encode(reference),
            as: UTF8.self
        )

        XCTAssertFalse(serializedReference.contains("user name"))
        XCTAssertFalse(serializedReference.contains("p/word"))
        XCTAssertFalse(serializedReference.contains("example.invalid"))

        let refreshed = try await provider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: detail.summary.videoID,
                title: detail.summary.title,
                sourceIdentity: reference.sourceIdentity,
                resourceIdentity: reference.episodeIdentity,
                sourceName: source.name,
                episodeName: episode.name,
                episodeReference: reference.stableResourceLocator,
                providerResourceReference: reference
            )
        )

        XCTAssertEqual(refreshed.episode.url, reference.stableResourceLocator)
        XCTAssertEqual(refreshed.playbackResult.resourceReference, reference)
        XCTAssertEqual(refreshed.playbackResult.networkPolicy, .systemHTTPProxy)
        XCTAssertEqual(
            refreshed.playbackResult.url,
            "https://example.invalid:8443/iptv/movie/user%20name/p%2Fword/1001.mkv"
        )
    }

    func testCredentialBearingArtworkAndDirectSourceNeverEnterMediaModels()
        async throws {
        let client = try XtreamProviderFixtureHTTPClient(
            responses: [
                "get_vod_streams": Data(
                    #"[{"stream_id":1001,"name":"Unsafe URLs","category_id":10,"container_extension":"mkv","stream_icon":"https://example.invalid/movie/user/pass/1001.jpg","direct_source":"https://example.invalid/movie/user/pass/1001.mkv"}]"#.utf8
                ),
                "get_vod_info": Data(
                    #"{"info":{"name":"Unsafe URLs","movie_image":"https://example.invalid/movie/user/pass/1001.jpg"},"movie_data":{"stream_id":1001,"category_id":10,"container_extension":"mkv","direct_source":"https://example.invalid/movie/user/pass/1001.mkv"}}"#.utf8
                )
            ]
        )
        let provider = try makeProvider(httpClient: client)

        let page = try await provider.category(
            id: "xtr.vod.category.3130",
            page: 1,
            filters: [:]
        )
        XCTAssertNil(try XCTUnwrap(page.items.first).posterURL)

        let detail = try await provider.detail(id: "xtr.movie.31303031")
        XCTAssertNil(detail.summary.posterURL)
        let episode = try XCTUnwrap(detail.playSources.first?.episodes.first)
        XCTAssertFalse(episode.url.contains("example.invalid"))
        XCTAssertFalse(episode.url.contains("user"))
        XCTAssertFalse(episode.url.contains("pass"))
    }

    func testClassicSeriesMapsEverySeasonToItsOwnStableSource() async throws {
        let provider = try makeProvider(httpClient: try fixtureHTTPClient())
        let home = try await provider.home()
        let seriesCategory = try XCTUnwrap(
            home.categories.first { $0.id.hasPrefix("xtr.series.category.") }
        )
        let page = try await provider.category(
            id: seriesCategory.id,
            page: 1,
            filters: [:]
        )
        XCTAssertEqual(page.items.map(\.title), ["Fixture Series", "Sparse Series"])
        XCTAssertTrue(page.items.allSatisfy { $0.videoID.hasPrefix("xtr.series.") })

        let detail = try await provider.detail(
            id: try XCTUnwrap(page.items.first?.videoID)
        )
        XCTAssertEqual(detail.summary.title, "Fixture Series")
        XCTAssertEqual(TMDBMatchInput(detail: detail).type, .tv)
        XCTAssertEqual(detail.playSources.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(
            detail.playSources.map { $0.episodes.map(\.name) },
            [["Pilot", "Second"], ["Return"]]
        )
        XCTAssertNotEqual(
            detail.playSources[0].stableIdentity,
            detail.playSources[1].stableIdentity
        )
        XCTAssertTrue(detail.playSources.allSatisfy {
            $0.referenceIdentity?.contains(".season.") == true
        })

        let episode = detail.playSources[1].episodes[0]
        XCTAssertEqual(episode.metadata, .init(form: .series, season: 2, episode: 1))
        let reference = try XCTUnwrap(episode.providerResourceReference)
        XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))
        XCTAssertEqual(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(reference),
            reference
        )
        let result = try await provider.player(
            flag: detail.playSources[1].name,
            episodeURL: episode.url
        )
        XCTAssertEqual(
            result.url,
            "https://example.invalid:8443/iptv/series/user%20name/p%2Fword/7101.mp4"
        )
        XCTAssertEqual(result.networkPolicy, .systemHTTPProxy)
        XCTAssertEqual(result.resourceReference, reference)
    }

    func testFlatSeriesDerivesSeasonSourcesWithoutSeasonMetadata() async throws {
        let responses: [String: Data] = [
            "get_vod_categories": try fixture("xtream-vod-categories"),
            "get_series_categories": try fixture("xtream-series-categories"),
            "get_series": try fixture("xtream-series-list"),
            "get_series_info": try fixture("xtream-series-info-flat")
        ]
        let provider = try makeProvider(
            httpClient: try XtreamProviderFixtureHTTPClient(responses: responses)
        )
        let detail = try await provider.detail(
            id: "xtr.series.383030"
        )

        XCTAssertEqual(detail.playSources.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(detail.playSources.map(\.episodes.count), [1, 2])
        XCTAssertEqual(
            detail.playSources[1].episodes.map(\.name),
            ["S2E1", "S2E2"]
        )
    }

    func testEmptyVODMetadataUsesCachedCatalogForDetailAndPlayback() async throws {
        let http = try XtreamProviderFixtureHTTPClient(responses: [
            "get_vod_streams": fixture("xtream-vod-streams"),
            "get_series": Data("[]".utf8),
            "get_vod_categories": fixture("xtream-vod-categories"),
            "get_vod_info": Data(#"{"info":[],"movie_data":{}}"#.utf8)
        ])
        let provider = try makeProvider(httpClient: http)
        let results = try await provider.search(keyword: "Fixture Movie One", page: 1, quick: false)
        let detail = try await provider.detail(id: XCTUnwrap(results.items.first?.videoID))
        XCTAssertEqual(detail.summary.title, "Fixture Movie One")
        let episode = try XCTUnwrap(detail.playSources.first?.episodes.first)
        let media = try await provider.player(flag: detail.playSources[0].name, episodeURL: episode.url)
        XCTAssertTrue(media.url.hasSuffix("/1001.mp4"))
        XCTAssertEqual(media.validationPolicy, .playerAuthoritative)
    }

    func testSearchBuildsOneNormalizedMovieAndSeriesIndex() async throws {
        let httpClient = try fixtureHTTPClient()
        let provider = try makeProvider(httpClient: httpClient, pageSize: 2)

        let first = try await provider.search(
            keyword: "ＦＩＸＴＵＲＥ",
            page: 1,
            quick: true
        )
        let second = try await provider.search(
            keyword: "fixture",
            page: 2,
            quick: false
        )

        XCTAssertEqual(first.items.map(\.title), ["Fixture Movie One", "Fixture Movie Two"])
        XCTAssertEqual(second.items.map(\.title), ["Fixture Series"])
        XCTAssertEqual(first.pagination.pageCount, 2)
        let movieRequests = await httpClient.requestCount(
            action: "get_vod_streams"
        )
        let seriesRequests = await httpClient.requestCount(
            action: "get_series"
        )
        XCTAssertEqual(movieRequests, 1)
        XCTAssertEqual(seriesRequests, 1)
    }

    func testCatalogSearchStressAt10KAnd100KStaysBelowInitialSafetyDefault()
        async throws {
        for count in [10_000, 100_000] {
            let payload = stressCatalog(count: count)
            XCTAssertLessThan(
                payload.count,
                XtreamCatalogResponsePolicy.initialSafetyDefault
                    .maximumResponseBytes
            )
            let httpClient = try XtreamProviderFixtureHTTPClient(
                responses: [
                    "get_vod_streams": payload,
                    "get_series": Data("[]".utf8)
                ]
            )
            let provider = try makeProvider(httpClient: httpClient)

            let page = try await provider.search(
                keyword: "Needle \(count - 1)",
                page: 1,
                quick: false
            )

            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items[0].title, "Needle \(count - 1)")
        }
    }

    private func makeProvider(
        httpClient: HTTPClient,
        pageSize: Int = 60
    ) throws -> XtreamSiteProvider {
        let configuration = try XtreamProviderConfiguration(
            providerID: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!,
            displayName: "Fixture Xtream",
            serverBaseURL: XCTUnwrap(
                URL(string: "https://example.invalid:8443/iptv")
            )
        )
        return try XtreamSiteProvider(
            configuration: configuration,
            credentials: XtreamCredentials(
                username: "user name",
                password: "p/word"
            ),
            httpClient: httpClient,
            userAgent: "OKVideoMac/XtreamTests",
            pageSize: pageSize
        )
    }

    private func fixtureHTTPClient() throws -> XtreamProviderFixtureHTTPClient {
        try XtreamProviderFixtureHTTPClient(
            responses: [
                "auth": Data(
                    #"{"user_info":{"auth":1,"status":"Active","exp_date":"4102444800"}}"#.utf8
                ),
                "get_vod_categories": fixture("xtream-vod-categories"),
                "get_vod_streams": fixture("xtream-vod-streams"),
                "get_vod_info": fixture("xtream-vod-info"),
                "get_series_categories": fixture("xtream-series-categories"),
                "get_series": fixture("xtream-series-list"),
                "get_series_info": fixture("xtream-series-info-classic")
            ]
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func stressCatalog(count: Int) -> Data {
        var data = Data("[".utf8)
        for index in 0..<count {
            if index > 0 { data.append(contentsOf: Data(",".utf8)) }
            let title = index == count - 1
                ? "Needle \(index)"
                : "Catalog Item \(index)"
            data.append(
                contentsOf: Data(
                    "{\"stream_id\":\(index),\"name\":\"\(title)\",\"category_id\":\"1\",\"container_extension\":\"mp4\"}".utf8
                )
            )
        }
        data.append(contentsOf: Data("]".utf8))
        return data
    }
}

private actor XtreamProviderFixtureHTTPClient: HTTPClient {
    private let responses: [String: Data]
    private let statusCodes: [String: Int]
    private var actionCounts: [String: Int] = [:]

    init(responses: [String: Data], statusCodes: [String: Int] = [:]) throws {
        self.responses = responses
        self.statusCodes = statusCodes
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "action" })?.value ?? "auth"
        actionCounts[action, default: 0] += 1
        if let statusCode = statusCodes[action], !(200...299).contains(statusCode) {
            throw HTTPClientError.statusCode(statusCode)
        }
        guard let body = responses[action] else {
            throw AppError.network("Missing Xtream fixture for \(action)")
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            body: body
        )
    }

    func requestCount(action: String) -> Int {
        actionCounts[action, default: 0]
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
