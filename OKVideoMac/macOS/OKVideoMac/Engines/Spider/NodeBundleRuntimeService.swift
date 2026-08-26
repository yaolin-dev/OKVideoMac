import CryptoKit
import Foundation
import OKVideoCore

enum NodeDiagnosticCategory: String, Codable, Equatable, Sendable {
    case transport
    case trust
    case cache
    case runtime
    case spiderSite = "spider/site"
}

enum NodeDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

enum NodeDiagnosticCode: String, Codable, Equatable, Sendable {
    case bundleRequest = "NODE_BUNDLE_REQUEST"
    case bundleResponse = "NODE_BUNDLE_RESPONSE"
    case transportTimeout = "NODE_TRANSPORT_TIMEOUT"
    case transportReset = "NODE_TRANSPORT_RESET"
    case transportRefused = "NODE_TRANSPORT_REFUSED"
    case transportHTTPStatus = "NODE_TRANSPORT_HTTP_STATUS"
    case transportRedirectFailed = "NODE_TRANSPORT_REDIRECT_FAILED"
    case transportUnavailable = "NODE_TRANSPORT_UNAVAILABLE"
    case trustMissingPin = "NODE_TRUST_MISSING_SHA256"
    case trustSHA256Mismatch = "NODE_TRUST_SHA256_MISMATCH"
    case trustIntegrityRejected = "NODE_TRUST_INTEGRITY_REJECTED"
    case trustHashChanged = "NODE_TRUST_HASH_CHANGED"
    case trustAccepted = "NODE_TRUST_ACCEPTED"
    case cacheMissing = "NODE_CACHE_MISSING"
    case cacheInvalidMetadata = "NODE_CACHE_INVALID_METADATA"
    case cacheCorrupt = "NODE_CACHE_CORRUPT"
    case cacheLegacyDetected = "NODE_CACHE_LEGACY_DETECTED"
    case cacheLegacyMD5Mismatch = "NODE_CACHE_LEGACY_MD5_MISMATCH"
    case cacheMigrationSucceeded = "NODE_CACHE_MIGRATION_SUCCEEDED"
    case cacheMigrationFailed = "NODE_CACHE_MIGRATION_FAILED"
    case runtimeLaunchStarted = "NODE_RUNTIME_LAUNCH_STARTED"
    case runtimeContractDetected = "NODE_RUNTIME_CONTRACT_DETECTED"
    case runtimeHostAdapterReady = "NODE_RUNTIME_HOST_ADAPTER_READY"
    case runtimeConfigurationValidated = "NODE_RUNTIME_CONFIGURATION_VALIDATED"
    case runtimeListenerObserved = "NODE_RUNTIME_LISTENER_OBSERVED"
    case runtimeCapabilityValidated = "NODE_RUNTIME_CAPABILITY_VALIDATED"
    case runtimeStartRequested = "NODE_RUNTIME_START_REQUESTED"
    case runtimeStartupJoined = "NODE_RUNTIME_STARTUP_JOINED"
    case runtimeReadinessWaiting = "NODE_RUNTIME_READINESS_WAITING"
    case runtimeLaunchFailed = "NODE_RUNTIME_LAUNCH_FAILED"
    case runtimeReady = "NODE_RUNTIME_READY"
    case runtimeHealthFailed = "NODE_RUNTIME_HEALTH_FAILED"
    case runtimeExited = "NODE_RUNTIME_EXITED"
    case runtimeRestartScheduled = "NODE_RUNTIME_RESTART_SCHEDULED"
    case runtimeRestartExhausted = "NODE_RUNTIME_RESTART_EXHAUSTED"
    case runtimeEndpointInvalidated = "NODE_RUNTIME_ENDPOINT_INVALIDATED"
    case runtimeHomepageReloadRequested = "NODE_RUNTIME_HOMEPAGE_RELOAD_REQUESTED"
    case runtimeUnavailable = "NODE_RUNTIME_UNAVAILABLE"
    case spiderRequestFailed = "NODE_SPIDER_REQUEST_FAILED"
    case spiderOutput = "NODE_SPIDER_OUTPUT"
}

/// Shares one unstructured startup operation across independent callers.
/// Cancelling a waiter only resumes that waiter; the shared operation remains
/// alive until it completes or the runtime owner explicitly tears it down.
actor SharedNodeRuntimeStartup<Value: Sendable> {
    private struct Session {
        let id: UUID
        let task: Task<Value, Error>
        var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    }

    private enum State {
        case running(Session)
        case completed(UUID, Result<Value, Error>)
    }

    private var state: State?

    func run(
        sessionID: UUID,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if case .running(var session) = state {
                    guard session.id == sessionID else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    session.waiters[waiterID] = continuation
                    state = .running(session)
                    return
                }
                if case .completed(let completedID, let result) = state,
                   completedID == sessionID {
                    continuation.resume(with: result)
                    return
                }

                let task = Task {
                    try await operation()
                }
                state = .running(Session(
                    id: sessionID,
                    task: task,
                    waiters: [waiterID: continuation]
                ))
                Task { [weak self] in
                    let result: Result<Value, Error>
                    do {
                        result = .success(try await task.value)
                    } catch {
                        result = .failure(error)
                    }
                    await self?.complete(sessionID: sessionID, result: result)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func cancel() {
        guard case .running(let session) = state else {
            state = nil
            return
        }
        state = nil
        session.task.cancel()
        for continuation in session.waiters.values {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard case .running(var session) = state,
              let continuation = session.waiters.removeValue(forKey: waiterID)
        else { return }
        state = .running(session)
        continuation.resume(throwing: CancellationError())
    }

    private func complete(
        sessionID: UUID,
        result: Result<Value, Error>
    ) {
        guard case .running(let session) = state,
              session.id == sessionID else { return }
        state = .completed(sessionID, result)
        for continuation in session.waiters.values {
            continuation.resume(with: result)
        }
    }
}

enum NodeTrustDiagnosticState: String, Codable, Equatable, Sendable {
    case httpsTransport
    case publisherPinned
    case legacyTOFU
    case untrusted
    case hashChanged
}

struct NodeRedirectDiagnostic: Codable, Equatable, Sendable {
    let statusCode: Int
    let sourceURL: String
    let destinationURL: String
    let crossedScheme: Bool
    let crossedHost: Bool
    let downgradedHTTPS: Bool

    init(_ hop: HTTPRedirectHop) {
        statusCode = hop.statusCode
        sourceURL = LogRedactor.url(hop.sourceURL)
        destinationURL = LogRedactor.url(hop.destinationURL)
        crossedScheme = hop.crossesScheme
        crossedHost = hop.crossesHost
        downgradedHTTPS = hop.downgradesHTTPS
    }
}

struct NodeDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let category: NodeDiagnosticCategory
    let severity: NodeDiagnosticSeverity
    let code: NodeDiagnosticCode
    let message: String
    let sourceID: String?
    let siteKey: String?
    let operation: String?
    let cacheKey: String?
    let originalURL: String?
    let finalURL: String?
    let redirects: [NodeRedirectDiagnostic]
    let httpStatus: Int?
    let contentType: String?
    let contentLength: Int?
    let durationMilliseconds: Int?
    let downgradedHTTPS: Bool?
    let crossedScheme: Bool?
    let crossedHost: Bool?
    let trustState: NodeTrustDiagnosticState?
    let nodePID: Int32?
    let localPort: Int?

    init(
        timestamp: Date = Date(),
        category: NodeDiagnosticCategory,
        severity: NodeDiagnosticSeverity,
        code: NodeDiagnosticCode,
        message: String,
        sourceID: String? = nil,
        siteKey: String? = nil,
        operation: String? = nil,
        cacheKey: String? = nil,
        originalURL: URL? = nil,
        finalURL: URL? = nil,
        responseDiagnostics: HTTPResponseDiagnostics? = nil,
        httpStatus: Int? = nil,
        contentType: String? = nil,
        contentLength: Int? = nil,
        trustState: NodeTrustDiagnosticState? = nil,
        nodePID: Int32? = nil,
        localPort: Int? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.code = code
        self.message = LogRedactor.text(message)
        self.sourceID = sourceID.map(LogRedactor.text)
        self.siteKey = siteKey.map(LogRedactor.text)
        self.operation = operation.map(LogRedactor.text)
        self.cacheKey = cacheKey
        let diagnostics = responseDiagnostics
        self.originalURL = (diagnostics?.originalURL ?? originalURL).map(LogRedactor.url)
        self.finalURL = (diagnostics?.finalURL ?? finalURL).map(LogRedactor.url)
        redirects = diagnostics?.redirects.map(NodeRedirectDiagnostic.init) ?? []
        self.httpStatus = diagnostics?.statusCode ?? httpStatus
        self.contentType = (diagnostics?.contentType ?? contentType).map(LogRedactor.text)
        self.contentLength = diagnostics?.contentLength ?? contentLength
        durationMilliseconds = diagnostics.map { Int(($0.duration * 1_000).rounded()) }
        downgradedHTTPS = diagnostics?.redirectedFromHTTPSIntoHTTP
        crossedScheme = diagnostics?.crossedScheme
        crossedHost = diagnostics?.crossedHost
        self.trustState = trustState
        self.nodePID = nodePID
        self.localPort = localPort
    }
}

struct NodeDiagnosticClassification: Equatable, Sendable {
    let category: NodeDiagnosticCategory
    let code: NodeDiagnosticCode
}

enum NodeDiagnosticContext: Equatable, Sendable {
    case bundleTransport
    case runtime
    case spiderSite
}

enum NodeDiagnosticClassifier {
    static func classify(
        _ error: Error,
        context: NodeDiagnosticContext
    ) -> NodeDiagnosticClassification {
        if let nodeError = error as? NodeBundleRuntimeError {
            return nodeError.diagnosticClassification
        }
        if context == .spiderSite {
            return NodeDiagnosticClassification(
                category: .spiderSite,
                code: .spiderRequestFailed
            )
        }
        if let httpError = error as? HTTPClientError {
            switch httpError {
            case .timeout:
                return .init(category: .transport, code: .transportTimeout)
            case .statusCode:
                return .init(category: .transport, code: .transportHTTPStatus)
            case .tooManyRedirects:
                return .init(category: .transport, code: .transportRedirectFailed)
            case .transport(let message):
                let lowercased = message.lowercased()
                if lowercased.contains("econnreset")
                    || lowercased.contains("connection reset") {
                    return .init(category: .transport, code: .transportReset)
                }
                if lowercased.contains("refused") || lowercased.contains("econnrefused") {
                    return .init(category: .transport, code: .transportRefused)
                }
                return .init(category: .transport, code: .transportUnavailable)
            default:
                return .init(category: .transport, code: .transportUnavailable)
            }
        }
        return NodeDiagnosticClassification(
            category: context == .runtime ? .runtime : .transport,
            code: context == .runtime ? .runtimeUnavailable : .transportUnavailable
        )
    }
}

final class NodeDiagnosticLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let logURL: URL
    private let maximumBytes: Int
    private let retainedFileCount: Int
    private var handle: FileHandle?
    private var pendingNodeOutput = Data()

    init(logURL: URL, maximumBytes: Int, retainedFileCount: Int) {
        self.logURL = logURL
        self.maximumBytes = max(1_024, maximumBytes)
        self.retainedFileCount = max(1, retainedFileCount)
        prepareFileIfPossible()
    }

    func write(_ event: NodeDiagnosticEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        append(data)
    }

    func writeNodeOutput(_ data: Data) {
        lock.lock()
        pendingNodeOutput.append(data)
        var lines: [Data] = []
        while let newline = pendingNodeOutput.firstIndex(of: 0x0A) {
            lines.append(pendingNodeOutput.prefix(upTo: newline))
            pendingNodeOutput.removeSubrange(...newline)
        }
        lock.unlock()
        for line in lines {
            writeNodeLine(line)
        }
    }

    func flushNodeOutput() {
        lock.lock()
        let remaining = pendingNodeOutput
        pendingNodeOutput.removeAll(keepingCapacity: false)
        lock.unlock()
        if !remaining.isEmpty { writeNodeLine(remaining) }
    }

    func close() {
        flushNodeOutput()
        lock.lock()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    private func writeNodeLine(_ data: Data) {
        let raw = String(decoding: data, as: UTF8.self)
        let sanitized = String(
            Self.sanitizedNodeOutput(raw).prefix(64 * 1_024)
        )
        write(
            NodeDiagnosticEvent(
                category: .spiderSite,
                severity: .info,
                code: .spiderOutput,
                message: sanitized
            )
        )
    }

    /// Runtime proxy URLs may carry an opaque, encoded request context in a
    /// query item whose name is chosen by the third-party bundle. Generic log
    /// redaction cannot safely enumerate those names, so diagnostic output
    /// retains the proxy route while dropping its entire query capability.
    private static func sanitizedNodeOutput(_ raw: String) -> String {
        LogRedactor.text(redactingRuntimeProxyQueries(in: raw))
    }

    private static func redactingRuntimeProxyQueries(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(/proxy/[^?\s<>\"']+)\?[^\s<>\"']+"#
        ) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1?<redacted>"
        )
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard ensureHandle(), let handle else { return }
        let currentSize = (try? handle.offset()) ?? 0
        if currentSize > 0, currentSize + UInt64(data.count) > UInt64(maximumBytes) {
            rotateLocked()
        }
        guard ensureHandle(), let activeHandle = self.handle else { return }
        try? activeHandle.write(contentsOf: data)
    }

    private func prepareFileIfPossible() {
        lock.lock()
        defer { lock.unlock() }
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        purgeLegacyUnsanitizedLogsIfNeeded(in: directory)
        _ = ensureHandle()
    }

    private func purgeLegacyUnsanitizedLogsIfNeeded(in directory: URL) {
        let marker = directory.appendingPathComponent("diagnostics-v2.marker")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: logURL)
        for index in 1...retainedFileCount {
            try? manager.removeItem(at: rotatedURL(index))
        }
        _ = manager.createFile(
            atPath: marker.path,
            contents: Data("sanitized-jsonl\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        try? manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
    }

    @discardableResult
    private func ensureHandle() -> Bool {
        if handle != nil { return true }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: logURL.path
        )
        guard let opened = try? FileHandle(forWritingTo: logURL) else { return false }
        _ = try? opened.seekToEnd()
        handle = opened
        return true
    }

    private func rotateLocked() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        let oldest = rotatedURL(retainedFileCount)
        try? manager.removeItem(at: oldest)
        if retainedFileCount > 1 {
            for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
                let source = rotatedURL(index)
                let destination = rotatedURL(index + 1)
                if manager.fileExists(atPath: source.path) {
                    try? manager.moveItem(at: source, to: destination)
                }
            }
        }
        if manager.fileExists(atPath: logURL.path) {
            try? manager.moveItem(at: logURL, to: rotatedURL(1))
        }
        _ = ensureHandle()
    }

    private func rotatedURL(_ index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)")
    }
}

