import Foundation

public enum PlaybackResolutionState: Equatable, Sendable {
    case idle
    case restoringHistory
    case resolving
    case validating
    case loading
    case playing
    case retrying
    case exhausted
    case failed
}

public struct PlaybackCandidate: Equatable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var sourceName: String
    public var episodeName: String
    public var result: SitePlaybackResult
    public var danmakuContext: DanmakuPlaybackContext?

    public init(
        siteKey: String,
        siteName: String,
        sourceName: String,
        episodeName: String,
        result: SitePlaybackResult,
        danmakuContext: DanmakuPlaybackContext? = nil
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.result = result
        self.danmakuContext = danmakuContext
    }
}

public struct PlaybackResolutionRequest: Equatable, Sendable {
    public var candidates: [PlaybackCandidate]
    public var parsers: [ParseConfiguration]
    public var maximumAttempts: Int

    public init(
        candidates: [PlaybackCandidate],
        parsers: [ParseConfiguration],
        maximumAttempts: Int = 8
    ) {
        self.candidates = candidates
        self.parsers = parsers
        self.maximumAttempts = min(max(1, maximumAttempts), 32)
    }
}

public enum MediaTransportProfile: Equatable, Sendable {
    /// Ordinary native/direct playback. Existing buffering and startup
    /// behavior remains unchanged for this profile.
    case standard
    /// Media produced by a TVBox/CatVod Java spider. These URLs often sit
    /// behind a provider-owned loopback relay and need bounded per-file cache
    /// and event-driven startup/seek handling.
    case tvBox
}

/// Runtime-only opt-in. Existing providers do not inherit Native Xtream fixes.
public enum PlaybackCompatibilityPolicy: Equatable, Sendable {
    case existing
    case nativeXtreamLive
}

/// Runtime intent supplied by a native provider, never a saved proxy endpoint
/// or an option decoded from an untrusted provider response.
public enum MediaNetworkPolicy: Equatable, Sendable {
    case inherited
    case systemHTTPProxy
}

public struct ResolvedMedia: Equatable, Sendable {
    /// Host-owned subtitle preference scope; independent of reusable proxy URLs.
    public var subtitlePreferenceIdentity: String? = nil
    /// Host-owned playback preference snapshot; never decoded from a provider.
    public var mediaProxyPreference: Bool? = nil
    public var mediaNetworkRouteOverride: PlaybackMediaNetworkRoute? = nil
    /// File-local stop boundary for a bounded catch-up programme.
    public var playbackDurationLimit: TimeInterval? = nil
    public var playbackStartOffset: TimeInterval? = nil
    public var url: URL
    public var headers: HTTPHeaders
    public var format: String?
    public var subtitles: [URL]
    public var siteKey: String
    public var sourceName: String
    public var episodeName: String
    public var parserName: String?
    public var transportProfile: MediaTransportProfile
    public var nativeStartupBudgetSeconds: Int?
    public var hlsStartupSelection: HLSStartupSelection?
    public var compatibilityPolicy: PlaybackCompatibilityPolicy
    public var networkPolicy: MediaNetworkPolicy
    public var transferReceipt: TransferReceipt?
    public var danmakuContext: DanmakuPlaybackContext?

    public init(
        url: URL,
        headers: HTTPHeaders,
        format: String? = nil,
        subtitles: [URL] = [],
        siteKey: String,
        sourceName: String,
        episodeName: String,
        parserName: String? = nil,
        transportProfile: MediaTransportProfile = .standard,
        nativeStartupBudgetSeconds: Int? = nil,
        hlsStartupSelection: HLSStartupSelection? = nil,
        compatibilityPolicy: PlaybackCompatibilityPolicy = .existing,
        networkPolicy: MediaNetworkPolicy = .inherited,
        transferReceipt: TransferReceipt? = nil,
        danmakuContext: DanmakuPlaybackContext? = nil
    ) {
        self.url = url
        self.headers = headers
        self.format = format
        self.subtitles = subtitles
        self.siteKey = siteKey
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.parserName = parserName
        self.transportProfile = transportProfile
        self.nativeStartupBudgetSeconds = nativeStartupBudgetSeconds
        self.hlsStartupSelection = hlsStartupSelection
        self.compatibilityPolicy = compatibilityPolicy
        self.networkPolicy = networkPolicy
        self.transferReceipt = transferReceipt
        self.danmakuContext = danmakuContext
    }
}

public struct PlaybackAttempt: Equatable, Sendable {
    public var siteName: String
    public var sourceName: String
    public var episodeName: String
    public var parserName: String?
    public var redactedURL: String
    public var number: Int

