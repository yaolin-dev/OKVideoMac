import CryptoKit
import Foundation
import OKVideoCore

/// Production EPG facade. XMLTV is resource-scoped and persisted by the 9C.3
/// service; Xtream short EPG remains a separately bounded, channel-scoped cache.
public actor EPGProductionRepository {
    private struct FailureState {
        var count: Int
        var retryAt: Date
    }
    private struct XtreamKey: Hashable {
        let source: EPGSourceKey
        let revision: String
        let requestRevision: String
        let account: String
        let server: String
        let streamID: String
        var day: String? = nil
        var archive = false
    }
    private struct XtreamEntry {
        let key: EPGRequestKey
        let version: String
        let publishedAt: Date
        let expiresAt: Date
        var availability: EPGAvailability
        let programmes: [EPGProgramme]
        let byteCost: Int
        var accessedAt: Date
    }
    private struct XtreamFlight {
        let id: UUID
        let task: Task<XtreamEntry, Error>
    }

    public nonisolated let incarnation: UUID
    private let service: EPGProductionService?
    private let now: @Sendable () -> Date
    private var failures: [EPGRequestKey: FailureState] = [:]
    private var xtreamEntries: [XtreamKey: XtreamEntry] = [:]
    private var xtreamFlights: [XtreamKey: XtreamFlight] = [:]
    private struct CoverageRetry {
        let end: Date
        let count: Int
        let retryAt: Date
    }
    private var coverageRetries: [EPGRequestKey: CoverageRetry] = [:]
    private var xmltvFlights: [EPGRequestKey: Task<EPGRepositoryStatus, Error>] = [:]
    private var channelFailures: [XtreamKey: FailureState] = [:]
    private var manualRefreshIDs: [XtreamKey: UUID] = [:]
    private var paused = false
    private var closed = false
    private var terminalCloseComplete = false

    private static let xmltvTTL: TimeInterval = 6 * 3600
    private static let emptyTTL: TimeInterval = 15 * 60
    private static let unsupportedTTL: TimeInterval = 3600
    private static let coverageLead: TimeInterval = 30 * 60
    private static let xtreamTTL: TimeInterval = 5 * 60
    private static let maximumXtreamEntries = 128
    private static let maximumXtreamCacheBytes = 2 * 1_024 * 1_024
    private static let maximumXtreamEntryBytes = 64 * 1_024
    private static let maximumXtreamProgrammes = 16
    private static let maximumXtreamTitleBytes = 4 * 1_024
    private static let maximumXtreamIdentifierBytes = 512

    public init(cacheDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        let identity = UUID()
        incarnation = identity
        service = try? EPGProductionService(cacheDirectory: cacheDirectory, incarnation: identity)
        self.now = now
    }

    init(service: EPGProductionService,
         now: @escaping @Sendable () -> Date = { Date() }) {
        incarnation = service.incarnation
        self.service = service
        self.now = now
    }

    public var isAvailable: Bool { service != nil && !closed }

    public func status(for key: EPGRequestKey) async -> EPGRepositoryStatus {
        let date = now()
        guard !closed, key.source.kind == .imported, key.resource == "xmltv", let service else {
            return failedStatus(key, at: date)
        }
        let summary = try? await service.activeSummary(for: key)
        return status(key: key, summary: summary ?? nil, at: date)
    }

    public func refreshXMLTV(key: EPGRequestKey, url: URL, headers: HTTPHeaders = [:],
                             force: Bool = false) async throws -> EPGRepositoryStatus {
        guard !closed else { throw EPGProductionServiceError.closed }
        guard !paused else { throw EPGProductionServiceError.paused }
        guard key.source.kind == .imported, key.resource == "xmltv", let service else {
            throw EPGProductionServiceError.unavailable
        }
        if let flight = xmltvFlights[key] { return try await flight.value }
        let existing = await status(for: key)
        // status() crosses an actor boundary; another caller may have started work.
        if let flight = xmltvFlights[key] { return try await flight.value }
        guard !closed, !paused else { throw EPGProductionServiceError.paused }
        if !force, existing.nextRetryAt > now(),
           existing.summary != nil || existing.consecutiveFailures > 0 { return existing }
        let flight = Task { try await self.performXMLTVRefresh(key: key, url: url, headers: headers, service: service) }
        xmltvFlights[key] = flight
        defer { xmltvFlights[key] = nil }
        return try await flight.value
    }

    private func performXMLTVRefresh(key: EPGRequestKey, url: URL, headers: HTTPHeaders,
                                     service: EPGProductionService) async throws -> EPGRepositoryStatus {
        do {
            try await service.setSourceEnabled(key.source, enabled: true)
            // Force bypasses freshness, never cancels a shared download/import.
            let summary = try await service.refreshXMLTV(key: key, url: url, headers: headers)
            try Task.checkCancellation()
            failures[key] = nil
            let date = now()
            if let end = summary.coverageEnd, end <= date.addingTimeInterval(Self.coverageLead) {
                let previous = coverageRetries[key]
                let count = previous.map { end <= $0.end ? min(3, $0.count + 1) : 1 } ?? 1
                coverageRetries[key] = CoverageRetry(end: end, count: count,
                    retryAt: date.addingTimeInterval(min(900, 300 * pow(2, Double(count - 1)))))
            } else { coverageRetries[key] = nil }
            return await status(for: key)
        } catch let error as EPGProductionServiceError where error == .cancelled || error == .paused || error == .closed {
            throw error
        } catch is CancellationError {
            throw EPGProductionServiceError.cancelled
        } catch {
            let count = min(16, (failures[key]?.count ?? 0) + 1)
            failures[key] = FailureState(count: count, retryAt: now().addingTimeInterval(Self.retryDelay(count)))
            return await status(for: key)
        }
    }

    private static func retryDelay(_ count: Int) -> TimeInterval {
        min(15 * 60, 60 * pow(2, Double(count - 1)))
    }

    public func queryXMLTVNowNext(_ channels: [LiveChannel], for key: EPGRequestKey,
                                  at date: Date, demandRevision: UUID) async throws -> EPGNowNextBatch {
        guard !closed, let service else { throw EPGProductionServiceError.unavailable }
        let value = try await service.queryNowNext(channels, for: key, at: date,
                                                   demandRevision: demandRevision)
        let current = await status(for: key)
        guard current.summary?.dataVersion == value.token.dataVersion,
              current.summary?.sourceEpoch == value.token.sourceEpoch else {
            throw EPGProductionServiceError.invalidRequest
        }
        return EPGNowNextBatch(token: value.token, items: value.items,
                               availability: current.availability)
    }

    public func queryXMLTVWindow(_ channel: LiveChannel, for key: EPGRequestKey,
                                 from start: Date, to end: Date, limit: Int = 200,
                                 cursor: EPGProductionWindowCursor? = nil,
                                 demandRevision: UUID) async throws -> EPGProductionWindowResult {
        guard !closed, let service else { throw EPGProductionServiceError.unavailable }
        let value = try await service.queryWindow(channel, for: key, from: start, to: end,
            limit: limit, cursor: cursor, demandRevision: demandRevision)
        let current = await status(for: key)
        guard current.summary?.dataVersion == value.page.token.dataVersion,
              current.summary?.sourceEpoch == value.page.token.sourceEpoch else {
            throw EPGProductionServiceError.snapshotChanged
        }
        return value
    }

    public func loadXtream(key: EPGRequestKey, accountIdentity: String,
                           serverIdentity: String, configurationRevision: String,
                           at date: Date, demandRevision: UUID, force: Bool = false, refreshID: UUID? = nil,
                           fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> EPGNowNextBatch {
        guard !closed else { throw EPGProductionServiceError.closed }
        guard !paused else { throw EPGProductionServiceError.paused }
        let cacheKey = try xtreamKey(key: key, accountIdentity: accountIdentity,
                                     serverIdentity: serverIdentity,
                                     configurationRevision: configurationRevision)
        if !force, refreshID == nil,
           let archiveKey = try? xtreamKey(key: key, accountIdentity: accountIdentity,
               serverIdentity: serverIdentity, configurationRevision: configurationRevision, archive: true),
           let archive = xtreamEntries[archiveKey], archive.expiresAt > now(),
           archive.availability == .fresh,
           archive.publishedAt > (xtreamEntries[cacheKey]?.publishedAt ?? .distantPast),
           archive.programmes.contains(where: { $0.start <= date && date < $0.end }) {
            return xtreamBatch(archive, at: date, demandRevision: demandRevision)
        }
        let entry = try await resolveXtreamEntry(cacheKey: cacheKey, requestKey: key,
                                                 force: force, refreshID: refreshID, fetch: fetch)
        return xtreamBatch(entry, at: date, demandRevision: demandRevision)
    }

    public func loadXtreamWindow(key: EPGRequestKey, accountIdentity: String,
                                 serverIdentity: String, configurationRevision: String,
                                 from start: Date, to end: Date, demandRevision: UUID,
                                 force: Bool = false, archive: Bool = false, refreshID: UUID? = nil,
                                 fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> EPGXtreamWindowResult {
        guard !closed else { throw EPGProductionServiceError.closed }
        guard !paused else { throw EPGProductionServiceError.paused }
        guard start < end, end.timeIntervalSince(start) <= 12 * 60 * 60 else {
            throw EPGProductionServiceError.invalidRequest
        }
        let cacheKey = try xtreamKey(key: key, accountIdentity: accountIdentity,
                                     serverIdentity: serverIdentity,
                                     configurationRevision: configurationRevision, archive: archive)
        let entry = try await resolveXtreamEntry(cacheKey: cacheKey, requestKey: key,
                                                 force: force, refreshID: refreshID, maximumProgrammes: archive ? 1000 : Self.maximumXtreamProgrammes,
                                                 maximumEntryBytes: archive ? 256 * 1024 : Self.maximumXtreamEntryBytes, fetch: fetch)
        let token = xtreamToken(entry, demandRevision: demandRevision)
        let records: [EPGWindowProgramme] = entry.programmes.enumerated().compactMap { ordinal, programme in
            guard programme.start < end, programme.end > start else { return nil }
            return EPGWindowProgramme(id: EPGProgrammeRecordIdentity(kind: .xtream,
                resourceIdentity: token.resourceIdentity, sourceEpoch: token.sourceEpoch,
                dataVersion: token.dataVersion, ordinal: ordinal), programme: programme)
        }
        let match = EPGChannelMatch(kind: .exact, channelID: entry.key.resource)
        return EPGXtreamWindowResult(page: EPGWindowPage(token: token, match: match,
            records: records, hasMore: false), availability: xtreamAvailability(entry))
    }

    public func invalidate(_ source: EPGSourceKey, removePersistentCache: Bool = true) async {
        for (key, flight) in xtreamFlights where key.source == source {
            flight.task.cancel(); xtreamFlights[key] = nil
        }
        xtreamEntries = xtreamEntries.filter { $0.key.source != source }
        failures = failures.filter { $0.key.source != source }
        coverageRetries = coverageRetries.filter { $0.key.source != source }
        channelFailures = channelFailures.filter { $0.key.source != source }
        manualRefreshIDs = manualRefreshIDs.filter { $0.key.source != source }
        for (key, task) in xmltvFlights where key.source == source { task.cancel() }
        if removePersistentCache, source.kind == .imported, let service {
            try? await service.setSourceEnabled(source, enabled: false)
        }
    }

    public func prepareImportedSource(_ source: EPGSourceKey) async throws {
        guard source.kind == .imported, let service else { throw EPGProductionServiceError.unavailable }
        try await service.setSourceEnabled(source, enabled: true)
    }

    public func cancelTransientRequests() {
        for task in xmltvFlights.values { task.cancel() }
        for flight in xtreamFlights.values { flight.task.cancel() }
        xtreamFlights.removeAll()
    }

    public func pause(deadlineNanoseconds: UInt64 = 750_000_000) async -> Bool {
        paused = true
        cancelTransientRequests()
        guard let service else { return true }
        return await service.pause(deadlineNanoseconds: deadlineNanoseconds)
    }

    public func resume() async throws {
        try Task.checkCancellation()
        guard !closed else { throw EPGProductionServiceError.closed }
        if let service { try await service.resume() }
        try Task.checkCancellation()
        guard !closed else { throw EPGProductionServiceError.closed }
        paused = false
    }

    public func performMaintenance() async throws -> EPGMaintenanceResult {
        guard let service else { throw EPGProductionServiceError.unavailable }
        return try await service.performMaintenance()
    }

    public func close(deadlineNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        if terminalCloseComplete { return true }
        closed = true; paused = true
        cancelTransientRequests()
        guard let service else { terminalCloseComplete = true; return true }
        let completed = await service.close(deadlineNanoseconds: deadlineNanoseconds)
        if completed { terminalCloseComplete = true }
        return completed
    }

    private func status(key: EPGRequestKey, summary: EPGResourceSummary?, at date: Date) -> EPGRepositoryStatus {
        let failure = failures[key]
        guard let summary else {
            return EPGRepositoryStatus(key: key, availability: .failed, summary: nil,
                freshUntil: nil, refreshDueAt: failure?.retryAt ?? date,
                nextRetryAt: failure?.retryAt ?? date,
                consecutiveFailures: failure?.count ?? 0)
        }
        let freshUntil = summary.publishedAt.addingTimeInterval(
            summary.programmeCount == 0 ? Self.emptyTTL : Self.xmltvTTL)
        let coverageDue = summary.coverageEnd.map {
            max(summary.publishedAt, $0.addingTimeInterval(-Self.coverageLead))
        }
        let due = min(freshUntil, coverageDue ?? freshUntil)
        let availability: EPGAvailability
        if failure != nil || due <= date { availability = .stale }
        else if summary.programmeCount == 0 { availability = .empty }
        else { availability = .fresh }
        return EPGRepositoryStatus(key: key, availability: availability, summary: summary,
            freshUntil: freshUntil, refreshDueAt: due,
            nextRetryAt: failure?.retryAt ?? max(due,
                coverageRetries[key]?.retryAt ?? summary.publishedAt.addingTimeInterval(300)),
            consecutiveFailures: failure?.count ?? 0)
    }

    private func failedStatus(_ key: EPGRequestKey, at date: Date) -> EPGRepositoryStatus {
        EPGRepositoryStatus(key: key, availability: .failed, summary: nil,
            freshUntil: nil, refreshDueAt: date, nextRetryAt: date,
            consecutiveFailures: failures[key]?.count ?? 0)
    }

    private func xtreamKey(key: EPGRequestKey, accountIdentity: String,
                           serverIdentity: String, configurationRevision: String, archive: Bool = false) throws -> XtreamKey {
        guard key.source.kind == .xtream, key.resource.utf8.count > 0,
              key.resource.utf8.count <= Self.maximumXtreamIdentifierBytes,
              accountIdentity.utf8.count <= 8_192, serverIdentity.utf8.count <= 8_192,
              configurationRevision.utf8.count <= 8_192 else {
            throw EPGProductionServiceError.invalidRequest
        }
        return XtreamKey(source: key.source,
            revision: Self.digest(key.revision + "\u{0}" + configurationRevision + (archive ? "\u{0}archive" : "\u{0}short")),
            requestRevision: key.revision, account: Self.digest(accountIdentity), server: Self.digest(serverIdentity),
            streamID: key.resource, archive: archive)
    }

    private static func xtreamEntry(payload: EPGPayload, requestKey: EPGRequestKey,
                                    streamID: String, now: Date, maximumProgrammes: Int = maximumXtreamProgrammes, maximumEntryBytes: Int = maximumXtreamEntryBytes, cacheTTL: TimeInterval? = nil) throws -> XtreamEntry {
        let programmes = payload.guide.programmes
        guard programmes.count <= maximumProgrammes else {
            throw EPGProductionServiceError.resultTooLarge
        }
        var cost = streamID.utf8.count + 256
        var previous: Date?
        for value in programmes {
            let titleBytes = value.title.utf8.count
            guard value.channelID == streamID, !value.title.isEmpty,
                  titleBytes <= maximumXtreamTitleBytes,
                  value.channelID.utf8.count <= maximumXtreamIdentifierBytes,
                  value.start < value.end, value.end.timeIntervalSince(value.start) <= 7 * 86400,
                  previous.map({ $0 < value.start }) ?? true else {
                throw EPGProductionServiceError.invalidRequest
            }
            previous = value.start
            cost += titleBytes + value.channelID.utf8.count + 128
            guard cost <= maximumEntryBytes else {
                throw EPGProductionServiceError.resultTooLarge
            }
        }
        let availability: EPGAvailability = payload.unsupported ? .unsupported
            : (programmes.isEmpty ? .empty : .fresh)
        let ttl = cacheTTL ?? (payload.unsupported ? unsupportedTTL : (programmes.isEmpty ? emptyTTL : xtreamTTL))
        return XtreamEntry(key: requestKey, version: UUID().uuidString,
            publishedAt: now, expiresAt: now.addingTimeInterval(ttl),
            availability: availability, programmes: programmes,
            byteCost: cost, accessedAt: now)
    }

    private func rememberXtream(_ entry: XtreamEntry, for key: XtreamKey) {
        xtreamEntries[key] = entry
        while xtreamEntries.count > Self.maximumXtreamEntries
                || xtreamEntries.values.reduce(0, { $0 + $1.byteCost }) > Self.maximumXtreamCacheBytes,
              let oldest = xtreamEntries.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            xtreamEntries[oldest] = nil
        }
    }

    private func resolveXtreamEntry(cacheKey: XtreamKey, requestKey: EPGRequestKey,
                                    force: Bool, refreshID: UUID? = nil,
                                    maximumProgrammes: Int = maximumXtreamProgrammes,
                                    maximumEntryBytes: Int = maximumXtreamEntryBytes, cacheTTL: TimeInterval? = nil,
                                    fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> XtreamEntry {
        try Task.checkCancellation()
        let forced = force || (refreshID != nil && manualRefreshIDs[cacheKey] != refreshID)
        if let flight = xtreamFlights[cacheKey] {
            if let refreshID { manualRefreshIDs[cacheKey] = refreshID }
            do { return try await flight.task.value }
            catch { return try staleXtreamFallback(cacheKey: cacheKey, error: error) }
        }
        if !forced {
            if let failure = channelFailures[cacheKey] {
                if failure.retryAt > now() {
                    return try staleXtreamFallback(cacheKey: cacheKey, error: EPGProductionServiceError.unavailable)
                }
            } else if var cached = xtreamEntries[cacheKey], cached.expiresAt > now() {
                cached.accessedAt = now()
                xtreamEntries[cacheKey] = cached
                return cached
            }
        }
        if let refreshID { manualRefreshIDs[cacheKey] = refreshID }
        let id = UUID(), clock = now
        let task = Task<XtreamEntry, Error> {
            let payload = try await fetch()
            try Task.checkCancellation()
            return try Self.xtreamEntry(payload: payload, requestKey: requestKey,
                streamID: cacheKey.streamID, now: clock(), maximumProgrammes: maximumProgrammes,
                maximumEntryBytes: maximumEntryBytes, cacheTTL: cacheTTL)
        }
        xtreamFlights[cacheKey] = XtreamFlight(id: id, task: task)
        do {
            let value = try await task.value
            guard xtreamFlights[cacheKey]?.id == id, !closed, !paused else {
                throw EPGProductionServiceError.cancelled
            }
            xtreamFlights[cacheKey] = nil
            channelFailures[cacheKey] = nil
            rememberXtream(value, for: cacheKey)
            trimRefreshMetadata()
            return value
        } catch {
            guard xtreamFlights[cacheKey]?.id == id, !closed, !paused else {
                throw EPGProductionServiceError.cancelled
            }
            xtreamFlights[cacheKey] = nil
            if !(error is CancellationError), error as? EPGProductionServiceError != .cancelled {
                let count = min(16, (channelFailures[cacheKey]?.count ?? 0) + 1)
                channelFailures[cacheKey] = FailureState(count: count,
                    retryAt: now().addingTimeInterval(Self.retryDelay(count)))
                trimRefreshMetadata()
            }
            return try staleXtreamFallback(cacheKey: cacheKey, error: error)
        }
    }

    private func trimRefreshMetadata() {
        while channelFailures.count > Self.maximumXtreamEntries,
              let oldest = channelFailures.min(by: { $0.value.retryAt < $1.value.retryAt })?.key {
            channelFailures[oldest] = nil
            manualRefreshIDs[oldest] = nil
        }
        manualRefreshIDs = manualRefreshIDs.filter {
            xtreamEntries[$0.key] != nil || channelFailures[$0.key] != nil || xtreamFlights[$0.key] != nil
        }
    }

    public func refreshInfo(source: LiveSourceID, revision: String, resources: [String],
                            dayScope: [String: Set<String>]? = nil, archiveOnly: Bool = false,
                            includeXMLTV: Bool = true) async -> EPGRefreshInfo {
        let sourceKey = EPGSourceKey(source), selected = Set(resources)
        func matches(_ key: XtreamKey) -> Bool {
            guard key.source == sourceKey, key.requestRevision == revision,
                  selected.contains(key.streamID) else { return false }
            if archiveOnly, !key.archive { return false }
            if let dayScope, let day = key.day {
                return dayScope[key.streamID]?.contains(day) == true
            }
            return true
        }
        let entries = xtreamEntries.filter { matches($0.key) }
        let channelErrors = channelFailures.filter { matches($0.key) }
        var updated = entries.values.map(\.publishedAt)
        var due = entries.map { channelFailures[$0.key]?.retryAt ?? $0.value.expiresAt }
        var retries = channelErrors.values.map(\.retryAt)
        if includeXMLTV, case .imported = source {
            let status = await status(for: EPGRequestKey(source: source, revision: revision, resource: "xmltv"))
            if let summary = status.summary { updated.append(summary.publishedAt); due.append(status.nextRetryAt) }
            if status.consecutiveFailures > 0 { retries.append(status.nextRetryAt) }
        }
        due.append(contentsOf: retries)
        return EPGRefreshInfo(lastUpdatedAt: updated.max(), nextRefreshAt: due.min(), retryAt: retries.min())
    }

    private func staleXtreamFallback(cacheKey: XtreamKey, error: Error) throws -> XtreamEntry {
        if Task.isCancelled || error is CancellationError || error as? EPGProductionServiceError == .cancelled {
            throw EPGProductionServiceError.cancelled
        }
        if !closed, !paused, var old = xtreamEntries[cacheKey] {
            old.availability = .stale
            old.accessedAt = now()
            xtreamEntries[cacheKey] = old
            return old
        }
        if error is CancellationError || error as? EPGProductionServiceError == .cancelled {
            throw EPGProductionServiceError.cancelled
        }
        throw EPGProductionServiceError.unavailable
    }

    private func xtreamBatch(_ entry: XtreamEntry, at date: Date,
                             demandRevision: UUID) -> EPGNowNextBatch {
        let current = entry.programmes.first { $0.start <= date && date < $0.end }
        let next = entry.programmes.first { $0.start > date }
        let token = xtreamToken(entry, demandRevision: demandRevision)
        let match = EPGChannelMatch(kind: .exact, channelID: entry.key.resource)
        return EPGNowNextBatch(token: token,
            items: [EPGNowNextItem(match: match, current: current, next: next)],
            availability: xtreamAvailability(entry))
    }

    private func xtreamToken(_ entry: XtreamEntry, demandRevision: UUID) -> EPGResultToken {
        let resource = "xtream:" + Self.digest(entry.key.revision + "\u{0}" + entry.key.resource)
        return EPGResultToken(serviceIncarnation: incarnation,
            resourceIdentity: resource, sourceEpoch: entry.key.revision,
            dataVersion: entry.version, demandRevision: demandRevision)
    }

    private func xtreamAvailability(_ entry: XtreamEntry) -> EPGAvailability {
        entry.expiresAt <= now() && entry.availability == .fresh ? .stale : entry.availability
    }

    /// Daily API entries share the existing finite cache/flight/close budgets,
    /// with source, channel, endpoint revision, timezone and day isolated.
    public func loadTVBoxDay(key: EPGRequestKey, day: String, timeZoneID: String,
                            demandRevision: UUID, refreshID: UUID? = nil,
                            fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> EPGChannelDayResult {
        guard !closed, !paused, key.source.kind == .imported, !key.resource.isEmpty,
              key.resource.utf8.count <= Self.maximumXtreamIdentifierBytes,
              day.utf8.count <= 16, TimeZone(identifier: timeZoneID) != nil else {
            throw EPGProductionServiceError.invalidRequest
        }
        let scope = Self.digest(key.revision + "\u{0}" + day + "\u{0}" + timeZoneID)
        let cacheKey = XtreamKey(source: key.source, revision: scope,
            requestRevision: key.revision, account: "tvbox-day", server: scope, streamID: key.resource, day: day)
        let entry = try await resolveXtreamEntry(cacheKey: cacheKey, requestKey: key,
            force: false, refreshID: refreshID, maximumProgrammes: 512, cacheTTL: 300, fetch: fetch)
        let token = EPGResultToken(serviceIncarnation: incarnation,
            resourceIdentity: "tvbox:" + Self.digest(key.revision + "\u{0}" + key.resource + "\u{0}" + day),
            sourceEpoch: key.revision, dataVersion: entry.version, demandRevision: demandRevision)
        return EPGChannelDayResult(token: token, programmes: entry.programmes, availability: xtreamAvailability(entry))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
