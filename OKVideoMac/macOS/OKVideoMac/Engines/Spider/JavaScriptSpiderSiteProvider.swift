import Darwin
import AppKit
import CryptoKit
import Foundation
import AndroidRuntimeKit
import OKVideoCore
import Security

enum AndroidBridgeInteractionPollingPolicy {
    static let timeout: TimeInterval = 600

    /// Keep the first UI transitions responsive, then back off while a user is
    /// reading or entering data in the Android configuration surface. This
    /// cuts the steady-state localhost traffic from four requests per second
    /// to one without changing the ten-minute interaction deadline.
    static func delayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        switch max(0, attempt) {
        case 0..<8:
            return 250_000_000
        case 8..<24:
            return 500_000_000
        default:
            return 1_000_000_000
        }
    }

    static func shouldContinue(
        startedAt: Date,
        now: Date,
        timeout: TimeInterval = AndroidBridgeInteractionPollingPolicy.timeout
    ) -> Bool {
        now.timeIntervalSince(startedAt) < max(0, timeout)
    }
}

/// A request-owned description of one native Android configuration surface.
///
/// This is intentionally provider-neutral. A chooser, ordering form, cookie
/// reset and login QR code are different phases of a configuration operation;
/// they are not all authorization prompts merely because Android rendered them.
struct ConfigurationInteraction: Equatable, Identifiable, Sendable {
    enum ActionKind: String, Equatable, Sendable {
        case command
        case immediate
        case toggle
        case ordering
        case configuration
        case authorization
        case webSetting
        case nativeSetting
        case playback
    }

    enum Phase: String, Equatable, Sendable {
        case invoking
        case choice
        case form
        case transitioning
        case reattaching
        case status
        case completed
        case failed
        case cancelled
    }

    enum Outcome: String, Equatable, Sendable {
        case pending
        case succeeded
        case failed
        case cancelled
    }

    let id: UUID
    let actionKind: ActionKind
    let phase: Phase
    let outcome: Outcome
    let generation: Int?
}

/// The terminal provider response associated with one interaction request.
/// Keeping this value separate from the transient UI snapshot lets a caller
/// present native UI immediately without losing the eventual Spider result.
struct ConfigurationInteractionTerminalResponse: Equatable, Sendable {
    let requestID: UUID
    let outcome: ConfigurationInteraction.Outcome
    let providerResult: JSONValue?
    let error: String?
    let httpStatusCode: Int?
    /// `nil` means the compatibility bridge did not report refresh state.
    /// Callers must not interpret it as either true or false.
    let refreshPerformed: Bool?
    let failureKind: String?

    init(
        requestID: UUID,
        outcome: ConfigurationInteraction.Outcome,
        providerResult: JSONValue?,
        error: String?,
        httpStatusCode: Int?,
        refreshPerformed: Bool?,
        failureKind: String? = nil
    ) {
        self.requestID = requestID
        self.outcome = outcome
        self.providerResult = providerResult
        self.error = error
        self.httpStatusCode = httpStatusCode
        self.refreshPerformed = refreshPerformed
        self.failureKind = failureKind
    }
}

/// Request-scoped bridge handle. The HTTP invocation and every later state
/// and cancellation request use the same ID.
/// The invocation continues after the first UI generation is presented; its
/// final response is cached instead of being discarded by a first-wins race.
final class InteractionHandle: @unchecked Sendable, Identifiable {
    typealias StateProvider = @Sendable (UUID) async throws
        -> AndroidBridgeUIState
    typealias CancelProvider = @Sendable (UUID, String) async throws -> Void
    typealias ConfirmProvider = @Sendable (UUID) async throws
        -> AndroidBridgeUIState
    typealias TerminalCleanup = @Sendable (UUID) async -> Void

    private actor State {
        var latestInteraction: ConfigurationInteraction?
        var terminalResult:
            Result<ConfigurationInteractionTerminalResponse, Error>?
        var waiters: [
            CheckedContinuation<ConfigurationInteractionTerminalResponse, Error>
        ] = []

        func record(_ interaction: ConfigurationInteraction) {
            latestInteraction = interaction
        }

        func latest() -> ConfigurationInteraction? {
            latestInteraction
        }

        @discardableResult
        func finish(
            _ result: Result<ConfigurationInteractionTerminalResponse, Error>
        ) -> Bool {
            guard terminalResult == nil else { return false }
            terminalResult = result
            let currentWaiters = waiters
            waiters.removeAll()
            currentWaiters.forEach { $0.resume(with: result) }
            return true
        }

        func terminalResponseIfAvailable() throws
            -> ConfigurationInteractionTerminalResponse? {
            guard let terminalResult else { return nil }
            return try terminalResult.get()
        }

        func terminalResponse() async throws
            -> ConfigurationInteractionTerminalResponse {
            if let terminalResult {
                return try terminalResult.get()
            }
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    let id: UUID
    let actionKind: ConfigurationInteraction.ActionKind

    private let state = State()
    private let stateProvider: StateProvider?
    private let cancelProvider: CancelProvider?
    private let confirmProvider: ConfirmProvider?
    private let terminalCleanup: TerminalCleanup?
    private var invocationTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        actionKind: ConfigurationInteraction.ActionKind,
        stateProvider: StateProvider? = nil,
        cancelProvider: CancelProvider? = nil,
        confirmProvider: ConfirmProvider? = nil,
        terminalCleanup: TerminalCleanup? = nil,
        operation: @escaping @Sendable () async throws
            -> ConfigurationInteractionTerminalResponse
    ) {
        self.id = id
        self.actionKind = actionKind
        self.stateProvider = stateProvider
        self.cancelProvider = cancelProvider
        self.confirmProvider = confirmProvider
        self.terminalCleanup = terminalCleanup
        let state = self.state
        let cleanup = terminalCleanup
        let requestID = id
        invocationTask = Task {
            do {
                let response = try await operation()
                // Retire the request-owned input capability before publishing
                // its terminal value. Every waiter therefore observes the
                // terminal state only after old taps/swipes are fenced out.
                await cleanup?(requestID)
                await state.finish(.success(response))
            } catch {
                await cleanup?(requestID)
                await state.finish(.failure(error))
            }
        }
    }

    func record(_ interaction: ConfigurationInteraction) async {
        guard interaction.id == id else { return }
        await state.record(interaction)
    }

    func latestInteraction() async -> ConfigurationInteraction? {
        await state.latest()
    }

    func finalResponse() async throws
        -> ConfigurationInteractionTerminalResponse {
        try await state.terminalResponse()
    }

    func currentState() async throws -> AndroidBridgeUIState {
        guard let stateProvider else {
            throw AppError.spider("当前桥不支持请求级配置状态")
        }
        return try await stateProvider(id)
    }

    func confirmCompletion() async throws -> AndroidBridgeUIState {
        guard let confirmProvider else {
            throw AppError.spider("当前桥不支持显式确认配置完成")
        }
        return try await confirmProvider(id)
    }

    func cancel(reason: String = "hostCancelled") {
        invocationTask?.cancel()
        guard let cancelProvider else { return }
        let requestID = id
        Task {
            try? await cancelProvider(requestID, reason)
        }
    }
    /// Cancels the provider worker and waits for the request-scoped bridge to
    /// acknowledge the cancellation before the host starts another action.
    func cancelAndWait(reason: String = "hostCancelled") async {
        invocationTask?.cancel()
        guard let cancelProvider else { return }
        try? await cancelProvider(id, reason)
    }
}

struct AndroidBridgeSurfaceBounds: Decodable, Equatable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
    let width: Int
    let height: Int

    var isValid: Bool {
        left >= 0
            && top >= 0
            && right > left
            && bottom > top
            && width == right - left
            && height == bottom - top
    }
}

struct AndroidBridgeDisplayBounds: Decodable, Equatable, Sendable {
    let width: Int
    let height: Int

    var isValid: Bool { width > 0 && height > 0 }
}

struct AndroidBridgeDialogWindow: Decodable, Equatable, Sendable {
    let windowID: String
    let bounds: AndroidBridgeSurfaceBounds
    let contentBounds: AndroidBridgeSurfaceBounds?
    let nearFullDisplay: Bool
    let memberWindowCount: Int?
}

enum AndroidActionSurfacePresentationMode: String, Equatable, Sendable {
    case dialogCrop
    case fullDisplay
}

struct AndroidActionSurfaceCaptureDescriptor: Equatable, Sendable {
    let presentationMode: AndroidActionSurfacePresentationMode
    let fallbackReason: String
    let windowID: String
    let windowRevision: Int
    let windowStackDepth: Int
    let windowBounds: AndroidBridgeSurfaceBounds?
    let windowContentBounds: AndroidBridgeSurfaceBounds?
    let displayBounds: AndroidBridgeDisplayBounds?
}

enum AndroidActionSurfaceImageCropper {
    static func crop(
        pngData: Data,
        bounds: AndroidBridgeSurfaceBounds,
        display: AndroidBridgeDisplayBounds
    ) throws -> Data {
        guard bounds.isValid,
              display.isValid,
              bounds.right <= display.width,
              bounds.bottom <= display.height,
              let bitmap = NSBitmapImageRep(data: pngData),
              bitmap.pixelsWide == display.width,
              bitmap.pixelsHigh == display.height,
              let image = bitmap.cgImage else {
            throw AppError.spider("Android Dialog 裁剪坐标已失效")
        }
        // Android bounds use a top-left origin; CGImage cropping uses a
        // bottom-left origin. The conversion is geometry only and does not
        // inspect any Dialog child content.
        let cropRect = CGRect(
            x: bounds.left,
            y: display.height - bounds.bottom,
            width: bounds.width,
            height: bounds.height
        )
        guard let cropped = image.cropping(to: cropRect) else {
            throw AppError.spider("无法裁剪 Android Dialog 画面")
        }
        let representation = NSBitmapImageRep(cgImage: cropped)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw AppError.spider("无法编码 Android Dialog 画面")
        }
        return data
    }
}

enum AndroidActionSurfaceInputGeometryPolicy {
    static func displayPoint(
        localX: Int,
        localY: Int,
        cropWidth: Int,
        cropHeight: Int,
        originX: Int,
        originY: Int,
        displayWidth: Int,
        displayHeight: Int
    ) -> (x: Int, y: Int)? {
        guard cropWidth > 0,
              cropHeight > 0,
              displayWidth > 0,
              displayHeight > 0,
              localX >= 0,
              localY >= 0,
              localX < cropWidth,
              localY < cropHeight,
              originX >= 0,
              originY >= 0,
              originX + localX < displayWidth,
              originY + localY < displayHeight else {
            return nil
        }
        return (originX + localX, originY + localY)
    }
}

struct AndroidBridgeUIState: Decodable, Equatable, Sendable {
    let interactionID: String?
    let revision: Int?
    let kind: String?
    let phase: String?
    let generation: Int?
    let outcome: String?
    let terminal: Bool?
    let error: String?
    var userConfirmed: Bool? = nil
    var completionSource: String? = nil
    var cancelReason: String? = nil
    var confirmationAccepted: Bool? = nil
    /// The request-scoped Android worker is the only authoritative signal
    /// that a legacy Spider has finished persisting credentials. UI changes
    /// can happen earlier while that worker is still active.
    var workerReturned: Bool? = nil
    /// Opaque request owner minted by the macOS host and bound by the Bridge
    /// to one configuration/site/JAR tuple.
    var providerOwnerID: String? = nil
    var configurationID: String? = nil
    var siteKey: String? = nil
    /// Lifecycle-only ownership for the complete Android display. This remains
    /// true when a request-owned provider window launches a browser or another
    /// Activity and the Bridge process itself has no visible root. It is never
    /// authorization-success evidence.
    var surfaceActive: Bool? = nil
    var surfaceRequestScoped: Bool? = nil
    var surfaceInteractionID: String? = nil
    var surfaceMode: String? = nil
    var surfacePresentationMode: String? = nil
    var surfaceFallbackReason: String? = nil
    var surfaceWindowID: String? = nil
    var surfaceWindowRevision: Int? = nil
    var surfaceWindowStackDepth: Int? = nil
    var surfaceWindowBounds: AndroidBridgeSurfaceBounds? = nil
    var surfaceWindowContentBounds: AndroidBridgeSurfaceBounds? = nil
    var surfaceDisplayBounds: AndroidBridgeDisplayBounds? = nil
    var surfaceDialogStack: [AndroidBridgeDialogWindow]? = nil
    var surfaceDialogTrackerAvailable: Bool? = nil
    /// Cancellation is cooperative inside third-party DEX code. When the
    /// worker ignores interruption the Bridge asks the owned runtime to
    /// restart before another interaction is admitted.
    var workerStopped: Bool? = nil
    var requiresBridgeRestart: Bool? = nil

    var interactionGeneration: Int? {
        generation ?? revision
    }

    var hasRequestScopedActionSurface: Bool {
        guard terminal != true,
              surfaceActive == true,
              surfaceRequestScoped == true,
              let stateID = interactionID.flatMap(UUID.init(uuidString:)),
              let surfaceID = surfaceInteractionID.flatMap(UUID.init(uuidString:)),
              let mode = normalizedActionSurfaceMode,
              [
                "actionactivity",
                "providerwindow",
                "externalactivity",
                "delegatedactivity"
              ]
                .contains(mode)
        else {
            return false
        }
        // ActionActivity is opaque and request-owned. Its full display is the
        // only unstructured provider UI exposed to macOS.
        return stateID == surfaceID
    }

    var normalizedActionSurfaceMode: String? {
        surfaceMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var actionSurfaceCaptureDescriptor:
        AndroidActionSurfaceCaptureDescriptor? {
        guard hasRequestScopedActionSurface else { return nil }
        let normalizedPresentation = surfacePresentationMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedPresentation {
        case "dialogcrop":
            let contentBoundsAreValid = surfaceWindowContentBounds.map {
                $0.isValid
                    && $0.left >= (surfaceWindowBounds?.left ?? 0)
                    && $0.top >= (surfaceWindowBounds?.top ?? 0)
                    && $0.right <= (surfaceWindowBounds?.right ?? 0)
                    && $0.bottom <= (surfaceWindowBounds?.bottom ?? 0)
            } ?? true
            guard let bounds = surfaceWindowBounds,
                  bounds.isValid,
                  contentBoundsAreValid,
                  let display = surfaceDisplayBounds,
                  display.isValid,
                  bounds.right <= display.width,
                  bounds.bottom <= display.height,
                  let windowID = surfaceWindowID?.nonEmptyBridgeValue,
                  let windowRevision = surfaceWindowRevision,
                  windowRevision > 0 else {
                return nil
            }
            return AndroidActionSurfaceCaptureDescriptor(
                presentationMode: .dialogCrop,
                fallbackReason: "",
                windowID: windowID,
                windowRevision: windowRevision,
                windowStackDepth: max(1, surfaceWindowStackDepth ?? 1),
                windowBounds: bounds,
                windowContentBounds: surfaceWindowContentBounds,
                displayBounds: display
            )
        case "fulldisplay":
            return AndroidActionSurfaceCaptureDescriptor(
                presentationMode: .fullDisplay,
                fallbackReason: surfaceFallbackReason ?? "",
                windowID: surfaceWindowID ?? "",
                windowRevision: max(0, surfaceWindowRevision ?? 0),
                windowStackDepth: max(0, surfaceWindowStackDepth ?? 0),
                windowBounds: nil,
                windowContentBounds: surfaceWindowContentBounds,
                displayBounds: surfaceDisplayBounds
            )
        default:
            // An older/fallback Bridge can still expose a request-scoped full
            // Android display. Missing geometry must never become a crop.
            return AndroidActionSurfaceCaptureDescriptor(
                presentationMode: .fullDisplay,
                fallbackReason: "dialogProtocolUnavailable",
                windowID: "",
                windowRevision: 0,
                windowStackDepth: 0,
                windowBounds: nil,
                windowContentBounds: nil,
                displayBounds: surfaceDisplayBounds
            )
        }
    }

    /// Any request-owned provider UI which the native configuration sheet can
    /// render. Ordering and ordinary configuration surfaces intentionally use
    /// this predicate without becoming authorization requests.
    var isProviderUIPrompt: Bool {
        guard hasRequestScopedActionSurface,
              let mode = normalizedActionSurfaceMode else {
            return false
        }
        // `actionActivity` is only the request-owned placeholder. Publishing
        // it before a provider Dialog/browser exists exposes the internal
        // "Android Action Session" page and makes slow providers look stuck.
        return mode != "actionactivity"
    }

    /// A provider UI may enter the account lifecycle only when the request
    /// itself was explicitly declared as authorization. A QR-shaped image in
    /// playback, ordering or configuration content is not login evidence.
    var isAuthorizationPrompt: Bool {
        guard kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == ConfigurationInteraction.ActionKind
            .authorization.rawValue.lowercased() else {
            return false
        }
        return hasRequestScopedActionSurface
    }

    func configurationInteraction(
        requestID: UUID,
        actionKind: ConfigurationInteraction.ActionKind
    ) -> ConfigurationInteraction {
        let normalizedPhase = phase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedOutcome = outcome?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let declaredActionKind: ConfigurationInteraction.ActionKind = {
            guard let kind else {
                return actionKind
            }
            let rawKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKind.isEmpty else { return actionKind }
            if let exact = ConfigurationInteraction.ActionKind(
                rawValue: rawKind
            ) {
                return exact
            }
            switch rawKind.lowercased() {
            case "websetting", "web_setting": return .webSetting
            case "nativesetting", "native_setting": return .nativeSetting
            case "command": return .command
            case "immediate": return .immediate
            case "toggle": return .toggle
            case "ordering", "order": return .ordering
            case "configuration", "config": return .configuration
            case "authorization", "authorisation", "auth":
                return .authorization
            case "playback", "play": return .playback
            default: return actionKind
            }
        }()
        let interactionPhase: ConfigurationInteraction.Phase
        switch normalizedPhase {
        case "started", "invoking":
            interactionPhase = .invoking
        case "awaitinguser", "awaiting_user":
            interactionPhase = .status
        case "chooser", "choice", "select":
            interactionPhase = .choice
        case "credentials", "credential", "form", "input":
            interactionPhase = .form
        case "transitioning", "loading", "waiting", "processing":
            interactionPhase = .transitioning
        case "reattaching":
            interactionPhase = .reattaching
        case "completed", "success", "succeeded":
            interactionPhase = .completed
        case "failed", "error", "hostunavailable":
            interactionPhase = .failed
        case "cancelled", "canceled", "superseded":
            interactionPhase = .cancelled
        default:
            interactionPhase = .status
        }

        let resolvedOutcome: ConfigurationInteraction.Outcome
        switch normalizedOutcome {
        case "completed", "success", "succeeded":
            resolvedOutcome = .succeeded
        case "failed", "error":
            resolvedOutcome = .failed
        case "cancelled", "canceled", "superseded":
            resolvedOutcome = .cancelled
        case "none", "stay":
            resolvedOutcome = .pending
        default:
            switch interactionPhase {
            case .completed:
                resolvedOutcome = .succeeded
            case .failed:
                resolvedOutcome = .failed
            case .cancelled:
                resolvedOutcome = .cancelled
            default:
                resolvedOutcome = .pending
            }
        }

        return ConfigurationInteraction(
            id: requestID,
            actionKind: declaredActionKind,
            phase: interactionPhase,
            outcome: resolvedOutcome,
            generation: interactionGeneration
        )
    }
}

struct AndroidBridgeUIRequired: Error {
    let state: AndroidBridgeUIState
    let interaction: ConfigurationInteraction?
    let handle: InteractionHandle?

    init(
        state: AndroidBridgeUIState,
        interaction: ConfigurationInteraction? = nil,
        handle: InteractionHandle? = nil
    ) {
        self.state = state
        self.interaction = interaction
        self.handle = handle
    }
}

/// A TVBox Spider can return an episode token which is valid only while the
/// exact provider instance that created it remains alive. Treat the provider's
/// explicit missing-UUID code as lifecycle state, not as a media or network
/// failure, so history recovery can rebuild that one site and resolve a fresh
/// episode before retrying playback.
struct AndroidProviderContextInvalid: Error, Equatable, LocalizedError, Sendable {
    let providerMessage: String

    var errorDescription: String? {
        "TVBox 来源运行上下文已失效，需要重新获取影片详情"
    }
}

enum AndroidProviderContextRecoveryPolicy {
    static let unavailableCode = "provideruuidunavailable"

    static func recognizes(_ message: String) -> Bool {
        let normalized = message.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
        return normalized.contains(unavailableCode)
    }

    static func contextError(from error: Error) -> AndroidProviderContextInvalid? {
        if let typed = error as? AndroidProviderContextInvalid {
            return typed
        }
        let message = error.localizedDescription
        guard recognizes(message) else { return nil }
        return AndroidProviderContextInvalid(providerMessage: message)
    }

