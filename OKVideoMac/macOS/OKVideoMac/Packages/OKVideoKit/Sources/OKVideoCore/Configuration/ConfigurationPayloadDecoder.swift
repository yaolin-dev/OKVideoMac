import Foundation

/// Decodes the transport wrappers accepted by FongMi's `Decoder.getJson`.
///
/// Some configuration providers return a valid JPEG whose metadata contains
/// `AAAAAAAA**<base64-json>`. Treating the response as JSON directly produces a
/// misleading decoding error, so unwrap that documented FongMi convention
/// before handing the bytes to `ConfigurationParser`.
public struct ConfigurationPayloadDecoder {
    public init() {}

    public func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw AppError.configuration("配置内容为空")
        }
        if Self.firstSignificantByte(in: data) == UInt8(ascii: "{") {
            return data
        }

        let bytes = [UInt8](data)
        if let payload = try decodeBase64Payload(in: bytes) {
            return payload
        }

        if Self.looksLikeImage(bytes) {
            throw AppError.configuration(
                "远程地址返回了图片，但没有找到有效的 FongMi Base64 配置"
            )
        }
        return data
    }

    private func decodeBase64Payload(in bytes: [UInt8]) throws -> Data? {
        guard bytes.count >= 10 else { return nil }
        for index in 0...(bytes.count - 10) {
            guard bytes[index..<(index + 8)].allSatisfy(Self.isASCIIAlphaNumeric),
                  bytes[index + 8] == UInt8(ascii: "*"),
                  bytes[index + 9] == UInt8(ascii: "*") else {
                continue
            }

            let encoded = String(
                decoding: bytes[(index + 10)...],
                as: UTF8.self
            )
            guard let decoded = Data(
                base64Encoded: encoded,
                options: [.ignoreUnknownCharacters]
            ), Self.firstSignificantByte(in: decoded) == UInt8(ascii: "{") else {
                continue
            }
            guard decoded.count <= ConfigurationParser.maximumConfigurationSize else {
                throw AppError.configuration(
                    "解包后的配置超过 \(ConfigurationParser.maximumConfigurationSize) 字节限制"
                )
            }
            return decoded
        }
        return nil
    }

    private static func firstSignificantByte(in data: Data) -> UInt8? {
        var bytes = Array(data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        if let byte = bytes.first(where: { !isJSONWhitespace($0) }) {
            return byte
        }
        return data.dropFirst(min(4, data.count)).first {
            !isJSONWhitespace($0)
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func looksLikeImage(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || bytes.starts(with: Array("GIF8".utf8))
            || bytes.starts(with: Array("BM".utf8))
    }
}
