import Foundation
import OKVideoCore

enum PlayerTeardownMode: String, CaseIterable, Sendable {
    case warmStop
    case fullDestroy

    /// Internal rollback switch. Full teardown is the safe default after the
    /// player window closes because libmpv otherwise retains decoder and cache
    /// allocations. `warmStop` remains available for controlled comparisons.
    static let defaultsKey = "player.teardownMode"
    static let environmentKey = "OKVIDEOMAC_PLAYER_TEARDOWN_MODE"

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> PlayerTeardownMode {
        if let raw = environment[environmentKey],
           let mode = PlayerTeardownMode(rawValue: raw) {
            return mode
        }
        if let raw = defaults.string(forKey: defaultsKey),
           let mode = PlayerTeardownMode(rawValue: raw) {
            return mode
        }
        return .fullDestroy
    }
}

enum PlayerReleasePolicy: Equatable, Sendable {
    case existingBehavior
    case destroyBeforeLoad
}

enum PlayerLifecycleTransitionKind: Equatable, Sendable {
    case prepare
    case strictRelease
    case stop
    case close
}

/// Keeps the player cache bounded on long remote streams. `legacy` is an
/// operational rollback for servers whose buffering behavior depends on the
/// previous unbounded defaults.
enum MPVPlaybackPerformanceProfile: String, CaseIterable, Sendable {
    case legacy
    case balanced

    static let defaultsKey = "player.performanceProfile"
    static let environmentKey = "OKVIDEOMAC_MPV_PERFORMANCE_PROFILE"

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> MPVPlaybackPerformanceProfile {
        if let raw = environment[environmentKey],
           let profile = MPVPlaybackPerformanceProfile(rawValue: raw) {
            return profile
        }
        if let raw = defaults.string(forKey: defaultsKey),
           let profile = MPVPlaybackPerformanceProfile(rawValue: raw) {
            return profile
        }
        return .balanced
    }

    var mpvOptions: [(name: String, value: String)] {
        switch self {
        case .legacy:
            return [("cache", "yes")]
        case .balanced:
            return [
                ("cache", "auto"),
                ("cache-secs", "60"),
                ("demuxer-max-bytes", "128MiB"),
                ("demuxer-max-back-bytes", "32MiB"),
                ("demuxer-hysteresis-secs", "10")
            ]
        }
    }
}

/// libmpv advanced render control allows supported decoders to render directly
/// into caller-owned textures and can remove one full-frame copy. Keep the old
/// render contract available as a runtime rollback while this ships broadly.
enum MPVRenderControlMode: String, CaseIterable, Sendable {
    case legacy
    case advanced

    static let defaultsKey = "player.renderControlMode"
    static let environmentKey = "OKVIDEOMAC_MPV_RENDER_CONTROL"

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> MPVRenderControlMode {
        if let raw = environment[environmentKey],
           let mode = MPVRenderControlMode(rawValue: raw) {
            return mode
        }
        if let raw = defaults.string(forKey: defaultsKey),
           let mode = MPVRenderControlMode(rawValue: raw) {
            return mode
        }
        return .advanced
    }

    var usesAdvancedControl: Bool { self == .advanced }
}

private final class NativeLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum PlayerLoadTimeoutPolicy {
    static func seconds(for media: ResolvedMedia) -> Int {
        if media.compatibilityPolicy == .nativeXtreamLive { return min(60, max(1, media.nativeStartupBudgetSeconds ?? 60)) }
        return media.siteKey == "live" ? 8 : 30
    }
}

enum MPVTVBoxPlaybackPolicy {
    static func loadCommand(
        for media: ResolvedMedia,
        omitFormatHint: Bool = false,
        startPosition: TimeInterval? = nil,
        networkOptions: [(String, String)] = []
    ) -> [String] {
        let source: String
        if media.compatibilityPolicy == .nativeXtreamLive, let selection = media.hlsStartupSelection {
            source = "lavf://data:application/vnd.apple.mpegurl;base64," + Data(selection.playlist.utf8).base64EncodedString()
        } else { source = media.url.absoluteString }
        var command = ["loadfile", source, "replace"]
        var options = media.transportProfile == .tvBox
            ? fileOptions(for: media, omitFormatHint: omitFormatHint)
            : []
        if media.transportProfile == .tvBox {
            // File-local options cannot leak the prior episode's bookmark.
            // Keep decoding paused until file-loaded; start is applied by mpv
            // while opening the media, rather than by a second visible seek.
            let position = startPosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            options.append("start=" + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position))
            options.append("pause=yes")
        }
        if media.compatibilityPolicy == .nativeXtreamLive, media.hlsStartupSelection != nil {
            options.append("demuxer-lavf-format=hls")
        }
        if media.siteKey == "xtream-live",
           media.url.scheme?.lowercased() == "https" {
            options.append("tls-verify=yes")
        }
        options += networkOptions.map { MPVFileOptionEncoder.encode(name: $0.0, value: $0.1) }
        guard !options.isEmpty else { return command }
        command.append("-1")
        command.append(options.joined(separator: ","))
        return command
    }

    static func formatHint(for media: ResolvedMedia) -> String? {
        let declared = media.format?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let pathExtension = media.url.pathExtension.lowercased()
        if declared.contains("mpegurl")
            || declared == "m3u8"
            || declared == "hls"
            || pathExtension == "m3u8" {
            return "hls"
        }
        if declared.contains("dash") || declared == "mpd"
            || pathExtension == "mpd" {
            return "dash"
        }
        if declared == "mpegts" || declared == "video/mp2t"
            || declared == "ts" {
            return "mpegts"
        }
        return nil
    }

    static func isBridgeSession(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ),
              url.port == 19_978 else {
            return false
        }
        return url.path.hasPrefix("/proxy/media/")
            || url.path.hasPrefix("/v1/media-sessions/")
    }

    private static func fileOptions(
        for media: ResolvedMedia,
        omitFormatHint: Bool
    ) -> [String] {
        var options: [String]
        if isBridgeSession(media.url) {
            // The bridge already owns the remote connection and byte ranges.
            // A smaller forward/back window avoids retaining tens or hundreds
            // of megabytes from an abandoned seek while keeping enough data
            // for short backward jumps.
            options = [
                "cache=yes",
                "cache-secs=24",
                "demuxer-max-bytes=48MiB",
                "demuxer-max-back-bytes=12MiB",
                "demuxer-hysteresis-secs=3"
            ]
        } else {
            options = [
                "cache=auto",
                "cache-secs=36",
                "demuxer-max-bytes=64MiB",
                "demuxer-max-back-bytes=16MiB",
                "demuxer-hysteresis-secs=4"
            ]
        }
        if !omitFormatHint, let hint = formatHint(for: media) {
            options.append("demuxer-lavf-format=\(hint)")
        }
        return options
    }
}

enum MPVPlaybackErrorPolicy {
    static func userFacingMessage(nativeMessage: String) -> String {
        if nativeMessage == "no audio or video data played" {
            return L10n.string("player.error.no-media-data", fallback: "This source returned no playable audio or video data.")
        }
        return nativeMessage
    }
}

enum PlayerExperimentLogger {
    static func lifecycle(
        _ message: String,
        playerID: UUID?,
        requestID: UUID? = nil,
        mode: PlayerTeardownMode
    ) {
        write(
            category: "MPV-LIFECYCLE",
            message: message,
            playerID: playerID,
            requestID: requestID,
            mode: mode
        )
    }

    static func performance(
        _ message: String,
        playerID: UUID?,
        requestID: UUID?,
        mode: PlayerTeardownMode
    ) {
        write(
            category: "MPV-PERF",
            message: message,
            playerID: playerID,
            requestID: requestID,
            mode: mode
        )
    }

    static func failure(
        _ message: String,
        playerID: UUID?,
        requestID: UUID?,
        mode: PlayerTeardownMode
    ) {
        write(
            category: "MPV-ERROR",
            message: message,
            playerID: playerID,
            requestID: requestID,
            mode: mode
        )
    }

    private static func write(
        category: String,
        message: String,
        playerID: UUID?,
        requestID: UUID?,
        mode: PlayerTeardownMode
    ) {
        let timestamp = String(
            format: "%.3f",
            Date().timeIntervalSince1970
        )
        let player = playerID?.uuidString ?? "none"
        let request = requestID?.uuidString ?? "none"
        let line = "[\(category)] timestamp=\(timestamp)"
            + " player=\(player)"
            + " request=\(request)"
            + " mode=\(mode.rawValue) \(message)"
        NSLog("%@", line)
    }
}

final class PlayerStartupTraceStore {
    static let shared = PlayerStartupTraceStore()

    private struct Trace {
        let requestID: UUID
        let mode: PlayerTeardownMode
        let t0: TimeInterval
        var playerID: UUID?
        var t1: TimeInterval?
        var t2: TimeInterval?
        var t3: TimeInterval?
    }

    private let lock = NSLock()
    private var traces: [UUID: Trace] = [:]
    private var requestByPlayerID: [UUID: UUID] = [:]

    func begin(requestID: UUID, mode: PlayerTeardownMode) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        traces[requestID] = Trace(
            requestID: requestID,
            mode: mode,
            t0: now
        )
        lock.unlock()
        PlayerExperimentLogger.performance(
            "phase=click elapsed_ms=0",
            playerID: nil,
            requestID: requestID,
            mode: mode
        )
    }

    func markClientReady(requestID: UUID, playerID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard var trace = traces[requestID] else {
            lock.unlock()
            return
        }
        trace.playerID = playerID
        trace.t1 = now
        traces[requestID] = trace
        requestByPlayerID[playerID] = requestID
        lock.unlock()
        PlayerExperimentLogger.performance(
            "phase=client_ready click_to_client_ready_ms="
                + "\(milliseconds(now - trace.t0))",
            playerID: playerID,
            requestID: requestID,
            mode: trace.mode
        )
    }

    func markLoadfileIssued(requestID: UUID, playerID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard var trace = traces[requestID] else {
            lock.unlock()
            return
        }
        trace.playerID = playerID
        trace.t2 = now
        traces[requestID] = trace
        requestByPlayerID[playerID] = requestID
        lock.unlock()
        PlayerExperimentLogger.performance(
            "phase=loadfile click_to_loadfile_ms="
                + "\(milliseconds(now - trace.t0))",
            playerID: playerID,
            requestID: requestID,
            mode: trace.mode
        )
    }

    func markFileLoaded(requestID: UUID, playerID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard var trace = traces[requestID], trace.t3 == nil else {
            lock.unlock()
            return
        }
        trace.playerID = playerID
        trace.t3 = now
        traces[requestID] = trace
        requestByPlayerID[playerID] = requestID
        lock.unlock()
        PlayerExperimentLogger.performance(
            "phase=file_loaded click_to_file_loaded_ms="
                + "\(milliseconds(now - trace.t0))",
            playerID: playerID,
            requestID: requestID,
            mode: trace.mode
        )
    }

    @discardableResult
    func markFirstRenderSwap(playerID: UUID) -> UUID? {
        completePlaybackStart(playerID: playerID, phase: "first_render_swap")
    }

    @discardableResult
    func markTimelineProgress(playerID: UUID) -> UUID? {
        completePlaybackStart(playerID: playerID, phase: "timeline_progress")
    }

    private func completePlaybackStart(
        playerID: UUID,
        phase: String
    ) -> UUID? {
        let now = ProcessInfo.processInfo.systemUptime
        let completed: Trace?
        lock.lock()
        if let requestID = requestByPlayerID[playerID],
           let trace = traces[requestID],
           trace.t3 != nil {
            completed = trace
            traces[requestID] = nil
            requestByPlayerID[playerID] = nil
        } else {
            completed = nil
        }
        lock.unlock()

        guard let trace = completed,
              let t1 = trace.t1,
              let t2 = trace.t2,
              let t3 = trace.t3 else { return nil }
        let clientInit = milliseconds(t1 - trace.t0)
        let clickToLoadfile = milliseconds(t2 - trace.t0)
        let loadToFileLoaded = milliseconds(t3 - t2)
        let fileLoadedToCompletion = milliseconds(now - t3)
        let total = milliseconds(now - trace.t0)
        PlayerExperimentLogger.performance(
            "phase=\(phase) client_init_ms=\(clientInit)"
                + " click_to_loadfile_ms=\(clickToLoadfile)"
                + " loadfile_to_file_loaded_ms=\(loadToFileLoaded)"
                + " file_loaded_to_\(phase)_ms=\(fileLoadedToCompletion)"
                + " total_click_to_\(phase)_ms=\(total)",
            playerID: playerID,
            requestID: trace.requestID,
            mode: trace.mode
        )
        return trace.requestID
    }

    func cancel(playerID: UUID) {
        lock.lock()
        if let requestID = requestByPlayerID.removeValue(forKey: playerID) {
            traces[requestID] = nil
        }
        lock.unlock()
    }

    func cancel(requestID: UUID) {
        lock.lock()
        if let playerID = traces.removeValue(forKey: requestID)?.playerID,
           requestByPlayerID[playerID] == requestID {
            requestByPlayerID[playerID] = nil
        }
        lock.unlock()
    }

    private func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }
}

/// Owns the playback-start signal for the media currently loaded by one mpv
/// client. This is deliberately independent from performance tracing: a
/// failed candidate may clear its trace before the resolver tries the next
/// candidate with the same request ID, but that must never prevent the next
/// candidate from confirming real playback.
final class PlayerPlaybackStartSignal {
    private let lock = NSLock()
    private var requestID: UUID?
    private var fileLoaded = false
    private var wasClaimed = false
    private var requiresTimelineProgress = false

    func reset(requestID: UUID, requiresTimelineProgress: Bool = false) {
        lock.lock()
        self.requestID = requestID
        self.requiresTimelineProgress = requiresTimelineProgress
        fileLoaded = false
        wasClaimed = false
        lock.unlock()
    }

    func markFileLoaded() {
        lock.lock()
        fileLoaded = true
        lock.unlock()
    }

    func claimPlaybackStarted(fromRenderSwap: Bool = false) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard fileLoaded, !wasClaimed, let requestID,
              !(fromRenderSwap && requiresTimelineProgress) else { return nil }
        wasClaimed = true
        return requestID
    }

    func hasStartedPlayback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasClaimed
    }

    func cancel() {
        lock.lock()
        requestID = nil
        fileLoaded = false
        wasClaimed = false
        lock.unlock()
    }
}

enum PlayerSeekCompletionPolicy {
    static func accepts(target: TimeInterval, position: TimeInterval,
                        nativeSeeking: Bool, pausedForCache: Bool,
                        seekRestarted: Bool) -> Bool {
        // Readiness and keyframe accuracy are independent. Only the current
        // command's native seek lifecycle may release its waiting indicator.
        seekRestarted && target.isFinite && position.isFinite && target >= 0 && position >= 0
            && !nativeSeeking && !pausedForCache
    }
}