    /// Performs one bounded site rebuild. A second provider-context failure is
    /// returned to the host instead of entering an unbounded destroy/retry loop.
    static func recover<Value>(
        operation: () async throws -> Value,
        reset: () async throws -> Void
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is AndroidProviderContextInvalid {
            try await reset()
            return try await operation()
        }
    }
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
                recommendations: result.recommendations,
                actionItems: result.actionItems
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
        switch try await select(id: id) {
        case .detail(let detail):
            return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        case .search:
            throw AppError.spider("该卡片只提供发现信息，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        return try SpiderResponseMapper.selection(
            await session.detail(id: id),
            site: site,
            baseURL: baseURL
        )
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        return try SpiderResponseMapper.selection(
            await session.detail(id: summary.videoID),
            site: site,
            baseURL: baseURL,
            fallbackSummary: summary,
            allowsPlaceholderAction: summary.resolvedContentKind == .action
        )
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable != 0, !quick || site.quickSearch == 1 else {
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

/// Structural compatibility metadata for the legacy MyDriveGuard action
/// surface. The upstream CatVod response exposes stable action identifiers but
/// omits `tag`, so every card would otherwise be treated as a generic native
/// configuration operation. Bind only the documented provider class and its
/// opaque action IDs; localized titles remain presentation-only.
enum MyDriveGuardActionContract {
    static let providerAPI = "csp_MyDriveGuard"
    static let configurationCenterAPI = "csp_FishConfig"
    static let loginAction = "LoginShow"

    /// Both providers expose the same stable cloud-account action contract.
    /// `csp_FishConfig` is the configuration-center facade used by current
    /// sources, while `csp_MyDriveGuard` is the underlying legacy provider.
    /// Bind the behavior to these provider classes and opaque action IDs, not
    /// to localized card titles such as “扫码登录”.
    static func supportsAccountAuthorization(api: String) -> Bool {
        let normalized = api.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized == providerAPI || normalized == configurationCenterAPI
    }

    static func tag(for action: String?) -> String? {
        switch action?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case loginAction, "pushCkShow":
            return "authorization"
        case "ucClean", "quarkClean", "BdClean", "aliClean":
            return "command"
        case "panSortShow", "panSourceSortShow":
            return "order"
        default:
            return nil
        }
    }

    static func applying(to item: SiteActionItem) -> SiteActionItem {
        guard item.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false,
              let tag = tag(for: item.action) else {
            return item
        }
        var updated = item
        updated.tag = tag
        return updated
    }

    static func applying(to summary: VideoSummary) -> VideoSummary {
        guard summary.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false,
              let tag = tag(for: summary.action) else {
            return summary
        }
        var updated = summary
        updated.tag = tag
        return updated
    }
}

final class AndroidDexSpiderSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaDexSpider

    private let configurationIdentity: String
    private let configurationHosts: [String]
    private let baseURL: URL?
    private let jarReference: String
    private let bridge: AndroidDexBridgeClient
    /// Credential-free account-state scope for this exact configuration,
    /// site and JAR. It intentionally matches the owner capability bound by
    /// Android so a configuration switch or JAR replacement cannot inherit a
    /// stale "已授权" snapshot.
    let cloudAccountScopeID: String?

    init(
        site: SiteConfiguration,
        configurationID: UUID,
        configurationHosts: [String],
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
        let normalizedConfigurationID = configurationID.uuidString.lowercased()
        configurationIdentity = normalizedConfigurationID
        self.configurationHosts = configurationHosts
        self.jarReference = jarReference
        self.baseURL = baseURL
        self.bridge = bridge
        if let jar = try? AndroidDexBridgeClient.jarParts(
            jarReference,
            baseURL: baseURL
        ) {
            cloudAccountScopeID = AndroidDexBridgeClient.providerOwnerID(
                configurationID: normalizedConfigurationID,
                siteKey: site.key,
                jarURL: jar.url,
                jarMD5: jar.md5
            )
        } else {
            cloudAccountScopeID = nil
        }
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
        let result = Self.applyingHomeContract(
            to: try SpiderResponseMapper.home(
                homeValue,
                homeVideoValue: homeVideoValue,
                site: site,
                baseURL: baseURL
            ),
            site: site
        )
        guard site.categories.isEmpty else {
            let allowed = Set(site.categories)
            return SiteHome(
                categories: result.categories.filter { allowed.contains($0.name) },
                recommendations: result.recommendations,
                actionItems: result.actionItems
            )
        }
        return result
    }

    /// Restores semantics which are part of a known Java/Dex provider's home
    /// contract but are not encoded in CatVod's generic `class` objects.
    ///
    /// MyDriveGuard always exposes `peizhi` as a host configuration entry.
    /// After authorization it appends media providers (for example Quark), so
    /// the old singleton-empty-category fallback can no longer identify that
    /// entry.  Bind the meaning to the provider class and its stable contract
    /// identifier; never infer it from a localized display title.
    static func applyingHomeContract(
        to home: SiteHome,
        site: SiteConfiguration
    ) -> SiteHome {
        guard MyDriveGuardActionContract.supportsAccountAuthorization(
            api: site.api
        ) else {
            return home
        }
        var updated = home
        for index in updated.categories.indices
        where updated.categories[index].id == "peizhi" {
            updated.categories[index].contentKind = .action
        }
        updated.actionItems = updated.actionItems.map(
            MyDriveGuardActionContract.applying(to:)
        )
        return updated
    }

    func restoringHomeContract(in home: SiteHome) -> SiteHome {
        Self.applyingHomeContract(to: home, site: site)
    }

    static func homeConfirmsAuthorization(
        _ home: SiteHome,
        site: SiteConfiguration
    ) -> Bool {
        guard MyDriveGuardActionContract.supportsAccountAuthorization(
            api: site.api
        ) else {
            return false
        }
        return applyingHomeContract(to: home, site: site).categories.contains {
            $0.resolvedContentKind == .media
        }
    }

    func homeConfirmsAuthorization(_ home: SiteHome) -> Bool {
        Self.homeConfirmsAuthorization(home, site: site)
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try SpiderResponseMapper.javaDexCategoryPage(
            await categoryValue(id: id, page: page, filters: filters),
            site: site,
            baseURL: baseURL,
            page: page
        )
    }

    func actionCategory(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        let mapped = try SpiderResponseMapper.actionPage(
            await categoryValue(id: id, page: page, filters: filters),
            site: site,
            baseURL: baseURL,
            page: page
        )
        guard MyDriveGuardActionContract.supportsAccountAuthorization(
            api: site.api
        ) else {
            return mapped
        }
        return VideoPage(
            items: mapped.items.map(MyDriveGuardActionContract.applying(to:)),
            pagination: mapped.pagination
        )
    }

    private func categoryValue(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> JSONValue {
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
        if Self.shouldRetryCategory(page: page, value: value) {
            // Guard spiders can retain a failed upstream delegate. Recreate
            // the site and replay its normal home lifecycle once before
            // accepting an empty first page. A decoded `{ list: [] }` is also
            // a failed first-page result for these spiders; limiting recovery
            // to one replay keeps legitimately empty categories bounded.
            _ = try? await invoke(method: "destroy", arguments: [])
            _ = try? await loadHomeValues()
            value = try await invoke(
                method: "category",
                arguments: arguments
            )
        }
        return value
    }

    static func shouldRetryCategory(page: Int, value: JSONValue) -> Bool {
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

    func detail(id: String) async throws -> VideoDetail {
        switch try await select(id: id) {
        case .detail(let detail):
            return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        case .search:
            throw AppError.spider("该卡片只提供发现信息，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        try SpiderResponseMapper.selection(
            await invoke(method: "detail", arguments: [.array([.string(id)])]),
            site: site,
            baseURL: baseURL
        )
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try SpiderResponseMapper.selection(
            await invoke(
                method: "detail",
                arguments: [.array([.string(summary.videoID)])]
            ),
            site: site,
            baseURL: baseURL,
            fallbackSummary: summary,
            allowsPlaceholderAction: summary.resolvedContentKind == .action
        )
    }

    func select(action item: SiteActionItem) async throws -> SiteSelectionResult {
        try await select(action: item, interactionID: nil)
    }

    /// Executes a host-owned configuration request with the exact interaction
    /// identifier that AppState reserved. Action-backed cards and detail-backed
    /// cards share this path so neither can create an unrelated bridge request.
    func select(
        action item: SiteActionItem,
        interactionID: UUID?
    ) async throws -> SiteSelectionResult {
        switch item.resolvedRoute {
        case .actionCategory:
            throw AppError.spider("配置分类必须先加载操作列表，不能作为影视详情打开")
        case .command(let rawAction):
            let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else {
                throw AppError.spider("配置动作内容为空")
            }
            let interactionKind = Self.interactionActionKind(tag: item.tag)
            return .action(
                try await invoke(
                    method: "action",
                    arguments: [.string(action)],
                    // FongMi invokes every action opaquely. Use a scoped
                    // interaction whenever AppState supplied one, including
                    // commands whose normal result is empty. A provider may
                    // still create native UI regardless of its metadata tag.
                    monitorsAuthorization: interactionID != nil,
                    interactionKind: interactionKind,
                    interactionID: interactionID
                )
            )
        case .providerSelection(let itemID):
            return try SpiderResponseMapper.selection(
                await invoke(
                    method: "detail",
                    arguments: [.array([.string(itemID)])],
                    monitorsAuthorization: true,
                    interactionKind: Self.interactionActionKind(tag: item.tag),
                    interactionID: interactionID
                ),
                site: site,
                baseURL: baseURL,
                fallbackSummary: item.selectionSummary,
                allowsPlaceholderAction: true
            )
        }
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable != 0, !quick || site.quickSearch == 1 else {
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
        try await requestPlayer(
            flag: flag,
            episodeURL: episodeURL,
            refreshPlayback: false,
            interactionID: nil
        )
    }

    /// Keeps playerContent and any authorization UI inside the playback
    /// request already owned by AppState. The eventual provider result is
    /// cached by the same InteractionHandle and can resume that player without
    /// issuing a second, unrelated playerContent call.
    func player(
        flag: String,
        episodeURL: String,
        interactionID: UUID
    ) async throws -> SitePlaybackResult {
        try await requestPlayer(
            flag: flag,
            episodeURL: episodeURL,
            refreshPlayback: false,
            interactionID: interactionID
        )
    }

    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        // Android/Dex episode locators are provider-instance replay tokens, not
        // durable history identities. Always rebuild from current detail before
        // playerContent, even when an older record incorrectly marked a locator
        // as provider-stable.
        try await AndroidProviderContextRecoveryPolicy.recover {
            try await resolveFreshPlayback(request, interactionID: nil)
        } reset: {
            try await resetSpiderForPlaybackRecovery()
        }
    }

    func refreshPlayback(
        _ request: PlaybackRefreshRequest,
        interactionID: UUID
    ) async throws -> RefreshedSitePlayback {
        try await AndroidProviderContextRecoveryPolicy.recover {
            try await resolveFreshPlayback(
                request,
                interactionID: interactionID
            )
        } reset: {
            try await resetSpiderForPlaybackRecovery()
        }
    }

    private func resolveFreshPlayback(
        _ request: PlaybackRefreshRequest,
        interactionID: UUID?
    ) async throws -> RefreshedSitePlayback {
        let selected = try await resolvePlaybackRefreshSelection(request)
        let result = try await requestPlayer(
            flag: selected.source.name,
            episodeURL: selected.episode.url,
            refreshPlayback: true,
            interactionID: interactionID
        )
        return RefreshedSitePlayback(
            detail: selected.detail,
            source: selected.source,
            episode: selected.episode,
            playbackResult: result
        )
    }

    private func resetSpiderForPlaybackRecovery() async throws {
        // `destroy` is keyed by jar + site in the Bridge. Do not restart the
        // Android runtime or invalidate unrelated providers/configurations.
        _ = try await invoke(method: "destroy", arguments: [])
        // Match FongMi's navigation-first lifecycle. Home warm-up is best
        // effort because legitimate search/detail-only spiders may return no
        // home content; the following detail call remains authoritative.
        _ = try? await loadHomeValues()
    }

    private func requestPlayer(
        flag: String,
        episodeURL: String,
        refreshPlayback: Bool,
        interactionID: UUID?
    ) async throws -> SitePlaybackResult {
        do {
            let providerValue = try await invoke(
                method: "play",
                arguments: [.string(flag), .string(episodeURL), .array([])],
                monitorsAuthorization: interactionID != nil,
                interactionKind: interactionID == nil ? nil : .playback,
                refreshPlayback: refreshPlayback,
                interactionID: interactionID
            )
            return try playbackResult(
                from: providerValue,
                flag: flag,
                episodeURL: episodeURL
            )
        } catch {
            if let contextError = AndroidProviderContextRecoveryPolicy
                .contextError(from: error) {
                throw contextError
            }
            throw error
        }
    }

    /// Maps the terminal value from the exact Bridge invocation that produced
    /// an interaction. AppState uses this instead of issuing a second `play`
    /// request after authorization, preserving the provider's authoritative
    /// media-session capability.
    func playbackResult(
        from providerValue: JSONValue,
        flag: String,
        episodeURL: String
    ) throws -> SitePlaybackResult {
        var result = try SpiderResponseMapper.player(
            providerValue,
            site: site
        )
        result = Self.applyingPlaybackRequestContract(
            to: result,
            siteHeaders: HTTPHeaders(site.header)
        )
        let needsParsing = result.needsParsing
        let rewriteMediaURL: (String) throws -> String = { rawURL in
            needsParsing
                ? self.bridge.hostReachableProxyURL(rawURL)
                : try self.bridge.hostReachableMediaURL(rawURL)
        }
        result.url = try rewriteMediaURL(result.url)
        result.qualities = try result.qualities.map { quality in
            PlaybackQuality(
                name: quality.name,
                url: try rewriteMediaURL(quality.url)
            )
        }
        if let playURL = result.playURL {
            result.playURL = try rewriteMediaURL(playURL)
        }
        result.subtitles = result.subtitles.map {
            URL(string: bridge.hostReachableProxyURL($0.absoluteString)) ?? $0
        }

        let resourceReference = Self.playbackResourceReference(
            site: site,
            configurationIdentity: configurationIdentity,
            flag: flag,
            episodeURL: episodeURL
        )
        let providerSessionID = AndroidDexBridgeClient
            .providerMediaSessionID(from: result.url)
        let handoff = Self.playbackHandoff(from: providerValue)
        let handoffMatchesURL = providerSessionID != nil
            && handoff?.mediaSessionID == providerSessionID
        let isLoopback = AndroidDexBridgeClient.isLoopbackURL(result.url)
        let runtimeSessionID = providerSessionID ?? UUID().uuidString
        // A scoped bridge capability owns all upstream request headers. Do not
        // duplicate Cookie, Authorization or signed URL context in the Mac
        // playback object. Compatibility bridges still require the old header
        // path and are explicitly marked as such below.
        if providerSessionID != nil {
            result.headers = [:]
        }
        result.resourceReference = resourceReference
        result.mediaSession = PlaybackMediaSession(
            sessionID: runtimeSessionID,
            transport: Self.playbackSessionTransport(
                mediaURL: result.url,
                providerSessionID: providerSessionID
            ),
            mediaURL: result.url,
            headers: result.headers,
            authorizationContextReference: providerSessionID,
            proxyRequestID: providerSessionID ?? UUID().uuidString,
            upstreamResourceFingerprint: handoffMatchesURL
                ? handoff?.upstreamFingerprint
                : nil,
            refreshPerformed: handoffMatchesURL
                ? handoff?.refreshPerformed
                : nil,
            expiresAt: nil,
            redirectPolicy: isLoopback ? .follow : .providerDefined,
            rangePolicy: isLoopback ? .forward : .providerDefined,
            resourceReference: resourceReference
        )
        return result
    }

    func acceptsPlaybackResourceReference(
        _ reference: PlaybackResourceReference
    ) -> Bool {
        if let expiresAt = reference.expiresAt, expiresAt <= Date() {
            return false
        }
        let locator = reference.stableResourceLocator.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let sourceIdentity = reference.sourceIdentity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let episodeIdentity = reference.episodeIdentity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return reference.schemaVersion == 1
            && reference.configurationIdentity == configurationIdentity
            && reference.siteIdentity == site.key
            && reference.providerKind == "android-dex-spider"
            && reference.providerVersion == 1
            && !locator.isEmpty
            && !sourceIdentity.isEmpty
            && !episodeIdentity.isEmpty
    }

    struct PlaybackHandoff: Equatable, Sendable {
        let mediaSessionID: String
        let upstreamFingerprint: String?
        let refreshPerformed: Bool?
    }

    /// Reads only the bridge-owned, non-secret handoff metadata. Signed URLs,
    /// nested media URLs and header values are deliberately ignored here.
    static func playbackHandoff(from value: JSONValue) -> PlaybackHandoff? {
        guard let object = value.objectValue,
              let mediaSessionID = object["mediaSessionID"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !mediaSessionID.isEmpty else {
            return nil
        }
        let fingerprint = object["upstreamFingerprint"]?.stringValue.flatMap {
            validatedUpstreamFingerprint($0)
        }
        let refreshPerformed: Bool?
        if case .bool(let value)? = object["refreshPerformed"] {
            refreshPerformed = value
        } else {
            refreshPerformed = nil
        }
        return PlaybackHandoff(
            mediaSessionID: mediaSessionID,
            upstreamFingerprint: fingerprint,
            refreshPerformed: refreshPerformed
        )
    }

    static func validatedUpstreamFingerprint(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return value
    }

    static func playbackSessionTransport(
        mediaURL: String,
        providerSessionID: String?
    ) -> PlaybackMediaSession.Transport {
        if providerSessionID?.isEmpty == false {
            return .providerLoopback
        }
        if AndroidDexBridgeClient.isLoopbackURL(mediaURL) {
            return .compatibilityLoopback
        }
        return .compatibilityDirect
    }

    static func applyingPlaybackRequestContract(
        to input: SitePlaybackResult,
        siteHeaders: HTTPHeaders
    ) -> SitePlaybackResult {
        var result = input
        result.headers = siteHeaders.merging(result.headers)
        // `parse=1` / `jx=1` is an unresolved page URL, not a provider-owned
        // media request. Marking every Android result player-authoritative
        // caused PlaybackResolutionAttemptContext to remove all configured
        // parsers before resolution, so QY and similar lines could never use
        // the parser supplied by a TVBox configuration.
        result.validationPolicy = result.needsParsing
            ? .preflight
            : .playerAuthoritative
        return result
    }

    static func playbackResourceReference(
        site: SiteConfiguration,
        configurationIdentity: String,
        flag: String,
        episodeURL: String
    ) -> PlaybackResourceReference {
        PlaybackResourceReference(
            configurationIdentity: configurationIdentity,
            siteIdentity: site.key,
            providerKind: "android-dex-spider",
            providerVersion: 1,
            // Provider protocol data is kept intact and opaque. No source
            // name, domain, card ID or URL fragment controls behavior here.
            stableResourceLocator: episodeURL,
            sourceIdentity: PlaybackReferenceIdentity.source(
                explicitIdentity: "android-dex-source:\(site.key):\(flag)",
                episodes: []
            ),
            episodeIdentity: PlaybackReferenceIdentity.episode(
                name: "",
                reference: episodeURL
            ),
            stability: .providerReplay,
            expiresAt: nil
        )
    }

    func action(_ action: String) async throws -> JSONValue {
        try await invoke(method: "action", arguments: [.string(action)])
    }

    func action(
        _ action: String,
        interactionID: UUID,
        interactionKind: ConfigurationInteraction.ActionKind
    ) async throws -> JSONValue {
        try await invoke(
            method: "action",
            arguments: [.string(action)],
            monitorsAuthorization: true,
            interactionKind: interactionKind,
            interactionID: interactionID
        )
    }

    private func invoke(
        method: String,
        arguments: [JSONValue],
        monitorsAuthorization: Bool = false,
        interactionKind: ConfigurationInteraction.ActionKind? = nil,
        refreshPlayback: Bool = false,
        interactionID: UUID? = nil
    ) async throws -> JSONValue {
        try await bridge.invoke(
            site: site,
            configurationID: configurationIdentity,
            configurationHosts: configurationHosts,
            jarReference: jarReference,
            baseURL: baseURL,
            method: method,
            arguments: arguments,
            monitorsAuthorization: monitorsAuthorization,
            interactionKind: interactionKind,
            refreshPlayback: refreshPlayback,
            requestedInteractionID: interactionID
        )
    }

    /// Maps only provider protocol metadata. Source keys, display titles,
    /// action IDs and domains are intentionally absent from this decision.
    static func interactionActionKind(
        tag: String?
    ) -> ConfigurationInteraction.ActionKind {
        switch tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "command": return .command
        case "immediate": return .immediate
        case "toggle": return .toggle
        case "order", "ordering": return .ordering
        // Only the provider protocol's explicit authorization kind may enter
        // the authorization lifecycle. Presentation hints such as `qr` or
        // `credential` are not an authority boundary: ordinary configuration
        // actions can contain images and text inputs too.
        case "authorization", "authorisation", "auth":
            return .authorization
        case "web": return .webSetting
        case "native": return .nativeSetting
        default: return .configuration
        }
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
    case javaRuntimeMissing
    case adbUnavailable
    case adbPrivateServerFailed
    case adbDeviceMissing
    case adbDeviceOffline
    case adbSerialMissingTimeout
    case adbOfflineTimeout
    case adbReconnectFailed
    case hostGPUADBOfflineTimeout
    case softwareGPUADBOfflineTimeout
    case privateAVDRecoveryRequired
    case emulatorLaunchFailed
    case emulatorLaunchTimedOut
    case emulatorExitedBeforeADB
    case emulatorExitedEarly
    case emulatorExited
    case appRequestedTermination
    case emulatorOwnershipMismatch
    case emulatorProcessMismatch
    case emulatorRuntimeConflict
    case portConflict
    case unexpectedSerial
    case androidBootTimedOut
    case emulatorNetworkUnavailable
    case bridgeAPKMissing
    case bridgeInstallFailed
    case bridgeLaunchFailed
    case portForwardFailed
    case hostPortConflict
    case bridgeIdentityMismatch
    case bridgeVersionMismatch
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

    var nonEmptyBridgeValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct AndroidRuntimeDiagnosticSnapshot: Codable, Equatable, Sendable {
    let runtimeMode: AndroidRuntimeMode?
    let runtimeState: String
    let ownershipClassification: AndroidRuntimeOwnershipClassification?
    let launchOrigin: AndroidRuntimeLaunchOrigin?
    let appSessionID: String?
    let runtimeSessionID: String?
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
    let emulatorLaunchAt: Date?
    let emulatorExitAt: Date?
    let emulatorLifetime: TimeInterval?
    let emulatorTerminationStatus: Int32?
    let emulatorTerminationReason: String?
    let emulatorTerminationRequestedByApp: Bool
    let emulatorTerminationRequestReason: String?
    let emulatorStdoutTail: String?
    let emulatorStderrTail: String?
    let emulatorArguments: [String]
    let emulatorEnvironment: [String: String]
    let emulatorADBAuthenticationMode: AndroidEmulatorADBAuthenticationMode
    let emulatorSkipADBAuthEnabled: Bool
    let emulatorADBAuthenticationCompatibilityReason: String?
    let adbEnvironment: [String: String]
    let privateADBKeyPath: String
    let privateADBPublicKeyPath: String
    let privateADBKeyExists: Bool
    let privateADBPublicKeyExists: Bool
    let privateADBKeyReadable: Bool
    let privateADBPublicKeyReadable: Bool
    let privateADBKeyPairMatches: Bool?
    let privateADBPublicKeySHA256: String?
    let privateADBKeyGeneratedThisSession: Bool
    let adbVendorKeysPointsToPrivateKey: Bool
    let privateADBServerReportedKeyLoaded: Bool
    let privateADBServerReportedExpectedKeyPath: Bool
    let androidEmulatorHomePath: String
    let androidEmulatorHomeIsPrivate: Bool
    let emulatorReportedSendingADBPublicKey: Bool
    let emulatorReportedNoADBPrivateKey: Bool
    let emulatorBootPropertiesContainADBPublicKey: Bool
    let emulatorReportedADBPublicKeySHA256: String?
    let emulatorReportedADBPublicKeyMatchesPrivateKey: Bool?
    let androidRuntimeDiagnosticModeEnabled: Bool
    let adbPrivateServer: AndroidADBServerDiagnostic?
    let adbReconnect: AndroidADBReconnectDiagnostic?
    let adbTransportSummary: AndroidADBTransportSummary?
    let selectedGPUBackend: AndroidEmulatorGPUBackend?
    let gpuFallbackAttempted: Bool
    let gpuFallbackResult: String?
    let privateAVDRecoveryBackup: String?
    let emulatorTerminationCategory: AndroidRuntimeFailureCategory?
    let avdManagerPath: String?
    let avdManagerExists: Bool
    let avdManagerExecutable: Bool
    let javaHome: String?
    let javaRuntimeSource: String?
    let javaExecutable: Bool
    let expectedAVDName: String
    let avdExists: Bool
    let avdPath: String
    let systemImage: String?
    let systemImageAPILevel: Int?
    let systemImageExtensionLevel: Int?
    let systemImageABI: String?
    let systemImageDirectory: String?
    let systemImageCandidates: [AndroidSystemImageDiagnostic]
    let configuredAVDSystemImageDirectory: String?
    let avdSystemImageMatchesSelection: Bool?
    let avdConfigSummary: [String: String]
    let avdHardwareConfigSummary: [String: String]
    let avdLockFiles: [String]
    let avdRuntimeFiles: [String: Bool]
    let emulatorPID: Int32?
    let emulatorPIDBirthIdentity: String?
    let emulatorConsolePort: Int?
    let emulatorADBPort: Int?
    let emulatorSerial: String?
    let emulatorProcessRunning: Bool
    let adbDeviceState: String?
    let adbWaitTimeline: [AndroidADBWaitObservation]
    let shutdownMechanism: AndroidRuntimeShutdownMechanism
    let shutdownStartedAt: Date?
    let shutdownCompletedAt: Date?
    let shutdownElapsed: TimeInterval?
    let shutdownForced: Bool
    let staleAVDLocksCleared: [String]
    let lifecycleConflictReason: String?
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
        case .javaRuntimeMissing:
            return "创建专用 Android 环境需要 Java Runtime。请安装 JDK，或安装包含 JBR 的 Android Studio。"
        case .adbUnavailable:
            return "ADB 无法使用，无法连接专用 Android Emulator。"
        case .adbPrivateServerFailed:
            return "OKVideoMac 无法启动独立的 ADB 服务；没有连接或关闭系统默认 ADB。"
        case .adbDeviceMissing, .adbSerialMissingTimeout:
            return "Android Emulator 仍在运行，但 ADB 未发现目标设备。"
        case .adbDeviceOffline, .adbOfflineTimeout,
             .hostGPUADBOfflineTimeout, .softwareGPUADBOfflineTimeout:
            return "ADB 已发现专用 Android Emulator，但设备一直处于 offline 状态。"
        case .adbReconnectFailed:
            return "专用 Android Emulator 的有界 ADB 重连失败。"
        case .privateAVDRecoveryRequired:
            return "专用 Android Runtime 使用硬件和软件渲染均无法启动；请在设置中重建 Runtime。"
        case .emulatorLaunchFailed, .emulatorLaunchTimedOut,
             .emulatorExitedBeforeADB,
             .emulatorExitedEarly, .emulatorExited, .runtimeExited:
            return "Android Emulator 未能正常启动，请导出诊断后重试。"
        case .appRequestedTermination:
            return "Android Emulator 启动已由 App 取消或结束。"
        case .emulatorOwnershipMismatch:
            return "无法安全确认专用 Android Emulator，已停止操作其他设备。"
        case .emulatorProcessMismatch:
            return "Android Emulator PID 已不再属于本次启动实例。"
        case .emulatorRuntimeConflict:
            return "检测到其他 Emulator 正在使用专用 AVD 或记录端口，未执行任何操作。"
        case .portConflict:
            return "Android Emulator 所需端口被其他进程占用，未终止占用进程。"
        case .unexpectedSerial:
            return "ADB 发现了其他 Emulator，但没有发现本次启动所预期的设备。"
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
        case .bridgeIdentityMismatch:
            return "检测到的 Android Bridge 不属于当前启动实例；已拒绝连接，请重新启动兼容环境。"
        case .bridgeVersionMismatch:
            return "Android Bridge 与当前 App 版本不一致；请使用“修复”重新安装当前 Bridge。"
        case .bridgeHealthTimedOut:
            return "Android Bridge 未在限定时间内建立连接；本次启动已失败，请重试或使用“修复”。"
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

final class AndroidDexBridgeClient: @unchecked Sendable {
    private struct Request: Encodable {
        let configurationID: String
        let hosts: [String]
        let siteKey: String
        let api: String
        let ext: String
        let jarURL: String
        let jarMD5: String
        let method: String
        let arguments: [JSONValue]
        /// Request-scoped site headers are sent only for playback so the
        /// provider VM can attach them to its opaque media capability. They
        /// are never copied into playback history or diagnostic output.
        let siteHeaders: [String: String]?
        let monitorsAuthorization: Bool
        let interactionID: String?
        let interactionKind: String?
        let providerOwnerID: String
        /// Present only for an explicit same-resource refresh. New bridge
        /// builds bypass their short playback handoff cache when this is true;
        /// old builds safely ignore the additional JSON field.
        let refreshPlayback: Bool?
    }

    private struct Response: Decodable {
        let ok: Bool
        let result: JSONValue?
        let error: String?
        let interactionID: String?
        let interaction: InteractionResponse?
        let refreshPerformed: Bool?
    }

    private struct InteractionResponse: Decodable, Sendable {
        let interactionID: String?
        let revision: Int?
        let kind: String?
        let method: String?
        let phase: String?
        let outcome: String?
        let terminal: Bool?
        let hostUnavailable: Bool?
        let error: String?
        let refreshPerformed: Bool?
        let failureKind: String?
        let completionSource: String?
        let cancelReason: String?
    }

    private enum MonitoredInvocation: Sendable {
        case completed(
            ConfigurationInteractionTerminalResponse,
            InteractionHandle
        )
        case presented(
            AndroidBridgeUIState,
            ConfigurationInteraction,
            InteractionHandle
        )
    }

    private let runtime: AndroidDexBridgeRuntime
    private let runtimePrerequisite: @Sendable () async throws -> Void
    private let session: URLSession
    private let interactionSession: URLSession
    private let invokeURL = URL(string: "http://127.0.0.1:19978/v1/invoke")!
    private let uiStateURL = URL(string: "http://127.0.0.1:19978/v1/ui/state")!
    private let uiDismissURL = URL(string: "http://127.0.0.1:19978/v1/ui/dismiss")!

    init(
        runtime: AndroidDexBridgeRuntime = AndroidDexBridgeRuntime(),
        runtimePrerequisite:
            @escaping @Sendable () async throws -> Void = {}
    ) {
        self.runtime = runtime
        self.runtimePrerequisite = runtimePrerequisite
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        configuration.httpMaximumConnectionsPerHost = 20
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)

        let interactionConfiguration = URLSessionConfiguration.ephemeral
        interactionConfiguration.timeoutIntervalForRequest = 600
        interactionConfiguration.timeoutIntervalForResource = 600
        interactionConfiguration.httpMaximumConnectionsPerHost = 8
        interactionConfiguration.connectionProxyDictionary = [:]
        interactionSession = URLSession(configuration: interactionConfiguration)
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

    func shutdownForApplicationTermination() async {
        await runtime.shutdownForApplicationTermination()
    }

    func beginApplicationTermination() async {
        await runtime.beginApplicationTermination()
    }

    func repairRuntime() async throws -> AndroidRuntimeStatus {
        try await runtime.repair()
        return await runtime.status()
    }

    func rebuildRuntime() async throws -> AndroidRuntimeStatus {
        try await runtime.rebuildPrivateAVD()
        return await runtime.status()
    }

    func setUserSelectedSDKRoot(_ url: URL) async {
        await runtime.setUserSelectedSDKRoot(url)
    }

    func setRuntimeSelection(
        mode: AndroidRuntimeMode,
        externalSDKRoot: URL?
    ) async {
        await runtime.setRuntimeSelection(
            mode: mode,
            externalSDKRoot: externalSDKRoot
        )
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

    /// Rewrites Android loopback media capabilities to the host port while
    /// leaving ordinary remote URLs direct for mpv startup and seeking.
    /// Parsing URLs are intentionally handled by `hostReachableProxyURL`
    /// instead because they are not yet media resources.
    func hostReachableMediaURL(_ rawURL: String) throws -> String {
        let rewritten = hostReachableProxyURL(rawURL)
        guard let components = URLComponents(string: rewritten),
              ["http", "https"].contains(
                  components.scheme?.lowercased() ?? ""
              ) else {
            return rewritten
        }
        if Self.isLoopbackHost(components.host) {
            guard Self.isHostReachablePlaybackLoopback(components) else {
                throw AppError.playback(
                    "Android 内部媒体代理未正确转发"
                )
            }
            return rewritten
        }
        return rewritten
    }

    static func providerMediaSessionID(from rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              isLoopbackHost(components.host) else { return nil }
        for prefix in ["/proxy/media/", "/v1/media-sessions/"]
            where components.path.hasPrefix(prefix) {
            let value = String(components.path.dropFirst(prefix.count))
            if !value.isEmpty, !value.contains("/") { return value }
        }
        return nil
    }

    static func isLoopbackMediaURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL) else {
            return false
        }
        return isLoopbackHost(components.host)
            && (components.path.hasPrefix("/proxy/media/")
                || components.path.hasPrefix("/v1/media-sessions/")
                || components.path == "/v1/media")
    }

    static func isLoopbackURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL) else {
            return false
        }
        return isLoopbackHost(components.host)
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(
            host?.lowercased() ?? ""
        )
    }

    /// Only loopback endpoints explicitly forwarded by the Android runtime
    /// may be handed to the Mac player. Provider-owned dynamic ports must have
    /// been converted to a scoped `/proxy/media/{session}` capability first.
    private static func isHostReachablePlaybackLoopback(
        _ components: URLComponents
    ) -> Bool {
        let path = components.path
        switch components.port {
        case BridgeServerPort.host:
            return path.hasPrefix("/proxy/media/")
                || path.hasPrefix("/v1/media-sessions/")
                || path == "/v1/media"
                || path == "/proxy"
                || path.hasPrefix("/proxy/")
        case BridgeServerPort.kaiserHost:
            return path.hasPrefix("/kaiser")
        case BridgeServerPort.cloudFileHost:
            return path.hasPrefix("/proxy/play/")
        default:
            return false
        }
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
        return bridgeMediaProxyURL(for: rawUpstream)
    }

    private static func bridgeMediaProxyURL(for rawUpstream: String) -> String? {
        guard let upstream = URLComponents(string: rawUpstream),
              ["http", "https"].contains(
                  upstream.scheme?.lowercased() ?? ""
              ),
              !isLoopbackHost(upstream.host) else { return nil }
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
        configurationID: String,
        configurationHosts: [String],
        jarReference: String,
        baseURL: URL?,
        method: String,
        arguments: [JSONValue],
        monitorsAuthorization explicitAuthorizationAction: Bool = false,
        interactionKind explicitInteractionKind:
            ConfigurationInteraction.ActionKind? = nil,
        refreshPlayback: Bool = false,
        requestedInteractionID: UUID? = nil
    ) async throws -> JSONValue {
        try await runtimePrerequisite()
        try await runtime.ensureReady()
        let monitorsAuthorization = Self.shouldMonitorAuthorization(
            for: method,
            explicitAuthorizationAction: explicitAuthorizationAction
        )
        let actionKind = explicitInteractionKind
            ?? Self.interactionActionKind(
                method: method,
                explicitConfigurationAction: explicitAuthorizationAction
            )
        let interactionID = monitorsAuthorization
            ? requestedInteractionID ?? UUID()
            : nil
        if monitorsAuthorization,
           requestedInteractionID == nil,
           let staleState = try? await uiState(),
           staleState.isProviderUIPrompt {
            // A dialog belongs to the operation that created it. If it was
            // hidden on macOS without resetting Android, accepting it here
            // would attach an old cloud-login window to an unrelated detail
            // or playback click.
            try await resetAuthorizationUI()
        }
        if let interactionID {
            // This actor hop is the host-side supersede fence. No request for
            // the replacement interaction is sent to Android until every ADB
            // input already admitted for the previous lease has completed.
            try await runtime.beginActionSurfaceSession(
                interactionID: interactionID
            )
        }
        let jar = try Self.jarParts(jarReference, baseURL: baseURL)
        let providerOwnerID = Self.providerOwnerID(
            configurationID: configurationID,
            siteKey: site.key,
            jarURL: jar.url,
            jarMD5: jar.md5
        )
        var request = URLRequest(url: invokeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Request(
                configurationID: configurationID,
                hosts: configurationHosts,
                siteKey: site.key,
                api: site.api,
                ext: try Self.extString(site.ext),
                jarURL: jar.url.absoluteString,
                jarMD5: jar.md5,
                method: method,
                arguments: arguments,
                siteHeaders: Self.requestScopedPlaybackHeaders(
                    method: method,
                    siteHeaders: site.header
                ),
                monitorsAuthorization: monitorsAuthorization,
                interactionID: interactionID?.uuidString,
                interactionKind: interactionID == nil
                    ? nil
                    : actionKind.rawValue,
                providerOwnerID: providerOwnerID,
                refreshPlayback: refreshPlayback ? true : nil
            )
        )
        let terminalResponse: ConfigurationInteractionTerminalResponse
        var interactionHandle: InteractionHandle?
        if monitorsAuthorization {
            switch try await sendMonitoringInteraction(
                request,
                requestID: interactionID!,
                actionKind: actionKind
            ) {
            case .completed(let terminal, let handle):
                terminalResponse = terminal
                interactionHandle = handle
            case .presented(let state, let interaction, let handle):
                throw AndroidBridgeUIRequired(
                    state: state,
                    interaction: interaction,
                    handle: handle
                )
            }
        } else {
            let requestID = UUID()
            let (data, response) = try await session.data(for: request)
            terminalResponse = Self.decodeTerminalResponse(
                requestID: requestID,
                data: data,
                response: response
            )
        }

        guard terminalResponse.outcome == .succeeded else {
            if monitorsAuthorization,
               let state = await authorizationStateAfterFailedInvocation(
                   interactionID: terminalResponse.requestID
               ) {
                let resolvedActionKind = interactionHandle?.actionKind
                    ?? actionKind
                let interaction = state.configurationInteraction(
                    requestID: terminalResponse.requestID,
                    actionKind: resolvedActionKind
                )
                await interactionHandle?.record(interaction)
                throw AndroidBridgeUIRequired(
                    state: state,
                    interaction: interaction,
                    handle: interactionHandle
                )
            }
            if let interactionID {
                await runtime.endActionSurfaceSession(
                    interactionID: interactionID
                )
            }
            if let message = terminalResponse.error,
               AndroidProviderContextRecoveryPolicy.recognizes(message) {
                throw AndroidProviderContextInvalid(
                    providerMessage: message
                )
            }
            if terminalResponse.failureKind == "providerMessage" {
                throw ProviderPlaybackError(
                    terminalResponse.error ?? "Spider 没有返回可播放媒体"
                )
            }
            throw AppError.spider(
                Self.userFacingBridgeError(
                    terminalResponse.error
                        ?? terminalResponse.httpStatusCode.map {
                            "Java/Dex 桥 HTTP \($0)"
                        }
                        ?? "Java/Dex 桥没有返回有效结果"
                )
            )
        }
        if let interactionID {
            await runtime.endActionSurfaceSession(
                interactionID: interactionID
            )
        }
        return terminalResponse.providerResult ?? .null
    }

    static func requestScopedPlaybackHeaders(
        method: String,
        siteHeaders: [String: String]
    ) -> [String: String]? {
        guard method == "play", !siteHeaders.isEmpty else { return nil }
        return siteHeaders
    }

    private static func interactionActionKind(
        method: String,
        explicitConfigurationAction: Bool
    ) -> ConfigurationInteraction.ActionKind {
        if method == "play" {
            return .playback
        }
        if explicitConfigurationAction || method == "action" {
            return .configuration
        }
        return .configuration
    }

    static func decodeTerminalResponse(
        requestID: UUID,
        data: Data,
        response: URLResponse,
        requiresScopedIdentity: Bool = false,
        allowsImmediateAuthoritativeResult: Bool = false
    ) -> ConfigurationInteractionTerminalResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .failed,
                providerResult: nil,
                error: "Java/Dex 桥没有返回 HTTP 响应",
                httpStatusCode: nil,
                refreshPerformed: nil
            )
        }
        let bridgeResponse: Response
        do {
            bridgeResponse = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .failed,
                providerResult: nil,
                error: "Java/Dex 桥响应无效（HTTP \(httpResponse.statusCode)）："
                    + String(text.prefix(500)),
                httpStatusCode: httpResponse.statusCode,
                refreshPerformed: nil
            )
        }
        let transportSucceeded = bridgeResponse.ok
            && (200..<300).contains(httpResponse.statusCode)
        let returnedInteractionID = bridgeResponse.interaction?.interactionID
            ?? bridgeResponse.interactionID
        guard Self.interactionIdentifier(
            returnedInteractionID,
            matches: requestID,
            allowsMissing: !requiresScopedIdentity
        ) else {
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .failed,
                providerResult: nil,
                error: "Java/Dex 桥返回了其他配置操作的结果",
                httpStatusCode: httpResponse.statusCode,
                refreshPerformed: nil
            )
        }
        let outcome: ConfigurationInteraction.Outcome
        if bridgeResponse.interaction == nil,
           (httpResponse.statusCode == 202 || requiresScopedIdentity),
           !(allowsImmediateAuthoritativeResult
             && bridgeResponse.result != nil
             && bridgeResponse.result != .null) {
            // A request-owned worker can acknowledge the invocation before
            // Android attaches its native surface. A transport-level success
            // (including HTTP 202 Accepted) without a scoped terminal object
            // is therefore pending, never a manufactured business completion.
            // The only exception is an explicitly declared immediate action
            // carrying a non-null result.
            outcome = .pending
        } else {
            outcome = interactionOutcome(
                bridgeResponse.interaction,
                transportSucceeded: transportSucceeded
            )
        }
        return ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: outcome,
            providerResult: bridgeResponse.result,
            error: outcome == .failed
                ? bridgeResponse.interaction?.error ?? bridgeResponse.error
                : nil,
            httpStatusCode: httpResponse.statusCode,
            refreshPerformed: bridgeResponse.interaction?.refreshPerformed
                ?? bridgeResponse.refreshPerformed,
            failureKind: bridgeResponse.interaction?.failureKind
        )
    }

    private static func interactionOutcome(
        _ interaction: InteractionResponse?,
        transportSucceeded: Bool
    ) -> ConfigurationInteraction.Outcome {
        guard transportSucceeded else { return .failed }
        guard let interaction else { return .succeeded }
        if interaction.hostUnavailable == true { return .pending }
        let outcome = interaction.outcome?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let phase = interaction.phase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch outcome {
        case "completed", "success", "succeeded": return .succeeded
        case "failed", "error": return .failed
        case "hostunavailable", "stay", "none": return .pending
        case "cancelled", "canceled", "superseded": return .cancelled
        default: break
        }
        switch phase {
        case "completed", "success", "succeeded": return .succeeded
        case "failed", "error": return .failed
        case "hostunavailable", "reattaching": return .pending
        case "cancelled", "canceled", "superseded": return .cancelled
        default:
            // A scoped Bridge response explicitly marked nonterminal remains
            // pending. The request handle will await its actual state endpoint
            // rather than manufacturing success from the first UI snapshot.
            return interaction.terminal == true ? .failed : .pending
        }
    }

    private static func awaitTerminalInteraction(
        initial: ConfigurationInteractionTerminalResponse,
        requestID: UUID,
        session: URLSession
    ) async throws -> ConfigurationInteractionTerminalResponse {
        guard initial.outcome == .pending else { return initial }
        let url = interactionURL(requestID, suffix: "state")
        let startedAt = Date()
        var lastError: Error?
        var attempt = 0
        while AndroidBridgeInteractionPollingPolicy.shouldContinue(
            startedAt: startedAt,
            now: Date()
        ) {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw AppError.spider("无法读取配置操作终态")
                }
                let interaction = try JSONDecoder().decode(
                    InteractionResponse.self,
                    from: data
                )
                guard interactionIdentifier(
                    interaction.interactionID,
                    matches: requestID,
                    allowsMissing: false
                ) else {
                    throw AppError.spider("配置操作状态与当前请求不匹配")
                }
                let outcome = interactionOutcome(
                    interaction,
                    transportSucceeded: true
                )
                if outcome != .pending {
                    return ConfigurationInteractionTerminalResponse(
                        requestID: requestID,
                        outcome: outcome,
                        providerResult: initial.providerResult,
                        error: outcome == .failed
                            ? interaction.error ?? initial.error
                            : nil,
                        httpStatusCode: httpResponse.statusCode,
                        refreshPerformed: interaction.refreshPerformed
                            ?? initial.refreshPerformed,
                        failureKind: interaction.failureKind
                            ?? initial.failureKind
                    )
                }
                lastError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A short bridge restart or Activity transition must not lose
                // the request-owned provider response. Keep polling within the
                // same bounded interaction deadline.
                lastError = error
            }
            let delay = AndroidBridgeInteractionPollingPolicy
                .delayNanoseconds(afterAttempt: attempt)
            attempt += 1
            try await Task.sleep(nanoseconds: delay)
        }
        throw lastError ?? AppError.spider("等待配置操作完成超时")
    }

    private static func interactionURL(
        _ interactionID: UUID,
        suffix: String
    ) -> URL {
        URL(
            string: "http://127.0.0.1:19978/v1/interactions/"
                + interactionID.uuidString
                + "/\(suffix)"
        )!
    }

    private static func interactionIdentifier(
        _ rawValue: String?,
        matches requestID: UUID,
        allowsMissing: Bool = false
    ) -> Bool {
        guard let rawValue else {
            return allowsMissing
        }
        return UUID(uuidString: rawValue) == requestID
    }

    private func authorizationStateAfterFailedInvocation(
        interactionID: UUID?
    )
        async -> AndroidBridgeUIState? {
        // Some Android spiders render their authorization dialog and then
        // immediately fail the synthetic detail call. In that ordering the
        // HTTP response can beat the 250 ms monitor poll. Give the already
        // requested UI a short bounded grace period before surfacing the
        // bridge error so the authorization state remains authoritative.
        await Self.waitForAuthorizationStateAfterFailure {
            try? await self.fetchUIState(interactionID: interactionID)
        }
    }

    static func waitForAuthorizationStateAfterFailure(
        attempts: Int = 20,
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        poll: () async -> AndroidBridgeUIState?
    ) async -> AndroidBridgeUIState? {
        guard attempts > 0 else { return nil }
        for attempt in 0..<attempts {
            if let state = await poll(),
               state.isProviderUIPrompt || state.hasRequestScopedActionSurface {
                return state
            }
            guard attempt + 1 < attempts else { break }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: pollIntervalNanoseconds
                )
            }
        }
        return nil
    }

    func uiState(interactionID: UUID? = nil) async throws
        -> AndroidBridgeUIState {
        try await runtime.ensureReady()
        return try await fetchUIState(interactionID: interactionID)
    }

    private func fetchUIState(interactionID: UUID? = nil) async throws
        -> AndroidBridgeUIState {
        let url = interactionID.map {
            Self.interactionURL($0, suffix: "state")
        } ?? uiStateURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await bridgeData(
            for: request,
            legacyURL: nil
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.spider("无法读取网盘授权界面")
        }
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        if let interactionID {
            guard let returnedID = state.interactionID,
                  UUID(uuidString: returnedID) == interactionID else {
                throw AppError.spider("配置界面状态与当前请求不匹配")
            }
        }
        return state
    }

    func resetAuthorizationUI(
        interactionID: UUID? = nil,
        cancellationReason: String = "hostRequested"
    ) async throws {
        // Invalidate the host input lease before asking Android to dismiss the
        // surface. A replacement invocation cannot start until this actor hop
        // has retired every old tap/swipe admitted by the previous session.
        await runtime.endActionSurfaceSession(interactionID: interactionID)
        try await runtime.ensureReady()
        let url = interactionID.map {
            Self.interactionURL($0, suffix: "cancel")
        } ?? uiDismissURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue(
            cancellationReason,
            forHTTPHeaderField: "X-OKVideo-Cancel-Reason"
        )
        let (data, response) = try await bridgeData(
            for: request,
            legacyURL: nil
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.spider("无法关闭当前网盘授权界面")
        }
        if let state = try? JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        ), state.requiresBridgeRestart == true
                || state.workerStopped == false {
            // A cancelled Future does not prove that third-party DEX code has
            // left its runner. Restart only this owned package process; its
            // application data (including cloud-drive login state) remains.
            try await runtime.resetAuthorizationUI()
        }
    }

    func confirmInteractionCompletion(
        interactionID: UUID
    ) async throws -> AndroidBridgeUIState {
        try await runtime.ensureReady()
        let url = Self.interactionURL(interactionID, suffix: "complete")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let (data, response) = try await bridgeData(
            for: request,
            legacyURL: nil
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.spider("无法确认当前配置操作")
        }
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        guard state.interactionID.flatMap(UUID.init(uuidString:))
                == interactionID,
              state.confirmationAccepted == true else {
            throw AppError.spider("配置完成确认已被新的操作替换")
        }
        return state
    }

    /// Request-scoped endpoints are preferred whenever the installed bridge
    /// supports them. Older bridge packages expose only the `latest` UI
    /// routes; fall back exclusively when the scoped route is unavailable,
    /// never when a real scoped interaction reports a business failure.
    private func bridgeData(
        for request: URLRequest,
        legacyURL: URL?
    ) async throws -> (Data, URLResponse) {
        let result = try await session.data(for: request)
        guard let legacyURL,
              let status = (result.1 as? HTTPURLResponse)?.statusCode,
              [404, 405, 501].contains(status) else {
            return result
        }
        var legacyRequest = request
        legacyRequest.url = legacyURL
        return try await session.data(for: legacyRequest)
    }

    private final class InteractionObservationGate: @unchecked Sendable {
        typealias Output = MonitoredInvocation

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        private var terminalObserver: Task<Void, Never>?
        private var monitor: Task<Void, Never>?
        private var isResolved = false
        private var keepsTerminalObserverAlive = false

        func begin(_ continuation: CheckedContinuation<Output, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func setTerminalObserver(_ task: Task<Void, Never>) {
            lock.lock()
            terminalObserver = task
            let shouldCancel = isResolved && !keepsTerminalObserverAlive
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func setMonitor(_ task: Task<Void, Never>) {
            lock.lock()
            monitor = task
            let shouldCancel = isResolved
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func resolve(
            _ result: Result<Output, Error>,
            keepTerminalObserverAlive: Bool
        ) {
            let continuation: CheckedContinuation<Output, Error>?
            let terminalObserver: Task<Void, Never>?
            let monitor: Task<Void, Never>?
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            keepsTerminalObserverAlive = keepTerminalObserverAlive
            continuation = self.continuation
            self.continuation = nil
            terminalObserver = self.terminalObserver
            monitor = self.monitor
            self.terminalObserver = nil
            self.monitor = nil
            lock.unlock()

            monitor?.cancel()
            if !keepTerminalObserverAlive { terminalObserver?.cancel() }
            continuation?.resume(with: result)
        }

        func cancel() {
            resolve(
                .failure(CancellationError()),
                keepTerminalObserverAlive: false
            )
        }
    }

    static func shouldMonitorAuthorization(
        for method: String,
        explicitAuthorizationAction: Bool = false
    ) -> Bool {
        // UI ownership is explicit. FongMi's action() payload is opaque and a
        // playerContent result is playback data; neither is an implicit login
        // request merely because a legacy provider creates a window or QR.
        explicitAuthorizationAction
    }

    private func sendMonitoringInteraction(
        _ request: URLRequest,
        requestID: UUID,
        actionKind: ConfigurationInteraction.ActionKind
    ) async throws -> MonitoredInvocation {
        var preparedRequest = request
        preparedRequest.timeoutInterval = 600
        let interactiveRequest = preparedRequest
        let handle = InteractionHandle(
            id: requestID,
            actionKind: actionKind,
            stateProvider: { [weak self] interactionID in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.uiState(interactionID: interactionID)
            },
            cancelProvider: { [weak self] interactionID, reason in
                guard let self else { return }
                try await self.resetAuthorizationUI(
                    interactionID: interactionID,
                    cancellationReason: reason
                )
            },
            confirmProvider: { [weak self] interactionID in
                guard let self else { throw CancellationError() }
                return try await self.confirmInteractionCompletion(
                    interactionID: interactionID
                )
            },
            terminalCleanup: { [weak self] interactionID in
                guard let self else { return }
                await self.runtime.endActionSurfaceSession(
                    interactionID: interactionID
                )
            }
        ) { [interactionSession] in
            let (data, response) = try await interactionSession.data(
                for: interactiveRequest
            )
            let initial = Self.decodeTerminalResponse(
                requestID: requestID,
                data: data,
                response: response,
                requiresScopedIdentity: true,
                allowsImmediateAuthoritativeResult: actionKind == .immediate
            )
            return try await Self.awaitTerminalInteraction(
                initial: initial,
                requestID: requestID,
                session: interactionSession
            )
        }
        // The handle, rather than the first observer, owns the invocation. A
        // UI generation may be returned immediately while the same handle
        // continues to cache the provider's eventual terminal response.
        let gate = InteractionObservationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.begin(continuation)
                let terminalObserver = Task {
                    do {
                        let terminal = try await handle.finalResponse()
                        gate.resolve(
                            .success(.completed(terminal, handle)),
                            keepTerminalObserverAlive: false
                        )
                    } catch {
                        gate.resolve(
                            .failure(error),
                            keepTerminalObserverAlive: false
                        )
                    }
                }
                gate.setTerminalObserver(terminalObserver)
                let monitor = Task { [weak self] in
                    for _ in 0..<2_400 {
                        guard !Task.isCancelled else { return }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled, let self else { return }
                        // invoke() has already prepared the runtime. Poll the
                        // bridge endpoint directly so UI observation does not
                        // repeat emulator/ADB health checks.
                        if let state = try? await self.fetchUIState(
                            interactionID: requestID
                        ),
                           state.isProviderUIPrompt {
                            let interaction = state.configurationInteraction(
                                requestID: requestID,
                                actionKind: actionKind
                            )
                            await handle.record(interaction)
                            gate.resolve(
                                .success(
                                    .presented(state, interaction, handle)
                                ),
                                keepTerminalObserverAlive: true
                            )
                            return
                        }
                    }
                    handle.cancel()
                    gate.resolve(
                        .failure(AppError.spider("等待 Java/Dex 响应超时")),
                        keepTerminalObserverAlive: false
                    )
                }
                gate.setMonitor(monitor)
            }
        } onCancel: {
            handle.cancel()
            gate.cancel()
        }
    }

    fileprivate static func jarParts(
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

    /// Stable but opaque owner for one configuration/site/JAR capability.
    /// Each field is UTF-8 length-prefixed before hashing so concatenation
    /// cannot alias (`ab`+`c` versus `a`+`bc`). Android treats the result as an
    /// opaque capability and independently binds it to the exact loaded JAR.
    static func providerOwnerID(
        configurationID: String,
        siteKey: String,
        jarURL: URL,
        jarMD5: String
    ) -> String {
        let jarIdentity = jarMD5.nonEmptyBridgeValue?.lowercased()
            ?? jarURL.absoluteString
        let fields = [
            configurationID.lowercased(),
            siteKey,
            jarIdentity
        ]
        var material = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            material.append(Data(String(bytes.count).utf8))
            material.append(0x3a) // ':'
            material.append(bytes)
            material.append(0x00)
        }
        let digest = SHA256.hash(data: material)
        return "android-owner-v1:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
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

/// One full-display or request-owned Dialog crop from the app-owned Android
/// runtime. The frame is deliberately bound to the same request, provider,
/// window and UI generation used by the structured Bridge protocol; it is
/// presentation data, never evidence that an operation succeeded.
struct AndroidActionSurfaceFrame: Equatable, Sendable {
    let interactionID: UUID
    let providerOwnerID: String
    let runtimeGeneration: String
    let surfaceMode: String
    let generation: Int
    let frameSequence: UInt64
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let presentationMode: AndroidActionSurfacePresentationMode
    let fallbackReason: String
    let windowID: String
    let windowRevision: Int
    let windowStackDepth: Int
    let windowContentBounds: AndroidBridgeSurfaceBounds?
    let captureOriginX: Int
    let captureOriginY: Int
    let displayPixelWidth: Int
    let displayPixelHeight: Int

    init(
        interactionID: UUID,
        providerOwnerID: String,
        runtimeGeneration: String,
        surfaceMode: String,
        generation: Int,
        frameSequence: UInt64,
        pngData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        presentationMode: AndroidActionSurfacePresentationMode = .fullDisplay,
        fallbackReason: String = "",
        windowID: String = "",
        windowRevision: Int = 0,
        windowStackDepth: Int = 0,
        windowContentBounds: AndroidBridgeSurfaceBounds? = nil,
        captureOriginX: Int = 0,
        captureOriginY: Int = 0,
        displayPixelWidth: Int? = nil,
        displayPixelHeight: Int? = nil
    ) {
        self.interactionID = interactionID
        self.providerOwnerID = providerOwnerID
        self.runtimeGeneration = runtimeGeneration
        self.surfaceMode = surfaceMode
        self.generation = generation
        self.frameSequence = frameSequence
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.presentationMode = presentationMode
        self.fallbackReason = fallbackReason
        self.windowID = windowID
        self.windowRevision = windowRevision
        self.windowStackDepth = windowStackDepth
        self.windowContentBounds = windowContentBounds
        self.captureOriginX = captureOriginX
        self.captureOriginY = captureOriginY
        self.displayPixelWidth = displayPixelWidth ?? pixelWidth
        self.displayPixelHeight = displayPixelHeight ?? pixelHeight
    }

    static func == (
        lhs: AndroidActionSurfaceFrame,
        rhs: AndroidActionSurfaceFrame
    ) -> Bool {
        lhs.interactionID == rhs.interactionID
            && lhs.providerOwnerID == rhs.providerOwnerID
            && lhs.runtimeGeneration == rhs.runtimeGeneration
            && lhs.surfaceMode == rhs.surfaceMode
            && lhs.generation == rhs.generation
            && lhs.frameSequence == rhs.frameSequence
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.presentationMode == rhs.presentationMode
            && lhs.fallbackReason == rhs.fallbackReason
            && lhs.windowID == rhs.windowID
            && lhs.windowRevision == rhs.windowRevision
            && lhs.windowStackDepth == rhs.windowStackDepth
            && lhs.windowContentBounds == rhs.windowContentBounds
            && lhs.captureOriginX == rhs.captureOriginX
            && lhs.captureOriginY == rhs.captureOriginY
            && lhs.displayPixelWidth == rhs.displayPixelWidth
            && lhs.displayPixelHeight == rhs.displayPixelHeight
    }

    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var captureDescriptor: AndroidActionSurfaceCaptureDescriptor {
        AndroidActionSurfaceCaptureDescriptor(
            presentationMode: presentationMode,
            fallbackReason: fallbackReason,
            windowID: windowID,
            windowRevision: windowRevision,
            windowStackDepth: windowStackDepth,
            windowBounds: presentationMode == .dialogCrop
                ? AndroidBridgeSurfaceBounds(
                    left: captureOriginX,
                    top: captureOriginY,
                    right: captureOriginX + pixelWidth,
                    bottom: captureOriginY + pixelHeight,
                    width: pixelWidth,
                    height: pixelHeight
                )
                : nil,
            windowContentBounds: windowContentBounds,
            displayBounds: AndroidBridgeDisplayBounds(
                width: displayPixelWidth,
                height: displayPixelHeight
            )
        )
    }

    var hasValidCaptureGeometry: Bool {
        guard pixelWidth > 0,
              pixelHeight > 0,
              displayPixelWidth > 0,
              displayPixelHeight > 0,
              captureOriginX >= 0,
              captureOriginY >= 0,
              captureOriginX + pixelWidth <= displayPixelWidth,
              captureOriginY + pixelHeight <= displayPixelHeight else {
            return false
        }
        switch presentationMode {
        case .dialogCrop:
            let contentIsValid = windowContentBounds.map {
                $0.isValid
                    && $0.left >= captureOriginX
                    && $0.top >= captureOriginY
                    && $0.right <= captureOriginX + pixelWidth
                    && $0.bottom <= captureOriginY + pixelHeight
            } ?? true
            return contentIsValid
                && !windowID.isEmpty
                && windowRevision > 0
                && windowStackDepth > 0
        case .fullDisplay:
            return captureOriginX == 0
                && captureOriginY == 0
                && pixelWidth == displayPixelWidth
                && pixelHeight == displayPixelHeight
        }
    }

    func matches(
        captureDescriptor expected: AndroidActionSurfaceCaptureDescriptor
    ) -> Bool {
        guard presentationMode == expected.presentationMode,
              fallbackReason == expected.fallbackReason,
              windowID == expected.windowID,
              windowRevision == expected.windowRevision,
              windowStackDepth == expected.windowStackDepth else {
            return false
        }
        if let display = expected.displayBounds,
           display.width != displayPixelWidth
                || display.height != displayPixelHeight {
            return false
        }
        if expected.presentationMode == .dialogCrop {
            guard let bounds = expected.windowBounds else { return false }
            return bounds.left == captureOriginX
                && bounds.top == captureOriginY
                && bounds.width == pixelWidth
                && bounds.height == pixelHeight
                && expected.windowContentBounds == windowContentBounds
        }
        return expected.windowContentBounds == windowContentBounds
            && captureOriginX == 0
            && captureOriginY == 0
            && pixelWidth == displayPixelWidth
            && pixelHeight == displayPixelHeight
    }

    static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24,
              Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[12..<16]) == [73, 72, 68, 82] else {
            return nil
        }
        let width = bytes[16..<20].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let height = bytes[20..<24].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard width > 0, height > 0 else {
            return nil
        }
        return (Int(width), Int(height))
    }
}

