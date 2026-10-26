import XCTest
import AppKit
import SwiftUI
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class TMDBDetailTests: XCTestCase {
    func testMovieVersionsKeepWorkSynopsisBeforeAndAfterTMDB() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1284041,"title":"最后孤屋","original_title":"The Last House","overview":"影片中文简介","runtime":117,"release_date":"2026-08-06"}"#.utf8))
        let resources = ["1080p中英字幕", "The.Last.House.2026.1080p.WEB-DL", "The.Last.House.2026.2160p.WEB-DL"].map { PlayEpisode(name: $0, url: "opaque:unchanged:\($0)") }
        let source = PlaySource(name: "夸父原1", episodes: resources)
        let detail = VideoDetail(summary: .init(siteKey: "wogg", siteName: "玩偶哥哥", videoID: "last", title: "最后孤屋"), synopsis: "源站影片简介", playSources: [source])
        for metadata in [nil, work] {
            let info = TMDBEpisodeInformation.make(detail: detail, work: metadata, season: nil, source: source, episode: resources[2])
            XCTAssertEqual(info.title, "最后孤屋")
            XCTAssertEqual(info.overview, metadata == nil ? "源站影片简介" : "影片中文简介")
            XCTAssertFalse(TMDBEpisodeInformation.isSeries(detail: detail, work: metadata, season: nil))
            XCTAssertFalse(info.title.contains("2160p"))
        }
        XCTAssertEqual(detail.playSources[0].episodes.map(\.url), resources.map(\.url))
    }

    func testHeroActionFrameDoesNotMoveWhenInformationFillsOrWraps() async throws {
        let model = TMDBDetailModel()
        let detail = VideoDetail(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "最后孤屋"))
        for width in [500.0, 900.0, 1600.0] {
            func view(_ information: TMDBEpisodeInformation) -> some View {
                TMDBHeroView(metadata: model, detail: detail, information: information, width: width, viewportHeight: 1000,
                    onSynopsis: { _ in }) {
                        Color.green.frame(height: 86).background(TMDBAuditAnchor())
                    }
            }
            let empty = TMDBEpisodeInformation(title: "", facts: "", overview: "")
            let host = NSHostingView(rootView: view(empty))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
            func measured() throws -> CGRect {
                let anchor = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).first { $0.identifier?.rawValue == "tmdb-audit-actions" })
                return anchor.convert(anchor.bounds, to: host)
            }
            let before = try measured(); XCTAssertGreaterThan(before.width, 0)
            host.rootView = view(.init(title: String(repeating: "很长的电影信息", count: 20), facts: String(repeating: "2026 · 科幻 · 悬疑 · ", count: 20), overview: String(repeating: "很长的中文简介。", count: 100)))
            try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
            let after = try measured()
            XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "Buttons moved at width \(width)")
            XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
            XCTAssertEqual(after.size.height, before.size.height, accuracy: 0.5)
        }
    }

    func testIdentityCacheAvoidsRepeatedWholeLineNormalization() {
        let cache = TMDBSourceIdentityCache()
        let episodes = (1...400).map { PlayEpisode(name: "第 \($0) 集", url: "https://example.invalid/video/\($0)?token=old") }
        let source = PlaySource(name: "夸克原画", episodes: episodes)
        let identity = cache.identity(source)
        for _ in 0..<100 { XCTAssertEqual(cache.identity(source), identity) }
        XCTAssertEqual(cache.computationCount, 1)
        var changed = source; changed.episodes.append(.init(name: "第 401 集", url: "https://example.invalid/video/401"))
        XCTAssertNotEqual(cache.identity(changed), identity)
        XCTAssertEqual(cache.computationCount, 2)
        let other = PlaySource(name: "百度原画", episodes: [.init(name: "第 1 集", url: "https://example.invalid/baidu/1")])
        XCTAssertNotEqual(cache.identity(other), identity)
        XCTAssertEqual(cache.identity(changed), changed.stableIdentity)
        XCTAssertEqual(cache.computationCount, 3)
    }

    func testRelatedSearchUsesAllRunnableCurrentCatalogSitesAndProgressiveHomeRanking() async throws {
        let recorder = TMDBSearchRecorder()
        let first = TMDBSearchProvider(site: .init(key: "quark", name: "Quark", type: 1, api: "https://example.invalid"), recorder: recorder, delay: 0)
        let second = TMDBSearchProvider(site: .init(key: "baidu", name: "Baidu", type: 1, api: "https://example.invalid"), recorder: recorder, delay: 150_000_000)
        let unrelated = TMDBSearchProvider(site: .init(key: "other-config", name: "Other", type: 1, api: "https://example.invalid"), recorder: recorder, delay: 0)
        let providers: [String: SiteProvider] = [first.site.key: first, second.site.key: second, unrelated.site.key: unrelated]
        let selected = AppState.orderedSearchProviders(catalog: [first.site, second.site], providers: providers)
        XCTAssertEqual(Set(selected.map { $0.site.key }), ["quark", "baidu"])
        XCTAssertEqual(AppState.orderedSearchProviders(catalog: [first.site, second.site], providers: providers, selectedKeys: ["quark"]).count, 1, "Homepage custom scope stays supported")
        var snapshots: [[VideoSummary]] = []
        for await event in MultiSiteSearch(maximumConcurrency: 20).search(providers: selected, keyword: "Film", providerPolicies: AppState.aggregateSearchPolicies(selected)) {
            if case .snapshot(let value) = event { snapshots.append(value.items) }
        }
        XCTAssertTrue(snapshots.contains { $0.count == 1 }, "First site's result must appear before the slow site")
        XCTAssertEqual(Set(snapshots.last?.map(\.siteKey) ?? []), ["quark", "baidu"])
        let requests = await recorder.keys
        XCTAssertEqual(Set(requests), ["quark", "baidu"])
    }

    /// Opt-in acceptance against captured, unedited responses from the running
    /// provider and the real FC API. Each case starts without metadata bindings.
    func testLiveSourceMatchingWithoutSavedBindings() async throws {
        guard let path = ProcessInfo.processInfo.environment["OKVIDEOMAC_TMDB_SOURCE_FIXTURES"] else {
            throw XCTSkip("Set a private real-provider fixture directory to run live acceptance")
        }
        let root = URL(fileURLWithPath: path)
        let site = SiteConfiguration(key: "nodejs_huban", name: "虎斑|4K", type: 3, api: "/spider/huban/3")
        var reports: [[String: Any]] = []
        for (file, title, year, expectedMatch) in [("luding-provider.json", "鹿鼎记2014", 2014, true), ("icecream-provider.json", "卖冰淇淋的人", 2026, true), ("qian-provider.json", "倩女幽魂", 1987, false), ("shendiao-provider.json", "神雕侠侣1995", 1995, false), ("tianlong-provider.json", "天龙八部", 2003, false)] {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let detail = try SpiderResponseMapper.detail(JSONDecoder().decode(JSONValue.self, from: data), site: site, baseURL: nil)
            XCTAssertEqual(detail.summary.title, title)
            let input = TMDBMatchInput(detail: detail)
            XCTAssertEqual(input.year, year)
            XCTAssertNil(input.type, "These real sources should exercise missing type inference")
            let originalSources = detail.playSources
            let model = TMDBDetailModel()
            guard let credentialFile = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_CREDENTIAL_FILE"] else { throw XCTSkip("A private direct credential is required") }
            let credential = try TMDBCredential(keychainData: Data(contentsOf: URL(fileURLWithPath: credentialFile)))
            let transport = TMDBAcceptanceTransport()
            await model.load(repository: TMDBRepository(client: TMDBClient(credential: credential, httpClient: transport)), key: UUID().uuidString, input: input)
            var report: [String: Any] = ["sourceTitle": title, "sourceYear": year, "candidateCount": model.candidates.count, "matched": model.selection != nil, "sourceURLsUnchanged": detail.playSources == originalSources]
            report["requests"] = await transport.events
            try JSONSerialization.data(withJSONObject: reports + [report], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("live-matching-results.json"))
            if expectedMatch {
                let selection = try XCTUnwrap(model.selection, "Expected fresh automatic match for \(title)")
                XCTAssertEqual(selection.work.year, year)
                XCTAssertEqual(model.binding?.manual, false)
                XCTAssertTrue(TMDBMatcher.assess(selection, input: input).corroboratedCast)
                report["tmdbID"] = selection.reference.id
                report["tmdbType"] = selection.reference.type.rawValue
                report["tmdbTitle"] = selection.work.displayTitle
                report["tmdbCast"] = selection.work.cast.prefix(10).map(\.name)
                if selection.reference.type == .tv {
                    await model.loadSeason(source: detail.playSources.first, category: detail.summary.categoryName)
                    XCTAssertEqual(model.season?.seasonNumber, 1)
                    report["season"] = model.season?.seasonNumber
                    report["sourceEpisodeCount"] = detail.playSources.first?.episodes.count
                }
            } else {
                XCTAssertNil(model.selection, "An undated same-title rival must still block automatic selection")
                XCTAssertTrue(model.candidates.contains { $0.work.year == nil })
            }
            XCTAssertEqual(detail.playSources, originalSources)
            reports.append(report)
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("live-matching-results.json"))
        }
    }

    func testWhitespaceCastEnrichesTVBoxEntryWithoutManualChoice() async throws {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"list":[{"vod_id":"opaque","vod_name":"测试电影","vod_year":"2023","type_name":"剧情 悬疑","vod_actor":"甲演员 乙演员 丙演员","vod_play_from":"主线","vod_play_url":"正片$opaque:movie"}]}"#.utf8))
        let detail = try SpiderResponseMapper.detail(payload, site: .init(key: "tvbox", name: "TVBox", type: 3, api: "csp_Test"), baseURL: nil)
        let service = TMDBDetailService(includesCast: true)
        let model = TMDBDetailModel()
        model.beginEntry(repository: TMDBRepository(client: service), key: "tvbox-space-cast", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        let navigation = model.navigationID
        model.receive(detail: detail, key: "tvbox-space-cast")
        for _ in 0..<200 {
            if model.selection != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.pageMode, .enhanced)
        XCTAssertEqual(model.selection?.reference, .init(type: .movie, id: 1))
        XCTAssertEqual(model.binding?.manual, false)
        XCTAssertEqual(model.navigationID, navigation)
        XCTAssertEqual(detail.playSources.first?.episodes.first?.url, "opaque:movie")
        model.cancel()
    }

    func testFirstEntryUsesVerifiedCacheEvenWithExpiredOrFailedLinks() async throws {
        let detail = Self.detail(), health = TMDBAvailability()
        let repository = TMDBRepository(client: TMDBDetailService())
        _ = try await repository.resolve(key: "a", input: .init(detail: detail))
        await health.finish(health.ticket(.images), outcome: .failure(.network))
        let model = TMDBDetailModel()
        model.beginEntry(repository: repository, key: "a", summary: detail.summary, availability: health, enabled: true)
        model.receive(detail: detail, key: "a")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.pageMode, .enhanced)
        XCTAssertEqual(model.selection?.reference.id, 1)
        XCTAssertTrue(model.usesUnifiedLayout)
        model.cancel()
    }

    func testSparseProviderDetailUsesCardIdentityAndStaysOnSamePage() async throws {
        let full = Self.detail(), model = TMDBDetailModel()
        var sparse = full; sparse.summary.year = nil; sparse.summary.categoryName = nil
        let repository = TMDBRepository(client: TMDBDetailService())
        model.beginEntry(repository: repository, key: "sparse", summary: full.summary, availability: TMDBAvailability(), enabled: true)
        let navigation = model.navigationID
        model.receive(detail: sparse, key: "sparse")
        for _ in 0..<200 {
            if model.selection != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.pageMode, .enhanced)
        XCTAssertEqual(model.binding?.manual, false)
        XCTAssertEqual(model.navigationID, navigation)
        model.cancel()
        // A subsequent unrelated entry cannot inherit the preceding card's year.
        model.beginEntry(repository: repository, key: "other", summary: sparse.summary, availability: TMDBAvailability(), enabled: true)
        model.receive(detail: sparse, key: "other")
        for _ in 0..<200 {
            if !model.isPreparing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(model.selection)
        model.cancel()
    }

    func testColdEntryEnrichesSamePageAfterFormerDeadline() async throws {
        let detail = Self.detail(), model = TMDBDetailModel()
        let service = TMDBDeferredDetailService()
        let repository = TMDBRepository(client: service)
        model.beginEntry(repository: repository, key: "a", summary: detail.summary,
                         availability: TMDBAvailability(), enabled: true, budget: 10)
        let navigation = model.navigationID
        model.receive(detail: detail, key: "a")
        XCTAssertEqual(model.pageMode, .source)
        XCTAssertTrue(model.usesUnifiedLayout)
        // Start the measured delay only after the transport has actually begun;
        // application startup scheduling must not masquerade as request latency.
        for _ in 0..<200 {
            if await service.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await service.started
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertNil(model.selection)
        await service.release()
        for _ in 0..<200 {
            if model.selection != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.pageMode, .enhanced)
        XCTAssertEqual(model.navigationID, navigation)
        XCTAssertEqual(model.binding?.manual, false)
        model.cancel()
    }

    func testExpiredCacheRemainsVisibleAfterRefreshFailure() async throws {
        var date = Date(timeIntervalSince1970: 1000)
        let service = TMDBDetailService()
        let repository = TMDBRepository(client: service, now: { date })
        let detail = Self.detail(), model = TMDBDetailModel()
        _ = try await repository.resolve(key: "a", input: .init(detail: detail))
        date.addTimeInterval(86400 * 8)
        await service.setFailure(true)
        model.beginEntry(repository: repository, key: "a", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        model.receive(detail: detail, key: "a")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.selection?.reference.id, 1)
        XCTAssertEqual(model.decisionReason, "refresh-failed-cache-retained")
        XCTAssertFalse(model.isPreparing)
        model.cancel()
    }

    func testLeavingAndReturningJoinsPreparationWithoutSwitchingOtherPage() async throws {
        let repository = TMDBRepository(client: TMDBDetailService(delay: 150_000_000))
        let detail = Self.detail(), model = TMDBDetailModel(), health = TMDBAvailability()
        model.beginEntry(repository: repository, key: "a", summary: detail.summary, availability: health, enabled: true)
        model.receive(detail: detail, key: "a")
        try await Task.sleep(nanoseconds: 30_000_000)
        model.beginEntry(repository: nil, key: "b", summary: detail.summary, availability: health, enabled: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.selection)
        model.beginEntry(repository: repository, key: "a", summary: detail.summary, availability: health, enabled: true)
        model.receive(detail: detail, key: "a")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.selection?.reference.id, 1)
        model.cancel()
    }

    func testOriginalChoiceCannotBeOverwrittenByBackgroundPreparation() async throws {
        let detail = Self.detail(), model = TMDBDetailModel()
        model.beginEntry(repository: TMDBRepository(client: TMDBDetailService(delay: 150_000_000)),
                         key: "a", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        model.receive(detail: detail, key: "a")
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.useOriginal()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.usesUnifiedLayout)
        XCTAssertTrue(model.originalRequested)
    }

    func testOfflineAndDeadlineKeepOriginalPageUsable() async {
        let detail = Self.detail()
        for client in [TMDBDetailService(fails: true), TMDBDetailService(delay: 1_000_000_000)] {
            let model = TMDBDetailModel()
            await model.load(repository: TMDBRepository(client: client), key: "source", input: .init(detail: detail), budget: 0.02)
            XCTAssertNil(model.selection)
            XCTAssertNil(model.actionError, "Background failures must not become a blocking detail-page error")
            XCTAssertEqual(detail.playSources.first?.episodes.first?.url, "opaque:1")
        }
    }

    func testLatePageCannotReplaceNewPage() async throws {
        let model = TMDBDetailModel()
        let old = Task { await model.load(repository: TMDBRepository(client: TMDBDetailService(delay: 100_000_000)), key: "old", input: .init(detail: Self.detail()), budget: 1) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.load(repository: TMDBRepository(client: TMDBDetailService(id: 2)), key: "new", input: .init(detail: Self.detail()), budget: 1)
        await old.value
        XCTAssertEqual(model.selection?.reference.id, 2)
    }

    func testDisabledEnrichmentAndMissingSeasonDoNotRemoveMatchedWork() async throws {
        let model = TMDBDetailModel(), detail = Self.detail()
        await model.load(repository: TMDBRepository(client: TMDBDetailService()), key: "source", input: .init(detail: detail))
        XCTAssertNotNil(model.selection)
        await model.loadSeason(source: detail.playSources.first, category: detail.summary.categoryName)
        XCTAssertNotNil(model.selection); XCTAssertNil(model.season)
        await model.useOriginal()
        XCTAssertNil(model.selection)
        await model.load(repository: nil, key: nil, input: .init(detail: detail))
        XCTAssertNil(model.selection)
    }

    func testSplitEpisodeCardsPreserveProviderPartLabel() {
        for name in ["第1集上", "第1集下", "第1集（上）", "第1集 下集"] {
            let episode = PlayEpisode(name: name, url: "opaque:part")
            let item = EpisodeNameParser.presentation(for: episode, categoryName: "电视剧")
            XCTAssertEqual(TMDBEpisodeCards.sourceName(item), name)
        }
    }

    func testNativeShelfRepeatedPagingGesturesResizeAndBoundaries() async throws {
        for cardWidth in [CGFloat(160), CGFloat(112)] {
            let host = NSHostingView(rootView: TMDBHorizontalShelf(count: 54, cardWidth: cardWidth, height: 180, identifier: "test.shelf") { index in
                Text("Card \(index)").frame(width: cardWidth, height: 150)
            })
            let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1000, height: 180), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            let probe = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBShelfScrollProbe }.first)
            let controller = try XCTUnwrap(probe.controller)
            let scroll = try XCTUnwrap(probe.enclosingScrollView)
            XCTAssertFalse(controller.canGoBack); XCTAssertTrue(controller.canGoForward)
            let stride = cardWidth + 14
            controller.page(forward: true, stride: stride)
            let first = controller.offset
            XCTAssertGreaterThan(first, 0); XCTAssertTrue(controller.canGoBack)
            controller.page(forward: true, stride: stride)
            XCTAssertGreaterThan(controller.offset, first, "Second click must advance beyond the first page")
            controller.page(forward: false, stride: stride)
            XCTAssertEqual(controller.offset, first, accuracy: 1)
            controller.page(forward: false, stride: stride)
            XCTAssertEqual(controller.offset, 0, accuracy: 1); XCTAssertFalse(controller.canGoBack)
            // Simulate a trackpad position between card boundaries, then click
            // before the async observer has delivered its change notification.
            scroll.contentView.scroll(to: .init(x: 417, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
            controller.page(forward: true, stride: stride)
            XCTAssertGreaterThan(controller.offset, 417)
            controller.page(forward: false, stride: stride)
            XCTAssertEqual(controller.offset, 417, accuracy: 1)
            for _ in 0..<80 { controller.page(forward: true, stride: stride) }
            XCTAssertEqual(controller.offset, controller.maximumOffset, accuracy: 1)
            XCTAssertFalse(controller.canGoForward); XCTAssertTrue(controller.canGoBack)
            controller.page(forward: false, stride: stride)
            XCTAssertTrue(controller.canGoForward)
            window.setContentSize(.init(width: 650, height: 180))
            try await Task.sleep(nanoseconds: 100_000_000)
            for _ in 0..<80 { controller.page(forward: false, stride: stride) }
            XCTAssertEqual(controller.offset, 0, accuracy: 1)
            XCTAssertFalse(controller.canGoBack); XCTAssertTrue(controller.canGoForward)
            scroll.contentView.scroll(to: .init(x: 220, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(controller.offset, 220, accuracy: 1, "Native gesture notifications must update button availability")
            window.setContentSize(.init(width: 20000, height: 180))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(controller.canGoForward); XCTAssertFalse(controller.canGoBack)
        }
    }

    func testDetailPresentationPreferenceAppliesImmediatelyAndSurvivesNewEntry() async throws {
        let suite = "TMDBDetailTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = TMDBNetworkRuntime(credentials: TMDBMemoryCredentialStore(try TMDBCredential(kind: .apiKey, value: "fixture")),
            defaults: defaults, transport: TMDBPolicyTransport())
        await runtime.checkConnections()
        let detail = Self.detail(), model = TMDBDetailModel()
        let repository = TMDBRepository(client: TMDBDetailService(delay: 80_000_000))
        model.beginEntry(repository: repository, key: "preference", summary: detail.summary, availability: runtime.availability,
            enabled: runtime.decisionForEntry().usesTMDB)
        model.receive(detail: detail, key: "preference")
        let navigation = model.navigationID
        let host = NSHostingView(rootView: VStack {
            DetailPresentationPicker(runtime: runtime)
            DetailView(detail: detail, metadata: model, runtime: runtime).environmentObject(AppState(environment: nil, tmdbRuntime: runtime))
        }.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1000, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { model.cancel(); window.close() }
        try await Task.sleep(nanoseconds: 20_000_000)
        runtime.setPreference(.original)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(model.usesUnifiedLayout)
        XCTAssertNil(model.selection, "A late metadata response must not override Original")
        XCTAssertEqual(model.navigationID, navigation)
        XCTAssertEqual(TMDBPresentationPreference.load(defaults: defaults), .original)
        model.beginEntry(repository: repository, key: "preference", summary: detail.summary, availability: runtime.availability,
            enabled: runtime.decisionForEntry().usesTMDB)
        XCTAssertFalse(model.usesUnifiedLayout)
        runtime.setPreference(.automatic)
        try await waitUntil { runtime.presentationDecision.usesTMDB }
        XCTAssertFalse(model.usesUnifiedLayout, "Background readiness must not change the current page")
        model.setPresentationEnabled(runtime.decisionForEntry().usesTMDB, detail: detail)
        try await waitUntil { model.selection != nil }
        XCTAssertTrue(model.usesUnifiedLayout)
        XCTAssertEqual(detail.playSources[0].episodes[0].url, "opaque:1")
        let offline = TMDBDetailModel()
        offline.setPresentationEnabled(false, detail: detail)
        XCTAssertFalse(offline.usesUnifiedLayout)
    }

    func testNativeEpisodeSingleDoubleClickAndKeyboardUseExactSourceResource() throws {
        let control = TMDBEpisodeActivationControl(frame: .init(x: 0, y: 0, width: 160, height: 115))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView?.addSubview(control)
        defer { window.close() }
        var selections = 0, plays = [String]()
        let sourceURL = "opaque:provider:episode-3:alternate"
        control.onSelect = { selections += 1 }
        control.onPlay = { plays.append(sourceURL) }
        for count in [1, 2, 3] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .init(x: 50, y: 50), modifierFlags: [], timestamp: Double(count), windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 0))
            control.mouseUp(with: event)
            XCTAssertEqual(selections, count)
            XCTAssertEqual(plays.count, count == 1 ? 0 : 1)
        }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 4, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        control.keyDown(with: enter)
        XCTAssertEqual(plays, [sourceURL, sourceURL])
        XCTAssertTrue(control.accessibilityPerformPress())
        XCTAssertEqual(selections, 4); XCTAssertEqual(plays.count, 2, "Accessibility activation selects without starting playback")
    }

    func testSelectedEpisodeMetadataMapsGapsAndDoesNotInventBonusDetails() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1,"name":"验收剧集","genres":[{"id":1,"name":"剧情"}],"overview":"整剧简介","seasons":[{"season_number":1,"episode_count":3}]}"#.utf8))
        let season = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[{"id":1,"episode_number":1,"name":"第一集","overview":"第一集简介"},{"id":3,"episode_number":3,"name":"重逢","overview":"第三集简介","runtime":44,"air_date":"2026-10-18"}]}"#.utf8))
        let episodes = [PlayEpisode(name: "第1集", url: "opaque:1"), PlayEpisode(name: "第3集", url: "opaque:3"), PlayEpisode(name: "幕后花絮", url: "opaque:bonus")]
        let source = PlaySource(name: "原始线路", episodes: episodes)
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "show", title: "验收剧集", categoryName: "电视剧"), playSources: [source])
        let selected = TMDBEpisodeInformation.make(detail: detail, work: work, season: season, source: source, episode: episodes[1])
        XCTAssertTrue(selected.title.contains("3")); XCTAssertTrue(selected.title.contains("重逢"))
        XCTAssertEqual(selected.overview, "第三集简介"); XCTAssertTrue(selected.facts.contains("44"))
        XCTAssertTrue(selected.facts.contains("2026-10-18")); XCTAssertFalse(selected.facts.contains("4K"))
        let bonus = TMDBEpisodeInformation.make(detail: detail, work: work, season: season, source: source, episode: episodes[2])
        XCTAssertTrue(bonus.title.contains("幕后花絮")); XCTAssertFalse(bonus.overview.contains("第一集")); XCTAssertFalse(bonus.overview.contains("整剧简介"))
        XCTAssertEqual(source.episodes.map(\.url), ["opaque:1", "opaque:3", "opaque:bonus"])
    }

    func testNumberedTMDBPlaceholdersDoNotDuplicateEpisodeTitles() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sourceEpisode = PlayEpisode(name: "S01E01", url: "opaque:original:1")
        let source = PlaySource(name: "夸克原画", episodes: [sourceEpisode])
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "show", title: "百日谎言", categoryName: "电视剧"), playSources: [source])
        let item = EpisodeNameParser.presentation(for: sourceEpisode, categoryName: "电视剧")
        let heading = L10n.string("tmdb.episode.heading", fallback: "Season %d · Episode %d", 1, 1)
        func episode(_ name: String) throws -> TMDBEpisode {
            try decoder.decode(TMDBEpisode.self, from: JSONSerialization.data(withJSONObject: ["id": 1, "season_number": 1, "episode_number": 1, "name": name]))
        }
        for name in ["第1集", "第 1 集", "第一集", "第１集", "Episode 1", "episode 01", "EP01", "E1", "S01E01", "Season 1 · Episode 1", "第1季·第1集", "01"] {
            let mapped = try episode(name)
            XCTAssertEqual(TMDBEpisodeTitle.compose(heading, episode: mapped, seasonNumber: 1), heading, name)
            XCTAssertEqual(TMDBEpisodeCards.title(item, mapped: mapped), L10n.string("tmdb.episode.number", fallback: "Episode %d", 1), name)
        }
        for name in ["失踪的第1集", "第1集的秘密", "第一集：初遇", "Chapter 1", "Episode 2", "第2季·第1集", "第一集（上）"] {
            XCTAssertEqual(TMDBEpisodeTitle.compose(heading, episode: try episode(name), seasonNumber: 1), heading + " · " + name)
        }
        let season = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[{"id":1,"season_number":1,"episode_number":1,"name":"第 1 集","overview":"真正的简介"}]}"#.utf8))
        let information = TMDBEpisodeInformation.make(detail: detail, work: nil, season: season, source: source, episode: sourceEpisode)
        XCTAssertEqual(information.title, heading); XCTAssertEqual(information.synopsis.title, heading)
        XCTAssertEqual(information.overview, "真正的简介")
        XCTAssertEqual(source.episodes.first?.url, "opaque:original:1")
    }

    func testSynopsisOverlayCentersInWindowAndRemovesWithoutReplacingContent() async throws {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: .init(x: 0, y: 0, width: 1200, height: 900)); window.contentView = container
        let anchor = TMDBSynopsisAnchor(frame: .zero); container.addSubview(anchor)
        defer { anchor.removePresentation(); window.close() }
        anchor.onDismiss = { anchor.synopsis = nil; anchor.updatePresentation() }
        anchor.synopsis = .init(title: "第1季 · 第3集", facts: "44 分钟", overview: String(repeating: "这是完整的分集简介。", count: 100))
        anchor.updatePresentation()
        try await Task.sleep(nanoseconds: 80_000_000)
        let frameView = try XCTUnwrap(container.superview)
        let overlay = try XCTUnwrap(frameView.subviews.first { $0.accessibilityIdentifier() == "tmdb.synopsis.overlay" })
        XCTAssertEqual(overlay.frame, frameView.convert(container.bounds, from: container))
        XCTAssertTrue(overlay is TMDBSynopsisOverlay)
        window.setContentSize(.init(width: 760, height: 650)); frameView.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame, frameView.convert(container.bounds, from: container))
        anchor.onDismiss()
        XCTAssertNil(overlay.superview); XCTAssertTrue(window.contentView === container)
    }

    func testSynopsisSizesToContentAndActualCloseHitTargetWorks() throws {
        let overlay = TMDBSynopsisOverlay(synopsis: .init(title: "短简介", facts: "", overview: "短简介只占一行。"), close: {})
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView = overlay
        overlay.frame = .init(x: 0, y: 0, width: 1200, height: 900); overlay.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(overlay.subviews.first)
        XCTAssertLessThan(panel.frame.height, 160)
        XCTAssertEqual(panel.frame.midX, 600, accuracy: 1); XCTAssertEqual(panel.frame.midY, 450, accuracy: 1)
        let closePoint = try XCTUnwrap(overlay.superview).convert(NSPoint(x: 16, y: 16), from: overlay.closeButton)
        XCTAssertTrue(overlay.hitTest(closePoint) === overlay.closeButton, "Close must be a real hit target above the dimming view")
        var closed = 0
        let interactive = TMDBSynopsisOverlay(synopsis: .init(title: "长简介", facts: "", overview: String(repeating: "完整简介需要支持滚动。", count: 300)), close: { closed += 1 })
        interactive.frame = overlay.frame; interactive.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(try XCTUnwrap(interactive.subviews.first).frame.height, 630)
        XCTAssertGreaterThan(interactive.textView.frame.height, 630)
        interactive.closeButton.performClick(nil); XCTAssertEqual(closed, 1)
        interactive.cancelOperation(nil); XCTAssertEqual(closed, 2)
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-TMDB-Visuals/synopsis-short.png")
        if let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
    }

    func testSynopsisCloseReceivesWindowMouseHitAboveSwiftUIContent() throws {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Color.white.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.contentView = hosting
        let anchor = TMDBSynopsisAnchor(frame: .zero); hosting.addSubview(anchor)
        defer { anchor.removePresentation(); window.close() }
        anchor.synopsis = .init(title: "鼠标关闭验收", facts: "", overview: "真实 SwiftUI 宿主必须允许点击关闭。")
        anchor.updatePresentation()
        let frameView = try XCTUnwrap(hosting.superview)
        frameView.layoutSubtreeIfNeeded()
        func findOverlay(_ view: NSView) -> TMDBSynopsisOverlay? {
            if let overlay = view as? TMDBSynopsisOverlay { return overlay }
            return view.subviews.lazy.compactMap { findOverlay($0) }.first
        }
        let overlay = try XCTUnwrap(findOverlay(frameView))
        for size in [NSSize(width: 1200, height: 900), NSSize(width: 760, height: 650)] {
            window.setContentSize(size); frameView.layoutSubtreeIfNeeded(); overlay.layoutSubtreeIfNeeded()
            let point = frameView.convert(NSPoint(x: 16, y: 16), from: overlay.closeButton)
            let hit = frameView.hitTest(point)
            XCTAssertTrue(hit === overlay.closeButton, "The full window hit route must reach Close, got \(String(describing: hit))")
            for location in [NSPoint(x: 10, y: 10), NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)] {
                let target = try XCTUnwrap(frameView.hitTest(frameView.convert(location, from: overlay)))
                XCTAssertTrue(target === overlay || target.isDescendant(of: overlay), "Modal and backdrop must block underlying content")
            }
            XCTAssertTrue(overlay.superview === frameView)
            XCTAssertEqual(overlay.frame, frameView.convert(hosting.bounds, from: hosting))
        }
    }

    func testSynopsisMoreOnlyAppearsOnOverflowAndWholePreviewActivates() throws {
        let short = "短简介没有溢出。"
        XCTAssertEqual(TMDBTextLayout.preview(short, width: 500).string, short)
        let long = String(repeating: "中文👨‍👩‍👦剧情 synopsis，", count: 50)
        let clipped = TMDBTextLayout.preview(long, width: 250)
        XCTAssertTrue(clipped.string.hasSuffix("… " + L10n.string("tmdb.synopsis.more", fallback: "More")))
        XCTAssertLessThanOrEqual(TMDBTextLayout.height(clipped, width: 250), 42)
        XCTAssertEqual(TMDBTextLayout.preview(short, width: 500).string, short, "Resizing cannot leave a stale More suffix")
        let control = TMDBSynopsisPreviewControl(frame: .init(x: 0, y: 0, width: 500, height: 42))
        var opens = 0; control.actionHandler = { opens += 1 }; control.isEnabled = true
        XCTAssertTrue(control.accessibilityPerformPress()); XCTAssertEqual(opens, 1)
        control.isEnabled = false; XCTAssertFalse(control.accessibilityPerformPress()); XCTAssertEqual(opens, 1)
    }

    func testSwitchingPlayLinesReusesMappedEpisodeImageAcrossViewAndDiskLifetimes() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let season = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[{"id":101,"episode_number":1,"name":"首次开庭","overview":"本集剧情","still_path":"/same-episode.jpg"},{"id":102,"episode_number":2},{"id":103,"episode_number":3},{"id":104,"episode_number":4}]}"#.utf8))
        let quark = PlaySource(name: "夸克原画", episodes: [.init(name: "[1.0GB]01 4K.mp4【全3集】", url: "quark:one"), .init(name: "[1.0GB]02_4K.mp4【全3集】", url: "quark:two"), .init(name: "[1.0GB]03 4K.mp4【全3集】", url: "quark:three")])
        let baidu = PlaySource(name: "百度", episodes: [.init(name: "S01E01", url: "baidu:one"), .init(name: "S01E02", url: "baidu:two"), .init(name: "S01E03", url: "baidu:three")])
        let a = TMDBEpisodeMapper.episodes(quark.episodes, category: "电视剧", season: season)
        let b = TMDBEpisodeMapper.episodes(baidu.episodes, category: "电视剧", season: season)
        XCTAssertEqual(a[0]?.stillPath, b[0]?.stillPath)
        XCTAssertEqual(a.count, 3, "An ongoing line must map its three uploaded episodes even when TMDB has four")
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "ongoing", title: "连载剧", categoryName: "电视剧"), playSources: [quark])
        let info = TMDBEpisodeInformation.make(detail: detail, work: nil, season: season, source: quark, episode: quark.episodes[0])
        XCTAssertTrue(info.title.hasSuffix("首次开庭"))
        XCTAssertEqual(info.overview, "本集剧情")
        let url = try XCTUnwrap(TMDBClient.imageURL(path: a[0]?.stillPath, size: "w300"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let probe = TMDBSeasonImageProbe(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try ImageDataRepository(cacheDirectory: directory, httpClient: probe)
        let images = ImageRepository(dataRepository: data), request = PosterImageRequest(url: url, pixels: 320)
        _ = try await images.posterImage(for: request, priority: .visible)
        XCTAssertNotNil(images.cachedPoster(for: request), "New line card must render shared cached pixels immediately")
        _ = try await images.posterImage(for: request, priority: .selected)
        let relaunched = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: directory, httpClient: probe))
        _ = try await relaunched.posterImage(for: request)
        let requests = await probe.paths
        XCTAssertEqual(requests.filter { $0.hasSuffix("same-episode.jpg") }.count, 1)
        XCTAssertEqual(quark.episodes[0].url, "quark:one"); XCTAssertEqual(baidu.episodes[0].url, "baidu:one")
    }


    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for metadata state")
    }

    func testColdCardMetadataDisplaysBeforeStreamsWithoutSavingUnverifiedBinding() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1,"title":"测试电影","release_date":"2023-01-01","overview":"已核验的影片简介","vote_average":8.2,"vote_count":500,"backdrop_path":"/unavailable.jpg"}"#.utf8))
        let repository = TMDBRepository(client: TMDBRenderService(work: work, episodes: try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[]}"#.utf8))))
        let model = TMDBDetailModel(), detail = Self.detail()
        model.beginEntry(repository: repository, key: "parallel", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        let navigation = model.navigationID
        defer { model.cancel() }
        try await waitUntil { model.selection != nil && !model.isPreparing }
        let earlyBinding = await repository.binding(key: "parallel", input: .init(detail: detail))
        XCTAssertNil(earlyBinding, "Card evidence must not persist an automatic provider association")
        XCTAssertEqual(model.selection?.reference.id, 1)
        XCTAssertNotNil(model.artwork(.backdrop))

        // Actual SwiftUI detail tree while source transport is still loading.
        // No image repository: image failure must not hide the verified text.
        let state = AppState(environment: nil)
        XCTAssertEqual(state.detailLoadState, .loading)
        let host = NSHostingView(rootView: DetailView(detail: .init(summary: detail.summary), metadata: model).environmentObject(state).defaultAppStorage(UserDefaults(suiteName: "TMDBDetailFixture-\(UUID())")!))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBSynopsisPreviewControl }.first)
        XCTAssertEqual(preview.text, "已核验的影片简介")
        XCTAssertTrue(preview.isEnabled, "Stream loading must not redact or disable the synopsis")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OKVideoMac-TMDB154-Preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("metadata-ready-streams-pending.png"))

        model.receive(detail: detail, key: "parallel")
        try await waitUntil { !model.isPreparing }
        let saved = await repository.binding(key: "parallel", input: .init(detail: detail))
        XCTAssertEqual(saved?.reference?.id, 1)
        XCTAssertEqual(model.navigationID, navigation)
        XCTAssertEqual(detail.playSources[0].episodes[0].url, "opaque:1")
    }

    func testSparseCardWaitsForCastInsteadOfGuessingType() async throws {
        var detail = Self.detail()
        detail.summary.categoryName = "剧情 悬疑"
        detail.actors = "甲演员 乙演员 丙演员"
        let repository = TMDBRepository(client: TMDBDetailService(includesCast: true)), model = TMDBDetailModel()
        model.beginEntry(repository: repository, key: "sparse-cast", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        defer { model.cancel() }
        try await waitUntil { model.isAwaitingSourceIdentity }
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isPreparing)
        let before = await repository.binding(key: "sparse-cast", input: .init(detail: detail))
        XCTAssertNil(before)
        model.receive(detail: detail, key: "sparse-cast")
        try await waitUntil { !model.isPreparing }
        XCTAssertEqual(model.selection?.reference.id, 1)
        XCTAssertFalse(model.isAwaitingSourceIdentity)
    }

    func testRicherDirectorConflictRemovesPreviewAndNeverSavesIt() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1,"title":"测试电影","release_date":"2023-01-01","credits":{"crew":[{"id":99,"name":"甲导演","job":"Director"}]}}"#.utf8))
        let repository = TMDBRepository(client: TMDBRenderService(work: work, episodes: try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[]}"#.utf8))))
        let model = TMDBDetailModel()
        var detail = Self.detail()
        model.beginEntry(repository: repository, key: "director", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        defer { model.cancel() }
        try await waitUntil { model.selection != nil }
        detail.director = "乙导演"
        model.receive(detail: detail, key: "director")
        XCTAssertNil(model.selection, "Conflicting new evidence must retract an automatic preview synchronously")
        try await waitUntil { !model.isPreparing }
        XCTAssertNil(model.selection)
        let saved = await repository.binding(key: "director", input: .init(detail: Self.detail()))
        XCTAssertNil(saved)
    }

    func testChangedYearRemovesEarlyPreview() async throws {
        let repository = TMDBRepository(client: TMDBDetailService()), model = TMDBDetailModel()
        var detail = Self.detail()
        model.beginEntry(repository: repository, key: "changed-year", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        defer { model.cancel() }
        try await waitUntil { model.selection != nil }
        detail.summary.year = "2024"
        model.receive(detail: detail, key: "changed-year")
        XCTAssertNil(model.selection)
        try await waitUntil { !model.isPreparing }
        XCTAssertNil(model.selection)
        let saved = await repository.binding(key: "changed-year", input: .init(detail: Self.detail()))
        XCTAssertNil(saved)
    }

    func testStreamsRemainAvailableWhileTMDBIsPendingThenFails() async throws {
        let model = TMDBDetailModel(), detail = Self.detail()
        let service = TMDBDeferredDetailService(), repository = TMDBRepository(client: service)
        // No coupling to source page state or episode resources on TMDB failure.
        model.beginEntry(repository: repository, key: "failed-tmdb", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        model.receive(detail: detail, key: "failed-tmdb")
        defer { model.cancel() }
        XCTAssertTrue(model.isPreparing)
        let info = TMDBEpisodeInformation.make(detail: detail, work: nil, season: nil, source: detail.playSources.first, episode: detail.playSources.first?.episodes.first)
        XCTAssertEqual(info.overview, detail.synopsis)
        XCTAssertEqual(detail.playSources[0].episodes[0].url, "opaque:1")
        let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(AppState(environment: nil)))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBSynopsisPreviewControl }.first)
        XCTAssertEqual(preview.text, detail.synopsis)
        XCTAssertTrue(preview.isEnabled)
        XCTAssertTrue(model.isPreparing)
        await service.fail()
        try await waitUntil { !model.isPreparing }
        XCTAssertNil(model.selection)
        XCTAssertNil(model.actionError)
        XCTAssertTrue(model.usesUnifiedLayout)
    }

    func testDetailedInputDuringPreviewCannotLoseBindingPromotion() async throws {
        let service = TMDBDeferredDetailService(), repository = TMDBRepository(client: service)
        let model = TMDBDetailModel(), detail = Self.detail()
        model.beginEntry(repository: repository, key: "promote", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        defer { model.cancel() }
        for _ in 0..<200 {
            if await service.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.receive(detail: detail, key: "promote")
        await service.release()
        try await waitUntil { !model.isPreparing }
        XCTAssertEqual(model.selection?.reference.id, 1)
        let saved = await repository.binding(key: "promote", input: .init(detail: detail))
        XCTAssertEqual(saved?.reference?.id, 1)
    }

    func testLatePreviewCannotReappearAfterNavigationOrOriginalChoice() async throws {
        for leavePage in [false, true] {
            let service = TMDBDeferredDetailService(), repository = TMDBRepository(client: service)
            let model = TMDBDetailModel(), detail = Self.detail()
            model.beginEntry(repository: repository, key: "preview", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
            for _ in 0..<200 {
                if await service.started { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if leavePage {
                model.beginEntry(repository: nil, key: "different", summary: detail.summary, availability: TMDBAvailability(), enabled: false)
            } else { await model.useOriginal() }
            await service.release()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(model.selection)
            let saved = await repository.binding(key: "preview", input: .init(detail: detail))
            XCTAssertNil(saved)
            model.cancel()
        }
    }

    static func detail() -> VideoDetail {
        .init(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "movie", title: "测试电影", year: "2023", categoryName: "电影"),
              synopsis: "源站简介", playSources: [.init(name: "线路 A", episodes: [.init(name: "正片", url: "opaque:1")])])
    }

    func testEnhancedLayoutsAndAttributionWithOptionalRealArtwork() async throws {
        let fixtureRoot = URL(fileURLWithPath: "/private/tmp/OKVideoMac-TMDB-Fixtures")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fallbackWork = Data(#"{"id":114461,"name":"阿索卡","first_air_date":"2023-08-22","overview":"曾经的绝地武士阿索卡展开调查，追寻银河系中新出现的威胁。","seasons":[{"season_number":1,"episode_count":8}]}"#.utf8)
        let fallbackSeason = Data(#"{"season_number":1,"episodes":[{"id":1,"episode_number":1,"name":"师与徒"},{"id":3,"episode_number":3,"name":"飞翔时刻"}]}"#.utf8)
        let work = try decoder.decode(TMDBWork.self, from: (try? Data(contentsOf: fixtureRoot.appendingPathComponent("tv.json"))) ?? fallbackWork)
        let season = try decoder.decode(TMDBSeason.self, from: (try? Data(contentsOf: fixtureRoot.appendingPathComponent("season.json"))) ?? fallbackSeason)
        let repository = TMDBRepository(client: TMDBRenderService(work: work, episodes: season))
        let episodes = (1...8).filter { $0 != 2 }.map { PlayEpisode(name: "第 \($0) 集", url: "opaque:original:\($0)") }
            + [PlayEpisode(name: "预告片", url: "opaque:trailer"), PlayEpisode(name: "第 3 集 备用", url: "opaque:alternate:3")]
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "测试来源", videoID: "ahsoka", title: "阿索卡 第一季", year: "2023", categoryName: "电视剧"),
            synopsis: "曾经的绝地武士阿索卡展开调查，追寻银河系中新出现的威胁。", playSources: [.init(name: "线路 A", episodes: episodes), .init(name: "线路 B", episodes: episodes)])
        let model = TMDBDetailModel()
        await model.load(repository: repository, key: "ahsoka", input: .init(detail: detail))
        XCTAssertEqual(model.selection?.reference.id, 114461, "Chinese alias must match even when TMDB returns an English main title")
        await model.loadSeason(source: detail.playSources[0], category: "电视剧")
        XCTAssertEqual(model.season?.seasonNumber, 1)
        XCTAssertEqual(TMDBEpisodeMapper.episode(episodes[1], category: "电视剧", season: season)?.episodeNumber, 3)
        XCTAssertNil(TMDBEpisodeMapper.episode(episodes[7], category: "电视剧", season: season))
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-TMDB-Visuals")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let images = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: output.appendingPathComponent(UUID().uuidString), httpClient: TMDBRenderImages(root: fixtureRoot.appendingPathComponent("images"))))
        let urls = [model.artwork(.backdrop), model.artwork(.logo)] + season.episodes.map { model.imageURL($0.stillPath, kind: .still) } + work.cast.prefix(20).map { model.imageURL($0.profilePath, kind: .profile) }
        for url in urls.compactMap({ $0 }) { _ = try? await images.image(for: url) }
        let state = AppState(environment: nil)
        let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(state).environment(\.imageRepository, images))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1600, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        for (name, width, appearance) in [("wide-light", 1280.0, NSAppearance.Name.aqua), ("fullscreen-light", 2020.0, .aqua), ("ultrawide-light", 2320.0, .aqua), ("wide-dark", 1600.0, .darkAqua), ("compact-light", 650.0, .aqua), ("narrow-light", 500.0, .aqua)] {
            host.appearance = NSAppearance(named: appearance); window.setContentSize(.init(width: width, height: 1100))
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let scrolls = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSScrollView }
            let vertical = try XCTUnwrap(scrolls.max { $0.bounds.height < $1.bounds.height })
            XCTAssertLessThanOrEqual(try XCTUnwrap(vertical.documentView).bounds.width, width + 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("detail-\(name).png"))
        }
        XCTAssertEqual(detail.playSources[0].episodes.map(\.url), episodes.map(\.url), "Missing, duplicate and bonus resources must retain original playback targets")
        XCTAssertNotNil(NSImage(named: "TMDBLogo"))
        let noticeURL = try XCTUnwrap(Bundle.main.url(forResource: "TMDB-Attribution", withExtension: "txt"))
        XCTAssertTrue(try String(contentsOf: noticeURL).contains(TMDBAttributionView.notice))
        // A separate view has no image repository: all remote artwork fails,
        // while metadata, season controls and original playback remain intact.
        let missingHost = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(state))
        let missingWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        missingWindow.isReleasedWhenClosed = false; missingWindow.contentView = missingHost
        defer { missingWindow.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        missingHost.layoutSubtreeIfNeeded()
        let missingBitmap = try XCTUnwrap(missingHost.bitmapImageRepForCachingDisplay(in: missingHost.bounds))
        missingHost.cacheDisplay(in: missingHost.bounds, to: missingBitmap)
        try XCTUnwrap(missingBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("detail-images-unavailable.png"))
        XCTAssertNotNil(model.selection); XCTAssertNotNil(model.season)

        await model.search("阿索卡", type: .tv)
        XCTAssertEqual(model.candidates.count, 1)
        let matchHost = NSHostingView(rootView: TMDBMatchSheet(metadata: model, originalTitle: detail.summary.title).environment(\.imageRepository, images))
        let matchWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 738, height: 618), styleMask: [.titled], backing: .buffered, defer: false)
        matchWindow.isReleasedWhenClosed = false; matchWindow.contentView = matchHost
        defer { matchWindow.close() }
        try await Task.sleep(nanoseconds: 300_000_000); matchHost.layoutSubtreeIfNeeded()
        let matchBitmap = try XCTUnwrap(matchHost.bitmapImageRepForCachingDisplay(in: matchHost.bounds))
        matchHost.cacheDisplay(in: matchHost.bounds, to: matchBitmap)
        try XCTUnwrap(matchBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("manual-match.png"))
        await model.useOriginal()
        XCTAssertNil(model.selection)
        let saved = await repository.binding(key: "ahsoka", input: .init(detail: detail))
        XCTAssertEqual(saved?.disabled, false)
        XCTAssertNotNil(saved?.reference)
        let candidate = TMDBCandidate(reference: .init(type: .tv, id: work.id), work: work)
        let chosen = await model.choose(candidate)
        XCTAssertTrue(chosen); XCTAssertEqual(model.binding?.manual, true)
    }

    func testKnownSeasonLoadsBeforeProviderLinesAndMapsSingleNumericEpisode() async throws {
        for explicit in [false, true] {
            let client = TMDBSeasonIdentityProbe(multiple: explicit)
            let model = TMDBDetailModel()
            let summary = VideoSummary(siteKey: "s", siteName: "Site", videoID: "id", title: explicit ? "测试剧 第二季" : "测试剧", year: "2026", categoryName: "电视剧")
            model.beginEntry(repository: TMDBRepository(client: client), key: "k", summary: summary, availability: TMDBAvailability(), enabled: true)
            defer { model.cancel() }
            for _ in 0..<100 { if model.season != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let number = explicit ? 2 : 1
            XCTAssertEqual(model.season?.seasonNumber, number, "Season data must arrive without a source line")
            let calls = await client.seasonCalls
            XCTAssertEqual(calls, [number])
            let source = PlaySource(name: "Line", episodes: [.init(name: "01.mp4", url: "opaque:original"), .init(name: "S09E01", url: "opaque:bad")])
            await model.loadSeason(source: source, category: nil)
            let mapping = model.episodeMapping(source: source, category: nil)
            XCTAssertEqual(mapping[0]?.stillPath, "/s\(number)e1.jpg")
            XCTAssertNil(mapping[1])
            let after = await client.seasonCalls
            XCTAssertEqual(after, [number], "Changing lines reuses the same verified season")
            XCTAssertEqual(source.episodes.first?.url, "opaque:original")
        }
    }

    func testMixedSeasonsMapPerResourceAndUnknownSeasonDoesNotBorrowArtwork() async throws {
        let client = TMDBSeasonIdentityProbe(multiple: true), model = TMDBDetailModel()
        let detail = VideoDetail(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "测试剧", year: "2026", categoryName: "电视剧"))
        await model.load(repository: TMDBRepository(client: client), key: "mixed", input: .init(detail: detail))
        defer { model.cancel() }
        let source = PlaySource(name: "Mixed", episodes: [.init(name: "S02E01", url: "b"), .init(name: "S01E01", url: "a"), .init(name: "01", url: "unknown")])
        await model.loadSeason(source: source, category: nil)
        XCTAssertNil(model.season)
        let mapping = model.episodeMapping(source: source, category: nil)
        XCTAssertEqual(mapping[0]?.stillPath, "/s2e1.jpg")
        XCTAssertEqual(mapping[1]?.stillPath, "/s1e1.jpg")
        XCTAssertNil(mapping[2])
        XCTAssertNotNil(model.selection)
    }

    func testFirstEntryAutomaticallyLoadsSeasonAndEpisodeArtworkForGroupedSeries() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":64197,"name":"琅琊榜","first_air_date":"2015-09-19","seasons":[{"season_number":1,"air_date":"2015-09-19","episode_count":54},{"season_number":2,"air_date":"2017-12-18","episode_count":50}]}"#.utf8))
        let seasonData = try JSONSerialization.data(withJSONObject: ["season_number": 1, "episodes": (1...54).map {
            ["id": $0, "episode_number": $0, "still_path": "/episode-\($0).jpg"] as [String: Any]
        }])
        let season = try decoder.decode(TMDBSeason.self, from: seasonData)
        let source = PlaySource(name: "线路一", episodes: (1...54).map { PlayEpisode(name: String($0), url: "opaque:\($0)") })
        let detail = VideoDetail(summary: .init(siteKey: "fixture", siteName: "Fixture", videoID: "langyabang", title: "琅琊榜 第一季", year: "2015", categoryName: "电视剧"), playSources: [source])
        let model = TMDBDetailModel()
        model.beginEntry(repository: TMDBRepository(client: TMDBRenderService(work: work, episodes: season)), key: "langyabang", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        let navigation = model.navigationID
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.blue, atX: x, y: y) } }
        let probe = TMDBSeasonImageProbe(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        let images = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), httpClient: probe))
        let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(AppState(environment: nil)).environment(\.imageRepository, images).defaultAppStorage(UserDefaults(suiteName: "TMDBDetailFixture-\(UUID())")!))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1000, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { model.cancel(); window.close() }
        model.receive(detail: detail, key: "langyabang")
        for _ in 0..<200 {
            if model.season != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.selection?.reference.id, 64197)
        XCTAssertEqual(model.season?.seasonNumber, 1, "DetailView must start season loading on the first metadata update")
        XCTAssertTrue(model.binding?.seasons.isEmpty == true, "No manual season binding is needed")
        XCTAssertEqual(model.navigationID, navigation)
        let loaded = try XCTUnwrap(model.season)
        let mapping = TMDBEpisodeMapper.episodes(source.episodes, category: "电视剧", season: loaded)
        XCTAssertEqual(mapping.count, 54, "The complete source line must qualify for episode-card enrichment")
        let mapped = mapping[0]
        XCTAssertEqual(mapped?.stillPath, "/episode-1.jpg")
        XCTAssertNotNil(model.imageURL(mapped?.stillPath, kind: .still))
        for _ in 0..<200 {
            if await probe.paths.contains(where: { $0.hasSuffix("/episode-1.jpg") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requested = await probe.paths
        XCTAssertTrue(requested.contains(where: { $0.hasSuffix("/episode-1.jpg") }), "The live card must request its image after automatic metadata arrives")
        XCTAssertEqual(detail.playSources[0], source)
    }
}

private actor TMDBAcceptanceTransport: HTTPClient {
    let client = URLSessionHTTPClient.isolatedEphemeral()
    var events: [[String: String]] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let start = Date()
        do {
            let response = try await client.send(request)
            events.append(["path": request.url.path, "seconds": String(Date().timeIntervalSince(start)), "status": String(response.statusCode)])
            return response
        } catch {
            events.append(["path": request.url.path, "seconds": String(Date().timeIntervalSince(start)), "error": String(describing: error)])
            throw error
        }
    }
}

