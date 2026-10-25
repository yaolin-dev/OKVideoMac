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
