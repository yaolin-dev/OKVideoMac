import AppKit
import AndroidRuntimeKit
import CryptoKit
import Foundation
import os
import OKVideoCore
import OKVideoPersistence

/// Request-scoped, behavior-neutral timing used to audit CatPaw detail loads.
/// All timestamps come from the monotonic system uptime clock so wall-clock
/// changes cannot distort a single trace.
final class DetailPerformanceTrace: @unchecked Sendable {
    enum Stage: String, Hashable {
        case tap
        case providerStart
        case runtimeReady
        case moduleReady
        case detailRequest
        case nodeResult
        case selectedDetail
        case firstRender
    }

    struct StageSample {
        let uptimeNanoseconds: UInt64
        let executionContext: String
    }

    let id = UUID().uuidString.lowercased()
    let title: String
    let siteKey: String
    let videoID: String

    private let lock = NSLock()
    private var stages: [Stage: StageSample] = [:]
    private var runtimeWasAlreadyReady: Bool?
    private var moduleWasAlreadyInitialized: Bool?
    private var searchActiveAtTap: Bool
    private var searchActiveAtProviderStart: Bool?
    private var searchActiveAtPublish: Bool?
    private var authorizationWaitNanoseconds: UInt64 = 0
    private var authorizationWaitCount = 0
    private var historyBuildNanoseconds: UInt64 = 0
    private var playSourceCount = 0
    private var episodeCount = 0
    private var generatedHistoryIdentityCount = 0
    private var detailRequestAttemptCount = 0
    private var nodeStatusCodes: [Int] = []
    private var nodeInvocationIDs: [String] = []
    private var didFinish = false
    private var requestFinished = false
    private var cacheHit = false
    private static let logger = Logger(subsystem: "com.okvideomac.OKVideoMac", category: "DetailLoading")
    private static let points = OSLog(subsystem: "com.okvideomac.OKVideoMac", category: .pointsOfInterest)
    private let signpostID = OSSignpostID(log: DetailPerformanceTrace.points)

    init(
        title: String,
        siteKey: String,
        videoID: String,
        searchActiveAtTap: Bool
    ) {
        self.title = title
        self.siteKey = siteKey
        self.videoID = videoID
        self.searchActiveAtTap = searchActiveAtTap
        stages[.tap] = Self.sample()
        os_signpost(.begin, log: Self.points, name: "DetailLoad", signpostID: signpostID)
    }

    func markProviderStart(searchActive: Bool) {
        withLock {
            searchActiveAtProviderStart = searchActive
            record(.providerStart)
        }
    }

    func recordRuntimeWasAlreadyReady(_ value: Bool) {
        withLock { runtimeWasAlreadyReady = value }
    }

    func markRuntimeReady() {
        withLock { record(.runtimeReady) }
    }

    func markModuleReady(wasAlreadyInitialized: Bool) {
        withLock {
            moduleWasAlreadyInitialized = wasAlreadyInitialized
            record(.moduleReady)
        }
    }

    func markDetailRequest(invocationID: String) {
        withLock {
            detailRequestAttemptCount += 1
            nodeInvocationIDs.append(invocationID)
            record(.detailRequest)
        }
    }

    func markNodeResult(statusCode: Int) {
        withLock {
            nodeStatusCodes.append(statusCode)
            stages[.nodeResult] = Self.sample()
        }
    }

    func beginAuthorizationWait() -> UInt64 {
        let start = Self.now()
        withLock { authorizationWaitCount += 1 }
        return start
    }

    func endAuthorizationWait(startedAt: UInt64) {
        let elapsed = Self.now() &- startedAt
        withLock { authorizationWaitNanoseconds &+= elapsed }
    }

    func beginHistoryBuild(
        playSourceCount: Int,
        episodeCount: Int
    ) -> UInt64 {
        let start = Self.now()
        withLock {
            self.playSourceCount = playSourceCount
            self.episodeCount = episodeCount
        }
        return start
    }

    func endHistoryBuild(
        startedAt: UInt64,
        generatedIdentityCount: Int
    ) {
        let elapsed = Self.now() &- startedAt
        withLock {
            historyBuildNanoseconds &+= elapsed
            generatedHistoryIdentityCount = generatedIdentityCount
        }
    }

    func markSelectedDetail(searchActive: Bool) {
        withLock {
            searchActiveAtPublish = searchActive
            record(.selectedDetail)
        }
    }

    func finishFirstRender() {
        let report: String? = withLock {
            guard !didFinish else { return nil }
            didFinish = true
            record(.firstRender)
            return makeReport()
        }
        if let report { Self.logger.info("\(report, privacy: .public)") }
    }

    func markCacheHit() { withLock { cacheHit = true } }

    func recordHTTPMetrics(_ timing: HTTPTaskTiming) {
        Self.logger.info("DetailNetwork id=\(self.id, privacy: .public) total_ms=\(timing.total * 1000) dns_ms=\(timing.dns * 1000) connect_ms=\(timing.connect * 1000) tls_ms=\(timing.tls * 1000) first_byte_ms=\(timing.firstByte * 1000) transfer_ms=\(timing.transfer * 1000) transactions=\(timing.transactions) redirects=\(timing.redirects)")
    }

    /// Request completion is recorded even when a page is never mounted.
    /// firstRender remains a separate mount observation, not a frame timestamp.
    func finishRequest(outcome: String) {
        let report: String? = withLock {
            guard !requestFinished else { return nil }
            requestFinished = true
            let elapsed = stages[.tap].map { Self.now() &- $0.uptimeNanoseconds } ?? 0
            return "DetailRequest id=\(id) outcome=\(outcome) cacheHit=\(cacheHit) elapsed_ms=\(Self.milliseconds(elapsed))\n\(makeReport())"
        }
        guard let report else { return }
        os_signpost(.end, log: Self.points, name: "DetailLoad", signpostID: signpostID)
        Self.logger.info("\(report, privacy: .public)")
    }

    private func makeReport() -> String {
        func value(_ start: Stage, _ end: Stage) -> String {
            guard let startValue = stages[start]?.uptimeNanoseconds,
                  let endValue = stages[end]?.uptimeNanoseconds,
                  endValue >= startValue else { return "n/a" }
            return Self.milliseconds(endValue - startValue)
        }

        let contexts = Stage.allCasesForReport.compactMap { stage -> String? in
            guard let context = stages[stage]?.executionContext else { return nil }
            return "\(stage.rawValue)=\(context)"
        }.joined(separator: ",")
        let statusCodes = nodeStatusCodes.map(String.init).joined(separator: ",")
        let invocationIDs = nodeInvocationIDs.joined(separator: ",")
        return [
            "DetailPerf id=\(id)",
            "DetailPerf id=\(id) tap -> providerStart: \(value(.tap, .providerStart)) ms",
            "DetailPerf id=\(id) providerStart -> runtimeReady: \(value(.providerStart, .runtimeReady)) ms",
            "DetailPerf id=\(id) runtimeReady -> moduleReady: \(value(.runtimeReady, .moduleReady)) ms",
            "DetailPerf id=\(id) moduleReady -> detailRequest: \(value(.moduleReady, .detailRequest)) ms",
            "DetailPerf id=\(id) detailRequest -> nodeResult: \(value(.detailRequest, .nodeResult)) ms",
            "DetailPerf id=\(id) authWait: \(Self.milliseconds(authorizationWaitNanoseconds)) ms count=\(authorizationWaitCount)",
            "DetailPerf id=\(id) historyBuild: \(Self.milliseconds(historyBuildNanoseconds)) ms",
            "DetailPerf id=\(id) nodeResult -> selectedDetail: \(value(.nodeResult, .selectedDetail)) ms",
            "DetailPerf id=\(id) selectedDetail -> firstRender: \(value(.selectedDetail, .firstRender)) ms",
            "DetailPerf id=\(id) total tap -> firstRender: \(value(.tap, .firstRender)) ms",
            "DetailPerf id=\(id) sources=\(playSourceCount) episodes=\(episodeCount) historyIdentities=\(generatedHistoryIdentityCount)",
            "DetailPerf id=\(id) runtimeAlreadyReady=\(Self.optionalBoolean(runtimeWasAlreadyReady)) moduleAlreadyInitialized=\(Self.optionalBoolean(moduleWasAlreadyInitialized)) searchActiveAtTap=\(searchActiveAtTap) searchActiveAtProviderStart=\(Self.optionalBoolean(searchActiveAtProviderStart)) searchActiveAtPublish=\(Self.optionalBoolean(searchActiveAtPublish))",
            "DetailPerf id=\(id) detailAttempts=\(detailRequestAttemptCount) nodeStatusCodes=\(statusCodes.isEmpty ? "none" : statusCodes) nodeInvocationIDs=\(invocationIDs.isEmpty ? "none" : invocationIDs)",
            "DetailPerf id=\(id) executionContexts=\(contexts)"
        ].joined(separator: "\n")
    }

    private func record(_ stage: Stage) {
        if stages[stage] == nil {
            stages[stage] = Self.sample()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func sample() -> StageSample {
        StageSample(
            uptimeNanoseconds: now(),
            executionContext: Thread.isMainThread ? "main" : "background"
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func optionalBoolean(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }
}

private extension DetailPerformanceTrace.Stage {
    static let allCasesForReport: [Self] = [
        .tap,
        .providerStart,
        .runtimeReady,
        .moduleReady,
        .detailRequest,
        .nodeResult,
        .selectedDetail,
        .firstRender
    ]
}

enum DetailPerformanceContext {
    @TaskLocal static var current: DetailPerformanceTrace?
}

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case live
    case favorites
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.string(.sectionBrowse)
        case .live: return L10n.string(.sectionLiveTV)
        case .favorites: return L10n.string(.sectionFavorites)
        case .history: return L10n.string(.sectionHistory)
        case .settings: return L10n.string(.sectionSettings)
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .live: return "dot.radiowaves.left.and.right"
        case .favorites: return "star"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

enum SidebarSearchKind: Equatable {
    case video
    case liveChannels
}

struct SidebarSearchPresentation: Equatable {
    let kind: SidebarSearchKind
    let placeholder: String
    let accessibilityLabel: String
    let help: String
}

enum SidebarSearchPresentationPolicy {
    static func presentation(for section: AppSection) -> SidebarSearchPresentation {
        switch section {
        case .live:
            return SidebarSearchPresentation(
                kind: .liveChannels,
                placeholder: L10n.string(
                    "sidebar.search.live.placeholder",
                    fallback: "Search channels…"
                ),
                accessibilityLabel: L10n.string(
                    "sidebar.search.live.accessibility",
                    fallback: "Search live TV channels"
                ),
                help: L10n.string(
                    "sidebar.search.live.help",
                    fallback: "Filter channels in the current live TV source"
                )
            )
        case .home, .favorites, .history, .settings:
            return SidebarSearchPresentation(
                kind: .video,
                placeholder: L10n.string(
                    "sidebar.search.video.placeholder",
                    fallback: "Search videos…"
                ),
                accessibilityLabel: L10n.string(
                    "sidebar.search.video.accessibility",
                    fallback: "Search videos"
                ),
                help: L10n.string(
                    "sidebar.search.video.help",
                    fallback: "Search all providers in the current configuration"
                )
            )
        }
    }
}

enum ShortcutWindowContext: Equatable {
    case browser
    case player
    case other
}

enum ShortcutRoutePolicy {
    static func context(
        browserWindowIsKey: Bool,
        playerWindowIsKey: Bool
    ) -> ShortcutWindowContext {
        if playerWindowIsKey { return .player }
        if browserWindowIsKey { return .browser }
        return .other
    }

    static func allowsBrowserCommands(
        browserWindowIsKey: Bool,
        playerWindowIsKey: Bool
    ) -> Bool {
        context(
            browserWindowIsKey: browserWindowIsKey,
            playerWindowIsKey: playerWindowIsKey
        ) == .browser
    }

    static func allowsPlayerCommands(
        browserWindowIsKey: Bool,
        playerWindowIsKey: Bool
    ) -> Bool {
        context(
            browserWindowIsKey: browserWindowIsKey,
            playerWindowIsKey: playerWindowIsKey
        ) == .player
    }
}

enum BrowserEscapeAction: Equatable {
    case none
    case dismissDetail
    case navigateBackFolder
    case stopSearch
    case returnHome
}

enum BrowserEscapeRoutePolicy {
    static func action(
        isHomeSearchPresented: Bool,
        isSearching: Bool,
        hasSearchFolder: Bool,
        hasDetailPresentation: Bool,
        hasBlockingPresentation: Bool
    ) -> BrowserEscapeAction {
        guard !hasBlockingPresentation else {
            return .none
        }
        if hasDetailPresentation {
            return .dismissDetail
        }
        if hasSearchFolder {
            return .navigateBackFolder
        }
        guard isHomeSearchPresented else { return .none }
        return isSearching ? .stopSearch : .returnHome
    }
}

struct ShortcutLiveSourceSelection: Equatable {
    let requestID: UUID
    let sourceID: LiveSourceID
}

/// Keeps high-frequency page navigation separate from the much larger app
/// content model. Publishing section changes through `AppState` used to
/// invalidate every view holding that environment object, including all live
/// channel cards, immediately before those cards were removed from screen.
struct NavigationSelection: Equatable {
    let section: AppSection
    let revision: UInt64
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published private(set) var selection = NavigationSelection(section: .home, revision: 0)
    var selectedSection: AppSection {
        get { selection.section }
        set { select(newValue) }
    }

    @discardableResult
    func select(_ section: AppSection) -> NavigationSelection {
        guard selection.section != section else { return selection }
        selection = NavigationSelection(section: section, revision: selection.revision + 1)
        return selection
    }
}

/// Settings navigation is presentation state. Keeping it out of AppState's
/// publisher prevents a pane click from rebuilding browser grids and live
/// channel cards that are about to leave the hierarchy.
@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published private(set) var selectedPane: SettingsPane = .general

    func select(_ pane: SettingsPane) {
        guard selectedPane != pane else { return }
        selectedPane = pane
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case configurations
    case search
    case liveSources
    case playback
    case cache
    case backup
    case advanced

    var id: String { rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.string(.themeSystem)
        case .light: return L10n.string(.themeLight)
        case .dark: return L10n.string(.themeDark)
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case Self.system.rawValue, "跟随系统": self = .system
        case Self.light.rawValue, "浅色": self = .light
        case Self.dark.rawValue, "深色": self = .dark
        default: return nil
        }
    }
}

enum UserFacingErrorTarget: String, Equatable, Sendable {
    case browser
    case player
}

struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let target: UserFacingErrorTarget

    init(
        title: String,
        message: String,
        target: UserFacingErrorTarget = .browser
    ) {
        self.title = title
        self.message = message
        self.target = target
    }

    static func == (lhs: UserFacingError, rhs: UserFacingError) -> Bool {
        lhs.id == rhs.id
    }
}

enum PlayerWindowActivationPolicy: Equatable {
    case userInitiated
    case preserveFocus
}

enum AppWindowLayoutTarget: String, Equatable, Sendable {
    case mainWindow
    case playerWindow
}

struct AppWindowLayoutCommand: Identifiable, Equatable, Sendable {
    let id: UUID
    let target: AppWindowLayoutTarget

    init(
        id: UUID = UUID(),
        target: AppWindowLayoutTarget
    ) {
        self.id = id
        self.target = target
    }
}

enum PlayerWindowCommandKind: Equatable {
    case showAndActivate
    case focus
    case showWithoutStealingFocus
    case toggleFullScreen
    case close
}

struct PlayerWindowCommand: Identifiable, Equatable {
    let id: UUID
    let requestID: UUID?
    let kind: PlayerWindowCommandKind

    init(
        id: UUID = UUID(),
        requestID: UUID?,
        kind: PlayerWindowCommandKind
    ) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
    }
}

enum PlayerWindowFocusCompensationPolicy {
    static func shouldRetry(
        isApplicationActive: Bool,
        isWindowKey: Bool,
        ownsRequest: Bool,
        isCommandPending: Bool
    ) -> Bool {
        isApplicationActive
            && !isWindowKey
            && ownsRequest
            && isCommandPending
    }
}

enum PlayerErrorPresentationPolicy {
    static func targetsPlayer(
        target: UserFacingErrorTarget,
        isPlayerPresented: Bool
    ) -> Bool {
        isPlayerPresented && target == .player
    }
}

enum ImportOperationResult {
    case success(ConfigurationImportSummary)
    case cancelled
    case failure(UserFacingError)
}

struct ConfigurationImportSummary: Equatable {
    let configurationID: UUID
    let configurationName: String
    let siteCount: Int
    let javaDexSiteCount: Int
    let javaScriptSiteCount: Int
    let otherSiteCount: Int
    let liveCount: Int
    let synchronizableLiveCount: Int
    let unsupportedLiveCount: Int
    let androidBridgeUnavailable: Bool
}

struct EmbeddedLiveSourceSyncResult: Equatable {
    let importedCount: Int
    let skippedCount: Int
    let failedCount: Int
}

enum ConfigurationImportCapabilityAnalyzer {
    static func summary(
        configurationID: UUID,
        configurationName: String,
        configuration: FongMiConfiguration,
        baseURL: URL?,
        androidBridgeUnavailable: Bool
    ) -> ConfigurationImportSummary {
        var javaDexSiteCount = 0
        var javaScriptSiteCount = 0
        for site in configuration.sites {
            if SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider: configuration.spider,
                baseURL: baseURL
            ) != nil {
                javaDexSiteCount += 1
            } else if SiteProviderRoutingPolicy.localJavaScriptURL(
                site: site,
                configurationSpider: configuration.spider,
                baseURL: baseURL
            ) != nil || SiteProviderRoutingPolicy
                .hasExclusiveNodeRuntimeOwnership(site) {
                javaScriptSiteCount += 1
            }
        }
        let synchronizableLiveCount = configuration.lives.filter {
            EmbeddedLiveSourcePolicy.canSynchronize($0, baseURL: baseURL)
        }.count
        return ConfigurationImportSummary(
            configurationID: configurationID,
            configurationName: configurationName,
            siteCount: configuration.sites.count,
            javaDexSiteCount: javaDexSiteCount,
            javaScriptSiteCount: javaScriptSiteCount,
            otherSiteCount: max(
                0,
                configuration.sites.count - javaDexSiteCount
                    - javaScriptSiteCount
            ),
            liveCount: configuration.lives.count,
            synchronizableLiveCount: synchronizableLiveCount,
            unsupportedLiveCount: configuration.lives.count
                - synchronizableLiveCount,
            androidBridgeUnavailable: androidBridgeUnavailable
        )
    }
}

enum EmbeddedLiveSourcePolicy {
    static func canSynchronize(
        _ live: LiveConfiguration,
        baseURL: URL?
    ) -> Bool {
        !live.groups.isEmpty || remoteURL(for: live, baseURL: baseURL) != nil
    }

    static func remoteURL(
        for live: LiveConfiguration,
        baseURL: URL?
    ) -> URL? {
        for reference in [live.url, live.api].compactMap({ $0 }) {
            let trimmed = reference.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.hasPrefix("csp_") else { continue }
            guard let url = try? ResourceResolver.resolve(
                trimmed,
                relativeTo: baseURL
            ), ["http", "https"].contains(
                url.scheme?.lowercased() ?? ""
            ) else {
                continue
            }
            return url
        }
        return nil
    }

    static func inlineData(for live: LiveConfiguration) throws -> Data {
        var groups = live.groups
        var defaults = live.header
        if let userAgent = live.userAgent {
            defaults["User-Agent"] = userAgent
        }
        if let referer = live.referer {
            defaults["Referer"] = referer
        }
        if let origin = live.origin {
            defaults["Origin"] = origin
        }
        if !defaults.isEmpty {
            for groupIndex in groups.indices {
                for channelIndex in groups[groupIndex].channels.indices {
                    var merged = defaults
                    merged.merge(
                        groups[groupIndex].channels[channelIndex].header
                    ) { _, channelValue in channelValue }
                    groups[groupIndex].channels[channelIndex].header = merged
                }
            }
        }
        return try JSONEncoder().encode(groups)
    }

    static func defaultHeaders(for live: LiveConfiguration) -> [String: String] {
        var headers = live.header
        if let userAgent = live.userAgent {
            headers["User-Agent"] = userAgent
        }
        if let referer = live.referer {
            headers["Referer"] = referer
        }
        if let origin = live.origin {
            headers["Origin"] = origin
        }
        return headers
    }
}

private struct ImportedConfigurationPayload {
    let loaded: LoadedConfiguration
    let nodeRuntimeEndpoint: URL?
}

struct NodeReleaseErrorPresentation: Equatable {
    let title: String
    let message: String
}

enum AndroidRuntimeUserFacingErrorMapper {
    static func presentation(
        for error: Error,
        localizer: AppLocalizer = .shared
    ) -> NodeReleaseErrorPresentation? {
        guard let runtimeError = error as? AndroidRuntimeFailureError else {
            return nil
        }
        return .init(
            title: localizer.string(.androidStartupFailureTitle),
            message: message(
                for: runtimeError.record.category,
                localizer: localizer
            )
        )
    }

    private static func message(
        for category: AndroidRuntimeFailureCategory,
        localizer: AppLocalizer
    ) -> String {
        let key: String
        let fallback: String
        switch category {
        case .sdkIncomplete:
            key = "android.error.sdk-incomplete"
            fallback = "The selected Android SDK is incomplete. Choose an SDK that includes ADB, Emulator, and a compatible system image in Settings."
        case .javaRuntimeMissing:
            key = "android.error.java-runtime-missing"
            fallback = "Creating or repairing an AVD with the selected external SDK requires a working Java runtime. Existing compatible AVDs can still be launched without it."
        case .adbUnavailable:
            key = "android.error.adb-unavailable"
            fallback = "ADB is unavailable, so OKVideoMac cannot connect to its dedicated Android Emulator."
        case .adbPrivateServerFailed:
            key = "android.error.adb-private-server-failed"
            fallback = "OKVideoMac could not start its private ADB server. The system ADB server was not connected to or stopped."
        case .adbDeviceMissing, .adbSerialMissingTimeout:
            key = "android.error.adb-device-missing"
            fallback = "Android Emulator is still running, but ADB did not discover the expected device."
        case .adbDeviceOffline, .adbOfflineTimeout,
             .hostGPUADBOfflineTimeout, .softwareGPUADBOfflineTimeout:
            key = "android.error.adb-device-offline"
            fallback = "ADB discovered the dedicated Android Emulator, but the device remained offline."
        case .adbReconnectFailed:
            key = "android.error.adb-reconnect-failed"
            fallback = "The bounded reconnect attempt for the dedicated Android Emulator failed."
        case .privateAVDRecoveryRequired:
            key = "android.error.avd-recovery-required"
            fallback = "The dedicated Android Runtime failed with both hardware and software rendering. Rebuild the Runtime from Settings."
        case .emulatorLaunchFailed, .emulatorLaunchTimedOut,
             .emulatorExitedBeforeADB, .emulatorExitedEarly,
             .emulatorExited, .runtimeExited:
            key = "android.error.emulator-launch-failed"
            fallback = "Android Emulator did not start correctly. Export diagnostics and try again."
        case .appRequestedTermination:
            key = "android.error.app-requested-termination"
            fallback = "Android Emulator startup was cancelled or ended by OKVideoMac."
        case .emulatorOwnershipMismatch:
            key = "android.error.emulator-ownership-mismatch"
            fallback = "OKVideoMac could not safely verify ownership of the dedicated Android Emulator and did not touch other devices."
        case .emulatorProcessMismatch:
            key = "android.error.emulator-process-mismatch"
            fallback = "The recorded Android Emulator process no longer belongs to this startup session."
        case .emulatorRuntimeConflict:
            key = "android.error.emulator-runtime-conflict"
            fallback = "Another Emulator is using the dedicated AVD or reserved ports. No process was terminated."
        case .portConflict:
            key = "android.error.port-conflict"
            fallback = "A port required by Android Emulator is in use by another process. The other process was not terminated."
        case .unexpectedSerial:
            key = "android.error.unexpected-serial"
            fallback = "ADB discovered another Emulator, but not the device expected for this startup session."
        case .androidBootTimedOut:
            key = "android.error.boot-timeout"
            fallback = "Android did not finish booting within the allowed time."
        case .emulatorNetworkUnavailable:
            key = "android.error.network-unavailable"
            fallback = "Android Emulator did not establish a usable network connection. Check your network and try again."
        case .bridgeAPKMissing, .bridgeInstallFailed:
            key = "android.error.bridge-install-failed"
            fallback = "Android Bridge could not be installed. Reinstall OKVideoMac or export diagnostics."
        case .bridgeLaunchFailed:
            key = "android.error.bridge-launch-failed"
            fallback = "Android Bridge did not start. Use Repair in Settings and try again."
        case .portForwardFailed:
            key = "android.error.port-forward-failed"
            fallback = "ADB port forwarding failed, so Android Bridge could not connect to the Mac."
        case .hostPortConflict:
            key = "android.error.host-port-conflict"
            fallback = "The local Android Bridge port is already in use. Close the conflicting app and try again."
        case .bridgeIdentityMismatch:
            key = "android.error.bridge-identity-mismatch"
            fallback = "The detected Android Bridge does not belong to this startup session. The connection was refused."
        case .bridgeVersionMismatch:
            key = "android.error.bridge-version-mismatch"
            fallback = "Android Bridge does not match this version of OKVideoMac. Use Repair to install the current Bridge."
        case .bridgeHealthTimedOut:
            key = "android.error.bridge-health-timeout"
            fallback = "Android Bridge did not connect within the allowed time. This startup attempt has failed; try again or use Repair."
        case .unknown:
            key = "android.error.unknown"
            fallback = "The Android compatibility environment failed to start. Export diagnostics now for troubleshooting."
        }
        return localizer.string(
            L10nKey(rawValue: key),
            fallback: fallback
        )
    }
}

enum NodeUserFacingErrorMapper {
    static func presentation(for error: Error) -> NodeReleaseErrorPresentation? {
        if let nodeError = error as? NodeBundleRuntimeError {
            switch nodeError {
            case .unsupportedHostContract:
                return .init(
                    title: L10n.string("node.error.unsupported.title", fallback: "Unsupported Node Compatibility Mode"),
                    message: L10n.string("node.error.unsupported.message", fallback: "This provider requires host capabilities that are not supported by this version. Loading stopped.")
                )
            case .configurationContractInvalid:
                return .init(
                    title: L10n.string("node.error.invalid-config.title", fallback: "Invalid Node Provider Configuration"),
                    message: L10n.string("node.error.invalid-config.message", fallback: "This provider supplied an incomplete or unsupported runtime configuration.")
                )
            case .hostCapabilityUnavailable, .portAllocationFailed,
                 .loopbackEnforcementFailed, .contractBReadinessFailed:
                return .init(
                    title: L10n.string("node.error.startup.title", fallback: "Node Runtime Failed to Start"),
                    message: L10n.string("node.error.startup.message", fallback: "The local runtime service did not pass its startup security checks. Try again later.")
                )
            default:
                break
            }
            switch nodeError.diagnosticClassification.category {
            case .transport:
                return .init(
                    title: L10n.string("node.error.component-connection.title", fallback: "Node Component Connection Failed"),
                    message: L10n.string("node.error.component-connection.message", fallback: "The runtime component could not be retrieved. A verified local cache was attempted. Try again later.")
                )
            case .trust:
                return .init(
                    title: L10n.string("node.error.integrity.title", fallback: "Node Security Check Failed"),
                    message: L10n.string("node.error.integrity.message", fallback: "The remote runtime component failed integrity validation. Loading stopped.")
                )
            case .cache:
                return .init(
                    title: L10n.string("node.error.cache.title", fallback: "Node Cache Unavailable"),
                    message: L10n.string("node.error.cache.message", fallback: "The local runtime component cache could not be validated or upgraded. Try again later.")
                )
            case .runtime:
                return .init(
                    title: L10n.string("node.error.startup.title", fallback: "Node Runtime Failed to Start"),
                    message: L10n.string("node.error.bundled-startup.message", fallback: "The built-in runtime did not start correctly. Restart the app and try again.")
                )
            case .spiderSite:
                return .init(
                    title: L10n.string("provider.error.request.title", fallback: "Provider Request Failed"),
                    message: L10n.string("provider.error.unresponsive.message", fallback: "The current provider is temporarily unresponsive. Other providers remain available.")
                )
            }
        }
        if let appError = error as? AppError {
            switch appError {
            case .spider:
                return .init(
                    title: L10n.string("provider.error.request.title", fallback: "Provider Request Failed"),
                    message: L10n.string("provider.error.invalid-response.message", fallback: "The current provider returned a result that could not be processed. Try again later or choose another provider.")
                )
            default:
                break
            }
        }
        return nil
    }
}

enum CommonUserFacingErrorMapper {
    static func message(
        for error: Error,
        localizer: AppLocalizer = .shared
    ) -> String? {
        if let playbackError = error as? ProviderPlaybackError {
            // Provider-authored text is content, not application chrome. Keep
            // it intact while removing AppError's legacy Chinese prefix.
            return LogRedactor.text(playbackError.message)
        }
        guard let appError = error as? AppError else { return nil }
        switch appError {
        case .cancelled:
            return localizer.string(
                L10nKey(rawValue: "error.common.cancelled"),
                fallback: "The operation was cancelled."
            )
        case .configuration(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.configuration",
                fallback: "The configuration could not be processed. Check it and try again.",
                localizer: localizer
            )
        case .network(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.network",
                fallback: "The network request failed. Check your connection and try again.",
                localizer: localizer
            )
        case .decoding(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.decoding",
                fallback: "The returned data could not be processed. Try another provider or try again later.",
                localizer: localizer
            )
        case .site(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.site",
                fallback: "The provider could not complete this request. Try again later or use another provider.",
                localizer: localizer
            )
        case .contentUnavailable(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.content-unavailable",
                fallback: "This content cannot be opened from the current provider.",
                localizer: localizer
            )
        case .spider(let message), .javascript(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.provider-script",
                fallback: "The provider script could not complete the request.",
                localizer: localizer
            )
        case .parsing(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.parsing",
                fallback: "The playback address could not be resolved. Try another stream or provider.",
                localizer: localizer
            )
        case .playback(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.playback",
                fallback: "Playback could not be started or completed.",
                localizer: localizer
            )
        case .live(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.live",
                fallback: "The Live TV operation could not be completed.",
                localizer: localizer
            )
        case .database(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.database",
                fallback: "The local database operation failed. Export diagnostics if the problem continues.",
                localizer: localizer
            )
        case .filesystem(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.filesystem",
                fallback: "The file operation failed. Check the selected file or folder and try again.",
                localizer: localizer
            )
        case .unsupported(let message):
            return localizedOrGeneric(
                message,
                key: "error.common.unsupported",
                fallback: "This operation is not supported.",
                localizer: localizer
            )
        }
    }

    private static func localizedOrGeneric(
        _ message: String,
        key: String,
        fallback: String,
        localizer: AppLocalizer
    ) -> String {
        let redacted = LogRedactor.text(message)
        guard localizer.language == .english,
              redacted.unicodeScalars.contains(where: {
                  (0x4E00...0x9FFF).contains(Int($0.value))
              }) else {
            return redacted
        }
        return localizer.string(
            L10nKey(rawValue: key),
            fallback: fallback
        )
    }
}

enum RuntimeUserFacingMessageMapper {
    static func message(for error: Error) -> String {
        if let presentation = AndroidRuntimeUserFacingErrorMapper.presentation(
            for: error
        ) {
            return presentation.message
        }
        if let presentation = NodeUserFacingErrorMapper.presentation(for: error) {
            return presentation.message
        }
        if let message = CommonUserFacingErrorMapper.message(for: error) {
            return message
        }
        return LogRedactor.text(error.localizedDescription)
    }
}

enum CloudAccountSnapshotStatus: String, Codable, Equatable, Sendable {
    case authenticated
    case unauthenticated
    case pending

    var localizedTitle: String {
        switch self {
        case .authenticated: return L10n.string(.cloudAuthenticated)
        case .unauthenticated: return L10n.string(.cloudUnauthenticated)
        case .pending: return L10n.string(.cloudPending)
        }
    }
}

struct CloudAccountStatusKey: Codable, Equatable, Hashable, Sendable {
    let scopeID: String
    let accountKey: String
}

struct CloudAccountStatusRecord: Codable, Equatable, Sendable {
    let key: CloudAccountStatusKey
    var status: CloudAccountSnapshotStatus
    var verifiedAt: Date
}

/// A credential-free, application-wide snapshot of cloud account state.
/// Android remains the sole owner of Cookie/Token data. This store persists
/// only the exact configuration/site/JAR scope, account identity, a tri-state
/// result and its verification time. A different configuration or updated JAR
/// must verify again instead of inheriting a stale login badge.
struct CloudAccountStatusStore: Codable, Equatable, Sendable {
    static let settingKey = "cloud.accountStatus.v2"

    private(set) var records: [CloudAccountStatusRecord] = []

    init(records: [CloudAccountStatusRecord] = []) {
        self.records = records
    }

    init?(setting: JSONValue) {
        guard case .string(let encoded) = setting,
              let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        // Persisted authentication is historical evidence, not proof that the
        // newly-created Android provider instance restored valid credentials.
        // Current Bridge evidence promotes it back to authenticated.
        var restored = decoded
        for index in restored.records.indices
        where restored.records[index].status == .authenticated {
            restored.records[index].status = .pending
        }
        self = restored
    }

    var setting: JSONValue? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return .string(data.base64EncodedString())
    }

    func status(
        scopeID: String,
        accountKey: String
    ) -> CloudAccountSnapshotStatus? {
        records.first(where: {
            $0.key == CloudAccountStatusKey(
                scopeID: scopeID,
                accountKey: accountKey
            )
        })?.status
    }

    func status(
        scopeID: String,
        matchingAccountLabel accountLabel: String
    ) -> CloudAccountSnapshotStatus? {
        records
            .filter {
                $0.key.scopeID == scopeID
                    && CloudAccountIdentityPolicy.matches(
                        $0.key.accountKey,
                        accountLabel
                    )
            }
            .max(by: { $0.verifiedAt < $1.verifiedAt })?
            .status
    }

    @discardableResult
    mutating func observe(
        title: String,
        scopeID: String,
        explicitlyUnauthenticated: Bool = false,
        now: Date = Date()
    ) -> Bool {
        guard let parsed = CloudAccountStatusTitlePolicy.parse(title) else {
            return false
        }
        let key = CloudAccountStatusKey(
            scopeID: scopeID,
            accountKey: parsed.accountKey
        )
        let incoming: CloudAccountSnapshotStatus
        switch parsed.status {
        case .authenticated:
            incoming = .authenticated
        case .unauthenticated:
            // A legacy chooser may publish a temporary "未登录" row while a
            // newly-created provider instance is restoring Android state.
            // It cannot revoke a previously confirmed login unless the Bridge
            // also reports an explicit unauthenticated result.
            if status(
                scopeID: scopeID,
                accountKey: parsed.accountKey
            ) == .authenticated, !explicitlyUnauthenticated {
                return false
            }
            incoming = .unauthenticated
        case .pending:
            if status(
                scopeID: scopeID,
                accountKey: parsed.accountKey
            ) == .authenticated {
                return false
            }
            incoming = .pending
        }
        return set(incoming, for: key, verifiedAt: now)
    }

    @discardableResult
    mutating func confirmAuthenticated(
        scopeID: String,
        accountKey: String,
        now: Date = Date()
    ) -> Bool {
        set(
            .authenticated,
            for: CloudAccountStatusKey(
                scopeID: scopeID,
                accountKey: accountKey
            ),
            verifiedAt: now
        )
    }

    @discardableResult
    mutating func invalidate(
        scopeID: String,
        command: String,
        now: Date = Date()
    ) -> Bool {
        guard let fragments = CloudAccountStatusInvalidationPolicy
            .accountKeyFragments(for: command) else {
            return false
        }
        var changed = false
        for index in records.indices
        where records[index].key.scopeID == scopeID
            && fragments.contains(where: {
                records[index].key.accountKey.contains($0)
            }) {
            if records[index].status != .unauthenticated {
                records[index].status = .unauthenticated
                records[index].verifiedAt = now
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    mutating func invalidate(
        scopeID: String,
        now: Date = Date()
    ) -> Bool {
        var changed = false
        for index in records.indices
        where records[index].key.scopeID == scopeID {
            if records[index].status != .unauthenticated {
                records[index].status = .unauthenticated
                records[index].verifiedAt = now
                changed = true
            }
        }
        return changed
    }

    func reconciledTitle(_ title: String, scopeID: String) -> String {
        guard let parsed = CloudAccountStatusTitlePolicy.parse(title),
              let stored = status(
                scopeID: scopeID,
                accountKey: parsed.accountKey
              ) else {
            return title
        }
        return CloudAccountStatusTitlePolicy.replacingStatus(
            in: title,
            with: stored
        )
    }

    private mutating func set(
        _ status: CloudAccountSnapshotStatus,
        for key: CloudAccountStatusKey,
        verifiedAt: Date
    ) -> Bool {
        if let index = records.firstIndex(where: { $0.key == key }) {
            guard records[index].status != status else { return false }
            records[index].status = status
            records[index].verifiedAt = verifiedAt
            return true
        }
        records.append(
            CloudAccountStatusRecord(
                key: key,
                status: status,
                verifiedAt: verifiedAt
            )
        )
        return true
    }
}

enum CloudAccountStatusTitlePolicy {
    struct ParsedStatus: Equatable, Sendable {
        let accountKey: String
        let status: CloudAccountSnapshotStatus
    }

    private static let markers: [
        (text: String, status: CloudAccountSnapshotStatus)
    ] = [
        ("未登录", .unauthenticated),
        ("未登入", .unauthenticated),
        ("未授权", .unauthenticated),
        ("上次已授权", .pending),
        ("已登录", .authenticated),
        ("已登入", .authenticated),
        ("已授权", .authenticated),
        ("正在确认", .pending),
        ("Not Signed In", .unauthenticated),
        ("Previously Authorized", .pending),
        ("Signed In", .authenticated),
        ("Confirming", .pending)
    ]

    static func parse(_ title: String) -> ParsedStatus? {
        guard let marker = markers.first(where: { title.contains($0.text) }),
              let accountKey = accountKey(in: title) else {
            return nil
        }
        return ParsedStatus(accountKey: accountKey, status: marker.status)
    }

    static func accountKey(in title: String) -> String? {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in markers {
            normalized = normalized.replacingOccurrences(
                of: marker.text,
                with: ""
            )
        }
        let separators = CharacterSet(
            charactersIn: "-—–_:：|｜·•()（）[]【】"
        ).union(.whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: separators).lowercased()
        return normalized.nonEmpty
    }

    static func replacingStatus(
        in title: String,
        with status: CloudAccountSnapshotStatus
    ) -> String {
        guard parse(title) != nil else { return title }
        var base = title
        for marker in markers {
            base = base.replacingOccurrences(of: marker.text, with: "")
        }
        let separators = CharacterSet(
            charactersIn: "-—–_:：|｜·•()（）[]【】"
        ).union(.whitespacesAndNewlines)
        base = base.trimmingCharacters(in: separators)
        return L10n.string(
            .cloudTitleFormat,
            fallback: "%1$@ — %2$@",
            base,
            status.localizedTitle
        )
    }

    static func replacingStatusOnly(
        in value: String,
        with status: CloudAccountSnapshotStatus
    ) -> String {
        guard isStatusOnly(value) else { return value }
        return status.localizedTitle
    }

    static func isStatusOnly(_ value: String) -> Bool {
        var remainder = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in markers {
            remainder = remainder.replacingOccurrences(of: marker.text, with: "")
        }
        let separators = CharacterSet(
            charactersIn: "-—–_:：|｜·•()（）[]【】"
        ).union(.whitespacesAndNewlines)
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remainder.trimmingCharacters(in: separators).isEmpty
            && markers.contains(where: { value.contains($0.text) })
    }
}

enum CloudAccountIdentityPolicy {
    private static let accountFamilies: [[String]] = [
        ["quark", "夸克", "夸父"],
        ["uc", "优沛", "优汐", "优沫"],
        ["baidu", "百度", "哪吒", "哪哪"],
        ["ali", "阿里", "阿狸"],
        ["tianyi", "天翼"],
        ["mobile", "移动", "和彩云"],
        ["xunlei", "迅雷"],
        ["123", "123盘", "123网盘"],
        ["115", "115盘", "115网盘"],
        ["guangya", "光鸭"]
    ]

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right || left.contains(right) || right.contains(left) {
            return true
        }
        return accountFamilies.contains { family in
            family.contains(where: left.contains)
                && family.contains(where: right.contains)
        }
    }

    private static func normalized(_ value: String) -> String {
        var normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        for fragment in [
            "我的", "网盘", "云盘", "账号", "帐号", "账户", "account", "drive"
        ] {
            normalized = normalized.replacingOccurrences(of: fragment, with: "")
        }
        let separators = CharacterSet(
            charactersIn: "-—–_:：|｜·•()（）[]【】"
        ).union(.whitespacesAndNewlines)
        return normalized.trimmingCharacters(in: separators)
    }
}

enum CloudAccountStatusPresentationPolicy {
    static func applying(
        to items: [SiteActionItem],
        accountLabel: String,
        scopeID: String,
        store: CloudAccountStatusStore
    ) -> [SiteActionItem] {
        guard let status = store.status(
            scopeID: scopeID,
            matchingAccountLabel: accountLabel
        ) else { return items }
        return items.map { item in
            var updated = item
            updated.title = store.reconciledTitle(
                item.title,
                scopeID: scopeID
            )
            if let remarks = item.remarks {
                let reconciled = store.reconciledTitle(
                    remarks,
                    scopeID: scopeID
                )
                updated.remarks = CloudAccountStatusTitlePolicy
                    .replacingStatusOnly(in: reconciled, with: status)
            }
            return updated
        }
    }
}

enum CloudAccountStatusInvalidationPolicy {
    static func accountKeyFragments(for command: String) -> [String]? {
        switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "quarkClean":
            return ["quark", "夸克", "夸父"]
        case "ucClean":
            return ["uc", "优沛", "优汐"]
        case "BdClean":
            return ["baidu", "百度", "哪吒", "哪哪"]
        case "aliClean":
            return ["ali", "阿里", "阿狸"]
        default:
            return nil
        }
    }
}

enum CloudAccountProviderIdentity {
    static func identifier(
        capability: SiteCapability,
        api: String
    ) -> String? {
        let normalizedAPI = api.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !normalizedAPI.isEmpty else { return nil }
        return "\(capability.rawValue.lowercased()):\(normalizedAPI)"
    }
}

enum CloudPlaybackAuthorizationFailurePolicy {
    static func isExplicit(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !normalized.isEmpty else { return false }
        return [
            "未登录", "未登入", "请登录", "请登入", "登录失效", "登入失效",
            "授权失效", "授权过期", "cookie失效", "cookie过期",
            "token失效", "token过期", "http 401", "http 403"
        ].contains(where: normalized.contains)
    }
}

enum CloudInteractionKind: String, Equatable {
    case configuration
    case authorization
}

/// Host-owned semantics for a configuration interaction. Providers may adopt
/// these values directly once their protocol exposes an interaction ID. Until
/// then the legacy adapter starts conservatively as `.legacy` and only
/// promotes a native surface from structural UI metadata.
enum ConfigurationInteractionSemantic: String, Equatable, Sendable {
    case command
    case toggle
    case choice
    case order
    case qrAuthorization = "qr"
    case credentialAuthorization = "credential"
    case web
    case native
    case legacy

    var isAuthorization: Bool {
        // These values are assigned only after the provider has explicitly
        // declared an authorization interaction. Merely exposing an input or
        // image must never upgrade an ordinary configuration command.
        self == .qrAuthorization || self == .credentialAuthorization
    }
}

enum ConfigurationInteractionTransport: String, Equatable, Sendable {
    case web
    case native
    case legacy
}

enum ConfigurationInteractionPhase: String, Equatable, Sendable {
    case invoking
    case awaitingInterface
    case presenting
    case submitting
    case processing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .invoking, .awaitingInterface, .submitting, .processing:
            return true
        case .presenting, .completed, .failed, .cancelled:
            return false
        }
    }
}

enum ConfigurationInteractionCancellationReason: String, Equatable, Sendable {
    case user
    case superseded
    case sourceChanged
    case providerCancelled
}

struct ConfigurationInteractionRequest: Equatable, Sendable {
    let interactionID: UUID
    /// Monotonic host generation. UUID ownership rejects callbacks from a
    /// different request, while this generation also prevents a deliberately
    /// reused playback request ID from reviving presentation state retired by
    /// a later host session.
    let generation: UInt64
    let sourceIdentity: HomeContentIdentity
    let semantic: ConfigurationInteractionSemantic
    let transport: ConfigurationInteractionTransport
    let title: String
}

struct ConfigurationInteractionTransaction: Equatable, Sendable {
    var request: ConfigurationInteractionRequest
    var phase: ConfigurationInteractionPhase
    var status: String?
    var cancellationReason: ConfigurationInteractionCancellationReason?
}

/// Single semantic owner for request-scoped configuration UI. Every async
/// callback must still own `interactionID` before it may publish UI or a
/// terminal result. A new request supersedes the previous request without
/// allowing its late callbacks to mutate the replacement.
struct ConfigurationInteractionCoordinator: Sendable {
    private(set) var current: ConfigurationInteractionTransaction?
    private(set) var generation: UInt64 = 0

    var hasActiveRequest: Bool {
        guard let current else { return false }
        return !current.phase.isTerminal
    }

    @discardableResult
    mutating func begin(
        sourceIdentity: HomeContentIdentity,
        semantic: ConfigurationInteractionSemantic,
        transport: ConfigurationInteractionTransport,
        title: String,
        interactionID: UUID = UUID()
    ) -> ConfigurationInteractionRequest {
        generation &+= 1
        let request = ConfigurationInteractionRequest(
            interactionID: interactionID,
            generation: generation,
            sourceIdentity: sourceIdentity,
            semantic: semantic,
            transport: transport,
            title: title
        )
        current = ConfigurationInteractionTransaction(
            request: request,
            phase: .invoking,
            status: nil,
            cancellationReason: nil
        )
        return request
    }

    func owns(
        _ interactionID: UUID,
        generation expectedGeneration: UInt64? = nil
    ) -> Bool {
        guard let request = current?.request,
              request.interactionID == interactionID else {
            return false
        }
        return expectedGeneration == nil
            || request.generation == expectedGeneration
    }

    @discardableResult
    mutating func transition(
        _ interactionID: UUID,
        to phase: ConfigurationInteractionPhase,
        semantic: ConfigurationInteractionSemantic? = nil,
        transport: ConfigurationInteractionTransport? = nil,
        status: String? = nil
    ) -> Bool {
        guard var transaction = current,
              transaction.request.interactionID == interactionID,
              !transaction.phase.isTerminal else {
            return false
        }
        if let semantic {
            transaction.request = ConfigurationInteractionRequest(
                interactionID: transaction.request.interactionID,
                generation: transaction.request.generation,
                sourceIdentity: transaction.request.sourceIdentity,
                semantic: semantic,
                transport: transport ?? transaction.request.transport,
                title: transaction.request.title
            )
        } else if let transport {
            transaction.request = ConfigurationInteractionRequest(
                interactionID: transaction.request.interactionID,
                generation: transaction.request.generation,
                sourceIdentity: transaction.request.sourceIdentity,
                semantic: transaction.request.semantic,
                transport: transport,
                title: transaction.request.title
            )
        }
        transaction.phase = phase
        transaction.status = status
        current = transaction
        return true
    }

    @discardableResult
    mutating func cancel(
        _ interactionID: UUID,
        reason: ConfigurationInteractionCancellationReason
    ) -> Bool {
        guard var transaction = current,
              transaction.request.interactionID == interactionID,
              !transaction.phase.isTerminal else {
            return false
        }
        transaction.phase = .cancelled
        transaction.cancellationReason = reason
        current = transaction
        return true
    }

    mutating func clear(_ interactionID: UUID? = nil) {
        guard interactionID == nil || current?.request.interactionID == interactionID else {
            return
        }
        current = nil
    }
}

enum CloudAuthorizationPresentationTarget: Equatable {
    case mainWindow
    case detail
    case player(requestID: UUID)
}

enum ConfigurationPresentationTargetPolicy {
    static func resolvedTarget(
        requested: CloudAuthorizationPresentationTarget,
        hasDetailPresentation: Bool
    ) -> CloudAuthorizationPresentationTarget {
        guard requested == .detail, !hasDetailPresentation else {
            return requested
        }
        return .mainWindow
    }
}

enum CloudAuthorizationPlaybackOwnershipPolicy {
    static func isCurrent(
        requestID: UUID,
        activeRequestID: UUID,
        playbackSessionID: UUID,
        isPlayerPresented: Bool
    ) -> Bool {
        isPlayerPresented
            && requestID == activeRequestID
            && requestID == playbackSessionID
    }
}

/// Serializes the handoff from an Android authorization interaction back into
/// the exact player request that triggered it. The original resolver lease is
/// released before the provider UI is presented, so an immediately available
/// terminal result can resume without timing sleeps. A request may consume its
/// authoritative result only once.
struct PlaybackAuthorizationResumeGate: Sendable {
    private(set) var claimedRequestID: UUID?

    static func allowsInFlightDuplicateFastPath(
        authorizationRetry: Bool,
        hasAuthoritativeResult: Bool
    ) -> Bool {
        !authorizationRetry && !hasAuthoritativeResult
    }

    mutating func resetForNewPlayback() {
        claimedRequestID = nil
    }

    mutating func claim(
        requestID: UUID,
        activeRequestID: UUID,
        playbackSessionID: UUID,
        isPlayerPresented: Bool,
        hasAuthoritativeResult: Bool,
        requiresAuthoritativeResult: Bool,
        originalRequestIsResolving: Bool
    ) -> Bool {
        guard CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
            requestID: requestID,
            activeRequestID: activeRequestID,
            playbackSessionID: playbackSessionID,
            isPlayerPresented: isPlayerPresented
        ), !originalRequestIsResolving,
           !requiresAuthoritativeResult || hasAuthoritativeResult,
           claimedRequestID != requestID else {
            return false
        }
        claimedRequestID = requestID
        return true
    }
}

/// A captured Android frame is a short-lived input capability, not merely an
/// image. Publication and event delivery validate the complete lease so an
/// older frame can never drive a newer provider/runtime surface.
enum AndroidActionSurfaceLeasePolicy {
    static func accepts(
        frame: AndroidActionSurfaceFrame,
        replacing previous: AndroidActionSurfaceFrame?,
        expectedInteractionID: UUID,
        expectedProviderOwnerID: String?,
        expectedGeneration: Int?
    ) -> Bool {
        guard frame.interactionID == expectedInteractionID,
              let expectedProviderOwnerID = expectedProviderOwnerID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedProviderOwnerID.isEmpty,
              frame.providerOwnerID == expectedProviderOwnerID,
              let expectedGeneration,
              frame.generation == expectedGeneration,
              !frame.runtimeGeneration.isEmpty,
              [
                "actionactivity", "providerwindow",
                "externalactivity", "delegatedactivity"
              ]
                .contains(frame.surfaceMode),
              frame.frameSequence > 0,
              frame.pixelWidth > 0,
              frame.pixelHeight > 0,
              frame.hasValidCaptureGeometry else {
            return false
        }
        guard let previous else { return true }
        guard previous.interactionID == frame.interactionID else {
            return false
        }
        return previous.providerOwnerID == frame.providerOwnerID
            && previous.runtimeGeneration == frame.runtimeGeneration
            && frame.frameSequence > previous.frameSequence
    }

    static func isExactLease(
        _ lhs: AndroidActionSurfaceFrame,
        _ rhs: AndroidActionSurfaceFrame
    ) -> Bool {
        lhs == rhs
    }

    /// A Dialog stack transition invalidates the pixels immediately, even
    /// though the action/provider lease itself is unchanged. This prevents a
    /// just-dismissed Dialog (or its QR code) from surviving the capture
    /// throttle while Android has already exposed the layer below it.
    static func matchesCurrentWindow(
        _ frame: AndroidActionSurfaceFrame,
        descriptor: AndroidActionSurfaceCaptureDescriptor?
    ) -> Bool {
        guard let descriptor else { return false }
        return frame.matches(captureDescriptor: descriptor)
    }
}

/// Keeps the last renderable pixels during a brief Dialog/Activity or ADB
/// capture gap, but only while they still belong to the exact request-owned
/// Android surface. A replacement interaction, provider, or runtime generation
/// can never inherit the previous surface.
enum AndroidActionSurfaceContinuityPolicy {
    static func canRetain(
        _ frame: AndroidActionSurfaceFrame?,
        expectedInteractionID: UUID,
        providerOwnerID: String?,
        generation: Int?
    ) -> Bool {
        guard let frame,
              frame.interactionID == expectedInteractionID else {
            return false
        }
        if let providerOwnerID = providerOwnerID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerOwnerID.isEmpty,
           frame.providerOwnerID != providerOwnerID {
            return false
        }
        if let generation, frame.generation != generation {
            return false
        }
        return true
    }
}

struct CloudAuthorizationPrompt: Identifiable, Equatable {
    let id: UUID
    let interactionID: UUID
    let requestGeneration: UInt64
    var title: String
    var interactionKind: CloudInteractionKind
    var semantic: ConfigurationInteractionSemantic
    var transport: ConfigurationInteractionTransport
    var lifecyclePhase: ConfigurationInteractionPhase
    var presentationTarget: CloudAuthorizationPresentationTarget
    var status: String?
    var allowsRetry: Bool
    var allowsCompletionConfirmation: Bool
    var webLinks: [String] = []
}

/// FongMi treats an action result message like `Notify.show`: it is optional,
/// short lived, and independent from any provider-owned dialog. Keeping this
/// value out of `CloudAuthorizationPrompt.status` prevents a Toast/result from
/// becoming the title or body of the next persistent Android interaction.
struct TransientSiteActionStatus: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestGeneration: UInt64
    let title: String
    let message: String
}

struct NodeWebPresentation: Identifiable, Equatable {
    let id: UUID
    let challengeID: UUID
    let requestID: String?
    let sourceIdentity: HomeContentIdentity
    let runtimeWebsiteLocation: NodeRuntimeWebsiteLocation?
    var url: URL
    let title: String
    let message: String
    let provider: String?
    let preferredProviderID: String?
    let transport: String
    let completionMode: NodeAuthorizationCompletionMode
    let challenge: CatPawAuthorizationChallenge?
    let presentationTarget: CloudAuthorizationPresentationTarget
    var lifecycleState: NodeAuthorizationLifecycleState
    var status: String?
    var allowsAutomaticRetry: Bool
    var hasAttemptedProfileRevisionVerification: Bool
    var revision: Int
}

enum NodeAuthorizationLifecycleState: Equatable {
    case waiting
    case saved
    case verifying
    case needsManualRetry
}

struct ConfigurationCategoryPresentation: Identifiable, Equatable {
    let id: UUID
    let sourceIdentity: HomeContentIdentity
    let categoryID: String
    let title: String
    var items: [SiteActionItem]
    var isLoading: Bool
    var errorMessage: String?
}

struct SearchSiteOption: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let resultCount: Int
}

enum SearchSiteScopeMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case custom

    var id: String { rawValue }
}

struct SearchSiteScope: Equatable, Sendable {
    static let schemaVersion = 3

    var mode: SearchSiteScopeMode
    var selectedSiteKeys: Set<String>

    static let all = SearchSiteScope(mode: .all)

    init(mode: SearchSiteScopeMode, selectedSiteKeys: Set<String> = []) {
        self.mode = mode
        self.selectedSiteKeys = selectedSiteKeys
    }

    init?(
        setting: JSONValue,
        expectedConfigurationFingerprint: String
    ) {
        guard case .object(let object) = setting,
              let rawMode = object["mode"]?.stringValue,
              let mode = SearchSiteScopeMode(rawValue: rawMode) else {
            return nil
        }
        if case .integer(let storedVersion)? = object["version"],
           storedVersion < 1 || storedVersion > Int64(Self.schemaVersion) {
            return nil
        }
        // The setting key is already configuration-scoped. A fingerprint
        // change means sites were added/removed or edited; it must not expand a
        // saved custom subset to every site. Keep the keys and rewrite the
        // current fingerprint after loading.
        _ = expectedConfigurationFingerprint
        let keys: Set<String>
        if case .array(let values)? = object["selectedSiteKeys"] {
            keys = Set(values.compactMap(\.stringValue))
        } else {
            keys = []
        }
        self.init(mode: mode, selectedSiteKeys: keys)
    }

    func settingValue(configurationFingerprint: String) -> JSONValue {
        .object([
            "version": .integer(Int64(Self.schemaVersion)),
            "configurationFingerprint": .string(configurationFingerprint),
            "mode": .string(mode.rawValue),
            "selectedSiteKeys": .array(
                selectedSiteKeys.sorted().map(JSONValue.string)
            )
        ])
    }
}

enum SearchConfigurationFingerprint {
    static func make(sites: [SiteConfiguration]) -> String {
        let canonical = sites.map { site in
            [
                site.key,
                String(site.type),
                site.api,
                String(site.hide),
                String(site.indexs),
                String(site.searchable),
                String(site.quickSearch)
            ].joined(separator: "\u{1f}")
        }.sorted().joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum SearchScopeSiteAvailability: Equatable, Sendable {
    case enabled
    case userDisabled
    case unavailable(String)
}

enum SearchScopeSiteAvailabilityPolicy {
    static func availability(
        for site: SiteConfiguration,
        providerCapability: SiteCapability?
    ) -> SearchScopeSiteAvailability {
        if site.extra["okNodeUnsupportedModule"] == .bool(true) {
            let kind = site.extra["okNodeModuleKind"]?.stringValue
                ?? L10n.string("common.other", fallback: "Other")
            return .unavailable(L10n.string("node.module.unavailable", fallback: "%@ module detected; its interface is not enabled in this version", kind))
        }
        let isCatalogueDisabled = site.extra["okNodeCatalogDisabled"]
            == .bool(true)
        if site.extra["okNodeConfigurationRequired"] == .bool(true) {
            return .unavailable(L10n.string("node.module.account-required", fallback: "No account or mount configured"))
        }
        if site.hide != 0, !isCatalogueDisabled {
            return .unavailable(L10n.string("node.module.hidden", fallback: "Hidden by the configuration"))
        }
        if providerCapability == nil || providerCapability == .unsupportedSpider {
            return .unavailable(L10n.string("node.module.runtime-unsupported", fallback: "Unsupported by the current runtime"))
        }
        if site.searchable == 2 || isCatalogueDisabled {
            return .userDisabled
        }
        // `searchable == 0` and a missing/negative Node capability declaration
        // are intentionally not blockers. CatPawOpen bundles in the wild do
        // not publish those fields consistently, so the exact route response
        // is the only reliable capability probe.
        return .enabled
    }
}

enum NodeSearchCapabilityState: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

enum NodeSearchCapabilityPolicy {
    static func declaredState(for site: SiteConfiguration) -> NodeSearchCapabilityState {
        switch site.extra["okNodeSearchCapabilityState"]?.stringValue {
        case "supported":
            return .supported
        case "unsupported":
            return .unsupported
        case "unknown":
            return .unknown
        default:
            break
        }

        // Compatibility with normalized configurations produced before the
        // explicit state marker was introduced. An absent capability list is
        // not negative evidence; only a present empty list is.
        if case .array(let values)? = site.extra["okNodeCapabilities"] {
            return values.compactMap(\.stringValue).contains("search")
                ? .supported
                : .unsupported
        }
        return site.searchable == 0 ? .unsupported : .unknown
    }
}

struct SearchScopeSiteOption: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let availability: SearchScopeSiteAvailability

    init(
        key: String,
        name: String,
        availability: SearchScopeSiteAvailability
    ) {
        self.key = key
        self.name = name
        self.availability = availability
    }

    // Retain the original initializer for persisted-scope policy tests and
    // callers that only distinguish available/unavailable providers.
    init(key: String, name: String, unavailableReason: String?) {
        self.init(
            key: key,
            name: name,
            availability: unavailableReason.map(
                SearchScopeSiteAvailability.unavailable
            ) ?? .enabled
        )
    }

    var unavailableReason: String? {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }

    var isSearchable: Bool {
        if case .unavailable = availability { return false }
        return true
    }

    var isEnabledByDefault: Bool { availability == .enabled }
    var isUserDisabled: Bool { availability == .userDisabled }
}

enum SearchSiteScopePolicy {
    static func effectiveSiteKeys(
        scope: SearchSiteScope,
        options: [SearchScopeSiteOption]
    ) -> Set<String> {
        let selectableKeys = Set(
            options.lazy.filter(\.isSearchable).map(\.key)
        )
        switch scope.mode {
        case .all:
            // "All sites" is literal: CatPawOpen's searchable == 2 is a
            // source-side preference, not evidence that POST /search cannot
            // return data. Users who want to omit a site can switch to the
            // custom scope. This also prevents a useful provider such as the
            // short-drama route from silently disappearing from aggregate
            // search merely because another client disabled it.
            return selectableKeys
        case .custom:
            return selectableKeys.intersection(scope.selectedSiteKeys)
        }
    }
}

enum NodeDynamicSiteCatalogPolicy {
    private static let dynamicKeyPrefixes = [
        "nodejs_alist_",
        "nodejs_emby_",
        "nodejs_webdav_"
    ]

    static func containsConfiguredProvider(in sites: [SiteConfiguration]) -> Bool {
        sites.contains { site in
            dynamicKeyPrefixes.contains { site.key.hasPrefix($0) }
        }
    }
}

enum SearchLaunchContext: Equatable, Sendable {
    case manual
    case discoveryCard
    case discoveryFallback

    var usesConfiguredScope: Bool {
        switch self {
        case .manual, .discoveryCard:
            return true
        case .discoveryFallback:
            return false
        }
    }
}

enum SearchProviderSelectionPolicy {
    static func effectiveSiteKeys(
        context: SearchLaunchContext,
        scope: SearchSiteScope,
        options: [SearchScopeSiteOption]
    ) -> Set<String> {
        switch context {
        case .manual, .discoveryCard:
            return SearchSiteScopePolicy.effectiveSiteKeys(
                scope: scope,
                options: options
            )
        case .discoveryFallback:
            // A discovery card represents a title, not an instruction to
            // search only the site that supplied the metadata. Respect the
            // protocol's searchable/hidden/runtime flags, but deliberately
            // ignore the user's manual-search subset for this one launch.
            return Set(options.lazy.filter(\.isEnabledByDefault).map(\.key))
        }
    }
}

struct HomeContentIdentity: Equatable, Hashable, Sendable {
    let configurationID: UUID
    let siteKey: String
}

enum NodeAuthorizationRetryPolicy {
    static func shouldRetry(
        pendingIdentity: HomeContentIdentity,
        presentationIdentity: HomeContentIdentity,
        activeConfigurationID: UUID?,
        selectedSiteKey: String?,
        requiresSelectedHomeSource: Bool,
        availableSiteKeys: Set<String>
    ) -> Bool {
        pendingIdentity == presentationIdentity
            && activeConfigurationID == pendingIdentity.configurationID
            && availableSiteKeys.contains(pendingIdentity.siteKey)
            && (!requiresSelectedHomeSource
                || selectedSiteKey == pendingIdentity.siteKey)
    }
}

/// Stores only the Runtime-owned configuration route. The loopback origin is
/// deliberately resolved at presentation time so a restarted CatPaw Runtime
/// cannot leave the WebView pinned to its retired random port.
struct NodeRuntimeWebsiteLocation: Equatable, Sendable {
    let percentEncodedPath: String
    let percentEncodedQuery: String?
    let percentEncodedFragment: String?

    init?(url: URL) {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        let path = components.percentEncodedPath
        guard path == "/website" || path.hasPrefix("/website/") else {
            return nil
        }
        percentEncodedPath = path
        percentEncodedQuery = components.percentEncodedQuery
        percentEncodedFragment = components.percentEncodedFragment
    }

    func resolved(against runtimeEndpoint: URL) -> URL? {
        guard var components = URLComponents(
            url: runtimeEndpoint,
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == "http",
           ["127.0.0.1", "localhost", "::1"].contains(
            components.host?.lowercased() ?? ""
           ) else {
            return nil
        }
        components.percentEncodedPath = percentEncodedPath
        components.percentEncodedQuery = percentEncodedQuery
        components.percentEncodedFragment = percentEncodedFragment
        return components.url
    }
}

enum NodeAuthorizationCompletionMatchingPolicy {
    static func matches(
        expectedChallengeID: UUID,
        expectedRequestID: String?,
        signal: NodeAuthorizationCompletionSignal
    ) -> Bool {
        guard signal.challengeID == expectedChallengeID,
              let expectedRequestID = normalized(expectedRequestID),
              normalized(signal.requestID) == expectedRequestID else {
            return false
        }
        return true
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum NodeProfileRevisionVerificationPolicy {
    static func shouldVerifyAutomatically(
        isPlayback: Bool,
        requestID: String?,
        allowsAutomaticRetry: Bool,
        hasAttemptedVerification: Bool,
        acceptsProfileRevisionCompletion: Bool = false
    ) -> Bool {
        let normalizedRequestID = requestID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlayback
            && (acceptsProfileRevisionCompletion
                || normalizedRequestID == nil
                || normalizedRequestID?.isEmpty == true)
            && allowsAutomaticRetry
            && !hasAttemptedVerification
    }
}

enum CatPawHistoryMigrationPolicy {
    static func shouldCaptureRecoveredIdentity(
        isHistory: Bool,
        isAuthorizationRetry: Bool,
        isNodeProvider: Bool,
        hasAcceptedProviderReference: Bool,
        detailID: String
    ) -> Bool {
        isHistory
            && !isAuthorizationRetry
            && isNodeProvider
            && !hasAcceptedProviderReference
            && !NodePlaybackReplayReference.isPersistedOpaqueIdentity(detailID)
    }
}

enum CloudAuthorizationRetryPolicy {
    static func isCurrent(
        sourceIdentity: HomeContentIdentity,
        activeConfigurationID: UUID?,
        availableSiteKeys: Set<String>
    ) -> Bool {
        activeConfigurationID == sourceIdentity.configurationID
            && availableSiteKeys.contains(sourceIdentity.siteKey)
    }
}

enum ConfigurationInteractionTerminalDecision: Equatable, Sendable {
    case pending
    case terminalSucceeded
    case terminalFailed(String?)
    case terminalCancelled
}

/// Accepts only state owned by the active request and recognizes an explicit
/// terminal marker. Surface visibility is presentation state, never a business
/// result; a scoped provider handle still owns the authoritative final value.
enum ConfigurationInteractionStatePolicy {
    static func accepts(
        _ state: AndroidBridgeUIState,
        interactionID: UUID,
        requiresScopedIdentity: Bool
    ) -> Bool {
        guard let rawID = state.interactionID?.nonEmpty else {
            return !requiresScopedIdentity
        }
        return UUID(uuidString: rawID) == interactionID
    }

    static func decision(
        for state: AndroidBridgeUIState
    ) -> ConfigurationInteractionTerminalDecision {
        let normalizedOutcome = state.outcome?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPhase = state.phase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if state.terminal == true {
            switch normalizedOutcome {
            case "completed", "success", "succeeded":
                return .terminalSucceeded
            case "cancelled", "canceled", "superseded":
                return .terminalCancelled
            case "failed", "error":
                return .terminalFailed(state.error?.nonEmpty)
            default:
                switch normalizedPhase {
                case "completed", "success", "succeeded":
                    return .terminalSucceeded
                case "cancelled", "canceled", "superseded":
                    return .terminalCancelled
                case "failed", "error":
                    return .terminalFailed(state.error?.nonEmpty)
                default:
                    return .pending
                }
            }
        }

        return .pending
    }
}

enum ConfigurationInteractionClassificationPolicy {
    /// Only structural metadata is accepted here. Display names, source keys,
    /// domains and provider-specific action IDs deliberately do not classify an
    /// operation.
    static func legacySemantic(tag: String?) -> ConfigurationInteractionSemantic {
        switch tag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "command", "immediate": return .command
        case "toggle": return .toggle
        case "choice": return .choice
        case "order": return .order
        // Legacy tags are presentation hints, not proof that the provider is
        // performing authorization. Only the request's declared action kind
        // may select authorization semantics.
        case "qr", "qr-authorization", "qrauthorization",
             "credential", "credentials":
            return .legacy
        case "web": return .web
        case "native": return .native
        default: return .legacy
        }
    }

    static func interactionKind(
        for semantic: ConfigurationInteractionSemantic
    ) -> CloudInteractionKind {
        semantic.isAuthorization ? .authorization : .configuration
    }
}

enum UserVisibleAsyncErrorPolicy {
    static func shouldPresent(_ error: Error, ownsSession: Bool) -> Bool {
        ownsSession && !AsyncCancellationPolicy.isCancellation(error)
    }
}

enum AsyncCancellationPolicy {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return (nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSUserCancelledError)
    }
}

enum HomeContentPublicationPolicy {
    static func shouldDiscard(
        currentIdentity: HomeContentIdentity?,
        targetIdentity: HomeContentIdentity?
    ) -> Bool {
        guard let currentIdentity else { return false }
        return currentIdentity != targetIdentity
    }

    static func shouldPublish(
        currentHome: SiteHome?,
        currentIdentity: HomeContentIdentity?,
        incomingHome: SiteHome,
        incomingIdentity: HomeContentIdentity
    ) -> Bool {
        currentIdentity != incomingIdentity || currentHome != incomingHome
    }
}

enum HomeLoadResultPolicy {
    static func shouldAccept(
        requestSessionID: UUID,
        currentSessionID: UUID,
        requestedSiteKey: String,
        currentSiteKey: String?,
        requestedIdentity: HomeContentIdentity,
        currentIdentity: HomeContentIdentity?
    ) -> Bool {
        requestSessionID == currentSessionID
            && requestedSiteKey == currentSiteKey
            && requestedIdentity == currentIdentity
    }
}

enum HomePresentationSelection: Equatable, Sendable {
    case recommendation
    case category(String)
    case actions
    case empty
}

enum HomeResumeAction: Equatable, Sendable {
    case keep
    case restoreCategory(String)
    case showRecommendation
    case loadCategory(String)
    case showActions
    case loadHome
    case unavailable
}

enum HomeResumePolicy {
    static func action(
        home: SiteHome?,
        selection: HomePresentationSelection,
        selectedCategoryID: String?,
        hasCategoryPage: Bool,
        lastCategoryID: String?
    ) -> HomeResumeAction {
        guard let home else { return .loadHome }
        let mediaCategoryIDs = Set(
            home.categories.lazy
                .filter { $0.resolvedContentKind == .media }
                .map(\.id)
        )
        let hasActions = !home.actionItems.isEmpty
            || HomePresentationPolicy.firstActionCategory(in: home) != nil

        switch selection {
        case .recommendation
            where !home.recommendations.isEmpty
                && selectedCategoryID == nil:
            return .keep
        case .category(let id)
            where mediaCategoryIDs.contains(id)
                && selectedCategoryID == id:
            return hasCategoryPage ? .keep : .loadCategory(id)
        case .actions where hasActions && selectedCategoryID == nil:
            return .keep
        default:
            break
        }

        if let selectedCategoryID,
           mediaCategoryIDs.contains(selectedCategoryID) {
            return hasCategoryPage
                ? .restoreCategory(selectedCategoryID)
                : .loadCategory(selectedCategoryID)
        }
        if !home.recommendations.isEmpty {
            return .showRecommendation
        }
        if let lastCategoryID,
           mediaCategoryIDs.contains(lastCategoryID) {
            return .loadCategory(lastCategoryID)
        }
        if let firstCategoryID = home.categories.first(where: {
            $0.resolvedContentKind == .media
        })?.id {
            return .loadCategory(firstCategoryID)
        }
        if hasActions {
            return .showActions
        }
        return .unavailable
    }

    static func isStructurallyValid(
        home: SiteHome,
        selection: HomePresentationSelection,
        selectedCategoryID: String?
    ) -> Bool {
        switch selection {
        case .recommendation:
            return !home.recommendations.isEmpty
                && selectedCategoryID == nil
        case .category(let id):
            return selectedCategoryID == id
                && home.categories.contains {
                    $0.id == id && $0.resolvedContentKind == .media
                }
        case .actions:
            return selectedCategoryID == nil
                && (!home.actionItems.isEmpty
                    || HomePresentationPolicy.firstActionCategory(in: home)
                        != nil)
        case .empty:
            return home.recommendations.isEmpty
                && !home.categories.contains {
                    $0.resolvedContentKind == .media
                }
                && home.actionItems.isEmpty
                && HomePresentationPolicy.firstActionCategory(in: home) == nil
        }
    }
}

enum HomeSiteSelectionPolicy {
    static func requiresTransition(
        requestedKey: String,
        currentKey: String?,
        hasCurrentHome: Bool,
        isCurrentContent: Bool,
        isHomeLoading: Bool
    ) -> Bool {
        guard requestedKey == currentKey else { return true }
        if hasCurrentHome && isCurrentContent { return false }
        return !isHomeLoading
    }
}

enum HomePresentationPolicy {
    static func selection(
        for home: SiteHome,
        preserving selectedCategoryID: String?
    ) -> HomePresentationSelection {
        let mediaCategories = home.categories.filter {
            $0.resolvedContentKind == .media
        }
        if let selectedCategoryID,
           mediaCategories.contains(where: { $0.id == selectedCategoryID }) {
            return .category(selectedCategoryID)
        }
        if !home.recommendations.isEmpty {
            return .recommendation
        }
        if let category = mediaCategories.first {
            return .category(category.id)
        }
        if !home.actionItems.isEmpty || firstActionCategory(in: home) != nil {
            return .actions
        }
        return .empty
    }

    static func firstActionCategory(in home: SiteHome) -> VideoCategory? {
        home.categories.first { $0.resolvedContentKind == .action }
    }

    static func actionItems(
        from page: VideoPage,
        inheritedFrom category: VideoCategory,
        fallback: SiteActionItem? = nil
    ) -> [SiteActionItem] {
        guard category.resolvedContentKind == .action else { return [] }
        let items: [SiteActionItem] = page.items.compactMap { summary in
            guard summary.resolvedContentKind != .unsupported else { return nil }
            return SiteActionItem(summary: summary)
        }
        if !items.isEmpty {
            return items
        }
        return fallback.map { [$0] } ?? []
    }

    static func addingActionCategoryFallback(
        to home: SiteHome,
        siteKey: String,
        siteName: String
    ) -> SiteHome {
        guard home.actionItems.isEmpty,
              let category = firstActionCategory(in: home) else {
            return home
        }
        var updated = home
        updated.actionItems = [
            SiteActionItem(
                siteKey: siteKey,
                siteName: siteName,
                itemID: category.id,
                title: category.name,
                remarks: L10n.string("configuration.action.open", fallback: "Open Configuration Action"),
                route: .actionCategory(categoryID: category.id)
            )
        ]
        return updated
    }

    /// Some protocol implementations expose a configuration-only shell as a
    /// single category, but omit the optional `action` marker.  Do not infer
    /// from its display name or identifier.  Instead, wait until the provider
    /// has confirmed that the category's complete first page is empty, then
    /// preserve the only structural entry as a user-invoked action.  The
    /// detail request remains the authority for whether a host action exists.
    static func promotingSingletonEmptyCategoryToAction(
        in home: SiteHome,
        categoryID: String,
        page: VideoPage
    ) -> SiteHome? {
        guard home.recommendations.isEmpty,
              home.actionItems.isEmpty,
              home.categories.count == 1,
              home.categories[0].id == categoryID,
              home.categories[0].resolvedContentKind == .media,
              page.items.isEmpty,
              page.pagination.page == 1,
              !page.pagination.hasMore else {
            return nil
        }
        var updated = home
        updated.categories[0].contentKind = .action
        return updated
    }

    static func defaultFilters(for category: VideoCategory) -> [String: String] {
        CategoryFilterCanonicalizer.canonicalSelection(
            filters: category.filters,
            selection: [:]
        )
    }
}

enum HomeSiteRolePolicy {
    static func isContentHome(_ home: SiteHome) -> Bool {
        !home.recommendations.isEmpty
            || home.categories.contains {
                $0.resolvedContentKind == .media
            }
    }
}

enum HomeLandingSitePolicy {
    static func defaultSiteKey(
        from sites: [SiteConfiguration]
    ) -> String? {
        // `indexs` is protocol metadata declaring an indexed/home site. It is
        // a stable structural signal and avoids interpreting source names,
        // keys, domains, or localized category titles.
        sites.first(where: { $0.indexs == 1 })?.key ?? sites.first?.key
    }
}

private struct HomeBrowsingSnapshot {
    let presentation: HomePresentationSelection
    let categoryID: String?
    let categoryQueryKey: CategoryQueryKey?
}

struct CatPawHomeLoadKey: Equatable, Hashable, Sendable {
    let configurationID: UUID
    let semanticRevision: String
    let siteKey: String
}

enum CatPawHomeLoadDecision: Equatable, Sendable {
    case start(generation: UInt64)
    case join(generation: UInt64)
}

struct CatPawHomeLoadCoordinator {
    private var nextGeneration: UInt64 = 0
    private var inFlight: [CatPawHomeLoadKey: UInt64] = [:]

    mutating func begin(
        key: CatPawHomeLoadKey,
        forceRefresh: Bool
    ) -> CatPawHomeLoadDecision {
        if !forceRefresh, let generation = inFlight[key] {
            return .join(generation: generation)
        }
        nextGeneration &+= 1
        inFlight[key] = nextGeneration
        return .start(generation: nextGeneration)
    }

    func owns(key: CatPawHomeLoadKey, generation: UInt64) -> Bool {
        inFlight[key] == generation
    }

    mutating func finish(key: CatPawHomeLoadKey, generation: UInt64) {
        guard owns(key: key, generation: generation) else { return }
        inFlight[key] = nil
    }

    mutating func invalidate(key: CatPawHomeLoadKey) {
        inFlight[key] = nil
    }

    mutating func removeAll() {
        inFlight.removeAll()
    }
}

private struct CatPawHomeRequestTaskEntry {
    let generation: UInt64
    let task: Task<Bool, Never>
}

private struct CategoryRequestTaskEntry {
    let generation: UInt64
    let task: Task<Bool, Never>
}

enum HomeItemRoute: Equatable, Sendable {
    case action
    case folder
    case search
    case detail
}

enum HomeItemRoutePolicy {
    static func route(
        summary: VideoSummary,
        site: SiteConfiguration?,
        inheritedNavigationMode: NodeSiteNavigationMode? = nil
    ) -> HomeItemRoute {
        if summary.resolvedContentKind == .action
            || summary.action?.nonEmpty != nil {
            return .action
        }
        if summary.isFolder { return .folder }
        // FongMi's `indexs` contract describes discovery/index providers.
        // Their cards are search seeds, not provider-owned detail records.
        if inheritedNavigationMode == .discovery
            || NodeSiteNavigationMode.resolve(for: site) == .discovery
            || site?.indexs == 1
            || summary.videoID.hasPrefix("msearch:") {
            return .search
        }
        return .detail
    }
}

enum HomeEntryReason: Equatable, Sendable {
    case applicationRestore
    case configurationSwitch
    case manualReload

    var restoresPersistedSite: Bool {
        self == .applicationRestore
    }
}

enum CategoryLoadResultPolicy {
    static func shouldAccept(
        requestSessionID: UUID,
        currentSessionID: UUID,
        requestedSiteKey: String,
        currentSiteKey: String?,
        requestedIdentity: HomeContentIdentity,
        currentIdentity: HomeContentIdentity?
    ) -> Bool {
        requestSessionID == currentSessionID
            && requestedSiteKey == currentSiteKey
            && requestedIdentity == currentIdentity
    }
}

struct CategoryTabNamespace: Equatable, Hashable, Sendable {
    let configurationID: UUID
    let configurationRevision: String
    let siteKey: String
}

enum NodeConfigurationSemanticRevision {
    static func make(record: StoredConfiguration) -> String? {
        guard record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let sourceURL = URL(string: sourceValue),
              NodeBundleRuntimeService.supports(sourceURL) else {
            return nil
        }
        return make(
            sourceKind: record.sourceKind,
            sourceValue: sourceValue,
            rawData: record.rawData
        )
    }

    static func make(
        sourceKind: StoredConfigurationSourceKind,
        sourceValue: String?,
        rawData: Data
    ) -> String? {
        guard let nodeIdentity = NodeConfigurationSemanticIdentity.revision(
            in: rawData
        ) else {
            return nil
        }
        var hasher = SHA256()
        append(Data(sourceKind.rawValue.utf8), to: &hasher)
        append(Data((sourceValue ?? "").utf8), to: &hasher)
        append(Data(nodeIdentity.utf8), to: &hasher)
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func append(_ data: Data, to hasher: inout SHA256) {
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }
}

enum ConfigurationPublicationChange: Equatable, Sendable {
    case unchanged
    case transportOnly
    case semantic
}

enum ConfigurationPublicationChangePolicy {
    static func classify(
        previous record: StoredConfiguration,
        incomingRawData: Data,
        incomingBaseURL: URL?,
        usesNodeRuntime: Bool
    ) -> ConfigurationPublicationChange {
        let bytesOrEndpointChanged = record.rawData != incomingRawData
            || record.baseURL != incomingBaseURL
        guard bytesOrEndpointChanged else { return .unchanged }
        guard usesNodeRuntime,
              let previousRevision = NodeConfigurationSemanticRevision.make(
                record: record
              ),
              let incomingRevision = NodeConfigurationSemanticRevision.make(
                sourceKind: record.sourceKind,
                sourceValue: record.sourceValue,
                rawData: incomingRawData
              ) else {
            // Preserve the existing comparison contract for TVBox, ordinary
            // remote JSON, and malformed/legacy Node records.
            return .semantic
        }
        return previousRevision == incomingRevision
            ? .transportOnly
            : .semantic
    }
}

enum CategoryConfigurationRevision {
    static func make(record: StoredConfiguration) -> String {
        if let revision = NodeConfigurationSemanticRevision.make(record: record) {
            return revision
        }
        var hasher = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }

        append(Data(record.sourceKind.rawValue.utf8))
        append(Data((record.sourceValue ?? "").utf8))
        append(Data((record.baseURL?.absoluteString ?? "").utf8))
        append(record.rawData)
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum NodeRuntimeContentTransport {
    static func rebind(_ url: URL?, to endpoint: URL) -> URL? {
        guard let url,
              isLoopback(endpoint),
              var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              let sourceURL = components.url,
              isLoopback(sourceURL),
              components.path.hasPrefix("/spider/")
                || components.path.hasPrefix("/proxy/")
                || components.path.hasPrefix("/__okvideo/") else {
            return url
        }
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        return components.url ?? url
    }

    static func rebind(_ items: [VideoSummary], to endpoint: URL) -> [VideoSummary] {
        items.map { item in
            var item = item
            item.posterURL = rebind(item.posterURL, to: endpoint)
            return item
        }
    }

    static func rebind(_ page: VideoPage, to endpoint: URL) -> VideoPage {
        VideoPage(
            items: rebind(page.items, to: endpoint),
            pagination: page.pagination
        )
    }

    static func rebind(_ home: SiteHome, to endpoint: URL) -> SiteHome {
        SiteHome(
            categories: home.categories,
            recommendations: rebind(home.recommendations, to: endpoint),
            actionItems: home.actionItems
        )
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(
            url.host?.lowercased() ?? ""
        )
    }
}

struct CategoryFilterValue: Equatable, Hashable, Sendable {
    let key: String
    let value: String
}

enum CategoryFilterCanonicalizer {
    static func canonicalSelection(
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        let knownFilterIDs = Set(filters.map(\.id))
        for filter in filters {
            guard let defaultOption = filter.options.first else { continue }
            let selectedValue = selection[filter.id].flatMap { candidate in
                filter.options.first(where: { $0.value == candidate })?.value
            }
            result[filter.id] = selectedValue ?? defaultOption.value
        }
        // Provider-defined filters are authoritative, but preserve explicitly
        // supplied extension keys because they can still affect provider
        // semantics even when an older home response did not describe them.
        for (key, value) in selection where !knownFilterIDs.contains(key) {
            result[key] = value
        }
        return result
    }

    static func fingerprint(
        filters: [VideoFilter],
        selection: [String: String]
    ) -> [CategoryFilterValue] {
        canonicalSelection(filters: filters, selection: selection)
            .map { CategoryFilterValue(key: $0.key, value: $0.value) }
            .sorted {
                if $0.key == $1.key { return $0.value < $1.value }
                return $0.key < $1.key
            }
    }
}

struct CategoryQueryKey: Equatable, Hashable, Sendable {
    let namespace: CategoryTabNamespace
    let categoryID: String
    let canonicalFilters: [CategoryFilterValue]
    let sort: String?

    static func make(
        namespace: CategoryTabNamespace,
        category: VideoCategory,
        selection: [String: String],
        sort: String? = nil
    ) -> CategoryQueryKey {
        CategoryQueryKey(
            namespace: namespace,
            categoryID: category.id,
            canonicalFilters: CategoryFilterCanonicalizer.fingerprint(
                filters: category.filters,
                selection: selection
            ),
            sort: sort
        )
    }

    var filters: [String: String] {
        Dictionary(
            uniqueKeysWithValues: canonicalFilters.map {
                ($0.key, $0.value)
            }
        )
    }
}

struct CategoryStateKey: Equatable, Hashable, Sendable {
    let namespace: CategoryTabNamespace
    let categoryID: String
}

struct CategorySessionState: Equatable, Sendable {
    let lastActiveQuery: CategoryQueryKey
    let lastSelectedFilters: [String: String]
    let sort: String?
}

enum CategoryPaginationIssueKind: Hashable, Sendable {
    case failed, uncertain
}

struct CategoryQueryState: Equatable, Sendable {
    let key: CategoryQueryKey
    var page: VideoPage?
    var isInitialLoading: Bool
    var isRefreshing: Bool
    var isLoadingNextPage: Bool
    var paginationError: String?
    var refreshError: String?
    var lastSuccessAt: Date?
    var requestGeneration: UInt64

    var paginationIssueKind: CategoryPaginationIssueKind = .failed
    var browseAnchor: PosterBrowseAnchor? = nil
    var isAtTop = true
    var interactionRevision: UInt64 = 0
    var refreshInteractionRevision: UInt64 = 0
    var pendingRefreshPage: VideoPage? = nil
    var presentationRevision: UInt64 = 0

    var hasValidContent: Bool { page != nil }
    var lastLoadedPage: Int { page?.pagination.page ?? 0 }
    var pageCount: Int? { page?.pagination.pageCount }
    var hasMore: Bool { page?.pagination.hasMore == true }
}

struct CategoryPageRequestKey: Equatable, Hashable, Sendable {
    let queryKey: CategoryQueryKey
    let page: Int
}

enum CategoryTabRequestDecision: Equatable, Sendable {
    case cached
    case start(generation: UInt64)
    case join(generation: UInt64)
    case rejected
}

struct CategoryTabSessionStore {
    private(set) var categoryStates: [CategoryStateKey: CategorySessionState] = [:]
    private(set) var queryStates: [CategoryQueryKey: CategoryQueryState] = [:]
    private var inFlightRequests: [CategoryPageRequestKey: UInt64] = [:]
    private var nextRequestGeneration: UInt64 = 0
    private var recency: [CategoryQueryKey: UInt64] = [:]
    private var accessClock: UInt64 = 0

    mutating func recordViewport(for key: CategoryQueryKey, anchor: PosterBrowseAnchor, atTop: Bool, interacted: Bool) {
        guard var state = queryStates[key] else { return }
        state.browseAnchor = anchor
        state.isAtTop = atTop
        if interacted { state.interactionRevision &+= 1 }
        queryStates[key] = state
    }

    mutating func acceptRefresh(for key: CategoryQueryKey) -> CategoryQueryState? {
        guard var state = queryStates[key], let pending = state.pendingRefreshPage else { return nil }
        state.page = pending
        state.pendingRefreshPage = nil
        state.browseAnchor = nil
        state.isAtTop = true
        state.paginationError = nil
        state.presentationRevision &+= 1
        queryStates[key] = state
        return state
    }

    /// All filter variants share one budget. Active content is never truncated.
    mutating func trim(keeping active: CategoryQueryKey?, maximumInactive: Int = 6, maximumInactiveItems: Int = 5000) -> Set<CategoryQueryKey> {
        accessClock &+= 1
        if let active { recency[active] = accessClock }
        var candidates = queryStates.keys.filter { $0 != active }.sorted { recency[$0, default: 0] < recency[$1, default: 0] }
        var total = candidates.reduce(0) { $0 + (queryStates[$1]?.page?.items.count ?? 0) + (queryStates[$1]?.pendingRefreshPage?.items.count ?? 0) }
        var removed = Set<CategoryQueryKey>()
        while candidates.count > maximumInactive || total > maximumInactiveItems {
            guard !candidates.isEmpty else { break }
            let key = candidates.removeFirst()
            total -= (queryStates[key]?.page?.items.count ?? 0) + (queryStates[key]?.pendingRefreshPage?.items.count ?? 0)
            invalidateQuery(key)
            removed.insert(key)
        }
        return removed
    }

    mutating func queryKey(
        namespace: CategoryTabNamespace,
        category: VideoCategory,
        requestedFilters: [String: String]?,
        sort: String? = nil
    ) -> CategoryQueryKey {
        let categoryKey = CategoryStateKey(
            namespace: namespace,
            categoryID: category.id
        )
        let selection = requestedFilters
            ?? categoryStates[categoryKey]?.lastSelectedFilters
            ?? [:]
        let key = CategoryQueryKey.make(
            namespace: namespace,
            category: category,
            selection: selection,
            sort: sort
        )
        categoryStates[categoryKey] = CategorySessionState(
            lastActiveQuery: key,
            lastSelectedFilters: key.filters,
            sort: sort
        )
        return key
    }

    func state(for key: CategoryQueryKey) -> CategoryQueryState? {
        queryStates[key]
    }

    func lastQuery(
        namespace: CategoryTabNamespace,
        categoryID: String
    ) -> CategoryQueryKey? {
        categoryStates[
            CategoryStateKey(namespace: namespace, categoryID: categoryID)
        ]?.lastActiveQuery
    }

    func ownsRequest(
        for key: CategoryQueryKey,
        page: Int,
        generation: UInt64
    ) -> Bool {
        inFlightRequests[
            CategoryPageRequestKey(queryKey: key, page: page)
        ] == generation && queryStates[key]?.requestGeneration == generation
    }

    mutating func beginRequest(
        for key: CategoryQueryKey,
        page: Int,
        forceRefresh: Bool
    ) -> CategoryTabRequestDecision {
        guard page >= 1, !forceRefresh || page == 1 else {
            return .rejected
        }
        if page == 1,
           !forceRefresh,
           queryStates[key]?.hasValidContent == true {
            return .cached
        }

        let requestKey = CategoryPageRequestKey(queryKey: key, page: page)
        if !forceRefresh,
           let generation = inFlightRequests[requestKey] {
            return .join(generation: generation)
        }

        if page > 1 {
            guard queryStates[key]?.isRefreshing != true,
                  queryStates[key]?.pendingRefreshPage == nil,
                  let current = queryStates[key]?.page,
                  current.pagination.page == page - 1,
                  current.pagination.hasMore else {
                return .rejected
            }
        }

        if forceRefresh {
            inFlightRequests = inFlightRequests.filter {
                $0.key.queryKey != key
            }
        }
        nextRequestGeneration &+= 1
        let generation = nextRequestGeneration
        var state = queryStates[key] ?? CategoryQueryState(
            key: key,
            page: nil,
            isInitialLoading: false,
            isRefreshing: false,
            isLoadingNextPage: false,
            paginationError: nil,
            refreshError: nil,
            lastSuccessAt: nil,
            requestGeneration: 0
        )
        state.requestGeneration = generation
        if page == 1 {
            accessClock &+= 1
            recency[key] = accessClock
            state.isInitialLoading = state.page == nil
            state.isRefreshing = state.page != nil
            state.isLoadingNextPage = false
            state.refreshError = nil
            state.refreshInteractionRevision = state.interactionRevision
            state.pendingRefreshPage = nil
        } else {
            state.isLoadingNextPage = true
            state.paginationError = nil
            state.paginationIssueKind = .failed
        }
        queryStates[key] = state
        inFlightRequests[requestKey] = generation
        return .start(generation: generation)
    }

    @discardableResult
    mutating func completeRequest(
        for key: CategoryQueryKey,
        page: Int,
        generation: UInt64,
        loaded: VideoPage,
        at date: Date = Date()
    ) -> CategoryQueryState? {
        let requestKey = CategoryPageRequestKey(queryKey: key, page: page)
        guard inFlightRequests[requestKey] == generation,
              var state = queryStates[key],
              state.requestGeneration == generation else {
            return nil
        }
        inFlightRequests[requestKey] = nil
        var knownIDs = Set<String>()
        if page > 1 { knownIDs = Set(state.page?.items.map(\.id) ?? []) }
        let noProgress = !loaded.items.contains { !knownIDs.contains($0.id) }
        let confirmedEnd = loaded.pagination.continuation == .end
            || (loaded.pagination.continuation == nil && !loaded.pagination.hasMore)
        if noProgress && !confirmedEnd {
            state.isInitialLoading = false
            state.isRefreshing = false
            state.isLoadingNextPage = false
            state.paginationIssueKind = .uncertain
            let message = L10n.string("pagination.no-progress", fallback: "The provider returned no new titles. Automatic loading is paused; you can retry.")
            if page > 1 { state.paginationError = message }
            else { state.refreshError = message }
            queryStates[key] = state
            return state
        }
        let merged = VideoPageMerger.merge(
            current: page > 1 ? state.page : nil,
            loaded: loaded,
            requestedPage: page,
            knownIDs: &knownIDs
        )
        if page == 1, state.page != nil,
           !state.isAtTop || state.interactionRevision != state.refreshInteractionRevision {
            state.pendingRefreshPage = merged
        } else {
            if page == 1, state.page != nil { state.presentationRevision &+= 1; state.browseAnchor = nil }
            state.page = merged
        }
        state.isInitialLoading = false
        state.isRefreshing = false
        state.isLoadingNextPage = false
        state.paginationError = nil
        state.refreshError = nil
        state.lastSuccessAt = date
        queryStates[key] = state
        return state
    }

    @discardableResult
    mutating func failRequest(
        for key: CategoryQueryKey,
        page: Int,
        generation: UInt64,
        message: String?,
        isCancellation: Bool,
        issueKind: CategoryPaginationIssueKind = .failed
    ) -> CategoryQueryState? {
        let requestKey = CategoryPageRequestKey(queryKey: key, page: page)
        guard inFlightRequests[requestKey] == generation,
              var state = queryStates[key],
              state.requestGeneration == generation else {
            return nil
        }
        inFlightRequests[requestKey] = nil
        if page > 1 {
            state.isLoadingNextPage = false
            state.paginationError = isCancellation ? nil : message
            state.paginationIssueKind = issueKind
        } else {
            state.isInitialLoading = false
            state.isRefreshing = false
            state.refreshError = isCancellation ? nil : message
        }
        queryStates[key] = state
        return state
    }

    mutating func invalidateRequests(for key: CategoryQueryKey) {
        inFlightRequests = inFlightRequests.filter {
            $0.key.queryKey != key
        }
    }

    mutating func invalidateQuery(_ key: CategoryQueryKey) {
        queryStates[key] = nil
        recency[key] = nil
        invalidateRequests(for: key)
    }

    mutating func invalidateRevisions(
        configurationID: UUID,
        keeping revision: String
    ) {
        categoryStates = categoryStates.filter {
            $0.key.namespace.configurationID != configurationID
                || $0.key.namespace.configurationRevision == revision
        }
        queryStates = queryStates.filter {
            $0.key.namespace.configurationID != configurationID
                || $0.key.namespace.configurationRevision == revision
        }
        recency = recency.filter { queryStates[$0.key] != nil }
        inFlightRequests = inFlightRequests.filter {
            $0.key.queryKey.namespace.configurationID != configurationID
                || $0.key.queryKey.namespace.configurationRevision == revision
        }
    }

    mutating func rebindRuntimeContent(
        configurationID: UUID,
        to endpoint: URL
    ) {
        for (key, var state) in queryStates
        where key.namespace.configurationID == configurationID {
            if let page = state.page {
                state.page = NodeRuntimeContentTransport.rebind(
                    page,
                    to: endpoint
                )
            }
            if let pending = state.pendingRefreshPage { state.pendingRefreshPage = NodeRuntimeContentTransport.rebind(pending, to: endpoint) }
            queryStates[key] = state
        }
    }

    mutating func removeAll() {
        categoryStates.removeAll()
        queryStates.removeAll()
        inFlightRequests.removeAll()
        recency.removeAll()
    }
}

enum CategoryTabPublicationPolicy {
    static func shouldPublish(
        requestKey: CategoryQueryKey,
        activeKey: CategoryQueryKey?,
        currentNamespace: CategoryTabNamespace?
    ) -> Bool {
        requestKey == activeKey && requestKey.namespace == currentNamespace
    }
}

enum CategoryReloadPresentationPolicy {
    static func shouldPreserveCurrentPage(
        requestedPage: Int,
        requestedCategoryID: String,
        currentCategoryID: String?,
        hasCurrentPage: Bool
    ) -> Bool {
        requestedPage == 1
            && requestedCategoryID == currentCategoryID
            && hasCurrentPage
    }
}

enum HomeAutomaticRefreshPolicy {
    static func allowsRefresh(
        hasCompletedStartup: Bool,
        selectedSection: AppSection,
        isHomeSearchPresented: Bool
    ) -> Bool {
        hasCompletedStartup
            && selectedSection == .home
            && !isHomeSearchPresented
    }
}

struct SearchFolderNavigationContext: Equatable, Sendable {
    let navigationMode: NodeSiteNavigationMode
    let sourceSiteKey: String
    let configurationID: UUID?
    let configurationRevision: String?
    let nodeSiteIdentity: String?

    static func legacy(siteKey: String) -> Self {
        Self(
            navigationMode: .detail,
            sourceSiteKey: siteKey,
            configurationID: nil,
            configurationRevision: nil,
            nodeSiteIdentity: nil
        )
    }

    func isCurrent(
        configurationID currentConfigurationID: UUID?,
        configurationRevision currentConfigurationRevision: String?,
        nodeSiteIdentity currentNodeSiteIdentity: String?
    ) -> Bool {
        guard let configurationID else {
            // Legacy in-memory folders did not carry a revision. They retain
            // detail navigation and therefore cannot accidentally acquire
            // CatPaw discovery semantics.
            return navigationMode == .detail
        }
        guard configurationID == currentConfigurationID,
              configurationRevision == currentConfigurationRevision else {
            return false
        }
        if let nodeSiteIdentity {
            return nodeSiteIdentity == currentNodeSiteIdentity
        }
        return true
    }
}

struct SearchFolderPage: Identifiable, Equatable {
    let id: UUID
    let folder: VideoSummary
    let navigationContext: SearchFolderNavigationContext
    var items: [VideoSummary]
    var pagination: Pagination?
    var isLoading: Bool
    var errorMessage: String?
    var paginationIssueKind: CategoryPaginationIssueKind = .failed
    var failedPage: Int?
    var requestID = UUID()

    init(
        folder: VideoSummary,
        navigationContext: SearchFolderNavigationContext? = nil
    ) {
        id = UUID()
        self.folder = folder
        self.navigationContext = navigationContext
            ?? .legacy(siteKey: folder.siteKey)
        items = []
        pagination = nil
        isLoading = true
        errorMessage = nil
    }
}

enum SearchFolderOrigin: Equatable {
    case home
    case searchResults
}

enum SearchFolderBackDestination: Equatable {
    case parentFolder
    case home
    case searchResults
}

enum SearchFolderNavigationPolicy {
    static func backDestination(
        pathCount: Int,
        origin: SearchFolderOrigin?
    ) -> SearchFolderBackDestination? {
        guard pathCount > 0 else { return nil }
        if pathCount > 1 { return .parentFolder }
        switch origin {
        case .home:
            return .home
        case .searchResults, .none:
            // Old in-memory state may not have an origin. Closing only the
            // Folder is the safest compatibility fallback because it keeps
            // the surrounding search results visible.
            return .searchResults
        }
    }

    static func backTitle(
        pathCount: Int,
        origin: SearchFolderOrigin?
    ) -> String {
        switch backDestination(pathCount: pathCount, origin: origin) {
        case .parentFolder:
            return L10n.string("navigation.up", fallback: "Up One Level")
        case .home:
            return L10n.string("navigation.back-browse", fallback: "Back to Browse")
        case .searchResults:
            return L10n.string("navigation.back-search-results", fallback: "Back to Search Results")
        case .none:
            return L10n.string("navigation.back-browse", fallback: "Back to Browse")
        }
    }

    static func backHelp(
        pathCount: Int,
        origin: SearchFolderOrigin?
    ) -> String {
        switch backDestination(pathCount: pathCount, origin: origin) {
        case .parentFolder:
            return L10n.string("navigation.back-parent-folder", fallback: "Back to Parent Folder")
        case .home:
            return L10n.string("navigation.close-folder-browse", fallback: "Close this folder and return to the previous Browse category")
        case .searchResults:
            return L10n.string("navigation.close-folder-search", fallback: "Close this folder and return to all search results")
        case .none:
            return L10n.string("navigation.back-browse", fallback: "Back to Browse")
        }
    }
}

struct DetailHomeSearchReturnSnapshot: Equatable {
    let selectedSiteKey: String?
    let folderPath: [SearchFolderPage]
    let folderOrigin: SearchFolderOrigin?
}

enum DetailHomeSearchReturnPolicy {
    static func capture(
        isHomeSearchPresented: Bool,
        selectedSiteKey: String?,
        folderPath: [SearchFolderPage],
        folderOrigin: SearchFolderOrigin?
    ) -> DetailHomeSearchReturnSnapshot? {
        guard isHomeSearchPresented else { return nil }
        return DetailHomeSearchReturnSnapshot(
            selectedSiteKey: selectedSiteKey,
            folderPath: folderPath,
            folderOrigin: folderOrigin
        )
    }
}

enum VideoPageMerger {
    static func merge(
        current: VideoPage?,
        loaded: VideoPage,
        requestedPage: Int
    ) -> VideoPage {
        var knownIDs = Set(current?.items.map(\.id) ?? [])
        return merge(current: current, loaded: loaded, requestedPage: requestedPage, knownIDs: &knownIDs)
    }

    static func merge(
        current: VideoPage?,
        loaded: VideoPage,
        requestedPage: Int,
        knownIDs: inout Set<String>
    ) -> VideoPage {
        var newItems: [VideoSummary] = []
        newItems.reserveCapacity(loaded.items.count)
        for item in loaded.items where knownIDs.insert(item.id).inserted {
            newItems.append(item)
        }

        var pagination = loaded.pagination
        pagination.page = requestedPage
        if pagination.continuation == nil, let pageCount = pagination.pageCount {
            pagination.hasMore = requestedPage < pageCount
        }

        let reachedEnd = pagination.continuation == .end
            || (pagination.continuation == nil && (loaded.items.isEmpty
                || (current != nil && newItems.isEmpty)))
        if reachedEnd {
            pagination.pageCount = min(
                pagination.pageCount ?? requestedPage,
                requestedPage
            )
            pagination.hasMore = false
        }

        return VideoPage(
            items: (current?.items ?? []) + newItems,
            pagination: pagination
        )
    }
}

enum PlayerEpisodeAdvancePolicy {
    static func orderedEpisodes(in episodes: [PlayEpisode], categoryName: String? = nil) -> [PlayEpisode] {
        var values: [(item: PlayEpisode, semantics: PlaybackResourceSemantics)] = []
        for (episode, value) in zip(episodes, PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)) {
            guard !PlaybackResourceAnalyzer.isNonVideoResource(episode) else { continue }
            let contextual = value.form == .series && value.evidence == .contextual && value.role == .main
            if value.hasReliableEpisode || contextual { values.append((episode, value)) }
        }
        // Unknown seasons cannot be interleaved with explicitly numbered seasons.
        let hasSeason = values.contains { $0.semantics.season != nil }
        let lacksSeason = values.contains { $0.semantics.season == nil }
        if hasSeason && lacksSeason { return [] }
        let keys: [String] = values.map { "\($0.semantics.season ?? -1):\($0.semantics.episode!)" }
        guard Set(keys).count == keys.count else { return [] }
        values.sort { lhs, rhs in
            let leftSeason = lhs.semantics.season ?? -1, rightSeason = rhs.semantics.season ?? -1
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            return lhs.semantics.episode! < rhs.semantics.episode!
        }
        return values.map(\.item)
    }

    static func versionKey(_ episode: PlayEpisode) -> String {
        PlaybackResourceAnalyzer.analyze(episode).versionLabels.joined(separator: "|")
    }

    static func versionOrders(in episodes: [PlayEpisode], categoryName: String? = nil) -> [String: [PlayEpisode]] {
        let semantics = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)
        var groups: [String: [PlayEpisode]] = [:]
        for (episode, value) in zip(episodes, semantics) {
            guard !PlaybackResourceAnalyzer.isNonVideoResource(episode), value.form == .series,
                  value.role == .main, value.episode != nil, value.endEpisode == nil,
                  value.evidence != .conflict else { continue }
            // Pass inferred type only to local queue analysis, never mutate source metadata.
            groups[value.versionLabels.joined(separator: "|") , default: []].append(episode)
        }
        return groups.mapValues { orderedEpisodes(in: $0, categoryName: "series") }
    }

    static func nextEpisode(in episodes: [PlayEpisode], currentEpisodeID: String,
                            enabled: Bool, categoryName: String? = nil) -> PlayEpisode? {
        let all = orderedEpisodes(in: episodes, categoryName: categoryName)
        let current = episodes.first { $0.id == currentEpisodeID }
        let versions = versionOrders(in: episodes, categoryName: categoryName)
        let ordered = (all.isEmpty || versions.count > 1) ? (current.flatMap {
            versions[versionKey($0)]
        } ?? []) : all
        guard enabled, let index = ordered.firstIndex(where: { $0.id == currentEpisodeID }),
              ordered.indices.contains(index + 1) else { return nil }
        return ordered[index + 1]
    }
}

enum PlayerSeekConfirmationPolicy {
    /// `absolute+keyframes` is deliberately imprecise: mpv may restart from a
    /// keyframe well before the requested timestamp. Native seek completion is
    /// therefore authoritative; comparing the reported position with a small
    /// fixed tolerance turns a successful long-GOP seek into a false failure.
    static func hasCompleted(snapshot: PlayerSnapshot) -> Bool {
        !snapshot.isSeeking
    }
}

enum PlaybackRequestOwnershipPolicy {
    static func accepts(
        requestID: UUID?,
        activeRequestID: UUID
    ) -> Bool {
        requestID == activeRequestID
    }
}

enum SiteProviderRoutingPolicy {
    private struct ArtifactReference {
        let original: String
        let artifact: String
        let checksum: String?

        init?(_ reference: String) {
            let trimmed = reference.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return nil }

            let marker = ";md5;"
            if let range = trimmed.range(
                of: marker,
                options: [.caseInsensitive]
            ) {
                let artifact = String(trimmed[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artifact.isEmpty else { return nil }
                self.artifact = artifact
                let checksum = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.checksum = checksum
                original = artifact + marker + checksum
            } else {
                self.original = trimmed
                artifact = trimmed
                checksum = nil
            }
        }

        var hasValidatedContentChecksum: Bool {
            guard let checksum,
                  [32, 64].contains(checksum.count) else {
                return false
            }
            return checksum.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                    .contains($0)
            }
        }
    }

    private static let localJavaScriptExtensions = Set([
        "js", "mjs", "cjs"
    ])

    static func hasExclusiveNodeRuntimeOwnership(
        _ site: SiteConfiguration
    ) -> Bool {
        site.extra["okNodeRuntime"] == .bool(true)
    }

    /// Android is a compatibility provider only for an actual Java/Dex
    /// artifact. A `csp_` class name alone is not provenance: Node and local
    /// JavaScript sites must fail within their own provider boundary instead
    /// of falling through to Android when their runtime is unavailable.
    static func javaDexJarReference(
        site: SiteConfiguration,
        configurationSpider: String?,
        baseURL: URL?
    ) -> String? {
        guard site.type == 3,
              site.api.hasPrefix("csp_"),
              !hasExclusiveNodeRuntimeOwnership(site),
              localJavaScriptURL(
                  site: site,
                  configurationSpider: configurationSpider,
                  baseURL: baseURL
              ) == nil,
              let reference = site.jar ?? configurationSpider,
              let parsedReference = ArtifactReference(reference) else {
            return nil
        }
        guard let resolved = try? ResourceResolver.resolve(
            parsedReference.artifact,
            relativeTo: baseURL
        ) else {
            return nil
        }
        let extensionName = resolved.pathExtension.lowercased()
        guard !localJavaScriptExtensions.contains(extensionName) else {
            return nil
        }
        let hasExplicitJavaExtension = ["jar", "dex"].contains(extensionName)
        // TVBox configurations commonly disguise a Java artifact as `.jpg`
        // while binding its bytes with `;md5;<digest>`. Treat that
        // content-addressed form as Java/Dex provenance too. Node-owned and
        // local JavaScript sites have already been excluded above, so an
        // arbitrary URL still cannot make a non-Android provider fall through
        // to the Bridge.
        let hasContentAddressedArtifact =
            parsedReference.hasValidatedContentChecksum
        guard hasExplicitJavaExtension || hasContentAddressedArtifact else {
            return nil
        }
        return parsedReference.original
    }

    static func localJavaScriptURL(
        site: SiteConfiguration,
        configurationSpider: String?,
        baseURL: URL?
    ) -> URL? {
        var references: [String] = []
        if let script = site.extra["script"]?.stringValue {
            references.append(script)
        }
        if let script = site.ext?.objectValue?["script"]?.stringValue {
            references.append(script)
        }
        references.append(site.api)
        if let configurationSpider {
            references.append(configurationSpider)
        }
        for reference in references {
            guard let parsedReference = ArtifactReference(reference) else {
                continue
            }
            if let resolved = try? ResourceResolver.resolve(
                parsedReference.artifact,
                relativeTo: baseURL
            ), localJavaScriptExtensions.contains(
                resolved.pathExtension.lowercased()
            ),
               ["http", "https"].contains(
                   resolved.scheme?.lowercased() ?? ""
               ) {
                return resolved
            }
        }
        return nil
    }
}

struct PlayerSubtitleTrackPreference: Equatable {
    let id: Int
    let title: String
    let language: String?

    init(track: MediaTrack) {
        id = track.id
        title = track.title
        language = track.language
    }

    init?(setting: JSONValue) {
        guard case .object(let object) = setting,
              case .integer(let identifier)? = object["id"],
              case .string(let title)? = object["title"] else {
            return nil
        }
        id = Int(identifier)
        self.title = title
        language = object["language"]?.stringValue
    }

    var settingValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .integer(Int64(id)),
            "title": .string(title)
        ]
        if let language, !language.isEmpty {
            object["language"] = .string(language)
        }
        return .object(object)
    }

    static func matchingTrack(
        in tracks: [MediaTrack],
        preference: PlayerSubtitleTrackPreference
    ) -> MediaTrack? {
        let subtitleTracks = tracks.filter { $0.type == .subtitle }
        let preferredTitle = normalized(preference.title)
        let preferredLanguage = normalized(preference.language ?? "")

        if let exact = subtitleTracks.first(where: {
            normalized($0.title) == preferredTitle
                && normalized($0.language ?? "") == preferredLanguage
        }) {
            return exact
        }
        if !preferredLanguage.isEmpty,
           let sameLanguage = subtitleTracks.first(where: {
               normalized($0.language ?? "") == preferredLanguage
           }) {
            return sameLanguage
        }
        return subtitleTracks.first { $0.id == preference.id }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ActivePlaybackContext {
    let configurationID: UUID
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var media: ResolvedMedia
    var playbackResult: SitePlaybackResult?
    var providerResourceReference: PlaybackResourceReference?
    var replacedHistoryRecord: HistoryRecord? = nil
    var requestID: UUID? = nil
}

struct PlaybackEndingSkipPrompt: Equatable {
    var secondsUntilBoundary: Int
    var willAdvanceAutomatically: Bool
}

private struct PlaybackSkipSessionState {
    var episodeSessionID: UUID
    var identity: PlaybackSkipRuleIdentity
    var historyRecordID: String
    var lineRule: PlaybackSkipRule?
    var episodeRule: PlaybackSkipRule?
    var effectiveRule: EffectivePlaybackSkipRule
    var openingSkipSuppressed = false
    var endingSkipSuppressed = false
    var observedPlaybackBeforeEndingPrompt = false
}

private enum EpisodeAdvanceReason: Equatable {
    case naturalEnd
    case endingSkip
    case manualEndingSkip

    var requiresAutoPlay: Bool {
        self != .manualEndingSkip
    }
}

enum DetailPageLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
    case needsAuthorization

    var message: String? {
        switch self {
        case .failed(let message): return message
        case .needsAuthorization: return L10n.string("detail.authorization.pending", fallback: "Complete authorization, then retry loading details.")
        case .loading, .loaded: return nil
        }
    }
}

struct HistoryPlaybackChoice: Identifiable, Equatable {
    let id: UUID
    let detail: VideoDetail
    let source: PlaySource
    let episode: PlayEpisode

    init(
        id: UUID = UUID(),
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode
    ) {
        self.id = id
        self.detail = detail
        self.source = source
        self.episode = episode
    }

    var title: String {
        detail.summary.title
    }

    var subtitle: String {
        "\(source.name) · \(episode.name)"
    }
}

/// Keeps only explicitly reusable media. A live URL/TTL is not proof that a
/// mutable provider proxy still returns the original file.
struct HistoryPlaybackSessionCache {
    static let defaultLifetime: TimeInterval = 2 * 60 * 60
    static let defaultCapacity = 24

    private struct Entry {
        var playback: ActivePlaybackContext
        var lastUsedAt: Date
    }

    private var entries: [HistoryRecord.ID: Entry] = [:]
    let lifetime: TimeInterval
    let capacity: Int

    init(
        lifetime: TimeInterval = defaultLifetime,
        capacity: Int = defaultCapacity
    ) {
        self.lifetime = max(0, lifetime)
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    mutating func store(
        _ playback: ActivePlaybackContext,
        for recordIDs: Set<HistoryRecord.ID>,
        now: Date = Date()
    ) {
        prune(now: now)
        guard Self.canReuse(playback, now: now) else {
            remove(recordIDs)
            return
        }
        for recordID in recordIDs {
            entries[recordID] = Entry(
                playback: playback,
                lastUsedAt: now
            )
        }
        while entries.count > capacity,
              let oldest = entries.min(by: {
                  $0.value.lastUsedAt < $1.value.lastUsedAt
              })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func playback(
        for recordID: HistoryRecord.ID,
        now: Date = Date()
    ) -> ActivePlaybackContext? {
        prune(now: now)
        guard var entry = entries[recordID] else { return nil }
        guard Self.canReuse(entry.playback, now: now) else {
            entries.removeValue(forKey: recordID)
            return nil
        }
        entry.lastUsedAt = now
        entries[recordID] = entry
        return entry.playback
    }

    mutating func remove(_ recordID: HistoryRecord.ID) {
        entries.removeValue(forKey: recordID)
    }

    mutating func remove(_ recordIDs: Set<HistoryRecord.ID>) {
        for recordID in recordIDs {
            entries.removeValue(forKey: recordID)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    static func canReuse(_ playback: ActivePlaybackContext, now: Date = Date()) -> Bool {
        if let session = playback.playbackResult?.mediaSession {
            return session.historyReusePolicy == .immutableResource
                && session.resourceReference.stability == .providerStable
                && session.resourceReference.configurationIdentity == playback.configurationID.uuidString.lowercased()
                && session.resourceReference.siteIdentity == playback.detail.summary.siteKey
                && session.resourceReference.sourceIdentity == playback.source.stableIdentity
                && session.resourceReference.episodeIdentity == playback.episode.stableIdentity
                && playback.providerResourceReference == session.resourceReference
                && (session.expiresAt.map { $0 > now } ?? false)
                && (session.resourceReference.expiresAt.map { $0 > now } ?? true)
                && session.mediaURL == playback.media.url.absoluteString
        }
        return playback.providerResourceReference == nil
            && PlaybackPersistencePolicy.sanitizedMediaReference(playback.media.url.absoluteString) != nil
    }

    private mutating func prune(now: Date) {
        entries = entries.filter {
            now.timeIntervalSince($0.value.lastUsedAt) <= lifetime
        }
    }
}

private struct PlaybackHistoryWrite {
    let record: HistoryRecord
    let incognito: Bool
    let requestID: UUID?
    let replacedRecord: HistoryRecord?
    let sessionID: UUID
}

enum PlaybackConfigurationOwnershipPolicy {
    static func capturedConfigurationID(
        requested: UUID?,
        history: UUID?,
        current: UUID?
    ) -> UUID? {
        requested ?? history ?? current
    }

    static func canBeginPlayback(
        captured: UUID,
        current: UUID?
    ) -> Bool {
        captured == current
    }

    static func historyOwner(
        captured: UUID,
        current _: UUID?
    ) -> UUID {
        captured
    }
}

struct NodePlaybackRecoveryCheckpoint: Equatable, Sendable {
    let position: TimeInterval
    let paused: Bool

    init(position: TimeInterval, paused: Bool) {
        self.position = position.isFinite ? max(0, position) : 0
        self.paused = paused
    }
}

struct NodePlaybackRecoveryGate {
    private var usedRequestID: UUID?
    mutating func reset() { usedRequestID = nil }
    mutating func claim(_ requestID: UUID) -> Bool {
        guard usedRequestID != requestID else { return false }
        usedRequestID = requestID
        return true
    }
}

private struct PendingCloudPlayback {
    let requestID: UUID
    let configurationID: UUID
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var origin: PlaybackRequestOrigin = .direct
    var recoveryCheckpoint: NodePlaybackRecoveryCheckpoint? = nil
}

private struct TransferMediaLease: Equatable {
    let mediaInstanceID: UUID
    let playbackSessionID: UUID
    let requestGeneration: UInt64
    let receipt: TransferReceipt
}

enum TransferReceiptOwnershipPolicy {
    static func accepts(
        _ receipt: TransferReceipt,
        requestID: UUID,
        requestGeneration: UInt64
    ) -> Bool {
        receipt.requestID == requestID
            && receipt.requestGeneration == requestGeneration
    }
}

private enum PendingCloudOperation {
    case playback(PendingCloudPlayback)
    case detail(VideoSummary)
    case homeAction(SiteActionItem)
    case siteAction(
        action: String,
        title: String,
        tag: String?
    )

    var pendingPlayback: PendingCloudPlayback? {
        guard case .playback(let playback) = self else { return nil }
        return playback
    }

    var playbackRequestID: UUID? {
        pendingPlayback?.requestID
    }

    var initialSemantic: ConfigurationInteractionSemantic {
        switch self {
        case .playback:
            return .legacy
        case .siteAction(_, _, let tag):
            return ConfigurationInteractionClassificationPolicy
                .legacySemantic(tag: tag)
        case .detail(let summary):
            return ConfigurationInteractionClassificationPolicy
                .legacySemantic(tag: summary.tag)
        case .homeAction(let item):
            return ConfigurationInteractionClassificationPolicy
                .legacySemantic(tag: item.tag)
        }
    }

    var interactionKind: CloudInteractionKind {
        ConfigurationInteractionClassificationPolicy.interactionKind(
            for: initialSemantic
        )
    }

    var actionIdentifier: String? {
        switch self {
        case .playback:
            return nil
        case .detail(let summary):
            return summary.action
        case .homeAction(let item):
            return item.action
        case .siteAction(let action, _, _):
            return action
        }
    }
}

struct TVBoxConfigurationRefreshTarget: Equatable {
    let sourceIdentity: HomeContentIdentity
    let categoryID: String?
    let filters: [String: String]
    let categoryPresentationID: UUID?
}

struct PendingTVBoxConfigurationAction: Equatable {
    let id: UUID
    let siteKey: String
    let route: HomeFunctionRoute
    let title: String
    let refreshTarget: TVBoxConfigurationRefreshTarget
}

private struct CloudAuthorizationContext {
    let sourceIdentity: HomeContentIdentity
    let operationID: UUID
    let requestGeneration: UInt64
    /// Generation of the user-facing action feedback session. Playback and
    /// detail requests do not allocate one.
    let actionStatusGeneration: UInt64?
    /// Exact capability binding returned by the Bridge for this interaction.
    /// The host stores it only for the live prompt and returns it verbatim;
    /// source/provider labels never select a credential target.
    var providerOwnerID: String?
    var providerHandle: InteractionHandle?
    var providerInteraction: ConfigurationInteraction?
    var operation: PendingCloudOperation
    var hasObservedPrompt: Bool
    var lastObservedRevision: Int?
    var configurationRefreshTarget: TVBoxConfigurationRefreshTarget? = nil
}

enum PlaybackRequestOrigin: Equatable, Sendable {
    case direct
    case history(HistoryRecord)

    var historyRecord: HistoryRecord? {
        guard case .history(let record) = self else { return nil }
        return record
    }

    var isHistory: Bool {
        historyRecord != nil
    }
}

/// Keeps every value used by one resolver/load attempt on the same provider
/// snapshot. In particular, a same-resource refresh must not combine its new
/// episode or request headers with the expired values from the first attempt.
struct PlaybackResolutionAttemptContext: Equatable, Sendable {
    let detail: VideoDetail
    let source: PlaySource
    let episode: PlayEpisode
    let result: SitePlaybackResult
    let danmakuContext: DanmakuPlaybackContext?

    init(
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        result: SitePlaybackResult,
        danmakuContext: DanmakuPlaybackContext? = nil
    ) {
        self.detail = detail
        self.source = source
        self.episode = episode
        self.result = result
        self.danmakuContext = danmakuContext
    }

    func resolutionRequest(
        configuredParsers: [ParseConfiguration],
        maximumAttempts: Int
    ) -> PlaybackResolutionRequest {
        // A provider-final result is already the provider's authenticated
        // media request. Generic parsers cannot renew that capability and
        // must not consume the retry budget that belongs to the provider's
        // same-resource refresh. `providerPreflight` still validates bytes in
        // PlaybackResolver; it merely forbids unrelated parser rewriting.
        let eligibleParsers = result.validationPolicy == .preflight
            ? configuredParsers
            : []
        return PlaybackResolutionRequest(
            candidates: [
                PlaybackCandidate(
                    siteKey: detail.summary.siteKey,
                    siteName: detail.summary.siteName,
                    sourceName: source.name,
                    episodeName: episode.name,
                    result: result,
                    danmakuContext: danmakuContext
                )
            ],
            parsers: eligibleParsers,
            maximumAttempts: maximumAttempts
        )
    }
}

private struct PlayerEpisodePresentationCacheKey: Equatable, Sendable {
    let categoryName: String?
    let source: PlaySource
    let videoID: String
    let sourceID: String
    let episodeCount: Int
    let firstEpisodeID: String?
    let lastEpisodeID: String?
}

private struct PlayerEpisodePresentationCache {
    let key: PlayerEpisodePresentationCacheKey
    let values: [EpisodePresentation]
    let valuesByEpisodeID: [String: EpisodePresentation]
    let playbackOrder: [PlayEpisode]
    let versionOrders: [String: [PlayEpisode]]
}

private enum PendingNodeOperation {
    case category(
        identity: HomeContentIdentity,
        siteKey: String,
        id: String,
        page: Int,
        filters: [String: String]
    )
    case detail(identity: HomeContentIdentity, summary: VideoSummary)
    case siteAction(
        identity: HomeContentIdentity,
        action: String,
        title: String
    )
    case homeAction(identity: HomeContentIdentity, item: SiteActionItem)
    case playback(
        identity: HomeContentIdentity,
        playback: PendingCloudPlayback
    )

    var sourceIdentity: HomeContentIdentity {
        switch self {
        case .category(let identity, _, _, _, _),
             .detail(let identity, _),
             .siteAction(let identity, _, _),
             .homeAction(let identity, _),
             .playback(let identity, _):
            return identity
        }
    }

    var requiresSelectedHomeSource: Bool {
        switch self {
        case .category, .siteAction, .homeAction:
            return true
        case .detail, .playback:
            return false
        }
    }

    var playbackRequestID: UUID? {
        guard case .playback(_, let playback) = self else { return nil }
        return playback.requestID
    }

    var presentationTarget: CloudAuthorizationPresentationTarget {
        switch self {
        case .detail:
            return .detail
        case .playback(_, let playback):
            return .player(requestID: playback.requestID)
        case .category, .siteAction, .homeAction:
            return .mainWindow
        }
    }
}

private struct PendingNodePlaybackConfigurationFallback {
    let authorization: NodeWebAuthorizationRequired
    let operation: PendingNodeOperation
}

private enum AppStateTiming {
    static let automaticConfigurationRefreshInterval: TimeInterval = 30 * 60
}

private enum HomePreparationLoadBehavior: Equatable {
    case none
    case background
    case awaited
}

private enum LiveSettingsKey {
    static let favoriteChannels = "live.favoriteChannels"
    static let deletedChannels = "live.deletedChannels"
}

enum LiveChannelNavigationPolicy {
    static func normalizedChannels(
        _ channels: [LiveChannel],
        including currentChannel: LiveChannel
    ) -> [LiveChannel] {
        var seenIDs = Set<String>()
        var values = channels.filter { channel in
            !channel.streams.isEmpty && seenIDs.insert(channel.id).inserted
        }
        if !currentChannel.streams.isEmpty,
           seenIDs.insert(currentChannel.id).inserted {
            values.append(currentChannel)
        }
        return values
    }

    static func adjacentChannel(
        in channels: [LiveChannel],
        currentChannelID: String,
        offset: Int
    ) -> LiveChannel? {
        guard channels.count > 1,
              offset != 0,
              let currentIndex = channels.firstIndex(where: {
                  $0.id == currentChannelID
              }) else {
            return nil
        }
        let normalizedOffset = offset % channels.count
        let targetIndex = (
            currentIndex + normalizedOffset + channels.count
        ) % channels.count
        return channels[targetIndex]
    }
}

enum LiveChannelDeletionPolicy {
    static func identifier(sourceID: UUID, channelID: String) -> String {
        "\(sourceID.uuidString)::\(channelID)"
    }

    static func contains(
        _ identifiers: Set<String>,
        sourceID: UUID,
        channelID: String
    ) -> Bool {
        identifiers.contains(
            identifier(sourceID: sourceID, channelID: channelID)
        )
    }

    static func removingSource(
        _ sourceID: UUID,
        from identifiers: Set<String>
    ) -> Set<String> {
        let prefix = "\(sourceID.uuidString)::"
        return identifiers.filter { !$0.hasPrefix(prefix) }
    }
}

/// One accepted publication. Never reconstruct this context from a SwiftUI body
/// or use a new catalog to resolve an old playback/menu key.
final class AcceptedImportedCatalog: CustomStringConvertible, CustomReflectable {
    let sourceID: UUID
    let playlist: LivePlaylist
    let routeContext: ImportedRouteContext?
    private let channelsByID: [String: [LiveChannel]]

    init(sourceID: UUID, playlist: LivePlaylist) {
        self.sourceID = sourceID
        self.playlist = playlist
        let channels = playlist.groups.flatMap(\.channels)
        channelsByID = Dictionary(grouping: channels, by: \.id)
        routeContext = ImportedRouteContext(
            source: .imported(sourceID), streams: channels.flatMap(\.streams)
        )
    }

    func contains(_ channel: LiveChannel) -> Bool {
        // A channel-key collision is an 8C.3 blocker, never first-wins.
        channelsByID[channel.id] == [channel]
    }

    func selections(for channel: LiveChannel) -> [ImportedRouteSelection] {
        guard contains(channel), let bindings = routeContext?.bindings(in: channel.streams) else { return [] }
        return bindings.map { ImportedRouteSelection(catalog: self, channel: channel, binding: $0) }
    }

    func selection(for channel: LiveChannel, key: ImportedRouteRuntimeKey) -> ImportedRouteSelection? {
        selections(for: channel).first { $0.id == key }
    }

    var description: String { "AcceptedImportedCatalog(source: \(sourceID))" }
    var customMirror: Mirror { Mirror(self, children: ["sourceID": sourceID]) }
}

/// The factory binds a key to its channel, not merely to a source-wide tuple.
struct ImportedRouteSelection: Identifiable, CustomStringConvertible, CustomReflectable {
    let catalog: AcceptedImportedCatalog
    let channel: LiveChannel
    private let binding: ImportedRouteBinding
    var id: ImportedRouteRuntimeKey { binding.id }
    var stream: LiveStream { binding.stream }
    fileprivate init(catalog: AcceptedImportedCatalog, channel: LiveChannel, binding: ImportedRouteBinding) {
        self.catalog = catalog; self.channel = channel; self.binding = binding
    }
    var description: String { "ImportedRouteSelection(\(id))" }
    var customMirror: Mirror { Mirror(self, children: ["key": id]) }
}

struct LivePlaybackCandidate {
    let channel: LiveChannel
    let stream: LiveStream
    var routeKey: ImportedRouteRuntimeKey? = nil

    var nativeIdentifier: String {
        "\(channel.id)::\(stream.id)"
    }
}

enum LivePlaybackRecoveryScope: Equatable {
    case entireSource
    case currentChannel
}

enum LivePlaybackRecoveryPolicy {
    static func importedCandidates(
        catalog: AcceptedImportedCatalog,
        channels: [LiveChannel],
        starting: ImportedRouteSelection,
        excluding attempted: Set<ImportedRouteTransport>
    ) -> [LivePlaybackCandidate] {
        guard starting.catalog === catalog,
              catalog.selection(for: starting.channel, key: starting.id) != nil,
              channels.allSatisfy(catalog.contains),
              Set(channels.map(\.id)).count == channels.count,
              let index = channels.firstIndex(of: starting.channel) else { return [] }
        let ordered = Array(channels[index...]) + Array(channels[..<index])
        var seen = attempted
        var result: [LivePlaybackCandidate] = []
        for channel in ordered {
            let selections = catalog.selections(for: channel)
            let routes = channel == starting.channel
                ? [starting] + selections.filter { !ImportedRouteTransport.same($0.stream, starting.stream) }
                : selections
            for route in routes {
                guard let transport = ImportedRouteTransport(route.stream), seen.insert(transport).inserted else { continue }
                result.append(LivePlaybackCandidate(channel: channel, stream: route.stream, routeKey: route.id))
            }
        }
        return result
    }

    // Native/provider recovery retains its existing locator semantics. Imported
    // production calls must use importedCandidates and full transport equality.
    static func candidates(
        channels: [LiveChannel],
        startingChannel: LiveChannel,
        startingStream: LiveStream,
        excluding attemptedIdentifiers: Set<String> = [],
        scope: LivePlaybackRecoveryScope = .entireSource
    ) -> [LivePlaybackCandidate] {
        let normalized = LiveChannelNavigationPolicy.normalizedChannels(
            channels,
            including: startingChannel
        )
        guard let startingIndex = normalized.firstIndex(where: {
            $0.id == startingChannel.id
        }) else {
            return []
        }

        let orderedChannels: [LiveChannel]
        switch scope {
        case .entireSource:
            orderedChannels = Array(normalized[startingIndex...])
                + Array(normalized[..<startingIndex])
        case .currentChannel:
            orderedChannels = [startingChannel]
        }
        var seenStreamURLs = Set<String>()
        var values: [LivePlaybackCandidate] = []
        for channel in orderedChannels {
            let streams: [LiveStream]
            if channel.id == startingChannel.id {
                streams = [startingStream] + startingChannel.streams.filter {
                    $0.id != startingStream.id
                }
            } else {
                streams = channel.streams
            }
            for stream in streams {
                let candidate = LivePlaybackCandidate(
                    channel: channel.id == startingChannel.id
                        ? startingChannel
                        : channel,
                    stream: stream
                )
                guard seenStreamURLs.insert(stream.id).inserted,
                      !attemptedIdentifiers.contains(candidate.nativeIdentifier) else {
                    continue
                }
                values.append(candidate)
            }
        }
        return values
    }
}

enum XtreamLivePlaybackFailurePolicy {
    static func permitsFormatFallback(after message: String) -> Bool {
        let normalized = message.lowercased()
        let terminalMarkers = [
            "401", "403", "unauthorized", "forbidden", "disabled",
            "expired", "credential", "account"
        ]
        return !terminalMarkers.contains { normalized.contains($0) }
    }
}

private enum XtreamLivePlaybackError: LocalizedError {
    case staleRequest
    case unavailableAccount
    case invalidReference

    var errorDescription: String? {
        switch self {
        case .staleRequest:
            return "The Xtream Live playback request is no longer current."
        case .unavailableAccount:
            return "The Xtream account is unavailable. Check its credentials in Settings."
        case .invalidReference:
            return "The Xtream Live channel reference is invalid."
        }
    }
}

enum LiveSourceValidationStatus: Equatable {
    case checking(completed: Int, total: Int)
    case processing(completed: Int, total: Int)
    case completed(removed: Int, total: Int)
    case cancelled(completed: Int, total: Int)
    case partial(completed: Int, total: Int)
    case failed(String)
}
enum ConfigurationImportPhase: Equatable {
    case downloadingAndParsing
    case parsing
    case startingNodeRuntime
    case saving
    case activating

    var title: String {
        switch self {
        case .downloadingAndParsing: return L10n.string("configuration.stage.download-parse", fallback: "Downloading and parsing…")
        case .parsing: return L10n.string("configuration.stage.parsing", fallback: "Parsing configuration…")
        case .startingNodeRuntime: return L10n.string("configuration.stage.starting-node", fallback: "Starting Node Runtime…")
        case .saving: return L10n.string("configuration.stage.saving", fallback: "Saving configuration…")
        case .activating: return L10n.string("configuration.stage.activating", fallback: "Activating configuration…")
        }
    }
}

enum LiveSourceImportPhase: Equatable {
    case downloadingAndParsing
    case parsing
    case saving
    case publishing

    var title: String {
        switch self {
        case .downloadingAndParsing: return L10n.string("live.stage.download-parse", fallback: "Downloading and parsing…")
        case .parsing: return L10n.string("live.stage.parsing", fallback: "Parsing Live TV source…")
        case .saving: return L10n.string("live.stage.saving", fallback: "Saving Live TV source…")
        case .publishing: return L10n.string("live.stage.publishing", fallback: "Publishing channels…")
        }
    }
}

struct LiveValidationFreshnessRecord: Codable, Equatable {
    let revision: String
    let completedAt: Date
}

struct LiveValidationFreshnessStore {
    static let storageKey = "OKVideoMac.LiveValidationFreshness.v1"
    static let successfulLifetime: TimeInterval = 24 * 60 * 60
    let defaults: UserDefaults
    let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = Self.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func isFresh(_ source: StoredLiveSource, now: Date = Date()) -> Bool {
        guard let record = records()[source.id.uuidString],
              record.revision == Self.revision(for: source),
              now.timeIntervalSince(record.completedAt) >= 0,
              now.timeIntervalSince(record.completedAt) < Self.successfulLifetime else { return false }
        return true
    }

    func markCompleted(_ source: StoredLiveSource, at date: Date = Date()) {
        var values = records()
        values[source.id.uuidString] = LiveValidationFreshnessRecord(
            revision: Self.revision(for: source), completedAt: date
        )
        save(values)
    }

    func remove(_ sourceID: UUID) {
        var values = records()
        values[sourceID.uuidString] = nil
        save(values)
    }

    static func revision(for source: StoredLiveSource) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(source.sourceKind.rawValue.utf8))
        hasher.update(data: source.rawData)
        if let baseURL = source.baseURL?.absoluteString {
            hasher.update(data: Data(baseURL.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func records() -> [String: LiveValidationFreshnessRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode(
                [String: LiveValidationFreshnessRecord].self, from: data
              ) else { return [:] }
        return values
    }

    private func save(_ values: [String: LiveValidationFreshnessRecord]) {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }
}

enum LiveSourceEPGStatus: Equatable {
    case loading
    case loaded(lastProgrammeEnd: Date?)
    case failed(String)

    enum Presentation: Equatable {
        case loading, loaded, expired, empty
        case failed(String)
    }

    init(status: EPGRepositoryStatus, failureMessage: String) {
        if status.availability == .failed || status.consecutiveFailures > 0 {
            self = .failed(failureMessage)
        } else {
            self = .loaded(lastProgrammeEnd: status.summary?.coverageEnd)
        }
    }

    var programmeBoundary: Date? {
        if case .loaded(let end) = self { return end }
        return nil
    }

    /// O(1), display only. No refresh, TTL changes, or programme mutation.
    func presentation(at now: Date) -> Presentation {
        switch self {
        case .loading: return .loading
        case .failed(let message): return .failed(message)
        case .loaded(let end):
            guard let end else { return .empty }
            return end <= now ? .expired : .loaded
        }
    }
}

private final class LivePlaybackNavigationContext {
    let flowID = UUID()
    let sourceID: LiveSourceID
    let channels: [LiveChannel]
    let importedCatalog: AcceptedImportedCatalog?
    var attemptedTransports = Set<ImportedRouteTransport>()

    init(sourceID: LiveSourceID, channels: [LiveChannel], importedCatalog: AcceptedImportedCatalog? = nil) {
        self.sourceID = sourceID
        self.channels = channels
        self.importedCatalog = importedCatalog
    }
}

struct PlaybackStartupGateToken {
    let identity: UUID
    let stream: AsyncThrowingStream<Void, Error>
}

/// Waits for actual playback progress after libmpv has accepted a file.
///
/// Resolving a provider URL and waiting for `file-loaded` can legitimately take
/// much longer than the startup timeout on a cold remote source. The timeout is
/// therefore dormant until `arm` is called by the `fileLoaded` event handler.
/// Keeping the gate registered before `loadfile` also means a very fast first
/// frame cannot race past the waiter.
@MainActor
final class PlaybackStartupGateController {
    private struct PendingGate {
        let identity: UUID
        let continuation: AsyncThrowingStream<Void, Error>.Continuation
        let timeoutNanoseconds: UInt64
        var timeoutTask: Task<Void, Never>?
    }

    private var pending: [UUID: PendingGate] = [:]

    func begin(
        requestID: UUID,
        timeoutNanoseconds: UInt64 = 12_000_000_000
    ) -> PlaybackStartupGateToken {
        cancel(requestID: requestID)
        let identity = UUID()
        var captured: AsyncThrowingStream<Void, Error>.Continuation!
        let stream = AsyncThrowingStream<Void, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            captured = continuation
        }
        pending[requestID] = PendingGate(
            identity: identity,
            continuation: captured,
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutTask: nil
        )
        return PlaybackStartupGateToken(identity: identity, stream: stream)
    }

    @discardableResult
    func arm(requestID: UUID, expectedIdentity: UUID? = nil) -> Bool {
        guard var gate = pending[requestID],
              expectedIdentity == nil || gate.identity == expectedIdentity,
              gate.timeoutTask == nil else {
            return false
        }
        let identity = gate.identity
        let timeoutNanoseconds = gate.timeoutNanoseconds
        gate.timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let seconds = max(
                1,
                Int((Double(timeoutNanoseconds) / 1_000_000_000).rounded())
            )
            self?.fail(
                requestID: requestID,
                expectedIdentity: identity,
                error: AppError.playback(
                    L10n.string("player.validation.no-media", fallback: "The stream loaded but produced no audio or video within %d seconds", seconds)
                )
            )
        }
        pending[requestID] = gate
        return true
    }

    @discardableResult
    func complete(requestID: UUID) -> Bool {
        guard let gate = pending.removeValue(forKey: requestID) else {
            return false
        }
        gate.timeoutTask?.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        return true
    }

    @discardableResult
    func fail(
        requestID: UUID,
        expectedIdentity: UUID? = nil,
        error: Error
    ) -> Bool {
        guard let gate = pending[requestID],
              expectedIdentity == nil || gate.identity == expectedIdentity else {
            return false
        }
        pending[requestID] = nil
        gate.timeoutTask?.cancel()
        gate.continuation.finish(throwing: error)
        return true
    }

    func cancel(requestID: UUID, expectedIdentity: UUID? = nil) {
        _ = fail(
            requestID: requestID,
            expectedIdentity: expectedIdentity,
            error: CancellationError()
        )
    }

    func cancelAll() {
        let gates = pending
        pending.removeAll()
        for gate in gates.values {
            gate.timeoutTask?.cancel()
            gate.continuation.finish(throwing: CancellationError())
        }
    }
}

/// Starts automatic episode replacement outside the player-event consumer.
///
/// The replacement path waits for `fileLoaded` and `playbackStarted`, which are
/// delivered by that same consumer. Awaiting replacement inline from an
/// `ended` event therefore deadlocks the application snapshot at `.loading`
/// even though libmpv is already rendering the next file. This controller also
/// gives manual playback, window close, and shutdown one request-scoped handle
/// with which to invalidate an in-flight automatic replacement.
@MainActor
final class AutomaticEpisodeAdvanceController {
    private(set) var requestID: UUID?
    private(set) var claimedSessionID: UUID?
    private var task: Task<Void, Never>?

    func owns(requestID: UUID) -> Bool {
        self.requestID == requestID
    }

    func schedule(
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        schedule(sessionID: UUID(), operation: operation)
    }

    func schedule(
        sessionID: UUID,
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        guard claimedSessionID != sessionID else { return }
        cancel()
        let requestID = UUID()
        self.requestID = requestID
        claimedSessionID = sessionID
        task = Task { @MainActor [weak self] in
            // Let the caller return to AsyncStream iteration before beginning a
            // flow whose completion depends on later events from that stream.
            await Task.yield()
            guard let self,
                  self.requestID == requestID,
                  !Task.isCancelled else { return }
            await operation(requestID)
            guard self.requestID == requestID else { return }
            self.requestID = nil
            self.claimedSessionID = nil
            self.task = nil
        }
    }

    func cancel() {
        requestID = nil
        claimedSessionID = nil
        task?.cancel()
        task = nil
    }
}

struct ConfigurationActivationToken: Equatable, Sendable {
    let generation: UInt64
    let configurationID: UUID
}

enum ConfigurationSwitchFeedback: Equatable, Sendable {
    case idle
    case switching(ConfigurationActivationToken, targetName: String)
    case success(ConfigurationActivationToken, targetName: String)
    case failure(
        ConfigurationActivationToken,
        targetName: String,
        message: String
    )

    var targetName: String? {
        switch self {
        case .idle:
            return nil
        case .switching(_, let name), .success(_, let name):
            return name
        case .failure(_, let name, _):
            return name
        }
    }
}

enum ConfigurationSwitchFeedbackPolicy {
    static func switching(
        token: ConfigurationActivationToken,
        targetName: String
    ) -> ConfigurationSwitchFeedback {
        .switching(token, targetName: targetName)
    }

    static func success(
        current: ConfigurationSwitchFeedback,
        token: ConfigurationActivationToken,
        targetName: String,
        ownsCurrentRequest: Bool
    ) -> ConfigurationSwitchFeedback {
        ownsCurrentRequest
            ? .success(token, targetName: targetName)
            : current
    }

    static func failure(
        current: ConfigurationSwitchFeedback,
        token: ConfigurationActivationToken,
        targetName: String,
        message: String,
        ownsCurrentRequest: Bool
    ) -> ConfigurationSwitchFeedback {
        ownsCurrentRequest
            ? .failure(token, targetName: targetName, message: message)
            : current
    }

    static func shouldDismiss(
        _ feedback: ConfigurationSwitchFeedback,
        token: ConfigurationActivationToken
    ) -> Bool {
        switch feedback {
        case .success(let current, _), .failure(let current, _, _):
            return current == token
        case .idle, .switching:
            return false
        }
    }

    static func shouldClear(
        _ feedback: ConfigurationSwitchFeedback,
        hasActiveActivationRequest: Bool
    ) -> Bool {
        guard !hasActiveActivationRequest else { return false }
        if case .idle = feedback { return false }
        return true
    }
}

struct ConfigurationActivationRequestTracker: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var requestedConfigurationID: UUID?

    mutating func begin(_ configurationID: UUID) -> ConfigurationActivationToken {
        generation &+= 1
        requestedConfigurationID = configurationID
        return ConfigurationActivationToken(
            generation: generation,
            configurationID: configurationID
        )
    }

    func owns(_ token: ConfigurationActivationToken) -> Bool {
        generation == token.generation
            && requestedConfigurationID == token.configurationID
    }

    mutating func finish(_ token: ConfigurationActivationToken) {
        guard owns(token) else { return }
        requestedConfigurationID = nil
    }
}

enum ConfigurationActivationErrorPolicy {
    static func shouldPresent(
        _ error: Error,
        ownsCurrentRequest: Bool
    ) -> Bool {
        ownsCurrentRequest && !AsyncCancellationPolicy.isCancellation(error)
    }
}

enum ConfigurationActivationRuntimePolicy {
    static func shouldStopNodeRuntime(
        targetUsesNodeRuntime: Bool,
        ownsCurrentRequest: Bool
    ) -> Bool {
        ownsCurrentRequest && !targetUsesNodeRuntime
    }
}

enum ConfigurationPostActivationPolicy {
    static func isCurrent(
        expectedSessionID: UUID,
        currentSessionID: UUID,
        expectedConfigurationID: UUID,
        activeConfigurationID: UUID?
    ) -> Bool {
        expectedSessionID == currentSessionID
            && expectedConfigurationID == activeConfigurationID
    }
}

private struct PreparedConfigurationActivation {
    var record: StoredConfiguration
    let configuration: FongMiConfiguration
    let nodeRuntimeEndpoint: URL?
    let nodeRuntimeSourceURL: URL?
    let xtreamCredentials: XtreamCredentials?

    var usesNodeRuntime: Bool {
        nodeRuntimeSourceURL != nil
    }
}

struct SearchSessionGate: Equatable {
    private(set) var currentID = UUID()

    mutating func begin() -> UUID {
        currentID = UUID()
        return currentID
    }

    mutating func invalidate() {
        currentID = UUID()
    }

    func accepts(_ sessionID: UUID) -> Bool {
        currentID == sessionID
    }
}

/// Publishes the high-frequency mpv timeline independently from `AppState`.
/// Browser views observe `AppState`, so keeping the snapshot there as an
/// `@Published` value caused every progress tick to rebuild unrelated grids.
@MainActor
final class PlayerSnapshotState: ObservableObject {
    @Published private(set) var snapshot: PlayerSnapshot

    init(snapshot: PlayerSnapshot = PlayerSnapshot()) {
        self.snapshot = snapshot
    }

    func update(_ snapshot: PlayerSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

private struct LiveGuideDemandInput: Equatable {
    let source: LiveSourceID
    let channels: [LiveChannel]
    let windowStart: Date
    let windowEnd: Date
    let visibleRange: Range<Int>
    let focusedChannelID: String?
}

private struct LiveGuideRequestSpec: Equatable {
    let input: LiveGuideDemandInput
    let identity: LiveGuideDeliveryIdentity
}

/// One publication for the category page and its related presentation state.
/// A pagination result should not invalidate HomeView once per field.
private struct HomeCategoryPublication: Equatable {
    var homeLoadErrorMessage: String?
    var selectedCategoryID: String?
    var selectedCategoryFilters: [String: String] = [:]
    var categoryPage: VideoPage?
    var homePresentationSelection: HomePresentationSelection = .empty
    var isLoadingNextCategoryPage = false
    var categoryPaginationError: String?
    var paginationIssueKind: CategoryPaginationIssueKind = .failed
    var presentationRevision: UInt64 = 0
    var hasPendingRefresh = false
}

@MainActor
final class AppState: ObservableObject {
    let navigation = AppNavigationState()
    let settingsNavigation = SettingsNavigationState()
    var selectedSection: AppSection {
        get { navigation.selectedSection }
        set { navigation.selectedSection = newValue }
    }
    @Published private(set) var isHomeSearchPresented = false
    @Published private(set) var isBrowserWindowKey = false
    @Published private(set) var isPlayerWindowKey = false
    @Published private(set) var isQuickSwitcherPresented = false
    @Published private(set) var isShortcutHelpPresented = false
    @Published private(set) var shortcutLiveRefreshRequest: UInt64 = 0
    @Published private(set) var shortcutPlayerEscapeRequest: UInt64 = 0
    @Published private(set) var shortcutLiveSourceSelection:
        ShortcutLiveSourceSelection?
    var selectedSettingsPane: SettingsPane {
        get { settingsNavigation.selectedPane }
        set { settingsNavigation.select(newValue) }
    }
    @Published private(set) var configurations: [StoredConfiguration] = []
    @Published private(set) var activeConfigurationRecord: StoredConfiguration?
    @Published private(set) var activeConfiguration: FongMiConfiguration?
    @Published private(set) var requestedConfigurationID: UUID?
    @Published private(set) var configurationSwitchFeedback:
        ConfigurationSwitchFeedback = .idle
    @Published private(set) var selectedSiteKey: String?
    @Published private(set) var siteHome: SiteHome?
    @Published private(set) var isHomeLoading = false
    @Published private(set) var isRecoveringHome = false
    @Published private var homeCategoryPublication = HomeCategoryPublication()
    private(set) var homeLoadErrorMessage: String? {
        get { homeCategoryPublication.homeLoadErrorMessage }
        set {
            guard homeCategoryPublication.homeLoadErrorMessage != newValue else { return }
            homeCategoryPublication.homeLoadErrorMessage = newValue
        }
    }
    @Published private(set) var homeLoadErrorIsLocalPluginCache = false
    @Published private(set) var hasCompletedStartup = false
    private(set) var selectedCategoryID: String? {
        get { homeCategoryPublication.selectedCategoryID }
        set {
            guard homeCategoryPublication.selectedCategoryID != newValue else { return }
            homeCategoryPublication.selectedCategoryID = newValue
        }
    }
    private(set) var selectedCategoryFilters: [String: String] {
        get { homeCategoryPublication.selectedCategoryFilters }
        set {
            guard homeCategoryPublication.selectedCategoryFilters != newValue else { return }
            homeCategoryPublication.selectedCategoryFilters = newValue
        }
    }
    private(set) var categoryPage: VideoPage? {
        get { homeCategoryPublication.categoryPage }
        set {
            guard homeCategoryPublication.categoryPage != newValue else { return }
            homeCategoryPublication.categoryPage = newValue
        }
    }
    private(set) var homePresentationSelection: HomePresentationSelection {
        get { homeCategoryPublication.homePresentationSelection }
        set {
            guard homeCategoryPublication.homePresentationSelection != newValue else { return }
            homeCategoryPublication.homePresentationSelection = newValue
        }
    }
    /// Editable text shown by the global sidebar search field. This may differ
    /// from `activeSearchKeyword` until the user submits the field.
    @Published var searchDraftKeyword = ""
    /// The normalized keyword that owns the currently presented result set.
    /// Result metadata and retries must use this value, never the live draft.
    @Published private(set) var activeSearchKeyword = ""
    @Published private(set) var globalSearchFocusRequest: UInt64 = 0
    @Published private(set) var homeSearchReturnSection: AppSection?
    @Published private(set) var searchResults: [VideoSummary] = []
    var searchClusters: [SearchResultCluster] { SearchResultAggregator.cluster(searchResults) }
    @Published private(set) var searchFailures: [SearchFailure] = []
    @Published private(set) var searchSiteOutcomes: [String: SearchSiteOutcome] = [:]
    @Published private(set) var searchFirstPageCompletedSiteCount = 0
    @Published private(set) var searchCompletedSiteCount = 0
    @Published private(set) var searchTotalSiteCount = 0
    @Published private(set) var searchReceivedCandidateCount = 0
    @Published private(set) var searchMaximumRetainedCandidates = Int.max
    @Published private(set) var searchMaximumResultsPerSite = Int.max
    @Published private(set) var searchDidDiscardCandidates = false
    @Published private(set) var searchTermination: MultiSiteSearchTermination?
    @Published private(set) var previousSearchTermination:
        MultiSiteSearchTermination?
    @Published private(set) var isSearching = false
    @Published private(set) var searchSiteScope: SearchSiteScope = .all
    @Published private(set) var activeSearchSiteKeys: Set<String> = []
    @Published private(set) var selectedSearchSiteKey: String?
    @Published private(set) var searchFolderPath: [SearchFolderPage] = []
    @Published private(set) var searchFolderOrigin: SearchFolderOrigin?
    @Published private(set) var favorites: [FavoriteRecord] = []
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var historyPlaybackLoadingID: HistoryRecord.ID?
    @Published private(set) var historyPlaybackChoices: [HistoryPlaybackChoice] = []
    @Published private(set) var liveSources: [StoredLiveSource] = []
    @Published private(set) var acceptedImportedCatalogs: [UUID: AcceptedImportedCatalog] = [:]
    // Compatibility projection for existing EPG/identity readers; publication
    // has only one authority, and never allocates contexts on a read.
    var loadedLivePlaylists: [UUID: LivePlaylist] {
        acceptedImportedCatalogs.mapValues(\.playlist)
    }

    private func publishImportedCatalog(_ playlist: LivePlaylist?, sourceID: UUID) {
        acceptedImportedCatalogs[sourceID] = playlist.map {
            AcceptedImportedCatalog(sourceID: sourceID, playlist: $0)
        }
    }
    @Published private(set) var nativeLiveCatalog: LiveCatalogSnapshot?
    @Published private(set) var nativeLiveCatalogError: String?
    @Published private(set) var liveCatalogLoadingSourceIDs = Set<LiveSourceID>()
    @Published private(set) var nativeLiveFavorites = StoredLiveChannelReferenceEnvelope(setting: nil)
    @Published private(set) var nativeLiveHiddenChannels = StoredLiveChannelReferenceEnvelope(setting: nil)
    let liveEPG = LiveEPGState()
    let liveGuide = LiveGuideState()
    @Published private(set) var epgPreferences = EPGPreferences()
    @Published private(set) var isSavingEPGPreferences = false
    @Published private(set) var liveEPGCatalogRevision = UUID()
    @Published private(set) var epgFailures: [UUID: String] = [:]
    @Published private(set) var liveSourceEPGStatuses:
        [UUID: LiveSourceEPGStatus] = [:]
    @Published private(set) var livePlaybackChannel: LiveChannel? {
        didSet { scheduleEPGRefresh() }
    }
    @Published private(set) var livePlaybackStream: LiveStream?
    @Published private(set) var livePlaybackSourceID: LiveSourceID? {
        didSet { scheduleEPGRefresh() }
    }
    @Published private(set) var isRecoveringLivePlayback = false
    @Published private(set) var hasExhaustedLivePlayback = false
    @Published private(set) var livePlaybackNotice: String?
    let liveValidationActivity = LiveValidationActivityModel()
    var liveSourceValidationStatuses: [UUID: LiveSourceValidationStatus] { liveValidationActivity.statuses }
    @Published private(set) var selectedDetail: VideoDetail?
    @Published private(set) var pendingDetailSummary: VideoSummary?
    @Published private(set) var detailRouteSummary: VideoSummary?
    @Published private(set) var detailLoadState: DetailPageLoadState = .loading
    @Published private(set) var detailSuggestedSearch: String?

    var isDetailPagePresented: Bool {
        detailRouteSummary != nil || selectedDetail != nil || pendingDetailSummary != nil
    }
    @Published private(set) var incognitoMode = false
    @Published private(set) var historyRetentionDays = 60
    @Published private(set) var appTheme: AppTheme = .system
    @Published private(set) var favoriteLiveChannelIDs: Set<String> = []
    @Published private(set) var deletedLiveChannelIDs: Set<String> = []
    let playerWindowPreferences = PlayerWindowPreferenceStore()
    let playerSnapshotState = PlayerSnapshotState()
    let danmaku = DanmakuSessionCoordinator()
    private(set) var playerSnapshot: PlayerSnapshot {
        get { playerSnapshotState.snapshot }
        set {
            playerSnapshotState.update(newValue)
            if !isShutdownRequested && !isClosingPlayer && isPlayerPresented {
                playbackDisplaySleep.update(newValue, requestID: activePlayerRequestID)
            }
        }
    }
    @Published private(set) var isRestoringPlayerEpisodeList = false
    @Published private(set) var isPlayerEpisodeListIncomplete = false
    private var playerEpisodeListHistoryRecord: HistoryRecord?
    private var playerEpisodeListRestoreTask: Task<Void, Never>?
    private var playerEpisodeListRestoreID: UUID?
    @Published private(set) var playerEpisodePresentations: [EpisodePresentation] = []
    @Published private(set) var isPlayerEpisodeListPreparing = false
    @Published private(set) var playerRenderClient: MPVPlayerClient?
    @Published private(set) var playerSubtitlesEnabled = false
    @Published private(set) var selectedPlayerSubtitleTrackID: Int?
    @Published private(set) var playerSubtitleDelay: TimeInterval = 0
    @Published private(set) var playerSubtitleScale: Double = 1
    @Published private(set) var playerSubtitlePosition: Double = 100
    @Published private(set) var playerSubtitleBorderSize: Double = 3
    @Published private(set) var playerAudioDelay: TimeInterval = 0
    @Published private(set) var playerAspectRatio: String?
    @Published private(set) var playerHardwareDecoding = true
    @Published private(set) var autoPlayNextEpisode = true
    @Published private(set) var playbackSkipOpeningEnd: TimeInterval?
    @Published private(set) var playbackSkipEndingDuration: TimeInterval?
    @Published private(set) var playbackSkipOpeningEnabled = false
    @Published private(set) var playbackSkipEndingEnabled = false
    @Published private(set) var playbackSkipAppliesToAllEpisodes = true
    @Published private(set) var playbackEndingSkipPrompt:
        PlaybackEndingSkipPrompt?
    @Published private(set) var playbackResolutionState: PlaybackResolutionState = .idle
    @Published private(set) var currentPlaybackAttempt: PlaybackAttempt?
    @Published private(set) var playbackFailureSummary: String?
    @Published private(set) var playbackQualities: [PlaybackQuality] = []
    @Published private(set) var selectedPlaybackQualityID: String?
    @Published private(set) var isSwitchingPlaybackQuality = false
    @Published var isPlayerPresented = false {
        didSet {
            if !isPlayerPresented {
                playerPresentedError = nil
                playbackDisplaySleep.finishSession(activePlayerRequestID)
                danmaku.endSession()
                liveHLSPreparationTask?.task.cancel()
                liveHLSPreparationTask = nil
            }
        }
    }
    @Published private(set) var isPlayerRenderSurfaceMountEnabled = false
    @Published private(set) var playerWindowCommand: PlayerWindowCommand?
    @Published private(set) var appWindowLayoutCommand: AppWindowLayoutCommand?
    @Published private(set) var isLoading = false
    private(set) var isLoadingNextCategoryPage: Bool {
        get { homeCategoryPublication.isLoadingNextCategoryPage }
        set {
            guard homeCategoryPublication.isLoadingNextCategoryPage != newValue else { return }
            homeCategoryPublication.isLoadingNextCategoryPage = newValue
        }
    }
    var categoryPaginationIssueKind: CategoryPaginationIssueKind { homeCategoryPublication.paginationIssueKind }

    private(set) var categoryPaginationError: String? {
        get { homeCategoryPublication.categoryPaginationError }
        set {
            guard homeCategoryPublication.categoryPaginationError != newValue else { return }
            homeCategoryPublication.categoryPaginationError = newValue
            if newValue == nil { homeCategoryPublication.paginationIssueKind = .failed }
        }
    }
    @Published var presentedError: UserFacingError?
    @Published var playerPresentedError: UserFacingError?
    @Published var cloudAuthorizationPrompt: CloudAuthorizationPrompt?
    @Published var cloudAuthorizationInput = ""
    @Published private(set) var cloudAuthorizationSurfaceFrame:
        AndroidActionSurfaceFrame?
    @Published private(set) var siteActionStatus: TransientSiteActionStatus?
    @Published private(set) var nodeWebPresentation: NodeWebPresentation?
    @Published private(set) var configurationCategoryPresentation:
        ConfigurationCategoryPresentation?
    @Published private(set) var androidRuntimeStatus: AndroidRuntimeStatus = .checking
    @Published private(set) var isAndroidRuntimeBusy = false
    @Published private(set) var androidRuntimeStorage: ManagedRuntimeStorage?
    @Published private(set) var androidMaintenanceMessage: String?
    @Published private(set) var managedRuntimeInstallationState:
        ManagedRuntimeInstallationState = .detecting
    @Published private(set) var androidRuntimeModeSnapshot:
        AndroidRuntimeModeSnapshot = .initial
    @Published var isAndroidRuntimeInstallSheetPresented = false

    var mainWindowCloudAuthorizationPrompt: CloudAuthorizationPrompt? {
        guard let prompt = cloudAuthorizationPrompt,
              prompt.presentationTarget == .mainWindow else {
            return nil
        }
        return prompt
    }

    var detailCloudAuthorizationPrompt: CloudAuthorizationPrompt? {
        guard let prompt = cloudAuthorizationPrompt,
              prompt.presentationTarget == .detail else {
            return nil
        }
        return prompt
    }

    var playerCloudAuthorizationPrompt: CloudAuthorizationPrompt? {
        guard let prompt = cloudAuthorizationPrompt,
              case .player(let requestID) = prompt.presentationTarget,
              CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: requestID,
                activeRequestID: activePlayerRequestID,
                playbackSessionID: playbackSessionID,
                isPlayerPresented: isPlayerPresented
              ) else {
            return nil
        }
        return prompt
    }

    var mainWindowNodeWebPresentation: NodeWebPresentation? {
        guard let presentation = nodeWebPresentation,
              presentation.presentationTarget == .mainWindow else {
            return nil
        }
        return presentation
    }

    var detailNodeWebPresentation: NodeWebPresentation? {
        guard let presentation = nodeWebPresentation,
              presentation.presentationTarget == .detail else {
            return nil
        }
        return presentation
    }

    var playerNodeWebPresentation: NodeWebPresentation? {
        guard let presentation = nodeWebPresentation,
              case .player(let requestID) = presentation.presentationTarget,
              CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: requestID,
                activeRequestID: activePlayerRequestID,
                playbackSessionID: playbackSessionID,
                isPlayerPresented: isPlayerPresented
              ) else {
            return nil
        }
        return presentation
    }

    @Published private(set) var playerAudioPreference = PlaybackAudioPreference()
    private var audioErrorRevision: UInt64?
    private let environment: AppEnvironment?
    private let liveReferenceStore: SQLiteStore?
    private let liveCredentialStore: (any XtreamCredentialStoring)?
    private let playerRenderSurfaceGate = PlayerRenderSurfaceReadinessGate()
    private var configurationImportOperationID: UUID?
    private var xtreamProviderOperationID: UUID?
    private var configurationActivationTracker =
        ConfigurationActivationRequestTracker()
    private var configurationActivationTask: Task<Void, Never>?
    private var configurationPostActivationTask: Task<Void, Never>?
    private var configurationPostActivationSessionID = UUID()
    private var configurationSwitchFeedbackDismissTask: Task<Void, Never>?
    private var providers: [String: SiteProvider] = [:] {
        didSet { invalidateDetailContext(preservingRoute: preservesDetailRouteOnProviderReplacement) }
    }
    private var preservesDetailRouteOnProviderReplacement = false
    private let catPawSearchMemory = CatPawSearchMemory()
    private var activeSearchContext: SearchLaunchContext?
    private var activeSearchScope: SearchSiteScope?
    private var activeXtreamCredentials: XtreamCredentials?
    private var nativeLiveGeneration = UUID()
    private var nativeLiveAccountMutationIDs = Set<UUID>()
    private var nativeLiveCatalogRequestID: UUID?
    private var nativeLiveCatalogTask: Task<LiveCatalogSnapshot, Error>?
    private var nativeLiveReferenceWriteTask: Task<Void, Never>?
    private var nativeLiveReferenceWriteID: UUID?
    private var searchTask: Task<Void, Never>?
    private var searchSessionGate = SearchSessionGate()
    private var searchContinuationTask: Task<Bool, Never>?
    @Published private(set) var searchPaging = SearchPagingState()
    let searchBrowseMemory = SearchBrowseMemory()
    private(set) var searchBrowseSessionID = UUID()

    private let detailResponseCache = DetailResponseCache()
    private var detailRequestTask: Task<Void, Never>?
    private var detailTimeoutTask: Task<Void, Never>?
    private let detailRequestTimeout: TimeInterval
    private var detailRequestKey: DetailResponseCache.Key?
    private var detailRequestSummary: VideoSummary?
    @Published private(set) var isRefreshingDetail = false
    @Published private(set) var detailRevision = 0
    private var detailLoadSessionID = UUID()
    private var activeDetailPerformanceTrace: DetailPerformanceTrace?
    private var detailHomeSearchReturnSnapshot:
        DetailHomeSearchReturnSnapshot?
    private var discoverySearchReturnSnapshot:
        DetailHomeSearchReturnSnapshot?
    private var homeLoadSessionID = UUID()
    private var androidHomeLoadTask: Task<SiteHome, Error>?
    private var androidHomeLoadTaskID: UUID?
    private var homeContentIdentity: HomeContentIdentity?
    private var homeBrowsingSnapshots:
        [HomeContentIdentity: HomeBrowsingSnapshot] = [:]
    private var homeResumeTask: Task<Void, Never>?
    private var catPawHomeLoadCoordinator = CatPawHomeLoadCoordinator()
    private var catPawHomeRequestTasks:
        [CatPawHomeLoadKey: CatPawHomeRequestTaskEntry] = [:]
    private var categoryLoadSessionID = UUID()
    private var categoryFilterLoadTask: Task<Void, Never>?
    private var categoryFilterLoadID: UUID?
    private var categoryTabSessionStore = CategoryTabSessionStore()
    private var categoryRequestTasks:
        [CategoryPageRequestKey: CategoryRequestTaskEntry] = [:]
    private var knownCategoryConfigurationRevisions: [UUID: String] = [:]
    private var activeCategoryQueryKey: CategoryQueryKey?
    private var configurationCategoryLoadSessionID = UUID()
    private var playerEventTask: Task<Void, Never>?
    private let automaticEpisodeAdvanceController =
        AutomaticEpisodeAdvanceController()
    private var playbackSkipSession: PlaybackSkipSessionState?
    private var activeSeekConfirmationID: UUID?
    private var cloudAuthorizationPollTask: Task<Void, Never>?
    private var nodeAuthorizationCompletionTask: Task<Void, Never>?
    private var nodeAuthorizationAutoRetryRequestID: UUID?
    private var cloudAuthorizationSessionID = UUID()
    private var lastCloudAuthorizationSurfaceCaptureAt: Date?
    @Published private var configurationInteractionCoordinator =
        ConfigurationInteractionCoordinator()
    private var configurationInteractionTerminalTask: Task<Void, Never>?
    /// Serializes provider cancellation/restart cleanup across UI dismissal
    /// and a subsequent button click. A cleared sheet must not make its old
    /// DEX worker invisible to the next interaction.
    private var configurationInteractionCleanupTask: Task<Void, Never>?
    @Published private(set) var pendingTVBoxConfigurationAction: PendingTVBoxConfigurationAction?
    private var tvboxConfigurationActionTask: Task<Void, Never>?
    private var tvboxConfigurationActionTimeoutTask: Task<Void, Never>?
    private let configurationActionTimeout: TimeInterval
    private var siteActionStatusGeneration: UInt64 = 0
    private var siteActionStatusDismissTask: Task<Void, Never>?
    private var activePlayback: ActivePlaybackContext?
    private var pendingPlayback: PendingCloudPlayback?
    /// Retains only a CatPaw-owned Node proxy generation. TVBox, ordinary
    /// direct media and cloud bridge sessions never create this lease.
    private var activeNodePlaybackLease: NodeRuntimePlaybackLease?
    private var livePlaybackNavigationContext: LivePlaybackNavigationContext?
    private var livePlaybackAttemptedIdentifiers = Set<String>()
    private var livePlaybackRecoveryTask: Task<Void, Never>?
    private var liveHLSPreparationTask: (requestID: UUID, task: Task<HLSStartupSelection?, Error>)?
    private var livePlaybackNoticeTask: Task<Void, Never>?
    private var liveSourceValidationTasks: [UUID: Task<Void, Never>] = [:]
    private var liveValidationPermits: [UUID: LiveValidationPermit] = [:]
    private var liveValidationProgressRelays: [UUID: ValidationProgressRelay] = [:]
    private var liveValidationDeadlines: [UUID: Task<Void, Never>] = [:]
    // Automatic background health checks intentionally use less concurrency
    // than an explicit diagnostic run so playback keeps the network budget.
    private var liveValidationService = LiveValidationService(concurrency: 2)
    private let liveValidationFreshness = LiveValidationFreshnessStore()
    private var liveValidationSelectedSource: UUID?
    private var epgRefreshTask: Task<Void, Never>?
    private var epgBoundaryTask: Task<Void, Never>?
    private var epgLifecycleTask: Task<Void, Never>?
    private var epgResourceRefreshTasks: [EPGRequestKey: Task<Void, Never>] = [:]
    private var epgResourceRefreshOperationIDs: [EPGRequestKey: UUID] = [:]
    private var liveGuideTask: Task<Void, Never>?
    private var liveGuideOwner: UUID?
    private var liveGuideWaitingForResource: EPGRequestKey?
    private var liveGuideInput: LiveGuideDemandInput?
    private var liveGuideRequest: LiveGuideRequestSpec?
    private var liveGuideDebounce = LiveGuideDemandDebounce()
    private var epgRefreshGeneration = UUID()
    private var epgSleeping = false
    private var epgBrowserSource: LiveSourceID?
    private var epgBrowserChannels: [LiveChannel] = []
    private var epgInitialSourceID: UUID?
    private var playerEpisodePresentationCache: PlayerEpisodePresentationCache?
    private var playerEpisodePreparationTask: Task<Void, Never>?
    private var cloudAuthorizationContext: CloudAuthorizationContext?
    private var cloudAccountStatusStore = CloudAccountStatusStore()
    private var pendingNodeOperation: PendingNodeOperation?
    private var pendingNodePlaybackConfigurationFallback:
        PendingNodePlaybackConfigurationFallback?
    private var nodePlaybackRecoveryGate = NodePlaybackRecoveryGate()
    private var nodePlaybackRecoveryTask: Task<Void, Never>?
    private var nodePlaybackLastCheckpoint: (UUID, NodePlaybackRecoveryCheckpoint)?
    private var playbackSessionID = UUID()
    @Published private(set) var playbackPresentationID = UUID()
    @Published private(set) var hasCurrentPlaybackStarted = false
    private var activePlayerRequestID = UUID() {
        didSet {
            playbackDisplaySleep.beginSession(activePlayerRequestID)
            if oldValue != activePlayerRequestID {
                playbackPresentationID = activePlayerRequestID
                hasCurrentPlaybackStarted = false
                playerPresentedError = nil
                playbackFailureSummary = nil
                nodePlaybackRecoveryTask?.cancel()
                nodePlaybackRecoveryTask = nil
                danmaku.endSession()
                liveHLSPreparationTask?.task.cancel()
                liveHLSPreparationTask = nil
            }
        }
    }
    private let playbackDisplaySleep: PlaybackDisplaySleepController
    private var transferRequestGeneration: UInt64 = 0
    private var transferGenerationsByRequestID: [UUID: UInt64] = [:]
    private var preparedTransferReceipts: [UUID: TransferReceipt] = [:]
    private var transferMediaLeases: [UUID: TransferMediaLease] = [:]
    private let playbackStartupGates = PlaybackStartupGateController()
    private var presentedPlaybackErrorRequestIDs = Set<UUID>()
    private var playbackRequestsResolving = Set<UUID>()
    private var playbackAuthorizationResumeGate =
        PlaybackAuthorizationResumeGate()
    private var playbackQualitySwitchSessionID = UUID()
    @Published var favoritesScope: FavoriteScope = .all
    @Published var favoriteSelection = Set<String>()
    @Published private(set) var favoritePendingIdentities = Set<FavoriteIdentity>()
    @Published private(set) var favoriteLoadingID: String?
    @Published private(set) var pendingFavoriteRepairID: String?
    private var detailFavoriteSource: FavoriteSourceContext?
    private var detailFavoriteExpectation: FavoriteRecord?
    private var favoriteRecoveryContext: (original: FavoriteRecord, expected: FavoriteRecord, source: FavoriteSourceContext, bind: Bool)?
    private var favoriteMutationTask: Task<Void, Never>?
    private var favoriteIntentVersions: [FavoriteIdentity: UUID] = [:]
    private var favoritesRevision: UInt64 = 0
    private var favoriteOpenTask: Task<Void, Never>?
    private var favoriteOpenGeneration = UUID()
    private var historyRevision: UInt64 = 0
    private var lastHistoryPublishedAt = Date.distantPast
    private var suppressedHistorySessions = Set<UUID>()
    private var historySessionRecordIDs: [UUID: Set<String>] = [:]
    private var lastHistoryPersistenceErrorAt = Date.distantPast
    private var lastHistorySaveAt = Date.distantPast
    private var historyProgressCheckpoint = PlayerHistoryProgressCheckpoint()
    private var historyPlaybackPreparationID = UUID()
    private var historyPlaybackTask: Task<Void, Never>?
    private var historyPlaybackRequestedItem: HistoryRecord?
    private var historyPlaybackSessionCache = HistoryPlaybackSessionCache()
    private var pendingHistoryWrite: PlaybackHistoryWrite?
    private var historyPersistenceTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShutdownRequested = false
    private var hasCompletedShutdown = false
    private var shouldResumeAfterWake = false
    private var isClosingPlayer = false
    private var playerCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var prefersPlayerSubtitlesEnabled = false
    private var preferredPlayerSubtitleTrack: PlayerSubtitleTrackPreference?
    private var lastAutomaticConfigurationRefreshAttemptAt: Date?
    private var configurationRefreshTask: Task<Bool, Never>?
    private var configurationRefreshSessionID = UUID()
    private var nodeRuntimeStatusTask: Task<Void, Never>?
    private var nodeProfileRevisionTask: Task<Void, Never>?
    private var managedRuntimeStatusTask: Task<Void, Never>?
    private var observedNodeProfileRevision: NodeProfileRevisionSnapshot?
    private var activeNodeRuntimeEndpoint: URL?
    private var lastReadyNodeRuntimeEndpoint: URL?
    private var nodeRuntimeUnavailableReason = L10n.string("node.runtime.not-started", fallback: "Node Runtime has not started")

    static func bootstrap() -> AppState {
        do {
            let environment = try AppEnvironment.live()
            let warning = environment.recoveredDatabaseDirectory.map {
                UserFacingError(
                    title: L10n.string("database.recovered.title", fallback: "Database Recovered"),
                    message: L10n.string("database.recovered.message", fallback: "The damaged database was preserved at %@ and a new database was created.", $0.path)
                )
            }
            return AppState(environment: environment, startupError: warning)
        } catch {
            return AppState(
                environment: nil,
                startupError: UserFacingError(
                    title: L10n.string("app.initialization.failed", fallback: "Unable to Initialize App"),
                    message: CommonUserFacingErrorMapper.message(for: error)
                        ?? LogRedactor.text(error.localizedDescription)
                )
            )
        }
    }

    private var importedIdentityEnabled: Bool { liveReferenceStore?.importedIdentityAcceptanceEnabled == true }
    @Published private(set) var importedIdentityMapping: ImportedCatalogMapping?
    @Published private var importedIdentityMappingFailed = false
    private var importedIdentitySource: LiveSourceID?
    private var importedIdentityGeneration: ImportedCatalogGeneration?
    private var deletingImportedSourceIDs = Set<UUID>()
    private var importedRefreshDownloads: [UUID: Task<LoadedLiveSource, Error>] = [:]
    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    var importedRetirementBeforeTransactionForTesting: (() async throws -> Void)?
    #endif

    func selectImportedIdentitySource(_ sourceID: LiveSourceID?) {
        if case .imported(let id) = sourceID, importedIdentityEnabled {
            guard !deletingImportedSourceIDs.contains(id), liveSources.contains(where: { $0.id == id }) else { return }
        }
        let validationSource: UUID?
        if case .imported(let id) = sourceID { validationSource = id } else { validationSource = nil }
        if liveValidationSelectedSource != validationSource {
            if let old = liveValidationSelectedSource { cancelLiveSourceValidation(old) }
            liveValidationSelectedSource = validationSource
        }
        guard importedIdentityEnabled, sourceID != importedIdentitySource else { return }
        if case .imported(let previous) = importedIdentitySource {
            // The existing availability worker can write Hidden state. Revoke
            // it too, including A -> B -> A, before changing authority.
            cancelLiveSourceValidation(previous)
            importedRefreshDownloads[previous]?.cancel()
            importedRefreshDownloads[previous] = nil
        }
        importedIdentityGeneration?.invalidate()
        importedIdentityMapping = nil
        importedIdentitySource = sourceID
        importedIdentityMappingFailed = false
        importedIdentityGeneration = nil
        if case .imported(let id) = sourceID {
            let generation = ImportedCatalogGeneration(sourceID: id)
            importedIdentityGeneration = generation
            Task { await refreshImportedIdentityMapping(id, generation: generation) }
        }
    }

    private func refreshImportedIdentityMapping(_ id: UUID, generation: ImportedCatalogGeneration) async {
        guard let database = liveReferenceStore, generation.isCurrent, !deletingImportedSourceIDs.contains(id),
              liveSources.contains(where: { $0.id == id }), loadedLivePlaylists[id] != nil else { return }
        do {
            let mapping = try await database.importedCatalogMapping(sourceID: id, generation: generation)
            guard generation.isCurrent, importedIdentityGeneration === generation,
                  importedIdentitySource == .imported(id) else { return }
            importedIdentityMapping = mapping
        } catch {
            guard generation.isCurrent else { return }
            importedIdentityMappingFailed = true
            show(error, title: "频道身份暂不可用")
        }
    }

    private func editImportedIdentityReferences(_ id: UUID,
        edits: [(channel: LiveChannel, kind: MigrationReferenceKind, present: Bool)],
        validationPermit: LiveValidationPermit? = nil) async throws {
        guard !deletingImportedSourceIDs.contains(id), let database = liveReferenceStore,
              let mapping = importedIdentityMapping, mapping.sourceID == id else {
            throw ImportedExecutionError.blocked
        }
        let updated = try await database.setImportedReferences(mapping: mapping, edits: edits, validationPermit: validationPermit)
        guard mapping.generation.isCurrent, importedIdentityGeneration === mapping.generation else { return }
        importedIdentityMapping = updated
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    // Intercepts only the final load boundary. Tests exercise the production
    // selection/flow/recovery path without a window, network, or user database.
    var importedRouteLoadForTesting: ((LivePlaybackCandidate, ResolvedMedia, UUID) async throws -> Void)?
    func acceptImportedRoutesForTesting(_ source: StoredLiveSource, playlist: LivePlaylist) {
        liveSources.removeAll { $0.id == source.id }; liveSources.append(source)
        publishImportedCatalog(playlist, sourceID: source.id)
    }
    func setImportedRouteDeletingForTesting(_ id: UUID, deleting: Bool) {
        if deleting { deletingImportedSourceIDs.insert(id); revokeImportedPlaybackFlow(id) }
        else { deletingImportedSourceIDs.remove(id) }
    }
    func failImportedRouteForTesting() {
        recoverLivePlaybackAfterFailure(requestID: activePlayerRequestID, message: "fixture failure")
    }
    var importedRouteFlowForTesting: UUID? { livePlaybackNavigationContext?.flowID }
    var importedRoutePlaybackCatalogForTesting: AcceptedImportedCatalog? { livePlaybackNavigationContext?.importedCatalog }
    var importedRouteRecoveryTaskForTesting: Task<Void, Never>? { livePlaybackRecoveryTask }
    var importedRouteAttemptCountForTesting: Int { livePlaybackNavigationContext?.attemptedTransports.count ?? 0 }
    func setImportedIdentityCatalogForTesting(_ source: StoredLiveSource) throws {
        liveSources.removeAll { $0.id == source.id }; liveSources.append(source)
        publishImportedCatalog(try LiveSourceParser().parse(source.rawData, baseURL: source.baseURL), sourceID: source.id)
    }
    #endif

    init(
        environment: AppEnvironment?,
        startupError: UserFacingError? = nil,
        initialProviders: [String: SiteProvider] = [:],
        liveReferenceStore: SQLiteStore? = nil,
        liveCredentialStore: (any XtreamCredentialStoring)? = nil,
        playbackDisplaySleep: PlaybackDisplaySleepController? = nil,
        detailRequestTimeout: TimeInterval = 90,
        configurationActionTimeout: TimeInterval = 90
    ) {
        self.environment = environment
        self.playerAudioPreference = environment?.player.audioPreference ?? .init()
        self.configurationActionTimeout = configurationActionTimeout.isFinite ? min(600, max(0.001, configurationActionTimeout)) : 90
        self.detailRequestTimeout = detailRequestTimeout.isFinite ? min(600, max(0.001, detailRequestTimeout)) : 90
        self.playbackDisplaySleep = playbackDisplaySleep ?? PlaybackDisplaySleepController()
        self.playbackDisplaySleep.beginSession(activePlayerRequestID)
        self.liveReferenceStore = liveReferenceStore ?? environment?.database
        self.liveCredentialStore = liveCredentialStore
            ?? environment?.xtreamCredentialStore
        providers = initialProviders
        playerRenderClient = environment?.player.renderPlayer
        presentedError = startupError
        self.playerSnapshot.volume = environment?.player.audioPreference.volume ?? 100
        self.playerSnapshot.isMuted = environment?.player.audioPreference.muted ?? false
        environment?.player.onRenderClientChanged = { [weak self] player in
            self?.playerRenderClient = player
        }
    }

    func playerRenderSurfaceDidBecomeReady(_ renderOwnerID: UUID) {
        playerRenderSurfaceGate.markReady(renderOwnerID: renderOwnerID)
    }

    func playerRenderSurfaceDidBecomeUnavailable(_ renderOwnerID: UUID) {
        playerRenderSurfaceGate.markUnavailable(renderOwnerID: renderOwnerID)
    }

    func start() async {
        guard !hasCompletedStartup, let environment else { return }
        startNodeRuntimeStatusMonitoring()
        startNodeProfileRevisionMonitoring()
        startManagedRuntimeStatusMonitoring()
        await recoverAndroidMaintenanceIfNeeded()
        androidRuntimeModeSnapshot = await environment
            .androidRuntimeModeCoordinator.refresh()
        _ = try? await environment.androidRuntimeManager.refresh()
        isLoading = true
        defer {
            isLoading = false
            hasCompletedStartup = true
        }
        do {
            configurations = try await environment.database.configurations()
            liveSources = try await environment.database.liveSources()
            activeConfigurationRecord = try await environment.database.activeConfiguration()

            // Restore the last valid configuration and home snapshot before
            // performing any remote Node bundle work. This keeps startup
            // useful offline and prevents a misleading "no configuration"
            // screen while a remote script is downloading.
            activeXtreamCredentials = try? await xtreamCredentials(
                for: activeConfigurationRecord
            )
            try await validateXtreamAccountIfNeeded(
                record: activeConfigurationRecord,
                credentials: activeXtreamCredentials
            )
            try loadActiveConfigurationContent()
            try await loadSettings()
            await prepareActiveConfigurationHome(
                reportLoadErrors: false,
                loadBehavior: .none,
                entryReason: .applicationRestore
            )
            try await reloadUserData()
            startPlayerEventLoop()

            if let record = activeConfigurationRecord,
               let sourceURL = activeNodeRuntimeSourceURL {
                scheduleNodeConfigurationPreparation(
                    recordID: record.id,
                    sourceURL: sourceURL
                )
                // The restore pass above already selected the site and
                // published its cached home. Starting CatPaw must continue
                // from that state, not run a second destructive preparation.
                isHomeLoading = selectedSiteKey != nil
                Task { @MainActor [weak self] in
                    await self?.loadSelectedSiteHome(
                        refreshConfigurationIfNeeded: false,
                        reportErrors: false
                    )
                }
            } else {
                await prepareActiveConfigurationHome(
                    reportLoadErrors: false,
                    entryReason: .applicationRestore
                )
            }
        } catch {
            isHomeLoading = false
            show(error, title: L10n.string("app.startup.failed", fallback: "Startup Failed"))
        }
    }

    @discardableResult
    func importConfiguration(
        source: ConfigurationSource,
        name: String?,
        progress: (ConfigurationImportPhase) -> Void = { _ in }
    ) async -> Bool {
        let result = await importConfigurationForSheet(
            source: source,
            name: name,
            progress: progress,
            onCommitStarted: {}
        )
        switch result {
        case .success:
            return true
        case .cancelled:
            return false
        case .failure(let error):
            presentedError = error
            return false
        }
    }

    func testXtreamProviderConnection(
        serverURL: String,
        username: String,
        password: String
    ) async throws -> XtreamAccount {
        guard let environment else {
            throw AppError.configuration(
                L10n.string(
                    "app.environment.not-initialized",
                    fallback: "The app environment has not been initialized"
                )
            )
        }
        let endpoint = try Self.xtreamEndpoint(serverURL)
        let credentials = try Self.xtreamCredentials(
            username: username,
            password: password
        )
        return try await XtreamClient(
            endpoint: endpoint,
            credentials: credentials,
            httpClient: environment.xtreamHTTPClient,
            userAgent: Self.xtreamUserAgent
        ).authenticate()
    }

    @discardableResult
    func saveXtreamProvider(
        id: UUID?,
        displayName: String,
        serverURL: String,
        username: String,
        password: String
    ) async -> Bool {
        guard let environment else { return false }
        guard xtreamProviderOperationID == nil,
              configurationImportOperationID == nil,
              requestedConfigurationID == nil else {
            show(
                AppError.configuration(
                    L10n.string(
                        "xtream.operation.in-progress",
                        fallback: "Another provider operation is already in progress."
                    )
                ),
                title: L10n.string(
                    "xtream.save.failed",
                    fallback: "Unable to Save Xtream Provider"
                )
            )
            return false
        }
        let operationID = UUID()
        xtreamProviderOperationID = operationID
        isLoading = true
        defer {
            if xtreamProviderOperationID == operationID {
                xtreamProviderOperationID = nil
                isLoading = false
            }
        }

        var previousCredentials: XtreamCredentials?
        var targetProviderID: UUID?
        var didWriteCredentials = false
        var didCommitDatabase = false
        do {
            let existing: StoredConfiguration?
            if let id {
                guard let record = configurations.first(where: { $0.id == id }),
                      record.sourceKind == .xtream else {
                    throw AppError.configuration(
                        L10n.string(
                            "xtream.edit.missing",
                            fallback: "The Xtream provider no longer exists."
                        )
                    )
                }
                existing = record
            } else {
                existing = nil
            }
            let providerID = existing?.id ?? UUID()
            targetProviderID = providerID
            let endpoint = try Self.xtreamEndpoint(serverURL)
            let credentials = try Self.xtreamCredentials(
                username: username,
                password: password
            )
            let descriptor = try XtreamProviderConfiguration(
                providerID: providerID,
                displayName: displayName,
                serverBaseURL: endpoint.serverURL
            )

            // Authentication is a hard pre-commit gate. Neither the Keychain
            // nor SQLite changes when the account is rejected.
            _ = try await XtreamClient(
                endpoint: endpoint,
                credentials: credentials,
                httpClient: environment.xtreamHTTPClient,
                userAgent: Self.xtreamUserAgent
            ).authenticate()
            try Task.checkCancellation()

            nativeLiveAccountMutationIDs.insert(providerID)
            liveEPG.remove(.xtream(providerID))
            await environment.productionEPGRepository.invalidate(EPGSourceKey(.xtream(providerID)))
            if existing == nil || activeConfigurationRecord?.id == providerID {
                invalidateXtreamLiveCatalog()
            }
            defer { nativeLiveAccountMutationIDs.remove(providerID) }
            await closeXtreamLivePlaybackIfNeeded(
                providerID: existing == nil ? nil : providerID
            )
            guard xtreamProviderOperationID == operationID else {
                throw CancellationError()
            }
            previousCredentials = try await environment.xtreamCredentialStore
                .credentials(for: providerID)
            try await environment.xtreamCredentialStore.save(
                credentials,
                for: providerID
            )
            didWriteCredentials = true
            try Task.checkCancellation()

            let record = StoredConfiguration(
                id: providerID,
                name: descriptor.displayName,
                sourceKind: .xtream,
                sourceValue: descriptor.serverBaseURL.absoluteString,
                baseURL: descriptor.serverBaseURL,
                rawData: try descriptor.encoded(),
                updatedAt: Date(),
                isActive: existing?.isActive ?? true
            )
            let shouldPublish = existing == nil || record.isActive
            if existing == nil {
                configurations = try await environment.database
                    .commitImportedConfiguration(record)
                didCommitDatabase = true
            } else {
                try await environment.database.saveConfiguration(record)
                didCommitDatabase = true
                configurations = configurations.map {
                    $0.id == record.id ? record : $0
                }.sorted {
                    if $0.isActive != $1.isActive {
                        return $0.isActive && !$1.isActive
                    }
                    return $0.updatedAt > $1.updatedAt
                }
            }

            if shouldPublish {
                configurationPostActivationSessionID = UUID()
                configurationPostActivationTask?.cancel()
                configurationPostActivationTask = nil
                commitConfigurationActivation(
                    PreparedConfigurationActivation(
                        record: record,
                        configuration: descriptor.providerConfiguration,
                        nodeRuntimeEndpoint: nil,
                        nodeRuntimeSourceURL: nil,
                        xtreamCredentials: credentials
                    )
                )
                scheduleNodeRuntimeStop(for: record.id)
                await loadSearchSiteScope()
                _ = await prepareActiveConfigurationHome(
                    reportLoadErrors: false,
                    loadBehavior: .background,
                    entryReason: .configurationSwitch
                )
                try? await reloadHistory()
            }
            return true
        } catch {
            if didWriteCredentials && !didCommitDatabase {
                if let previousCredentials, let targetProviderID {
                    try? await environment.xtreamCredentialStore.save(
                        previousCredentials,
                        for: targetProviderID
                    )
                } else if let targetProviderID {
                    try? await environment.xtreamCredentialStore
                        .deleteCredentials(for: targetProviderID)
                }
            }
            if !AsyncCancellationPolicy.isCancellation(error) {
                show(
                    error,
                    title: L10n.string(
                        "xtream.save.failed",
                        fallback: "Unable to Save Xtream Provider"
                    )
                )
            }
            return false
        }
    }

    private static func xtreamEndpoint(_ rawValue: String) throws
        -> XtreamEndpoint {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else {
            throw XtreamProviderConfigurationError.invalidServerURL
        }
        return try XtreamEndpoint(serverURL: url)
    }

    private static func xtreamCredentials(
        username: String,
        password: String
    ) throws -> XtreamCredentials {
        let normalizedUsername = username.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedUsername.isEmpty,
              !password.isEmpty,
              normalizedUsername.utf8.count <= 1_024,
              password.utf8.count <= 1_024,
              !normalizedUsername.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }),
              !password.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AppError.configuration(
                L10n.string(
                    "xtream.credentials.invalid",
                    fallback: "Enter a valid Xtream username and password."
                )
            )
        }
        return XtreamCredentials(
            username: normalizedUsername,
            password: password
        )
    }

    func importConfigurationForSheet(
        source: ConfigurationSource,
        name: String?,
        progress: (ConfigurationImportPhase) -> Void = { _ in },
        onCommitStarted: () -> Void
    ) async -> ImportOperationResult {
        guard let environment else {
            return .failure(
                UserFacingError(
                    title: L10n.string("configuration.import.failed", fallback: "Configuration Import Failed"),
                    message: L10n.string("app.environment.not-initialized", fallback: "The app environment has not been initialized")
                )
            )
        }
        guard configurationImportOperationID == nil else {
            return .failure(
                UserFacingError(
                    title: L10n.string("configuration.import.failed", fallback: "Configuration Import Failed"),
                    message: L10n.string("configuration.import.in-progress", fallback: "Another configuration is already being imported. Wait for it to finish.")
                )
            )
        }
        clearConfigurationSwitchFeedback()
        let operationID = UUID()
        configurationImportOperationID = operationID
        isLoading = true
        defer {
            if configurationImportOperationID == operationID {
                configurationImportOperationID = nil
                isLoading = false
            }
        }
        do {
            try ensureConfigurationImportIsActive(operationID)
            if case .remote(let url) = source,
               NodeBundleRuntimeService.supports(url) {
                progress(.startingNodeRuntime)
            } else if case .remote = source {
                progress(.downloadingAndParsing)
            } else {
                progress(.parsing)
            }
            let importedConfigurationID = UUID()
            let payload = try await loadConfigurationForImport(
                source,
                configurationID: importedConfigurationID
            )
            try ensureConfigurationImportIsActive(operationID)
            let sourceDetails: (StoredConfigurationSourceKind, String?)
            switch source {
            case .remote(let url):
                sourceDetails = (.remote, url.absoluteString)
            case .localFile(let url):
                sourceDetails = (.localFile, url.path)
            case .pasted:
                sourceDetails = (.pasted, nil)
            }
            let record = StoredConfiguration(
                id: importedConfigurationID,
                name: name?.nonEmpty ?? source.displayName,
                sourceKind: sourceDetails.0,
                sourceValue: sourceDetails.1,
                baseURL: payload.loaded.baseURL,
                rawData: payload.loaded.rawData,
                updatedAt: payload.loaded.loadedAt,
                isActive: true
            )
            progress(.saving)
            try ensureConfigurationImportIsActive(operationID)
            if livePlaybackSourceID?.isXtream == true {
                invalidateXtreamLiveCatalog()
                await closeXtreamLivePlaybackIfNeeded()
                try ensureConfigurationImportIsActive(operationID)
            }
            onCommitStarted()
            try ensureConfigurationImportIsActive(operationID)
            let committedConfigurations = try await environment.database
                .commitImportedConfiguration(record)

            // SQLite commit is the operation's cancellation boundary. The
            // Sheet disables cancellation before this point, and the model
            // state below is committed synchronously before the next await.
            progress(.activating)
            configurationPostActivationSessionID = UUID()
            configurationPostActivationTask?.cancel()
            configurationPostActivationTask = nil
            resetSearchForConfigurationChange()
            invalidateCatPawHomeLoads()
            categoryLoadSessionID = UUID()
            configurations = committedConfigurations
            configurationRefreshSessionID = UUID()
            configurationRefreshTask?.cancel()
            configurationRefreshTask = nil
            lastAutomaticConfigurationRefreshAttemptAt = payload.loaded.loadedAt
            activeConfigurationRecord = record
            activeConfiguration = payload.loaded.configuration
            activeXtreamCredentials = nil
            let importedUsesNodeRuntime: Bool
            if case .remote(let url) = source {
                importedUsesNodeRuntime = NodeBundleRuntimeService.supports(url)
            } else {
                importedUsesNodeRuntime = false
            }
            if importedUsesNodeRuntime {
                activeNodeRuntimeEndpoint = payload.nodeRuntimeEndpoint
                nodeRuntimeUnavailableReason = ""
            } else {
                activeNodeRuntimeEndpoint = nil
                nodeRuntimeUnavailableReason = L10n.string("node.runtime.not-used", fallback: "Node Runtime is not used by the current configuration")
            }
            rebuildProviders()
            selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                from: supportedSites
            )
            if !importedUsesNodeRuntime {
                scheduleNodeRuntimeStop(for: record.id)
            }
            await loadSearchSiteScope()
            await prepareActiveConfigurationHome(
                entryReason: .configurationSwitch
            )
            try await reloadHistory()
            let summary = ConfigurationImportCapabilityAnalyzer.summary(
                configurationID: record.id,
                configurationName: record.name,
                configuration: payload.loaded.configuration,
                baseURL: payload.loaded.baseURL,
                androidBridgeUnavailable: androidRuntimeStatus.phase
                    == .unavailable
                    || androidRuntimeStatus.phase == .failed
            )
            return .success(summary)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(
                userFacingError(for: error, title: L10n.string("configuration.import.failed", fallback: "Configuration Import Failed"))
            )
        }
    }

    private func ensureConfigurationImportIsActive(
        _ operationID: UUID
    ) throws {
        try Task.checkCancellation()
        guard configurationImportOperationID == operationID else {
            throw CancellationError()
        }
    }

    func refreshActiveConfiguration() async {
        clearConfigurationSwitchFeedback()
        guard activeConfigurationRecord?.sourceKind == .remote else {
            show(
                AppError.configuration(L10n.string("configuration.refresh.remote-only", fallback: "Only URL configurations can be refreshed directly")),
                title: L10n.string("common.refresh.failed", fallback: "Unable to Refresh")
            )
            return
        }
        _ = await refreshActiveConfigurationIfNeeded(
            force: true,
            reportErrors: true
        )
    }

    var canImportCatPawProfile: Bool {
        activeConfigurationUsesNodeRuntime
            && activeConfigurationRecord?.id != nil
    }

    func canImportCatPawSettings(for configurationID: UUID) async -> Bool {
        guard canImportCatPawProfile,
              activeConfigurationRecord?.id == configurationID,
              let environment else { return false }
        let supported = await environment.nodeBundleRuntime
            .supportsProfileImport(configurationID: configurationID)
        return supported && activeConfigurationRecord?.id == configurationID
    }

    func importCatPawProfile(from fileURL: URL) async {
        guard let environment,
              let record = activeConfigurationRecord,
              let sourceURL = activeNodeRuntimeSourceURL else {
            show(
                AppError.configuration(L10n.string("configuration.catpaw.enable-first", fallback: "Enable a CatPawOpen Node configuration first.")),
                title: L10n.string("configuration.catpaw.import.failed", fallback: "Unable to Import CatPaw Configuration")
            )
            return
        }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            _ = try await environment.nodeBundleRuntime.importProfile(
                data,
                from: sourceURL,
                configurationID: record.id
            )
            _ = await refreshActiveConfigurationIfNeeded(
                force: true,
                reportErrors: true
            )
            presentedError = UserFacingError(
                title: L10n.string("configuration.catpaw.imported.title", fallback: "CatPaw Configuration Imported"),
                message: L10n.string("configuration.catpaw.imported.message", fallback: "Dynamic provider directories were reloaded with the new profile. No restart is required.")
            )
        } catch {
            show(error, title: L10n.string("configuration.catpaw.import.failed", fallback: "Unable to Import CatPaw Configuration"))
        }
    }

    static func shouldAutomaticallyRefreshConfiguration(
        sourceKind: StoredConfigurationSourceKind,
        lastAttemptAt: Date?,
        now: Date,
        interval: TimeInterval = AppStateTiming.automaticConfigurationRefreshInterval
    ) -> Bool {
        guard sourceKind == .remote else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= max(0, interval)
    }

    @discardableResult
    private func refreshActiveConfigurationIfNeeded(
        force: Bool = false,
        reportErrors: Bool = false,
        now: Date = Date()
    ) async -> Bool {
        guard let record = activeConfigurationRecord,
              record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let url = URL(string: sourceValue) else {
            return false
        }
        guard force || Self.shouldAutomaticallyRefreshConfiguration(
            sourceKind: record.sourceKind,
            lastAttemptAt: lastAutomaticConfigurationRefreshAttemptAt,
            now: now
        ) else {
            return false
        }
        if let configurationRefreshTask {
            return await configurationRefreshTask.value
        }

        lastAutomaticConfigurationRefreshAttemptAt = now
        configurationRefreshSessionID = UUID()
        let refreshSessionID = configurationRefreshSessionID
        let task = Task { [weak self] in
            guard let self, let environment = self.environment else { return false }
            do {
                let loaded = try await self.loadConfiguration(.remote(url))
                guard !Task.isCancelled,
                      self.configurationRefreshSessionID == refreshSessionID,
                      self.activeConfigurationRecord?.id == record.id else {
                    return false
                }
                let change = ConfigurationPublicationChangePolicy.classify(
                    previous: record,
                    incomingRawData: loaded.rawData,
                    incomingBaseURL: loaded.baseURL,
                    usesNodeRuntime: NodeBundleRuntimeService.supports(url)
                )
                let updated = StoredConfiguration(
                    id: record.id,
                    name: record.name,
                    sourceKind: record.sourceKind,
                    sourceValue: sourceValue,
                    baseURL: loaded.baseURL,
                    rawData: loaded.rawData,
                    updatedAt: loaded.loadedAt,
                    isActive: true
                )
                try await environment.database.saveConfiguration(updated)
                self.configurations = try await environment.database.configurations()
                self.activeConfigurationRecord = updated
                self.activeConfiguration = loaded.configuration

                if change == .transportOnly, let endpoint = loaded.baseURL {
                    self.rebindCatPawHomeTransport(to: endpoint)
                }
                guard change == .semantic else { return false }
                self.invalidateCatPawHomeLoads()
                self.categoryLoadSessionID = UUID()
                self.rebuildProviders(preservingDetailRoute: self.activeConfigurationUsesNodeRuntime)
                let previousSiteKey = self.selectedSiteKey
                if !self.supportedSites.contains(where: {
                    $0.key == self.selectedSiteKey
                }) {
                    self.selectedSiteKey = self.supportedSites.first?.key
                }
                if self.selectedSiteKey != previousSiteKey {
                    try? await self.reloadHistory()
                }
                self.discardHomeContentIfNeeded(
                    for: self.currentHomeContentIdentity
                )
                self.activeCategoryQueryKey = nil
                self.selectedCategoryID = nil
                self.selectedCategoryFilters = [:]
                self.categoryPage = nil
                self.homePresentationSelection = .empty
                self.categoryPaginationError = nil
                return true
            } catch {
                if reportErrors {
                    self.show(error, title: L10n.string("configuration.refresh.failed", fallback: "Configuration Refresh Failed"))
                }
                // Automatic refresh is best-effort. Keep the last valid cached
                // configuration so an offline launch remains usable.
                return false
            }
        }
        configurationRefreshTask = task
        let changed = await task.value
        if configurationRefreshSessionID == refreshSessionID {
            configurationRefreshTask = nil
        }
        return changed
    }

    var configurationMenuSelectionID: UUID? {
        requestedConfigurationID ?? activeConfigurationRecord?.id
    }

    var isSwitchingConfiguration: Bool {
        requestedConfigurationID != nil
    }

    private func clearConfigurationSwitchFeedback() {
        guard ConfigurationSwitchFeedbackPolicy.shouldClear(
            configurationSwitchFeedback,
            hasActiveActivationRequest: requestedConfigurationID != nil
        ) else {
            return
        }
        configurationSwitchFeedbackDismissTask?.cancel()
        configurationSwitchFeedbackDismissTask = nil
        configurationSwitchFeedback = .idle
    }

    /// Shared activation entry point used by both Settings and the Home
    /// toolbar. Every request receives a generation; a newer request cancels
    /// the previous waiter and is the only generation allowed to publish or
    /// surface an error.
    func activateConfiguration(_ id: UUID) async {
        guard environment != nil,
              configurationImportOperationID == nil,
              xtreamProviderOperationID == nil,
              let record = configurations.first(where: { $0.id == id }) else {
            return
        }
        if activeConfigurationRecord?.id == id,
           requestedConfigurationID == nil {
            // Re-selecting the already active source is also an explicit
            // acknowledgement of any earlier failed switch attempt.
            clearConfigurationSwitchFeedback()
            return
        }
        if requestedConfigurationID == id {
            await configurationActivationTask?.value
            return
        }

        let token = configurationActivationTracker.begin(id)
        configurationSwitchFeedbackDismissTask?.cancel()
        configurationSwitchFeedbackDismissTask = nil
        requestedConfigurationID = id
        configurationSwitchFeedback = ConfigurationSwitchFeedbackPolicy.switching(
            token: token,
            targetName: record.name
        )
        configurationActivationTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConfigurationActivation(record, token: token)
        }
        configurationActivationTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func performConfigurationActivation(
        _ record: StoredConfiguration,
        token: ConfigurationActivationToken
    ) async {
        guard let environment else { return }
        var didCommitConfiguration = false
        defer {
            if configurationActivationTracker.owns(token) {
                configurationActivationTracker.finish(token)
                requestedConfigurationID = nil
                configurationActivationTask = nil
            }
        }

        do {
            let prepared = try await prepareConfigurationActivation(record)
            try ensureConfigurationActivationIsCurrent(token)

            if prepared.record != record {
                try await environment.database.saveConfiguration(prepared.record)
                try ensureConfigurationActivationIsCurrent(token)
            }

            if livePlaybackSourceID?.isXtream == true {
                invalidateXtreamLiveCatalog()
                await closeXtreamLivePlaybackIfNeeded()
                try ensureConfigurationActivationIsCurrent(token)
            }

            // Persistence is intentionally the final awaited step before the
            // synchronous model commit. A stale generation may finish this
            // tiny transaction, but it cannot publish; the current generation
            // always owns the final persisted and visible selection.
            try await environment.database.activateConfiguration(id: record.id)
            try ensureConfigurationActivationIsCurrent(token)

            commitConfigurationActivation(prepared)
            didCommitConfiguration = true
            if ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetUsesNodeRuntime: prepared.usesNodeRuntime,
                ownsCurrentRequest: configurationActivationTracker.owns(token)
            ) {
                scheduleNodeRuntimeStop(for: prepared.record.id)
            } else if let sourceURL = prepared.nodeRuntimeSourceURL {
                scheduleNodeConfigurationPreparation(
                    recordID: prepared.record.id,
                    sourceURL: sourceURL
                )
            }
            await loadSearchSiteScope()
            try ensureConfigurationActivationIsCurrent(token)
            _ = await prepareActiveConfigurationHome(
                reportLoadErrors: false,
                loadBehavior: .background,
                entryReason: .configurationSwitch
            )
            // Configuration activation and the selected site's network health
            // are separate facts. Once the configuration/provider graph has
            // committed, a home request failure belongs to the site UI and
            // must not turn the configuration switch into a persistent error.
            try ensureConfigurationActivationIsCurrent(token)
            try await reloadHistory()
            try ensureConfigurationActivationIsCurrent(token)
            configurationSwitchFeedback = ConfigurationSwitchFeedbackPolicy.success(
                current: configurationSwitchFeedback,
                token: token,
                targetName: record.name,
                ownsCurrentRequest: configurationActivationTracker.owns(token)
            )
            scheduleConfigurationSwitchFeedbackDismissal(for: token)
        } catch {
            let ownsCurrentRequest = configurationActivationTracker.owns(token)
            guard ConfigurationActivationErrorPolicy.shouldPresent(
                error,
                ownsCurrentRequest: ownsCurrentRequest
            ) else {
                // A newer source selection owns the UI and any eventual error.
                return
            }
            if didCommitConfiguration {
                // The selected configuration is already the persisted and
                // visible authority. Failures from home/history refresh are
                // follow-up data errors, not configuration-switch failures.
                configurationSwitchFeedback = ConfigurationSwitchFeedbackPolicy.success(
                    current: configurationSwitchFeedback,
                    token: token,
                    targetName: record.name,
                    ownsCurrentRequest: ownsCurrentRequest
                )
                scheduleConfigurationSwitchFeedbackDismissal(for: token)
                return
            }
            let presentation = userFacingError(for: error, title: L10n.string("configuration.switch.failed", fallback: "Configuration Switch Failed"))
            configurationSwitchFeedback = ConfigurationSwitchFeedbackPolicy.failure(
                current: configurationSwitchFeedback,
                token: token,
                targetName: record.name,
                message: presentation.message,
                ownsCurrentRequest: ownsCurrentRequest
            )
            // The detailed failure remains available in the home load state;
            // do not leave a stale red marker beside the source picker for the
            // rest of the app session.
            scheduleConfigurationSwitchFeedbackDismissal(for: token)
        }
    }

    private func scheduleConfigurationSwitchFeedbackDismissal(
        for token: ConfigurationActivationToken
    ) {
        configurationSwitchFeedbackDismissTask?.cancel()
        configurationSwitchFeedbackDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self,
                  ConfigurationSwitchFeedbackPolicy.shouldDismiss(
                    self.configurationSwitchFeedback,
                    token: token
                  ) else {
                return
            }
            self.configurationSwitchFeedback = .idle
            self.configurationSwitchFeedbackDismissTask = nil
        }
    }

    private func prepareConfigurationActivation(
        _ record: StoredConfiguration
    ) async throws -> PreparedConfigurationActivation {
        guard environment != nil else {
            throw AppError.configuration(L10n.string("app.environment.not-initialized", fallback: "The app environment has not been initialized"))
        }
        if record.sourceKind == .remote,
           let sourceValue = record.sourceValue,
           let sourceURL = URL(string: sourceValue),
           NodeBundleRuntimeService.supports(sourceURL) {
            // The imported record is the last known-good catalogue. Commit it
            // immediately; validated cache startup and publisher I/O belong to
            // post-activation work and must never extend the visible switch.
            return PreparedConfigurationActivation(
                record: record,
                configuration: try ConfigurationParser().parse(record.rawData),
                nodeRuntimeEndpoint: nil,
                nodeRuntimeSourceURL: sourceURL,
                xtreamCredentials: nil
            )
        }
        let configuration = try Self.configurationContent(for: record)
        let credentials = try await xtreamCredentials(for: record)
        // An explicitly selected Xtream provider must pass the same server
        // account-state gate as Test Connection and Save.
        try await validateXtreamAccountIfNeeded(
            record: record,
            credentials: credentials
        )
        return PreparedConfigurationActivation(
            record: record,
            configuration: configuration,
            nodeRuntimeEndpoint: nil,
            nodeRuntimeSourceURL: nil,
            xtreamCredentials: credentials
        )
    }

    private func ensureConfigurationActivationIsCurrent(
        _ token: ConfigurationActivationToken
    ) throws {
        try Task.checkCancellation()
        guard configurationActivationTracker.owns(token) else {
            throw CancellationError()
        }
    }

    private func commitConfigurationActivation(
        _ prepared: PreparedConfigurationActivation
    ) {
        cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
        resetSearchForConfigurationChange()
        configurationRefreshSessionID = UUID()
        configurationRefreshTask?.cancel()
        configurationRefreshTask = nil
        invalidateCatPawHomeLoads()
        categoryLoadSessionID = UUID()
        cancelDetailRequest()

        var activeRecord = prepared.record
        activeRecord.isActive = true
        configurations = configurations.map { existing in
            if existing.id == activeRecord.id {
                return activeRecord
            }
            var inactive = existing
            inactive.isActive = false
            return inactive
        }
        activeConfigurationRecord = activeRecord
        activeConfiguration = prepared.configuration
        if activeRecord.sourceKind == .xtream {
            let sourceID = LiveSourceID.xtream(activeRecord.id)
            LiveBrowserPreferenceStore().setSelectedSource(sourceID)
            shortcutLiveSourceSelection = ShortcutLiveSourceSelection(
                requestID: UUID(),
                sourceID: sourceID
            )
        }
        activeXtreamCredentials = prepared.xtreamCredentials
        lastAutomaticConfigurationRefreshAttemptAt = activeRecord.updatedAt
        activeNodeRuntimeEndpoint = prepared.nodeRuntimeEndpoint
        nodeRuntimeUnavailableReason = prepared.usesNodeRuntime
            ? L10n.string("node.runtime.starting-cache", fallback: "Node Runtime is starting from the local cache")
            : L10n.string("node.runtime.not-used", fallback: "Node Runtime is not used by the current configuration")
        rebuildProviders()
        selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
            from: supportedSites
        )
        activeCategoryQueryKey = nil
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = .empty
        categoryPaginationError = nil
        discardHomeContentIfNeeded(for: currentHomeContentIdentity)
    }

    private func scheduleNodeRuntimeStop(for configurationID: UUID) {
        guard let environment else { return }
        configurationPostActivationSessionID = UUID()
        let sessionID = configurationPostActivationSessionID
        configurationPostActivationTask?.cancel()
        configurationPostActivationTask = Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentPostActivationWork(
                    sessionID: sessionID,
                    configurationID: configurationID
                  ),
                  !self.activeConfigurationUsesNodeRuntime else {
                return
            }
            await environment.nodeBundleRuntime.stop()
            guard self.isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: configurationID
            ) else {
                return
            }
            self.configurationPostActivationTask = nil
        }
    }

    private func scheduleNodeConfigurationPreparation(
        recordID: UUID,
        sourceURL: URL
    ) {
        configurationPostActivationSessionID = UUID()
        let sessionID = configurationPostActivationSessionID
        configurationPostActivationTask?.cancel()
        nodeRuntimeUnavailableReason = L10n.string("node.runtime.starting-cache", fallback: "Node Runtime is starting from the local cache")
        configurationPostActivationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareNodeConfigurationInBackground(
                recordID: recordID,
                sourceURL: sourceURL,
                sessionID: sessionID
            )
        }
    }

    private func prepareNodeConfigurationInBackground(
        recordID: UUID,
        sourceURL: URL,
        sessionID: UUID
    ) async {
        guard let environment,
              isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
              ) else {
            return
        }

        var restoredValidatedCache = false
        do {
            let cached = try await environment.nodeBundleRuntime
                .loadConfiguration(
                    from: sourceURL,
                    configurationID: recordID,
                    startupStrategy: .cacheOnly
                )
            try Task.checkCancellation()
            guard isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
            ) else {
                return
            }
            restoredValidatedCache = true
            try await publishPreparedNodeConfiguration(
                cached,
                recordID: recordID,
                sessionID: sessionID
            )
        } catch is CancellationError {
            return
        } catch {
            // A missing or rejected cache is not the terminal state: the
            // publisher refresh below may install a newly validated bundle.
            guard isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
            ) else {
                return
            }
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = L10n.string("node.runtime.refreshing-bundle", fallback: "Local cache unavailable; refreshing the Node bundle in the background")
        }

        do {
            try Task.checkCancellation()
            let refreshed = try await environment.nodeBundleRuntime
                .refreshConfiguration(
                    from: sourceURL,
                    configurationID: recordID
                )
            try Task.checkCancellation()
            guard isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
            ) else {
                return
            }
            try await publishPreparedNodeConfiguration(
                refreshed,
                recordID: recordID,
                sessionID: sessionID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
            ) else {
                return
            }
            // A refresh failure must not take a validated running cache back
            // offline. Only expose the error when no usable Runtime was found.
            if !restoredValidatedCache, activeNodeRuntimeEndpoint == nil {
                nodeRuntimeUnavailableReason = L10n.string(
                    "node.runtime.failed.user-facing",
                    fallback: "Node Runtime is unavailable. Export diagnostics for details."
                )
            }
        }

        guard isCurrentPostActivationWork(
            sessionID: sessionID,
            configurationID: recordID
        ) else {
            return
        }
        configurationPostActivationTask = nil
    }

    private func publishPreparedNodeConfiguration(
        _ loaded: LoadedConfiguration,
        recordID: UUID,
        sessionID: UUID
    ) async throws {
        guard let environment,
              isCurrentPostActivationWork(
                sessionID: sessionID,
                configurationID: recordID
              ),
              var record = activeConfigurationRecord else {
            throw CancellationError()
        }
        let change = ConfigurationPublicationChangePolicy.classify(
            previous: record,
            incomingRawData: loaded.rawData,
            incomingBaseURL: loaded.baseURL,
            usesNodeRuntime: true
        )
        record.baseURL = loaded.baseURL
        record.rawData = loaded.rawData
        record.updatedAt = loaded.loadedAt
        record.isActive = true
        try await environment.database.saveConfiguration(record)
        guard isCurrentPostActivationWork(
            sessionID: sessionID,
            configurationID: recordID
        ) else {
            throw CancellationError()
        }

        configurations = configurations.map {
            $0.id == recordID ? record : $0
        }
        activeConfigurationRecord = record
        activeConfiguration = loaded.configuration
        lastAutomaticConfigurationRefreshAttemptAt = loaded.loadedAt
        activeNodeRuntimeEndpoint = loaded.baseURL
        lastReadyNodeRuntimeEndpoint = loaded.baseURL
        nodeRuntimeUnavailableReason = ""
        let previousSiteKey = selectedSiteKey
        if change == .semantic {
            invalidateCatPawHomeLoads()
            categoryLoadSessionID = UUID()
        } else if let endpoint = loaded.baseURL {
            rebindCatPawHomeTransport(to: endpoint)
        }
        let requiresProviderRebuild = change == .semantic || providers.isEmpty
        if requiresProviderRebuild {
            rebuildProviders(preservingDetailRoute: true)
            if !supportedSites.contains(where: { $0.key == selectedSiteKey }) {
                selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                    from: supportedSites
                )
            }
            await loadSearchSiteScope()
        }
        guard isCurrentPostActivationWork(
            sessionID: sessionID,
            configurationID: recordID
        ) else {
            throw CancellationError()
        }
        if change == .semantic || selectedSiteKey != previousSiteKey
            || homeContentIdentity?.configurationID != recordID {
            await prepareActiveConfigurationHome(
                reportLoadErrors: false,
                loadBehavior: .background,
                entryReason: .configurationSwitch
            )
        } else if isHomeLoading || homeLoadErrorMessage != nil {
            Task { @MainActor [weak self] in
                await self?.loadSelectedSiteHome(reportErrors: false)
            }
        }
    }

    private func isCurrentPostActivationWork(
        sessionID: UUID,
        configurationID: UUID
    ) -> Bool {
        ConfigurationPostActivationPolicy.isCurrent(
            expectedSessionID: sessionID,
            currentSessionID: configurationPostActivationSessionID,
            expectedConfigurationID: configurationID,
            activeConfigurationID: activeConfigurationRecord?.id
        )
    }

    func deleteConfiguration(_ id: UUID) async {
        guard let environment else { return }
        clearConfigurationSwitchFeedback()
        let deletingActiveConfiguration = activeConfigurationRecord?.id == id
        let deletingXtream = configurations.first(where: { $0.id == id })?
            .sourceKind == .xtream
        if deletingXtream {
            nativeLiveAccountMutationIDs.insert(id)
            if deletingActiveConfiguration { invalidateXtreamLiveCatalog() }
        }
        defer { nativeLiveAccountMutationIDs.remove(id) }
        if deletingXtream {
            await closeXtreamLivePlaybackIfNeeded(providerID: id)
        }
        var deletedXtreamCredentials: XtreamCredentials?
        var didDeleteXtreamCredentials = false
        var didDeleteConfiguration = false
        do {
            if deletingXtream {
                deletedXtreamCredentials = try await environment
                    .xtreamCredentialStore.credentials(for: id)
                try await environment.xtreamCredentialStore
                    .deleteCredentials(for: id)
                didDeleteXtreamCredentials = true
            }
            try await environment.database.deleteConfiguration(id: id)
            if deletingXtream {
                liveEPG.remove(.xtream(id))
                await environment.productionEPGRepository.invalidate(EPGSourceKey(.xtream(id)))
            }
            didDeleteConfiguration = true
            if deletingActiveConfiguration {
                resetSearchForConfigurationChange()
            }
            configurations = try await environment.database.configurations()
            if activeConfigurationRecord?.id == id {
                activeConfigurationRecord = try await environment.database.activeConfiguration()
                selectedSiteKey = nil
                activeXtreamCredentials = try? await xtreamCredentials(
                    for: activeConfigurationRecord
                )
                try loadActiveConfigurationContent()
                if let record = activeConfigurationRecord,
                   let sourceURL = activeNodeRuntimeSourceURL {
                    scheduleNodeConfigurationPreparation(
                        recordID: record.id,
                        sourceURL: sourceURL
                    )
                } else if let record = activeConfigurationRecord {
                    scheduleNodeRuntimeStop(for: record.id)
                } else {
                    configurationPostActivationSessionID = UUID()
                    configurationPostActivationTask?.cancel()
                    configurationPostActivationTask = nil
                    Task {
                        await environment.nodeBundleRuntime.stop()
                    }
                }
                await loadSearchSiteScope()
                await prepareActiveConfigurationHome(
                    entryReason: .configurationSwitch
                )
                try await reloadHistory()
            }
        } catch {
            if didDeleteXtreamCredentials,
               !didDeleteConfiguration,
               let deletedXtreamCredentials {
                try? await environment.xtreamCredentialStore.save(
                    deletedXtreamCredentials,
                    for: id
                )
            }
            show(error, title: L10n.string("configuration.delete.failed", fallback: "Configuration Deletion Failed"))
        }
    }

    func resumeHomeIfNeeded(reportErrors: Bool = false) async {
        guard selectedSection == .home,
              !isHomeSearchPresented,
              activeConfigurationRecord != nil,
              selectedSiteKey != nil,
              !isRecoveringHome else {
            return
        }
        isRecoveringHome = true
        defer { isRecoveringHome = false }

        if siteHome == nil {
            await restoreCachedSiteHome(loadsCategoryContent: false)
        }
        if siteHome == nil {
            _ = await loadSelectedSiteHome(reportErrors: reportErrors)
            captureHomeBrowsingSnapshotIfValid()
            return
        }

        restoreHomeBrowsingSnapshotIfPossible()
        guard let home = siteHome else { return }
        let snapshot = currentHomeContentIdentity.flatMap {
            homeBrowsingSnapshots[$0]
        }
        let action = HomeResumePolicy.action(
            home: home,
            selection: homePresentationSelection,
            selectedCategoryID: selectedCategoryID,
            hasCategoryPage: categoryPage != nil,
            lastCategoryID: snapshot?.categoryID
        )
        switch action {
        case .keep:
            captureHomeBrowsingSnapshotIfValid()
        case .restoreCategory(let id):
            homePresentationSelection = .category(id)
            captureHomeBrowsingSnapshotIfValid()
        case .showRecommendation:
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .recommendation
            homeLoadErrorMessage = nil
            captureHomeBrowsingSnapshotIfValid()
        case .loadCategory(let id):
            guard home.categories.contains(where: {
                $0.id == id && $0.resolvedContentKind == .media
            }) else { return }
            if await loadCategory(
                id: id,
                reportErrors: reportErrors
            ) {
                homeLoadErrorMessage = nil
                captureHomeBrowsingSnapshotIfValid()
            }
        case .showActions:
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .actions
            homeLoadErrorMessage = nil
            captureHomeBrowsingSnapshotIfValid()
        case .loadHome:
            _ = await loadSelectedSiteHome(reportErrors: reportErrors)
            captureHomeBrowsingSnapshotIfValid()
        case .unavailable:
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .empty
        }
    }

    func selectSite(_ key: String) async {
        let targetIdentity = activeConfigurationRecord.map {
            HomeContentIdentity(configurationID: $0.id, siteKey: key)
        }
        guard HomeSiteSelectionPolicy.requiresTransition(
            requestedKey: key,
            currentKey: selectedSiteKey,
            hasCurrentHome: siteHome != nil,
            isCurrentContent: homeContentIdentity == targetIdentity,
            isHomeLoading: isHomeLoading
        ) else {
            if siteHome != nil {
                await resumeHomeIfNeeded()
            }
            return
        }
        captureHomeBrowsingSnapshotIfValid()
        homeResumeTask?.cancel()
        homeResumeTask = nil
        invalidatePendingNodeHomeOperation(nextSiteKey: key)
        cancelActiveCloudAuthorizationInteraction(
            nextIdentity: targetIdentity
        )
        invalidateCatPawHomeLoads()
        categoryLoadSessionID = UUID()
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        isHomeLoading = true
        homeLoadErrorMessage = nil
        homeLoadErrorIsLocalPluginCache = false
        selectedSiteKey = key
        discardHomeContentIfNeeded(for: currentHomeContentIdentity)
        activeCategoryQueryKey = nil
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = .empty
        await restoreCachedSiteHome()
        await loadSelectedSiteHome()
        captureHomeBrowsingSnapshotIfValid()
    }

    var categoryBrowsingKey: CategoryQueryKey? { activeCategoryQueryKey }
    var categoryBrowseAnchor: PosterBrowseAnchor? { activeCategoryQueryKey.flatMap { categoryTabSessionStore.state(for: $0)?.browseAnchor } }
    var categoryPresentationRevision: UInt64 { activeCategoryQueryKey.flatMap { categoryTabSessionStore.state(for: $0)?.presentationRevision } ?? 0 }
    var categoryHasPendingUpdate: Bool { activeCategoryQueryKey.flatMap { categoryTabSessionStore.state(for: $0)?.pendingRefreshPage } != nil }

    func recordCategoryViewport(for key: CategoryQueryKey, anchor: PosterBrowseAnchor, atTop: Bool, interacted: Bool) {
        guard key == activeCategoryQueryKey else { return }
        categoryTabSessionStore.recordViewport(for: key, anchor: anchor, atTop: atTop, interacted: interacted)
    }

    func acceptCategoryUpdate() {
        guard let key = activeCategoryQueryKey,
              let state = categoryTabSessionStore.acceptRefresh(for: key) else { return }
        applyCategoryQueryState(state, preserveCurrentPage: false)
        captureHomeBrowsingSnapshotIfValid()
    }

    private func trimCategoryQueries() {
        let removed = categoryTabSessionStore.trim(keeping: activeCategoryQueryKey)
        for key in removed { cancelCategoryRequestTasks(for: key) }
    }

    @discardableResult
    func loadCategory(
        id: String,
        page: Int = 1,
        filters: [String: String]? = nil,
        reportErrors: Bool = true,
        forceRefresh: Bool = false
    ) async -> Bool {
        guard let key = selectedSiteKey,
              let provider = providers[key],
              let contentIdentity = currentHomeContentIdentity,
              let category = siteHome?.categories.first(where: {
                  $0.id == id && $0.resolvedContentKind == .media
              }),
              let namespace = categoryTabNamespace(for: key) else {
            return false
        }
        if page == 1 { cancelScheduledCategoryFilterLoad() }
        let loadingNextPage = page > 1
        let queryKey = categoryTabSessionStore.queryKey(
            namespace: namespace,
            category: category,
            requestedFilters: filters
        )
        if loadingNextPage {
            guard activeCategoryQueryKey == queryKey,
                  selectedCategoryID == id else {
                return false
            }
        } else if !forceRefresh,
                  activeCategoryQueryKey == queryKey,
                  categoryTabSessionStore.state(for: queryKey)?
                    .hasValidContent == true,
                  categoryPage != nil {
            // Re-selecting the current, fully loaded Tab is deliberately a
            // no-op. Do not churn loading state or invoke the provider.
            return true
        }

        if forceRefresh {
            cancelCategoryRequestTasks(for: queryKey)
        }
        let decision = categoryTabSessionStore.beginRequest(
            for: queryKey,
            page: page,
            forceRefresh: forceRefresh
        )
        let preservesCurrentPage = CategoryReloadPresentationPolicy
            .shouldPreserveCurrentPage(
                requestedPage: page,
                requestedCategoryID: id,
                currentCategoryID: selectedCategoryID,
                hasCurrentPage: categoryPage != nil
            )
        switch decision {
        case .cached:
            categoryLoadSessionID = UUID()
            guard let state = categoryTabSessionStore.state(for: queryKey) else {
                return false
            }
            activeCategoryQueryKey = queryKey
            applyCategoryQueryState(state, preserveCurrentPage: false)
            captureHomeBrowsingSnapshotIfValid()
            return true
        case .rejected:
            return false
        case .join(let generation):
            if !loadingNextPage {
                categoryLoadSessionID = UUID()
            }
            activeCategoryQueryKey = queryKey
            if let state = categoryTabSessionStore.state(for: queryKey) {
                applyCategoryQueryState(
                    state,
                    preserveCurrentPage: preservesCurrentPage
                )
            }
            let requestKey = CategoryPageRequestKey(
                queryKey: queryKey,
                page: page
            )
            guard let entry = categoryRequestTasks[requestKey],
                  entry.generation == generation else {
                categoryTabSessionStore.invalidateRequests(for: queryKey)
                return await loadCategory(
                    id: id,
                    page: page,
                    filters: queryKey.filters,
                    reportErrors: reportErrors,
                    forceRefresh: forceRefresh
                )
            }
            return await entry.task.value
        case .start(let generation):
            if !loadingNextPage {
                categoryLoadSessionID = UUID()
            }
            activeCategoryQueryKey = queryKey
            if let state = categoryTabSessionStore.state(for: queryKey) {
                applyCategoryQueryState(
                    state,
                    preserveCurrentPage: preservesCurrentPage
                )
            }
            let requestKey = CategoryPageRequestKey(
                queryKey: queryKey,
                page: page
            )
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.performCategoryRequest(
                    requestKey: requestKey,
                    generation: generation,
                    provider: provider,
                    contentIdentity: contentIdentity,
                    reportErrors: reportErrors
                )
            }
            categoryRequestTasks[requestKey] = CategoryRequestTaskEntry(
                generation: generation,
                task: task
            )
            return await task.value
        }
    }

    private func performCategoryRequest(
        requestKey: CategoryPageRequestKey,
        generation: UInt64,
        provider: SiteProvider,
        contentIdentity: HomeContentIdentity,
        reportErrors: Bool
    ) async -> Bool {
        let queryKey = requestKey.queryKey
        let page = requestKey.page
        defer {
            if categoryRequestTasks[requestKey]?.generation == generation {
                categoryRequestTasks[requestKey] = nil
            }
        }
        do {
            var loaded = try await provider.category(
                id: queryKey.categoryID,
                page: page,
                filters: queryKey.filters
            )
            if provider.site.extra["okNodeRuntime"] == .bool(true),
               let endpoint = activeNodeRuntimeEndpoint {
                loaded = NodeRuntimeContentTransport.rebind(
                    loaded,
                    to: endpoint
                )
            }
            if page == 1,
               let home = siteHome,
               let promoted = HomePresentationPolicy
                .promotingSingletonEmptyCategoryToAction(
                    in: home,
                    categoryID: queryKey.categoryID,
                    page: loaded
                ) {
                guard categoryTabSessionStore.ownsRequest(
                    for: queryKey,
                    page: page,
                    generation: generation
                ) else { return false }
                categoryTabSessionStore.invalidateQuery(queryKey)
                guard shouldPublishCategoryQuery(queryKey) else { return true }
                publishHomeContent(promoted, identity: contentIdentity)
                if let publishedHome = siteHome {
                    await cacheSiteHome(
                        publishedHome,
                        identity: contentIdentity
                    )
                }
                activeCategoryQueryKey = nil
                selectedCategoryID = nil
                selectedCategoryFilters = [:]
                categoryPage = nil
                homePresentationSelection = .actions
                categoryPaginationError = nil
                // The ordinary category mapper intentionally keeps media
                // only. If its first page consisted entirely of protocol
                // action cards, the structural promotion above is the point
                // where we can safely replay the category through the action
                // mapper and preserve those upstream actions.
                return await loadActionCategory(
                    id: queryKey.categoryID,
                    filters: queryKey.filters,
                    reportErrors: reportErrors
                )
            }
            guard let state = categoryTabSessionStore.completeRequest(
                for: queryKey,
                page: page,
                generation: generation,
                loaded: loaded
            ) else { return false }
            trimCategoryQueries()
            guard shouldPublishCategoryQuery(queryKey) else { return true }
            applyCategoryQueryState(state, preserveCurrentPage: false)
            captureHomeBrowsingSnapshotIfValid()
            // A handled but stalled response is not progress. Do not ask the
            // viewport scheduler to immediately reevaluate the same page.
            return state.paginationError == nil && state.refreshError == nil
        } catch let authorization as NodeWebAuthorizationRequired {
            guard let state = categoryTabSessionStore.failRequest(
                for: queryKey,
                page: page,
                generation: generation,
                message: authorization.localizedDescription,
                isCancellation: false
            ), shouldPublishCategoryQuery(queryKey) else {
                return false
            }
            applyCategoryQueryState(
                state,
                preserveCurrentPage: state.page == nil && categoryPage != nil
            )
            presentNodeConfiguration(
                authorization,
                pending: .category(
                    identity: contentIdentity,
                    siteKey: queryKey.namespace.siteKey,
                    id: queryKey.categoryID,
                    page: page,
                    filters: queryKey.filters
                )
            )
            return false
        } catch {
            let isCancellation = AsyncCancellationPolicy.isCancellation(error)
            let state = categoryTabSessionStore.failRequest(
                for: queryKey,
                page: page,
                generation: generation,
                message: localizedRuntimeErrorMessage(error),
                isCancellation: isCancellation,
                issueKind: error is CategoryPageResponseError ? .uncertain : .failed
            )
            guard let state,
                  shouldPublishCategoryQuery(queryKey) else {
                return false
            }
            applyCategoryQueryState(
                state,
                preserveCurrentPage: state.page == nil && categoryPage != nil
            )
            if !isCancellation, page == 1, reportErrors {
                show(error, title: L10n.string("category.load.failed", fallback: "Category Loading Failed"))
            }
            return false
        }
    }

    /// The filter request belongs to the query, not to the grid/popover that
    /// disappears when staging replaces loaded posters with a loading view.
    func scheduleCategoryFilterLoad(id: String, filters: [String: String]) {
        guard let queryKey = stageCategoryFilters(id: id, filters: filters) else { return }
        cancelScheduledCategoryFilterLoad()
        let requestID = UUID()
        categoryFilterLoadID = requestID
        categoryFilterLoadTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.categoryFilterLoadID == requestID else { return }
            self.categoryFilterLoadTask = nil
            self.categoryFilterLoadID = nil
            // Include configuration revision and provider identity: an old
            // popover must never apply its filters to an identically named
            // category in a different provider/configuration.
            guard self.shouldPublishCategoryQuery(queryKey) else { return }
            await self.loadCategory(id: queryKey.categoryID, filters: queryKey.filters)
        }
    }

    private func cancelScheduledCategoryFilterLoad() {
        categoryFilterLoadTask?.cancel()
        categoryFilterLoadTask = nil
        categoryFilterLoadID = nil
    }

    @discardableResult
    func stageCategoryFilters(
        id: String,
        filters: [String: String]
    ) -> CategoryQueryKey? {
        guard selectedCategoryID == id,
              let siteKey = selectedSiteKey,
              let namespace = categoryTabNamespace(for: siteKey),
              let category = siteHome?.categories.first(where: {
                  $0.id == id && $0.resolvedContentKind == .media
              }) else { return nil }
        // Change visible query ownership immediately, before the short UI
        // debounce elapses. The prior filter request may still populate its
        // own QueryState, but can no longer publish into this selection.
        categoryLoadSessionID = UUID()
        let queryKey = categoryTabSessionStore.queryKey(
            namespace: namespace,
            category: category,
            requestedFilters: filters
        )
        activeCategoryQueryKey = queryKey
        selectedCategoryFilters = queryKey.filters
        if let state = categoryTabSessionStore.state(for: queryKey),
           state.hasValidContent {
            applyCategoryQueryState(state, preserveCurrentPage: false)
        } else {
            categoryPage = nil
            isLoading = true
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            homeLoadErrorMessage = nil
        }
        captureHomeBrowsingSnapshotIfValid()
        return queryKey
    }

    func clearCategory() {
        cancelScheduledCategoryFilterLoad()
        isLoading = false
        categoryLoadSessionID = UUID()
        activeCategoryQueryKey = nil
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = siteHome.map {
            HomePresentationPolicy.selection(for: $0, preserving: nil)
        } ?? .empty
        captureHomeBrowsingSnapshotIfValid()
    }

    func openConfigurationCategory(_ item: SiteActionItem) async {
        guard case .actionCategory(let categoryID) = item.resolvedRoute else {
            await performHomeAction(item)
            return
        }
        guard let identity = currentHomeContentIdentity,
              identity.siteKey == item.siteKey,
              let category = siteHome?.categories.first(where: {
                  $0.id == categoryID && $0.resolvedContentKind == .action
              }) else {
            show(
                AppError.site(L10n.string("configuration.page.updated", fallback: "The configuration page was updated. Open it again.")),
                title: item.title
            )
            return
        }
        configurationCategoryLoadSessionID = UUID()
        let sessionID = configurationCategoryLoadSessionID
        let presentationID = UUID()
        configurationCategoryPresentation = ConfigurationCategoryPresentation(
            id: presentationID,
            sourceIdentity: identity,
            categoryID: categoryID,
            title: category.name,
            items: [],
            isLoading: true,
            errorMessage: nil
        )
        await loadConfigurationCategory(
            presentationID: presentationID,
            sessionID: sessionID,
            category: category
        )
    }

    func refreshConfigurationCategory() async {
        guard let presentation = configurationCategoryPresentation,
              presentation.sourceIdentity == currentHomeContentIdentity,
              let category = siteHome?.categories.first(where: {
                  $0.id == presentation.categoryID
                    && $0.resolvedContentKind == .action
              }) else {
            closeConfigurationCategory()
            show(
                AppError.site(L10n.string("configuration.page.updated", fallback: "The configuration page was updated. Open it again.")),
                title: L10n.string("configuration.center", fallback: "Configuration Center")
            )
            return
        }
        configurationCategoryLoadSessionID = UUID()
        let sessionID = configurationCategoryLoadSessionID
        configurationCategoryPresentation?.isLoading = true
        configurationCategoryPresentation?.errorMessage = nil
        await loadConfigurationCategory(
            presentationID: presentation.id,
            sessionID: sessionID,
            category: category
        )
    }

    func closeConfigurationCategory() {
        if let pending = pendingTVBoxConfigurationAction,
           pending.refreshTarget.categoryPresentationID == configurationCategoryPresentation?.id {
            cancelPendingTVBoxConfigurationAction(pending.id)
        }
        configurationCategoryLoadSessionID = UUID()
        configurationCategoryPresentation = nil
    }

    private func loadConfigurationCategory(
        presentationID: UUID,
        sessionID: UUID,
        category: VideoCategory
    ) async {
        guard let identity = currentHomeContentIdentity,
              let provider = providers[identity.siteKey] else {
            closeConfigurationCategory()
            return
        }
        do {
            let page = try await provider.actionCategory(
                id: category.id,
                page: 1,
                filters: HomePresentationPolicy.defaultFilters(for: category)
            )
            guard configurationCategoryLoadSessionID == sessionID,
                  currentHomeContentIdentity == identity,
                  configurationCategoryPresentation?.id == presentationID else {
                return
            }
            let items = HomePresentationPolicy.actionItems(
                from: page,
                inheritedFrom: category
            )
            configurationCategoryPresentation?.items = items
            configurationCategoryPresentation?.isLoading = false
            configurationCategoryPresentation?.errorMessage = items.isEmpty
                ? L10n.string("configuration.actions.empty", fallback: "This configuration category did not return any available actions.")
                : nil
        } catch is CancellationError {
            guard configurationCategoryLoadSessionID == sessionID,
                  configurationCategoryPresentation?.id == presentationID else {
                return
            }
            configurationCategoryPresentation?.isLoading = false
        } catch {
            guard configurationCategoryLoadSessionID == sessionID,
                  currentHomeContentIdentity == identity,
                  configurationCategoryPresentation?.id == presentationID else {
                return
            }
            configurationCategoryPresentation?.isLoading = false
            configurationCategoryPresentation?.errorMessage =
                AsyncCancellationPolicy.isCancellation(error)
                ? nil
                : localizedRuntimeErrorMessage(error)
        }
    }

    @discardableResult
    private func loadActionCategory(
        id: String,
        filters: [String: String],
        reportErrors: Bool
    ) async -> Bool {
        guard let key = selectedSiteKey,
              let provider = providers[key],
              let contentIdentity = currentHomeContentIdentity,
              let actionCategory = siteHome?.categories.first(where: {
                  $0.id == id && $0.resolvedContentKind == .action
              }) else {
            return false
        }
        categoryLoadSessionID = UUID()
        let sessionID = categoryLoadSessionID
        activeCategoryQueryKey = nil
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = .actions
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        isLoading = true
        defer {
            if categoryLoadSessionID == sessionID {
                isLoading = false
            }
        }
        do {
            let loaded = try await provider.actionCategory(
                id: id,
                page: 1,
                filters: filters
            )
            guard CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: categoryLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ), var updatedHome = siteHome,
              homeContentIdentity == contentIdentity else {
                return false
            }
            updatedHome.actionItems = HomePresentationPolicy.actionItems(
                from: loaded,
                inheritedFrom: actionCategory,
                fallback: SiteActionItem(
                    siteKey: provider.site.key,
                    siteName: provider.site.name,
                    itemID: actionCategory.id,
                    title: actionCategory.name,
                    remarks: L10n.string("configuration.action.open", fallback: "Open Configuration Action"),
                    route: .actionCategory(categoryID: actionCategory.id)
                )
            )
            if let scopeID = cloudAccountScopeID(
                for: provider,
                sourceIdentity: contentIdentity
            ) {
                updatedHome.actionItems = CloudAccountStatusPresentationPolicy
                    .applying(
                        to: updatedHome.actionItems,
                        accountLabel: actionCategory.name,
                        scopeID: scopeID,
                        store: cloudAccountStatusStore
                    )
            }
            publishHomeContent(updatedHome, identity: contentIdentity)
            await cacheSiteHome(updatedHome, identity: contentIdentity)
            homeLoadErrorMessage = nil
            return true
        } catch let authorization as NodeWebAuthorizationRequired {
            guard CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: categoryLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ) else { return false }
            homeLoadErrorMessage = authorization.localizedDescription
            presentNodeConfiguration(
                authorization,
                pending: .category(
                    identity: contentIdentity,
                    siteKey: key,
                    id: id,
                    page: 1,
                    filters: filters
                )
            )
            return false
        } catch is CancellationError {
            guard CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: categoryLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ) else { return false }
            return false
        } catch {
            guard CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: categoryLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ) else { return false }
            if AsyncCancellationPolicy.isCancellation(error) {
                homeLoadErrorMessage = nil
                return false
            }
            homeLoadErrorMessage = localizedRuntimeErrorMessage(error)
            if reportErrors {
                show(error, title: L10n.string("configuration.action.load.failed", fallback: "Action Content Failed to Load"))
            }
            return false
        }
    }

    @discardableResult
    func loadSelectedSiteHome(
        refreshConfigurationIfNeeded: Bool = true,
        reportErrors: Bool = true,
        forceCategoryRefresh: Bool = false,
        forceHomeRefresh: Bool = false
    ) async -> Bool {
        if refreshConfigurationIfNeeded {
            _ = await refreshActiveConfigurationIfNeeded()
        }
        guard let key = selectedSiteKey,
              let provider = providers[key],
              provider.capability != .unsupportedSpider,
              let contentIdentity = currentHomeContentIdentity else {
            isHomeLoading = false
            return selectedSiteKey == nil
        }
        guard let loadKey = catPawHomeLoadKey(siteKey: key) else {
            return await performSelectedSiteHomeLoad(
                key: key,
                provider: provider,
                contentIdentity: contentIdentity,
                reportErrors: reportErrors,
                forceCategoryRefresh: forceCategoryRefresh
            )
        }

        if forceHomeRefresh {
            catPawHomeRequestTasks[loadKey]?.task.cancel()
            catPawHomeRequestTasks[loadKey] = nil
        }
        var decision = catPawHomeLoadCoordinator.begin(
            key: loadKey,
            forceRefresh: forceHomeRefresh
        )
        if case .join(let generation) = decision {
            if let entry = catPawHomeRequestTasks[loadKey],
               entry.generation == generation {
                return await entry.task.value
            }
            // Recover from an interrupted owner without manufacturing a
            // second concurrent request for a still-registered generation.
            catPawHomeLoadCoordinator.invalidate(key: loadKey)
            decision = catPawHomeLoadCoordinator.begin(
                key: loadKey,
                forceRefresh: false
            )
        }
        guard case .start(let generation) = decision else { return false }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performSelectedSiteHomeLoad(
                key: key,
                provider: provider,
                contentIdentity: contentIdentity,
                reportErrors: reportErrors,
                forceCategoryRefresh: forceCategoryRefresh
            )
        }
        catPawHomeRequestTasks[loadKey] = CatPawHomeRequestTaskEntry(
            generation: generation,
            task: task
        )
        let result = await task.value
        if catPawHomeLoadCoordinator.owns(
            key: loadKey,
            generation: generation
        ) {
            catPawHomeLoadCoordinator.finish(
                key: loadKey,
                generation: generation
            )
            if catPawHomeRequestTasks[loadKey]?.generation == generation {
                catPawHomeRequestTasks[loadKey] = nil
            }
        }
        return result
    }

    private func performSelectedSiteHomeLoad(
        key: String,
        provider: SiteProvider,
        contentIdentity: HomeContentIdentity,
        reportErrors: Bool,
        forceCategoryRefresh: Bool
    ) async -> Bool {
        cancelAndroidHomeLoad()
        homeLoadSessionID = UUID()
        let sessionID = homeLoadSessionID
        isHomeLoading = true
        homeLoadErrorIsLocalPluginCache = false
        defer {
            if homeLoadSessionID == sessionID {
                isHomeLoading = false
            }
        }
        do {
            var loaded: SiteHome
            if provider is AndroidDexSpiderSiteProvider {
                let taskID = UUID()
                let task = Task { try await provider.home() }
                androidHomeLoadTask = task
                androidHomeLoadTaskID = taskID
                defer {
                    if androidHomeLoadTaskID == taskID {
                        androidHomeLoadTask = nil
                        androidHomeLoadTaskID = nil
                    }
                }
                loaded = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } else {
                loaded = try await provider.home()
            }
            guard HomeLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: homeLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ) else {
                return false
            }
            if provider.site.extra["okNodeRuntime"] == .bool(true),
               let endpoint = activeNodeRuntimeEndpoint {
                loaded = NodeRuntimeContentTransport.rebind(
                    loaded,
                    to: endpoint
                )
            }
            publishHomeContent(loaded, identity: contentIdentity)
            homeLoadErrorMessage = nil
            homeLoadErrorIsLocalPluginCache = false
            await cacheSiteHome(loaded, identity: contentIdentity)
            if HomeSiteRolePolicy.isContentHome(loaded) {
                await persistSelectedSitePreference(key)
            }
            let didApplyPresentation = await applyHomePresentation(
                loaded,
                identity: contentIdentity,
                reportCategoryErrors: reportErrors,
                forceCategoryRefresh: forceCategoryRefresh
            )
            guard didApplyPresentation else { return false }
            captureHomeBrowsingSnapshotIfValid()
            return true
        } catch is CancellationError {
            guard HomeLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID, currentSessionID: homeLoadSessionID,
                requestedSiteKey: key, currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity, currentIdentity: currentHomeContentIdentity
            ) else { return false }
            homeLoadErrorMessage = nil
            homeLoadErrorIsLocalPluginCache = false
            return false
        } catch {
            guard HomeLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID, currentSessionID: homeLoadSessionID,
                requestedSiteKey: key, currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity, currentIdentity: currentHomeContentIdentity
            ) else { return false }
            let shouldPresent = UserVisibleAsyncErrorPolicy.shouldPresent(
                error,
                ownsSession: true
            )
            homeLoadErrorMessage = shouldPresent
                ? localizedRuntimeErrorMessage(error)
                : nil
            homeLoadErrorIsLocalPluginCache = shouldPresent
                && error is AndroidDexJarCacheFailure
            if reportErrors && shouldPresent {
                show(error, title: L10n.string("provider.load.failed", fallback: "Provider Failed to Load"))
            }
            return false
        }
    }

    func refreshHome() async {
        clearConfigurationSwitchFeedback()
        _ = await refreshActiveConfigurationIfNeeded(
            force: true,
            reportErrors: true
        )
        await loadSelectedSiteHome(
            refreshConfigurationIfNeeded: false,
            forceCategoryRefresh: true,
            forceHomeRefresh: true
        )
    }

    /// Page recovery does not invalidate provider configuration or successful pages.
    func refreshHomePage() async {
        guard !isLoading, !isHomeLoading, !isLoadingNextCategoryPage else { return }
        if categoryHasPendingUpdate { acceptCategoryUpdate(); return }
        if let categoryID = selectedCategoryID, let page = categoryPage {
            _ = await loadCategory(id: categoryID,
                page: categoryPaginationError == nil ? 1 : page.pagination.page + 1,
                filters: selectedCategoryFilters, reportErrors: false, forceRefresh: categoryPaginationError == nil)
        } else {
            await loadSelectedSiteHome(refreshConfigurationIfNeeded: false,
                forceCategoryRefresh: true, forceHomeRefresh: true)
        }
    }

    /// Called when an already-loaded home screen becomes visible or the app
    /// returns to the foreground. Only reload the site when the remote config
    /// actually changed; otherwise keep the current home content undisturbed.
    func refreshHomeConfigurationIfNeeded() async {
        guard HomeAutomaticRefreshPolicy.allowsRefresh(
            hasCompletedStartup: hasCompletedStartup,
            selectedSection: selectedSection,
            isHomeSearchPresented: isHomeSearchPresented
        ) else { return }
        let changed = await refreshActiveConfigurationIfNeeded()
        guard changed,
              selectedSection == .home,
              !isHomeSearchPresented else {
            return
        }
        await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
    }

    func loadDetail(
        _ summary: VideoSummary,
        performanceTrace: DetailPerformanceTrace? = nil,
        forceRefresh: Bool = false,
        favorite: FavoriteRecord? = nil
    ) async {
        guard !Task.isCancelled else { return }
        if summary.resolvedContentKind == .action {
            await performHomeAction(SiteActionItem(summary: summary))
            return
        }
        if summary.isFolder {
            openSearchFolder(
                summary,
                replacingPath: true,
                origin: isHomeSearchPresented ? .searchResults : .home
            )
            return
        }
        if summary.videoID.hasPrefix("msearch:") {
            detailRouteSummary = nil
            selectedDetail = nil
            pendingDetailSummary = nil
            presentHomeSearch()
            search(summary.title, context: .discoveryFallback)
            return
        }
        guard let provider = providers[summary.siteKey] else {
            if !isDetailPagePresented {
                detailHomeSearchReturnSnapshot = DetailHomeSearchReturnPolicy.capture(
                    isHomeSearchPresented: isHomeSearchPresented, selectedSiteKey: selectedSearchSiteKey,
                    folderPath: searchFolderPath, folderOrigin: searchFolderOrigin)
            }
            cancelDetailRequest()
            selectedDetail = nil
            pendingDetailSummary = nil
            detailRequestSummary = summary
            detailRouteSummary = summary
            detailSuggestedSearch = nil
            detailLoadState = .failed(L10n.string("provider.unavailable.history-preserved", fallback: "Provider %@ is unavailable in the current configuration. The record will be preserved.", summary.siteKey))
            return
        }
        if summary.action?.nonEmpty != nil || (provider.capability == .javaDexSpider
            && AndroidDexSpiderSiteProvider.isPanConfigurationAPI(provider.site.api)) {
            await performHomeAction(SiteActionItem(summary: summary))
            return
        }
        if let favorite { detailFavoriteExpectation = favorite }
        else if detailRequestSummary?.id != summary.id { detailFavoriteExpectation = nil }
        detailFavoriteSource = activeConfigurationRecord.map { FavoriteSourceContext(configuration: $0, site: provider.site) }
        if let recovery = favoriteRecoveryContext,
           recovery.expected.videoID == summary.videoID, recovery.expected.siteKey == summary.siteKey,
           recovery.source.configurationID == activeConfigurationRecord?.id {
            detailFavoriteExpectation = recovery.expected
            guard detailFavoriteSource == recovery.source else {
                detailRouteSummary = summary; selectedDetail = nil
                detailLoadState = .failed(L10n.string("favorites.source.changed", fallback: "This source's server or account has changed. Use Confirm Source to verify this favorite again."))
                return
            }
        } else { favoriteRecoveryContext = nil }
        let key = detailResponseCache.key(for: summary)
        if detailRequestKey == key, let task = detailRequestTask {
            // One page owns the request; repeated taps join its completion.
            await task.value
            return
        }
        let retainingDetail = selectedDetail != nil && detailRequestSummary?.id == summary.id
        if !isDetailPagePresented {
            detailHomeSearchReturnSnapshot = DetailHomeSearchReturnPolicy.capture(
                isHomeSearchPresented: isHomeSearchPresented,
                selectedSiteKey: selectedSearchSiteKey,
                folderPath: searchFolderPath,
                folderOrigin: searchFolderOrigin
            )
        }
        cancelDetailRequest()
        let trace = performanceTrace ?? DetailPerformanceTrace(
            title: summary.title, siteKey: summary.siteKey, videoID: summary.videoID,
            searchActiveAtTap: isSearching
        )
        detailRequestSummary = summary
        // Media navigates immediately. Configuration entries are dispatched
        // above by their item/provider contract, never by engine type alone.
        detailRouteSummary = summary
        detailLoadState = .loading
        detailSuggestedSearch = nil
        if !forceRefresh, let cached = detailResponseCache.value(for: key) {
            guard acceptsFavoriteDetail(cached) else { return }
            trace.markCacheHit()
            trace.markSelectedDetail(searchActive: isSearching)
            activeDetailPerformanceTrace = trace
            pendingDetailSummary = nil
            selectedDetail = cached
            detailLoadState = .loaded
            detailRevision &+= 1
            trace.finishRequest(outcome: "cache-hit")
            await completeFavoriteDetail(cached)
            return
        }
        if forceRefresh { detailResponseCache.remove(key) }
        let sessionID = detailLoadSessionID
        detailRequestKey = key
        activeDetailPerformanceTrace = trace
        if !retainingDetail { selectedDetail = nil }
        pendingDetailSummary = retainingDetail ? nil : summary
        isRefreshingDetail = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDetailRequest(summary, provider: provider, key: key,
                                           sessionID: sessionID, performanceTrace: trace)
        }
        detailRequestTask = task
        let timeout = UInt64(detailRequestTimeout * 1_000_000_000)
        detailTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.detailLoadSessionID == sessionID,
                  self.detailLoadState == .loading else { return }
            self.cancelDetailRequest()
            self.pendingDetailSummary = nil
            let message = L10n.string("detail.request-timeout", fallback: "This provider is taking too long. Your page is preserved; you can retry.")
            self.detailLoadState = .failed(message)
        }
        await task.value
        if detailLoadSessionID == sessionID {
            detailTimeoutTask?.cancel()
            detailTimeoutTask = nil
            detailRequestTask = nil
            detailRequestKey = nil
            isRefreshingDetail = false
        }
    }

    func refreshDetail() async {
        guard isDetailPagePresented, let summary = detailRequestSummary else { return }
        await loadDetail(summary, forceRefresh: true)
    }

    func continueDetailSearch() {
        guard let query = detailSuggestedSearch else { return }
        dismissDetail(restoringSearch: false)
        presentHomeSearch()
        search(query, context: .discoveryFallback)
    }

    private func cancelDetailRequest() {
        detailTimeoutTask?.cancel()
        detailTimeoutTask = nil
        detailRequestTask?.cancel()
        detailRequestTask = nil
        detailRequestKey = nil
        detailLoadSessionID = UUID()
        activeDetailPerformanceTrace?.finishRequest(outcome: "cancelled")
        activeDetailPerformanceTrace = nil
        isRefreshingDetail = false
    }

    /// Provider replacement covers configuration revisions and account edits.
    /// Authorization entry points also invalidate snapshots before retrying.
    private func invalidateDetailContext(preservingRoute: Bool = false) {
        catPawSearchMemory.invalidate(clearPerformance: true)
        let retainedSummary = preservingRoute && isDetailPagePresented
            ? (detailRouteSummary ?? detailRequestSummary) : nil
        detailFavoriteSource = nil
        detailFavoriteExpectation = nil
        detailResponseCache.invalidate()
        cancelDetailRequest()
        detailRequestSummary = nil
        pendingDetailSummary = nil
        detailRouteSummary = nil
        selectedDetail = nil
        if let retainedSummary {
            detailRequestSummary = retainedSummary
            detailRouteSummary = retainedSummary
            detailSuggestedSearch = nil
            detailLoadState = .failed(L10n.string("detail.source-updated", fallback: "This source's configuration changed. Retry to load the updated details."))
        }
    }

    /// Unknown Profile fields may contain credentials as well as share caches.
    /// Invalidate reusable data conservatively, but let the current page-owned
    /// request finish. A later catalogue change is handled separately.
    func nodeProfileStorageDidChange() {
        detailResponseCache.invalidate()
        catPawSearchMemory.invalidate()
    }

    private func performDetailRequest(
        _ summary: VideoSummary, provider: SiteProvider,
        key: DetailResponseCache.Key, sessionID: UUID,
        performanceTrace: DetailPerformanceTrace
    ) async {
        // The route survives failure and authorization. Only this request may
        // publish into it; explicit navigation closes the route.
        do {
            performanceTrace.markProviderStart(searchActive: isSearching)
            if provider is NodeHTTPSpiderSiteProvider, let environment {
                let runtimeStatus = await environment.nodeBundleRuntime
                    .currentStatus()
                if case .running = runtimeStatus {
                    performanceTrace.recordRuntimeWasAlreadyReady(true)
                } else {
                    performanceTrace.recordRuntimeWasAlreadyReady(false)
                }
            }
            let selection = try await DetailPerformanceContext.$current
                .withValue(performanceTrace) {
                    try await HTTPTaskTimingContext.$observer.withValue({ timing in
                        performanceTrace.recordHTTPMetrics(timing)
                    }) {
                        try await provider.select(summary: summary)
                    }
                }
            guard detailLoadSessionID == sessionID, !Task.isCancelled else { return }
            pendingDetailSummary = nil
            switch selection {
            case .detail(let detail):
                guard acceptsFavoriteDetail(detail) else { return }
                activeDetailPerformanceTrace = performanceTrace
                performanceTrace.markSelectedDetail(searchActive: isSearching)
                detailRouteSummary = summary
                selectedDetail = detail
                detailLoadState = .loaded
                detailRevision &+= 1
                detailResponseCache.insert(detail, for: key)
                performanceTrace.finishRequest(outcome: "success")
                await completeFavoriteDetail(detail)
            case .search(let query):
                performanceTrace.finishRequest(outcome: "discovery")
                detailRouteSummary = summary
                detailSuggestedSearch = query
                detailLoadState = .failed(L10n.string("detail.search-returned", fallback: "This provider returned a search suggestion instead of details. Retry or continue searching."))
            case .action(let result):
                performanceTrace.finishRequest(outcome: "action")
                if provider.capability == .javaDexSpider {
                    detailRouteSummary = nil
                    selectedDetail = nil
                    detailRequestSummary = nil
                    let generation = beginSiteActionStatusSession()
                    publishSiteActionStatus(Self.siteActionMessage(result)
                        ?? L10n.string("configuration.action.finished", fallback: "Operation finished"),
                        title: summary.title, generation: generation)
                    detailLoadState = .loaded
                    if selectedSection == .home, selectedSiteKey == summary.siteKey {
                        await loadSelectedSiteHome(refreshConfigurationIfNeeded: false,
                            forceCategoryRefresh: true, forceHomeRefresh: true)
                    }
                } else {
                    detailLoadState = .failed(Self.siteActionMessage(result)
                        ?? L10n.string("configuration.action.mismatched", fallback: "The provider returned a configuration action unrelated to the current request. Go back and try again."))
                }
            }
        } catch let authorization as NodeWebAuthorizationRequired {
            performanceTrace.finishRequest(outcome: "authorization")
            guard detailLoadSessionID == sessionID, !Task.isCancelled else { return }
            pendingDetailSummary = nil
            detailLoadState = .needsAuthorization
            guard let identity = activeSourceIdentity(
                for: summary.siteKey
            ) else {
                detailLoadState = .failed(L10n.string("detail.configuration-changed", fallback: "The configuration associated with these details has changed"))
                return
            }
            presentNodeConfiguration(
                authorization,
                pending: .detail(
                    identity: identity,
                    summary: summary
                )
            )
        } catch let authorization as AndroidBridgeUIRequired {
            performanceTrace.finishRequest(outcome: "authorization")
            guard detailLoadSessionID == sessionID, !Task.isCancelled else { return }
            pendingDetailSummary = nil
            detailLoadState = .needsAuthorization
            await presentCloudAuthorization(
                authorization.state,
                interaction: authorization.interaction,
                handle: authorization.handle,
                operation: .detail(summary),
                siteKey: summary.siteKey
            )
        } catch is CancellationError {
            performanceTrace.finishRequest(outcome: "cancelled")
            guard detailLoadSessionID == sessionID, !Task.isCancelled else { return }
            pendingDetailSummary = nil
            detailLoadState = .failed(L10n.string("detail.request-cancelled", fallback: "Detail loading was interrupted. You can retry here."))
        } catch {
            performanceTrace.finishRequest(outcome: Task.isCancelled ? "cancelled" : "failure")
            guard detailLoadSessionID == sessionID, !Task.isCancelled else { return }
            pendingDetailSummary = nil
            let failure = userFacingError(for: error,
                title: L10n.string("detail.load.failed", fallback: "Details Failed to Load"))
            if provider.capability == .javaDexSpider, detailRouteSummary == nil {
                presentedError = failure
            }
            detailLoadState = .failed(failure.message)
        }
    }

    func openHomeItem(_ summary: VideoSummary) async {
        let site = supportedSites.first { $0.key == summary.siteKey }
        switch HomeItemRoutePolicy.route(summary: summary, site: site) {
        case .action:
            await performHomeAction(SiteActionItem(summary: summary))
        case .folder:
            openSearchFolder(
                summary,
                replacingPath: true,
                origin: .home
            )
        case .search:
            launchDiscoveryCardSearch(
                summary,
                preservingFolderReturn: false
            )
        case .detail:
            await loadDetail(summary)
        }
    }

    func isTVBoxConfigurationActionPending(_ item: SiteActionItem) -> Bool {
        pendingTVBoxConfigurationAction.map {
            $0.siteKey == item.siteKey && $0.route == item.resolvedRoute
        } ?? false
    }

    /// The task exists before runtime startup or a native dialog. Cancellation
    /// therefore works throughout preparation, not only after UI appears.
    private func runTVBoxConfigurationAction(
        siteKey: String, route: HomeFunctionRoute, title: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        guard let identity = activeSourceIdentity(for: siteKey) else {
            presentedError = UserFacingError(title: title,
                message: L10n.string("configuration.action.configuration-changed", fallback: "The configuration associated with this action has changed"))
            return
        }
        if let pending = pendingTVBoxConfigurationAction {
            guard pending.siteKey != siteKey || pending.route != route else { return }
            cancelPendingTVBoxConfigurationAction(pending.id)
        }
        let pending = PendingTVBoxConfigurationAction(id: UUID(), siteKey: siteKey,
            route: route, title: title,
            refreshTarget: TVBoxConfigurationRefreshTarget(sourceIdentity: identity,
                categoryID: selectedCategoryID, filters: selectedCategoryFilters,
                categoryPresentationID: configurationCategoryPresentation?.id))
        pendingTVBoxConfigurationAction = pending
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.pendingTVBoxConfigurationAction?.id == pending.id else { return }
            await operation()
        }
        tvboxConfigurationActionTask = task
        let timeout = UInt64(configurationActionTimeout * 1_000_000_000)
        tvboxConfigurationActionTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.pendingTVBoxConfigurationAction?.id == pending.id else { return }
            self.cancelPendingTVBoxConfigurationAction(pending.id)
            self.presentedError = UserFacingError(title: title,
                message: L10n.string("configuration.action.timeout", fallback: "The operation timed out. Refresh the configuration to check its current state before retrying."))
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                self?.cancelPendingTVBoxConfigurationAction(pending.id)
            }
        }
        guard pendingTVBoxConfigurationAction?.id == pending.id else { return }
        if Task.isCancelled {
            cancelPendingTVBoxConfigurationAction(pending.id)
        } else {
            tvboxConfigurationActionTimeoutTask?.cancel()
            tvboxConfigurationActionTimeoutTask = nil
            tvboxConfigurationActionTask = nil
            pendingTVBoxConfigurationAction = nil
        }
    }

    func cancelPendingTVBoxConfigurationAction(_ id: UUID) {
        guard pendingTVBoxConfigurationAction?.id == id else { return }
        tvboxConfigurationActionTask?.cancel()
        tvboxConfigurationActionTask = nil
        tvboxConfigurationActionTimeoutTask?.cancel()
        tvboxConfigurationActionTimeoutTask = nil
        pendingTVBoxConfigurationAction = nil
        _ = beginSiteActionStatusSession()
        if cloudAuthorizationContext?.operationID == id {
            clearCloudAuthorization(resetBridgeUI: true, markPendingPlaybackCancelled: false,
                cancellationReason: .user)
        }
    }

    private func refreshTVBoxConfigurationAfterAction(_ target: TVBoxConfigurationRefreshTarget) async {
        guard !Task.isCancelled,
              activeSourceIdentity(for: target.sourceIdentity.siteKey) == target.sourceIdentity,
              selectedSection == .home, selectedSiteKey == target.sourceIdentity.siteKey else { return }
        // Read back exactly the original visible category. Never invoke the
        // action a second time, or navigate back over a newer user selection.
        if let presentationID = target.categoryPresentationID {
            guard configurationCategoryPresentation?.id == presentationID else { return }
            await refreshConfigurationCategory()
        } else if let categoryID = target.categoryID {
            guard selectedCategoryID == categoryID, selectedCategoryFilters == target.filters else { return }
            await loadCategory(id: categoryID, page: 1, filters: target.filters, forceRefresh: true)
        } else if selectedCategoryID == nil {
            await loadSelectedSiteHome(refreshConfigurationIfNeeded: false,
                forceCategoryRefresh: true, forceHomeRefresh: true)
        }
    }

    func performHomeAction(_ item: SiteActionItem) async {
        guard let provider = providers[item.siteKey], provider.capability == .javaDexSpider,
              case .providerSelection = item.resolvedRoute else {
            await performHomeActionRequest(item)
            return
        }
        await runTVBoxConfigurationAction(siteKey: item.siteKey, route: item.resolvedRoute, title: item.title) {
            await self.performHomeActionRequest(item)
        }
    }

    private func performHomeActionRequest(_ item: SiteActionItem) async {
        detailResponseCache.invalidate()
        guard let provider = providers[item.siteKey] else {
            show(
                AppError.site(L10n.string("configuration.action.provider-unavailable", fallback: "The provider for this action is currently unavailable")),
                title: item.title
            )
            return
        }
        switch item.resolvedRoute {
        case .actionCategory:
            await openConfigurationCategory(item)
            return
        case .command(let action):
            await performSiteAction(
                action,
                title: item.title,
                provider: provider,
                tag: item.tag,
                configurationSelectionText: item.remarks ?? ""
            )
            return
        case .providerSelection:
            break
        }
        let actionStatusGeneration = beginSiteActionStatusSession()
        let refreshTarget = provider.capability == .javaDexSpider
            ? pendingTVBoxConfigurationAction?.refreshTarget : nil
        let operation = PendingCloudOperation.homeAction(item)
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
            guard !Task.isCancelled, siteActionStatusGeneration == actionStatusGeneration else {
                return
            }
        }
        let interactionID: UUID?
        if provider.capability == .javaDexSpider {
            guard let begunInteractionID = beginConfigurationInteraction(
                title: item.title,
                siteKey: item.siteKey,
                operation: operation,
                semantic: operation.initialSemantic,
                interactionID: pendingTVBoxConfigurationAction?.id ?? UUID(),
                actionStatusGeneration: actionStatusGeneration,
                presentsPlaceholder: false
            ) else {
                // A Java/Dex action must never fall through to the legacy
                // unscoped invocation path. The active configuration may have
                // changed while the old action card was still visible.
                return
            }
            interactionID = begunInteractionID
        } else {
            interactionID = nil
        }
        let usesGlobalLoadingIndicator = interactionID == nil
        if usesGlobalLoadingIndicator { isLoading = true }
        defer {
            if usesGlobalLoadingIndicator { isLoading = false }
        }
        do {
            let selection: SiteSelectionResult
            if let interactionID,
               let provider = provider as? AndroidDexSpiderSiteProvider {
                selection = try await provider.select(
                    action: item,
                    interactionID: interactionID
                )
            } else {
                selection = try await provider.select(action: item)
            }
            try Task.checkCancellation()
            if let interactionID {
                guard configurationInteractionCoordinator.owns(interactionID),
                      cloudAuthorizationContext?.actionStatusGeneration == actionStatusGeneration,
                      cloudAuthorizationContext.map(isCurrentCloudAuthorizationContext) == true else { return }
            }
            switch selection {
            case .detail:
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    failConfigurationInteraction(
                        interactionID,
                        message: L10n.string("configuration.action.returned-detail", fallback: "The provider returned media details instead of a configuration screen. The action was not performed.")
                    )
                } else {
                    presentedError = UserFacingError(
                        title: item.title,
                        message: L10n.string("configuration.action.not-detail", fallback: "This entry is a configuration action and was not opened as media details.")
                    )
                }
            case .action(let result):
                if let command = item.action {
                    await invalidatePersistedCloudAccountStatus(
                        provider: provider,
                        command: command
                    )
                }
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    publishSiteActionStatus(
                        Self.siteActionMessage(result) ?? L10n.string("configuration.action.finished", fallback: "Operation finished"),
                        title: item.title,
                        generation: actionStatusGeneration
                    )
                    completeConfigurationInteraction(
                        interactionID,
                        status: L10n.string("configuration.action.completed", fallback: "Configuration Action Complete")
                    )
                    if cloudAuthorizationPrompt?.interactionID
                        == interactionID {
                        retireCompletedConfigurationInteraction(
                            interactionID,
                            preservingPrompt: true
                        )
                    } else {
                        retireCompletedConfigurationInteraction(interactionID)
                    }
                } else {
                    publishSiteActionStatus(
                        Self.siteActionMessage(result),
                        title: item.title,
                        generation: actionStatusGeneration
                    )
                }
                if let refreshTarget, siteActionStatusGeneration == actionStatusGeneration {
                    await refreshTVBoxConfigurationAfterAction(refreshTarget)
                }
            case .search(let query):
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    completeConfigurationInteraction(interactionID)
                    retireCompletedConfigurationInteraction(
                        interactionID,
                        preservingPrompt:
                            cloudAuthorizationPrompt?.interactionID
                                == interactionID
                    )
                }
                presentHomeSearch()
                search(query, context: .discoveryFallback)
            }
        } catch let authorization as NodeWebAuthorizationRequired {
            guard let identity = activeSourceIdentity(for: item.siteKey) else {
                show(
                    AppError.site(L10n.string("configuration.action.configuration-changed", fallback: "The configuration associated with this action has changed")),
                    title: item.title
                )
                return
            }
            presentNodeConfiguration(
                authorization,
                pending: .homeAction(identity: identity, item: item)
            )
        } catch let authorization as AndroidBridgeUIRequired {
            guard !Task.isCancelled, siteActionStatusGeneration == actionStatusGeneration else {
                scheduleConfigurationInteractionCleanup(
                    authorization.handle,
                    reason: ConfigurationInteractionCancellationReason
                        .superseded.rawValue
                )
                return
            }
            if let interactionID,
               !configurationInteractionCoordinator.owns(interactionID) {
                scheduleConfigurationInteractionCleanup(
                    authorization.handle,
                    reason: ConfigurationInteractionCancellationReason
                        .superseded.rawValue
                )
                return
            }
            await presentCloudAuthorization(
                authorization.state,
                interaction: authorization.interaction,
                handle: authorization.handle,
                operation: operation,
                siteKey: item.siteKey
            )
        } catch is CancellationError {
            if let interactionID,
               configurationInteractionCoordinator.owns(interactionID) {
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
            }
        } catch {
            guard !Task.isCancelled, interactionID.map { configurationInteractionCoordinator.owns($0) } ?? true else { return }
            if AsyncCancellationPolicy.isCancellation(error) {
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    clearCloudAuthorization(
                        resetBridgeUI: false,
                        markPendingPlaybackCancelled: false,
                        cancellationReason: .providerCancelled
                    )
                }
                return
            }
            if let interactionID,
               configurationInteractionCoordinator.owns(interactionID) {
                failConfigurationInteraction(
                    interactionID,
                    message: localizedRuntimeErrorMessage(error)
                )
            } else {
                show(error, title: L10n.string("common.action.failed", fallback: "%@ Failed", item.title))
            }
        }
    }

    func openSearchResult(_ summary: VideoSummary) {
        if summary.isFolder {
            openSearchFolder(
                summary,
                replacingPath: true,
                origin: .searchResults
            )
        } else {
            Task { await loadDetail(summary) }
        }
    }

    func openSearchFolderItem(_ summary: VideoSummary) {
        let currentFolder = searchFolderPath.last
        let site = supportedSites.first { $0.key == summary.siteKey }
        switch HomeItemRoutePolicy.route(
            summary: summary,
            site: site,
            inheritedNavigationMode:
                currentFolder?.navigationContext.navigationMode
        ) {
        case .action:
            Task {
                await performHomeAction(SiteActionItem(summary: summary))
            }
        case .folder:
            openSearchFolder(
                summary,
                replacingPath: false,
                origin: nil
            )
        case .search:
            launchDiscoveryCardSearch(
                summary,
                preservingFolderReturn: true
            )
        case .detail:
            Task { await loadDetail(summary) }
        }
    }

    private func launchDiscoveryCardSearch(
        _ summary: VideoSummary,
        preservingFolderReturn: Bool
    ) {
        cancelDetailRequest()
        detailRouteSummary = nil
        selectedDetail = nil
        pendingDetailSummary = nil
        if preservingFolderReturn {
            discoverySearchReturnSnapshot =
                DetailHomeSearchReturnPolicy.capture(
                    isHomeSearchPresented: isHomeSearchPresented,
                    selectedSiteKey: selectedSearchSiteKey,
                    folderPath: searchFolderPath,
                    folderOrigin: searchFolderOrigin
                )
        } else {
            discoverySearchReturnSnapshot = nil
        }
        presentHomeSearch()
        // Discovery cards are explicit user navigation and therefore use the
        // configured aggregate-search scope. They are not failed detail
        // requests and must never mount DetailLoadingView first.
        search(summary.title, context: .discoveryCard)
    }

    func closeSearchFolder() {
        searchFolderPath = []
        searchFolderOrigin = nil
    }

    func navigateBackSearchFolder() {
        switch SearchFolderNavigationPolicy.backDestination(
            pathCount: searchFolderPath.count,
            origin: searchFolderOrigin
        ) {
        case .parentFolder:
            searchFolderPath.removeLast()
        case .home:
            returnFromSearchToHome()
        case .searchResults:
            closeSearchFolder()
        case .none:
            break
        }
    }

    func navigateBackHomeSearch() {
        if searchFolderPath.isEmpty {
            if !restoreDiscoverySearchReturnSnapshot() {
                returnFromSearchToOrigin()
            }
        } else {
            navigateBackSearchFolder()
        }
    }

    @discardableResult
    private func restoreDiscoverySearchReturnSnapshot() -> Bool {
        guard let snapshot = discoverySearchReturnSnapshot,
              let page = snapshot.folderPath.last else {
            return false
        }
        let site = supportedSites.first {
            $0.key == page.navigationContext.sourceSiteKey
        }
        let currentRevision = activeConfigurationRecord.map {
            CategoryConfigurationRevision.make(record: $0)
        }
        guard page.navigationContext.isCurrent(
            configurationID: activeConfigurationRecord?.id,
            configurationRevision: currentRevision,
            nodeSiteIdentity: site?.extra[
                "okNodeSiteIdentity"
            ]?.stringValue
        ) else {
            discoverySearchReturnSnapshot = nil
            return false
        }
        discoverySearchReturnSnapshot = nil
        cancelSearch()
        selectedSection = .home
        selectedSearchSiteKey = snapshot.selectedSiteKey
        searchFolderPath = snapshot.folderPath
        searchFolderOrigin = snapshot.folderOrigin
        isHomeSearchPresented = true
        return true
    }

    var homeSearchBackTitle: String {
        if searchFolderPath.isEmpty {
            if discoverySearchReturnSnapshot?.folderPath.isEmpty == false {
                return L10n.string("navigation.back-list", fallback: "Back to List")
            }
            return L10n.string(
                "search.return-section",
                fallback: "Return to %@",
                (homeSearchReturnSection ?? .home).title
            )
        }
        return SearchFolderNavigationPolicy.backTitle(
            pathCount: searchFolderPath.count,
            origin: searchFolderOrigin
        )
    }

    var homeSearchBackHelp: String {
        if searchFolderPath.isEmpty {
            if isSearching || searchPaging.loading {
                return L10n.string("navigation.stop-search-preserve", fallback: "Stop Search and Keep Current Results")
            }
            if discoverySearchReturnSnapshot?.folderPath.isEmpty == false {
                return L10n.string("navigation.back-pre-search-list", fallback: "Return to the list open before search")
            }
            return L10n.string(
                "search.close-and-return-section",
                fallback: "Close Search and Return to %@",
                (homeSearchReturnSection ?? .home).title
            )
        }
        return SearchFolderNavigationPolicy.backHelp(
            pathCount: searchFolderPath.count,
            origin: searchFolderOrigin
        )
    }

    func retryCurrentSearchFolder() {
        guard let current = searchFolderPath.last, !current.isLoading else { return }
        updateSearchFolder(id: current.id) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        Task {
            await loadSearchFolder(
                id: current.id,
                summary: current.folder,
                page: 1
            )
        }
    }

    func loadNextSearchFolderPage() {
        Task { await loadNextSearchFolderPageAndWait() }
    }

    func loadNextSearchFolderPageAndWait() async -> Bool {
        guard let current = searchFolderPath.last, !current.isLoading,
              let pagination = current.pagination, pagination.hasMore else { return false }
        updateSearchFolder(id: current.id) { page in
            page.isLoading = true
            page.errorMessage = nil
            page.paginationIssueKind = .failed
        }
        await loadSearchFolder(id: current.id, summary: current.folder, page: pagination.page + 1)
        return searchFolderPath.last.map { $0.id == current.id && $0.errorMessage == nil } ?? false
    }

    @discardableResult
    private func beginSiteActionStatusSession() -> UInt64 {
        siteActionStatusGeneration &+= 1
        siteActionStatusDismissTask?.cancel()
        siteActionStatusDismissTask = nil
        siteActionStatus = nil
        return siteActionStatusGeneration
    }

    private func publishSiteActionStatus(
        _ message: String?,
        title: String,
        generation: UInt64
    ) {
        guard generation == siteActionStatusGeneration,
              let message = message?.nonEmpty else {
            return
        }
        let status = TransientSiteActionStatus(
            id: UUID(),
            requestGeneration: generation,
            title: title,
            message: message
        )
        siteActionStatusDismissTask?.cancel()
        siteActionStatus = status
        siteActionStatusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled,
                  self?.siteActionStatus?.id == status.id,
                  self?.siteActionStatusGeneration == generation else {
                return
            }
            self?.siteActionStatus = nil
            self?.siteActionStatusDismissTask = nil
        }
    }

    /// Removes only presentation state owned by a provider request that has
    /// already completed. This is intentionally different from cancellation:
    /// an empty FongMi action result is a valid silent completion and must not
    /// send a late cancel that can race the next request.
    private func retireCompletedConfigurationInteraction(
        _ interactionID: UUID,
        preservingPrompt: Bool = false
    ) {
        guard configurationInteractionCoordinator.owns(interactionID),
              cloudAuthorizationContext?.operationID == interactionID else {
            return
        }
        let retainedPrompt = preservingPrompt
            ? cloudAuthorizationPrompt
            : nil
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        cloudAuthorizationPrompt = retainedPrompt
        cloudAuthorizationInput = ""
        cloudAuthorizationSurfaceFrame = nil
        lastCloudAuthorizationSurfaceCaptureAt = nil
        cloudAuthorizationContext = nil
        configurationInteractionCoordinator.clear(interactionID)
    }

    private func performSiteAction(
        _ action: String, title: String, provider: SiteProvider, tag: String? = nil,
        configurationSelectionText: String? = nil
    ) async {
        guard provider.capability == .javaDexSpider else {
            await performSiteActionRequest(action, title: title, provider: provider, tag: tag,
                configurationSelectionText: configurationSelectionText)
            return
        }
        await runTVBoxConfigurationAction(siteKey: provider.site.key,
            route: .command(action: action), title: title) {
            await self.performSiteActionRequest(action, title: title, provider: provider, tag: tag,
                configurationSelectionText: configurationSelectionText)
        }
    }

    private func performSiteActionRequest(
        _ action: String,
        title: String,
        provider: SiteProvider,
        tag: String? = nil,
        configurationSelectionText: String? = nil
    ) async {
        detailResponseCache.invalidate()
        let actionStatusGeneration = beginSiteActionStatusSession()
        let refreshTarget = provider.capability == .javaDexSpider
            ? pendingTVBoxConfigurationAction?.refreshTarget : nil
        let effectiveTag: String? = tag?.nonEmpty ?? {
            guard MyDriveGuardActionContract.supportsAccountAuthorization(
                api: provider.site.api
            ) else { return nil }
            return MyDriveGuardActionContract.tag(for: action)
        }()
        let interactionKind = AndroidDexSpiderSiteProvider
            .interactionActionKind(tag: effectiveTag)
        let operation = PendingCloudOperation.siteAction(
            action: action,
            title: title,
            tag: effectiveTag
        )
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
            guard !Task.isCancelled, siteActionStatusGeneration == actionStatusGeneration else {
                return
            }
        }
        let interactionID: UUID?
        if provider.capability == .javaDexSpider {
            guard let begunInteractionID = beginConfigurationInteraction(
                title: title,
                siteKey: provider.site.key,
                operation: operation,
                semantic: operation.initialSemantic,
                interactionID: pendingTVBoxConfigurationAction?.id ?? UUID(),
                actionStatusGeneration: actionStatusGeneration,
                // FongMi does not manufacture a host dialog while action()
                // runs. Present only if Android actually publishes a surface.
                presentsPlaceholder: false
            ) else {
                // Do not send a stale Java/Dex command without the host-owned
                // interaction/session identity.
                return
            }
            interactionID = begunInteractionID
        } else {
            interactionID = nil
        }
        let usesGlobalLoadingIndicator = interactionID == nil
        if usesGlobalLoadingIndicator { isLoading = true }
        defer {
            if usesGlobalLoadingIndicator { isLoading = false }
        }
        do {
            let result: JSONValue
            if let interactionID,
               let provider = provider as? AndroidDexSpiderSiteProvider {
                result = try await provider.action(
                    action,
                    interactionID: interactionID,
                    interactionKind: interactionKind,
                    configurationSelectionText: configurationSelectionText
                )
            } else {
                result = try await provider.action(action)
            }
            try Task.checkCancellation()
            if let interactionID {
                guard configurationInteractionCoordinator.owns(interactionID),
                      cloudAuthorizationContext.map(isCurrentCloudAuthorizationContext) == true else { return }
            }
            await invalidatePersistedCloudAccountStatus(
                provider: provider,
                command: action
            )
            if let interactionID {
                guard configurationInteractionCoordinator.owns(interactionID),
                      cloudAuthorizationContext?.actionStatusGeneration
                        == actionStatusGeneration else {
                    return
                }
                publishSiteActionStatus(
                    Self.siteActionMessage(result) ?? L10n.string("configuration.action.finished", fallback: "Operation finished"),
                    title: title,
                    generation: actionStatusGeneration
                )
                completeConfigurationInteraction(
                    interactionID,
                    status: L10n.string("configuration.action.completed", fallback: "Configuration Action Complete")
                )
                if cloudAuthorizationPrompt?.interactionID == interactionID {
                    retireCompletedConfigurationInteraction(
                        interactionID,
                        preservingPrompt: true
                    )
                } else {
                    retireCompletedConfigurationInteraction(interactionID)
                }
            } else {
                publishSiteActionStatus(
                    Self.siteActionMessage(result),
                    title: title,
                    generation: actionStatusGeneration
                )
            }
            if let refreshTarget, siteActionStatusGeneration == actionStatusGeneration {
                await refreshTVBoxConfigurationAfterAction(refreshTarget)
            }
        } catch let authorization as NodeWebAuthorizationRequired {
            guard let identity = activeSourceIdentity(
                for: provider.site.key
            ) else {
                show(
                    AppError.site(L10n.string("configuration.action.configuration-changed", fallback: "The configuration associated with this action has changed")),
                    title: title
                )
                return
            }
            presentNodeConfiguration(
                authorization,
                pending: .siteAction(
                    identity: identity,
                    action: action,
                    title: title
                )
            )
        } catch let authorization as AndroidBridgeUIRequired {
            guard !Task.isCancelled, siteActionStatusGeneration == actionStatusGeneration else {
                scheduleConfigurationInteractionCleanup(
                    authorization.handle,
                    reason: ConfigurationInteractionCancellationReason
                        .superseded.rawValue
                )
                return
            }
            if let interactionID,
               !configurationInteractionCoordinator.owns(interactionID) {
                scheduleConfigurationInteractionCleanup(
                    authorization.handle,
                    reason: ConfigurationInteractionCancellationReason
                        .superseded.rawValue
                )
                return
            }
            await presentCloudAuthorization(
                authorization.state,
                interaction: authorization.interaction,
                handle: authorization.handle,
                operation: operation,
                siteKey: provider.site.key
            )
        } catch is CancellationError {
            if let interactionID,
               configurationInteractionCoordinator.owns(interactionID) {
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
            }
        } catch {
            guard !Task.isCancelled, interactionID.map { configurationInteractionCoordinator.owns($0) } ?? true else { return }
            if AsyncCancellationPolicy.isCancellation(error) {
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    clearCloudAuthorization(
                        resetBridgeUI: false,
                        markPendingPlaybackCancelled: false,
                        cancellationReason: .providerCancelled
                    )
                }
                return
            }
            if let interactionID,
               configurationInteractionCoordinator.owns(interactionID) {
                failConfigurationInteraction(
                    interactionID,
                    message: localizedRuntimeErrorMessage(error)
                )
            } else {
                show(error, title: L10n.string("common.action.failed", fallback: "%@ Failed", title))
            }
        }
    }

    private func cloudAuthorizationPresentationTarget(
        for operation: PendingCloudOperation
    ) -> CloudAuthorizationPresentationTarget {
        switch operation {
        case .playback(let pending):
            return .player(requestID: pending.requestID)
        case .detail:
            return isDetailPagePresented
                ? .detail
                : .mainWindow
        case .homeAction, .siteAction:
            return .mainWindow
        }
    }

    @discardableResult
    private func beginConfigurationInteraction(
        title: String,
        siteKey: String,
        operation: PendingCloudOperation,
        semantic: ConfigurationInteractionSemantic? = nil,
        interactionID: UUID = UUID(),
        providerHandle: InteractionHandle? = nil,
        providerInteraction: ConfigurationInteraction? = nil,
        phase: ConfigurationInteractionPhase = .invoking,
        actionStatusGeneration: UInt64? = nil,
        presentsPlaceholder: Bool = true
    ) -> UUID? {
        guard let identity = activeSourceIdentity(for: siteKey) else {
            show(
                AppError.site(L10n.string("configuration.action.configuration-changed", fallback: "The configuration associated with this action has changed")),
                title: title
            )
            return nil
        }
        if cloudAuthorizationContext != nil || cloudAuthorizationPrompt != nil {
            clearCloudAuthorization(
                resetBridgeUI: true,
                markPendingPlaybackCancelled: false,
                cancellationReason: .superseded
            )
        }
        let resolvedSemantic = semantic ?? operation.initialSemantic
        let request = configurationInteractionCoordinator.begin(
            sourceIdentity: identity,
            semantic: resolvedSemantic,
            transport: .native,
            title: title,
            interactionID: interactionID
        )
        if phase != .invoking {
            _ = configurationInteractionCoordinator.transition(
                request.interactionID,
                to: phase
            )
        }
        // The complete Android frame is leased to one host generation. Never
        // carry an old dialog/QR image into a newly begun request, even when
        // the first capture of the replacement is delayed or blocked.
        cloudAuthorizationSurfaceFrame = nil
        lastCloudAuthorizationSurfaceCaptureAt = nil
        cloudAuthorizationContext = CloudAuthorizationContext(
            sourceIdentity: identity,
            operationID: request.interactionID,
            requestGeneration: request.generation,
            actionStatusGeneration: actionStatusGeneration,
            providerOwnerID: nil,
            providerHandle: providerHandle,
            providerInteraction: providerInteraction,
            operation: operation,
            hasObservedPrompt: false,
            lastObservedRevision: nil,
            configurationRefreshTarget: pendingTVBoxConfigurationAction?.id == interactionID
                ? pendingTVBoxConfigurationAction?.refreshTarget : nil
        )
        cloudAuthorizationPrompt = presentsPlaceholder
            ? CloudAuthorizationPrompt(
            id: UUID(),
            interactionID: request.interactionID,
            requestGeneration: request.generation,
            title: title,
            interactionKind: ConfigurationInteractionClassificationPolicy
                .interactionKind(for: resolvedSemantic),
            semantic: resolvedSemantic,
            transport: .native,
            lifecyclePhase: phase,
            presentationTarget: cloudAuthorizationPresentationTarget(
                for: operation
            ),
            status: phase == .invoking
                ? L10n.string("configuration.action.executing", fallback: "Performing configuration action…")
                : L10n.string("configuration.action.waiting-interface", fallback: "Waiting for the provider to open the next action screen…"),
            allowsRetry: false,
            allowsCompletionConfirmation: false
        )
            : nil
        return request.interactionID
    }

    /// Retires the previous request before reserving a new native interaction.
    /// Cleanup may restart only the Android Bridge process when third-party
    /// DEX code ignores interruption. Await it before a replacement request so
    /// old callbacks can never attach themselves to the new Activity.
    private func supersedeConfigurationInteractionIfNeeded() async {
        await configurationInteractionCleanupTask?.value
        guard cloudAuthorizationContext != nil
                || cloudAuthorizationPrompt != nil else { return }
        let bridge = environment?.androidDexBridge
        let providerHandle = cloudAuthorizationContext?.providerHandle
        let interactionID = cloudAuthorizationContext?.operationID
        let usesLegacyBridge = providerHandle == nil
        clearCloudAuthorization(
            resetBridgeUI: false,
            markPendingPlaybackCancelled: false,
            cancellationReason: .superseded,
            cancelProviderHandle: false
        )
        if let providerHandle {
            await providerHandle.cancelAndWait(
                reason: ConfigurationInteractionCancellationReason
                    .superseded.rawValue
            )
        } else if usesLegacyBridge, let bridge {
            try? await bridge.resetAuthorizationUI(interactionID: interactionID)
        }
    }

    private func scheduleConfigurationInteractionCleanup(
        _ handle: InteractionHandle?,
        reason: String
    ) {
        guard let handle else { return }
        let previous = configurationInteractionCleanupTask
        configurationInteractionCleanupTask = Task {
            await previous?.value
            await handle.cancelAndWait(reason: reason)
        }
    }

    private func transitionConfigurationInteraction(
        _ interactionID: UUID,
        to phase: ConfigurationInteractionPhase,
        semantic: ConfigurationInteractionSemantic? = nil,
        status: String? = nil,
        allowsRetry: Bool? = nil
    ) {
        guard configurationInteractionCoordinator.transition(
            interactionID,
            to: phase,
            semantic: semantic,
            transport: .native,
            status: status
        ) else { return }
        if phase.isTerminal {
            cloudAuthorizationSurfaceFrame = nil
            lastCloudAuthorizationSurfaceCaptureAt = nil
        }
        guard var prompt = cloudAuthorizationPrompt,
              prompt.interactionID == interactionID,
              configurationInteractionCoordinator.owns(
                interactionID,
                generation: prompt.requestGeneration
              ) else {
            return
        }
        if let semantic {
            prompt.semantic = semantic
            prompt.interactionKind = ConfigurationInteractionClassificationPolicy
                .interactionKind(for: semantic)
        }
        prompt.lifecyclePhase = phase
        if let status { prompt.status = status }
        if let allowsRetry { prompt.allowsRetry = allowsRetry }
        cloudAuthorizationPrompt = prompt
    }

    private func completeConfigurationInteraction(
        _ interactionID: UUID,
        status: String = L10n.string("configuration.action.completed", fallback: "Configuration Action Complete")
    ) {
        transitionConfigurationInteraction(
            interactionID,
            to: .completed,
            status: status,
            allowsRetry: false
        )
    }

    private func failConfigurationInteraction(
        _ interactionID: UUID,
        message: String
    ) {
        guard configurationInteractionCoordinator.owns(interactionID) else { return }
        let title = configurationInteractionCoordinator.current?.request.title
            ?? L10n.string("cloud.configuration-action.title", fallback: "Configuration Action")
        let hasPrompt = cloudAuthorizationPrompt?.interactionID == interactionID
        transitionConfigurationInteraction(
            interactionID,
            to: .failed,
            status: message,
            allowsRetry: true
        )
        if !hasPrompt {
            presentedError = UserFacingError(title: title, message: message)
            // No sheet owns a retry here. Retire the failed request and its
            // provider lease now; the user can retry the original card.
            clearCloudAuthorization(resetBridgeUI: true, markPendingPlaybackCancelled: false,
                cancellationReason: .providerCancelled)
        }
    }

    private func observeConfigurationInteractionTerminal(
        _ handle: InteractionHandle
    ) {
        configurationInteractionTerminalTask?.cancel()
        configurationInteractionTerminalTask = Task { [weak self] in
            do {
                let terminal = try await handle.finalResponse()
                guard let self,
                      terminal.requestID == handle.id,
                      self.configurationInteractionCoordinator.owns(handle.id),
                      self.cloudAuthorizationContext?.operationID == handle.id else {
                    return
                }
                await self.processConfigurationInteractionTerminal(
                    terminal,
                    expectedInteractionID: handle.id
                )
            } catch is CancellationError {
                guard let self,
                      self.configurationInteractionCoordinator.owns(handle.id) else {
                    return
                }
                self.clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
            } catch {
                guard let self,
                      self.configurationInteractionCoordinator.owns(handle.id) else {
                    return
                }
                if AsyncCancellationPolicy.isCancellation(error) {
                    self.clearCloudAuthorization(
                        resetBridgeUI: false,
                        markPendingPlaybackCancelled: false,
                        cancellationReason: .providerCancelled
                    )
                    return
                }
                self.failConfigurationInteraction(
                    handle.id,
                    message: self.localizedRuntimeErrorMessage(error)
                )
            }
        }
    }

    private func processConfigurationInteractionTerminal(
        _ terminal: ConfigurationInteractionTerminalResponse,
        expectedInteractionID: UUID
    ) async {
        guard terminal.requestID == expectedInteractionID,
              configurationInteractionCoordinator.owns(expectedInteractionID),
              cloudAuthorizationContext?.operationID == expectedInteractionID else {
            return
        }
        switch terminal.outcome {
        case .succeeded:
            await finishCloudAuthorizationAndRetry(
                providerResult: terminal.providerResult,
                refreshPerformed: terminal.refreshPerformed
            )
        case .failed:
            failConfigurationInteraction(
                expectedInteractionID,
                message: terminal.error?.nonEmpty
                    ?? L10n.string("configuration.action.not-completed", fallback: "The provider did not complete this configuration action. Try again.")
            )
        case .cancelled:
            clearCloudAuthorization(
                resetBridgeUI: false,
                markPendingPlaybackCancelled: false,
                cancellationReason: .providerCancelled
            )
        case .pending:
            transitionConfigurationInteraction(
                expectedInteractionID,
                to: .processing,
                status: L10n.string("configuration.action.processing", fallback: "The provider is still processing this configuration action…")
            )
        }
    }

    private func configurationInteractionState(
        for context: CloudAuthorizationContext
    ) async throws -> AndroidBridgeUIState {
        if let handle = context.providerHandle {
            return try await handle.currentState()
        }
        guard let environment else { throw CancellationError() }
        return try await environment.androidDexBridge.uiState()
    }

    @discardableResult
    private func acceptConfigurationInteractionState(
        _ state: AndroidBridgeUIState,
        context: CloudAuthorizationContext
    ) -> Bool {
        guard configurationInteractionCoordinator.owns(context.operationID),
              configurationInteractionCoordinator.owns(
                context.operationID,
                generation: context.requestGeneration
              ),
              cloudAuthorizationContext?.operationID == context.operationID,
              ConfigurationInteractionStatePolicy.accepts(
                state,
                interactionID: context.operationID,
                requiresScopedIdentity: context.providerHandle != nil
              ) else {
            return false
        }
        if let returnedConfigurationID = state.configurationID?.nonEmpty,
           returnedConfigurationID.lowercased()
            != context.sourceIdentity.configurationID.uuidString.lowercased() {
            return false
        }
        if let returnedSiteKey = state.siteKey?.nonEmpty,
           returnedSiteKey != context.sourceIdentity.siteKey {
            return false
        }
        if let currentOwner = context.providerOwnerID?.nonEmpty,
           let returnedOwner = state.providerOwnerID?.nonEmpty,
           currentOwner != returnedOwner {
            return false
        }
        if let revision = state.revision,
           let previousRevision = cloudAuthorizationContext?.lastObservedRevision,
           revision < previousRevision {
            return false
        }
        if let revision = state.revision,
           var current = cloudAuthorizationContext,
           current.operationID == context.operationID {
            current.lastObservedRevision = max(
                current.lastObservedRevision ?? revision,
                revision
            )
            cloudAuthorizationContext = current
        }
        // Surface continuity is handled by updateCloudAuthorizationSurfaceFrame.
        // It deliberately keeps the last frame for a very short provider
        // transition, but never treats the Bridge placeholder as actionable UI.
        return true
    }

    /// Returns true when the state is terminal and therefore must not be
    /// interpreted as a missing or hidden window by the surface poller.
    private func consumeConfigurationTerminalState(
        _ state: AndroidBridgeUIState,
        context: CloudAuthorizationContext
    ) async -> Bool {
        let decision = ConfigurationInteractionStatePolicy.decision(for: state)
        switch decision {
        case .pending:
            return false
        case .terminalSucceeded, .terminalFailed, .terminalCancelled:
            if context.providerHandle != nil {
                // The scoped worker will publish the full provider terminal
                // response (including its result/error). Do not close from a
                // UI/status snapshot, even when that snapshot is terminal.
                transitionConfigurationInteraction(
                    context.operationID,
                    to: .processing,
                    status: L10n.string("configuration.action.finishing", fallback: "The provider returned a result. Finishing the current configuration action…")
                )
                return true
            }
            switch decision {
            case .terminalSucceeded:
                await finishCloudAuthorizationAndRetry()
            case .terminalFailed(let message):
                failConfigurationInteraction(
                    context.operationID,
                    message: message?.nonEmpty
                        ?? L10n.string("configuration.action.not-completed", fallback: "The provider did not complete this configuration action. Try again.")
                )
            case .terminalCancelled:
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
            default:
                break
            }
            return true
        }
    }

    private func presentNodeConfiguration(
        _ authorization: NodeWebAuthorizationRequired,
        pending suppliedPending: PendingNodeOperation
    ) {
        detailResponseCache.invalidate()
        var pending = suppliedPending
        if case .playback(let identity, var playback) = pending,
           playback.recoveryCheckpoint == nil,
           pendingPlayback?.requestID == playback.requestID {
            playback.recoveryCheckpoint = pendingPlayback?.recoveryCheckpoint
            pending = .playback(identity: identity, playback: playback)
        }
        if let challenge = authorization.challenge {
            guard pending.playbackRequestID == challenge.playbackRequestID,
                  activePlayerRequestID == challenge.playbackRequestID,
                  playbackSessionID == challenge.playbackRequestID,
                  transferGenerationsByRequestID[
                    challenge.playbackRequestID
                  ] == challenge.requestGeneration,
                  pending.sourceIdentity.configurationID
                    == activeConfigurationRecord?.id,
                  pending.sourceIdentity.siteKey
                    == providers[pending.sourceIdentity.siteKey]?.site.key else {
                return
            }
            if let configurationIdentity = challenge.configurationIdentity,
               activeConfigurationRecord?.id.uuidString
                .caseInsensitiveCompare(configurationIdentity) != .orderedSame {
                return
            }
            if let expectedRevision = activeConfigurationRecord.flatMap(
                NodeConfigurationSemanticRevision.make
            ), challenge.semanticRevision != expectedRevision {
                return
            }
            if let expectedSiteIdentity = providers[
                pending.sourceIdentity.siteKey
            ]?.site.extra["okNodeSiteIdentity"]?.stringValue,
               challenge.siteIdentity != expectedSiteIdentity {
                return
            }
        }
        if let current = nodeWebPresentation,
           pending.playbackRequestID != nil,
           pendingNodeOperation?.playbackRequestID == pending.playbackRequestID,
           current.preferredProviderID == authorization.preferredProviderID {
            // A repeated failure stays inside the existing sheet. Do not
            // reload its QR page or create another automatic-resume budget.
            return
        }
        playerPresentedError = nil
        pendingNodePlaybackConfigurationFallback = nil
        if let previous = nodeWebPresentation {
            nodeAuthorizationCompletionTask?.cancel()
            Task {
                await NodeAuthorizationSignalCenter.shared.cancel(
                    previous.challengeID
                )
            }
        }
        pendingNodeOperation = pending
        let isPlaybackAuthorization = pending.playbackRequestID != nil
        let allowsAutomaticRetry = isPlaybackAuthorization && pending.playbackRequestID.map {
            $0 != nodeAuthorizationAutoRetryRequestID
        } == true
        let websiteLocation = NodeRuntimeWebsiteLocation(
            url: authorization.websiteURL
        )
        let currentWebsiteURL = activeNodeRuntimeEndpoint.flatMap {
            websiteLocation?.resolved(against: $0)
        } ?? authorization.websiteURL
        let status: String
        if isPlaybackAuthorization {
            status = authorization.completionMode == .profileRevision
                ? L10n.string("cloud.authorization.waiting-save", fallback: "Waiting for the configuration to be saved. The current title will be verified automatically only once.")
                : L10n.string("cloud.authorization.waiting-request", fallback: "Waiting for authorization confirmation that matches the current playback request.")
        } else {
            status = L10n.string("cloud.configuration.keep-open", fallback: "The configuration page will remain open. After saving, apply it manually and try the original action again.")
        }
        nodeWebPresentation = NodeWebPresentation(
            id: UUID(),
            challengeID: authorization.challengeID,
            requestID: authorization.requestID,
            sourceIdentity: pending.sourceIdentity,
            runtimeWebsiteLocation: websiteLocation,
            url: currentWebsiteURL,
            title: authorization.title.nonEmpty
                ?? L10n.string("cloud.configuration-center", fallback: "Cloud Configuration Center"),
            message: authorization.message,
            provider: authorization.provider,
            preferredProviderID: authorization.preferredProviderID,
            transport: authorization.transport,
            completionMode: authorization.completionMode,
            challenge: authorization.challenge,
            presentationTarget: ConfigurationPresentationTargetPolicy
                .resolvedTarget(
                    requested: pending.presentationTarget,
                    hasDetailPresentation: selectedDetail != nil
                        || pendingDetailSummary != nil
                ),
            lifecycleState: isPlaybackAuthorization && !allowsAutomaticRetry
                ? .needsManualRetry
                : .waiting,
            status: isPlaybackAuthorization && !allowsAutomaticRetry
                ? L10n.string("cloud.authorization.already-verified", fallback: "This playback request was already verified automatically once. To avoid duplicate transfers, confirm the status and retry manually.")
                : status,
            allowsAutomaticRetry: allowsAutomaticRetry,
            hasAttemptedProfileRevisionVerification: false,
            revision: 0
        )
        let challengeID = authorization.challengeID
        guard allowsAutomaticRetry,
              let requestID = authorization.requestID,
              authorization.completionMode == .explicitSignal else {
            nodeAuthorizationCompletionTask = nil
            return
        }
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = Task { @MainActor [weak self] in
            let signals = await NodeAuthorizationSignalCenter.shared.signals(
                for: challengeID,
                requestID: requestID
            )
            for await signal in signals {
                guard !Task.isCancelled, let self,
                      self.nodeWebPresentation?.challengeID == challengeID else {
                    return
                }
                guard NodeAuthorizationCompletionMatchingPolicy.matches(
                    expectedChallengeID: challengeID,
                    expectedRequestID: requestID,
                    signal: signal
                ) else {
                    continue
                }
                guard self.nodeWebPresentation?.allowsAutomaticRetry == true else {
                    var presentation = self.nodeWebPresentation
                    presentation?.lifecycleState = .needsManualRetry
                    presentation?.status = L10n.string("cloud.authorization.signal-received", fallback: "Authorization confirmation received. To avoid repeating the cloud operation, retry manually.")
                    self.nodeWebPresentation = presentation
                    return
                }
                await self.completeNodeConfigurationAndRetry(
                    automatically: true
                )
                return
            }
        }
    }

    func refreshNodeConfigurationWebsite() {
        guard var presentation = nodeWebPresentation else { return }
        presentation.revision &+= 1
        nodeWebPresentation = presentation
    }

    func cancelNodeConfiguration() {
        let challengeID = nodeWebPresentation?.challengeID
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = nil
        if let challengeID {
            Task {
                await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
            }
        }
        if case .playback = pendingNodeOperation {
            // User cancellation is a neutral terminal state. Do not turn it
            // into a playback failure that can later surface as a stale alert.
            playbackResolutionState = .idle
            playbackFailureSummary = nil
        }
        pendingNodeOperation = nil
        pendingNodePlaybackConfigurationFallback = nil
        nodeWebPresentation = nil
    }

    func completeNodeConfigurationAndRetry(
        automatically: Bool = false,
        configurationAlreadyRefreshed: Bool = false
    ) async {
        guard let pending = pendingNodeOperation,
              var presentation = nodeWebPresentation else { return }
        if automatically, let requestID = pending.playbackRequestID {
            guard requestID != nodeAuthorizationAutoRetryRequestID else {
                presentation.lifecycleState = .needsManualRetry
                presentation.status = L10n.string("cloud.authorization.auto-resume-used", fallback: "Automatic resume has already run once. Confirm authorization, then retry manually.")
                presentation.allowsAutomaticRetry = false
                nodeWebPresentation = presentation
                return
            }
            nodeAuthorizationAutoRetryRequestID = requestID
        }
        detailResponseCache.invalidate()
        catPawSearchMemory.invalidate()
        presentation.lifecycleState = .verifying
        presentation.status = automatically
            ? L10n.string("cloud.authorization.resuming", fallback: "Authorization complete. Resuming playback…")
            : L10n.string("cloud.authorization.refreshing", fallback: "Refreshing authorization and resolving the current content again…")
        nodeWebPresentation = presentation
        if activeConfigurationUsesNodeRuntime && !configurationAlreadyRefreshed {
            // Configuration/login pages can add dynamic AList mounts or alter
            // the enabled site list. Re-read the local CatPawOpen catalogue
            // before deciding whether the original operation still exists.
            _ = await refreshActiveConfigurationIfNeeded(
                force: true,
                reportErrors: false
            )
        }
        guard pendingNodeOperation?.sourceIdentity == pending.sourceIdentity,
              nodeWebPresentation?.challengeID == presentation.challengeID else {
            return
        }
        let identity = pending.sourceIdentity
        guard NodeAuthorizationRetryPolicy.shouldRetry(
            pendingIdentity: identity,
            presentationIdentity: presentation.sourceIdentity,
            activeConfigurationID: activeConfigurationRecord?.id,
            selectedSiteKey: selectedSiteKey,
            requiresSelectedHomeSource: pending.requiresSelectedHomeSource,
            availableSiteKeys: Set(providers.keys)
        ) else {
            // A source/configuration switch supersedes the pending request.
            // Its late completion is expected and must not alert the user.
            cancelNodeConfiguration()
            return
        }

        if case .playback(_, let playback) = pending {
            await verifyNodePlaybackAuthorization(
                pending: pending,
                playback: playback,
                presentation: presentation
            )
            return
        }

        nodeAuthorizationCompletionTask = nil
        await NodeAuthorizationSignalCenter.shared.cancel(
            presentation.challengeID
        )
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        switch pending {
        case .category(_, let siteKey, let id, let page, let filters):
            guard siteKey == identity.siteKey else { return }
            await loadCategory(id: id, page: page, filters: filters)
        case .detail(_, let summary):
            guard summary.siteKey == identity.siteKey else { return }
            await loadDetail(summary)
        case .siteAction(_, let action, let title):
            guard let provider = providers[identity.siteKey] else { return }
            await performSiteAction(
                action,
                title: title,
                provider: provider
            )
        case .homeAction(_, let item):
            guard item.siteKey == identity.siteKey else { return }
            await performHomeAction(item)
        case .playback(_, let playback):
            guard playback.detail.summary.siteKey == identity.siteKey else {
                return
            }
            guard playback.requestID == activePlayerRequestID,
                  playback.requestID == playbackSessionID,
                  isPlayerPresented else {
                return
            }
            await startPlayback(
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode,
                origin: playback.origin,
                configurationID: playback.configurationID,
                continuingRequestID: playback.requestID,
                authorizationRetry: true,
                windowActivation: .preserveFocus,
                recoveryCheckpoint: playback.recoveryCheckpoint
            )
        }
    }

    private func verifyNodePlaybackAuthorization(
        pending: PendingNodeOperation,
        playback: PendingCloudPlayback,
        presentation: NodeWebPresentation
    ) async {
        guard playback.requestID == activePlayerRequestID,
              playback.requestID == playbackSessionID,
              isPlayerPresented,
              let provider = providers[presentation.sourceIdentity.siteKey] else {
            return
        }
        do {
            let transferContext = transferPlaybackContext(
                for: playback.requestID
            )
            let verifiedResult: SitePlaybackResult
            if let nodeProvider = provider as? NodeHTTPSpiderSiteProvider {
                verifiedResult = try await nodeProvider.player(
                    flag: playback.source.name,
                    episodeURL: playback.episode.url,
                    transferContext: transferContext
                )
            } else {
                verifiedResult = try await provider.player(
                    flag: playback.source.name,
                    episodeURL: playback.episode.url
                )
            }
            guard pendingNodeOperation?.sourceIdentity == pending.sourceIdentity,
                  nodeWebPresentation?.challengeID == presentation.challengeID,
                  playback.requestID == activePlayerRequestID,
                  playback.requestID == playbackSessionID,
                  isPlayerPresented else {
                return
            }
            nodeAuthorizationCompletionTask = nil
            await NodeAuthorizationSignalCenter.shared.cancel(
                presentation.challengeID
            )
            pendingNodeOperation = nil
            nodeWebPresentation = nil
            await startPlayback(
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode,
                origin: playback.origin,
                authoritativePlaybackResult: verifiedResult,
                configurationID: playback.configurationID,
                continuingRequestID: playback.requestID,
                authorizationRetry: true,
                windowActivation: .preserveFocus,
                recoveryCheckpoint: playback.recoveryCheckpoint
            )
        } catch let authorization as NodeWebAuthorizationRequired {
            guard pendingNodeOperation?.sourceIdentity == pending.sourceIdentity,
                  nodeWebPresentation?.challengeID == presentation.challengeID else {
                return
            }
            presentNodeConfiguration(authorization, pending: pending)
            if var replacement = nodeWebPresentation {
                replacement.status = L10n.string("cloud.authorization.not-verified", fallback: "Authorization could not be verified. The configuration page will remain open; finish authorization and try again.")
                nodeWebPresentation = replacement
            }
        } catch is CancellationError {
            return
        } catch {
            guard pendingNodeOperation?.sourceIdentity == pending.sourceIdentity,
                  var current = nodeWebPresentation,
                  current.challengeID == presentation.challengeID else {
                return
            }
            nodeAuthorizationCompletionTask = nil
            current.lifecycleState = .needsManualRetry
            current.status = L10n.string("cloud.authorization.verification-failed", fallback: "Authorization verification failed: %@", LogRedactor.text(error.localizedDescription))
            current.allowsAutomaticRetry = false
            nodeWebPresentation = current
        }
    }

    private func activeSourceIdentity(
        for siteKey: String
    ) -> HomeContentIdentity? {
        guard let configurationID = activeConfigurationRecord?.id,
              providers[siteKey] != nil else {
            return nil
        }
        return HomeContentIdentity(
            configurationID: configurationID,
            siteKey: siteKey
        )
    }

    private func invalidatePendingNodeHomeOperation(nextSiteKey: String) {
        guard let pending = pendingNodeOperation,
              pending.requiresSelectedHomeSource,
              pending.sourceIdentity.siteKey != nextSiteKey else {
            return
        }
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = nil
        if let challengeID = nodeWebPresentation?.challengeID {
            Task {
                await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
            }
        }
        pendingNodeOperation = nil
        nodeWebPresentation = nil
    }

    private func cancelActiveCloudAuthorizationInteraction(
        nextIdentity: HomeContentIdentity?
    ) {
        if let pending = pendingTVBoxConfigurationAction,
           pending.refreshTarget.sourceIdentity != nextIdentity {
            cancelPendingTVBoxConfigurationAction(pending.id)
        }
        guard let context = cloudAuthorizationContext,
              context.sourceIdentity != nextIdentity else {
            return
        }
        clearCloudAuthorization(
            resetBridgeUI: true,
            markPendingPlaybackCancelled: false,
            cancellationReason: .sourceChanged
        )
    }

    private func cloudAccountScopeID(
        for provider: SiteProvider,
        sourceIdentity: HomeContentIdentity?
    ) -> String? {
        if let android = provider as? AndroidDexSpiderSiteProvider,
           let owner = android.cloudAccountScopeID {
            return owner
        }
        guard let sourceIdentity,
              let providerIdentity = CloudAccountProviderIdentity.identifier(
            capability: provider.capability,
            api: provider.site.api
        ) else { return nil }
        return [
            "provider-scope-v1",
            sourceIdentity.configurationID.uuidString.lowercased(),
            sourceIdentity.siteKey,
            providerIdentity
        ].joined(separator: ":")
    }

    private func invalidatePersistedCloudAccountStatus(
        provider: SiteProvider,
        command: String
    ) async {
        let identity = activeSourceIdentity(for: provider.site.key)
        guard let scopeID = cloudAccountScopeID(
            for: provider,
            sourceIdentity: identity
        ), cloudAccountStatusStore.invalidate(
            scopeID: scopeID,
            command: command
        ) else {
            return
        }
        await persistCloudAccountStatusStore()
        guard let identity,
              currentHomeContentIdentity == identity,
              homeContentIdentity == identity,
              var updatedHome = siteHome else { return }
        updatedHome.actionItems = updatedHome.actionItems.map { item in
            var updated = item
            updated.title = cloudAccountStatusStore.reconciledTitle(
                item.title,
                scopeID: scopeID
            )
            if let remarks = item.remarks {
                updated.remarks = cloudAccountStatusStore.reconciledTitle(
                    remarks,
                    scopeID: scopeID
                )
            }
            return updated
        }
        publishHomeContent(updatedHome, identity: identity)
        await cacheSiteHome(updatedHome, identity: identity)
    }

    private func clearCloudAuthorization(
        resetBridgeUI: Bool,
        markPendingPlaybackCancelled: Bool,
        cancellationReason: ConfigurationInteractionCancellationReason = .user,
        cancelProviderHandle: Bool = true
    ) {
        let androidDexBridge = environment?.androidDexBridge
        let providerHandle = cloudAuthorizationContext?.providerHandle
        let hadPendingPlayback = cloudAuthorizationContext?
            .operation.pendingPlayback != nil
        let interactionID = cloudAuthorizationContext?.operationID
            ?? cloudAuthorizationPrompt?.interactionID
        if let interactionID {
            configurationInteractionCoordinator.cancel(
                interactionID,
                reason: cancellationReason
            )
            configurationInteractionCoordinator.clear(interactionID)
        }
        configurationInteractionTerminalTask?.cancel()
        configurationInteractionTerminalTask = nil
        if cancelProviderHandle {
            scheduleConfigurationInteractionCleanup(
                providerHandle,
                reason: cancellationReason.rawValue
            )
        }
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        cloudAuthorizationPrompt = nil
        cloudAuthorizationInput = ""
        cloudAuthorizationSurfaceFrame = nil
        lastCloudAuthorizationSurfaceCaptureAt = nil
        cloudAuthorizationContext = nil
        if markPendingPlaybackCancelled, hadPendingPlayback {
            let message = L10n.string("cloud.authorization.cancelled", fallback: "Cloud Authorization Cancelled")
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
        }
        // A scoped handle owns its Android interaction and was cancelled
        // above. Resetting the process-global legacy UI as well could erase a
        // newer request that has already superseded this one.
        guard resetBridgeUI, providerHandle == nil else { return }
        let previousCleanup = configurationInteractionCleanupTask
        configurationInteractionCleanupTask = Task {
            await previousCleanup?.value
            try? await androidDexBridge?.resetAuthorizationUI(interactionID: interactionID)
        }
    }

    private func isCurrentCloudAuthorizationContext(
        _ context: CloudAuthorizationContext
    ) -> Bool {
        guard configurationInteractionCoordinator.owns(
            context.operationID,
            generation: context.requestGeneration
        ) else {
            return false
        }
        guard CloudAuthorizationRetryPolicy.isCurrent(
            sourceIdentity: context.sourceIdentity,
            activeConfigurationID: activeConfigurationRecord?.id,
            availableSiteKeys: Set(providers.keys)
        ) else {
            return false
        }
        guard let requestID = context.operation.playbackRequestID else {
            return true
        }
        return CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
            requestID: requestID,
            activeRequestID: activePlayerRequestID,
            playbackSessionID: playbackSessionID,
            isPlayerPresented: isPlayerPresented
        )
    }

    private var cloudInteractionLabel: String {
        let kind = cloudAuthorizationPrompt?.interactionKind
            ?? cloudAuthorizationContext?.operation.interactionKind
        return kind == .authorization
            ? L10n.string("cloud.authorization.title", fallback: "Cloud Authorization")
            : L10n.string("cloud.configuration-action.title", fallback: "Configuration Action")
    }

    func cancelCloudAuthorization() async {
        if cloudAuthorizationContext == nil,
           cloudAuthorizationPrompt?.lifecyclePhase.isTerminal == true {
            cloudAuthorizationPrompt = nil
            cloudAuthorizationInput = ""
            cloudAuthorizationSurfaceFrame = nil
            lastCloudAuthorizationSurfaceCaptureAt = nil
            return
        }
        // The Android dialog is a real native window. Merely hiding the
        // SwiftUI layer leaves it stacked behind the app and causes the next
        // detail/play call to receive the wrong provider prompt.
        let bridge = environment?.androidDexBridge
        let providerHandle = cloudAuthorizationContext?.providerHandle
        let cancelsPlayback = cloudAuthorizationContext?
            .operation.pendingPlayback != nil
        let usesLegacyBridge = providerHandle == nil
        clearCloudAuthorization(
            resetBridgeUI: false,
            markPendingPlaybackCancelled: false,
            cancelProviderHandle: false
        )
        if let providerHandle {
            await providerHandle.cancelAndWait(
                reason: ConfigurationInteractionCancellationReason.user.rawValue
            )
        } else if usesLegacyBridge {
            try? await bridge?.resetAuthorizationUI()
        }
        if cancelsPlayback {
            await closePlayer()
        }
    }

    func refreshCloudAuthorization() async {
        guard environment != nil,
              let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context) else {
            cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
            return
        }
        do {
            let state = try await configurationInteractionState(for: context)
            guard configurationInteractionCoordinator.owns(context.operationID),
                  cloudAuthorizationContext?.operationID == context.operationID,
                  acceptConfigurationInteractionState(state, context: context) else {
                return
            }
            if await consumeConfigurationTerminalState(
                state,
                context: context
            ) {
                return
            }
            guard state.isProviderUIPrompt else {
                await updateCloudAuthorizationSurfaceFrame(
                    for: state,
                    context: context
                )
                startCloudAuthorizationPolling()
                return
            }
            await updateCloudAuthorizationPrompt(state)
            startCloudAuthorizationPolling()
        } catch is CancellationError {
            return
        } catch {
            guard configurationInteractionCoordinator.owns(context.operationID) else {
                return
            }
            if AsyncCancellationPolicy.isCancellation(error) {
                return
            }
            failConfigurationInteraction(
                context.operationID,
                message: localizedRuntimeErrorMessage(error)
            )
        }
    }

    func confirmCloudAuthorizationCompletion() async {
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              var prompt = cloudAuthorizationPrompt,
              prompt.interactionID == context.operationID,
              prompt.allowsCompletionConfirmation,
              !prompt.lifecyclePhase.isTerminal else {
            return
        }
        prompt.lifecyclePhase = .submitting
        prompt.status = context.operation.pendingPlayback == nil
            ? L10n.string("cloud.configuration.confirming", fallback: "Confirming the result and refreshing configuration…")
            : L10n.string("cloud.authorization.playback-resuming", fallback: "Authorization successful. Resuming playback…")
        cloudAuthorizationPrompt = prompt
        _ = configurationInteractionCoordinator.transition(
            context.operationID,
            to: .submitting,
            status: prompt.status
        )
        do {
            if let handle = context.providerHandle {
                let state = try await handle.confirmCompletion()
                guard configurationInteractionCoordinator.owns(
                        context.operationID,
                        generation: context.requestGeneration
                      ),
                      cloudAuthorizationContext?.operationID
                        == context.operationID,
                      acceptConfigurationInteractionState(
                        state,
                        context: context
                      ) else {
                    return
                }
                _ = await consumeConfigurationTerminalState(
                    state,
                    context: context
                )
                startCloudAuthorizationPolling()
            } else {
                await finishCloudAuthorizationAndRetry()
            }
        } catch is CancellationError {
            return
        } catch {
            guard configurationInteractionCoordinator.owns(
                    context.operationID,
                    generation: context.requestGeneration
                  ) else {
                return
            }
            failConfigurationInteraction(
                context.operationID,
                message: localizedRuntimeErrorMessage(error)
            )
        }
    }

    func retryCloudAuthorizationOperation() async {
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              cloudAuthorizationPrompt?.allowsRetry == true else {
            return
        }
        let operation = context.operation
        let siteKey = context.sourceIdentity.siteKey
        await supersedeConfigurationInteractionIfNeeded()

        switch operation {
        case .playback(let pending):
            guard pending.detail.summary.siteKey == siteKey else { return }
            await startPlayback(
                detail: pending.detail,
                source: pending.source,
                episode: pending.episode,
                origin: pending.origin,
                configurationID: pending.configurationID,
                windowActivation: .preserveFocus
            )
        case .detail(let summary):
            guard summary.siteKey == siteKey else { return }
            await loadDetail(summary)
        case .homeAction(let item):
            guard item.siteKey == siteKey else { return }
            await performHomeAction(item)
        case .siteAction(let action, let title, let tag):
            guard let provider = providers[siteKey] else {
                show(
                    AppError.site(L10n.string("configuration.action.provider-unavailable", fallback: "The provider for this action is currently unavailable")),
                    title: title
                )
                return
            }
            await performSiteAction(
                action,
                title: title,
                provider: provider,
                tag: tag
            )
        }
    }

    private func presentCloudAuthorization(
        _ state: AndroidBridgeUIState,
        interaction: ConfigurationInteraction? = nil,
        handle: InteractionHandle? = nil,
        operation: PendingCloudOperation,
        siteKey: String
    ) async {
        detailResponseCache.invalidate()
        let stateInteractionID = state.interactionID.flatMap(UUID.init(uuidString:))
        let scopedIdentifiers = [handle?.id, interaction?.id, stateInteractionID]
            .compactMap { $0 }
        guard Set(scopedIdentifiers).count <= 1 else {
            handle?.cancel()
            if let activeID = cloudAuthorizationContext?.operationID {
                failConfigurationInteraction(
                    activeID,
                    message: L10n.string("configuration.action.request-mismatch", fallback: "The provider returned a mismatched configuration request identifier. Try again.")
                )
            }
            return
        }
        let interactionID = handle?.id
            ?? interaction?.id
            ?? stateInteractionID
            ?? UUID()
        if var current = cloudAuthorizationContext,
           current.operationID == interactionID,
           configurationInteractionCoordinator.owns(
                interactionID,
                generation: current.requestGeneration
           ) {
            guard current.sourceIdentity.siteKey == siteKey else {
                handle?.cancel()
                failConfigurationInteraction(
                    interactionID,
                    message: L10n.string("configuration.action.source-mismatch", fallback: "The configuration interface does not match the current action. Try again.")
                )
                return
            }
            current.providerHandle = handle
            current.providerInteraction = interaction
            current.operation = operation
            cloudAuthorizationContext = current
            if var prompt = cloudAuthorizationPrompt,
               prompt.interactionID == interactionID {
                prompt.presentationTarget = cloudAuthorizationPresentationTarget(
                    for: operation
                )
                cloudAuthorizationPrompt = prompt
            }
            transitionConfigurationInteraction(
                interactionID,
                to: .presenting,
                status: L10n.string("configuration.action.waiting-interface", fallback: "Waiting for the provider to open the next action screen…")
            )
        } else {
            await supersedeConfigurationInteractionIfNeeded()
            guard beginConfigurationInteraction(
                title: L10n.string("cloud.configuration-action.title", fallback: "Configuration Action"),
                siteKey: siteKey,
                operation: operation,
                semantic: operation.initialSemantic,
                interactionID: interactionID,
                providerHandle: handle,
                providerInteraction: interaction,
                phase: .presenting
            ) != nil else {
                handle?.cancel()
                return
            }
        }
        guard let context = cloudAuthorizationContext,
              acceptConfigurationInteractionState(state, context: context) else {
            handle?.cancel()
            failConfigurationInteraction(
                interactionID,
                message: L10n.string("configuration.action.interface-mismatch", fallback: "The configuration interface returned by the provider does not belong to the current action. Try again.")
            )
            return
        }
        await updateCloudAuthorizationPrompt(state)
        guard configurationInteractionCoordinator.owns(interactionID),
              cloudAuthorizationContext?.operationID == interactionID else {
            handle?.cancel()
            return
        }
        startCloudAuthorizationPolling()
        if let handle {
            observeConfigurationInteractionTerminal(handle)
        }
    }

    func openCloudConfigurationWebLink(_ index: Int, interactionID: UUID) async {
        guard let context = cloudAuthorizationContext,
              context.operationID == interactionID,
              configurationInteractionCoordinator.owns(interactionID),
              isCurrentCloudAuthorizationContext(context),
              let environment else { return }
        do {
            let state = try await environment.androidDexBridge.openConfigurationWebLink(
                interactionID: interactionID, index: index)
            guard cloudAuthorizationContext?.operationID == interactionID else { return }
            await updateCloudAuthorizationPrompt(state)
        } catch {
            guard cloudAuthorizationContext?.operationID == interactionID else { return }
            cloudAuthorizationPrompt?.status = localizedRuntimeErrorMessage(error)
        }
    }

    private func updateCloudAuthorizationPrompt(
        _ state: AndroidBridgeUIState
    ) async {
        guard let operationID = cloudAuthorizationContext?.operationID,
              configurationInteractionCoordinator.owns(operationID) else {
            return
        }
        let previous = cloudAuthorizationPrompt
        let providerHandle = cloudAuthorizationContext?.providerHandle
        let initialProviderInteraction = cloudAuthorizationContext?
            .providerInteraction
        let latestProviderInteraction = await providerHandle?.latestInteraction()
        guard configurationInteractionCoordinator.owns(operationID),
              cloudAuthorizationContext?.operationID == operationID else {
            return
        }
        let fallbackActionKind = providerHandle?.actionKind
            ?? latestProviderInteraction?.actionKind
            ?? initialProviderInteraction?.actionKind
            ?? .configuration
        let providerInteraction = state.configurationInteraction(
            requestID: operationID,
            actionKind: fallbackActionKind
        )
        await providerHandle?.record(providerInteraction)
        guard configurationInteractionCoordinator.owns(operationID),
              var context = cloudAuthorizationContext,
              context.operationID == operationID else {
            return
        }
        context.providerInteraction = providerInteraction
        if let owner = state.providerOwnerID?.nonEmpty {
            context.providerOwnerID = owner
        }
        cloudAuthorizationContext = context
        let semantic = context.operation.initialSemantic
        let interactionKind = ConfigurationInteractionClassificationPolicy
            .interactionKind(for: semantic)
        let lifecyclePhase: ConfigurationInteractionPhase =
            state.isProviderUIPrompt ? .presenting : .awaitingInterface
        let status: String
        if lifecyclePhase == .presenting {
            status = context.operation.pendingPlayback == nil
                ? L10n.string("cloud.android.complete-and-refresh", fallback: "Complete the action in the native Android interface, then select Finish and Refresh.")
                : L10n.string("cloud.android.complete", fallback: "Complete the action in the native Android interface")
        } else {
            status = L10n.string("cloud.android.waiting", fallback: "Waiting for the provider to create the Android action interface…")
        }
        let updated = CloudAuthorizationPrompt(
            id: previous?.id ?? UUID(),
            interactionID: operationID,
            requestGeneration: context.requestGeneration,
            title: configurationInteractionCoordinator.current?.request.title
                ?? (interactionKind == .authorization
                    ? L10n.string("cloud.authorization.title", fallback: "Cloud Authorization")
                    : L10n.string("cloud.configuration-action.title", fallback: "Configuration Action")),
            interactionKind: interactionKind,
            semantic: semantic,
            transport: .native,
            lifecyclePhase: lifecyclePhase,
            presentationTarget: previous?.presentationTarget
                ?? cloudAuthorizationPresentationTarget(
                    for: context.operation
            ),
            status: status,
            allowsRetry: previous?.allowsRetry ?? false,
            allowsCompletionConfirmation:
                context.operation.pendingPlayback == nil || state.playbackAwaitingAuthorization == true,
            webLinks: state.webLinks ?? []
        )
        _ = configurationInteractionCoordinator.transition(
            operationID,
            to: lifecyclePhase,
            semantic: semantic,
            transport: .native,
            status: status
        )
        if updated != previous {
            cloudAuthorizationPrompt = updated
        }
        if let current = cloudAuthorizationContext,
           current.operationID == operationID {
            await updateCloudAuthorizationSurfaceFrame(
                for: state,
                context: current
            )
        }
    }

    private func updateCloudAuthorizationSurfaceFrame(
        for state: AndroidBridgeUIState,
        context: CloudAuthorizationContext
    ) async {
        // A provider may hand the request to a browser, system picker or
        // another Android Activity. In that case the Bridge-owned root is not
        // reported as `visible`, but the request-scoped full display is still
        // exactly the surface the user must operate. Ownership/terminal checks
        // below are the security boundary; `visible` is only UI metadata.
        guard state.isProviderUIPrompt else {
            let capturedRecently = lastCloudAuthorizationSurfaceCaptureAt.map {
                Date().timeIntervalSince($0) < 0.8
            } ?? false
            if !capturedRecently
                    || !AndroidActionSurfaceContinuityPolicy.canRetain(
                cloudAuthorizationSurfaceFrame,
                expectedInteractionID: context.operationID,
                providerOwnerID: state.providerOwnerID,
                generation: nil
            ) {
                cloudAuthorizationSurfaceFrame = nil
            }
            if !capturedRecently {
                lastCloudAuthorizationSurfaceCaptureAt = nil
            }
            return
        }
        guard configurationInteractionCoordinator.owns(
                context.operationID,
                generation: context.requestGeneration
              ),
              cloudAuthorizationContext?.operationID == context.operationID,
              cloudAuthorizationPrompt?.interactionID == context.operationID,
              let bridge = environment?.androidDexBridge else {
            if cloudAuthorizationContext?.operationID == context.operationID {
                cloudAuthorizationSurfaceFrame = nil
            }
            return
        }

        if let previous = cloudAuthorizationSurfaceFrame,
           !AndroidActionSurfaceLeasePolicy.accepts(
                frame: previous,
                replacing: nil,
                expectedInteractionID: context.operationID,
                expectedProviderOwnerID: state.providerOwnerID,
                expectedGeneration: state.interactionGeneration
           ) {
            cloudAuthorizationSurfaceFrame = nil
            lastCloudAuthorizationSurfaceCaptureAt = nil
        }
        if let previous = cloudAuthorizationSurfaceFrame,
           !AndroidActionSurfaceLeasePolicy.matchesCurrentWindow(
                previous,
                descriptor: state.actionSurfaceCaptureDescriptor
           ) {
            cloudAuthorizationSurfaceFrame = nil
            lastCloudAuthorizationSurfaceCaptureAt = nil
        }
        let now = Date()
        if let lastCloudAuthorizationSurfaceCaptureAt,
           now.timeIntervalSince(lastCloudAuthorizationSurfaceCaptureAt) < 0.45 {
            return
        }
        lastCloudAuthorizationSurfaceCaptureAt = now
        do {
            let frame = try await bridge.actionSurfaceFrame(
                interactionID: context.operationID
            )
            guard configurationInteractionCoordinator.owns(
                    context.operationID,
                    generation: context.requestGeneration
                  ),
                  cloudAuthorizationContext?.operationID == context.operationID,
                  cloudAuthorizationPrompt?.requestGeneration
                    == context.requestGeneration,
                  AndroidActionSurfaceLeasePolicy.accepts(
                    frame: frame,
                    replacing: cloudAuthorizationSurfaceFrame,
                    expectedInteractionID: context.operationID,
                    expectedProviderOwnerID: state.providerOwnerID,
                    expectedGeneration: state.interactionGeneration
                  ) else {
                return
            }
            // FLAG_SECURE yields a black screencap instead of an error on some
            // emulator releases. Never publish that frame, but keep the last
            // valid frame from this exact lease to avoid a placeholder flash.
            if Self.isRenderableActionSurface(frame.pngData) {
                cloudAuthorizationSurfaceFrame = frame
            }
        } catch {
            guard configurationInteractionCoordinator.owns(
                    context.operationID,
                    generation: context.requestGeneration
                  ),
                  cloudAuthorizationContext?.operationID == context.operationID else {
                return
            }
            if !AndroidActionSurfaceContinuityPolicy.canRetain(
                cloudAuthorizationSurfaceFrame,
                expectedInteractionID: context.operationID,
                providerOwnerID: state.providerOwnerID,
                generation: state.interactionGeneration
            ) {
                cloudAuthorizationSurfaceFrame = nil
            }
        }
    }

    private static func isRenderableActionSurface(_ png: Data) -> Bool {
        guard let bitmap = NSBitmapImageRep(data: png),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return false
        }
        let columns = 9
        let rows = 9
        var nearBlack = 0
        var samples = 0
        for column in 1...columns {
            for row in 1...rows {
                let x = bitmap.pixelsWide * column / (columns + 1)
                let y = bitmap.pixelsHigh * row / (rows + 1)
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else {
                    continue
                }
                samples += 1
                if color.redComponent < 0.02,
                   color.greenComponent < 0.02,
                   color.blueComponent < 0.02 {
                    nearBlack += 1
                }
            }
        }
        return samples > 0 && nearBlack * 100 < samples * 96
    }

    func tapCloudAuthorizationSurface(
        x: Int,
        y: Int,
        frame: AndroidActionSurfaceFrame
    ) async {
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              frame.interactionID == context.operationID,
              let currentFrame = cloudAuthorizationSurfaceFrame,
              AndroidActionSurfaceLeasePolicy.isExactLease(
                currentFrame,
                frame
              ),
              let bridge = environment?.androidDexBridge else {
            return
        }
        lastCloudAuthorizationSurfaceCaptureAt = nil
        do {
            try await bridge.tapActionSurface(
                frame: frame,
                x: x,
                y: y
            )
            guard isCurrentCloudAuthorizationContext(context) else { return }
            await refreshCloudAuthorization()
        } catch {
            guard isCurrentCloudAuthorizationContext(context),
                  !AsyncCancellationPolicy.isCancellation(error) else {
                return
            }
            await refreshCloudAuthorization()
        }
    }

    func swipeCloudAuthorizationSurface(
        fromX: Int,
        fromY: Int,
        toX: Int,
        toY: Int,
        durationMilliseconds: Int = 300,
        frame: AndroidActionSurfaceFrame
    ) async {
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              frame.interactionID == context.operationID,
              let currentFrame = cloudAuthorizationSurfaceFrame,
              AndroidActionSurfaceLeasePolicy.isExactLease(
                currentFrame,
                frame
              ),
              let bridge = environment?.androidDexBridge else {
            return
        }
        lastCloudAuthorizationSurfaceCaptureAt = nil
        do {
            try await bridge.swipeActionSurface(
                frame: frame,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                durationMilliseconds: durationMilliseconds
            )
            guard isCurrentCloudAuthorizationContext(context) else { return }
            await refreshCloudAuthorization()
        } catch {
            guard isCurrentCloudAuthorizationContext(context),
                  !AsyncCancellationPolicy.isCancellation(error) else {
                return
            }
            await refreshCloudAuthorization()
        }
    }

    func backCloudAuthorizationSurface(
        frame: AndroidActionSurfaceFrame
    ) async {
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              frame.interactionID == context.operationID,
              let currentFrame = cloudAuthorizationSurfaceFrame,
              AndroidActionSurfaceLeasePolicy.isExactLease(
                currentFrame,
                frame
              ),
              let bridge = environment?.androidDexBridge else {
            return
        }
        lastCloudAuthorizationSurfaceCaptureAt = nil
        do {
            try await bridge.backActionSurface(frame: frame)
            guard isCurrentCloudAuthorizationContext(context) else { return }
            await refreshCloudAuthorization()
        } catch {
            guard isCurrentCloudAuthorizationContext(context),
                  !AsyncCancellationPolicy.isCancellation(error) else {
                return
            }
            await refreshCloudAuthorization()
        }
    }

    func typeCloudAuthorizationSurfaceText(
        frame: AndroidActionSurfaceFrame
    ) async {
        let text = cloudAuthorizationInput
        guard let context = cloudAuthorizationContext,
              isCurrentCloudAuthorizationContext(context),
              !text.isEmpty,
              frame.interactionID == context.operationID,
              let currentFrame = cloudAuthorizationSurfaceFrame,
              AndroidActionSurfaceLeasePolicy.isExactLease(
                currentFrame,
                frame
              ),
              let bridge = environment?.androidDexBridge else {
            return
        }
        do {
            try await bridge.typeActionSurface(frame: frame, text: text)
            guard isCurrentCloudAuthorizationContext(context) else { return }
            cloudAuthorizationInput = ""
            lastCloudAuthorizationSurfaceCaptureAt = nil
            await refreshCloudAuthorization()
        } catch {
            guard isCurrentCloudAuthorizationContext(context),
                  !AsyncCancellationPolicy.isCancellation(error) else {
                return
            }
            await refreshCloudAuthorization()
        }
    }

    private func startCloudAuthorizationPolling() {
        cloudAuthorizationSessionID = UUID()
        let sessionID = cloudAuthorizationSessionID
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = Task { [weak self] in
            var bridgeFailureCount = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard let self,
                      self.cloudAuthorizationSessionID == sessionID,
                      self.cloudAuthorizationPrompt != nil,
                      let context = self.cloudAuthorizationContext,
                      self.configurationInteractionCoordinator.owns(
                        context.operationID
                      ),
                      self.isCurrentCloudAuthorizationContext(context),
                      self.environment != nil else {
                    return
                }
                do {
                    let state = try await self.configurationInteractionState(
                        for: context
                    )
                    guard self.cloudAuthorizationSessionID == sessionID,
                          self.acceptConfigurationInteractionState(
                            state,
                            context: context
                          ) else {
                        throw AppError.spider(
                            L10n.string("configuration.action.replaced", fallback: "Another action replaced the configuration state")
                        )
                    }
                    bridgeFailureCount = 0
                    if await self.consumeConfigurationTerminalState(
                        state,
                        context: context
                    ) {
                        guard self.cloudAuthorizationSessionID == sessionID,
                              self.configurationInteractionCoordinator.owns(
                                context.operationID
                              ),
                              self.cloudAuthorizationPrompt != nil else {
                            return
                        }
                        continue
                    }
                    // Action Session has exactly two nonterminal observations:
                    // a request-owned Android surface, or a provider worker
                    // which has not returned yet. Pixels and view content do
                    // not participate in classification or completion.
                    if state.isProviderUIPrompt {
                        if var current = self.cloudAuthorizationContext,
                           current.operationID == context.operationID {
                            current.hasObservedPrompt = true
                            self.cloudAuthorizationContext = current
                        }
                        await self.updateCloudAuthorizationPrompt(state)
                        continue
                    }
                    await self.updateCloudAuthorizationSurfaceFrame(
                        for: state,
                        context: context
                    )
                    if var prompt = self.cloudAuthorizationPrompt,
                       prompt.interactionID == context.operationID {
                        prompt.lifecyclePhase = state.workerReturned == true
                            ? .presenting
                            : .processing
                        prompt.status = state.workerReturned == true
                            ? L10n.string("cloud.android.method-returned", fallback: "The provider method returned. After confirming the Android action is complete, select Finish and Refresh.")
                            : L10n.string("cloud.android.interface-waiting", fallback: "The Android action interface is temporarily hidden while the provider processes the request…")
                        prompt.allowsCompletionConfirmation =
                            context.operation.pendingPlayback == nil
                                && context.hasObservedPrompt
                        self.cloudAuthorizationPrompt = prompt
                    }
                    continue
                } catch is CancellationError {
                    return
                } catch {
                    bridgeFailureCount += 1
                    if bridgeFailureCount >= 6 {
                        self.scheduleConfigurationInteractionCleanup(
                            context.providerHandle,
                            reason: ConfigurationInteractionCancellationReason
                                .providerCancelled.rawValue
                        )
                        self.failConfigurationInteraction(
                            context.operationID,
                            message: L10n.string("configuration.bridge.unresponsive", fallback: "The local configuration bridge repeatedly failed to respond. Try the action again.")
                        )
                        return
                    }
                }
            }
        }
    }

    private func finishCloudAuthorizationAndRetry(
        providerResult: JSONValue? = nil,
        refreshPerformed: Bool? = nil
    ) async {
        guard let context = cloudAuthorizationContext,
              configurationInteractionCoordinator.owns(context.operationID),
              isCurrentCloudAuthorizationContext(context) else {
            return
        }
        detailResponseCache.invalidate()
        let hasProviderResult = providerResult.map { $0 != .null } == true
        if case .playback = context.operation,
           context.providerHandle != nil,
           !hasProviderResult {
            // A scoped playerContent worker is the sole owner of this media
            // result. A successful UI transition without that result is not
            // permission to issue playerContent again under a second request.
            failConfigurationInteraction(
                context.operationID,
                message: L10n.string("cloud.authorization.no-media", fallback: "Authorization finished, but the original playback request returned no media. Try playback again.")
            )
            return
        }
        var authoritativePlaybackResult: SitePlaybackResult?
        if case .playback(let pending) = context.operation,
           let providerResult,
           providerResult != .null {
            guard let provider = providers[context.sourceIdentity.siteKey]
                as? AndroidDexSpiderSiteProvider else {
                failConfigurationInteraction(
                    context.operationID,
                    message: L10n.string("player.provider-changed", fallback: "The provider associated with the playback result changed. Try again.")
                )
                return
            }
            do {
                var mapped = try provider.playbackResult(
                    from: providerResult,
                    flag: pending.source.name,
                    episodeURL: pending.episode.url
                )
                if let refreshPerformed,
                   mapped.mediaSession?.refreshPerformed == nil {
                    mapped.mediaSession?.refreshPerformed = refreshPerformed
                }
                authoritativePlaybackResult = mapped
            } catch {
                failConfigurationInteraction(
                    context.operationID,
                    message: localizedRuntimeErrorMessage(error)
                )
                return
            }
        }
        if case .playback(let pending) = context.operation {
            guard playbackAuthorizationResumeGate.claim(
                requestID: pending.requestID,
                activeRequestID: activePlayerRequestID,
                playbackSessionID: playbackSessionID,
                isPlayerPresented: isPlayerPresented,
                hasAuthoritativeResult: authoritativePlaybackResult != nil,
                requiresAuthoritativeResult: context.providerHandle != nil,
                originalRequestIsResolving: playbackRequestsResolving.contains(
                    pending.requestID
                )
            ) else {
                return
            }
        }
        let completionSemantic = cloudAuthorizationPrompt?.semantic
            ?? context.operation.initialSemantic
        if let actionStatusGeneration = context.actionStatusGeneration {
            publishSiteActionStatus(
                providerResult.flatMap(Self.siteActionMessage) ?? L10n.string("configuration.action.finished", fallback: "Operation finished"),
                title: configurationInteractionCoordinator.current?
                    .request.title
                    ?? L10n.string("cloud.configuration-action.title", fallback: "Configuration Action"),
                generation: actionStatusGeneration
            )
        }
        let isPlaybackOperation: Bool = {
            if case .playback = context.operation {
                return true
            }
            return false
        }()
        let completionStatus: String
        if isPlaybackOperation {
            completionStatus = L10n.string("cloud.authorization.playback-resuming", fallback: "Authorization successful. Resuming playback…")
        } else {
            switch completionSemantic {
            case .order:
                completionStatus = L10n.string("configuration.action.sort-updated", fallback: "Sort Order Updated")
            case .toggle:
                completionStatus = L10n.string("configuration.action.settings-updated", fallback: "Settings Updated")
            default:
                completionStatus = L10n.string("configuration.action.completed", fallback: "Configuration Action Complete")
            }
        }
        completeConfigurationInteraction(
            context.operationID,
            status: completionStatus
        )
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              isCurrentCloudAuthorizationContext(context) else {
            return
        }
        // Playback has an authoritative media result and can resume
        // immediately. Legacy configuration actions have no provider-level
        // completion callback, so retain the completed result until the user
        // closes it instead of dismissing on a timing heuristic.
        retireCompletedConfigurationInteraction(
            context.operationID,
            preservingPrompt: !isPlaybackOperation
        )
        configurationInteractionTerminalTask = nil
        switch context.operation {
        case .playback(let pending):
            guard pending.detail.summary.siteKey == context.sourceIdentity.siteKey else {
                return
            }
            await startPlayback(
                detail: pending.detail,
                source: pending.source,
                episode: pending.episode,
                origin: pending.origin,
                authoritativePlaybackResult: authoritativePlaybackResult,
                configurationID: pending.configurationID,
                continuingRequestID: pending.requestID,
                authorizationRetry: true,
                windowActivation: .preserveFocus
            )
        case .detail(let summary):
            guard summary.siteKey == context.sourceIdentity.siteKey else { return }
            if context.providerHandle != nil,
               let provider = providers[summary.siteKey] as? AndroidDexSpiderSiteProvider {
                // The original worker is authoritative for scoped TVBox UI.
                // Configuration completion never replays its side effects.
                switch provider.selectionAfterInteraction(providerResult ?? .null, summary: summary) {
                case .detail(let detail):
                    guard acceptsFavoriteDetail(detail) else { return }
                    detailRouteSummary = summary
                    selectedDetail = detail
                    pendingDetailSummary = nil
                    detailLoadState = .loaded
                    detailRevision &+= 1
                    await completeFavoriteDetail(detail)
                case .action, .search:
                    dismissDetail()
                    if selectedSection == .home,
                       selectedSiteKey == context.sourceIdentity.siteKey {
                        await loadSelectedSiteHome(refreshConfigurationIfNeeded: false,
                            forceCategoryRefresh: true, forceHomeRefresh: true)
                    }
                }
            } else if summary.resolvedContentKind == .action,
                      selectedSection == .home,
                      selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
            } else {
                await loadDetail(summary)
            }
        case .homeAction:
            if let target = context.configurationRefreshTarget {
                await refreshTVBoxConfigurationAfterAction(target)
            } else if selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false,
                    forceCategoryRefresh: true, forceHomeRefresh: true)
            }
        case .siteAction:
            if let target = context.configurationRefreshTarget {
                await refreshTVBoxConfigurationAfterAction(target)
            } else if selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
            }
        }
    }

    static func shouldWaitForCloudAuthorization(
        capability: SiteCapability
    ) -> Bool {
        capability == .javaDexSpider
    }

    /// Mirrors FongMi's `Result.getMsg()`/`Notify.show` boundary: an explicit
    /// message may become transient feedback, while null, an empty string, or
    /// an object without a message is a normal silent action completion.
    static func siteActionMessage(_ value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for key in ["msg", "message", "error", "errMsg"] {
                guard let item = object[key] else { continue }
                if case .string(let message) = item,
                   let message = message.nonEmpty {
                    return message
                }
            }
        case .string(let message):
            if let message = message.nonEmpty { return message }
        default:
            break
        }
        return nil
    }

    func requestOpenFavorite(_ id: String, repairSource: Bool = false) {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return }
        if favoriteLoadingID == id { return }
        favoriteOpenTask?.cancel()
        let generation = UUID(); favoriteOpenGeneration = generation; favoriteLoadingID = id
        favoriteOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openFavorite(favorite, generation: generation, repairSource: repairSource)
            if self.favoriteOpenGeneration == generation { self.favoriteLoadingID = nil; self.favoriteOpenTask = nil }
        }
    }

    func openFavorite(_ favorite: FavoriteRecord) async {
        requestOpenFavorite(favorite.id)
        await favoriteOpenTask?.value
    }

    private func chooseFavoriteSource(_ favorite: FavoriteRecord) async -> UUID? {
        guard !configurations.isEmpty, let window = NSApp.keyWindow else { return nil }
        let options = configurations
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
        picker.addItems(withTitles: options.map(\.name))
        let alert = NSAlert(); alert.messageText = L10n.string("favorites.source.choose", fallback: "Confirm Favorite Source")
        alert.informativeText = L10n.string("favorites.source.choose-message", fallback: "Choose the configuration that contains %@. The saved favorite is kept until the returned details are verified.", favorite.title)
        alert.accessoryView = picker
        alert.addButton(withTitle: L10n.string(.commonCancel)); alert.addButton(withTitle: L10n.string("common.continue", fallback: "Continue"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn && options.indices.contains(picker.indexOfSelectedItem) ? options[picker.indexOfSelectedItem].id : nil)
            }
        }
    }

    private func openFavorite(_ original: FavoriteRecord, generation: UUID, repairSource: Bool) async {
        var favorite = original
        var needsBinding = repairSource || favorite.configurationID == nil
            || !configurations.contains(where: { $0.id == favorite.configurationID })
        let targetID: UUID?
        if needsBinding { targetID = await chooseFavoriteSource(favorite) }
        else { targetID = favorite.configurationID }
        guard let targetID, !Task.isCancelled, favoriteOpenGeneration == generation else { return }
        // Configuration activation currently closes Xtream live playback. Make
        // that consequence an explicit native choice rather than a side effect.
        if activeConfigurationRecord?.id != targetID, livePlaybackSourceID?.isXtream == true {
            let alert = NSAlert(); alert.messageText = L10n.string("favorites.source.stop-live", fallback: "Switch Source and Stop Current Live Playback?")
            alert.addButton(withTitle: L10n.string(.commonCancel)); alert.addButton(withTitle: L10n.string("common.continue", fallback: "Continue"))
            guard let window = NSApp.keyWindow else { return }
            let accepted: Bool = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertSecondButtonReturn) } }
            guard accepted, !Task.isCancelled else { return }
        }
        if activeConfigurationRecord?.id != targetID { await activateConfiguration(targetID) }
        guard !Task.isCancelled, favoriteOpenGeneration == generation,
              activeConfigurationRecord?.id == targetID,
              favorites.contains(original) else { return }
        if needsBinding || providers[favorite.siteKey] == nil {
            let options = visibleSites.filter { providers[$0.key] != nil }
            guard !options.isEmpty, let window = NSApp.keyWindow else {
                show(AppError.configuration(L10n.string("favorites.source.unavailable", fallback: "Source unavailable")), title: L10n.string(.sectionFavorites)); return
            }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28)); picker.addItems(withTitles: options.map(\.name))
            if let index = options.firstIndex(where: { $0.key == favorite.siteKey }) { picker.selectItem(at: index) }
            let alert = NSAlert(); alert.messageText = L10n.string("favorites.site.choose", fallback: "Confirm Favorite Provider")
            alert.informativeText = original.title; alert.accessoryView = picker
            alert.addButton(withTitle: L10n.string(.commonCancel)); alert.addButton(withTitle: L10n.string("common.continue", fallback: "Continue"))
            let index: Int? = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertSecondButtonReturn ? picker.indexOfSelectedItem : nil) } }
            guard let index, options.indices.contains(index), !Task.isCancelled, favoriteOpenGeneration == generation else { return }
            favorite.siteKey = options[index].key; needsBinding = true
        }
        guard let configuration = activeConfigurationRecord, let provider = providers[favorite.siteKey] else { return }
        let context = FavoriteSourceContext(configuration: configuration, site: provider.site)
        if !needsBinding, !favorite.sourceFingerprint.isEmpty, favorite.sourceFingerprint != context.fingerprint {
            pendingFavoriteRepairID = original.id
            show(AppError.configuration(L10n.string("favorites.source.changed", fallback: "This source's server or account has changed. Use Confirm Source to verify this favorite again.")), title: L10n.string(.sectionFavorites))
            return
        }
        if needsBinding { pendingFavoriteRepairID = original.id }
        let summary = VideoSummary(siteKey: favorite.siteKey, siteName: provider.site.name, videoID: favorite.videoID,
            title: favorite.title, posterURL: favorite.posterURL, year: favorite.year, categoryName: favorite.categoryName)
        favoriteRecoveryContext = (original, favorite, context, needsBinding)
        await loadDetail(summary, favorite: favorite)
    }

    private func completeFavoriteDetail(_ detail: VideoDetail) async {
        guard let context = favoriteRecoveryContext, detailFavoriteSource == context.source,
              FavoriteSourceContext.matches(detail, favorite: context.expected),
              favorites.contains(context.original) else { return }
        await updateOpenedFavorite(context.original, detail: detail, context: context.source, bind: context.bind)
    }

    private func updateOpenedFavorite(_ original: FavoriteRecord, detail: VideoDetail, context: FavoriteSourceContext, bind: Bool) async {
        guard configurationImportOperationID == nil, let environment else { return }
        let metadata = context.record(detail)
        guard FavoritePersistencePolicy.isValid(metadata) else {
            show(AppError.configuration(L10n.string("favorites.locator.unsafe", fallback: "This provider returned a temporary or credential-bearing locator. It cannot be saved as a durable favorite.")), title: L10n.string(.sectionFavorites)); return
        }
        let previous = favoriteMutationTask
        favoritesRevision &+= 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                self.favorites = try await (bind ? environment.database.bindFavorite(original, to: metadata)
                    : environment.database.refreshFavorite(original, with: metadata))
                if bind { self.pendingFavoriteRepairID = nil }
            } catch { self.show(error, title: L10n.string("favorites.action.failed", fallback: "Favorites Action Failed")) }
            self.favoritesRevision &+= 1
        }
        favoriteMutationTask = task; await task.value
    }

    func cancelFavoriteRepair() { pendingFavoriteRepairID = nil }
    func confirmFavoriteRepair(_ detail: VideoDetail) {
        guard let id = pendingFavoriteRepairID, let original = favorites.first(where: { $0.id == id }),
              let context = detailFavoriteSource, let window = NSApp.keyWindow else { return }
        let alert = NSAlert(); alert.messageText = L10n.string("favorites.repair.confirm", fallback: "Associate This Title with the Saved Favorite?")
        alert.informativeText = original.title + " → " + detail.summary.title + "\n" + context.configurationName + " · " + context.siteName
        alert.addButton(withTitle: L10n.string(.commonCancel)); alert.addButton(withTitle: L10n.string("common.confirm", fallback: "Confirm"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { Task { await self.updateOpenedFavorite(original, detail: detail, context: context, bind: true) } }
        }
    }

    private func acceptsFavoriteDetail(_ detail: VideoDetail) -> Bool {
        guard let expected = detailFavoriteExpectation else { return true }
        guard favorites.contains(where: { $0.id == expected.id }), FavoriteSourceContext.matches(detail, favorite: expected) else {
            selectedDetail = nil
            detailSuggestedSearch = expected.title
            pendingFavoriteRepairID = expected.id
            detailLoadState = .failed(L10n.string("favorites.content.changed", fallback: "The provider returned a different title. The saved favorite is unchanged. Search this source and explicitly associate the correct title."))
            return false
        }
        return true
    }

    /// Handles the UI event synchronously so the native player window command
    /// is issued before configuration switching, provider I/O, or even the
    /// first suspension point of history restoration.
    func requestHistoryPlayback(_ item: HistoryRecord) {
        guard !isShutdownRequested else { return }
        let item = history.first(where: { $0.id == item.id }) ?? item
        let isSameRequest = historyPlaybackRequestedItem?.id == item.id
        let isRecoveringSameRequest = isSameRequest
            && historyPlaybackLoadingID == item.id
            && isCurrentHistoryPreparation(historyPlaybackPreparationID)
        let isShowingSameRequest = isSameRequest
            && isPlayerPresented
            && playbackResolutionState != .failed
            && playbackResolutionState != .exhausted
        if isRecoveringSameRequest || isShowingSameRequest {
            presentPlayer(
                requestID: activePlayerRequestID,
                activation: .userInitiated
            )
            return
        }

        captureHistoryBeforePlaybackTransition()
        historyPlaybackTask?.cancel()
        let preparationID = UUID()
        historyPlaybackPreparationID = preparationID
        historyPlaybackLoadingID = item.id
        historyPlaybackRequestedItem = item
        historyPlaybackChoices = []
        cancelAllPlaybackStartupGates()
        if let configurationID = item.configurationID
            ?? activeConfigurationRecord?.id {
            _ = prepareHistoryPlaybackShell(
                item,
                siteName: historySiteName(for: item),
                configurationID: configurationID,
                requestID: preparationID
            )
        } else {
            playbackSessionID = preparationID
            activePlayerRequestID = preparationID
            pendingPlayback = nil
            activePlayback = nil
            playbackResolutionState = .restoringHistory
            currentPlaybackAttempt = nil
            playbackFailureSummary = nil
            isPlayerRenderSurfaceMountEnabled = false
            playerSnapshot = PlayerSnapshot(
                status: .loading,
                volume: playerSnapshot.volume,
                isMuted: playerSnapshot.isMuted,
                speed: playerSnapshot.speed
            )
        }
        playerPresentedError = nil
        presentPlayer(
            requestID: preparationID,
            activation: .userInitiated
        )
        historyPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreHistoryPlayback(
                item,
                preparationID: preparationID
            )
        }
    }

    var canRetryHistoryPlayback: Bool {
        historyPlaybackRequestedItem != nil
            && isPlayerPresented
            && (playbackResolutionState == .failed
                || playbackResolutionState == .exhausted)
    }

    func retryHistoryPlayback() {
        guard let item = historyPlaybackRequestedItem else { return }
        requestHistoryPlayback(item)
    }

    var canOpenNodeConfigurationForPlaybackFailure: Bool {
        guard let fallback = pendingNodePlaybackConfigurationFallback,
              fallback.operation.playbackRequestID == activePlayerRequestID,
              isPlayerPresented else {
            return false
        }
        return playbackResolutionState == .failed
            || playbackResolutionState == .exhausted
    }

    func openNodeConfigurationForPlaybackFailure() {
        guard canOpenNodeConfigurationForPlaybackFailure,
              let fallback = pendingNodePlaybackConfigurationFallback else {
            return
        }
        pendingNodePlaybackConfigurationFallback = nil
        presentNodeConfiguration(
            fallback.authorization,
            pending: fallback.operation
        )
    }

    func retryNodePlaybackFailure() {
        guard canOpenNodeConfigurationForPlaybackFailure,
              let fallback = pendingNodePlaybackConfigurationFallback,
              case .playback(_, let playback) = fallback.operation else { return }
        pendingNodePlaybackConfigurationFallback = nil
        Task { @MainActor [weak self] in
            guard let self, self.activePlayerRequestID == playback.requestID,
                  self.isPlayerPresented else { return }
            await self.startPlayback(detail: playback.detail, source: playback.source,
                episode: playback.episode, origin: playback.origin,
                configurationID: playback.configurationID,
                recoveryCheckpoint: playback.recoveryCheckpoint)
        }
    }

    var hasHistoryPlaybackChoices: Bool {
        !historyPlaybackChoices.isEmpty
    }

    func chooseHistoryPlayback(_ choiceID: HistoryPlaybackChoice.ID) {
        guard let item = historyPlaybackRequestedItem,
              let choice = historyPlaybackChoices.first(where: {
                $0.id == choiceID
              }),
              isPlayerPresented else { return }
        let preparationID = historyPlaybackPreparationID
        historyPlaybackChoices = []
        historyPlaybackLoadingID = item.id
        playbackFailureSummary = nil
        playbackResolutionState = .restoringHistory
        historyPlaybackTask?.cancel()
        historyPlaybackTask = Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentHistoryPreparation(preparationID) else { return }
            await self.startPlayback(
                detail: choice.detail,
                source: choice.source,
                episode: choice.episode,
                origin: .history(item),
                continuingRequestID: preparationID,
                windowActivation: .preserveFocus
            )
        }
    }

    func cancelHistoryPlaybackChoices() {
        historyPlaybackChoices = []
        let preparationID = historyPlaybackPreparationID
        guard isCurrentHistoryPreparation(preparationID) else { return }
        failHistoryPlayback(
            L10n.string("history.restore.no-selection", fallback: "No stream or episode was selected for restore"),
            preparationID: preparationID
        )
    }

    func returnToHistoryAfterPlaybackFailure() {
        historyPlaybackChoices = []
        selectSection(.history)
        Task { await closePlayer() }
    }

    private func restoreHistoryPlayback(
        _ item: HistoryRecord,
        preparationID: UUID
    ) async {
        var recoveryFailure = L10n.string("history.restore.missing-stable-id", fallback: "Stable cloud file identifier is missing")
        defer {
            if historyPlaybackPreparationID == preparationID {
                historyPlaybackLoadingID = nil
                historyPlaybackTask = nil
            }
        }
        guard !Task.isCancelled,
              isCurrentHistoryPreparation(preparationID) else { return }
        switch Self.historyConfigurationResolution(
            record: item,
            activeConfigurationID: activeConfigurationRecord?.id,
            availableConfigurationIDs: Set(configurations.map(\.id))
        ) {
        case .current:
            break
        case .switchTo(let configurationID):
            await activateConfiguration(configurationID)
            guard !Task.isCancelled,
                  isCurrentHistoryPreparation(preparationID) else { return }
            guard activeConfigurationRecord?.id == configurationID else {
                failHistoryPlayback(
                    L10n.string("history.restore.switch-configuration.failed", fallback: "Unable to switch to the video configuration associated with this history item"),
                    preparationID: preparationID
                )
                return
            }
        case .unavailable:
            failHistoryPlayback(
                L10n.string("history.restore.configuration-deleted", fallback: "The video configuration for this history item was deleted, so its original provider cannot be restored safely"),
                preparationID: preparationID
            )
            return
        case .legacy:
            failHistoryPlayback(
                L10n.string("history.restore.legacy-no-identity", fallback: "This legacy history item has no configuration identity, so its original provider cannot be determined safely"),
                preparationID: preparationID
            )
            return
        }
        let siteName = visibleSites.first { $0.key == item.siteKey }?.name
            ?? item.siteKey
        guard let owningConfigurationID = item.configurationID
            ?? activeConfigurationRecord?.id else {
            failHistoryPlayback(
                L10n.string("history.restore.configuration-unknown", fallback: "Unable to determine the video configuration associated with this history item"),
                preparationID: preparationID
            )
            return
        }
        if await replayRecentHistorySession(
            item,
            owningConfigurationID: owningConfigurationID,
            owningPreparationID: preparationID
        ) {
            return
        }
        guard isCurrentHistoryPreparation(preparationID) else { return }
        guard let provider = providers[item.siteKey] else {
            if await replayCachedHistory(
                item,
                siteName: siteName,
                owningConfigurationID: owningConfigurationID,
                owningPreparationID: preparationID
            ) {
                return
            }
            guard isCurrentHistoryPreparation(preparationID) else { return }
            failHistoryPlayback(
                L10n.string("history.restore.provider-unavailable", fallback: "Provider %@ is unavailable in the current configuration, so playback cannot be restored", siteName),
                preparationID: preparationID
            )
            return
        }

        let acceptedProviderReference = Self.acceptedHistoryProviderReference(
            from: item,
            provider: provider
        )
        if let acceptedProviderReference {
            guard isCurrentHistoryPreparation(preparationID) else { return }
            // Only a provider-attested, credential-free stable resource reaches
            // this path. CatPaw ndr2/nhr2 replay recipes are deliberately
            // rejected and recover through current detail/navigation below.
            var context = Self.historyPlaybackContext(
                record: item,
                siteName: siteName,
                episodeURL: acceptedProviderReference.stableResourceLocator
            )
            context.episode.referenceIdentity = acceptedProviderReference
                .episodeIdentity
            context.episode.providerResourceReference = acceptedProviderReference
            context.source.referenceIdentity = acceptedProviderReference
                .sourceIdentity
            context.source.episodes = [context.episode]
            context.detail.playSources = [context.source]
            await startPlayback(
                detail: context.detail,
                source: context.source,
                episode: context.episode,
                origin: .history(item),
                continuingRequestID: preparationID,
                windowActivation: .preserveFocus
            )
            return
        }

        let recipeDetailID = item.playbackReference?.navigationRecipe.flatMap {
            recipe in
            recipe.configurationID == owningConfigurationID
                && recipe.siteKey == item.siteKey
                ? recipe.detailID.nonEmpty
                : nil
        }
        let storedDetailID = recipeDetailID ?? item.videoID
        if provider is NodeHTTPSpiderSiteProvider,
           NodePlaybackReplayReference.isPersistedOpaqueIdentity(
               storedDetailID
           ) {
            // `cph2` is a row/deduplication identity, never a provider vodID.
            // CatPaw history is navigation-first, so an opaque row identity
            // continues directly to title recovery instead of issuing a
            // guaranteed-invalid detail call.
            recoveryFailure = L10n.string("history.restore.legacy-dedup-only", fallback: "The legacy detail identity can only be used to deduplicate history")
        } else {
            do {
                let detail = try await Self.historyPlaybackDetail(
                    provider: provider,
                    summary: VideoSummary(
                        siteKey: item.siteKey,
                        siteName: siteName,
                        videoID: storedDetailID,
                        title: item.title,
                        posterURL: item.posterURL
                    )
                )
                guard isCurrentHistoryPreparation(preparationID) else { return }

                let selections = Self.historyPlaybackChoices(
                    in: detail,
                    record: item
                )
                if selections.count == 1, let selection = selections.first {
                    await startPlayback(
                        detail: detail,
                        source: selection.source,
                        episode: selection.episode,
                        origin: .history(item),
                        continuingRequestID: preparationID,
                        windowActivation: .preserveFocus
                    )
                    return
                }
                if selections.count > 1 {
                    presentHistoryPlaybackChoices(
                        selections.map {
                            HistoryPlaybackChoice(
                                detail: detail,
                                source: $0.source,
                                episode: $0.episode
                            )
                        },
                        preparationID: preparationID
                    )
                    return
                }

                // A provider may refresh the same episode with a shortened
                // display name or a renamed route. Do not claim that the
                // episode was removed while the durable history reference can
                // still rebuild a valid playback URL below.
                recoveryFailure = L10n.string("history.restore.stream-missing", fallback: "The original stream or episode was not found in the latest details")
            } catch {
                // Search/cloud providers often expose session-scoped video
                // IDs. Continue with the durable episode reference or cached
                // media instead of surfacing a low-level empty-JSON error.
                recoveryFailure = L10n.string("history.restore.detail-id-expired", fallback: "The legacy detail ID is no longer valid")
            }
        }

        let persistedEpisodeReference = provider.capability == .javaDexSpider
            || provider is NodeHTTPSpiderSiteProvider
            ? nil
            : item.episodeReference?.nonEmpty.flatMap {
                Self.persistentHistoryEpisodeReference($0)
            }
        if let episodeReference = persistedEpisodeReference,
           !NodePlaybackReplayReference.isLocator(episodeReference),
           !NodeProviderLocatorReference.isLocator(episodeReference) {
            guard isCurrentHistoryPreparation(preparationID) else { return }
            let context = Self.historyPlaybackContext(
                record: item,
                siteName: siteName,
                episodeURL: episodeReference
            )
            await startPlayback(
                detail: context.detail,
                source: context.source,
                episode: context.episode,
                origin: .history(item),
                continuingRequestID: preparationID,
                windowActivation: .preserveFocus
            )
            return
        }

        if await replayCachedHistory(
            item,
            siteName: siteName,
            owningConfigurationID: owningConfigurationID,
            owningPreparationID: preparationID
        ) {
            return
        }
        guard isCurrentHistoryPreparation(preparationID) else { return }

        do {
            let page = try await provider.search(
                keyword: Self.historySearchQuery(for: item.title) ?? item.title,
                page: 1,
                quick: false
            )
            let candidates = Self.historySearchCandidates(
                in: page.items,
                record: item
            )
            var resolved: [HistoryPlaybackChoice] = []
            for summary in candidates.prefix(12) {
                guard let detail = try? await Self.historyPlaybackDetail(
                    provider: provider,
                    summary: summary
                ) else {
                    continue
                }
                let selections = Self.historyPlaybackChoices(
                    in: detail,
                    record: item
                )
                resolved.append(contentsOf: selections.map {
                    HistoryPlaybackChoice(
                        detail: detail,
                        source: $0.source,
                        episode: $0.episode
                    )
                })
            }
            guard isCurrentHistoryPreparation(preparationID) else { return }
            if resolved.count == 1, let match = resolved.first {
                await startPlayback(
                    detail: match.detail,
                    source: match.source,
                    episode: match.episode,
                    origin: .history(item),
                    continuingRequestID: preparationID,
                    windowActivation: .preserveFocus
                )
                return
            }
            if resolved.count > 1 {
                presentHistoryPlaybackChoices(
                    Array(resolved.prefix(12)),
                    preparationID: preparationID
                )
                return
            }
            if candidates.count > 1 {
                recoveryFailure = L10n.string("history.restore.ambiguous", fallback: "Multiple results with the same title were found, but none uniquely matches the original stream and episode")
            } else if candidates.isEmpty {
                recoveryFailure += L10n.string("history.restore.search-no-title.suffix", fallback: "; a new search did not find the same title")
            } else {
                recoveryFailure = L10n.string("history.restore.title-found-stream-missing", fallback: "Content with the same title was found, but the original stream or episode did not match")
            }
        } catch {
            // A search retry is best effort. Present one actionable history
            // message below instead of a second provider decoding error.
            recoveryFailure += L10n.string("history.restore.search-failed.suffix", fallback: "; the new search failed")
        }

        guard isCurrentHistoryPreparation(preparationID) else { return }
        failHistoryPlayback(
            L10n.string("history.restore.reselect", fallback: "%@. Choose again.", recoveryFailure),
            preparationID: preparationID
        )
    }

    private func failHistoryPlayback(
        _ message: String,
        preparationID: UUID
    ) {
        guard isCurrentHistoryPreparation(preparationID),
              activePlayerRequestID == preparationID else { return }
        let redactedMessage = LogRedactor.text(message)
        playbackResolutionState = .failed
        playbackFailureSummary = redactedMessage
        playerSnapshot.status = .failed(redactedMessage)
        playerPresentedError = nil
    }

    /// CatPaw detail payloads may omit `vod_id` while still returning a valid
    /// title and complete play list. Normal navigation carries its discovery
    /// summary into `select(summary:)`, which supplies that missing identity;
    /// history must preserve the same contract. Other provider types keep their
    /// existing `detail(id:)` path unchanged.
    static func historyPlaybackDetail(
        provider: any SiteProvider,
        summary: VideoSummary
    ) async throws -> VideoDetail {
        guard let nodeProvider = provider as? NodeHTTPSpiderSiteProvider else {
            return try await provider.detail(id: summary.videoID)
        }
        switch try await nodeProvider.select(summary: summary) {
        case .detail(let detail):
            return detail
        case .action:
            throw AppError.spider(L10n.string("history.restore.catpaw-action", fallback: "CatPaw history returned a settings action instead of media details"))
        case .search:
            throw AppError.contentUnavailable(L10n.string("history.restore.catpaw-no-details", fallback: "CatPaw history did not return playable details"))
        }
    }

    private func presentHistoryPlaybackChoices(
        _ choices: [HistoryPlaybackChoice],
        preparationID: UUID
    ) {
        guard isCurrentHistoryPreparation(preparationID),
              activePlayerRequestID == preparationID,
              !choices.isEmpty else { return }
        var seen = Set<String>()
        historyPlaybackChoices = choices.filter { choice in
            seen.insert(
                [
                    choice.detail.summary.siteKey,
                    choice.detail.summary.videoID,
                    choice.source.stableIdentity,
                    choice.episode.stableIdentity
                ].joined(separator: "|")
            ).inserted
        }
        playbackResolutionState = .restoringHistory
        playbackFailureSummary = L10n.string("history.restore.choose-candidate", fallback: "Multiple possible original streams or episodes were found. Choose one; this history item will be repaired automatically after playback succeeds.")
        playerSnapshot.status = .loading
        playerPresentedError = nil
    }

    private func replayRecentHistorySession(
        _ item: HistoryRecord,
        owningConfigurationID: UUID,
        owningPreparationID: UUID
    ) async -> Bool {
        guard let environment,
              let replay = historyPlaybackSessionCache.playback(
                for: item.id
              ),
              replay.configurationID == owningConfigurationID,
              Self.historyContentMatches(replay.detail, record: item),
              Self.historyRecord(item, matches: replay.source, episode: replay.episode) else {
            return false
        }
        guard isCurrentHistoryPreparation(owningPreparationID) else {
            return false
        }
        let sessionID = prepareHistoryPlaybackShell(
            item,
            siteName: replay.detail.summary.siteName,
            configurationID: owningConfigurationID,
            requestID: owningPreparationID
        )
        do {
            guard activePlayerRequestID == sessionID,
                  playbackSessionID == sessionID else { return false }
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            isPlayerRenderSurfaceMountEnabled = true
            await environment.player.stop(ifOwnedBy: sessionID)
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            // Admission to this cache requires an explicit immutable-resource
            // contract (or a local file). Mutable cloud sessions refresh below.
            try await loadResolvedPlayback(
                replay.media,
                detail: replay.detail,
                source: replay.source,
                episode: replay.episode,
                playbackResult: replay.playbackResult,
                configurationID: owningConfigurationID,
                providerResourceReference: replay.providerResourceReference,
                sessionID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            playbackResolutionState = .playing
            playbackFailureSummary = nil
            return true
        } catch {
            historyPlaybackSessionCache.remove(item.id)
            if playbackSessionID == sessionID {
                isPlayerRenderSurfaceMountEnabled = false
            }
            return false
        }
    }

    private func replayCachedHistory(
        _ item: HistoryRecord,
        siteName: String,
        owningConfigurationID: UUID,
        owningPreparationID: UUID
    ) async -> Bool {
        guard let environment,
              let replay = Self.replayableHistoryPlayback(
                record: item,
                siteName: siteName
              ) else {
            return false
        }
        let probe = DefaultMediaProbe(
            httpClient: configuredHTTPClient(environment: environment)
        )
        guard (try? await probe.validate(
            url: replay.media.url,
            headers: replay.media.headers
        )) == true else {
            return false
        }
        guard isCurrentHistoryPreparation(owningPreparationID) else {
            return false
        }
        // The player shell is already visible while the cached media is
        // validated. Mount the render surface only after the player engine is
        // ready, matching the detail/provider recovery path.
        let sessionID = prepareHistoryPlaybackShell(
            item,
            siteName: siteName,
            configurationID: owningConfigurationID,
            requestID: owningPreparationID
        )
        do {
            guard activePlayerRequestID == sessionID,
                  playbackSessionID == sessionID else { return false }
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            isPlayerRenderSurfaceMountEnabled = true
            await environment.player.stop(ifOwnedBy: sessionID)
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            try await loadResolvedPlayback(
                replay.media,
                detail: replay.detail,
                source: replay.source,
                episode: replay.episode,
                configurationID: owningConfigurationID,
                sessionID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            playbackResolutionState = .playing
            playbackFailureSummary = nil
            return true
        } catch {
            if playbackSessionID == sessionID {
                isPlayerRenderSurfaceMountEnabled = false
            }
            return false
        }
    }

    private func prepareHistoryPlaybackShell(
        _ item: HistoryRecord,
        siteName: String,
        configurationID: UUID,
        requestID: UUID
    ) -> UUID {
        clearPlayerEpisodeListRecovery()
        let preparationID = requestID
        historyProgressCheckpoint.reset(owner: preparationID)
        playbackSessionID = preparationID
        activePlayerRequestID = preparationID
        playbackQualitySwitchSessionID = UUID()
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        // A transferred Quark file remains leased to the currently loaded
        // mpv media until the replacement reaches file-loaded. Keep its
        // playback context authoritative while the next episode resolves so
        // a failed B request leaves A usable instead of presenting an empty
        // playback state over media that is still playing.
        if transferMediaLeases.isEmpty {
            activePlayback = nil
        }
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        livePlaybackNavigationContext = nil
        detailRouteSummary = nil
        selectedDetail = nil
        pendingDetailSummary = nil

        let context = Self.historyPlaybackContext(
            record: item,
            siteName: siteName,
            episodeURL: "history-pending://\(preparationID.uuidString.lowercased())"
        )
        pendingPlayback = PendingCloudPlayback(
            requestID: preparationID,
            configurationID: configurationID,
            detail: context.detail,
            source: context.source,
            episode: context.episode,
            origin: .history(item)
        )
        playerEpisodePreparationTask?.cancel()
        playerEpisodePresentations = []
        playerEpisodePresentationCache = nil
        isPlayerEpisodeListPreparing = true
        playbackResolutionState = .restoringHistory
        currentPlaybackAttempt = nil
        playbackFailureSummary = nil
        isPlayerRenderSurfaceMountEnabled = false
        playerSnapshot = PlayerSnapshot(
            status: .loading,
            volume: playerSnapshot.volume,
            isMuted: playerSnapshot.isMuted,
            speed: playerSnapshot.speed
        )
        return preparationID
    }

    private func isCurrentHistoryPreparation(_ preparationID: UUID) -> Bool {
        historyPlaybackPreparationID == preparationID
    }

    func dismissDetail(restoringSearch: Bool = true) {
        favoriteOpenGeneration = UUID(); favoriteOpenTask?.cancel(); favoriteLoadingID = nil
        detailFavoriteExpectation = nil
        detailFavoriteSource = nil
        favoriteRecoveryContext = nil
        let searchReturnSnapshot = detailHomeSearchReturnSnapshot
        detailHomeSearchReturnSnapshot = nil
        cancelDetailRequest()
        activeDetailPerformanceTrace = nil
        detailRouteSummary = nil
        selectedDetail = nil
        pendingDetailSummary = nil
        if restoringSearch, let searchReturnSnapshot {
            selectedSection = .home
            selectedSearchSiteKey = searchReturnSnapshot.selectedSiteKey
            searchFolderPath = searchReturnSnapshot.folderPath
            searchFolderOrigin = searchReturnSnapshot.folderOrigin
            isHomeSearchPresented = true
        }
    }

    func recordDetailFirstRender(_ detail: VideoDetail) {
        guard let trace = activeDetailPerformanceTrace,
              selectedDetail == detail,
              trace.siteKey == detail.summary.siteKey else { return }
        trace.finishFirstRender()
        activeDetailPerformanceTrace = nil
    }

    func search(_ keyword: String) {
        discoverySearchReturnSnapshot = nil
        search(keyword, context: .manual)
    }

    private func search(
        _ keyword: String,
        context: SearchLaunchContext
    ) {
        let normalized = keyword.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeConfigurationUsesNodeRuntime, isSearching,
           activeSearchKeyword == normalized, activeSearchContext == context,
           activeSearchScope == searchSiteScope { return }
        activeSearchContext = context
        activeSearchScope = searchSiteScope
        if isSearching {
            previousSearchTermination = .supersededByNewSearch
        }
        searchTask?.cancel()
        let sessionID = searchSessionGate.begin()
        searchBrowseSessionID = sessionID
        searchContinuationTask?.cancel()
        searchContinuationTask = nil
        searchPaging = SearchPagingState()
        searchBrowseMemory.reset()
        searchResults = []
        searchFailures = []
        searchSiteOutcomes = [:]
        searchFirstPageCompletedSiteCount = 0
        searchCompletedSiteCount = 0
        searchTotalSiteCount = 0
        searchReceivedCandidateCount = 0
        searchMaximumRetainedCandidates = .max
        searchMaximumResultsPerSite = .max
        searchDidDiscardCandidates = false
        searchTermination = nil
        isSearching = false
        activeSearchSiteKeys = []
        selectedSearchSiteKey = nil
        searchFolderPath = []
        searchFolderOrigin = nil
        // Preserve meaningful punctuation exactly as FongMi does. NFC
        // normalization only removes equivalent Unicode spellings that can
        // otherwise produce different URL/JSON payloads for the same text.
        let trimmed = keyword
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchKeyword = trimmed
        searchDraftKeyword = trimmed
        guard !trimmed.isEmpty else { return }

        // Profile revisions refresh `/config` and `/full-config` in the
        // background. Keep catalogue maintenance off the foreground search
        // path so an optional/older `/full-config` endpoint can never add a
        // multi-second delay before the first provider request is submitted.
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled,
                  self.searchSessionGate.accepts(sessionID) else { return }
            await self.executeSearch(
                keyword: trimmed,
                context: context,
                sessionID: sessionID
            )
        }
    }

    private func executeSearch(
        keyword: String,
        context: SearchLaunchContext,
        sessionID: UUID,
        refreshKeys: Set<String>? = nil,
        retainedResults: [VideoSummary] = []
    ) async {
        let selectedKeys = refreshKeys ?? SearchProviderSelectionPolicy.effectiveSiteKeys(
            context: context,
            scope: searchSiteScope,
            options: searchScopeSiteOptions
        )
        if context.usesConfiguredScope,
           searchSiteScope.mode == .custom,
           selectedKeys.isEmpty {
            show(
                AppError.configuration(L10n.string("search.scope.no-available-providers", fallback: "The current custom search scope has no available providers. Choose again.")),
                title: L10n.string("search.scope.unavailable", fallback: "Search Scope Unavailable")
            )
            isSearching = false
            searchTask = nil
            return
        }
        // CatPawOpen metadata is not reliable enough to decide whether a
        // registered route can search. In particular, utility-looking sites
        // and older bundles may report `searchable == 0` even though their
        // route accepts a normal search request. Schedule every selected,
        // runnable provider and let the request's exact outcome decide.
        var searchableProviders: [SiteProvider] = searchCatalogSites.compactMap { site in
            guard selectedKeys.contains(site.key) else { return nil }
            return providers[site.key]
        }
        // Reorder only CatPaw slots. Every selected site still gets a first-page
        // attempt, including unknown and previously slow providers.
        var nodeOrder = searchableProviders.enumerated().compactMap { index, provider -> (Int, NodeHTTPSpiderSiteProvider)? in
            (provider as? NodeHTTPSpiderSiteProvider).map { (index, $0) }
        }.sorted {
            let a = $0.1.aggregateSearchPriority, b = $1.1.aggregateSearchPriority
            return a == b ? $0.0 < $1.0 : a < b
        }.map(\.1).makeIterator()
        searchableProviders = searchableProviders.map { $0 is NodeHTTPSpiderSiteProvider ? (nodeOrder.next()! as SiteProvider) : $0 }
        if refreshKeys == nil { searchPaging.order = searchableProviders.map { $0.site.key } }
        for provider in searchableProviders {
            let key = provider.site.key
            if !searchPaging.order.contains(key) { searchPaging.order.append(key) }
            searchPaging.cursors[key] = SearchPageCursor(keyword: keyword)
            if provider is NodeHTTPSpiderSiteProvider { searchPaging.restricted.insert(key) }
            else { searchPaging.restricted.remove(key) }
        }
        activeSearchSiteKeys = Set(searchableProviders.map { $0.site.key })
        searchTotalSiteCount = searchableProviders.count
        isSearching = !searchableProviders.isEmpty
        guard !searchableProviders.isEmpty else {
            searchTermination = .completed
            searchTask = nil
            return
        }
        let aggregatePolicies: [String: MultiSiteSearchProviderPolicy] = Dictionary(
            uniqueKeysWithValues: searchableProviders.compactMap {
                provider -> (String, MultiSiteSearchProviderPolicy)? in
                guard provider is NodeHTTPSpiderSiteProvider else { return nil }
                return (
                    provider.site.key,
                    MultiSiteSearchProviderPolicy(
                        concurrencyGroup: "node-http-runtime",
                        maximumGroupConcurrency: 20,
                        maximumPagesPerSite: 1
                    )
                )
            }
        )
        let stream = MultiSiteSearch(maximumConcurrency: 20).search(
            providers: searchableProviders,
            keyword: keyword,
            providerPolicies: aggregatePolicies,
            onPage: { [weak self] progress in
                await self?.recordSearchPage(progress, sessionID: sessionID)
            }
        )
        var firstPageCompletedSiteKeys = Set<String>()
        var completedSiteKeys = Set<String>()
        var successfulRefreshKeys = Set<String>()
        var latestRefreshItems: [VideoSummary] = []

        let applySnapshot: (MultiSiteSearchSnapshot) -> Void = { [weak self] snapshot in
            guard let self,
                  self.searchSessionGate.accepts(sessionID) else { return }
            // MultiSiteSearch is the semantic owner of relevance, retention,
            // eviction and per-site diversity. AppState only publishes its
            // authoritative retained snapshot.
            latestRefreshItems = snapshot.items
            self.searchResults = refreshKeys == nil ? snapshot.items : SearchRefreshSnapshot.merge(
                retained: retainedResults, incoming: snapshot.items, successfulKeys: successfulRefreshKeys)
            self.searchReceivedCandidateCount = snapshot.receivedCandidateCount
            self.searchMaximumRetainedCandidates = snapshot.maximumRetainedCandidates
            self.searchMaximumResultsPerSite = snapshot.maximumResultsPerSite
            self.searchDidDiscardCandidates = snapshot.didDiscardCandidates
        }
        let snapshotPublisher = SearchSnapshotPublisher(publish: applySnapshot)
        defer { snapshotPublisher.cancel() }

        for await event in stream {
            guard searchSessionGate.accepts(sessionID) else { return }
            switch event {
            case .snapshot(let snapshot):
                latestRefreshItems = snapshot.items
                snapshotPublisher.submit(snapshot)
            case .failure(let failure):
                searchFailures.append(failure)
                searchPaging.cursors[failure.siteKey]?.fail(failure.message, uncertain: failure.isPaginationUncertain)
            case .siteOutcome(let outcome):
                searchSiteOutcomes[outcome.siteKey] = outcome
                if refreshKeys != nil, case .success = outcome {
                    successfulRefreshKeys.insert(outcome.siteKey)
                    searchResults = SearchRefreshSnapshot.merge(retained: retainedResults,
                        incoming: latestRefreshItems, successfulKeys: successfulRefreshKeys)
                }
            case .siteFirstPageCompleted(let siteKey):
                if firstPageCompletedSiteKeys.insert(siteKey).inserted {
                    searchFirstPageCompletedSiteCount = firstPageCompletedSiteKeys.count
                }
            case .siteCompleted(let siteKey):
                if completedSiteKeys.insert(siteKey).inserted {
                    searchCompletedSiteCount = completedSiteKeys.count
                }
            case .finished(let termination):
                snapshotPublisher.flush()
                searchTermination = termination
                isSearching = false
            }
        }
        if searchSessionGate.accepts(sessionID) {
            snapshotPublisher.flush()
            isSearching = false
            searchTask = nil
            if let selected = selectedSearchSiteKey,
               !searchResults.contains(where: { $0.siteKey == selected }) {
                selectedSearchSiteKey = nil
            }
        }
    }

    func presentHomeSearch(returnSection: AppSection? = nil) {
        if !isHomeSearchPresented {
            let origin = returnSection ?? selectedSection
            homeSearchReturnSection = origin
        }
        if selectedSection == .home {
            captureHomeBrowsingSnapshotIfValid()
        }
        selectedSection = .home
        isHomeSearchPresented = true
    }

    func focusGlobalSearch() {
        globalSearchFocusRequest &+= 1
    }

    func searchFromHome(_ keyword: String) {
        searchFromSidebar(keyword)
    }

    func searchFromSidebar(_ keyword: String) {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let returnSection = isHomeSearchPresented
            ? (homeSearchReturnSection ?? .home)
            : selectedSection
        // Details take precedence over the search page. Dismiss first to
        // invalidate pending provider work and consume its old return snapshot
        // before the new search resets filters and results.
        if isDetailPagePresented {
            dismissDetail()
        }
        presentHomeSearch(returnSection: returnSection)
        search(keyword)
    }

    func returnFromSearchToHome() {
        dismissHomeSearch(returningTo: .home)
    }

    func returnFromSearchToOrigin() {
        dismissHomeSearch(returningTo: homeSearchReturnSection ?? .home)
    }

    func clearGlobalVideoSearch() {
        if isHomeSearchPresented {
            returnFromSearchToOrigin()
        } else {
            searchDraftKeyword = ""
            activeSearchKeyword = ""
        }
    }

    private func dismissHomeSearch(returningTo section: AppSection) {
        if isDetailPagePresented {
            dismissDetail(restoringSearch: false)
        }
        discoverySearchReturnSnapshot = nil
        cancelSearch()
        searchDraftKeyword = ""
        activeSearchKeyword = ""
        searchFolderPath = []
        searchFolderOrigin = nil
        selectedSearchSiteKey = nil
        isHomeSearchPresented = false
        homeSearchReturnSection = nil
        selectedSection = section
        if section == .home {
            scheduleHomeResume()
        }
    }

    func selectSection(_ section: AppSection) {
        if section != .live, liveGuideOwner != nil { clearLiveGuideDemand() }
        if isDetailPagePresented {
            dismissDetail(restoringSearch: false)
        }
        if isHomeSearchPresented {
            dismissHomeSearch(returningTo: section)
            return
        }
        if selectedSection == .home, section != .home {
            captureHomeBrowsingSnapshotIfValid()
        }
        selectedSection = section
        if section == .home {
            scheduleHomeResume()
        }
    }

    var shortcutWindowContext: ShortcutWindowContext {
        ShortcutRoutePolicy.context(
            browserWindowIsKey: isBrowserWindowKey,
            playerWindowIsKey: isPlayerWindowKey
        )
    }

    var allowsBrowserShortcuts: Bool {
        ShortcutRoutePolicy.allowsBrowserCommands(
            browserWindowIsKey: isBrowserWindowKey,
            playerWindowIsKey: isPlayerWindowKey
        )
    }

    var allowsPlayerShortcuts: Bool {
        isPlayerPresented
            && ShortcutRoutePolicy.allowsPlayerCommands(
                browserWindowIsKey: isBrowserWindowKey,
                playerWindowIsKey: isPlayerWindowKey
            )
    }

    func setBrowserWindowKey(_ isKey: Bool) {
        isBrowserWindowKey = isKey
    }

    func setPlayerWindowKey(_ isKey: Bool) {
        isPlayerWindowKey = isKey
    }

    func restoreDefaultWindowLayout(_ target: AppWindowLayoutTarget) {
        appWindowLayoutCommand = AppWindowLayoutCommand(target: target)
    }

    func setPlayerWindowMode(_ mode: PlayerWindowMode) {
        playerWindowPreferences.setMode(mode)
    }

    func presentQuickSwitcher() {
        guard allowsBrowserShortcuts,
              cloudAuthorizationPrompt == nil,
              nodeWebPresentation == nil,
              !isDetailPagePresented else { return }
        isShortcutHelpPresented = false
        isQuickSwitcherPresented = true
    }

    func dismissQuickSwitcher() {
        isQuickSwitcherPresented = false
    }

    func presentShortcutHelp() {
        guard allowsBrowserShortcuts,
              cloudAuthorizationPrompt == nil,
              nodeWebPresentation == nil,
              !isDetailPagePresented else { return }
        isQuickSwitcherPresented = false
        isShortcutHelpPresented = true
    }

    func dismissShortcutHelp() {
        isShortcutHelpPresented = false
    }

    func requestLiveSourceSelection(_ sourceID: UUID) {
        requestLiveSourceSelection(.imported(sourceID))
    }

    func requestLiveSourceSelection(_ sourceID: LiveSourceID) {
        shortcutLiveSourceSelection = ShortcutLiveSourceSelection(
            requestID: UUID(),
            sourceID: sourceID
        )
        selectSection(.live)
    }

    func requestPlayerEscapeHandling() {
        guard allowsPlayerShortcuts else { return }
        shortcutPlayerEscapeRequest &+= 1
    }

    @discardableResult
    func performSearchBackAction() -> Bool {
        guard isHomeSearchPresented else { return false }
        let action = BrowserEscapeRoutePolicy.action(
            isHomeSearchPresented: true,
            isSearching: isSearching || searchPaging.loading,
            hasSearchFolder: !searchFolderPath.isEmpty,
            hasDetailPresentation: isDetailPagePresented,
            hasBlockingPresentation: mainWindowCloudAuthorizationPrompt != nil
                || nodeWebPresentation != nil
                || isQuickSwitcherPresented
                || isShortcutHelpPresented
        )
        return performBrowserBackAction(action)
    }

    @discardableResult
    func performBrowserEscapeShortcut() -> Bool {
        guard allowsBrowserShortcuts else { return false }
        if isHomeSearchPresented {
            return performSearchBackAction()
        }
        let action = BrowserEscapeRoutePolicy.action(
            isHomeSearchPresented: isHomeSearchPresented,
            isSearching: isSearching || searchPaging.loading,
            hasSearchFolder: !searchFolderPath.isEmpty,
            hasDetailPresentation: isDetailPagePresented,
            hasBlockingPresentation: mainWindowCloudAuthorizationPrompt != nil
                || nodeWebPresentation != nil
                || isQuickSwitcherPresented
                || isShortcutHelpPresented
        )
        return performBrowserBackAction(action)
    }

    @discardableResult
    private func performBrowserBackAction(
        _ action: BrowserEscapeAction
    ) -> Bool {
        switch action {
        case .none:
            return false
        case .dismissDetail:
            dismissDetail()
        case .navigateBackFolder:
            navigateBackHomeSearch()
        case .stopSearch:
            cancelSearch()
        case .returnHome:
            returnFromSearchToOrigin()
        }
        return true
    }

    func togglePlayerFullScreen() {
        guard isPlayerPresented else { return }
        issuePlayerWindowCommand(
            .toggleFullScreen,
            requestID: activePlayerRequestID
        )
    }

    func ownsPlayerWindowRequest(_ requestID: UUID) -> Bool {
        isPlayerPresented && activePlayerRequestID == requestID
    }

    func performContextRefresh() async {
        guard allowsBrowserShortcuts else { return }
        if isDetailPagePresented {
            await refreshDetail()
            return
        }
        switch selectedSection {
        case .home:
            if isHomeSearchPresented {
                await refreshSearchPage()
            } else {
                await refreshHomePage()
            }
        case .live:
            shortcutLiveRefreshRequest &+= 1
        case .favorites, .history, .settings:
            // These screens are backed by local observable state and update
            // as soon as their stores change. There is no remote page request
            // to repeat, so Command-R intentionally remains a no-op.
            break
        }
    }

    func performBackShortcut() async {
        guard allowsBrowserShortcuts else { return }
        if cloudAuthorizationPrompt != nil {
            await cancelCloudAuthorization()
        } else if nodeWebPresentation != nil {
            cancelNodeConfiguration()
        } else if isHomeSearchPresented {
            _ = performSearchBackAction()
        } else if isDetailPagePresented {
            dismissDetail()
        } else if !searchFolderPath.isEmpty {
            navigateBackHomeSearch()
        } else if selectedSection != .home {
            selectSection(.home)
        }
    }

    func stopCurrentShortcutOperation() {
        guard allowsBrowserShortcuts else { return }
        if isSearching || searchPaging.loading {
            cancelSearch()
        }
    }

    func cancelSearch() {
        let wasSearching = isSearching || searchPaging.loading
        searchPaging.stopped = true
        searchPaging.loading = false
        searchContinuationTask?.cancel()
        searchContinuationTask = nil
        if wasSearching {
            searchTermination = .cancelled
        }
        searchSessionGate.invalidate()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

#if DEBUG || OKVIDEO_PERFORMANCE_TEST
    func seedSearchResultsForTesting(_ results: [VideoSummary]) {
        searchResults = results
    }
    func seedSearchPagingForTesting(_ cursors: [String: SearchPageCursor], order: [String]) {
        searchPaging.cursors = cursors
        searchPaging.order = order
        activeSearchSiteKeys = Set(order)
    }
#endif

    func saveSearchSiteScope(_ scope: SearchSiteScope) async -> Bool {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id else {
            show(
                AppError.configuration(L10n.string("configuration.import-enable-first", fallback: "Import and enable a video provider configuration first.")),
                title: L10n.string("search.scope.save.failed", fallback: "Unable to Save Search Scope")
            )
            return false
        }
        let effectiveKeys = SearchSiteScopePolicy.effectiveSiteKeys(
            scope: scope,
            options: searchScopeSiteOptions
        )
        if scope.mode == .custom, effectiveKeys.isEmpty {
            show(
                AppError.configuration(L10n.string("search.scope.minimum-one", fallback: "A custom search scope requires at least one currently available provider.")),
                title: L10n.string("search.scope.save.failed", fallback: "Unable to Save Search Scope")
            )
            return false
        }
        do {
            try await environment.database.setSetting(
                scope.settingValue(
                    configurationFingerprint: SearchConfigurationFingerprint.make(
                        sites: activeConfiguration?.sites ?? []
                    )
                ),
                forKey: Self.searchScopeSettingKey(for: configurationID)
            )
            guard activeConfigurationRecord?.id == configurationID else {
                return true
            }
            searchSiteScope = scope
            return true
        } catch {
            show(error, title: L10n.string("search.scope.save.failed", fallback: "Unable to Save Search Scope"))
            return false
        }
    }

    private func recordSearchPage(_ progress: SearchPageProgress, sessionID: UUID) {
        guard searchSessionGate.accepts(sessionID) else { return }
        var cursor = searchPaging.cursors[progress.siteKey] ?? SearchPageCursor(keyword: progress.keyword)
        cursor.keyword = progress.keyword
        cursor.accept(progress.page, requestedPage: progress.requestedPage)
        searchPaging.cursors[progress.siteKey] = cursor
        // A declared next page is evidence of support. Unknown Node pagination
        // retains its compatibility cap instead of probing a script blindly.
        if progress.page.pagination.continuation == .more ||
            progress.page.pagination.pageCount.map({ $0 > progress.requestedPage }) == true {
            searchPaging.restricted.remove(progress.siteKey)
        }
    }

    var searchPageIsLoading: Bool {
        currentSearchFolder?.isLoading ?? (isSearching || searchPaging.loading)
    }

    var searchPageError: String? {
        if let folder = currentSearchFolder { return folder.errorMessage }
        let keys = Set(searchPaging.keys(selected: selectedSearchSiteKey))
        let messages = searchFailures.filter { keys.contains($0.siteKey) }
            .map { "\($0.siteName): \($0.message)" }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    var searchRefreshTitle: String {
        if currentSearchFolder?.errorMessage != nil || searchPaging.keys(selected: selectedSearchSiteKey).contains(where: {
            searchPaging.cursors[$0]?.error != nil || searchPaging.cursors[$0]?.uncertain == true
        }) { return L10n.string("browser.refresh.retry", fallback: "Retry Failed Requests") }
        if searchPaging.stopped || searchPaging.manualContinuation {
            return L10n.string("browser.refresh.resume", fallback: "Continue Search")
        }
        return L10n.string("common.refresh", fallback: "Refresh")
    }

    func refreshSearchPage(force: Bool = false) async {
        guard !searchPageIsLoading else { return }
        catPawSearchMemory.invalidate()
        searchBrowseMemory.acceptPendingOrders()
        if let folder = currentSearchFolder {
            if let failedPage = folder.failedPage, failedPage > 1, folder.pagination?.hasMore == true {
                _ = await loadNextSearchFolderPageAndWait()
            } else { retryCurrentSearchFolder() }
            return
        }
        let eligible = searchPaging.eligible(selected: selectedSearchSiteKey, retry: true)
        if !force, eligible.contains(where: {
            searchPaging.cursors[$0]?.error != nil || searchPaging.cursors[$0]?.uncertain == true
        }) {
            _ = await loadMoreSearchResults(retry: true, failuresOnly: true)
            return
        }
        if !force, (searchPaging.stopped || searchPaging.manualContinuation), !eligible.isEmpty {
            _ = await loadMoreSearchResults(retry: true)
            return
        }
        let keys = selectedSearchSiteKey.map { Set([$0]) } ?? Set(searchPaging.order)
        guard !keys.isEmpty else { search(activeSearchKeyword); return }
        let retained = searchResults
        let sessionID = searchSessionGate.begin()
        searchPaging.stopped = false
        searchPaging.manualContinuation = false
        searchFailures.removeAll { keys.contains($0.siteKey) }
        searchFirstPageCompletedSiteCount = 0
        searchCompletedSiteCount = 0
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.executeSearch(keyword: self.activeSearchKeyword, context: .manual,
                sessionID: sessionID, refreshKeys: keys, retainedResults: retained)
        }
        await searchTask?.value
    }

    var searchPaginationFooter: PosterNativeFooterKey {
        let keys = searchPaging.keys(selected: selectedSearchSiteKey)
        let cursors = keys.compactMap { searchPaging.cursors[$0] }
        let ready = searchPaging.eligible(selected: selectedSearchSiteKey, retry: false)
        let retry = searchPaging.eligible(selected: selectedSearchSiteKey, retry: true)
        let busy = isSearching || searchPaging.loading
        let stopped = searchPaging.stopped || searchPaging.manualContinuation
        let uncertain = cursors.contains { $0.uncertain }
        let failed = cursors.contains { $0.error != nil }
        let restricted = keys.contains { searchPaging.restricted.contains($0) && searchPaging.cursors[$0]?.ended != true }
        let text: String
        if busy {
            text = searchResults.isEmpty
                ? L10n.string("search.browse.loading", fallback: "Searching for more results…")
                : L10n.string("search.browse.waiting-providers", fallback: "Results are ready; some providers are still searching…")
        }
        else if searchPaging.stopped { text = L10n.string("search.browse.stopped", fallback: "Search stopped; results retained") }
        else if searchPaging.manualContinuation { text = L10n.string("search.browse.paused", fallback: "More sources found; continue loading when ready") }
        else if !ready.isEmpty {
            text = failed || uncertain
                ? L10n.string("search.browse.partial", fallback: "Some providers need attention; other results can continue")
                : L10n.string("search.browse.continue", fallback: "More results are available")
        } else if uncertain { text = L10n.string("pagination.uncertain", fallback: "No new titles; the end of results is not confirmed") }
        else if failed { text = L10n.string("search.browse.failed", fallback: "Some providers failed; results retained") }
        else if restricted { text = L10n.string("search.browse.limited", fallback: "Further paging is not confirmed for this provider") }
        else if !cursors.isEmpty && cursors.allSatisfy({ $0.ended }) {
            text = L10n.string("search.browse.complete", fallback: "All results in this scope have loaded")
        } else { text = L10n.string("search.browse.pending", fallback: "No further page has been confirmed") }
        let details = keys.compactMap { key -> String? in
            guard let message = searchPaging.cursors[key]?.error else { return nil }
            return "\(providers[key]?.site.name ?? key): \(message)"
        }.joined(separator: "\n")
        return PosterNativeFooterKey(hasMore: !retry.isEmpty, isLoading: busy, isRefreshing: false,
            errorMessage: details.isEmpty ? nil : details, itemCount: searchResults.count, hasPendingUpdate: false,
            statusText: text,
            actionTitle: retry.isEmpty ? nil : L10n.string("search.browse.resume", fallback: "Continue / Retry"),
            automaticLoading: !busy && !stopped && !ready.isEmpty)
    }

    func loadMoreSearchResults(retry: Bool = false, failuresOnly: Bool = false) async -> Bool {
        guard retry || (!searchPaging.stopped && !searchPaging.manualContinuation) else { return false }
        guard !isSearching, !searchPaging.loading, searchContinuationTask == nil else { return false }
        let sessionID = searchSessionGate.currentID
        let selected = selectedSearchSiteKey
        let eligible = searchPaging.eligible(selected: selected, retry: retry)
        let keys = failuresOnly
            ? eligible.filter { searchPaging.cursors[$0]?.error != nil || searchPaging.cursors[$0]?.uncertain == true }
            : Array(eligible.prefix(3))
        guard !keys.isEmpty else { return false }
        searchPaging.loading = true
        searchPaging.stopped = false
        searchPaging.manualContinuation = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let before = Set(self.searchClusters.map(\.id))
            var advanced = false
            for key in keys {
                guard !Task.isCancelled, self.searchSessionGate.accepts(sessionID),
                      let provider = self.providers[key], var cursor = self.searchPaging.cursors[key] else { break }
                let requestedPage = cursor.nextPage
                let result = await MultiSiteSearch().nextPage(provider: provider, cursor: cursor)
                guard !Task.isCancelled, self.searchSessionGate.accepts(sessionID) else { return false }
                self.searchPaging.lastServed = key
                switch result {
                case .success(let page, let keyword):
                    cursor.keyword = keyword
                    if page.pagination.continuation == .more || page.pagination.pageCount.map({ $0 > requestedPage }) == true {
                        self.searchPaging.restricted.remove(key)
                    }
                    if cursor.accept(page, requestedPage: requestedPage) {
                        let existing = self.searchResults
                        let keyword = self.activeSearchKeyword
                        let maximumRetained = self.searchMaximumRetainedCandidates
                        let maximumPerSite = self.searchMaximumResultsPerSite
                        let snapshot = await Task.detached(priority: .userInitiated) {
                            MultiSiteSearch.merging(existing: existing, incoming: page.items, keyword: keyword,
                                maximumRetainedCandidates: maximumRetained, maximumResultsPerSite: maximumPerSite)
                        }.value
                        guard !Task.isCancelled, self.searchSessionGate.accepts(sessionID) else { return false }
                        self.searchResults = snapshot.items
                        self.searchDidDiscardCandidates = self.searchDidDiscardCandidates || snapshot.didDiscardCandidates
                        self.searchReceivedCandidateCount += page.items.count
                        self.searchFailures.removeAll { $0.siteKey == key }
                        self.searchSiteOutcomes[key] = .success(siteKey: key, siteName: provider.site.name,
                            resultCount: cursor.seenIDs.count)
                        advanced = true
                    }
                case .failure(let message, let uncertain):
                    cursor.fail(message, uncertain: uncertain)
                    let failure = SearchFailure(siteKey: key, siteName: provider.site.name,
                        message: message, isPaginationUncertain: uncertain)
                    self.searchFailures.removeAll { $0.siteKey == key }
                    self.searchFailures.append(failure)
                    self.searchSiteOutcomes[key] = .failure(failure)
                case .cancelled: return false
                }
                self.searchPaging.cursors[key] = cursor
                self.searchPaging.revision += 1
            }
            guard self.searchSessionGate.accepts(sessionID) else { return false }
            // A page can add only alternate sources. Bound automatic work even
            // when the number of visible cards never increases.
            if advanced && Set(self.searchClusters.map(\.id)) == before {
                self.searchPaging.manualContinuation = true
            }
            return advanced
        }
        searchContinuationTask = task
        let succeeded = await task.value
        if searchSessionGate.accepts(sessionID) {
            searchPaging.loading = false
            searchContinuationTask = nil
        }
        return succeeded
    }

    func selectSearchSite(_ key: String?) {
        selectedSearchSiteKey = key
    }

    var searchSiteOptions: [SearchSiteOption] {
        let grouped = Dictionary(grouping: searchResults, by: \.siteKey)
        var options: [SearchSiteOption] = []
        var included = Set<String>()

        for site in visibleSites {
            guard grouped[site.key]?.isEmpty == false else { continue }
            let items = grouped[site.key] ?? []
            included.insert(site.key)
            options.append(
                SearchSiteOption(
                    key: site.key,
                    name: site.name,
                    resultCount: items.count
                )
            )
        }

        for item in searchResults where !included.contains(item.siteKey) {
            guard let items = grouped[item.siteKey] else { continue }
            included.insert(item.siteKey)
            options.append(
                SearchSiteOption(
                    key: item.siteKey,
                    name: item.siteName,
                    resultCount: items.count
                )
            )
        }
        return options
    }

    var searchScopeSiteOptions: [SearchScopeSiteOption] {
        searchCatalogSites.map { site in
            return SearchScopeSiteOption(
                key: site.key,
                name: site.name,
                availability: SearchScopeSiteAvailabilityPolicy.availability(
                    for: site,
                    providerCapability: providers[site.key]?.capability
                )
            )
        }
    }

    var effectiveSearchSiteKeys: Set<String> {
        SearchSiteScopePolicy.effectiveSiteKeys(
            scope: searchSiteScope,
            options: searchScopeSiteOptions
        )
    }

    var searchScopeSummary: String {
        let total = searchScopeSiteOptions.filter(\.isSearchable).count
        let selected = effectiveSearchSiteKeys.count
        switch searchSiteScope.mode {
        case .all:
            return selected == total
                ? L10n.string("search.scope.summary.all", fallback: "Scope: All %d", total)
                : L10n.string("search.scope.summary.enabled", fallback: "Scope: %d/%d Enabled", selected, total)
        case .custom:
            return L10n.string("search.scope.summary.selected", fallback: "Scope: %d/%d Selected", selected, total)
        }
    }

    var searchRuntimeProfileNotice: String? {
        guard activeConfigurationUsesNodeRuntime,
              !NodeDynamicSiteCatalogPolicy.containsConfiguredProvider(
                in: searchCatalogSites
              ) else {
            return nil
        }
        return L10n.string("configuration.catpaw.no-default", fallback: "The current CatPaw resource does not provide a verifiable default configuration. Dynamic providers that depend on accounts or mounts might not appear.")
    }

    var visibleSearchClusters: [SearchResultCluster] {
        guard let selectedSearchSiteKey else { return searchClusters }
        return SearchResultAggregator.cluster(
            searchResults.filter { $0.siteKey == selectedSearchSiteKey }
        )
    }

    var currentSearchFolder: SearchFolderPage? {
        searchFolderPath.last
    }

    func isFavorite(_ detail: VideoDetail) -> Bool {
        guard let context = detailFavoriteSource, context.siteKey == detail.summary.siteKey else { return false }
        return favorites.contains { $0.identity == context.record(detail).identity }
    }
    func canChangeFavorite(_ detail: VideoDetail) -> Bool {
        guard configurationImportOperationID == nil, let context = detailFavoriteSource, context.siteKey == detail.summary.siteKey else { return false }
        return !favoritePendingIdentities.contains(context.record(detail).identity)
    }
    func toggleFavorite(_ detail: VideoDetail) async {
        await setFavorite(detail, isFavorite: !isFavorite(detail))
    }
    func setFavorite(_ detail: VideoDetail, isFavorite desired: Bool) async {
        guard configurationImportOperationID == nil, let environment, let context = detailFavoriteSource,
              context.siteKey == detail.summary.siteKey else { return }
        let record = context.record(detail), identity = record.identity, version = UUID()
        guard !desired || FavoritePersistencePolicy.isValid(record) else {
            show(AppError.configuration(L10n.string("favorites.locator.unsafe", fallback: "This provider returned a temporary or credential-bearing locator. It cannot be saved as a durable favorite.")), title: L10n.string(.sectionFavorites)); return
        }
        favoriteIntentVersions[identity] = version
        favoritePendingIdentities.insert(identity)
        favoritesRevision &+= 1
        let previous = favoriteMutationTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do { self.favorites = try await environment.database.setFavorite(record, isFavorite: desired) }
            catch { self.show(error, title: L10n.string("favorites.action.failed", fallback: "Favorites Action Failed")) }
            self.favoritesRevision &+= 1
            if self.favoriteIntentVersions[identity] == version { self.favoritePendingIdentities.remove(identity) }
        }
        favoriteMutationTask = task
        await task.value
    }

    @discardableResult
    func deleteFavorites(ids: Set<FavoriteRecord.ID>) async -> Bool {
        guard configurationImportOperationID == nil, let environment, !ids.isEmpty else { return false }
        if favoriteLoadingID.map(ids.contains) == true || detailFavoriteExpectation.map({ ids.contains($0.id) }) == true {
            favoriteOpenGeneration = UUID(); favoriteOpenTask?.cancel(); favoriteLoadingID = nil
            cancelDetailRequest(); detailFavoriteExpectation = nil; favoriteRecoveryContext = nil
        }
        if pendingFavoriteRepairID.map(ids.contains) == true { pendingFavoriteRepairID = nil }
        favoritesRevision &+= 1
        let previous = favoriteMutationTask
        var succeeded = false
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                self.favorites = try await environment.database.deleteFavorites(ids: ids)
                succeeded = true
            } catch { self.show(error, title: L10n.string("favorites.delete.failed", fallback: "Favorite Deletion Failed")) }
            self.favoritesRevision &+= 1
        }
        favoriteMutationTask = task
        await task.value
        return succeeded
    }
    func clearFavorites() async { _ = await deleteFavorites(ids: Set(favorites.map(\.id))) }

    func refreshFavoritesPresentation() async {
        guard let environment else { return }
        let revision = favoritesRevision
        do {
            let records = try await environment.database.favorites()
            if revision == favoritesRevision { favorites = records }
        } catch { show(error, title: L10n.string("favorites.action.failed", fallback: "Favorites Action Failed")) }
    }

    func favoriteSourceDescription(_ record: FavoriteRecord) -> String {
        guard let id = record.configurationID else { return L10n.string("favorites.source.unresolved", fallback: "Source needs confirmation") + " · " + (record.siteName ?? record.siteKey) }
        let configuration = configurations.first { $0.id == id }
        let name = configuration?.name ?? record.configurationName ?? L10n.string("favorites.source.unavailable", fallback: "Source unavailable")
        let siteName = activeConfigurationRecord?.id == id ? providers[record.siteKey]?.site.name : nil
        let missing = configuration == nil ? " · " + L10n.string("favorites.source.unavailable", fallback: "Source unavailable") : ""
        return name + " · " + (siteName ?? record.siteName ?? record.siteKey) + missing
    }

    func startPlayback(
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        origin: PlaybackRequestOrigin = .direct,
        authoritativePlaybackResult: SitePlaybackResult? = nil,
        configurationID requestedConfigurationID: UUID? = nil,
        continuingRequestID: UUID? = nil,
        authorizationRetry: Bool = false,
        windowActivation: PlayerWindowActivationPolicy = .userInitiated,
        automaticAdvanceRequestID: UUID? = nil,
        recoveryCheckpoint: NodePlaybackRecoveryCheckpoint? = nil,
        isAutomaticRecovery: Bool = false
    ) async {
        if let automaticAdvanceRequestID {
            guard automaticEpisodeAdvanceController.owns(
                requestID: automaticAdvanceRequestID
            ), !Task.isCancelled else { return }
        } else {
            // A user choice or an authorization/history recovery supersedes a
            // queued automatic transition before it can replace that choice.
            automaticEpisodeAdvanceController.cancel()
        }
        guard !isShutdownRequested,
              let environment,
              let activeConfigurationID = activeConfigurationRecord?.id,
              let provider = providers[detail.summary.siteKey] else { return }
        guard let playbackConfigurationID = PlaybackConfigurationOwnershipPolicy
            .capturedConfigurationID(
                requested: requestedConfigurationID,
                history: origin.historyRecord?.configurationID,
                current: activeConfigurationID
            ) else { return }
        guard PlaybackConfigurationOwnershipPolicy.canBeginPlayback(
            captured: playbackConfigurationID,
            current: activeConfigurationID
        ) else {
            show(
                AppError.playback(L10n.string("player.configuration-switched", fallback: "The playback configuration changed. Switch back to the original configuration and try again.")),
                title: L10n.string("player.stopped", fallback: "Playback Stopped"),
                target: .player
            )
            return
        }
        if continuingRequestID == nil {
            playbackAuthorizationResumeGate.resetForNewPlayback()
            nodePlaybackRecoveryGate.reset()
            nodePlaybackRecoveryTask?.cancel()
            nodePlaybackRecoveryTask = nil
            nodePlaybackLastCheckpoint = nil
        }
        if continuingRequestID == nil,
           cloudAuthorizationContext?.operation.pendingPlayback != nil {
            // A user-selected playback is a new generation. Retire and await
            // cancellation of the exact old Android worker before publishing
            // the new player session, so its late QR/frame/result cannot leak
            // into the replacement overlay.
            await supersedeConfigurationInteractionIfNeeded()
        }
        if let continuingRequestID {
            if authorizationRetry || isAutomaticRecovery {
                guard activePlayerRequestID == continuingRequestID,
                      playbackSessionID == continuingRequestID,
                      isPlayerPresented else { return }
            } else {
                guard origin.isHistory,
                      historyPlaybackPreparationID == continuingRequestID,
                      activePlayerRequestID == continuingRequestID else { return }
            }
        } else if !origin.isHistory {
            if let presentation = playerNodeWebPresentation {
                nodeAuthorizationCompletionTask?.cancel()
                nodeAuthorizationCompletionTask = nil
                Task {
                    await NodeAuthorizationSignalCenter.shared.cancel(
                        presentation.challengeID
                    )
                }
                pendingNodeOperation = nil
                nodeWebPresentation = nil
            }
            nodeAuthorizationAutoRetryRequestID = nil
            historyPlaybackTask?.cancel()
            historyPlaybackTask = nil
            historyPlaybackLoadingID = nil
            historyPlaybackRequestedItem = nil
            historyPlaybackChoices = []
            historyPlaybackPreparationID = UUID()
        }
        if PlaybackAuthorizationResumeGate.allowsInFlightDuplicateFastPath(
            authorizationRetry: authorizationRetry,
            hasAuthoritativeResult: authoritativePlaybackResult != nil
        ), let pendingPlayback,
           pendingPlayback.configurationID == playbackConfigurationID,
           pendingPlayback.detail.summary.siteKey == detail.summary.siteKey,
           pendingPlayback.detail.summary.videoID == detail.summary.videoID,
           pendingPlayback.source.id == source.id,
           pendingPlayback.episode.id == episode.id,
           activePlayback == nil,
           playbackResolutionState != .failed,
           playbackRequestsResolving.contains(pendingPlayback.requestID) {
            presentPlayer(
                requestID: pendingPlayback.requestID,
                activation: .userInitiated
            )
            return
        }
        cancelAllPlaybackStartupGates()
        presentedPlaybackErrorRequestIDs.removeAll()
        // Detail is presented above SearchView, so opening the player does not
        // reliably trigger SearchView.onDisappear. Stop the aggregate search
        // explicitly before cloud URL resolution starts; otherwise its site
        // requests and result clustering compete with the player's cold-start
        // proxy traffic. Keep the accumulated results for a fast return.
        let sessionID = continuingRequestID ?? UUID()
        let nodeTransferContext = transferPlaybackContext(for: sessionID)
        playbackRequestsResolving.insert(sessionID)
        defer {
            playbackRequestsResolving.remove(sessionID)
        }
        PlayerStartupTraceStore.shared.begin(
            requestID: sessionID,
            mode: environment.player.mode
        )
        cancelSearch()
        let imageQuiesceTask = Task { @MainActor in
            await environment.imageRepository.cancelInFlightLoads()
        }
        if continuingRequestID == nil {
            resetPlaybackSkipSession()
        }
        captureHistoryBeforePlaybackTransition()
        clearPlayerEpisodeListRecovery()
        playbackSessionID = sessionID
        activePlayerRequestID = sessionID
        historyProgressCheckpoint.reset(owner: sessionID)
        pendingNodePlaybackConfigurationFallback = nil
        playbackQualitySwitchSessionID = UUID()
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        pendingPlayback = PendingCloudPlayback(
            requestID: sessionID,
            configurationID: playbackConfigurationID,
            detail: detail,
            source: source,
            episode: episode,
            origin: origin,
            recoveryCheckpoint: recoveryCheckpoint
        )
        preparePlayerEpisodePresentations(
            detail: detail,
            source: source,
            sessionID: sessionID
        )
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        livePlaybackNavigationContext = nil
        activePlayback = nil
        cancelDetailRequest()
        detailRouteSummary = nil
        selectedDetail = nil
        pendingDetailSummary = nil
        playbackResolutionState = .resolving
        playerPresentedError = nil
        currentPlaybackAttempt = PlaybackAttempt(
            siteName: detail.summary.siteName,
            sourceName: source.name,
            episodeName: episode.name,
            parserName: nil,
            redactedURL: L10n.string("player.url.resolving", fallback: "<resolving playback URL>"),
            number: 1
        )
        playbackFailureSummary = nil
        isPlayerRenderSurfaceMountEnabled = false
        playerSnapshot = PlayerSnapshot(
            status: .loading,
            volume: playerSnapshot.volume,
            isMuted: playerSnapshot.isMuted,
            speed: playerSnapshot.speed
        )
        // The native window shell is a user-interface response to the click,
        // not a side effect of mpv initialization. Mounting the render surface
        // remains disabled until prepareForPlayback has completed, so the
        // AppKit window can appear immediately without reusing a stale OpenGL
        // context from the previous request.
        presentPlayer(
            requestID: sessionID,
            activation: windowActivation
        )
        // PendingCloudPlayback retains the navigation recipe while resolving.
        // Commit it together with progress only after playback succeeds.
        do {
            guard activePlayerRequestID == sessionID,
                  playbackSessionID == sessionID else { return }
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
        } catch {
            PlayerStartupTraceStore.shared.cancel(requestID: sessionID)
            guard playbackSessionID == sessionID else { return }
            show(error, title: L10n.string("player.initialization.failed", fallback: "Player Initialization Failed"), target: .player)
            return
        }
        guard playbackSessionID == sessionID else { return }
        isPlayerRenderSurfaceMountEnabled = true
        // A transferred cloud file remains leased while its replacement is
        // resolved. MPV's later loadfile/replace event, not the click, proves
        // that the old media has been released.
        if transferMediaLeases.isEmpty {
            await environment.player.stop(ifOwnedBy: sessionID)
        }
        guard playbackSessionID == sessionID else { return }

        var unresolvedTransferReceipts: [UUID: TransferReceipt] = [:]
        do {
            guard detail.playSources.contains(where: { $0.id == source.id }) else {
                throw AppError.playback(L10n.string("player.stream.not-in-details", fallback: "The current stream is not present in the detail data"))
            }
            let httpClient = configuredHTTPClient(environment: environment)
            let resolver = PlaybackResolver(
                parseExecutor: AppParseExecutor(httpClient: httpClient),
                mediaProbe: DefaultMediaProbe(httpClient: httpClient)
            )
            var failures: [String] = []
            var completedAttempts = 0
            var resolvedRequests = Set<String>()
            var initialMediaFingerprint: String?
            var currentProviderReference = Self.acceptedHistoryProviderReference(
                from: origin.historyRecord,
                provider: provider
            ) ?? Self.acceptedProviderResourceReference(
                episode.providerResourceReference,
                provider: provider
            )
            // User line selection is authoritative. Automatic attempts may use
            // configured parsers for that resource, but never silently move to
            // another provider line by array order. One same-resource refresh
            // is allowed for both direct and history playback so short-lived
            // URLs and authorization context can be rebuilt after a 401/403.
            // A history record with a provider-owned durable reference starts
            // with that provider's cache-bypassing refresh. A terminal Bridge
            // result is even more authoritative and therefore remains first.
            let refreshFirst = origin.isHistory
                && authoritativePlaybackResult == nil
                && (currentProviderReference != nil
                    || provider is AndroidDexSpiderSiteProvider
                    || provider is NodeHTTPSpiderSiteProvider)
            let isQuarkPlayback = provider is NodeHTTPSpiderSiteProvider
                && CatPawCloudProvider.resolve(flag: source.name) == .quark
            let refreshAttempts = isAutomaticRecovery ? [true]
                : refreshFirst ? [true] : [false, true]

            for (targetIndex, isRefreshAttempt) in refreshAttempts.enumerated() {
                try Task.checkCancellation()
                guard playbackSessionID == sessionID else {
                    throw CancellationError()
                }
                if isQuarkPlayback, isRefreshAttempt, !isAutomaticRecovery,
                   !nodePlaybackRecoveryGate.claim(sessionID) { break }

                let candidateDetail: VideoDetail
                let candidateSource: PlaySource
                let candidateEpisode: PlayEpisode
                let refreshedPlaybackResult: SitePlaybackResult?
                if !isRefreshAttempt {
                    candidateDetail = detail
                    candidateSource = source
                    candidateEpisode = episode
                    refreshedPlaybackResult = targetIndex == 0
                        ? authoritativePlaybackResult
                        : nil
                } else if !origin.isHistory {
                    // Ordinary playback already owns an exact detail, flag and
                    // episode URL selected by the user. Retry playerContent
                    // once with that same tuple so a transient cloud dlink can
                    // be rebuilt. Never invoke history-navigation matching
                    // here: fuzzy source/episode relocation can mask the real
                    // media failure with an unrelated "无法唯一匹配" error.
                    candidateDetail = detail
                    candidateSource = source
                    candidateEpisode = episode
                    refreshedPlaybackResult = nil
                } else {
                    // A retry is a true same-resource refresh. Fetch current
                    // detail again so expiring episode references, provider
                    // state, headers, and authorization context can all be
                    // rebuilt. Repeating player() with the old episode value
                    // is not a refresh.
                    do {
                        let historyRecord = origin.historyRecord
                        let reference = historyRecord?.playbackReference
                        let providerReference = currentProviderReference
                        let refreshRequest = PlaybackRefreshRequest(
                            // The verified fresh detail ID is usable by the provider;
                            // a persisted cloud row ID may be only a deduplication hash.
                            videoID: detail.summary.videoID,
                            title: historyRecord?.title
                                ?? detail.summary.title,
                            sourceIdentity: providerReference?.sourceIdentity
                                ?? reference?.sourceIdentity
                                ?? source.stableIdentity,
                            resourceIdentity: providerReference?.episodeIdentity
                                ?? reference?.resourceIdentity
                                ?? episode.stableIdentity,
                            sourceName: historyRecord?.sourceName
                                ?? source.name,
                            episodeName: historyRecord?.episodeName
                                ?? episode.name,
                            episodeReference: providerReference?
                                .stableResourceLocator
                                ?? historyRecord?.episodeReference
                                ?? episode.url,
                            providerResourceReference: providerReference
                        )
                        let refreshed: RefreshedSitePlayback
                        if let androidProvider = provider
                            as? AndroidDexSpiderSiteProvider {
                            refreshed = try await androidProvider
                                .refreshPlayback(
                                    refreshRequest,
                                    interactionID: sessionID
                                )
                        } else if let nodeProvider = provider
                            as? NodeHTTPSpiderSiteProvider {
                            refreshed = try await nodeProvider.refreshPlayback(
                                refreshRequest,
                                transferContext: nodeTransferContext
                            )
                        } else {
                            refreshed = try await provider.refreshPlayback(
                                refreshRequest
                            )
                        }
                        if let historyRecord,
                           !Self.historyContentMatches(refreshed.detail, record: historyRecord) {
                            throw AppError.playback("刷新后的影片与历史记录不一致，请重新选择播放内容")
                        }
                        candidateDetail = refreshed.detail
                        candidateSource = refreshed.source
                        candidateEpisode = refreshed.episode
                        refreshedPlaybackResult = refreshed.playbackResult
                    } catch let authorization as NodeWebAuthorizationRequired {
                        guard let identity = activeSourceIdentity(
                            for: detail.summary.siteKey
                        ) else { return }
                        presentNodeConfiguration(
                            authorization,
                            pending: .playback(
                                identity: identity,
                                playback: PendingCloudPlayback(
                                    requestID: sessionID,
                                    configurationID: playbackConfigurationID,
                                    detail: detail,
                                    source: source,
                                    episode: episode,
                                    origin: origin
                                )
                            )
                        )
                        return
                    } catch let authorization as AndroidBridgeUIRequired {
                        guard playbackSessionID == sessionID else {
                            scheduleConfigurationInteractionCleanup(
                                authorization.handle,
                                reason: ConfigurationInteractionCancellationReason
                                    .superseded.rawValue
                            )
                            return
                        }
                        // Hand the request lease to the authorization flow
                        // before its first await. The terminal provider result
                        // may already be cached and resume this same request
                        // while presentation is still being assembled.
                        playbackRequestsResolving.remove(sessionID)
                        await presentCloudAuthorization(
                            authorization.state,
                            interaction: authorization.interaction,
                            handle: authorization.handle,
                            operation: .playback(
                                PendingCloudPlayback(
                                    requestID: sessionID,
                                    configurationID: playbackConfigurationID,
                                    detail: detail,
                                    source: source,
                                    episode: episode,
                                    origin: origin
                                )
                            ),
                            siteKey: detail.summary.siteKey
                        )
                        return
                    } catch let providerError as ProviderPlaybackError {
                        guard playbackSessionID == sessionID else { return }
                        await finishProviderPlaybackFailure(
                            providerError,
                            requestID: sessionID,
                            provider: provider
                        )
                        return
                    } catch {
                        let message = localizedRuntimeErrorMessage(error)
                        failures.append(L10n.string("player.details.refresh.failed", fallback: "Failed to refresh playback details: %@", message))
                        playbackFailureSummary = message
                        continue
                    }
                }

                currentPlaybackAttempt = PlaybackAttempt(
                    siteName: candidateDetail.summary.siteName,
                    sourceName: candidateSource.name,
                    episodeName: candidateEpisode.name,
                    parserName: nil,
                    redactedURL: L10n.string("player.url.resolving", fallback: "<resolving playback URL>"),
                    number: completedAttempts + 1
                )
                playbackResolutionState = completedAttempts == 0
                    ? .resolving
                    : .retrying

                let result: SitePlaybackResult
                do {
                    if let refreshedPlaybackResult {
                        result = refreshedPlaybackResult
                    } else {
                        result = try await requestSitePlayback(
                            provider: provider,
                            flag: candidateSource.name,
                            episodeURL: candidateEpisode.url,
                            sessionID: sessionID,
                            transferContext: nodeTransferContext
                        )
                    }
                    if let receipt = result.transferReceipt {
                        unresolvedTransferReceipts[receipt.receiptID] = receipt
                        guard TransferReceiptOwnershipPolicy.accepts(
                            receipt,
                            requestID: nodeTransferContext.requestID,
                            requestGeneration:
                                nodeTransferContext.requestGeneration
                        ) else {
                            await cleanupTransferReceipt(
                                receipt,
                                reason: .staleGeneration
                            )
                            unresolvedTransferReceipts[receipt.receiptID] = nil
                            throw CancellationError()
                        }
                    }
                    guard playbackSessionID == sessionID else {
                        if let receipt = result.transferReceipt {
                            await cleanupTransferReceipt(
                                receipt,
                                reason: .staleGeneration
                            )
                            unresolvedTransferReceipts[receipt.receiptID] = nil
                        }
                        throw CancellationError()
                    }
                    if let acceptedReference = Self.acceptedProviderResourceReference(
                        result.resourceReference,
                        provider: provider
                    ) {
                        // A detail-time CatPaw reference contains the complete
                        // vodID/flag/episodeID or Pan path replay. A later
                        // player response may expose only a narrower Quark
                        // share/file reference; keep the complete protocol
                        // locator instead of downgrading history identity.
                        if currentProviderReference.map({
                            !NodePlaybackReplayReference.isCurrentLocator(
                                $0.stableResourceLocator
                            )
                        }) ?? true {
                            currentProviderReference = acceptedReference
                        }
                    }
                } catch let authorization as NodeWebAuthorizationRequired {
                    guard playbackSessionID == sessionID else { return }
                    guard let identity = activeSourceIdentity(
                        for: candidateDetail.summary.siteKey
                    ) else {
                        playbackResolutionState = .failed
                        playbackFailureSummary = L10n.string("player.configuration-changed", fallback: "The playback configuration changed")
                        return
                    }
                    presentNodeConfiguration(
                        authorization,
                        pending: .playback(
                            identity: identity,
                            playback: PendingCloudPlayback(
                                requestID: sessionID,
                                configurationID: playbackConfigurationID,
                                detail: candidateDetail,
                                source: candidateSource,
                                episode: candidateEpisode,
                                origin: origin
                            )
                        )
                    )
                    return
                } catch let authorization as AndroidBridgeUIRequired {
                    guard playbackSessionID == sessionID else {
                        scheduleConfigurationInteractionCleanup(
                            authorization.handle,
                            reason: ConfigurationInteractionCancellationReason
                                .superseded.rawValue
                        )
                        return
                    }
                    // The deferred removal below remains as an idempotent
                    // cleanup, but cannot be the synchronization boundary: an
                    // authorization terminal can arrive during this await.
                    playbackRequestsResolving.remove(sessionID)
                    await presentCloudAuthorization(
                        authorization.state,
                        interaction: authorization.interaction,
                        handle: authorization.handle,
                        operation: .playback(
                            PendingCloudPlayback(
                                requestID: sessionID,
                                configurationID: playbackConfigurationID,
                                detail: candidateDetail,
                                source: candidateSource,
                                episode: candidateEpisode,
                                origin: origin
                            )
                        ),
                        siteKey: candidateDetail.summary.siteKey
                    )
                    return
                } catch let providerError as ProviderPlaybackError {
                    guard playbackSessionID == sessionID else { return }
                    await finishProviderPlaybackFailure(
                        providerError,
                        requestID: sessionID,
                        provider: provider
                    )
                    return
                } catch {
                    guard playbackSessionID == sessionID else { return }
                    let message = localizedRuntimeErrorMessage(error)
                    failures.append(
                        L10n.string(
                            "player.stream.failure-detail",
                            fallback: "%1$@: %2$@",
                            candidateSource.name,
                            message
                        )
                    )
                    playbackFailureSummary = message
                    continue
                }

                // A provider-owned loopback URL is a short-lived capability;
                // its random session component does not prove that the
                // upstream media request changed. Prefer the provider's
                // non-secret upstream fingerprint together with the stable
                // resource identity and request policy. Legacy results that
                // cannot provide a fingerprint retain URL + header-value
                // comparison for compatibility.
                let requestSignature = Self.playbackRequestSignature(for: result)
                if !resolvedRequests.insert(requestSignature).inserted {
                    if let receipt = result.transferReceipt {
                        await cleanupTransferReceipt(
                            receipt,
                            reason: .resolutionFailed
                        )
                        unresolvedTransferReceipts[receipt.receiptID] = nil
                    }
                    if result.networkPolicy == .systemHTTPProxy, !failures.isEmpty {
                        // A stable Xtream URL is expected. Keep the actual
                        // load failure visible; a duplicate adds no diagnosis.
                        PlayerExperimentLogger.lifecycle(
                            "phase=duplicate_resolution skipped=true network=system-http",
                            playerID: nil, requestID: sessionID,
                            mode: environment.player.mode
                        )
                        continue
                    }
                    failures.append(L10n.string("player.resolve.same-result.source", fallback: "%@: resolving again returned the same URL and request context", candidateSource.name))
                    playbackFailureSummary = L10n.string("player.resolve.same-result", fallback: "Resolving again returned the same URL and request context")
                    continue
                }
                let currentMediaFingerprint = result.mediaSession?
                    .upstreamResourceFingerprint
                let refreshWasExplicitlyObserved = isRefreshAttempt
                    && (result.mediaSession?.refreshPerformed == true
                        || (initialMediaFingerprint != nil
                            && currentMediaFingerprint != nil
                            && currentMediaFingerprint != initialMediaFingerprint))
                if targetIndex == 0 {
                    initialMediaFingerprint = currentMediaFingerprint
                }

                let attemptContext = PlaybackResolutionAttemptContext(
                    detail: candidateDetail,
                    source: candidateSource,
                    episode: candidateEpisode,
                    result: result,
                    danmakuContext: makeDanmakuPlaybackContext(
                        configurationID: playbackConfigurationID,
                        provider: provider,
                        detail: candidateDetail,
                        source: candidateSource,
                        episode: candidateEpisode,
                        result: result,
                        sessionID: sessionID
                    )
                )
                let providerReferenceForAttempt = currentProviderReference
                let remainingAttempts = isQuarkPlayback ? 1 : max(1, 8 - completedAttempts)
                var attemptsInCandidate = 0
                var candidateFailure: String?
                var candidateMediaFailure: NodeCloudMediaFailure?
                var checkedLateNodeAuthorization = false
                let lateNodeAuthorizationNotBefore = Date()
                let stream = resolver.resolve(
                    attemptContext.resolutionRequest(
                        configuredParsers: activeConfiguration?.parses ?? [],
                        maximumAttempts: remainingAttempts
                    ),
                    mediaLoader: { [weak self] media, _ in
                        guard let self,
                              self.playbackSessionID == sessionID else {
                            throw CancellationError()
                        }
                        // Image cancellation is started at the click boundary,
                        // but overlaps player preparation and URL resolution.
                        // Preserve the hard boundary before loadfile so poster
                        // work cannot compete with first-frame decode.
                        if provider.capability != .javaDexSpider {
                            await imageQuiesceTask.value
                        }
                        try await self.loadResolvedPlayback(
                            media,
                            detail: attemptContext.detail,
                            source: attemptContext.source,
                            episode: attemptContext.episode,
                            playbackResult: attemptContext.result,
                            configurationID: playbackConfigurationID,
                            providerResourceReference: providerReferenceForAttempt,
                            sessionID: sessionID
                        )
                    }
                )
                for await event in stream {
                    try Task.checkCancellation()
                    guard playbackSessionID == sessionID else {
                        throw CancellationError()
                    }
                    switch event {
                    case .state(let resolutionState):
                        playbackResolutionState = resolutionState
                    case .attempting(var attempt):
                        attemptsInCandidate = max(attemptsInCandidate, attempt.number)
                        attempt.number += completedAttempts
                        currentPlaybackAttempt = attempt
                    case .attemptFailed(var attempt, let message):
                        attemptsInCandidate = max(attemptsInCandidate, attempt.number)
                        attempt.number += completedAttempts
                        currentPlaybackAttempt = attempt
                        if !checkedLateNodeAuthorization,
                           result.validationPolicy == .playerAuthoritative {
                            checkedLateNodeAuthorization = true
                            let pending = PendingCloudPlayback(
                                requestID: sessionID,
                                configurationID: playbackConfigurationID,
                                detail: candidateDetail,
                                source: candidateSource,
                                episode: candidateEpisode,
                                origin: origin
                            )
                            if await presentLateNodePlaybackAuthorizationIfNeeded(
                                provider: provider,
                                flag: candidateSource.name,
                                notBefore: lateNodeAuthorizationNotBefore,
                                playback: pending
                            ) {
                                if let receipt = result.transferReceipt {
                                    await cleanupTransferReceipt(
                                        receipt,
                                        reason: .resolutionFailed
                                    )
                                    unresolvedTransferReceipts[
                                        receipt.receiptID
                                    ] = nil
                                }
                                return
                            }
                        }
                        if candidateMediaFailure == nil,
                           CatPawCloudProvider.resolve(flag: candidateSource.name) == .quark,
                           let nodeProvider = provider as? NodeHTTPSpiderSiteProvider {
                            candidateMediaFailure = await nodeProvider.consumeLatePlaybackFailure(
                                transferContext: nodeTransferContext
                            )
                            guard playbackSessionID == sessionID else { return }
                        }
                        playbackFailureSummary = candidateMediaFailure?.message ?? Self.playbackFailureMessage(
                            message,
                            validationPolicy: result.validationPolicy,
                            refreshPerformed: refreshWasExplicitlyObserved
                        )
                    case .resolved:
                        if let receipt = result.transferReceipt {
                            unresolvedTransferReceipts[receipt.receiptID] = nil
                        }
                        playbackFailureSummary = nil
                        pendingPlayback = nil
                        return
                    case .failed(let message):
                        if !checkedLateNodeAuthorization,
                           result.validationPolicy == .playerAuthoritative {
                            checkedLateNodeAuthorization = true
                            let pending = PendingCloudPlayback(
                                requestID: sessionID,
                                configurationID: playbackConfigurationID,
                                detail: candidateDetail,
                                source: candidateSource,
                                episode: candidateEpisode,
                                origin: origin
                            )
                            if await presentLateNodePlaybackAuthorizationIfNeeded(
                                provider: provider,
                                flag: candidateSource.name,
                                notBefore: lateNodeAuthorizationNotBefore,
                                playback: pending
                            ) {
                                if let receipt = result.transferReceipt {
                                    await cleanupTransferReceipt(
                                        receipt,
                                        reason: .resolutionFailed
                                    )
                                    unresolvedTransferReceipts[
                                        receipt.receiptID
                                    ] = nil
                                }
                                return
                            }
                        }
                        if candidateMediaFailure == nil,
                           CatPawCloudProvider.resolve(flag: candidateSource.name) == .quark,
                           let nodeProvider = provider as? NodeHTTPSpiderSiteProvider {
                            candidateMediaFailure = await nodeProvider.consumeLatePlaybackFailure(
                                transferContext: nodeTransferContext
                            )
                            guard playbackSessionID == sessionID else { return }
                        }
                        candidateFailure = candidateMediaFailure?.message ?? Self.playbackFailureMessage(
                            message,
                            validationPolicy: result.validationPolicy,
                            refreshPerformed: refreshWasExplicitlyObserved
                        )
                    case .cancelled:
                        throw CancellationError()
                    }
                }
                if let receipt = result.transferReceipt {
                    await cleanupTransferReceipt(
                        receipt,
                        reason: .resolutionFailed
                    )
                    unresolvedTransferReceipts[receipt.receiptID] = nil
                }
                completedAttempts += attemptsInCandidate
                if let candidateFailure {
                    failures.append(candidateFailure)
                    playbackFailureSummary = candidateFailure
                }
                if candidateMediaFailure?.allowsAutomaticRecovery == false || completedAttempts >= 8 {
                    break
                }
            }

            let message = Self.consolidatedPlaybackFailureMessage(failures)
            prepareNodePlaybackFailureRecovery(provider: provider, message: message)
            playbackResolutionState = .exhausted
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
            if !canOpenNodeConfigurationForPlaybackFailure {
                presentPlaybackErrorOnce(message, requestID: sessionID)
            }
        } catch is CancellationError {
            for receipt in unresolvedTransferReceipts.values {
                await cleanupTransferReceipt(
                    receipt,
                    reason: .staleGeneration
                )
            }
            unresolvedTransferReceipts.removeAll()
            if playbackSessionID == sessionID {
                await dismissPlayerSurfaceAndRestoreWindow()
                activePlayback = nil
                pendingPlayback = nil
                playbackQualities = []
                selectedPlaybackQualityID = nil
                isSwitchingPlaybackQuality = false
                playbackResolutionState = .idle
            }
        } catch {
            for receipt in unresolvedTransferReceipts.values {
                await cleanupTransferReceipt(
                    receipt,
                    reason: .resolutionFailed
                )
            }
            unresolvedTransferReceipts.removeAll()
            guard playbackSessionID == sessionID else { return }
            let message = localizedRuntimeErrorMessage(error)
            prepareNodePlaybackFailureRecovery(provider: provider, message: message)
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
            if !canOpenNodeConfigurationForPlaybackFailure {
                presentPlaybackErrorOnce(message, requestID: sessionID)
            }
        }
    }

    private func requestSitePlayback(
        provider: any SiteProvider,
        flag: String,
        episodeURL: String,
        sessionID: UUID,
        transferContext: NodeTransferPlaybackContext
    ) async throws -> SitePlaybackResult {
        try Task.checkCancellation()
        guard playbackSessionID == sessionID else {
            throw CancellationError()
        }
        if let androidProvider = provider as? AndroidDexSpiderSiteProvider {
            return try await androidProvider.player(
                flag: flag,
                episodeURL: episodeURL,
                interactionID: sessionID
            )
        }
        if let nodeProvider = provider as? NodeHTTPSpiderSiteProvider {
            return try await nodeProvider.player(
                flag: flag,
                episodeURL: episodeURL,
                transferContext: transferContext
            )
        }
        return try await provider.player(
            flag: flag,
            episodeURL: episodeURL
        )
    }

    private func transferPlaybackContext(
        for requestID: UUID
    ) -> NodeTransferPlaybackContext {
        if let generation = transferGenerationsByRequestID[requestID] {
            return NodeTransferPlaybackContext(
                requestID: requestID,
                requestGeneration: generation
            )
        }
        transferRequestGeneration &+= 1
        if transferRequestGeneration == 0 {
            transferRequestGeneration = 1
        }
        let generation = transferRequestGeneration
        transferGenerationsByRequestID[requestID] = generation
        if transferGenerationsByRequestID.count > 128 {
            let retained = Set(playbackRequestsResolving)
                .union([requestID, playbackSessionID, activePlayerRequestID])
            transferGenerationsByRequestID = transferGenerationsByRequestID
                .filter { retained.contains($0.key) }
        }
        return NodeTransferPlaybackContext(
            requestID: requestID,
            requestGeneration: generation
        )
    }

    private func presentLateNodePlaybackAuthorizationIfNeeded(
        provider: any SiteProvider,
        flag: String,
        notBefore: Date,
        playback: PendingCloudPlayback
    ) async -> Bool {
        guard playback.requestID == playbackSessionID,
              playback.requestID == activePlayerRequestID,
              let nodeProvider = provider as? NodeHTTPSpiderSiteProvider,
              let authorization = await nodeProvider
                .consumeLatePlaybackAuthorization(
                    flag: flag,
                    notBefore: notBefore,
                    transferContext: transferPlaybackContext(
                        for: playback.requestID
                    )
                ),
              playback.requestID == playbackSessionID,
              playback.requestID == activePlayerRequestID,
              let identity = activeSourceIdentity(
                for: playback.detail.summary.siteKey
              ) else {
            return false
        }
        playbackFailureSummary = authorization.localizedDescription
        presentNodeConfiguration(
            authorization,
            pending: .playback(identity: identity, playback: playback)
        )
        return true
    }

    private func finishProviderPlaybackFailure(
        _ error: ProviderPlaybackError,
        requestID: UUID,
        provider: SiteProvider?
    ) async {
        guard playbackSessionID == requestID else { return }
        let message = localizedRuntimeErrorMessage(error)
        prepareNodePlaybackFailureRecovery(provider: provider, message: error.message)
        if CloudPlaybackAuthorizationFailurePolicy.isExplicit(error.message),
           let provider,
           let scopeID = cloudAccountScopeID(
               for: provider,
               sourceIdentity: activeSourceIdentity(for: provider.site.key)
           ), cloudAccountStatusStore.invalidate(scopeID: scopeID) {
            await persistCloudAccountStatusStore()
        }
        playbackResolutionState = .failed
        playbackFailureSummary = message
        playerSnapshot.status = .failed(message)
        pendingPlayback = nil
        if !canOpenNodeConfigurationForPlaybackFailure {
            presentPlaybackErrorOnce(message, requestID: requestID)
        }
    }

    private func prepareNodePlaybackFailureRecovery(provider: SiteProvider?, message: String) {
        if let nodeProvider = provider as? NodeHTTPSpiderSiteProvider,
           let playback = pendingPlayback,
           playback.requestID == activePlayerRequestID,
           let identity = activeSourceIdentity(
               for: playback.detail.summary.siteKey
           ), let cloudProvider = CatPawCloudProvider.resolve(
               flag: playback.source.name,
               message: message
           ) {
            pendingNodePlaybackConfigurationFallback =
                PendingNodePlaybackConfigurationFallback(
                    authorization: NodeWebAuthorizationRequired(
                        challengeID: UUID(),
                        requestID: nil,
                        websiteURL: nodeProvider.configurationWebsiteURL,
                        title: L10n.string("cloud.authorization.open-provider", fallback: "Open %@ Authorization Settings", cloudProvider.displayName),
                        message: L10n.string("cloud.authorization.media-check", fallback: "Playback failed, but account expiration has not been confirmed. Check cloud authorization here; after saving, the app will verify and resume only the current title once."),
                        provider: cloudProvider.displayName,
                        profileRevision: nodeProvider.site.extra[
                            "okNodeProfileRevision"
                        ]?.stringValue,
                        transport: "manual",
                        preferredProviderID: cloudProvider.rawValue,
                        completionMode: .profileRevision
                    ),
                    operation: .playback(
                        identity: identity,
                        playback: playback
                    )
                )
        } else {
            pendingNodePlaybackConfigurationFallback = nil
        }
    }

    static func playbackFailureMessage(
        _ message: String,
        validationPolicy: SitePlaybackResult.ValidationPolicy,
        refreshPerformed: Bool = false,
        upstreamHTTPStatusCode: Int? = nil
    ) -> String {
        guard validationPolicy == .playerAuthoritative else { return message }
        // libmpv's generic `loading failed` does not identify an authorization
        // failure. A provider loopback proxy can already have returned 200/206
        // and still fail because the body is empty, truncated, non-media, has an
        // inconsistent range, or cannot be demuxed. Only structured upstream
        // HTTP evidence may turn a player failure into an authorization prompt;
        // NodeWebAuthorizationRequired is handled explicitly before this helper.
        if upstreamHTTPStatusCode == 401 || upstreamHTTPStatusCode == 403 {
            let refreshStatus = refreshPerformed
                ? L10n.string("player.media-refresh-completed.prefix", fallback: "The same resource was refreshed once; ")
                : ""
            return L10n.string("player.media-request-denied", fallback: "The media request was denied. Cloud authorization or the temporary playback URL may have expired. %@Authorize again and retry.", refreshStatus)
        }
        return message
    }

    static func consolidatedPlaybackFailureMessage(
        _ failures: [String]
    ) -> String {
        let proxyFailure = L10n.string("player.android-proxy.failed", fallback: "The internal Android media proxy did not forward the request correctly")
        let normalized = failures.compactMap { failure -> String? in
            let value = failure.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if normalized.contains(where: { $0.contains(proxyFailure) }) {
            return proxyFailure
        }
        var seen = Set<String>()
        let unique = normalized.filter { seen.insert($0).inserted }
        return unique.suffix(4).joined(
            separator: L10n.string("common.list-separator", fallback: "; ")
        )
            .nonEmpty ?? L10n.string("player.all-streams.failed", fallback: "No available stream returned playable media")
    }

    static func playbackRequestSignature(
        for result: SitePlaybackResult
    ) -> String {
        guard let mediaSession = result.mediaSession,
              let fingerprint = mediaSession.upstreamResourceFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            let sensitiveRequest = ([result.url] + result.headers.dictionary
                .map { "\($0.key.lowercased()):\($0.value)" }
                .sorted())
                .joined(separator: "\n")
            let digest = SHA256.hash(data: Data(sensitiveRequest.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            return "legacy-v1:\(digest)"
        }

        let reference = mediaSession.resourceReference
        let fingerprintDigest = SHA256.hash(
            data: Data(fingerprint.utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()
        let headerNames = Set(
            result.headers.dictionary.keys.map { $0.lowercased() }
                + mediaSession.headers.dictionary.keys.map { $0.lowercased() }
        ).sorted().joined(separator: ",")
        return [
            "provider-v1",
            "fingerprint-sha256:\(fingerprintDigest)",
            "configuration:\(reference.configurationIdentity)",
            "site:\(reference.siteIdentity)",
            "provider:\(reference.providerKind):\(reference.providerVersion)",
            "source:\(reference.sourceIdentity)",
            "episode:\(reference.episodeIdentity)",
            "transport:\(mediaSession.transport.rawValue)",
            "redirect:\(mediaSession.redirectPolicy.rawValue)",
            "range:\(mediaSession.rangePolicy.rawValue)",
            "refresh:\(mediaSession.refreshPerformed.map(String.init) ?? "unknown")",
            "headers:\(headerNames)"
        ].joined(separator: "\n")
    }

    @discardableResult
    func importLiveSource(
        source: LiveSourceInput,
        name: String?,
        progress: (LiveSourceImportPhase) -> Void = { _ in }
    ) async -> Bool {
        guard let environment else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            if case .remote = source {
                progress(.downloadingAndParsing)
            } else {
                progress(.parsing)
            }
            let loaded = try await environment.liveSourceLoader.load(source)
            try Task.checkCancellation()
            let sourceDetails: (StoredLiveSourceKind, String?)
            switch source {
            case .remote(let url):
                sourceDetails = (.remote, url.absoluteString)
            case .localFile(let url):
                sourceDetails = (.localFile, url.path)
            case .pasted:
                sourceDetails = (.pasted, nil)
            }
            let record = StoredLiveSource(
                name: name?.nonEmpty ?? source.displayName,
                sourceKind: sourceDetails.0,
                sourceValue: sourceDetails.1,
                baseURL: loaded.baseURL,
                rawData: loaded.rawData,
                updatedAt: loaded.loadedAt
            )
            progress(.saving)
            try Task.checkCancellation()
            try await environment.database.createLiveSource(record)
            try Task.checkCancellation()
            progress(.publishing)
            liveSources = try await environment.database.liveSources()
            try Task.checkCancellation()
            publishImportedCatalog(loaded.playlist, sourceID: record.id)
            startLiveSourceBackgroundWork(for: record, playlist: loaded.playlist)
            return true
        } catch is CancellationError {
            return false
        } catch {
            show(error, title: L10n.string("live.source.load.failed", fallback: "Live TV Source Failed to Load"))
            return false
        }
    }

    func synchronizeEmbeddedLiveSources(
        configurationID: UUID
    ) async -> EmbeddedLiveSourceSyncResult {
        guard let environment,
              activeConfigurationRecord?.id == configurationID,
              let configuration = activeConfiguration else {
            return EmbeddedLiveSourceSyncResult(
                importedCount: 0,
                skippedCount: 0,
                failedCount: 0
            )
        }

        isLoading = true
        defer { isLoading = false }
        let baseURL = activeConfigurationRecord?.baseURL
        var importedCount = 0
        var skippedCount = 0
        var failedCount = 0

        for live in configuration.lives {
            do {
                try Task.checkCancellation()
                let record: StoredLiveSource
                let playlist: LivePlaylist

                if !live.groups.isEmpty {
                    let data = try EmbeddedLiveSourcePolicy.inlineData(for: live)
                    if liveSources.contains(where: {
                        $0.sourceKind == .pasted
                            && $0.name == live.name
                            && $0.rawData == data
                    }) {
                        skippedCount += 1
                        continue
                    }
                    playlist = try LiveSourceParser().parse(
                        data,
                        baseURL: baseURL
                    )
                    record = StoredLiveSource(
                        name: live.name,
                        sourceKind: .pasted,
                        baseURL: baseURL,
                        rawData: data
                    )
                } else if let url = EmbeddedLiveSourcePolicy.remoteURL(
                    for: live,
                    baseURL: baseURL
                ) {
                    if liveSources.contains(where: {
                        $0.sourceKind == .remote
                            && $0.sourceValue == url.absoluteString
                    }) {
                        skippedCount += 1
                        continue
                    }
                    let loaded = try await environment.liveSourceLoader.load(
                        .remote(url)
                    )
                    playlist = loaded.playlist.applyingDefaultHeaders(
                        EmbeddedLiveSourcePolicy.defaultHeaders(for: live)
                    )
                    record = StoredLiveSource(
                        name: live.name,
                        sourceKind: .remote,
                        sourceValue: url.absoluteString,
                        baseURL: loaded.baseURL,
                        rawData: loaded.rawData,
                        updatedAt: loaded.loadedAt
                    )
                } else {
                    skippedCount += 1
                    continue
                }

                try await environment.database.saveLiveSource(record)
                publishImportedCatalog(playlist, sourceID: record.id)
                startLiveSourceBackgroundWork(for: record, playlist: playlist)
                importedCount += 1
            } catch is CancellationError {
                break
            } catch {
                failedCount += 1
            }
        }

        if let refreshed = try? await environment.database.liveSources() {
            liveSources = refreshed
        }
        return EmbeddedLiveSourceSyncResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            failedCount: failedCount
        )
    }

    var liveSourceDescriptors: [LiveSourceDescriptor] {
        var sources = liveSources.map {
            LiveSourceDescriptor(
                id: .imported($0.id), name: $0.name,
                canRefresh: $0.sourceKind == .remote,
                canExport: true, supportsEPG: true
            )
        }
        if let record = activeConfigurationRecord,
           record.sourceKind == .xtream,
           let configuration = try? XtreamProviderConfiguration(data: record.rawData),
           configuration.providerID == record.id {
            sources.append(LiveSourceDescriptor(
                id: .xtream(record.id), name: record.name,
                canRefresh: true, canExport: false, supportsEPG: true
            ))
        }
        return sources
    }

    func liveCatalog(for sourceID: LiveSourceID) -> LiveCatalogSnapshot? {
        switch sourceID {
        case .imported(let id):
            guard liveSources.contains(where: { $0.id == id }),
                  let playlist = loadedLivePlaylists[id] else { return nil }
            return LiveCatalogSnapshot(sourceID: sourceID, groups: playlist.groups, epgURL: playlist.epgURL)
        case .xtream:
            guard liveSourceDescriptors.contains(where: { $0.id == sourceID }),
                  nativeLiveCatalog?.sourceID == sourceID else { return nil }
            return nativeLiveCatalog
        }
    }

    func isLiveCatalogLoading(_ sourceID: LiveSourceID) -> Bool {
        liveCatalogLoadingSourceIDs.contains(sourceID)
            || (importedIdentityEnabled && importedIdentitySource == sourceID
                && importedIdentityMapping == nil && !importedIdentityMappingFailed
                && liveCatalog(for: sourceID) != nil)
    }

    /// UI-only projection. Unknown authority is a loading/error state, never
    /// an invented "all channels deleted" count. Player/catalog access unchanged.
    func presentedLiveCatalog(for sourceID: LiveSourceID) -> LiveCatalogSnapshot? {
        if importedIdentityEnabled, case .imported = sourceID,
           (importedIdentityMapping?.sourceID).map(LiveSourceID.imported) != sourceID { return nil }
        return liveCatalog(for: sourceID)
    }

    func liveCatalogError(for sourceID: LiveSourceID) -> String? {
        if importedIdentityEnabled, case .imported = sourceID, importedIdentityMappingFailed {
            return "频道身份暂不可用，请刷新后重试。"
        }
        guard case .xtream = sourceID,
              liveSourceDescriptors.contains(where: { $0.id == sourceID }) else { return nil }
        return nativeLiveCatalogError
    }

    func loadLiveSource(_ sourceID: LiveSourceID) async {
        switch sourceID {
        case .imported(let id):
            guard let source = liveSources.first(where: { $0.id == id }),
                  loadedLivePlaylists[id] == nil else { return }
            await loadLiveSource(source)
        case .xtream:
            guard liveCatalog(for: sourceID) == nil,
                  !isLiveCatalogLoading(sourceID) else { return }
            await loadXtreamLiveCatalog(sourceID)
        }
    }

    func refreshLiveSource(_ sourceID: LiveSourceID) async {
        switch sourceID {
        case .imported(let id): await refreshLiveSource(id)
        case .xtream: await loadXtreamLiveCatalog(sourceID)
        }
    }

    private func loadXtreamLiveCatalog(_ sourceID: LiveSourceID) async {
        guard !isShutdownRequested,
              case .xtream(let id) = sourceID,
              !nativeLiveAccountMutationIDs.contains(id),
              let record = activeConfigurationRecord, record.id == id,
              record.sourceKind == .xtream,
              let descriptor = try? XtreamProviderConfiguration(data: record.rawData),
              descriptor.providerID == id else { return }
        nativeLiveCatalogTask?.cancel()
        nativeLiveCatalogError = nil
        guard let provider = providers[descriptor.siteKey] as? XtreamSiteProvider else {
            nativeLiveCatalogRequestID = nil
            nativeLiveCatalogTask = nil
            liveCatalogLoadingSourceIDs.remove(sourceID)
            nativeLiveCatalogError = L10n.string(
                "xtream.live.credentials-unavailable",
                fallback: "This provider is unavailable. Check its account credentials in Settings."
            )
            return
        }
        let requestID = UUID()
        let generation = nativeLiveGeneration
        nativeLiveCatalogRequestID = requestID
        liveCatalogLoadingSourceIDs = liveCatalogLoadingSourceIDs.filter {
            if case .xtream = $0 { return false }; return true
        }
        liveCatalogLoadingSourceIDs.insert(sourceID)
        let task = Task { try await provider.liveCatalog() }
        nativeLiveCatalogTask = task
        defer {
            if nativeLiveCatalogRequestID == requestID {
                nativeLiveCatalogRequestID = nil
                nativeLiveCatalogTask = nil
                liveCatalogLoadingSourceIDs.remove(sourceID)
            }
        }
        do {
            let catalog = try await task.value
            guard !Task.isCancelled, !isShutdownRequested,
                  nativeLiveGeneration == generation,
                  nativeLiveCatalogRequestID == requestID,
                  activeConfigurationRecord?.id == id,
                  catalog.sourceID == sourceID else { return }
            nativeLiveCatalog = catalog
            liveEPGCatalogRevision = UUID()
        } catch {
            guard nativeLiveGeneration == generation,
                  nativeLiveCatalogRequestID == requestID,
                  activeConfigurationRecord?.id == id,
                  !AsyncCancellationPolicy.isCancellation(error) else { return }
            // Do not retain URLSession errors or credential-bearing request URLs
            // in published browser state. A prior safe snapshot can still be used.
            nativeLiveCatalogError = L10n.string(
                "xtream.live.catalog-failed",
                fallback: "Unable to load Live TV. Check the account and connection, then refresh."
            )
        }
    }

    private func invalidateXtreamLiveCatalog() {
        liveEPG.removeNativeSources()
        epgBrowserChannels = []
        scheduleEPGRefresh()
        nativeLiveGeneration = UUID()
        nativeLiveCatalogTask?.cancel()
        nativeLiveCatalogTask = nil
        nativeLiveCatalogRequestID = nil
        nativeLiveCatalog = nil
        nativeLiveCatalogError = nil
        liveCatalogLoadingSourceIDs = liveCatalogLoadingSourceIDs.filter {
            if case .xtream = $0 { return false }; return true
        }
    }

    /// Account/configuration mutations must not race a player that still owns
    /// a credential-bearing Xtream URL. `closePlayer` is itself ownership-safe
    /// and waits for an already-running close transition to finish.
    private func closeXtreamLivePlaybackIfNeeded(
        providerID: UUID? = nil
    ) async {
        guard case .xtream(let activeProviderID) = livePlaybackSourceID,
              providerID == nil || providerID == activeProviderID else {
            return
        }
        await closePlayer()
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    func seedFavoriteConfigurationsForTesting(_ records: [StoredConfiguration]) { configurations = records }

    func seedHistoryPlaybackForTesting(configuration: StoredConfiguration, videoID: String = "video", position: Double, duration: Double) {
        activeConfigurationRecord = configuration
        let episode = PlayEpisode(name: "Episode 1", url: "https://example.invalid/movie.mp4")
        let source = PlaySource(name: "Line", episodes: [episode])
        let detail = VideoDetail(summary: VideoSummary(siteKey: "fixture", siteName: "Fixture", videoID: videoID, title: "History Fixture"), playSources: [source])
        let request = UUID()
        activePlayerRequestID = request; playbackSessionID = request
        activePlayback = ActivePlaybackContext(configurationID: configuration.id, detail: detail, source: source, episode: episode,
            media: ResolvedMedia(url: URL(string: episode.url)!, headers: [:], siteKey: "fixture", sourceName: source.name, episodeName: episode.name), requestID: request)
        playerSnapshot = PlayerSnapshot(status: .playing, position: position, duration: duration)
        historyProgressCheckpoint.reset(owner: request)
        historyProgressCheckpoint.observe(playerSnapshot, owner: request)
    }
    func changeHistoryProgressForTesting(position: Double, duration: Double) {
        playerSnapshot = PlayerSnapshot(status: .playing, position: position, duration: duration)
        historyProgressCheckpoint.observe(playerSnapshot, owner: activePlayerRequestID)
        schedulePlaybackHistorySave(position: position, duration: duration)
    }
    func transitionHistoryForTesting() {
        captureHistoryBeforePlaybackTransition()
        activePlayerRequestID = UUID(); activePlayback = nil
        playerSnapshot = PlayerSnapshot()
    }
    func qualityOwnershipForTesting() {
        let request = UUID()
        activePlayerRequestID = request; activePlayback?.requestID = request
        historyProgressCheckpoint.transferOwnership(to: request)
    }
    func finishHistoryForTesting() async { await finishScheduledHistoryPersistence() }

    func seedCategoryHomeForTesting(record: StoredConfiguration, provider: SiteProvider, home: SiteHome) {
        cancelAllCategoryRequestTasks()
        activeConfigurationRecord = record
        activeConfiguration = FongMiConfiguration(sites: [provider.site])
        providers = [provider.site.key: provider]
        selectedSiteKey = provider.site.key
        publishHomeContent(home, identity: HomeContentIdentity(configurationID: record.id, siteKey: provider.site.key))
        hasCompletedStartup = true
    }

    func setLiveConfigurationForTesting(_ record: StoredConfiguration?, providers: [String: SiteProvider], preservingDetailRoute: Bool = false) {
        preservesDetailRouteOnProviderReplacement = preservingDetailRoute
        defer { preservesDetailRouteOnProviderReplacement = false }
        invalidateXtreamLiveCatalog()
        activeConfigurationRecord = record
        activeConfiguration = record.flatMap { try? XtreamProviderConfiguration(data: $0.rawData).providerConfiguration }
        self.providers = providers
    }
    #endif

    func loadLiveSource(_ source: StoredLiveSource) async {
        guard environment != nil else { return }
        cancelLiveSourceValidation(source.id)
        if importedIdentityEnabled {
            guard !deletingImportedSourceIDs.contains(source.id), liveSources.contains(where: { $0.id == source.id }) else { return }
        }
        liveCatalogLoadingSourceIDs.insert(.imported(source.id))
        isLoading = true
        defer {
            isLoading = false
            liveCatalogLoadingSourceIDs.remove(.imported(source.id))
        }
        do {
            let playlist = try LiveSourceParser().parse(
                source.rawData,
                baseURL: source.baseURL
            )
            publishImportedCatalog(playlist, sourceID: source.id)
            if importedIdentityEnabled, let generation = importedIdentityGeneration, generation.sourceID == source.id {
                await refreshImportedIdentityMapping(source.id, generation: generation)
                guard generation.isCurrent, !deletingImportedSourceIDs.contains(source.id),
                      liveSources.contains(where: { $0.id == source.id }) else { return }
            }
            startLiveSourceBackgroundWork(for: source, playlist: playlist)
        } catch {
            show(error, title: L10n.string("live.source.load.failed", fallback: "Live TV Source Failed to Load"))
        }
    }

    func refreshLiveSource(_ id: UUID) async {
        guard !deletingImportedSourceIDs.contains(id) else { return }
        // Even a refresh that cannot start must terminate the previous check.
        cancelLiveSourceValidation(id)
        guard let environment,
              let existing = liveSources.first(where: { $0.id == id }) else {
            return
        }
        guard existing.sourceKind == .remote,
              let value = existing.sourceValue,
              let url = URL(string: value) else {
            show(
                AppError.live(L10n.string("live.refresh.remote-only", fallback: "Only URL Live TV sources can be refreshed directly")),
                title: L10n.string("common.refresh.failed", fallback: "Unable to Refresh")
            )
            return
        }
        var identityGeneration: ImportedCatalogGeneration?
        if importedIdentityEnabled {
            guard importedIdentitySource == .imported(id) else { return }
            importedRefreshDownloads[id]?.cancel()
            importedIdentityGeneration?.invalidate()
            let generation = ImportedCatalogGeneration(sourceID: id)
            importedIdentityGeneration = generation
            identityGeneration = generation
            importedIdentityMapping = nil
            importedIdentityMappingFailed = false
        }
        liveCatalogLoadingSourceIDs.insert(.imported(id))
        isLoading = true
        defer {
            if identityGeneration == nil || importedIdentityGeneration === identityGeneration {
                isLoading = false
                liveCatalogLoadingSourceIDs.remove(.imported(id))
                importedRefreshDownloads[id] = nil
            }
        }
        do {
            let loaded: LoadedLiveSource
            if identityGeneration != nil {
                let download = Task { try await environment.liveSourceLoader.load(.remote(url)) }
                importedRefreshDownloads[id] = download
                loaded = try await withTaskCancellationHandler(operation: { try await download.value }, onCancel: { download.cancel() })
            } else {
                loaded = try await environment.liveSourceLoader.load(.remote(url))
            }
            if let identityGeneration, !identityGeneration.isCurrent { return }
            let updated = StoredLiveSource(
                id: existing.id,
                name: existing.name,
                sourceKind: .remote,
                sourceValue: value,
                baseURL: loaded.baseURL,
                rawData: loaded.rawData,
                updatedAt: loaded.loadedAt
            )
            if let identityGeneration {
                try await environment.database.acceptImportedRefresh(updated, generation: identityGeneration)
                guard identityGeneration.isCurrent else { return }
            } else {
                try await environment.database.saveLiveSource(updated)
            }
            liveSources = try await environment.database.liveSources()
            if let identityGeneration, !identityGeneration.isCurrent { return }
            publishImportedCatalog(loaded.playlist, sourceID: id)
            if let identityGeneration {
                await refreshImportedIdentityMapping(id, generation: identityGeneration)
                guard identityGeneration.isCurrent else { return }
            }
            epgFailures[id] = nil
            startLiveSourceBackgroundWork(for: updated, playlist: loaded.playlist)
        } catch {
            if let identityGeneration, !identityGeneration.isCurrent { return }
            // Failed refresh is not an empty catalog. Recompute authority from
            // the unchanged stored catalog under the new live generation.
            if let identityGeneration { await refreshImportedIdentityMapping(id, generation: identityGeneration) }
            show(error, title: L10n.string("live.refresh.failed", fallback: "Live TV Source Refresh Failed"))
        }
    }

    func deleteLiveSource(_ id: UUID) async {
        if importedIdentityEnabled {
            await retireImportedLiveSource(id)
            return
        }
        guard let environment, deletingImportedSourceIDs.insert(id).inserted else { return }
        revokeImportedPlaybackFlow(id)
        defer { deletingImportedSourceIDs.remove(id) }
        cancelLiveSourceValidation(id)
        liveValidationActivity.clear(id)
        liveValidationFreshness.remove(id)
        liveSourceEPGStatuses[id] = nil
        do {
            try await environment.database.deleteLiveSource(id: id)
            liveSources = try await environment.database.liveSources()
            publishImportedCatalog(nil, sourceID: id)
            liveEPG.remove(.imported(id))
            await environment.productionEPGRepository.invalidate(EPGSourceKey(.imported(id)))
            scheduleEPGRefresh()
            epgFailures[id] = nil
            let previousDeletedIDs = deletedLiveChannelIDs
            deletedLiveChannelIDs = LiveChannelDeletionPolicy.removingSource(
                id,
                from: deletedLiveChannelIDs
            )
            if deletedLiveChannelIDs != previousDeletedIDs {
                do {
                    try await persistDeletedLiveChannels()
                } catch {
                    // The source has already been deleted successfully. Keep
                    // the in-memory cleanup and avoid reporting the source
                    // deletion itself as failed because of stale-ID cleanup.
                }
            }
        } catch {
            show(error, title: L10n.string("live.delete-source.failed", fallback: "Live TV Source Deletion Failed"))
        }
    }

    private func retireImportedLiveSource(_ id: UUID) async {
        guard let database = liveReferenceStore, liveSources.contains(where: { $0.id == id }),
              deletingImportedSourceIDs.insert(id).inserted else { return }
        revokeImportedPlaybackFlow(id)
        // Barrier is installed BEFORE the first await. No UI path may mint a
        // replacement capability until retirement succeeds or fails.
        let wasCurrent = importedIdentitySource == .imported(id)
        let revoked = wasCurrent ? (importedIdentityGeneration ?? ImportedCatalogGeneration(sourceID: id)) : ImportedCatalogGeneration(sourceID: id)
        revoked.invalidate()
        if wasCurrent { importedIdentityMapping = nil; importedIdentityGeneration = nil }
        importedRefreshDownloads[id]?.cancel(); importedRefreshDownloads[id] = nil
        cancelLiveSourceValidation(id)
        defer { deletingImportedSourceIDs.remove(id) }
        do {
            #if DEBUG || OKVIDEO_PERFORMANCE_TEST
            try await importedRetirementBeforeTransactionForTesting?()
            #endif
            try await database.retireImportedSource(id: id, revokedGeneration: revoked)
        } catch {
            deletingImportedSourceIDs.remove(id)
            // SQL rollback does NOT roll back revocation. Only the current
            // source gets a NEW capability; never disturb a switch to B.
            if importedIdentitySource == .imported(id) {
                let replacement = ImportedCatalogGeneration(sourceID: id)
                importedIdentityGeneration = replacement
                importedIdentityMappingFailed = false
                await refreshImportedIdentityMapping(id, generation: replacement)
            }
            show(error, title: L10n.string("live.delete-source.failed", fallback: "Live TV Source Deletion Failed"))
            return
        }
        liveSources.removeAll { $0.id == id }
        publishImportedCatalog(nil, sourceID: id)
        liveValidationActivity.clear(id)
        liveValidationFreshness.remove(id)
        liveSourceEPGStatuses[id] = nil
        liveCatalogLoadingSourceIDs.remove(.imported(id))
        if importedIdentitySource == .imported(id) {
            importedIdentitySource = nil; importedIdentityGeneration = nil
            importedIdentityMapping = nil; importedIdentityMappingFailed = false
            isLoading = false
        }
        // Existing post-delete EPG cleanup is retained; no EPG engine change.
        liveEPG.remove(.imported(id))
        if let environment { await environment.productionEPGRepository.invalidate(EPGSourceKey(.imported(id))) }
        scheduleEPGRefresh()
        epgFailures[id] = nil
        // Legacy arrays are historical evidence. No legacy cleanup writes here.
    }

    private func startLiveSourceBackgroundWork(
        for source: StoredLiveSource,
        playlist: LivePlaylist
    ) {
        if importedIdentityEnabled {
            guard !deletingImportedSourceIDs.contains(source.id), liveSources.contains(where: { $0.id == source.id }) else { return }
        }
        liveEPGCatalogRevision = UUID()
        if let revision = epgRevision(for: .imported(source.id)) {
            liveEPG.prepare(source: .imported(source.id), revision: revision)
        }
        if resolvedEPGSource(for: .imported(source.id)) == nil {
            liveEPG.remove(.imported(source.id))
            epgFailures[source.id] = nil
            liveSourceEPGStatuses[source.id] = nil
        } else {
            liveSourceEPGStatuses[source.id] = .loading
            epgInitialSourceID = source.id
        }
        scheduleEPGRefresh()
        if !liveValidationFreshness.isFresh(source) {
            startInitialLiveSourceValidation(
                sourceID: source.id,
                playlist: playlist
            )
        }
    }

    private func cancelLiveSourceValidation(_ sourceID: UUID, expectedRunID: UUID? = nil, budgetExceeded: Bool = false) {
        guard let permit = liveValidationPermits[sourceID],
              expectedRunID == nil || permit.id == expectedRunID else { return }
        // If COMMIT won the race, report its outcome instead of claiming cancel.
        guard permit.cancel() else { return }
        liveSourceValidationTasks[sourceID]?.cancel()
        liveValidationDeadlines[sourceID]?.cancel()
        let latest = liveValidationProgressRelays[sourceID]?.close()
        switch liveSourceValidationStatuses[sourceID] {
        case .checking(let done, let total), .processing(let done, let total):
            let count = max(done, latest?.completed ?? done)
            liveValidationActivity.transition(budgetExceeded
                ? .partial(completed: count, total: total) : .cancelled(completed: count, total: total),
                sourceID: sourceID, runID: permit.id)
        default: break
        }
    }

    private func startInitialLiveSourceValidation(sourceID: UUID, playlist: LivePlaylist) {
        cancelLiveSourceValidation(sourceID)
        guard !epgSleeping, !isShutdownRequested, !deletingImportedSourceIDs.contains(sourceID),
              let source = liveSources.first(where: { $0.id == sourceID }) else { return }
        let channels = playlist.groups.flatMap(\.channels)
        let permit = LiveValidationPermit(sourceID: sourceID)
        liveValidationPermits[sourceID] = permit
        liveValidationProgressRelays[sourceID]?.close()
        liveValidationActivity.begin(sourceID: sourceID, runID: permit.id, total: channels.count)
        let relay = ValidationProgressRelay(sourceID: sourceID, runID: permit.id, total: channels.count) { [weak self] value in
            guard let self, self.liveValidationPermits[value.sourceID]?.id == value.runID,
                  self.liveValidationPermits[value.sourceID]?.isCancelled == false else { return }
            self.liveValidationActivity.accept(value)
        }
        liveValidationProgressRelays[sourceID] = relay
        let service = liveValidationService
        liveValidationDeadlines[sourceID]?.cancel()
        liveValidationDeadlines[sourceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(service.maximumRunDuration * 1_000_000_000)) }
            catch { return }
            self?.cancelLiveSourceValidation(sourceID, expectedRunID: permit.id, budgetExceeded: true)
        }
        liveSourceValidationTasks[sourceID] = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                relay.close()
                // An older finally cannot remove its replacement's handle.
                if self.liveValidationPermits[sourceID] === permit {
                    self.liveSourceValidationTasks[sourceID] = nil
                    self.liveValidationDeadlines[sourceID]?.cancel()
                    self.liveValidationDeadlines[sourceID] = nil
                    self.liveValidationPermits[sourceID] = nil
                    self.liveValidationProgressRelays[sourceID] = nil
                }
            }
            let result = await service.run(channels: channels, permit: permit) { done, total in
                relay.submit(completed: done, total: total)
            }
            relay.close()
            guard self.liveValidationPermits[sourceID] === permit else { return }
            switch result.end {
            case .cancelled:
                if case .checking = self.liveSourceValidationStatuses[sourceID] {
                    self.liveValidationActivity.transition(.cancelled(completed: result.completed, total: result.total), sourceID: sourceID, runID: permit.id)
                }
                return
            case .budgetExceeded:
                self.liveValidationActivity.transition(.partial(completed: result.completed, total: result.total), sourceID: sourceID, runID: permit.id)
                return
            case .complete: break
            }
            guard !Task.isCancelled, !permit.isCancelled, !self.deletingImportedSourceIDs.contains(sourceID),
                  self.liveSources.contains(where: { $0.id == sourceID }) else { return }
            self.liveValidationActivity.transition(.processing(completed: result.completed, total: result.total), sourceID: sourceID, runID: permit.id)
            do {
                #if DEBUG || OKVIDEO_PERFORMANCE_TEST
                try await self.liveValidationBeforeWriteForTesting?()
                #endif
                try await self.applyAutomaticallyUnavailableLiveChannels(result.unavailableIDs,
                    source: source, channels: channels, permit: permit)
                guard self.liveValidationPermits[sourceID] === permit,
                      self.liveSources.contains(where: { $0.id == sourceID }) else { return }
                self.liveValidationActivity.transition(.completed(removed: result.unavailableIDs.count, total: result.total), sourceID: sourceID, runID: permit.id)
                self.liveValidationFreshness.markCompleted(source)
            } catch {
                guard self.liveValidationPermits[sourceID] === permit else { return }
                if permit.isCancelled || Task.isCancelled {
                    if case .processing = self.liveSourceValidationStatuses[sourceID] {
                        self.liveValidationActivity.transition(.cancelled(completed: result.completed, total: result.total), sourceID: sourceID, runID: permit.id)
                    }
                } else {
                    self.liveValidationActivity.transition(.failed(self.localizedRuntimeErrorMessage(error)), sourceID: sourceID, runID: permit.id)
                }
            }
        }
    }

    private func applyAutomaticallyUnavailableLiveChannels(_ channelIDs: Set<String>,
        source: StoredLiveSource, channels: [LiveChannel], permit: LiveValidationPermit) async throws {
        guard !Task.isCancelled, !permit.isCancelled, liveValidationPermits[source.id] === permit,
              !deletingImportedSourceIDs.contains(source.id) else { throw CancellationError() }
        guard !channelIDs.isEmpty else { try permit.commit {}; return }
        let affected = channels.filter { channelIDs.contains($0.id) }
        if importedIdentityEnabled {
            try await editImportedIdentityReferences(source.id, edits: affected.flatMap {
                [(channel: $0, kind: MigrationReferenceKind.hidden, present: true),
                 (channel: $0, kind: MigrationReferenceKind.favorite, present: false)]
            }, validationPermit: permit)
            return
        }
        guard let database = liveReferenceStore else { throw ImportedExecutionError.blocked }
        let updated = try await database.applyLegacyLiveValidation(source: source, channels: affected, permit: permit)
        guard liveValidationPermits[source.id] === permit else { return }
        deletedLiveChannelIDs = updated.hidden
        favoriteLiveChannelIDs = updated.favorites
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    var liveValidationBeforeWriteForTesting: (() async throws -> Void)?
    func startLiveValidationForTesting(sourceID: UUID, playlist: LivePlaylist, service: LiveValidationService) {
        self.liveValidationService = service
        startInitialLiveSourceValidation(sourceID: sourceID, playlist: playlist)
    }
    func cancelLiveValidationForTesting(_ sourceID: UUID) { cancelLiveSourceValidation(sourceID) }
    func liveValidationRunIDForTesting(_ sourceID: UUID) -> UUID? { liveValidationPermits[sourceID]?.id }
    func liveValidationRelayForTesting(_ sourceID: UUID) -> ValidationProgressRelay? { liveValidationProgressRelays[sourceID] }
    #endif
    func playLive(
        channel: LiveChannel,
        stream: LiveStream,
        sourceID: LiveSourceID,
        navigationChannels: [LiveChannel]? = nil,
        windowActivation: PlayerWindowActivationPolicy = .userInitiated
    ) async {
        // Raw stream entry is Native-only. Imported callers carry a channel-
        // bound selection captured from an accepted catalog.
        guard sourceID.isXtream else { return }
        let context = LivePlaybackNavigationContext(
            sourceID: sourceID,
            channels: LiveChannelNavigationPolicy.normalizedChannels(
                navigationChannels ?? [channel], including: channel
            )
        )
        await beginLivePlayback(channel: channel, stream: stream, context: context, windowActivation: windowActivation)
    }

    func playImportedLive(
        _ selection: ImportedRouteSelection,
        navigationChannels: [LiveChannel],
        windowActivation: PlayerWindowActivationPolicy = .userInitiated
    ) async {
        guard acceptedImportedCatalogs[selection.catalog.sourceID] === selection.catalog,
              presentedLiveCatalog(for: .imported(selection.catalog.sourceID)) != nil else { return }
        // Playback owns the network budget. A future refresh can resume an
        // incomplete health pass; the current stream must not compete with it.
        cancelLiveSourceValidation(selection.catalog.sourceID)
        await beginImportedLive(selection, navigationChannels: navigationChannels, windowActivation: windowActivation)
    }

    private func importedPlaybackSourceIsActive(_ id: UUID) -> Bool {
        !deletingImportedSourceIDs.contains(id) && liveSources.contains { $0.id == id }
    }

    private func revokeImportedPlaybackFlow(_ id: UUID) {
        guard livePlaybackNavigationContext?.sourceID == .imported(id) else { return }
        livePlaybackNavigationContext = nil
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        livePlaybackNotice = nil
        isRecoveringLivePlayback = false
        // An already playing stream is not stopped. Only its permission to
        // initiate another route dies; SQL rollback cannot revive this flow.
    }

    private func beginImportedLive(
        _ selection: ImportedRouteSelection,
        navigationChannels: [LiveChannel],
        windowActivation: PlayerWindowActivationPolicy
    ) async {
        guard importedPlaybackSourceIsActive(selection.catalog.sourceID),
              selection.catalog.selection(for: selection.channel, key: selection.id) != nil,
              navigationChannels.contains(selection.channel),
              navigationChannels.allSatisfy(selection.catalog.contains),
              Set(navigationChannels.map(\.id)).count == navigationChannels.count else { return }
        let context = LivePlaybackNavigationContext(
            sourceID: .imported(selection.catalog.sourceID), channels: navigationChannels,
            importedCatalog: selection.catalog
        )
        await beginLivePlayback(channel: selection.channel, stream: selection.stream, context: context, windowActivation: windowActivation)
    }

    private func ownsLiveFlow(_ context: LivePlaybackNavigationContext) -> Bool {
        livePlaybackNavigationContext === context && !isShutdownRequested && !isClosingPlayer
    }

    private func liveFlowMayLoad(_ context: LivePlaybackNavigationContext) -> Bool {
        guard ownsLiveFlow(context) else { return false }
        if case .imported(let id) = context.sourceID { return importedPlaybackSourceIsActive(id) }
        return true
    }

    private var hasLivePlaybackLoader: Bool {
        #if DEBUG || OKVIDEO_PERFORMANCE_TEST
        if importedRouteLoadForTesting != nil { return true }
        #endif
        return environment != nil
    }

    private func beginLivePlayback(
        channel: LiveChannel,
        stream: LiveStream,
        context: LivePlaybackNavigationContext,
        windowActivation: PlayerWindowActivationPolicy
    ) async {
        guard !isShutdownRequested, !isClosingPlayer, hasLivePlaybackLoader else { return }
        let sourceID = context.sourceID
        if case .xtream(let providerID) = sourceID {
            guard xtreamProviderOperationID == nil,
                  configurationImportOperationID == nil,
                  requestedConfigurationID == nil,
                  !nativeLiveAccountMutationIDs.contains(providerID),
                  let record = activeConfigurationRecord,
                  record.id == providerID,
                  record.sourceKind == .xtream,
                  let descriptor = try? XtreamProviderConfiguration(
                    data: record.rawData
                  ),
                  descriptor.providerID == providerID else {
                show(
                    XtreamLivePlaybackError.unavailableAccount,
                    title: L10n.string(
                        "player.stage.failed", fallback: "Playback Failed"
                    )
                )
                return
            }
        }
        historyPlaybackTask?.cancel()
        historyPlaybackTask = nil
        historyPlaybackPreparationID = UUID()
        historyPlaybackLoadingID = nil
        historyPlaybackRequestedItem = nil
        historyPlaybackChoices = []
        clearPlayerEpisodeListRecovery()
        let clickRequestID = UUID()
        if let environment {
            PlayerStartupTraceStore.shared.begin(requestID: clickRequestID, mode: environment.player.mode)
        }
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        livePlaybackNotice = nil
        hasExhaustedLivePlayback = false
        playbackResolutionState = .idle
        playbackFailureSummary = nil
        playerPresentedError = nil
        livePlaybackAttemptedIdentifiers = []
        livePlaybackNavigationContext = context

        captureHistoryBeforePlaybackTransition()
        activePlayback = nil
        pendingPlayback = nil
        pendingNodePlaybackConfigurationFallback = nil
        livePlaybackChannel = channel
        livePlaybackStream = stream
        livePlaybackSourceID = sourceID
        playbackQualitySwitchSessionID = UUID()
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        playbackSessionID = clickRequestID
        activePlayerRequestID = clickRequestID
        isPlayerRenderSurfaceMountEnabled = true
        #if DEBUG || OKVIDEO_PERFORMANCE_TEST
        if importedRouteLoadForTesting != nil {
            isPlayerPresented = true
        } else {
            presentPlayer(requestID: clickRequestID, activation: windowActivation)
        }
        #else
        presentPlayer(requestID: clickRequestID, activation: windowActivation)
        #endif
        await attemptLivePlaybackCandidates(
            startingChannel: channel,
            startingStream: stream,
            sourceID: sourceID,
            isAutomaticRecovery: false,
            initialRequestID: clickRequestID,
            context: context
        )
    }

    func switchLiveChannel(by offset: Int) async {
        guard !isShutdownRequested,
              isPlayerPresented,
              let currentChannel = livePlaybackChannel,
              let sourceID = livePlaybackSourceID,
              let context = livePlaybackNavigationContext,
              context.sourceID == sourceID,
              let targetChannel = LiveChannelNavigationPolicy.adjacentChannel(
                  in: context.channels,
                  currentChannelID: currentChannel.id,
                  offset: offset
              ),
              let targetStream = targetChannel.streams.first else {
            return
        }
        if let catalog = context.importedCatalog {
            guard liveFlowMayLoad(context), let selection = catalog.selections(for: targetChannel).first else { return }
            // Navigation explicitly remains in the playing snapshot.
            await beginImportedLive(selection, navigationChannels: context.channels, windowActivation: .preserveFocus)
            return
        }
        await playLive(
            channel: targetChannel,
            stream: targetStream,
            sourceID: sourceID,
            navigationChannels: context.channels,
            windowActivation: .preserveFocus
        )
    }

    private func attemptLivePlaybackCandidates(
        startingChannel: LiveChannel,
        startingStream: LiveStream,
        sourceID: LiveSourceID,
        isAutomaticRecovery: Bool,
        initialRequestID: UUID? = nil,
        context: LivePlaybackNavigationContext
    ) async {
        guard hasLivePlaybackLoader, liveFlowMayLoad(context), context.sourceID == sourceID else {
            return
        }
        isRecoveringLivePlayback = true
        hasExhaustedLivePlayback = false
        let candidates: [LivePlaybackCandidate]
        if let catalog = context.importedCatalog {
            guard let key = catalog.routeContext?.key(for: startingStream),
                  let selection = catalog.selection(for: startingChannel, key: key) else {
                isRecoveringLivePlayback = false
                return
            }
            candidates = LivePlaybackRecoveryPolicy.importedCandidates(
                catalog: catalog, channels: context.channels, starting: selection,
                excluding: context.attemptedTransports
            )
        } else {
            candidates = LivePlaybackRecoveryPolicy.candidates(
                channels: context.channels, startingChannel: startingChannel,
                startingStream: startingStream, excluding: livePlaybackAttemptedIdentifiers,
                scope: .currentChannel
            )
        }
        var skippedCount = 0
        var pendingInitialRequestID = initialRequestID
        for candidate in candidates {
            guard ownsLiveFlow(context) else { return }
            guard liveFlowMayLoad(context), !Task.isCancelled,
                  !isShutdownRequested,
                  livePlaybackSourceID == sourceID,
                  isPlayerPresented else {
                isRecoveringLivePlayback = false
                return
            }
            if let transport = ImportedRouteTransport(candidate.stream), context.importedCatalog != nil {
                context.attemptedTransports.insert(transport)
            } else {
                livePlaybackAttemptedIdentifiers.insert(candidate.nativeIdentifier)
            }
            let requestID = pendingInitialRequestID ?? UUID()
            if pendingInitialRequestID == nil, let environment {
                PlayerStartupTraceStore.shared.begin(
                    requestID: requestID,
                    mode: environment.player.mode
                )
            }
            pendingInitialRequestID = nil
            playbackSessionID = requestID
            activePlayerRequestID = requestID
            livePlaybackChannel = candidate.channel
            livePlaybackStream = candidate.stream
            do {
                var media: ResolvedMedia
                switch (sourceID, candidate.stream.target) {
                case (.imported, .direct(let streamURL)):
                    media = ResolvedMedia(
                        url: streamURL,
                        headers: HTTPHeaders(candidate.stream.headers),
                        format: candidate.stream.format,
                        siteKey: "live",
                        sourceName: candidate.channel.name,
                        episodeName: candidate.stream.name
                    )
                case (.xtream, .provider(let reference)):
                    guard let environment else { throw CancellationError() }
                    // Xtream URLs contain account secrets. Release the prior
                    // media/client before reading Keychain and materializing a
                    // fresh URL, then keep that URL only in this stack frame.
                    _ = try await environment.player.prepareForPlayback(
                        requestID: requestID,
                        releasePolicy: .destroyBeforeLoad,
                        compatibilityPolicy: NativeXtreamCompatibility.policy
                    )
                    guard playbackSessionID == requestID,
                          activePlayerRequestID == requestID,
                          livePlaybackSourceID == sourceID,
                          isPlayerPresented else {
                        throw CancellationError()
                    }
                    media = try await resolveXtreamLiveMedia(
                        reference: reference,
                        sourceID: sourceID,
                        channel: candidate.channel,
                        stream: candidate.stream,
                        requestID: requestID
                    )
                default:
                    throw XtreamLivePlaybackError.invalidReference
                }
                // Prepare the first Native attempt too: a provider's .ts route
                // can redirect to a multi-variant HLS master. The bounded loader
                // stops non-HLS responses immediately, without reading a stream.
                let nativeAttemptStarted = ProcessInfo.processInfo.systemUptime
                if media.compatibilityPolicy == .nativeXtreamLive,
                   NativeXtreamCompatibility.hlsFallbackEnabled {
                    let preparationStarted = ProcessInfo.processInfo.systemUptime
                    media.hlsStartupSelection = try await prepareLiveHLS(media, requestID: requestID)
                    try Task.checkCancellation()
                    guard playbackSessionID == requestID,
                          activePlayerRequestID == requestID,
                          livePlaybackSourceID == sourceID, isPlayerPresented else {
                        throw CancellationError()
                    }
                    let preparationElapsed = max(0, ProcessInfo.processInfo.systemUptime - preparationStarted)
                    let preparationSeconds = Int(ceil(preparationElapsed))
                    media.nativeStartupBudgetSeconds = max(1, 60 - preparationSeconds)
                    if let environment {
                        PlayerExperimentLogger.performance(
                            "phase=live_hls_preparation elapsed_ms=\(Int(preparationElapsed * 1000))"
                                + " selected=\(media.hlsStartupSelection != nil)"
                                + " variants=\(media.hlsStartupSelection?.variantCount ?? 0)",
                            playerID: nil, requestID: requestID, mode: environment.player.mode
                        )
                    }
                }
                guard liveFlowMayLoad(context) else { throw CancellationError() }
                do {
                    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
                    if let loader = importedRouteLoadForTesting, context.importedCatalog != nil {
                        try await loader(candidate, media, requestID)
                    } else {
                        try await loadPlayerAfterRenderSurfaceReady(media, startPosition: nil, requestID: requestID, liveFlow: context)
                    }
                    #else
                    try await loadPlayerAfterRenderSurfaceReady(media, startPosition: nil, requestID: requestID, liveFlow: context)
                    #endif
                } catch {
                    // A reduced master is an optimization, not a new source.
                    // Retry the original once inside the same total budget if
                    // the chosen rendition cannot be opened. Never revive an
                    // old channel switch, cancellation or account failure.
                    guard media.hlsStartupSelection != nil,
                          !AsyncCancellationPolicy.isCancellation(error),
                          liveFlowMayLoad(context), playbackSessionID == requestID,
                          activePlayerRequestID == requestID, isPlayerPresented,
                          XtreamLivePlaybackFailurePolicy.permitsFormatFallback(after: error.localizedDescription) else {
                        throw error
                    }
                    let remaining = 60 - Int(ceil(ProcessInfo.processInfo.systemUptime - nativeAttemptStarted))
                    guard remaining > 0 else { throw error }
                    media.hlsStartupSelection = nil
                    media.nativeStartupBudgetSeconds = remaining
                    if let environment {
                        PlayerExperimentLogger.performance(
                            "phase=live_hls_original_fallback remaining_s=\(remaining)",
                            playerID: nil, requestID: requestID, mode: environment.player.mode
                        )
                    }
                    try await loadPlayerAfterRenderSurfaceReady(media, startPosition: nil, requestID: requestID, liveFlow: context)
                }
                guard ownsLiveFlow(context), playbackSessionID == requestID else { return }
                guard liveFlowMayLoad(context) else { throw CancellationError() }
                isRecoveringLivePlayback = false
                hasExhaustedLivePlayback = false
                if skippedCount > 0 || isAutomaticRecovery {
                    showLivePlaybackNotice(
                        L10n.string("live.skipped-invalid-stream", fallback: "Skipped an invalid stream and started playing %@", candidate.channel.name)
                    )
                }
                return
            } catch {
                PlayerStartupTraceStore.shared.cancel(requestID: requestID)
                guard ownsLiveFlow(context), playbackSessionID == requestID else { return }
                if AsyncCancellationPolicy.isCancellation(error) {
                    isRecoveringLivePlayback = false
                    return
                }
                skippedCount += 1
                if sourceID.isXtream,
                   !XtreamLivePlaybackFailurePolicy.permitsFormatFallback(
                    after: error.localizedDescription
                   ) {
                    finishExhaustedLivePlayback()
                    show(
                        error,
                        title: L10n.string(
                            "player.stage.failed", fallback: "Playback Failed"
                        ),
                        target: .player
                    )
                    return
                }
            }
        }
        guard ownsLiveFlow(context) else { return }
        finishExhaustedLivePlayback()
    }

    private func prepareLiveHLS(_ media: ResolvedMedia, requestID: UUID) async throws -> HLSStartupSelection? {
        liveHLSPreparationTask?.task.cancel()
        let task = Task { try await LiveHLSStartupPreparer().prepare(url: media.url, headers: media.headers) }
        liveHLSPreparationTask = (requestID, task)
        defer {
            if liveHLSPreparationTask?.requestID == requestID { liveHLSPreparationTask = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveXtreamLiveMedia(
        reference: PlaybackResourceReference,
        sourceID: LiveSourceID,
        channel: LiveChannel,
        stream: LiveStream,
        requestID: UUID
    ) async throws -> ResolvedMedia {
        guard let environment,
              let liveCredentialStore,
              case .xtream(let providerID) = sourceID,
              !nativeLiveAccountMutationIDs.contains(providerID),
              requestedConfigurationID == nil,
              configurationImportOperationID == nil,
              xtreamProviderOperationID == nil,
              activePlayerRequestID == requestID,
              playbackSessionID == requestID,
              livePlaybackSourceID == sourceID,
              let record = activeConfigurationRecord,
              record.id == providerID,
              record.sourceKind == .xtream,
              let descriptor = try? XtreamProviderConfiguration(
                data: record.rawData
              ),
              descriptor.providerID == providerID else {
            throw XtreamLivePlaybackError.staleRequest
        }
        let generation = nativeLiveGeneration
        guard let credentials = try await liveCredentialStore.credentials(
            for: providerID
        ) else {
            throw XtreamLivePlaybackError.unavailableAccount
        }
        try Task.checkCancellation()
        guard nativeLiveGeneration == generation,
              !nativeLiveAccountMutationIDs.contains(providerID),
              requestedConfigurationID == nil,
              configurationImportOperationID == nil,
              xtreamProviderOperationID == nil,
              activePlayerRequestID == requestID,
              playbackSessionID == requestID,
              livePlaybackSourceID == sourceID,
              activeConfigurationRecord?.id == providerID else {
            throw XtreamLivePlaybackError.staleRequest
        }
        let provider = try XtreamSiteProvider(
            configuration: descriptor,
            credentials: credentials,
            httpClient: environment.xtreamHTTPClient,
            userAgent: Self.xtreamUserAgent
        )
        try await provider.validateLivePlaybackAccount()
        try Task.checkCancellation()
        guard nativeLiveGeneration == generation,
              !nativeLiveAccountMutationIDs.contains(providerID),
              activePlayerRequestID == requestID,
              playbackSessionID == requestID,
              livePlaybackSourceID == sourceID,
              activeConfigurationRecord?.id == providerID else {
            throw XtreamLivePlaybackError.staleRequest
        }
        let result = try provider.resolveLivePlayback(reference)
        guard let url = URL(string: result.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw XtreamLivePlaybackError.invalidReference
        }
        guard nativeLiveGeneration == generation,
              activePlayerRequestID == requestID,
              playbackSessionID == requestID,
              livePlaybackSourceID == sourceID,
              activeConfigurationRecord?.id == providerID else {
            throw XtreamLivePlaybackError.staleRequest
        }
        return ResolvedMedia(
            url: url,
            headers: result.headers,
            format: result.format,
            siteKey: "xtream-live",
            sourceName: channel.name,
            episodeName: stream.name,
            compatibilityPolicy: NativeXtreamCompatibility.policy
        )
    }

    private func recoverLivePlaybackAfterFailure(
        requestID: UUID?,
        message: String? = nil
    ) {
        guard !isShutdownRequested,
              isPlayerPresented,
              !isRecoveringLivePlayback,
              livePlaybackRecoveryTask == nil,
              PlaybackRequestOwnershipPolicy.accepts(
                  requestID: requestID,
                  activeRequestID: activePlayerRequestID
              ),
              let channel = livePlaybackChannel,
              let stream = livePlaybackStream,
              let sourceID = livePlaybackSourceID,
              let context = livePlaybackNavigationContext,
              liveFlowMayLoad(context) else {
            return
        }
        if sourceID.isXtream,
           let message,
           !XtreamLivePlaybackFailurePolicy.permitsFormatFallback(
            after: message
           ) {
            finishExhaustedLivePlayback()
            show(
                AppError.playback(message),
                title: L10n.string(
                    "player.error.title", fallback: "Player Error"
                ),
                target: .player
            )
            return
        }
        livePlaybackRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.attemptLivePlaybackCandidates(
                startingChannel: channel,
                startingStream: stream,
                sourceID: sourceID,
                isAutomaticRecovery: true,
                context: context
            )
            if self.ownsLiveFlow(context) { self.livePlaybackRecoveryTask = nil }
        }
    }

    private func finishExhaustedLivePlayback() {
        isRecoveringLivePlayback = false
        hasExhaustedLivePlayback = true
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        livePlaybackNotice = nil
        playbackFailureSummary = L10n.string("live.channel-unavailable", fallback: "This channel could not be loaded. Try again or choose another channel.")
        playbackResolutionState = .failed
        playerSnapshot.status = .failed(playbackFailureSummary!)
    }

    private func showLivePlaybackNotice(_ message: String) {
        livePlaybackNoticeTask?.cancel()
        livePlaybackNotice = message
        let flowID = livePlaybackNavigationContext?.flowID
        livePlaybackNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self?.livePlaybackNavigationContext?.flowID == flowID else { return }
            self?.livePlaybackNotice = nil
            self?.livePlaybackNoticeTask = nil
        }
    }

    private func nativeChannelLocator(sourceID: LiveSourceID, channel: LiveChannel) -> XtreamLivePlaybackLocator? {
        guard case .xtream(let id) = sourceID else { return nil }
        return channel.streams.compactMap { stream -> XtreamLivePlaybackLocator? in
            guard case .provider(let reference) = stream.target,
                  let locator = reference.xtreamLiveLocator,
                  locator.providerID == id else { return nil }
            return locator
        }.first
    }

    func isLiveFavorite(sourceID: LiveSourceID, channel: LiveChannel) -> Bool {
        if importedIdentityEnabled, case .imported(let id) = sourceID {
            guard importedIdentityMapping?.sourceID == id else { return false }
            return importedIdentityMapping?.value(channel: channel, kind: .favorite) == true
        }
        switch sourceID {
        case .imported(let id):
            guard let source = liveSources.first(where: { $0.id == id }) else { return false }
            return isLiveFavorite(sourceName: source.name, channel: channel)
        case .xtream:
            guard let locator = nativeChannelLocator(sourceID: sourceID, channel: channel) else { return false }
            return nativeLiveFavorites.containsXtream(providerID: locator.providerID, streamID: locator.streamID)
        }
    }

    func toggleLiveFavorite(sourceID: LiveSourceID, channel: LiveChannel) async {
        if importedIdentityEnabled, case .imported(let id) = sourceID {
            do {
                guard let mapping = importedIdentityMapping, mapping.sourceID == id,
                      let value = mapping.value(channel: channel, kind: .favorite) else { throw ImportedExecutionError.blocked }
                try await editImportedIdentityReferences(id, edits: [(channel, .favorite, !value)])
            } catch { show(error, title: "无法保存频道收藏") }
            return
        }
        switch sourceID {
        case .imported(let id):
            guard let source = liveSources.first(where: { $0.id == id }) else { return }
            await toggleLiveFavorite(sourceName: source.name, channel: channel)
        case .xtream:
            guard let locator = nativeChannelLocator(sourceID: sourceID, channel: channel) else { return }
            await editNativeLiveReferences(hidden: false) { references in
                try references.setXtream(
                    providerID: locator.providerID, streamID: locator.streamID,
                    isIncluded: !references.containsXtream(providerID: locator.providerID, streamID: locator.streamID)
                )
            }
        }
    }

    func isLiveChannelDeleted(sourceID: LiveSourceID, channel: LiveChannel) -> Bool {
        switch sourceID {
        case .imported(let id): return isLiveChannelDeleted(sourceID: id, channel: channel)
        case .xtream:
            guard let locator = nativeChannelLocator(sourceID: sourceID, channel: channel) else { return false }
            return nativeLiveHiddenChannels.containsXtream(providerID: locator.providerID, streamID: locator.streamID)
        }
    }

    func deleteLiveChannel(sourceID: LiveSourceID, sourceName: String, channel: LiveChannel) async {
        switch sourceID {
        case .imported(let id): await deleteLiveChannel(sourceID: id, sourceName: sourceName, channel: channel)
        case .xtream:
            guard let locator = nativeChannelLocator(sourceID: sourceID, channel: channel) else { return }
            // Hiding a native channel preserves its stable favorite reference.
            await editNativeLiveReferences(hidden: true) { references in
                try references.setXtream(providerID: locator.providerID, streamID: locator.streamID, isIncluded: true)
            }
        }
    }

    func restoreDeletedLiveChannel(sourceID: LiveSourceID, channel: LiveChannel) async {
        switch sourceID {
        case .imported(let id): await restoreDeletedLiveChannel(sourceID: id, channel: channel)
        case .xtream:
            guard let locator = nativeChannelLocator(sourceID: sourceID, channel: channel) else { return }
            await editNativeLiveReferences(hidden: true) { references in
                try references.setXtream(providerID: locator.providerID, streamID: locator.streamID, isIncluded: false)
            }
        }
    }

    func restoreAllDeletedLiveChannels(sourceID: LiveSourceID) async {
        switch sourceID {
        case .imported(let id): await restoreAllDeletedLiveChannels(sourceID: id)
        case .xtream(let id):
            await editNativeLiveReferences(hidden: true) { references in
                for reference in references.references {
                    if case .xtream(let providerID, let streamID) = reference, providerID == id {
                        try references.setXtream(providerID: id, streamID: streamID, isIncluded: false)
                    }
                }
            }
        }
    }

    private func editNativeLiveReferences(
        hidden: Bool,
        edit: @escaping (inout StoredLiveChannelReferenceEnvelope) throws -> Void
    ) async {
        guard let liveReferenceStore else { return }
        // Serialize writes and publish only after SQLite succeeds. A late
        // failed save cannot roll back a more recent membership change.
        let previous = nativeLiveReferenceWriteTask
        let operationID = UUID()
        nativeLiveReferenceWriteID = operationID
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.isShutdownRequested else { return }
            do {
                var references = hidden ? self.nativeLiveHiddenChannels : self.nativeLiveFavorites
                try edit(&references)
                try await liveReferenceStore.setSetting(
                    references.setting,
                    forKey: hidden ? "live.hiddenReferences.v1" : "live.favoriteReferences.v1"
                )
                if hidden { self.nativeLiveHiddenChannels = references }
                else { self.nativeLiveFavorites = references }
            } catch {
                self.show(error, title: L10n.string("live.reference.save-failed", fallback: "Unable to Save Channel Preferences"))
            }
        }
        nativeLiveReferenceWriteTask = task
        await task.value
        if nativeLiveReferenceWriteID == operationID {
            nativeLiveReferenceWriteTask = nil
            nativeLiveReferenceWriteID = nil
        }
    }

    func isLiveFavorite(sourceName: String, channel: LiveChannel) -> Bool {
        if importedIdentityEnabled {
            let matches = liveSources.filter { $0.name == sourceName &&
                loadedLivePlaylists[$0.id]?.groups.flatMap(\.channels).contains(channel) == true }
            guard matches.count == 1 else { return false }
            return isLiveFavorite(sourceID: .imported(matches[0].id), channel: channel)
        }
        return favoriteLiveChannelIDs.contains(liveFavoriteID(sourceName: sourceName, channel: channel))
    }

    func isLiveChannelDeleted(
        sourceID: UUID,
        channel: LiveChannel
    ) -> Bool {
        if importedIdentityEnabled {
            guard importedIdentityMapping?.sourceID == sourceID else { return true }
            // Unknown authority must not reveal a previously claimed Hidden.
            return importedIdentityMapping?.value(channel: channel, kind: .hidden) ?? true
        }
        return LiveChannelDeletionPolicy.contains(
            deletedLiveChannelIDs,
            sourceID: sourceID,
            channelID: channel.id
        )
    }

    func deleteLiveChannel(
        sourceID: UUID,
        sourceName: String,
        channel: LiveChannel
    ) async {
        if importedIdentityEnabled {
            do { try await editImportedIdentityReferences(sourceID, edits: [(channel, .hidden, true), (channel, .favorite, false)]) }
            catch { show(error, title: "无法隐藏频道") }
            return
        }
        guard environment != nil else { return }
        let previousDeletedIDs = deletedLiveChannelIDs
        let previousFavoriteIDs = favoriteLiveChannelIDs
        deletedLiveChannelIDs.insert(
            LiveChannelDeletionPolicy.identifier(
                sourceID: sourceID,
                channelID: channel.id
            )
        )
        favoriteLiveChannelIDs.remove(
            liveFavoriteID(sourceName: sourceName, channel: channel)
        )
        do {
            try await persistDeletedLiveChannels()
            if favoriteLiveChannelIDs != previousFavoriteIDs {
                try await persistFavoriteLiveChannels()
            }
        } catch {
            deletedLiveChannelIDs = previousDeletedIDs
            favoriteLiveChannelIDs = previousFavoriteIDs
            try? await persistDeletedLiveChannels()
            try? await persistFavoriteLiveChannels()
            show(error, title: L10n.string("live.delete-channel.failed", fallback: "Unable to Delete Live TV Channel"))
        }
    }

    func restoreDeletedLiveChannel(
        sourceID: UUID,
        channel: LiveChannel
    ) async {
        if importedIdentityEnabled {
            do { try await editImportedIdentityReferences(sourceID, edits: [(channel, .hidden, false)]) }
            catch { show(error, title: "无法恢复频道") }
            return
        }
        let identifier = LiveChannelDeletionPolicy.identifier(
            sourceID: sourceID,
            channelID: channel.id
        )
        guard deletedLiveChannelIDs.remove(identifier) != nil else { return }
        do {
            try await persistDeletedLiveChannels()
        } catch {
            deletedLiveChannelIDs.insert(identifier)
            show(error, title: L10n.string("live.restore-channel.failed", fallback: "Unable to Restore Live TV Channel"))
        }
    }

    func restoreAllDeletedLiveChannels(sourceID: UUID) async {
        if importedIdentityEnabled {
            do {
                guard let channels = loadedLivePlaylists[sourceID]?.groups.flatMap(\.channels) else { throw ImportedExecutionError.blocked }
                try await editImportedIdentityReferences(sourceID, edits: channels.map { ($0, .hidden, false) })
            } catch { show(error, title: "无法恢复频道") }
            return
        }
        let previousDeletedIDs = deletedLiveChannelIDs
        deletedLiveChannelIDs = LiveChannelDeletionPolicy.removingSource(
            sourceID,
            from: deletedLiveChannelIDs
        )
        guard deletedLiveChannelIDs != previousDeletedIDs else { return }
        do {
            try await persistDeletedLiveChannels()
        } catch {
            deletedLiveChannelIDs = previousDeletedIDs
            show(error, title: L10n.string("live.restore-channel.failed", fallback: "Unable to Restore Live TV Channel"))
        }
    }

    func toggleLiveFavorite(sourceName: String, channel: LiveChannel) async {
        if importedIdentityEnabled {
            let matches = liveSources.filter { $0.name == sourceName &&
                loadedLivePlaylists[$0.id]?.groups.flatMap(\.channels).contains(channel) == true }
            guard matches.count == 1 else { return }
            await toggleLiveFavorite(sourceID: .imported(matches[0].id), channel: channel)
            return
        }
        guard environment != nil else { return }
        let id = liveFavoriteID(sourceName: sourceName, channel: channel)
        if favoriteLiveChannelIDs.contains(id) {
            favoriteLiveChannelIDs.remove(id)
        } else {
            favoriteLiveChannelIDs.insert(id)
        }
        do {
            try await persistFavoriteLiveChannels()
        } catch {
            show(error, title: L10n.string("live.favorite.save.failed", fallback: "Unable to Save Live TV Favorite"))
        }
    }

    func exportData(for record: StoredConfiguration, to url: URL) throws {
        do {
            try record.rawData.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw AppError.filesystem(L10n.string("configuration.export.failed-message", fallback: "Unable to export configuration: %@", error.localizedDescription))
        }
    }

    func exportPortableBackup(
        to url: URL
    ) async throws -> PortableBackupPreview {
        guard let environment, let configuration = activeConfigurationRecord else {
            throw AppError.configuration(L10n.string("configuration.import-enable-first", fallback: "Import and enable a video provider configuration first."))
        }
        let allHistory = try await environment.database.history()
        let history = allHistory.filter {
            $0.configurationID == configuration.id
        }
        let playbackSkipRules = try await environment.database
            .playbackSkipRules(configurationID: configuration.id)
        let playbackCompletionMarkers = try await environment.database
            .playbackCompletionMarkers(configurationID: configuration.id)
        let danmakuBindings = try await environment.database
            .danmakuBindings(configurationID: configuration.id)
        let scopedFavorites = try await environment.database.favorites().filter { $0.configurationID == configuration.id }
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? L10n.string("common.unknown", fallback: "Unknown")
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? L10n.string("common.unknown", fallback: "Unknown")
        let createdAt = Date()
        let data = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.encode(
                configuration: configuration,
                history: history,
                playbackSkipRules: playbackSkipRules,
                playbackCompletionMarkers: playbackCompletionMarkers,
                danmakuBindings: danmakuBindings,
                favorites: scopedFavorites,
                appVersion: appVersion,
                appBuild: appBuild,
                createdAt: createdAt
            )
        }.value
        try writePortableBackupData(data, to: url)
        return PortableBackupPreview(
            fileURL: url,
            createdAt: createdAt,
            appVersion: appVersion,
            appBuild: appBuild,
            configurationName: configuration.name,
            historyCount: history.count,
            favoriteCount: scopedFavorites.count
        )
    }

    func inspectPortableBackup(
        at url: URL
    ) async throws -> PortableBackupPreview {
        let data = try readPortableBackupData(from: url)
        let decoded = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.decode(data)
        }.value
        _ = try Self.configurationContent(
            for: decoded.payload.configuration.storedConfiguration
        )
        return PortableBackupPreview(
            fileURL: url,
            createdAt: decoded.manifest.createdAt,
            appVersion: decoded.manifest.appVersion,
            appBuild: decoded.manifest.appBuild,
            configurationName: decoded.payload.configuration.name,
            historyCount: decoded.payload.history.count,
            favoriteCount: decoded.payload.favorites?.count ?? 0
        )
    }

    func importPortableBackup(
        from url: URL
    ) async throws -> PortableBackupImportSummary {
        guard let environment else {
            throw AppError.configuration(L10n.string("app.environment.not-initialized", fallback: "The app environment has not been initialized"))
        }
        guard configurationImportOperationID == nil,
              xtreamProviderOperationID == nil,
              requestedConfigurationID == nil else {
            throw AppError.configuration(
                L10n.string(
                    "configuration.import.in-progress",
                    fallback: "Another configuration is already being imported. Wait for it to finish."
                )
            )
        }
        let operationID = UUID()
        configurationImportOperationID = operationID
        defer {
            if configurationImportOperationID == operationID {
                configurationImportOperationID = nil
            }
        }
        let data = try readPortableBackupData(from: url)
        let decoded = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.decode(data)
        }.value
        _ = try Self.configurationContent(
            for: decoded.payload.configuration.storedConfiguration
        )

        // Drain accepted favorite mutations before the recovery snapshot. New
        // mutations are blocked by configurationImportOperationID.
        await favoriteMutationTask?.value

        // A failed or unwanted merge must always have a user-owned recovery
        // point. This backup is written before the database transaction.
        let safetyBackupURL = try await createPreImportSafetyBackup()
        guard configurationImportOperationID == operationID else {
            throw CancellationError()
        }
        if livePlaybackSourceID?.isXtream == true {
            invalidateXtreamLiveCatalog()
            await closeXtreamLivePlaybackIfNeeded()
            guard configurationImportOperationID == operationID else {
                throw CancellationError()
            }
        }
        await favoriteMutationTask?.value
        let result = try await environment.database
            .restoreConfigurationAndHistory(
                configuration: decoded.payload.configuration.storedConfiguration,
                history: decoded.payload.history,
                favorites: decoded.payload.favorites
            )
        let importedConfigurationID = result.configuration.id
        let existingSkipRules = try await environment.database
            .playbackSkipRules(configurationID: importedConfigurationID)
        let existingSkipRulesByIdentity = Dictionary(
            uniqueKeysWithValues: existingSkipRules.map { ($0.identity, $0) }
        )
        for var rule in decoded.payload.playbackSkipRules {
            rule.identity.configurationID = importedConfigurationID
            if let existing = existingSkipRulesByIdentity[rule.identity],
               existing.updatedAt >= rule.updatedAt {
                continue
            }
            try await environment.database.savePlaybackSkipRule(rule)
        }
        let oldConfigurationPrefix = decoded.payload.configuration.id
            .uuidString.lowercased() + "::"
        let newConfigurationPrefix = importedConfigurationID
            .uuidString.lowercased() + "::"
        let existingCompletionMarkers = try await environment.database
            .playbackCompletionMarkers(configurationID: importedConfigurationID)
        let existingCompletionMarkersByIdentity = Dictionary(
            uniqueKeysWithValues: existingCompletionMarkers.map {
                ($0.identity, $0)
            }
        )
        for var marker in decoded.payload.playbackCompletionMarkers {
            marker.identity.configurationID = importedConfigurationID
            if marker.historyRecordID.hasPrefix(oldConfigurationPrefix) {
                marker.historyRecordID = newConfigurationPrefix
                    + marker.historyRecordID.dropFirst(
                        oldConfigurationPrefix.count
                    )
            }
            if let existing = existingCompletionMarkersByIdentity[
                marker.identity
            ], existing.completedAt >= marker.completedAt {
                continue
            }
            try await environment.database.savePlaybackCompletionMarker(marker)
        }
        let existingDanmakuBindings = try await environment.database
            .danmakuBindings(configurationID: importedConfigurationID)
        let existingDanmakuBindingsByIdentity = Dictionary(
            uniqueKeysWithValues: existingDanmakuBindings.map {
                ($0.editionIdentity, $0)
            }
        )
        for var binding in decoded.payload.danmakuBindings {
            binding.editionIdentity.episode.content.configurationID
                = importedConfigurationID
            if let existing = existingDanmakuBindingsByIdentity[
                binding.editionIdentity
            ], existing.updatedAt >= binding.updatedAt {
                continue
            }
            try await environment.database.saveDanmakuBinding(binding)
        }

        cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
        resetSearchForConfigurationChange()
        configurationRefreshSessionID = UUID()
        configurationRefreshTask?.cancel()
        configurationRefreshTask = nil
        configurations = result.configurations
        activeConfigurationRecord = result.configuration
        activeXtreamCredentials = try? await xtreamCredentials(
            for: result.configuration
        )
        activeNodeRuntimeEndpoint = nil
        nodeRuntimeUnavailableReason = L10n.string("node.runtime.prepares-on-demand", fallback: "Node Runtime will be prepared when the configuration is used")
        try loadActiveConfigurationContent()
        if let sourceURL = activeNodeRuntimeSourceURL {
            scheduleNodeConfigurationPreparation(
                recordID: result.configuration.id,
                sourceURL: sourceURL
            )
        } else {
            scheduleNodeRuntimeStop(for: result.configuration.id)
        }
        await loadSearchSiteScope()
        _ = await prepareActiveConfigurationHome(
            reportLoadErrors: false,
            entryReason: .configurationSwitch
        )
        try await reloadHistory()

        await refreshFavoritesPresentation()
        return PortableBackupImportSummary(
            configurationName: result.configuration.name,
            historyCount: result.consideredHistoryCount,
            changedHistoryCount: result.changedHistoryCount,
            safetyBackupURL: safetyBackupURL
        )
    }

    private func createPreImportSafetyBackup() async throws -> URL? {
        guard let environment, let configuration = activeConfigurationRecord else {
            return nil
        }
        let allHistory = try await environment.database.history()
        let history = allHistory.filter {
            $0.configurationID == configuration.id
        }
        let playbackSkipRules = try await environment.database
            .playbackSkipRules(configurationID: configuration.id)
        let playbackCompletionMarkers = try await environment.database
            .playbackCompletionMarkers(configurationID: configuration.id)
        let danmakuBindings = try await environment.database
            .danmakuBindings(configurationID: configuration.id)
        let scopedFavorites = try await environment.database.favorites().filter { $0.configurationID == configuration.id }
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? L10n.string("common.unknown", fallback: "Unknown")
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? L10n.string("common.unknown", fallback: "Unknown")
        let data = try await Task.detached(priority: .utility) {
            try PortableBackupCodec.encode(
                configuration: configuration,
                history: history,
                playbackSkipRules: playbackSkipRules,
                playbackCompletionMarkers: playbackCompletionMarkers,
                danmakuBindings: danmakuBindings,
                favorites: scopedFavorites,
                appVersion: appVersion,
                appBuild: appBuild
            )
        }.value
        let directory = environment.directories.applicationSupport
            .appendingPathComponent("Backups", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = directory.appendingPathComponent(
                "BeforeImport-\(formatter.string(from: Date())).okvideobackup"
            )
            try writePortableBackupData(data, to: url)
            try pruneSafetyBackups(in: directory, keeping: 5)
            return url
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.filesystem(
                L10n.string("backup.safety-create.failed", fallback: "Unable to create a safety backup before import: %@", error.localizedDescription)
            )
        }
    }

    private func pruneSafetyBackups(
        in directory: URL,
        keeping limit: Int
    ) throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("BeforeImport-")
                && $0.pathExtension == "okvideobackup"
        }.sorted {
            let left = (try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in files.dropFirst(max(1, limit)) {
            try fileManager.removeItem(at: url)
        }
    }

    private func readPortableBackupData(from url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            if let size = attributes[.size] as? NSNumber,
               size.intValue > PortableBackupCodec.maximumArchiveByteCount {
                throw PortableBackupError.fileTooLarge
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as PortableBackupError {
            throw error
        } catch {
            throw AppError.filesystem(
                L10n.string(
                    "backup.read.failed",
                    fallback: "Unable to read the backup file: %@",
                    error.localizedDescription
                )
            )
        }
    }

    private func writePortableBackupData(
        _ data: Data,
        to url: URL
    ) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw AppError.filesystem(
                L10n.string(
                    "backup.write.failed",
                    fallback: "Unable to write the backup file: %@",
                    error.localizedDescription
                )
            )
        }
    }

    func setIncognitoMode(_ enabled: Bool) async {
        guard let environment else { return }
        do {
            try await environment.database.setSetting(
                .bool(enabled),
                forKey: "privacy.incognito"
            )
            incognitoMode = enabled
        } catch {
            show(error, title: L10n.string("settings.privacy.save.failed", fallback: "Unable to Save Private Mode Setting"))
        }
    }

    func setHistoryRetentionDays(_ days: Int) async {
        guard let environment else { return }
        let bounded = min(max(days, 1), 3_650)
        do {
            try await environment.database.setSetting(
                .integer(Int64(bounded)),
                forKey: "history.retentionDays"
            )
            historyRetentionDays = bounded
            try await reloadUserData()
        } catch {
            show(error, title: L10n.string("settings.history.save.failed", fallback: "Unable to Save History Setting"))
        }
    }

    func setAppTheme(_ theme: AppTheme) async {
        guard let environment else { return }
        do {
            try await environment.database.setSetting(
                .string(theme.rawValue),
                forKey: "appearance.theme"
            )
            appTheme = theme
        } catch {
            show(error, title: L10n.string("settings.theme.save.failed", fallback: "Unable to Save Theme Setting"))
        }
    }

    func setAutoPlayNextEpisode(_ enabled: Bool) async {
        guard let environment else { return }
        let previousValue = autoPlayNextEpisode
        autoPlayNextEpisode = enabled
        do {
            try await environment.database.setSetting(
                .bool(enabled),
                forKey: "playback.autoPlayNextEpisode"
            )
        } catch {
            if autoPlayNextEpisode == enabled {
                autoPlayNextEpisode = previousValue
            }
            show(error, title: L10n.string("settings.autoplay.save.failed", fallback: "Unable to Save Auto-Play Setting"))
        }
    }

    func setPlaybackSkipAppliesToAllEpisodes(_ enabled: Bool) {
        playbackSkipAppliesToAllEpisodes = enabled
        refreshPlaybackSkipPresentation()
    }

    func markPlaybackOpeningAtCurrentPosition() async {
        let position = playerSnapshot.position
        guard canMarkPlaybackOpening,
              position.isFinite,
              position > 0,
              position <= playbackSkipMaximumDuration else {
            showPlaybackSkipValidationError()
            return
        }
        await updateSelectedPlaybackSkipRule { rule in
            rule.opening = .enabled(position)
        }
    }

    func markPlaybackEndingAtCurrentPosition() async {
        let duration = playerSnapshot.duration
        let remaining = duration - playerSnapshot.position
        guard canMarkPlaybackEnding,
              duration.isFinite,
              duration > 0,
              remaining.isFinite,
              remaining > 0,
              remaining <= playbackSkipMaximumDuration else {
            showPlaybackSkipValidationError()
            return
        }
        // Marking the current frame as the beginning of the ending must not
        // immediately dismiss the episode the user is still configuring.
        playbackSkipSession?.endingSkipSuppressed = true
        playbackEndingSkipPrompt = nil
        await updateSelectedPlaybackSkipRule { rule in
            rule.ending = .enabled(remaining)
        }
    }

    func adjustPlaybackOpening(by delta: TimeInterval) async {
        guard let value = playbackSkipOpeningEnd else { return }
        let adjusted = min(
            max(1, value + delta),
            playbackSkipMaximumDuration
        )
        await updateSelectedPlaybackSkipRule { rule in
            rule.opening = .enabled(adjusted)
        }
    }

    func adjustPlaybackEnding(by delta: TimeInterval) async {
        guard let value = playbackSkipEndingDuration else { return }
        let adjusted = min(
            max(1, value + delta),
            playbackSkipMaximumDuration
        )
        await updateSelectedPlaybackSkipRule { rule in
            rule.ending = .enabled(adjusted)
        }
    }

    func setPlaybackOpeningSkipEnabled(_ enabled: Bool) async {
        guard playbackSkipOpeningEnd != nil else { return }
        await updateSelectedPlaybackSkipRule { rule in
            if rule.opening.seconds == nil {
                rule.opening.seconds = playbackSkipOpeningEnd
            }
            rule.opening = rule.opening.settingEnabled(enabled)
        }
    }

    func setPlaybackEndingSkipEnabled(_ enabled: Bool) async {
        guard playbackSkipEndingDuration != nil else { return }
        await updateSelectedPlaybackSkipRule { rule in
            if rule.ending.seconds == nil {
                rule.ending.seconds = playbackSkipEndingDuration
            }
            rule.ending = rule.ending.settingEnabled(enabled)
        }
        if !enabled {
            playbackEndingSkipPrompt = nil
        }
    }

    func clearSelectedPlaybackSkipRule() async {
        guard var session = playbackSkipSession else { return }
        let identity = playbackSkipAppliesToAllEpisodes
            ? session.identity.seriesLineIdentity
            : session.identity
        if playbackSkipAppliesToAllEpisodes {
            session.lineRule = nil
        } else {
            session.episodeRule = nil
        }
        session.effectiveRule = PlaybackSkipRuleResolver.resolve(
            line: session.lineRule,
            episode: session.episodeRule
        )
        playbackSkipSession = session
        refreshPlaybackSkipPresentation()
        guard !incognitoMode else { return }
        do {
            try await environment?.database.deletePlaybackSkipRule(
                identity: identity
            )
        } catch {
            show(
                error,
                title: L10n.string(
                    "player.skip.save.failed",
                    fallback: "Unable to Save Skip Settings"
                ),
                target: .player
            )
        }
    }

    func suppressEndingSkipForCurrentPlayback() {
        playbackSkipSession?.endingSkipSuppressed = true
        playbackEndingSkipPrompt = nil
    }

    func skipEndingNow() {
        guard let session = playbackSkipSession,
              session.episodeSessionID == playbackSessionID else { return }
        playbackEndingSkipPrompt = nil
        requestAdvanceToNextEpisode(
            reason: .manualEndingSkip,
            sessionID: session.episodeSessionID
        )
    }

    var canEditPlaybackSkip: Bool {
        !isLivePlayback
            && activePlayback != nil
            && playerSnapshot.duration.isFinite
            && playerSnapshot.duration > 0
            && !playerSnapshot.isSeeking
    }

    var canMarkPlaybackOpening: Bool {
        canEditPlaybackSkip && canSeekPlayback
    }

    var canMarkPlaybackEnding: Bool {
        canEditPlaybackSkip
    }

    private var playbackSkipMaximumDuration: TimeInterval {
        let duration = playerSnapshot.duration
        guard duration.isFinite, duration > 0 else {
            return PlaybackSkipPolicy.maximumSkipDuration
        }
        return min(
            PlaybackSkipPolicy.maximumSkipDuration,
            duration * PlaybackSkipPolicy.maximumDurationFraction
        )
    }

    private func updateSelectedPlaybackSkipRule(
        _ update: (inout PlaybackSkipRule) -> Void
    ) async {
        guard var session = playbackSkipSession else { return }
        let original = session
        let identity = playbackSkipAppliesToAllEpisodes
            ? session.identity.seriesLineIdentity
            : session.identity
        var rule = playbackSkipAppliesToAllEpisodes
            ? session.lineRule ?? PlaybackSkipRule(identity: identity)
            : session.episodeRule ?? PlaybackSkipRule(identity: identity)
        update(&rule)
        rule.updatedAt = Date()
        if playbackSkipAppliesToAllEpisodes {
            session.lineRule = rule
        } else {
            session.episodeRule = rule
        }
        session.effectiveRule = PlaybackSkipRuleResolver.resolve(
            line: session.lineRule,
            episode: session.episodeRule
        )
        playbackSkipSession = session
        refreshPlaybackSkipPresentation()
        guard !incognitoMode else { return }
        do {
            try await environment?.database.savePlaybackSkipRule(rule)
        } catch {
            if playbackSkipSession?.episodeSessionID
                == original.episodeSessionID {
                playbackSkipSession = original
                refreshPlaybackSkipPresentation()
            }
            show(
                error,
                title: L10n.string(
                    "player.skip.save.failed",
                    fallback: "Unable to Save Skip Settings"
                ),
                target: .player
            )
        }
    }

    private func refreshPlaybackSkipPresentation() {
        guard let session = playbackSkipSession else {
            playbackSkipOpeningEnd = nil
            playbackSkipEndingDuration = nil
            playbackSkipOpeningEnabled = false
            playbackSkipEndingEnabled = false
            return
        }
        let selected = playbackSkipAppliesToAllEpisodes
            ? session.lineRule
            : session.episodeRule
        let opening = presentedPlaybackSkipField(
            selected?.opening,
            inherited: session.effectiveRule.openingEnd
        )
        let ending = presentedPlaybackSkipField(
            selected?.ending,
            inherited: session.effectiveRule.endingDuration
        )
        playbackSkipOpeningEnd = opening.seconds
        playbackSkipEndingDuration = ending.seconds
        playbackSkipOpeningEnabled = opening.enabled
        playbackSkipEndingEnabled = ending.enabled
    }

    private func presentedPlaybackSkipField(
        _ field: PlaybackSkipFieldRule?,
        inherited: TimeInterval?
    ) -> (seconds: TimeInterval?, enabled: Bool) {
        guard let field else {
            return (inherited, inherited != nil)
        }
        switch field.behavior {
        case .enabled:
            return (field.seconds, field.enabledSeconds != nil)
        case .disabled:
            return (field.seconds ?? inherited, false)
        case .inherit:
            return (inherited, inherited != nil)
        }
    }

    private func showPlaybackSkipValidationError() {
        show(
            AppError.playback(
                L10n.string(
                    "player.skip.invalid-position",
                    fallback: "Play to the beginning of the opening or ending, then set the marker. The marker must be within the first or last 20%% of the episode."
                )
            ),
            title: L10n.string(
                "player.skip.unavailable",
                fallback: "Unable to Set Skip Point"
            ),
            target: .player
        )
    }

    func clearPosterCache() async {
        guard let repository = environment?.imageRepository else { return }
        do {
            try await repository.clear()
        } catch {
            show(error, title: L10n.string("settings.poster-cache.clear.failed", fallback: "Unable to Clear Poster Cache"))
        }
    }

    func clearHistory() async {
        _ = await deleteHistory(records: history)
    }

    @discardableResult
    func deleteHistory(ids: Set<HistoryRecord.ID>) async -> Bool {
        await deleteHistory(records: history.filter { ids.contains($0.id) })
    }

    @discardableResult
    func deleteHistory(records: [HistoryRecord]) async -> Bool {
        guard let environment, !records.isEmpty else { return false }
        let ids = Set(records.map(\.id))
        var sessions = Set(historySessionRecordIDs.compactMap { session, records in
            records.isDisjoint(with: ids) ? nil : session
        })
        if let pending = pendingPlayback {
            let id = HistoryRecord(configurationID: pending.configurationID, siteKey: pending.detail.summary.siteKey,
                videoID: pending.detail.summary.videoID, title: pending.detail.summary.title, sourceKey: pending.source.id).id
            if ids.contains(id) { sessions.insert(playbackSessionID) }
        }
        if let write = playbackHistoryWrite(position: playerSnapshot.position, duration: playerSnapshot.duration),
           ids.contains(write.record.id) || write.replacedRecord.map({ ids.contains($0.id) }) == true {
            sessions.insert(write.sessionID)
        }
        if let pendingHistoryWrite, ids.contains(pendingHistoryWrite.record.id) {
            sessions.insert(pendingHistoryWrite.sessionID)
        }
        if let requested = historyPlaybackRequestedItem, ids.contains(requested.id) {
            sessions.insert(playbackSessionID)
        }
        let affectedIDs = ids.union(sessions.flatMap { historySessionRecordIDs[$0] ?? [] })
        do {
            // SQLite commits deletion, completion markers, and write suppression
            // together without an actor suspension inside the transaction.
            try await environment.database.deleteWatchedHistory(records, suppressing: sessions)
            suppressedHistorySessions.formUnion(sessions)
            historyRevision &+= 1
            history.removeAll { affectedIDs.contains($0.id) }
            historyPlaybackSessionCache.remove(affectedIDs)
            if pendingHistoryWrite.map({ sessions.contains($0.sessionID) }) == true { pendingHistoryWrite = nil }
            if let requested = historyPlaybackRequestedItem, ids.contains(requested.id) {
                historyPlaybackTask?.cancel()
                historyPlaybackTask = nil
                historyPlaybackPreparationID = UUID()
                historyPlaybackRequestedItem = nil
                historyPlaybackLoadingID = nil
                historyPlaybackChoices = []
            }
            return true
        } catch {
            show(error, title: L10n.string("history.delete.failed", fallback: "Unable to Delete History"))
            return false
        }
    }

    func exportDiagnostics(to url: URL) async throws {
        let sites = visibleSites.map { site -> [String: Any] in
            let api: String
            if let parsed = URL(string: site.api), parsed.scheme != nil {
                api = LogRedactor.url(parsed)
            } else {
                api = "<relative>"
            }
            return [
                "key": site.key,
                "name": site.name,
                "type": site.type,
                "api": api,
                "capability": providers[site.key]?.capability.rawValue ?? "unavailable"
            ]
        }
        var report: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": versionDescription,
            "system": systemDescription,
            "architecture": architectureDescription,
            "configurationCount": configurations.count,
            "activeConfiguration": activeConfigurationRecord.map { $0.name as Any } ?? NSNull(),
            "siteCount": sites.count,
            "sites": sites,
            "favoriteCount": favorites.count,
            "historyCount": history.count,
            "incognito": incognitoMode,
            "quickJSBundled": environment?.spiderRuntimeFactory != nil,
            "playerStatus": playerStatusDescription
        ]
        let diagnosticEncoder = JSONEncoder()
        diagnosticEncoder.dateEncodingStrategy = .iso8601
        if let androidSnapshot = await environment?.androidDexBridge
            .diagnosticSnapshot(),
           let encoded = try? diagnosticEncoder.encode(androidSnapshot),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            report["androidRuntime"] = LogRedactor.json(object)
        }
        if let managedSnapshot = await environment?.androidRuntimeManager
            .diagnosticReport(),
           let encoded = try? diagnosticEncoder.encode(managedSnapshot),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            report["androidManagedRuntime"] = LogRedactor.json(object)
        }
        if let service = environment?.androidRuntimeManager.maintenance {
            if let plan = await service.diagnosticPlan(),
               let encoded = try? diagnosticEncoder.encode(plan),
               let object = try? JSONSerialization.jsonObject(with: encoded) {
                report["androidManagedUninstallPlan"] = LogRedactor.json(object)
            }
            let transactions = await service.transactionDiagnostics()
            if let encoded = try? diagnosticEncoder.encode(transactions),
               let object = try? JSONSerialization.jsonObject(with: encoded) {
                report["androidUninstallTransactions"] = LogRedactor.json(object)
            }
            let storage = await service.storage()
            if let encoded = try? diagnosticEncoder.encode(storage),
               let object = try? JSONSerialization.jsonObject(with: encoded) {
                report["androidManagedStorage"] = object
            }
        }
        if let modeSnapshot = await environment?.androidRuntimeModeCoordinator
            .diagnosticReport(),
           let encoded = try? diagnosticEncoder.encode(modeSnapshot),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            report["androidRuntimeSelection"] = LogRedactor.json(object)
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw AppError.filesystem(
                L10n.string(
                    "diagnostics.export.failed",
                    fallback: "Unable to export diagnostics: %@",
                    error.localizedDescription
                )
            )
        }
    }

    func shutdown() async {
        if hasCompletedShutdown {
            return
        }
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        let finalHistoryWrite = playbackHistoryWrite(position: playerSnapshot.position, duration: playerSnapshot.duration)
        isShutdownRequested = true
        liveHLSPreparationTask?.task.cancel()
        liveHLSPreparationTask = nil
        playbackDisplaySleep.setSuspended(true)
        importedIdentityGeneration?.invalidate()
        importedIdentityMapping = nil
        for task in importedRefreshDownloads.values { task.cancel() }
        importedRefreshDownloads.removeAll()
        epgRefreshTask?.cancel()
        epgBoundaryTask?.cancel()
        epgBoundaryTask = nil
        epgLifecycleTask?.cancel()
        epgLifecycleTask = nil
        for task in epgResourceRefreshTasks.values { task.cancel() }
        epgResourceRefreshTasks.removeAll()
        epgResourceRefreshOperationIDs.removeAll()
        liveEPGLoadActivities.removeAll()
        liveGuideTask?.cancel()
        liveGuideTask = nil
        liveGuideRequest = nil
        liveGuideInput = nil
        liveGuideOwner = nil
        liveGuideWaitingForResource = nil
        liveGuideDebounce.reset()
        liveGuide.deactivate()
        if let repository = environment?.productionEPGRepository {
            _ = await repository.close(deadlineNanoseconds: 2_000_000_000)
        }
        invalidateXtreamLiveCatalog()
        playerRenderSurfaceGate.reset()
        automaticEpisodeAdvanceController.cancel()
        invalidateCatPawHomeLoads()
        cancelAllCategoryRequestTasks()
        categoryTabSessionStore.removeAll()
        cancelAllPlaybackStartupGates()
        playbackRequestsResolving.removeAll()
        historyPlaybackTask?.cancel()
        historyPlaybackTask = nil
        historyPlaybackPreparationID = UUID()
        historyPlaybackLoadingID = nil
        historyPlaybackRequestedItem = nil
        historyPlaybackChoices = []
        activeSeekConfirmationID = nil
        playbackSessionID = UUID()
        activePlayerRequestID = UUID()
        playbackQualitySwitchSessionID = UUID()
        livePlaybackNavigationContext = nil
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        for id in Array(liveValidationPermits.keys) { cancelLiveSourceValidation(id) }
        liveSourceValidationTasks = [:]
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = nil
        if let challengeID = nodeWebPresentation?.challengeID {
            await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
        }
        pendingNodeOperation = nil
        pendingNodePlaybackConfigurationFallback = nil
        nodeWebPresentation = nil
        nodeRuntimeStatusTask?.cancel()
        nodeRuntimeStatusTask = nil
        nodeProfileRevisionTask?.cancel()
        nodeProfileRevisionTask = nil
        managedRuntimeStatusTask?.cancel()
        managedRuntimeStatusTask = nil
        configurationActivationTask?.cancel()
        configurationActivationTask = nil
        configurationPostActivationSessionID = UUID()
        configurationPostActivationTask?.cancel()
        configurationPostActivationTask = nil
        configurationSwitchFeedbackDismissTask?.cancel()
        configurationSwitchFeedbackDismissTask = nil
        requestedConfigurationID = nil
        configurationSwitchFeedback = .idle

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let androidBridge = self.environment?.androidDexBridge
            // Close process-wide Android startup admission before yielding to
            // the rest of shutdown. The actual bounded process teardown can
            // then run alongside player/history cleanup.
            await androidBridge?.beginApplicationTermination()
            let androidShutdownTask = androidBridge.map { bridge in
                Task {
                    await bridge.shutdownForApplicationTermination()
                }
            }
            await self.finishScheduledHistoryPersistence()
            if let finalHistoryWrite { await self.persistFinalHistoryWrite(finalHistoryWrite) }
            await self.environment?.player.shutdown()
            await self.cleanupPreparedTransferReceipts(reason: .appShutdown)
            await self.releaseAllTransferMediaLeases(reason: .appShutdown)
            self.playerEventTask?.cancel()
            self.playerEventTask = nil
            if let lease = self.activeNodePlaybackLease {
                self.activeNodePlaybackLease = nil
                await self.environment?.nodeBundleRuntime.releasePlaybackLease(
                    lease
                )
            }
            await self.environment?.nodeBundleRuntime.stop(force: true)
            _ = await androidShutdownTask?.value
            self.pendingPlayback = nil
            self.cloudAuthorizationContext = nil
            self.pendingHistoryWrite = nil
        }
        shutdownTask = task
        await task.value
        hasCompletedShutdown = true
    }

    func persistPlaybackProgress(ownedRequestID: UUID? = nil) async {
        let write = playbackHistoryWrite(position: playerSnapshot.position,
            duration: playerSnapshot.duration, ownedRequestID: ownedRequestID)
        await finishScheduledHistoryPersistence()
        if let write { await persistFinalHistoryWrite(write) }
    }

    func handleSystemSleep() async {
        playbackDisplaySleep.setSuspended(true)
        for id in Array(liveValidationPermits.keys) { cancelLiveSourceValidation(id) }
        epgSleeping = true
        epgLifecycleTask?.cancel()
        epgLifecycleTask = nil
        epgRefreshGeneration = UUID()
        epgRefreshTask?.cancel()
        epgBoundaryTask?.cancel()
        epgBoundaryTask = nil
        for task in epgResourceRefreshTasks.values { task.cancel() }
        epgResourceRefreshTasks.removeAll()
        epgResourceRefreshOperationIDs.removeAll()
        liveEPGLoadActivities.removeAll()
        liveGuideTask?.cancel()
        liveGuideTask = nil
        liveGuideRequest = nil
        liveGuideWaitingForResource = nil
        liveGuideDebounce.reset()
        liveGuide.suspend()
        if let repository = environment?.productionEPGRepository {
            _ = await repository.pause(deadlineNanoseconds: 750_000_000)
        }
        switch playerSnapshot.status {
        case .playing, .buffering:
            shouldResumeAfterWake = true
            try? await environment?.player.pause()
        default:
            shouldResumeAfterWake = false
        }
        await persistPlaybackProgress()
    }

    func handleSystemWake() async {
        playbackDisplaySleep.setSuspended(false)
        epgSleeping = false
        liveEPG.tick()
        if let repository = environment?.productionEPGRepository {
            epgLifecycleTask?.cancel()
            epgLifecycleTask = Task(priority: .utility) { @MainActor [weak self] in
                do { try await repository.resume() } catch { return }
                guard let self, !Task.isCancelled, !self.epgSleeping,
                      !self.isShutdownRequested else { return }
                self.epgLifecycleTask = nil
                self.scheduleEPGRefresh()
                self.restartLiveGuideDemandIfNeeded()
            }
        } else {
            scheduleEPGRefresh()
        }
        if shouldResumeAfterWake {
            shouldResumeAfterWake = false
            do {
                try await environment?.player.play()
            } catch {
                show(error, title: L10n.string("player.wake-resume.failed", fallback: "Unable to Resume After Wake"), target: .player)
            }
        }
    }

    func closePlayer() async {
        guard !isShutdownRequested else { return }
        clearPlayerEpisodeListRecovery()
        // Capabilities expire before any close-time suspension.
        livePlaybackNavigationContext = nil
        if isClosingPlayer {
            await withCheckedContinuation { continuation in
                playerCloseWaiters.append(continuation)
            }
            return
        }
        guard isPlayerPresented
                || activePlayback != nil
                || pendingPlayback != nil
                || livePlaybackChannel != nil else {
            return
        }
        if let context = cloudAuthorizationContext,
           context.operation.playbackRequestID == activePlayerRequestID {
            clearCloudAuthorization(
                resetBridgeUI: true,
                markPendingPlaybackCancelled: false,
                cancellationReason: .user
            )
        }
        if pendingNodeOperation?.playbackRequestID == activePlayerRequestID {
            nodeAuthorizationCompletionTask?.cancel()
            nodeAuthorizationCompletionTask = nil
            if let challengeID = nodeWebPresentation?.challengeID {
                await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
            }
            pendingNodeOperation = nil
            nodeWebPresentation = nil
        }
        isClosingPlayer = true
        liveHLSPreparationTask?.task.cancel()
        liveHLSPreparationTask = nil
        playbackDisplaySleep.finishSession(activePlayerRequestID)
        defer {
            isClosingPlayer = false
            let waiters = playerCloseWaiters
            playerCloseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let closingWrite = playbackHistoryWrite(position: playerSnapshot.position, duration: playerSnapshot.duration)
        let closingRequestID = activePlayerRequestID
        let closingTransitionID = UUID()
        let shouldRetainTVBoxPlayerWarm = activePlayback?.media.transportProfile
            == .tvBox
        playerRenderSurfaceGate.reset()
        automaticEpisodeAdvanceController.cancel()
        resetPlaybackSkipSession()
        cancelAllPlaybackStartupGates()
        playbackRequestsResolving.removeAll()
        historyPlaybackTask?.cancel()
        historyPlaybackTask = nil
        historyPlaybackPreparationID = UUID()
        historyPlaybackLoadingID = nil
        historyPlaybackRequestedItem = nil
        historyPlaybackChoices = []
        activeSeekConfirmationID = nil
        playbackSessionID = closingTransitionID
        activePlayerRequestID = closingTransitionID
        playbackQualitySwitchSessionID = UUID()
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        isRecoveringLivePlayback = false
        hasExhaustedLivePlayback = false
        livePlaybackNotice = nil
        livePlaybackAttemptedIdentifiers = []
        pendingNodePlaybackConfigurationFallback = nil
        // Capture the final position before stop resets the player snapshot.
        await finishScheduledHistoryPersistence()
        if let closingWrite { await persistFinalHistoryWrite(closingWrite) }
        guard activePlayerRequestID == closingTransitionID,
              playbackSessionID == closingTransitionID else { return }
        // Ignore the stop event for history purposes. It otherwise publishes a
        // second, zeroed history update while the player is being dismissed.
        activePlayback = nil
        pendingPlayback = nil
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        livePlaybackNavigationContext = nil
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        let closingPreparedReceipts = preparedTransferReceipts
        preparedTransferReceipts.removeAll()
        let closingTransferLeases = transferMediaLeases
        transferMediaLeases.removeAll()
        let closingNodeLease = activeNodePlaybackLease
        activeNodePlaybackLease = nil
        await environment?.player.closeAfterPlayback(
            requestID: closingRequestID,
            // `stop` releases the active demux/cache state immediately. Keep
            // only the idle libmpv core briefly so returning from History does
            // not pay another native cold-start; ordinary sources retain the
            // existing immediate full-destroy behavior.
            warmRetentionSeconds: shouldRetainTVBoxPlayerWarm ? 45 : 0
        )
        for receipt in closingPreparedReceipts.values {
            await cleanupTransferReceipt(receipt, reason: .playerClosed)
        }
        for lease in closingTransferLeases.values {
            _ = await environment?.nodeBundleRuntime.releaseTransferLease(
                receiptID: lease.receipt.receiptID,
                reason: .playerClosed
            )
        }
        if let lease = closingNodeLease {
            await environment?.nodeBundleRuntime.releasePlaybackLease(lease)
        }
        guard activePlayerRequestID == closingTransitionID,
              playbackSessionID == closingTransitionID else { return }
        await dismissPlayerSurfaceAndRestoreWindow()
        guard activePlayerRequestID == closingTransitionID,
              playbackSessionID == closingTransitionID else { return }
        playbackResolutionState = .idle
        currentPlaybackAttempt = nil
        playbackFailureSummary = nil
        playerPresentedError = nil
    }

    func togglePlayPause() async {
        guard let player = environment?.player else { return }
        let previousStatus = playerSnapshot.status
        let shouldPlay: Bool
        if previousStatus == .ended {
            // Reload with a fresh playback/EOF owner. Merely unpausing a
            // keep-open final frame cannot produce another end event.
            await savePlaybackHistory(position: playerSnapshot.position, duration: playerSnapshot.duration)
            await retryCurrentPlayback()
            return
        }
        if case .paused = previousStatus {
            shouldPlay = true
            playerSnapshot.status = .playing
        } else {
            shouldPlay = false
            playerSnapshot.status = .paused
        }
        do {
            if shouldPlay {
                try await player.play()
            } else {
                try await player.pause()
                schedulePlaybackHistorySave(
                    position: playerSnapshot.position,
                    duration: playerSnapshot.duration
                )
            }
        } catch {
            let optimisticStatus: PlayerStatus = shouldPlay ? .playing : .paused
            if playerSnapshot.status == optimisticStatus {
                playerSnapshot.status = previousStatus
            }
            show(error, title: L10n.string("player.control.failed", fallback: "Playback Control Failed"), target: .player)
        }
    }

    /// Developer-only bounded comparison; the owned media locator stays here.
    /// The ordinary Bridge build does not expose this diagnostic operation.
    func seekAcceptanceReadAudit() async -> Data? {
        guard ProcessInfo.processInfo.environment["OKVIDEOMAC_SEEK_ACCEPTANCE"] == "1",
              (try? AppEnvironment.acceptanceWorkspace()) != nil,
              let media = activePlayback?.media,
              MPVTVBoxPlaybackPolicy.isBridgeSession(media.url) else { return nil }
        let owner = activePlayerRequestID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 35
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: media.url)
        request.allHTTPHeaderFields = media.headers.dictionary
        request.setValue("1", forHTTPHeaderField: "X-OKVideoMac-Range-Audit")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard response.mimeType == "application/json" else { return nil }
            var result = Data()
            for try await byte in bytes {
                guard result.count < 16_384, activePlayerRequestID == owner else { return nil }
                result.append(byte)
            }
            guard activePlayerRequestID == owner else { return nil }
            return result
        } catch { return nil }
    }

    func seek(by offset: TimeInterval) async {
        guard canSeekPlayback else { return }
        let target = min(
            max(0, playerSnapshot.position + offset),
            playerSnapshot.duration > 0
                ? playerSnapshot.duration
                : .greatestFiniteMagnitude
        )
        NSLog("[MPV-SEEK] phase=host_relative request=%@ %@",
              activePlayerRequestID.uuidString,
              PlayerSeekDiagnostics.fields(
                position: playerSnapshot.position,
                duration: playerSnapshot.duration,
                target: target,
                offset: offset
              ))
        await seek(to: target)
    }

    func seek(to position: TimeInterval) async {
        guard canSeekPlayback else { return }
        guard let player = environment?.player else { return }
        guard let target = PlayerSeekPolicy.target(
            requested: position,
            duration: playerSnapshot.duration
        ) else {
            show(
                AppError.playback(L10n.string("player.seek.invalid-position", fallback: "The seek position is invalid.")),
                title: L10n.string("player.seek.failed", fallback: "Unable to Seek"),
                target: .player
            )
            return
        }
        noteUserSeekForPlaybackSkip(to: target)
        let previousPosition = playerSnapshot.position
        let isTVBoxPlayback = activePlayback?.media.transportProfile == .tvBox
        NSLog("[MPV-SEEK] phase=host_absolute request=%@ %@",
              activePlayerRequestID.uuidString,
              PlayerSeekDiagnostics.fields(
                position: previousPosition,
                duration: playerSnapshot.duration,
                target: target,
                requested: position
              ))
        let confirmationID = UUID()
        activeSeekConfirmationID = confirmationID
        playerSnapshot.isSeeking = true
        playerSnapshot.seekTarget = target
        do {
            try await player.seek(to: target)
            if isTVBoxPlayback {
                // TVBox media is commonly a provider-owned Range relay. The
                // native seek/restart events are authoritative; a host-side
                // timeout followed by a rollback starts a second expensive
                // Range request and can make an otherwise successful seek
                // look like an EOF/next-episode transition.
                return
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try Task.checkCancellation()
                guard activeSeekConfirmationID == confirmationID else { return }
                if PlayerSeekConfirmationPolicy.hasCompleted(
                    snapshot: playerSnapshot
                ) {
                    activeSeekConfirmationID = nil
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard activeSeekConfirmationID == confirmationID else { return }
            activeSeekConfirmationID = nil
            // The command was accepted but mpv never reported a restart near
            // the target. Restore the previous timeline point once so a
            // sequential-only HLS proxy does not leave the UI out of sync.
            try? await player.seek(to: previousPosition)
            playerSnapshot.position = previousPosition
            playerSnapshot.isSeeking = false
            playerSnapshot.seekTarget = nil
            show(
                AppError.playback(
                    L10n.string(
                        "player.seek.timeout.message",
                        fallback: "The player did not finish seeking within 10 seconds and returned to the previous position. The network or source may be slow; try again later or switch quality."
                    )
                ),
                title: L10n.string("player.seek.timeout.title", fallback: "Seek Timed Out"),
                target: .player
            )
        } catch is CancellationError {
            if activeSeekConfirmationID == confirmationID {
                activeSeekConfirmationID = nil
                playerSnapshot.isSeeking = false
                playerSnapshot.seekTarget = nil
            }
        } catch {
            activeSeekConfirmationID = nil
            playerSnapshot.position = previousPosition
            if playerSnapshot.seekTarget == target {
                playerSnapshot.isSeeking = false
                playerSnapshot.seekTarget = nil
            }
            show(error, title: L10n.string("player.seek.failed", fallback: "Unable to Seek"), target: .player)
        }
    }

    @discardableResult
    func requestPlayerVolume(_ volume: Double) -> Task<Void, Never> {
        guard volume.isFinite else { return Task {} }
        environment?.player.rememberVolume(volume)
        var value = playerAudioPreference
        value.volume = min(130, max(0, volume))
        if value.volume > 0 { value.muted = false }
        playerAudioPreference = environment?.player.audioPreference ?? value
        playerSnapshot.volume = playerAudioPreference.volume
        playerSnapshot.isMuted = playerAudioPreference.muted
        return applyPlayerAudioPreference()
    }

    func setPlayerVolume(_ volume: Double) async { await requestPlayerVolume(volume).value }

    func adjustPlayerVolume(by delta: Double) async {
        await setPlayerVolume(playerAudioPreference.volume + delta)
    }

    func togglePlayerMute() async {
        let muted = !playerAudioPreference.muted
        environment?.player.rememberMuted(muted)
        playerAudioPreference.muted = muted
        playerSnapshot.isMuted = muted
        await applyPlayerAudioPreference().value
    }

    private func applyPlayerAudioPreference() -> Task<Void, Never> {
        let revision = environment?.player.audioPreferenceRevision
        return Task { @MainActor [weak self] in
            guard let self, let player = self.environment?.player else { return }
            do {
                try await player.applyAudioPreference()
                self.audioErrorRevision = nil
            } catch {
                guard revision == player.audioPreferenceRevision, self.audioErrorRevision != revision else { return }
                self.audioErrorRevision = revision
                self.show(error, title: L10n.string("player.audio.apply.failed", fallback: "Audio setting could not be applied; your preference is saved."), target: .player)
            }
        }
    }

    func setPlayerSpeed(_ speed: Double) async {
        let previousSpeed = playerSnapshot.speed
        playerSnapshot.speed = speed
        do {
            try await environment?.player.setSpeed(speed)
        } catch {
            if playerSnapshot.speed == speed {
                playerSnapshot.speed = previousSpeed
            }
            show(error, title: L10n.string("player.speed.failed", fallback: "Unable to Change Playback Speed"), target: .player)
        }
    }

    func adjustPlayerSpeed(by delta: Double) async {
        let target = min(max(playerSnapshot.speed + delta, 0.5), 2)
        await setPlayerSpeed((target * 4).rounded() / 4)
    }

    var hasPlayerAudioTracks: Bool {
        playerSnapshot.tracks.contains { $0.type == .audio }
    }

    var hasPlayerSubtitleTracks: Bool {
        playerSnapshot.tracks.contains { $0.type == .subtitle }
    }

    func cyclePlayerAudioTrack() async {
        let tracks = playerSnapshot.tracks.filter { $0.type == .audio }
        guard !tracks.isEmpty else { return }
        let selectedIndex = tracks.firstIndex(where: \.isSelected)
        let nextIndex = selectedIndex.map { ($0 + 1) % tracks.count } ?? 0
        await selectPlayerTrack(tracks[nextIndex])
    }

    var selectedPlaybackQualityName: String? {
        playbackQualities.first { $0.id == selectedPlaybackQualityID }?.name
    }

    func switchPlaybackQuality(_ quality: PlaybackQuality) async {
        guard !isShutdownRequested,
              let environment,
              let playback = activePlayback,
              var playbackResult = playback.playbackResult,
              playbackResult.qualities.contains(quality),
              quality.id != selectedPlaybackQualityID,
              !isSwitchingPlaybackQuality else {
            return
        }

        let switchSessionID = UUID()
        playbackQualitySwitchSessionID = switchSessionID
        let owningPlaybackSessionID = playbackSessionID
        let previousMedia = playback.media
        var previousPosition = playerSnapshot.position
        var previousDuration = playerSnapshot.duration
        var wasPaused: Bool
        if case .paused = playerSnapshot.status {
            wasPaused = true
        } else {
            wasPaused = false
        }
        playbackResult.url = quality.url
        isSwitchingPlaybackQuality = true
        playbackFailureSummary = nil
        playbackResolutionState = .resolving
        defer {
            if playbackQualitySwitchSessionID == switchSessionID {
                isSwitchingPlaybackQuality = false
            }
        }

        var replacementStarted = false
        do {
            let httpClient = configuredHTTPClient(environment: environment)
            let resolver = PlaybackResolver(
                parseExecutor: AppParseExecutor(httpClient: httpClient),
                mediaProbe: DefaultMediaProbe(httpClient: httpClient)
            )
            let attemptContext = PlaybackResolutionAttemptContext(
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode,
                result: playbackResult,
                danmakuContext: playback.media.danmakuContext
            )
            var resolvedMedia: ResolvedMedia?
            var failureMessage: String?
            for await event in resolver.resolve(
                attemptContext.resolutionRequest(
                    configuredParsers: activeConfiguration?.parses ?? [],
                    maximumAttempts: 8
                )
            ) {
                try Task.checkCancellation()
                guard playbackQualitySwitchSessionID == switchSessionID,
                      playbackSessionID == owningPlaybackSessionID else {
                    throw CancellationError()
                }
                switch event {
                case .state(let state):
                    playbackResolutionState = state
                case .attempting(let attempt):
                    currentPlaybackAttempt = attempt
                case .attemptFailed(let attempt, let message):
                    currentPlaybackAttempt = attempt
                    failureMessage = message
                case .resolved(let media):
                    resolvedMedia = media
                case .failed(let message):
                    failureMessage = message
                case .cancelled:
                    throw CancellationError()
                }
            }
            guard let resolvedMedia else {
                throw AppError.playback(
                    failureMessage ?? L10n.string("player.quality.no-playable-url", fallback: "This quality did not return a playable URL.")
                )
            }
            guard playbackQualitySwitchSessionID == switchSessionID,
                  playbackSessionID == owningPlaybackSessionID else {
                throw CancellationError()
            }

            if PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot) {
                previousPosition = playerSnapshot.position
                previousDuration = playerSnapshot.duration
                wasPaused = playerSnapshot.status == .paused
            }
            captureHistoryBeforePlaybackTransition()
            replacementStarted = true
            activePlayerRequestID = switchSessionID
            historyProgressCheckpoint.transferOwnership(to: switchSessionID)
            activePlayback?.requestID = switchSessionID
            try await loadPlayerAfterRenderSurfaceReady(
                resolvedMedia,
                startPosition: previousPosition,
                requestID: switchSessionID
            )
            guard playbackQualitySwitchSessionID == switchSessionID,
                  playbackSessionID == owningPlaybackSessionID else {
                throw CancellationError()
            }
            if wasPaused {
                try await environment.player.pause()
                guard playbackQualitySwitchSessionID == switchSessionID,
                      playbackSessionID == owningPlaybackSessionID else {
                    throw CancellationError()
                }
            }
            activePlayback = ActivePlaybackContext(
                configurationID: playback.configurationID,
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode,
                media: resolvedMedia,
                playbackResult: playbackResult,
                providerResourceReference: playback.providerResourceReference,
                replacedHistoryRecord: playback.replacedHistoryRecord,
                requestID: switchSessionID
            )
            playbackQualities = playbackResult.qualities
            selectedPlaybackQualityID = quality.id
            playbackResolutionState = .playing
            currentPlaybackAttempt = nil
            playbackFailureSummary = nil
            await savePlaybackHistory(
                position: previousPosition,
                duration: previousDuration
            )
        } catch is CancellationError {
            return
        } catch {
            guard playbackQualitySwitchSessionID == switchSessionID,
                  playbackSessionID == owningPlaybackSessionID else {
                return
            }
            currentPlaybackAttempt = nil
            var restoreError: Error?
            if replacementStarted,
               playbackQualitySwitchSessionID == switchSessionID,
               playbackSessionID == owningPlaybackSessionID {
                do {
                    try await loadPlayerAfterRenderSurfaceReady(
                        previousMedia,
                        startPosition: previousPosition,
                        requestID: switchSessionID
                    )
                    guard playbackQualitySwitchSessionID == switchSessionID,
                          playbackSessionID == owningPlaybackSessionID else {
                        throw CancellationError()
                    }
                    if wasPaused {
                        try await environment.player.pause()
                        guard playbackQualitySwitchSessionID == switchSessionID,
                              playbackSessionID == owningPlaybackSessionID else {
                            throw CancellationError()
                        }
                    }
                } catch {
                    restoreError = error
                }
            }
            if let restoreError {
                let switchMessage = localizedRuntimeErrorMessage(error)
                let restoreMessage = localizedRuntimeErrorMessage(restoreError)
                playbackResolutionState = .failed
                playbackFailureSummary = restoreMessage
                show(
                    AppError.playback(
                        L10n.string(
                            "player.quality.switch-and-restore.failed",
                            fallback: "%1$@ Restoring the previous quality also failed: %2$@",
                            switchMessage,
                            restoreMessage
                        )
                    ),
                    title: L10n.string("player.quality.switch.failed", fallback: "Unable to Switch Quality"),
                    target: .player
                )
            } else {
                playbackResolutionState = .playing
                playbackFailureSummary = nil
                show(error, title: L10n.string("player.quality.switch.failed", fallback: "Unable to Switch Quality"), target: .player)
            }
        }
    }

    func selectPlayerTrack(_ track: MediaTrack) async {
        do {
            try await environment?.player.selectTrack(
                id: track.id,
                type: track.type
            )
            if track.type == .subtitle {
                selectedPlayerSubtitleTrackID = track.id
                playerSubtitlesEnabled = true
                prefersPlayerSubtitlesEnabled = true
                preferredPlayerSubtitleTrack = PlayerSubtitleTrackPreference(
                    track: track
                )
                await persistPlayerSubtitlePreference(
                    enabled: true,
                    track: track
                )
            }
        } catch {
            show(error, title: L10n.string("player.track.switch.failed", fallback: "Unable to Switch Track"), target: .player)
        }
    }

    func togglePlayerSubtitles() async {
        let subtitleTracks = playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        guard !subtitleTracks.isEmpty else {
            show(
                AppError.playback(L10n.string("player.subtitle.none", fallback: "No subtitles are available for this video.")),
                title: L10n.string("player.subtitle.setting.failed", fallback: "Unable to Change Subtitle Setting"),
                target: .player
            )
            return
        }
        do {
            if playerSubtitlesEnabled {
                if let selected = subtitleTracks.first(where: { $0.isSelected }) {
                    selectedPlayerSubtitleTrackID = selected.id
                    preferredPlayerSubtitleTrack = PlayerSubtitleTrackPreference(
                        track: selected
                    )
                }
                try await environment?.player.selectTrack(
                    id: -1,
                    type: .subtitle
                )
                playerSubtitlesEnabled = false
                prefersPlayerSubtitlesEnabled = false
                await persistPlayerSubtitlePreference(
                    enabled: false,
                    track: subtitleTracks.first(where: { $0.isSelected })
                )
            } else {
                let track = preferredPlayerSubtitleTrack.flatMap {
                    PlayerSubtitleTrackPreference.matchingTrack(
                        in: subtitleTracks,
                        preference: $0
                    )
                } ?? selectedPlayerSubtitleTrackID.flatMap { identifier in
                    subtitleTracks.first { $0.id == identifier }
                } ?? MPVPlayerClient.preferredSubtitleTrack(in: subtitleTracks)
                guard let track else { return }
                try await environment?.player.selectTrack(
                    id: track.id,
                    type: .subtitle
                )
                selectedPlayerSubtitleTrackID = track.id
                playerSubtitlesEnabled = true
                prefersPlayerSubtitlesEnabled = true
                preferredPlayerSubtitleTrack = PlayerSubtitleTrackPreference(
                    track: track
                )
                await persistPlayerSubtitlePreference(
                    enabled: true,
                    track: track
                )
            }
        } catch {
            show(error, title: L10n.string("player.subtitle.setting.failed", fallback: "Unable to Change Subtitle Setting"), target: .player)
        }
    }

    func adjustPlayerSubtitleDelay(by offset: TimeInterval) async {
        let value = min(max(playerSubtitleDelay + offset, -30), 30)
        do {
            try await environment?.player.setSubtitleDelay(value)
            playerSubtitleDelay = value
        } catch {
            show(error, title: L10n.string("player.subtitle.delay.failed", fallback: "Unable to Change Subtitle Delay"), target: .player)
        }
    }

    func adjustPlayerSubtitleScale(by offset: Double) async {
        let value = min(max(playerSubtitleScale + offset, 0.5), 3)
        do {
            try await environment?.player.setSubtitleScale(value)
            playerSubtitleScale = value
        } catch {
            show(error, title: L10n.string("player.subtitle.size.failed", fallback: "Unable to Change Subtitle Size"), target: .player)
        }
    }

    func adjustPlayerSubtitlePosition(by offset: Double) async {
        let value = min(max(playerSubtitlePosition + offset, 0), 100)
        do {
            try await environment?.player.setSubtitlePosition(value)
            playerSubtitlePosition = value
        } catch {
            show(error, title: L10n.string("player.subtitle.position.failed", fallback: "Unable to Change Subtitle Position"), target: .player)
        }
    }

    func adjustPlayerSubtitleBorderSize(by offset: Double) async {
        let value = min(max(playerSubtitleBorderSize + offset, 0), 10)
        do {
            try await environment?.player.setSubtitleBorderSize(value)
            playerSubtitleBorderSize = value
        } catch {
            show(error, title: L10n.string("player.subtitle.outline.failed", fallback: "Unable to Change Subtitle Outline"), target: .player)
        }
    }

    func resetPlayerSubtitleSettings() async {
        do {
            try await environment?.player.setSubtitleDelay(0)
            try await environment?.player.setSubtitleScale(1)
            try await environment?.player.setSubtitlePosition(100)
            try await environment?.player.setSubtitleBorderSize(3)
            playerSubtitleDelay = 0
            playerSubtitleScale = 1
            playerSubtitlePosition = 100
            playerSubtitleBorderSize = 3
        } catch {
            show(error, title: L10n.string("player.subtitle.reset.failed", fallback: "Unable to Reset Subtitle Settings"), target: .player)
        }
    }

    func adjustPlayerAudioDelay(by offset: TimeInterval) async {
        let value = min(max(playerAudioDelay + offset, -30), 30)
        do {
            try await environment?.player.setAudioDelay(value)
            playerAudioDelay = value
        } catch {
            show(error, title: L10n.string("player.audio.delay.failed", fallback: "Unable to Change Audio Delay"), target: .player)
        }
    }

    func setPlayerAspectRatio(_ ratio: String?) async {
        do {
            try await environment?.player.setAspectRatio(ratio)
            playerAspectRatio = ratio
        } catch {
            show(error, title: L10n.string("player.aspect-ratio.failed", fallback: "Unable to Change Aspect Ratio"), target: .player)
        }
    }

    func togglePlayerHardwareDecoding() async {
        let value = !playerHardwareDecoding
        do {
            try await environment?.player.setHardwareDecoding(enabled: value)
            playerHardwareDecoding = value
        } catch {
            show(error, title: L10n.string("player.hardware-decoding.failed", fallback: "Unable to Change Hardware Decoding"), target: .player)
        }
    }

    func addPlayerSubtitle(_ url: URL) async {
        do {
            try await environment?.player.addSubtitle(url: url)
            playerSubtitlesEnabled = true
            prefersPlayerSubtitlesEnabled = true
            await persistPlayerSubtitlePreference(enabled: true, track: nil)
        } catch {
            show(error, title: L10n.string("player.subtitle.load.failed", fallback: "Unable to Load Subtitles"), target: .player)
        }
    }

    func savePlayerScreenshot(to url: URL) async {
        do {
            try await environment?.player.screenshot(to: url)
        } catch {
            show(error, title: L10n.string("player.screenshot.failed", fallback: "Unable to Save Screenshot"), target: .player)
        }
    }

    func playAdjacentEpisode(offset: Int) async {
        guard let playback = activePlayback,
              let currentIndex = manuallyOrderedPlayerEpisodes.firstIndex(
                where: { $0.id == playback.episode.id }
              ) else { return }
        let nextIndex = currentIndex + offset
        guard manuallyOrderedPlayerEpisodes.indices.contains(nextIndex) else { return }
        await startPlayback(
            detail: playback.detail,
            source: playback.source,
            episode: manuallyOrderedPlayerEpisodes[nextIndex],
            configurationID: playback.configurationID,
            windowActivation: .preserveFocus
        )
    }

    private func clearPlayerEpisodeListRecovery() {
        playerEpisodeListRestoreTask?.cancel()
        playerEpisodeListRestoreTask = nil
        playerEpisodeListRestoreID = nil
        playerEpisodeListHistoryRecord = nil
        isRestoringPlayerEpisodeList = false
        isPlayerEpisodeListIncomplete = false
    }
    var hasLoadedPlayerEpisode: Bool { activePlayback != nil }
    var currentPlayerVersionText: String {
        currentPlaybackEpisode.map { PlaybackResourceAnalyzer.analyze($0).versionLabels.joined(separator: " · ") } ?? ""
    }
    var canRetryPlayerEpisode: Bool {
        canRetryCurrentPlayback && (playbackResolutionState == .failed || playbackResolutionState == .exhausted || {
            if case .failed = playerSnapshot.status { return true }; return false
        }())
    }

    var currentPlayerSourceName: String {
        (activePlayback?.source ?? pendingPlayback?.source)?.name ?? ""
    }

    func retryPlayerEpisodeList() {
        guard let record = playerEpisodeListHistoryRecord else { return }
        restorePlayerEpisodeList(record, sessionID: playbackSessionID)
    }

    private func restorePlayerEpisodeList(_ record: HistoryRecord, sessionID: UUID) {
        playerEpisodeListRestoreTask?.cancel()
        playerEpisodeListHistoryRecord = record
        isPlayerEpisodeListIncomplete = true
        guard let provider = providers[record.siteKey], let playback = activePlayback,
              activeConfigurationRecord?.id == playback.configurationID,
              record.configurationID == nil || record.configurationID == playback.configurationID else {
            isRestoringPlayerEpisodeList = false
            return
        }
        isRestoringPlayerEpisodeList = true
        let restoreID = UUID()
        playerEpisodeListRestoreID = restoreID
        let episodeID = playback.episode.id
        let configurationID = playback.configurationID
        playerEpisodeListRestoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.playbackSessionID == sessionID && self.playerEpisodeListRestoreID == restoreID {
                    self.isRestoringPlayerEpisodeList = false
                    self.playerEpisodeListRestoreTask = nil
                }
            }
            let detailID = record.playbackReference?.navigationRecipe?.detailID ?? record.videoID
            let summary = VideoSummary(siteKey: record.siteKey, siteName: playback.detail.summary.siteName,
                videoID: detailID, title: record.title, posterURL: record.posterURL)
            guard let detail = try? await Self.historyPlaybackDetail(provider: provider, summary: summary),
                  !Task.isCancelled, self.playbackSessionID == sessionID,
                  self.playerEpisodeListRestoreID == restoreID,
                  self.activePlayback?.episode.id == episodeID,
                  self.activePlayback?.configurationID == configurationID,
                  self.activeConfigurationRecord?.id == configurationID,
                  Self.historyContentMatches(detail, record: record) else { return }
            let choices = Self.historyPlaybackChoices(in: detail, record: record)
            guard choices.count == 1, let choice = choices.first else { return }
            self.activePlayback?.detail = detail
            self.activePlayback?.source = choice.source
            self.activePlayback?.episode = choice.episode
            self.isPlayerEpisodeListIncomplete = false
            self.preparePlayerEpisodePresentations(detail: detail, source: choice.source, sessionID: sessionID)
        }
    }

    var playerEpisodeSelectionSessionID: UUID { playbackSessionID }
    var canSelectPlayerEpisode: Bool {
        (activePlayback != nil || pendingPlayback != nil)
            && (playbackResolutionState == .playing || canRetryPlayerEpisode)
    }

    func playPlayerEpisode(_ episode: PlayEpisode, expectedSessionID: UUID? = nil) async {
        guard expectedSessionID == nil || expectedSessionID == playbackSessionID,
              canSelectPlayerEpisode,
              let detail = activePlayback?.detail ?? pendingPlayback?.detail,
              let source = activePlayback?.source ?? pendingPlayback?.source,
              source.episodes.contains(episode) else {
            return
        }
        guard episode.id != currentPlayerEpisodeID || canRetryPlayerEpisode else { return }
        if episode.id == currentPlayerEpisodeID, activePlayback == nil,
           let record = pendingPlayback?.origin.historyRecord {
            requestHistoryPlayback(record)
            return
        }
        await startPlayback(
            detail: detail,
            source: source,
            episode: episode,
            configurationID: activePlayback?.configurationID ?? pendingPlayback?.configurationID,
            windowActivation: .preserveFocus
        )
    }

    func reportPlayerRenderError(_ error: Error) {
        guard isPlayerPresented else { return }
        presentPlaybackErrorOnce(localizedRuntimeErrorMessage(error), requestID: activePlayerRequestID)
    }

    var visibleSites: [SiteConfiguration] {
        (activeConfiguration?.sites ?? []).filter { $0.hide == 0 }
    }

    /// Includes CatPawOpen catalogue entries that are intentionally absent
    /// from its enabled `/config`, while keeping them out of the Home source
    /// menu. These entries can be explicitly re-enabled in Search scope.
    var searchCatalogSites: [SiteConfiguration] {
        (activeConfiguration?.sites ?? []).filter {
            $0.hide == 0 || $0.extra["okNodeCatalogDisabled"] == .bool(true)
        }
    }

    private var providerCatalogSites: [SiteConfiguration] {
        searchCatalogSites
    }

    var supportedSites: [SiteConfiguration] {
        visibleSites.filter {
            providers[$0.key]?.capability != .unsupportedSpider
        }
    }

    func siteCapability(for key: String) -> SiteCapability? {
        providers[key]?.capability
    }

    var currentSite: SiteConfiguration? {
        visibleSites.first { $0.key == selectedSiteKey }
    }

    var homePresentationNeedsRecovery: Bool {
        guard let home = siteHome else { return false }
        return !HomeResumePolicy.isStructurallyValid(
            home: home,
            selection: homePresentationSelection,
            selectedCategoryID: selectedCategoryID
        )
    }

    var isConfigurationInteractionActive: Bool {
        configurationInteractionCoordinator.hasActiveRequest
    }

    var systemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var architectureDescription: String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return L10n.string("system.architecture.unknown", fallback: "Unknown Architecture")
        #endif
    }

    var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.3.20"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "\(version) (\(build))"
    }

    func refreshAndroidRuntimeStatus() async {
        guard !isAndroidRuntimeBusy else { return }
        guard let environment else {
            androidRuntimeStatus = .unavailable(
                L10n.string("android.runtime.environment-uninitialized", fallback: "The application environment has not finished initializing.")
            )
            return
        }
        androidRuntimeModeSnapshot = await environment
            .androidRuntimeModeCoordinator.refresh()
        androidRuntimeStatus = await environment.androidDexBridge.runtimeStatus()
        _ = try? await environment.androidRuntimeManager.refresh()
    }

    func showManagedRuntimeInstaller() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        do {
            try await environment.androidRuntimeManager.presentInstallOffer()
            isAndroidRuntimeInstallSheetPresented = true
        } catch {
            show(error, title: L10n.string("android.runtime.component-unavailable", fallback: "Android Compatibility Component Unavailable"))
        }
    }

    func installManagedRuntime(acceptingLicenses: Bool) async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        do {
            try await environment.androidRuntimeManager.installDefault(
                acceptingLicenses: acceptingLicenses
            )
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            await refreshAndroidStorage()
        } catch is CancellationError {
            return
        } catch {
            // The manager publishes a path-free product error in the sheet.
        }
    }

    func cancelManagedRuntimeInstallation() async {
        guard let environment else { return }
        await environment.androidRuntimeManager.cancel()
    }

    func repairManagedRuntime(acceptingLicenses: Bool) async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        if androidRuntimeStatus.isRunning {
            androidRuntimeStatus = await environment.androidDexBridge.stopRuntime()
        }
        do {
            try await environment.androidRuntimeManager.repair(
                acceptingLicenses: acceptingLicenses
            )
        } catch is CancellationError {
            return
        } catch {
            // The manager keeps the previous generation recoverable and
            // publishes the appropriate retry/diagnostic state.
        }
    }

    func dismissManagedRuntimeInstaller() {
        guard !managedRuntimeInstallationState.isBusy else { return }
        isAndroidRuntimeInstallSheetPresented = false
        if case .available = managedRuntimeInstallationState {
            Task { [weak self] in
                guard let manager = self?.environment?.androidRuntimeManager
                else { return }
                await manager.cancel()
            }
        }
    }

    func chooseAndroidSDK() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        while true {
            let panel = NSOpenPanel()
            panel.title = L10n.string("android.sdk.choose.title", fallback: "Choose Android SDK")
            panel.message = L10n.string("android.sdk.choose.message", fallback: "Choose an Android SDK folder containing platform-tools and emulator.")
            panel.prompt = L10n.string("android.sdk.choose.action", fallback: "Check SDK")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = androidRuntimeModeSnapshot.externalSDKRoot?
                .deletingLastPathComponent()
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Library/Android",
                        isDirectory: true
                    )
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let validation = await environment.androidRuntimeModeCoordinator
                .previewExternalSDK(url)
            let alert = NSAlert()
            alert.alertStyle = validation.canPrepareRuntime
                ? .informational
                : .warning
            alert.messageText = validation.canSelectEnvironment
                ? (validation.canPrepareRuntime
                    ? L10n.string("android.sdk.validation.usable", fallback: "The Existing Android SDK Can Be Used")
                    : L10n.string("android.sdk.validation.rebuild-needed", fallback: "The Dedicated Environment Must Be Rebuilt"))
                : L10n.string("android.sdk.validation.unavailable", fallback: "The Existing Android SDK Is Unavailable")
            alert.informativeText = [
                L10n.string("android.sdk.validation.location", fallback: "Location: %@", validation.sdkRoot.path),
                L10n.string("android.sdk.validation.launch", fallback: "Launch capability: %@", validation.launchCapability.detail),
                L10n.string("android.sdk.validation.repair", fallback: "Create/repair capability: %@", validation.createRepairCapability.detail),
                validation.userFacingSelectionStatus
            ].joined(separator: "\n")
            if validation.canSelectEnvironment {
                alert.addButton(withTitle: L10n.string("android.sdk.use", fallback: "Use This Environment"))
                alert.addButton(withTitle: L10n.string("common.cancel", fallback: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return
                }
                do {
                    androidRuntimeModeSnapshot = try await environment
                        .androidRuntimeModeCoordinator.useExternalSDK(url)
                    isAndroidRuntimeInstallSheetPresented = false
                    androidRuntimeStatus = await environment.androidDexBridge
                        .runtimeStatus()
                } catch {
                    show(error, title: L10n.string("android.runtime.switch.failed", fallback: "Unable to Switch Android Runtime"))
                }
                return
            }
            alert.addButton(withTitle: L10n.string("android.sdk.choose-again", fallback: "Choose Again…"))
            alert.addButton(withTitle: L10n.string("common.cancel", fallback: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
    }

    func useConfiguredExternalAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        do {
            androidRuntimeModeSnapshot = try await environment
                .androidRuntimeModeCoordinator.useConfiguredExternalSDK()
            isAndroidRuntimeInstallSheetPresented = false
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
        } catch {
            show(error, title: L10n.string("android.sdk.unavailable", fallback: "Existing Android SDK Unavailable"))
        }
    }

    func useManagedAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        do {
            androidRuntimeModeSnapshot = try await environment
                .androidRuntimeModeCoordinator.useManagedRuntime()
            _ = try? await environment.androidRuntimeManager.refresh()
            if !androidRuntimeModeSnapshot.managedRuntimeUsable {
                await showManagedRuntimeInstaller()
            }
        } catch {
            show(error, title: L10n.string("android.runtime.switch.failed", fallback: "Unable to Switch Android Runtime"))
        }
    }

    func startAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        androidRuntimeStatus = .starting(
            L10n.string("android.runtime.start.preparing", fallback: "Preparing to Start Android Compatibility Module"),
            progress: 0
        )
        let progressTask = monitorAndroidRuntimeProgress(
            environment.androidDexBridge
        )
        defer {
            progressTask.cancel()
            isAndroidRuntimeBusy = false
        }
        do {
            try await environment.androidRuntimeModeCoordinator.prepareRuntime()
            androidRuntimeStatus = try await environment.androidDexBridge
                .startRuntime()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            show(error, title: L10n.string("android.runtime.start.failed", fallback: "Unable to Start Android Compatibility Module"))
        }
    }

    func stopAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        androidRuntimeStatus = .stopping
        androidRuntimeStatus = await environment.androidDexBridge.stopRuntime()
        isAndroidRuntimeBusy = false
    }

    func repairAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        androidRuntimeStatus = .starting(
            L10n.string("android.runtime.repair.preparing", fallback: "Preparing to Rebuild Port Mapping and Reinstall Bridge"),
            progress: 0
        )
        let progressTask = monitorAndroidRuntimeProgress(
            environment.androidDexBridge
        )
        defer {
            progressTask.cancel()
            isAndroidRuntimeBusy = false
        }
        do {
            try await environment.androidRuntimeModeCoordinator.prepareRuntime()
            androidRuntimeStatus = try await environment.androidDexBridge
                .repairRuntime()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            show(error, title: L10n.string("android.runtime.repair.failed", fallback: "Unable to Repair Android Compatibility Module"))
        }
    }

    func rebuildAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("android.runtime.rebuild.title", fallback: "Repair Android Runtime?")
        alert.informativeText =
            L10n.string(
                "android.runtime.rebuild.message",
                fallback: "The current OKVideoMac Android Runtime will be moved to a recoverable backup, then rebuilt using an existing system image from the selected Android SDK.\n\nThe runtime's internal state will be reset, and some cloud drives may require you to sign in or authorize again. OKVideoMac settings, favorites, and history will not be affected."
            )
        alert.addButton(withTitle: L10n.string("android.runtime.rebuild.action", fallback: "Back Up and Rebuild"))
        alert.addButton(withTitle: L10n.string("common.cancel", fallback: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isAndroidRuntimeBusy = true
        androidRuntimeStatus = .starting(
            L10n.string("android.runtime.rebuild.progress", fallback: "Backing Up and Rebuilding the OKVideoMac Android Runtime"),
            progress: 0
        )
        let progressTask = monitorAndroidRuntimeProgress(
            environment.androidDexBridge
        )
        defer {
            progressTask.cancel()
            isAndroidRuntimeBusy = false
        }
        do {
            try await environment.androidRuntimeModeCoordinator
                .prepareRuntimeRepair()
            androidRuntimeStatus = try await environment.androidDexBridge
                .rebuildRuntime()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            show(error, title: L10n.string("android.runtime.rebuild.failed", fallback: "Unable to Rebuild Android Runtime"))
        }
    }

    private func monitorAndroidRuntimeProgress(
        _ bridge: AndroidDexBridgeClient
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let status = await bridge.runtimeStatus()
                guard !Task.isCancelled else { return }
                if status.phase == .starting || status.phase == .stopping {
                    self?.androidRuntimeStatus = status
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    var playerStatusDescription: String {
        switch playerSnapshot.status {
        case .idle: return L10n.string("player.status.idle", fallback: "Idle")
        case .loading: return L10n.string("player.status.loading", fallback: "Loading")
        case .playing: return L10n.string("player.status.playing", fallback: "Playing")
        case .paused: return L10n.string("player.status.paused", fallback: "Paused")
        case .buffering: return L10n.string("player.status.buffering", fallback: "Buffering")
        case .ended: return L10n.string("player.status.ended", fallback: "Ended")
        case .stopped: return L10n.string("player.status.stopped", fallback: "Stopped")
        case .failed(let message):
            return L10n.string("player.status.failed", fallback: "Failed: %@", LogRedactor.text(message))
        }
    }

    var imageRepository: ImageRepository? {
        environment?.imageRepository
    }

    var embeddedPlayer: MPVPlayerClient? {
        playerRenderClient
    }

    var playerRuntimeDescription: String {
        environment?.player.runtimeDescription
            ?? L10n.string("player.runtime.unavailable", fallback: "libmpv unavailable")
    }

    var currentPlaybackTitle: String {
        if let playback = activePlayback {
            return playback.episode.name
        }
        if let pendingPlayback {
            return pendingPlayback.episode.name
        }
        return livePlaybackDisplayTitle
    }

    var currentPlaybackContentTitle: String? {
        activePlayback?.detail.summary.title
            ?? pendingPlayback?.detail.summary.title
    }

    var currentPlaybackEpisode: PlayEpisode? {
        activePlayback?.episode ?? pendingPlayback?.episode
    }

    var isLivePlayback: Bool {
        livePlaybackChannel != nil
    }

    var canSeekPlayback: Bool {
        guard !isLivePlayback, activePlayback != nil else {
            return false
        }
        return activePlayback?.playbackResult?.mediaSession?.rangePolicy
            != .unsupported
    }

    var canSwitchLiveChannel: Bool {
        guard isPlayerPresented,
              let currentChannel = livePlaybackChannel,
              let sourceID = livePlaybackSourceID,
              let context = livePlaybackNavigationContext,
              context.sourceID == sourceID,
              context.channels.count > 1 else {
            return false
        }
        return context.channels.contains { $0.id == currentChannel.id }
    }

    var livePlaybackDisplayTitle: String {
        guard let channel = livePlaybackChannel else {
            return L10n.string("live.title", fallback: "Live TV")
        }
        guard let number = channel.number?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !number.isEmpty,
        !channel.name.localizedCaseInsensitiveContains(number) else {
            return channel.name
        }
        return "\(number) \(channel.name)"
    }

    var livePlaybackProgrammes: (
        current: EPGProgramme?,
        next: EPGProgramme?
    ) {
        guard let channel = livePlaybackChannel,
              let sourceID = livePlaybackSourceID else {
            return (nil, nil)
        }
        return liveProgrammes(for: channel, sourceID: sourceID, at: Date())
    }

    func liveProgrammes(
        for channel: LiveChannel,
        sourceID: LiveSourceID,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        let result = liveEPG.nowNext(channel: channel, source: sourceID, at: date)
        return (result.current, result.next)
    }

    func liveProgrammes(
        for channel: LiveChannel,
        sourceID: UUID,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        liveProgrammes(for: channel, sourceID: .imported(sourceID), at: date)
    }

    var playbackStageDescription: String {
        if case .failed = playerSnapshot.status {
            return L10n.string("player.stage.failed", fallback: "Playback Failed")
        }
        if playerSnapshot.isSeeking && playerSnapshot.isPausedForCache {
            return cacheActivityDescription(
                prefix: L10n.string("player.stage.seeking-buffering", fallback: "Seeking and Buffering")
            )
        }
        if playerSnapshot.isPausedForCache {
            return cacheActivityDescription(
                prefix: L10n.string("player.stage.buffering", fallback: "Buffering")
            )
        }
        if playerSnapshot.isSeeking {
            guard let target = playerSnapshot.seekTarget else {
                return L10n.string("player.stage.seeking", fallback: "Seeking")
            }
            return L10n.string(
                "player.stage.seeking-to",
                fallback: "Seeking to %@",
                Self.playbackTimeDescription(target)
            )
        }
        switch playbackResolutionState {
        case .idle: return playerStatusDescription
        case .restoringHistory: return L10n.string("player.stage.restoring-history", fallback: "Restoring History")
        case .resolving: return L10n.string("player.stage.resolving", fallback: "Resolving Playback URL")
        case .validating: return L10n.string("player.stage.validating", fallback: "Validating Media Source")
        case .loading: return L10n.string("player.stage.connecting", fallback: "Connecting to Media")
        case .playing: return playerStatusDescription
        case .retrying: return L10n.string("player.stage.retrying", fallback: "Source Failed; Trying Another")
        case .exhausted: return L10n.string("player.stage.exhausted", fallback: "All Available Sources Were Tried")
        case .failed: return L10n.string("player.stage.prepare-failed", fallback: "Playback Preparation Failed")
        }
    }

    private func cacheActivityDescription(prefix: String) -> String {
        let percent = Int(playerSnapshot.bufferedPercent.rounded())
        guard (1..<100).contains(percent) else { return prefix }
        return "\(prefix) \(percent)%"
    }

    private static func playbackTimeDescription(
        _ value: TimeInterval
    ) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let totalSeconds = Int(value.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var playerNetworkSpeedDescription: String {
        let bytes = playerSnapshot.networkSpeedBytesPerSecond
        guard bytes > 0 else {
            switch playerSnapshot.status {
            case .loading, .buffering:
                return L10n.string("player.network.zero", fallback: "Current speed: 0 KB/s")
            default:
                return L10n.string("player.network.waiting", fallback: "Waiting for media data")
            }
        }
        let value = ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
        return L10n.string("player.network.speed", fallback: "Current speed: %@/s", value)
    }

    private var automaticNextEpisode: PlayEpisode? {
        guard let playback = activePlayback, let cache = playerEpisodePresentationCache,
              cache.key.source == playback.source, cache.key.categoryName == playback.detail.summary.categoryName,
              let index = episodeQueue(cache, current: playback.episode).firstIndex(where: { $0.id == playback.episode.id }),
              episodeQueue(cache, current: playback.episode).indices.contains(index + 1) else { return nil }
        return episodeQueue(cache, current: playback.episode)[index + 1]
    }

    var hasPreviousEpisode: Bool {
        hasAdjacentEpisode(offset: -1)
    }

    var hasNextEpisode: Bool {
        hasAdjacentEpisode(offset: 1)
    }

    var playerEpisodes: [PlayEpisode] {
        activePlayback?.source.episodes ?? pendingPlayback?.source.episodes ?? []
    }

    var currentPlayerEpisodePresentation: EpisodePresentation? {
        guard let episodeID = currentPlayerEpisodeID else { return nil }
        let detail = activePlayback?.detail ?? pendingPlayback?.detail
        let source = activePlayback?.source ?? pendingPlayback?.source
        if let cache = playerEpisodePresentationCache,
           cache.key.videoID == detail?.summary.id, cache.key.source == source,
           cache.key.categoryName == detail?.summary.categoryName,
           let cached = cache.valuesByEpisodeID[episodeID] {
            return cached
        }
        guard let episode = playerEpisodes.first(where: { $0.id == episodeID }) else {
            return nil
        }
        // While the actor prepares a long list, display this file conservatively.
        // A singleton fallback must not relabel a movie edition as the sole feature.
        return EpisodeNameParser.presentation(for: episode, categoryName: detail?.summary.categoryName)
    }

    var playerHasEpisodeNames: Bool {
        guard let episode = currentPlaybackEpisode else { return false }
        let category = (activePlayback?.detail ?? pendingPlayback?.detail)?.summary.categoryName
        return playerEpisodePresentations.contains { $0.episodeNumber != nil }
            || PlaybackResourceAnalyzer.analyze(episode, categoryName: category).form == .series
    }

    var playerResourcePanelTitle: String {
        if playerUsesVersionNames { return L10n.string("player.versions", fallback: "Versions") }
        return playerHasEpisodeNames ? L10n.string("player.episodes", fallback: "Episodes")
            : L10n.string("detail.playable-resources", fallback: "Playable Resources")
    }

    var playerResourceCountText: String {
        L10n.string(playerUsesVersionNames ? "player.version-count" : "player.resource-count",
            fallback: "%d resources", playerEpisodes.count)
    }

    var previousPlayerResourceTitle: String {
        L10n.string(playerHasEpisodeNames ? "player.previous-episode" : "player.previous-resource", fallback: "Previous Resource")
    }
    var nextPlayerResourceTitle: String {
        L10n.string(playerHasEpisodeNames ? "player.next-episode" : "player.next-resource", fallback: "Next Resource")
    }

    private func episodeQueue(_ cache: PlayerEpisodePresentationCache, current: PlayEpisode) -> [PlayEpisode] {
        (cache.playbackOrder.isEmpty || cache.versionOrders.count > 1)
            ? cache.versionOrders[PlayerEpisodeAdvancePolicy.versionKey(current)] ?? []
            : cache.playbackOrder
    }

    private var manuallyOrderedPlayerEpisodes: [PlayEpisode] {
        guard let playback = activePlayback else { return [] }
        let ordered = playerEpisodePresentationCache.flatMap { cache in
            cache.key.source == playback.source && cache.key.categoryName == playback.detail.summary.categoryName
                ? episodeQueue(cache, current: playback.episode) : nil
        } ?? []
        return ordered.contains(where: { $0.id == playback.episode.id }) ? ordered : (playerHasEpisodeNames ? [] : playback.source.episodes)
    }

    var playerUsesVersionNames: Bool {
        guard let episode = currentPlaybackEpisode else { return false }
        let category = (activePlayback?.detail ?? pendingPlayback?.detail)?.summary.categoryName
        return PlaybackResourceAnalyzer.analyze(episode, categoryName: category).form == .movie
    }

    var currentPlayerEpisodeID: String? {
        activePlayback?.episode.id ?? pendingPlayback?.episode.id
    }

    private func preparePlayerEpisodePresentations(
        detail: VideoDetail,
        source: PlaySource,
        sessionID: UUID
    ) {
        let key = PlayerEpisodePresentationCacheKey(
            categoryName: detail.summary.categoryName,
            source: source,
            videoID: detail.summary.id,
            sourceID: source.id,
            episodeCount: source.episodes.count,
            firstEpisodeID: source.episodes.first?.id,
            lastEpisodeID: source.episodes.last?.id
        )
        playerEpisodePreparationTask?.cancel()
        if let cache = playerEpisodePresentationCache,
           cache.key == key {
            playerEpisodePresentations = cache.values
            isPlayerEpisodeListPreparing = false
            return
        }
        playerEpisodePreparationTask?.cancel()
        playerEpisodePresentations = []
        isPlayerEpisodeListPreparing = true
        playerEpisodePreparationTask = Task { [weak self] in
            let snapshot = await EpisodePresentationRepository.shared.snapshot(
                videoID: detail.summary.id,
                source: source,
                categoryName: detail.summary.categoryName
            )
            guard !Task.isCancelled, let self,
                  self.playbackSessionID == sessionID else { return }
            let cache = PlayerEpisodePresentationCache(
                key: key,
                values: snapshot.values,
                valuesByEpisodeID: snapshot.valuesByEpisodeID,
                playbackOrder: snapshot.playbackOrder,
                versionOrders: snapshot.versionOrders
            )
            self.playerEpisodePresentationCache = cache
            self.playerEpisodePresentations = snapshot.values
            self.isPlayerEpisodeListPreparing = false
            self.playerEpisodePreparationTask = nil
        }
    }

    nonisolated static func orderedPlaybackSources(
        _ sources: [PlaySource],
        selectedSourceID: String
    ) -> [PlaySource] {
        guard let selectedIndex = sources.firstIndex(where: {
            $0.id == selectedSourceID
        }) else { return [] }
        let selected = sources[selectedIndex]
        var output = [selected]
        output.append(contentsOf: sources.dropFirst(selectedIndex + 1))
        output.append(contentsOf: sources.prefix(selectedIndex))
        return output
    }

    private func openSearchFolder(
        _ summary: VideoSummary,
        replacingPath: Bool,
        origin: SearchFolderOrigin?
    ) {
        cancelDetailRequest()
        detailRouteSummary = nil
        selectedDetail = nil
        pendingDetailSummary = nil
        let resolvedOrigin = origin
            ?? searchFolderOrigin
            ?? (isHomeSearchPresented ? .searchResults : .home)
        let navigationContext: SearchFolderNavigationContext
        if !replacingPath,
           let inherited = searchFolderPath.last?.navigationContext {
            navigationContext = inherited
        } else {
            navigationContext = searchFolderNavigationContext(for: summary)
        }
        presentHomeSearch()
        let page = SearchFolderPage(
            folder: summary,
            navigationContext: navigationContext
        )
        if replacingPath {
            searchFolderPath = [page]
            searchFolderOrigin = resolvedOrigin
        } else {
            if searchFolderOrigin == nil {
                searchFolderOrigin = resolvedOrigin
            }
            searchFolderPath.append(page)
        }
        Task {
            await loadSearchFolder(
                id: page.id,
                summary: summary,
                page: 1
            )
        }
    }

    private func searchFolderNavigationContext(
        for summary: VideoSummary
    ) -> SearchFolderNavigationContext {
        let site = supportedSites.first { $0.key == summary.siteKey }
        guard let record = activeConfigurationRecord else {
            return .legacy(siteKey: summary.siteKey)
        }
        return SearchFolderNavigationContext(
            navigationMode: NodeSiteNavigationMode.resolve(for: site),
            sourceSiteKey: summary.siteKey,
            configurationID: record.id,
            configurationRevision:
                CategoryConfigurationRevision.make(record: record),
            nodeSiteIdentity: site?.extra[
                "okNodeSiteIdentity"
            ]?.stringValue
        )
    }

    private func loadSearchFolder(
        id: UUID,
        summary: VideoSummary,
        page pageNumber: Int
    ) async {
        guard let provider = providers[summary.siteKey] else {
            updateSearchFolder(id: id) { page in
                page.failedPage = pageNumber
                page.isLoading = false
                page.errorMessage = L10n.string(
                    "provider.current-configuration.unavailable",
                    fallback: "%@ is unavailable in the current configuration.",
                    summary.siteName
                )
            }
            return
        }

        let requestID = UUID()
        updateSearchFolder(id: id) { $0.requestID = requestID }
        do {
            let loaded = try await provider.category(
                id: summary.videoID,
                page: pageNumber,
                filters: [:]
            )
            updateSearchFolder(id: id) { page in
                guard page.requestID == requestID else { return }
                var cursor = SearchPageCursor(keyword: "")
                if pageNumber > 1, let pagination = page.pagination {
                    cursor.accept(VideoPage(items: page.items, pagination: pagination), requestedPage: pagination.page)
                }
                guard cursor.accept(loaded, requestedPage: pageNumber) else {
                    page.failedPage = pageNumber
                page.isLoading = false
                    page.paginationIssueKind = .uncertain
                    page.errorMessage = L10n.string("pagination.uncertain", fallback: "No new titles; the end of results is not confirmed")
                    return
                }
                let currentPage = page.pagination.map {
                    VideoPage(items: page.items, pagination: $0)
                }
                let merged = VideoPageMerger.merge(
                    current: pageNumber > 1 ? currentPage : nil,
                    loaded: loaded,
                    requestedPage: pageNumber
                )
                page.items = merged.items
                page.pagination = merged.pagination
                page.failedPage = pageNumber
                page.isLoading = false
                page.errorMessage = nil
                page.failedPage = nil
            }
        } catch {
            updateSearchFolder(id: id) { page in
                guard page.requestID == requestID else { return }
                page.failedPage = pageNumber
                page.isLoading = false
                page.paginationIssueKind = error is CategoryPageResponseError ? .uncertain : .failed
                page.errorMessage = localizedRuntimeErrorMessage(error)
            }
        }
    }

    private func updateSearchFolder(
        id: UUID,
        _ update: (inout SearchFolderPage) -> Void
    ) {
        if let index = searchFolderPath.firstIndex(where: { $0.id == id }) {
            update(&searchFolderPath[index])
            return
        }
        // A discovery leaf temporarily replaces the visible Folder with an
        // aggregate search. If a page request was already in flight, publish
        // it into the retained snapshot so returning never strands the Folder
        // in a loading state or loses a completed pagination page.
        guard let snapshot = discoverySearchReturnSnapshot,
              let index = snapshot.folderPath.firstIndex(
                  where: { $0.id == id }
              ) else {
            return
        }
        var folderPath = snapshot.folderPath
        update(&folderPath[index])
        discoverySearchReturnSnapshot = DetailHomeSearchReturnSnapshot(
            selectedSiteKey: snapshot.selectedSiteKey,
            folderPath: folderPath,
            folderOrigin: snapshot.folderOrigin
        )
    }

    enum HistoryConfigurationResolution: Equatable {
        case current
        case switchTo(UUID)
        case unavailable
        case legacy
    }

    static func historyConfigurationResolution(
        record: HistoryRecord,
        activeConfigurationID: UUID?,
        availableConfigurationIDs: Set<UUID>
    ) -> HistoryConfigurationResolution {
        guard let configurationID = record.configurationID else {
            return .legacy
        }
        if configurationID == activeConfigurationID {
            return .current
        }
        return availableConfigurationIDs.contains(configurationID)
            ? .switchTo(configurationID)
            : .unavailable
    }

    func historyConfigurationName(for record: HistoryRecord) -> String {
        guard let configurationID = record.configurationID else {
            return L10n.string("history.legacy-record", fallback: "Legacy Record")
        }
        return configurations.first(where: { $0.id == configurationID })?.name
            ?? L10n.string("history.original-configuration-deleted", fallback: "Original Configuration Deleted")
    }

    func historySiteName(for record: HistoryRecord) -> String {
        guard record.configurationID == activeConfigurationRecord?.id else {
            return record.siteKey
        }
        let configuredName = activeConfiguration?.sites.first(where: {
            $0.key == record.siteKey
        })?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredName, !configuredName.isEmpty else {
            return record.siteKey
        }
        return configuredName
    }

    static func historyContentMatches(_ detail: VideoDetail, record: HistoryRecord) -> Bool {
        guard detail.summary.siteKey == record.siteKey,
              let expected = historySearchQuery(for: record.title),
              let actual = historySearchQuery(for: detail.summary.title) else { return false }
        return actual.compare(expected, options: [
            .caseInsensitive, .widthInsensitive, .diacriticInsensitive
        ]) == .orderedSame
    }

    static func historyPlaybackSelection(
        in detail: VideoDetail,
        record: HistoryRecord
    ) -> (source: PlaySource, episode: PlayEpisode)? {
        guard historyContentMatches(detail, record: record) else { return nil }
        let structuralSources = record.playbackReference.map { reference in
            detail.playSources.filter {
                $0.stableIdentity == reference.sourceIdentity
            }
        } ?? []
        let namedSources = record.sourceName?.nonEmpty.map { sourceName in
            detail.playSources.filter {
                $0.name.compare(
                    sourceName,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame
            }
        } ?? []
        let preferredSources = structuralSources.isEmpty
            ? namedSources
            : structuralSources

        if let resourceIdentity = record.playbackReference?.resourceIdentity {
            let preferredMatches = playbackMatches(
                in: preferredSources,
                resourceIdentity: resourceIdentity
            )
            if preferredMatches.count == 1 {
                return preferredMatches[0]
            }

            // A provider may reorganize or rename a source. Cross-source
            // recovery is safe only when the stable resource is globally
            // unique; ambiguity must never be resolved by list order.
            let globalMatches = playbackMatches(
                in: detail.playSources,
                resourceIdentity: resourceIdentity
            )
            if globalMatches.count == 1 {
                return globalMatches[0]
            }
        }

        // Cloud and scripted providers commonly rewrite the visible filename
        // while retaining the same opaque episode token. The token is the
        // strongest identity and must take precedence over display text.
        if let episodeReference = record.episodeReference?.nonEmpty {
            let normalizedReference = episodeReference.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let preferredMatches = preferredSources.flatMap { source in
                source.episodes.filter {
                    $0.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        == normalizedReference
                }.map { (source, $0) }
            }
            if preferredMatches.count == 1 {
                return preferredMatches[0]
            }
            let globalMatches = detail.playSources.flatMap { source in
                source.episodes.filter {
                    $0.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        == normalizedReference
                }.map { (source, $0) }
            }
            if globalMatches.count == 1 {
                return globalMatches[0]
            }

            // Quark episode URLs contain an expiring stoken. When detail has
            // refreshed the same share/file, prefer that fresh URL even if the
            // display name or the opaque token changed.
            if let identity = QuarkEpisodeReference.identity(
                from: normalizedReference
            ) {
                let matches = detail.playSources.flatMap { source in
                source.episodes.filter {
                        QuarkEpisodeReference.identity(from: $0.url) == identity
                    }.map { (source, $0) }
                }
                if matches.count == 1 {
                    return matches[0]
                }
            }
        }

        if let recipe = record.playbackReference?.navigationRecipe,
           let recipeSelection = historyRecipeSelection(
            in: detail,
            recipe: recipe
           ) {
            return recipeSelection
        }

        if let episodeName = record.episodeName?.nonEmpty {
            let exactMatches = preferredSources.flatMap { source in
                source.episodes.filter {
                    $0.name.compare(
                        episodeName,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                }.map { (source, $0) }
            }
            if exactMatches.count == 1 {
                return exactMatches[0]
            }

            let normalizedFilename = historyNormalizedFilename(episodeName)
            if !normalizedFilename.isEmpty {
                let filenameMatches = preferredSources.flatMap { source in
                    source.episodes.compactMap { episode in
                        historyNormalizedFilename(episode.name)
                            == normalizedFilename
                            ? (source, episode)
                            : nil
                    }
                }
                if filenameMatches.count == 1 {
                    return filenameMatches[0]
                }
                let globalFilenameMatches = detail.playSources.flatMap { source in
                    source.episodes.compactMap { episode in
                        historyNormalizedFilename(episode.name)
                            == normalizedFilename
                            ? (source, episode)
                            : nil
                    }
                }
                if globalFilenameMatches.count == 1 {
                    return globalFilenameMatches[0]
                }
            }

            let recorded = PlaybackResourceAnalyzer.analyze(
                PlayEpisode(name: episodeName, url: "history-identity"), categoryName: detail.summary.categoryName)
            for sources in [preferredSources, detail.playSources] {
                let matches = sources.flatMap { source in
                    source.episodes.compactMap { candidate -> (PlaySource, PlayEpisode)? in
                        reliableHistoryEpisodeMatches(recorded, candidate: candidate, categoryName: detail.summary.categoryName)
                            ? (source, candidate) : nil
                    }
                }
                if matches.count == 1 { return matches[0] }
                if matches.count > 1 { return nil }
            }
        }

        return nil
    }

    static func historyPlaybackChoices(
        in detail: VideoDetail,
        record: HistoryRecord
    ) -> [(source: PlaySource, episode: PlayEpisode)] {
        guard historyContentMatches(detail, record: record) else { return [] }
        if let selection = historyPlaybackSelection(in: detail, record: record) {
            return [selection]
        }

        let recipe = record.playbackReference?.navigationRecipe
        let recordedName = recipe?.episode.name.nonEmpty
            ?? record.episodeName?.nonEmpty
        let normalizedFilename = recipe?.episode.normalizedFilename.nonEmpty
            ?? recordedName.map(historyNormalizedFilename)
        let recordedSemantics = PlaybackResourceAnalyzer.analyze(
            PlayEpisode(name: recordedName ?? "", url: "history-choice", metadata: recipe?.episode.metadata),
            categoryName: recipe?.episode.categoryName ?? detail.summary.categoryName)
        let sourceNames = [
            recipe?.source.flag.nonEmpty,
            recipe?.source.name.nonEmpty,
            record.sourceName?.nonEmpty
        ].compactMap { $0 }

        var matches: [(PlaySource, PlayEpisode)] = []
        for source in detail.playSources {
            let sourceMatches = sourceNames.contains { name in
                source.name.compare(
                    name,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame
            }
            for episode in source.episodes {
                let exactName = recordedName.map {
                    episode.name.compare(
                        $0,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                } ?? false
                let filenameMatch = normalizedFilename.map {
                    !$0.isEmpty && historyNormalizedFilename(episode.name) == $0
                } ?? false
                let episodeNumberMatch = reliableHistoryEpisodeMatches(recordedSemantics,
                    candidate: episode, categoryName: detail.summary.categoryName)
                if (sourceMatches && (exactName || filenameMatch || episodeNumberMatch))
                    || filenameMatch {
                    matches.append((source, episode))
                }
            }
        }
        return matches
    }

    private static func historyRecipeSelection(
        in detail: VideoDetail,
        recipe: HistoryNavigationRecipe
    ) -> (source: PlaySource, episode: PlayEpisode)? {
        struct ScoredMatch {
            let source: PlaySource
            let episode: PlayEpisode
            let score: Int
        }

        var matches: [ScoredMatch] = []
        for source in detail.playSources {
            var sourceScore = 0
            if let stableID = recipe.source.providerStableID,
               stableID == source.referenceIdentity
                    || stableID == source.stableIdentity {
                sourceScore = 1_000
            } else if [recipe.source.flag, recipe.source.name].contains(where: {
                source.name.compare(
                    $0,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame
            }) {
                sourceScore = 400
            }

            for episode in source.episodes {
                var episodeScore = 0
                if let stableID = recipe.episode.providerStableID,
                   stableID == episode.referenceIdentity
                        || stableID == episode.stableIdentity {
                    episodeScore = 1_200
                } else if historyNormalizedFilename(episode.name)
                            == recipe.episode.normalizedFilename,
                          !recipe.episode.normalizedFilename.isEmpty {
                    episodeScore = 700
                } else if episode.name.compare(
                    recipe.episode.name,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame {
                    episodeScore = 500
                } else {
                    let recorded = PlaybackResourceAnalyzer.analyze(
                        PlayEpisode(name: recipe.episode.name, url: "history-recipe", metadata: recipe.episode.metadata),
                        categoryName: recipe.episode.categoryName ?? detail.summary.categoryName)
                    if reliableHistoryEpisodeMatches(recorded, candidate: episode, categoryName: detail.summary.categoryName) {
                        episodeScore = 250
                    }
                }
                let score = sourceScore + episodeScore
                // Source names and list positions do not identify a file.
                // A reordered/replaced playlist must have episode evidence.
                if episodeScore > 0 {
                    matches.append(
                        ScoredMatch(
                            source: source,
                            episode: episode,
                            score: score
                        )
                    )
                }
            }
        }
        guard let bestScore = matches.map(\.score).max() else { return nil }
        let best = matches.filter { $0.score == bestScore }
        guard best.count == 1, let selection = best.first else { return nil }
        return (selection.source, selection.episode)
    }

    private static func reliableHistoryEpisodeMatches(_ recorded: PlaybackResourceSemantics,
                                                      candidate: PlayEpisode, categoryName: String?) -> Bool {
        let value = PlaybackResourceAnalyzer.analyze(candidate, categoryName: categoryName)
        return recorded.hasReliableEpisode && value.hasReliableEpisode
            && recorded.episode == value.episode && recorded.season == value.season
            && recorded.versionLabels == value.versionLabels
    }

    static func historyEpisodeDisplayName(_ record: HistoryRecord) -> String? {
        guard let name = record.episodeName else { return nil }
        let saved = record.playbackReference?.navigationRecipe?.episode
        return EpisodeNameParser.presentation(for: PlayEpisode(name: name, url: "history-display", metadata: saved?.metadata),
            categoryName: saved?.categoryName).displayName
    }

    static func historyNormalizedFilename(_ rawName: String) -> String {
        var value = rawName.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()
        value = value.replacingOccurrences(
            of: #"\[[^\]]*(?:kb|mb|gb|tb|1080|2160|4k|8k)[^\]]*\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\.(?:mp4|mkv|m2ts|ts|avi|mov|flv|wmv|webm)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(of: "丨", with: "")
        return String(value.filter { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        })
    }

    private static func playbackMatches(
        in sources: [PlaySource],
        resourceIdentity: String
    ) -> [(source: PlaySource, episode: PlayEpisode)] {
        sources.flatMap { source in
            source.episodes.compactMap { episode in
                episode.stableIdentity == resourceIdentity
                    ? (source, episode)
                    : nil
            }
        }
    }

    static func historyPlaybackReference(
        source: PlaySource,
        episode: PlayEpisode,
        providerResourceReference: PlaybackResourceReference? = nil,
        navigationRecipe: HistoryNavigationRecipe? = nil,
        headers: HTTPHeaders
    ) -> HistoryPlaybackReference {
        let sourceIdentity = PlaybackPersistencePolicy
            .sanitizedPlaybackIdentity(source.stableIdentity)
            ?? PlaybackReferenceIdentity.source(
                explicitIdentity: source.stableIdentity,
                episodes: []
            )
        let resourceIdentity = PlaybackPersistencePolicy
            .sanitizedPlaybackIdentity(episode.stableIdentity)
            ?? PlaybackReferenceIdentity.episode(
                explicitIdentity: episode.stableIdentity,
                name: "",
                reference: ""
            )
        return HistoryPlaybackReference(
            sourceIdentity: sourceIdentity,
            resourceIdentity: resourceIdentity,
            providerResourceReference: persistentProviderResourceReference(
                providerResourceReference
            ),
            navigationRecipe: navigationRecipe,
            replayHeaders: safeHistoryReplayHeaders(headers)
        )
    }

    static func historyNavigationRecipe(
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        configurationID: UUID,
        position: TimeInterval,
        persistedDetailID: String? = nil
    ) -> HistoryNavigationRecipe {
        let sourceIndex = detail.playSources.firstIndex(where: {
            $0.id == source.id && $0.stableIdentity == source.stableIdentity
        }) ?? detail.playSources.firstIndex(where: { $0.id == source.id })
        let episodeIndex = source.episodes.firstIndex(where: {
            $0.id == episode.id
        }) ?? source.episodes.firstIndex(where: {
            $0.stableIdentity == episode.stableIdentity
        })
        let identity = PlaybackResourceAnalyzer.trustedEpisode(episode, categoryName: detail.summary.categoryName)
        return HistoryNavigationRecipe(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            detailID: persistedDetailID ?? detail.summary.videoID,
            source: HistoryNavigationSource(
                providerStableID: source.referenceIdentity.flatMap {
                    PlaybackPersistencePolicy.sanitizedPlaybackIdentity($0)
                },
                flag: source.name,
                name: source.name,
                index: sourceIndex
            ),
            episode: HistoryNavigationEpisode(
                providerStableID: episode.referenceIdentity.flatMap {
                    PlaybackPersistencePolicy.sanitizedPlaybackIdentity($0)
                },
                name: episode.name,
                normalizedFilename: historyNormalizedFilename(episode.name),
                seasonNumber: identity?.season,
                episodeNumber: identity?.episode,
                index: episodeIndex,
                metadata: episode.metadata,
                categoryName: detail.summary.categoryName
            ),
            resumePosition: position
        )
    }

    static func acceptedHistoryProviderReference(
        from record: HistoryRecord?,
        provider: any SiteProvider
    ) -> PlaybackResourceReference? {
        // Android/Dex locators are tied to a live Spider instance. History is
        // navigation-first for this capability even if a legacy record marked
        // the locator as provider-stable.
        guard provider.capability != .javaDexSpider else { return nil }
        return acceptedProviderResourceReference(
            record?.playbackReference?.providerResourceReference,
            provider: provider
        )
    }

    static func acceptedProviderResourceReference(
        _ reference: PlaybackResourceReference?,
        provider: any SiteProvider
    ) -> PlaybackResourceReference? {
        guard let reference,
              provider.acceptsPlaybackResourceReference(reference) else {
            return nil
        }
        return reference
    }

    static func historyRecord(
        _ record: HistoryRecord,
        matches source: PlaySource,
        episode: PlayEpisode
    ) -> Bool {
        if let recipe = record.playbackReference?.navigationRecipe {
            let sourceMatches = recipe.source.providerStableID.map {
                $0 == source.referenceIdentity || $0 == source.stableIdentity
            } ?? [recipe.source.flag, recipe.source.name].contains(where: {
                source.name.compare(
                    $0,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame
            })
            let episodeMatches = recipe.episode.providerStableID.map {
                $0 == episode.referenceIdentity || $0 == episode.stableIdentity
            } ?? (historyNormalizedFilename(episode.name)
                    == recipe.episode.normalizedFilename)
            if sourceMatches && episodeMatches {
                return true
            }
        }
        if let reference = record.playbackReference {
            return reference.sourceIdentity == source.stableIdentity
                && reference.resourceIdentity == episode.stableIdentity
        }
        return record.sourceName == source.name
            && record.episodeName == episode.name
    }

    /// A clicked history row is the authority for the initial seek. Refreshed
    /// provider detail may legitimately change its video/source/episode
    /// identity, so the load stage must not use those refreshed values to find
    /// the same row again.
    static func historyResumePosition(
        from record: HistoryRecord?
    ) -> TimeInterval? {
        guard let record,
              record.position.isFinite,
              record.duration.isFinite,
              (record.position > 0
                || (record.playbackReference?.navigationRecipe?.resumePosition
                    ?? 0) > 0) else {
            return nil
        }
        let position = record.position > 0
            ? record.position
            : record.playbackReference?.navigationRecipe?.resumePosition ?? 0
        guard position.isFinite,
              record.duration == 0 || position < record.duration - 20 else {
            return nil
        }
        return position
    }

    private static func safeHistoryReplayHeaders(
        _ headers: HTTPHeaders
    ) -> [String: String] {
        PlaybackPersistencePolicy.sanitizedReplayHeaders(headers).dictionary
    }

    static func historyPlaybackContext(
        record: HistoryRecord,
        siteName: String,
        episodeURL: String
    ) -> (detail: VideoDetail, source: PlaySource, episode: PlayEpisode) {
        let episode = PlayEpisode(
            name: record.episodeName?.nonEmpty
                ?? L10n.string("history.episode.fallback", fallback: "History Episode"),
            url: episodeURL,
            metadata: record.playbackReference?.navigationRecipe?.episode.metadata
        )
        let source = PlaySource(
            name: record.sourceName?.nonEmpty
                ?? L10n.string("history.source.fallback", fallback: "History Source"),
            episodes: [episode]
        )
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: record.siteKey,
                siteName: siteName,
                videoID: record.videoID,
                title: record.title,
                posterURL: record.posterURL,
                categoryName: record.playbackReference?.navigationRecipe?.episode.categoryName
            ),
            playSources: [source]
        )
        return (detail, source, episode)
    }

    static func replayableHistoryPlayback(
        record: HistoryRecord,
        siteName: String
    ) -> (
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        media: ResolvedMedia
    )? {
        guard let rawReference = PlaybackPersistencePolicy
            .sanitizedMediaReference(record.mediaReference),
              let url = URL(string: rawReference) else {
            return nil
        }
        let episodeReference = PlaybackPersistencePolicy
            .sanitizedOpaqueLocator(record.episodeReference)
        let context = historyPlaybackContext(
            record: record,
            siteName: siteName,
            episodeURL: episodeReference ?? rawReference
        )
        let media = ResolvedMedia(
            url: url,
            headers: PlaybackPersistencePolicy.sanitizedReplayHeaders(
                HTTPHeaders(record.playbackReference?.replayHeaders ?? [:])
            ),
            siteKey: record.siteKey,
            sourceName: context.source.name,
            episodeName: context.episode.name
        )
        return (context.detail, context.source, context.episode, media)
    }

    static func persistentHistoryMediaReference(
        _ mediaURL: URL,
        playbackResult: SitePlaybackResult?
    ) -> String? {
        // Provider media sessions and localhost proxy URLs are runtime
        // capabilities, not durable media. History retains the provider's
        // validated resource reference instead and asks that same provider to
        // refresh it on resume.
        guard playbackResult?.mediaSession == nil else {
            return nil
        }
        return PlaybackPersistencePolicy.sanitizedMediaReference(
            mediaURL.absoluteString
        )
    }

    private func persistentHistoryVideoID(
        detail: VideoDetail,
        providerResourceReference: PlaybackResourceReference?
    ) -> String {
        let rawValue = detail.summary.videoID
        let provider = providers[detail.summary.siteKey]
        if provider is NodeHTTPSpiderSiteProvider
            || providerResourceReference?.providerKind == "node-http-spider" {
            return NodePlaybackReplayReference.persistedOpaqueIdentity(
                rawValue,
                namespace: "catpaw-video-vod-id"
            )
        }
        return rawValue
    }

    /// Keeps only provider locators that are safe to serialize. Runtime
    /// capabilities and credential-bearing URLs remain in memory and are
    /// regenerated by the owning provider on the next playback.
    static func persistentHistoryEpisodeReference(
        _ rawValue: String,
        providerCapability: SiteCapability? = nil,
        isNodeProvider: Bool = false
    ) -> String? {
        guard providerCapability != .javaDexSpider,
              !isNodeProvider else { return nil }
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }

        if QuarkEpisodeReference.identity(from: trimmed) != nil {
            let durable = QuarkEpisodeReference.durableHistoryReference(
                trimmed
            )
            guard QuarkEpisodeReference.requiresShareTokenRefresh(durable) else {
                return nil
            }
            return PlaybackPersistencePolicy.sanitizedOpaqueLocator(durable)
        }
        return PlaybackPersistencePolicy.sanitizedOpaqueLocator(trimmed)
    }

    static func persistentProviderResourceReference(
        _ reference: PlaybackResourceReference?
    ) -> PlaybackResourceReference? {
        PlaybackPersistencePolicy.sanitizedProviderResourceReference(reference)
    }

    static func historySearchMatch(
        in items: [VideoSummary],
        record: HistoryRecord
    ) -> VideoSummary? {
        let matches = historySearchCandidates(in: items, record: record)
        return matches.count == 1 ? matches[0] : nil
    }

    static func historySearchCandidates(
        in items: [VideoSummary],
        record: HistoryRecord
    ) -> [VideoSummary] {
        guard let query = historySearchQuery(for: record.title) else {
            return []
        }
        let exactMatches = items.filter {
            historySearchQuery(for: $0.title)?.compare(
                query,
                options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
        if !exactMatches.isEmpty {
            return exactMatches
        }

        return items.filter {
            guard let candidate = historySearchQuery(for: $0.title) else {
                return false
            }
            return candidate.localizedCaseInsensitiveContains(query)
                || query.localizedCaseInsensitiveContains(candidate)
        }
    }

    static func historySearchQuery(for title: String) -> String? {
        guard let query = title.nonEmpty,
              query.unicodeScalars.contains(where: {
                  CharacterSet.alphanumerics.contains($0)
              }) else {
            return nil
        }
        let placeholder = query.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
        guard ![
            "unknown", "untitled", "null", "undefined", "n/a",
            "无标题", "未命名"
        ].contains(placeholder) else {
            return nil
        }
        var normalized = query
        let decorationPatterns = [
            #"[（(\[][\s]*(?:臻彩|4k|8k|蓝光|超清|高清|杜比|hdr|国语|中字|中文字幕)[\s]*[）)\]]"#,
            #"(?:[._\-\s]+)(?:臻彩|4k|8k|蓝光|超清|高清|杜比|hdr|国语中字|中文字幕|中字)(?=$|[._\-\s])"#
        ]
        for pattern in decorationPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        normalized = normalized
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.nonEmpty
    }

    private func loadActiveConfigurationContent() throws {
        configurationRefreshSessionID = UUID()
        configurationRefreshTask?.cancel()
        configurationRefreshTask = nil
        guard let record = activeConfigurationRecord else {
            lastAutomaticConfigurationRefreshAttemptAt = nil
            activeConfiguration = nil
            providers = [:]
            selectedSiteKey = nil
            discardHomeContentIfNeeded(for: nil)
            return
        }
        lastAutomaticConfigurationRefreshAttemptAt = record.updatedAt
        activeConfiguration = try Self.configurationContent(for: record)
        rebuildProviders()
        if !supportedSites.contains(where: { $0.key == selectedSiteKey }) {
            selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                from: supportedSites
            )
        }
    }

    static func configurationContent(
        for record: StoredConfiguration
    ) throws -> FongMiConfiguration {
        guard record.sourceKind == .xtream else {
            return try ConfigurationParser().parse(record.rawData)
        }
        let descriptor = try XtreamProviderConfiguration(data: record.rawData)
        guard descriptor.providerID == record.id else {
            throw XtreamProviderConfigurationError.invalidProviderID
        }
        return descriptor.providerConfiguration
    }

    private func xtreamCredentials(
        for record: StoredConfiguration?
    ) async throws -> XtreamCredentials? {
        guard let environment, let record, record.sourceKind == .xtream else {
            return nil
        }
        return try await environment.xtreamCredentialStore.credentials(
            for: record.id
        )
    }

    private func validateXtreamAccountIfNeeded(
        record: StoredConfiguration?,
        credentials: XtreamCredentials?
    ) async throws {
        guard let record, record.sourceKind == .xtream else { return }
        guard let environment, let credentials else {
            throw AppError.configuration(
                L10n.string(
                    "xtream.live.credentials-unavailable",
                    fallback: "This provider is unavailable. Check its account credentials in Settings."
                )
            )
        }
        let descriptor = try XtreamProviderConfiguration(data: record.rawData)
        _ = try await XtreamClient(
            endpoint: try XtreamEndpoint(
                serverURL: descriptor.serverBaseURL
            ),
            credentials: credentials,
            httpClient: environment.xtreamHTTPClient,
            userAgent: Self.xtreamUserAgent
        ).authenticate()
    }

    private func loadConfiguration(
        _ source: ConfigurationSource
    ) async throws -> LoadedConfiguration {
        guard let environment else {
            throw AppError.configuration(
                L10n.string("app.environment.uninitialized", fallback: "The application environment has not been initialized.")
            )
        }
        if case .remote(let url) = source,
           NodeBundleRuntimeService.supports(url) {
            do {
                let loaded = try await environment.nodeBundleRuntime
                    .loadConfiguration(
                        from: url,
                        configurationID: activeConfigurationRecord?.id
                    )
                activeNodeRuntimeEndpoint = loaded.baseURL
                nodeRuntimeUnavailableReason = ""
                return loaded
            } catch {
                activeNodeRuntimeEndpoint = nil
                nodeRuntimeUnavailableReason = L10n.string(
                    "node.runtime.failed.user-facing",
                    fallback: "Node Runtime is unavailable. Export diagnostics for details."
                )
                throw error
            }
        }
        return try await environment.configurationLoader.load(source)
    }

    private func loadConfigurationForImport(
        _ source: ConfigurationSource,
        configurationID: UUID
    ) async throws -> ImportedConfigurationPayload {
        guard let environment else {
            throw AppError.configuration(
                L10n.string("app.environment.uninitialized", fallback: "The application environment has not been initialized.")
            )
        }
        if case .remote(let url) = source,
           NodeBundleRuntimeService.supports(url) {
            let loaded = try await environment.nodeBundleRuntime
                .loadConfiguration(
                    from: url,
                    configurationID: configurationID
                )
            try Task.checkCancellation()
            return ImportedConfigurationPayload(
                loaded: loaded,
                nodeRuntimeEndpoint: loaded.baseURL
            )
        }
        let loaded = try await environment.configurationLoader.load(source)
        try Task.checkCancellation()
        return ImportedConfigurationPayload(
            loaded: loaded,
            nodeRuntimeEndpoint: nil
        )
    }

    private var activeNodeRuntimeSourceURL: URL? {
        guard let record = activeConfigurationRecord,
              record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let sourceURL = URL(string: sourceValue),
              NodeBundleRuntimeService.supports(sourceURL) else {
            return nil
        }
        return sourceURL
    }

    private var activeConfigurationUsesNodeRuntime: Bool {
        activeNodeRuntimeSourceURL != nil
    }

    private func startNodeRuntimeStatusMonitoring() {
        guard nodeRuntimeStatusTask == nil, let environment else { return }
        nodeRuntimeStatusTask = Task { @MainActor [weak self] in
            let updates = await environment.nodeBundleRuntime.statusUpdates()
            for await status in updates {
                guard !Task.isCancelled, let self else { return }
                self.applyNodeRuntimeStatus(status)
            }
        }
    }

    private func startManagedRuntimeStatusMonitoring() {
        guard managedRuntimeStatusTask == nil, let environment else { return }
        managedRuntimeStatusTask = Task { @MainActor [weak self] in
            let updates = await environment.androidRuntimeManager.states()
            for await status in updates {
                guard !Task.isCancelled, let self else { return }
                self.managedRuntimeInstallationState = status
                if case .available = status {
                    // `.available` is emitted only by an explicit settings
                    // action or by the first Dex request that is suspended in
                    // the installation coordinator.
                    self.isAndroidRuntimeInstallSheetPresented = true
                }
            }
        }
    }

    private func startNodeProfileRevisionMonitoring() {
        guard nodeProfileRevisionTask == nil, let environment else { return }
        nodeProfileRevisionTask = Task { @MainActor [weak self] in
            let updates = await environment.nodeBundleRuntime
                .profileRevisionUpdates()
            for await snapshot in updates {
                guard !Task.isCancelled, let self else { return }
                let previous = self.observedNodeProfileRevision
                self.observedNodeProfileRevision = snapshot
                guard let previous,
                      previous.storageKey == snapshot.storageKey,
                      previous.revision != snapshot.revision,
                      self.activeConfigurationUsesNodeRuntime,
                      !self.isSwitchingConfiguration,
                      self.configurationImportOperationID == nil else {
                    continue
                }
                self.nodeProfileStorageDidChange()
                _ = await self.refreshActiveConfigurationIfNeeded(
                    force: true,
                    reportErrors: false
                )
                guard var presentation = self.nodeWebPresentation,
                      presentation.sourceIdentity.configurationID
                        == self.activeConfigurationRecord?.id else {
                    continue
                }
                let isPlayback = self.pendingNodeOperation?.playbackRequestID != nil
                if NodeProfileRevisionVerificationPolicy.shouldVerifyAutomatically(
                    isPlayback: isPlayback,
                    requestID: presentation.requestID,
                    allowsAutomaticRetry: presentation.allowsAutomaticRetry,
                    hasAttemptedVerification:
                        presentation.hasAttemptedProfileRevisionVerification,
                    acceptsProfileRevisionCompletion:
                        presentation.completionMode == .profileRevision
                ) {
                    presentation.hasAttemptedProfileRevisionVerification = true
                    presentation.lifecycleState = .saved
                    presentation.status = L10n.string("node.authorization.saved-verifying-legacy", fallback: "Configuration saved. Running one-time authorization verification for the legacy Spider.")
                    self.nodeWebPresentation = presentation
                    await self.completeNodeConfigurationAndRetry(
                        automatically: true,
                        configurationAlreadyRefreshed: true
                    )
                } else {
                    presentation.lifecycleState = .saved
                    if isPlayback,
                       presentation.completionMode == .explicitSignal {
                        presentation.status = L10n.string("node.authorization.saved-waiting-signal", fallback: "Configuration saved. Waiting for an explicit authorization-complete signal from the current request.")
                    } else if isPlayback {
                        presentation.status = L10n.string("node.authorization.saved-manual-retry", fallback: "Configuration saved. Automatic verification already ran once; retry manually.")
                    } else {
                        presentation.status = L10n.string("node.authorization.saved-window-open", fallback: "Configuration saved. This window will remain open.")
                    }
                    self.nodeWebPresentation = presentation
                }
            }
        }
    }

    private func applyNodeRuntimeStatus(_ status: NodeRuntimeStatus) {
        if isSwitchingConfiguration {
            if case .running(let endpoint) = status {
                lastReadyNodeRuntimeEndpoint = endpoint
            }
            return
        }
        switch status {
        case .running(let endpoint):
            let previousEndpoint = lastReadyNodeRuntimeEndpoint
                ?? activeConfigurationRecord?.baseURL
            if previousEndpoint != endpoint { catPawSearchMemory.invalidate() }
            lastReadyNodeRuntimeEndpoint = endpoint
            activeNodeRuntimeEndpoint = endpoint
            rebindNodeConfigurationWebsite(to: endpoint)
            nodeRuntimeUnavailableReason = ""
            if activeConfigurationUsesNodeRuntime,
               activeConfiguration != nil,
               configurationImportOperationID == nil,
               previousEndpoint != endpoint {
                rebindCatPawHomeTransport(to: endpoint)
            }
        case .starting:
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = L10n.string("node.runtime.starting", fallback: "Node Runtime is starting")
        case .restarting(let attempt, let reason):
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = L10n.string(
                "node.runtime.restarting",
                fallback: "Node Runtime restart attempt %1$lld: %2$@",
                attempt,
                reason
            )
        case .failed:
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = L10n.string(
                "node.runtime.failed.user-facing",
                fallback: "Node Runtime is unavailable. Export diagnostics for details."
            )
        case .stopped:
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = L10n.string("node.runtime.stopped", fallback: "Node Runtime has stopped")
        }
    }

    private func rebindNodeConfigurationWebsite(to endpoint: URL) {
        guard var presentation = nodeWebPresentation,
              let location = presentation.runtimeWebsiteLocation,
              let updatedURL = location.resolved(against: endpoint),
              updatedURL != presentation.url else {
            return
        }
        presentation.url = updatedURL
        presentation.revision &+= 1
        if presentation.lifecycleState != .verifying {
            presentation.status = L10n.string("node.runtime.recovered-new-port", fallback: "CatPaw Runtime recovered. The configuration page is connected to the new port.")
        }
        nodeWebPresentation = presentation
    }

    private func rebindCatPawHomeTransport(to endpoint: URL) {
        guard activeConfigurationUsesNodeRuntime,
              let configurationID = activeConfigurationRecord?.id else {
            return
        }
        categoryTabSessionStore.rebindRuntimeContent(
            configurationID: configurationID,
            to: endpoint
        )
        if let page = categoryPage {
            categoryPage = NodeRuntimeContentTransport.rebind(
                page,
                to: endpoint
            )
        }
        if let activeCategoryQueryKey,
           let state = categoryTabSessionStore.state(
            for: activeCategoryQueryKey
           ),
           let page = state.page {
            categoryPage = page
        }
        guard let identity = currentHomeContentIdentity,
              identity.configurationID == configurationID,
              homeContentIdentity == identity,
              let home = siteHome else {
            return
        }
        let rebound = NodeRuntimeContentTransport.rebind(home, to: endpoint)
        guard rebound != home else { return }
        // A port rebind changes only transport-bearing poster URLs. Preserve
        // the current presentation and action sheet instead of publishing a
        // semantically new home model.
        siteHome = rebound
        Task { @MainActor [weak self] in
            guard let self,
                  self.currentHomeContentIdentity == identity,
                  self.homeContentIdentity == identity,
                  self.siteHome == rebound else {
                return
            }
            await self.cacheSiteHome(rebound, identity: identity)
        }
    }

    private func catPawHomeLoadKey(
        siteKey: String
    ) -> CatPawHomeLoadKey? {
        guard activeConfigurationUsesNodeRuntime,
              let record = activeConfigurationRecord,
              let semanticRevision = NodeConfigurationSemanticRevision.make(
                record: record
              ) else {
            return nil
        }
        return CatPawHomeLoadKey(
            configurationID: record.id,
            semanticRevision: semanticRevision,
            siteKey: siteKey
        )
    }

    private func invalidateCatPawHomeLoads() {
        homeLoadSessionID = UUID()
        cancelAndroidHomeLoad()
        for entry in catPawHomeRequestTasks.values {
            entry.task.cancel()
        }
        catPawHomeRequestTasks.removeAll()
        catPawHomeLoadCoordinator.removeAll()
    }

    private func cancelAndroidHomeLoad() {
        androidHomeLoadTask?.cancel()
        androidHomeLoadTask = nil
        androidHomeLoadTaskID = nil
    }

    private func selectedSiteSettingKey(for configurationID: UUID) -> String {
        "home.selectedSite.\(configurationID.uuidString.lowercased())"
    }

    static func searchScopeSettingKey(for configurationID: UUID) -> String {
        "search.scope.\(configurationID.uuidString.lowercased())"
    }

    private func loadSearchSiteScope() async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id else {
            searchSiteScope = .all
            return
        }
        let settingKey = Self.searchScopeSettingKey(for: configurationID)
        let value: JSONValue?
        do {
            value = try await environment.database.setting(forKey: settingKey)
        } catch {
            guard activeConfigurationRecord?.id == configurationID else { return }
            searchSiteScope = SearchSiteScope(mode: .custom)
            show(error, title: L10n.string("search.scope.read.failed", fallback: "Unable to Read Search Scope"))
            return
        }
        guard activeConfigurationRecord?.id == configurationID else { return }
        let fingerprint = SearchConfigurationFingerprint.make(
            sites: activeConfiguration?.sites ?? []
        )
        guard let value else {
            searchSiteScope = .all
            return
        }
        guard let decoded = SearchSiteScope(
            setting: value,
            expectedConfigurationFingerprint: fingerprint
        ) else {
            searchSiteScope = SearchSiteScope(mode: .custom)
            show(
                AppError.database(L10n.string("search.scope.invalid", fallback: "The saved search scope is invalid. Select sites again.")),
                title: L10n.string("search.scope.expand.failed", fallback: "Search Scope Was Not Expanded")
            )
            return
        }
        searchSiteScope = decoded
        let normalized = decoded.settingValue(
            configurationFingerprint: fingerprint
        )
        if normalized != value {
            try? await environment.database.setSetting(
                normalized,
                forKey: settingKey
            )
        }
    }

    private func resetSearchForConfigurationChange() {
        detailHomeSearchReturnSnapshot = nil
        discoverySearchReturnSnapshot = nil
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = nil
        if let challengeID = nodeWebPresentation?.challengeID {
            Task {
                await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
            }
        }
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        cancelSearch()
        searchDraftKeyword = ""
        activeSearchKeyword = ""
        isHomeSearchPresented = false
        searchResults = []
        searchFailures = []
        searchSiteOutcomes = [:]
        searchFirstPageCompletedSiteCount = 0
        searchCompletedSiteCount = 0
        searchTotalSiteCount = 0
        activeSearchSiteKeys = []
        selectedSearchSiteKey = nil
        searchFolderPath = []
        searchFolderOrigin = nil
        searchSiteScope = .all
    }

    private func homeCacheSettingKey(
        configurationID: UUID,
        siteKey: String
    ) -> String {
        let encodedSiteKey = Data(siteKey.utf8).base64EncodedString()
        return "home.cache.\(configurationID.uuidString.lowercased()).\(encodedSiteKey)"
    }

    private func restoreSelectedSitePreference() async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id,
              let value = try? await environment.database.setting(
                forKey: selectedSiteSettingKey(for: configurationID)
              ),
              case .string(let preferredKey) = value,
              supportedSites.contains(where: { $0.key == preferredKey }),
              let cached = await cachedSiteHome(
                configurationID: configurationID,
                siteKey: preferredKey
              ),
              HomeSiteRolePolicy.isContentHome(cached),
              activeConfigurationRecord?.id == configurationID else {
            return
        }
        selectedSiteKey = preferredKey
    }

    @discardableResult
    private func prepareActiveConfigurationHome(
        reportLoadErrors: Bool = true,
        loadBehavior: HomePreparationLoadBehavior = .background,
        entryReason: HomeEntryReason = .manualReload
    ) async -> Bool {
        homeResumeTask?.cancel()
        homeResumeTask = nil
        isRecoveringHome = false
        invalidateCatPawHomeLoads()
        categoryLoadSessionID = UUID()
        activeCategoryQueryKey = nil
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = .empty
        categoryPaginationError = nil
        homeLoadErrorMessage = nil
        if entryReason.restoresPersistedSite {
            await restoreSelectedSitePreference()
        }
        discardHomeContentIfNeeded(for: currentHomeContentIdentity)
        await restoreCachedSiteHome(loadsCategoryContent: false)
        guard loadBehavior != .none else {
            isHomeLoading = false
            return true
        }
        guard let key = selectedSiteKey,
              siteCapability(for: key) != .unsupportedSpider else {
            isHomeLoading = false
            return true
        }
        switch loadBehavior {
        case .none:
            return true
        case .background:
            isHomeLoading = true
            Task { [weak self] in
                await self?.loadSelectedSiteHome(
                    reportErrors: reportLoadErrors
                )
            }
            return true
        case .awaited:
            return await loadSelectedSiteHome(
                reportErrors: reportLoadErrors
            )
        }
    }

    private func persistSelectedSitePreference(_ siteKey: String) async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id else { return }
        try? await environment.database.setSetting(
            .string(siteKey),
            forKey: selectedSiteSettingKey(for: configurationID)
        )
    }

    private func restoreCachedSiteHome(
        loadsCategoryContent: Bool = false
    ) async {
        guard let configurationID = activeConfigurationRecord?.id,
              let siteKey = selectedSiteKey,
              let contentIdentity = currentHomeContentIdentity,
              let cached = await cachedSiteHome(
                configurationID: configurationID,
                siteKey: siteKey
              ),
              currentHomeContentIdentity == contentIdentity else {
            return
        }
        let restored = (providers[siteKey] as? AndroidDexSpiderSiteProvider)?
            .restoringHomeContract(in: cached) ?? cached
        publishHomeContent(restored, identity: contentIdentity)
        _ = await applyHomePresentation(
            restored,
            identity: contentIdentity,
            loadsCategoryContent: loadsCategoryContent
        )
    }

    private func cachedSiteHome(
        configurationID: UUID,
        siteKey: String
    ) async -> SiteHome? {
        guard let environment,
              let value = try? await environment.database.setting(
                forKey: homeCacheSettingKey(
                    configurationID: configurationID,
                    siteKey: siteKey
                )
              ),
              case .string(let encoded) = value,
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(SiteHome.self, from: data)
    }

    private var currentHomeContentIdentity: HomeContentIdentity? {
        guard let configurationID = activeConfigurationRecord?.id,
              let siteKey = selectedSiteKey else {
            return nil
        }
        return HomeContentIdentity(
            configurationID: configurationID,
            siteKey: siteKey
        )
    }

    private func categoryTabNamespace(
        for siteKey: String
    ) -> CategoryTabNamespace? {
        guard let record = activeConfigurationRecord else { return nil }
        let revision = CategoryConfigurationRevision.make(record: record)
        synchronizeCategoryConfigurationRevision(
            configurationID: record.id,
            revision: revision
        )
        return CategoryTabNamespace(
            configurationID: record.id,
            configurationRevision: revision,
            siteKey: siteKey
        )
    }

    private func synchronizeCategoryConfigurationRevision(
        configurationID: UUID,
        revision: String
    ) {
        let previousRevision = knownCategoryConfigurationRevisions[
            configurationID
        ]
        if previousRevision != revision {
            let obsoleteRequestKeys = categoryRequestTasks.keys.filter {
                $0.queryKey.namespace.configurationID == configurationID
                    && $0.queryKey.namespace.configurationRevision != revision
            }
            for requestKey in obsoleteRequestKeys {
                categoryRequestTasks[requestKey]?.task.cancel()
                categoryRequestTasks[requestKey] = nil
            }
            categoryTabSessionStore.invalidateRevisions(
                configurationID: configurationID,
                keeping: revision
            )
            knownCategoryConfigurationRevisions[configurationID] = revision
        }

        if let activeKey = activeCategoryQueryKey,
           activeKey.namespace.configurationID != configurationID
            || activeKey.namespace.configurationRevision != revision {
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            isLoading = false
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
        }
    }

    private func cancelCategoryRequestTasks(for key: CategoryQueryKey) {
        let requestKeys = categoryRequestTasks.keys.filter {
            $0.queryKey == key
        }
        for requestKey in requestKeys {
            categoryRequestTasks[requestKey]?.task.cancel()
            categoryRequestTasks[requestKey] = nil
        }
        categoryTabSessionStore.invalidateRequests(for: key)
    }

    private func cancelAllCategoryRequestTasks() {
        cancelScheduledCategoryFilterLoad()
        for entry in categoryRequestTasks.values {
            entry.task.cancel()
        }
        categoryRequestTasks.removeAll()
    }

    private func shouldPublishCategoryQuery(
        _ key: CategoryQueryKey
    ) -> Bool {
        guard selectedSiteKey == key.namespace.siteKey,
              currentHomeContentIdentity == HomeContentIdentity(
                configurationID: key.namespace.configurationID,
                siteKey: key.namespace.siteKey
              ),
              siteHome?.categories.contains(where: {
                $0.id == key.categoryID
                    && $0.resolvedContentKind == .media
              }) == true else {
            return false
        }
        return CategoryTabPublicationPolicy.shouldPublish(
            requestKey: key,
            activeKey: activeCategoryQueryKey,
            currentNamespace: categoryTabNamespace(
                for: key.namespace.siteKey
            )
        )
    }

    private func applyCategoryQueryState(
        _ state: CategoryQueryState,
        preserveCurrentPage: Bool
    ) {
        activeCategoryQueryKey = state.key
        var publication = homeCategoryPublication
        publication.selectedCategoryID = state.key.categoryID
        publication.selectedCategoryFilters = state.key.filters
        if !preserveCurrentPage || state.page != nil {
            publication.categoryPage = state.page
        }
        publication.homePresentationSelection = .category(state.key.categoryID)
        publication.isLoadingNextCategoryPage = state.isLoadingNextPage
        publication.categoryPaginationError = state.paginationError
        publication.paginationIssueKind = state.paginationIssueKind
        publication.homeLoadErrorMessage = state.refreshError
        publication.presentationRevision = state.presentationRevision
        publication.hasPendingRefresh = state.pendingRefreshPage != nil
        if homeCategoryPublication != publication {
            homeCategoryPublication = publication
        }
        let loading = state.isInitialLoading || state.isRefreshing
        if isLoading != loading { isLoading = loading }
        trimCategoryQueries()
    }

    private func captureHomeBrowsingSnapshotIfValid() {
        guard let identity = currentHomeContentIdentity,
              homeContentIdentity == identity,
              let home = siteHome,
              HomeResumePolicy.isStructurallyValid(
                home: home,
                selection: homePresentationSelection,
                selectedCategoryID: selectedCategoryID
              ) else {
            return
        }
        if case .category = homePresentationSelection,
           (activeCategoryQueryKey == nil
            || activeCategoryQueryKey.flatMap {
                categoryTabSessionStore.state(for: $0)?.page
            } != categoryPage) {
            // A category request in flight, or a staged filter that is still
            // showing the prior query, is not a stable restore point. Keep the
            // last complete QueryState for this configuration/site identity.
            return
        }
        homeBrowsingSnapshots[identity] = HomeBrowsingSnapshot(
            presentation: homePresentationSelection,
            categoryID: selectedCategoryID,
            categoryQueryKey: activeCategoryQueryKey
        )
    }

    private func restoreHomeBrowsingSnapshotIfPossible() {
        guard let identity = currentHomeContentIdentity,
              homeContentIdentity == identity,
              let home = siteHome,
              let snapshot = homeBrowsingSnapshots[identity] else {
            return
        }
        let currentIsValid = HomeResumePolicy.isStructurallyValid(
            home: home,
            selection: homePresentationSelection,
            selectedCategoryID: selectedCategoryID
        )
        let restoresMissingCategoryPage: Bool
        if case .category(let id) = homePresentationSelection {
            restoresMissingCategoryPage = selectedCategoryID == id
                && categoryPage == nil
                && snapshot.categoryID == id
                && snapshot.categoryQueryKey.flatMap {
                    categoryTabSessionStore.state(for: $0)?.page
                } != nil
        } else {
            restoresMissingCategoryPage = false
        }
        guard !currentIsValid || restoresMissingCategoryPage else { return }

        switch snapshot.presentation {
        case .recommendation where !home.recommendations.isEmpty:
            activeCategoryQueryKey = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .recommendation
            homeLoadErrorMessage = nil
        case .category(let id) where home.categories.contains(where: {
            $0.id == id && $0.resolvedContentKind == .media
        }):
            if let queryKey = snapshot.categoryQueryKey,
               queryKey.categoryID == id,
               queryKey.namespace == categoryTabNamespace(
                   for: identity.siteKey
               ),
               let state = categoryTabSessionStore.state(for: queryKey),
               state.hasValidContent {
                applyCategoryQueryState(state, preserveCurrentPage: false)
            }
        case .actions where !home.actionItems.isEmpty
            || HomePresentationPolicy.firstActionCategory(in: home) != nil:
            activeCategoryQueryKey = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .actions
            homeLoadErrorMessage = nil
        default:
            break
        }
    }

    private func scheduleHomeResume() {
        homeResumeTask?.cancel()
        homeResumeTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.resumeHomeIfNeeded()
        }
    }

    private func discardHomeContentIfNeeded(
        for targetIdentity: HomeContentIdentity?
    ) {
        guard HomeContentPublicationPolicy.shouldDiscard(
            currentIdentity: homeContentIdentity,
            targetIdentity: targetIdentity
        ) else { return }
        if siteHome != nil {
            siteHome = nil
        }
        if configurationCategoryPresentation != nil {
            closeConfigurationCategory()
        }
        homeContentIdentity = nil
    }

    private func publishHomeContent(
        _ home: SiteHome,
        identity: HomeContentIdentity
    ) {
        let siteName = providers[identity.siteKey]?.site.name
            ?? visibleSites.first(where: { $0.key == identity.siteKey })?.name
            ?? identity.siteKey
        let publishedHome = HomePresentationPolicy.addingActionCategoryFallback(
            to: home,
            siteKey: identity.siteKey,
            siteName: siteName
        )
        guard HomeContentPublicationPolicy.shouldPublish(
            currentHome: siteHome,
            currentIdentity: homeContentIdentity,
            incomingHome: publishedHome,
            incomingIdentity: identity
        ) else { return }
        if let presentation = configurationCategoryPresentation,
           presentation.sourceIdentity != identity || siteHome != publishedHome {
            // A refreshed home may replace request-scoped action identifiers.
            // Close the old list rather than allowing stale actions to cross
            // a login, provider reload, or configuration generation change.
            closeConfigurationCategory()
        }
        homeContentIdentity = identity
        siteHome = publishedHome
    }

    private func applyHomePresentation(
        _ home: SiteHome,
        identity: HomeContentIdentity,
        loadsCategoryContent: Bool = true,
        reportCategoryErrors: Bool = true,
        forceCategoryRefresh: Bool = false
    ) async -> Bool {
        guard currentHomeContentIdentity == identity,
              homeContentIdentity == identity else {
            return false
        }
        var preservedCategoryID = selectedCategoryID
        if preservedCategoryID == nil,
           homePresentationSelection == .empty,
           let snapshot = homeBrowsingSnapshots[identity],
           let queryKey = snapshot.categoryQueryKey,
           queryKey.namespace == categoryTabNamespace(for: identity.siteKey) {
            preservedCategoryID = snapshot.categoryID
        }
        let selection = HomePresentationPolicy.selection(
            for: home,
            preserving: preservedCategoryID
        )
        homePresentationSelection = selection
        switch selection {
        case .recommendation:
            clearCategory()
            return true
        case .category(let id):
            guard let category = home.categories.first(where: {
                $0.id == id && $0.resolvedContentKind == .media
            }) else { return false }
            let requestedFilters = selectedCategoryID == id
                ? selectedCategoryFilters
                : nil
            if loadsCategoryContent {
                return await loadCategory(
                    id: id,
                    filters: requestedFilters,
                    reportErrors: reportCategoryErrors,
                    forceRefresh: forceCategoryRefresh
                )
            } else {
                guard let namespace = categoryTabNamespace(
                    for: identity.siteKey
                ) else { return false }
                categoryLoadSessionID = UUID()
                let queryKey = categoryTabSessionStore.queryKey(
                    namespace: namespace,
                    category: category,
                    requestedFilters: requestedFilters
                )
                activeCategoryQueryKey = queryKey
                if let state = categoryTabSessionStore.state(for: queryKey),
                   state.hasValidContent {
                    applyCategoryQueryState(
                        state,
                        preserveCurrentPage: false
                    )
                } else {
                    isLoadingNextCategoryPage = false
                    categoryPaginationError = nil
                    selectedCategoryID = id
                    selectedCategoryFilters = queryKey.filters
                    categoryPage = nil
                }
                return true
            }
        case .actions:
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            guard home.actionItems.isEmpty,
                  let actionCategory = HomePresentationPolicy.firstActionCategory(
                    in: home
                  ) else {
                return true
            }
            guard loadsCategoryContent else { return true }
            return await loadActionCategory(
                id: actionCategory.id,
                filters: HomePresentationPolicy.defaultFilters(
                    for: actionCategory
                ),
                reportErrors: reportCategoryErrors
            )
        case .empty:
            categoryLoadSessionID = UUID()
            activeCategoryQueryKey = nil
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            return true
        }
    }

    private func cacheSiteHome(
        _ home: SiteHome,
        identity: HomeContentIdentity
    ) async {
        guard let environment,
              let data = try? JSONEncoder().encode(home) else { return }
        try? await environment.database.setSetting(
            .string(data.base64EncodedString()),
            forKey: homeCacheSettingKey(
                configurationID: identity.configurationID,
                siteKey: identity.siteKey
            )
        )
    }

    private func rebuildProviders(preservingDetailRoute: Bool = false) {
        preservesDetailRouteOnProviderReplacement = preservingDetailRoute
        defer { preservesDetailRouteOnProviderReplacement = false }
        invalidateXtreamLiveCatalog()
        guard let environment else {
            providers = [:]
            return
        }
        if let record = activeConfigurationRecord {
            synchronizeCategoryConfigurationRevision(
                configurationID: record.id,
                revision: CategoryConfigurationRevision.make(record: record)
            )
        }
        let usesNodeRuntime = activeConfigurationUsesNodeRuntime
        let nodeSourceURL = activeNodeRuntimeSourceURL
        let baseURL = usesNodeRuntime
            ? activeNodeRuntimeEndpoint
            : activeConfigurationRecord?.baseURL
        let nodeFallbackBaseURL = activeNodeRuntimeEndpoint
            ?? activeConfigurationRecord?.baseURL
            ?? URL(string: "http://127.0.0.1/")!
        let httpClient = configuredHTTPClient(environment: environment)
        let aggregateSearchHTTPClient = configuredAggregateSearchHTTPClient(
            environment: environment
        )
        let nodeBundleRuntime = environment.nodeBundleRuntime
        let activeConfigurationID = activeConfigurationRecord?.id
        let activeXtreamConfiguration: XtreamProviderConfiguration? = {
            guard let record = activeConfigurationRecord,
                  record.sourceKind == .xtream else { return nil }
            return try? XtreamProviderConfiguration(data: record.rawData)
        }()
        let activeConfigurationSemanticRevision = activeConfigurationRecord
            .flatMap(NodeConfigurationSemanticRevision.make)
        providers = Dictionary(
            uniqueKeysWithValues: providerCatalogSites.map { site in
                let provider: SiteProvider
                let nodeOwned = SiteProviderRoutingPolicy
                    .hasExclusiveNodeRuntimeOwnership(site)
                let localScriptURL = javaScriptURL(
                    for: site,
                    baseURL: baseURL
                )
                if site.type == XtreamProviderConfiguration.nativeSiteType,
                   site.api == XtreamProviderConfiguration.nativeAPIIdentifier,
                   let activeXtreamConfiguration,
                   activeXtreamConfiguration.siteKey == site.key,
                   let activeXtreamCredentials {
                    provider = (try? XtreamSiteProvider(
                        configuration: activeXtreamConfiguration,
                        credentials: activeXtreamCredentials,
                        httpClient: environment.xtreamHTTPClient,
                        userAgent: Self.xtreamUserAgent,
                        movieSourceName: L10n.string(
                            "xtream.source.movie",
                            fallback: "Movie"
                        ),
                        episodesSourceName: L10n.string(
                            "xtream.source.episodes",
                            fallback: "Episodes"
                        ),
                        seasonSourceName: { season in
                            L10n.string(
                                "xtream.source.season",
                                fallback: "Season %lld",
                                season
                            )
                        },
                        episodeName: { episode in
                            L10n.string(
                                "xtream.episode.fallback",
                                fallback: "Episode %lld",
                                episode
                            )
                        }
                    )) ?? UnsupportedSiteProvider(site: site)
                } else if nodeOwned {
                    if usesNodeRuntime,
                       let nodeSourceURL,
                       NodeHTTPSpiderSiteProvider.canHandle(
                           site: site,
                           baseURL: nodeFallbackBaseURL
                       ) {
                        provider = (try? NodeHTTPSpiderSiteProvider(
                            site: site,
                            baseURL: nodeFallbackBaseURL,
                            httpClient: httpClient,
                            aggregateSearchHTTPClient: aggregateSearchHTTPClient,
                            searchMemory: catPawSearchMemory,
                            diagnosticReporter: {
                                [weak runtime = nodeBundleRuntime] event in
                                Task { await runtime?.recordDiagnosticEvent(event) }
                            },
                            ensureRuntimeReady: {
                                try await nodeBundleRuntime.ensureReady(
                                    from: nodeSourceURL,
                                    configurationID: activeConfigurationID
                                )
                            },
                            configurationIdentity: activeConfigurationID?
                                .uuidString,
                            configurationSemanticRevision:
                                activeConfigurationSemanticRevision
                        )) ?? UnsupportedSiteProvider(site: site)
                    } else if let baseURL,
                              NodeHTTPSpiderSiteProvider.canHandle(
                                  site: site,
                                  baseURL: baseURL
                              ) {
                        provider = (try? NodeHTTPSpiderSiteProvider(
                            site: site,
                            baseURL: baseURL,
                            httpClient: httpClient,
                            aggregateSearchHTTPClient: aggregateSearchHTTPClient,
                            searchMemory: catPawSearchMemory,
                            diagnosticReporter: {
                                [weak runtime = nodeBundleRuntime] event in
                                Task { await runtime?.recordDiagnosticEvent(event) }
                            },
                            configurationIdentity: activeConfigurationID?
                                .uuidString,
                            configurationSemanticRevision:
                                activeConfigurationSemanticRevision
                        )) ?? UnsupportedSiteProvider(site: site)
                    } else {
                        // `okNodeRuntime` is exclusive ownership metadata. A
                        // broken/missing Node runtime must not start Android.
                        provider = UnsupportedSiteProvider(site: site)
                    }
                } else if [0, 1, 4].contains(site.type) {
                    provider = (try? StandardSiteProvider(
                        site: site,
                        httpClient: httpClient,
                        configurationBaseURL: baseURL
                    )) ?? UnsupportedSiteProvider(site: site)
                } else if site.type == 3, let localScriptURL {
                    if let factory = environment.spiderRuntimeFactory {
                        provider = (try? JavaScriptSpiderSiteProvider(
                            site: site,
                            scriptURL: localScriptURL,
                            baseURL: baseURL,
                            httpClient: httpClient,
                            runtimeFactory: factory
                        )) ?? UnsupportedSiteProvider(site: site)
                    } else {
                        // Local JavaScript ownership remains local even when
                        // QuickJS is unavailable; never reinterpret it as JAR.
                        provider = UnsupportedSiteProvider(site: site)
                    }
                } else if site.type == 3,
                          site.api.hasPrefix("csp_"),
                          let activeConfigurationID,
                          let jarReference = javaDexJarReference(
                              for: site,
                              baseURL: baseURL
                          ) {
                    provider = (try? AndroidDexSpiderSiteProvider(
                        site: site,
                        configurationID: activeConfigurationID,
                        configurationHosts: activeConfiguration?.hosts ?? [],
                        jarReference: jarReference,
                        baseURL: baseURL,
                        bridge: environment.androidDexBridge,
                        authorizationSites: supportedSites.filter {
                            $0.type == 3 && ["csp_PanConfig", "csp_PanConfigGuard"].contains($0.api)
                                && javaDexJarReference(for: $0, baseURL: baseURL) == jarReference
                        }
                    )) ?? UnsupportedSiteProvider(site: site)
                } else {
                    provider = UnsupportedSiteProvider(site: site)
                }
                return (site.key, provider)
            }
        )
    }

    private func configuredHTTPClient(environment: AppEnvironment) -> HTTPClient {
        ConfigurationPolicyHTTPClient(
            base: environment.httpClient,
            rules: activeConfiguration?.headers ?? []
        )
    }

    static var xtreamUserAgent: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let normalizedVersion = version?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedVersion, !normalizedVersion.isEmpty {
            return "OKVideoMac/\(normalizedVersion)"
        }
        return "OKVideoMac"
    }

    private func configuredAggregateSearchHTTPClient(
        environment: AppEnvironment
    ) -> HTTPClient {
        ConfigurationPolicyHTTPClient(
            base: environment.aggregateSearchHTTPClient,
            rules: activeConfiguration?.headers ?? []
        )
    }

    private func javaScriptURL(
        for site: SiteConfiguration,
        baseURL: URL?
    ) -> URL? {
        SiteProviderRoutingPolicy.localJavaScriptURL(
            site: site,
            configurationSpider: activeConfiguration?.spider,
            baseURL: baseURL
        )
    }

    private func javaDexJarReference(
        for site: SiteConfiguration,
        baseURL: URL?
    ) -> String? {
        SiteProviderRoutingPolicy.javaDexJarReference(
            site: site,
            configurationSpider: activeConfiguration?.spider,
            baseURL: baseURL
        )
    }

    private func reloadUserData() async throws {
        guard let environment else { return }
        await refreshFavoritesPresentation()
        let expirationDate = Calendar.current.date(
            byAdding: .day,
            value: -historyRetentionDays,
            to: Date()
        ) ?? Date.distantPast
        _ = try await environment.database.deleteHistory(
            olderThan: expirationDate
        )
        try await reloadHistory()
    }

    static func historyRecords(
        _ records: [HistoryRecord],
        for configurationID: UUID?
    ) -> [HistoryRecord] {
        guard let configurationID else { return [] }
        // A point-on-demand configuration is the user's history source.
        // Site keys remain part of each record's durable identity and replay
        // target, but switching the selected homepage site must never hide
        // history produced by sibling sites in the same configuration.
        return records.filter { $0.configurationID == configurationID }
    }

    private func reloadHistory() async throws {
        guard let environment else { return }
        let configurationID = activeConfigurationRecord?.id
        let revision = historyRevision
        let records = try await environment.database.history()
        guard configurationID == activeConfigurationRecord?.id, revision == historyRevision else { return }
        // Preserve the current live checkpoint when the periodic disk write is
        // deliberately behind it. Deleted rows are protected by the revision.
        var latest = Self.historyRecords(records, for: configurationID)
        for item in history where item.configurationID == configurationID {
            if let index = latest.firstIndex(where: { $0.id == item.id }),
               latest[index].watchedAt < item.watchedAt { latest[index] = item }
        }
        history = latest
    }

    /// Browser-level demand only. No visibility observers or card networking.
    func setEPGBrowserDemand(source: LiveSourceID?, channels: [LiveChannel]) {
        let bounded = Array(channels.prefix(100))
        guard epgBrowserSource != source || epgBrowserChannels != bounded else { return }
        epgBrowserSource = source
        epgBrowserChannels = bounded
        scheduleEPGRefresh()
    }

    /// Full Guide demand is independent from the Now/Next browser demand. It
    /// cancels only the bounded window query; the shared XMLTV resource refresh
    /// continues for every consumer.
    /// An appearance owns one lease. A late disappearance can release only
    /// that lease, never another page's query. Navigation itself can clear all.
    @discardableResult
    func acquireLiveGuideDemand(owner: UUID, navigation selection: NavigationSelection) -> Bool {
        guard selection == navigation.selection, selection.section == .live,
              !isShutdownRequested else { return false }
        if liveGuideOwner != owner {
            clearLiveGuideDemand()
            liveGuideOwner = owner
            BrowserInteractionTrace.record("guide.acquire", revision: selection.revision, request: owner)
        }
        return true
    }

    func setLiveGuideDemand(owner: UUID, source: LiveSourceID?, channels: [LiveChannel],
                            windowStart: Date, windowEnd: Date,
                            visibleRange: Range<Int>,
                            focusedChannelID: String? = nil, force: Bool = false) {
        guard liveGuideOwner == owner else { return }
        guard let source, environment != nil, !isShutdownRequested, !epgSleeping else {
            clearLiveGuideDemand(owner: owner)
            return
        }
        let bounded = Array(channels.prefix(EPGGuideLimits.maximumDesiredRows))
        guard !bounded.isEmpty, windowStart < windowEnd,
              windowEnd.timeIntervalSince(windowStart) <= 24 * 60 * 60 else {
            clearLiveGuideDemand(owner: owner)
            return
        }
        let lower = min(max(0, visibleRange.lowerBound), bounded.count - 1)
        let upper = min(bounded.count, max(lower + 1, visibleRange.upperBound))
        let input = LiveGuideDemandInput(
            source: source,
            channels: bounded,
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleRange: lower..<upper,
            focusedChannelID: focusedChannelID
        )
        if !force, input == liveGuideInput,
           liveGuideTask != nil || liveGuideWaitingForResource != nil || liveGuide.snapshot != nil { return }
        liveGuideInput = input
        liveGuideDebounce.register(at: DispatchTime.now().uptimeNanoseconds)
        startLiveGuideDemand(input)
    }

    func clearLiveGuideDemand(owner: UUID? = nil) {
        if let owner, liveGuideOwner != owner { return }
        BrowserInteractionTrace.record("guide.release", request: liveGuideOwner)
        liveGuideOwner = nil
        liveGuideWaitingForResource = nil
        liveGuideTask?.cancel()
        liveGuideTask = nil
        liveGuideInput = nil
        liveGuideRequest = nil
        liveGuideDebounce.reset()
        liveGuide.deactivate()
    }

    private func startLiveGuideDemand(_ input: LiveGuideDemandInput) {
        liveGuideTask?.cancel()
        liveGuideWaitingForResource = nil
        guard let environment, !isShutdownRequested, !epgSleeping else {
            liveGuide.suspend()
            return
        }
        guard let revision = epgRevision(for: input.source) else {
            liveGuideRequest = nil
            liveGuideDebounce.reset()
            liveGuide.setUnsupported()
            return
        }
        let capability: EPGGuideCapability
        switch input.source {
        case .imported: capability = .xmltv
        case .xtream: capability = .xtreamShort
        }
        let identity = LiveGuideDeliveryIdentity(
            source: EPGSourceKey(input.source),
            revision: revision,
            demandRevision: UUID(),
            serviceIncarnation: environment.productionEPGRepository.incarnation,
            capability: capability
        )
        let request = LiveGuideRequestSpec(input: input, identity: identity)
        liveGuideRequest = request
        liveGuide.begin(identity, refreshing: true)
        BrowserInteractionTrace.record("guide.query", request: identity.demandRevision)
        let retainedCost = liveGuide.retainedSnapshotCost

        liveGuideTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.liveGuideRequest == request {
                    self.liveGuideTask = nil
                    // No live waiter may be represented as perpetual loading.
                    if self.liveGuideWaitingForResource == nil,
                       case .loadingInitial = self.liveGuide.lifecycle {
                        self.liveGuide.fail(.unavailable, identity: identity)
                    }
                }
            }
            do {
                let now = DispatchTime.now().uptimeNanoseconds
                let delay = self.liveGuideDebounce.delay(at: now)
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, self.liveGuideRequest == request,
                      self.epgRevision(for: input.source) == revision else { return }
                self.liveGuideDebounce.reset()
                let slices = try Self.liveGuideSlices(
                    from: input.windowStart,
                    to: input.windowEnd
                )
                let demand = try EPGGuideDemand(
                    source: identity.source,
                    revision: revision,
                    demandRevision: identity.demandRevision,
                    capability: capability,
                    channels: input.channels,
                    visibleRange: input.visibleRange,
                    focusedChannelID: input.focusedChannelID,
                    playingChannelID: self.livePlaybackSourceID == input.source
                        ? self.livePlaybackChannel?.id : nil,
                    slices: slices
                )
                let snapshot: EPGGuideSnapshot
                switch input.source {
                case .imported(let sourceID):
                    let key = EPGRequestKey(
                        source: input.source,
                        revision: revision,
                        resource: "xmltv"
                    )
                    let status = await environment.productionEPGRepository.status(for: key)
                    guard !Task.isCancelled, self.liveGuideRequest == request,
                          self.epgRevision(for: input.source) == revision else { return }
                    self.liveEPG.setStatus(status)
                    self.updateImportedEPGStatus(status, sourceID: sourceID)
                    let shouldRefresh = status.nextRetryAt <= Date()
                        && self.resolvedEPGSource(for: input.source)?.url != nil
                    self.liveGuide.begin(identity, refreshing: true)
                    if shouldRefresh,
                       let url = self.resolvedEPGSource(for: input.source)?.url {
                        self.beginXMLTVResourceRefresh(key: key, url: url)
                    }
                    guard status.summary != nil else {
                        if self.epgResourceRefreshTasks[key] != nil {
                            self.liveGuideWaitingForResource = key
                            BrowserInteractionTrace.record("guide.waitResource", request: identity.demandRevision)
                        } else {
                            self.liveGuide.fail(.unavailable, identity: identity)
                        }
                        return
                    }
                    snapshot = try await EPGGuideXMLTVLoader.load(
                        repository: environment.productionEPGRepository,
                        key: key,
                        demand: demand,
                        availability: status.availability,
                        retainedSnapshotCost: retainedCost
                    )

                case .xtream(let providerID):
                    guard let record = self.activeConfigurationRecord,
                          record.id == providerID,
                          let configuration = try? XtreamProviderConfiguration(data: record.rawData),
                          configuration.providerID == providerID else {
                        self.liveGuide.setUnsupported()
                        return
                    }
                    let streamIDs = Dictionary(uniqueKeysWithValues:
                        input.channels.compactMap { channel -> (String, String)? in
                            guard let locator = self.nativeChannelLocator(
                                sourceID: input.source,
                                channel: channel
                            ) else { return nil }
                            return (channel.id, locator.streamID)
                        }
                    )
                    let context = EPGGuideXtreamContext(
                        accountIdentity: configuration.providerID.uuidString,
                        serverIdentity: configuration.serverBaseURL.absoluteString,
                        configurationRevision: revision,
                        streamIDByChannelID: streamIDs
                    )
                    let store = environment.xtreamCredentialStore
                    let client = environment.xtreamHTTPClient
                    let userAgent = Self.xtreamUserAgent
                    snapshot = try await EPGGuideXtreamLoader.load(
                        repository: environment.productionEPGRepository,
                        demand: demand,
                        context: context,
                        retainedSnapshotCost: retainedCost,
                        fetch: { streamID in
                            try await XtreamEPGAdapter.fetch(
                                configuration: configuration,
                                streamID: streamID,
                                credentialStore: store,
                                httpClient: client,
                                userAgent: userAgent
                            )
                        }
                    )
                }
                guard !Task.isCancelled, self.liveGuideRequest == request,
                      self.epgRevision(for: input.source) == revision else { return }
                if !self.liveGuide.publish(snapshot, identity: identity) {
                    self.liveGuide.fail(.snapshotChanged, identity: identity)
                }
                BrowserInteractionTrace.record("guide.delivered", request: identity.demandRevision)
            } catch let failure as EPGGuideFailure {
                self.liveGuide.fail(failure, identity: identity)
            } catch is CancellationError {
                // A newer demand owns presentation; cancellation is not empty or failed.
            } catch {
                self.liveGuide.fail(.invalidRequest, identity: identity)
            }
        }
    }

    private func restartLiveGuideDemandIfNeeded(for key: EPGRequestKey? = nil) {
        guard let input = liveGuideInput else { return }
        if let key {
            guard key.source == EPGSourceKey(input.source),
                  key.revision == epgRevision(for: input.source) else { return }
        }
        startLiveGuideDemand(input)
    }

    private static func liveGuideSlices(from start: Date, to end: Date) throws
        -> [EPGGuideTimeSlice] {
        guard start < end, end.timeIntervalSince(start) <= 24 * 60 * 60 else {
            throw EPGGuideValidationError.invalidDemand
        }
        let boundary = min(end, start.addingTimeInterval(12 * 60 * 60))
        var slices = [try EPGGuideTimeSlice(start: start, end: boundary)]
        if boundary < end {
            slices.append(try EPGGuideTimeSlice(start: boundary, end: end))
        }
        return slices
    }

    func setEPGChannelVisibility(source: LiveSourceID, channel: LiveChannel, visible: Bool) {
        guard epgBrowserSource == source else { return }
        var next = epgBrowserChannels.filter { $0.id != channel.id }
        if visible, next.count < 100 { next.append(channel) }
        guard next != epgBrowserChannels else { return }
        epgBrowserChannels = next
        scheduleEPGRefresh()
    }

    func refreshEPGAfterActivation() {
        liveEPG.tick()
        scheduleEPGRefresh()
    }

    /// Drafts reach persistence and the EPG lifecycle only on explicit submission.
    @discardableResult
    func saveEPGPreferences(_ draft: EPGPreferences) async -> Bool {
        guard !isSavingEPGPreferences, let environment else { return false }
        isSavingEPGPreferences = true
        defer { isSavingEPGPreferences = false }
        do {
            let validated = try draft.validated()
            try await environment.database.saveEPGPreferences(validated)
            await applyEPGPreferences(validated)
            return true
        } catch {
            // Neither URL validation nor transport/storage errors expose token-bearing input.
            presentedError = UserFacingError(
                title: L10n.string("settings.epg.save-failed", fallback: "Unable to Save Programme Settings"),
                message: L10n.string("settings.epg.invalid-url", fallback: "Enter a valid HTTP or HTTPS XMLTV address and try again. Your previous settings have been kept."))
            return false
        }
    }

    private func resolvedEPGSource(for source: LiveSourceID) -> ResolvedXMLTVSource? {
        guard case .imported(let id) = source,
              liveSources.contains(where: { $0.id == id }), loadedLivePlaylists[id] != nil else { return nil }
        return epgPreferences.resolvedXMLTV(for: source, embedded: loadedLivePlaylists[id]?.epgURL)
    }

    /// Read-only, current-configuration projection. Native short EPG is not
    /// aggregated into a misleading source-wide XMLTV status.
    func liveBackgroundEPGPresentation(for source: LiveSourceID, at now: Date) -> LiveEPGPresentation? {
        guard case .imported(let id) = source, loadedLivePlaylists[id] != nil else { return nil }
        let enabled = epgPreferences.automaticEPGEnabled && epgPreferences.source(id).mode != .disabled
        let key = epgRevision(for: source).map { EPGRequestKey(source: source, revision: $0, resource: "xmltv") }
        let status = key.flatMap { liveEPG.status($0) }
        let failed: Bool
        if case .failed = liveSourceEPGStatuses[id] { failed = true } else { failed = false }
        return LiveEPGPresentation(enabled: enabled, key: key, status: status,
            loading: key.map { liveEPGLoadActivities[$0] != nil } ?? false,
            refreshFailed: failed, now: now)
    }

    func liveBackgroundValidationPresentation(for source: LiveSourceID) -> LiveValidationPresentation? {
        liveValidationActivity.presentation(for: source)
    }

    /// Popover opening pulls the mailbox once; it does not start/stop any task.
    func synchronizeLiveValidationPresentation(for source: LiveSourceID) {
        guard case .imported(let id) = source, let relay = liveValidationProgressRelays[id],
              let permit = liveValidationPermits[id], !permit.isCancelled else { return }
        let value = relay.snapshot()
        guard value.runID == permit.id else { return }
        liveValidationActivity.accept(value)
    }

    func stopLiveBackgroundValidation(sourceID: LiveSourceID, runID: UUID) {
        guard case .imported(let id) = sourceID,
              liveValidationSelectedSource == id, !isShutdownRequested, !epgSleeping,
              liveSources.contains(where: { $0.id == id }), !deletingImportedSourceIDs.contains(id),
              case .checking = liveSourceValidationStatuses[id],
              liveValidationPermits[id]?.id == runID else { return }
        cancelLiveSourceValidation(id, expectedRunID: runID)
    }

    // Observation of existing load scopes only. Never schedules work and
    // never carries errors, payloads or persistent task history.
    @Published private var liveEPGLoadActivities: [EPGRequestKey: UUID] = [:]

    func beginLiveEPGLoadPresentation(_ key: EPGRequestKey) -> UUID {
        let token = UUID()
        liveEPGLoadActivities[key] = token
        return token
    }

    func finishLiveEPGLoadPresentation(_ key: EPGRequestKey, token: UUID) {
        if liveEPGLoadActivities[key] == token { liveEPGLoadActivities[key] = nil }
    }

    private func applyEPGPreferences(_ next: EPGPreferences) async {
        let previous = epgPreferences
        guard previous != next else { return }
        let masterChanged = previous.automaticEPGEnabled != next.automaticEPGEnabled
        let affected = liveSources.map(\.id).filter { id in
            let embedded = loadedLivePlaylists[id]?.epgURL
            return masterChanged || previous.source(id) != next.source(id)
                || previous.resolvedXMLTV(for: .imported(id), embedded: embedded)
                    != next.resolvedXMLTV(for: .imported(id), embedded: embedded)
        }
        epgPreferences = next
        // Invalidate presentation and the running waiter BEFORE any actor hop.
        // Source generations are deliberately independent of the persisted URL digest.
        epgRefreshTask?.cancel()
        liveGuideTask?.cancel()
        liveGuideTask = nil
        liveGuideRequest = nil
        if masterChanged {
            for task in epgResourceRefreshTasks.values { task.cancel() }
            epgResourceRefreshTasks.removeAll()
            epgResourceRefreshOperationIDs.removeAll()
        } else {
            for key in Array(epgResourceRefreshTasks.keys) where affected.contains(key.source.id) {
                epgResourceRefreshTasks.removeValue(forKey: key)?.cancel()
                epgResourceRefreshOperationIDs[key] = nil
            }
        }
        liveEPGLoadActivities.removeAll()
        epgRefreshGeneration = UUID()
        let generation = epgRefreshGeneration
        if masterChanged {
            liveEPG.removeAll()
            epgInitialSourceID = nil
        }
        for id in affected {
            liveEPG.remove(.imported(id))
            epgFailures[id] = nil
            liveSourceEPGStatuses[id] = nil
        }
        if let environment, masterChanged {
            if next.automaticEPGEnabled { try? await environment.productionEPGRepository.resume() }
            else { _ = await environment.productionEPGRepository.pause() }
        }
        guard epgRefreshGeneration == generation else { return }
        // Unchanged embedded/custom/native sources retain their snapshots and flights.
        scheduleEPGRefresh(cancelSharedRequests: false)
        restartLiveGuideDemandIfNeeded()
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    func setEPGInputsForTesting(sources: [StoredLiveSource], playlists: [UUID: LivePlaylist]) {
        liveSources = sources
        acceptedImportedCatalogs = Dictionary(uniqueKeysWithValues: playlists.map {
            ($0.key, AcceptedImportedCatalog(sourceID: $0.key, playlist: $0.value))
        })
    }
    func applyEPGPreferencesForTesting(_ value: EPGPreferences) async throws {
        await applyEPGPreferences(try value.validated())
    }
    #endif

    /// Synchronous scheduling only; never awaited by playLive or channel switch.
    private func scheduleEPGRefresh(cancelSharedRequests _: Bool = true) {
        epgRefreshTask?.cancel()
        epgBoundaryTask?.cancel()
        epgBoundaryTask = nil
        epgRefreshGeneration = UUID()
        guard environment != nil, epgPreferences.automaticEPGEnabled,
              !isShutdownRequested, !epgSleeping else { return }
        let generation = epgRefreshGeneration
        epgRefreshTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self, self.epgRefreshGeneration == generation else { return }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                while !Task.isCancelled, self.epgRefreshGeneration == generation,
                      !self.isShutdownRequested, !self.epgSleeping {
                    await self.refreshEPGDemand(generation: generation)
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
            } catch { /* cancellation is not an EPG failure */ }
        }
    }

    private func epgRevision(for source: LiveSourceID) -> String? {
        guard epgPreferences.automaticEPGEnabled else { return nil }
        switch source {
        case .imported:
            // Same endpoint preserves a usable schedule across playlist refresh.
            return resolvedEPGSource(for: source)?.revision
        case .xtream(let id):
            guard !nativeLiveAccountMutationIDs.contains(id),
                  let record = activeConfigurationRecord, record.id == id,
                  record.sourceKind == .xtream else { return nil }
            // No credential values; password-only edits also update updatedAt.
            return EPGRequestKey.revision(for: record.rawData
                + Data(String(record.updatedAt.timeIntervalSince1970).utf8))
        }
    }

    private func refreshEPGDemand(generation: UUID) async {
        guard let environment else { return }
        var channelsBySource: [LiveSourceID: [LiveChannel]] = [:]
        var sourceOrder: [LiveSourceID] = []
        func add(_ source: LiveSourceID, _ channel: LiveChannel?) {
            if channelsBySource[source] == nil {
                channelsBySource[source] = []
                sourceOrder.append(source)
            }
            guard let channel,
                  channelsBySource[source]!.count < 100,
                  !channelsBySource[source]!.contains(where: { $0.id == channel.id }) else { return }
            channelsBySource[source]!.append(channel)
        }
        if let source = livePlaybackSourceID, let channel = livePlaybackChannel {
            add(source, channel)
        }
        if let source = epgBrowserSource {
            add(source, nil)
            for channel in epgBrowserChannels { add(source, channel) }
        }
        if let id = epgInitialSourceID { add(.imported(id), nil) }

        for source in sourceOrder {
            guard !Task.isCancelled, epgRefreshGeneration == generation else { return }
            guard let revision = epgRevision(for: source) else { continue }
            let channels = channelsBySource[source] ?? []
            let presentationGeneration = liveEPG.prepare(source: source, revision: revision)
            switch source {
            case .imported(let id):
                let key = EPGRequestKey(source: source, revision: revision, resource: "xmltv")
                let status = await environment.productionEPGRepository.status(for: key)
                guard !Task.isCancelled, epgRefreshGeneration == generation,
                      epgRevision(for: source) == revision else { return }
                liveEPG.setStatus(status)
                updateImportedEPGStatus(status, sourceID: id)
                if status.nextRetryAt <= Date(), let url = resolvedEPGSource(for: source)?.url {
                    beginXMLTVResourceRefresh(key: key, url: url)
                }
                guard status.summary != nil, !channels.isEmpty else { continue }
                do {
                    let batch = try await environment.productionEPGRepository.queryXMLTVNowNext(
                        channels, for: key, at: Date(), demandRevision: generation)
                    guard !Task.isCancelled, epgRefreshGeneration == generation,
                          epgRevision(for: source) == revision else { return }
                    _ = liveEPG.publish(batch, channels: channels, source: source,
                        revision: revision, generation: presentationGeneration,
                        demandRevision: generation,
                        serviceIncarnation: environment.productionEPGRepository.incarnation)
                } catch { /* query failure is not an empty guide or a playback failure */ }

            case .xtream(let providerID):
                guard let record = activeConfigurationRecord, record.id == providerID,
                      let configuration = try? XtreamProviderConfiguration(data: record.rawData) else { continue }
                for channel in channels {
                    guard !Task.isCancelled, epgRefreshGeneration == generation else { return }
                    guard let locator = nativeChannelLocator(sourceID: source, channel: channel) else { continue }
                    let key = EPGRequestKey(source: source, revision: revision, resource: locator.streamID)
                    let store = environment.xtreamCredentialStore
                    let client = environment.xtreamHTTPClient
                    let userAgent = Self.xtreamUserAgent
                    do {
                        let batch = try await environment.productionEPGRepository.loadXtream(
                            key: key, accountIdentity: configuration.providerID.uuidString,
                            serverIdentity: configuration.serverBaseURL.absoluteString,
                            configurationRevision: revision, at: Date(), demandRevision: generation,
                            fetch: {
                                try await XtreamEPGAdapter.fetch(configuration: configuration,
                                    streamID: locator.streamID, credentialStore: store,
                                    httpClient: client, userAgent: userAgent)
                            })
                        guard !Task.isCancelled, epgRefreshGeneration == generation,
                              epgRevision(for: source) == revision else { return }
                        _ = liveEPG.publish(batch, channels: [channel], source: source,
                            revision: revision, generation: presentationGeneration,
                            demandRevision: generation,
                            serviceIncarnation: environment.productionEPGRepository.incarnation)
                    } catch { /* optional enrichment; playback and other channels continue */ }
                }
            }
        }
        scheduleEPGBoundaryRefresh()
    }

    private func scheduleEPGBoundaryRefresh() {
        epgBoundaryTask?.cancel()
        guard !isShutdownRequested, !epgSleeping,
              let boundary = liveEPG.nextBoundary(after: Date()) else {
            epgBoundaryTask = nil
            return
        }
        let nanoseconds = UInt64(max(0.05, boundary.timeIntervalSinceNow + 0.05) * 1_000_000_000)
        epgBoundaryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.scheduleEPGRefresh(cancelSharedRequests: false)
            } catch { }
        }
    }

    private func beginXMLTVResourceRefresh(key: EPGRequestKey, url: URL, force: Bool = false) {
        guard epgResourceRefreshTasks[key] == nil, let environment,
              !isShutdownRequested, !epgSleeping else { return }
        let activityID = beginLiveEPGLoadPresentation(key)
        let operationID = UUID()
        epgResourceRefreshOperationIDs[key] = operationID
        epgResourceRefreshTasks[key] = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epgResourceRefreshOperationIDs[key] == operationID {
                    self.finishLiveGuideResourceWait(key: key, operationID: operationID)
                    self.epgResourceRefreshOperationIDs[key] = nil
                    self.epgResourceRefreshTasks[key] = nil
                    self.finishLiveEPGLoadPresentation(key, token: activityID)
                }
            }
            do {
                let status = try await environment.productionEPGRepository.refreshXMLTV(
                    key: key, url: url, force: force)
                guard !Task.isCancelled, !self.epgSleeping,
                      self.epgRevision(for: .imported(key.source.id)) == key.revision else { return }
                self.liveEPG.setStatus(status)
                self.updateImportedEPGStatus(status, sourceID: key.source.id)
                self.scheduleEPGRefresh(cancelSharedRequests: false)
                self.restartLiveGuideDemandIfNeeded(for: key)
                _ = try? await environment.productionEPGRepository.performMaintenance()
            } catch {
                self.finishLiveGuideResourceWait(key: key, operationID: operationID)
            }
        }
    }

    private func finishLiveGuideResourceWait(key: EPGRequestKey, operationID: UUID) {
        guard epgResourceRefreshOperationIDs[key] == operationID,
              liveGuideWaitingForResource == key,
              let request = liveGuideRequest,
              request.identity.source == key.source,
              request.identity.revision == key.revision else { return }
        liveGuideWaitingForResource = nil
        if epgSleeping || isShutdownRequested {
            liveGuide.suspend()
        } else {
            liveGuide.fail(.unavailable, identity: request.identity)
        }
        BrowserInteractionTrace.record("guide.resourceEnded", request: request.identity.demandRevision)
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    func beginLiveGuideResourceWaitForTesting(key: EPGRequestKey, operation: UUID) {
        let identity = LiveGuideDeliveryIdentity(source: key.source, revision: key.revision,
            demandRevision: UUID(), serviceIncarnation: UUID(), capability: .xmltv)
        let input = LiveGuideDemandInput(source: .imported(key.source.id), channels: [],
            windowStart: Date(), windowEnd: Date().addingTimeInterval(43200),
            visibleRange: 0..<1, focusedChannelID: nil)
        liveGuideRequest = LiveGuideRequestSpec(input: input, identity: identity)
        liveGuideWaitingForResource = key
        epgResourceRefreshOperationIDs[key] = operation
        liveGuide.begin(identity, refreshing: true)
    }

    func finishLiveGuideResourceWaitForTesting(key: EPGRequestKey, operation: UUID) {
        finishLiveGuideResourceWait(key: key, operationID: operation)
    }
    #endif

    private func updateImportedEPGStatus(_ status: EPGRepositoryStatus, sourceID: UUID) {
        let message = L10n.string("live.epg.refresh-failed",
                                  fallback: "Programme refresh failed; any saved schedule is still available.")
        if status.summary == nil, status.consecutiveFailures == 0 {
            liveSourceEPGStatuses[sourceID] = .loading
            epgFailures[sourceID] = nil
            return
        }
        liveSourceEPGStatuses[sourceID] = LiveSourceEPGStatus(status: status, failureMessage: message)
        epgFailures[sourceID] = status.consecutiveFailures > 0 ? message : nil
        if epgInitialSourceID == sourceID { epgInitialSourceID = nil }
    }

    private func loadSettings() async throws {
        guard let environment else { return }
        epgPreferences = try await environment.database.epgPreferences()
        if let value = try await environment.database.setting(
            forKey: "privacy.incognito"
        ), case .bool(let enabled) = value {
            incognitoMode = enabled
        }
        if let value = try await environment.database.setting(
            forKey: "history.retentionDays"
        ) {
            switch value {
            case .integer(let days):
                historyRetentionDays = min(max(Int(days), 1), 3_650)
            case .number(let days):
                historyRetentionDays = min(max(Int(days), 1), 3_650)
            default:
                break
            }
        }
        if let value = try await environment.database.setting(
            forKey: "appearance.theme"
        ), case .string(let rawTheme) = value,
           let theme = AppTheme(persistedValue: rawTheme) {
            appTheme = theme
        }
        if let value = try await environment.database.setting(
            forKey: "playback.autoPlayNextEpisode"
        ), case .bool(let enabled) = value {
            autoPlayNextEpisode = enabled
        }
        if let value = try await environment.database.setting(
            forKey: "playback.subtitlesEnabled"
        ), case .bool(let enabled) = value {
            prefersPlayerSubtitlesEnabled = enabled
            playerSubtitlesEnabled = enabled
        }
        if let value = try await environment.database.setting(
            forKey: "playback.subtitleTrack"
        ), let preference = PlayerSubtitleTrackPreference(setting: value) {
            preferredPlayerSubtitleTrack = preference
            selectedPlayerSubtitleTrackID = preference.id
        }
        if let value = try await environment.database.setting(
            forKey: LiveSettingsKey.favoriteChannels
        ), case .array(let identifiers) = value {
            favoriteLiveChannelIDs = Set(identifiers.compactMap(\.stringValue))
        }
        if let value = try await environment.database.setting(
            forKey: LiveSettingsKey.deletedChannels
        ), case .array(let identifiers) = value {
            deletedLiveChannelIDs = Set(identifiers.compactMap(\.stringValue))
        }
        try await loadNativeLiveReferences()
        if let value = try await environment.database.setting(
            forKey: CloudAccountStatusStore.settingKey
        ), let stored = CloudAccountStatusStore(setting: value) {
            cloudAccountStatusStore = stored
        }
        await loadSearchSiteScope()
    }

    func loadNativeLiveReferences() async throws {
        guard let liveReferenceStore else { return }
        nativeLiveFavorites = StoredLiveChannelReferenceEnvelope(setting:
            try await liveReferenceStore.setting(forKey: "live.favoriteReferences.v1")
        )
        nativeLiveHiddenChannels = StoredLiveChannelReferenceEnvelope(setting:
            try await liveReferenceStore.setting(forKey: "live.hiddenReferences.v1")
        )
    }

    private func persistCloudAccountStatusStore() async {
        guard let environment,
              let setting = cloudAccountStatusStore.setting else { return }
        try? await environment.database.setSetting(
            setting,
            forKey: CloudAccountStatusStore.settingKey
        )
    }

    private func persistFavoriteLiveChannels() async throws {
        guard let environment else { return }
        try await environment.database.setSetting(
            .array(favoriteLiveChannelIDs.sorted().map(JSONValue.string)),
            forKey: LiveSettingsKey.favoriteChannels
        )
    }

    private func persistDeletedLiveChannels() async throws {
        guard let environment else { return }
        try await environment.database.setSetting(
            .array(deletedLiveChannelIDs.sorted().map(JSONValue.string)),
            forKey: LiveSettingsKey.deletedChannels
        )
    }

    private func liveFavoriteID(sourceName: String, channel: LiveChannel) -> String {
        "\(sourceName)::\(channel.id)"
    }

    private func hasAdjacentEpisode(offset: Int) -> Bool {
        guard let playback = activePlayback,
              let currentIndex = manuallyOrderedPlayerEpisodes.firstIndex(
                where: { $0.id == playback.episode.id }
              ) else { return false }
        return manuallyOrderedPlayerEpisodes.indices.contains(currentIndex + offset)
    }

    private func resetPlaybackSkipSession() {
        playbackSkipSession = nil
        playbackSkipOpeningEnd = nil
        playbackSkipEndingDuration = nil
        playbackSkipOpeningEnabled = false
        playbackSkipEndingEnabled = false
        playbackEndingSkipPrompt = nil
        playbackSkipAppliesToAllEpisodes = true
    }

    private func noteUserSeekForPlaybackSkip(to target: TimeInterval) {
        guard var session = playbackSkipSession,
              session.episodeSessionID == playbackSessionID else { return }
        if let opening = session.effectiveRule.openingEnd,
           target < opening {
            session.openingSkipSuppressed = true
        }
        if let ending = session.effectiveRule.endingDuration,
           let boundary = PlaybackSkipPolicy.endingBoundary(
                duration: playerSnapshot.duration,
                endingDuration: ending
           ) {
            let promptStart = PlaybackSkipPolicy.endingPromptStart(
                boundary: boundary,
                speed: playerSnapshot.speed
            )
            if target >= promptStart {
                session.endingSkipSuppressed = true
            } else {
                session.observedPlaybackBeforeEndingPrompt = true
            }
        }
        playbackSkipSession = session
        playbackEndingSkipPrompt = nil
    }

    private func handlePlaybackSkipSnapshot(
        _ snapshot: PlayerSnapshot,
        requestID: UUID?
    ) {
        guard requestID == activePlayerRequestID,
              var session = playbackSkipSession,
              session.episodeSessionID == playbackSessionID,
              activePlayback != nil,
              automaticNextEpisode != nil,
              !session.endingSkipSuppressed,
              snapshot.historyProgressIsReliable,
              !snapshot.isSeeking,
              !snapshot.isPausedForCache,
              let rawEnding = session.effectiveRule.endingDuration else {
            playbackEndingSkipPrompt = nil
            return
        }
        let validated = PlaybackSkipPolicy.validated(
            session.effectiveRule,
            duration: snapshot.duration
        )
        guard let ending = validated.endingDuration,
              let boundary = PlaybackSkipPolicy.endingBoundary(
                duration: snapshot.duration,
                endingDuration: ending
              ), rawEnding == ending else {
            playbackEndingSkipPrompt = nil
            return
        }
        let promptStart = PlaybackSkipPolicy.endingPromptStart(
            boundary: boundary,
            speed: snapshot.speed
        )
        if snapshot.position < promptStart {
            if snapshot.status == .playing {
                session.observedPlaybackBeforeEndingPrompt = true
                playbackSkipSession = session
            }
            playbackEndingSkipPrompt = nil
            return
        }
        guard snapshot.status == .playing else {
            return
        }
        if snapshot.position < boundary {
            let seconds = Int(ceil(
                (boundary - snapshot.position) / max(snapshot.speed, 0.1)
            ))
            let prompt = PlaybackEndingSkipPrompt(
                secondsUntilBoundary: max(1, seconds),
                willAdvanceAutomatically: autoPlayNextEpisode
                    && session.observedPlaybackBeforeEndingPrompt
            )
            if playbackEndingSkipPrompt != prompt {
                playbackEndingSkipPrompt = prompt
            }
            return
        }
        if autoPlayNextEpisode,
           session.observedPlaybackBeforeEndingPrompt {
            playbackEndingSkipPrompt = nil
            requestAdvanceToNextEpisode(
                reason: .endingSkip,
                sessionID: session.episodeSessionID
            )
        } else {
            let prompt = PlaybackEndingSkipPrompt(
                secondsUntilBoundary: 0,
                willAdvanceAutomatically: false
            )
            if playbackEndingSkipPrompt != prompt {
                playbackEndingSkipPrompt = prompt
            }
        }
    }

    private func startPlayerEventLoop() {
        guard !isShutdownRequested,
              playerEventTask == nil,
              let player = environment?.player else { return }
        playerEventTask = Task { [weak self] in
            for await event in player.events {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot, let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
                    if snapshot.status == .playing || snapshot.status == .paused,
                       let requestID {
                        self.nodePlaybackLastCheckpoint = (requestID,
                            NodePlaybackRecoveryCheckpoint(position: snapshot.position,
                                paused: snapshot.status == .paused))
                    }
                    let previousHistoryStatus = self.playerSnapshot.status
                    self.playerSnapshot = snapshot
                    self.handlePlaybackSkipSnapshot(
                        snapshot,
                        requestID: requestID
                    )
                    self.historyProgressCheckpoint.observe(snapshot, owner: requestID)
                    let subtitleTracks = snapshot.tracks.filter {
                        $0.type == .subtitle
                    }
                    if !subtitleTracks.isEmpty {
                        let subtitlesEnabled = subtitleTracks.contains {
                            $0.isSelected
                        }
                        if self.playerSubtitlesEnabled != subtitlesEnabled {
                            self.playerSubtitlesEnabled = subtitlesEnabled
                        }
                        if let selected = subtitleTracks.first(where: { $0.isSelected }) {
                            if self.selectedPlayerSubtitleTrackID != selected.id {
                                self.selectedPlayerSubtitleTrackID = selected.id
                            }
                            let preference = PlayerSubtitleTrackPreference(
                                track: selected
                            )
                            if self.preferredPlayerSubtitleTrack != preference {
                                self.preferredPlayerSubtitleTrack = preference
                            }
                        } else if let preference = self.preferredPlayerSubtitleTrack,
                                  let remembered =
                                    PlayerSubtitleTrackPreference.matchingTrack(
                                        in: subtitleTracks,
                                        preference: preference
                                    ) {
                            if self.selectedPlayerSubtitleTrackID != remembered.id {
                                self.selectedPlayerSubtitleTrackID = remembered.id
                            }
                        }
                    }
                    let elapsedSinceHistorySave = Date()
                        .timeIntervalSince(self.lastHistorySaveAt)
                    let isInactiveStatus = snapshot.status == .paused
                        || snapshot.status == .ended
                        || snapshot.status == .stopped
                    let liveWrite = self.playbackHistoryWrite(position: snapshot.position, duration: snapshot.duration)
                    let gainedDuration = liveWrite.map { write in
                        write.record.duration > 0 && (self.history.first { $0.id == write.record.id }?.duration ?? 0) <= 0
                    } ?? false
                    if let liveWrite, gainedDuration || Date().timeIntervalSince(self.lastHistoryPublishedAt) >= 1 {
                        self.publishHistoryWrite(liveWrite)
                    }
                    let shouldPersist = gainedDuration || (isInactiveStatus && previousHistoryStatus != snapshot.status)
                        || elapsedSinceHistorySave >= (isInactiveStatus ? 1 : 10)
                    if shouldPersist, self.activePlayback != nil {
                        self.schedulePlaybackHistorySave(
                            position: snapshot.position,
                            duration: snapshot.duration
                        )
                    }
                case .fileLoaded(let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
                    if let requestID {
                        if !self.isClosingPlayer && !self.isShutdownRequested {
                            self.playbackDisplaySleep.mediaLoaded(requestID)
                        }
                        await self.activatePreparedTransferLease(
                            requestID: requestID
                        )
                        _ = self.playbackStartupGates.arm(
                            requestID: requestID
                        )
                    }
                    await self.applyPlayerSubtitlePreference(
                        requestID: requestID
                    )
                case .mediaReleased(let requestID):
                    if let requestID {
                        self.playbackDisplaySleep.finishSession(requestID)
                        await self.releaseTransferMediaLease(
                            requestID: requestID,
                            reason: .mediaReleased
                        )
                    }
                case .playbackStarted(let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ), let requestID else {
                        continue
                    }
                    self.hasCurrentPlaybackStarted = true
                    _ = self.completePlaybackStartupGate(
                        requestID: requestID
                    )
                case .ended(let requestID, let origin):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
                    self.playbackDisplaySleep.playbackEnded(self.activePlayerRequestID)
                    switch origin {
                    case .premature(let message):
                        self.handlePlayerEventFailure(
                            message,
                            requestID: requestID
                        )
                    case .natural, .userSeekBoundary:
                        if self.livePlaybackChannel != nil {
                            self.recoverLivePlaybackAfterFailure(
                                requestID: requestID
                            )
                            continue
                        }
                        let endedSessionID = self.playbackSessionID
                        if self.activePlayback != nil {
                            await self.savePlaybackHistory(
                                position: self.playerSnapshot.position,
                                duration: self.playerSnapshot.duration
                            )
                        }
                        if origin.permitsAutomaticAdvance {
                            self.scheduleAdvanceAfterCompletedEnd(
                                endedSessionID: endedSessionID
                            )
                        }
                    }
                case .error(let message, let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
                    self.handlePlayerEventFailure(
                        message,
                        requestID: requestID
                    )
                }
            }
        }
    }

    private func activatePreparedTransferLease(requestID: UUID) async {
        guard transferMediaLeases[requestID] == nil,
              let receipt = preparedTransferReceipts.removeValue(
                forKey: requestID
              ),
              receipt.requestID == requestID else {
            return
        }
        let result = await environment?.nodeBundleRuntime
            .acquireTransferLease(receiptID: receipt.receiptID)
        guard result?.status == .leased else {
            if result?.status == .retryScheduled
                || result?.status == .accountUnavailable {
                preparedTransferReceipts[requestID] = receipt
            }
            return
        }
        transferMediaLeases[requestID] = TransferMediaLease(
            mediaInstanceID: UUID(),
            playbackSessionID: requestID,
            requestGeneration: receipt.requestGeneration,
            receipt: receipt
        )
    }

    private func releaseTransferMediaLease(
        requestID: UUID,
        reason: NodeTransferCleanupReason
    ) async {
        guard let lease = transferMediaLeases.removeValue(
            forKey: requestID
        ) else { return }
        _ = await environment?.nodeBundleRuntime.releaseTransferLease(
            receiptID: lease.receipt.receiptID,
            reason: reason
        )
    }

    private func releaseAllTransferMediaLeases(
        reason: NodeTransferCleanupReason
    ) async {
        let leases = transferMediaLeases
        transferMediaLeases.removeAll()
        for lease in leases.values {
            _ = await environment?.nodeBundleRuntime.releaseTransferLease(
                receiptID: lease.receipt.receiptID,
                reason: reason
            )
        }
    }

    private func releaseReplacedTransferMediaLeases(
        keeping requestID: UUID
    ) async {
        let releasedIDs = transferMediaLeases.keys.filter { $0 != requestID }
        for releasedID in releasedIDs {
            await releaseTransferMediaLease(
                requestID: releasedID,
                reason: .mediaReleased
            )
        }
    }

    private func cleanupTransferReceipt(
        _ receipt: TransferReceipt,
        reason: NodeTransferCleanupReason
    ) async {
        _ = await environment?.nodeBundleRuntime.cleanupTransfer(
            receiptID: receipt.receiptID,
            reason: reason
        )
    }

    private func cleanupPreparedTransferReceipts(
        reason: NodeTransferCleanupReason
    ) async {
        let receipts = preparedTransferReceipts
        preparedTransferReceipts.removeAll()
        for receipt in receipts.values {
            await cleanupTransferReceipt(receipt, reason: reason)
        }
    }

    private func handlePlayerEventFailure(
        _ message: String,
        requestID: UUID?
    ) {
        playbackDisplaySleep.finishSession(activePlayerRequestID)
        if livePlaybackChannel != nil {
            recoverLivePlaybackAfterFailure(
                requestID: requestID,
                message: message
            )
            return
        }
        if let requestID,
           failPlaybackStartupGate(
               requestID: requestID,
               error: AppError.playback(message)
           ) {
            playbackFailureSummary = message
            return
        }
        if let requestID,
           playbackRequestsResolving.contains(requestID) {
            playbackFailureSummary = message
            return
        }
        if let requestID, requestID == activePlayerRequestID,
           let playback = activePlayback,
           let provider = providers[playback.detail.summary.siteKey] as? NodeHTTPSpiderSiteProvider,
           CatPawCloudProvider.resolve(flag: playback.source.name) == .quark {
            guard nodePlaybackRecoveryTask == nil else { return }
            let checkpoint = nodePlaybackLastCheckpoint.flatMap { $0.0 == requestID ? $0.1 : nil }
                ?? NodePlaybackRecoveryCheckpoint(position: playerSnapshot.position, paused: false)
            let pending = PendingCloudPlayback(requestID: requestID,
                configurationID: playback.configurationID, detail: playback.detail,
                source: playback.source, episode: playback.episode, recoveryCheckpoint: checkpoint)
            pendingPlayback = pending
            nodePlaybackRecoveryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.activePlayerRequestID == requestID { self.nodePlaybackRecoveryTask = nil }
                }
                let evidence = await provider.consumeLatePlaybackFailure(
                    transferContext: self.transferPlaybackContext(for: requestID))
                guard !Task.isCancelled, self.activePlayerRequestID == requestID,
                      self.isPlayerPresented else { return }
                if await self.presentLateNodePlaybackAuthorizationIfNeeded(provider: provider,
                    flag: playback.source.name, notBefore: Date().addingTimeInterval(-5), playback: pending) { return }
                guard !Task.isCancelled, self.activePlayerRequestID == requestID,
                      self.isPlayerPresented else { return }
                if evidence?.allowsAutomaticRecovery != false,
                   self.nodePlaybackRecoveryGate.claim(requestID) {
                    await self.startPlayback(detail: playback.detail, source: playback.source,
                        episode: playback.episode, configurationID: playback.configurationID,
                        continuingRequestID: requestID, windowActivation: .preserveFocus,
                        recoveryCheckpoint: checkpoint, isAutomaticRecovery: true)
                } else {
                    self.prepareNodePlaybackFailureRecovery(provider: provider, message: message)
                    self.playbackFailureSummary = evidence?.message ?? message
                    self.playbackResolutionState = .failed
                }
            }
            return
        }
        if let requestID {
            presentPlaybackErrorOnce(message, requestID: requestID)
        } else {
            presentPlaybackErrorOnce(message, requestID: activePlayerRequestID)
        }
    }

    private func scheduleAdvanceAfterCompletedEnd(endedSessionID: UUID) {
        requestAdvanceToNextEpisode(
            reason: .naturalEnd,
            sessionID: endedSessionID
        )
    }

    private func requestAdvanceToNextEpisode(
        reason: EpisodeAdvanceReason,
        sessionID: UUID
    ) {
        guard !reason.requiresAutoPlay || autoPlayNextEpisode else { return }
        automaticEpisodeAdvanceController.schedule(
            sessionID: sessionID
        ) { [weak self] requestID in
            await self?.advanceToNextEpisode(
                reason: reason,
                episodeSessionID: sessionID,
                automaticAdvanceRequestID: requestID
            )
        }
    }

    private func advanceToNextEpisode(
        reason: EpisodeAdvanceReason,
        episodeSessionID: UUID,
        automaticAdvanceRequestID: UUID
    ) async {
        // Cached history may start playback before its full episode list is
        // restored. Await that bounded request, then recheck all ownership
        // below; a fast seek to EOF must not consume the session's one advance
        // attempt while it still contains only the cached current episode.
        if isRestoringPlayerEpisodeList, let restoration = playerEpisodeListRestoreTask {
            await restoration.value
        }
        guard automaticEpisodeAdvanceController.owns(
                  requestID: automaticAdvanceRequestID
              ),
              !Task.isCancelled,
              playbackSessionID == episodeSessionID,
              isPlayerPresented,
              livePlaybackChannel == nil,
              (!reason.requiresAutoPlay || autoPlayNextEpisode),
              let playback = activePlayback,
              let nextEpisode = PlayerEpisodeAdvancePolicy.nextEpisode(
                  in: playback.source.episodes,
                  currentEpisodeID: playback.episode.id,
                  enabled: true,
                  categoryName: playback.detail.summary.categoryName
              ) else {
            return
        }
        if reason == .endingSkip || reason == .manualEndingSkip {
            await savePlaybackHistory(
                position: playerSnapshot.position,
                duration: playerSnapshot.duration
            )
            if !incognitoMode,
               let session = playbackSkipSession,
               session.episodeSessionID == episodeSessionID {
                try? await environment?.database.savePlaybackCompletionMarker(
                    PlaybackCompletionMarker(
                        identity: session.identity,
                        historyRecordID: session.historyRecordID,
                        position: playerSnapshot.position,
                        duration: playerSnapshot.duration
                    ), sessionID: playbackSessionID
                )
            }
        }
        await startPlayback(
            detail: playback.detail,
            source: playback.source,
            episode: nextEpisode,
            configurationID: playback.configurationID,
            windowActivation: .preserveFocus,
            automaticAdvanceRequestID: automaticAdvanceRequestID
        )
    }

    private func applyPlayerSubtitlePreference(requestID: UUID?) async {
        guard PlaybackRequestOwnershipPolicy.accepts(
            requestID: requestID,
            activeRequestID: activePlayerRequestID
        ) else { return }
        let tracks = playerSnapshot.tracks.filter { $0.type == .subtitle }
        guard !tracks.isEmpty else {
            playerSubtitlesEnabled = false
            selectedPlayerSubtitleTrackID = nil
            return
        }
        let track = preferredPlayerSubtitleTrack.flatMap {
            PlayerSubtitleTrackPreference.matchingTrack(
                in: tracks,
                preference: $0
            )
        } ?? MPVPlayerClient.preferredSubtitleTrack(in: tracks)
        selectedPlayerSubtitleTrackID = track?.id

        guard prefersPlayerSubtitlesEnabled, let track else {
            try? await environment?.player.selectTrack(id: -1, type: .subtitle)
            guard PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestID,
                activeRequestID: activePlayerRequestID
            ) else { return }
            playerSubtitlesEnabled = false
            return
        }
        do {
            try await environment?.player.selectTrack(
                id: track.id,
                type: .subtitle
            )
            guard PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestID,
                activeRequestID: activePlayerRequestID
            ) else { return }
            playerSubtitlesEnabled = true
            preferredPlayerSubtitleTrack = PlayerSubtitleTrackPreference(
                track: track
            )
        } catch {
            guard PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestID,
                activeRequestID: activePlayerRequestID
            ) else { return }
            playerSubtitlesEnabled = false
            show(error, title: L10n.string("player.subtitle.restore.failed", fallback: "Unable to Restore Subtitle Settings"), target: .player)
        }
    }

    private func persistPlayerSubtitlePreference(
        enabled: Bool,
        track: MediaTrack?
    ) async {
        guard let environment else { return }
        do {
            try await environment.database.setSetting(
                .bool(enabled),
                forKey: "playback.subtitlesEnabled"
            )
            if let track {
                try await environment.database.setSetting(
                    PlayerSubtitleTrackPreference(track: track).settingValue,
                    forKey: "playback.subtitleTrack"
                )
            }
        } catch {
            show(error, title: L10n.string("player.subtitle.save.failed", fallback: "Unable to Save Subtitle Settings"), target: .player)
        }
    }

    private func beginPlaybackStartupGate(
        requestID: UUID,
        timeoutSeconds: UInt64 = 12
    ) -> PlaybackStartupGateToken {
        playbackStartupGates.begin(
            requestID: requestID,
            timeoutNanoseconds: timeoutSeconds * 1_000_000_000
        )
    }

    @discardableResult
    private func completePlaybackStartupGate(requestID: UUID) -> Bool {
        playbackStartupGates.complete(requestID: requestID)
    }

    @discardableResult
    private func failPlaybackStartupGate(
        requestID: UUID,
        expectedIdentity: UUID? = nil,
        error: Error
    ) -> Bool {
        playbackStartupGates.fail(
            requestID: requestID,
            expectedIdentity: expectedIdentity,
            error: error
        )
    }

    private func cancelPlaybackStartupGate(
        requestID: UUID,
        expectedIdentity: UUID? = nil
    ) {
        playbackStartupGates.cancel(
            requestID: requestID,
            expectedIdentity: expectedIdentity
        )
    }

    private func cancelAllPlaybackStartupGates() {
        playbackStartupGates.cancelAll()
    }

    private func awaitPlaybackStartup(
        _ stream: AsyncThrowingStream<Void, Error>
    ) async throws {
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else {
            throw CancellationError()
        }
    }

    private func presentPlaybackErrorOnce(
        _ message: String,
        requestID: UUID
    ) {
        guard isPlayerPresented, requestID == activePlayerRequestID,
              presentedPlaybackErrorRequestIDs.insert(requestID).inserted else { return }
        playbackFailureSummary = LogRedactor.text(message)
        if playbackResolutionState != .exhausted { playbackResolutionState = .failed }
        playerSnapshot.status = .failed(playbackFailureSummary ?? message)
        playerPresentedError = nil
    }

    var canRetryCurrentPlayback: Bool {
        isPlayerPresented && !isShutdownRequested && !isClosingPlayer
            && (livePlaybackNavigationContext != nil || activePlayback != nil || pendingPlayback != nil)
    }

    func retryCurrentPlayback() async {
        guard canRetryCurrentPlayback else { return }
        if let context = livePlaybackNavigationContext, let channel = livePlaybackChannel,
           let stream = livePlaybackStream, liveFlowMayLoad(context) {
            context.attemptedTransports.removeAll()
            await beginLivePlayback(channel: channel, stream: stream, context: context, windowActivation: .preserveFocus)
        } else if let detail = activePlayback?.detail ?? pendingPlayback?.detail,
                  let source = activePlayback?.source ?? pendingPlayback?.source,
                  let episode = activePlayback?.episode ?? pendingPlayback?.episode {
            let configurationID = activePlayback?.configurationID ?? pendingPlayback?.configurationID
            await startPlayback(detail: detail, source: source, episode: episode,
                configurationID: configurationID, windowActivation: .preserveFocus)
        }
    }

    private func loadResolvedPlayback(
        _ media: ResolvedMedia,
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        playbackResult: SitePlaybackResult? = nil,
        configurationID: UUID,
        providerResourceReference: PlaybackResourceReference? = nil,
        sessionID: UUID
    ) async throws {
        guard let environment else {
            throw AppError.playback(
                L10n.string("player.environment.unavailable", fallback: "The player environment is unavailable.")
            )
        }
        guard playbackSessionID == sessionID else {
            throw CancellationError()
        }
        clearPlayerEpisodeListRecovery()
        preparePlayerEpisodePresentations(detail: detail, source: source, sessionID: sessionID)
        let isTVBoxPlayback = providers[detail.summary.siteKey]?.capability
            == .javaDexSpider
        var scopedMedia = media
        if isTVBoxPlayback {
            scopedMedia.transportProfile = .tvBox
        }
        let authoritativeHistoryRecord = pendingPlayback?.requestID == sessionID
            ? pendingPlayback?.origin.historyRecord : nil
        let replacementVideoID = persistentHistoryVideoID(
            detail: detail,
            providerResourceReference: providerResourceReference
        )
        let existing = authoritativeHistoryRecord ?? history.first {
            $0.siteKey == detail.summary.siteKey
                && ($0.videoID == replacementVideoID
                    || $0.videoID == detail.summary.videoID)
                && Self.historyRecord($0, matches: source, episode: episode)
        }
        let skipIdentity = PlaybackSkipRuleIdentity(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            contentID: replacementVideoID,
            lineID: source.referenceIdentity ?? source.stableIdentity,
            episodeID: episode.referenceIdentity ?? episode.stableIdentity
        )
        let skipRules = (try? await environment.database.playbackSkipRules(
            configurationID: configurationID
        )) ?? []
        let completionMarkers = (try? await environment.database
            .playbackCompletionMarkers(
                configurationID: configurationID
            )) ?? []
        let lineSkipRule = skipRules.first {
            $0.identity == skipIdentity.seriesLineIdentity
        }
        let episodeSkipRule = skipRules.first {
            $0.identity == skipIdentity
        }
        let effectiveSkipRule = PlaybackSkipRuleResolver.resolve(
            line: lineSkipRule,
            episode: episodeSkipRule
        )
        let mediaCanSeek = playbackResult?.mediaSession?.rangePolicy
            != .unsupported
        let historyRecordID = HistoryRecord(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            videoID: replacementVideoID,
            title: detail.summary.title,
            sourceKey: source.id
        ).id
        let wasCompletedByEndingSkip = completionMarkers.contains {
            $0.identity == skipIdentity
        }
        let recoveryCheckpoint = pendingPlayback?.requestID == sessionID
            ? pendingPlayback?.recoveryCheckpoint : nil
        let startPosition = recoveryCheckpoint.map { mediaCanSeek ? $0.position : 0 }
            ?? PlaybackSkipPolicy.startPosition(
            resumePosition: wasCompletedByEndingSkip
                ? nil
                : Self.historyResumePosition(from: existing),
            openingEnd: effectiveSkipRule.openingEnd,
            canSeek: mediaCanSeek
        )
        let skipSession = PlaybackSkipSessionState(
            episodeSessionID: sessionID,
            identity: skipIdentity,
            historyRecordID: historyRecordID,
            lineRule: lineSkipRule,
            episodeRule: episodeSkipRule,
            effectiveRule: effectiveSkipRule
        )
        let playback = ActivePlaybackContext(
            configurationID: configurationID,
            detail: detail,
            source: source,
            episode: episode,
            media: scopedMedia,
            playbackResult: playbackResult,
            providerResourceReference: providerResourceReference,
            replacedHistoryRecord: authoritativeHistoryRecord.flatMap {
                let replacementID = HistoryRecord(
                    configurationID: configurationID,
                    siteKey: detail.summary.siteKey,
                    videoID: replacementVideoID,
                    title: detail.summary.title,
                    sourceKey: source.id
                ).id
                return $0.id == replacementID ? nil : $0
            },
            requestID: sessionID
        )
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        livePlaybackNavigationContext = nil
        detailRouteSummary = nil
        selectedDetail = nil
        activePlayerRequestID = sessionID
        presentPlayer(
            requestID: sessionID,
            activation: .preserveFocus
        )
        let startupGate: PlaybackStartupGateToken? = beginPlaybackStartupGate(
            requestID: sessionID, timeoutSeconds: isTVBoxPlayback ? 30 : 12)
        let acquiredNodeLease: NodeRuntimePlaybackLease?
        if let mediaSession = playbackResult?.mediaSession {
            // The Runtime independently verifies the provider kind, transport,
            // endpoint and CatPaw route. A TVBox media session or an ordinary
            // direct/cloud URL therefore cannot acquire this lease.
            acquiredNodeLease = await environment.nodeBundleRuntime
                .acquirePlaybackLease(for: mediaSession)
        } else {
            acquiredNodeLease = nil
        }
        if let receipt = scopedMedia.transferReceipt {
            guard TransferReceiptOwnershipPolicy.accepts(
                receipt,
                requestID: sessionID,
                requestGeneration: transferPlaybackContext(for: sessionID)
                    .requestGeneration
            ) else {
                await cleanupTransferReceipt(
                    receipt,
                    reason: .staleGeneration
                )
                throw CancellationError()
            }
            preparedTransferReceipts[sessionID] = receipt
        }
        defer {
            if let startupGate {
                cancelPlaybackStartupGate(
                    requestID: sessionID,
                    expectedIdentity: startupGate.identity
                )
            }
        }
        var didReachFileLoaded = false
        do {
            try await loadPlayerAfterRenderSurfaceReady(
                scopedMedia,
                startPosition: startPosition,
                requestID: sessionID
            )
            didReachFileLoaded = true
            guard playbackSessionID == sessionID else {
                throw CancellationError()
            }
            // load() returns only after MPV_EVENT_FILE_LOADED. That native
            // boundary proves the replaced media has been released.
            await activatePreparedTransferLease(requestID: sessionID)
            await releaseReplacedTransferMediaLeases(keeping: sessionID)
            // MPV's file-loaded boundary owns autoplay. Wait for actual
            // progress instead of sending another play command here.
            if recoveryCheckpoint?.paused == true {
                try await environment.player.pause()
            } else {
                if let startupGate {
                    try await awaitPlaybackStartup(startupGate.stream)
                    guard playbackSessionID == sessionID else {
                        throw CancellationError()
                    }
                }
            }
        } catch {
            if didReachFileLoaded {
                // The replacement is now the native active media. Stop waits
                // for its actual unload boundary before the fallback release.
                await environment.player.stop(ifOwnedBy: sessionID)
                await releaseTransferMediaLease(
                    requestID: sessionID,
                    reason: .playerLoadFailed
                )
            } else if let retainedRequestID = transferMediaLeases.keys.first(
                where: { $0 != sessionID }
            ) {
                // No FILE_LOADED boundary was crossed. Restore ownership to
                // the media that mpv still holds instead of stopping A merely
                // because preparation or loadfile submission for B failed.
                playbackSessionID = retainedRequestID
                activePlayerRequestID = retainedRequestID
                pendingPlayback = nil
                playbackResolutionState = .playing
            }
            if let receipt = preparedTransferReceipts.removeValue(
                forKey: sessionID
            ) {
                await cleanupTransferReceipt(
                    receipt,
                    reason: .playerLoadFailed
                )
            }
            if let acquiredNodeLease {
                await environment.nodeBundleRuntime.releasePlaybackLease(
                    acquiredNodeLease
                )
            }
            throw error
        }
        let previousNodeLease = activeNodePlaybackLease
        activeNodePlaybackLease = acquiredNodeLease
        if let previousNodeLease, previousNodeLease != acquiredNodeLease {
            await environment.nodeBundleRuntime.releasePlaybackLease(
                previousNodeLease
            )
        }
        activePlayback = playback
        danmaku.begin(
            context: scopedMedia.danmakuContext,
            playbackSessionID: sessionID,
            database: environment.database
        )
        playbackSkipSession = skipSession
        playbackSkipAppliesToAllEpisodes = true
        refreshPlaybackSkipPresentation()
        playbackEndingSkipPrompt = nil
        if wasCompletedByEndingSkip, !incognitoMode {
            try? await environment.database.deletePlaybackCompletionMarker(
                identity: skipIdentity
            )
        }
        if let authoritativeHistoryRecord {
            historyPlaybackSessionCache.store(
                playback,
                for: [authoritativeHistoryRecord.id]
            )
        }
        pendingPlayback = nil
        playbackQualities = playbackResult?.qualities ?? []
        selectedPlaybackQualityID = playbackResult.flatMap { result in
            result.qualities.first { $0.url == result.url }?.id
        }
        isSwitchingPlaybackQuality = false
        await savePlaybackHistory(
            position: PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot) ? playerSnapshot.position : startPosition ?? 0,
            duration: PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot) ? playerSnapshot.duration : existing?.duration ?? 0
        )
        if let authoritativeHistoryRecord, source.episodes.count == 1 {
            restorePlayerEpisodeList(authoritativeHistoryRecord, sessionID: sessionID)
        }
    }

    private func makeDanmakuPlaybackContext(
        configurationID: UUID,
        provider: SiteProvider,
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        result: SitePlaybackResult,
        sessionID: UUID
    ) -> DanmakuPlaybackContext {
        let ecosystem: DanmakuEcosystem
        switch provider.capability {
        case .xtream:
            ecosystem = .xtream
        case .javaScriptSpider where provider is NodeHTTPSpiderSiteProvider:
            ecosystem = .catPaw
        case .javaScriptSpider, .javaDexSpider:
            ecosystem = .tvBox
        case .standardXML, .standardJSON, .base64JSON,
             .unsupportedSpider:
            ecosystem = .unknown
        }

        let contentIdentity = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            contentID: detail.summary.videoID,
            title: detail.summary.title
        )
        let episodeIdentityMetadata = PlaybackResourceAnalyzer.trustedEpisode(episode, categoryName: detail.summary.categoryName)
        let episodeIdentity = DanmakuEpisodeIdentity(
            content: contentIdentity,
            episodeID: episode.referenceIdentity ?? episode.stableIdentity,
            title: episode.name,
            seasonNumber: episodeIdentityMetadata?.season,
            episodeNumber: episodeIdentityMetadata?.episode
        )
        // Xtream PlaySource represents a season. Its source identity is not a
        // video edition, so bind to the account/site edition and let the
        // episode identity carry season and episode specificity.
        let editionID = ecosystem == .xtream
            ? "xtream-site:\(detail.summary.siteKey)"
            : (source.referenceIdentity ?? source.stableIdentity)
        let generation = Self.danmakuRuntimeGeneration(for: sessionID)
        let baseURL = URL(
            string: result.mediaSession?.mediaURL ?? result.url
        )?.deletingLastPathComponent() ?? activeConfigurationRecord?.baseURL
        let providerName = "\(ecosystem.rawValue):\(detail.summary.siteKey)"
        let providedSources = DanmakuSourceNormalizer.sources(
            from: result.danmaku,
            provider: providerName,
            baseURL: baseURL,
            inheritedHeaders: result.headers,
            runtimeGeneration: generation
        )
        var searchCapabilities = result.danmakuSearchCapabilities
        if let configured = activeConfiguration?.danmaku?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            if searchCapabilities.isEmpty || !configured.contains("/website/danmu/fe") {
                searchCapabilities.append(.configuredEndpoint(value: configured))
            }
        }
        var context = DanmakuPlaybackContext(
            ecosystem: ecosystem,
            contentIdentity: contentIdentity,
            editionIdentity: DanmakuEditionIdentity(
                episode: episodeIdentity,
                editionID: editionID
            ),
            providedSources: providedSources,
            searchCapabilities: searchCapabilities,
            runtimeGeneration: generation
        )
        context.matchRequest = DanmakuMatchRequest(title: detail.summary.title, year: detail.summary.year,
            category: detail.summary.categoryName, episode: episode, siblings: source.episodes)
        context.upstreamRequestID = sessionID
        return context
    }

    private static func danmakuRuntimeGeneration(for sessionID: UUID) -> UInt64 {
        let compact = sessionID.uuidString.replacingOccurrences(of: "-", with: "")
        return UInt64(compact.prefix(16), radix: 16) ?? 1
    }

    private func savePlaybackHistory(
        position: TimeInterval,
        duration: TimeInterval,
        reloadHistoryAfterSaving: Bool = true,
        ownedRequestID: UUID? = nil
    ) async {
        guard let write = playbackHistoryWrite(
            position: position,
            duration: duration,
            ownedRequestID: ownedRequestID
        ) else { return }
        if !write.incognito, let activePlayback {
            historyPlaybackSessionCache.store(
                activePlayback,
                for: [write.record.id]
            )
        }
        await persistFinalHistoryWrite(write)
        lastHistorySaveAt = Date()
    }

    private func playbackHistoryWrite(
        position: TimeInterval,
        duration: TimeInterval,
        ownedRequestID: UUID? = nil
    ) -> PlaybackHistoryWrite? {
        guard let playback = activePlayback,
              playback.requestID == activePlayerRequestID,
              !suppressedHistorySessions.contains(playbackSessionID),
              ownedRequestID == nil || ownedRequestID == playback.requestID else { return nil }
        guard let trusted = historyProgressCheckpoint.resolve(position: position, duration: duration,
            reliable: PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot),
            owner: ownedRequestID ?? activePlayerRequestID) else { return nil }
        let position = trusted.position
        let duration = trusted.duration
        let detail = playback.detail
        let providerResourceReference = playback.providerResourceReference
        let persistedVideoID = persistentHistoryVideoID(
            detail: detail,
            providerResourceReference: providerResourceReference
        )
        let write = PlaybackHistoryWrite(
            record: HistoryRecord(
                configurationID: PlaybackConfigurationOwnershipPolicy.historyOwner(
                    captured: playback.configurationID,
                    current: activeConfigurationRecord?.id
                ),
                siteKey: detail.summary.siteKey,
                videoID: persistedVideoID,
                title: detail.summary.title,
                posterURL: detail.summary.posterURL,
                sourceKey: playback.source.id,
                sourceName: playback.source.name,
                episodeName: playback.episode.name,
                episodeReference: Self.persistentHistoryEpisodeReference(
                    playback.episode.url,
                    providerCapability: providers[detail.summary.siteKey]?
                        .capability,
                    isNodeProvider: providers[detail.summary.siteKey]
                        is NodeHTTPSpiderSiteProvider
                ),
                mediaReference: Self.persistentHistoryMediaReference(
                    playback.media.url,
                    playbackResult: playback.playbackResult
                ),
                playbackReference: Self.historyPlaybackReference(
                    source: playback.source,
                    episode: playback.episode,
                    providerResourceReference: providerResourceReference,
                    navigationRecipe: Self.historyNavigationRecipe(
                        detail: detail,
                        source: playback.source,
                        episode: playback.episode,
                        configurationID: playback.configurationID,
                        position: position,
                        persistedDetailID: persistedVideoID
                    ),
                    headers: playback.media.headers
                ),
                position: position,
                duration: duration
            ),
            incognito: incognitoMode,
            requestID: ownedRequestID ?? activePlayerRequestID,
            replacedRecord: playback.replacedHistoryRecord,
            sessionID: playbackSessionID
        )
        historySessionRecordIDs[write.sessionID, default: []].insert(write.record.id)
        if let original = write.replacedRecord { historySessionRecordIDs[write.sessionID, default: []].insert(original.id) }
        return write
    }

    private func publishHistoryWrite(_ write: PlaybackHistoryWrite) {
        guard !write.incognito, !suppressedHistorySessions.contains(write.sessionID),
              write.record.configurationID == activeConfigurationRecord?.id else { return }
        let record = write.record.sanitizedForPersistence()
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            guard history[index].watchedAt <= record.watchedAt else { return }
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
        if let original = write.replacedRecord, original.id != record.id {
            history.removeAll { $0.id == original.id }
        }
        historyRevision &+= 1
        lastHistoryPublishedAt = Date()
    }

    private func persistPlaybackHistoryWrite(
        _ write: PlaybackHistoryWrite, reloadHistoryAfterSaving: Bool
    ) async throws {
        guard let environment, !write.incognito,
              !suppressedHistorySessions.contains(write.sessionID) else { return }
        let saved = try await environment.database.saveWatchedHistory(
            write.record, replacing: write.replacedRecord, sessionID: write.sessionID)
        guard saved, !suppressedHistorySessions.contains(write.sessionID) else { return }
        if activePlayerRequestID == write.requestID {
            activePlayback?.replacedHistoryRecord = nil
        }
        publishHistoryWrite(write)
    }

    private func captureHistoryBeforePlaybackTransition() {
        guard let write = playbackHistoryWrite(position: playerSnapshot.position,
                                               duration: playerSnapshot.duration) else { return }
        // Chain immutable final writes: replacing the coalesced slot would lose
        // A's last seconds during a quick A → B → C transition.
        let previous = historyPersistenceTask
        historyPersistenceTask = Task { [weak self] in
            await previous?.value
            await self?.persistFinalHistoryWrite(write)
        }
    }

    private func persistFinalHistoryWrite(_ write: PlaybackHistoryWrite) async {
        do {
            try await persistPlaybackHistoryWrite(write, reloadHistoryAfterSaving: false)
        } catch {
            // A bounded retry keeps transient database contention from silently
            // discarding the final checkpoint; SQLite also has its busy timeout.
            do { try await persistPlaybackHistoryWrite(write, reloadHistoryAfterSaving: false) }
            catch { reportHistoryPersistenceFailure(error) }
        }
    }

    private func reportHistoryPersistenceFailure(_ error: Error) {
        guard Date().timeIntervalSince(lastHistoryPersistenceErrorAt) > 60 else { return }
        lastHistoryPersistenceErrorAt = Date()
        show(error, title: L10n.string("history.save.failed", fallback: "Unable to Save Watch Progress"))
    }

    private func schedulePlaybackHistorySave(position: TimeInterval, duration: TimeInterval) {
        guard let write = playbackHistoryWrite(position: position, duration: duration) else { return }
        lastHistorySaveAt = Date()
        pendingHistoryWrite = write
        let previous = historyPersistenceTask
        historyPersistenceTask = Task { [weak self] in
            await previous?.value
            guard let self, let pending = self.pendingHistoryWrite else { return }
            self.pendingHistoryWrite = nil
            await self.persistFinalHistoryWrite(pending)
        }
    }

    private func finishScheduledHistoryPersistence() async {
        await historyPersistenceTask?.value
    }

    func refreshHistoryPresentation() async {
        do { try await reloadHistory() }
        catch { reportHistoryPersistenceFailure(error) }
    }

    private func loadPlayerAfterRenderSurfaceReady(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID,
        liveFlow: LivePlaybackNavigationContext? = nil
    ) async throws {
        guard let environment else {
            throw AppError.playback(
                L10n.string("app.environment.uninitialized", fallback: "The application environment has not been initialized.")
            )
        }
        guard liveFlow.map(liveFlowMayLoad) ?? true,
              isPlayerPresented,
              activePlayerRequestID == requestID else {
            throw CancellationError()
        }
        try await environment.player.load(
            media,
            startPosition: startPosition,
            requestID: requestID,
            waitForRenderSurface: { [weak self] renderOwnerID in
                guard let self else { throw CancellationError() }
                try await self.playerRenderSurfaceGate.waitUntilReady(
                    requestID: requestID,
                    renderOwnerID: renderOwnerID
                )
                try Task.checkCancellation()
                guard liveFlow.map(self.liveFlowMayLoad) ?? true,
                      self.isPlayerPresented,
                      self.activePlayerRequestID == requestID,
                      environment.player.renderPlayer?.renderOwnerID
                        == renderOwnerID else {
                    throw CancellationError()
                }
            }
        )
    }

    private func presentPlayer(
        requestID: UUID? = nil,
        activation: PlayerWindowActivationPolicy = .userInitiated
    ) {
        let wasPresented = isPlayerPresented
        isPlayerPresented = true
        let owningRequestID = requestID ?? activePlayerRequestID
        switch activation {
        case .userInitiated:
            issuePlayerWindowCommand(
                wasPresented ? .focus : .showAndActivate,
                requestID: owningRequestID
            )
        case .preserveFocus:
            issuePlayerWindowCommand(
                .showWithoutStealingFocus,
                requestID: owningRequestID
            )
        }
    }

    private func dismissPlayerSurfaceAndRestoreWindow() async {
        isPlayerRenderSurfaceMountEnabled = false
        playerPresentedError = nil
        issuePlayerWindowCommand(.close, requestID: nil)
        isPlayerPresented = false
        // The player owns a separate window. Yield once so AppKit can close
        // that window after the native render context has detached; the
        // browsing window is never resized or transitioned by playback.
        await Task.yield()
    }

    private func issuePlayerWindowCommand(
        _ kind: PlayerWindowCommandKind,
        requestID: UUID?
    ) {
        playerWindowCommand = PlayerWindowCommand(
            requestID: requestID,
            kind: kind
        )
    }

    private func localizedRuntimeErrorMessage(_ error: Error) -> String {
        RuntimeUserFacingMessageMapper.message(for: error)
    }

    private func show(
        _ error: Error,
        title: String,
        target: UserFacingErrorTarget = .browser
    ) {
        let presentation = userFacingError(
            for: error,
            title: title,
            target: target
        )
        if PlayerErrorPresentationPolicy.targetsPlayer(
            target: presentation.target,
            isPlayerPresented: isPlayerPresented
        ) {
            if hasExhaustedLivePlayback || playbackResolutionState == .failed || playbackResolutionState == .exhausted {
                playbackFailureSummary = presentation.message
                playerPresentedError = nil
            } else {
                playerPresentedError = presentation
            }
        } else {
            presentedError = presentation
        }
    }

    private func userFacingError(
        for error: Error,
        title: String,
        target: UserFacingErrorTarget = .browser
    ) -> UserFacingError {
        if let presentation = AndroidRuntimeUserFacingErrorMapper.presentation(
            for: error
        ) {
            return UserFacingError(
                title: presentation.title,
                message: presentation.message,
                target: target
            )
        }
        if let presentation = NodeUserFacingErrorMapper.presentation(for: error) {
            return UserFacingError(
                title: presentation.title,
                message: presentation.message,
                target: target
            )
        }
        if let message = CommonUserFacingErrorMapper.message(for: error) {
            return UserFacingError(
                title: title,
                message: message,
                target: target
            )
        }
        return UserFacingError(
            title: title,
            message: LogRedactor.text(error.localizedDescription),
            target: target
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension AppState {
    func refreshAndroidStorage() async {
        guard let environment else { return }
        androidRuntimeStorage = await environment.androidRuntimeManager.maintenance.storage()
    }

    func uninstallManagedAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy,
              !managedRuntimeInstallationState.isBusy else { return }
        isAndroidRuntimeBusy = true
        defer { isAndroidRuntimeBusy = false }
        do {
            let service = environment.androidRuntimeManager.maintenance
            let plan = try await service.prepareManagedUninstall()
            guard !plan.items.isEmpty else { throw RuntimeMaintenanceError.nothingToRemove }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("settings.android.uninstall.title", fallback: "Uninstall OKVideoMac-managed Android components?")
            alert.informativeText = L10n.string("settings.android.uninstall.message", fallback: "Approximately %@ will be removed. The OKVideoMac Android session will be stopped first. Android sign-in data, user-data backups, private keys, and your external SDK selection will be kept. External SDK files will not be deleted.", ByteCountFormatter.string(fromByteCount: plan.estimatedReclaimBytes, countStyle: .file))
            alert.addButton(withTitle: L10n.string("settings.android.uninstall.confirm", fallback: "Uninstall Components"))
            alert.addButton(withTitle: L10n.string("common.cancel", fallback: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try await runAndroidMaintenance(planID: plan.id)
        } catch {
            androidMaintenanceMessage = maintenanceMessage(error)
        }
        await refreshAndroidStorage()
    }

    func recoverAndroidMaintenanceIfNeeded() async {
        await refreshAndroidStorage()
        guard androidRuntimeStorage?.hasPendingMaintenance == true,
              !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        defer { isAndroidRuntimeBusy = false }
        do { try await runAndroidMaintenance(planID: nil) }
        catch { androidMaintenanceMessage = maintenanceMessage(error) }
        await refreshAndroidStorage()
    }

    private func runAndroidMaintenance(planID: UUID?) async throws {
        guard let environment else { return }
        let manager = environment.androidRuntimeManager
        let coordinator = environment.androidRuntimeModeCoordinator
        let bridge = environment.androidDexBridge
        let token = try await coordinator.beginMaintenance()
        do {
            try await manager.beginMaintenance()
        } catch {
            await coordinator.endMaintenance(token)
            throw error
        }
        androidMaintenanceMessage = L10n.string("settings.android.uninstall.running", fallback: "Stopping Android and checking the uninstall transaction…")
        do {
            let results: [ManagedUninstallResult]
            if let planID {
                results = [try await manager.maintenance.execute(planID: planID) {
                    try await bridge.beginManagedMaintenance()
                }]
            } else {
                results = try await manager.maintenance.recover {
                    try await bridge.beginManagedMaintenance()
                }
            }
            androidMaintenanceMessage = results.contains(where: \.cleanupPending)
                ? L10n.string("settings.android.uninstall.cleanup-pending", fallback: "Components are uninstalled, but some files still need cleanup. Android user data was kept. Retry cleanup before installing again.")
                : L10n.string("settings.android.uninstall.success", fallback: "Maintenance completed. Android user data, private keys, and the external SDK were kept.")
        } catch {
            await bridge.endManagedMaintenance()
            await manager.endMaintenance()
            await coordinator.endMaintenance(token)
            throw error
        }
        await bridge.endManagedMaintenance()
        await manager.endMaintenance()
        await coordinator.endMaintenance(token)
        androidRuntimeModeSnapshot = await coordinator.refresh()
        androidRuntimeStatus = await bridge.runtimeStatus()
    }

    private func maintenanceMessage(_ error: Error) -> String {
        switch error as? RuntimeMaintenanceError {
        case .expiredPlan, .changed:
            return L10n.string("settings.android.uninstall.plan-changed", fallback: "The uninstall plan expired or the files changed. Nothing further was removed. Review a new plan and try again.")
        case .busy:
            return L10n.string("settings.android.uninstall.busy", fallback: "Another Android operation is in progress. Wait for it to finish before trying again.")
        case .sessionNotStopped:
            return L10n.string("settings.android.uninstall.stop-failed", fallback: "The OKVideoMac Android session could not be confirmed stopped. No components were removed.")
        case .nothingToRemove:
            return L10n.string("settings.android.uninstall.empty", fallback: "No recognized managed components or installation cache need removal.")
        default:
            return L10n.string("settings.android.uninstall.failure", fallback: "Maintenance could not finish safely. Unrecognized files and recovery data were kept. Export diagnostics before trying again.")
        }
    }
}
