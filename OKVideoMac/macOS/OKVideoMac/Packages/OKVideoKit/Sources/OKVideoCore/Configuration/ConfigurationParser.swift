import Foundation

public struct ConfigurationParser {
    public static let maximumConfigurationSize = 5 * 1_024 * 1_024

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init() {
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    public func parse(_ data: Data) throws -> FongMiConfiguration {
        guard data.count <= Self.maximumConfigurationSize else {
            throw AppError.configuration(
                "配置大小为 \(data.count) 字节，超过 \(Self.maximumConfigurationSize) 字节限制"
            )
        }
        guard !data.isEmpty else {
            throw AppError.configuration("配置内容为空")
        }

        do {
            let normalized = try TVBoxJSONNormalizer.normalize(data)
            try JSONDuplicateKeyDetector.validate(normalized)
            var configuration = try decoder.decode(
                FongMiConfiguration.self,
                from: normalized
            )
            // The Android FongMi ecosystem commonly uses repeated site keys
            // for announcement/separator entries. Its runtime map keeps the
            // last value, so mirror that behavior instead of rejecting the
            // entire otherwise usable configuration.
            configuration.sites = Self.sitesKeepingLastDuplicate(
                configuration.sites
            )
            try ConfigurationValidator().validate(configuration)
            return configuration
        } catch let error as AppError {
            throw error
        } catch let error as DecodingError {
            throw AppError.decoding(Self.describe(error))
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    public func parse(_ text: String) throws -> FongMiConfiguration {
        guard let data = text.data(using: .utf8) else {
            throw AppError.configuration("配置文本不是有效 UTF-8")
        }
        return try parse(data)
    }

    public func encode(_ configuration: FongMiConfiguration) throws -> Data {
        do {
            return try encoder.encode(configuration)
        } catch {
            throw AppError.decoding("无法导出配置：\(error.localizedDescription)")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return "JSON 内容损坏（\(path(context.codingPath))）：\(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath + [key]))"
        case .typeMismatch(let type, let context):
            return "字段 \(path(context.codingPath)) 类型错误，期望 \(type)"
        case .valueNotFound(let type, let context):
            return "字段 \(path(context.codingPath)) 缺少 \(type) 值"
        @unknown default:
            return "未知 JSON 解码错误"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let value = codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }

    private static func sitesKeepingLastDuplicate(
        _ sites: [SiteConfiguration]
    ) -> [SiteConfiguration] {
        var seen = Set<String>()
        return sites.reversed().filter { site in
            seen.insert(site.key).inserted
        }.reversed()
    }
}

public struct ConfigurationValidator {
    public init() {}

    public func validate(_ configuration: FongMiConfiguration) throws {
        var siteKeys = Set<String>()
        for (index, site) in configuration.sites.enumerated() {
            let prefix = "sites[\(index)]"
            guard !site.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).key 不能为空")
            }
            guard siteKeys.insert(site.key).inserted else {
                throw AppError.configuration("站点 key 重复：\(site.key)")
            }
            guard !site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).name 不能为空")
            }
            guard [0, 1, 3, 4].contains(site.type) else {
                throw AppError.configuration("\(prefix).type \(site.type) 不在 0/1/3/4 范围内")
            }
            guard !site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).api 不能为空")
            }
            if site.type != 3 {
                try validateHTTPReference(site.api, field: "\(prefix).api")
            }
            if let timeout = site.timeout, !(1...300).contains(timeout) {
                throw AppError.configuration("\(prefix).timeout 必须在 1 到 300 秒之间")
            }
        }

        var parseNames = Set<String>()
        for (index, parse) in configuration.parses.enumerated() {
            let prefix = "parses[\(index)]"
            guard !parse.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).name 不能为空")
            }
            guard parseNames.insert(parse.name).inserted else {
                throw AppError.configuration("解析器 name 重复：\(parse.name)")
            }
            guard (0...4).contains(parse.type) else {
                throw AppError.configuration("\(prefix).type \(parse.type) 不在 0...4 范围内")
            }
            guard !parse.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).url 不能为空")
            }
            try validateHTTPReference(parse.url, field: "\(prefix).url")
        }

        var liveNames = Set<String>()
        for (index, live) in configuration.lives.enumerated() {
            let prefix = "lives[\(index)]"
            guard !live.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.configuration("\(prefix).name 不能为空")
            }
            guard liveNames.insert(live.name).inserted else {
                throw AppError.configuration("直播源 name 重复：\(live.name)")
            }
            guard live.url != nil || live.api != nil || !live.groups.isEmpty else {
                throw AppError.configuration("\(prefix) 必须包含 url、api 或 groups")
            }
            if let timeout = live.timeout, !(1...300).contains(timeout) {
                throw AppError.configuration("\(prefix).timeout 必须在 1 到 300 秒之间")
            }
        }
    }

    private func validateHTTPReference(_ value: String, field: String) throws {
        guard let url = URL(string: value) else {
            throw AppError.configuration("\(field) 不是有效 URL 或相对路径")
        }
        if let scheme = url.scheme?.lowercased(), !["http", "https"].contains(scheme) {
            throw AppError.configuration("\(field) 使用了不允许的协议 \(scheme)")
        }
    }
}

public enum ConfigurationSource: Equatable, Sendable {
    case remote(URL)
    case localFile(URL)
    case pasted(text: String, baseURL: URL?)

    public var displayName: String {
        switch self {
        case .remote(let url): return LogRedactor.url(url)
        case .localFile(let url): return url.lastPathComponent
        case .pasted: return "粘贴内容"
        }
    }

    public var baseURL: URL? {
        switch self {
        case .remote(let url):
            return url.deletingLastPathComponent()
        case .localFile(let url):
            return url.deletingLastPathComponent()
        case .pasted(_, let baseURL):
            return baseURL
        }
    }
}

public struct LoadedConfiguration: Equatable, Sendable {
    public let source: ConfigurationSource
    public let baseURL: URL?
    public let rawData: Data
    public let configuration: FongMiConfiguration
    public let loadedAt: Date

    public init(
        source: ConfigurationSource,
        baseURL: URL?,
        rawData: Data,
        configuration: FongMiConfiguration,
        loadedAt: Date
    ) {
        self.source = source
        self.baseURL = baseURL
        self.rawData = rawData
        self.configuration = configuration
        self.loadedAt = loadedAt
    }
}

public enum ResourceResolver {
    public static func resolve(_ reference: String, relativeTo baseURL: URL?) throws -> URL {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AppError.configuration("资源地址为空")
        }
        if let absolute = encodedURL(value), absolute.scheme != nil {
            guard let scheme = absolute.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else {
                throw AppError.configuration("资源协议不受支持：\(absolute.scheme ?? "")")
            }
            return absolute
        }
        guard let baseURL,
              let resolved = encodedURL(value, relativeTo: baseURL)?.absoluteURL else {
            throw AppError.configuration("相对资源 \(reference) 缺少基准地址")
        }
        return resolved
    }

    private static func encodedURL(_ value: String, relativeTo baseURL: URL? = nil) -> URL? {
        if let url = URL(string: value, relativeTo: baseURL) {
            return url
        }
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        ) else {
            return nil
        }
        return URL(string: encoded, relativeTo: baseURL)
    }
}
