import Foundation
import ImageIO

public enum TMDBImageValidation {
    public static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

public struct TMDBLinkProber {
    public let availability: TMDBAvailability
    private let metadata: TMDBServing
    private let images: HTTPClient
    private let paths: [String]
    public init(availability: TMDBAvailability, metadata: TMDBServing = TMDBClient(timeout: 6), images: HTTPClient = URLSessionHTTPClient(), imagePaths: [String] = ["/1E5baAaEse26fej7uHcjOgEE2t2.jpg", "/6FfCtAuVAW8XJjZ7eWeLibRLWTw.jpg"]) {
        self.availability = availability; self.metadata = metadata; self.images = images; paths = Array(imagePaths.prefix(2))
    }
    public func warm(force: Bool = false) async {
        await availability.probe(.metadata, force: force) {
            do { _ = try await metadata.imageConfiguration(); return .success }
            catch { return .error(error) }
        }
        await availability.probe(.images, force: force) {
            for path in paths {
                if Task.isCancelled { return .cancelled }
                guard let url = TMDBClient.imageURL(path: path, size: "w92") else { continue }
                do {
                    let response = try await images.send(HTTPRequest(url: url, headers: ["Cache-Control": "no-cache"], timeout: 6, maximumResponseBytes: 512 * 1024, earlyResponseLimitBytes: 512 * 1024, maximumRedirects: 0, retryPolicy: .none, allowsNonSuccessfulStatus: true))
                    if Task.isCancelled { return .cancelled }
                    if response.statusCode == 404 { continue }
                    guard (200..<300).contains(response.statusCode) else { return .status(response.statusCode, retryAfter: TMDBClient.retryAfter(response.headers["Retry-After"])) }
                    return TMDBImageValidation.decodes(response.body) ? .success : .failure(.invalidResponse)
                } catch {
                    if TMDBLinkOutcome.error(error) == .missing { continue }
                    return .error(error)
                }
            }
            return .missing
        }
    }
}

/// Only the real image transport is observed, after decoding. App image cache
/// hits never reach this wrapper and therefore cannot prove current connectivity.
public struct TMDBObservedImageClient: HTTPClient {
    private let base: HTTPClient
    private let availability: TMDBAvailability
    public init(base: HTTPClient, availability: TMDBAvailability) { self.base = base; self.availability = availability }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host == TMDBClient.imageBase.host else { return try await base.send(request) }
        let health = await availability.snapshot().images
        // Missing/corrupt images and individual transport failures must not
        // suppress every other image. Honor service-wide rate/auth/server faults.
        if health.state == .unavailable,
           health.failure == .rateLimited || health.failure == .configuration || health.failure == .server {
            throw TMDBError.unavailable(0)
        }
        let ticket = await availability.ticket(.images)
        var request = request
        request.allowsNonSuccessfulStatus = true
        do {
            let response: HTTPResponse
            do { response = try await base.send(request) }
            catch {
                guard TMDBLinkOutcome.error(error) == .failure(.network), !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: 300_000_000)
                response = try await base.send(request)
            }
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                throw TMDBError.service(response.statusCode, retryAfter: TMDBClient.retryAfter(response.headers["Retry-After"]))
            }
            guard TMDBImageValidation.decodes(response.body) else { throw TMDBError.invalidResponse }
            await availability.finish(ticket, outcome: .success)
            return response
        } catch {
            await availability.finish(ticket, outcome: .error(error)); throw error
        }
    }
}
