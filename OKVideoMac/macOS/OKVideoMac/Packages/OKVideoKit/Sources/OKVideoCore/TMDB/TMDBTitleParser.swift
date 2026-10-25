import Foundation

/// Versioned, lossless hints. Unknown bracket contents remain identity-bearing.
public struct TMDBParsedTitle: Equatable, Codable, Sendable {
    public let original: String
    public let workTitle: String
    public let years: Set<Int>
    public let seasons: Set<Int>
    public let labels: [String]
    public let unknown: [String]
    public let typeHint: TMDBMediaType?
    public static let version = 5

    public init(_ original: String) {
        self.original = original
        var text = original.precomposedStringWithCompatibilityMapping
        var years = Set<Int>(), labels: [String] = [], unknown: [String] = []
        let seasons = PlaybackResourceAnalyzer.explicitSeasons(in: text)
        let tags = Set(["臻彩", "4k", "8k", "720p", "1080p", "2160p", "高清", "超清", "蓝光", "藍光", "hdr", "hdr10", "dolbyvision", "web-dl", "bluray", "国语", "國語", "粤语", "粵語", "中字", "中字版", "双语", "雙語", "中英字幕", "完结", "全集", "导演剪辑版", "導演剪輯版", "加长版", "加長版", "修复版", "修復版"])
        func isYear(_ token: String) -> Bool { token.range(of: #"^(18|19|20)[0-9]{2}$"#, options: .regularExpression) != nil }
        func isSeason(_ token: String) -> Bool {
            token.range(of: #"(?i)^(?:第[0-9零〇一二两三四五六七八九十百]+季|[0-9]{1,4}季|S[0-9]{1,4}(?:E[0-9]+)?)$"#, options: .regularExpression) != nil
        }
        let brackets = try! NSRegularExpression(pattern: #"[\[【(]([^\[\]【】()]*)[\]】)]"#)
        for match in brackets.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            let contents = String(text[inner])
            var kept: [String] = []
            for token in contents.components(separatedBy: CharacterSet(charactersIn: "·•,，/、;；| ")).filter({ !$0.isEmpty }) {
                if tags.contains(token.lowercased()) { labels.append(token) }
                else if isYear(token), let year = Int(token) { years.insert(year) }
                else if isSeason(token) { /* separately retained above */ }
                else { kept.append(token) }
            }
            let remainder = kept.joined(separator: " ")
            if !remainder.isEmpty { unknown.append(remainder) }
            text.replaceSubrange(whole, with: remainder.isEmpty ? " " : "(\(remainder))")
        }
        // Space/dash delimited suffixes only; digits embedded in a name survive.
        let trailingYear = try! NSRegularExpression(pattern: #"\s+((?:18|19|20)[0-9]{2})\s*$"#)
        if let match = trailingYear.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text), let year = Int(text[range]),
           let whole = Range(match.range, in: text) { years.insert(year); text.removeSubrange(whole) }
        for pattern in [#"第[0-9零〇一二两三四五六七八九十百千万]+季"#, #"(?:^|\s)[0-9]{1,4}季(?=\s|$)"#, #"(?i)(?:^|\s)S[0-9]{1,4}(?:E[0-9]+)?(?=\s|$)"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        var tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        while tokens.count > 1, let token = tokens.last, tags.contains(token.lowercased()) {
            labels.append(token); tokens.removeLast()
        }
        text = tokens.joined(separator: " ")
        // Nested unknown subtitles remain identity-bearing after inner labels are extracted.
        if text.contains("("), unknown.isEmpty { unknown.append(text) }
        // Recognize a single explicitly delimited technical suffix.
        if let separator = text.lastIndex(where: { $0 == "-" || $0 == "_" }),
           tags.contains(String(text[text.index(after: separator)...]).lowercased()) {
            labels.append(String(text[text.index(after: separator)...])); text = String(text[..<separator])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        workTitle = text.isEmpty ? original.trimmingCharacters(in: .whitespacesAndNewlines) : text
        self.years = years; self.seasons = seasons; self.labels = labels.reversed(); self.unknown = unknown.reversed()
        typeHint = unknown.contains(where: { $0.contains("电影版") || $0.contains("電影版") }) ? .movie : nil
    }
}

public struct TMDBIdentitySnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let years: Set<Int>
    public let type: TMDBMediaType?
    public let season: Int?
    public init(_ input: TMDBMatchInput) {
        title = TMDBTitleNormalizer.key(input.titleWithoutAttachedYear ?? input.parsedTitle.workTitle)
        years = input.yearHints; type = input.type; season = input.season
    }
    public func isCompatible(with input: TMDBMatchInput) -> Bool {
        let other = Self(input)
        guard !input.hasConflict, title == other.title, type == nil || other.type == nil || type == other.type else { return false }
        // A new season can carry a different air year without changing the work.
        if type != .movie, season != other.season, season != nil || other.season != nil { return true }
        return years.isEmpty || other.years.isEmpty || other.years.isSubset(of: years)
    }
}

