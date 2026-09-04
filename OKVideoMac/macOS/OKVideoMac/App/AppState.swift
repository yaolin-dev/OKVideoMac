import AppKit
import CryptoKit
import Foundation
import OKVideoCore
import OKVideoPersistence

enum AppSection: String, CaseIterable, Identifiable {
    case home = "点播"
    case live = "直播"
    case favorites = "收藏"
    case history = "历史"
    case settings = "设置"

    var id: String { rawValue }

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
                placeholder: "搜索频道…",
                accessibilityLabel: "搜索直播频道",
                help: "筛选当前直播源中的频道"
            )
        case .home, .favorites, .history, .settings:
            return SidebarSearchPresentation(
                kind: .video,
                placeholder: "搜索点播内容…",
                accessibilityLabel: "搜索点播内容",
                help: "搜索当前点播配置中的全部站点"
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
    let sourceID: UUID
}

/// Keeps high-frequency page navigation separate from the much larger app
/// content model. Publishing section changes through `AppState` used to
/// invalidate every view holding that environment object, including all live
/// channel cards, immediately before those cards were removed from screen.
@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedSection: AppSection = .home
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
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }
}

struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

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
    private static let playerTitleFragments = [
        "播放", "播放器", "跳转", "音量", "静音", "倍速", "清晰度",
        "轨道", "字幕", "音频", "画面", "截图", "硬件解码", "视频渲染"
    ]

    static func targetsPlayer(
        title: String,
        isPlayerPresented: Bool
    ) -> Bool {
        isPlayerPresented
            && playerTitleFragments.contains(where: title.contains)
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
        for error: Error
    ) -> NodeReleaseErrorPresentation? {
        guard let runtimeError = error as? AndroidRuntimeFailureError else {
            return nil
        }
        return .init(
            title: runtimeError.userFacingTitle,
            message: runtimeError.userFacingMessage
        )
    }
}

enum NodeUserFacingErrorMapper {
    static func presentation(for error: Error) -> NodeReleaseErrorPresentation? {
        if let nodeError = error as? NodeBundleRuntimeError {
            switch nodeError {
            case .unsupportedHostContract:
                return .init(
                    title: "Node 兼容模式不受支持",
                    message: "该内容源需要当前版本尚未支持的宿主能力，已停止加载。"
                )
            case .configurationContractInvalid:
                return .init(
                    title: "Node 源配置无效",
                    message: "该源提供的运行配置不完整或格式不受支持。"
                )
            case .hostCapabilityUnavailable, .portAllocationFailed,
                 .loopbackEnforcementFailed, .contractBReadinessFailed:
                return .init(
                    title: "Node Runtime 启动失败",
                    message: "本地运行服务未能通过安全启动检查，请稍后重试。"
                )
            default:
                break
            }
            switch nodeError.diagnosticClassification.category {
            case .transport:
                return .init(
                    title: "Node 组件连接失败",
                    message: "无法获取运行组件，已尝试使用经过校验的本地缓存。请稍后重试。"
                )
            case .trust:
                return .init(
                    title: "Node 安全校验失败",
                    message: "远程运行组件未通过完整性校验，已停止加载。"
                )
            case .cache:
                return .init(
                    title: "Node 缓存不可用",
                    message: "本地运行组件缓存无法通过校验或升级，请稍后重试。"
                )
            case .runtime:
                return .init(
                    title: "Node Runtime 启动失败",
                    message: "内置运行环境未能正常启动，请重启应用后重试。"
                )
            case .spiderSite:
                return .init(
                    title: "内容源请求失败",
                    message: "当前站点暂时无响应，其他站点仍可继续使用。"
                )
            }
        }
        if let appError = error as? AppError {
            switch appError {
            case .contentUnavailable(let message):
                return .init(title: "无法打开内容", message: message)
            case .spider:
                return .init(
                    title: "内容源请求失败",
                    message: "当前站点返回了无法处理的结果，请稍后重试或更换站点。"
                )
            default:
                break
            }
        }
        return nil
    }
}

enum CloudAccountSnapshotStatus: String, Codable, Equatable, Sendable {
    case authenticated
    case unauthenticated
    case pending
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
        ("正在确认", .pending)
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
        let suffix: String
        switch status {
        case .authenticated:
            suffix = "已登录"
        case .unauthenticated:
            suffix = "未登录"
        case .pending:
            suffix = "上次已授权"
        }
        return "\(base) - \(suffix)"
    }

    static func replacingStatusOnly(
        in value: String,
        with status: CloudAccountSnapshotStatus
    ) -> String {
        guard isStatusOnly(value) else { return value }
        switch status {
        case .authenticated:
            return "已登录"
        case .unauthenticated:
            return "未登录"
        case .pending:
            return "上次已授权"
        }
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
    let transport: String
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
            let kind = site.extra["okNodeModuleKind"]?.stringValue ?? "其他"
            return .unavailable("已识别 \(kind) 模块，当前版本尚未启用对应界面")
        }
        let isCatalogueDisabled = site.extra["okNodeCatalogDisabled"]
            == .bool(true)
        if site.extra["okNodeConfigurationRequired"] == .bool(true) {
            return .unavailable("未配置账号或挂载")
        }
        if site.hide != 0, !isCatalogueDisabled {
            return .unavailable("配置中已隐藏")
        }
        if providerCapability == nil || providerCapability == .unsupportedSpider {
            return .unavailable("当前运行环境不支持")
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
    case discoveryFallback
}

enum SearchProviderSelectionPolicy {
    static func effectiveSiteKeys(
        context: SearchLaunchContext,
        scope: SearchSiteScope,
        options: [SearchScopeSiteOption]
    ) -> Set<String> {
        switch context {
        case .manual:
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
        hasAttemptedVerification: Bool
    ) -> Bool {
        let normalizedRequestID = requestID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlayback
            && (normalizedRequestID == nil || normalizedRequestID?.isEmpty == true)
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
                remarks: "打开配置功能",
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
        Dictionary(
            uniqueKeysWithValues: category.filters.compactMap { filter in
                filter.options.first.map { (filter.id, $0.value) }
            }
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
    let filters: [String: String]
    let page: VideoPage?
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
        site: SiteConfiguration?
    ) -> HomeItemRoute {
        if summary.resolvedContentKind == .action
            || summary.action?.nonEmpty != nil {
            return .action
        }
        if summary.isFolder { return .folder }
        // FongMi's `indexs` contract describes discovery/index providers.
        // Their cards are search seeds, not provider-owned detail records.
        if site?.indexs == 1 || summary.videoID.hasPrefix("msearch:") {
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

enum NodeRuntimeHomepageReloadPolicy {
    static func shouldReload(
        previousReadyEndpoint: URL?,
        currentReadyEndpoint: URL,
        usesNodeRuntime: Bool,
        hasActiveConfiguration: Bool,
        isConfigurationImportInProgress: Bool
    ) -> Bool {
        usesNodeRuntime
            && hasActiveConfiguration
            && !isConfigurationImportInProgress
            && previousReadyEndpoint != nil
            && previousReadyEndpoint != currentReadyEndpoint
    }
}

struct SearchFolderPage: Identifiable, Equatable {
    let id: UUID
    let folder: VideoSummary
    var items: [VideoSummary]
    var pagination: Pagination?
    var isLoading: Bool
    var errorMessage: String?

    init(folder: VideoSummary) {
        id = UUID()
        self.folder = folder
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
            return "上一级"
        case .home:
            return "返回点播"
        case .searchResults:
            return "返回搜索结果"
        case .none:
            return "返回点播"
        }
    }

    static func backHelp(
        pathCount: Int,
        origin: SearchFolderOrigin?
    ) -> String {
        switch backDestination(pathCount: pathCount, origin: origin) {
        case .parentFolder:
            return "返回上一级目录"
        case .home:
            return "关闭目录并返回进入前的点播分类"
        case .searchResults:
            return "关闭目录并返回全部搜索结果"
        case .none:
            return "返回点播"
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
        var newItems: [VideoSummary] = []
        newItems.reserveCapacity(loaded.items.count)
        for item in loaded.items where knownIDs.insert(item.id).inserted {
            newItems.append(item)
        }

        var pagination = loaded.pagination
        pagination.page = requestedPage
        if let pageCount = pagination.pageCount {
            pagination.hasMore = requestedPage < pageCount
        }

        let reachedEnd = loaded.items.isEmpty
            || (current != nil && newItems.isEmpty)
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
    static func nextEpisode(
        in episodes: [PlayEpisode],
        currentEpisodeID: String,
        enabled: Bool
    ) -> PlayEpisode? {
        guard enabled,
              let currentIndex = episodes.firstIndex(where: {
                  $0.id == currentEpisodeID
              }) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        guard episodes.indices.contains(nextIndex) else { return nil }
        return episodes[nextIndex]
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

/// Keeps recently resolved provider media capabilities in memory only. Cloud
/// URLs, Cookies and bridge session IDs never cross the persistence boundary,
/// but closing the player must not throw away a still-valid two-hour bridge
/// session and force History to invoke the provider (or show a login QR) again.
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

    private mutating func prune(now: Date) {
        entries = entries.filter {
            now.timeIntervalSince($0.value.lastUsedAt) <= lifetime
        }
    }
}

private struct PlaybackHistoryWrite {
    let record: HistoryRecord
    let incognito: Bool
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

private struct PendingCloudPlayback {
    let requestID: UUID
    let configurationID: UUID
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var origin: PlaybackRequestOrigin = .direct
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
                    result: result
                )
            ],
            parsers: eligibleParsers,
            maximumAttempts: maximumAttempts
        )
    }
}

private struct PlayerEpisodePresentationCacheKey: Equatable, Sendable {
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

struct LivePlaybackCandidate: Equatable {
    let channel: LiveChannel
    let stream: LiveStream

    var identifier: String {
        "\(channel.id)::\(stream.id)"
    }
}

enum LivePlaybackRecoveryPolicy {
    static func candidates(
        channels: [LiveChannel],
        startingChannel: LiveChannel,
        startingStream: LiveStream,
        excluding attemptedIdentifiers: Set<String> = []
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

        let orderedChannels = Array(normalized[startingIndex...])
            + Array(normalized[..<startingIndex])
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
                      !attemptedIdentifiers.contains(candidate.identifier) else {
                    continue
                }
                values.append(candidate)
            }
        }
        return values
    }
}

enum LiveStreamProbeResult: Equatable, Sendable {
    case reachable
    case definitivelyUnavailable
    case inconclusive
}

enum LiveSourceValidationPolicy {
    static func result(forHTTPStatus statusCode: Int) -> LiveStreamProbeResult {
        switch statusCode {
        case 200...399:
            return .reachable
        case 400, 401, 403, 404, 410, 451:
            return .definitivelyUnavailable
        default:
            return .inconclusive
        }
    }

    static func shouldRemoveChannel(
        streamResults: [LiveStreamProbeResult]
    ) -> Bool {
        !streamResults.isEmpty
            && streamResults.allSatisfy { $0 == .definitivelyUnavailable }
    }
}

enum LiveSourceValidationStatus: Equatable {
    case checking(completed: Int, total: Int)
    case completed(removed: Int, total: Int)
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
        case .downloadingAndParsing: return "正在下载并解析…"
        case .parsing: return "正在解析配置…"
        case .startingNodeRuntime: return "正在启动 Node Runtime…"
        case .saving: return "正在保存配置…"
        case .activating: return "正在启用配置…"
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
        case .downloadingAndParsing: return "正在下载并解析…"
        case .parsing: return "正在解析直播源…"
        case .saving: return "正在保存直播源…"
        case .publishing: return "正在发布到直播列表…"
        }
    }
}

enum LiveSourceEPGStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

private actor LiveStreamAvailabilityProber {
    private let httpClient: URLSessionHTTPClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 7
        httpClient = URLSessionHTTPClient(configuration: configuration)
    }

    func result(for stream: LiveStream) async -> LiveStreamProbeResult {
        if stream.needsParsing {
            return .inconclusive
        }
        if stream.url.isFileURL {
            return FileManager.default.fileExists(atPath: stream.url.path)
                ? .reachable
                : .definitivelyUnavailable
        }
        guard ["http", "https"].contains(
            stream.url.scheme?.lowercased() ?? ""
        ) else {
            return .inconclusive
        }

        let first = await probeOnce(stream)
        guard first == .definitivelyUnavailable else { return first }
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return .inconclusive
        }
        let second = await probeOnce(stream)
        return second == .definitivelyUnavailable
            ? .definitivelyUnavailable
            : second == .reachable ? .reachable : .inconclusive
    }

    private func probeOnce(_ stream: LiveStream) async -> LiveStreamProbeResult {
        var headers = HTTPHeaders(stream.headers)
        headers["Range"] = "bytes=0-1023"
        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: stream.url,
                    headers: headers,
                    timeout: 6,
                    maximumResponseBytes: 256 * 1_024,
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
            )
            return LiveSourceValidationPolicy.result(
                forHTTPStatus: response.statusCode
            )
        } catch let error as HTTPClientError {
            if case .responseTooLarge = error {
                return .reachable
            }
            return .inconclusive
        } catch {
            return .inconclusive
        }
    }
}

private struct LivePlaybackNavigationContext {
    let sourceID: UUID
    let channels: [LiveChannel]
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
                    "该线路已载入，但 \(seconds) 秒内没有产生音视频"
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

@MainActor
final class AppState: ObservableObject {
    let navigation = AppNavigationState()
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
    @Published var selectedSettingsPane: SettingsPane = .general
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
    @Published private(set) var homeLoadErrorMessage: String?
    @Published private(set) var hasCompletedStartup = false
    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var selectedCategoryFilters: [String: String] = [:]
    @Published private(set) var categoryPage: VideoPage?
    @Published private(set) var homePresentationSelection:
        HomePresentationSelection = .empty
    /// Editable text shown by the global sidebar search field. This may differ
    /// from `activeSearchKeyword` until the user submits the field.
    @Published var searchDraftKeyword = ""
    /// The normalized keyword that owns the currently presented result set.
    /// Result metadata and retries must use this value, never the live draft.
    @Published private(set) var activeSearchKeyword = ""
    @Published private(set) var globalSearchFocusRequest: UInt64 = 0
    @Published private(set) var homeSearchReturnSection: AppSection?
    @Published private(set) var searchResults: [VideoSummary] = []
    @Published private(set) var searchClusters: [SearchResultCluster] = []
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
    @Published private(set) var loadedLivePlaylists: [UUID: LivePlaylist] = [:]
    @Published private(set) var loadedEPGGuides: [UUID: XMLTVGuide] = [:]
    private var loadedEPGScheduleIndexes: [UUID: XMLTVScheduleIndex] = [:]
    @Published private(set) var epgFailures: [UUID: String] = [:]
    @Published private(set) var liveSourceEPGStatuses:
        [UUID: LiveSourceEPGStatus] = [:]
    @Published private(set) var livePlaybackChannel: LiveChannel?
    @Published private(set) var livePlaybackStream: LiveStream?
    @Published private(set) var livePlaybackSourceID: UUID?
    @Published private(set) var isRecoveringLivePlayback = false
    @Published private(set) var hasExhaustedLivePlayback = false
    @Published private(set) var livePlaybackNotice: String?
    @Published private(set) var liveSourceValidationStatuses:
        [UUID: LiveSourceValidationStatus] = [:]
    @Published private(set) var selectedDetail: VideoDetail?
    @Published private(set) var pendingDetailSummary: VideoSummary?

