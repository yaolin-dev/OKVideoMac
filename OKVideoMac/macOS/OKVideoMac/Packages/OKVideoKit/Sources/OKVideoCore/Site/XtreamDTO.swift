import Foundation

public struct XtreamAuthenticationResponseDTO: Decodable, Sendable {
    public let userInfo: XtreamUserInfoDTO?
    public let serverInfo: XtreamServerInfoDTO?

    private enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

public struct XtreamUserInfoDTO: Decodable, Sendable {
    public let auth: Bool?
    public let status: String?
    public let message: String?
    public let expirationTimestamp: Int64?
    public let isTrial: Bool?
    public let activeConnections: Int?
    public let maxConnections: Int?
    public let allowedOutputFormats: [String]

    private enum CodingKeys: String, CodingKey {
        case auth, status, message
        case expirationTimestamp = "exp_date"
        case isTrial = "is_trial"
        case activeConnections = "active_cons"
        case maxConnections = "max_connections"
        case allowedOutputFormats = "allowed_output_formats"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        auth = try values.xtreamAuthenticationBoolIfPresent(.auth)
        status = values.xtreamStringIfPresent(.status)
        message = values.xtreamStringIfPresent(.message)
        expirationTimestamp = values.xtreamInt64IfPresent(.expirationTimestamp)
        isTrial = values.xtreamBoolIfPresent(.isTrial)
        activeConnections = values.xtreamIntIfPresent(.activeConnections)
        maxConnections = values.xtreamIntIfPresent(.maxConnections)
        allowedOutputFormats = values.xtreamStringArrayIfPresent(
            .allowedOutputFormats
        ) ?? []
    }
}

public struct XtreamServerInfoDTO: Decodable, Sendable {
    public let host: String?
    public let port: Int?
    public let httpsPort: Int?
    public let protocolName: String?
    public let timezone: String?
    public let timestamp: Int64?

    private enum CodingKeys: String, CodingKey {
        case host = "url"
        case port
        case httpsPort = "https_port"
        case protocolName = "server_protocol"
        case timezone
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = values.xtreamStringIfPresent(.host)
        port = values.xtreamIntIfPresent(.port)
        httpsPort = values.xtreamIntIfPresent(.httpsPort)
        protocolName = values.xtreamStringIfPresent(.protocolName)
        timezone = values.xtreamStringIfPresent(.timezone)
        timestamp = values.xtreamInt64IfPresent(.timestamp)
    }
}

public struct XtreamCategoryDTO: Decodable, Equatable, Sendable {
    public let categoryID: String?
    public let categoryName: String?
    public let parentID: String?

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case parentID = "parent_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = values.xtreamStringIfPresent(.categoryID)
        categoryName = values.xtreamStringIfPresent(.categoryName)
        parentID = values.xtreamStringIfPresent(.parentID)
    }
}

/// Metadata only. `direct_source` is intentionally not part of this DTO: Live
/// media URLs may only be materialized later by the native provider resolver.
public struct XtreamLiveStreamDTO: Decodable, Equatable, Sendable {
    public let epgChannelID: String?
    public let streamID: String?
    public let name: String?
    public let number: String?
    public let streamIcon: String?
    public let categoryID: String?
    public let containerExtension: String?
    public let tvArchive: Bool?
    public let tvArchiveDuration: Int?

    private enum CodingKeys: String, CodingKey {
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
        case epgChannelID = "epg_channel_id"
        case streamID = "stream_id"
        case name
        case number = "num"
        case streamIcon = "stream_icon"
        case categoryID = "category_id"
        case containerExtension = "container_extension"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // IDs accept string/integer scalars, not Boolean/object coercions.
        epgChannelID = values.xtreamStringIfPresent(.epgChannelID)
        streamID = (try? values.decode(String.self, forKey: .streamID))
            ?? (try? values.decode(Int64.self, forKey: .streamID)).map(String.init)
        categoryID = (try? values.decode(String.self, forKey: .categoryID))
            ?? (try? values.decode(Int64.self, forKey: .categoryID)).map(String.init)
        name = values.xtreamStringIfPresent(.name)
        number = values.xtreamStringIfPresent(.number)
        streamIcon = values.xtreamStringIfPresent(.streamIcon)
        containerExtension = values.xtreamStringIfPresent(.containerExtension)
        tvArchive = values.xtreamBoolIfPresent(.tvArchive)
        tvArchiveDuration = values.xtreamIntIfPresent(.tvArchiveDuration)
    }
}

