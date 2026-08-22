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

/// A provider-owned reference that can be persisted without teaching the host
/// how a cloud drive, Spider, source or episode encodes its identity.
///
/// `stableResourceLocator` is opaque to the host: it may only be returned to
/// the same provider/version for refresh. It must never be used for display,
/// source-name matching or cross-provider fallback.
public struct PlaybackResourceReference: Codable, Equatable, Hashable, Sendable {
    public enum Stability: String, Codable, Equatable, Hashable, Sendable {
        /// The provider explicitly guarantees that the locator is durable.
        case providerStable
        /// Compatibility for a legacy provider episode reference. The host
        /// may replay it only through the same provider and must not parse it.
        case providerReplay
    }

    public var schemaVersion: Int
    public var configurationIdentity: String
    public var siteIdentity: String
    public var providerKind: String
    public var providerVersion: Int
    public var stableResourceLocator: String
    public var sourceIdentity: String
    public var episodeIdentity: String
    public var stability: Stability
    public var expiresAt: Date?

    public init(
        schemaVersion: Int = 1,
        configurationIdentity: String,
        siteIdentity: String,
        providerKind: String,
        providerVersion: Int,
        stableResourceLocator: String,
        sourceIdentity: String,
        episodeIdentity: String,
        stability: Stability,
        expiresAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.configurationIdentity = configurationIdentity
        self.siteIdentity = siteIdentity
        self.providerKind = providerKind
        self.providerVersion = providerVersion
        self.stableResourceLocator = stableResourceLocator
        self.sourceIdentity = sourceIdentity
        self.episodeIdentity = episodeIdentity
        self.stability = stability
        self.expiresAt = expiresAt
    }
}

/// The narrow, provider-authored part of a durable playback reference.
///
/// A Spider may include this object in its player response under
/// `providerResourceReference`. The host supplies configuration/site binding
/// itself and never derives this locator from a media or localhost proxy URL.
/// Only `.providerStable`, URL-free locators are accepted for persistence.
public struct ProviderPlaybackResourceDescriptor: Equatable, Hashable, Sendable {
    public var schemaVersion: Int
    public var providerVersion: Int
    public var stableResourceLocator: String
    public var stability: PlaybackResourceReference.Stability

    public init(
        schemaVersion: Int,
        providerVersion: Int,
        stableResourceLocator: String,
        stability: PlaybackResourceReference.Stability
    ) {
        self.schemaVersion = schemaVersion
        self.providerVersion = providerVersion
        self.stableResourceLocator = stableResourceLocator
        self.stability = stability
    }
}

/// Complete, short-lived media request contract returned by a provider.
///
/// This model is deliberately not Codable: authorization headers and proxy
/// session context are runtime-only and must not leak into playback history.
public struct PlaybackMediaSession: Equatable, Sendable {
    public enum Transport: String, Equatable, Sendable {
        /// The media URL is a localhost capability owned by the provider VM.
        case providerLoopback
        /// An older bridge wrapped the upstream URL in its unscoped localhost
        /// endpoint. This remains loopback transport, but it is not an opaque
        /// provider-owned media session and must not be treated as one.
        case compatibilityLoopback
        /// A legacy provider could not establish a scoped loopback session.
        case compatibilityDirect
    }

    public enum RedirectPolicy: String, Equatable, Sendable {
        case follow
        case providerDefined
    }

    public enum RangePolicy: String, Equatable, Sendable {
        case forward
        case providerDefined
    }

    public var sessionID: String
    public var transport: Transport
    public var mediaURL: String
    public var headers: HTTPHeaders
    public var authorizationContextReference: String?
    public var proxyRequestID: String?
    /// Non-secret fingerprint of the exact upstream media request. Together
    /// with `resourceReference`, this lets the host prove both that it selected
    /// the same stable resource and that a refresh did not reuse the cached
    /// signed URL, without exposing that URL, Cookie or authorization token.
    public var upstreamResourceFingerprint: String?
    /// Present only when the provider explicitly reports whether this session
    /// was produced by a real cache-bypassing refresh. Compatibility bridges
    /// leave it `nil`; the host must never infer it from a changed session URL.
    public var refreshPerformed: Bool?
    public var expiresAt: Date?
    public var redirectPolicy: RedirectPolicy
    public var rangePolicy: RangePolicy
    public var resourceReference: PlaybackResourceReference

    public init(
        sessionID: String,
        transport: Transport,
        mediaURL: String,
        headers: HTTPHeaders = [:],
        authorizationContextReference: String? = nil,
        proxyRequestID: String? = nil,
        upstreamResourceFingerprint: String? = nil,
        refreshPerformed: Bool? = nil,
        expiresAt: Date? = nil,
        redirectPolicy: RedirectPolicy = .providerDefined,
        rangePolicy: RangePolicy = .providerDefined,
        resourceReference: PlaybackResourceReference
    ) {
        self.sessionID = sessionID
        self.transport = transport
        self.mediaURL = mediaURL
        self.headers = headers
        self.authorizationContextReference = authorizationContextReference
        self.proxyRequestID = proxyRequestID
        self.upstreamResourceFingerprint = upstreamResourceFingerprint
        self.refreshPerformed = refreshPerformed
        self.expiresAt = expiresAt
        self.redirectPolicy = redirectPolicy
        self.rangePolicy = rangePolicy
        self.resourceReference = resourceReference
    }
}

