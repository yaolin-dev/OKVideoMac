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
    public static let currentSchemaVersion = 13

    var suppressedHistorySessions = Set<UUID>()
    private var watchedSessionRecords: [UUID: [String: HistoryRecord]] = [:]
    private let connection: SQLiteConnection
    public let databaseURL: URL
    public nonisolated let importedIdentityAcceptanceEnabled: Bool

    public struct OpenResult {
        public let store: SQLiteStore
        public let quarantinedDatabaseDirectory: URL?

        public init(store: SQLiteStore, quarantinedDatabaseDirectory: URL?) {
            self.store = store
            self.quarantinedDatabaseDirectory = quarantinedDatabaseDirectory
        }
    }

    public init(databaseURL: URL) throws {
        self.importedIdentityAcceptanceEnabled = false
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

    /// Same actor/connection as all App persistence; schema 12 remains opt-in
    /// only through a validated isolated workspace, never the default opener.
    public init(importedAcceptance workspace: ImportedAcceptanceWorkspace) throws {
        try workspace.validate()
        self.databaseURL = workspace.databaseURL
        self.importedIdentityAcceptanceEnabled = true
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let acceptanceConnection = try SQLiteConnection(url: databaseURL)
        connection = acceptanceConnection
        try Self.configure(acceptanceConnection)
        try Self.migrateAcceptance(acceptanceConnection)
        try Self.verify(acceptanceConnection)
        try Self.restrictDatabasePermissions(databaseURL)
    }

    private static func migrateAcceptance(_ connection: SQLiteConnection) throws {
        let version = try connection.scalarInt("PRAGMA user_version")
        if version < 11 { try Self.migrate(connection) }
        guard version <= 12 || version == 13 else { throw ImportedExecutionError.blocked }
        if version < 11 || version == 13 {
            try connection.transaction {
                try ImportedMigrationStore.createAuthoritySchema(connection)
                try connection.execute("PRAGMA user_version=11")
                let t = ImportedMigrationTransaction(connection)
                defer { t.active = false }
                _ = try t.snapshot()
            }
        }
        if try connection.scalarInt("PRAGMA user_version") == 11 {
            try ImportedSourceLifecycleSQL.migrate(connection)
        }
        try migrateFavorites(connection, production: false)
    }

    public func importedCatalogMapping(sourceID: UUID, generation: ImportedCatalogGeneration) throws -> ImportedCatalogMapping {
        try importedCatalogMapping(sourceID: sourceID, generation: generation, beforeCommit: {})
    }
    // Deterministic cancellation injection for transaction regression tests.
    func importedCatalogMapping(sourceID: UUID, generation: ImportedCatalogGeneration, beforeCommit: () -> Void) throws -> ImportedCatalogMapping {
        guard importedIdentityAcceptanceEnabled, generation.sourceID == sourceID else { throw ImportedExecutionError.blocked }
        return try importedTransaction(generation: generation) {
                let t = ImportedMigrationTransaction(connection); defer { t.active = false }
                let session = ImportedMigrationExecutionSession()
                let snapshot = try t.snapshot()
                let plan = try session.prepare(snapshot)
                guard snapshot.sources.contains(where: { $0.id == sourceID }) else { throw ImportedExecutionError.blocked }
                _ = try session.execute(plan, transaction: t, sourceID: sourceID)
                beforeCommit()
                return ImportedCatalogMapping(sourceID: sourceID, generation: generation,
                    plan: try session.prepare(t.snapshot()), session: session)
        }
    }

    /// Catalog replacement and identity allocation share the SAME admission.
    /// A late network result cannot even replace source rawData after revocation.
    public func acceptImportedRefresh(_ source: StoredLiveSource, generation: ImportedCatalogGeneration) throws {
        guard importedIdentityAcceptanceEnabled, source.id == generation.sourceID else { throw ImportedExecutionError.blocked }
        try importedTransaction(generation: generation) { try updateLiveSourceRow(source) }
    }

    private func importedTransaction<T>(generation: ImportedCatalogGeneration, validationPermit: LiveValidationPermit? = nil, body: () throws -> T) throws -> T {
        guard generation.isCurrent else { throw ImportedExecutionError.stalePlan }
        if let validationPermit {
            guard validationPermit.sourceID == generation.sourceID, !validationPermit.isCancelled else { throw CancellationError() }
        }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try ImportedSourceLifecycleSQL.requireActive(generation.sourceID, connection)
            let value = try body()
            // The lock covers ONLY COMMIT, not catalog parsing/reconciliation.
            // Invalidation during preparation causes rollback, including UUIDs.
            try generation.admit {
                if let validationPermit { try validationPermit.commit { try connection.execute("COMMIT") } }
                else { try connection.execute("COMMIT") }
            }
            return value
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    public func setImportedReferences(mapping: ImportedCatalogMapping,
        edits: [(channel: LiveChannel, kind: MigrationReferenceKind, present: Bool)],
        validationPermit: LiveValidationPermit? = nil) throws -> ImportedCatalogMapping {
        try setImportedReferences(mapping: mapping, edits: edits, validationPermit: validationPermit, beforeCommit: {})
    }
    func setImportedReferences(mapping: ImportedCatalogMapping,
        edits: [(channel: LiveChannel, kind: MigrationReferenceKind, present: Bool)],
        validationPermit: LiveValidationPermit?, beforeCommit: () throws -> Void) throws -> ImportedCatalogMapping {
        guard importedIdentityAcceptanceEnabled else { throw ImportedExecutionError.blocked }
        return try importedTransaction(generation: mapping.generation, validationPermit: validationPermit) {
                let t = ImportedMigrationTransaction(connection); defer { t.active = false }
                let session = mapping.session
                let plan = try session.prepare(t.snapshot())
                guard plan.planFingerprint == mapping.plan.planFingerprint else { throw ImportedExecutionError.stalePlan }
                for edit in edits {
                    try session.writeValidated(plan, transaction: t, sourceID: mapping.sourceID,
                        channel: edit.channel, kind: edit.kind, present: edit.present)
                }
                try beforeCommit()
                return ImportedCatalogMapping(sourceID: mapping.sourceID, generation: mapping.generation,
                    plan: try session.prepare(t.snapshot()), session: session)
        }
    }

    /// Legacy-only background validation batch. Never usable to bypass claimed
    /// authority in the isolated identity App. Read current settings inside the
    /// transaction, preserve unrelated tokens, and commit BOTH values atomically.
    public func applyLegacyLiveValidation(source: StoredLiveSource, channels: [LiveChannel],
        permit: LiveValidationPermit) throws -> (hidden: Set<String>, favorites: Set<String>) {
        try applyLegacyLiveValidation(source: source, channels: channels, permit: permit, beforeCommit: {})
    }
    func applyLegacyLiveValidation(source: StoredLiveSource, channels: [LiveChannel],
        permit: LiveValidationPermit, beforeCommit: () throws -> Void) throws -> (hidden: Set<String>, favorites: Set<String>) {
        guard !importedIdentityAcceptanceEnabled, source.id == permit.sourceID, !permit.isCancelled else { throw CancellationError() }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            var currentData: Data?
            var currentName: String?
            try connection.query("SELECT raw_data,name FROM live_sources WHERE id=?", bindings: [.text(source.id.uuidString)]) {
                currentData = connection.data($0, 0); currentName = connection.text($0, 1)
            }
            guard currentData == source.rawData, currentName == source.name else { throw ImportedExecutionError.stalePlan }
            func tokens(_ key: String) throws -> Set<String> {
                guard let value = try setting(forKey: key) else { return [] }
                guard case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) else { throw ImportedExecutionError.blocked }
                return Set(items.compactMap(\.stringValue))
            }
            var hidden = try tokens("live.deletedChannels"), favorites = try tokens("live.favoriteChannels")
            for channel in channels {
                hidden.insert(ImportedChannelMigrationPlanner.hiddenKey(sourceID: source.id, channelID: channel.id))
                favorites.remove(ImportedChannelMigrationPlanner.favoriteKey(sourceName: source.name, channelID: channel.id))
            }
            try setSetting(.array(hidden.sorted().map(JSONValue.string)), forKey: "live.deletedChannels")
            try setSetting(.array(favorites.sorted().map(JSONValue.string)), forKey: "live.favoriteChannels")
            try beforeCommit()
            try permit.commit { try connection.execute("COMMIT") }
            return (hidden, favorites)
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
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
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
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
        // A read-only quick_check can report a transient WAL error while
        // another OKVideoMac process is actively writing. Moving the database,
        // WAL and SHM at that point detaches the live writer and makes all data
        // disappear from the newly opened process. Require writer ownership
        // before treating an integrity result as actionable corruption.
        let ownershipResult = sqlite3_exec(
            handle,
            "BEGIN EXCLUSIVE TRANSACTION",
            nil,
            nil,
            nil
        )
        if isCorruptionResult(ownershipResult) {
            return true
        }
        guard ownershipResult == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        }

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

    /// A refresh updates content only. It cannot create a deleted row, change
    /// activation, or overwrite a newer publication accepted while downloading.
    public func refreshActiveConfiguration(_ configuration: StoredConfiguration, expectedUpdatedAt: Date) throws -> Bool {
        try Task.checkCancellation()
        try connection.execute("""
            UPDATE configurations SET base_url=?,raw_data=?,updated_at=?
            WHERE id=? AND is_active=1 AND updated_at=?
            """, bindings: [.optional(configuration.baseURL?.absoluteString), .blob(configuration.rawData),
                .double(configuration.updatedAt.timeIntervalSince1970), .text(configuration.id.uuidString),
                .double(expectedUpdatedAt.timeIntervalSince1970)])
        return connection.lastChangedRowCount() == 1
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
        history importedHistory: [HistoryRecord],
        favorites importedFavorites: [FavoriteRecord]? = nil
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

            for var favorite in importedFavorites ?? [] {
                guard FavoritePersistencePolicy.isValid(favorite) else { throw AppError.database("备份收藏字段无效") }
                favorite.favoriteID = UUID()
                favorite.configurationID = targetID
                favorite.configurationName = restoredConfiguration.name
                try saveFavorite(favorite)
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
        try connection.transaction {
            try connection.execute(
                "DELETE FROM configurations WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            try deletePlaybackSkipRules(configurationID: id)
            try deletePlaybackCompletionMarkers(configurationID: id)
            try deleteDanmakuBindings(configurationID: id)
        }
    }

    public func saveLiveSource(_ source: StoredLiveSource) throws {
        if importedIdentityAcceptanceEnabled {
            // Compatibility entry is create-only in acceptance mode. Refresh
            // must use update-existing with an admitted generation.
            try createLiveSource(source)
            return
        }
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

    /// Refresh never creates a missing source. A delete accepted while the
    /// download was in flight remains authoritative, even across actor hops.
    public func refreshExistingLiveSource(_ source: StoredLiveSource) throws -> Bool {
        guard !importedIdentityAcceptanceEnabled else { throw ImportedExecutionError.blocked }
        let values = sourceBindings(source)
        try connection.execute("""
            UPDATE live_sources SET name=?,source_kind=?,source_value=?,base_url=?,raw_data=?,updated_at=? WHERE id=?
            """, bindings: Array(values.dropFirst()) + [values[0]])
        return connection.lastChangedRowCount() == 1
    }

    public func createLiveSource(_ source: StoredLiveSource) throws {
        try connection.transaction {
            try connection.execute("""
                INSERT INTO live_sources(id,name,source_kind,source_value,base_url,raw_data,updated_at)
                VALUES (?,?,?,?,?,?,?)
                """, bindings: sourceBindings(source))
        }
    }

    public func updateImportedLiveSource(_ source: StoredLiveSource, generation: ImportedCatalogGeneration) throws {
        try acceptImportedRefresh(source, generation: generation)
    }

    private func sourceBindings(_ source: StoredLiveSource) -> [SQLiteBinding] {
        [.text(source.id.uuidString), .text(source.name), .text(source.sourceKind.rawValue),
         .optional(source.sourceValue), .optional(source.baseURL?.absoluteString), .blob(source.rawData),
         .double(source.updatedAt.timeIntervalSince1970)]
    }

    private func updateLiveSourceRow(_ source: StoredLiveSource) throws {
        try ImportedSourceLifecycleSQL.requireActive(source.id, connection)
        let values = sourceBindings(source)
        try connection.execute("""
            UPDATE live_sources SET name=?,source_kind=?,source_value=?,base_url=?,raw_data=?,updated_at=? WHERE id=?
            """, bindings: Array(values.dropFirst()) + [values[0]])
        guard connection.lastChangedRowCount() == 1 else { throw ImportedExecutionError.blocked }
    }

    public func liveSources() throws -> [StoredLiveSource] {
        var values: [StoredLiveSource] = []
        try connection.query(
            """
            SELECT id, name, source_kind, source_value, base_url,
                   raw_data, updated_at
            FROM live_sources
            \(importedIdentityAcceptanceEnabled ? "WHERE retired_at IS NULL" : "")
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
        if importedIdentityAcceptanceEnabled {
            // Caller must revoke its capability and use the retirement transaction.
            throw ImportedExecutionError.blocked
        }
        try connection.execute(
            "DELETE FROM live_sources WHERE id = ?",
            bindings: [.text(id.uuidString)]
        )
    }

    public func retireImportedSource(id: UUID, revokedGeneration: ImportedCatalogGeneration) throws {
        try retireImportedSource(id: id, revokedGeneration: revokedGeneration, checkpoint: { _ in })
    }

    func retireImportedSource(id: UUID, revokedGeneration: ImportedCatalogGeneration, checkpoint: (Int) throws -> Void) throws {
        guard importedIdentityAcceptanceEnabled, revokedGeneration.sourceID == id,
              !revokedGeneration.isCurrent else { throw ImportedExecutionError.blocked }
        try connection.transaction {
            try ImportedSourceLifecycleSQL.requireActive(id, connection)
            let t = ImportedMigrationTransaction(connection); defer { t.active = false }
            let snapshot = try t.snapshot()
            try ImportedSourceLifecycleSQL.retire(id, snapshot: snapshot, connection: connection, checkpoint: checkpoint)
            _ = try t.snapshot() // Validate historical relations, NOT active reconciliation.
        }
    }

    public func saveFavorite(_ favorite: FavoriteRecord) throws {
        let records = try favorites()
        let existing = records.first { $0.identity == favorite.identity }
        guard !records.contains(where: { $0.favoriteID == favorite.favoriteID && $0.identity != favorite.identity }) else {
            throw AppError.database("收藏记录标识冲突")
        }
        let recordID = existing?.favoriteID ?? favorite.favoriteID
        try connection.execute("""
            INSERT INTO favorites (favorite_id, configuration_id, configuration_name, site_name, source_fingerprint,
                site_key, video_id, title, poster_url, synopsis, created_at, year, category_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(favorite_id) DO UPDATE SET title=excluded.title, poster_url=excluded.poster_url,
                synopsis=excluded.synopsis, configuration_name=excluded.configuration_name,
                site_name=excluded.site_name, year=excluded.year, category_name=excluded.category_name,
                created_at=MIN(favorites.created_at, excluded.created_at)
            """, bindings: [.text(recordID.uuidString.lowercased()),
                .text(favorite.configurationID?.uuidString.lowercased() ?? ""),
                .optional(favorite.configurationName), .optional(favorite.siteName), .text(favorite.sourceFingerprint),
                .text(favorite.siteKey), .text(favorite.videoID), .text(favorite.title),
                .optional(favorite.posterURL?.absoluteString), .optional(favorite.synopsis),
                .double(favorite.createdAt.timeIntervalSince1970), .optional(favorite.year), .optional(favorite.categoryName)])
    }

    public func favorites() throws -> [FavoriteRecord] {
        var values: [FavoriteRecord] = []
        try connection.query("""
            SELECT site_key, video_id, title, poster_url, synopsis, created_at, favorite_id,
                configuration_id, configuration_name, site_name, source_fingerprint, year, category_name
            FROM favorites ORDER BY created_at DESC, favorite_id
            """) { row in
            guard let id = self.connection.text(row, 6).flatMap(UUID.init(uuidString:)) else {
                throw AppError.database("收藏记录标识无效")
            }
            values.append(FavoriteRecord(siteKey: self.connection.text(row, 0) ?? "",
                videoID: self.connection.text(row, 1) ?? "", title: self.connection.text(row, 2) ?? "",
                posterURL: self.connection.text(row, 3).flatMap(URL.init(string:)), synopsis: self.connection.text(row, 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 5)), favoriteID: id,
                configurationID: self.connection.text(row, 7).flatMap(UUID.init(uuidString:)),
                configurationName: self.connection.text(row, 8), siteName: self.connection.text(row, 9),
                sourceFingerprint: self.connection.text(row, 10) ?? "", year: self.connection.text(row, 11),
                categoryName: self.connection.text(row, 12)))
        }
        return values
    }

    /// Explicit desired state, committed with its returned authoritative list.
    public func setFavorite(_ record: FavoriteRecord, isFavorite: Bool) throws -> [FavoriteRecord] {
        try connection.transaction {
            if isFavorite { try saveFavorite(record) }
            else {
                for existing in try favorites() where existing.identity == record.identity {
                    try connection.execute("DELETE FROM favorites WHERE favorite_id=?", bindings: [.text(existing.id)])
                }
            }
            return try favorites()
        }
    }

    public func deleteFavorites(ids: Set<String>) throws -> [FavoriteRecord] {
        try connection.transaction {
            for id in ids { try connection.execute("DELETE FROM favorites WHERE favorite_id=?", bindings: [.text(id)]) }
            return try favorites()
        }
    }

    /// Retained for older callers; an unscoped key may only remove a legacy row.
    public func deleteFavorite(siteKey: String, videoID: String) throws {
        try connection.execute("DELETE FROM favorites WHERE configuration_id='' AND site_key=? AND video_id=?",
                               bindings: [.text(siteKey), .text(videoID)])
    }
    @discardableResult public func deleteAllFavorites() throws -> Int {
        try connection.execute("DELETE FROM favorites")
        return connection.lastChangedRowCount()
    }

    /// Optimistic UPDATE: a late detail response cannot create a removed row.
    public func refreshFavorite(_ expected: FavoriteRecord, with metadata: FavoriteRecord) throws -> [FavoriteRecord] {
        try connection.transaction {
            guard try favorites().contains(expected) else { return try favorites() }
            try connection.execute("UPDATE favorites SET title=?, poster_url=?, synopsis=?, year=?, category_name=? WHERE favorite_id=?",
                bindings: [.text(metadata.title), .optional(metadata.posterURL?.absoluteString), .optional(metadata.synopsis),
                    .optional(metadata.year), .optional(metadata.categoryName), .text(expected.id)])
            return try favorites()
        }
    }

    public func bindFavorite(_ expected: FavoriteRecord, to target: FavoriteRecord) throws -> [FavoriteRecord] {
        try connection.transaction {
            let all = try favorites()
            guard all.contains(expected) else { throw AppError.database("收藏已更改，请重新打开") }
            let duplicate = all.first { $0.id != expected.id && $0.identity == target.identity }
            if let duplicate { try connection.execute("DELETE FROM favorites WHERE favorite_id=?", bindings: [.text(duplicate.id)]) }
            try connection.execute("""
                UPDATE favorites SET configuration_id=?, configuration_name=?, site_name=?, source_fingerprint=?,
                    site_key=?, video_id=?, title=?, poster_url=?, synopsis=?, created_at=?, year=?, category_name=? WHERE favorite_id=?
                """, bindings: [.text(target.configurationID?.uuidString.lowercased() ?? ""), .optional(target.configurationName),
                    .optional(target.siteName), .text(target.sourceFingerprint), .text(target.siteKey), .text(target.videoID),
                    .text(target.title), .optional(target.posterURL?.absoluteString), .optional(target.synopsis),
                    .double(min(expected.createdAt, duplicate?.createdAt ?? expected.createdAt).timeIntervalSince1970),
                    .optional(target.year), .optional(target.categoryName), .text(expected.id)])
            return try favorites()
        }
    }

    /// The database actor is the serialization boundary for playback and deletion.
    /// Suppression lasts for a logical viewing session, including quality switches.
    public func saveWatchedHistory(_ record: HistoryRecord, replacing original: HistoryRecord?,
                                   sessionID: UUID) throws -> Bool {
        guard !suppressedHistorySessions.contains(sessionID) else { return false }
        let saved = try connection.transaction {
            let changed = try writeHistory(record, onlyWhenNewer: true) > 0
            if changed, let original, original.id != record.id {
                _ = try deleteHistory(configurationID: original.configurationID,
                    siteKey: original.siteKey, videoID: original.videoID, sourceKey: original.sourceKey)
            }
            return changed
        }
        if saved {
            watchedSessionRecords[sessionID, default: [:]][record.id] = record
            if let original { watchedSessionRecords[sessionID, default: [:]][original.id] = original }
        }
        return saved
    }

    public func deleteWatchedHistory(_ records: [HistoryRecord], suppressing sessions: Set<UUID>) throws {
        var targets = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in sessions {
            for (id, record) in watchedSessionRecords[session] ?? [:] { targets[id] = record }
        }
        try connection.transaction {
            for record in targets.values {
                _ = try deleteHistory(configurationID: record.configurationID,
                    siteKey: record.siteKey, videoID: record.videoID, sourceKey: record.sourceKey)
            }
            try deletePlaybackCompletionMarkers(historyRecordIDs: Set(targets.keys))
        }
        suppressedHistorySessions.formUnion(sessions)
    }

    public func savePlaybackCompletionMarker(_ marker: PlaybackCompletionMarker,
                                             sessionID: UUID) throws {
        guard !suppressedHistorySessions.contains(sessionID) else { return }
        try savePlaybackCompletionMarker(marker)
    }

    public func saveHistory(_ history: HistoryRecord, incognito: Bool) throws {
        guard !incognito else { return }
        _ = try writeHistory(history, onlyWhenNewer: false)
    }

    public func replaceHistory(
        _ original: HistoryRecord,
        with replacement: HistoryRecord,
        incognito: Bool
    ) throws {
        guard !incognito else { return }
        try connection.transaction {
            _ = try deleteHistory(
                configurationID: original.configurationID,
                siteKey: original.siteKey,
                videoID: original.videoID,
                sourceKey: original.sourceKey
            )
            _ = try writeHistory(replacement, onlyWhenNewer: false)
        }
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
        if importedIdentityAcceptanceEnabled && ["live.favoriteChannels", "live.deletedChannels"].contains(key) {
            throw ImportedExecutionError.blocked // owned keys use the admitted reference transaction only
        }
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

    // Registry APIs are deliberately not used by AppState/importers in 8B.1.
    // Keep the connection private and reuse this actor's synchronous transaction
    // boundary; no await/reentrancy is allowed between BEGIN and COMMIT.
    public func importedChannelIdentity(_ identity: ImportedLiveChannelIdentity) throws -> ImportedChannelRegistryRecord? {
        try ImportedIdentityRegistrySQL.fetch(identity, connection: connection)
    }

    public func importedChannelIdentities(for source: LiveSourceID,
                                          lifecycle: ImportedChannelRegistryLifecycle? = nil) throws -> [ImportedChannelRegistryRecord] {
        try ImportedIdentityRegistrySQL.list(source, lifecycle: lifecycle, connection: connection)
    }

    public func applyImportedChannelIdentityMutations(_ mutations: [ImportedChannelRegistryMutation]) throws {
        // Low-level Registry maintenance is not an acceptance authority writer.
        // Allocation/retirement must use their complete transactions instead.
        guard !importedIdentityAcceptanceEnabled else { throw ImportedExecutionError.blocked }
        try connection.transaction {
            for mutation in mutations {
                try ImportedIdentityRegistrySQL.apply(mutation, connection: connection)
            }
        }
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
        let isolated = try connection.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='imported_reference_claims'") > 0
        guard version <= currentSchemaVersion, version != 11, version != 12, !isolated else {
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
        if version < 9 {
            try connection.transaction {
                var rows: [(
                    rowID: Int64,
                    playbackReference: String?
                )] = []
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
                    let decoded = row.playbackReference
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap {
                            try? decoder.decode(
                                HistoryPlaybackReference.self,
                                from: $0
                            )
                        }
                    let providerReference = decoded?.providerResourceReference
                    let isLegacyCatPawReplay = providerReference?.providerKind
                            == "node-http-spider"
                        && providerReference?.providerVersion == 2
                        && (providerReference?.stableResourceLocator
                            .hasPrefix("ndr2.") == true
                            || providerReference?.stableResourceLocator
                                .hasPrefix("nhr2.") == true)
                    guard isLegacyCatPawReplay else { continue }
                    let scrubbed = decoded?.sanitizedForPersistence()
                    let encoded = try scrubbed.map {
                        String(decoding: try encoder.encode($0), as: UTF8.self)
                    }
                    try connection.execute(
                        """
                        UPDATE history
                        SET episode_reference = ?, playback_reference = ?
                        WHERE rowid = ?
                        """,
                        bindings: [
                            .optional(
                                nil
                            ),
                            .optional(encoded),
                            .integer(row.rowID)
                        ]
                    )
                }
                try connection.execute("PRAGMA user_version = 9")
            }
            // ndr2 embeds provider replay arguments in the SQLite value. Rebuild
            // the file after removing it so old pages and WAL frames cannot keep
            // an unreachable copy.
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
            try connection.execute("VACUUM")
            try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
        }
        if version < 10 {
            try connection.transaction {
                try ImportedIdentityRegistrySQL.createSchema(connection)
                try connection.execute("PRAGMA user_version = 10")
            }
        }
        try migrateFavorites(connection, production: true, backup: version > 0)
    }

    private static func migrateFavorites(_ connection: SQLiteConnection, production: Bool, backup: Bool = true) throws {
        if try columnExists("favorite_id", in: "favorites", connection: connection) {
            if production { try connection.execute("PRAGMA user_version=13") }
            return
        }
        if backup {
            let destination = connection.url.deletingLastPathComponent().appendingPathComponent("Backups")
                .appendingPathComponent("before-favorites-schema13-\(UUID().uuidString).sqlite3")
            try connection.verifiedBackup(to: destination)
        }
        try connection.transaction {
            let count = try connection.scalarInt("SELECT count(*) FROM favorites")
            try connection.execute("ALTER TABLE favorites RENAME TO favorites_legacy")
            try connection.execute("""
                CREATE TABLE favorites (
                    favorite_id TEXT PRIMARY KEY NOT NULL,
                    configuration_id TEXT NOT NULL DEFAULT '', configuration_name TEXT, site_name TEXT,
                    source_fingerprint TEXT NOT NULL DEFAULT '', site_key TEXT NOT NULL, video_id TEXT NOT NULL,
                    title TEXT NOT NULL, poster_url TEXT, synopsis TEXT, created_at REAL NOT NULL,
                    year TEXT, category_name TEXT,
                    UNIQUE(configuration_id, site_key, source_fingerprint, video_id))
                """)
            try connection.query("SELECT site_key, video_id, title, poster_url, synopsis, created_at FROM favorites_legacy") { row in
                try connection.execute("""
                    INSERT INTO favorites (favorite_id, site_key, video_id, title, poster_url, synopsis, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, bindings: [.text(UUID().uuidString.lowercased()), .text(connection.text(row, 0) ?? ""),
                        .text(connection.text(row, 1) ?? ""), .text(connection.text(row, 2) ?? ""),
                        .optional(connection.text(row, 3)), .optional(connection.text(row, 4)),
                        .double(sqlite3_column_double(row, 5))])
            }
            guard try connection.scalarInt("SELECT count(*) FROM favorites") == count else {
                throw AppError.database("收藏迁移数量验证失败")
            }
            try verify(connection)
            try connection.execute("DROP TABLE favorites_legacy")
            if production { try connection.execute("PRAGMA user_version = 13") }
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
