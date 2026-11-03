import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class HistoryNavigationLocatorTests: XCTestCase {
    static let locator = "https://pan.quark.cn/s/21882ef8f4c8"
    static let returnedID = "21882ef8f4c8"
    static let title = "History Fixture"
    static let site = SiteConfiguration(key: "history-locator", name: "Fixture", type: 3, api: "csp_Fixture")
    static func mappedDetail(_ request: String) throws -> VideoDetail {
        let summary = VideoSummary(siteKey: site.key, siteName: site.name, videoID: request, title: title)
        let payload: JSONValue = .object(["list": .array([.object([
            "vod_id": .string(returnedID), "vod_name": .string(title),
            "vod_play_from": .string("Original"), "vod_play_url": .string("Episode03.mkv$opaque-current-token")
        ])])])
        guard case .detail(let detail) = try AndroidDexSpiderSiteProvider.foregroundSelection(payload,
            site: site, baseURL: nil, summary: summary) else { throw AppError.contentUnavailable("fixture") }
        return detail
    }
    func record(configurationID: UUID) -> HistoryRecord {
        HistoryRecord(configurationID: configurationID, siteKey: Self.site.key, videoID: Self.returnedID,
            title: Self.title, sourceName: "Original", episodeName: "Episode03.mkv",
            position: 1004.24, duration: 1138.706, watchedAt: Date(timeIntervalSince1970: 1793594448))
    }
    func testReturnedIdentityAndRequestLocatorSurvivePersistenceWithoutDuplicatingHistory() async throws {
        let environment = try AppEnvironment.live(), id = UUID()
        let original = record(configurationID: id), detail = try Self.mappedDetail(Self.locator)
        XCTAssertEqual(detail.summary.videoID, original.videoID)
        XCTAssertEqual(detail.detailRequestID, Self.locator)
        let source = detail.playSources[0], episode = source.episodes[0]
        let recipe = AppState.historyNavigationRecipe(detail: detail, source: source, episode: episode,
            configurationID: id, position: original.position)
        var repaired = original
        repaired.playbackReference = .init(sourceIdentity: source.stableIdentity, resourceIdentity: episode.stableIdentity,
            navigationRecipe: recipe)
        try await environment.database.saveHistory(original, incognito: false)
        try await environment.database.saveHistory(repaired, incognito: false)
        let rows = try await environment.database.history()
        XCTAssertEqual(rows.count, 1)
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.navigationDetailID, Self.locator)
        XCTAssertEqual(saved.position, original.position)
        XCTAssertEqual(saved.duration, original.duration)
        XCTAssertEqual(saved.watchedAt, original.watchedAt)
    }
    func testLegacyJSONAndUnsafeOrForeignLocatorFallBackWithoutChangingProgress() throws {
        let original = record(configurationID: UUID()), detail = try Self.mappedDetail(Self.locator)
        var recipe = AppState.historyNavigationRecipe(detail: detail, source: detail.playSources[0],
            episode: detail.playSources[0].episodes[0], configurationID: original.configurationID!, position: original.position)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
        json.removeValue(forKey: "detailRequestID"); json["version"] = 4
        let legacy = try JSONDecoder().decode(HistoryNavigationRecipe.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.detailRequestID)
        var saved = original
        saved.playbackReference = .init(sourceIdentity: "line", resourceIdentity: "file", navigationRecipe: legacy)
        XCTAssertEqual(saved.navigationDetailID, Self.returnedID)
        XCTAssertEqual(saved.position, 1004.24)
        for locator in [Self.locator + "?token=private", "http://127.0.0.1/session", "https://user:password@example.org/id"] {
            recipe.detailRequestID = locator
            XCTAssertNil(recipe.sanitizedForPersistence()?.detailRequestID)
            saved.playbackReference?.navigationRecipe = recipe
            XCTAssertEqual(saved.navigationDetailID, Self.returnedID)
        }
        recipe.detailRequestID = Self.locator; recipe.configurationID = UUID()
        saved.playbackReference?.navigationRecipe = recipe
        XCTAssertEqual(saved.navigationDetailID, Self.returnedID)
        recipe.configurationID = original.configurationID!; recipe.siteKey = "another-site"
        saved.playbackReference?.navigationRecipe = recipe
        XCTAssertEqual(saved.navigationDetailID, Self.returnedID)
    }
    func testOnlyEmptyMediaDetailsAllowLegacyRecoveryAndSettingsStillWork() throws {
        let summary = VideoSummary(siteKey: Self.site.key, siteName: Self.site.name, videoID: Self.returnedID, title: Self.title)
        for value in [JSONValue.string(" \n"), .null] {
            XCTAssertThrowsError(try AndroidDexSpiderSiteProvider.foregroundSelection(value,
                site: Self.site, baseURL: nil, summary: summary)) { error in
                XCTAssertTrue(HistoryDetailFailurePolicy.permitsTitleRecovery(error))
            }
        }
        XCTAssertThrowsError(try AndroidDexSpiderSiteProvider.foregroundSelection(.string("java.net.SocketException: Socket is closed"),
            site: Self.site, baseURL: nil, summary: summary)) { error in
            XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(error))
        }
        let settings = SiteConfiguration(key: "settings", name: "Settings", type: 3, api: "csp_PanConfigGuard")
        XCTAssertEqual(try AndroidDexSpiderSiteProvider.foregroundSelection(.string(""),
            site: settings, baseURL: nil, summary: summary), .action(.string("")))
    }
    func testSameTitleDoesNotEstablishOriginalDetailOrFileIdentity() throws {
        let saved = record(configurationID: UUID())
        var detail = try Self.mappedDetail(Self.locator)
        XCTAssertTrue(AppState.isOriginalHistoryDetail(detail, record: saved))
        XCTAssertNil(AppState.historyPlaybackResolution(in: detail, record: saved, requiresFileIdentity: true).automaticChoice)
        detail.summary.videoID = "other-share"
        XCTAssertFalse(AppState.isOriginalHistoryDetail(detail, record: saved))
        detail.summary.videoID = saved.videoID; detail.summary.siteKey = "other-site"
        XCTAssertFalse(AppState.isOriginalHistoryDetail(detail, record: saved))
    }

    func testConfirmedYpanSoFileReopensAcrossTokenChangesWithoutSavingCredentials() throws {
        func token(_ auth: String, fileID: String = "file03") -> String {
            "{\"flag\":\"夸父盘\",\"sId\":\"share\",\"fid\":\"\(fileID)\",\"file_name\":\"03.mkv\",\"size\":1513975972,\"sToken\":\"\(auth)\",\"share_fid_token\":\"private\"}"
        }
        let resource = try XCTUnwrap(AndroidDexSpiderSiteProvider.originalFileResource(api: "csp_YpanSoGuard", token: token("old-secret")))
        var detail = try Self.mappedDetail(Self.locator)
        detail.playSources[0].episodes[0].originalResource = resource
        var legacy = record(configurationID: UUID())
        XCTAssertEqual(AppState.historyPlaybackResolution(in: detail, record: legacy, requiresFileIdentity: true).choices.count, 1,
            "The legacy playlist label must still match when original filename is only 03.mkv")
        let source = detail.playSources[0], episode = source.episodes[0]
        legacy.playbackReference = AppState.historyPlaybackReference(source: source, episode: episode,
            navigationRecipe: AppState.historyNavigationRecipe(detail: detail, source: source, episode: episode,
                configurationID: legacy.configurationID!, position: legacy.position), headers: [:])
        let persisted = legacy.sanitizedForPersistence()
        let encoded = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(encoded.contains("old-secret")); XCTAssertFalse(encoded.contains("private")); XCTAssertFalse(encoded.contains("sToken"))
        detail.playSources[0].episodes[0].originalResource = AndroidDexSpiderSiteProvider.originalFileResource(api: "csp_YpanSoGuard", token: token("new-secret"))
        detail.playSources[0].episodes[0].url = token("new-secret")
        XCTAssertNotNil(AppState.historyPlaybackResolution(in: detail, record: persisted, requiresFileIdentity: true).automaticChoice)
        detail.playSources[0].episodes[0].originalResource?.fileID = "replacement"
        XCTAssertNil(AppState.historyPlaybackResolution(in: detail, record: persisted, requiresFileIdentity: true).automaticChoice)
        XCTAssertNil(AndroidDexSpiderSiteProvider.originalFileResource(api: "csp_Unknown", token: token("secret")))
        XCTAssertNil(AndroidDexSpiderSiteProvider.originalFileResource(api: "csp_YpanSoGuard", token: token("secret", fileID: "https://example.org/token")))
    }

    func testPlaybackRefreshUsesRequestLocatorAfterLegacyChoiceAndOnLaterRetries() async throws {
        let saved = record(configurationID: UUID()), detail = try Self.mappedDetail(Self.locator)
        let source = detail.playSources[0], episode = source.episodes[0]
        for origin in [PlaybackRequestOrigin.direct, .history(saved), .historyRelink(saved, fromBeginning: false)] {
            let provider = Provider()
            let request = AppState.historyPlaybackRefreshRequest(detail: detail, source: source,
                episode: episode, providerReference: nil, origin: origin)
            XCTAssertEqual(request.videoID, Self.locator, "Fresh playback must request the locator, never the returned history row ID")
            let refreshed = try await provider.resolvePlaybackRefreshSelection(request)
            XCTAssertEqual(refreshed.detail.summary.videoID, saved.videoID)
            XCTAssertEqual(refreshed.detail.detailRequestID, Self.locator)
            XCTAssertEqual(refreshed.episode.name, saved.episodeName)
            let requests = await provider.requests, searches = await provider.searches
            XCTAssertEqual(requests, [Self.locator]); XCTAssertEqual(searches, 0)
            XCTAssertEqual(saved.position, 1004.24)
        }
    }

    actor Provider: SiteProvider {
        nonisolated let site = SiteConfiguration(key: "history-locator", name: "Fixture", type: 3, api: "csp_Fixture")
        nonisolated let capability = SiteCapability.javaDexSpider
        var requests: [String] = []
        var searches = 0
        let networkFailure: Bool
        init(networkFailure: Bool = false) { self.networkFailure = networkFailure }
        func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
        func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
            VideoPage(items: [], pagination: Pagination(page: page, pageCount: 1))
        }
        func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
            searches += 1
            let locator = await HistoryNavigationLocatorTests.locator
            let title = await HistoryNavigationLocatorTests.title
            return VideoPage(items: ["stale-card", locator, "unrelated-card"].map {
                VideoSummary(siteKey: site.key, siteName: site.name, videoID: $0, title: title)
            }, pagination: Pagination(page: page, pageCount: 1))
        }
        func detail(id: String) async throws -> VideoDetail {
            requests.append(id)
            if networkFailure { throw AppError.network("Connection reset") }
            if await id != HistoryNavigationLocatorTests.locator { throw AppError.contentUnavailable("empty media detail") }
            return try await HistoryNavigationLocatorTests.mappedDetail(id)
        }
        func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
            throw AppError.playback("A legacy file must require an explicit choice before playback")
        }
    }
    func runRestore(savedLocator: Bool, networkFailure: Bool = false) async throws -> (AppState, AppEnvironment, Provider, HistoryRecord) {
        let provider = Provider(networkFailure: networkFailure), environment = try AppEnvironment.live()
        let state = AppState(environment: environment)
        let config = StoredConfiguration(name: "History fixture", sourceKind: .pasted, rawData: Data("{}".utf8))
        state.seedCategoryHomeForTesting(record: config, provider: provider, home: try await provider.home())
        var saved = record(configurationID: config.id)
        if savedLocator {
            let detail = try Self.mappedDetail(Self.locator), source = detail.playSources[0]
            saved.playbackReference = .init(sourceIdentity: "line", resourceIdentity: "file", navigationRecipe:
                AppState.historyNavigationRecipe(detail: detail, source: source, episode: source.episodes[0],
                    configurationID: config.id, position: saved.position))
        }
        try await environment.database.saveHistory(saved, incognito: false)
        state.requestHistoryPlayback(saved)
        for _ in 0..<300 {
            if state.historyPlaybackLoadingID == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(state.historyPlaybackLoadingID)
        return (state, environment, provider, saved)
    }
    func testLegacyHistoryRecoversOriginalAfterStaleCardWithoutTouchingProgress() async throws {
        let (state, environment, provider, saved) = try await runRestore(savedLocator: false)
        let requests = await provider.requests, searches = await provider.searches
        XCTAssertEqual(requests, [Self.returnedID, "stale-card", Self.locator])
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(state.historyPlaybackChoices.count, 1)
        XCTAssertTrue(state.historyPlaybackChoices.allSatisfy(\.requiresRelink))
        XCTAssertEqual(state.historyPlaybackChoices.first?.detail.detailRequestID, Self.locator)
        state.cancelHistoryPlaybackChoices()
        await state.closePlayer()
        let rows = try await environment.database.history()
        XCTAssertEqual(rows, [saved], "Discovery and cancellation must preserve every saved field")
        await state.shutdown()
    }
    func testSavedLocatorReopensDirectlyAndOriginalDetailsUseSameLocator() async throws {
        let (state, environment, provider, saved) = try await runRestore(savedLocator: true)
        let requests = await provider.requests, searches = await provider.searches
        XCTAssertEqual(requests, [Self.locator]); XCTAssertEqual(searches, 0)
        XCTAssertEqual(state.historyPlaybackChoices.count, 1)
        await state.openOriginalHistoryDetail()
        XCTAssertEqual(state.selectedDetail?.detailRequestID, Self.locator)
        let rows = try await environment.database.history()
        XCTAssertEqual(rows, [saved])
        await state.shutdown()
    }
    func testNetworkFailureDoesNotSearchOrOverwriteSavedHistory() async throws {
        let (state, environment, provider, saved) = try await runRestore(savedLocator: true, networkFailure: true)
        let searches = await provider.searches
        XCTAssertEqual(searches, 0)
        XCTAssertTrue(state.historyPlaybackChoices.isEmpty)
        XCTAssertNotNil(state.playbackFailureSummary)
        let rows = try await environment.database.history()
        XCTAssertEqual(rows, [saved])
        await state.shutdown()
    }
}
