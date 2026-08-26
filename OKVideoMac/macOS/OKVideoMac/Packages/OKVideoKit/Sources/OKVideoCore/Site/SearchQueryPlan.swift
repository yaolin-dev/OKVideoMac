import Foundation

struct SearchQueryPlan: Equatable, Sendable {
    let original: String
    let fallback: String?

    init(_ keyword: String) {
        let original = keyword
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.original = original

        guard SearchTitleNormalizer.containsRemovableSeparator(in: original) else {
            fallback = nil
            return
        }
        let candidate = SearchTitleNormalizer.containsCJK(in: original)
            ? SearchTitleNormalizer.compactQuery(original)
            : SearchTitleNormalizer.tokenizedQuery(original)
        fallback = candidate.isEmpty || candidate == original ? nil : candidate
    }
}

enum SearchTitleNormalizer {
    static func strictKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func comparisonKey(_ value: String) -> String {
        transformed(folded(value), separator: .remove)
    }

    static func tokenizedQuery(_ value: String) -> String {
        transformed(queryValue(value), separator: .space)
    }

    static func compactQuery(_ value: String) -> String {
        transformed(queryValue(value), separator: .remove)
    }

    static func containsRemovableSeparator(in value: String) -> Bool {
        let characters = Array(queryValue(value))
        return characters.indices.contains { index in
            let character = characters[index]
            guard !character.isWhitespace,
                  !character.isLetter,
                  !character.isNumber else { return false }
            return !isSemanticSymbol(character, at: index, in: characters)
        }
    }

    static func containsCJK(in value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF,
                 0x3040...0x30FF,
                 0x31F0...0x31FF,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xAC00...0xD7AF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private enum SeparatorReplacement {
        case remove
        case space
    }

    private static func transformed(
        _ value: String,
        separator: SeparatorReplacement
    ) -> String {
        let characters = Array(value)
        var output = ""
        var needsSpace = false

        for index in characters.indices {
            let character = characters[index]
            if character.isLetter || character.isNumber
                || isSemanticSymbol(character, at: index, in: characters) {
                if needsSpace, !output.isEmpty {
                    output.append(" ")
                }
                needsSpace = false
                output.append(character)
            } else if separator == .space {
                needsSpace = !output.isEmpty
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folded(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func queryValue(_ value: String) -> String {
        value
            .folding(options: [.widthInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSemanticSymbol(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        switch character {
        case "+", "#", "/":
            return true
        case "-", "‐", "‑":
            return hasASCIIAlphaNumericNeighbors(at: index, in: characters)
        case ".":
            return neighbor(at: index - 1, in: characters)?.isNumber == true
                && neighbor(at: index + 1, in: characters)?.isNumber == true
        case "'", "’":
            return hasASCIILetterNeighbors(at: index, in: characters)
        case "!", "?":
            return neighbor(at: index - 1, in: characters).map {
                isASCIIAlphaNumeric($0)
            } == true
        default:
            return false
        }
    }

    private static func hasASCIIAlphaNumericNeighbors(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard let previous = neighbor(at: index - 1, in: characters),
              let next = neighbor(at: index + 1, in: characters) else {
            return false
        }
        return isASCIIAlphaNumeric(previous) && isASCIIAlphaNumeric(next)
    }

    private static func hasASCIILetterNeighbors(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard let previous = neighbor(at: index - 1, in: characters),
              let next = neighbor(at: index + 1, in: characters) else {
            return false
        }
        return isASCIILetter(previous) && isASCIILetter(next)
    }

    private static func neighbor(
        at index: Int,
        in characters: [Character]
    ) -> Character? {
        characters.indices.contains(index) ? characters[index] : nil
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        isASCIILetter(character) || isASCIIDigit(character)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x30...0x39).contains(value)
    }
}
