import Foundation
import OKVideoCore

/// Routes published by the CatPawOpen Node protocol. A missing capability in
/// publisher metadata is intentionally treated as unknown: older bundles do
/// not publish a manifest, but still implement these routes.
enum CatPawRoute: String, CaseIterable, Sendable {
    case initialize = "init"
    case home
    case homeVod
    case category
    case detail
    case search
    case play
    case support
    case action
    case directory = "dir"
    case file
    case proxy
}

enum CatPawRuntimeURLResolver {
    static func normalize(_ rawValue: String, baseURL: URL) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeToken = "js2p://_WEB_"
        if value.lowercased().hasPrefix(runtimeToken.lowercased()) {
            let suffix = String(value.dropFirst(runtimeToken.count))
            return append(suffix, to: baseURL)?.absoluteString ?? value
        }
        if value.hasPrefix("/spider/")
            || value.hasPrefix("/proxy/")
            || value.hasPrefix("/__okvideo/") {
            return append(value, to: baseURL)?.absoluteString ?? value
        }
        return value
    }

    private static func append(_ pathAndQuery: String, to baseURL: URL) -> URL? {
        guard let relative = URLComponents(string: pathAndQuery),
              var output = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        let basePath = output.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = relative.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        output.percentEncodedPath = [basePath, relativePath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        output.percentEncodedPath = "/" + output.percentEncodedPath
        // CatPaw proxy routes frequently carry an already-percent-encoded
        // upstream URL, token and Referer in the query. Assign the encoded
        // representation directly: treating the whole value as a path turns
        // `?` into `%3F` and double-encodes the nested media URL.
        output.percentEncodedQuery = relative.percentEncodedQuery
        output.percentEncodedFragment = relative.percentEncodedFragment
        return output.url
    }
}

enum CatPawRouteCapabilityState: String, Equatable, Sendable {
    case unknown
    case supported
    case unsupported
}

/// The identity deliberately includes the bundle and profile revision. Route
/// observations from one account/profile must never disable another runtime.
struct CatPawModuleIdentity: Hashable, Sendable {
    let value: String

    init(site: SiteConfiguration, fallbackSession: String? = nil) {
        if let identity = site.extra["okNodeSiteIdentity"]?.stringValue,
           !identity.isEmpty {
            value = identity
            return
        }
        // A hand-authored/legacy site has no reliable Bundle + Profile
        // identity. Sharing a negative route observation globally in that
        // case can disable an unrelated provider with the same site key.
        // Keep such observations local to the provider session instead.
        if let fallbackSession {
            value = [
                "legacy-session",
                fallbackSession,
                site.extra["okNodeModuleKind"]?.stringValue ?? "video",
                site.extra["okNodeModuleOriginalKey"]?.stringValue ?? site.key
            ].joined(separator: "|")
            return
        }
        value = [
            site.extra["okNodeBundleIdentity"]?.stringValue ?? "unknown-bundle",
            site.extra["okNodeProfileRevision"]?.stringValue ?? "unconfigured",
            site.extra["okNodeModuleKind"]?.stringValue ?? "video",
            site.extra["okNodeModuleOriginalKey"]?.stringValue ?? site.key
        ].joined(separator: "|")
    }
}

actor CatPawCapabilityRegistry {
    static let shared = CatPawCapabilityRegistry()

    private var states: [CatPawModuleIdentity: [CatPawRoute: CatPawRouteCapabilityState]] = [:]

    func state(
        of route: CatPawRoute,
        for identity: CatPawModuleIdentity
    ) -> CatPawRouteCapabilityState {
        states[identity]?[route] ?? .unknown
    }

    func recordSupported(
        _ route: CatPawRoute,
        for identity: CatPawModuleIdentity
    ) {
        states[identity, default: [:]][route] = .supported
    }

    func recordUnsupported(
        _ route: CatPawRoute,
        for identity: CatPawModuleIdentity
    ) {
        states[identity, default: [:]][route] = .unsupported
    }
}

