import CryptoKit
import Foundation
import OKVideoCore

private actor NodeSiteInitializationGate {
    private enum State {
        case initializing([CheckedContinuation<Void, Error>])
        case initialized
    }

    private var states: [String: State] = [:]

    func ensureInitialized(
        at baseURL: URL,
        using operation: () async throws -> Void
    ) async throws {
        let endpointKey = baseURL.absoluteString
        switch states[endpointKey] {
        case .initialized:
            return
        case .initializing:
            try await withCheckedThrowingContinuation { continuation in
                guard case .initializing(var waiters) = states[endpointKey] else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                states[endpointKey] = .initializing(waiters)
            }
            return
        case nil:
            states[endpointKey] = .initializing([])
        }

        do {
            try await operation()
            let waiters = waiters(for: endpointKey)
            states[endpointKey] = .initialized
            waiters.forEach { $0.resume() }
        } catch {
            let waiters = waiters(for: endpointKey)
            states.removeValue(forKey: endpointKey)
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func waiters(
        for endpointKey: String
    ) -> [CheckedContinuation<Void, Error>] {
        guard case .initializing(let waiters) = states[endpointKey] else {
            return []
        }
        return waiters
    }
}

struct NodeRuntimeUnavailableSiteProvider: SiteProvider {
    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider
    let reason: String

    func home() async throws -> SiteHome { throw error }
    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage { throw error }
    func detail(id: String) async throws -> VideoDetail { throw error }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        throw error
    }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        throw error
    }
    func action(_ action: String) async throws -> JSONValue { throw error }

    private var error: NodeBundleRuntimeError {
        .endpointUnavailable(reason)
    }
}

struct NodeWebAuthorizationRequired: Error, LocalizedError, Equatable {
    let websiteURL: URL
    let title: String
    let message: String

    var errorDescription: String? { message }
}

protocol QuarkPasscodeStoring {
    func passcode(for account: String) -> String?

    @discardableResult
    func store(_ passcode: String, for account: String) -> Bool
}

struct QuarkPasscodeDisabledStore: QuarkPasscodeStoring {
    func passcode(for _: String) -> String? { nil }
    func store(_: String, for _: String) -> Bool { false }
}

/// The downloaded Node bundle owns the meaning of an episode value, but many
/// Contract-B bundles do not yet publish an explicit durable resource
/// descriptor. Keep that opaque input in Keychain and expose only a versioned
/// digest to history. This lets the same Node provider recreate a fresh media
/// URL/proxy session without persisting signed URLs, cookies or play tokens.
struct NodePlaybackReplay: Codable, Equatable {
    let flag: String
    let episodeURL: String
}

protocol NodePlaybackReplayStoring {
    func replay(for locator: String) -> NodePlaybackReplay?

    @discardableResult
    func store(_ replay: NodePlaybackReplay, for locator: String) -> Bool

    @discardableResult
    func removeReplay(for locator: String) -> Bool
}

struct NodePlaybackDisabledReplayStore: NodePlaybackReplayStoring {
    func replay(for _: String) -> NodePlaybackReplay? { nil }
    func store(_: NodePlaybackReplay, for _: String) -> Bool { false }
    func removeReplay(for _: String) -> Bool { false }
}

enum NodePlaybackReplayReference {
    static let prefix = "nhr1"
    private static let maximumFlagByteCount = 4_096
    private static let maximumEpisodeByteCount = 65_536

    static func locator(
        configurationIdentity: String,
        siteIdentity: String,
        replay: NodePlaybackReplay
    ) -> String? {
        guard !replay.flag.isEmpty,
              !replay.episodeURL.isEmpty,
              replay.flag.utf8.count <= maximumFlagByteCount,
              replay.episodeURL.utf8.count <= maximumEpisodeByteCount else {
            return nil
        }
        var data = Data()
        for value in [
            configurationIdentity,
            siteIdentity,
            replay.flag,
            replay.episodeURL
        ] {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix).\(digest)"
    }

