import Foundation
import Combine
import OKVideoCore

/// Run-local, bounded mailbox. Submitting never hops to or waits for MainActor.
/// At most one delayed/delivering publication exists; it reads the latest value
/// on arrival, rather than retaining a queue of per-channel events.
final class ValidationProgressRelay: @unchecked Sendable {
    struct Value: Equatable, Sendable {
        let sourceID: UUID
        let runID: UUID
        let completed: Int
        let total: Int
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let deliver: @MainActor @Sendable (Value) -> Void
    private var latest: Value
    private var closed = false
    private var pending = false
    private var work: DispatchWorkItem?

    init(sourceID: UUID, runID: UUID, total: Int, interval: TimeInterval = 0.25,
         queue: DispatchQueue = DispatchQueue(label: "OKVideoMac.validation.progress", qos: .utility),
         deliver: @escaping @MainActor @Sendable (Value) -> Void) {
        latest = Value(sourceID: sourceID, runID: runID, completed: 0, total: max(0, total))
        self.interval = max(0.001, interval); self.queue = queue; self.deliver = deliver
    }

    func submit(completed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        // Total belongs to this run's input, not to a late/malformed callback.
        guard total == latest.total else { return }
        let next = Value(sourceID: latest.sourceID, runID: latest.runID,
            completed: min(latest.total, max(latest.completed, completed)), total: latest.total)
        guard next != latest else { return }
        latest = next
        if !pending { scheduleLocked() }
    }

    /// Used on open/cancel: the displayed, throttled number is not the truth.
    func snapshot() -> Value {
        lock.lock(); defer { lock.unlock() }; return latest
    }

    @discardableResult func close() -> Value {
        lock.lock(); defer { lock.unlock() }
        closed = true; work?.cancel(); work = nil
        return latest
    }

    private func scheduleLocked() {
        pending = true
        let item = DispatchWorkItem { [weak self] in self?.enqueueDelivery() }
        work = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func enqueueDelivery() {
        guard deliveryValue() != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let value = self.deliveryValue() else { return }
            self.deliver(value)
            self.didDeliver(value)
        }
    }

    private func deliveryValue() -> Value? {
        lock.lock(); defer { lock.unlock() }; return closed ? nil : latest
    }

    private func didDeliver(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        work = nil; pending = false
        if !closed && latest != value { scheduleLocked() }
    }
}

/// Toolbar never subscribes to numeric progress, even when the popover is open.
@MainActor
final class LiveValidationToolbarModel: ObservableObject {
    @Published private(set) var indicators: [UUID: LiveBackgroundIndicator] = [:]
    fileprivate func set(_ indicator: LiveBackgroundIndicator?, sourceID: UUID) {
        guard indicators[sourceID] != indicator else { return }
        indicators[sourceID] = indicator
    }
}

/// Presentation only. AppState owns permits/tasks/commits and does not forward
/// this object's notifications. There is no persistence or network ownership.
@MainActor
final class LiveValidationActivityModel: ObservableObject {
    let toolbar = LiveValidationToolbarModel()
    @Published private(set) var statuses: [UUID: LiveSourceValidationStatus] = [:]
    private var runs: [UUID: UUID] = [:]

    func begin(sourceID: UUID, runID: UUID, total: Int) {
        runs[sourceID] = runID
        statuses[sourceID] = .checking(completed: 0, total: max(0, total))
        toolbar.set(.active, sourceID: sourceID)
    }

    func accept(_ value: ValidationProgressRelay.Value) {
        guard runs[value.sourceID] == value.runID,
              case .checking(let done, let total) = statuses[value.sourceID],
              total == value.total, value.completed > done else { return }
        set(.checking(completed: min(total, value.completed), total: total), sourceID: value.sourceID)
    }

    func transition(_ status: LiveSourceValidationStatus, sourceID: UUID, runID: UUID) {
        guard runs[sourceID] == runID else { return }
        if case .checking = status { return } // Only begin/accept may publish progress.
        // Final states cannot be revived by a late completion/progress event.
        switch statuses[sourceID] {
        case .checking, .processing: set(status, sourceID: sourceID)
        default: return
        }
    }

    func clear(_ sourceID: UUID) {
        guard statuses[sourceID] != nil || runs[sourceID] != nil else { return }
        runs[sourceID] = nil; statuses[sourceID] = nil
        toolbar.set(nil, sourceID: sourceID)
    }

    func presentation(for source: LiveSourceID) -> LiveValidationPresentation? {
        guard case .imported(let id) = source else { return nil }
        return LiveValidationPresentation(status: statuses[id], runID: runs[id])
    }