public struct XtreamVODStreamDTO: Decodable, Equatable, Sendable {
    public let streamID: String?
    public let name: String?
    public let streamIcon: String?
    public let rating: Double?
    public let rating5Based: Double?
    public let added: String?
    public let categoryID: String?
    public let containerExtension: String?
    public let directSource: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case rating
        case rating5Based = "rating_5based"
        case added
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case directSource = "direct_source"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        streamID = values.xtreamStringIfPresent(.streamID)
        name = values.xtreamStringIfPresent(.name)
        streamIcon = values.xtreamStringIfPresent(.streamIcon)
        rating = values.xtreamDoubleIfPresent(.rating)
        rating5Based = values.xtreamDoubleIfPresent(.rating5Based)
        added = values.xtreamStringIfPresent(.added)
        categoryID = values.xtreamStringIfPresent(.categoryID)
        containerExtension = values.xtreamStringIfPresent(.containerExtension)
        directSource = values.xtreamStringIfPresent(.directSource)
    }
}

public struct XtreamVODInfoResponseDTO: Decodable, Sendable {
    public let info: XtreamVODInfoDTO?
    public let movieData: XtreamMovieDataDTO?

    private enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Some panels represent absent metadata as an empty PHP array. Preserve
        // the catalog/movie_data fallback without accepting malformed metadata.
        if let array = try? values.nestedUnkeyedContainer(forKey: .info), array.isAtEnd {
            info = nil
        } else {
            info = try values.decodeIfPresent(XtreamVODInfoDTO.self, forKey: .info)
        }
        movieData = try values.decodeIfPresent(XtreamMovieDataDTO.self, forKey: .movieData)
    }
}

public struct XtreamVODInfoDTO: Decodable, Equatable, Sendable {
    public let name: String?
    public let movieImage: String?
    public let backdropPaths: [String]
    public let plot: String?
    public let cast: String?
    public let director: String?
    public let genre: String?
    public let releaseDate: String?
    public let duration: String?
    public let durationSeconds: Int?
    public let rating: Double?
    public let youtubeTrailer: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case movieImage = "movie_image"
        case backdropPaths = "backdrop_path"
        case plot, cast, director, genre
        case releaseDate = "release_date"
        case duration
        case durationSeconds = "duration_secs"
        case rating
        case youtubeTrailer = "youtube_trailer"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = values.xtreamStringIfPresent(.name)
        movieImage = values.xtreamStringIfPresent(.movieImage)
        backdropPaths = values.xtreamStringArrayIfPresent(.backdropPaths) ?? []
        plot = values.xtreamStringIfPresent(.plot)
        cast = values.xtreamStringIfPresent(.cast)
        director = values.xtreamStringIfPresent(.director)
        genre = values.xtreamStringIfPresent(.genre)
        releaseDate = values.xtreamStringIfPresent(.releaseDate)
        duration = values.xtreamStringIfPresent(.duration)
        durationSeconds = values.xtreamIntIfPresent(.durationSeconds)
        rating = values.xtreamDoubleIfPresent(.rating)
        youtubeTrailer = values.xtreamStringIfPresent(.youtubeTrailer)
    }
}

public struct XtreamMovieDataDTO: Decodable, Equatable, Sendable {
    public let streamID: String?
    public let name: String?
    public let categoryID: String?
    public let containerExtension: String?
    public let directSource: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case directSource = "direct_source"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        streamID = values.xtreamStringIfPresent(.streamID)
        name = values.xtreamStringIfPresent(.name)
        categoryID = values.xtreamStringIfPresent(.categoryID)
        containerExtension = values.xtreamStringIfPresent(.containerExtension)
        directSource = values.xtreamStringIfPresent(.directSource)
    }
}

public struct XtreamSeriesDTO: Decodable, Equatable, Sendable {
    public let seriesID: String?
    public let name: String?
    public let cover: String?
    public let plot: String?
    public let cast: String?
    public let director: String?
    public let genre: String?
    public let releaseDate: String?
    public let rating: Double?
    public let backdropPaths: [String]
    public let youtubeTrailer: String?
    public let episodeRunTime: Int?
    public let categoryID: String?

