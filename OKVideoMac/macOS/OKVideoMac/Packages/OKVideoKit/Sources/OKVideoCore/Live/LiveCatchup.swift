import Foundation

public enum LiveCatchupSeekPolicy: String, Codable, Sendable {
    case native, request, unavailable
}

/// Provider configuration is private source data. Its diagnostic representation
/// must never reveal a template (which can contain account credentials).
public struct LiveCatchupConfiguration: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var mode: String
    public var template: String
    public var retentionDays: Double?
    public var correctionSeconds: TimeInterval
    public var timeZoneID: String
    public var supportsStartOver: Bool
    public var seekPolicy: LiveCatchupSeekPolicy

    public init(mode: String, template: String, retentionDays: Double? = nil,
                correctionSeconds: TimeInterval = 0, timeZoneID: String = "UTC",
                supportsStartOver: Bool = false, seekPolicy: LiveCatchupSeekPolicy = .native) {
        self.mode = mode.lowercased()
        self.template = template
        self.retentionDays = retentionDays
        self.correctionSeconds = correctionSeconds
        self.timeZoneID = timeZoneID
        self.supportsStartOver = supportsStartOver
        self.seekPolicy = seekPolicy
    }

    public static func m3u(attributes: [String: String]) -> Self? {
        guard let mode = attributes["catchup"], !mode.isEmpty else { return nil }
        return Self(mode: mode, template: attributes["catchup-source"] ?? "",
            retentionDays: attributes["catchup-days"].map { Double($0) ?? 0 },
            correctionSeconds: (attributes["catchup-correction"].map { Double($0) ?? .infinity } ?? 0) * 3600,
            timeZoneID: attributes["catchup-timezone"] ?? "UTC",
            supportsStartOver: attributes["catchup-startover"] == "true",
            seekPolicy: attributes["catchup-seek"].flatMap(LiveCatchupSeekPolicy.init(rawValue:)) ?? .native)
    }

    public var description: String { "LiveCatchupConfiguration(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum LiveCatchupAvailability: Equatable, Sendable {
    case available, current, future, expired, unsupported, invalidConfiguration, invalidProgramme
}

public enum LiveCatchupError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(LiveCatchupAvailability), invalidTemplate, invalidURL, invalidOffset
    public var errorDescription: String? { "The selected programme could not be requested as catch-up." }
}

