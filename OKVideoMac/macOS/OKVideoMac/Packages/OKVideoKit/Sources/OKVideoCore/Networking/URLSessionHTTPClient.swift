import Foundation

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let configuration: URLSessionConfiguration
    private let boundedSession: BoundedResponseSession?

    public init(
        configuration: URLSessionConfiguration = .default,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration.copy() as! URLSessionConfiguration
        session = URLSession(configuration: configuration)
        boundedSession = nil
    }

    /// A separate, stateless transport for credential-bearing provider APIs.
    /// The existing initializer deliberately retains its shared-cookie behavior
    /// for providers that rely on it. Passing `.ephemeral` to that initializer
    /// is not equivalent to using this factory.
    public static func isolatedEphemeral(reusesBoundedConnections: Bool = false) -> URLSessionHTTPClient {
        URLSessionHTTPClient(isolatedConfiguration: .ephemeral, reusesBoundedConnections: reusesBoundedConnections)
    }

    // Keep protocol-class injection internal so tests can exercise both the
    // buffered and bounded paths without adding a production configuration
    // escape hatch to the isolated factory.
    init(isolatedConfiguration: URLSessionConfiguration, reusesBoundedConnections: Bool = false) {
        let configuration = isolatedConfiguration.copy()
            as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration.copy() as! URLSessionConfiguration
        session = URLSession(configuration: configuration)
        boundedSession = reusesBoundedConnections ? BoundedResponseSession(configuration: configuration) : nil
    }

    deinit { boundedSession?.invalidate() }

    /// A defensive copy for transport-policy regression tests. The actual
    /// session and the configuration used by bounded loads remain immutable.
    var transportConfiguration: URLSessionConfiguration {
        configuration.copy() as! URLSessionConfiguration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Self.validateScheme(request.url)

        guard let budget = request.totalTimeout else { return try await sendWithRetries(request) }
        do {
            return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask { try await self.sendWithRetries(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    throw HTTPClientError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            if Task.isCancelled { throw HTTPClientError.cancelled }
            throw Self.map(error)
        }
    }

    private func sendWithRetries(_ request: HTTPRequest) async throws -> HTTPResponse {
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
            redirectedHeaders: redirectedHeaders,
            redirectPolicy: request.redirectPolicy,
            originalURL: request.url,
            timingObserver: HTTPTaskTimingContext.observer
        )
        let (data, response): (Data, URLResponse)
        let redirects: [HTTPRedirectHop]
        do {
            if let earlyLimit = request.earlyResponseLimitBytes {
                let result = try await BoundedResponseLoader(
                    configuration: configuration,
                    maximumBytes: earlyLimit,
                    maximumRedirects: request.maximumRedirects,
                    redirectedHeaders: redirectedHeaders,
                    redirectPolicy: request.redirectPolicy,
                    originalURL: request.url,
                    pooledSession: boundedSession,
                    timingObserver: HTTPTaskTimingContext.observer
                ).load(urlRequest)
                data = result.data
                response = result.response
                redirects = result.redirects
            } else {
                (data, response) = try await session.data(
                    for: urlRequest,
                    delegate: redirectDelegate
                )
                redirects = redirectDelegate.redirects
            }
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
        if redirectDelegate.rejectedRedirect {
            throw HTTPClientError.redirectRejected
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
                redirects: redirects,
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
                 .redirectRejected,
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
    private let redirectPolicy: HTTPRedirectPolicy
    private let originalURL: URL?
    private let timingObserver: (@Sendable (HTTPTaskTiming) -> Void)?
    private let lock = NSLock()
    private var redirectCount = 0
    private var redirectHops: [HTTPRedirectHop] = []
    private var didRejectRedirect = false

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

    var rejectedRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectRedirect
    }

    init(
        maximumRedirects: Int,
        redirectedHeaders: HTTPHeaders = [:],
        redirectPolicy: HTTPRedirectPolicy = .follow,
        originalURL: URL? = nil,
        timingObserver: (@Sendable (HTTPTaskTiming) -> Void)? = nil
    ) {
        self.maximumRedirects = max(0, maximumRedirects)
        self.redirectedHeaders = redirectedHeaders
        self.redirectPolicy = redirectPolicy
        self.originalURL = originalURL
        self.timingObserver = timingObserver
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        timingObserver?(HTTPTaskTiming(metrics))
    }

    func preparedRedirectRequest(
        _ request: URLRequest,
        originalURL: URL?
    ) -> URLRequest {
        HTTPRedirectSecurity.preparedRequest(
            request,
            originalURL: originalURL,
            redirectedHeaders: redirectedHeaders
        )
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
            && HTTPRedirectSecurity.isAllowed(
                request.url,
                from: redirectPolicy == .noDowngrade ? response.url : (originalURL ?? task.originalRequest?.url),
                policy: redirectPolicy
            )
        if redirectCount <= maximumRedirects, !isAllowed {
            didRejectRedirect = true
        }
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

enum HTTPRedirectSecurity {
    static func isAllowed(
        _ destination: URL?,
        from origin: URL?,
        policy: HTTPRedirectPolicy
    ) -> Bool {
        guard policy != .follow else { return true }
        guard let destination, let origin,
              let destinationScheme = destination.scheme?.lowercased(),
              let originScheme = origin.scheme?.lowercased(),
              let destinationHost = destination.host?.lowercased(),
              let originHost = origin.host?.lowercased() else {
            return false
        }
        if policy == .noDowngrade {
            return ["http", "https"].contains(destinationScheme)
                && ["http", "https"].contains(originScheme)
                && !(originScheme == "https" && destinationScheme == "http")
        }
        return destinationScheme == originScheme
            && destinationHost == originHost
            && effectivePort(destination) == effectivePort(origin)
    }

    static func preparedRequest(
        _ request: URLRequest,
        originalURL: URL?,
        redirectedHeaders: HTTPHeaders
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
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        return redirectedRequest
    }

    private static func effectivePort(_ url: URL?) -> Int? {
        if let port = url?.port { return port }
        switch url?.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

private struct BoundedResponseResult {
    let data: Data
    let response: URLResponse
    let redirects: [HTTPRedirectHop]
}

/// One connection pool per opted-in client. Response buffers, redirect policy,
/// cancellation and metrics remain owned by each individual request.
private final class BoundedResponseSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var loaders: [Int: BoundedResponseLoader] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func makeTask(_ request: URLRequest, loader: BoundedResponseLoader) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock(); loaders[task.taskIdentifier] = loader; lock.unlock()
        return task
    }

    private func loader(for task: URLSessionTask) -> BoundedResponseLoader? {
        lock.lock(); defer { lock.unlock() }
        return loaders[task.taskIdentifier]
    }

    func remove(_ task: URLSessionTask) {
        lock.lock(); loaders[task.taskIdentifier] = nil; lock.unlock()
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let loader = loader(for: dataTask) else { completionHandler(.cancel); return }
        loader.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loader(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let loader = loader(for: task) else { completionHandler(nil); return }
        loader.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        loader(for: task)?.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        loader(for: task)?.urlSession(session, task: task, didCompleteWithError: error)
        remove(task)
    }
}

private final class BoundedResponseLoader: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let maximumRedirects: Int
    private let redirectedHeaders: HTTPHeaders
    private let redirectPolicy: HTTPRedirectPolicy
    private let originalURL: URL
    private let pooledSession: BoundedResponseSession?
    private let timingObserver: (@Sendable (HTTPTaskTiming) -> Void)?
    private let lock = NSLock()

    private var continuation: CheckedContinuation<BoundedResponseResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var data = Data()
    private var redirects: [HTTPRedirectHop] = []
    private var redirectCount = 0
    private var completed = false
    private var cancellationRequested = false

    init(
        configuration: URLSessionConfiguration,
        maximumBytes: Int,
        maximumRedirects: Int,
        redirectedHeaders: HTTPHeaders,
        redirectPolicy: HTTPRedirectPolicy,
        originalURL: URL,
        pooledSession: BoundedResponseSession? = nil,
        timingObserver: (@Sendable (HTTPTaskTiming) -> Void)? = nil
    ) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.maximumBytes = max(1, maximumBytes)
        self.maximumRedirects = max(0, maximumRedirects)
        self.redirectedHeaders = redirectedHeaders
        self.redirectPolicy = redirectPolicy
        self.originalURL = originalURL
        self.pooledSession = pooledSession
        self.timingObserver = timingObserver
    }

    func load(_ request: URLRequest) async throws -> BoundedResponseResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task: URLSessionDataTask
                if let pooledSession {
                    task = pooledSession.makeTask(request, loader: self)
                } else {
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    task = session.dataTask(with: request)
                }
                self.task = task
                let cancelled = cancellationRequested || Task.isCancelled
                lock.unlock()

                if cancelled {
                    finish(.failure(HTTPClientError.cancelled), cancelTask: true)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        timingObserver?(HTTPTaskTiming(metrics))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let declaredLength = response.expectedContentLength
        if declaredLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(
                .failure(
                    HTTPClientError.responseTooLarge(
                        limit: maximumBytes,
                        actual: declaredLength > Int64(Int.max)
                            ? Int.max
                            : Int(declaredLength)
                    )
                ),
                cancelTask: true
            )
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive newData: Data
    ) {
        lock.lock()
        let currentCount = data.count
        let exceedsLimit = newData.count > maximumBytes - currentCount
        if !exceedsLimit {
            data.append(newData)
        }
        lock.unlock()

        if exceedsLimit {
            finish(
                .failure(
                    HTTPClientError.responseTooLarge(
                        limit: maximumBytes,
                        actual: currentCount + newData.count
                    )
                ),
                cancelTask: true
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let destination = request.url
        let hop = destination.map {
            HTTPRedirectHop(
                statusCode: response.statusCode,
                sourceURL: response.url ?? originalURL,
                destinationURL: $0
            )
        }
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        if let hop { redirects.append(hop) }
        lock.unlock()

        guard count <= maximumRedirects else {
            completionHandler(nil)
            finish(
                .failure(HTTPClientError.tooManyRedirects(maximumRedirects)),
                cancelTask: true
            )
            return
        }
        guard HTTPRedirectSecurity.isAllowed(
            destination,
            from: redirectPolicy == .noDowngrade ? response.url : originalURL,
            policy: redirectPolicy
        ) else {
            completionHandler(nil)
            finish(.failure(HTTPClientError.redirectRejected), cancelTask: true)
            return
        }
        completionHandler(
            HTTPRedirectSecurity.preparedRequest(
                request,
                originalURL: task.originalRequest?.url,
                redirectedHeaders: redirectedHeaders
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error), cancelTask: false)
            return
        }
        lock.lock()
        let response = self.response
        let result = response.map {
            BoundedResponseResult(
                data: data,
                response: $0,
                redirects: redirects
            )
        }
        lock.unlock()
        if let result {
            finish(.success(result), cancelTask: false)
        } else {
            finish(.failure(HTTPClientError.invalidResponse), cancelTask: false)
        }
    }

    private func finish(
        _ result: Result<BoundedResponseResult, Error>,
        cancelTask: Bool
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        self.continuation = nil
        lock.unlock()

        if cancelTask { task?.cancel() }
        if let task { pooledSession?.remove(task) }
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let hasStarted = continuation != nil
        lock.unlock()
        if hasStarted {
            finish(.failure(HTTPClientError.cancelled), cancelTask: true)
        }
    }
}
