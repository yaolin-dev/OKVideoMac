import Foundation

public enum TMDBMediaType: String, Codable, Sendable { case movie, tv }

public struct TMDBReference: Codable, Equatable, Hashable, Sendable {
    public let type: TMDBMediaType
    public let id: Int
    public init(type: TMDBMediaType, id: Int) { self.type = type; self.id = id }
}

/// Optional enrichment only. These models never contain provider playback URLs.
public struct TMDBWork: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public var title: String?
    public var name: String?
    public var originalTitle: String?
    public var originalName: String?
    public var mediaType: String?
    public var adult: Bool?
    public var releaseDate: String?
    public var firstAirDate: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var originalLanguage: String?
    public var originCountry: [String]?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var runtime: Int?
    public var status: String?
    public var genres: [TMDBNamed]?
    public var numberOfSeasons: Int?
    public var seasons: [TMDBSeasonSummary]?
    public var images: TMDBImages?
    public var credits: TMDBCredits?
    public var aggregateCredits: TMDBCredits?
    public var alternativeTitles: TMDBAlternativeTitles?
    public var translations: TMDBTranslations?

    public var displayTitle: String { title?.nonBlank ?? name?.nonBlank ?? originalTitle?.nonBlank ?? originalName?.nonBlank ?? "" }
    public var year: Int? { Int(String((releaseDate ?? firstAirDate ?? "").prefix(4))) }
    public var cast: [TMDBPerson] { credits?.cast ?? aggregateCredits?.cast ?? [] }
    /// Aggregate TV credits store jobs separately; a writer/creator is not a director.
    public var directors: [TMDBPerson] {
        ((credits?.crew ?? []) + (aggregateCredits?.crew ?? [])).filter(\.isDirector)
    }
    public var aliases: [String] {
        var result = [title, name, originalTitle, originalName].compactMap { $0 }
        let alternatives = alternativeTitles?.titles ?? alternativeTitles?.results ?? []
        result.append(contentsOf: alternatives.map(\.title))
        for translation in translations?.translations ?? [] {
            if let title = translation.data.title { result.append(title) }
            if let name = translation.data.name { result.append(name) }
        }
        return result
    }
    public var chineseOverview: String? {
        if let overview = overview?.nonBlank, overview.range(of: "[\\p{Han}]", options: .regularExpression) != nil { return overview }
        return translations?.translations?.first(where: { $0.iso6391 == "zh" })?.data.overview?.nonBlank
    }
}

public struct TMDBNamed: Codable, Equatable, Sendable { public let id: Int; public let name: String }
public struct TMDBSeasonSummary: Codable, Equatable, Sendable {
    public let seasonNumber: Int
    public var name: String?
    public var airDate: String?
    public var episodeCount: Int?
}
public struct TMDBSeason: Codable, Equatable, Sendable {
    public let seasonNumber: Int
    public let episodes: [TMDBEpisode]
    public var airDate: String?
    public var name: String?
}
public struct TMDBEpisode: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let episodeNumber: Int
    public var seasonNumber: Int?
    public var name: String?
    public var overview: String?
    public var stillPath: String?
    public var airDate: String?
    public var runtime: Int?
}
public struct TMDBPerson: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public var originalName: String?
    public var alsoKnownAs: [String]?
    public var profilePath: String?
    public var character: String?
    public var job: String?
    public var roles: [TMDBRole]?
    public var jobs: [TMDBRole]?
    public var isDirector: Bool { job == "Director" || jobs?.contains(where: { $0.job == "Director" }) == true }
    public var role: String { character ?? roles?.first?.character ?? job ?? "" }
}
public struct TMDBRole: Codable, Equatable, Sendable { public var character: String?; public var job: String? }
public struct TMDBCredits: Codable, Equatable, Sendable {
    public var cast: [TMDBPerson]?
    public var crew: [TMDBPerson]?
}
public struct TMDBAlternativeTitles: Codable, Equatable, Sendable {
    public struct Title: Codable, Equatable, Sendable { public let title: String }
    public var titles: [Title]?
    public var results: [Title]?
}
public struct TMDBTranslations: Codable, Equatable, Sendable {
    public struct Translation: Codable, Equatable, Sendable {
        public struct Text: Codable, Equatable, Sendable { public var title: String?; public var name: String?; public var overview: String? }
        public var iso6391: String?
        public let data: Text
    }
    public var translations: [Translation]?
}
public struct TMDBImages: Codable, Equatable, Sendable {
    public var backdrops: [TMDBArtwork]?
    public var posters: [TMDBArtwork]?
    public var logos: [TMDBArtwork]?
}
public struct TMDBArtwork: Codable, Equatable, Sendable {
    public let filePath: String
    public var iso6391: String?
    public var width: Int?
    public var height: Int?
    public var voteAverage: Double?
}