    public init(
        siteName: String,
        sourceName: String,
        episodeName: String,
        parserName: String?,
        redactedURL: String,
        number: Int
    ) {
        self.siteName = siteName
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.parserName = parserName
        self.redactedURL = redactedURL
        self.number = number
    }
}

public enum PlaybackPreparationIssue: Error, Equatable, LocalizedError, Sendable {
    case missingParser
    case httpStatus(Int)
    case nonMedia

    public var allowsAutomaticRefresh: Bool {
        if case .httpStatus(let status) = self { return [401, 403, 404, 408, 410, 429].contains(status) || status >= 500 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .missingParser: return "该线路需要解析，但当前配置没有可用解析器。请检查播放配置或打开原网页。"
        case .httpStatus(let status):
            switch status {
            case 401, 403: return "上游拒绝了媒体请求（HTTP \(status)）。请检查上游服务或授权状态。"
            case 404, 410: return "媒体地址不可用（HTTP \(status)）。请更换线路或等待上游恢复。"
            default: return "媒体线路返回 HTTP 状态码 \(status)"
            }
        case .nonMedia: return "该地址返回了网页或错误数据，未取得可播放的媒体。"
        }
    }
}

public enum PlaybackResolutionEvent: Equatable, Sendable {
    case preparationIssue(PlaybackPreparationIssue?)
    case state(PlaybackResolutionState)
    case attempting(PlaybackAttempt)
    case attemptFailed(PlaybackAttempt, message: String)
    case resolved(ResolvedMedia)
    case failed(message: String)
    case cancelled
}

public struct ParsedMedia: Equatable, Sendable {
    public var url: URL
    public var headers: HTTPHeaders
    public var format: String?

    public init(url: URL, headers: HTTPHeaders = [:], format: String? = nil) {
        self.url = url
        self.headers = headers
        self.format = format
    }
}

public protocol ParseExecutor {
    func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia
}

public protocol MediaProbe {
    func validate(url: URL, headers: HTTPHeaders) async throws -> Bool
    func validateParsingFallback(url: URL, headers: HTTPHeaders) async throws -> Bool
}

public extension MediaProbe {
    func validateParsingFallback(url: URL, headers: HTTPHeaders) async throws -> Bool {
        try await validate(url: url, headers: headers)
    }
}

public typealias PlaybackMediaLoader = (
    ResolvedMedia,
    PlaybackAttempt
) async throws -> Void

public struct DefaultMediaProbe: MediaProbe {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    public func validate(url: URL, headers: HTTPHeaders) async throws -> Bool {
        try await validate(url: url, headers: headers, requiresMediaSignature: false)
    }

    public func validateParsingFallback(url: URL, headers: HTTPHeaders) async throws -> Bool {
        try await validate(url: url, headers: headers, requiresMediaSignature: true)
    }

    private func validate(url: URL, headers: HTTPHeaders, requiresMediaSignature: Bool) async throws -> Bool {
        if url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }

        // The Android cloud-drive original-quality server intentionally
        // serves a byte range while reporting the full file Content-Length.
        // URLSession rejects that otherwise valid response as -1005 because
        // the received byte count does not match the advertised multi-GB
        // length. libmpv handles this server correctly, so let the player do
        // the authoritative load check for this one controlled loopback
        // endpoint instead of rejecting every original-quality line here.
        if !requiresMediaSignature && Self.isAndroidCloudOriginalProxy(url) {
            return true
        }

        let isAndroidBridgeSession = Self.isAndroidBridgeMediaSession(url)
        let isNodeRuntimeProxy = Self.isNodeRuntimeMediaProxy(url)

