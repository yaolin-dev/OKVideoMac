import Foundation
import OKVideoCore

enum PlayerEpisodeNavigationResult: Equatable, Sendable {
    case available(PlayEpisode)
    case choice([PlayEpisode])
    case boundary
    case unavailable
    case preparing

    var uniqueEpisode: PlayEpisode? {
        if case .available(let episode) = self { return episode }
        return nil
    }

    var canNavigate: Bool {
        switch self {
        case .available, .choice: return true
        case .boundary, .unavailable, .preparing: return false
        }
    }
}

/// The presentation list keeps every upload. Navigation only needs the next
/// numbered group to be unique, not every group elsewhere in the same line.
struct PlayerEpisodeNavigationIndex: Sendable {
    private struct Position: Hashable, Comparable, Sendable {
        let season: Int?
        let episode: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.season != rhs.season { return (lhs.season ?? -1) < (rhs.season ?? -1) }
            return lhs.episode < rhs.episode
        }
    }
    private struct Group: Sendable {
        let position: Position
        let episodes: [PlayEpisode]
    }
    private var groupsByVersion: [String: [Group]] = [:]
    private var versionsByID: [String: [String]] = [:]

    init(episodes: [PlayEpisode], categoryName: String? = nil, confirmedVideoEpisodeID: String? = nil) {
        var versions: [String: [Position: [PlayEpisode]]] = [:]
        let semantics = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)
        let videoOverrides = PlayerEpisodeVideoEvidence.eligibleIDs(in: episodes,
            categoryName: categoryName, confirmedVideoEpisodeID: confirmedVideoEpisodeID)
        for (episode, value) in zip(episodes, semantics) {
            let contextual = value.form == .series && value.evidence == .contextual && value.role == .main
            guard !PlaybackResourceAnalyzer.isNonVideoResource(episode) || videoOverrides.contains(episode.id),
                  value.hasReliableEpisode || contextual,
                  let number = value.episode, value.endEpisode == nil else { continue }
            let version = value.versionLabels.joined(separator: "|")
            let position = Position(season: value.season, episode: number)
            versions[version, default: [:]][position, default: []].append(episode)
            versionsByID[episode.id, default: []].append(version)
        }
        for (version, positions) in versions {
            // Preserve the existing protection against borrowing an unknown
            // season from a numbered one, independently within each version.
            let hasSeason = positions.keys.contains { $0.season != nil }
            let lacksSeason = positions.keys.contains { $0.season == nil }
            guard !(hasSeason && lacksSeason) else { continue }
            groupsByVersion[version] = positions.keys.sorted().map {
                Group(position: $0, episodes: positions[$0]!)
            }
        }
    }

    func adjacent(to currentEpisodeID: String, offset: Int) -> PlayerEpisodeNavigationResult {
        guard offset == -1 || offset == 1,
              let versions = versionsByID[currentEpisodeID], versions.count == 1,
              let groups = groupsByVersion[versions[0]],
              let current = groups.firstIndex(where: { group in
                  group.episodes.contains { $0.id == currentEpisodeID }
              }) else { return .unavailable }
        let target = current + offset
        guard groups.indices.contains(target) else { return .boundary }
        let candidates = groups[target].episodes
        return candidates.count == 1 ? .available(candidates[0]) : .choice(candidates)
    }
}

/// A provider's display suffix is only a hint. A decoded moving video can
/// override an audio suffix locally, without rewriting resource/history IDs.
/// Siblings remain inferred candidates and must establish their own evidence
/// after loading; the evidence never crosses a playback request or source.
enum PlayerEpisodeVideoEvidence {
    static func eligibleIDs(in episodes: [PlayEpisode], categoryName: String?,
                            confirmedVideoEpisodeID: String?) -> Set<String> {
        guard let id = confirmedVideoEpisodeID,
              let current = episodes.first(where: { $0.id == id }),
              let family = mediaFamily(current, categoryName: categoryName) else { return [] }
        var eligible: Set<String> = [id]
        let members = episodes.filter { mediaFamily($0, categoryName: categoryName) == family }
        let numbers = Set(members.compactMap {
            PlaybackResourceAnalyzer.analyze($0, categoryName: categoryName).episode
        })
        let currentNumber = PlaybackResourceAnalyzer.analyze(current, categoryName: categoryName).episode!
        // Three consecutive, explicitly numbered files around the verified
        // member establish a family. An unrelated MP3 in a mixed list does not.
        let hasLocalRun = (-2...0).contains { offset in
            (0...2).allSatisfy { numbers.contains(currentNumber + offset + $0) }
        }
        if hasLocalRun { eligible.formUnion(members.map(\.id)) }
        return eligible
    }

    private static func mediaFamily(_ item: PlayEpisode, categoryName: String?) -> String? {
        let value = PlaybackResourceAnalyzer.analyze(item, categoryName: categoryName)
        guard value.hasReliableEpisode else { return nil }
        let raw = (item.name.removingPercentEncoding ?? item.name)
            .precomposedStringWithCompatibilityMapping.lowercased()
        let mediaExtension = #"\.(mp3|flac|aac|m4a|wav|ogg|mp4|mkv|m4v|mov|avi|ts|m2ts|flv|webm|m3u8)(?=$|[?#\s【\[])"#
        guard raw.range(of: mediaExtension, options: .regularExpression) != nil else { return nil }
        // Display-name compaction truncates video extensions and everything
        // after them. Remove only the extension first so E14.mp3 and E15.mp4
        // retain the same provider/title suffix when matching a numbered family.
        let name = PlaybackResourceAnalyzer.compactName(raw.replacingOccurrences(
            of: mediaExtension, with: "", options: .regularExpression))
        let token = #"(?i)(?<![a-z0-9])(?:s[0-9]{1,4}[ ._-]*)?ep?[ ._-]*[0-9]{1,5}|第?\s*[0-9零〇一二两三四五六七八九十百千万]+\s*[集话]"#
        let template = name.replacingOccurrences(of: token, with: "<episode>", options: .regularExpression)
        guard template != name else { return nil }
        return "\(value.season ?? -1)|\(value.versionLabels.joined(separator: "|"))|\(template)"
    }
}

struct PlayerEpisodeNavigationChoice: Identifiable, Equatable {
    let id = UUID()
    let sessionID: UUID
    let source: PlaySource
    let currentEpisodeID: String
    let offset: Int
    let episodes: [PlayEpisode]
}
