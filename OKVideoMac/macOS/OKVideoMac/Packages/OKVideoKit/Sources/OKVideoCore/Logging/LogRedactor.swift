import Foundation

public enum LogRedactor {
    private static let sensitiveKeys: Set<String> = [
        "token", "accesstoken", "refreshtoken", "authtoken", "xauthtoken",
        "auth", "authorization", "proxyauthorization", "cookie", "setcookie",
        "stoken", "signature", "sign", "requestkey", "key", "secret",
        "password", "passwd", "pwd", "session", "sessionid", "sid",
        "uidtoken", "jwt", "code", "ticket", "credential", "apikey",
        "xapikey"
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

    public static func json(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                if isSensitive(key) {
                    return (key, "<redacted>" as Any)
                }
                return (key, json(value))
            })
        case let array as [Any]:
            return array.map(json)
        case let string as String:
            return sanitizeScalarText(string)
        default:
            return value
        }
    }

    public static func jsonData(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: json(object),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func text(_ text: String) -> String {
        if let data = text.data(using: .utf8),
           let sanitized = jsonData(data),
           let value = String(data: sanitized, encoding: .utf8) {
            return value
        }
        return sanitizeScalarText(text)
    }

    public static func path(_ path: String) -> String {
        replacingHomePaths(in: path)
    }

    private static func sanitizeScalarText(_ text: String) -> String {
        var output = replacingHomePaths(in: text)
        output = replacingMatches(
            in: output,
            pattern: #"(?im)\b(authorization|proxy-authorization|cookie|set-cookie|x-auth-token|x-api-key|api-key|x-request-key)\s*:\s*[^\r\n]+"#,
            template: "$1: <redacted>"
        )
        output = replacingMatches(
            in: output,
            pattern: #"(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|uid[_-]?token|token|auth|authorization|cookie|stoken|signature|sign|request[_-]?key|api[_-]?key|password|passwd|pwd|secret|credential|session(?:id)?|sid|jwt|code|ticket)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^&\s,;}]+)"#,
            template: "$1<redacted>"
        )
        output = replacingURLs(in: output)
        return output
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeys.contains(normalized)
            || normalized.contains("token")
            || normalized.contains("password")
            || normalized.contains("credential")
            || normalized.contains("secret")
            || normalized.contains("cookie")
            || normalized.contains("signature")
            || normalized.contains("requestkey")
    }

    private static func replacingURLs(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s<>\"']+"#,
            options: [.caseInsensitive]
        ) else { return text }
        var output = text
        let matches = regex.matches(
            in: output,
            range: NSRange(output.startIndex..., in: output)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let candidate = String(output[range])
            guard let parsed = URL(string: candidate) else { continue }
            output.replaceSubrange(range, with: url(parsed))
        }
        return output
    }

    private static func replacingHomePaths(in text: String) -> String {
        replacingMatches(
            in: text,
            pattern: #"/Users/[^/\s\"']+"#,
            template: "<HOME>"
        )
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
