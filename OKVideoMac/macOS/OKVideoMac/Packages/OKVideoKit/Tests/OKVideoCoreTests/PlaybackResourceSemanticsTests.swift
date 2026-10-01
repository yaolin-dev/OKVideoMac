import XCTest
@testable import OKVideoCore

final class PlaybackResourceSemanticsTests: XCTestCase {
    private func namedFiles(_ numbers: [Int], stem: String = "ZIYA", suffix: String = ".mkv") -> [PlayEpisode] {
        numbers.enumerated().map { index, number in
            PlayEpisode(name: "[4.\(90 + index)GB] \(stem) \(number)\(suffix)", url: "fixture:\(stem):\(index)")
        }
    }

    func testNamedVideoSequenceProvidesOnlyLocalEpisodeContext() {
        let episodes = namedFiles([23, 21, 22])
        for category in [nil, "剧情 爱情 古装", "电视剧"] as [String?] {
            let values = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: category)
            XCTAssertEqual(values.map(\.episode), [23, 21, 22])
            XCTAssertTrue(values.allSatisfy { $0.form == .series && $0.evidence == .contextual })
            XCTAssertTrue(values.allSatisfy { !$0.hasReliableEpisode && $0.season == nil })
            XCTAssertNil(PlaybackResourceAnalyzer.trustedEpisode(episodes[2], categoryName: category))
        }
    }

    func testNamedVideoSequenceRejectsInsufficientOrAmbiguousEvidence() {
        let rejected = [
            namedFiles([22]), namedFiles([21, 22]), namedFiles([21, 23, 25]),
            namedFiles([21, 22, 22, 23]), namedFiles([2024, 2025, 2026]),
            namedFiles([21, 22, 23], suffix: ".mp3"),
            namedFiles([21, 22, 23], stem: "ZIYA 花絮"),
            namedFiles([21, 22, 23], stem: "Movie Part"),
            (21...23).map { PlayEpisode(name: "ZIYA \($0)", url: "fixture:\($0)") }
        ]
        for episodes in rejected {
            XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(episodes).allSatisfy { $0.episode == nil }, episodes.map(\.name).description)
        }
        XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(namedFiles([21, 22, 23]), categoryName: "电影").allSatisfy { $0.episode == nil })
        XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(namedFiles([21, 22, 23]), categoryName: "综艺").allSatisfy { $0.episode == nil })
    }

    func testNumberedVideoNamingVariantsAndMissingUploads() {
        for names in [
            ["ZIYA021.mkv", "新前缀_022.mp4", "023 不同后缀.webm"],
            ["[4.9GB] ZIYA 21", "22 [4.8GB]", "[4.7GB] NEW 23"],
            ["Show.2026.021.1080p.H265.mkv", "Other.2026.022.1080p.H264.mkv", "023.1080p.60fps.10bit.mp4"],
            ["ZIYA ２１.mkv", "NEW ２２.mp4【全38集】", "第三个 ２３.mkv"],
            ["ZIYA%2021.mkv", "OTHER%2022.mkv", "23.mkv"],
            ["21.mkv", "22.mkv", "23.mkv", "25.mkv", "28.mkv"]
        ] {
            let episodes = names.map { PlayEpisode(name: $0, url: "fixture:\($0)") }
            let expected = names.count == 5 ? [21, 22, 23, 25, 28] : [21, 22, 23]
            XCTAssertEqual(PlaybackResourceAnalyzer.analyzeList(episodes).compactMap(\.episode), expected, names.description)
        }
    }

    func testKnownSeriesCanUseShortListsAndTitlesWithoutExtensions() {
        let episodes = ["ZIYA22", "另一个前缀 23"].map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        XCTAssertEqual(PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: "电视剧").map(\.episode), [22, 23])
        XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(episodes).allSatisfy { $0.episode == nil })
        XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: "电影").allSatisfy { $0.episode == nil })
    }

    func testNumericNoiseCannotSupplyAnEpisodeSequence() {
        for names in [
            ["Movie.5.1.mkv", "Movie.6.1.mkv", "Movie.7.1.mkv"],
            ["Movie.2024.mkv", "Movie.2025.mkv", "Movie.2026.mkv"],
            ["Show.21-22.mkv", "Show.22-23.mkv", "Show.23-24.mkv"],
            ["20260921.mkv", "20260922.mkv", "20260923.mkv"],
            ["1080p.mkv", "720p.mkv", "2160p.mkv"],
            ["ZIYA21.mp3", "ZIYA22.mp3", "ZIYA23.mp3"],
            ["ZIYA21.srt", "ZIYA22.srt", "ZIYA23.srt"]
        ] {
            let episodes = names.map { PlayEpisode(name: $0, url: "fixture:\($0)") }
            XCTAssertTrue(PlaybackResourceAnalyzer.analyzeList(episodes).allSatisfy { $0.episode == nil }, names.description)
        }
    }

    func testVideoSequenceCanChangePrefixesAndMixNumericAndExplicitNames() {
        let episodes = ["[4.9GB] ZIYA 21.mkv", "[4.8GB] NEW 22.mkv", "[4.7GB] 23.mkv", "[4.6GB] EP24.mkv"]
            .map { PlayEpisode(name: $0, url: "fixture:\($0)") }
        for category in [nil, "剧情 爱情 古装", "电视剧"] as [String?] {
            let values = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: category)
            XCTAssertEqual(values.map(\.episode), [21, 22, 23, 24])
            XCTAssertFalse(values[1].hasReliableEpisode)
            XCTAssertTrue(values[3].hasReliableEpisode)
        }
    }

    func testNamedVideoSequenceExcludesAudioAndKeepsVersionsSeparate() {
        let episodes = namedFiles([21, 22, 23], suffix: "_4K.mkv")
            + namedFiles([21, 22, 23], suffix: "_1080p.mkv")
            + namedFiles([21, 22, 23], suffix: ".mp3")
        let values = PlaybackResourceAnalyzer.analyzeList(episodes)
        XCTAssertEqual(values.map(\.episode), [21, 22, 23, 21, 22, 23, nil, nil, nil])
        XCTAssertEqual(values[0].versionLabels, ["4K"])
        XCTAssertEqual(values[3].versionLabels, ["1080p"])
    }

    private func parse(_ name: String, _ category: String? = nil) -> PlaybackResourceSemantics {
        PlaybackResourceAnalyzer.analyze(PlayEpisode(name: name, url: "fixture:media"), categoryName: category)
    }
    func testWeakNumericTokensNeverCreateUnknownEpisodes() {
        for name in ["求救信号.4.mkv", "求救信号.7.mkv", "Movie.5.1.mkv", "Movie.7.1.mkv",
                     "Movie Part 1.mkv", "Movie Part 2.mkv", "Movie.2025.mkv", "Movie.2026.mkv",
                     "Show.1080p.H.264.10bit.60fps.mkv", "4.7GB.mkv", "01.mp4", "02.mp4"] {
            XCTAssertNil(parse(name).episode, name)
            XCTAssertNil(parse(name, "动作 喜剧").episode, name)
        }
    }
    func testExplicitMarkersWinOverFollowingSequences() {
        for (name, expected) in [("Show.EP05.1.mkv",5),("Show.EP08.2.mkv",8),("Show.EP10.3.mkv",10),
                                 ("EP720.1080p.mkv",720),("第５集",5),("第五集",5),("第两百零三话",203)] {
            XCTAssertEqual(parse(name).episode, expected, name)
            XCTAssertTrue(parse(name).hasReliableEpisode, name)
        }
    }
    func testSeasonRangeIsNotSingleEpisodeIdentity() {
        let value = parse("S01E01-E02.mkv")
        XCTAssertEqual(value.season, 1); XCTAssertEqual(value.episode, 1); XCTAssertEqual(value.endEpisode, 2)
        XCTAssertFalse(value.hasReliableEpisode)
        XCTAssertEqual(parse("第十一至十二集").endEpisode, 12)
        XCTAssertEqual(parse("S02E105.mkv").season, 2)
    }
    func testConflictingExplicitMarkersRemainUncertain() {
        XCTAssertEqual(parse("S01E05 EP08.mkv").evidence, .conflict)
        XCTAssertNil(parse("S01E05 EP08.mkv").episode)
        XCTAssertEqual(parse("E10-E02").evidence, .conflict)
    }
    func testDatesAreWholeValidatedTokens() {
        XCTAssertEqual(parse("20260925", "综艺").date, "2026-09-25")
        XCTAssertEqual(parse("20260926", "综艺").date, "2026-09-26")
        XCTAssertNil(parse("20260925").episode)
        XCTAssertNil(parse("20260230").date)
        XCTAssertNil(parse("1202609258").date)
        XCTAssertEqual(parse("第十三期", "综艺").issue, 13)
    }
    func testMovieContextPreventsIncidentalEpisodeMarkers() {
        XCTAssertNil(parse("Movie.4.mkv", "电影").episode)
        XCTAssertNil(parse("Movie.EP04.mkv", "电影").episode)
        XCTAssertEqual(parse("电影.4.mkv", "电影 电视剧").form, .unknown)
        XCTAssertEqual(parse("国语.2160p.HDR.杜比视界.mkv", "电影").versionLabels, ["国语","4K","HDR","杜比视界"])
    }
    func testFinaleDoesNotLoseEpisodeAndBonusRetainsRole() {
        let finale = parse("第 20 集 大结局", "电视剧")
        XCTAssertEqual(finale.episode, 20); XCTAssertTrue(finale.hasReliableEpisode); XCTAssertTrue(finale.finale)
        let bonus = parse("S01E14 特别篇.mkv")
        XCTAssertEqual(bonus.role, .bonus); XCTAssertFalse(bonus.hasReliableEpisode)
        XCTAssertEqual(parse("Movie Part 1.mkv").role, .part)
    }
    func testUnknownSingleItemKeepsNameAndKnownSeriesNumericIsDisplayOnly() {
        XCTAssertEqual(parse("Mader - Kitchen 1.mp4").name, "Mader - Kitchen 1")
        XCTAssertNil(parse("Mader - Kitchen 1.mp4").episode)
        let known = parse("01.mp4", "电视剧")
        XCTAssertEqual(known.episode, 1); XCTAssertFalse(known.hasReliableEpisode)
        XCTAssertNil(parse("Show.2026.1080p.4.mkv", "电视剧").episode)
    }
    func testFolderDescriptionAndURLCredentialsDoNotSupplyEpisodeNumber() {
        XCTAssertEqual(parse("S01E05.mkv【节目/全30集】").episode, 5)
        XCTAssertNil(parse("Movie.mp4【全集30集】").episode)
        XCTAssertNil(parse("https://example.invalid/Movie.mp4?episode=5").episode)
        XCTAssertEqual(parse("https://example.invalid/Movie.mp4?episode=5").name, "Movie")
    }
    func testStructuredMetadataDoesNotChangeIdentityAndRoundTrips() throws {
        let original = PlayEpisode(name: "Episode title", url: "fixture:media", referenceIdentity: "stable")
        var tagged = original
        tagged.metadata = .init(form: .series, season: 2, episode: 7)
        XCTAssertEqual(tagged.id, original.id); XCTAssertEqual(tagged.stableIdentity, original.stableIdentity)
        let value = PlaybackResourceAnalyzer.analyze(tagged)
        XCTAssertEqual(value.episode, 7); XCTAssertEqual(value.season, 2); XCTAssertTrue(value.hasReliableEpisode)
        XCTAssertEqual(try JSONDecoder().decode(PlayEpisode.self, from: JSONEncoder().encode(tagged)), tagged)
        let legacy = try JSONDecoder().decode(PlayEpisode.self, from: Data(#"{"name":"01.mp4","url":"fixture:media"}"#.utf8))
        XCTAssertNil(legacy.metadata)
    }
    func testChineseSeasonAndRedundantExplicitMarkersAgree() {
        for name in ["第二季 第五集", "S02E05 EP05", "S02E05 第5集"] {
            let value = PlaybackResourceAnalyzer.analyze(.init(name: name, url: "fixture"))
            XCTAssertEqual(value.season, 2)
            XCTAssertEqual(value.episode, 5)
            XCTAssertTrue(value.hasReliableEpisode)
        }
        XCTAssertNil(PlaybackResourceAnalyzer.analyze(.init(name: "共三十集", url: "fixture")).episode)
        XCTAssertNil(PlaybackResourceAnalyzer.analyze(.init(name: "全三十集", url: "fixture")).episode)
        XCTAssertEqual(PlaybackResourceAnalyzer.analyze(.init(name: "[1080p]Movie.mkv", url: "fixture"), categoryName: "电影").versionLabels, ["1080p"])
    }

    func testPartSlashIsNotAPathAndURLQueryCannotSupplyVersion() {
        let part = PlaybackResourceAnalyzer.analyze(.init(name: "Movie Part 1/2.mp4", url: "fixture"))
        XCTAssertEqual(part.name, "Movie Part 1/2")
        XCTAssertEqual(part.role, .part)
        XCTAssertNil(part.episode)
        let remote = PlaybackResourceAnalyzer.analyze(.init(name: "https://example.invalid/Movie.mp4?quality=4K&episode=5", url: "fixture"))
        XCTAssertEqual(remote.name, "Movie")
        XCTAssertTrue(remote.versionLabels.isEmpty)
        XCTAssertNil(remote.episode)
    }

    func testTechnicalNumericNamesRequireContextAndKeepSeasonIndependent() {
        for (name, number) in [("[1.50GB] 4KSDR 10.mkv", 10), ("34 [2.06GB]", 34), ("4KHDR 2", 2)] {
            XCTAssertNil(parse(name).episode)
            let value = parse(name, "电视剧")
            XCTAssertEqual(value.episode, number)
            XCTAssertNil(value.season)
            XCTAssertEqual(value.evidence, .contextual)
            XCTAssertFalse(value.hasReliableEpisode)
        }
        XCTAssertEqual(parse("4KSDR 10").versionLabels, ["4K", "SDR"])
        for name in ["4K 5.1", "4K 2026", "Part 2", "4K 10 11", "Movie 4"] {
            XCTAssertNil(parse(name, "电视剧").episode)
        }
    }
    func testListInferenceNeedsMultipleOverlappingExplicitAnchors() {
        let weak = (1...10).map { PlayEpisode(name: "4KSDR \($0)", url: "weak:\($0)") }
        let anchors = [2, 5].map { PlayEpisode(name: "S01E\($0).4KHDR", url: "strong:\($0)") }
        let inferred = PlaybackResourceAnalyzer.analyzeList(weak + anchors, categoryName: "剧情 爱情 古装")
        XCTAssertEqual(inferred[9].episode, 10)
        XCTAssertNil(inferred[9].season)
        XCTAssertFalse(inferred[9].hasReliableEpisode)
        XCTAssertNil(PlaybackResourceAnalyzer.analyzeList(weak + anchors.prefix(1))[0].episode)
        XCTAssertNil(PlaybackResourceAnalyzer.analyzeList(weak + anchors, categoryName: "电影")[0].episode)
        XCTAssertNil(PlaybackResourceAnalyzer.analyzeList(weak)[0].episode)
    }

}
