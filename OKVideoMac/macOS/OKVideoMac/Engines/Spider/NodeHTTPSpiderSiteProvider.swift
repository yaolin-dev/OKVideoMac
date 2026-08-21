import Foundation
import OKVideoCore

private actor NodeSiteInitializationGate {
    private enum State {
        case initializing([CheckedContinuation<Void, Error>])
        case initialized
    }

    private var states: [String: State] = [:]

    func ensureInitialized(
        at baseURL: URL,
        using operation: () async throws -> Void
    ) async throws {
        let endpointKey = baseURL.absoluteString
        switch states[endpointKey] {
        case .initialized:
            return
        case .initializing:
            try await withCheckedThrowingContinuation { continuation in
                guard case .initializing(var waiters) = states[endpointKey] else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                states[endpointKey] = .initializing(waiters)
            }
            return
        case nil:
            states[endpointKey] = .initializing([])
        }

        do {
            try await operation()
            let waiters = waiters(for: endpointKey)
            states[endpointKey] = .initialized
            waiters.forEach { $0.resume() }
        } catch {
            let waiters = waiters(for: endpointKey)
            states.removeValue(forKey: endpointKey)
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func waiters(
        for endpointKey: String
    ) -> [CheckedContinuation<Void, Error>] {
        guard case .initializing(let waiters) = states[endpointKey] else {
            return []
        }
        return waiters
    }
}

struct NodeRuntimeUnavailableSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider
    let reason: String

    func home() async throws -> SiteHome { throw error }
    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage { throw error }
    func detail(id: String) async throws -> VideoDetail { throw error }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        throw error
    }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw error
    }
    func action(_ action: String) async throws -> JSONValue { throw error }

    private var error: NodeBundleRuntimeError {
        .endpointUnavailable(reason)
    }
}

struct NodeWebAuthorizationRequired: Error, LocalizedError, Equatable {
    let websiteURL: URL
    let title: String
    let message: String

    var errorDescription: String? { message }
}

/// The Node bundle embeds Quark's short-lived share authorization inside the
/// opaque episode URL. Keep the codec in the host app so an expired `stoken`
/// can be refreshed without modifying a downloaded third-party bundle.
enum QuarkEpisodeReference {
    struct Identity: Equatable {
        let providerID: String
        let shareID: String
        let fileID: String
    }