extension AndroidDexBridgeClient {
    /// Captures the complete Android display. State is checked both before
    /// and after ADB capture so a
    /// frame from a superseded request can never be published under the new
    /// request's lease.
    func actionSurfaceFrame(
        interactionID: UUID
    ) async throws -> AndroidActionSurfaceFrame {
        let before = try await activeSurfaceState(
            interactionID: interactionID
        )
        guard let providerOwnerID = before.providerOwnerID?
                .nonEmptyBridgeValue,
              let generation = before.interactionGeneration,
              let surfaceMode = before.normalizedActionSurfaceMode,
              let captureDescriptor = before.actionSurfaceCaptureDescriptor else {
            throw CancellationError()
        }
        let frame = try await runtime.captureActionSurface(
            interactionID: interactionID,
            providerOwnerID: providerOwnerID,
            surfaceMode: surfaceMode,
            generation: generation,
            captureDescriptor: captureDescriptor
        )
        let after = try await activeSurfaceState(
            interactionID: interactionID
        )
        guard after.providerOwnerID?.nonEmptyBridgeValue == providerOwnerID,
              after.normalizedActionSurfaceMode == surfaceMode,
              after.interactionGeneration == generation,
              after.actionSurfaceCaptureDescriptor == captureDescriptor,
              frame.interactionID == interactionID,
              frame.providerOwnerID == providerOwnerID,
              frame.surfaceMode == surfaceMode,
              frame.generation == generation,
              frame.matches(captureDescriptor: captureDescriptor) else {
            throw CancellationError()
        }
        return frame
    }

    func tapActionSurface(
        frame: AndroidActionSurfaceFrame,
        x: Int,
        y: Int
    ) async throws {
        let state = try await activeSurfaceState(
            interactionID: frame.interactionID,
            expectedGeneration: frame.generation
        )
        guard state.providerOwnerID?.nonEmptyBridgeValue
                == frame.providerOwnerID,
              state.normalizedActionSurfaceMode == frame.surfaceMode,
              let descriptor = state.actionSurfaceCaptureDescriptor,
              frame.matches(captureDescriptor: descriptor) else {
            throw CancellationError()
        }
        try await runtime.tapActionSurface(
            frame: frame,
            x: x,
            y: y
        )
    }

    func swipeActionSurface(
        frame: AndroidActionSurfaceFrame,
        fromX: Int,
        fromY: Int,
        toX: Int,
        toY: Int,
        durationMilliseconds: Int = 300
    ) async throws {
        let state = try await activeSurfaceState(
            interactionID: frame.interactionID,
            expectedGeneration: frame.generation
        )
        guard state.providerOwnerID?.nonEmptyBridgeValue
                == frame.providerOwnerID,
              state.normalizedActionSurfaceMode == frame.surfaceMode,
              let descriptor = state.actionSurfaceCaptureDescriptor,
              frame.matches(captureDescriptor: descriptor) else {
            throw CancellationError()
        }
        try await runtime.swipeActionSurface(
            frame: frame,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMilliseconds: durationMilliseconds
        )
    }

    func backActionSurface(
        frame: AndroidActionSurfaceFrame
    ) async throws {
        let state = try await activeSurfaceState(
            interactionID: frame.interactionID,
            expectedGeneration: frame.generation
        )
        guard state.providerOwnerID?.nonEmptyBridgeValue
                == frame.providerOwnerID,
              state.normalizedActionSurfaceMode == frame.surfaceMode,
              let descriptor = state.actionSurfaceCaptureDescriptor,
              frame.matches(captureDescriptor: descriptor) else {
            throw CancellationError()
        }
        try await runtime.backActionSurface(
            frame: frame
        )
    }

    func typeActionSurface(
        frame: AndroidActionSurfaceFrame,
        text: String
    ) async throws {
        let state = try await activeSurfaceState(
            interactionID: frame.interactionID,
            expectedGeneration: frame.generation
        )
        guard state.providerOwnerID?.nonEmptyBridgeValue
                == frame.providerOwnerID,
              state.normalizedActionSurfaceMode == frame.surfaceMode,
              let descriptor = state.actionSurfaceCaptureDescriptor,
              frame.matches(captureDescriptor: descriptor) else {
            throw CancellationError()
        }
        if frame.presentationMode == .dialogCrop {
            guard !text.isEmpty, text.utf8.count <= 16_384 else {
                throw AppError.spider("发送到 Android 操作界面的文字为空或过长")
            }
            var request = URLRequest(
                url: Self.interactionURL(frame.interactionID, suffix: "text")
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "windowID": frame.windowID,
                "windowRevision": frame.windowRevision
            ])
            let (data, response) = try await bridgeData(
                for: request,
                legacyURL: nil
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  value["textAccepted"] as? Bool == true else {
                throw AppError.spider("Android Dialog 当前输入焦点已失效")
            }
            return
        }
        try await runtime.typeActionSurface(frame: frame, text: text)
    }

    private func activeSurfaceState(
        interactionID: UUID,
        expectedGeneration: Int? = nil
    ) async throws -> AndroidBridgeUIState {
        let state = try await fetchUIState(interactionID: interactionID)
        guard state.interactionID.flatMap(UUID.init(uuidString:))
                == interactionID,
              state.terminal != true,
              state.hasRequestScopedActionSurface else {
            throw CancellationError()
        }
        if let expectedGeneration,
           state.interactionGeneration != expectedGeneration {
            throw CancellationError()
        }
        return state
    }
}

struct AndroidToolchain: Equatable, Sendable {
    let sdkRoot: URL
    let adb: URL
    let emulator: URL
    let avdManager: URL?
}

struct AndroidDeprecatedTargetSDKWarningPolicy {
    struct TapPoint: Equatable, Sendable {
        let x: Int
        let y: Int
    }

    static func shouldInspect(windowDump: String) -> Bool {
        windowDump.contains("DeprecatedTargetSdkVersionDialog")
            && windowDump.contains(
                "com.okvideomac.dexbridge/com.okvideomac.dexbridge.BridgeActivity"
            )
    }

    static func dismissalPoint(uiHierarchy: String) -> TapPoint? {
        // The system window is already identified by dumpsys. Still require
        // the exact Bridge title so a generic Android OK button can never be
        // clicked on behalf of an unrelated dialog.
        guard uiHierarchy.contains("text=\"OKVideo Dex Bridge\"") else {
            return nil
        }
        let pattern = #"<node(?=[^>]*resource-id="android:id/button1")(?=[^>]*text="OK")[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*/>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: uiHierarchy,
                range: NSRange(uiHierarchy.startIndex..., in: uiHierarchy)
              ),
              match.numberOfRanges == 5 else {
            return nil
        }
        func integer(at index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: uiHierarchy) else {
                return nil
            }
            return Int(uiHierarchy[range])
        }
        guard let left = integer(at: 1),
              let top = integer(at: 2),
              let right = integer(at: 3),
              let bottom = integer(at: 4),
              right > left,
              bottom > top else {
            return nil
        }
        return TapPoint(x: (left + right) / 2, y: (top + bottom) / 2)
    }
}

struct AndroidSystemImage: Equatable, Sendable {
    let packageID: String
    let apiLevel: Int
    let extensionLevel: Int
    let variant: String
    let variantDisplayName: String?
    let architecture: String
    let actualRelativeDirectory: String
    let targetIdentifier: String

    init(
        packageID: String,
        apiLevel: Int,
        extensionLevel: Int = 0,
        variant: String,
        variantDisplayName: String? = nil,
        architecture: String,
        actualRelativeDirectory: String? = nil,
        targetIdentifier: String? = nil
    ) {
        self.packageID = packageID
        self.apiLevel = apiLevel
        self.extensionLevel = extensionLevel
        self.variant = variant
        self.variantDisplayName = variantDisplayName
        self.architecture = architecture
        let packageComponents = packageID.split(separator: ";").map(String.init)
        self.actualRelativeDirectory = actualRelativeDirectory
            ?? packageComponents.joined(separator: "/")
        self.targetIdentifier = targetIdentifier
            ?? packageComponents.dropFirst().first
            ?? "android-\(apiLevel)"
    }

    var supportsInteractiveRendering: Bool {
        let normalized = variant.lowercased()
        return normalized != "atd" && !normalized.hasSuffix("_atd")
    }

    var avdSystemImageDirectory: String {
        actualRelativeDirectory.hasSuffix("/")
            ? actualRelativeDirectory
            : actualRelativeDirectory + "/"
    }

    var avdTagDisplayName: String {
        if let variantDisplayName = variantDisplayName?.nonEmptyBridgeValue {
            return variantDisplayName
        }
        switch variant {
        case "google_apis":
            return "Google APIs"
        case "default":
            return "Default Android System Image"
        default:
            return variant
        }
    }
}

struct AndroidSystemImageDiagnostic: Codable, Equatable, Sendable {
    let actualRelativeDirectory: String
    let packageID: String?
    let apiLevel: Int?
    let extensionLevel: Int?
    let variant: String?
    let architecture: String?
    let accepted: Bool
    let reason: String
}

private struct AndroidSystemImageInspection {
    let actualRelativeDirectory: String
    let image: AndroidSystemImage?
    let metadataError: String?

    var diagnostic: AndroidSystemImageDiagnostic {
        let rejection: String?
        if let metadataError {
            rejection = metadataError
        } else if let image, image.apiLevel < 24 {
            rejection = "API 低于 Android Bridge minSdk 24"
        } else if let image, image.architecture != "arm64-v8a" {
            rejection = "ABI 不是 arm64-v8a"
        } else if let image, !image.supportsInteractiveRendering {
            rejection = "ATD 不支持交互界面捕获"
        } else if image == nil {
            rejection = "无法读取 system image 元数据"
        } else {
            rejection = nil
        }
        return AndroidSystemImageDiagnostic(
            actualRelativeDirectory: actualRelativeDirectory,
            packageID: image?.packageID,
            apiLevel: image?.apiLevel,
            extensionLevel: image?.extensionLevel,
            variant: image?.variant,
            architecture: image?.architecture,
            accepted: rejection == nil,
            reason: rejection ?? "可用于 OKVideoMac 专用 AVD"
        )
    }
}

private enum AndroidSystemImagePackageError: LocalizedError {
    case unreadable
    case malformedXML
    case missingPackageID
    case invalidPackageID
    case directoryMismatch(expected: String, actual: String)
    case missingAPILevel
    case missingTag
    case missingABI
    case tagMismatch(expected: String, actual: String)
    case abiMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "package.xml 无法读取"
        case .malformedXML:
            return "package.xml XML 已损坏"
        case .missingPackageID:
            return "package.xml 缺少 localPackage path"
        case .invalidPackageID:
            return "localPackage path 不是 system image 身份"
        case let .directoryMismatch(expected, actual):
            return "localPackage path 与实际目录不一致（\(expected) != \(actual)）"
        case .missingAPILevel:
            return "package.xml 缺少有效 api-level"
        case .missingTag:
            return "package.xml 缺少 tag/id"
        case .missingABI:
            return "package.xml 缺少 abi"
        case let .tagMismatch(expected, actual):
            return "tag/id 与 package 身份不一致（\(expected) != \(actual)）"
        case let .abiMismatch(expected, actual):
            return "abi 与 package 身份不一致（\(expected) != \(actual)）"
        }
    }
}

private enum AndroidSystemImagePackageParser {
    static func parse(
        data: Data,
        actualRelativeDirectory: String
    ) throws -> AndroidSystemImage {
        let delegate = AndroidSystemImagePackageXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AndroidSystemImagePackageError.malformedXML
        }
        guard let packageID = delegate.packageID?.nonEmptyBridgeValue else {
            throw AndroidSystemImagePackageError.missingPackageID
        }
        let components = packageID.split(separator: ";").map(String.init)
        guard components.count == 4, components[0] == "system-images" else {
            throw AndroidSystemImagePackageError.invalidPackageID
        }
        let normalizedActual = AndroidManagedAVDConfiguration
            .normalizedSystemImageDirectory(actualRelativeDirectory)
        let expectedDirectory = components.joined(separator: "/")
        guard normalizedActual == expectedDirectory else {
            throw AndroidSystemImagePackageError.directoryMismatch(
                expected: expectedDirectory,
                actual: normalizedActual
            )
        }
        guard let apiLevel = Int(delegate.apiLevel ?? ""), apiLevel > 0 else {
            throw AndroidSystemImagePackageError.missingAPILevel
        }
        guard let variant = delegate.tagID?.nonEmptyBridgeValue else {
            throw AndroidSystemImagePackageError.missingTag
        }
        guard let architecture = delegate.abi?.nonEmptyBridgeValue else {
            throw AndroidSystemImagePackageError.missingABI
        }
        guard variant == components[2] else {
            throw AndroidSystemImagePackageError.tagMismatch(
                expected: components[2],
                actual: variant
            )
        }
        guard architecture == components[3] else {
            throw AndroidSystemImagePackageError.abiMismatch(
                expected: components[3],
                actual: architecture
            )
        }
        let extensionLevel = Int(delegate.extensionLevel ?? "") ?? 0
        return AndroidSystemImage(
            packageID: packageID,
            apiLevel: apiLevel,
            extensionLevel: max(0, extensionLevel),
            variant: variant,
            variantDisplayName: delegate.tagDisplay?.nonEmptyBridgeValue,
            architecture: architecture,
            actualRelativeDirectory: normalizedActual,
            targetIdentifier: components[1]
        )
    }
}

private final class AndroidSystemImagePackageXMLDelegate:
    NSObject, XMLParserDelegate {
    var packageID: String?
    var apiLevel: String?
    var extensionLevel: String?
    var tagID: String?
    var tagDisplay: String?
    var abi: String?

    private var path: [String] = []
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        path.append(elementName)
        text = ""
        if elementName == "localPackage" {
            packageID = attributeDict["path"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "api-level" {
            apiLevel = value
        } else if elementName == "extension-level" {
            extensionLevel = value
        } else if elementName == "abi" {
            abi = value
        } else if path.suffix(2) == ["tag", "id"] {
            tagID = value
        } else if path.suffix(2) == ["tag", "display"] {
            tagDisplay = value
        }
        if !path.isEmpty {
            path.removeLast()
        }
        text = ""
    }
}

struct AndroidJavaRuntime: Equatable, Sendable {
    let home: URL
    let executable: URL
    let source: String

    func applying(to base: [String: String]) -> [String: String] {
        var environment = base
        environment["JAVA_HOME"] = home.path
        let javaBin = executable.deletingLastPathComponent().path
        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = javaBin + ":" + path
        } else {
            environment["PATH"] = javaBin
        }
        return environment
    }
}

struct AndroidJavaRuntimeResolver {
    let homeDirectory: URL
    let environment: [String: String]
    let systemApplicationsDirectory: URL
    let fileManager: FileManager
    let systemJavaHomeProvider: () -> URL?

    init(
        homeDirectory: URL,
        environment: [String: String],
        systemApplicationsDirectory: URL = URL(
            fileURLWithPath: "/Applications",
            isDirectory: true
        ),
        fileManager: FileManager,
        systemJavaHomeProvider: @escaping () -> URL? = Self.systemJavaHome
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.systemApplicationsDirectory = systemApplicationsDirectory
        self.fileManager = fileManager
        self.systemJavaHomeProvider = systemJavaHomeProvider
    }

    func resolve() -> AndroidJavaRuntime? {
        var candidates: [(URL, String)] = []
        if let javaHome = environment["JAVA_HOME"]?.nonEmptyBridgeValue {
            candidates.append((Self.url(from: javaHome), "JAVA_HOME"))
        }
        if let systemJavaHome = systemJavaHomeProvider() {
            candidates.append((systemJavaHome, "/usr/libexec/java_home"))
        }
        candidates.append(contentsOf: androidStudioHomes(
            in: systemApplicationsDirectory,
            source: "Android Studio JBR (/Applications)"
        ))
        candidates.append(contentsOf: androidStudioHomes(
            in: homeDirectory.appendingPathComponent(
                "Applications",
                isDirectory: true
            ),
            source: "Android Studio JBR (~/Applications)"
        ))

        var seen = Set<String>()
        for (candidate, source) in candidates {
            let home = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(home.path).inserted else { continue }
            let java = home.appendingPathComponent("bin/java")
            if fileManager.isExecutableFile(atPath: java.path) {
                return AndroidJavaRuntime(
                    home: home,
                    executable: java.resolvingSymlinksInPath(),
                    source: source
                )
            }
        }
        return nil
    }

    private func androidStudioHomes(
        in applicationsDirectory: URL,
        source: String
    ) -> [(URL, String)] {
        guard let applications = try? fileManager.contentsOfDirectory(
            at: applicationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return applications
            .filter {
                $0.pathExtension == "app"
                    && $0.deletingPathExtension().lastPathComponent
                        .hasPrefix("Android Studio")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                (
                    $0.appendingPathComponent(
                        "Contents/jbr/Contents/Home",
                        isDirectory: true
                    ),
                    source
                )
            }
    }

    private static func url(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func systemJavaHome() -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let value = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              )?.nonEmptyBridgeValue else {
            return nil
        }
        return URL(fileURLWithPath: value)
    }
}

struct AndroidManagedDisplayProfile: Equatable, Sendable {
    static let pixelWidth = 720
    static let pixelHeight = 1_600
    static let densityDPI = 280
    static let fontScale = 1.0

    static var logicalWidth: Double {
        Double(pixelWidth) * 160 / Double(densityDPI)
    }

    static var logicalHeight: Double {
        Double(pixelHeight) * 160 / Double(densityDPI)
    }
}

struct AndroidManagedAVDConfiguration {
    static func value(for key: String, in contents: String) -> String? {
        contents.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    static func systemImageVariant(in contents: String) -> String? {
        guard let directory = systemImageDirectory(in: contents) else {
            return nil
        }
        let components = directory.split(separator: "/")
        guard let systemImagesIndex = components.firstIndex(of: "system-images"),
              components.indices.contains(systemImagesIndex + 2) else {
            return nil
        }
        return String(components[systemImagesIndex + 2])
    }

    static func systemImageDirectory(in contents: String) -> String? {
        guard let directory = value(
            for: "image.sysdir.1",
            in: contents
        )?.nonEmptyBridgeValue else {
            return nil
        }
        let normalized = normalizedSystemImageDirectory(directory)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedSystemImageDirectory(_ directory: String) -> String {
        let slashNormalized = directory.replacingOccurrences(
            of: "\\",
            with: "/"
        )
        let components = slashNormalized.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        if let index = components.firstIndex(of: "system-images") {
            return components[index...].joined(separator: "/")
        }
        return components.joined(separator: "/")
    }

    static func targetIdentifier(in contents: String) -> String? {
        value(for: "target", in: contents)?.nonEmptyBridgeValue
    }

    static func targetAPILevel(in contents: String) -> Int? {
        guard let target = targetIdentifier(in: contents),
              target.hasPrefix("android-") else {
            return nil
        }
        let version = target.dropFirst("android-".count)
        return Int(version.split(separator: ".", maxSplits: 1)[0])
    }

    static func requiresInteractiveImageMigration(_ contents: String) -> Bool {
        guard let variant = systemImageVariant(in: contents) else {
            return false
        }
        return !AndroidSystemImage(
            packageID: "",
            apiLevel: 0,
            variant: variant,
            architecture: ""
        ).supportsInteractiveRendering
    }

    static func matches(
        _ image: AndroidSystemImage,
        contents: String
    ) -> Bool {
        if let directory = systemImageDirectory(in: contents) {
            return directory == normalizedSystemImageDirectory(
                image.actualRelativeDirectory
            )
        }
        return targetIdentifier(in: contents) == image.targetIdentifier
            && systemImageVariant(in: contents) == image.variant
    }

    static func requiresSystemImageMigration(
        _ contents: String,
        to image: AndroidSystemImage
    ) -> Bool {
        !matches(image, contents: contents)
    }

    static func updating(
        _ contents: String,
        for image: AndroidSystemImage,
        gpuBackend: AndroidEmulatorGPUBackend = .host
    ) -> String {
        let updates = [
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": gpuBackend.rawValue,
            "hw.initialOrientation": "portrait",
            "hw.lcd.density": "\(AndroidManagedDisplayProfile.densityDPI)",
            "hw.lcd.height": "\(AndroidManagedDisplayProfile.pixelHeight)",
            "hw.lcd.width": "\(AndroidManagedDisplayProfile.pixelWidth)",
            "image.sysdir.1": image.avdSystemImageDirectory,
            "tag.display": image.avdTagDisplayName,
            "tag.displaynames": image.avdTagDisplayName,
            "tag.id": image.variant,
            "tag.ids": image.variant,
            "target": image.targetIdentifier
        ]
        var seen = Set<String>()
        var lines = contents.components(separatedBy: .newlines)
        let endedWithNewline = lines.last == ""
        if endedWithNewline {
            lines.removeLast()
        }
        lines = lines.map { line in
            guard let separator = line.firstIndex(of: "=") else {
                return line
            }
            let key = String(line[..<separator])
            guard let replacement = updates[key] else {
                return line
            }
            seen.insert(key)
            return "\(key)=\(replacement)"
        }
        for key in updates.keys.sorted() where !seen.contains(key) {
            if let replacement = updates[key] {
                lines.append("\(key)=\(replacement)")
            }
        }
        let result = lines.joined(separator: "\n")
        return endedWithNewline ? result + "\n" : result
    }
}

struct AndroidToolchainResolver {
    static let minimumBridgeAPILevel = 24
    static let userSDKRootDefaultsKey = "OKVideoMac.AndroidSDKRoot"

    let applicationSupportDirectory: URL
    let homeDirectory: URL
    let environment: [String: String]
    let userSelectedSDKRoot: String?
    let fileManager: FileManager
    var selectionMode: AndroidRuntimeMode? = nil

    func resolve() -> AndroidToolchain? {
        if selectionMode == .managed {
            guard let selection = managedRuntimeSelection() else { return nil }
            return toolchain(at: selection.sdkRoot)
        }
        if selectionMode == .external {
            guard let userSelectedSDKRoot else { return nil }
            return toolchain(at: Self.url(from: userSelectedSDKRoot))
        }
        if hasManagedRuntimePointer {
            guard let selection = managedRuntimeSelection() else { return nil }
            return toolchain(at: selection.sdkRoot)
        }
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

    func resolveJavaRuntime() -> AndroidJavaRuntime? {
        if selectionMode == .managed {
            guard let selection = managedRuntimeSelection() else { return nil }
            return AndroidJavaRuntime(
                home: selection.javaHome,
                executable: selection.java,
                source: "OKVideoMac Managed Runtime"
            )
        }
        if selectionMode == nil, hasManagedRuntimePointer {
            guard let selection = managedRuntimeSelection() else { return nil }
            return AndroidJavaRuntime(
                home: selection.javaHome,
                executable: selection.java,
                source: "OKVideoMac Managed Runtime"
            )
        }
        return AndroidJavaRuntimeResolver(
            homeDirectory: homeDirectory,
            environment: environment,
            fileManager: fileManager
        ).resolve()
    }

    private var managedRuntimeLayout: AndroidRuntimeLayout {
        AndroidRuntimeLayout(
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    private var hasManagedRuntimePointer: Bool {
        fileManager.fileExists(
            atPath: managedRuntimeLayout.currentRuntimePointer.path
        )
    }

    private func managedRuntimeSelection() -> ManagedRuntimeSelection? {
        guard let catalog = try? BundledRuntimeCatalog.load() else { return nil }
        return try? ManagedRuntimeSelection.resolve(
            layout: managedRuntimeLayout,
            catalog: catalog
        )
    }

    func installedSystemImages(in toolchain: AndroidToolchain) -> [AndroidSystemImage] {
        systemImageInspections(in: toolchain)
            .compactMap(\.image)
            .filter {
                $0.apiLevel >= Self.minimumBridgeAPILevel
                    && $0.architecture == "arm64-v8a"
            }
            .sorted(by: Self.precedes)
    }

    func systemImageDiagnostics(
        in toolchain: AndroidToolchain
    ) -> [AndroidSystemImageDiagnostic] {
        systemImageInspections(in: toolchain)
            .map(\.diagnostic)
            .sorted {
                $0.actualRelativeDirectory < $1.actualRelativeDirectory
            }
    }

    private func systemImageInspections(
        in toolchain: AndroidToolchain
    ) -> [AndroidSystemImageInspection] {
        let root = toolchain.sdkRoot.appendingPathComponent("system-images")
        guard let apiDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var inspections: [AndroidSystemImageInspection] = []
        for apiDirectory in apiDirectories {
            guard let variants = try? fileManager.contentsOfDirectory(
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
                    let relativeDirectory = [
                        "system-images",
                        apiDirectory.lastPathComponent,
                        variantDirectory.lastPathComponent,
                        architectureDirectory.lastPathComponent
                    ].joined(separator: "/")
                    let metadata = architectureDirectory.appendingPathComponent(
                        "package.xml"
                    )
                    guard let data = try? Data(contentsOf: metadata) else {
                        inspections.append(
                            AndroidSystemImageInspection(
                                actualRelativeDirectory: relativeDirectory,
                                image: nil,
                                metadataError: AndroidSystemImagePackageError
                                    .unreadable.localizedDescription
                            )
                        )
                        continue
                    }
                    do {
                        inspections.append(
                            AndroidSystemImageInspection(
                                actualRelativeDirectory: relativeDirectory,
                                image: try AndroidSystemImagePackageParser.parse(
                                    data: data,
                                    actualRelativeDirectory: relativeDirectory
                                ),
                                metadataError: nil
                            )
                        )
                    } catch {
                        inspections.append(
                            AndroidSystemImageInspection(
                                actualRelativeDirectory: relativeDirectory,
                                image: nil,
                                metadataError: error.localizedDescription
                            )
                        )
                    }
                }
            }
        }
        return inspections
    }

    func interactiveSystemImages(
        in toolchain: AndroidToolchain
    ) -> [AndroidSystemImage] {
        installedSystemImages(in: toolchain).filter(
            \.supportsInteractiveRendering
        )
    }

    func preferredInteractiveSystemImage(
        in toolchain: AndroidToolchain,
        avdConfiguration: String? = nil
    ) -> AndroidSystemImage? {
        let images = interactiveSystemImages(in: toolchain)
        guard let avdConfiguration else {
            return images.first
        }
        if let currentDirectory = AndroidManagedAVDConfiguration
            .systemImageDirectory(in: avdConfiguration),
           let exact = images.first(where: {
               AndroidManagedAVDConfiguration
                   .normalizedSystemImageDirectory($0.actualRelativeDirectory)
                   == currentDirectory
           }) {
            return exact
        }
        let currentTarget = AndroidManagedAVDConfiguration.targetIdentifier(
            in: avdConfiguration
        )
        let currentVariant = AndroidManagedAVDConfiguration.systemImageVariant(
            in: avdConfiguration
        )
        if let currentTarget, let currentVariant,
           let exact = images.first(where: {
               $0.targetIdentifier == currentTarget
                   && $0.variant == currentVariant
           }) {
            return exact
        }
        if let currentTarget,
           let targetMatch = images.first(where: {
               $0.targetIdentifier == currentTarget
           }) {
            return targetMatch
        }
        return images.first
    }

    private static func precedes(
        _ lhs: AndroidSystemImage,
        _ rhs: AndroidSystemImage
    ) -> Bool {
        if lhs.apiLevel != rhs.apiLevel {
            return lhs.apiLevel > rhs.apiLevel
        }
        if lhs.extensionLevel != rhs.extensionLevel {
            return lhs.extensionLevel > rhs.extensionLevel
        }
        let rank: (String) -> Int = { variant in
            switch variant {
            case "google_apis": return 0
            case "default": return 1
            default: return 2
            }
        }
        let lhsRank = rank(lhs.variant)
        let rhsRank = rank(rhs.variant)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.packageID < rhs.packageID
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

    func avdManagerCandidate(in sdkRoot: URL) -> URL? {
        let candidates = avdManagerCandidates(in: sdkRoot)
        return candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) ?? candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        })
    }

    private func avdManager(in sdkRoot: URL) -> URL? {
        avdManagerCandidates(in: sdkRoot).first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        })?.resolvingSymlinksInPath()
    }

