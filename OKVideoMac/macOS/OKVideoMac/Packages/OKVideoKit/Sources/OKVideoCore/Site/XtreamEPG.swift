import Foundation

/// Tolerant wire decoder, deliberately not Codable/persisted. Only normalized
/// title/time metadata leaves this boundary; native IDs belong to the request.
struct XtreamEPGResponse {
    let rows: [[String: Any]]

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [Any], array.isEmpty { rows = []; return }
        guard let object = object as? [String: Any],
              let values = object["epg_listings"] as? [Any], values.count <= 1000 else {
            throw EPGFetchError.malformed
        }
        rows = values.compactMap { $0 as? [String: Any] }
        if !values.isEmpty && rows.isEmpty { throw EPGFetchError.malformed }
    }

    var requiresServerTimezone: Bool {
        rows.contains { timestamp($0["start_timestamp"]) == nil || endTimestamp($0) == nil }
    }

    func payload(streamID: String, timezone: TimeZone?, secrets: [String]) throws -> EPGPayload {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        var programmes: [EPGProgramme] = []
        var seen = Set<Date>()
        for row in rows {
            try Task.checkCancellation()
            if let remote = row["stream_id"], String(describing: remote) != streamID { continue }
            let start = timestamp(row["start_timestamp"])
                ?? (timezone == nil ? nil : (row["start"] as? String).flatMap(formatter.date(from:)))
            let end = endTimestamp(row)
                ?? (timezone == nil ? nil : (row["end"] as? String).flatMap(formatter.date(from:)))
            guard let start, let end, start < end, end.timeIntervalSince(start) <= 7 * 86400,
                  let rawTitle = row["title"] as? String else { continue }
            var title = rawTitle
            if let bytes = Data(base64Encoded: rawTitle), let decoded = String(data: bytes, encoding: .utf8),
               !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) {
                title = decoded
            }
            title = LogRedactor.text(title)
            for secret in secrets where !secret.isEmpty { title = title.replacingOccurrences(of: secret, with: "<redacted>") }
            title = boundedUTF8(title.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 4096)
            guard !title.isEmpty, seen.insert(start).inserted else { continue }
            let archive: Bool?
            if let value = row["has_archive"] as? NSNumber { archive = value.doubleValue == 1 ? true : (value.doubleValue == 0 ? false : nil) }
            else if let value = row["has_archive"] as? String { archive = ["1", "true"].contains(value.lowercased()) ? true : (["0", "false"].contains(value.lowercased()) ? false : nil) }
            else { archive = nil }
            programmes.append(EPGProgramme(channelID: streamID, title: title, start: start, end: end, catchupAvailable: archive))
        }
        // Invalid nonempty data must not replace a previous valid schedule.
        if !rows.isEmpty && programmes.isEmpty { throw EPGFetchError.malformed }
        return EPGPayload(guide: XMLTVGuide(channels: [], programmes: programmes.sorted { $0.start < $1.start }))
    }

    private func timestamp(_ value: Any?) -> Date? {
        let number: Double?
        if let text = value as? String { number = Double(text) }
        else if let value = value as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else { number = nil }
        guard let number, number.isFinite, number > 0, number < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: number)
    }

    private func endTimestamp(_ row: [String: Any]) -> Date? {
        timestamp(row["stop_timestamp"]) ?? timestamp(row["end_timestamp"])
    }

    private func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}

public enum XtreamEPGAdapter {
    public static func fetch(configuration: XtreamProviderConfiguration, streamID: String,
                             credentialStore: any XtreamCredentialStoring,
                             httpClient: HTTPClient, userAgent: String, archive: Bool = false) async throws -> EPGPayload {
        guard let credentials = try await credentialStore.credentials(for: configuration.providerID) else {
            throw EPGFetchError.unavailable
        }
        try Task.checkCancellation()
        let client = XtreamClient(endpoint: try XtreamEndpoint(serverURL: configuration.serverBaseURL),
                                  credentials: credentials, httpClient: httpClient, userAgent: userAgent,
                                  maximumConcurrentRequests: 1)
        if archive {
            let value = try await client.archiveEPG(streamID: streamID)
            if !value.unsupported { return value }
        }
        return try await client.shortEPG(streamID: streamID)
    }
}
