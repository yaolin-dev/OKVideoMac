import XCTest
@testable import OKVideoCore

final class SiteProviderTests: XCTestCase {
    func testPlayListParserNeverInventsEpisodeNumbersFromArrayPosition() {
        let sources = PlayListParser.parse(
            sourceNames: "主线路",
            sourceEpisodes: "https://media.example.invalid/S01E14.mkv#https://media.example.invalid/behind-the-scenes.mkv"
        )

        XCTAssertEqual(sources.first?.episodes.map(\.name), [
            "S01E14.mkv",
            "behind-the-scenes.mkv"
        ])
        XCTAssertFalse(sources.first?.episodes[0].name.contains("第 1 集") ?? true)
        XCTAssertFalse(sources.first?.episodes[1].name.contains("第 2 集") ?? true)
    }

    func testJSONHomeCategoryAndDetailMapping() async throws {
        let client = RecordingHTTPClient { request in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            if values["ids"] != nil {
                return Self.response(
                    """
                    {
                      "list":[{
                        "vod_id":"detail-1",
                        "vod_name":"Fixture Detail",
                        "vod_pic":"poster.jpg",
                        "vod_year":"2026",
                        "vod_area":"Test",
                        "vod_director":"Fixture Director",
                        "vod_actor":"Fixture Actor",
                        "vod_content":"Fixture synopsis",
                        "vod_play_from":"Line A$$$Line B",
                        "vod_play_url":"Episode 1$https://media.example.invalid/one.m3u8#Episode 2$https://media.example.invalid/two.mp4$$$Backup$https://media.example.invalid/backup.m3u8"
                      }]
                    }
                    """
                )
            }
            if values["t"] != nil {
                XCTAssertEqual(values["f"], #"{"area":"fixture"}"#)
                return Self.response(
                    """
                    {"pagecount":2,"list":[{"vod_id":"vod-1","vod_name":"Fixture One"}]}
                    """
                )
            }
            return Self.response(
                """
                {
                  "class":[{"type_id":"movie","type_name":"Movies"}],
                  "filters":{
                    "movie":[{
                      "key":"area",
                      "name":"Area",
                      "value":[{"n":"Fixture","v":"fixture"}]
                    }]
                  },
                  "list":[{
                    "vod_id":"home-1",
                    "vod_name":"Home Fixture",
                    "vod_pic":"poster.jpg",
                    "vod_remarks":"Public fixture"
                  }]
                }
                """
            )
        }
        let provider = try StandardSiteProvider(
            site: SiteConfiguration(
                key: "fixture",
                name: "Fixture",
                type: 1,
                api: "api"
            ),
            httpClient: client,
            configurationBaseURL: URL(string: "https://example.invalid/config/")!
        )

        let home = try await provider.home()
        XCTAssertEqual(home.categories.first?.filters.first?.id, "area")
        XCTAssertEqual(home.recommendations.first?.posterURL?.absoluteString, "https://example.invalid/config/poster.jpg")

        let category = try await provider.category(
            id: "movie",
            page: 1,
            filters: ["area": "fixture"]
        )
        XCTAssertEqual(category.items.first?.title, "Fixture One")
        XCTAssertTrue(category.pagination.hasMore)

        let detail = try await provider.detail(id: "detail-1")
        XCTAssertEqual(detail.playSources.count, 2)
        XCTAssertEqual(detail.playSources[0].episodes.count, 2)
        XCTAssertEqual(detail.playSources[1].episodes.first?.name, "Backup")
    }

    func testXMLResponseMapping() async throws {
        let client = RecordingHTTPClient { _ in
            HTTPResponse(
                url: URL(string: "https://example.invalid/xml")!,
                statusCode: 200,
                headers: ["Content-Type": "application/xml"],
                body: Data(
                    """
                    <rss>
                      <class><ty id="1" name="Movies"/></class>
                      <list pagecount="3">
                        <video>
                          <id>fixture-xml</id>
                          <name>XML Fixture</name>
                          <pic>https://example.invalid/poster.jpg</pic>
                          <note>Fixture note</note>
                        </video>
                      </list>
                    </rss>
                    """.utf8
                )
            )
        }
        let provider = try StandardSiteProvider(
            site: SiteConfiguration(
                key: "xml",
                name: "XML",
                type: 0,
                api: "https://example.invalid/xml"
            ),
            httpClient: client,
            configurationBaseURL: nil
        )

        let home = try await provider.home()
        XCTAssertEqual(home.categories.first?.name, "Movies")
        XCTAssertEqual(home.recommendations.first?.videoID, "fixture-xml")
    }

    func testType4UsesURLSafeBase64Ext() async throws {
        let client = RecordingHTTPClient { request in
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
            let ext = items?.first(where: { $0.name == "ext" })?.value
            XCTAssertNotNil(ext)
            XCTAssertFalse(ext?.contains("=") ?? true)
            return Self.response(#"{"list":[]}"#)
        }
        let provider = try StandardSiteProvider(
            site: SiteConfiguration(
                key: "type4",
                name: "Type 4",
                type: 4,
                api: "https://example.invalid/api"
            ),
            httpClient: client,
            configurationBaseURL: nil
        )
        _ = try await provider.category(id: "1", page: 1, filters: ["x": "y"])
    }

    func testSearchPreservesSymbolKeywordInQuery() async throws {
        let keyword = "《群体》：测试 & 特辑"
        let client = RecordingHTTPClient { request in
            let query = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            XCTAssertEqual(
                query.first(where: { $0.name == "wd" })?.value,
                keyword
            )
            XCTAssertEqual(
                query.first(where: { $0.name == "quick" })?.value,
                "false"
            )
            return Self.response(#"{"list":[]}"#)
        }
        let provider = try StandardSiteProvider(
            site: SiteConfiguration(
                key: "symbols",
                name: "Symbols",
                type: 1,
                api: "https://example.invalid/api"
            ),
            httpClient: client,
            configurationBaseURL: nil
        )

        _ = try await provider.search(
            keyword: keyword,
            page: 1,
            quick: false
        )
    }

    func testDirectMediaClassifier() {
        XCTAssertTrue(MediaURLClassifier.isDirectMediaURL("https://example.invalid/a.m3u8?token=fixture"))
        XCTAssertTrue(MediaURLClassifier.isDirectMediaURL("file:///tmp/a.mp4"))
        XCTAssertFalse(MediaURLClassifier.isDirectMediaURL("javascript:alert(1)"))
        XCTAssertFalse(MediaURLClassifier.isDirectMediaURL("https://example.invalid/watch/1"))
    }

    func testEmptySpiderResponseUsesActionableError() {
        let site = SiteConfiguration(
            key: "empty",
            name: "空响应站点",
            type: 3,
            api: "csp_Empty"
        )

        XCTAssertThrowsError(
            try SpiderResponseMapper.detail(
                .string("  \n"),
                site: site,
                baseURL: nil
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("未返回数据"))
            XCTAssertFalse(error.localizedDescription.contains("JSON 无效"))
        }
    }

    func testEmptySpiderPageMatchesFongMiEmptyResult() throws {
        let site = SiteConfiguration(
            key: "empty-page",
            name: "空分页站点",
            type: 3,
            api: "csp_Empty"
        )

        let emptyStringPage = try SpiderResponseMapper.page(
            .string("  \n"),
            site: site,
            baseURL: nil,
            page: 1
        )
        let nullPage = try SpiderResponseMapper.page(
            .null,
            site: site,
            baseURL: nil,
            page: 2
        )
        let malformedPage = try SpiderResponseMapper.page(
            .string("not-json"),
            site: site,
            baseURL: nil,
            page: 3
        )

        XCTAssertTrue(emptyStringPage.items.isEmpty)
        XCTAssertEqual(emptyStringPage.pagination.page, 1)
        XCTAssertTrue(nullPage.items.isEmpty)
        XCTAssertEqual(nullPage.pagination.page, 2)
        XCTAssertTrue(malformedPage.items.isEmpty)
        XCTAssertEqual(malformedPage.pagination.page, 3)
    }

    func testEmptySpiderHomeMatchesFongMiEmptyResult() throws {
        let site = SiteConfiguration(
            key: "empty-home",
            name: "空首页站点",
            type: 3,
            api: "csp_Empty"
        )

        let home = try SpiderResponseMapper.home(
            .string(""),
            homeVideoValue: .string("null"),
            site: site,
            baseURL: nil
        )

        XCTAssertTrue(home.categories.isEmpty)
        XCTAssertTrue(home.recommendations.isEmpty)
    }

    func testSpiderHomePreservesProtocolSettingEntriesAsActions() throws {
        let site = SiteConfiguration(
            key: "generic-node-site",
            name: "Generic Node Site",
            type: 4,
            api: "/spider/generic/4"
        )

        let home = try SpiderResponseMapper.home(
            .string(
                #"{"class":[{"type_id":"setting","type_name":"任意功能入口"}],"list":[{"vod_id":"config-center","vod_name":"任意操作卡片","vod_pic":"https://example.invalid/poster.jpg"}]}"#
            ),
            homeVideoValue: nil,
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(home.categories.map(\.resolvedContentKind), [.action])
        XCTAssertTrue(home.recommendations.isEmpty)
        XCTAssertEqual(home.actionItems.map(\.title), ["任意操作卡片"])
        XCTAssertEqual(home.actionItems.map(\.itemID), ["config-center"])
    }

    func testSpiderHomeKeepsMediaWhoseTextOrIdentifierLooksFunctional() throws {
        let site = SiteConfiguration(
            key: "semantic-media",
            name: "Semantic Media",
            type: 3,
            api: "csp_SemanticMedia"
        )

        let home = try SpiderResponseMapper.home(
            .string(
                #"{"class":[{"type_id":"https://example.invalid/category","type_name":"设置中心电影"}],"list":[{"vod_id":"https://example.invalid/detail/1","vod_name":"配置中心往事","type_id":"https://example.invalid/category","vod_pic":"https://example.invalid/poster.jpg"}]}"#
            ),
            homeVideoValue: nil,
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(home.categories.map(\.name), ["设置中心电影"])
        XCTAssertEqual(home.recommendations.map(\.title), ["配置中心往事"])
        XCTAssertEqual(
            home.recommendations.first?.videoID,
            "https://example.invalid/detail/1"
        )
    }

    func testSpiderHomePreservesExplicitRecommendationCategoryOnlyWhenProvided() throws {
        let site = SiteConfiguration(
            key: "recommendation-semantics",
            name: "Recommendation Semantics",
            type: 3,
            api: "csp_Recommendation"
        )
        let explicit = try SpiderResponseMapper.home(
            .string(
                #"{"class":[{"type_id":"recommend","type_name":"推荐"}],"list":[]}"#
            ),
            homeVideoValue: nil,
            site: site,
            baseURL: nil
        )
        let absent = try SpiderResponseMapper.home(
            .string(
                #"{"class":[{"type_id":"movie","type_name":"电影"}],"list":[{"vod_id":"home-feed-1","vod_name":"首页影片"}]}"#
            ),
            homeVideoValue: nil,
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(explicit.categories.map(\.name), ["推荐"])
        XCTAssertEqual(absent.categories.map(\.name), ["电影"])
        XCTAssertFalse(absent.categories.contains { $0.name == "推荐" })
        XCTAssertEqual(absent.recommendations.map(\.title), ["首页影片"])
    }

    func testPromotionalPlaceholderIsExcludedAndMissingIDsRemainDiscoverable() throws {
        let site = SiteConfiguration(
            key: "discovery",
            name: "Discovery",
            type: 3,
            api: "csp_Discovery"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                """
                {
                  "list":[
                    {"vod_id":"-1001","vod_name":"Promotion"},
                    {"vod_id":"msearch:###Fixture","vod_name":"Fixture"},
                    {"vod_id":"folder-payload","vod_name":"Cloud Folder","vod_tag":"folder"},
                    {"vod_name":"Missing Identifier","vod_pic":"https://example.invalid/poster.jpg"},
                    {"vod_name":"Action Item","action":"login"}
                  ]
                }
                """.utf8
            ),
            site: site,
            baseURL: nil
        )
        let summaries = UpstreamResponseDecoder.summaries(
            from: response.videos,
            site: site,
            baseURL: nil
        )
        XCTAssertEqual(
            summaries.map(\.videoID),
            [
                "msearch:###Fixture",
                "folder-payload",
                "msearch:discovery:Missing Identifier",
                "action:discovery:Action Item"
            ]
        )
        XCTAssertEqual(summaries.map(\.title), [
            "Fixture",
            "Cloud Folder",
            "Missing Identifier",
            "Action Item"
        ])
        XCTAssertTrue(summaries[1].isFolder)
        XCTAssertEqual(summaries[1].tag, "folder")
    }

    func testPlayerUnwrapsUnavailableAndroidM3U8ProxyAndStringHeaders() throws {
        let site = SiteConfiguration(
            key: "dex",
            name: "DEX Fixture",
            type: 3,
            api: "csp_Fixture"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                #"""
                {
                  "parse":0,
                  "url":"http://127.0.0.1:-1/proxy?do=m3u8&url=https%3A%2F%2Fmedia.example.invalid%2Findex.m3u8%3Ftoken%3Dfixture",
                  "header":"{\"User-Agent\":\"FixtureAgent\",\"Referer\":\"https://provider.example.invalid/\"}"
                }
                """#.utf8
            ),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.url,
            "https://media.example.invalid/index.m3u8?token=fixture"
        )
        XCTAssertEqual(response.player?.headers["User-Agent"], "FixtureAgent")
        XCTAssertEqual(
            response.player?.headers["Referer"],
            "https://provider.example.invalid/"
        )
    }

    func testPlayerPreservesUsableLocalProxyURL() throws {
        let site = SiteConfiguration(
            key: "proxy",
            name: "Proxy Fixture",
            type: 3,
            api: "csp_Fixture"
        )
        let rawURL = "http://127.0.0.1:9978/proxy?do=m3u8&url=https%3A%2F%2Fmedia.example.invalid%2Findex.m3u8"
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(#"{"parse":0,"url":"\#(rawURL)"}"#.utf8),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(response.player?.url, rawURL)
    }

    func testPlayerSelectsFirstFongMiQualityArrayURL() throws {
        let site = SiteConfiguration(
            key: "quality-array",
            name: "Quality Array",
            type: 3,
            api: "csp_Fixture"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                #"{"parse":0,"url":["Original","https://media.example.invalid/original.mp4","Smart","https://media.example.invalid/smart.m3u8"]}"#.utf8
            ),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.url,
            "https://media.example.invalid/original.mp4"
        )
        XCTAssertEqual(
            response.player?.qualities,
            [
                PlaybackQuality(
                    name: "Original",
                    url: "https://media.example.invalid/original.mp4"
                ),
                PlaybackQuality(
                    name: "Smart",
                    url: "https://media.example.invalid/smart.m3u8"
                )
            ]
        )
    }

    func testPlayerPrefersOriginalQualityOverFongMiURLObjectPosition() throws {
        let site = SiteConfiguration(
            key: "quality-object",
            name: "Quality Object",
            type: 3,
            api: "csp_Fixture"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                #"{"parse":0,"url":{"values":[{"n":"Original","v":"https://media.example.invalid/original.mp4"},{"n":"Smart","v":"https://media.example.invalid/smart.m3u8"}],"position":1}}"#.utf8
            ),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.url,
            "https://media.example.invalid/original.mp4"
        )
        XCTAssertEqual(response.player?.qualities.map(\.name), ["Original", "Smart"])
    }

    func testPlayerHonorsFongMiURLObjectPositionWithoutOriginalQuality() throws {
        let site = SiteConfiguration(
            key: "quality-object-position",
            name: "Quality Object Position",
            type: 3,
            api: "csp_Fixture"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                #"{"parse":0,"url":{"values":[{"n":"720P","v":"https://media.example.invalid/720.mp4"},{"n":"1080P","v":"https://media.example.invalid/1080.mp4"}],"position":1}}"#.utf8
            ),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.url,
            "https://media.example.invalid/1080.mp4"
        )
    }

    func testPlayerFindsOriginalQualityWhenItIsNotFirstInArray() throws {
        let site = SiteConfiguration(
            key: "quality-array-original-second",
            name: "Quality Array Original Second",
            type: 3,
            api: "csp_Fixture"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                #"{"parse":0,"url":["智能","https://media.example.invalid/smart.m3u8","原画质","https://media.example.invalid/original.mp4"]}"#.utf8
            ),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.url,
            "https://media.example.invalid/original.mp4"
        )
        XCTAssertEqual(response.player?.qualities.map(\.name), ["智能", "原画质"])
    }

    func testSpiderActionIsPreservedInsteadOfBeingTreatedAsDetail() throws {
        let site = SiteConfiguration(
            key: "drive",
            name: "Drive",
            type: 3,
            api: "csp_MyDriveGuard"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(
                """
                {
                  "list":[{
                    "vod_id":"action-login",
                    "vod_name":"登入自己网盘",
                    "action":"LoginShow"
                  }]
                }
                """.utf8
            ),
            site: site,
            baseURL: nil
        )
        let summary = try XCTUnwrap(
            UpstreamResponseDecoder.summaries(
                from: response.videos,
                site: site,
                baseURL: nil
            ).first
        )

        XCTAssertEqual(summary.action, "LoginShow")
        XCTAssertEqual(summary.resolvedContentKind, .action)
    }

    func testLegacySiteHomeCacheDecodesWithoutActionItems() throws {
        let data = Data(
            #"{"categories":[],"recommendations":[]}"#.utf8
        )

        let home = try JSONDecoder().decode(SiteHome.self, from: data)

        XCTAssertTrue(home.categories.isEmpty)
        XCTAssertTrue(home.recommendations.isEmpty)
        XCTAssertTrue(home.actionItems.isEmpty)
    }

    func testBlankDetailPlaceholderIsRecognizedAsAction() throws {
        let site = SiteConfiguration(
            key: "settings",
            name: "Settings",
            type: 3,
            api: "csp_Settings"
        )
        let value = JSONValue.object([
            "list": .array([.object([:])]),
            "parse": .integer(0),
            "jx": .integer(0)
        ])

        XCTAssertEqual(
            try SpiderResponseMapper.selection(
                value,
                site: site,
                baseURL: nil
            ),
            .action(value)
        )
    }

    func testIncompletePlayableDetailUsesFallbackSummary() throws {
        let site = SiteConfiguration(
            key: "node-content",
            name: "Node Content",
            type: 3,
            api: "http://127.0.0.1/spider/content/3"
        )
        let fallback = VideoSummary(
            siteKey: site.key,
            siteName: site.name,
            videoID: "share-123",
            title: "无悔追踪",
            remarks: "全集"
        )
        let value = JSONValue.object([
            "list": .array([
                .object([
                    "vod_play_from": .string("夸克"),
                    "vod_play_url": .string("第1集$quark://episode-1")
                ])
            ])
        ])

        let result = try SpiderResponseMapper.selection(
            value,
            site: site,
            baseURL: nil,
            fallbackSummary: fallback,
            allowsPlaceholderAction: false
        )
        guard case .detail(let detail) = result else {
            return XCTFail("可播放的部分详情应使用搜索摘要补全")
        }
        XCTAssertEqual(detail.summary.videoID, "share-123")
        XCTAssertEqual(detail.summary.title, "无悔追踪")
        XCTAssertEqual(detail.summary.remarks, "全集")
        XCTAssertEqual(detail.playSources.first?.name, "夸克")
        XCTAssertEqual(detail.playSources.first?.episodes.count, 1)
    }

    func testContentSiteBlankDetailPlaceholderIsNotAnAction() throws {
        let site = SiteConfiguration(
            key: "node-content",
            name: "Node Content",
            type: 3,
            api: "http://127.0.0.1/spider/content/3"
        )

        XCTAssertThrowsError(
            try SpiderResponseMapper.selection(
                .object(["list": .array([.object([:])])]),
                site: site,
                baseURL: nil,
                fallbackSummary: VideoSummary(
                    siteKey: site.key,
                    siteName: site.name,
                    videoID: "share-123",
                    title: "无悔追踪"
                ),
                allowsPlaceholderAction: false
            )
        ) { error in
            XCTAssertEqual(
                error as? AppError,
                .spider("Spider 详情响应缺少可识别的影视信息")
            )
        }
    }

    func testEmptyDetailListRemainsAnError() throws {
        let site = SiteConfiguration(
            key: "broken",
            name: "Broken",
            type: 3,
            api: "csp_Broken"
        )

        XCTAssertThrowsError(
            try SpiderResponseMapper.selection(
                .object(["list": .array([])]),
                site: site,
                baseURL: nil
            )
        )
    }

    func testSpiderPlayerSurfacesProviderMessageWhenURLIsEmpty() throws {
        let site = SiteConfiguration(
            key: "drive",
            name: "Drive",
            type: 3,
            api: "csp_WoGGGuard"
        )

        XCTAssertThrowsError(
            try SpiderResponseMapper.player(
                .object([
                    "parse": .integer(0),
                    "url": .string(""),
                    "msg": .string("未扫码授权无法观看")
                ]),
                site: site
            )
        ) { error in
            XCTAssertEqual(error as? AppError, .spider("未扫码授权无法观看"))
        }
    }

    private static func response(_ json: String) -> HTTPResponse {
        HTTPResponse(
            url: URL(string: "https://example.invalid/config/api")!,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }
}

private final class RecordingHTTPClient: HTTPClient {
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try handler(request)
    }
}
