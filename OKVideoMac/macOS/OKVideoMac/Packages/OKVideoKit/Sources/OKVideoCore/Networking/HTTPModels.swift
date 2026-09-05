import Foundation
import CoreFoundation

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"

    public var isIdempotent: Bool {
        switch self {
        case .get, .put, .delete, .head: return true
        case .post, .patch: return false
        }
    }
}

public struct HTTPHeaders: Equatable, ExpressibleByDictionaryLiteral, Sendable {
    private var storage: [String: String]

    public init(_ values: [String: String] = [:]) {
        storage = values
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        storage = Dictionary(uniqueKeysWithValues: elements)
    }

    public subscript(name: String) -> String? {
        get {
            storage.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        set {
            if let existing = storage.keys.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                storage.removeValue(forKey: existing)
            }
            if let newValue {
                storage[name] = newValue
            }
        }
    }

    public var dictionary: [String: String] {
        storage
    }

    public func merging(_ other: HTTPHeaders) -> HTTPHeaders {
        var merged = self
        for (key, value) in other.storage {
            merged[key] = value
        }
        return merged
    }
}

public struct HTTPRetryPolicy: Equatable, Sendable {
    public var maximumRetries: Int
    public var initialDelay: TimeInterval
    public var multiplier: Double

    public init(
        maximumRetries: Int = 2,
        initialDelay: TimeInterval = 0.25,
        multiplier: Double = 2
    ) {
        self.maximumRetries = max(0, maximumRetries)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
    }

    public static let none = HTTPRetryPolicy(maximumRetries: 0)
    public static let standard = HTTPRetryPolicy()
}

public struct HTTPRequest: Equatable, Sendable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: HTTPHeaders
    public var body: Data?
    public var timeout: TimeInterval
    public var maximumResponseBytes: Int
    public var maximumRedirects: Int
    /// Header fields that must be explicitly reapplied to redirected
    /// requests. URLSession may discard provider-required fields such as
    /// Range, Referer, or User-Agent when a download crosses hosts.
    /// Authorization and Proxy-Authorization are never forwarded across an
    /// origin boundary even when requested here.
    public var redirectedHeaderFields: Set<String>
    public var retryPolicy: HTTPRetryPolicy
    public var allowsNonSuccessfulStatus: Bool

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        maximumRedirects: Int = 10,
        redirectedHeaderFields: Set<String> = [],
        retryPolicy: HTTPRetryPolicy = .standard,
        allowsNonSuccessfulStatus: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumRedirects = maximumRedirects
        self.redirectedHeaderFields = redirectedHeaderFields
        self.retryPolicy = retryPolicy
        self.allowsNonSuccessfulStatus = allowsNonSuccessfulStatus
    }

    public static func json<T: Encodable>(
        url: URL,
        method: HTTPMethod = .post,
        value: T,
        headers: HTTPHeaders = [:],
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> HTTPRequest {
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json; charset=utf-8"
        return HTTPRequest(
            url: url,
            method: method,
            headers: requestHeaders,
            body: try encoder.encode(value)
        )
    }

    public static func form(
        url: URL,
        fields: [String: String],
        headers: HTTPHeaders = [:]
    ) throws -> HTTPRequest {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let data = components.percentEncodedQuery?.data(using: .utf8) else {
            throw AppError.network("无法编码表单")
        }
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
        return HTTPRequest(url: url, method: .post, headers: requestHeaders, body: data)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: HTTPHeaders
    public let body: Data
    public let diagnostics: HTTPResponseDiagnostics?

    public init(
        url: URL,
        statusCode: Int,
        headers: HTTPHeaders,
        body: Data,
        diagnostics: HTTPResponseDiagnostics? = nil
    ) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.diagnostics = diagnostics
    }

    public func text() throws -> String {
        let contentType = headers["Content-Type"]?.lowercased() ?? ""
        let encoding: String.Encoding
        if contentType.contains("gb18030") || contentType.contains("gbk") {
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
        } else if contentType.contains("utf-16") {
            encoding = .utf16
        } else if contentType.contains("iso-8859-1") {
            encoding = .isoLatin1
        } else {
            encoding = .utf8
        }

        if let value = String(data: body, encoding: encoding) {
            return value
        }
        if encoding != .utf8, let value = String(data: body, encoding: .utf8) {
            return value
        }
        throw AppError.decoding("响应文本编码无法识别")
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }
}

public struct HTTPRedirectHop: Equatable, Sendable {
    public let statusCode: Int
    public let sourceURL: URL
    public let destinationURL: URL

    public init(statusCode: Int, sourceURL: URL, destinationURL: URL) {
        self.statusCode = statusCode
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    public var crossesScheme: Bool {
        sourceURL.scheme?.caseInsensitiveCompare(destinationURL.scheme ?? "")
            != .orderedSame
    }

    public var crossesHost: Bool {
        sourceURL.host?.caseInsensitiveCompare(destinationURL.host ?? "")
            != .orderedSame
            || sourceURL.port != destinationURL.port
    }

    public var downgradesHTTPS: Bool {
        sourceURL.scheme?.lowercased() == "https"
            && destinationURL.scheme?.lowercased() == "http"
    }
}

public struct HTTPResponseDiagnostics: Equatable, Sendable {
    public let originalURL: URL
    public let redirects: [HTTPRedirectHop]
    public let finalURL: URL
    public let statusCode: Int
    public let contentType: String?
    public let contentLength: Int
    public let duration: TimeInterval

    public init(
        originalURL: URL,
        redirects: [HTTPRedirectHop],
        finalURL: URL,
        statusCode: Int,
        contentType: String?,
        contentLength: Int,
        duration: TimeInterval
    ) {
        self.originalURL = originalURL
        self.redirects = redirects
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
        self.contentLength = contentLength
        self.duration = duration
    }

    public var redirectedFromHTTPSIntoHTTP: Bool {
        redirects.contains(where: \.downgradesHTTPS)
            || (originalURL.scheme?.lowercased() == "https"
                && finalURL.scheme?.lowercased() == "http")
    }

    public var crossedScheme: Bool {
        redirects.contains(where: \.crossesScheme)
    }

    public var crossedHost: Bool {
        redirects.contains(where: \.crossesHost)
    }
}

public enum HTTPClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidScheme(String?)
    case statusCode(Int)
    case responseTooLarge(limit: Int, actual: Int)
    case tooManyRedirects(Int)
    case invalidResponse
    case timeout
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidScheme(let scheme): return "不允许的 URL 协议：\(scheme ?? "<none>")"
        case .statusCode(let code): return "HTTP 状态码 \(code)"
        case .responseTooLarge(let limit, let actual):
            return "响应大小 \(actual) 字节超过 \(limit) 字节限制"
        case .tooManyRedirects(let count): return "重定向次数超过 \(count)"
        case .invalidResponse: return "服务器返回了无效响应"
        case .timeout: return "请求超时"
        case .transport(let message): return "传输失败：\(message)"
        case .cancelled: return "请求已取消"
        }
    }
}

public protocol HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