struct PlayerSeekActivityOwner {
    private var owner: (request: UInt64, seek: UInt64)?
    private var started = false
    private var restarted = false
    mutating func begin(request: UInt64, seek: UInt64) {
        owner = (request, seek); started = false; restarted = false
    }
    mutating func markStarted(request: UInt64, seek: UInt64) {
        guard owner?.request == request, owner?.seek == seek else { return }
        started = true
    }
    mutating func markRestarted(request: UInt64, seek: UInt64) {
        guard owner?.request == request, owner?.seek == seek, started else { return }
        restarted = true
    }
    func hasRestarted(request: UInt64, seek: UInt64) -> Bool {
        owner?.request == request && owner?.seek == seek && started && restarted
    }
    mutating func reset() { owner = nil; started = false; restarted = false }
}

enum PlayerSeekPolicy {
    static func target(
        requested: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard requested.isFinite, requested >= 0 else { return nil }
        guard duration.isFinite, duration > 0 else { return requested }
        return min(requested, duration)
    }
}

enum MPVPlaybackEndDisposition: Equatable {
    case natural
    case userSeekBoundary
    case premature
    case stopped
    case failed
    case ignored
}

enum MPVPlaybackEndPolicy {
    static func disposition(
        endFileReason: Int32,
        error: Int32 = 0,
        isReplacingMedia: Bool,
        hasStartedPlayback: Bool,
        isPausedForCache: Bool,
        position: TimeInterval,
        duration: TimeInterval,
        isProtectedByUserSeek: Bool,
        isUserSeekToBoundary: Bool = false,
        completionTolerance: TimeInterval = 3
    ) -> MPVPlaybackEndDisposition {
        guard !isReplacingMedia else { return .ignored }
        if endFileReason == 2 { return .stopped }
        if error < 0 { return .failed }
        guard endFileReason == 0 else { return .premature }
        if isProtectedByUserSeek {
            return isUserSeekToBoundary ? .userSeekBoundary : .premature
        }
        guard hasStartedPlayback,
              !isPausedForCache,
              position.isFinite,
              duration.isFinite else {
            return .premature
        }
        // Some finite VOD manifests do not publish duration until the native
        // EOF. A started, non-seeking request can still end naturally in that
        // case; request ownership and the post-seek guard provide the safety
        // boundaries instead of inventing a duration.
        guard duration > 0 else { return .natural }
        let tolerance = max(0, completionTolerance)
        return position >= max(0, duration - tolerance)
            ? .natural
            : .premature
    }
}

/// Interprets mpv's `eof-reached=yes` property when `keep-open=yes` keeps the
/// current file loaded and therefore may never emit `MPV_EVENT_END_FILE`.
/// Request ownership is deliberately part of the policy so a late property
/// notification from a replaced file cannot advance the new playlist.
enum MPVKeepOpenEOFPolicy {
    static func disposition(
        signalRequestGeneration: UInt64,
        currentRequestGeneration: UInt64,
        ownsActiveMedia: Bool,
        isReplacingMedia: Bool,
        hasStartedPlayback: Bool,
        isPausedForCache: Bool,
        position: TimeInterval,
        duration: TimeInterval,
        isProtectedByUserSeek: Bool,
        isUserSeekToBoundary: Bool,
        completionTolerance: TimeInterval = 3
    ) -> MPVPlaybackEndDisposition {
        guard signalRequestGeneration == currentRequestGeneration,
              ownsActiveMedia,
              !isReplacingMedia,
              hasStartedPlayback,
              !isPausedForCache,
              position.isFinite,
              duration.isFinite,
              duration > 0 else {
            return .ignored
        }
        return MPVPlaybackEndPolicy.disposition(
            endFileReason: 0,
            isReplacingMedia: false,
            hasStartedPlayback: true,
            isPausedForCache: false,
            position: position,
            duration: duration,
            isProtectedByUserSeek: isProtectedByUserSeek,
            isUserSeekToBoundary: isUserSeekToBoundary,
            completionTolerance: completionTolerance
        )
    }
}

/// Retains the semantic effect of a user seek after libmpv's instantaneous
/// `seeking` flag has returned to false. The guard expires only after native
/// playback has restarted and the media timeline has advanced continuously;
/// buffering wall-clock time never weakens it.
struct PlayerPostSeekEndGuard: Equatable {
    private struct Context: Equatable {
        let requestGeneration: UInt64
        let seekGeneration: UInt64
        let target: TimeInterval
        var didRestartPlayback = false
        var lastPosition: TimeInterval?
        var continuousForwardProgress: TimeInterval = 0
    }

    static let requiredForwardProgress: TimeInterval = 3
    static let maximumContinuousPositionDelta: TimeInterval = 5

    private(set) var latestSeekGeneration: UInt64 = 0
    private var context: Context?

    mutating func begin(
        requestGeneration: UInt64,
        target: TimeInterval
    ) -> UInt64 {
        latestSeekGeneration &+= 1
        context = Context(
            requestGeneration: requestGeneration,
            seekGeneration: latestSeekGeneration,
            target: target
        )
        return latestSeekGeneration
    }

    mutating func markPlaybackRestart(requestGeneration: UInt64) {
        guard var context,
              context.requestGeneration == requestGeneration else { return }
        context.didRestartPlayback = true
        context.lastPosition = nil
        context.continuousForwardProgress = 0
        self.context = context
    }

    mutating func observePosition(
        _ position: TimeInterval,
        requestGeneration: UInt64,
        isSeeking: Bool
    ) {
        guard position.isFinite,
              !isSeeking,
              var context,
              context.requestGeneration == requestGeneration else { return }
        if !context.didRestartPlayback {
            // A progressing timeline is itself proof that playback resumed on
            // sources which omit MPV_EVENT_PLAYBACK_RESTART.
            context.didRestartPlayback = true
            context.lastPosition = position
            context.continuousForwardProgress = 0
            self.context = context
            return
        }
        guard let previous = context.lastPosition else {
            context.lastPosition = position
            self.context = context
            return
        }

        let delta = position - previous
        if delta > 0,
           delta <= Self.maximumContinuousPositionDelta {
            context.continuousForwardProgress += delta
        } else if delta < 0
                    || delta > Self.maximumContinuousPositionDelta {
            // A second native jump or resync is not continuous playback.
            context.continuousForwardProgress = 0
        }
        context.lastPosition = position
        if context.continuousForwardProgress
            >= Self.requiredForwardProgress {
            self.context = nil
        } else {
            self.context = context
        }
    }

    mutating func cancel(
        requestGeneration: UInt64,
        seekGeneration: UInt64
    ) {
        guard context?.requestGeneration == requestGeneration,
              context?.seekGeneration == seekGeneration else { return }
        context = nil
    }

    mutating func reset() {
        context = nil
    }

    func permitsHistory(_ snapshot: PlayerSnapshot, requestGeneration: UInt64) -> Bool {
        if case .failed = snapshot.status { return false }
        return !snapshot.isSeeking && (!isProtecting(requestGeneration: requestGeneration)
            || isBoundarySeek(requestGeneration: requestGeneration,
                position: snapshot.position, duration: snapshot.duration))
    }

    func isProtecting(requestGeneration: UInt64) -> Bool {
        context?.requestGeneration == requestGeneration
    }

    func activeSeekGeneration(requestGeneration: UInt64) -> UInt64? {
        guard context?.requestGeneration == requestGeneration else {
            return nil
        }
        return context?.seekGeneration
    }

    func isBoundarySeek(
        requestGeneration: UInt64,
        position: TimeInterval,
        duration: TimeInterval,
        completionTolerance: TimeInterval = 3
    ) -> Bool {
        guard let context,
              context.requestGeneration == requestGeneration,
              context.target.isFinite,
              context.target >= 0,
              position.isFinite,
              duration.isFinite,
              duration > 0 else { return false }
        let boundary = max(0, duration - max(0, completionTolerance))
        // Native EOF position is an observation, not evidence of user intent.
        // A broken mid-file seek may itself report position == duration.
        return context.target >= boundary
    }

    func activeTarget(requestGeneration: UInt64) -> TimeInterval? {
        guard context?.requestGeneration == requestGeneration else { return nil }
        return context?.target
    }
}

/// Keep the last confirmed progress for this playback owner only. A failed
/// seek's native tail position must not replace the user's resumable history.
struct PlayerHistoryProgressCheckpoint {
    private var owner: UUID?
    private var progress: (position: TimeInterval, duration: TimeInterval)?
    mutating func reset(owner: UUID) { self.owner = owner; progress = nil }
    mutating func transferOwnership(to owner: UUID) { self.owner = owner }
    static func isReliable(_ snapshot: PlayerSnapshot) -> Bool {
        guard snapshot.status == .playing || snapshot.status == .paused || snapshot.status == .ended else { return false }
        return snapshot.historyProgressIsReliable && !snapshot.isSeeking
    }
    mutating func observe(_ snapshot: PlayerSnapshot, owner: UUID?) {
        guard owner == self.owner, owner != nil, Self.isReliable(snapshot),
              snapshot.position.isFinite, snapshot.duration.isFinite,
              snapshot.position >= 0, snapshot.duration >= 0 else { return }
        switch snapshot.status {
        case .playing, .paused, .ended: progress = (snapshot.position, snapshot.duration)
        default: break
        }
    }
    func resolve(position: TimeInterval, duration: TimeInterval, reliable: Bool,
                 owner: UUID) -> (position: TimeInterval, duration: TimeInterval)? {
        guard position.isFinite, duration.isFinite, position >= 0, duration >= 0 else { return nil }
        guard owner == self.owner else { return nil }
        if reliable { return (position, duration) }
        return progress
    }
}

/// Only numeric timeline observations enter seek diagnostics. No media URL,
/// title, headers, or native error payload is accepted by this formatter.
enum PlayerSeekDiagnostics {
    static func fields(
        position: TimeInterval,
        duration: TimeInterval,
        target: TimeInterval?,
        requested: TimeInterval? = nil,
        offset: TimeInterval? = nil
    ) -> String {
        func seconds(_ value: TimeInterval?) -> String {
            guard let value else { return "none" }
            guard value.isFinite else { return "nonfinite" }
            return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return "observed_position=\(seconds(position))"
            + " observed_duration=\(seconds(duration))"
            + " seek_target=\(seconds(target))"
            + " requested_position=\(seconds(requested))"
            + " relative_offset=\(seconds(offset))"
    }
}

enum PlayerSeekReadDiagnostics {
    static let environmentKey = "OKVIDEOMAC_SEEK_READ_DIAGNOSTICS"
    static let properties = ["time-pos", "audio-pts", "duration", "seekable", "partially-seekable",
                             "eof-reached", "seeking", "paused-for-cache", "demuxer-via-network",
                             "demuxer-cache-duration", "stream-pos", "file-size", "file-format"]

    static func route(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        if url.isFileURL { return "file" }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return "other" }
        if MPVTVBoxPlaybackPolicy.isBridgeSession(url) { return "bridge_session" }
        if SystemMediaProxyResolver.isLoopback(url.host ?? "") { return "loopback_http" }
        // Describes the entry URL, not a claim that OS/environment proxying is absent.
        return "remote_http"
    }

    static func property(_ name: String, value: String?) -> String {
        guard properties.contains(name), let value, value.utf8.count <= 256 else { return "unknown" }
        if name == "file-format" {
            return ["matroska", "webm", "matroska,webm", "mov", "mp4", "mov,mp4,m4a,3gp,3g2,mj2", "mpegts", "hls", "dash", "avi", "lavf"].contains(value)
                ? value : "other"
        }
        if ["seekable", "partially-seekable", "eof-reached", "seeking", "paused-for-cache", "demuxer-via-network"].contains(name) {
            return ["yes", "no"].contains(value) ? value : "unknown"
        }
        guard let number = Double(value), number.isFinite else { return "unknown" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    static func warning(prefix: String, level: Int32, text: String) -> String {
        // All output vocabulary is fixed; never return arbitrary substrings.
        let component = ["ffmpeg", "demux", "lavf", "cplayer", "vd", "ad", "stream"].first {
            prefix == $0 || prefix.hasPrefix($0 + "/")
        } ?? "other"
        let severity = [10: "fatal", 20: "error", 30: "warn"][Int(level)] ?? "other"
        let message = String(text.prefix(4096)).lowercased()
        let rules: [(String, String)] = [
            ("stream ends prematurely", "short_read"), ("partial file", "partial_file"),
            ("http error", "http_error"), ("failed to seek", "seek_failed"),
            ("seek failed", "seek_failed"), ("not seekable", "not_seekable"),
            ("invalid data", "invalid_data"), ("moov atom not found", "missing_index"),
            ("index", "index_warning"), ("connection reset", "connection_reset"),
            ("timed out", "timeout"), ("end of file", "eof"),
            ("error reading", "read_error"), ("failed to read", "read_error"),
            ("failed to open", "open_failed"), ("decode", "decode_error")
        ]
        let category = rules.first { message.contains($0.0) }?.1 ?? "unclassified"
        var result = "component=\(component) severity=\(severity) issue=\(category)"
        func numbers(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
            var output: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: message),
                      let number = UInt64(message[range]) else { return nil }
                output.append(String(number))
            }
            return output
        }
        if let fields = numbers(#"stream ends prematurely at ([0-9]{1,20}), should be ([0-9]{1,20})(?![0-9])"#) {
            result += " stream_end_offset=\(fields[0]) expected_end_offset=\(fields[1])"
        }
        if let status = numbers(#"http error ([1-5][0-9]{2})(?![0-9])"#)?.first {
            result += " http_status=\(status)"
        }
        return result
    }
}

struct PlayerSeekReadWindow {
    let requestGeneration: UInt64
    let seekGeneration: UInt64
    let deadline: TimeInterval
    private(set) var remaining = 24