private struct TMDBRenderImages: HTTPClient {
    let root: URL
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data = try Data(contentsOf: root.appendingPathComponent(request.url.lastPathComponent))
        return HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: data)
    }
}

private actor TMDBSeasonImageProbe: HTTPClient {
    let data: Data
    private(set) var paths: [String] = []
    init(data: Data) { self.data = data }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        paths.append(request.url.path)
        return HTTPResponse(url: request.url, statusCode: 200, headers: ["Content-Type": "image/png"], body: data)
    }
}

private struct TMDBRenderService: TMDBServing {
    let work: TMDBWork
    let episodes: TMDBSeason
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [work] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { work }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { episodes }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.unavailable(404) }
}

private actor TMDBDetailService: TMDBServing {
    var fails: Bool
    let delay: UInt64, id: Int
    let includesCast: Bool
    func setFailure(_ value: Bool) { fails = value }
    init(fails: Bool = false, delay: UInt64 = 0, id: Int = 1, includesCast: Bool = false) { self.fails = fails; self.delay = delay; self.id = id; self.includesCast = includesCast }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        if fails { throw URLError(.cannotConnectToHost) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return [try await detail(.init(type: .movie, id: id))]
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        if fails { throw URLError(.cannotConnectToHost) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let cast = includesCast ? #", "media_type":"movie", "credits":{"cast":[{"id":10,"name":"甲演员"},{"id":11,"name":"乙演员"},{"id":12,"name":"丙演员"}]}"# : ""
        return try decoder.decode(TMDBWork.self, from: Data("{\"id\":\(reference.id),\"title\":\"测试电影\",\"release_date\":\"2023-01-01\"\(cast)}".utf8))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.unavailable(404) }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.unavailable(404) }
}

