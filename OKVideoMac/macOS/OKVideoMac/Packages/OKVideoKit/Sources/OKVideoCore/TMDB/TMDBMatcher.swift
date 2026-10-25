import Foundation

public struct TMDBMatchInput: Equatable, Sendable {
    public let title: String
    public let parsedTitle: TMDBParsedTitle
    public let yearHints: Set<Int>
    public let year: Int?
    public let type: TMDBMediaType?
    public let season: Int?
    public let people: Set<String>
    public let directors: Set<String>
    public let principalActors: [String]
    public let canInferTypeFromCast: Bool
    public let titleWithoutAttachedYear: String?
    public let hasConflict: Bool

    public init(detail: VideoDetail, fallbackSummary: VideoSummary? = nil) {
        // Only reuse discovery fields for this exact provider item. Detail values
        // win; a redirect or renamed identity must not inherit another work's year.
        let fallback = fallbackSummary.flatMap { summary -> VideoSummary? in
            guard summary.siteKey == detail.summary.siteKey,
                  summary.videoID == detail.summary.videoID,
                  TMDBTitleNormalizer.key(summary.title) == TMDBTitleNormalizer.key(detail.summary.title)
            else { return nil }
            return summary
        }
        func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        title = detail.summary.title
        let rawYear = nonempty(detail.summary.year) ?? nonempty(fallback?.year) ?? ""
        parsedTitle = TMDBParsedTitle(title)
        let sourceYear = rawYear.range(of: #"^(18|19|20)[0-9]{2}$"#, options: .regularExpression) != nil ? Int(rawYear) : nil
        yearHints = parsedTitle.years.union(sourceYear.map { [$0] } ?? [])
        year = sourceYear ?? (parsedTitle.years.count == 1 ? parsedTitle.years.first : nil)
        titleWithoutAttachedYear = TMDBTitleNormalizer.removingAttachedYear(title, year: year)
        let hints = PlaybackResourceAnalyzer.explicitSeasons(in: title)
        season = hints.count == 1 ? hints.first : nil
        let category = nonempty(detail.summary.categoryName) ?? nonempty(fallback?.categoryName)
        let categoryEvidence = Self.categoryEvidence(category)
        // Xtream supplies protocol-level movie/series metadata even when its
        // operator-defined category is simply "Drama" or "4K". Episode labels
        // and resource counts alone are not evidence (movies can have parts).
        let forms = Set(detail.playSources.flatMap(\.episodes).compactMap { $0.metadata?.form }
            .filter { $0 != .unknown })
        var types = categoryEvidence.types
        if forms.contains(.movie) { types.insert(.movie) }
        if forms.contains(.series) { types.insert(.tv) }
        if !hints.isEmpty { types.insert(.tv) }
        if let hint = parsedTitle.typeHint { types.insert(hint) }
        type = types.count == 1 ? types.first : nil
        canInferTypeFromCast = types.isEmpty && !categoryEvidence.blocksInference && !forms.contains(.programme)
        hasConflict = hints.count > 1 || types.count > 1
            || (forms.contains(.programme) && !types.isEmpty)
        let actorNames = Self.personNames(nonempty(detail.actors) ?? nonempty(detail.summary.identityActors) ?? fallback?.identityActors)
        directors = Set(Self.personNames(nonempty(detail.director) ?? nonempty(detail.summary.identityDirector) ?? fallback?.identityDirector))
        people = directors.union(actorNames)
        principalActors = Array(actorNames.prefix(8))
    }

    /// TVBox commonly separates Chinese credits with spaces, including full-width
    /// spaces. Split only unambiguous Han-name lists; a Western person's given
    /// and family names must remain one identity, never two corroborating actors.
    private static func personNames(_ raw: String?) -> [String] {
        let value = (raw ?? "").precomposedStringWithCompatibilityMapping
        let names = value.components(separatedBy: CharacterSet(charactersIn: "/,，、;；|\r\n"))
            .flatMap { chunk -> [String] in
                let words = chunk.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                func hanName(_ word: String) -> Bool {
                    word.range(of: #"^[\p{Han}][\p{Han}·•・]*[\p{Han}]$"#, options: .regularExpression) != nil
                }
                guard words.count > 1, words.contains(where: hanName) else { return [chunk] }
                var result: [String] = [], latin: [String] = []
                for word in words {
                    if hanName(word) {
                        if !latin.isEmpty { result.append(latin.joined(separator: " ")); latin = [] }
                        result.append(word)
                    } else { latin.append(word) }
                }
                if !latin.isEmpty { result.append(latin.joined(separator: " ")) }
                return result
            }
        var seen = Set<String>()
        return names.map(TMDBTitleNormalizer.key).filter {
            $0.count >= 2 && !["未知", "暂无", "不详", "unknown"].contains($0) && seen.insert($0).inserted
        }
    }

    /// TMDB-specific classification: do not change the source's playback or
    /// history semantics while recognizing TVBox catalogue vocabulary.
    private static func categoryEvidence(_ raw: String?) -> (types: Set<TMDBMediaType>, blocksInference: Bool) {
        let value = (raw ?? "").precomposedStringWithCompatibilityMapping
            .applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)?.lowercased() ?? ""
        let movie = ["电影", "movie", "film", "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "惊悚片",
                     "剧情片", "战争片", "犯罪片", "悬疑片", "动画片", "冒险片", "奇幻片", "纪录片"]
        let television = ["电视剧", "连续剧", "剧集", "短剧", "国产剧", "大陆剧", "内地剧", "欧美剧",
                          "美剧", "英剧", "港剧", "香港剧", "台剧", "台湾剧", "港台剧", "韩剧", "韩国剧",
                          "日剧", "日本剧", "日韩剧", "泰剧", "泰国剧", "海外剧", "其他剧", "series", "tv show"]
        var types = Set<TMDBMediaType>()
        if movie.contains(where: value.contains) { types.insert(.movie) }
        if television.contains(where: value.contains) { types.insert(.tv) }
        // Animation/documentary without an explicit form can be either a
        // movie or a series; retain the independent cast/year checks for them.
        let blocked = ["综艺", "节目", "音乐", "演唱会", "直播", "体育", "variety", "music", "live", "sport"]
            .contains(where: value.contains)
        return (types, blocked)
    }

    public var canPrepareFromSummary: Bool {
        !hasConflict && titleWithoutAttachedYear == nil
            && ((year != nil && type != nil) || (canInferTypeFromCast && (principalActors.count >= 2 || (year != nil && !directors.isEmpty))))
    }

    public var searchNames: [String] {
        let original = TMDBTitleNormalizer.searchNames(title)
        guard let titleWithoutAttachedYear else { return original }
        // Search both identities: a year-like number can also belong to a title.
        return Array(([titleWithoutAttachedYear] + original).prefix(3))
    }
}

public enum TMDBTitleNormalizer {
    /// Only a Chinese title followed by the independently supplied release year.
    /// Never derive a release year from a title or strip sequel/numeric titles.
    public static func removingAttachedYear(_ raw: String, year: Int?) -> String? {
        guard let year else { return nil }
        let value = clean(raw)
        guard let range = value.range(of: #"(?<=\p{Han})(?:18|19|20)[0-9]{2}$"#, options: .regularExpression),
              Int(value[range]) == year else { return nil }
        let title = String(value[..<range.lowerBound])
        return title.count >= 2 ? title : nil
    }
    public static func key(_ raw: String) -> String {
        let value = raw.precomposedStringWithCompatibilityMapping
            .applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? raw
        return value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    public static func clean(_ raw: String) -> String {
        TMDBParsedTitle(raw).workTitle
    }

    public static func searchNames(_ raw: String) -> [String] {
        let cleaned = clean(raw)
        var candidates = [cleaned]
        // Separate bilingual aliases only when the two scripts give evidence
        // of alternative names; keep ordinary English titles such as Face/Off.
        if cleaned.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
           cleaned.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "/()（）"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if parts.count > 1 { candidates = parts + [cleaned] }
        }
        if let simplified = cleaned.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false), simplified != cleaned {
            candidates.insert(simplified, at: min(1, candidates.count))
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(2).map { $0 }
    }
}

public struct TMDBCandidate: Codable, Equatable, Identifiable, Sendable {
    public let reference: TMDBReference
    public let work: TMDBWork
    public var id: String { "\(reference.type.rawValue):\(reference.id)" }
    public init(reference: TMDBReference, work: TMDBWork) { self.reference = reference; self.work = work }
}

public enum TMDBMatchPolicy: String, Codable, Sendable {
    case strict, relaxed
}

public enum TMDBMatcher {
    /// Only use after a complete, unfiltered cross-media search proves uniqueness.
    /// Missing translated credits are uncertainty; explicit contradictions still veto.
    public static func acceptsRelaxed(_ candidate: TMDBCandidate, input: TMDBMatchInput) -> Bool {
        let evidence = assess(candidate, input: input)
        return evidence.exactTitle && !evidence.conflict && input.titleWithoutAttachedYear == nil
            && (input.type != nil || input.canInferTypeFromCast)
    }

