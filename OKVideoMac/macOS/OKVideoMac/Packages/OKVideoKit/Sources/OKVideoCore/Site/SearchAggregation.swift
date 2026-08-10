import Foundation

public struct SearchResultCluster: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var year: String?
    public var sources: [VideoSummary]

    public init(id: String, title: String, year: String?, sources: [VideoSummary]) {
        self.id = id
        self.title = title
        self.year = year
        self.sources = sources
    }

    public var primary: VideoSummary? {
        sources.first
    }
}

public enum SearchResultAggregator {
    public static func cluster(_ items: [VideoSummary]) -> [SearchResultCluster] {
        let withinSite = deduplicateWithinSite(items)
        var clusters: [SearchResultCluster] = []
        var indexByKey: [String: Int] = [:]

        // Keep arrival order and the first source as the primary source. Search
        // results arrive incrementally; re-sorting the sources on every event
        // used to replace an already visible card's title and poster.
        for item in withinSite {
            let key = clusterKey(item)
            if let index = indexByKey[key] {
                clusters[index].sources.append(item)
            } else {
                indexByKey[key] = clusters.count
                clusters.append(
                    SearchResultCluster(
                        id: key,
                        title: item.title,
                        year: item.year?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .nonEmpty,
                        sources: [item]
                    )
                )
            }
        }
        return clusters
    }

    private static func deduplicateWithinSite(_ items: [VideoSummary]) -> [VideoSummary] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func clusterKey(_ item: VideoSummary) -> String {
        let foldedTitle = item.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let year = item.year?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "<unknown>"
        return "\(foldedTitle)::\(year)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