        var probeHeaders = headers
        // A single bounded byte request proves both reachability and body
        // shape. HEAD is frequently unsupported by cloud proxies and doing
        // both requests doubles startup latency without adding evidence.
        probeHeaders["Range"] = "bytes=0-16383"
        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: probeHeaders,
                    timeout: 8,
                    maximumResponseBytes: 128 * 1_024,
                    responsePrefixBytes: 16_384,
                    maximumRedirects: 4,
                    redirectedHeaderFields: ["Range", "Referer", "User-Agent"],
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
            )
            if !(200...299).contains(response.statusCode),
               isAndroidBridgeSession,
               let bridgeFailure = Self.androidBridgeFailure(response) {
                throw AppError.playback(bridgeFailure)
            }
            switch response.statusCode {
            case 200...299:
                break
            default:
                throw PlaybackPreparationIssue.httpStatus(response.statusCode)
            }
            let valid = Self.looksLikeMediaBytes(response)
                && (!requiresMediaSignature || Self.hasMediaSignature(response.body))
            if !valid, isNodeRuntimeProxy || isAndroidBridgeSession {
                throw PlaybackPreparationIssue.nonMedia
            }
            return valid
        } catch HTTPClientError.responseTooLarge {
            throw PlaybackPreparationIssue.nonMedia
        }
    }

    static func hasMediaSignature(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(512))
        guard b.count >= 4 else { return false }
        if b.count >= 8, let atom = String(bytes: b[4..<8], encoding: .ascii),
           ["ftyp", "moov", "mdat", "wide", "free", "styp"].contains(atom) { return true }
        if b.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) || b.starts(with: [0x4f, 0x67, 0x67, 0x53])
            || b.starts(with: [0x46, 0x4c, 0x56]) || b.starts(with: [0x49, 0x44, 0x33])
            || b.starts(with: [0x52, 0x49, 0x46, 0x46]) || b.starts(with: [0x66, 0x4c, 0x61, 0x43]) { return true }
        if b.count > 188, b[0] == 0x47, b[188] == 0x47 { return true }
        if b[0] == 0xff, b[1] & 0xe0 == 0xe0 { return true }
        let text = String(decoding: b, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        return text.hasPrefix("#EXTM3U")
            || text.range(of: "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?MPD(?:[ >\\t\\r\\n])", options: .regularExpression) != nil
    }

    private static func androidBridgeFailure(
        _ response: HTTPResponse
    ) -> String? {
        guard response.body.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: response.body)
                as? [String: Any],
              let error = object["error"] as? String else {
            return nil
        }
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        switch message {
        case "TVBox local proxy is not ready",
             "TVBox local proxy port is unavailable":
            return "TVBox 本地代理未就绪"
        case "Spider internal proxy failed",
             "Invalid Spider proxy response",
             "Provider media proxy failed":
            return "Spider 内部代理处理失败"
        case "Media session expired or missing":
            return "播放会话已过期，请重新解析"
        default:
            return message
        }
    }

    private static func looksLikeMedia(_ response: HTTPResponse) -> Bool {
        let contentType = response.headers["Content-Type"]?.lowercased() ?? ""
        return contentType.hasPrefix("video/")
            || contentType.hasPrefix("audio/")
            || contentType.contains("mpegurl")
            || contentType.contains("dash+xml")
            || contentType.contains("octet-stream")
    }

    private static func looksLikeMediaBytes(_ response: HTTPResponse) -> Bool {
        guard !response.body.isEmpty else { return false }
        let contentType = response.headers["Content-Type"]?.lowercased() ?? ""
        if contentType.contains("json")
            || contentType.contains("text/html")
            || contentType.contains("application/xhtml") {
            return false
        }
        let prefix = response.body.prefix(512)
        if let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           text.hasPrefix("{")
            || text.hasPrefix("[")
            || text.hasPrefix("<!doctype html")
            || text.hasPrefix("<html") {
            return false
        }
        return hasMediaSignature(response.body) || looksLikeMedia(response)
            || response.statusCode == 206
            || contentType.isEmpty
    }

    static func isAndroidCloudOriginalProxy(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "127.0.0.1" else {
            return false
        }
        switch url.port {
        case 16_677:
            return url.path.hasPrefix("/proxy/play/")
        case 18_096:
            return url.path.hasPrefix("/kaiser")
        case 19_978:
            return url.path == "/v1/media"
        default:
            return false
        }
    }

    static func isNodeRuntimeMediaProxy(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ),
              url.port != nil else {
            return false
        }
        guard !isAndroidBridgeMediaSession(url) else { return false }
        return (url.path.hasPrefix("/spider/") && url.path.contains("/proxy"))
            || url.path.hasPrefix("/proxy/")
    }

    static func isAndroidBridgeMediaSession(_ url: URL) -> Bool {
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
}

