import CryptoKit
import Foundation

/// Protocol-level meaning of an item returned by a site.
///
/// `nil` on persisted legacy models means media. Non-media values are only
/// assigned only from explicit structural fields such as `action` or `tag`;
/// display titles, category identifiers, source names, and URLs never
/// participate in this classification.
public enum VideoContentKind: String, Codable, Equatable, Hashable, Sendable {
    case media
    case action
    case unsupported
}

public struct VideoCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var filters: [VideoFilter]
    public var contentKind: VideoContentKind?

    public init(
        id: String,
        name: String,
        filters: [VideoFilter] = [],
        contentKind: VideoContentKind? = nil
    ) {
        self.id = id
        self.name = name
        self.filters = filters
        self.contentKind = contentKind
    }

    public var resolvedContentKind: VideoContentKind {
        contentKind ?? .media
    }
}

public struct VideoFilter: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var options: [VideoFilterOption]

    public init(id: String, name: String, options: [VideoFilterOption]) {
        self.id = id
        self.name = name
        self.options = options
    }
}

public struct VideoFilterOption: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { value }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct VideoSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(siteKey)::\(videoID)" }
    public var siteKey: String
    public var siteName: String
    public var videoID: String
    public var title: String
    public var posterURL: URL?
    public var remarks: String?
    public var year: String?
    public var categoryName: String?
    public var tag: String?
    public var action: String?
    public var contentKind: VideoContentKind?

    public init(
        siteKey: String,
        siteName: String,
        videoID: String,
        title: String,
        posterURL: URL? = nil,
        remarks: String? = nil,
        year: String? = nil,
        categoryName: String? = nil,
        tag: String? = nil,
        action: String? = nil,
        contentKind: VideoContentKind? = nil
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.videoID = videoID
        self.title = title
        self.posterURL = posterURL
        self.remarks = remarks
        self.year = year
        self.categoryName = categoryName
        self.tag = tag
        self.action = action
        self.contentKind = contentKind
    }

    public var resolvedContentKind: VideoContentKind {
        contentKind ?? .media
    }

    public var isFolder: Bool {
        tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("folder") == .orderedSame
    }
}

/// A structural home operation. It is intentionally separate from
/// `VideoSummary` so presentation cannot accidentally send it through movie
/// detail or playback UI.
public struct SiteActionItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(siteKey)::action::\(itemID)" }
    public var siteKey: String
    public var siteName: String
    public var itemID: String
    public var title: String
    public var remarks: String?
    public var tag: String?
    public var action: String?

    public init(
        siteKey: String,
        siteName: String,
        itemID: String,
        title: String,
        remarks: String? = nil,
        tag: String? = nil,
        action: String? = nil
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.itemID = itemID
        self.title = title
        self.remarks = remarks
        self.tag = tag
        self.action = action
    }

    public init(summary: VideoSummary) {
        self.init(
            siteKey: summary.siteKey,
            siteName: summary.siteName,
            itemID: summary.videoID,
            title: summary.title,
            remarks: summary.remarks,
            tag: summary.tag,
            action: summary.action
        )
    }

    /// Compatibility adapter for existing provider detail/action selection.
    public var selectionSummary: VideoSummary {
        VideoSummary(
            siteKey: siteKey,
            siteName: siteName,
            videoID: itemID,
            title: title,
            remarks: remarks,
            tag: tag,
            action: action,
            contentKind: .action
        )
    }
}

public struct VideoDetail: Codable, Equatable, Sendable {
    public var summary: VideoSummary
    public var area: String?
    public var director: String?
    public var actors: String?
    public var synopsis: String?
    public var playSources: [PlaySource]

    public init(
        summary: VideoSummary,
        area: String? = nil,
        director: String? = nil,
        actors: String? = nil,
        synopsis: String? = nil,
        playSources: [PlaySource] = []
    ) {
        self.summary = summary
        self.area = area
        self.director = director
        self.actors = actors
        self.synopsis = synopsis
        self.playSources = playSources
    }
}

