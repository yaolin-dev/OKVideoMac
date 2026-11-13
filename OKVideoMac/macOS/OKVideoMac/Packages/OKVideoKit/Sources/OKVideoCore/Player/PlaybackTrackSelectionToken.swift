import Foundation

/// Admission at the native queue and database actor, without a main-thread hop.
/// Invalidating a token retires queued work; it cannot undo an executing command.
public final class PlaybackTrackSelectionToken: @unchecked Sendable {
    public let requestID: UUID
    public let type: MediaTrackType
    public let trackID: Int?
    private let lock = NSLock()
    private var valid = true

    public init(requestID: UUID, type: MediaTrackType, trackID: Int?) {
        self.requestID = requestID; self.type = type; self.trackID = trackID
    }
    public var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return valid
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }
    public func checkValidity() throws {
        if !isValid { throw CancellationError() }
    }
}
