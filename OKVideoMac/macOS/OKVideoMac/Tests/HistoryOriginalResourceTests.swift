import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class HistoryOriginalResourceTests: XCTestCase {
    func file(_ id: String = "file-13", name: String = "S01E13.mp4", path: String = "folder/S01E13.mp4") -> OriginalMediaResource {
        OriginalMediaResource(provider: "baidu", shareID: "share", ownerID: "owner", fileID: id,
            originalFilename: name, providerPath: path, byteSize: 1571407203, provenance: "wogg-baidu-detail")
    }
    func episode(_ id: String = "file-13", name: String = "S01E13.mp4") -> PlayEpisode {
        PlayEpisode(name: name, url: "NEW-TOKEN-\(id)", originalResource: file(id, name: name))
    }
    func detail(_ sources: [PlaySource]) -> VideoDetail {
        VideoDetail(summary: VideoSummary(siteKey: "fixture", siteName: "Fixture", videoID: "132964", title: "影片"), playSources: sources)
    }
    func history(original: OriginalMediaResource? = nil) -> HistoryRecord {
        HistoryRecord(siteKey: "fixture", videoID: "132964", title: "影片", sourceName: "嘟嘟无限", episodeName: "[1.46GB]第13集.mp4",
            playbackReference: HistoryPlaybackReference(sourceIdentity: "old-source", resourceIdentity: "old-token-hash", originalResource: original),
            position: 2635.4, duration: 2778)
    }
    func testStableFileSurvivesLabelRouteAndTokenChangesAndDeduplicatesRoutes() {
        let new = episode(name: "重命名的第13集.mp4")
        let value = detail([PlaySource(name: "嘟嘟无限3", episodes: [new]), PlaySource(name: "嘟嘟无限2", episodes: [new])])
        let resolution = AppState.historyPlaybackResolution(in: value, record: history(original: file()), requiresFileIdentity: true)
        XCTAssertEqual(resolution.automaticChoice?.episode.url, new.url)
        XCTAssertEqual(resolution.choices.count, 1)
    }
    func testDifferentKnownFileIDNeverFallsBackToSameFilenameOrPath() {
        let value = detail([PlaySource(name: "嘟嘟无限", episodes: [episode("replacement")])])
        let resolution = AppState.historyPlaybackResolution(in: value, record: history(original: file()), requiresFileIdentity: true)
        XCTAssertNil(resolution.automaticChoice)
        XCTAssertEqual(resolution.choices.count, 1)
        XCTAssertTrue(resolution.choices.allSatisfy(\.requiresRelink))
    }
    func testLegacyUnknownSeasonOffersEditionsWithoutAutomaticSelection() {
        let value = detail([PlaySource(name: "嘟嘟无限2", episodes: [episode(), episode("hdr", name: "S01E13.4KHDR.mp4")])])
        let resolution = AppState.historyPlaybackResolution(in: value, record: history(), requiresFileIdentity: true)
        XCTAssertNil(resolution.automaticChoice)
        XCTAssertEqual(resolution.choices.count, 2)
        XCTAssertTrue(resolution.choices.allSatisfy(\.requiresRelink))
        XCTAssertTrue(resolution.choices[0].subtitle.contains("folder/S01E13.mp4"))
    }
    func testUnknownTVBoxFormatRequiresSelectionEvenForOneExactLabel() {
        let value = detail([PlaySource(name: "嘟嘟无限", episodes: [PlayEpisode(name: "[1.46GB]第13集.mp4", url: "opaque")])])
        let resolution = AppState.historyPlaybackResolution(in: value, record: history(), requiresFileIdentity: true)
        XCTAssertNil(resolution.automaticChoice)
        XCTAssertEqual(resolution.choices.count, 1)
    }
    func testSameNamesInDifferentSharesRemainDistinctChoices() {
        let first = episode(); var second = episode()
        second.originalResource?.shareID = "other-share"
        let value = detail([PlaySource(name: "Line", episodes: [first, second])])
        let resolution = AppState.historyPlaybackResolution(in: value, record: history(), requiresFileIdentity: true)
        XCTAssertEqual(resolution.choices.count, 2)
        XCTAssertNil(resolution.automaticChoice)
    }
    func testRefreshUsesCurrentFileParametersInsteadOfHistoryLabels() {
        let current = episode()
        let source = PlaySource(name: "嘟嘟无限3", episodes: [current])
        let request = AppState.historyPlaybackRefreshRequest(detail: detail([source]), source: source,
            episode: current, providerReference: nil, origin: .history(history(original: file())))
        XCTAssertEqual(request.sourceName, source.name)
        XCTAssertEqual(request.episodeName, current.name)
        XCTAssertEqual(request.episodeReference, current.url)
    }
    func testNetworkFailuresDoNotMasqueradeAsMissingMovieIDs() {
        for error in [AppError.spider("java.net.SocketException: Socket is closed"), .network("Connection reset")] {
            XCTAssertTrue(HistoryDetailFailurePolicy.isTransient(error))
            XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(error))
        }
        XCTAssertFalse(HistoryDetailFailurePolicy.isTransient(CancellationError()))
        XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.decoding("partial response")))
        XCTAssertTrue(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.contentUnavailable("gone")))
        XCTAssertTrue(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.network("HTTP 404")))
    }
    func testResumeMustBeConfirmedBeforeHistoryCanBeUpdated() {
        let saved = history(original: file())
        XCTAssertEqual(HistoryRelinkResumePolicy.evaluate(record: saved, snapshot: PlayerSnapshot(status: .playing, position: 0, duration: 2778), target: 2635.4, canSeek: true), .waiting)
        XCTAssertEqual(HistoryRelinkResumePolicy.evaluate(record: saved, snapshot: PlayerSnapshot(status: .playing, position: 2636, duration: 2778), target: 2635.4, canSeek: true), .ready)
    }

    func testLocalMediaRelaysExplicitlyBypassInheritedProxy() {
        for address in ["http://127.0.0.1:19978/proxy/media/fixture", "http://localhost:9978/proxy", "http://[::1]:9978/proxy"] {
            let media = ResolvedMedia(url: URL(string: address)!, headers: [:], siteKey: "fixture", sourceName: "Quark", episodeName: "film")
            XCTAssertEqual(PlayerMediaNetworkPolicy.decision(for: media), .direct)
            let command = MPVTVBoxPlaybackPolicy.loadCommand(for: media,
                networkOptions: PlayerMediaNetworkPolicy.decision(for: media)?.mpvOptions ?? [])
            XCTAssertTrue(command.last?.contains("http_proxy=") == true)
        }
        let remote = ResolvedMedia(url: URL(string: "https://fixture.invalid/film.mp4")!, headers: [:], siteKey: "fixture", sourceName: "Quark", episodeName: "film")
        XCTAssertNil(PlayerMediaNetworkPolicy.decision(for: remote))
        XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.spider("ProviderDetailUnavailableAfterRecovery")))
    }
}
