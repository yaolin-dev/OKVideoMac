import AppKit
import CryptoKit
import Foundation
import OKVideoCore
import OKVideoPersistence

enum AppSection: String, CaseIterable, Identifiable {
    case home = "首页"
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
    case stopSearch
    case returnHome
}

enum BrowserEscapeRoutePolicy {
    static func action(
        isHomeSearchPresented: Bool,
        isSearching: Bool,
        hasBlockingPresentation: Bool
    ) -> BrowserEscapeAction {
        guard isHomeSearchPresented, !hasBlockingPresentation else {
            return .none
        }
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

struct CloudAuthorizationAction: Identifiable, Equatable {
    let id: String
    let title: String
    /// Provider-owned title before the host reconciles a persisted account
    /// status for display. Authorization verification must always inspect
    /// this value so presentation state cannot change provider semantics.
    let providerTitle: String
    let role: String?
    let generation: Int?

    init(
        id: String,
        title: String,
        providerTitle: String? = nil,
        role: String? = nil,
        generation: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.providerTitle = providerTitle ?? title
        self.role = role
        self.generation = generation
    }
}

enum CloudAccountSnapshotStatus: String, Codable, Equatable, Sendable {
    case authenticated
    case unauthenticated
    case pending
}

struct CloudAccountStatusKey: Codable, Equatable, Hashable, Sendable {
    let providerID: String
    let accountKey: String
}

struct CloudAccountStatusRecord: Codable, Equatable, Sendable {
    let key: CloudAccountStatusKey
    var status: CloudAccountSnapshotStatus
    var verifiedAt: Date
}

/// A credential-free, application-wide snapshot of cloud account state.
/// Android remains the sole owner of Cookie/Token data. This store persists
/// only provider/account identity, a tri-state result and its verification
/// time so equivalent providers can retain presentation state across source
/// configuration switches.
struct CloudAccountStatusStore: Codable, Equatable, Sendable {
    static let settingKey = "cloud.accountStatus.v1"

    private(set) var records: [CloudAccountStatusRecord] = []

    init(records: [CloudAccountStatusRecord] = []) {
        self.records = records
    }

    init?(setting: JSONValue) {
        guard case .string(let encoded) = setting,
              let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }

    var setting: JSONValue? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return .string(data.base64EncodedString())
    }

    func status(
        providerID: String,
        accountKey: String
    ) -> CloudAccountSnapshotStatus? {
        records.first(where: {
            $0.key == CloudAccountStatusKey(
                providerID: providerID,
                accountKey: accountKey
            )
        })?.status
    }

    func status(
        providerID: String,
        matchingAccountLabel accountLabel: String
    ) -> CloudAccountSnapshotStatus? {
        records
            .filter {
                $0.key.providerID == providerID
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
        providerID: String,
        explicitlyUnauthenticated: Bool = false,
        now: Date = Date()
    ) -> Bool {
        guard let parsed = CloudAccountStatusTitlePolicy.parse(title) else {
            return false
        }
        let key = CloudAccountStatusKey(
            providerID: providerID,
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
                providerID: providerID,
                accountKey: parsed.accountKey
            ) == .authenticated, !explicitlyUnauthenticated {
                return false
            }
            incoming = .unauthenticated
        case .pending:
            if status(
                providerID: providerID,
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
        providerID: String,
        accountKey: String,
        now: Date = Date()
    ) -> Bool {
        set(
            .authenticated,
            for: CloudAccountStatusKey(
                providerID: providerID,
                accountKey: accountKey
            ),
            verifiedAt: now
        )
    }

    @discardableResult
    mutating func invalidate(
        providerID: String,
        command: String,
        now: Date = Date()
    ) -> Bool {
        guard let fragments = CloudAccountStatusInvalidationPolicy
            .accountKeyFragments(for: command) else {
            return false
        }
        var changed = false
        for index in records.indices
        where records[index].key.providerID == providerID
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

    func reconciledTitle(_ title: String, providerID: String) -> String {
        guard let parsed = CloudAccountStatusTitlePolicy.parse(title),
              let stored = status(
                providerID: providerID,
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
            suffix = "正在确认"
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
            return "正在确认"
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
        providerID: String,
        store: CloudAccountStatusStore
    ) -> [SiteActionItem] {
        guard let status = store.status(
            providerID: providerID,
            matchingAccountLabel: accountLabel
        ) else { return items }
        return items.map { item in
            var updated = item
            updated.title = store.reconciledTitle(
                item.title,
                providerID: providerID
            )
            if let remarks = item.remarks {
                let reconciled = store.reconciledTitle(
                    remarks,
                    providerID: providerID
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

enum CloudAccountBridgeEvidencePolicy {
    static func isExplicitlyUnauthenticated(
        authenticated: Bool?,
        verificationPerformed: Bool?,
        error: String?
    ) -> Bool {
        authenticated == false
            && verificationPerformed == true
            && error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private extension AndroidBridgeUIElement {
    func replacingTitle(_ title: String) -> AndroidBridgeUIElement {
        AndroidBridgeUIElement(
            id: id,
            type: type,
            title: title,
            role: role,
            enabled: enabled,
            clickable: clickable,
            selected: selected,
            checked: checked,
            selectedIndex: selectedIndex,
            value: value,
            maximumValue: maximumValue,
            hint: hint,
            hasValue: hasValue,
            parentID: parentID,
            resourceName: resourceName,
            className: className,
            order: order,
            depth: depth,
            x: x,
            y: y,
            width: width,
            height: height
        )
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
        let request = ConfigurationInteractionRequest(
            interactionID: interactionID,
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

    func owns(_ interactionID: UUID) -> Bool {
        current?.request.interactionID == interactionID
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
                sourceIdentity: transaction.request.sourceIdentity,
                semantic: semantic,
                transport: transport ?? transaction.request.transport,
                title: transaction.request.title
            )
        } else if let transport {
            transaction.request = ConfigurationInteractionRequest(
                interactionID: transaction.request.interactionID,
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

enum CloudAuthorizationQRCodeState: String, Equatable {
    case idle
    case generating
    case ready
    case expired
    case notFound
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

struct CloudAuthorizationPrompt: Identifiable, Equatable {
    let id: UUID
    let interactionID: UUID
    var title: String
    var interactionKind: CloudInteractionKind
    var semantic: ConfigurationInteractionSemantic
    var transport: ConfigurationInteractionTransport
    var lifecyclePhase: ConfigurationInteractionPhase
    var presentationTarget: CloudAuthorizationPresentationTarget
    var qrState: CloudAuthorizationQRCodeState
    var status: String?
    var phase: String?
    var provider: String?
    var hasTextInput: Bool
    var usesSecureInput: Bool
    var credentialPush: Bool
    var displaysLoginQRCode: Bool
    var allowsRetry: Bool
    var actions: [CloudAuthorizationAction]
    var snapshot: Data?
    var uiSchemaVersion: Int? = nil
    var elements: [AndroidBridgeUIElement] = []
    var supportingTexts: [String] = []

    var structuredRows: [AndroidConfigurationSurfaceRow] {
        AndroidConfigurationSurfaceLayout.rows(elements: elements)
    }
}

struct NodeWebPresentation: Identifiable, Equatable {
    let id: UUID
    let sourceIdentity: HomeContentIdentity
    let url: URL
    let title: String
    let message: String
    var revision: Int
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
        let defaultKeys = Set(
            options.lazy.filter(\.isEnabledByDefault).map(\.key)
        )
        let explicitlyReenabledKeys = Set(
            options.lazy.filter(\.isUserDisabled).map(\.key)
        ).intersection(scope.selectedSiteKeys)
        switch scope.mode {
        case .all:
            return defaultKeys.union(explicitlyReenabledKeys)
        case .custom:
            return selectableKeys.intersection(scope.selectedSiteKeys)
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

struct HomeContentIdentity: Equatable, Sendable {
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

enum CloudAuthorizationCompletionPolicy {
    static func shouldComplete(
        authenticated: Bool,
        interactionKind: CloudInteractionKind,
        hasObservedPrompt: Bool,
        hasObservedQRCode: Bool,
        hiddenPollCount: Int
    ) -> Bool {
        // Retained only as a compatibility seam for older tests/callers. UI
        // visibility, a decoded QR image and a bridge authentication snapshot
        // are observations, not the terminal result of the request that
        // created the interaction. Success is published exclusively by the
        // request-scoped InteractionHandle terminal response (or by the
        // immediate provider call returning normally before a UI is created).
        // In particular, a window disappearing must never become success.
        false
    }
}

enum CloudAuthorizationPollingPolicy {
    static let maximumHiddenPollCount = 40
    static let maximumUnchangedSubmissionInterval: TimeInterval = 8
    static let minimumQRCodeExitPollCount = 3
    static let minimumQRCodeExitInterval: TimeInterval = 1

    static func shouldTimeOut(
        hiddenPollCount: Int,
        maximumHiddenPollCount: Int = maximumHiddenPollCount
    ) -> Bool {
        hiddenPollCount >= max(1, maximumHiddenPollCount)
    }

    static func shouldFailUnchangedSubmission(
        elapsed: TimeInterval,
        submittedGeneration: Int?,
        currentGeneration: Int?,
        hasObservedTransition: Bool,
        isVisible: Bool,
        maximumInterval: TimeInterval = maximumUnchangedSubmissionInterval
    ) -> Bool {
        guard isVisible,
              !hasObservedTransition,
              let submittedGeneration,
              let currentGeneration,
              submittedGeneration == currentGeneration else {
            return false
        }
        return elapsed >= max(0, maximumInterval)
    }

    static func shouldVerifyAfterQRCodeExit(
        hasObservedQRCode: Bool,
        currentStateIsQRCode: Bool,
        actionKind: ConfigurationInteraction.ActionKind?,
        consecutiveExitPollCount: Int,
        exitInterval: TimeInterval,
        hasGenerationTransition: Bool
    ) -> Bool {
        hasObservedQRCode
            && !currentStateIsQRCode
            && actionKind == .authorization
            && consecutiveExitPollCount >= minimumQRCodeExitPollCount
            && exitInterval >= minimumQRCodeExitInterval
            && hasGenerationTransition
    }

    static func isWaitingForProviderWorker(
        workerReturned: Bool?
    ) -> Bool {
        workerReturned != true
    }
}

enum MyDriveAuthorizationAccountStatus: Equatable, Sendable {
    case authenticated
    case unauthenticated
    case unknown
}

struct MyDriveAuthorizationTarget: Equatable, Sendable {
    let controlID: String?
    let accountKey: String
    let initialStatus: MyDriveAuthorizationAccountStatus
}

enum MyDriveAuthorizationVerificationDecision: Equatable, Sendable {
    case authenticated
    case unauthenticated
    case pending
}

/// MyDriveGuard exposes the account being authorized as a chooser row whose
/// stable identity remains the same when its suffix changes from 未登录 to
/// 已登录. A QR disappearing, an Android generation change, or the provider
/// worker returning is never account evidence on its own.
enum MyDriveAuthorizationVerificationPolicy {
    private static let authenticatedMarkers = ["已登录", "已登入", "已授权"]
    private static let unauthenticatedMarkers = ["未登录", "未登入", "未授权"]

    static func target(
        controlID: String?,
        title: String
    ) -> MyDriveAuthorizationTarget? {
        let initialStatus = status(in: title)
        guard initialStatus == .unauthenticated,
              let accountKey = accountKey(in: title) else {
            return nil
        }
        return MyDriveAuthorizationTarget(
            controlID: controlID?.nonEmpty,
            accountKey: accountKey,
            initialStatus: initialStatus
        )
    }

    static func decision(
        target: MyDriveAuthorizationTarget?,
        state: AndroidBridgeUIState
    ) -> MyDriveAuthorizationVerificationDecision {
        guard let target,
              target.initialStatus == .unauthenticated else {
            return .pending
        }
        let candidates = state.actionableControls.map {
            (id: Optional($0.id), title: $0.title)
        } + (state.texts ?? []).map {
            (id: Optional<String>.none, title: $0)
        } + (state.elements ?? []).map {
            (id: Optional($0.id), title: $0.title)
        }
        var observedUnauthenticated = false
        for candidate in candidates {
            let candidateStatus = status(in: candidate.title)
            guard candidateStatus != .unknown else { continue }
            let candidateAccountKey = accountKey(in: candidate.title)
            let sameAccount = candidateAccountKey == target.accountKey
            // Android view identifiers can be positional and may be reused
            // when the provider reconstructs its chooser. Prefer the account
            // identity whenever the title contains one; use the control only
            // for a generic status-only row.
            let sameStatusOnlyControl = candidateAccountKey == nil
                && target.controlID != nil
                && candidate.id == target.controlID
            guard sameAccount || sameStatusOnlyControl else { continue }
            if candidateStatus == .authenticated {
                return .authenticated
            }
            observedUnauthenticated = true
        }
        return observedUnauthenticated ? .unauthenticated : .pending
    }

    static func status(in title: String) -> MyDriveAuthorizationAccountStatus {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if unauthenticatedMarkers.contains(where: normalized.contains) {
            return .unauthenticated
        }
        if authenticatedMarkers.contains(where: normalized.contains) {
            return .authenticated
        }
        return .unknown
    }

    /// MyDriveGuard exposes every usable cloud account as a media category on
    /// its home response. Comparing stable category identifiers before and
    /// after an authorization attempt gives us a second authoritative signal
    /// when the legacy Android dialog destroys both the QR child and its
    /// chooser parent before the Mac can capture the changed account row.
    static func authorizedCategoryIDs(in home: SiteHome?) -> Set<String>? {
        guard let home else { return nil }
        return Set(
            home.categories
                .filter { $0.resolvedContentKind == .media }
                .map(\.id)
        )
    }

    static func confirmsNewAuthorizedCategory(
        baseline: Set<String>?,
        home: SiteHome
    ) -> Bool {
        guard let baseline else { return false }
        let current = authorizedCategoryIDs(in: home) ?? []
        return !current.subtracting(baseline).isEmpty
    }

    private static func accountKey(in title: String) -> String? {
        CloudAccountStatusTitlePolicy.accountKey(in: title)
    }
}

/// MyDrive's legacy QR dialogs can remain visible after the provider has
/// already persisted the account credential. The Android Bridge exposes only
/// an opaque preference digest. Require the changed digest to remain stable
/// across multiple polls so a transient/partial preference write cannot
/// complete the authorization by itself.
enum MyDriveAuthorizationStorageEvidencePolicy {
    static let requiredStablePollCount = 2

    /// Provider callbacks may not return until after the phone has completed
    /// authorization. Seed the digest before clicking the account row, then
    /// allow the first visible QR frame to replace it only while the provider
    /// worker is still active. This filters QR-generation writes without
    /// allowing a post-login digest to become the baseline.
    static func baselineAfterObservingQRCode(
        existing: String?,
        observed: String?,
        hadObservedQRCode: Bool,
        workerReturned: Bool?
    ) -> String? {
        guard let observed = observed?.nonEmpty else { return existing }
        if !hadObservedQRCode, workerReturned != true {
            return observed
        }
        return existing?.nonEmpty ?? observed
    }

    static func confirmsStableChange(
        baseline: String?,
        candidate: String?,
        stablePollCount: Int
    ) -> Bool {
        guard let baseline = baseline?.nonEmpty,
              let candidate = candidate?.nonEmpty,
              candidate != baseline else {
            return false
        }
        return stablePollCount >= requiredStablePollCount
    }

    /// Accumulates the same opaque post-QR digest across visible and hidden
    /// provider states. Some providers close their QR window immediately
    /// after persisting credentials, so limiting this observation to visible
    /// QR frames loses the only authoritative storage transition.
    static func updatedCandidate(
        baseline: String?,
        candidate: String?,
        stablePollCount: Int,
        observed: String?
    ) -> (fingerprint: String?, stablePollCount: Int) {
        guard let baseline = baseline?.nonEmpty,
              let observed = observed?.nonEmpty,
              observed != baseline else {
            return (nil, 0)
        }
        if candidate?.nonEmpty == observed {
            return (observed, max(0, stablePollCount) + 1)
        }
        return (observed, 1)
    }
}

/// Legacy CatVod commands and one-shot toggles persist inside their clicked
/// Android callback and often publish no second terminal response. Ordering
/// controls are different: arrow clicks mutate a draft dialog and only its
/// own save/cancel control is terminal. Treating every arrow as completion
/// closes the Mac surface after one move and loses the provider's draft.
enum ConfigurationControlSubmissionPolicy {
    static func acceptedClickCompletes(
        semantic: ConfigurationInteractionSemantic,
        controlTitle: String? = nil,
        controlRole: String? = nil
    ) -> Bool {
        switch semantic {
        case .command, .toggle: return true
        case .order:
            return isOrderingCommit(
                title: controlTitle,
                role: controlRole
            )
        default: return false
        }
    }

    static func acceptedClickCancels(
        controlTitle: String,
        controlRole: String?
    ) -> Bool {
        let value = normalizedControlText(
            title: controlTitle,
            role: controlRole
        )
        return ["取消", "关闭", "返回", "cancel", "close", "dismiss"]
            .contains(value)
    }

    private static func isOrderingCommit(
        title: String?,
        role: String?
    ) -> Bool {
        let value = normalizedControlText(title: title, role: role)
        return [
            "保存", "确定", "应用", "完成", "提交",
            "save", "confirm", "apply", "done", "submit"
        ].contains(value)
    }

    private static func normalizedControlText(
        title: String?,
        role: String?
    ) -> String {
        let normalizedRole = role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["cancel", "dismiss", "close", "save", "confirm", "apply"]
            .contains(normalizedRole) {
            return normalizedRole
        }
        return title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    static func completionStatus(
        semantic: ConfigurationInteractionSemantic
    ) -> String {
        switch semantic {
        case .order:
            return "排序已更新"
        case .toggle:
            return "设置已更新"
        default:
            return semantic.isAuthorization
                ? "授权成功，正在刷新网盘内容…"
                : "配置操作已完成"
        }
    }
}

enum ConfigurationInteractionVerificationDecision: Equatable, Sendable {
    case pending
    case verifySucceeded(refreshPerformed: Bool?)
    case verifyFailed(String)
    case terminalSucceeded
    case terminalFailed(String?)
    case terminalCancelled
}

/// Converts request-scoped bridge state into an explicit host action. Neither
/// UI visibility nor a generation change is a business result. A login flow
/// may be verified only after the provider's refreshed status explicitly says
/// that it is authenticated (or supplies an explicit verification error).
/// Other configuration commands remain owned by the provider worker's
/// terminal response.
enum ConfigurationInteractionVerificationPolicy {
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
        for state: AndroidBridgeUIState,
        semantic: ConfigurationInteractionSemantic
    ) -> ConfigurationInteractionVerificationDecision {
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

        guard state.hostUnavailable != true,
              state.verificationPerformed != true,
              (semantic == .qrAuthorization
                || semantic == .credentialAuthorization) else {
            return .pending
        }
        if state.authenticated == true {
            return .verifySucceeded(refreshPerformed: state.refreshPerformed)
        }
        if state.authenticated == false,
           let error = state.error?.nonEmpty {
            return .verifyFailed(error)
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
        case "command": return .command
        case "toggle": return .toggle
        case "choice": return .choice
        case "order": return .order
        // Legacy tags are presentation hints, not proof that the provider is
        // performing authorization. The live provider interaction must first
        // declare authorization and then expose verified login UI before the
        // host upgrades the prompt semantics.
        case "qr", "qr-authorization", "qrauthorization",
             "credential", "credentials":
            return .legacy
        case "web": return .web
        case "native": return .native
        default: return .legacy
        }
    }

    private static func structuralNativeSemantic(
        inputCount: Int,
        controlRoles: [String?]
    ) -> ConfigurationInteractionSemantic {
        let roles = controlRoles.compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if roles.contains(where: { $0 == "toggle" || $0 == "switch" }) {
            return .toggle
        }
        if roles.contains(where: { $0 == "order" || $0 == "reorder" }) {
            return .order
        }
        if !controlRoles.isEmpty { return .choice }
        return .native
    }

    static func nativeSemantic(
        interaction: ConfigurationInteraction?,
        hasVerifiedQRCode: Bool,
        credentialPush: Bool,
        state: AndroidBridgeUIState
    ) -> ConfigurationInteractionSemantic {
        // A bitmap merely being decodable as a QR code is not enough to call
        // an arbitrary configuration surface "authorization". The provider
        // must explicitly own an authorization interaction and identify the
        // image as its login QR code.
        if hasVerifiedQRCode,
           interaction?.actionKind == .authorization,
           interaction?.qrRole == .login {
            return .qrAuthorization
        }
        if interaction?.actionKind == .authorization,
           credentialPush {
            return .credentialAuthorization
        }
        switch interaction?.actionKind {
        case .command, .immediate:
            return .command
        case .toggle:
            return .toggle
        case .ordering:
            return .order
        case .webSetting:
            return .web
        case .nativeSetting:
            return .native
        case .configuration, .authorization, .playback, nil:
            break
        }
        let structuralSemantic = structuralNativeSemantic(
            inputCount: 0,
            controlRoles: state.actionableControls.map(\.role)
        )
        switch interaction?.phase {
        case .choice:
            switch structuralSemantic {
            case .toggle, .order:
                return structuralSemantic
            default:
                return .choice
            }
        case .form:
            switch structuralSemantic {
            case .toggle, .order, .choice:
                return structuralSemantic
            default:
                return .native
            }
        case .qrCode:
            // Candidate/helper/credential-push images remain generic native
            // configuration UI. Only the explicit login case above is auth.
            return .native
        case .invoking, .transitioning, .reattaching, .status, .completed, .failed,
             .cancelled, nil:
            return structuralSemantic
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

private enum PendingCloudOperation {
    case playback(PendingCloudPlayback)
    case detail(VideoSummary)
    case homeAction(SiteActionItem)
    case siteAction(action: String, title: String)

    var pendingPlayback: PendingCloudPlayback? {
        guard case .playback(let playback) = self else { return nil }
        return playback
    }

    var playbackRequestID: UUID? {
        pendingPlayback?.requestID
    }

    var initialSemantic: ConfigurationInteractionSemantic {
        switch self {
        case .playback, .siteAction:
            return .legacy
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
        case .siteAction(let action, _):
            return action
        }
    }
}

private struct CloudAuthorizationContext {
    let sourceIdentity: HomeContentIdentity
    let operationID: UUID
    /// Exact capability binding returned by the Bridge for this interaction.
    /// The host stores it only for the live prompt and returns it verbatim;
    /// source/provider labels never select a credential target.
    var providerOwnerID: String?
    var actionContract: JSONValue?
    var providerHandle: InteractionHandle?
    var providerInteraction: ConfigurationInteraction?
    var operation: PendingCloudOperation
    var submittedAt: Date?
    /// First request-scoped observation that the provider is waiting for a
    /// login QR. Unlike `submittedAt`, this also covers providers that open a
    /// QR directly from `play()` without a preceding chooser click.
    var qrExpectedAt: Date?
    var submittedGeneration: Int?
    var hasObservedPrompt: Bool
    var hasObservedQRCode: Bool
    var lastObservedQRCodeGeneration: Int?
    var hasObservedPostSubmissionTransition: Bool
    var lastObservedRevision: Int?
    var hasRequestedVerification: Bool
    var lastAuthorizationProbeAt: Date?
    /// Exact chooser row selected before MyDriveGuard displayed a login QR.
    /// A later QR/window transition is successful only when this same account
    /// is observed as authenticated.
    var myDriveAuthorizationTarget: MyDriveAuthorizationTarget?
    /// Stable media-category identifiers visible before the selected account
    /// opened its QR. A newly available category after the worker returns is
    /// accepted as authorization evidence when the legacy chooser disappears.
    var myDriveAuthorizedCategoryIDsAtStart: Set<String>?
    /// Opaque Android preference digest captured once the selected account's
    /// QR is visible. A later stable change proves provider auth storage was
    /// updated even when the legacy QR dialog never closes.
    var myDriveAuthorizationStorageFingerprintAtQRCode: String?
    var myDriveAuthorizationStorageCandidateFingerprint: String?
    var myDriveAuthorizationStorageStablePollCount: Int
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

private struct PendingPlaybackStartupGate {
    let identity: UUID
    let continuation: AsyncThrowingStream<Void, Error>.Continuation
    let timeoutTask: Task<Void, Never>
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
        targetEndpoint: URL?,
        ownsCurrentRequest: Bool
    ) -> Bool {
        ownsCurrentRequest && targetEndpoint == nil
    }
}

private struct PreparedConfigurationActivation {
    var record: StoredConfiguration
    let configuration: FongMiConfiguration
    let nodeRuntimeEndpoint: URL?
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
    @Published private(set) var homeLoadErrorMessage: String?
    @Published private(set) var hasCompletedStartup = false
    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var selectedCategoryFilters: [String: String] = [:]
    @Published private(set) var categoryPage: VideoPage?
    @Published private(set) var homePresentationSelection:
        HomePresentationSelection = .empty
    @Published var searchKeyword = ""
    @Published private(set) var homeToolbarSearchFocusRequest: UInt64 = 0
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
    @Published private(set) var incognitoMode = false
    @Published private(set) var historyRetentionDays = 60
    @Published private(set) var appTheme: AppTheme = .system
    @Published private(set) var favoriteLiveChannelIDs: Set<String> = []
    @Published private(set) var deletedLiveChannelIDs: Set<String> = []
    @Published private(set) var playerSnapshot = PlayerSnapshot()
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
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextCategoryPage = false
    @Published private(set) var categoryPaginationError: String?
    @Published var presentedError: UserFacingError?
    @Published var playerPresentedError: UserFacingError?
    @Published var cloudAuthorizationPrompt: CloudAuthorizationPrompt?
    @Published var cloudAuthorizationInput = ""
    @Published private(set) var nodeWebPresentation: NodeWebPresentation?
    @Published private(set) var configurationCategoryPresentation:
        ConfigurationCategoryPresentation?
    @Published private(set) var androidRuntimeStatus: AndroidRuntimeStatus = .checking
    @Published private(set) var androidRuntimeContinuityStatus:
        AndroidRuntimeContinuityStatus = .checking
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

    private let environment: AppEnvironment?
    private let playerRenderSurfaceGate = PlayerRenderSurfaceReadinessGate()
    private var configurationImportOperationID: UUID?
    private var configurationActivationTracker =
        ConfigurationActivationRequestTracker()
    private var configurationActivationTask: Task<Void, Never>?
    private var configurationSwitchFeedbackDismissTask: Task<Void, Never>?
    private var providers: [String: SiteProvider] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchSessionGate = SearchSessionGate()
    private var unsupportedNodeSearchRouteIdentities = Set<String>()
    private var detailLoadSessionID = UUID()
    private var homeLoadSessionID = UUID()
    private var homeContentIdentity: HomeContentIdentity?
    private var categoryLoadSessionID = UUID()
    private var configurationCategoryLoadSessionID = UUID()
    private var playerEventTask: Task<Void, Never>?
    private var activeSeekConfirmationID: UUID?
    private var cloudAuthorizationPollTask: Task<Void, Never>?
    private var cloudAuthorizationSessionID = UUID()
    private var configurationInteractionCoordinator =
        ConfigurationInteractionCoordinator()
    private var configurationInteractionDismissTask: Task<Void, Never>?
    private var configurationInteractionTerminalTask: Task<Void, Never>?
    private var activePlayback: ActivePlaybackContext?
    private var pendingPlayback: PendingCloudPlayback?
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
    private var pendingPlaybackStartupGates:
        [UUID: PendingPlaybackStartupGate] = [:]
    private var presentedPlaybackErrorRequestIDs = Set<UUID>()
    private var playbackRequestsResolving = Set<UUID>()
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

    private init(
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

            if activeConfigurationUsesNodeRuntime {
                do {
                    try await prepareActiveNodeConfigurationIfNeeded()
                    try loadActiveConfigurationContent()
                } catch {
                    activeNodeRuntimeEndpoint = nil
                    nodeRuntimeUnavailableReason = error.localizedDescription
                    rebuildProviders()
                    show(error, title: "Node Runtime 启动失败")
                }
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
                Task { @MainActor [weak self] in
                    guard let self, !self.activeConfigurationUsesNodeRuntime else {
                        return
                    }
                    await environment.nodeBundleRuntime.stop()
                }
            }
            rebuildProviders()
            selectedSiteKey = HomeLandingSitePolicy.defaultSiteKey(
                from: supportedSites
            )
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
                targetEndpoint: prepared.nodeRuntimeEndpoint,
                ownsCurrentRequest: configurationActivationTracker.owns(token)
            ) {
                // This is cleanup owned by the latest committed non-Node
                // selection, never by a stale task. The actor call is queued
                // before MainActor can accept another selection, so a newer
                // Node startup can only begin after this stop completes.
                await environment.nodeBundleRuntime.stop()
                try ensureConfigurationActivationIsCurrent(token)
            }
            await loadSearchSiteScope()
            try ensureConfigurationActivationIsCurrent(token)
            _ = await prepareActiveConfigurationHome(
                reportLoadErrors: false,
                loadBehavior: .awaited,
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
        guard let environment else {
            throw AppError.configuration("应用环境尚未初始化")
        }
        if record.sourceKind == .remote,
           let sourceValue = record.sourceValue,
           let sourceURL = URL(string: sourceValue),
           NodeBundleRuntimeService.supports(sourceURL) {
            let loaded = try await environment.nodeBundleRuntime
                .loadConfiguration(
                    from: sourceURL,
                    configurationID: record.id
                )
            try Task.checkCancellation()
            var updated = record
            updated.baseURL = loaded.baseURL
            updated.rawData = loaded.rawData
            updated.updatedAt = loaded.loadedAt
            return PreparedConfigurationActivation(
                record: updated,
                configuration: loaded.configuration,
                nodeRuntimeEndpoint: loaded.baseURL
            )
        }
        return PreparedConfigurationActivation(
            record: record,
            configuration: try ConfigurationParser().parse(record.rawData),
            nodeRuntimeEndpoint: nil
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
        nodeRuntimeUnavailableReason = prepared.nodeRuntimeEndpoint == nil
            ? "Node Runtime 未用于当前配置"
            : ""
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

    func deleteConfiguration(_ id: UUID) async {
        guard let environment else { return }
        clearConfigurationSwitchFeedback()
        let deletingActiveConfiguration = activeConfigurationRecord?.id == id
        do {
            try await environment.database.deleteConfiguration(id: id)
            if deletingActiveConfiguration {
                resetSearchForConfigurationChange()
            }
            configurations = try await environment.database.configurations()
            if activeConfigurationRecord?.id == id {
                activeConfigurationRecord = try await environment.database.activeConfiguration()
                selectedSiteKey = nil
                try await prepareActiveNodeConfigurationIfNeeded()
                try loadActiveConfigurationContent()
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

    func selectSite(_ key: String) async {
        invalidatePendingNodeHomeOperation(nextSiteKey: key)
        cancelActiveCloudAuthorizationInteraction(
            nextIdentity: activeConfigurationRecord.map {
                HomeContentIdentity(configurationID: $0.id, siteKey: key)
            }
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
            categoryPage = nil
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
            if let providerID = CloudAccountProviderIdentity.identifier(
                capability: provider.capability,
                api: provider.site.api
            ) {
                updatedHome.actionItems = CloudAccountStatusPresentationPolicy
                    .applying(
                        to: updatedHome.actionItems,
                        accountLabel: actionCategory.name,
                        providerID: providerID,
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
            openSearchFolder(summary, replacingPath: true)
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
                selectedDetail = nil
                presentHomeSearch()
                search(query, context: .discoveryFallback)
            case .action(let result):
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
        } catch {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            show(error, title: "详情加载失败")
        }
    }

    func openHomeItem(_ summary: VideoSummary) async {
        let site = supportedSites.first { $0.key == summary.siteKey }
        switch HomeItemRoutePolicy.route(summary: summary, site: site) {
        case .action:
            await performHomeAction(SiteActionItem(summary: summary))
        case .folder:
            openSearchFolder(summary, replacingPath: true)
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
            await performSiteAction(action, title: item.title, provider: provider)
            return
        case .providerSelection:
            break
        }
        let operation = PendingCloudOperation.homeAction(item)
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
        }
        let interactionID: UUID?
        if provider.capability == .javaDexSpider {
            guard let begunInteractionID = beginConfigurationInteraction(
                title: item.title,
                siteKey: item.siteKey,
                operation: operation,
                semantic: operation.initialSemantic
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
                    completeConfigurationInteraction(
                        interactionID,
                        status: Self.siteActionMessage(result)
                            ?? "配置操作已完成"
                    )
                    scheduleConfigurationInteractionDismiss(interactionID)
                } else {
                    presentedError = UserFacingError(
                        title: item.title,
                        message: Self.siteActionMessage(result)
                            ?? Self.unsupportedSiteActionMessage
                    )
                }
            case .search(let query):
                if let interactionID,
                   configurationInteractionCoordinator.owns(interactionID) {
                    completeConfigurationInteraction(interactionID)
                    scheduleConfigurationInteractionDismiss(interactionID)
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
            if let interactionID,
               !configurationInteractionCoordinator.owns(interactionID) {
                authorization.handle?.cancel()
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
            openSearchFolder(summary, replacingPath: true)
        } else {
            Task { await loadDetail(summary) }
        }
    }

    func openSearchFolderItem(_ summary: VideoSummary) {
        if summary.isFolder {
            openSearchFolder(summary, replacingPath: false)
        } else {
            Task { await loadDetail(summary) }
        }
    }

    func closeSearchFolder() {
        searchFolderPath = []
    }

    func navigateBackSearchFolder() {
        guard !searchFolderPath.isEmpty else { return }
        searchFolderPath.removeLast()
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

    private func performSiteAction(
        _ action: String,
        title: String,
        provider: SiteProvider
    ) async {
        let operation = PendingCloudOperation.siteAction(
            action: action,
            title: title
        )
        if provider.capability == .javaDexSpider {
            await supersedeConfigurationInteractionIfNeeded()
        }
        let interactionID: UUID?
        if provider.capability == .javaDexSpider {
            guard let begunInteractionID = beginConfigurationInteraction(
                title: title,
                siteKey: provider.site.key,
                operation: operation,
                semantic: operation.initialSemantic
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
                    interactionID: interactionID
                )
            } else {
                result = try await provider.action(action)
            }
            await invalidatePersistedCloudAccountStatus(
                provider: provider,
                command: action
            )
            if let interactionID {
                guard configurationInteractionCoordinator.owns(interactionID) else {
                    return
                }
                completeConfigurationInteraction(
                    interactionID,
                    status: Self.siteActionMessage(result)
                        ?? "配置操作已完成"
                )
                scheduleConfigurationInteractionDismiss(interactionID)
            } else {
                let message = Self.siteActionMessage(result)
                    ?? Self.unsupportedSiteActionMessage
                presentedError = UserFacingError(title: title, message: message)
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
            if let interactionID,
               !configurationInteractionCoordinator.owns(interactionID) {
                authorization.handle?.cancel()
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
        phase: ConfigurationInteractionPhase = .invoking
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
        cloudAuthorizationContext = CloudAuthorizationContext(
            sourceIdentity: identity,
            operationID: request.interactionID,
            providerOwnerID: nil,
            actionContract: nil,
            providerHandle: providerHandle,
            providerInteraction: providerInteraction,
            operation: operation,
            submittedAt: nil,
            qrExpectedAt: nil,
            submittedGeneration: nil,
            hasObservedPrompt: false,
            hasObservedQRCode: false,
            lastObservedQRCodeGeneration: nil,
            hasObservedPostSubmissionTransition: false,
            lastObservedRevision: nil,
            hasRequestedVerification: false,
            lastAuthorizationProbeAt: nil,
            myDriveAuthorizationTarget: nil,
            myDriveAuthorizedCategoryIDsAtStart: nil,
            myDriveAuthorizationStorageFingerprintAtQRCode: nil,
            myDriveAuthorizationStorageCandidateFingerprint: nil,
            myDriveAuthorizationStorageStablePollCount: 0
        )
        cloudAuthorizationPrompt = CloudAuthorizationPrompt(
            id: UUID(),
            interactionID: request.interactionID,
            title: title,
            interactionKind: ConfigurationInteractionClassificationPolicy
                .interactionKind(for: resolvedSemantic),
            semantic: resolvedSemantic,
            transport: .native,
            lifecyclePhase: phase,
            presentationTarget: cloudAuthorizationPresentationTarget(
                for: operation
            ),
            qrState: .idle,
            status: phase == .invoking
                ? "正在执行配置操作…"
                : "正在等待站点创建下一步操作界面…",
            phase: nil,
            provider: nil,
            hasTextInput: false,
            usesSecureInput: false,
            credentialPush: false,
            displaysLoginQRCode: false,
            allowsRetry: false,
            actions: [],
            snapshot: nil
        )
        return request.interactionID
    }

    /// Retires the previous request before reserving a new native interaction.
    /// Waiting is bounded so a broken compatibility bridge cannot freeze the
    /// main actor, while a responsive bridge gets a chance to remove its old UI.
    private func supersedeConfigurationInteractionIfNeeded() async {
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
        await withTaskGroup(of: Void.self) { group in
            if let providerHandle {
                group.addTask { await providerHandle.cancelAndWait() }
            } else if usesLegacyBridge, let bridge {
                group.addTask { try? await bridge.resetAuthorizationUI() }
            } else {
                return
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
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
              prompt.interactionID == interactionID else {
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
        if phase == .processing || phase == .completed || phase == .failed {
            prompt.actions = []
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

    private func scheduleConfigurationInteractionDismiss(
        _ interactionID: UUID,
        delayNanoseconds: UInt64 = 900_000_000
    ) {
        configurationInteractionDismissTask?.cancel()
        configurationInteractionDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self,
                  self.configurationInteractionCoordinator.owns(interactionID),
                  self.cloudAuthorizationPrompt?.lifecyclePhase == .completed else {
                return
            }
            self.clearCloudAuthorization(
                resetBridgeUI: false,
                markPendingPlaybackCancelled: false
            )
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
              cloudAuthorizationContext?.operationID == context.operationID,
              ConfigurationInteractionVerificationPolicy.accepts(
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
        return true
    }

    /// Returns true when the state is terminal/being verified and therefore
    /// must not be interpreted as a missing or hidden window by the poller.
    private func consumeConfigurationVerificationState(
        _ state: AndroidBridgeUIState,
        context: CloudAuthorizationContext
    ) async -> Bool {
        let semantic = cloudAuthorizationPrompt?.semantic
            ?? context.operation.initialSemantic
        let decision = ConfigurationInteractionVerificationPolicy.decision(
            for: state,
            semantic: semantic
        )
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
        case .verifySucceeded, .verifyFailed:
            guard let handle = context.providerHandle else {
                switch decision {
                case .verifySucceeded:
                    await finishCloudAuthorizationAndRetry()
                case .verifyFailed(let message):
                    failConfigurationInteraction(
                        context.operationID,
                        message: message
                    )
                default:
                    break
                }
                return true
            }
            if cloudAuthorizationContext?.hasRequestedVerification == true {
                return true
            }
            if var current = cloudAuthorizationContext,
               current.operationID == context.operationID {
                current.hasRequestedVerification = true
                cloudAuthorizationContext = current
            }
            transitionConfigurationInteraction(
                context.operationID,
                to: .processing,
                status: "已验证站点状态，正在完成当前配置操作…"
            )
            switch decision {
            case .verifySucceeded(let refreshPerformed):
                await Self.verifyScopedConfigurationInteraction(
                    handle,
                    succeeded: true,
                    actualRefreshPerformed: refreshPerformed
                )
            case .verifyFailed(let message):
                await Self.verifyScopedConfigurationInteraction(
                    handle,
                    succeeded: false,
                    error: message,
                    actualRefreshPerformed: state.refreshPerformed
                )
            default:
                return true
            }
            return true
        }
    }

    /// A scoped verification and its still-running provider invocation share
    /// one terminal owner inside `InteractionHandle`. The handle publishes the
    /// provider response (or a bounded verified fallback) to the observer that
    /// was installed when the native UI was presented. Returning that response
    /// to this polling call and processing it here as well would create two
    /// competing AppState continuations and could discard `providerResult`.
    static func verifyScopedConfigurationInteraction(
        _ handle: InteractionHandle,
        succeeded: Bool,
        error: String? = nil,
        actualRefreshPerformed: Bool? = nil,
        providerResultGraceNanoseconds: UInt64 = 3_000_000_000
    ) async {
        do {
            _ = try await handle.verify(
                succeeded: succeeded,
                error: error,
                actualRefreshPerformed: actualRefreshPerformed,
                providerResultGraceNanoseconds: providerResultGraceNanoseconds
            )
        } catch {
            // `InteractionHandle.verify` already atomically installed this
            // failure in the request terminal state. Only the observer created
            // when the interaction was presented may consume that terminal;
            // handling it again in this polling path would publish twice.
        }
    }

    private func presentNodeConfiguration(
        _ authorization: NodeWebAuthorizationRequired,
        pending: PendingNodeOperation
    ) {
        pendingNodeOperation = pending
        nodeWebPresentation = NodeWebPresentation(
            id: UUID(),
            sourceIdentity: pending.sourceIdentity,
            url: authorization.websiteURL,
            title: authorization.title.nonEmpty ?? "网盘配置中心",
            message: authorization.message,
            revision: 0
        )
    }

    func refreshNodeConfigurationWebsite() {
        guard var presentation = nodeWebPresentation else { return }
        presentation.revision &+= 1
        nodeWebPresentation = presentation
    }

    func cancelNodeConfiguration() {
        if case .playback = pendingNodeOperation {
            // User cancellation is a neutral terminal state. Do not turn it
            // into a playback failure that can later surface as a stale alert.
            playbackResolutionState = .idle
            playbackFailureSummary = nil
        }
        pendingNodeOperation = nil
        nodeWebPresentation = nil
    }

    func completeNodeConfigurationAndRetry() async {
        let pending = pendingNodeOperation
        let presentation = nodeWebPresentation
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        guard let pending, let presentation else { return }
        if activeConfigurationUsesNodeRuntime {
            // Configuration/login pages can add dynamic AList mounts or alter
            // the enabled site list. Re-read the local CatPawOpen catalogue
            // before deciding whether the original operation still exists.
            _ = await refreshActiveConfigurationIfNeeded(
                force: true,
                reportErrors: false
            )
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
            return
        }
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
                windowActivation: .preserveFocus
            )
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

    private func cloudAccountProviderID(
        for context: CloudAuthorizationContext
    ) -> String? {
        guard let provider = providers[context.sourceIdentity.siteKey] else {
            return nil
        }
        return CloudAccountProviderIdentity.identifier(
            capability: provider.capability,
            api: provider.site.api
        )
    }

    /// Reconciles provider UI labels with the credential-free global snapshot.
    /// Empty/transitional legacy UI does not alter a confirmed account. A
    /// downgrade is accepted only when the Bridge returns a completed failed
    /// credential verification with an error, or when a clear/logout command
    /// succeeds. The current UI capture's default `authenticated: false` is
    /// transitional metadata and must never revoke a confirmed login.
    private func observeCloudAccountStatuses(
        in state: AndroidBridgeUIState,
        context: CloudAuthorizationContext
    ) async -> String? {
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              let providerID = cloudAccountProviderID(for: context) else {
            return nil
        }
        let titles = state.actionableControls.map(\.title)
            + (state.texts ?? [])
            + (state.elements ?? []).map(\.title)
        var changed = false
        let explicitlyUnauthenticated = CloudAccountBridgeEvidencePolicy
            .isExplicitlyUnauthenticated(
                authenticated: state.authenticated,
                verificationPerformed: state.verificationPerformed,
                error: state.error
            )
        for title in Set(titles) {
            changed = cloudAccountStatusStore.observe(
                title: title,
                providerID: providerID,
                explicitlyUnauthenticated: explicitlyUnauthenticated
            ) || changed
        }
        if state.authenticated == true,
           let target = context.myDriveAuthorizationTarget {
            changed = cloudAccountStatusStore.confirmAuthenticated(
                providerID: providerID,
                accountKey: target.accountKey
            ) || changed
        }
        if changed {
            await persistCloudAccountStatusStore()
        }
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID else {
            return nil
        }
        return providerID
    }

    private func confirmCloudAccountStatus(
        for context: CloudAuthorizationContext
    ) async {
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              let target = context.myDriveAuthorizationTarget,
              let providerID = cloudAccountProviderID(for: context) else {
            return
        }
        let changed = cloudAccountStatusStore.confirmAuthenticated(
            providerID: providerID,
            accountKey: target.accountKey
        )
        if changed {
            await persistCloudAccountStatusStore()
        }
        await reconcileVisibleCloudAccountStatus(
            accountLabel: target.accountKey,
            providerID: providerID,
            context: context
        )
    }

    private func reconcileVisibleCloudAccountStatus(
        accountLabel: String,
        providerID: String,
        context: CloudAuthorizationContext
    ) async {
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              currentHomeContentIdentity == context.sourceIdentity,
              homeContentIdentity == context.sourceIdentity,
              var updatedHome = siteHome else {
            return
        }
        updatedHome.actionItems = CloudAccountStatusPresentationPolicy.applying(
            to: updatedHome.actionItems,
            accountLabel: accountLabel,
            providerID: providerID,
            store: cloudAccountStatusStore
        )
        publishHomeContent(updatedHome, identity: context.sourceIdentity)
        await cacheSiteHome(updatedHome, identity: context.sourceIdentity)
    }

    private func invalidatePersistedCloudAccountStatus(
        provider: SiteProvider,
        command: String
    ) async {
        guard let providerID = CloudAccountProviderIdentity.identifier(
            capability: provider.capability,
            api: provider.site.api
        ), cloudAccountStatusStore.invalidate(
            providerID: providerID,
            command: command
        ) else {
            return
        }
        await persistCloudAccountStatusStore()
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
        configurationInteractionDismissTask?.cancel()
        configurationInteractionDismissTask = nil
        configurationInteractionTerminalTask?.cancel()
        configurationInteractionTerminalTask = nil
        if cancelProviderHandle {
            providerHandle?.cancel()
        }
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        cloudAuthorizationPrompt = nil
        cloudAuthorizationInput = ""
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

    func submitCloudAuthorization(action: CloudAuthorizationAction) async {
        guard let environment,
              let context = cloudAuthorizationContext,
              configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationPrompt?.lifecyclePhase == .presenting,
              isCurrentCloudAuthorizationContext(context) else {
            cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
            return
        }
        let submissionSemantic = cloudAuthorizationPrompt?.semantic
            ?? context.operation.initialSemantic
        let controlID = action.id.hasPrefix("legacy:")
            ? nil
            : action.id
        if myDriveLoginStatusAction(for: context) != nil,
           let target = MyDriveAuthorizationVerificationPolicy.target(
                controlID: controlID,
                title: action.providerTitle
           ) {
            // The legacy provider's submit call can remain suspended until
            // after the phone has scanned the QR and credentials are already
            // persisted. Stage the exact row and pre-click storage digest
            // before entering that call; doing this after `submit` returns
            // records the successful credential as the baseline and makes the
            // UI wait forever despite a completed login.
            let baselineState = try? await configurationInteractionState(
                for: context
            )
            guard configurationInteractionCoordinator.owns(context.operationID),
                  var current = cloudAuthorizationContext,
                  current.operationID == context.operationID else {
                return
            }
            current.myDriveAuthorizationTarget = target
            current.myDriveAuthorizedCategoryIDsAtStart =
                currentHomeContentIdentity == context.sourceIdentity
                    ? MyDriveAuthorizationVerificationPolicy
                        .authorizedCategoryIDs(in: siteHome)
                    : nil
            current.myDriveAuthorizationStorageFingerprintAtQRCode =
                baselineState?.authorizationStorageFingerprint?.nonEmpty
            current.myDriveAuthorizationStorageCandidateFingerprint = nil
            current.myDriveAuthorizationStorageStablePollCount = 0
            cloudAuthorizationContext = current
        }
        transitionConfigurationInteraction(
            context.operationID,
            to: .submitting,
            status: "正在提交“\(action.title)”…"
        )
        do {
            let text = cloudAuthorizationInput.nonEmpty
            let result: AndroidBridgeUISubmitResult
            if let handle = context.providerHandle {
                result = try await handle.submit(
                    text: text,
                    button: action.title,
                    controlID: controlID,
                    generation: action.generation
                )
            } else {
                result = try await environment.androidDexBridge.submitUI(
                    text: text,
                    button: action.title,
                    controlID: controlID,
                    generation: action.generation,
                    interactionID: nil
                )
            }
            guard configurationInteractionCoordinator.owns(context.operationID),
                  cloudAuthorizationContext?.operationID == context.operationID else {
                return
            }
            if result.stale {
                if let state = try? await configurationInteractionState(
                    for: context
                ), acceptConfigurationInteractionState(state, context: context) {
                    if await consumeConfigurationVerificationState(
                        state,
                        context: context
                    ) {
                        return
                    }
                    if state.isAuthorizationPrompt {
                        await updateCloudAuthorizationPrompt(state)
                    }
                }
                throw AppError.spider("操作界面已经更新，请使用刷新后的按钮继续")
            }
            guard result.clicked else {
                throw AppError.spider(
                    "后台授权窗口中没有找到“\(action.title)”按钮"
                )
            }
            if ConfigurationControlSubmissionPolicy.acceptedClickCancels(
                controlTitle: action.title,
                controlRole: action.role
            ) {
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .user,
                    cancelProviderHandle: false
                )
                return
            }
            if ConfigurationControlSubmissionPolicy.acceptedClickCompletes(
                semantic: submissionSemantic,
                controlTitle: action.title,
                controlRole: action.role
            ) {
                if var current = cloudAuthorizationContext,
                   current.operationID == context.operationID {
                    current.hasRequestedVerification = true
                    cloudAuthorizationContext = current
                }
                transitionConfigurationInteraction(
                    context.operationID,
                    to: .processing,
                    semantic: submissionSemantic,
                    status: submissionSemantic == .order
                        ? "排序操作已提交，正在保存…"
                        : "设置操作已提交，正在保存…"
                )
                if let handle = context.providerHandle {
                    await Self.verifyScopedConfigurationInteraction(
                        handle,
                        succeeded: true
                    )
                } else {
                    await finishCloudAuthorizationAndRetry()
                }
                return
            }
            if var current = cloudAuthorizationContext,
               current.operationID == context.operationID {
                current.submittedAt = Date()
                current.submittedGeneration = action.generation
                    ?? result.generation
                current.hasObservedPostSubmissionTransition = false
                cloudAuthorizationContext = current
            }
            transitionConfigurationInteraction(
                context.operationID,
                to: .processing,
                status: "命令已提交，正在等待站点返回结果…"
            )
            try await Task.sleep(nanoseconds: 250_000_000)
            guard configurationInteractionCoordinator.owns(context.operationID),
                  cloudAuthorizationContext?.operationID == context.operationID else {
                return
            }
            var consumedState = false
            var displayedPromptState = false
            if let state = try? await configurationInteractionState(for: context),
               acceptConfigurationInteractionState(state, context: context) {
                consumedState = await consumeConfigurationVerificationState(
                    state,
                    context: context
                )
                if !consumedState, state.isAuthorizationPrompt {
                    displayedPromptState = true
                    await updateCloudAuthorizationPrompt(state)
                }
            }
            if !consumedState, !displayedPromptState,
               var prompt = cloudAuthorizationPrompt {
                prompt.status = "正在等待下一步配置界面或最终结果…"
                prompt.phase = "transitioning"
                prompt.lifecyclePhase = .processing
                cloudAuthorizationPrompt = prompt
            }
            if configurationInteractionCoordinator.owns(context.operationID) {
                startCloudAuthorizationPolling()
            }
        } catch is CancellationError {
            guard configurationInteractionCoordinator.owns(context.operationID) else {
                return
            }
            clearCloudAuthorization(
                resetBridgeUI: false,
                markPendingPlaybackCancelled: false,
                cancellationReason: .providerCancelled
            )
        } catch {
            if AsyncCancellationPolicy.isCancellation(error) {
                guard configurationInteractionCoordinator.owns(context.operationID) else {
                    return
                }
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
                return
            }
            failConfigurationInteraction(
                context.operationID,
                message: error.localizedDescription
            )
        }
    }

    func submitCloudCredential() async {
        guard let context = cloudAuthorizationContext,
              configurationInteractionCoordinator.owns(context.operationID),
              isCurrentCloudAuthorizationContext(context) else {
            cancelActiveCloudAuthorizationInteraction(nextIdentity: nil)
            return
        }
        guard let environment,
              let prompt = cloudAuthorizationPrompt,
              prompt.credentialPush,
              let providerOwnerID = context.providerOwnerID?.nonEmpty,
              let actionContract = context.actionContract else {
            return
        }
        let credential = cloudAuthorizationInput
        guard credential.nonEmpty != nil else {
            failConfigurationInteraction(
                context.operationID,
                message: "请先粘贴 Cookie 或 Token"
            )
            return
        }

        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        transitionConfigurationInteraction(
            context.operationID,
            to: .submitting,
            status: "正在安全提交凭据…"
        )
        do {
            try await environment.androidDexBridge.pushCredential(
                interactionID: context.operationID,
                configurationID: context.sourceIdentity.configurationID,
                siteKey: context.sourceIdentity.siteKey,
                providerOwnerID: providerOwnerID,
                actionContract: actionContract,
                credential: credential
            )
            guard configurationInteractionCoordinator.owns(context.operationID),
                  cloudAuthorizationContext?.operationID == context.operationID else {
                return
            }
            transitionConfigurationInteraction(
                context.operationID,
                to: .processing,
                status: "凭据已提交，正在等待站点确认…"
            )
            // A successful bridge submission only proves that the credential
            // reached the provider. Completion still belongs to the request's
            // terminal response. Legacy providers without a handle remain in
            // processing and eventually surface a bounded, retryable timeout.
            startCloudAuthorizationPolling()
        } catch is CancellationError {
            guard configurationInteractionCoordinator.owns(context.operationID) else {
                return
            }
            clearCloudAuthorization(
                resetBridgeUI: false,
                markPendingPlaybackCancelled: false,
                cancellationReason: .providerCancelled
            )
        } catch {
            if AsyncCancellationPolicy.isCancellation(error) {
                guard configurationInteractionCoordinator.owns(context.operationID) else {
                    return
                }
                clearCloudAuthorization(
                    resetBridgeUI: false,
                    markPendingPlaybackCancelled: false,
                    cancellationReason: .providerCancelled
                )
                return
            }
            failConfigurationInteraction(
                context.operationID,
                message: error.localizedDescription
            )
        }
    }

    func cancelCloudAuthorization() async {
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
            await providerHandle.cancelAndWait()
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
            if await consumeConfigurationVerificationState(
                state,
                context: context
            ) {
                return
            }
            guard state.isAuthorizationPrompt else {
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
        case .siteAction(let action, let title):
            guard let provider = providers[siteKey] else {
                show(AppError.site("该功能所属站点当前不可用"), title: title)
                return
            }
            await performSiteAction(action, title: title, provider: provider)
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
           configurationInteractionCoordinator.owns(interactionID) {
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
                title: state.title.nonEmpty ?? "配置操作",
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
        let credentialPush = state.isCredentialPush
        let fallbackActionKind = providerHandle?.actionKind
            ?? latestProviderInteraction?.actionKind
            ?? initialProviderInteraction?.actionKind
            ?? .configuration
        // First resolve the provider-declared kind without an image. A normal
        // configuration image may be a preview, logo or helper code and must
        // never trigger QR capture or authorization presentation by itself.
        let declaredInteraction = state.configurationInteraction(
            requestID: operationID,
            actionKind: fallbackActionKind,
            validatedQRCode: nil
        )
        // Some authorization providers rotate an expired QR code without
        // replacing the Android dialog. Read the small local image on every
        // authorization poll and only publish when its bytes actually change.
        let rawSnapshot: Data?
        if declaredInteraction.actionKind == .authorization,
           state.imageCount > 0,
           !credentialPush {
            if let providerHandle {
                rawSnapshot = try? await providerHandle.snapshot()
            } else {
                rawSnapshot = try? await environment?.androidDexBridge.uiSnapshot()
            }
        } else {
            rawSnapshot = nil
        }
        guard configurationInteractionCoordinator.owns(operationID),
              cloudAuthorizationContext?.operationID == operationID else {
            return
        }
        let freshSnapshot = AndroidBridgeQRCodePolicy.validatedSnapshot(
            rawSnapshot
        )
        // Snapshot capture is intentionally stricter than Android view-tree
        // classification and can miss one frame while the ImageView redraws.
        // Within the same request, retain the last decoded login QR until the
        // bridge reports a stable exit; the poller owns that exit decision.
        let retainsPendingAuthorization = previous?.interactionID == operationID
            && previous?.displaysLoginQRCode == true
            && cloudAuthorizationContext?.hasObservedQRCode == true
            && cloudAuthorizationContext?.hasRequestedVerification != true
        let snapshot = AndroidBridgeQRCodePolicy.retainedSnapshot(
            fresh: freshSnapshot,
            previous: previous?.snapshot,
            currentStateIsQRCode: state.isQRCode,
            retainsPendingAuthorization: retainsPendingAuthorization
        )
        let hasVerifiedQRCode = snapshot != nil
        // QR images often arrive one or more polling generations after the
        // interaction first becomes visible. Rebuild the interaction from the
        // current state and current validated snapshot so an explicit login
        // operation can reliably move candidate -> login without allowing a
        // configuration/ordering action to be promoted to authorization.
        let providerInteraction = state.configurationInteraction(
            requestID: operationID,
            actionKind: fallbackActionKind,
            validatedQRCode: snapshot
        )
        await providerHandle?.record(providerInteraction)
        guard configurationInteractionCoordinator.owns(operationID),
              var context = cloudAuthorizationContext,
              context.operationID == operationID else {
            return
        }
        if providerInteraction.actionKind == .authorization,
           !credentialPush,
           context.qrExpectedAt == nil {
            context.qrExpectedAt = Date()
        }
        context.providerInteraction = providerInteraction
        if let owner = state.providerOwnerID?.nonEmpty {
            context.providerOwnerID = owner
        }
        if let contract = state.actionContract {
            context.actionContract = contract
        }
        cloudAuthorizationContext = context
        let accountProviderID = await observeCloudAccountStatuses(
            in: state,
            context: context
        )
        guard configurationInteractionCoordinator.owns(operationID),
              cloudAuthorizationContext?.operationID == operationID else {
            return
        }
        let reconciledAccountTitle: (String) -> String = { [self] title in
            guard let accountProviderID else { return title }
            return cloudAccountStatusStore.reconciledTitle(
                title,
                providerID: accountProviderID
            )
        }
        let semantic = ConfigurationInteractionClassificationPolicy
            .nativeSemantic(
                interaction: providerInteraction,
                hasVerifiedQRCode: hasVerifiedQRCode,
                credentialPush: credentialPush,
                state: state
            )
        let interactionKind = ConfigurationInteractionClassificationPolicy
            .interactionKind(for: semantic)
        let displaysLoginQRCode = semantic == .qrAuthorization
            && providerInteraction.actionKind == .authorization
            && providerInteraction.qrRole == .login
            && snapshot != nil
        let expectsLoginQRCode = !credentialPush
            && snapshot == nil
            && state.inputCount == 0
            && state.actionableControls.isEmpty
            && (providerInteraction.actionKind == .authorization
                || cloudAuthorizationContext?.myDriveAuthorizationTarget != nil
                || previous?.qrState != .idle)
        let qrState: CloudAuthorizationQRCodeState = {
            if displaysLoginQRCode { return .ready }
            switch state.qrStatus?.lowercased() {
            case "expired": return .expired
            case "notfound", "not_found": return .notFound
            case "generating": return .generating
            default: break
            }
            guard expectsLoginQRCode else { return .idle }
            if let expectedAt = cloudAuthorizationContext?.qrExpectedAt
                    ?? cloudAuthorizationContext?.submittedAt,
               Date().timeIntervalSince(expectedAt) >= 12 {
                return .notFound
            }
            return .generating
        }()
        let usesSecureInput = providerInteraction.actionKind == .authorization
            || credentialPush
        let lifecyclePhase: ConfigurationInteractionPhase = {
            if qrState != .idle { return .presenting }
            guard let context = cloudAuthorizationContext,
                  context.submittedAt != nil,
                  !context.hasObservedPostSubmissionTransition else {
                return .presenting
            }
            return .processing
        }()
        let phase = credentialPush
            ? "credentials"
            : qrState != .idle
                ? "qr"
                : state.inputCount > 0
                    ? "credentials"
                    : "chooser"
        if semantic == .qrAuthorization,
           var context = cloudAuthorizationContext {
            let hadObservedQRCode = context.hasObservedQRCode
            context.hasObservedQRCode = true
            context.lastObservedQRCodeGeneration = state.interactionGeneration
            if context.myDriveAuthorizationTarget != nil,
               let fingerprint = state.authorizationStorageFingerprint?.nonEmpty {
                let baseline = MyDriveAuthorizationStorageEvidencePolicy
                    .baselineAfterObservingQRCode(
                        existing: context
                            .myDriveAuthorizationStorageFingerprintAtQRCode,
                        observed: fingerprint,
                        hadObservedQRCode: hadObservedQRCode,
                        workerReturned: state.workerReturned
                    )
                if baseline
                    != context.myDriveAuthorizationStorageFingerprintAtQRCode {
                    // The first QR frame is the authoritative baseline while
                    // the worker is active because some providers persist a
                    // QR nonce during dialog construction.
                    context.myDriveAuthorizationStorageFingerprintAtQRCode =
                        baseline
                    context.myDriveAuthorizationStorageCandidateFingerprint = nil
                    context.myDriveAuthorizationStorageStablePollCount = 0
                } else {
                    let candidate = MyDriveAuthorizationStorageEvidencePolicy
                        .updatedCandidate(
                            baseline: baseline,
                            candidate: context
                                .myDriveAuthorizationStorageCandidateFingerprint,
                            stablePollCount: context
                                .myDriveAuthorizationStorageStablePollCount,
                            observed: fingerprint
                        )
                    context.myDriveAuthorizationStorageCandidateFingerprint =
                        candidate.fingerprint
                    context.myDriveAuthorizationStorageStablePollCount =
                        candidate.stablePollCount
                }
            }
            cloudAuthorizationContext = context
        }
        let upstreamStatus = state.texts?
            .first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0 != state.title
                    && !$0.localizedCaseInsensitiveContains(
                        "/proxy?do=input"
                    )
            })
        let freshStatus = state.isRemoteInputQRCode
            ? "当前辅助输入码不适用于 Mac。请直接粘贴 Cookie，或点击“扫描二维码”生成网盘 App 登录码。"
            : credentialPush
            ? "该上游页面不是网盘 APP 登录码。请在下方粘贴 Cookie 或 Token，内容只发送到本机 Android 桥。"
            : upstreamStatus
        // A transient Android chooser/QR rebuild must not erase the useful
        // verification message and then restore it on the next half-second
        // poll. Preserve the current request's QR status until new upstream
        // text or a terminal state replaces it.
        let status = freshStatus
            ?? (previous?.interactionID == operationID
                && previous?.displaysLoginQRCode == true
                ? previous?.status
                : nil)
        let updated = CloudAuthorizationPrompt(
            id: previous?.id ?? UUID(),
            interactionID: operationID,
            title: qrState != .idle
                ? "网盘授权"
                : state.title.nonEmpty
                    ?? (interactionKind == .authorization ? "网盘授权" : "配置操作"),
            interactionKind: interactionKind,
            semantic: semantic,
            transport: .native,
            lifecyclePhase: lifecyclePhase,
            presentationTarget: previous?.presentationTarget
                ?? cloudAuthorizationPresentationTarget(
                    for: context.operation
                ),
            qrState: qrState,
            status: status,
            phase: phase,
            provider: state.provider,
            hasTextInput: state.inputCount > 0 || credentialPush,
            usesSecureInput: usesSecureInput,
            credentialPush: credentialPush,
            displaysLoginQRCode: displaysLoginQRCode,
            allowsRetry: qrState == .expired || qrState == .notFound
                || (qrState == .idle
                    && previous?.interactionID == operationID
                    && previous?.allowsRetry == true),
            actions: lifecyclePhase == .presenting
                && qrState == .idle
                ? state.actionableControls.map {
                CloudAuthorizationAction(
                    id: $0.id,
                    title: reconciledAccountTitle($0.title),
                    providerTitle: $0.title,
                    role: $0.role,
                    generation: state.interactionGeneration
                )
                }
                : [],
            snapshot: qrState == .ready ? snapshot : nil,
            uiSchemaVersion: state.uiSchemaVersion,
            elements: qrState != .idle
                ? []
                : (state.elements ?? []).map {
                    $0.replacingTitle(reconciledAccountTitle($0.title))
                },
            supportingTexts: qrState != .idle
                ? []
                : (state.texts ?? []).map(reconciledAccountTitle)
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
    }

    private func startCloudAuthorizationPolling() {
        cloudAuthorizationSessionID = UUID()
        let sessionID = cloudAuthorizationSessionID
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = Task { [weak self] in
            var hiddenPollCount = 0
            var bridgeFailureCount = 0
            var qrExitPollCount = 0
            var qrExitStartedAt: Date?
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
                    let hiddenStorageEvidenceConfirmed = !state.isQRCode
                        && self.recordHiddenMyDriveAuthorizationStorageEvidence(
                            state,
                            operationID: context.operationID
                        )
                    if await self.consumeConfigurationVerificationState(
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
                    if state.isQRCode {
                        qrExitPollCount = 0
                        qrExitStartedAt = nil
                    }
                    if context.hasObservedQRCode,
                       !state.isQRCode,
                       context.providerInteraction?.actionKind == .authorization {
                        let now = Date()
                        if qrExitPollCount == 0 {
                            qrExitStartedAt = now
                        }
                        qrExitPollCount += 1
                        let exitInterval = now.timeIntervalSince(
                            qrExitStartedAt ?? now
                        )
                        let hasGenerationTransition = context
                            .lastObservedQRCodeGeneration.map {
                                state.interactionGeneration != $0
                            } ?? false
                        guard CloudAuthorizationPollingPolicy
                            .shouldVerifyAfterQRCodeExit(
                                hasObservedQRCode: true,
                                currentStateIsQRCode: false,
                                actionKind: .authorization,
                                consecutiveExitPollCount: qrExitPollCount,
                                exitInterval: exitInterval,
                                hasGenerationTransition: hasGenerationTransition
                            ) else {
                            // A single Android snapshot can lose its QR role
                            // while the ImageView redraws or the dialog host is
                            // reattached. Keep the last validated QR visible;
                            // absence is presentation state, not scan proof.
                            continue
                        }
                    }
                    if CloudAuthorizationPollingPolicy
                        .shouldVerifyAfterQRCodeExit(
                            hasObservedQRCode: context.hasObservedQRCode,
                            currentStateIsQRCode: state.isQRCode,
                            actionKind: context.providerInteraction?.actionKind,
                            consecutiveExitPollCount: qrExitPollCount,
                            exitInterval: Date().timeIntervalSince(
                                qrExitStartedAt ?? Date()
                            ),
                            hasGenerationTransition: context
                                .lastObservedQRCodeGeneration.map {
                                    state.interactionGeneration != $0
                                } ?? false
                        ) {
                        hiddenPollCount += 1
                        if await self.verifyAuthorizationResultAfterQRCodeExit(
                            state: state,
                            context: context,
                            storageEvidenceConfirmed:
                                hiddenStorageEvidenceConfirmed
                        ) {
                            // The verifier also owns the explicitly pending
                            // MyDrive state. Do not age that state into the
                            // generic hidden-window timeout while the QR is
                            // still awaiting an authenticated account delta.
                            hiddenPollCount = 0
                            continue
                        }
                        if CloudAuthorizationPollingPolicy.shouldTimeOut(
                            hiddenPollCount: hiddenPollCount
                        ) {
                            context.providerHandle?.cancel()
                            self.failConfigurationInteraction(
                                context.operationID,
                                message: "二维码已确认，但站点状态长时间没有更新。请刷新后重试。"
                            )
                            return
                        }
                        continue
                    }
                    if state.isAuthorizationPrompt {
                        hiddenPollCount = 0
                        if var current = self.cloudAuthorizationContext,
                           current.operationID == context.operationID {
                            current.hasObservedPrompt = true
                            if let submittedGeneration = current.submittedGeneration,
                               state.interactionGeneration != submittedGeneration {
                                current.hasObservedPostSubmissionTransition = true
                            }
                            self.cloudAuthorizationContext = current
                        }
                        if let current = self.cloudAuthorizationContext,
                           current.operationID == context.operationID,
                           let submittedAt = current.submittedAt,
                           CloudAuthorizationPollingPolicy
                            .shouldFailUnchangedSubmission(
                                elapsed: Date().timeIntervalSince(submittedAt),
                                submittedGeneration: current.submittedGeneration,
                                currentGeneration: state.interactionGeneration,
                                hasObservedTransition: current
                                    .hasObservedPostSubmissionTransition,
                                isVisible: state.visible
                            ) {
                            current.providerHandle?.cancel()
                            self.failConfigurationInteraction(
                                context.operationID,
                                message: "站点收到点击，但操作界面没有进入下一步。请重试；若仍失败，请刷新配置后再试。"
                            )
                            return
                        }
                        await self.updateCloudAuthorizationPrompt(state)
                        if state.isQRCode,
                           let latestContext = self.cloudAuthorizationContext,
                           latestContext.operationID == context.operationID,
                           MyDriveAuthorizationStorageEvidencePolicy
                            .confirmsStableChange(
                                baseline: latestContext
                                    .myDriveAuthorizationStorageFingerprintAtQRCode,
                                candidate: latestContext
                                    .myDriveAuthorizationStorageCandidateFingerprint,
                                stablePollCount: latestContext
                                    .myDriveAuthorizationStorageStablePollCount
                            ),
                           await self.verifyMyDriveAuthorizationResult(
                                state: state,
                                context: latestContext,
                                storageEvidenceConfirmed: true
                           ) {
                            continue
                        }
                    } else {
                        hiddenPollCount += 1
                        if CloudAuthorizationPollingPolicy.shouldTimeOut(
                            hiddenPollCount: hiddenPollCount
                        ) {
                            let observed = self.cloudAuthorizationContext?
                                .hasObservedPrompt == true
                            context.providerHandle?.cancel()
                            self.failConfigurationInteraction(
                                context.operationID,
                                message: observed
                                    ? "操作窗口已关闭，但站点没有返回可验证的结果。请重试，或关闭后重新执行该操作。"
                                    : "站点未能创建下一步操作界面，操作没有完成。请检查网络后重试。"
                            )
                            return
                        } else if hiddenPollCount == 10,
                                  var prompt = self.cloudAuthorizationPrompt {
                            prompt.status = "仍在等待站点创建下一步操作界面…"
                            self.cloudAuthorizationPrompt = prompt
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    bridgeFailureCount += 1
                    if bridgeFailureCount >= 6 {
                        context.providerHandle?.cancel()
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

    /// Legacy CatVod providers can close or rebuild their child QR dialog both
    /// before and after a phone scan. Treat the QR -> non-QR transition only as
    /// a request to inspect provider state, never as evidence of a scan.
    private func verifyAuthorizationResultAfterQRCodeExit(
        state: AndroidBridgeUIState,
        context: CloudAuthorizationContext,
        storageEvidenceConfirmed: Bool
    ) async -> Bool {
        guard context.hasObservedQRCode,
              !state.isQRCode,
              context.providerInteraction?.actionKind == .authorization,
              cloudAuthorizationContext?.hasRequestedVerification != true else {
            return false
        }
        // Calling the same legacy Spider while its authorization worker is
        // active can corrupt provider-owned locks or state. QR disappearance
        // still does not prove that the phone scanned it, so keep the last
        // validated image visible and wait without claiming success.
        if CloudAuthorizationPollingPolicy.isWaitingForProviderWorker(
            workerReturned: state.workerReturned
        ) {
            if var prompt = cloudAuthorizationPrompt,
               prompt.interactionID == context.operationID,
               prompt.lifecyclePhase == .presenting {
                prompt.status = "二维码界面发生变化，正在等待站点返回账号状态…"
                cloudAuthorizationPrompt = prompt
            }
            // The Bridge owns the worker timeout and publishes an explicit
            // failure if it never returns. Do not consume the short generic
            // hidden-window timeout while useful provider work is active.
            return true
        }

        // The old implementation marked MyDriveGuard successful merely because
        // the worker returned, then reopened the chooser. UC routinely returns
        // or rebuilds its child window before any scan, so that branch closed a
        // valid QR after a few seconds. Accept only either (a) the exact row
        // selected before QR presentation changing from 未登录 to 已登录, or (b)
        // a new media category appearing relative to the pre-click home. The
        // latter covers legacy dialogs that destroy their chooser parent after
        // a real scan, while still rejecting a bare QR/window transition.
        if myDriveLoginStatusAction(for: context) != nil {
            return await verifyMyDriveAuthorizationResult(
                state: state,
                context: context,
                storageEvidenceConfirmed: storageEvidenceConfirmed
            )
        }

        guard let provider = providers[context.sourceIdentity.siteKey]
                as? AndroidDexSpiderSiteProvider else {
            return false
        }
        let now = Date()
        if let lastProbe = cloudAuthorizationContext?.lastAuthorizationProbeAt,
           now.timeIntervalSince(lastProbe) < 1 {
            return false
        }
        guard var current = cloudAuthorizationContext,
              current.operationID == context.operationID else {
            return false
        }
        current.lastAuthorizationProbeAt = now
        cloudAuthorizationContext = current
        // Keep the last validated QR visible while probing. Switching the
        // whole prompt to `.processing` on an unverified UI transition made
        // the QR disappear and reappear whenever Android missed one capture.
        if var prompt = cloudAuthorizationPrompt,
           prompt.interactionID == context.operationID,
           prompt.lifecyclePhase == .presenting {
            prompt.status = "检测到二维码界面变化，正在确认授权结果…"
            cloudAuthorizationPrompt = prompt
        }

        let verifiedHome = try? await provider.home()
        let homeConfirmed = verifiedHome.map {
            provider.homeConfirmsAuthorization($0)
        } == true
        // A category response may differ because of pagination, ordering,
        // posters or network timing. It is not an authentication contract and
        // must never close a QR prompt before the user has scanned it.
        guard homeConfirmed,
              configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID else {
            return false
        }
        transitionConfigurationInteraction(
            context.operationID,
            to: .processing,
            semantic: .qrAuthorization,
            status: "授权已确认，正在刷新网盘内容…"
        )
        if homeConfirmed,
           let verifiedHome,
           currentHomeContentIdentity == context.sourceIdentity {
            publishHomeContent(verifiedHome, identity: context.sourceIdentity)
            await cacheSiteHome(verifiedHome, identity: context.sourceIdentity)
            _ = await applyHomePresentation(
                verifiedHome,
                identity: context.sourceIdentity,
                loadsCategoryContent: false
            )
        }
        if var verifiedContext = cloudAuthorizationContext,
           verifiedContext.operationID == context.operationID {
            verifiedContext.hasRequestedVerification = true
            cloudAuthorizationContext = verifiedContext
        }
        if let handle = context.providerHandle {
            await Self.verifyScopedConfigurationInteraction(
                handle,
                succeeded: true,
                actualRefreshPerformed: true
            )
        } else {
            await finishCloudAuthorizationAndRetry(refreshPerformed: true)
        }
        return true
    }

    /// Records an opaque credential-storage transition after the provider has
    /// hidden its QR UI. This must run before terminal-state consumption: old
    /// or slow bridges may report a lifecycle transition in the same snapshot
    /// that first exposes the persisted authorization digest.
    private func recordHiddenMyDriveAuthorizationStorageEvidence(
        _ state: AndroidBridgeUIState,
        operationID: UUID
    ) -> Bool {
        guard var context = cloudAuthorizationContext,
              context.operationID == operationID,
              context.hasObservedQRCode,
              context.myDriveAuthorizationTarget != nil else {
            return false
        }
        let candidate = MyDriveAuthorizationStorageEvidencePolicy
            .updatedCandidate(
                baseline: context
                    .myDriveAuthorizationStorageFingerprintAtQRCode,
                candidate: context
                    .myDriveAuthorizationStorageCandidateFingerprint,
                stablePollCount: context
                    .myDriveAuthorizationStorageStablePollCount,
                observed: state.authorizationStorageFingerprint
            )
        context.myDriveAuthorizationStorageCandidateFingerprint =
            candidate.fingerprint
        context.myDriveAuthorizationStorageStablePollCount =
            candidate.stablePollCount
        cloudAuthorizationContext = context
        return MyDriveAuthorizationStorageEvidencePolicy.confirmsStableChange(
            baseline: context.myDriveAuthorizationStorageFingerprintAtQRCode,
            candidate: candidate.fingerprint,
            stablePollCount: candidate.stablePollCount
        )
    }

    /// Confirms MyDrive authorization from one of three request-scoped facts:
    /// the exact chooser row changed to logged in, a new usable media category
    /// appeared, or Android persisted a stable post-QR preference change.
    /// The last signal is necessary for providers that keep their QR dialog
    /// visible after success and leave the newly logged account disabled.
    private func verifyMyDriveAuthorizationResult(
        state: AndroidBridgeUIState,
        context: CloudAuthorizationContext,
        storageEvidenceConfirmed: Bool
    ) async -> Bool {
        guard myDriveLoginStatusAction(for: context) != nil,
              configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              CloudAuthorizationPollingPolicy.isWaitingForProviderWorker(
                workerReturned: state.workerReturned
              ) == false,
              let provider = providers[context.sourceIdentity.siteKey]
                as? AndroidDexSpiderSiteProvider else {
            return false
        }
        let decision = MyDriveAuthorizationVerificationPolicy.decision(
            target: context.myDriveAuthorizationTarget,
            state: state
        )
        var verifiedHome: SiteHome?
        var categoryDeltaConfirmed = false
        let now = Date()
        let mayProbeHome: Bool
        if let lastProbe = cloudAuthorizationContext?.lastAuthorizationProbeAt {
            mayProbeHome = now.timeIntervalSince(lastProbe) >= 1
        } else {
            mayProbeHome = true
        }
        if decision != .authenticated, mayProbeHome,
           var current = cloudAuthorizationContext,
           current.operationID == context.operationID {
            current.lastAuthorizationProbeAt = now
            cloudAuthorizationContext = current
            verifiedHome = try? await provider.home()
            if let verifiedHome {
                categoryDeltaConfirmed =
                    MyDriveAuthorizationVerificationPolicy
                        .confirmsNewAuthorizedCategory(
                            baseline: current
                                .myDriveAuthorizedCategoryIDsAtStart,
                            home: verifiedHome
                        )
            }
        }
        guard decision == .authenticated
                || categoryDeltaConfirmed
                || storageEvidenceConfirmed else {
            if var prompt = cloudAuthorizationPrompt,
               prompt.interactionID == context.operationID,
               prompt.lifecyclePhase == .presenting {
                prompt.status = decision == .unauthenticated || mayProbeHome
                    ? "尚未检测到登录成功；请完成扫码。二维码失效时可点“重试”重新生成。"
                    : "正在等待所选网盘账号返回明确的登录状态…"
                prompt.allowsRetry = true
                cloudAuthorizationPrompt = prompt
            }
            return true
        }
        await confirmCloudAccountStatus(for: context)
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID else {
            return false
        }
        if verifiedHome == nil {
            verifiedHome = try? await provider.home()
        }
        if let verifiedHome,
           currentHomeContentIdentity == context.sourceIdentity {
            publishHomeContent(verifiedHome, identity: context.sourceIdentity)
            await cacheSiteHome(
                verifiedHome,
                identity: context.sourceIdentity
            )
            _ = await applyHomePresentation(
                verifiedHome,
                identity: context.sourceIdentity,
                loadsCategoryContent: false
            )
        }
        if var verifiedContext = cloudAuthorizationContext,
           verifiedContext.operationID == context.operationID {
            verifiedContext.hasRequestedVerification = true
            cloudAuthorizationContext = verifiedContext
        }
        transitionConfigurationInteraction(
            context.operationID,
            to: .processing,
            semantic: .qrAuthorization,
            status: storageEvidenceConfirmed
                ? "检测到所选网盘账号授权数据已更新，正在刷新账号状态…"
                : "已确认所选网盘账号登录成功，正在刷新账号状态…"
        )
        if let handle = context.providerHandle {
            await Self.verifyScopedConfigurationInteraction(
                handle,
                succeeded: true,
                actualRefreshPerformed: verifiedHome != nil
            )
        } else {
            await finishCloudAuthorizationAndRetry(
                refreshPerformed: verifiedHome != nil
            )
        }
        return true
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
        let completionSemantic = cloudAuthorizationPrompt?.semantic
            ?? context.operation.initialSemantic
        let isPlaybackOperation: Bool = {
            if case .playback = context.operation {
                return true
            }
            return false
        }()
        let loginStatusActionToReopen = completionSemantic.isAuthorization
            ? myDriveLoginStatusAction(for: context)
            : nil
        let completionStatus: String
        if loginStatusActionToReopen != nil {
            completionStatus = "二维码流程已结束，正在刷新账号状态…"
        } else if isPlaybackOperation && completionSemantic.isAuthorization {
            completionStatus = "授权成功，正在继续播放…"
        } else {
            completionStatus = ConfigurationControlSubmissionPolicy.completionStatus(
                semantic: completionSemantic
            )
        }
        completeConfigurationInteraction(
            context.operationID,
            status: completionStatus
        )
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        let completionDelay: UInt64
        if loginStatusActionToReopen != nil
            || (isPlaybackOperation && completionSemantic.isAuthorization) {
            completionDelay = 350_000_000
        } else if completionSemantic.isAuthorization {
            completionDelay = 1_400_000_000
        } else {
            completionDelay = 650_000_000
        }
        try? await Task.sleep(nanoseconds: completionDelay)
        guard configurationInteractionCoordinator.owns(context.operationID),
              cloudAuthorizationContext?.operationID == context.operationID,
              isCurrentCloudAuthorizationContext(context) else {
            return
        }
        cloudAuthorizationPrompt = nil
        cloudAuthorizationInput = ""
        cloudAuthorizationContext = nil
        configurationInteractionCoordinator.clear(context.operationID)
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
                windowActivation: .preserveFocus
            )
        case .detail(let summary):
            guard summary.siteKey == context.sourceIdentity.siteKey else { return }
            if summary.resolvedContentKind == .action,
               selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
                if let loginStatusActionToReopen {
                    let refreshedAction = siteHome?.actionItems.first(where: {
                        $0.action == MyDriveGuardActionContract.loginAction
                    }) ?? loginStatusActionToReopen
                    await performHomeAction(refreshedAction)
                }
            } else {
                await loadDetail(summary)
            }
        case .homeAction:
            if selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
                if let loginStatusActionToReopen {
                    let refreshedAction = siteHome?.actionItems.first(where: {
                        $0.action == MyDriveGuardActionContract.loginAction
                    }) ?? loginStatusActionToReopen
                    await performHomeAction(refreshedAction)
                }
            }
        case .siteAction:
            if selectedSection == .home,
               selectedSiteKey == context.sourceIdentity.siteKey {
                await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
            }
        }
    }

    private func myDriveLoginStatusAction(
        for context: CloudAuthorizationContext
    ) -> SiteActionItem? {
        guard let provider = providers[context.sourceIdentity.siteKey]
                as? AndroidDexSpiderSiteProvider,
              MyDriveGuardActionContract.supportsAccountAuthorization(
                api: provider.site.api
              ) else {
            return nil
        }
        switch context.operation {
        case .homeAction(let item)
            where item.action == MyDriveGuardActionContract.loginAction:
            return item
        case .detail(let summary)
            where summary.action == MyDriveGuardActionContract.loginAction:
            return SiteActionItem(summary: summary)
        default:
            return nil
        }
    }

    static let unconfirmedSiteActionMessage =
        "未检测到网盘设置或授权界面，当前操作尚未完成。请稍后重试。"

    static let unsupportedSiteActionMessage =
        "站点未提供可执行的宿主操作，当前功能尚未完成。"

    static func shouldWaitForCloudAuthorization(
        capability: SiteCapability
    ) -> Bool {
        capability == .javaDexSpider
    }

    /// Returns only an explicit upstream result. Empty placeholder objects are
    /// commands, not proof that their side effect completed successfully.
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
        do {
            let detail = try await provider.detail(
                id: recipeDetailID ?? item.videoID
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

            // A provider may refresh the same episode with a shortened display
            // name or a renamed route. Do not claim that the episode was
            // removed while the durable history reference can still rebuild a
            // valid playback URL below.
            recoveryFailure = "最新详情中未找到原线路或原分集"
        } catch {
            // Search/cloud providers often expose session-scoped video IDs.
            // Continue with the durable episode reference or cached media
            // instead of surfacing a low-level empty-JSON error.
            recoveryFailure = "旧详情 ID 已失效"
        }

        let persistedEpisodeReference = item.episodeReference?.nonEmpty.flatMap(
            Self.persistentHistoryEpisodeReference
        )
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
        activePlayback = nil
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
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
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
        // Preserve meaningful punctuation exactly as FongMi does. NFC
        // normalization only removes equivalent Unicode spellings that can
        // otherwise produce different URL/JSON payloads for the same text.
        let trimmed = keyword
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        searchKeyword = trimmed
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
        let searchableProviders: [SiteProvider] = searchCatalogSites.compactMap { site in
            guard selectedKeys.contains(site.key),
                  site.searchable != 0 else { return nil }
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
                if failure.category == .unsupportedRoute,
                   let site = searchCatalogSites.first(where: {
                    $0.key == failure.siteKey
                   }),
                   let identity = nodeSearchCapabilityIdentity(for: site) {
                    unsupportedNodeSearchRouteIdentities.insert(identity)
                }
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

    func presentHomeSearch() {
        selectedSection = .home
        isHomeSearchPresented = true
    }

    func focusHomeToolbarSearch() {
        if isHomeSearchPresented {
            returnFromSearchToHome()
        } else {
            selectedSection = .home
        }
        homeToolbarSearchFocusRequest &+= 1
    }

    func searchFromHome(_ keyword: String) {
        presentHomeSearch()
        search(keyword)
    }

    func returnFromSearchToHome() {
        cancelSearch()
        searchFolderPath = []
        selectedSearchSiteKey = nil
        isHomeSearchPresented = false
    }

    func selectSection(_ section: AppSection) {
        if section == .home, isHomeSearchPresented {
            returnFromSearchToHome()
        } else if isHomeSearchPresented {
            cancelSearch()
            isHomeSearchPresented = false
        }
        selectedSection = section
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
            hasBlockingPresentation: mainWindowCloudAuthorizationPrompt != nil
                || nodeWebPresentation != nil
                || selectedDetail != nil
                || pendingDetailSummary != nil
                || isQuickSwitcherPresented
                || isShortcutHelpPresented
        )
        switch action {
        case .none:
            return false
        case .stopSearch:
            cancelSearch()
        case .returnHome:
            returnFromSearchToHome()
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
                search(searchKeyword)
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
            if searchFolderPath.count > 1 {
                navigateBackSearchFolder()
            } else {
                closeSearchFolder()
            }
        } else if isHomeSearchPresented {
            returnFromSearchToHome()
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
            let isCatalogueDisabled = site.extra["okNodeCatalogDisabled"]
                == .bool(true)
            let availability: SearchScopeSiteAvailability
            if site.extra["okNodeConfigurationRequired"] == .bool(true) {
                availability = .unavailable("未配置账号或挂载")
            } else if let identity = nodeSearchCapabilityIdentity(for: site),
                      unsupportedNodeSearchRouteIdentities.contains(identity) {
                availability = .unavailable("Spider 未提供搜索接口")
            } else if site.extra["okNodeRuntime"] == .bool(true),
                      NodeSearchCapabilityPolicy.declaredState(for: site)
                        == .unsupported {
                availability = .unavailable("Spider 未提供搜索接口")
            } else if site.searchable == 0 {
                availability = .unavailable("站点未提供搜索能力")
            } else if site.hide != 0, !isCatalogueDisabled {
                availability = .unavailable("配置中已隐藏")
            } else if providers[site.key]?.capability == .unsupportedSpider
                        || providers[site.key] == nil {
                availability = .unavailable("当前运行环境不支持")
            } else if site.searchable == 2 || isCatalogueDisabled {
                availability = .userDisabled
            } else {
                availability = .enabled
            }
            return SearchScopeSiteOption(
                key: site.key,
                name: site.name,
                availability: availability
            )
        }
    }

    private func nodeSearchCapabilityIdentity(
        for site: SiteConfiguration
    ) -> String? {
        guard site.extra["okNodeRuntime"] == .bool(true),
              let bundle = site.extra["okNodeBundleIdentity"]?.stringValue,
              let revision = site.extra["okNodeProfileRevision"]?.stringValue else {
            return nil
        }
        return [bundle, revision, site.key].joined(separator: "\u{1f}")
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
        if let continuingRequestID {
            guard origin.isHistory,
                  historyPlaybackPreparationID == continuingRequestID,
                  activePlayerRequestID == continuingRequestID else { return }
        } else if !origin.isHistory {
            historyPlaybackTask?.cancel()
            historyPlaybackTask = nil
            historyPlaybackLoadingID = nil
            historyPlaybackRequestedItem = nil
            historyPlaybackChoices = []
            historyPlaybackPreparationID = UUID()
        }
        if let pendingPlayback,
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
        if !origin.isHistory {
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
        await environment.player.stop()
        guard playbackSessionID == sessionID else { return }

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
                        let refreshed = try await provider.refreshPlayback(
                            PlaybackRefreshRequest(
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
                        )
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
                            authorization.handle?.cancel()
                            return
                        }
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
                        finishProviderPlaybackFailure(
                            providerError,
                            requestID: sessionID
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
                            sessionID: sessionID
                        )
                    }
                    guard playbackSessionID == sessionID else {
                        throw CancellationError()
                    }
                    if let acceptedReference = Self.acceptedProviderResourceReference(
                        result.resourceReference,
                        provider: provider
                    ) {
                        currentProviderReference = acceptedReference
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
                        authorization.handle?.cancel()
                        return
                    }
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
                    finishProviderPlaybackFailure(
                        providerError,
                        requestID: sessionID
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
                        await imageQuiesceTask.value
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
                        playbackFailureSummary = Self.playbackFailureMessage(
                            message,
                            validationPolicy: result.validationPolicy,
                            refreshPerformed: refreshWasExplicitlyObserved
                        )
                    case .resolved:
                        playbackFailureSummary = nil
                        pendingPlayback = nil
                        return
                    case .failed(let message):
                        candidateFailure = Self.playbackFailureMessage(
                            message,
                            validationPolicy: result.validationPolicy,
                            refreshPerformed: refreshWasExplicitlyObserved
                        )
                    case .cancelled:
                        throw CancellationError()
                    }
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
        sessionID: UUID
    ) async throws -> SitePlaybackResult {
        try Task.checkCancellation()
        guard playbackSessionID == sessionID else {
            throw CancellationError()
        }
        return try await provider.player(
            flag: flag,
            episodeURL: episodeURL
        )
    }

    private func finishProviderPlaybackFailure(
        _ error: ProviderPlaybackError,
        requestID: UUID
    ) {
        guard playbackSessionID == requestID else { return }
        let message = LogRedactor.text(error.localizedDescription)
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
        if activeConfigurationUsesNodeRuntime {
            do {
                try await prepareActiveNodeConfigurationIfNeeded()
                try loadActiveConfigurationContent()
            } catch {
                // The validated snapshot and history have already committed.
                // Keep restoration successful and let the existing runtime
                // status UI explain why this provider is temporarily offline.
                nodeRuntimeUnavailableReason = error.localizedDescription
                rebuildProviders()
            }
        } else {
            await environment.nodeBundleRuntime.stop()
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
            let recordIDs = Set(history.map(\.id))
            _ = try await environment.database.deleteHistory(
                configurationID: configurationID
            )
            historyPlaybackSessionCache.remove(recordIDs)
            try await reloadHistory()
        } catch {
            show(error, title: "清理历史失败")
        }
    }

    func deleteHistory(ids: Set<HistoryRecord.ID>) async {
        guard let environment, !ids.isEmpty else { return }
        do {
            for record in history where ids.contains(record.id) {
                _ = try await environment.database.deleteHistory(
                    configurationID: record.configurationID,
                    siteKey: record.siteKey,
                    videoID: record.videoID,
                    sourceKey: record.sourceKey
                )
            }
            historyPlaybackSessionCache.remove(ids)
            try await reloadHistory()
        } catch {
            show(error, title: "删除历史失败")
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
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        playerEventTask?.cancel()
        playerEventTask = nil
        nodeRuntimeStatusTask?.cancel()
        nodeRuntimeStatusTask = nil
        nodeProfileRevisionTask?.cancel()
        nodeProfileRevisionTask = nil
        configurationActivationTask?.cancel()
        configurationActivationTask = nil
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
            await self.environment?.nodeBundleRuntime.stop()
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
            pendingNodeOperation = nil
            nodeWebPresentation = nil
        }
        isClosingPlayer = true
        defer { isClosingPlayer = false }
        let closingRequestID = activePlayerRequestID
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
            requestID: closingRequestID
        )
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
        let confirmationID = UUID()
        activeSeekConfirmationID = confirmationID
        playerSnapshot.isSeeking = true
        playerSnapshot.seekTarget = target
        do {
            try await player.seek(to: target)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try Task.checkCancellation()
                guard activeSeekConfirmationID == confirmationID else { return }
                let tolerance = max(3, min(12, playerSnapshot.duration * 0.002))
                if !playerSnapshot.isSeeking,
                   abs(playerSnapshot.position - target) <= tolerance {
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
                    "当前转码线路不支持随机跳转，请切换原画或其他清晰度"
                ),
                title: "跳转失败"
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
        androidRuntimeContinuityStatus = await environment.androidDexBridge
            .runtimeContinuityStatus()
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

    func migrateLegacyAndroidRuntime() async {
        guard let environment, !isAndroidRuntimeBusy else { return }
        isAndroidRuntimeBusy = true
        androidRuntimeContinuityStatus = .migrating
        defer { isAndroidRuntimeBusy = false }
        do {
            androidRuntimeStatus = .starting(
                "正在复制并验证旧版授权环境",
                progress: 0
            )
            androidRuntimeContinuityStatus = try await environment
                .androidDexBridge.migrateLegacyRuntime()
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            androidRuntimeContinuityStatus = await environment.androidDexBridge
                .runtimeContinuityStatus()
        } catch {
            androidRuntimeStatus = await environment.androidDexBridge
                .runtimeStatus()
            androidRuntimeContinuityStatus = await environment.androidDexBridge
                .runtimeContinuityStatus()
            show(error, title: "旧版授权环境迁移失败")
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
        replacingPath: Bool
    ) {
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
        presentHomeSearch()
        let page = SearchFolderPage(folder: summary)
        if replacingPath {
            searchFolderPath = [page]
        } else {
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
        position: TimeInterval
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
            detailID: detail.summary.videoID,
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
        acceptedProviderResourceReference(
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

    /// Keeps only provider locators that are safe to serialize. Runtime
    /// capabilities and credential-bearing URLs remain in memory and are
    /// regenerated by the owning provider on the next playback.
    static func persistentHistoryEpisodeReference(
        _ rawValue: String
    ) -> String? {
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

    private func prepareActiveNodeConfigurationIfNeeded() async throws {
        guard let environment else { return }
        guard let record = activeConfigurationRecord,
              record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let sourceURL = URL(string: sourceValue),
              NodeBundleRuntimeService.supports(sourceURL) else {
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = "Node Runtime 未用于当前配置"
            await environment.nodeBundleRuntime.stop()
            return
        }
        let loaded: LoadedConfiguration
        do {
            loaded = try await environment.nodeBundleRuntime
                .loadConfiguration(
                    from: sourceURL,
                    configurationID: record.id
                )
            activeNodeRuntimeEndpoint = loaded.baseURL
            nodeRuntimeUnavailableReason = ""
        } catch {
            activeNodeRuntimeEndpoint = nil
            nodeRuntimeUnavailableReason = error.localizedDescription
            rebuildProviders()
            throw error
        }
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
        configurations = try await environment.database.configurations()
        activeConfigurationRecord = updated
        lastAutomaticConfigurationRefreshAttemptAt = loaded.loadedAt
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
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        cancelSearch()
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
            uniqueKeysWithValues: searchCatalogSites.map { site in
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
        _ = try await environment.database.deleteHistory(
            olderThan: Calendar.current.date(
                byAdding: .day,
                value: -historyRetentionDays,
                to: Date()
            )
                ?? Date.distantPast
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
                    if self.playerSnapshot != snapshot {
                        self.playerSnapshot = snapshot
                    }
                    let subtitleTracks = snapshot.tracks.filter {
                        $0.type == .subtitle
                    }
                    if !subtitleTracks.isEmpty {
                        self.playerSubtitlesEnabled = subtitleTracks.contains {
                            $0.isSelected
                        }
                        if let selected = subtitleTracks.first(where: { $0.isSelected }) {
                            self.selectedPlayerSubtitleTrackID = selected.id
                            self.preferredPlayerSubtitleTrack =
                                PlayerSubtitleTrackPreference(track: selected)
                        } else if let preference = self.preferredPlayerSubtitleTrack,
                                  let remembered =
                                    PlayerSubtitleTrackPreference.matchingTrack(
                                        in: subtitleTracks,
                                        preference: preference
                                    ) {
                            self.selectedPlayerSubtitleTrackID = remembered.id
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
                    await self.applyPlayerSubtitlePreference(
                        requestID: requestID
                    )
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
                case .ended(let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
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
                    await self.advanceAfterNaturalEnd(
                        endedSessionID: endedSessionID
                    )
                case .error(let message, let requestID):
                    guard PlaybackRequestOwnershipPolicy.accepts(
                        requestID: requestID,
                        activeRequestID: self.activePlayerRequestID
                    ) else {
                        continue
                    }
                    if self.livePlaybackChannel != nil {
                        self.recoverLivePlaybackAfterFailure(
                            requestID: requestID
                        )
                        continue
                    }
                    if let requestID,
                       self.failPlaybackStartupGate(
                           requestID: requestID,
                           error: AppError.playback(message)
                       ) {
                        self.playbackFailureSummary = message
                        continue
                    }
                    if let requestID,
                       self.playbackRequestsResolving.contains(requestID) {
                        self.playbackFailureSummary = message
                        continue
                    }
                    if let requestID {
                        self.presentPlaybackErrorOnce(
                            message,
                            requestID: requestID
                        )
                    } else {
                        self.show(
                            AppError.playback(message),
                            title: "播放器错误"
                        )
                    }
                }
            }
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
    ) -> (
        identity: UUID,
        stream: AsyncThrowingStream<Void, Error>
    ) {
        cancelPlaybackStartupGate(requestID: requestID)
        let identity = UUID()
        var captured: AsyncThrowingStream<Void, Error>.Continuation!
        let stream = AsyncThrowingStream<Void, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            captured = continuation
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: timeoutSeconds * 1_000_000_000
            )
            guard !Task.isCancelled else { return }
            self?.failPlaybackStartupGate(
                requestID: requestID,
                expectedIdentity: identity,
                error: AppError.playback(
                    "该线路已载入，但 \(timeoutSeconds) 秒内没有产生音视频"
                )
            )
        }
        pendingPlaybackStartupGates[requestID] = PendingPlaybackStartupGate(
            identity: identity,
            continuation: captured,
            timeoutTask: timeoutTask
        )
        return (identity, stream)
    }

    @discardableResult
    private func completePlaybackStartupGate(requestID: UUID) -> Bool {
        guard let gate = pendingPlaybackStartupGates.removeValue(
            forKey: requestID
        ) else { return false }
        gate.timeoutTask.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        return true
    }

    @discardableResult
    private func failPlaybackStartupGate(
        requestID: UUID,
        expectedIdentity: UUID? = nil,
        error: Error
    ) -> Bool {
        guard let gate = pendingPlaybackStartupGates[requestID],
              expectedIdentity == nil || gate.identity == expectedIdentity else {
            return false
        }
        pendingPlaybackStartupGates[requestID] = nil
        gate.timeoutTask.cancel()
        gate.continuation.finish(throwing: error)
        return true
    }

    private func cancelPlaybackStartupGate(
        requestID: UUID,
        expectedIdentity: UUID? = nil
    ) {
        _ = failPlaybackStartupGate(
            requestID: requestID,
            expectedIdentity: expectedIdentity,
            error: CancellationError()
        )
    }

    private func cancelAllPlaybackStartupGates() {
        let gates = pendingPlaybackStartupGates
        pendingPlaybackStartupGates.removeAll()
        for gate in gates.values {
            gate.timeoutTask.cancel()
            gate.continuation.finish(throwing: CancellationError())
        }
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
        let authoritativeHistoryRecord = pendingPlayback?.origin.historyRecord
        let existing = authoritativeHistoryRecord ?? history.first {
            $0.siteKey == detail.summary.siteKey
                && $0.videoID == detail.summary.videoID
                && Self.historyRecord($0, matches: source, episode: episode)
        }
        let startPosition = Self.historyResumePosition(from: existing)
        let playback = ActivePlaybackContext(
            configurationID: configurationID,
            detail: detail,
            source: source,
            episode: episode,
            media: media,
            playbackResult: playbackResult,
            providerResourceReference: providerResourceReference,
            replacedHistoryRecord: authoritativeHistoryRecord.flatMap {
                let replacementID = HistoryRecord(
                    configurationID: configurationID,
                    siteKey: detail.summary.siteKey,
                    videoID: detail.summary.videoID,
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
        let startupGate = beginPlaybackStartupGate(requestID: sessionID)
        defer {
            cancelPlaybackStartupGate(
                requestID: sessionID,
                expectedIdentity: startupGate.identity
            )
        }
        do {
            try await loadPlayerAfterRenderSurfaceReady(
                media,
                startPosition: startPosition,
                requestID: sessionID
            )
            guard playbackSessionID == sessionID else {
                throw CancellationError()
            }
            // A natural EOF can leave libmpv's pause/keep-open state latched
            // while the next episode is being resolved. Reassert autoplay
            // after file-loaded, then wait for actual media progress before
            // committing this resolver candidate as playable.
            try await environment.player.play()
            guard playbackSessionID == sessionID else {
                throw CancellationError()
            }
            try await awaitPlaybackStartup(startupGate.stream)
            guard playbackSessionID == sessionID else {
                throw CancellationError()
            }
        } catch {
            await environment.player.stop()
            throw error
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
        return PlaybackHistoryWrite(
            record: HistoryRecord(
                configurationID: PlaybackConfigurationOwnershipPolicy.historyOwner(
                    captured: playback.configurationID,
                    current: activeConfigurationRecord?.id
                ),
                siteKey: detail.summary.siteKey,
                videoID: detail.summary.videoID,
                title: detail.summary.title,
                posterURL: detail.summary.posterURL,
                sourceKey: playback.source.id,
                sourceName: playback.source.name,
                episodeName: playback.episode.name,
                episodeReference: Self.persistentHistoryEpisodeReference(
                    playback.episode.url
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
                        position: position
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
        let candidateID = HistoryRecord(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            videoID: detail.summary.videoID,
            title: detail.summary.title,
            sourceKey: source.id
        ).id
        let existing = history.first(where: { $0.id == candidateID })
            ?? history.first(where: {
                $0.configurationID == configurationID
                    && $0.siteKey == detail.summary.siteKey
                    && $0.videoID == detail.summary.videoID
                    && Self.historyRecord($0, matches: source, episode: episode)
            })
        let position = existing?.position ?? 0
        let reference = Self.historyPlaybackReference(
            source: source,
            episode: episode,
            providerResourceReference: episode.providerResourceReference,
            navigationRecipe: Self.historyNavigationRecipe(
                detail: detail,
                source: source,
                episode: episode,
                configurationID: configurationID,
                position: position
            ),
            headers: [:]
        )
        let record = HistoryRecord(
            configurationID: configurationID,
            siteKey: detail.summary.siteKey,
            videoID: detail.summary.videoID,
            title: detail.summary.title,
            posterURL: detail.summary.posterURL,
            sourceKey: source.id,
            sourceName: source.name,
            episodeName: episode.name,
            episodeReference: Self.persistentHistoryEpisodeReference(
                episode.url
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
        } catch {
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
