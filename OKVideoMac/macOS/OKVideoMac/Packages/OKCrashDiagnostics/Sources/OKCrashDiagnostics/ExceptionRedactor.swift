import Foundation

enum ExceptionRedactor {
    static func name(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 128,
              value.range(of: #"^[A-Za-z_][A-Za-z0-9_.$]*$"#, options: .regularExpression) != nil else {
            return "NSException"
        }
        return value
    }

    /// Preserve diagnostic wording, while removing common variable user content.
    /// The unchanged native report remains in the private, bounded local archive only.
    static func reason(_ value: String) -> String {
        var result = String(value.prefix(8192))
        let rules: [(String, String)] = [
            (#"(?i)\b(?:set-cookie|cookie)[ \t]*:[ \t]*[^\r\n]+"#, "[CREDENTIAL]"),
            (#"(?i)\b(?:authorization|proxy-authorization)[ \t]*[:=][ \t]*(?:bearer|basic)[ \t]+[^\s,;<>\"']+"#, "[CREDENTIAL]"),
            (#"(?i)\b(?:authorization|bearer|password|passwd|token|secret|api[_-]?key|cookie)[ \t]*(?:[:=][ \t]*|[ \t]+)(?:\"[^\"]*\"|'[^']*'|[^\s,;<>]+)"#, "[CREDENTIAL]"),
            (#"[\x00-\x1F\x7F]"#, " "),
            (#"(?i)\b(?:https?|file|ftp|smb|rtsp|rtmp)://[^\s<>\"']+"#, "[URL]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[EMAIL]"),
            (#"(?<![A-Za-z0-9])/(?:Users|Volumes|private|var|tmp|Applications|Library|System|home|mnt)/[^\s<>\"']*"#, "[PATH]"),
            (#"(?i)\b[A-Z]:\\[^\s<>\"']+"#, "[PATH]"),
            (#"\"[^\"]*\"|'[^']*'"#, "[QUOTED]"),
            (#"<([A-Za-z_][A-Za-z0-9_.$]*)[^>]*>"#, "<$1>"),
            (#"0x[0-9A-Fa-f]+"#, "[ADDRESS]")
        ]
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(result.prefix(2048))
    }
}
