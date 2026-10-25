import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class SearchBrowseMigrationTests: XCTestCase {
    func testTVBoxPrioritizesPositiveResultsAndOmitsOnlyUnsupportedDexSites() throws {
        let bridge = AndroidDexBridgeClient(runtimePrerequisite: { XCTFail("ordering must not start Android") })
        func dex(_ key: String, searchable: Int = 1) throws -> AndroidDexSpiderSiteProvider {
            try AndroidDexSpiderSiteProvider(
                site: SiteConfiguration(key: key, name: key, type: 3, api: "csp_Fixture", searchable: searchable),
                configurationID: UUID(), configurationHosts: [], jarReference: "https://fixture.invalid/spider.jar",
                baseURL: nil, bridge: bridge)
        }
        let slow = try dex("slow"), unknown = try dex("unknown"), fast = try dex("fast")
        let empty = try dex("empty"), disabled = try dex("disabled", searchable: 0)
        let failed = try dex("failed")
        slow.searchPerformance.record(elapsed: 5, resultCount: 20, succeeded: true)
        fast.searchPerformance.record(elapsed: 1, resultCount: 20, succeeded: true)
        empty.searchPerformance.record(elapsed: 0.1, resultCount: 0, succeeded: true)
        failed.searchPerformance.record(elapsed: 0.1, resultCount: 0, succeeded: false)
        let all = [failed, empty, slow, unknown, disabled, fast]
        let ordered = AppState.orderedSearchProviders(catalog: all.map(\.site),
            providers: Dictionary(uniqueKeysWithValues: all.map { ($0.site.key, $0 as SiteProvider) }))
        XCTAssertEqual(ordered.map { $0.site.key }, ["fast", "slow", "unknown", "empty", "failed"])
        XCTAssertTrue(AppState.orderedSearchProviders(catalog: [disabled.site],
            providers: ["disabled": disabled], selectedKeys: ["disabled"]).isEmpty)
        // A fresh provider with the same key cannot inherit old account/JAR performance.
        XCTAssertEqual(try dex("fast").aggregateSearchPriority, unknown.aggregateSearchPriority)
    }

    func testRepeatedTVBoxStyleSearchPreservesSessionAndNewKeywordRejectsOldResults() async throws {
        let recorder = SearchAppRequestRecorder()
        let provider = SearchAppFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider])
        state.seedCategoryHomeForTesting(
            record: StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data()),
            provider: provider, home: SiteHome(categories: [], recommendations: []))
        state.search("first")
        let session = state.searchBrowseSessionID
        state.search(" first ")
        XCTAssertEqual(state.searchBrowseSessionID, session)
        try await Task.sleep(nanoseconds: 10_000_000)
        state.search("second")
        XCTAssertNotEqual(state.searchBrowseSessionID, session)
        for _ in 0..<100 where state.isSearching {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.searchResults.isEmpty)
        XCTAssertTrue(state.searchResults.allSatisfy { $0.title.hasPrefix("second") })
        state.cancelSearch()
    }

    func testFirstResultPublishesBeforeSlowTrailingBatch() async throws {
        var displayed: [Int] = []
        let publisher = SearchSnapshotPublisher<Int> { displayed.append($0) }
        publisher.submit(1)
        XCTAssertEqual(displayed, [1])
        publisher.submit(2)
        XCTAssertEqual(displayed, [1])
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(displayed, [1, 2])
        publisher.cancel()
    }
    func summary(_ id: String, site: String = "source", title: String? = nil) -> VideoSummary {
        VideoSummary(siteKey: site, siteName: "来源 \(site)", videoID: id, title: title ?? id, year: "2026")
    }

    func testRefreshCommitsOnlySuccessfulProvidersAndAcceptsEmptySuccess() {
        let old = [summary("old-a", site: "a"), summary("old-b", site: "b")]
        let incoming = [summary("new-a", site: "a"), summary("partial-b", site: "b")]
        XCTAssertEqual(SearchRefreshSnapshot.merge(retained: old, incoming: incoming, successfulKeys: []), old)
        let partial = SearchRefreshSnapshot.merge(retained: old, incoming: incoming, successfulKeys: ["a"])
        XCTAssertEqual(Set(partial.map(\.videoID)), Set(["new-a", "old-b"]))
        let empty = SearchRefreshSnapshot.merge(retained: old, incoming: [], successfulKeys: ["a"])
        XCTAssertEqual(empty, [old[1]])
    }

    func testOnlySourcesWithResultsAppearAndArrivalOrderStaysStable() {
        let state = AppState(environment: nil)
        state.seedSearchPagingForTesting(["empty": SearchPageCursor(keyword: "film")], order: ["empty"])
        state.seedSearchResultsForTesting([summary("a", site: "b"), summary("alternate", site: "a", title: "a")])
        XCTAssertEqual(Set(state.searchSiteOptions.map(\.key)), Set(["a", "b"]))
        XCTAssertEqual(state.searchSiteOptions.reduce(0) { $0 + $1.resultCount }, 2)
        let memory = SearchBrowseMemory()
        let first = memory.orderedSources(state.searchSiteOptions).map(\.key)
        state.seedSearchResultsForTesting([summary("c", site: "c")] + state.searchResults.reversed())
        XCTAssertEqual(Array(memory.orderedSources(state.searchSiteOptions).map(\.key).prefix(2)), first)
        state.seedSearchResultsForTesting([])
        XCTAssertTrue(memory.orderedSources(state.searchSiteOptions).isEmpty)
    }

    func testRefreshRetriesFailedSourceWithoutFetchingHealthySourceOrClearingResults() async {
        let recorder = SearchAppRequestRecorder()
        let provider = SearchAppFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: ["source": provider])
        var failed = SearchPageCursor(keyword: "film")
        failed.fail("offline")
        state.seedSearchPagingForTesting(["source": failed, "healthy": SearchPageCursor(keyword: "film")], order: ["healthy", "source"])
        let retained = summary("retained", site: "healthy")
        state.seedSearchResultsForTesting([retained])
        await state.refreshSearchPage()
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(state.searchResults.contains(retained))
        XCTAssertEqual(state.searchPaging.cursors["healthy"]?.nextPage, 1)
        XCTAssertEqual(state.searchPaging.cursors["source"]?.nextPage, 2)
        XCTAssertNil(state.searchPaging.cursors["source"]?.error)
    }

    func testNativeLiveGridReusesVisibleCardsAndPreservesClipAcrossEPGUpdates() async throws {
        let state = AppState(environment: nil)
        let session = LiveBrowserSession(preferences: LiveBrowserPreferenceStore(storageKey: "test.native.live"))
        let owner = UUID(); session.activate(owner: owner)
        defer { session.deactivate(owner: owner) }
        let channels = (0..<1000).map { LiveChannel(groupName: "Fixture", name: "Channel \($0)", streams: []) }
        let source = LiveSourceID.xtream(UUID())
        let host = NSHostingView(rootView: NativeLiveChannelPage(channels: channels,
            source: source, sourceName: "Fixture", catalog: nil, session: session, browseKey: "fixture")
            .environmentObject(state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let scroll = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? LiveChannelScrollView }.first)
        XCTAssertEqual(scroll.collection.numberOfItems(inSection: 0), 1000)
        XCTAssertGreaterThan(scroll.collection.visibleItems().count, 0)
        XCTAssertLessThan(scroll.collection.visibleItems().count, 30)
        for y in [1000.0, 4000.0, 9000.0] {
            scroll.contentView.scroll(to: .init(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertLessThan(scroll.collection.visibleItems().count, 30)
        }
        let offset = scroll.contentView.bounds.origin
        state.liveEPG.objectWillChange.send()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        XCTAssertNotNil(session.channelAnchors["fixture"])
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-UX109-Visuals", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            host.appearance = NSAppearance(named: appearance)
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("live-\(name).png"))
        }

        XCTAssertTrue(scroll.collection.visibleItems().allSatisfy { !String(describing: type(of: $0.view)).contains("Hosting") })
    }

    func testReadingOrderAndPrimaryStayStableUntilAccepted() {
        let presentation = SearchStablePresentation()
        let a = summary("a"), b = summary("b")
        let initial = SearchResultAggregator.cluster([a, b])
        XCTAssertEqual(presentation.update(initial).map(\.id), initial.map(\.id))
        presentation.atTop = false
        let alternate = summary("alternate", site: "other", title: "a")
        let incoming = SearchResultAggregator.cluster([b, alternate, a])
        let display = presentation.update(incoming)
        XCTAssertEqual(display.map(\.id), initial.map(\.id))
        XCTAssertEqual(display[0].primary?.id, a.id)
        XCTAssertEqual(display[0].sources.count, 2)
        XCTAssertTrue(presentation.hasPendingOrder)
        presentation.acceptOrder()
        XCTAssertEqual(presentation.update(incoming).map(\.id), incoming.map(\.id))
    }

    func testRoundRobinDoesNotAutomaticallyRetryFailuresOrRestrictedDeepPages() {
        var state = SearchPagingState()
        state.order = ["a", "b", "c"]
        state.cursors = Dictionary(uniqueKeysWithValues: state.order.map { ($0, SearchPageCursor(keyword: "x")) })
        state.cursors["b"]?.error = "offline"
        state.lastServed = "a"
        XCTAssertEqual(state.eligible(selected: nil, retry: false), ["c", "a"])
        XCTAssertEqual(state.eligible(selected: "b", retry: true), ["b"])
        state.restricted.insert("c")
        XCTAssertTrue(state.eligible(selected: "c", retry: true).contains("c"), "First-page retry remains available")
        state.cursors["c"]?.accept(VideoPage(items: [summary("c")], pagination: Pagination(page: 1, pageCount: nil)), requestedPage: 1)
        XCTAssertTrue(state.eligible(selected: "c", retry: true).isEmpty)
    }

    func testNativeSearchKeepsNavigationAndCollectionDuringFirstResultsAndSourceUpdates() async throws {
        let defaults = UserDefaults.standard
        let mergeKey = SearchDisplayPreferences.mergesDuplicateTitlesKey
        let previousMergePreference = defaults.object(forKey: mergeKey)
        defaults.set(true, forKey: mergeKey)
        defer {
            if let previousMergePreference {
                defaults.set(previousMergePreference, forKey: mergeKey)
            } else {
                defaults.removeObject(forKey: mergeKey)
            }
        }
        let state = AppState(environment: nil)
        let host = NSHostingView(rootView: SearchView().environmentObject(state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        func descendants<T: NSView>(_ type: T.Type) -> [T] {
            BrowserKeyboardView.descendants(of: host).compactMap { $0 as? T }
        }
        let navigation = try XCTUnwrap(descendants(NativeBrowseCategoryNavigation.self).first)
        let collection = try XCTUnwrap(descendants(PosterNativePageCollectionView.self).first)
        let scroll = try XCTUnwrap(descendants(PosterNativePageScrollView.self).first)
        let navY = navigation.convert(navigation.bounds, to: host).minY
        state.seedSearchResultsForTesting((0..<100).map { summary("\($0)", site: "s\($0 % 12)") })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(descendants(PosterNativePageCollectionView.self).first === collection)
        XCTAssertTrue(descendants(NativeBrowseCategoryNavigation.self).first === navigation)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 100)
        XCTAssertEqual(navigation.convert(navigation.bounds, to: host).minY, navY, accuracy: 1)
        XCTAssertEqual(navigation.segments.controlSize, .large)
        XCTAssertFalse(navigation.more.isHidden)
        scroll.contentView.scroll(to: .init(x: 0, y: 450))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 60_000_000)
        let offset = scroll.contentView.bounds.minY
        let size = (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize
        state.seedSearchResultsForTesting(state.searchResults + [summary("alternate", site: "new", title: "0")])
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 100)
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
        XCTAssertEqual((collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize, size)
        window.setContentSize(.init(width: 1250, height: 1000))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(scroll.contentSize.height, 800)
    }

    func testBackStopsContinuationBeforeLeavingSearch() async throws {
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder())
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider])
        state.presentHomeSearch()
        state.seedSearchPagingForTesting(["source": SearchPageCursor(keyword: "film")], order: ["source"])
        let task = Task { await state.loadMoreSearchResults() }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(state.searchPaging.loading)
        XCTAssertTrue(state.performSearchBackAction())
        XCTAssertTrue(state.isHomeSearchPresented)
        XCTAssertTrue(state.searchPaging.stopped)
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertEqual(state.searchTermination, .cancelled)
    }

    func testContinuationIsSingleFlightAndCancellationDoesNotRestartAutomatically() async throws {
        let recorder = SearchAppRequestRecorder()
        let provider = SearchAppFixture(recorder: recorder)
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider])
        state.seedSearchPagingForTesting(["source": SearchPageCursor(keyword: "film")], order: ["source"])
        async let first = state.loadMoreSearchResults()
        async let second = state.loadMoreSearchResults()
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.searchPaging.cursors["source"]?.nextPage, 2)
        state.cancelSearch()
        let automatic = await state.loadMoreSearchResults()
        XCTAssertFalse(automatic)
        XCTAssertTrue(state.searchPaging.stopped)
        let resumed = await state.loadMoreSearchResults(retry: true)
        XCTAssertTrue(resumed)
        XCTAssertEqual(state.searchResults.count, 2)
    }
}

private actor SearchAppRequestRecorder {
    var count = 0
    func record() { count += 1 }
}

private struct SearchAppFixture: SiteProvider {
    let recorder: SearchAppRequestRecorder
    let site = SiteConfiguration(key: "source", name: "Source", type: 1, api: "https://example.invalid")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { try await search(keyword: "film", page: page, quick: false) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record()
        try await Task.sleep(nanoseconds: 50_000_000)
        var pagination = Pagination(page: page, pageCount: 4)
        pagination.continuation = page < 4 ? .more : .end
        return VideoPage(items: [VideoSummary(siteKey: site.key, siteName: site.name, videoID: "\(page)", title: "\(keyword) \(page)")], pagination: pagination)
    }
}
