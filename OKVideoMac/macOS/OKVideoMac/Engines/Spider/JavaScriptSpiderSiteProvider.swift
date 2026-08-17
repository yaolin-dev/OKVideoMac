import Darwin
import CryptoKit
import Foundation
import OKVideoCore

struct AndroidBridgeUIControl: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
}

struct AndroidBridgeUIState: Decodable, Equatable {
    let visible: Bool
    let title: String
    let inputCount: Int
    let imageCount: Int
    let buttons: [String]
    let controls: [AndroidBridgeUIControl]?
    let texts: [String]?
    let phase: String?
    let provider: String?
    let authenticated: Bool?
    let credentialPush: Bool?
    let remoteInput: Bool?

    var actionableControls: [AndroidBridgeUIControl] {
        if let controls, !controls.isEmpty {
            return controls
        }
        return buttons.enumerated().map {
            AndroidBridgeUIControl(
                id: "legacy:\($0.offset)",
                title: $0.element
            )
        }
    }

    var isQRCode: Bool {
        !isRemoteInputQRCode && (phase == "qr" || imageCount > 0)
    }

    var isRemoteInputQRCode: Bool {
        if remoteInput == true {
            return true
        }
        return texts?.contains { text in
            text.localizedCaseInsensitiveContains("/proxy?do=input")
        } == true
    }

    var isCredentialPush: Bool {
        if credentialPush == true {
            return true
        }
        guard isQRCode else { return false }
        return texts?.contains { text in
            let lower = text.lowercased()
            return text.contains("微信扫码推送")
                || (text.contains("推送")
                && (lower.contains("cookie") || lower.contains("token")))
        } == true
    }

    var hasVisibleAuthorizationContent: Bool {
        guard visible else { return false }
        return inputCount > 0
            || imageCount > 0
            || !actionableControls.isEmpty
            || !(texts?.isEmpty ?? true)
    }

    var isAuthorizationPrompt: Bool {
        // Older bridge builds reported the empty host Activity as a visible
        // "chooser" after a QR dialog closed. Requiring actual captured UI
        // content prevents that ghost window from blocking playback forever.
        guard hasVisibleAuthorizationContent else { return false }
        // A number of cloud spiders show a disclaimer in a custom chooser
        // whose rows are clickable TextViews rather than Android Buttons. A
        // text-only disclaimer is not an authorization prompt and must never
        // block an unrelated detail/play request.
        return inputCount > 0
            || imageCount > 0
            || !actionableControls.isEmpty
    }
}

struct AndroidBridgeUIRequired: Error {
    let state: AndroidBridgeUIState
}

final class JavaScriptSpiderSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL?
    private let session: JavaScriptSpiderSession

    init(
        site: SiteConfiguration,
        scriptURL: URL,
        baseURL: URL?,
        httpClient: HTTPClient,
        runtimeFactory: SpiderRuntimeFactory
    ) throws {
        guard site.type == 3 else {
            throw AppError.spider("JavaScriptSpiderSiteProvider 仅支持 type 3")
        }
        guard ["http", "https"].contains(scriptURL.scheme?.lowercased() ?? "") else {
            throw AppError.spider("JavaScript Spider 脚本只允许 HTTP/HTTPS")
        }
        self.site = site
        self.baseURL = baseURL
        let host = HTTPSpiderHost(httpClient: httpClient)
        let runtime = try runtimeFactory.makeRuntime(
            siteKey: site.key,
            limits: .standard,
            host: host
        )
        session = JavaScriptSpiderSession(
            site: site,
            scriptURL: scriptURL,
            httpClient: httpClient,
            engine: SpiderEngine(site: site, runtime: runtime)
        )
    }

    func home() async throws -> SiteHome {
        let values = try await session.home()
        let result = try SpiderResponseMapper.home(
            values.home,
            homeVideoValue: values.homeVideo,
            site: site,
            baseURL: baseURL
        )
        guard site.categories.isEmpty else {
            let allowed = Set(site.categories)
            return SiteHome(
                categories: result.categories.filter { allowed.contains($0.name) },
                recommendations: result.recommendations
            )
        }
        return result
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try SpiderResponseMapper.page(
            await session.category(id: id, page: page, filters: filters),
            site: site,
            baseURL: baseURL,
            page: page
        )
    }

    func detail(id: String) async throws -> VideoDetail {
        try SpiderResponseMapper.detail(
            await session.detail(id: id),
            site: site,
            baseURL: baseURL
        )
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable == 1, !quick || site.quickSearch == 1 else {
            return VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
        }
        return try SpiderResponseMapper.page(
            await session.search(keyword: keyword, quick: quick, page: page),
            site: site,
            baseURL: baseURL,
            page: page
        )
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        try SpiderResponseMapper.player(
            await session.player(flag: flag, episodeURL: episodeURL),
            site: site
        )
    }

    func action(_ action: String) async throws -> JSONValue {
        try await session.action(action)
    }
}

private actor JavaScriptSpiderSession {
    let site: SiteConfiguration
    let scriptURL: URL
    let httpClient: HTTPClient
    let engine: SpiderEngine
    var initialized = false

    init(
        site: SiteConfiguration,
        scriptURL: URL,
        httpClient: HTTPClient,
        engine: SpiderEngine
    ) {
        self.site = site
        self.scriptURL = scriptURL
        self.httpClient = httpClient
        self.engine = engine
    }

    func home() async throws -> (home: JSONValue, homeVideo: JSONValue?) {
        try await initializeIfNeeded()
        let home = try await engine.home()
        let homeVideo = try? await engine.homeVideo()
        return (home, homeVideo)
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await engine.category(
            id: id,
            page: page,
            filter: true,
            extend: filters
        )
    }

    func detail(id: String) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await engine.detail(id: id)
    }

    func search(keyword: String, quick: Bool, page: Int) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await engine.search(keyword: keyword, quick: quick, page: page)
    }

    func player(flag: String, episodeURL: String) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await engine.play(flag: flag, id: episodeURL, vipFlags: [])
    }

    func action(_ action: String) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await engine.action(action)
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        var loadedResponse: HTTPResponse?
        var lastError: Error?
        for candidate in SpiderSourceURLCandidates.values(for: scriptURL) {
            do {
                loadedResponse = try await httpClient.send(
                    HTTPRequest(
                        url: candidate,
                        timeout: 20,
                        maximumResponseBytes: 5 * 1_024 * 1_024,
                        retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
                    )
                )
                break
            } catch {
                lastError = error
            }
        }
        guard let response = loadedResponse else {
            throw lastError ?? AppError.spider("无法下载 JavaScript Spider")
        }
        let script = try response.text()
        try await engine.initialize(script: script, sourceURL: response.url)
        initialized = true
    }
}

final class AndroidDexSpiderSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaDexSpider

    private let baseURL: URL?
    private let jarReference: String
    private let bridge: AndroidDexBridgeClient

    init(
        site: SiteConfiguration,
        jarReference: String,
        baseURL: URL?,
        bridge: AndroidDexBridgeClient
    ) throws {
        guard site.type == 3, site.api.hasPrefix("csp_") else {
            throw AppError.spider(
                "AndroidDexSpiderSiteProvider 仅支持 type 3 的 csp_ Java/Dex 站点"
            )
        }
        self.site = site
        self.jarReference = jarReference
        self.baseURL = baseURL
        self.bridge = bridge
    }

    func home() async throws -> SiteHome {
        var values = try await loadHomeValues()
        if Self.shouldResetSpider(
            homeValue: values.home,
            homeVideoValue: values.homeVideo
        ) {
            // Guard-style spiders can finish init with an unavailable delegate
            // and then remain cached as an empty provider. Recreate that one
            // site once before treating it as a legitimate search-only site.
            _ = try? await invoke(method: "destroy", arguments: [])
            values = try await loadHomeValues()
        }

        guard let homeValue = values.home.nonEmptySpiderValue else {
            guard let homeVideoValue = values.homeVideo?.nonEmptySpiderValue else {
                // FongMi permits Java/Dex sites without home content. Keeping
                // the provider alive preserves search/detail capabilities and
                // lets HomeView render its existing nonfatal empty state.
                return SiteHome(categories: [], recommendations: [])
            }
            return try filteredHome(
                homeValue: .object([:]),
                homeVideoValue: homeVideoValue
            )
        }
        return try filteredHome(
            homeValue: homeValue,
            homeVideoValue: values.homeVideo?.nonEmptySpiderValue
        )
    }

    static func shouldResetSpider(
        homeValue: JSONValue,
        homeVideoValue: JSONValue?
    ) -> Bool {
        homeValue.nonEmptySpiderValue == nil
            && homeVideoValue?.nonEmptySpiderValue == nil
    }

    private func loadHomeValues() async throws -> (
        home: JSONValue,
        homeVideo: JSONValue?
    ) {
        let home = try await invoke(method: "home", arguments: [.bool(true)])
        let homeVideo = try? await invoke(method: "homeVod", arguments: [])
        return (home, homeVideo)
    }

    private func filteredHome(
        homeValue: JSONValue,
        homeVideoValue: JSONValue?
    ) throws -> SiteHome {
        let result = try SpiderResponseMapper.home(
            homeValue,
            homeVideoValue: homeVideoValue,
            site: site,
            baseURL: baseURL
        )
        guard site.categories.isEmpty else {
            let allowed = Set(site.categories)
            return SiteHome(
                categories: result.categories.filter { allowed.contains($0.name) },
                recommendations: result.recommendations
            )
        }
        return result
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        let filterValues = Dictionary(
            uniqueKeysWithValues: filters.map { ($0.key, JSONValue.string($0.value)) }
        )
        let arguments: [JSONValue] = [
            .string(id),
            .string(String(page)),
            // OK/FongMi's category screen always enables the Spider filter
            // contract, even when every selected value is empty.
            .bool(true),
            .object(filterValues)
        ]
        var value = try await invoke(
            method: "category",
            arguments: arguments
        )
        if page == 1, value.nonEmptySpiderValue == nil {
            // Guard spiders can retain a failed upstream delegate. Recreate
            // the site and replay its normal home lifecycle once before
            // accepting an empty first page.
            _ = try? await invoke(method: "destroy", arguments: [])
            _ = try? await loadHomeValues()
            value = try await invoke(
                method: "category",
                arguments: arguments
            )
        }
        return try SpiderResponseMapper.page(
            value,
            site: site,
            baseURL: baseURL,
            page: page
        )
    }

    func detail(id: String) async throws -> VideoDetail {
        switch try await select(id: id) {
        case .detail(let detail):
            return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        try SpiderResponseMapper.selection(
            await invoke(method: "detail", arguments: [.array([.string(id)])]),
            site: site,
            baseURL: baseURL
        )
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable == 1, !quick || site.quickSearch == 1 else {
            return VideoPage(items: [], pagination: Pagination(page: page, pageCount: 0))
        }
        let arguments: [JSONValue]
        if page <= 1 {
            // FongMi's SiteApi intentionally calls the two-argument overload on
            // the first page. A large number of CatVod spiders only override it.
            arguments = [.string(keyword), .bool(quick)]
        } else {
            arguments = [.string(keyword), .bool(quick), .string(String(page))]
        }
        var didRetry = false
        let value: JSONValue
        do {
            value = try await invoke(
                method: "search",
                arguments: arguments
            )
        } catch {
            guard page <= 1 else { throw error }
            await resetSpiderForSearchRetry()
            didRetry = true
            value = try await invoke(
                method: "search",
                arguments: arguments
            )
        }

        var recoveredValue = value
        if !didRetry, Self.shouldRetrySearch(page: page, value: recoveredValue) {
            await resetSpiderForSearchRetry()
            didRetry = true
            recoveredValue = try await invoke(
                method: "search",
                arguments: arguments
            )
        }
        var mapped = try SpiderResponseMapper.page(
            recoveredValue,
            site: site,
            baseURL: baseURL,
            page: page
        )
        if !didRetry, page <= 1, mapped.items.isEmpty {
            await resetSpiderForSearchRetry()
            recoveredValue = try await invoke(
                method: "search",
                arguments: arguments
            )
            mapped = try SpiderResponseMapper.page(
                recoveredValue,
                site: site,
                baseURL: baseURL,
                page: page
            )
        }
        return mapped
    }

    static func shouldRetrySearch(page: Int, value: JSONValue) -> Bool {
        guard page <= 1 else { return false }
        if value.nonEmptySpiderValue == nil { return true }
        switch value {
        case .array(let values):
            return values.isEmpty
        case .object(let object):
            for key in ["list", "data", "videos"] {
                guard let nested = object[key] else { continue }
                if case .array(let values) = nested, values.isEmpty {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }

    private func resetSpiderForSearchRetry() async {
        // Search can be the first call made to a site. Guard spiders such as
        // WoGG need the same destroy -> home lifecycle recovery used by their
        // home/category entry points before a second search attempt.
        _ = try? await invoke(method: "destroy", arguments: [])
        _ = try? await home()
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        var result = try SpiderResponseMapper.player(
            await invoke(
                method: "play",
                arguments: [.string(flag), .string(episodeURL), .array([])]
            ),
            site: site
        )
        result.url = bridge.hostReachableProxyURL(result.url)
        result.qualities = result.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: bridge.hostReachableProxyURL($0.url)
            )
        }
        if let playURL = result.playURL {
            result.playURL = bridge.hostReachableProxyURL(playURL)
        }
        result.subtitles = result.subtitles.map {
            URL(string: bridge.hostReachableProxyURL($0.absoluteString)) ?? $0
        }
        return result
    }

    func action(_ action: String) async throws -> JSONValue {
        try await invoke(method: "action", arguments: [.string(action)])
    }

    private func invoke(
        method: String,
        arguments: [JSONValue]
    ) async throws -> JSONValue {
        try await bridge.invoke(
            site: site,
            jarReference: jarReference,
            baseURL: baseURL,
            method: method,
            arguments: arguments
        )
    }
}

enum AndroidRuntimePhase: Equatable, Sendable {
    case checking
    case unavailable
    case stopped
    case starting
    case running
    case stopping
    case failed
}

enum AndroidRuntimeStartupStage: String, Codable, CaseIterable, Sendable {
    case idle
    case locatingSDK
    case preparingAVD
    case launchingEmulator
    case waitingForADB
    case waitingForAndroidBoot
    case configuringPortForward
    case checkingEmulatorNetwork
    case installingBridge
    case launchingBridge
    case probingBridge
    case ready
    case stopping

    var progress: Double? {
        switch self {
        case .idle: return 0
        case .locatingSDK: return 0.03
        case .preparingAVD: return 0.07
        case .launchingEmulator: return 0.10
        case .waitingForADB: return 0.18
        case .waitingForAndroidBoot: return 0.32
        case .configuringPortForward: return 0.55
        case .checkingEmulatorNetwork: return 0.68
        case .installingBridge: return 0.84
        case .launchingBridge: return 0.88
        case .probingBridge: return 0.92
        case .ready: return 1
        case .stopping: return nil
        }
    }

    var title: String {
        switch self {
        case .idle: return "等待启动"
        case .locatingSDK: return "正在检查 Android SDK"
        case .preparingAVD: return "正在准备专用 Android 环境"
        case .launchingEmulator: return "正在启动 Android Emulator"
        case .waitingForADB: return "正在等待专用 Emulator 连接"
        case .waitingForAndroidBoot: return "正在等待 Android 系统启动"
        case .configuringPortForward: return "正在配置 Bridge 端口映射"
        case .checkingEmulatorNetwork: return "正在检查 Emulator 网络"
        case .installingBridge: return "正在安装 Android Bridge"
        case .launchingBridge: return "正在启动 Android Bridge"
        case .probingBridge: return "正在等待 Android Bridge 响应"
        case .ready: return "Android 兼容环境已就绪"
        case .stopping: return "正在停止 Android Emulator"
        }
    }

    static func stage(for progress: Double) -> AndroidRuntimeStartupStage {
        allCases
            .filter { $0.progress != nil && ($0.progress ?? 0) <= progress }
            .max { ($0.progress ?? 0) < ($1.progress ?? 0) } ?? .idle
    }
}

enum AndroidRuntimeFailureCategory: String, Codable, Sendable {
    case sdkIncomplete
    case adbUnavailable
    case emulatorLaunchFailed
    case emulatorLaunchTimedOut
    case emulatorOwnershipMismatch
    case androidBootTimedOut
    case emulatorNetworkUnavailable
    case bridgeAPKMissing
    case bridgeInstallFailed
    case bridgeLaunchFailed
    case portForwardFailed
    case hostPortConflict
    case bridgeHealthTimedOut
    case runtimeExited
    case unknown
}

struct AndroidRuntimeFailureRecord: Codable, Equatable, Sendable {
    let occurredAt: Date
    let stage: AndroidRuntimeStartupStage
    let category: AndroidRuntimeFailureCategory
    let message: String
}

struct AndroidRuntimeStageRecord: Codable, Equatable, Sendable {
    let stage: AndroidRuntimeStartupStage
    let startedAt: Date
    var completedAt: Date?
    var duration: TimeInterval?
    var error: String?
}

struct AndroidRuntimeEventRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let stage: AndroidRuntimeStartupStage
    let event: String
    let detail: String?
}

struct AndroidRuntimeCommandRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let category: String
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let timedOut: Bool
}

struct AndroidToolCommandError: LocalizedError, Sendable {
    let category: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let timedOut: Bool

    var errorDescription: String? {
        if timedOut {
            return "Android 工具超时（\(category)，\(Self.durationText(duration))）"
        }
        let diagnostic = stderr.nonEmptyCommandOutput
            ?? stdout.nonEmptyCommandOutput
            ?? "无输出"
        return "Android 工具失败（\(category)，exit=\(exitCode)）：\(String(diagnostic.prefix(1_000)))"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}

private extension String {
    var nonEmptyCommandOutput: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct AndroidRuntimeDiagnosticSnapshot: Codable, Equatable, Sendable {
    let runtimeState: String
    let startupStage: AndroidRuntimeStartupStage
    let progress: Double?
    let stageStartedAt: Date?
    let lastAttemptAt: Date?
    let lastSuccessfulStartAt: Date?
    let lastFailure: AndroidRuntimeFailureRecord?
    let sdkDiscoverySource: String?
    let sdkRoot: String?
    let adbPath: String?
    let adbExists: Bool
    let adbExecutable: Bool
    let adbVersion: String?
    let emulatorPath: String?
    let emulatorExists: Bool
    let emulatorExecutable: Bool
    let emulatorVersion: String?
    let avdManagerPath: String?
    let expectedAVDName: String
    let avdExists: Bool
    let avdPath: String
    let systemImage: String?
    let systemImageABI: String?
    let emulatorPID: Int32?
    let emulatorSerial: String?
    let emulatorProcessRunning: Bool
    let adbDeviceState: String?
    let androidBootCompleted: Bool?
    let bootWaitDuration: TimeInterval?
    let ipAddresses: String?
    let ipRoutes: String?
    let defaultRoutePresent: Bool?
    let wifiStatus: String?
    let networkRecoveryAttempted: Bool
    let networkRecoverySecurityException: Bool
    let networkRecoveryDuration: TimeInterval?
    let networkRecoveryResult: String?
    let networkRecoveryCommand: AndroidRuntimeCommandRecord?
    let connectivityProbeResult: String?
    let androidCPUABI: String?
    let androidSDKLevel: String?
    let androidRelease: String?
    let adbDevices: [String]
    let adbForwards: [String]
    let bridgeAPKPresentOnMac: Bool
    let bridgeAPKHash: String?
    let bridgePackageInstalled: Bool?
    let bridgePackageVersion: Int?
    let bridgeProcessRunning: Bool?
    let bridgeComponentStartResult: String?
    let hostPort: Int
    let guestPort: Int
    let hostPortOccupied: Bool?
    let forwardPresent: Bool?
    let forwardPointsToOwnedDevice: Bool?
    let probeURL: String
    let probeRetryCount: Int
    let probeHTTPStatus: Int?
    let probeErrorCategory: String?
    let probeDuration: TimeInterval?
    let stageHistory: [AndroidRuntimeStageRecord]
    let timeline: [AndroidRuntimeEventRecord]
    let recentCommands: [AndroidRuntimeCommandRecord]
}

struct AndroidRuntimeFailureError: LocalizedError, Sendable {
    let record: AndroidRuntimeFailureRecord

    var errorDescription: String? { record.message }

    var userFacingTitle: String { "Android 兼容环境启动失败" }

    var userFacingMessage: String {
        switch record.category {
        case .sdkIncomplete:
            return "Android SDK 不完整，请在设置中选择包含 ADB、Emulator 和系统镜像的 SDK。"
        case .adbUnavailable:
            return "ADB 无法使用，无法连接专用 Android Emulator。"
        case .emulatorLaunchFailed, .emulatorLaunchTimedOut, .runtimeExited:
            return "Android Emulator 未能正常启动，请导出诊断后重试。"
        case .emulatorOwnershipMismatch:
            return "无法安全确认专用 Android Emulator，已停止操作其他设备。"
        case .androidBootTimedOut:
            return "Android 系统启动超时，兼容环境没有在预期时间内完成启动。"
        case .emulatorNetworkUnavailable:
            return "Android Emulator 没有建立可用网络，请检查网络后重试。"
        case .bridgeAPKMissing, .bridgeInstallFailed:
            return "Android Bridge 安装失败，请重新安装测试版或导出诊断。"
        case .bridgeLaunchFailed:
            return "Android Bridge 服务启动失败，请使用“修复”后重试。"
        case .portForwardFailed:
            return "ADB 端口映射失败，Android Bridge 无法连接到 Mac。"
        case .hostPortConflict:
            return "本机 Android Bridge 端口被占用，请关闭冲突程序后重试。"
        case .bridgeHealthTimedOut:
            return "Android 兼容服务未响应；Emulator 已启动，但 Bridge 尚未建立连接。"
        case .unknown:
            return "Android 兼容环境启动失败，请立即导出诊断信息。"
        }
    }
}

struct AndroidRuntimeStatus: Equatable, Sendable {
    let phase: AndroidRuntimePhase
    let stage: AndroidRuntimeStartupStage
    let title: String
    let detail: String
    let progress: Double?

    var isRunning: Bool { phase == .running }

    static let checking = AndroidRuntimeStatus(
        phase: .checking,
        stage: .locatingSDK,
        title: "准备中",
        detail: "正在检查 Android 兼容环境…",
        progress: nil
    )

    static func unavailable(_ detail: String) -> AndroidRuntimeStatus {
        AndroidRuntimeStatus(
            phase: .unavailable,
            stage: .locatingSDK,
            title: "需要处理",
            detail: detail,
            progress: nil
        )
    }

    static let stopped = AndroidRuntimeStatus(
        phase: .stopped,
        stage: .idle,
        title: "已停止",
        detail: "Java/Dex 站点需要时将自动启动",
        progress: nil
    )

    static func starting(
        _ detail: String = "首次启动可能需要 1–4 分钟",
        progress: Double = 0
    ) -> AndroidRuntimeStatus {
        AndroidRuntimeStatus(
            phase: .starting,
            stage: .stage(for: progress),
            title: "准备中",
            detail: detail,
            progress: min(max(progress, 0), 1)
        )
    }

    static func starting(
        stage: AndroidRuntimeStartupStage,
        progress: Double? = nil
    ) -> AndroidRuntimeStatus {
        AndroidRuntimeStatus(
            phase: .starting,
            stage: stage,
            title: "准备中",
            detail: stage.title,
            progress: progress ?? stage.progress
        )
    }

    static let running = AndroidRuntimeStatus(
        phase: .running,
        stage: .ready,
        title: "已就绪",
        detail: "Java/Dex 站点可正常使用",
        progress: 1
    )

    static let stopping = AndroidRuntimeStatus(
        phase: .stopping,
        stage: .stopping,
        title: "正在停止",
        detail: "正在关闭 Android 模拟器",
        progress: nil
    )

