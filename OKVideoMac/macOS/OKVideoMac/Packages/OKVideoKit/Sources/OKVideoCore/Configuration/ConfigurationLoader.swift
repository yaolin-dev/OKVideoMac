import Foundation

public struct ConfigurationLoader {
    private let httpClient: HTTPClient
    private let parser: ConfigurationParser
    private let payloadDecoder: ConfigurationPayloadDecoder
    private let now: () -> Date

    public init(
        httpClient: HTTPClient,
        parser: ConfigurationParser = ConfigurationParser(),
        payloadDecoder: ConfigurationPayloadDecoder = ConfigurationPayloadDecoder(),
        now: @escaping () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.parser = parser
        self.payloadDecoder = payloadDecoder
        self.now = now
    }

    public func load(_ source: ConfigurationSource) async throws -> LoadedConfiguration {
        let rawData: Data
        let resolvedBaseURL: URL?

        switch source {
        case .remote(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw AppError.configuration("远程配置仅允许 HTTP/HTTPS")
            }
            let request = HTTPRequest(
                url: url,
                timeout: 20,
                maximumResponseBytes: ConfigurationParser.maximumConfigurationSize,
                maximumRedirects: 10,
                retryPolicy: .standard
            )
            let response = try await httpClient.send(request)
            rawData = try payloadDecoder.decode(response.body)
            resolvedBaseURL = response.url.deletingLastPathComponent()

        case .localFile(let url):
            guard url.isFileURL else {
                throw AppError.configuration("本地配置必须是 file URL")
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes[.size] as? NSNumber,
                   size.intValue > ConfigurationParser.maximumConfigurationSize {
                    throw AppError.configuration("本地配置超过 5 MiB 限制")
                }
                rawData = try payloadDecoder.decode(
                    Data(contentsOf: url, options: .mappedIfSafe)
                )
            } catch let error as AppError {
                throw error
            } catch {
                throw AppError.filesystem("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
            resolvedBaseURL = url.deletingLastPathComponent()

        case .pasted(let text, let baseURL):
            guard let data = text.data(using: .utf8) else {
                throw AppError.configuration("粘贴内容不是有效 UTF-8")
            }
            rawData = try payloadDecoder.decode(data)
            resolvedBaseURL = baseURL
        }

        return LoadedConfiguration(
            source: source,
            baseURL: resolvedBaseURL,
            rawData: rawData,
            configuration: try parser.parse(rawData),
            loadedAt: now()
        )
    }
}
