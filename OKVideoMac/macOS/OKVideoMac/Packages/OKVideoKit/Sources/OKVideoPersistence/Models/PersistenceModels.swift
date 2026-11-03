import Foundation
import CryptoKit
import OKVideoCore

public enum StoredConfigurationSourceKind: String, Codable, Sendable {
    case remote
    case localFile
    case pasted
    case xtream
}

public struct StoredConfiguration: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceKind: StoredConfigurationSourceKind
    public var sourceValue: String?
    public var baseURL: URL?
    public var rawData: Data
    public var updatedAt: Date
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sourceKind: StoredConfigurationSourceKind,
        sourceValue: String? = nil,
        baseURL: URL? = nil,
        rawData: Data,
        updatedAt: Date = Date(),
        isActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sourceKind = sourceKind
        self.sourceValue = sourceValue
        self.baseURL = baseURL
        self.rawData = rawData
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}

public struct ConfigurationHistoryRestoreResult: Sendable {
    public var configuration: StoredConfiguration
    public var configurations: [StoredConfiguration]
    public var consideredHistoryCount: Int
    public var changedHistoryCount: Int

    public init(
        configuration: StoredConfiguration,
        configurations: [StoredConfiguration],
        consideredHistoryCount: Int,
        changedHistoryCount: Int
    ) {
        self.configuration = configuration
        self.configurations = configurations
        self.consideredHistoryCount = consideredHistoryCount
        self.changedHistoryCount = changedHistoryCount
    }
}

public enum StoredLiveSourceKind: String, Codable, Sendable {
    case remote
    case localFile
    case pasted
}

public struct StoredLiveSource: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceKind: StoredLiveSourceKind
    public var sourceValue: String?
    public var baseURL: URL?
    public var rawData: Data
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sourceKind: StoredLiveSourceKind,
        sourceValue: String? = nil,
        baseURL: URL? = nil,
        rawData: Data,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceKind = sourceKind
        self.sourceValue = sourceValue
        self.baseURL = baseURL
        self.rawData = rawData
        self.updatedAt = updatedAt
    }
}

public struct FavoriteIdentity: Hashable, Sendable {
    public var configurationID: UUID?
    public var siteKey: String
    public var videoID: String
    public var sourceFingerprint: String
}

