import Foundation

public enum PlaybackContentForm: String, Codable, Sendable {
    case movie, series, programme, unknown

    public static func category(_ value: String?) -> Self {
        let text = (value ?? "").lowercased()
        let movie = ["电影", "movie", "film"].contains { text.contains($0) }
        let series = ["电视剧", "连续剧", "剧集", "短剧", "美剧", "韩剧", "日剧", "series", "tv show"].contains { text.contains($0) }
        if movie && series { return .unknown }
        if movie { return .movie }
        if series { return .series }
        if ["综艺", "节目", "variety"].contains(where: text.contains) { return .programme }
        return .unknown
    }
}

/// Provider-declared metadata, never part of an episode's stable identity.
public struct PlaybackEpisodeMetadata: Codable, Equatable, Hashable, Sendable {
    public var form: PlaybackContentForm
    public var season: Int?
    public var episode: Int?
    public init(form: PlaybackContentForm, season: Int? = nil, episode: Int? = nil) {
        self.form = form; self.season = season; self.episode = episode
    }
}

public struct PlaybackResourceSemantics: Equatable, Sendable {
    public enum Evidence: String, Sendable { case none, contextual, explicit, structured, conflict }
    public enum Role: String, Codable, Sendable { case main, bonus, part }
    public var form: PlaybackContentForm
    public var name: String
    public var season: Int?
    public var episode: Int?
    public var endEpisode: Int?
    public var issue: Int?
    public var date: String?
    public var unit = "集"
    public var role: Role = .main
    public var evidence: Evidence = .none
    public var finale = false
    public var versionLabels: [String] = []
    public var hasReliableEpisode: Bool {
        episode != nil && endEpisode == nil && role == .main
            && (evidence == .explicit || evidence == .structured)
            && form == .series
    }
}

/// Pure, conservative parsing shared by presentation, history and playback.
/// Bare numbers do not establish identity. A verified numbered-file family
/// may supply local queue context without changing persistent identities.
public enum PlaybackResourceAnalyzer {
    public static let rulesVersion = 4
    private static let number = "[0-9零〇一二两三四五六七八九十百千万]+"

