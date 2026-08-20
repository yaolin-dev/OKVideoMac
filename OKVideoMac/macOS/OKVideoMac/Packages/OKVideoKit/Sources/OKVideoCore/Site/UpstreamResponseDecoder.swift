import Foundation

struct UpstreamResponse {
    var categories: [VideoCategory]
    var videos: [UpstreamVideo]
    var pageCount: Int?
    var player: SitePlaybackResult?
    var message: String?
}

struct UpstreamVideo {
    var id: String
    var name: String
    var typeName: String?
    var picture: String?
    var remarks: String?
    var year: String?
    var area: String?
    var director: String?
    var actors: String?
    var content: String?
    var playFrom: String?
    var playURL: String?
    var tag: String?
    var action: String?
    var contentKind: VideoContentKind
}

/// Interprets only protocol metadata. Human-facing names, poster URLs, and
/// identifiers that merely happen to look like URLs are deliberately ignored.
enum ProtocolContentSemantics {
    private static let actionIdentifiers: Set<String> = [
        "action", "actions", "configuration", "config", "menu", "operation",
        "operations", "service", "services", "setting", "settings", "tool",
        "tools"
    ]

    private static let unsupportedIdentifiers: Set<String> = [
        "unsupported"
    ]

    static func kind(
        categoryID: String?,
        action: String?,
        tag: String?
    ) -> VideoContentKind {
        if action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .action
        }
        for value in [tag, categoryID].compactMap({ $0 }) {
            let identifier = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
            if actionIdentifiers.contains(identifier) {
                return .action
            }
            if unsupportedIdentifiers.contains(identifier) {
                return .unsupported
            }
        }
        return .media
    }
}

enum UpstreamResponseDecoder {
    static func decodeJSON(
        _ data: Data,
        site: SiteConfiguration,
        baseURL: URL?
    ) throws -> UpstreamResponse {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AppError.decoding("站点 \(site.name) 返回的 JSON 无效：\(error.localizedDescription)")
        }
        guard case .object(let object) = root else {
            throw AppError.decoding("站点 \(site.name) 的响应顶层必须是对象")
        }