    public struct Evidence: Equatable, Sendable {
        public let exactTitle: Bool
        public let matchingYear: Bool
        public let matchingType: Bool
        public let corroboratedCast: Bool
        public let corroboratedDirector: Bool
        /// Year/type/season conflicts cannot be repaired by a person's aliases.
        let identityConflict: Bool
        public var requiresCompleteSearch: Bool { !matchingType && !corroboratedCast && corroboratedDirector }
        public let identitySupported: Bool
        public let conflict: Bool
        public let hasYearEvidence: Bool
        public let unresolvedDirector: Bool
        public let rank: Int
        public var acceptsAutomatically: Bool { exactTitle && (matchingYear || (!hasYearEvidence && corroboratedCast)) && identitySupported && !conflict && (!unresolvedDirector || corroboratedCast) }
    }

    public static func assess(_ candidate: TMDBCandidate, input: TMDBMatchInput) -> Evidence {
        let names = input.searchNames
        let bilingual = names.count == 2 && names.contains { $0.range(of: #"\p{Han}"#, options: .regularExpression) != nil }
            && names.contains { $0.range(of: #"^[A-Za-z][A-Za-z0-9 .’'&:!?_-]*$"#, options: .regularExpression) != nil }
        let identityNames = input.parsedTitle.unknown.isEmpty || bilingual ? names : [input.parsedTitle.workTitle]
        let keys = Set(identityNames.map(TMDBTitleNormalizer.key))
        let aliases = candidate.work.aliases.map(TMDBTitleNormalizer.key)
        let exact = bilingual ? keys.allSatisfy { !$0.isEmpty && aliases.contains($0) }
            : aliases.contains { !$0.isEmpty && keys.contains($0) }
        let typeMatches = input.type == candidate.reference.type
        var conflict = input.hasConflict || (input.type != nil && !typeMatches)
        var years = [candidate.work.year].compactMap { $0 }
        if candidate.reference.type == .tv, let season = input.season {
            if let seasons = candidate.work.seasons {
                if let selected = seasons.first(where: { $0.seasonNumber == season }) {
                    if let year = Int(String((selected.airDate ?? "").prefix(4))) { years.append(year) }
                } else { conflict = true }
            }
        }
        let yearMatches = !input.yearHints.isEmpty && input.yearHints.isSubset(of: Set(years))
        // Search results lack season dates. A TV season-year mismatch must be
        // checked against detail before it can exclude a candidate.
        if !input.yearHints.isEmpty, !years.isEmpty, !yearMatches,
           candidate.reference.type == .movie || input.season == nil || candidate.work.seasons != nil {
            conflict = true
        }
        let castNames = Set(candidate.work.cast.map { TMDBTitleNormalizer.key($0.name) })
        // Match names exactly (including script normalization), not transliteration
        // or fuzzy similarity. Duplicate credits for one person count only once.
        let principals = Set(input.principalActors)
        let leads = Set(input.principalActors.prefix(3))
        var matchedIDs = Set<Int>()
        var matchedNames = Set<String>()
        var leadMatched = false
        for person in candidate.work.cast.prefix(10) {
            let names = Set(([person.name, person.originalName].compactMap { $0 } + (person.alsoKnownAs ?? [])).map(TMDBTitleNormalizer.key))
            let matched = names.intersection(principals)
            if !matched.isEmpty { matchedIDs.insert(person.id); matchedNames.formUnion(matched) }
            if !names.isDisjoint(with: leads) { leadMatched = true }
        }
        let strongCast = matchedIDs.count >= 2 && matchedNames.count >= 2 && leadMatched
        let originalKeys = Set(TMDBTitleNormalizer.searchNames(input.title).map(TMDBTitleNormalizer.key))
        let needsYearRemoval = input.titleWithoutAttachedYear != nil && !aliases.contains(where: originalKeys.contains)
        let identityConflict = conflict
        let crew = candidate.work.directors.filter { $0.id > 0 }
        func directorNames(_ person: TMDBPerson) -> Set<String> {
            Set(([person.name, person.originalName].compactMap { $0 } + (person.alsoKnownAs ?? [])).map(TMDBTitleNormalizer.key))
        }
        let directors = Set(crew.flatMap { directorNames($0) })
        // Every supplied director must identify exactly one credited TMDB person.
        // Shared aliases, partial names and guessed transliterations cannot confirm a work.
        let verifiedDirector = !input.directors.isEmpty && input.directors.allSatisfy { name in
            Set(crew.filter { directorNames($0).contains(name) }.map(\.id)).count == 1
        }
        // Partial director credits are missing evidence, not an affirmative conflict.
        // The new director-only path still requires every source name above.
        let directorMismatch = !input.directors.isEmpty && !directors.isEmpty && input.directors.isDisjoint(with: directors)
        // A missing form may be supported by a verified director only together
        // with an exact release year. This never repairs title/year/type conflicts
        // or the separate title-with-attached-year exception.
        let directorSupportsIdentity = input.canInferTypeFromCast && yearMatches && verifiedDirector && !needsYearRemoval
        let identitySupported = (typeMatches || (input.canInferTypeFromCast && strongCast) || directorSupportsIdentity)
            && (!needsYearRemoval || strongCast)
        func latin(_ value: String) -> Bool { value.range(of: #"^[\p{Latin}0-9]+$"#, options: .regularExpression) != nil }
        let comparable = crew.allSatisfy { person in
            let original = TMDBTitleNormalizer.key(person.originalName ?? person.name)
            return input.directors.allSatisfy { latin($0) == latin(original) }
        }
        if directorMismatch && comparable { conflict = true }
        let unresolvedDirector = directorMismatch && !comparable
        let peopleMatch = !input.people.intersection(castNames.union(directors)).isEmpty
        let similarity = keys.map { key in aliases.map { similarityScore(key, $0) }.max() ?? 0 }.max() ?? 0
        let rank = (exact ? 60 : similarity) + (yearMatches ? 20 : 0) + (typeMatches ? 15 : 0) + (strongCast ? 10 : peopleMatch ? 5 : 0) - (conflict ? 100 : 0)
        return Evidence(exactTitle: exact, matchingYear: yearMatches, matchingType: typeMatches, corroboratedCast: strongCast, corroboratedDirector: verifiedDirector, identityConflict: identityConflict, identitySupported: identitySupported, conflict: conflict, hasYearEvidence: !input.yearHints.isEmpty, unresolvedDirector: unresolvedDirector, rank: rank)
    }

    public static func automaticMatch(_ candidates: [TMDBCandidate], input: TMDBMatchInput) -> TMDBCandidate? {
        let accepted = candidates.filter {
            let evidence = assess($0, input: input)
            return evidence.acceptsAutomatically
        }
        // An unverified exact-title rival with missing year/type data is still
        // ambiguous; popularity, input order and poster quality cannot settle it.
        guard accepted.count == 1, let winner = accepted.first else { return nil }
        let rival = candidates.contains { candidate in
            guard candidate.reference != winner.reference else { return false }
            let evidence = assess(candidate, input: input)
            return evidence.exactTitle && !evidence.conflict
        }
        return rival ? nil : winner
    }

    private static func similarityScore(_ a: String, _ b: String) -> Int {
        let left = Set(a), right = Set(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Int(40 * Double(left.intersection(right).count * 2) / Double(left.count + right.count))
    }
}

public enum TMDBEpisodeMapper {
    /// Work identity is already verified. This context only scopes episode artwork.
    /// Explicit page/manual season wins over a noisy individual resource; the
    /// resource is checked separately and cannot invalidate its siblings.
    public static func season(work: TMDBWork, input: TMDBMatchInput, source: PlaySource?, manual: Int? = nil) -> Int? {
        let seasons = work.seasons ?? []
        func valid(_ number: Int) -> Int? { seasons.contains { $0.seasonNumber == number } ? number : nil }
        if let manual { return valid(manual) }
        let page = PlaybackResourceAnalyzer.explicitSeasons(in: input.title)
        let lineHints = PlaybackResourceAnalyzer.explicitSeasons(in: source?.name ?? "")
        if !page.isEmpty && !lineHints.isEmpty && page != lineHints { return nil }
        if page.count == 1 { return valid(page.first!) }
        if page.count > 1 { return nil }
        let line = PlaybackResourceAnalyzer.explicitSeasons(in: source?.name ?? "")
        if line.count == 1 { return valid(line.first!) }
        if line.count > 1 { return nil }
        // Do not filter by episode_count: an announced second season still
        // makes the series multi-season, even before its episodes are listed.
        let regular = seasons.filter { $0.seasonNumber > 0 }
        if regular.count == 1 && (work.numberOfSeasons == nil || work.numberOfSeasons == 1) { return regular.first?.seasonNumber }
        return nil
    }

    public static func seasonNumbers(work: TMDBWork, input: TMDBMatchInput, source: PlaySource?, manual: Int? = nil) -> [Int] {
        if let number = season(work: work, input: input, source: source, manual: manual) {
            let hasSpecials = (work.seasons ?? []).contains { $0.seasonNumber == 0 }
            let explicitSpecials = (source?.episodes ?? []).contains { item in
                let value = PlaybackResourceAnalyzer.analyze(item, categoryName: "电视剧")
                return value.evidence != .conflict && (item.metadata?.season ?? value.season) == 0
            }
            return number != 0 && hasSpecials && explicitSpecials ? [number, 0] : [number]
        }
        guard manual == nil, PlaybackResourceAnalyzer.explicitSeasons(in: input.title).isEmpty,
              PlaybackResourceAnalyzer.explicitSeasons(in: source?.name ?? "").isEmpty else { return [] }
        let valid = Set((work.seasons ?? []).map(\.seasonNumber))
        var seen = Set<Int>()
        return (source?.episodes ?? []).compactMap { item in
            let value = PlaybackResourceAnalyzer.analyze(item, categoryName: "电视剧")
            guard value.evidence != .conflict, let number = item.metadata?.season ?? value.season,
                  valid.contains(number), seen.insert(number).inserted else { return nil }
            return number
        }
    }

    /// Indices are provider indices, never inferred episode numbers. Multiple
    /// encodes may share artwork while keeping distinct playback identities.
    public static func episodes(_ sources: [PlayEpisode], category: String?, season: TMDBSeason) -> [Int: TMDBEpisode] {
        let form = PlaybackContentForm.category(category)
        guard form != .movie && form != .programme else { return [:] }
        let parsed = sources.map { PlaybackResourceAnalyzer.analyze($0, categoryName: "电视剧") }
        let maximum = season.episodes.map(\.episodeNumber).max() ?? 0
        let ordinary = parsed.filter { $0.role == .main && $0.endEpisode == nil && ($0.season == nil || $0.season == season.seasonNumber) }.compactMap(\.episode)
        let outOfRange = ordinary.filter { $0 > maximum }.count
        // Systematic alternate numbering (e.g. 94 parts for 47 episodes) is
        // different from one bad resource. Do not silently map its first half.
        if outOfRange >= 2 && outOfRange * 4 > ordinary.count { return [:] }
        var result = Dictionary(uniqueKeysWithValues: sources.enumerated().compactMap { index, item in
            episode(item, category: category, season: season, allowExplicitParent: true).map { (index, $0) }
        })
        // Shared descriptive labels such as "(2026) 英剧 01" or "X-剧名 01"
        // provide episode numbering only after series/season verification.
        // Require at least two distinct numbers with the exact same prefix.
        let regex = try! NSRegularExpression(pattern: #"^(.+?)[ _-]+([0-9]{1,3})$"#)
        var groups: [String: [(Int, Int)]] = [:]
        for (index, item) in sources.enumerated() where result[index] == nil {
            let value = parsed[index]
            guard value.role == .main, value.evidence != .conflict, value.endEpisode == nil, value.date == nil,
                  PlaybackResourceAnalyzer.explicitSeasons(in: item.name).allSatisfy({ $0 == season.seasonNumber }),
                  !["番外", "花絮", "预告", "特别篇", "特辑", "彩蛋", "幕后"].contains(where: item.name.contains) else { continue }
            let name = PlaybackResourceAnalyzer.compactName(item.name)
            guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let prefix = Range(match.range(at: 1), in: name), let digits = Range(match.range(at: 2), in: name),
                  let number = Int(name[digits]), number > 0 else { continue }
            groups[String(name[prefix]), default: []].append((index, number))
        }
        for values in groups.values where Set(values.map { $0.1 }).count >= 2 {
            for (index, number) in values {
                if var episode = season.episodes.first(where: { $0.episodeNumber == number }) { episode.seasonNumber = season.seasonNumber; result[index] = episode }
            }
        }
        return result
    }

    public static func episode(_ source: PlayEpisode, category: String?, season: TMDBSeason, allowExplicitParent: Bool = false) -> TMDBEpisode? {
        let form = PlaybackContentForm.category(category)
        guard form != .movie && form != .programme else { return nil }
        let value = PlaybackResourceAnalyzer.analyze(source, categoryName: "电视剧")
        guard PlaybackResourceAnalyzer.explicitSeasons(in: source.name).allSatisfy({ $0 == season.seasonNumber }),
              !["番外", "花絮", "预告", "特别篇", "特辑", "彩蛋", "幕后"].contains(where: source.name.contains) || value.season == 0 else { return nil }
        guard value.evidence != .conflict, value.endEpisode == nil, value.issue == nil, value.date == nil,
              (value.role != .part || allowExplicitParent),
              value.season == nil || value.season == season.seasonNumber else { return nil }
        if value.role == .bonus && value.season != 0 { return nil }
        var number: Int?
        if value.evidence == .explicit || value.evidence == .structured { number = value.episode }
        // A complete numeric label has meaning only inside a verified series
        // and season. Do not scan arbitrary numbers from descriptive filenames.
        if number == nil, value.role == .main {
            let name = PlaybackResourceAnalyzer.compactName(source.name).precomposedStringWithCompatibilityMapping
            if name.range(of: #"^[0-9]{1,4}(?:[\s_]+(?:480[pP]|720[pP]|1080[pP]|2160[pP]|4320[pP]|[248][kK]))?$"#, options: .regularExpression) != nil {
                number = Int(name.prefix(while: { $0.isNumber }))
            }
        }
        guard let number, number > 0 else { return nil }
        guard var matched = season.episodes.first(where: { $0.episodeNumber == number }) else { return nil }
        matched.seasonNumber = season.seasonNumber
        return matched
    }
}
