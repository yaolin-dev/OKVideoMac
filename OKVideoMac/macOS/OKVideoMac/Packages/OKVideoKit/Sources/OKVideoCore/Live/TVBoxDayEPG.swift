import Foundation

public enum TVBoxDayEPG {
    public static let maximumResponseBytes = 256 * 1024

    public static func days(configuration: TVBoxEPGConfiguration, from start: Date, to end: Date) throws -> [String] {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start < end, end.timeIntervalSince(start) <= 24 * 3600,
              let zone = TimeZone(identifier: configuration.timeZoneID) else { throw EPGFetchError.malformed }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) else {
            throw EPGFetchError.malformed
        }
        let last = calendar.startOfDay(for: end.addingTimeInterval(-0.001))
        var result: [String] = []
        let formatter = dateFormatter(zone)
        while day <= last, result.count < 4 {
            result.append(formatter.string(from: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { throw EPGFetchError.malformed }
            day = next
        }
        guard day > last else { throw EPGFetchError.malformed }
        return result
    }

    public static func requestURL(configuration: TVBoxEPGConfiguration, day: String) throws -> URL {
        guard validDay(day, zone: TimeZone(secondsFromGMT: 0)!) != nil,
              configuration.template.contains("{date}"), configuration.template.utf8.count <= 16384 else {
            throw EPGFetchError.malformed
        }
        let value = configuration.template.replacingOccurrences(of: "{date}", with: day)
        guard !value.contains("{"), !value.contains("}"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.fragment == nil else { throw EPGFetchError.malformed }
        return url
    }

    public static func payload(data: Data, day: String, channelID: String,
                               configuration: TVBoxEPGConfiguration) throws -> EPGPayload {
        guard data.count <= maximumResponseBytes, !channelID.isEmpty, channelID.utf8.count <= 512,
              let zone = TimeZone(identifier: configuration.timeZoneID),
              let date = validDay(day, zone: zone),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["date"] as? String == day, let rows = object["epg_data"] as? [Any],
              rows.count <= 512 else { throw EPGFetchError.malformed }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var programmes: [EPGProgramme] = [], seen = Set<Date>()
        for raw in rows {
            try Task.checkCancellation()
            guard let row = raw as? [String: Any], let title = row["title"] as? String,
                  let begin = row["start"] as? String, let finish = row["end"] as? String,
                  let start = time(begin, on: date, calendar: calendar, policy: .first) else { continue }
            let candidates = [Calendar.RepeatedTimePolicy.first, .last].compactMap {
                time(finish, on: date, calendar: calendar, policy: $0)
            }.filter { $0 > start }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: date)
            let wraps = clockSeconds(finish).flatMap { finish in clockSeconds(begin).map { finish < $0 } } ?? false
            let end = candidates.min() ?? (wraps ? nextDay.flatMap {
                time(finish, on: $0, calendar: calendar, policy: .first)
            } : nil)
            let clean = LogRedactor.text(title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let end, end > start, end.timeIntervalSince(start) <= 26 * 3600,
                  begin != finish, !clean.isEmpty, clean.utf8.count <= 4096,
                  !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(start).inserted else { continue }
            programmes.append(.init(channelID: channelID, title: clean, start: start, end: end))
        }
        guard rows.isEmpty || !programmes.isEmpty else { throw EPGFetchError.malformed }
        return EPGPayload(guide: .init(channels: [], programmes: programmes.sorted { $0.start < $1.start }))
    }

    public static func fetch(configuration: TVBoxEPGConfiguration, day: String, channelID: String,
                             httpClient: HTTPClient) async throws -> EPGPayload {
        do {
            try Task.checkCancellation()
            let response = try await httpClient.send(.init(url: requestURL(configuration: configuration, day: day),
                timeout: 10, maximumResponseBytes: maximumResponseBytes, maximumRedirects: 3, retryPolicy: .none))
            if [404, 410].contains(response.statusCode) {
                return .init(guide: .init(channels: [], programmes: []), unsupported: true)
            }
            guard (200..<300).contains(response.statusCode) else { throw EPGFetchError.unavailable }
            return try payload(data: response.body, day: day, channelID: channelID, configuration: configuration)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw EPGFetchError.unavailable
        }
    }

    private static func dateFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"; f.isLenient = false; return f
    }
    private static func validDay(_ value: String, zone: TimeZone) -> Date? {
        guard value.utf8.count == 10 else { return nil }
        let f = dateFormatter(zone); f.dateFormat = "yyyy-MM-dd HH:mm"
        let text = value + " 12:00"
        guard let date = f.date(from: text), f.string(from: date) == text else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.startOfDay(for: date)
    }
    private static func clockSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + (parts.count == 3 ? parts[2] : 0)
    }
    private static func time(_ value: String, on day: Date, calendar: Calendar,
                             policy: Calendar.RepeatedTimePolicy) -> Date? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              let second = parts.count == 3 ? Int(parts[2]) : 0,
              (0...24).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        if hour == 24 {
            guard minute == 0, second == 0 else { return nil }
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        }
        var fields = calendar.dateComponents([.year, .month, .day], from: day)
        fields.hour = hour; fields.minute = minute; fields.second = second
        let value = calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
            matching: fields, matchingPolicy: .strict, repeatedTimePolicy: policy, direction: .forward)
        return value.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
    }
}

public struct EPGChannelDayResult: Sendable {
    public let token: EPGResultToken
    public let programmes: [EPGProgramme]
    public let availability: EPGAvailability
    public init(token: EPGResultToken, programmes: [EPGProgramme], availability: EPGAvailability) {
        self.token = token; self.programmes = programmes; self.availability = availability
    }
}
