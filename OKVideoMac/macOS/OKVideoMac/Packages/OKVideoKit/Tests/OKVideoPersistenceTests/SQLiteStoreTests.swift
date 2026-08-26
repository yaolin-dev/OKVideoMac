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

    func testImportedConfigurationCommitReturnsPostCommitState() async throws {
        let store = try makeStore()
        let original = StoredConfiguration(
            name: "Original",
            sourceKind: .pasted,
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let imported = StoredConfiguration(
            name: "Imported",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        try await store.saveConfiguration(original)

        let committed = try await store.commitImportedConfiguration(imported)
        let activeID = try await store.activeConfiguration()?.id

        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed.filter(\.isActive).map(\.id), [imported.id])
        XCTAssertEqual(activeID, imported.id)
    }

    func testConfigurationHistoryRestoreRemapsAndWritesAtomically() async throws {
        let store = try makeStore()
        let imported = StoredConfiguration(
            name: "Imported",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            rawData: Data(#"{"sites":[]}"#.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            isActive: true
        )
        let first = HistoryRecord(
            configurationID: imported.id,
            siteKey: "fixture",
            videoID: "video-1",
            title: "First",
            sourceKey: "line-1",
            position: 10,
            watchedAt: Date(timeIntervalSince1970: 110)
        )
        let second = HistoryRecord(
            configurationID: imported.id,
            siteKey: "fixture",
            videoID: "video-2",
            title: "Second",
            sourceKey: "line-2",
            position: 20,
            watchedAt: Date(timeIntervalSince1970: 120)
        )

        let result = try await store.restoreConfigurationAndHistory(
            configuration: imported,
            history: [first, second]
        )
        let storedHistory = try await store.history()
        let activeID = try await store.activeConfiguration()?.id

        XCTAssertEqual(result.configuration.id, imported.id)
        XCTAssertEqual(result.consideredHistoryCount, 2)
        XCTAssertEqual(result.changedHistoryCount, 2)
        XCTAssertEqual(storedHistory.count, 2)
        XCTAssertTrue(storedHistory.allSatisfy {
            $0.configurationID == imported.id
        })
        XCTAssertEqual(activeID, imported.id)
    }

    func testConfigurationHistoryRestoreKeepsNewerLocalData() async throws {
        let store = try makeStore()
        let configurationID = UUID()
        let current = StoredConfiguration(
            id: configurationID,
            name: "Current",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            rawData: Data(#"{"sites":[{"key":"new"}]}"#.utf8),
            updatedAt: Date(timeIntervalSince1970: 300),
            isActive: true
        )
        try await store.saveConfiguration(current)
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "video-1",
                title: "Current",
                sourceKey: "line-1",
                position: 80,
                watchedAt: Date(timeIntervalSince1970: 300)
            ),
            incognito: false
        )
        let olderConfiguration = StoredConfiguration(
            id: configurationID,
            name: "Older Backup",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            rawData: Data(#"{"sites":[]}"#.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            isActive: true
        )
        let olderHistory = HistoryRecord(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "video-1",
            title: "Older",
            sourceKey: "line-1",
            position: 10,
            watchedAt: Date(timeIntervalSince1970: 100)
        )

        let result = try await store.restoreConfigurationAndHistory(
            configuration: olderConfiguration,
            history: [olderHistory]
        )
        let activeConfiguration = try await store.activeConfiguration()
        let storedConfiguration = try XCTUnwrap(activeConfiguration)
        let history = try await store.history()
        let storedHistory = try XCTUnwrap(history.first)

        XCTAssertEqual(result.changedHistoryCount, 0)
        XCTAssertEqual(storedConfiguration.name, "Current")
        XCTAssertEqual(storedConfiguration.rawData, current.rawData)
        XCTAssertEqual(storedHistory.position, 80)
        XCTAssertEqual(storedHistory.title, "Current")
    }

    func testCancelledImportedConfigurationDoesNotPersistOrDeactivate() async throws {
        let store = try makeStore()
        let original = StoredConfiguration(
            name: "Original",
            sourceKind: .pasted,
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let cancelled = StoredConfiguration(
            name: "Cancelled",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/cancelled.json",
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        try await store.saveConfiguration(original)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.commitImportedConfiguration(cancelled)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before SQLite commit")
        } catch is CancellationError {
            // Expected.
        }

        let stored = try await store.configurations()
        let activeID = try await store.activeConfiguration()?.id
        XCTAssertEqual(stored.map(\.id), [original.id])
        XCTAssertEqual(activeID, original.id)
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

    func testHistoryPlaybackReferenceRoundTripsWithoutSensitiveHeaders() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStore(databaseURL: databaseURL)
        let providerReference = PlaybackResourceReference(
            configurationIdentity: "configuration-v1",
            siteIdentity: "site-v1",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "share-42/item-9",
            sourceIdentity: "stable-source",
            episodeIdentity: "stable-resource",
            stability: .providerStable
        )
        let reference = HistoryPlaybackReference(
            sourceIdentity: "stable-source",
            resourceIdentity: "stable-resource",
            providerResourceReference: providerReference,
            replayHeaders: [
                "User-Agent": "Fixture/1.0",
                "Referer": "https://example.invalid/watch/17"
            ]
        )
        let record = HistoryRecord(
            siteKey: "renamed-site",
            videoID: "renamed-video",
            title: "Fixture",
            sourceName: "Display Only",
            episodeName: "Episode Display Only",
            episodeReference: "share-42/item-9",
            mediaReference: URL(
                fileURLWithPath: "/tmp/OKVideoMac fixture.mkv"
            ).absoluteString,
            playbackReference: reference
        )

        try await store.saveHistory(record, incognito: false)
        let history = try await store.history()
        let stored = try XCTUnwrap(history.first)

        let expectedReference = HistoryPlaybackReference(
            sourceIdentity: "stable-source",
            resourceIdentity: "stable-resource",
            providerResourceReference: providerReference,
            replayHeaders: ["User-Agent": "Fixture/1.0"]
        )
        XCTAssertEqual(stored.episodeReference, "share-42/item-9")
        XCTAssertEqual(
            stored.mediaReference,
            URL(fileURLWithPath: "/tmp/OKVideoMac fixture.mkv")
                .standardizedFileURL.absoluteString
        )
        XCTAssertEqual(stored.playbackReference, expectedReference)
        XCTAssertEqual(stored.playbackReference?.sourceIdentity, "stable-source")
        XCTAssertEqual(stored.playbackReference?.resourceIdentity, "stable-resource")
        XCTAssertEqual(
            stored.playbackReference?.providerResourceReference,
            providerReference
        )
        let encoded = try JSONEncoder().encode(stored.playbackReference)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(
            encodedText.localizedCaseInsensitiveContains("authorization")
        )
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("mediaSession"))

        var rawValues: [String] = []
        let verification = try SQLiteConnection(url: databaseURL)
        try verification.query(
            """
            SELECT episode_reference, media_reference, playback_reference
            FROM history
            """
        ) { statement in
            rawValues = (0...2).compactMap { verification.text(statement, Int32($0)) }
        }
        verification.close()
        let rawText = rawValues.joined(separator: "\n")
        XCTAssertFalse(rawText.localizedCaseInsensitiveContains("referer"))
        XCTAssertFalse(rawText.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(rawText.localizedCaseInsensitiveContains("authorization"))
    }

    func testHistoryPersistenceBoundaryRejectsMaliciousValuesOnWriteAndRead()
        async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStore(databaseURL: databaseURL)
        let sentinel = "SECRET-SENTINEL-9427"
        let base64EpisodeReference = Data(
            #"{"fileId":"42","token":"SECRET-SENTINEL-9427"}"#.utf8
        ).base64EncodedString()
        let expiringProviderReference = PlaybackResourceReference(
            configurationIdentity: "configuration-v1",
            siteIdentity: "site-v1",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "token-\(sentinel)",
            sourceIdentity: "stable-source",
            episodeIdentity: "stable-resource",
            stability: .providerStable,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let inputReference = HistoryPlaybackReference(
            sourceIdentity: "stable-source",
            resourceIdentity: "stable-resource",
            providerResourceReference: expiringProviderReference,
            replayHeaders: [
                "Authorization": "Bearer \(sentinel)",
                "Cookie": "session=\(sentinel)",
                "Origin": "https://origin.invalid/\(sentinel)",
                "Referer": "https://referer.invalid/\(sentinel)",
                "User-Agent": "Fixture/1.0"
            ]
        )
        try await store.saveHistory(
            HistoryRecord(
                siteKey: "fixture",
                videoID: "unsafe",
                title: "Unsafe",
                episodeReference: base64EpisodeReference,
                mediaReference: "https://media.invalid/video?token=\(sentinel)",
                playbackReference: inputReference
            ),
            incognito: false
        )

        var records = try await store.history()
        var stored = try XCTUnwrap(records.first)
        XCTAssertNil(stored.episodeReference)
        XCTAssertNil(stored.mediaReference)
        XCTAssertNil(stored.playbackReference?.providerResourceReference)
        XCTAssertEqual(
            stored.playbackReference?.replayHeaders,
            ["User-Agent": "Fixture/1.0"]
        )

        let direct = try SQLiteConnection(url: databaseURL)
        var persistedText = ""
        try direct.query(
            """
            SELECT COALESCE(episode_reference, ''),
                   COALESCE(media_reference, ''),
                   COALESCE(playback_reference, '')
            FROM history
            """
        ) { statement in
            persistedText = (0...2)
                .compactMap { direct.text(statement, Int32($0)) }
                .joined(separator: "\n")
        }
        XCTAssertFalse(persistedText.contains(sentinel))
        XCTAssertFalse(persistedText.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(
            persistedText.localizedCaseInsensitiveContains("authorization")
        )

        let replayOnlyReference = HistoryPlaybackReference(
            sourceIdentity: "stable-source",
            resourceIdentity: "stable-resource",
            providerResourceReference: PlaybackResourceReference(
                configurationIdentity: "configuration-v1",
                siteIdentity: "site-v1",
                providerKind: "android-dex-spider",
                providerVersion: 1,
                stableResourceLocator: "item-\(sentinel)",
                sourceIdentity: "stable-source",
                episodeIdentity: "stable-resource",
                stability: .providerReplay
            ),
            replayHeaders: [
                "Authorization": "Bearer \(sentinel)",
                "User-Agent": "Fixture/2.0"
            ]
        )
        let rawPlaybackReference = String(
            decoding: try JSONEncoder().encode(replayOnlyReference),
            as: UTF8.self
        )
        try direct.execute(
            """
            UPDATE history
            SET episode_reference = ?, media_reference = ?,
                playback_reference = ?
            """,
            bindings: [
                .text("http://127.0.0.1:9978/media?token=\(sentinel)"),
                .text("http://localhost:9978/media/\(sentinel)"),
                .text(rawPlaybackReference)
            ]
        )
        direct.close()

        records = try await store.history()
        stored = try XCTUnwrap(records.first)
        XCTAssertNil(stored.episodeReference)
        XCTAssertNil(stored.mediaReference)
        XCTAssertNil(stored.playbackReference?.providerResourceReference)
        XCTAssertEqual(
            stored.playbackReference?.replayHeaders,
            ["User-Agent": "Fixture/2.0"]
        )
        XCTAssertNil(
            PlaybackPersistencePolicy.sanitizedOpaqueLocator(
                #"{"fileId":"42"}"#
            )
        )
        XCTAssertNil(
            PlaybackPersistencePolicy.sanitizedOpaqueLocator(
                "unsafe\u{0000}locator"
            )
        )
    }

    func testSchemaSixMigrationScrubsLegacyHistorySecretsFromDisk()
        async throws {
        let databaseURL = try makeDatabaseURL()
        let sentinel = "MIGRATION-SECRET-SENTINEL-7319"
        let legacyReference = HistoryPlaybackReference(
            version: 3,
            sourceIdentity: "stable-source",
            resourceIdentity: "stable-resource",
            providerResourceReference: PlaybackResourceReference(
                configurationIdentity: "configuration-v1",
                siteIdentity: "site-v1",
                providerKind: "android-dex-spider",
                providerVersion: 1,
                stableResourceLocator: "token-\(sentinel)",
                sourceIdentity: "stable-source",
                episodeIdentity: "stable-resource",
                stability: .providerReplay
            ),
            replayHeaders: [
                "Authorization": "Bearer \(sentinel)",
                "Cookie": "session=\(sentinel)",
                "User-Agent": "Legacy/1.0"
            ]
        )
        let rawLegacyReference = String(
            decoding: try JSONEncoder().encode(legacyReference),
            as: UTF8.self
        )
        let legacy = try SQLiteConnection(url: databaseURL)
        try legacy.execute(
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
        try legacy.execute(
            """
            INSERT INTO history (
                configuration_id, site_key, video_id, title, source_name,
                episode_name, media_reference, position, duration, watched_at,
                episode_reference, playback_reference
            ) VALUES ('', 'fixture', 'legacy', 'Legacy', 'UC', 'Episode',
                      ?, 33, 100, 1000, ?, ?)
            """,
            bindings: [
                .text("https://media.invalid/file?token=\(sentinel)"),
                .text("https://episode.invalid/item?cookie=\(sentinel)"),
                .text(rawLegacyReference)
            ]
        )
        try legacy.execute("PRAGMA user_version = 5")
        legacy.close()

        let store = try SQLiteStore(databaseURL: databaseURL)
        let migratedRecords = try await store.history()
        let migrated = try XCTUnwrap(migratedRecords.first)
        XCTAssertEqual(migrated.title, "Legacy")
        XCTAssertEqual(migrated.position, 33)
        XCTAssertEqual(migrated.duration, 100)
        XCTAssertNil(migrated.episodeReference)
        XCTAssertNil(migrated.mediaReference)
        XCTAssertNil(migrated.playbackReference?.providerResourceReference)
        XCTAssertEqual(
            migrated.playbackReference?.replayHeaders,
            ["User-Agent": "Legacy/1.0"]
        )

        let verification = try SQLiteConnection(url: databaseURL)
        XCTAssertEqual(
            try verification.scalarInt("PRAGMA user_version"),
            SQLiteStore.currentSchemaVersion
        )
        var persistedText = ""
        try verification.query(
            """
            SELECT COALESCE(episode_reference, ''),
                   COALESCE(media_reference, ''),
                   COALESCE(playback_reference, '')
            FROM history
            """
        ) { statement in
            persistedText = (0...2)
                .compactMap { verification.text(statement, Int32($0)) }
                .joined(separator: "\n")
        }
        verification.close()
        XCTAssertFalse(persistedText.contains(sentinel))

        let sentinelData = Data(sentinel.utf8)
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }
            let contents = try Data(contentsOf: candidate)
            XCTAssertNil(
                contents.range(of: sentinelData),
                "Migration left the secret sentinel in \(candidate.lastPathComponent)"
            )
        }
    }

    func testSchemaSevenMigrationRemovesRawNodeProviderLocatorFromSQLite()
        async throws {
        let databaseURL = try makeDatabaseURL()
        let sentinel = "eyJhbGciOiJIUzI1NiJ9.NODE-SECRET-7319.signature"
        let legacyReference = HistoryPlaybackReference(
            version: 3,
            sourceIdentity: "node-source",
            resourceIdentity: "node-episode",
            providerResourceReference: PlaybackResourceReference(
                configurationIdentity: "configuration-a",
                siteIdentity: "node-site",
                providerKind: "node-http-spider",
                providerVersion: 1,
                stableResourceLocator: sentinel,
                sourceIdentity: "node-source",
                episodeIdentity: "node-episode",
                stability: .providerStable
            ),
            replayHeaders: ["User-Agent": "Fixture/1.0"]
        )
        let rawLegacyReference = String(
            decoding: try JSONEncoder().encode(legacyReference),
            as: UTF8.self
        )
        let legacy = try SQLiteConnection(url: databaseURL)
        try legacy.execute(
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
        try legacy.execute(
            """
            INSERT INTO history (
                configuration_id, site_key, video_id, title, position,
                duration, watched_at, playback_reference
            ) VALUES ('configuration-a', 'node-site', 'video', 'Node',
                      10, 100, 1000, ?)
            """,
            bindings: [.text(rawLegacyReference)]
        )
        try legacy.execute("PRAGMA user_version = 6")
        legacy.close()

        let store = try SQLiteStore(databaseURL: databaseURL)
        let migratedRecords = try await store.history()
        let migrated = try XCTUnwrap(migratedRecords.first)
        XCTAssertEqual(migrated.playbackReference?.sourceIdentity, "node-source")
        XCTAssertEqual(migrated.playbackReference?.resourceIdentity, "node-episode")
        XCTAssertNil(migrated.playbackReference?.providerResourceReference)
        XCTAssertEqual(
            migrated.playbackReference?.replayHeaders,
            ["User-Agent": "Fixture/1.0"]
        )

        let verification = try SQLiteConnection(url: databaseURL)
        XCTAssertEqual(
            try verification.scalarInt("PRAGMA user_version"),
            SQLiteStore.currentSchemaVersion
        )
        var persistedReference = ""
        try verification.query(
            "SELECT COALESCE(playback_reference, '') FROM history"
        ) { statement in
            persistedReference = verification.text(statement, 0) ?? ""
        }
        verification.close()
        XCTAssertFalse(persistedReference.contains(sentinel))

        let sentinelData = Data(sentinel.utf8)
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }
            let contents = try Data(contentsOf: candidate)
            XCTAssertNil(
                contents.range(of: sentinelData),
                "Migration left the raw Node locator in \(candidate.lastPathComponent)"
            )
        }
    }

    func testLegacyHistoryPlaybackReferenceDecodesWithoutProviderReference()
        throws {
        let legacy = Data(
            #"{"version":2,"sourceIdentity":"source","resourceIdentity":"episode","replayHeaders":{"User-Agent":"Fixture"}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            HistoryPlaybackReference.self,
            from: legacy
        )

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.sourceIdentity, "source")
        XCTAssertEqual(decoded.resourceIdentity, "episode")
        XCTAssertNil(decoded.providerResourceReference)
        XCTAssertEqual(decoded.replayHeaders["User-Agent"], "Fixture")
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

    func testHistoryKeepsSameVideoSeparateAcrossSitesWithinConfiguration() async throws {
        let store = try makeStore()
        let configurationID = UUID()
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "site-a",
                videoID: "shared-video",
                title: "Site A"
            ),
            incognito: false
        )
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "site-b",
                videoID: "shared-video",
                title: "Site B"
            ),
            incognito: false
        )

        let records = try await store.history()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.siteKey)), Set(["site-a", "site-b"]))
    }

    func testHistoryKeepsPlaybackSourcesSeparateAndUpdatesOnlyMatchingSource()
        async throws {
        let store = try makeStore()
        let configurationID = UUID()
        try await store.saveHistory(
            HistoryRecord(
                configurationID: configurationID,
                siteKey: "fixture",
                videoID: "shared-video",
                title: "Fixture",
                sourceKey: "line-1",
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
                sourceKey: "line-2",
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
                sourceKey: "line-1",
                sourceName: "线路一（重命名）",
                episodeName: "第3集",
                position: 30,
                watchedAt: Date(timeIntervalSince1970: 30)
            ),
            incognito: false
        )

        var records = try await store.history()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.sourceKey)), Set(["line-1", "line-2"]))
        XCTAssertEqual(
            records.first { $0.sourceKey == "line-1" }?.episodeName,
            "第3集"
        )
        XCTAssertEqual(
            records.first { $0.sourceKey == "line-2" }?.position,
            20
        )

        let deleted = try await store.deleteHistory(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "shared-video",
            sourceKey: "line-1"
        )
        records = try await store.history()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(records.map(\.sourceKey), ["line-2"])
    }

    func testHistoryVersionSevenMigrationPreservesPlaybackReferenceAndRows()
        async throws {
        let databaseURL = try makeDatabaseURL()
        let configurationID = UUID()
        let persistedReference =
            #"{"version":3,"sourceIdentity":"line-2","resourceIdentity":"episode-8","replayHeaders":{}}"#
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
                    .text(" 线路二 "),
                    .text("第8集"),
                    .double(88),
                    .double(100),
                    .double(1_000),
                    .text("episode-8"),
                    .text(persistedReference)
                ]
            )
            try connection.execute("PRAGMA user_version = 7")
        }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let migratedHistory = try await store.history()
        let record = try XCTUnwrap(migratedHistory.first)
        XCTAssertEqual(record.sourceKey, "线路二")
        XCTAssertEqual(record.sourceName, " 线路二 ")
        XCTAssertEqual(record.episodeName, "第8集")
        XCTAssertEqual(record.position, 88)
        XCTAssertEqual(record.playbackReference?.sourceIdentity, "line-2")
        XCTAssertEqual(SQLiteStore.currentSchemaVersion, 8)

        let verification = try SQLiteConnection(url: databaseURL)
        var storedPlaybackReference: String?
        var storedSourceKey: String?
        try verification.query(
            "SELECT playback_reference, source_key FROM history"
        ) { statement in
            storedPlaybackReference = verification.text(statement, 0)
            storedSourceKey = verification.text(statement, 1)
        }
        XCTAssertEqual(storedPlaybackReference, persistedReference)
        XCTAssertEqual(storedSourceKey, "线路二")
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

    func testHistorySelfHealReplacementIsAtomicAndRemovesOldIdentity()
        async throws {
        let store = try makeStore()
        let configurationID = UUID()
        let original = HistoryRecord(
            configurationID: configurationID,
            siteKey: "cloud",
            videoID: "expired-session-id",
            title: "楚门的世界（臻彩）",
            sourceKey: "夸克",
            sourceName: "夸克",
            episodeName: "原画",
            position: 2_224.9,
            duration: 6_176.9
        )
        try await store.saveHistory(original, incognito: false)
        let replacement = HistoryRecord(
            configurationID: configurationID,
            siteKey: "cloud",
            videoID: "current-video-id",
            title: "楚门的世界",
            sourceKey: "夸克",
            sourceName: "夸克",
            episodeName: "原画",
            position: original.position,
            duration: original.duration
        )

        try await store.replaceHistory(
            original,
            with: replacement,
            incognito: false
        )
        let records = try await store.history()

        XCTAssertEqual(records, [replacement.sanitizedForPersistence()])
        XCTAssertFalse(records.contains { $0.videoID == original.videoID })
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

    func testHealthyDatabaseOpenFailureIsNotQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OKVideoMacRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let connection = try SQLiteConnection(url: databaseURL)
        try connection.execute("CREATE TABLE preserved_user_data (value TEXT NOT NULL)")
        try connection.execute("INSERT INTO preserved_user_data VALUES ('preserved')")
        try connection.execute("PRAGMA user_version = 999")
        connection.close()

        XCTAssertThrowsError(try SQLiteStore.openRecovering(databaseURL: databaseURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Corrupt-") }
        XCTAssertEqual(quarantines, [])

        let verification = try SQLiteConnection(url: databaseURL)
        XCTAssertEqual(
            try verification.scalarInt("SELECT COUNT(*) FROM preserved_user_data"),
            1
        )
        verification.close()
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

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OKVideoMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("test.sqlite3")
    }

    private func makeStore() throws -> SQLiteStore {
        try SQLiteStore(databaseURL: makeDatabaseURL())
    }
}
