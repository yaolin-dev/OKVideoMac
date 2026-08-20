import Foundation

/// Protocol-level meaning of an item returned by a site.
///
/// `nil` on persisted legacy models means media. Non-media values are only
/// assigned from structural fields such as category identifiers, `action`, or
/// `tag`; display titles and URLs never participate in this classification.
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

    public init(name: String, episodes: [PlayEpisode]) {
        self.name = name
        self.episodes = episodes
    }
}

public struct PlayEpisode: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)::\(url)" }
    public var name: String
    public var url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
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
    func select(id: String) async throws -> SiteSelectionResult
    func select(summary: VideoSummary) async throws -> SiteSelectionResult
    func select(action item: SiteActionItem) async throws -> SiteSelectionResult
    func detail(id: String) async throws -> VideoDetail
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult
    func action(_ action: String) async throws -> JSONValue
}

public extension SiteProvider {
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