final class NodePortCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var capturedPort: Int?

    var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return capturedPort
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > 256 * 1_024 {
            buffer = Data(buffer.suffix(256 * 1_024))
        }
        let text = String(decoding: buffer, as: UTF8.self)
        let pattern = #"http://127\.0\.0\.1:(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ).last,
              let range = Range(match.range(at: 1), in: text) else { return }
        capturedPort = Int(text[range])
    }
}

enum NodeBundleRuntimeError: Error, Equatable, LocalizedError {
    case downloadFailed(resource: String, detail: String)
    case missingTrustedSHA256(finalURL: URL)
    case sha256Mismatch(expected: String, actual: String, finalURL: URL)
    case integrityRejected(String)
    case legacyCacheUnavailable(String)
    case legacyMD5Mismatch(expected: String, actual: String)
    case legacyMigrationFailed(String)
    case invalidCacheMetadata(String)
    case bundledNodeMissing
    case invalidNodeEnvironment(String)
    case nodeLaunchFailed(String)
    case nodeExitedUnexpectedly(String)
    case endpointUnavailable(String)
    case unsupportedHostContract
    case configurationContractInvalid
    case hostCapabilityUnavailable
    case portAllocationFailed
    case loopbackEnforcementFailed
    case contractBReadinessFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let resource, let detail):
            return "Node \(resource)下载失败：\(detail)"
        case .missingTrustedSHA256(let finalURL):
            return "安全拒绝：HTTP Node 可执行 bundle 缺少可信 SHA-256（最终地址：\(LogRedactor.url(finalURL))）"
        case .sha256Mismatch(let expected, let actual, let finalURL):
            return "安全拒绝：Node bundle SHA-256 不匹配（最终地址：\(LogRedactor.url(finalURL))，期望 \(expected)，实际 \(actual)）"
        case .integrityRejected(let detail):
            return "安全拒绝：Node bundle 完整性校验失败：\(detail)"
        case .legacyCacheUnavailable(let detail):
            return "Node bundle 下载失败，且没有可迁移的离线旧缓存：\(detail)"
        case .legacyMD5Mismatch(let expected, let actual):
            return "安全拒绝：旧缓存 MD5 不匹配（期望 \(expected)，实际 \(actual)）"
        case .legacyMigrationFailed(let detail):
            return "Node 旧缓存迁移失败：\(detail)"
        case .invalidCacheMetadata(let detail):
            return "安全拒绝：Node 缓存元数据无效：\(detail)"
        case .bundledNodeMissing:
            return "内置 Node 缺失：应用包中没有可执行的 NodeRuntime/node，请重新安装 Release 版本"
        case .invalidNodeEnvironment(let detail):
            return "Node 运行环境不满足安全要求：\(detail)"
        case .nodeLaunchFailed(let detail):
            return "内置 Node 启动失败：\(detail)"
        case .nodeExitedUnexpectedly(let detail):
            return "Node 运行进程意外退出：\(detail)"
        case .endpointUnavailable(let detail):
            return "Node 服务端点不可用：\(detail)"
        case .unsupportedHostContract:
            return "Node 运行协议不受支持"
        case .configurationContractInvalid:
            return "Node 源配置不完整或格式不受支持"
        case .hostCapabilityUnavailable:
            return "Node 宿主能力初始化失败"
        case .portAllocationFailed:
            return "Node 本地服务端口分配失败"
        case .loopbackEnforcementFailed:
            return "Node 本地服务未通过回环地址安全校验"
        case .contractBReadinessFailed:
            return "Node 本地服务能力校验失败"
        }
    }

    var allowsCachedFallback: Bool {
        switch self {
        case .downloadFailed, .missingTrustedSHA256:
            // Never execute the just-downloaded unpinned HTTP bytes. A
            // pre-existing cache may still be used after its own MD5/SHA-256
            // validation (including one-time legacy TOFU migration).
            return true
        default:
            return false
        }
    }

    var diagnosticClassification: NodeDiagnosticClassification {
        switch self {
        case .downloadFailed:
            return .init(category: .transport, code: .transportUnavailable)
        case .missingTrustedSHA256:
            return .init(category: .trust, code: .trustMissingPin)
        case .sha256Mismatch:
            return .init(category: .trust, code: .trustSHA256Mismatch)
        case .integrityRejected:
            return .init(category: .trust, code: .trustIntegrityRejected)
        case .legacyCacheUnavailable:
            return .init(category: .cache, code: .cacheMissing)
        case .legacyMD5Mismatch:
            return .init(category: .cache, code: .cacheLegacyMD5Mismatch)
        case .legacyMigrationFailed:
            return .init(category: .cache, code: .cacheMigrationFailed)
        case .invalidCacheMetadata:
            return .init(category: .cache, code: .cacheInvalidMetadata)
        case .bundledNodeMissing, .invalidNodeEnvironment, .nodeLaunchFailed,
             .unsupportedHostContract, .configurationContractInvalid,
             .hostCapabilityUnavailable, .portAllocationFailed,
             .loopbackEnforcementFailed, .contractBReadinessFailed:
            return .init(category: .runtime, code: .runtimeLaunchFailed)
        case .nodeExitedUnexpectedly:
            return .init(category: .runtime, code: .runtimeExited)
        case .endpointUnavailable:
            return .init(category: .runtime, code: .runtimeUnavailable)
        }
    }
}

struct NodeBundleSourceDescriptor: Equatable, Sendable {
    static let checksumSuffix = ".js.md5"

    let originalURL: URL
    let checksumURL: URL
    let scriptURL: URL
    let authorizationHeader: String?
    let sourceID: String?
    let declaredVersion: String?
    let expectedSHA256: String?
    let pinIdentity: String
    let cacheKey: String
    let legacyCacheKey: String

    static func supports(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        return url.path.lowercased().hasSuffix(checksumSuffix)
    }

    init(url: URL) throws {
        guard Self.supports(url),
              var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else {
            throw AppError.configuration(
                "Node 资源地址必须以 .js.md5 结尾"
            )
        }
        let username = components.user
        let password = components.password
        guard (username == nil) == (password == nil) else {
            throw AppError.configuration("Node 资源地址的账号和密码必须同时提供")
        }

        let fragmentValues = Self.fragmentValues(components.fragment)
        let expectedSHA256 = fragmentValues["sha256"]?.lowercased()
        if let expectedSHA256,
           expectedSHA256.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
           ) == nil {
            throw AppError.configuration(
                "Node 资源 URL fragment 中的 sha256 必须是 64 位十六进制"
            )
        }
        let sourceID = Self.nonEmptyFragmentValue(fragmentValues["source"])
        let declaredVersion = Self.nonEmptyFragmentValue(fragmentValues["version"])
        components.fragment = nil

        // Credentials must never travel over cleartext HTTP. Existing source
        // lists commonly publish an http:// URL even though the same host has
        // HTTPS enabled, so authenticated Node bundles are upgraded here.
        if components.scheme?.lowercased() == "http", username != nil {
            components.scheme = "https"
        }
        components.user = nil
        components.password = nil
        guard let checksumURL = components.url else {
            throw AppError.configuration("Node 资源校验地址无效")
        }

        let checksumPath = components.percentEncodedPath
        guard checksumPath.lowercased().hasSuffix(".md5") else {
            throw AppError.configuration("Node 资源校验地址缺少 .md5 后缀")
        }
        components.percentEncodedPath = String(checksumPath.dropLast(4))
        guard let scriptURL = components.url else {
            throw AppError.configuration("Node 资源脚本地址无效")
        }

        let authorizationHeader: String?
        if let username, let password {
            authorizationHeader = "Basic "
                + Data("\(username):\(password)".utf8).base64EncodedString()
        } else {
            authorizationHeader = nil
        }

