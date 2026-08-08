import Foundation
import OKVideoCore

final class AppParseExecutor: ParseExecutor {
    private let jsonExecutor: JSONParseExecutor

    init(httpClient: HTTPClient) {
        jsonExecutor = JSONParseExecutor(httpClient: httpClient)
    }

    func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        switch parser.type {
        case 1:
            return try await jsonExecutor.resolve(
                parser: parser,
                inputURL: inputURL,
                headers: headers
            )
        case 0:
            return try await sniff(
                parser: parser,
                inputURL: inputURL,
                headers: headers
            )
        default:
            throw AppError.unsupported("解析器 \(parser.name) 的 type \(parser.type) 尚未实现")
        }
    }

    private func sniff(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        guard let pageURL = URL(string: parser.url + inputURL),
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else {
            throw AppError.parsing("Web 解析器 \(parser.name) 生成了非法 URL")
        }
        let sniffer = await MainActor.run { WKWebSniffer() }
        let mergedHeaders = headers.merging(HTTPHeaders(parser.headers))
        let request = WebSniffRequest(
            siteKey: "parser:\(parser.name)",
            url: pageURL,
            headers: mergedHeaders,
            timeout: 15
        )
        let media = try await withTaskCancellationHandler(
            operation: {
                try await sniffer.sniff(request)
            },
            onCancel: {
                Task { @MainActor in
                    sniffer.cancel()
                }
            }
        )
        return ParsedMedia(
            url: media.url,
            headers: mergedHeaders.merging(media.headers)
        )
    }
}
