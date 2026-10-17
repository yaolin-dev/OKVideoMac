import Foundation

public enum XtreamEndpointError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedScheme
    case missingHost
    case embeddedCredentials
    case queryOrFragmentNotAllowed
    case invalidURL
    case invalidPathComponent

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            return "The Xtream server URL must use HTTP or HTTPS."
        case .missingHost:
            return "The Xtream server URL must include a host."
        case .embeddedCredentials:
            return "Do not include credentials in the Xtream server URL."
        case .queryOrFragmentNotAllowed:
            return "The Xtream server URL cannot include a query or fragment."
        case .invalidURL:
            return "The Xtream URL could not be constructed."
        case .invalidPathComponent:
            return "An Xtream resource identifier is invalid."
        }
    }
}

public struct XtreamEndpoint: Equatable, Sendable {
    public let serverURL: URL

    public init(serverURL: URL) throws {
        guard var components = URLComponents(
            url: serverURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamEndpointError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw XtreamEndpointError.unsupportedScheme
        }
        guard components.host?.isEmpty == false else {
            throw XtreamEndpointError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw XtreamEndpointError.embeddedCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw XtreamEndpointError.queryOrFragmentNotAllowed
        }

        components.scheme = scheme
        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let normalized = components.url else {
            throw XtreamEndpointError.invalidURL
        }
        self.serverURL = normalized
    }
}

public enum XtreamAction: String, CaseIterable, Sendable {
    case liveCategories = "get_live_categories"
    case liveStreams = "get_live_streams"
    case shortEPG = "get_short_epg"
    case simpleDataTable = "get_simple_data_table"
    case vodCategories = "get_vod_categories"
    case vodStreams = "get_vod_streams"
    case vodInfo = "get_vod_info"
    case seriesCategories = "get_series_categories"
    case series = "get_series"
    case seriesInfo = "get_series_info"
}

public enum XtreamMediaKind: String, Sendable {
    case live
    case movie
    case series

    var defaultContainerExtension: String {
        switch self {
        case .live: return "ts"
        case .movie, .series: return "mp4"
        }
    }
}

public struct XtreamURLBuilder: Sendable {
    public let endpoint: XtreamEndpoint

    public init(endpoint: XtreamEndpoint) {
        self.endpoint = endpoint
    }

    public func playerAPIURL(
        credentials: XtreamCredentials,
        action: XtreamAction? = nil,
        parameters: [URLQueryItem] = []
    ) throws -> URL {
        guard !parameters.contains(where: {
            let name = $0.name.lowercased()
            return name == "username" || name == "password" || name == "action"
        }) else {
            throw XtreamEndpointError.invalidURL
        }
        guard var components = URLComponents(
            url: endpoint.serverURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamEndpointError.invalidURL
        }
        components.percentEncodedPath = appending(
            encodedPathComponent: "player_api.php",
            to: components.percentEncodedPath
        )
        var queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action {
            queryItems.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        queryItems.append(contentsOf: parameters)
        components.queryItems = queryItems
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw XtreamEndpointError.invalidURL
        }
        return url
    }

    public func playbackURL(
        kind: XtreamMediaKind,
        remoteID: String,
        containerExtension: String?,
        credentials: XtreamCredentials
    ) throws -> URL {
        let identifier = try encodedPathComponent(remoteID)
        let username = try encodedPathComponent(credentials.username)
        let password = try encodedPathComponent(credentials.password)
        let extensionValue = normalizedContainerExtension(
            containerExtension,
            fallback: kind.defaultContainerExtension
        )
        guard var components = URLComponents(
            url: endpoint.serverURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamEndpointError.invalidURL
        }
        let pathComponents = [kind.rawValue, username, password, "\(identifier).\(extensionValue)"]
        components.percentEncodedPath = pathComponents.reduce(
            components.percentEncodedPath
        ) { path, component in
            appending(encodedPathComponent: component, to: path)
        }
        guard let url = components.url else {
            throw XtreamEndpointError.invalidURL
        }
        return url
    }

    public func archiveRequest(credentials: XtreamCredentials, streamID: String, outputFormat: String,
                               programme: EPGProgramme, offset: TimeInterval = 0, now: Date = Date(),
                               serverTimeZoneID: String?) throws -> XtreamArchiveRequest {
        guard ["ts", "m3u8"].contains(outputFormat) else { throw XtreamEndpointError.invalidPathComponent }
        let window = try XtreamArchivePolicy.window(programme: programme, offset: offset, now: now, timeZoneID: serverTimeZoneID)
        guard var rest = URLComponents(url: endpoint.serverURL, resolvingAgainstBaseURL: false),
              var legacy = URLComponents(url: endpoint.serverURL, resolvingAgainstBaseURL: false) else {
            throw XtreamEndpointError.invalidURL
        }
        let parts = ["timeshift", credentials.username, credentials.password, String(window.minutes),
                     window.time, streamID + "." + outputFormat]
        for part in parts { rest.percentEncodedPath = appending(encodedPathComponent: try encodedPathComponent(part), to: rest.percentEncodedPath) }
        for part in ["streaming", "timeshift.php"] {
            legacy.percentEncodedPath = appending(encodedPathComponent: part, to: legacy.percentEncodedPath)
        }
        legacy.queryItems = [.init(name: "username", value: credentials.username), .init(name: "password", value: credentials.password),
                             .init(name: "stream", value: streamID), .init(name: "start", value: window.time),
                             .init(name: "duration", value: String(window.minutes)), .init(name: "extension", value: outputFormat)]
        legacy.percentEncodedQuery = legacy.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = rest.url, let legacyURL = legacy.url else { throw XtreamEndpointError.invalidURL }
        return XtreamArchiveRequest(url: url, legacyURL: legacyURL, leadIn: window.leadIn, remainingDuration: window.remaining)
    }

    private func encodedPathComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XtreamEndpointError.invalidPathComponent
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw XtreamEndpointError.invalidPathComponent
        }
        return encoded
    }

    private func normalizedContainerExtension(
        _ value: String?,
        fallback: String
    ) -> String {
        let candidate = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased() ?? ""
        guard !candidate.isEmpty,
              candidate.count <= 16,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              }) else {
            return fallback
        }
        return candidate
    }

    private func appending(
        encodedPathComponent component: String,
        to path: String
    ) -> String {
        let prefix = path.isEmpty || path == "/"
            ? ""
            : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "/\(component)" : "/\(prefix)/\(component)"
    }
}
