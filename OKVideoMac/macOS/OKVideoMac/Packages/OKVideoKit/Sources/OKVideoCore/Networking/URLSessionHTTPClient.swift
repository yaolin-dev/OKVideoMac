import Foundation

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(
        configuration: URLSessionConfiguration = .default,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Self.validateScheme(request.url)

        var attempt = 0
        var delay = request.retryPolicy.initialDelay
        while true {
            do {
                return try await sendOnce(request)
            } catch {
                guard shouldRetry(error, request: request, attempt: attempt) else {
                    throw Self.map(error)
                }
                attempt += 1
                if delay > 0 {
                    let nanoseconds = UInt64(delay * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
                delay *= request.retryPolicy.multiplier
            }
        }
    }

    private func sendOnce(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let startedAt = Date()

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers.dictionary {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        var redirectedHeaders = HTTPHeaders()
        for field in request.redirectedHeaderFields {
            if let value = request.headers[field] {
                redirectedHeaders[field] = value
            }
        }
        let redirectDelegate = RedirectDelegate(
            maximumRedirects: request.maximumRedirects,
            redirectedHeaders: redirectedHeaders
        )
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: redirectDelegate)
        } catch let error as HTTPClientError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPClientError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw Task.isCancelled ? HTTPClientError.cancelled : HTTPClientError.transport(error.localizedDescription)
        } catch {
            throw HTTPClientError.transport(error.localizedDescription)
        }

        if redirectDelegate.exceededLimit {
            throw HTTPClientError.tooManyRedirects(request.maximumRedirects)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard data.count <= request.maximumResponseBytes else {
            throw HTTPClientError.responseTooLarge(
                limit: request.maximumResponseBytes,
                actual: data.count
            )
        }
        guard request.allowsNonSuccessfulStatus
                || (200...299).contains(http.statusCode) else {
            throw HTTPClientError.statusCode(http.statusCode)
        }
        guard let finalURL = http.url else {
            throw HTTPClientError.invalidResponse
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            responseHeaders[String(describing: key)] = String(describing: value)
        }
        return HTTPResponse(
            url: finalURL,
            statusCode: http.statusCode,
            headers: HTTPHeaders(responseHeaders),
            body: data,
            diagnostics: HTTPResponseDiagnostics(
                originalURL: request.url,
                redirects: redirectDelegate.redirects,
                finalURL: finalURL,
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                contentLength: data.count,
                duration: Date().timeIntervalSince(startedAt)
            )
        )
    }

    private func shouldRetry(_ error: Error, request: HTTPRequest, attempt: Int) -> Bool {
        guard attempt < request.retryPolicy.maximumRetries,
              request.method.isIdempotent,
              !Task.isCancelled else {
            return false
        }

        if let error = error as? HTTPClientError {
            switch error {
            case .statusCode(let code):
                return code == 408 || code == 429 || (500...599).contains(code)
            case .timeout, .transport:
                return true
            case .invalidScheme, .responseTooLarge, .tooManyRedirects,
                 .invalidResponse, .cancelled:
                return false
            }
        }
        return error is URLError
    }

    private static func validateScheme(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw HTTPClientError.invalidScheme(scheme)
        }
    }

    private static func map(_ error: Error) -> Error {
        if error is CancellationError {
            return HTTPClientError.cancelled
        }
        return error
    }
}

final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let maximumRedirects: Int
    private let redirectedHeaders: HTTPHeaders
    private let lock = NSLock()
    private var redirectCount = 0
    private var redirectHops: [HTTPRedirectHop] = []

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return redirectCount > maximumRedirects
    }

    var redirects: [HTTPRedirectHop] {
        lock.lock()
        defer { lock.unlock() }
        return redirectHops
    }

    init(
        maximumRedirects: Int,
        redirectedHeaders: HTTPHeaders = [:]
    ) {
        self.maximumRedirects = max(0, maximumRedirects)
        self.redirectedHeaders = redirectedHeaders
    }

    func preparedRedirectRequest(
        _ request: URLRequest,
        originalURL: URL?
    ) -> URLRequest {
        var redirectedRequest = request
        for (field, value) in redirectedHeaders.dictionary {
            redirectedRequest.setValue(value, forHTTPHeaderField: field)
        }
        let redirectedURL = request.url
        let changedOrigin = originalURL?.scheme?.caseInsensitiveCompare(
            redirectedURL?.scheme ?? ""
        ) != .orderedSame || originalURL?.host?.caseInsensitiveCompare(
            redirectedURL?.host ?? ""
        ) != .orderedSame || originalURL?.port != redirectedURL?.port
        if changedOrigin {
            // Provider media headers may be explicitly preserved, but
            // credentials must never cross an origin boundary.
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        return redirectedRequest
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let isAllowed = redirectCount <= maximumRedirects
        if let sourceURL = response.url, let destinationURL = request.url {
            redirectHops.append(
                HTTPRedirectHop(
                    statusCode: response.statusCode,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
            )
        }
        lock.unlock()
        guard isAllowed else {
            completionHandler(nil)
            return
        }
        completionHandler(
            preparedRedirectRequest(
                request,
                originalURL: task.originalRequest?.url
            )
        )
    }
}
