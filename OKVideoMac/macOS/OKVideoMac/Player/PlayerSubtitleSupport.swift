import CryptoKit
import Foundation
import OKVideoCore

struct PlayerSubtitlePreference: Codable, Equatable {
    var encoding: SubtitleTextEncoding = .automatic
    var fontStyle: SubtitleFontStyle = .original
}

/// Persist only opaque identities, never media/subtitle URLs or query tokens.
final class PlayerSubtitlePreferenceStore {
    private let defaults: UserDefaults
    private let storageKey = "playback.subtitleCompatibility.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func identity(media: String, external: String?, trackID: Int, title: String) -> String {
        let parts = external.map { ["external", media, $0] }
            ?? ["embedded", media, String(trackID), title]
        return opaqueIdentity(parts)
    }
    static func opaqueIdentity(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func mediaScope(_ media: ResolvedMedia?, requestID: UUID?) -> String {
        if let identity = media?.subtitlePreferenceIdentity { return identity }
        // A local relay can serve different episodes at the same URL. Without
        // a host-owned resource identity its settings last only this playback.
        if let host = media?.url.host?.lowercased(),
           host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") {
            return "session:" + (requestID?.uuidString ?? "unloaded")
        }
        return media?.url.absoluteString ?? "unloaded"
    }
    func preference(for key: String) -> PlayerSubtitlePreference {
        values()[key] ?? PlayerSubtitlePreference()
    }
    func save(_ preference: PlayerSubtitlePreference, for key: String) {
        var current = values()
        if current.count >= 500, current[key] == nil { current.removeValue(forKey: current.keys.sorted().first!) }
        if preference == PlayerSubtitlePreference() { current.removeValue(forKey: key) }
        else { current[key] = preference }
        if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: storageKey) }
    }
    private func values() -> [String: PlayerSubtitlePreference] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PlayerSubtitlePreference].self, from: data)) ?? [:]
    }
}

struct PlayerSubtitleDiagnostics {
    private(set) var fonts = Set<String>()
    private(set) var missingGlyphs = Set<String>()
    private(set) var charsets = Set<String>()
    var loadFailures = 0
    mutating func record(prefix: String, text: String) -> Bool {
        // Store a small whitelist of facts. Raw native messages can contain
        // signed URLs, local paths or subtitle dialogue and are never retained.
        if prefix == "sub/ass" {
            if text.contains("failed to find any fallback with glyph") || text.contains("not found in font for") {
                if let range = text.range(of: "0x[0-9A-Fa-f]{1,6}", options: .regularExpression), missingGlyphs.count < 64 {
                    return missingGlyphs.insert("U+" + text[range].dropFirst(2).uppercased()).inserted
                }
            } else if text.contains("fontselect:"), let value = text.components(separatedBy: ", ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                      value.range(of: "^[A-Za-z0-9_-]{1,96}$", options: .regularExpression) != nil, fonts.count < 32 {
                return fonts.insert(value).inserted
            }
        } else if prefix == "lavf", text.hasPrefix("Using subtitle charset: ") {
            let value = text.dropFirst("Using subtitle charset: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: "^[A-Za-z0-9_+-]{1,32}$", options: .regularExpression) != nil, charsets.count < 12 {
                return charsets.insert(value).inserted
            }
        }
        return false
    }
    func report(settings: PlayerSubtitleSettings, bundledFont: Bool) -> String {
        let facts: [String: Any] = [
            "schema": 1, "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "trackID": settings.trackID as Any? ?? NSNull(), "kind": settings.trackID == nil ? "none" : (settings.isExternal ? "external" : "embedded"),
            "codec": settings.codec ?? "unknown", "requestedEncoding": settings.encoding.rawValue,
            "fontMode": settings.fontStyle.rawValue, "bundledCJKFont": bundledFont,
            "observedCharsets": charsets.sorted(), "observedFonts": fonts.sorted(),
            "missingGlyphs": missingGlyphs.sorted(), "subtitleLoadFailures": loadFailures,
            "observationScope": "current playback; native logs cannot always identify individual tracks"
        ]
        return (try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

enum PlayerSubtitleFonts {
    static let family = "Noto Sans CJK SC"
    static var directory: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("SubtitleFonts/Fonts"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("NotoSansCJKsc-Regular.otf").path) else { return nil }
        return root
    }
}