    static func isLocator(_ value: String) -> Bool {
        guard value.hasPrefix("\(prefix).") else { return false }
        let digest = value.dropFirst(prefix.count + 1)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

/// Provider-published stable locators may still be credentials (for example a
/// refresh token or JWT). Persist only this configuration/site/provider-bound
/// digest; the original value remains in the ThisDeviceOnly replay store.
enum NodeProviderLocatorReference {
    static let prefix = "npr1"
    private static let providerKind = "node-http-spider"
    private static let maximumLocatorByteCount = 65_536

    static func locator(
        configurationIdentity: String,
        siteIdentity: String,
        schemaVersion: Int,
        providerVersion: Int,
        replay: NodePlaybackReplay
    ) -> String? {
        guard !replay.flag.isEmpty,
              !replay.episodeURL.isEmpty,
              replay.episodeURL.utf8.count <= maximumLocatorByteCount else {
            return nil
        }
        var data = Data()
        for value in [
            configurationIdentity,
            siteIdentity,
            providerKind,
            String(schemaVersion),
            String(providerVersion),
            replay.flag,
            replay.episodeURL
        ] {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix).\(digest)"
    }

    static func isLocator(_ value: String) -> Bool {
        guard value.hasPrefix("\(prefix).") else { return false }
        let digest = value.dropFirst(prefix.count + 1)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

/// The Node bundle embeds Quark's short-lived share authorization inside the
/// opaque episode URL. Keep the codec in the host app so an expired `stoken`
/// can be refreshed without modifying a downloaded third-party bundle.
enum QuarkEpisodeReference {
    struct Identity: Equatable {
        let providerID: String
        let shareID: String
        let fileID: String
    }

    static let shareTokenURL = URL(
        string: "https://drive.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    )!

    /// URL-free and JSON-free so the durable locator passes the shared
    /// persistence boundary. Each identity component is UTF-8 hex encoded;
    /// the prefix carries the schema version without exposing credentials.
    static let durableReferencePrefix = "qhr1"

    static func identity(from rawValue: String) -> Identity? {
        guard let payload = payload(from: rawValue),
              payload.providerID.caseInsensitiveCompare("quark") == .orderedSame,
              !payload.shareID.isEmpty,
              !payload.fileID.isEmpty else {
            return nil
        }
        return Identity(
            providerID: payload.providerID.lowercased(),
            shareID: payload.shareID,
            fileID: payload.fileID
        )
    }

    static func requiresShareTokenRefresh(_ rawValue: String) -> Bool {
        guard let payload = payload(from: rawValue),
              payload.providerID.caseInsensitiveCompare("quark") == .orderedSame else {
            return false
        }
        return payload.stoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func replacingStoken(
        in rawValue: String,
        with stoken: String
    ) throws -> String {
        guard let identity = identity(from: rawValue) else {
            throw AppError.playback("夸克分集令牌格式无效，无法刷新分享授权")
        }
        let normalizedStoken = stoken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedStoken.isEmpty else {
            throw AppError.playback("夸克分享令牌编码失败")
        }

        // Rebuild the smallest token understood by Node /play. Never copy
        // arbitrary fields from a historical/runtime playToken into a new
        // capability.
        let token: [String: Any] = [
            "fid": identity.fileID,
            "shareId": identity.shareID,
            "stoken": normalizedStoken
        ]
        let tokenData = try JSONSerialization.data(
            withJSONObject: token,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let tokenString = String(data: tokenData, encoding: .utf8) else {
            throw AppError.playback("夸克分享令牌编码失败")
        }
        let outer: [String: Any] = [
            "fileId": identity.fileID,
            "playToken": tokenString,
            "providerId": identity.providerID,
            "shareId": identity.shareID
        ]
        let data = try JSONSerialization.data(
            withJSONObject: outer,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.base64EncodedString()
    }

    /// History keeps only the versioned provider/share/file identity. Share
    /// passcodes and all runtime capability fields remain Spider-owned and are
    /// never copied into host persistence.
    static func durableHistoryReference(
        _ rawValue: String,
        passcodeStore _: QuarkPasscodeStoring = QuarkPasscodeDisabledStore()
    ) -> String {
        guard let identity = identity(from: rawValue) else { return rawValue }
        return durableReference(for: identity)
    }

    static func passcode(from rawValue: String) -> String {
        embeddedPasscode(from: rawValue) ?? ""
    }

    static func durableHistoryReference(
        _ description: ProviderPlaybackStableDescription
    ) -> String? {
        guard description.provider.caseInsensitiveCompare("quark") == .orderedSame,
              !description.shareID.isEmpty,
              !description.fileID.isEmpty else {
            return nil
        }
        return durableReference(
            for: Identity(
                providerID: "quark",
                shareID: description.shareID,
                fileID: description.fileID
            )
        )
    }

    static func credentialAccount(for identity: Identity) -> String {
        let identityData = Data(
            [
                durableReferencePrefix,
                identity.providerID.lowercased(),
                identity.shareID,
                identity.fileID
            ]
                .joined(separator: "\u{0}")
                .utf8
        )
        return SHA256.hash(data: identityData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func embeddedPasscode(from rawValue: String) -> String? {
        guard let outerData = Data(
            base64Encoded: rawValue,
            options: .ignoreUnknownCharacters
        ),
        let outer = try? JSONSerialization.jsonObject(with: outerData)
            as? [String: Any] else {
            return nil
        }
        if let value = firstPresentString(
            in: outer,
            keys: ["passcode", "passCode", "password", "pwd"]
        ) {
            return value
        }
        guard let playToken = outer["playToken"] as? String,
              let token = try? JSONSerialization.jsonObject(
                with: Data(playToken.utf8)
              ) as? [String: Any] else {
            return nil
        }
        return firstPresentString(
            in: token,
            keys: ["passcode", "passCode", "password", "pwd"]
        )
    }

    private struct Payload {
        let providerID: String
        let shareID: String
        let fileID: String
        let stoken: String
    }

    private static func payload(from rawValue: String) -> Payload? {
        if let durablePayload = durablePayload(from: rawValue) {
            return durablePayload
        }
        guard let data = Data(
            base64Encoded: rawValue,
            options: .ignoreUnknownCharacters
        ),
        let outer = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
        let providerID = outer["providerId"] as? String,
        let playToken = outer["playToken"] as? String,
        let token = try? JSONSerialization.jsonObject(
            with: Data(playToken.utf8)
        ) as? [String: Any] else {
            return nil
        }
        let shareID = (outer["shareId"] as? String)
            ?? (token["shareId"] as? String)
            ?? ""
        let fileID = (outer["fileId"] as? String)
            ?? (token["fid"] as? String)
            ?? ""
        return Payload(
            providerID: providerID,
            shareID: shareID,
            fileID: fileID,
            stoken: token["stoken"] as? String ?? ""
        )
    }

    private static func durableReference(for identity: Identity) -> String {
        [
            durableReferencePrefix,
            hexEncoded(identity.providerID.lowercased()),
            hexEncoded(identity.shareID),
            hexEncoded(identity.fileID)
        ].joined(separator: ".")
    }

    private static func durablePayload(from rawValue: String) -> Payload? {
        let components = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == Substring(durableReferencePrefix),
              let providerID = hexDecoded(components[1]),
              let shareID = hexDecoded(components[2]),
              let fileID = hexDecoded(components[3]),
              !providerID.isEmpty,
              !shareID.isEmpty,
              !fileID.isEmpty else {
            return nil
        }
        return Payload(
            providerID: providerID,
            shareID: shareID,
            fileID: fileID,
            stoken: ""
        )
    }

    private static func hexEncoded(_ value: String) -> String {
        Data(value.utf8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func hexDecoded(_ value: Substring) -> String? {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return String(data: bytes, encoding: .utf8)
    }

    private static func firstPresentString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

final class NodeHTTPSpiderSiteProvider: SiteProvider {
    private struct HostMessage: Decodable {
        struct Options: Decodable {
            let url: String
        }

        let action: String
        let opt: Options
    }

    private struct InvocationResult {
        let value: JSONValue
        let baseURL: URL
        let hostMessage: HostMessage?
    }

    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)?
    private let ensureRuntimeReady: (@Sendable () async throws -> URL)?
    private let configurationIdentity: String?
    private let initializationGate = NodeSiteInitializationGate()

    var configurationWebsiteURL: URL {
        baseURL.appendingPathComponent("website")
    }

    static func canHandle(site: SiteConfiguration, baseURL: URL?) -> Bool {
        guard (site.type == 3 || site.type == 4),
              site.extra["okNodeRuntime"] == .bool(true),
              site.api.contains("/spider/"),
              let baseURL,
              baseURL.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                baseURL.host?.lowercased() ?? ""
              ) else {
            return false
        }
        return true
    }

    init(
        site: SiteConfiguration,
        baseURL: URL,
        httpClient: HTTPClient,
        diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)? = nil,
        ensureRuntimeReady: (@Sendable () async throws -> URL)? = nil,
        quarkPasscodeStore: QuarkPasscodeStoring = QuarkPasscodeDisabledStore(),
        playbackReplayStore: NodePlaybackReplayStoring =
            NodePlaybackDisabledReplayStore(),
        configurationIdentity: String? = nil
    ) throws {
        guard Self.canHandle(site: site, baseURL: baseURL) else {
            throw AppError.spider("NodeHTTPSpiderSiteProvider 站点配置无效")
        }
        self.site = site
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.diagnosticReporter = diagnosticReporter
        self.ensureRuntimeReady = ensureRuntimeReady
        _ = quarkPasscodeStore
        _ = playbackReplayStore
        let normalizedConfigurationIdentity = configurationIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.configurationIdentity = normalizedConfigurationIdentity?.isEmpty == false
            ? normalizedConfigurationIdentity
            : nil
    }

    func home() async throws -> SiteHome {
        let home = try await invoke(
            method: "home",
            body: ["filter": .bool(true)],
            maximumAttempts: 2
        )
        let homeVideo = try? await invoke(
            method: "homeVod",
            body: [:],
            maximumAttempts: 2
        )
        let result = try SpiderResponseMapper.home(
            home.value,
            homeVideoValue: homeVideo?.value,
            site: site,
            baseURL: home.baseURL
        )
        guard !site.categories.isEmpty else { return result }
        let allowed = Set(site.categories)
        return SiteHome(
            categories: result.categories.filter { allowed.contains($0.name) },
            recommendations: result.recommendations,
            actionItems: result.actionItems
        )
    }

    func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try await category(
            id: id,
            page: page,
            filters: filters,
            awaitsHostAction: false
        )
    }

    func actionCategory(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        try await category(
            id: id,
            page: page,
            filters: filters,
            awaitsHostAction: true
        )
    }

    private func category(
        id: String,
        page: Int,
        filters: [String: String],
        awaitsHostAction: Bool
    ) async throws -> VideoPage {
        let values = filters.mapValues(JSONValue.string)
        let invocation = try await invoke(
            method: "category",
            body: [
                "id": .string(id),
                "tid": .string(id),
                "page": .string(String(page)),
                "pg": .string(String(page)),
                "filter": .bool(true),
                "extend": .object(values),
                "filters": .object(values)
            ],
            maximumAttempts: 2,
            hostMessageWaitMilliseconds: awaitsHostAction ? 1_000 : 0
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(hostMessage: hostMessage)
        }
        if awaitsHostAction {
            return try SpiderResponseMapper.actionPage(
                invocation.value,
                site: site,
                baseURL: invocation.baseURL,
                page: page
            )
        }
        return try SpiderResponseMapper.page(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            page: page
        )
    }

    func detail(id: String) async throws -> VideoDetail {
        switch try await select(id: id) {
        case .detail(let detail): return detail
        case .action:
            throw AppError.spider("该卡片执行的是设置操作，不包含影视详情")
        case .search:
            throw AppError.spider("该卡片只提供发现信息，不包含影视详情")
        }
    }

    func select(id: String) async throws -> SiteSelectionResult {
        try await select(id: id, fallbackSummary: nil)
    }

    func select(summary: VideoSummary) async throws -> SiteSelectionResult {
        try await select(
            id: summary.videoID,
            fallbackSummary: summary,
            awaitsHostAction: summary.resolvedContentKind == .action
        )
    }

    func select(action item: SiteActionItem) async throws -> SiteSelectionResult {
        switch item.resolvedRoute {
        case .actionCategory:
            throw AppError.spider("配置分类必须先加载操作列表，不能作为影视详情打开")
        case .command(let action):
            return .action(try await self.action(action))
        case .providerSelection(let itemID):
            return try await select(
                id: itemID,
                fallbackSummary: item.selectionSummary,
                awaitsHostAction: true
            )
        }
    }

    private func select(
        id: String,
        fallbackSummary: VideoSummary?,
        awaitsHostAction: Bool = false
    ) async throws -> SiteSelectionResult {
        let invocation = try await invoke(
            method: "detail",
            body: [
                "id": .string(id),
                "ids": .array([.string(id)])
            ],
            maximumAttempts: 2,
            hostMessageWaitMilliseconds: awaitsHostAction ? 1_000 : 0
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(
                hostMessage: hostMessage
            )
        }
        let selection = try SpiderResponseMapper.selection(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            fallbackSummary: fallbackSummary,
            allowsPlaceholderAction:
                fallbackSummary?.resolvedContentKind == .action
        )
        return attachDurableEpisodeReferences(to: selection)
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        guard site.searchable != 0, !quick || site.quickSearch == 1 else {
            return VideoPage(
                items: [],
                pagination: Pagination(page: page, pageCount: 0)
            )
        }
        let invocation = try await invoke(
            method: "search",
            body: [
                "wd": .string(keyword),
                "key": .string(keyword),
                "quick": .bool(quick),
                "page": .string(String(page)),
                "pg": .string(String(page))
            ],
            // A first-pass aggregate search must invoke each CatPawOpen route
            // exactly once. Retrying here occupies another Node worker and
            // delays sites that have not received their first request yet.
            maximumAttempts: 1
        )
        let result = try SpiderResponseMapper.page(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            page: page
        )
        if result.items.isEmpty,
           let message = Self.serverMessage(from: invocation.value),
           Self.isUpstreamUnavailableMessage(message) {
            throw SiteSearchError(
                "\(site.name) 搜索失败：\(message)",
                category: .upstreamUnavailable
            )
        }
        return result
    }

    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        var resolvedEpisodeURL = episodeURL
        var refreshedShareToken = false
        if QuarkEpisodeReference.requiresShareTokenRefresh(resolvedEpisodeURL) {
            resolvedEpisodeURL = try await refreshQuarkShareToken(
                in: resolvedEpisodeURL
            )
            refreshedShareToken = true
        }
        do {
            return try await resolvePlayer(
                flag: flag,
                episodeURL: resolvedEpisodeURL
            )
        } catch let authorization as NodeWebAuthorizationRequired {
            throw authorization
        } catch {
            if !refreshedShareToken,
               Self.shouldRefreshQuarkShareToken(after: error),
               QuarkEpisodeReference.identity(from: resolvedEpisodeURL) != nil {
                let refreshedURL = try await refreshQuarkShareToken(
                    in: resolvedEpisodeURL
                )
                do {
                    return try await resolvePlayer(
                        flag: flag,
                        episodeURL: refreshedURL
                    )
                } catch {
                    throw AppError.spider(
                        "\(site.name) play 失败：已刷新夸克分享令牌，但转存仍失败："
                            + error.localizedDescription
                    )
                }
            }
            // Some Node spiders put an already playable URL directly in the
            // episode field even though their optional play resolver is down.
            // Preserve that valid fallback instead of turning a resolver 500
            // into a total playback failure.
            if MediaURLClassifier.isDirectMediaURL(episodeURL) {
                let readyBaseURL = try await runtimeBaseURL()
                return SitePlaybackResult(
                    url: normalizePlaybackURL(
                        episodeURL,
                        baseURL: readyBaseURL
                    ),
                    needsParsing: false,
                    flag: flag,
                    headers: HTTPHeaders(site.header),
                    validationPolicy: .providerPreflight
                )
            }
            throw error
        }
    }

    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        let requestedSourceName = request.sourceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = request.providerResourceReference,
           acceptsPlaybackResourceReference(reference),
           let sourceName = requestedSourceName,
           !sourceName.isEmpty {
            let directResult: SitePlaybackResult
            do {
                directResult = try await player(
                    flag: sourceName,
                    episodeURL: reference.stableResourceLocator
                )
            } catch let authorization as NodeWebAuthorizationRequired {
                throw authorization
            } catch {
                // Password-protected shares intentionally do not persist the
                // extraction code. Let current Spider detail reacquire its
                // own share context before declaring the durable identity
                // unusable.
                return try await refreshPlaybackBySelection(request)
            }
            var result = directResult
            result.resourceReference = reference
            result.mediaSession?.resourceReference = reference
            result.mediaSession?.refreshPerformed = true
            let requestedEpisodeName = request.episodeName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let episodeName: String
            if let requestedEpisodeName, !requestedEpisodeName.isEmpty {
                episodeName = requestedEpisodeName
            } else {
                episodeName = "历史分集"
            }
            let episode = PlayEpisode(
                name: episodeName,
                url: reference.stableResourceLocator,
                referenceIdentity: reference.episodeIdentity,
                providerResourceReference: reference
            )
            let source = PlaySource(
                name: sourceName,
                episodes: [episode],
                referenceIdentity: reference.sourceIdentity
            )
            return RefreshedSitePlayback(
                detail: VideoDetail(
                    summary: VideoSummary(
                        siteKey: site.key,
                        siteName: site.name,
                        videoID: request.videoID,
                        title: request.title
                    ),
                    playSources: [source]
                ),
                source: source,
                episode: episode,
                playbackResult: result
            )
        }
        return try await refreshPlaybackBySelection(request)
    }

    private func refreshPlaybackBySelection(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        let selected = try await resolvePlaybackRefreshSelection(request)
        var result = try await player(
            flag: selected.source.name,
            episodeURL: selected.episode.url
        )
        result.mediaSession?.refreshPerformed = true
        return RefreshedSitePlayback(
            detail: selected.detail,
            source: selected.source,
            episode: selected.episode,
            playbackResult: result
        )
    }

    func acceptsPlaybackResourceReference(
        _ reference: PlaybackResourceReference
    ) -> Bool {
        guard let configurationIdentity else {
            return false
        }
        if let expiresAt = reference.expiresAt, expiresAt <= Date() {
            return false
        }
        let locator = reference.stableResourceLocator.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard reference.schemaVersion == 1
            && reference.configurationIdentity == configurationIdentity
            && reference.siteIdentity == site.key
            && reference.providerKind == "node-http-spider"
            && reference.providerVersion == 1
            && reference.stability == .providerStable
            && !reference.sourceIdentity.isEmpty
            && !reference.episodeIdentity.isEmpty,
              locator == reference.stableResourceLocator,
              PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                  reference
              ) == reference else {
            return false
        }
        return QuarkEpisodeReference.identity(from: locator) != nil
    }

    private func resolvePlayer(
        flag: String,
        episodeURL: String
    ) async throws -> SitePlaybackResult {
        let invocation = try await invoke(
            method: "play",
            body: [
                "flag": .string(flag),
                "id": .string(episodeURL),
                "vipFlags": .array([]),
                "flags": .array([])
            ],
            // POST /play may perform a cloud transfer. Blindly repeating
            // it cannot repair an expired token and can duplicate work.
            maximumAttempts: 1
        )
        var result = try SpiderResponseMapper.player(
            invocation.value,
            site: site
        )
        // Site-level headers (for example Referer/User-Agent) are part of the
        // provider contract. Player-response headers override them, but must
        // not replace the whole request context.
        result.headers = HTTPHeaders(site.header).merging(result.headers)
        // A Node Spider may return an expired dlink, an HTML login page or a
        // JSON error with HTTP 200. Unlike an in-process player, the host can
        // safely validate this transport with the complete request headers.
        // Do not let a syntactically valid URL bypass the media-byte probe.
        result.validationPolicy = .providerPreflight
        result.resourceReference = playbackResourceReference(
            flag: flag,
            episodeURL: episodeURL,
            providerDescriptor: SpiderResponseMapper
                .providerPlaybackResourceDescriptor(invocation.value)
        )
        result.url = normalizePlaybackURL(
            result.url,
            baseURL: invocation.baseURL
        )
        result.qualities = result.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: normalizePlaybackURL(
                    $0.url,
                    baseURL: invocation.baseURL
                )
            )
        }
        let transportSelection = await preferredPlaybackTransport(
            selectedURL: result.url,
            qualities: result.qualities,
            headers: result.headers,
            baseURL: invocation.baseURL
        )
        result.url = transportSelection.url
        result.subtitles = result.subtitles.map { subtitle in
            URL(string: normalizePlaybackURL(
                subtitle.absoluteString,
                baseURL: invocation.baseURL
            ))
                ?? subtitle
        }
        // Media-session identity is runtime-only. Generic Node playback still
        // needs transport/range metadata even when there is no safe durable
        // history reference. Its hashed reference is never exposed through
        // `result.resourceReference` and is rejected by persistence policy.
        let mediaReference = result.resourceReference
            ?? runtimeMediaReference(flag: flag, episodeURL: episodeURL)
        result.mediaSession = playbackMediaSession(
            result: result,
            reference: mediaReference,
            baseURL: invocation.baseURL,
            rangePolicy: transportSelection.rangePolicy
        )
        return result
    }

    private func runtimeMediaReference(
        flag: String,
        episodeURL: String
    ) -> PlaybackResourceReference {
        let digest = SHA256.hash(
            data: Data("\(flag)\u{0}\(episodeURL)".utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return PlaybackResourceReference(
            configurationIdentity: configurationIdentity ?? "runtime-only",
            siteIdentity: site.key,
            providerKind: "node-http-spider-runtime",
            providerVersion: 1,
            stableResourceLocator: "runtime-v1.\(digest)",
            sourceIdentity: PlaybackReferenceIdentity.source(
                explicitIdentity: "node-http-source:\(site.key):\(flag)",
                episodes: []
            ),
            episodeIdentity: "runtime-sha256:\(digest)",
            stability: .providerReplay,
            expiresAt: nil
        )
    }

    private func playbackResourceReference(
        flag: String,
        episodeURL: String,
        providerDescriptor: ProviderPlaybackResourceDescriptor?
    ) -> PlaybackResourceReference? {
        guard let configurationIdentity else {
            return nil
        }

        let durableLocator = providerDescriptor?.stableDescription.flatMap(
            QuarkEpisodeReference.durableHistoryReference
        ) ?? {
            guard QuarkEpisodeReference.identity(from: episodeURL) != nil else {
                return nil
            }
            return QuarkEpisodeReference.durableHistoryReference(episodeURL)
        }()
        if let durableLocator {
            guard QuarkEpisodeReference.requiresShareTokenRefresh(durableLocator) else {
                return nil
            }
            return PlaybackResourceReference(
                configurationIdentity: configurationIdentity,
                siteIdentity: site.key,
                providerKind: "node-http-spider",
                providerVersion: 1,
                stableResourceLocator: durableLocator,
                sourceIdentity: PlaybackReferenceIdentity.source(
                    explicitIdentity: "node-http-source:\(site.key):\(flag)",
                    episodes: []
                ),
                episodeIdentity: PlaybackReferenceIdentity.episode(
                    explicitIdentity: "node-http-quark:\(durableLocator)",
                    name: "",
                    reference: ""
                ),
                stability: .providerStable,
                expiresAt: nil
            )
        }

        return nil
    }

    private func attachDurableEpisodeReferences(
        to selection: SiteSelectionResult
    ) -> SiteSelectionResult {
        guard case .detail(var detail) = selection else { return selection }
        detail.playSources = detail.playSources.map { source in
            var source = source
            source.episodes = source.episodes.map { episode in
                guard let reference = playbackResourceReference(
                    flag: source.name,
                    episodeURL: episode.url,
                    providerDescriptor: nil
                ) else {
                    return episode
                }
                var episode = episode
                episode.referenceIdentity = reference.episodeIdentity
                episode.providerResourceReference = reference
                return episode
            }
            if let sourceIdentity = source.episodes.compactMap({
                $0.providerResourceReference?.sourceIdentity
            }).first {
                source.referenceIdentity = sourceIdentity
            }
            return source
        }
        return .detail(detail)
    }

    private func refreshQuarkShareToken(
        in episodeURL: String
    ) async throws -> String {
        guard let identity = QuarkEpisodeReference.identity(from: episodeURL) else {
            throw AppError.playback("夸克分集令牌缺少分享或文件标识")
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "pwd_id": identity.shareID,
                "passcode": QuarkEpisodeReference.passcode(from: episodeURL)
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let response = try await httpClient.send(
            HTTPRequest(
                url: QuarkEpisodeReference.shareTokenURL,
                method: .post,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Referer": "https://pan.quark.cn/",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
                ],
                body: body,
                timeout: 20,
                maximumResponseBytes: 1_024 * 1_024,
                maximumRedirects: 2,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let message = value.flatMap(Self.serverMessage)
        guard (200...299).contains(response.statusCode) else {
            let code = value.flatMap(Self.serverCode)
            let detail = [code.map { "错误码 \($0)" }, message]
                .compactMap { $0 }
                .joined(separator: "：")
            throw AppError.playback(
                "夸克分享令牌刷新失败："
                    + (detail.isEmpty
                        ? "HTTP 状态码 \(response.statusCode)"
                        : detail)
            )
        }
        guard let stoken = value?.objectValue?["data"]?
            .objectValue?["stoken"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stoken.isEmpty else {
            throw AppError.playback(
                "夸克分享令牌刷新失败："
                    + (message ?? "接口未返回新 stoken，分享可能已失效")
            )
        }
        return try QuarkEpisodeReference.replacingStoken(
            in: episodeURL,
            with: stoken
        )
    }

    private static func shouldRefreshQuarkShareToken(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let missingTask = (message.contains("task_id")
            || message.contains("task id"))
            && (message.contains("没有返回")
                || message.contains("未返回")
                || message.contains("missing")
                || message.contains("empty")
                || message.contains("null"))
        return missingTask || isExpiredQuarkShareTokenMessage(message)
    }

    private func playbackMediaSession(
        result: SitePlaybackResult,
        reference: PlaybackResourceReference,
        baseURL: URL,
        rangePolicy: PlaybackMediaSession.RangePolicy
    ) -> PlaybackMediaSession {
        var fingerprintData = Data(result.url.utf8)
        for (name, value) in result.headers.dictionary.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            fingerprintData.append(0)
            fingerprintData.append(contentsOf: name.lowercased().utf8)
            fingerprintData.append(0)
            fingerprintData.append(contentsOf: value.utf8)
        }
        let fingerprint = SHA256.hash(data: fingerprintData)
            .map { String(format: "%02x", $0) }
            .joined()
        return PlaybackMediaSession(
            sessionID: UUID().uuidString.lowercased(),
            transport: isOwnedByRuntime(result.url, baseURL: baseURL)
                ? .providerLoopback
                : .compatibilityDirect,
            mediaURL: result.url,
            headers: result.headers,
            upstreamResourceFingerprint: fingerprint,
            refreshPerformed: false,
            redirectPolicy: .providerDefined,
            rangePolicy: rangePolicy,
            resourceReference: reference
        )
    }

    func action(_ action: String) async throws -> JSONValue {
        let invocation = try await invoke(
            method: "action",
            body: ["action": .string(action)],
            hostMessageWaitMilliseconds: 1_000
        )
        if let hostMessage = invocation.hostMessage {
            throw try webAuthorizationRequired(
                hostMessage: hostMessage
            )
        }
        return invocation.value
    }

    private func invoke(
        method: String,
        body: [String: JSONValue],
        maximumAttempts: Int = 1,
        hostMessageWaitMilliseconds: Int = 0
    ) async throws -> InvocationResult {
        let requestBody = try JSONEncoder().encode(JSONValue.object(body))
        var headers = HTTPHeaders(site.header)
        headers["Content-Type"] = "application/json; charset=utf-8"
        let attempts = max(1, maximumAttempts)
        var lastEndpoint = baseURL
        for attempt in 0..<attempts {
            do {
                let readyBaseURL = try await runtimeBaseURL()
                try await initializationGate.ensureInitialized(
                    at: readyBaseURL
                ) {
                    try await initializeSite(at: readyBaseURL, headers: headers)
                }
                let apiURL = try ResourceResolver.resolve(
                    site.api,
                    relativeTo: readyBaseURL
                )
                let endpoint = apiURL.appendingPathComponent(method)
                lastEndpoint = endpoint
                let invocationID = UUID().uuidString.lowercased()
                headers["X-OKVideo-Invocation-ID"] = invocationID
                let response = try await httpClient.send(
                    HTTPRequest(
                        url: endpoint,
                        method: .post,
                        headers: headers,
                        body: requestBody,
                        timeout: TimeInterval(site.timeout ?? 60),
                        maximumResponseBytes: 16 * 1_024 * 1_024,
                        retryPolicy: .none,
                        allowsNonSuccessfulStatus: true
                    )
                )
                let value: JSONValue
                if response.body.isEmpty {
                    value = .null
                } else {
                    do {
                        value = try JSONDecoder().decode(
                            JSONValue.self,
                            from: response.body
                        )
                    } catch {
                        throw AppError.spider(
                            "Node 站点 \(site.name) 的 \(method) 响应不是有效 JSON"
                        )
                    }
                }
                guard !(200...299).contains(response.statusCode) else {
                    let immediateHostMessage = Self.decodeHostMessage(
                        response.headers["X-OKVideo-Host-Message"]
                    )
                    let hostMessage: HostMessage?
                    if let immediateHostMessage {
                        hostMessage = immediateHostMessage
                    } else if hostMessageWaitMilliseconds > 0 {
                        hostMessage = try await awaitHostMessage(
                            invocationID: response.headers[
                                "X-OKVideo-Invocation-ID"
                            ] ?? invocationID,
                            baseURL: readyBaseURL,
                            waitMilliseconds: hostMessageWaitMilliseconds
                        )
                    } else {
                        hostMessage = nil
                    }
                    return InvocationResult(
                        value: value,
                        baseURL: readyBaseURL,
                        hostMessage: hostMessage
                    )
                }
                let message = Self.serverMessage(from: value)
                    ?? "HTTP 状态码 \(response.statusCode)"
                if Self.isAuthorizationMessage(message) {
                    throw webAuthorizationRequired(
                        message: message,
                        baseURL: readyBaseURL
                    )
                }
                if method == "search" {
                    throw Self.searchError(
                        siteName: site.name,
                        statusCode: response.statusCode,
                        message: message
                    )
                }
                if attempt + 1 < attempts,
                   Self.isTransientHTTPStatus(response.statusCode) {
                    try await retryDelay(after: attempt)
                    continue
                }
                throw AppError.spider(
                    "\(site.name) \(method) 失败：\(message)"
                )
            } catch let authorization as NodeWebAuthorizationRequired {
                throw authorization
            } catch let error as SiteSearchError {
                throw error
            } catch {
                if attempt + 1 < attempts,
                   Self.isTransientTransportError(error) {
                    try await retryDelay(after: attempt)
                    continue
                }
                let classification = NodeDiagnosticClassifier.classify(
                    error,
                    context: .spiderSite
                )
                diagnosticReporter?(
                    NodeDiagnosticEvent(
                        category: classification.category,
                        severity: .error,
                        code: classification.code,
                        message: error.localizedDescription,
                        siteKey: site.key,
                        operation: method,
                        originalURL: lastEndpoint
                    )
                )
                if method == "search" {
                    throw Self.searchTransportError(
                        siteName: site.name,
                        error: error
                    )
                }
                throw error
            }
        }
        throw AppError.spider("Node 站点 \(site.name) 的 \(method) 请求失败")
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private static func searchError(
        siteName: String,
        statusCode: Int,
        message: String
    ) -> SiteSearchError {
        let fullMessage = "\(siteName) search 失败：\(message)"
        let value = message.lowercased()
        if statusCode == 404,
           value.contains("route post:"),
           value.contains("/search"),
           value.contains("not found") {
            return SiteSearchError(
                fullMessage,
                category: .unsupportedRoute
            )
        }
        if isAuthorizationMessage(message)
            || value.contains("账号")
            || value.contains("挂载")
            || value.contains("cookie")
            || value.contains("token") {
            return SiteSearchError(
                fullMessage,
                category: .configurationRequired
            )
        }
        if value.contains("typeerror")
            || value.contains("referenceerror")
            || value.contains("cannot read properties")
            || value.contains("is not a function") {
            return SiteSearchError(fullMessage, category: .scriptError)
        }
        // CatPawOpen commonly wraps an upstream socket failure in its own
        // HTTP 500 JSON response. Preserve the underlying transport meaning
        // so the aggregate scheduler retries it once after every site's first
        // pass instead of reporting a permanent provider/business failure.
        if isTransientTransportMessage(message) {
            return SiteSearchError(
                fullMessage,
                category: .transport,
                isRetryable: true
            )
        }
        if statusCode == 408 || statusCode == 429 {
            return SiteSearchError(
                fullMessage,
                category: .upstreamUnavailable,
                isRetryable: true
            )
        }
        if isTransientHTTPStatus(statusCode) {
            return SiteSearchError(
                fullMessage,
                category: .upstreamUnavailable,
                isRetryable: true
            )
        }
        if isUpstreamUnavailableMessage(message) {
            return SiteSearchError(
                fullMessage,
                category: .upstreamUnavailable
            )
        }
        return SiteSearchError(fullMessage, category: .provider)
    }

    private static func searchTransportError(
        siteName: String,
        error: Error
    ) -> SiteSearchError {
        let message = "\(siteName) search 失败：\(error.localizedDescription)"
        guard let clientError = error as? HTTPClientError else {
            return SiteSearchError(
                message,
                category: SearchFailure.classify(error.localizedDescription)
            )
        }
        switch clientError {
        case .timeout:
            return SiteSearchError(
                message,
                category: .timeout,
                isRetryable: true
            )
        case .transport, .invalidResponse:
            return SiteSearchError(
                message,
                category: .transport,
                isRetryable: true
            )
        case .statusCode(let code):
            return searchError(
                siteName: siteName,
                statusCode: code,
                message: error.localizedDescription
            )
        case .cancelled:
            return SiteSearchError(message, category: .transport)
        case .invalidScheme, .responseTooLarge, .tooManyRedirects:
            return SiteSearchError(message, category: .provider)
        }
    }

    private static func isUpstreamUnavailableMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("上游")
            || value.contains("all upstream")
            || value.contains("no upstream")
            || value.contains("bad gateway")
            || value.contains("service unavailable")
    }

    private static func isTransientTransportMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("econnreset")
            || value.contains("econnrefused")
            || value.contains("etimedout")
            || value.contains("eai_again")
            || value.contains("enotfound")
            || value.contains("epipe")
            || value.contains("socket hang up")
            || value.contains("connection reset")
            || value.contains("connection closed")
            || value.contains("network connection was lost")
            || value.contains("unexpected eof")
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let error = error as? HTTPClientError else { return false }
        switch error {
        case .timeout, .transport:
            return true
        case .statusCode(let code):
            return isTransientHTTPStatus(code)
        case .invalidScheme, .responseTooLarge, .tooManyRedirects,
             .invalidResponse, .cancelled:
            return false
        }
    }

    private func awaitHostMessage(
        invocationID: String,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> HostMessage? {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        guard invocationID.rangeOfCharacter(from: allowed.inverted) == nil,
              (8...128).contains(invocationID.count) else {
            throw AppError.spider("Node 宿主操作关联标识无效")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "wait",
                value: String(min(max(waitMilliseconds, 0), 2_000))
            )
        ]
        guard let endpoint = components?.url else {
            throw AppError.spider("Node 宿主操作轮询地址无效")
        }
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                method: .get,
                timeout: TimeInterval(waitMilliseconds) / 1_000 + 2,
                maximumResponseBytes: 8 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard response.statusCode == 200 else {
            if response.statusCode == 204 || response.statusCode == 404 {
                return nil
            }
            throw AppError.spider(
                "Node 宿主操作轮询失败：HTTP 状态码 \(response.statusCode)"
            )
        }
        guard response.body.count <= 4 * 1_024 else {
            throw AppError.spider("Node 宿主操作响应过大")
        }
        return try? JSONDecoder().decode(HostMessage.self, from: response.body)
    }

    private func initializeSite(
        at readyBaseURL: URL,
        headers: HTTPHeaders
    ) async throws {
        let apiURL = try ResourceResolver.resolve(
            site.api,
            relativeTo: readyBaseURL
        )
        let endpoint = apiURL.appendingPathComponent("init")
        let response = try await httpClient.send(
            HTTPRequest(
                url: endpoint,
                method: .post,
                headers: headers,
                body: Data("{}".utf8),
                timeout: min(TimeInterval(site.timeout ?? 60), 15),
                maximumResponseBytes: 1 * 1_024 * 1_024,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        if (200...299).contains(response.statusCode)
            || response.statusCode == 404
            || response.statusCode == 405 {
            return
        }
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        let message = value.flatMap(Self.serverMessage)
            ?? "HTTP 状态码 \(response.statusCode)"
        throw AppError.spider("\(site.name) init 失败：\(message)")
    }

    private func webAuthorizationRequired(
        message: String,
        baseURL: URL
    ) -> NodeWebAuthorizationRequired {
        NodeWebAuthorizationRequired(
            websiteURL: baseURL.appendingPathComponent("website"),
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: message
        )
    }

    private func webAuthorizationRequired(
        hostMessage: HostMessage
    ) throws -> NodeWebAuthorizationRequired {
        guard hostMessage.action == "openInternalWebview",
              let url = URL(string: hostMessage.opt.url),
              url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ),
              url.port != nil else {
            throw AppError.spider("Node 站点请求了不受支持的宿主操作")
        }
        return NodeWebAuthorizationRequired(
            websiteURL: url,
            title: site.name.replacingOccurrences(of: "|", with: " "),
            message: "请在内置页面中完成此功能。"
        )
    }

    private static func decodeHostMessage(_ encoded: String?) -> HostMessage? {
        guard let encoded,
              encoded.utf8.count <= 8 * 1_024,
              let data = Data(base64Encoded: encoded),
              data.count <= 4 * 1_024 else {
            return nil
        }
        return try? JSONDecoder().decode(HostMessage.self, from: data)
    }

    private func retryDelay(after attempt: Int) async throws {
        let nanoseconds = UInt64(250_000_000 * (attempt + 1))
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func runtimeBaseURL() async throws -> URL {
        if let ensureRuntimeReady {
            return try await ensureRuntimeReady()
        }
        return baseURL
    }

    private func normalizePlaybackURL(
        _ rawValue: String,
        baseURL: URL
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasPrefix("/") {
            return baseURL
                .appendingPathComponent(String(value.dropFirst()))
                .absoluteString
        }
        guard var components = URLComponents(string: value),
              let port = components.port,
              port == baseURL.port,
              components.path.hasPrefix("/spider/")
                || components.path.hasPrefix("/proxy/") else {
            return value
        }
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url?.absoluteString ?? value
    }

    private struct PlaybackTransportSelection {
        let url: String
        let rangePolicy: PlaybackMediaSession.RangePolicy
    }

    /// Prefer the decoder-selected original/direct transport. A Node relay is
    /// a fallback only when the direct file does not implement byte ranges.
    /// An HLS URL is seekable only after its VOD playlist and a non-leading
    /// segment have both been read successfully. Merely ending in `.m3u8`
    /// proves neither random access nor that the provider proxy maps segment
    /// sequence numbers correctly.
    private func preferredPlaybackTransport(
        selectedURL: String,
        qualities: [PlaybackQuality],
        headers: HTTPHeaders,
        baseURL: URL
    ) async -> PlaybackTransportSelection {
        if Self.isHLSURL(selectedURL) {
            let supportsSeek = await supportsHLSRandomAccess(
                url: selectedURL,
                headers: headers
            )
            return PlaybackTransportSelection(
                url: selectedURL,
                rangePolicy: supportsSeek ? .forward : .unsupported
            )
        }

        let selectedIsRuntimeOwned = isOwnedByRuntime(
            selectedURL,
            baseURL: baseURL
        )
        if !selectedIsRuntimeOwned,
           await supportsByteRanges(url: selectedURL, headers: headers) {
            return PlaybackTransportSelection(
                url: selectedURL,
                rangePolicy: .forward
            )
        }

        if !selectedIsRuntimeOwned,
           let hls = qualities.first(where: {
               !isOwnedByRuntime($0.url, baseURL: baseURL)
                   && Self.isHLSURL($0.url)
           }) {
            let supportsSeek = await supportsHLSRandomAccess(
                url: hls.url,
                headers: headers
            )
            return PlaybackTransportSelection(
                url: hls.url,
                rangePolicy: supportsSeek ? .forward : .unsupported
            )
        }

        if let relay = qualities.first(where: {
            isOwnedByRuntime($0.url, baseURL: baseURL)
        }) {
            let supportsRange = await supportsByteRanges(
                url: relay.url,
                headers: headers
            )
            return PlaybackTransportSelection(
                url: relay.url,
                rangePolicy: supportsRange ? .forward : .unsupported
            )
        }

        let supportsRange = selectedIsRuntimeOwned
            ? await supportsByteRanges(url: selectedURL, headers: headers)
            : false
        return PlaybackTransportSelection(
            url: selectedURL,
            rangePolicy: supportsRange ? .forward : .unsupported
        )
    }

    private func supportsByteRanges(
        url rawValue: String,
        headers: HTTPHeaders
    ) async -> Bool {
        guard let url = URL(string: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        var probeHeaders = headers
        probeHeaders["Range"] = "bytes=0-0"
        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: probeHeaders,
                    timeout: 3,
                    maximumResponseBytes: 64 * 1_024,
                    maximumRedirects: 4,
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
            )
            guard response.statusCode == 206,
                  let contentRange = response.headers["Content-Range"]?
                    .lowercased() else { return false }
            return contentRange.hasPrefix("bytes 0-0/")
                || contentRange.hasPrefix("bytes 0-")
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private struct HLSMediaPlaylist {
        let segments: [URL]
        let auxiliaryResources: [URL]
        let duration: TimeInterval
        let isVOD: Bool
    }

    private func supportsHLSRandomAccess(
        url rawValue: String,
        headers: HTTPHeaders
    ) async -> Bool {
        guard let url = URL(string: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        do {
            let playlist = try await loadHLSMediaPlaylist(
                url: url,
                headers: headers,
                remainingMasterDepth: 2
            )
            guard playlist.isVOD,
                  playlist.duration > 0,
                  playlist.segments.count >= 2 else {
                return false
            }

            // Probe a segment away from the beginning. Sequential-only proxy
            // implementations often serve 0.ts successfully but fail here.
            let middleIndex = min(
                playlist.segments.count - 1,
                max(1, playlist.segments.count / 2)
            )
            guard try await hasReadableMediaBytes(
                at: playlist.segments[middleIndex],
                headers: headers
            ) else {
                return false
            }

            // EXT-X-MAP and EXT-X-KEY participate in random access too. Check
            // their rewritten URLs when present so an apparently valid media
            // segment cannot advertise a broken initialization/key resource.
            for resource in playlist.auxiliaryResources {
                guard try await hasReadableResource(
                    at: resource,
                    headers: headers
                ) else {
                    return false
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func loadHLSMediaPlaylist(
        url: URL,
        headers: HTTPHeaders,
        remainingMasterDepth: Int
    ) async throws -> HLSMediaPlaylist {
        let response = try await httpClient.send(
            HTTPRequest(
                url: url,
                headers: headers,
                timeout: 8,
                maximumResponseBytes: 2 * 1_024 * 1_024,
                maximumRedirects: 4,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard (200...299).contains(response.statusCode),
              let text = String(data: response.body, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("#EXTM3U") else {
            throw AppError.playback("HLS 清单不可读")
        }

        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            guard remainingMasterDepth > 0,
                  let variant = Self.firstHLSVariant(in: lines, baseURL: url)
            else {
                throw AppError.playback("HLS 主清单没有可用变体")
            }
            return try await loadHLSMediaPlaylist(
                url: variant,
                headers: headers,
                remainingMasterDepth: remainingMasterDepth - 1
            )
        }

        let segmentURLs = lines.compactMap { line -> URL? in
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return URL(string: line, relativeTo: url)?.absoluteURL
        }
        var duration: TimeInterval = 0
        var auxiliary: [URL] = []
        for line in lines {
            if line.hasPrefix("#EXTINF:"),
               let value = line.dropFirst("#EXTINF:".count)
                .split(separator: ",", maxSplits: 1)
                .first,
               let seconds = TimeInterval(value) {
                duration += max(0, seconds)
            }
            if line.hasPrefix("#EXT-X-KEY:")
                || line.hasPrefix("#EXT-X-MAP:") {
                if let rawURI = Self.hlsAttribute(
                    named: "URI",
                    in: line
                ), let resource = URL(
                    string: rawURI,
                    relativeTo: url
                )?.absoluteURL {
                    auxiliary.append(resource)
                }
            }
        }
        let isVOD = lines.contains("#EXT-X-ENDLIST")
            || lines.contains(where: {
                $0.uppercased().hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD")
            })
        return HLSMediaPlaylist(
            segments: segmentURLs,
            auxiliaryResources: Array(Set(auxiliary)),
            duration: duration,
            isVOD: isVOD
        )
    }

    private func hasReadableMediaBytes(
        at url: URL,
        headers: HTTPHeaders
    ) async throws -> Bool {
        var requestHeaders = headers
        requestHeaders["Range"] = "bytes=0-65535"
        let response = try await httpClient.send(
            HTTPRequest(
                url: url,
                headers: requestHeaders,
                timeout: 8,
                maximumResponseBytes: 256 * 1_024,
                maximumRedirects: 4,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        guard (200...299).contains(response.statusCode),
              !response.body.isEmpty else { return false }
        let contentType = response.headers["Content-Type"]?.lowercased() ?? ""
        if contentType.contains("json") || contentType.contains("html") {
            return false
        }
        let prefix = String(
            data: response.body.prefix(512),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix?.hasPrefix("{") != true
            && prefix?.hasPrefix("[") != true
            && prefix?.hasPrefix("<!doctype html") != true
            && prefix?.hasPrefix("<html") != true
    }

    private func hasReadableResource(
        at url: URL,
        headers: HTTPHeaders
    ) async throws -> Bool {
        let response = try await httpClient.send(
            HTTPRequest(
                url: url,
                headers: headers,
                timeout: 8,
                maximumResponseBytes: 512 * 1_024,
                maximumRedirects: 4,
                retryPolicy: .none,
                allowsNonSuccessfulStatus: true
            )
        )
        return (200...299).contains(response.statusCode)
            && !response.body.isEmpty
    }

    private static func firstHLSVariant(
        in lines: [String],
        baseURL: URL
    ) -> URL? {
        for index in lines.indices where lines[index].hasPrefix(
            "#EXT-X-STREAM-INF:"
        ) {
            var next = index + 1
            while next < lines.count {
                let line = lines[next]
                if !line.isEmpty, !line.hasPrefix("#") {
                    return URL(string: line, relativeTo: baseURL)?.absoluteURL
                }
                next += 1
            }
        }
        return nil
    }

    private static func hlsAttribute(
        named name: String,
        in line: String
    ) -> String? {
        let marker = "\(name)=\""
        guard let start = line.range(of: marker) else { return nil }
        let remainder = line[start.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    private static func isHLSURL(_ rawValue: String) -> Bool {
        let lowered = rawValue.lowercased()
        if lowered.contains(".m3u8") { return true }
        guard let components = URLComponents(string: rawValue) else {
            return false
        }
        return components.queryItems?.contains {
            $0.value?.lowercased().contains("m3u8") == true
        } == true
    }

    private func isOwnedByRuntime(
        _ rawValue: String,
        baseURL: URL
    ) -> Bool {
        guard let candidate = URL(string: rawValue),
              let candidateHost = candidate.host,
              let baseHost = baseURL.host else {
            return false
        }
        return candidate.scheme?.caseInsensitiveCompare(baseURL.scheme ?? "")
                == .orderedSame
            && candidateHost.caseInsensitiveCompare(baseHost) == .orderedSame
            && candidate.port == baseURL.port
    }

    private static func serverMessage(from value: JSONValue) -> String? {
        guard case .object(let object) = value else {
            if case .string(let message) = value {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        for key in ["message", "msg", "error", "errMsg"] {
            guard case .string(let message) = object[key] else { continue }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func serverCode(from value: JSONValue) -> String? {
        guard case .object(let object) = value else { return nil }
        for key in ["code", "errorCode", "error_code", "errno"] {
            switch object[key] {
            case .integer(let value):
                return String(value)
            case .number(let value):
                return value.rounded() == value
                    ? String(Int64(value))
                    : String(value)
            case .string(let value):
                let trimmed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmed.isEmpty { return trimmed }
            default:
                continue
            }
        }
        return nil
    }

    private static func isExpiredQuarkShareTokenMessage(
        _ message: String
    ) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("41016")
            || (normalized.contains("stoken")
                && (normalized.contains("过期")
                    || normalized.contains("expired")))
    }

    private static func isAuthorizationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        // A share stoken is independent from the user's cloud-drive login.
        // Treating 41016 as a Cookie/login problem bypasses the refresh path
        // and sends the user to an authorization screen that cannot fix it.
        if isExpiredQuarkShareTokenMessage(normalized) {
            return false
        }
        let configurationHints = [
            "请先去配置中心", "请先到配置中心",
            "还没有配置", "未登录", "还没有登录",
            "cookie", "token", "扫码登录", "验证码登录"
        ]
        let providerHints = [
            "网盘", "夸克", "uc", "百度", "115", "123",
            "天翼", "移动", "光鸭", "迅雷", "bili"
        ]
        return configurationHints.contains(where: normalized.contains)
            && providerHints.contains(where: normalized.contains)
    }
}
