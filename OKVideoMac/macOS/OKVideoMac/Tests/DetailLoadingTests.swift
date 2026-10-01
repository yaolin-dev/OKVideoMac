import XCTest
import AppKit
import SwiftUI
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class PlayerTooltipTests: XCTestCase {
    func testHoverWaitsAndOldExitCannotClearNewButton() async throws {
        let model = PlayerControlTooltipState(delayNanoseconds: 20_000_000)
        let a = UUID(), b = UUID()
        model.hover(a, inside: true)
        XCTAssertNil(model.activeID)
        model.hover(b, inside: true)
        model.hover(a, inside: false)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.activeID, b)
        model.hover(b, inside: false)
        XCTAssertNil(model.activeID)
    }

    func testShortHoverDismissAndDisabledInteractionCancelDelayedPresentation() async throws {
        let model = PlayerControlTooltipState(delayNanoseconds: 20_000_000), id = UUID()
        model.hover(id, inside: true); model.hover(id, inside: false)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(model.activeID)
        model.hover(id, inside: true); model.dismiss()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(model.activeID)
        model.hover(id, inside: true); model.setEnabled(false)
        model.hover(id, inside: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(model.activeID, "Drag/fullscreen must suppress delayed and fresh hover events")
        model.setEnabled(true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(model.activeID, "Re-enabling must not restore stale hover")
        model.hover(id, inside: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.activeID, id)
    }

    func testTooltipOffscreenLayoutAndFocusDismissal() async throws {
        let model = PlayerControlTooltipState(delayNanoseconds: 20_000_000), id = UUID()
        let host = NSHostingView(rootView:
            ZStack {
                Color(red: 0.24, green: 0.35, blue: 0.46)
                VStack {
                    Spacer()
                    HStack {
                        Button {} label: { Image(systemName: "play.fill").frame(width: 38, height: 38) }
                            .buttonStyle(.plain)
                            .modifier(PlayerControlTooltip(title: "播放 / 暂停", id: id))
                        Spacer()
                        Image(systemName: "gearshape").frame(width: 38, height: 38)
                    }.padding(24)
                }
            }.foregroundColor(.white).modifier(PlayerControlTooltipOverlay(model: model)))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 640, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        model.hover(id, inside: true)
        for width in [640.0, 260.0] {
            window.setContentSize(.init(width: width, height: 180))
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ok115-tooltip-\(Int(width)).png"))
            XCTAssertEqual(model.activeID, id)
        }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(model.activeID)
    }
}

@MainActor final class DetailLoadingTests: XCTestCase {
    func testToolbarRefreshReturnsToClickableButtonAfterRepeatedLoads() {
        let control = DetailRefreshControl()
        let originalChildren = control.subviews
        let originalSize = control.intrinsicContentSize
        var calls = 0
        for _ in 0..<3 {
            control.update(isLoading: true) { calls += 1 }
            XCTAssertTrue(control.refreshButton.isHidden)
            XCTAssertFalse(control.refreshButton.isEnabled)
            XCTAssertFalse(control.progressIndicator.isHidden)
            control.update(isLoading: false) { calls += 1 }
            XCTAssertFalse(control.refreshButton.isHidden)
            XCTAssertTrue(control.refreshButton.isEnabled)
            XCTAssertTrue(control.progressIndicator.isHidden)
            XCTAssertEqual(control.subviews, originalChildren)
            XCTAssertEqual(control.intrinsicContentSize, originalSize)
            control.refreshButton.performClick(nil)
        }
        XCTAssertEqual(calls, 3)
        // Reused controls must invoke the current page's closure.
        control.update(isLoading: false) { calls += 10 }
        control.refreshButton.performClick(nil)
        XCTAssertEqual(calls, 13)
    }

    func testDetailLayoutInCompactAndWideAppearance() async throws {
        let state = AppState(environment: nil)
        let summary = VideoSummary(siteKey: "fixture", siteName: "测试来源", videoID: "film",
            title: "一段旅程：详情布局与原生控件验收", remarks: "更新至第 240 集", year: "2026")
        let detail = VideoDetail(summary: summary, area: "中国", director: "示例导演", actors: "示例演员一、示例演员二",
            synopsis: String(repeating: "这是一段用于检查阅读宽度与折叠行为的简介。故事从一个平凡的清晨开始，人物在旅途中发现生活的变化。", count: 80),
            playSources: (1...8).map { index in PlaySource(name: "验收线路 \(index)", episodes:
                (1...240).map { PlayEpisode(name: "第 \($0) 集", url: "opaque:\(index):\($0)") }) })
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Detail111-Visuals", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldSelection = UserDefaults.standard.object(forKey: "detail.lastPlaySourceName")
        defer { UserDefaults.standard.set(oldSelection, forKey: "detail.lastPlaySourceName") }
        UserDefaults.standard.set("验收线路 2", forKey: "detail.lastPlaySourceName")
        let host = NSHostingView(rootView: DetailView(detail: detail).environmentObject(state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Offscreen fixture: do not take focus from the user's desktop app.
        defer { window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        for (name, width, appearance) in [
            ("compact-light", 650.0, NSAppearance.Name.aqua),
            ("wide-light", 1800.0, .aqua),
            ("wide-dark", 1800.0, .darkAqua),
            ("stacked-light", 500.0, .aqua),
            ("normal-return", 900.0, .aqua)
        ] {
            host.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 1100))
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertEqual(UserDefaults.standard.string(forKey: "detail.lastPlaySourceName"), "验收线路 2")
            let scrolls = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSScrollView }
            let vertical = try XCTUnwrap(scrolls.max { $0.bounds.height < $1.bounds.height })
            XCTAssertLessThanOrEqual(try XCTUnwrap(vertical.documentView).bounds.width, width + 1,
                "The page must not overflow horizontally at \(width)")
            XCTAssertTrue(BrowserKeyboardView.descendants(of: host).allSatisfy { !($0 is NativeBrowseCategoryNavigation) })
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("detail-\(name).png"))
        }
    }

    private func summary(_ id: String = "film", site: String = "detail") -> VideoSummary {
        VideoSummary(siteKey: site, siteName: site, videoID: id, title: "Film")
    }

    private func detail(_ item: VideoSummary) -> VideoDetail {
        VideoDetail(summary: item, playSources: [PlaySource(name: "Line", episodes: [PlayEpisode(name: "1", url: "opaque:episode")])])
    }

    func testCacheExpiresAndSeparatesSourcesAndGenerations() {
        var time: TimeInterval = 0
        let cache = DetailResponseCache(lifetime: 120, now: { time })
        let item = summary(), key = cache.key(for: item)
        cache.insert(detail(item), for: key)
        XCTAssertNotNil(cache.value(for: key))
        XCTAssertNil(cache.value(for: cache.key(for: summary(site: "other"))))
        time = 120
        XCTAssertNil(cache.value(for: key))
        cache.insert(detail(item), for: key)
        cache.invalidate()
        XCTAssertNil(cache.value(for: key))
        cache.insert(detail(item), for: key) // Late response from old credentials.
        XCTAssertNil(cache.value(for: cache.key(for: item)))
    }

    func testEmptyAndActionDetailsAreNeverCached() {
        let cache = DetailResponseCache()
        var item = summary()
        cache.insert(VideoDetail(summary: item), for: cache.key(for: item))
        XCTAssertNil(cache.value(for: cache.key(for: item)))
        item.contentKind = .action
        cache.insert(detail(item), for: cache.key(for: item))
        XCTAssertNil(cache.value(for: cache.key(for: item)))
    }

    func testConcurrentTapsAndRepeatedVisitOnlyRequestOnce() async {
        let recorder = DetailFixtureRecorder()
        let provider = DetailFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: ["detail": provider])
        async let a: Void = state.loadDetail(summary())
        async let b: Void = state.loadDetail(summary())
        _ = await (a, b)
        XCTAssertNotNil(state.selectedDetail)
        state.dismissDetail()
        await state.loadDetail(summary())
        let count = await recorder.calls
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(state.selectedDetail)
        XCTAssertFalse(state.isRefreshingDetail)
    }

    func testDismissCancelsTransportAndDoesNotPopulateCache() async throws {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        let task = Task { await state.loadDetail(summary()) }
        try await recorder.waitForCalls(1)
        state.dismissDetail()
        await task.value
        let cancelled = await recorder.cancelled
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(state.selectedDetail)
        XCTAssertNil(state.pendingDetailSummary)
        XCTAssertNil(state.presentedError)
        await state.loadDetail(summary())
        let calls = await recorder.calls
        XCTAssertEqual(calls, 2)
    }

    func testSwitchingFilmCancelsOldRequestAndOnlyPublishesNewFilm() async throws {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        let old = Task { await state.loadDetail(summary("old")) }
        try await recorder.waitForCalls(1)
        await state.loadDetail(summary("new"))
        await old.value
        XCTAssertEqual(state.selectedDetail?.summary.videoID, "new")
        let cancelled = await recorder.cancelled
        XCTAssertEqual(cancelled, 1)
    }

    func testRefreshPreservesVisibleDetailsOnFailureAndCanRetry() async throws {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        await state.loadDetail(summary())
        let old = state.selectedDetail
        await recorder.failNext()
        let refresh = Task { await state.refreshDetail() }
        try await recorder.waitForCalls(2)
        XCTAssertEqual(state.selectedDetail, old)
        XCTAssertNil(state.pendingDetailSummary)
        XCTAssertTrue(state.isRefreshingDetail)
        await refresh.value
        XCTAssertEqual(state.selectedDetail, old)
        XCTAssertNil(state.presentedError)
        XCTAssertNotNil(state.detailLoadState.message)
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertFalse(state.isRefreshingDetail)
        await state.refreshDetail()
        XCTAssertEqual(state.selectedDetail?.synopsis, "request 3")
    }

    func testProviderReplacementInvalidatesCacheAndInFlightWork() async throws {
        let recorder = DetailFixtureRecorder()
        let provider = DetailFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: ["detail": provider])
        await state.loadDetail(summary())
        state.setLiveConfigurationForTesting(nil, providers: ["detail": provider])
        XCTAssertNil(state.selectedDetail)
        let load = Task { await state.loadDetail(summary()) }
        try await recorder.waitForCalls(2)
        state.setLiveConfigurationForTesting(nil, providers: ["detail": provider])
        await load.value
        XCTAssertNil(state.selectedDetail)
        await state.loadDetail(summary())
        let calls = await recorder.calls
        XCTAssertEqual(calls, 3)
    }

    func testFirstFailureKeepsRouteAndRetrySucceeds() async {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        state.seedSearchResultsForTesting([summary()])
        await recorder.failNext()
        await state.loadDetail(summary())
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertEqual(state.detailRouteSummary?.videoID, "film")
        XCTAssertNil(state.selectedDetail)
        XCTAssertNil(state.presentedError)
        XCTAssertNotNil(state.detailLoadState.message)
        XCTAssertFalse(state.isRefreshingDetail)
        await state.refreshDetail()
        XCTAssertEqual(state.detailLoadState, .loaded)
        XCTAssertNotNil(state.selectedDetail)
        state.dismissDetail()
        XCTAssertFalse(state.isDetailPagePresented)
        XCTAssertEqual(state.searchResults.count, 1)
    }

    func testCatPawStorageWritesDuringDetailDoNotCancelOrCacheOldGeneration() async throws {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        let load = Task { await state.loadDetail(summary()) }
        try await recorder.waitForCalls(1)
        // Share caches can be persisted several times while one detail resolves.
        for _ in 0..<3 { state.nodeProfileStorageDidChange() }
        XCTAssertTrue(state.isDetailPagePresented)
        await load.value
        XCTAssertEqual(state.detailLoadState, .loaded)
        XCTAssertNotNil(state.selectedDetail)
        let cancelled = await recorder.cancelled
        XCTAssertEqual(cancelled, 0)
        state.dismissDetail()
        await state.loadDetail(summary())
        let calls = await recorder.calls
        XCTAssertEqual(calls, 2, "A request started before a storage/account update must not repopulate reusable cache")
    }

    func testCatPawStorageUpdateCannotReopenDismissedOrPreviousFilm() async throws {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        let load = Task { await state.loadDetail(summary("old")) }
        try await recorder.waitForCalls(1)
        state.nodeProfileStorageDidChange()
        state.dismissDetail()
        await load.value
        state.nodeProfileStorageDidChange()
        XCTAssertFalse(state.isDetailPagePresented)
        await state.loadDetail(summary("new"))
        state.nodeProfileStorageDidChange()
        XCTAssertEqual(state.selectedDetail?.summary.videoID, "new")
    }

    func testCatPawShareCacheRevisionDoesNotChangeCatalogueIdentity() throws {
        let raw = Data(#"{"video":{"sites":[{"key":"fixture","name":"Fixture","type":3,"api":"/spider/fixture/3"}]}}"#.utf8)
        let first = try NodeBundleRuntimeService.normalizeConfiguration(raw,
            bundleIdentity: "bundle", profileIdentity: "account-a", profileRevision: "before-cache-write")
        let second = try NodeBundleRuntimeService.normalizeConfiguration(raw,
            bundleIdentity: "bundle", profileIdentity: "account-a", profileRevision: "after-cache-write")
        let other = try NodeBundleRuntimeService.normalizeConfiguration(raw,
            bundleIdentity: "bundle", profileIdentity: "account-b", profileRevision: "after-cache-write")
        XCTAssertNotEqual(first, second, "Keep the storage revision available for authorization")
        XCTAssertEqual(NodeConfigurationSemanticIdentity.revision(in: first), NodeConfigurationSemanticIdentity.revision(in: second))
        XCTAssertNotEqual(NodeConfigurationSemanticIdentity.revision(in: first), NodeConfigurationSemanticIdentity.revision(in: other))
    }

    func testBackgroundCatalogueReplacementKeepsRouteButRejectsOldDetails() async throws {
        let recorder = DetailFixtureRecorder()
        let provider = DetailFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: ["detail": provider])
        let load = Task { await state.loadDetail(summary()) }
        try await recorder.waitForCalls(1)
        state.setLiveConfigurationForTesting(nil, providers: ["detail": provider], preservingDetailRoute: true)
        await load.value
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertNil(state.selectedDetail)
        XCTAssertNotNil(state.detailLoadState.message)
        await state.refreshDetail()
        XCTAssertEqual(state.detailLoadState, .loaded)
        XCTAssertEqual(state.selectedDetail?.synopsis, "request 2")
    }

    func testProviderInternalCancellationKeepsRetryablePage() async {
        let recorder = DetailFixtureRecorder()
        await recorder.cancelNextInternally()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)])
        await state.loadDetail(summary())
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertNotNil(state.detailLoadState.message)
        XCTAssertFalse(state.isRefreshingDetail)
        await state.refreshDetail()
        XCTAssertEqual(state.detailLoadState, .loaded)
    }

    func testUnexpectedSearchResponseWaitsForExplicitNavigation() async {
        let state = AppState(environment: nil, initialProviders: ["detail": DetailSearchResponseFixture()])
        await state.loadDetail(summary())
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertEqual(state.detailSuggestedSearch, "Suggested title")
        XCTAssertFalse(state.isSearching)
        XCTAssertNotNil(state.detailLoadState.message)
        state.dismissDetail()
        XCTAssertFalse(state.isDetailPagePresented)
    }

    func testTimeoutKeepsPageAndRejectsCancelledCompletion() async {
        let recorder = DetailFixtureRecorder()
        let state = AppState(environment: nil, initialProviders: ["detail": DetailFixture(recorder: recorder)], detailRequestTimeout: 0.01)
        await state.loadDetail(summary())
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertNil(state.selectedDetail)
        XCTAssertNotNil(state.detailLoadState.message)
        XCTAssertFalse(state.isRefreshingDetail)
        XCTAssertNil(state.presentedError)
        state.dismissDetail()
        await state.refreshDetail()
        XCTAssertFalse(state.isDetailPagePresented)
    }

    func testUnavailableProviderStillHasBackAndRetryPage() async {
        let state = AppState(environment: nil)
        await state.loadDetail(summary())
        XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertNotNil(state.detailLoadState.message)
        XCTAssertNil(state.presentedError)
        state.dismissDetail()
        XCTAssertFalse(state.isDetailPagePresented)
    }

    func testEpisodeRefreshUpdatesMiddleEpisodeWithSameCountAndEndpoints() async {
        let repository = EpisodePresentationRepository()
        var source = PlaySource(name: "Line", episodes: (1...3).map { PlayEpisode(name: "Episode \($0)", url: "opaque:\($0)") })
        let old = await repository.snapshot(videoID: "film", source: source)
        source.episodes[1] = PlayEpisode(name: "Episode 2 new", url: "opaque:new")
        let new = await repository.snapshot(videoID: "film", source: source)
        XCTAssertNotEqual(old.values[1].episode, new.values[1].episode)
        XCTAssertEqual(new.values[1].episode, source.episodes[1])
    }
}

