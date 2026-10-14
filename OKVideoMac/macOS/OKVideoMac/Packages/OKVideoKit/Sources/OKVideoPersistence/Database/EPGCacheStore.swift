import Foundation
import Darwin
import CSQLite
import OKVideoCore

struct EPGCacheImportHandle: Equatable {
    let incarnation: UUID
    let resource: String
    let source: String
    let epoch: String
    let request: String
    let generation: String
}

struct EPGCacheRecord {
    let ordinal: Int
    let programme: EPGProgramme
}

struct EPGCacheValidation {
    let rawProgrammeCount: Int
    let emittedProgrammeCount: Int
    let minimumStart: Date?
    let maximumEnd: Date?
    let emittedChannelRecordCount: Int

    init(rawProgrammeCount: Int, emittedProgrammeCount: Int,
         minimumStart: Date?, maximumEnd: Date?, emittedChannelRecordCount: Int = 0) {
        self.rawProgrammeCount = rawProgrammeCount
        self.emittedProgrammeCount = emittedProgrammeCount
        self.minimumStart = minimumStart
        self.maximumEnd = maximumEnd
        self.emittedChannelRecordCount = emittedChannelRecordCount
    }
}

struct EPGCacheActiveIdentity: Equatable {
    let generation: String
    let programmeCount: Int
    let normalizationVersion: Int
}

struct EPGCacheActiveRecord: Equatable {
    let identity: EPGCacheActiveIdentity
    let resourceKey: String
    let sourceEpoch: String
    let publishedAt: Date
    let minimumStart: Date?
    let maximumEnd: Date?
}

struct EPGCacheCleanupProgress {
    let deletedProgrammes: Int
    let deletedAliases: Int
    let deletedChannels: Int
    let removedGeneration: Bool
    let hasWorkRemaining: Bool
}

struct EPGQuerySnapshotID: Equatable, Sendable {
    let storeIncarnation: UUID
    let resourceKey: String
    let sourceEpoch: String
    let generationID: String
}

struct EPGCacheProgrammeResult: Equatable, Sendable {
    let ordinal: Int
    let channelID: String
    let title: String
    let start: Date
    let end: Date
}

struct EPGCacheNowNextEntry: Equatable, Sendable {
    let match: EPGChannelMatch
    let current: EPGCacheProgrammeResult?
    let next: EPGCacheProgrammeResult?
}

struct EPGCacheNowNextResult: Equatable, Sendable {
    let snapshotID: EPGQuerySnapshotID
    let entries: [EPGCacheNowNextEntry]
}

struct EPGCacheChannelMatchesResult: Equatable, Sendable {
    let snapshotID: EPGQuerySnapshotID
    let matches: [EPGChannelMatch]
}

struct EPGCacheWindowCursor: Equatable, Sendable {
    let version: Int
    let snapshotID: EPGQuerySnapshotID
    let channelKey: String
    let windowStart: Date
    let windowEnd: Date
    let lastStart: Date
    let lastOrdinal: Int
}

struct EPGCacheWindowPage: Equatable, Sendable {
    let snapshotID: EPGQuerySnapshotID
    let match: EPGChannelMatch
    let programmes: [EPGCacheProgrammeResult]
    let nextCursor: EPGCacheWindowCursor?
}

struct EPGCacheQueryDiagnostics: Equatable, Sendable {
    var virtualMachineSteps = 0
    var fullScanSteps = 0
    var sortOperations = 0
    var automaticIndexRows = 0
    var maximumStatementBytes = 0
}

enum EPGCacheQueryError: Error, Equatable {
    case noActiveGeneration
    case invalidRequest
    case invalidCursor
    case snapshotChanged
    case cancelled
    case queryBudgetExceeded
    case queueFull
    case resultTooLarge
    case storeUnavailable
    case sqlite(Int32)
}

final class EPGCacheQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() { lock.withLock { value = true } }
    fileprivate var isCancelled: Bool { lock.withLock { value } }
}

private enum EPGCacheInterruptionReason {
    case callerCancelled
    case budgetExceeded
    case storeClosing
}

private final class EPGCacheQueryControl {
    private let lock = NSLock()
    private let cancellation: EPGCacheQueryCancellation?
    private let instructionBudget: Int
    private let stepInterval: Int
    private var work = 0
    private var storedReason: EPGCacheInterruptionReason?
    private var storedDiagnostics = EPGCacheQueryDiagnostics()

    init(cancellation: EPGCacheQueryCancellation?, instructionBudget: Int, stepInterval: Int) {
        self.cancellation = cancellation
        self.instructionBudget = instructionBudget
        self.stepInterval = stepInterval
    }

    func progressShouldStop() -> Bool {
        lock.withLock {
            if storedReason != nil { return true }
            if cancellation?.isCancelled == true {
                storedReason = .callerCancelled
                return true
            }
            work += stepInterval
            if work >= instructionBudget {
                storedReason = .budgetExceeded
                return true
            }
            return false
        }
    }

    func stop(_ reason: EPGCacheInterruptionReason) {
        lock.withLock { if storedReason == nil { storedReason = reason } }
    }

    func check() throws {
        if cancellation?.isCancelled == true { stop(.callerCancelled) }
        if let reason { throw reason.queryError }
    }

    func record(_ statement: EPGCacheStatement) {
        let vm = Int(statement.status(SQLITE_STMTSTATUS_VM_STEP, reset: true))
        let scan = Int(statement.status(SQLITE_STMTSTATUS_FULLSCAN_STEP, reset: true))
        let sort = Int(statement.status(SQLITE_STMTSTATUS_SORT, reset: true))
        let automatic = Int(statement.status(SQLITE_STMTSTATUS_AUTOINDEX, reset: true))
        let memory = Int(statement.status(SQLITE_STMTSTATUS_MEMUSED))
        lock.withLock {
            storedDiagnostics.virtualMachineSteps += vm
            storedDiagnostics.fullScanSteps += scan
            storedDiagnostics.sortOperations += sort
            storedDiagnostics.automaticIndexRows += automatic
            storedDiagnostics.maximumStatementBytes = max(storedDiagnostics.maximumStatementBytes, memory)
        }
    }

    var reason: EPGCacheInterruptionReason? { lock.withLock { storedReason } }
    var diagnostics: EPGCacheQueryDiagnostics { lock.withLock { storedDiagnostics } }
}

