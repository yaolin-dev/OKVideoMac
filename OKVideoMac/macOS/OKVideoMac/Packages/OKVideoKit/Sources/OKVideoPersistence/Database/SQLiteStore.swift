import Foundation
import CSQLite
import OKVideoCore

public actor SQLiteStore:
    ConfigurationRepository,
    LiveSourceRepository,
    FavoritesRepository,
    HistoryRepository,
    SettingsRepository
{
    public static let currentSchemaVersion = 8

    private let connection: SQLiteConnection
    public let databaseURL: URL

    public struct OpenResult {
        public let store: SQLiteStore
        public let quarantinedDatabaseDirectory: URL?

        public init(store: SQLiteStore, quarantinedDatabaseDirectory: URL?) {
            self.store = store
            self.quarantinedDatabaseDirectory = quarantinedDatabaseDirectory
        }
    }

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        connection = try SQLiteConnection(url: databaseURL)
        try Self.configure(connection)
        try Self.migrate(connection)
        try Self.verify(connection)
        try Self.restrictDatabasePermissions(databaseURL)
    }

    public static func openRecovering(databaseURL: URL) throws -> OpenResult {
        do {
            return OpenResult(
                store: try SQLiteStore(databaseURL: databaseURL),
                quarantinedDatabaseDirectory: nil
            )
        } catch let openingError {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: databaseURL.path) else {
                throw openingError
            }

            // Opening can fail for reasons that do not imply corruption, such
            // as a busy database, a newer schema, a migration error, or a
            // transient filesystem failure. Moving a healthy database in any
            // of those cases makes all user data appear to disappear. Only
            // quarantine after a read-only SQLite integrity check positively
            // identifies corrupt/not-a-database content.
            guard confirmedCorruption(at: databaseURL) else {
                throw openingError
            }

            let quarantine = databaseURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "Corrupt-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let candidates = [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
                URL(fileURLWithPath: databaseURL.path + "-shm")
            ]
            do {
                for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
                    try fileManager.moveItem(
                        at: candidate,
                        to: quarantine.appendingPathComponent(candidate.lastPathComponent)
                    )
                }
            } catch {
                throw AppError.database(
                    "数据库损坏且无法隔离到 \(quarantine.lastPathComponent)：\(error.localizedDescription)"
                )
            }

            // WAL recovery can make a database that initially reported
            // SQLITE_CORRUPT readable once its three files have been moved as
            // one set. Do not replace such a healthy user database with an
            // empty one. Restore the complete set and retry the normal open;
            // if that still fails, preserve the files and surface the original
            // failure instead of silently discarding visible user data.
            let quarantinedDatabaseURL = quarantine
                .appendingPathComponent(databaseURL.lastPathComponent)
            if confirmedHealthy(at: quarantinedDatabaseURL) {
                do {
                    for candidate in candidates {
                        let quarantinedCandidate = quarantine
                            .appendingPathComponent(candidate.lastPathComponent)
                        guard fileManager.fileExists(atPath: quarantinedCandidate.path) else {
                            continue
                        }
                        try fileManager.moveItem(
                            at: quarantinedCandidate,
                            to: candidate
                        )
                    }
                    try? fileManager.removeItem(at: quarantine)
                } catch {
                    throw AppError.database(
                        "数据库隔离后校验完整，但恢复失败：\(error.localizedDescription)"
                    )
                }
                do {
                    return OpenResult(
                        store: try SQLiteStore(databaseURL: databaseURL),
                        quarantinedDatabaseDirectory: nil
                    )
                } catch {
                    throw openingError
                }
            }
            return OpenResult(
                store: try SQLiteStore(databaseURL: databaseURL),
                quarantinedDatabaseDirectory: quarantine
            )
        }
    }

    private static func confirmedCorruption(at databaseURL: URL) -> Bool {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        defer {
            if let handle {
                sqlite3_close(handle)
            }
        }

        if isCorruptionResult(openResult) {
            return true
        }
        guard openResult == SQLITE_OK, let handle else {
            return false
        }

        sqlite3_extended_result_codes(handle, 1)
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            handle,
            "PRAGMA quick_check",
            -1,
            &statement,
            nil
        )
        if isCorruptionResult(prepareResult) {
            return true
        }
        guard prepareResult == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        var sawResult = false
        var sawIntegrityFailure = false
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                sawResult = true
                guard let pointer = sqlite3_column_text(statement, 0) else {
                    return false
                }
                if String(cString: pointer) != "ok" {
                    sawIntegrityFailure = true
                }
            } else if stepResult == SQLITE_DONE {
                return sawResult && sawIntegrityFailure
            } else if isCorruptionResult(stepResult) {
                return true
            } else {
                return false
            }
        }
    }

    private static func confirmedHealthy(at databaseURL: URL) -> Bool {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        defer {
            if let handle {
                sqlite3_close(handle)
            }
        }
        guard openResult == SQLITE_OK, let handle else {
            return false
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "PRAGMA quick_check",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        var sawResult = false
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let pointer = sqlite3_column_text(statement, 0),
                      String(cString: pointer) == "ok" else {
                    return false
                }
                sawResult = true
            case SQLITE_DONE:
                return sawResult
            default:
                return false
            }
        }
    }

    private static func isCorruptionResult(_ result: Int32) -> Bool {
        let primaryResult = result & 0xff
        return primaryResult == SQLITE_CORRUPT || primaryResult == SQLITE_NOTADB
    }

    public func saveConfiguration(_ configuration: StoredConfiguration) throws {
        try connection.transaction {
            try writeConfiguration(configuration)
        }
    }

    /// Atomically persists an imported active configuration and returns the
    /// post-commit configuration list. Cancellation before the transaction's
    /// final read rolls the entire import back.
    public func commitImportedConfiguration(
        _ configuration: StoredConfiguration
    ) throws -> [StoredConfiguration] {
        try Task.checkCancellation()
        return try connection.transaction {
            try Task.checkCancellation()
            try writeConfiguration(configuration)
            try Task.checkCancellation()
            let values = try readConfigurations()
            try Task.checkCancellation()
            return values
        }
    }

    /// Restores one portable configuration and its history as a single unit.
    /// Existing newer data wins, while every imported history row is remapped
    /// to the resolved local configuration identity before it is written.
    public func restoreConfigurationAndHistory(
        configuration importedConfiguration: StoredConfiguration,
        history importedHistory: [HistoryRecord]
    ) throws -> ConfigurationHistoryRestoreResult {
        try connection.transaction {
            let existingConfigurations = try readConfigurations()
            let matchingConfiguration = existingConfigurations.first {
                $0.id == importedConfiguration.id
            } ?? existingConfigurations.first {
                $0.sourceKind == importedConfiguration.sourceKind
                    && $0.sourceValue == importedConfiguration.sourceValue
                    && $0.rawData == importedConfiguration.rawData
            }
            let targetID = matchingConfiguration?.id
                ?? importedConfiguration.id

            var restoredConfiguration: StoredConfiguration
            if let existing = matchingConfiguration,
               existing.updatedAt > importedConfiguration.updatedAt {
                restoredConfiguration = existing
            } else {
                restoredConfiguration = importedConfiguration
                restoredConfiguration.id = targetID
            }
            restoredConfiguration.isActive = true
            try writeConfiguration(restoredConfiguration)

            var changedHistoryCount = 0
            for importedRecord in importedHistory {
                var record = importedRecord.sanitizedForPersistence()
                record.configurationID = targetID
                changedHistoryCount += try writeHistory(
                    record,
                    onlyWhenNewer: true
                )
            }

            let configurations = try readConfigurations()
            guard let committedConfiguration = configurations.first(where: {
                $0.id == targetID
            }) else {
                throw AppError.database("备份配置写入后无法读取")
            }
            return ConfigurationHistoryRestoreResult(
                configuration: committedConfiguration,
                configurations: configurations,
                consideredHistoryCount: importedHistory.count,
                changedHistoryCount: changedHistoryCount
            )
        }
    }

    public func configurations() throws -> [StoredConfiguration] {
        try readConfigurations()
    }

    private func writeConfiguration(
        _ configuration: StoredConfiguration
    ) throws {
        if configuration.isActive {
            try connection.execute("UPDATE configurations SET is_active = 0")
        }
        try connection.execute(
            """
            INSERT INTO configurations (
                id, name, source_kind, source_value, base_url,
                raw_data, updated_at, is_active
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                source_kind = excluded.source_kind,
                source_value = excluded.source_value,
                base_url = excluded.base_url,
                raw_data = excluded.raw_data,
                updated_at = excluded.updated_at,
                is_active = excluded.is_active
            """,
            bindings: [
                .text(configuration.id.uuidString),
                .text(configuration.name),
                .text(configuration.sourceKind.rawValue),
                .optional(configuration.sourceValue),
                .optional(configuration.baseURL?.absoluteString),
                .blob(configuration.rawData),
                .double(configuration.updatedAt.timeIntervalSince1970),
                .integer(configuration.isActive ? 1 : 0)
            ]
        )
    }

    private func readConfigurations() throws -> [StoredConfiguration] {
        var values: [StoredConfiguration] = []
        try connection.query(
            """
            SELECT id, name, source_kind, source_value, base_url,
                   raw_data, updated_at, is_active
            FROM configurations
            ORDER BY is_active DESC, updated_at DESC
            """
        ) { statement in
            if let value = try self.configuration(from: statement) {
                values.append(value)
            }
        }
        return values
    }

    public func activeConfiguration() throws -> StoredConfiguration? {
        var value: StoredConfiguration?
        try connection.query(
            """
            SELECT id, name, source_kind, source_value, base_url,
                   raw_data, updated_at, is_active
            FROM configurations
            WHERE is_active = 1
            ORDER BY updated_at DESC
            LIMIT 1
            """
        ) { statement in
            value = try self.configuration(from: statement)
        }
        return value
    }

    public func activateConfiguration(id: UUID) throws {
        try connection.transaction {
            try connection.execute("UPDATE configurations SET is_active = 0")
            try connection.execute(
                "UPDATE configurations SET is_active = 1 WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            guard connection.lastChangedRowCount() == 1 else {
                throw AppError.database("找不到配置 \(id.uuidString)")
            }
        }
    }

    public func deleteConfiguration(id: UUID) throws {
        try connection.execute(
            "DELETE FROM configurations WHERE id = ?",
            bindings: [.text(id.uuidString)]
        )
    }

    public func saveLiveSource(_ source: StoredLiveSource) throws {
        try connection.execute(
            """
            INSERT INTO live_sources (
                id, name, source_kind, source_value, base_url,
                raw_data, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                source_kind = excluded.source_kind,
                source_value = excluded.source_value,
                base_url = excluded.base_url,
                raw_data = excluded.raw_data,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(source.id.uuidString),
                .text(source.name),
                .text(source.sourceKind.rawValue),
                .optional(source.sourceValue),
                .optional(source.baseURL?.absoluteString),
                .blob(source.rawData),
                .double(source.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func liveSources() throws -> [StoredLiveSource] {
        var values: [StoredLiveSource] = []
        try connection.query(
            """
            SELECT id, name, source_kind, source_value, base_url,
                   raw_data, updated_at
            FROM live_sources
            ORDER BY updated_at DESC
            """
        ) { statement in
            if let value = self.liveSource(from: statement) {
                values.append(value)
            }
        }
        return values
    }

    public func deleteLiveSource(id: UUID) throws {
        try connection.execute(
            "DELETE FROM live_sources WHERE id = ?",
            bindings: [.text(id.uuidString)]
        )
    }

    public func saveFavorite(_ favorite: FavoriteRecord) throws {
        try connection.execute(
            """
            INSERT INTO favorites (
                site_key, video_id, title, poster_url, synopsis, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(site_key, video_id) DO UPDATE SET
                title = excluded.title,
                poster_url = excluded.poster_url,
                synopsis = excluded.synopsis
            """,
            bindings: [
                .text(favorite.siteKey),
                .text(favorite.videoID),
                .text(favorite.title),
                .optional(favorite.posterURL?.absoluteString),
                .optional(favorite.synopsis),
                .double(favorite.createdAt.timeIntervalSince1970)
            ]
        )
    }

    public func favorites() throws -> [FavoriteRecord] {
        var values: [FavoriteRecord] = []
        try connection.query(
            """
            SELECT site_key, video_id, title, poster_url, synopsis, created_at
            FROM favorites
            ORDER BY created_at DESC
            """
        ) { statement in
            values.append(
                FavoriteRecord(
                    siteKey: self.connection.text(statement, 0) ?? "",
                    videoID: self.connection.text(statement, 1) ?? "",
                    title: self.connection.text(statement, 2) ?? "",
                    posterURL: self.connection.text(statement, 3).flatMap(URL.init(string:)),
                    synopsis: self.connection.text(statement, 4),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }
        return values
    }

    public func deleteFavorite(siteKey: String, videoID: String) throws {
        try connection.execute(
            "DELETE FROM favorites WHERE site_key = ? AND video_id = ?",
            bindings: [.text(siteKey), .text(videoID)]
        )
    }

    @discardableResult
    public func deleteAllFavorites() throws -> Int {
        try connection.execute("DELETE FROM favorites")
        return connection.lastChangedRowCount()
    }

    public func saveHistory(_ history: HistoryRecord, incognito: Bool) throws {
        guard !incognito else { return }
        _ = try writeHistory(history, onlyWhenNewer: false)
    }

    @discardableResult
    private func writeHistory(
        _ originalHistory: HistoryRecord,
        onlyWhenNewer: Bool
    ) throws -> Int {
        let history = originalHistory.sanitizedForPersistence()
        let playbackReference = try history.playbackReference.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }
        let mergeGuard = onlyWhenNewer
            ? " WHERE excluded.watched_at > history.watched_at"
            : ""
        try connection.execute(
            """
            INSERT INTO history (
                configuration_id, site_key, video_id, source_key,
                title, poster_url, source_name,
                episode_name, episode_reference, media_reference,
                position, duration, watched_at, playback_reference
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(configuration_id, site_key, video_id, source_key) DO UPDATE SET
                title = excluded.title,
                poster_url = excluded.poster_url,
                source_name = excluded.source_name,
                episode_name = excluded.episode_name,
                episode_reference = excluded.episode_reference,
                media_reference = excluded.media_reference,
                position = excluded.position,
                duration = excluded.duration,
                watched_at = excluded.watched_at,
                playback_reference = excluded.playback_reference
            \(mergeGuard)
            """,
            bindings: [
                .text(history.configurationID?.uuidString.lowercased() ?? ""),
                .text(history.siteKey),
                .text(history.videoID),
                .text(history.sourceKey),
                .text(history.title),
                .optional(history.posterURL?.absoluteString),
                .optional(history.sourceName),
                .optional(history.episodeName),
                .optional(history.episodeReference),
                .optional(history.mediaReference),
                .double(history.position),
                .double(history.duration),
                .double(history.watchedAt.timeIntervalSince1970),
                .optional(playbackReference)
            ]
        )
        return connection.lastChangedRowCount()
    }

    public func history() throws -> [HistoryRecord] {
        var values: [HistoryRecord] = []
        try connection.query(
            """
            SELECT configuration_id, site_key, video_id, source_key,
                   title, poster_url, source_name,
                   episode_name, episode_reference, media_reference,
                   position, duration, watched_at, playback_reference
            FROM history
            ORDER BY watched_at DESC
            """
        ) { statement in
            let record = HistoryRecord(
                configurationID: self.connection.text(statement, 0)
                    .flatMap(UUID.init(uuidString:)),
                siteKey: self.connection.text(statement, 1) ?? "",
                videoID: self.connection.text(statement, 2) ?? "",
                title: self.connection.text(statement, 4) ?? "",
                posterURL: self.connection.text(statement, 5).flatMap(URL.init(string:)),
                sourceKey: self.connection.text(statement, 3),
                sourceName: self.connection.text(statement, 6),
                episodeName: self.connection.text(statement, 7),
                episodeReference: self.connection.text(statement, 8),
                mediaReference: self.connection.text(statement, 9),
                playbackReference: self.connection.text(statement, 13)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(
                        HistoryPlaybackReference.self,
                        from: $0
                    ) },
                position: sqlite3_column_double(statement, 10),
                duration: sqlite3_column_double(statement, 11),
                watchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            )
            values.append(record.sanitizedForPersistence())
        }
        return values
    }

    @discardableResult
    public func deleteHistory(
        configurationID: UUID?,
        siteKey: String,
        videoID: String,
        sourceKey: String
    ) throws -> Int {
        try connection.execute(
            """
            DELETE FROM history
            WHERE configuration_id = ? AND site_key = ? AND video_id = ?
                AND source_key = ?
            """,
            bindings: [
                .text(configurationID?.uuidString.lowercased() ?? ""),
                .text(siteKey),
                .text(videoID),
                .text(HistoryRecord.normalizedSourceKey(sourceKey))
            ]
        )
        return connection.lastChangedRowCount()
    }

    @discardableResult
    public func deleteHistory(configurationID: UUID) throws -> Int {
        try connection.execute(
            "DELETE FROM history WHERE configuration_id = ?",
            bindings: [.text(configurationID.uuidString.lowercased())]
        )
        return connection.lastChangedRowCount()
    }

    @discardableResult
    public func deleteHistory(olderThan cutoff: Date) throws -> Int {
        try connection.execute(
            "DELETE FROM history WHERE watched_at < ?",
            bindings: [.double(cutoff.timeIntervalSince1970)]
        )
        return connection.lastChangedRowCount()
    }

    public func setSetting(_ value: JSONValue?, forKey key: String) throws {
        guard !key.isEmpty else {
            throw AppError.database("设置 key 不能为空")
        }
        guard let value else {
            try connection.execute(
                "DELETE FROM settings WHERE key = ?",
                bindings: [.text(key)]
            )
            return
        }
        let data = try JSONEncoder().encode(value)
        try connection.execute(
            """
            INSERT INTO settings (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            bindings: [.text(key), .blob(data)]
        )
    }

    public func setting(forKey key: String) throws -> JSONValue? {
        var value: JSONValue?
        try connection.query(
            "SELECT value FROM settings WHERE key = ? LIMIT 1",
            bindings: [.text(key)]
        ) { statement in
            guard let data = self.connection.data(statement, 0) else { return }
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        return value
    }

    private static func configure(_ connection: SQLiteConnection) throws {
        var journalMode: String?
        try connection.query("PRAGMA journal_mode = WAL") { statement in
            journalMode = connection.text(statement, 0)
        }
        guard journalMode?.lowercased() == "wal" else {
            throw AppError.database(
                "无法启用 WAL 日志模式：\(journalMode ?? "无返回值")"
            )
        }
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = NORMAL")
        let secureDelete = try connection.scalarInt("PRAGMA secure_delete = ON")
        guard secureDelete == 1 else {
            throw AppError.database(
                "无法启用 SQLite 安全删除：\(secureDelete)"
            )
        }
        let busyTimeout = try connection.scalarInt("PRAGMA busy_timeout = 5000")
        guard busyTimeout == 5_000 else {
            throw AppError.database(
                "无法设置数据库忙等待时间：\(busyTimeout) ms"
            )
        }
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let version = try connection.scalarInt("PRAGMA user_version")
        guard version <= currentSchemaVersion else {
            throw AppError.database(
                "数据库版本 \(version) 高于应用支持的 \(currentSchemaVersion)"
            )
        }
        if version < 1 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE configurations (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        source_kind TEXT NOT NULL,
                        source_value TEXT,
                        base_url TEXT,
                        raw_data BLOB NOT NULL,
                        updated_at REAL NOT NULL,
                        is_active INTEGER NOT NULL DEFAULT 0
                    )
                    """
                )
                try connection.execute(
                    "CREATE UNIQUE INDEX one_active_configuration ON configurations(is_active) WHERE is_active = 1"
                )
                try connection.execute(
                    """
                    CREATE TABLE favorites (
                        site_key TEXT NOT NULL,
                        video_id TEXT NOT NULL,
                        title TEXT NOT NULL,
                        poster_url TEXT,
                        synopsis TEXT,
                        created_at REAL NOT NULL,
                        PRIMARY KEY (site_key, video_id)
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE history (
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
                        PRIMARY KEY (site_key, video_id)
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX history_watched_at ON history(watched_at)"
                )
                try connection.execute(
                    """
                    CREATE TABLE settings (
                        key TEXT PRIMARY KEY NOT NULL,
                        value BLOB NOT NULL
                    )
                    """
                )
                try connection.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE live_sources (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        source_kind TEXT NOT NULL,
                        source_value TEXT,
                        base_url TEXT,
                        raw_data BLOB NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX live_sources_updated_at ON live_sources(updated_at)"
                )
                try connection.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try connection.transaction {
                try connection.execute(
                    "ALTER TABLE history ADD COLUMN episode_reference TEXT"
                )
                try connection.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try connection.transaction {
                // Historical rows created by older builds cannot be assigned
                // safely: two configurations may reuse the same site key for
                // different providers. Preserve them as legacy rows, but keep
                // them outside every configuration-scoped history view.
                try connection.execute(
                    """
                    CREATE TABLE history_v4 (
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
                    INSERT INTO history_v4 (
                        configuration_id, site_key, video_id, title,
                        poster_url, source_name, episode_name,
                        media_reference, position, duration, watched_at,
                        episode_reference
                    )
                    SELECT '', site_key, video_id, title, poster_url,
                           source_name, episode_name, media_reference,
                           position, duration, watched_at, episode_reference
                    FROM history
                    """
                )
                try connection.execute("DROP TABLE history")
                try connection.execute("ALTER TABLE history_v4 RENAME TO history")
                try connection.execute(
                    "CREATE INDEX history_watched_at ON history(watched_at)"
                )
                try connection.execute(
                    "CREATE INDEX history_configuration_watched_at ON history(configuration_id, watched_at DESC)"
                )
                try connection.execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try connection.transaction {
                try connection.execute(
                    "ALTER TABLE history ADD COLUMN playback_reference TEXT"
                )
                try connection.execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            try connection.transaction {
                var rows: [(
                    rowID: Int64,
                    episodeReference: String?,
                    mediaReference: String?,
                    playbackReference: String?
                )] = []
                try connection.query(
                    """
                    SELECT rowid, episode_reference, media_reference,
                           playback_reference
                    FROM history
                    """
                ) { statement in
                    rows.append((
                        rowID: sqlite3_column_int64(statement, 0),
                        episodeReference: connection.text(statement, 1),
                        mediaReference: connection.text(statement, 2),
                        playbackReference: connection.text(statement, 3)
                    ))
                }

                let encoder = JSONEncoder()
                let decoder = JSONDecoder()
                for row in rows {
                    let playbackReference = row.playbackReference
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap {
                            try? decoder.decode(
                                HistoryPlaybackReference.self,
                                from: $0
                            )
                        }?
                        .sanitizedForPersistence()
                    let encodedPlaybackReference = try playbackReference.map {
                        String(decoding: try encoder.encode($0), as: UTF8.self)
                    }
                    try connection.execute(
                        """
                        UPDATE history
                        SET episode_reference = ?, media_reference = ?,
                            playback_reference = ?
                        WHERE rowid = ?
                        """,
                        bindings: [
                            .optional(PlaybackPersistencePolicy
                                .sanitizedOpaqueLocator(
                                    row.episodeReference
                                )),
                            .optional(PlaybackPersistencePolicy
                                .sanitizedMediaReference(
                                    row.mediaReference
                                )),
                            .optional(encodedPlaybackReference),
                            .integer(row.rowID)
                        ]
                    )
                }
                try connection.execute("PRAGMA user_version = 6")
            }

            // Existing databases may have carried a secret in an old cell or
            // WAL frame. This one-time rebuild/checkpoint removes stale copies
            // after the v6 row-level scrub.
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
            try connection.execute("VACUUM")
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
        }
        if version < 7 {
            try connection.transaction {
                var rows: [(rowID: Int64, playbackReference: String?)] = []
                try connection.query(
                    "SELECT rowid, playback_reference FROM history"
                ) { statement in
                    rows.append((
                        rowID: sqlite3_column_int64(statement, 0),
                        playbackReference: connection.text(statement, 1)
                    ))
                }
                let encoder = JSONEncoder()
                let decoder = JSONDecoder()
                for row in rows {
                    let scrubbed = row.playbackReference
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap {
                            try? decoder.decode(
                                HistoryPlaybackReference.self,
                                from: $0
                            )
                        }?
                        .sanitizedForPersistence()
                    let encoded = try scrubbed.map {
                        String(decoding: try encoder.encode($0), as: UTF8.self)
                    }
                    try connection.execute(
                        "UPDATE history SET playback_reference = ? WHERE rowid = ?",
                        bindings: [.optional(encoded), .integer(row.rowID)]
                    )
                }
                try connection.execute("PRAGMA user_version = 7")
            }
            // Remove old raw provider locators from both table pages and WAL.
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
            try connection.execute("VACUUM")
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
        }
        if version < 8 {
            try connection.transaction {
                if try !columnExists(
                    "playback_reference",
                    in: "history",
                    connection: connection
                ) {
                    try connection.execute(
                        "ALTER TABLE history ADD COLUMN playback_reference TEXT"
                    )
                }

                if try !columnExists(
                    "source_key",
                    in: "history",
                    connection: connection
                ) {
                    try connection.execute(
                        """
                        CREATE TABLE history_v8 (
                            configuration_id TEXT NOT NULL,
                            site_key TEXT NOT NULL,
                            video_id TEXT NOT NULL,
                            source_key TEXT NOT NULL,
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
                            PRIMARY KEY (
                                configuration_id, site_key, video_id, source_key
                            )
                        )
                        """
                    )
                    try connection.execute(
                        """
                        INSERT INTO history_v8 (
                            configuration_id, site_key, video_id, source_key,
                            title, poster_url, source_name, episode_name,
                            media_reference, position, duration, watched_at,
                            episode_reference, playback_reference
                        )
                        SELECT configuration_id, site_key, video_id,
                               CASE
                                   WHEN trim(COALESCE(source_name, '')) = ''
                                       THEN '__legacy__'
                                   ELSE trim(source_name)
                               END,
                               title, poster_url, source_name, episode_name,
                               media_reference, position, duration, watched_at,
                               episode_reference, playback_reference
                        FROM history
                        """
                    )
                    try connection.execute("DROP TABLE history")
                    try connection.execute(
                        "ALTER TABLE history_v8 RENAME TO history"
                    )
                    try connection.execute(
                        "CREATE INDEX history_watched_at ON history(watched_at)"
                    )
                    try connection.execute(
                        "CREATE INDEX history_configuration_watched_at ON history(configuration_id, watched_at DESC)"
                    )
                }
                try connection.execute("PRAGMA user_version = 8")
            }
        }
    }

    private static func columnExists(
        _ column: String,
        in table: String,
        connection: SQLiteConnection
    ) throws -> Bool {
        var exists = false
        try connection.query("PRAGMA table_info(\(table))") { statement in
            if connection.text(statement, 1) == column {
                exists = true
            }
        }
        return exists
    }

    private static func verify(_ connection: SQLiteConnection) throws {
        var result: String?
        try connection.query("PRAGMA quick_check") { statement in
            result = connection.text(statement, 0)
        }
        guard result == "ok" else {
            throw AppError.database("数据库完整性检查失败：\(result ?? "无结果")")
        }
    }

    private static func restrictDatabasePermissions(_ databaseURL: URL) throws {
        let fileManager = FileManager.default
        let candidates = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm"
        ]
        for path in candidates where fileManager.fileExists(atPath: path) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    private func configuration(from statement: OpaquePointer) throws -> StoredConfiguration? {
        guard let rawID = connection.text(statement, 0),
              let id = UUID(uuidString: rawID),
              let name = connection.text(statement, 1),
              let rawKind = connection.text(statement, 2),
              let kind = StoredConfigurationSourceKind(rawValue: rawKind),
              let rawData = connection.data(statement, 5) else {
            return nil
        }
        return StoredConfiguration(
            id: id,
            name: name,
            sourceKind: kind,
            sourceValue: connection.text(statement, 3),
            baseURL: connection.text(statement, 4).flatMap(URL.init(string:)),
            rawData: rawData,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isActive: sqlite3_column_int(statement, 7) == 1
        )
    }

    private func liveSource(from statement: OpaquePointer) -> StoredLiveSource? {
        guard let rawID = connection.text(statement, 0),
              let id = UUID(uuidString: rawID),
              let name = connection.text(statement, 1),
              let rawKind = connection.text(statement, 2),
              let kind = StoredLiveSourceKind(rawValue: rawKind),
              let rawData = connection.data(statement, 5) else {
            return nil
        }
        return StoredLiveSource(
            id: id,
            name: name,
            sourceKind: kind,
            sourceValue: connection.text(statement, 3),
            baseURL: connection.text(statement, 4).flatMap(URL.init(string:)),
            rawData: rawData,
            updatedAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 6)
            )
        )
    }

}