public struct FavoriteRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { favoriteID.uuidString.lowercased() }
    public var favoriteID: UUID
    public var configurationID: UUID?
    public var configurationName: String?
    public var siteName: String?
    public var sourceFingerprint: String
    public var siteKey: String
    public var videoID: String
    public var title: String
    public var posterURL: URL?
    public var synopsis: String?
    public var createdAt: Date
    public var year: String?
    public var categoryName: String?
    public var identity: FavoriteIdentity {
        FavoriteIdentity(configurationID: configurationID, siteKey: siteKey,
                         videoID: videoID, sourceFingerprint: sourceFingerprint)
    }

    public init(siteKey: String, videoID: String, title: String,
                posterURL: URL? = nil, synopsis: String? = nil, createdAt: Date = Date(),
                favoriteID: UUID = UUID(), configurationID: UUID? = nil,
                configurationName: String? = nil, siteName: String? = nil,
                sourceFingerprint: String = "", year: String? = nil, categoryName: String? = nil) {
        self.favoriteID = favoriteID; self.configurationID = configurationID
        self.configurationName = configurationName; self.siteName = siteName
        self.sourceFingerprint = sourceFingerprint
        self.siteKey = siteKey; self.videoID = videoID; self.title = title
        self.posterURL = posterURL; self.synopsis = synopsis; self.createdAt = createdAt
        self.year = year; self.categoryName = categoryName
    }
    private enum CodingKeys: String, CodingKey {
        case favoriteID, configurationID, configurationName, siteName, sourceFingerprint
        case siteKey, videoID, title, posterURL, synopsis, createdAt, year, categoryName
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteKey = try c.decode(String.self, forKey: .siteKey)
        videoID = try c.decode(String.self, forKey: .videoID)
        title = try c.decode(String.self, forKey: .title)
        posterURL = try c.decodeIfPresent(URL.self, forKey: .posterURL)
        synopsis = try c.decodeIfPresent(String.self, forKey: .synopsis)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        configurationID = try c.decodeIfPresent(UUID.self, forKey: .configurationID)
        configurationName = try c.decodeIfPresent(String.self, forKey: .configurationName)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        sourceFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? ""
        year = try c.decodeIfPresent(String.self, forKey: .year)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
        // Legacy decoding is deterministic. Database migration assigns an ID
        // once and persists it; merely reading an old document never changes it.
        let encoded = try JSONEncoder().encode([siteKey, videoID])
        let bytes = Array(SHA256.hash(data: encoded).prefix(16))
        favoriteID = try c.decodeIfPresent(UUID.self, forKey: .favoriteID) ?? UUID(uuid:
            (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
             bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

public struct HistoryNavigationSource: Codable, Equatable, Sendable {
    public var providerStableID: String?
    public var flag: String
    public var name: String
    public var index: Int?

    public init(
        providerStableID: String? = nil,
        flag: String,
        name: String,
        index: Int? = nil
    ) {
        self.providerStableID = providerStableID
        self.flag = flag
        self.name = name
        self.index = index
    }
}

public struct HistoryNavigationEpisode: Codable, Equatable, Sendable {
    public var providerStableID: String?
    public var name: String
    public var normalizedFilename: String
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var index: Int?
    public var metadata: PlaybackEpisodeMetadata?
    public var categoryName: String?

    public init(
        providerStableID: String? = nil,
        name: String,
        normalizedFilename: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        index: Int? = nil,
        metadata: PlaybackEpisodeMetadata? = nil,
        categoryName: String? = nil
    ) {
        self.providerStableID = providerStableID
        self.name = name
        self.normalizedFilename = normalizedFilename
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.index = index
        self.metadata = metadata
        self.categoryName = categoryName
    }
}

/// A credential-free recipe for replaying the user's navigation path.
///
/// The recipe deliberately stores presentation and structural identity only.
/// Runtime episode URLs, signed media URLs, Cookies, Authorization values and
/// local proxy capabilities are never representable here.
public struct HistoryNavigationRecipe: Codable, Equatable, Sendable {
    public static let currentVersion = 5

    public var version: Int
    public var configurationID: UUID
    public var siteKey: String
    public var detailID: String
    public var detailRequestID: String?
    public var source: HistoryNavigationSource
    public var episode: HistoryNavigationEpisode
    public var resumePosition: TimeInterval

    public init(
        version: Int = currentVersion,
        configurationID: UUID,
        siteKey: String,
        detailID: String,
        detailRequestID: String? = nil,
        source: HistoryNavigationSource,
        episode: HistoryNavigationEpisode,
        resumePosition: TimeInterval = 0
    ) {
        self.version = version
        self.configurationID = configurationID
        self.siteKey = siteKey
        self.detailID = detailID
        self.detailRequestID = detailRequestID
        self.source = source
        self.episode = episode
        self.resumePosition = max(0, resumePosition)
    }
}

public extension HistoryNavigationRecipe {
    func sanitizedForPersistence() -> HistoryNavigationRecipe? {
        guard version > 0,
              let siteKey = Self.safeDisplayValue(siteKey),
              let detailID = Self.safeDisplayValue(detailID),
              let sourceFlag = Self.safeDisplayValue(source.flag),
              let sourceName = Self.safeDisplayValue(source.name),
              let episodeName = Self.safeDisplayValue(episode.name),
              let normalizedFilename = Self.safeDisplayValue(
                episode.normalizedFilename
              ) else {
            return nil
        }
        let sourceStableID = source.providerStableID.flatMap {
            PlaybackPersistencePolicy.sanitizedPlaybackIdentity($0)
        }
        let episodeStableID = episode.providerStableID.flatMap {
            PlaybackPersistencePolicy.sanitizedPlaybackIdentity($0)
        }
        return HistoryNavigationRecipe(
            configurationID: configurationID,
            siteKey: siteKey,
            detailID: detailID,
            detailRequestID: detailRequestID.flatMap { FavoritePersistencePolicy.isSafeLocator($0) ? $0 : nil },
            source: HistoryNavigationSource(
                providerStableID: sourceStableID,
                flag: sourceFlag,
                name: sourceName,
                index: Self.safeIndex(source.index)
            ),
            episode: HistoryNavigationEpisode(
                providerStableID: episodeStableID,
                name: episodeName,
                normalizedFilename: normalizedFilename,
                seasonNumber: Self.safeNumber(episode.seasonNumber),
                episodeNumber: Self.safeNumber(episode.episodeNumber),
                index: Self.safeIndex(episode.index),
                metadata: episode.metadata.map { .init(form: $0.form, season: $0.season.flatMap { (0...10_000).contains($0) ? $0 : nil }, episode: Self.safeNumber($0.episode)) },
                categoryName: episode.categoryName.flatMap(Self.safeDisplayValue)
            ),
            resumePosition: resumePosition.isFinite
                ? max(0, resumePosition)
                : 0
        )
    }

    private static func safeDisplayValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func safeIndex(_ value: Int?) -> Int? {
        value.flatMap { (0...100_000).contains($0) ? $0 : nil }
    }

    private static func safeNumber(_ value: Int?) -> Int? {
        value.flatMap { (0...100_000).contains($0) ? $0 : nil }
    }
}

public struct HistoryPlaybackReference: Codable, Equatable, Sendable {
    public static let currentVersion = 5

    public var version: Int
    public var sourceIdentity: String
    public var resourceIdentity: String
    /// Provider-owned durable identity used to rebuild an expired media
    /// session. This value is safe to persist and deliberately excludes the
    /// runtime URL, Cookie, Authorization and loopback media-session token.
    /// It is optional so version 1/2 history JSON continues to decode.
    public var providerResourceReference: PlaybackResourceReference?
    /// Exact credential-free navigation path captured when the user selects
    /// the episode. Optional for version 1-3 records.
    public var navigationRecipe: HistoryNavigationRecipe?
    public var originalResource: OriginalMediaResource?
    /// Only non-sensitive request context may be persisted here. Cookie and
    /// Authorization are intentionally reacquired from the provider.
    public var replayHeaders: [String: String]

    public init(
        version: Int = currentVersion,
        sourceIdentity: String,
        resourceIdentity: String,
        providerResourceReference: PlaybackResourceReference? = nil,
        navigationRecipe: HistoryNavigationRecipe? = nil,
        originalResource: OriginalMediaResource? = nil,
        replayHeaders: [String: String] = [:]
    ) {
        self.version = version
        self.sourceIdentity = sourceIdentity
        self.resourceIdentity = resourceIdentity
        self.providerResourceReference = providerResourceReference
        self.navigationRecipe = navigationRecipe
        self.originalResource = originalResource?.validated
        self.replayHeaders = replayHeaders
    }
}

public extension HistoryPlaybackReference {
    /// Returns the complete durable subset of a playback reference. Runtime
    /// media/session material is intentionally not representable here.
    func sanitizedForPersistence() -> HistoryPlaybackReference? {
        guard let sourceIdentity = PlaybackPersistencePolicy
            .sanitizedPlaybackIdentity(sourceIdentity),
              let resourceIdentity = PlaybackPersistencePolicy
                .sanitizedPlaybackIdentity(resourceIdentity) else {
            return nil
        }
        return HistoryPlaybackReference(
            version: Self.currentVersion,
            sourceIdentity: sourceIdentity,
            resourceIdentity: resourceIdentity,
            providerResourceReference: PlaybackPersistencePolicy
                .sanitizedProviderResourceReference(
                    providerResourceReference
                ),
            navigationRecipe: navigationRecipe?.sanitizedForPersistence(),
            originalResource: originalResource?.validated,
            replayHeaders: PlaybackPersistencePolicy.sanitizedReplayHeaders(
                replayHeaders
            )
        )
    }
}

public struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
    /// Keep the history primary key stable; only the navigation locator changes.
    /// Never borrow a locator from another configuration or site.
    public var navigationDetailID: String {
        guard let recipe = playbackReference?.navigationRecipe,
              recipe.configurationID == configurationID, recipe.siteKey == siteKey else { return videoID }
        if let locator = recipe.detailRequestID, FavoritePersistencePolicy.isSafeLocator(locator) { return locator }
        return recipe.detailID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? videoID : recipe.detailID
    }

    public var id: String {
        "\(configurationID?.uuidString.lowercased() ?? "legacy")::\(siteKey)::\(videoID)::\(sourceKey)"
    }
    /// The on-demand configuration that produced this record.
    ///
    /// Site keys are only unique inside one FongMi configuration. Keeping the
    /// configuration identity prevents a history item from being replayed by
    /// a different provider after the user switches on-demand sources.
    public var configurationID: UUID?
    public var siteKey: String
    public var videoID: String
    public var title: String
    public var posterURL: URL?
    /// Stable identity of the playback source/line within one video.
    ///
    /// `sourceName` remains presentation text. Keeping a separate key lets
    /// two lines of the same site/video retain independent episode progress.
    public var sourceKey: String
    public var sourceName: String?
    public var episodeName: String?
    public var episodeReference: String?
    public var mediaReference: String?
    public var playbackReference: HistoryPlaybackReference?
    public var position: TimeInterval
    public var duration: TimeInterval
    public var watchedAt: Date

    public init(
        configurationID: UUID? = nil,
        siteKey: String,
        videoID: String,
        title: String,
        posterURL: URL? = nil,
        sourceKey: String? = nil,
        sourceName: String? = nil,
        episodeName: String? = nil,
        episodeReference: String? = nil,
        mediaReference: String? = nil,
        playbackReference: HistoryPlaybackReference? = nil,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        watchedAt: Date = Date()
    ) {
        self.configurationID = configurationID
        self.siteKey = siteKey
        self.videoID = videoID
        self.title = title
        self.posterURL = posterURL
        self.sourceKey = Self.normalizedSourceKey(sourceKey ?? sourceName)
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.episodeReference = episodeReference
        self.mediaReference = mediaReference
        self.playbackReference = playbackReference
        self.position = max(0, position)
        self.duration = max(0, duration)
        self.watchedAt = watchedAt
    }

    public static func normalizedSourceKey(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "__legacy__" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case configurationID
        case siteKey
        case videoID
        case title
        case posterURL
        case sourceKey
        case sourceName
        case episodeName
        case episodeReference
        case mediaReference
        case playbackReference
        case position
        case duration
        case watchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSourceName = try container.decodeIfPresent(
            String.self,
            forKey: .sourceName
        )
        self.init(
            configurationID: try container.decodeIfPresent(
                UUID.self,
                forKey: .configurationID
            ),
            siteKey: try container.decode(String.self, forKey: .siteKey),
            videoID: try container.decode(String.self, forKey: .videoID),
            title: try container.decode(String.self, forKey: .title),
            posterURL: try container.decodeIfPresent(URL.self, forKey: .posterURL),
            sourceKey: try container.decodeIfPresent(String.self, forKey: .sourceKey),
            sourceName: decodedSourceName,
            episodeName: try container.decodeIfPresent(String.self, forKey: .episodeName),
            episodeReference: try container.decodeIfPresent(
                String.self,
                forKey: .episodeReference
            ),
            mediaReference: try container.decodeIfPresent(
                String.self,
                forKey: .mediaReference
            ),
            playbackReference: try container.decodeIfPresent(
                HistoryPlaybackReference.self,
                forKey: .playbackReference
            ),
            position: try container.decode(Double.self, forKey: .position),
            duration: try container.decode(Double.self, forKey: .duration),
            watchedAt: try container.decode(Date.self, forKey: .watchedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configurationID, forKey: .configurationID)
        try container.encode(siteKey, forKey: .siteKey)
        try container.encode(videoID, forKey: .videoID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(posterURL, forKey: .posterURL)
        try container.encode(sourceKey, forKey: .sourceKey)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(episodeName, forKey: .episodeName)
        try container.encodeIfPresent(episodeReference, forKey: .episodeReference)
        try container.encodeIfPresent(mediaReference, forKey: .mediaReference)
        try container.encodeIfPresent(playbackReference, forKey: .playbackReference)
        try container.encode(position, forKey: .position)
        try container.encode(duration, forKey: .duration)
        try container.encode(watchedAt, forKey: .watchedAt)
    }
}

public extension HistoryRecord {
    /// Applies the durable-playback boundary to the entire record. Callers may
    /// use this before display, but repositories must still enforce it on both
    /// writes and reads because old or externally modified databases exist.
    func sanitizedForPersistence() -> HistoryRecord {
        var record = self
        record.episodeReference = PlaybackPersistencePolicy
            .sanitizedOpaqueLocator(episodeReference)
        record.mediaReference = PlaybackPersistencePolicy
            .sanitizedMediaReference(mediaReference)
        record.playbackReference = playbackReference?
            .sanitizedForPersistence()
        if let recipe = record.playbackReference?.navigationRecipe,
           recipe.configurationID != record.configurationID
                || recipe.siteKey != record.siteKey
                || recipe.detailID != record.videoID {
            record.playbackReference?.navigationRecipe = nil
        }
        record.position = position.isFinite ? max(0, position) : 0
        record.duration = duration.isFinite ? max(0, duration) : 0
        if !watchedAt.timeIntervalSince1970.isFinite {
            record.watchedAt = Date(timeIntervalSince1970: 0)
        }
        return record
    }
}

public protocol ConfigurationRepository {
    func saveConfiguration(_ configuration: StoredConfiguration) async throws
    func configurations() async throws -> [StoredConfiguration]
    func activeConfiguration() async throws -> StoredConfiguration?
    func activateConfiguration(id: UUID) async throws
    func deleteConfiguration(id: UUID) async throws
}

public protocol LiveSourceRepository {
    func saveLiveSource(_ source: StoredLiveSource) async throws
    func liveSources() async throws -> [StoredLiveSource]
    func deleteLiveSource(id: UUID) async throws
}

public protocol FavoritesRepository {
    func saveFavorite(_ favorite: FavoriteRecord) async throws
    func favorites() async throws -> [FavoriteRecord]
    func deleteFavorite(siteKey: String, videoID: String) async throws
    @discardableResult
    func deleteAllFavorites() async throws -> Int
}

public protocol HistoryRepository {
    func saveHistory(_ history: HistoryRecord, incognito: Bool) async throws
    func replaceHistory(
        _ original: HistoryRecord,
        with replacement: HistoryRecord,
        incognito: Bool
    ) async throws
    func history() async throws -> [HistoryRecord]
    @discardableResult
    func deleteHistory(
        configurationID: UUID?,
        siteKey: String,
        videoID: String,
        sourceKey: String
    ) async throws -> Int
    @discardableResult
    func deleteHistory(configurationID: UUID) async throws -> Int
    @discardableResult
    func deleteHistory(olderThan cutoff: Date) async throws -> Int
}

public protocol SettingsRepository {
    func setSetting(_ value: JSONValue?, forKey key: String) async throws
    func setting(forKey key: String) async throws -> JSONValue?
}

public protocol PlaybackSkipRuleRepository {
    func savePlaybackSkipRule(_ rule: PlaybackSkipRule) async throws
    func playbackSkipRules(
        configurationID: UUID
    ) async throws -> [PlaybackSkipRule]
    func deletePlaybackSkipRule(
        identity: PlaybackSkipRuleIdentity
    ) async throws
    func deletePlaybackSkipRules(
        configurationID: UUID
    ) async throws
    func savePlaybackCompletionMarker(
        _ marker: PlaybackCompletionMarker
    ) async throws
    func playbackCompletionMarkers(
        configurationID: UUID
    ) async throws -> [PlaybackCompletionMarker]
    func deletePlaybackCompletionMarker(
        identity: PlaybackSkipRuleIdentity
    ) async throws
    func deletePlaybackCompletionMarkers(
        configurationID: UUID
    ) async throws
    func deletePlaybackCompletionMarkers(
        historyRecordIDs: Set<String>
    ) async throws
}

public protocol DanmakuBindingRepository {
    func saveDanmakuBinding(_ binding: DanmakuBinding) async throws
    func danmakuBindings(
        configurationID: UUID
    ) async throws -> [DanmakuBinding]
    func danmakuBinding(
        for editionIdentity: DanmakuEditionIdentity
    ) async throws -> DanmakuBinding?
    func deleteDanmakuBinding(
        for editionIdentity: DanmakuEditionIdentity
    ) async throws
    func deleteDanmakuBindings(configurationID: UUID) async throws
}
