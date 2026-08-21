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

public struct HistoryPlaybackReference: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var sourceIdentity: String
    public var resourceIdentity: String
    /// Only non-sensitive request context may be persisted here. Cookie and
    /// Authorization are intentionally reacquired from the provider.
    public var replayHeaders: [String: String]

    public init(
        version: Int = currentVersion,
        sourceIdentity: String,
        resourceIdentity: String,
        replayHeaders: [String: String] = [:]
    ) {
        self.version = version
        self.sourceIdentity = sourceIdentity
        self.resourceIdentity = resourceIdentity
        self.replayHeaders = replayHeaders
    }
}

public struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String {
        "\(configurationID?.uuidString.lowercased() ?? "legacy")::\(siteKey)::\(videoID)"
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
        self.sourceName = sourceName
        self.episodeName = episodeName
        self.episodeReference = episodeReference
        self.mediaReference = mediaReference
        self.playbackReference = playbackReference
        self.position = max(0, position)
        self.duration = max(0, duration)
        self.watchedAt = watchedAt
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
    func history() async throws -> [HistoryRecord]
    @discardableResult
    func deleteHistory(
        configurationID: UUID?,
        siteKey: String,
        videoID: String
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