    private enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case name, cover, plot, cast, director, genre
        case releaseDate = "release_date"
        case rating
        case backdropPaths = "backdrop_path"
        case youtubeTrailer = "youtube_trailer"
        case episodeRunTime = "episode_run_time"
        case categoryID = "category_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = values.xtreamStringIfPresent(.seriesID)
        name = values.xtreamStringIfPresent(.name)
        cover = values.xtreamStringIfPresent(.cover)
        plot = values.xtreamStringIfPresent(.plot)
        cast = values.xtreamStringIfPresent(.cast)
        director = values.xtreamStringIfPresent(.director)
        genre = values.xtreamStringIfPresent(.genre)
        releaseDate = values.xtreamStringIfPresent(.releaseDate)
        rating = values.xtreamDoubleIfPresent(.rating)
        backdropPaths = values.xtreamStringArrayIfPresent(.backdropPaths) ?? []
        youtubeTrailer = values.xtreamStringIfPresent(.youtubeTrailer)
        episodeRunTime = values.xtreamIntIfPresent(.episodeRunTime)
        categoryID = values.xtreamStringIfPresent(.categoryID)
    }
}

public struct XtreamSeriesInfoResponseDTO: Decodable, Sendable {
    public let info: XtreamSeriesDTO?
    public let seasons: [XtreamSeasonDTO]
    public let episodesBySeason: [Int: [XtreamEpisodeDTO]]

    private enum CodingKeys: String, CodingKey {
        case info, seasons, episodes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        info = try values.decodeIfPresent(XtreamSeriesDTO.self, forKey: .info)
        seasons = (try? values.decode([XtreamSeasonDTO].self, forKey: .seasons)) ?? []

        if let grouped = try? values.decode(
            [String: [XtreamEpisodeDTO]].self,
            forKey: .episodes
        ) {
            var result: [Int: [XtreamEpisodeDTO]] = [:]
            for (key, episodes) in grouped {
                let season = Int(key) ?? episodes.first?.seasonNumber ?? 0
                result[season, default: []].append(contentsOf: episodes)
            }
            episodesBySeason = result
        } else if let flat = try? values.decode(
            [XtreamEpisodeDTO].self,
            forKey: .episodes
        ) {
            episodesBySeason = Dictionary(grouping: flat) {
                $0.seasonNumber ?? 0
            }
        } else {
            episodesBySeason = [:]
        }
    }
}

public struct XtreamSeasonDTO: Decodable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let episodeCount: Int?
    public let seasonNumber: Int?
    public let airDate: String?
    public let cover: String?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case episodeCount = "episode_count"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case cover
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.xtreamStringIfPresent(.id)
        name = values.xtreamStringIfPresent(.name)
        episodeCount = values.xtreamIntIfPresent(.episodeCount)
        seasonNumber = values.xtreamIntIfPresent(.seasonNumber)
        airDate = values.xtreamStringIfPresent(.airDate)
        cover = values.xtreamStringIfPresent(.cover)
    }
}

public struct XtreamEpisodeDTO: Decodable, Equatable, Sendable {
    public let id: String?
    public let episodeNumber: Int?
    public let title: String?
    public let containerExtension: String?
    public let added: String?
    public let seasonNumber: Int?
    public let directSource: String?
    public let info: XtreamEpisodeInfoDTO?

    private enum CodingKeys: String, CodingKey {
        case id
        case episodeNumber = "episode_num"
        case title
        case containerExtension = "container_extension"
        case added
        case seasonNumber = "season"
        case directSource = "direct_source"
        case info
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.xtreamStringIfPresent(.id)
        episodeNumber = values.xtreamIntIfPresent(.episodeNumber)
        title = values.xtreamStringIfPresent(.title)
        containerExtension = values.xtreamStringIfPresent(.containerExtension)
        added = values.xtreamStringIfPresent(.added)
        seasonNumber = values.xtreamIntIfPresent(.seasonNumber)
        directSource = values.xtreamStringIfPresent(.directSource)
        info = try? values.decode(XtreamEpisodeInfoDTO.self, forKey: .info)
    }
}

