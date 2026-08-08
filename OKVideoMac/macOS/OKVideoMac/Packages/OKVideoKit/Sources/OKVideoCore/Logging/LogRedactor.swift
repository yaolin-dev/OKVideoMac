import Foundation

public enum LogRedactor {
    private static let sensitiveHeaderNames = [
        "authorization", "cookie", "set-cookie", "proxy-authorization",
        "token", "password", "secret", "api-key", "apikey"
    ]

    public static func headers(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key, isSensitive(key) ? "<redacted>" : value)
        })
    }

    public static func url(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return "<invalid-url>"
        }
        if components.user != nil || components.password != nil {
            components.user = "<redacted>"
            components.password = nil
        }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                isSensitive(item.name)
                    ? URLQueryItem(name: item.name, value: "<redacted>")
                    : item
            }
        }
        return components.string ?? url.absoluteString
    }

    public static func text(_ text: String) -> String {
        var output = text
        let pattern = #"(?i)(authorization|cookie|token|password|secret|api[-_]?key)\s*[:=]\s*([^&\s,;]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: "$1=<redacted>"
            )
        }
        return output
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveHeaderNames.contains { normalized.contains($0) }
    }
}
