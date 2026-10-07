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

    init(episodes: [PlayEpisode], categoryName: String? = nil) {
        var versions: [String: [Position: [PlayEpisode]]] = [:]
        let semantics = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)
        for (episode, value) in zip(episodes, semantics) {
            let contextual = value.form == .series && value.evidence == .contextual && value.role == .main
            guard !PlaybackResourceAnalyzer.isNonVideoResource(episode),
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

struct PlayerEpisodeNavigationChoice: Identifiable, Equatable {
    let id = UUID()
    let sessionID: UUID
    let source: PlaySource
    let currentEpisodeID: String
    let offset: Int
    let episodes: [PlayEpisode]
}
