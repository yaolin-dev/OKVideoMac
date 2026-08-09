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
    public static let currentSchemaVersion = 4

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
        } catch {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: databaseURL.path) else {
                throw error
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
            return OpenResult(
                store: try SQLiteStore(databaseURL: databaseURL),
                quarantinedDatabaseDirectory: quarantine
            )
        }
    }

    public func saveConfiguration(_ configuration: StoredConfiguration) throws {
        try connection.transaction {
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
    }

    public func configurations() throws -> [StoredConfiguration] {
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
        try connection.execute(
            """
            INSERT INTO history (
                configuration_id, site_key, video_id, title, poster_url, source_name,
                episode_name, episode_reference, media_reference,
                position, duration, watched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(configuration_id, site_key, video_id) DO UPDATE SET
                title = excluded.title,
                poster_url = excluded.poster_url,
                source_name = excluded.source_name,
                episode_name = excluded.episode_name,
                episode_reference = excluded.episode_reference,
                media_reference = excluded.media_reference,
                position = excluded.position,
                duration = excluded.duration,
                watched_at = excluded.watched_at
            """,
            bindings: [
                .text(history.configurationID?.uuidString.lowercased() ?? ""),
                .text(history.siteKey),
                .text(history.videoID),
                .text(history.title),
                .optional(history.posterURL?.absoluteString),
                .optional(history.sourceName),
                .optional(history.episodeName),
                .optional(history.episodeReference),
                .optional(Self.safeMediaReference(history.mediaReference)),
                .double(history.position),
                .double(history.duration),
                .double(history.watchedAt.timeIntervalSince1970)
            ]
        )
    }

    public func history() throws -> [HistoryRecord] {
        var values: [HistoryRecord] = []
        try connection.query(
            """
            SELECT configuration_id, site_key, video_id, title, poster_url, source_name,
                   episode_name, episode_reference, media_reference,
                   position, duration, watched_at
            FROM history
            ORDER BY watched_at DESC
            """
        ) { statement in
            values.append(
                HistoryRecord(
                    configurationID: self.connection.text(statement, 0)
                        .flatMap(UUID.init(uuidString:)),
                    siteKey: self.connection.text(statement, 1) ?? "",
                    videoID: self.connection.text(statement, 2) ?? "",
                    title: self.connection.text(statement, 3) ?? "",
                    posterURL: self.connection.text(statement, 4).flatMap(URL.init(string:)),
                    sourceName: self.connection.text(statement, 5),
                    episodeName: self.connection.text(statement, 6),
                    episodeReference: self.connection.text(statement, 7),
                    mediaReference: self.connection.text(statement, 8),
                    position: sqlite3_column_double(statement, 9),
                    duration: sqlite3_column_double(statement, 10),
                    watchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
                )
            )
        }
        return values
    }

    @discardableResult
    public func deleteHistory(
        configurationID: UUID?,
        siteKey: String,
        videoID: String
    ) throws -> Int {
        try connection.execute(
            """
            DELETE FROM history
            WHERE configuration_id = ? AND site_key = ? AND video_id = ?
            """,
            bindings: [
                .text(configurationID?.uuidString.lowercased() ?? ""),
                .text(siteKey),
                .text(videoID)
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

    private static func safeMediaReference(_ value: String?) -> String? {
        guard let value, let url = URL(string: value) else { return value }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return value
        }
        let sensitive = ["token", "auth", "authorization", "cookie", "password", "secret", "key"]
        components.queryItems = components.queryItems?.map { item in
            sensitive.contains(where: { item.name.lowercased().contains($0) })
                ? URLQueryItem(name: item.name, value: "<redacted>")
                : item
        }
        return components.string
    }
}
