import Foundation

public enum TMDBPageMode: String, Sendable { case waiting, source, enhanced }
public struct TMDBEntryDecision: Sendable {
    public let id = UUID()
    public let startedAt: TimeInterval
    public let deadline: TimeInterval
    public private(set) var mode: TMDBPageMode = .waiting
    public private(set) var reason = "preparing"
    public init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, budget: TimeInterval = 1.2) {
        self.startedAt = startedAt; deadline = startedAt + max(0, budget)
    }
    public mutating func choose(_ mode: TMDBPageMode, reason: String) {
        guard self.mode == .waiting, mode != .waiting else { return }
        self.mode = mode; self.reason = reason
    }
    public mutating func evaluate(enabled: Bool, links: TMDBAvailabilitySnapshot, workReady: Bool, noMatch: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard mode == .waiting else { return }
        if !enabled { choose(.source, reason: "disabled") }
        else if workReady { choose(.enhanced, reason: "verified-work") }
        else if now >= deadline { choose(.source, reason: "deadline") }
        else if noMatch { choose(.source, reason: "unresolved-identity") }
    }
}

public actor TMDBRequestBudget {
    public let deadline: TimeInterval
    private var searches = 0, details = 0
    public init(deadline: TimeInterval) { self.deadline = deadline }
    public func admit(search: Bool) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline, searches + details < 4 else { throw CancellationError() }
        if search { guard searches < 2 else { throw CancellationError() }; searches += 1 }
        else { guard details < 2 else { throw CancellationError() }; details += 1 }
    }
    /// Enforce the preparation deadline at the transport boundary as well as
    /// between requests. URLSession cancellation is propagated by the client.
    public nonisolated func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw CancellationError() }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(min(remaining, 3600) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

}