    private func avdManagerCandidates(in sdkRoot: URL) -> [URL] {
        let latest = sdkRoot.appendingPathComponent(
            "cmdline-tools/latest/bin/avdmanager"
        )
        // `cmdline-tools` may live on a slow or temporarily unresponsive
        // external volume. The canonical `latest` install is sufficient, so
        // do not enumerate sibling versions when it is already usable.
        if fileManager.isExecutableFile(atPath: latest.path) {
            return [latest]
        }
        let commandLineTools = sdkRoot.appendingPathComponent("cmdline-tools")
        let versions = (try? fileManager.contentsOfDirectory(
            at: commandLineTools,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let versioned = versions
            .filter { $0.lastPathComponent != "latest" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/avdmanager") }
        return [latest] + versioned
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
    var systemBootIdentifier: String?
    let sdkRoot: URL
    let emulatorExecutable: URL
    var adbExecutable: URL?
    var adbServerPort: Int?
    var gpuBackend: AndroidEmulatorGPUBackend?
    var adbAuthenticationMode: AndroidEmulatorADBAuthenticationMode?
    let avdName: String
    let avdDirectory: URL
    let pid: Int32
    var pidBirthIdentity: String?
    let consolePort: Int
    let serial: String
    let forwards: [AndroidPortForwardIdentity]
    let launchedAt: Date
    var appSessionID: String?
    var runtimeSessionID: String?
    var launchOrigin: AndroidRuntimeLaunchOrigin?
    var terminationRequestedAt: Date?
    var terminationRequestReason: String?
}

enum AndroidRuntimeLaunchOrigin: String, Codable, Equatable, Sendable {
    case currentLaunch
    case adoptedExisting
}

enum AndroidRuntimeOwnershipClassification: String, Codable, Equatable,
    Sendable {
    case ownedCurrentLaunch
    case ownedExistingHealthy
    case ownedExistingBooting
    case ownedExistingOffline
    case ownedExistingADBMissing
    case staleRuntimeMetadata
    case staleAVDLock
    case externalRuntimeConflict
    case portConflict
}

enum AndroidRuntimeShutdownMechanism: String, Codable, Equatable, Sendable {
    case none
    case adbEmuKill
    case sigterm
    case sigkill
    case refusedOwnershipMismatch
    case alreadyExited
}

enum AndroidRuntimeShutdownAction: Equatable, Sendable {
    case adbEmuKill
    case sigterm
    case sigkill
    case refuse
}

enum AndroidRuntimeDiscoveryAction: Equatable, Sendable {
    case launch
    case adopt
    case rejectExternalConflict
}

enum AndroidRuntimeAdmissionError: LocalizedError, Sendable {
    case terminating

    var errorDescription: String? {
        "OKVideoMac 正在退出，已拒绝重新启动 Android 兼容环境"
    }
}

enum AndroidADBTargetState: String, Equatable, Sendable {
    case missing
    case device
    case offline
    case unauthorized
    case unknown
}

enum AndroidEmulatorGPUBackend: String, Codable, Equatable, Sendable {
    case host
    case software
}

enum AndroidEmulatorADBAuthenticationMode: String, Codable, Equatable,
    Sendable {
    /// Modern system images accept the host public key through Android boot
    /// properties. ADB authentication remains enabled end to end.
    case privateKeyBootProperty

    /// Android 10 and older system images predate the modern Emulator boot
    /// property path. A fresh, isolated key cannot be authorized in a
    /// headless guest, so the private Emulator must use its official local
    /// compatibility switch while all host-side isolation remains intact.
    case legacySkipAuthCompatibility

    var skipsGuestADBAuthentication: Bool {
        self == .legacySkipAuthCompatibility
    }

    var diagnosticReason: String? {
        switch self {
        case .privateKeyBootProperty:
            return nil
        case .legacySkipAuthCompatibility:
            return "system image API < 30 does not support modern Emulator ADB public-key boot-property provisioning"
        }
    }
}

enum AndroidADBTransportAction: Equatable, Sendable {
    case wait
    case reconnect
    case ready
    case fail(AndroidRuntimeFailureCategory)
}

struct AndroidADBTransportPolicy: Equatable, Sendable {
    static let production = AndroidADBTransportPolicy(
        timeout: 180,
        offlineGracePeriod: 20,
        summaryInterval: 5
    )

    let timeout: TimeInterval
    let offlineGracePeriod: TimeInterval
    let summaryInterval: TimeInterval

    func action(
        elapsed: TimeInterval,
        targetState: AndroidADBTargetState,
        processPresent: Bool,
        processOwned: Bool,
        reconnectAttempted: Bool,
        reconnectFailed: Bool = false,
        gpuBackend: AndroidEmulatorGPUBackend
    ) -> AndroidADBTransportAction {
        guard processPresent else { return .fail(.emulatorExitedBeforeADB) }
        guard processOwned else { return .fail(.emulatorProcessMismatch) }
        if targetState == .device { return .ready }
        if elapsed >= timeout {
            if reconnectFailed {
                return .fail(.adbReconnectFailed)
            }
            switch targetState {
            case .missing:
                return .fail(.adbSerialMissingTimeout)
            case .offline:
                return .fail(
                    gpuBackend == .host
                        ? .hostGPUADBOfflineTimeout
                        : .softwareGPUADBOfflineTimeout
                )
            case .unauthorized, .unknown:
                return .fail(.adbUnavailable)
            case .device:
                return .ready
            }
        }
        if targetState == .offline,
           elapsed >= offlineGracePeriod,
           !reconnectAttempted {
            return .reconnect
        }
        return .wait
    }

    func shouldRecordSummary(
        elapsed: TimeInterval,
        previousState: AndroidADBTargetState?,
        state: AndroidADBTargetState,
        lastSummaryElapsed: TimeInterval?
    ) -> Bool {
        if previousState != state { return true }
        guard let lastSummaryElapsed else { return true }
        return elapsed - lastSummaryElapsed >= summaryInterval
    }
}

struct AndroidADBReconnectDiagnostic: Codable, Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let monotonicElapsed: TimeInterval
    let executable: String
    let serverPort: Int
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let stateBefore: String
    let stateAfter: String
}

struct AndroidADBTransportSummary: Codable, Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let elapsed: TimeInterval
    let missingCount: Int
    let offlineCount: Int
    let deviceCount: Int
    let reconnectCount: Int
    let emulatorAlwaysAlive: Bool
    let emulatorAlwaysOwned: Bool
    let consolePortAlwaysListening: Bool?
    let adbPortAlwaysListening: Bool?
    let finalState: String
}

struct AndroidADBServerDiagnostic: Codable, Equatable, Sendable {
    let port: Int
    let pid: Int32?
    let executable: String?
    let version: String?
    let birthIdentity: String?
    let startedAt: Date?
    let ownedBySelectedSDK: Bool
}

struct AndroidPrivateADBKeyPaths: Equatable, Sendable {
    let runtimeDirectory: URL
    let privateHome: URL
    let emulatorHome: URL
    let privateKey: URL
    let publicKey: URL

    static func paths(runtimeDirectory: URL) -> Self {
        let privateHome = runtimeDirectory.appendingPathComponent(
            "home",
            isDirectory: true
        )
        let emulatorHome = privateHome.appendingPathComponent(
            ".android",
            isDirectory: true
        )
        return Self(
            runtimeDirectory: runtimeDirectory,
            privateHome: privateHome,
            emulatorHome: emulatorHome,
            privateKey: emulatorHome.appendingPathComponent("adbkey"),
            publicKey: emulatorHome.appendingPathComponent("adbkey.pub")
        )
    }
}

struct AndroidPrivateADBKeyStatus: Codable, Equatable, Sendable {
    let privateKeyExists: Bool
    let publicKeyExists: Bool
    let privateKeyReadable: Bool
    let publicKeyReadable: Bool
    let keyPairMatches: Bool?
    let publicKeySHA256: String?
}

struct AndroidPrivateADBKeyProvisionResult: Equatable, Sendable {
    let status: AndroidPrivateADBKeyStatus
    let generated: Bool
}

struct AndroidEmulatorADBKeySignals: Codable, Equatable, Sendable {
    let reportedSendingPublicKey: Bool
    let reportedMissingPrivateKey: Bool
    let bootPropertiesContainPublicKey: Bool
    let reportedPublicKeySHA256: String?
}

/// Owns only the keypair below OKVideoMac's private Android Runtime home.
/// It never searches, reads, copies, replaces, or removes `$HOME/.android`.
@inline(never)
private func androidPrivatePEMLabel() -> String {
    String(
        decoding: [80, 82, 73, 86, 65, 84, 69, 32, 75, 69, 89],
        as: UTF8.self
    )
}

enum AndroidPrivateADBKeyManager {
    static func ensureOwnedDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        if let type = itemType(at: directory), type != S_IFDIR {
            throw AppError.spider(
                "OKVideoMac 私有 Android 目录不是普通目录，已拒绝继续"
            )
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard itemType(at: directory) == S_IFDIR else {
            throw AppError.spider(
                "OKVideoMac 私有 Android 目录无法通过路径安全校验"
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    static func ensureKeyPair(
        paths: AndroidPrivateADBKeyPaths,
        fileManager: FileManager = .default,
        generate: (URL) throws -> Void
    ) throws -> AndroidPrivateADBKeyProvisionResult {
        guard paths.privateHome.deletingLastPathComponent()
                .standardizedFileURL
                == paths.runtimeDirectory.standardizedFileURL,
              paths.emulatorHome.deletingLastPathComponent()
                .standardizedFileURL == paths.privateHome.standardizedFileURL,
              paths.privateKey.deletingLastPathComponent()
                .standardizedFileURL == paths.emulatorHome.standardizedFileURL,
              paths.publicKey.deletingLastPathComponent()
                .standardizedFileURL == paths.emulatorHome.standardizedFileURL,
              paths.privateKey.lastPathComponent == "adbkey",
              paths.publicKey.lastPathComponent == "adbkey.pub" else {
            throw AppError.spider("拒绝在非 OKVideoMac 私有目录维护 ADB keypair")
        }
        for directory in [
            paths.runtimeDirectory,
            paths.privateHome,
            paths.emulatorHome
        ] {
            try ensureOwnedDirectory(directory, fileManager: fileManager)
        }
        for key in [paths.privateKey, paths.publicKey] {
            if let type = itemType(at: key), type != S_IFREG {
                throw AppError.spider(
                    "OKVideoMac 私有 ADB key 路径不是普通文件，已拒绝继续"
                )
            }
        }

        var current = status(paths: paths, fileManager: fileManager)
        if current.keyPairMatches == true {
            try applyPermissions(paths: paths, fileManager: fileManager)
            return AndroidPrivateADBKeyProvisionResult(
                status: current,
                generated: false
            )
        }

        let stagingDirectory = paths.privateHome.appendingPathComponent(
            ".adb-keygen-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        let stagingPaths = AndroidPrivateADBKeyPaths(
            runtimeDirectory: stagingDirectory,
            privateHome: stagingDirectory,
            emulatorHome: stagingDirectory,
            privateKey: stagingDirectory.appendingPathComponent("adbkey"),
            publicKey: stagingDirectory.appendingPathComponent("adbkey.pub")
        )
        try generate(stagingPaths.privateKey)
        let generated = status(paths: stagingPaths, fileManager: fileManager)
        guard generated.keyPairMatches == true,
              let privateData = try? Data(contentsOf: stagingPaths.privateKey),
              let publicData = try? Data(contentsOf: stagingPaths.publicKey)
        else {
            throw AppError.spider(
                "所选 Android SDK 未能生成有效的 OKVideoMac 私有 ADB keypair"
            )
        }

        // Each destination is an app-owned path and each write is atomic. If
        // the process stops between writes, the next call detects the mismatch
        // and replaces only this private pair.
        try privateData.write(to: paths.privateKey, options: [.atomic])
        try publicData.write(to: paths.publicKey, options: [.atomic])
        try applyPermissions(paths: paths, fileManager: fileManager)
        current = status(paths: paths, fileManager: fileManager)
        guard current.keyPairMatches == true else {
            throw AppError.spider(
                "OKVideoMac 私有 ADB keypair 写入后校验失败"
            )
        }
        return AndroidPrivateADBKeyProvisionResult(
            status: current,
            generated: true
        )
    }

    static func status(
        paths: AndroidPrivateADBKeyPaths,
        fileManager: FileManager = .default
    ) -> AndroidPrivateADBKeyStatus {
        let hierarchyIsSafe = [
            paths.runtimeDirectory,
            paths.privateHome,
            paths.emulatorHome
        ].allSatisfy { itemType(at: $0) == S_IFDIR }
        let privateType = hierarchyIsSafe
            ? itemType(at: paths.privateKey) : nil
        let publicType = hierarchyIsSafe
            ? itemType(at: paths.publicKey) : nil
        let privateExists = privateType != nil
        let publicExists = publicType != nil
        let privateData: Data?
        if privateType == S_IFREG {
            privateData = try? Data(
                contentsOf: paths.privateKey,
                options: [.mappedIfSafe]
            )
        } else {
            privateData = nil
        }
        let publicData: Data?
        if publicType == S_IFREG {
            publicData = try? Data(
                contentsOf: paths.publicKey,
                options: [.mappedIfSafe]
            )
        } else {
            publicData = nil
        }
        let matches: Bool?
        if privateExists, publicExists,
           let privateData, let publicData {
            matches = keyPairMatches(
                privateKeyPEM: privateData,
                androidPublicKey: publicData
            )
        } else {
            matches = nil
        }
        return AndroidPrivateADBKeyStatus(
            privateKeyExists: privateExists,
            publicKeyExists: publicExists,
            privateKeyReadable: privateData != nil,
            publicKeyReadable: publicData != nil,
            keyPairMatches: matches,
            publicKeySHA256: publicData.flatMap(publicKeySHA256)
        )
    }

    static func keyPairMatches(
        privateKeyPEM: Data,
        androidPublicKey: Data
    ) -> Bool {
        guard let privateKey = privateSecKey(fromPEM: privateKeyPEM),
              let publicKey = publicSecKey(
                  fromAndroidPublicKey: androidPublicKey
              ) else {
            return false
        }
        let challenge = Data(
            "OKVideoMac private ADB keypair validation v1".utf8
        )
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(
            privateKey,
            .sign,
            algorithm
        ), SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm),
        let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            challenge as CFData,
            nil
        ) as Data? else {
            return false
        }
        return SecKeyVerifySignature(
            publicKey,
            algorithm,
            challenge as CFData,
            signature as CFData,
            nil
        )
    }

    static func publicKeySHA256(_ publicKey: Data) -> String? {
        guard let binary = androidPublicKeyBinary(publicKey),
              binary.count == 524,
              littleEndianUInt32(binary, at: 0) == 64,
              littleEndianUInt32(binary, at: 520) != nil else {
            return nil
        }
        return SHA256.hash(data: binary)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func applyPermissions(
        paths: AndroidPrivateADBKeyPaths,
        fileManager: FileManager
    ) throws {
        guard itemType(at: paths.emulatorHome) == S_IFDIR,
              itemType(at: paths.privateKey) == S_IFREG,
              itemType(at: paths.publicKey) == S_IFREG else {
            throw AppError.spider(
                "OKVideoMac 私有 ADB keypair 无法通过路径安全校验"
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.emulatorHome.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.privateKey.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: paths.publicKey.path
        )
    }

    private static func itemType(at url: URL) -> mode_t? {
        var information = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &information)
        }
        guard result == 0 else { return nil }
        return information.st_mode & S_IFMT
    }

    private static func privateSecKey(fromPEM data: Data) -> SecKey? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let privateKeyLabel = androidPrivatePEMLabel()
        let isPKCS8 = text.contains(
            "-----BEGIN " + privateKeyLabel + "-----"
        )
        let encoded = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let pemDER = Data(base64Encoded: encoded) else { return nil }
        let keyDER: Data
        if isPKCS8 {
            guard let unwrapped = pkcs1PrivateKey(fromPKCS8: pemDER) else {
                return nil
            }
            keyDER = unwrapped
        } else {
            keyDER = pemDER
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048
        ]
        return SecKeyCreateWithData(
            keyDER as CFData,
            attributes as CFDictionary,
            nil
        )
    }

    /// `adb keygen` currently writes an unencrypted PKCS#8 PEM. Security's
    /// `SecKeyCreateWithData` expects the inner PKCS#1 RSA key on macOS, so
    /// unwrap only the standard PrivateKeyInfo envelope. No key bytes leave
    /// memory and no external conversion utility is required at runtime.
    private static func pkcs1PrivateKey(fromPKCS8 data: Data) -> Data? {
        guard let outer = asn1Element(in: data, at: 0),
              outer.tag == 0x30,
              outer.nextOffset == data.count,
              let version = asn1Element(in: data, at: outer.value.lowerBound),
              version.tag == 0x02,
              let algorithm = asn1Element(in: data, at: version.nextOffset),
              algorithm.tag == 0x30,
              let privateKey = asn1Element(in: data, at: algorithm.nextOffset),
              privateKey.tag == 0x04,
              privateKey.nextOffset <= outer.value.upperBound else {
            return nil
        }
        return Data(data[privateKey.value])
    }

    private struct ASN1Element {
        let tag: UInt8
        let value: Range<Int>
        let nextOffset: Int
    }

    private static func asn1Element(
        in data: Data,
        at offset: Int
    ) -> ASN1Element? {
        guard offset >= 0, data.count >= offset + 2 else { return nil }
        let tag = data[offset]
        let firstLengthByte = data[offset + 1]
        var cursor = offset + 2
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7f)
            guard (1...4).contains(byteCount),
                  data.count >= cursor + byteCount else {
                return nil
            }
            var decodedLength = 0
            for index in 0..<byteCount {
                decodedLength = (decodedLength << 8)
                    | Int(data[cursor + index])
            }
            length = decodedLength
            cursor += byteCount
        }
        guard length >= 0, data.count >= cursor + length else { return nil }
        let value = cursor..<(cursor + length)
        return ASN1Element(tag: tag, value: value, nextOffset: value.upperBound)
    }

    private static func publicSecKey(
        fromAndroidPublicKey data: Data
    ) -> SecKey? {
        guard let binary = androidPublicKeyBinary(data),
              binary.count >= 524,
              littleEndianUInt32(binary, at: 0) == 64,
              let exponent = littleEndianUInt32(binary, at: 520) else {
            return nil
        }
        let modulus = Data(binary[8..<264].reversed())
        let exponentBytes = unsignedBigEndianBytes(exponent)
        let rsaPublicKey = asn1Sequence(
            asn1Integer(modulus) + asn1Integer(exponentBytes)
        )
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2_048
        ]
        return SecKeyCreateWithData(
            rsaPublicKey as CFData,
            attributes as CFDictionary,
            nil
        )
    }

    private static func androidPublicKeyBinary(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let encoded = text.split(whereSeparator: \.isWhitespace).first
        else { return nil }
        return Data(base64Encoded: String(encoded))
    }

    private static func littleEndianUInt32(
        _ data: Data,
        at offset: Int
    ) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func unsignedBigEndianBytes(_ value: UInt32) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1, bytes.first == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }

    private static func asn1Integer(_ raw: Data) -> Data {
        var value = raw.drop { $0 == 0 }
        if value.isEmpty { value = Data([0])[...] }
        var bytes = Data(value)
        if bytes.first.map({ $0 & 0x80 != 0 }) == true {
            bytes.insert(0, at: 0)
        }
        return Data([0x02]) + asn1Length(bytes.count) + bytes
    }

    private static func asn1Sequence(_ value: Data) -> Data {
        Data([0x30]) + asn1Length(value.count) + value
    }

    private static func asn1Length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

struct AndroidADBWaitObservation: Codable, Equatable, Sendable {
    let timestamp: Date
    let expectedSerial: String
    let targetState: String
    let observedEmulatorSerials: [String]
    let adbDevices: [String]
    let emulatorPID: Int32
    let emulatorAlive: Bool
    let emulatorOwned: Bool
    let consolePort: Int
    let consolePortListening: Bool?
    let adbPort: Int
    let adbPortListening: Bool?
}

struct AndroidEmulatorProcessSnapshot: Equatable, Sendable {
    let pid: Int32?
    let launchAt: Date
    let exitAt: Date?
    let lifetime: TimeInterval
    let terminationStatus: Int32?
    let terminationReason: String?
    let terminationRequestedByApp: Bool
    let terminationRequestReason: String?
    let stdoutURL: URL
    let stderrURL: URL
    let arguments: [String]
    let environment: [String: String]
}

final class AndroidEmulatorProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    private let launchAt: Date
    private var exitAt: Date?
    private var terminationStatus: Int32?
    private var terminationReason: String?
    private var terminationRequestReason: String?
    private let stdoutURL: URL
    private let stderrURL: URL
    private let arguments: [String]
    private let environment: [String: String]

    init(
        launchAt: Date,
        stdoutURL: URL,
        stderrURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        self.launchAt = launchAt
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.arguments = arguments
        self.environment = environment
    }

    func processDidLaunch(pid: Int32) {
        lock.lock()
        self.pid = pid
        lock.unlock()
    }

    func processDidTerminate(
        pid: Int32,
        status: Int32,
        reason: String,
        at date: Date = Date()
    ) {
        lock.lock()
        self.pid = pid
        exitAt = date
        terminationStatus = status
        terminationReason = reason
        lock.unlock()
    }

    func recordTerminationRequestedByApp(_ reason: String) {
        lock.lock()
        if terminationRequestReason == nil {
            terminationRequestReason = reason
        }
        lock.unlock()
    }

    func snapshot(at date: Date = Date()) -> AndroidEmulatorProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let end = exitAt ?? date
        return AndroidEmulatorProcessSnapshot(
            pid: pid,
            launchAt: launchAt,
            exitAt: exitAt,
            lifetime: max(0, end.timeIntervalSince(launchAt)),
            terminationStatus: terminationStatus,
            terminationReason: terminationReason,
            terminationRequestedByApp: terminationRequestReason != nil,
            terminationRequestReason: terminationRequestReason,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            arguments: arguments,
            environment: environment
        )
    }
}

enum AndroidRuntimeProcessIdentityState: Equatable, Sendable {
    case owned
    case exited
    case reusedByOtherProcess
}

enum AndroidRuntimeStaleRecordReason: Equatable, Sendable {
    case previousSystemBoot
    case processExited
    case pidReused
}

enum AndroidRuntimeRecordDecision: Equatable, Sendable {
    case reuseOwnedRuntime
    case clearStaleRecord(AndroidRuntimeStaleRecordReason)
    case rejectConflictingRuntime
}

private struct AndroidRuntimeOwnershipObservation: Sendable {
    let processState: AndroidRuntimeProcessIdentityState
    let deviceReachable: Bool
    let deviceOwned: Bool
    let decision: AndroidRuntimeRecordDecision

    var processOwned: Bool { processState == .owned }
}

private struct AndroidManagedRuntimeProcessCandidate: Sendable {
    let pid: Int32
    let executable: URL
    let command: String
    let consolePort: Int
    let gpuBackend: AndroidEmulatorGPUBackend?
    let adbAuthenticationMode: AndroidEmulatorADBAuthenticationMode
    let birthIdentity: String
    let startedAt: Date
    let referencesPrivateAVD: Bool
}

private struct AndroidRuntimeProfile: Codable, Equatable, Sendable {
    static let schema = 2

    let schema: Int
    var privateADBServerPort: Int
    var preferredGPUBackend: AndroidEmulatorGPUBackend
    var privateADBServerPID: Int32?
    var privateADBServerBirthIdentity: String?
    var privateADBPublicKeySHA256: String?
    var updatedAt: Date
}

struct AndroidPrivateAVDBackupResult: Equatable, Sendable {
    let directory: URL
    let movedItemNames: [String]
    let metadataItemNames: [String]
}

private struct AndroidRuntimeContinuityRecord: Codable, Equatable, Sendable {
    let schema: Int
    let runtimeSchema: Int
    let avdName: String
    let applicationID: String
    let bridgeCertificateSHA256: String
    let bridgeVersionCode: Int
    let sourceFingerprint: String
    let destinationFingerprint: String
    let backupDirectoryName: String
    let migratedAt: Date
    let firstInstallTime: Int64?
    let androidUID: Int?
    let dataDirectoryFingerprint: String?
    let authorizationStorageFingerprint: String?
}

private struct AndroidBridgeRuntimeContinuityReport: Decodable, Sendable {
    let ok: Bool
    let runtimeSchemaVersion: Int
    let applicationId: String
    let versionCode: Int
    let firstInstallTime: Int64
    let lastUpdateTime: Int64
    let uid: Int
    let dataDirectoryFingerprint: String
    let authorizationStorageFingerprint: String
}

private struct AndroidBinaryProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let timedOut: Bool
}

/// Drains a child-process pipe while the child is running. Waiting for a
/// verbose command (notably `ps -axo command=`) before reading can fill the
/// kernel pipe buffer and deadlock both processes.
private final class AndroidProcessPipeReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let captured = handle.readDataToEndOfFile()
            lock.lock()
            data = captured
            lock.unlock()
            group.leave()
        }
    }

    func result() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// `Process.terminationHandler` can fire before an async waiter is installed.
/// Keep the exit status so both fast exits and cancellation-driven exits are
/// observed exactly once without blocking the Android runtime actor.
private final class AndroidProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func install(on process: Process) {
        process.terminationHandler = { [weak self] process in
            self?.complete(with: process.terminationStatus)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func complete(with status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: status)
        }
    }
}

/// Cancellation may race with `Process.run()`. Remember a pre-launch stop and
/// apply it immediately after launch; escalate to SIGKILL only for the exact
/// process object if normal termination does not finish promptly.
private final class AndroidBinaryProcessHandle: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopRequested = false
    private var killScheduled = false

    init(process: Process) {
        self.process = process
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        stopRunningProcessIfNeeded()
    }

    func processDidStart() {
        lock.lock()
        let shouldStop = stopRequested
        lock.unlock()
        if shouldStop {
            stopRunningProcessIfNeeded()
        }
    }

    private func stopRunningProcessIfNeeded() {
        guard process.isRunning else { return }
        process.terminate()

        lock.lock()
        let shouldScheduleKill = !killScheduled
        killScheduled = true
        lock.unlock()
        guard shouldScheduleKill else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 0.75
        ) { [process] in
            guard process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

enum AndroidBridgeHealthValidation: String, Equatable, Sendable {
    case healthy
    case serviceNotReady = "bridge_not_ready"
    case generationMissing = "bridge_generation_missing"
    case generationMismatch = "bridge_generation_mismatch"
    case versionMissing = "bridge_version_missing"
    case versionMismatch = "bridge_version_mismatch"
}

enum AndroidBridgeDeploymentAction: Equatable, Sendable {
    case installBundled
    case activateInstalledNewer(versionCode: Int)
}

struct AndroidInstalledPackageContinuity: Equatable, Sendable {
    let firstInstallTime: String
    let userID: Int
    let dataDirectory: String
}

/// Atomically admits at most one Android runtime startup operation. Every
/// caller that arrives while launch, ADB registration, Android boot, or Bridge
/// setup is in progress awaits the same task instead of running its own
/// preflight and emulator launch sequence.
actor AndroidRuntimeStartupSingleFlight {
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Error>
    }

    private var inFlight: InFlight?
    private var stopTokens = Set<UUID>()
    private var permanentlyTerminating = false

    func ensureRuntime(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard !permanentlyTerminating, stopTokens.isEmpty else {
            throw AndroidRuntimeAdmissionError.terminating
        }
        let startup: InFlight
        if let inFlight {
            startup = inFlight
        } else {
            let id = UUID()
            let task = Task {
                try await operation()
            }
            let created = InFlight(id: id, task: task)
            inFlight = created
            startup = created
        }

        do {
            try await startup.task.value
            clearIfCurrent(startup.id)
        } catch {
            clearIfCurrent(startup.id)
            throw error
        }
    }

    /// Runtime teardown is the only operation allowed to cancel the shared
    /// startup. Keep the cancelled task registered until it has fully unwound
    /// so a new caller cannot overlap its cleanup with another launch.
    func cancelAndWait() async {
        guard let startup = inFlight else { return }
        startup.task.cancel()
        _ = await startup.task.result
        clearIfCurrent(startup.id)
    }

    /// Blocks every process-local runtime instance before cancelling startup.
    /// The token keeps a manual stop exclusive until its teardown finishes;
    /// application termination is permanent for the remaining process life.
    func beginStopping(permanent: Bool) async -> UUID {
        let token = UUID()
        stopTokens.insert(token)
        permanentlyTerminating = permanentlyTerminating || permanent
        if let startup = inFlight {
            startup.task.cancel()
            _ = await startup.task.result
            clearIfCurrent(startup.id)
        }
        return token
    }

    /// Permanently closes startup admission before the rest of App teardown
    /// is allowed to run. Repeated calls are intentionally idempotent.
    func beginApplicationTermination() async {
        permanentlyTerminating = true
        if let startup = inFlight {
            startup.task.cancel()
            _ = await startup.task.result
            clearIfCurrent(startup.id)
        }
    }

    func finishStopping(_ token: UUID) {
        stopTokens.remove(token)
    }

    func isRejectingStartup() -> Bool {
        permanentlyTerminating || !stopTokens.isEmpty
    }

    private func clearIfCurrent(_ id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }
}

