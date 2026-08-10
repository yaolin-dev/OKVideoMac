import Foundation

public struct WebSniffRequest: Equatable, Sendable {
    public var siteKey: String
    public var url: URL
    public var headers: HTTPHeaders
    public var mediaPatterns: [String]
    public var clickScript: String?
    public var timeout: TimeInterval
    public var debugVisible: Bool

    public init(
        siteKey: String,
        url: URL,
        headers: HTTPHeaders = [:],
        mediaPatterns: [String] = [],
        clickScript: String? = nil,
        timeout: TimeInterval = 15,
        debugVisible: Bool = false
    ) {
        self.siteKey = siteKey
        self.url = url
        self.headers = headers
        self.mediaPatterns = mediaPatterns
        self.clickScript = clickScript
        self.timeout = max(1, timeout)
        self.debugVisible = debugVisible
    }
}

public struct SniffedMedia: Equatable, Sendable {
    public var url: URL
    public var headers: HTTPHeaders
    public var sourcePageURL: URL

    public init(url: URL, headers: HTTPHeaders, sourcePageURL: URL) {
        self.url = url
        self.headers = headers
        self.sourcePageURL = sourcePageURL
    }
}

@MainActor
public protocol WebSnifferClient: AnyObject {
    func sniff(_ request: WebSniffRequest) async throws -> SniffedMedia
    func cancel()
}
