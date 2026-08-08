import Foundation

enum JSONDuplicateKeyDetector {
    static func validate(_ data: Data) throws {
        var scanner = Scanner(bytes: Array(data))
        try scanner.scanDocument()
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func scanDocument() throws {
            skipWhitespace()
            try scanValue(path: "<root>")
            skipWhitespace()
            guard index == bytes.count else {
                throw AppError.decoding("JSON 根值后存在多余内容")
            }
        }

        private mutating func scanValue(path: String) throws {
            skipWhitespace()
            guard let byte = current else {
                throw AppError.decoding("JSON 在 \(path) 处意外结束")
            }
            switch byte {
            case ascii("{"):
                try scanObject(path: path)
            case ascii("["):
                try scanArray(path: path)
            case ascii("\""):
                _ = try scanString(path: path)
            case ascii("t"):
                try scanLiteral("true", path: path)
            case ascii("f"):
                try scanLiteral("false", path: path)
            case ascii("n"):
                try scanLiteral("null", path: path)
            case ascii("-"), ascii("0")...ascii("9"):
                try scanNumber(path: path)
            default:
                throw AppError.decoding("JSON 在 \(path) 处包含非法字符")
            }
        }

        private mutating func scanObject(path: String) throws {
            try consume(ascii("{"), path: path)
            skipWhitespace()
            if consumeIf(ascii("}")) { return }

            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try scanString(path: path)
                guard keys.insert(key).inserted else {
                    throw AppError.configuration("JSON 对象 \(path) 存在重复字段：\(key)")
                }
                skipWhitespace()
                try consume(ascii(":"), path: path)
                let childPath = path == "<root>" ? key : "\(path).\(key)"
                try scanValue(path: childPath)
                skipWhitespace()
                if consumeIf(ascii("}")) { return }
                try consume(ascii(","), path: path)
            }
        }

        private mutating func scanArray(path: String) throws {
            try consume(ascii("["), path: path)
            skipWhitespace()
            if consumeIf(ascii("]")) { return }

            var item = 0
            while true {
                try scanValue(path: "\(path)[\(item)]")
                item += 1
                skipWhitespace()
                if consumeIf(ascii("]")) { return }
                try consume(ascii(","), path: path)
            }
        }

        private mutating func scanString(path: String) throws -> String {
            let start = index
            try consume(ascii("\""), path: path)
            var escaped = false
            while let byte = current {
                if byte < 0x20 {
                    throw AppError.decoding("JSON 字符串 \(path) 包含控制字符")
                }
                index += 1
                if escaped {
                    escaped = false
                    if byte == ascii("u") {
                        guard index + 4 <= bytes.count,
                              bytes[index..<(index + 4)].allSatisfy(Self.isHexDigit) else {
                            throw AppError.decoding("JSON 字符串 \(path) 包含非法 Unicode 转义")
                        }
                        index += 4
                    } else if ![
                        ascii("\""), ascii("\\"), ascii("/"), ascii("b"),
                        ascii("f"), ascii("n"), ascii("r"), ascii("t")
                    ].contains(byte) {
                        throw AppError.decoding("JSON 字符串 \(path) 包含非法转义")
                    }
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    let token = Data(bytes[start..<index])
                    do {
                        return try JSONDecoder().decode(String.self, from: token)
                    } catch {
                        throw AppError.decoding("JSON 字符串 \(path) 无法解码")
                    }
                }
            }
            throw AppError.decoding("JSON 字符串 \(path) 未闭合")
        }

        private mutating func scanLiteral(_ literal: String, path: String) throws {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw AppError.decoding("JSON 在 \(path) 处包含非法字面量")
            }
            index += expected.count
        }

        private mutating func scanNumber(path: String) throws {
            if consumeIf(ascii("-")), current == nil {
                throw AppError.decoding("JSON 数字 \(path) 不完整")
            }
            if consumeIf(ascii("0")) {
                if let byte = current, Self.isDigit(byte) {
                    throw AppError.decoding("JSON 数字 \(path) 包含前导零")
                }
            } else {
                try consumeDigits(path: path, required: true)
            }
            if consumeIf(ascii(".")) {
                try consumeDigits(path: path, required: true)
            }
            if current == ascii("e") || current == ascii("E") {
                index += 1
                if current == ascii("+") || current == ascii("-") {
                    index += 1
                }
                try consumeDigits(path: path, required: true)
            }
        }

        private mutating func consumeDigits(path: String, required: Bool) throws {
            let start = index
            while let byte = current, Self.isDigit(byte) {
                index += 1
            }
            if required, start == index {
                throw AppError.decoding("JSON 数字 \(path) 不完整")
            }
        }

        private mutating func consume(_ expected: UInt8, path: String) throws {
            guard consumeIf(expected) else {
                throw AppError.decoding("JSON 在 \(path) 处缺少“\(Character(UnicodeScalar(expected)))”")
            }
        }

        private mutating func consumeIf(_ expected: UInt8) -> Bool {
            guard current == expected else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let byte = current,
                  byte == ascii(" ") || byte == ascii("\n")
                    || byte == ascii("\r") || byte == ascii("\t") {
                index += 1
            }
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            ascii("0")...ascii("9") ~= byte
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || ascii("a")...ascii("f") ~= byte
                || ascii("A")...ascii("F") ~= byte
        }
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