private extension EPGCacheInterruptionReason {
    var queryError: EPGCacheQueryError {
        switch self {
        case .callerCancelled: return .cancelled
        case .budgetExceeded: return .queryBudgetExceeded
        case .storeClosing: return .storeUnavailable
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

private struct EPGCachePreparedChannel {
    let key: String
    let rawID: String
    var aliases: Set<String>
}

private struct EPGCacheResolvedChannel {
    let match: EPGChannelMatch
    let channelKey: String?
}

private struct EPGCacheChannelMatchStatements {
    let exact: EPGCacheStatement
    let alias: EPGCacheStatement
    let rawID: EPGCacheStatement
}

/// 9C.1 internal storage only. No production construction, parser conformance,
/// full-guide API, or UI queries. Every connection operation runs on one queue.
/// Call from a background worker: these methods deliberately apply backpressure.
final class EPGCacheStore: @unchecked Sendable {
    private var importPipelineActive = false
    func acquireImportPipeline() throws {
        try queryStateLock.withLock {
            guard !isClosing else { throw EPGCacheError.closed }
            guard !importPipelineActive else { throw EPGCacheError.importInProgress }
            importPipelineActive = true
        }
    }
    func releaseImportPipeline() { queryStateLock.withLock { importPipelineActive = false } }
    static let schemaVersion = 3
    static let normalizationVersion = 1
    static let applicationID: Int64 = 0x4f4b4550
    static let maximumProgrammes = 200_000
    static let maximumKnownChannels = 400_000
    static let maximumAliases = 800_000
    static let maximumBatchBytes = 1_048_576
    static let maximumFieldBytes = 64 * 1_024 * 1_024
    static let maximumMetadataBytes = 64 * 1_024 * 1_024
    static let diskBudget = 256 * 1_024 * 1_024

    private let queue = DispatchQueue(label: "OKVideoMac.EPGCacheStorage", qos: .utility)
    private let readerQueue = DispatchQueue(label: "OKVideoMac.EPGCacheReader", qos: .utility)
    private let queryStateLock = NSLock()
    private let directory: URL
    private let maximumDatabaseBytes: Int
    private let queryVMInstructionBudget: Int
    private let queryProgressStepInterval: Int
    private let incarnation = UUID()
    private var database: EPGCacheDatabase?
    private var readerDatabase: EPGCacheDatabase?
    private var lockFD: Int32 = -1
    private var queryOperationCount = 0
    private var isClosing = false
    private var activeQueryControl: EPGCacheQueryControl?
    private var lastQueryDiagnosticsValue = EPGCacheQueryDiagnostics()
    private(set) var rebuiltOnOpen = false
    // Synchronous test barrier only; never installed by production code.
    var boundaryForTesting: ((String) -> Void)?
    var readerBoundaryForTesting: ((String) -> Void)?

    init(directory: URL, maximumDatabaseBytes: Int = 128 * 1_024 * 1_024,
         queryVMInstructionBudget: Int = 2_000_000,
         queryProgressStepInterval: Int = 1_000) throws {
        guard maximumDatabaseBytes >= 65_536, maximumDatabaseBytes <= 128 * 1_024 * 1_024 else {
            throw EPGCacheError.invalidInput
        }
        guard queryVMInstructionBudget > 0, queryVMInstructionBudget <= 50_000_000,
              queryProgressStepInterval > 0, queryProgressStepInterval <= 10_000 else {
            throw EPGCacheError.invalidInput
        }
        self.directory = directory.standardizedFileURL
        self.maximumDatabaseBytes = maximumDatabaseBytes
        self.queryVMInstructionBudget = queryVMInstructionBudget
        self.queryProgressStepInterval = queryProgressStepInterval
        do {
            try acquireDirectory()
            try openCache()
            try openReader()
        } catch {
            readerDatabase?.close(); readerDatabase = nil
            database?.close(); database = nil
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw error
        }
    }

    deinit { close() }
    func close() {
        let shouldClose: Bool = queryStateLock.withLock {
            guard !isClosing else { return false }
            isClosing = true
            activeQueryControl?.stop(.storeClosing)
            return true
        }
        guard shouldClose else { return }
        readerDatabase?.interrupt()
        readerQueue.sync {
            readerDatabase?.clearProgressHandler()
            readerDatabase?.close(); readerDatabase = nil
        }
        queue.sync {
            database?.close(); database = nil
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
        }
    }

    var queryOperationCountForTesting: Int { queryStateLock.withLock { queryOperationCount } }
    var isClosingForTesting: Bool { queryStateLock.withLock { isClosing } }
    var lastQueryDiagnosticsForTesting: EPGCacheQueryDiagnostics {
        queryStateLock.withLock { lastQueryDiagnosticsValue }
    }

    func begin(_ key: EPGRequestKey) throws -> EPGCacheImportHandle {
        try queue.sync {
            try Task.checkCancellation()
            let db = try connection()
            let resource = try resourceKey(key), source = sourceKey(key.source)
            try checkDiskBudget()
            guard try db.integer("SELECT COUNT(*) FROM generations") < 128 else { throw EPGCacheError.budgetExceeded }
            return try db.transaction {
                try checkMetadataCapacity(table: "sources", id: source, db: db)
                try checkMetadataCapacity(table: "resources", id: resource, db: db)
                try db.execute("INSERT OR IGNORE INTO sources(id,epoch,enabled) VALUES(?,?,1)",
                    [.text(source), .text(UUID().uuidString)])
                guard try db.integer("SELECT enabled FROM sources WHERE id=?", [.text(source)]) == 1,
                      let epoch = try db.string("SELECT epoch FROM sources WHERE id=?", [.text(source)]) else {
                    throw EPGCacheError.superseded
                }
                // One XMLTV resource per source. Starting a new revision also
                // revokes the former revision; a late old request cannot publish.
                try db.execute("UPDATE resources SET current_request=NULL WHERE source_id=?", [.text(source)])
                try db.execute("UPDATE resources SET active_generation=NULL WHERE source_id=? AND id<>?",
                    [.text(source), .text(resource)])
                try db.execute("INSERT OR IGNORE INTO resources(id,source_id) VALUES(?,?)",
                    [.text(resource), .text(source)])
                let value = EPGCacheImportHandle(incarnation: incarnation, resource: resource,
                    source: source, epoch: epoch, request: UUID().uuidString, generation: UUID().uuidString)
                try db.execute("UPDATE resources SET current_request=? WHERE id=?",
                    [.text(value.request), .text(resource)])
                try db.execute("""
                    INSERT INTO generations(id,resource_id,source_epoch,request_id,state,normalization_version)
                    VALUES(?,?,?,?,'staging',?)
                    """, [.text(value.generation), .text(resource), .text(epoch), .text(value.request),
                          .integer(Int64(Self.normalizationVersion))])
                return value
            }
        }
    }

    func append(_ records: [EPGCacheRecord], to handle: EPGCacheImportHandle) throws {
        try queue.sync {
            try Task.checkCancellation()
            let db = try connection()
            guard !records.isEmpty, records.count <= 512 else { throw EPGCacheError.budgetExceeded }
            var bytes = 0, previous = -1
            for record in records {
                let p = record.programme
                guard record.ordinal > previous, record.ordinal < Self.maximumProgrammes,
                      !p.channelID.isEmpty, !p.title.isEmpty,
                      p.start.timeIntervalSince1970.isFinite, p.end.timeIntervalSince1970.isFinite,
                      p.end > p.start else { throw EPGCacheError.invalidInput }
                previous = record.ordinal
                let count = p.channelID.utf8.count + p.title.utf8.count + 64
                guard count <= Self.maximumBatchBytes, bytes <= Self.maximumBatchBytes - count else {
                    throw EPGCacheError.budgetExceeded
                }
                bytes += count
            }
            let knownChannels = try prepareChannels(records.map {
                EPGChannel(id: $0.programme.channelID, displayName: $0.programme.channelID)
            })
            try checkDiskBudget()
            try db.transaction {
                try eligible(handle, state: "staging", db: db)
                try upsertKnownChannels(knownChannels, channelRecordDelta: 0,
                                        generation: handle.generation, db: db)
                let totals = try db.statement("SELECT count,field_bytes,last_ordinal FROM generations WHERE id=?")
                try totals.bind([.text(handle.generation)])
                guard try totals.step(), totals.integer(0) + Int64(records.count) <= Self.maximumProgrammes,
                      totals.integer(1) + Int64(bytes) <= Self.maximumFieldBytes,
                      Int64(records[0].ordinal) > totals.integer(2) else { throw EPGCacheError.budgetExceeded }
                let insert = try db.statement("""
                    INSERT INTO programmes(generation_id,ordinal,channel_reference,channel_key,start,end,title)
                    VALUES(?,?,?,?,?,?,?)
                    """)
                for record in records {
                    try Task.checkCancellation()
                    let p = record.programme
                    try insert.bind([.text(handle.generation), .integer(Int64(record.ordinal)),
                        .text(p.channelID), .text(XMLTVChannelNormalization.exactIDKey(p.channelID)),
                        .double(p.start.timeIntervalSince1970),
                        .double(p.end.timeIntervalSince1970), .text(p.title)])
                    _ = try insert.step()
                    try insert.reset() // reset AND clear every binding before reuse
                }
                try db.execute("""
                    UPDATE generations SET count=count+?,field_bytes=field_bytes+?,last_ordinal=? WHERE id=?
                    """, [.integer(Int64(records.count)), .integer(Int64(bytes)),
                          .integer(Int64(previous)), .text(handle.generation)])
                try Task.checkCancellation()
                try checkDiskBudget()
                boundaryForTesting?("appendBeforeCommit")
            }
        }
    }

    /// Channel declarations are optional in XMLTV, so programme append also
    /// creates known channels from references. Declaration records add display
    /// names and aliases without requiring a complete in-memory channel list.
    func appendChannels(_ channels: [EPGChannel], to handle: EPGCacheImportHandle) throws {
        try queue.sync {
            try Task.checkCancellation()
            guard !channels.isEmpty, channels.count <= 512 else { throw EPGCacheError.budgetExceeded }
            let prepared = try prepareChannels(channels)
            let db = try connection()
            try checkDiskBudget()
            try db.transaction {
                try eligible(handle, state: "staging", db: db)
                try upsertKnownChannels(prepared, channelRecordDelta: channels.count,
                                        generation: handle.generation, db: db)
                try Task.checkCancellation()
                try checkDiskBudget()
            }
        }
    }

    /// Seals the generation. In 9C.3 only successful parser return may supply
    /// this metadata; this storage primitive alone cannot prove XML/gzip EOF.
    func validate(_ handle: EPGCacheImportHandle, summary: EPGCacheValidation,
                  checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) throws {
        try queue.sync {
            try Task.checkCancellation()
            let db = try connection()
            try checkCancellation()
            var interruption: Error?
            try db.installProgressHandler(stepInterval: 1000) { [self] in
                do {
                    try checkCancellation()
                    if queryStateLock.withLock({ isClosing }) { throw EPGCacheError.closed }
                    return false
                } catch { interruption = error; return true }
            }
            defer { db.clearProgressHandler() }
            guard summary.rawProgrammeCount >= 0, summary.rawProgrammeCount <= Self.maximumProgrammes,
                  summary.emittedProgrammeCount >= 0,
                  summary.emittedProgrammeCount <= summary.rawProgrammeCount,
                  summary.emittedChannelRecordCount >= 0,
                  summary.emittedChannelRecordCount <= Self.maximumKnownChannels else {
                throw EPGCacheError.invalidInput
            }
            do { try db.transaction {
                try eligible(handle, state: "staging", db: db)
                let query = try db.statement("""
                    SELECT COUNT(*),COALESCE(MAX(ordinal),-1),MIN(start),MAX(end),
                      COALESCE(SUM(length(CAST(channel_reference AS BLOB))+length(CAST(title AS BLOB))+64),0)
                    FROM programmes WHERE generation_id=?
                    """)
                try query.bind([.text(handle.generation)])
                _ = try query.step()
                let count = query.integer(0)
                guard count == summary.emittedProgrammeCount,
                      count == (try db.integer("SELECT count FROM generations WHERE id=?", [.text(handle.generation)])),
                      query.integer(1) < summary.rawProgrammeCount,
                      query.integer(4) == (try db.integer("SELECT field_bytes FROM generations WHERE id=?", [.text(handle.generation)]))
                else { throw EPGCacheError.validationFailed }
                if count == 0 {
                    guard summary.minimumStart == nil, summary.maximumEnd == nil else { throw EPGCacheError.validationFailed }
                } else {
                    guard let start = summary.minimumStart?.timeIntervalSince1970,
                          let end = summary.maximumEnd?.timeIntervalSince1970,
                          start.isFinite, end.isFinite, start == query.number(2), end == query.number(3) else {
                        throw EPGCacheError.validationFailed
                    }
                }
                let metadata = try db.statement("""
                    SELECT channel_count,alias_count,metadata_bytes,channel_records
                    FROM generations WHERE id=?
                    """)
                try metadata.bind([.text(handle.generation)])
                guard try metadata.step(),
                      metadata.integer(0) == (try db.integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(handle.generation)])),
                      metadata.integer(1) == (try db.integer("SELECT COUNT(*) FROM channel_aliases WHERE generation_id=?", [.text(handle.generation)])),
                      metadata.integer(3) == summary.emittedChannelRecordCount else {
                    throw EPGCacheError.validationFailed
                }
                let channelBytes = try db.integer("""
                    SELECT COALESCE(SUM(length(CAST(channel_key AS BLOB))+
                      length(CAST(raw_channel_id AS BLOB))+32),0)
                    FROM channels WHERE generation_id=?
                    """, [.text(handle.generation)])
                let aliasBytes = try db.integer("""
                    SELECT COALESCE(SUM(length(CAST(normalized_alias AS BLOB))+
                      length(CAST(channel_key AS BLOB))+32),0)
                    FROM channel_aliases WHERE generation_id=?
                    """, [.text(handle.generation)])
                guard metadata.integer(2) == channelBytes + aliasBytes,
                      try db.integer("""
                        SELECT COUNT(*) FROM programmes p WHERE p.generation_id=? AND NOT EXISTS(
                          SELECT 1 FROM channels c WHERE c.generation_id=p.generation_id
                            AND c.channel_key=p.channel_key)
                        """, [.text(handle.generation)]) == 0 else {
                    throw EPGCacheError.validationFailed
                }
                try db.execute("UPDATE generations SET state='validated',raw_count=?,min_start=?,max_end=? WHERE id=?", [
                    .integer(Int64(summary.rawProgrammeCount)),
                    summary.minimumStart.map { .double($0.timeIntervalSince1970) } ?? .null,
                    summary.maximumEnd.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .text(handle.generation)])
                try Task.checkCancellation()
                boundaryForTesting?("validateBeforeCommit")
                try checkCancellation()
            } } catch { throw interruption ?? error }
        }
    }

    /// Carry previously observed, finished programmes into the next coherent
    /// generation. Fresh provider data wins; no aliases or removed channels are
    /// resurrected. This never manufactures missing historical schedules.
    func retainCatchupHistory(_ handle: EPGCacheImportHandle, now: Date = Date(),
                              checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) throws {
        try queue.sync {
            guard now.timeIntervalSince1970.isFinite else { throw EPGCacheError.invalidInput }
            try checkCancellation()
            let db = try connection()
            var interruption: Error?
            try db.installProgressHandler(stepInterval: 1000) { [self] in
                do {
                    try checkCancellation()
                    if queryStateLock.withLock({ isClosing }) { throw EPGCacheError.closed }
                    return false
                } catch { interruption = error; return true }
            }
            defer { db.clearProgressHandler() }
            do { try db.transaction {
                try eligible(handle, state: "validated", db: db)
                guard let old = try db.string("""
                    SELECT g.id FROM resources r JOIN generations g ON g.id=r.active_generation
                    WHERE r.id=? AND g.source_epoch=? AND g.state='active'
                    """, [.text(handle.resource), .text(handle.epoch)]) else { return }
                let facts = try db.statement("SELECT raw_count,field_bytes FROM generations WHERE id=?")
                try facts.bind([.text(handle.generation)])
                guard try facts.step() else { throw EPGCacheError.invalidState }
                let firstOrdinal = facts.integer(0)
                let remainingCount = Int64(Self.maximumProgrammes) - firstOrdinal
                let remainingBytes = Int64(Self.maximumFieldBytes) - facts.integer(1)
                guard remainingCount > 0, remainingBytes > 0 else { return }
                try db.execute("""
                    WITH fresh AS (
                      SELECT channel_key,MIN(start) AS first_start FROM programmes
                      WHERE generation_id=? GROUP BY channel_key
                    ), candidates AS (
                      SELECT p.*,
                        SUM(length(CAST(p.channel_reference AS BLOB))+length(CAST(p.title AS BLOB))+64)
                          OVER(ORDER BY p.start DESC,p.ordinal) AS running_bytes
                      FROM programmes p JOIN fresh f ON f.channel_key=p.channel_key
                      WHERE p.generation_id=? AND p.start>=? AND p.end<=? AND p.end<=f.first_start
                    ), bounded AS (
                      SELECT * FROM candidates WHERE running_bytes<=?
                      ORDER BY start DESC,ordinal LIMIT ?
                    )
                    INSERT INTO programmes(generation_id,ordinal,channel_reference,channel_key,start,end,title)
                    SELECT ?,?+ROW_NUMBER() OVER(ORDER BY start,ordinal)-1,
                      channel_reference,channel_key,start,end,title FROM bounded
                    """, [.text(handle.generation), .text(old),
                          .double(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970),
                          .double(now.timeIntervalSince1970), .integer(remainingBytes), .integer(remainingCount),
                          .text(handle.generation), .integer(firstOrdinal)])
                let added = Int64(db.changes)
                guard added > 0 else { return }
                try db.execute("""
                    UPDATE generations SET count=count+?,raw_count=raw_count+?,
                      last_ordinal=raw_count+?-1,
                      field_bytes=(SELECT COALESCE(SUM(length(CAST(channel_reference AS BLOB))+length(CAST(title AS BLOB))+64),0)
                        FROM programmes WHERE generation_id=?),
                      min_start=(SELECT MIN(start) FROM programmes WHERE generation_id=?),
                      max_end=(SELECT MAX(end) FROM programmes WHERE generation_id=?)
                    WHERE id=?
                    """, [.integer(added), .integer(added), .integer(added),
                          .text(handle.generation), .text(handle.generation), .text(handle.generation), .text(handle.generation)])
                try checkCancellation()
                try checkDiskBudget()
            } } catch { throw interruption ?? error }
        }
    }

    func activate(_ handle: EPGCacheImportHandle, control: EPGImportControl? = nil) throws -> EPGCacheActiveIdentity {
        try queue.sync {
            try Task.checkCancellation()
            let db = try connection()
            let publish = { [self] in try db.transaction {
                try eligible(handle, state: "validated", db: db)
                let old = try db.string("SELECT active_generation FROM resources WHERE id=?", [.text(handle.resource)])
                try db.execute("""
                    UPDATE resources SET active_generation=?,current_request=NULL
                    WHERE id=? AND source_id=? AND current_request=?
                      AND EXISTS(SELECT 1 FROM sources WHERE id=resources.source_id AND epoch=? AND enabled=1)
                      AND EXISTS(SELECT 1 FROM generations WHERE id=? AND resource_id=resources.id
                        AND source_epoch=? AND request_id=? AND state='validated')
                    """, [.text(handle.generation), .text(handle.resource), .text(handle.source),
                          .text(handle.request), .text(handle.epoch), .text(handle.generation),
                          .text(handle.epoch), .text(handle.request)])
                guard db.changes == 1 else { throw EPGCacheError.superseded }
                if let old {
                    try db.execute("UPDATE generations SET state='retired' WHERE id=?", [.text(old)])
                }
                try db.execute("UPDATE generations SET state='active',published_at=? WHERE id=?",
                               [.double(Date().timeIntervalSince1970), .text(handle.generation)])
                let result = EPGCacheActiveIdentity(generation: handle.generation,
                    programmeCount: Int(try db.integer("SELECT count FROM generations WHERE id=?", [.text(handle.generation)])),
                    normalizationVersion: Self.normalizationVersion)
                try Task.checkCancellation()
                boundaryForTesting?("activateBeforeCommit")
                return result // transaction() commits before this becomes visible to caller
            } }
            let active = try control.map { try $0.activate(publish) } ?? publish()
            boundaryForTesting?("activateAfterCommit")
            return active
        }
    }

    /// Cancel is ordered on the same writer queue as activate. After commit it
    /// is a no-op; it never revokes a published generation or a newer request.
    func abandon(_ handle: EPGCacheImportHandle) throws {
        try queue.sync {
            let db = try connection()
            try checkHandle(handle)
            try db.transaction {
                guard try db.integer("SELECT COUNT(*) FROM resources WHERE active_generation=?", [.text(handle.generation)]) == 0 else { return }
                try db.execute("UPDATE resources SET current_request=NULL WHERE id=? AND current_request=?",
                    [.text(handle.resource), .text(handle.request)])
                try db.execute("""
                    UPDATE generations SET state='abandoned' WHERE id=? AND resource_id=? AND request_id=?
                    """, [.text(handle.generation), .text(handle.resource), .text(handle.request)])
            }
        }
    }

    /// Explicit source lifecycle operation; reopening a disabled source requires
    /// another explicit call. A new epoch prevents delete/recreate ABA races.
    func setSourceEnabled(_ source: EPGSourceKey, enabled: Bool) throws {
        try queue.sync {
            let db = try connection(), id = sourceKey(source)
            if let current = try db.string("SELECT CAST(enabled AS TEXT) FROM sources WHERE id=?", [.text(id)]),
               current == (enabled ? "1" : "0") { return }
            try db.transaction {
                try checkMetadataCapacity(table: "sources", id: id, db: db)
                try db.execute("""
                    INSERT INTO sources(id,epoch,enabled) VALUES(?,?,?)
                    ON CONFLICT(id) DO UPDATE SET epoch=excluded.epoch,enabled=excluded.enabled
                    """, [.text(id), .text(UUID().uuidString), .integer(enabled ? 1 : 0)])
                try db.execute("UPDATE resources SET current_request=NULL,active_generation=NULL WHERE source_id=?", [.text(id)])
            }
        }
    }

    func activeIdentity(for key: EPGRequestKey) throws -> EPGCacheActiveIdentity? {
        try queue.sync {
            let db = try connection()
            let query = try db.statement("""
                SELECT g.id,g.count,g.normalization_version FROM resources r
                JOIN sources s ON s.id=r.source_id AND s.enabled=1
                JOIN generations g ON g.id=r.active_generation AND g.resource_id=r.id AND g.source_epoch=s.epoch
                WHERE r.id=?
                """)
            try query.bind([.text(try resourceKey(key))])
            guard try query.step(), let id = query.text(0) else { return nil }
            return EPGCacheActiveIdentity(generation: id, programmeCount: Int(query.integer(1)),
                                          normalizationVersion: Int(query.integer(2)))
        }
    }

    func activeRecord(for key: EPGRequestKey) throws -> EPGCacheActiveRecord? {
        try queue.sync {
            let db = try connection()
            let resource = try resourceKey(key)
            let query = try db.statement("""
                SELECT g.id,g.count,g.normalization_version,g.source_epoch,g.published_at,g.min_start,g.max_end
                FROM resources r
                JOIN sources s ON s.id=r.source_id AND s.enabled=1
                JOIN generations g ON g.id=r.active_generation AND g.resource_id=r.id AND g.source_epoch=s.epoch
                WHERE r.id=?
                """)
            try query.bind([.text(resource)])
            guard try query.step(), let generation = query.text(0),
                  let epoch = query.text(3), !query.isNull(4) else { return nil }
            let identity = EPGCacheActiveIdentity(generation: generation,
                programmeCount: Int(query.integer(1)), normalizationVersion: Int(query.integer(2)))
            return EPGCacheActiveRecord(identity: identity, resourceKey: resource,
                sourceEpoch: epoch, publishedAt: Date(timeIntervalSince1970: query.number(4)),
                minimumStart: query.isNull(5) ? nil : Date(timeIntervalSince1970: query.number(5)),
                maximumEnd: query.isNull(6) ? nil : Date(timeIntervalSince1970: query.number(6)))
        }
    }

    func matchChannels(_ channels: [LiveChannel], for key: EPGRequestKey,
                       cancellation: EPGCacheQueryCancellation? = nil) throws -> EPGCacheChannelMatchesResult {
        try validateQueryInput(channels)
        return try performReaderQuery(cancellation: cancellation) { db, control in
            try db.readTransaction {
                let snapshot = try querySnapshot(for: key, db: db, control: control)
                readerBoundaryForTesting?("snapshotResolved")
                try control.check()
                let statements = try channelMatchStatements(db: db)
                let matches = try channels.map {
                    try control.check()
                    return try resolveChannel($0, generation: snapshot.generationID,
                                               statements: statements, control: control).match
                }
                return EPGCacheChannelMatchesResult(snapshotID: snapshot, matches: matches)
            }
        }
    }

    func queryNowNext(_ channels: [LiveChannel], for key: EPGRequestKey,
                      at date: Date, cancellation: EPGCacheQueryCancellation? = nil) throws -> EPGCacheNowNextResult {
        try validateQueryInput(channels)
        guard date.timeIntervalSince1970.isFinite else { throw EPGCacheQueryError.invalidRequest }
        return try performReaderQuery(cancellation: cancellation) { db, control in
            try db.readTransaction {
                    let snapshot = try querySnapshot(for: key, db: db, control: control)
                    readerBoundaryForTesting?("snapshotResolved")
                    try control.check()
                    let matchStatements = try channelMatchStatements(db: db)
                    let now = try db.statement("""
                        SELECT ordinal,channel_reference,title,start,end FROM programmes
                        WHERE generation_id=? AND channel_key=? AND start<=? AND end>?
                        ORDER BY start DESC,ordinal DESC LIMIT 1
                        """)
                    let next = try db.statement("""
                        SELECT ordinal,channel_reference,title,start,end FROM programmes
                        WHERE generation_id=? AND channel_key=? AND start>?
                        ORDER BY start ASC,ordinal ASC LIMIT 1
                        """)
                    var result: [EPGCacheNowNextEntry] = []
                    result.reserveCapacity(channels.count)
                    var resultBytes = 0
                    let timestamp = date.timeIntervalSince1970
                    for channel in channels {
                        try control.check()
                        let resolved = try resolveChannel(channel, generation: snapshot.generationID,
                                                          statements: matchStatements, control: control)
                        var current: EPGCacheProgrammeResult?, following: EPGCacheProgrammeResult?
                        if let channelKey = resolved.channelKey {
                            current = try programme(now, values: [.text(snapshot.generationID), .text(channelKey),
                                .double(timestamp), .double(timestamp)], control: control)
                            following = try programme(next, values: [.text(snapshot.generationID), .text(channelKey),
                                .double(timestamp)], control: control)
                        }
                        for programme in [current, following].compactMap({ $0 }) {
                            let bytes = programme.channelID.utf8.count + programme.title.utf8.count + 64
                            guard resultBytes <= 2 * 1_024 * 1_024 - bytes else {
                                throw EPGCacheQueryError.resultTooLarge
                            }
                            resultBytes += bytes
                        }
                        result.append(EPGCacheNowNextEntry(match: resolved.match,
                                                           current: current, next: following))
                    }
                    return EPGCacheNowNextResult(snapshotID: snapshot, entries: result)
            }
        }
    }

    func queryWindow(_ channel: LiveChannel, for key: EPGRequestKey,
                     from windowStart: Date, to windowEnd: Date,
                     limit: Int = 200, cursor: EPGCacheWindowCursor? = nil,
                     cancellation: EPGCacheQueryCancellation? = nil) throws -> EPGCacheWindowPage {
        try validateQueryInput([channel])
        let start = windowStart.timeIntervalSince1970, end = windowEnd.timeIntervalSince1970
        guard start.isFinite, end.isFinite, end > start, end - start <= 24 * 60 * 60,
              limit > 0, limit <= 500 else { throw EPGCacheQueryError.invalidRequest }
        return try performReaderQuery(cancellation: cancellation) { db, control in
            try db.readTransaction {
                let snapshot: EPGQuerySnapshotID
                do {
                    snapshot = try querySnapshot(for: key, db: db, control: control)
                } catch EPGCacheQueryError.noActiveGeneration where cursor != nil {
                    throw EPGCacheQueryError.snapshotChanged
                }
                readerBoundaryForTesting?("snapshotResolved")
                try control.check()
                if let cursor, cursor.snapshotID != snapshot { throw EPGCacheQueryError.snapshotChanged }
                let matchStatements = try channelMatchStatements(db: db)
                let resolved = try resolveChannel(channel, generation: snapshot.generationID,
                                                  statements: matchStatements, control: control)
                guard let channelKey = resolved.channelKey else {
                    guard cursor == nil else { throw EPGCacheQueryError.invalidCursor }
                    return EPGCacheWindowPage(snapshotID: snapshot, match: resolved.match,
                                              programmes: [], nextCursor: nil)
                }
                if let cursor {
                    guard cursor.version == 1, cursor.channelKey == channelKey,
                          cursor.windowStart == windowStart, cursor.windowEnd == windowEnd,
                          cursor.lastStart.timeIntervalSince1970.isFinite,
                          cursor.lastOrdinal >= 0 else { throw EPGCacheQueryError.invalidCursor }
                    let anchor = try db.statement("""
                        SELECT 1 FROM programmes WHERE generation_id=? AND channel_key=?
                          AND start=? AND ordinal=? AND start<? AND end>? LIMIT 1
                        """)
                    try anchor.bind([.text(snapshot.generationID), .text(channelKey),
                        .double(cursor.lastStart.timeIntervalSince1970), .integer(Int64(cursor.lastOrdinal)),
                        .double(end), .double(start)])
                    let exists = try anchor.step()
                    control.record(anchor)
                    try anchor.reset()
                    guard exists else { throw EPGCacheQueryError.invalidCursor }
                }
                let statement: EPGCacheStatement
                if cursor == nil {
                    statement = try db.statement("""
                        SELECT ordinal,channel_reference,title,start,end FROM programmes
                        WHERE generation_id=? AND channel_key=? AND start<? AND end>?
                        ORDER BY start ASC,ordinal ASC LIMIT ?
                        """)
                    try statement.bind([.text(snapshot.generationID), .text(channelKey),
                        .double(end), .double(start), .integer(Int64(limit + 1))])
                } else {
                    statement = try db.statement("""
                        SELECT ordinal,channel_reference,title,start,end FROM programmes
                        WHERE generation_id=? AND channel_key=? AND start<? AND end>?
                          AND (start>? OR (start=? AND ordinal>?))
                        ORDER BY start ASC,ordinal ASC LIMIT ?
                        """)
                    let cursorStart = cursor!.lastStart.timeIntervalSince1970
                    try statement.bind([.text(snapshot.generationID), .text(channelKey),
                        .double(end), .double(start), .double(cursorStart), .double(cursorStart),
                        .integer(Int64(cursor!.lastOrdinal)), .integer(Int64(limit + 1))])
                }
                defer { control.record(statement); try? statement.reset() }
                var programmes: [EPGCacheProgrammeResult] = []
                programmes.reserveCapacity(limit)
                var resultBytes = 0, hasMore = false
                while try statement.step() {
                    try control.check()
                    if programmes.count == limit { hasMore = true; break }
                    guard let channelID = statement.text(1), let title = statement.text(2) else {
                        throw EPGCacheQueryError.storeUnavailable
                    }
                    let bytes = channelID.utf8.count + title.utf8.count + 64
                    if bytes > 2 * 1_024 * 1_024 - resultBytes {
                        guard !programmes.isEmpty else { throw EPGCacheQueryError.resultTooLarge }
                        hasMore = true
                        break
                    }
                    resultBytes += bytes
                    programmes.append(EPGCacheProgrammeResult(ordinal: Int(statement.integer(0)),
                        channelID: channelID, title: title,
                        start: Date(timeIntervalSince1970: statement.number(3)),
                        end: Date(timeIntervalSince1970: statement.number(4))))
                }
                let nextCursor: EPGCacheWindowCursor?
                if hasMore, let last = programmes.last {
                    nextCursor = EPGCacheWindowCursor(version: 1, snapshotID: snapshot,
                        channelKey: channelKey, windowStart: windowStart, windowEnd: windowEnd,
                        lastStart: last.start, lastOrdinal: last.ordinal)
                } else {
                    nextCursor = nil
                }
                return EPGCacheWindowPage(snapshotID: snapshot, match: resolved.match,
                                          programmes: programmes, nextCursor: nextCursor)
            }
        }
    }

    /// One bounded GC step. Active pointer protection is independent of status.
    /// No implicit loop, foreground VACUUM, cascading mass delete, or forced checkpoint.
    @discardableResult func cleanupStep(limit: Int = 512) throws -> EPGCacheCleanupProgress {
        try queue.sync {
            guard limit > 0, limit <= 512 else { throw EPGCacheError.invalidInput }
            let db = try connection()
            let removed: EPGCacheCleanupProgress = try db.transaction {
                let candidates = """
                    SELECT g.id FROM generations g
                    WHERE NOT EXISTS(SELECT 1 FROM resources r WHERE r.active_generation=g.id)
                      AND NOT EXISTS(SELECT 1 FROM resources r JOIN sources s ON s.id=r.source_id
                        WHERE r.id=g.resource_id AND r.current_request=g.request_id
                          AND s.enabled=1 AND s.epoch=g.source_epoch AND g.state IN ('staging','validated'))
                    ORDER BY g.rowid LIMIT 1
                    """
                guard let id = try db.string(candidates) else {
                    return EPGCacheCleanupProgress(deletedProgrammes: 0, deletedAliases: 0,
                        deletedChannels: 0, removedGeneration: false, hasWorkRemaining: false)
                }
                var remaining = limit
                try db.execute("""
                    DELETE FROM programmes WHERE generation_id=? AND ordinal IN
                      (SELECT ordinal FROM programmes WHERE generation_id=? ORDER BY ordinal LIMIT ?)
                    """, [.text(id), .text(id), .integer(Int64(remaining))])
                let programmes = db.changes
                remaining -= programmes
                var aliases = 0, channels = 0
                if remaining > 0 {
                    try db.execute("""
                        DELETE FROM channel_aliases WHERE generation_id=? AND (normalized_alias,channel_key) IN
                          (SELECT normalized_alias,channel_key FROM channel_aliases
                           WHERE generation_id=? ORDER BY normalized_alias,channel_key LIMIT ?)
                        """, [.text(id), .text(id), .integer(Int64(remaining))])
                    aliases = db.changes
                    remaining -= aliases
                }
                if remaining > 0 {
                    try db.execute("""
                        DELETE FROM channels WHERE generation_id=? AND channel_key IN
                          (SELECT channel_key FROM channels WHERE generation_id=? ORDER BY channel_key LIMIT ?)
                        """, [.text(id), .text(id), .integer(Int64(remaining))])
                    channels = db.changes
                }
                let empty = try db.integer("SELECT COUNT(*) FROM programmes WHERE generation_id=?", [.text(id)]) == 0
                    && db.integer("SELECT COUNT(*) FROM channel_aliases WHERE generation_id=?", [.text(id)]) == 0
                    && db.integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(id)]) == 0
                if empty {
                    let resource = try db.string("SELECT resource_id FROM generations WHERE id=?", [.text(id)])
                    try db.execute("DELETE FROM generations WHERE id=?", [.text(id)])
                    if let resource {
                        try db.execute("""
                            DELETE FROM resources WHERE id=? AND active_generation IS NULL AND current_request IS NULL
                              AND NOT EXISTS(SELECT 1 FROM generations WHERE resource_id=resources.id)
                            """, [.text(resource)])
                    }
                }
                boundaryForTesting?("cleanupBeforeCommit")
                return EPGCacheCleanupProgress(deletedProgrammes: programmes, deletedAliases: aliases,
                    deletedChannels: channels, removedGeneration: empty,
                    hasWorkRemaining: try db.string(candidates) != nil)
            }
            try db.checkpoint()
            return removed
        }
    }

    private func performReaderQuery<T>(cancellation: EPGCacheQueryCancellation?,
                                       _ body: (EPGCacheDatabase, EPGCacheQueryControl) throws -> T) throws -> T {
        if cancellation?.isCancelled == true { throw EPGCacheQueryError.cancelled }
        try queryStateLock.withLock {
            guard !isClosing else { throw EPGCacheQueryError.storeUnavailable }
            guard queryOperationCount < 8 else { throw EPGCacheQueryError.queueFull }
            queryOperationCount += 1
        }
        defer { queryStateLock.withLock { queryOperationCount -= 1 } }
        return try readerQueue.sync {
            let control = EPGCacheQueryControl(cancellation: cancellation,
                instructionBudget: queryVMInstructionBudget,
                stepInterval: queryProgressStepInterval)
            do {
                let db: EPGCacheDatabase = try queryStateLock.withLock {
                    guard !isClosing else { throw EPGCacheQueryError.storeUnavailable }
                    activeQueryControl = control
                    return try readerConnection()
                }
                try db.installProgressHandler(stepInterval: Int32(queryProgressStepInterval)) {
                    control.progressShouldStop()
                }
                defer {
                    db.clearProgressHandler()
                    queryStateLock.withLock {
                        if activeQueryControl === control { activeQueryControl = nil }
                        lastQueryDiagnosticsValue = control.diagnostics
                    }
                }
                try control.check()
                return try body(db, control)
            } catch {
                throw queryError(error, control: control)
            }
        }
    }

    private func validateQueryInput(_ channels: [LiveChannel]) throws {
        guard !channels.isEmpty, channels.count <= 100 else { throw EPGCacheQueryError.invalidRequest }
        var bytes = 0
        for channel in channels {
            for value in [channel.name, channel.tvgID ?? "", channel.tvgName ?? ""] {
                guard value.utf8.count <= Self.maximumBatchBytes,
                      bytes <= Self.maximumBatchBytes - value.utf8.count else {
                    throw EPGCacheQueryError.invalidRequest
                }
                bytes += value.utf8.count
            }
        }
    }

    private func querySnapshot(for key: EPGRequestKey, db: EPGCacheDatabase,
                               control: EPGCacheQueryControl) throws -> EPGQuerySnapshotID {
        let resource = try resourceKey(key)
        let query = try db.statement("""
            SELECT r.id,s.epoch,g.id FROM resources r
            JOIN sources s ON s.id=r.source_id AND s.enabled=1
            JOIN generations g ON g.id=r.active_generation AND g.resource_id=r.id
              AND g.source_epoch=s.epoch AND g.normalization_version=?
            WHERE r.id=?
            """)
        defer { control.record(query) }
        try query.bind([.integer(Int64(Self.normalizationVersion)), .text(resource)])
        guard try query.step(), let resourceID = query.text(0),
              let epoch = query.text(1), let generation = query.text(2) else {
            throw EPGCacheQueryError.noActiveGeneration
        }
        return EPGQuerySnapshotID(storeIncarnation: incarnation, resourceKey: resourceID,
                                  sourceEpoch: epoch, generationID: generation)
    }

    private func channelMatchStatements(db: EPGCacheDatabase) throws -> EPGCacheChannelMatchStatements {
        EPGCacheChannelMatchStatements(
            exact: try db.statement("""
                SELECT 1 FROM channels WHERE generation_id=? AND channel_key=? LIMIT 1
                """),
            alias: try db.statement("""
                SELECT channel_key FROM channel_aliases
                WHERE generation_id=? AND normalized_alias=? ORDER BY channel_key LIMIT 2
                """),
            rawID: try db.statement("""
                SELECT raw_channel_id FROM channels WHERE generation_id=? AND channel_key=? LIMIT 1
                """)
        )
    }

    private func resolveChannel(_ channel: LiveChannel, generation: String,
                                statements: EPGCacheChannelMatchStatements,
                                control: EPGCacheQueryControl) throws -> EPGCacheResolvedChannel {
        if let id = channel.tvgID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let key = XMLTVChannelNormalization.exactIDKey(id)
            try statements.exact.bind([.text(generation), .text(key)])
            let exists = try statements.exact.step()
            control.record(statements.exact)
            try statements.exact.reset()
            return EPGCacheResolvedChannel(
                match: EPGChannelMatch(kind: exists ? .exact : .unmatched,
                                       channelID: exists ? id : nil),
                channelKey: exists ? key : nil
            )
        }

        var candidates = Set<String>()
        for value in [channel.name, channel.tvgName ?? ""] {
            for alias in XMLTVChannelNormalization.nameVariants(value) {
                try statements.alias.bind([.text(generation), .text(alias)])
                while candidates.count < 2, try statements.alias.step() {
                    if let key = statements.alias.text(0) { candidates.insert(key) }
                }
                control.record(statements.alias)
                try statements.alias.reset()
                if candidates.count > 1 { break }
            }
            if candidates.count > 1 { break }
        }
        guard candidates.count == 1, let key = candidates.first else {
            return EPGCacheResolvedChannel(
                match: EPGChannelMatch(kind: candidates.count > 1 ? .ambiguous : .unmatched,
                                       channelID: nil),
                channelKey: nil
            )
        }
        try statements.rawID.bind([.text(generation), .text(key)])
        let found = try statements.rawID.step()
        let rawID = found ? statements.rawID.text(0) : nil
        control.record(statements.rawID)
        try statements.rawID.reset()
        guard let rawID else { throw EPGCacheQueryError.storeUnavailable }
        return EPGCacheResolvedChannel(match: EPGChannelMatch(kind: .normalizedUnique, channelID: rawID),
                                       channelKey: key)
    }

    private func programme(_ statement: EPGCacheStatement,
                           values: [SQLiteBinding], control: EPGCacheQueryControl) throws -> EPGCacheProgrammeResult? {
        try statement.bind(values)
        defer { control.record(statement); try? statement.reset() }
        guard try statement.step() else { return nil }
        guard let channelID = statement.text(1), let title = statement.text(2) else {
            throw EPGCacheQueryError.storeUnavailable
        }
        let result = EPGCacheProgrammeResult(ordinal: Int(statement.integer(0)), channelID: channelID,
            title: title, start: Date(timeIntervalSince1970: statement.number(3)),
            end: Date(timeIntervalSince1970: statement.number(4)))
        return result
    }

    private func queryError(_ error: Error, control: EPGCacheQueryControl? = nil) -> EPGCacheQueryError {
        if let error = error as? EPGCacheQueryError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? EPGCacheError else { return .storeUnavailable }
        switch error {
        case .invalidInput: return .invalidRequest
        case .closed: return .storeUnavailable
        case .sqlite(let code):
            if code & 0xff == SQLITE_INTERRUPT, let reason = control?.reason { return reason.queryError }
            return .sqlite(code)
        default: return .storeUnavailable
        }
    }

    private func connection() throws -> EPGCacheDatabase {
        guard let database else { throw EPGCacheError.closed }
        return database
    }
    private func readerConnection() throws -> EPGCacheDatabase {
        guard let readerDatabase else { throw EPGCacheError.closed }
        return readerDatabase
    }
    private func checkMetadataCapacity(table: String, id: String, db: EPGCacheDatabase) throws {
        // table is an internal literal, never provider input. Keep source
        // tombstones so a deleted/recreated source cannot regain an old epoch.
        guard try db.integer("SELECT COUNT(*) FROM \(table) WHERE id=?", [.text(id)]) > 0
            || db.integer("SELECT COUNT(*) FROM \(table)") < 128 else { throw EPGCacheError.budgetExceeded }
    }
    private func checkHandle(_ handle: EPGCacheImportHandle) throws {
        guard handle.incarnation == incarnation else { throw EPGCacheError.invalidHandle }
    }
    private func eligible(_ handle: EPGCacheImportHandle, state: String, db: EPGCacheDatabase) throws {
        guard !queryStateLock.withLock({ isClosing }) else { throw EPGCacheError.closed }
        try checkHandle(handle)
        let query = try db.statement("""
            SELECT g.state FROM generations g JOIN resources r ON r.id=g.resource_id
            JOIN sources s ON s.id=r.source_id
            WHERE g.id=? AND r.id=? AND s.id=? AND s.epoch=? AND s.enabled=1
              AND r.current_request=? AND g.request_id=r.current_request AND g.source_epoch=s.epoch
            """)
        try query.bind([.text(handle.generation), .text(handle.resource), .text(handle.source),
                        .text(handle.epoch), .text(handle.request)])
        guard try query.step() else { throw EPGCacheError.superseded }
        guard query.text(0) == state else { throw EPGCacheError.invalidState }
    }

    private func prepareChannels(_ channels: [EPGChannel]) throws -> [EPGCachePreparedChannel] {
        var prepared: [String: EPGCachePreparedChannel] = [:]
        var inputBytes = 0
        for channel in channels {
            guard !channel.id.isEmpty, !channel.displayName.isEmpty else { throw EPGCacheError.invalidInput }
            let values = [channel.id, channel.displayName] + (channel.aliases ?? [])
            for value in values {
                guard value.utf8.count <= Self.maximumBatchBytes,
                      inputBytes <= Self.maximumBatchBytes - value.utf8.count else {
                    throw EPGCacheError.budgetExceeded
                }
                inputBytes += value.utf8.count
            }
            let key = XMLTVChannelNormalization.exactIDKey(channel.id)
            guard !key.isEmpty else { throw EPGCacheError.invalidInput }
            var item = prepared[key] ?? EPGCachePreparedChannel(key: key, rawID: channel.id, aliases: [])
            for value in values {
                item.aliases.formUnion(XMLTVChannelNormalization.nameVariants(value))
            }
            prepared[key] = item
        }
        var normalizedBytes = 0
        for item in prepared.values {
            let channelBytes = item.key.utf8.count + item.rawID.utf8.count + 32
            guard channelBytes <= Self.maximumBatchBytes,
                  normalizedBytes <= Self.maximumBatchBytes - channelBytes else {
                throw EPGCacheError.budgetExceeded
            }
            normalizedBytes += channelBytes
            for alias in item.aliases {
                let aliasBytes = alias.utf8.count + item.key.utf8.count + 32
                guard aliasBytes <= Self.maximumBatchBytes,
                      normalizedBytes <= Self.maximumBatchBytes - aliasBytes else {
                    throw EPGCacheError.budgetExceeded
                }
                normalizedBytes += aliasBytes
            }
        }
        return Array(prepared.values)
    }

    private func upsertKnownChannels(_ channels: [EPGCachePreparedChannel], channelRecordDelta: Int,
                                     generation: String, db: EPGCacheDatabase) throws {
        let insertChannel = try db.statement("""
            INSERT OR IGNORE INTO channels(generation_id,channel_key,raw_channel_id) VALUES(?,?,?)
            """)
        let insertAlias = try db.statement("""
            INSERT OR IGNORE INTO channel_aliases(generation_id,normalized_alias,channel_key) VALUES(?,?,?)
            """)
        var channelDelta = 0, aliasDelta = 0, byteDelta = 0
        for channel in channels {
            try insertChannel.bind([.text(generation), .text(channel.key), .text(channel.rawID)])
            _ = try insertChannel.step()
            if db.changes == 1 {
                channelDelta += 1
                byteDelta += channel.key.utf8.count + channel.rawID.utf8.count + 32
            }
            try insertChannel.reset()
            for alias in channel.aliases {
                try insertAlias.bind([.text(generation), .text(alias), .text(channel.key)])
                _ = try insertAlias.step()
                if db.changes == 1 {
                    aliasDelta += 1
                    byteDelta += alias.utf8.count + channel.key.utf8.count + 32
                }
                try insertAlias.reset()
            }
        }
        let totals = try db.statement("""
            SELECT channel_count,alias_count,metadata_bytes,channel_records
            FROM generations WHERE id=?
            """)
        try totals.bind([.text(generation)])
        guard try totals.step(),
              totals.integer(0) + Int64(channelDelta) <= Self.maximumKnownChannels,
              totals.integer(1) + Int64(aliasDelta) <= Self.maximumAliases,
              totals.integer(2) + Int64(byteDelta) <= Self.maximumMetadataBytes,
              totals.integer(3) + Int64(channelRecordDelta) <= Self.maximumKnownChannels else {
            throw EPGCacheError.budgetExceeded
        }
        try db.execute("""
            UPDATE generations SET channel_count=channel_count+?,alias_count=alias_count+?,
              metadata_bytes=metadata_bytes+?,channel_records=channel_records+? WHERE id=?
            """, [.integer(Int64(channelDelta)), .integer(Int64(aliasDelta)), .integer(Int64(byteDelta)),
                  .integer(Int64(channelRecordDelta)), .text(generation)])
    }

    private func sourceKey(_ source: EPGSourceKey) -> String { source.kind.rawValue + ":" + source.id.uuidString.lowercased() }
    private func resourceKey(_ key: EPGRequestKey) throws -> String {
        guard key.source.kind == .imported, key.resource == "xmltv", key.revision.utf8.count == 64,
              key.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EPGCacheError.invalidInput
        }
        return sourceKey(key.source) + ":" + key.revision + ":xmltv"
    }

    private func acquireDirectory() throws {
        guard directory.isFileURL, directory.path == directory.resolvingSymlinksInPath().path,
              directory.path != "/", directory.lastPathComponent.hasPrefix("EPGCache-") else {
            throw EPGCacheError.unsafeDirectory
        }
        var rootInfo = stat()
        if lstat(directory.path, &rootInfo) != 0 {
            guard errno == ENOENT else { throw EPGCacheError.io(errno) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &rootInfo) == 0 else { throw EPGCacheError.io(errno) }
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else {
            throw EPGCacheError.unsafeDirectory
        }
        for name in ["owner.lock", "EPGCache.sqlite", "EPGCache.sqlite-wal", "EPGCache.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else {
                    throw EPGCacheError.unsafeDirectory
                }
            } else if errno != ENOENT { throw EPGCacheError.io(errno) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        lockFD = open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw EPGCacheError.io(errno) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw EPGCacheError.alreadyOpen }
    }

    private func openCache() throws {
        do { try configureCache() }
        catch {
            database?.close(); database = nil
            // Busy/full/IO/permissions and newer versions never trigger deletion.
            let rebuild: Bool
            switch error {
            case EPGCacheError.sqlite(let code): rebuild = (code & 0xff) == SQLITE_CORRUPT || (code & 0xff) == SQLITE_NOTADB
            case EPGCacheError.incompatibleVersion(let version): rebuild = version < Self.schemaVersion
            case EPGCacheError.validationFailed: rebuild = true
            default: rebuild = false
            }
            guard rebuild else { throw error }
            // Only exact owned cache files; owner.lock remains held throughout.
            for name in ["EPGCache.sqlite-wal", "EPGCache.sqlite-shm", "EPGCache.sqlite"] {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            rebuiltOnOpen = true
            try configureCache() // one attempt; never a destructive retry loop
        }
    }

    private func openReader() throws {
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"),
                                      access: .existingReadWrite)
        do {
            try db.execute("PRAGMA query_only=ON")
            guard try db.integer("PRAGMA query_only") == 1 else {
                throw EPGCacheError.validationFailed
            }
            try db.execute("PRAGMA foreign_keys=ON")
            try db.execute("PRAGMA cache_size=-2048")
            try db.execute("PRAGMA mmap_size=0")
            readerDatabase = db
        } catch {
            db.close()
            throw error
        }
    }

    private func configureCache() throws {
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"))
        database = db
        let app = try db.integer("PRAGMA application_id"), version = try db.integer("PRAGMA user_version")
        let tables = try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        guard app == Self.applicationID || (app == 0 && version == 0 && tables == 0) else {
            throw EPGCacheError.foreignDatabase
        }
        guard version <= Self.schemaVersion else { throw EPGCacheError.incompatibleVersion(Int(version)) }
        if app == Self.applicationID, version != Self.schemaVersion { throw EPGCacheError.incompatibleVersion(Int(version)) }
        guard try db.string("PRAGMA quick_check(1)") == "ok" else { throw EPGCacheError.validationFailed }
        guard try db.string("PRAGMA journal_mode=WAL") == "wal" else { throw EPGCacheError.validationFailed }
        try db.execute("PRAGMA synchronous=NORMAL")
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("PRAGMA cache_size=-2048")
        try db.execute("PRAGMA mmap_size=0")
        try db.execute("PRAGMA wal_autocheckpoint=256")
        let pageSize = try db.integer("PRAGMA page_size")
        try db.execute("PRAGMA max_page_count=\(Int64(maximumDatabaseBytes) / pageSize)")
        if app == 0 {
            try db.transaction {
                try db.execute("CREATE TABLE sources(id TEXT PRIMARY KEY,epoch TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN(0,1)))")
                try db.execute("""
                    CREATE TABLE resources(id TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES sources(id),
                      current_request TEXT,active_generation TEXT REFERENCES generations(id))
                    """)
                try db.execute("""
                    CREATE TABLE generations(id TEXT PRIMARY KEY,resource_id TEXT NOT NULL REFERENCES resources(id),
                      source_epoch TEXT NOT NULL,request_id TEXT NOT NULL,
                      state TEXT NOT NULL CHECK(state IN('staging','validated','active','retired','abandoned')),
                      normalization_version INTEGER NOT NULL,count INTEGER NOT NULL DEFAULT 0,
                      field_bytes INTEGER NOT NULL DEFAULT 0,last_ordinal INTEGER NOT NULL DEFAULT -1,
                      channel_records INTEGER NOT NULL DEFAULT 0,channel_count INTEGER NOT NULL DEFAULT 0,
                      alias_count INTEGER NOT NULL DEFAULT 0,metadata_bytes INTEGER NOT NULL DEFAULT 0,
                      raw_count INTEGER,min_start REAL,max_end REAL,published_at REAL)
                    """)
                try db.execute("""
                    CREATE TABLE channels(generation_id TEXT NOT NULL REFERENCES generations(id),
                      channel_key TEXT NOT NULL,raw_channel_id TEXT NOT NULL,
                      PRIMARY KEY(generation_id,channel_key)) WITHOUT ROWID
                    """)
                try db.execute("""
                    CREATE TABLE channel_aliases(generation_id TEXT NOT NULL,normalized_alias TEXT NOT NULL,
                      channel_key TEXT NOT NULL,
                      PRIMARY KEY(generation_id,normalized_alias,channel_key),
                      FOREIGN KEY(generation_id,channel_key) REFERENCES channels(generation_id,channel_key)) WITHOUT ROWID
                    """)
                try db.execute("""
                    CREATE TABLE programmes(generation_id TEXT NOT NULL REFERENCES generations(id),
                      ordinal INTEGER NOT NULL,channel_reference TEXT NOT NULL,channel_key TEXT NOT NULL,start REAL NOT NULL,
                      end REAL NOT NULL CHECK(end>start),title TEXT NOT NULL,
                      PRIMARY KEY(generation_id,ordinal),
                      FOREIGN KEY(generation_id,channel_key) REFERENCES channels(generation_id,channel_key)) WITHOUT ROWID
                    """)
                try db.execute("CREATE INDEX programme_time ON programmes(generation_id,channel_key,start,ordinal)")
                try db.execute("PRAGMA application_id=\(Self.applicationID)")
                try db.execute("PRAGMA user_version=\(Self.schemaVersion)")
            }
        }
        guard try db.string("PRAGMA foreign_key_check") == nil else { throw EPGCacheError.validationFailed }
        guard try db.integer("""
            SELECT COUNT(*) FROM resources r JOIN generations g ON g.id=r.active_generation
            JOIN sources s ON s.id=r.source_id WHERE g.resource_id<>r.id OR g.source_epoch<>s.epoch
              OR s.enabled<>1 OR g.raw_count IS NULL OR g.published_at IS NULL OR g.normalization_version<>1
            """) == 0 else { throw EPGCacheError.validationFailed }
        try db.transaction {
            try db.execute("UPDATE resources SET current_request=NULL")
            try db.execute("""
                UPDATE generations SET state=CASE WHEN EXISTS
                  (SELECT 1 FROM resources r WHERE r.active_generation=generations.id)
                  THEN 'active' ELSE 'abandoned' END
                """)
        }
        for name in ["EPGCache.sqlite", "EPGCache.sqlite-wal", "EPGCache.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    private func checkDiskBudget() throws {
        var total: Int64 = 0
        for name in ["EPGCache.sqlite", "EPGCache.sqlite-wal", "EPGCache.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0 { total += info.st_size }
            else if errno != ENOENT { throw EPGCacheError.io(errno) }
        }
        guard total < Self.diskBudget else { throw EPGCacheError.budgetExceeded }
    }
}
