import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class SQLiteStoreTests: XCTestCase {
    func testConfigurationActivationAndDeletionPreserveUserData() async throws {
        let store = try makeStore()
        let first = StoredConfiguration(
            name: "First",
            sourceKind: .pasted,
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let second = StoredConfiguration(
            name: "Second",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            rawData: Data(#"{"sites":[]}"#.utf8)
        )
        try await store.saveConfiguration(first)
        try await store.saveConfiguration(second)
        try await store.activateConfiguration(id: second.id)

        let activeID = try await store.activeConfiguration()?.id
        let configurationCount = try await store.configurations().count
        XCTAssertEqual(activeID, second.id)
        XCTAssertEqual(configurationCount, 2)

        let favorite = FavoriteRecord(siteKey: "fixture", videoID: "1", title: "Fixture")
        let history = HistoryRecord(siteKey: "fixture", videoID: "1", title: "Fixture")
        try await store.saveFavorite(favorite)
        try await store.saveHistory(history, incognito: false)
        try await store.deleteConfiguration(id: second.id)

        let storedFavorites = try await store.favorites()
        let storedHistoryIDs = try await store.history().map(\.id)
        XCTAssertEqual(storedFavorites.count, 1)
        XCTAssertEqual(storedFavorites.first?.siteKey, favorite.siteKey)
        XCTAssertEqual(storedFavorites.first?.videoID, favorite.videoID)
        XCTAssertEqual(storedFavorites.first?.title, favorite.title)
        XCTAssertEqual(
            storedFavorites.first?.createdAt.timeIntervalSince1970 ?? 0,
            favorite.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(storedHistoryIDs, [history.id])
    }

    func testFavoriteUpsertDoesNotDuplicate() async throws {
        let store = try makeStore()
        try await store.saveFavorite(
            FavoriteRecord(siteKey: "fixture", videoID: "1", title: "Original")
        )
        try await store.saveFavorite(
            FavoriteRecord(siteKey: "fixture", videoID: "1", title: "Updated")
        )

        let values = try await store.favorites()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.title, "Updated")
    }

    func testFavoriteDeletionSupportsSingleItemAndClearAll() async throws {
        let store = try makeStore()
        try await store.saveFavorite(
            FavoriteRecord(siteKey: "fixture", videoID: "1", title: "First")
        )
        try await store.saveFavorite(
            FavoriteRecord(siteKey: "fixture", videoID: "2", title: "Second")
        )

        try await store.deleteFavorite(siteKey: "fixture", videoID: "1")
        var values = try await store.favorites()
        XCTAssertEqual(values.map(\.videoID), ["2"])

        let deleted = try await store.deleteAllFavorites()
        values = try await store.favorites()
        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(values.isEmpty)
    }

    func testLiveSourcesArePersistedSeparatelyFromVODConfigurations() async throws {
        let store = try makeStore()
        let configuration = StoredConfiguration(
            name: "VOD",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/vod.json",
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let live = StoredLiveSource(
            name: "Live",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/live.m3u",
            baseURL: URL(string: "https://example.invalid/"),
            rawData: Data("#EXTM3U\n".utf8),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.saveConfiguration(configuration)
        try await store.saveLiveSource(live)
        try await store.deleteConfiguration(id: configuration.id)

        let configurations = try await store.configurations()
        let liveSources = try await store.liveSources()
        XCTAssertTrue(configurations.isEmpty)
        XCTAssertEqual(liveSources, [live])

        try await store.deleteLiveSource(id: live.id)
        let deletedLiveSources = try await store.liveSources()
        XCTAssertTrue(deletedLiveSources.isEmpty)
    }

    func testHistoryUpdateIncognitoAndCleanup() async throws {
        let store = try makeStore()
        try await store.saveHistory(
            HistoryRecord(
                siteKey: "fixture",
                videoID: "old",
                title: "Old",
                watchedAt: Date(timeIntervalSince1970: 10)
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(siteKey: "fixture", videoID: "private", title: "Private"),
            incognito: true
        )
        try await store.saveHistory(
            HistoryRecord(
                siteKey: "fixture",
                videoID: "current",
                title: "Current",
                episodeReference: "episode-reference",
                position: 42,
                duration: 100,
                watchedAt: Date(timeIntervalSince1970: 100)
            ),
            incognito: false
        )

        let historyCount = try await store.history().count
        let deletedCount = try await store.deleteHistory(
            olderThan: Date(timeIntervalSince1970: 50)
        )
        XCTAssertEqual(historyCount, 2)
        XCTAssertEqual(deletedCount, 1)
        let remaining = try await store.history()
        XCTAssertEqual(remaining.map(\.videoID), ["current"])
        XCTAssertEqual(remaining.first?.position, 42)
        XCTAssertEqual(remaining.first?.episodeReference, "episode-reference")
    }

    func testHistoryKeepsSameSiteAndVideoSeparateAcrossConfigurations() async throws {
        let store = try makeStore()
        let first = UUID()
        let second = UUID()
        try await store.saveHistory(
            HistoryRecord(
                configurationID: first,
                siteKey: "shared-site",
                videoID: "shared-video",
                title: "First configuration"
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(
                configurationID: second,
                siteKey: "shared-site",
                videoID: "shared-video",
                title: "Second configuration"
            ),
            incognito: false
        )

        let records = try await store.history()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            Set(records.compactMap(\.configurationID)),
            Set([first, second])
        )
        XCTAssertEqual(Set(records.map(\.title)), Set([
            "First configuration",
            "Second configuration"
        ]))

        let deleted = try await store.deleteHistory(configurationID: first)
        let remaining = try await store.history()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(remaining.map(\.configurationID), [second])
    }

    func testHistoryKeepsPlaybackSourcesSeparateAndUpdatesOnlyMatchingSource() async throws {
        let store = try makeStore()
        let configurationID = UUID()
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "shared-video",
                title: "Fixture",
                sourceName: "线路一",
                episodeName: "第1集",
                position: 10,
                watchedAt: Date(timeIntervalSince1970: 10)
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "shared-video",
                title: "Fixture",
                sourceName: "线路二",
                episodeName: "第2集",
                position: 20,
                watchedAt: Date(timeIntervalSince1970: 20)
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "shared-video",
                title: "Fixture",
                sourceName: "线路一",
                episodeName: "第3集",
                position: 30,
                watchedAt: Date(timeIntervalSince1970: 30)
            ),
            incognito: false
        )

        var records = try await store.history()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.sourceKey)), Set(["线路一", "线路二"]))
        XCTAssertEqual(
            records.first { $0.sourceKey == "线路一" }?.episodeName,
            "第3集"
        )
        XCTAssertEqual(
            records.first { $0.sourceKey == "线路二" }?.position,
            20
        )

        let deleted = try await store.deleteHistory(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "shared-video",
            sourceKey: "线路一"
        )
        records = try await store.history()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(records.map(\.sourceKey), ["线路二"])
    }

    func testHistoryVersionFourMigrationPreservesLatestLineAndAddsSourceIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OKVideoMacHistoryMigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let configurationID = UUID()
        do {
            let connection = try SQLiteConnection(url: databaseURL)
            try connection.execute(
                """
                CREATE TABLE history (
                    configuration_id TEXT NOT NULL,
                    site_key TEXT NOT NULL,
                    video_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    poster_url TEXT,
                    source_name TEXT,
                    episode_name TEXT,
                    media_reference TEXT,
                    position REAL NOT NULL DEFAULT 0,
                    duration REAL NOT NULL DEFAULT 0,
                    watched_at REAL NOT NULL,
                    episode_reference TEXT,
                    PRIMARY KEY (configuration_id, site_key, video_id)
                )
                """
            )
            try connection.execute(
                """
                INSERT INTO history (
                    configuration_id, site_key, video_id, title,
                    source_name, episode_name, position, duration,
                    watched_at, episode_reference
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(configurationID.uuidString.lowercased()),
                    .text("fixture"),
                    .text("video"),
                    .text("Fixture"),
                    .text(" 线路二 "),
                    .text("第8集"),
                    .double(88),
                    .double(100),
                    .double(1_000),
                    .text("episode-8")
                ]
            )
            try connection.execute("PRAGMA user_version = 4")
        }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let migratedRecords = try await store.history()
        let record = try XCTUnwrap(migratedRecords.first)
        XCTAssertEqual(record.sourceKey, "线路二")
        XCTAssertEqual(record.sourceName, " 线路二 ")
        XCTAssertEqual(record.episodeName, "第8集")
        XCTAssertEqual(record.position, 88)
        XCTAssertEqual(SQLiteStore.currentSchemaVersion, 8)
    }

    func testHistoryVersionSevenMigrationPreservesPlaybackReferenceAndRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OKVideoMacHistoryV7MigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let configurationID = UUID()
        do {
            let connection = try SQLiteConnection(url: databaseURL)
            try connection.execute(
                """
                CREATE TABLE history (
                    configuration_id TEXT NOT NULL,
                    site_key TEXT NOT NULL,
                    video_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    poster_url TEXT,
                    source_name TEXT,
                    episode_name TEXT,
                    media_reference TEXT,
                    position REAL NOT NULL DEFAULT 0,
                    duration REAL NOT NULL DEFAULT 0,
                    watched_at REAL NOT NULL,
                    episode_reference TEXT,
                    playback_reference TEXT,
                    PRIMARY KEY (configuration_id, site_key, video_id)
                )
                """
            )
            try connection.execute(
                """
                INSERT INTO history (
                    configuration_id, site_key, video_id, title,
                    source_name, episode_name, position, duration,
                    watched_at, episode_reference, playback_reference
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(configurationID.uuidString.lowercased()),
                    .text("fixture"),
                    .text("video"),
                    .text("Fixture"),
                    .text("夸父原1"),
                    .text("第8集"),
                    .double(88),
                    .double(100),
                    .double(1_000),
                    .text("episode-8"),
                    .text("{\"version\":3,\"opaque\":\"preserved\"}")
                ]
            )
            try connection.execute("PRAGMA user_version = 7")
        }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let records = try await store.history()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceKey, "夸父原1")

        let verification = try SQLiteConnection(url: databaseURL)
        var persistedReference: String?
        var persistedSourceKey: String?
        try verification.query(
            "SELECT playback_reference, source_key FROM history"
        ) { statement in
            persistedReference = verification.text(statement, 0)
            persistedSourceKey = verification.text(statement, 1)
        }
        XCTAssertEqual(
            persistedReference,
            "{\"version\":3,\"opaque\":\"preserved\"}"
        )
        XCTAssertEqual(persistedSourceKey, "夸父原1")
    }

    func testHealthyNewerSchemaIsNeverQuarantinedAsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OKVideoMacNewerSchemaTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        do {
            let connection = try SQLiteConnection(url: databaseURL)
            try connection.execute("CREATE TABLE sentinel (value TEXT)")
            try connection.execute("INSERT INTO sentinel VALUES ('keep-me')")
            try connection.execute("PRAGMA user_version = 99")
        }

        XCTAssertThrowsError(try SQLiteStore.openRecovering(databaseURL: databaseURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let verification = try SQLiteConnection(url: databaseURL)
        var value: String?
        try verification.query("SELECT value FROM sentinel") { statement in
            value = verification.text(statement, 0)
        }
        XCTAssertEqual(value, "keep-me")
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        XCTAssertFalse(entries.contains { $0.hasPrefix("Corrupt-") })
    }

    func testHistoryDeletionTargetsOnlySelectedRecord() async throws {
        let store = try makeStore()
        let configurationID = UUID()
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "first",
                title: "First"
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "second",
                title: "Second"
            ),
            incognito: false
        )

        let deleted = try await store.deleteHistory(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "first",
            sourceKey: HistoryRecord.normalizedSourceKey(nil)
        )
        let remaining = try await store.history()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(remaining.map(\.videoID), ["second"])
    }

    func testSettingsRoundTripAndDelete() async throws {
        let store = try makeStore()
        let value = JSONValue.object([
            "speed": .number(1.25),
            "hardwareDecoding": .bool(true)
        ])
        try await store.setSetting(value, forKey: "player")
        let storedSetting = try await store.setting(forKey: "player")
        XCTAssertEqual(storedSetting, value)

        try await store.setSetting(nil, forKey: "player")
        let deletedSetting = try await store.setting(forKey: "player")
        XCTAssertNil(deletedSetting)
    }

    func testCorruptDatabaseIsQuarantinedAndRecreated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OKVideoMacRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        try Data("not a sqlite database".utf8).write(to: databaseURL)

        let result = try SQLiteStore.openRecovering(databaseURL: databaseURL)
        let quarantine = try XCTUnwrap(result.quarantinedDatabaseDirectory)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: quarantine.appendingPathComponent("test.sqlite3").path
            )
        )
        let configurations = try await result.store.configurations()
        XCTAssertEqual(configurations, [])
    }

    func testConcurrentWritesAreSerialized() async throws {
        let store = try makeStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try await store.saveFavorite(
                        FavoriteRecord(
                            siteKey: "fixture",
                            videoID: String(index),
                            title: "Fixture \(index)"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }
        let favorites = try await store.favorites()
        XCTAssertEqual(favorites.count, 50)
    }

    private func makeStore() throws -> SQLiteStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OKVideoMacTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try SQLiteStore(databaseURL: directory.appendingPathComponent("test.sqlite3"))
    }
}