    var isDetailPagePresented: Bool {
        selectedDetail != nil || pendingDetailSummary != nil
    }
    @Published private(set) var incognitoMode = false
    @Published private(set) var historyRetentionDays = 60
    @Published private(set) var appTheme: AppTheme = .system
    @Published private(set) var favoriteLiveChannelIDs: Set<String> = []
    @Published private(set) var deletedLiveChannelIDs: Set<String> = []
    let playerWindowPreferences = PlayerWindowPreferenceStore()
    let playerSnapshotState = PlayerSnapshotState()
    private(set) var playerSnapshot: PlayerSnapshot {
        get { playerSnapshotState.snapshot }
        set { playerSnapshotState.update(newValue) }
    }
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
    @Published private(set) var playbackResolutionState: PlaybackResolutionState = .idle
    @Published private(set) var currentPlaybackAttempt: PlaybackAttempt?
    @Published private(set) var playbackFailureSummary: String?
    @Published private(set) var playbackQualities: [PlaybackQuality] = []
    @Published private(set) var selectedPlaybackQualityID: String?
    @Published private(set) var isSwitchingPlaybackQuality = false
    @Published var isPlayerPresented = false
    @Published private(set) var isPlayerRenderSurfaceMountEnabled = false
    @Published private(set) var playerWindowCommand: PlayerWindowCommand?
    @Published private(set) var appWindowLayoutCommand: AppWindowLayoutCommand?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextCategoryPage = false
    @Published private(set) var categoryPaginationError: String?
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

    private let environment: AppEnvironment?
    private let playerRenderSurfaceGate = PlayerRenderSurfaceReadinessGate()
    private var configurationImportOperationID: UUID?
    private var configurationActivationTracker =
        ConfigurationActivationRequestTracker()
    private var configurationActivationTask: Task<Void, Never>?
    private var configurationPostActivationTask: Task<Void, Never>?
    private var configurationPostActivationSessionID = UUID()
    private var configurationSwitchFeedbackDismissTask: Task<Void, Never>?
    private var providers: [String: SiteProvider] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchSessionGate = SearchSessionGate()
    private var detailLoadSessionID = UUID()
    private var detailHomeSearchReturnSnapshot:
        DetailHomeSearchReturnSnapshot?
    private var homeLoadSessionID = UUID()
    private var homeContentIdentity: HomeContentIdentity?
    private var homeBrowsingSnapshots:
        [HomeContentIdentity: HomeBrowsingSnapshot] = [:]
    private var homeResumeTask: Task<Void, Never>?
    private var categoryLoadSessionID = UUID()
    private var configurationCategoryLoadSessionID = UUID()
    private var playerEventTask: Task<Void, Never>?
    private var activeSeekConfirmationID: UUID?
    private var cloudAuthorizationPollTask: Task<Void, Never>?
    private var nodeAuthorizationCompletionTask: Task<Void, Never>?
    private var nodeAuthorizationAutoRetryRequestID: UUID?
    private var cloudAuthorizationSessionID = UUID()
    private var lastCloudAuthorizationSurfaceCaptureAt: Date?
    private var configurationInteractionCoordinator =
        ConfigurationInteractionCoordinator()
    private var configurationInteractionTerminalTask: Task<Void, Never>?
    /// Serializes provider cancellation/restart cleanup across UI dismissal
    /// and a subsequent button click. A cleared sheet must not make its old
    /// DEX worker invisible to the next interaction.
    private var configurationInteractionCleanupTask: Task<Void, Never>?
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
    private var livePlaybackNoticeTask: Task<Void, Never>?
    private var liveSourceValidationTasks: [UUID: Task<Void, Never>] = [:]
    private var liveSourceEPGTasks: [UUID: Task<Void, Never>] = [:]
    private var playerEpisodePresentationCache: PlayerEpisodePresentationCache?
    private var playerEpisodePreparationTask: Task<Void, Never>?
    private var cloudAuthorizationContext: CloudAuthorizationContext?
    private var cloudAccountStatusStore = CloudAccountStatusStore()
    private var pendingNodeOperation: PendingNodeOperation?
    private var playbackSessionID = UUID()
    private var activePlayerRequestID = UUID()
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
    private var lastHistorySaveAt = Date.distantPast
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
    private var prefersPlayerSubtitlesEnabled = false
    private var preferredPlayerSubtitleTrack: PlayerSubtitleTrackPreference?
    private var lastAutomaticConfigurationRefreshAttemptAt: Date?
    private var configurationRefreshTask: Task<Bool, Never>?
    private var configurationRefreshSessionID = UUID()
    private var nodeRuntimeStatusTask: Task<Void, Never>?
    private var nodeProfileRevisionTask: Task<Void, Never>?
    private var observedNodeProfileRevision: NodeProfileRevisionSnapshot?
    private var activeNodeRuntimeEndpoint: URL?
    private var lastReadyNodeRuntimeEndpoint: URL?
    private var nodeRuntimeUnavailableReason = "Node Runtime 尚未启动"

    static func bootstrap() -> AppState {
        do {
            let environment = try AppEnvironment.live()
            let warning = environment.recoveredDatabaseDirectory.map {
                UserFacingError(
                    title: "已恢复数据库",
                    message: "损坏的数据库已保留在 \($0.path)，应用已创建新数据库。"
                )
            }
            return AppState(environment: environment, startupError: warning)
        } catch {
            return AppState(
                environment: nil,
                startupError: UserFacingError(
                    title: "无法初始化应用",
                    message: error.localizedDescription
                )
            )
        }
    }