private actor TMDBDeferredDetailService: TMDBServing {
    private(set) var started = false
    private var released = false
    private var fails = false
    func release() { released = true }
    func fail() { fails = true; released = true }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        started = true
        while !released { try await Task.sleep(nanoseconds: 10_000_000) }
        if fails { throw URLError(.cannotConnectToHost) }
        return [try await detail(.init(type: .movie, id: 1))]
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        try await TMDBDetailService().detail(reference)
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBSearchRecorder {
    var keys: [String] = []
    func record(_ key: String) { keys.append(key) }
}
private struct TMDBSearchProvider: SiteProvider {
    let site: SiteConfiguration
    let recorder: TMDBSearchRecorder
    let delay: UInt64
    var capability: SiteCapability { .standardJSON }
    func home() async throws -> SiteHome { .init(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { throw TMDBError.invalidInput }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        await recorder.record(site.key)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return .init(items: [.init(siteKey: site.key, siteName: site.name, videoID: "1", title: "Film")], pagination: .init(page: 1, pageCount: 1))
    }
    func detail(id: String) async throws -> VideoDetail { throw TMDBError.invalidInput }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw TMDBError.invalidInput }
}

@MainActor final class DetailWindowRegressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "OKVideoMac.window-regression.\(UUID())")! }

    func testMoveSavesBeforeDebounceOrQuit() throws {
        let d = defaults(), window = makeWindow()
        defer { window.close(); d.removeObject(forKey: MainWindowGeometryStore.storageKey) }
        let store = MainWindowGeometryStore(window: window, defaults: d)
        window.setFrameOrigin(NSPoint(x: 207, y: 163))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        XCTAssertEqual(MainWindowGeometryStore.savedFrame(defaults: d), window.frame)
        withExtendedLifetime(store) {}
    }
    func testCloseSavesFinalFrameAfterTransitionCoordinatorMarksClosing() throws {
        let d = defaults(), window = makeWindow()
        defer { window.close(); d.removeObject(forKey: MainWindowGeometryStore.storageKey) }
        let transition = WindowTransitionCoordinator.state(for: window)
        let store = MainWindowGeometryStore(window: window, defaults: d)
        window.setFrameOrigin(NSPoint(x: 233, y: 176))
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertTrue(transition.isClosing)
        XCTAssertEqual(MainWindowGeometryStore.savedFrame(defaults: d), window.frame)
        withExtendedLifetime(store) {}
    }
    func testRestoredIdentifierStillAttachesAndRestoresOnce() throws {
        let d = defaults(), window = makeWindow()
        defer { window.close(); window.setFrameAutosaveName(""); d.removeObject(forKey: MainWindowGeometryStore.storageKey) }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let saved = NSRect(x: screen.minX + 60, y: screen.minY + 70, width: 1000, height: 700)
        d.set(try JSONEncoder().encode(saved), forKey: MainWindowGeometryStore.storageKey)
        window.identifier = AppWindowLayoutPolicy.descriptor(for: .mainWindow).identifier
        AppWindowLayoutPolicy.configure(window, target: .mainWindow, defaults: d)
        XCTAssertTrue(MainWindowGeometryStore.isAttached(to: window))
        XCTAssertEqual(window.frame, saved)
        let moved = saved.offsetBy(dx: 32, dy: 21)
        window.setFrame(moved, display: false)
        AppWindowLayoutPolicy.configure(window, target: .mainWindow, defaults: d)
        XCTAssertEqual(window.frame, moved, "Remount must not restore over the user's move")
    }
    func testQuitInFullScreenPreservesLastWindowedFrame() throws {
        let d = defaults(), window = makeWindow()
        defer { window.close(); d.removeObject(forKey: MainWindowGeometryStore.storageKey) }
        let transition = WindowTransitionCoordinator.state(for: window)
        let store = MainWindowGeometryStore(window: window, defaults: d)
        store.save(); let saved = MainWindowGeometryStore.savedFrame(defaults: d)
        transition.beginFullScreen(entering: true)
        window.setFrame(NSRect(x: 0, y: 0, width: 2240, height: 1260), display: false)
        transition.completeFullScreen(isFullScreen: true)
        store.save()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(MainWindowGeometryStore.savedFrame(defaults: d), saved)
    }
    func testDetachedSearchGridDropsItsNativeDocumentImmediately() {
        let scroll = PosterNativePageScrollView()
        let collection = PosterNativePageCollectionView()
        collection.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 260)))
        scroll.documentView = collection
        PosterNativePage.dismantleNSView(scroll, coordinator: PosterNativePage.Coordinator())
        XCTAssertNil(scroll.documentView)
        XCTAssertTrue(scroll.isHidden)
        XCTAssertNil(collection.superview)
    }
    func testHeroFollowsBackdropProportionAndKeepsActionsInsideUltrawideViewport() {
        let windowed = TMDBHeroLayout.height(width: 1280, viewportHeight: 900)
        let full = TMDBHeroLayout.height(width: 2020, viewportHeight: 1100)
        XCTAssertGreaterThan(full, windowed)
        XCTAssertGreaterThan(full, 620)
        XCTAssertEqual(windowed, 720)
        XCTAssertEqual(TMDBHeroLayout.height(width: 2020, viewportHeight: 1210), 1136.25)
        XCTAssertEqual(full, 1076)
        XCTAssertEqual(TMDBHeroLayout.height(width: 3000, viewportHeight: 900), 876)
        XCTAssertGreaterThanOrEqual(TMDBHeroLayout.height(width: 500, viewportHeight: 600), 540)
    }
    func testWideHeroKeepsTopOfArtworkAndOpaqueEdges() async throws {
        let image = NSImage(size: NSSize(width: 160, height: 90), flipped: true) { rect in
            NSColor.blue.setFill(); rect.fill()
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 160, height: 16).fill()
            return true
        }
        let host = NSHostingView(rootView: TMDBHeroArtwork(image: Image(nsImage: image), blurred: false))
        let window = makeWindow(); window.contentView = host
        defer { window.close() }
        for width in [1280.0, 2020.0] {
            window.setContentSize(NSSize(width: width, height: 620))
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(pixel.redComponent, 0.9, "The image's top stripe must survive wide-window cropping")
            XCTAssertGreaterThan(pixel.redComponent - pixel.blueComponent, 0.7, "Allow display color conversion while rejecting the blue cropped center")
            XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
        }
    }
}

@MainActor final class BrowserFullscreenCommandTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testSynopsisBlocksBackgroundEscapeRegardlessOfMonitorOrder() throws {
        final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
        let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let monitor = AppKeyCommandMonitorView(frame: .zero)
        content.addSubview(monitor)
        var backActions = 0
        monitor.handler = { _ in backActions += 1; return true }
        let anchor = TMDBSynopsisAnchor(frame: .zero)
        content.addSubview(anchor)
        anchor.synopsis = .init(title: "Episode", facts: "", overview: "Synopsis")
        var dismissals = 0
        anchor.onDismiss = { dismissals += 1; anchor.synopsis = nil; anchor.removePresentation() }
        anchor.updatePresentation()
        XCTAssertTrue(WindowModalRegistry.isPresented(in: window))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNotNil(monitor.handleKeyEvent(event), "The page monitor must yield to the modal")
        XCTAssertEqual(backActions, 0)
        let overlay = try XCTUnwrap(descendants(try XCTUnwrap(content.superview)).compactMap { $0 as? TMDBSynopsisOverlay }.first)
        overlay.cancelOperation(nil)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(WindowModalRegistry.isPresented(in: window))
        XCTAssertEqual(backActions, 0, "Closing the modal must not also dismiss the detail")
        XCTAssertNil(monitor.handleKeyEvent(event), "The next Escape can reach page navigation")
        XCTAssertEqual(backActions, 1)
    }

    func testSearchCommandRevealsCollapsedSidebarAndFocusesExistingField() async throws {
        let state = AppState(environment: nil)
        state.selectSection(.settings)
        struct SearchFixture: View {
            @ObservedObject var state: AppState
            var body: some View {
                NativeSidebarSourceList(text: .constant(""),
                    presentation: SidebarSearchPresentationPolicy.presentation(for: state.selectedSection),
                    isSearchEnabled: true, focusRequest: state.globalSearchFocusRequest,
                    selection: state.navigation.selection, navigation: state.navigation,
                    onTextChange: { _ in }, onSubmit: {}, onExitSearch: { true }, onSelect: state.selectSection)
            }
        }
        let splitController = BrowserRootSplitController()
        splitController.sidebarHost.rootView = AnyView(SearchFixture(state: state))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 700),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = splitController
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await Task.sleep(nanoseconds: 250_000_000)
        let views = descendants(try XCTUnwrap(window.contentView))
        let controller = try XCTUnwrap(views.compactMap { ($0 as? NSSplitView)?.delegate as? BrowserRootSplitController }.first)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        controller.splitViewItems[0].isCollapsed = true
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.splitViewItems[0].isCollapsed)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<40 where NSApp.keyWindow !== window {
            window.makeKey()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(NSApp.keyWindow === window, "The command must target the active test window")
        state.focusGlobalSearch()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(controller.splitViewItems[0].isCollapsed)
        XCTAssertNotNil(search.currentEditor())
        XCTAssertTrue(window.firstResponder === search.currentEditor())
        BrowserRootSplitController.toggleSidebar(in: window)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(controller.splitViewItems[0].isCollapsed, "Menu and toolbar share the native split command")
    }

    func testFullscreenShortcutRoutesToNativeWindowBeforeMenuOpenAndWhileEditing() throws {
        final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            var toggles = 0
            override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
        }
        let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let monitor = AppKeyCommandMonitorView(frame: .zero)
        content.addSubview(monitor)
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 30))
        content.addSubview(text); window.makeFirstResponder(text)
        var pageActions = 0
        monitor.handler = { _ in pageActions += 1; return true }
        func event(_ modifiers: NSEvent.ModifierFlags, repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: repeated, keyCode: 3))
        }
        XCTAssertNil(monitor.handleKeyEvent(try event([.command, .control])))
        XCTAssertEqual(window.toggles, 1)
        XCTAssertNil(monitor.handleKeyEvent(try event([.command, .control], repeated: true)))
        XCTAssertEqual(window.toggles, 1, "Holding the chord must not repeatedly toggle the window")
        XCTAssertNotNil(monitor.handleKeyEvent(try event(.command)))
        XCTAssertNotNil(monitor.handleKeyEvent(try event([])))
        XCTAssertNotNil(monitor.handleKeyEvent(try event([.command, .control, .shift])))
        XCTAssertEqual(pageActions, 0, "Search and ordinary typing keep their original routing")
        XCTAssertEqual(window.toggles, 1)
    }

    func testNativeFullscreenMenuSurvivesRebuildWithOneCorrectlyNamedCommand() {
        final class FullscreenWindow: NSWindow {
            var reportsFullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { reportsFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue }
            }
        }
        let main = NSMenu(), view = NSMenu(title: "View")
        let top = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        top.submenu = view; main.addItem(top)
        let window = FullscreenWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        MainMenuLocalizationController.ensureFullscreenCommand(in: main, window: window)
        XCTAssertEqual(view.items.count, 1)
        XCTAssertEqual(view.items[0].title, MainMenuLocalization.title(for: "Enter Full Screen"))
        view.removeAllItems()
        window.reportsFullscreen = true
        MainMenuLocalizationController.ensureFullscreenCommand(in: main, window: window)
        XCTAssertEqual(view.items[0].title, MainMenuLocalization.title(for: "Exit Full Screen"))
        view.addItem(NSMenuItem(title: "Exit Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: ""))
        MainMenuLocalizationController.ensureFullscreenCommand(in: main, window: window)
        XCTAssertEqual(view.items.count, 1)
        XCTAssertEqual(view.items[0].action, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertNil(view.items[0].target)
        window.reportsFullscreen = false
    }

    func testFullscreenShortcutKeepsNativeResponderTargetAndLeavesPlayerFAlone() {
        let native = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        MainMenuLocalizationController.configureNativeFullscreenShortcut(native)
        XCTAssertEqual(native.action, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertNil(native.target, "AppKit must choose the active window through the responder chain")
        XCTAssertEqual(native.keyEquivalent, "f")
        XCTAssertEqual(native.keyEquivalentModifierMask, [.command, .control])
        let player = NSMenuItem(title: "Player F", action: nil, keyEquivalent: "f")
        player.keyEquivalentModifierMask = []
        MainMenuLocalizationController.configureNativeFullscreenShortcut(player)
        XCTAssertEqual(player.keyEquivalentModifierMask, [])
    }


}

private struct TMDBAuditAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = .init("tmdb-audit-actions"); return view }
    func updateNSView(_ view: NSView, context: Context) {}
}