private actor CatPawInitializationGate {
    private enum State {
        case initializing([CheckedContinuation<Void, Error>])
        case initialized
    }

    private var states: [String: State] = [:]

    func ensureInitialized(
        endpointKey: String,
        operation: () async throws -> Void
    ) async throws {
        switch states[endpointKey] {
        case .initialized:
            return
        case .initializing:
            try await withCheckedThrowingContinuation { continuation in
                guard case .initializing(var waiters) = states[endpointKey] else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                states[endpointKey] = .initializing(waiters)
            }
            return
        case nil:
            states[endpointKey] = .initializing([])
        }

        do {
            try await operation()
            let waiters = waiters(for: endpointKey)
            states[endpointKey] = .initialized
            waiters.forEach { $0.resume() }
        } catch {
            let waiters = waiters(for: endpointKey)
            states.removeValue(forKey: endpointKey)
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func waiters(
        for endpointKey: String
    ) -> [CheckedContinuation<Void, Error>] {
        guard case .initializing(let waiters) = states[endpointKey] else {
            return []
        }
        return waiters
    }
}

enum CatPawRouteError: Error, LocalizedError, Equatable {
    case unsupportedRoute(route: CatPawRoute, message: String)
    case invalidJSON(route: CatPawRoute)
    case httpStatus(route: CatPawRoute, statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRoute(_, let message):
            return message
        case .invalidJSON(let route):
            return "CatPaw \(route.rawValue) 响应不是有效 JSON"
        case .httpStatus(_, let statusCode, let message):
            return "HTTP \(statusCode)：\(message)"
        }
    }
}

struct CatPawPreparedInvocation: Sendable {
    let route: CatPawRoute
    let baseURL: URL
    let invocationID: String
    let request: HTTPRequest
}

struct CatPawRouteResponse: Sendable {
    let route: CatPawRoute
    let value: JSONValue
    let baseURL: URL
    let invocationID: String
    let statusCode: Int
    let headers: HTTPHeaders
}

/// Owns CatPaw route construction, per-runtime initialization, JSON decoding,
/// and route-capability observations. UI policy (authorization presentation,
/// sniffing, retry messages) remains above this transport layer.
final class CatPawRouteClient {
    private let moduleIdentity: CatPawModuleIdentity
    private let apiReference: String
    private let moduleName: String
    private let requestHeaders: HTTPHeaders
    private let timeout: TimeInterval
    private let httpClient: HTTPClient
    private let resolveRuntimeBaseURL: @Sendable () async throws -> URL
    private let initializationGate = CatPawInitializationGate()
    private let capabilityRegistry: CatPawCapabilityRegistry

    init(
        site: SiteConfiguration,
        baseURL: URL,
        httpClient: HTTPClient,
        ensureRuntimeReady: (@Sendable () async throws -> URL)?,
        capabilityRegistry: CatPawCapabilityRegistry = .shared
    ) {
        moduleIdentity = CatPawModuleIdentity(
            site: site,
            fallbackSession: UUID().uuidString.lowercased()
        )
        apiReference = site.api
        moduleName = site.name
        requestHeaders = HTTPHeaders(site.header)
        timeout = TimeInterval(site.timeout ?? 60)
        self.httpClient = httpClient
        self.capabilityRegistry = capabilityRegistry
        resolveRuntimeBaseURL = ensureRuntimeReady ?? { baseURL }
    }

    func capabilityState(
        for route: CatPawRoute
    ) async -> CatPawRouteCapabilityState {
        await capabilityRegistry.state(of: route, for: moduleIdentity)
    }

    func recordSupported(_ route: CatPawRoute) async {
        await capabilityRegistry.recordSupported(route, for: moduleIdentity)
    }

    func recordUnsupported(_ route: CatPawRoute) async {
        await capabilityRegistry.recordUnsupported(route, for: moduleIdentity)
    }

    func prepare(
        route: CatPawRoute,
        payload: [String: JSONValue]
    ) async throws -> CatPawPreparedInvocation {
        if await capabilityRegistry.state(
            of: route,
            for: moduleIdentity
        ) == .unsupported {
            throw CatPawRouteError.unsupportedRoute(
                route: route,
                message: "\(moduleName) 未注册 \(route.rawValue) 路由"
            )
        }

        let baseURL = try await resolveRuntimeBaseURL()
        let apiURL = try ResourceResolver.resolve(apiReference, relativeTo: baseURL)
        try await initializationGate.ensureInitialized(
            endpointKey: apiURL.absoluteString
        ) { [self] in
            try await initializeModule(apiURL: apiURL)
        }

        let invocationID = UUID().uuidString.lowercased()
        var headers = requestHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        headers["X-OKVideo-Invocation-ID"] = invocationID
        let request = HTTPRequest(
            url: apiURL.appendingPathComponent(route.rawValue),
            method: .post,
            headers: headers,
            body: try JSONEncoder().encode(JSONValue.object(payload)),
            timeout: timeout,
            maximumResponseBytes: 16 * 1_024 * 1_024,
            retryPolicy: .none,
            allowsNonSuccessfulStatus: true
        )
        return CatPawPreparedInvocation(
            route: route,
            baseURL: baseURL,
            invocationID: invocationID,
            request: request
        )
    }

    func send(
        route: CatPawRoute,
        payload: [String: JSONValue]
    ) async throws -> CatPawRouteResponse {
        let invocation = try await prepare(route: route, payload: payload)
        let response = try await httpClient.send(invocation.request)
        return try await decode(response, for: invocation)
    }

    func decode(
        _ response: HTTPResponse,
        for invocation: CatPawPreparedInvocation
    ) async throws -> CatPawRouteResponse {
        let value: JSONValue
        if response.body.isEmpty {
            value = .null
        } else {
            guard let decoded = try? JSONDecoder().decode(
                JSONValue.self,
                from: response.body
            ) else {
                throw CatPawRouteError.invalidJSON(route: invocation.route)
            }
            value = decoded
        }
        let effectiveInvocationID = response.headers["X-OKVideo-Invocation-ID"]
            ?? invocation.invocationID
        let message = Self.serverMessage(from: value)
            ?? "HTTP 状态码 \(response.statusCode)"
        guard (200...299).contains(response.statusCode) else {
            if Self.isExactRouteNotFound(
                statusCode: response.statusCode,
                message: message,
                route: invocation.route
            ) {
                await capabilityRegistry.recordUnsupported(
                    invocation.route,
                    for: moduleIdentity
                )
                throw CatPawRouteError.unsupportedRoute(
                    route: invocation.route,
                    message: message
                )
            }
            throw CatPawRouteError.httpStatus(
                route: invocation.route,
                statusCode: response.statusCode,
                message: message
            )
        }
        await capabilityRegistry.recordSupported(
            invocation.route,
            for: moduleIdentity
        )
        return CatPawRouteResponse(
            route: invocation.route,
            value: value,
            baseURL: invocation.baseURL,
            invocationID: effectiveInvocationID,
            statusCode: response.statusCode,
            headers: response.headers
        )
    }

    private func initializeModule(apiURL: URL) async throws {
        var headers = requestHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        let response = try await httpClient.send(
            HTTPRequest(
                url: apiURL.appendingPathComponent(CatPawRoute.initialize.rawValue),
                method: .post,
                headers: headers,
                body: Data("{}".utf8),
                timeout: min(timeout, 15),
                maximumResponseBytes: 1 * 1_024 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        if (200...299).contains(response.statusCode)
            || response.statusCode == 404
            || response.statusCode == 405 {
            return
        }
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let message = value.flatMap(Self.serverMessage(from:))
            ?? "HTTP 状态码 \(response.statusCode)"
        throw CatPawRouteError.httpStatus(
            route: .initialize,
            statusCode: response.statusCode,
            message: "\(moduleName) init 失败：\(message)"
        )
    }

    static func serverMessage(from value: JSONValue) -> String? {
        guard let object = value.objectValue else { return value.stringValue }
        for key in ["msg", "message", "error"] {
            if let message = object[key]?.stringValue,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        return nil
    }

    static func isExactRouteNotFound(
        statusCode: Int,
        message: String,
        route: CatPawRoute
    ) -> Bool {
        guard statusCode == 404 else { return false }
        let value = message.lowercased()
        return value.contains("route post:")
            && value.contains("/\(route.rawValue.lowercased())")
            && value.contains("not found")
    }
}

struct CatPawHostMessage: Decodable, Sendable {
    let action: String
    let requestID: String?
    let opt: JSONValue
}

/// Request-scoped mailbox used by CatPaw's synchronous `messageToDart()`
/// bridge. It never consumes a message belonging to another invocation.
final class CatPawHostMessageBridge {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func decodeHeader(_ encoded: String?) -> CatPawHostMessage? {
        guard let encoded,
              let data = Data(base64Encoded: encoded),
              data.count <= 4 * 1_024 else { return nil }
        return try? JSONDecoder().decode(CatPawHostMessage.self, from: data)
    }

    func poll(
        invocationID: String,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> CatPawHostMessage? {
        guard Self.isValidIdentifier(invocationID) else {
            throw AppError.spider("Node 宿主操作关联标识无效")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "wait",
                value: String(min(max(waitMilliseconds, 0), 2_000))
            )
        ]
        guard let endpoint = components?.url else {
            throw AppError.spider("Node 宿主操作轮询地址无效")
        }
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                timeout: TimeInterval(waitMilliseconds) / 1_000 + 2,
                maximumResponseBytes: 8 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard response.statusCode == 200 else {
            if response.statusCode == 204 || response.statusCode == 404 {
                return nil
            }
            throw AppError.spider(
                "Node 宿主操作轮询失败：HTTP 状态码 \(response.statusCode)"
            )
        }
        guard response.body.count <= 4 * 1_024 else {
            throw AppError.spider("Node 宿主操作响应过大")
        }
        return try? JSONDecoder().decode(
            CatPawHostMessage.self,
            from: response.body
        )
    }

    /// Reads a short-lived host event emitted by a later Runtime-owned request
    /// such as a media proxy GET. Those requests have their own invocation ID,
    /// which libmpv cannot return to the app, so the Contract-B adapter scopes
    /// the event to the owning CatPaw module path instead.
    func pollRuntimeEvent(
        modulePath: String,
        notBefore: Date,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> CatPawHostMessage? {
        guard Self.isValidRuntimeModulePath(modulePath) else {
            throw AppError.spider("Node Runtime 事件来源无效")
        }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("__okvideo")
                .appendingPathComponent("runtime-host-message"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "source", value: modulePath),
            URLQueryItem(
                name: "notBefore",
                value: String(Int(notBefore.timeIntervalSince1970 * 1_000))
            ),
            URLQueryItem(
                name: "wait",
                value: String(min(max(waitMilliseconds, 0), 2_000))
            )
        ]
        guard let endpoint = components?.url else {
            throw AppError.spider("Node Runtime 事件轮询地址无效")
        }
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                timeout: TimeInterval(waitMilliseconds) / 1_000 + 2,
                maximumResponseBytes: 8 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard response.statusCode == 200 else {
            if response.statusCode == 204 || response.statusCode == 404 {
                return nil
            }
            throw AppError.spider(
                "Node Runtime 事件轮询失败：HTTP 状态码 \(response.statusCode)"
            )
        }
        guard response.body.count <= 4 * 1_024 else {
            throw AppError.spider("Node Runtime 事件响应过大")
        }
        return try? JSONDecoder().decode(
            CatPawHostMessage.self,
            from: response.body
        )
    }

    /// Asks the trusted Contract-B adapter whether an internal page belongs to
    /// one of the listeners started by the current Runtime process. This keeps
    /// auxiliary services (for example a danmu settings server) usable without
    /// weakening the same-process ownership boundary to arbitrary loopback
    /// ports.
    func ownedInternalWebViewURL(
        _ rawURL: String,
        baseURL: URL
    ) async -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048,
              let candidate = URL(string: trimmed),
              candidate.scheme?.lowercased() == "http",
              candidate.port != nil else {
            return nil
        }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("__okvideo")
                .appendingPathComponent("owned-loopback"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "url", value: trimmed),
            URLQueryItem(name: "purpose", value: "internal-webview")
        ]
        guard let endpoint = components?.url,
              let response = try? await httpClient.send(
                HTTPRequest(
                    url: endpoint,
                    timeout: 2,
                    maximumResponseBytes: 4 * 1_024,
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
              ), response.statusCode == 200,
              let value = try? JSONDecoder().decode(
                JSONValue.self,
                from: response.body
              ), let normalized = value.objectValue?["url"]?.stringValue,
              let url = URL(string: normalized),
              Self.isNormalizedOwnedInternalWebViewURL(url) else {
            return nil
        }
        return url
    }

    func reply(
        _ value: JSONValue,
        invocationID: String,
        requestID: String,
        baseURL: URL
    ) async throws {
        guard Self.isValidIdentifier(invocationID),
              Self.isValidIdentifier(requestID) else {
            throw AppError.spider("Node 宿主操作关联标识无效")
        }
        let endpoint = baseURL
            .appendingPathComponent("__okvideo")
            .appendingPathComponent("host-message-reply")
            .appendingPathComponent(invocationID)
            .appendingPathComponent(requestID)
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                method: .post,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: try JSONEncoder().encode(value),
                timeout: 5,
                maximumResponseBytes: 8 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard (200...299).contains(response.statusCode) else {
            throw AppError.spider(
                "Node 宿主操作回传失败：HTTP 状态码 \(response.statusCode)"
            )
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || ".-_".unicodeScalars.contains($0)
        }
    }

    private static func isValidRuntimeModulePath(_ value: String) -> Bool {
        guard value.utf8.count <= 1_024 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[0].lowercased() == "spider" else {
            return false
        }
        return parts.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }

    private static func isNormalizedOwnedInternalWebViewURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ), url.port != nil else {
            return false
        }
        let path = url.path
        return path != "/__okvideo" && !path.hasPrefix("/__okvideo/")
    }
}

/// Adds request-scoped host-message and authorization handling to ordinary
/// CatPaw routes. Valid responses return immediately; the compatibility
/// mailbox is polled only when a route-specific predicate says the response
/// is incomplete, so already-authorized providers pay no extra delay.
final class CatPawInteractiveRouteClient {
    private let routeClient: CatPawRouteClient
    private let httpClient: HTTPClient
    private let hostMessageBridge: CatPawHostMessageBridge
    private let authorizationCoordinator: CatPawAuthorizationCoordinator

    init(
        site: SiteConfiguration,
        baseURL: URL,
        httpClient: HTTPClient,
        ensureRuntimeReady: (@Sendable () async throws -> URL)? = nil
    ) {
        self.httpClient = httpClient
        routeClient = CatPawRouteClient(
            site: site,
            baseURL: baseURL,
            httpClient: httpClient,
            ensureRuntimeReady: ensureRuntimeReady
        )
        hostMessageBridge = CatPawHostMessageBridge(httpClient: httpClient)
        authorizationCoordinator = CatPawAuthorizationCoordinator(
            site: site,
            hostMessageBridge: hostMessageBridge
        )
    }

    func send(
        route: CatPawRoute,
        payload: [String: JSONValue],
        waitsForLateMessage: (JSONValue, CatPawRoute) -> Bool,
        legacyAuthorization: (String) -> Bool
    ) async throws -> CatPawRouteResponse {
        let invocation = try await routeClient.prepare(
            route: route,
            payload: payload
        )
        let rawResponse = try await httpClient.send(invocation.request)
        let invocationID = rawResponse.headers["X-OKVideo-Invocation-ID"]
            ?? invocation.invocationID
        if let message = hostMessageBridge.decodeHeader(
            rawResponse.headers["X-OKVideo-Host-Message"]
        ), message.action == "openInternalWebview" {
            throw try await authorizationCoordinator.authorizationRequired(
                hostMessage: message,
                invocationID: invocationID,
                baseURL: invocation.baseURL
            )
        }

        do {
            let response = try await routeClient.decode(
                rawResponse,
                for: invocation
            )
            if waitsForLateMessage(response.value, route) {
                if let message = try await hostMessageBridge.poll(
                    invocationID: invocationID,
                    baseURL: invocation.baseURL,
                    waitMilliseconds: 1_250
                ), message.action == "openInternalWebview" {
                    throw try await authorizationCoordinator.authorizationRequired(
                        hostMessage: message,
                        invocationID: invocationID,
                        baseURL: invocation.baseURL
                    )
                }
                if let message = CatPawRouteClient.serverMessage(
                    from: response.value
                ), legacyAuthorization(message) {
                    throw authorizationCoordinator.legacyAuthorizationRequired(
                        message: message,
                        baseURL: invocation.baseURL
                    )
                }
            }
            return response
        } catch let authorization as NodeWebAuthorizationRequired {
            throw authorization
        } catch {
            if let message = try? await hostMessageBridge.poll(
                invocationID: invocationID,
                baseURL: invocation.baseURL,
                waitMilliseconds: 1_250
            ), message.action == "openInternalWebview" {
                throw try await authorizationCoordinator.authorizationRequired(
                    hostMessage: message,
                    invocationID: invocationID,
                    baseURL: invocation.baseURL
                )
            }
            if legacyAuthorization(error.localizedDescription) {
                throw authorizationCoordinator.legacyAuthorizationRequired(
                    message: error.localizedDescription,
                    baseURL: invocation.baseURL
                )
            }
            throw error
        }
    }
}

/// Converts request-scoped CatPaw web challenges into the authorization state
/// already consumed by AppState and keeps listening for the explicit
/// completion signal. It deliberately does not retry the triggering route.
final class CatPawAuthorizationCoordinator {
    private let site: SiteConfiguration
    private let hostMessageBridge: CatPawHostMessageBridge

    init(site: SiteConfiguration, hostMessageBridge: CatPawHostMessageBridge) {
        self.site = site
        self.hostMessageBridge = hostMessageBridge
    }

    func authorizationRequired(
        hostMessage: CatPawHostMessage,
        invocationID: String,
        baseURL: URL
    ) async throws -> NodeWebAuthorizationRequired {
        guard hostMessage.action == "openInternalWebview",
              let options = hostMessage.opt.objectValue,
              let rawURL = options["url"]?.stringValue else {
            throw AppError.spider("Node 模块请求了不受支持的宿主操作")
        }
        let normalized = CatPawRuntimeURLResolver.normalize(
            rawURL,
            baseURL: baseURL
        )
        let candidateURL = URL(string: normalized)
        let url: URL?
        if let candidateURL,
           Self.isOwnedRuntimeURL(candidateURL, baseURL: baseURL) {
            url = candidateURL
        } else {
            url = await hostMessageBridge.ownedInternalWebViewURL(
                rawURL,
                baseURL: baseURL
            )
        }
        guard let url else {
            throw AppError.spider("Node 模块请求了不属于当前 Runtime 的配置页面")
        }

        if let declaredRequestID = Self.nonEmpty(
            options["requestID"]?.stringValue
        ), declaredRequestID != invocationID {
            throw AppError.spider("Node 授权请求与当前调用不匹配")
        }
        let providerChallenge = Self.nonEmpty(
            options["challengeID"]?.stringValue
        ).flatMap(UUID.init(uuidString:))
        let challengeID = providerChallenge ?? UUID()
        let requestID = providerChallenge == nil ? nil : invocationID
        let provider = Self.nonEmpty(options["provider"]?.stringValue)
            ?? site.name.replacingOccurrences(of: "|", with: " ")
        let profileRevision = Self.nonEmpty(
            options["profileRevision"]?.stringValue
        ) ?? site.extra["okNodeProfileRevision"]?.stringValue
        let transport = Self.nonEmpty(options["transport"]?.stringValue) ?? "web"
        if let providerChallenge, let requestID {
            let monitor = Task { [weak self] in
                guard let self else { return }
                await self.monitorCompletion(
                    challengeID: challengeID,
                    providerChallengeID: providerChallenge,
                    provider: provider,
                    invocationID: requestID,
                    baseURL: baseURL
                )
            }
            Task {
                await NodeAuthorizationSignalCenter.shared.register(
                    challengeID: challengeID,
                    requestID: requestID,
                    monitor: monitor
                )
            }
        }
        return NodeWebAuthorizationRequired(
            challengeID: challengeID,
            requestID: requestID,
            websiteURL: url,
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: providerChallenge == nil
                ? "已打开当前 CatPaw Runtime 提供的内部页面。"
                : "等待网盘授权，请使用对应网盘 App 扫码。",
            provider: provider,
            profileRevision: profileRevision,
            transport: transport
        )
    }

    func legacyAuthorizationRequired(
        message: String,
        baseURL: URL
    ) -> NodeWebAuthorizationRequired {
        NodeWebAuthorizationRequired(
            challengeID: UUID(),
            requestID: nil,
            websiteURL: baseURL.appendingPathComponent("website"),
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: message,
            provider: site.name.replacingOccurrences(of: "|", with: " "),
            profileRevision: site.extra["okNodeProfileRevision"]?.stringValue,
            transport: "web"
        )
    }

    private func monitorCompletion(
        challengeID: UUID,
        providerChallengeID: UUID,
        provider: String?,
        invocationID: String,
        baseURL: URL
    ) async {
        while !Task.isCancelled {
            do {
                guard let message = try await hostMessageBridge.poll(
                    invocationID: invocationID,
                    baseURL: baseURL,
                    waitMilliseconds: 2_000
                ) else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                guard message.action == "authorizationCompleted" else {
                    continue
                }
                let options = message.opt.objectValue ?? [:]
                guard let actualChallengeID = Self.nonEmpty(
                    options["challengeID"]?.stringValue
                ).flatMap(UUID.init(uuidString:)),
                      actualChallengeID == providerChallengeID,
                      Self.nonEmpty(options["requestID"]?.stringValue)
                        == invocationID else {
                    continue
                }
                await NodeAuthorizationSignalCenter.shared.publish(
                    NodeAuthorizationCompletionSignal(
                        challengeID: challengeID,
                        requestID: invocationID,
                        provider: Self.nonEmpty(options["provider"]?.stringValue)
                            ?? provider,
                        profileRevision: Self.nonEmpty(
                            options["profileRevision"]?.stringValue
                        )
                    )
                )
                return
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private static func isOwnedRuntimeURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              baseURL.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ), url.port == baseURL.port else {
            return false
        }
        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