    private func set(_ status: LiveSourceValidationStatus, sourceID: UUID) {
        guard statuses[sourceID] != status else { return }
        statuses[sourceID] = status
        let value = LiveValidationPresentation(status: status, runID: runs[sourceID])
        toolbar.set(value.isRunning ? .active : value.phase == .failed ? .warning : .idle, sourceID: sourceID)
    }
}

/// A value projection, not an observable task/state machine. No I/O and no
/// catalogue/matcher scan; temporal coverage reads the table's existing bound.
struct LiveEPGPresentation: Equatable {
    enum Activity: Equatable { case idle, loading, refreshing }
    enum Freshness: Equatable { case unknown, fresh, stale }
    enum Coverage: Equatable { case unknown, empty, expired, hasUnexpiredProgrammes }

    let enabled: Bool
    let configured: Bool
    let activity: Activity
    let dataAvailable: Bool
    let freshness: Freshness
    let coverage: Coverage
    let refreshFailed: Bool
    let lastProgrammeEnd: Date?
    let lastUpdatedAt: Date?
    let retryAt: Date?

    var usesCachedData: Bool {
        dataAvailable && (activity == .refreshing || freshness == .stale || refreshFailed)
    }

    init(enabled: Bool, key: EPGRequestKey?, status: EPGRepositoryStatus?,
         loading: Bool, refreshFailed: Bool, now: Date) {
        self.enabled = enabled
        configured = key != nil
        guard enabled, let key else {
            lastUpdatedAt = nil; retryAt = nil
            activity = .idle; dataAvailable = false; freshness = .unknown
            coverage = .unknown; self.refreshFailed = false; lastProgrammeEnd = nil
            return
        }
        let current = status.flatMap { $0.key == key ? $0 : nil }
        lastUpdatedAt = current?.summary?.publishedAt
        retryAt = (current?.consecutiveFailures ?? 0) > 0 ? current?.nextRetryAt : nil
        let parsed = current?.summary != nil && current?.availability != .failed
            && current?.availability != .unsupported
        dataAvailable = parsed && (current?.summary?.programmeCount ?? 0) > 0
        activity = loading ? (dataAvailable ? .refreshing : .loading) : .idle
        // A bare stale snapshot can just be an expired TTL, not a fetch error.
        self.refreshFailed = current != nil && (refreshFailed || (current?.consecutiveFailures ?? 0) > 0)
        if let current, parsed {
            freshness = current.availability == .stale || current.refreshDueAt <= now ? .stale : .fresh
            lastProgrammeEnd = current.summary?.coverageEnd
            if current.summary?.programmeCount == 0 { coverage = .empty }
            else if let end = current.summary?.coverageEnd {
                coverage = end <= now ? .expired : .hasUnexpiredProgrammes
            } else { coverage = .unknown }
        } else {
            freshness = .unknown; coverage = .unknown; lastProgrammeEnd = nil
        }
    }
}

struct LiveValidationPresentation: Equatable {
    enum Phase: Equatable { case idle, checking, processing, completed, cancelled, partial, failed }
    let phase: Phase
    let completed: Int
    let total: Int
    let hiddenCandidates: Int
    /// Capability captured with the displayed row, never looked up on click.
    let runID: UUID?
    var isRunning: Bool { phase == .checking || phase == .processing }
    var canStop: Bool { phase == .checking && runID != nil }
    var progress: Double? { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil }

    init(status: LiveSourceValidationStatus?, runID: UUID?) {
        let done: Int, count: Int, hidden: Int
        switch status {
        case .checking(let d, let t): phase = .checking; done = d; count = t; hidden = 0
        case .processing(let d, let t): phase = .processing; done = d; count = t; hidden = 0
        case .completed(let h, let t): phase = .completed; done = t; count = t; hidden = h
        case .cancelled(let d, let t): phase = .cancelled; done = d; count = t; hidden = 0
        case .partial(let d, let t): phase = .partial; done = d; count = t; hidden = 0
        case .failed: phase = .failed; done = 0; count = 0; hidden = 0
        case nil: phase = .idle; done = 0; count = 0; hidden = 0
        }
        total = max(0, count); completed = min(max(0, done), max(0, count))
        hiddenCandidates = max(0, hidden)
        self.runID = phase == .checking ? runID : nil
    }
}

enum LiveBackgroundIndicator: Equatable {
    case idle, active, warning

    init(catalogLoading: Bool, catalogFailed: Bool,
         epg: LiveEPGPresentation?, validation: LiveValidationPresentation?) {
        if catalogLoading || epg?.activity == .loading || epg?.activity == .refreshing
            || validation?.isRunning == true {
            self = .active
        } else if catalogFailed || epg?.refreshFailed == true || validation?.phase == .failed {
            self = .warning
        } else { self = .idle }
    }
}