private actor TMDBSeasonIdentityProbe: TMDBServing {
    let multiple: Bool
    var seasonCalls: [Int] = []
    init(multiple: Bool) { self.multiple = multiple }
    func decode<T: Decodable>(_ object: Any) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [try await detail(.init(type: .tv, id: 71))] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        try decode(["id":71, "name":"测试剧", "first_air_date":"2026-01-01", "media_type":"tv",
            "seasons": (multiple ? [0,1,2] : [0,1]).map { ["season_number":$0, "air_date":"2026-01-01", "episode_count":2] as [String:Any] }])
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason {
        seasonCalls.append(number)
        return try decode(["season_number":number, "episodes":(1...2).map { ["id":number * 100 + $0,"episode_number":$0,"season_number":number,"still_path":"/s\(number)e\($0).jpg"] as [String:Any] }])
    }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

extension TMDBDetailTests {
    func testDirectCredentialValidationAndKeychainFailurePreserveWorkingSession() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TMDB-direct-test-" + UUID().uuidString))
        let initial = try TMDBCredential(kind: .readAccessToken, value: "initial-token")
        let store = TMDBMemoryCredentialStore(initial), transport = TMDBSettingsTransport()
        let runtime = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        await transport.setStatus(401)
        let invalid = await runtime.validateAndSave(kind: .apiKey, value: "invalid-key")
        XCTAssertFalse(invalid); XCTAssertEqual(store.value, initial)
        XCTAssertEqual(runtime.credentialKind, .readAccessToken)
        await transport.setStatus(200); store.failWrites = true
        let unsaved = await runtime.validateAndSave(kind: .apiKey, value: "valid-but-unsaved")
        XCTAssertFalse(unsaved); XCTAssertEqual(store.value, initial)
        _ = try await runtime.client.imageConfiguration()
        let last = await transport.requests.last
        XCTAssertEqual(last?.headers["Authorization"], "Bearer initial-token")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("initial-token") })
    }

    func testDirectSaveDisableEnableDeleteAndRestartUseOneCredentialSession() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TMDB-direct-test-" + UUID().uuidString))
        defaults.set(TMDBPresentationPreference.original.rawValue, forKey: TMDBPresentationPreference.key)
        let store = TMDBMemoryCredentialStore(nil), transport = TMDBSettingsTransport()
        let runtime = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        let saved = await runtime.validateAndSave(kind: .apiKey, value: "customer-key")
        XCTAssertTrue(saved); XCTAssertEqual(runtime.credentialKind, .apiKey)
        _ = try await runtime.client.imageConfiguration()
        let restarted = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        await restarted.prepare()
        _ = try await restarted.client.imageConfiguration()
        await runtime.setEnabled(false)
        do { _ = try await runtime.client.imageConfiguration(); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .credentialMissing) }
        await runtime.setEnabled(true)
        _ = try await runtime.client.imageConfiguration()
        await runtime.deleteCredential()
        XCTAssertNil(store.value); XCTAssertNil(runtime.credentialKind)
        do { _ = try await runtime.client.imageConfiguration(); XCTFail() } catch { XCTAssertEqual(error as? TMDBError, .credentialMissing) }
        let requests = await transport.requests.filter { $0.url.host == "api.themoviedb.org" }
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "api.themoviedb.org" && $0.headers["Authorization"] == nil })
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("customer-key") })
    }

    func testDirectCredentialChangePreservesVerifiedCacheAndManualBinding() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TMDB-direct-test-" + UUID().uuidString))
        let runtime = TMDBNetworkRuntime(credentials: TMDBMemoryCredentialStore(nil), defaults: defaults, transport: TMDBSettingsTransport())
        let repository = TMDBRepository(client: TMDBDetailService())
        let detail = Self.detail(), input = TMDBMatchInput(detail: detail)
        _ = try await repository.choose(.init(type: .movie, id: 1), key: "manual", input: input)
        runtime.register(repository)
        let saved = await runtime.validateAndSave(kind: .readAccessToken, value: "new-token")
        XCTAssertTrue(saved)
        await runtime.deleteCredential()
        let cached = await repository.cachedResolution(key: "manual", input: input)
        guard case .matched(let candidate, let binding) = cached else { return XCTFail("Verified cache was discarded") }
        XCTAssertEqual(candidate.reference.id, 1); XCTAssertTrue(binding.manual)
    }

    func testDirectValidationRateLimitBlocksRepeatedSaveRequests() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TMDB-direct-test-" + UUID().uuidString))
        let store = TMDBMemoryCredentialStore(nil), transport = TMDBSettingsTransport()
        await transport.setStatus(429)
        let runtime = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        let first = await runtime.validateAndSave(kind: .apiKey, value: "customer-key")
        let second = await runtime.validateAndSave(kind: .apiKey, value: "customer-key")
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertNil(store.value)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let health = await runtime.availability.snapshot()
        XCTAssertEqual(health.metadata.failure, .rateLimited)
    }
}

@MainActor private final class TMDBMemoryCredentialStore: TMDBCredentialStoring {
    var value: TMDBCredential?
    var failWrites = false
    init(_ value: TMDBCredential?) { self.value = value }
    func load() throws -> TMDBCredential? { value }
    func save(_ value: TMDBCredential) throws { if failWrites { throw TMDBKeychainError(status: -1) }; self.value = value }
    func delete() throws { if failWrites { throw TMDBKeychainError(status: -1) }; value = nil }
}
private actor TMDBSettingsTransport: HTTPClient {
    var status = 200
    var requests: [HTTPRequest] = []
    func setStatus(_ value: Int) { status = value }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(url: request.url, statusCode: status, headers: ["Retry-After": "45"], body: Data(#"{"images":{"still_sizes":["w300"]}}"#.utf8))
    }
}

extension TMDBDetailTests {
    func testDirectKeychainRoundTripUsesIsolatedItemAndDeletesIt() throws {
        let store = KeychainTMDBCredentialStore(service: "com.okvideomac.tests.tmdb." + UUID().uuidString)
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let token = try TMDBCredential(kind: .readAccessToken, value: "test-only-keychain-token")
        try store.save(token)
        XCTAssertEqual(try store.load(), token)
        let key = try TMDBCredential(kind: .apiKey, value: "test-only-keychain-key")
        try store.save(key)
        XCTAssertEqual(try store.load(), key)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}


extension TMDBDetailTests {
    func testCandidateReviewDoesNotBindUntilUserChoosesAndResetsOnNavigation() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1550223,"title":"余光珍爱","media_type":"movie","release_date":"2025-10-15","credits":{"crew":[{"id":424258,"name":"Adolfo Alix Jr.","job":"Director"}]}}"#.utf8))
        let episodes = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[]}"#.utf8))
        let store = TMDBRepository(client: TMDBRenderService(work: work, episodes: episodes)), model = TMDBDetailModel()
        let detail = VideoDetail(summary: .init(siteKey: "wogg", siteName: "Wogg", videoID: "remaining", title: "余光珍爱", year: "2025"), director: "小阿多弗·亚历克斯")
        XCTAssertFalse(model.needsMatchConfirmation)
        await model.load(repository: store, key: "review", input: .init(detail: detail))
        XCTAssertTrue(model.needsMatchConfirmation); XCTAssertNil(model.selection)
        let before = await store.binding(key: "review", input: .init(detail: detail)); XCTAssertNil(before)
        let chosen = await model.choose(try XCTUnwrap(model.candidates.first))
        XCTAssertTrue(chosen); XCTAssertFalse(model.needsMatchConfirmation); XCTAssertEqual(model.binding?.manual, true)
        XCTAssertEqual(model.selection?.reference.id, 1550223)
        model.beginEntry(repository: nil, key: nil, summary: .init(siteKey: "s", siteName: "S", videoID: "other", title: "Other"), availability: TMDBAvailability(), enabled: true)
        XCTAssertFalse(model.needsMatchConfirmation); XCTAssertTrue(model.candidates.isEmpty); XCTAssertNil(model.selection)
        model.cancel()
    }
}