public struct JSONParseExecutor: ParseExecutor {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    public func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        guard parser.type == 1 else {
            throw AppError.unsupported("JSONParseExecutor 仅支持 type 1")
        }
        guard let endpoint = URL(string: parser.url + inputURL),
              ["http", "https"].contains(endpoint.scheme?.lowercased() ?? "") else {
            throw AppError.parsing("解析器 \(parser.name) 生成了非法 URL")
        }
        let mergedHeaders = headers.merging(HTTPHeaders(parser.headers))
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                headers: mergedHeaders,
                timeout: 15,
                maximumResponseBytes: 2 * 1_024 * 1_024,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 1)
            )
        )
        let root = try JSONDecoder().decode(JSONValue.self, from: response.body)
        guard case .object(let object) = root else {
            throw AppError.parsing("解析器 \(parser.name) 响应顶层不是对象")
        }

        let rawURL = Self.string(object["url"])
            ?? object["data"]?.objectValue.flatMap { Self.string($0["url"]) }
        guard let rawURL, let mediaURL = URL(string: rawURL),
              ["http", "https", "file"].contains(mediaURL.scheme?.lowercased() ?? "") else {
            throw AppError.parsing("解析器 \(parser.name) 未返回有效媒体 URL")
        }
        let responseHeaders = Self.allowedHeaders(from: object["header"])
        return ParsedMedia(
            url: mediaURL,
            headers: mergedHeaders.merging(HTTPHeaders(responseHeaders)),
            format: Self.string(object["format"])
        )
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func allowedHeaders(from value: JSONValue?) -> [String: String] {
        guard case .object(let object) = value else { return [:] }
        let allowed = ["user-agent", "referer", "cookie", "origin"]
        return Dictionary(uniqueKeysWithValues: object.compactMap { key, value in
            guard allowed.contains(key.lowercased()),
                  let string = string(value) else {
                return nil
            }
            return (key, string)
        })
    }
}

public struct PlaybackResolver {
    private let parseExecutor: ParseExecutor
    private let mediaProbe: MediaProbe

    public init(parseExecutor: ParseExecutor, mediaProbe: MediaProbe) {
        self.parseExecutor = parseExecutor
        self.mediaProbe = mediaProbe
    }

    public func resolve(
        _ request: PlaybackResolutionRequest
    ) -> AsyncStream<PlaybackResolutionEvent> {
        resolve(request, mediaLoader: nil)
    }

    public func resolve(
        _ request: PlaybackResolutionRequest,
        mediaLoader: @escaping PlaybackMediaLoader
    ) -> AsyncStream<PlaybackResolutionEvent> {
        resolve(request, mediaLoader: Optional(mediaLoader))
    }

