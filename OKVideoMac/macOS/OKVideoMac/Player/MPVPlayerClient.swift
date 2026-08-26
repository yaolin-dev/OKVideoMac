import Foundation
import OKVideoCore

enum PlayerTeardownMode: String, CaseIterable, Sendable {
    case warmStop
    case fullDestroy

    /// Internal rollback switch. The production default is fullDestroy; an
    /// explicit warmStop override can be used if a deployment exposes a
    /// lifecycle regression.
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

enum PlayerLoadTimeoutPolicy {
    static func seconds(for media: ResolvedMedia) -> Int {
        media.siteKey == "live" ? 8 : 30
    }
}

enum MPVPlaybackErrorPolicy {
    static func userFacingMessage(nativeMessage: String) -> String {
        if nativeMessage == "no audio or video data played" {
            return "该线路没有返回可播放的音视频数据"
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

    func reset(requestID: UUID) {
        lock.lock()
        self.requestID = requestID
        fileLoaded = false
        wasClaimed = false
        lock.unlock()
    }

    func markFileLoaded() {
        lock.lock()
        fileLoaded = true
        lock.unlock()
    }

    func claimPlaybackStarted() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard fileLoaded, !wasClaimed, let requestID else { return nil }
        wasClaimed = true
        return requestID
    }

    func cancel() {
        lock.lock()
        requestID = nil
        fileLoaded = false
        wasClaimed = false
        lock.unlock()
    }
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

enum MPVPlaybackEndPolicy {
    static func isNaturalEnd(
        endFileReason: Int32? = nil,
        eofReached: Bool = false,
        isReplacingMedia: Bool
    ) -> Bool {
        guard !isReplacingMedia else { return false }
        return eofReached || endFileReason == 0
    }
}

final class MPVPlayerClient: PlayerClient {
    let events: AsyncStream<PlayerEvent>
    let renderOwnerID = UUID()
    let teardownMode: PlayerTeardownMode

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
        static let none: Int32 = 0
        static let shutdown: Int32 = 1
        static let endFile: Int32 = 7
        static let fileLoaded: Int32 = 8
        static let seek: Int32 = 20
        static let playbackRestart: Int32 = 21
        static let propertyChange: Int32 = 22
        static let queueOverflow: Int32 = 24
    }

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
    private var renderDetachWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRequestID: UUID?
    private var isReplacingMedia = false
    private var didEmitEndedForCurrentMedia = false
    private var pendingStartPosition: TimeInterval?
    private var pendingSubtitles: [URL] = []
    private var didEmitFileLoadedForCurrentMedia = false
    private var startupTimelinePosition: Double?
    private var renderContextCount = 0
    private var pendingLoad: (
        identifier: UUID,
        continuation: CheckedContinuation<Void, Error>
    )?
    private var lastEmittedSnapshot: PlayerSnapshot?
    private var lastTimelineEmissionUptime: UInt64 = 0
    private var timelineEmissionScheduled = false
    private let timelineEmissionIntervalNanoseconds: UInt64 = 100_000_000

    init(
        bundle: Bundle = .main,
        teardownMode: PlayerTeardownMode = .warmStop
    ) throws {
        self.teardownMode = teardownMode
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
            throw AppError.playback("无法创建 libmpv 客户端")
        }
        client = created

        do {
            try setOption("config", value: "no", client: created)
            try setOption("terminal", value: "no", client: created)
            try setOption("input-default-bindings", value: "no", client: created)
            try setOption("input-cursor", value: "no", client: created)
            try setOption("idle", value: "yes", client: created)
            try setOption("keep-open", value: "yes", client: created)
            try setOption("sid", value: "no", client: created)
            try setOption("vo", value: "libmpv", client: created)
            try setOption("hwdec", value: "auto-safe", client: created)
            try setOption("cache", value: "yes", client: created)
            try setOption("audio-client-name", value: "OKVideoMac", client: created)
            // Prefer full Chinese subtitles over the short English "forced"
            // track that many remuxes mark as the container default.
            try setOption("slang", value: "zh-Hans,zh-CN,cmn-Hans,zh,chi,zho", client: created)
            try setOption("subs-with-matching-audio", value: "yes", client: created)
            try library.checked(
                library.initialize(created),
                operation: "初始化 libmpv"
            )
            PlayerExperimentLogger.lifecycle(
                "initialize",
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
        try validate(media: media)
        let loadTimeoutSeconds = PlayerLoadTimeoutPolicy.seconds(for: media)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.isRunning, let client = self.client else {
                    continuation.resume(
                        throwing: AppError.playback("libmpv 已关闭")
                    )
                    return
                }
                let identifier = UUID()
                if let pending = self.pendingLoad {
                    self.pendingLoad = nil
                    pending.continuation.resume(
                        throwing: AppError.playback("播放请求已被新的请求替换")
                    )
                }
                self.currentRequestID = requestID
                self.pendingLoad = (identifier, continuation)
                do {
                    try self.applyViewport(
                        aspectRatio: aspectRatio,
                        panscan: panscan,
                        client: client
                    )
                    try self.applyHTTPHeaders(media.headers, client: client)
                    self.pendingStartPosition = startPosition.flatMap {
                        $0.isFinite && $0 > 0 ? $0 : nil
                    }
                    self.pendingSubtitles = media.subtitles
                    self.isReplacingMedia = true
                    self.didEmitEndedForCurrentMedia = false
                    self.didEmitFileLoadedForCurrentMedia = false
                    self.startupTimelinePosition = nil
                    self.playbackStartSignal.reset(requestID: requestID)
                    self.snapshot.position = 0
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
                        ["loadfile", media.url.absoluteString, "replace"],
                        client: client
                    )
                } catch {
                    PlayerStartupTraceStore.shared.cancel(
                        requestID: requestID
                    )
                    self.snapshot.status = .failed(error.localizedDescription)
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
                        "libmpv 媒体加载超时（\(loadTimeoutSeconds) 秒）"
                    )
                    self.snapshot.status = .failed(error.localizedDescription)
                    self.emitSnapshot()
                    self.completeLoad(.failure(error))
                    _ = try? self.command(["stop"], client: client)
                }
            }
        }
    }

    func play() async throws {
        try await setFlagProperty(
            "pause",
            value: false,
            operation: "继续播放"
        ) { snapshot in
            snapshot.status = .playing
        }
    }

    func pause() async throws {
        try await setFlagProperty(
            "pause",
            value: true,
            operation: "暂停播放"
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
        try? await perform { client in
            self.completeLoad(.failure(CancellationError()))
            try self.command(["stop"], client: client)
            self.clearTransientPlaybackActivity()
            self.snapshot.status = .stopped
            self.emitSnapshot()
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
            guard let target = PlayerSeekPolicy.target(
                requested: position,
                duration: self.snapshot.duration
            ) else {
                throw AppError.playback("跳转位置无效")
            }
            self.snapshot.isSeeking = true
            self.snapshot.seekTarget = target
            self.emitSnapshot()
            do {
                let targetValue = String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    target
                )
                try self.command(
                    ["seek", targetValue, "absolute+keyframes"],
                    client: client
                )
            } catch {
                self.snapshot.isSeeking = false
                self.snapshot.seekTarget = nil
                self.emitSnapshot()
                throw error
            }
        }
    }

    func setVolume(_ volume: Double) async throws {
        let clampedVolume = min(max(volume, 0), 130)
        try await setDoubleProperty(
            "volume",
            value: clampedVolume,
            operation: "设置音量"
        ) { snapshot in
            snapshot.volume = clampedVolume
        }
    }

    func setMuted(_ muted: Bool) async throws {
        try await setFlagProperty(
            "mute",
            value: muted,
            operation: "设置静音"
        ) { snapshot in
            snapshot.isMuted = muted
        }
    }

    func setSpeed(_ speed: Double) async throws {
        guard speed.isFinite, (0.25...4).contains(speed) else {
            throw AppError.playback("播放速度必须在 0.25x 到 4x 之间")
        }
        try await setDoubleProperty(
            "speed",
            value: speed,
            operation: "设置倍速"
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
            operation: "选择媒体轨道"
        )
    }

    func addSubtitle(url: URL) async throws {
        guard url.isFileURL || ["http", "https"].contains(
            url.scheme?.lowercased() ?? ""
        ) else {
            throw AppError.playback("字幕只允许用户选择的文件或 HTTP/HTTPS URL")
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
            operation: "设置字幕延迟"
        )
    }

    func setSubtitleScale(_ scale: Double) async throws {
        guard scale.isFinite, (0.5...3).contains(scale) else {
            throw AppError.playback("字幕大小必须在 50% 到 300% 之间")
        }
        try await setDoubleProperty(
            "sub-scale",
            value: scale,
            operation: "设置字幕大小"
        )
    }

    func setSubtitlePosition(_ position: Double) async throws {
        guard position.isFinite, (0...100).contains(position) else {
            throw AppError.playback("字幕位置必须在 0 到 100 之间")
        }
        try await setDoubleProperty(
            "sub-pos",
            value: position,
            operation: "设置字幕位置"
        )
    }

    func setSubtitleBorderSize(_ size: Double) async throws {
        guard size.isFinite, (0...10).contains(size) else {
            throw AppError.playback("字幕描边必须在 0 到 10 之间")
        }
        try await setDoubleProperty(
            "sub-border-size",
            value: size,
            operation: "设置字幕描边"
        )
    }

    func setAudioDelay(_ delay: TimeInterval) async throws {
        try await setDoubleProperty(
            "audio-delay",
            value: delay,
            operation: "设置音频延迟"
        )
    }

    func setAspectRatio(_ ratio: String?) async throws {
        let value = ratio?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await setStringProperty(
            "video-aspect-override",
            value: value?.isEmpty == false ? value! : "-1",
            operation: "设置画面比例"
        )
    }

    func setHardwareDecoding(enabled: Bool) async throws {
        try await setStringProperty(
            "hwdec",
            value: enabled ? "auto-safe" : "no",
            operation: "设置硬件解码"
        )
    }

    func screenshot(to url: URL) async throws {
        guard url.isFileURL else {
            throw AppError.playback("截图目标必须是本地文件")
        }
        try await perform { client in
            try self.command(
                ["screenshot-to-file", url.path, "subtitles"],
                client: client
            )
        }
    }

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
            throw AppError.playback("libmpv 已关闭")
        }
        var renderContext: OpaquePointer?
        try library.checked(
            library.renderCreate(
                client,
                getProcAddress,
                context,
                &renderContext
            ),
            operation: "创建 mpv OpenGL Render Context"
        )
        guard let renderContext else {
            throw AppError.playback("mpv 未返回 Render Context")
        }
        renderContextCount += 1
        PlayerExperimentLogger.lifecycle(
            "create render context",
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
            operation: "渲染视频帧"
        )
    }

    func reportSwap(_ renderContext: OpaquePointer) {
        library.renderReportSwap(renderContext)
        if let requestID = playbackStartSignal.claimPlaybackStarted() {
            PlayerStartupTraceStore.shared.markFirstRenderSwap(
                playerID: renderOwnerID
            )
            continuation.yield(.playbackStarted(requestID: requestID))
        }
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
                        throwing: AppError.playback("libmpv 已关闭")
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
                    operation: "设置 mpv 选项 \(name)"
                )
            }
        }
    }

    private func command(
        _ arguments: [String],
        client: OpaquePointer
    ) throws {
        guard !arguments.isEmpty,
              !arguments.contains(where: { $0.contains("\0") }) else {
            throw AppError.playback("播放器命令参数无效")
        }
        try withMPVCStringArray(arguments) { pointers in
            try library.checked(
                library.command(client, Int32(arguments.count), pointers),
                operation: "执行 mpv 命令 \(arguments[0])"
            )
        }
    }

    private func setStringProperty(
        _ name: String,
        value: String,
        operation: String
    ) async throws {
        guard !value.contains("\0") else {
            throw AppError.playback("播放器属性包含无效字符")
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
                throw AppError.playback("媒体请求 Header 包含非法换行或空字符")
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
                    operation: "设置媒体请求 Header"
                )
            }
        }
        let userAgent = headers["User-Agent"] ?? "OKVideoMac/0.3.18"
        try setPropertyString(
            "user-agent",
            value: userAgent,
            client: client,
            operation: "设置 User-Agent"
        )
        try setPropertyString(
            "referrer",
            value: headers["Referer"] ?? "",
            client: client,
            operation: "设置 Referer"
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
            operation: "设置加载画面比例"
        )
        let boundedPanscan = min(max(panscan, 0), 1)
        try "panscan".withCString { namePointer in
            try library.checked(
                library.setPropertyDouble(
                    client,
                    namePointer,
                    boundedPanscan
                ),
                operation: "设置加载画面填充"
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
                "播放器不支持该媒体协议：\(scheme ?? "未知")"
            )
        }
        guard !media.url.absoluteString.contains("\0") else {
            throw AppError.playback("媒体 URL 包含无效字符")
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
                    operation: "观察 mpv 属性 \(name)"
                )
            }
        }
    }

    private func pollEvents() {
        guard isRunning, let client else { return }
        // Drain a bounded batch instead of reading only one event every 16 ms.
        // A seek or volume drag can produce several property notifications at
        // once; the old one-at-a-time loop let native events and UI commands
        // queue behind each other.
        var processedCount = 0
        while processedCount < 64, isRunning {
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
            // `keep-open=yes` can preserve a paused EOF state across a
            // loadfile/replace transition. Clear it at the native boundary;
            // AppState performs a second autoplay handshake after load returns.
            try? "pause".withCString { namePointer in
                try library.checked(
                    library.setPropertyFlag(client, namePointer, 0),
                    operation: "开始播放新媒体"
                )
            }
            snapshot.status = .playing
            if let position = pendingStartPosition {
                try? "time-pos".withCString { pointer in
                    try library.checked(
                        library.setPropertyDouble(client, pointer, position),
                        operation: "恢复播放进度"
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
                        operation: "按用户设置关闭字幕"
                    )
                }
            }
            refreshTracks(client: client)
            emitSnapshot()
            if isFirstFileLoaded {
                completeLoad(.success(()))
                continuation.yield(.fileLoaded(requestID: currentRequestID))
            }
        case NativeEvent.endFile:
            if isReplacingMedia {
                guard event.endFileReason != 2 else { return }
                let nativeMessage = event.error < 0
                    ? library.errorString(for: event.error)
                    : "libmpv 在媒体载入完成前结束"
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
            if MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: event.endFileReason,
                isReplacingMedia: isReplacingMedia
            ) {
                emitEndedIfNeeded()
            } else if event.endFileReason == 2 {
                snapshot.status = .stopped
                clearTransientPlaybackActivity()
                emitSnapshot()
            } else if event.error < 0 {
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
            }
        case NativeEvent.propertyChange:
            processProperty(event)
        case NativeEvent.seek:
            snapshot.isSeeking = true
            emitSnapshot()
        case NativeEvent.playbackRestart:
            guard snapshot.isSeeking || snapshot.seekTarget != nil else {
                break
            }
            snapshot.isSeeking = false
            snapshot.seekTarget = nil
            emitSnapshot()
        case NativeEvent.queueOverflow:
            continuation.yield(
                .error(
                    "libmpv 事件队列溢出",
                    requestID: currentRequestID
                )
            )
        case NativeEvent.shutdown:
            clearTransientPlaybackActivity()
            snapshot.status = .stopped
            emitSnapshot()
        default:
            break
        }
    }

    private func processProperty(_ event: NativeMPVEvent) {
        guard let propertyName = event.propertyName else { return }
        let name = String(cString: propertyName)
        switch name {
        case "time-pos":
            let position = max(0, event.doubleValue)
            snapshot.position = position
            if let previous = startupTimelinePosition {
                if abs(position - previous) >= 0.05,
                   let requestID = playbackStartSignal
                    .claimPlaybackStarted() {
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
            if MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: event.flagValue != 0,
                isReplacingMedia: isReplacingMedia
            ) {
                emitEndedIfNeeded()
                return
            }
        case "paused-for-cache":
            snapshot.isPausedForCache = event.flagValue != 0
            if snapshot.isPausedForCache {
                snapshot.status = .buffering
            } else if snapshot.status == .buffering {
                snapshot.status = .playing
            }
        case "seeking":
            snapshot.isSeeking = event.flagValue != 0
            if !snapshot.isSeeking {
                snapshot.seekTarget = nil
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
        if Self.isTimelineProperty(name) {
            emitTimelineSnapshot()
        } else {
            emitSnapshot()
        }
    }

    private func emitSnapshot() {
        guard snapshot != lastEmittedSnapshot else { return }
        lastEmittedSnapshot = snapshot
        lastTimelineEmissionUptime = DispatchTime.now().uptimeNanoseconds
        continuation.yield(
            .snapshot(snapshot, requestID: currentRequestID)
        )
    }

    private func emitEndedIfNeeded() {
        guard !didEmitEndedForCurrentMedia else { return }
        didEmitEndedForCurrentMedia = true
        clearTransientPlaybackActivity()
        snapshot.status = .ended
        if snapshot.duration > 0 {
            snapshot.position = max(snapshot.position, snapshot.duration)
        }
        emitSnapshot()
        continuation.yield(.ended(requestID: currentRequestID))
    }

    private func clearTransientPlaybackActivity() {
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
    private var teardownTask: Task<Void, Never>?
    private var isShuttingDown = false

    private var rememberedVolume: Double = 100
    private var rememberedMuted = false
    private var rememberedSpeed: Double = 1
    private var rememberedSubtitleDelay: TimeInterval = 0
    private var rememberedSubtitleScale: Double = 1
    private var rememberedSubtitlePosition: Double = 100
    private var rememberedSubtitleBorderSize: Double = 3
    private var rememberedAudioDelay: TimeInterval = 0
    private var rememberedAspectRatio: String?
    private var rememberedHardwareDecoding = true
    private var usesFixedLiveWindow = false

    init(mode: PlayerTeardownMode = .configured()) {
        self.mode = mode
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            captured = $0
        }
        continuation = captured

        do {
            let player = try MPVPlayerClient(teardownMode: mode)
            currentClient = player
            startForwardingEvents(from: player)
        } catch {
            let unavailable = UnavailablePlayerClient(
                reason: "libmpv 不可用：\(LogRedactor.text(error.localizedDescription))"
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
        renderPlayer?.runtimeDescription ?? "libmpv 不可用"
    }

    @discardableResult
    func prepareForPlayback(requestID: UUID) async throws -> MPVPlayerClient {
        if let teardownTask {
            await teardownTask.value
        }
        guard !isShuttingDown else {
            throw AppError.playback("播放器正在关闭")
        }
        if let player = renderPlayer {
            PlayerStartupTraceStore.shared.markClientReady(
                requestID: requestID,
                playerID: player.renderOwnerID
            )
            return player
        }

        PlayerExperimentLogger.lifecycle(
            "recreate begin",
            playerID: nil,
            requestID: requestID,
            mode: mode
        )
        let player = try MPVPlayerClient(teardownMode: mode)
        do {
            try await applyRememberedSettings(to: player)
        } catch {
            await player.shutdown()
            throw error
        }
        currentClient = player
        startForwardingEvents(from: player)
        onRenderClientChanged?(player)
        PlayerStartupTraceStore.shared.markClientReady(
            requestID: requestID,
            playerID: player.renderOwnerID
        )
        PlayerExperimentLogger.lifecycle(
            "recreate ready",
            playerID: player.renderOwnerID,
            requestID: requestID,
            mode: mode
        )
        return player
    }

    func closeAfterPlayback(requestID: UUID?) async {
        await stop()
        guard mode == .fullDestroy else { return }
        await fullDestroy(requestID: requestID)
    }

    func fullDestroy(requestID: UUID?) async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard let player = currentClient else { return }
        let playerID = (player as? MPVPlayerClient)?.renderOwnerID
        PlayerExperimentLogger.lifecycle(
            "full destroy begin",
            playerID: playerID,
            requestID: requestID,
            mode: mode
        )
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        let task = Task { @MainActor [weak self, player] in
            await player.shutdown()
            guard let self else { return }
            if self.currentClient === player {
                self.currentClient = nil
                self.onRenderClientChanged?(nil)
            }
            if let playerID {
                PlayerStartupTraceStore.shared.cancel(playerID: playerID)
            }
            PlayerExperimentLogger.lifecycle(
                "full destroy end",
                playerID: playerID,
                requestID: requestID,
                mode: self.mode
            )
        }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID,
        waitForRenderSurface: ((UUID) async throws -> Void)? = nil
    ) async throws {
        let player = try await prepareForPlayback(requestID: requestID)
        if let waitForRenderSurface {
            try await waitForRenderSurface(player.renderOwnerID)
            try Task.checkCancellation()
            guard renderPlayer === player else {
                throw CancellationError()
            }
        }
        usesFixedLiveWindow = PlayerViewportPolicy.usesFixedLiveWindow(
            siteKey: media.siteKey
        )
        try await player.load(
            media,
            startPosition: startPosition,
            requestID: requestID,
            aspectRatio: usesFixedLiveWindow ? nil : rememberedAspectRatio,
            panscan: PlayerViewportPolicy.panscan(siteKey: media.siteKey)
        )
    }

    func play() async throws {
        try await requireClient().play()
    }

    func pause() async throws {
        try await requireClient().pause()
    }

    func stop() async {
        await currentClient?.stop()
    }

    func seek(to position: TimeInterval) async throws {
        try await requireClient().seek(to: position)
    }

    func setVolume(_ volume: Double) async throws {
        rememberedVolume = volume
        try await requireClient().setVolume(volume)
    }

    func setMuted(_ muted: Bool) async throws {
        rememberedMuted = muted
        try await requireClient().setMuted(muted)
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
        guard !usesFixedLiveWindow else { return }
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
        guard !isShuttingDown else {
            if let teardownTask {
                await teardownTask.value
            }
            return
        }
        isShuttingDown = true
        if let teardownTask {
            await teardownTask.value
        }
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        if let player = currentClient {
            await player.shutdown()
        }
        currentClient = nil
        onRenderClientChanged?(nil)
        continuation.finish()
    }

    private func requireClient() throws -> PlayerClient {
        guard let currentClient else {
            throw AppError.playback("播放器尚未创建")
        }
        return currentClient
    }

    private func startForwardingEvents(from player: PlayerClient) {
        eventForwardingTask?.cancel()
        eventForwardingTask = Task { [weak self, player] in
            for await event in player.events {
                guard !Task.isCancelled else { return }
                self?.continuation.yield(event)
            }
        }
    }

    private func applyRememberedSettings(
        to player: MPVPlayerClient
    ) async throws {
        try await player.setVolume(rememberedVolume)
        try await player.setMuted(rememberedMuted)
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
    static func usesFixedLiveWindow(siteKey: String) -> Bool {
        siteKey == "live"
    }

    static func panscan(siteKey: String) -> Double {
        // A fixed 16:9 live window must not imply destructive cropping.
        // libmpv keeps the stream's display aspect ratio and naturally adds
        // pillarbox/letterbox bars when an older source does not match 16:9.
        0
    }
}