extension TMDBDetailTests {
    func testPendingConfirmationAndChosenMetadataKeepSynopsisFrame() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let work = try decoder.decode(TMDBWork.self, from: Data(#"{"id":1550223,"title":"余光珍爱","original_title":"The Time That Remains","media_type":"movie","release_date":"2025-10-15","overview":"等待确认的影片资料。","credits":{"crew":[{"id":424258,"name":"Adolfo Alix Jr.","job":"Director"}]}}"#.utf8))
        let season = try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[]}"#.utf8))
        let detail = VideoDetail(summary: .init(siteKey: "wogg", siteName: "Wogg", videoID: "remaining", title: "余光珍爱", year: "2025"), director: "小阿多弗·亚历克斯", synopsis: "源站影片简介。", playSources: [.init(name: "线路 A", episodes: [.init(name: "版本 1", url: "opaque:source")])])
        let output = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECTOR_VISUALS"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for width in [500.0, 900.0, 1600.0] {
            let model = TMDBDetailModel(), store = TMDBRepository(client: TMDBRenderService(work: work, episodes: season))
            let state = AppState(environment: nil)
            model.beginEntry(repository: nil, key: nil, summary: detail.summary, availability: TMDBAvailability(), enabled: true)
            let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(state))
            let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { model.cancel(); window.close() }
            func measured(_ label: String) async throws -> CGRect {
                try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
                let preview = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBSynopsisPreviewControl }.first)
                if let output {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("review-\(Int(width))-\(label).png"))
                }
                return preview.convert(preview.bounds, to: host)
            }
            let before = try await measured("source")
            await model.load(repository: store, key: "layout", input: .init(detail: detail))
            XCTAssertTrue(model.needsMatchConfirmation)
            let pending = try await measured("pending")
            let result = await model.choose(try XCTUnwrap(model.candidates.first)); XCTAssertTrue(result)
            let selected = try await measured("confirmed")
            for frame in [pending, selected] {
                XCTAssertEqual(frame.minY, before.minY, accuracy: 0.5, "Vertical jump at \(width)")
                XCTAssertEqual(frame.minX, before.minX, accuracy: 0.5)
                XCTAssertEqual(frame.width, before.width, accuracy: 0.5)
                XCTAssertEqual(frame.height, before.height, accuracy: 0.5)
            }
        }
    }
}

extension TMDBDetailTests {
    func testRelaxedPreferenceDefaultsOffAndPersists() throws {
        let name = "TMDBMatching-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TMDBMatchingPreferences.policy(defaults: defaults), .strict)
        defaults.set(true, forKey: TMDBMatchingPreferences.key)
        XCTAssertEqual(TMDBMatchingPreferences.policy(defaults: try XCTUnwrap(UserDefaults(suiteName: name))), .relaxed)
        defaults.set(false, forKey: TMDBMatchingPreferences.key)
        XCTAssertEqual(TMDBMatchingPreferences.policy(defaults: defaults), .strict)
    }
    func testRelaxedTitleOnlyEntryDoesNotWaitForSourceAndSurvivesMissingDirectorTranslation() async throws {
        let model = TMDBDetailModel(), store = TMDBRepository(client: TMDBRelaxedUIProbe())
        let card = VideoSummary(siteKey: "wogg", siteName: "玩偶哥哥", videoID: "remaining", title: "余光珍爱")
        model.beginEntry(repository: store, key: "a", summary: card, availability: TMDBAvailability(), enabled: true, policy: .relaxed)
        defer { model.cancel() }
        try await waitUntil { model.selection != nil && !model.isPreparing }
        XCTAssertEqual(model.selection?.reference.id, 1550223); XCTAssertFalse(model.isAwaitingSourceIdentity)
        XCTAssertTrue(model.binding?.isRelaxed == true)
        let navigation = model.navigationID
        let detail = VideoDetail(summary: .init(siteKey: "wogg", siteName: "玩偶哥哥", videoID: "remaining", title: "余光珍爱", year: "2025"), director: "小阿多弗·亚历克斯")
        model.receive(detail: detail, key: "a")
        XCTAssertNotNil(model.selection, "No flicker when richer source evidence is merely missing a translation")
        try await waitUntil { !model.isPreparing }
        XCTAssertEqual(model.navigationID, navigation); XCTAssertEqual(model.selection?.reference.id, 1550223)
        model.setMatchPolicy(.strict, detail: detail)
        XCTAssertNil(model.selection, "Switching off must clear a weak preview synchronously")
        try await waitUntil { !model.isPreparing }
        XCTAssertNil(model.selection); XCTAssertTrue(model.needsMatchConfirmation)
        model.setMatchPolicy(.relaxed, detail: detail)
        try await waitUntil { model.selection != nil && !model.isPreparing }
        XCTAssertEqual(model.navigationID, navigation)
    }
    func testRelaxedPreviewIsRemovedByExplicitSourceConflict() async throws {
        let model = TMDBDetailModel(), store = TMDBRepository(client: TMDBRelaxedUIProbe())
        let card = VideoSummary(siteKey: "s", siteName: "S", videoID: "1", title: "余光珍爱")
        model.beginEntry(repository: store, key: "a", summary: card, availability: TMDBAvailability(), enabled: true, policy: .relaxed)
        defer { model.cancel() }
        try await waitUntil { model.selection != nil }
        var summary = card; summary.year = "2024"
        model.receive(detail: .init(summary: summary), key: "a")
        XCTAssertNil(model.selection)
        try await waitUntil { !model.isPreparing }
        XCTAssertNil(model.selection)
    }
    func testDisablingRelaxedDuringPendingRequestCannotPublishLateResult() async throws {
        let service = TMDBRelaxedUIProbe(delay: 100_000_000), store = TMDBRepository(client: service), model = TMDBDetailModel()
        let detail = VideoDetail(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "余光珍爱"))
        model.beginEntry(repository: store, key: "a", summary: detail.summary, availability: TMDBAvailability(), enabled: true, policy: .relaxed)
        defer { model.cancel() }
        while await !service.started { await Task.yield() }
        model.setMatchPolicy(.strict, detail: detail)
        try await waitUntil { !model.isPreparing }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(model.selection); XCTAssertTrue(model.needsMatchConfirmation)
    }
    func testRelaxedMetadataAndToggleKeepPageGeometry() async throws {
        let detail = VideoDetail(summary: .init(siteKey: "wogg", siteName: "Wogg", videoID: "remaining", title: "余光珍爱", year: "2025"), director: "小阿多弗·亚历克斯", synopsis: "源站简介。", playSources: [.init(name: "线路 A", episodes: [.init(name: "版本 1", url: "opaque:source")])])
        let output = ProcessInfo.processInfo.environment["OKVIDEO_TMDB_DIRECTOR_VISUALS"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for width in [500.0, 900.0, 1600.0] {
            let model = TMDBDetailModel(), store = TMDBRepository(client: TMDBRelaxedUIProbe()), state = AppState(environment: nil)
            model.beginEntry(repository: nil, key: nil, summary: detail.summary, availability: TMDBAvailability(), enabled: true)
            let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(state))
            let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { model.cancel(); window.close() }
            func measured(_ label: String) async throws -> CGRect {
                try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
                let preview = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBSynopsisPreviewControl }.first)
                if let output {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("relaxed-\(Int(width))-\(label).png"))
                }
                return preview.convert(preview.bounds, to: host)
            }
            let before = try await measured("source")
            model.beginEntry(repository: store, key: "a", summary: detail.summary, availability: TMDBAvailability(), enabled: true, policy: .relaxed)
            model.receive(detail: detail, key: "a")
            try await waitUntil { model.selection != nil && !model.isPreparing }
            let enabled = try await measured("enabled")
            model.setMatchPolicy(.strict, detail: detail)
            try await waitUntil { !model.isPreparing }
            let disabled = try await measured("disabled")
            for frame in [enabled, disabled] {
                XCTAssertEqual(frame.minX, before.minX, accuracy: 0.5); XCTAssertEqual(frame.minY, before.minY, accuracy: 0.5)
                XCTAssertEqual(frame.width, before.width, accuracy: 0.5); XCTAssertEqual(frame.height, before.height, accuracy: 0.5)
            }
        }
    }
}
private actor TMDBRelaxedUIProbe: TMDBServing {
    let delay: UInt64
    private(set) var started = false
    init(delay: UInt64 = 0) { self.delay = delay }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { try await searchPage(query: query, type: type, year: year).results }
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        started = true
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return .init(results: [try await detail(.init(type: .movie, id: 1550223))], page: 1, totalPages: 1, totalResults: 1)
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: Data(#"{"id":1550223,"title":"余光珍爱","original_title":"The Time That Remains","media_type":"movie","release_date":"2025-10-15","overview":"已匹配的中文影片简介。","poster_path":"/poster.jpg","credits":{"crew":[{"id":424258,"name":"Adolfo Alix Jr.","job":"Director"}]}}"#.utf8))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

@MainActor final class TMDBDetailPolishTests: XCTestCase {
    func testActionColorsRemainStableAcrossWindowFocusAndAppearance() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Button-Match-Visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: VStack(spacing: 6) {
            TMDBNativeActionButton(title: "播放", identifier: "focus-play", prominent: true).frame(height: 44)
            HStack(spacing: 8) {
                ForEach(["star", "info.circle", "ellipsis"], id: \.self) { symbol in
                    TMDBNativeActionButton(title: symbol, symbol: symbol, identifier: symbol).frame(maxWidth: .infinity).frame(height: 42)
                }
            }.frame(maxWidth: .infinity)
        }.frame(width: 260).padding(24).background(Color(white: 0.65)))
        // Focus is a WindowServer interaction: use an on-screen window and
        // activate after ordering it, rather than relying on off-screen focus.
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: .init(x: origin.x + 40, y: origin.y + 40, width: 308, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .init(x: origin.x + 370, y: origin.y + 40, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        window.contentView = host
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); other.close(); NSApp.setActivationPolicy(previousPolicy) }
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            host.appearance = NSAppearance(named: appearance)
            var samples = [NSColor]()
            for active in [true, false] {
                if active { window.makeKeyAndOrderFront(nil) } else { other.makeKeyAndOrderFront(nil) }
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApp.activate(ignoringOtherApps: true)
                for _ in 0..<100 {
                    if window.isKeyWindow == active { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                if active && !NSApp.isActive {
                    throw XCTSkip("WindowServer did not grant foreground activation to the test host; active-window rendering requires a foreground session")
                }
                XCTAssertEqual(window.isKeyWindow, active, "appActive=\(NSApp.isActive), canBecomeKey=\(window.canBecomeKey), visible=\(window.isVisible)")
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let play = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "focus-play" })
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let rect = play.convert(play.bounds, to: host)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let y = host.isFlipped ? rect.midY : host.bounds.height - rect.midY
                let pixel = try XCTUnwrap(bitmap.colorAt(x: Int((rect.minX + 20) * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(pixel.redComponent, 0.95, "The play surface must stay white with an active detail window")
                XCTAssertGreaterThan(pixel.greenComponent, 0.95)
                XCTAssertGreaterThan(pixel.blueComponent, 0.95)
                samples.append(pixel)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("actions-\(style)-\(active ? "active" : "inactive").png"))
            }
            XCTAssertEqual(samples[0].redComponent, samples[1].redComponent, accuracy: 0.01)
        }
    }

    func testNativeActionsCenterSymbolsAndPreserveMenuActions() async throws {
        var played = false, invoked = false
        let host = NSHostingView(rootView: VStack(spacing: 8) {
            TMDBNativeActionButton(title: "播放", identifier: "play", prominent: true) { played = true }
                .frame(height: 44)
            HStack(spacing: 8) {
                ForEach(["star", "info.circle", "ellipsis"], id: \.self) { symbol in
                    TMDBNativeActionButton(title: symbol, symbol: symbol, identifier: symbol)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
            }.frame(maxWidth: .infinity)
        }.frame(width: 260).padding(12))
        let window = NSWindow(contentRect: .init(x: -2200, y: -2200, width: 284, height: 118), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        let buttons = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        let play = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "play" })
        XCTAssertEqual(play.title, "播放"); XCTAssertNil(play.image)
        XCTAssertEqual(play.contentTintColor, .black)
        XCTAssertEqual(play.bounds.width, 260, accuracy: 1)
        XCTAssertEqual(play.bounds.height, 44, accuracy: 1)
        play.performClick(nil); XCTAssertTrue(played)
        let surfaces = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBActionSurface }
        XCTAssertEqual(surfaces.count, 4)
        for surface in surfaces {
            XCTAssertEqual(surface.solidSurface.fillColor, .white)
            XCTAssertEqual(surface.materialSurface.state, .active, "Window focus must not recolor the material")
            XCTAssertEqual(surface.button.contentTintColor, .black)
        }
        for button in buttons where button !== play {
            XCTAssertEqual(button.title, ""); XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertFalse(button.isBordered)
            XCTAssertEqual(button.bounds.width, (260 - 16) / 3, accuracy: 1)
            XCTAssertEqual(button.bounds.height, 42, accuracy: 1)
            let cell = try XCTUnwrap(button.cell as? NSButtonCell)
            let imageRect = cell.imageRect(forBounds: button.bounds)
            XCTAssertEqual(imageRect.midX, button.bounds.midX, accuracy: 1)
            XCTAssertEqual(imageRect.midY, button.bounds.midY, accuracy: 2)
        }
        let coordinator = TMDBNativeActionButton.Coordinator()
        coordinator.menuItems = [.status("已匹配"), .separator, .action("刷新") { invoked = true }, .action("不可用", enabled: false) {}]
        let menu = coordinator.makeMenu()
        XCTAssertEqual(menu.items.map(\.title), ["已匹配", "", "刷新", "不可用"])
        XCTAssertTrue(menu.items[1].isSeparatorItem); XCTAssertFalse(menu.items[3].isEnabled)
        menu.performActionForItem(at: 2); XCTAssertTrue(invoked)
    }

    private func key(_ code: UInt16, window: NSWindow? = nil, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: code == 36 ? "\r" : "",
            charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code))
    }
    func testKeyboardUsesVisibleOrderBoundariesAndExactPlaybackTarget() throws {
        let controller = TMDBEpisodeKeyboardController()
        var selected = [String](), played = [String]()
        controller.onSelect = { selected.append($0) }; controller.onPlay = { played.append($0) }
        controller.configure(ids: ["episode26", "episode23", "bonus"], selectedID: "episode23")
        XCTAssertTrue(controller.handle(try key(123)))
        XCTAssertEqual(selected.last, "episode26")
        XCTAssertTrue(controller.handle(try key(123, repeatKey: true)))
        XCTAssertEqual(selected.last, "episode26")
        for _ in 0..<4 { XCTAssertTrue(controller.handle(try key(124, repeatKey: true))) }
        XCTAssertEqual(selected.last, "bonus"); XCTAssertTrue(played.isEmpty)
        XCTAssertTrue(controller.handle(try key(36))); XCTAssertTrue(controller.handle(try key(36, repeatKey: true)))
        XCTAssertEqual(played, ["bonus"])
        XCTAssertFalse(controller.handle(try key(123, modifiers: .command)))
        XCTAssertFalse(controller.handle(try key(125)))
        controller.configure(ids: ["otherLine1", "otherLine9"], selectedID: "episode23")
        XCTAssertTrue(controller.handle(try key(124)))
        XCTAssertEqual(selected.last, "otherLine1")
        XCTAssertTrue(controller.handle(try key(36))); XCTAssertEqual(played.last, "otherLine1")
        controller.configure(ids: [], selectedID: nil)
        XCTAssertFalse(controller.handle(try key(124)))
    }

    func testMouseSelectionThenArrowsKeepFocusAcrossLazyCardRecycling() async throws {
        let resources = (1...54).map { PlayEpisode(name: "第 \($0) 集", url: "opaque:original:\($0)") }
        let episodes = resources.enumerated().map { index, episode in
            EpisodePresentation(episode: episode, displayName: episode.name, originalName: episode.name,
                seasonNumber: 1, episodeNumber: index + 1, isSpecial: false, sourceIndex: index)
        }
        var selected: String?, played: String?
        let host = NSHostingView(rootView: TMDBPolishKeyboardHarness(episodes: episodes,
            onSelect: { selected = $0 }, onPlay: { played = $0 }))
        let window = NSWindow(contentRect: .init(x: -2200, y: -2200, width: 520, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBEpisodeActivationControl }.first)
        let point = control.convert(.init(x: 40, y: 40), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        control.mouseDown(with: down); control.activate(clickCount: 1)
        XCTAssertEqual(selected, resources[0].id)
        let responder = try XCTUnwrap(window.firstResponder as? TMDBEpisodeKeyboardView)
        XCTAssertNil(control.toolTip)
        for index in 1...32 {
            window.firstResponder?.keyDown(with: try key(124, window: window, repeatKey: index > 1))
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await Task.sleep(nanoseconds: 180_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(selected, resources[32].id); XCTAssertNil(played)
        let scroll = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 1000, "Offscreen selection must reveal itself")
        window.firstResponder?.keyDown(with: try key(36, window: window))
        XCTAssertEqual(played, resources[32].id)
        // A real field editor owns arrows while editing; there is no global key monitor.
        let field = NSTextField(frame: .init(x: 0, y: 180, width: 200, height: 24))
        host.addSubview(field); field.stringValue = "abc"; window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(.init(location: 3, length: 0)); editor.moveLeft(nil)
        XCTAssertEqual(editor.selectedRange().location, 2); XCTAssertEqual(selected, resources[32].id)
    }

    func testCompactCardsKeepMeaningAndTMDBDurationStaysUnchanged() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let mapped = try decoder.decode(TMDBEpisode.self, from: Data(#"{"id":23,"season_number":1,"episode_number":23,"name":"华子想挖星池望和不肯放人","runtime":45}"#.utf8))
        let episode = PlayEpisode(name: "北上 - S01E23.mkv", url: "opaque:23")
        let item = EpisodeNameParser.presentation(for: episode, categoryName: "电视剧")
        let title = TMDBEpisodeCards.title(item, mapped: mapped)
        XCTAssertEqual(title, L10n.string("tmdb.episode.number", fallback: "Episode %d", 23) + " · 华子想挖星池望和不肯放人")
        XCTAssertFalse(title.contains(".mkv")); XCTAssertFalse(title.contains("S01"))
        let split = EpisodeNameParser.presentation(for: .init(name: "第23集下", url: "opaque:part"), categoryName: "电视剧")
        XCTAssertTrue(TMDBEpisodeCards.title(split, mapped: mapped).contains("下"))
        let source = PlaySource(name: "原始线路", episodes: [episode])
        let detail = VideoDetail(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "北上", categoryName: "电视剧"), playSources: [source])
        let info = TMDBEpisodeInformation.make(detail: detail, work: nil, season: nil, source: source, episode: episode, mappedEpisode: mapped)
        XCTAssertTrue(info.facts.contains("45")); XCTAssertFalse(info.facts.contains("46")); XCTAssertFalse(info.facts.contains("4K"))
    }

    func testOriginalNameFooterRendersFullLongNameAtNarrowWidth() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Detail-Polish-Visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "北上 - S01E26 - " + String(repeating: "原始文件名称", count: 16) + ".mkv"
        let host = NSHostingView(rootView: VStack(alignment: .leading) {
            DetailResourceFooter(originalName: name)
            Spacer()
        }.frame(width: 400, height: 240).background(Color.white))
        let window = NSWindow(contentRect: .init(x: -2200, y: -2200, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("original-name-narrow.png"))
        XCTAssertEqual(PlaybackMediaInfo.safeFileName(name), name)
        XCTAssertEqual(PlaybackMediaInfo.safeFileName("北上 - S01E26.mkv"), "北上 - S01E26.mkv")
    }

    func testTitleLogoAndTextFallbackKeepSameGeometry() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Detail-Polish-Visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Self-contained transparent bitmap: the regression must not depend on
        // a developer's downloaded logo or on a remote artwork service.
        let artwork = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 140,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 480, bitsPerPixel: 32))
        for x in 0..<120 { for y in 0..<140 {
            artwork.setColor(NSColor(deviceRed: 1, green: 0.8, blue: 0, alpha: x > 20 && x < 100 && y > 5 && y < 135 ? 1 : 0), atX: x, y: y)
        } }
        let probe = TMDBSeasonImageProbe(data: try XCTUnwrap(artwork.representation(using: .png, properties: [:])))
        let images = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: directory.appendingPathComponent(UUID().uuidString), httpClient: probe))
        let url = URL(string: "https://image.tmdb.org/t/p/w500/northward.png")!
        _ = try await images.posterImage(for: .init(url: url, pixels: 500), priority: .visible)
        for (name, logo) in [("logo", Optional(url)), ("missing-logo", nil)] {
            for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: TMDBWorkTitle(title: "北上", logoURL: logo, width: 240)
                    .padding(20).background(AppSurfacePalette.background).environment(\.imageRepository, images))
                let window = NSWindow(contentRect: .init(x: -2200, y: -2200, width: 280, height: 138), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: appearance)
                try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 280, accuracy: 1); XCTAssertEqual(host.fittingSize.height, 138, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(style).png"))
                if logo != nil {
                    var minX = bitmap.pixelsWide, maxX = 0
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                        if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           pixel.redComponent > 0.8, pixel.greenComponent > 0.6, pixel.blueComponent < 0.4 {
                            minX = min(minX, x); maxX = max(maxX, x)
                        }
                    } }
                    XCTAssertLessThan(minX, maxX)
                    XCTAssertEqual(CGFloat(minX + maxX) / 2, CGFloat(bitmap.pixelsWide) / 2, accuracy: 2,
                        "Portrait title artwork must share the play button's center line")
                }
                window.close()
            }
        }
    }
}

