import AppKit
import Combine
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import XCTest
@testable import OKVideoMac

@MainActor final class SettingsRedesignTests: XCTestCase {
    func testSettingsIsTheSelectedSidebarSectionAndLocalQueriesStayIsolated() {
        let state = AppState(environment: nil)
        state.searchDraftKeyword = "电影"
        state.presentHomeSearch()
        state.selectSection(.settings)
        XCTAssertEqual(state.selectedSection, .settings)
        XCTAssertFalse(state.isHomeSearchPresented)
        XCTAssertEqual(state.searchDraftKeyword, "电影")
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        state.sidebarSearch.settings = "TMDB"
        state.sidebarSearch.favorites = "收藏"
        state.sidebarSearch.history = "剧集"
        XCTAssertEqual(changes, 0, "Local typing must not invalidate the detail/browser publisher")
        for section in AppSection.allCases { state.selectSection(section) }
        XCTAssertEqual(state.sidebarSearch.settings, "TMDB")
        XCTAssertEqual(state.sidebarSearch.favorites, "收藏")
        XCTAssertEqual(state.sidebarSearch.history, "剧集")
        XCTAssertEqual(state.searchDraftKeyword, "电影")
        withExtendedLifetime(observation) {}
    }

    func testNativeSearchEditsOnlyTheCurrentSectionAndRejectsStaleCallbacks() {
        let state = AppState(environment: nil), live = LiveBrowserSession()
        for section in AppSection.allCases {
            state.selectSection(section)
            let binding = SidebarSearchBinding.text(for: section, state: state, live: live)
            let parent = NativeSidebarSourceList(text: binding,
                presentation: SidebarSearchPresentationPolicy.presentation(for: section),
                isSearchEnabled: true, focusRequest: 0, selection: state.navigation.selection,
                navigation: state.navigation, onTextChange: { _ in }, onSubmit: {},
                onExitSearch: { true }, onSelect: state.selectSection)
            let coordinator = parent.makeCoordinator()
            let field = NSSearchField(string: section.rawValue)
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(binding.wrappedValue, section.rawValue)
            XCTAssertEqual(state.selectedSection, section)
            XCTAssertFalse(state.isHomeSearchPresented)
            let next: AppSection = section == .home ? .settings : .home
            state.selectSection(next)
            field.stringValue = "stale edit"
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            coordinator.submit(field)
            XCTAssertEqual(binding.wrappedValue, section.rawValue)
        }
        for section in AppSection.allCases {
            XCTAssertEqual(SidebarSearchBinding.text(for: section, state: state, live: live).wrappedValue, section.rawValue)
        }
    }

    func testLibrarySearchMatchesAllTermsAcrossTitleSourceAndEpisode() {
        XCTAssertTrue(LibrarySearchQuery("  Café  第2集 ").matches("CAFE 小城", "片源 · 第2集"))
        XCTAssertFalse(LibrarySearchQuery("小城 第3集").matches("小城", "片源 · 第2集"))
        XCTAssertTrue(LibrarySearchQuery("片源 小城").matches("小城", "片源"))
        XCTAssertTrue(LibrarySearchQuery(" \n ").matches("任何片名", "任何来源"))
    }

    func testMountedHistoryFiltersImmediatelyAndKeepsUnderlyingRecords() async throws {
        let state = AppState(environment: nil)
        let records = [HistoryRecord(configurationID: UUID(), siteKey: "fixture", videoID: "a", title: "小城故事"),
                       HistoryRecord(configurationID: UUID(), siteKey: "fixture", videoID: "b", title: "远方")]
        state.watchHistory.replace(records)
        let host = NSHostingView(rootView: HistoryView(history: state.watchHistory, search: state.sidebarSearch).environmentObject(state))
        let window = NSWindow(contentRect: .init(x: -2500, y: -2200, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        state.sidebarSearch.history = "小城"
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, -1, "A hidden selected history item must be deselected")
        state.sidebarSearch.history = "没有这个片名"
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertEqual(state.watchHistory.records.map(\.id), records.map(\.id))
        state.sidebarSearch.history = ""
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 2)
    }

    func testOpeningASettingsDestinationClearsOnlyTheSettingsQuery() {
        let state = AppState(environment: nil)
        state.sidebarSearch.settings = "TMDB"
        state.sidebarSearch.favorites = "小城"
        state.selectedSettingsPane = .configurations
        state.selectSection(.settings)
        XCTAssertEqual(state.selectedSettingsPane, .configurations)
        XCTAssertEqual(state.sidebarSearch.settings, "")
        XCTAssertEqual(state.sidebarSearch.favorites, "小城")
    }

    func testOldDestinationsResolveToOwnedSections() {
        let navigation = SettingsNavigationState()
        navigation.select(.search)
        XCTAssertEqual(navigation.selectedPane, .configurations)
        XCTAssertEqual(navigation.focus?.sectionID, "search-scope")
        navigation.select(.backup)
        XCTAssertEqual(navigation.selectedPane, .data)
        XCTAssertEqual(navigation.dataTab, .backup)
        navigation.select(.cache)
        XCTAssertEqual(navigation.selectedPane, .data)
        XCTAssertEqual(navigation.dataTab, .storage)
        XCTAssertEqual(navigation.focus?.sectionID, "image-cache")
    }

