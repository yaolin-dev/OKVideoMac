import Foundation
import CFNetwork
import OKVideoCore

/// Both switches are local diagnostic rollbacks; no persistent provider changes.
enum NativeXtreamCompatibility {
    static var policy: PlaybackCompatibilityPolicy {
        UserDefaults.standard.bool(forKey: "player.disableNativeXtreamTransport")
            ? .existing : .nativeXtreamLive
    }
    // Separate rollback for the bounded HLS startup fallback.
    static var hlsFallbackEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "player.disableNativeXtreamHLSFallback")
    }
}

enum MediaProxyDecision: Equatable, Sendable {
    case direct
    case httpProxy(URL)
    /// Preserve the old environment-based transport for unsupported system types.
    case inherited(String)

    var diagnosticMode: String {
        switch self {
        case .direct: return "direct"
        case .httpProxy: return "http-proxy"
        case .inherited: return "legacy-unsupported-system-proxy"
        }
    }

    var mpvOptions: [(String, String)] {
        let proxy: String
        switch self {
        case .direct: proxy = ""
        case .httpProxy(let url): proxy = url.absoluteString.replacingOccurrences(of: ",", with: "%2C")
        case .inherited:
            return [("http-proxy", ""), ("stream-lavf-o", ""),
                    ("demuxer-lavf-o", ""), ("tls-verify", "yes")]
        }
        // mpv omits an empty http-proxy option when building the AV dictionary.
        // Explicit empty FFmpeg values suppress its environment proxy fallback.
        // Apply these as loadfile options so replacement, stop and failure all
        // restore the preceding values, including on a reused VOD player.
        return [("http-proxy", proxy), ("stream-lavf-o", "http_proxy=\(proxy)"),
                ("demuxer-lavf-o", "http_proxy=\(proxy)"), ("tls-verify", "yes")]
    }
}

/// mpv parses loadfile's option list separately from each nested lavf list.
/// Length quoting uses UTF-8 bytes and protects commas, percent signs and
/// quotes without changing the option value (including explicit empty values).
enum MPVFileOptionEncoder {
    static func encode(name: String, value: String) -> String {
        "\(name)=%\(value.utf8.count)%\(value)"
    }
}

enum PlayerMediaNetworkPolicy {
    static func usesSystemProxy(_ media: ResolvedMedia) -> Bool {
        media.networkPolicy == .systemHTTPProxy
            || media.compatibilityPolicy == .nativeXtreamLive
    }

    static func decision(for media: ResolvedMedia) -> MediaProxyDecision? {
        // The Android/CatPaw relay is local infrastructure. Explicitly clear
        // inherited FFmpeg proxy options even for provider-owned VOD routing.
        if ["http", "https"].contains(media.url.scheme?.lowercased() ?? ""),
           let host = media.url.host, SystemMediaProxyResolver.isLoopback(host) {
            return .direct
        }
        guard usesSystemProxy(media) else { return nil }
        return SystemMediaProxyResolver.resolve(
            for: media.hlsStartupSelection?.routingURL ?? media.url
        )
    }
}

enum SystemMediaProxyResolver {
    static func resolve(for url: URL) -> MediaProxyDecision {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
        return resolve(for: url, settings: settings as? [String: Any] ?? [:],
                       environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(for url: URL, settings: [String: Any],
                        environment: [String: String]) -> MediaProxyDecision {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { return .direct }
        if isLoopback(host) { return .direct }
        // FFmpeg still applies no_proxy to explicit proxies; report that choice
        // accurately for the entry URL. Nested URLs keep FFmpeg's own matching.
        if bypasses(host: host, list: environment["no_proxy"]) { return .direct }
        let entries = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary)
            .takeRetainedValue() as? [[String: Any]] ?? []
        if let first = entries.first,
           let type = first[kCFProxyTypeKey as String] as? String {
            if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
                guard let host = first[kCFProxyHostNameKey as String] as? String,
                      let port = first[kCFProxyPortNumberKey as String] as? Int,
                      !host.isEmpty, (1...65535).contains(port) else {
                    return .inherited("invalid-system-proxy")
                }
                var endpoint = URLComponents()
                endpoint.scheme = "http"; endpoint.host = host; endpoint.port = port
                guard let proxy = endpoint.url else { return .inherited("invalid-system-proxy") }
                return .httpProxy(proxy)
            }
            if type != kCFProxyTypeNone as String { return .inherited("unsupported-system-proxy") }
        }
        // An enabled system proxy may have explicitly bypassed this URL.
        if [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable,
            kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesProxyAutoConfigEnable,
            kCFNetworkProxiesProxyAutoDiscoveryEnable].contains(where: {
                (settings[$0 as String] as? NSNumber)?.boolValue == true
            }) { return .direct }
        if let raw = environment["http_proxy"], !raw.isEmpty {
            guard let proxy = URL(string: raw), proxy.scheme?.lowercased() == "http",
                  proxy.host != nil, proxy.query == nil, proxy.fragment == nil,
                  proxy.port.map({ (1...65535).contains($0) }) ?? true else {
                return .inherited("unsupported-environment-proxy")
            }
            return .httpProxy(proxy)
        }
        return .direct
    }

    static func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value == "localhost." || value == "::1"
            || value == "0:0:0:0:0:0:0:1" { return true }
        let ipv4 = value.hasPrefix("::ffff:") ? String(value.dropFirst(7)) : value
        let octets = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127"
            && octets.allSatisfy { UInt8($0) != nil }
    }

    static func bypasses(host: String, list: String?) -> Bool {
        guard let list else { return false }
        let host = host.lowercased()
        return list.split(whereSeparator: { $0 == "," || $0 == " " }).contains { item in
            if item == "*" { return true }
            var rule = String(item).lowercased()
            if rule.hasPrefix("*.") { rule.removeFirst(2) }
            if rule.hasPrefix(".") { rule.removeFirst() }
            return !rule.isEmpty && (host == rule || host.hasSuffix("." + rule))
        }
    }
}

/// URLRequest's timeout is an inactivity timeout. Bound the entire optional
/// preparation separately, including redirects and slow trickling responses.
enum NativeXtreamHLSPreparation {
    static func response(
        client: any HTTPClient, request: HTTPRequest,
        deadlineNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> HTTPResponse {
        try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask { try await client.send(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: deadlineNanoseconds)
                throw HTTPClientError.timeout
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }
}