public struct SitePlaybackResult: Equatable, Sendable {
    public enum ValidationPolicy: Equatable, Sendable {
        /// Use the generic HEAD/range reachability probe before loading.
        case preflight
        /// The provider produced an authenticated or short-lived resource;
        /// the player load is the only authoritative validity check.
        case playerAuthoritative
    }

    public var url: String
    public var needsParsing: Bool
    public var playURL: String?
    public var flag: String
    public var headers: HTTPHeaders
    public var format: String?
    public var subtitles: [URL]
    public var qualities: [PlaybackQuality]
    public var validationPolicy: ValidationPolicy
    public var resourceReference: PlaybackResourceReference?
    public var mediaSession: PlaybackMediaSession?

    public init(
        url: String,
        needsParsing: Bool,
        playURL: String? = nil,
        flag: String,
        headers: HTTPHeaders = [:],
        format: String? = nil,
        subtitles: [URL] = [],
        qualities: [PlaybackQuality] = [],
        validationPolicy: ValidationPolicy = .preflight,
        resourceReference: PlaybackResourceReference? = nil,
        mediaSession: PlaybackMediaSession? = nil
    ) {
        self.url = url
        self.needsParsing = needsParsing
        self.playURL = playURL
        self.flag = flag
        self.headers = headers
        self.format = format
        self.subtitles = subtitles
        self.qualities = qualities
        self.validationPolicy = validationPolicy
        self.resourceReference = resourceReference
        self.mediaSession = mediaSession
    }
}

public struct PlaybackRefreshRequest: Equatable, Sendable {
    public var videoID: String
    public var title: String
    public var sourceIdentity: String
    public var resourceIdentity: String
    public var sourceName: String?
    public var episodeName: String?
    /// Provider-owned opaque episode reference captured when playback was
    /// originally resolved. Hosts persist and compare it, but never parse it.
    public var episodeReference: String?
    /// Complete provider-owned identity captured with the original playback.
    /// Only the provider that issued this reference may interpret or replay
    /// its locator. Other providers continue to use the structural fields
    /// above and never inherit a bridge dependency.
    public var providerResourceReference: PlaybackResourceReference?

    public init(
        videoID: String,
        title: String,
        sourceIdentity: String,
        resourceIdentity: String,
        sourceName: String? = nil,
        episodeName: String? = nil,
        episodeReference: String? = nil,
        providerResourceReference: PlaybackResourceReference? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.sourceIdentity = sourceIdentity
        self.resourceIdentity = resourceIdentity
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.episodeReference = episodeReference
        self.providerResourceReference = providerResourceReference
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
    /// Returns whether this exact provider instance owns and can safely replay
    /// the opaque resource reference. The host must never infer ownership from
    /// a provider class, source name, card ID, URL or domain.
    func acceptsPlaybackResourceReference(
        _ reference: PlaybackResourceReference
    ) -> Bool
    func action(_ action: String) async throws -> JSONValue
}

public extension SiteProvider {
    func acceptsPlaybackResourceReference(
        _ reference: PlaybackResourceReference
    ) -> Bool {
        false
    }

    /// Resolves the one source/episode that is structurally the same resource
    /// as a previous playback. Providers which need a cache-bypassing player
    /// call can reuse this selection policy without copying its matching and
    /// duplicate-title safeguards.
    func resolvePlaybackRefreshSelection(
        _ request: PlaybackRefreshRequest
    ) async throws -> (
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode
    ) {
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
            if let episodeReference = request.episodeReference?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !episodeReference.isEmpty {
                let referenceMatches: [(PlaySource, PlayEpisode)] = detail
                    .playSources.flatMap { source in
                    source.episodes.compactMap { episode in
                        guard episode.url == episodeReference else { return nil }
                        if source.stableIdentity == request.sourceIdentity
                            || request.sourceName == nil
                            || source.name == request.sourceName {
                            return (source, episode)
                        }
                        return nil
                    }
                }
                if referenceMatches.count == 1 {
                    return referenceMatches[0]
                }
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
            guard !exactMatches.isEmpty else {
                throw AppError.playback("无法从当前搜索结果唯一定位原历史内容")
            }

            // Duplicate titles are normal for cloud-drive search results. The
            // resource identity, not title uniqueness, decides which result is
            // safe to refresh. Bound detail fan-out to keep recovery finite.
            var matchingDetails: [(VideoDetail, PlaySource, PlayEpisode)] = []
            for summary in exactMatches.prefix(20) {
                guard let candidateDetail = try? await self.detail(
                    id: summary.videoID
                ), let candidate = matchingPlayback(in: candidateDetail) else {
                    continue
                }
                matchingDetails.append(
                    (candidateDetail, candidate.0, candidate.1)
                )
            }
            guard matchingDetails.count == 1,
                  let refreshed = matchingDetails.first else {
                if matchingDetails.isEmpty {
                    throw AppError.playback("无法从最新详情唯一匹配原历史线路")
                }
                throw AppError.playback("多个同名结果均匹配原历史资源，无法安全自动选择")
            }
            detail = refreshed.0
            selected = (refreshed.1, refreshed.2)
        }
        return (
            detail: detail,
            source: selected.0,
            episode: selected.1
        )
    }

    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        let selected = try await resolvePlaybackRefreshSelection(request)
        let result = try await player(
            flag: selected.source.name,
            episodeURL: selected.episode.url
        )
        return RefreshedSitePlayback(
            detail: selected.detail,
            source: selected.source,
            episode: selected.episode,
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
