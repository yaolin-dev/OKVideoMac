import XCTest
import OKVideoCore
@testable import OKVideoMac

final class PlayerEpisodeNavigationTests: XCTestCase {
    private func episodes() -> [PlayEpisode] {
        (1...16).map { PlayEpisode(name: "[1.37GB]E\($0).mp4", url: "fixture:\($0)") }
            + [PlayEpisode(name: "[2.00GB]E16.mp4", url: "fixture:16-other")]
    }

    func testLaterDuplicateDoesNotBlockFourteenToFifteen() {
        let items = episodes()
        XCTAssertEqual(PlayerEpisodeAdvancePolicy.nextEpisode(in: items,
            currentEpisodeID: items[13].id, enabled: true,
            categoryName: "剧情 悬疑 犯罪")?.id, items[14].id)
    }

    func testDuplicateTargetStillCannotBeChosenAutomatically() {
        let items = episodes()
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: items,
            currentEpisodeID: items[14].id, enabled: true,
            categoryName: "剧情 悬疑 犯罪"))
    }
    func testAdjacentGroupsLocalizeAmbiguityInBothDirections() {
        let items = episodes() + [PlayEpisode(name: "E17.mp4", url: "fixture:17")]
        let index = PlayerEpisodeNavigationIndex(episodes: items)
        XCTAssertEqual(index.adjacent(to: items[13].id, offset: -1), .available(items[12]))
        XCTAssertEqual(index.adjacent(to: items[13].id, offset: 1), .available(items[14]))
        XCTAssertEqual(index.adjacent(to: items[14].id, offset: 1), .choice([items[15], items[16]]))
        XCTAssertEqual(index.adjacent(to: items[17].id, offset: -1), .choice([items[15], items[16]]))
        for current in [items[15], items[16]] {
            XCTAssertEqual(index.adjacent(to: current.id, offset: -1), .available(items[14]))
            XCTAssertEqual(index.adjacent(to: current.id, offset: 1), .available(items[17]))
        }
        XCTAssertEqual(index.adjacent(to: items[0].id, offset: -1), .boundary)
        XCTAssertEqual(index.adjacent(to: items[17].id, offset: 1), .boundary)
        XCTAssertEqual(index.adjacent(to: "missing", offset: 1), .unavailable)
        XCTAssertEqual(index.adjacent(to: items[13].id, offset: 2), .unavailable)
    }

    func testOrderDoesNotDependOnSourceSortingAndNeverSkipsAmbiguousTarget() {
        let items = episodes() + [PlayEpisode(name: "E18.mp4", url: "fixture:18")]
        for source in [items, Array(items.reversed()), Array(items.dropFirst(8)) + Array(items.prefix(8))] {
            let index = PlayerEpisodeNavigationIndex(episodes: source)
            XCTAssertEqual(index.adjacent(to: items[13].id, offset: 1), .available(items[14]))
            guard case .choice(let values) = index.adjacent(to: items[14].id, offset: 1) else {
                return XCTFail("Do not jump past the ambiguous E16 group to E18")
            }
            XCTAssertEqual(Set(values.map(\.id)), Set([items[15].id, items[16].id]))
        }
    }

    func testVersionsSeasonsAndMissingUploadsRetainExistingRules() {
        let items = ["S01E13.4KSDR", "S01E14.4KHDR", "S01E15.4KSDR", "S01E16.4KSDR", "S01E16.4KSDR", "S02E01.4KSDR"]
            .enumerated().map { PlayEpisode(name: $0.element, url: "fixture:\($0.offset)") }
        let index = PlayerEpisodeNavigationIndex(episodes: items)
        XCTAssertEqual(index.adjacent(to: items[0].id, offset: 1), .available(items[2]))
        XCTAssertEqual(index.adjacent(to: items[1].id, offset: 1), .boundary)
        XCTAssertEqual(index.adjacent(to: items[2].id, offset: 1), .choice([items[3], items[4]]))
        XCTAssertEqual(index.adjacent(to: items[3].id, offset: 1), .available(items[5]))
        let mixed = [PlayEpisode(name: "E14", url: "14"), PlayEpisode(name: "S01E15", url: "15")]
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: mixed).adjacent(to: mixed[0].id, offset: 1), .unavailable)
    }

    func testMovieUnknownExtrasAndMergedEpisodesCannotAcquireAutomaticTargets() {
        let names = ["E14.mp4", "E15.mp4", "E16 花絮.mp4", "E16.mp3", "E16.srt", "E16-E17.mp4", "E18.mp4"]
        let items = names.map { PlayEpisode(name: $0, url: $0) }
        let index = PlayerEpisodeNavigationIndex(episodes: items)
        XCTAssertEqual(index.adjacent(to: items[1].id, offset: 1), .available(items[6]))
        for excluded in items[2...5] { XCTAssertEqual(index.adjacent(to: excluded.id, offset: 1), .unavailable) }
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: items, categoryName: "电影").adjacent(to: items[0].id, offset: 1), .unavailable)
        let unknown = ["1", "2", "3"].map { PlayEpisode(name: $0, url: $0) }
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: unknown).adjacent(to: unknown[0].id, offset: 1), .unavailable)
    }

    func testLocalInferenceAndStrictWholeQueueContractRemainUnchanged() {
        let unique = (12...15).map { PlayEpisode(name: "[1.3GB] ZIYA \($0).mkv", url: "fixture:\($0)") }
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: unique).adjacent(to: unique[1].id, offset: 1), .available(unique[2]))
        XCTAssertNil(PlaybackResourceAnalyzer.trustedEpisode(unique[1]))
        XCTAssertTrue(PlayerEpisodeAdvancePolicy.orderedEpisodes(in: episodes()).isEmpty)
        XCTAssertNil(PlayerEpisodeAdvancePolicy.nextEpisode(in: episodes(), currentEpisodeID: episodes()[13].id, enabled: false))
    }

}