    func testSearchFindsChineseAliasesAndEnglishKeywordsWithoutDuplicatedRoutes() {
        XCTAssertEqual(SettingsSearchEntry.matching("硬解").map(\.id), ["hardware"])
        XCTAssertEqual(SettingsSearchEntry.matching("API token").map(\.id), ["tmdb"])
        XCTAssertTrue(SettingsSearchEntry.matching("节目单").contains { $0.id == "epg" })
        XCTAssertTrue(SettingsSearchEntry.matching("  CACHE ").contains { $0.tab == .storage })
        XCTAssertTrue(SettingsSearchEntry.matching(" \n ").isEmpty)
        XCTAssertTrue(SettingsSearchEntry.matching("nonexistent-setting").isEmpty)
        let panes = SettingsGroup.allCases.flatMap(\.panes)
        XCTAssertEqual(panes, SettingsPane.allCases)
        XCTAssertEqual(Set(panes).count, panes.count)
        XCTAssertEqual(Set(SettingsSearchEntry.all.map(\.id)).count, SettingsSearchEntry.all.count)
        XCTAssertTrue(SettingsSearchEntry.all.allSatisfy { SettingsPane.allCases.contains($0.pane) })


    }

    func testFinishingAnOldSearchHighlightCannotClearNewDestination() {
        let navigation = SettingsNavigationState()
        navigation.select(.details, sectionID: "tmdb-connection")
        let first = navigation.focus!.id
        navigation.select(.advanced, sectionID: "maintenance")
        navigation.finishFocus(first)
        XCTAssertEqual(navigation.focus?.sectionID, "maintenance")
        navigation.finishFocus(navigation.focus!.id)
        XCTAssertNil(navigation.focus)
    }

    func testAbsentRuntimeDoesNotClaimCacheClearSucceeded() async {
        let state = AppState(environment: nil)
        let result = await state.clearPosterCache()
        XCTAssertFalse(result)
    }

    func testUnloadedLiveSourceDoesNotClaimAnEmbeddedGuideWasDetected() {
        let state = AppState(environment: nil)
        XCTAssertEqual(state.settingsEPGOrigin(for: UUID()), "automatic")
    }

    func testEPGSummaryFollowsTheSamePriorityAsPlaybackWithoutNetworkRequests() async throws {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Fixture", sourceKind: .pasted, rawData: Data())
        state.setEPGInputsForTesting(sources: [source], playlists: [
            source.id: LivePlaylist(format: .m3u, groups: [], epgURL: URL(string: "https://example.invalid/embedded.xml"))
        ])
        try await state.applyEPGPreferencesForTesting(.init(defaultEPGURL: "https://example.invalid/global.xml"))
        XCTAssertEqual(state.settingsEPGOrigin(for: source.id), "embedded")
        try await state.applyEPGPreferencesForTesting(.init(defaultEPGURL: "https://example.invalid/global.xml",
            sources: [source.id.uuidString: .init(mode: .custom, customEPGURL: "https://example.invalid/custom.xml")]))
        XCTAssertEqual(state.settingsEPGOrigin(for: source.id), "custom")
        try await state.applyEPGPreferencesForTesting(.init(automaticEPGEnabled: false))
        XCTAssertEqual(state.settingsEPGOrigin(for: source.id), "off")
    }

    func testSettingsCatalogIsTranslatedInBothSupportedLanguages() {
        for language in AppLanguage.allCases {
            let localizer = AppLocalizer(language: language)
            for key in ["pane.playback", "pane.details", "pane.sources", "pane.live", "pane.data",
                        "pane.compatibility", "pane.about", "search.placeholder", "history.clear.message",
                        "backup.favorites.help", "backup.favorites.count", "disclosure.expanded", "disclosure.collapsed"] {
                let full = "settings.organized." + key
                XCTAssertNotEqual(localizer.string(.init(rawValue: full)), full, "\(language): \(key)")
            }
        }
    }
}

