import XCTest
@testable import OKVideoCore

final class TMDBMatcherTests: XCTestCase {

    private func releaseInput(_ names: [String], year: String? = nil, category: String? = nil) -> TMDBMatchInput {
        .init(detail: .init(summary: .init(siteKey: "wogg", siteName: "Source", videoID: "last", title: "最后孤屋", year: year, categoryName: category),
            playSources: [.init(name: "original", episodes: names.map { .init(name: $0, url: "opaque:unchanged") })]))
    }
    func testMixedChineseAndWesternCastPreservesIndividualPeople() {
        let value = input("最后孤屋", year: "2026", category: "动作 科幻 悬疑", actors: "格蕾塔·李 瓦格纳·马拉 Riley Chung 艾玛·霍 Noah Alexander Sosnowski")
        XCTAssertEqual(value.principalActors, ["格蕾塔李", "瓦格纳马拉", "rileychung", "艾玛霍", "noahalexandersosnowski"])
        XCTAssertEqual(input("Film", actors: "Tom Hanks Helena Bonham Carter").principalActors.count, 1)
    }
    func testFilenamesNeverSupplyOrVetoWorkIdentity() throws {
        let winner = try candidate(title: "最后孤屋", year: "2026", type: .movie)
        let names = ["The.Last.House.2026.1080p", "Another.Film.1990.S09E01.2160p", "R-任何东西 S01E01", "2026.mp4"]
        let without = releaseInput([], year: "2026", category: "电影")
        let withFiles = releaseInput(names, year: "2026", category: "电影")
        XCTAssertEqual(without, withFiles)
        XCTAssertEqual(TMDBRepository.fingerprint(without), TMDBRepository.fingerprint(withFiles))
        XCTAssertNotNil(TMDBMatcher.automaticMatch([winner], input: withFiles))
        XCTAssertNil(TMDBMatcher.automaticMatch([winner], input: releaseInput(names)))
        XCTAssertNil(releaseInput(names).year)
        XCTAssertNil(releaseInput(names).type)
        XCTAssertNil(releaseInput(names).season)
        XCTAssertFalse(releaseInput(names).hasConflict)
        XCTAssertNil(TMDBMatcher.automaticMatch([winner], input: releaseInput(names, year: "1990", category: "电影")))
    }
    func testVerifiedPersonAliasesBelongToDistinctPeople() throws {
        let work = try candidate(title: "翠鸟谋杀案", year: "2026", extra: #", "aggregate_credits":{"cast":[{"id":1,"name":"莱丝利·曼维尔"},{"id":2,"name":"Tim McMullan","also_known_as":["蒂姆·迈克穆兰"]}]}"#)
        let source = input("翠鸟谋杀案", year: "2026", category: nil, actors: "莱丝利·曼维尔 蒂姆·迈克穆兰")
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: source))
        let duplicate = try candidate(title: "翠鸟谋杀案", year: "2026", extra: #", "aggregate_credits":{"cast":[{"id":1,"name":"莱丝利·曼维尔","also_known_as":["蒂姆·迈克穆兰"]}]}"#)
        XCTAssertNil(TMDBMatcher.automaticMatch([duplicate], input: source))
    }
    func testMissingYearCanUseTwoPrincipalActorsButKnownConflictStillBlocks() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: nil, category: nil, actors: "黄日华 陈浩民")))
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: nil, category: nil, actors: "黄日华")))
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: "2003", category: nil, actors: "黄日华 陈浩民")))
    }
    func testBilingualTitlesMustBothNameTheSameWork() throws {
        let work = try candidate(title: "最后孤屋", year: "2026", type: .movie, extra: #", "original_title":"The Last House""#)
        for name in ["最后孤屋(The Last House)", "最后孤屋/The Last House"] {
            XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input(name, year: "2026", category: "电影")))
        }
        for name in ["最后孤屋(Another House)", "最后孤屋(导演访谈)", "最后孤屋(电影版)"] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input(name, year: "2026", category: "电影")))
        }
    }
    func testDirectorOriginalNameMatchesButUnverifiedTransliterationCannotApproveAlone() throws {
        let work = try candidate(title: "最后孤屋", year: "2026", type: .movie, extra: #", "original_title":"The Last House", "credits":{"crew":[{"id":18865,"name":"路易斯·莱特里尔","original_name":"Louis Leterrier","job":"Director"}]}"#)
        for name in ["Louis Leterrier", "路易斯·莱特里尔"] {
            XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("最后孤屋", year: "2026", category: "电影", director: name)))
        }
        let variant = input("最后孤屋", year: "2026", category: "电影", director: "路易斯·莱特列尔")
        XCTAssertFalse(TMDBMatcher.assess(work, input: variant).conflict)
        XCTAssertTrue(TMDBMatcher.assess(work, input: variant).unresolvedDirector)
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: variant))
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("最后孤屋", year: "2026", category: "电影", director: "Michael Mann")))
    }
    func testDiscoveryCreditsSurviveDecoderAndCanPrepareBeforeStreams() throws {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"list":[{"vod_id":"1","vod_name":"天龙八部","vod_year":"1997","vod_actor":"黄日华 陈浩民","vod_director":"李添胜"}]}"#.utf8))
        let site = SiteConfiguration(key: "wogg", name: "Source", type: 3, api: "csp_Test")
        let detail = try SpiderResponseMapper.detail(payload, site: site, baseURL: nil)
        let summary = try JSONDecoder().decode(VideoSummary.self, from: JSONEncoder().encode(detail.summary))
        let value = TMDBMatchInput(detail: .init(summary: summary))
        XCTAssertEqual(value.principalActors, ["黄日华", "陈浩民"])
        XCTAssertTrue(value.canPrepareFromSummary)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([try candidate(title: "天龙八部", year: "1997", extra: matchingCast)], input: value))
    }

    func testVerifiedDirectorCanCorroborateMissingFormButNotMissingYear() throws {
        let work = try candidate(title: "余光珍爱", year: "2025", type: .movie, extra: #", "credits":{"crew":[{"id":424258,"name":"Adolfo Alix Jr.","also_known_as":["Adolfo Borinaga Alix Jr"],"job":"Director"}]}"#)
        for name in ["Adolfo Alix Jr.", "Adolfo Borinaga Alix Jr"] {
            let source = input("余光珍爱", year: "2025", category: "剧情 悬疑 恐怖", director: name, actors: "未知")
            let evidence = TMDBMatcher.assess(work, input: source)
            XCTAssertTrue(evidence.corroboratedDirector); XCTAssertTrue(evidence.requiresCompleteSearch)
            XCTAssertTrue(source.canPrepareFromSummary)
            XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: source))
        }
        for source in [input("余光珍爱", year: nil, category: nil, director: "Adolfo Alix Jr."),
                       input("余光珍爱", year: "2024", category: nil, director: "Adolfo Alix Jr."),
                       input("余光珍爱", year: "2025", category: "电视剧", director: "Adolfo Alix Jr."),
                       input("余光珍爱", year: "2025", category: "综艺", director: "Adolfo Alix Jr."),
                       input("余光珍爱2025", year: "2025", category: nil, director: "Adolfo Alix Jr."),
                       input("余光珍爱", year: "2025", category: nil, director: "小阿多弗·亚历克斯")] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: source))
        }
    }

    func testDirectorEvidenceRequiresActualRoleAndEverySourceDirector() throws {
        let source = input("余光珍爱", year: "2025", category: nil, director: "Director One")
        for job in ["Writer", "Producer", "Creator"] {
            let work = try candidate(title: "余光珍爱", year: "2025", type: .movie, extra: ", \"credits\":{\"crew\":[{\"id\":1,\"name\":\"Director One\",\"job\":\"\(job)\"}]}" )
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: source))
        }
        let work = try candidate(title: "余光珍爱", year: "2025", type: .movie, extra: #", "credits":{"crew":[{"id":1,"name":"Director One","job":"Director"}]}"#)
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("余光珍爱", year: "2025", category: nil, director: "Director One / Director Two")))
        let sharedAlias = try candidate(title: "余光珍爱", year: "2025", type: .movie, extra: #", "credits":{"crew":[{"id":1,"name":"Director One","job":"Director"},{"id":2,"name":"Director Two","also_known_as":["Director One"],"job":"Director"}]}"#)
        XCTAssertFalse(TMDBMatcher.assess(sharedAlias, input: source).corroboratedDirector)
        XCTAssertNil(TMDBMatcher.automaticMatch([sharedAlias], input: source))
    }

    func testAggregateDirectorJobsAndSameTitleRivalsStayStrict() throws {
        let source = input("测试剧", year: "2025", category: nil, director: "Director One")
        let work = try candidate(1, title: "测试剧", year: "2025", extra: #", "aggregate_credits":{"crew":[{"id":10,"name":"Director One","jobs":[{"job":"Director","episode_count":6}]}]}"#)
        XCTAssertTrue(TMDBMatcher.assess(work, input: source).corroboratedDirector)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: source))
        let rival = try candidate(2, title: "测试剧", year: "2025", type: .movie)
        XCTAssertNil(TMDBMatcher.automaticMatch([work, rival], input: source))
    }

    private func input(_ title: String, year: String? = "2023", category: String? = "电视剧", director: String? = nil, actors: String? = nil) -> TMDBMatchInput {
        .init(detail: VideoDetail(summary: .init(siteKey: "site", siteName: "Site", videoID: "provider-only", title: title, year: year, categoryName: category), director: director, actors: actors))
    }
    private func candidate(_ id: Int = 1, title: String = "阿索卡", year: String? = "2023", type: TMDBMediaType = .tv, extra: String = "") throws -> TMDBCandidate {
        let date = year.map { ",\"\(type == .movie ? "release_date" : "first_air_date")\":\"\($0)-01-01\"" } ?? ""
        let data = Data("{\"id\":\(id),\"\(type == .movie ? "title" : "name")\":\"\(title)\"\(date)\(extra)}".utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return .init(reference: .init(type: type, id: id), work: try decoder.decode(TMDBWork.self, from: data))
    }
    private func season(_ number: Int = 2) throws -> TMDBSeason {
        let data = Data("{\"season_number\":\(number),\"episodes\":[{\"id\":203,\"episode_number\":3},{\"id\":201,\"episode_number\":1}]}".utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBSeason.self, from: data)
    }

    func testTVBoxWhitespaceSeparatedChineseCastSupportsUnknownGenreCategory() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        for separator in [" ", "  ", "\t", "\n", "\r\n", "\u{3000}", "\u{00a0}"] {
            let value = input("天龙八部", year: "1997", category: "剧情 武侠", actors: ["黄日华", "陈浩民", "樊少皇"].joined(separator: separator))
            XCTAssertEqual(value.principalActors, ["黄日华", "陈浩民", "樊少皇"])
            XCTAssertEqual(value.people, ["黄日华", "陈浩民", "樊少皇"])
            XCTAssertTrue(TMDBMatcher.assess(work, input: value).corroboratedCast)
            XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: value))
        }
    }

    func testPersonParsingPreservesWesternNamesAndChineseTransliterations() throws {
        let value = input("测试", director: "杨磊 陈木胜", actors: "Tom Hanks / Helena Bonham Carter / 汤姆·克鲁斯 刘德华 / 未知 / 刘德华")
        XCTAssertEqual(value.directors, ["杨磊", "陈木胜"])
        XCTAssertEqual(value.principalActors, ["tomhanks", "helenabonhamcarter", "汤姆克鲁斯", "刘德华"])
        XCTAssertFalse(value.people.contains("未知"))
        let latin = input("测试", actors: "Tom Hanks Helena Bonham Carter")
        XCTAssertEqual(latin.principalActors.count, 1, "Ambiguous Latin spaces must not fabricate separate people")
        let work = try candidate(title: "测试", type: .movie, extra: #", "credits":{"crew":[{"id":10,"name":"杨磊","job":"Director"}]}"#)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("测试", category: "电影", director: "杨磊 陈木胜")))
    }

    func testWhitespaceCastDoesNotRelaxYearTypeLeadOrDuplicateChecks() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        for value in [input("天龙八部", year: "2003", category: nil, actors: "黄日华 陈浩民"),
                      input("天龙八部", year: "1997", category: "电影", actors: "黄日华 陈浩民"),
                      input("天龙八部", year: "1997", category: nil, actors: "黄日华 黄日华"),
                      input("天龙八部", year: "1997", category: nil, actors: "甲演员 乙演员 丙演员 黄日华 陈浩民")] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: value))
        }
        let value = input("天龙八部", year: "1997", category: nil, actors: "黄日华 陈浩民")
        XCTAssertNil(TMDBMatcher.automaticMatch([work, try candidate(2, title: "天龙八部", year: "1997")], input: value))
    }

    func testTVBoxRegionalAndGenreCategoriesMatchWithoutManualBinding() throws {
        let tv = try candidate()
        for category in ["国产剧", "大陆剧", "欧美剧", "香港剧", "台湾剧", "韓國劇", "日韩剧", "泰剧", "海外剧"] {
            let value = input("阿索卡", category: category)
            XCTAssertEqual(value.type, .tv, category)
            XCTAssertNotNil(TMDBMatcher.automaticMatch([tv], input: value), category)
        }
        let movie = try candidate(type: .movie)
        for category in ["动作片", "剧情片", "爱情片", "科幻片", "動畫片", "纪录片"] {
            let value = input("阿索卡", category: category)
            XCTAssertEqual(value.type, .movie, category)
            XCTAssertNotNil(TMDBMatcher.automaticMatch([movie], input: value), category)
            XCTAssertNil(TMDBMatcher.automaticMatch([tv], input: value), category)
        }
    }

    func testTVBoxDecodedDetailRetainsAutomaticMatchEvidence() throws {
        let site = SiteConfiguration(key: "tvbox", name: "TVBox", type: 3, api: "https://example.invalid/spider")
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"list":[{"vod_id":"opaque-42","vod_name":"阿索卡","type_name":"欧美剧","vod_year":"2023","vod_play_from":"主线","vod_play_url":"第1集$opaque:one#第2集$opaque:two"}]}"#.utf8))
        let detail = try SpiderResponseMapper.detail(payload, site: site, baseURL: nil)
        let value = TMDBMatchInput(detail: detail)
        XCTAssertEqual(detail.summary.videoID, "opaque-42")
        XCTAssertEqual(detail.playSources[0].episodes[0].url, "opaque:one")
        XCTAssertNotNil(TMDBMatcher.automaticMatch([try candidate()], input: value))
    }

    func testXtreamStructuredFormOverridesUninformativeCategoryButNotConflicts() throws {
        func value(_ forms: [PlaybackContentForm], category: String = "4K | Drama") -> TMDBMatchInput {
            .init(detail: .init(summary: .init(siteKey: "xtream", siteName: "Xtream", videoID: "opaque", title: "阿索卡", year: "2023", categoryName: category),
                playSources: [.init(name: "Line", episodes: forms.enumerated().map {
                    .init(name: "Part \($0.offset)", url: "opaque:\($0.offset)", metadata: .init(form: $0.element))
                })]))
        }
        for (form, type) in [(PlaybackContentForm.movie, TMDBMediaType.movie), (.series, .tv)] {
            let input = value([form, form])
            XCTAssertEqual(input.type, type)
            XCTAssertNotNil(TMDBMatcher.automaticMatch([try candidate(type: type)], input: input))
        }
        for input in [value([.movie, .series]), value([.movie], category: "国产剧"), value([.series], category: "动作片")] {
            XCTAssertTrue(input.hasConflict)
            XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(), try candidate(2, type: .movie)], input: input))
        }
        XCTAssertNil(value([.unknown]).type)
    }

    func testCustomCategoryStillRequiresIndependentYearAndPrincipalCast() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: "1997", category: "精选 | 4K", actors: "黄日华、陈浩民")))
        for value in [input("天龙八部", year: "1997", category: "精选 | 4K"),
                      input("天龙八部", year: "2003", category: "精选 | 4K", actors: "黄日华、陈浩民"),
                      input("天龙八部", year: "1997", category: "国产剧/动作片", actors: "黄日华、陈浩民")] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: value))
        }
    }

    func testDiscoveryMetadataFillsOnlyMissingFieldsForSameProviderIdentity() throws {
        let summary = VideoSummary(siteKey: "site", siteName: "Site", videoID: "42", title: "阿索卡", year: "2023", categoryName: "欧美剧")
        var sparse = summary; sparse.year = " "; sparse.categoryName = nil
        let detail = VideoDetail(summary: sparse)
        let restored = TMDBMatchInput(detail: detail, fallbackSummary: summary)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([try candidate()], input: restored))
        for field in 0..<3 {
            var different = summary
            if field == 0 { different.videoID = "43" }
            if field == 1 { different.siteKey = "other" }
            if field == 2 { different.title = "另一部" }
            let value = TMDBMatchInput(detail: detail, fallbackSummary: different)
            XCTAssertNil(value.year); XCTAssertNil(value.type)
        }
        sparse.year = "2022"; sparse.categoryName = "电影"
        let authoritative = TMDBMatchInput(detail: .init(summary: sparse), fallbackSummary: summary)
        XCTAssertEqual(authoritative.year, 2022); XCTAssertEqual(authoritative.type, .movie)
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate()], input: authoritative))
    }

    func testChineseNormalizationPreservesSequelAndNumericTitles() {
        XCTAssertEqual(TMDBTitleNormalizer.clean("阿索卡 第一季 1080P 国语"), "阿索卡")
        XCTAssertEqual(TMDBTitleNormalizer.clean("某剧 S02 2023"), "某剧")
        for title in ["误杀2", "1917", "三体", "第九区", "四季", "四季情", "某电影 第二部"] { XCTAssertEqual(TMDBTitleNormalizer.clean(title), title) }
        XCTAssertTrue(PlaybackResourceAnalyzer.explicitSeasons(in: "四季情").isEmpty)
        XCTAssertTrue(TMDBTitleNormalizer.searchNames("阿索卡/Ahsoka").contains("阿索卡"))
        XCTAssertTrue(TMDBTitleNormalizer.searchNames("阿索卡（Ahsoka）").contains("Ahsoka"))
        XCTAssertEqual(TMDBTitleNormalizer.searchNames("Face/Off"), ["Face/Off"])
        XCTAssertEqual(TMDBTitleNormalizer.key("繁體 電視劇！"), TMDBTitleNormalizer.key("繁体电视剧"))
        XCTAssertEqual(PlaybackResourceAnalyzer.explicitSeasons(in: "某剧 第十二季"), [12])
        XCTAssertEqual(PlaybackResourceAnalyzer.explicitSeasons(in: "Show S02E03"), [2])
        XCTAssertTrue(PlaybackResourceAnalyzer.explicitSeasons(in: "误杀2").isEmpty)
    }

    func testStructuredLabelsRetainUnknownIdentityAndYearHints() throws {
        XCTAssertEqual(TMDBTitleNormalizer.clean("兰香如故（臻彩）"), "兰香如故")
        let parsed = TMDBParsedTitle("兰香如故【4K·国语·中字】（2026）")
        XCTAssertEqual(parsed.workTitle, "兰香如故"); XCTAssertEqual(parsed.years, [2026])
        XCTAssertEqual(Set(parsed.labels), ["4K", "国语", "中字"])
        XCTAssertEqual(TMDBTitleNormalizer.clean("某剧（4K·未知副标题）"), "某剧(未知副标题)")
        let plain = try candidate(title: "某剧")
        XCTAssertNil(TMDBMatcher.automaticMatch([plain], input: input("某剧（4K·未知副标题）")))
        XCTAssertEqual(input("某剧（2023）", year: nil).year, 2023)
        XCTAssertNil(TMDBMatcher.automaticMatch([plain], input: input("某剧（2022）", year: "2023")))
        let show = try candidate(title: "某剧", year: "2024", extra: #", "seasons":[{"season_number":2,"air_date":"2026-01-01","episode_count":8}]"#)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([show], input: input("某剧（第二季）（2026）", year: "2024")))
        XCTAssertNil(TMDBMatcher.automaticMatch([plain], input: input("某剧（电影版）")))
        for title in ["1917", "2001太空漫游", "某片2"] { XCTAssertEqual(TMDBTitleNormalizer.clean(title), title) }
    }

    func testTechnicalWordInsideTitleAndNestedSubtitleRemainIdentityBearing() throws {
        XCTAssertEqual(TMDBParsedTitle("The 4K Journey").workTitle, "The 4K Journey")
        XCTAssertEqual(TMDBParsedTitle("某剧（未知副标题【4K】）").labels, ["4K"])
        XCTAssertFalse(TMDBParsedTitle("某剧（未知副标题【4K】）").unknown.isEmpty)
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(title: "某剧")], input: input("某剧（未知副标题【4K】）")))
    }

    func testCompleteLineRejectsDifferentNumberingButAllowsDuplicateVersionsAndExplicitParts() throws {
        let data = try JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": (1...47).map { ["id": $0, "episode_number": $0] }])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let season = try decoder.decode(TMDBSeason.self, from: data)
        func items(_ names: [String]) -> [PlayEpisode] { names.enumerated().map { .init(name: $0.element, url: "opaque:\($0.offset)") } }
        let duplicate = items((1...47).map { "第\($0)集" } + (1...47).map { "S01E\($0)" })
        XCTAssertEqual(TMDBEpisodeMapper.episodes(duplicate, category: nil, season: season).count, 94)
        XCTAssertTrue(TMDBEpisodeMapper.episodes(items((1...94).map { "第\($0)集" }), category: nil, season: season).isEmpty)
        let parts = items((1...47).flatMap { ["第\($0)集上", "第\($0)集下"] })
        let mapped = TMDBEpisodeMapper.episodes(parts, category: nil, season: season)
        XCTAssertEqual(mapped.count, 94); XCTAssertEqual(mapped[0]?.id, mapped[1]?.id)
        let mixed = items(["第1～2集合并", "花絮 第1集", "预告", "第3集", "第3集备用"])
        let safe = TMDBEpisodeMapper.episodes(mixed, category: nil, season: season)
        XCTAssertEqual(Set(safe.keys), [3, 4])
        XCTAssertEqual(TMDBEpisodeMapper.episodes(items(["S01E01", "S02E02"]), category: nil, season: season).count, 1)
    }

    func testExactTypedYearMatchAndRegionalAlias() throws {
        let value = try candidate(title: "另一地区译名", extra: #", "alternative_titles":{"results":[{"title":"阿索卡"}]}"#)
        XCTAssertEqual(TMDBMatcher.automaticMatch([value], input: input("阿索卡 第一季"))?.reference.id, 1)
    }

    func testSameNameRemakesAreSelectedByYearNeverResultOrder() throws {
        let old = try candidate(1, title: "同名作品", year: "1990", type: .movie)
        let new = try candidate(2, title: "同名作品", year: "2023", type: .movie)
        XCTAssertEqual(TMDBMatcher.automaticMatch([old, new], input: input("同名作品", category: "电影"))?.reference.id, 2)
        XCTAssertNil(TMDBMatcher.automaticMatch([old, new], input: input("同名作品", year: nil, category: "电影")))
    }

    func testSameTitleYearIsAmbiguousAndMissingYearRivalStillBlocks() throws {
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(1), try candidate(2)], input: input("阿索卡")))
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(1), try candidate(2, year: nil)], input: input("阿索卡")))
    }

    func testUnknownTypeWrongTypeNearYearAndSequelAreNotAutoMatched() throws {
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate()], input: input("阿索卡", category: nil)))
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(type: .movie)], input: input("阿索卡")))
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(year: "2022")], input: input("阿索卡")))
        XCTAssertNil(TMDBMatcher.automaticMatch([try candidate(title: "误杀", type: .movie)], input: input("误杀2", category: "电影")))
    }

    func testConflictingDirectorCannotBeAutoAccepted() throws {
        let work = try candidate(type: .movie, extra: #", "credits":{"crew":[{"id":10,"name":"另一位导演","job":"Director"}]}"#)
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("阿索卡", category: "电影", director: "原片导演")))
    }

    private var matchingCast: String { #", "credits":{"cast":[{"id":10,"name":"黃日華"},{"id":11,"name":"陈浩民"},{"id":12,"name":"樊少皇"}]}"# }

    func testAttachedChineseYearNeedsIndependentYearAndCast() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        let evidence = input("天龙八部1997", year: "1997", actors: "黄日华、陈浩民、樊少皇")
        XCTAssertEqual(evidence.titleWithoutAttachedYear, "天龙八部")
        XCTAssertEqual(evidence.searchNames, ["天龙八部", "天龙八部1997"])
        XCTAssertEqual(TMDBMatcher.automaticMatch([work], input: evidence)?.reference.id, 1)
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部1997", year: "1997")))
        for (title, year) in [("1917", "1917"), ("2012", "2012"), ("误杀2", "2021"), ("银翼杀手2049", "2017"), ("天龙八部1997", "2003")] {
            XCTAssertNil(input(title, year: year).titleWithoutAttachedYear)
        }
        XCTAssertNil(input("天龙八部1997", year: nil).titleWithoutAttachedYear)
    }

    func testUnknownTypeNeedsTwoDistinctPrincipalActorsIncludingALead() throws {
        let work = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: "1997", category: nil, actors: "黄日华 / 陈浩民")))
        for actors in [nil, "黄日华", "黄日华、黄日华", "甲演员、乙演员、丙演员、黄日华、陈浩民"] as [String?] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: "1997", category: nil, director: "陈浩民", actors: actors)))
        }
        let duplicate = try candidate(title: "天龙八部", year: "1997", extra: #", "credits":{"cast":[{"id":10,"name":"黄日华"},{"id":10,"name":"陈浩民"}]}"#)
        XCTAssertNil(TMDBMatcher.automaticMatch([duplicate], input: input("天龙八部", year: "1997", category: nil, actors: "黄日华、陈浩民")))
        for category in ["电影", "音乐", "电影电视剧"] {
            XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("天龙八部", year: "1997", category: category, actors: "黄日华、陈浩民")))
        }
    }

    func testCorroboratedCastNeverOverridesYearTypeOrSameTitleRivals() throws {
        let winner = try candidate(title: "天龙八部", year: "1997", extra: matchingCast)
        let source = input("天龙八部1997", year: "1997", category: nil, actors: "黄日华、陈浩民")
        for rival in [try candidate(2, title: "天龙八部", year: "1997"),
                      try candidate(3, title: "天龙八部", year: nil),
                      try candidate(4, title: "天龙八部", year: "1997", type: .movie, extra: matchingCast),
                      try candidate(5, title: "天龙八部1997", year: "1997", extra: matchingCast)] {
            XCTAssertNil(TMDBMatcher.automaticMatch([winner, rival], input: source))
            XCTAssertNil(TMDBMatcher.automaticMatch([rival, winner], input: source))
        }
        XCTAssertNil(TMDBMatcher.automaticMatch([winner], input: input("天龙八部", year: "2003", category: nil, actors: "黄日华、陈浩民")))
        XCTAssertNotNil(TMDBMatcher.automaticMatch([winner], input: input("天龙八部", year: nil, category: nil, actors: "黄日华、陈浩民")))
        let sequel = input("天龙八部2", year: "1997", category: nil, actors: "黄日华、陈浩民")
        XCTAssertNil(TMDBMatcher.automaticMatch([winner], input: sequel))
    }

    func testSeasonYearIsNotFirstAirYearAndMissingSeasonRejects() throws {
        let work = try candidate(title: "某剧", year: "2016", extra: #", "seasons":[{"season_number":1,"air_date":"2016-01-01","episode_count":8},{"season_number":4,"air_date":"2022-01-01","episode_count":9}]"#)
        XCTAssertNotNil(TMDBMatcher.automaticMatch([work], input: input("某剧 第四季", year: "2022")))
        XCTAssertNil(TMDBMatcher.automaticMatch([work], input: input("某剧 第五季", year: "2022")))
    }

    func testSingleAndSpecifiedSeasonDoNotDependOnAllResourcesBeingClean() throws {
        let work = try candidate(extra: #", "seasons":[{"season_number":0,"episode_count":1},{"season_number":1,"episode_count":3}]"#).work
        let source = PlaySource(name: "Line", episodes: [.init(name: "S09E01", url: "opaque:bad"), .init(name: "01.mp4", url: "opaque:good")])
        XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: nil), 1)
        XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: source), 1)
        let mapped = TMDBEpisodeMapper.episodes(source.episodes, category: nil, season: try season(1))
        XCTAssertNil(mapped[0]); XCTAssertEqual(mapped[1]?.episodeNumber, 1)
        let specials = PlaySource(name: "Line", episodes: [.init(name: "01", url: "main"), .init(name: "SP S00E01", url: "special")])
        XCTAssertEqual(TMDBEpisodeMapper.seasonNumbers(work: work, input: input("阿索卡"), source: specials), [1,0])
        let multi = try candidate(extra: #", "seasons":[{"season_number":1,"episode_count":3},{"season_number":2,"episode_count":0}]"#).work
        XCTAssertNil(TMDBEpisodeMapper.season(work: multi, input: input("阿索卡"), source: nil))
        XCTAssertEqual(TMDBEpisodeMapper.season(work: multi, input: input("阿索卡 第二季"), source: source), 2)
        let mixed = PlaySource(name: "Line", episodes: [.init(name: "S01E01", url: "a"), .init(name: "S02E01", url: "b"), .init(name: "01", url: "c")])
        XCTAssertEqual(TMDBEpisodeMapper.seasonNumbers(work: multi, input: input("阿索卡"), source: mixed), [1,2])
    }

    func testSeasonSelectionRequiresUniqueEvidenceNotEpisodeCount() throws {
        let work = try candidate(extra: #", "seasons":[{"season_number":0,"episode_count":2},{"season_number":1,"episode_count":8},{"season_number":2,"episode_count":8}]"#).work
        let source = PlaySource(name: "Line", episodes: (1...8).map { PlayEpisode(name: "第\($0)集", url: "opaque:\($0)") })
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: source))
        XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("阿索卡 第二季"), source: source), 2)
        XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: source, manual: 0), 0)
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: source, manual: 9))
    }

    func testSeasonReleaseYearResolvesGroupedSequelsWithoutManualSelection() throws {
        let work = try candidate(title: "琅琊榜", year: "2015", extra: #", "seasons":[{"season_number":1,"air_date":"2015-09-19","episode_count":54},{"season_number":2,"air_date":"2017-12-18","episode_count":50}]"#).work
        let episodes = (1...54).map { PlayEpisode(name: "第\($0)集", url: "opaque:\($0)") }
        let source = PlaySource(name: "线路一", episodes: episodes)
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("琅琊榜", year: "2015"), source: source))
        let sequel = PlaySource(name: "线路一", episodes: Array(episodes.prefix(50)))
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("琅琊榜", year: "2017"), source: sequel))
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("琅琊榜", year: "2017"), source: source), "54 numbered episodes cannot belong to the 50-episode season")
        XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("琅琊榜（2017）", year: "2015"), source: source))
        XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("琅琊榜", year: "2015"), source: source, manual: 2), 2)
        XCTAssertEqual(source.episodes, episodes, "Metadata matching must preserve source episodes and URLs")
    }

    func testSeasonYearDoesNotGuessAcrossAmbiguousOrUndatedSeasons() throws {
        for seasons in [
            #"[{"season_number":1,"air_date":"2023-01-01","episode_count":8},{"season_number":2,"air_date":"2023-10-01","episode_count":8}]"#,
            #"[{"season_number":1,"air_date":"2023-01-01","episode_count":8},{"season_number":2,"episode_count":8}]"#
        ] {
            let work = try candidate(extra: ", \"seasons\":\(seasons)").work
            XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: nil))
            let explicit = PlaySource(name: "第二季", episodes: [.init(name: "第1集", url: "opaque:1")])
            XCTAssertEqual(TMDBEpisodeMapper.season(work: work, input: input("阿索卡"), source: explicit), 2)
            XCTAssertNil(TMDBEpisodeMapper.season(work: work, input: input("阿索卡 第一季"), source: explicit))
        }
    }

    func testQualitySuffixedNumericLineReusesVerifiedSeasonWhileUpdating() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": (1...39).map {
            ["id": $0 + 100, "episode_number": $0, "still_path": "/\($0).jpg"] as [String: Any]
        }])
        let season = try decoder.decode(TMDBSeason.self, from: data)
        let quark = (1...39).map { PlayEpisode(name: String(format: "%02d 4K", $0), url: "quark:\($0)") }
        let baidu = (1...39).map { PlayEpisode(name: "第\($0)集", url: "baidu:\($0)") }
        let a = TMDBEpisodeMapper.episodes(quark, category: "电视剧", season: season)
        let b = TMDBEpisodeMapper.episodes(baidu, category: "电视剧", season: season)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 39)
        let filenames = quark.map { PlayEpisode(name: "[1002.9MB]" + $0.name + ".mp4【【国剧】向风而行.全39集.国语中字.2022.4K】", url: $0.url) }
        XCTAssertEqual(TMDBEpisodeMapper.episodes(filenames, category: nil, season: season), b, "Captured provider filename wrappers must reuse the same artwork")
        XCTAssertEqual(quark[0].name, "01 4K"); XCTAssertEqual(quark[0].url, "quark:1")
        XCTAssertEqual(TMDBEpisodeMapper.episodes(Array(quark.dropLast()), category: "电视剧", season: season).count, 38)
        for label in ["01 上", "01-02 4K", "01 4K 预告", "2024 4K", "01 花絮", "01 4K导演版", "01 4K.mp4【预告】", "01 4K.mp4【S02】"] {
            var unsafe = quark; unsafe[0].name = label
            XCTAssertNil(TMDBEpisodeMapper.episodes(unsafe, category: "电视剧", season: season)[0], label)
            XCTAssertEqual(TMDBEpisodeMapper.episodes(unsafe, category: "电视剧", season: season).count, 38, label)
        }
        var duplicate = quark; duplicate[1].name = "01 1080P"
        XCTAssertEqual(TMDBEpisodeMapper.episodes(duplicate, category: "电视剧", season: season).count, 39)
        XCTAssertTrue(TMDBEpisodeMapper.episodes(quark, category: "电影", season: season).isEmpty)
    }

    func testCompleteNumericSeasonCanAttachArtworkWithoutPromotingPlaybackIdentity() throws {
        let data = try JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": (1...54).map {
            ["id": $0 + 100, "episode_number": $0, "still_path": "/\($0).jpg"] as [String: Any]
        }])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let season = try decoder.decode(TMDBSeason.self, from: data)
        let sources = (1...54).reversed().map { PlayEpisode(name: String($0), url: "opaque:\($0)") }
        let mapped = TMDBEpisodeMapper.episodes(sources, category: nil, season: season)
        XCTAssertEqual(mapped.count, 54)
        XCTAssertEqual(mapped[0]?.episodeNumber, 54, "Map by the source label, never its array position")
        XCTAssertEqual(mapped[53]?.stillPath, "/1.jpg")
        XCTAssertFalse(PlaybackResourceAnalyzer.analyze(sources[0], categoryName: "电视剧").hasReliableEpisode)
        XCTAssertNotNil(TMDBEpisodeMapper.episode(sources[0], category: "电视剧", season: season))
        XCTAssertEqual(TMDBEpisodeMapper.episodes(Array(sources.dropLast()), category: "电视剧", season: season).count, 53)
        for invalid in [sources + [sources[0]],
                        sources.dropLast().map { $0 } + [.init(name: "55", url: "opaque:55")],
                        sources.dropLast().map { $0 } + [.init(name: "预告", url: "opaque:bonus")]] {
            XCTAssertGreaterThanOrEqual(TMDBEpisodeMapper.episodes(invalid, category: "电视剧", season: season).count, 53)
        }
        XCTAssertTrue(TMDBEpisodeMapper.episodes(sources, category: "电影", season: season).isEmpty)
        XCTAssertTrue(TMDBEpisodeMapper.episodes(sources, category: "综艺", season: season).isEmpty)
    }

    func testOngoingNumericLineMapsExistingEpisodesByNumberWithoutRequiringFutureUploads() throws {
        // 蒸蒸日上: the provider has 16 uploads, while TMDB already lists 22.
        let data = try JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": (1...22).map {
            ["id": $0 + 100, "episode_number": $0, "name": "分集剧情\($0)", "still_path": "/\($0).jpg"] as [String: Any]
        }])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let season = try decoder.decode(TMDBSeason.self, from: data)
        func items(_ numbers: [Int], suffix: String = "4K") -> [PlayEpisode] {
            numbers.map { .init(name: String(format: "%02d %@", $0, suffix), url: "opaque:\($0)") }
        }
        // Captured filename shape includes mixed spaces/underscores and a provider wrapper.
        let source = (1...16).map { number in
            PlayEpisode(name: String(format: "[1.1GB]%02d%@4K.mp4【Z‑蒸‑Z‑日‑S/4K】", number, (5...12).contains(number) ? "_" : " "), url: "opaque:\(number)")
        }
        let mapping = TMDBEpisodeMapper.episodes(source, category: nil, season: season)
        XCTAssertEqual(mapping.count, 16)
        XCTAssertEqual(mapping[0]?.stillPath, "/1.jpg")
        XCTAssertEqual(mapping[15]?.stillPath, "/16.jpg")
        XCTAssertEqual(mapping[0]?.name, "分集剧情1")
        XCTAssertNil(mapping[16], "Unreleased uploads must not become playable cards")
        let reversedWithGap = items([16, 8, 3, 2, 1])
        let reordered = TMDBEpisodeMapper.episodes(reversedWithGap, category: "电视剧", season: season)
        XCTAssertEqual(reordered[0]?.episodeNumber, 16)
        XCTAssertEqual(reordered[4]?.episodeNumber, 1)
        XCTAssertEqual(TMDBEpisodeMapper.episodes(items(Array(1...16), suffix: "1080P"), category: nil, season: season), mapping)
        for invalid in [items([1, 3, 5]), items([1, 2]), items([1, 2, 3, 23]), items([1, 2, 3, 3])] {
            XCTAssertEqual(TMDBEpisodeMapper.episodes(invalid, category: nil, season: season).count, invalid.filter { Int(PlaybackResourceAnalyzer.compactName($0.name).prefix(while: { $0.isNumber })) ?? 999 <= 22 }.count)
        }
        XCTAssertEqual(source[0].name, "[1.1GB]01 4K.mp4【Z‑蒸‑Z‑日‑S/4K】"); XCTAssertEqual(source[0].url, "opaque:1")
        XCTAssertFalse(PlaybackResourceAnalyzer.analyze(source[0], categoryName: "电视剧").hasReliableEpisode)
        XCTAssertNotNil(TMDBEpisodeMapper.episode(source[0], category: "电视剧", season: season))
    }

    func testEpisodeMappingUsesNumberAndPreservesGapsAndVersions() throws {
        let season = try season()
        for name in ["S02E03", "第二季 第三集", "第3集 国语", "第3集 粤语"] {
            XCTAssertEqual(TMDBEpisodeMapper.episode(.init(name: name, url: "opaque:\(name)"), category: "电视剧", season: season)?.id, 203)
        }
        XCTAssertEqual(TMDBEpisodeMapper.episode(.init(name: "第1集", url: "opaque:1"), category: "电视剧", season: season)?.id, 201)
        XCTAssertNil(TMDBEpisodeMapper.episode(.init(name: "第2集", url: "opaque:2"), category: "电视剧", season: season))
    }

    func testNoAutomaticMappingForBareNumbersPartsRangesBonusOrWrongSeason() throws {
        for name in [ "第3集 上集", "第1-3集", "花絮 第3集", "第3期", "S01E03", "S02E03 S02E04", "2023-01-03"] {
            XCTAssertNil(TMDBEpisodeMapper.episode(.init(name: name, url: "opaque:resource"), category: "电视剧", season: try season()), name)
        }
        XCTAssertEqual(TMDBEpisodeMapper.episode(.init(name: "SP S00E03", url: "opaque:special"), category: "电视剧", season: try season(0))?.id, 203)
    }
}