private actor DetailFixtureRecorder {
    private(set) var calls = 0
    private(set) var cancelled = 0
    private var fails = false
    private var internalCancel = false
    func failNext() { fails = true }
    func cancelNextInternally() { internalCancel = true }
    func run() async throws -> Int {
        calls += 1
        let count = calls, fail = fails
        fails = false
        do { try await Task.sleep(nanoseconds: 100_000_000) }
        catch { cancelled += 1; throw error }
        if internalCancel { internalCancel = false; throw CancellationError() }
        if fail { throw AppError.site("fixture failure") }
        return count
    }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<200 {
            if calls >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("request did not start")
    }
}

private struct DetailSearchResponseFixture: SiteProvider {
    let site = SiteConfiguration(key: "detail", name: "Source", type: 1, api: "https://example.invalid")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0)) }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: keyword, page: page, filters: [:]) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused") }
    func select(summary: VideoSummary) async throws -> SiteSelectionResult { .search("Suggested title") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
}

private struct DetailFixture: SiteProvider {
    let recorder: DetailFixtureRecorder
    let site = SiteConfiguration(key: "detail", name: "Source", type: 1, api: "https://example.invalid")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0)) }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: keyword, page: page, filters: [:]) }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
    func detail(id: String) async throws -> VideoDetail {
        let call = try await recorder.run()
        return VideoDetail(summary: VideoSummary(siteKey: site.key, siteName: site.name, videoID: id, title: "Film"), synopsis: "request \(call)", playSources: [PlaySource(name: "Line", episodes: [PlayEpisode(name: "1", url: "opaque:episode")])])
    }
}