        self.originalURL = url
        self.checksumURL = checksumURL
        self.scriptURL = scriptURL
        self.authorizationHeader = authorizationHeader
        self.sourceID = sourceID
        self.declaredVersion = declaredVersion
        self.expectedSHA256 = expectedSHA256
        pinIdentity = [
            "request=\(checksumURL.absoluteString)",
            "source=\(sourceID ?? "-")",
            "version=\(declaredVersion ?? "-")"
        ].joined(separator: "\n")
        cacheKey = Self.sha256Hex(
            Data(
                ([
                    pinIdentity,
                    "pin=\(expectedSHA256 ?? "-")",
                    "authorization=\(authorizationHeader ?? "-")"
                ].joined(separator: "\n"))
                    .utf8
            )
        )
        legacyCacheKey = Self.sha256Hex(
            Data(
                (checksumURL.absoluteString + "\n" + (authorizationHeader ?? ""))
                    .utf8
            )
        )
    }

    private static func fragmentValues(_ fragment: String?) -> [String: String] {
        guard let fragment, !fragment.isEmpty else { return [:] }
        var parser = URLComponents()
        parser.percentEncodedQuery = fragment
        return (parser.queryItems ?? []).reduce(into: [:]) { values, item in
            guard let value = item.value else { return }
            values[item.name.lowercased()] = value
        }
    }

    private static func nonEmptyFragmentValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NodeRuntimeProfileNamespace: Equatable, Sendable {
    let configurationIdentity: String
    let sourceIdentity: String
    let publisherIdentity: String
    let storageKey: String

    init(
        configurationID: UUID?,
        descriptor: NodeBundleSourceDescriptor
    ) {
        configurationIdentity = configurationID?.uuidString.lowercased()
            ?? "unassigned"
        sourceIdentity = descriptor.checksumURL.absoluteString
        publisherIdentity = descriptor.sourceID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nonEmptyProfileValue ?? Self.originIdentity(for: descriptor.checksumURL)
        storageKey = Self.sha256Hex(
            Data(
                [
                    configurationIdentity,
                    sourceIdentity,
                    publisherIdentity
                ]
                    .joined(separator: "\u{0}")
                    .utf8
            )
        )
    }

    static func originIdentityForMigration(sourceURLString: String?) -> String {
        guard let sourceURLString, let url = URL(string: sourceURLString) else {
            return "unknown-publisher"
        }
        return originIdentity(for: url)
    }

    private static func originIdentity(for url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        components.port = url.port
        return components.string ?? url.host?.lowercased() ?? "unknown-publisher"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nonEmptyProfileValue: String? {
        isEmpty ? nil : self
    }
}

enum NodeBundleTrustState: String, Codable, Equatable, Sendable {
    case httpsTransport
    case publisherSHA256
    case legacyTOFU
}

/// Applies narrowly-scoped runtime compatibility fixes after the downloaded
/// bundle has passed its publisher integrity checks. The verified cache is
/// never modified: a patched execution copy is generated for the current
/// process and removed with the other Contract-B runtime files.
enum NodeBundleRuntimeCompatibilityPatcher {
    private static let supportedHost = "raw.githubusercontent.com"
    private static let supportedPathSuffix =
        "/Darklessing/catvod/refs/heads/main/douer/index.js"
    private static let baiduStartMarker =
        "var C40=qe(J6(),1),N40=qe(oa(),1);var bE="
    private static let baiduEndMarker = "var Wqt=require(\"crypto\");"

    static func patchedScript(
        _ data: Data,
        sourceURL: URL
    ) throws -> Data? {
        guard sourceURL.host?.lowercased() == supportedHost,
              sourceURL.path.hasSuffix(supportedPathSuffix),
              var source = String(data: data, encoding: .utf8),
              let start = source.range(of: baiduStartMarker)?.lowerBound,
              let end = source.range(
                of: baiduEndMarker,
                range: start..<source.endIndex
              )?.lowerBound else {
            return nil
        }
        let replacement = #"""
var C40=qe(J6(),1),N40=qe(oa(),1);var bE="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",P7={NEW:"NEW",SCANNED:"SCANNED",CONFIRMED:"CONFIRMED",EXPIRED:"EXPIRED",CANCELED:"CANCELED",RETRYING:"RETRYING",RETRYABLE_ERROR:"RETRYABLE_ERROR"},zqt={encode(e,t=3e5){let r={data:e,expireTime:Date.now()+t};return Buffer.from(JSON.stringify(r)).toString("base64url")},decode(e){try{if(!e)return null;let t=JSON.parse(Buffer.from(e,"base64url").toString());return Date.now()>t.expireTime?null:t.data}catch{return null}}},qVe=require("crypto"),BVe=new Map,AVe="",v5n=async e=>(await e.db.getObjectDefault("/baidu",{}))["baidu_cookie"]??"",KVe=async e=>(await e.db.getObjectDefault("/baidu",{}))["credential_revision"]??"",GAe=async(e,t)=>{let r=qVe.randomUUID();await e.db.push("/baidu/baidu_cookie",t),await e.db.push("/baidu/credential_revision",r);return r};function E5n(){return qVe.randomUUID()}function zVe(){let e=Date.now();for(let[t,r]of BVe)r.expiresAt<=e&&BVe.delete(t);for(;BVe.size>12;){let t=BVe.keys().next().value;t&&BVe.delete(t)}}function HVe(e,t,r){return{authorizationSessionID:e?.id||"",status:t||e?.status||P7.NEW,message:r||e?.message||"",credentialRevision:e?.credentialRevision||"",expiresAt:e?.expiresAt||0}}async function VVe(e){let t=await ge.get("https://pan.baidu.com/api/gettemplatevariable",{params:{clienttype:0,app_id:250528,web:1,fields:'["username","uk"]'},headers:{"User-Agent":bE,Referer:"https://pan.baidu.com/",Cookie:e},timeout:15e3,validateStatus:()=>!0}),r=t?.data;if(t.status<200||t.status>=300||!r||Number(r.errno)!==0||!r.result)throw new Error("百度 Cookie 已写入但登录验证未通过");return!0}async function YAe(e){e.get("/qrcode",async(r,n)=>{try{zVe();if(AVe){let h=BVe.get(AVe);h&&!h.credentialRevision&&(h.cancelled=!0,h.status=P7.CANCELED,h.message="已生成新的二维码")}let i=E5n(),a=Date.now().toString(),s=Math.floor(Date.now()/1e3).toString(),o=`tangram_guid_${a}`,c=(await ge.get("https://passport.baidu.com/v2/api/getqrcode",{params:{lp:"pc",qrloginfrom:"pc",gid:i,callback:o,apiver:"v3",tt:s,tpl:"netdisk",_:a},headers:{"User-Agent":bE,Referer:"https://pan.baidu.com","sec-ch-ua-platform":'"Windows"',DNT:"1"},timeout:2e4})).data;if(typeof c!="string")throw new Error("响应格式错误");c=c.replace(/^[^(]*\(/,"").replace(/\);?$/,"");let u=JSON.parse(c);if(u.errno!==0)throw new Error(`获取二维码失败: ${u.errmsg||"未知错误"}`);let l=E5n(),d={id:l,sign:u.sign,channelId:u.channel_id,status:P7.NEW,message:"等待手机扫码",createdAt:Date.now(),expiresAt:Date.now()+3e5,cancelled:!1,pollPromise:null,exchangePromise:null,credentialRevision:""};BVe.set(l,d),AVe=l;let f=zqt.encode({sign:u.sign,channel_id:u.channel_id,authorizationSessionID:l}),p=await ge.get("https://"+u.imgurl,{responseType:"arraybuffer",headers:{"User-Agent":bE},timeout:2e4});n.header("X-Session-Key",f),n.header("X-Authorization-Session-ID",l),n.send(p.data)}catch(i){console.error("百度二维码获取失败:",i?.message||i),n.status(500).send({code:-1,message:i?.message||"获取二维码失败"})}}),e.post("/check-status",async(r,n)=>{let{sessionKey:i}=r.body,a=zqt.decode(i);if(!a)return n.send({code:0,data:HVe(null,P7.EXPIRED,"二维码会话已过期")});let s=BVe.get(a.authorizationSessionID);if(!s||s.sign!==a.sign)return n.send({code:0,data:HVe(null,P7.EXPIRED,"二维码会话不存在或已过期")});if(s.cancelled)return n.send({code:0,data:HVe(s,P7.CANCELED,s.message)});if(s.credentialRevision)return n.send({code:0,data:HVe(s,P7.CONFIRMED,"百度授权已验证")});try{s.pollPromise||(s.pollPromise=(async()=>{try{let o=Date.now().toString(),c=`tangram_guid_${o}`,u=(await ge.get("https://passport.baidu.com/channel/unicast",{params:{channel_id:s.sign,tpl:"netdisk",apiver:"v3",tt:Math.floor(Date.now()/1e3).toString(),callback:c,_:o},headers:{"User-Agent":bE,Referer:"https://pan.baidu.com"},timeout:2e4})).data;if(s.cancelled)return HVe(s,P7.CANCELED,"授权已取消");if(typeof u==="string"){let l=JSON.parse(u.replace(/^[^(]*\(/,"").replace(/\);?\s*$/,"").trim());if(l.errno===1){s.status=P7.NEW;s.message="等待手机扫码";return HVe(s)}if(l.errno===2){s.status=P7.EXPIRED;s.message="二维码已过期";return HVe(s)}if(l.errno===0&&l.channel_v){let d=JSON.parse(l.channel_v);if(d.status===1){s.status=P7.SCANNED;s.message="已扫码，等待手机确认";return HVe(s)}if(d.status===0&&d.v){s.exchangePromise||(s.exchangePromise=t(d.v,r.server,s));let f=await s.exchangePromise;if(s.cancelled)return HVe(s,P7.CANCELED,"授权已取消");s.credentialRevision=f,s.status=P7.CONFIRMED,s.message="百度授权已验证";return HVe(s)}}}s.status=P7.RETRYING,s.message="正在等待百度确认";return HVe(s)}catch(o){let c=String(o?.code||""),u=c==="ECONNABORTED"||c==="ETIMEDOUT";s.status=u?P7.RETRYING:P7.RETRYABLE_ERROR,s.message=u?"百度状态查询超时，正在重试":"百度状态查询暂时失败，正在重试";return HVe(s)}finally{s.pollPromise=null}})());let o=await s.pollPromise;n.send({code:0,data:o})}catch(o){n.send({code:0,data:HVe(s,P7.RETRYABLE_ERROR,o?.message||"百度状态查询失败，正在重试")})}});async function t(r,n,i){let a=Date.now().toString(),s=Math.floor(Date.now()/1e3).toString(),o=(await ge.get("https://passport.baidu.com/v3/login/main/qrbdusslogin",{params:{v:a,bduss:r,u:"https://pan.baidu.com/disk/main#/index?category=all",loginVersion:"v5",qrcode:"1",tpl:"netdisk",maskId:"",fileId:"",apiver:"v3",tt:a,traceid:"",time:s,alg:"v3",elapsed:"1"},headers:{"User-Agent":bE,Referer:"https://pan.baidu.com/","Accept-Language":"zh-CN,zh;q=0.9"},timeout:3e4})).data;if(i.cancelled)throw new Error("授权已取消");if(typeof o==="string"){o=o.replace(/^[^(]*\(/,"").replace(/\);?\s*$/,"").trim();let c=o.match(/"bduss":\s*"([^"]+)"/),u=o.match(/"stoken":\s*"([^"]+)"/),l=o.match(/"ptoken":\s*"([^"]+)"/),d=o.match(/"ubi":\s*"([^"]+)"/);if(c&&u&&l&&d){let f=c[1],p=u[1],m=l[1],g=encodeURIComponent(d[1]),b=Object.entries({newlogin:"1",UBI:g,STOKEN:p,BDUSS:f,PTOKEN:m,BDUSS_BFESS:f,STOKEN_BFESS:p,PTOKEN_BFESS:m,UBI_BFESS:g}).map(([_,S])=>`${_}=${S}`).join("; "),y=(await ge.get("https://passport.baidu.com/v3/login/api/auth/?return_type=5&tpl=netdisk&u=https://pan.baidu.com/disk/home",{headers:{"User-Agent":bE,Referer:"https://pan.baidu.com/",Cookie:b},maxRedirects:0,validateStatus:_=>_===302||_===200,timeout:2e4})).headers.location,w=`BDUSS=${f};STOKEN=${p};`;if(y){let _=(await ge.get(y,{headers:{"User-Agent":bE,Referer:"https://pan.baidu.com/",Cookie:b},maxRedirects:0,validateStatus:S=>S===302||S===200,timeout:2e4})).headers["set-cookie"],T=_?.find(S=>S.toLowerCase().includes("stoken"));T&&(w=`BDUSS=${f};${T.split(";")[0]};`)}if(i.cancelled)throw new Error("授权已取消");await VVe(w);if(i.cancelled)throw new Error("授权已取消");return await GAe(n,w)}}throw new Error("Cookie解析失败")}e.get("/authorization-state",async(r,n)=>{zVe();let i=AVe?BVe.get(AVe):null,a=await KVe(r.server);n.send({code:0,data:{...HVe(i,i?.status||"IDLE",i?.message||"等待生成百度二维码"),loggedIn:!!a,credentialRevision:i?.credentialRevision||a}})}),e.post("/authorization-cancel",async(r,n)=>{let i=String(r.body?.authorizationSessionID||AVe||""),a=BVe.get(i);a&&(a.cancelled=!0,a.status=P7.CANCELED,a.message="授权已取消"),n.send({code:0,data:HVe(a,P7.CANCELED,"授权已取消")})}),e.post("/cookie",async(r,n)=>{n.send({code:-1,message:"请使用 /check-status 接口"})}),e.get("/cookie",async(r,n)=>{let i=await KVe(r.server);n.send({code:0,data:{loggedIn:!!i,credentialRevision:i}})}),e.put("/cookie",async(r,n)=>{let i=String(r.body?.cookie||"").trim();if(!i){let a=await KVe(r.server);return n.send({code:0,data:{credentialRevision:a},message:"授权凭据已由服务端保存"})}try{await VVe(i);let a=await GAe(r.server,i);n.send({code:0,data:{credentialRevision:a},message:"Cookie 已验证并入库"})}catch(a){n.send({code:-1,message:a?.message||"Cookie 验证失败"})}})}
"""#
        source.replaceSubrange(start..<end, with: replacement)
        let pollingStart = "d(),p.current=setInterval(async()=>{"
        let serialPollingStart = "d();let R=async()=>{"
        if let range = source.range(of: pollingStart) {
            source.replaceSubrange(range, with: serialPollingStart)
        }
        let pollingEnd = "}catch(I){}},2e3),m.current="
        let serialPollingEnd =
            "}catch(I){};p.current&&(p.current=setTimeout(R,2e3))};"
                + "p.current=setTimeout(R,0),m.current="
        if let range = source.range(of: pollingEnd) {
            source.replaceSubrange(range, with: serialPollingEnd)
        }
        // Baidu now commits and verifies credentials on the server. Its
        // CONFIRMED response deliberately contains no Cookie, so the shared
        // QR component must not issue the legacy second PUT.
        let duplicateCookieWrite = "await E.put(t,{cookie:N})"
        if let range = source.range(of: duplicateCookieWrite) {
            source.replaceSubrange(
                range,
                with: "N&&await E.put(t,{cookie:N})"
            )
        }
        guard let patched = source.data(using: .utf8) else {
            throw NodeBundleRuntimeError.integrityRejected(
                "百度兼容补丁生成了无效 UTF-8"
            )
        }
        return patched
    }
}

private extension NodeBundleTrustState {
    var diagnosticState: NodeTrustDiagnosticState {
        switch self {
        case .httpsTransport: return .httpsTransport
        case .publisherSHA256: return .publisherPinned
        case .legacyTOFU: return .legacyTOFU
        }
    }
}

enum NodeRuntimeStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(URL)
    case restarting(attempt: Int, reason: String)
    case failed(String)
}

struct NodeBundleCacheSnapshot: Equatable, Sendable {
    let cacheKey: String
    let sha256: String
    let trustState: NodeBundleTrustState
}

actor NodeBundleRuntimeService {
    private struct CachedBundle: Sendable {
        let sourceID: String?
        let cacheKey: String
        let scriptURL: URL
        let md5: String
        let sha256: String
        let expectedSHA256: String?
        let finalChecksumURL: URL
        let finalScriptURL: URL
        let runtimeDirectory: URL
        let trustState: NodeBundleTrustState
    }

    private enum StartupSource: Sendable {
        case descriptor(NodeBundleSourceDescriptor, NodeRuntimeProfileNamespace)
        case cached(CachedBundle, NodeRuntimeProfileNamespace)

        var cacheKey: String {
            switch self {
            case .descriptor(let descriptor, _): descriptor.cacheKey
            case .cached(let bundle, _): bundle.cacheKey
            }
        }

        var profileNamespace: NodeRuntimeProfileNamespace {
            switch self {
            case .descriptor(_, let namespace), .cached(_, let namespace):
                return namespace
            }
        }
    }

    struct CacheMetadata: Codable, Equatable {
        let pinIdentity: String
        let finalChecksumURL: URL
        let finalScriptURL: URL
        let md5: String
        let sha256: String
        let trustState: NodeBundleTrustState?
    }

    private static let maximumScriptSize = 16 * 1_024 * 1_024
    private static let maximumConfigurationSize = 5 * 1_024 * 1_024

    private let applicationSupportDirectory: URL
    private let cacheDirectory: URL
    private let remoteHTTPClient: HTTPClient
    private let localHTTPClient: HTTPClient
    private let nodeExecutableOverride: URL?
    private let now: () -> Date
    private let migrationCommitHook: (() throws -> Void)?
    private let diagnosticLogMaximumBytes: Int
    private let diagnosticLogRetainedFileCount: Int
    private let readinessTimeout: TimeInterval
    private let readinessPollInterval: TimeInterval
    private let sharedStartup = SharedNodeRuntimeStartup<URL>()

    private var process: Process?
    private var outputPipe: Pipe?
    private var activeDiagnosticWriter: NodeDiagnosticLogWriter?
    private var diagnosticWriters: [String: NodeDiagnosticLogWriter] = [:]
    private var activeBundleCacheKey: String?
    private var activeProfileStorageKey: String?
    private var activeContractCleanupURLs: [URL] = []
    private var serviceBaseURL: URL?
    private var status: NodeRuntimeStatus = .stopped
    private var statusContinuations: [UUID: AsyncStream<NodeRuntimeStatus>.Continuation] = [:]
    private var desiredBundle: CachedBundle?
    private var desiredProfileNamespace: NodeRuntimeProfileNamespace?
    private var processGeneration = UUID()
    private var restartTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var startupCacheKey: String?
    private var startupProfileStorageKey: String?
    private var startupGeneration: UUID?

    static let restartDelays: [TimeInterval] = [1, 2, 5]

    init(
        applicationSupportDirectory: URL,
        cacheDirectory: URL,
        remoteHTTPClient: HTTPClient,
        nodeExecutableURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        migrationCommitHook: (() throws -> Void)? = nil,
        diagnosticLogMaximumBytes: Int = 4 * 1_024 * 1_024,
        diagnosticLogRetainedFileCount: Int = 3,
        readinessTimeout: TimeInterval = 90,
        readinessPollInterval: TimeInterval = 0.1
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cacheDirectory = cacheDirectory
        self.remoteHTTPClient = remoteHTTPClient
        nodeExecutableOverride = nodeExecutableURL
        self.now = now
        self.migrationCommitHook = migrationCommitHook
        self.diagnosticLogMaximumBytes = diagnosticLogMaximumBytes
        self.diagnosticLogRetainedFileCount = diagnosticLogRetainedFileCount
        self.readinessTimeout = max(0.1, readinessTimeout)
        self.readinessPollInterval = max(0.01, readinessPollInterval)
        Self.purgeLegacyNodeLogsIfNeeded(
            applicationSupportDirectory: applicationSupportDirectory
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        localHTTPClient = URLSessionHTTPClient(configuration: configuration)
    }

    private static func purgeLegacyNodeLogsIfNeeded(
        applicationSupportDirectory: URL
    ) {
        let manager = FileManager.default
        let root = applicationSupportDirectory
            .appendingPathComponent("NodeRuntime", isDirectory: true)
        let marker = root.appendingPathComponent("diagnostics-v2.marker")
        guard !manager.fileExists(atPath: marker.path) else { return }
        try? manager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let directories = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in directories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true,
                    let files = try? manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    ) else { continue }
                for file in files where file.lastPathComponent == "node.log"
                    || file.lastPathComponent.hasPrefix("node.log.") {
                    try? manager.removeItem(at: file)
                }
            }
        }
        _ = manager.createFile(
            atPath: marker.path,
            contents: Data("sanitized-jsonl\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        try? manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
    }

    static func supports(_ url: URL) -> Bool {
        NodeBundleSourceDescriptor.supports(url)
    }

    func loadConfiguration(
        from sourceURL: URL,
        configurationID: UUID? = nil
    ) async throws -> LoadedConfiguration {
        let baseURL = try await ensureReady(
            from: sourceURL,
            configurationID: configurationID
        )
        try Task.checkCancellation()
        let configURL = baseURL.appendingPathComponent("config")
        let response = try await localHTTPClient.send(
            HTTPRequest(
                url: configURL,
                timeout: 60,
                maximumResponseBytes: Self.maximumConfigurationSize,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 1, initialDelay: 0.25)
            )
        )
        try Task.checkCancellation()
        let normalized = try Self.normalizeConfiguration(response.body)
        try Task.checkCancellation()
        let parsed = try ConfigurationParser().parse(normalized)
        try Task.checkCancellation()
        return LoadedConfiguration(
            source: .remote(sourceURL),
            baseURL: baseURL,
            rawData: normalized,
            configuration: parsed,
            loadedAt: now()
        )
    }

    /// Returns only after the selected contract's readiness policy succeeds.
    /// Contract A retains its `/health` identity check; Contract B requires an
    /// observed loopback listener plus a validated `/config` capability.
    func ensureReady(
        from sourceURL: URL,
        configurationID: UUID? = nil
    ) async throws -> URL {
        let descriptor = try NodeBundleSourceDescriptor(url: sourceURL)
        let profileNamespace = NodeRuntimeProfileNamespace(
            configurationID: configurationID,
            descriptor: descriptor
        )
        return try await ensureReady(
            source: .descriptor(descriptor, profileNamespace),
            automaticRestart: false
        )
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        startupGeneration = nil
        startupCacheKey = nil
        startupProfileStorageKey = nil
        await sharedStartup.cancel()
        desiredBundle = nil
        desiredProfileNamespace = nil
        restartAttempt = 0
        stopProcess(publishing: .stopped)
    }

    func recordDiagnosticEvent(_ event: NodeDiagnosticEvent) {
        activeDiagnosticWriter?.write(event)
    }

    func statusUpdates() -> AsyncStream<NodeRuntimeStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            statusContinuations[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStatusContinuation(id) }
            }
        }
    }

    func currentStatus() -> NodeRuntimeStatus {
        status
    }

    func prepareBundleForTesting(from sourceURL: URL) async throws -> NodeBundleCacheSnapshot {
        let descriptor = try NodeBundleSourceDescriptor(url: sourceURL)
        let bundle = try await obtainBundle(descriptor)
        return NodeBundleCacheSnapshot(
            cacheKey: descriptor.cacheKey,
            sha256: bundle.sha256,
            trustState: bundle.trustState
        )
    }

    static func normalizeConfiguration(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.configuration("Node 服务的 /config 未返回 JSON 对象")
        }

        var sites: [[String: Any]]
        if let directSites = root["sites"] as? [[String: Any]] {
            sites = directSites
        } else if let video = root["video"] as? [String: Any],
                  let videoSites = video["sites"] as? [[String: Any]] {
            sites = videoSites
            if root["danmaku"] == nil,
               let danmaku = video["danmuSearchUrl"] as? String,
               !danmaku.isEmpty {
                root["danmaku"] = danmaku
            }
        } else {
            throw AppError.configuration("Node 服务的 /config 缺少 video.sites")
        }

        sites = sites.map { rawSite in
            var site = rawSite
            site["okNodeRuntime"] = true
            if site["hide"] == nil, let enabled = site["enable"] as? Bool, !enabled {
                site["hide"] = 1
            }
            return site
        }
        root["sites"] = sites

        do {
            return try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw AppError.configuration(
                "无法转换 Node 服务配置：\(error.localizedDescription)"
            )
        }
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func requiresTrustedSHA256(
        finalChecksumURL: URL,
        finalScriptURL: URL
    ) throws -> Bool {
        let schemes = [finalChecksumURL, finalScriptURL].map {
            $0.scheme?.lowercased() ?? ""
        }
        guard schemes.allSatisfy({ $0 == "http" || $0 == "https" }) else {
            throw NodeBundleRuntimeError.integrityRejected(
                "重定向后的地址不是 HTTP/HTTPS"
            )
        }
        return schemes.contains("http")
    }

    static func validateTrustedSHA256(
        expected: String?,
        actual: String,
        requiresTrustedSHA256: Bool,
        finalScriptURL: URL
    ) throws {
        if requiresTrustedSHA256, expected == nil {
            throw NodeBundleRuntimeError.missingTrustedSHA256(
                finalURL: finalScriptURL
            )
        }
        guard let expected else { return }
        guard expected == actual else {
            throw NodeBundleRuntimeError.sha256Mismatch(
                expected: expected,
                actual: actual,
                finalURL: finalScriptURL
            )
        }
    }

    static func sanitizedNodeEnvironment(
        bundlePath: URL,
        runtimeDirectory: URL,
        temporaryDirectory: URL,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        contractAdditions: [String: String] = [:]
    ) throws -> [String: String] {
        var environment = [
            "HOST": "127.0.0.1",
            "PORT": "0",
            "NODE_ENV": "production",
            "HOME": runtimeDirectory.path,
            "TMPDIR": temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "OKVIDEO_BUNDLE_PATH": bundlePath.path,
            "OKVIDEO_PARENT_PID": String(parentPID)
        ]
        let allowedContractBNames = Set([
            "DEV_HTTP_PORT",
            "OKVIDEO_CONTRACT_B_CONFIG_PATH",
            "OKVIDEO_CONTRACT_B_STATE_PATH",
            "OKVIDEO_CONTRACT_B_PROFILE_PATH"
        ])
        guard Set(contractAdditions.keys).isSubset(of: allowedContractBNames) else {
            throw NodeBundleRuntimeError.invalidNodeEnvironment(
                "Contract 注入了未授权环境变量"
            )
        }
        environment.merge(contractAdditions) { _, addition in addition }
        let forbiddenNames = environment.keys.filter {
            $0 == "NODE_OPTIONS"
                || $0 == "NODE_PATH"
                || $0.hasPrefix("DYLD_")
                || $0.hasPrefix("LD_")
        }
        guard forbiddenNames.isEmpty else {
            throw NodeBundleRuntimeError.invalidNodeEnvironment(
                "包含禁止变量：\(forbiddenNames.sorted().joined(separator: ", "))"
            )
        }
        return environment
    }

    static func validateBundleDataForExecution(
        _ data: Data,
        expectedMD5: String,
        expectedInternalSHA256: String,
        trustedSHA256: String?,
        finalChecksumURL: URL,
        finalScriptURL: URL
    ) throws {
        guard data.count <= Self.maximumScriptSize else {
            throw NodeBundleRuntimeError.integrityRejected(
                "执行前脚本超过 16 MiB 限制"
            )
        }
        let actualMD5 = Self.md5Hex(data)
        guard actualMD5 == expectedMD5 else {
            throw NodeBundleRuntimeError.integrityRejected(
                "执行前 MD5 不匹配，缓存可能已被篡改"
            )
        }
        let actualSHA256 = Self.sha256Hex(data)
        guard actualSHA256 == expectedInternalSHA256 else {
            throw NodeBundleRuntimeError.integrityRejected(
                "执行前 SHA-256 不匹配，缓存可能已被篡改"
            )
        }
        try Self.validateTrustedSHA256(
            expected: trustedSHA256,
            actual: actualSHA256,
            requiresTrustedSHA256: try Self.requiresTrustedSHA256(
                finalChecksumURL: finalChecksumURL,
                finalScriptURL: finalScriptURL
            ),
            finalScriptURL: finalScriptURL
        )
    }

    private func obtainBundle(
        _ descriptor: NodeBundleSourceDescriptor
    ) async throws -> CachedBundle {
        let writer = diagnosticWriter(for: descriptor)
        do {
            return try await downloadBundle(descriptor)
        } catch let downloadError {
            record(
                error: downloadError,
                context: .bundleTransport,
                descriptor: descriptor,
                writer: writer
            )
            let allowsFallback = (downloadError as? NodeBundleRuntimeError)?
                .allowsCachedFallback == true
            guard allowsFallback else { throw downloadError }

            let currentCache = cacheURL(for: descriptor.cacheKey)
            if FileManager.default.fileExists(atPath: currentCache.path) {
                do {
                    let cached = try loadCachedBundle(descriptor, cacheURL: currentCache)
                    writer.write(
                        diagnosticEvent(
                            category: .cache,
                            severity: .info,
                            code: .trustAccepted,
                            message: "Validated current Node bundle cache",
                            descriptor: descriptor,
                            trustState: cached.trustState.diagnosticState
                        )
                    )
                    return cached
                } catch {
                    record(
                        error: error,
                        context: .bundleTransport,
                        descriptor: descriptor,
                        writer: writer
                    )
                    // The first hardened build created the destination directory
                    // before it knew whether metadata existed. Treat only a
                    // completely empty directory as an interrupted cache write;
                    // any executable/cache material must fail closed.
                    let contents = try? FileManager.default.contentsOfDirectory(
                        at: currentCache,
                        includingPropertiesForKeys: nil
                    )
                    guard contents?.isEmpty == true else { throw error }
                }
            }
            do {
                writer.write(
                    diagnosticEvent(
                        category: .cache,
                        severity: .info,
                        code: .cacheLegacyDetected,
                        message: "Legacy Node bundle cache migration requested",
                        descriptor: descriptor
                    )
                )
                return try migrateLegacyCache(descriptor)
            } catch NodeBundleRuntimeError.legacyCacheUnavailable(let detail) {
                throw NodeBundleRuntimeError.legacyCacheUnavailable(
                    "\(downloadError.localizedDescription)；\(detail)"
                )
            } catch let migrationError as NodeBundleRuntimeError {
                throw migrationError
            } catch {
                throw NodeBundleRuntimeError.legacyMigrationFailed(
                    error.localizedDescription
                )
            }
        }
    }

    private func downloadBundle(
        _ descriptor: NodeBundleSourceDescriptor
    ) async throws -> CachedBundle {
        let writer = diagnosticWriter(for: descriptor)
        var headers = HTTPHeaders()
        if let authorization = descriptor.authorizationHeader {
            headers["Authorization"] = authorization
        }

        let checksumResponse: HTTPResponse
        do {
            writer.write(
                diagnosticEvent(
                    category: .transport,
                    severity: .info,
                    code: .bundleRequest,
                    message: "Requesting Node bundle checksum",
                    descriptor: descriptor,
                    originalURL: descriptor.checksumURL
                )
            )
            checksumResponse = try await sendBundleRequest(
                HTTPRequest(
                    url: descriptor.checksumURL,
                    headers: headers,
                    timeout: 20,
                    maximumResponseBytes: 256,
                    retryPolicy: HTTPRetryPolicy(maximumRetries: 2),
                    allowsNonSuccessfulStatus: true
                )
            )
            writer.write(
                diagnosticEvent(
                    category: .transport,
                    severity: .info,
                    code: .bundleResponse,
                    message: "Received Node bundle checksum response",
                    descriptor: descriptor,
                    response: checksumResponse
                )
            )
            guard (200...299).contains(checksumResponse.statusCode) else {
                throw HTTPClientError.statusCode(checksumResponse.statusCode)
            }
        } catch {
            record(
                error: error,
                context: .bundleTransport,
                descriptor: descriptor,
                writer: writer
            )
            throw NodeBundleRuntimeError.downloadFailed(
                resource: "MD5 校验文件",
                detail: error.localizedDescription
            )
        }
        let checksum: String
        do {
            checksum = try checksumResponse.text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } catch {
            throw NodeBundleRuntimeError.integrityRejected(
                "上游 .md5 响应无法解码"
            )
        }
        guard checksum.range(
            of: "^[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil else {
            throw NodeBundleRuntimeError.integrityRejected(
                "上游 .md5 响应不是 32 位 MD5"
            )
        }

        let scriptResponse: HTTPResponse
        do {
            writer.write(
                diagnosticEvent(
                    category: .transport,
                    severity: .info,
                    code: .bundleRequest,
                    message: "Requesting Node executable bundle",
                    descriptor: descriptor,
                    originalURL: descriptor.scriptURL
                )
            )
            scriptResponse = try await sendBundleRequest(
                HTTPRequest(
                    url: descriptor.scriptURL,
                    headers: headers,
                    timeout: 60,
                    maximumResponseBytes: Self.maximumScriptSize,
                    retryPolicy: HTTPRetryPolicy(maximumRetries: 2),
                    allowsNonSuccessfulStatus: true
                )
            )
            writer.write(
                diagnosticEvent(
                    category: .transport,
                    severity: .info,
                    code: .bundleResponse,
                    message: "Received Node executable bundle response",
                    descriptor: descriptor,
                    response: scriptResponse
                )
            )
            guard (200...299).contains(scriptResponse.statusCode) else {
                throw HTTPClientError.statusCode(scriptResponse.statusCode)
            }
        } catch {
            record(
                error: error,
                context: .bundleTransport,
                descriptor: descriptor,
                writer: writer
            )
            throw NodeBundleRuntimeError.downloadFailed(
                resource: "可执行脚本",
                detail: error.localizedDescription
            )
        }
        let requiresTrustedSHA256 = try Self.requiresTrustedSHA256(
            finalChecksumURL: checksumResponse.url,
            finalScriptURL: scriptResponse.url
        )
        let actualMD5 = Self.md5Hex(scriptResponse.body)
        guard actualMD5 == checksum else {
            throw NodeBundleRuntimeError.integrityRejected(
                "上游 MD5 不匹配（期望 \(checksum)，实际 \(actualMD5)）"
            )
        }
        guard String(data: scriptResponse.body, encoding: .utf8) != nil else {
            throw NodeBundleRuntimeError.integrityRejected("脚本不是有效 UTF-8")
        }
        let actualSHA256 = Self.sha256Hex(scriptResponse.body)
        if let knownHash = currentLegacyTOFUHash(descriptor), knownHash != actualSHA256 {
            writer.write(
                diagnosticEvent(
                    category: .trust,
                    severity: .error,
                    code: .trustHashChanged,
                    message: "Remote Node bundle hash differs from the established legacy trust record",
                    descriptor: descriptor,
                    response: scriptResponse,
                    trustState: .hashChanged
                )
            )
        }
        try Self.validateTrustedSHA256(
            expected: descriptor.expectedSHA256,
            actual: actualSHA256,
            requiresTrustedSHA256: requiresTrustedSHA256,
            finalScriptURL: scriptResponse.url
        )

        let trustState: NodeBundleTrustState = descriptor.expectedSHA256 == nil
            ? .httpsTransport
            : .publisherSHA256
        let metadata = CacheMetadata(
            pinIdentity: descriptor.pinIdentity,
            finalChecksumURL: checksumResponse.url,
            finalScriptURL: scriptResponse.url,
            md5: checksum,
            sha256: actualSHA256,
            trustState: trustState
        )
        let cacheURL = try installCacheAtomically(
            descriptor: descriptor,
            script: scriptResponse.body,
            checksum: checksum,
            metadata: metadata
        )
        let cached = try loadCachedBundle(descriptor, cacheURL: cacheURL)
        writer.write(
            diagnosticEvent(
                category: .trust,
                severity: .info,
                code: .trustAccepted,
                message: "Node bundle trust validation succeeded",
                descriptor: descriptor,
                response: scriptResponse,
                trustState: cached.trustState.diagnosticState
            )
        )
        return cached
    }

    private func sendBundleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        var statusAttempt = 0
        while true {
            let response = try await remoteHTTPClient.send(request)
            if (200...299).contains(response.statusCode) {
                return response
            }
            let retryable = response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
            guard retryable, statusAttempt < 2 else { return response }
            statusAttempt += 1
            try await Task.sleep(
                nanoseconds: UInt64(500_000_000 * statusAttempt)
            )
        }
    }

    private func loadCachedBundle(
        _ descriptor: NodeBundleSourceDescriptor,
        cacheURL: URL
    ) throws -> CachedBundle {
        let scriptURL = cacheURL.appendingPathComponent("index.js")
        let checksumURL = cacheURL.appendingPathComponent("index.js.md5")
        let metadataURL = cacheURL.appendingPathComponent("metadata.json")
        let metadata: CacheMetadata
        do {
            metadata = try JSONDecoder().decode(
                CacheMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
        } catch {
            throw NodeBundleRuntimeError.invalidCacheMetadata(
                error.localizedDescription
            )
        }
        guard metadata.pinIdentity == descriptor.pinIdentity else {
            throw NodeBundleRuntimeError.invalidCacheMetadata(
                "缓存身份与当前 bundle URL/source/version 不一致"
            )
        }
        let data = try Data(contentsOf: scriptURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumScriptSize else {
            throw NodeBundleRuntimeError.integrityRejected("缓存超过 16 MiB 限制")
        }
        let expected = try String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard expected.range(
            of: "^[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil else {
            throw NodeBundleRuntimeError.invalidCacheMetadata("缓存 MD5 格式无效")
        }
        let actual = Self.md5Hex(data)
        guard expected == actual, metadata.md5 == actual else {
            throw NodeBundleRuntimeError.integrityRejected("缓存 MD5 不匹配")
        }
        let actualSHA256 = Self.sha256Hex(data)
        guard metadata.sha256 == actualSHA256 else {
            throw NodeBundleRuntimeError.integrityRejected("缓存 SHA-256 不匹配")
        }
        let requiresTrustedSHA256 = try Self.requiresTrustedSHA256(
            finalChecksumURL: metadata.finalChecksumURL,
            finalScriptURL: metadata.finalScriptURL
        )
        try Self.validateTrustedSHA256(
            expected: descriptor.expectedSHA256,
            actual: actualSHA256,
            requiresTrustedSHA256: requiresTrustedSHA256,
            finalScriptURL: metadata.finalScriptURL
        )
        let trustState = metadata.trustState
            ?? (descriptor.expectedSHA256 == nil ? .httpsTransport : .publisherSHA256)
        return CachedBundle(
            sourceID: descriptor.sourceID,
            cacheKey: descriptor.cacheKey,
            scriptURL: scriptURL,
            md5: expected,
            sha256: actualSHA256,
            expectedSHA256: descriptor.expectedSHA256,
            finalChecksumURL: metadata.finalChecksumURL,
            finalScriptURL: metadata.finalScriptURL,
            runtimeDirectory: try runtimeDirectory(for: descriptor),
            trustState: trustState
        )
    }

    private func migrateLegacyCache(
        _ descriptor: NodeBundleSourceDescriptor
    ) throws -> CachedBundle {
        let legacyURL = cacheURL(for: descriptor.legacyCacheKey)
        let scriptURL = legacyURL.appendingPathComponent("index.js")
        let checksumURL = legacyURL.appendingPathComponent("index.js.md5")
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: checksumURL.path) else {
            throw NodeBundleRuntimeError.legacyCacheUnavailable(
                "旧缓存目录不存在或缺少 index.js/index.js.md5"
            )
        }
        let data = try Data(contentsOf: scriptURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumScriptSize else {
            throw NodeBundleRuntimeError.integrityRejected("旧缓存超过 16 MiB 限制")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw NodeBundleRuntimeError.integrityRejected("旧缓存脚本不是有效 UTF-8")
        }
        let checksum = try String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard checksum.range(
            of: "^[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil else {
            throw NodeBundleRuntimeError.integrityRejected("旧缓存 MD5 格式无效")
        }
        let actualMD5 = Self.md5Hex(data)
        guard checksum == actualMD5 else {
            throw NodeBundleRuntimeError.legacyMD5Mismatch(
                expected: checksum,
                actual: actualMD5
            )
        }
        let actualSHA256 = Self.sha256Hex(data)
        let requiresPin = try Self.requiresTrustedSHA256(
            finalChecksumURL: descriptor.checksumURL,
            finalScriptURL: descriptor.scriptURL
        )
        try Self.validateTrustedSHA256(
            expected: descriptor.expectedSHA256,
            actual: actualSHA256,
            requiresTrustedSHA256: requiresPin,
            finalScriptURL: descriptor.scriptURL
        )
        let metadata = CacheMetadata(
            pinIdentity: descriptor.pinIdentity,
            finalChecksumURL: descriptor.checksumURL,
            finalScriptURL: descriptor.scriptURL,
            md5: checksum,
            sha256: actualSHA256,
            trustState: .legacyTOFU
        )
        let installedURL: URL
        do {
            installedURL = try installCacheAtomically(
                descriptor: descriptor,
                script: data,
                checksum: checksum,
                metadata: metadata,
                beforeCommit: migrationCommitHook
            )
        } catch let error as NodeBundleRuntimeError {
            throw error
        } catch {
            throw NodeBundleRuntimeError.legacyMigrationFailed(
                error.localizedDescription
            )
        }
        let bundle = try loadCachedBundle(descriptor, cacheURL: installedURL)
        diagnosticWriter(for: descriptor).write(
            diagnosticEvent(
                category: .cache,
                severity: .info,
                code: .cacheMigrationSucceeded,
                message: "Legacy Node bundle cache migration succeeded",
                descriptor: descriptor,
                trustState: .legacyTOFU
            )
        )
        return bundle
    }

    private func installCacheAtomically(
        descriptor: NodeBundleSourceDescriptor,
        script: Data,
        checksum: String,
        metadata: CacheMetadata,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> URL {
        let root = cacheRootURL()
        try secureDirectory(root)
        let destination = cacheURL(for: descriptor.cacheKey)
        let staging = root.appendingPathComponent(
            ".\(descriptor.cacheKey).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        try secureDirectory(staging)
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        let scriptURL = staging.appendingPathComponent("index.js")
        let checksumURL = staging.appendingPathComponent("index.js.md5")
        let metadataURL = staging.appendingPathComponent("metadata.json")
        try script.write(to: scriptURL, options: .atomic)
        try Data(checksum.utf8).write(to: checksumURL, options: .atomic)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        for file in [scriptURL, checksumURL, metadataURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
            let handle = try FileHandle(forWritingTo: file)
            try handle.synchronize()
            try handle.close()
        }
        _ = try loadCachedBundle(descriptor, cacheURL: staging)
        try beforeCommit?()

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        committed = true
        return destination
    }

    private func cacheRootURL() -> URL {
        cacheDirectory.appendingPathComponent("NodeBundles", isDirectory: true)
    }

    private func cacheURL(for key: String) -> URL {
        cacheRootURL().appendingPathComponent(key, isDirectory: true)
    }

    private func currentLegacyTOFUHash(
        _ descriptor: NodeBundleSourceDescriptor
    ) -> String? {
        let metadataURL = cacheURL(for: descriptor.cacheKey)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data),
              metadata.pinIdentity == descriptor.pinIdentity,
              metadata.trustState == .legacyTOFU else { return nil }
        return metadata.sha256
    }

    private func diagnosticWriter(
        for descriptor: NodeBundleSourceDescriptor
    ) -> NodeDiagnosticLogWriter {
        if let existing = diagnosticWriters[descriptor.cacheKey] {
            return existing
        }
        let directory = (try? runtimeDirectory(for: descriptor))
            ?? applicationSupportDirectory
                .appendingPathComponent("NodeRuntime", isDirectory: true)
                .appendingPathComponent(descriptor.cacheKey, isDirectory: true)
        let writer = NodeDiagnosticLogWriter(
            logURL: directory.appendingPathComponent("node.log"),
            maximumBytes: diagnosticLogMaximumBytes,
            retainedFileCount: diagnosticLogRetainedFileCount
        )
        diagnosticWriters[descriptor.cacheKey] = writer
        return writer
    }

    private func diagnosticEvent(
        category: NodeDiagnosticCategory,
        severity: NodeDiagnosticSeverity,
        code: NodeDiagnosticCode,
        message: String,
        descriptor: NodeBundleSourceDescriptor,
        originalURL: URL? = nil,
        finalURL: URL? = nil,
        response: HTTPResponse? = nil,
        trustState: NodeTrustDiagnosticState? = nil,
        nodePID: Int32? = nil,
        localPort: Int? = nil
    ) -> NodeDiagnosticEvent {
        NodeDiagnosticEvent(
            timestamp: now(),
            category: category,
            severity: severity,
            code: code,
            message: message,
            sourceID: descriptor.sourceID,
            cacheKey: descriptor.cacheKey,
            originalURL: originalURL,
            finalURL: response?.url ?? finalURL,
            responseDiagnostics: response?.diagnostics,
            httpStatus: response?.statusCode,
            contentType: response?.headers["Content-Type"],
            contentLength: response?.body.count,
            trustState: trustState,
            nodePID: nodePID,
            localPort: localPort
        )
    }

    private func record(
        error: Error,
        context: NodeDiagnosticContext,
        descriptor: NodeBundleSourceDescriptor,
        writer: NodeDiagnosticLogWriter
    ) {
        let classification = NodeDiagnosticClassifier.classify(error, context: context)
        let trustState: NodeTrustDiagnosticState? = classification.category == .trust
            ? (classification.code == .trustSHA256Mismatch ? .hashChanged : .untrusted)
            : nil
        let finalURL: URL?
        if let nodeError = error as? NodeBundleRuntimeError {
            switch nodeError {
            case .missingTrustedSHA256(let url),
                 .sha256Mismatch(_, _, let url):
                finalURL = url
            default:
                finalURL = nil
            }
        } else {
            finalURL = nil
        }
        writer.write(
            diagnosticEvent(
                category: classification.category,
                severity: .error,
                code: classification.code,
                message: error.localizedDescription,
                descriptor: descriptor,
                finalURL: finalURL,
                trustState: trustState
            )
        )
    }

    private func runtimeDirectory(
        for descriptor: NodeBundleSourceDescriptor
    ) throws -> URL {
        let runtime = applicationSupportDirectory
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent(descriptor.cacheKey, isDirectory: true)
        try secureDirectory(runtime)
        return runtime
    }

    private func contractBProfileURL(
        for namespace: NodeRuntimeProfileNamespace,
        currentBundle: CachedBundle
    ) throws -> URL {
        let profileDirectory = applicationSupportDirectory
            .appendingPathComponent("NodeProfiles", isDirectory: true)
            .appendingPathComponent(namespace.storageKey, isDirectory: true)
        try secureDirectory(profileDirectory)
        let profileURL = profileDirectory.appendingPathComponent(
            "contract-b-profile.json"
        )
        if FileManager.default.fileExists(atPath: profileURL.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: profileURL.path
            )
            return profileURL
        }

        guard let legacy = try legacyProfileCandidate(
            for: namespace,
            currentBundle: currentBundle
        ) else {
            return profileURL
        }
        let data = try validatedProfileData(at: legacy.profileURL)
        let backups = profileDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        try secureDirectory(backups)
        let timestamp = Int(now().timeIntervalSince1970)
        let backupURL = backups.appendingPathComponent(
            "contract-b-profile-\(timestamp)-\(legacy.cacheKey.prefix(12)).json"
        )
        try data.write(to: backupURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
        try data.write(to: profileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: profileURL.path
        )
        return profileURL
    }

    private struct LegacyProfileCandidate {
        let profileURL: URL
        let cacheKey: String
        let modifiedAt: Date
    }

    private func legacyProfileCandidate(
        for namespace: NodeRuntimeProfileNamespace,
        currentBundle: CachedBundle
    ) throws -> LegacyProfileCandidate? {
        let manager = FileManager.default
        let runtimeRoot = applicationSupportDirectory.appendingPathComponent(
            "NodeRuntime",
            isDirectory: true
        )
        guard let runtimeDirectories = try? manager.contentsOfDirectory(
            at: runtimeRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var candidates: [LegacyProfileCandidate] = []
        for directory in runtimeDirectories {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let cacheKey = directory.lastPathComponent
            let profileURL = directory.appendingPathComponent(
                "contract-b-profile.json"
            )
            guard manager.fileExists(atPath: profileURL.path) else { continue }
            let belongsToCurrentSource: Bool
            if cacheKey == currentBundle.cacheKey {
                belongsToCurrentSource = true
            } else {
                belongsToCurrentSource = legacyCacheMetadata(
                    cacheKey: cacheKey,
                    matches: namespace
                )
            }
            guard belongsToCurrentSource,
                  (try? validatedProfileData(at: profileURL)) != nil else {
                continue
            }
            let profileValues = try profileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            candidates.append(
                LegacyProfileCandidate(
                    profileURL: profileURL,
                    cacheKey: cacheKey,
                    modifiedAt: profileValues.contentModificationDate
                        ?? values.contentModificationDate
                        ?? .distantPast
                )
            )
        }
        return candidates.max { $0.modifiedAt < $1.modifiedAt }
    }

    private func legacyCacheMetadata(
        cacheKey: String,
        matches namespace: NodeRuntimeProfileNamespace
    ) -> Bool {
        let metadataURL = cacheURL(for: cacheKey)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(
                  CacheMetadata.self,
                  from: data
              ) else {
            return false
        }
        let values = metadata.pinIdentity
            .split(separator: "\n")
            .reduce(into: [String: String]()) { result, line in
                let components = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard components.count == 2 else { return }
                result[String(components[0])] = String(components[1])
            }
        let source = values["request"]
        let publisher = values["source"].flatMap { $0 == "-" ? nil : $0 }
            ?? NodeRuntimeProfileNamespace.originIdentityForMigration(
                sourceURLString: source
            )
        return source == namespace.sourceIdentity
            && publisher == namespace.publisherIdentity
    }

    private func validatedProfileData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= 1_024 * 1_024 else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
        return data
    }

    private func secureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func ensureReady(
        source: StartupSource,
        automaticRestart: Bool
    ) async throws -> URL {
        try Task.checkCancellation()
        let cacheKey = source.cacheKey
        let profileStorageKey = source.profileNamespace.storageKey
        if activeBundleCacheKey == cacheKey,
           activeProfileStorageKey == profileStorageKey,
           process?.isRunning == true,
           let serviceBaseURL,
           case .running(let publishedURL) = status,
           publishedURL == serviceBaseURL {
            return serviceBaseURL
        }

        if let startupCacheKey,
           let startupProfileStorageKey,
           let generation = startupGeneration {
            let joinsCurrentStartup = startupCacheKey == cacheKey
                && startupProfileStorageKey == profileStorageKey
            recordStartupLifecycle(
                code: .runtimeStartupJoined,
                message: joinsCurrentStartup
                    ? "Joined existing Node runtime startup"
                    : "Waiting for another Node runtime startup to finish",
                cacheKey: cacheKey
            )
            if joinsCurrentStartup {
                do {
                    let endpoint = try await sharedStartup.run(
                        sessionID: generation
                    ) {
                        throw CancellationError()
                    }
                    finishStartup(generation: generation)
                    try Task.checkCancellation()
                    return endpoint
                } catch {
                    if !Task.isCancelled {
                        finishStartup(generation: generation)
                    }
                    throw error
                }
            }
            do {
                _ = try await sharedStartup.run(sessionID: generation) {
                    throw CancellationError()
                }
            } catch {
                if Task.isCancelled {
                    throw error
                }
            }
            finishStartup(generation: generation)
            try Task.checkCancellation()
            return try await ensureReady(
                source: source,
                automaticRestart: automaticRestart
            )
        }

        if !automaticRestart {
            restartTask?.cancel()
            restartTask = nil
            restartAttempt = 0
        }
        let generation = UUID()
        startupGeneration = generation
        startupCacheKey = cacheKey
        startupProfileStorageKey = profileStorageKey
        recordStartupLifecycle(
            code: .runtimeStartRequested,
            message: automaticRestart
                ? "Controlled Node runtime restart requested"
                : "Node runtime start requested",
            cacheKey: cacheKey
        )
        publish(.starting)
        recordStartupLifecycle(
            code: .runtimeReadinessWaiting,
            message: "Waiting for Node runtime health readiness",
            cacheKey: cacheKey
        )

        do {
            let endpoint = try await sharedStartup.run(
                sessionID: generation
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.performStartup(
                    source: source,
                    generation: generation
                )
            }
            finishStartup(generation: generation)
            try Task.checkCancellation()
            return endpoint
        } catch {
            if !Task.isCancelled {
                finishStartup(generation: generation)
            }
            throw error
        }
    }

    private func finishStartup(generation: UUID) {
        guard startupGeneration == generation else { return }
        startupGeneration = nil
        startupCacheKey = nil
        startupProfileStorageKey = nil
    }

    private func performStartup(
        source: StartupSource,
        generation: UUID
    ) async throws -> URL {
        do {
            let bundle: CachedBundle
            switch source {
            case .descriptor(let descriptor, _):
                bundle = try await obtainBundle(descriptor)
            case .cached(let cached, _):
                bundle = cached
            }
            try Task.checkCancellation()
            try validateBundleForExecution(bundle)
            guard startupGeneration == generation else {
                throw CancellationError()
            }
            desiredBundle = bundle
            desiredProfileNamespace = source.profileNamespace
            stopProcess(publishing: .starting)
            let endpoint = try await startProcess(
                bundle,
                profileNamespace: source.profileNamespace
            )
            guard startupGeneration == generation else {
                throw CancellationError()
            }
            activeBundleCacheKey = bundle.cacheKey
            activeProfileStorageKey = source.profileNamespace.storageKey
            return endpoint
        } catch {
            if startupGeneration == generation {
                stopProcess(publishing: .failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func recordStartupLifecycle(
        code: NodeDiagnosticCode,
        message: String,
        cacheKey: String
    ) {
        let writer: NodeDiagnosticLogWriter
        if let existing = diagnosticWriters[cacheKey] {
            writer = existing
        } else {
            let directory = applicationSupportDirectory
                .appendingPathComponent("NodeRuntime", isDirectory: true)
                .appendingPathComponent(cacheKey, isDirectory: true)
            do {
                try secureDirectory(directory)
            } catch {
                return
            }
            writer = NodeDiagnosticLogWriter(
                logURL: directory.appendingPathComponent("node.log"),
                maximumBytes: diagnosticLogMaximumBytes,
                retainedFileCount: diagnosticLogRetainedFileCount
            )
            diagnosticWriters[cacheKey] = writer
        }
        writer.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .info,
                code: code,
                message: message,
                cacheKey: cacheKey
            )
        )
    }

    private func startProcess(
        _ bundle: CachedBundle,
        profileNamespace: NodeRuntimeProfileNamespace
    ) async throws -> URL {
        try validateBundleForExecution(bundle)
        let validatedBundleData = try Data(
            contentsOf: bundle.scriptURL,
            options: .mappedIfSafe
        )
        let contract = try NodeRuntimeContractDetector.detect(
            validatedBundleData: validatedBundleData
        )
        let nodeExecutable = try nodeExecutableURL()
        let launcherURL = bundle.runtimeDirectory.appendingPathComponent("launcher.js")
        let writer = diagnosticWriters[bundle.cacheKey] ?? NodeDiagnosticLogWriter(
            logURL: bundle.runtimeDirectory.appendingPathComponent("node.log"),
            maximumBytes: diagnosticLogMaximumBytes,
            retainedFileCount: diagnosticLogRetainedFileCount
        )
        diagnosticWriters[bundle.cacheKey] = writer
        activeDiagnosticWriter = writer
        let temporaryDirectory = bundle.runtimeDirectory
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let profileURL = contract == .hostIntegrated
            ? try contractBProfileURL(
                for: profileNamespace,
                currentBundle: bundle
            )
            : nil
        let launchPlan = try NodeRuntimeContractFactory.makePlan(
            contract: contract,
            runtimeDirectory: bundle.runtimeDirectory,
            profileURL: profileURL
        )
        var executableBundleURL = bundle.scriptURL
        var cleanupURLs = launchPlan.cleanupURLs
        if let patched = try NodeBundleRuntimeCompatibilityPatcher.patchedScript(
            validatedBundleData,
            sourceURL: bundle.finalScriptURL
        ) {
            let patchedURL = bundle.runtimeDirectory.appendingPathComponent(
                "compat-index.js"
            )
            try patched.write(to: patchedURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: patchedURL.path
            )
            executableBundleURL = patchedURL
            cleanupURLs.append(patchedURL)
        }
        activeContractCleanupURLs = cleanupURLs
        writer.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .info,
                code: .runtimeContractDetected,
                message: "Node runtime contract selected: \(contract.rawValue)",
                sourceID: bundle.sourceID,
                cacheKey: bundle.cacheKey,
                trustState: bundle.trustState.diagnosticState
            )
        )
        if contract == .hostIntegrated {
            writer.write(
                NodeDiagnosticEvent(
                    timestamp: now(),
                    category: .runtime,
                    severity: .info,
                    code: .runtimeConfigurationValidated,
                    message: "Contract B minimum host configuration validated",
                    sourceID: bundle.sourceID,
                    cacheKey: bundle.cacheKey
                )
            )
            writer.write(
                NodeDiagnosticEvent(
                    timestamp: now(),
                    category: .runtime,
                    severity: .info,
                    code: .runtimeHostAdapterReady,
                    message: "Contract B bounded host adapter prepared",
                    sourceID: bundle.sourceID,
                    cacheKey: bundle.cacheKey,
                    localPort: launchPlan.environmentAdditions["DEV_HTTP_PORT"].flatMap(Int.init)
                )
            )
        }
        try Data(launchPlan.launcherScript.utf8).write(
            to: launcherURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: launcherURL.path
        )

        writer.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .info,
                code: .runtimeLaunchStarted,
                message: "Launching bundled Node runtime",
                sourceID: bundle.sourceID,
                cacheKey: bundle.cacheKey,
                trustState: bundle.trustState.diagnosticState
            )
        )
        let pipe = Pipe()
        let portCapture = NodePortCapture()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            portCapture.append(data)
            writer.writeNodeOutput(data)
        }

        let process = Process()
        let generation = UUID()
        processGeneration = generation
        process.executableURL = nodeExecutable
        process.arguments = [launcherURL.path]
        process.currentDirectoryURL = bundle.runtimeDirectory
        process.environment = try Self.sanitizedNodeEnvironment(
            bundlePath: executableBundleURL,
            runtimeDirectory: bundle.runtimeDirectory,
            temporaryDirectory: temporaryDirectory,
            contractAdditions: launchPlan.environmentAdditions
        )
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] terminatedProcess in
            let detail = "退出码 \(terminatedProcess.terminationStatus)"
            Task {
                await self?.handleUnexpectedTermination(
                    generation: generation,
                    detail: detail
                )
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            writer.flushNodeOutput()
            writer.write(
                NodeDiagnosticEvent(
                    timestamp: now(),
                    category: .runtime,
                    severity: .error,
                    code: .runtimeLaunchFailed,
                    message: error.localizedDescription,
                    sourceID: bundle.sourceID,
                    cacheKey: bundle.cacheKey,
                    trustState: bundle.trustState.diagnosticState
                )
            )
            throw NodeBundleRuntimeError.nodeLaunchFailed(
                error.localizedDescription
            )
        }

        self.process = process
        outputPipe = pipe
        writer.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .info,
                code: .runtimeLaunchStarted,
                message: "Bundled Node process launched",
                sourceID: bundle.sourceID,
                cacheKey: bundle.cacheKey,
                trustState: bundle.trustState.diagnosticState,
                nodePID: process.processIdentifier
            )
        )

        let readinessDeadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < readinessDeadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                process.terminationHandler = nil
                stopProcess(publishing: nil)
                writer.write(
                    NodeDiagnosticEvent(
                        timestamp: now(),
                        category: .runtime,
                        severity: .error,
                        code: .runtimeExited,
                        message: "Node process exited before becoming ready",
                        sourceID: bundle.sourceID,
                        cacheKey: bundle.cacheKey,
                        nodePID: process.processIdentifier
                    )
                )
                throw NodeBundleRuntimeError.nodeLaunchFailed(
                    "进程在服务就绪前提前退出"
                )
            }
            let port: Int?
            switch launchPlan.contract {
            case .service:
                port = portCapture.port
            case .hostIntegrated:
                port = launchPlan.stateFileURL
                    .flatMap(ContractBListenerState.readValidated(from:))?
                    .port
            }
            if let port,
               let baseURL = URL(string: "http://127.0.0.1:\(port)/"),
               await isReady(baseURL, policy: launchPlan.readinessPolicy) {
                serviceBaseURL = baseURL
                publish(.running(baseURL))
                if launchPlan.contract == .hostIntegrated {
                    writer.write(
                        NodeDiagnosticEvent(
                            timestamp: now(),
                            category: .runtime,
                            severity: .info,
                            code: .runtimeListenerObserved,
                            message: "Contract B loopback listener observed",
                            sourceID: bundle.sourceID,
                            cacheKey: bundle.cacheKey,
                            nodePID: process.processIdentifier,
                            localPort: port
                        )
                    )
                    writer.write(
                        NodeDiagnosticEvent(
                            timestamp: now(),
                            category: .runtime,
                            severity: .info,
                            code: .runtimeCapabilityValidated,
                            message: "Contract B configuration capability validated",
                            sourceID: bundle.sourceID,
                            cacheKey: bundle.cacheKey,
                            nodePID: process.processIdentifier,
                            localPort: port
                        )
                    )
                }
                writer.write(
                    NodeDiagnosticEvent(
                        timestamp: now(),
                        category: .runtime,
                        severity: .info,
                        code: .runtimeReady,
                        message: launchPlan.contract == .service
                            ? "Node runtime health check succeeded"
                            : "Node runtime host capability check succeeded",
                        sourceID: bundle.sourceID,
                        cacheKey: bundle.cacheKey,
                        trustState: bundle.trustState.diagnosticState,
                        nodePID: process.processIdentifier,
                        localPort: port
                    )
                )
                startHealthMonitor(
                    generation: generation,
                    baseURL: baseURL,
                    readinessPolicy: launchPlan.readinessPolicy
                )
                return baseURL
            }
            try await Task.sleep(
                nanoseconds: UInt64(readinessPollInterval * 1_000_000_000)
            )
        }

        process.terminationHandler = nil
        stopProcess(publishing: nil)
        writer.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .error,
                code: .runtimeLaunchFailed,
                message: "Node runtime did not become ready before timeout",
                sourceID: bundle.sourceID,
                cacheKey: bundle.cacheKey
            )
        )
        if launchPlan.contract == .hostIntegrated {
            throw NodeBundleRuntimeError.contractBReadinessFailed
        }
        throw NodeBundleRuntimeError.nodeLaunchFailed("资源服务启动超时")
    }

    private func isReady(
        _ baseURL: URL,
        policy: NodeRuntimeReadinessPolicy
    ) async -> Bool {
        do {
            let path: String
            let maximumResponseBytes: Int
            switch policy {
            case .serviceHealthIdentity:
                path = "health"
                maximumResponseBytes = 1_024
            case .hostIntegratedConfiguration:
                path = "config"
                maximumResponseBytes = Self.maximumConfigurationSize
            }
            let response = try await localHTTPClient.send(
                HTTPRequest(
                    url: baseURL.appendingPathComponent(path),
                    timeout: 2,
                    maximumResponseBytes: maximumResponseBytes,
                    maximumRedirects: 0,
                    retryPolicy: .none
                )
            )
            switch policy {
            case .serviceHealthIdentity:
                guard let object = try JSONSerialization.jsonObject(with: response.body)
                    as? [String: Any] else {
                    return false
                }
                return object["ok"] as? Bool == true
                    && object["name"] as? String == "CatVodSpiderios"
            case .hostIntegratedConfiguration:
                let normalized = try Self.normalizeConfiguration(response.body)
                _ = try ConfigurationParser().parse(normalized)
                return true
            }
        } catch {
            return false
        }
    }

    private func stopProcess(publishing newStatus: NodeRuntimeStatus?) {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        activeDiagnosticWriter?.flushNodeOutput()
        outputPipe = nil
        process = nil
        activeBundleCacheKey = nil
        activeProfileStorageKey = nil
        removeActiveContractArtifacts()
        serviceBaseURL = nil
        if let newStatus {
            publish(newStatus)
        }
    }

    private func handleUnexpectedTermination(
        generation: UUID,
        detail: String
    ) {
        guard generation == processGeneration else { return }
        guard case .running = status else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        activeDiagnosticWriter?.flushNodeOutput()
        activeDiagnosticWriter?.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .error,
                code: .runtimeExited,
                message: detail,
                nodePID: process?.processIdentifier
            )
        )
        outputPipe = nil
        process = nil
        activeBundleCacheKey = nil
        activeProfileStorageKey = nil
        removeActiveContractArtifacts()
        serviceBaseURL = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        activeDiagnosticWriter?.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .warning,
                code: .runtimeEndpointInvalidated,
                message: "Node runtime endpoint invalidated after process exit"
            )
        )
        scheduleRestart(reason: detail)
    }

    private func removeActiveContractArtifacts() {
        for url in activeContractCleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        activeContractCleanupURLs = []
    }

    private func startHealthMonitor(
        generation: UUID,
        baseURL: URL,
        readinessPolicy: NodeRuntimeReadinessPolicy
    ) {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let healthy = await self.isReady(
                    baseURL,
                    policy: readinessPolicy
                )
                if healthy {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 2 {
                        await self.handleHealthFailure(generation: generation)
                        return
                    }
                }
            }
        }
    }

    private func handleHealthFailure(generation: UUID) {
        guard generation == processGeneration else { return }
        guard case .running = status else { return }
        activeDiagnosticWriter?.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .warning,
                code: .runtimeHealthFailed,
                message: "Node runtime failed consecutive health checks"
            )
        )
        stopProcess(publishing: nil)
        scheduleRestart(reason: "连续健康检查失败")
    }

    private func scheduleRestart(reason: String) {
        guard restartTask == nil, desiredBundle != nil else { return }
        guard restartAttempt < Self.restartDelays.count else {
            activeDiagnosticWriter?.write(
                NodeDiagnosticEvent(
                    timestamp: now(),
                    category: .runtime,
                    severity: .error,
                    code: .runtimeRestartExhausted,
                    message: reason
                )
            )
            publish(.failed(
                NodeBundleRuntimeError.nodeExitedUnexpectedly(
                    "已完成 \(Self.restartDelays.count) 次恢复尝试：\(reason)"
                ).localizedDescription
            ))
            return
        }
        let attempt = restartAttempt + 1
        restartAttempt = attempt
        let delay = Self.restartDelays[attempt - 1]
        activeDiagnosticWriter?.write(
            NodeDiagnosticEvent(
                timestamp: now(),
                category: .runtime,
                severity: .warning,
                code: .runtimeRestartScheduled,
                message: "Node runtime restart scheduled after failure"
            )
        )
        publish(.restarting(attempt: attempt, reason: reason))
        restartTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await self?.performRestart(attempt: attempt)
        }
    }

    private func performRestart(attempt: Int) async {
        restartTask = nil
        guard case .restarting(let currentAttempt, _) = status,
              currentAttempt == attempt,
              let bundle = desiredBundle,
              let profileNamespace = desiredProfileNamespace else { return }
        do {
            _ = try await ensureReady(
                source: .cached(bundle, profileNamespace),
                automaticRestart: true
            )
        } catch {
            stopProcess(publishing: nil)
            scheduleRestart(reason: error.localizedDescription)
        }
    }

    private func publish(_ newStatus: NodeRuntimeStatus) {
        status = newStatus
        for continuation in statusContinuations.values {
            continuation.yield(newStatus)
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func validateBundleForExecution(_ bundle: CachedBundle) throws {
        let data = try Data(contentsOf: bundle.scriptURL, options: .mappedIfSafe)
        try Self.validateBundleDataForExecution(
            data,
            expectedMD5: bundle.md5,
            expectedInternalSHA256: bundle.sha256,
            trustedSHA256: bundle.expectedSHA256,
            finalChecksumURL: bundle.finalChecksumURL,
            finalScriptURL: bundle.finalScriptURL
        )
    }

    private func nodeExecutableURL() throws -> URL {
        #if DEBUG
        if let nodeExecutableOverride {
            guard FileManager.default.isExecutableFile(
                atPath: nodeExecutableOverride.path
            ) else {
                throw NodeBundleRuntimeError.invalidNodeEnvironment(
                    "测试/Debug 指定的 Node 不可执行"
                )
            }
            return nodeExecutableOverride
        }
        #endif

        guard let resources = Bundle.main.resourceURL else {
            throw NodeBundleRuntimeError.bundledNodeMissing
        }
        let resourceRoot = resources.resolvingSymlinksInPath()
        let executable = resources
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent("node")
            .resolvingSymlinksInPath()
        let allowedPrefix = resourceRoot.path.hasSuffix("/")
            ? resourceRoot.path
            : resourceRoot.path + "/"
        guard executable.path.hasPrefix(allowedPrefix) else {
            throw NodeBundleRuntimeError.invalidNodeEnvironment(
                "NodeRuntime/node 解析到 App Bundle 之外"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NodeBundleRuntimeError.bundledNodeMissing
        }
        return executable
    }

    private static func port(fromLogAt url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        let suffix = data.suffix(256 * 1_024)
        guard let text = String(data: suffix, encoding: .utf8) else {
            return nil
        }
        let pattern = #"http://127\.0\.0\.1:(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ).last,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

}