    static func failed(
        _ detail: String,
        stage: AndroidRuntimeStartupStage = .idle
    ) -> AndroidRuntimeStatus {
        AndroidRuntimeStatus(
            phase: .failed,
            stage: stage,
            title: "需要处理",
            detail: "\(stage.title)：\(detail)",
            progress: nil
        )
    }
}

enum AndroidRuntimeFailureStatePolicy {
    static func status(
        operationStatus: AndroidRuntimeStatus?,
        lastFailure: AndroidRuntimeFailureRecord?
    ) -> AndroidRuntimeStatus? {
        if let operationStatus {
            return operationStatus
        }
        guard let lastFailure else { return nil }
        return .failed(lastFailure.message, stage: lastFailure.stage)
    }
}

enum AndroidRuntimeRecoveryPolicy {
    static let networkObservationTimeout: TimeInterval = 30
    static let networkPollNanoseconds: UInt64 = 500_000_000
    static let initialBridgeProbeAttempts = 30
    static let recoveredBridgeProbeAttempts = 20
    static let bridgeProbePollNanoseconds: UInt64 = 500_000_000

    static func shouldRetryKnownFailedNetworkCommand(
        lastFailureStage: AndroidRuntimeStartupStage?,
        networkRecoveryResult: String?
    ) -> Bool {
        !(lastFailureStage == .checkingEmulatorNetwork
            && networkRecoveryResult == "command_failed")
    }
}

final class AndroidDexBridgeClient {
    private struct Request: Encodable {
        let siteKey: String
        let api: String
        let ext: String
        let jarURL: String
        let jarMD5: String
        let method: String
        let arguments: [JSONValue]
    }

    private struct Response: Decodable {
        let ok: Bool
        let result: JSONValue?
        let error: String?
    }

    private let runtime: AndroidDexBridgeRuntime
    private let session: URLSession
    private let invokeURL = URL(string: "http://127.0.0.1:19978/v1/invoke")!
    private let uiStateURL = URL(string: "http://127.0.0.1:19978/v1/ui/state")!
    private let uiSubmitURL = URL(string: "http://127.0.0.1:19978/v1/ui/submit")!
    private let uiSnapshotURL = URL(string: "http://127.0.0.1:19978/v1/ui/snapshot")!
    private let authPushURL = URL(string: "http://127.0.0.1:19978/v1/auth/push")!

    init(runtime: AndroidDexBridgeRuntime = AndroidDexBridgeRuntime()) {
        self.runtime = runtime
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        configuration.httpMaximumConnectionsPerHost = 20
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func runtimeStatus() async -> AndroidRuntimeStatus {
        await runtime.status()
    }

    func diagnosticSnapshot() async -> AndroidRuntimeDiagnosticSnapshot {
        await runtime.diagnosticSnapshot()
    }

    func startRuntime() async throws -> AndroidRuntimeStatus {
        try await runtime.start()
        return await runtime.status()
    }

    func stopRuntime() async -> AndroidRuntimeStatus {
        await runtime.stop()
        return await runtime.status()
    }

    func repairRuntime() async throws -> AndroidRuntimeStatus {
        try await runtime.repair()
        return await runtime.status()
    }

    func setUserSelectedSDKRoot(_ url: URL) async {
        await runtime.setUserSelectedSDKRoot(url)
    }

    func hostReachableProxyURL(_ rawURL: String) -> String {
        let encodedURL = rawURL.addingPercentEncoding(
            withAllowedCharacters: Self.urlStructureAllowedCharacters
        ) ?? rawURL
        guard var components = URLComponents(string: encodedURL),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            ["127.0.0.1", "localhost", "::1"].contains(
                components.host?.lowercased() ?? ""
              ) else {
            return rawURL
        }

        let hostPort: Int
        switch components.port {
        case BridgeServerPort.guest where components.path.hasPrefix("/proxy"):
            hostPort = BridgeServerPort.host
        case BridgeServerPort.kaiserGuest
            where components.path.hasPrefix("/kaiser"),
             BridgeServerPort.kaiserHost
            where components.path.hasPrefix("/kaiser"):
            // NewWex currently starts its Kaiser service but disables all
            // business routes when its remote signature check fails. The
            // returned Kaiser URL still contains the already-authorized cloud
            // media URL, so stream that URL through our maintained Android
            // bridge instead of handing libmpv a guaranteed HTTP 503.
            if let directProxyURL = Self.bridgeMediaProxyURL(from: components) {
                return directProxyURL
            }
            // Preserve the old forwarding behavior for an unexpected Kaiser
            // response without a valid nested URL.
            hostPort = BridgeServerPort.kaiserHost
        case BridgeServerPort.cloudFileGuest
            where components.path.hasPrefix("/proxy/play/"):
            // Cloud-drive "original" lines are served by an HTTP file server
            // inside the Android process. Its URL commonly contains unescaped
            // Chinese path components, so URLComponents also performs the
            // percent encoding needed by Foundation and libmpv.
            hostPort = BridgeServerPort.cloudFileHost
        default:
            return rawURL
        }
        components.host = "127.0.0.1"
        components.port = hostPort
        return components.url?.absoluteString ?? rawURL
    }

    private static func bridgeMediaProxyURL(
        from kaiserComponents: URLComponents
    ) -> String? {
        guard let encodedQuery = kaiserComponents.percentEncodedQuery,
        let marker = encodedQuery.range(
            of: "(?:^|&)url=",
            options: [.regularExpression, .caseInsensitive]
        ),
        marker.upperBound < encodedQuery.endIndex else {
            return nil
        }
        // Kaiser receives cloud URLs whose own signed query often contains
        // unescaped ampersands (thread/chunk/key/type). URLComponents.queryItems
        // would mistake those for Kaiser parameters and truncate the URL at
        // the first ampersand, so everything following `url=` belongs to the
        // nested media URL. Most Wex responses leave the nested scheme raw;
        // in that form its own percent escapes must not be decoded. Older
        // responses encode the whole nested URL, which is detected by its
        // encoded scheme and decoded exactly once.
        let encodedUpstream = String(encodedQuery[marker.upperBound...])
        let lowercasedUpstream = encodedUpstream.lowercased()
        let rawUpstream: String
        if lowercasedUpstream.hasPrefix("http://")
            || lowercasedUpstream.hasPrefix("https://") {
            rawUpstream = encodedUpstream
        } else {
            rawUpstream = encodedUpstream.removingPercentEncoding
                ?? encodedUpstream
        }
        guard let upstream = URLComponents(string: rawUpstream),
        ["http", "https"].contains(upstream.scheme?.lowercased() ?? ""),
        let upstreamHost = upstream.host?.lowercased(),
        !["127.0.0.1", "localhost", "::1"].contains(upstreamHost) else {
            return nil
        }
        // URLComponents normalizes any unescaped Unicode path returned by a
        // Spider before it is nested into the bridge query parameter.
        guard let normalizedUpstream = upstream.url?.absoluteString else {
            return nil
        }
        var proxy = URLComponents()
        proxy.scheme = "http"
        proxy.host = "127.0.0.1"
        proxy.port = BridgeServerPort.host
        proxy.path = "/v1/media"
        // Encode every query delimiter and percent sign as data for the outer
        // bridge URL. BridgeServer decodes this layer once, leaving the
        // upstream URL (including escapes such as `%2B`) byte-for-byte intact.
        guard let encodedUpstream = normalizedUpstream.addingPercentEncoding(
            withAllowedCharacters: Self.bridgeMediaQueryValueAllowedCharacters
        ) else {
            return nil
        }
        proxy.percentEncodedQuery = "url=\(encodedUpstream)"
        return proxy.url?.absoluteString
    }

    private static let bridgeMediaQueryValueAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz"
            + "0123456789-._~"
    )

    private static let urlStructureAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz"
            + "0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    func invoke(
        site: SiteConfiguration,
        jarReference: String,
        baseURL: URL?,
        method: String,
        arguments: [JSONValue]
    ) async throws -> JSONValue {
        try await runtime.ensureReady()
        let monitorsAuthorization = Self.shouldMonitorAuthorization(
            for: method,
            site: site
        )
        if monitorsAuthorization,
           let staleState = try? await uiState(),
           staleState.isAuthorizationPrompt {
            // A dialog belongs to the operation that created it. If it was
            // hidden on macOS without resetting Android, accepting it here
            // would attach an old cloud-login window to an unrelated detail
            // or playback click.
            try await resetAuthorizationUI()
        }
        let jar = try Self.jarParts(jarReference, baseURL: baseURL)
        var request = URLRequest(url: invokeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Request(
                siteKey: site.key,
                api: site.api,
                ext: try Self.extString(site.ext),
                jarURL: jar.url.absoluteString,
                jarMD5: jar.md5,
                method: method,
                arguments: arguments
            )
        )
        let (data, urlResponse): (Data, URLResponse)
        if monitorsAuthorization {
            (data, urlResponse) = try await sendMonitoringAuthorization(request)
        } else {
            (data, urlResponse) = try await session.data(for: request)
        }
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppError.spider("Java/Dex 桥没有返回 HTTP 响应")
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.spider(
                "Java/Dex 桥响应无效（HTTP \(httpResponse.statusCode)）："
                    + String(text.prefix(500))
            )
        }
        guard response.ok, (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.spider(
                Self.userFacingBridgeError(
                    response.error
                        ?? "Java/Dex 桥 HTTP \(httpResponse.statusCode)"
                )
            )
        }
        return response.result ?? .null
    }

    func uiState() async throws -> AndroidBridgeUIState {
        try await runtime.ensureReady()
        return try await fetchUIState()
    }

    private func fetchUIState() async throws -> AndroidBridgeUIState {
        var request = URLRequest(url: uiStateURL)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.spider("无法读取网盘授权界面")
        }
        return try JSONDecoder().decode(AndroidBridgeUIState.self, from: data)
    }

    @discardableResult
    func submitUI(
        text: String?,
        button: String,
        controlID: String?
    ) async throws -> Bool {
        try await runtime.ensureReady()
        var request = URLRequest(url: uiSubmitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "text": (text as Any?) ?? NSNull(),
                "button": button,
                "controlID": (controlID as Any?) ?? NSNull()
            ] as [String: Any]
        )
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw AppError.spider("无法提交网盘授权操作")
        }
        return object["clicked"] as? Bool == true
    }

    func uiSnapshot() async throws -> Data {
        try await runtime.ensureReady()
        var request = URLRequest(url: uiSnapshotURL)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else {
            throw AppError.spider("无法读取网盘扫码界面")
        }
        return data
    }

    func pushCredential(provider: String, credential: String) async throws {
        let normalizedProvider = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let supportedProviders = ["baidu", "quark", "uc", "ali", "bili"]
        guard supportedProviders.contains(normalizedProvider) else {
            throw AppError.spider("当前网盘类型不支持本机凭据提交")
        }
        guard !credential
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw AppError.spider("请先粘贴 Cookie 或 Token")
        }

        try await runtime.ensureReady()
        var request = URLRequest(url: authPushURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "provider": normalizedProvider,
                "credential": credential
            ]
        )
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["ok"] as? Bool == true,
              object["accepted"] as? Bool == true else {
            throw AppError.spider("本机 Android 桥未能接收网盘凭据")
        }
    }

    func resetAuthorizationUI() async throws {
        try await runtime.resetAuthorizationUI()
    }

    private enum InvokeOutcome {
        case response(Data, URLResponse)
        case authorization(AndroidBridgeUIState)
    }

    static func shouldMonitorAuthorization(
        for method: String,
        site: SiteConfiguration
    ) -> Bool {
        if method == "play" || method == "action" { return true }
        guard method == "detail" else { return false }
        let api = site.api.lowercased()
        let key = site.key.lowercased()
        return api.contains("config") || key.contains("config")
    }

    private func sendMonitoringAuthorization(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: InvokeOutcome.self) { group in
            group.addTask { [session] in
                let (data, response) = try await session.data(for: request)
                return .response(data, response)
            }
            group.addTask { [weak self] in
                for _ in 0..<300 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 250_000_000)
                    guard let self else { throw CancellationError() }
                    // invoke() has already prepared the runtime. Poll the
                    // bridge endpoint directly so a normal authorization wait
                    // does not repeat emulator/ADB health checks four times a
                    // second.
                    if let state = try? await self.fetchUIState(),
                       state.isAuthorizationPrompt {
                        return .authorization(state)
                    }
                }
                throw AppError.spider("等待 Java/Dex 响应超时")
            }
            guard let first = try await group.next() else {
                throw AppError.spider("Java/Dex 桥没有返回响应")
            }
            group.cancelAll()
            switch first {
            case .response(let data, let response):
                return (data, response)
            case .authorization(let state):
                throw AndroidBridgeUIRequired(state: state)
            }
        }
    }

    private static func jarParts(
        _ reference: String,
        baseURL: URL?
    ) throws -> (url: URL, md5: String) {
        let marker = ";md5;"
        let parts = reference.components(separatedBy: marker)
        let rawURL = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = try ResourceResolver.resolve(rawURL, relativeTo: baseURL)
        guard ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else {
            throw AppError.spider("Java/Dex 包只允许 HTTP/HTTPS")
        }
        let md5 = parts.count > 1
            ? parts.dropFirst().joined(separator: marker)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (resolved, md5)
    }

    private static func extString(_ value: JSONValue?) throws -> String {
        guard let value else { return "" }
        if case .string(let string) = value {
            return string
        }
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.spider("无法编码 Java/Dex 站点扩展参数")
        }
        return text
    }

    private static func userFacingBridgeError(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("end of input") {
            return "站点返回空响应，上游接口可能暂时不可用"
        }
        return message
    }
}

