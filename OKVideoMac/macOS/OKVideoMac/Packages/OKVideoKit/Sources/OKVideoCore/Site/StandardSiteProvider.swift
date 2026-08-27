import Foundation

public final class StandardSiteProvider: SiteProvider {
    public let site: SiteConfiguration
    public let capability: SiteCapability

    private let httpClient: HTTPClient
    private let configurationBaseURL: URL?

    public init(
        site: SiteConfiguration,
        httpClient: HTTPClient,
        configurationBaseURL: URL?
    ) throws {
        guard [0, 1, 4].contains(site.type) else {
            throw AppError.unsupported("StandardSiteProvider 不支持 type \(site.type)")
        }
        self.site = site
        self.httpClient = httpClient
        self.configurationBaseURL = configurationBaseURL
        switch site.type {
        case 0: capability = .standardXML
        case 1: capability = .standardJSON
        default: capability = .base64JSON
        }
    }

    public func home() async throws -> SiteHome {
        let response = try await request(parameters: [:])
        let summaries = UpstreamResponseDecoder.summaries(
            from: response.videos,
            site: site,
            baseURL: configurationBaseURL
        )
        return SiteHome(
            categories: filteredCategories(response.categories).filter {
                $0.resolvedContentKind != .unsupported
            },
            recommendations: summaries.filter {
                $0.resolvedContentKind == .media
            },
            actionItems: summaries.filter {
                $0.resolvedContentKind == .action
            }.map(SiteActionItem.init(summary:))
        )
    }

    public func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        guard page >= 1 else {
            throw AppError.site("页码必须从 1 开始")
        }
        var parameters = [
            "ac": site.type == 0 ? "videolist" : "detail",
            "t": id,
            "pg": String(page)
        ]
        if site.type == 1, !filters.isEmpty {
            parameters["f"] = try encodeJSONObject(filters)
        } else if site.type == 4 {
            let json = try encodeJSONObject(filters)
            parameters["ext"] = Data(json.utf8).base64URLEncodedString()
        }
        if let ext = site.ext {
            parameters["extend"] = try encodeExt(ext)
        }

        let response = try await request(parameters: parameters)
        return VideoPage(
            items: UpstreamResponseDecoder.mediaSummaries(
                from: response.videos,
                site: site,
                baseURL: configurationBaseURL
            ),
            pagination: Pagination(page: page, pageCount: response.pageCount)
        )
    }

    public func detail(id: String) async throws -> VideoDetail {
        let response = try await request(
            parameters: [
                "ac": site.type == 0 ? "videolist" : "detail",
                "ids": id
            ]
        )
        guard let video = response.videos.first else {
            throw AppError.site("站点 \(site.name) 未返回详情")
        }
        return try UpstreamResponseDecoder.detail(
            from: video,
            site: site,
            baseURL: configurationBaseURL
        )
    }

    public func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable != 0 else {
            return VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
        }
        if quick, site.quickSearch != 1 {
            return VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
        }
        var parameters = [
            "wd": keyword,
            "quick": quick ? "true" : "false",
            "extend": ""
        ]
        if page > 1 {
            parameters["pg"] = String(page)
        }
        let response = try await request(parameters: parameters)
        return VideoPage(
            items: UpstreamResponseDecoder.mediaSummaries(
                from: response.videos,
                site: site,
                baseURL: configurationBaseURL
            ),
            pagination: Pagination(page: page, pageCount: response.pageCount)
        )
    }

    public func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        let isDirect = MediaURLClassifier.isDirectMediaURL(episodeURL)
        return SitePlaybackResult(
            url: episodeURL,
            needsParsing: !isDirect || !(site.playURL ?? "").isEmpty,
            playURL: site.playURL,
            flag: flag,
            headers: HTTPHeaders(site.header)
        )
    }

    private func request(parameters: [String: String]) async throws -> UpstreamResponse {
        let endpoint = try ResourceResolver.resolve(site.api, relativeTo: configurationBaseURL)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AppError.site("站点 \(site.name) 的 API URL 无效")
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AppError.site("站点 \(site.name) 的请求 URL 无法构造")
        }

        let response = try await httpClient.send(
            HTTPRequest(
                url: url,
                headers: HTTPHeaders(site.header),
                timeout: TimeInterval(site.timeout ?? 30),
                maximumResponseBytes: 16 * 1_024 * 1_024
            )
        )
        if site.type == 0 {
            return try UpstreamResponseDecoder.decodeXML(response.body, site: site)
        }
        return try UpstreamResponseDecoder.decodeJSON(
            response.body,
            site: site,
            baseURL: response.url.deletingLastPathComponent()
        )
    }

    private func filteredCategories(_ categories: [VideoCategory]) -> [VideoCategory] {
        guard !site.categories.isEmpty else { return categories }
        let allowed = Set(site.categories)
        return categories.filter { allowed.contains($0.name) }
    }

    private func encodeJSONObject(_ value: [String: String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw AppError.decoding("无法编码筛选条件")
        }
        return string
    }

    private func encodeExt(_ value: JSONValue) throws -> String {
        if case .string(let string) = value {
            return string
        }
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AppError.decoding("无法编码站点 ext")
        }
        return string
    }
}

public struct UnsupportedSiteProvider: SiteProvider {
    public let site: SiteConfiguration
    public let capability: SiteCapability = .unsupportedSpider

    public init(site: SiteConfiguration) {
        self.site = site
    }

    public func home() async throws -> SiteHome { throw error }
    public func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
        throw error
    }
    public func detail(id: String) async throws -> VideoDetail { throw error }
    public func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        throw error
    }
    public func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw error
    }

    private var error: AppError {
        .unsupported("站点 \(site.name) 使用 Java/Dex/Python Spider，MVP 不执行该运行时")
    }
}

public enum MediaURLClassifier {
    private static let directExtensions = [
        "m3u8", "mp4", "mkv", "webm", "mov", "flv", "ts", "mpd", "mp3", "m4a", "aac"
    ]

    public static func isDirectMediaURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            return false
        }
        let pathExtension = url.pathExtension.lowercased()
        if directExtensions.contains(pathExtension) {
            return true
        }
        let lowered = value.lowercased()
        return lowered.contains(".m3u8?") || lowered.contains(".mpd?")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
