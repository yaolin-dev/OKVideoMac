import AppKit
import Combine
import ImageIO
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class BrowserPlaybackPerformanceTests: XCTestCase {
    private func configuration() -> StoredConfiguration {
        .init(name: "Playback budget fixture", sourceKind: .pasted, rawData: Data("{}".utf8), isActive: true)
    }
    private func line(_ count: Int = 120) -> PlaySource {
        .init(name: "Cloud original", episodes: (1...count).map {
            .init(name: "Show.S01E\($0).2160p.mkv", url: "https://fixture.invalid/media/\($0)?token=temporary")
        })
    }

    func testRealSnapshotHandlerDoesNotBroadcastUnchangedEndingPromptToBrowser() async throws {
        let app = AppState(environment: nil)
        app.seedHistoryPlaybackForTesting(configuration: configuration(), position: 10, duration: 3600, line: line())
        try await Task.sleep(nanoseconds: 10_000_000)
        var browserNotifications = 0, historyNotifications = 0
        let browser = app.objectWillChange.sink { browserNotifications += 1 }
        let history = app.watchHistory.objectWillChange.sink { historyNotifications += 1 }
        for index in 0..<100 {
            app.processPlaybackSnapshotForTesting(.init(status: .playing, position: 10 + Double(index) / 10, duration: 3600))
        }
        XCTAssertEqual(browserNotifications, 0)
        XCTAssertEqual(historyNotifications, 1, "A burst of native events must not publish history for every tick")
        XCTAssertEqual(app.historyTemplateBuildCount, 1)
        withExtendedLifetime((browser, history)) {}
        await app.closePlayer()
    }

    func testHistoryTemplateKeepsFreshProgressAndInvalidatesChangedMediaAndSession() async throws {
        let app = AppState(environment: nil), config = configuration()
        app.seedHistoryPlaybackForTesting(configuration: config, position: 10, duration: 3600, line: line())
        let before = try XCTUnwrap(app.historyRecordForTesting(position: 10, duration: 3600))
        for position in 11...100 {
            let record = try XCTUnwrap(app.historyRecordForTesting(position: Double(position), duration: 3600))
            XCTAssertEqual(record.position, Double(position))
            XCTAssertEqual(record.playbackReference?.navigationRecipe?.resumePosition, Double(position))
            XCTAssertEqual(record.playbackReference?.sourceIdentity, before.playbackReference?.sourceIdentity)
            XCTAssertEqual(record.configurationID, config.id)
            XCTAssertGreaterThanOrEqual(record.watchedAt, before.watchedAt)
        }
        XCTAssertEqual(app.historyTemplateBuildCount, 1)
        app.replaceHistoryMediaForTesting(URL(fileURLWithPath: "/tmp/browser-fixture-replacement.mp4"))
        let replaced = try XCTUnwrap(app.historyRecordForTesting(position: 101, duration: 3600))
        XCTAssertEqual(app.historyTemplateBuildCount, 2)
        XCTAssertEqual(replaced.mediaReference, "file:///tmp/browser-fixture-replacement.mp4")
        app.seedHistoryPlaybackForTesting(configuration: config, videoID: "next", position: 3, duration: 120)
        let next = try XCTUnwrap(app.historyRecordForTesting(position: 3, duration: 120))
        XCTAssertEqual(next.videoID, "next"); XCTAssertEqual(next.position, 3)
        XCTAssertNotEqual(next.id, before.id)
        XCTAssertEqual(app.historyTemplateBuildCount, 3)
        await app.closePlayer()
    }

    func testHiddenOverlayIgnoresClockTicksButWakesForSeekBufferingAndEnd() async throws {
        let source = PlayerSnapshotState(snapshot: .init(status: .playing, position: 10, duration: 3600))
        let observation = PlayerOverlayObservation(source: source)
        observation.setVisible(false)
        var count = 0
        let token = observation.objectWillChange.sink { count += 1 }
        for index in 0..<20 {
            source.update(.init(status: .playing, position: 11 + Double(index), duration: 3600))
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(count, 0)
        source.beginSeek(id: UUID(), target: 100)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(count, 1, "Pending seek has no new native snapshot yet, but must wake the overlay")
        source.resetSeek()
        source.update(.init(status: .buffering, position: 100, duration: 3600))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(count, 2)
        source.update(.init(status: .ended, position: 3600, duration: 3600))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(count, 3)
        observation.setVisible(true)
        let shown = count
        source.update(.init(status: .playing, position: 15, duration: 3600))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThan(count, shown)
        withExtendedLifetime(token) {}
    }

    func testPreparedTMDBMissNeverFallsBackToDifferentSeasonMapping() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let season = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[{"id":1,"episode_number":1,"name":"Wrong fallback","overview":"Wrong synopsis"}]}"#.utf8))
        let source = PlaySource(name: "Line", episodes: [.init(name: "S01E01", url: "opaque:one")])
        let detail = VideoDetail(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "Show", categoryName: "电视剧"), playSources: [source])
        let mapped = TMDBEpisodeInformation.make(detail: detail, work: nil, season: season, source: source, episode: source.episodes[0])
        XCTAssertEqual(mapped.overview, "Wrong synopsis", "Fixture must be mappable by the old fallback")
        for _ in 0..<100 {
            let unresolved = TMDBEpisodeInformation.make(detail: detail, work: nil, season: season, source: source, episode: source.episodes[0], mapping: .prepared(nil))
            XCTAssertFalse(unresolved.hasOverview)
            XCTAssertFalse(unresolved.title.contains("Wrong fallback"))
        }
    }

    func testPreparedTMDBInformationAvoidsWholeLineWorkAndPreservesOutput() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let episodeJSON: [[String: Any]] = (1...120).map {
            ["id": $0, "episode_number": $0, "name": "Arrival \($0)", "overview": "Synopsis", "runtime": 45]
        }
        let season = try decoder.decode(TMDBSeason.self, from: JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": episodeJSON]))
        let source = line(120)
        let detail = VideoDetail(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "Show", categoryName: "电视剧"), playSources: [source])
        let mapping = TMDBEpisodeMapper.episodes(source.episodes, category: "电视剧", season: season)
        let selected = try XCTUnwrap(mapping[0])
        let start = ProcessInfo.processInfo.systemUptime
        var baseline: TMDBEpisodeInformation?
        for _ in 0..<30 { baseline = .make(detail: detail, work: nil, season: season, source: source, episode: source.episodes[0]) }
        let before = ProcessInfo.processInfo.systemUptime - start
        let preparedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<30 {
            XCTAssertEqual(TMDBEpisodeInformation.make(detail: detail, work: nil, season: season, source: source, episode: source.episodes[0], mapping: .prepared(selected)), baseline)
        }
        let after = ProcessInfo.processInfo.systemUptime - preparedStart
        print("BROWSER_PERF tmdb_120_resources_30_reads baseline_ms=\(before * 1000) prepared_ms=\(after * 1000)")
    }

    func testWindowActivityAndBulkRefreshProtectPlaybackWithoutDisablingVisibleBrowsing() {
        XCTAssertTrue(BrowserPlaybackActivityPolicy.surfaceVisible(attached: true, visible: true, miniaturized: false, occluded: false), "A visible secondary window remains active without keyboard focus")
        XCTAssertFalse(BrowserPlaybackActivityPolicy.surfaceVisible(attached: true, visible: true, miniaturized: false, occluded: true))
        XCTAssertFalse(BrowserPlaybackActivityPolicy.surfaceVisible(attached: true, visible: true, miniaturized: true, occluded: false))
        for status: PlayerStatus in [.loading, .buffering] {
            XCTAssertTrue(BrowserPlaybackActivityPolicy.defersBulkRefresh(playerPresented: true, snapshot: .init(status: status)))
            XCTAssertFalse(BrowserPlaybackActivityPolicy.defersBulkRefresh(playerPresented: false, snapshot: .init(status: status)))
        }
        var playing = PlayerSnapshot(status: .playing)
        XCTAssertFalse(BrowserPlaybackActivityPolicy.defersBulkRefresh(playerPresented: true, snapshot: playing))
        playing.isSeeking = true
        XCTAssertTrue(BrowserPlaybackActivityPolicy.defersBulkRefresh(playerPresented: true, snapshot: playing))
    }

    func testHiddenHistoryKeepsLatestDataWithoutInvalidatingItsList() {
        let history = WatchHistoryState()
        history.setPresentationActive(false)
        var notifications = 0
        let token = history.objectWillChange.sink { notifications += 1 }
        for position in 1...60 {
            history.replace([.init(siteKey: "s", videoID: "1", title: "Show", position: Double(position), duration: 3600)])
        }
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(history.records.first?.position, 60, "Hidden presentation must not freeze the actual progress model")
        history.setPresentationActive(true)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(history.records.first?.position, 60)
        history.setPresentationActive(true)
        XCTAssertEqual(notifications, 1)
        withExtendedLifetime(token) {}
    }

    func testNativePosterHiddenDemandResumesAndKeepsLoadedImage() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 24, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let client = BrowserImageClient(body: bytes as Data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: directory, httpClient: client))
        let coordinator = PosterNativeRemoteImage.Coordinator(), view = NSImageView()
        let request = PosterImageRequest(url: URL(string: "https://fixture.invalid/visible.png")!, pixels: 128)
        coordinator.update(view: view, request: request, repository: repository, priority: .visible, isActive: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        let hiddenRequests = await client.count
        XCTAssertEqual(hiddenRequests, 0)
        coordinator.update(view: view, request: request, repository: repository, priority: .visible, isActive: true)
        for _ in 0..<200 where view.image == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let loaded = try XCTUnwrap(view.image)
        coordinator.update(view: view, request: request, repository: repository, priority: .visible, isActive: false)
        XCTAssertTrue(view.image === loaded)
        coordinator.update(view: view, request: request, repository: repository, priority: .visible, isActive: true)
        let requests = await client.count
        XCTAssertEqual(requests, 1)
        coordinator.cancel()
    }
}

private actor BrowserImageClient: HTTPClient {
    let body: Data
    private(set) var count = 0
    init(body: Data) { self.body = body }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        return .init(url: request.url, statusCode: 200, headers: ["Content-Type": "image/png"], body: body)
    }
}
