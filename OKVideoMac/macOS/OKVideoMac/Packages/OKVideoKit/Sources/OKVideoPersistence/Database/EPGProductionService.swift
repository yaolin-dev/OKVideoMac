import Darwin
import Foundation
@_spi(XMLTVStreaming) import OKVideoCore

public enum EPGProductionServiceError: Error, Equatable, Sendable {
    case paused
    case closed
    case noActiveData
    case cancelled
    case busy
    case invalidRequest
    case snapshotChanged
    case queryBudgetExceeded
    case unavailable
    case resultTooLarge
}

public struct EPGMaintenanceResult: Equatable, Sendable {
    public let steps: Int
    public let hasWorkRemaining: Bool
    public let elapsed: TimeInterval

    public init(steps: Int, hasWorkRemaining: Bool, elapsed: TimeInterval) {
        self.steps = steps
        self.hasWorkRemaining = hasWorkRemaining
        self.elapsed = elapsed
    }
}

/// Session-only cursor. Its database snapshot identity is retained inside this
/// module and is always revalidated by EPGCacheStore before a following page.
public struct EPGProductionWindowCursor: Sendable {
    public let token: EPGResultToken
    fileprivate let storage: EPGCacheWindowCursor
}

public struct EPGProductionWindowResult: Sendable {
    public let page: EPGWindowPage
    public let nextCursor: EPGProductionWindowCursor?
}

private final class EPGDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ value: CheckedContinuation<Bool, Never>) {
        let immediate: Bool? = lock.withLock {
            if let result { return result }
            continuation = value
            return nil
        }
        if let immediate { value.resume(returning: immediate) }
    }

    func finish(_ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: value)
    }
}