    mutating func consume(request: UInt64, seek: UInt64, now: TimeInterval) -> Bool {
        guard request == requestGeneration, seek == seekGeneration,
              now.isFinite, now < deadline, remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

final class MPVPlayerClient: PlayerClient {
    let events: AsyncStream<PlayerEvent>
    let renderOwnerID = UUID()
    let teardownMode: PlayerTeardownMode
    let performanceProfile: MPVPlaybackPerformanceProfile
    let renderControlMode: MPVRenderControlMode

    private enum LifecycleState {
        case running
        case shuttingDown
        case shutdown
    }

    private enum NativeFormat {
        static let string: Int32 = 1
        static let flag: Int32 = 3
        static let int64: Int32 = 4
        static let double: Int32 = 5
    }

    private enum NativeEvent {
        static let logMessage: Int32 = 2
        static let none: Int32 = 0
        static let shutdown: Int32 = 1
        static let endFile: Int32 = 7
        static let fileLoaded: Int32 = 8
        static let seek: Int32 = 20
        static let playbackRestart: Int32 = 21
        static let propertyChange: Int32 = 22
        static let queueOverflow: Int32 = 24
    }

    let compatibilityPolicy: PlaybackCompatibilityPolicy
    private let library: MPVLibrary
    private let queue = DispatchQueue(
        label: "com.okvideomac.player.libmpv",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private let lifecycleLock = NSLock()
    private let playbackStartSignal = PlayerPlaybackStartSignal()
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var client: OpaquePointer?
    private var snapshot = PlayerSnapshot()
    private var lifecycleState = LifecycleState.running
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var mediaReleaseWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var renderDetachWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRequestID: UUID?
    private var activeMediaRequestID: UUID?
    private var replacingMediaRequestID: UUID?
    private var isReplacingMedia = false
    private var didEmitEndedForCurrentMedia = false
    private var pendingStartPosition: TimeInterval?
    private var pendingSubtitles: [URL] = []
    private var didEmitFileLoadedForCurrentMedia = false
    private var startupTimelinePosition: Double?
    private var diagnosticsGeneration = UUID()
    private let seekReadDiagnosticsEnabled = ProcessInfo.processInfo.environment[PlayerSeekReadDiagnostics.environmentKey] == "1"
    private var seekReadWindow: PlayerSeekReadWindow?
    private var currentMediaTransportProfile: MediaTransportProfile = .standard
    private var currentMedia: ResolvedMedia?
    private var currentNetworkOptions: [(String, String)] = []
    private let mediaProxyResolver: @Sendable (ResolvedMedia) -> MediaProxyDecision?
    private var tvBoxFormatFallbackAvailable = false
    private var playbackRequestGeneration: UInt64 = 0
    private var postSeekEndGuard = PlayerPostSeekEndGuard()
    private var seekActivityOwner = PlayerSeekActivityOwner()
    private var pendingEOFSignal: (
        requestGeneration: UInt64,
        seekGeneration: UInt64?
    )?
    private var completedTVBoxSeekGeneration: UInt64?
    private var renderContextCount = 0
    private var pendingLoad: (
        identifier: UUID,
        supportsCancellation: Bool,
        continuation: CheckedContinuation<Void, Error>
    )?
    private var lastEmittedSnapshot: PlayerSnapshot?
    private var lastTimelineEmissionUptime: UInt64 = 0
    private var timelineEmissionScheduled = false
    private let timelineEmissionIntervalNanoseconds: UInt64 = 100_000_000

    init(
        bundle: Bundle = .main,
        teardownMode: PlayerTeardownMode = .warmStop,
        performanceProfile: MPVPlaybackPerformanceProfile = .configured(),
        renderControlMode: MPVRenderControlMode = .configured(),
        compatibilityPolicy: PlaybackCompatibilityPolicy = .existing,
        audioPreference: PlaybackAudioPreference = .init(),
        mediaProxyResolver: @escaping @Sendable (ResolvedMedia) -> MediaProxyDecision? = {
            PlayerMediaNetworkPolicy.decision(for: $0)
        }
    ) throws {
        snapshot = PlayerSnapshot(volume: audioPreference.volume, isMuted: audioPreference.muted)
        self.mediaProxyResolver = mediaProxyResolver
        self.compatibilityPolicy = compatibilityPolicy
        self.teardownMode = teardownMode
        self.performanceProfile = performanceProfile
        self.renderControlMode = renderControlMode
        var captured: AsyncStream<PlayerEvent>.Continuation!
        // Keep the bridge bounded even if the main actor is briefly busy with
        // a menu, window transition, or a slow database operation.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            captured = $0
        }
        continuation = captured
        library = try MPVLibrary(bundle: bundle)
        queue.setSpecific(key: queueKey, value: queueValue)
        PlayerExperimentLogger.lifecycle(
            "create client",
            playerID: renderOwnerID,
            mode: teardownMode
        )
        guard let created = library.create() else {
            throw AppError.playback(L10n.string("player.runtime.client-create.failed", fallback: "Unable to create the libmpv client."))
        }
        client = created

        do {
            try setOption("config", value: "no", client: created)
            try setOption("terminal", value: "no", client: created)
            // These path-bearing features vary across supported libmpv
            // versions. Disable every option the bundled runtime recognizes;
            // only a genuine "option not found" is compatibility-skippable.
            // Invalid values and all other failures still abort initialization.
            for option in [
                ("load-scripts", "no"),
                ("resume-playback", "no"),
                ("save-position-on-quit", "no"),
                ("save-watch-history", "no"),
                ("write-filename-in-watch-later-config", "no"),
                ("log-file", "")
            ] {
                _ = try setOptionIfAvailable(
                    option.0, value: option.1, client: created
                )
            }
            try setOption("input-default-bindings", value: "no", client: created)
            try setOption("input-cursor", value: "no", client: created)
            try setOption("idle", value: "yes", client: created)
            try setOption("keep-open", value: "yes", client: created)
            try setOption("sid", value: "no", client: created)
            try setOption("vo", value: "libmpv", client: created)
            try setOption("hwdec", value: "auto-safe", client: created)
            for option in performanceProfile.mpvOptions {
                try setOption(option.name, value: option.value, client: created)
            }
            if renderControlMode.usesAdvancedControl {
                // Required by MPV_RENDER_PARAM_ADVANCED_CONTROL for supported
                // decoders to allocate caller-compatible frame surfaces.
                try setOption("vd-lavc-dr", value: "yes", client: created)
            }
            try setOption("volume-max", value: "130", client: created)
            try setOption("volume", value: String(audioPreference.volume), client: created)
            try setOption("mute", value: audioPreference.muted ? "yes" : "no", client: created)
            try setOption("audio-client-name", value: "OKVideoMac", client: created)
            // Prefer full Chinese subtitles over the short English "forced"
            // track that many remuxes mark as the container default.
            try setOption("slang", value: "zh-Hans,zh-CN,cmn-Hans,zh,chi,zho", client: created)
            try setOption("subs-with-matching-audio", value: "yes", client: created)
            try library.checked(
                library.initialize(created),
                operation: L10n.string("player.operation.initialize", fallback: "Initialize libmpv")
            )
            PlayerExperimentLogger.lifecycle(
                "initialize performance_profile=\(performanceProfile.rawValue)"
                    + " render_control=\(renderControlMode.rawValue)",
                playerID: renderOwnerID,
                mode: teardownMode
            )
            try installPropertyObservers(client: created)
        } catch {
            library.destroy(created)
            client = nil
            continuation.finish()
            throw error
        }

        queue.async { [weak self] in
            self?.pollEvents()
        }
    }

    deinit {
        let fallbackClient: OpaquePointer?
        lifecycleLock.lock()
        if lifecycleState != .shutdown, renderContextCount == 0 {
            lifecycleState = .shutdown
            fallbackClient = client
            client = nil
        } else {
            fallbackClient = nil
        }
        lifecycleLock.unlock()

        if let fallbackClient {
            let destroyCore = {
                self.library.wakeup(fallbackClient)
                self.library.destroy(fallbackClient)
            }
            if DispatchQueue.getSpecific(key: queueKey) == queueValue {
                destroyCore()
            } else {
                queue.sync(execute: destroyCore)
            }
        }
        continuation.finish()
    }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID
    ) async throws {
        try await load(
            media,
            startPosition: startPosition,
            requestID: requestID,
            aspectRatio: nil,
            panscan: 0
        )
    }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID,
        aspectRatio: String?,
        panscan: Double
    ) async throws {
        try Task.checkCancellation()
        guard media.compatibilityPolicy == compatibilityPolicy else {
            throw AppError.playback("Playback policy requires a fresh player instance.")
        }
        try validate(media: media)
        let proxyDecision = mediaProxyResolver(media)
        let supportsCancellation = PlayerMediaNetworkPolicy.usesSystemProxy(media)
        let loadTimeoutSeconds = PlayerLoadTimeoutPolicy.seconds(for: media)
        let cancellation = NativeLoadCancellation()
        let identifier = UUID()
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if supportsCancellation, cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.isRunning, let client = self.client else {
                    continuation.resume(
                        throwing: AppError.playback(L10n.string("player.runtime.closed", fallback: "libmpv has closed."))
                    )
                    return
                }
                if let pending = self.pendingLoad {
                    self.pendingLoad = nil
                    pending.continuation.resume(
                        throwing: AppError.playback(L10n.string("player.request.replaced", fallback: "The playback request was replaced by a newer request."))
                    )
                }
                let previousRequestID = self.currentRequestID
                let previousMedia = self.currentMedia
                let previousNetworkOptions = self.currentNetworkOptions
                let previousTransportProfile = self.currentMediaTransportProfile
                let previousSnapshot = self.snapshot
                let previousDidEmitEnded = self.didEmitEndedForCurrentMedia
                let previousDidEmitFileLoaded = self.didEmitFileLoadedForCurrentMedia
                self.endSeekReadDiagnostics()
                self.playbackRequestGeneration &+= 1
                self.replacingMediaRequestID = self.activeMediaRequestID
                self.currentRequestID = requestID
                self.pendingLoad = (identifier, supportsCancellation, continuation)
                do {
                    try self.applyViewport(
                        aspectRatio: aspectRatio,
                        panscan: panscan,
                        client: client
                    )
                    if let proxyDecision {
                        PlayerExperimentLogger.lifecycle(
                            "media transport=\(proxyDecision.diagnosticMode) scope=file",
                            playerID: self.renderOwnerID, requestID: requestID,
                            mode: self.teardownMode
                        )
                    }
                    try self.applyHTTPHeaders(media.headers, client: client)
                    self.pendingStartPosition = startPosition.flatMap {
                        $0.isFinite && $0 > 0 ? $0 : nil
                    }
                    self.pendingSubtitles = media.subtitles
                    self.currentMediaTransportProfile = media.transportProfile
                    self.currentMedia = media
                    self.currentNetworkOptions = proxyDecision?.mpvOptions ?? []
                    self.tvBoxFormatFallbackAvailable = media.transportProfile == .tvBox
                        && MPVTVBoxPlaybackPolicy.formatHint(for: media) != nil
                    self.postSeekEndGuard.reset()
                    self.seekActivityOwner.reset()
                    self.pendingEOFSignal = nil
                    self.completedTVBoxSeekGeneration = nil
                    self.isReplacingMedia = true
                    self.didEmitEndedForCurrentMedia = false
                    self.didEmitFileLoadedForCurrentMedia = false
                    self.startupTimelinePosition = nil
                    self.diagnosticsGeneration = UUID()
                    self.playbackStartSignal.reset(requestID: requestID, requiresTimelineProgress: media.transportProfile == .tvBox)
                    self.snapshot.position = 0
                    self.snapshot.positionSampleUptime = nil
                    self.snapshot.duration = 0
                    self.snapshot.bufferedPercent = 0
                    self.snapshot.networkSpeedBytesPerSecond = 0
                    self.snapshot.isSeeking = false
                    self.snapshot.isPausedForCache = false
                    self.snapshot.seekTarget = nil
                    self.snapshot.videoWidth = 0
                    self.snapshot.videoHeight = 0
                    self.snapshot.status = .loading
                    self.emitSnapshot()
                    PlayerStartupTraceStore.shared.markLoadfileIssued(
                        requestID: requestID,
                        playerID: self.renderOwnerID
                    )
                    try self.command(
                        MPVTVBoxPlaybackPolicy.loadCommand(
                            for: media, startPosition: self.pendingStartPosition,
                            networkOptions: self.currentNetworkOptions
                        ),
                        client: client
                    )
                } catch {
                    PlayerStartupTraceStore.shared.cancel(
                        requestID: requestID
                    )
                    // A synchronous command rejection occurs before libmpv
                    // accepts the replacement. Restore the still-active media
                    // identity and snapshot so AppState can keep its lease.
                    self.currentRequestID = previousRequestID
                    self.currentMedia = previousMedia
                    self.currentNetworkOptions = previousNetworkOptions
                    self.currentMediaTransportProfile = previousTransportProfile
                    self.snapshot = previousSnapshot
                    self.didEmitEndedForCurrentMedia = previousDidEmitEnded
                    self.didEmitFileLoadedForCurrentMedia = previousDidEmitFileLoaded
                    self.replacingMediaRequestID = nil
                    self.isReplacingMedia = false
                    self.pendingStartPosition = nil
                    self.pendingSubtitles = []
                    self.emitSnapshot()
                    self.completeLoad(.failure(error))
                    return
                }
                self.queue.asyncAfter(
                    deadline: .now() + .seconds(loadTimeoutSeconds)
                ) {
                    guard self.pendingLoad?.identifier == identifier else {
                        return
                    }
                    let error = AppError.playback(
                        L10n.string("player.load.timeout", fallback: "libmpv media loading timed out after %lld seconds.", loadTimeoutSeconds)
                    )
                    self.snapshot.status = .failed(error.localizedDescription)
                    self.emitSnapshot()
                    self.completeLoad(.failure(error))
                    _ = try? self.command(["stop"], client: client)
                }
            }
        }
        } onCancel: {
            if supportsCancellation {
                cancellation.cancel()
                self.cancelPendingMediaLoad(requestID: requestID, loadIdentifier: identifier)
            }
        }
    }

    /// Lifecycle calls retire the owned request before its successor is queued.
    /// Task cancellation additionally binds the exact load, since a retry may
    /// reuse a request ID. Unmanaged providers keep their existing behavior.
    func cancelPendingMediaLoad(requestID: UUID?, loadIdentifier: UUID? = nil) {
        guard let requestID else { return }
        queue.async {
            guard self.currentRequestID == requestID,
                  let pending = self.pendingLoad, pending.supportsCancellation,
                  loadIdentifier == nil || pending.identifier == loadIdentifier,
                  let client = self.client else { return }
            self.completeLoad(.failure(CancellationError()))
            _ = try? self.command(["stop"], client: client)
        }
    }

    func play() async throws {
        try await setFlagProperty(
            "pause",
            value: false,
            operation: L10n.string("player.operation.play", fallback: "Resume playback")
        ) { snapshot in
            snapshot.status = .playing
        }
    }

    func pause() async throws {
        try await setFlagProperty(
            "pause",
            value: true,
            operation: L10n.string("player.operation.pause", fallback: "Pause playback")
        ) { snapshot in
            snapshot.status = .paused
        }
    }

    func stop() async {
        playbackStartSignal.cancel()
        PlayerExperimentLogger.lifecycle(
            "stop begin",
            playerID: renderOwnerID,
            requestID: nil,
            mode: teardownMode
        )
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.isRunning, let client = self.client else {
                    continuation.resume()
                    return
                }
                let releasedRequestID = self.activeMediaRequestID
                if let releasedRequestID {
                    self.mediaReleaseWaiters[releasedRequestID, default: []]
                        .append(continuation)
                }
                self.completeLoad(.failure(CancellationError()))
                self.diagnosticsGeneration = UUID()
                do {
                    try self.command(["stop"], client: client)
                    self.clearTransientPlaybackActivity()
                    self.snapshot.status = .stopped
                    self.emitSnapshot()
                    if releasedRequestID == nil {
                        continuation.resume()
                    }
                } catch {
                    if let releasedRequestID {
                        self.resumeMediaReleaseWaiters(
                            requestID: releasedRequestID
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        PlayerExperimentLogger.lifecycle(
            "stop end",
            playerID: renderOwnerID,
            requestID: nil,
            mode: teardownMode
        )
    }

    func seek(to position: TimeInterval) async throws {
        try await perform { client in
            // Retire queued native events before assigning a new UI owner.
            // All command/event processing is serialized on this queue.
            self.drainNativeEvents(limit: 4096)
            guard let target = PlayerSeekPolicy.target(
                requested: position,
                duration: self.snapshot.duration
            ) else {
                throw AppError.playback(L10n.string("player.seek.invalid-position", fallback: "The seek position is invalid."))
            }
            self.snapshot.isSeeking = true
            self.snapshot.seekTarget = target
            let requestGeneration = self.playbackRequestGeneration
            let seekGeneration = self.postSeekEndGuard.begin(
                requestGeneration: requestGeneration,
                target: target
            )
            PlayerExperimentLogger.performance(
                "phase=seek_command request_generation=\(requestGeneration)"
                    + " seek_generation=\(seekGeneration)"
                    + " tvbox=\(self.currentMediaTransportProfile == .tvBox) "
                    + PlayerSeekDiagnostics.fields(
                        position: self.snapshot.position,
                        duration: self.snapshot.duration,
                        target: target,
                        requested: position
                    ),
                playerID: self.renderOwnerID,
                requestID: self.currentRequestID,
                mode: self.teardownMode
            )
            let tvBoxGeneration: UInt64?
            if self.currentMediaTransportProfile == .tvBox {
                self.completedTVBoxSeekGeneration = nil
                self.seekActivityOwner.begin(request: requestGeneration, seek: seekGeneration)
                tvBoxGeneration = seekGeneration
            } else {
                tvBoxGeneration = nil
            }
            self.emitSnapshot()
            do {
                self.beginSeekReadDiagnostics(request: requestGeneration, seek: seekGeneration)
                self.logSeekReadState(phase: "seek_read_before")
                try self.command(Self.seekCommand(to: target, duration: self.snapshot.duration), client: client)
                if let tvBoxGeneration {
                    self.queue.asyncAfter(deadline: .now() + .seconds(15)) {
                        guard self.currentMediaTransportProfile == .tvBox,
                              self.playbackRequestGeneration
                                == requestGeneration,
                              self.postSeekEndGuard.activeSeekGeneration(
                                requestGeneration: requestGeneration
                              ) == tvBoxGeneration,
                              self.completedTVBoxSeekGeneration
                                != tvBoxGeneration,
                              self.snapshot.isSeeking else { return }
                        self.refreshTVBoxSeekCompletion()
                        guard self.snapshot.seekTarget != nil else { return }
                        self.logSeekObservation(phase: "seek_ui_deadline")
                        self.snapshot.isSeeking = false
                        self.snapshot.status = .failed(L10n.string("player.seek.wait-timeout", fallback: "Seeking is taking too long. Retry this position or choose another position."))
                        self.emitSnapshot()
                    }
                }
            } catch {
                self.logSeekObservation(phase: "seek_command_failed")
                self.endSeekReadDiagnostics()
                self.postSeekEndGuard.cancel(
                    requestGeneration: requestGeneration,
                    seekGeneration: seekGeneration
                )
                self.seekActivityOwner.reset()
                self.snapshot.isSeeking = false
                self.snapshot.seekTarget = nil
                self.emitSnapshot()
                throw error
            }
        }
    }

    static func seekCommand(to position: TimeInterval, duration: TimeInterval? = nil) -> [String] {
        let targetValue = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            position
        )
        let isEnd = duration.map { $0.isFinite && $0 > 0 && position >= $0 } ?? false
        return ["seek", targetValue, isEnd ? "absolute+exact" : "absolute+keyframes"]
    }

    func setVolume(_ volume: Double) async throws {
        let clampedVolume = min(max(volume, 0), 130)
        try await setDoubleProperty(
            "volume",
            value: clampedVolume,
            operation: L10n.string("player.operation.set-volume", fallback: "Set volume")
        ) { snapshot in
            snapshot.volume = clampedVolume
        }
    }

    func setMuted(_ muted: Bool) async throws {
        try await setFlagProperty(
            "mute",
            value: muted,
            operation: L10n.string("player.operation.set-mute", fallback: "Set mute")
        ) { snapshot in
            snapshot.isMuted = muted
        }
    }

    func setSpeed(_ speed: Double) async throws {
        guard speed.isFinite, (0.25...4).contains(speed) else {
            throw AppError.playback(L10n.string("player.speed.invalid", fallback: "Playback speed must be between 0.25x and 4x."))
        }
        try await setDoubleProperty(
            "speed",
            value: speed,
            operation: L10n.string("player.operation.set-speed", fallback: "Set playback speed")
        ) { snapshot in
            snapshot.speed = speed
        }
    }

    func selectTrack(id: Int, type: MediaTrackType) async throws {
        let property: String
        switch type {
        case .video: property = "vid"
        case .audio: property = "aid"
        case .subtitle: property = "sid"
        }
        try await setStringProperty(
            property,
            value: id > 0 ? String(id) : "no",
            operation: L10n.string("player.operation.select-track", fallback: "Select media track")
        )
    }

    func addSubtitle(url: URL) async throws {
        guard url.isFileURL || ["http", "https"].contains(
            url.scheme?.lowercased() ?? ""
        ) else {
            throw AppError.playback(L10n.string("player.subtitle.url.invalid", fallback: "Subtitles must be a user-selected file or an HTTP/HTTPS URL."))
        }
        try await perform { client in
            try self.command(
                ["sub-add", url.absoluteString, "select"],
                client: client
            )
        }
    }

    func setSubtitleDelay(_ delay: TimeInterval) async throws {
        try await setDoubleProperty(
            "sub-delay",
            value: delay,
            operation: L10n.string("player.operation.set-subtitle-delay", fallback: "Set subtitle delay")
        )
    }

    func setSubtitleScale(_ scale: Double) async throws {
        guard scale.isFinite, (0.5...3).contains(scale) else {
            throw AppError.playback(L10n.string("player.subtitle.scale.invalid", fallback: "Subtitle size must be between 50% and 300%."))
        }
        try await setDoubleProperty(
            "sub-scale",
            value: scale,
            operation: L10n.string("player.operation.set-subtitle-size", fallback: "Set subtitle size")
        )
    }

    func setSubtitlePosition(_ position: Double) async throws {
        guard position.isFinite, (0...100).contains(position) else {
            throw AppError.playback(L10n.string("player.subtitle.position.invalid", fallback: "Subtitle position must be between 0 and 100."))
        }
        try await setDoubleProperty(
            "sub-pos",
            value: position,
            operation: L10n.string("player.operation.set-subtitle-position", fallback: "Set subtitle position")
        )
    }

    func setSubtitleBorderSize(_ size: Double) async throws {
        guard size.isFinite, (0...10).contains(size) else {
            throw AppError.playback(L10n.string("player.subtitle.outline.invalid", fallback: "Subtitle outline must be between 0 and 10."))
        }
        try await setDoubleProperty(
            "sub-border-size",
            value: size,
            operation: L10n.string("player.operation.set-subtitle-outline", fallback: "Set subtitle outline")
        )
    }

    func setAudioDelay(_ delay: TimeInterval) async throws {
        try await setDoubleProperty(
            "audio-delay",
            value: delay,
            operation: L10n.string("player.operation.set-audio-delay", fallback: "Set audio delay")
        )
    }

    func setAspectRatio(_ ratio: String?) async throws {
        let value = ratio?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await setStringProperty(
            "video-aspect-override",
            value: value?.isEmpty == false ? value! : "-1",
            operation: L10n.string("player.operation.set-aspect-ratio", fallback: "Set aspect ratio")
        )
    }

    func setHardwareDecoding(enabled: Bool) async throws {
        try await setStringProperty(
            "hwdec",
            value: enabled ? "auto-safe" : "no",
            operation: L10n.string("player.operation.set-hardware-decoding", fallback: "Set hardware decoding")
        )
    }

    func screenshot(to url: URL) async throws {
        guard url.isFileURL else {
            throw AppError.playback(L10n.string("player.screenshot.target.invalid", fallback: "The screenshot destination must be a local file."))
        }
        try await perform { client in
            try self.command(
                ["screenshot-to-file", url.path, "subtitles"],
                client: client
            )
        }
    }

#if DEBUG || OKVIDEO_PERFORMANCE_TEST
    /// Only invoked by the explicit local calibration test; never by playback.
    func enableLocalRenderDiagnosticsForTesting() async throws {
        try await setStringProperty("terminal", value: "yes", operation: "Enable local test diagnostics")
        try await setStringProperty("msg-level", value: "all=warn", operation: "Enable local test warnings")
    }

    func diagnosticPropertyForTesting(_ name: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.isRunning, let client = self.client else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.propertyString(name, client: client))
            }
        }
    }
