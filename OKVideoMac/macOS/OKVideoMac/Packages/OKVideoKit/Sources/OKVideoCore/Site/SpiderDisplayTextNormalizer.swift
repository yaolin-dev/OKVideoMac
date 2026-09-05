import Foundation

/// Converts display-only Spider text without changing the provider response
/// retained by `VideoDetail`.
public enum SpiderDisplayTextNormalizer {
    /// Normalizes a list of people returned by a Spider for safe plain-text UI.
    ///
    /// FongMi-compatible Spiders can wrap names in `[a=cr:.../]name[/a]`.
    /// Only that exact protocol wrapper is interpreted: its payload is never
    /// executed or exposed, while the visible label is retained.
    public static func people(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let decoded = decodeHTMLEntities(in: rawValue)
        let visibleText = extractCRAnchorLabels(from: decoded)
        let parts = visibleText.split(whereSeparator: isPeopleSeparator)

        var seen = Set<String>()
        var names: [String] = []
        for part in parts {
            let name = collapseWhitespace(in: String(part))
            guard !name.isEmpty else { continue }
            let identity = name.lowercased()
            guard seen.insert(identity).inserted else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private static func extractCRAnchorLabels(from value: String) -> String {
        let openingMarker = "[a=cr:"
        let openingTerminator = "/]"
        let closingMarker = "[/a]"
        var output = ""
        var cursor = value.startIndex

        while cursor < value.endIndex,
              let opening = value.range(
                  of: openingMarker,
                  options: [.caseInsensitive],
                  range: cursor..<value.endIndex
              ) {
            output.append(contentsOf: value[cursor..<opening.lowerBound])

            guard let openingEnd = value.range(
                of: openingTerminator,
                range: opening.upperBound..<value.endIndex
            ) else {
                // A broken protocol payload must never become visible. If a
                // closing marker exists, discard only this malformed wrapper
                // and continue preserving later plain text.
                if let closing = value.range(
                    of: closingMarker,
                    options: [.caseInsensitive],
                    range: opening.upperBound..<value.endIndex
                ) {
                    cursor = closing.upperBound
                    continue
                }
                cursor = value.endIndex
                break
            }

            let labelStart = openingEnd.upperBound
            if let closing = value.range(
                of: closingMarker,
                options: [.caseInsensitive],
                range: labelStart..<value.endIndex
            ) {
                output.append(contentsOf: value[labelStart..<closing.lowerBound])
                cursor = closing.upperBound
            } else {
                // The payload terminator establishes a safe label boundary.
                // Preserve a dangling visible label, but stop before another
                // protocol wrapper so that its JSON cannot leak into the UI.
                let nextOpening = value.range(
                    of: openingMarker,
                    options: [.caseInsensitive],
                    range: labelStart..<value.endIndex
                )
                let labelEnd = nextOpening?.lowerBound ?? value.endIndex
                output.append(contentsOf: value[labelStart..<labelEnd])
                cursor = labelEnd
            }
        }

        if cursor < value.endIndex {
            output.append(contentsOf: value[cursor..<value.endIndex])
        }
        return removingProtocolClosers(from: output)
    }

    private static func removingProtocolClosers(from value: String) -> String {
        let marker = "[/a]"
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex,
              let range = value.range(
                  of: marker,
                  options: [.caseInsensitive],
                  range: cursor..<value.endIndex
              ) {
            output.append(contentsOf: value[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        if cursor < value.endIndex {
            output.append(contentsOf: value[cursor..<value.endIndex])
        }
        return output
    }

    private static func isPeopleSeparator(_ character: Character) -> Bool {
        switch character {
        case ",", "，", "、", ";", "；", "|", "\n", "\r", "\t":
            return true
        default:
            return false
        }
    }

    private static func collapseWhitespace(in value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func decodeHTMLEntities(in value: String) -> String {
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "&" else {
                output.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }

            let maximumEnd = value.index(
                cursor,
                offsetBy: 12,
                limitedBy: value.endIndex
            ) ?? value.endIndex
            guard let semicolon = value[cursor..<maximumEnd].firstIndex(of: ";") else {
                output.append("&")
                cursor = value.index(after: cursor)
                continue
            }
            let entityStart = value.index(after: cursor)
            let entity = String(value[entityStart..<semicolon])
            guard let decoded = decodedEntity(entity) else {
                output.append(contentsOf: value[cursor...semicolon])
                cursor = value.index(after: semicolon)
                continue
            }
            output.append(decoded)
            cursor = value.index(after: semicolon)
        }
        return output
    }

    private static func decodedEntity(_ entity: String) -> Character? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "apos": return "'"
        case "quot": return "\""
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default:
            let scalarValue: UInt32?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalarValue = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                scalarValue = UInt32(entity.dropFirst(), radix: 10)
            } else {
                scalarValue = nil
            }
            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else {
                return nil
            }
            return Character(scalar)
        }
    }
}
