import Foundation

public struct XtreamArchiveCapability: Codable, Hashable, Sendable {
    public let retentionDays: Int
    public init(retentionDays: Int) { self.retentionDays = retentionDays }
    public var isValid: Bool { (1...365).contains(retentionDays) }
}

public enum XtreamArchiveError: Error, Equatable, Sendable, LocalizedError {
    case invalidProgramme, invalidOffset, missingServerTimeZone, ambiguousServerTime
    public var errorDescription: String? {
        switch self {
        case .missingServerTimeZone: return "The server did not provide a usable archive timezone."
        case .ambiguousServerTime: return "The server's archive format cannot distinguish this repeated local time."
        default: return "The selected programme could not be requested as an archive."
        }
    }
}

public struct XtreamArchiveRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let legacyURL: URL
    public let leadIn: TimeInterval
    public let remainingDuration: TimeInterval
    public var description: String { "XtreamArchiveRequest(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum XtreamArchivePolicy {
    public static func availability(capability: XtreamArchiveCapability?, programme: EPGProgramme,
                                    now: Date) -> LiveCatchupAvailability {
        guard [programme.start, programme.end, now].allSatisfy({
            $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970)
        }), programme.start < programme.end else { return .invalidProgramme }
        if programme.start > now { return .future }
        if programme.end > now { return .current }
        guard let capability, capability.isValid, programme.catchupAvailable != false else { return .unsupported }
        if programme.start < now.addingTimeInterval(-Double(capability.retentionDays) * 86400) { return .expired }
        return .available
    }

    struct Window {
        let time: String
        let minutes: Int
        let leadIn: TimeInterval
        let remaining: TimeInterval
    }
    static func window(programme: EPGProgramme, offset: TimeInterval, now: Date,
                       timeZoneID: String?) throws -> Window {
        guard [programme.start, programme.end, now].allSatisfy({
            $0.timeIntervalSince1970.isFinite && (0...253402300799).contains($0.timeIntervalSince1970)
        }), programme.start < programme.end, programme.end <= now,
              programme.end.timeIntervalSince(programme.start) <= 7 * 86400 else { throw XtreamArchiveError.invalidProgramme }
        let duration = programme.end.timeIntervalSince(programme.start)
        guard offset.isFinite, offset >= 0, offset < duration else { throw XtreamArchiveError.invalidOffset }
        guard let timeZoneID, let zone = TimeZone(identifier: timeZoneID) else { throw XtreamArchiveError.missingServerTimeZone }
        let target = programme.start.addingTimeInterval(offset)
        let aligned = Date(timeIntervalSince1970: floor(target.timeIntervalSince1970 / 60) * 60)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: aligned)
        let before = calendar.startOfDay(for: aligned).addingTimeInterval(-1)
        let first = calendar.nextDate(after: before, matching: fields, matchingPolicy: .strict,
                                      repeatedTimePolicy: .first, direction: .forward)
        let last = calendar.nextDate(after: before, matching: fields, matchingPolicy: .strict,
                                     repeatedTimePolicy: .last, direction: .forward)
        if let first, let last, first != last { throw XtreamArchiveError.ambiguousServerTime }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        return Window(time: formatter.string(from: aligned),
                      minutes: max(1, Int(ceil(programme.end.timeIntervalSince(aligned) / 60))),
                      leadIn: target.timeIntervalSince(aligned), remaining: duration - offset)
    }

    public static func programmePosition(mediaPosition: TimeInterval, offset: TimeInterval,
                                         leadIn: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard mediaPosition.isFinite, offset.isFinite, leadIn.isFinite, duration.isFinite else { return 0 }
        return min(max(0, duration), max(max(0, offset), mediaPosition + offset - leadIn))
    }
}

extension LiveCatchupPolicy {
    public static func availability(stream: LiveStream, programme: EPGProgramme, now: Date) -> LiveCatchupAvailability {
        if case .provider = stream.target {
            return XtreamArchivePolicy.availability(capability: stream.archive, programme: programme, now: now)
        }
        return availability(configuration: stream.effectiveCatchup, programme: programme, now: now)
    }
}