/// The content produced after selecting a site card.
///
/// Most cards resolve to a normal video detail. FongMi configuration and
/// account-management spiders also use detail requests as commands and return
/// a placeholder item after completing the side effect. Keeping that outcome
/// distinct prevents those cards from being decoded as broken videos.
public enum SiteSelectionResult: Equatable, Sendable {
    case detail(VideoDetail)
    case action(JSONValue)
    /// The selected card is discovery metadata rather than a provider-owned
    /// detail. The host should continue through its existing search flow.
    case search(String)
}

public struct PlaySource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var episodes: [PlayEpisode]

    /// A display-name-independent identity derived from the resources exposed
    /// by this source. Providers may supply an explicit protocol identity;
    /// otherwise the host derives one without retaining expiring credentials.
    public var stableIdentity: String {
        PlaybackReferenceIdentity.source(
            explicitIdentity: referenceIdentity,
            episodes: episodes
        )
    }

    public var referenceIdentity: String?

    public init(
        name: String,
        episodes: [PlayEpisode],
        referenceIdentity: String? = nil
    ) {
        self.name = name
        self.episodes = episodes
        self.referenceIdentity = referenceIdentity
    }
}

public struct PlayEpisode: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)::\(url)" }
    public var name: String
    public var url: String

    /// A stable resource identity used for history restoration. It deliberately
    /// ignores URL hosts and short-lived credential fields so endpoint/domain
    /// changes do not turn the same resource into a different episode.
    public var stableIdentity: String {
        PlaybackReferenceIdentity.episode(
            explicitIdentity: referenceIdentity,
            name: name,
            reference: url
        )
    }

    public var referenceIdentity: String?

    public init(
        name: String,
        url: String,
        referenceIdentity: String? = nil
    ) {
        self.name = name
        self.url = url
        self.referenceIdentity = referenceIdentity
    }
}

/// Produces non-secret structural identities for playback history.
///
/// Human-facing source names never participate. URL hosts are excluded so a
/// provider can move domains without invalidating history. Credential-like
/// query/JSON fields are excluded before hashing and are therefore never
/// persisted through these identities.
public enum PlaybackReferenceIdentity {
    private static let volatileFieldFragments = [
        "auth", "authorization", "cookie", "credential", "expire", "key",
        "password", "secret", "sign", "stoken", "timestamp", "token"
    ]

    public static func episode(
        explicitIdentity: String? = nil,
        name: String,
        reference: String
    ) -> String {
        if let explicitIdentity = explicitIdentity?.trimmedNonEmpty {
            return digest("explicit:\(explicitIdentity)")
        }
        let canonical = canonicalReference(reference)
            ?? "name:\(normalizedDisplayValue(name))"
        return digest("episode-v1:\(canonical)")
    }

    public static func source(
        explicitIdentity: String? = nil,
        episodes: [PlayEpisode]
    ) -> String {
        if let explicitIdentity = explicitIdentity?.trimmedNonEmpty {
            return digest("explicit:\(explicitIdentity)")
        }
        let identities = episodes.map(\.stableIdentity).sorted()
        return digest("source-v1:\(identities.joined(separator: "|"))")
    }

