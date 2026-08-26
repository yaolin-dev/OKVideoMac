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

    public init(
        siteKey: String,
        siteName: String,
        sourceName: String,
        episodeName: String,
        result: SitePlaybackResult
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.result = result
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

public struct ResolvedMedia: Equatable, Sendable {
    public var url: URL
    public var headers: HTTPHeaders
    public var format: String?
    public var subtitles: [URL]
    public var siteKey: String
    public var sourceName: String
    public var episodeName: String
    public var parserName: String?

    public init(
        url: URL,
        headers: HTTPHeaders,
        format: String? = nil,
        subtitles: [URL] = [],
        siteKey: String,
        sourceName: String,
        episodeName: String,
        parserName: String? = nil
    ) {
        self.url = url
        self.headers = headers
        self.format = format
        self.subtitles = subtitles
        self.siteKey = siteKey
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.parserName = parserName
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

public enum PlaybackResolutionEvent: Equatable, Sendable {
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
        if Self.isAndroidCloudOriginalProxy(url)
            || Self.isNodeRuntimeMediaProxy(url) {
            return true
        }

        let isAndroidBridgeSession = Self.isAndroidBridgeMediaSession(url)

        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    method: .head,
                    headers: headers,
                    timeout: 10,
                    maximumResponseBytes: 1_024,
                    retryPolicy: .none
                )
            )
            let accepted = Self.looksLikeMedia(response)
                || MediaURLClassifier.isDirectMediaURL(url.absoluteString)
            if !isAndroidBridgeSession { return accepted }
            // A provider-owned Android loopback server may omit Content-Type
            // on HEAD, and a successful HEAD still proves no media bytes are
            // readable. Always continue with a bounded Range GET so empty,
            // HTML, JSON and truncated bridge responses are rejected before
            // libmpv can reduce them to a generic `loading failed`.
        } catch let error as HTTPClientError {
            switch error {
            case .statusCode, .invalidResponse:
                break
            default:
                throw error
            }
        }

        var probeHeaders = headers
        probeHeaders["Range"] = "bytes=0-65535"
        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: probeHeaders,
                    timeout: 10,
                    maximumResponseBytes: 512 * 1_024,
                    retryPolicy: .none
                )
            )
            if isAndroidBridgeSession {
                return Self.looksLikeMediaBytes(response)
            }
            return Self.looksLikeMedia(response)
                || MediaURLClassifier.isDirectMediaURL(url.absoluteString)
        } catch HTTPClientError.responseTooLarge
                    where MediaURLClassifier.isDirectMediaURL(url.absoluteString)
                        || isAndroidBridgeSession {
            // Some VOD providers ignore Range and return a complete, very large
            // media playlist. Receiving more than the probe limit still proves
            // that the direct media endpoint is reachable.
            return true
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
        return looksLikeMedia(response)
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
            if !candidate.result.needsParsing
                || MediaURLClassifier.isDirectMediaURL(candidate.result.url) {
                options.append((nil, candidate.result.url))
            }
            options.append(contentsOf: parserOrder.map { ($0, candidate.result.url) })
            if options.isEmpty, candidate.result.needsParsing {
                failureMessages.append(
                    "\(candidate.sourceName)/解析：线路返回待解析地址，但当前配置没有可用解析器"
                )
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
                    continuation.yield(.state(.validating))
                    let requiresPreflight = parser != nil
                        || candidate.result.validationPolicy == .preflight
                    if requiresPreflight {
                        guard try await mediaProbe.validate(
                            url: parsed.url,
                            headers: parsed.headers
                        ) else {
                            throw AppError.parsing("媒体探测未通过")
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
                        parserName: parser?.name
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
