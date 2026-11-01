import Foundation
import OKVideoCore

enum PlayerTrackPresentation {
    static func label(_ track: MediaTrack) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = track.type == .audio ? #"(?i)^audio(?:\s+track)?\s*#?\d*$"# : #"(?i)^(?:sub|subtitle)(?:\s+track)?\s*#?\d*$"#
        let generic = title.isEmpty || title.range(of: pattern, options: .regularExpression) != nil
        let label = generic
            ? L10n.string(track.type == .audio ? "player.audio.number" : "player.subtitle.number",
                          fallback: track.type == .audio ? "Audio Track %d" : "Subtitle Track %d", track.id)
            : title
        guard let language = track.language, !language.isEmpty, language != "und" else { return label }
        return label + " · " + (Locale.current.localizedString(forLanguageCode: language) ?? language)
    }
}