@MainActor
final class PlayerEpisodeNavigationStateTests: XCTestCase {
    private func items() -> [PlayEpisode] {
        ["E13.mp4", "E14.mp4", "E15.mp4", "[1GB]E16.mp4", "[2GB]E16.mp4"]
            .enumerated().map { PlayEpisode(name: $0.element, url: "fixture:\($0.offset)") }
    }

    func testButtonsAndManualChoiceUseSamePreparedSnapshot() async {
        let app = AppState(environment: nil), values = items()
        let source = PlaySource(name: "Line", episodes: values)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[1])
        XCTAssertTrue(app.hasPreviousEpisode)
        XCTAssertTrue(app.hasNextEpisode)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1, automatic: true), .available(values[2]))
        await app.seedEpisodeNavigationForTesting(source: source, current: values[2])
        XCTAssertTrue(app.hasNextEpisode, "Manual navigation can request a choice")
        XCTAssertNil(app.playerEpisodeNavigation(offset: 1, automatic: true).uniqueEpisode)
        XCTAssertNil(app.playerEpisodeNavigationChoice, "An automatic decision must not open a panel")
        await app.playAdjacentEpisode(offset: 1)
        XCTAssertEqual(app.playerEpisodeNavigationChoice?.episodes, Array(values.suffix(2)))
        XCTAssertEqual(Set(app.playerPanelEpisodePresentations.map(\.id)), Set(values.suffix(2).map(\.id)))
        app.dismissPlayerEpisodeNavigationChoice()
        XCTAssertEqual(app.playerPanelEpisodePresentations.count, 5)
    }

    func testSameCountSourceReplacementAndNewSessionInvalidateChoice() async {
        let app = AppState(environment: nil), values = items()
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "Line", episodes: values), current: values[2])
        await app.playAdjacentEpisode(offset: 1)
        XCTAssertNotNil(app.playerEpisodeNavigationChoice)
        let oldSession = app.playerEpisodeSelectionSessionID
        var replacement = values
        replacement[2] = PlayEpisode(name: "E15.mp4", url: "fixture:replacement")
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "Line", episodes: replacement), current: values[1])
        XCTAssertNil(app.playerEpisodeNavigationChoice)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(replacement[2]))
        XCTAssertEqual(app.playerEpisodePresentations.first(where: { $0.id == replacement[2].id })?.episode, replacement[2])
        await app.playPlayerEpisode(values[3], expectedSessionID: oldSession)
        XCTAssertEqual(app.currentPlayerEpisodeID, values[1].id)
    }

    func testPreparationAndCloseDoNotExposeStaleTargets() async {
        let app = AppState(environment: nil), values = items()
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "Line", episodes: values), current: values[2])
        await app.playAdjacentEpisode(offset: 1)
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "Other", episodes: values),
            current: values[1], videoID: "other", waitForPreparation: false)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .preparing)
        XCTAssertFalse(app.hasNextEpisode)
        XCTAssertNil(app.playerEpisodeNavigationChoice)
        await app.closePlayer()
        XCTAssertFalse(app.hasNextEpisode)
        XCTAssertNil(app.playerEpisodeNavigationChoice)
    }

    func testManualMovieResourcesRemainAvailableWithoutAutomaticContinuation() async {
        let app = AppState(environment: nil)
        let values = ["Movie.1080P", "Movie.4K"].map { PlayEpisode(name: $0, url: $0) }
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "Movie", episodes: values), current: values[0], category: "电影")
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(values[1]))
        XCTAssertNil(app.playerEpisodeNavigation(offset: 1, automatic: true).uniqueEpisode)
    }
}