@MainActor final class HomeFilterRegressionTests: XCTestCase {
    private func fixture() async throws -> (AppState, FilterRequestRecorder, FilterFixture) {
        let recorder = FilterRequestRecorder()
        let provider = FilterFixture(recorder: recorder)
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Filter fixture", sourceKind: .pasted,
            rawData: try JSONEncoder().encode(FongMiConfiguration(sites: [provider.site])), isActive: true)
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: try await provider.home())
        return (state, recorder, provider)
    }

    private func settle(_ state: AppState) async throws {
        for _ in 0..<150 {
            if !state.isLoading { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The filter intent must finish rather than leaving a permanent skeleton")
    }

    func testClearFilterSurvivesNativeGridDisappearing() async throws {
        let (state, recorder, _) = try await fixture()
        let loaded = await state.loadCategory(id: "movie", filters: ["area": "cn"])
        XCTAssertTrue(loaded)
        let host = NSHostingView(rootView: HomeView().environmentObject(state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let clear = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("home.filter.clear", fallback: "Clear Filters") })
        clear.performClick(nil)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.categoryPage, "The old native grid is replaced while this request is pending")
        try await settle(state)
        XCTAssertEqual(state.selectedCategoryFilters["area"], "all")
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "all")
        let calls = await recorder.values
        XCTAssertEqual(calls, ["cn", "all"])
    }

    func testFilterRequestOutlivesTransientCaller() async throws {
        let (state, recorder, _) = try await fixture()
        await state.loadCategory(id: "movie")
        let caller = Task { state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"]) }
        await caller.value
        caller.cancel()
        try await settle(state)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "cn")
        let calls = await recorder.values
        XCTAssertEqual(calls, ["all", "cn"])
    }

    func testRapidFilterChangesOnlyRequestLatestSelection() async throws {
        let (state, recorder, _) = try await fixture()
        await state.loadCategory(id: "movie")
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"])
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "us"])
        try await settle(state)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "us")
        let calls = await recorder.values
        XCTAssertEqual(calls, ["all", "us"])
    }

    func testSlowPreviousFilterCannotReplaceLatestResults() async throws {
        let (state, recorder, _) = try await fixture()
        await state.loadCategory(id: "movie")
        await recorder.setSlow("cn")
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"])
        try await recorder.waitFor("cn")
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "us"])
        try await settle(state)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "us")
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "us")
        XCTAssertFalse(state.isLoading)
    }

    func testFailedFilterEndsLoadingAndCanRetry() async throws {
        let (state, recorder, _) = try await fixture()
        await state.loadCategory(id: "movie")
        await recorder.failNext()
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"])
        try await settle(state)
        XCTAssertNotNil(state.homeLoadErrorMessage)
        XCTAssertNil(state.categoryPage)
        let retried = await state.loadCategory(id: "movie", filters: state.selectedCategoryFilters,
            reportErrors: false, forceRefresh: true)
        XCTAssertTrue(retried)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "cn")
        XCTAssertNil(state.homeLoadErrorMessage)
        XCTAssertFalse(state.isLoading)
    }

    func testClearingCategoryCancelsPendingFilterAndLoading() async throws {
        let (state, recorder, _) = try await fixture()
        await state.loadCategory(id: "movie")
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"])
        state.clearCategory()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(state.selectedCategoryID)
        XCTAssertFalse(state.isLoading)
        let calls = await recorder.values
        XCTAssertEqual(calls, ["all"])
    }

    func testChangingConfigurationCannotApplyOldFilterToSameCategoryID() async throws {
        let (state, recorder, provider) = try await fixture()
        await state.loadCategory(id: "movie")
        state.scheduleCategoryFilterLoad(id: "movie", filters: ["area": "cn"])
        let record = StoredConfiguration(name: "Replacement", sourceKind: .pasted,
            rawData: try JSONEncoder().encode(FongMiConfiguration(sites: [provider.site])), isActive: true)
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: try await provider.home())
        await state.loadCategory(id: "movie")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(state.categoryPage?.items.first?.videoID, "all")
        let calls = await recorder.values
        XCTAssertEqual(calls, ["all", "all"])
    }
}

