import CryptoKit
import Foundation
import OKVideoCore

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
}

struct NodeBundleSourceDescriptor: Equatable {
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

enum NodeBundleTrustState: String, Codable, Equatable, Sendable {
    case httpsTransport
    case publisherSHA256
    case legacyTOFU
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
        let scriptURL: URL
        let md5: String
        let sha256: String
        let expectedSHA256: String?
        let finalChecksumURL: URL
        let finalScriptURL: URL
        let runtimeDirectory: URL
        let trustState: NodeBundleTrustState
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

    private var process: Process?
    private var logHandle: FileHandle?
    private var activeBundleSHA256: String?
    private var serviceBaseURL: URL?
    private var status: NodeRuntimeStatus = .stopped
    private var statusContinuations: [UUID: AsyncStream<NodeRuntimeStatus>.Continuation] = [:]
    private var desiredBundle: CachedBundle?
    private var processGeneration = UUID()
    private var restartTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var restartAttempt = 0

    static let restartDelays: [TimeInterval] = [1, 2, 5]

    init(
        applicationSupportDirectory: URL,
        cacheDirectory: URL,
        remoteHTTPClient: HTTPClient,
        nodeExecutableURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        migrationCommitHook: (() throws -> Void)? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cacheDirectory = cacheDirectory
        self.remoteHTTPClient = remoteHTTPClient
        nodeExecutableOverride = nodeExecutableURL
        self.now = now
        self.migrationCommitHook = migrationCommitHook

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        localHTTPClient = URLSessionHTTPClient(configuration: configuration)
    }

    static func supports(_ url: URL) -> Bool {
        NodeBundleSourceDescriptor.supports(url)
    }