private struct TMDBPolishKeyboardHarness: View {
    let episodes: [EpisodePresentation]
    let onSelect: (String) -> Void
    let onPlay: (String) -> Void
    @State private var selectedID: String?
    @StateObject private var metadata = TMDBDetailModel()
    var body: some View {
        TMDBEpisodeCards(metadata: metadata, episodes: episodes, sourceIdentity: "keyboard-test", sourceEpisodes: episodes.map(\.episode),
            category: "电视剧", selectedID: selectedID, fallbackURL: nil,
            onSelect: { selectedID = $0.id; onSelect($0.id) }, onPlay: { onPlay($0.id) })
    }
}

/// Explicit visual review harness. Reads only the supplied offline fixture and
/// renders the production DetailView; it never starts provider playback.
@MainActor final class TMDBDetailReferencePreviewTests: XCTestCase {
    func testReferenceArtworkPreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["OKVIDEOMAC_DETAIL_PREVIEW_FIXTURE"] else {
            throw XCTSkip("Supply an offline reference fixture for visual review")
        }
        let root = URL(fileURLWithPath: path), decoder = JSONDecoder()
        let work = try decoder.decode(TMDBWork.self, from: Data(contentsOf: root.appendingPathComponent("work.json")))
        let season = try decoder.decode(TMDBSeason.self, from: Data(contentsOf: root.appendingPathComponent("season.json")))
        let episodes = season.episodes.map { PlayEpisode(name: "\(work.displayTitle) - S01E\(String(format: "%02d", $0.episodeNumber)).mkv", url: "opaque:preview:\($0.episodeNumber)") }
        let detail = VideoDetail(summary: .init(siteKey: "preview", siteName: "预览", videoID: String(work.id), title: work.displayTitle, year: work.year.map(String.init), categoryName: "电视剧"),
            synopsis: work.overview, playSources: [.init(name: "预览线路", episodes: episodes)])
        let model = TMDBDetailModel()
        await model.load(repository: TMDBRepository(client: TMDBRenderService(work: work, episodes: season)), key: "reference-preview", input: .init(detail: detail))
        XCTAssertEqual(model.selection?.reference.id, work.id)
        await model.loadSeason(source: detail.playSources[0], category: "电视剧")
        let output = root.appendingPathComponent("Preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let images = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: output.appendingPathComponent("cache"), httpClient: TMDBRenderImages(root: root.appendingPathComponent("images"))))
        let urls = [model.artwork(.backdrop), model.artwork(.logo)] + season.episodes.map { model.imageURL($0.stillPath, kind: .still) } + work.cast.prefix(20).map { model.imageURL($0.profilePath, kind: .profile) }
        for url in urls.compactMap({ $0 }) { _ = try? await images.image(for: url) }
        for (name, width, height, appearance) in [("window", 1280.0, 940.0, NSAppearance.Name.aqua), ("fullscreen", 2020.0, 1210.0, .aqua), ("dark", 1280.0, 940.0, .darkAqua)] {
            let host = NSHostingView(rootView: DetailView(detail: detail, metadata: model).environmentObject(AppState(environment: nil)).environment(\.imageRepository, images))
            let window = NSWindow(contentRect: .init(x: -3000, y: -2200, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 500_000_000); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("detail-\(name).png"))
            let surfaces = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? TMDBActionSurface }
            XCTAssertEqual(surfaces.count, 4)
            for surface in surfaces {
                XCTAssertEqual(surface.bounds.height, surface.solidSurface.isHidden ? 42 : 44, accuracy: 0.5)
            }
            let primary = try XCTUnwrap(surfaces.first { !$0.solidSurface.isHidden })
            let primaryRect = primary.convert(primary.bounds, to: host)
            let secondaryRects = surfaces.filter { $0.solidSurface.isHidden }.map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(try XCTUnwrap(secondaryRects.first).minX, primaryRect.minX, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(secondaryRects.last).maxX, primaryRect.maxX, accuracy: 1)
            for rect in secondaryRects { XCTAssertEqual(rect.width, (primaryRect.width - 16) / 3, accuracy: 1) }
            if name == "window" {
                let play = try XCTUnwrap(surfaces.first { !$0.solidSurface.isHidden })
                let playRect = play.convert(play.bounds, to: host)
                // Use the actual view's coordinate system for a close-up, not a
                // separately styled mockup. Include title, actions and stills.
                let top = host.isFlipped ? playRect.minY - 115 : playRect.maxY + 115
                let crop = NSRect(x: 0, y: host.isFlipped ? top : top - 490, width: min(1100, width), height: 490).intersection(host.bounds)
                let closeup = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: crop))
                host.cacheDisplay(in: crop, to: closeup)
                try XCTUnwrap(closeup.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("detail-closeup.png"))
                let actionsRect = NSRect(x: playRect.minX - 12, y: host.isFlipped ? top : top - 219, width: playRect.width + 24, height: 219).intersection(host.bounds)
                let actions = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: actionsRect))
                host.cacheDisplay(in: actionsRect, to: actions)
                try XCTUnwrap(actions.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("actions-closeup.png"))
            }
            window.close()
        }
    }
}

