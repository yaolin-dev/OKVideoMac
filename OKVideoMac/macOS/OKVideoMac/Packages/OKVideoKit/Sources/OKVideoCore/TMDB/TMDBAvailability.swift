import Foundation

public enum TMDBLink: String, CaseIterable, Sendable { case metadata, images }
public enum TMDBLinkState: String, Sendable { case unknown, available, unavailable }
public enum TMDBFailure: String, Sendable { case network, server, configuration, rateLimited, invalidResponse }
public enum TMDBLinkOutcome: Equatable, Sendable {
    case success, missing, cancelled
    case failure(TMDBFailure, retryAfter: TimeInterval? = nil)

    public static func status(_ code: Int, retryAfter: TimeInterval? = nil) -> Self {
        switch code {
        case 404: return .missing
        case 401, 403: return .failure(.configuration)
        case 429: return .failure(.rateLimited, retryAfter: retryAfter)
        case 500...599: return .failure(.server)
        default: return .failure(.invalidResponse)
        }
    }
    public static func error(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError { return error.code == .cancelled ? .cancelled : .failure(.network) }
        if let error = error as? TMDBError {
            switch error {
            case .invalidInput: return .cancelled
            case .credentialMissing, .invalidCredential: return .failure(.configuration)
            case .invalidResponse: return .failure(.invalidResponse)
            case .unavailable(let code): return code == 0 ? .cancelled : status(code)
            case .service(let code, let retry): return status(code, retryAfter: retry)
            }
        }
        if let error = error as? HTTPClientError {
            switch error {
            case .cancelled: return .cancelled
            case .statusCode(let code): return status(code)
            case .timeout, .transport: return .failure(.network)
            default: return .failure(.invalidResponse)
            }
        }
        return .failure(.invalidResponse)
    }
}

public struct TMDBAvailabilitySnapshot: Sendable {
    public struct Link: Sendable {
        public let state: TMDBLinkState
        public let checking: Bool
        public let failure: TMDBFailure?
        public let retryAt: TimeInterval
        public let validUntil: TimeInterval
    }
    public let generation: Int
    public let metadata: Link
    public let images: Link
    public var ready: Bool { metadata.state == .available && images.state == .available }
    public var blocked: Bool { metadata.state == .unavailable || images.state == .unavailable }
}

