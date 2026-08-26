import Foundation

/// The single semantic boundary for data that may cross from a live playback
/// session into durable storage.
///
/// Providers own refreshable resource locators. The host may persist only a
/// provider-attested stable locator; signed media URLs, bridge capabilities,
/// authorization material and replay-session state remain memory-only.
public enum PlaybackPersistencePolicy {
    private static let maximumLocatorByteCount = 4_096
    private static let maximumIdentityByteCount = 4_096
    private static let maximumHeaderValueByteCount = 512

    private static let sensitiveLocatorWords: Set<String> = [
        "api-key", "apikey", "auth", "authorization", "bearer", "cookie",
        "credential", "expire", "expired", "expires", "jwt", "key",
        "password", "passwd", "secret", "session", "sessionid", "sid",
        "sign", "signature", "signed", "stoken", "ticket", "timestamp",
        "token"
    ]

    private static let sensitiveLocatorFragments = [
        "accesstoken", "authorization", "clientsecret", "cookie",
        "password", "refreshtoken", "sessionid", "signature", "stoken",
        "token"
    ]

    /// Keeps only a local file URL. Network URLs and localhost bridge
    /// capabilities are deliberately not durable playback references.
    public static func sanitizedMediaReference(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue, maximumByteCount: maximumLocatorByteCount),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "file",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedQuery == nil,
              components.host?.isEmpty != false,
              let url = components.url,
              url.isFileURL,
              !url.path.isEmpty,
              !containsControlCharacter(url.path) else {
            return nil
        }
        return url.standardizedFileURL.absoluteString
    }

    /// Accepts a deliberately narrow, URL-free opaque locator alphabet.
    /// JSON (including base64/base64url JSON) and credential-shaped values
    /// are rejected before persistence.
    public static func sanitizedOpaqueLocator(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue, maximumByteCount: maximumLocatorByteCount),
              URLComponents(string: value)?.scheme == nil,
              !looksLikeJSON(value),
              !looksLikeBase64JSON(value),
              !containsSensitiveLocatorWord(value),
              value.unicodeScalars.allSatisfy(isAllowedLocatorScalar) else {
            return nil
        }
        return value
    }

    /// A provider reference is durable only when the provider explicitly
    /// attests stability, supplies a safe opaque locator and does not attach
    /// expiry metadata.
    public static func sanitizedProviderResourceReference(
        _ reference: PlaybackResourceReference?
    ) -> PlaybackResourceReference? {
        guard let reference,
              reference.stability == .providerStable,
              reference.expiresAt == nil,
              reference.schemaVersion > 0,
              reference.providerVersion >= 0,
              sanitizedMetadata(reference.configurationIdentity) != nil,
              sanitizedMetadata(reference.siteIdentity) != nil,
              sanitizedMetadata(reference.providerKind) != nil,
              sanitizedMetadata(reference.sourceIdentity) != nil,
              sanitizedMetadata(reference.episodeIdentity) != nil,
              let locator = sanitizedOpaqueLocator(
                  reference.stableResourceLocator
              ), locator == reference.stableResourceLocator else {
            return nil
        }
        // Node provider locators cross a third-party runtime boundary and may
        // be JWTs or refresh tokens despite being labelled "stable". Persist
        // only the secret-free Quark share/file identity. Legacy nhr1/npr1
        // handles depended on host replay storage and are intentionally dead.
        if reference.providerKind == "node-http-spider" {
            guard locator.hasPrefix("qhr1.") else {
                return nil
            }
        }
        return reference
    }

    /// Structural history identities are non-secret digests/opaque IDs. A
    /// value that looks like a URL, structured payload or credential is not a
    /// valid durable identity.
    public static func sanitizedPlaybackIdentity(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue, maximumByteCount: maximumIdentityByteCount),
              let safeValue = sanitizedOpaqueLocator(value) else {
            return nil
        }
        return safeValue
    }

    /// Only a bounded User-Agent is retained. Authorization, Cookie, Referer,
    /// Origin and all provider-specific headers must be reacquired at refresh.
    public static func sanitizedReplayHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        guard let rawValue = headers.first(where: {
            $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
        })?.value,
              let value = trimmed(
                  rawValue,
                  maximumByteCount: maximumHeaderValueByteCount
              ),
              !containsSensitiveHeaderValue(value) else {
            return [:]
        }
        return ["User-Agent": value]
    }

    public static func sanitizedReplayHeaders(
        _ headers: HTTPHeaders
    ) -> HTTPHeaders {
        HTTPHeaders(sanitizedReplayHeaders(headers.dictionary))
    }

    private static func sanitizedMetadata(_ rawValue: String) -> String? {
        guard let value = trimmed(rawValue, maximumByteCount: maximumIdentityByteCount),
              value == rawValue else {
            return nil
        }
        return value
    }

    private static func trimmed(
        _ rawValue: String?,
        maximumByteCount: Int
    ) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumByteCount,
              !containsControlCharacter(value) else {
            return nil
        }
        return value
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func isAllowedLocatorScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 45, 46, 47, 95, 126: // - . / _ ~
            return true
        default:
            return false
        }
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        guard value.first == "{" || value.first == "[",
              let data = value.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func looksLikeBase64JSON(_ value: String) -> Bool {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else {
            return false
        }
        return looksLikeJSON(
            decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func containsSensitiveLocatorWord(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if sensitiveLocatorFragments.contains(where: lowercased.contains) {
            return true
        }
        let words = lowercased.split { character in
            character == "-" || character == "." || character == "/"
                || character == "_" || character == "~"
        }
        return words.contains { sensitiveLocatorWords.contains(String($0)) }
    }

    private static func containsSensitiveHeaderValue(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return [
            "authorization", "bearer ", "cookie=", "cookie:",
            "password=", "secret=", "signature=", "stoken=", "token="
        ].contains(where: lowercased.contains)
    }
}
