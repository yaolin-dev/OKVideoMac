import Foundation
import OKVideoCore

enum PlayerEpisodeNavigationConfirmation: Equatable, Sendable {
    case gap(expected: Int, available: Int)
    case seasonChange(season: Int, episode: Int)
    case editionChange

    var message: String {
        switch self {
        case .gap(let expected, let available):
            return L10n.string("player.queue.gap", fallback: "Episode %d is unavailable. Select a resource to continue at episode %d.", expected, available)
        case .seasonChange(let season, let episode):
            return L10n.string("player.queue.season-change", fallback: "Select a resource to continue at season %d, episode %d.", season, episode)
        case .editionChange:
            return L10n.string("player.queue.edition-change", fallback: "The next episode uses a different language or edition. Select a resource to continue.")
        }
    }
}

enum PlayerEpisodeNavigationResult: Equatable, Sendable {
    case available(PlayEpisode)
    case choice([PlayEpisode])
    case confirmation([PlayEpisode], PlayerEpisodeNavigationConfirmation)
    case boundary
    case unavailable
    case preparing

    var uniqueEpisode: PlayEpisode? {
        if case .available(let episode) = self { return episode }
        return nil
    }
    var candidates: [PlayEpisode]? {
        switch self {
        case .choice(let items), .confirmation(let items, _): return items
        default: return nil
        }
    }
    var confirmation: PlayerEpisodeNavigationConfirmation? {
        if case .confirmation(_, let reason) = self { return reason }
        return nil
    }
    var canNavigate: Bool {
        switch self {
        case .available, .choice, .confirmation: return true
        case .boundary, .unavailable, .preparing: return false
        }
    }
}

/// Find the adjacent logical episode before choosing its encode. Quality labels
/// are preferences, never separate queues that can hide or skip an episode.
struct PlayerEpisodeNavigationIndex: Sendable {
    private struct Position: Hashable, Comparable, Sendable {
        let season: Int?
        let episode: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.season != rhs.season { return (lhs.season ?? -1) < (rhs.season ?? -1) }
            return lhs.episode < rhs.episode
        }
    }
    private struct Candidate: Sendable {
        let episode: PlayEpisode
        let version: [String]
        var edition: [String] { version.filter { !["4K", "1080p", "720p", "HDR", "SDR", "杜比视界"].contains($0) } }
    }
    private struct Group: Sendable {
        let position: Position
        let candidates: [Candidate]
    }
    private var groups: [Group] = []
    private var positionsByID: [String: Position] = [:]

    init(episodes: [PlayEpisode], categoryName: String? = nil, confirmedVideoEpisodeID: String? = nil) {
        var positions: [Position: [Candidate]] = [:]
        let semantics = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)
        let videoOverrides = PlayerEpisodeVideoEvidence.eligibleIDs(in: episodes,
            categoryName: categoryName, confirmedVideoEpisodeID: confirmedVideoEpisodeID)
        for (episode, value) in zip(episodes, semantics) {
            guard !PlaybackResourceAnalyzer.isNonVideoResource(episode) || videoOverrides.contains(episode.id),
                  value.hasLocalEpisode, let number = value.episode else { continue }
            let position = Position(season: value.season, episode: number)
            positions[position, default: []].append(Candidate(episode: episode, version: value.versionLabels))
            positionsByID[episode.id] = position
        }
        // An unnumbered season must never be borrowed from a numbered season.
        guard !(positions.keys.contains { $0.season == nil } && positions.keys.contains { $0.season != nil }) else { return }
        groups = positions.keys.sorted().map { Group(position: $0, candidates: positions[$0]!) }
    }

    func adjacent(to currentEpisodeID: String, offset: Int) -> PlayerEpisodeNavigationResult {
        guard offset == -1 || offset == 1,
              let position = positionsByID[currentEpisodeID],
              let current = groups.firstIndex(where: { $0.position == position }),
              let playing = groups[current].candidates.first(where: { $0.episode.id == currentEpisodeID }) else { return .unavailable }
        let target = current + offset
        guard groups.indices.contains(target) else { return .boundary }
        let group = groups[target]
        let sameVersion = group.candidates.filter { $0.version == playing.version }
        let sameEdition = group.candidates.filter { $0.edition == playing.edition }
        let candidates = !sameVersion.isEmpty ? sameVersion : !sameEdition.isEmpty ? sameEdition : group.candidates
        let episodes = candidates.map(\.episode)
        if group.position.season != position.season {
            return .confirmation(episodes, .seasonChange(season: group.position.season!, episode: group.position.episode))
        }
        if group.position.episode != position.episode + offset {
            return .confirmation(episodes, .gap(expected: position.episode + offset, available: group.position.episode))
        }
        if sameEdition.isEmpty { return .confirmation(episodes, .editionChange) }
        return episodes.count == 1 ? .available(episodes[0]) : .choice(episodes)
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
    var confirmation: PlayerEpisodeNavigationConfirmation? = nil
}