struct AndroidToolchain: Equatable, Sendable {
    let sdkRoot: URL
    let adb: URL
    let emulator: URL
    let avdManager: URL?
}

struct AndroidSystemImage: Equatable, Sendable {
    let packageID: String
    let apiLevel: Int
    let variant: String
    let architecture: String
}

struct AndroidToolchainResolver {
    static let userSDKRootDefaultsKey = "OKVideoMac.AndroidSDKRoot"

    let applicationSupportDirectory: URL
    let homeDirectory: URL
    let environment: [String: String]
    let userSelectedSDKRoot: String?
    let fileManager: FileManager

    func resolve() -> AndroidToolchain? {
        for root in candidateSDKRoots() {
            if let toolchain = toolchain(at: root) {
                return toolchain
            }
        }
        return nil
    }

    func toolchain(at root: URL) -> AndroidToolchain? {
        let normalizedRoot = Self.normalized(root)
        let adb = normalizedRoot.appendingPathComponent("platform-tools/adb")
        let emulator = normalizedRoot.appendingPathComponent("emulator/emulator")
        guard fileManager.isExecutableFile(atPath: adb.path),
              fileManager.isExecutableFile(atPath: emulator.path) else {
            return nil
        }
        return AndroidToolchain(
            sdkRoot: normalizedRoot,
            adb: adb.resolvingSymlinksInPath(),
            emulator: emulator.resolvingSymlinksInPath(),
            avdManager: avdManager(in: normalizedRoot)
        )
    }

