import Darwin
import AppKit
import CryptoKit
import Foundation
import OKVideoCore

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
    case adbDeviceMissing
    case adbDeviceOffline
    case emulatorLaunchFailed
    case emulatorLaunchTimedOut
    case emulatorExitedEarly
    case emulatorOwnershipMismatch
    case emulatorRuntimeConflict
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
        case .javaRuntimeMissing:
            return "创建专用 Android 环境需要 Java Runtime。请安装 JDK，或安装包含 JBR 的 Android Studio。"
        case .adbUnavailable:
            return "ADB 无法使用，无法连接专用 Android Emulator。"
        case .adbDeviceMissing:
            return "Android Emulator 仍在运行，但 ADB 未发现目标设备。"
        case .adbDeviceOffline:
            return "ADB 已发现专用 Android Emulator，但设备一直处于 offline 状态。"
        case .emulatorLaunchFailed, .emulatorLaunchTimedOut,
             .emulatorExitedEarly, .runtimeExited:
            return "Android Emulator 未能正常启动，请导出诊断后重试。"
        case .emulatorOwnershipMismatch:
            return "无法安全确认专用 Android Emulator，已停止操作其他设备。"
        case .emulatorRuntimeConflict:
            return "检测到其他 Emulator 正在使用专用 AVD 或记录端口，未执行任何操作。"
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
    private let session: URLSession
    private let interactionSession: URLSession
    private let invokeURL = URL(string: "http://127.0.0.1:19978/v1/invoke")!
    private let uiStateURL = URL(string: "http://127.0.0.1:19978/v1/ui/state")!
    private let uiDismissURL = URL(string: "http://127.0.0.1:19978/v1/ui/dismiss")!

    init(runtime: AndroidDexBridgeRuntime = AndroidDexBridgeRuntime()) {
        self.runtime = runtime
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
        for image: AndroidSystemImage
    ) -> String {
        let updates = [
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "host",
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

    func resolveJavaRuntime() -> AndroidJavaRuntime? {
        AndroidJavaRuntimeResolver(
            homeDirectory: homeDirectory,
            environment: environment,
            fileManager: fileManager
        ).resolve()
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
    let avdName: String
    let avdDirectory: URL
    let pid: Int32
    let consolePort: Int
    let serial: String
    let forwards: [AndroidPortForwardIdentity]
    let launchedAt: Date
}

enum AndroidADBTargetState: String, Equatable, Sendable {
    case missing
    case device
    case offline
    case unauthorized
    case unknown
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
        terminationRequestReason = reason
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

actor AndroidDexBridgeRuntime {
    static let bridgeVersion = "0.3.44"
    static let bridgeVersionCode = 56
    static let bridgeApplicationID = "com.okvideomac.dexbridge"
    static let bridgeCertificateSHA256 =
        "33e95ef23b662f2629a23df892aaff52ae6216f7492cfb559a63d37247a059e0"
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
    private let continuityURL: URL
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL
    private let currentBootIdentifier: String
    private var userSelectedSDKRoot: String?
    private var emulatorProcess: Process?
    private var emulatorOutputHandles: [FileHandle] = []
    private var emulatorProcessRecorder: AndroidEmulatorProcessRecorder?
    private var ready = false
    private var acceptsNewerBridge = false
    private var managedDisplayConfigured = false
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
        continuityURL = runtimeDirectory.appendingPathComponent(
            "runtime-continuity.json"
        )
        backupDirectory = runtimeDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        self.fileManager = fileManager
        self.defaults = defaults
        baseEnvironment = environment
        homeDirectory = fileManager.homeDirectoryForCurrentUser
        currentBootIdentifier = Self.systemBootIdentifier()
        userSelectedSDKRoot = defaults.string(
            forKey: AndroidToolchainResolver.userSDKRootDefaultsKey
        )
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
        _ = try run(
            toolchain.adb,
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
        _ = try run(
            toolchain.adb,
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
        _ = try run(
            toolchain.adb,
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
        _ = try run(
            toolchain.adb,
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
            return .emulatorRuntimeConflict
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
        deviceOwned: Bool
    ) -> AndroidRuntimeFailureCategory? {
        if !processPresent {
            return .emulatorExitedEarly
        }
        if !processOwned {
            return .emulatorRuntimeConflict
        }
        switch targetState {
        case .missing:
            return .adbDeviceMissing
        case .offline:
            return .adbDeviceOffline
        case .unauthorized, .unknown:
            return .adbUnavailable
        case .device:
            return deviceOwned ? nil : .emulatorOwnershipMismatch
        }
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
            if let observedState = try? run(
                toolchain.adb,
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
            emulatorLaunchAt: emulatorSnapshot?.launchAt,
            emulatorExitAt: emulatorSnapshot?.exitAt,
            emulatorLifetime: emulatorSnapshot?.lifetime,
            emulatorTerminationStatus: emulatorSnapshot?.terminationStatus,
            emulatorTerminationReason: emulatorSnapshot?.terminationReason,
            emulatorTerminationRequestedByApp: emulatorSnapshot?
                .terminationRequestedByApp ?? false,
            emulatorTerminationRequestReason: emulatorSnapshot?
                .terminationRequestReason,
            emulatorStdoutTail: emulatorSnapshot.flatMap {
                emulatorLogTail(at: $0.stdoutURL)
            },
            emulatorStderrTail: emulatorSnapshot.flatMap {
                emulatorLogTail(at: $0.stderrURL)
            },
            emulatorArguments: emulatorSnapshot?.arguments ?? [],
            emulatorEnvironment: emulatorSnapshot?.environment ?? [:],
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
        actionSurfaceLease = nil
        managedDisplayConfigured = false
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
        guard let toolchain = resolver().toolchain(at: identity.sdkRoot) else {
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
        let observation = observeRuntimeOwnership(
            identity,
            toolchain: toolchain
        )
        switch observation.decision {
        case let .clearStaleRecord(reason):
            appendStaleRecordRecovery(reason)
            clearRuntimeRecord()
            return
        case .rejectConflictingRuntime:
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
            if !observation.deviceOwned {
                recordEmulatorTerminationRequest(
                    pid: identity.pid,
                    reason: "userRequestedStop"
                )
                _ = Darwin.kill(identity.pid, SIGTERM)
                for _ in 0..<20 {
                    if processExecutablePath(pid: identity.pid) == nil {
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
                return
            }
        }
        do {
            recordEmulatorTerminationRequest(
                pid: identity.pid,
                reason: "userRequestedStop"
            )
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
            try await prepareRuntime()
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
                try await prepareRuntime()
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
                guard var recorded = loadIdentity() else {
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
                let observation = observeRuntimeOwnership(
                    recorded,
                    toolchain: recordedToolchain
                )
                switch observation.decision {
                case .reuseOwnedRuntime:
                    if recorded.systemBootIdentifier != currentBootIdentifier {
                        recorded.systemBootIdentifier = currentBootIdentifier
                        try saveIdentity(recorded)
                    }
                    activeIdentity = recorded
                    activeToolchain = recordedToolchain
                case let .clearStaleRecord(reason):
                    appendStaleRecordRecovery(reason)
                    if reason == .previousSystemBoot {
                        operationStatus = .starting(
                            "检测到电脑重启后的旧运行记录，正在重新连接。",
                            progress: AndroidRuntimeStartupStage.locatingSDK.progress
                                ?? 0
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
                guard !runtimeProcessReferencesAVD(
                    named: Self.avdName
                ) else {
                    throw AndroidRuntimeFailureError(
                        record: AndroidRuntimeFailureRecord(
                            occurredAt: Date(),
                            stage: .launchingEmulator,
                            category: .emulatorRuntimeConflict,
                            message: "检测到另一个进程正在使用 OKVideoMac 专用 AVD，未重复启动"
                        )
                    )
                }
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
        }
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

    private func childEnvironment(
        for toolchain: AndroidToolchain
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["ANDROID_HOME"] = toolchain.sdkRoot.path
        environment.removeValue(forKey: "ANDROID_SDK_ROOT")
        environment["ANDROID_AVD_HOME"] = avdHome.path
        return environment
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
        var safe = LogRedactor.text(text)
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
            let contents = try String(
                contentsOf: configuration,
                encoding: .utf8
            )
            guard let image = resolver().preferredInteractiveSystemImage(
                in: toolchain,
                avdConfiguration: contents
            ) else {
                throw AppError.spider(
                    "缺少可显示原生界面的 arm64 Android system image（ATD 不支持界面捕获）"
                )
            }
            let updated = AndroidManagedAVDConfiguration.updating(
                contents,
                for: image
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
        guard let image = resolver().interactiveSystemImages(
            in: toolchain
        ).first else {
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
            for: image
        )
        if updated != contents {
            try Data(updated.utf8).write(
                to: configuration,
                options: [.atomic]
            )
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
            let arguments = [
                "-avd", Self.avdName,
                "-port", "\(consolePort)",
                "-no-window",
                "-no-audio",
                "-no-boot-anim",
                "-no-metrics",
                "-no-snapshot",
                "-gpu", "host",
                "-accel", "on"
            ]
            let environment = childEnvironment(for: toolchain)
            let launchAt = Date()
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
            for _ in 0..<20 where process.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if !process.isRunning {
                try? stdout.close()
                try? stderr.close()
                let output = [
                    emulatorLogTail(at: stderrURL),
                    emulatorLogTail(at: stdoutURL)
                ].compactMap { $0 }.joined(separator: "\n")
                if Self.isEmulatorPortConflict(output) {
                    continue
                }
                if Self.isEmulatorAVDConflict(output) {
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

            emulatorProcess = process
            emulatorOutputHandles = [stdout, stderr]
            let identity = AndroidRuntimeIdentity(
                schema: Self.manifestSchema,
                generation: generation,
                systemBootIdentifier: currentBootIdentifier,
                sdkRoot: toolchain.sdkRoot,
                emulatorExecutable: toolchain.emulator,
                avdName: Self.avdName,
                avdDirectory: avdDirectory,
                pid: process.processIdentifier,
                consolePort: consolePort,
                serial: "emulator-\(consolePort)",
                forwards: Self.expectedForwards,
                launchedAt: launchAt
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
            guard processExecutablePath(pid: identity.pid) != nil else {
                throw AndroidRuntimeFailureError(
                    record: AndroidRuntimeFailureRecord(
                        occurredAt: Date(),
                        stage: .waitingForADB,
                        category: .emulatorExitedEarly,
                        message: "Android Emulator 在接入 ADB 前已退出"
                    )
                )
            }
            if try validateManagedRuntime(
                identity,
                toolchain: toolchain,
                deviceRequired: false
            ) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let listing = (try? run(
            toolchain.adb,
            ["devices", "-l"],
            category: "adb.wait.devices",
            timeout: 5
        )) ?? ""
        let state = Self.adbTargetState(
            in: listing,
            serial: identity.serial
        )
        let processPresent = processExecutablePath(pid: identity.pid) != nil
        let processOwned = processPresent
            && verifyProcessOwnership(identity, toolchain: toolchain)
        let deviceOwned = state == .device
            && verifyDeviceOwnership(identity, toolchain: toolchain)
        guard let category = Self.waitingForADBFailureCategory(
            processPresent: processPresent,
            processOwned: processOwned,
            targetState: state,
            deviceOwned: deviceOwned
        ) else { return }
        let message: String
        switch category {
        case .emulatorExitedEarly:
            message = "Android Emulator 在接入 ADB 前已退出"
        case .emulatorRuntimeConflict:
            message = "Android Emulator PID 已不属于本次启动的专用实例"
        case .adbDeviceMissing:
            message = "Android Emulator 进程仍在运行，但 ADB 未在限定时间内发现目标设备"
        case .adbDeviceOffline:
            message = "ADB 已发现专用 Android Emulator，但设备一直处于 offline 状态"
        case .emulatorOwnershipMismatch:
            message = "ADB 设备已连接，但 AVD 名称与专用运行记录不匹配"
        case .adbUnavailable:
            message = "ADB 目标设备状态异常（\(state.rawValue)）"
        default:
            message = "Android Emulator 接入 ADB 失败"
        }
        throw AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: .waitingForADB,
                category: category,
                message: message
            )
        )
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
                    ? .emulatorExitedEarly : .runtimeExited
            case .previousSystemBoot:
                category = .runtimeExited
            case .pidReused:
                category = .emulatorRuntimeConflict
            }
        case .rejectConflictingRuntime:
            category = observation.deviceReachable && !observation.deviceOwned
                ? .emulatorOwnershipMismatch : .emulatorRuntimeConflict
        }
        guard let category else {
            return observation.deviceOwned
        }

        let message: String
        switch category {
        case .emulatorExitedEarly:
            message = "Android Emulator 在接入 ADB 前已退出"
        case .runtimeExited:
            message = "专用 Android Emulator 进程已退出"
        case .adbUnavailable:
            message = "专用 Android Emulator 设备已断开"
        case .adbDeviceMissing:
            message = "Android Emulator 进程仍在运行，但 ADB 未发现目标设备"
        case .adbDeviceOffline:
            message = "ADB 目标设备处于 offline 状态"
        case .emulatorOwnershipMismatch:
            message = "专用 Android Emulator 所有权校验失败；已拒绝继续操作"
        case .emulatorRuntimeConflict:
            message = "检测到其他 Emulator 使用了记录端口，未执行任何操作"
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
                ["-s", identity.serial] + arguments,
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
        toolchain: AndroidToolchain
    ) async -> Bool {
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
        recordEmulatorTerminationRequest(
            pid: identity.pid,
            reason: "startupFailureCleanup"
        )
        if !observation.deviceOwned {
            _ = Darwin.kill(identity.pid, SIGTERM)
            for _ in 0..<20 {
                if processExecutablePath(pid: identity.pid) == nil {
                    clearRuntimeRecord()
                    return true
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
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

    /// Runs an Android tool whose stdout is arbitrary bytes. Both pipes are
    /// drained concurrently into memory so a verbose stderr cannot deadlock a
    /// screen capture. Cancellation and timeout terminate the child process;
    /// no frame bytes are ever written to a temporary file.
    private nonisolated static func executeBinaryProcess(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> AndroidBinaryProcessOutput {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
        let isDiagnosticEvidence = category.hasPrefix("diagnostic.")
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
