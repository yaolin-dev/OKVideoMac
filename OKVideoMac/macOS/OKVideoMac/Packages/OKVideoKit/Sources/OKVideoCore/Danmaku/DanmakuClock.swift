import Foundation

/// Interpolates between authoritative player snapshots. The player owns media
/// time; this clock only smooths drawing between snapshots.
public struct DanmakuClock: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var mediaTime: TimeInterval
    public private(set) var monotonicTime: TimeInterval
    public private(set) var rate: Double
    public private(set) var isAdvancing: Bool
    // Corrections affect presentation only. Filter transport noise and limit the
    // remaining slew to 2% of playback speed; never restart a fast linear ramp.
    private var correctionVelocity: Double = 0
    private var filteredError: TimeInterval = 0
    private let correctionDecay: TimeInterval = 1.5
    private var observation: Observation?
    private struct Observation: Equatable, Sendable {
        var position: TimeInterval
        var sampleTime: TimeInterval?
        var rate: Double
        var advancing: Bool
        var seeking: Bool
        var generation: UInt64
    }

    public init(
        generation: UInt64 = 0,
        mediaTime: TimeInterval = 0,
        monotonicTime: TimeInterval = 0,
        rate: Double = 1,
        isAdvancing: Bool = false
    ) {
        correctionVelocity = 0
        filteredError = 0
        observation = nil
        self.generation = generation
        self.mediaTime = Self.validMediaTime(mediaTime)
        self.monotonicTime = monotonicTime.isFinite ? monotonicTime : 0
        self.rate = Self.validRate(rate)
        self.isAdvancing = isAdvancing
    }

    public mutating func anchor(
        mediaTime: TimeInterval,
        monotonicTime: TimeInterval,
        rate: Double,
        isPlaying: Bool,
        isBuffering: Bool,
        isSeeking: Bool,
        generation: UInt64
    ) {
        correctionVelocity = 0
        filteredError = 0
        observation = nil
        self.generation = generation
        self.mediaTime = Self.validMediaTime(mediaTime)
        self.monotonicTime = monotonicTime.isFinite ? monotonicTime : self.monotonicTime
        self.rate = Self.validRate(rate)
        isAdvancing = isPlaying && !isBuffering && !isSeeking
    }

    public func currentTime(at monotonicTime: TimeInterval) -> TimeInterval {
        guard generation > 0, isAdvancing, monotonicTime.isFinite else {
            return mediaTime
        }
        let elapsed = max(0, monotonicTime - self.monotonicTime)
        return max(0, mediaTime + elapsed * rate
            + correctionVelocity * correctionDecay * (1 - exp(-elapsed / correctionDecay)))
    }

    /// Returns true only when the timeline should discard its old presentation.
    /// Repeated UI snapshots are ignored; small transport jitter is corrected
    /// gradually without moving backwards. Pause, buffering and seeks remain
    /// authoritative and do not extrapolate stale playback progress.
    @discardableResult
    public mutating func synchronize(mediaTime: TimeInterval, sampleUptime: TimeInterval?,
                                    monotonicTime now: TimeInterval, rate: Double,
                                    isPlaying: Bool, isBuffering: Bool, isSeeking: Bool,
                                    generation: UInt64) -> Bool {
        guard now.isFinite else { return false }
        let rate = Self.validRate(rate)
        let advancing = isPlaying && !isBuffering && !isSeeking
        let sample = sampleUptime.flatMap { $0.isFinite && $0 <= now ? $0 : nil }
        let next = Observation(position: Self.validMediaTime(mediaTime), sampleTime: sample,
                               rate: rate, advancing: advancing, seeking: isSeeking, generation: generation)
        guard next != observation else { return false }
        if let previous = observation, previous.generation == generation,
           let oldTime = previous.sampleTime, let sample, sample < oldTime { return false }
        let expected = currentTime(at: now)
        let target = next.position + (advancing ? max(0, now - (sample ?? now)) * rate : 0)
        let reset = self.generation != generation || abs(target - expected) > 0.8
            || (isSeeking && observation?.seeking != true)
        let smoothly = !reset && advancing && isAdvancing
        let elapsed = max(0, now - self.monotonicTime)
        let previousVelocity = correctionVelocity * exp(-elapsed / correctionDecay)
        if smoothly && self.rate == rate {
            // A 20 ms wall-time dead band suppresses frame-quantized progress.
            // Persistent drift still accumulates against expected media time.
            let alpha = 1 - exp(-min(elapsed, 1) / 0.5)
            filteredError += alpha * (target - expected - filteredError)
            let deadBand = 0.020 * rate
            let error = max(0, abs(filteredError) - deadBand) * (filteredError < 0 ? -1 : 1)
            let desiredVelocity = min(max(error / 2, -rate * 0.02), rate * 0.02)
            correctionVelocity = previousVelocity + alpha * (desiredVelocity - previousVelocity)
        } else {
            correctionVelocity = 0
            filteredError = 0
        }
        self.mediaTime = smoothly ? expected : target
        self.monotonicTime = now
        self.generation = generation
        self.rate = rate
        self.isAdvancing = advancing
        observation = next
        return reset
    }

    private static func validMediaTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    private static func validRate(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }
}