    init(
        environment: AppEnvironment?,
        startupError: UserFacingError? = nil
    ) {
        self.environment = environment
        playerRenderClient = environment?.player.renderPlayer
        presentedError = startupError
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
            }
            await prepareActiveConfigurationHome(
                reportLoadErrors: false,
                entryReason: .applicationRestore
            )
        } catch {
            isHomeLoading = false
            show(error, title: "启动失败")
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

    func importConfigurationForSheet(
        source: ConfigurationSource,
        name: String?,
        progress: (ConfigurationImportPhase) -> Void = { _ in },
        onCommitStarted: () -> Void
    ) async -> ImportOperationResult {
        guard let environment else {
            return .failure(
                UserFacingError(
                    title: "配置导入失败",
                    message: "应用环境尚未初始化"
                )
            )
        }
        guard configurationImportOperationID == nil else {
            return .failure(
                UserFacingError(
                    title: "配置导入失败",
                    message: "已有配置正在导入，请稍候"
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
            configurations = committedConfigurations
            configurationRefreshSessionID = UUID()
            configurationRefreshTask?.cancel()
            configurationRefreshTask = nil
            lastAutomaticConfigurationRefreshAttemptAt = payload.loaded.loadedAt
            activeConfigurationRecord = record
            activeConfiguration = payload.loaded.configuration
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
                nodeRuntimeUnavailableReason = "Node Runtime 未用于当前配置"
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
                userFacingError(for: error, title: "配置导入失败")
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
                AppError.configuration("只有 URL 配置可以直接刷新"),
                title: "无法刷新"
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

    func importCatPawProfile(from fileURL: URL) async {
        guard let environment,
              let record = activeConfigurationRecord,
              let sourceURL = activeNodeRuntimeSourceURL else {
            show(
                AppError.configuration("请先启用一个 CatPawOpen Node 配置。"),
                title: "无法导入 CatPaw 配置"
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
                title: "CatPaw 配置已导入",
                message: "动态站点目录已按新 profile 重新加载，无需重启应用。"
            )
        } catch {
            show(error, title: "无法导入 CatPaw 配置")
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
                let changed = loaded.rawData != record.rawData
                    || loaded.baseURL != record.baseURL
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

                guard changed else { return false }
                self.homeLoadSessionID = UUID()
                self.categoryLoadSessionID = UUID()
                self.activeConfiguration = loaded.configuration
                self.rebuildProviders()
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
                self.selectedCategoryID = nil
                self.selectedCategoryFilters = [:]
                self.categoryPage = nil
                self.homePresentationSelection = .empty
                self.categoryPaginationError = nil
                return true
            } catch {
                if reportErrors {
                    self.show(error, title: "配置刷新失败")
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
        await task.value
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
            let presentation = userFacingError(for: error, title: "切换配置失败")
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
            throw AppError.configuration("应用环境尚未初始化")
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
                nodeRuntimeSourceURL: sourceURL
            )
        }
        return PreparedConfigurationActivation(
            record: record,
            configuration: try ConfigurationParser().parse(record.rawData),
            nodeRuntimeEndpoint: nil,
            nodeRuntimeSourceURL: nil
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
        homeLoadSessionID = UUID()
        categoryLoadSessionID = UUID()
        detailLoadSessionID = UUID()

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
        lastAutomaticConfigurationRefreshAttemptAt = activeRecord.updatedAt
        activeNodeRuntimeEndpoint = prepared.nodeRuntimeEndpoint
        nodeRuntimeUnavailableReason = prepared.usesNodeRuntime
            ? "Node Runtime 正在从本地缓存启动"
            : "Node Runtime 未用于当前配置"
        rebuildProviders()
        selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
            from: supportedSites
        )
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
        nodeRuntimeUnavailableReason = "Node Runtime 正在从本地缓存启动"
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
            nodeRuntimeUnavailableReason = "本地缓存不可用，正在后台刷新 Node bundle"
            rebuildProviders()
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
                nodeRuntimeUnavailableReason = error.localizedDescription
                rebuildProviders()
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
        let contentChanged = record.rawData != loaded.rawData
            || record.baseURL != loaded.baseURL
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
        rebuildProviders()
        if !supportedSites.contains(where: { $0.key == selectedSiteKey }) {
            selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                from: supportedSites
            )
        }
        await loadSearchSiteScope()
        guard isCurrentPostActivationWork(
            sessionID: sessionID,
            configurationID: recordID
        ) else {
            throw CancellationError()
        }
        if contentChanged || selectedSiteKey != previousSiteKey
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
        do {
            let protectedHistory = try await environment.database.history()
                .filter { $0.configurationID == id }
            try await environment.database.deleteConfiguration(id: id)
            removeCatPawReplayReferences(in: protectedHistory)
            if deletingActiveConfiguration {
                resetSearchForConfigurationChange()
            }
            configurations = try await environment.database.configurations()
            if activeConfigurationRecord?.id == id {
                activeConfigurationRecord = try await environment.database.activeConfiguration()
                selectedSiteKey = nil
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
            show(error, title: "删除配置失败")
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
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .recommendation
            homeLoadErrorMessage = nil
            captureHomeBrowsingSnapshotIfValid()
        case .loadCategory(let id):
            guard let category = home.categories.first(where: {
                $0.id == id && $0.resolvedContentKind == .media
            }) else { return }
            let filters: [String: String]
            if selectedCategoryID == id, !selectedCategoryFilters.isEmpty {
                filters = selectedCategoryFilters
            } else if snapshot?.categoryID == id,
                      let snapshotFilters = snapshot?.filters {
                filters = snapshotFilters
            } else {
                filters = HomePresentationPolicy.defaultFilters(for: category)
            }
            if await loadCategory(
                id: id,
                filters: filters,
                reportErrors: reportErrors
            ) {
                homeLoadErrorMessage = nil
                captureHomeBrowsingSnapshotIfValid()
            }
        case .showActions:
            categoryLoadSessionID = UUID()
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
        homeLoadSessionID = UUID()
        categoryLoadSessionID = UUID()
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        isHomeLoading = true
        homeLoadErrorMessage = nil
        selectedSiteKey = key
        discardHomeContentIfNeeded(for: currentHomeContentIdentity)
        selectedCategoryID = nil
        selectedCategoryFilters = [:]
        categoryPage = nil
        homePresentationSelection = .empty
        await restoreCachedSiteHome()
        await loadSelectedSiteHome()
        captureHomeBrowsingSnapshotIfValid()
    }

    @discardableResult
    func loadCategory(
        id: String,
        page: Int = 1,
        filters: [String: String] = [:],
        reportErrors: Bool = true
    ) async -> Bool {
        guard let key = selectedSiteKey,
              let provider = providers[key],
              let contentIdentity = currentHomeContentIdentity,
              siteHome?.categories.contains(where: {
                  $0.id == id && $0.resolvedContentKind == .media
              }) == true else {
            return false
        }
        let sessionID: UUID
        let loadingNextPage = page > 1
        let preservesCurrentPage = CategoryReloadPresentationPolicy
            .shouldPreserveCurrentPage(
                requestedPage: page,
                requestedCategoryID: id,
                currentCategoryID: selectedCategoryID,
                hasCurrentPage: categoryPage != nil
            )
        if loadingNextPage {
            guard !isLoadingNextCategoryPage,
                  selectedCategoryID == id,
                  categoryPage?.pagination.page == page - 1,
                  categoryPage?.pagination.hasMore == true else {
                return false
            }
            sessionID = categoryLoadSessionID
            isLoadingNextCategoryPage = true
            categoryPaginationError = nil
        } else {
            categoryLoadSessionID = UUID()
            sessionID = categoryLoadSessionID
            selectedCategoryID = id
            selectedCategoryFilters = filters
            if !preservesCurrentPage {
                categoryPage = nil
            }
            homePresentationSelection = .category(id)
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            isLoading = true
        }
        defer {
            if categoryLoadSessionID == sessionID {
                if loadingNextPage {
                    isLoadingNextCategoryPage = false
                } else {
                    isLoading = false
                }
            }
        }
        do {
            let loaded = try await provider.category(id: id, page: page, filters: filters)
            guard CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: sessionID,
                currentSessionID: categoryLoadSessionID,
                requestedSiteKey: key,
                currentSiteKey: selectedSiteKey,
                requestedIdentity: contentIdentity,
                currentIdentity: currentHomeContentIdentity
            ) else { return false }
            if page == 1,
               let home = siteHome,
               let promoted = HomePresentationPolicy
                .promotingSingletonEmptyCategoryToAction(
                    in: home,
                    categoryID: id,
                    page: loaded
                ) {
                publishHomeContent(promoted, identity: contentIdentity)
                if let publishedHome = siteHome {
                    await cacheSiteHome(
                        publishedHome,
                        identity: contentIdentity
                    )
                }
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
                    id: id,
                    filters: filters,
                    reportErrors: reportErrors
                )
            }
            selectedCategoryID = id
            categoryPage = VideoPageMerger.merge(
                current: page > 1 ? categoryPage : nil,
                loaded: loaded,
                requestedPage: page
            )
            categoryPaginationError = nil
            captureHomeBrowsingSnapshotIfValid()
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
            if !loadingNextPage {
                homeLoadErrorMessage = authorization.localizedDescription
            }
            presentNodeConfiguration(
                authorization,
                pending: .category(
                    identity: contentIdentity,
                    siteKey: key,
                    id: id,
                    page: page,
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
                if loadingNextPage {
                    categoryPaginationError = nil
                } else {
                    homeLoadErrorMessage = nil
                }
                return false
            }
            if loadingNextPage {
                categoryPaginationError = error.localizedDescription
            } else {
                homeLoadErrorMessage = error.localizedDescription
                if reportErrors {
                    show(error, title: "分类加载失败")
                }
            }
            return false
        }
    }

    func stageCategoryFilters(
        id: String,
        filters: [String: String]
    ) {
        guard selectedCategoryID == id else { return }
        // Supersede an in-flight category request immediately, before the
        // short UI debounce elapses. Providers that do not cooperate with
        // Task cancellation can then never publish an obsolete filter page.
        categoryLoadSessionID = UUID()
        isLoading = false
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        selectedCategoryFilters = filters
        captureHomeBrowsingSnapshotIfValid()
    }

    func clearCategory() {
        categoryLoadSessionID = UUID()
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
                AppError.site("配置页面已更新，请重新打开"),
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
                AppError.site("配置页面已更新，请重新打开"),
                title: "配置中心"
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
                ? "该配置分类没有返回可执行操作。"
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
                : error.localizedDescription
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
                    remarks: "打开配置功能",
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
            homeLoadErrorMessage = error.localizedDescription
            if reportErrors {
                show(error, title: "功能内容加载失败")
            }
            return false
        }
    }

    @discardableResult
    func loadSelectedSiteHome(
        refreshConfigurationIfNeeded: Bool = true,
        reportErrors: Bool = true
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
        homeLoadSessionID = UUID()
        let sessionID = homeLoadSessionID
        isHomeLoading = true
        defer {
            if homeLoadSessionID == sessionID {
                isHomeLoading = false
            }
        }
        do {
            let loaded = try await provider.home()
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
            publishHomeContent(loaded, identity: contentIdentity)
            homeLoadErrorMessage = nil
            await cacheSiteHome(loaded, identity: contentIdentity)
            if HomeSiteRolePolicy.isContentHome(loaded) {
                await persistSelectedSitePreference(key)
            }
            let didApplyPresentation = await applyHomePresentation(
                loaded,
                identity: contentIdentity,
                reportCategoryErrors: reportErrors
            )
            guard didApplyPresentation else { return false }
            captureHomeBrowsingSnapshotIfValid()
            return true
        } catch is CancellationError {
            guard homeLoadSessionID == sessionID else { return false }
            homeLoadErrorMessage = nil
            return false
        } catch {
            guard homeLoadSessionID == sessionID else { return false }
            let shouldPresent = UserVisibleAsyncErrorPolicy.shouldPresent(
                error,
                ownsSession: true
            )
            homeLoadErrorMessage = shouldPresent
                ? error.localizedDescription
                : nil
            if reportErrors && shouldPresent {
                show(error, title: "站点加载失败")
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
        await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
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

    func loadDetail(_ summary: VideoSummary) async {
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
            selectedDetail = nil
            pendingDetailSummary = nil
            presentHomeSearch()
            search(summary.title, context: .discoveryFallback)
            return
        }
        guard let provider = providers[summary.siteKey] else {
            show(
                AppError.site("来源 \(summary.siteKey) 在当前配置中不可用，记录仍会保留"),
                title: "来源不可用"
            )
            return
        }
        if summary.action?.nonEmpty != nil {
            await performHomeAction(SiteActionItem(summary: summary))
            return
        }
        detailHomeSearchReturnSnapshot =
            DetailHomeSearchReturnPolicy.capture(
                isHomeSearchPresented: isHomeSearchPresented,
                selectedSiteKey: selectedSearchSiteKey,
                folderPath: searchFolderPath,
                folderOrigin: searchFolderOrigin
            )
        let sessionID = UUID()
        detailLoadSessionID = sessionID
        selectedDetail = nil
        pendingDetailSummary = summary
        isLoading = true
        defer { isLoading = false }
        do {
            let selection = try await provider.select(summary: summary)
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            switch selection {
            case .detail(let detail):
                selectedDetail = detail
            case .search(let query):
                detailHomeSearchReturnSnapshot = nil
                selectedDetail = nil
                presentHomeSearch()
                search(query, context: .discoveryFallback)
            case .action(let result):
                detailHomeSearchReturnSnapshot = nil
                // Action-backed summaries are routed through
                // performHomeAction before detail loading. Reaching this
                // branch means the provider changed an ordinary detail into
                // an action without the host-owned interaction ID. Never
                // manufacture a completed configuration operation here.
                presentedError = UserFacingError(
                    title: summary.title,
                    message: Self.siteActionMessage(result)
                        ?? "站点返回了未关联到当前请求的配置操作，请返回后重试。"
                )
            }
        } catch let authorization as NodeWebAuthorizationRequired {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            guard let identity = activeSourceIdentity(
                for: summary.siteKey
            ) else {
                detailHomeSearchReturnSnapshot = nil
                show(
                    AppError.site("该详情所属配置已经发生变化"),
                    title: "详情加载失败"
                )
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
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            await presentCloudAuthorization(
                authorization.state,
                interaction: authorization.interaction,
                handle: authorization.handle,
                operation: .detail(summary),
                siteKey: summary.siteKey
            )
        } catch is CancellationError {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            detailHomeSearchReturnSnapshot = nil
        } catch {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            detailHomeSearchReturnSnapshot = nil
            show(error, title: "详情加载失败")
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
            detailLoadSessionID = UUID()
            selectedDetail = nil
            pendingDetailSummary = nil
            presentHomeSearch()
            // An index card is a user-initiated search and therefore observes
            // the user's configured search scope.
            search(summary.title, context: .manual)
        case .detail:
            await loadDetail(summary)
        }
    }

    func performHomeAction(_ item: SiteActionItem) async {
        guard let provider = providers[item.siteKey] else {
            show(
                AppError.site("该功能所属站点当前不可用"),
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
                tag: item.tag
            )
            return
        case .providerSelection:
            break
        }
        let actionStatusGeneration = beginSiteActionStatusSession()
        let operation = PendingCloudOperation.homeAction(item)
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
            guard siteActionStatusGeneration == actionStatusGeneration else {
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
            switch selection {
            case .detail:
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    failConfigurationInteraction(
                        interactionID,
                        message: "站点把配置入口返回成了影视详情，操作未执行。"
                    )
                } else {
                    presentedError = UserFacingError(
                        title: item.title,
                        message: "该入口是功能操作，未作为影视详情打开。"
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
                        Self.siteActionMessage(result),
                        title: item.title,
                        generation: actionStatusGeneration
                    )
                    completeConfigurationInteraction(
                        interactionID,
                        status: "配置操作已完成"
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
                    AppError.site("该功能所属配置已经发生变化"),
                    title: item.title
                )
                return
            }
            presentNodeConfiguration(
                authorization,
                pending: .homeAction(identity: identity, item: item)
            )
        } catch let authorization as AndroidBridgeUIRequired {
            guard siteActionStatusGeneration == actionStatusGeneration else {
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
                    message: error.localizedDescription
                )
            } else {
                show(error, title: "\(item.title)失败")
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
        if summary.isFolder {
            openSearchFolder(
                summary,
                replacingPath: false,
                origin: nil
            )
        } else {
            Task { await loadDetail(summary) }
        }
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
            returnFromSearchToOrigin()
        } else {
            navigateBackSearchFolder()
        }
    }

    var homeSearchBackTitle: String {
        if searchFolderPath.isEmpty {
            return "返回\((homeSearchReturnSection ?? .home).rawValue)"
        }
        return SearchFolderNavigationPolicy.backTitle(
            pathCount: searchFolderPath.count,
            origin: searchFolderOrigin
        )
    }

    var homeSearchBackHelp: String {
        if searchFolderPath.isEmpty {
            return "关闭搜索并返回\((homeSearchReturnSection ?? .home).rawValue)"
        }
        return SearchFolderNavigationPolicy.backHelp(
            pathCount: searchFolderPath.count,
            origin: searchFolderOrigin
        )
    }

    func retryCurrentSearchFolder() {
        guard let current = searchFolderPath.last else { return }
        updateSearchFolder(id: current.id) { page in
            page.items = []
            page.pagination = nil
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
        guard let current = searchFolderPath.last,
              !current.isLoading,
              let pagination = current.pagination,
              pagination.hasMore else {
            return
        }
        updateSearchFolder(id: current.id) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        Task {
            await loadSearchFolder(
                id: current.id,
                summary: current.folder,
                page: pagination.page + 1
            )
        }
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
        _ action: String,
        title: String,
        provider: SiteProvider,
        tag: String? = nil
    ) async {
        let actionStatusGeneration = beginSiteActionStatusSession()
        let effectiveTag: String? = tag?.nonEmpty ?? {
            guard MyDriveGuardActionContract.supportsAccountAuthorization(
                api: provider.site.api
            ) else { return nil }
            return MyDriveGuardActionContract.tag(for: action)
        }()
        let interactionKind = AndroidDexSpiderSiteProvider
            .interactionActionKind(tag: effectiveTag)
        let presentsProviderUI = interactionKind != .command
            && interactionKind != .immediate
        let operation = PendingCloudOperation.siteAction(
            action: action,
            title: title,
            tag: effectiveTag
        )
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
            guard siteActionStatusGeneration == actionStatusGeneration else {
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
            || !presentsProviderUI
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
                    interactionKind: interactionKind
                )
            } else {
                result = try await provider.action(action)
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
                    Self.siteActionMessage(result),
                    title: title,
                    generation: actionStatusGeneration
                )
                completeConfigurationInteraction(
                    interactionID,
                    status: "配置操作已完成"
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
        } catch let authorization as NodeWebAuthorizationRequired {
            guard let identity = activeSourceIdentity(
                for: provider.site.key
            ) else {
                show(
                    AppError.site("该功能所属配置已经发生变化"),
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
            guard siteActionStatusGeneration == actionStatusGeneration else {
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
                    message: error.localizedDescription
                )
            } else {
                show(error, title: "\(title)失败")
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
            return selectedDetail != nil || pendingDetailSummary != nil
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
                AppError.site("该配置操作所属配置已经发生变化"),
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
            lastObservedRevision: nil
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
                ? "正在执行配置操作…"
                : "正在等待站点创建下一步操作界面…",
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
            try? await bridge.resetAuthorizationUI()
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
        ), var prompt = cloudAuthorizationPrompt,
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
        if phase.isTerminal {
            cloudAuthorizationSurfaceFrame = nil
            lastCloudAuthorizationSurfaceCaptureAt = nil
        }
        cloudAuthorizationPrompt = prompt
    }

    private func completeConfigurationInteraction(
        _ interactionID: UUID,
        status: String = "配置操作已完成"
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
        transitionConfigurationInteraction(
            interactionID,
            to: .failed,
            status: message,
            allowsRetry: true
        )
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
                    message: error.localizedDescription
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
                    ?? "站点没有完成该配置操作，请重试。"
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
                status: "站点仍在处理该配置操作…"
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
                    status: "站点已返回结果，正在完成当前配置操作…"
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
                        ?? "站点没有完成该配置操作，请重试。"
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
        pending: PendingNodeOperation
    ) {
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
            status = authorization.requestID == nil
                ? "等待配置保存；旧版 Spider 保存后只会自动验证一次。"
                : "等待与当前播放请求匹配的授权完成信号。"
        } else {
            status = "配置页会保持打开；保存后可手动应用并重试原操作。"
        }
        nodeWebPresentation = NodeWebPresentation(
            id: UUID(),
            challengeID: authorization.challengeID,
            requestID: authorization.requestID,
            sourceIdentity: pending.sourceIdentity,
            runtimeWebsiteLocation: websiteLocation,
            url: currentWebsiteURL,
            title: authorization.title.nonEmpty ?? "网盘配置中心",
            message: authorization.message,
            provider: authorization.provider,
            transport: authorization.transport,
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
                ? "本次播放已经自动验证过一次；为避免重复转存，请确认后手动重试。"
                : status,
            allowsAutomaticRetry: allowsAutomaticRetry,
            hasAttemptedProfileRevisionVerification: false,
            revision: 0
        )
        let challengeID = authorization.challengeID
        guard allowsAutomaticRetry,
              let requestID = authorization.requestID else {
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
                    presentation?.status = "已收到授权完成信号；为避免重复执行网盘操作，请手动重试。"
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
                presentation.status = "自动续播已执行过一次，请确认授权状态后手动重试。"
                presentation.allowsAutomaticRetry = false
                nodeWebPresentation = presentation
                return
            }
            nodeAuthorizationAutoRetryRequestID = requestID
        }
        presentation.lifecycleState = .verifying
        presentation.status = automatically
            ? "已检测到授权完成，正在恢复当前播放…"
            : "正在刷新授权状态并重新解析当前内容…"
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
                windowActivation: .preserveFocus
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
                windowActivation: .preserveFocus
            )
        } catch let authorization as NodeWebAuthorizationRequired {
            guard pendingNodeOperation?.sourceIdentity == pending.sourceIdentity,
                  nodeWebPresentation?.challengeID == presentation.challengeID else {
                return
            }
            presentNodeConfiguration(authorization, pending: pending)
            if var replacement = nodeWebPresentation {
                replacement.status = "授权验证尚未通过，配置页将保持打开，请完成授权后再试。"
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
            current.status = "授权验证未通过：\(LogRedactor.text(error.localizedDescription))"
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
            let message = "已取消网盘授权"
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
        }
        // A scoped handle owns its Android interaction and was cancelled
        // above. Resetting the process-global legacy UI as well could erase a
        // newer request that has already superseded this one.
        guard resetBridgeUI, providerHandle == nil else { return }
        Task {
            try? await androidDexBridge?.resetAuthorizationUI()
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
        return kind == .authorization ? "网盘授权" : "配置操作"
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
                message: error.localizedDescription
            )
        }
    }

    func confirmCloudAuthorizationCompletion() async {
        guard let context = cloudAuthorizationContext,
              context.operation.pendingPlayback == nil,
              isCurrentCloudAuthorizationContext(context),
              var prompt = cloudAuthorizationPrompt,
              prompt.interactionID == context.operationID,
              prompt.allowsCompletionConfirmation,
              !prompt.lifecyclePhase.isTerminal else {
            return
        }
        prompt.lifecyclePhase = .submitting
        prompt.status = "正在确认操作结果并刷新配置…"
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
                message: error.localizedDescription
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
                show(AppError.site("该功能所属站点当前不可用"), title: title)
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
        let stateInteractionID = state.interactionID.flatMap(UUID.init(uuidString:))
        let scopedIdentifiers = [handle?.id, interaction?.id, stateInteractionID]
            .compactMap { $0 }
        guard Set(scopedIdentifiers).count <= 1 else {
            handle?.cancel()
            if let activeID = cloudAuthorizationContext?.operationID {
                failConfigurationInteraction(
                    activeID,
                    message: "站点返回的配置请求标识不一致，请重试。"
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
                    message: "配置界面来源与当前操作不匹配，请重试。"
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
                status: "正在等待站点创建下一步操作界面…"
            )
        } else {
            await supersedeConfigurationInteractionIfNeeded()
            guard beginConfigurationInteraction(
                title: "配置操作",
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
                message: "站点返回的配置界面不属于当前操作，请重试。"
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
                ? "请在 Android 原生界面中完成操作，完成后点击“完成并刷新”。"
                : "请在 Android 原生界面中完成操作"
        } else {
            status = "正在等待站点创建 Android 操作界面…"
        }
        let updated = CloudAuthorizationPrompt(
            id: previous?.id ?? UUID(),
            interactionID: operationID,
            requestGeneration: context.requestGeneration,
            title: configurationInteractionCoordinator.current?.request.title
                ?? (interactionKind == .authorization ? "网盘授权" : "配置操作"),
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
                context.operation.pendingPlayback == nil
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
                            "配置状态已被另一个操作替换"
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
                            ? "站点方法已返回；确认 Android 操作完成后，请点击“完成并刷新”。"
                            : "Android 操作界面暂时不可见，正在等待站点处理…"
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
                            message: "本机配置桥连续无法响应，请重试该操作。"
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
        let hasProviderResult = providerResult.map { $0 != .null } == true
        if case .playback = context.operation,
           context.providerHandle != nil,
           !hasProviderResult {
            // A scoped playerContent worker is the sole owner of this media
            // result. A successful UI transition without that result is not
            // permission to issue playerContent again under a second request.
            failConfigurationInteraction(
                context.operationID,
                message: "授权流程已结束，但原播放请求没有返回媒体，请重试播放。"
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
                    message: "播放结果所属 provider 已发生变化，请重试。"
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
                    message: error.localizedDescription
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
                providerResult.flatMap(Self.siteActionMessage),
                title: configurationInteractionCoordinator.current?
                    .request.title ?? "配置操作",
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
            completionStatus = "授权成功，正在继续播放…"
        } else {
            switch completionSemantic {
            case .order:
                completionStatus = "排序已更新"
            case .toggle:
                completionStatus = "设置已更新"
            default:
                completionStatus = "配置操作已完成"
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
            if summary.resolvedContentKind == .action,
               selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
            } else {
                await loadDetail(summary)
            }
        case .homeAction:
            if selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
            }
        case .siteAction:
            if selectedSection == .home,
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

    func openFavorite(_ favorite: FavoriteRecord) async {
        let siteName = visibleSites.first { $0.key == favorite.siteKey }?.name
            ?? favorite.siteKey
        await loadDetail(
            VideoSummary(
                siteKey: favorite.siteKey,
                siteName: siteName,
                videoID: favorite.videoID,
                title: favorite.title,
                posterURL: favorite.posterURL
            )
        )
    }

    /// Handles the UI event synchronously so the native player window command
    /// is issued before configuration switching, provider I/O, or even the
    /// first suspension point of history restoration.
    func requestHistoryPlayback(_ item: HistoryRecord) {
        guard !isShutdownRequested else { return }
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
            "没有选择要恢复的线路和分集",
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
        var recoveryFailure = "缺少稳定网盘文件标识"
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
                    "无法切换到这条历史记录所属的点播配置",
                    preparationID: preparationID
                )
                return
            }
        case .unavailable:
            failHistoryPlayback(
                "这条历史记录所属的点播配置已被删除，无法安全恢复原来源",
                preparationID: preparationID
            )
            return
        case .legacy:
            failHistoryPlayback(
                "这是一条没有配置身份的旧版历史记录，无法安全判断原来源",
                preparationID: preparationID
            )
            return
        }
        let siteName = visibleSites.first { $0.key == item.siteKey }?.name
            ?? item.siteKey
        guard let owningConfigurationID = item.configurationID
            ?? activeConfigurationRecord?.id else {
            failHistoryPlayback(
                "无法确定这条历史记录所属的点播配置",
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
                "来源 \(siteName) 在当前配置中不可用，无法恢复播放",
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
            if let nodeProvider = provider as? NodeHTTPSpiderSiteProvider,
               NodePlaybackReplayReference.isCurrentLocator(
                   acceptedProviderReference.stableResourceLocator
               ) {
                // A CatPaw nhr2 record is a replay recipe, not an episode URL.
                // Restore it through current detail -> original flag -> exact
                // episode -> play before constructing ActivePlayback, so the
                // context retains every current episode for automatic advance.
                let refreshRequest = PlaybackRefreshRequest(
                    videoID: item.videoID,
                    title: item.title,
                    sourceIdentity: acceptedProviderReference.sourceIdentity,
                    resourceIdentity:
                        acceptedProviderReference.episodeIdentity,
                    sourceName: item.sourceName,
                    episodeName: item.episodeName,
                    episodeReference:
                        acceptedProviderReference.stableResourceLocator,
                    providerResourceReference: acceptedProviderReference
                )
                do {
                    let refreshed = try await nodeProvider.refreshPlayback(
                        refreshRequest,
                        transferContext: transferPlaybackContext(
                            for: preparationID
                        )
                    )
                    guard isCurrentHistoryPreparation(preparationID) else {
                        if let receipt = refreshed.playbackResult.transferReceipt {
                            await cleanupTransferReceipt(
                                receipt,
                                reason: .staleGeneration
                            )
                        }
                        return
                    }
                    await startPlayback(
                        detail: refreshed.detail,
                        source: refreshed.source,
                        episode: refreshed.episode,
                        origin: .history(item),
                        authoritativePlaybackResult:
                            refreshed.playbackResult,
                        configurationID: owningConfigurationID,
                        continuingRequestID: preparationID,
                        windowActivation: .preserveFocus
                    )
                    if let receipt = refreshed.playbackResult.transferReceipt,
                       activePlayback?.playbackResult?.transferReceipt?
                        .receiptID != receipt.receiptID {
                        await cleanupTransferReceipt(
                            receipt,
                            reason: .resolutionFailed
                        )
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // Preserve the existing authorization and recovery path.
                    // startPlayback will retry this same provider reference
                    // and present any provider-owned authorization UI.
                }
            }
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
            // Current CatPaw records arrive above through their protected
            // provider reference; legacy rows continue directly to title
            // recovery instead of issuing a guaranteed-invalid detail call.
            recoveryFailure = "旧详情身份仅可用于历史去重"
        } else {
            do {
                let detail = try await provider.detail(id: storedDetailID)
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
                recoveryFailure = "最新详情中未找到原线路或原分集"
            } catch {
                // Search/cloud providers often expose session-scoped video
                // IDs. Continue with the durable episode reference or cached
                // media instead of surfacing a low-level empty-JSON error.
                recoveryFailure = "旧详情 ID 已失效"
            }
        }

        let persistedEpisodeReference = provider.capability == .javaDexSpider
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
                guard let detail = try? await provider.detail(
                    id: summary.videoID
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
                recoveryFailure = "找到多个同名结果，但没有唯一匹配原线路和分集"
            } else if candidates.isEmpty {
                recoveryFailure += "，重新搜索也没有找到同名内容"
            } else {
                recoveryFailure = "已找到同名内容，但未匹配到原线路或原分集"
            }
        } catch {
            // A search retry is best effort. Present one actionable history
            // message below instead of a second provider decoding error.
            recoveryFailure += "；重新搜索失败"
        }

        guard isCurrentHistoryPreparation(preparationID) else { return }
        failHistoryPlayback(
            "\(recoveryFailure)，请重新选择。",
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
        playbackFailureSummary = "找到多个可能的原线路或分集，请选择一次；成功后会自动修复这条历史记录。"
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
              replay.detail.summary.siteKey == item.siteKey else {
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
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            isPlayerRenderSurfaceMountEnabled = true
            await environment.player.stop()
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            // A provider-owned media session is already the authoritative
            // request contract. Loading it directly avoids a redundant
            // detail/player invocation whose only observable result may be a
            // stale authorization dialog.
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
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
            guard isCurrentHistoryPreparation(owningPreparationID),
                  playbackSessionID == sessionID else { return false }
            isPlayerRenderSurfaceMountEnabled = true
            await environment.player.stop()
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
        let preparationID = requestID
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

    func dismissDetail() {
        let searchReturnSnapshot = detailHomeSearchReturnSnapshot
        detailHomeSearchReturnSnapshot = nil
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
        if let searchReturnSnapshot {
            selectedSection = .home
            selectedSearchSiteKey = searchReturnSnapshot.selectedSiteKey
            searchFolderPath = searchReturnSnapshot.folderPath
            searchFolderOrigin = searchReturnSnapshot.folderOrigin
            isHomeSearchPresented = true
        }
    }

    func search(_ keyword: String) {
        search(keyword, context: .manual)
    }

    private func search(
        _ keyword: String,
        context: SearchLaunchContext
    ) {
        if isSearching {
            previousSearchTermination = .supersededByNewSearch
        }
        searchTask?.cancel()
        let sessionID = searchSessionGate.begin()
        searchResults = []
        searchClusters = []
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
        sessionID: UUID
    ) async {
        let selectedKeys = SearchProviderSelectionPolicy.effectiveSiteKeys(
            context: context,
            scope: searchSiteScope,
            options: searchScopeSiteOptions
        )
        if context == .manual,
           searchSiteScope.mode == .custom,
           selectedKeys.isEmpty {
            show(
                AppError.configuration("当前自定义搜索范围没有可用站点，请重新选择。"),
                title: "搜索范围不可用"
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
        let searchableProviders: [SiteProvider] = searchCatalogSites.compactMap { site in
            guard selectedKeys.contains(site.key) else { return nil }
            return providers[site.key]
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
            providerPolicies: aggregatePolicies
        )
        var firstPageCompletedSiteKeys = Set<String>()
        var completedSiteKeys = Set<String>()
        var pendingSnapshot: MultiSiteSearchSnapshot?
        var lastSnapshotRefresh = Date.distantPast

        let applySnapshot: (MultiSiteSearchSnapshot) -> Void = { [weak self] snapshot in
            guard let self,
                  self.searchSessionGate.accepts(sessionID) else { return }
            // MultiSiteSearch is the semantic owner of relevance, retention,
            // eviction and per-site diversity. AppState only publishes its
            // authoritative retained snapshot.
            self.searchResults = snapshot.items
            self.searchClusters = SearchResultAggregator.cluster(snapshot.items)
            self.searchReceivedCandidateCount = snapshot.receivedCandidateCount
            self.searchMaximumRetainedCandidates = snapshot.maximumRetainedCandidates
            self.searchMaximumResultsPerSite = snapshot.maximumResultsPerSite
            self.searchDidDiscardCandidates = snapshot.didDiscardCandidates
        }

        for await event in stream {
            guard searchSessionGate.accepts(sessionID) else { return }
            switch event {
            case .snapshot(let snapshot):
                pendingSnapshot = snapshot
                let now = Date()
                if now.timeIntervalSince(lastSnapshotRefresh) >= 0.12 {
                    applySnapshot(snapshot)
                    pendingSnapshot = nil
                    lastSnapshotRefresh = now
                }
            case .failure(let failure):
                searchFailures.append(failure)
            case .siteOutcome(let outcome):
                searchSiteOutcomes[outcome.siteKey] = outcome
            case .siteFirstPageCompleted(let siteKey):
                if firstPageCompletedSiteKeys.insert(siteKey).inserted {
                    searchFirstPageCompletedSiteCount = firstPageCompletedSiteKeys.count
                }
            case .siteCompleted(let siteKey):
                if completedSiteKeys.insert(siteKey).inserted {
                    searchCompletedSiteCount = completedSiteKeys.count
                }
            case .finished(let termination):
                if let pendingSnapshot {
                    applySnapshot(pendingSnapshot)
                }
                searchTermination = termination
                isSearching = false
            }
        }
        if searchSessionGate.accepts(sessionID) {
            if let pendingSnapshot {
                applySnapshot(pendingSnapshot)
            }
            isSearching = false
            searchTask = nil
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
        let returnSection = isHomeSearchPresented
            ? (homeSearchReturnSection ?? .home)
            : selectedSection
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
        if isDetailPagePresented {
            dismissDetail()
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
              selectedDetail == nil,
              pendingDetailSummary == nil else { return }
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
              selectedDetail == nil,
              pendingDetailSummary == nil else { return }
        isQuickSwitcherPresented = false
        isShortcutHelpPresented = true
    }

    func dismissShortcutHelp() {
        isShortcutHelpPresented = false
    }

    func requestLiveSourceSelection(_ sourceID: UUID) {
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
    func performBrowserEscapeShortcut() -> Bool {
        guard allowsBrowserShortcuts else { return false }
        let action = BrowserEscapeRoutePolicy.action(
            isHomeSearchPresented: isHomeSearchPresented,
            isSearching: isSearching,
            hasSearchFolder: !searchFolderPath.isEmpty,
            hasDetailPresentation: selectedDetail != nil
                || pendingDetailSummary != nil,
            hasBlockingPresentation: mainWindowCloudAuthorizationPrompt != nil
                || nodeWebPresentation != nil
                || isQuickSwitcherPresented
                || isShortcutHelpPresented
        )
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
        switch selectedSection {
        case .home:
            if isHomeSearchPresented {
                search(activeSearchKeyword)
            } else {
                await refreshHome()
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
        } else if selectedDetail != nil || pendingDetailSummary != nil {
            dismissDetail()
        } else if !searchFolderPath.isEmpty {
            navigateBackHomeSearch()
        } else if isHomeSearchPresented {
            navigateBackHomeSearch()
        } else if selectedSection != .home {
            selectSection(.home)
        }
    }

    func stopCurrentShortcutOperation() {
        guard allowsBrowserShortcuts else { return }
        if isSearching {
            cancelSearch()
        }
    }

    func cancelSearch() {
        if isSearching {
            searchTermination = .cancelled
        }
        searchSessionGate.invalidate()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func saveSearchSiteScope(_ scope: SearchSiteScope) async -> Bool {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id else {
            show(
                AppError.configuration("请先导入并启用一个点播配置。"),
                title: "无法保存搜索范围"
            )
            return false
        }
        let effectiveKeys = SearchSiteScopePolicy.effectiveSiteKeys(
            scope: scope,
            options: searchScopeSiteOptions
        )
        if scope.mode == .custom, effectiveKeys.isEmpty {
            show(
                AppError.configuration("自定义搜索范围至少需要一个当前可用站点。"),
                title: "无法保存搜索范围"
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
            show(error, title: "无法保存搜索范围")
            return false
        }
    }

    func selectSearchSite(_ key: String?) {
        selectedSearchSiteKey = key
    }

    var searchSiteOptions: [SearchSiteOption] {
        let grouped = Dictionary(grouping: searchResults, by: \.siteKey)
        var options: [SearchSiteOption] = []
        var included = Set<String>()

        for site in visibleSites {
            guard let items = grouped[site.key], !items.isEmpty else { continue }
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
                ? "范围：全部 \(total)"
                : "范围：已启用 \(selected)/\(total)"
        case .custom:
            return "范围：已选 \(selected)/\(total)"
        }
    }

    var searchRuntimeProfileNotice: String? {
        guard activeConfigurationUsesNodeRuntime,
              !NodeDynamicSiteCatalogPolicy.containsConfiguredProvider(
                in: searchCatalogSites
              ) else {
            return nil
        }
        return "当前 CatPaw 资源未提供可验证的默认配置，"
            + "依赖账号或挂载的动态站点可能不会出现。"
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

    func toggleFavorite(_ detail: VideoDetail) async {
        guard let environment else { return }
        let summary = detail.summary
        do {
            if favorites.contains(where: { $0.id == summary.id }) {
                try await environment.database.deleteFavorite(
                    siteKey: summary.siteKey,
                    videoID: summary.videoID
                )
            } else {
                try await environment.database.saveFavorite(
                    FavoriteRecord(
                        siteKey: summary.siteKey,
                        videoID: summary.videoID,
                        title: summary.title,
                        posterURL: summary.posterURL,
                        synopsis: detail.synopsis
                    )
                )
            }
            favorites = try await environment.database.favorites()
        } catch {
            show(error, title: "收藏操作失败")
        }
    }

    func deleteFavorites(ids: Set<FavoriteRecord.ID>) async {
        guard let environment, !ids.isEmpty else { return }
        do {
            for favorite in favorites where ids.contains(favorite.id) {
                try await environment.database.deleteFavorite(
                    siteKey: favorite.siteKey,
                    videoID: favorite.videoID
                )
            }
            favorites = try await environment.database.favorites()
        } catch {
            show(error, title: "删除收藏失败")
        }
    }

    func clearFavorites() async {
        guard let environment else { return }
        do {
            _ = try await environment.database.deleteAllFavorites()
            favorites = try await environment.database.favorites()
        } catch {
            show(error, title: "清空收藏失败")
        }
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
        windowActivation: PlayerWindowActivationPolicy = .userInitiated
    ) async {
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
                AppError.playback("播放所属配置已经切换，请切回原配置后重试"),
                title: "播放已停止"
            )
            return
        }
        if continuingRequestID == nil {
            playbackAuthorizationResumeGate.resetForNewPlayback()
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
            if authorizationRetry {
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
        playbackSessionID = sessionID
        activePlayerRequestID = sessionID
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
            origin: origin
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
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
        playbackResolutionState = .resolving
        playerPresentedError = nil
        currentPlaybackAttempt = PlaybackAttempt(
            siteName: detail.summary.siteName,
            sourceName: source.name,
            episodeName: episode.name,
            parserName: nil,
            redactedURL: "<正在获取播放地址>",
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
        let migratesLegacyCatPawHistory = CatPawHistoryMigrationPolicy
            .shouldCaptureRecoveredIdentity(
                isHistory: origin.isHistory,
                isAuthorizationRetry: authorizationRetry,
                isNodeProvider: provider is NodeHTTPSpiderSiteProvider,
                hasAcceptedProviderReference:
                    Self.acceptedHistoryProviderReference(
                        from: origin.historyRecord,
                        provider: provider
                    ) != nil,
                detailID: detail.summary.videoID
            )
        if !origin.isHistory || migratesLegacyCatPawHistory {
            // A legacy CatPaw row may reach this point only after its exact
            // detail/line/episode was recovered. Capture that current raw
            // provider identity now so the next launch uses nhr2 directly
            // instead of repeating title search. Other provider histories
            // retain their existing navigation behavior.
            await persistHistoryNavigationSelection(
                detail: detail,
                source: source,
                episode: episode,
                configurationID: playbackConfigurationID
            )
        }
        do {
            try await environment.player.prepareForPlayback(
                requestID: sessionID
            )
        } catch {
            PlayerStartupTraceStore.shared.cancel(requestID: sessionID)
            guard playbackSessionID == sessionID else { return }
            show(error, title: "播放器初始化失败")
            return
        }
        guard playbackSessionID == sessionID else { return }
        isPlayerRenderSurfaceMountEnabled = true
        // A transferred cloud file remains leased while its replacement is
        // resolved. MPV's later loadfile/replace event, not the click, proves
        // that the old media has been released.
        if transferMediaLeases.isEmpty {
            await environment.player.stop()
        }
        guard playbackSessionID == sessionID else { return }

        var unresolvedTransferReceipts: [UUID: TransferReceipt] = [:]
        do {
            guard detail.playSources.contains(where: { $0.id == source.id }) else {
                throw AppError.playback("当前线路不在详情数据中")
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
                && currentProviderReference != nil
            let refreshAttempts = refreshFirst
                ? [true, false]
                : [false, true]

            for (targetIndex, isRefreshAttempt) in refreshAttempts.enumerated() {
                try Task.checkCancellation()
                guard playbackSessionID == sessionID else {
                    throw CancellationError()
                }

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
                            videoID: historyRecord?.videoID
                                ?? detail.summary.videoID,
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
                        failures.append("重新获取播放详情失败：\(error.localizedDescription)")
                        playbackFailureSummary = error.localizedDescription
                        continue
                    }
                }

                currentPlaybackAttempt = PlaybackAttempt(
                    siteName: candidateDetail.summary.siteName,
                    sourceName: candidateSource.name,
                    episodeName: candidateEpisode.name,
                    parserName: nil,
                    redactedURL: "<正在获取播放地址>",
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
                        playbackFailureSummary = "播放所属配置已经发生变化"
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
                    failures.append(
                        "\(candidateSource.name)：\(error.localizedDescription)"
                    )
                    playbackFailureSummary = error.localizedDescription
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
                    failures.append("\(candidateSource.name)：重新解析仍返回相同地址和请求上下文")
                    playbackFailureSummary = "重新解析仍返回相同地址和请求上下文"
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
                    result: result
                )
                let providerReferenceForAttempt = currentProviderReference
                let remainingAttempts = max(1, 8 - completedAttempts)
                var attemptsInCandidate = 0
                var candidateFailure: String?
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
                        playbackFailureSummary = Self.playbackFailureMessage(
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
                        candidateFailure = Self.playbackFailureMessage(
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
                if completedAttempts >= 8 {
                    break
                }
            }

            let message = Self.consolidatedPlaybackFailureMessage(failures)
            playbackResolutionState = .exhausted
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
            presentPlaybackErrorOnce(message, requestID: sessionID)
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
            let message = error.localizedDescription
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
            presentPlaybackErrorOnce(message, requestID: sessionID)
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
                    notBefore: notBefore
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
        let message = LogRedactor.text(error.localizedDescription)
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
        presentPlaybackErrorOnce(message, requestID: requestID)
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
                ? "已完成一次同资源刷新；"
                : ""
            return "媒体请求被拒绝，网盘授权或临时播放地址可能已失效。\(refreshStatus)请重新授权后再试。"
        }
        return message
    }

    static func consolidatedPlaybackFailureMessage(
        _ failures: [String]
    ) -> String {
        let proxyFailure = "Android 内部媒体代理未正确转发"
        let normalized = failures.compactMap { failure -> String? in
            let value = failure.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if normalized.contains(where: { $0.contains(proxyFailure) }) {
            return proxyFailure
        }
        var seen = Set<String>()
        let unique = normalized.filter { seen.insert($0).inserted }
        return unique.suffix(4).joined(separator: "；")
            .nonEmpty ?? "所有线路都无法返回可播放媒体"
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
            try await environment.database.saveLiveSource(record)
            try Task.checkCancellation()
            progress(.publishing)
            liveSources = try await environment.database.liveSources()
            try Task.checkCancellation()
            loadedLivePlaylists[record.id] = loaded.playlist
            startLiveSourceBackgroundWork(for: record, playlist: loaded.playlist)
            return true
        } catch is CancellationError {
            return false
        } catch {
            show(error, title: "直播源加载失败")
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
                loadedLivePlaylists[record.id] = playlist
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

    func loadLiveSource(_ source: StoredLiveSource) async {
        guard environment != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let playlist = try LiveSourceParser().parse(
                source.rawData,
                baseURL: source.baseURL
            )
            loadedLivePlaylists[source.id] = playlist
            startLiveSourceBackgroundWork(for: source, playlist: playlist)
        } catch {
            show(error, title: "直播源加载失败")
        }
    }

    func refreshLiveSource(_ id: UUID) async {
        guard let environment,
              let existing = liveSources.first(where: { $0.id == id }) else {
            return
        }
        guard existing.sourceKind == .remote,
              let value = existing.sourceValue,
              let url = URL(string: value) else {
            show(
                AppError.live("只有 URL 直播源可以直接刷新"),
                title: "无法刷新"
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await environment.liveSourceLoader.load(.remote(url))
            let updated = StoredLiveSource(
                id: existing.id,
                name: existing.name,
                sourceKind: .remote,
                sourceValue: value,
                baseURL: loaded.baseURL,
                rawData: loaded.rawData,
                updatedAt: loaded.loadedAt
            )
            try await environment.database.saveLiveSource(updated)
            liveSources = try await environment.database.liveSources()
            loadedLivePlaylists[id] = loaded.playlist
            loadedEPGGuides[id] = nil
            loadedEPGScheduleIndexes[id] = nil
            epgFailures[id] = nil
            startLiveSourceBackgroundWork(for: updated, playlist: loaded.playlist)
        } catch {
            show(error, title: "直播源刷新失败")
        }
    }

    func deleteLiveSource(_ id: UUID) async {
        guard let environment else { return }
        liveSourceValidationTasks[id]?.cancel()
        liveSourceValidationTasks[id] = nil
        liveSourceEPGTasks[id]?.cancel()
        liveSourceEPGTasks[id] = nil
        liveSourceValidationStatuses[id] = nil
        liveSourceEPGStatuses[id] = nil
        do {
            try await environment.database.deleteLiveSource(id: id)
            liveSources = try await environment.database.liveSources()
            loadedLivePlaylists[id] = nil
            loadedEPGGuides[id] = nil
            loadedEPGScheduleIndexes[id] = nil
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
            show(error, title: "删除直播源失败")
        }
    }

    private func startLiveSourceBackgroundWork(
        for source: StoredLiveSource,
        playlist: LivePlaylist
    ) {
        liveSourceEPGTasks[source.id]?.cancel()
        if playlist.epgURL == nil {
            loadedEPGGuides[source.id] = nil
            loadedEPGScheduleIndexes[source.id] = nil
            epgFailures[source.id] = nil
            liveSourceEPGStatuses[source.id] = nil
            liveSourceEPGTasks[source.id] = nil
        } else {
            liveSourceEPGStatuses[source.id] = .loading
            liveSourceEPGTasks[source.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadEPG(for: source, playlist: playlist)
            }
        }
        startInitialLiveSourceValidation(
            sourceID: source.id,
            playlist: playlist
        )
    }

    private func startInitialLiveSourceValidation(
        sourceID: UUID,
        playlist: LivePlaylist
    ) {
        liveSourceValidationTasks[sourceID]?.cancel()
        let channels = playlist.groups.flatMap(\.channels)
        guard !channels.isEmpty else {
            liveSourceValidationStatuses[sourceID] = .completed(
                removed: 0,
                total: 0
            )
            return
        }
        liveSourceValidationStatuses[sourceID] = .checking(
            completed: 0,
            total: channels.count
        )
        let prober = LiveStreamAvailabilityProber()
        liveSourceValidationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var unavailableChannelIDs = Set<String>()
            var completed = 0

            for startIndex in stride(
                from: 0,
                to: channels.count,
                by: 4
            ) {
                guard !Task.isCancelled else { return }
                let endIndex = min(startIndex + 4, channels.count)
                let batch = Array(channels[startIndex..<endIndex])
                let results = await withTaskGroup(
                    of: (String, Bool).self,
                    returning: [(String, Bool)].self
                ) { group in
                    for channel in batch {
                        group.addTask {
                            guard !channel.streams.isEmpty else {
                                return (channel.id, true)
                            }
                            var streamResults: [LiveStreamProbeResult] = []
                            for stream in channel.streams {
                                guard !Task.isCancelled else {
                                    return (channel.id, false)
                                }
                                streamResults.append(
                                    await prober.result(for: stream)
                                )
                            }
                            return (
                                channel.id,
                                LiveSourceValidationPolicy.shouldRemoveChannel(
                                    streamResults: streamResults
                                )
                            )
                        }
                    }
                    var values: [(String, Bool)] = []
                    for await result in group {
                        values.append(result)
                    }
                    return values
                }
                guard !Task.isCancelled else { return }
                for (channelID, isUnavailable) in results
                where isUnavailable {
                    unavailableChannelIDs.insert(channelID)
                }
                completed += batch.count
                self.liveSourceValidationStatuses[sourceID] = .checking(
                    completed: completed,
                    total: channels.count
                )
            }

            guard !Task.isCancelled,
                  self.liveSources.contains(where: { $0.id == sourceID }) else {
                return
            }
            do {
                try await self.applyAutomaticallyUnavailableLiveChannels(
                    unavailableChannelIDs,
                    sourceID: sourceID,
                    channels: channels
                )
                self.liveSourceValidationStatuses[sourceID] = .completed(
                    removed: unavailableChannelIDs.count,
                    total: channels.count
                )
            } catch {
                self.liveSourceValidationStatuses[sourceID] = .failed(
                    error.localizedDescription
                )
            }
            self.liveSourceValidationTasks[sourceID] = nil
        }
    }

    private func applyAutomaticallyUnavailableLiveChannels(
        _ channelIDs: Set<String>,
        sourceID: UUID,
        channels: [LiveChannel]
    ) async throws {
        guard !channelIDs.isEmpty else { return }
        let previousDeletedIDs = deletedLiveChannelIDs
        let previousFavoriteIDs = favoriteLiveChannelIDs
        let sourceName = liveSources.first(where: { $0.id == sourceID })?.name
        for channel in channels where channelIDs.contains(channel.id) {
            deletedLiveChannelIDs.insert(
                LiveChannelDeletionPolicy.identifier(
                    sourceID: sourceID,
                    channelID: channel.id
                )
            )
            if let sourceName {
                favoriteLiveChannelIDs.remove(
                    liveFavoriteID(
                        sourceName: sourceName,
                        channel: channel
                    )
                )
            }
        }
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
            throw error
        }
    }

    func playLive(
        channel: LiveChannel,
        stream: LiveStream,
        sourceID: UUID,
        navigationChannels: [LiveChannel]? = nil,
        windowActivation: PlayerWindowActivationPolicy = .userInitiated
    ) async {
        guard !isShutdownRequested, let environment else { return }
        historyPlaybackTask?.cancel()
        historyPlaybackTask = nil
        historyPlaybackPreparationID = UUID()
        historyPlaybackLoadingID = nil
        historyPlaybackRequestedItem = nil
        historyPlaybackChoices = []
        let clickRequestID = UUID()
        PlayerStartupTraceStore.shared.begin(
            requestID: clickRequestID,
            mode: environment.player.mode
        )
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        livePlaybackNotice = nil
        hasExhaustedLivePlayback = false
        livePlaybackAttemptedIdentifiers = []
        if let navigationChannels {
            livePlaybackNavigationContext = LivePlaybackNavigationContext(
                sourceID: sourceID,
                channels: LiveChannelNavigationPolicy.normalizedChannels(
                    navigationChannels,
                    including: channel
                )
            )
        } else if livePlaybackNavigationContext?.sourceID != sourceID
                    || livePlaybackNavigationContext?.channels.contains(
                        where: { $0.id == channel.id }
                    ) != true {
            livePlaybackNavigationContext = LivePlaybackNavigationContext(
                sourceID: sourceID,
                channels: [channel]
            )
        }

        activePlayback = nil
        pendingPlayback = nil
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
        presentPlayer(
            requestID: clickRequestID,
            activation: windowActivation
        )
        await attemptLivePlaybackCandidates(
            startingChannel: channel,
            startingStream: stream,
            sourceID: sourceID,
            isAutomaticRecovery: false,
            initialRequestID: clickRequestID
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
        sourceID: UUID,
        isAutomaticRecovery: Bool,
        initialRequestID: UUID? = nil
    ) async {
        guard let environment,
              let context = livePlaybackNavigationContext,
              context.sourceID == sourceID else {
            return
        }
        isRecoveringLivePlayback = true
        hasExhaustedLivePlayback = false
        let candidates = LivePlaybackRecoveryPolicy.candidates(
            channels: context.channels,
            startingChannel: startingChannel,
            startingStream: startingStream,
            excluding: livePlaybackAttemptedIdentifiers
        )
        var skippedCount = 0
        var pendingInitialRequestID = initialRequestID
        for candidate in candidates {
            guard !Task.isCancelled,
                  !isShutdownRequested,
                  livePlaybackSourceID == sourceID,
                  isPlayerPresented else {
                isRecoveringLivePlayback = false
                return
            }
            livePlaybackAttemptedIdentifiers.insert(candidate.identifier)
            let requestID = pendingInitialRequestID ?? UUID()
            if pendingInitialRequestID == nil {
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
            let media = ResolvedMedia(
                url: candidate.stream.url,
                headers: HTTPHeaders(candidate.stream.headers),
                format: candidate.stream.format,
                siteKey: "live",
                sourceName: candidate.channel.name,
                episodeName: candidate.stream.name
            )
            do {
                try await loadPlayerAfterRenderSurfaceReady(
                    media,
                    startPosition: nil,
                    requestID: requestID
                )
                guard playbackSessionID == requestID else { return }
                isRecoveringLivePlayback = false
                hasExhaustedLivePlayback = false
                if skippedCount > 0 || isAutomaticRecovery {
                    showLivePlaybackNotice(
                        "已自动跳过失效线路，正在播放 \(candidate.channel.name)"
                    )
                }
                return
            } catch {
                PlayerStartupTraceStore.shared.cancel(requestID: requestID)
                guard playbackSessionID == requestID else { return }
                skippedCount += 1
            }
        }
        finishExhaustedLivePlayback()
    }

    private func recoverLivePlaybackAfterFailure(requestID: UUID?) {
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
              let sourceID = livePlaybackSourceID else {
            return
        }
        livePlaybackRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.attemptLivePlaybackCandidates(
                startingChannel: channel,
                startingStream: stream,
                sourceID: sourceID,
                isAutomaticRecovery: true
            )
            self.livePlaybackRecoveryTask = nil
        }
    }

    private func finishExhaustedLivePlayback() {
        isRecoveringLivePlayback = false
        hasExhaustedLivePlayback = true
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        livePlaybackNotice = "当前直播源暂时没有可播放的频道"
    }

    private func showLivePlaybackNotice(_ message: String) {
        livePlaybackNoticeTask?.cancel()
        livePlaybackNotice = message
        livePlaybackNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.livePlaybackNotice = nil
            self?.livePlaybackNoticeTask = nil
        }
    }

    func isLiveFavorite(sourceName: String, channel: LiveChannel) -> Bool {
        favoriteLiveChannelIDs.contains(liveFavoriteID(sourceName: sourceName, channel: channel))
    }

    func isLiveChannelDeleted(
        sourceID: UUID,
        channel: LiveChannel
    ) -> Bool {
        LiveChannelDeletionPolicy.contains(
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
            show(error, title: "无法删除直播频道")
        }
    }

    func restoreDeletedLiveChannel(
        sourceID: UUID,
        channel: LiveChannel
    ) async {
        let identifier = LiveChannelDeletionPolicy.identifier(
            sourceID: sourceID,
            channelID: channel.id
        )
        guard deletedLiveChannelIDs.remove(identifier) != nil else { return }
        do {
            try await persistDeletedLiveChannels()
        } catch {
            deletedLiveChannelIDs.insert(identifier)
            show(error, title: "无法恢复直播频道")
        }
    }

    func restoreAllDeletedLiveChannels(sourceID: UUID) async {
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
            show(error, title: "无法恢复直播频道")
        }
    }

    func toggleLiveFavorite(sourceName: String, channel: LiveChannel) async {
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
            show(error, title: "无法保存直播收藏")
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
            throw AppError.filesystem("无法导出配置：\(error.localizedDescription)")
        }
    }

    func exportPortableBackup(
        to url: URL
    ) async throws -> PortableBackupPreview {
        guard let environment, let configuration = activeConfigurationRecord else {
            throw AppError.configuration("请先导入并启用一个点播配置")
        }
        let allHistory = try await environment.database.history()
        let history = allHistory.filter {
            $0.configurationID == configuration.id
        }
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "未知"
        let createdAt = Date()
        let data = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.encode(
                configuration: configuration,
                history: history,
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
            historyCount: history.count
        )
    }

    func inspectPortableBackup(
        at url: URL
    ) async throws -> PortableBackupPreview {
        let data = try readPortableBackupData(from: url)
        let decoded = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.decode(data)
        }.value
        _ = try ConfigurationParser().parse(
            decoded.payload.configuration.rawData
        )
        return PortableBackupPreview(
            fileURL: url,
            createdAt: decoded.manifest.createdAt,
            appVersion: decoded.manifest.appVersion,
            appBuild: decoded.manifest.appBuild,
            configurationName: decoded.payload.configuration.name,
            historyCount: decoded.payload.history.count
        )
    }

    func importPortableBackup(
        from url: URL
    ) async throws -> PortableBackupImportSummary {
        guard let environment else {
            throw AppError.configuration("应用环境尚未初始化")
        }
        let data = try readPortableBackupData(from: url)
        let decoded = try await Task.detached(priority: .userInitiated) {
            try PortableBackupCodec.decode(data)
        }.value
        _ = try ConfigurationParser().parse(
            decoded.payload.configuration.rawData
        )

        // A failed or unwanted merge must always have a user-owned recovery
        // point. This backup is written before the database transaction.
        let safetyBackupURL = try await createPreImportSafetyBackup()
        let result = try await environment.database
            .restoreConfigurationAndHistory(
                configuration: decoded.payload.configuration.storedConfiguration,
                history: decoded.payload.history
            )

        cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
        resetSearchForConfigurationChange()
        configurationRefreshSessionID = UUID()
        configurationRefreshTask?.cancel()
        configurationRefreshTask = nil
        configurations = result.configurations
        activeConfigurationRecord = result.configuration
        activeNodeRuntimeEndpoint = nil
        nodeRuntimeUnavailableReason = "Node Runtime 将在使用配置时准备"
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
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "未知"
        let data = try await Task.detached(priority: .utility) {
            try PortableBackupCodec.encode(
                configuration: configuration,
                history: history,
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
                "无法创建导入前安全备份：\(error.localizedDescription)"
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
                "无法读取备份文件：\(error.localizedDescription)"
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
                "无法写入备份文件：\(error.localizedDescription)"
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
            show(error, title: "无法保存无痕设置")
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
            show(error, title: "无法保存历史设置")
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
            show(error, title: "无法保存主题设置")
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
            show(error, title: "无法保存连续播放设置")
        }
    }

    func clearPosterCache() async {
        guard let repository = environment?.imageRepository else { return }
        do {
            try await repository.clear()
        } catch {
            show(error, title: "清理海报缓存失败")
        }
    }

    func clearHistory() async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id else {
            return
        }
        do {
            let removedRecords = history.filter {
                $0.configurationID == configurationID
            }
            let recordIDs = Set(removedRecords.map(\.id))
            _ = try await environment.database.deleteHistory(
                configurationID: configurationID
            )
            removeCatPawReplayReferences(in: removedRecords)
            historyPlaybackSessionCache.remove(recordIDs)
            try await reloadHistory()
        } catch {
            show(error, title: "清理历史失败")
        }
    }

    func deleteHistory(ids: Set<HistoryRecord.ID>) async {
        guard let environment, !ids.isEmpty else { return }
        do {
            var removedRecords: [HistoryRecord] = []
            for record in history where ids.contains(record.id) {
                _ = try await environment.database.deleteHistory(
                    configurationID: record.configurationID,
                    siteKey: record.siteKey,
                    videoID: record.videoID,
                    sourceKey: record.sourceKey
                )
                removedRecords.append(record)
            }
            removeCatPawReplayReferences(in: removedRecords)
            historyPlaybackSessionCache.remove(ids)
            try await reloadHistory()
        } catch {
            show(error, title: "删除历史失败")
        }
    }

    private func removeCatPawReplayReferences(
        in records: [HistoryRecord]
    ) {
        let locators = Set(records.compactMap(Self.catPawReplayLocator))
        for locator in locators {
            _ = NodePlaybackKeychainReplayStore.shared.removeReplay(
                for: locator
            )
        }
    }

    private static func catPawReplayLocator(
        in record: HistoryRecord
    ) -> String? {
        guard let reference = record.playbackReference?
            .providerResourceReference,
              reference.providerKind == "node-http-spider",
              reference.providerVersion == 2,
              reference.stableResourceLocator.hasPrefix(
                  "\(NodePlaybackReplayReference.protectedPrefix)."
              ) else {
            return nil
        }
        return reference.stableResourceLocator
    }

    private func removeReplacedCatPawReplayReference(
        old: HistoryRecord?,
        new: HistoryRecord
    ) {
        guard let oldLocator = old.flatMap(Self.catPawReplayLocator),
              oldLocator != Self.catPawReplayLocator(in: new) else {
            return
        }
        _ = NodePlaybackKeychainReplayStore.shared.removeReplay(
            for: oldLocator
        )
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
            throw AppError.filesystem("无法导出诊断：\(error.localizedDescription)")
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

        isShutdownRequested = true
        playerRenderSurfaceGate.reset()
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
        for task in liveSourceValidationTasks.values {
            task.cancel()
        }
        liveSourceValidationTasks = [:]
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        nodeAuthorizationCompletionTask?.cancel()
        nodeAuthorizationCompletionTask = nil
        if let challengeID = nodeWebPresentation?.challengeID {
            await NodeAuthorizationSignalCenter.shared.cancel(challengeID)
        }
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        nodeRuntimeStatusTask?.cancel()
        nodeRuntimeStatusTask = nil
        nodeProfileRevisionTask?.cancel()
        nodeProfileRevisionTask = nil
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
            await self.finishScheduledHistoryPersistence()
            if self.activePlayback != nil {
                try? await self.savePlaybackHistory(
                    position: self.playerSnapshot.position,
                    duration: self.playerSnapshot.duration
                )
            }
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
            self.pendingPlayback = nil
            self.cloudAuthorizationContext = nil
            self.pendingHistoryWrite = nil
        }
        shutdownTask = task
        await task.value
        hasCompletedShutdown = true
    }

    func persistPlaybackProgress() async {
        guard activePlayback != nil else { return }
        await finishScheduledHistoryPersistence()
        try? await savePlaybackHistory(
            position: playerSnapshot.position,
            duration: playerSnapshot.duration
        )
    }

    func handleSystemSleep() async {
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
        guard shouldResumeAfterWake else { return }
        shouldResumeAfterWake = false
        do {
            try await environment?.player.play()
        } catch {
            show(error, title: "唤醒后恢复播放失败")
        }
    }

    func closePlayer() async {
        guard !isShutdownRequested else { return }
        guard !isClosingPlayer else { return }
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
        defer { isClosingPlayer = false }
        let closingRequestID = activePlayerRequestID
        let shouldRetainTVBoxPlayerWarm = activePlayback?.media.transportProfile
            == .tvBox
        playerRenderSurfaceGate.reset()
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
        livePlaybackRecoveryTask?.cancel()
        livePlaybackRecoveryTask = nil
        livePlaybackNoticeTask?.cancel()
        livePlaybackNoticeTask = nil
        isRecoveringLivePlayback = false
        hasExhaustedLivePlayback = false
        livePlaybackNotice = nil
        livePlaybackAttemptedIdentifiers = []
        // Capture the final position before stop resets the player snapshot.
        await persistPlaybackProgress()
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
        await environment?.player.closeAfterPlayback(
            requestID: closingRequestID,
            // `stop` releases the active demux/cache state immediately. Keep
            // only the idle libmpv core briefly so returning from History does
            // not pay another native cold-start; ordinary sources retain the
            // existing immediate full-destroy behavior.
            warmRetentionSeconds: shouldRetainTVBoxPlayerWarm ? 45 : 0
        )
        await cleanupPreparedTransferReceipts(reason: .playerClosed)
        await releaseAllTransferMediaLeases(reason: .playerClosed)
        if let lease = activeNodePlaybackLease {
            activeNodePlaybackLease = nil
            await environment?.nodeBundleRuntime.releasePlaybackLease(lease)
        }
        await dismissPlayerSurfaceAndRestoreWindow()
        playbackResolutionState = .idle
        currentPlaybackAttempt = nil
        playbackFailureSummary = nil
        playerPresentedError = nil
    }

    func togglePlayPause() async {
        guard let player = environment?.player else { return }
        let previousStatus = playerSnapshot.status
        let shouldPlay: Bool
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
            show(error, title: "播放控制失败")
        }
    }

    func seek(by offset: TimeInterval) async {
        guard canSeekPlayback else { return }
        let target = min(
            max(0, playerSnapshot.position + offset),
            playerSnapshot.duration > 0
                ? playerSnapshot.duration
                : .greatestFiniteMagnitude
        )
        await seek(to: target)
    }

    func seek(to position: TimeInterval) async {
        guard canSeekPlayback else { return }
        guard let player = environment?.player else { return }
        guard let target = PlayerSeekPolicy.target(
            requested: position,
            duration: playerSnapshot.duration
        ) else {
            show(AppError.playback("跳转位置无效"), title: "跳转失败")
            return
        }
        let previousPosition = playerSnapshot.position
        let isTVBoxPlayback = activePlayback?.media.transportProfile == .tvBox
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
                    "播放器在 10 秒内没有完成跳转，已返回原播放位置。"
                        + "当前网络或线路响应较慢，请稍后重试或切换清晰度。"
                ),
                title: "跳转超时"
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
            show(error, title: "跳转失败")
        }
    }

    func setPlayerVolume(_ volume: Double) async {
        let clampedVolume = min(max(volume, 0), 130)
        let previousVolume = playerSnapshot.volume
        playerSnapshot.volume = clampedVolume
        do {
            try await environment?.player.setVolume(clampedVolume)
        } catch {
            if playerSnapshot.volume == clampedVolume {
                playerSnapshot.volume = previousVolume
            }
            show(error, title: "音量设置失败")
        }
    }

    func adjustPlayerVolume(by delta: Double) async {
        await setPlayerVolume(playerSnapshot.volume + delta)
    }

    func togglePlayerMute() async {
        let previousMuted = playerSnapshot.isMuted
        let targetMuted = !previousMuted
        playerSnapshot.isMuted = targetMuted
        do {
            try await environment?.player.setMuted(targetMuted)
        } catch {
            if playerSnapshot.isMuted == targetMuted {
                playerSnapshot.isMuted = previousMuted
            }
            show(error, title: "静音设置失败")
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
            show(error, title: "倍速设置失败")
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
        let previousPosition = playerSnapshot.position
        let previousDuration = playerSnapshot.duration
        let wasPaused: Bool
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
                result: playbackResult
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
                    failureMessage ?? "该清晰度没有返回可播放地址"
                )
            }
            guard playbackQualitySwitchSessionID == switchSessionID,
                  playbackSessionID == owningPlaybackSessionID else {
                throw CancellationError()
            }

            replacementStarted = true
            activePlayerRequestID = switchSessionID
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
                providerResourceReference: playback.providerResourceReference
            )
            playbackQualities = playbackResult.qualities
            selectedPlaybackQualityID = quality.id
            playbackResolutionState = .playing
            currentPlaybackAttempt = nil
            playbackFailureSummary = nil
            try await savePlaybackHistory(
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
                playbackResolutionState = .failed
                playbackFailureSummary = restoreError.localizedDescription
                show(
                    AppError.playback(
                        "\(error.localizedDescription)；恢复原清晰度也失败："
                            + restoreError.localizedDescription
                    ),
                    title: "清晰度切换失败"
                )
            } else {
                playbackResolutionState = .playing
                playbackFailureSummary = nil
                show(error, title: "清晰度切换失败")
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
            show(error, title: "轨道切换失败")
        }
    }

    func togglePlayerSubtitles() async {
        let subtitleTracks = playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        guard !subtitleTracks.isEmpty else {
            show(AppError.playback("当前视频没有可用字幕"), title: "字幕设置失败")
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
            show(error, title: "字幕设置失败")
        }
    }

    func adjustPlayerSubtitleDelay(by offset: TimeInterval) async {
        let value = min(max(playerSubtitleDelay + offset, -30), 30)
        do {
            try await environment?.player.setSubtitleDelay(value)
            playerSubtitleDelay = value
        } catch {
            show(error, title: "字幕延迟设置失败")
        }
    }

    func adjustPlayerSubtitleScale(by offset: Double) async {
        let value = min(max(playerSubtitleScale + offset, 0.5), 3)
        do {
            try await environment?.player.setSubtitleScale(value)
            playerSubtitleScale = value
        } catch {
            show(error, title: "字幕大小设置失败")
        }
    }

    func adjustPlayerSubtitlePosition(by offset: Double) async {
        let value = min(max(playerSubtitlePosition + offset, 0), 100)
        do {
            try await environment?.player.setSubtitlePosition(value)
            playerSubtitlePosition = value
        } catch {
            show(error, title: "字幕位置设置失败")
        }
    }

    func adjustPlayerSubtitleBorderSize(by offset: Double) async {
        let value = min(max(playerSubtitleBorderSize + offset, 0), 10)
        do {
            try await environment?.player.setSubtitleBorderSize(value)
            playerSubtitleBorderSize = value
        } catch {
            show(error, title: "字幕描边设置失败")
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
            show(error, title: "字幕设置重置失败")
        }
    }

    func adjustPlayerAudioDelay(by offset: TimeInterval) async {
        let value = min(max(playerAudioDelay + offset, -30), 30)
        do {
            try await environment?.player.setAudioDelay(value)
            playerAudioDelay = value
        } catch {
            show(error, title: "音频延迟设置失败")
        }
    }

    func setPlayerAspectRatio(_ ratio: String?) async {
        do {
            try await environment?.player.setAspectRatio(ratio)
            playerAspectRatio = ratio
        } catch {
            show(error, title: "画面比例设置失败")
        }
    }

    func togglePlayerHardwareDecoding() async {
        let value = !playerHardwareDecoding
        do {
            try await environment?.player.setHardwareDecoding(enabled: value)
            playerHardwareDecoding = value
        } catch {
            show(error, title: "硬件解码设置失败")
        }
    }

    func addPlayerSubtitle(_ url: URL) async {
        do {
            try await environment?.player.addSubtitle(url: url)
            playerSubtitlesEnabled = true
            prefersPlayerSubtitlesEnabled = true
            await persistPlayerSubtitlePreference(enabled: true, track: nil)
        } catch {
            show(error, title: "字幕加载失败")
        }
    }

    func savePlayerScreenshot(to url: URL) async {
        do {
            try await environment?.player.screenshot(to: url)
        } catch {
            show(error, title: "截图失败")
        }
    }

    func playAdjacentEpisode(offset: Int) async {
        guard let playback = activePlayback,
              let currentIndex = playback.source.episodes.firstIndex(
                where: { $0.id == playback.episode.id }
              ) else { return }
        let nextIndex = currentIndex + offset
        guard playback.source.episodes.indices.contains(nextIndex) else { return }
        await startPlayback(
            detail: playback.detail,
            source: playback.source,
            episode: playback.source.episodes[nextIndex],
            configurationID: playback.configurationID,
            windowActivation: .preserveFocus
        )
    }

    func playPlayerEpisode(_ episode: PlayEpisode) async {
        guard let playback = activePlayback,
              playback.source.episodes.contains(where: { $0.id == episode.id }) else {
            return
        }
        await startPlayback(
            detail: playback.detail,
            source: playback.source,
            episode: episode,
            configurationID: playback.configurationID,
            windowActivation: .preserveFocus
        )
    }

    func reportPlayerRenderError(_ error: Error) {
        show(error, title: "视频渲染失败")
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
        return "未知架构"
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
        guard let environment else {
            androidRuntimeStatus = .unavailable("应用运行环境未完成初始化")
            return
        }
        androidRuntimeStatus = await environment.androidDexBridge.runtimeStatus()
    }

    func chooseAndroidSDK() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Android SDK"
        panel.message = "请选择包含 platform-tools 和 emulator 的 Android SDK 目录。"
        panel.prompt = "选择 SDK"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await environment.androidDexBridge.setUserSelectedSDKRoot(url)
        androidRuntimeStatus = await environment.androidDexBridge.runtimeStatus()
    }

    func startAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        androidRuntimeStatus = .starting(
            "准备启动 Android 兼容模块",
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
            androidRuntimeStatus = try await environment.androidDexBridge
                .startRuntime()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            show(error, title: "Android 兼容模块启动失败")
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
            "准备重建端口映射并重新安装 Bridge",
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
            androidRuntimeStatus = try await environment.androidDexBridge
                .repairRuntime()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            show(error, title: "Android 兼容模块修复失败")
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
        case .idle: return "空闲"
        case .loading: return "载入中"
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .buffering: return "缓冲中"
        case .ended: return "已结束"
        case .stopped: return "已停止"
        case .failed(let message): return "失败：\(LogRedactor.text(message))"
        }
    }

    var imageRepository: ImageRepository? {
        environment?.imageRepository
    }

    var embeddedPlayer: MPVPlayerClient? {
        playerRenderClient
    }

    var playerRuntimeDescription: String {
        environment?.player.runtimeDescription ?? "libmpv 不可用"
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
        guard let channel = livePlaybackChannel else { return "直播" }
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
        sourceID: UUID,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        loadedEPGScheduleIndexes[sourceID]?
            .currentAndNext(for: channel, at: date) ?? (nil, nil)
    }

    var playbackStageDescription: String {
        if case .failed = playerSnapshot.status {
            return "播放失败"
        }
        if playerSnapshot.isSeeking && playerSnapshot.isPausedForCache {
            return cacheActivityDescription(prefix: "正在跳转并缓冲")
        }
        if playerSnapshot.isPausedForCache {
            return cacheActivityDescription(prefix: "正在缓冲")
        }
        if playerSnapshot.isSeeking {
            guard let target = playerSnapshot.seekTarget else {
                return "正在跳转"
            }
            return "正在跳转到 \(Self.playbackTimeDescription(target))"
        }
        switch playbackResolutionState {
        case .idle: return playerStatusDescription
        case .restoringHistory: return "正在恢复历史记录"
        case .resolving: return "正在获取或解析播放地址"
        case .validating: return "正在验证媒体线路"
        case .loading: return "播放器正在连接媒体"
        case .playing: return playerStatusDescription
        case .retrying: return "当前线路失败，正在自动换线"
        case .exhausted: return "所有可用线路均已尝试"
        case .failed: return "播放准备失败"
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
                return "当前速度 0 KB/s"
            default:
                return "等待媒体数据"
            }
        }
        let value = ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
        return "当前速度 \(value)/s"
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
        if let cached = playerEpisodePresentationCache?
            .valuesByEpisodeID[episodeID] {
            return cached
        }
        guard let episode = playerEpisodes.first(where: { $0.id == episodeID }) else {
            return nil
        }
        return EpisodeNameParser.presentation(for: episode)
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
            videoID: detail.summary.id,
            sourceID: source.id,
            episodeCount: source.episodes.count,
            firstEpisodeID: source.episodes.first?.id,
            lastEpisodeID: source.episodes.last?.id
        )
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
                source: source
            )
            guard !Task.isCancelled, let self,
                  self.playbackSessionID == sessionID else { return }
            let cache = PlayerEpisodePresentationCache(
                key: key,
                values: snapshot.values,
                valuesByEpisodeID: snapshot.valuesByEpisodeID
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
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
        let resolvedOrigin = origin
            ?? searchFolderOrigin
            ?? (isHomeSearchPresented ? .searchResults : .home)
        presentHomeSearch()
        let page = SearchFolderPage(folder: summary)
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

    private func loadSearchFolder(
        id: UUID,
        summary: VideoSummary,
        page pageNumber: Int
    ) async {
        guard let provider = providers[summary.siteKey] else {
            updateSearchFolder(id: id) { page in
                page.isLoading = false
                page.errorMessage = "来源 \(summary.siteName) 在当前配置中不可用"
            }
            return
        }

        do {
            let loaded = try await provider.category(
                id: summary.videoID,
                page: pageNumber,
                filters: [:]
            )
            updateSearchFolder(id: id) { page in
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
                page.isLoading = false
                page.errorMessage = nil
            }
        } catch {
            updateSearchFolder(id: id) { page in
                page.isLoading = false
                page.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateSearchFolder(
        id: UUID,
        _ update: (inout SearchFolderPage) -> Void
    ) {
        guard let index = searchFolderPath.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        update(&searchFolderPath[index])
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
            return "旧版记录"
        }
        return configurations.first(where: { $0.id == configurationID })?.name
            ?? "原配置已删除"
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

    static func historyPlaybackSelection(
        in detail: VideoDetail,
        record: HistoryRecord
    ) -> (source: PlaySource, episode: PlayEpisode)? {
        if let recipe = record.playbackReference?.navigationRecipe,
           let recipeSelection = historyRecipeSelection(
            in: detail,
            recipe: recipe
           ) {
            return recipeSelection
        }
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
            let preferredMatches = preferredSources.compactMap { source in
                source.episodes.first(where: {
                    $0.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        == normalizedReference
                }).map { (source, $0) }
            }
            if preferredMatches.count == 1 {
                return preferredMatches[0]
            }
            let globalMatches = detail.playSources.compactMap { source in
                source.episodes.first(where: {
                    $0.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        == normalizedReference
                }).map { (source, $0) }
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
                let matches = detail.playSources.compactMap { source in
                    source.episodes.first(where: {
                        QuarkEpisodeReference.identity(from: $0.url) == identity
                    }).map { (source, $0) }
                }
                if matches.count == 1 {
                    return matches[0]
                }
            }
        }

        if let episodeName = record.episodeName?.nonEmpty {
            let exactMatches = preferredSources.compactMap { source in
                source.episodes.first(where: {
                    $0.name.compare(
                        episodeName,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                }).map { (source, $0) }
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

            // Only use numbers explicitly encoded by both names. This never
            // infers an episode from its list position, so specials and lists
            // that do not begin at episode one remain safe.
            let recordedPresentation = EpisodeNameParser.presentation(
                for: PlayEpisode(name: episodeName, url: "history-identity")
            )
            if let recordedEpisode = recordedPresentation.episodeNumber {
                let numberedMatches = preferredSources.compactMap { source in
                    source.episodes.first(where: { candidate in
                        let presentation = EpisodeNameParser.presentation(
                            for: candidate
                        )
                        guard presentation.episodeNumber == recordedEpisode,
                              !presentation.isSpecial else {
                            return false
                        }
                        if let recordedSeason = recordedPresentation.seasonNumber {
                            return presentation.seasonNumber == nil
                                || presentation.seasonNumber == recordedSeason
                        }
                        return true
                    }).map { (source, $0) }
                }
                if numberedMatches.count == 1 {
                    return numberedMatches[0]
                }
                let globalNumberedMatches: [(PlaySource, PlayEpisode)] = detail.playSources.flatMap { source in
                    source.episodes.compactMap { candidate -> (PlaySource, PlayEpisode)? in
                        let presentation = EpisodeNameParser.presentation(
                            for: candidate
                        )
                        guard presentation.episodeNumber == recordedEpisode,
                              !presentation.isSpecial else { return nil }
                        if let recordedSeason = recordedPresentation.seasonNumber,
                           let candidateSeason = presentation.seasonNumber,
                           candidateSeason != recordedSeason {
                            return nil
                        }
                        return (source, candidate)
                    }
                }
                if globalNumberedMatches.count == 1 {
                    return globalNumberedMatches[0]
                }
            }
        }

        if preferredSources.count == 1,
           preferredSources[0].episodes.count == 1,
           let episode = preferredSources[0].episodes.first {
            return (preferredSources[0], episode)
        }
        return nil
    }

    static func historyPlaybackChoices(
        in detail: VideoDetail,
        record: HistoryRecord
    ) -> [(source: PlaySource, episode: PlayEpisode)] {
        if let selection = historyPlaybackSelection(in: detail, record: record) {
            return [selection]
        }

        let recipe = record.playbackReference?.navigationRecipe
        let recordedName = recipe?.episode.name.nonEmpty
            ?? record.episodeName?.nonEmpty
        let normalizedFilename = recipe?.episode.normalizedFilename.nonEmpty
            ?? recordedName.map(historyNormalizedFilename)
        let recordedEpisodeNumber = recipe?.episode.episodeNumber
            ?? recordedName.flatMap {
                EpisodeNameParser.presentation(
                    for: PlayEpisode(name: $0, url: "history-choice")
                ).episodeNumber
            }
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
                let episodeNumberMatch = recordedEpisodeNumber.map {
                    EpisodeNameParser.presentation(for: episode).episodeNumber
                        == $0
                } ?? false
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
        for (sourceIndex, source) in detail.playSources.enumerated() {
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
            } else if recipe.source.index == sourceIndex {
                sourceScore = 80
            }

            for (episodeIndex, episode) in source.episodes.enumerated() {
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
                    let presentation = EpisodeNameParser.presentation(for: episode)
                    if let episodeNumber = recipe.episode.episodeNumber,
                       presentation.episodeNumber == episodeNumber,
                       !presentation.isSpecial,
                       recipe.episode.seasonNumber == nil
                            || presentation.seasonNumber == nil
                            || presentation.seasonNumber
                                == recipe.episode.seasonNumber {
                        episodeScore = 250
                    } else if recipe.episode.index == episodeIndex {
                        episodeScore = 70
                    }
                }
                let score = sourceScore + episodeScore
                if score >= 140 {
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
        let presentation = EpisodeNameParser.presentation(for: episode)
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
                seasonNumber: presentation.seasonNumber,
                episodeNumber: presentation.episodeNumber,
                index: episodeIndex
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
            name: record.episodeName?.nonEmpty ?? "历史分集",
            url: episodeURL
        )
        let source = PlaySource(
            name: record.sourceName?.nonEmpty ?? "历史线路",
            episodes: [episode]
        )
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: record.siteKey,
                siteName: siteName,
                videoID: record.videoID,
                title: record.title,
                posterURL: record.posterURL
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
        providerCapability: SiteCapability? = nil
    ) -> String? {
        guard providerCapability != .javaDexSpider else { return nil }
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
        activeConfiguration = try ConfigurationParser().parse(record.rawData)
        rebuildProviders()
        if !supportedSites.contains(where: { $0.key == selectedSiteKey }) {
            selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                from: supportedSites
            )
        }
    }

    private func loadConfiguration(
        _ source: ConfigurationSource
    ) async throws -> LoadedConfiguration {
        guard let environment else {
            throw AppError.configuration("应用环境尚未初始化")
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
                nodeRuntimeUnavailableReason = error.localizedDescription
                rebuildProviders()
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
            throw AppError.configuration("应用环境尚未初始化")
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
                        presentation.hasAttemptedProfileRevisionVerification
                ) {
                    presentation.hasAttemptedProfileRevisionVerification = true
                    presentation.lifecycleState = .saved
                    presentation.status = "配置已保存，正在执行旧版 Spider 的一次性授权验证。"
                    self.nodeWebPresentation = presentation
                    await self.completeNodeConfigurationAndRetry(
                        automatically: true,
                        configurationAlreadyRefreshed: true
                    )
                } else {
                    presentation.lifecycleState = .saved
                    if isPlayback, presentation.requestID != nil {
                        presentation.status = "配置已保存，仍在等待当前请求的明确授权完成信号。"
                    } else if isPlayback {
                        presentation.status = "配置已保存；自动验证已执行过一次，请手动重试。"
                    } else {
                        presentation.status = "配置已保存，窗口将保持打开。"
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
        let shouldReloadHome: Bool
        switch status {
        case .running(let endpoint):
            shouldReloadHome = NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: lastReadyNodeRuntimeEndpoint,
                currentReadyEndpoint: endpoint,
                usesNodeRuntime: activeConfigurationUsesNodeRuntime,
                hasActiveConfiguration: activeConfiguration != nil,
                isConfigurationImportInProgress: configurationImportOperationID != nil
            )
            lastReadyNodeRuntimeEndpoint = endpoint
            activeNodeRuntimeEndpoint = endpoint
            rebindNodeConfigurationWebsite(to: endpoint)
            nodeRuntimeUnavailableReason = ""
        case .starting:
            shouldReloadHome = false
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = "Node Runtime 正在启动"
        case .restarting(let attempt, let reason):
            shouldReloadHome = false
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = "Node Runtime 正在第 \(attempt) 次恢复：\(reason)"
        case .failed(let reason):
            shouldReloadHome = false
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = reason
        case .stopped:
            shouldReloadHome = false
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = "Node Runtime 已停止"
        }
        if activeConfigurationUsesNodeRuntime, activeConfiguration != nil {
            rebuildProviders()
        }
        guard shouldReloadHome,
              case .running(let endpoint) = status,
              let configurationID = activeConfigurationRecord?.id,
              let siteKey = selectedSiteKey else {
            return
        }
        // Invalidate an older homepage request synchronously with endpoint
        // publication. The replacement load starts below, but the old request
        // must not get a chance to publish models containing the stale port.
        homeLoadSessionID = UUID()
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeNodeRuntimeEndpoint == endpoint,
                  self.activeConfigurationRecord?.id == configurationID,
                  self.selectedSiteKey == siteKey else {
                return
            }
            if let environment = self.environment {
                await environment.nodeBundleRuntime.recordDiagnosticEvent(
                    NodeDiagnosticEvent(
                        category: .runtime,
                        severity: .info,
                        code: .runtimeHomepageReloadRequested,
                        message: "Reloading homepage after Node runtime endpoint replacement",
                        siteKey: siteKey,
                        operation: "home"
                    )
                )
            }
            await self.loadSelectedSiteHome(
                refreshConfigurationIfNeeded: false,
                reportErrors: false
            )
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
            presentation.status = "CatPaw Runtime 已恢复，配置页已连接到新端口。"
        }
        nodeWebPresentation = presentation
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
            show(error, title: "无法读取搜索范围")
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
                AppError.database("已保存的搜索范围格式无效，请重新选择站点"),
                title: "搜索范围未自动扩大"
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
        searchClusters = []
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
        homeLoadSessionID = UUID()
        categoryLoadSessionID = UUID()
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
           categoryPage == nil {
            // A category request in flight is not a stable restore point. Keep
            // the last complete page for this configuration/site identity.
            return
        }
        homeBrowsingSnapshots[identity] = HomeBrowsingSnapshot(
            presentation: homePresentationSelection,
            categoryID: selectedCategoryID,
            filters: selectedCategoryFilters,
            page: categoryPage
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
                && snapshot.page != nil
        } else {
            restoresMissingCategoryPage = false
        }
        guard !currentIsValid || restoresMissingCategoryPage else { return }

        switch snapshot.presentation {
        case .recommendation where !home.recommendations.isEmpty:
            selectedCategoryID = nil
            selectedCategoryFilters = [:]
            categoryPage = nil
            homePresentationSelection = .recommendation
            homeLoadErrorMessage = nil
        case .category(let id) where home.categories.contains(where: {
            $0.id == id && $0.resolvedContentKind == .media
        }):
            selectedCategoryID = id
            selectedCategoryFilters = snapshot.filters
            categoryPage = snapshot.page
            homePresentationSelection = .category(id)
            homeLoadErrorMessage = nil
        case .actions where !home.actionItems.isEmpty
            || HomePresentationPolicy.firstActionCategory(in: home) != nil:
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
        reportCategoryErrors: Bool = true
    ) async -> Bool {
        guard currentHomeContentIdentity == identity,
              homeContentIdentity == identity else {
            return false
        }
        let selection = HomePresentationPolicy.selection(
            for: home,
            preserving: selectedCategoryID
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
            let filters = selectedCategoryID == id
                ? selectedCategoryFilters
                : HomePresentationPolicy.defaultFilters(for: category)
            if loadsCategoryContent {
                return await loadCategory(
                    id: id,
                    filters: filters,
                    reportErrors: reportCategoryErrors
                )
            } else {
                categoryLoadSessionID = UUID()
                isLoadingNextCategoryPage = false
                categoryPaginationError = nil
                selectedCategoryID = id
                selectedCategoryFilters = filters
                categoryPage = nil
                return true
            }
        case .actions:
            categoryLoadSessionID = UUID()
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

    private func rebuildProviders() {
        guard let environment else {
            providers = [:]
            return
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
        let nodeBundleRuntime = environment.nodeBundleRuntime
        let activeConfigurationID = activeConfigurationRecord?.id
        providers = Dictionary(
            uniqueKeysWithValues: providerCatalogSites.map { site in
                let provider: SiteProvider
                let nodeOwned = SiteProviderRoutingPolicy
                    .hasExclusiveNodeRuntimeOwnership(site)
                let localScriptURL = javaScriptURL(
                    for: site,
                    baseURL: baseURL
                )
                if nodeOwned {
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
                            playbackReplayStore:
                                NodePlaybackKeychainReplayStore.shared,
                            configurationIdentity: activeConfigurationID?
                                .uuidString
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
                            diagnosticReporter: {
                                [weak runtime = nodeBundleRuntime] event in
                                Task { await runtime?.recordDiagnosticEvent(event) }
                            },
                            playbackReplayStore:
                                NodePlaybackKeychainReplayStore.shared,
                            configurationIdentity: activeConfigurationID?
                                .uuidString
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
                        bridge: environment.androidDexBridge
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
        favorites = try await environment.database.favorites()
        let expirationDate = Calendar.current.date(
            byAdding: .day,
            value: -historyRetentionDays,
            to: Date()
        ) ?? Date.distantPast
        let expiredRecords = try await environment.database.history().filter {
            $0.watchedAt < expirationDate
        }
        _ = try await environment.database.deleteHistory(
            olderThan: expirationDate
        )
        removeCatPawReplayReferences(in: expiredRecords)
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
        history = Self.historyRecords(
            try await environment.database.history(),
            for: activeConfigurationRecord?.id
        )
    }

    private func loadEPG(
        for source: StoredLiveSource,
        playlist: LivePlaylist
    ) async {
        guard let environment, let epgURL = playlist.epgURL else {
            loadedEPGGuides[source.id] = nil
            loadedEPGScheduleIndexes[source.id] = nil
            epgFailures[source.id] = nil
            liveSourceEPGStatuses[source.id] = nil
            return
        }
        do {
            let guide = try await environment.epgService.guide(
                for: epgURL
            )
            try Task.checkCancellation()
            let index = await XMLTVScheduleIndexBuilder.build(guide: guide)
            try Task.checkCancellation()
            guard liveSources.contains(where: { $0.id == source.id }) else {
                return
            }
            loadedEPGScheduleIndexes[source.id] = index
            loadedEPGGuides[source.id] = guide
            epgFailures[source.id] = nil
            liveSourceEPGStatuses[source.id] = .ready
        } catch is CancellationError {
            return
        } catch {
            loadedEPGGuides[source.id] = nil
            loadedEPGScheduleIndexes[source.id] = nil
            epgFailures[source.id] = error.localizedDescription
            liveSourceEPGStatuses[source.id] = .failed(
                error.localizedDescription
            )
        }
    }

    private func loadSettings() async throws {
        guard let environment else { return }
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
           let theme = AppTheme(rawValue: rawTheme) {
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
        if let value = try await environment.database.setting(
            forKey: CloudAccountStatusStore.settingKey
        ), let stored = CloudAccountStatusStore(setting: value) {
            cloudAccountStatusStore = stored
        }
        await loadSearchSiteScope()
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
              let currentIndex = playback.source.episodes.firstIndex(
                where: { $0.id == playback.episode.id }
              ) else { return false }
        return playback.source.episodes.indices.contains(currentIndex + offset)
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
                    self.playerSnapshot = snapshot
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
                    let shouldPersist = elapsedSinceHistorySave
                        >= (isInactiveStatus ? 1 : 10)
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
                            try? await self.savePlaybackHistory(
                                position: self.playerSnapshot.position,
                                duration: self.playerSnapshot.duration
                            )
                        }
                        if origin.permitsAutomaticAdvance {
                            await self.advanceAfterNaturalEnd(
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
        if livePlaybackChannel != nil {
            recoverLivePlaybackAfterFailure(requestID: requestID)
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
        if let requestID {
            presentPlaybackErrorOnce(message, requestID: requestID)
        } else {
            show(AppError.playback(message), title: "播放器错误")
        }
    }

    private func advanceAfterNaturalEnd(endedSessionID: UUID) async {
        guard playbackSessionID == endedSessionID,
              isPlayerPresented,
              livePlaybackChannel == nil,
              let playback = activePlayback,
              let nextEpisode = PlayerEpisodeAdvancePolicy.nextEpisode(
                  in: playback.source.episodes,
                  currentEpisodeID: playback.episode.id,
                  enabled: autoPlayNextEpisode
              ) else {
            return
        }
        await startPlayback(
            detail: playback.detail,
            source: playback.source,
            episode: nextEpisode,
            configurationID: playback.configurationID,
            windowActivation: .preserveFocus
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
            show(error, title: "恢复字幕设置失败")
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
            show(error, title: "无法保存字幕设置")
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
        guard presentedPlaybackErrorRequestIDs.insert(requestID).inserted else {
            return
        }
        // History recovery owns an actionable inline failure surface in the
        // player. Do not cover it with a modal alert attached to the window.
        if historyPlaybackRequestedItem != nil,
           activePlayerRequestID == requestID {
            return
        }
        show(AppError.playback(message), title: "播放器错误")
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
            throw AppError.playback("播放器环境不可用")
        }
        guard playbackSessionID == sessionID else {
            throw CancellationError()
        }
        let isTVBoxPlayback = providers[detail.summary.siteKey]?.capability
            == .javaDexSpider
        var scopedMedia = media
        if isTVBoxPlayback {
            scopedMedia.transportProfile = .tvBox
        }
        let authoritativeHistoryRecord = pendingPlayback?.origin.historyRecord
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
        let startPosition = Self.historyResumePosition(from: existing)
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
            }
        )
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        livePlaybackNavigationContext = nil
        selectedDetail = nil
        activePlayerRequestID = sessionID
        presentPlayer(
            requestID: sessionID,
            activation: .preserveFocus
        )
        let startupGate = isTVBoxPlayback
            ? nil
            : beginPlaybackStartupGate(requestID: sessionID)
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
            // A natural EOF can leave libmpv's pause/keep-open state latched
            // while the next episode is being resolved. Reassert autoplay
            // after file-loaded, then wait for actual media progress before
            // committing this resolver candidate as playable.
            try await environment.player.play()
            guard playbackSessionID == sessionID else {
                throw CancellationError()
            }
            if let startupGate {
                try await awaitPlaybackStartup(startupGate.stream)
                guard playbackSessionID == sessionID else {
                    throw CancellationError()
                }
            }
        } catch {
            if didReachFileLoaded {
                // The replacement is now the native active media. Stop waits
                // for its actual unload boundary before the fallback release.
                await environment.player.stop()
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
        try await savePlaybackHistory(
            position: startPosition ?? 0,
            duration: existing?.duration ?? 0
        )
    }

    private func savePlaybackHistory(
        position: TimeInterval,
        duration: TimeInterval,
        reloadHistoryAfterSaving: Bool = true
    ) async throws {
        guard let write = playbackHistoryWrite(
            position: position,
            duration: duration
        ) else { return }
        if !write.incognito, let activePlayback {
            historyPlaybackSessionCache.store(
                activePlayback,
                for: [write.record.id]
            )
        }
        try await persistPlaybackHistoryWrite(
            write,
            reloadHistoryAfterSaving: reloadHistoryAfterSaving
        )
        lastHistorySaveAt = Date()
    }

    private func playbackHistoryWrite(
        position: TimeInterval,
        duration: TimeInterval
    ) -> PlaybackHistoryWrite? {
        guard let playback = activePlayback else { return nil }
        let detail = playback.detail
        let providerResourceReference = playback.providerResourceReference
        let persistedVideoID = persistentHistoryVideoID(
            detail: detail,
            providerResourceReference: providerResourceReference
        )
        return PlaybackHistoryWrite(
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
                        .capability
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
            incognito: incognitoMode
        )
    }

    /// Capture the replay path at selection time. A crash, authorization
    /// prompt or provider failure after this point must not leave a progress
    /// row that knows the time but has forgotten how the episode was reached.
    private func persistHistoryNavigationSelection(
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        configurationID: UUID
    ) async {
        guard !incognitoMode, let environment else { return }
        let episodeIndex = source.episodes.firstIndex(where: {
            $0.id == episode.id
        }) ?? source.episodes.firstIndex(where: {
            $0.stableIdentity == episode.stableIdentity
        }) ?? 0
        let selectedProviderReference: PlaybackResourceReference?
        if let nodeProvider = providers[detail.summary.siteKey]
            as? NodeHTTPSpiderSiteProvider {
            selectedProviderReference = nodeProvider
                .captureHistoryPlaybackResourceReference(
                    videoID: detail.summary.videoID,
                    flag: source.name,
                    episode: episode,
                    episodeIndex: episodeIndex
                ) ?? episode.providerResourceReference
        } else {
            selectedProviderReference = episode.providerResourceReference
        }
        let persistedVideoID = persistentHistoryVideoID(
            detail: detail,
            providerResourceReference: selectedProviderReference
        )
        let candidateID = HistoryRecord(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            videoID: persistedVideoID,
            title: detail.summary.title,
            sourceKey: source.id
        ).id
        let existing = history.first(where: { $0.id == candidateID })
            ?? history.first(where: {
                $0.configurationID == configurationID
                    && $0.siteKey == detail.summary.siteKey
                    && ($0.videoID == persistedVideoID
                        || $0.videoID == detail.summary.videoID)
                    && Self.historyRecord($0, matches: source, episode: episode)
            })
        let position = existing?.position ?? 0
        let reference = Self.historyPlaybackReference(
            source: source,
            episode: episode,
            providerResourceReference: selectedProviderReference,
            navigationRecipe: Self.historyNavigationRecipe(
                detail: detail,
                source: source,
                episode: episode,
                configurationID: configurationID,
                position: position,
                persistedDetailID: persistedVideoID
            ),
            headers: [:]
        )
        let record = HistoryRecord(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            videoID: persistedVideoID,
            title: detail.summary.title,
            posterURL: detail.summary.posterURL,
            sourceKey: source.id,
            sourceName: source.name,
            episodeName: episode.name,
            episodeReference: Self.persistentHistoryEpisodeReference(
                episode.url,
                providerCapability: providers[detail.summary.siteKey]?
                    .capability
            ),
            playbackReference: reference,
            position: position,
            duration: existing?.duration ?? 0,
            watchedAt: existing?.watchedAt ?? Date()
        )
        do {
            if let existing, existing.id != record.id {
                try await environment.database.replaceHistory(
                    existing,
                    with: record,
                    incognito: false
                )
            } else {
                try await environment.database.saveHistory(
                    record,
                    incognito: false
                )
            }
            removeReplacedCatPawReplayReference(old: existing, new: record)
        } catch {
            if Self.catPawReplayLocator(in: existing ?? record)
                != Self.catPawReplayLocator(in: record) {
                removeCatPawReplayReferences(in: [record])
            } else if existing == nil {
                removeCatPawReplayReferences(in: [record])
            }
            // History persistence is best effort and must never block playback.
        }
    }

    private func persistPlaybackHistoryWrite(
        _ write: PlaybackHistoryWrite,
        reloadHistoryAfterSaving: Bool
    ) async throws {
        guard let environment else { return }
        if let original = activePlayback?.replacedHistoryRecord,
           original.id != write.record.id {
            try await environment.database.replaceHistory(
                original,
                with: write.record,
                incognito: write.incognito
            )
            if !write.incognito {
                removeReplacedCatPawReplayReference(
                    old: original,
                    new: write.record
                )
            }
            activePlayback?.replacedHistoryRecord = nil
        } else {
            try await environment.database.saveHistory(
                write.record,
                incognito: write.incognito
            )
        }
        if reloadHistoryAfterSaving, !write.incognito {
            try await reloadHistory()
        }
    }

    private func schedulePlaybackHistorySave(
        position: TimeInterval,
        duration: TimeInterval
    ) {
        guard let write = playbackHistoryWrite(
            position: position,
            duration: duration
        ) else { return }
        // Mark the request as accepted immediately so repeated snapshots while
        // paused cannot schedule a write for every UI update.
        lastHistorySaveAt = Date()
        pendingHistoryWrite = write
        guard historyPersistenceTask == nil else { return }
        historyPersistenceTask = Task { [weak self] in
            await self?.drainScheduledHistoryWrites()
        }
    }

    private func drainScheduledHistoryWrites() async {
        while let write = pendingHistoryWrite {
            pendingHistoryWrite = nil
            try? await persistPlaybackHistoryWrite(
                write,
                reloadHistoryAfterSaving: false
            )
        }
        historyPersistenceTask = nil
    }

    private func finishScheduledHistoryPersistence() async {
        await historyPersistenceTask?.value
    }

    private func loadPlayerAfterRenderSurfaceReady(
        _ media: ResolvedMedia,
        startPosition: TimeInterval?,
        requestID: UUID
    ) async throws {
        guard let environment else {
            throw AppError.playback("应用环境尚未初始化")
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
                guard self.isPlayerPresented,
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

    private func show(_ error: Error, title: String) {
        let presentation = userFacingError(for: error, title: title)
        if PlayerErrorPresentationPolicy.targetsPlayer(
            title: title,
            isPlayerPresented: isPlayerPresented
        ) {
            playerPresentedError = presentation
        } else {
            presentedError = presentation
        }
    }

    private func userFacingError(
        for error: Error,
        title: String
    ) -> UserFacingError {
        if let presentation = AndroidRuntimeUserFacingErrorMapper.presentation(
            for: error
        ) {
            return UserFacingError(
                title: presentation.title,
                message: presentation.message
            )
        }
        if let presentation = NodeUserFacingErrorMapper.presentation(for: error) {
            return UserFacingError(
                title: presentation.title,
                message: presentation.message
            )
        }
        return UserFacingError(
            title: title,
            message: LogRedactor.text(error.localizedDescription)
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
