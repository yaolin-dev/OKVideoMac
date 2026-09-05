import Foundation

/// Normalizes the deliberately small JSONC dialect accepted by TVBox/Gson
/// configurations without broadening configuration parsing to JSON5.
///
/// Comments and trailing commas are replaced with ASCII spaces. Keeping the
/// original byte count and line breaks prevents adjacent JSON tokens from
/// being joined and preserves useful line/column diagnostics.
enum TVBoxJSONNormalizer {
    static func normalize(_ data: Data) throws -> Data {
        var bytes = [UInt8](data)
        try replaceComments(in: &bytes)
        replaceTrailingCommas(in: &bytes)
        return Data(bytes)
    }

    private static func replaceComments(in bytes: inout [UInt8]) throws {
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == ascii("\\") {
                    isEscaped = true
                } else if byte == ascii("\"") {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == ascii("\"") {
                isInsideString = true
                index += 1
                continue
            }
            guard byte == ascii("/"), index + 1 < bytes.count else {
                index += 1
                continue
            }

            switch bytes[index + 1] {
            case ascii("/"):
                bytes[index] = ascii(" ")
                bytes[index + 1] = ascii(" ")
                index += 2
                while index < bytes.count,
                      bytes[index] != ascii("\n"),
                      bytes[index] != ascii("\r") {
                    bytes[index] = ascii(" ")
                    index += 1
                }

            case ascii("*"):
                bytes[index] = ascii(" ")
                bytes[index + 1] = ascii(" ")
                index += 2
                var didClose = false
                while index < bytes.count {
                    if index + 1 < bytes.count,
                       bytes[index] == ascii("*"),
                       bytes[index + 1] == ascii("/") {
                        bytes[index] = ascii(" ")
                        bytes[index + 1] = ascii(" ")
                        index += 2
                        didClose = true
                        break
                    }
                    if bytes[index] != ascii("\n"),
                       bytes[index] != ascii("\r") {
                        bytes[index] = ascii(" ")
                    }
                    index += 1
                }
                guard didClose else {
                    throw AppError.decoding("JSON 块注释未闭合")
                }

            default:
                index += 1
            }
        }
    }

    private static func replaceTrailingCommas(in bytes: inout [UInt8]) {
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == ascii("\\") {
                    isEscaped = true
                } else if byte == ascii("\"") {
                    isInsideString = false
                }
                index += 1
                continue
            }
            if byte == ascii("\"") {
                isInsideString = true
                index += 1
                continue
            }
            guard byte == ascii(",") else {
                index += 1
                continue
            }

            var lookahead = index + 1
            while lookahead < bytes.count, isJSONWhitespace(bytes[lookahead]) {
                lookahead += 1
            }
            if lookahead < bytes.count,
               bytes[lookahead] == ascii("}")
                || bytes[lookahead] == ascii("]") {
                bytes[index] = ascii(" ")
            }
            index += 1
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == ascii(" ") || byte == ascii("\t")
            || byte == ascii("\n") || byte == ascii("\r")
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