    static let shareTokenURL = URL(
        string: "https://drive.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    )!

    static func identity(from rawValue: String) -> Identity? {
        guard let payload = payload(from: rawValue),
              payload.providerID.caseInsensitiveCompare("quark") == .orderedSame,
              !payload.shareID.isEmpty,
              !payload.fileID.isEmpty else {
            return nil
        }
        return Identity(
            providerID: payload.providerID.lowercased(),
            shareID: payload.shareID,
            fileID: payload.fileID
        )
    }

    static func requiresShareTokenRefresh(_ rawValue: String) -> Bool {
        guard let payload = payload(from: rawValue),
              payload.providerID.caseInsensitiveCompare("quark") == .orderedSame else {
            return false
        }
        return payload.stoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func replacingStoken(
        in rawValue: String,
        with stoken: String
    ) throws -> String {
        guard let outerData = Data(
            base64Encoded: rawValue,
            options: .ignoreUnknownCharacters
        ),
        var outer = try JSONSerialization.jsonObject(with: outerData)
            as? [String: Any],
        var token = try JSONSerialization.jsonObject(
            with: Data((outer["playToken"] as? String ?? "").utf8)
        ) as? [String: Any] else {
            throw AppError.playback("夸克分集令牌格式无效，无法刷新分享授权")
        }
        token["stoken"] = stoken
        let tokenData = try JSONSerialization.data(
            withJSONObject: token,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let tokenString = String(data: tokenData, encoding: .utf8) else {
            throw AppError.playback("夸克分享令牌编码失败")
        }
        outer["playToken"] = tokenString
        let data = try JSONSerialization.data(
            withJSONObject: outer,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.base64EncodedString()
    }

    /// History keeps the stable share/file identity but deliberately omits the
    /// expiring stoken. The provider reacquires it before the next playback.
    static func durableHistoryReference(_ rawValue: String) -> String {
        guard identity(from: rawValue) != nil else { return rawValue }
        return (try? replacingStoken(in: rawValue, with: "")) ?? rawValue
    }

    static func passcode(from rawValue: String) -> String {
        guard let outerData = Data(
            base64Encoded: rawValue,
            options: .ignoreUnknownCharacters
        ),
        let outer = try? JSONSerialization.jsonObject(with: outerData)
            as? [String: Any] else {
            return ""
        }
        if let value = firstString(
            in: outer,
            keys: ["passcode", "passCode", "password", "pwd"]
        ) {
            return value
        }
        guard let playToken = outer["playToken"] as? String,
              let token = try? JSONSerialization.jsonObject(
                with: Data(playToken.utf8)
              ) as? [String: Any] else {
            return ""
        }
        return firstString(
            in: token,
            keys: ["passcode", "passCode", "password", "pwd"]
        ) ?? ""
    }

    private struct Payload {
        let providerID: String
        let shareID: String
        let fileID: String
        let stoken: String
    }

    private static func payload(from rawValue: String) -> Payload? {
        guard let data = Data(
            base64Encoded: rawValue,
            options: .ignoreUnknownCharacters
        ),
        let outer = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
        let providerID = outer["providerId"] as? String,
        let playToken = outer["playToken"] as? String,
        let token = try? JSONSerialization.jsonObject(
            with: Data(playToken.utf8)
        ) as? [String: Any] else {
            return nil
        }
        let shareID = (outer["shareId"] as? String)
            ?? (token["shareId"] as? String)
            ?? ""
        let fileID = (outer["fileId"] as? String)
            ?? (token["fid"] as? String)
            ?? ""
        return Payload(
            providerID: providerID,
            shareID: shareID,
            fileID: fileID,
            stoken: token["stoken"] as? String ?? ""
        )
    }

    private static func firstString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        keys.compactMap { object[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

final class NodeHTTPSpiderSiteProvider: SiteProvider {
    private struct HostMessage: Decodable {
        struct Options: Decodable {
            let url: String
        }

        let action: String
        let opt: Options
    }

    private struct InvocationResult {
        let value: JSONValue
        let baseURL: URL
        let hostMessage: HostMessage?
    }

    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)?
    private let ensureRuntimeReady: (@Sendable () async throws -> URL)?
    private let initializationGate = NodeSiteInitializationGate()

    var configurationWebsiteURL: URL {
        baseURL.appendingPathComponent("website")
    }

    static func canHandle(site: SiteConfiguration, baseURL: URL?) -> Bool {
        guard (site.type == 3 || site.type == 4),
              site.extra["okNodeRuntime"] == .bool(true),
              site.api.contains("/spider/"),
              let baseURL,
              baseURL.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                baseURL.host?.lowercased() ?? ""
              ) else {
            return false
        }
        return true
    }

    init(
        site: SiteConfiguration,
        baseURL: URL,
        httpClient: HTTPClient,
        diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)? = nil,
        ensureRuntimeReady: (@Sendable () async throws -> URL)? = nil
    ) throws {
        guard Self.canHandle(site: site, baseURL: baseURL) else {
            throw AppError.spider("NodeHTTPSpiderSiteProvider 站点配置无效")
        }
        self.site = site
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.diagnosticReporter = diagnosticReporter
        self.ensureRuntimeReady = ensureRuntimeReady
    }

    func home() async throws -> SiteHome {
        let home = try await invoke(
            method: "home",
            body: ["filter": .bool(true)],
            maximumAttempts: 2
        )
        let homeVideo = try? await invoke(
            method: "homeVod",
            body: [:],
            maximumAttempts: 2
        )
        let result = try SpiderResponseMapper.home(
            home.value,
            homeVideoValue: homeVideo?.value,
            site: site,
            baseURL: home.baseURL
        )
        guard !site.categories.isEmpty else { return result }
        let allowed = Set(site.categories)
        return SiteHome(
            categories: result.categories.filter { allowed.contains($0.name) },
            recommendations: result.recommendations,
            actionItems: result.actionItems
        )
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try await category(
            id: id,
            page: page,
            filters: filters,
            awaitsHostAction: false
        )
    }

    func actionCategory(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try await category(
            id: id,
            page: page,
            filters: filters,
            awaitsHostAction: true
        )
    }

    private func category(
        id: String,
        page: Int,
        filters: [String: String],
        awaitsHostAction: Bool
    ) async throws -> VideoPage {
        let values = filters.mapValues(JSONValue.string)
        let invocation = try await invoke(
            method: "category",
            body: [
                "id": .string(id),
                "tid": .string(id),
                "page": .string(String(page)),
                "pg": .string(String(page)),
                "filter": .bool(true),
                "extend": .object(values),
                "filters": .object(values)
            ],
            maximumAttempts: 2,
            hostMessageWaitMilliseconds: awaitsHostAction ? 1_000 : 0
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(hostMessage: hostMessage)
        }
        if awaitsHostAction {
            return try SpiderResponseMapper.actionPage(
                invocation.value,
                site: site,
                baseURL: invocation.baseURL,
                page: page
            )
        }
        return try SpiderResponseMapper.page(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            page: page
        )
    }

    func detail(id: String) async throws -> VideoDetail {
        switch try await select(id: id) {
        case .detail(let detail): return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        case .search:
            throw AppError.spider("该卡片只提供发现信息，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        try await select(id: id, fallbackSummary: nil)
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try await select(
            id: summary.videoID,
            fallbackSummary: summary,
            awaitsHostAction: summary.resolvedContentKind == .action
        )
    }

    func select(action item: SiteActionItem) async throws -> SiteSelectionResult {
        try await select(
            id: item.itemID,
            fallbackSummary: item.selectionSummary,
            awaitsHostAction: true
        )
    }

    private func select(
        id: String,
        fallbackSummary: VideoSummary?,
        awaitsHostAction: Bool = false
    ) async throws -> SiteSelectionResult {
        let invocation = try await invoke(
            method: "detail",
            body: [
                "id": .string(id),
                "ids": .array([.string(id)])
            ],
            maximumAttempts: 2,
            hostMessageWaitMilliseconds: awaitsHostAction ? 1_000 : 0
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(
                hostMessage: hostMessage
            )
        }
        return try SpiderResponseMapper.selection(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            fallbackSummary: fallbackSummary,
            allowsPlaceholderAction:
                fallbackSummary?.resolvedContentKind == .action
        )
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable == 1, !quick || site.quickSearch == 1 else {
            return VideoPage(
                items: [],
                pagination: Pagination(page: page, pageCount: 0)
            )
        }
        let invocation = try await invoke(
            method: "search",
            body: [
                "wd": .string(keyword),
                "key": .string(keyword),
                "quick": .bool(quick),
                "page": .string(String(page)),
                "pg": .string(String(page))
            ],
            maximumAttempts: 2
        )
        return try SpiderResponseMapper.page(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            page: page
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        var resolvedEpisodeURL = episodeURL
        var refreshedShareToken = false
        if QuarkEpisodeReference.requiresShareTokenRefresh(resolvedEpisodeURL) {
            resolvedEpisodeURL = try await refreshQuarkShareToken(
                in: resolvedEpisodeURL
            )
            refreshedShareToken = true
        }
        do {
            return try await resolvePlayer(
                flag: flag,
                episodeURL: resolvedEpisodeURL
            )
        } catch let authorization as NodeWebAuthorizationRequired {
            throw authorization
        } catch {
            if !refreshedShareToken,
               Self.shouldRefreshQuarkShareToken(after: error),
               QuarkEpisodeReference.identity(from: resolvedEpisodeURL) != nil {
                let refreshedURL = try await refreshQuarkShareToken(
                    in: resolvedEpisodeURL
                )
                do {
                    return try await resolvePlayer(
                        flag: flag,
                        episodeURL: refreshedURL
                    )
                } catch {
                    throw AppError.spider(
                        "\(site.name) play 失败：已刷新夸克分享令牌，"
                            + "但转存仍失败：\(error.localizedDescription)"
                    )
                }
            }
            // Some Node spiders put an already playable URL directly in the
            // episode field even though their optional play resolver is down.
            // Preserve that valid fallback instead of turning a resolver 500
            // into a total playback failure.
            if MediaURLClassifier.isDirectMediaURL(episodeURL) {
                let readyBaseURL = try await runtimeBaseURL()
                return SitePlaybackResult(
                    url: normalizePlaybackURL(
                        episodeURL,
                        baseURL: readyBaseURL
                    ),
                    needsParsing: false,
                    flag: flag,
                    headers: HTTPHeaders(site.header),
                    validationPolicy: .playerAuthoritative
                )
            }
            throw error
        }
    }

    private func resolvePlayer(
        flag: String,
        episodeURL: String
    ) async throws -> SitePlaybackResult {
        let invocation = try await invoke(
            method: "play",
            body: [
                "flag": .string(flag),
                "id": .string(episodeURL),
                "vipFlags": .array([]),
                "flags": .array([])
            ],
            // POST /play may perform a cloud transfer. Blindly repeating
            // it cannot repair an expired token and can duplicate work.
            maximumAttempts: 1
        )
        var result = try SpiderResponseMapper.player(
            invocation.value,
            site: site
        )
        // Site-level headers (for example Referer/User-Agent) are part of the
        // provider contract. Player-response headers override them, but must
        // not replace the whole request context.
        result.headers = HTTPHeaders(site.header).merging(result.headers)
        result.validationPolicy = .playerAuthoritative
        result.url = normalizePlaybackURL(
            result.url,
            baseURL: invocation.baseURL
        )
        result.qualities = result.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: normalizePlaybackURL(
                    $0.url,
                    baseURL: invocation.baseURL
                )
            )
        }
        result.subtitles = result.subtitles.map { subtitle in
            URL(string: normalizePlaybackURL(
                subtitle.absoluteString,
                baseURL: invocation.baseURL
            ))
                ?? subtitle
        }
        return result
    }

    private func refreshQuarkShareToken(
        in episodeURL: String
    ) async throws -> String {
        guard let identity = QuarkEpisodeReference.identity(from: episodeURL) else {
            throw AppError.playback("夸克分集令牌缺少分享或文件标识")
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "pwd_id": identity.shareID,
                "passcode": QuarkEpisodeReference.passcode(from: episodeURL)
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let response = try await httpClient.send(
            HTTPRequest(
                url: QuarkEpisodeReference.shareTokenURL,
                method: .post,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Referer": "https://pan.quark.cn/",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
                ],
                body: body,
                timeout: 20,
                maximumResponseBytes: 1_024 * 1_024,
                maximumRedirects: 2,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let message = value.flatMap(Self.serverMessage)
        guard (200...299).contains(response.statusCode) else {
            let code = value.flatMap(Self.serverCode)
            let detail = [
                code.map { "错误码 \($0)" },
                message
            ]
                .compactMap { $0 }
                .joined(separator: "：")
            throw AppError.playback(
                "夸克分享令牌刷新失败："
                    + (detail.isEmpty
                        ? "HTTP 状态码 \(response.statusCode)"
                        : detail)
            )
        }
        guard let stoken = value?.objectValue?["data"]?
            .objectValue?["stoken"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !stoken.isEmpty else {
            throw AppError.playback(
                "夸克分享令牌刷新失败："
                    + (message ?? "接口未返回新 stoken，分享可能已失效")
            )
        }
        return try QuarkEpisodeReference.replacingStoken(
            in: episodeURL,
            with: stoken
        )
    }

    private static func shouldRefreshQuarkShareToken(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let missingTask = (message.contains("task_id")
            || message.contains("task id"))
            && (message.contains("没有返回")
                || message.contains("未返回")
                || message.contains("missing")
                || message.contains("empty")
                || message.contains("null"))
        return missingTask || isExpiredQuarkShareTokenMessage(message)
    }

    func action(_ action: String) async throws -> JSONValue {
        let invocation = try await invoke(
            method: "action",
            body: ["action": .string(action)],
            hostMessageWaitMilliseconds: 1_000
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(
                hostMessage: hostMessage
            )
        }
        return invocation.value
    }

    private func invoke(
        method: String,
        body: [String: JSONValue],
        maximumAttempts: Int = 1,
        hostMessageWaitMilliseconds: Int = 0
    ) async throws -> InvocationResult {
        let requestBody = try JSONEncoder().encode(JSONValue.object(body))
        var headers = HTTPHeaders(site.header)
        headers["Content-Type"] = "application/json; charset=utf-8"
        let attempts = max(1, maximumAttempts)
        var lastEndpoint = baseURL
        for attempt in 0..<attempts {
            do {
                let readyBaseURL = try await runtimeBaseURL()
                try await initializationGate.ensureInitialized(
                    at: readyBaseURL
                ) {
                    try await initializeSite(at: readyBaseURL, headers: headers)
                }
                let apiURL = try ResourceResolver.resolve(
                    site.api,
                    relativeTo: readyBaseURL
                )
                let endpoint = apiURL.appendingPathComponent(method)
                lastEndpoint = endpoint
                let invocationID = UUID().uuidString.lowercased()
                headers["X-OKVideo-Invocation-ID"] = invocationID
                let response = try await httpClient.send(
                    HTTPRequest(
                        url: endpoint,
                        method: .post,
                        headers: headers,
                        body: requestBody,
                        timeout: TimeInterval(site.timeout ?? 60),
                        maximumResponseBytes: 16 * 1_024 * 1_024,
                        retryPolicy: .none,
                        allowsNonSuccessfulStatus: true
                    )
                )
                let value: JSONValue
                if response.body.isEmpty {
                    value = .null
                } else {
                    do {
                        value = try JSONDecoder().decode(
                            JSONValue.self,
                            from: response.body
                        )
                    } catch {
                        throw AppError.spider(
                            "Node 站点 \(site.name) 的 \(method) 响应不是有效 JSON"
                        )
                    }
                }
                guard !(200...299).contains(response.statusCode) else {
                    let immediateHostMessage = Self.decodeHostMessage(
                        response.headers["X-OKVideo-Host-Message"]
                    )
                    let hostMessage: HostMessage?
                    if let immediateHostMessage {
                        hostMessage = immediateHostMessage
                    } else if hostMessageWaitMilliseconds > 0 {
                        hostMessage = try await awaitHostMessage(
                            invocationID: response.headers[
                                "X-OKVideo-Invocation-ID"
                            ] ?? invocationID,
                            baseURL: readyBaseURL,
                            waitMilliseconds: hostMessageWaitMilliseconds
                        )
                    } else {
                        hostMessage = nil
                    }
                    return InvocationResult(
                        value: value,
                        baseURL: readyBaseURL,
                        hostMessage: hostMessage
                    )
                }
                let message = Self.serverMessage(from: value)
                    ?? "HTTP 状态码 \(response.statusCode)"
                if Self.isAuthorizationMessage(message) {
                    throw webAuthorizationRequired(
                        message: message,
                        baseURL: readyBaseURL
                    )
                }
                if attempt + 1 < attempts,
                   (500...599).contains(response.statusCode) {
                    try await retryDelay(after: attempt)
                    continue
                }
                throw AppError.spider(
                    "\(site.name) \(method) 失败：\(message)"
                )
            } catch let authorization as NodeWebAuthorizationRequired {
                throw authorization
            } catch {
                if attempt + 1 < attempts {
                    try await retryDelay(after: attempt)
                    continue
                }
                let classification = NodeDiagnosticClassifier.classify(
                    error,
                    context: .spiderSite
                )
                diagnosticReporter?(
                    NodeDiagnosticEvent(
                        category: classification.category,
                        severity: .error,
                        code: classification.code,
                        message: error.localizedDescription,
                        siteKey: site.key,
                        operation: method,
                        originalURL: lastEndpoint
                    )
                )
                throw error
            }
        }
        throw AppError.spider("Node 站点 \(site.name) 的 \(method) 请求失败")
    }

    private func awaitHostMessage(
        invocationID: String,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> HostMessage? {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        guard invocationID.rangeOfCharacter(from: allowed.inverted) == nil,
              (8...128).contains(invocationID.count) else {
            throw AppError.spider("Node 宿主操作关联标识无效")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "wait",
                value: String(min(max(waitMilliseconds, 0), 2_000))
            )
        ]
        guard let endpoint = components?.url else {
            throw AppError.spider("Node 宿主操作轮询地址无效")
        }
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                method: .get,
                timeout: TimeInterval(waitMilliseconds) / 1_000 + 2,
                maximumResponseBytes: 8 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard response.statusCode == 200 else {
            if response.statusCode == 204 || response.statusCode == 404 {
                return nil
            }
            throw AppError.spider(
                "Node 宿主操作轮询失败：HTTP 状态码 \(response.statusCode)"
            )
        }
        guard response.body.count <= 4 * 1_024 else {
            throw AppError.spider("Node 宿主操作响应过大")
        }
        return try? JSONDecoder().decode(HostMessage.self, from: response.body)
    }

    private func initializeSite(
        at readyBaseURL: URL,
        headers: HTTPHeaders
    ) async throws {
        let apiURL = try ResourceResolver.resolve(
            site.api,
            relativeTo: readyBaseURL
        )
        let endpoint = apiURL.appendingPathComponent("init")
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                method: .post,
                headers: headers,
                body: Data("{}".utf8),
                timeout: min(TimeInterval(site.timeout ?? 60), 15),
                maximumResponseBytes: 1 * 1_024 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        if (200...299).contains(response.statusCode)
            || response.statusCode == 404
            || response.statusCode == 405 {
            return
        }
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let message = value.flatMap(Self.serverMessage)
            ?? "HTTP 状态码 \(response.statusCode)"
        throw AppError.spider("\(site.name) init 失败：\(message)")
    }

    private func webAuthorizationRequired(
        message: String,
        baseURL: URL
    ) -> NodeWebAuthorizationRequired {
        NodeWebAuthorizationRequired(
            websiteURL: baseURL.appendingPathComponent("website"),
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: message
        )
    }

    private func webAuthorizationRequired(
        hostMessage: HostMessage
    ) throws -> NodeWebAuthorizationRequired {
        guard hostMessage.action == "openInternalWebview",
              let url = URL(string: hostMessage.opt.url),
              url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ),
              url.port != nil else {
            throw AppError.spider("Node 站点请求了不受支持的宿主操作")
        }
        return NodeWebAuthorizationRequired(
            websiteURL: url,
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: "请在内置页面中完成此功能。"
        )
    }

    private static func decodeHostMessage(_ encoded: String?) -> HostMessage? {
        guard let encoded,
              encoded.utf8.count <= 8 * 1_024,
              let data = Data(base64Encoded: encoded),
              data.count <= 4 * 1_024 else {
            return nil
        }
        return try? JSONDecoder().decode(HostMessage.self, from: data)
    }

    private func retryDelay(after attempt: Int) async throws {
        let nanoseconds = UInt64(250_000_000 * (attempt + 1))
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func runtimeBaseURL() async throws -> URL {
        if let ensureRuntimeReady {
            return try await ensureRuntimeReady()
        }
        return baseURL
    }

    private func normalizePlaybackURL(
        _ rawValue: String,
        baseURL: URL
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasPrefix("/") {
            return baseURL
                .appendingPathComponent(String(value.dropFirst()))
                .absoluteString
        }
        guard var components = URLComponents(string: value),
              let port = components.port,
              port == baseURL.port,
              components.path.hasPrefix("/spider/")
                || components.path.hasPrefix("/proxy/") else {
            return value
        }
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url?.absoluteString ?? value
    }

    private static func serverMessage(from value: JSONValue) -> String? {
        guard case .object(let object) = value else {
            if case .string(let message) = value {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        for key in ["message", "msg", "error", "errMsg"] {
            guard case .string(let message) = object[key] else { continue }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func serverCode(from value: JSONValue) -> String? {
        guard case .object(let object) = value else { return nil }
        for key in ["code", "errorCode", "error_code", "errno"] {
            switch object[key] {
            case .integer(let value):
                return String(value)
            case .number(let value):
                return value.rounded() == value
                    ? String(Int64(value))
                    : String(value)
            case .string(let value):
                let trimmed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmed.isEmpty { return trimmed }
            default:
                continue
            }
        }
        return nil
    }

    private static func isExpiredQuarkShareTokenMessage(
        _ message: String
    ) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("41016")
            || (normalized.contains("stoken")
                && (normalized.contains("过期")
                    || normalized.contains("expired")))
    }

    private static func isAuthorizationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        // A share stoken is independent from the user's cloud-drive login.
        // Treating 41016 as a Cookie/login problem bypasses the refresh path
        // and sends the user to an authorization screen that cannot fix it.
        if isExpiredQuarkShareTokenMessage(normalized) {
            return false
        }
        let configurationHints = [
            "请先去配置中心", "请先到配置中心",
            "还没有配置", "未登录", "还没有登录",
            "cookie", "token", "扫码登录", "验证码登录"
        ]
        let providerHints = [
            "网盘", "夸克", "uc", "百度", "115", "123",
            "天翼", "移动", "光鸭", "迅雷", "bili"
        ]
        return configurationHints.contains(where: normalized.contains)
            && providerHints.contains(where: normalized.contains)
    }
}