/// Production owner for one persistent EPG cache. Full guides remain inside
/// the SQLite/import boundary; public methods only return bounded metadata,
/// Now/Next rows, or a finite window page.
public actor EPGProductionService {
    private enum Lifecycle { case accepting, paused, closing, closed }
    private struct Components {
        let store: EPGCacheStore
        let coordinator: EPGImportCoordinator
        let stagingRootPath: String
    }

    public nonisolated let incarnation: UUID
    private let store: EPGCacheStore
    private let coordinator: EPGImportCoordinator
    private let stagingRootPath: String
    private let queryQueue = DispatchQueue(label: "com.okvideomac.epg.production.query", qos: .utility)
    // Queries use the Store's WAL reader and must not sit behind a complete
    // cleanup burst. The Store still serializes each write transaction itself.
    private let maintenanceQueue = DispatchQueue(label: "com.okvideomac.epg.production.maintenance", qos: .utility)
    private var lifecycle: Lifecycle = .accepting
    private var pauseDrain: Task<Void, Never>?
    private var closeDrain: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceID: UUID?
    private var maintenanceRevision: UInt64 = 0

    public init(cacheDirectory: URL, incarnation: UUID = UUID()) throws {
        let components = try Self.makeComponents(cacheDirectory: cacheDirectory)
        self.incarnation = incarnation
        store = components.store
        coordinator = components.coordinator
        stagingRootPath = components.stagingRootPath
        Task { [weak self] in await self?.requestMaintenance() }
    }

    /// Internal measurement seam. It changes only observation and the private
    /// staging root; the production importer, downloader and Store are exact.
    init(cacheDirectory: URL, incarnation: UUID = UUID(),
         stagingRootPathForTesting: String,
         temporaryByteObserverForTesting: ((Int64) -> Void)? = nil,
         phaseObserverForTesting: ((String) -> Void)? = nil) throws {
        let components = try Self.makeComponents(cacheDirectory: cacheDirectory,
            stagingRootPath: stagingRootPathForTesting,
            temporaryByteObserver: temporaryByteObserverForTesting,
            phaseObserver: phaseObserverForTesting)
        self.incarnation = incarnation
        store = components.store
        coordinator = components.coordinator
        stagingRootPath = components.stagingRootPath
        Task { [weak self] in await self?.requestMaintenance() }
    }

    deinit { maintenanceTask?.cancel() }

    /// One short slice per wake; stop completely when there is no work. A new
    /// request arriving during a slice must not be lost when that slice finishes.
    public func requestMaintenance() {
        guard lifecycle == .accepting else { return }
        maintenanceRevision &+= 1
        guard maintenanceID == nil else { return }
        let id = UUID()
        maintenanceID = id
        scheduleMaintenance(id)
    }

    private func scheduleMaintenance(_ id: UUID) {
        maintenanceTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
            await self?.runMaintenance(id)
        }
    }

    private func runMaintenance(_ id: UUID) async {
        guard maintenanceID == id, lifecycle == .accepting, !Task.isCancelled else { return }
        let revision = maintenanceRevision
        let result = try? await performMaintenance()
        guard maintenanceID == id, lifecycle == .accepting, !Task.isCancelled else { return }
        if result?.hasWorkRemaining == true || revision != maintenanceRevision {
            scheduleMaintenance(id)
        } else {
            // Errors do not create a busy retry loop. Startup, resume, source
            // changes and every import completion will request another pass.
            maintenanceTask = nil
            maintenanceID = nil
        }
    }

    private func stopMaintenance() {
        maintenanceID = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    private static func makeComponents(cacheDirectory: URL,
                                       stagingRootPath: String? = nil,
                                       temporaryByteObserver: ((Int64) -> Void)? = nil,
                                       phaseObserver: ((String) -> Void)? = nil) throws -> Components {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let root = stagingRootPath ?? ("/private/tmp/OKVideoMac-9B." + suffix)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let store = try EPGCacheStore(directory: cacheDirectory)
            return Components(store: store, coordinator: EPGImportCoordinator(
                store: store,
                downloader: XMLTVDownloader(stagingRootPath: root,
                    temporaryByteObserver: temporaryByteObserver),
                phaseObserver: phaseObserver
            ), stagingRootPath: root)
        } catch {
            _ = root.withCString { rmdir($0) }
            throw error
        }
    }

    public func activeSummary(for key: EPGRequestKey) async throws -> EPGResourceSummary? {
        try requireReadable()
        let store = store
        let record = try await performQuery { try store.activeRecord(for: key) }
        return record.map { summary($0, key: key) }
    }

    public func refreshXMLTV(key: EPGRequestKey, url: URL, headers: HTTPHeaders = [:],
                             force: Bool = false) async throws -> EPGResourceSummary {
        try requireAccepting()
        defer { requestMaintenance() }
        do {
            _ = try await coordinator.load(key: key,
                request: XMLTVDownloadRequest(url: url, headers: headers), force: force)
            guard let value = try await activeSummary(for: key) else {
                throw EPGProductionServiceError.noActiveData
            }
            return value
        } catch {
            throw map(error)
        }
    }

    public func queryNowNext(_ channels: [LiveChannel], for key: EPGRequestKey,
                             at date: Date, demandRevision: UUID) async throws -> EPGNowNextBatch {
        try requireReadable()
        let cancellation = EPGCacheQueryCancellation()
        let store = store
        let result: EPGCacheNowNextResult
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await performQuery {
                    try store.queryNowNext(channels, for: key, at: date, cancellation: cancellation)
                }
            }, onCancel: { cancellation.cancel() })
        } catch { throw map(error) }
        let token = resultToken(result.snapshotID, demandRevision: demandRevision)
        let items = result.entries.map {
            EPGNowNextItem(match: $0.match, current: programme($0.current), next: programme($0.next))
        }
        return EPGNowNextBatch(token: token, items: items)
    }

    public func queryWindow(_ channel: LiveChannel, for key: EPGRequestKey,
                            from start: Date, to end: Date, limit: Int = 200,
                            cursor: EPGProductionWindowCursor? = nil,
                            demandRevision: UUID) async throws -> EPGProductionWindowResult {
        try requireReadable()
        if let cursor {
            guard cursor.token.serviceIncarnation == incarnation,
                  cursor.token.demandRevision == demandRevision else {
                throw EPGProductionServiceError.invalidRequest
            }
        }
        let cancellation = EPGCacheQueryCancellation()
        let store = store
        let result: EPGCacheWindowPage
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await performQuery {
                    try store.queryWindow(channel, for: key, from: start, to: end,
                        limit: limit, cursor: cursor?.storage, cancellation: cancellation)
                }
            }, onCancel: { cancellation.cancel() })
        } catch { throw map(error) }
        let token = resultToken(result.snapshotID, demandRevision: demandRevision)
        let records = result.programmes.compactMap { value -> EPGWindowProgramme? in
            guard let programme = programme(value) else { return nil }
            return EPGWindowProgramme(id: EPGProgrammeRecordIdentity(
                kind: .xmltv, resourceIdentity: token.resourceIdentity,
                sourceEpoch: token.sourceEpoch, dataVersion: token.dataVersion,
                ordinal: value.ordinal), programme: programme)
        }
        let page = EPGWindowPage(token: token, match: result.match,
                                 records: records, hasMore: result.nextCursor != nil)
        return EPGProductionWindowResult(page: page,
            nextCursor: result.nextCursor.map { EPGProductionWindowCursor(token: token, storage: $0) })
    }

    public func setSourceEnabled(_ source: EPGSourceKey, enabled: Bool) async throws {
        try requireAccepting()
        defer { requestMaintenance() }
        do { try await coordinator.setSourceEnabled(source, enabled: enabled) }
        catch { throw map(error) }
    }

    /// Reversible pause. False means the deadline elapsed; ownership remains
    /// alive and draining, so callers must not construct a competing service.
    public func pause(deadlineNanoseconds: UInt64 = 750_000_000) async -> Bool {
        guard lifecycle == .accepting else { return lifecycle == .paused && pauseDrain == nil }
        lifecycle = .paused
        stopMaintenance()
        let task = Task { await coordinator.pause() }
        pauseDrain = task
        let completed = await wait(task, deadlineNanoseconds: deadlineNanoseconds)
        if completed { pauseDrain = nil }
        return completed
    }

    public func resume() async throws {
        try Task.checkCancellation()
        guard lifecycle == .paused else {
            if lifecycle == .accepting { return }
            throw EPGProductionServiceError.closed
        }
        if let pauseDrain { await pauseDrain.value; self.pauseDrain = nil }
        // A wake task can be revoked by a newer sleep while the old import is
        // still draining. Never let that late waiter reopen the pipeline.
        try Task.checkCancellation()
        guard lifecycle == .paused else { throw EPGProductionServiceError.closed }
        await coordinator.resume()
        lifecycle = .accepting
        requestMaintenance()
    }

    public func performMaintenance(maximumSteps: Int = 4,
                                   maximumDuration: TimeInterval = 0.020) async throws -> EPGMaintenanceResult {
        try requireReadable()
        guard maximumSteps > 0, maximumSteps <= 32,
              maximumDuration > 0, maximumDuration <= 0.250 else {
            throw EPGProductionServiceError.invalidRequest
        }
        do {
            let store = store
            return try await performQuery(on: maintenanceQueue) {
                let started = ProcessInfo.processInfo.systemUptime
                var steps = 0, remaining = true
                while steps < maximumSteps,
                      ProcessInfo.processInfo.systemUptime - started < maximumDuration {
                    remaining = try store.cleanupStep().hasWorkRemaining
                    steps += 1
                    if !remaining { break }
                }
                return EPGMaintenanceResult(steps: steps, hasWorkRemaining: remaining,
                    elapsed: ProcessInfo.processInfo.systemUptime - started)
            }
        } catch { throw map(error) }
    }

    /// Terminal close. A timeout does not close a Store still used by the
    /// importer; the detached drain retains ownership and completes safely.
    public func close(deadlineNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        if lifecycle == .closed { return true }
        lifecycle = .closing
        stopMaintenance()
        let task: Task<Void, Never>
        if let closeDrain { task = closeDrain }
        else {
            let coordinator = coordinator, store = store, root = stagingRootPath
            task = Task.detached(priority: .utility) {
                await coordinator.close()
                store.close()
                _ = root.withCString { rmdir($0) }
            }
            closeDrain = task
        }
        let completed = await wait(task, deadlineNanoseconds: deadlineNanoseconds)
        if completed {
            closeDrain = nil
            lifecycle = .closed
        }
        return completed
    }

    private func requireAccepting() throws {
        switch lifecycle {
        case .accepting: return
        case .paused: throw EPGProductionServiceError.paused
        case .closing, .closed: throw EPGProductionServiceError.closed
        }
    }

    private func requireReadable() throws {
        switch lifecycle {
        case .accepting, .paused: return
        case .closing, .closed: throw EPGProductionServiceError.closed
        }
    }

    private func performQuery<T>(on queue: DispatchQueue? = nil,
                                 _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            (queue ?? queryQueue).async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private func wait(_ task: Task<Void, Never>, deadlineNanoseconds: UInt64) async -> Bool {
        if deadlineNanoseconds == 0 { return false }
        let gate = EPGDeadlineGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task.detached { await task.value; gate.finish(true) }
            Task.detached {
                try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                gate.finish(false)
            }
        }
    }

    private func summary(_ record: EPGCacheActiveRecord, key: EPGRequestKey) -> EPGResourceSummary {
        EPGResourceSummary(key: key, resourceIdentity: record.resourceKey,
            sourceEpoch: record.sourceEpoch, dataVersion: record.identity.generation,
            programmeCount: record.identity.programmeCount, publishedAt: record.publishedAt,
            coverageStart: record.minimumStart, coverageEnd: record.maximumEnd)
    }

    private func resultToken(_ snapshot: EPGQuerySnapshotID, demandRevision: UUID) -> EPGResultToken {
        EPGResultToken(serviceIncarnation: incarnation, resourceIdentity: snapshot.resourceKey,
            sourceEpoch: snapshot.sourceEpoch, dataVersion: snapshot.generationID,
            demandRevision: demandRevision)
    }

    private func programme(_ value: EPGCacheProgrammeResult?) -> EPGProgramme? {
        value.map { EPGProgramme(channelID: $0.channelID, title: $0.title, start: $0.start, end: $0.end) }
    }

    private func map(_ error: Error) -> EPGProductionServiceError {
        if error is CancellationError || (error as? EPGImportStop) == .cancelled {
            return .cancelled
        }
        if let admission = error as? EPGImportAdmissionError {
            switch admission {
            case .paused: return .paused
            case .closed: return .closed
            case .queueFull: return .busy
            }
        }
        if let query = error as? EPGCacheQueryError {
            switch query {
            case .noActiveGeneration: return .noActiveData
            case .cancelled: return .cancelled
            case .queueFull: return .busy
            case .invalidRequest, .invalidCursor: return .invalidRequest
            case .snapshotChanged: return .snapshotChanged
            case .resultTooLarge: return .resultTooLarge
            case .queryBudgetExceeded: return .queryBudgetExceeded
            case .storeUnavailable, .sqlite: return .unavailable
            }
        }
        return .unavailable
    }
}
