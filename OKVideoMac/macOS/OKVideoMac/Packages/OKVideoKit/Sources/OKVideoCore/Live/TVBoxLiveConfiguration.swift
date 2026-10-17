import Foundation

/// Wire configuration stays with the imported source, never in diagnostics.
public struct TVBoxCatchupConfiguration: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var type: String
    public var days: String?
    public var regex: String
    public var source: String
    public var replace: String

    public init(type: String = "append", days: String? = nil, regex: String = "", source: String = "", replace: String = "") {
        self.type = type; self.days = days; self.regex = regex; self.source = source; self.replace = replace
    }

    private enum CodingKeys: String, CodingKey { case type, days, regex, source, replace }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "append"
        if let value = try? c.decode(String.self, forKey: .days) { days = value }
        else if let value = try? c.decode(Double.self, forKey: .days) { days = String(value) }
        else if c.contains(.days), !(try c.decodeNil(forKey: .days)) { days = "invalid" }
        else { days = nil }
        regex = try c.decodeIfPresent(String.self, forKey: .regex) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? ""
    }

    public var isEmpty: Bool { source.isEmpty && !["none", "off", "disabled"].contains(type) }

    public func normalized(for url: URL, deviceTimeZoneID: String = TimeZone.current.identifier) -> LiveCatchupConfiguration? {
        if ["none", "off", "disabled"].contains(type) { return .init(mode: "none", template: "") }
        guard !isEmpty else { return nil }
        do {
            let original = url.absoluteString
            guard try TVBoxBoundedRegex.matches(regex, text: original) else {
                return .init(mode: "none", template: "")
            }
            var template = try normalizedTokens(source)
            if type != "default" {
                var base = original
                let pair = replace.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 {
                    base = try TVBoxBoundedRegex.replacing(String(pair[0]), in: base, template: String(pair[1]))
                }
                if URLComponents(string: base)?.query?.isEmpty == false {
                    template = template.replacingOccurrences(of: "?", with: "&")
                }
                template = base + template
            }
            return .init(mode: "default", template: template, retentionDays: days.map { Double($0) ?? 0 },
                         timeZoneID: deviceTimeZoneID, seekPolicy: .request)
        } catch {
            // An invalid explicit rule must not expose the implicit PLTV fallback.
            return .init(mode: "default", template: "")
        }
    }

    private func normalizedTokens(_ value: String) throws -> String {
        guard value.utf8.count <= 16384 else { throw LiveCatchupError.invalidTemplate }
        let expression = try NSRegularExpression(pattern: #"\$?\{([^{}]+)\}"#)
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = value
        for match in matches.reversed() {
            guard let tagRange = Range(match.range(at: 1), in: value),
                  let range = Range(match.range, in: result) else { throw LiveCatchupError.invalidTemplate }
            let tag = String(value[tagRange]); let token: String
            if tag.hasPrefix("(b)") || tag.hasPrefix("(e)") {
                let field = tag.hasPrefix("(b)") ? "utc" : "utcend"
                let format = String(tag.dropFirst(3))
                token = format == "timestamp" ? "{\(field)}" : "{\(field):\(try datePattern(format))}"
            } else if tag.hasPrefix("utcend:") { token = "{utcend}" }
            else if tag.hasPrefix("utc:") { token = "{utc}" }
            else { throw LiveCatchupError.invalidTemplate }
            result.replaceSubrange(range, with: token)
        }
        return result
    }

    private func datePattern(_ format: String) throws -> String {
        guard !format.isEmpty, format.count <= 64 else { throw LiveCatchupError.invalidTemplate }
        let pairs = [("yyyy", "Y"), ("MM", "m"), ("dd", "d"), ("HH", "H"), ("mm", "M"), ("ss", "S")]
        var remainder = format[...], result = ""
        while !remainder.isEmpty {
            if remainder.hasPrefix("'T'") { result += "T"; remainder = remainder.dropFirst(3) }
            else if let pair = pairs.first(where: { remainder.hasPrefix($0.0) }) {
                result += pair.1; remainder = remainder.dropFirst(pair.0.count)
            } else if let char = remainder.first, "-_:T.".contains(char) {
                result.append(char); remainder = remainder.dropFirst()
            } else { throw LiveCatchupError.invalidTemplate }
        }
        return result
    }

    public var description: String { "TVBoxCatchupConfiguration(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// ICU's progress callback bounds untrusted matching and replacement work.
enum TVBoxBoundedRegex {
    private static func results(_ pattern: String, text: String) throws -> [NSTextCheckingResult] {
        guard pattern.utf8.count <= 1024, text.utf8.count <= 16384 else { throw LiveCatchupError.invalidTemplate }
        let expression = try NSRegularExpression(pattern: pattern)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.02
        var values: [NSTextCheckingResult] = [], exceeded = false
        expression.enumerateMatches(in: text, options: [.reportProgress],
                                    range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if ProcessInfo.processInfo.systemUptime > deadline || values.count >= 128 {
                exceeded = true; stop.pointee = true
            } else if let match { values.append(match) }
        }
        guard !exceeded else { throw LiveCatchupError.invalidTemplate }
        return values
    }

    static func matches(_ pattern: String, text: String) throws -> Bool {
        guard pattern.utf8.count <= 1024, text.utf8.count <= 16384 else { throw LiveCatchupError.invalidTemplate }
        if pattern.isEmpty || text.contains(pattern) { return true }
        return !(try results(pattern, text: text)).isEmpty
    }

    static func replacing(_ pattern: String, in text: String, template: String) throws -> String {
        guard template.utf8.count <= 4096 else { throw LiveCatchupError.invalidTemplate }
        let matches = try results(pattern, text: text)
        let expression = try NSRegularExpression(pattern: pattern)
        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { throw LiveCatchupError.invalidTemplate }
            output.replaceSubrange(range, with: expression.replacementString(for: match, in: text, offset: 0, template: template))
            guard output.utf8.count <= 16384 else { throw LiveCatchupError.invalidTemplate }
        }
        return output
    }
}

public struct TVBoxEPGConfiguration: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var template: String
    public var timeZoneID: String
    public init(template: String, timeZoneID: String) { self.template = template; self.timeZoneID = timeZoneID }
    public var description: String { "TVBoxEPGConfiguration(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct LiveSourceDefaults: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var epg: String?
    public var timeZone: String?
    public var catchup: TVBoxCatchupConfiguration?
    public var header: [String: String]
    public var userAgent: String?
    public var referer: String?
    public var origin: String?

    public init(_ live: LiveConfiguration) {
        epg = live.epg; timeZone = live.timeZone; catchup = live.catchup
        header = live.header; userAgent = live.userAgent; referer = live.referer; origin = live.origin
    }

    func headers(channel: LiveChannelConfiguration? = nil, current: [String: String] = [:]) -> [String: String] {
        var result = current.isEmpty ? header : current
        let ua = channel != nil ? channel?.userAgent ?? userAgent : current["User-Agent"] ?? userAgent
        let ref = channel != nil ? channel?.referer ?? referer : current["Referer"] ?? referer
        let org = channel != nil ? channel?.origin ?? origin : current["Origin"] ?? origin
        if let ua { result["User-Agent"] = ua }
        if let ref { result["Referer"] = ref }
        if let org { result["Origin"] = org }
        return result
    }

    func epgConfiguration(channel: LiveChannelConfiguration) -> TVBoxEPGConfiguration? {
        let declared = channel.epg ?? ""
        let candidate: String?
        if declared.hasPrefix("http://") || declared.hasPrefix("https://") { candidate = declared }
        else {
            candidate = epg?.split(separator: ",").map(String.init).first(where: { $0.contains("{") })?
                .replacingOccurrences(of: "{epg}", with: Self.encoded(declared))
        }
        guard var candidate, !candidate.isEmpty else { return nil }
        candidate = candidate.replacingOccurrences(of: "{id}", with: Self.encoded(channel.tvgID ?? ""))
            .replacingOccurrences(of: "{name}", with: Self.encoded(channel.tvgName ?? channel.name))
        return .init(template: candidate, timeZoneID: timeZone ?? TimeZone.current.identifier)
    }

    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    var xmltvURL: URL? {
        epg?.split(separator: ",").map(String.init).filter { !$0.contains("{") }.compactMap(URL.init(string:)).first {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
        }
    }

    public var description: String { "LiveSourceDefaults(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A bounded local snapshot retains the original bytes and their declared
/// defaults together. Refresh and parser observations consume the same document.
public enum LiveSourceDocument {
    private struct Envelope: Codable {
        let okvideoLiveSource: Int
        let data: Data
        let defaults: LiveSourceDefaults
    }
    public static func attaching(_ defaults: LiveSourceDefaults, to data: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let output = try encoder.encode(Envelope(okvideoLiveSource: 1, data: data, defaults: defaults))
        guard output.count <= LiveSourceLoader.maximumSourceSize else { throw AppError.live("直播源及附加配置超过 32 MiB 限制") }
        return output
    }
    static func unwrap(_ data: Data) throws -> (Data, LiveSourceDefaults)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["okvideoLiveSource"] != nil else { return nil }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.okvideoLiveSource == 1, value.data.count <= LiveSourceLoader.maximumSourceSize,
              (try? JSONSerialization.jsonObject(with: value.data) as? [String: Any])?["okvideoLiveSource"] == nil else {
            throw AppError.live("直播源快照格式无效")
        }
        return (value.data, value.defaults)
    }
    public static func defaults(in data: Data) throws -> LiveSourceDefaults? { try unwrap(data)?.1 }
    public static func originalData(in data: Data) throws -> Data { try unwrap(data)?.0 ?? data }
}
