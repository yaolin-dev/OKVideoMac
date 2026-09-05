import Foundation
import OKVideoCore

public enum StoredConfigurationSourceKind: String, Codable, Sendable {
    case remote
    case localFile
    case pasted
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

public struct FavoriteRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(siteKey)::\(videoID)" }
    public var siteKey: String
    public var videoID: String
    public var title: String
    public var posterURL: URL?
    public var synopsis: String?
    public var createdAt: Date

    public init(
        siteKey: String,
        videoID: String,
        title: String,
        posterURL: URL? = nil,
        synopsis: String? = nil,
        createdAt: Date = Date()
    ) {
        self.siteKey = siteKey
        self.videoID = videoID
        self.title = title
        self.posterURL = posterURL
        self.synopsis = synopsis
        self.createdAt = createdAt
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

    public init(
        providerStableID: String? = nil,
        name: String,
        normalizedFilename: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        index: Int? = nil
    ) {
        self.providerStableID = providerStableID
        self.name = name
        self.normalizedFilename = normalizedFilename
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.index = index
    }
}

/// A credential-free recipe for replaying the user's navigation path.
///
/// The recipe deliberately stores presentation and structural identity only.
/// Runtime episode URLs, signed media URLs, Cookies, Authorization values and
/// local proxy capabilities are never representable here.
public struct HistoryNavigationRecipe: Codable, Equatable, Sendable {
    public static let currentVersion = 4

    public var version: Int
    public var configurationID: UUID
    public var siteKey: String
    public var detailID: String
    public var source: HistoryNavigationSource
    public var episode: HistoryNavigationEpisode
    public var resumePosition: TimeInterval

    public init(
        version: Int = currentVersion,
        configurationID: UUID,
        siteKey: String,
        detailID: String,
        source: HistoryNavigationSource,
        episode: HistoryNavigationEpisode,
        resumePosition: TimeInterval = 0
    ) {
        self.version = version
        self.configurationID = configurationID
        self.siteKey = siteKey
        self.detailID = detailID
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
                index: Self.safeIndex(episode.index)
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
    public static let currentVersion = 4

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
    /// Only non-sensitive request context may be persisted here. Cookie and
    /// Authorization are intentionally reacquired from the provider.
    public var replayHeaders: [String: String]

    public init(
        version: Int = currentVersion,
        sourceIdentity: String,
        resourceIdentity: String,
        providerResourceReference: PlaybackResourceReference? = nil,
        navigationRecipe: HistoryNavigationRecipe? = nil,
        replayHeaders: [String: String] = [:]
    ) {
        self.version = version
        self.sourceIdentity = sourceIdentity
        self.resourceIdentity = resourceIdentity
        self.providerResourceReference = providerResourceReference
        self.navigationRecipe = navigationRecipe
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
            replayHeaders: PlaybackPersistencePolicy.sanitizedReplayHeaders(
                replayHeaders
            )
        )
    }
}

public struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
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