#endif

    func shutdown() async {
        playbackStartSignal.cancel()
        guard beginShutdown() else {
            await waitForShutdownCompletion()
            return
        }

        let renderOwnerID = renderOwnerID.uuidString
        await MainActor.run {
            NotificationCenter.default.post(
                name: .mpvPlayerWillShutdown,
                object: nil,
                userInfo: ["renderOwnerID": renderOwnerID]
            )
        }
        await waitForRenderContextsToDetach()

        await withCheckedContinuation { completion in
            queue.async {
                self.completeLoad(.failure(CancellationError()))
                self.diagnosticsGeneration = UUID()
                if let client = self.client {
                    _ = try? self.command(["stop"], client: client)
                    self.library.wakeup(client)
                    self.library.destroy(client)
                    PlayerExperimentLogger.lifecycle(
                        "mpv client destroyed",
                        playerID: self.renderOwnerID,
                        requestID: self.currentRequestID,
                        mode: self.teardownMode
                    )
                    self.client = nil
                }
                self.currentRequestID = nil
                self.continuation.finish()
                self.markShutdownComplete()
                completion.resume()
            }
        }
    }

    func makeRenderContext(
        getProcAddress: MPVGetProcAddress?,
        context: UnsafeMutableRawPointer?
    ) throws -> OpaquePointer {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let client, lifecycleState == .running else {
            throw AppError.playback(L10n.string("player.runtime.closed", fallback: "libmpv has closed."))
        }
        var renderContext: OpaquePointer?
        try library.checked(
            library.renderCreate(
                client,
                getProcAddress,
                context,
                renderControlMode.usesAdvancedControl ? 1 : 0,
                &renderContext
            ),
            operation: L10n.string("player.operation.create-render-context", fallback: "Create mpv OpenGL Render Context")
        )
        guard let renderContext else {
            throw AppError.playback(L10n.string("player.runtime.render-context-missing", fallback: "mpv did not return a Render Context."))
        }
        renderContextCount += 1
        PlayerExperimentLogger.lifecycle(
            "create render context control=\(renderControlMode.rawValue)",
            playerID: renderOwnerID,
            requestID: nil,
            mode: teardownMode
        )
        return renderContext
    }

    func setRenderUpdateCallback(
        renderContext: OpaquePointer,
        callback: MPVRenderUpdateCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        library.renderSetUpdateCallback(renderContext, callback, context)
    }

    func renderUpdate(_ renderContext: OpaquePointer) -> UInt64 {
        library.renderUpdate(renderContext)
    }

    func render(
        _ renderContext: OpaquePointer,
        framebuffer: Int32,
        width: Int32,
        height: Int32,
        flipY: Bool
    ) throws {
        try library.checked(
            library.render(
                renderContext,
                framebuffer,
                width,
                height,
                flipY ? 1 : 0
            ),
            operation: L10n.string("player.operation.render-frame", fallback: "Render video frame")
        )
    }

    func reportSwap(_ renderContext: OpaquePointer) {
        library.renderReportSwap(renderContext)
        if let requestID = playbackStartSignal.claimPlaybackStarted(fromRenderSwap: true) {
            PlayerStartupTraceStore.shared.markFirstRenderSwap(
                playerID: renderOwnerID
            )
            continuation.yield(.playbackStarted(requestID: requestID))
            queue.async { [weak self] in
                guard let self, let signal = self.pendingEOFSignal else {
                    return
                }
                self.handleKeepOpenEOFSignal(signal)
            }
        }
    }

    func skipRender(_ renderContext: OpaquePointer) throws {
        try library.checked(
            library.renderSkip(renderContext),
            operation: L10n.string("player.operation.skip-frame", fallback: "Skip hidden video frame")
        )
    }

    func destroyRenderContext(_ renderContext: OpaquePointer) {
        library.renderSetUpdateCallback(renderContext, nil, nil)
        library.renderDestroy(renderContext)
        PlayerExperimentLogger.lifecycle(
            "render context freed",
            playerID: renderOwnerID,
            requestID: nil,
            mode: teardownMode
        )
        let waiters: [CheckedContinuation<Void, Never>]
        lifecycleLock.lock()
        renderContextCount = max(0, renderContextCount - 1)
        if renderContextCount == 0 {
            waiters = renderDetachWaiters
            renderDetachWaiters.removeAll()
        } else {
            waiters = []
        }
        lifecycleLock.unlock()
        waiters.forEach { $0.resume() }
    }

    var runtimeDescription: String {
        "libmpv client API \(library.version)"
    }

    /// libmpv exposes subtitle entries in `track-list` with the type `sub`,
    /// while the app-facing model deliberately uses the clearer `subtitle`
    /// spelling. Keep the native vocabulary at this boundary so subtitle
    /// tracks are not silently discarded during snapshot refreshes.
    static func mediaTrackType(forMPVValue value: String) -> MediaTrackType? {
        switch value {
        case "video":
            return .video
        case "audio":
            return .audio
        case "sub":
            return .subtitle
        default:
            return nil
        }
    }

    /// Select a useful full subtitle by default. Container defaults frequently
    /// point at a short English forced-signs track, which looks to the user as
    /// though subtitles are broken even though several complete Chinese tracks
    /// are present.
    static func preferredSubtitleTrack(in tracks: [MediaTrack]) -> MediaTrack? {
        tracks
            .filter { $0.type == .subtitle }
            .max { subtitleScore($0) < subtitleScore($1) }
    }

    private static func subtitleScore(_ track: MediaTrack) -> Int {
        let title = track.title.lowercased()
        let language = track.language?.lowercased() ?? ""
        let combined = title + " " + language
        let forced = combined.contains("forced") || combined.contains("强制")
        var score = forced ? -10_000 : 0

        if combined.contains("cmn-hans")
            || combined.contains("zh-hans")
            || combined.contains("zh-cn")
            || combined.contains("简体")
            || combined.contains("简中")
            || combined.contains("chs") {
            score += 4_000
        } else if combined.contains("zh")
                    || combined.contains("chi")
                    || combined.contains("zho")
                    || combined.contains("chinese")
                    || combined.contains("中文")
                    || combined.contains("中字") {
            score += 3_000
        } else if track.isSelected {
            score += 1_000
        }
        return score - track.id
    }

    private func perform<Result>(
        _ operation: @escaping (OpaquePointer) throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Result, Error>) in
            queue.async {
                guard self.isRunning, let client = self.client else {
                    continuation.resume(
                        throwing: AppError.playback(L10n.string("player.runtime.closed", fallback: "libmpv has closed."))
                    )
                    return
                }
                do {
                    continuation.resume(returning: try operation(client))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setOption(
        _ name: String,
        value: String,
        client: OpaquePointer
    ) throws {
        try name.withCString { namePointer in
            try value.withCString { valuePointer in
                try library.checked(
                    library.setOptionString(client, namePointer, valuePointer),
                    operation: L10n.string("player.operation.set-option", fallback: "Set mpv option %@", name)
                )
            }
        }
    }

    @discardableResult
    private func setOptionIfAvailable(
        _ name: String,
        value: String,
        client: OpaquePointer
    ) throws -> Bool {
        let result = name.withCString { namePointer in
            value.withCString { valuePointer in
                library.setOptionString(client, namePointer, valuePointer)
            }
        }
        if result >= 0 { return true }
        if library.errorString(for: result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "option not found" {
            return false
        }
        try library.checked(
            result,
            operation: L10n.string(
                "player.operation.set-option",
                fallback: "Set mpv option %@",
                name
            )
        )
        return true
    }

    private func schedulePlaybackDiagnostics(requestID: UUID) {
        let generation = diagnosticsGeneration
        for delay in [2.0, 15.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isRunning,
                      self.diagnosticsGeneration == generation,
                      self.currentRequestID == requestID,
                      let client = self.client else { return }
                self.logPlaybackDiagnostics(
                    requestID: requestID,
                    elapsedSeconds: Int(delay),
                    client: client
                )
            }
        }
    }

    private func logPlaybackDiagnostics(
        requestID: UUID,
        elapsedSeconds: Int,
        client: OpaquePointer
    ) {
        let names = [
            "hwdec-current",
            "video-codec",
            "video-format",
            "estimated-vf-fps",
            "display-fps",
            "demuxer-cache-duration",
            "decoder-frame-drop-count",
            "frame-drop-count"
        ]
        let fields = names.compactMap { name -> String? in
            guard let value = propertyString(name, client: client),
                  !value.isEmpty else { return nil }
            return "\(name)=\(LogRedactor.text(value))"
        }
        PlayerExperimentLogger.performance(
            "phase=playback_diagnostics elapsed_s=\(elapsedSeconds)"
                + " performance_profile=\(performanceProfile.rawValue)"
                + " render_control=\(renderControlMode.rawValue)"
                + (fields.isEmpty
                    ? " properties=unavailable"
                    : " " + fields.joined(separator: " ")),
            playerID: renderOwnerID,
            requestID: requestID,
            mode: teardownMode
        )
    }

    private func propertyString(
        _ name: String,
        client: OpaquePointer
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = buffer.withUnsafeMutableBufferPointer { output in
            name.withCString { namePointer in
                library.getPropertyString(
                    client,
                    namePointer,
                    output.baseAddress,
                    Int32(output.count)
                )
            }
        }
        guard result >= 0 else { return nil }
        return buffer.withUnsafeBufferPointer { output in
            guard let baseAddress = output.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    private func command(
        _ arguments: [String],
        client: OpaquePointer
    ) throws {
        guard !arguments.isEmpty,
              !arguments.contains(where: { $0.contains("\0") }) else {
            throw AppError.playback(L10n.string("player.command.arguments.invalid", fallback: "The player command arguments are invalid."))
        }
        try withMPVCStringArray(arguments) { pointers in
            try library.checked(
                library.command(client, Int32(arguments.count), pointers),
                operation: L10n.string("player.operation.command", fallback: "Run mpv command %@", arguments[0])
            )
        }
    }

    private func setStringProperty(
        _ name: String,
        value: String,
        operation: String
    ) async throws {
        guard !value.contains("\0") else {
            throw AppError.playback(L10n.string("player.property.invalid-character", fallback: "The player property contains an invalid character."))
        }
        try await perform { client in
            try name.withCString { namePointer in
                try value.withCString { valuePointer in
                    try self.library.checked(
                        self.library.setPropertyString(
                            client,
                            namePointer,
                            valuePointer
                        ),
                        operation: operation
                    )
                }
            }
        }
    }

    private func setDoubleProperty(
        _ name: String,
        value: Double,
        operation: String,
        updateSnapshot: ((inout PlayerSnapshot) -> Void)? = nil
    ) async throws {
        try await perform { client in
            try name.withCString { namePointer in
                try self.library.checked(
                    self.library.setPropertyDouble(client, namePointer, value),
                    operation: operation
                )
            }
            if let updateSnapshot {
                updateSnapshot(&self.snapshot)
                self.emitSnapshot()
            }
        }
    }

    private func setFlagProperty(
        _ name: String,
        value: Bool,
        operation: String,
        updateSnapshot: ((inout PlayerSnapshot) -> Void)? = nil
    ) async throws {
        try await perform { client in
            try name.withCString { namePointer in
                try self.library.checked(
                    self.library.setPropertyFlag(
                        client,
                        namePointer,
                        value ? 1 : 0
                    ),
                    operation: operation
                )
            }
            if let updateSnapshot {
                updateSnapshot(&self.snapshot)
                self.emitSnapshot()
            }
        }
    }

    private func applyHTTPHeaders(
        _ headers: HTTPHeaders,
        client: OpaquePointer
    ) throws {
        for (name, value) in headers.dictionary {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n"),
                  !name.contains("\0"), !value.contains("\0") else {
                throw AppError.playback(L10n.string("player.headers.invalid", fallback: "A media request header contains an invalid line break or null character."))
            }
        }
        let fields = headers.dictionary
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
        try "http-header-fields".withCString { namePointer in
            try withMPVCStringArray(fields) { valuePointers in
                try library.checked(
                    library.setPropertyStringArray(
                        client,
                        namePointer,
                        Int32(fields.count),
                        valuePointers
                    ),
                    operation: L10n.string("player.operation.set-headers", fallback: "Set media request headers")
                )
            }
        }
        let userAgent = headers["User-Agent"] ?? "OKVideoMac/0.3.18"
        try setPropertyString(
            "user-agent",
            value: userAgent,
            client: client,
            operation: L10n.string("player.operation.set-user-agent", fallback: "Set User-Agent")
        )
        try setPropertyString(
            "referrer",
            value: headers["Referer"] ?? "",
            client: client,
            operation: L10n.string("player.operation.set-referer", fallback: "Set Referer")
        )
    }

    private func applyViewport(
        aspectRatio: String?,
        panscan: Double,
        client: OpaquePointer
    ) throws {
        let trimmedRatio = aspectRatio?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try setPropertyString(
            "video-aspect-override",
            value: trimmedRatio?.isEmpty == false ? trimmedRatio! : "-1",
            client: client,
            operation: L10n.string("player.operation.set-load-aspect", fallback: "Set loading aspect ratio")
        )
        let boundedPanscan = min(max(panscan, 0), 1)
        try "panscan".withCString { namePointer in
            try library.checked(
                library.setPropertyDouble(
                    client,
                    namePointer,
                    boundedPanscan
                ),
                operation: L10n.string("player.operation.set-load-fill", fallback: "Set loading image fill")
            )
        }
    }

    private func setPropertyString(
        _ name: String,
        value: String,
        client: OpaquePointer,
        operation: String
    ) throws {
        try name.withCString { namePointer in
            try value.withCString { valuePointer in
                try library.checked(
                    library.setPropertyString(
                        client,
                        namePointer,
                        valuePointer
                    ),
                    operation: operation
                )
            }
        }
    }

    private func validate(media: ResolvedMedia) throws {
        let scheme = media.url.scheme?.lowercased()
        let supportedNetworkSchemes = [
            "http", "https", "rtsp", "rtmp", "rtmps", "rtp", "udp"
        ]
        guard media.url.isFileURL
                || supportedNetworkSchemes.contains(scheme ?? "") else {
            throw AppError.playback(
                L10n.string(
                    "player.protocol.unsupported",
                    fallback: "The player does not support this media protocol: %@",
                    scheme ?? L10n.string("common.unknown", fallback: "Unknown")
                )
            )
        }
        guard !media.url.absoluteString.contains("\0") else {
            throw AppError.playback(L10n.string("player.url.invalid-character", fallback: "The media URL contains an invalid character."))
        }
    }

    private func installPropertyObservers(client: OpaquePointer) throws {
        let observations: [(UInt64, String, Int32)] = [
            (1, "time-pos", NativeFormat.double),
            (2, "duration", NativeFormat.double),
            (3, "pause", NativeFormat.flag),
            (4, "paused-for-cache", NativeFormat.flag),
            (5, "cache-buffering-state", NativeFormat.double),
            (6, "volume", NativeFormat.double),
            (7, "mute", NativeFormat.flag),
            (8, "speed", NativeFormat.double),
            (9, "idle-active", NativeFormat.flag),
            (10, "track-list", 0),
            (11, "cache-speed", NativeFormat.int64),
            (12, "eof-reached", NativeFormat.flag),
            (13, "dwidth", NativeFormat.int64),
            (14, "dheight", NativeFormat.int64),
            (15, "seeking", NativeFormat.flag)
        ]
        for (identifier, name, format) in observations {
            try name.withCString { pointer in
                try library.checked(
                    library.observeProperty(client, identifier, pointer, format),
                    operation: L10n.string("player.operation.observe-property", fallback: "Observe mpv property %@", name)
                )
            }
        }
    }

    @discardableResult
    private func drainNativeEvents(limit: Int) -> Int {
        guard isRunning, let client else { return 0 }
        // Drain a bounded batch instead of reading only one event every 16 ms.
        // A seek or volume drag can produce several property notifications at
        // once; the old one-at-a-time loop let native events and UI commands
        // queue behind each other.
        var processedCount = 0
        while processedCount < limit, isRunning {
            var event = NativeMPVEvent()
            let result = withUnsafeMutablePointer(to: &event) { eventPointer in
                library.waitEvent(
                    client,
                    0,
                    UnsafeMutableRawPointer(eventPointer)
                )
            }
            if result < 0 {
                continuation.yield(
                    .error(
                        library.errorString(for: result),
                        requestID: currentRequestID
                    )
                )
                break
            }
            guard event.eventID != NativeEvent.none else { break }
            process(event)
            processedCount += 1
        }
        return processedCount
    }

    private func pollEvents() {
        let processedCount = drainNativeEvents(limit: 64)
        guard isRunning else { return }
        let delay: DispatchTimeInterval = processedCount == 64
            ? .milliseconds(0)
            : .milliseconds(16)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pollEvents()
        }
    }

    private func process(_ event: NativeMPVEvent) {
        switch event.eventID {
        case NativeEvent.logMessage:
            recordSeekReadWarning(event)
        case NativeEvent.fileLoaded:
            guard let client else { return }
            let isFirstFileLoaded = !didEmitFileLoadedForCurrentMedia
            didEmitFileLoadedForCurrentMedia = true
            if isFirstFileLoaded, let currentRequestID {
                playbackStartSignal.markFileLoaded()
                PlayerStartupTraceStore.shared.markFileLoaded(
                    requestID: currentRequestID,
                    playerID: renderOwnerID
                )
            }
            isReplacingMedia = false
            if let replacingMediaRequestID {
                activeMediaRequestID = nil
                self.replacingMediaRequestID = nil
                continuation.yield(
                    .mediaReleased(requestID: replacingMediaRequestID)
                )
                resumeMediaReleaseWaiters(
                    requestID: replacingMediaRequestID
                )
            }
            activeMediaRequestID = currentRequestID
            pendingEOFSignal = nil
            // One native boundary owns autoplay. TVBox has already applied
            // its start position while paused; there is no post-start seek.
            try? "pause".withCString { namePointer in
                try library.checked(
                    library.setPropertyFlag(client, namePointer, 0),
                    operation: L10n.string("player.operation.start-new-media", fallback: "Start new media")
                )
            }
            snapshot.status = currentMediaTransportProfile == .tvBox
                ? (snapshot.isPausedForCache ? .buffering : .loading) : .playing
            if currentMediaTransportProfile != .tvBox, let position = pendingStartPosition {
                // History restore and quality switching are timeline seeks too.
                // Keep them on the remote-friendly keyframe path instead of
                // silently reintroducing an exact `time-pos` property seek.
                let requestGeneration = playbackRequestGeneration
                let seekGeneration = postSeekEndGuard.begin(
                    requestGeneration: requestGeneration,
                    target: position
                )
                do {
                    try command(Self.seekCommand(to: position), client: client)
                } catch {
                    postSeekEndGuard.cancel(
                        requestGeneration: requestGeneration,
                        seekGeneration: seekGeneration
                    )
                }
            }
            pendingStartPosition = nil
            for subtitle in pendingSubtitles {
                try? command(
                    [
                        "sub-add",
                        subtitle.absoluteString,
                        "auto"
                    ],
                    client: client
                )
            }
            pendingSubtitles = []
            refreshTracks(client: client)
            try? "sid".withCString { namePointer in
                try "no".withCString { valuePointer in
                    try library.checked(
                        library.setPropertyString(client, namePointer, valuePointer),
                        operation: L10n.string("player.operation.disable-subtitles", fallback: "Disable subtitles using the user setting")
                    )
                }
            }
            refreshTracks(client: client)
            emitSnapshot()
            if isFirstFileLoaded {
                if let currentRequestID {
                    schedulePlaybackDiagnostics(requestID: currentRequestID)
                }
                completeLoad(.success(()))
                continuation.yield(.fileLoaded(requestID: currentRequestID))
            }
        case NativeEvent.endFile:
            if isReplacingMedia {
                if let replacingMediaRequestID {
                    activeMediaRequestID = nil
                    self.replacingMediaRequestID = nil
                    continuation.yield(
                        .mediaReleased(requestID: replacingMediaRequestID)
                    )
                    resumeMediaReleaseWaiters(
                        requestID: replacingMediaRequestID
                    )
                }
                pendingEOFSignal = nil
                guard event.endFileReason != 2 else { return }
                let nativeMessage = event.error < 0
                    ? library.errorString(for: event.error)
                    : L10n.string("player.error.ended-before-load", fallback: "libmpv ended before media loading completed.")
                if currentMediaTransportProfile == .tvBox,
                   tvBoxFormatFallbackAvailable,
                   let currentMedia,
                   let client {
                    // Some TVBox spiders report a generic or stale format.
                    // Retry the same authenticated URL once with libavformat
                    // auto-detection before asking the provider to regenerate
                    // the entire playback session.
                    tvBoxFormatFallbackAvailable = false
                    do {
                        PlayerExperimentLogger.performance(
                            "phase=tvbox_local_format_fallback"
                                + " message=\(LogRedactor.text(nativeMessage))",
                            playerID: renderOwnerID,
                            requestID: currentRequestID,
                            mode: teardownMode
                        )
                        snapshot.status = .loading
                        emitSnapshot()
                        try command(
                            MPVTVBoxPlaybackPolicy.loadCommand(
                                for: currentMedia,
                                omitFormatHint: true,
                                startPosition: pendingStartPosition,
                                networkOptions: currentNetworkOptions
                            ),
                            client: client
                        )
                        return
                    } catch {
                        PlayerExperimentLogger.failure(
                            "phase=tvbox_local_format_fallback_failed"
                                + " message=\(LogRedactor.text(error.localizedDescription))",
                            playerID: renderOwnerID,
                            requestID: currentRequestID,
                            mode: teardownMode
                        )
                    }
                }
                let message = MPVPlaybackErrorPolicy.userFacingMessage(
                    nativeMessage: nativeMessage
                )
                PlayerExperimentLogger.failure(
                    "phase=end_file reason=\(event.endFileReason)"
                        + " error=\(event.error)"
                        + " message=\(LogRedactor.text(nativeMessage))",
                    playerID: renderOwnerID,
                    requestID: currentRequestID,
                    mode: teardownMode
                )
                snapshot.status = .failed(message)
                clearTransientPlaybackActivity()
                isReplacingMedia = false
                emitSnapshot()
                completeLoad(
                    .failure(AppError.playback(message))
                )
                return
            }
            let requestGeneration = playbackRequestGeneration
            let eofSignal = pendingEOFSignal.flatMap {
                $0.requestGeneration == requestGeneration ? $0 : nil
            }
            let eofSeekGeneration = eofSignal?.seekGeneration.map(String.init)
                ?? "none"
            pendingEOFSignal = nil
            logSeekReadState(phase: "seek_read_end_file")
            let disposition = MPVPlaybackEndPolicy.disposition(
                endFileReason: event.endFileReason,
                error: event.error,
                isReplacingMedia: isReplacingMedia,
                hasStartedPlayback: playbackStartSignal.hasStartedPlayback(),
                isPausedForCache: snapshot.isPausedForCache,
                position: snapshot.position,
                duration: snapshot.duration,
                isProtectedByUserSeek: postSeekEndGuard.isProtecting(
                    requestGeneration: requestGeneration
                ),
                isUserSeekToBoundary: postSeekEndGuard.isBoundarySeek(
                    requestGeneration: requestGeneration,
                    position: snapshot.position,
                    duration: snapshot.duration
                )
            )
            PlayerExperimentLogger.performance(
                "phase=end_arbiter"
                    + " disposition=\(String(describing: disposition))"
                    + " eof_signal=\(eofSignal != nil)"
                    + " seek_generation=\(eofSeekGeneration) "
                    + seekObservationFields(),
                playerID: renderOwnerID,
                requestID: currentRequestID,
                mode: teardownMode
            )
            switch disposition {
            case .natural:
                emitEndedIfNeeded(origin: .natural)
            case .userSeekBoundary:
                emitEndedIfNeeded(origin: .userSeekBoundary)
            case .stopped:
                emitMediaReleasedIfNeeded()
                snapshot.status = .stopped
                clearTransientPlaybackActivity()
                emitSnapshot()
            case .failed:
                emitMediaReleasedIfNeeded()
                let nativeMessage = library.errorString(for: event.error)
                let message = MPVPlaybackErrorPolicy.userFacingMessage(
                    nativeMessage: nativeMessage
                )
                PlayerExperimentLogger.failure(
                    "phase=end_file reason=\(event.endFileReason)"
                        + " error=\(event.error)"
                        + " message=\(LogRedactor.text(nativeMessage))",
                    playerID: renderOwnerID,
                    requestID: currentRequestID,
                    mode: teardownMode
                )
                snapshot.status = .failed(message)
                clearTransientPlaybackActivity()
                emitSnapshot()
                continuation.yield(
                    .error(message, requestID: currentRequestID)
                )
            case .premature:
                emitMediaReleasedIfNeeded()
                let message = postSeekEndGuard.isProtecting(
                    requestGeneration: requestGeneration
                )
                    ? L10n.string("player.error.ended-during-seek", fallback: "The media ended unexpectedly while seeking. Try again or switch sources.")
                    : L10n.string("player.error.ended-prematurely", fallback: "The media disconnected before playback finished. Try again or switch sources.")
                PlayerExperimentLogger.failure(
                    "phase=premature_end_file"
                        + " reason=\(event.endFileReason)"
                        + " position=\(snapshot.position)"
                        + " duration=\(snapshot.duration)"
                        + " seek_guard=\(postSeekEndGuard.isProtecting(requestGeneration: requestGeneration))",
                    playerID: renderOwnerID,
                    requestID: currentRequestID,
                    mode: teardownMode
                )
                emitPrematureEndIfNeeded(message: message)
            case .ignored:
                break
            }
        case NativeEvent.propertyChange:
            processProperty(event)
        case NativeEvent.seek:
            if currentMediaTransportProfile == .tvBox {
                if let generation = postSeekEndGuard.activeSeekGeneration(requestGeneration: playbackRequestGeneration) {
                    seekActivityOwner.markStarted(request: playbackRequestGeneration, seek: generation)
                }
                refreshTVBoxSeekCompletion()
                if snapshot.seekTarget == nil, let client {
                    snapshot.isSeeking = propertyString("seeking", client: client) == "yes"
                }
            } else { snapshot.isSeeking = true }
            emitSnapshot()
        case NativeEvent.playbackRestart:
            let activeSeekGeneration = postSeekEndGuard
                .activeSeekGeneration(
                    requestGeneration: playbackRequestGeneration
                )
            guard activeSeekGeneration != nil
                    || snapshot.isSeeking
                    || snapshot.seekTarget != nil else {
                break
            }
            postSeekEndGuard.markPlaybackRestart(
                requestGeneration: playbackRequestGeneration
            )
            logSeekObservation(phase: "seek_playback_restart")
            logSeekReadState(phase: "seek_read_restart")
            if currentMediaTransportProfile == .tvBox {
                if let activeSeekGeneration {
                    seekActivityOwner.markRestarted(request: playbackRequestGeneration, seek: activeSeekGeneration)
                }
                refreshTVBoxSeekCompletion()
            } else {
                snapshot.isSeeking = false
                snapshot.seekTarget = nil
            }
            emitSnapshot()
        case NativeEvent.queueOverflow:
            continuation.yield(
                .error(
                    L10n.string("player.error.event-queue-overflow", fallback: "The libmpv event queue overflowed."),
                    requestID: currentRequestID
                )
            )
        case NativeEvent.shutdown:
            emitMediaReleasedIfNeeded()
            clearTransientPlaybackActivity()
            snapshot.status = .stopped
            emitSnapshot()
        default:
            break
        }
    }

    private func emitMediaReleasedIfNeeded() {
        guard let releasedRequestID = activeMediaRequestID else { return }
        activeMediaRequestID = nil
        replacingMediaRequestID = nil
        continuation.yield(.mediaReleased(requestID: releasedRequestID))
        resumeMediaReleaseWaiters(requestID: releasedRequestID)
    }

    private func resumeMediaReleaseWaiters(requestID: UUID) {
        let waiters = mediaReleaseWaiters.removeValue(forKey: requestID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func refreshTVBoxSeekCompletion() {
        guard currentMediaTransportProfile == .tvBox, !isReplacingMedia,
              let client, let target = snapshot.seekTarget,
              let generation = postSeekEndGuard.activeSeekGeneration(requestGeneration: playbackRequestGeneration),
              let position = propertyString("time-pos", client: client).flatMap(Double.init),
              let seeking = propertyString("seeking", client: client),
              let cachePause = propertyString("paused-for-cache", client: client),
              PlayerSeekCompletionPolicy.accepts(target: target, position: position,
                nativeSeeking: seeking != "no", pausedForCache: cachePause != "no",
                seekRestarted: seekActivityOwner.hasRestarted(request: playbackRequestGeneration, seek: generation)) else { return }
        snapshot.position = position
        snapshot.positionSampleUptime = ProcessInfo.processInfo.systemUptime
        snapshot.isSeeking = false
        snapshot.seekTarget = nil
        snapshot.isPausedForCache = false
        completedTVBoxSeekGeneration = generation
        snapshot.status = propertyString("pause", client: client) == "yes" ? .paused : .playing
        logSeekObservation(phase: "seek_position_confirmed")
    }

    private func processProperty(_ event: NativeMPVEvent) {
        guard let propertyName = event.propertyName else { return }
        let name = String(cString: propertyName)
        switch name {
        case "time-pos":
            let position = max(0, event.doubleValue)
            snapshot.position = position
            snapshot.positionSampleUptime = ProcessInfo.processInfo.systemUptime
            if currentMediaTransportProfile == .tvBox { refreshTVBoxSeekCompletion() }
            let wasProtectingSeek = postSeekEndGuard.isProtecting(requestGeneration: playbackRequestGeneration)
            postSeekEndGuard.observePosition(
                position,
                requestGeneration: playbackRequestGeneration,
                isSeeking: snapshot.isSeeking
            )
            if wasProtectingSeek && !postSeekEndGuard.isProtecting(requestGeneration: playbackRequestGeneration) {
                logSeekReadState(phase: "confirmed_progress")
            }
            if let previous = startupTimelinePosition {
                if abs(position - previous) >= 0.05,
                   !snapshot.isSeeking, !snapshot.isPausedForCache,
                   let requestID = playbackStartSignal
                    .claimPlaybackStarted() {
                    if snapshot.status == .loading || snapshot.status == .buffering {
                        snapshot.status = .playing
                    }
                    PlayerStartupTraceStore.shared.markTimelineProgress(
                        playerID: renderOwnerID
                    )
                    continuation.yield(
                        .playbackStarted(requestID: requestID)
                    )
                    startupTimelinePosition = nil
                }
            } else if didEmitFileLoadedForCurrentMedia {
                startupTimelinePosition = position
            }
        case "duration":
            snapshot.duration = max(0, event.doubleValue)
        case "pause":
            if snapshot.status != .loading
                && snapshot.status != .buffering
                && snapshot.status != .ended {
                snapshot.status = event.flagValue != 0 ? .paused : .playing
            }
        case "eof-reached":
            if event.flagValue != 0 {
                let signal = (
                    requestGeneration: playbackRequestGeneration,
                    seekGeneration: postSeekEndGuard
                        .activeSeekGeneration(
                            requestGeneration: playbackRequestGeneration
                        )
                )
                pendingEOFSignal = signal
                // Property changes in the same native poll batch may still
                // contain the final time-pos/duration values. Arbitrate on the
                // serial queue's next turn so the EOF decision sees them.
                scheduleKeepOpenEOFArbitration(signal)
            } else if pendingEOFSignal?.requestGeneration
                        == playbackRequestGeneration {
                pendingEOFSignal = nil
            }
        case "paused-for-cache":
            snapshot.isPausedForCache = event.flagValue != 0
            if snapshot.isPausedForCache {
                snapshot.status = .buffering
            } else if snapshot.status == .buffering {
                snapshot.status = .playing
            }
            if currentMediaTransportProfile == .tvBox { refreshTVBoxSeekCompletion() }
        case "seeking":
            if currentMediaTransportProfile == .tvBox {
                if snapshot.seekTarget != nil { refreshTVBoxSeekCompletion() }
                else if let client {
                    // Read current native state instead of trusting a queued
                    // property notification from the preceding seek.
                    snapshot.isSeeking = propertyString("seeking", client: client) == "yes"
                }
            } else {
                snapshot.isSeeking = event.flagValue != 0
                if !snapshot.isSeeking { snapshot.seekTarget = nil }
            }
        case "cache-buffering-state":
            snapshot.bufferedPercent = min(max(event.doubleValue, 0), 100)
        case "cache-speed":
            snapshot.networkSpeedBytesPerSecond = max(0, event.int64Value)
        case "volume":
            snapshot.volume = min(max(event.doubleValue, 0), 130)
        case "mute":
            snapshot.isMuted = event.flagValue != 0
        case "speed":
            snapshot.speed = event.doubleValue
        case "dwidth":
            snapshot.videoWidth = max(0, Int(event.int64Value))
        case "dheight":
            snapshot.videoHeight = max(0, Int(event.int64Value))
        case "idle-active":
            if event.flagValue != 0, !isReplacingMedia {
                emitMediaReleasedIfNeeded()
                switch snapshot.status {
                case .ended, .failed:
                    break
                default:
                    snapshot.status = .idle
                }
            }
        case "track-list":
            if let client {
                refreshTracks(client: client)
            }
        default:
            return
        }
        if name == "time-pos"
            || name == "duration"
            || name == "paused-for-cache" {
            if let signal = pendingEOFSignal {
                scheduleKeepOpenEOFArbitration(signal)
            }
        }
        if Self.isTimelineProperty(name) {
            emitTimelineSnapshot()
        } else {
            emitSnapshot()
        }
    }

    private func emitSnapshot() {
        snapshot.historyProgressIsReliable = postSeekEndGuard.permitsHistory(snapshot,
            requestGeneration: playbackRequestGeneration)
        guard snapshot != lastEmittedSnapshot else { return }
        lastEmittedSnapshot = snapshot
        lastTimelineEmissionUptime = DispatchTime.now().uptimeNanoseconds
        continuation.yield(
            .snapshot(snapshot, requestID: currentRequestID)
        )
    }

    private func scheduleKeepOpenEOFArbitration(
        _ signal: (requestGeneration: UInt64, seekGeneration: UInt64?)
    ) {
        queue.async { [weak self] in
            self?.handleKeepOpenEOFSignal(signal)
        }
    }

    private func handleKeepOpenEOFSignal(
        _ signal: (requestGeneration: UInt64, seekGeneration: UInt64?)
    ) {
        guard pendingEOFSignal?.requestGeneration
                == signal.requestGeneration,
              pendingEOFSignal?.seekGeneration == signal.seekGeneration,
              !didEmitEndedForCurrentMedia else { return }
        let requestGeneration = playbackRequestGeneration
        let protectsUserSeek = postSeekEndGuard.isProtecting(
            requestGeneration: requestGeneration
        )
        logSeekReadState(phase: "seek_read_eof")
        let disposition = MPVKeepOpenEOFPolicy.disposition(
            signalRequestGeneration: signal.requestGeneration,
            currentRequestGeneration: requestGeneration,
            ownsActiveMedia: currentRequestID != nil
                && activeMediaRequestID == currentRequestID,
            isReplacingMedia: isReplacingMedia,
            hasStartedPlayback: playbackStartSignal.hasStartedPlayback(),
            isPausedForCache: snapshot.isPausedForCache,
            position: snapshot.position,
            duration: snapshot.duration,
            isProtectedByUserSeek: protectsUserSeek,
            isUserSeekToBoundary: postSeekEndGuard.isBoundarySeek(
                requestGeneration: requestGeneration,
                position: snapshot.position,
                duration: snapshot.duration
            )
        )
        PlayerExperimentLogger.performance(
            "phase=keep_open_eof_arbiter"
                + " disposition=\(String(describing: disposition))"
                + " signal_generation=\(signal.requestGeneration)"
                + " request_generation=\(requestGeneration)"
                + " seek_generation=\(signal.seekGeneration.map(String.init) ?? "none") "
                + seekObservationFields(),
            playerID: renderOwnerID,
            requestID: currentRequestID,
            mode: teardownMode
        )
        switch disposition {
        case .natural:
            emitEndedIfNeeded(origin: .natural)
        case .userSeekBoundary:
            emitEndedIfNeeded(origin: .userSeekBoundary)
        case .premature:
            let message = protectsUserSeek
                ? L10n.string("player.error.ended-during-seek", fallback: "The media ended unexpectedly while seeking. Try again or switch sources.")
                : L10n.string("player.error.ended-prematurely", fallback: "The media disconnected before playback finished. Try again or switch sources.")
            emitPrematureEndIfNeeded(message: message)
        case .stopped, .failed, .ignored:
            break
        }
    }

    private func seekObservationFields() -> String {
        PlayerSeekDiagnostics.fields(
            position: snapshot.position,
            duration: snapshot.duration,
            target: postSeekEndGuard.activeTarget(
                requestGeneration: playbackRequestGeneration
            )
        )
    }

    private func logSeekObservation(phase: StaticString) {
        PlayerExperimentLogger.performance(
            "phase=\(phase) request_generation=\(playbackRequestGeneration)"
                + " seek_generation=\(postSeekEndGuard.activeSeekGeneration(requestGeneration: playbackRequestGeneration).map(String.init) ?? "none") "
                + seekObservationFields(),
            playerID: renderOwnerID,
            requestID: currentRequestID,
            mode: teardownMode
        )
    }

    private func beginSeekReadDiagnostics(request: UInt64, seek: UInt64) {
        endSeekReadDiagnostics()
        guard seekReadDiagnosticsEnabled, let client else { return }
        let result = "warn".withCString { library.requestLogMessages?(client, $0) ?? -1 }
        seekReadWindow = PlayerSeekReadWindow(
            requestGeneration: request, seekGeneration: seek,
            deadline: ProcessInfo.processInfo.systemUptime + 20
        )
        PlayerExperimentLogger.performance(
            "phase=seek_read_open native_warnings=\(result >= 0) request_generation=\(request) seek_generation=\(seek)",
            playerID: renderOwnerID, requestID: currentRequestID, mode: teardownMode
        )
        queue.asyncAfter(deadline: .now() + .seconds(20), execute: DispatchWorkItem { [weak self] in
            guard let self, self.seekReadWindow?.requestGeneration == request,
                  self.seekReadWindow?.seekGeneration == seek else { return }
            self.endSeekReadDiagnostics()
        })
    }

    private func endSeekReadDiagnostics() {
        guard let window = seekReadWindow else { return }
        seekReadWindow = nil
        if let client {
            _ = "no".withCString { library.requestLogMessages?(client, $0) }
        }
        PlayerExperimentLogger.performance(
            "phase=seek_read_closed observations=\(24 - window.remaining) request_generation=\(window.requestGeneration) seek_generation=\(window.seekGeneration)",
            playerID: renderOwnerID, requestID: currentRequestID, mode: teardownMode
        )
    }

    private func takeSeekReadSlot() -> Bool {
        guard var window = seekReadWindow else { return false }
        guard window.consume(request: playbackRequestGeneration,
                             seek: postSeekEndGuard.latestSeekGeneration,
                             now: ProcessInfo.processInfo.systemUptime) else {
            endSeekReadDiagnostics()
            return false
        }
        seekReadWindow = window
        return true
    }

    private func logSeekReadState(phase: StaticString) {
        guard let client, takeSeekReadSlot() else { return }
        let fields = PlayerSeekReadDiagnostics.properties.map { name in
            "\(name)=\(PlayerSeekReadDiagnostics.property(name, value: propertyString(name, client: client)))"
        }.joined(separator: " ")
        PlayerExperimentLogger.performance(
            "phase=\(phase) request_generation=\(playbackRequestGeneration) seek_generation=\(postSeekEndGuard.latestSeekGeneration)"
                + " entry_route=\(PlayerSeekReadDiagnostics.route(currentMedia?.url)) " + fields,
            playerID: renderOwnerID, requestID: currentRequestID, mode: teardownMode
        )
    }

    private func recordSeekReadWarning(_ event: NativeMPVEvent) {
        guard takeSeekReadSlot() else { return }
        let fields = PlayerSeekReadDiagnostics.warning(
            prefix: event.propertyName.map { String(cString: $0) } ?? "",
            level: event.propertyFormat,
            text: event.stringValue.map { String(cString: $0) } ?? ""
        )
        // mpv log events carry no media/seek ID. These are observations in the
        // current diagnostic window, never authority for playback decisions.
        PlayerExperimentLogger.performance(
            "phase=seek_read_warning attribution=current_window request_generation=\(playbackRequestGeneration) seek_generation=\(postSeekEndGuard.latestSeekGeneration) " + fields,
            playerID: renderOwnerID, requestID: currentRequestID, mode: teardownMode
        )
    }

    private func emitEndedIfNeeded(origin: PlaybackEndOrigin) {
        guard !didEmitEndedForCurrentMedia else { return }
        didEmitEndedForCurrentMedia = true
        clearTransientPlaybackActivity()
        snapshot.status = .ended
        if snapshot.duration > 0 {
            snapshot.position = max(snapshot.position, snapshot.duration)
        }
        emitSnapshot()
        continuation.yield(
            .ended(requestID: currentRequestID, origin: origin)
        )
    }

    private func emitPrematureEndIfNeeded(message: String) {
        guard !didEmitEndedForCurrentMedia else { return }
        didEmitEndedForCurrentMedia = true
        clearTransientPlaybackActivity()
        snapshot.status = .failed(message)
        emitSnapshot()
        continuation.yield(
            .ended(
                requestID: currentRequestID,
                origin: .premature(message)
            )
        )
    }

    private func clearTransientPlaybackActivity() {
        endSeekReadDiagnostics()
        postSeekEndGuard.reset()
        seekActivityOwner.reset()
        pendingEOFSignal = nil
        snapshot.isSeeking = false
        snapshot.isPausedForCache = false
        snapshot.seekTarget = nil
    }

    private func emitTimelineSnapshot() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= lastTimelineEmissionUptime
            ? now - lastTimelineEmissionUptime
            : timelineEmissionIntervalNanoseconds
        if lastTimelineEmissionUptime == 0
            || elapsed >= timelineEmissionIntervalNanoseconds {
            emitSnapshot()
            return
        }
        guard !timelineEmissionScheduled else { return }
        timelineEmissionScheduled = true
        let remaining = timelineEmissionIntervalNanoseconds - elapsed
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(remaining))
        ) { [weak self] in
            guard let self else { return }
            self.timelineEmissionScheduled = false
            guard self.isRunning else { return }
            self.emitSnapshot()
        }
    }

    private var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycleState == .running
    }

    private func beginShutdown() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lifecycleState == .running else { return false }
        lifecycleState = .shuttingDown
        return true
    }

    private func waitForRenderContextsToDetach() async {
        await withCheckedContinuation { continuation in
            lifecycleLock.lock()
            if renderContextCount == 0 {
                lifecycleLock.unlock()
                continuation.resume()
            } else {
                renderDetachWaiters.append(continuation)
                lifecycleLock.unlock()
            }
        }
    }

    private func waitForShutdownCompletion() async {
        await withCheckedContinuation { continuation in
            lifecycleLock.lock()
            if lifecycleState == .shutdown {
                lifecycleLock.unlock()
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
                lifecycleLock.unlock()
            }
        }
    }

    private func markShutdownComplete() {
        let waiters: [CheckedContinuation<Void, Never>]
        lifecycleLock.lock()
        lifecycleState = .shutdown
        waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        lifecycleLock.unlock()
        waiters.forEach { $0.resume() }
    }

    static func isTimelineProperty(_ name: String) -> Bool {
        switch name {
        case "time-pos", "cache-buffering-state", "cache-speed":
            return true
        default:
            return false
        }
    }

    private func completeLoad(_ result: Result<Void, Error>) {
        guard let pending = pendingLoad else { return }
        pendingLoad = nil
        switch result {
        case .success:
            pending.continuation.resume()
        case .failure(let error):
            pending.continuation.resume(throwing: error)
        }
    }

    private func refreshTracks(client: OpaquePointer) {
        let count = library.trackCount(client)
        guard count >= 0 else { return }
        var tracks: [MediaTrack] = []
        for index in 0..<count {
            var identifier: Int64 = 0
            var selected: Int32 = 0
            var type = [CChar](repeating: 0, count: 32)
            var title = [CChar](repeating: 0, count: 512)
            var language = [CChar](repeating: 0, count: 64)
            let result = type.withUnsafeMutableBufferPointer { typeBuffer in
                title.withUnsafeMutableBufferPointer { titleBuffer in
                    language.withUnsafeMutableBufferPointer { languageBuffer in
                        library.trackAt(
                            client,
                            index,
                            &identifier,
                            typeBuffer.baseAddress,
                            Int32(typeBuffer.count),
                            titleBuffer.baseAddress,
                            Int32(titleBuffer.count),
                            languageBuffer.baseAddress,
                            Int32(languageBuffer.count),
                            &selected
                        )
                    }
                }
            }
            guard result >= 0,
                  let trackType = Self.mediaTrackType(
                    forMPVValue: String(cString: type)
                  ) else { continue }
            let rawTitle = String(cString: title)
            let rawLanguage = String(cString: language)
            tracks.append(
                MediaTrack(
                    id: Int(identifier),
                    type: trackType,
                    title: rawTitle.isEmpty
                        ? "\(trackType.rawValue) \(identifier)"
                        : rawTitle,
                    language: rawLanguage.isEmpty ? nil : rawLanguage,
                    isSelected: selected != 0
                )
            )
        }
        snapshot.tracks = tracks
    }
}