    private static func canonicalReference(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           components.scheme?.isEmpty == false {
            return canonicalURL(components)
        }
        if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
           let object = try? JSONSerialization.jsonObject(with: data),
           let canonical = canonicalJSON(object) {
            return "base64-json:\(canonical)"
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let canonical = canonicalJSON(object) {
            return "json:\(canonical)"
        }
        return "opaque:\(trimmed)"
    }

    private static func canonicalURL(_ components: URLComponents) -> String {
        let path = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        let query = (components.queryItems ?? [])
            .filter { !isVolatileField($0.name) }
            .map { item in
                "\(item.name.lowercased())=\(item.value ?? "")"
            }
            .sorted()
            .joined(separator: "&")
        return query.isEmpty ? "url:\(path)" : "url:\(path)?\(query)"
    }

    private static func canonicalJSON(_ value: Any) -> String? {
        switch value {
        case let object as [String: Any]:
            return object.keys
                .filter { !isVolatileField($0) }
                .sorted()
                .compactMap { key in
                    canonicalJSON(object[key] as Any).map {
                        "\(key.lowercased()):\($0)"
                    }
                }
                .joined(separator: ",")
        case let values as [Any]:
            return values.compactMap(canonicalJSON).joined(separator: ",")
        case let string as String:
            if let components = URLComponents(string: string),
               components.scheme?.isEmpty == false {
                return canonicalURL(components)
            }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        case is NSNull:
            return "null"
        default:
            return nil
        }
    }

    private static func isVolatileField(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return volatileFieldFragments.contains { normalized.contains($0) }
    }

    private static func normalizedDisplayValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public struct Pagination: Codable, Equatable, Sendable {
    public var page: Int
    public var pageCount: Int?
    public var hasMore: Bool

    public init(page: Int, pageCount: Int?) {
        self.page = page
        self.pageCount = pageCount
        hasMore = pageCount.map { page < $0 } ?? false
    }
}

public struct VideoPage: Equatable, Sendable {
    public var items: [VideoSummary]
    public var pagination: Pagination

    public init(items: [VideoSummary], pagination: Pagination) {
        self.items = items
        self.pagination = pagination
    }
}

public struct SiteHome: Codable, Equatable, Sendable {
    public var categories: [VideoCategory]
    public var recommendations: [VideoSummary]
    public var actionItems: [SiteActionItem]

    public init(
        categories: [VideoCategory],
        recommendations: [VideoSummary],
        actionItems: [SiteActionItem] = []
    ) {
        self.categories = categories
        self.recommendations = recommendations
        self.actionItems = actionItems
    }

    private enum CodingKeys: String, CodingKey {
        case categories
        case recommendations
        case actionItems
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categories = try values.decode([VideoCategory].self, forKey: .categories)
        recommendations = try values.decode(
            [VideoSummary].self,
            forKey: .recommendations
        )
        // Existing persisted home snapshots predate action presentation.
        actionItems = try values.decodeIfPresent(
            [SiteActionItem].self,
            forKey: .actionItems
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(categories, forKey: .categories)
        try values.encode(recommendations, forKey: .recommendations)
        try values.encode(actionItems, forKey: .actionItems)
    }
}

public struct PlaybackQuality: Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var url: String

    public var id: String { "\(name)::\(url)" }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

public struct SitePlaybackResult: Equatable, Sendable {
    public var url: String
    public var needsParsing: Bool
    public var playURL: String?
    public var flag: String
    public var headers: HTTPHeaders
    public var format: String?
    public var subtitles: [URL]
    public var qualities: [PlaybackQuality]

    public init(
        url: String,
        needsParsing: Bool,
        playURL: String? = nil,
        flag: String,
        headers: HTTPHeaders = [:],
        format: String? = nil,
        subtitles: [URL] = [],
        qualities: [PlaybackQuality] = []
    ) {
        self.url = url
        self.needsParsing = needsParsing
        self.playURL = playURL
        self.flag = flag
        self.headers = headers
        self.format = format
        self.subtitles = subtitles
        self.qualities = qualities
    }
}

public struct PlaybackRefreshRequest: Equatable, Sendable {
    public var videoID: String
    public var title: String
    public var sourceIdentity: String
    public var resourceIdentity: String
    public var sourceName: String?
    public var episodeName: String?

    public init(
        videoID: String,
        title: String,
        sourceIdentity: String,
        resourceIdentity: String,
        sourceName: String? = nil,
        episodeName: String? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.sourceIdentity = sourceIdentity
        self.resourceIdentity = resourceIdentity
        self.sourceName = sourceName
        self.episodeName = episodeName
    }
}

public struct RefreshedSitePlayback: Equatable, Sendable {
    public var detail: VideoDetail
    public var source: PlaySource
    public var episode: PlayEpisode
    public var playbackResult: SitePlaybackResult

    public init(
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        playbackResult: SitePlaybackResult
    ) {
        self.detail = detail
        self.source = source
        self.episode = episode
        self.playbackResult = playbackResult
    }
}

public enum SiteCapability: String, Codable, Sendable {
    case standardXML
    case standardJSON
    case base64JSON
    case javaScriptSpider
    case javaDexSpider
    case unsupportedSpider
}

public protocol SiteProvider {
    var site: SiteConfiguration { get }
    var capability: SiteCapability { get }

    func home() async throws -> SiteHome
    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage
    /// Loads a category which the provider explicitly described as an action.
    /// Providers with an out-of-band host-action channel may wait for that
    /// action here without delaying ordinary media categories.
    func actionCategory(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage
    func select(id: String) async throws -> SiteSelectionResult
    func select(summary: VideoSummary) async throws -> SiteSelectionResult
    func select(action item: SiteActionItem) async throws -> SiteSelectionResult
    func detail(id: String) async throws -> VideoDetail
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult
    /// Rebuilds the current URL and transient request context for the same
    /// stable resource. The default implementation never falls through to a
    /// different source or episode.
    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback
    func action(_ action: String) async throws -> JSONValue
}

public extension SiteProvider {
    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        func matchingPlayback(
            in detail: VideoDetail
        ) -> (PlaySource, PlayEpisode)? {
            let structuralMatches = detail.playSources.flatMap { source in
                source.episodes.compactMap { episode in
                    source.stableIdentity == request.sourceIdentity
                        && episode.stableIdentity == request.resourceIdentity
                        ? (source, episode)
                        : nil
                }
            }
            if structuralMatches.count == 1 {
                return structuralMatches[0]
            }
            let displayMatches = detail.playSources.flatMap { source in
                source.episodes.compactMap { episode in
                    source.name == request.sourceName
                        && episode.name == request.episodeName
                        ? (source, episode)
                        : nil
                }
            }
            return displayMatches.count == 1 ? displayMatches[0] : nil
        }

        let directDetail = try? await self.detail(id: request.videoID)
        let detail: VideoDetail
        let selected: (PlaySource, PlayEpisode)
        if let directDetail,
           let directMatch = matchingPlayback(in: directDetail) {
            detail = directDetail
            selected = directMatch
        } else {
            let page = try await search(
                keyword: request.title,
                page: 1,
                quick: false
            )
            let exactMatches = page.items.filter {
                $0.title.compare(
                    request.title,
                    options: [
                        .caseInsensitive,
                        .widthInsensitive,
                        .diacriticInsensitive
                    ]
                ) == .orderedSame
            }
            guard exactMatches.count == 1 else {
                throw AppError.playback("无法从当前搜索结果唯一定位原历史内容")
            }
            detail = try await self.detail(id: exactMatches[0].videoID)
            guard let searchedMatch = matchingPlayback(in: detail) else {
                throw AppError.playback("无法从最新详情唯一匹配原历史线路")
            }
            selected = searchedMatch
        }
        let result = try await player(
            flag: selected.0.name,
            episodeURL: selected.1.url
        )
        return RefreshedSitePlayback(
            detail: detail,
            source: selected.0,
            episode: selected.1,
            playbackResult: result
        )
    }

    func actionCategory(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try await category(id: id, page: page, filters: filters)
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try await select(id: summary.videoID)
    }

    func select(action item: SiteActionItem) async throws -> SiteSelectionResult {
        try await select(summary: item.selectionSummary)
    }

    func select(id: String) async throws -> SiteSelectionResult {
        .detail(try await detail(id: id))
    }

    func action(_ action: String) async throws -> JSONValue {
        throw AppError.unsupported("站点 \(site.name) 不支持操作 \(action)")
    }
}
