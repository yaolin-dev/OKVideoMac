import Foundation

public enum SpiderMethod: String, Codable, CaseIterable, Sendable {
    case initialize = "init"
    case home
    case homeVideo = "homeVod"
    case category
    case detail
    case search
    case play
    case live
    case proxy
    case action
    case sniffer
    case isVideo
    case destroy
}

public struct SpiderInvocation: Equatable, Sendable {
    public var method: SpiderMethod
    public var arguments: [JSONValue]

    public init(method: SpiderMethod, arguments: [JSONValue] = []) {
        self.method = method
        self.arguments = arguments
    }
}

public struct SpiderRuntimeLimits: Equatable, Sendable {
    public var maximumMemoryBytes: Int
    public var executionTimeout: TimeInterval

    public init(
        maximumMemoryBytes: Int = 64 * 1_024 * 1_024,
        executionTimeout: TimeInterval = 10
    ) {
        self.maximumMemoryBytes = max(1_024 * 1_024, maximumMemoryBytes)
        self.executionTimeout = max(0.1, executionTimeout)
    }

    public static let standard = SpiderRuntimeLimits()
}

public struct SpiderNetworkRequest: Equatable, Sendable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: HTTPHeaders
    public var body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: HTTPHeaders = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct SpiderNetworkResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(statusCode: Int, headers: HTTPHeaders, body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol SpiderHost {
    func log(siteKey: String, message: String)
    func request(_ request: SpiderNetworkRequest) async throws -> SpiderNetworkResponse
}

public protocol SpiderRuntime: AnyObject {
    var siteKey: String { get }
    var limits: SpiderRuntimeLimits { get }

    func load(script: String, sourceURL: URL?) async throws
    func invoke(_ invocation: SpiderInvocation) async throws -> JSONValue
    func destroy() async
}

public protocol SpiderRuntimeFactory {
    func makeRuntime(
        siteKey: String,
        limits: SpiderRuntimeLimits,
        host: SpiderHost
    ) throws -> SpiderRuntime
}

public final class UnsupportedQuickJSRuntime: SpiderRuntime {
    public let siteKey: String
    public let limits: SpiderRuntimeLimits

    public init(siteKey: String, limits: SpiderRuntimeLimits = .standard) {
        self.siteKey = siteKey
        self.limits = limits
    }

    public func load(script: String, sourceURL: URL?) async throws {
        throw AppError.unsupported(
            "QuickJS 运行库尚未构建；请先执行 Scripts/build-quickjs.sh"
        )
    }

    public func invoke(_ invocation: SpiderInvocation) async throws -> JSONValue {
        throw AppError.unsupported("QuickJS 运行库尚未可用")
    }

    public func destroy() async {}
}

public final class HTTPSpiderHost: SpiderHost {
    private let httpClient: HTTPClient
    private let logger: (String, String) -> Void

    public init(
        httpClient: HTTPClient,
        logger: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.httpClient = httpClient
        self.logger = logger
    }

    public func log(siteKey: String, message: String) {
        logger(siteKey, LogRedactor.text(message))
    }

    public func request(_ request: SpiderNetworkRequest) async throws -> SpiderNetworkResponse {
        let response = try await httpClient.send(
            HTTPRequest(
                url: request.url,
                method: request.method,
                headers: request.headers,
                body: request.body,
                timeout: 20,
                maximumResponseBytes: 8 * 1_024 * 1_024
            )
        )
        return SpiderNetworkResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.body
        )
    }
}

public actor SpiderEngine {
    public let site: SiteConfiguration
    private let runtime: SpiderRuntime
    private let parser: ConfigurationParser
    private var initialized = false

    public init(
        site: SiteConfiguration,
        runtime: SpiderRuntime,
        parser: ConfigurationParser = ConfigurationParser()
    ) {
        self.site = site
        self.runtime = runtime
        self.parser = parser
    }

    public func initialize(script: String, sourceURL: URL?) async throws {
        guard !initialized else { return }
        try await runtime.load(script: script, sourceURL: sourceURL)
        let ext = site.ext ?? .null
        _ = try await runtime.invoke(
            SpiderInvocation(method: .initialize, arguments: [ext])
        )
        initialized = true
    }

    public func home(filter: Bool = true) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(method: .home, arguments: [.bool(filter)])
        )
    }

    public func homeVideo() async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(SpiderInvocation(method: .homeVideo))
    }

    public func category(
        id: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(
                method: .category,
                arguments: [
                    .string(id),
                    .string(String(page)),
                    .bool(filter),
                    .object(extend.mapValues(JSONValue.string))
                ]
            )
        )
    }

    public func detail(id: String) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(method: .detail, arguments: [.string(id)])
        )
    }

    public func search(keyword: String, quick: Bool, page: Int?) async throws -> JSONValue {
        try ensureInitialized()
        var arguments: [JSONValue] = [.string(keyword), .bool(quick)]
        if let page {
            arguments.append(.string(String(page)))
        }
        return try await runtime.invoke(
            SpiderInvocation(method: .search, arguments: arguments)
        )
    }

    public func play(flag: String, id: String, vipFlags: [String]) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(
                method: .play,
                arguments: [
                    .string(flag),
                    .string(id),
                    .array(vipFlags.map(JSONValue.string))
                ]
            )
        )
    }

    public func live(url: String) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(method: .live, arguments: [.string(url)])
        )
    }

    public func action(_ action: String) async throws -> JSONValue {
        try ensureInitialized()
        return try await runtime.invoke(
            SpiderInvocation(method: .action, arguments: [.string(action)])
        )
    }

    public func destroy() async {
        initialized = false
        await runtime.destroy()
    }

    private func ensureInitialized() throws {
        guard initialized else {
            throw AppError.spider("站点 \(site.name) 的 Spider 尚未初始化")
        }
    }
}
