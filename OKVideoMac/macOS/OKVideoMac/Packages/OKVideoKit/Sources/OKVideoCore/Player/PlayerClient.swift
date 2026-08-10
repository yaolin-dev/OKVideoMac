import Foundation

public enum PlayerStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case stopped
    case failed(String)
}

public enum MediaTrackType: String, Codable, Sendable {
    case video
    case audio
    case subtitle
}

public struct MediaTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var type: MediaTrackType
    public var title: String
    public var language: String?
    public var isSelected: Bool

    public init(
        id: Int,
        type: MediaTrackType,
        title: String,
        language: String? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.language = language
        self.isSelected = isSelected
    }
}

public struct PlayerSnapshot: Equatable, Sendable {
    public var status: PlayerStatus
    public var position: TimeInterval
    public var duration: TimeInterval
    public var bufferedPercent: Double
    public var networkSpeedBytesPerSecond: Int64
    public var volume: Double
    public var isMuted: Bool
    public var speed: Double
    public var tracks: [MediaTrack]
    public var videoWidth: Int
    public var videoHeight: Int

    public init(
        status: PlayerStatus = .idle,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        bufferedPercent: Double = 0,
        networkSpeedBytesPerSecond: Int64 = 0,
        volume: Double = 100,
        isMuted: Bool = false,
        speed: Double = 1,
        tracks: [MediaTrack] = [],
        videoWidth: Int = 0,
        videoHeight: Int = 0
    ) {
        self.status = status
        self.position = position
        self.duration = duration
        self.bufferedPercent = bufferedPercent
        self.networkSpeedBytesPerSecond = max(0, networkSpeedBytesPerSecond)
        self.volume = volume
        self.isMuted = isMuted
        self.speed = speed
        self.tracks = tracks
        self.videoWidth = max(0, videoWidth)
        self.videoHeight = max(0, videoHeight)
    }
}

public enum PlayerEvent: Equatable, Sendable {
    case snapshot(PlayerSnapshot, requestID: UUID?)
    case fileLoaded(requestID: UUID?)
    case ended(requestID: UUID?)
    case error(String, requestID: UUID?)
}

public protocol PlayerClient: AnyObject {
    var events: AsyncStream<PlayerEvent> { get }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID
    ) async throws
    func play() async throws
    func pause() async throws
    func stop() async
    func seek(to position: TimeInterval) async throws
    func setVolume(_ volume: Double) async throws
    func setMuted(_ muted: Bool) async throws
    func setSpeed(_ speed: Double) async throws
    func selectTrack(id: Int, type: MediaTrackType) async throws
    func addSubtitle(url: URL) async throws
    func setSubtitleDelay(_ delay: TimeInterval) async throws
    func setSubtitleScale(_ scale: Double) async throws
    func setSubtitlePosition(_ position: Double) async throws
    func setSubtitleBorderSize(_ size: Double) async throws
    func setAudioDelay(_ delay: TimeInterval) async throws
    func setAspectRatio(_ ratio: String?) async throws
    func setHardwareDecoding(enabled: Bool) async throws
    func screenshot(to url: URL) async throws
    func shutdown() async
}

public final class UnavailablePlayerClient: PlayerClient {
    public let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    public init(reason: String = "libmpv 尚未构建或载入") {
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
        self.reason = reason
    }

    private let reason: String

    public func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID
    ) async throws {
        continuation.yield(.error(reason, requestID: requestID))
        throw AppError.unsupported(reason)
    }
    public func play() async throws { throw AppError.unsupported("libmpv 尚未可用") }
    public func pause() async throws { throw AppError.unsupported("libmpv 尚未可用") }
    public func stop() async {}
    public func seek(to position: TimeInterval) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setVolume(_ volume: Double) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setMuted(_ muted: Bool) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setSpeed(_ speed: Double) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func selectTrack(id: Int, type: MediaTrackType) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func addSubtitle(url: URL) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setSubtitleDelay(_ delay: TimeInterval) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setSubtitleScale(_ scale: Double) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setSubtitlePosition(_ position: Double) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setSubtitleBorderSize(_ size: Double) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setAudioDelay(_ delay: TimeInterval) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setAspectRatio(_ ratio: String?) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func setHardwareDecoding(enabled: Bool) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func screenshot(to url: URL) async throws {
        throw AppError.unsupported("libmpv 尚未可用")
    }
    public func shutdown() async {
        continuation.finish()
    }
}
