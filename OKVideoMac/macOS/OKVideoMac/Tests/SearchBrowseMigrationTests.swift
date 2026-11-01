import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class SearchBrowseMigrationTests: XCTestCase {
    func testRelatedAndHomeUseSameCustomScopeWithoutStartingExcludedProvider() async throws {
        let selectedRecorder = SearchAppRequestRecorder(), excludedRecorder = SearchAppRequestRecorder()
        let selected = SearchAppFixture(recorder: selectedRecorder)
        let excluded = SearchAppFixture(recorder: excludedRecorder,
            site: .init(key: "excluded", name: "Excluded", type: 1, api: "https://fixture.invalid"))
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: selected, home: .init(categories: [], recommendations: []),
            additionalProviders: ["excluded": excluded], searchScope: .init(mode: .custom, selectedSiteKeys: ["source"]))
        state.search("film")
        for _ in 0..<200 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        let page = TMDBRelatedPage(kind: .search, title: "film", source: .init(siteKey: "source", siteName: "Source", videoID: "1", title: "Origin"), configurationID: record.id)
        try await state.searchRelatedWork(page, refresh: false)
        XCTAssertEqual(page.searchPaging.order, ["source"])
        XCTAssertEqual(page.results, state.searchResults)
        let excludedCalls = await excludedRecorder.count, selectedCalls = await selectedRecorder.count
        XCTAssertEqual(excludedCalls, 0); XCTAssertEqual(selectedCalls, 2)
    }

    func testRelatedSearchAndHomeShareResultsFooterAndAutomaticBudgetReplay() async throws {
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder(), largeFinalPage: true)
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: .init(categories: [], recommendations: []))
        state.search("film")
        for _ in 0..<200 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        let home = SearchScreenSnapshot(state: state)
        let page = TMDBRelatedPage(kind: .search, title: "film", source: .init(siteKey: "source", siteName: "Source", videoID: "origin", title: "Origin"), configurationID: record.id)
        let browser = TMDBRelatedBrowser(); browser.pages = [page]
        browser.load(page, state: state); await page.task?.value
        let related = SearchScreenSnapshot(page: page)
        XCTAssertEqual(home.results, related.results)
        XCTAssertEqual(home.sites, related.sites)
        XCTAssertEqual(home.footer, related.footer)
        for merge in [true, false] {
            for sort in SearchResultSortOrder.allCases {
                XCTAssertEqual(SearchResultPresentation.clusters(from: home.results, keyword: home.keyword, mergesDuplicates: merge, sortOrder: sort),
                    SearchResultPresentation.clusters(from: related.results, keyword: related.keyword, mergesDuplicates: merge, sortOrder: sort))
            }
        }
        XCTAssertNil(related.footer.actionTitle)
        XCTAssertTrue(related.footer.scrollDrivenLoading)
        let first = await browser.loadMore(page, state: state)
        XCTAssertTrue(first); XCTAssertEqual(page.results.count, 240)
        let last = await browser.loadMore(page, state: state)
        XCTAssertTrue(last); XCTAssertEqual(page.results.count, 250)
        XCTAssertFalse(SearchScreenSnapshot(page: page).footer.hasMore)
        XCTAssertEqual(state.searchResults.count, 120, "Related paging must not mutate home")
        XCTAssertEqual(page.maximumRetained, SearchPagingState.initialMaximumResults * 3)
        browser.clear()
    }

    func testRelatedBackPreservesActorFilterHomeQueryAndSearchSourceSelection() async throws {
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder())
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: .init(categories: [], recommendations: []))
        state.searchDraftKeyword = "Original home query"
        let candidate = try relatedCandidate()
        let person = TMDBRelatedPage(kind: .person, title: "Actor", source: .init(siteKey: "source", siteName: "Source", videoID: "origin", title: "Origin"), configurationID: record.id)
        person.works = [candidate]; person.filter = "movie"; person.displayedCount = 96
        let browser = TMDBRelatedBrowser(); browser.pages = [person]
        browser.select(try XCTUnwrap(person.items.first), page: person, state: state)
        let page = try XCTUnwrap(browser.pages.last)
        await page.task?.value
        XCTAssertEqual(state.sidebarVideoSearchText, "Film")
        XCTAssertEqual(state.searchDraftKeyword, "Original home query")
        page.selectedSearchSiteKey = "source"
        state.sidebarVideoSearchText = "Draft retained"
        browser.select(try XCTUnwrap(page.results.first), page: page, state: state)
        XCTAssertEqual(browser.pages.last?.kind, .detail)
        browser.pop()
        XCTAssertTrue(browser.pages.last === page)
        XCTAssertEqual(page.selectedSearchSiteKey, "source")
        XCTAssertEqual(state.sidebarVideoSearchText, "Draft retained")
        browser.pop()
        XCTAssertTrue(browser.pages.last === person)
        XCTAssertEqual(person.filter, "movie"); XCTAssertEqual(person.displayedCount, 96)
        XCTAssertEqual(state.sidebarVideoSearchText, "Original home query")
        XCTAssertNil(state.relatedSearchSubmit)
        browser.clear()
    }

    func testRelatedSidebarReplacementAndStopRejectStaleCompletion() async throws {
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder())
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: .init(categories: [], recommendations: []))
        state.searchDraftKeyword = "Parent"
        let actor = TMDBRelatedPage(kind: .person, title: "Actor", source: .init(siteKey: "source", siteName: "Source", videoID: "origin", title: "Origin"), configurationID: record.id)
        actor.works = [try relatedCandidate()]
        let browser = TMDBRelatedBrowser(); browser.pages = [actor]
        browser.select(try XCTUnwrap(actor.items.first), page: actor, state: state)
        let old = try XCTUnwrap(browser.pages.last)
        state.searchFromSidebar("New film")
        let current = try XCTUnwrap(browser.pages.last)
        XCTAssertNotEqual(current.id, old.id); XCTAssertNil(current.candidate)
        await current.task?.value
        XCTAssertTrue(current.results.allSatisfy { $0.title.hasPrefix("New film") })
        XCTAssertTrue(old.results.isEmpty)
        XCTAssertEqual(state.searchDraftKeyword, "Parent")
        browser.cancelSearch(current)
        let stoppedCount = current.results.count
        let automatic = await browser.loadMore(current, state: state)
        XCTAssertFalse(automatic); XCTAssertEqual(current.results.count, stoppedCount)
        let resumed = await browser.loadMore(current, state: state, retry: true)
        XCTAssertTrue(resumed)
        browser.clear(); XCTAssertNil(state.relatedSearchDraft)
    }

    func testRelatedFailedRefreshKeepsResultsAndRequiresExplicitRetry() async throws {
        let recorder = SearchAppRequestRecorder()
        let provider = SearchAppFixture(recorder: recorder)
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: .init(categories: [], recommendations: []))
        let page = TMDBRelatedPage(kind: .search, title: "film", source: .init(siteKey: "source", siteName: "Source", videoID: "origin", title: "Origin"), configurationID: record.id)
        let browser = TMDBRelatedBrowser(); browser.pages = [page]
        browser.load(page, state: state); await page.task?.value
        let original = page.results
        await recorder.setFailure(true)
        await browser.refreshSearch(page, state: state, force: true)
        XCTAssertEqual(page.results, original); XCTAssertEqual(page.failures.count, 1)
        XCTAssertFalse(SearchScreenSnapshot(page: page).footer.automaticLoading)
        XCTAssertNotNil(SearchScreenSnapshot(page: page).footer.actionTitle)
        await recorder.setFailure(false)
        await browser.refreshSearch(page, state: state, force: false)
        XCTAssertTrue(page.failures.isEmpty); XCTAssertEqual(page.results, original)
        XCTAssertTrue(SearchScreenSnapshot(page: page).footer.automaticLoading)
        browser.clear()
    }

    func testRelatedFolderKeepsProviderIdentifiersAndReturnsToSearch() async throws {
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder())
        let state = AppState(environment: nil)
        let record = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: .init(categories: [], recommendations: []))
        let folder = VideoSummary(siteKey: "source", siteName: "Source", videoID: "opaque/folder", title: "Folder", tag: "folder")
        let page = TMDBRelatedPage(kind: .search, title: "film", source: folder, configurationID: record.id)
        let browser = TMDBRelatedBrowser(); browser.pages = [page]
        browser.select(folder, page: page, state: state)
        let next = try XCTUnwrap(browser.pages.last)
        XCTAssertEqual(next.kind, .folder); XCTAssertEqual(next.source.videoID, "opaque/folder")
        await next.task?.value; XCTAssertEqual(next.results.count, 1)
        let more = await browser.loadMore(next, state: state)
        XCTAssertTrue(more); XCTAssertEqual(next.results.count, 2)
        browser.pop(); XCTAssertTrue(browser.pages.last === page)
        browser.clear()
    }

    func testKnownTMDBArtworkRequiresMatchingIdentityAndNeverChangesSource() throws {
        let candidate = try relatedCandidate()
        let url = URL(string: "https://fixture.invalid/cloud-logo.png")!
        let source = VideoSummary(siteKey: "source", siteName: "Source", videoID: "opaque:123", title: "Film", posterURL: url, year: "2025", categoryName: "电影")
        let display = SearchArtworkPresentation.summary(source, candidate: candidate)
        XCTAssertNotEqual(display.posterURL, url)
        XCTAssertEqual(source.posterURL, url)
        XCTAssertEqual(display.id, source.id); XCTAssertEqual(display.videoID, source.videoID)
        var conflict = source; conflict.year = "2024"
        XCTAssertEqual(SearchArtworkPresentation.summary(conflict, candidate: candidate), conflict)
        conflict = source; conflict.categoryName = "电视剧"
        XCTAssertEqual(SearchArtworkPresentation.summary(conflict, candidate: candidate), conflict)
        conflict = source; conflict.year = nil
        XCTAssertEqual(SearchArtworkPresentation.summary(conflict, candidate: candidate), conflict)
    }

    func testNativeActorSearchUsesSameMergedGridSourceRowAndCardGeometryAsHome() async throws {
        let defaults = UserDefaults.standard, key = SearchDisplayPreferences.mergesDuplicateTitlesKey
        let before = defaults.object(forKey: key); defaults.set(true, forKey: key)
        defer { if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let state = AppState(environment: nil)
        let rows = (0..<20).flatMap { index in
            ["a", "b"].map { site in VideoSummary(siteKey: site, siteName: site.uppercased(),
                videoID: "\(site)-\(index)", title: "Film \(index)", year: "2025", categoryName: "电影") }
        }
        state.seedSearchResultsForTesting(rows)
        let page = TMDBRelatedPage(kind: .search, title: "", source: rows[0], configurationID: UUID(), candidate: try relatedCandidate())
        page.results = rows
        let browser = TMDBRelatedBrowser(); browser.pages = [page]
        let home = NSHostingView(rootView: SearchView().environmentObject(state))
        let related = NSHostingView(rootView: TMDBRelatedPageView(browser: browser, page: page, active: true).environmentObject(state))
        var sizes: [NSSize] = []
        for host in [home as NSView, related as NSView] {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
            let descendants = BrowserKeyboardView.descendants(of: host)
            let collection = try XCTUnwrap(descendants.compactMap { $0 as? PosterNativePageCollectionView }.first)
            let row = try XCTUnwrap(descendants.compactMap { $0 as? NativeBrowseCategoryNavigation }.first)
            XCTAssertEqual(collection.numberOfItems(inSection: 0), 20)
            XCTAssertEqual(row.segments.segmentCount, 3, "All results plus the two provider filters")
            sizes.append(try XCTUnwrap((collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize))
            window.close()
        }
        XCTAssertEqual(sizes[0], sizes[1])
        browser.clear()
    }

    private func relatedCandidate() throws -> TMDBCandidate {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":123,"title":"Film","release_date":"2025-01-01","poster_path":"/film.jpg"}"#.utf8))
        return .init(reference: .init(type: .movie, id: 123), work: work)
    }

    func testBudgetedFinalPageCanBeFullyRecoveredByScrollContinuation() async throws {
        let recorder = SearchAppRequestRecorder()
        let provider = SearchAppFixture(recorder: recorder, largeFinalPage: true)
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider])
        state.seedCategoryHomeForTesting(
            record: StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data()),
            provider: provider, home: SiteHome(categories: [], recommendations: []))
        state.search("film")
        for _ in 0..<200 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(state.searchResults.count, 120)
        XCTAssertTrue(state.searchPaging.cursors["source"]?.ended == true)
        XCTAssertTrue(state.searchPaginationFooter.hasMore, "A truncated final page must stay resumable")
        XCTAssertTrue(state.searchPaginationFooter.automaticLoading)
        XCTAssertTrue(state.searchPaginationFooter.scrollDrivenLoading)
        XCTAssertNil(state.searchPaginationFooter.actionTitle, "Healthy results must not require a continue button")
        let resumed = await state.loadMoreSearchResults()
        XCTAssertTrue(resumed)
        XCTAssertEqual(state.searchResults.count, 240)
        XCTAssertTrue(state.searchPaginationFooter.automaticLoading)
        let finished = await state.loadMoreSearchResults()
        XCTAssertTrue(finished)
        XCTAssertEqual(Set(state.searchResults.map(\.videoID)), Set((0..<250).map(String.init)))
        XCTAssertFalse(state.searchPaginationFooter.hasMore)
        XCTAssertTrue(state.searchPaging.deferredPages.isEmpty)
        let calls = await recorder.count
        XCTAssertEqual(calls, 3)
        state.cancelSearch()
    }

    func testFailedBudgetReplayRemainsRetryableWithoutAutomaticRetryLoop() {
        var paging = SearchPagingState()
        paging.order = ["source"]
        paging.cursors["source"] = SearchPageCursor(keyword: "film")
        paging.deferResults(["source": 1])
        paging.cursors["source"]?.fail("offline")
        XCTAssertTrue(paging.eligible(selected: nil, retry: false).isEmpty)
        XCTAssertEqual(paging.eligible(selected: nil, retry: true), ["source"])
        XCTAssertEqual(paging.cursorForLoading("source")?.nextPage, 1)
    }

    func testLearnedOrderingKeepsFastEmptySourcesAndAllEligibleSources() throws {
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
        let all = [failed, empty, slow, unknown, disabled, fast]
        let keys = Dictionary(uniqueKeysWithValues: all.map { ($0.site.key, SearchPerformanceStore.key(namespace: "test", identity: $0.site.key)) })
        let performance = SearchPerformanceStore()
        for _ in 0..<4 {
            for (source, seconds, status, relevant) in [(slow, 5.0, SearchAttemptStatus.success, true),
                    (fast, 0.2, .success, true), (empty, 0.1, .success, false), (failed, 30.0, .timeout, false)] {
                performance.record(.init(siteKey: source.site.key, elapsed: seconds, status: status, hasRelevantResults: relevant), key: keys[source.site.key]!)
            }
        }
        let providers = Dictionary(uniqueKeysWithValues: all.map { ($0.site.key, $0 as SiteProvider) })
        let ordered = AppState.orderedSearchProviders(catalog: all.map(\.site), providers: providers,
            performance: performance, performanceKeys: keys)
        XCTAssertEqual(ordered.map { $0.site.key }, ["empty", "fast", "unknown", "slow", "failed"])
        XCTAssertTrue(AppState.orderedSearchProviders(catalog: [disabled.site], providers: providers,
            selectedKeys: ["disabled"], performance: performance, performanceKeys: keys).isEmpty)
        // Explicit scope selection cannot be widened by learned priority.
        XCTAssertEqual(AppState.orderedSearchProviders(catalog: all.map(\.site), providers: providers,
            selectedKeys: ["slow"], performance: performance, performanceKeys: keys).map { $0.site.key }, ["slow"])
        XCTAssertEqual(AppState.aggregateSearchPolicies(ordered)["fast"]?.maximumGroupConcurrency, 20)
    }

    func testSearchRecordsPersistentLearningThroughProductionPipeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("performance.json")
        let performance = SearchPerformanceStore(file: file)
        let provider = SearchAppFixture(recorder: SearchAppRequestRecorder())
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider], searchPerformance: performance)
        state.seedCategoryHomeForTesting(record: StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data()),
            provider: provider, home: SiteHome(categories: [], recommendations: []))
        state.search("film")
        for _ in 0..<200 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.isSearching)
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertEqual(performance.entryCount, 1)
        try performance.flush()
        XCTAssertEqual(SearchPerformanceStore(file: file).entryCount, 1)
        XCTAssertTrue(state.searchPaginationFooter.automaticLoading)
        XCTAssertNil(state.searchPaginationFooter.actionTitle)
        state.cancelSearch()
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
    var fails = false
    func record() { count += 1 }
    func setFailure(_ value: Bool) { fails = value }
}

private struct SearchAppFixture: SiteProvider {
    let recorder: SearchAppRequestRecorder
    var largeFinalPage = false
    var site = SiteConfiguration(key: "source", name: "Source", type: 1, api: "https://example.invalid")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { try await search(keyword: "film", page: page, quick: false) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record()
        if await recorder.fails { throw AppError.site("Fixture offline") }
        try await Task.sleep(nanoseconds: 50_000_000)
        if largeFinalPage {
            return VideoPage(items: (0..<250).map { VideoSummary(siteKey: site.key, siteName: site.name,
                videoID: String($0), title: "\(keyword) \($0)") }, pagination: Pagination(page: 1, pageCount: 1))
        }
        var pagination = Pagination(page: page, pageCount: 4)
        pagination.continuation = page < 4 ? .more : .end
        return VideoPage(items: [VideoSummary(siteKey: site.key, siteName: site.name, videoID: "\(page)", title: "\(keyword) \(page)")], pagination: pagination)
    }
}