@MainActor final class SettingsPreviewTests: XCTestCase {
    func testPopulatedSettingsAndNestedDestinations() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OKVIDEOMAC_SETTINGS_PREVIEW"]
            ?? NSTemporaryDirectory() + "OKVideoMac-Settings-Preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState(environment: nil)
        let active = StoredConfiguration(name: "我的点播配置 · 多站点测试 / My Video Configuration", sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json", rawData: Data("{}".utf8), isActive: true)
        state.seedFavoriteConfigurationsForTesting([active, .init(name: "备用配置 / Alternate Configuration",
            sourceKind: .localFile, rawData: Data("{}".utf8))])
        state.setLiveConfigurationForTesting(active, providers: [:])
        let live = StoredLiveSource(name: "直播频道与节目单 / Live Channels", sourceKind: .remote,
            sourceValue: "https://example.invalid/live.m3u", rawData: Data())
        state.setEPGInputsForTesting(sources: [live], playlists: [
            live.id: .init(format: .m3u, groups: [], epgURL: URL(string: "https://example.invalid/guide.xml"))
        ])
        let cases: [(String, SettingsPane, SettingsDataTab?, String?, String)] = [
            ("sources-populated", .configurations, nil, nil, ""),
            ("live-populated", .liveSources, nil, nil, ""),
            ("data-storage", .data, .storage, nil, ""),
            ("data-backup", .data, .backup, nil, ""),
            ("runtime-expanded", .advanced, nil, "environment", ""),
            ("maintenance-expanded", .advanced, nil, "maintenance", ""),
            ("search-results", .general, nil, nil, "TMDB"),
            ("search-empty", .general, nil, nil, "nonexistent-setting")
        ]
        for (name, pane, tab, focus, query) in cases {
            let navigation = state.settingsNavigation
            navigation.select(pane)
            if let tab { navigation.dataTab = tab }
            if let focus { navigation.select(pane, sectionID: focus, tab: tab) }
            state.sidebarSearch.settings = query
            let host = NSHostingView(rootView: SettingsView(navigation: navigation, search: state.sidebarSearch)
                .environmentObject(state).environmentObject(state.navigation))
            let window = NSWindow(contentRect: .init(x: -3500, y: -2500, width: 860, height: 680),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
            window.close()
        }
    }

    func testSettingsUseOneMainSidebarSearchField() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OKVIDEOMAC_SETTINGS_PREVIEW"]
            ?? NSTemporaryDirectory() + "OKVideoMac-Settings-Preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState(environment: nil)
        state.selectSection(.settings)
        for (name, query, width) in [("main-settings", "", 1240.0), ("main-settings-search", "TMDB", 900.0)] {
            state.sidebarSearch.settings = query
            let host = NSHostingView(rootView: RootView().environmentObject(state).environmentObject(state.navigation))
            let window = NSWindow(contentRect: .init(x: -3500, y: -2500, width: width, height: 700),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let fields = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSSearchField }
            XCTAssertEqual(fields.count, 1)
            XCTAssertEqual(fields.first?.stringValue, query)
            XCTAssertEqual(fields.first?.placeholderAttributedString?.string, SidebarSearchPresentationPolicy.presentation(for: .settings).placeholder)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
            window.close()
        }
    }

    func testSettingsPagesFitDefaultAndNarrowWindows() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OKVIDEOMAC_SETTINGS_PREVIEW"]
            ?? NSTemporaryDirectory() + "OKVideoMac-Settings-Preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState(environment: nil)
        let defaults = UserDefaults(suiteName: "SettingsPreview-\(UUID())")!
        let navigation = state.settingsNavigation
        for (label, width, height, appearance) in [
            ("default", 1020.0, 680.0, NSAppearance.Name.aqua),
            ("narrow", 680.0, 540.0, .aqua),
            ("dark", 980.0, 720.0, .darkAqua)
        ] {
            for pane in SettingsPane.allCases {
                navigation.select(pane)
                let host = NSHostingView(rootView: SettingsView(navigation: navigation, search: state.sidebarSearch)
                    .environmentObject(state).environmentObject(state.navigation).defaultAppStorage(defaults))
                let window = NSWindow(contentRect: .init(x: -3500, y: -2500, width: width, height: height),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host; host.appearance = NSAppearance(named: appearance)
                try await Task.sleep(nanoseconds: 180_000_000)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, width, accuracy: 1, "\(pane)")
                XCTAssertEqual(host.bounds.height, height, accuracy: 1, "\(pane)")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(pane.rawValue)-\(label).png"))
                window.close()
            }
        }
    }
}


@MainActor final class SettingsHardwareDecodingTests: XCTestCase {
    func testSavedChoiceSurvivesClosedPlayerRecreationAndRestart() async throws {
        let suite = "SettingsHardware.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlayerLifecycleController(mode: .fullDestroy, hardwareDefaults: defaults)
        await controller.closeAfterPlayback(requestID: UUID())
        XCTAssertNil(controller.renderPlayer)
        try await controller.setHardwareDecoding(enabled: false)
        XCTAssertFalse(controller.rememberedHardwareDecoding)
        XCTAssertEqual(defaults.object(forKey: PlayerLifecycleController.hardwareDecodingKey) as? Bool, false)
        let recreated = try await controller.prepareForPlayback(requestID: UUID())
        let actual = await recreated.diagnosticPropertyForTesting("hwdec")
        XCTAssertEqual(actual, "no")
        await controller.shutdown()
        let restarted = PlayerLifecycleController(mode: .fullDestroy, hardwareDefaults: defaults)
        let initial = await restarted.renderPlayer?.diagnosticPropertyForTesting("hwdec")
        XCTAssertEqual(initial, "no")
        await restarted.shutdown()
    }

    func testLatestChoiceWinsWhileEarlierNativeCommandIsSuspended() async throws {
        let controller = PlayerLifecycleController(mode: .fullDestroy)
        var release: CheckedContinuation<Void, Never>?
        controller.hardwareCommandSuspensionForTesting = {
            controller.hardwareCommandSuspensionForTesting = nil
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await controller.setHardwareDecoding(enabled: false) }
        while release == nil { await Task.yield() }
        let last = Task { try await controller.setHardwareDecoding(enabled: true) }
        while !controller.rememberedHardwareDecoding { await Task.yield() }
        release?.resume()
        try await first.value; try await last.value
        let actual = await controller.renderPlayer?.diagnosticPropertyForTesting("hwdec")
        XCTAssertEqual(actual, "auto-safe")
        XCTAssertTrue(controller.rememberedHardwareDecoding)
        await controller.shutdown()
    }
}