/// Owns the native player and applies the configured close policy. AppState is
/// main-actor isolated, so all
/// lifecycle transitions are serialized here as well. The native client still
/// owns its dedicated libmpv queue and performs its own render-detach barrier.
@MainActor
final class PlayerLifecycleController {
    let events: AsyncStream<PlayerEvent>
    let mode: PlayerTeardownMode

    var onRenderClientChanged: ((MPVPlayerClient?) -> Void)?

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var currentClient: PlayerClient?
    private var eventForwardingTask: Task<Void, Never>?
    private var lifecycleBarrier: Task<Void, Never>?
    private var lifecycleBarrierID: UUID?
    private var deferredDestroyTask: Task<Void, Never>?
    private var deferredDestroyID: UUID?
    private var isShuttingDown = false
    private var playbackIntentRequestID: UUID?
    private var playbackIntentGeneration: UInt64 = 0
    var transitionSuspensionForTesting:
        ((PlayerLifecycleTransitionKind) async -> Void)?

    private let audioPreferences: PlaybackAudioPreferenceStore
    private var audioApplication: Task<Void, Error>?
    private var audioApplicationID: UUID?
    var audioCommandSuspensionForTesting: (() async throws -> Void)?
    var audioPreference: PlaybackAudioPreference { audioPreferences.value }
    var audioPreferenceRevision: UInt64 { audioPreferences.revision }
    private var rememberedSpeed: Double = 1
    private var rememberedSubtitleDelay: TimeInterval = 0
    private var rememberedSubtitleScale: Double = 1
    private var rememberedSubtitlePosition: Double = 100
    private var rememberedSubtitleBorderSize: Double = 3
    private var rememberedAudioDelay: TimeInterval = 0
    private var rememberedAspectRatio: String?
    private var rememberedHardwareDecoding = true

