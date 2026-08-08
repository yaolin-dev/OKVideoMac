import Foundation

public struct ConfigurationPolicyHTTPClient: HTTPClient {
    private let base: HTTPClient
    private let rules: [HeaderRuleConfiguration]

    public init(base: HTTPClient, rules: [HeaderRuleConfiguration]) {
        self.base = base
        self.rules = rules
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var configured = request
        var policyHeaders = HTTPHeaders()
        for rule in rules where Self.matches(host: request.url.host, pattern: rule.host) {
            policyHeaders = policyHeaders.merging(HTTPHeaders(rule.headerDictionary))
        }
        configured.headers = configured.headers.merging(policyHeaders)
        return try await base.send(configured)
    }

    private static func matches(host: String?, pattern: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let pattern = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst())
            return host.hasSuffix(suffix) || host == String(pattern.dropFirst(2))
        }
        if host == pattern { return true }
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(host.startIndex..., in: host)
        return regex.firstMatch(in: host, range: range)?.range == range
    }
}