public struct LiveCatchupRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let programme: EPGProgramme
    public let offset: TimeInterval
    public let remainingDuration: TimeInterval
    public var description: String { "LiveCatchupRequest(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum LiveCatchupPolicy {
    public static func availability(configuration: LiveCatchupConfiguration?, programme: EPGProgramme,
                                    now: Date) -> LiveCatchupAvailability {
        let safeDates = [programme.start, programme.end, now].allSatisfy {
            $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970)
        }
        guard safeDates, programme.start < programme.end else { return .invalidProgramme }
        if programme.start > now { return .future }
        guard let configuration else { return programme.end > now ? .current : .unsupported }
        guard ["default", "append"].contains(configuration.mode) else { return .unsupported }
        guard !configuration.template.isEmpty, configuration.correctionSeconds.isFinite,
              abs(configuration.correctionSeconds) <= 14 * 3600,
              TimeZone(identifier: configuration.timeZoneID) != nil else { return .invalidConfiguration }
        if let days = configuration.retentionDays {
            guard days.isFinite, days > 0, days <= 365 else { return .invalidConfiguration }
            if programme.start < now.addingTimeInterval(-days * 86400) { return .expired }
        }
        if programme.end > now && !configuration.supportsStartOver { return .current }
        guard programme.start < now else { return .current }
        guard let expanded = try? expand(configuration.template,
            start: programme.start.addingTimeInterval(configuration.correctionSeconds),
            end: min(programme.end, now).addingTimeInterval(configuration.correctionSeconds),
            now: now, timeZoneID: configuration.timeZoneID) else { return .invalidConfiguration }
        if configuration.mode == "default" {
            guard let url = URL(string: expanded), ["http", "https", "rtsp"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.fragment == nil else { return .invalidConfiguration }
        }
        return .available
    }

    public static func request(stream: LiveStream, programme: EPGProgramme, now: Date,
                               offset: TimeInterval = 0) throws -> LiveCatchupRequest {
        let availability = availability(configuration: stream.effectiveCatchup, programme: programme, now: now)
        guard availability == .available, let config = stream.effectiveCatchup else { throw LiveCatchupError.unavailable(availability) }
        guard let liveURL = stream.url, !stream.needsParsing else { throw LiveCatchupError.invalidURL }
        let end = min(programme.end, now)
        let duration = end.timeIntervalSince(programme.start)
        guard offset.isFinite, offset >= 0, offset < duration else { throw LiveCatchupError.invalidOffset }
        let start = programme.start.addingTimeInterval(offset + config.correctionSeconds)
        let correctedEnd = end.addingTimeInterval(config.correctionSeconds)
        let template = config.mode == "append" ? liveURL.absoluteString + config.template : config.template
        let value = try expand(template, start: start, end: correctedEnd, now: now, timeZoneID: config.timeZoneID)
        guard let url = URL(string: value), ["http", "https", "rtsp"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.fragment == nil else { throw LiveCatchupError.invalidURL }
        return LiveCatchupRequest(url: url, programme: programme, offset: offset, remainingDuration: duration - offset)
    }

    /// Only the documented M3U date fields are interpreted. Unsupported tokens
    /// fail before networking; a static/live URL cannot masquerade as a replay.
    private static let tokenExpression = try! NSRegularExpression(pattern: #"\$?\{([^{}]+)\}"#)

    private static func expand(_ template: String, start: Date, end: Date, now: Date,
                               timeZoneID: String) throws -> String {
        guard template.count <= 16384, let timeZone = TimeZone(identifier: timeZoneID) else { throw LiveCatchupError.invalidTemplate }
        let matches = tokenExpression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        guard !matches.isEmpty else { throw LiveCatchupError.invalidTemplate }
        var result = template
        var hasStart = false
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: template),
                  let replacementRange = Range(match.range, in: result) else { throw LiveCatchupError.invalidTemplate }
            let components = template[tokenRange].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(components[0]); let argument = components.count == 2 ? String(components[1]) : nil
            let value: String
            let date: Date?
            switch key {
            case "utc", "start": date = start; hasStart = true
            case "utcend", "end": date = end
            case "lutc", "now", "timestamp": date = now
            default: date = nil
            }
            if let date {
                value = try argument.map { try formatted(date, pattern: $0, timeZone: timeZone) }
                    ?? String(Int64(date.timeIntervalSince1970.rounded(.down)))
            } else if ["Y", "m", "d", "H", "M", "S"].contains(key), argument == nil {
                value = try formatted(start, pattern: key, timeZone: timeZone); hasStart = true
            } else if key == "duration" || key == "offset" {
                let divisor = argument.flatMap(Int.init) ?? (argument == nil ? 1 : 0)
                guard divisor > 0 else { throw LiveCatchupError.invalidTemplate }
                let seconds = key == "duration" ? end.timeIntervalSince(start) : now.timeIntervalSince(start)
                guard seconds.isFinite, seconds >= 0 else { throw LiveCatchupError.invalidTemplate }
                value = String(Int64((seconds / Double(divisor)).rounded(.down)))
                if key == "offset" { hasStart = true }
            } else { throw LiveCatchupError.invalidTemplate }
            result.replaceSubrange(replacementRange, with: value)
        }
        guard hasStart, !result.contains("{"), !result.contains("}"),
              !result.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else { throw LiveCatchupError.invalidTemplate }
        return result
    }

    private static func formatted(_ date: Date, pattern: String, timeZone: TimeZone) throws -> String {
        guard !pattern.isEmpty, pattern.count <= 64 else { throw LiveCatchupError.invalidTemplate }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let values: [Character: String] = ["Y": String(format: "%04d", fields.year ?? 0),
            "m": String(format: "%02d", fields.month ?? 0), "d": String(format: "%02d", fields.day ?? 0),
            "H": String(format: "%02d", fields.hour ?? 0), "M": String(format: "%02d", fields.minute ?? 0),
            "S": String(format: "%02d", fields.second ?? 0)]
        var output = ""
        for char in pattern {
            if let value = values[char] { output += value }
            else if "-_:T.".contains(char) { output.append(char) }
            else { throw LiveCatchupError.invalidTemplate }
        }
        return output
    }
}