        let filters = decodeFilters(object["filters"])
        let categories = decodeCategories(object["class"], filters: filters)
        let videos = decodeVideos(object["list"])
        let pageCount = integer(object["pagecount"])
        let player = decodePlayer(object)
        let message = firstNonEmptyString(
            object["msg"],
            object["errMsg"],
            object["error"]
        )
        return UpstreamResponse(
            categories: categories,
            videos: videos,
            pageCount: pageCount,
            player: player,
            message: message
        )
    }

    static func decodeXML(_ data: Data, site: SiteConfiguration) throws -> UpstreamResponse {
        let delegate = XMLVideoParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.decoding(
                "站点 \(site.name) 返回的 XML 无效：\(parser.parserError?.localizedDescription ?? "未知错误")"
            )
        }
        return UpstreamResponse(
            categories: delegate.categories,
            videos: delegate.videos,
            pageCount: delegate.pageCount,
            player: nil,
            message: nil
        )
    }

    static func summaries(
        from videos: [UpstreamVideo],
        site: SiteConfiguration,
        baseURL: URL?,
        inheritedContentKind: VideoContentKind? = nil
    ) -> [VideoSummary] {
        videos.compactMap { video in
            guard video.id != "-1001", !video.name.isEmpty else {
                return nil
            }
            let identifier: String
            if !video.id.isEmpty {
                identifier = video.id
            } else if video.action?.isEmpty == false {
                identifier = "action:\(site.key):\(video.name)"
            } else {
                // Some FongMi discovery spiders intentionally return poster
                // recommendations without vod_id. Android still shows these
                // cards; route them into the existing multi-site search flow
                // instead of silently dropping the whole recommendation row.
                identifier = "msearch:\(site.key):\(video.name)"
            }
            let posterURL = video.picture.flatMap { try? ResourceResolver.resolve($0, relativeTo: baseURL) }
            let contentKind = video.contentKind == .media
                ? (inheritedContentKind ?? .media)
                : video.contentKind
            return VideoSummary(
                siteKey: site.key,
                siteName: site.name,
                videoID: identifier,
                title: video.name,
                posterURL: posterURL,
                remarks: video.remarks,
                year: video.year,
                categoryName: video.typeName,
                tag: video.tag,
                action: video.action,
                contentKind: contentKind == .media ? nil : contentKind
            )
        }
    }

    static func mediaSummaries(
        from videos: [UpstreamVideo],
        site: SiteConfiguration,
        baseURL: URL?,
        inheritedContentKind: VideoContentKind? = nil
    ) -> [VideoSummary] {
        summaries(
            from: videos,
            site: site,
            baseURL: baseURL,
            inheritedContentKind: inheritedContentKind
        ).filter { $0.resolvedContentKind == .media }
    }

    static func detail(
        from video: UpstreamVideo,
        site: SiteConfiguration,
        baseURL: URL?
    ) throws -> VideoDetail {
        guard !video.id.isEmpty, !video.name.isEmpty else {
            throw AppError.decoding("详情响应缺少 vod_id 或 vod_name")
        }
        let summary = summaries(from: [video], site: site, baseURL: baseURL)[0]
        return VideoDetail(
            summary: summary,
            area: video.area,
            director: video.director,
            actors: video.actors,
            synopsis: video.content,
            playSources: PlayListParser.parse(
                sourceNames: video.playFrom ?? "",
                sourceEpisodes: video.playURL ?? ""
            )
        )
    }

    private static func decodeCategories(
        _ value: JSONValue?,
        filters: [String: [VideoFilter]]
    ) -> [VideoCategory] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item,
                  let id = string(object["type_id"]),
                  let name = string(object["type_name"]),
                  !id.isEmpty,
                  !name.isEmpty else {
                return nil
            }
            let contentKind = ProtocolContentSemantics.kind(
                categoryID: id,
                action: string(object["action"]),
                tag: string(object["tag"])
            )
            return VideoCategory(
                id: id,
                name: name,
                filters: filters[id] ?? [],
                contentKind: contentKind == .media ? nil : contentKind
            )
        }
    }

    private static func decodeFilters(_ value: JSONValue?) -> [String: [VideoFilter]] {
        guard case .object(let categories) = value else { return [:] }
        var output: [String: [VideoFilter]] = [:]
        for (categoryID, rawFilters) in categories {
            guard case .array(let filters) = rawFilters else { continue }
            output[categoryID] = filters.compactMap { rawFilter in
                guard case .object(let object) = rawFilter,
                      let id = string(object["key"]),
                      let name = string(object["name"]),
                      case .array(let rawOptions) = object["value"] else {
                    return nil
                }
                let options = rawOptions.compactMap { rawOption -> VideoFilterOption? in
                    guard case .object(let option) = rawOption,
                          let optionName = string(option["n"]),
                          let optionValue = string(option["v"]) else {
                        return nil
                    }
                    return VideoFilterOption(name: optionName, value: optionValue)
                }
                return VideoFilter(id: id, name: name, options: options)
            }
        }
        return output
    }

    private static func decodeVideos(_ value: JSONValue?) -> [UpstreamVideo] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item else { return nil }
            let categoryID = string(object["type_id"])
            let tag = string(object["vod_tag"]) ?? string(object["tag"])
            let action = string(object["action"])
            return UpstreamVideo(
                id: string(object["vod_id"]) ?? string(object["id"]) ?? "",
                name: string(object["vod_name"]) ?? string(object["name"]) ?? "",
                typeName: string(object["type_name"]),
                picture: string(object["vod_pic"]) ?? string(object["pic"]),
                remarks: string(object["vod_remarks"]) ?? string(object["note"]),
                year: string(object["vod_year"]) ?? string(object["year"]),
                area: string(object["vod_area"]) ?? string(object["area"]),
                director: string(object["vod_director"]) ?? string(object["director"]),
                actors: string(object["vod_actor"]) ?? string(object["actor"]),
                content: string(object["vod_content"]) ?? string(object["des"]),
                playFrom: string(object["vod_play_from"]),
                playURL: string(object["vod_play_url"]),
                tag: tag,
                action: action,
                contentKind: ProtocolContentSemantics.kind(
                    categoryID: categoryID,
                    action: action,
                    tag: tag
                )
            )
        }
    }

    private static func decodePlayer(_ object: [String: JSONValue]) -> SitePlaybackResult? {
        guard let selection = playerURLSelection(object["url"]) else { return nil }
        let url = unwrapUnavailableLocalM3U8Proxy(selection.url)
        let qualities = selection.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: unwrapUnavailableLocalM3U8Proxy($0.url)
            )
        }
        let needsParsing = integer(object["parse"]) == 1 || integer(object["jx"]) == 1
        let headers = decodeHeaders(object["header"])
        var subtitles: [URL] = []
        if case .array(let rawSubtitles) = object["subs"] {
            subtitles = rawSubtitles.compactMap { item in
                guard case .object(let sub) = item,
                      let rawURL = string(sub["url"]) else { return nil }
                return URL(string: rawURL)
            }
        }
        return SitePlaybackResult(
            url: url,
            needsParsing: needsParsing,
            playURL: string(object["playUrl"]),
            flag: string(object["flag"]) ?? "",
            headers: HTTPHeaders(headers),
            format: string(object["format"]),
            subtitles: subtitles,
            qualities: qualities
        )
    }

    /// Matches FongMi's `UrlAdapter`: player responses may return either one
    /// URL, alternating quality-name/URL pairs, or a persisted Url object. Keep
    /// every quality for the player and prefer the provider's original/source
    /// stream even when a stale persisted position points at a smart variant.
    private static func playerURLSelection(_ value: JSONValue?) -> (
        url: String,
        qualities: [PlaybackQuality]
    )? {
        switch value {
        case .string(let value):
            guard let url = nonEmptyTrimmed(value) else { return nil }
            return (url, [])

        case .array(let values):
            // FongMi arrays are [qualityName, url, qualityName, url, ...].
            let qualities = stride(from: 0, to: values.count - 1, by: 2)
                .compactMap { index -> PlaybackQuality? in
                    guard let url = string(values[index + 1]).flatMap(nonEmptyTrimmed) else {
                        return nil
                    }
                    let name = string(values[index]).flatMap(nonEmptyTrimmed)
                        ?? "清晰度 \(index / 2 + 1)"
                    return PlaybackQuality(name: name, url: url)
                }
            return selectedQuality(from: qualities, fallbackPosition: 0)

        case .object(let object):
            guard case .array(let values) = object["values"], !values.isEmpty else {
                return nil
            }
            let position = integer(object["position"]) ?? 0
            let qualities = values.enumerated().compactMap { index, value -> PlaybackQuality? in
                guard case .object(let item) = value,
                      let url = string(item["v"]).flatMap(nonEmptyTrimmed) else {
                    return nil
                }
                let name = string(item["n"]).flatMap(nonEmptyTrimmed)
                    ?? "清晰度 \(index + 1)"
                return PlaybackQuality(name: name, url: url)
            }
            return selectedQuality(from: qualities, fallbackPosition: position)

        default:
            return nil
        }
    }

    private static func selectedQuality(
        from qualities: [PlaybackQuality],
        fallbackPosition: Int
    ) -> (url: String, qualities: [PlaybackQuality])? {
        guard !qualities.isEmpty else { return nil }
        let selected = qualities.first(where: { isOriginalQualityName($0.name) })
            ?? (qualities.indices.contains(fallbackPosition)
                ? qualities[fallbackPosition]
                : qualities[0])
        return (selected.url, qualities)
    }

    private static func isOriginalQualityName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("原画")
            || normalized.contains("原畫")
            || normalized.contains("original")
            || normalized.contains("source")
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeHeaders(_ value: JSONValue?) -> [String: String] {
        let rawHeaders: [String: JSONValue]
        switch value {
        case .object(let object):
            rawHeaders = object
        case .string(let encoded):
            guard let data = encoded.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let object) = decoded else {
                return [:]
            }
            rawHeaders = object
        default:
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: rawHeaders.compactMap { key, value in
            string(value).map { (key, $0) }
        })
    }

    private static func unwrapUnavailableLocalM3U8Proxy(_ rawURL: String) -> String {
        let localAuthorities = [
            "127.0.0.1:-1",
            "localhost:-1",
            "[::1]:-1"
        ]
        guard let authority = localAuthorities.first(where: { rawURL.contains("://\($0)/proxy?") })
        else {
            return rawURL
        }
        let parseableURL = rawURL.replacingOccurrences(
            of: authority,
            with: authority.replacingOccurrences(of: ":-1", with: "")
        )
        guard let components = URLComponents(string: parseableURL),
              components.path == "/proxy",
              components.queryItems?.first(where: { $0.name == "do" })?.value == "m3u8",
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: target),
              ["http", "https"].contains(targetURL.scheme?.lowercased() ?? "") else {
            return rawURL
        }
        return targetURL.absoluteString
    }

    private static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let value): return Int(exactly: value)
        case .number(let value) where value.rounded() == value: return Int(exactly: value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    private static func firstNonEmptyString(_ values: JSONValue?...) -> String? {
        values.lazy.compactMap(string).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public enum SpiderResponseMapper {
    public static func home(
        _ homeValue: JSONValue,
        homeVideoValue: JSONValue?,
        site: SiteConfiguration,
        baseURL: URL?
    ) throws -> SiteHome {
        let home = try decode(
            homeValue,
            site: site,
            baseURL: baseURL,
            allowEmpty: true
        )
        let recommendationResponse: UpstreamResponse
        if let homeVideoValue {
            recommendationResponse = try decode(
                homeVideoValue,
                site: site,
                baseURL: baseURL,
                allowEmpty: true
            )
        } else {
            recommendationResponse = home
        }
        let inheritedKind: VideoContentKind? =
            !recommendationResponse.categories.isEmpty
            && recommendationResponse.categories.allSatisfy {
                $0.resolvedContentKind != .media
            }
                ? .action
                : nil
        return SiteHome(
            categories: home.categories.filter {
                $0.resolvedContentKind == .media
            },
            recommendations: UpstreamResponseDecoder.mediaSummaries(
                from: recommendationResponse.videos,
                site: site,
                baseURL: baseURL,
                inheritedContentKind: inheritedKind
            )
        )
    }

    public static func page(
        _ value: JSONValue,
        site: SiteConfiguration,
        baseURL: URL?,
        page: Int
    ) throws -> VideoPage {
        let response = try decode(
            value,
            site: site,
            baseURL: baseURL,
            allowEmpty: true
        )
        return VideoPage(
            items: UpstreamResponseDecoder.mediaSummaries(
                from: response.videos,
                site: site,
                baseURL: baseURL
            ),
            pagination: Pagination(page: page, pageCount: response.pageCount)
        )
    }

    public static func detail(
        _ value: JSONValue,
        site: SiteConfiguration,
        baseURL: URL?
    ) throws -> VideoDetail {
        switch try selection(value, site: site, baseURL: baseURL) {
        case .detail(let detail):
            return detail
        case .action:
            throw AppError.spider("Spider 返回了设置操作结果，而不是影视详情")
        }
    }

    public static func selection(
        _ value: JSONValue,
        site: SiteConfiguration,
        baseURL: URL?,
        fallbackSummary: VideoSummary? = nil,
        allowsPlaceholderAction: Bool = true
    ) throws -> SiteSelectionResult {
        let response = try decode(value, site: site, baseURL: baseURL)
        if let video = response.videos.first(where: {
            $0.contentKind == .media
                &&
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .detail(
                try UpstreamResponseDecoder.detail(
                    from: video,
                    site: site,
                    baseURL: baseURL
                )
            )
        }
        if fallbackSummary?.resolvedContentKind != .action,
           let fallbackSummary,
           var video = response.videos.first(where: {
               detailPayloadIsRecoverable($0)
           }) {
            video.id = video.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackSummary.videoID
                : video.id
            video.name = video.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackSummary.title
                : video.name
            video.picture = video.picture?.nonEmptyValue
                ?? fallbackSummary.posterURL?.absoluteString
            video.remarks = video.remarks?.nonEmptyValue ?? fallbackSummary.remarks
            video.year = video.year?.nonEmptyValue ?? fallbackSummary.year
            video.typeName = video.typeName?.nonEmptyValue ?? fallbackSummary.categoryName
            video.tag = video.tag?.nonEmptyValue ?? fallbackSummary.tag
            return .detail(
                try UpstreamResponseDecoder.detail(
                    from: video,
                    site: site,
                    baseURL: baseURL
                )
            )
        }
        if fallbackSummary?.resolvedContentKind == .action
            || response.videos.contains(where: {
            $0.contentKind == .action || $0.action?.nonEmptyValue != nil
        }) {
            return .action(value)
        }
        // Configuration/account spiders intentionally return {"list":[{}]}
        // after handling the selected command. An empty list still represents
        // a failed detail request and remains an error.
        if allowsPlaceholderAction, !response.videos.isEmpty {
            return .action(value)
        }
        if let message = response.message {
            throw AppError.spider(message)
        }
        if !response.videos.isEmpty {
            throw AppError.spider("Spider 详情响应缺少可识别的影视信息")
        }
        throw AppError.spider("Spider 详情响应没有有效项目")
    }

    private static func detailPayloadIsRecoverable(_ video: UpstreamVideo) -> Bool {
        guard video.contentKind == .media,
              video.action?.nonEmptyValue == nil else { return false }
        return [
            video.typeName,
            video.picture,
            video.remarks,
            video.year,
            video.area,
            video.director,
            video.actors,
            video.content,
            video.playFrom,
            video.playURL,
            video.tag
        ].contains { $0?.nonEmptyValue != nil }
    }

    public static func player(
        _ value: JSONValue,
        site: SiteConfiguration
    ) throws -> SitePlaybackResult {
        let response = try decode(value, site: site, baseURL: nil)
        guard let player = response.player else {
            if let message = response.message {
                throw AppError.spider(message)
            }
            throw AppError.spider("Spider 播放响应缺少 url")
        }
        return player
    }

    private static func decode(
        _ value: JSONValue,
        site: SiteConfiguration,
        baseURL: URL?,
        allowEmpty: Bool = false
    ) throws -> UpstreamResponse {
        let data: Data
        if case .string(let string) = value {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "null" else {
                if allowEmpty {
                    return emptyResponse()
                }
                throw AppError.spider(
                    "站点 \(site.name) 未返回数据，上游链接可能已失效"
                )
            }
            guard let stringData = string.data(using: .utf8) else {
                throw AppError.spider("Spider JSON 字符串不是 UTF-8")
            }
            data = stringData
        } else if value == .null, allowEmpty {
            return emptyResponse()
        } else {
            data = try JSONEncoder().encode(value)
        }
        do {
            return try UpstreamResponseDecoder.decodeJSON(
                data,
                site: site,
                baseURL: baseURL
            )
        } catch {
            // OK/FongMi's Result.fromJson catches malformed or non-object
            // Spider responses and returns Result.empty(). Home/category/search
            // must keep that compatibility so a transient upstream response
            // does not become a blocking alert. Detail/player remain strict.
            if allowEmpty {
                return emptyResponse()
            }
            throw error
        }
    }

    private static func emptyResponse() -> UpstreamResponse {
        UpstreamResponse(
            categories: [],
            videos: [],
            pageCount: nil,
            player: nil,
            message: nil
        )
    }
}

public enum PlayListParser {
    public static func parse(sourceNames: String, sourceEpisodes: String) -> [PlaySource] {
        let names = sourceNames.components(separatedBy: "$$$")
        let episodeGroups = sourceEpisodes.components(separatedBy: "$$$")
        let count = max(names.count, episodeGroups.count)
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            let name: String
            if index < names.count, !names[index].isEmpty {
                name = names[index]
            } else {
                name = "线路 \(index + 1)"
            }
            let rawGroup = index < episodeGroups.count ? episodeGroups[index] : ""
            let episodes = rawGroup.components(separatedBy: "#").compactMap {
                raw -> PlayEpisode? in
                guard !raw.isEmpty else { return nil }
                if let separator = raw.firstIndex(of: "$") {
                    let episodeName = String(raw[..<separator])
                    let url = String(raw[raw.index(after: separator)...])
                    guard !url.isEmpty else { return nil }
                    return PlayEpisode(
                        name: episodeName.isEmpty ? fallbackName(from: url) : episodeName,
                        url: url
                    )
                }
                return PlayEpisode(name: fallbackName(from: raw), url: raw)
            }
            return episodes.isEmpty ? nil : PlaySource(name: name, episodes: episodes)
        }
    }

    private static func fallbackName(from reference: String) -> String {
        let decoded = reference.removingPercentEncoding ?? reference
        if let components = URLComponents(string: decoded),
           let url = components.url,
           !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        let withoutQuery = decoded.components(separatedBy: "?").first ?? decoded
        let withoutFragment = withoutQuery.components(separatedBy: "#").first ?? withoutQuery
        if let last = withoutFragment.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        let trimmed = withoutFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名资源" : trimmed
    }
}

private final class XMLVideoParserDelegate: NSObject, XMLParserDelegate {
    private(set) var categories: [VideoCategory] = []
    private(set) var videos: [UpstreamVideo] = []
    private(set) var pageCount: Int?

    private var element = ""
    private var text = ""
    private var currentVideo: [String: String]?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName.lowercased()
        text = ""
        if element == "video" {
            currentVideo = [:]
        } else if element == "ty", let id = attributeDict["id"] {
            let name = attributeDict["name"] ?? ""
            if !name.isEmpty {
                categories.append(VideoCategory(id: id, name: name))
            }
        } else if element == "list", let rawPageCount = attributeDict["pagecount"] {
            pageCount = Int(rawPageCount)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentVideo != nil, name != "video", !value.isEmpty {
            currentVideo?[name] = value
        }
        if name == "video", let video = currentVideo {
            let categoryID = video["type_id"]
            let tag = video["vod_tag"] ?? video["tag"]
            let action = video["action"]
            videos.append(
                UpstreamVideo(
                    id: video["id"] ?? video["vod_id"] ?? "",
                    name: video["name"] ?? video["vod_name"] ?? "",
                    typeName: video["type"] ?? video["type_name"],
                    picture: video["pic"] ?? video["vod_pic"],
                    remarks: video["note"] ?? video["vod_remarks"],
                    year: video["year"] ?? video["vod_year"],
                    area: video["area"] ?? video["vod_area"],
                    director: video["director"] ?? video["vod_director"],
                    actors: video["actor"] ?? video["vod_actor"],
                    content: video["des"] ?? video["vod_content"],
                    playFrom: video["dl"] ?? video["vod_play_from"],
                    playURL: video["dd"] ?? video["vod_play_url"],
                    tag: tag,
                    action: action,
                    contentKind: ProtocolContentSemantics.kind(
                        categoryID: categoryID,
                        action: action,
                        tag: tag
                    )
                )
            )
            currentVideo = nil
        }
        text = ""
    }
}

private extension String {
    var nonEmptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