    func loadConfiguration(from sourceURL: URL) async throws -> LoadedConfiguration {
        let descriptor = try NodeBundleSourceDescriptor(url: sourceURL)
        let bundle = try await obtainBundle(descriptor)
        let baseURL = try await ensureServiceRunning(bundle)
        let configURL = baseURL.appendingPathComponent("config")
        let response = try await localHTTPClient.send(
            HTTPRequest(
                url: configURL,
                timeout: 60,
                maximumResponseBytes: Self.maximumConfigurationSize,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 1, initialDelay: 0.25)
            )
        )
        let normalized = try Self.normalizeConfiguration(response.body)
        let parsed = try ConfigurationParser().parse(normalized)
        return LoadedConfiguration(
            source: .remote(sourceURL),
            baseURL: baseURL,
            rawData: normalized,
            configuration: parsed,
            loadedAt: now()
        )
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        desiredBundle = nil
        restartAttempt = 0
        stopProcess(publishing: .stopped)
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
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> [String: String] {
        let environment = [
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
        do {
            return try await downloadBundle(descriptor)
        } catch let downloadError {
            let allowsFallback = (downloadError as? NodeBundleRuntimeError)?
                .allowsCachedFallback == true
            guard allowsFallback else { throw downloadError }

            let currentCache = cacheURL(for: descriptor.cacheKey)
            if FileManager.default.fileExists(atPath: currentCache.path) {
                do {
                    return try loadCachedBundle(descriptor, cacheURL: currentCache)
                } catch {
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
        var headers = HTTPHeaders()
        if let authorization = descriptor.authorizationHeader {
            headers["Authorization"] = authorization
        }

        let checksumResponse: HTTPResponse
        do {
            checksumResponse = try await remoteHTTPClient.send(
                HTTPRequest(
                    url: descriptor.checksumURL,
                    headers: headers,
                    timeout: 20,
                    maximumResponseBytes: 256,
                    retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
                )
            )
        } catch {
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
            scriptResponse = try await remoteHTTPClient.send(
                HTTPRequest(
                    url: descriptor.scriptURL,
                    headers: headers,
                    timeout: 60,
                    maximumResponseBytes: Self.maximumScriptSize,
                    retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
                )
            )
        } catch {
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
        return try loadCachedBundle(descriptor, cacheURL: cacheURL)
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
        return try loadCachedBundle(descriptor, cacheURL: installedURL)
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

    private func runtimeDirectory(
        for descriptor: NodeBundleSourceDescriptor
    ) throws -> URL {
        let runtime = applicationSupportDirectory
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent(descriptor.cacheKey, isDirectory: true)
        try secureDirectory(runtime)
        return runtime
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

    private func ensureServiceRunning(_ bundle: CachedBundle) async throws -> URL {
        do {
            try validateBundleForExecution(bundle)
        } catch {
            desiredBundle = nil
            stopProcess(publishing: .failed(error.localizedDescription))
            throw error
        }
        if activeBundleSHA256 == bundle.sha256,
           process?.isRunning == true,
           let serviceBaseURL,
           await isHealthy(serviceBaseURL) {
            return serviceBaseURL
        }

        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        desiredBundle = bundle
        stopProcess(publishing: .starting)
        do {
            return try await startProcess(bundle)
        } catch {
            stopProcess(publishing: .failed(error.localizedDescription))
            throw error
        }
    }

    private func startProcess(_ bundle: CachedBundle) async throws -> URL {
        try validateBundleForExecution(bundle)
        let nodeExecutable = try nodeExecutableURL()
        let launcherURL = bundle.runtimeDirectory.appendingPathComponent("launcher.js")
        let logURL = bundle.runtimeDirectory.appendingPathComponent("node.log")
        let temporaryDirectory = bundle.runtimeDirectory
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(Self.launcherScript.utf8).write(to: launcherURL, options: .atomic)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        for privateFile in [launcherURL, logURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: privateFile.path
            )
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)

        let process = Process()
        let generation = UUID()
        processGeneration = generation
        process.executableURL = nodeExecutable
        process.arguments = [launcherURL.path]
        process.currentDirectoryURL = bundle.runtimeDirectory
        process.environment = try Self.sanitizedNodeEnvironment(
            bundlePath: bundle.scriptURL,
            runtimeDirectory: bundle.runtimeDirectory,
            temporaryDirectory: temporaryDirectory
        )
        process.standardOutput = handle
        process.standardError = handle
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
            try? handle.close()
            throw NodeBundleRuntimeError.nodeLaunchFailed(
                error.localizedDescription
            )
        }

        self.process = process
        logHandle = handle
        activeBundleSHA256 = bundle.sha256

        for _ in 0..<900 {
            guard process.isRunning else {
                process.terminationHandler = nil
                stopProcess(publishing: nil)
                throw NodeBundleRuntimeError.nodeLaunchFailed(
                    "进程提前退出，日志位于 \(logURL.path)"
                )
            }
            if let port = Self.port(fromLogAt: logURL),
               let baseURL = URL(string: "http://127.0.0.1:\(port)/"),
               await isHealthy(baseURL) {
                serviceBaseURL = baseURL
                publish(.running(baseURL))
                startHealthMonitor(generation: generation, baseURL: baseURL)
                return baseURL
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        process.terminationHandler = nil
        stopProcess(publishing: nil)
        throw NodeBundleRuntimeError.nodeLaunchFailed("资源服务启动超过 90 秒")
    }

    private func isHealthy(_ baseURL: URL) async -> Bool {
        do {
            let response = try await localHTTPClient.send(
                HTTPRequest(
                    url: baseURL.appendingPathComponent("health"),
                    timeout: 2,
                    maximumResponseBytes: 1_024,
                    maximumRedirects: 0,
                    retryPolicy: .none
                )
            )
            guard let object = try JSONSerialization.jsonObject(with: response.body)
                as? [String: Any] else {
                return false
            }
            return object["ok"] as? Bool == true
                && object["name"] as? String == "CatVodSpiderios"
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
        try? logHandle?.close()
        logHandle = nil
        process = nil
        activeBundleSHA256 = nil
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
        try? logHandle?.close()
        logHandle = nil
        process = nil
        activeBundleSHA256 = nil
        serviceBaseURL = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        scheduleRestart(reason: detail)
    }

    private func startHealthMonitor(generation: UUID, baseURL: URL) {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let healthy = await self.isHealthy(baseURL)
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
        stopProcess(publishing: nil)
        scheduleRestart(reason: "连续健康检查失败")
    }

    private func scheduleRestart(reason: String) {
        guard restartTask == nil, desiredBundle != nil else { return }
        guard restartAttempt < Self.restartDelays.count else {
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
              let bundle = desiredBundle else { return }
        do {
            _ = try await startProcess(bundle)
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

    private static let launcherScript = #"""
    'use strict';
    const bundlePath = process.env.OKVIDEO_BUNDLE_PATH;
    const parentPID = Number(process.env.OKVIDEO_PARENT_PID || 0);
    let runtime = null;
    let stopping = false;

    async function shutdown(code) {
      if (stopping) return;
      stopping = true;
      try {
        if (runtime && typeof runtime.stop === 'function') await runtime.stop();
      } catch (_) {}
      process.exit(code);
    }

    process.on('SIGTERM', () => { void shutdown(0); });
    process.on('SIGINT', () => { void shutdown(0); });
    setInterval(() => {
      if (!parentPID) return;
      try { process.kill(parentPID, 0); }
      catch (_) { void shutdown(0); }
    }, 1000);

    try {
      runtime = require(bundlePath);
      Promise.resolve(runtime.start()).catch((error) => {
        console.error(error);
        void shutdown(1);
      });
    } catch (error) {
      console.error(error);
      void shutdown(1);
    }
    """#
}
