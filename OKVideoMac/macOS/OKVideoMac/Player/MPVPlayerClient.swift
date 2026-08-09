import Foundation
import OKVideoCore

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
        static let propertyChange: Int32 = 22
        static let queueOverflow: Int32 = 24
    }

    private let library: MPVLibrary
    private let queue = DispatchQueue(
        label: "com.okvideomac.player.libmpv",
        qos: .userInitiated
    )
    private let lifecycleLock = NSLock()
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var client: OpaquePointer?
    private var snapshot = PlayerSnapshot()
    private var isShutdown = false
    private var isReplacingMedia = false
    private var didEmitEndedForCurrentMedia = false
    private var pendingStartPosition: TimeInterval?
    private var pendingSubtitles: [URL] = []
    private var renderContextCount = 0
    private var pendingLoad: (
        identifier: UUID,
        continuation: CheckedContinuation<Void, Error>
    )?
    private var lastEmittedSnapshot: PlayerSnapshot?
    private var lastTimelineEmissionUptime: UInt64 = 0
    private var timelineEmissionScheduled = false
    private let timelineEmissionIntervalNanoseconds: UInt64 = 100_000_000

    init(bundle: Bundle = .main) throws {
        var captured: AsyncStream<PlayerEvent>.Continuation!
        // Keep the bridge bounded even if the main actor is briefly busy with
        // a menu, window transition, or a slow database operation.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            captured = $0
        }
        continuation = captured
        library = try MPVLibrary(bundle: bundle)
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
        lifecycleLock.lock()
        if let client {
            library.wakeup(client)
            library.destroy(client)
        }
        lifecycleLock.unlock()
        continuation.finish()
    }

    func load(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?
    ) async throws {
        try validate(media: media)
        try await waitForRenderContext()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.isShutdown, let client = self.client else {
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
                self.pendingLoad = (identifier, continuation)
                do {
                    try self.applyHTTPHeaders(media.headers, client: client)
                    self.pendingStartPosition = startPosition.flatMap {
                        $0.isFinite && $0 > 0 ? $0 : nil
                    }
                    self.pendingSubtitles = media.subtitles
                    self.isReplacingMedia = true
                    self.didEmitEndedForCurrentMedia = false
                    self.snapshot.position = 0
                    self.snapshot.duration = 0
                    self.snapshot.bufferedPercent = 0
                    self.snapshot.networkSpeedBytesPerSecond = 0
                    self.snapshot.videoWidth = 0
                    self.snapshot.videoHeight = 0
                    self.snapshot.status = .loading
                    self.emitSnapshot()
                    try self.command(
                        ["loadfile", media.url.absoluteString, "replace"],
                        client: client
                    )
                } catch {
                    self.snapshot.status = .failed(error.localizedDescription)
                    self.emitSnapshot()
                    self.completeLoad(.failure(error))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + .seconds(30)) {
                    guard self.pendingLoad?.identifier == identifier else {
                        return
                    }
                    let error = AppError.playback("libmpv 媒体加载超时（30 秒）")
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
        try? await perform { client in
            self.completeLoad(.failure(CancellationError()))
            try self.command(["stop"], client: client)
            self.snapshot.status = .stopped
            self.emitSnapshot()
        }
    }

    func seek(to position: TimeInterval) async throws {
        guard let target = PlayerSeekPolicy.target(
            requested: position,
            duration: snapshot.duration
        ) else {
            throw AppError.playback("跳转位置无效")
        }
        try await perform { client in
            try "time-pos".withCString { namePointer in
                try self.library.checked(
                    self.library.setPropertyDouble(client, namePointer, target),
                    operation: "跳转"
                )
            }
            // Do not make the UI depend exclusively on a later property-change
            // event. A successful set means mpv accepted this seek target.
            self.snapshot.position = target
            self.emitSnapshot()
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
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.isShutdown else {
                    continuation.resume()
                    return
                }
                self.isShutdown = true
                self.lifecycleLock.lock()
                if let client = self.client {
                    self.completeLoad(.failure(CancellationError()))
                    _ = try? self.command(["stop"], client: client)
                    self.library.wakeup(client)
                    self.library.destroy(client)
                    self.client = nil
                }
                self.lifecycleLock.unlock()
                self.continuation.finish()
                continuation.resume()
            }
        }
    }

    func makeRenderContext(
        getProcAddress: MPVGetProcAddress?,
        context: UnsafeMutableRawPointer?
    ) throws -> OpaquePointer {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let client, !isShutdown else {
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
    }

    func destroyRenderContext(_ renderContext: OpaquePointer) {
        library.renderSetUpdateCallback(renderContext, nil, nil)
        library.renderDestroy(renderContext)
        lifecycleLock.lock()
        renderContextCount = max(0, renderContextCount - 1)
        lifecycleLock.unlock()
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
                guard !self.isShutdown, let client = self.client else {
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

    private func waitForRenderContext() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if hasActiveRenderContext() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AppError.playback("播放器窗口未能在 5 秒内建立 OpenGL Render Context")
    }

    private func hasActiveRenderContext() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return renderContextCount > 0 && !isShutdown
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
            (14, "dheight", NativeFormat.int64)
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
        guard !isShutdown, let client else { return }
        // Drain a bounded batch instead of reading only one event every 16 ms.
        // A seek or volume drag can produce several property notifications at
        // once; the old one-at-a-time loop let native events and UI commands
        // queue behind each other.
        var processedCount = 0
        while processedCount < 64, !isShutdown {
            var event = NativeMPVEvent()
            let result = withUnsafeMutablePointer(to: &event) { eventPointer in
                library.waitEvent(
                    client,
                    0,
                    UnsafeMutableRawPointer(eventPointer)
                )
            }
            if result < 0 {
                continuation.yield(.error(library.errorString(for: result)))
                break
            }
            guard event.eventID != NativeEvent.none else { break }
            process(event)
            processedCount += 1
        }
        guard !isShutdown else { return }
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
            isReplacingMedia = false
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
            completeLoad(.success(()))
            continuation.yield(.fileLoaded)
        case NativeEvent.endFile:
            if isReplacingMedia {
                guard event.endFileReason != 2 else { return }
                let message = event.error < 0
                    ? library.errorString(for: event.error)
                    : "libmpv 在媒体载入完成前结束"
                snapshot.status = .failed(message)
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
                emitSnapshot()
            } else if event.error < 0 {
                let message = library.errorString(for: event.error)
                snapshot.status = .failed(message)
                emitSnapshot()
                continuation.yield(.error(message))
            }
        case NativeEvent.propertyChange:
            processProperty(event)
        case NativeEvent.queueOverflow:
            continuation.yield(.error("libmpv 事件队列溢出"))
        case NativeEvent.shutdown:
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
            snapshot.position = max(0, event.doubleValue)
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
            if event.flagValue != 0 {
                snapshot.status = .buffering
            } else if snapshot.status == .buffering {
                snapshot.status = .playing
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
        continuation.yield(.snapshot(snapshot))
    }

    private func emitEndedIfNeeded() {
        guard !didEmitEndedForCurrentMedia else { return }
        didEmitEndedForCurrentMedia = true
        snapshot.status = .ended
        if snapshot.duration > 0 {
            snapshot.position = max(snapshot.position, snapshot.duration)
        }
        emitSnapshot()
        continuation.yield(.ended)
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
            guard !self.isShutdown else { return }
            self.emitSnapshot()
        }
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