    func installedSystemImages(in toolchain: AndroidToolchain) -> [AndroidSystemImage] {
        let root = toolchain.sdkRoot.appendingPathComponent("system-images")
        guard let apiDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var images: [AndroidSystemImage] = []
        for apiDirectory in apiDirectories {
            let apiName = apiDirectory.lastPathComponent
            guard apiName.hasPrefix("android-"),
                  let apiLevel = Int(apiName.dropFirst("android-".count)),
                  let variants = try? fileManager.contentsOfDirectory(
                    at: apiDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for variantDirectory in variants {
                guard let architectures = try? fileManager.contentsOfDirectory(
                    at: variantDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for architectureDirectory in architectures {
                    let architecture = architectureDirectory.lastPathComponent
                    guard architecture == "arm64-v8a",
                          fileManager.fileExists(
                            atPath: architectureDirectory
                                .appendingPathComponent("package.xml").path
                          ) else { continue }
                    let variant = variantDirectory.lastPathComponent
                    images.append(
                        AndroidSystemImage(
                            packageID: "system-images;\(apiName);\(variant);\(architecture)",
                            apiLevel: apiLevel,
                            variant: variant,
                            architecture: architecture
                        )
                    )
                }
            }
        }
        return images.sorted { lhs, rhs in
            if lhs.apiLevel != rhs.apiLevel {
                return lhs.apiLevel > rhs.apiLevel
            }
            let rank: (String) -> Int = { variant in
                switch variant {
                case "google_apis": return 0
                case "default": return 1
                default: return 2
                }
            }
            return rank(lhs.variant) < rank(rhs.variant)
        }
    }

    private func candidateSDKRoots() -> [URL] {
        var candidates: [URL] = [
            applicationSupportDirectory
                .appendingPathComponent("AndroidRuntime/sdk", isDirectory: true)
        ]
        if let userSelectedSDKRoot, !userSelectedSDKRoot.isEmpty {
            candidates.append(Self.url(from: userSelectedSDKRoot))
        }
        if let androidHome = environment["ANDROID_HOME"], !androidHome.isEmpty {
            candidates.append(Self.url(from: androidHome))
        }
        if let deprecatedRoot = environment["ANDROID_SDK_ROOT"],
           !deprecatedRoot.isEmpty {
            candidates.append(Self.url(from: deprecatedRoot))
        }
        candidates.append(
            homeDirectory.appendingPathComponent("Library/Android/sdk")
        )
        if let path = environment["PATH"] {
            for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
                if let inferred = Self.inferredSDKRoot(
                    fromPATHEntry: URL(fileURLWithPath: String(entry))
                ) {
                    candidates.append(inferred)
                }
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let normalized = Self.normalized(candidate)
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    private func avdManager(in sdkRoot: URL) -> URL? {
        let latest = sdkRoot.appendingPathComponent(
            "cmdline-tools/latest/bin/avdmanager"
        )
        if fileManager.isExecutableFile(atPath: latest.path) {
            return latest.resolvingSymlinksInPath()
        }
        let commandLineTools = sdkRoot.appendingPathComponent("cmdline-tools")
        guard let versions = try? fileManager.contentsOfDirectory(
            at: commandLineTools,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let candidate = version.appendingPathComponent("bin/avdmanager")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    static func inferredSDKRoot(fromPATHEntry entry: URL) -> URL? {
        let normalized = normalized(entry)
        switch normalized.lastPathComponent {
        case "platform-tools", "emulator":
            return normalized.deletingLastPathComponent()
        case "bin":
            let version = normalized.deletingLastPathComponent()
            let commandLineTools = version.deletingLastPathComponent()
            guard commandLineTools.lastPathComponent == "cmdline-tools" else {
                return nil
            }
            return commandLineTools.deletingLastPathComponent()
        default:
            return nil
        }
    }

    private static func url(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct AndroidPortForwardIdentity: Codable, Equatable, Sendable {
    let hostPort: Int
    let devicePort: Int
}

struct AndroidRuntimeIdentity: Codable, Equatable, Sendable {
    let schema: Int
    var generation: String
    let sdkRoot: URL
    let emulatorExecutable: URL
    let avdName: String
    let avdDirectory: URL
    let pid: Int32
    let consolePort: Int
    let serial: String
    let forwards: [AndroidPortForwardIdentity]
    let launchedAt: Date
}

actor AndroidDexBridgeRuntime {
    private static let bridgeVersion = "0.3.15"
    private static let bridgeVersionCode = 27
    private static let networkCheckInterval: TimeInterval = 30
    private static let manifestSchema = 1
    private static let avdName = "OKVideoMac_Runtime"
    static let candidateConsolePorts = Array(
        stride(from: 5_554, through: 5_682, by: 2)
    )

    private let applicationSupportDirectory: URL
    private let runtimeDirectory: URL
    private let avdHome: URL
    private let avdDirectory: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL
    private var userSelectedSDKRoot: String?
    private var emulatorProcess: Process?
    private var emulatorLogHandle: FileHandle?
    private var ready = false
    private var acceptsNewerBridge = false
    private var lastNetworkCheck: Date?
    private var readinessTask: Task<Void, Error>?
    private var operationStatus: AndroidRuntimeStatus?
    private var currentStage: AndroidRuntimeStartupStage = .idle
    private var stageStartedAt: Date?
    private var lastAttemptAt: Date?
    private var lastSuccessfulStartAt: Date?
    private var lastFailure: AndroidRuntimeFailureRecord?
    private var stageHistory: [AndroidRuntimeStageRecord] = []
    private var timeline: [AndroidRuntimeEventRecord] = []
    private var recentCommands: [AndroidRuntimeCommandRecord] = []
    private var lastObservedIdentity: AndroidRuntimeIdentity?
    private var lastObservedToolchain: AndroidToolchain?
    private var lastBootCompleted: Bool?
    private var lastBootWaitDuration: TimeInterval?
    private var lastIPAddressOutput: String?
    private var lastIPRouteOutput: String?
    private var lastDefaultRoutePresent: Bool?
    private var lastWiFiStatus: String?
    private var networkRecoveryAttempted = false
    private var networkRecoverySecurityException = false
    private var networkRecoveryDuration: TimeInterval?
    private var networkRecoveryResult: String?
    private var lastNetworkRecoveryCommand: AndroidRuntimeCommandRecord?
    private var connectivityProbeResult: String?
    private var lastADBDevices: [String] = []
    private var lastADBForwards: [String] = []
    private var lastBridgePackageInstalled: Bool?
    private var lastBridgeVersionCode: Int?
    private var lastBridgeProcessRunning: Bool?
    private var lastBridgeComponentStartResult: String?
    private var probeStartedAt: Date?
    private var probeRetryCount = 0
    private var probeHTTPStatus: Int?
    private var probeErrorCategory: String?
    private var probeDuration: TimeInterval?

    init(
        applicationSupportDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let fileManager = FileManager.default
        let defaults = UserDefaults.standard
        let support = applicationSupportDirectory ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/OKVideoMac",
                isDirectory: true
            )
        self.applicationSupportDirectory = support
        runtimeDirectory = support.appendingPathComponent(
            "AndroidRuntime",
            isDirectory: true
        )
        avdHome = runtimeDirectory.appendingPathComponent("avd", isDirectory: true)
        avdDirectory = avdHome.appendingPathComponent(
            "\(Self.avdName).avd",
            isDirectory: true
        )
        manifestURL = runtimeDirectory.appendingPathComponent(
            "runtime-manifest.json"
        )
        self.fileManager = fileManager
        self.defaults = defaults
        baseEnvironment = environment
        homeDirectory = fileManager.homeDirectoryForCurrentUser
        userSelectedSDKRoot = defaults.string(
            forKey: AndroidToolchainResolver.userSDKRootDefaultsKey
        )
    }

    private func transition(
        to stage: AndroidRuntimeStartupStage,
        progress: Double? = nil,
        event: String = "started",
        detail: String? = nil
    ) {
        let now = Date()
        if currentStage != stage {
            completeCurrentStage(at: now)
            currentStage = stage
            stageStartedAt = now
            stageHistory.append(
                AndroidRuntimeStageRecord(
                    stage: stage,
                    startedAt: now,
                    completedAt: nil,
                    duration: nil,
                    error: nil
                )
            )
            if stageHistory.count > 50 {
                stageHistory.removeFirst(stageHistory.count - 50)
            }
        }
        appendEvent(stage: stage, event: event, detail: detail)
        switch stage {
        case .idle:
            operationStatus = nil
        case .ready:
            operationStatus = .running
        case .stopping:
            operationStatus = .stopping
        default:
            operationStatus = .starting(
                stage: stage,
                progress: progress ?? stage.progress
            )
        }
    }

    private func completeCurrentStage(
        at date: Date = Date(),
        error: String? = nil
    ) {
        guard let index = stageHistory.indices.last,
              stageHistory[index].completedAt == nil else { return }
        stageHistory[index].completedAt = date
        stageHistory[index].duration = date.timeIntervalSince(
            stageHistory[index].startedAt
        )
        stageHistory[index].error = error
    }

    private func appendEvent(
        stage: AndroidRuntimeStartupStage,
        event: String,
        detail: String? = nil
    ) {
        timeline.append(
            AndroidRuntimeEventRecord(
                timestamp: Date(),
                stage: stage,
                event: event,
                detail: detail.map(LogRedactor.text)
            )
        )
        if timeline.count > 100 {
            timeline.removeFirst(timeline.count - 100)
        }
    }

    private func classifiedFailure(
        for error: Error,
        stage: AndroidRuntimeStartupStage? = nil
    ) -> AndroidRuntimeFailureError {
        if let runtimeError = error as? AndroidRuntimeFailureError {
            return runtimeError
        }
        let failedStage = stage ?? currentStage
        let message = LogRedactor.text(error.localizedDescription)
        let lowercased = message.lowercased()
        let category: AndroidRuntimeFailureCategory
        if lowercased.contains("所有权") || lowercased.contains("身份") {
            category = .emulatorOwnershipMismatch
        } else {
            switch failedStage {
            case .locatingSDK, .preparingAVD:
                category = .sdkIncomplete
            case .launchingEmulator:
                category = lowercased.contains("超时")
                    ? .emulatorLaunchTimedOut : .emulatorLaunchFailed
            case .waitingForADB:
                category = .adbUnavailable
            case .waitingForAndroidBoot:
                category = .androidBootTimedOut
            case .configuringPortForward:
                category = Self.isEmulatorPortConflict(message)
                    ? .hostPortConflict : .portForwardFailed
            case .checkingEmulatorNetwork:
                category = .emulatorNetworkUnavailable
            case .installingBridge:
                category = lowercased.contains("缺少")
                    ? .bridgeAPKMissing : .bridgeInstallFailed
            case .launchingBridge:
                category = .bridgeLaunchFailed
            case .probingBridge:
                category = .bridgeHealthTimedOut
            case .idle, .ready, .stopping:
                category = .unknown
            }
        }
        return AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: failedStage,
                category: category,
                message: message
            )
        )
    }

    private func preserveFailure(_ failure: AndroidRuntimeFailureError) {
        lastFailure = failure.record
        completeCurrentStage(error: failure.record.message)
        appendEvent(
            stage: failure.record.stage,
            event: "failed",
            detail: "\(failure.record.category.rawValue): \(failure.record.message)"
        )
    }

    func status() async -> AndroidRuntimeStatus {
        if let persisted = AndroidRuntimeFailureStatePolicy.status(
            operationStatus: operationStatus,
            lastFailure: lastFailure
        ) {
            return persisted
        }

        if fileManager.fileExists(atPath: manifestURL.path) {
            guard let identity = loadIdentity() else {
                return .failed("Android 运行记录损坏，需要重新初始化")
            }
            guard let toolchain = resolver().toolchain(at: identity.sdkRoot) else {
                return .failed("原 Android SDK 已不可用，无法安全确认运行实例")
            }
            if verifyProcessOwnership(identity, toolchain: toolchain) {
                guard verifyDeviceOwnership(identity, toolchain: toolchain) else {
                    return .starting(progress: 0.45)
                }
                if await isHealthy(
                    identity,
                    toolchain: toolchain,
                    acceptVersionMismatch: true
                ) {
                    ready = true
                    acceptsNewerBridge = true
                    lastNetworkCheck = Date()
                    return .running
                }
                return .starting(progress: 0.70)
            }
            if processExecutablePath(pid: identity.pid) != nil
                || deviceIsReachable(identity, toolchain: toolchain) {
                return .failed("无法安全确认 Android 实例所有权；请重新初始化")
            }
            try? fileManager.removeItem(at: manifestURL)
        }

        ready = false
        guard let toolchain = resolver().resolve() else {
            return .unavailable("未找到完整 Android SDK，请选择包含 adb 和 emulator 的 SDK")
        }
        if fileManager.fileExists(
            atPath: avdDirectory.appendingPathComponent("config.ini").path
        ) {
            return .stopped
        }
        guard toolchain.avdManager != nil else {
            return .unavailable("缺少 Android SDK Command-line Tools（avdmanager）")
        }
        guard !resolver().installedSystemImages(in: toolchain).isEmpty else {
            return .unavailable("缺少可用的 arm64 Android system image")
        }
        return .stopped
    }

    func diagnosticSnapshot() async -> AndroidRuntimeDiagnosticSnapshot {
        let identity = loadIdentity() ?? lastObservedIdentity
        let toolchain = identity.flatMap {
            resolver().toolchain(at: $0.sdkRoot)
        } ?? resolver().resolve() ?? lastObservedToolchain
        if let toolchain {
            lastObservedToolchain = toolchain
        }
        if let identity {
            lastObservedIdentity = identity
        }

        var adbVersion: String?
        var emulatorVersion: String?
        var deviceState: String?
        var androidCPUABI: String?
        var androidSDKLevel: String?
        var androidRelease: String?
        var processRunning = false
        var forwardPresent: Bool?
        var forwardOwned: Bool?

        if let toolchain {
            adbVersion = try? run(
                toolchain.adb,
                ["version"],
                category: "diagnostic.adb.version",
                timeout: 5
            )
            emulatorVersion = try? run(
                toolchain.emulator,
                ["-version"],
                category: "diagnostic.emulator.version",
                timeout: 5
            )
            if let devices = try? run(
                toolchain.adb,
                ["devices", "-l"],
                category: "diagnostic.adb.devices",
                timeout: 5
            ) {
                lastADBDevices = Self.sanitizedADBDevices(
                    devices,
                    ownedSerial: identity?.serial
                )
            }
        }

        if let identity, let toolchain {
            processRunning = verifyProcessOwnership(
                identity,
                toolchain: toolchain
            )
            deviceState = try? run(
                toolchain.adb,
                ["-s", identity.serial, "get-state"],
                category: "diagnostic.adb.get_state",
                timeout: 5
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if verifyOwnership(identity, toolchain: toolchain) {
                if let boot = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "getprop", "sys.boot_completed"],
                    category: "diagnostic.android.boot_completed",
                    timeout: 5
                ) {
                    lastBootCompleted = boot.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == "1"
                }
                androidCPUABI = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "getprop", "ro.product.cpu.abi"],
                    category: "diagnostic.android.cpu_abi",
                    timeout: 5
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                androidSDKLevel = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "getprop", "ro.build.version.sdk"],
                    category: "diagnostic.android.sdk_level",
                    timeout: 5
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                androidRelease = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "getprop", "ro.build.version.release"],
                    category: "diagnostic.android.release",
                    timeout: 5
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                _ = observeNetwork(identity, toolchain: toolchain)
                let installed = installedBridgeVersionCode(
                    identity,
                    toolchain: toolchain
                )
                lastBridgeVersionCode = installed
                lastBridgePackageInstalled = installed != nil
                if let bridgePID = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "pidof", "com.okvideomac.dexbridge"],
                    category: "diagnostic.bridge.pidof",
                    timeout: 5
                ) {
                    lastBridgeProcessRunning = !bridgePID.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                } else {
                    lastBridgeProcessRunning = false
                }
                if let forwards = try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["forward", "--list"],
                    category: "diagnostic.adb.forwards",
                    timeout: 5
                ) {
                    lastADBForwards = Self.sanitizedADBForwards(
                        forwards,
                        ownedSerial: identity.serial
                    )
                    forwardPresent = Self.portForwardExists(
                        listing: forwards,
                        device: identity.serial,
                        host: BridgeServerPort.host,
                        guest: BridgeServerPort.guest
                    )
                    forwardOwned = forwardPresent
                }
            }
        }

        let image = toolchain.flatMap {
            resolver().installedSystemImages(in: $0).first
        }
        let apk = try? bridgeAPK()
        let apkHash = apk.flatMap(Self.sha256Hex)
        let configExists = fileManager.fileExists(
            atPath: avdDirectory.appendingPathComponent("config.ini").path
        )
        let runtimeState: String
        if let operationStatus {
            runtimeState = String(describing: operationStatus.phase)
        } else if ready {
            runtimeState = "running"
        } else if lastFailure != nil {
            runtimeState = "failed"
        } else if processRunning {
            runtimeState = "starting"
        } else {
            runtimeState = "stopped"
        }
        return AndroidRuntimeDiagnosticSnapshot(
            runtimeState: runtimeState,
            startupStage: currentStage,
            progress: operationStatus?.progress ?? currentStage.progress,
            stageStartedAt: stageStartedAt,
            lastAttemptAt: lastAttemptAt,
            lastSuccessfulStartAt: lastSuccessfulStartAt,
            lastFailure: lastFailure,
            sdkDiscoverySource: toolchain.map(sdkDiscoverySource),
            sdkRoot: toolchain.map { _ in "<sdk-root>" },
            adbPath: toolchain.map { _ in "<sdk-root>/platform-tools/adb" },
            adbExists: toolchain.map {
                fileManager.fileExists(atPath: $0.adb.path)
            } ?? false,
            adbExecutable: toolchain.map {
                fileManager.isExecutableFile(atPath: $0.adb.path)
            } ?? false,
            adbVersion: adbVersion.map(Self.firstDiagnosticLine),
            emulatorPath: toolchain.map { _ in "<sdk-root>/emulator/emulator" },
            emulatorExists: toolchain.map {
                fileManager.fileExists(atPath: $0.emulator.path)
            } ?? false,
            emulatorExecutable: toolchain.map {
                fileManager.isExecutableFile(atPath: $0.emulator.path)
            } ?? false,
            emulatorVersion: emulatorVersion.map(Self.firstDiagnosticLine),
            avdManagerPath: toolchain?.avdManager.map { _ in
                "<sdk-root>/cmdline-tools/<version>/bin/avdmanager"
            },
            expectedAVDName: Self.avdName,
            avdExists: configExists,
            avdPath: "<app-support>/AndroidRuntime/avd/\(Self.avdName).avd",
            systemImage: image?.packageID,
            systemImageABI: image?.architecture,
            emulatorPID: identity?.pid,
            emulatorSerial: identity?.serial,
            emulatorProcessRunning: processRunning,
            adbDeviceState: deviceState,
            androidBootCompleted: lastBootCompleted,
            bootWaitDuration: lastBootWaitDuration,
            ipAddresses: lastIPAddressOutput,
            ipRoutes: lastIPRouteOutput,
            defaultRoutePresent: lastDefaultRoutePresent,
            wifiStatus: lastWiFiStatus,
            networkRecoveryAttempted: networkRecoveryAttempted,
            networkRecoverySecurityException: networkRecoverySecurityException,
            networkRecoveryDuration: networkRecoveryDuration,
            networkRecoveryResult: networkRecoveryResult,
            networkRecoveryCommand: lastNetworkRecoveryCommand,
            connectivityProbeResult: connectivityProbeResult,
            androidCPUABI: androidCPUABI,
            androidSDKLevel: androidSDKLevel,
            androidRelease: androidRelease,
            adbDevices: lastADBDevices,
            adbForwards: lastADBForwards,
            bridgeAPKPresentOnMac: apk != nil,
            bridgeAPKHash: apkHash,
            bridgePackageInstalled: lastBridgePackageInstalled,
            bridgePackageVersion: lastBridgeVersionCode,
            bridgeProcessRunning: lastBridgeProcessRunning,
            bridgeComponentStartResult: lastBridgeComponentStartResult,
            hostPort: BridgeServerPort.host,
            guestPort: BridgeServerPort.guest,
            hostPortOccupied: lastFailure?.category == .hostPortConflict,
            forwardPresent: forwardPresent,
            forwardPointsToOwnedDevice: forwardOwned,
            probeURL: "http://127.0.0.1:<bridge-port>/health",
            probeRetryCount: probeRetryCount,
            probeHTTPStatus: probeHTTPStatus,
            probeErrorCategory: probeErrorCategory,
            probeDuration: probeDuration,
            stageHistory: stageHistory,
            timeline: timeline,
            recentCommands: recentCommands
        )
    }

    private func sdkDiscoverySource(_ toolchain: AndroidToolchain) -> String {
        let root = toolchain.sdkRoot.standardizedFileURL.path
        if let selected = userSelectedSDKRoot,
           URL(fileURLWithPath: selected).standardizedFileURL.path == root {
            return "user-selected"
        }
        if baseEnvironment["ANDROID_HOME"].map({
            URL(fileURLWithPath: $0).standardizedFileURL.path == root
        }) == true {
            return "ANDROID_HOME"
        }
        if root.hasPrefix(applicationSupportDirectory.standardizedFileURL.path) {
            return "app-managed"
        }
        if root.hasPrefix(homeDirectory.standardizedFileURL.path) {
            return "default-home"
        }
        return "PATH-or-external"
    }

    static func sanitizedADBDevices(
        _ output: String,
        ownedSerial: String?
    ) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[0] != "List" else { return nil }
            let serial = String(fields[0])
            let state = String(fields[1])
            return serial == ownedSerial
                ? "\(serial) state=\(state) owned=true"
                : "<unrelated-device> state=\(state) owned=false"
        }
    }

    static func sanitizedADBForwards(
        _ output: String,
        ownedSerial: String
    ) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard line.hasPrefix("\(ownedSerial) ") else { return nil }
            return line
        }
    }

    private static func sha256Hex(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private static func firstDiagnosticLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? output
    }

    func setUserSelectedSDKRoot(_ url: URL) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
        defaults.set(
            normalized,
            forKey: AndroidToolchainResolver.userSDKRootDefaultsKey
        )
        userSelectedSDKRoot = normalized
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
    }

    func start() async throws {
        try await ensureReady()
    }

    func repair() async throws {
        let retryKnownFailedNetworkCommand = AndroidRuntimeRecoveryPolicy
            .shouldRetryKnownFailedNetworkCommand(
                lastFailureStage: lastFailure?.stage,
                networkRecoveryResult: networkRecoveryResult
            )
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
        let activeTask = readinessTask
        activeTask?.cancel()
        _ = try? await activeTask?.value
        readinessTask = nil
        try await prepareRuntime(
            forceInstall: true,
            retryKnownFailedNetworkCommand: retryKnownFailedNetworkCommand
        )
    }

    func stop() async {
        transition(to: .stopping, event: "stop_requested")
        let task = readinessTask
        task?.cancel()
        readinessTask = nil
        _ = try? await task?.value
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
        defer {
            completeCurrentStage()
            currentStage = .idle
            stageStartedAt = nil
            operationStatus = nil
        }

        guard let identity = loadIdentity() else {
            return
        }
        guard let toolchain = resolver().toolchain(at: identity.sdkRoot),
              verifyOwnership(identity, toolchain: toolchain) else {
            if processExecutablePath(pid: identity.pid) == nil,
               !deviceIsReachable(
                    identity,
                    toolchain: resolver().toolchain(at: identity.sdkRoot)
                ) {
                clearRuntimeRecord()
            } else {
                let failure = classifiedFailure(
                    for: AppError.spider(
                        "无法安全确认 Android 实例所有权，已拒绝停止任何 Emulator"
                    ),
                    stage: .stopping
                )
                preserveFailure(failure)
            }
            return
        }
        do {
            try removeOwnedPortForwards(identity, toolchain: toolchain)
            _ = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["emu", "kill"]
            )
            for _ in 0..<40 {
                if processExecutablePath(pid: identity.pid) == nil,
                   !deviceIsReachable(identity, toolchain: toolchain) {
                    clearRuntimeRecord()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if verifyProcessOwnership(identity, toolchain: toolchain) {
                _ = Darwin.kill(identity.pid, SIGTERM)
            }
            for _ in 0..<20 {
                if processExecutablePath(pid: identity.pid) == nil,
                   !deviceIsReachable(identity, toolchain: toolchain) {
                    clearRuntimeRecord()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            preserveFailure(
                classifiedFailure(
                    for: AppError.spider(
                        "专用 Android Emulator 未确认停止；已保留运行记录以防误操作"
                    ),
                    stage: .stopping
                )
            )
        } catch {
            preserveFailure(classifiedFailure(for: error, stage: .stopping))
        }
    }

    func ensureReady() async throws {
        if ready {
            guard let identity = loadIdentity(),
                  let toolchain = resolver().toolchain(at: identity.sdkRoot),
                  verifyOwnership(identity, toolchain: toolchain) else {
                ready = false
                throw AppError.spider(
                    "Android 运行实例所有权校验失败，已拒绝继续操作"
                )
            }
            if let lastNetworkCheck,
               Date().timeIntervalSince(lastNetworkCheck)
                    < Self.networkCheckInterval {
                return
            }
            if await isHealthy(
                identity,
                toolchain: toolchain,
                acceptVersionMismatch: acceptsNewerBridge
            ) {
                lastNetworkCheck = Date()
                return
            }
            ready = false
        }
        if let readinessTask {
            return try await readinessTask.value
        }
        let task = Task {
            try await prepareRuntime()
        }
        readinessTask = task
        do {
            try await task.value
            readinessTask = nil
        } catch {
            readinessTask = nil
            throw error
        }
    }

    func resetAuthorizationUI() async throws {
        guard let identity = loadIdentity(),
              let toolchain = resolver().toolchain(at: identity.sdkRoot),
              verifyOwnership(identity, toolchain: toolchain) else {
            throw AppError.spider("Android 运行实例所有权校验失败")
        }

        ready = false
        _ = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "am", "force-stop",
                "com.okvideomac.dexbridge"
            ]
        )
        try configurePortForwards(identity, toolchain: toolchain)
        try startBridge(identity, toolchain: toolchain)
        for _ in 0..<20 {
            if await isHealthy(
                identity,
                toolchain: toolchain,
                acceptVersionMismatch: acceptsNewerBridge
            ) {
                ready = true
                lastNetworkCheck = Date()
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        // If Android discarded the installed package or Activity, the normal
        // preparation path reinstalls the bundled Release bridge.
        try await prepareRuntime()
    }

    private func prepareRuntime(
        forceInstall: Bool = false,
        retryKnownFailedNetworkCommand: Bool = true
    ) async throws {
        lastAttemptAt = Date()
        lastBootCompleted = nil
        lastBootWaitDuration = nil
        lastIPAddressOutput = nil
        lastIPRouteOutput = nil
        lastDefaultRoutePresent = nil
        lastWiFiStatus = nil
        networkRecoveryAttempted = false
        networkRecoverySecurityException = false
        networkRecoveryDuration = nil
        networkRecoveryResult = nil
        lastNetworkRecoveryCommand = nil
        connectivityProbeResult = nil
        probeStartedAt = nil
        probeRetryCount = 0
        probeHTTPStatus = nil
        probeErrorCategory = nil
        probeDuration = nil
        transition(to: .locatingSDK, event: "startup_requested")
        defer {
            if currentStage != .ready {
                operationStatus = nil
            }
        }
        var activeIdentity: AndroidRuntimeIdentity?
        var activeToolchain: AndroidToolchain?
        do {
            try Task.checkCancellation()
            try createRuntimeDirectories()

            if fileManager.fileExists(atPath: manifestURL.path) {
                guard let recorded = loadIdentity() else {
                    throw AppError.spider(
                        "Android 运行记录损坏；为避免误操作其他设备，已停止"
                    )
                }
                guard let recordedToolchain = resolver().toolchain(
                    at: recorded.sdkRoot
                ) else {
                    throw AppError.spider(
                        "原 Android SDK 已不可用，无法安全复用运行实例"
                    )
                }
                if verifyOwnership(recorded, toolchain: recordedToolchain) {
                    activeIdentity = recorded
                    activeToolchain = recordedToolchain
                } else if processExecutablePath(pid: recorded.pid) != nil
                            || deviceIsReachable(
                                recorded,
                                toolchain: recordedToolchain
                            ) {
                    throw AppError.spider(
                        "Android 实例身份与运行记录不一致；已拒绝继续操作"
                    )
                } else {
                    clearRuntimeRecord()
                }
            }

            let toolchain: AndroidToolchain
            var identity: AndroidRuntimeIdentity
            if let activeIdentity, let activeToolchain {
                identity = activeIdentity
                toolchain = activeToolchain
            } else {
                guard let resolved = resolver().resolve() else {
                    throw AppError.spider(
                        "未找到完整 Android SDK；请选择包含 adb 和 emulator 的 SDK"
                    )
                }
                toolchain = resolved
                lastObservedToolchain = toolchain
                transition(to: .preparingAVD)
                try ensureManagedAVD(toolchain)
                transition(to: .launchingEmulator)
                identity = try await launchManagedEmulator(toolchain)
                activeIdentity = identity
                activeToolchain = toolchain
            }
            lastObservedIdentity = identity
            lastObservedToolchain = toolchain

            transition(to: .waitingForADB)
            try await waitForOwnership(identity, toolchain: toolchain)
            transition(to: .waitingForAndroidBoot)
            try await waitForBoot(identity, toolchain: toolchain)
            try Task.checkCancellation()

            if forceInstall {
                identity.generation = UUID().uuidString
                try saveIdentity(identity)
                activeIdentity = identity
            }

            transition(to: .configuringPortForward)
            let installedVersionCode = installedBridgeVersionCode(
                identity,
                toolchain: toolchain
            )
            let hasNewerBridge = installedVersionCode.map {
                $0 > Self.bridgeVersionCode
            } ?? false
            try configurePortForwards(identity, toolchain: toolchain)

            transition(to: .checkingEmulatorNetwork)
            let networkWasRepaired: Bool
            if let lastNetworkCheck,
               Date().timeIntervalSince(lastNetworkCheck)
                    < Self.networkCheckInterval {
                networkWasRepaired = false
            } else {
                networkWasRepaired = try await ensureEmulatorNetwork(
                    identity,
                    toolchain: toolchain,
                    allowRecoveryCommand: retryKnownFailedNetworkCommand
                )
            }
            if !forceInstall, !networkWasRepaired,
               await isHealthy(
                    identity,
                    toolchain: toolchain,
                    acceptVersionMismatch: hasNewerBridge
               ) {
                ready = true
                acceptsNewerBridge = hasNewerBridge
                lastNetworkCheck = Date()
                lastFailure = nil
                lastSuccessfulStartAt = Date()
                transition(to: .ready, event: "existing_bridge_ready")
                return
            }

            transition(to: .installingBridge)
            let apk = try bridgeAPK()
            _ = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["install", "-r", apk.path],
                category: "adb.bridge.install",
                timeout: 120
            )
            transition(to: .launchingBridge)
            try startBridge(identity, toolchain: toolchain)
            transition(to: .probingBridge)
            for attempt in 0..<AndroidRuntimeRecoveryPolicy
                .initialBridgeProbeAttempts {
                try Task.checkCancellation()
                probeRetryCount = attempt + 1
                if await isHealthy(identity, toolchain: toolchain) {
                    ready = true
                    acceptsNewerBridge = false
                    lastNetworkCheck = Date()
                    lastFailure = nil
                    lastSuccessfulStartAt = Date()
                    transition(to: .ready, event: "bridge_ready")
                    return
                }
                try await Task.sleep(
                    nanoseconds: AndroidRuntimeRecoveryPolicy
                        .bridgeProbePollNanoseconds
                )
            }

            appendEvent(
                stage: .probingBridge,
                event: "bounded_bridge_recovery_started",
                detail: "reconfigure forwards and restart the owned Bridge once"
            )
            try configurePortForwards(identity, toolchain: toolchain)
            try startBridge(identity, toolchain: toolchain)
            for attempt in 0..<AndroidRuntimeRecoveryPolicy
                .recoveredBridgeProbeAttempts {
                try Task.checkCancellation()
                probeRetryCount = AndroidRuntimeRecoveryPolicy
                    .initialBridgeProbeAttempts + attempt + 1
                if await isHealthy(identity, toolchain: toolchain) {
                    ready = true
                    acceptsNewerBridge = false
                    lastNetworkCheck = Date()
                    lastFailure = nil
                    lastSuccessfulStartAt = Date()
                    transition(to: .ready, event: "bridge_recovered")
                    return
                }
                try await Task.sleep(
                    nanoseconds: AndroidRuntimeRecoveryPolicy
                        .bridgeProbePollNanoseconds
                )
            }
            throw AppError.spider("Java/Dex Android 桥启动超时（已执行一次有界恢复）")
        } catch {
            ready = false
            let failure = classifiedFailure(for: error)
            preserveFailure(failure)
            if let identity = activeIdentity,
               let toolchain = activeToolchain {
                let cleaned = await cleanupFailedRuntime(
                    identity,
                    toolchain: toolchain
                )
                if !cleaned {
                    appendEvent(
                        stage: failure.record.stage,
                        event: "cleanup_skipped_or_unconfirmed",
                        detail: "无法安全确认实例所有权；保留原始失败分类"
                    )
                }
            }
            throw failure
        }
    }

    private func configurePortForwards(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) throws {
        var listing = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["forward", "--list"],
            category: "adb.forward.list"
        )
        for forward in identity.forwards {
            if Self.portForwardExists(
                listing: listing,
                device: identity.serial,
                host: forward.hostPort,
                guest: forward.devicePort
            ) {
                continue
            }
            if Self.deviceHasHostForward(
                listing: listing,
                device: identity.serial,
                host: forward.hostPort
            ) {
                _ = try runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["forward", "--remove", "tcp:\(forward.hostPort)"],
                    category: "adb.forward.remove"
                )
            }
            _ = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                [
                    "forward", "tcp:\(forward.hostPort)",
                    "tcp:\(forward.devicePort)"
                ],
                category: "adb.forward.create"
            )
            listing = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["forward", "--list"],
                category: "adb.forward.list"
            )
            guard Self.portForwardExists(
                listing: listing,
                device: identity.serial,
                host: forward.hostPort,
                guest: forward.devicePort
            ) else {
                throw AppError.spider("Android Bridge 端口映射校验失败")
            }
        }
    }

    static func portForwardExists(
        listing: String,
        device: String,
        host: Int,
        guest: Int
    ) -> Bool {
        let expected = "\(device) tcp:\(host) tcp:\(guest)"
        return listing.split(whereSeparator: \.isNewline).contains {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                == expected
        }
    }

    static func deviceHasHostForward(
        listing: String,
        device: String,
        host: Int
    ) -> Bool {
        let prefix = "\(device) tcp:\(host) "
        return listing.split(whereSeparator: \.isNewline).contains {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(prefix)
        }
    }

    private func ensureEmulatorNetwork(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        allowRecoveryCommand: Bool
    ) async throws -> Bool {
        let unavailableSince = Date()
        if observeNetwork(identity, toolchain: toolchain) {
            lastNetworkCheck = Date()
            connectivityProbeResult = probeEmulatorGateway(
                identity,
                toolchain: toolchain
            )
            return false
        }

        networkRecoveryAttempted = true
        appendEvent(
            stage: .checkingEmulatorNetwork,
            event: "network_unavailable",
            detail: "bounded non-privileged recovery started"
        )
        if allowRecoveryCommand {
            do {
                _ = try runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    [
                        "shell", "cmd", "wifi",
                        "connect-network", "AndroidWifi", "open"
                    ],
                    category: "adb.network.wifi.connect",
                    timeout: 10
                )
                lastNetworkRecoveryCommand = recentCommands.last {
                    $0.category == "adb.network.wifi.connect"
                }
            } catch {
                lastNetworkRecoveryCommand = recentCommands.last {
                    $0.category == "adb.network.wifi.connect"
                }
                let text = error.localizedDescription
                networkRecoverySecurityException = Self.containsSecurityException(
                    text
                )
                networkRecoveryDuration = Date().timeIntervalSince(
                    unavailableSince
                )
                networkRecoveryResult = "command_failed"
                appendEvent(
                    stage: .checkingEmulatorNetwork,
                    event: "network_recovery_command_failed",
                    detail: text
                )
                throw error
            }
        } else {
            appendEvent(
                stage: .checkingEmulatorNetwork,
                event: "known_failed_recovery_command_skipped",
                detail: "Repair performs bounded observation without repeating the failed command"
            )
        }

        let deadline = Date().addingTimeInterval(
            AndroidRuntimeRecoveryPolicy.networkObservationTimeout
        )
        while Date() < deadline {
            try Task.checkCancellation()
            if observeNetwork(identity, toolchain: toolchain) {
                lastNetworkCheck = Date()
                networkRecoveryDuration = Date().timeIntervalSince(
                    unavailableSince
                )
                networkRecoveryResult = "available"
                connectivityProbeResult = probeEmulatorGateway(
                    identity,
                    toolchain: toolchain
                )
                appendEvent(
                    stage: .checkingEmulatorNetwork,
                    event: "network_available_after_recovery",
                    detail: connectivityProbeResult
                )
                return true
            }
            try await Task.sleep(
                nanoseconds: AndroidRuntimeRecoveryPolicy.networkPollNanoseconds
            )
        }
        networkRecoveryDuration = Date().timeIntervalSince(unavailableSince)
        networkRecoveryResult = "timed_out"
        connectivityProbeResult = "default_route_unavailable"
        throw AppError.spider("Java/Dex Android 运行时网络连接失败，请稍后重试")
    }

    private func observeNetwork(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        let addresses = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "ip", "addr"],
            category: "adb.network.ip_addr",
            timeout: 3
        )
        let routes = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "ip", "route", "show", "table", "all"],
            category: "adb.network.ip_route",
            timeout: 3
        )
        let status = (try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "cmd", "wifi", "status"],
            category: "adb.network.wifi.status",
            timeout: 3
        )) ?? "<wifi-status-unavailable>"
        lastIPAddressOutput = addresses.map(LogRedactor.text)
        lastIPRouteOutput = routes.map(LogRedactor.text)
        lastWiFiStatus = LogRedactor.text(status)
        lastDefaultRoutePresent = routes.map(Self.hasUsableDefaultRoute)
        guard let routes else { return false }
        return Self.networkLooksReady(status: status, routes: routes)
    }

    static func networkLooksReady(status: String, routes: String) -> Bool {
        // Wi-Fi status is retained for diagnostics, but Ethernet/VPN-capable
        // system images are ready when they have a real gateway route.
        hasUsableDefaultRoute(routes)
    }

    static func hasUsableDefaultRoute(_ routes: String) -> Bool {
        routes.split(whereSeparator: \.isNewline).contains { line in
            let value = String(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return value.hasPrefix("default ")
                && value.contains(" via ")
                && !value.contains(" dev dummy")
        }
    }

    static func containsSecurityException(_ output: String) -> Bool {
        output.range(of: "SecurityException", options: .caseInsensitive) != nil
    }

    private func probeEmulatorGateway(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> String {
        guard let routes = lastIPRouteOutput,
              let gateway = Self.defaultGateway(from: routes) else {
            return "default_route_missing"
        }
        do {
            _ = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["shell", "ping", "-c", "1", "-W", "2", gateway],
                category: "adb.network.gateway_probe",
                timeout: 5
            )
            return "gateway_reachable"
        } catch {
            return "default_route_available_gateway_probe_failed"
        }
    }

    static func defaultGateway(from routes: String) -> String? {
        for line in routes.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.first == "default",
                  let via = parts.firstIndex(of: "via"),
                  parts.indices.contains(via + 1) else { continue }
            return parts[via + 1]
        }
        return nil
    }

    private func waitForBoot(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) async throws {
        let startedAt = Date()
        for _ in 0..<240 {
            try Task.checkCancellation()
            if let value = try? runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["shell", "getprop", "sys.boot_completed"],
                category: "adb.boot.sys_boot_completed"
            ), value.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                lastBootCompleted = true
                lastBootWaitDuration = Date().timeIntervalSince(startedAt)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        lastBootCompleted = false
        lastBootWaitDuration = Date().timeIntervalSince(startedAt)
        throw AppError.spider("Java/Dex Android 运行时启动超过 240 秒")
    }

    private func bridgeAPK() throws -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("AndroidDexBridge-release.apk")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        throw AppError.spider(
            "应用包缺少 AndroidDexBridge-release.apk，请重新构建 OKVideoMac"
        )
    }

    private func installedBridgeVersionCode(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Int? {
        guard let output = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "dumpsys", "package",
                "com.okvideomac.dexbridge"
            ]
        ) else { return nil }
        return Self.installedVersionCode(from: output)
    }

    static func installedVersionCode(from packageDump: String) -> Int? {
        guard let marker = packageDump.range(of: "versionCode=") else {
            return nil
        }
        let suffix = packageDump[marker.upperBound...]
        let digits = suffix.prefix(while: \.isNumber)
        return Int(digits)
    }

    private func isHealthy(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        acceptVersionMismatch: Bool = false
    ) async -> Bool {
        if probeStartedAt == nil {
            probeStartedAt = Date()
        }
        guard verifyOwnership(identity, toolchain: toolchain) else {
            probeErrorCategory = "ownership_mismatch"
            return false
        }
        guard let url = URL(
            string: "http://127.0.0.1:\(BridgeServerPort.host)/health"
        ) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let (data, response) = try await URLSession(
                configuration: configuration
            ).data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            probeHTTPStatus = statusCode
            probeDuration = probeStartedAt.map {
                Date().timeIntervalSince($0)
            }
            guard statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                probeErrorCategory = "invalid_http_response"
                return false
            }
            let matches = Self.healthMatches(
                object,
                generation: identity.generation,
                acceptVersionMismatch: acceptVersionMismatch
            )
            probeErrorCategory = matches ? nil : "identity_or_version_mismatch"
            return matches
        } catch {
            probeDuration = probeStartedAt.map {
                Date().timeIntervalSince($0)
            }
            if let urlError = error as? URLError {
                probeErrorCategory = "url_error_\(urlError.code.rawValue)"
            } else {
                probeErrorCategory = "transport_error"
            }
            return false
        }
    }

    static func healthMatches(
        _ object: [String: Any],
        generation: String,
        acceptVersionMismatch: Bool = false
    ) -> Bool {
        object["ok"] as? Bool == true
            && object["generation"] as? String == generation
            && (
                object["version"] as? String == bridgeVersion
                    || acceptVersionMismatch
            )
    }

    static func avdName(from emulatorConsoleOutput: String) -> String? {
        emulatorConsoleOutput.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    static func commandMatches(
        _ command: String,
        avdName: String,
        consolePort: Int
    ) -> Bool {
        let hasAVD = command.contains("-avd \(avdName)")
            || command.contains("@\(avdName)")
        let hasPort = command.contains("-port \(consolePort)")
            || command.contains("-ports \(consolePort),")
        return hasAVD && hasPort
    }

    static func isEmulatorPortConflict(_ output: String) -> Bool {
        let text = output.lowercased()
        let mentionsPort = text.contains("port") || text.contains("socket")
        let mentionsConflict = text.contains("already in use")
            || text.contains("address in use")
            || text.contains("cannot bind")
            || text.contains("failed to bind")
            || text.contains("used by another")
        return mentionsPort && mentionsConflict
    }

    static func ownershipAllowsMutation(
        processOwned: Bool,
        deviceOwned: Bool
    ) -> Bool {
        processOwned && deviceOwned
    }

    private func resolver() -> AndroidToolchainResolver {
        AndroidToolchainResolver(
            applicationSupportDirectory: applicationSupportDirectory,
            homeDirectory: homeDirectory,
            environment: baseEnvironment,
            userSelectedSDKRoot: userSelectedSDKRoot,
            fileManager: fileManager
        )
    }

    private func createRuntimeDirectories() throws {
        for directory in [runtimeDirectory, avdHome] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    private func childEnvironment(
        for toolchain: AndroidToolchain
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["ANDROID_HOME"] = toolchain.sdkRoot.path
        environment.removeValue(forKey: "ANDROID_SDK_ROOT")
        environment["ANDROID_AVD_HOME"] = avdHome.path
        return environment
    }

    private func ensureManagedAVD(_ toolchain: AndroidToolchain) throws {
        try createRuntimeDirectories()
        let configuration = avdDirectory.appendingPathComponent("config.ini")
        if fileManager.fileExists(atPath: configuration.path) {
            let listing = try run(
                toolchain.emulator,
                ["-list-avds"],
                environment: childEnvironment(for: toolchain)
            )
            guard listing.split(whereSeparator: \.isNewline).contains(
                where: {
                    String($0).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == Self.avdName
                }
            ) else {
                throw AppError.spider(
                    "专用 Android 环境记录不完整，需要重新初始化"
                )
            }
            return
        }
        if fileManager.fileExists(atPath: avdDirectory.path) {
            throw AppError.spider(
                "专用 AVD 目录不完整；为避免覆盖现有数据，已停止"
            )
        }
        guard let avdManager = toolchain.avdManager else {
            throw AppError.spider(
                "缺少 Android SDK Command-line Tools（avdmanager）"
            )
        }
        guard let image = resolver().installedSystemImages(in: toolchain).first else {
            throw AppError.spider(
                "缺少可用的 arm64 Android system image；本版本不会自动下载"
            )
        }
        _ = try run(
            avdManager,
            [
                "create", "avd",
                "-n", Self.avdName,
                "-k", image.packageID,
                "-p", avdDirectory.path
            ],
            environment: childEnvironment(for: toolchain),
            input: Data("no\n".utf8)
        )
        guard fileManager.fileExists(atPath: configuration.path) else {
            throw AppError.spider("专用 Android 环境创建失败")
        }
        let listing = try run(
            toolchain.emulator,
            ["-list-avds"],
            environment: childEnvironment(for: toolchain)
        )
        guard Self.avdName(from: listing) == Self.avdName
            || listing.split(whereSeparator: \.isNewline).contains(
                where: {
                    String($0).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == Self.avdName
                }
            ) else {
            throw AppError.spider("专用 Android 环境无法被 Emulator 识别")
        }
    }

    private func launchManagedEmulator(
        _ toolchain: AndroidToolchain
    ) async throws -> AndroidRuntimeIdentity {
        let generation = UUID().uuidString
        for consolePort in Self.candidateConsolePorts {
            try Task.checkCancellation()
            let logURL = runtimeDirectory.appendingPathComponent(
                "emulator-\(generation)-\(consolePort).log"
            )
            _ = fileManager.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = toolchain.emulator
            process.arguments = [
                "-avd", Self.avdName,
                "-port", "\(consolePort)",
                "-no-window",
                "-no-audio",
                "-no-boot-anim",
                "-no-metrics",
                "-no-snapshot",
                "-gpu", "off",
                "-accel", "on"
            ]
            process.environment = childEnvironment(for: toolchain)
            process.standardOutput = log
            process.standardError = log
            do {
                try process.run()
            } catch {
                try? log.close()
                throw error
            }
            for _ in 0..<20 where process.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if !process.isRunning {
                try? log.close()
                let output = (
                    try? String(contentsOf: logURL, encoding: .utf8)
                ) ?? ""
                if Self.isEmulatorPortConflict(output) {
                    continue
                }
                throw AppError.spider(
                    "Android Emulator 启动失败："
                        + String(output.suffix(1_000))
                )
            }

            emulatorProcess = process
            emulatorLogHandle = log
            let identity = AndroidRuntimeIdentity(
                schema: Self.manifestSchema,
                generation: generation,
                sdkRoot: toolchain.sdkRoot,
                emulatorExecutable: toolchain.emulator,
                avdName: Self.avdName,
                avdDirectory: avdDirectory,
                pid: process.processIdentifier,
                consolePort: consolePort,
                serial: "emulator-\(consolePort)",
                forwards: Self.expectedForwards,
                launchedAt: Date()
            )
            try saveIdentity(identity)
            return identity
        }
        throw AppError.spider("没有可用的 Android Emulator console port")
    }

    private func waitForOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard verifyProcessOwnership(identity, toolchain: toolchain) else {
                throw AppError.spider(
                    "Android Emulator 进程身份校验失败；已拒绝继续操作"
                )
            }
            if verifyDeviceOwnership(identity, toolchain: toolchain) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AppError.spider("等待专用 Android Emulator 设备身份超时")
    }

    private func verifyOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        Self.ownershipAllowsMutation(
            processOwned: verifyProcessOwnership(
                identity,
                toolchain: toolchain
            ),
            deviceOwned: verifyDeviceOwnership(
                identity,
                toolchain: toolchain
            )
        )
    }

    private func verifyProcessOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        guard identity.schema == Self.manifestSchema,
              identity.avdName == Self.avdName,
              identity.avdDirectory.standardizedFileURL
                == avdDirectory.standardizedFileURL,
              identity.serial == "emulator-\(identity.consolePort)",
              Self.candidateConsolePorts.contains(identity.consolePort),
              identity.emulatorExecutable.standardizedFileURL
                == toolchain.emulator.standardizedFileURL,
              let executablePath = processExecutablePath(pid: identity.pid)
        else { return false }

        let executable = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let emulatorRoot = toolchain.sdkRoot
            .appendingPathComponent("emulator", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard executable == toolchain.emulator.standardizedFileURL
                .resolvingSymlinksInPath()
                || executable.path.hasPrefix(emulatorRoot),
              let command = try? run(
                URL(fileURLWithPath: "/bin/ps"),
                ["-p", "\(identity.pid)", "-o", "command="]
              ),
              Self.commandMatches(
                command,
                avdName: identity.avdName,
                consolePort: identity.consolePort
              ) else { return false }
        return true
    }

    private func verifyDeviceOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        guard let state = try? run(
            toolchain.adb,
            ["-s", identity.serial, "get-state"]
        ), state.trimmingCharacters(in: .whitespacesAndNewlines) == "device",
        let avdOutput = try? run(
            toolchain.adb,
            ["-s", identity.serial, "emu", "avd", "name"]
        ), Self.avdName(from: avdOutput) == identity.avdName else {
            return false
        }
        return true
    }

    private func runVerifiedADB(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        _ arguments: [String],
        category: String = "adb.command",
        timeout: TimeInterval = 30
    ) throws -> String {
        guard verifyOwnership(identity, toolchain: toolchain) else {
            throw AppError.spider(
                "Android 运行实例所有权校验失败，已拒绝执行 ADB 操作"
            )
        }
        return try run(
            toolchain.adb,
            ["-s", identity.serial] + arguments,
            category: category,
            timeout: timeout
        )
    }

    private func deviceIsReachable(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain?
    ) -> Bool {
        guard let toolchain,
              let state = try? run(
                toolchain.adb,
                ["-s", identity.serial, "get-state"]
              ) else { return false }
        return state.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    private func processExecutablePath(pid: Int32) -> String? {
        let capacity = 4_096
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func startBridge(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) throws {
        lastBridgeComponentStartResult = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "am", "start",
                "-n", "com.okvideomac.dexbridge/.BridgeActivity",
                "--es", "okvideomac_runtime_generation", identity.generation
            ],
            category: "adb.bridge.start"
        )
    }

    private func removeOwnedPortForwards(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) throws {
        var listing = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["forward", "--list"]
        )
        for forward in identity.forwards where Self.portForwardExists(
            listing: listing,
            device: identity.serial,
            host: forward.hostPort,
            guest: forward.devicePort
        ) {
            _ = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["forward", "--remove", "tcp:\(forward.hostPort)"]
            )
            listing = try runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["forward", "--list"]
            )
        }
    }

    private func cleanupFailedRuntime(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) async -> Bool {
        guard verifyOwnership(identity, toolchain: toolchain) else {
            return false
        }
        try? removeOwnedPortForwards(identity, toolchain: toolchain)
        _ = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["emu", "kill"]
        )
        for _ in 0..<40 {
            if processExecutablePath(pid: identity.pid) == nil,
               !deviceIsReachable(identity, toolchain: toolchain) {
                clearRuntimeRecord()
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if verifyProcessOwnership(identity, toolchain: toolchain) {
            _ = Darwin.kill(identity.pid, SIGTERM)
        }
        for _ in 0..<20 {
            if processExecutablePath(pid: identity.pid) == nil {
                clearRuntimeRecord()
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func loadIdentity() -> AndroidRuntimeIdentity? {
        guard let data = try? Data(contentsOf: manifestURL),
              let identity = try? JSONDecoder().decode(
                AndroidRuntimeIdentity.self,
                from: data
              ),
              identity.schema == Self.manifestSchema,
              identity.avdName == Self.avdName,
              identity.avdDirectory.standardizedFileURL
                == avdDirectory.standardizedFileURL,
              identity.serial == "emulator-\(identity.consolePort)",
              identity.forwards == Self.expectedForwards,
              !identity.generation.isEmpty else { return nil }
        return identity
    }

    private func saveIdentity(_ identity: AndroidRuntimeIdentity) throws {
        try createRuntimeDirectories()
        let data = try JSONEncoder().encode(identity)
        try data.write(to: manifestURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    private func clearRuntimeRecord() {
        try? emulatorLogHandle?.close()
        emulatorLogHandle = nil
        emulatorProcess = nil
        if fileManager.fileExists(atPath: manifestURL.path) {
            try? fileManager.removeItem(at: manifestURL)
        }
    }

    private static let expectedForwards = [
        AndroidPortForwardIdentity(
            hostPort: BridgeServerPort.host,
            devicePort: BridgeServerPort.guest
        ),
        AndroidPortForwardIdentity(
            hostPort: BridgeServerPort.kaiserHost,
            devicePort: BridgeServerPort.kaiserGuest
        ),
        AndroidPortForwardIdentity(
            hostPort: BridgeServerPort.cloudFileHost,
            devicePort: BridgeServerPort.cloudFileGuest
        )
    ]

    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        category: String = "android.tool",
        timeout: TimeInterval = 30
    ) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        let startedAt = Date()
        do {
            try process.run()
        } catch {
            let duration = Date().timeIntervalSince(startedAt)
            recordCommand(
                timestamp: startedAt,
                category: category,
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                duration: duration,
                timedOut: false
            )
            throw error
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let waitResult = completed.wait(timeout: .now() + timeout)
        let timedOut = waitResult == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        let stdoutData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let stderrData = standardError.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startedAt)
        let exitCode: Int32 = timedOut ? -1 : process.terminationStatus
        recordCommand(
            timestamp: startedAt,
            category: category,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            duration: duration,
            timedOut: timedOut
        )
        if Self.containsSecurityException(stdout + "\n" + stderr) {
            networkRecoverySecurityException = true
        }
        guard !timedOut, exitCode == 0 else {
            let safeStdout = sanitizedCommandOutput(
                stdout,
                category: category
            )
            let safeStderr = sanitizedCommandOutput(
                stderr,
                category: category
            )
            throw AndroidToolCommandError(
                category: category,
                exitCode: exitCode,
                stdout: safeStdout,
                stderr: safeStderr,
                duration: duration,
                timedOut: timedOut
            )
        }
        return stdout
    }

    private func recordCommand(
        timestamp: Date,
        category: String,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        duration: TimeInterval,
        timedOut: Bool
    ) {
        let isDiagnosticEvidence = category.hasPrefix("diagnostic.")
            || category.hasPrefix("adb.network.")
            || category.hasPrefix("adb.boot.")
            || category.hasPrefix("adb.bridge.")
            || category.hasPrefix("adb.forward.")
        guard isDiagnosticEvidence else { return }
        let safeStdout = sanitizedCommandOutput(stdout, category: category)
        let safeStderr = sanitizedCommandOutput(stderr, category: category)
        recentCommands.append(
            AndroidRuntimeCommandRecord(
                timestamp: timestamp,
                category: category,
                command: Self.safeCommandDescription(for: category),
                exitCode: exitCode,
                stdout: String(safeStdout.prefix(4_000)),
                stderr: String(safeStderr.prefix(4_000)),
                duration: duration,
                timedOut: timedOut
            )
        )
        if recentCommands.count > 40 {
            recentCommands.removeFirst(recentCommands.count - 40)
        }
    }

    private static func safeCommandDescription(for category: String) -> String {
        switch category {
        case "adb.network.wifi.connect":
            return "adb -s <owned-serial> shell cmd wifi connect-network AndroidWifi open"
        case "adb.network.wifi.status":
            return "adb -s <owned-serial> shell cmd wifi status"
        case "adb.network.ip_addr":
            return "adb -s <owned-serial> shell ip addr"
        case "adb.network.ip_route":
            return "adb -s <owned-serial> shell ip route show table all"
        case "adb.network.gateway_probe":
            return "adb -s <owned-serial> shell ping <default-gateway>"
        case "adb.boot.sys_boot_completed",
             "diagnostic.android.boot_completed":
            return "adb -s <owned-serial> shell getprop sys.boot_completed"
        case "diagnostic.adb.get_state":
            return "adb -s <owned-serial> get-state"
        default:
            return category
        }
    }

    private func sanitizedCommandOutput(
        _ output: String,
        category: String
    ) -> String {
        if category == "diagnostic.adb.devices" {
            return Self.sanitizedADBDevices(
                output,
                ownedSerial: lastObservedIdentity?.serial
            ).joined(separator: "\n")
        }
        if category == "diagnostic.adb.forwards"
            || category.hasPrefix("adb.forward.") {
            guard let serial = lastObservedIdentity?.serial else { return "" }
            return Self.sanitizedADBForwards(
                output,
                ownedSerial: serial
            ).joined(separator: "\n")
        }
        var safe = LogRedactor.text(output)
        if let sdkRoot = lastObservedToolchain?.sdkRoot.path {
            safe = safe.replacingOccurrences(
                of: sdkRoot,
                with: "<sdk-root>"
            )
        }
        safe = safe.replacingOccurrences(
            of: applicationSupportDirectory.path,
            with: "<app-support>"
        )
        return safe
    }
}

private enum BridgeServerPort {
    static let guest = 9_978
    static let host = 19_978
    static let kaiserGuest = 8_096
    static let kaiserHost = 18_096
    static let cloudFileGuest = 6_677
    static let cloudFileHost = 16_677
}

private extension JSONValue {
    var nonEmptySpiderValue: JSONValue? {
        if case .string(let value) = self,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if self == .null { return nil }
        return self
    }
}