public enum TMDBImageKind: String, Sendable { case backdrop, poster, logo, still, profile }
public struct TMDBImageConfiguration: Codable, Equatable, Sendable {
    public var backdropSizes: [String]?
    public var posterSizes: [String]?
    public var logoSizes: [String]?
    public var stillSizes: [String]?
    public var profileSizes: [String]?

    public func size(for kind: TMDBImageKind) -> String {
        let sizes: [String]?
        let target: Int
        switch kind {
        case .backdrop: sizes = backdropSizes; target = 1280
        case .poster: sizes = posterSizes; target = 500
        case .logo: sizes = logoSizes; target = 500
        case .still: sizes = stillSizes; target = 300
        case .profile: sizes = profileSizes; target = 185
        }
        let widths = (sizes ?? []).compactMap { $0.first == "w" ? Int($0.dropFirst()) : nil }.sorted()
        return widths.first(where: { $0 >= target }).map { "w\($0)" }
            ?? widths.last.map { "w\($0)" } ?? "original"
    }
}

extension String {
    fileprivate var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public struct TMDBPersonCredits: Codable, Sendable {
    public let id: Int
    public var cast: [TMDBWork]?
    public var crew: [TMDBWork]?
    public var works: [TMDBCandidate] {
        var seen = Set<TMDBReference>()
        return ((cast ?? []) + (crew ?? [])).compactMap { work in
            guard work.id > 0, work.adult != true, !work.displayTitle.isEmpty,
                  let type = work.mediaType.flatMap(TMDBMediaType.init(rawValue:)) else { return nil }
            let reference = TMDBReference(type: type, id: work.id)
            guard seen.insert(reference).inserted else { return nil }
            return TMDBCandidate(reference: reference, work: work)
        }.sorted { lhs, rhs in
            let a = lhs.work.releaseDate ?? lhs.work.firstAirDate ?? "", b = rhs.work.releaseDate ?? rhs.work.firstAirDate ?? ""
            return a == b ? lhs.id < rhs.id : a > b
        }
    }
}

/// Counts describe the unfiltered API response, never a locally shortened list.
public struct TMDBSearchPage: Codable, Sendable {
    public let results: [TMDBWork]
    public var page: Int?
    public var totalPages: Int?
    public var totalResults: Int?
    public init(results: [TMDBWork], page: Int? = nil, totalPages: Int? = nil, totalResults: Int? = nil) {
        self.results = results; self.page = page; self.totalPages = totalPages; self.totalResults = totalResults
    }
    public var isComplete: Bool? {
        guard let page, let totalPages, let totalResults else { return nil }
        return page == 1 && totalPages <= 1 && totalResults == results.count
    }
    public var isUnique: Bool { isComplete == true && totalResults == 1 }
}

public extension TMDBWork {
    func artworkPath(_ kind: TMDBImageKind) -> String? {
        let items: [TMDBArtwork]
        switch kind {
        case .backdrop: items = images?.backdrops ?? []
        case .poster: items = images?.posters ?? []
        case .logo: items = images?.logos ?? []
        default: items = []
        }
        func rank(_ image: TMDBArtwork) -> Int {
            if kind == .backdrop && image.iso6391 == nil { return 4 }
            switch image.iso6391 { case "zh": return 3; case "en": return 2; case nil: return 1; default: return 0 }
        }
        return items.sorted {
            if rank($0) != rank($1) { return rank($0) > rank($1) }
            if ($0.width ?? 0) != ($1.width ?? 0) { return ($0.width ?? 0) > ($1.width ?? 0) }
            if ($0.voteAverage ?? 0) != ($1.voteAverage ?? 0) { return ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            return $0.filePath < $1.filePath
        }.first?.filePath ?? (kind == .backdrop ? backdropPath : kind == .poster ? posterPath : nil)
    }
}

/// Names belong to one upstream person ID; never synthesize transliterations.
public struct TMDBPersonIdentity: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let alsoKnownAs: [String]?
}