private actor SettingsSuspendedLiveHTTP: HTTPClient {
    private var pending: [(HTTPRequest, CheckedContinuation<HTTPResponse, Error>)] = []
    private(set) var count = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }
    func release(body: Data = Data("#EXTM3U\n#EXTINF:-1,New\nhttps://fixture.invalid/new\n".utf8)) {
        let requests = pending; pending = []
        for (request, continuation) in requests {
            continuation.resume(returning: HTTPResponse(url: request.url, statusCode: 200, headers: [:],
                body: body))
        }
    }
}

@MainActor final class SettingsLiveRefreshTests: XCTestCase {
    private func fixture() async throws -> (URL, SQLiteStore, StoredLiveSource) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRefresh-\(UUID())")
        let db = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let source = StoredLiveSource(name: "Fixture", sourceKind: .remote, sourceValue: "https://fixture.invalid/list",
            rawData: Data("#EXTM3U\n#EXTINF:-1,Old\nhttps://fixture.invalid/old\n".utf8))
        try await db.createLiveSource(source)
        return (root, db, source)
    }
    private func wait(_ client: SettingsSuspendedLiveHTTP, count: Int = 1) async throws {
        for _ in 0..<1000 {
            if await client.count == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Refresh did not reach controlled transport")
    }
    func testLateRefreshCannotResurrectDeletedSource() async throws {
        let (root, db, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SettingsSuspendedLiveHTTP()
        let state = AppState(environment: nil, liveReferenceStore: db, liveSourceLoader: .init(httpClient: client))
        try state.setImportedIdentityCatalogForTesting(source)
        let refresh = Task { await state.refreshLiveSource(source.id) }
        try await wait(client)
        XCTAssertTrue(state.refreshingLiveSourceIDs.contains(source.id))
        await state.deleteLiveSource(source.id)
        await client.release(); await refresh.value
        let records = try await db.liveSources()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(state.liveSources.isEmpty)
        XCTAssertNil(state.loadedLivePlaylists[source.id])
        XCTAssertTrue(state.refreshingLiveSourceIDs.isEmpty)
        XCTAssertNil(state.presentedError)
    }
    func testRefreshDatabaseWriteNeverInsertsAnAbsentSource() async throws {
        let (root, db, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let updated = try await db.refreshExistingLiveSource(source)
        XCTAssertTrue(updated)
        try await db.deleteLiveSource(id: source.id)
        let resurrected = try await db.refreshExistingLiveSource(source)
        XCTAssertFalse(resurrected)
        let records = try await db.liveSources(); XCTAssertTrue(records.isEmpty)
    }
    func testRefreshingOneSourcePreservesDeletionOfAnotherSource() async throws {
        let (root, db, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = StoredLiveSource(name: "Other", sourceKind: .remote, sourceValue: source.sourceValue, rawData: source.rawData)
        try await db.createLiveSource(other)
        let client = SettingsSuspendedLiveHTTP()
        let state = AppState(environment: nil, liveReferenceStore: db, liveSourceLoader: .init(httpClient: client))
        try state.setImportedIdentityCatalogForTesting(source)
        try state.setImportedIdentityCatalogForTesting(other)
        // Keep this persistence test independent of channel/network validation.
        await state.handleSystemSleep()
        let refresh = Task { await state.refreshLiveSource(source.id) }
        try await wait(client)
        await state.deleteLiveSource(other.id)
        await client.release(); await refresh.value
        let stored = try await db.liveSources()
        XCTAssertEqual(stored.map(\.id), [source.id])
        XCTAssertEqual(state.liveSources.map(\.id), [source.id])
        XCTAssertNotEqual(state.liveSources.first?.rawData, source.rawData)
        XCTAssertEqual(state.liveSources.first?.rawData, stored.first?.rawData)
        XCTAssertTrue(state.refreshingLiveSourceIDs.isEmpty)
    }

    func testDuplicateRefreshJoinsAndCancellationKeepsStoredSource() async throws {
        let (root, db, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SettingsSuspendedLiveHTTP()
        let state = AppState(environment: nil, liveReferenceStore: db, liveSourceLoader: .init(httpClient: client))
        try state.setImportedIdentityCatalogForTesting(source)
        let first = Task { await state.refreshLiveSource(source.id) }
        try await wait(client)
        let second = Task { await state.refreshLiveSource(source.id) }
        for _ in 0..<5 { await Task.yield() }
        let requests = await client.count; XCTAssertEqual(requests, 1)
        state.cancelLiveSourceRefresh(source.id)
        await client.release(); await first.value; await second.value
        let stored = try await db.liveSources()
        XCTAssertEqual(stored.first?.rawData, source.rawData)
        XCTAssertTrue(state.refreshingLiveSourceIDs.isEmpty)
        XCTAssertNotNil(state.liveSourceRefreshMessages[source.id])
    }
}


@MainActor final class SettingsConfigurationRefreshTests: XCTestCase {
    private func fixture(timeout: TimeInterval = 30) async throws -> (URL, SQLiteStore, StoredConfiguration, AppState, SettingsSuspendedLiveHTTP) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsConfiguration-\(UUID())")
        let db = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let record = StoredConfiguration(name: "Fixture", sourceKind: .remote,
            sourceValue: "https://fixture.invalid/config.json", rawData: Data("{}".utf8), isActive: true)
        try await db.saveConfiguration(record)
        // Production state is loaded from SQLite. Compare against that persisted
        // baseline, since Date's reference-epoch conversion can round fractions.
        let persisted = try await db.activeConfiguration()
        let baseline = try XCTUnwrap(persisted)
        let transport = SettingsSuspendedLiveHTTP()
        let state = AppState(environment: nil, liveReferenceStore: db, configurationLoader: .init(httpClient: transport), configurationRefreshTimeout: timeout)
        try state.setSettingsConfigurationsForTesting([baseline])
        return (root, db, baseline, state, transport)
    }
    private func wait(_ transport: SettingsSuspendedLiveHTTP) async throws {
        for _ in 0..<1000 {
            if await transport.count == 1 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Configuration refresh did not start")
    }
    func testOverallDeadlineReleasesUIAndRejectsLateResult() async throws {
        let (root, db, record, state, transport) = try await fixture(timeout: 0.03)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { await state.refreshActiveConfiguration() }
        try await wait(transport)
        for _ in 0..<1000 {
            if state.refreshingConfigurationID == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(state.refreshingConfigurationID)
        XCTAssertNotNil(state.configurationRefreshMessage)
        await transport.release(body: record.rawData); await task.value
        let stored = try await db.activeConfiguration()
        XCTAssertEqual(stored?.updatedAt, record.updatedAt)
        XCTAssertEqual(state.activeConfigurationRecord?.updatedAt, record.updatedAt)
    }
    func testDuplicateRefreshAndCancellationKeepCache() async throws {
        let (root, db, record, state, transport) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { await state.refreshActiveConfiguration() }
        try await wait(transport)
        XCTAssertEqual(state.refreshingConfigurationID, record.id)
        let second = Task { await state.refreshActiveConfiguration() }
        for _ in 0..<5 { await Task.yield() }
        let count = await transport.count; XCTAssertEqual(count, 1)
        state.cancelConfigurationRefresh()
        await transport.release(body: Data("{}".utf8)); await first.value; await second.value
        XCTAssertNil(state.refreshingConfigurationID)
        XCTAssertNotNil(state.configurationRefreshMessage)
        let stored = try await db.activeConfiguration(); XCTAssertEqual(stored?.updatedAt, record.updatedAt)
    }
    func testManualJoinReceivesBackgroundFailure() async throws {
        let (root, _, record, state, transport) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let background = Task { await state.refreshActiveConfigurationIfNeeded() }
        try await wait(transport)
        let manual = Task { await state.refreshActiveConfiguration() }
        for _ in 0..<5 { await Task.yield() }
        await transport.release(body: Data("invalid JSON".utf8)); _ = await background.value; await manual.value
        XCTAssertNil(state.refreshingConfigurationID)
        XCTAssertNotNil(state.configurationRefreshMessage)
        XCTAssertEqual(state.activeConfigurationRecord?.rawData, record.rawData)
    }
    func testSuccessfulUnchangedRefreshReportsCompletion() async throws {
        let (root, _, record, state, transport) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { await state.refreshActiveConfiguration() }
        try await wait(transport)
        await transport.release(body: record.rawData); await task.value
        XCTAssertNil(state.refreshingConfigurationID)
        XCTAssertFalse(state.isCommittingConfigurationRefresh)
        XCTAssertNotNil(state.configurationRefreshMessage)
        XCTAssertEqual(state.activeConfigurationRecord?.id, record.id)
    }
    func testSwitchMakesLateRefreshIneligible() async throws {
        let (root, db, record, state, transport) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var other = StoredConfiguration(name: "Other", sourceKind: .pasted, rawData: Data("{}".utf8))
        try await db.saveConfiguration(other)
        let task = Task { await state.refreshActiveConfiguration() }
        try await wait(transport)
        try await db.activateConfiguration(id: other.id); other.isActive = true
        var old = record; old.isActive = false
        try state.setSettingsConfigurationsForTesting([other, old])
        await transport.release(body: Data(#"{"sites":[]}"#.utf8)); await task.value
        XCTAssertEqual(state.activeConfigurationRecord?.id, other.id)
        let stored = try await db.activeConfiguration(); XCTAssertEqual(stored?.id, other.id)
        XCTAssertNil(state.configurationRefreshMessage)
    }
    func testDatabaseRefreshCannotReactivateResurrectOrOverwriteNewerContent() async throws {
        let (root, db, record, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var changed = record; changed.updatedAt = record.updatedAt.addingTimeInterval(10)
        let first = try await db.refreshActiveConfiguration(changed, expectedUpdatedAt: record.updatedAt)
        XCTAssertTrue(first)
        let stale = try await db.refreshActiveConfiguration(record, expectedUpdatedAt: record.updatedAt)
        XCTAssertFalse(stale)
        let other = StoredConfiguration(name: "Other", sourceKind: .pasted, rawData: record.rawData, isActive: true)
        try await db.saveConfiguration(other)
        let inactive = try await db.refreshActiveConfiguration(changed, expectedUpdatedAt: changed.updatedAt)
        XCTAssertFalse(inactive)
        try await db.deleteConfiguration(id: record.id)
        let deleted = try await db.refreshActiveConfiguration(record, expectedUpdatedAt: record.updatedAt)
        XCTAssertFalse(deleted)
        let stored = try await db.activeConfiguration(); XCTAssertEqual(stored?.id, other.id)
    }
}


@MainActor final class SettingsBackupOperationTests: XCTestCase {
    private func fixture() async throws -> (URL, AppState, StoredConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsBackup-\(UUID())")
        let db = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let configuration = StoredConfiguration(name: "Backup fixture", sourceKind: .pasted,
            rawData: Data(("{}" + String(repeating: " ", count: 1_000_000)).utf8), isActive: true)
        try await db.saveConfiguration(configuration)
        let state = AppState(environment: nil, liveReferenceStore: db)
        try state.setSettingsConfigurationsForTesting([configuration])
        return (root, state, configuration)
    }
    func testExportRemainsOwnedAcrossNavigationAndRejectsConcurrentInspection() async throws {
        let (root, state, configuration) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("export.okvideobackup")
        let operation = Task { try await state.exportPortableBackup(to: url) }
        for _ in 0..<1000 {
            if state.isBackupBusy { break }
            await Task.yield()
        }
        XCTAssertTrue(state.isBackupBusy)
        state.selectedSettingsPane = .general
        state.selectedSettingsPane = .data
        XCTAssertTrue(state.isBackupBusy)
        do { _ = try await state.inspectPortableBackup(at: url); XCTFail("Concurrent operation was accepted") }
        catch { XCTAssertTrue(state.isBackupBusy, "Rejected work must not clear the real owner's busy state") }
        let exported = try await operation.value
        XCTAssertEqual(exported.configurationName, configuration.name)
        XCTAssertFalse(state.isBackupBusy)
        let preview = try await state.inspectPortableBackup(at: url)
        XCTAssertEqual(preview.configurationName, configuration.name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testReadFailureReleasesOperationAndValidBackupCanBeReadNext() async throws {
        let (root, state, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.okvideobackup")
        do { _ = try await state.inspectPortableBackup(at: missing); XCTFail("Missing file was accepted") }
        catch { XCTAssertFalse(state.isBackupBusy) }
        let url = root.appendingPathComponent("valid.okvideobackup")
        _ = try await state.exportPortableBackup(to: url)
        _ = try await state.inspectPortableBackup(at: url)
        XCTAssertFalse(state.isBackupBusy)
        state.pendingBackupImport = try await state.inspectPortableBackup(at: url)
        state.selectedSettingsPane = .general
        state.selectedSettingsPane = .data
        XCTAssertEqual(state.pendingBackupImport?.fileURL, url)
    }
    func testOversizeFileIsRejectedBeforeReadingItsBody() async throws {
        let (root, state, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversize.okvideobackup")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PortableBackupCodec.maximumArchiveByteCount + 1)); try handle.close()
        do { _ = try await state.inspectPortableBackup(at: url); XCTFail("Oversized archive accepted") }
        catch { XCTAssertEqual(error as? PortableBackupError, .fileTooLarge) }
        XCTAssertFalse(state.isBackupBusy)
    }
}


private final class SettingsCredentialReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var onMain = false
    let release = DispatchSemaphore(value: 0)
    var state: (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (started, onMain) }
    func read() {
        lock.lock(); started = true; onMain = Thread.isMainThread; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
    }
}
private struct SettingsSlowTMDBCredentialStore: TMDBCredentialStoring {
    let probe: SettingsCredentialReadProbe
    func load() throws -> TMDBCredential? { probe.read(); return try TMDBCredential(kind: .apiKey, value: "fixture-key") }
    func save(_ value: TMDBCredential) throws {}
    func delete() throws {}
}
private actor SettingsTMDBCredentialStore: TMDBCredentialStoring {
    private(set) var value: TMDBCredential?
    init(_ value: TMDBCredential?) { self.value = value }
    func load() throws -> TMDBCredential? { value }
    func save(_ value: TMDBCredential) throws { self.value = value }
    func delete() throws { value = nil }
}

@MainActor final class SettingsTMDBOperationTests: XCTestCase {
    func testCredentialReadDoesNotBlockMainExecutor() async throws {
        let probe = SettingsCredentialReadProbe()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTMDB-\(UUID())"))
        let runtime = TMDBNetworkRuntime(credentials: SettingsSlowTMDBCredentialStore(probe: probe), defaults: defaults)
        for _ in 0..<1000 {
            if probe.state.0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(probe.state.0)
        XCTAssertFalse(probe.state.1, "Blocking credential storage must run off the main thread")
        XCTAssertTrue(runtime.isLoadingCredential)
        probe.release.signal()
        await runtime.prepare()
        XCTAssertFalse(runtime.busy)
        XCTAssertFalse(runtime.isLoadingCredential)
        XCTAssertEqual(runtime.credentialKind, .apiKey)
    }
    func testCancelledVerificationPreservesSavedCredentialAndRejectsDuplicate() async throws {
        let initial = try TMDBCredential(kind: .apiKey, value: "original")
        let store = SettingsTMDBCredentialStore(initial)
        let transport = SettingsSuspendedLiveHTTP()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTMDB-\(UUID())"))
        let runtime = TMDBNetworkRuntime(credentials: store, defaults: defaults, transport: transport)
        await runtime.prepare()
        let operation = Task { await runtime.validateAndSave(kind: .apiKey, value: "replacement") }
        for _ in 0..<1000 {
            if await transport.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(runtime.canCancelOperation)
        let duplicate = await runtime.validateAndSave(kind: .apiKey, value: "duplicate")
        XCTAssertFalse(duplicate)
        operation.cancel()
        await transport.release(body: Data(#"{"images":{"still_sizes":["w300"]}}"#.utf8))
        let saved = await operation.value; XCTAssertFalse(saved)
        let retained = await store.value; XCTAssertEqual(retained, initial)
        XCTAssertFalse(runtime.busy)
        XCTAssertFalse(runtime.canCancelOperation)
    }
    func testAutomaticAvailabilityChangesPublishWithoutManualCheck() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTMDB-\(UUID())"))
        let runtime = TMDBNetworkRuntime(credentials: SettingsTMDBCredentialStore(nil), defaults: defaults)
        await runtime.prepare()
        let ticket = await runtime.availability.ticket(.metadata)
        await runtime.availability.finish(ticket, outcome: .success)
        for _ in 0..<1000 {
            if runtime.links?.metadata.state == .available { break }
            await Task.yield()
        }
        XCTAssertEqual(runtime.links?.metadata.state, .available)
        await runtime.availability.networkChanged()
        for _ in 0..<1000 {
            if runtime.links?.metadata.state == .unknown { break }
            await Task.yield()
        }
        XCTAssertEqual(runtime.links?.metadata.state, .unknown)
    }
}

private actor SettingsSuspendedRuntimeStatus {
    private var pending: [CheckedContinuation<(AndroidRuntimeModeSnapshot, AndroidRuntimeStatus), Never>] = []
    private(set) var count = 0
    func load() async -> (AndroidRuntimeModeSnapshot, AndroidRuntimeStatus) {
        count += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func release() {
        let values = pending; pending = []
        for value in values { value.resume(returning: (.initial, .unavailable("controlled result"))) }
    }
}

@MainActor final class SettingsRuntimeOperationTests: XCTestCase {
    private func wait(_ loader: SettingsSuspendedRuntimeStatus) async throws {
        for _ in 0..<1000 {
            if await loader.count == 1 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Runtime check did not start")
    }
    func testManualAndAutomaticChecksShareOneRequestAndShowCompletion() async throws {
        let loader = SettingsSuspendedRuntimeStatus()
        let state = AppState(environment: nil, runtimeStatusLoader: { await loader.load() })
        let automatic = Task { await state.refreshAndroidRuntimeStatus(reportCompletion: false) }
        try await wait(loader)
        XCTAssertTrue(state.isCheckingAndroidRuntime)
        let manual = Task { await state.refreshAndroidRuntimeStatus() }
        for _ in 0..<5 { await Task.yield() }
        let count = await loader.count; XCTAssertEqual(count, 1)
        await loader.release(); await automatic.value; await manual.value
        XCTAssertFalse(state.isCheckingAndroidRuntime)
        XCTAssertEqual(state.androidRuntimeStatus.detail, "controlled result")
        XCTAssertNotNil(state.androidRuntimeCheckMessage)
    }
    func testShutdownRejectsLateRuntimeCheck() async throws {
        let loader = SettingsSuspendedRuntimeStatus()
        let state = AppState(environment: nil, runtimeStatusLoader: { await loader.load() })
        let check = Task { await state.refreshAndroidRuntimeStatus() }
        try await wait(loader)
        await state.shutdown()
        XCTAssertFalse(state.isCheckingAndroidRuntime)
        await loader.release(); await check.value
        XCTAssertNotEqual(state.androidRuntimeStatus.detail, "controlled result")
        XCTAssertNil(state.androidRuntimeCheckMessage)
    }
    func testDiagnosticsExportReportsResultPreservesRedactionAndRecoversFromFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsDiagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(environment: nil)
        let data = Data(#"{"sites":[{"key":"fixture","name":"Fixture","type":1,"api":"https://fixture.invalid/api?token=secret-token"}]}"#.utf8)
        try state.setSettingsConfigurationsForTesting([StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: data, isActive: true)])
        do { try await state.exportDiagnostics(to: root.appendingPathComponent("missing/result.json")); XCTFail("Invalid output succeeded") }
        catch { XCTAssertFalse(state.isExportingDiagnostics); XCTAssertNotNil(state.diagnosticsExportMessage) }
        let url = root.appendingPathComponent("diagnostics.json")
        try await state.exportDiagnostics(to: url)
        XCTAssertFalse(state.isExportingDiagnostics)
        XCTAssertEqual(state.diagnosticsExportURL, url)
        XCTAssertNotNil(state.diagnosticsExportMessage)
        let output = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("secret-token"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(report["siteCount"] as? Int, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

private actor SettingsXtreamCredentialStore: XtreamCredentialStoring {
    private var values: [UUID: XtreamCredentials] = [:]
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    func credentials(for providerID: UUID) async throws -> XtreamCredentials? { values[providerID] }
    func save(_ credentials: XtreamCredentials, for providerID: UUID) async throws {
        writes += 1
        await withCheckedContinuation { pending.append($0) }
        values[providerID] = credentials
    }
    func deleteCredentials(for providerID: UUID) async throws { values[providerID] = nil }
    func releaseWrite() {
        let list = pending; pending = []
        for value in list { value.resume() }
    }
}

@MainActor final class SettingsEPGAndXtreamTests: XCTestCase {
    private func fixture() throws -> (URL, SQLiteStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsEPGXtream-\(UUID())")
        return (root, try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite")))
    }
    func testEPGValidationAndStorageFailuresAreDistinctAndKeepPreviousSettings() async throws {
        let (root, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(environment: nil, liveReferenceStore: db)
        let initial = EPGPreferences(automaticEPGEnabled: false, defaultEPGURL: "https://fixture.invalid/guide.xml")
        let saved = await state.saveEPGPreferences(initial); XCTAssertTrue(saved)
        var invalid = initial; invalid.defaultEPGURL = "file:///secret-token"
        let invalidSaved = await state.saveEPGPreferences(invalid); XCTAssertFalse(invalidSaved)
        let invalidMessage = try XCTUnwrap(state.presentedError?.message)
        XCTAssertFalse(invalidMessage.contains("secret-token"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [root.appendingPathComponent("test.sqlite").path,
            "CREATE TRIGGER settings_fail_fixture BEFORE INSERT ON settings WHEN NEW.key='live.epg.preferences.v1' BEGIN SELECT RAISE(ABORT, 'fixture secret-token'); END;"]
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        var changed = initial; changed.defaultEPGURL = "https://fixture.invalid/changed.xml?token=secret-token"
        let changedSaved = await state.saveEPGPreferences(changed); XCTAssertFalse(changedSaved)
        let storageMessage = try XCTUnwrap(state.presentedError?.message)
        XCTAssertNotEqual(storageMessage, invalidMessage)
        XCTAssertFalse(storageMessage.contains("secret-token"))
        XCTAssertEqual(state.epgPreferences, initial)
        let persisted = try await db.epgPreferences(); XCTAssertEqual(persisted, initial)
        XCTAssertFalse(state.isSavingEPGPreferences)
    }
    private func wait(_ transport: SettingsSuspendedLiveHTTP) async throws {
        for _ in 0..<1000 {
            if await transport.count == 1 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Xtream authentication did not start")
    }
    func testCancelledXtreamAuthenticationDoesNotWriteCredentialsOrConfiguration() async throws {
        let (root, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SettingsSuspendedLiveHTTP(), credentials = SettingsXtreamCredentialStore()
        let state = AppState(environment: nil, liveReferenceStore: db, xtreamHTTPClient: transport, liveCredentialStore: credentials)
        let secret = UUID().uuidString // Synthetic, unique test input; never a service credential.
        let save = Task { await state.saveXtreamProvider(id: nil, displayName: "Fixture", serverURL: "https://fixture.invalid",
            username: "fixture-user", password: secret) }
        try await wait(transport)
        XCTAssertFalse(state.isCommittingXtreamProvider)
        save.cancel()
        await transport.release(body: Data(#"{"user_info":{"auth":1,"status":"Active"}}"#.utf8))
        let succeeded = await save.value; XCTAssertFalse(succeeded)
        let writes = await credentials.writes; XCTAssertEqual(writes, 0)
        let records = try await db.configurations(); XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(state.isCommittingXtreamProvider)
    }
    func testXtreamSavePublishesCommitPhaseAndFinishesWithoutExportingSecrets() async throws {
        let (root, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SettingsSuspendedLiveHTTP(), credentials = SettingsXtreamCredentialStore()
        let state = AppState(environment: nil, liveReferenceStore: db, xtreamHTTPClient: transport, liveCredentialStore: credentials)
        let secret = UUID().uuidString // Synthetic, unique test input; never a service credential.
        let save = Task { await state.saveXtreamProvider(id: nil, displayName: "Fixture", serverURL: "https://fixture.invalid",
            username: "fixture-user", password: secret) }
        try await wait(transport)
        await transport.release(body: Data(#"{"user_info":{"auth":1,"status":"Active"}}"#.utf8))
        for _ in 0..<1000 {
            if await credentials.writes == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(state.isCommittingXtreamProvider)
        await credentials.releaseWrite()
        let succeeded = await save.value; XCTAssertTrue(succeeded)
        XCTAssertFalse(state.isCommittingXtreamProvider)
        let records = try await db.configurations()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(state.activeConfigurationRecord?.id, record.id)
        let credential = try await credentials.credentials(for: record.id)
        XCTAssertEqual(credential?.password, secret)
        let exported = String(decoding: record.rawData, as: UTF8.self)
        XCTAssertFalse(exported.contains(secret)); XCTAssertFalse(exported.contains("fixture-user"))
    }
}


@MainActor final class SettingsCacheOperationTests: XCTestCase {
    func testMissingRepositoryReportsFailureAndReleasesBusyState() async {
        let state = AppState(environment: nil)
        let cleared = await state.clearPosterCache()
        XCTAssertFalse(cleared)
        XCTAssertFalse(state.isClearingPosterCache)
        XCTAssertNotNil(state.posterCacheOperationMessage)
    }
    func testTemporaryCacheIsClearedAndResultSurvivesNavigation() async throws {
        let environment = try AppEnvironment.live()
        let root = environment.directories.caches.deletingLastPathComponent()
        guard root.lastPathComponent.hasPrefix("OKVideoMac-XCTest-") else { return XCTFail("Cache test must use an isolated XCTest directory") }
        let state = AppState(environment: environment)
        let sentinel = environment.directories.caches.appendingPathComponent("Posters/settings-fixture.image")
        try Data("fixture".utf8).write(to: sentinel)
        let cleared = await state.clearPosterCache()
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(state.isClearingPosterCache)
        let message = try XCTUnwrap(state.posterCacheOperationMessage)
        state.selectedSettingsPane = .general
        state.selectedSettingsPane = .data
        XCTAssertEqual(state.posterCacheOperationMessage, message)
        await state.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