/// Shared by probes and real requests. All deadlines use monotonic uptime.
public actor TMDBAvailability {
    public struct Ticket: Sendable {
        let link: TMDBLink
        let generation: Int
        let serial: Int
    }
    private struct Record {
        var successUntil: TimeInterval = 0
        var retryAt: TimeInterval = 0
        var failure: TMDBFailure?
        var nextProbeAt: TimeInterval = 0
        var failures = 0
        var acceptedSerial = 0
        var probe: (Int, Task<Void, Never>)?
    }
    private var records: [TMDBLink: Record] = [:]
    private var generation = 0
    private var serial = 0
    private var metadataRequestsEnabled = true
    private var observers: [UUID: AsyncStream<TMDBAvailabilitySnapshot>.Continuation] = [:]
    private let now: @Sendable () -> TimeInterval
    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    public func snapshot() -> TMDBAvailabilitySnapshot {
        func value(_ link: TMDBLink) -> TMDBAvailabilitySnapshot.Link {
            let record = records[link] ?? Record()
            let state: TMDBLinkState = record.retryAt > now() ? .unavailable : record.successUntil > now() ? .available : .unknown
            return .init(state: state, checking: record.probe != nil, failure: record.failure, retryAt: record.retryAt, validUntil: record.successUntil)
        }
        return .init(generation: generation, metadata: value(.metadata), images: value(.images))
    }
    public func updates() -> AsyncStream<TMDBAvailabilitySnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() {
        let value = snapshot()
        for observer in observers.values { observer.yield(value) }
    }

    public func ticket(_ link: TMDBLink) -> Ticket {
        serial += 1
        return Ticket(link: link, generation: generation, serial: serial)
    }
    public func setMetadataRequestsEnabled(_ enabled: Bool) { metadataRequestsEnabled = enabled }
    public func requestAllowed(_ link: TMDBLink) -> Bool { (link == .images || metadataRequestsEnabled) && (records[link]?.retryAt ?? 0) <= now() }

    public func finish(_ ticket: Ticket, outcome: TMDBLinkOutcome) {
        guard ticket.generation == generation else { return }
        var record = records[ticket.link] ?? Record()
        if record.probe?.0 == ticket.serial { record.probe = nil }
        defer { records[ticket.link] = record; publish() }
        guard ticket.serial >= record.acceptedSerial else { return }
        switch outcome {
        case .cancelled: return
        case .missing: record.nextProbeAt = now() + 30; return
        case .success:
            if record.failure == .rateLimited, record.retryAt > now() { return }
            record.acceptedSerial = ticket.serial; record.successUntil = now() + 180
            record.failure = nil; record.retryAt = 0; record.failures = 0
        case .failure(let failure, let retry):
            record.acceptedSerial = ticket.serial; record.successUntil = 0
            record.failures = min(record.failures + 1, 5); record.failure = failure
            let backoff = min(300, 30 * pow(2, Double(record.failures - 1)))
            // Invalid API credentials cannot recover through automatic retries.
            // A credential/route change or an explicit user probe resets this state.
            record.retryAt = failure == .configuration && ticket.link == .metadata ? .infinity : now() + max(backoff, retry ?? 0)
        }
    }

    /// One probe per link. Starting a refresh preserves valid success evidence.
    public func probe(_ link: TMDBLink, force: Bool = false, operation: @escaping @Sendable () async -> TMDBLinkOutcome) {
        var record = records[link] ?? Record()
        guard !Task.isCancelled, record.probe == nil else { return }
        if !force, record.nextProbeAt > now() { return }
        if record.retryAt > now(), !force || record.failure == .rateLimited { return }
        if !force, record.successUntil > now() { return }
        if force, record.failure != .rateLimited { record.retryAt = 0 }
        let ticket = ticket(link)
        let task = Task { [weak self] in
            let outcome = await operation()
            await self?.finish(ticket, outcome: outcome)
        }
        record.probe = (ticket.serial, task); records[link] = record
        publish()
    }

    /// Cancelling a check does not erase successful evidence or server backoff.
    /// Late completions from the cancelled probes cannot publish success.
    public func cancelProbes() {
        for link in TMDBLink.allCases {
            guard var record = records[link], let probe = record.probe else { continue }
            probe.1.cancel(); record.probe = nil
            serial += 1; record.acceptedSerial = serial
            records[link] = record
        }
        publish()
    }

    public func networkChanged() {
        generation += 1
        for link in TMDBLink.allCases {
            let old = records[link] ?? Record()
            old.probe?.1.cancel()
            var fresh = Record()
            // Changing a route does not authorize bypassing a server rate limit.
            if old.failure == .rateLimited, old.retryAt > now() {
                fresh.failure = old.failure; fresh.retryAt = old.retryAt; fresh.failures = old.failures
            }
            records[link] = fresh
        }
        publish()
    }
}

/// Reports only validated API outcomes; cache hits never flow through here.
public actor TMDBObservedService: TMDBServing {
    private let base: TMDBServing
    private let availability: TMDBAvailability
    public init(base: TMDBServing = TMDBClient(), availability: TMDBAvailability) { self.base = base; self.availability = availability }
    private func observed<T>(_ operation: () async throws -> T) async throws -> T {
        guard await availability.requestAllowed(.metadata) else { throw TMDBError.unavailable(0) }
        let ticket = await availability.ticket(.metadata)
        for attempt in 0..<2 {
            do {
                let value = try await operation()
                try Task.checkCancellation()
                await availability.finish(ticket, outcome: .success)
                return value
            } catch {
                let outcome = TMDBLinkOutcome.error(error)
                // One transient transport error gets a bounded retry before
                // recording a shared outage. Cancellation/HTTP errors do not.
                if attempt == 0, outcome == .failure(.network), !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 300_000_000) }
                    catch { await availability.finish(ticket, outcome: .cancelled); throw error }
                    guard await availability.requestAllowed(.metadata) else { throw TMDBError.unavailable(0) }
                    continue
                }
                await availability.finish(ticket, outcome: outcome); throw error
            }
        }
        throw TMDBError.invalidResponse
    }
    public func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        try await observed { try await base.search(query: query, type: type, year: year) }
    }
    public func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        try await observed { try await base.searchPage(query: query, type: type, year: year) }
    }
    public func detail(_ reference: TMDBReference) async throws -> TMDBWork { try await observed { try await base.detail(reference) } }
    public func season(tvID: Int, number: Int) async throws -> TMDBSeason { try await observed { try await base.season(tvID: tvID, number: number) } }
    public func personIdentity(id: Int) async throws -> TMDBPersonIdentity { try await observed { try await base.personIdentity(id: id) } }
    public func personCredits(id: Int) async throws -> TMDBPersonCredits { try await observed { try await base.personCredits(id: id) } }
    public func imageConfiguration() async throws -> TMDBImageConfiguration { try await observed { try await base.imageConfiguration() } }
}
