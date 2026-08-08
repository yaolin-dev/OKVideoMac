import CryptoKit
import Foundation
import OKVideoCore

struct NodeBundleSourceDescriptor: Equatable {
    static let checksumSuffix = ".js.md5"

    let originalURL: URL
    let checksumURL: URL
    let scriptURL: URL
    let authorizationHeader: String?
    let cacheKey: String

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
        cacheKey = Self.sha256Hex(
            Data(
                (checksumURL.absoluteString + "\n" + (authorizationHeader ?? ""))
                    .utf8
            )
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor NodeBundleRuntimeService {
    private struct CachedBundle {
        let scriptURL: URL
        let md5: String
        let sha256: String
        let runtimeDirectory: URL
    }

    private static let maximumScriptSize = 16 * 1_024 * 1_024
    private static let maximumConfigurationSize = 5 * 1_024 * 1_024

    private let applicationSupportDirectory: URL
    private let cacheDirectory: URL
    private let remoteHTTPClient: HTTPClient
    private let localHTTPClient: HTTPClient
    private let nodeExecutableOverride: URL?
    private let now: () -> Date

    private var process: Process?
    private var logHandle: FileHandle?
    private var activeBundleSHA256: String?
    private var serviceBaseURL: URL?

    init(
        applicationSupportDirectory: URL,
        cacheDirectory: URL,
        remoteHTTPClient: HTTPClient,
        nodeExecutableURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cacheDirectory = cacheDirectory
        self.remoteHTTPClient = remoteHTTPClient
        nodeExecutableOverride = nodeExecutableURL
        self.now = now

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
        stopProcess()
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

    private func obtainBundle(
        _ descriptor: NodeBundleSourceDescriptor
    ) async throws -> CachedBundle {
        do {
            return try await downloadBundle(descriptor)
        } catch {
            if let cached = try? loadCachedBundle(descriptor) {
                return cached
            }
            throw error
        }
    }

    private func downloadBundle(
        _ descriptor: NodeBundleSourceDescriptor
    ) async throws -> CachedBundle {
        var headers = HTTPHeaders()
        if let authorization = descriptor.authorizationHeader {
            headers["Authorization"] = authorization
        }

        let checksumResponse = try await remoteHTTPClient.send(
            HTTPRequest(
                url: descriptor.checksumURL,
                headers: headers,
                timeout: 20,
                maximumResponseBytes: 256,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
            )
        )
        let checksum = try checksumResponse.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard checksum.range(
            of: "^[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil else {
            throw AppError.configuration("Node 资源的 .md5 响应不是 32 位 MD5")
        }

        let scriptResponse = try await remoteHTTPClient.send(
            HTTPRequest(
                url: descriptor.scriptURL,
                headers: headers,
                timeout: 60,
                maximumResponseBytes: Self.maximumScriptSize,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
            )
        )
        let actualMD5 = Self.md5Hex(scriptResponse.body)
        guard actualMD5 == checksum else {
            throw AppError.configuration(
                "Node 资源 MD5 校验失败：期望 \(checksum)，实际 \(actualMD5)"
            )
        }
        guard String(data: scriptResponse.body, encoding: .utf8) != nil else {
            throw AppError.configuration("Node 资源脚本不是有效 UTF-8")
        }

        let directories = try bundleDirectories(descriptor)
        let scriptURL = directories.cache.appendingPathComponent("index.js")
        let checksumURL = directories.cache.appendingPathComponent("index.js.md5")
        try scriptResponse.body.write(to: scriptURL, options: .atomic)
        try Data(checksum.utf8).write(to: checksumURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: scriptURL.path
        )
        return CachedBundle(
            scriptURL: scriptURL,
            md5: checksum,
            sha256: Self.sha256Hex(scriptResponse.body),
            runtimeDirectory: directories.runtime
        )
    }

    private func loadCachedBundle(
        _ descriptor: NodeBundleSourceDescriptor
    ) throws -> CachedBundle {
        let directories = try bundleDirectories(descriptor)
        let scriptURL = directories.cache.appendingPathComponent("index.js")
        let checksumURL = directories.cache.appendingPathComponent("index.js.md5")
        let data = try Data(contentsOf: scriptURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumScriptSize else {
            throw AppError.configuration("Node 资源缓存超过 16 MiB 限制")
        }
        let expected = try String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let actual = Self.md5Hex(data)
        guard expected == actual else {
            throw AppError.configuration("Node 资源缓存 MD5 校验失败")
        }
        return CachedBundle(
            scriptURL: scriptURL,
            md5: expected,
            sha256: Self.sha256Hex(data),
            runtimeDirectory: directories.runtime
        )
    }

    private func bundleDirectories(
        _ descriptor: NodeBundleSourceDescriptor
    ) throws -> (cache: URL, runtime: URL) {
        let cache = cacheDirectory
            .appendingPathComponent("NodeBundles", isDirectory: true)
            .appendingPathComponent(descriptor.cacheKey, isDirectory: true)
        let runtime = applicationSupportDirectory
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent(descriptor.cacheKey, isDirectory: true)
        for directory in [cache, runtime] {
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
        return (cache, runtime)
    }

    private func ensureServiceRunning(_ bundle: CachedBundle) async throws -> URL {
        if activeBundleSHA256 == bundle.sha256,
           process?.isRunning == true,
           let serviceBaseURL,
           await isHealthy(serviceBaseURL) {
            return serviceBaseURL
        }

        stopProcess()
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
        process.executableURL = nodeExecutable
        process.arguments = [launcherURL.path]
        process.currentDirectoryURL = bundle.runtimeDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["HOST"] = "127.0.0.1"
        environment["PORT"] = "0"
        environment["NODE_ENV"] = "production"
        environment["HOME"] = bundle.runtimeDirectory.path
        environment["TMPDIR"] = temporaryDirectory.path
        environment["OKVIDEO_BUNDLE_PATH"] = bundle.scriptURL.path
        environment["OKVIDEO_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw AppError.configuration(
                "无法启动内置 Node 服务：\(error.localizedDescription)"
            )
        }

        self.process = process
        logHandle = handle
        activeBundleSHA256 = bundle.sha256

        for _ in 0..<900 {
            guard process.isRunning else {
                stopProcess()
                throw AppError.configuration(
                    "Node 资源服务启动失败，日志位于 \(logURL.path)"
                )
            }
            if let port = Self.port(fromLogAt: logURL),
               let baseURL = URL(string: "http://127.0.0.1:\(port)/"),
               await isHealthy(baseURL) {
                serviceBaseURL = baseURL
                return baseURL
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        stopProcess()
        throw AppError.configuration("Node 资源服务启动超过 90 秒")
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

    private func stopProcess() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? logHandle?.close()
        logHandle = nil
        process = nil
        activeBundleSHA256 = nil
        serviceBaseURL = nil
    }

    private func nodeExecutableURL() throws -> URL {
        let candidates = [
            nodeExecutableOverride,
            Bundle.main.resourceURL?
                .appendingPathComponent("NodeRuntime", isDirectory: true)
                .appendingPathComponent("node"),
            URL(fileURLWithPath: "/opt/homebrew/opt/node@22-direct/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/opt/local/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node")
        ].compactMap { $0 }
        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw AppError.configuration(
            "应用包缺少 NodeRuntime/node，请重新安装 Release 版本"
        )
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