    public static func compactName(_ raw: String, preserveTechnicalPrefix: Bool = false) -> String {
        var value = raw.removingPercentEncoding ?? raw
        if let url = URL(string: value), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            value = url.lastPathComponent
        }
        if let match = match(#"(?i)\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm|m3u8)(?=$|[?#\s【\[])"#, value) {
            value = (value as NSString).substring(to: match.range.location)
        }
        if !preserveTechnicalPrefix {
        value = value.replacingOccurrences(of: #"(?i)^\s*\[[^\]]*(?:[0-9]\s*(?:GB|MB|TB)|[248]K|1080|2160)[^\]]*\]\s*"#,
                                           with: "", options: .regularExpression)
        }
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func analyze(_ item: PlayEpisode, categoryName: String? = nil) -> PlaybackResourceSemantics {
        let name = compactName(item.name).precomposedStringWithCompatibilityMapping
        let metadata = item.metadata
        let form = metadata?.form == .unknown ? PlaybackContentForm.category(categoryName) : (metadata?.form ?? .category(categoryName))
        var result = PlaybackResourceSemantics(form: form, name: name)
        result.finale = name.contains("大结局")
        result.versionLabels = versions(compactName(item.name, preserveTechnicalPrefix: true).precomposedStringWithCompatibilityMapping)
        let bonus = ["番外", "花絮", "预告", "特别篇", "特辑", "彩蛋", "幕后"].contains(where: name.contains)
            || match(#"(?i)(?:^|[^A-Z0-9])(?:SP|OVA)(?:[ ._-]*[0-9]+)?(?:[^A-Z0-9]|$)"#, name) != nil
        if bonus { result.role = .bonus }
        else if match(#"(?i)(上[部篇集]|下[部篇集]|中[部篇集]|(?:^|[^A-Z])part[ ._-]*[0-9]+)"#, name) != nil { result.role = .part }

        // Provider metadata survives a descriptive title without episode tokens.
        if form == .series, let episode = metadata?.episode, valid(episode),
           metadata?.season == nil || (0...10_000).contains(metadata!.season!) {
            result.season = metadata?.season; result.episode = episode; result.evidence = .structured
            return result
        }
        // A provider-declared movie must not be converted by incidental EP text.
        if form == .movie { return result }

        struct Marker: Hashable { let season: Int?; let start: Int; let end: Int?; let unit: String }
        var markers: Set<Marker> = []
        let seasonPattern = #"(?i)(?:^|[^A-Z0-9])S([0-9]{1,4})[ ._-]*E([0-9]{1,5})(?:\s*[-–~至]\s*E?([0-9]{1,5}))?(?![0-9])"#
        for values in captures(seasonPattern, name) {
            if let season = Int(values[0]), let start = Int(values[1]), valid(start) {
                markers.insert(Marker(season: season, start: start, end: values[2].isEmpty ? nil : Int(values[2]), unit: "集"))
            }
        }
        let episodeCodeName = regex(seasonPattern)?.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: " ") ?? name
        for values in captures(#"(?i)(?:^|[^A-Z0-9])EP?[ ._-]*([0-9]{1,5})(?:\s*[-–~至]\s*(?:EP?)?([0-9]{1,5}))?(?![0-9])"#, episodeCodeName) {
            if let start = Int(values[0]), valid(start) { markers.insert(Marker(season: nil, start: start, end: Int(values[1]), unit: "集")) }
        }
        for values in captures("(?:^|[^全共0-9零〇一二两三四五六七八九十百千万])第?\\s*(\(number))(?:\\s*[-–~至]\\s*(\(number)))?\\s*([集话期])", name) {
            if let start = integer(values[0]), valid(start) {
                markers.insert(Marker(season: nil, start: start, end: integer(values[1]), unit: values[2]))
            }
        }
        let namedSeasons = captures("(?:第)?(\(number))季", name).compactMap { integer($0[0]) }
        let seasons = Set(namedSeasons + markers.compactMap(\.season))
        if seasons.count > 1 { result.evidence = .conflict; return result }
        if let season = seasons.first {
            markers = Set(markers.map { Marker(season: $0.season ?? season, start: $0.start, end: $0.end, unit: $0.unit) })
        }
        if markers.count > 1 { result.evidence = .conflict; return result }
        if let marker = markers.first {
            if let end = marker.end, !valid(end) || end <= marker.start { result.evidence = .conflict; return result }
            result.evidence = .explicit; result.unit = marker.unit
            if marker.unit == "期" { result.issue = marker.start; result.form = .programme }
            else {
                result.season = marker.season ?? metadata?.season
                result.episode = marker.start; result.endEpisode = marker.end; result.form = .series
            }
            return result
        }
        // Validate the entire date; never scan chunks of a longer numeric token.
        for v in captures(#"(?<![0-9])((?:19|20)[0-9]{2})[-./]?([01][0-9])[-./]?([0-3][0-9])(?![0-9])"#, name) {
            if let year = Int(v[0]), let month = Int(v[1]), let day = Int(v[2]) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let parts = DateComponents(year: year, month: month, day: day)
                if let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: date) == parts {
                    result.date = String(format: "%04d-%02d-%02d", year, month, day)
                    return result
                }
            }
        }
        if result.role == .main, form == .series,
           let episode = contextualNumber(name) {
            result.episode = episode; result.season = metadata?.season; result.evidence = .contextual
        }
        return result
    }

    /// List evidence is presentation-only: it never upgrades persistent identity.
    /// Use a numbered video sequence or multiple overlapping explicit anchors.
    public static func analyzeList(_ episodes: [PlayEpisode], categoryName: String? = nil) -> [PlaybackResourceSemantics] {
        var values = episodes.map { analyze($0, categoryName: categoryName) }
        inferNumberedVideoSequence(episodes, values: &values)
        guard PlaybackContentForm.category(categoryName) == .unknown else { return values }
        let anchors = values.filter { $0.hasReliableEpisode }
        guard Set(anchors.compactMap(\.episode)).count >= 2,
              Set(anchors.compactMap(\.season)).count <= 1,
              !values.contains(where: { $0.form == .movie || $0.evidence == .conflict }) else { return values }
        let candidates = values.indices.filter {
            values[$0].form == .unknown && values[$0].role == .main
                && values[$0].date == nil && contextualNumber(values[$0].name) != nil
        }
        let numbers = Set(candidates.compactMap { contextualNumber(values[$0].name) })
        guard numbers.count >= 3, numbers.intersection(Set(anchors.compactMap(\.episode))).count >= 2 else { return values }
        for index in candidates {
            values[index].form = .series
            values[index].episode = contextualNumber(values[index].name)
            values[index].evidence = .contextual
            // Season is independent evidence; never borrow it from another edition.
        }
        return values
    }

    public static func isNonVideoResource(_ item: PlayEpisode) -> Bool {
        let raw = (item.name.removingPercentEncoding ?? item.name).precomposedStringWithCompatibilityMapping
        return match(#"(?i)\.(mp3|flac|aac|m4a|wav|ogg|srt|ass|vtt)(?=$|[?#\s【\[])"#, raw) != nil
    }

    /// Names such as [4.93GB] ZIYA 22.mkv need the whole line to establish
    /// an episode sequence. Prefixes may change between uploads; continuity
    /// comes from the numbers within one version, never from array positions.
    /// Keep this evidence local to presentation and autoplay, not persistence.
    private static func inferNumberedVideoSequence(_ episodes: [PlayEpisode], values: inout [PlaybackResourceSemantics]) {
        guard !values.contains(where: { $0.form == .movie || $0.evidence == .conflict }) else { return }
        var families: [String: [(index: Int, number: Int)]] = [:]
        for index in values.indices {
            let value = values[index]
            let raw = (episodes[index].name.removingPercentEncoding ?? episodes[index].name).precomposedStringWithCompatibilityMapping
            guard value.form == .unknown || value.form == .series,
                  value.role == .main, value.endEpisode == nil, value.date == nil,
                  !isNonVideoResource(episodes[index]) else { continue }
            let hasVideoExtension = match(#"(?i)\.(mp4|mkv|m4v|mov|avi|ts|m2ts|flv|webm|m3u8)(?=$|[?#\s【\[])"#, raw) != nil
            let hasFileSize = match(#"(?i)\[[0-9]+(?:\.[0-9]+)?\s*(GB|MB|TB)\]"#, raw) != nil
            guard value.form == .series || hasVideoExtension || hasFileSize else { continue }
            let number = value.episode ?? contextualNumber(value.name) ?? numberedFileNumber(value.name)
            guard let number, valid(number) else { continue }
            let key = "\(value.season ?? -1):\(value.versionLabels.joined(separator: "|"))"
            families[key, default: []].append((index, number))
        }
        for family in families.values {
            let numbers = family.map(\.number).sorted()
            // A known series may have only two remaining uploads. Otherwise
            // require a run of three to establish the pattern, allowing gaps
            // elsewhere in an already established sequence.
            let knownSeries = family.allSatisfy { values[$0.index].form == .series }
            let hasConsecutiveRun = numbers.indices.dropFirst(2).contains {
                numbers[$0] == numbers[$0 - 1] + 1 && numbers[$0 - 1] == numbers[$0 - 2] + 1
            }
            guard Set(numbers).count == numbers.count,
                  (knownSeries && family.count >= 2) || hasConsecutiveRun else { continue }
            for candidate in family where values[candidate.index].evidence == .none {
                values[candidate.index].form = .series
                values[candidate.index].episode = candidate.number
                values[candidate.index].evidence = .contextual
            }
        }
    }

    private static func numberedFileNumber(_ name: String) -> Int? {
        var text = removingTechnicalLabels(name)
        for pattern in [
            #"(?i)(?<![A-Z0-9])(?:[HX][ ._-]?26[45]|AV1|[0-9]+(?:\.[0-9]+)?FPS|[0-9]+BIT)(?![A-Z0-9])"#,
            #"(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Exactly one remaining numeric token: no ranges, part numbers,
        // channel counts, sizes or conflicting episode hints.
        let tokens = captures(#"([0-9]+)"#, text)
        guard tokens.count == 1, let token = tokens.first?[0], token.count <= 3,
              let number = Int(token), valid(number) else { return nil }
        return number
    }

    private static func removingTechnicalLabels(_ name: String) -> String {
        var value = name.replacingOccurrences(of: #"(?i)\[[0-9]+(?:\.[0-9]+)?\s*(?:GB|MB|TB)\]"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)(?<![A-Z0-9])(?:4K(?:SDR|HDR(?:10\+?)?)?|2160p|1080p|720p|SDR|HDR(?:10\+?)?)(?![A-Z0-9])"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
    }

    private static func contextualNumber(_ name: String) -> Int? {
        let value = removingTechnicalLabels(name)
        guard let match = captures(#"^([0-9]{1,3})$"#, value).first,
              let number = Int(match[0]), valid(number) else { return nil }
        return number
    }

    public static func trustedEpisode(_ item: PlayEpisode, categoryName: String? = nil) -> PlaybackResourceSemantics? {
        let result = analyze(item, categoryName: categoryName)
        return result.hasReliableEpisode ? result : nil
    }

    public static func versions(_ name: String) -> [String] {
        var labels: [String] = []
        for word in ["国语", "粤语", "英语", "日语", "韩语", "原声", "导演剪辑版", "加长版", "修复版"] where name.contains(word) { labels.append(word) }
        for (pattern, label) in [(#"(?i)(?<![A-Z0-9])(?:2160p?|4K)(?=SDR|HDR|[^A-Z0-9]|$)"#, "4K"),
                                  (#"(?i)(?<![A-Z0-9])1080p?(?![A-Z0-9])"#, "1080p"),
                                  (#"(?i)(?<![A-Z0-9])720p?(?![A-Z0-9])"#, "720p"),
                                  (#"(?i)(?:(?<![A-Z0-9])|(?<=4K))HDR(?:10\+?)?(?![A-Z0-9])"#, "HDR"),
                                  (#"(?i)(?:(?<![A-Z0-9])|(?<=4K))SDR(?![A-Z0-9])"#, "SDR"),
                                  (#"杜比视界"#, "杜比视界")] where match(pattern, name) != nil { labels.append(label) }
        return labels
    }

    private static func valid(_ number: Int) -> Bool { (1...99_999).contains(number) }
    private static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        guard !text.isEmpty else { return nil }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let units: [Character: Int] = ["十":10,"百":100,"千":1000,"万":10000]
        var total = 0, section = 0, digit = 0
        for char in text {
            if let value = digits[char] { digit = value }
            else if let unit = units[char] {
                if unit == 10000 { total += (section + digit) * unit; section = 0 }
                else { section += max(1, digit) * unit }
                digit = 0
            } else { return nil }
        }
        return total + section + digit
    }
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let value = regexCache.object(forKey: pattern as NSString) { return value }
        guard let value = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(value, forKey: pattern as NSString); return value
    }
    private static func match(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = regex(pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}
