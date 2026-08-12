import Foundation
import OKVideoCore

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
    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)?

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
        diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)? = nil
    ) throws {
        guard Self.canHandle(site: site, baseURL: baseURL) else {
            throw AppError.spider("NodeHTTPSpiderSiteProvider 站点配置无效")
        }
        self.site = site
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.diagnosticReporter = diagnosticReporter
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
        var result = try SpiderResponseMapper.home(
            home,
            homeVideoValue: homeVideo,
            site: site,
            baseURL: baseURL
        )
        if isConfigurationCenter {
            result.recommendations = result.recommendations.map { summary in
                var summary = summary
                summary.action = "node-web-configuration"
                return summary
            }
        }
        guard !site.categories.isEmpty else { return result }
        let allowed = Set(site.categories)
        return SiteHome(
            categories: result.categories.filter { allowed.contains($0.name) },
            recommendations: result.recommendations
        )
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        let values = filters.mapValues(JSONValue.string)
        let value = try await invoke(
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
            maximumAttempts: 2
        )
        return try SpiderResponseMapper.page(
            value,
            site: site,
            baseURL: baseURL,
            page: page
        )
    }

    func detail(id: String) async throws -> VideoDetail {
        switch try await select(id: id) {
        case .detail(let detail): return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        try await select(id: id, fallbackSummary: nil)
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try await select(id: summary.videoID, fallbackSummary: summary)
    }

    private func select(
        id: String,
        fallbackSummary: VideoSummary?
    ) async throws -> SiteSelectionResult {
        if isConfigurationCenter,
           id == "config-center" || id == "node-web-configuration" {
            throw webAuthorizationRequired(
                message: "在内置配置中心中管理网盘登录与扫码授权。"
            )
        }
        return try SpiderResponseMapper.selection(
            await invoke(
                method: "detail",
                body: [
                    "id": .array([.string(id)]),
                    "ids": .array([.string(id)])
                ],
                maximumAttempts: 2
            ),
            site: site,
            baseURL: baseURL,
            fallbackSummary: fallbackSummary,
            allowsPlaceholderAction: isConfigurationCenter
        )
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable == 1, !quick || site.quickSearch == 1 else {
            return VideoPage(
                items: [],
                pagination: Pagination(page: page, pageCount: 0)
            )
        }
        let value = try await invoke(
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
            value,
            site: site,
            baseURL: baseURL,
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
                return SitePlaybackResult(
                    url: normalizePlaybackURL(episodeURL),
                    needsParsing: false,
                    flag: flag,
                    headers: HTTPHeaders(site.header)
                )
            }
            throw error
        }
    }

    private func resolvePlayer(
        flag: String,
        episodeURL: String
    ) async throws -> SitePlaybackResult {
        var result = try SpiderResponseMapper.player(
            await invoke(
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
            ),
            site: site
        )
        result.url = normalizePlaybackURL(result.url)
        result.qualities = result.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: normalizePlaybackURL($0.url)
            )
        }
        result.subtitles = result.subtitles.map { subtitle in
            URL(string: normalizePlaybackURL(subtitle.absoluteString))
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
        if action == "node-web-configuration"
            || action == "config-center"
            || action.contains("/website") {
            throw webAuthorizationRequired(
                message: "在内置配置中心中管理网盘登录与扫码授权。"
            )
        }
        return try await invoke(
            method: "action",
            body: ["action": .string(action)]
        )
    }

    private func invoke(
        method: String,
        body: [String: JSONValue],
        maximumAttempts: Int = 1
    ) async throws -> JSONValue {
        let apiURL = try ResourceResolver.resolve(site.api, relativeTo: baseURL)
        let endpoint = apiURL.appendingPathComponent(method)
        let requestBody = try JSONEncoder().encode(JSONValue.object(body))
        var headers = HTTPHeaders(site.header)
        headers["Content-Type"] = "application/json; charset=utf-8"
        let attempts = max(1, maximumAttempts)
        for attempt in 0..<attempts {
            do {
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
                    return value
                }
                let message = Self.serverMessage(from: value)
                    ?? "HTTP 状态码 \(response.statusCode)"
                if Self.isAuthorizationMessage(message) {
                    throw webAuthorizationRequired(message: message)
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
                        originalURL: endpoint
                    )
                )
                throw error
            }
        }
        throw AppError.spider("Node 站点 \(site.name) 的 \(method) 请求失败")
    }

    private var isConfigurationCenter: Bool {
        site.key == "nodejs_baseset"
            || site.api.contains("/spider/baseset/")
    }

    private func webAuthorizationRequired(
        message: String
    ) -> NodeWebAuthorizationRequired {
        NodeWebAuthorizationRequired(
            websiteURL: configurationWebsiteURL,
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: message
        )
    }

    private func retryDelay(after attempt: Int) async throws {
        let nanoseconds = UInt64(250_000_000 * (attempt + 1))
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func normalizePlaybackURL(_ rawValue: String) -> String {
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