private actor FilterRequestRecorder {
    private(set) var values: [String] = []
    private var failing = false
    private var slow: String?
    func failNext() { failing = true }
    func setSlow(_ value: String) { slow = value }
    func request(_ value: String) async throws {
        values.append(value)
        let fail = failing
        failing = false
        try await Task.sleep(nanoseconds: value == slow ? 600_000_000 : 20_000_000)
        if fail { throw AppError.site("Fixture filter failure") }
    }
    func waitFor(_ value: String) async throws {
        for _ in 0..<100 {
            if values.contains(value) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Filter request did not start")
    }
}

private struct FilterFixture: SiteProvider {
    let recorder: FilterRequestRecorder
    let site = SiteConfiguration(key: "filter-fixture", name: "Filter fixture", type: 1, api: "https://example.invalid")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome {
        SiteHome(categories: [VideoCategory(id: "movie", name: "电影", filters: [
            VideoFilter(id: "area", name: "地区", options: [
                VideoFilterOption(name: "全部", value: "all"),
                VideoFilterOption(name: "华语", value: "cn"),
                VideoFilterOption(name: "欧美", value: "us")
            ])
        ]), VideoCategory(id: "series", name: "剧集")], recommendations: [])
    }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
        let area = filters["area"] ?? "all"
        try await recorder.request(area)
        return VideoPage(items: [VideoSummary(siteKey: site.key, siteName: site.name,
            videoID: area, title: "筛选结果 " + area, posterURL: URL(string: "https://example.invalid/poster.jpg"))],
            pagination: Pagination(page: page, pageCount: 1))
    }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: keyword, page: page, filters: [:]) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("Unused fixture detail") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("Unused fixture player") }
}

