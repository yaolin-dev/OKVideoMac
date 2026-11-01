import Foundation

/// First-attempt HLS preparation, including URLs declared as TS that redirect
/// to HLS. Never downloads a media segment or persists credential-bearing data.
public struct LiveHLSStartupPreparer {
    private let configuration: URLSessionConfiguration
    private let deadline: TimeInterval
    private let maximumBytes: Int

    public init(useSystemProxy: Bool = true) {
        let configuration = URLSessionConfiguration.ephemeral
        if !useSystemProxy { configuration.connectionProxyDictionary = [:] }
        self.init(configuration: configuration, deadline: 5, maximumBytes: 256 * 1024)
    }

    init(configuration: URLSessionConfiguration, deadline: TimeInterval, maximumBytes: Int = 256 * 1024) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.deadline = max(0.01, deadline)
        self.maximumBytes = max(16, maximumBytes)
    }

    /// Nil means use the original player path, not an unavailable channel.
    /// Binary responses stop at their initial prefix instead of awaiting EOF.
    public func prepare(url: URL, headers: HTTPHeaders) async throws -> HLSStartupSelection? {
        try Task.checkCancellation()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: deadline)
        for (field, value) in headers.dictionary { request.setValue(value, forHTTPHeaderField: field) }
        return try await LiveHLSManifestLoad(configuration: configuration, deadline: deadline,
                                             maximumBytes: maximumBytes, headers: headers).load(request)
    }
}

private final class LiveHLSManifestLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let deadline: TimeInterval
    private let maximumBytes: Int
    private let headers: HTTPHeaders
    private var continuation: CheckedContinuation<HLSStartupSelection?, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadlineWork: DispatchWorkItem?
    private var data = Data()
    private var finalURL: URL?
    private var redirectCount = 0
    private var finished = false
    private var cancelled = false

    init(configuration: URLSessionConfiguration, deadline: TimeInterval, maximumBytes: Int, headers: HTTPHeaders) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.deadline = deadline
        self.maximumBytes = maximumBytes
        self.headers = headers
        self.configuration.urlCache = nil
        self.configuration.httpCookieStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCredentialStorage = nil
        self.configuration.timeoutIntervalForResource = deadline
    }

    func load(_ request: URLRequest) async throws -> HLSStartupSelection? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                let work = DispatchWorkItem { [weak self] in self?.finish(.success(nil)) }
                deadlineWork = work
                let stop = cancelled || Task.isCancelled
                lock.unlock()
                if stop { finish(.failure(CancellationError())) }
                else {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline, execute: work)
                    task.resume()
                }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let started = self.continuation != nil
            self.lock.unlock()
            if started { self.finish(.failure(CancellationError())) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), http.statusCode != 206,
              response.expectedContentLength < Int64(maximumBytes) else {
            finish(.success(nil)); completionHandler(.cancel); return
        }
        lock.lock()
        finalURL = http.url
        let stop = finished
        lock.unlock()
        completionHandler(stop ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let exceedsLimit = chunk.count >= maximumBytes - data.count
        data.append(chunk.prefix(maximumBytes - data.count))
        // At most ten bytes determine the EXTM3U signature (optional UTF-8 BOM).
        // A real continuous MPEG-TS response is cancelled on its first chunk.
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]
        let prefix = data.starts(with: bom) ? data.dropFirst(3) : data[...]
        let magic = Array("#EXTM3U".utf8)
        let compared = min(prefix.count, magic.count)
        let mismatch = !prefix.prefix(compared).elementsEqual(magic.prefix(compared))
        let waitingForBOM = data.count < bom.count && bom.starts(with: data)
        let stop = exceedsLimit || (mismatch && !waitingForBOM)
        lock.unlock()
        if stop { finish(.success(nil)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let bytes = data
        let url = finalURL
        let stop = finished
        lock.unlock()
        guard !stop else { return }
        let normalized = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes
        let selection = error == nil ? url.flatMap { HLSStartupSelection.select(from: normalized, baseURL: $0) } : nil
        finish(.success(selection))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectCount += 1
        let allowed = !finished && redirectCount <= 5
        lock.unlock()
        guard allowed, HTTPRedirectSecurity.isAllowed(request.url, from: response.url, policy: .noDowngrade) else {
            finish(.success(nil)); completionHandler(nil); return
        }
        // Do not reintroduce origin credentials on later CDN-to-CDN redirects.
        var forwarded = headers
        if !HTTPRedirectSecurity.isAllowed(request.url, from: task.originalRequest?.url, policy: .sameOriginNoDowngrade) {
            forwarded["Authorization"] = nil
            forwarded["Proxy-Authorization"] = nil
            forwarded["Cookie"] = nil
        }
        var redirected = HTTPRedirectSecurity.preparedRequest(request, originalURL: task.originalRequest?.url, redirectedHeaders: forwarded)
        if forwarded["Cookie"] == nil { redirected.setValue(nil, forHTTPHeaderField: "Cookie") }
        completionHandler(redirected)
    }

    private func finish(_ result: Result<HLSStartupSelection?, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        let session = self.session; self.session = nil
        let work = deadlineWork; deadlineWork = nil
        data.removeAll(keepingCapacity: false)
        let result = cancelled ? .failure(CancellationError()) : result
        lock.unlock()
        work?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