public struct XtreamEpisodeInfoDTO: Decodable, Equatable, Sendable {
    public let duration: String?
    public let durationSeconds: Int?
    public let plot: String?
    public let releaseDate: String?
    public let rating: Double?
    public let movieImage: String?

    private enum CodingKeys: String, CodingKey {
        case duration
        case durationSeconds = "duration_secs"
        case plot
        case releaseDate = "release_date"
        case rating
        case movieImage = "movie_image"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        duration = values.xtreamStringIfPresent(.duration)
        durationSeconds = values.xtreamIntIfPresent(.durationSeconds)
        plot = values.xtreamStringIfPresent(.plot)
        releaseDate = values.xtreamStringIfPresent(.releaseDate)
        rating = values.xtreamDoubleIfPresent(.rating)
        movieImage = values.xtreamStringIfPresent(.movieImage)
    }
}

private struct XtreamFlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            self.value = string
        } else if let integer = try? value.decode(Int64.self) {
            self.value = String(integer)
        } else if let number = try? value.decode(Double.self) {
            self.value = String(number)
        } else if let bool = try? value.decode(Bool.self) {
            self.value = bool ? "true" : "false"
        } else {
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "Expected a string-compatible Xtream value"
            )
        }
    }
}

private struct XtreamFlexibleInt64: Decodable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            value = integer
        } else if let string = try? container.decode(String.self),
                  let integer = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = integer
        } else if let number = try? container.decode(Double.self),
                  number.isFinite,
                  number >= Double(Int64.min),
                  number <= Double(Int64.max) {
            value = Int64(number)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? 1 : 0
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an integer-compatible Xtream value"
            )
        }
    }
}

private struct XtreamFlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self), number.isFinite {
            value = number
        } else if let string = try? container.decode(String.self),
                  let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number.isFinite {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a number-compatible Xtream value"
            )
        }
    }
}

private struct XtreamFlexibleBool: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let integer = try? container.decode(Int64.self) {
            value = integer != 0
        } else if let string = try? container.decode(String.self) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": value = true
            case "0", "false", "no", "off", "": value = false
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a Boolean-compatible Xtream value"
                )
            }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a Boolean-compatible Xtream value"
            )
        }
    }
}

private struct XtreamAuthenticationBool: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
            return
        }
        if let integer = try? container.decode(Int64.self) {
            switch integer {
            case 1: value = true
            case 0: value = false
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an Xtream authentication value of 0 or 1"
                )
            }
            return
        }
        if let string = try? container.decode(String.self) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": value = true
            case "0", "false", "no", "off": value = false
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a Boolean-compatible Xtream authentication value"
                )
            }
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a Boolean-compatible Xtream authentication value"
        )
    }
}

private extension KeyedDecodingContainer {
    func xtreamStringIfPresent(_ key: Key) -> String? {
        (try? decodeIfPresent(XtreamFlexibleString.self, forKey: key))??.value
    }

    func xtreamInt64IfPresent(_ key: Key) -> Int64? {
        (try? decodeIfPresent(XtreamFlexibleInt64.self, forKey: key))??.value
    }

    func xtreamIntIfPresent(_ key: Key) -> Int? {
        guard let value = xtreamInt64IfPresent(key),
              value >= Int64(Int.min), value <= Int64(Int.max) else {
            return nil
        }
        return Int(value)
    }

    func xtreamDoubleIfPresent(_ key: Key) -> Double? {
        (try? decodeIfPresent(XtreamFlexibleDouble.self, forKey: key))??.value
    }

    func xtreamBoolIfPresent(_ key: Key) -> Bool? {
        (try? decodeIfPresent(XtreamFlexibleBool.self, forKey: key))??.value
    }

    func xtreamAuthenticationBoolIfPresent(_ key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        return try decode(XtreamAuthenticationBool.self, forKey: key).value
    }

    func xtreamStringArrayIfPresent(_ key: Key) -> [String]? {
        if let values = try? decodeIfPresent(
            [XtreamFlexibleString].self,
            forKey: key
        ) {
            return values.map(\.value)
        }
        return xtreamStringIfPresent(key).map { [$0] }
    }
}