    private func resolve(
        _ request: PlaybackResolutionRequest,
        mediaLoader: PlaybackMediaLoader?
    ) -> AsyncStream<PlaybackResolutionEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(
                    request,
                    mediaLoader: mediaLoader,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func run(
        _ request: PlaybackResolutionRequest,
        mediaLoader: PlaybackMediaLoader?,
        continuation: AsyncStream<PlaybackResolutionEvent>.Continuation
    ) async {
        continuation.yield(.state(.resolving))
        var attempted = Set<String>()
        var attemptNumber = 0
        var failureMessages: [String] = []

        for candidate in request.candidates {
            if Task.isCancelled {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }

            let parserOrder = orderedParsers(for: candidate.result, all: request.parsers)
            var options: [(ParseConfiguration?, String)] = []
            if !candidate.result.needsParsing { options.append((nil, candidate.result.url)) }
            options.append(contentsOf: parserOrder.map { ($0, candidate.result.url) })
            // Legacy scripts can mark real media as parse=1. Parsers have
            // priority; only bounded byte evidence may admit a direct fallback.
            if candidate.result.needsParsing && MediaURLClassifier.isDirectMediaURL(candidate.result.url) {
                options.append((nil, candidate.result.url))
            }
            if options.isEmpty, candidate.result.needsParsing {
                continuation.yield(.preparationIssue(.missingParser))
                failureMessages.append("\(candidate.sourceName)：\(PlaybackPreparationIssue.missingParser.localizedDescription)")
            }

            for (parser, inputURL) in options {
                guard attemptNumber < request.maximumAttempts else {
                    continuation.yield(.state(.exhausted))
                    continuation.yield(.failed(message: failureSummary(failureMessages)))
                    continuation.finish()
                    return
                }
                if Task.isCancelled {
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                }

                let identity = [
                    candidate.siteKey,
                    candidate.sourceName,
                    parser?.name ?? "<direct>",
                    inputURL
                ].joined(separator: "|")
                guard attempted.insert(identity).inserted else { continue }

                continuation.yield(.preparationIssue(nil))
                attemptNumber += 1
                let attempt = PlaybackAttempt(
                    siteName: candidate.siteName,
                    sourceName: candidate.sourceName,
                    episodeName: candidate.episodeName,
                    parserName: parser?.name,
                    redactedURL: URL(string: inputURL).map(LogRedactor.url) ?? "<invalid>",
                    number: attemptNumber
                )
                continuation.yield(.attempting(attempt))

                do {
                    let parsed: ParsedMedia
                    if let parser {
                        continuation.yield(.state(.resolving))
                        parsed = try await parseExecutor.resolve(
                            parser: parser,
                            inputURL: inputURL,
                            headers: candidate.result.headers
                        )
                    } else {
                        guard let url = URL(string: inputURL) else {
                            throw AppError.parsing("媒体 URL 无效")
                        }
                        parsed = ParsedMedia(
                            url: url,
                            headers: candidate.result.headers,
                            format: candidate.result.format
                        )
                    }
                    guard MediaURLClassifier.isSupportedAbsoluteMediaURL(
                        parsed.url
                    ) else {
                        throw AppError.parsing(
                            "播放器拒绝了非绝对或不受支持的媒体地址"
                        )
                    }
                    continuation.yield(.state(.validating))
                    let requiresPreflight = parser != nil || candidate.result.needsParsing
                        || candidate.result.validationPolicy
                            != .playerAuthoritative
                    if requiresPreflight {
                        let valid: Bool
                        if parser == nil && candidate.result.needsParsing {
                            valid = try await mediaProbe.validateParsingFallback(url: parsed.url, headers: parsed.headers)
                        } else {
                            valid = try await mediaProbe.validate(url: parsed.url, headers: parsed.headers)
                        }
                        guard valid else {
                            throw candidate.result.needsParsing && parserOrder.isEmpty
                                ? PlaybackPreparationIssue.missingParser : PlaybackPreparationIssue.nonMedia
                        }
                    }
                    let resolved = ResolvedMedia(
                        url: parsed.url,
                        headers: parsed.headers,
                        format: parsed.format ?? candidate.result.format,
                        subtitles: candidate.result.subtitles,
                        siteKey: candidate.siteKey,
                        sourceName: candidate.sourceName,
                        episodeName: candidate.episodeName,
                        parserName: parser?.name,
                        networkPolicy: candidate.result.networkPolicy,
                        transferReceipt: candidate.result.transferReceipt,
                        danmakuContext: candidate.danmakuContext
                    )
                    continuation.yield(.state(.loading))
                    if let mediaLoader {
                        do {
                            try await mediaLoader(resolved, attempt)
                        } catch {
                            if candidate.result.validationPolicy
                                == .playerAuthoritative,
                               DefaultMediaProbe.isAndroidBridgeMediaSession(
                                parsed.url
                               ) {
                                do {
                                    let reachable = try await mediaProbe.validate(
                                        url: parsed.url,
                                        headers: parsed.headers
                                    )
                                    if !reachable {
                                        throw AppError.playback(
                                            "Android 内部播放代理没有返回媒体数据"
                                        )
                                    }
                                } catch {
                                    throw AppError.playback(
                                        "Android 内部播放代理无法取得上游媒体："
                                            + error.localizedDescription
                                    )
                                }
                            }
                            throw error
                        }
                        continuation.yield(.state(.playing))
                    }
                    continuation.yield(.resolved(resolved))
                    continuation.finish()
                    return
                } catch is CancellationError {
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                } catch {
                    continuation.yield(.preparationIssue(error as? PlaybackPreparationIssue))
                    let message = error.localizedDescription
                    failureMessages.append(
                        "\(candidate.sourceName)/\(parser?.name ?? "直链")：\(message)"
                    )
                    continuation.yield(.attemptFailed(attempt, message: message))
                    continuation.yield(.state(.retrying))
                }
            }
        }

        continuation.yield(.state(.exhausted))
        continuation.yield(.failed(message: failureSummary(failureMessages)))
        continuation.finish()
    }

    private func orderedParsers(
        for result: SitePlaybackResult,
        all parsers: [ParseConfiguration]
    ) -> [ParseConfiguration] {
        let supported = parsers.filter { $0.type == 0 || $0.type == 1 }
        if let playURL = result.playURL {
            if playURL.hasPrefix("parse:") {
                let name = String(playURL.dropFirst("parse:".count))
                if let specified = supported.first(where: { $0.name == name }) {
                    return [specified] + supported.filter { $0.name != name }
                }
            } else if playURL.hasPrefix("json:") {
                let url = String(playURL.dropFirst("json:".count))
                let synthetic = ParseConfiguration(name: "指定 JSON 解析", type: 1, url: url)
                return [synthetic] + supported.filter { $0.url != url }
            } else if let url = URL(string: playURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                let synthetic = ParseConfiguration(name: "指定网页解析", type: 0, url: playURL)
                return [synthetic] + supported.filter { $0.url != playURL }
            }
        }
        let matching = supported.filter {
            !$0.flags.isEmpty && $0.flags.contains(result.flag)
        }
        let matchingNames = Set(matching.map(\.name))
        return matching + supported.filter { !matchingNames.contains($0.name) }
    }

    private func failureSummary(_ messages: [String]) -> String {
        if messages.isEmpty {
            return "没有可用的直链或解析器"
        }
        return messages.suffix(4).joined(separator: "；")
    }
}
