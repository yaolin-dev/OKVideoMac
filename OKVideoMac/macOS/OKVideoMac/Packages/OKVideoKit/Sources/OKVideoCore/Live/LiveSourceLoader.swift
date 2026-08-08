import Foundation

public enum LiveSourceInput: Equatable {
    case remote(URL)
    case localFile(URL)
    case pasted(text: String, baseURL: URL?)

    public var displayName: String {
        switch self {
        case .remote(let url):
            return url.host ?? url.lastPathComponent.nonEmpty ?? "远程直播源"
        case .localFile(let url):
            return url.deletingPathExtension().lastPathComponent
        case .pasted:
            return "粘贴的直播源"
        }
    }
}

public struct LoadedLiveSource: Equatable {
    public let source: LiveSourceInput
    public let baseURL: URL?
    public let rawData: Data
    public let playlist: LivePlaylist
    public let loadedAt: Date

    public init(
        source: LiveSourceInput,
        baseURL: URL?,
        rawData: Data,
        playlist: LivePlaylist,
        loadedAt: Date
    ) {
        self.source = source
        self.baseURL = baseURL
        self.rawData = rawData
        self.playlist = playlist
        self.loadedAt = loadedAt
    }
}

public struct LiveSourceLoader {
    public static let maximumSourceSize = 32 * 1_024 * 1_024

    private let httpClient: HTTPClient
    private let parser: LiveSourceParser
    private let now: () -> Date

    public init(
        httpClient: HTTPClient,
        parser: LiveSourceParser = LiveSourceParser(),
        now: @escaping () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.parser = parser
        self.now = now
    }

    public func load(_ source: LiveSourceInput) async throws -> LoadedLiveSource {
        let data: Data
        let baseURL: URL?

        switch source {
        case .remote(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw AppError.live("远程直播源仅允许 HTTP/HTTPS")
            }
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    timeout: 30,
                    maximumResponseBytes: Self.maximumSourceSize,
                    maximumRedirects: 10,
                    retryPolicy: .standard
                )
            )
            data = response.body
            baseURL = response.url.deletingLastPathComponent()

        case .localFile(let url):
            guard url.isFileURL else {
                throw AppError.live("本地直播源必须是 file URL")
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumSourceSize {
                throw AppError.live("本地直播源超过 32 MiB 限制")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
            baseURL = url.deletingLastPathComponent()

        case .pasted(let text, let suppliedBaseURL):
            guard let value = text.data(using: .utf8) else {
                throw AppError.live("粘贴的直播源不是有效 UTF-8")
            }
            data = value
            baseURL = suppliedBaseURL
        }

        guard !data.isEmpty else {
            throw AppError.live("直播源内容为空")
        }
        guard data.count <= Self.maximumSourceSize else {
            throw AppError.live("直播源超过 32 MiB 限制")
        }
        return LoadedLiveSource(
            source: source,
            baseURL: baseURL,
            rawData: data,
            playlist: try parser.parse(data, baseURL: baseURL),
            loadedAt: now()
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
