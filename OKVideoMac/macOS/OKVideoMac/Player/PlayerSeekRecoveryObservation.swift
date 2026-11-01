import Foundation

/// Event-driven, numeric-only summary. Timeline progress is not a rendered
/// first-frame measurement. A new seek/load closes the preceding observation.
struct PlayerSeekRecoveryObservation {
    let started: TimeInterval
    private(set) var firstProgress: TimeInterval?
    private(set) var rebufferCount = 0
    private(set) var stableTenSeconds = false
    private var cachePaused = false
    private var lastPosition: TimeInterval?
    private var continuousSince: TimeInterval?

    init(started: TimeInterval) { self.started = started }

    mutating func interruptProgress() { continuousSince = nil }

    mutating func cachePause(_ paused: Bool) {
        if paused && !cachePaused {
            if firstProgress != nil { rebufferCount += 1 }
            continuousSince = nil
        }
        cachePaused = paused
    }

    mutating func progress(position: TimeInterval, now: TimeInterval, playing: Bool) {
        guard now.isFinite, position.isFinite, now >= started else { return }
        defer { lastPosition = position }
        guard playing, !cachePaused else { continuousSince = nil; return }
        guard let previous = lastPosition, position > previous + 0.001 else { return }
        if firstProgress == nil { firstProgress = now }
        if continuousSince == nil { continuousSince = now }
        if let continuousSince, now - continuousSince >= 10 { stableTenSeconds = true }
    }

    var fields: String {
        let first = firstProgress.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0 - started) } ?? "none"
        return "first_progress_seconds=\(first) rebuffers=\(rebufferCount) stable_10s_observed=\(stableTenSeconds)"
    }
}