actor AndroidDexBridgeRuntime {
    static let bridgeVersion = "0.3.44"
    static let bridgeVersionCode = 56
    static let bridgeApplicationID = "com.okvideomac.dexbridge"
    static let bridgeCertificateSHA256 =
        "33e95ef23b662f2629a23df892aaff52ae6216f7492cfb559a63d37247a059e0"
    private static let networkCheckInterval: TimeInterval = 30
    private static let manifestSchema = 1
    private static let avdName = "OKVideoMac_Runtime"
    private static let appSessionID = UUID().uuidString
    static let diagnosticModeEnvironmentKey =
        "OKVIDEOMAC_ANDROID_RUNTIME_DIAGNOSTICS"
    static let diagnosticModeDefaultsKey =
        "OKVideoMac.AndroidRuntimeDiagnostics"
    static let candidatePrivateADBServerPorts = Array(50_437...50_445)
    static let candidateConsolePorts = Array(
        stride(from: 5_554, through: 5_682, by: 2)
    )

    private let applicationSupportDirectory: URL
    private let runtimeDirectory: URL
    private let avdHome: URL
    private let avdDirectory: URL
    private let privateADBKeyPaths: AndroidPrivateADBKeyPaths
    private let manifestURL: URL
    private let continuityURL: URL
    private let runtimeProfileURL: URL
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL
    private let currentBootIdentifier: String
    private let verboseAndroidDiagnosticsEnabled: Bool
    private var userSelectedSDKRoot: String?
    private var runtimeSelectionMode: AndroidRuntimeMode?
    private var emulatorProcess: Process?
    private var emulatorOutputHandles: [FileHandle] = []
    private var emulatorProcessRecorder: AndroidEmulatorProcessRecorder?
    private var adbServerProcess: Process?
    private var adbServerOutputHandles: [FileHandle] = []
    private var privateADBServerPort: Int
    private var preferredGPUBackend: AndroidEmulatorGPUBackend
    private var persistedADBServerPID: Int32?
    private var persistedADBServerBirthIdentity: String?
    private var lastADBServerDiagnostic: AndroidADBServerDiagnostic?
    private var lastADBReconnectDiagnostic: AndroidADBReconnectDiagnostic?
    private var lastADBTransportSummary: AndroidADBTransportSummary?
    private var lastPrivateADBKeyStatus: AndroidPrivateADBKeyStatus?
    private var privateADBKeyGeneratedThisSession = false
    private var gpuFallbackAttempted = false
    private var gpuFallbackResult: String?
    private var lastPrivateAVDRecoveryBackup: String?
    private var ready = false
    private var acceptsNewerBridge = false
    private var managedDisplayConfigured = false
    private var lastNetworkCheck: Date?
    /// Process-wide because more than one provider/runtime object can be
    /// constructed, while every instance targets the same managed AVD name.
    private static let startupSingleFlight =
        AndroidRuntimeStartupSingleFlight()
    private static let privateADBKeyLifecycleLock = NSLock()
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
    private var lastOwnershipClassification:
        AndroidRuntimeOwnershipClassification?
    private var lastShutdownMechanism: AndroidRuntimeShutdownMechanism = .none
    private var lastShutdownStartedAt: Date?
    private var lastShutdownCompletedAt: Date?
    private var lastShutdownForced = false
    private var lastStaleAVDLocksCleared: [String] = []
    private var lastLifecycleConflictReason: String?
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
    private var adbWaitTimeline: [AndroidADBWaitObservation] = []
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
    private struct ActionSurfaceLease: Sendable {
        let interactionID: UUID
        let runtimeGeneration: String
        var providerOwnerID: String?
        var surfaceMode: String?
        var surfaceGeneration: Int?
        var captureDescriptor: AndroidActionSurfaceCaptureDescriptor?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var displayPixelWidth: Int?
        var displayPixelHeight: Int?
        /// Monotonic token assigned before each async screencap. Only the most
        /// recently admitted capture may commit after actor re-entry.
        var latestCaptureToken: UInt64 = 0
        /// Token of the frame currently exposed to the host input path.
        var frameSequence: UInt64? = nil
    }
    private var actionSurfaceLease: ActionSurfaceLease?

    init(
        applicationSupportDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verboseAndroidDiagnostics: Bool? = nil
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
        privateADBKeyPaths = AndroidPrivateADBKeyPaths.paths(
            runtimeDirectory: runtimeDirectory
        )
        manifestURL = runtimeDirectory.appendingPathComponent(
            "runtime-manifest.json"
        )
        continuityURL = runtimeDirectory.appendingPathComponent(
            "runtime-continuity.json"
        )
        let profileURL = runtimeDirectory.appendingPathComponent(
            "runtime-profile.json"
        )
        runtimeProfileURL = profileURL
        backupDirectory = runtimeDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        self.fileManager = fileManager
        self.defaults = defaults
        baseEnvironment = environment
        homeDirectory = fileManager.homeDirectoryForCurrentUser
        currentBootIdentifier = Self.systemBootIdentifier()
        verboseAndroidDiagnosticsEnabled = verboseAndroidDiagnostics
            ?? Self.diagnosticModeEnabled(
                environment: environment,
                defaults: defaults
            )
        if let data = try? Data(contentsOf: profileURL),
           let profile = Self.persistedRuntimeProfile(from: data),
           Self.candidatePrivateADBServerPorts.contains(
               profile.privateADBServerPort
           ) {
            privateADBServerPort = profile.privateADBServerPort
            preferredGPUBackend = profile.preferredGPUBackend
            let currentKey = AndroidPrivateADBKeyManager.status(
                paths: privateADBKeyPaths,
                fileManager: fileManager
            )
            let canReuseRecordedServer = currentKey.keyPairMatches == true
                && profile.privateADBPublicKeySHA256 != nil
                && profile.privateADBPublicKeySHA256
                    == currentKey.publicKeySHA256
            persistedADBServerPID = canReuseRecordedServer
                ? profile.privateADBServerPID
                : nil
            persistedADBServerBirthIdentity = canReuseRecordedServer
                ? profile.privateADBServerBirthIdentity
                : nil
        } else {
            privateADBServerPort = Self.candidatePrivateADBServerPorts[0]
            preferredGPUBackend = .host
            persistedADBServerPID = nil
            persistedADBServerBirthIdentity = nil
        }
        userSelectedSDKRoot = defaults.string(
            forKey: AndroidToolchainResolver.userSDKRootDefaultsKey
        )
        runtimeSelectionMode = nil
    }

    /// Starts the single emulator display lease owned by this ActionSession.
    /// Each capture may remain full-display or become a Bridge-authorized
    /// top-level Dialog crop without changing the underlying Android UI.
    func beginActionSurfaceSession(interactionID: UUID) async throws {
        let (identity, _) = try await readyOwnedRuntime()
        actionSurfaceLease = ActionSurfaceLease(
            interactionID: interactionID,
            runtimeGeneration: identity.generation,
            providerOwnerID: nil,
            surfaceMode: nil,
            surfaceGeneration: nil,
            captureDescriptor: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            displayPixelWidth: nil,
            displayPixelHeight: nil
        )
    }

    func endActionSurfaceSession(interactionID: UUID?) {
        guard interactionID == nil
                || actionSurfaceLease?.interactionID == interactionID else {
            return
        }
        actionSurfaceLease = nil
    }

    func captureActionSurface(
        interactionID: UUID,
        providerOwnerID: String,
        surfaceMode: String,
        generation: Int,
        captureDescriptor: AndroidActionSurfaceCaptureDescriptor
    ) async throws -> AndroidActionSurfaceFrame {
        guard var lease = actionSurfaceLease,
              lease.interactionID == interactionID,
              lease.providerOwnerID == nil
                || lease.providerOwnerID == providerOwnerID else {
            throw CancellationError()
        }
        let (identity, toolchain) = try ownedRuntime(for: lease)
        lease.latestCaptureToken &+= 1
        let captureToken = lease.latestCaptureToken
        actionSurfaceLease = lease
        let fullDisplayData = try await runVerifiedADBBinary(
            identity,
            toolchain: toolchain,
            ["exec-out", "screencap", "-p"],
            category: "adb.surface.capture",
            timeout: 5
        )
        guard fullDisplayData.count >= 24,
              fullDisplayData.count <= 32 * 1_024 * 1_024,
              let displaySize = AndroidActionSurfaceFrame.pngPixelSize(
                fullDisplayData
              ),
              displaySize.width <= 8_192,
              displaySize.height <= 8_192,
              var current = actionSurfaceLease,
              current.interactionID == interactionID,
              current.runtimeGeneration == identity.generation,
              current.latestCaptureToken == captureToken,
              current.providerOwnerID == nil
                || current.providerOwnerID == providerOwnerID,
              loadIdentity()?.generation == identity.generation else {
            throw CancellationError()
        }
        let output: (
            data: Data,
            width: Int,
            height: Int,
            originX: Int,
            originY: Int
        )
        switch captureDescriptor.presentationMode {
        case .dialogCrop:
            guard let bounds = captureDescriptor.windowBounds,
                  let declaredDisplay = captureDescriptor.displayBounds,
                  declaredDisplay.width == displaySize.width,
                  declaredDisplay.height == displaySize.height else {
                throw CancellationError()
            }
            let cropped = try AndroidActionSurfaceImageCropper.crop(
                pngData: fullDisplayData,
                bounds: bounds,
                display: declaredDisplay
            )
            guard let cropSize = AndroidActionSurfaceFrame.pngPixelSize(cropped),
                  cropSize.width == bounds.width,
                  cropSize.height == bounds.height else {
                throw CancellationError()
            }
            output = (
                cropped,
                cropSize.width,
                cropSize.height,
                bounds.left,
                bounds.top
            )
        case .fullDisplay:
            if let declaredDisplay = captureDescriptor.displayBounds,
               declaredDisplay.width != displaySize.width
                    || declaredDisplay.height != displaySize.height {
                throw CancellationError()
            }
            output = (
                fullDisplayData,
                displaySize.width,
                displaySize.height,
                0,
                0
            )
        }
        current.providerOwnerID = providerOwnerID
        current.surfaceMode = surfaceMode
        current.surfaceGeneration = generation
        current.captureDescriptor = captureDescriptor
        current.pixelWidth = output.width
        current.pixelHeight = output.height
        current.displayPixelWidth = displaySize.width
        current.displayPixelHeight = displaySize.height
        current.frameSequence = captureToken
        actionSurfaceLease = current
        return AndroidActionSurfaceFrame(
            interactionID: interactionID,
            providerOwnerID: providerOwnerID,
            runtimeGeneration: identity.generation,
            surfaceMode: surfaceMode,
            generation: generation,
            frameSequence: captureToken,
            pngData: output.data,
            pixelWidth: output.width,
            pixelHeight: output.height,
            presentationMode: captureDescriptor.presentationMode,
            fallbackReason: captureDescriptor.fallbackReason,
            windowID: captureDescriptor.windowID,
            windowRevision: captureDescriptor.windowRevision,
            windowStackDepth: captureDescriptor.windowStackDepth,
            windowContentBounds: captureDescriptor.windowContentBounds,
            captureOriginX: output.originX,
            captureOriginY: output.originY,
            displayPixelWidth: displaySize.width,
            displayPixelHeight: displaySize.height
        )
    }

    func tapActionSurface(
        frame: AndroidActionSurfaceFrame,
        x: Int,
        y: Int
    ) async throws {
        let (lease, identity, toolchain) = try activeActionSurfaceLease(
            matching: frame
        )
        let point = try Self.surfacePoint(
            x: x,
            y: y,
            width: lease.pixelWidth,
            height: lease.pixelHeight,
            originX: frame.captureOriginX,
            originY: frame.captureOriginY,
            displayWidth: lease.displayPixelWidth,
            displayHeight: lease.displayPixelHeight
        )
        _ = try runADB(
            toolchain,
            [
                "-s", identity.serial,
                "shell", "input", "tap", "\(point.x)", "\(point.y)"
            ],
            category: "adb.surface.tap",
            timeout: 5
        )
    }

    func swipeActionSurface(
        frame: AndroidActionSurfaceFrame,
        fromX: Int,
        fromY: Int,
        toX: Int,
        toY: Int,
        durationMilliseconds: Int
    ) async throws {
        let (lease, identity, toolchain) = try activeActionSurfaceLease(
            matching: frame
        )
        let start = try Self.surfacePoint(
            x: fromX,
            y: fromY,
            width: lease.pixelWidth,
            height: lease.pixelHeight,
            originX: frame.captureOriginX,
            originY: frame.captureOriginY,
            displayWidth: lease.displayPixelWidth,
            displayHeight: lease.displayPixelHeight
        )
        let end = try Self.surfacePoint(
            x: toX,
            y: toY,
            width: lease.pixelWidth,
            height: lease.pixelHeight,
            originX: frame.captureOriginX,
            originY: frame.captureOriginY,
            displayWidth: lease.displayPixelWidth,
            displayHeight: lease.displayPixelHeight
        )
        let duration = min(2_000, max(50, durationMilliseconds))
        _ = try runADB(
            toolchain,
            [
                "-s", identity.serial,
                "shell", "input", "swipe",
                "\(start.x)", "\(start.y)",
                "\(end.x)", "\(end.y)",
                "\(duration)"
            ],
            category: "adb.surface.swipe",
            timeout: 5
        )
    }

    func backActionSurface(
        frame: AndroidActionSurfaceFrame
    ) async throws {
        let (_, identity, toolchain) = try activeActionSurfaceLease(
            matching: frame
        )
        _ = try runADB(
            toolchain,
            [
                "-s", identity.serial,
                "shell", "input", "keyevent", "KEYCODE_BACK"
            ],
            category: "adb.surface.back",
            timeout: 5
        )
    }

    func typeActionSurface(
        frame: AndroidActionSurfaceFrame,
        text: String
    ) async throws {
        let (_, identity, toolchain) = try activeActionSurfaceLease(
            matching: frame
        )
        guard !text.isEmpty, text.utf8.count <= 16_384 else {
            throw AppError.spider("发送到 Android 操作界面的文字为空或过长")
        }
        // `adb shell input text` receives this as one argv item; `%s` is the
        // Android input command's portable representation for spaces.
        let encoded = text.replacingOccurrences(of: " ", with: "%s")
        _ = try runADB(
            toolchain,
            [
                "-s", identity.serial,
                "shell", "input", "text", encoded
            ],
            category: "adb.surface.text",
            timeout: 10
        )
    }

    private func readyOwnedRuntime() async throws
        -> (AndroidRuntimeIdentity, AndroidToolchain) {
        try await ensureReady()
        guard let identity = loadIdentity(),
              let toolchain = resolver().toolchain(at: identity.sdkRoot),
              verifyOwnership(identity, toolchain: toolchain) else {
            throw AppError.spider(
                "Android 运行实例所有权校验失败，已拒绝操作配置画面"
            )
        }
        return (identity, toolchain)
    }

    private func ownedRuntime(
        for lease: ActionSurfaceLease
    ) throws -> (AndroidRuntimeIdentity, AndroidToolchain) {
        guard let identity = loadIdentity(),
              identity.generation == lease.runtimeGeneration,
              let toolchain = resolver().toolchain(at: identity.sdkRoot),
              verifyOwnership(identity, toolchain: toolchain) else {
            actionSurfaceLease = nil
            throw CancellationError()
        }
        return (identity, toolchain)
    }

    private func activeActionSurfaceLease(
        matching frame: AndroidActionSurfaceFrame
    ) throws -> (
        ActionSurfaceLease,
        AndroidRuntimeIdentity,
        AndroidToolchain
    ) {
        guard let lease = actionSurfaceLease,
              lease.interactionID == frame.interactionID,
              lease.runtimeGeneration == frame.runtimeGeneration,
              lease.surfaceMode == frame.surfaceMode,
              lease.surfaceGeneration == frame.generation,
              let captureDescriptor = lease.captureDescriptor,
              frame.matches(captureDescriptor: captureDescriptor),
              lease.providerOwnerID == frame.providerOwnerID,
              lease.frameSequence == frame.frameSequence,
              lease.pixelWidth == frame.pixelWidth,
              lease.pixelHeight == frame.pixelHeight,
              lease.displayPixelWidth == frame.displayPixelWidth,
              lease.displayPixelHeight == frame.displayPixelHeight else {
            throw CancellationError()
        }
        let (identity, toolchain) = try ownedRuntime(for: lease)
        return (lease, identity, toolchain)
    }

    private static func surfacePoint(
        x: Int,
        y: Int,
        width: Int?,
        height: Int?,
        originX: Int,
        originY: Int,
        displayWidth: Int?,
        displayHeight: Int?
    ) throws -> (x: Int, y: Int) {
        guard let width,
              let height,
              let displayWidth,
              let displayHeight,
              let point = AndroidActionSurfaceInputGeometryPolicy.displayPoint(
                localX: x,
                localY: y,
                cropWidth: width,
                cropHeight: height,
                originX: originX,
                originY: originY,
                displayWidth: displayWidth,
                displayHeight: displayHeight
              ) else {
            throw AppError.spider("Android 配置画面坐标已失效")
        }
        return point
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
        if stage == .ready, event != "runtimeReady" {
            appendEvent(stage: stage, event: "runtimeReady", detail: detail)
        }
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
        if failedStage == .probingBridge,
           let bridgeCategory = Self.bridgeFailureCategory(
               for: probeErrorCategory
           ) {
            category = bridgeCategory
        } else if lowercased.contains("java runtime")
                    || lowercased.contains("java_home") {
            category = .javaRuntimeMissing
        } else if lowercased.contains("其他 emulator")
                    || lowercased.contains("记录端口") {
            category = .emulatorRuntimeConflict
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

    static func bridgeFailureCategory(
        for probeErrorCategory: String?
    ) -> AndroidRuntimeFailureCategory? {
        switch probeErrorCategory {
        case AndroidBridgeHealthValidation.generationMissing.rawValue,
             AndroidBridgeHealthValidation.generationMismatch.rawValue:
            return .bridgeIdentityMismatch
        case AndroidBridgeHealthValidation.versionMissing.rawValue,
             AndroidBridgeHealthValidation.versionMismatch.rawValue:
            return .bridgeVersionMismatch
        default:
            return nil
        }
    }

    static func terminalBridgeProbeMessage(
        for probeErrorCategory: String?
    ) -> String {
        switch bridgeFailureCategory(for: probeErrorCategory) {
        case .bridgeIdentityMismatch:
            return "Android Bridge 实例身份不匹配；已拒绝把非本次启动的 Bridge 标记为已连接"
        case .bridgeVersionMismatch:
            return "Android Bridge 版本不匹配（宿主要求 \(bridgeVersion)）；已拒绝把不兼容的 Bridge 标记为已连接"
        default:
            return "Java/Dex Android 桥启动超时（已执行一次有界恢复）"
        }
    }

    static func managedRuntimeFailureCategory(
        processPresent: Bool,
        processOwned: Bool,
        deviceRequired: Bool,
        deviceReachable: Bool,
        deviceOwned: Bool
    ) -> AndroidRuntimeFailureCategory? {
        if !processPresent {
            return .runtimeExited
        }
        if !processOwned {
            return .emulatorProcessMismatch
        }
        if deviceRequired && !deviceReachable {
            return .adbUnavailable
        }
        if deviceReachable && !deviceOwned {
            return .emulatorOwnershipMismatch
        }
        return nil
    }

    static func waitingForADBFailureCategory(
        processPresent: Bool,
        processOwned: Bool,
        targetState: AndroidADBTargetState,
        deviceOwned: Bool,
        hasUnexpectedEmulatorSerial: Bool = false
    ) -> AndroidRuntimeFailureCategory? {
        if !processPresent {
            return .emulatorExited
        }
        if !processOwned {
            return .emulatorProcessMismatch
        }
        switch targetState {
        case .missing:
            return hasUnexpectedEmulatorSerial
                ? .unexpectedSerial : .adbDeviceMissing
        case .offline:
            return .adbDeviceOffline
        case .unauthorized, .unknown:
            return .adbUnavailable
        case .device:
            return deviceOwned ? nil : .emulatorOwnershipMismatch
        }
    }

    static func emulatorTerminationCategory(
        _ snapshot: AndroidEmulatorProcessSnapshot?
    ) -> AndroidRuntimeFailureCategory? {
        guard let snapshot else { return nil }
        if snapshot.terminationRequestedByApp {
            return .appRequestedTermination
        }
        return snapshot.exitAt == nil ? nil : .emulatorExited
    }

    static func processIdentityState(
        processPresent: Bool,
        processOwned: Bool
    ) -> AndroidRuntimeProcessIdentityState {
        if processOwned {
            return .owned
        }
        return processPresent ? .reusedByOtherProcess : .exited
    }

    static func runtimeRecordDecision(
        recordedBootIdentifier: String?,
        currentBootIdentifier: String,
        processPresent: Bool,
        processOwned: Bool,
        deviceReachable: Bool,
        deviceOwned: Bool
    ) -> AndroidRuntimeRecordDecision {
        if let recordedBootIdentifier,
           !bootIdentifiersReferToSameBoot(
               recordedBootIdentifier,
               currentBootIdentifier
           ) {
            return deviceReachable
                ? .rejectConflictingRuntime
                : .clearStaleRecord(.previousSystemBoot)
        }

        let processState = processIdentityState(
            processPresent: processPresent,
            processOwned: processOwned
        )
        if processState == .owned {
            if deviceReachable && !deviceOwned {
                return .rejectConflictingRuntime
            }
            return .reuseOwnedRuntime
        }
        guard !deviceReachable else {
            return .rejectConflictingRuntime
        }
        switch processState {
        case .owned:
            return .reuseOwnedRuntime
        case .exited:
            return .clearStaleRecord(.processExited)
        case .reusedByOtherProcess:
            return .clearStaleRecord(.pidReused)
        }
    }

    static func systemBootIdentifier() -> String {
        if let sessionUUID = bootSessionUUID() {
            if let legacyIdentifier = legacySystemBootIdentifier() {
                return "session:\(sessionUUID)|legacy:\(legacyIdentifier)"
            }
            return "session:\(sessionUUID)"
        }
        return legacySystemBootIdentifier()
            ?? "estimated:\(Int64(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime))"
    }

    static func bootIdentifiersReferToSameBoot(
        _ recorded: String,
        _ current: String
    ) -> Bool {
        if recorded == current { return true }

        let recordedSession = bootSessionUUID(from: recorded)
        let currentSession = bootSessionUUID(from: current)
        if let recordedSession, let currentSession {
            return recordedSession.caseInsensitiveCompare(currentSession)
                == .orderedSame
        }

        guard let recordedSeconds = legacyBootSeconds(from: recorded),
              let currentSeconds = legacyBootSeconds(from: current) else {
            return false
        }
        // `kern.boottime` is expressed in wall-clock time and can drift when
        // macOS corrects its clock. It is retained only to migrate manifests
        // written before the stable boot-session UUID was introduced.
        return abs(recordedSeconds - currentSeconds) <= 300
    }

    private static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(
            "kern.bootsessionuuid",
            &buffer,
            &size,
            nil,
            0
        ) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    private static func legacySystemBootIdentifier() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 {
            return "\(bootTime.tv_sec):\(bootTime.tv_usec)"
        }
        return nil
    }

    private static func bootSessionUUID(from identifier: String) -> String? {
        guard identifier.hasPrefix("session:") else { return nil }
        return identifier
            .dropFirst("session:".count)
            .split(separator: "|", maxSplits: 1)
            .first
            .map(String.init)
    }

    private static func legacyBootSeconds(from identifier: String) -> Int64? {
        let legacy: Substring
        if let range = identifier.range(of: "|legacy:") {
            legacy = identifier[range.upperBound...]
        } else if identifier.hasPrefix("estimated:") {
            legacy = identifier.dropFirst("estimated:".count)
        } else if !identifier.hasPrefix("session:") {
            legacy = Substring(identifier)
        } else {
            return nil
        }
        guard let seconds = legacy.split(separator: ":", maxSplits: 1).first
        else { return nil }
        return Int64(seconds)
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
            guard var identity = loadIdentity() else {
                return .failed("Android 运行记录损坏，需要重新初始化")
            }
            guard let toolchain = resolver().toolchain(at: identity.sdkRoot) else {
                return .failed("原 Android SDK 已不可用，无法安全确认运行实例")
            }
            let observation = observeRuntimeOwnership(
                identity,
                toolchain: toolchain
            )
            switch observation.decision {
            case .reuseOwnedRuntime:
                if identity.systemBootIdentifier != currentBootIdentifier {
                    identity.systemBootIdentifier = currentBootIdentifier
                    try? saveIdentity(identity)
                }
                guard observation.deviceReachable else {
                    return .starting(progress: 0.45)
                }
                if (try? await isHealthy(
                    identity,
                    toolchain: toolchain,
                    acceptVersionMismatch: true
                )) == true {
                    ready = true
                    acceptsNewerBridge = true
                    lastNetworkCheck = Date()
                    return .running
                }
                return .starting(progress: 0.70)
            case let .clearStaleRecord(reason):
                appendStaleRecordRecovery(reason)
                clearRuntimeRecord()
            case .rejectConflictingRuntime:
                return .failed(
                    "检测到其他 Emulator 使用了记录端口，未执行任何操作"
                )
            }
        }

        ready = false
        guard let toolchain = resolver().resolve() else {
            return .unavailable("未找到完整 Android SDK，请选择包含 adb 和 emulator 的 SDK")
        }
        guard !resolver().interactiveSystemImages(in: toolchain).isEmpty else {
            return .unavailable(
                "缺少可显示原生界面的 arm64 Android system image（ATD 不支持界面捕获）"
            )
        }
        if fileManager.fileExists(
            atPath: avdDirectory.appendingPathComponent("config.ini").path
        ) {
            return .stopped
        }
        guard toolchain.avdManager != nil else {
            return .unavailable("缺少 Android SDK Command-line Tools（avdmanager）")
        }
        guard resolver().resolveJavaRuntime() != nil else {
            return .unavailable(
                "创建 AVD 缺少 Java Runtime；请安装 JDK 或 Android Studio JBR"
            )
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
            try? ensureADBServer(toolchain)
            adbVersion = try? runADB(
                toolchain,
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
            if let devices = try? runADB(
                toolchain,
                ["devices", "-l"],
                category: "diagnostic.adb.devices",
                timeout: 5
            ) {
                lastADBDevices = Self.sanitizedADBDevices(
                    devices,
                    ownedSerial: identity?.serial
                )
                if let serial = identity?.serial {
                    deviceState = Self.adbTargetState(
                        in: devices,
                        serial: serial
                    ).rawValue
                }
            }
        }

        if let identity, let toolchain {
            processRunning = verifyProcessOwnership(
                identity,
                toolchain: toolchain
            )
            if let observedState = try? runADB(
                toolchain,
                ["-s", identity.serial, "get-state"],
                category: "diagnostic.adb.get_state",
                timeout: 5
            ).trimmingCharacters(in: .whitespacesAndNewlines),
               !observedState.isEmpty {
                deviceState = observedState
            }
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

        let configurationURL = avdDirectory.appendingPathComponent(
            "config.ini"
        )
        let configurationContents = try? String(
            contentsOf: configurationURL,
            encoding: .utf8
        )
        let image = toolchain.flatMap {
            resolver().preferredInteractiveSystemImage(
                in: $0,
                avdConfiguration: configurationContents
            )
        }
        let javaRuntime = resolver().resolveJavaRuntime()
        let avdManagerCandidate = toolchain.flatMap {
            resolver().avdManagerCandidate(in: $0.sdkRoot)
        }
        let imageDiagnostics = toolchain.map {
            resolver().systemImageDiagnostics(in: $0)
        } ?? []
        let configuredImageDirectory = configurationContents.flatMap {
            AndroidManagedAVDConfiguration.systemImageDirectory(in: $0)
        }
        let imageMatchesConfiguration = configurationContents.map { contents in
            image.map {
                AndroidManagedAVDConfiguration.matches($0, contents: contents)
            } ?? false
        }
        let hardwareConfigurationURL = avdDirectory.appendingPathComponent(
            "hardware-qemu.ini"
        )
        let hardwareConfigurationContents = try? String(
            contentsOf: hardwareConfigurationURL,
            encoding: .utf8
        )
        let avdEntries = (try? fileManager.contentsOfDirectory(
            at: avdDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let avdLockFiles = avdEntries
            .map(\.lastPathComponent)
            .filter { $0.lowercased().contains("lock") }
            .sorted()
        let avdRuntimeFiles = Dictionary(uniqueKeysWithValues: [
            "config.ini",
            "hardware-qemu.ini",
            "userdata-qemu.img",
            "cache.img",
            "snapshots"
        ].map { name in
            (
                name,
                fileManager.fileExists(
                    atPath: avdDirectory.appendingPathComponent(name).path
                )
            )
        })
        let apk = try? bridgeAPK()
        let apkHash = apk.flatMap(Self.sha256Hex)
        let configExists = fileManager.fileExists(
            atPath: configurationURL.path
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
        let emulatorSnapshot = emulatorProcessRecorder?.snapshot()
        let privateADBKeyStatus = lastPrivateADBKeyStatus
            ?? AndroidPrivateADBKeyManager.status(
                paths: privateADBKeyPaths,
                fileManager: fileManager
            )
        let privateEnvironment = toolchain.map {
            childEnvironment(for: $0)
        }
        let adbKeySignals = emulatorADBKeySignals(emulatorSnapshot)
        let adbServerKeySignals = privateADBServerKeySignals()
        let adbAuthenticationMode = identity?.adbAuthenticationMode
            ?? Self.emulatorADBAuthenticationMode(
                systemImageAPILevel: image?.apiLevel
            )
        let emulatorSkipADBAuthEnabled = emulatorSnapshot.map {
            $0.arguments.contains("-skip-adb-auth")
        } ?? identity?.adbAuthenticationMode?
            .skipsGuestADBAuthentication ?? false
        return AndroidRuntimeDiagnosticSnapshot(
            runtimeMode: runtimeSelectionMode,
            runtimeState: runtimeState,
            ownershipClassification: lastOwnershipClassification,
            launchOrigin: identity?.launchOrigin,
            appSessionID: identity?.appSessionID,
            runtimeSessionID: identity?.runtimeSessionID,
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
            emulatorLaunchAt: emulatorSnapshot?.launchAt,
            emulatorExitAt: emulatorSnapshot?.exitAt,
            emulatorLifetime: emulatorSnapshot?.lifetime,
            emulatorTerminationStatus: emulatorSnapshot?.terminationStatus,
            emulatorTerminationReason: emulatorSnapshot?.terminationReason,
            emulatorTerminationRequestedByApp: emulatorSnapshot?
                .terminationRequestedByApp
                    ?? (identity?.terminationRequestedAt != nil),
            emulatorTerminationRequestReason: emulatorSnapshot?
                .terminationRequestReason
                    ?? identity?.terminationRequestReason,
            emulatorStdoutTail: emulatorSnapshot.flatMap {
                emulatorLogTail(at: $0.stdoutURL)
            },
            emulatorStderrTail: emulatorSnapshot.flatMap {
                emulatorLogTail(at: $0.stderrURL)
            },
            emulatorArguments: emulatorSnapshot?.arguments ?? [],
            emulatorEnvironment: emulatorSnapshot?.environment ?? [:],
            emulatorADBAuthenticationMode: adbAuthenticationMode,
            emulatorSkipADBAuthEnabled: emulatorSkipADBAuthEnabled,
            emulatorADBAuthenticationCompatibilityReason:
                adbAuthenticationMode.diagnosticReason,
            adbEnvironment: toolchain.map {
                diagnosticEmulatorEnvironment(
                    childEnvironment(for: $0),
                    toolchain: $0
                )
            } ?? [:],
            privateADBKeyPath:
                "<app-support>/AndroidRuntime/home/.android/adbkey",
            privateADBPublicKeyPath:
                "<app-support>/AndroidRuntime/home/.android/adbkey.pub",
            privateADBKeyExists: privateADBKeyStatus.privateKeyExists,
            privateADBPublicKeyExists: privateADBKeyStatus.publicKeyExists,
            privateADBKeyReadable: privateADBKeyStatus.privateKeyReadable,
            privateADBPublicKeyReadable:
                privateADBKeyStatus.publicKeyReadable,
            privateADBKeyPairMatches: privateADBKeyStatus.keyPairMatches,
            privateADBPublicKeySHA256:
                privateADBKeyStatus.publicKeySHA256,
            privateADBKeyGeneratedThisSession:
                privateADBKeyGeneratedThisSession,
            adbVendorKeysPointsToPrivateKey:
                privateEnvironment?["ADB_VENDOR_KEYS"]
                    == privateADBKeyPaths.privateKey.path,
            privateADBServerReportedKeyLoaded:
                adbServerKeySignals.reportedKeyLoaded,
            privateADBServerReportedExpectedKeyPath:
                adbServerKeySignals.expectedPathMatched,
            androidEmulatorHomePath:
                "<app-support>/AndroidRuntime/home/.android",
            androidEmulatorHomeIsPrivate:
                privateEnvironment?["ANDROID_EMULATOR_HOME"]
                    == privateADBKeyPaths.emulatorHome.path,
            emulatorReportedSendingADBPublicKey:
                adbKeySignals.reportedSendingPublicKey,
            emulatorReportedNoADBPrivateKey:
                adbKeySignals.reportedMissingPrivateKey,
            emulatorBootPropertiesContainADBPublicKey:
                adbKeySignals.bootPropertiesContainPublicKey,
            emulatorReportedADBPublicKeySHA256:
                adbKeySignals.reportedPublicKeySHA256,
            emulatorReportedADBPublicKeyMatchesPrivateKey:
                adbKeySignals.reportedPublicKeySHA256.flatMap { reported in
                    privateADBKeyStatus.publicKeySHA256.map {
                        reported == $0
                    }
                },
            androidRuntimeDiagnosticModeEnabled:
                verboseAndroidDiagnosticsEnabled,
            adbPrivateServer: lastADBServerDiagnostic,
            adbReconnect: lastADBReconnectDiagnostic,
            adbTransportSummary: lastADBTransportSummary,
            selectedGPUBackend: identity?.gpuBackend
                ?? preferredGPUBackend,
            gpuFallbackAttempted: gpuFallbackAttempted,
            gpuFallbackResult: gpuFallbackResult,
            privateAVDRecoveryBackup: lastPrivateAVDRecoveryBackup,
            emulatorTerminationCategory: Self.emulatorTerminationCategory(
                emulatorSnapshot
            ),
            avdManagerPath: avdManagerCandidate.map { _ in
                "<sdk-root>/cmdline-tools/<version>/bin/avdmanager"
            },
            avdManagerExists: avdManagerCandidate.map {
                fileManager.fileExists(atPath: $0.path)
            } ?? false,
            avdManagerExecutable: avdManagerCandidate.map {
                fileManager.isExecutableFile(atPath: $0.path)
            } ?? false,
            javaHome: javaRuntime.map { _ in "<java-home>" },
            javaRuntimeSource: javaRuntime?.source,
            javaExecutable: javaRuntime.map {
                fileManager.isExecutableFile(atPath: $0.executable.path)
            } ?? false,
            expectedAVDName: Self.avdName,
            avdExists: configExists,
            avdPath: "<app-support>/AndroidRuntime/avd/\(Self.avdName).avd",
            systemImage: image?.packageID,
            systemImageAPILevel: image?.apiLevel,
            systemImageExtensionLevel: image?.extensionLevel,
            systemImageABI: image?.architecture,
            systemImageDirectory: image?.actualRelativeDirectory,
            systemImageCandidates: imageDiagnostics,
            configuredAVDSystemImageDirectory: configuredImageDirectory,
            avdSystemImageMatchesSelection: imageMatchesConfiguration,
            avdConfigSummary: diagnosticAVDConfiguration(
                configurationContents,
                toolchain: toolchain
            ),
            avdHardwareConfigSummary: diagnosticAVDConfiguration(
                hardwareConfigurationContents,
                toolchain: toolchain
            ),
            avdLockFiles: avdLockFiles,
            avdRuntimeFiles: avdRuntimeFiles,
            emulatorPID: identity?.pid,
            emulatorPIDBirthIdentity: identity?.pidBirthIdentity,
            emulatorConsolePort: identity?.consolePort,
            emulatorADBPort: identity.map { $0.consolePort + 1 },
            emulatorSerial: identity?.serial,
            emulatorProcessRunning: processRunning,
            adbDeviceState: deviceState,
            adbWaitTimeline: adbWaitTimeline,
            shutdownMechanism: lastShutdownMechanism,
            shutdownStartedAt: lastShutdownStartedAt,
            shutdownCompletedAt: lastShutdownCompletedAt,
            shutdownElapsed: lastShutdownStartedAt.map { started in
                (lastShutdownCompletedAt ?? Date()).timeIntervalSince(started)
            },
            shutdownForced: lastShutdownForced,
            staleAVDLocksCleared: lastStaleAVDLocksCleared,
            lifecycleConflictReason: lastLifecycleConflictReason,
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
        if runtimeSelectionMode == .managed {
            return "managed-generation"
        }
        if runtimeSelectionMode == .external {
            return "explicit-external"
        }
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
        runtimeSelectionMode = .external
        resetResolvedRuntimeState()
    }

    /// Product-level routing resolves Managed versus External before entering
    /// the stable Session state machine. This setter only supplies that exact
    /// selection; it never persists or discovers a fallback SDK.
    func setRuntimeSelection(
        mode: AndroidRuntimeMode,
        externalSDKRoot: URL?
    ) {
        let normalizedRoot = externalSDKRoot?.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard runtimeSelectionMode != mode
                || userSelectedSDKRoot != normalizedRoot else { return }
        runtimeSelectionMode = mode
        userSelectedSDKRoot = mode == .external ? normalizedRoot : nil
        resetResolvedRuntimeState()
    }

    private func resetResolvedRuntimeState() {
        actionSurfaceLease = nil
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
    }

    func start() async throws {
        try await ensureReady()
    }

    func repair() async throws {
        actionSurfaceLease = nil
        let retryKnownFailedNetworkCommand = AndroidRuntimeRecoveryPolicy
            .shouldRetryKnownFailedNetworkCommand(
                lastFailureStage: lastFailure?.stage,
                networkRecoveryResult: networkRecoveryResult
            )
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
        await Self.startupSingleFlight.cancelAndWait()
        try await ensureRuntimeStartup(
            forceInstall: true,
            retryKnownFailedNetworkCommand: retryKnownFailedNetworkCommand
        )
    }

    func rebuildPrivateAVD() async throws {
        let stopToken = await Self.startupSingleFlight.beginStopping(
            permanent: false
        )
        do {
            guard let toolchain = resolver().resolve() else {
                throw AppError.spider(
                    "未找到用户选择的完整 Android SDK；未修改现有 Runtime"
                )
            }
            guard toolchain.avdManager != nil else {
                throw AppError.spider(
                    "所选 Android SDK 缺少 Command-line Tools（avdmanager）；未修改现有 Runtime"
                )
            }
            guard !resolver().interactiveSystemImages(in: toolchain).isEmpty
            else {
                throw AppError.spider(
                    "所选 Android SDK 没有可用的 arm64 可视 system image；本版本不会自动下载"
                )
            }
            guard resolver().resolveJavaRuntime() != nil else {
                throw AppError.spider(
                    "重建 Android Runtime 需要 Java Runtime；未修改现有 Runtime"
                )
            }
            // A rebuilt guest must see the same app-owned key used by the
            // private ADB daemon on its very first boot.
            try ensurePrivateADBKeypair(toolchain)

            let metadataSnapshots = Self.privateAVDMetadataSnapshots(
                runtimeDirectory: runtimeDirectory,
                fileManager: fileManager
            )
            await performStop(reason: "privateAVDRepair")
            let matchingProcessCount = try matchingAVDProcessCount()
            guard Self.privateAVDRepairMayProceed(
                shutdownMechanism: lastShutdownMechanism,
                matchingAVDProcessCount: matchingProcessCount
            ) else {
                throw AppError.spider(
                    "无法明确确认 OKVideoMac 专用 Emulator 已停止，已拒绝重建"
                )
            }

            appendEvent(
                stage: .preparingAVD,
                event: "privateAVDBackupStart"
            )
            let backup = try Self.movePrivateAVDToRecoverableBackup(
                runtimeDirectory: runtimeDirectory,
                fileManager: fileManager,
                metadataSnapshots: metadataSnapshots
            )
            lastPrivateAVDRecoveryBackup = backup.map {
                "<app-support>/AndroidRuntime/Backups/"
                    + $0.directory.lastPathComponent
            }
            if let backup {
                appendEvent(
                    stage: .preparingAVD,
                    event: "privateAVDBackupCreated",
                    detail: backup.directory.lastPathComponent
                )
            }
            clearRuntimeRecord()
            ready = false
            acceptsNewerBridge = false
            lastNetworkCheck = nil
            lastFailure = nil
            transition(to: .preparingAVD)
            try ensureManagedAVD(
                toolchain,
                gpuBackend: preferredGPUBackend
            )
            appendEvent(
                stage: .preparingAVD,
                event: "privateAVDRecreated",
                detail: "gpu=\(preferredGPUBackend.rawValue)"
            )
        } catch {
            await Self.startupSingleFlight.finishStopping(stopToken)
            throw error
        }
        await Self.startupSingleFlight.finishStopping(stopToken)
        try await ensureRuntimeStartup(forceInstall: true)
    }

    func stop() async {
        let stopToken = await Self.startupSingleFlight.beginStopping(
            permanent: false
        )
        let toolchain = loadIdentity().flatMap {
            resolver().toolchain(at: $0.sdkRoot)
        } ?? resolver().resolve() ?? lastObservedToolchain
        await performStop(reason: "userRequestedStop")
        stopPrivateADBServerIfOwned(toolchain: toolchain)
        await Self.startupSingleFlight.finishStopping(stopToken)
    }

    func shutdownForApplicationTermination() async {
        await beginApplicationTermination()
        let toolchain = loadIdentity().flatMap {
            resolver().toolchain(at: $0.sdkRoot)
        } ?? resolver().resolve() ?? lastObservedToolchain
        await performStop(reason: "applicationTermination")
        stopPrivateADBServerIfOwned(toolchain: toolchain)
    }

    func beginApplicationTermination() async {
        await Self.startupSingleFlight.beginApplicationTermination()
    }

    private func performStop(reason: String) async {
        actionSurfaceLease = nil
        managedDisplayConfigured = false
        transition(to: .stopping, event: "stop_requested")
        lastShutdownStartedAt = Date()
        lastShutdownCompletedAt = nil
        lastShutdownMechanism = .none
        lastShutdownForced = false
        ready = false
        acceptsNewerBridge = false
        lastNetworkCheck = nil
        defer {
            lastShutdownCompletedAt = Date()
            completeCurrentStage()
            currentStage = .idle
            stageStartedAt = nil
            operationStatus = nil
        }

        var identity = loadIdentity()
        var toolchain = identity.flatMap {
            resolver().toolchain(at: $0.sdkRoot)
        }
        if identity == nil, let resolved = resolver().resolve() {
            toolchain = resolved
            do {
                identity = try discoverExistingManagedRuntime(
                    toolchain: resolved
                )
            } catch {
                lastShutdownMechanism = .refusedOwnershipMismatch
                preserveFailure(classifiedFailure(for: error, stage: .stopping))
                return
            }
        }
        guard var identity else {
            lastShutdownMechanism = .alreadyExited
            clearRuntimeRecord()
            if let toolchain {
                try? clearStalePrivateAVDLocksIfSafe(
                    toolchain: toolchain,
                    updateOwnershipClassification: false
                )
            }
            return
        }
        guard let toolchain else {
            preserveFailure(
                classifiedFailure(
                    for: AppError.spider(
                        "原 Android SDK 已不可用，未执行任何 Emulator 操作"
                    ),
                    stage: .stopping
                )
            )
            return
        }
        guard verifyProcessOwnership(identity, toolchain: toolchain) else {
            let processPresent = processExecutablePath(pid: identity.pid) != nil
            if !processPresent
                || processBirthIdentity(pid: identity.pid)?.value
                    != identity.pidBirthIdentity {
                lastShutdownMechanism = .alreadyExited
                finishOwnedRuntimeExitCleanup(toolchain: toolchain)
            } else {
                lastShutdownMechanism = .refusedOwnershipMismatch
                lastLifecycleConflictReason =
                    "停止前 PID/executable/argv 身份校验失败"
            }
            return
        }
        identity = refreshedIdentityForCurrentSession(
            identity,
            toolchain: toolchain
        )
        identity.terminationRequestedAt = Date()
        identity.terminationRequestReason = reason
        lastObservedIdentity = identity
        try? saveIdentity(identity)
        let observation = observeRuntimeOwnership(
            identity,
            toolchain: toolchain
        )
        switch observation.decision {
        case let .clearStaleRecord(reason):
            appendStaleRecordRecovery(reason)
            lastShutdownMechanism = .alreadyExited
            finishOwnedRuntimeExitCleanup(toolchain: toolchain)
            return
        case .rejectConflictingRuntime:
            lastShutdownMechanism = .refusedOwnershipMismatch
            lastLifecycleConflictReason =
                "停止时运行记录与当前进程或 ADB 设备不一致"
            preserveFailure(
                classifiedFailure(
                    for: AppError.spider(
                        "检测到其他 Emulator 使用了记录端口，未执行任何操作"
                    ),
                    stage: .stopping
                )
            )
            return
        case .reuseOwnedRuntime:
            break
        }

        guard verifyStrictProcessOwnership(identity, toolchain: toolchain)
        else {
            lastShutdownMechanism = .refusedOwnershipMismatch
            lastLifecycleConflictReason =
                "停止前未同时验证 PID 出生标识与私有 AVD 打开文件"
            preserveFailure(
                classifiedFailure(
                    for: AppError.spider(
                        "无法严格确认专用 Android Emulator，未执行终止"
                    ),
                    stage: .stopping
                )
            )
            return
        }

        recordEmulatorTerminationRequest(pid: identity.pid, reason: reason)
        if observation.deviceOwned {
            try? removeOwnedPortForwards(identity, toolchain: toolchain)
            _ = try? runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["emu", "kill"],
                category: "adb.runtime.shutdown"
            )
            lastShutdownMechanism = .adbEmuKill
            if await waitForOwnedProcessExit(identity, attempts: 20) {
                finishOwnedRuntimeExitCleanup(toolchain: toolchain)
                return
            }
        }

        guard verifyStrictProcessOwnership(identity, toolchain: toolchain)
        else {
            finishShutdownAfterIdentityChanged(
                identity,
                toolchain: toolchain
            )
            return
        }
        _ = Darwin.kill(identity.pid, SIGTERM)
        lastShutdownMechanism = .sigterm
        if await waitForOwnedProcessExit(identity, attempts: 12) {
            finishOwnedRuntimeExitCleanup(toolchain: toolchain)
            return
        }

        guard verifyStrictProcessOwnership(identity, toolchain: toolchain)
        else {
            finishShutdownAfterIdentityChanged(
                identity,
                toolchain: toolchain
            )
            return
        }
        _ = Darwin.kill(identity.pid, SIGKILL)
        lastShutdownMechanism = .sigkill
        lastShutdownForced = true
        if await waitForOwnedProcessExit(identity, attempts: 8) {
            finishOwnedRuntimeExitCleanup(toolchain: toolchain)
            return
        }
        preserveFailure(
            classifiedFailure(
                for: AppError.spider(
                    "专用 Android Emulator 未确认停止；已保留运行记录以防误操作"
                ),
                stage: .stopping
            )
        )
    }

    private func waitForOwnedProcessExit(
        _ identity: AndroidRuntimeIdentity,
        attempts: Int
    ) async -> Bool {
        for _ in 0..<attempts {
            guard let current = processBirthIdentity(pid: identity.pid) else {
                return true
            }
            if current.value != identity.pidBirthIdentity {
                appendEvent(
                    stage: .stopping,
                    event: "shutdown_pid_identity_changed",
                    detail: "pid=\(identity.pid)"
                )
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return processBirthIdentity(pid: identity.pid) == nil
    }

    private func finishShutdownAfterIdentityChanged(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) {
        if processBirthIdentity(pid: identity.pid)?.value
            != identity.pidBirthIdentity {
            lastShutdownMechanism = .alreadyExited
            finishOwnedRuntimeExitCleanup(toolchain: toolchain)
        } else {
            lastShutdownMechanism = .refusedOwnershipMismatch
            lastLifecycleConflictReason =
                "终止升级前 PID 身份或私有 AVD 校验发生变化"
        }
    }

    private func finishOwnedRuntimeExitCleanup(
        toolchain: AndroidToolchain
    ) {
        clearRuntimeRecord()
        try? clearStalePrivateAVDLocksIfSafe(
            toolchain: toolchain,
            updateOwnershipClassification: false
        )
    }

    func ensureReady() async throws {
        guard !(await Self.startupSingleFlight.isRejectingStartup()) else {
            throw AndroidRuntimeAdmissionError.terminating
        }
        if ready {
            guard let identity = loadIdentity(),
                  let toolchain = resolver().toolchain(at: identity.sdkRoot)
            else {
                ready = false
                throw AppError.spider(
                    "Android 运行实例所有权校验失败，已拒绝继续操作"
                )
            }
            let observation = observeRuntimeOwnership(
                identity,
                toolchain: toolchain
            )
            switch observation.decision {
            case let .clearStaleRecord(reason):
                appendStaleRecordRecovery(reason)
                clearRuntimeRecord()
                ready = false
            case .rejectConflictingRuntime:
                ready = false
                throw classifiedFailure(
                    for: AppError.spider(
                        "检测到其他 Emulator 使用了记录端口，未执行任何操作"
                    )
                )
            case .reuseOwnedRuntime:
                if observation.deviceOwned {
                    if !managedDisplayConfigured {
                        try configureManagedDisplay(
                            identity,
                            toolchain: toolchain
                        )
                    }
                    if let lastNetworkCheck,
                       Date().timeIntervalSince(lastNetworkCheck)
                            < Self.networkCheckInterval {
                        return
                    }
                    if try await isHealthy(
                        identity,
                        toolchain: toolchain,
                        acceptVersionMismatch: acceptsNewerBridge
                    ) {
                        lastNetworkCheck = Date()
                        return
                    }
                }
                ready = false
            }
        }
        try await ensureRuntimeStartup()
    }

    func resetAuthorizationUI() async throws {
        guard let identity = loadIdentity(),
              let toolchain = resolver().toolchain(at: identity.sdkRoot) else {
            throw AppError.spider("Android 运行实例所有权校验失败")
        }
        let observation = observeRuntimeOwnership(
            identity,
            toolchain: toolchain
        )
        switch observation.decision {
        case let .clearStaleRecord(reason):
            appendStaleRecordRecovery(reason)
            clearRuntimeRecord()
            try await ensureRuntimeStartup()
            return
        case .rejectConflictingRuntime:
            throw classifiedFailure(
                for: AppError.spider(
                    "检测到其他 Emulator 使用了记录端口，未执行任何操作"
                )
            )
        case .reuseOwnedRuntime:
            guard observation.deviceOwned else {
                ready = false
                try await ensureRuntimeStartup()
                return
            }
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
            if try await isHealthy(
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
        try await ensureRuntimeStartup()
    }

    private func ensureRuntimeStartup(
        forceInstall: Bool = false,
        retryKnownFailedNetworkCommand: Bool = true
    ) async throws {
        try await Self.startupSingleFlight.ensureRuntime { [self] in
            try await prepareRuntime(
                forceInstall: forceInstall,
                retryKnownFailedNetworkCommand:
                    retryKnownFailedNetworkCommand
            )
        }
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
        adbWaitTimeline = []
        lastADBReconnectDiagnostic = nil
        lastADBTransportSummary = nil
        gpuFallbackAttempted = false
        gpuFallbackResult = nil
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
                if var recorded = loadIdentity() {
                    guard let recordedToolchain = resolver().toolchain(
                        at: recorded.sdkRoot
                    ) else {
                        throw AppError.spider(
                            "原 Android SDK 已不可用，无法安全复用运行实例"
                        )
                    }
                    try ensureADBServer(recordedToolchain)
                    if try await retireLegacyADBServerRuntimeIfNeeded(
                        recorded,
                        toolchain: recordedToolchain
                    ) {
                        clearRuntimeRecord()
                    } else {
                        let observation = observeRuntimeOwnership(
                            recorded,
                            toolchain: recordedToolchain
                        )
                        switch observation.decision {
                        case .reuseOwnedRuntime:
                            recorded = refreshedIdentityForCurrentSession(
                                recorded,
                                toolchain: recordedToolchain
                            )
                            if requiresADBAuthenticationCompatibilityRelaunch(
                                recorded,
                                toolchain: recordedToolchain
                            ) {
                                appendEvent(
                                    stage: .locatingSDK,
                                    event: "legacyADBAuthCompatibilityRelaunch",
                                    detail: "owned Emulator lacks -skip-adb-auth"
                                )
                                guard await cleanupFailedRuntime(
                                    recorded,
                                    toolchain: recordedToolchain,
                                    reason: "legacyADBAuthCompatibilityUpgrade",
                                    allowVerifiedSIGKILL: true
                                ) else {
                                    throw AppError.spider(
                                        "无法安全重启旧版 Android 兼容环境；未启动第二个实例"
                                    )
                                }
                            } else {
                                try saveIdentity(recorded)
                                let recordedState = adbTargetState(
                                    recorded,
                                    toolchain: recordedToolchain
                                )
                                lastOwnershipClassification = Self
                                    .ownershipClassification(
                                        isCurrentAppLaunch:
                                            recorded.launchOrigin == .currentLaunch,
                                        targetState: recordedState,
                                        deviceOwned: observation.deviceOwned,
                                        processAge: Date().timeIntervalSince(
                                            recorded.launchedAt
                                        )
                                    )
                                activeIdentity = recorded
                                activeToolchain = recordedToolchain
                            }
                        case let .clearStaleRecord(reason):
                            appendStaleRecordRecovery(reason)
                            if reason == .previousSystemBoot {
                                operationStatus = .starting(
                                    "检测到电脑重启后的旧运行记录，正在重新连接。",
                                    progress: AndroidRuntimeStartupStage
                                        .locatingSDK.progress ?? 0
                                )
                                await Task.yield()
                            }
                            clearRuntimeRecord()
                        case .rejectConflictingRuntime:
                            throw AppError.spider(
                                "检测到其他 Emulator 使用了记录端口，未执行任何操作"
                            )
                        }
                    }
                } else {
                    // A corrupt/legacy-incompatible record is only stale after
                    // real process discovery proves there is no private AVD
                    // instance. If one is alive, recover from process truth.
                    guard let resolved = resolver().resolve() else {
                        throw AppError.spider(
                            "Android 运行记录损坏且无法解析原 Android SDK"
                        )
                    }
                    try ensureADBServer(resolved)
                    lastObservedToolchain = resolved
                    if let discovered = try discoverExistingManagedRuntime(
                        toolchain: resolved
                    ) {
                        activeIdentity = discovered
                        activeToolchain = resolved
                    } else {
                        lastOwnershipClassification = .staleRuntimeMetadata
                        appendEvent(
                            stage: .locatingSDK,
                            event: "invalid_runtime_metadata_cleared",
                            detail: "真实进程扫描确认专用 AVD 未运行"
                        )
                        clearRuntimeRecord()
                    }
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
                // The Emulator connects to the adb server during its own
                // startup. Establish the selected-SDK server first so a newly
                // spawned guest cannot miss its initial transport handshake.
                try ensureADBServer(toolchain)
                transition(to: .preparingAVD)
                if let discovered = try discoverExistingManagedRuntime(
                    toolchain: toolchain
                ) {
                    identity = discovered
                    activeIdentity = discovered
                    activeToolchain = toolchain
                } else {
                    appendEvent(
                        stage: .preparingAVD,
                        event: "prepareAVDStart"
                    )
                    try ensureManagedAVD(
                        toolchain,
                        gpuBackend: preferredGPUBackend
                    )
                    appendEvent(
                        stage: .preparingAVD,
                        event: "prepareAVDEnd"
                    )
                    try clearStalePrivateAVDLocksIfSafe(toolchain: toolchain)
                    transition(to: .launchingEmulator)
                    identity = try await launchManagedEmulator(
                        toolchain,
                        gpuBackend: preferredGPUBackend
                    )
                    activeIdentity = identity
                    activeToolchain = toolchain
                }
            }
            lastObservedIdentity = identity
            lastObservedToolchain = toolchain

            transition(to: .waitingForADB)
            do {
                try await waitForOwnership(identity, toolchain: toolchain)
            } catch let failure as AndroidRuntimeFailureError
                where Self.shouldAttemptSoftwareGPUFallback(
                    failureCategory: failure.record.category,
                    currentBackend: identity.gpuBackend ?? preferredGPUBackend,
                    fallbackAlreadyAttempted: gpuFallbackAttempted
                ) {
                gpuFallbackAttempted = true
                appendEvent(
                    stage: .waitingForADB,
                    event: "gpuFallbackRequested",
                    detail: "host -> software"
                )
                guard softwareGPUBackendSupported(toolchain: toolchain) else {
                    gpuFallbackResult = "software_backend_unavailable"
                    throw privateAVDRecoveryRequired(
                        "Emulator 不支持 software GPU backend；未修改 userdata"
                    )
                }
                appendEvent(
                    stage: .waitingForADB,
                    event: "hostEmulatorShutdownStart",
                    detail: "pid=\(identity.pid)"
                )
                guard await cleanupFailedRuntime(
                    identity,
                    toolchain: toolchain,
                    reason: "gpuFallback",
                    allowVerifiedSIGKILL: true
                ), await waitForEmulatorPortsToRelease(identity) else {
                    gpuFallbackResult = "host_shutdown_unconfirmed"
                    throw privateAVDRecoveryRequired(
                        "host GPU Emulator 无法确认安全退出；未启动第二个实例"
                    )
                }
                appendEvent(
                    stage: .waitingForADB,
                    event: "hostEmulatorShutdownEnd",
                    detail: "ports released"
                )
                try clearStalePrivateAVDLocksIfSafe(toolchain: toolchain)
                transition(to: .preparingAVD)
                appendEvent(
                    stage: .preparingAVD,
                    event: "prepareAVDStart",
                    detail: "gpu=software"
                )
                try ensureManagedAVD(toolchain, gpuBackend: .software)
                appendEvent(
                    stage: .preparingAVD,
                    event: "prepareAVDEnd",
                    detail: "gpu=software"
                )
                transition(to: .launchingEmulator)
                appendEvent(
                    stage: .launchingEmulator,
                    event: "softwareEmulatorLaunchStart",
                    detail: "single bounded fallback"
                )
                identity = try await launchManagedEmulator(
                    toolchain,
                    gpuBackend: .software
                )
                activeIdentity = identity
                lastObservedIdentity = identity
                transition(to: .waitingForADB)
                do {
                    try await waitForOwnership(
                        identity,
                        toolchain: toolchain
                    )
                    gpuFallbackResult = "software_transport_ready"
                } catch let softwareFailure as AndroidRuntimeFailureError
                    where Self.softwareFallbackRequiresAVDRecovery(
                        failureCategory: softwareFailure.record.category
                    ) {
                    gpuFallbackResult = softwareFailure.record.category.rawValue
                    appendEvent(
                        stage: .waitingForADB,
                        event: "softwareGPUFallbackFailed",
                        detail: softwareFailure.record.category.rawValue
                    )
                    throw privateAVDRecoveryRequired(
                        "host 与 software GPU 均无法建立 ADB transport；未删除 userdata"
                    )
                }
            }
            transition(to: .waitingForAndroidBoot)
            try await waitForBoot(identity, toolchain: toolchain)
            try recordSuccessfulGPUBackend(
                identity.gpuBackend ?? preferredGPUBackend
            )
            try Task.checkCancellation()
            try configureManagedDisplay(
                identity,
                toolchain: toolchain
            )

            if forceInstall {
                identity.generation = UUID().uuidString
                try saveIdentity(identity)
                activeIdentity = identity
            }

            transition(to: .configuringPortForward)
            let packageContinuityBeforeInstall = installedBridgeContinuity(
                identity,
                toolchain: toolchain
            )
            let installedVersionCode = installedBridgeVersionCode(
                identity,
                toolchain: toolchain
            )
            let deploymentAction = Self.bridgeDeploymentAction(
                installedVersionCode: installedVersionCode
            )
            let hasNewerBridge: Bool
            if case .activateInstalledNewer = deploymentAction {
                hasNewerBridge = true
            } else {
                hasNewerBridge = false
            }
            let requiresBundledInstall: Bool
            if hasNewerBridge {
                requiresBundledInstall = false
            } else if installedVersionCode == Self.bridgeVersionCode {
                let bundledAPK = try bridgeAPK()
                requiresBundledInstall = Self.bridgeInstallRequired(
                    installedVersionCode: installedVersionCode,
                    installedSHA256: installedBridgeAPKSHA256(
                        identity,
                        toolchain: toolchain
                    ),
                    bundledSHA256: Self.sha256Hex(bundledAPK)
                )
            } else {
                requiresBundledInstall = true
            }
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
            if case let .activateInstalledNewer(versionCode) = deploymentAction {
                // A newer signed Bridge can remain in the managed emulator
                // after the user tests a later OKVideoMac build. Android will
                // reject an install -r downgrade, and uninstalling here would
                // erase the user's cloud-drive login data. Start and validate
                // the newer compatible Bridge instead.
                transition(to: .launchingBridge)
                try startBridge(identity, toolchain: toolchain)
                transition(to: .probingBridge)
                for attempt in 0..<AndroidRuntimeRecoveryPolicy
                    .initialBridgeProbeAttempts {
                    try Task.checkCancellation()
                    probeRetryCount = attempt + 1
                    if try await isHealthy(
                        identity,
                        toolchain: toolchain,
                        acceptVersionMismatch: true
                    ) {
                        ready = true
                        acceptsNewerBridge = true
                        lastNetworkCheck = Date()
                        lastFailure = nil
                        lastSuccessfulStartAt = Date()
                        try await verifyAndRecordBridgeContinuity()
                        transition(to: .ready, event: "newer_bridge_ready")
                        return
                    }
                    try await Task.sleep(
                        nanoseconds: AndroidRuntimeRecoveryPolicy
                            .bridgeProbePollNanoseconds
                    )
                }
                throw AppError.spider(
                    "检测到较新的 Android Bridge（构建 \(versionCode)），"
                        + "但启动验证失败；为保留网盘登录数据，未执行降级或卸载"
                )
            }
            if !forceInstall, !networkWasRepaired,
               !requiresBundledInstall,
               try await isHealthy(
                    identity,
                    toolchain: toolchain,
                    acceptVersionMismatch: hasNewerBridge
               ) {
                dismissDeprecatedTargetSDKWarningIfNeeded(
                    identity,
                    toolchain: toolchain
                )
                ready = true
                acceptsNewerBridge = hasNewerBridge
                lastNetworkCheck = Date()
                lastFailure = nil
                lastSuccessfulStartAt = Date()
                try await verifyAndRecordBridgeContinuity()
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
            if let before = packageContinuityBeforeInstall {
                guard let after = installedBridgeContinuity(
                    identity,
                    toolchain: toolchain
                ), Self.installPreservesPackageContinuity(
                    before: before,
                    after: after
                ) else {
                    throw AppError.spider(
                        "Bridge 升级改变了 Android 应用身份；为保护网盘授权，启动已中止"
                    )
                }
            }
            if let bundledSHA256 = Self.sha256Hex(apk),
               let installedSHA256 = installedBridgeAPKSHA256(
                    identity,
                    toolchain: toolchain
               ),
               bundledSHA256 != installedSHA256 {
                throw AppError.spider(
                    "Android Bridge 安装后内容校验失败；已拒绝启动旧 Bridge"
                )
            }
            transition(to: .launchingBridge)
            try startBridge(identity, toolchain: toolchain)
            transition(to: .probingBridge)
            for attempt in 0..<AndroidRuntimeRecoveryPolicy
                .initialBridgeProbeAttempts {
                try Task.checkCancellation()
                probeRetryCount = attempt + 1
                if try await isHealthy(identity, toolchain: toolchain) {
                    ready = true
                    acceptsNewerBridge = false
                    lastNetworkCheck = Date()
                    lastFailure = nil
                    lastSuccessfulStartAt = Date()
                    try await verifyAndRecordBridgeContinuity()
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
                if try await isHealthy(identity, toolchain: toolchain) {
                    ready = true
                    acceptsNewerBridge = false
                    lastNetworkCheck = Date()
                    lastFailure = nil
                    lastSuccessfulStartAt = Date()
                    try await verifyAndRecordBridgeContinuity()
                    transition(to: .ready, event: "bridge_recovered")
                    return
                }
                try await Task.sleep(
                    nanoseconds: AndroidRuntimeRecoveryPolicy
                        .bridgeProbePollNanoseconds
                )
            }
            throw AppError.spider(
                Self.terminalBridgeProbeMessage(for: probeErrorCategory)
            )
        } catch {
            ready = false
            let failure: AndroidRuntimeFailureError
            if error is CancellationError {
                if let identity = activeIdentity {
                    recordEmulatorTerminationRequest(
                        pid: identity.pid,
                        reason: "startupCancelled"
                    )
                }
                failure = AndroidRuntimeFailureError(
                    record: AndroidRuntimeFailureRecord(
                        occurredAt: Date(),
                        stage: currentStage,
                        category: .appRequestedTermination,
                        message: "Android Emulator 启动已由 App 取消"
                    )
                )
            } else {
                failure = classifiedFailure(for: error)
            }
            preserveFailure(failure)
            if Task.isCancelled {
                appendEvent(
                    stage: failure.record.stage,
                    event: "startup_cleanup_deferred_to_shutdown",
                    detail: "共享 startup 已由停止流程取消"
                )
            } else if let identity = activeIdentity,
               let toolchain = activeToolchain {
                let cleaned = await cleanupFailedRuntime(
                    identity,
                    toolchain: toolchain
                )
                if cleaned {
                    stopPrivateADBServerIfOwned(toolchain: toolchain)
                }
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
            try validateManagedRuntime(
                identity,
                toolchain: toolchain,
                deviceRequired: true
            )
            if let value = try? runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["shell", "getprop", "sys.boot_completed"],
                category: "adb.boot.sys_boot_completed"
            ), value.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                lastBootCompleted = true
                lastBootWaitDuration = Date().timeIntervalSince(startedAt)
                appendEvent(
                    stage: .waitingForAndroidBoot,
                    event: "sysBootCompletedFirstObserved",
                    detail: String(
                        format: "elapsed=%.3f",
                        lastBootWaitDuration ?? 0
                    )
                )
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        lastBootCompleted = false
        lastBootWaitDuration = Date().timeIntervalSince(startedAt)
        throw AppError.spider("Java/Dex Android 运行时启动超过 240 秒")
    }

    private func configureManagedDisplay(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) throws {
        let currentSize = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "wm", "size"],
            category: "adb.display.size.verify",
            timeout: 10
        )
        let currentDensity = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "wm", "density"],
            category: "adb.display.density.verify",
            timeout: 10
        )
        let currentFontScale = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "settings", "get", "system", "font_scale"],
            category: "adb.display.font_scale.verify",
            timeout: 10
        )
        if Self.managedDisplayProfileMatches(
            sizeOutput: currentSize,
            densityOutput: currentDensity,
            fontScaleOutput: currentFontScale
        ) {
            managedDisplayConfigured = true
            return
        }

        _ = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "wm", "size",
                "\(AndroidManagedDisplayProfile.pixelWidth)x"
                    + "\(AndroidManagedDisplayProfile.pixelHeight)"
            ],
            category: "adb.display.size.configure",
            timeout: 10
        )
        _ = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "wm", "density",
                "\(AndroidManagedDisplayProfile.densityDPI)"
            ],
            category: "adb.display.density.configure",
            timeout: 10
        )
        _ = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "settings", "put", "system", "font_scale",
                "\(AndroidManagedDisplayProfile.fontScale)"
            ],
            category: "adb.display.font_scale.configure",
            timeout: 10
        )
        let size = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "wm", "size"],
            category: "adb.display.size.verify",
            timeout: 10
        )
        let density = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "wm", "density"],
            category: "adb.display.density.verify",
            timeout: 10
        )
        let fontScale = try runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "settings", "get", "system", "font_scale"],
            category: "adb.display.font_scale.verify",
            timeout: 10
        )
        guard Self.managedDisplayProfileMatches(
            sizeOutput: size,
            densityOutput: density,
            fontScaleOutput: fontScale
        ) else {
            throw AppError.spider("Android 原生界面显示尺寸配置失败")
        }
        managedDisplayConfigured = true
    }

    static func managedDisplayProfileMatches(
        sizeOutput: String,
        densityOutput: String,
        fontScaleOutput: String
    ) -> Bool {
        let expectedSize =
            "\(AndroidManagedDisplayProfile.pixelWidth)x"
                + "\(AndroidManagedDisplayProfile.pixelHeight)"
        guard effectiveADBDisplayValue(in: sizeOutput) == expectedSize,
              effectiveADBDisplayValue(in: densityOutput)
                == "\(AndroidManagedDisplayProfile.densityDPI)",
              let scale = Double(
                fontScaleOutput.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ) else {
            return false
        }
        return abs(scale - AndroidManagedDisplayProfile.fontScale) < 0.001
    }

    private static func effectiveADBDisplayValue(in output: String) -> String? {
        var physicalValue: String?
        var overrideValue: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let components = line.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: true
            )
            guard components.count == 2 else { continue }
            let label = components[0].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let value = components[1].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            switch label {
            case "Override size", "Override density":
                overrideValue = value
            case "Physical size", "Physical density":
                physicalValue = value
            default:
                continue
            }
        }
        return overrideValue ?? physicalValue
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

    private func installedBridgeContinuity(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> AndroidInstalledPackageContinuity? {
        guard let output = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "dumpsys", "package", Self.bridgeApplicationID],
            category: "adb.bridge.package_continuity",
            timeout: 10
        ) else { return nil }
        return Self.installedPackageContinuity(from: output)
    }

    static func installedPackageContinuity(
        from packageDump: String
    ) -> AndroidInstalledPackageContinuity? {
        func value(after marker: String) -> String? {
            packageDump.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.hasPrefix(marker) })
                .map { String($0.dropFirst(marker.count)) }
        }
        guard let firstInstallTime = value(after: "firstInstallTime="),
              let userID = value(after: "userId=").flatMap(Int.init),
              let dataDirectory = value(after: "dataDir="),
              dataDirectory.hasPrefix("/data/") else { return nil }
        return AndroidInstalledPackageContinuity(
            firstInstallTime: firstInstallTime,
            userID: userID,
            dataDirectory: dataDirectory
        )
    }

    static func installPreservesPackageContinuity(
        before: AndroidInstalledPackageContinuity,
        after: AndroidInstalledPackageContinuity
    ) -> Bool {
        before == after
    }

    static func installedVersionCode(from packageDump: String) -> Int? {
        // Android can retain the package's settings and data directory after
        // its code path has disappeared. dumpsys still exposes versionCode in
        // that state, but marks the parsed package as `pkg=null`; treating it
        // as a newer usable Bridge skips the data-preserving `adb install -r`
        // repair and makes am start fail with Error type 3.
        let hasMissingParsedPackage = packageDump
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("pkg=null")
        guard !hasMissingParsedPackage else { return nil }
        guard let marker = packageDump.range(of: "versionCode=") else {
            return nil
        }
        let suffix = packageDump[marker.upperBound...]
        let digits = suffix.prefix(while: \.isNumber)
        return Int(digits)
    }

    static func bridgeDeploymentAction(
        installedVersionCode: Int?
    ) -> AndroidBridgeDeploymentAction {
        guard let installedVersionCode,
              installedVersionCode > bridgeVersionCode else {
            return .installBundled
        }
        return .activateInstalledNewer(versionCode: installedVersionCode)
    }

    /// Version equality alone is not enough: local Release builds can embed a
    /// rebuilt APK before its Gradle version is bumped. In that case Android
    /// reports a healthy, same-version package while macOS is still speaking
    /// to the old Bridge protocol. Compare the installed base APK with the
    /// bundled APK and reinstall in place when their content differs. A newer
    /// installed build remains protected from downgrade so cloud credentials
    /// stored in the managed emulator are never erased.
    static func bridgeInstallRequired(
        installedVersionCode: Int?,
        installedSHA256: String?,
        bundledSHA256: String?
    ) -> Bool {
        guard let installedVersionCode else { return true }
        if installedVersionCode > bridgeVersionCode { return false }
        if installedVersionCode < bridgeVersionCode { return true }
        guard let installedSHA256 = normalizedSHA256(installedSHA256),
              let bundledSHA256 = normalizedSHA256(bundledSHA256) else {
            // For an equal-version package, inability to prove byte identity
            // must not silently retain an unknown Bridge implementation.
            return true
        }
        return installedSHA256 != bundledSHA256
    }

    static func installedAPKPath(from packageManagerOutput: String) -> String? {
        let paths = packageManagerOutput.split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                let line = String(rawLine).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard line.hasPrefix("package:") else { return nil }
                let path = String(line.dropFirst("package:".count))
                let allowed = CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "/._~=-")
                )
                guard path.hasPrefix("/data/app/"),
                      path.hasSuffix("/base.apk"),
                      path.unicodeScalars.allSatisfy(allowed.contains) else {
                    return nil
                }
                return path
            }
        return paths.count == 1 ? paths[0] : nil
    }

    static func sha256FromCommandOutput(_ output: String) -> String? {
        let candidate = output.split(whereSeparator: \.isWhitespace)
            .first.map(String.init)
        return normalizedSHA256(candidate)
    }

    private static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(hexadecimal.contains)
        else {
            return nil
        }
        return normalized
    }

    private func installedBridgeAPKSHA256(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> String? {
        guard let packageOutput = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "pm", "path", "com.okvideomac.dexbridge"],
            category: "adb.bridge.apk.path"
        ),
        let path = Self.installedAPKPath(from: packageOutput),
        let digestOutput = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            ["shell", "sha256sum", path],
            category: "adb.bridge.apk.sha256"
        ) else {
            return nil
        }
        return Self.sha256FromCommandOutput(digestOutput)
    }

    private func isHealthy(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        acceptVersionMismatch: Bool = false
    ) async throws -> Bool {
        if probeStartedAt == nil {
            probeStartedAt = Date()
        }
        try validateManagedRuntime(
            identity,
            toolchain: toolchain,
            deviceRequired: true
        )
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
            let validation = Self.healthValidation(
                object,
                generation: identity.generation,
                acceptVersionMismatch: acceptVersionMismatch
            )
            probeErrorCategory = validation == .healthy
                ? nil : validation.rawValue
            return validation == .healthy
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

    private func verifyAndRecordBridgeContinuity() async throws {
        guard let record = loadContinuityRecord() else { return }
        guard let url = URL(
            string: "http://127.0.0.1:\(BridgeServerPort.host)/v1/runtime/continuity"
        ) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(
            configuration: configuration
        ).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let report = try? JSONDecoder().decode(
                  AndroidBridgeRuntimeContinuityReport.self,
                  from: data
              ),
              report.ok,
              report.runtimeSchemaVersion == 1,
              report.applicationId == Self.bridgeApplicationID else {
            throw AppError.spider("迁移后的 Bridge 无法提供授权连续性证明")
        }
        if let previous = record.firstInstallTime,
           previous != report.firstInstallTime {
            throw AppError.spider("Bridge firstInstallTime 已变化；为保护网盘授权，启动已中止")
        }
        if let previous = record.androidUID, previous != report.uid {
            throw AppError.spider("Bridge Android UID 已变化；为保护网盘授权，启动已中止")
        }
        if let previous = record.dataDirectoryFingerprint,
           previous != report.dataDirectoryFingerprint {
            throw AppError.spider("Bridge 数据目录身份已变化；为保护网盘授权，启动已中止")
        }
        let updated = AndroidRuntimeContinuityRecord(
            schema: record.schema,
            runtimeSchema: record.runtimeSchema,
            avdName: record.avdName,
            applicationID: record.applicationID,
            bridgeCertificateSHA256: record.bridgeCertificateSHA256,
            bridgeVersionCode: report.versionCode,
            sourceFingerprint: record.sourceFingerprint,
            destinationFingerprint: record.destinationFingerprint,
            backupDirectoryName: record.backupDirectoryName,
            migratedAt: record.migratedAt,
            firstInstallTime: report.firstInstallTime,
            androidUID: report.uid,
            dataDirectoryFingerprint: report.dataDirectoryFingerprint,
            authorizationStorageFingerprint:
                report.authorizationStorageFingerprint
        )
        try saveContinuityRecord(updated)
    }

    static func healthMatches(
        _ object: [String: Any],
        generation: String,
        acceptVersionMismatch: Bool = false
    ) -> Bool {
        healthValidation(
            object,
            generation: generation,
            acceptVersionMismatch: acceptVersionMismatch
        ) == .healthy
    }

    static func healthValidation(
        _ object: [String: Any],
        generation: String,
        acceptVersionMismatch: Bool = false
    ) -> AndroidBridgeHealthValidation {
        guard object["ok"] as? Bool == true else {
            return .serviceNotReady
        }
        guard let actualGeneration = object["generation"] as? String else {
            return .generationMissing
        }
        guard actualGeneration == generation else {
            return .generationMismatch
        }
        guard let actualVersion = object["version"] as? String else {
            return .versionMissing
        }
        guard actualVersion == bridgeVersion || acceptVersionMismatch else {
            return .versionMismatch
        }
        return .healthy
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

    static func consolePort(
        in command: String,
        candidates: [Int] = candidateConsolePorts
    ) -> Int? {
        let fields = command.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        for index in fields.indices {
            if fields[index] == "-port", fields.indices.contains(index + 1),
               let port = Int(fields[index + 1]), candidates.contains(port) {
                return port
            }
            if fields[index] == "-ports", fields.indices.contains(index + 1),
               let first = fields[index + 1].split(separator: ",").first,
               let port = Int(first), candidates.contains(port) {
                return port
            }
        }
        return nil
    }

    static func ownershipClassification(
        isCurrentAppLaunch: Bool,
        targetState: AndroidADBTargetState,
        deviceOwned: Bool,
        processAge: TimeInterval
    ) -> AndroidRuntimeOwnershipClassification {
        if isCurrentAppLaunch {
            return .ownedCurrentLaunch
        }
        if targetState == .device, deviceOwned {
            return .ownedExistingHealthy
        }
        if targetState == .offline || targetState == .unauthorized {
            return .ownedExistingOffline
        }
        if targetState == .missing, processAge < 120 {
            return .ownedExistingBooting
        }
        return .ownedExistingADBMissing
    }

    static func discoveryAction(
        matchingAVDProcessCount: Int,
        strictlyOwnedCandidateCount: Int
    ) -> AndroidRuntimeDiscoveryAction {
        if matchingAVDProcessCount == 0 { return .launch }
        if matchingAVDProcessCount == 1,
           strictlyOwnedCandidateCount == 1 { return .adopt }
        return .rejectExternalConflict
    }

    static func shutdownAction(
        deviceOwned: Bool,
        processStrictlyOwned: Bool,
        adbAttempted: Bool,
        sigtermAttempted: Bool
    ) -> AndroidRuntimeShutdownAction {
        if deviceOwned, !adbAttempted {
            return .adbEmuKill
        }
        guard processStrictlyOwned else { return .refuse }
        return sigtermAttempted ? .sigkill : .sigterm
    }

    static func mayClearStaleAVDLocks(
        hasManagedAVDProcess: Bool,
        hasLiveRecordedProcess: Bool,
        managedPortsOwned: Bool
    ) -> Bool {
        !hasManagedAVDProcess && !hasLiveRecordedProcess && !managedPortsOwned
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

    static func isEmulatorAVDConflict(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("running multiple emulators with the same avd")
            || text.contains("another emulator instance is running")
            || text.contains("avd is already running")
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
            fileManager: fileManager,
            selectionMode: runtimeSelectionMode
        )
    }

    private func createRuntimeDirectories() throws {
        for directory in [
            runtimeDirectory,
            avdHome,
            privateADBKeyPaths.privateHome,
            privateADBKeyPaths.emulatorHome
        ] {
            try AndroidPrivateADBKeyManager.ensureOwnedDirectory(
                directory,
                fileManager: fileManager
            )
        }
    }

    private static func allocatedDirectorySize(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ])
            guard values.isRegularFile == true else { continue }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? 0
            )
        }
        return total
    }

    private func runtimeProcessReferencesAVD(named name: String) -> Bool {
        guard let output = try? run(
            URL(fileURLWithPath: "/bin/ps"),
            ["-axo", "command="],
            category: "continuity.process_check",
            timeout: 5
        ) else { return true }
        return output.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            return command.contains("-avd \(name)")
                || command.contains("/\(name).avd")
                || command.contains("@\(name)")
        }
    }

    private func managedRuntimeProcessCandidates(
        toolchain: AndroidToolchain
    ) throws -> [AndroidManagedRuntimeProcessCandidate] {
        let output = try run(
            URL(fileURLWithPath: "/bin/ps"),
            ["-axo", "pid=,command="],
            category: "runtime.discovery.processes",
            timeout: 5
        )
        let expectedExecutable = toolchain.emulator.standardizedFileURL
            .resolvingSymlinksInPath()
        let emulatorRoot = toolchain.sdkRoot
            .appendingPathComponent("emulator", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.drop(while: { $0.isWhitespace })
            guard let separator = line.firstIndex(where: { $0.isWhitespace }),
                  let pid = Int32(line[..<separator]) else { return nil }
            let command = String(
                line[separator...].drop(while: { $0.isWhitespace })
            )
            guard command.contains("-avd \(Self.avdName)")
                    || command.contains("@\(Self.avdName)")
                    || command.contains("/\(Self.avdName).avd"),
                  let consolePort = Self.consolePort(in: command),
                  let executablePath = processExecutablePath(pid: pid),
                  let processIdentity = processBirthIdentity(pid: pid)
            else { return nil }
            let executable = URL(fileURLWithPath: executablePath)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard executable == expectedExecutable
                    || executable.path.hasPrefix(emulatorRoot) else {
                return nil
            }
            return AndroidManagedRuntimeProcessCandidate(
                pid: pid,
                executable: executable,
                command: command,
                consolePort: consolePort,
                gpuBackend: Self.gpuBackend(in: command),
                adbAuthenticationMode: Self
                    .emulatorADBAuthenticationMode(in: command),
                birthIdentity: processIdentity.value,
                startedAt: processIdentity.startedAt,
                referencesPrivateAVD: processReferencesPrivateAVD(pid: pid)
            )
        }
    }

    private func discoverExistingManagedRuntime(
        toolchain: AndroidToolchain
    ) throws -> AndroidRuntimeIdentity? {
        let allMatchingAVDProcesses = try matchingAVDProcessCount()
        let candidates = try managedRuntimeProcessCandidates(
            toolchain: toolchain
        )
        let privateCandidates = candidates.filter(\.referencesPrivateAVD)
        switch Self.discoveryAction(
            matchingAVDProcessCount: allMatchingAVDProcesses,
            strictlyOwnedCandidateCount: privateCandidates.count
        ) {
        case .launch:
            return nil
        case .rejectExternalConflict:
            lastOwnershipClassification = .externalRuntimeConflict
            lastLifecycleConflictReason =
                "同名 AVD 进程未同时通过 executable、argv、port 与私有 AVD 文件校验"
            throw AndroidRuntimeFailureError(
                record: AndroidRuntimeFailureRecord(
                    occurredAt: Date(),
                    stage: .launchingEmulator,
                    category: .emulatorRuntimeConflict,
                    message: "检测到无法安全接管的同名 Android Emulator，未执行启动或终止"
                )
            )
        case .adopt:
            break
        }
        guard let candidate = privateCandidates.first else { return nil }

        let identity = AndroidRuntimeIdentity(
            schema: Self.manifestSchema,
            generation: UUID().uuidString,
            systemBootIdentifier: currentBootIdentifier,
            sdkRoot: toolchain.sdkRoot,
            emulatorExecutable: toolchain.emulator,
            adbExecutable: toolchain.adb,
            adbServerPort: privateADBServerPort,
            gpuBackend: candidate.gpuBackend ?? preferredGPUBackend,
            adbAuthenticationMode: candidate.adbAuthenticationMode,
            avdName: Self.avdName,
            avdDirectory: avdDirectory,
            pid: candidate.pid,
            pidBirthIdentity: candidate.birthIdentity,
            consolePort: candidate.consolePort,
            serial: Self.emulatorSerial(consolePort: candidate.consolePort),
            forwards: Self.expectedForwards,
            launchedAt: candidate.startedAt,
            appSessionID: Self.appSessionID,
            runtimeSessionID: UUID().uuidString,
            launchOrigin: .adoptedExisting,
            terminationRequestedAt: nil,
            terminationRequestReason: nil
        )
        let state = adbTargetState(identity, toolchain: toolchain)
        let deviceOwned = state == .device
            && verifyDeviceOwnership(identity, toolchain: toolchain)
        lastOwnershipClassification = Self.ownershipClassification(
            isCurrentAppLaunch: false,
            targetState: state,
            deviceOwned: deviceOwned,
            processAge: Date().timeIntervalSince(candidate.startedAt)
        )
        lastLifecycleConflictReason = nil
        appendEvent(
            stage: currentStage,
            event: "existing_runtime_adopted",
            detail: "pid=\(candidate.pid) serial=\(identity.serial) state=\(state.rawValue)"
        )
        try saveIdentity(identity)
        return identity
    }

    private func matchingAVDProcessCount() throws -> Int {
        let output = try run(
            URL(fileURLWithPath: "/bin/ps"),
            ["-axo", "command="],
            category: "runtime.discovery.avd_process_count",
            timeout: 5
        )
        return output.split(whereSeparator: \.isNewline).filter { line in
            let command = String(line)
            return command.contains("-avd \(Self.avdName)")
                || command.contains("@\(Self.avdName)")
                || command.contains("/\(Self.avdName).avd")
        }.count
    }

    private func processReferencesPrivateAVD(pid: Int32) -> Bool {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else {
            return false
        }
        let output: String
        do {
            output = try run(
                lsof,
                ["-a", "-p", "\(pid)", "-Fn"],
                category: "runtime.discovery.private_avd_files",
                timeout: 5
            )
        } catch {
            return false
        }
        let prefix = avdDirectory.standardizedFileURL
            .resolvingSymlinksInPath().path + "/"
        return output.split(whereSeparator: \.isNewline).contains { rawLine in
            guard rawLine.first == "n" else { return false }
            let path = String(rawLine.dropFirst())
            return path == avdDirectory.path || path.hasPrefix(prefix)
        }
    }

    private func processBirthIdentity(
        pid: Int32
    ) -> (value: String, startedAt: Date)? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout.size(ofValue: info))
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize,
              info.pbi_start_tvsec > 0 else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return (
            "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",
            Date(timeIntervalSince1970: seconds)
        )
    }

    private func adbTargetState(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> AndroidADBTargetState {
        guard let listing = try? runADB(
            toolchain,
            ["devices", "-l"],
            category: "runtime.discovery.adb_devices",
            timeout: 5
        ) else { return .unknown }
        return Self.adbTargetState(in: listing, serial: identity.serial)
    }

    private func clearStalePrivateAVDLocksIfSafe(
        toolchain: AndroidToolchain,
        updateOwnershipClassification: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: avdDirectory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: avdDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let locks = entries.filter {
            $0.lastPathComponent.lowercased().contains("lock")
        }
        guard !locks.isEmpty else { return }

        let managedProcessCount = try matchingAVDProcessCount()
        let recorded = loadIdentity()
        let recordedProcessLive = recorded.map {
            verifyProcessOwnership($0, toolchain: toolchain)
        } ?? false
        let managedPortsOwned = !(try managedRuntimeProcessCandidates(
            toolchain: toolchain
        )).isEmpty
        guard Self.mayClearStaleAVDLocks(
            hasManagedAVDProcess: managedProcessCount > 0,
            hasLiveRecordedProcess: recordedProcessLive,
            managedPortsOwned: managedPortsOwned
        ) else {
            return
        }

        var cleared: [String] = []
        for lock in locks {
            let normalized = lock.standardizedFileURL
            guard normalized.deletingLastPathComponent()
                    == avdDirectory.standardizedFileURL else { continue }
            try fileManager.removeItem(at: normalized)
            cleared.append(normalized.lastPathComponent)
        }
        guard !cleared.isEmpty else { return }
        lastStaleAVDLocksCleared = cleared.sorted()
        if updateOwnershipClassification {
            lastOwnershipClassification = .staleAVDLock
        }
        appendEvent(
            stage: currentStage,
            event: "stale_avd_locks_cleared",
            detail: cleared.sorted().joined(separator: ",")
        )
    }

    private func loadContinuityRecord() -> AndroidRuntimeContinuityRecord? {
        guard let data = try? Data(contentsOf: continuityURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(
            AndroidRuntimeContinuityRecord.self,
            from: data
        ) else { return nil }
        return record
    }

    private func saveContinuityRecord(
        _ record: AndroidRuntimeContinuityRecord
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: continuityURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: continuityURL.path
        )
    }

    private func saveRuntimeProfile() throws {
        try createRuntimeDirectories()
        let profile = AndroidRuntimeProfile(
            schema: AndroidRuntimeProfile.schema,
            privateADBServerPort: privateADBServerPort,
            preferredGPUBackend: preferredGPUBackend,
            privateADBServerPID: persistedADBServerPID,
            privateADBServerBirthIdentity:
                persistedADBServerBirthIdentity,
            privateADBPublicKeySHA256: lastPrivateADBKeyStatus?
                .publicKeySHA256
                    ?? AndroidPrivateADBKeyManager.status(
                        paths: privateADBKeyPaths,
                        fileManager: fileManager
                    ).publicKeySHA256,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        try data.write(to: runtimeProfileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: runtimeProfileURL.path
        )
    }

    private func recordSuccessfulGPUBackend(
        _ backend: AndroidEmulatorGPUBackend
    ) throws {
        preferredGPUBackend = backend
        try saveRuntimeProfile()
        appendEvent(
            stage: currentStage,
            event: "gpuBackendPersisted",
            detail: backend.rawValue
        )
    }

    static func supportedGPUBackends(from help: String) -> Set<String> {
        Set(help.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { return nil }
            let value = String(first)
            return ["host", "software", "swiftshader", "swangle"]
                .contains(value) ? value : nil
        })
    }

    static func persistedRuntimeProfile(
        from data: Data
    ) -> (
        privateADBServerPort: Int,
        preferredGPUBackend: AndroidEmulatorGPUBackend,
        privateADBServerPID: Int32?,
        privateADBServerBirthIdentity: String?,
        privateADBPublicKeySHA256: String?
    )? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(
            AndroidRuntimeProfile.self,
            from: data
        ), profile.schema == AndroidRuntimeProfile.schema else { return nil }
        return (
            profile.privateADBServerPort,
            profile.preferredGPUBackend,
            profile.privateADBServerPID,
            profile.privateADBServerBirthIdentity,
            profile.privateADBPublicKeySHA256
        )
    }

    private func softwareGPUBackendSupported(
        toolchain: AndroidToolchain
    ) -> Bool {
        guard let help = try? run(
            toolchain.emulator,
            ["-help-gpu"],
            environment: childEnvironment(for: toolchain),
            category: "emulator.gpu.capabilities",
            timeout: 10
        ) else { return false }
        return Self.supportedGPUBackends(from: help).contains("software")
    }

    static func diagnosticModeEnabled(
        environment: [String: String],
        defaults: UserDefaults
    ) -> Bool {
        let value = environment[diagnosticModeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "yes", "on"].contains(value ?? "")
            || defaults.bool(forKey: diagnosticModeDefaultsKey)
    }

    static func privateRuntimeEnvironment(
        baseEnvironment: [String: String],
        sdkRoot: URL,
        avdHome: URL,
        keyPaths: AndroidPrivateADBKeyPaths,
        privateADBServerPort: Int,
        verboseDiagnostics: Bool
    ) -> [String: String] {
        var environment = baseEnvironment
        // Test hosts and developer launches can inject loader paths that must
        // never leak into SDK executables spawned by the shipped app.
        for key in environment.keys where key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        // Do not inherit Android Studio/Homebrew routing or user-home SDK
        // configuration. Every child sees one private home, AVD directory,
        // ADB server port, and ADB identity owned by OKVideoMac.
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ANDROID_SDK_HOME")
        environment["ANDROID_ADB_SERVER_PORT"] =
            "\(privateADBServerPort)"
        environment["ADB_VENDOR_KEYS"] = keyPaths.privateKey.path
        environment["ANDROID_HOME"] = sdkRoot.path
        environment["ANDROID_SDK_ROOT"] = sdkRoot.path
        environment["ANDROID_AVD_HOME"] = avdHome.path
        environment["ANDROID_EMULATOR_HOME"] = keyPaths.emulatorHome.path
        environment["ANDROID_USER_HOME"] = keyPaths.emulatorHome.path
        environment["HOME"] = keyPaths.privateHome.path
        if verboseDiagnostics {
            environment["ADB_TRACE"] = "auth,transport"
        } else {
            environment.removeValue(forKey: "ADB_TRACE")
        }
        let generationRoot = sdkRoot.deletingLastPathComponent()
        let managedJRE = generationRoot.appendingPathComponent(
            "jre",
            isDirectory: true
        )
        let managedJava = managedJRE.appendingPathComponent("bin/java")
        let usesManagedGeneration = sdkRoot.lastPathComponent == "sdk"
            && generationRoot.deletingLastPathComponent().lastPathComponent
                == "Generations"
            && FileManager.default.isExecutableFile(atPath: managedJava.path)
        if usesManagedGeneration {
            // Managed purity is a hard boundary: no Java, Android tool, or
            // loader path from Android Studio, Homebrew, a login shell, or the
            // launching process can influence a Session child.
            environment["JAVA_HOME"] = managedJRE.path
            environment["PATH"] = [
                managedJRE.appendingPathComponent("bin").path,
                sdkRoot.appendingPathComponent(
                    "cmdline-tools/latest/bin"
                ).path,
                sdkRoot.appendingPathComponent("platform-tools").path,
                sdkRoot.appendingPathComponent("emulator").path,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ].joined(separator: ":")
        } else {
            // External mode still uses a user-selected SDK, but its child
            // processes must not fall through to Homebrew or Android Studio
            // tools on the launching process PATH.
            environment.removeValue(forKey: "JAVA_HOME")
            environment["PATH"] = [
                sdkRoot.appendingPathComponent(
                    "cmdline-tools/latest/bin"
                ).path,
                sdkRoot.appendingPathComponent("platform-tools").path,
                sdkRoot.appendingPathComponent("emulator").path,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ].joined(separator: ":")
        }
        return environment
    }

    private func childEnvironment(
        for toolchain: AndroidToolchain
    ) -> [String: String] {
        Self.privateRuntimeEnvironment(
            baseEnvironment: baseEnvironment,
            sdkRoot: toolchain.sdkRoot,
            avdHome: avdHome,
            keyPaths: privateADBKeyPaths,
            privateADBServerPort: privateADBServerPort,
            verboseDiagnostics: verboseAndroidDiagnosticsEnabled
        )
    }

    static func scopedADBArguments(
        _ arguments: [String],
        serverPort: Int
    ) -> [String] {
        ["-P", "\(serverPort)"] + arguments
    }

    static func privateADBServerLaunchArguments(port: Int) -> [String] {
        ["-L", "tcp:localhost:\(port)", "server", "nodaemon"]
    }

    static func selectPrivateADBServerPort(
        preferred: Int?,
        reusable: Set<Int>,
        occupied: Set<Int>,
        candidates: [Int] = candidatePrivateADBServerPorts
    ) -> Int? {
        let ordered = ([preferred].compactMap { $0 } + candidates).reduce(
            into: [Int]()
        ) { result, port in
            if !result.contains(port) { result.append(port) }
        }
        return ordered.first { reusable.contains($0) || !occupied.contains($0) }
    }

    static func privateADBServerIdentityMatches(
        listenerPID: Int32,
        listenerBirthIdentity: String?,
        listenerExecutable: URL,
        recordedPID: Int32?,
        recordedBirthIdentity: String?,
        selectedADB: URL
    ) -> Bool {
        listenerPID == recordedPID
            && listenerBirthIdentity == recordedBirthIdentity
            && recordedBirthIdentity != nil
            && listenerExecutable.standardizedFileURL
                .resolvingSymlinksInPath()
                == selectedADB.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func privateADBServerLaunchMatches(
        expectedLaunchedPID: Int32?,
        observedListenerPID: Int32?
    ) -> Bool {
        guard let expectedLaunchedPID else { return true }
        return observedListenerPID == expectedLaunchedPID
    }

    private func runADB(
        _ toolchain: AndroidToolchain,
        _ arguments: [String],
        category: String = "adb.command",
        timeout: TimeInterval = 30
    ) throws -> String {
        try run(
            toolchain.adb,
            Self.scopedADBArguments(
                arguments,
                serverPort: privateADBServerPort
            ),
            environment: childEnvironment(for: toolchain),
            category: category,
            timeout: timeout
        )
    }

    private func diagnosticEmulatorEnvironment(
        _ environment: [String: String],
        toolchain: AndroidToolchain
    ) -> [String: String] {
        let keys = [
            "ANDROID_HOME",
            "ANDROID_SDK_ROOT",
            "ANDROID_AVD_HOME",
            "ANDROID_SDK_HOME",
            "ANDROID_EMULATOR_HOME",
            "ANDROID_USER_HOME",
            "ADB_SERVER_SOCKET",
            "ANDROID_ADB_SERVER_PORT",
            "ADB_VENDOR_KEYS",
            "ADB_TRACE",
            "PATH",
            "HOME",
            "TMPDIR"
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let raw = environment[key] ?? "<unset>"
            return (
                key,
                sanitizedEmulatorText(raw, toolchain: toolchain)
            )
        })
    }

    private func diagnosticAVDConfiguration(
        _ contents: String?,
        toolchain: AndroidToolchain?
    ) -> [String: String] {
        guard let contents else { return [:] }
        let keys = [
            "avd.ini.displayname",
            "disk.cachePartition",
            "disk.cachePartition.path",
            "disk.dataPartition.path",
            "disk.dataPartition.size",
            "fastboot.forceColdBoot",
            "fastboot.forceFastBoot",
            "hw.cpu.arch",
            "hw.gpu.enabled",
            "hw.gpu.mode",
            "hw.ramSize",
            "image.sysdir.1",
            "snapshot.present",
            "tag.id",
            "target"
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = AndroidManagedAVDConfiguration.value(
                for: key,
                in: contents
            ) else { return nil }
            return (
                key,
                sanitizedEmulatorText(value, toolchain: toolchain)
            )
        })
    }

    private func emulatorLogTail(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return nil }
        let raw = Self.diagnosticLogTail(from: data)
        guard !raw.isEmpty else { return nil }
        return sanitizedEmulatorText(raw, toolchain: lastObservedToolchain)
    }

    private func emulatorADBKeySignals(
        _ snapshot: AndroidEmulatorProcessSnapshot?
    ) -> AndroidEmulatorADBKeySignals {
        guard let snapshot else {
            return AndroidEmulatorADBKeySignals(
                reportedSendingPublicKey: false,
                reportedMissingPrivateKey: false,
                bootPropertiesContainPublicKey: false,
                reportedPublicKeySHA256: nil
            )
        }
        let text = [snapshot.stdoutURL, snapshot.stderrURL]
            .compactMap { try? Data(contentsOf: $0, options: [.mappedIfSafe]) }
            .map { String(decoding: $0.prefix(1_048_576), as: UTF8.self) }
            .joined(separator: "\n")
        return Self.emulatorADBKeySignals(in: text)
    }

    private func privateADBServerKeySignals() -> (
        reportedKeyLoaded: Bool,
        expectedPathMatched: Bool
    ) {
        let stderrURL = runtimeDirectory.appendingPathComponent(
            "adb-server-\(privateADBServerPort).stderr.log"
        )
        guard let data = try? Data(
            contentsOf: stderrURL,
            options: [.mappedIfSafe]
        ) else { return (false, false) }
        return Self.privateADBServerKeySignals(
            in: String(decoding: data.prefix(1_048_576), as: UTF8.self),
            expectedPrivateKeyPath: privateADBKeyPaths.privateKey.path
        )
    }

    static func privateADBServerKeySignals(
        in log: String,
        expectedPrivateKeyPath: String
    ) -> (reportedKeyLoaded: Bool, expectedPathMatched: Bool) {
        let normalized = log.lowercased()
        let reported = normalized.contains("loaded new key from")
            || normalized.contains("ignored already-loaded key from")
        let expectedPath = expectedPrivateKeyPath.lowercased()
        let matched = normalized.contains("key from '\(expectedPath)'")
            || normalized.contains("key from \"\(expectedPath)\"")
        return (reported, matched)
    }

    static func emulatorADBKeySignals(
        in log: String
    ) -> AndroidEmulatorADBKeySignals {
        let lowercased = log.lowercased()
        return AndroidEmulatorADBKeySignals(
            reportedSendingPublicKey: lowercased.contains(
                "sending adb public key"
            ),
            reportedMissingPrivateKey: lowercased.contains(
                "no adb private key exists"
            ) || lowercased.contains("no private key found"),
            bootPropertiesContainPublicKey: lowercased.contains(
                "qemu.adb.pubkey="
            ) || lowercased.contains("qemu.adb.pubkey "),
            reportedPublicKeySHA256: emulatorReportedPublicKey(in: log)
                .flatMap { token in
                    AndroidPrivateADBKeyManager.publicKeySHA256(
                        Data(token.utf8)
                    )
                }
        )
    }

    private static func emulatorReportedPublicKey(in log: String) -> String? {
        let patterns = [
            #"(?i)Sending adb public key\s*\[([A-Za-z0-9+/=]+)"#,
            #"(?i)(?:androidboot\.)?qemu\.adb\.pubkey=[\"']?([A-Za-z0-9+/=]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: log,
                    range: NSRange(log.startIndex..., in: log)
                  ),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: log) else {
                continue
            }
            return String(log[range])
        }
        return nil
    }

    static func diagnosticLogTail(
        from data: Data,
        maximumBytes: Int = 16_384,
        maximumCharacters: Int = 4_000
    ) -> String {
        let raw = String(
            decoding: data.suffix(maximumBytes),
            as: UTF8.self
        )
        let sanitized = LogRedactor.text(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.suffix(maximumCharacters))
    }

    private func sanitizedEmulatorText(
        _ text: String,
        toolchain: AndroidToolchain?
    ) -> String {
        var safe = LogRedactor.text(Self.redactingADBKeyMaterial(in: text))
        if let toolchain {
            safe = safe.replacingOccurrences(
                of: toolchain.sdkRoot.path,
                with: "<sdk-root>"
            )
        }
        safe = safe.replacingOccurrences(
            of: applicationSupportDirectory.path,
            with: "<app-support>"
        )
        safe = safe.replacingOccurrences(
            of: homeDirectory.path,
            with: "<HOME>"
        )
        return safe
    }

    static func redactingADBKeyMaterial(in text: String) -> String {
        let privateKeyLabel = androidPrivatePEMLabel()
        let privateKeyPattern =
            #"(?is)(-----BEGIN (?:RSA )?"#
            + privateKeyLabel
            + #"-----).*?(-----END (?:RSA )?"#
            + privateKeyLabel
            + #"-----)"#
        let patterns = [
            (
                privateKeyPattern,
                "$1<redacted-private-key>$2"
            ),
            (
                #"(?i)(Sending adb public key\s*\[)[^\]\r\n]+(\])"#,
                "$1<redacted-public-key>$2"
            ),
            (
                #"(?i)((?:androidboot\.)?qemu\.adb\.pubkey=)[^\s\r\n]+"#,
                "$1<redacted-public-key>"
            )
        ]
        var output = text
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern
            ) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: template
            )
        }
        return output
    }

    static func privateAVDMetadataSnapshots(
        runtimeDirectory: URL,
        fileManager: FileManager
    ) -> [String: Data] {
        let allowed = [
            "runtime-manifest.json",
            "runtime-continuity.json",
            "runtime-profile.json"
        ]
        return Dictionary(uniqueKeysWithValues: allowed.compactMap { name in
            let url = runtimeDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (name, data)
        })
    }

    /// Atomically scopes repair to the private AVD. Items are moved, never
    /// deleted; if any move/write fails, completed moves are rolled back.
    static func movePrivateAVDToRecoverableBackup(
        runtimeDirectory: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        identifier: String = UUID().uuidString,
        metadataSnapshots: [String: Data] = [:]
    ) throws -> AndroidPrivateAVDBackupResult? {
        let avdHome = runtimeDirectory.appendingPathComponent(
            "avd",
            isDirectory: true
        )
        let avd = avdHome.appendingPathComponent(
            "\(Self.avdName).avd",
            isDirectory: true
        )
        let companion = avdHome.appendingPathComponent(
            "\(Self.avdName).ini"
        )
        let avdManifest = avdHome.appendingPathComponent(
            "avd-manifest.json"
        )
        let continuity = runtimeDirectory.appendingPathComponent(
            "runtime-continuity.json"
        )
        let movable = [avd, companion, avdManifest, continuity].filter {
            fileManager.fileExists(atPath: $0.path)
        }
        let allowedMetadataNames = Set([
            "runtime-manifest.json",
            "runtime-continuity.json",
            "runtime-profile.json"
        ])
        let metadata = metadataSnapshots.filter {
            allowedMetadataNames.contains($0.key)
        }
        guard !movable.isEmpty || !metadata.isEmpty else { return nil }

        let backups = runtimeDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeIdentifier = identifier.filter {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
        let suffix = String(safeIdentifier.prefix(8))
        let backup = backups.appendingPathComponent(
            "\(Self.avdName)-\(formatter.string(from: now))-\(suffix)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backup,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var completedMoves: [(source: URL, destination: URL)] = []
        var writtenMetadata: [String] = []
        do {
            for source in movable {
                let destination = backup.appendingPathComponent(
                    source.lastPathComponent,
                    isDirectory: source.pathExtension == "avd"
                )
                try fileManager.moveItem(at: source, to: destination)
                completedMoves.append((source, destination))
            }
            for (name, data) in metadata.sorted(by: { $0.key < $1.key }) {
                let destination = backup.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: [.atomic])
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: destination.path
                    )
                }
                writtenMetadata.append(name)
            }
        } catch {
            for move in completedMoves.reversed()
                where !fileManager.fileExists(atPath: move.source.path) {
                try? fileManager.moveItem(
                    at: move.destination,
                    to: move.source
                )
            }
            try? fileManager.removeItem(at: backup)
            throw error
        }
        return AndroidPrivateAVDBackupResult(
            directory: backup,
            movedItemNames: completedMoves.map {
                $0.destination.lastPathComponent
            }.sorted(),
            metadataItemNames: writtenMetadata.sorted()
        )
    }

    private func backupManagedAVDForRenderingUpgrade() throws {
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let allocatedBytes = try Self.allocatedDirectorySize(
            avdDirectory,
            fileManager: fileManager
        )
        let available = try runtimeDirectory.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        let availableBytes = available.volumeAvailableCapacityForImportantUsage
            ?? Int64(available.volumeAvailableCapacity ?? 0)
        let safetyMargin: Int64 = 1_073_741_824
        guard availableBytes > allocatedBytes + safetyMargin else {
            throw AppError.spider(
                "磁盘空间不足；保留 Android 登录数据备份还需要至少 1 GB 安全空间"
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        let root = backupDirectory.appendingPathComponent(
            "pre-rendering-upgrade-\(formatter.string(from: Date()))-\(suffix)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(
                at: avdDirectory,
                to: root.appendingPathComponent(
                    "\(Self.avdName).avd",
                    isDirectory: true
                )
            )
            let companion = avdHome.appendingPathComponent(
                "\(Self.avdName).ini"
            )
            if fileManager.fileExists(atPath: companion.path) {
                try fileManager.copyItem(
                    at: companion,
                    to: root.appendingPathComponent(companion.lastPathComponent)
                )
            }
            if fileManager.fileExists(atPath: manifestURL.path) {
                try fileManager.copyItem(
                    at: manifestURL,
                    to: root.appendingPathComponent(
                        manifestURL.lastPathComponent
                    )
                )
            }
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func ensureManagedAVD(
        _ toolchain: AndroidToolchain,
        gpuBackend: AndroidEmulatorGPUBackend
    ) throws {
        try createRuntimeDirectories()
        let managedContext = try managedAVDContext(for: toolchain)
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
            let contents = try String(
                contentsOf: configuration,
                encoding: .utf8
            )
            let image: AndroidSystemImage?
            if let managedContext {
                image = resolver().interactiveSystemImages(in: toolchain)
                    .first(where: {
                        $0.packageID == managedContext.systemImagePackageID
                    })
            } else {
                image = resolver().preferredInteractiveSystemImage(
                    in: toolchain,
                    avdConfiguration: contents
                )
            }
            guard let image else {
                throw AppError.spider(
                    "缺少可显示原生界面的 arm64 Android system image（ATD 不支持界面捕获）"
                )
            }
            try synchronizeAVDCompatibilityFingerprint(
                toolchain: toolchain,
                image: image,
                configurationContents: contents,
                managedContext: managedContext
            )
            if let managedContext {
                let existingManifest = try readManagedAVDManifest(
                    from: managedContext.layout.avdManifest
                )
                let compatibility = ManagedAVDCompatibility.evaluate(
                    hasExistingAVD: true,
                    manifest: existingManifest,
                    expectedGeneration: managedContext.generation,
                    expectedSystemImageComponentID:
                        managedContext.systemImageComponentID,
                    configurationMatchesExpectedImage:
                        AndroidManagedAVDConfiguration.matches(
                            image,
                            contents: contents
                        )
                )
                guard compatibility.status
                        != .requiresRecoverableRebuild else {
                    appendEvent(
                        stage: .preparingAVD,
                        event: "managedAVDCompatibilityRejected",
                        detail: compatibility.reason
                    )
                    throw AppError.spider(
                        "现有 Android 兼容环境与当前组件不兼容。"
                            + "为保护登录数据，OKVideoMac 未自动覆盖；"
                            + "请在设置中选择“修复 Android Runtime…”进行可恢复重建。"
                    )
                }
            }
            let updated = AndroidManagedAVDConfiguration.updating(
                contents,
                for: image,
                gpuBackend: gpuBackend
            )
            if updated != contents {
                if AndroidManagedAVDConfiguration.requiresSystemImageMigration(
                    contents,
                    to: image
                ) {
                    guard !runtimeProcessReferencesAVD(
                        named: Self.avdName
                    ) else {
                        throw AppError.spider(
                            "Android 环境仍在运行；为保护登录数据，系统镜像迁移已中止"
                        )
                    }
                    try backupManagedAVDForRenderingUpgrade()
                }
                try Data(updated.utf8).write(
                    to: configuration,
                    options: [.atomic]
                )
            }
            if let managedContext {
                try writeManagedAVDManifest(managedContext)
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
        let image: AndroidSystemImage?
        if let managedContext {
            image = resolver().interactiveSystemImages(in: toolchain)
                .first(where: {
                    $0.packageID == managedContext.systemImagePackageID
                })
        } else {
            image = resolver().interactiveSystemImages(in: toolchain).first
        }
        guard let image else {
            throw AppError.spider(
                "缺少可显示原生界面的 arm64 Android system image；"
                    + "ATD 不支持界面捕获，本版本不会自动下载"
            )
        }
        guard let javaRuntime = resolver().resolveJavaRuntime() else {
            throw AppError.spider(
                "创建 AVD 缺少 Java Runtime；请安装 JDK 或 Android Studio JBR"
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
            environment: javaRuntime.applying(
                to: childEnvironment(for: toolchain)
            ),
            input: Data("no\n".utf8)
        )
        guard fileManager.fileExists(atPath: configuration.path) else {
            throw AppError.spider("专用 Android 环境创建失败")
        }
        let contents = try String(contentsOf: configuration, encoding: .utf8)
        let updated = AndroidManagedAVDConfiguration.updating(
            contents,
            for: image,
            gpuBackend: gpuBackend
        )
        if updated != contents {
            try Data(updated.utf8).write(
                to: configuration,
                options: [.atomic]
            )
        }
        try synchronizeAVDCompatibilityFingerprint(
            toolchain: toolchain,
            image: image,
            configurationContents: updated,
            managedContext: managedContext
        )
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
        if let managedContext {
            try writeManagedAVDManifest(managedContext)
        }
    }

    private struct ManagedAVDContext {
        let layout: AndroidRuntimeLayout
        let selection: ManagedRuntimeSelection
        let generation: RuntimeGenerationDescriptor
        let systemImageComponentID: String
        let systemImagePackageID: String
    }

    /// The Managed Runtime integration is intentionally limited to selecting
    /// and recording AVD compatibility metadata. Startup admission, process
    /// ownership, private ADB, and recovery remain in the existing Session
    /// state machine.
    private func managedAVDContext(
        for toolchain: AndroidToolchain
    ) throws -> ManagedAVDContext? {
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: applicationSupportDirectory
        )
        guard fileManager.fileExists(
            atPath: layout.currentRuntimePointer.path
        ) else { return nil }
        do {
            let catalog = try BundledRuntimeCatalog.load()
            let selection = try ManagedRuntimeSelection.resolve(
                layout: layout,
                catalog: catalog,
                privateADBServerPort: privateADBServerPort
            )
            guard selection.sdkRoot.standardizedFileURL
                    .resolvingSymlinksInPath()
                    == toolchain.sdkRoot.standardizedFileURL
                        .resolvingSymlinksInPath(),
                  let generation = catalog.generations.first(where: {
                      $0.generationID == selection.generationID
                  }),
                  let image = generation.components.first(where: {
                      $0.role == .systemImage
                  }),
                  let packageID = generation.systemImagePackageID,
                  image.packageID == packageID else {
                throw ManagedRuntimeProductError.purityGateFailed
            }
            return ManagedAVDContext(
                layout: layout,
                selection: selection,
                generation: generation,
                systemImageComponentID: image.id,
                systemImagePackageID: packageID
            )
        } catch {
            throw AppError.spider(
                "Android 兼容组件校验失败；请在设置中修复组件"
            )
        }
    }

    private func synchronizeAVDCompatibilityFingerprint(
        toolchain: AndroidToolchain,
        image: AndroidSystemImage,
        configurationContents: String,
        managedContext: ManagedAVDContext?
    ) throws {
        guard let runtimeSelectionMode else { return }
        guard ExternalAndroidRuntimeValidator.avdConfiguration(
            configurationContents,
            matches: image
        ) else {
            throw AndroidRuntimeModeCoordinatorError.incompatibleAVD(
                "avd-configuration-metadata"
            )
        }
        let expected: AndroidRuntimeAVDCompatibilityFingerprint
        switch runtimeSelectionMode {
        case .managed:
            guard let managedContext,
                  let fingerprint = ExternalAndroidRuntimeValidator
                    .managedFingerprint(
                        selection: managedContext.selection,
                        descriptor: managedContext.generation
                    ) else {
                throw AndroidRuntimeModeCoordinatorError
                    .managedRuntimeUnavailable
            }
            expected = fingerprint
        case .external:
            expected = ExternalAndroidRuntimeValidator.externalFingerprint(
                sdkRoot: toolchain.sdkRoot,
                image: image,
                emulatorRevision: ExternalAndroidRuntimeValidator
                    .emulatorRevision(in: toolchain.sdkRoot)
            )
        }
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let store = AndroidRuntimeAVDFingerprintStore(
            layout: layout,
            fileManager: fileManager
        )
        let status = store.inspect(
            expected: expected,
            hasAVD: true,
            legacyManagedManifestExists: fileManager.fileExists(
                atPath: layout.avdManifest.path
            )
        )
        try store.adoptOrRefresh(expected, status: status)
    }

    private func readManagedAVDManifest(
        from url: URL
    ) throws -> ManagedAVDManifest? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                ManagedAVDManifest.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw AppError.spider(
                "Android 兼容环境记录无法读取。为保护登录数据，"
                    + "OKVideoMac 未自动覆盖；请执行可恢复重建。"
            )
        }
    }

    private func writeManagedAVDManifest(
        _ context: ManagedAVDContext
    ) throws {
        let existing = try readManagedAVDManifest(
            from: context.layout.avdManifest
        )
        let manifest = ManagedAVDManifest(
            avdSchema: context.generation.avdSchema,
            bridgeSchema: context.generation.bridgeSchema,
            runtimeGenerationID: context.generation.generationID,
            systemImageComponentID: context.systemImageComponentID,
            createdAt: existing?.createdAt ?? Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: context.layout.avdManifest,
            options: [.atomic]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: context.layout.avdManifest.path
        )
    }

    private func launchManagedEmulator(
        _ toolchain: AndroidToolchain,
        gpuBackend: AndroidEmulatorGPUBackend
    ) async throws -> AndroidRuntimeIdentity {
        let generation = UUID().uuidString
        let authenticationMode = emulatorADBAuthenticationMode(
            for: toolchain
        )
        var sawPortConflict = false
        for consolePort in Self.candidateConsolePorts {
            try Task.checkCancellation()
            let logStem = "emulator-\(generation)-\(consolePort)"
            let stdoutURL = runtimeDirectory.appendingPathComponent(
                "\(logStem).stdout.log"
            )
            let stderrURL = runtimeDirectory.appendingPathComponent(
                "\(logStem).stderr.log"
            )
            _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            let process = Process()
            process.executableURL = toolchain.emulator
            let arguments = Self.emulatorLaunchArguments(
                consolePort: consolePort,
                gpuBackend: gpuBackend,
                adbAuthenticationMode: authenticationMode,
                verboseDiagnostics: verboseAndroidDiagnosticsEnabled
            )
            let environment = childEnvironment(for: toolchain)
            let launchAt = Date()
            appendEvent(
                stage: .launchingEmulator,
                event: "emulatorLaunchStart",
                detail: "port=\(consolePort) gpu=\(gpuBackend.rawValue) adbAuth=\(authenticationMode.rawValue)"
            )
            let recorder = AndroidEmulatorProcessRecorder(
                launchAt: launchAt,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL,
                arguments: arguments.map {
                    sanitizedEmulatorText($0, toolchain: toolchain)
                },
                environment: diagnosticEmulatorEnvironment(
                    environment,
                    toolchain: toolchain
                )
            )
            emulatorProcessRecorder = recorder
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { terminatedProcess in
                let reason: String
                switch terminatedProcess.terminationReason {
                case .exit:
                    reason = "exit"
                case .uncaughtSignal:
                    reason = "uncaughtSignal"
                @unknown default:
                    reason = "unknown"
                }
                recorder.processDidTerminate(
                    pid: terminatedProcess.processIdentifier,
                    status: terminatedProcess.terminationStatus,
                    reason: reason
                )
            }
            do {
                try process.run()
                recorder.processDidLaunch(pid: process.processIdentifier)
            } catch {
                try? stdout.close()
                try? stderr.close()
                throw error
            }

            // Publish ownership immediately after spawn. App termination may
            // cancel the early-exit observation below; shutdown must already
            // know the exact PID and process birth identity in that window.
            emulatorProcess = process
            emulatorOutputHandles = [stdout, stderr]
            let processIdentity = processBirthIdentity(
                pid: process.processIdentifier
            )
            let identity = AndroidRuntimeIdentity(
                schema: Self.manifestSchema,
                generation: generation,
                systemBootIdentifier: currentBootIdentifier,
                sdkRoot: toolchain.sdkRoot,
                emulatorExecutable: toolchain.emulator,
                adbExecutable: toolchain.adb,
                adbServerPort: privateADBServerPort,
                gpuBackend: gpuBackend,
                adbAuthenticationMode: authenticationMode,
                avdName: Self.avdName,
                avdDirectory: avdDirectory,
                pid: process.processIdentifier,
                pidBirthIdentity: processIdentity?.value,
                consolePort: consolePort,
                serial: Self.emulatorSerial(consolePort: consolePort),
                forwards: Self.expectedForwards,
                launchedAt: processIdentity?.startedAt ?? launchAt,
                appSessionID: Self.appSessionID,
                runtimeSessionID: UUID().uuidString,
                launchOrigin: .currentLaunch,
                terminationRequestedAt: nil,
                terminationRequestReason: nil
            )
            lastObservedIdentity = identity
            lastOwnershipClassification = .ownedCurrentLaunch
            lastLifecycleConflictReason = nil
            do {
                try saveIdentity(identity)
                appendEvent(
                    stage: .launchingEmulator,
                    event: "emulator_process_launched",
                    detail: "pid=\(identity.pid) serial=\(identity.serial)"
                )
                appendEvent(
                    stage: .launchingEmulator,
                    event: "emulatorPIDObserved",
                    detail: "pid=\(identity.pid)"
                )
            } catch {
                recorder.recordTerminationRequestedByApp(
                    "runtimeIdentityPersistenceFailed"
                )
                process.terminate()
                for _ in 0..<10 where process.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                clearRuntimeRecord()
                throw error
            }
            for _ in 0..<20 where process.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if !process.isRunning {
                clearRuntimeRecord()
                let output = [
                    emulatorLogTail(at: stderrURL),
                    emulatorLogTail(at: stdoutURL)
                ].compactMap { $0 }.joined(separator: "\n")
                if Self.isEmulatorPortConflict(output) {
                    sawPortConflict = true
                    lastOwnershipClassification = .portConflict
                    lastLifecycleConflictReason =
                        "Emulator 无法绑定 console/ADB port \(consolePort)/\(consolePort + 1)"
                    continue
                }
                if Self.isEmulatorAVDConflict(output) {
                    lastOwnershipClassification = .externalRuntimeConflict
                    lastLifecycleConflictReason =
                        "Emulator 报告同一 AVD 已被其他进程使用"
                    throw AndroidRuntimeFailureError(
                        record: AndroidRuntimeFailureRecord(
                            occurredAt: Date(),
                            stage: .launchingEmulator,
                            category: .emulatorRuntimeConflict,
                            message: "Android Emulator 拒绝重复启动同一个专用 AVD"
                        )
                    )
                }
                throw AppError.spider(
                    "Android Emulator 启动失败："
                        + String(output.suffix(1_000))
                )
            }
            return identity
        }
        if sawPortConflict {
            throw AndroidRuntimeFailureError(
                record: AndroidRuntimeFailureRecord(
                    occurredAt: Date(),
                    stage: .launchingEmulator,
                    category: .portConflict,
                    message: "Android Emulator console/ADB 端口均被其他进程占用"
                )
            )
        }
        throw AppError.spider("没有可用的 Android Emulator console port")
    }

    static func emulatorLaunchArguments(
        consolePort: Int,
        gpuBackend: AndroidEmulatorGPUBackend = .host,
        adbAuthenticationMode: AndroidEmulatorADBAuthenticationMode =
            .privateKeyBootProperty,
        verboseDiagnostics: Bool = false
    ) -> [String] {
        var arguments = [
            "-avd", avdName,
            "-port", "\(consolePort)",
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            "-no-metrics",
            "-no-snapshot"
        ]
        if adbAuthenticationMode.skipsGuestADBAuthentication {
            arguments.append("-skip-adb-auth")
        }
        arguments.append(contentsOf: [
            "-gpu", gpuBackend.rawValue,
            "-accel", "on"
        ])
        if verboseDiagnostics {
            arguments.append(contentsOf: ["-verbose", "-show-kernel"])
        }
        return arguments
    }

    static func emulatorADBAuthenticationMode(
        systemImageAPILevel: Int?
    ) -> AndroidEmulatorADBAuthenticationMode {
        guard let systemImageAPILevel else {
            // Never weaken guest authentication when the selected image
            // cannot be proven to require the legacy compatibility path.
            return .privateKeyBootProperty
        }
        return systemImageAPILevel < 30
            ? .legacySkipAuthCompatibility
            : .privateKeyBootProperty
    }

    static func emulatorADBAuthenticationMode(
        in command: String
    ) -> AndroidEmulatorADBAuthenticationMode {
        let fields = command.split(whereSeparator: { $0.isWhitespace })
        return fields.contains("-skip-adb-auth")
            ? .legacySkipAuthCompatibility
            : .privateKeyBootProperty
    }

    private func emulatorADBAuthenticationMode(
        for toolchain: AndroidToolchain
    ) -> AndroidEmulatorADBAuthenticationMode {
        let configurationURL = avdDirectory.appendingPathComponent(
            "config.ini"
        )
        let configuration = try? String(
            contentsOf: configurationURL,
            encoding: .utf8
        )
        let image = resolver().preferredInteractiveSystemImage(
            in: toolchain,
            avdConfiguration: configuration
        )
        return Self.emulatorADBAuthenticationMode(
            systemImageAPILevel: image?.apiLevel
        )
    }

    static func emulatorSerial(consolePort: Int) -> String {
        "emulator-\(consolePort)"
    }

    static func gpuBackend(in command: String) -> AndroidEmulatorGPUBackend? {
        let fields = command.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let index = fields.firstIndex(of: "-gpu"),
              fields.indices.contains(index + 1) else { return nil }
        return AndroidEmulatorGPUBackend(rawValue: fields[index + 1])
    }

    static func shouldAttemptSoftwareGPUFallback(
        failureCategory: AndroidRuntimeFailureCategory,
        currentBackend: AndroidEmulatorGPUBackend,
        fallbackAlreadyAttempted: Bool
    ) -> Bool {
        (failureCategory == .hostGPUADBOfflineTimeout
            || failureCategory == .adbReconnectFailed)
            && currentBackend == .host
            && !fallbackAlreadyAttempted
    }

    static func softwareFallbackRequiresAVDRecovery(
        failureCategory: AndroidRuntimeFailureCategory
    ) -> Bool {
        switch failureCategory {
        case .softwareGPUADBOfflineTimeout, .adbSerialMissingTimeout,
             .adbOfflineTimeout, .adbReconnectFailed, .adbUnavailable:
            return true
        default:
            return false
        }
    }

    static func privateAVDRepairMayProceed(
        shutdownMechanism: AndroidRuntimeShutdownMechanism,
        matchingAVDProcessCount: Int
    ) -> Bool {
        shutdownMechanism != .refusedOwnershipMismatch
            && matchingAVDProcessCount == 0
    }

    /// Provisions one process-wide, app-owned keypair before either the
    /// private ADB daemon or an Emulator process can start. The lock covers
    /// multiple runtime actor instances that share the same Application
    /// Support directory.
    private func ensurePrivateADBKeypair(
        _ toolchain: AndroidToolchain
    ) throws {
        Self.privateADBKeyLifecycleLock.lock()
        defer { Self.privateADBKeyLifecycleLock.unlock() }

        try createRuntimeDirectories()
        let result = try AndroidPrivateADBKeyManager.ensureKeyPair(
            paths: privateADBKeyPaths,
            fileManager: fileManager
        ) { stagingPrivateKey in
            _ = try run(
                toolchain.adb,
                ["keygen", stagingPrivateKey.path],
                environment: childEnvironment(for: toolchain),
                category: "adb.keygen.private",
                timeout: 30
            )
        }
        lastPrivateADBKeyStatus = result.status
        privateADBKeyGeneratedThisSession =
            privateADBKeyGeneratedThisSession || result.generated
        if result.generated {
            appendEvent(
                stage: currentStage,
                event: "privateADBKeyGenerated",
                detail: result.status.publicKeySHA256.map {
                    "sha256=\($0)"
                }
            )
        }
    }

    private func ensureADBServer(_ toolchain: AndroidToolchain) throws {
        do {
            try ensurePrivateADBKeypair(toolchain)
        } catch let failure as AndroidRuntimeFailureError {
            throw failure
        } catch {
            throw adbPrivateServerFailure(
                "无法准备 OKVideoMac 私有 ADB keypair："
                    + sanitizedEmulatorText(
                        error.localizedDescription,
                        toolchain: toolchain
                    )
            )
        }
        appendEvent(
            stage: currentStage,
            event: "adbPrivateServerStart",
            detail: "selected SDK; default 5037 excluded"
        )
        let selectedADB = toolchain.adb.standardizedFileURL
            .resolvingSymlinksInPath()
        var occupied = Set<Int>()
        var reusable = Set<Int>()
        for port in Self.candidatePrivateADBServerPorts {
            let pids = listeningProcessIDs(on: port)
            guard !pids.isEmpty else { continue }
            occupied.insert(port)
            if pids.count == 1,
               port == privateADBServerPort,
               let path = processExecutablePath(pid: pids[0]),
               Self.privateADBServerIdentityMatches(
                    listenerPID: pids[0],
                    listenerBirthIdentity:
                        processBirthIdentity(pid: pids[0])?.value,
                    listenerExecutable: URL(fileURLWithPath: path),
                    recordedPID: persistedADBServerPID,
                    recordedBirthIdentity:
                        persistedADBServerBirthIdentity,
                    selectedADB: selectedADB
               ) {
                // An executable match alone is insufficient: another tool
                // can start the same SDK's adb on a high port. Reuse only the
                // exact PID and birth identity recorded by OKVideoMac.
                reusable.insert(port)
            }
        }
        guard let selectedPort = Self.selectPrivateADBServerPort(
            preferred: privateADBServerPort,
            reusable: reusable,
            occupied: occupied
        ) else {
            throw adbPrivateServerFailure(
                "OKVideoMac 私有 ADB 端口范围已被其他进程占用"
            )
        }
        privateADBServerPort = selectedPort

        var expectedLaunchedPID: Int32?
        if !reusable.contains(selectedPort) {
            do {
                try launchPrivateADBServer(
                    toolchain: toolchain,
                    port: selectedPort
                )
                expectedLaunchedPID = adbServerProcess?.processIdentifier
            } catch {
                throw adbPrivateServerFailure(
                    "无法使用所选 Android SDK 启动私有 ADB server："
                        + sanitizedEmulatorText(
                            error.localizedDescription,
                            toolchain: toolchain
                        )
                )
            }
        }

        var diagnostic: AndroidADBServerDiagnostic?
        for _ in 0..<100 {
            diagnostic = adbServerDiagnostic(toolchain: toolchain)
            if diagnostic?.ownedBySelectedSDK == true,
               Self.privateADBServerLaunchMatches(
                    expectedLaunchedPID: expectedLaunchedPID,
                    observedListenerPID: diagnostic?.pid
               ) {
                break
            }
            if adbServerProcess?.isRunning == false { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let diagnostic,
              diagnostic.ownedBySelectedSDK,
              Self.privateADBServerLaunchMatches(
                expectedLaunchedPID: expectedLaunchedPID,
                observedListenerPID: diagnostic.pid
              ) else {
            if adbServerProcess?.isRunning == true {
                adbServerProcess?.terminate()
            }
            adbServerProcess = nil
            for handle in adbServerOutputHandles { try? handle.close() }
            adbServerOutputHandles = []
            throw adbPrivateServerFailure(
                "私有 ADB server 进程无法通过 selected SDK 身份校验"
            )
        }
        lastADBServerDiagnostic = diagnostic
        persistedADBServerPID = diagnostic.pid
        persistedADBServerBirthIdentity = diagnostic.birthIdentity
        try saveRuntimeProfile()
        appendEvent(
            stage: currentStage,
            event: "adbPrivateServerReady",
            detail: "port=\(selectedPort) pid=\(diagnostic.pid.map(String.init) ?? "unknown")"
        )
    }

    private func launchPrivateADBServer(
        toolchain: AndroidToolchain,
        port: Int
    ) throws {
        try createRuntimeDirectories()
        for handle in adbServerOutputHandles {
            try? handle.close()
        }
        adbServerOutputHandles = []
        adbServerProcess = nil

        let stdoutURL = runtimeDirectory.appendingPathComponent(
            "adb-server-\(port).stdout.log"
        )
        let stderrURL = runtimeDirectory.appendingPathComponent(
            "adb-server-\(port).stderr.log"
        )
        for url in [stdoutURL, stderrURL] {
            if !fileManager.fileExists(atPath: url.path) {
                _ = fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            adbServerOutputHandles.append(handle)
        }
        guard adbServerOutputHandles.count == 2 else {
            throw AppError.spider("无法创建私有 ADB server 日志")
        }
        let process = Process()
        process.executableURL = toolchain.adb
        process.arguments = Self.privateADBServerLaunchArguments(port: port)
        process.environment = childEnvironment(for: toolchain)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = adbServerOutputHandles[0]
        process.standardError = adbServerOutputHandles[1]
        do {
            try process.run()
        } catch {
            for handle in adbServerOutputHandles { try? handle.close() }
            adbServerOutputHandles = []
            throw error
        }
        adbServerProcess = process
        appendEvent(
            stage: currentStage,
            event: "adbPrivateServerPIDObserved",
            detail: "port=\(port) pid=\(process.processIdentifier)"
        )
    }

    private func adbPrivateServerFailure(
        _ message: String
    ) -> AndroidRuntimeFailureError {
        AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: currentStage,
                category: .adbPrivateServerFailed,
                message: message
            )
        )
    }

    private func listeningProcessIDs(on port: Int) -> [Int32] {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else { return [] }
        guard let output = try? run(
            lsof,
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"],
            category: "adb.server.listener_identity",
            timeout: 5
        ) else { return [] }
        return Array(Set(output.split(whereSeparator: \.isNewline).compactMap {
            line in
            guard line.first == "p" else { return nil }
            return Int32(line.dropFirst())
        })).sorted()
    }

    private func adbServerDiagnostic(
        toolchain: AndroidToolchain
    ) -> AndroidADBServerDiagnostic? {
        let pids = listeningProcessIDs(on: privateADBServerPort)
        guard pids.count == 1 else { return nil }
        let pid = pids[0]
        let actualPath = processExecutablePath(pid: pid).map {
            URL(fileURLWithPath: $0).standardizedFileURL
                .resolvingSymlinksInPath()
        }
        let selectedPath = toolchain.adb.standardizedFileURL
            .resolvingSymlinksInPath()
        let owned = actualPath == selectedPath
        let birth = processBirthIdentity(pid: pid)
        let version = owned ? (try? runADB(
            toolchain,
            ["version"],
            category: "adb.server.private.version",
            timeout: 5
        )).map(Self.firstDiagnosticLine) : nil
        return AndroidADBServerDiagnostic(
            port: privateADBServerPort,
            pid: pid,
            executable: actualPath.map {
                sanitizedEmulatorText($0.path, toolchain: toolchain)
            },
            version: version,
            birthIdentity: birth?.value,
            startedAt: birth?.startedAt,
            ownedBySelectedSDK: owned
        )
    }

    private func stopPrivateADBServerIfOwned(
        toolchain: AndroidToolchain?
    ) {
        let expectedPID = lastADBServerDiagnostic?.pid
            ?? persistedADBServerPID
        let expectedBirthIdentity = lastADBServerDiagnostic?.birthIdentity
            ?? persistedADBServerBirthIdentity
        guard let toolchain,
              let expectedPID,
              let expectedBirthIdentity,
              listeningProcessIDs(on: privateADBServerPort) == [expectedPID],
              processBirthIdentity(pid: expectedPID)?.value
                == expectedBirthIdentity,
              processExecutablePath(pid: expectedPID).map({
                  URL(fileURLWithPath: $0).standardizedFileURL
                      .resolvingSymlinksInPath()
              }) == toolchain.adb.standardizedFileURL
                  .resolvingSymlinksInPath(),
              let current = adbServerDiagnostic(toolchain: toolchain),
              current.ownedBySelectedSDK,
              current.pid == expectedPID,
              current.birthIdentity == expectedBirthIdentity
        else { return }
        _ = try? runADB(
            toolchain,
            ["kill-server"],
            category: "adb.server.private.stop",
            timeout: 10
        )
        appendEvent(
            stage: currentStage,
            event: "adbPrivateServerStopped",
            detail: "port=\(privateADBServerPort)"
        )
        for _ in 0..<20 where listeningProcessIDs(
            on: privateADBServerPort
        ).contains(current.pid ?? -1) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let pid = current.pid,
           listeningProcessIDs(on: privateADBServerPort).contains(pid),
           processBirthIdentity(pid: pid)?.value == current.birthIdentity,
           processExecutablePath(pid: pid).map({
               URL(fileURLWithPath: $0).standardizedFileURL
                   .resolvingSymlinksInPath()
           }) == toolchain.adb.standardizedFileURL.resolvingSymlinksInPath() {
            _ = Darwin.kill(pid, SIGTERM)
        }
        adbServerProcess = nil
        for handle in adbServerOutputHandles { try? handle.close() }
        adbServerOutputHandles = []
        lastADBServerDiagnostic = nil
        persistedADBServerPID = nil
        persistedADBServerBirthIdentity = nil
        try? saveRuntimeProfile()
    }

    private func waitForOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) async throws {
        let policy = AndroidADBTransportPolicy.production
        let monotonicStart = ProcessInfo.processInfo.systemUptime
        let wallStart = Date()
        var targetState: AndroidADBTargetState = .missing
        var observedEmulatorSerials: [String] = []
        var allObservedEmulatorSerials = Set<String>()
        var sanitizedDevices: [String] = []
        var previousState: AndroidADBTargetState?
        var lastSummaryElapsed: TimeInterval?
        var lastPortProbeElapsed: TimeInterval?
        var reconnectAttempted = false
        var reconnectCount = 0
        var missingCount = 0
        var offlineCount = 0
        var deviceCount = 0
        var emulatorAlwaysAlive = true
        var emulatorAlwaysOwned = true
        var consolePortListening: Bool?
        var adbPortListening: Bool?
        var consolePortAlwaysListening: Bool?
        var adbPortAlwaysListening: Bool?
        var gracePeriodEnded = false
        var firstMissingRecorded = false
        var firstOfflineRecorded = false
        var firstDeviceRecorded = false
        var portsRecorded = false

        while true {
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime
                - monotonicStart
            let processPresent = processExecutablePath(pid: identity.pid) != nil
            let processOwned = processPresent
                && verifyProcessOwnership(identity, toolchain: toolchain)
            emulatorAlwaysAlive = emulatorAlwaysAlive && processPresent
            emulatorAlwaysOwned = emulatorAlwaysOwned && processOwned

            if processPresent, processOwned {
                do {
                    let listing = try runADB(
                        toolchain,
                        ["devices", "-l"],
                        category: "adb.wait.devices",
                        timeout: 5
                    )
                    targetState = Self.adbTargetState(
                        in: listing,
                        serial: identity.serial
                    )
                    observedEmulatorSerials = Self.emulatorSerials(
                        in: listing
                    )
                    allObservedEmulatorSerials.formUnion(
                        observedEmulatorSerials
                    )
                    sanitizedDevices = Self.sanitizedADBDevices(
                        listing,
                        ownedSerial: identity.serial
                    )
                    lastADBDevices = sanitizedDevices
                } catch {
                    targetState = .unknown
                    observedEmulatorSerials = []
                    sanitizedDevices = []
                }
            }

            switch targetState {
            case .missing:
                missingCount += 1
                if !firstMissingRecorded {
                    firstMissingRecorded = true
                    appendEvent(
                        stage: .waitingForADB,
                        event: "adbSerialMissingFirstObserved",
                        detail: String(format: "elapsed=%.3f", elapsed)
                    )
                }
            case .offline:
                offlineCount += 1
                if !firstOfflineRecorded {
                    firstOfflineRecorded = true
                    appendEvent(
                        stage: .waitingForADB,
                        event: "adbOfflineFirstObserved",
                        detail: String(format: "elapsed=%.3f", elapsed)
                    )
                }
            case .device:
                deviceCount += 1
                if !firstDeviceRecorded {
                    firstDeviceRecorded = true
                    appendEvent(
                        stage: .waitingForADB,
                        event: "adbDeviceFirstObserved",
                        detail: String(format: "elapsed=%.3f", elapsed)
                    )
                }
            case .unauthorized, .unknown:
                break
            }

            if lastPortProbeElapsed == nil
                || elapsed - (lastPortProbeElapsed ?? 0) >= 5 {
                let portStatus = emulatorPortStatus(identity)
                consolePortListening = portStatus.console
                adbPortListening = portStatus.adb
                consolePortAlwaysListening = Self.combinedPortObservation(
                    consolePortAlwaysListening,
                    portStatus.console
                )
                adbPortAlwaysListening = Self.combinedPortObservation(
                    adbPortAlwaysListening,
                    portStatus.adb
                )
                lastPortProbeElapsed = elapsed
                if !portsRecorded {
                    portsRecorded = true
                    appendEvent(
                        stage: .waitingForADB,
                        event: "consolePortListening",
                        detail: "\(identity.consolePort)=\(portStatus.console.map(String.init) ?? "unknown")"
                    )
                    appendEvent(
                        stage: .waitingForADB,
                        event: "adbPortListening",
                        detail: "\(identity.consolePort + 1)=\(portStatus.adb.map(String.init) ?? "unknown")"
                    )
                }
            }

            if !gracePeriodEnded,
               elapsed >= policy.offlineGracePeriod {
                gracePeriodEnded = true
                appendEvent(
                    stage: .waitingForADB,
                    event: "offlineGracePeriodEnd",
                    detail: String(format: "elapsed=%.3f", elapsed)
                )
            }

            if policy.shouldRecordSummary(
                elapsed: elapsed,
                previousState: previousState,
                state: targetState,
                lastSummaryElapsed: lastSummaryElapsed
            ) {
                appendADBWaitObservation(
                    identity: identity,
                    targetState: targetState,
                    observedEmulatorSerials: observedEmulatorSerials,
                    adbDevices: sanitizedDevices,
                    emulatorAlive: processPresent,
                    emulatorOwned: processOwned,
                    consolePortListening: consolePortListening,
                    adbPortListening: adbPortListening
                )
                lastSummaryElapsed = elapsed
            }

            let backend = identity.gpuBackend ?? preferredGPUBackend
            let action = policy.action(
                elapsed: elapsed,
                targetState: targetState,
                processPresent: processPresent,
                processOwned: processOwned,
                reconnectAttempted: reconnectAttempted,
                reconnectFailed:
                    lastADBReconnectDiagnostic.map { $0.exitCode != 0 }
                        ?? false,
                gpuBackend: backend
            )
            switch action {
            case .ready:
                guard verifyDeviceOwnership(identity, toolchain: toolchain)
                else {
                    finishADBTransportWait(
                        identity: identity,
                        startedAt: wallStart,
                        elapsed: elapsed,
                        missingCount: missingCount,
                        offlineCount: offlineCount,
                        deviceCount: deviceCount,
                        reconnectCount: reconnectCount,
                        emulatorAlwaysAlive: emulatorAlwaysAlive,
                        emulatorAlwaysOwned: emulatorAlwaysOwned,
                        consolePortAlwaysListening: consolePortAlwaysListening,
                        adbPortAlwaysListening: adbPortAlwaysListening,
                        finalState: targetState
                    )
                    throw waitingForADBFailure(
                        .emulatorOwnershipMismatch,
                        message: "ADB 设备已连接，但 AVD 名称与专用运行记录不匹配"
                    )
                }
                finishADBTransportWait(
                    identity: identity,
                    startedAt: wallStart,
                    elapsed: elapsed,
                    missingCount: missingCount,
                    offlineCount: offlineCount,
                    deviceCount: deviceCount,
                    reconnectCount: reconnectCount,
                    emulatorAlwaysAlive: emulatorAlwaysAlive,
                    emulatorAlwaysOwned: emulatorAlwaysOwned,
                    consolePortAlwaysListening: consolePortAlwaysListening,
                    adbPortAlwaysListening: adbPortAlwaysListening,
                    finalState: targetState
                )
                lastOwnershipClassification = Self.ownershipClassification(
                    isCurrentAppLaunch:
                        identity.launchOrigin == .currentLaunch
                            && identity.appSessionID == Self.appSessionID,
                    targetState: .device,
                    deviceOwned: true,
                    processAge: Date().timeIntervalSince(identity.launchedAt)
                )
                return
            case .reconnect:
                reconnectAttempted = true
                reconnectCount += 1
                operationStatus = .starting(
                    "ADB 正在恢复专用 Emulator 连接",
                    progress: AndroidRuntimeStartupStage.waitingForADB.progress
                        ?? 0.18
                )
                lastADBReconnectDiagnostic = performBoundedADBReconnect(
                    identity,
                    toolchain: toolchain,
                    monotonicElapsed: elapsed,
                    stateBefore: targetState
                )
            case let .fail(category):
                let effectiveCategory: AndroidRuntimeFailureCategory
                if category == .adbSerialMissingTimeout,
                   allObservedEmulatorSerials.contains(where: {
                       $0 != identity.serial
                   }) {
                    effectiveCategory = .unexpectedSerial
                } else {
                    effectiveCategory = category
                }
                finishADBTransportWait(
                    identity: identity,
                    startedAt: wallStart,
                    elapsed: elapsed,
                    missingCount: missingCount,
                    offlineCount: offlineCount,
                    deviceCount: deviceCount,
                    reconnectCount: reconnectCount,
                    emulatorAlwaysAlive: emulatorAlwaysAlive,
                    emulatorAlwaysOwned: emulatorAlwaysOwned,
                    consolePortAlwaysListening: consolePortAlwaysListening,
                    adbPortAlwaysListening: adbPortAlwaysListening,
                    finalState: targetState
                )
                throw waitingForADBFailure(effectiveCategory)
            case .wait:
                break
            }
            previousState = targetState
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func combinedPortObservation(
        _ current: Bool?,
        _ next: Bool?
    ) -> Bool? {
        guard let next else { return current }
        guard let current else { return next }
        return current && next
    }

    private func performBoundedADBReconnect(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        monotonicElapsed: TimeInterval,
        stateBefore: AndroidADBTargetState
    ) -> AndroidADBReconnectDiagnostic {
        let startedAt = Date()
        appendEvent(
            stage: .waitingForADB,
            event: "adbReconnectStart",
            detail: String(format: "elapsed=%.3f", monotonicElapsed)
        )
        var exitCode: Int32 = 0
        var stdout = ""
        var stderr = ""
        var duration: TimeInterval = 0
        do {
            stdout = try runADB(
                toolchain,
                ["-s", identity.serial, "reconnect"],
                category: "adb.wait.reconnect_owned_device",
                timeout: 8
            )
            duration = Date().timeIntervalSince(startedAt)
        } catch let error as AndroidToolCommandError {
            exitCode = error.exitCode
            stdout = error.stdout
            stderr = error.stderr
            duration = error.duration
        } catch {
            exitCode = -1
            stderr = error.localizedDescription
            duration = Date().timeIntervalSince(startedAt)
        }
        let stateAfter = (try? runADB(
            toolchain,
            ["devices", "-l"],
            category: "adb.wait.reconnect_state",
            timeout: 5
        )).map {
            Self.adbTargetState(in: $0, serial: identity.serial)
        } ?? .unknown
        let diagnostic = AndroidADBReconnectDiagnostic(
            startedAt: startedAt,
            endedAt: Date(),
            monotonicElapsed: monotonicElapsed,
            executable: "<sdk-root>/platform-tools/adb",
            serverPort: privateADBServerPort,
            exitCode: exitCode,
            stdout: String(sanitizedCommandOutput(
                stdout,
                category: "adb.wait.reconnect_owned_device"
            ).prefix(4_000)),
            stderr: String(sanitizedCommandOutput(
                stderr,
                category: "adb.wait.reconnect_owned_device"
            ).prefix(4_000)),
            duration: duration,
            stateBefore: stateBefore.rawValue,
            stateAfter: stateAfter.rawValue
        )
        appendEvent(
            stage: .waitingForADB,
            event: "adbReconnectEnd",
            detail: "exit=\(exitCode) state=\(stateAfter.rawValue)"
        )
        return diagnostic
    }

    private func finishADBTransportWait(
        identity: AndroidRuntimeIdentity,
        startedAt: Date,
        elapsed: TimeInterval,
        missingCount: Int,
        offlineCount: Int,
        deviceCount: Int,
        reconnectCount: Int,
        emulatorAlwaysAlive: Bool,
        emulatorAlwaysOwned: Bool,
        consolePortAlwaysListening: Bool?,
        adbPortAlwaysListening: Bool?,
        finalState: AndroidADBTargetState
    ) {
        lastADBTransportSummary = AndroidADBTransportSummary(
            startedAt: startedAt,
            endedAt: Date(),
            elapsed: elapsed,
            missingCount: missingCount,
            offlineCount: offlineCount,
            deviceCount: deviceCount,
            reconnectCount: reconnectCount,
            emulatorAlwaysAlive: emulatorAlwaysAlive,
            emulatorAlwaysOwned: emulatorAlwaysOwned,
            consolePortAlwaysListening: consolePortAlwaysListening,
            adbPortAlwaysListening: adbPortAlwaysListening,
            finalState: finalState.rawValue
        )
        appendEvent(
            stage: .waitingForADB,
            event: "transportWaitEnd",
            detail: String(
                format: "elapsed=%.3f state=%@ missing=%d offline=%d device=%d reconnect=%d",
                elapsed,
                finalState.rawValue,
                missingCount,
                offlineCount,
                deviceCount,
                reconnectCount
            )
        )
    }

    private func waitingForADBFailure(
        _ category: AndroidRuntimeFailureCategory,
        message explicitMessage: String? = nil
    ) -> AndroidRuntimeFailureError {
        let message: String
        if let explicitMessage {
            message = explicitMessage
        } else {
            switch category {
            case .emulatorExitedBeforeADB, .emulatorExitedEarly,
                 .emulatorExited:
                message = "Android Emulator 在接入 ADB 前已退出"
            case .emulatorProcessMismatch:
                message = "Android Emulator PID 已不属于本次启动的专用实例"
            case .adbSerialMissingTimeout:
                message = "Android Emulator 仍在运行，但私有 ADB 未在 180 秒内发现目标 serial"
            case .hostGPUADBOfflineTimeout:
                message = "host GPU Emulator 在 180 秒内始终处于 ADB offline"
            case .softwareGPUADBOfflineTimeout:
                message = "software GPU Emulator 在 180 秒内始终处于 ADB offline"
            case .adbReconnectFailed:
                message = "目标 Emulator 的有界 ADB reconnect 失败"
            case .adbUnavailable:
                message = "私有 ADB 目标设备状态异常"
            default:
                message = "Android Emulator 接入私有 ADB 失败"
            }
        }
        return AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: .waitingForADB,
                category: category,
                message: message
            )
        )
    }

    private func privateAVDRecoveryRequired(
        _ message: String
    ) -> AndroidRuntimeFailureError {
        AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: .waitingForADB,
                category: .privateAVDRecoveryRequired,
                message: message
            )
        )
    }

    private func retireLegacyADBServerRuntimeIfNeeded(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) async throws -> Bool {
        guard identity.adbServerPort != privateADBServerPort,
              processExecutablePath(pid: identity.pid) != nil else {
            return false
        }
        guard verifyStrictProcessOwnership(identity, toolchain: toolchain)
        else {
            throw AndroidRuntimeFailureError(
                record: AndroidRuntimeFailureRecord(
                    occurredAt: Date(),
                    stage: .locatingSDK,
                    category: .emulatorProcessMismatch,
                    message: "旧 Runtime 未使用私有 ADB，且无法通过严格身份校验；未执行终止"
                )
            )
        }
        appendEvent(
            stage: .locatingSDK,
            event: "legacyADBServerRuntimeMigrationStart",
            detail: "retire owned pre-0.4.2 runtime"
        )
        guard await cleanupFailedRuntime(
            identity,
            toolchain: toolchain,
            reason: "privateADBServerMigration",
            allowVerifiedSIGKILL: true
        ), await waitForEmulatorPortsToRelease(identity) else {
            throw AndroidRuntimeFailureError(
                record: AndroidRuntimeFailureRecord(
                    occurredAt: Date(),
                    stage: .locatingSDK,
                    category: .emulatorProcessMismatch,
                    message: "旧 Runtime 无法确认安全退出；未启动第二个 Emulator"
                )
            )
        }
        try clearStalePrivateAVDLocksIfSafe(toolchain: toolchain)
        appendEvent(
            stage: .locatingSDK,
            event: "legacyADBServerRuntimeMigrationEnd",
            detail: "private ADB relaunch permitted"
        )
        return true
    }

    private func waitForEmulatorPortsToRelease(
        _ identity: AndroidRuntimeIdentity
    ) async -> Bool {
        for _ in 0..<40 {
            if listeningProcessIDs(on: identity.consolePort).isEmpty,
               listeningProcessIDs(on: identity.consolePort + 1).isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return listeningProcessIDs(on: identity.consolePort).isEmpty
            && listeningProcessIDs(on: identity.consolePort + 1).isEmpty
    }

    static func adbTargetState(
        in listing: String,
        serial: String
    ) -> AndroidADBTargetState {
        for rawLine in listing.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  String(fields[0]) == serial else { continue }
            switch String(fields[1]).lowercased() {
            case "device": return .device
            case "offline": return .offline
            case "unauthorized": return .unauthorized
            default: return .unknown
            }
        }
        return .missing
    }

    @discardableResult
    private func validateManagedRuntime(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        deviceRequired: Bool
    ) throws -> Bool {
        let observation = observeRuntimeOwnership(
            identity,
            toolchain: toolchain
        )
        let category: AndroidRuntimeFailureCategory?
        switch observation.decision {
        case .reuseOwnedRuntime:
            category = deviceRequired && !observation.deviceReachable
                ? .adbUnavailable : nil
        case let .clearStaleRecord(reason):
            switch reason {
            case .processExited:
                category = currentStage == .waitingForADB
                    ? .emulatorExited : .runtimeExited
            case .previousSystemBoot:
                category = .runtimeExited
            case .pidReused:
                category = .emulatorProcessMismatch
            }
        case .rejectConflictingRuntime:
            category = observation.deviceReachable && !observation.deviceOwned
                ? .emulatorOwnershipMismatch : .emulatorProcessMismatch
        }
        guard let category else {
            return observation.deviceOwned
        }

        let message: String
        switch category {
        case .emulatorExitedEarly, .emulatorExited:
            message = "Android Emulator 在接入 ADB 前已退出"
        case .appRequestedTermination:
            message = "Android Emulator 启动已由 App 结束"
        case .runtimeExited:
            message = "专用 Android Emulator 进程已退出"
        case .adbUnavailable:
            message = "专用 Android Emulator 设备已断开"
        case .adbDeviceMissing:
            message = "Android Emulator 进程仍在运行，但 ADB 未发现目标设备"
        case .adbDeviceOffline:
            message = "ADB 目标设备处于 offline 状态"
        case .unexpectedSerial:
            message = "ADB 发现了其他 Emulator，但未发现本次启动的目标设备"
        case .emulatorOwnershipMismatch:
            message = "专用 Android Emulator 所有权校验失败；已拒绝继续操作"
        case .emulatorRuntimeConflict:
            message = "检测到其他 Emulator 使用了记录端口，未执行任何操作"
        case .portConflict:
            message = "Android Emulator 所需端口被其他进程占用"
        case .emulatorProcessMismatch:
            message = "Android Emulator PID 已不再属于本次启动实例"
        default:
            message = "专用 Android Emulator 生命周期校验失败"
        }
        throw AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: currentStage,
                category: category,
                message: message
            )
        )
    }

    private func observeRuntimeOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> AndroidRuntimeOwnershipObservation {
        let processPresent = processExecutablePath(pid: identity.pid) != nil
        let processOwned = processPresent
            && verifyProcessOwnership(identity, toolchain: toolchain)
        let deviceReachable = deviceIsReachable(
            identity,
            toolchain: toolchain
        )
        let deviceOwned = deviceReachable
            && verifyDeviceOwnership(identity, toolchain: toolchain)
        return AndroidRuntimeOwnershipObservation(
            processState: Self.processIdentityState(
                processPresent: processPresent,
                processOwned: processOwned
            ),
            deviceReachable: deviceReachable,
            deviceOwned: deviceOwned,
            decision: Self.runtimeRecordDecision(
                recordedBootIdentifier: identity.systemBootIdentifier,
                currentBootIdentifier: currentBootIdentifier,
                processPresent: processPresent,
                processOwned: processOwned,
                deviceReachable: deviceReachable,
                deviceOwned: deviceOwned
            )
        )
    }

    private func appendStaleRecordRecovery(
        _ reason: AndroidRuntimeStaleRecordReason
    ) {
        lastOwnershipClassification = .staleRuntimeMetadata
        let detail: String
        switch reason {
        case .previousSystemBoot:
            detail = "检测到电脑重启后的旧运行记录，正在重新连接"
        case .processExited:
            detail = "旧 Emulator 已退出，清除运行记录后重新连接"
        case .pidReused:
            detail = "旧 Emulator PID 已被其他进程复用；仅清除运行记录"
        }
        appendEvent(
            stage: currentStage,
            event: "stale_runtime_record_cleared",
            detail: detail
        )
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
              identity.serial == Self.emulatorSerial(
                  consolePort: identity.consolePort
              ),
              Self.candidateConsolePorts.contains(identity.consolePort),
              identity.sdkRoot.standardizedFileURL
                == toolchain.sdkRoot.standardizedFileURL,
              identity.emulatorExecutable.standardizedFileURL
                == toolchain.emulator.standardizedFileURL,
              identity.adbExecutable == nil
                || identity.adbExecutable?.standardizedFileURL
                    == toolchain.adb.standardizedFileURL,
              identity.adbServerPort == nil
                || identity.adbServerPort == privateADBServerPort,
              let executablePath = processExecutablePath(pid: identity.pid)
        else { return false }

        if let recordedBirth = identity.pidBirthIdentity {
            guard processBirthIdentity(pid: identity.pid)?.value
                    == recordedBirth else { return false }
        }

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

    private func verifyStrictProcessOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        guard let recordedBirth = identity.pidBirthIdentity,
              processBirthIdentity(pid: identity.pid)?.value == recordedBirth,
              verifyProcessOwnership(identity, toolchain: toolchain) else {
            return false
        }
        // A Process created by this actor is direct ownership proof during
        // the short interval before QEMU opens files below the private AVD.
        // Adopted processes have no handle and must pass the lsof check.
        let isCurrentChild = emulatorProcess?.processIdentifier == identity.pid
            && emulatorProcess?.isRunning == true
        return isCurrentChild || processReferencesPrivateAVD(pid: identity.pid)
    }

    private func refreshedIdentityForCurrentSession(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> AndroidRuntimeIdentity {
        var refreshed = identity
        refreshed.systemBootIdentifier = currentBootIdentifier
        refreshed.adbExecutable = toolchain.adb
        refreshed.adbServerPort = privateADBServerPort
        if refreshed.gpuBackend == nil {
            refreshed.gpuBackend = preferredGPUBackend
        }
        if refreshed.adbAuthenticationMode == nil,
           let command = try? run(
               URL(fileURLWithPath: "/bin/ps"),
               ["-p", "\(identity.pid)", "-o", "command="],
               category: "runtime.identity.adb_auth_mode",
               timeout: 5
           ) {
            refreshed.adbAuthenticationMode = Self
                .emulatorADBAuthenticationMode(in: command)
        }
        refreshed.pidBirthIdentity = processBirthIdentity(
            pid: identity.pid
        )?.value
        let isCurrentChild = emulatorProcess?.processIdentifier == identity.pid
            && emulatorProcess?.isRunning == true
        if refreshed.runtimeSessionID == nil {
            refreshed.runtimeSessionID = UUID().uuidString
        }
        refreshed.appSessionID = Self.appSessionID
        refreshed.launchOrigin = isCurrentChild
            ? .currentLaunch : .adoptedExisting
        refreshed.terminationRequestedAt = nil
        refreshed.terminationRequestReason = nil
        return refreshed
    }

    private func requiresADBAuthenticationCompatibilityRelaunch(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        emulatorADBAuthenticationMode(for: toolchain)
            == .legacySkipAuthCompatibility
            && identity.adbAuthenticationMode
                != .legacySkipAuthCompatibility
    }

    private func verifyDeviceOwnership(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) -> Bool {
        guard let state = try? runADB(
            toolchain,
            ["-s", identity.serial, "get-state"]
        ), state.trimmingCharacters(in: .whitespacesAndNewlines) == "device",
        let avdOutput = try? runADB(
            toolchain,
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
        return try runADB(
            toolchain,
            ["-s", identity.serial] + arguments,
            category: category,
            timeout: timeout
        )
    }

    private func runVerifiedADBBinary(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain,
        _ arguments: [String],
        category: String,
        timeout: TimeInterval
    ) async throws -> Data {
        // The caller has just resolved this exact identity with
        // `ownedRuntime(for:)`. Avoid repeating the expensive ps/adb ownership
        // probes for every frame; the surface lease is checked again after the
        // await before a frame can be published.
        let startedAt = Date()
        do {
            let result = try await Self.executeBinaryProcess(
                toolchain.adb,
                Self.scopedADBArguments(
                    ["-s", identity.serial] + arguments,
                    serverPort: privateADBServerPort
                ),
                environment: childEnvironment(for: toolchain),
                timeout: timeout
            )
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let duration = Date().timeIntervalSince(startedAt)
            let exitCode: Int32 = result.timedOut ? -1 : result.exitCode
            recordCommand(
                timestamp: startedAt,
                category: category,
                exitCode: exitCode,
                stdout: "<binary \(result.stdout.count) bytes>",
                stderr: stderr,
                duration: duration,
                timedOut: result.timedOut
            )
            guard !result.timedOut, exitCode == 0 else {
                throw AndroidToolCommandError(
                    category: category,
                    exitCode: exitCode,
                    stdout: "<binary output omitted>",
                    stderr: sanitizedCommandOutput(
                        stderr,
                        category: category
                    ),
                    duration: duration,
                    timedOut: result.timedOut
                )
            }
            return result.stdout
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AndroidToolCommandError {
            throw error
        } catch {
            recordCommand(
                timestamp: startedAt,
                category: category,
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                duration: Date().timeIntervalSince(startedAt),
                timedOut: false
            )
            throw error
        }
    }

    static func emulatorSerials(in listing: String) -> [String] {
        Array(Set(listing.split(whereSeparator: \.isNewline).compactMap {
            rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let serial = String(fields[0])
            return serial.hasPrefix("emulator-") ? serial : nil
        })).sorted()
    }

    private func appendADBWaitObservation(
        identity: AndroidRuntimeIdentity,
        targetState: AndroidADBTargetState,
        observedEmulatorSerials: [String],
        adbDevices: [String],
        emulatorAlive: Bool,
        emulatorOwned: Bool,
        consolePortListening: Bool?,
        adbPortListening: Bool?
    ) {
        adbWaitTimeline.append(
            AndroidADBWaitObservation(
                timestamp: Date(),
                expectedSerial: identity.serial,
                targetState: targetState.rawValue,
                observedEmulatorSerials: observedEmulatorSerials,
                adbDevices: adbDevices,
                emulatorPID: identity.pid,
                emulatorAlive: emulatorAlive,
                emulatorOwned: emulatorOwned,
                consolePort: identity.consolePort,
                consolePortListening: consolePortListening,
                adbPort: identity.consolePort + 1,
                adbPortListening: adbPortListening
            )
        )
        if adbWaitTimeline.count > 80 {
            adbWaitTimeline.removeFirst(adbWaitTimeline.count - 80)
        }
    }

    private func emulatorPortStatus(
        _ identity: AndroidRuntimeIdentity
    ) -> (console: Bool?, adb: Bool?) {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else {
            return (nil, nil)
        }
        let output: String
        do {
            output = try run(
                lsof,
                [
                    "-nP", "-a", "-p", "\(identity.pid)",
                    "-iTCP", "-sTCP:LISTEN"
                ],
                category: "emulator.wait.listening_ports",
                timeout: 5
            )
        } catch let error as AndroidToolCommandError
            where error.exitCode == 1 && !error.timedOut {
            return (false, false)
        } catch {
            return (nil, nil)
        }
        return (
            output.contains(":\(identity.consolePort) (LISTEN)"),
            output.contains(":\(identity.consolePort + 1) (LISTEN)")
        )
    }

    private func deviceIsReachable(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain?
    ) -> Bool {
        guard let toolchain,
              let state = try? runADB(
                toolchain,
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
        // This is a private, app-owned emulator. The Bridge intentionally
        // targets API 27 because legacy TVBox/FongMi packages still discover
        // ActivityThread state through pre-28 reflection. Suppress Android's
        // generic deprecation sheet before the Activity starts so it can
        // never be mistaken for provider-owned UI.
        _ = try? runVerifiedADB(
            identity,
            toolchain: toolchain,
            [
                "shell", "setprop",
                "debug.wm.disable_deprecated_target_sdk_dialog", "true"
            ],
            category: "adb.bridge.compatibility_warning.suppress",
            timeout: 8
        )
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
        dismissDeprecatedTargetSDKWarningIfNeeded(
            identity,
            toolchain: toolchain
        )
    }

    private func dismissDeprecatedTargetSDKWarningIfNeeded(
        _ identity: AndroidRuntimeIdentity,
        toolchain: AndroidToolchain
    ) {
        // `am start` may return just before system_server attaches the warning
        // window. Retry the cheap window probe briefly; only inspect/tap the
        // UI hierarchy after the exact warning and Bridge package are found.
        for attempt in 0..<8 {
            if let windows = try? runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["shell", "dumpsys", "window", "windows"],
                category: "adb.bridge.compatibility_warning.window",
                timeout: 8
            ), AndroidDeprecatedTargetSDKWarningPolicy.shouldInspect(
                windowDump: windows
            ), let hierarchy = try? runVerifiedADB(
                identity,
                toolchain: toolchain,
                ["exec-out", "uiautomator", "dump", "/dev/tty"],
                category: "adb.bridge.compatibility_warning.ui",
                timeout: 8
            ), let point = AndroidDeprecatedTargetSDKWarningPolicy
                .dismissalPoint(uiHierarchy: hierarchy),
               (try? runVerifiedADB(
                    identity,
                    toolchain: toolchain,
                    ["shell", "input", "tap", "\(point.x)", "\(point.y)"],
                    category: "adb.bridge.compatibility_warning.dismiss",
                    timeout: 8
               )) != nil {
                appendEvent(
                    stage: .launchingBridge,
                    event: "compatibility_warning_dismissed",
                    detail: "dismissed the Bridge target-SDK warning on the owned emulator"
                )
                return
            }
            if attempt < 7 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
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
        toolchain: AndroidToolchain,
        reason: String = "startupFailureCleanup",
        allowVerifiedSIGKILL: Bool = false
    ) async -> Bool {
        appendEvent(
            stage: currentStage,
            event: "startupCleanupStart",
            detail: reason
        )
        defer {
            appendEvent(
                stage: currentStage,
                event: "startupCleanupEnd",
                detail: reason
            )
        }
        let observation = observeRuntimeOwnership(
            identity,
            toolchain: toolchain
        )
        switch observation.decision {
        case let .clearStaleRecord(reason):
            appendStaleRecordRecovery(reason)
            clearRuntimeRecord()
            return true
        case .rejectConflictingRuntime:
            return false
        case .reuseOwnedRuntime:
            break
        }
        guard verifyStrictProcessOwnership(identity, toolchain: toolchain)
        else {
            lastLifecycleConflictReason =
                "启动失败清理前未通过 PID 出生标识与私有 AVD 文件校验"
            return false
        }
        recordEmulatorTerminationRequest(
            pid: identity.pid,
            reason: reason
        )
        if !observation.deviceOwned {
            _ = Darwin.kill(identity.pid, SIGTERM)
            let attempts = allowVerifiedSIGKILL ? 80 : 20
            for _ in 0..<attempts {
                if processExecutablePath(pid: identity.pid) == nil {
                    clearRuntimeRecord()
                    return true
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if allowVerifiedSIGKILL,
               verifyStrictProcessOwnership(identity, toolchain: toolchain) {
                _ = Darwin.kill(identity.pid, SIGKILL)
                for _ in 0..<20 {
                    if processExecutablePath(pid: identity.pid) == nil {
                        clearRuntimeRecord()
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
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
        if verifyStrictProcessOwnership(identity, toolchain: toolchain) {
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

    private func recordEmulatorTerminationRequest(
        pid: Int32,
        reason: String
    ) {
        guard let recorder = emulatorProcessRecorder,
              recorder.snapshot().pid == pid else { return }
        recorder.recordTerminationRequestedByApp(reason)
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
        actionSurfaceLease = nil
        managedDisplayConfigured = false
        for handle in emulatorOutputHandles {
            try? handle.close()
        }
        emulatorOutputHandles = []
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
        let stdoutReader = AndroidProcessPipeReader(
            standardOutput.fileHandleForReading
        )
        let stderrReader = AndroidProcessPipeReader(
            standardError.fileHandleForReading
        )
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var finished = false
        var cancelled = false
        while !finished, Date() < deadline {
            finished = completed.wait(timeout: .now() + 0.1) == .success
            if !finished, Task.isCancelled {
                cancelled = true
                break
            }
        }
        let timedOut = !finished && !cancelled
        if (timedOut || cancelled), process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        let stdoutData = stdoutReader.result()
        let stderrData = stderrReader.result()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startedAt)
        let exitCode: Int32 = (timedOut || cancelled)
            ? -1 : process.terminationStatus
        recordCommand(
            timestamp: startedAt,
            category: category,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            duration: duration,
            timedOut: timedOut
        )
        if cancelled {
            throw CancellationError()
        }
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

    /// Runs an Android tool whose stdout is arbitrary bytes. Both pipes are
    /// drained concurrently into memory so a verbose stderr cannot deadlock a
    /// screen capture. Cancellation and timeout terminate the child process;
    /// no frame bytes are ever written to a temporary file.
    private nonisolated static func executeBinaryProcess(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> AndroidBinaryProcessOutput {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        let termination = AndroidProcessTerminationWaiter()
        let handle = AndroidBinaryProcessHandle(process: process)
        termination.install(on: process)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try process.run()
            } catch {
                try? standardOutput.fileHandleForReading.close()
                try? standardOutput.fileHandleForWriting.close()
                try? standardError.fileHandleForReading.close()
                try? standardError.fileHandleForWriting.close()
                throw error
            }
            handle.processDidStart()

            // Detached readers prevent either pipe from applying backpressure
            // to adb while the actor remains available to supersede the lease.
            let stdoutTask = Task.detached(priority: .utility) {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached(priority: .utility) {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }
            let nanoseconds = UInt64(
                min(max(timeout, 0.001), 3_600) * 1_000_000_000
            )
            let timedOut = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = await termination.wait()
                    return false
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return false
                    }
                    handle.requestStop()
                    return true
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            let status = await termination.wait()
            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value
            try Task.checkCancellation()
            return AndroidBinaryProcessOutput(
                stdout: stdout,
                stderr: stderr,
                exitCode: status,
                timedOut: timedOut
            )
        } onCancel: {
            handle.requestStop()
        }
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
        // Transport polling is summarized separately by state change and a
        // five-second cadence. Do not let hundreds of identical device-list
        // samples evict reconnect/server/boot evidence from this ring.
        if category == "adb.wait.devices" { return }
        let isDiagnosticEvidence = category.hasPrefix("diagnostic.")
            || category.hasPrefix("adb.server.")
            || category.hasPrefix("adb.network.")
            || category.hasPrefix("adb.boot.")
            || category.hasPrefix("adb.bridge.")
            || category.hasPrefix("adb.forward.")
            || category.hasPrefix("adb.wait.")
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
        if category == "diagnostic.adb.devices"
            || category == "adb.wait.devices" {
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
