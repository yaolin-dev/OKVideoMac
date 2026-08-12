import Foundation

public struct VideoCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var filters: [VideoFilter]

    public init(id: String, name: String, filters: [VideoFilter] = []) {
        self.id = id
        self.name = name
        self.filters = filters
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
        action: String? = nil
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
    }

    public var isFolder: Bool {
        tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("folder") == .orderedSame
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

    public init(categories: [VideoCategory], recommendations: [VideoSummary]) {
        self.categories = categories
        self.recommendations = recommendations
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
    func detail(id: String) async throws -> VideoDetail
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult
    func action(_ action: String) async throws -> JSONValue
}

public extension SiteProvider {
    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try await select(id: summary.videoID)
    }

    func select(id: String) async throws -> SiteSelectionResult {
        .detail(try await detail(id: id))
    }

    func action(_ action: String) async throws -> JSONValue {
        throw AppError.unsupported("站点 \(site.name) 不支持操作 \(action)")
    }
}
