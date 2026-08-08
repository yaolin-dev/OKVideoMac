import Foundation
import CoreFoundation

public struct LiveSourceParser {
    public init() {}

    public func parse(_ data: Data, baseURL: URL? = nil) throws -> LivePlaylist {
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw AppError.live("直播源超过 32 MiB 限制")
        }
        guard let text = decodeText(data) else {
            throw AppError.live("直播源文本编码无法识别")
        }
        return try parse(text, baseURL: baseURL)
    }

    public func parse(_ text: String, baseURL: URL? = nil) throws -> LivePlaylist {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.live("直播源为空")
        }

        if trimmed.hasPrefix("[") {
            return try parseJSON(trimmed, baseURL: baseURL)
        }
        if normalized.contains("#EXTM3U") && !normalized.contains("#genre#") {
            return try parseM3U(normalized, baseURL: baseURL)
        }
        return try parseTXT(normalized, baseURL: baseURL)
    }

    private func parseJSON(_ text: String, baseURL: URL?) throws -> LivePlaylist {
        guard let data = text.data(using: .utf8) else {
            throw AppError.live("JSON 直播源不是 UTF-8")
        }
        let groups: [LiveGroupConfiguration]
        do {
            groups = try JSONDecoder().decode([LiveGroupConfiguration].self, from: data)
        } catch {
            throw AppError.live("JSON 直播源无效：\(error.localizedDescription)")
        }
        let mapped = groups.compactMap { group -> LiveGroup? in
            let channels = group.channels.compactMap { channel -> LiveChannel? in
                var channelHeaders = channel.header
                if let userAgent = channel.userAgent {
                    channelHeaders["User-Agent"] = userAgent
                }
                if let referer = channel.referer {
                    channelHeaders["Referer"] = referer
                }
                if let origin = channel.origin {
                    channelHeaders["Origin"] = origin
                }
                let streams = channel.urls.enumerated().compactMap { index, raw in
                    makeStream(
                        raw: raw,
                        defaultName: "线路 \(index + 1)",
                        inheritedHeaders: channelHeaders,
                        format: channel.format,
                        needsParsing: channel.parse == 1,
                        baseURL: baseURL
                    )
                }
                guard !channel.name.isEmpty, !streams.isEmpty else { return nil }
                return LiveChannel(
                    groupName: group.name,
                    name: channel.name,
                    number: channel.number,
                    logoURL: channel.logo.flatMap { try? ResourceResolver.resolve($0, relativeTo: baseURL) },
                    tvgID: channel.tvgID,
                    tvgName: channel.tvgName,
                    streams: streams
                )
            }
            guard !group.name.isEmpty, !channels.isEmpty else { return nil }
            return LiveGroup(name: group.name, password: group.pass, channels: channels)
        }
        return LivePlaylist(format: .json, groups: mapped)
    }

    private func parseM3U(_ text: String, baseURL: URL?) throws -> LivePlaylist {
        var builders: [GroupBuilder] = []
        var metadata = M3UMetadata()
        var epgURL: URL?
        var globalHeaders: [String: String] = [:]

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTM3U") {
                let attributes = parseAttributes(line)
                if let rawEPG = attributes["tvg-url"] ?? attributes["url-tvg"] {
                    epgURL = try? ResourceResolver.resolve(rawEPG, relativeTo: baseURL)
                }
            } else if line.hasPrefix("#EXTINF:") {
                let attributes = parseAttributes(line)
                metadata = M3UMetadata(
                    group: attributes["group-title"] ?? "未分组",
                    name: line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                        .dropFirst().first.map(String.init) ?? attributes["tvg-name"] ?? "未命名频道",
                    number: attributes["tvg-chno"],
                    logo: attributes["tvg-logo"],
                    tvgID: attributes["tvg-id"],
                    tvgName: attributes["tvg-name"],
                    headers: globalHeaders,
                    format: nil,
                    needsParsing: false
                )
                if let userAgent = attributes["http-user-agent"] {
                    metadata.headers["User-Agent"] = userAgent
                }
            } else if line.hasPrefix("#EXTHTTP:") {
                let json = String(line.dropFirst("#EXTHTTP:".count))
                if let data = json.data(using: .utf8),
                   let headers = try? JSONDecoder().decode([String: String].self, from: data) {
                    metadata.headers.merge(headers) { _, new in new }
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                applyVLCOption(line, to: &metadata.headers)
            } else if line.hasPrefix("ua=") {
                metadata.headers["User-Agent"] = value(after: "=", in: line)
            } else if line.hasPrefix("referer=") {
                metadata.headers["Referer"] = value(after: "=", in: line)
            } else if line.hasPrefix("origin=") {
                metadata.headers["Origin"] = value(after: "=", in: line)
            } else if line.hasPrefix("header=") {
                metadata.headers.merge(parseInlineHeaders(value(after: "=", in: line))) { _, new in new }
            } else if line.hasPrefix("format=") {
                metadata.format = value(after: "=", in: line)
            } else if line.hasPrefix("parse=") {
                metadata.needsParsing = value(after: "=", in: line) == "1"
            } else if line.hasPrefix("global-header=") {
                globalHeaders.merge(
                    parseInlineHeaders(value(after: "=", in: line))
                ) { _, new in new }
            } else if !line.hasPrefix("#"), line.contains("://") || baseURL != nil {
                let groupName = metadata.group.isEmpty ? "未分组" : metadata.group
                let channelName = metadata.name.isEmpty ? "未命名频道" : metadata.name
                guard let stream = makeStream(
                    raw: line,
                    defaultName: "线路 1",
                    inheritedHeaders: metadata.headers,
                    format: metadata.format,
                    needsParsing: metadata.needsParsing,
                    baseURL: baseURL
                ) else {
                    continue
                }
                append(
                    stream: stream,
                    metadata: metadata,
                    groupName: groupName,
                    channelName: channelName,
                    builders: &builders,
                    baseURL: baseURL
                )
                metadata = M3UMetadata(headers: globalHeaders)
            }
        }

        return LivePlaylist(
            format: .m3u,
            groups: builders.map(\.value),
            epgURL: epgURL
        )
    }

    private func parseTXT(_ text: String, baseURL: URL?) throws -> LivePlaylist {
        var builders: [GroupBuilder] = []
        var currentGroup = "未分组"
        var inheritedHeaders: [String: String] = [:]
        var format: String?
        var needsParsing = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.contains("#genre#") {
                let name = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? "未分组"
                currentGroup = name
                inheritedHeaders = [:]
                format = nil
                needsParsing = false
                ensureGroup(named: currentGroup, builders: &builders)
                continue
            }
            if line.hasPrefix("ua=") {
                inheritedHeaders["User-Agent"] = value(after: "=", in: line)
                continue
            }
            if line.hasPrefix("referer=") {
                inheritedHeaders["Referer"] = value(after: "=", in: line)
                continue
            }
            if line.hasPrefix("origin=") {
                inheritedHeaders["Origin"] = value(after: "=", in: line)
                continue
            }
            if line.hasPrefix("header=") {
                inheritedHeaders.merge(parseInlineHeaders(value(after: "=", in: line))) { _, new in new }
                continue
            }
            if line.hasPrefix("format=") {
                format = value(after: "=", in: line)
                continue
            }
            if line.hasPrefix("parse=") {
                needsParsing = value(after: "=", in: line) == "1"
                continue
            }

            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let channelName = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let rawURLs = String(parts[1])
            guard rawURLs.contains("://") || baseURL != nil else { continue }
            for (index, rawURL) in rawURLs.components(separatedBy: "#").enumerated() {
                guard let stream = makeStream(
                    raw: rawURL,
                    defaultName: "线路 \(index + 1)",
                    inheritedHeaders: inheritedHeaders,
                    format: format,
                    needsParsing: needsParsing,
                    baseURL: baseURL
                ) else {
                    continue
                }
                append(
                    stream: stream,
                    metadata: M3UMetadata(group: currentGroup, name: channelName),
                    groupName: currentGroup,
                    channelName: channelName,
                    builders: &builders,
                    baseURL: baseURL
                )
            }
        }

        return LivePlaylist(format: .text, groups: builders.map(\.value))
    }

    private func makeStream(
        raw: String,
        defaultName: String,
        inheritedHeaders: [String: String],
        format: String?,
        needsParsing: Bool,
        baseURL: URL?
    ) -> LiveStream? {
        let headerParts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        var rawURLAndName = String(headerParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = inheritedHeaders
        if headerParts.count == 2 {
            headers.merge(parseInlineHeaders(String(headerParts[1]))) { _, new in new }
        }

        var lineName = defaultName
        if let separator = rawURLAndName.lastIndex(of: "$") {
            let suffix = String(rawURLAndName[rawURLAndName.index(after: separator)...])
            if !suffix.isEmpty {
                lineName = suffix
                rawURLAndName = String(rawURLAndName[..<separator])
            }
        }
        guard let url = resolveLiveMediaURL(
            rawURLAndName,
            relativeTo: baseURL
        ) else {
            return nil
        }
        return LiveStream(
            name: lineName,
            url: url,
            headers: headers,
            format: format,
            needsParsing: needsParsing
        )
    }

    private func resolveLiveMediaURL(
        _ reference: String,
        relativeTo baseURL: URL?
    ) -> URL? {
        let value = normalizedLiveMediaReference(
            reference.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !value.isEmpty else { return nil }
        if let absolute = URL(string: value),
           let scheme = absolute.scheme?.lowercased() {
            let supportedSchemes = [
                "http", "https", "rtsp", "rtmp", "rtmps", "rtp", "udp"
            ]
            return supportedSchemes.contains(scheme) ? absolute : nil
        }
        guard let baseURL,
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            return nil
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    /// Real-world IPTV lists often contain literal `%`, incomplete percent
    /// escapes (for example `%0`), or spaces in signed query strings. Android's
    /// URI stack accepts them, while Foundation rejects the whole URL. Encode
    /// only invalid escapes and ASCII whitespace so valid signatures such as
    /// `%7E` and `%2C` remain byte-for-byte unchanged.
    private func normalizedLiveMediaReference(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                if index + 2 < bytes.count,
                   isASCIIHexDigit(bytes[index + 1]),
                   isASCIIHexDigit(bytes[index + 2]) {
                    output.append(contentsOf: bytes[index...(index + 2)])
                    index += 3
                    continue
                }
                output.append(contentsOf: Array("%25".utf8))
            } else if byte <= 0x20 || byte == 0x7F {
                output.append(contentsOf: Array(String(format: "%%%02X", byte).utf8))
            } else {
                output.append(byte)
            }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    private func append(
        stream: LiveStream,
        metadata: M3UMetadata,
        groupName: String,
        channelName: String,
        builders: inout [GroupBuilder],
        baseURL: URL?
    ) {
        let protectedGroup = splitProtectedGroupName(groupName)
        let groupIndex: Int
        if let index = builders.firstIndex(where: { $0.name == protectedGroup.name }) {
            groupIndex = index
        } else {
            builders.append(
                GroupBuilder(name: protectedGroup.name, password: protectedGroup.password)
            )
            groupIndex = builders.count - 1
        }

        let normalizedGroupName = builders[groupIndex].name
        let channelIndex: Int
        if let index = builders[groupIndex].channels.firstIndex(where: { $0.name == channelName }) {
            channelIndex = index
        } else {
            builders[groupIndex].channels.append(
                LiveChannel(
                    groupName: normalizedGroupName,
                    name: channelName,
                    number: metadata.number,
                    logoURL: metadata.logo.flatMap {
                        try? ResourceResolver.resolve($0, relativeTo: baseURL)
                    },
                    tvgID: metadata.tvgID,
                    tvgName: metadata.tvgName,
                    streams: []
                )
            )
            channelIndex = builders[groupIndex].channels.count - 1
        }
        if !builders[groupIndex].channels[channelIndex].streams.contains(where: { $0.url == stream.url }) {
            builders[groupIndex].channels[channelIndex].streams.append(stream)
        }
    }

    private func ensureGroup(named name: String, builders: inout [GroupBuilder]) {
        guard !builders.contains(where: { $0.name == splitProtectedGroupName(name).name }) else {
            return
        }
        let protected = splitProtectedGroupName(name)
        builders.append(GroupBuilder(name: protected.name, password: protected.password))
    }

    private func splitProtectedGroupName(_ value: String) -> (name: String, password: String?) {
        guard let separator = value.lastIndex(of: "_") else {
            return (value.isEmpty ? "未分组" : value, nil)
        }
        let name = String(value[..<separator])
        let password = String(value[value.index(after: separator)...])
        guard !name.isEmpty, !password.isEmpty else { return (value, nil) }
        return (name, password)
    }

    private func parseAttributes(_ line: String) -> [String: String] {
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(line.startIndex..., in: line)
        var output: [String: String] = [:]
        for match in regex.matches(in: line, range: range) where match.numberOfRanges == 3 {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            output[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }
        return output
    }

    private func parseInlineHeaders(_ value: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: value.split(separator: "&").compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
            let rawValue = String(pair[1])
            let decoded = rawValue.removingPercentEncoding ?? rawValue
            return (key, decoded)
        })
    }

    private func applyVLCOption(_ line: String, to headers: inout [String: String]) {
        if line.contains("http-user-agent=") {
            headers["User-Agent"] = value(after: "http-user-agent=", in: line)
        } else if line.contains("http-referrer=") {
            headers["Referer"] = value(after: "http-referrer=", in: line)
        } else if line.contains("http-origin=") {
            headers["Origin"] = value(after: "http-origin=", in: line)
        }
    }

    private func value(after separator: String, in line: String) -> String {
        guard let range = line.range(of: separator, options: .caseInsensitive) else { return "" }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeText(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb18030)
    }
}

private struct M3UMetadata {
    var group: String = "未分组"
    var name: String = ""
    var number: String?
    var logo: String?
    var tvgID: String?
    var tvgName: String?
    var headers: [String: String] = [:]
    var format: String?
    var needsParsing: Bool = false
}

private struct GroupBuilder {
    var name: String
    var password: String?
    var channels: [LiveChannel] = []

    var value: LiveGroup {
        LiveGroup(name: name, password: password, channels: channels)
    }
}
