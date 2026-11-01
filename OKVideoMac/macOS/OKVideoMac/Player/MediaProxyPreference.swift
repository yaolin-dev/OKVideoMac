import CFNetwork
import Foundation
import OKVideoCore

enum MediaProxyPreference {
    static let key = "player.mediaUsesSystemProxy"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Captured once per load; no endpoint or routing state is saved in history.
struct MediaPlaybackNetworkPlan {
    static let bridgeHeader = "X-OKVideo-Media-Network"
    let enabled: Bool?
    let decision: MediaProxyDecision?
    let route: PlaybackMediaNetworkRoute
    let bridgePolicy: String?

    static func current(for media: ResolvedMedia) -> Self {
        let enabled = media.mediaProxyPreference ?? MediaProxyPreference.enabled
        let settings = enabled ? CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:] : [:]
        return make(media: media, enabled: enabled, settings: settings)
    }

    static func make(media: ResolvedMedia, enabled: Bool, settings: [String: Any]) -> Self {
        let url = media.url
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return Self(enabled: enabled, decision: nil, route: url.isFileURL ? .localFile : .otherProtocol, bridgePolicy: nil)
        }
        let local = SystemMediaProxyResolver.isLoopback(url.host ?? "")
        let bridge = local && url.port == 19978 && (url.path.hasPrefix("/proxy/media/")
            || url.path.hasPrefix("/v1/media-sessions/") || url.path == "/v1/media")
        // Only /v1/media is a host-owned remote fetch. Session URLs usually
        // wrap opaque source downloads; the local first hop proves no route.
        let remoteBridge = bridge && url.path == "/v1/media"
        let nestedURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value
        let routingURL = remoteBridge ? nestedURL.flatMap { URL(string: $0) } : nil
        let decision: MediaProxyDecision
        if local && !remoteBridge { decision = .direct }
        else if !enabled { decision = .direct }
        else { decision = systemDecision(for: routingURL ?? media.hlsStartupSelection?.routingURL ?? url, settings: settings) }
        let route: PlaybackMediaNetworkRoute
        if local && !remoteBridge { route = .providerManaged }
        else {
            switch decision {
            case .direct: route = .direct
            case .httpProxy: route = .systemProxy
            case .inherited: route = .unsupportedProxy
            }
        }
        return Self(enabled: enabled, decision: local ? .direct : decision,
            route: media.mediaNetworkRouteOverride ?? route, bridgePolicy: bridge ? bridgeConfiguration(enabled: enabled, settings: settings) : nil)
    }

    static func systemDecision(for url: URL, settings: [String: Any]) -> MediaProxyDecision {
        // PAC/SOCKS need a separate transport implementation. Never silently
        // fall back to an unrelated process-level http_proxy endpoint.
        if flag(settings, "ProxyAutoConfigEnable") || flag(settings, "ProxyAutoDiscoveryEnable") {
            return .inherited("unsupported-pac")
        }
        let prefix = url.scheme?.lowercased() == "https" ? "HTTPS" : "HTTP"
        if flag(settings, prefix + "Enable") {
            guard let host = settings[prefix + "Proxy"] as? String, !host.isEmpty,
                  let port = settings[prefix + "Port"] as? Int, (1...65535).contains(port) else {
                return .inherited("invalid-system-proxy")
            }
        }
        return SystemMediaProxyResolver.resolve(for: url, settings: settings, environment: [:])
    }

    func validate() throws {
        if route == .unsupportedProxy {
            throw AppError.playback(L10n.string("player.network.unsupported", fallback: "The current system proxy type is not supported for media. HTTP/HTTPS proxies are supported. Turn off Use System Proxy for Media to connect directly."))
        }
    }

    func headers(_ original: HTTPHeaders) -> HTTPHeaders {
        // Provider headers cannot opt into internal routing or leak this
        // control header to a remote CDN on a following playback.
        HTTPHeaders(original.dictionary.filter { $0.key.caseInsensitiveCompare(Self.bridgeHeader) != .orderedSame })
    }

    private static func flag(_ settings: [String: Any], _ name: String) -> Bool {
        (settings[name] as? NSNumber)?.boolValue == true
    }

    static func bridgeConfiguration(enabled: Bool, settings: [String: Any]) -> String {
        var value: [String: Any] = ["version": 1, "enabled": enabled]
        if enabled {
            value["unsupported"] = flag(settings, "ProxyAutoConfigEnable") || flag(settings, "ProxyAutoDiscoveryEnable")
            value["socks"] = flag(settings, "SOCKSEnable")
            value["exceptions"] = settings["ExceptionsList"] as? [String] ?? []
            value["excludeSimple"] = flag(settings, "ExcludeSimpleHostnames")
            for (scheme, prefix) in [("http", "HTTP"), ("https", "HTTPS")] {
                guard flag(settings, prefix + "Enable") else { continue }
                guard var host = settings[prefix + "Proxy"] as? String,
                      let port = settings[prefix + "Port"] as? Int, (1...65535).contains(port), !host.isEmpty else {
                    value["unsupported"] = true; continue
                }
                // The emulator's host-loopback alias, not the guest itself.
                if SystemMediaProxyResolver.isLoopback(host) { host = "10.0.2.2" }
                value[scheme] = ["host": host, "port": port]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))?.base64EncodedString() ?? ""
    }
}

/// Configure an independent bridge capability before loading the player.
/// Routing configuration travels only over the local control API, never in
/// mpv's reusable headers (which also reach redirects and absolute HLS URLs).
enum MediaBridgeNetworkPreparation {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()

    static func prepare(_ media: ResolvedMedia, plan suppliedPlan: MediaPlaybackNetworkPlan? = nil,
                        send: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> ResolvedMedia {
        let plan = suppliedPlan ?? MediaPlaybackNetworkPlan.current(for: media)
        try plan.validate()
        var prepared = media
        prepared.mediaProxyPreference = plan.enabled
        guard let policy = plan.bridgePolicy else { return prepared }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19978/v1/media-network")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": media.url.absoluteString,
            "policy": policy, "headers": plan.headers(media.headers).dictionary,
            // mpv keeps the request side open while receiving media. Opt in
            // on this independent capability, never via reusable HTTP headers.
            "cancelOnDisconnect": true])
        let data: Data
        let response: URLResponse
        if let send { (data, response) = try await send(request) }
        else { (data, response) = try await session.data(for: request) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, let path = object["path"] as? String,
              path.range(of: #"^/proxy/media/[a-fA-F0-9-]{36}$"#, options: .regularExpression) != nil,
              let url = URL(string: "http://127.0.0.1:19978" + path) else {
            throw AppError.playback(L10n.string("player.network.bridge-failed", fallback: "Unable to apply the media network setting. Retry playback."))
        }
        prepared.url = url
        prepared.mediaNetworkRouteOverride = plan.route
        return prepared
    }
}

extension PlaybackMediaNetworkRoute {
    var title: String {
        switch self {
        case .direct: return L10n.string("player.network.direct", fallback: "Direct Connection")
        case .systemProxy: return L10n.string("player.network.system", fallback: "System Proxy")
        case .providerManaged: return L10n.string("player.network.provider", fallback: "Managed by Source (Local Relay)")
        case .unsupportedProxy: return L10n.string("player.network.unsupported-short", fallback: "Unsupported System Proxy")
        case .localFile: return L10n.string("player.network.local", fallback: "Local File")
        case .otherProtocol: return L10n.string("player.network.other", fallback: "Protocol Does Not Use HTTP Proxy")
        }
    }
}