@MainActor final class TMDBDetailPerformanceTests: XCTestCase {
    private func fixture(multiple: Bool = false) async throws -> TMDBDetailModel {
        let model = TMDBDetailModel()
        let detail = VideoDetail(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "测试剧", year: "2026", categoryName: "电视剧"))
        await model.load(repository: TMDBRepository(client: TMDBSeasonIdentityProbe(multiple: multiple)), key: "performance", input: .init(detail: detail))
        XCTAssertNotNil(model.selection)
        return model
    }

    func testRepeatedDisplayReadsReuseOffMainMappingAndPreserveResourceOrder() async throws {
        let model = try await fixture()
        defer { model.cancel() }
        let source = PlaySource(name: "Line", episodes: [.init(name: "S01E02", url: "opaque:two"), .init(name: "S01E01", url: "opaque:one"), .init(name: "S09E01", url: "opaque:wrong")])
        await model.loadSeason(source: source, category: "电视剧")
        let initial = model.episodeMapping(source: source, category: "电视剧")
        XCTAssertEqual(initial[0]?.episodeNumber, 2)
        XCTAssertEqual(initial[1]?.episodeNumber, 1)
        XCTAssertNil(initial[2])
        XCTAssertFalse(model.episodeMappingComputedOnMain)
        let count = model.episodeMappingComputationCount
        for _ in 0..<500 {
            XCTAssertEqual(model.episodeMapping(source: source, category: "电视剧"), initial)
        }
        await model.prepareEpisodeMapping(source: source, category: "电视剧")
        XCTAssertEqual(model.episodeMappingComputationCount, count, "Redraws and duplicate preparation must reuse one result")
        XCTAssertEqual(source.episodes.map(\.url), ["opaque:two", "opaque:one", "opaque:wrong"])
    }

    func testSameNamedSourceReplacementAndCategoryCannotReuseStaleMapping() async throws {
        let model = try await fixture()
        defer { model.cancel() }
        let source = PlaySource(name: "Line", episodes: [.init(name: "S01E01", url: "one"), .init(name: "S01E02", url: "two")])
        await model.loadSeason(source: source, category: "电视剧")
        var changed = source; changed.episodes.reverse()
        XCTAssertTrue(model.episodeMapping(source: changed, category: "电视剧").isEmpty)
        await model.prepareEpisodeMapping(source: changed, category: "电视剧")
        XCTAssertEqual(model.episodeMapping(source: changed, category: "电视剧")[0]?.episodeNumber, 2)
        XCTAssertTrue(model.episodeMapping(source: source, category: "电视剧").isEmpty)
        await model.prepareEpisodeMapping(source: changed, category: "电影")
        XCTAssertTrue(model.episodeMapping(source: changed, category: "电影").isEmpty)
    }

    func testSeasonSelectionInvalidatesAndCancellationRejectsLateMapping() async throws {
        let model = try await fixture(multiple: true)
        defer { model.cancel() }
        let source = PlaySource(name: "Line", episodes: [.init(name: "01.mp4", url: "opaque:one")])
        await model.selectSeason(2, source: source)
        await model.loadSeason(source: source, category: nil)
        XCTAssertEqual(model.episodeMapping(source: source, category: nil)[0]?.stillPath, "/s2e1.jpg")
        await model.selectSeason(1, source: source)
        XCTAssertTrue(model.episodeMapping(source: source, category: nil).isEmpty)
        await model.loadSeason(source: source, category: nil)
        XCTAssertEqual(model.episodeMapping(source: source, category: nil)[0]?.stillPath, "/s1e1.jpg")
        let pending = Task { await model.prepareEpisodeMapping(source: source, category: "电视剧") }
        await Task.yield()
        model.cancel()
        await pending.value
        XCTAssertTrue(model.episodeMapping(source: source, category: "电视剧").isEmpty)
    }

    func testMemoryTrimPreservesVisiblePixelsAndRestoresFromDiskWithoutNetwork() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1280, bitsPerPixel: 32))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let probe = TMDBSeasonImageProbe(data: bytes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = ImageRepository(dataRepository: try ImageDataRepository(cacheDirectory: directory, httpClient: probe))
        let request = PosterImageRequest(url: try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w300/performance-test.jpg")), pixels: 320)
        let displayed = try await images.posterImage(for: request)
        let originalPixels = displayed.tiffRepresentation
        images.trimDecodedMemoryCache()
        XCTAssertNil(images.cachedPoster(for: request))
        XCTAssertEqual(displayed.tiffRepresentation, originalPixels, "Visible views retain identical pixels during pressure eviction")
        let restored = try await images.posterImage(for: request)
        XCTAssertEqual(restored.tiffRepresentation, originalPixels)
        let calls = await probe.paths
        XCTAssertEqual(calls.count, 1, "Pressure must preserve the validated disk cache")
    }
}

@MainActor final class TMDBPresentationRuntimeTests: XCTestCase {
    private func runtime(original: Bool = false, credential: Bool = true) async throws -> (TMDBNetworkRuntime, TMDBPolicyTransport, TMDBMemoryCredentialStore) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TMDB-presentation-\(UUID())"))
        if original { defaults.set(false, forKey: TMDBPresentationPreference.legacyKey) }
        let store = TMDBMemoryCredentialStore(credential ? try TMDBCredential(kind: .apiKey, value: "test-only") : nil)
        let transport = TMDBPolicyTransport()
        let runtime = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        await runtime.prepare()
        return (runtime, transport, store)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Condition did not settle")
    }
    func testEntryReturnsOriginalImmediatelyThenBothLinksEnableNextEntry() async throws {
        let (runtime, transport, _) = try await runtime()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(runtime.decisionForEntry().usesTMDB)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.05)
        try await wait { runtime.presentationDecision.usesTMDB }
        XCTAssertTrue(runtime.decisionForEntry().usesTMDB)
        for _ in 0..<10 { runtime.warm() }
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await transport.count
        XCTAssertEqual(count, 2, "Repeated entry must reuse fresh API and image evidence")
    }
    func testMissingCredentialAndExplicitOriginalDoNotAutomaticallyProbe() async throws {
        for configuration in [(false, true), (true, false)] {
            let (runtime, transport, _) = try await runtime(original: configuration.0, credential: configuration.1)
            if !configuration.0 { await runtime.deleteCredential() }
            XCTAssertFalse(runtime.decisionForEntry().usesTMDB)
            try await Task.sleep(nanoseconds: 30_000_000)
            let count = await transport.count; XCTAssertEqual(count, 0)
        }
    }
    func testExplicitOriginalWithSavedCredentialWinsAndAutomaticCanRecover() async throws {
        let (runtime, transport, _) = try await runtime(original: true)
        XCTAssertEqual(runtime.decisionForEntry(), .originalPreference)
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await transport.count; XCTAssertEqual(count, 0)
        runtime.setPreference(.automatic)
        try await wait { runtime.presentationDecision.usesTMDB }
        _ = try await runtime.service.imageConfiguration()
        runtime.setPreference(.original)
        XCTAssertEqual(runtime.decisionForEntry(), .originalPreference)
        try await wait { !runtime.isChangingNetwork }
    }
    func testSaveWithBrokenImagesKeepsCredentialButDoesNotEnableLayout() async throws {
        let (runtime, transport, store) = try await runtime(credential: false)
        await transport.setImageStatus(503)
        let saved = await runtime.validateAndSave(kind: .apiKey, value: "new-test-key")
        XCTAssertTrue(saved); XCTAssertNotNil(store.value)
        XCTAssertEqual(runtime.links?.metadata.state, .available)
        XCTAssertEqual(runtime.links?.images.state, .unavailable)
        XCTAssertFalse(runtime.presentationDecision.usesTMDB)
        XCTAssertFalse(runtime.busy)
        await transport.setImageStatus(200)
        await runtime.checkConnections()
        XCTAssertTrue(runtime.presentationDecision.usesTMDB)
    }
    func testNetworkChangeAndDisableInvalidateReadinessBeforeAwaiting() async throws {
        let (runtime, transport, _) = try await runtime()
        await runtime.checkConnections()
        XCTAssertTrue(runtime.presentationDecision.usesTMDB)
        await transport.setImageStatus(503)
        runtime.changed()
        XCTAssertFalse(runtime.decisionForEntry().usesTMDB)
        try await wait { runtime.links?.images.state == .unavailable }
        await runtime.setEnabled(false)
        XCTAssertEqual(runtime.decisionForEntry(), .serviceDisabled)
    }
    func testRejectedReplacementPreservesPreviouslyReadyCredential() async throws {
        let (runtime, transport, store) = try await runtime()
        await runtime.checkConnections()
        let initial = store.value
        await transport.setAPIStatus(401)
        let saved = await runtime.validateAndSave(kind: .apiKey, value: "rejected")
        XCTAssertFalse(saved); XCTAssertEqual(store.value, initial)
        XCTAssertTrue(runtime.presentationDecision.usesTMDB)
    }
    func testCancelledImageCheckStopsProbeAndRetainsCommittedCredential() async throws {
        let (runtime, transport, store) = try await runtime(credential: false)
        await transport.setSuspendImages(true)
        let task = Task { await runtime.validateAndSave(kind: .apiKey, value: "committed") }
        try await wait { runtime.links?.images.checking == true }
        task.cancel()
        let saved = await task.value
        XCTAssertTrue(saved); XCTAssertNotNil(store.value)
        XCTAssertFalse(runtime.busy); XCTAssertFalse(runtime.links?.images.checking == true)
        XCTAssertFalse(runtime.presentationDecision.usesTMDB)
        for _ in 0..<1000 { if await transport.cancelledImages > 0 { break }; await Task.yield() }
        let cancelled = await transport.cancelledImages; XCTAssertEqual(cancelled, 1)
    }
}

private actor TMDBPolicyTransport: HTTPClient {
    private var apiStatus = 200, imageStatus = 200
    private var suspendImages = false
    private(set) var count = 0
    private(set) var cancelledImages = 0
    func setAPIStatus(_ value: Int) { apiStatus = value }
    func setImageStatus(_ value: Int) { imageStatus = value }
    func setSuspendImages(_ value: Bool) { suspendImages = value }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        let image = request.url.host == "image.tmdb.org"
        if image && suspendImages {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelledImages += 1; throw error }
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        return .init(url: request.url, statusCode: image ? imageStatus : apiStatus, headers: [:],
                     body: image ? png : Data(#"{"images":{"still_sizes":["w300"]}}"#.utf8))
    }
}

extension TMDBPresentationRuntimeTests {
    func testSettingsMenuPersistsAndConnectionStatesFitNarrowAndWidePanes() async throws {
        let (runtime, transport, _) = try await runtime(credential: false)
        let state = AppState(environment: nil, tmdbRuntime: runtime)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OKVideoMac-TMDB154-Preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [480.0, 920.0] {
            let host = NSHostingView(rootView: DetailSettingsPane(runtime: runtime)
                .environmentObject(state).environmentObject(state.settingsNavigation))
            let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: 760),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 80_000_000)
            host.layoutSubtreeIfNeeded()
            let picker = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
            func capture(_ name: String) async throws {
                try await Task.sleep(nanoseconds: 80_000_000); host.layoutSubtreeIfNeeded()
                let frame = picker.convert(picker.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("settings-\(Int(width))-\(name).png"))
            }
            await runtime.deleteCredential()
            await runtime.setEnabled(true)
            XCTAssertEqual(runtime.presentationDecision, .missingCredential)
            try await capture("missing")
            let menu = try XCTUnwrap(picker.menu)
            XCTAssertNotNil(menu.item(at: 1)?.action)
            menu.performActionForItem(at: 1)
            XCTAssertEqual(runtime.preference, .original)
            XCTAssertEqual(runtime.presentationDecision, .originalPreference)
            try await capture("original")
            XCTAssertNotNil(menu.item(at: 0)?.action)
            menu.performActionForItem(at: 0)
            XCTAssertEqual(runtime.preference, .automatic)
            await transport.setImageStatus(200)
            let saved = await runtime.validateAndSave(kind: .apiKey, value: "preview-fixture-only")
            XCTAssertTrue(saved); XCTAssertEqual(runtime.presentationDecision, .ready)
            try await capture("ready")
            await transport.setImageStatus(503)
            runtime.changed()
            await runtime.checkConnections()
            XCTAssertEqual(runtime.presentationDecision, .connectionUnavailable)
            try await capture("unavailable")
            await runtime.setEnabled(false)
            XCTAssertEqual(runtime.presentationDecision, .serviceDisabled)
            try await capture("disabled")
        }
    }

    func testMainEntryUsesOriginalUntilReadyAndNeverChangesMountedLayoutAutomatically() async throws {
        let (runtime, transport, _) = try await runtime()
        let provider = TMDBEntryProvider()
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider], tmdbRuntime: runtime)
        await state.loadDetail(provider.summary("one"))
        XCTAssertFalse(state.tmdbDetailModel.usesUnifiedLayout)
        XCTAssertNotNil(state.selectedDetail)
        await runtime.checkConnections()
        XCTAssertTrue(runtime.presentationDecision.usesTMDB)
        XCTAssertFalse(state.tmdbDetailModel.usesUnifiedLayout)
        await state.loadDetail(provider.summary("two"))
        XCTAssertTrue(state.tmdbDetailModel.usesUnifiedLayout)
        let navigation = state.tmdbDetailModel.navigationID
        await transport.setImageStatus(503)
        runtime.changed()
        XCTAssertTrue(state.tmdbDetailModel.usesUnifiedLayout, "Current TMDB layout must survive route changes")
        XCTAssertTrue(state.tmdbDetailModel.networkRequestsSuspended)
        XCTAssertEqual(state.tmdbDetailModel.navigationID, navigation)
        await state.loadDetail(provider.summary("three"))
        XCTAssertFalse(state.tmdbDetailModel.usesUnifiedLayout)
    }

    func testRelatedEntryUsesTheSamePolicyAndRefreshDoesNotPromoteOriginal() async throws {
        let (runtime, _, _) = try await runtime()
        let provider = TMDBEntryProvider()
        let state = AppState(environment: nil, initialProviders: [provider.site.key: provider], tmdbRuntime: runtime)
        let configuration = StoredConfiguration(name: "TMDB Fixture", sourceKind: .pasted,
            rawData: Data(#"{"sites":[{"key":"entry","name":"Entry","type":1,"api":"https://fixture.invalid"}]}"#.utf8), isActive: true)
        try state.setSettingsConfigurationsForTesting([configuration])
        let browser = TMDBRelatedBrowser()
        let original = TMDBRelatedPage(kind: .detail, title: "One", source: provider.summary("one"), configurationID: configuration.id)
        browser.load(original, state: state)
        await original.task?.value
        XCTAssertNotNil(original.detail); XCTAssertFalse(original.metadata.usesUnifiedLayout)
        await runtime.checkConnections()
        browser.load(original, state: state, refresh: true)
        await original.task?.value
        XCTAssertFalse(original.metadata.usesUnifiedLayout)
        let enhanced = TMDBRelatedPage(kind: .detail, title: "Two", source: provider.summary("two"), configurationID: configuration.id)
        browser.load(enhanced, state: state)
        await enhanced.task?.value
        XCTAssertNotNil(enhanced.detail); XCTAssertTrue(enhanced.metadata.usesUnifiedLayout)
        runtime.setPreference(.original)
        let next = TMDBRelatedPage(kind: .detail, title: "Three", source: provider.summary("three"), configurationID: configuration.id)
        browser.load(next, state: state)
        await next.task?.value
        XCTAssertFalse(next.metadata.usesUnifiedLayout)
    }

    func testSuspendingCurrentPageRetainsVerifiedMetadataAndNavigation() async throws {
        let detail = TMDBDetailTests.detail(), model = TMDBDetailModel()
        let repository = TMDBRepository(client: TMDBDetailService())
        model.beginEntry(repository: repository, key: "freeze", summary: detail.summary, availability: TMDBAvailability(), enabled: true)
        model.receive(detail: detail, key: "freeze")
        try await wait { model.selection != nil && !model.isPreparing }
        let selected = model.selection, navigation = model.navigationID
        model.suspendNetworkRequests()
        XCTAssertTrue(model.usesUnifiedLayout)
        XCTAssertEqual(model.selection, selected)
        XCTAssertEqual(model.navigationID, navigation)
        model.receive(detail: detail, key: "freeze")
        XCTAssertFalse(model.isPreparing)
        model.setPresentationEnabled(false, detail: detail)
        XCTAssertFalse(model.usesUnifiedLayout)
        XCTAssertEqual(model.navigationID, navigation)
    }
}

private struct TMDBEntryProvider: SiteProvider {
    let site = SiteConfiguration(key: "entry", name: "Entry", type: 1, api: "https://fixture.invalid")
    var capability: SiteCapability { .standardJSON }
    func summary(_ id: String) -> VideoSummary { .init(siteKey: site.key, siteName: site.name, videoID: id, title: "Fixture \(id)") }
    func home() async throws -> SiteHome { .init(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { throw TMDBError.invalidInput }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { throw TMDBError.invalidInput }
    func detail(id: String) async throws -> VideoDetail {
        .init(summary: summary(id), synopsis: "Source information", playSources: [.init(name: "Line A", episodes: [.init(name: "Episode 1", url: "opaque:1"), .init(name: "Episode 2", url: "opaque:2")])])
    }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw TMDBError.invalidInput }
}
