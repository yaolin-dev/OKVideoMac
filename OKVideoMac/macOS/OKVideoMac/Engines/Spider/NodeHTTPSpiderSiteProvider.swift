import Foundation
import OKVideoCore

struct NodeWebAuthorizationRequired: Error, LocalizedError, Equatable {
    let websiteURL: URL
    let title: String
    let message: String

    var errorDescription: String? { message }
}

final class NodeHTTPSpiderSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL
    private let httpClient: HTTPClient

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

    init(site: SiteConfiguration, baseURL: URL, httpClient: HTTPClient) throws {
        guard Self.canHandle(site: site, baseURL: baseURL) else {
            throw AppError.spider("NodeHTTPSpiderSiteProvider 站点配置无效")
        }
        self.site = site
        self.baseURL = baseURL
        self.httpClient = httpClient
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
            baseURL: baseURL
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
        do {
            var result = try SpiderResponseMapper.player(
                await invoke(
                    method: "play",
                    body: [
                        "flag": .string(flag),
                        "id": .string(episodeURL),
                        "vipFlags": .array([]),
                        "flags": .array([])
                    ],
                    maximumAttempts: 2
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
        } catch let authorization as NodeWebAuthorizationRequired {
            throw authorization
        } catch {
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

    private static func isAuthorizationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
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