@MainActor
final class PlayerMislabeledVideoNavigationTests: XCTestCase {
    private var motion: [String: String] {
        ["video-dec-params/w": "1920", "video-dec-params/h": "1080",
         "current-tracks/video/codec": "h264", "container-fps": "25",
         "current-tracks/video/image": "no", "current-tracks/video/albumart": "no"]
    }
    private func family() -> [PlayEpisode] {
        (1...16).map { PlayEpisode(name: "[\($0 == 11 ? "2.6" : "2.7")GB]E\($0).mp3【小程量房2026】", url: "fixture:\($0)") }
    }

    private func mixedFamily() -> [PlayEpisode] {
        (1...16).map { number in
            let size = number == 15 ? "1.5" : number == 16 ? "1.6" : "2.6"
            let suffix = number < 15 ? "mp3" : "mp4"
            return PlayEpisode(name: "[\(size)GB]E\(String(format: "%02d", number)).\(suffix)【小程量房2026】",
                               url: "fixture:mixed:\(number)")
        }
    }

    func testRealMixedSuffixLineReconnectsFromEitherSideAfterVideoDecodes() async {
        let values = mixedFamily(), app = AppState(environment: nil)
        let source = PlaySource(name: "夸克原画", episodes: values)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[14])
        XCTAssertFalse(app.hasPreviousEpisode, "A filename alone must not establish moving-video evidence")
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: -1), .available(values[13]), "E15.mp4 must reconnect to E14.mp3")
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(values[15]))

        for number in [1, 11, 13, 14, 15, 16] {
            await app.seedEpisodeNavigationForTesting(source: source, current: values[number - 1])
            app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
            XCTAssertEqual(app.playerEpisodeNavigation(offset: -1), number == 1 ? .boundary : .available(values[number - 2]))
            let next: PlayerEpisodeNavigationResult = number == 16 ? .boundary : .available(values[number])
            XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), next)
            XCTAssertEqual(app.playerEpisodeNavigation(offset: 1, automatic: true), next)
        }
        XCTAssertEqual(app.playerEpisodes, values)
    }

    func testMixedFamilyRequiresFreshVideoEvidenceAndPreservesExclusions() async {
        let values = mixedFamily(), app = AppState(environment: nil)
        let source = PlaySource(name: "夸克原画", episodes: values)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[14])
        let previousRequest = app.playbackPresentationID
        await app.seedEpisodeNavigationForTesting(source: source, current: values[14])
        app.observeEpisodeVideoForTesting(motion, requestID: previousRequest)
        XCTAssertFalse(app.hasPreviousEpisode)
        app.observeEpisodeVideoForTesting(motion.merging(["current-tracks/video/albumart": "yes"]) { _, new in new },
                                         requestID: app.playbackPresentationID)
        XCTAssertFalse(app.hasPreviousEpisode)
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertTrue(app.hasPreviousEpisode)
        await app.seedEpisodeNavigationForTesting(source: PlaySource(name: "另一线路", episodes: values), current: values[14])
        XCTAssertFalse(app.hasPreviousEpisode, "Evidence cannot cross sources or playback requests")

        let excluded = ["E17.mp3", "E17.mp3【其他节目】", "E17.mp3【小程量房2026】花絮",
                        "E17.srt【小程量房2026】", "E17.mp3【小程量房2026】国语", "S02E17.mp3【小程量房2026】"]
            .map { PlayEpisode(name: $0, url: "fixture:" + $0) }
        let index = PlayerEpisodeNavigationIndex(episodes: values + excluded, confirmedVideoEpisodeID: values[14].id)
        XCTAssertEqual(index.adjacent(to: values[14].id, offset: -1), .available(values[13]))
        XCTAssertEqual(index.adjacent(to: values[15].id, offset: 1), .boundary)
        for item in excluded { XCTAssertEqual(index.adjacent(to: item.id, offset: -1), .unavailable) }
        let sparse = Array(values[13...14])
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: sparse, confirmedVideoEpisodeID: values[14].id)
            .adjacent(to: values[14].id, offset: -1), .boundary, "Two mixed files alone must not infer an audio family")
    }

    func testRealFilenameBecomesNavigableOnlyAfterDecodedVideoEvidence() async {
        let values = family(), app = AppState(environment: nil)
        let source = PlaySource(name: "夸克原画", episodes: values)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[10])
        XCTAssertFalse(app.hasPreviousEpisode); XCTAssertFalse(app.hasNextEpisode)
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: -1), .available(values[9]))
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(values[11]))
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1, automatic: true), .available(values[11]))
        XCTAssertEqual(app.playerEpisodes, values, "Do not rename or change persistent source identities")
        XCTAssertEqual(app.playerEpisodePresentations.count, 16)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[0])
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertFalse(app.hasPreviousEpisode); XCTAssertTrue(app.hasNextEpisode)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[15])
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertTrue(app.hasPreviousEpisode); XCTAssertFalse(app.hasNextEpisode)
    }

    func testAudioCoverArtUnknownAndStaleRequestsCannotGrantVideoEvidence() async {
        let values = family(), app = AppState(environment: nil)
        let source = PlaySource(name: "line", episodes: values)
        for properties in [[String: String](), ["current-tracks/audio/codec": "mp3"],
                           motion.merging(["current-tracks/video/albumart": "yes"]) { _, new in new },
                           motion.merging(["current-tracks/video/image": "yes"]) { _, new in new }] {
            await app.seedEpisodeNavigationForTesting(source: source, current: values[10])
            app.observeEpisodeVideoForTesting(properties, requestID: app.playbackPresentationID)
            XCTAssertFalse(app.hasNextEpisode)
        }
        let oldRequest = app.playbackPresentationID
        await app.seedEpisodeNavigationForTesting(source: source, current: values[11])
        app.observeEpisodeVideoForTesting(motion, requestID: oldRequest)
        XCTAssertFalse(app.hasNextEpisode)
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertTrue(app.hasNextEpisode)
        await app.seedEpisodeNavigationForTesting(source: source, current: values[12])
        XCTAssertFalse(app.hasNextEpisode, "Each new resource must confirm its own media type")
        await app.closePlayer(); XCTAssertFalse(app.hasNextEpisode)
    }

    func testKnownVideoDoesNotAdmitSubtitlesBonusOrDifferentAudioFamilies() {
        let values = family() + [PlayEpisode(name: "E17.mp3", url: "unrelated"),
            PlayEpisode(name: "E17.mp3【小程量房2026】花絮", url: "bonus"),
            PlayEpisode(name: "E17.srt【小程量房2026】", url: "subtitle"),
            PlayEpisode(name: "E17.mp3【小程量房2026】国语", url: "other-version")]
        let index = PlayerEpisodeNavigationIndex(episodes: values, confirmedVideoEpisodeID: values[10].id)
        XCTAssertEqual(index.adjacent(to: values[15].id, offset: 1), .boundary)
        for excluded in values.suffix(4) { XCTAssertEqual(index.adjacent(to: excluded.id, offset: 1), .unavailable) }
        let subtitle = values[18]
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: values, confirmedVideoEpisodeID: subtitle.id)
            .adjacent(to: subtitle.id, offset: 1), .unavailable)
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: values, categoryName: "电影", confirmedVideoEpisodeID: values[10].id)
            .adjacent(to: values[10].id, offset: 1), .unavailable)
    }

    func testSingleMislabeledVideoAndDuplicateSiblingRetainNavigationRules() {
        let values = [PlayEpisode(name: "E10.mp4", url: "10"), family()[10], PlayEpisode(name: "E12.mp4", url: "12")]
        let index = PlayerEpisodeNavigationIndex(episodes: values, confirmedVideoEpisodeID: values[1].id)
        XCTAssertEqual(index.adjacent(to: values[1].id, offset: -1), .available(values[0]))
        XCTAssertEqual(index.adjacent(to: values[1].id, offset: 1), .available(values[2]))
        let duplicate = PlayEpisode(name: "[3GB]E12.mp3【小程量房2026】", url: "12-other")
        let group = family() + [duplicate]
        XCTAssertEqual(PlayerEpisodeNavigationIndex(episodes: group, confirmedVideoEpisodeID: group[10].id)
            .adjacent(to: group[10].id, offset: 1), .choice([group[11], duplicate]))
    }

    func testMediaInfoRetainsCoverFlagsWhenStatisticsAreRemoved() {
        XCTAssertTrue(PlaybackMediaInfo(properties: motion).hasDecodedMovingVideo)
        for flag in ["current-tracks/video/albumart", "current-tracks/video/image"] {
            let info = PlaybackMediaInfo(properties: motion.merging([flag: "yes"]) { _, new in new })
            XCTAssertFalse(info.hasDecodedMovingVideo)
            XCTAssertFalse(info.withoutStatistics.hasDecodedMovingVideo)
        }
    }
}