    init(mode: PlayerTeardownMode = .configured(), audioPreferences: PlaybackAudioPreferenceStore? = nil) {
        self.mode = mode
        self.audioPreferences = audioPreferences ?? PlaybackAudioPreferenceStore()
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            captured = $0
        }
        continuation = captured

        do {
            let player = try MPVPlayerClient(teardownMode: mode, audioPreference: self.audioPreference)
            currentClient = player
            startForwardingEvents(from: player)
        } catch {
            let unavailable = UnavailablePlayerClient(
                reason: L10n.string("player.runtime.unavailable-reason", fallback: "libmpv unavailable: %@", LogRedactor.text(error.localizedDescription))
            )
            currentClient = unavailable
            startForwardingEvents(from: unavailable)
        }
        PlayerExperimentLogger.lifecycle(
            "teardown mode configured",
            playerID: renderPlayer?.renderOwnerID,
            mode: mode
        )
    }

    var renderPlayer: MPVPlayerClient? {
        currentClient as? MPVPlayerClient
    }

    var runtimeDescription: String {
        renderPlayer?.runtimeDescription
            ?? L10n.string("player.runtime.unavailable", fallback: "libmpv unavailable")
    }

    func ownsPlaybackForTesting(_ requestID: UUID) -> Bool {
        playbackIntentRequestID == requestID
    }

    @discardableResult
    func prepareForPlayback(
        requestID: UUID,
        releasePolicy: PlayerReleasePolicy = .existingBehavior,
        compatibilityPolicy: PlaybackCompatibilityPolicy = .existing
    ) async throws -> MPVPlayerClient {
        let generation = claimPlaybackIntent(requestID: requestID)
        if let deferredDestroyTask {
            let deferredDestroyID = self.deferredDestroyID
            deferredDestroyTask.cancel()
            await deferredDestroyTask.value
            if self.deferredDestroyID == deferredDestroyID {
                self.deferredDestroyTask = nil
                self.deferredDestroyID = nil
            }
        }
        guard ownsPlaybackIntent(requestID: requestID, generation: generation) else {
            throw CancellationError()
        }
        return try await serializeLifecycleTransition { [weak self] in
            guard let self else { throw CancellationError() }
            await self.transitionSuspensionForTesting?(.prepare)
            guard self.ownsPlaybackIntent(
                requestID: requestID, generation: generation
            ), !self.isShuttingDown else {
                throw CancellationError()
            }

            if let capturedClient = self.currentClient,
               releasePolicy == .destroyBeforeLoad
                || self.renderPlayer?.compatibilityPolicy != compatibilityPolicy {
                await self.transitionSuspensionForTesting?(.strictRelease)
                guard self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                ) else { throw CancellationError() }
                self.detachCurrentClient(ifIdenticalTo: capturedClient)
                await capturedClient.shutdown()
                guard self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                ) else { throw CancellationError() }
            }

            if let player = self.renderPlayer {
                PlayerStartupTraceStore.shared.markClientReady(
                    requestID: requestID,
                    playerID: player.renderOwnerID
                )
                return player
            }
            if let unavailable = self.currentClient {
                self.detachCurrentClient(ifIdenticalTo: unavailable)
                await unavailable.shutdown()
                guard self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                ) else { throw CancellationError() }
            }

            PlayerExperimentLogger.lifecycle(
                "recreate begin",
                playerID: nil,
                requestID: requestID,
                mode: self.mode
            )
            let player = try MPVPlayerClient(teardownMode: self.mode, compatibilityPolicy: compatibilityPolicy, audioPreference: self.audioPreference)
            do {
                try await self.applyRememberedSettings(to: player)
                guard self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                ), !self.isShuttingDown else {
                    await player.shutdown()
                    throw CancellationError()
                }
            } catch {
                await player.shutdown()
                throw error
            }
            self.currentClient = player
            self.startForwardingEvents(from: player)
            self.onRenderClientChanged?(player)
            PlayerStartupTraceStore.shared.markClientReady(
                requestID: requestID,
                playerID: player.renderOwnerID
            )
            PlayerExperimentLogger.lifecycle(
                "recreate ready",
                playerID: player.renderOwnerID,
                requestID: requestID,
                mode: self.mode
            )
            return player
        }
    }

    func closeAfterPlayback(
        requestID: UUID?,
        warmRetentionSeconds: TimeInterval = 0
    ) async {
        let ownership = ownershipForRelease(requestID: requestID)
        guard let ownership else { return }
        renderPlayer?.cancelPendingMediaLoad(requestID: ownership.requestID)
        let retention = max(0, warmRetentionSeconds)
        do {
            try await serializeLifecycleTransition { [weak self] in
                guard let self else { return }
                try await self.transitionSuspensionForTesting?(.close)
                guard self.ownsPlaybackIntent(
                    requestID: ownership.requestID,
                    generation: ownership.generation
                ), let capturedClient = self.currentClient else { return }
                if self.mode == .fullDestroy, retention == 0 {
                    self.detachCurrentClient(ifIdenticalTo: capturedClient)
                    await capturedClient.shutdown()
                } else {
                    await capturedClient.stop()
                }
            }
        } catch {
            return
        }
        guard ownsPlaybackIntent(
            requestID: ownership.requestID,
            generation: ownership.generation
        ), mode == .fullDestroy, retention > 0 else { return }
        deferredDestroyTask?.cancel()
        let deferredGeneration = ownership.generation
        let deferredRequestID = ownership.requestID
        let deferredID = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(retention * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.ownsPlaybackIntent(
                    requestID: deferredRequestID,
                    generation: deferredGeneration
                  ), !self.isShuttingDown else { return }
            await self.fullDestroy(requestID: deferredRequestID)
        }
        deferredDestroyTask = task
        deferredDestroyID = deferredID
    }

    func fullDestroy(requestID: UUID?) async {
        guard let ownership = ownershipForRelease(requestID: requestID) else {
            return
        }
        renderPlayer?.cancelPendingMediaLoad(requestID: ownership.requestID)
        _ = try? await serializeLifecycleTransition { [weak self] in
            guard let self,
                  self.ownsPlaybackIntent(
                    requestID: ownership.requestID,
                    generation: ownership.generation
                  ), let player = self.currentClient else { return }
            let playerID = (player as? MPVPlayerClient)?.renderOwnerID
            PlayerExperimentLogger.lifecycle(
                "full destroy begin", playerID: playerID,
                requestID: ownership.requestID, mode: self.mode
            )
            self.detachCurrentClient(ifIdenticalTo: player)
            await player.shutdown()
            if let playerID {
                PlayerStartupTraceStore.shared.cancel(playerID: playerID)
            }
            PlayerExperimentLogger.lifecycle(
                "full destroy end", playerID: playerID,
                requestID: ownership.requestID, mode: self.mode
            )
        }
    }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID,
        waitForRenderSurface: ((UUID) async throws -> Void)? = nil
    ) async throws {
        let generation = claimPlaybackIntent(requestID: requestID)
        try await serializeLifecycleTransition { [weak self] in
            guard let self,
                  self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                  ) else { throw CancellationError() }
            let player = try await self.prepareForPlaybackInsideTransition(
                requestID: requestID,
                generation: generation,
                compatibilityPolicy: media.compatibilityPolicy
            )
            if let waitForRenderSurface {
                try await waitForRenderSurface(player.renderOwnerID)
                try Task.checkCancellation()
                guard self.ownsPlaybackIntent(
                    requestID: requestID, generation: generation
                ), self.renderPlayer === player else {
                    throw CancellationError()
                }
            }
            try await self.applyAudioPreference()
            guard self.ownsPlaybackIntent(requestID: requestID, generation: generation),
                  self.renderPlayer === player else { throw CancellationError() }
            try await player.load(
                media,
                startPosition: startPosition,
                requestID: requestID,
                aspectRatio: self.rememberedAspectRatio,
                panscan: PlayerViewportPolicy.panscan(siteKey: media.siteKey)
            )
            guard self.ownsPlaybackIntent(
                requestID: requestID, generation: generation
            ) else { throw CancellationError() }
        }
    }

    func play() async throws {
        try await applyAudioPreference()
        try await requireClient().play()
    }

    func pause() async throws {
        try await requireClient().pause()
    }

    func stop(ifOwnedBy requestID: UUID) async {
        if playbackIntentRequestID == requestID { renderPlayer?.cancelPendingMediaLoad(requestID: requestID) }
        guard let ownership = ownershipForRelease(requestID: requestID) else {
            return
        }
        renderPlayer?.cancelPendingMediaLoad(requestID: ownership.requestID)
        _ = try? await serializeLifecycleTransition { [weak self] in
            guard let self else { return }
            await self.transitionSuspensionForTesting?(.stop)
            guard self.ownsPlaybackIntent(
                requestID: ownership.requestID,
                generation: ownership.generation
            ), let capturedClient = self.currentClient else { return }
            await capturedClient.stop()
        }
    }

    func stop() async {
        guard let requestID = playbackIntentRequestID else { return }
        await stop(ifOwnedBy: requestID)
    }

    func seek(to position: TimeInterval) async throws {
        try await requireClient().seek(to: position)
    }

    func rememberVolume(_ volume: Double) { audioPreferences.setVolume(volume) }
    func rememberMuted(_ muted: Bool) { audioPreferences.setMuted(muted) }

    func setVolume(_ volume: Double) async throws {
        rememberVolume(volume)
        try await applyAudioPreference()
    }

    func setMuted(_ muted: Bool) async throws {
        rememberMuted(muted)
        try await applyAudioPreference()
    }

    /// One app-owned worker coalesces commands. Closing a slider cannot cancel persistence.
    func applyAudioPreference() async throws {
        if let audioApplication { try await audioApplication.value; return }
        let identifier = UUID()
        audioApplicationID = identifier
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Retire the worker before completing its Task. A new intent can
            // then never join an already-completed worker while its caller resumes.
            defer {
                if self.audioApplicationID == identifier {
                    self.audioApplication = nil
                    self.audioApplicationID = nil
                }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
            while !self.isShuttingDown {
                let revision = self.audioPreferenceRevision
                let preference = self.audioPreference
                guard let player = self.currentClient else { return }
                do {
                    try await self.audioCommandSuspensionForTesting?()
                    if preference.muted { try await player.setMuted(true) }
                    try await player.setVolume(preference.volume)
                    try await player.setMuted(preference.muted)
                } catch {
                    if self.isShuttingDown { return }
                    if self.currentClient !== player || self.audioPreferenceRevision != revision { continue }
                    throw error
                }
                if self.currentClient === player && self.audioPreferenceRevision == revision { return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        audioApplication = task
        defer {
            if audioApplicationID == identifier { audioApplication = nil; audioApplicationID = nil }
        }
        try await task.value
    }

    private func restoreAudio(to player: MPVPlayerClient) async throws {
        // A user can move the slider while an engine is being created.
        while true {
            let revision = audioPreferenceRevision, preference = audioPreference
            if preference.muted { try await player.setMuted(true) }
            try await player.setVolume(preference.volume)
            try await player.setMuted(preference.muted)
            if revision == audioPreferenceRevision { return }
        }
    }

    func setSpeed(_ speed: Double) async throws {
        rememberedSpeed = speed
        try await requireClient().setSpeed(speed)
    }

    func selectTrack(id: Int, type: MediaTrackType) async throws {
        try await requireClient().selectTrack(id: id, type: type)
    }

    func addSubtitle(url: URL) async throws {
        try await requireClient().addSubtitle(url: url)
    }

    func setSubtitleDelay(_ delay: TimeInterval) async throws {
        rememberedSubtitleDelay = delay
        try await requireClient().setSubtitleDelay(delay)
    }

    func setSubtitleScale(_ scale: Double) async throws {
        rememberedSubtitleScale = scale
        try await requireClient().setSubtitleScale(scale)
    }

    func setSubtitlePosition(_ position: Double) async throws {
        rememberedSubtitlePosition = position
        try await requireClient().setSubtitlePosition(position)
    }

    func setSubtitleBorderSize(_ size: Double) async throws {
        rememberedSubtitleBorderSize = size
        try await requireClient().setSubtitleBorderSize(size)
    }

    func setAudioDelay(_ delay: TimeInterval) async throws {
        rememberedAudioDelay = delay
        try await requireClient().setAudioDelay(delay)
    }

    func setAspectRatio(_ ratio: String?) async throws {
        rememberedAspectRatio = ratio
        try await requireClient().setAspectRatio(ratio)
    }

    func setHardwareDecoding(enabled: Bool) async throws {
        rememberedHardwareDecoding = enabled
        try await requireClient().setHardwareDecoding(enabled: enabled)
    }

    func screenshot(to url: URL) async throws {
        try await requireClient().screenshot(to: url)
    }

    func shutdown() async {
        guard !isShuttingDown else { await lifecycleBarrier?.value; return }
        renderPlayer?.cancelPendingMediaLoad(requestID: playbackIntentRequestID)
        isShuttingDown = true
        playbackIntentGeneration &+= 1
        playbackIntentRequestID = nil
        deferredDestroyTask?.cancel()
        await deferredDestroyTask?.value
        deferredDestroyTask = nil
        deferredDestroyID = nil
        await lifecycleBarrier?.value
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        if let player = currentClient {
            await player.shutdown()
        }
        currentClient = nil
        onRenderClientChanged?(nil)
        continuation.finish()
    }

    private typealias PlaybackOwnership = (requestID: UUID, generation: UInt64)

    private func claimPlaybackIntent(requestID: UUID) -> UInt64 {
        guard playbackIntentRequestID != requestID else {
            return playbackIntentGeneration
        }
        renderPlayer?.cancelPendingMediaLoad(requestID: playbackIntentRequestID)
        playbackIntentGeneration &+= 1
        playbackIntentRequestID = requestID
        return playbackIntentGeneration
    }

    private func ownershipForRelease(requestID: UUID?) -> PlaybackOwnership? {
        if playbackIntentRequestID == nil, let requestID {
            return (requestID, claimPlaybackIntent(requestID: requestID))
        }
        guard let ownedRequestID = playbackIntentRequestID,
              requestID == nil || requestID == ownedRequestID else { return nil }
        return (ownedRequestID, playbackIntentGeneration)
    }

    private func ownsPlaybackIntent(requestID: UUID, generation: UInt64) -> Bool {
        !isShuttingDown
            && playbackIntentRequestID == requestID
            && playbackIntentGeneration == generation
    }

    private func serializeLifecycleTransition<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = lifecycleBarrier
        let operationID = UUID()
        let task = Task<T, Error> { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        lifecycleBarrierID = operationID
        lifecycleBarrier = Task { _ = try? await task.value }
        do {
            let value = try await task.value
            if lifecycleBarrierID == operationID {
                lifecycleBarrier = nil
                lifecycleBarrierID = nil
            }
            return value
        } catch {
            if lifecycleBarrierID == operationID {
                lifecycleBarrier = nil
                lifecycleBarrierID = nil
            }
            throw error
        }
    }

    private func prepareForPlaybackInsideTransition(
        requestID: UUID,
        generation: UInt64,
        compatibilityPolicy: PlaybackCompatibilityPolicy
    ) async throws -> MPVPlayerClient {
        guard ownsPlaybackIntent(
            requestID: requestID, generation: generation
        ), !isShuttingDown else { throw CancellationError() }
        if let player = renderPlayer, player.compatibilityPolicy == compatibilityPolicy { return player }
        if let unavailable = currentClient {
            detachCurrentClient(ifIdenticalTo: unavailable)
            await unavailable.shutdown()
            guard ownsPlaybackIntent(
                requestID: requestID, generation: generation
            ) else { throw CancellationError() }
        }
        let player = try MPVPlayerClient(teardownMode: mode, compatibilityPolicy: compatibilityPolicy, audioPreference: audioPreference)
        do {
            try await applyRememberedSettings(to: player)
            guard ownsPlaybackIntent(
                requestID: requestID, generation: generation
            ) else {
                await player.shutdown()
                throw CancellationError()
            }
        } catch {
            await player.shutdown()
            throw error
        }
        currentClient = player
        startForwardingEvents(from: player)
        onRenderClientChanged?(player)
        PlayerStartupTraceStore.shared.markClientReady(
            requestID: requestID, playerID: player.renderOwnerID
        )
        return player
    }

    private func detachCurrentClient(ifIdenticalTo capturedClient: PlayerClient) {
        guard currentClient === capturedClient else { return }
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        currentClient = nil
        onRenderClientChanged?(nil)
    }

    private func requireClient() throws -> PlayerClient {
        guard let currentClient else {
            throw AppError.playback(L10n.string("player.not-created", fallback: "The player has not been created."))
        }
        return currentClient
    }

    private func startForwardingEvents(from player: PlayerClient) {
        eventForwardingTask?.cancel()
        eventForwardingTask = Task { [weak self, player] in
            for await event in player.events {
                guard !Task.isCancelled else { return }
                guard let self, self.currentClient === player else { return }
                self.continuation.yield(event)
            }
        }
    }

    private func applyRememberedSettings(
        to player: MPVPlayerClient
    ) async throws {
        try await restoreAudio(to: player)
        try await player.setSpeed(rememberedSpeed)
        try await player.setSubtitleDelay(rememberedSubtitleDelay)
        try await player.setSubtitleScale(rememberedSubtitleScale)
        try await player.setSubtitlePosition(rememberedSubtitlePosition)
        try await player.setSubtitleBorderSize(rememberedSubtitleBorderSize)
        try await player.setAudioDelay(rememberedAudioDelay)
        try await player.setAspectRatio(rememberedAspectRatio)
        try await player.setHardwareDecoding(
            enabled: rememberedHardwareDecoding
        )
    }
}

enum PlayerViewportPolicy {
    static func panscan(siteKey: String) -> Double {
        // Window geometry follows mpv's decoded display size. Keep panscan at
        // zero so adapting the outer window never crops subtitles or station
        // logos that are part of the encoded image.
        0
    }
}
