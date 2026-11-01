import Foundation
import OKVideoCore

/// Bounded, local-only playback evidence. The schema accepts no URLs, provider
/// messages, file names, titles, headers or credentials.
@MainActor final class PlaybackDiagnostics {
    enum Stage: String, Codable {
        case requested, resolving, resolved, authorization, loading, fileLoaded
        case firstFrame, retry, failed, paused, resumed, closed, superseded
    }
    enum Failure: String, Codable {
        case timeout, network, authorization, provider, decoding, database, player, cancelled, unknown
        static func classify(_ error: Error) -> Self {
            if error is CancellationError { return .cancelled }
            if let url = error as? URLError { return url.code == .cancelled ? .cancelled : url.code == .timedOut ? .timeout : .network }
            if let error = error as? HTTPClientError {
                switch error {
                case .cancelled: return .cancelled
                case .timeout: return .timeout
                case .statusCode(let code): return [401, 403].contains(code) ? .authorization : .network
                default: return .network
                }
            }
            if let error = error as? AppError {
                switch error {
                case .network: return .network
                case .decoding: return .decoding
                case .database: return .database
                case .site, .spider, .javascript, .parsing, .contentUnavailable: return .provider
                case .playback, .live: return .player
                case .cancelled: return .cancelled
                default: return .unknown
                }
            }
            return .unknown
        }
    }
    enum Retry: String, Codable { case user, authorization, recovery, quality }
    enum Kind: String, Codable { case onDemand, live, catchup }
    struct Event: Codable, Equatable {
        let stage: Stage
        let requestID: UUID
        let elapsedMilliseconds: Int
        let stageMilliseconds: Int
        let failure: Failure?
        let retry: Retry?
    }
    struct Record: Codable {
        let sessionID: UUID
        let kind: Kind
        var currentRequestID: UUID
        var events: [Event]
        var droppedEvents = 0
        var finished = false
    }
    private struct Trace {
        var record: Record
        let started: TimeInterval
        var previous: TimeInterval
        var confirmedPaused: Bool?
    }
    private var traces: [Trace] = []
    private let clock: () -> TimeInterval
    private let maximumSessions: Int
    private let maximumEvents: Int

    init(maximumSessions: Int = 12, maximumEvents: Int = 64,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumSessions = max(1, maximumSessions)
        self.maximumEvents = max(2, maximumEvents)
        self.clock = clock
    }
    func begin(sessionID: UUID, requestID: UUID, kind: Kind, retry: Retry? = nil, continuingFrom parent: UUID? = nil) {
        if let index = traces.lastIndex(where: { ($0.record.sessionID == sessionID || parent == $0.record.currentRequestID) && !$0.record.finished }) {
            if traces[index].record.currentRequestID == requestID, retry == nil, parent == nil { return }
            traces[index].record.currentRequestID = requestID
            traces[index].confirmedPaused = nil
            let previous = traces[index].record.events.last
            let reason = retry ?? (previous?.stage == .retry ? previous?.retry : nil) ?? .recovery
            record(requestID: requestID, stage: .retry, retry: reason)
            return
        }
        if let last = traces.last, !last.record.finished {
            record(requestID: last.record.currentRequestID, stage: .superseded)
        }
        let time = clock()
        traces.append(Trace(record: Record(sessionID: sessionID, kind: kind, currentRequestID: requestID, events: []), started: time, previous: time))
        if traces.count > maximumSessions { traces.removeFirst(traces.count - maximumSessions) }
        record(requestID: requestID, stage: .requested)
    }
    /// Compare native confirmations independently of optimistic UI snapshots.
    func observePlaybackState(requestID: UUID, paused: Bool) {
        guard let index = traces.lastIndex(where: { $0.record.currentRequestID == requestID && !$0.record.finished }) else { return }
        let previous = traces[index].confirmedPaused
        guard previous != paused else { return }
        traces[index].confirmedPaused = paused
        if paused { record(requestID: requestID, stage: .paused) }
        else if previous == true { record(requestID: requestID, stage: .resumed) }
    }
    func record(requestID: UUID, stage: Stage, failure: Failure? = nil, retry: Retry? = nil) {
        guard let index = traces.lastIndex(where: { $0.record.currentRequestID == requestID && !$0.record.finished }) else { return }
        let time = clock()
        if let last = traces[index].record.events.last,
           last.requestID == requestID, last.stage == stage, last.failure == failure, last.retry == retry { return }
        let event = Event(stage: stage, requestID: requestID,
            elapsedMilliseconds: milliseconds(time - traces[index].started),
            stageMilliseconds: milliseconds(time - traces[index].previous), failure: failure, retry: retry)
        traces[index].previous = time
        traces[index].record.events.append(event)
        if traces[index].record.events.count > maximumEvents {
            // Retain the initial request and the most recent diagnosis.
            traces[index].record.events.remove(at: 1)
            traces[index].record.droppedEvents += 1
        }
        if stage == .closed || stage == .superseded { traces[index].record.finished = true }
    }
    func snapshot() -> [Record] { traces.map(\.record) }
    private func milliseconds(_ value: TimeInterval) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(Double(Int.max / 2), max(0, value * 1000)))
    }
}