@MainActor final class CatPawSearchImprovementTests: XCTestCase {
    func testTrailingResultPublishesWithoutAnotherProvider() async throws {
        var values: [Int] = []
        let publisher = SearchSnapshotPublisher<Int>(interval: 0.03) { values.append($0) }
        publisher.submit(1); publisher.submit(2); publisher.submit(3)
        XCTAssertEqual(values, [1])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(values, [1, 3])
        publisher.submit(4); publisher.flush()
        XCTAssertEqual(values.last, 4)
    }
    func testCancelledSearchCannotPublishTrailingResults() async throws {
        var values: [Int] = []
        let publisher = SearchSnapshotPublisher<Int>(interval: 0.03) { values.append($0) }
        publisher.submit(1); publisher.submit(2); publisher.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(values, [1])
    }
    func testCacheExpiryAccountScopeAndLateGeneration() {
        var clock: TimeInterval = 100
        let memory = CatPawSearchMemory(now: { clock })
        let key = CatPawSearchMemory.Key(owner: "account-a", keyword: "film", page: 1, quick: false)
        let other = CatPawSearchMemory.Key(owner: "account-b", keyword: "film", page: 1, quick: false)
        let page = VideoPage(items: [.init(siteKey: "site", siteName: "Site", videoID: "1", title: "Film")], pagination: .init(page: 1, pageCount: 1))
        let generation = memory.lookup(key).0
        memory.insert(page, for: key, generation: generation)
        XCTAssertEqual(memory.lookup(key).1, page)
        XCTAssertNil(memory.lookup(other).1)
        clock += 31
        XCTAssertNil(memory.lookup(key).1)
        memory.invalidate()
        memory.insert(page, for: key, generation: generation)
        XCTAssertNil(memory.lookup(key).1, "A request from before an account change must not repopulate the cache")
        memory.insert(.init(items: [], pagination: .init(page: 1, pageCount: 1)), for: key, generation: memory.lookup(key).0)
        XCTAssertNil(memory.lookup(key).1)
    }
    func testRecentFastProvidersArePrioritizedAndCostsExpire() {
        var clock: TimeInterval = 100
        let memory = CatPawSearchMemory(now: { clock })
        memory.record(owner: "fast", elapsed: 0.15, succeeded: true)
        memory.record(owner: "failed", elapsed: 0.1, succeeded: false)
        XCTAssertLessThan(memory.priority(owner: "fast"), memory.priority(owner: "unknown"))
        XCTAssertGreaterThan(memory.priority(owner: "failed"), memory.priority(owner: "unknown"))
        clock += 1801
        XCTAssertEqual(memory.priority(owner: "fast"), memory.priority(owner: "unknown"))
        XCTAssertEqual(AppEnvironment.catPawSearchConfiguration().httpMaximumConnectionsPerHost, 20)
    }
    func testProviderCacheAvoidsRepeatTransportButRespectsInvalidationAndPages() async throws {
        let client = CatPawSearchFixtureHTTPClient()
        let memory = CatPawSearchMemory()
        let provider = try NodeHTTPSpiderSiteProvider(site: .init(key: "nodejs_search_fixture", name: "Fixture", type: 3, api: "/spider/fixture/3", extra: ["okNodeRuntime": .bool(true)]), baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")), httpClient: client, aggregateSearchHTTPClient: client, searchMemory: memory)
        let first = try await provider.aggregateSearch(keyword: "film", page: 1, quick: false)
        XCTAssertEqual(first.items.count, 1)
        let repeated = try await provider.aggregateSearch(keyword: "film", page: 1, quick: false)
        XCTAssertEqual(first, repeated)
        var calls = await client.count
        XCTAssertEqual(calls, 1)
        _ = try await provider.aggregateSearch(keyword: "film", page: 2, quick: false)
        memory.invalidate()
        _ = try await provider.aggregateSearch(keyword: "film", page: 1, quick: false)
        calls = await client.count
        XCTAssertEqual(calls, 3)
        _ = try await provider.search(keyword: "film", page: 1, quick: false)
        calls = await client.count
        XCTAssertEqual(calls, 4, "Interactive requests retain their independent transport path")
    }
}
private actor CatPawSearchFixtureHTTPClient: HTTPClient {
    private(set) var count = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/init") { return .init(url: request.url, statusCode: 404, headers: [:], body: Data()) }
        count += 1
        let payload = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        let page = payload?["page"] as? String ?? "1"
        let json = #"{"list":[{"vod_id":"film-1","vod_name":"Film"}],"page":PAGE,"pagecount":2}"#.replacingOccurrences(of: "PAGE", with: page)
        return .init(url: request.url, statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}
