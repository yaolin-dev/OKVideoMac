import CryptoKit
import Foundation
import OKVideoCore

private func nodeNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct NodeTransferPlaybackContext: Equatable, Sendable {
    let requestID: UUID
    let requestGeneration: UInt64
}

private enum NodeTransferPlaybackTaskContext {
    @TaskLocal static var current: NodeTransferPlaybackContext?
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
    let challengeID: UUID
    /// Host-side invocation that owns this challenge. Explicit completion
    /// signals are accepted only from this request-scoped mailbox.
    let requestID: String?
    let websiteURL: URL
    let title: String
    let message: String
    let provider: String?
    let profileRevision: String?
    let transport: String

    var errorDescription: String? { message }

    init(
        challengeID: UUID,
        requestID: String? = nil,
        websiteURL: URL,
        title: String,
        message: String,
        provider: String?,
        profileRevision: String?,
        transport: String
    ) {
        self.challengeID = challengeID
        self.requestID = requestID
        self.websiteURL = websiteURL
        self.title = title
        self.message = message
        self.provider = provider
        self.profileRevision = profileRevision
        self.transport = transport
    }
}

struct NodeAuthorizationCompletionSignal: Equatable, Sendable {
    let challengeID: UUID
    let requestID: String?
    let provider: String?
    let profileRevision: String?

    init(
        challengeID: UUID,
        requestID: String? = nil,
        provider: String?,
        profileRevision: String?
    ) {
        self.challengeID = challengeID
        self.requestID = requestID
        self.provider = provider
        self.profileRevision = profileRevision
    }
}

actor NodeAuthorizationSignalCenter {
    static let shared = NodeAuthorizationSignalCenter()

    private struct SignalKey: Hashable {
        let challengeID: UUID
        let requestID: String?
    }

    private var completed: [SignalKey: NodeAuthorizationCompletionSignal] = [:]
    private var continuations:
        [SignalKey: [UUID: AsyncStream<NodeAuthorizationCompletionSignal>.Continuation]] = [:]
    private var monitors: [SignalKey: Task<Void, Never>] = [:]

    func register(
        challengeID: UUID,
        requestID: String?,
        monitor: Task<Void, Never>
    ) {
        let key = SignalKey(
            challengeID: challengeID,
            requestID: Self.normalized(requestID)
        )
        guard completed[key] == nil else {
            monitor.cancel()
            return
        }
        monitors[key]?.cancel()
        monitors[key] = monitor
    }

    func signals(
        for challengeID: UUID,
        requestID: String?
    ) -> AsyncStream<NodeAuthorizationCompletionSignal> {
        let key = SignalKey(
            challengeID: challengeID,
            requestID: Self.normalized(requestID)
        )
        let continuationID = UUID()
        return AsyncStream { continuation in
            if let signal = completed[key] {
                continuation.yield(signal)
                continuation.finish()
            } else {
                continuations[key, default: [:]][continuationID] = continuation
            }
            continuation.onTermination = { _ in
                Task {
                    await NodeAuthorizationSignalCenter.shared.removeContinuation(
                        key: key,
                        continuationID: continuationID
                    )
                }
            }
        }
    }

    func publish(_ signal: NodeAuthorizationCompletionSignal) {
        let key = SignalKey(
            challengeID: signal.challengeID,
            requestID: Self.normalized(signal.requestID)
        )
        guard completed[key] == nil else { return }
        completed[key] = signal
        monitors[key] = nil
        let listeners = continuations.removeValue(forKey: key) ?? [:]
        for continuation in listeners.values {
            continuation.yield(signal)
            continuation.finish()
        }
    }

    func cancel(_ challengeID: UUID) {
        let monitorKeys = monitors.keys.filter { $0.challengeID == challengeID }
        for key in monitorKeys {
            monitors.removeValue(forKey: key)?.cancel()
        }
        completed = completed.filter { $0.key.challengeID != challengeID }
        let continuationKeys = continuations.keys.filter {
            $0.challengeID == challengeID
        }
        for key in continuationKeys {
            let listeners = continuations.removeValue(forKey: key) ?? [:]
            for continuation in listeners.values {
                continuation.finish()
            }
        }
    }

    private func removeContinuation(
        key: SignalKey,
        continuationID: UUID
    ) {
        continuations[key]?[continuationID] = nil
        if continuations[key]?.isEmpty == true {
            continuations[key] = nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        nodeNonEmpty(value)
    }
}

@MainActor
private enum NodeHostSniffBridge {
    private static var activeSniffer: WKWebSniffer?

    static func sniff(_ request: WebSniffRequest) async throws -> SniffedMedia {
        activeSniffer?.cancel()
        let sniffer = WKWebSniffer()
        activeSniffer = sniffer
        defer {
            if activeSniffer === sniffer {
                activeSniffer = nil
            }
        }
        return try await sniffer.sniff(request)
    }

    static func cancel() {
        activeSniffer?.cancel()
        activeSniffer = nil
    }
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

enum CatPawPlaybackReplayKind: String, Codable, Equatable {
    case video
    case pan
}

/// Provider-call identity captured before a temporary playback URL exists.
/// `profileIdentity` is the stable profile namespace, never the mutable
/// profile revision. The final media URL, headers and runtime session are not
/// representable here.
struct NodePlaybackReplay: Codable, Equatable {
    let version: Int
    let kind: CatPawPlaybackReplayKind
    let bundleIdentity: String?
    let profileIdentity: String?
    let videoID: String?
    let flag: String
    let episodeURL: String
    let episodeName: String?
    let episodeIndex: Int?

    init(
        version: Int = 2,
        kind: CatPawPlaybackReplayKind = .video,
        bundleIdentity: String? = nil,
        profileIdentity: String? = nil,
        videoID: String? = nil,
        flag: String,
        episodeURL: String,
        episodeName: String? = nil,
        episodeIndex: Int? = nil
    ) {
        self.version = version
        self.kind = kind
        self.bundleIdentity = bundleIdentity
        self.profileIdentity = profileIdentity
        self.videoID = videoID
        self.flag = flag
        self.episodeURL = episodeURL
        self.episodeName = episodeName
        self.episodeIndex = episodeIndex
    }
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
    static let protectedPrefix = "nhr2"
    static let directPrefix = "ndr2"
    private static let legacyProtectedPrefix = "nhr1"
    private static let maximumFlagByteCount = 4_096
    private static let maximumVideoByteCount = 65_536
    private static let maximumEpisodeByteCount = 65_536
    private static let maximumDirectLocatorByteCount = 3_500

    static func locator(
        configurationIdentity: String,
        siteIdentity: String,
        replay: NodePlaybackReplay,
        store: NodePlaybackReplayStoring,
        persistsProtectedReplay: Bool = true
    ) -> String? {
        guard !replay.flag.isEmpty,
              !replay.episodeURL.isEmpty,
              replay.flag.utf8.count <= maximumFlagByteCount,
              (replay.videoID?.utf8.count ?? 0) <= maximumVideoByteCount,
              replay.episodeURL.utf8.count <= maximumEpisodeByteCount else {
            return nil
        }
        if !requiresProtectedStorage(replay),
           let encoded = encodedDirectReplay(replay),
           encoded.utf8.count <= maximumDirectLocatorByteCount {
            return encoded
        }
        let locator = protectedLocator(
            configurationIdentity: configurationIdentity,
            siteIdentity: siteIdentity,
            replay: replay
        )
        guard persistsProtectedReplay else { return nil }
        guard store.store(replay, for: locator) else { return nil }
        return locator
    }

    static func replay(
        for locator: String,
        store: NodePlaybackReplayStoring
    ) -> NodePlaybackReplay? {
        if locator.hasPrefix("\(directPrefix).") {
            let encoded = locator.dropFirst(directPrefix.count + 1)
            guard let data = base64URLDecoded(String(encoded)) else {
                return nil
            }
            return try? JSONDecoder().decode(NodePlaybackReplay.self, from: data)
        }
        guard isProtectedLocator(locator) else { return nil }
        return store.replay(for: locator)
    }

    private static func protectedLocator(
        configurationIdentity: String,
        siteIdentity: String,
        replay: NodePlaybackReplay
    ) -> String {
        var data = Data()
        for value in [
            configurationIdentity,
            siteIdentity,
            replay.bundleIdentity ?? "",
            replay.profileIdentity ?? "",
            replay.videoID ?? "",
            replay.kind.rawValue,
            replay.flag,
            replay.episodeURL,
            replay.episodeName ?? "",
            replay.episodeIndex.map(String.init) ?? ""
        ] {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(protectedPrefix).\(digest)"
    }

    static func isLocator(_ value: String) -> Bool {
        isProtectedLocator(value)
            || (value.hasPrefix("\(directPrefix).")
                && replay(
                    for: value,
                    store: NodePlaybackDisabledReplayStore()
                ) != nil)
    }

    static func isCurrentLocator(_ value: String) -> Bool {
        value.hasPrefix("\(protectedPrefix).")
            || value.hasPrefix("\(directPrefix).")
    }

    /// Keeps ordinary provider IDs verbatim, while replacing a URL, JSON,
    /// encoded object or credential-shaped value with a non-reversible row
    /// identity. History can use that identity for display/deduplication and
    /// reopen the current provider detail (or search by title) on replay; the
    /// original value is never copied into host persistence.
    static func persistedOpaqueIdentity(
        _ rawValue: String,
        namespace: String
    ) -> String {
        guard opaqueValueRequiresProtection(rawValue) else { return rawValue }
        let digest = SHA256.hash(
            data: Data("\(namespace)\u{0}\(rawValue)".utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return "cph2.\(digest)"
    }

    private static func isProtectedLocator(_ value: String) -> Bool {
        let prefix: String
        if value.hasPrefix("\(protectedPrefix).") {
            prefix = protectedPrefix
        } else if value.hasPrefix("\(legacyProtectedPrefix).") {
            prefix = legacyProtectedPrefix
        } else {
            return false
        }
        let digest = value.dropFirst(prefix.count + 1)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }

    private static func encodedDirectReplay(
        _ replay: NodePlaybackReplay
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(replay) else { return nil }
        return "\(directPrefix).\(base64URLEncoded(data))"
    }

    private static func requiresProtectedStorage(
        _ replay: NodePlaybackReplay
    ) -> Bool {
        [replay.videoID, replay.episodeURL].compactMap { $0 }.contains {
            opaqueValueRequiresProtection($0)
        }
    }

    private static func opaqueValueRequiresProtection(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if URLComponents(string: value)?.scheme != nil
            || value.first == "{" || value.first == "["
            || value.contains("?") || value.contains("&")
            || value.contains("=") {
            return true
        }
        let lowercased = value.lowercased()
        let sensitiveFragments = [
            "access_token", "accesstoken", "authorization", "bearer",
            "cookie", "credential", "password", "passcode", "secret",
            "session", "signature", "signed", "stoken", "ticket", "token"
        ]
        if sensitiveFragments.contains(where: lowercased.contains) {
            return true
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        if let data = Data(base64Encoded: base64),
           let decoded = String(data: data, encoding: .utf8) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{" || trimmed.first == "[" {
                return true
            }
        }
        return false
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

/// Provider-published stable locators may still be credentials (for example a
/// refresh token or JWT). Legacy histories may contain only this bound digest;
/// without the original value they are intentionally re-resolved through the
/// current provider detail/search path instead of being replayed directly.
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
    private typealias HostMessage = CatPawHostMessage

    private struct InvocationResult {
        let value: JSONValue
        let baseURL: URL
        let invocationID: String
        let hostMessage: HostMessage?
    }

    private enum PlaybackInvocationEvent: @unchecked Sendable {
        case response(HTTPResponse)
        case hostMessage(HostMessage)
    }

    let site: SiteConfiguration
    let capability: SiteCapability = .javaScriptSpider

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let diagnosticReporter: (@Sendable (NodeDiagnosticEvent) -> Void)?
    private let ensureRuntimeReady: (@Sendable () async throws -> URL)?
    private let configurationIdentity: String?
    private let playbackReplayStore: NodePlaybackReplayStoring
    private let capturedPlaybackReferenceLock = NSLock()
    private var capturedPlaybackReferences: [String: PlaybackResourceReference] = [:]
    private let routeClient: CatPawRouteClient
    private let hostMessageBridge: CatPawHostMessageBridge
    private let authorizationCoordinator: CatPawAuthorizationCoordinator

    var configurationWebsiteURL: URL {
        baseURL.appendingPathComponent("website")
    }

    /// Consumes a credential failure emitted while libmpv was reading a
    /// CatPaw-owned proxy URL. Contract-B keeps the event short-lived and
    /// source-scoped when the proxy path carries a module identity. Root
    /// `/proxy/...` routes are runtime-scoped and can only be consumed by the
    /// active playback's bounded post-failure poll.
    func consumeLatePlaybackAuthorization(
        flag: String,
        notBefore: Date,
        waitMilliseconds: Int = 750
    ) async -> NodeWebAuthorizationRequired? {
        guard let modulePath = Self.runtimeModulePath(from: site.api),
              let readyBaseURL = try? await runtimeBaseURL() else {
            return nil
        }
        let deadline = Date().addingTimeInterval(
            TimeInterval(min(max(waitMilliseconds, 0), 2_000)) / 1_000
        )
        repeat {
            let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1_000))
            let hostMessage: HostMessage?
            do {
                hostMessage = try await hostMessageBridge.pollRuntimeEvent(
                    modulePath: modulePath,
                    notBefore: notBefore,
                    baseURL: readyBaseURL,
                    waitMilliseconds: remaining
                )
            } catch {
                return nil
            }
            guard let hostMessage else { return nil }
            guard let options = hostMessage.opt.objectValue else {
                continue
            }
            if let declaredModulePath = options["runtimeModulePath"]?.stringValue,
               declaredModulePath != modulePath {
                continue
            }
            let message: String
            switch hostMessage.action {
            case "proxyAuthorizationRequired":
                guard let eventMessage = Self.toastMessage(from: options),
                      Self.isStructuredProxyAuthorizationEvent(
                          options: options,
                          message: eventMessage
                      ) else {
                    continue
                }
                message = Self.proxyAuthorizationMessage(
                    eventMessage,
                    provider: options["provider"]?.stringValue
                )
            case "toast":
                guard let toastMessage = Self.toastMessage(from: options),
                      Self.isPlaybackAuthorizationMessage(
                          toastMessage,
                          flag: flag
                      ) else {
                    continue
                }
                message = toastMessage
            default:
                continue
            }
            return webAuthorizationRequired(
                message: LogRedactor.text(message),
                baseURL: readyBaseURL
            )
        } while deadline.timeIntervalSinceNow > 0
        return nil
    }

    static func canHandle(site: SiteConfiguration, baseURL: URL?) -> Bool {
        guard (site.type == 3 || site.type == 4),
              site.extra["okNodeRuntime"] == .bool(true),
              (site.extra["okNodeModuleKind"]?.stringValue ?? "video") == "video",
              site.extra["okNodeUnsupportedModule"] != .bool(true),
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
        routeClient = CatPawRouteClient(
            site: site,
            baseURL: baseURL,
            httpClient: httpClient,
            ensureRuntimeReady: ensureRuntimeReady
        )
        hostMessageBridge = CatPawHostMessageBridge(httpClient: httpClient)
        authorizationCoordinator = CatPawAuthorizationCoordinator(
            site: site,
            hostMessageBridge: hostMessageBridge
        )
        _ = quarkPasscodeStore
        self.playbackReplayStore = playbackReplayStore
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
        var result = try SpiderResponseMapper.home(
            home.value,
            homeVideoValue: homeVideo?.value,
            site: site,
            baseURL: home.baseURL
        )
        for index in result.categories.indices
        where result.categories[index].resolvedContentKind == .media {
            if await ownedLegacyConfigurationWebsite(
                result.categories[index].id,
                runtimeBaseURL: home.baseURL
            ) != nil {
                result.categories[index].contentKind = .action
            }
        }
        result.recommendations = Self.normalizingRuntimePosterURLs(
            result.recommendations,
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
        let readyBaseURL = try await runtimeBaseURL()
        let isLegacyConfiguration = await ownedLegacyConfigurationWebsite(
            id,
            runtimeBaseURL: readyBaseURL
        ) != nil
        return try await category(
            id: id,
            page: page,
            filters: filters,
            awaitsHostAction: isLegacyConfiguration,
            mapsEntirePageAsActions: isLegacyConfiguration
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
            awaitsHostAction: true,
            mapsEntirePageAsActions: true
        )
    }

    private func category(
        id: String,
        page: Int,
        filters: [String: String],
        awaitsHostAction: Bool,
        mapsEntirePageAsActions: Bool
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
        if let hostMessage = invocation.hostMessage,
           hostMessage.action == "openInternalWebview" {
            throw try await webAuthorizationRequired(
                hostMessage: hostMessage,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL
            )
        }
        if mapsEntirePageAsActions {
            let page = try SpiderResponseMapper.actionPage(
                invocation.value,
                site: site,
                baseURL: invocation.baseURL,
                page: page
            )
            return Self.normalizingRuntimePosterURLs(
                page,
                baseURL: invocation.baseURL
            )
        }
        // A regular FongMi category may mix media, folder and explicit action
        // cards. Preserve that protocol metadata so the host can dispatch an
        // action before considering folder/detail navigation.
        let mappedPage = try SpiderResponseMapper.javaDexCategoryPage(
            invocation.value,
            site: site,
            baseURL: invocation.baseURL,
            page: page
        )
        return Self.normalizingRuntimePosterURLs(
            mappedPage,
            baseURL: invocation.baseURL
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
        if let hostMessage = invocation.hostMessage,
           hostMessage.action == "openInternalWebview" {
            throw try await webAuthorizationRequired(
                hostMessage: hostMessage,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL
            )
        }
        do {
            let selection = try SpiderResponseMapper.selection(
                invocation.value,
                site: site,
                baseURL: invocation.baseURL,
                fallbackSummary: fallbackSummary,
                allowsPlaceholderAction:
                    fallbackSummary?.resolvedContentKind == .action
            )
            if !awaitsHostAction,
               Self.shouldAwaitLateConfigurationMessage(after: selection),
               let hostMessage = try await awaitRelevantHostMessage(
                initial: nil,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL,
                waitMilliseconds: 1_250
               ), hostMessage.action == "openInternalWebview" {
                throw try await webAuthorizationRequired(
                    hostMessage: hostMessage,
                    invocationID: invocation.invocationID,
                    baseURL: invocation.baseURL
                )
            }
            return attachDurableEpisodeReferences(to: selection)
        } catch let authorization as NodeWebAuthorizationRequired {
            throw authorization
        } catch {
            if !awaitsHostAction,
               let hostMessage = try? await awaitRelevantHostMessage(
                initial: nil,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL,
                waitMilliseconds: 1_250
               ), hostMessage.action == "openInternalWebview" {
                throw try await webAuthorizationRequired(
                    hostMessage: hostMessage,
                    invocationID: invocation.invocationID,
                    baseURL: invocation.baseURL
                )
            }
            throw error
        }
    }

    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        // CatPawOpen's `searchable` field describes catalogue/UI state, not a
        // trustworthy route capability. Aggregate searches deliberately try
        // every enabled Node route once; an exact route 404 is cheap and is
        // reported as unsupported without hiding the site from future runs.
        guard !quick || site.quickSearch == 1 else {
            return VideoPage(
                items: [],
                pagination: Pagination(page: page, pageCount: 0)
            )
        }
        if await routeClient.capabilityState(for: .search) == .unsupported {
            throw SiteSearchError(
                "\(site.name) search 失败：该 Bundle 与 Profile 已确认未注册搜索路由",
                category: .unsupportedRoute
            )
        }
        let invocation: InvocationResult
        do {
            invocation = try await invoke(
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
        } catch let error as SiteSearchError {
            if error.category == .unsupportedRoute {
                await routeClient.recordUnsupported(.search)
            }
            throw error
        }
        let result = Self.normalizingRuntimePosterURLs(
            try SpiderResponseMapper.page(
                invocation.value,
                site: site,
                baseURL: invocation.baseURL,
                page: page
            ),
            baseURL: invocation.baseURL
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

    func supportsContent(_ value: String) async throws -> Bool {
        do {
            let invocation = try await invoke(
                method: CatPawRoute.support.rawValue,
                body: [
                    "url": .string(value),
                    "id": .string(value)
                ],
                maximumAttempts: 1
            )
            return Self.supportBoolean(from: invocation.value)
        } catch let error as CatPawRouteError {
            if case .unsupportedRoute = error { return false }
            throw error
        }
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
                    url: Self.normalizePlaybackURL(
                        episodeURL,
                        baseURL: readyBaseURL
                    ),
                    needsParsing: false,
                    flag: flag,
                    headers: HTTPHeaders(site.header),
                    validationPolicy: .playerAuthoritative
                )
            }
            throw error
        }
    }

    func player(
        flag: String,
        episodeURL: String,
        transferContext: NodeTransferPlaybackContext
    ) async throws -> SitePlaybackResult {
        try await NodeTransferPlaybackTaskContext.$current.withValue(
            transferContext
        ) {
            try await player(flag: flag, episodeURL: episodeURL)
        }
    }

    func refreshPlayback(
        _ request: PlaybackRefreshRequest
    ) async throws -> RefreshedSitePlayback {
        let requestedSourceName = request.sourceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = request.providerResourceReference,
           acceptsPlaybackResourceReference(reference) {
            if NodePlaybackReplayReference.isCurrentLocator(
                reference.stableResourceLocator
            ) {
                return try await refreshCatPawVideoPlayback(
                    reference: reference
                )
            }
            guard let sourceName = requestedSourceName,
                  !sourceName.isEmpty else {
                throw ProviderPlaybackError("历史记录缺少原播放线路标识")
            }
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

    func refreshPlayback(
        _ request: PlaybackRefreshRequest,
        transferContext: NodeTransferPlaybackContext
    ) async throws -> RefreshedSitePlayback {
        try await NodeTransferPlaybackTaskContext.$current.withValue(
            transferContext
        ) {
            try await refreshPlayback(request)
        }
    }

    private func refreshCatPawVideoPlayback(
        reference: PlaybackResourceReference
    ) async throws -> RefreshedSitePlayback {
        guard let replay = NodePlaybackReplayReference.replay(
            for: reference.stableResourceLocator,
            store: playbackReplayStore
        ), replay.kind == .video,
           let videoID = nodeNonEmpty(replay.videoID),
           replayBelongsToCurrentProvider(replay) else {
            throw ProviderPlaybackError("原 CatPaw 播放身份已丢失或不属于当前 Bundle/Profile")
        }

        let detail = try await self.detail(id: videoID)
        let sourceEpisodes: [(PlaySource, PlayEpisode)] = detail.playSources
            .flatMap { source -> [(PlaySource, PlayEpisode)] in
                guard source.name == replay.flag else { return [] }
                return source.episodes.map { (source, $0) }
            }
        let exactMatches = sourceEpisodes.filter {
            $0.1.url == replay.episodeURL
        }
        let selected: (PlaySource, PlayEpisode)?
        if exactMatches.count == 1 {
            selected = exactMatches.first
        } else if exactMatches.isEmpty {
            // Some cloud details rotate a token embedded in episodeID while
            // preserving the same provider resource. Match the credential-
            // free structural identity only inside the exact original flag;
            // this is still provider replay and never a title search.
            let replayIdentity = PlaybackReferenceIdentity.episode(
                name: replay.episodeName ?? "",
                reference: replay.episodeURL
            )
            let semanticMatches = sourceEpisodes.filter {
                PlaybackReferenceIdentity.episode(
                    name: $0.1.name,
                    reference: $0.1.url
                ) == replayIdentity
            }
            selected = semanticMatches.count == 1
                ? semanticMatches.first
                : nil
        } else {
            selected = nil
        }
        guard let selected else {
            throw ProviderPlaybackError(
                "最新详情中已无法唯一定位原 flag + episodeID"
            )
        }

        var result = try await player(
            flag: replay.flag,
            episodeURL: selected.1.url
        )
        result.resourceReference = reference
        result.mediaSession?.resourceReference = reference
        result.mediaSession?.refreshPerformed = true
        return RefreshedSitePlayback(
            detail: detail,
            source: selected.0,
            episode: selected.1,
            playbackResult: result
        )
    }

    private func replayBelongsToCurrentProvider(
        _ replay: NodePlaybackReplay
    ) -> Bool {
        if let expectedBundle = nodeNonEmpty(replay.bundleIdentity),
           nodeNonEmpty(site.extra["okNodeBundleIdentity"]?.stringValue)
            != expectedBundle {
            return false
        }
        if let expectedProfile = nodeNonEmpty(replay.profileIdentity),
           nodeNonEmpty(site.extra["okNodeProfileIdentity"]?.stringValue)
            != expectedProfile {
            return false
        }
        return true
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
            && [1, 2].contains(reference.providerVersion)
            && reference.stability == .providerStable
            && !reference.sourceIdentity.isEmpty
            && !reference.episodeIdentity.isEmpty,
              locator == reference.stableResourceLocator,
              PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                  reference
              ) == reference else {
            return false
        }
        if reference.providerVersion == 2,
           NodePlaybackReplayReference.isCurrentLocator(locator),
           let replay = NodePlaybackReplayReference.replay(
            for: locator,
            store: playbackReplayStore
           ) {
            return replay.kind == .video
                && nodeNonEmpty(replay.videoID) != nil
                && replayBelongsToCurrentProvider(replay)
        }
        return reference.providerVersion == 1
            && QuarkEpisodeReference.identity(from: locator) != nil
    }

    private func resolvePlayer(
        flag: String,
        episodeURL: String
    ) async throws -> SitePlaybackResult {
        var body: [String: JSONValue] = [
            "flag": .string(flag),
            "id": .string(episodeURL),
            "vipFlags": .array([]),
            "flags": .array([])
        ]
        if let context = NodeTransferPlaybackTaskContext.current {
            body["_okvideo"] = .object([
                "transferContext": .object([
                    "requestID": .string(
                        context.requestID.uuidString.lowercased()
                    ),
                    "requestGeneration": .integer(
                        Int64(clamping: context.requestGeneration)
                    )
                ])
            ])
        }
        let invocation = try await invoke(
            method: "play",
            body: body,
            // POST /play may perform a cloud transfer. Blindly repeating
            // it cannot repair an expired token and can duplicate work.
            maximumAttempts: 1
        )
        if let hostMessage = invocation.hostMessage,
           hostMessage.action == "openInternalWebview" {
            throw try await webAuthorizationRequired(
                hostMessage: hostMessage,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL
            )
        }
        var result: SitePlaybackResult
        do {
            result = try SpiderResponseMapper.player(
                invocation.value,
                site: site
            )
        } catch let providerError as ProviderPlaybackError {
            if Self.shouldAwaitLateAuthorizationMessage(
                providerError.localizedDescription,
                flag: flag
            ), let hostMessage = try? await awaitHostMessage(
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL,
                waitMilliseconds: 1_250
            ), hostMessage.action == "openInternalWebview" {
                throw try await webAuthorizationRequired(
                    hostMessage: hostMessage,
                    invocationID: invocation.invocationID,
                    baseURL: invocation.baseURL
                )
            }
            if Self.isPlaybackAuthorizationMessage(
                providerError.localizedDescription,
                flag: flag
            ) {
                throw webAuthorizationRequired(
                    message: providerError.localizedDescription,
                    baseURL: invocation.baseURL
                )
            }
            throw providerError
        }
        // Site-level headers (for example Referer/User-Agent) are part of the
        // provider contract. Player-response headers override them, but must
        // not replace the whole request context.
        result.headers = HTTPHeaders(site.header).merging(result.headers)
        result.resourceReference = playbackResourceReference(
            flag: flag,
            episodeURL: episodeURL,
            providerDescriptor: SpiderResponseMapper
                .providerPlaybackResourceDescriptor(invocation.value)
        )
        result.url = Self.normalizePlaybackURL(
            result.url,
            baseURL: invocation.baseURL
        )
        result.qualities = result.qualities.map {
            PlaybackQuality(
                name: $0.name,
                url: Self.normalizePlaybackURL(
                    $0.url,
                    baseURL: invocation.baseURL
                )
            )
        }
        let selectedProviderURL = result.url
        let transportSelection = await preferredPlaybackTransport(
            selectedURL: selectedProviderURL,
            headers: result.headers
        )
        result.url = transportSelection.url
        if result.url != selectedProviderURL {
            result.qualities = result.qualities.map { quality in
                guard quality.url == selectedProviderURL else {
                    return quality
                }
                return PlaybackQuality(
                    name: quality.name,
                    url: result.url
                )
            }
        }
        // CatPaw's cloud routes are active capabilities, not passive files:
        // `/proxy/.../down` streams through its range-aware cache, while
        // `/proxy/.../redirect` mints a short-lived download URL. A host probe
        // would become the first consumer and make libmpv repeat that work (or
        // consume a one-shot redirect), so the player must issue the only
        // media request for both loopback and remote provider transports.
        result.validationPolicy = .playerAuthoritative
        result.subtitles = result.subtitles.map { subtitle in
            URL(string: Self.normalizePlaybackURL(
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
        if let captured = capturedPlaybackReference(
            flag: flag,
            episodeURL: episodeURL
        ) {
            return captured
        }
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
            source.episodes = source.episodes.enumerated().map {
                episodeIndex, episode in
                guard let reference = historyPlaybackResourceReference(
                    videoID: detail.summary.videoID,
                    flag: source.name,
                    episode: episode,
                    episodeIndex: episodeIndex,
                    persistsProtectedReplay: false
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

    private func historyPlaybackResourceReference(
        videoID: String,
        flag: String,
        episode: PlayEpisode,
        episodeIndex: Int,
        persistsProtectedReplay: Bool
    ) -> PlaybackResourceReference? {
        guard let configurationIdentity else { return nil }
        let replay = NodePlaybackReplay(
            kind: .video,
            bundleIdentity: nodeNonEmpty(
                site.extra["okNodeBundleIdentity"]?.stringValue
            ),
            profileIdentity: nodeNonEmpty(
                site.extra["okNodeProfileIdentity"]?.stringValue
            ),
            videoID: videoID,
            flag: flag,
            episodeURL: episode.url,
            episodeName: episode.name,
            episodeIndex: episodeIndex
        )
        if let locator = NodePlaybackReplayReference.locator(
            configurationIdentity: configurationIdentity,
            siteIdentity: site.key,
            replay: replay,
            store: playbackReplayStore,
            persistsProtectedReplay: persistsProtectedReplay
        ) {
            return PlaybackResourceReference(
                configurationIdentity: configurationIdentity,
                siteIdentity: site.key,
                providerKind: "node-http-spider",
                providerVersion: 2,
                stableResourceLocator: locator,
                sourceIdentity: PlaybackReferenceIdentity.source(
                    explicitIdentity: "catpaw-video:\(site.key):\(flag)",
                    episodes: []
                ),
                episodeIdentity: PlaybackReferenceIdentity.episode(
                    explicitIdentity: "catpaw-video:\(locator)",
                    name: episode.name,
                    reference: ""
                ),
                stability: .providerStable,
                expiresAt: nil
            )
        }

        // Production deliberately has no protected replay store. Quark's
        // share/file tuple is credential-free and refreshable; every other
        // unsafe provider value falls back to the saved navigation recipe so
        // history reopens current detail (or searches by title) before play.
        return playbackResourceReference(
            flag: flag,
            episodeURL: episode.url,
            providerDescriptor: nil
        )
    }

    /// Called at the user-selection boundary. Only credential-free replay
    /// values can become durable references; unsafe values remain in memory
    /// for the current playback session and history re-resolves them later.
    func captureHistoryPlaybackResourceReference(
        videoID: String,
        flag: String,
        episode: PlayEpisode,
        episodeIndex: Int
    ) -> PlaybackResourceReference? {
        guard let reference = historyPlaybackResourceReference(
            videoID: videoID,
            flag: flag,
            episode: episode,
            episodeIndex: episodeIndex,
            persistsProtectedReplay: true
        ) else { return nil }
        capturedPlaybackReferenceLock.lock()
        capturedPlaybackReferences[
            capturedPlaybackReferenceKey(flag: flag, episodeURL: episode.url)
        ] = reference
        if capturedPlaybackReferences.count > 64,
           let firstKey = capturedPlaybackReferences.keys.first {
            capturedPlaybackReferences.removeValue(forKey: firstKey)
        }
        capturedPlaybackReferenceLock.unlock()
        return reference
    }

    private func capturedPlaybackReference(
        flag: String,
        episodeURL: String
    ) -> PlaybackResourceReference? {
        let key = capturedPlaybackReferenceKey(
            flag: flag,
            episodeURL: episodeURL
        )
        capturedPlaybackReferenceLock.lock()
        defer { capturedPlaybackReferenceLock.unlock() }
        return capturedPlaybackReferences[key]
    }

    private func capturedPlaybackReferenceKey(
        flag: String,
        episodeURL: String
    ) -> String {
        SHA256.hash(data: Data("\(flag)\u{0}\(episodeURL)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        let message = value.flatMap { Self.serverMessage(from: $0) }
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
        if let hostMessage = invocation.hostMessage,
           hostMessage.action == "openInternalWebview" {
            throw try await webAuthorizationRequired(
                hostMessage: hostMessage,
                invocationID: invocation.invocationID,
                baseURL: invocation.baseURL
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
        guard let route = CatPawRoute(rawValue: method) else {
            throw AppError.spider("未知 CatPaw 路由：\(method)")
        }
        let attempts = max(1, maximumAttempts)
        var lastEndpoint = baseURL
        for attempt in 0..<attempts {
            do {
                let prepared = try await routeClient.prepare(
                    route: route,
                    payload: body
                )
                let readyBaseURL = prepared.baseURL
                let invocationID = prepared.invocationID
                let routeRequest = prepared.request
                lastEndpoint = routeRequest.url
                let response: HTTPResponse
                if route == .play,
                   site.extra["okNodeHostMessageBridge"] == .bool(true) {
                    let event = try await withThrowingTaskGroup(
                        of: PlaybackInvocationEvent.self
                    ) { group in
                        group.addTask { [httpClient] in
                            .response(try await httpClient.send(routeRequest))
                        }
                        group.addTask { [self] in
                            .hostMessage(
                                try await monitorPlaybackHostMessages(
                                    invocationID: invocationID,
                                    baseURL: readyBaseURL
                                )
                            )
                        }
                        guard let event = try await group.next() else {
                            throw CancellationError()
                        }
                        group.cancelAll()
                        return event
                    }
                    switch event {
                    case .response(let routeResponse):
                        response = routeResponse
                    case .hostMessage(let hostMessage):
                        Task { @MainActor in
                            NodeHostSniffBridge.cancel()
                        }
                        throw try await webAuthorizationRequired(
                            hostMessage: hostMessage,
                            invocationID: invocationID,
                            baseURL: readyBaseURL
                        )
                    }
                } else {
                    response = try await httpClient.send(routeRequest)
                }
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
                    await routeClient.recordSupported(route)
                    let immediateHostMessage = hostMessageBridge.decodeHeader(
                        response.headers["X-OKVideo-Host-Message"]
                    )
                    let effectiveInvocationID = response.headers[
                        "X-OKVideo-Invocation-ID"
                    ] ?? invocationID
                    let hostMessage: HostMessage?
                    if hostMessageWaitMilliseconds > 0 {
                        hostMessage = try await awaitRelevantHostMessage(
                            initial: immediateHostMessage,
                            invocationID: effectiveInvocationID,
                            baseURL: readyBaseURL,
                            waitMilliseconds: hostMessageWaitMilliseconds
                        )
                    } else if let immediateHostMessage {
                        hostMessage = immediateHostMessage
                    } else {
                        hostMessage = nil
                    }
                    return InvocationResult(
                        value: value,
                        baseURL: readyBaseURL,
                        invocationID: effectiveInvocationID,
                        hostMessage: hostMessage
                    )
                }
                let message = Self.serverMessage(from: value)
                    ?? "HTTP 状态码 \(response.statusCode)"
                if CatPawRouteClient.isExactRouteNotFound(
                    statusCode: response.statusCode,
                    message: message,
                    route: route
                ) {
                    await routeClient.recordUnsupported(route)
                }
                if route == .play,
                   Self.shouldAwaitLateAuthorizationMessage(
                       message,
                       flag: body["flag"]?.stringValue ?? ""
                   ), let hostMessage = try? await awaitHostMessage(
                       invocationID: response.headers[
                           "X-OKVideo-Invocation-ID"
                       ] ?? invocationID,
                       baseURL: readyBaseURL,
                       waitMilliseconds: 1_250
                   ), hostMessage.action == "openInternalWebview" {
                    throw try await webAuthorizationRequired(
                        hostMessage: hostMessage,
                        invocationID: response.headers[
                            "X-OKVideo-Invocation-ID"
                        ] ?? invocationID,
                        baseURL: readyBaseURL
                    )
                }
                if Self.isAuthorizationMessage(message) {
                    throw webAuthorizationRequired(
                        message: message,
                        baseURL: readyBaseURL
                    )
                }
                if route == .search {
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
            } catch let error as CatPawRouteError {
                if route == .search,
                   case .unsupportedRoute = error {
                    throw SiteSearchError(
                        "\(site.name) search 失败：\(error.localizedDescription)",
                        category: .unsupportedRoute
                    )
                }
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
                if route == .search {
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

    private static func supportBoolean(from value: JSONValue) -> Bool {
        switch value {
        case .bool(let value): return value
        case .integer(let value): return value != 0
        case .number(let value): return value != 0
        case .string(let value):
            return ["1", "true", "yes", "supported"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        case .object(let object):
            for key in ["support", "supported", "result", "value"] {
                if let nested = object[key] {
                    return supportBoolean(from: nested)
                }
            }
            return false
        case .array, .null:
            return false
        }
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

    private func monitorPlaybackHostMessages(
        invocationID: String,
        baseURL: URL
    ) async throws -> HostMessage {
        while !Task.isCancelled {
            if let message = try await awaitHostMessage(
                invocationID: invocationID,
                baseURL: baseURL,
                waitMilliseconds: 1_000
            ) {
                if message.action == "sniff" {
                    await performHostSniff(
                        message,
                        invocationID: invocationID,
                        baseURL: baseURL
                    )
                    continue
                }
                if message.action == "openInternalWebview" {
                    return message
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CancellationError()
    }

    private func performHostSniff(
        _ message: HostMessage,
        invocationID: String,
        baseURL: URL
    ) async {
        guard let requestID = message.requestID,
              Self.isValidHostMessageIdentifier(requestID),
              let options = message.opt.objectValue,
              let rawURL = options["url"]?.stringValue,
              let pageURL = URL(string: rawURL),
              Self.isSafeExternalSniffURL(pageURL) else {
            try? await sendHostMessageReply(
                .null,
                invocationID: invocationID,
                requestID: message.requestID ?? "invalid",
                baseURL: baseURL
            )
            return
        }
        var headers: [String: String] = [:]
        if let publishedHeaders = options["headers"]?.objectValue {
            for (name, value) in publishedHeaders.prefix(64) {
                guard name.utf8.count <= 128,
                      let headerValue = value.stringValue,
                      headerValue.utf8.count <= 8 * 1_024 else { continue }
                headers[name] = headerValue
            }
        }
        let patterns: [String]
        switch options["rule"] {
        case .string(let value):
            patterns = [value]
        case .array(let values):
            patterns = values.compactMap(\.stringValue)
        default:
            patterns = []
        }
        let timeoutMilliseconds: Double
        switch options["timeout"] {
        case .integer(let value): timeoutMilliseconds = Double(value)
        case .number(let value): timeoutMilliseconds = value
        default: timeoutMilliseconds = 15_000
        }
        let request = WebSniffRequest(
            siteKey: "node:\(site.key)",
            url: pageURL,
            headers: HTTPHeaders(headers),
            mediaPatterns: Array(patterns.prefix(32)),
            timeout: min(max(timeoutMilliseconds / 1_000, 1), 60),
            allowsPrivateNetworkAccess: false
        )
        let reply: JSONValue
        do {
            let media = try await NodeHostSniffBridge.sniff(request)
            var responseHeaders: [String: JSONValue] = [:]
            for (name, value) in media.headers.dictionary {
                responseHeaders[name.lowercased()] = .string(value)
            }
            reply = .object([
                "url": .string(media.url.absoluteString),
                "headers": .object(responseHeaders)
            ])
        } catch {
            reply = .null
        }
        try? await sendHostMessageReply(
            reply,
            invocationID: invocationID,
            requestID: requestID,
            baseURL: baseURL
        )
    }

    private func sendHostMessageReply(
        _ value: JSONValue,
        invocationID: String,
        requestID: String,
        baseURL: URL
    ) async throws {
        try await hostMessageBridge.reply(
            value,
            invocationID: invocationID,
            requestID: requestID,
            baseURL: baseURL
        )
    }

    /// Consumes only messages owned by one invocation. Sniff requests are
    /// answered in place and do not hide a following configuration challenge.
    private func awaitRelevantHostMessage(
        initial: HostMessage?,
        invocationID: String,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> HostMessage? {
        let deadline = Date().addingTimeInterval(
            TimeInterval(max(waitMilliseconds, 0)) / 1_000
        )
        var message = initial
        while !Task.isCancelled {
            if let current = message {
                if current.action == "sniff" {
                    await performHostSniff(
                        current,
                        invocationID: invocationID,
                        baseURL: baseURL
                    )
                    message = nil
                } else {
                    return current
                }
            }
            let remaining = Int(
                max(0, deadline.timeIntervalSinceNow * 1_000)
            )
            guard remaining > 0 else { return nil }
            message = try await awaitHostMessage(
                invocationID: invocationID,
                baseURL: baseURL,
                waitMilliseconds: min(remaining, 2_000)
            )
        }
        throw CancellationError()
    }

    private func ownedLegacyConfigurationWebsite(
        _ rawValue: String,
        runtimeBaseURL: URL
    ) async -> URL? {
        guard Self.isLegacyConfigurationWebsiteCandidate(rawValue) else {
            return nil
        }
        var components = URLComponents(
            url: runtimeBaseURL
                .appendingPathComponent("__okvideo")
                .appendingPathComponent("owned-loopback"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "url", value: rawValue)]
        guard let endpoint = components?.url,
              let response = try? await httpClient.send(
                HTTPRequest(
                    url: endpoint,
                    method: .get,
                    timeout: 2,
                    maximumResponseBytes: 4 * 1_024,
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
              ), response.statusCode == 200,
              let value = try? JSONDecoder().decode(
                JSONValue.self,
                from: response.body
              ), let normalized = value.objectValue?["url"]?.stringValue,
              let url = URL(string: normalized),
              Self.isNormalizedOwnedConfigurationWebsite(url) else {
            return nil
        }
        return url
    }

    private static func isLegacyConfigurationWebsiteCandidate(
        _ rawValue: String
    ) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2_048,
              let url = URL(string: value),
              url.scheme?.lowercased() == "http",
              url.port != nil else {
            return false
        }
        return url.path == "/website" || url.path == "/website/"
    }

    private static func isNormalizedOwnedConfigurationWebsite(
        _ url: URL
    ) -> Bool {
        guard url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
              ), url.port != nil else {
            return false
        }
        return url.path == "/website" || url.path == "/website/"
    }

    private static func shouldAwaitLateConfigurationMessage(
        after selection: SiteSelectionResult
    ) -> Bool {
        switch selection {
        case .detail(let detail):
            return detail.playSources.allSatisfy { $0.episodes.isEmpty }
        case .action, .search:
            return true
        }
    }

    private static func isValidHostMessageIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || ".-_".unicodeScalars.contains($0)
        }
    }

    private static func isSafeExternalSniffURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.contains(":") else {
            return false
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        guard parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return !(parts[0] == 0
            || parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 100 && (64...127).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || parts[0] >= 224)
    }

    private func awaitHostMessage(
        invocationID: String,
        baseURL: URL,
        waitMilliseconds: Int
    ) async throws -> HostMessage? {
        try await hostMessageBridge.poll(
            invocationID: invocationID,
            baseURL: baseURL,
            waitMilliseconds: waitMilliseconds
        )
    }

    private func webAuthorizationRequired(
        message: String,
        baseURL: URL
    ) -> NodeWebAuthorizationRequired {
        authorizationCoordinator.legacyAuthorizationRequired(
            message: message,
            baseURL: baseURL
        )
    }

    private func webAuthorizationRequired(
        hostMessage: HostMessage,
        invocationID: String,
        baseURL: URL
    ) async throws -> NodeWebAuthorizationRequired {
        try await authorizationCoordinator.authorizationRequired(
            hostMessage: hostMessage,
            invocationID: invocationID,
            baseURL: baseURL
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

    static func normalizePlaybackURL(
        _ rawValue: String,
        baseURL: URL
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasPrefix("/spider/")
            || value.hasPrefix("/proxy/")
            || value.hasPrefix("/__okvideo/") {
            return CatPawRuntimeURLResolver.normalize(value, baseURL: baseURL)
        }
        guard var components = URLComponents(string: value) else {
            return value
        }
        if components.scheme?.lowercased() == "js2p" {
            guard components.host?.lowercased() == "_web_",
                  components.path.hasPrefix("/spider/")
                    || components.path.hasPrefix("/proxy/"),
                  baseURL.scheme?.lowercased() == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(
                    baseURL.host?.lowercased() ?? ""
                  ) else {
                return value
            }
            return CatPawRuntimeURLResolver.normalize(value, baseURL: baseURL)
        }
        guard
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

    static func normalizeRuntimePosterURL(
        _ posterURL: URL?,
        baseURL: URL
    ) -> URL? {
        guard let posterURL else { return nil }
        return URL(
            string: normalizePlaybackURL(
                posterURL.absoluteString,
                baseURL: baseURL
            )
        ) ?? posterURL
    }

    private static func normalizingRuntimePosterURLs(
        _ items: [VideoSummary],
        baseURL: URL
    ) -> [VideoSummary] {
        items.map { item in
            var item = item
            item.posterURL = normalizeRuntimePosterURL(
                item.posterURL,
                baseURL: baseURL
            )
            return item
        }
    }

    private static func normalizingRuntimePosterURLs(
        _ page: VideoPage,
        baseURL: URL
    ) -> VideoPage {
        VideoPage(
            items: normalizingRuntimePosterURLs(
                page.items,
                baseURL: baseURL
            ),
            pagination: page.pagination
        )
    }

    private struct PlaybackTransportSelection {
        let url: String
        let rangePolicy: PlaybackMediaSession.RangePolicy
    }

    /// Honor the transport selected by the Spider response. Network probing is
    /// intentionally not performed here because CatPaw loopback URLs may mint
    /// a short-lived redirect or begin a provider-managed streaming session.
    private func preferredPlaybackTransport(
        selectedURL: String,
        headers: HTTPHeaders
    ) async -> PlaybackTransportSelection {
        if let prepared = await preparedBaiduOriginalTransport(
            selectedURL: selectedURL,
            headers: headers
        ) {
            return prepared
        }
        return PlaybackTransportSelection(
            url: selectedURL,
            rangePolicy: .providerDefined
        )
    }

    /// CatPaw's Baidu adapter currently returns the signed `d.pcs.baidu.com`
    /// gateway together with a provider-specific User-Agent and Referer. The
    /// gateway immediately redirects to a CDN host. Preparing that redirect
    /// with the exact provider headers avoids a libmpv/FFmpeg redirect race on
    /// a reused player client, and moves only one byte before playback. The
    /// resulting CDN URL is still short-lived and remains runtime-only.
    private func preparedBaiduOriginalTransport(
        selectedURL: String,
        headers: HTTPHeaders
    ) async -> PlaybackTransportSelection? {
        guard let url = URL(string: selectedURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "d.pcs.baidu.com",
              headers["User-Agent"]?.isEmpty == false,
              headers["Referer"]?.isEmpty == false else {
            return nil
        }

        var probeHeaders = headers
        probeHeaders["Range"] = "bytes=0-0"
        do {
            let response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: probeHeaders,
                    timeout: 8,
                    maximumResponseBytes: 64 * 1_024,
                    maximumRedirects: 4,
                    redirectedHeaderFields: [
                        "Range",
                        "Referer",
                        "User-Agent"
                    ],
                    retryPolicy: .none,
                    allowsNonSuccessfulStatus: true
                )
            )
            guard (200...299).contains(response.statusCode),
                  ["http", "https"].contains(
                    response.url.scheme?.lowercased() ?? ""
                  ) else {
                return nil
            }
            let rangePolicy: PlaybackMediaSession.RangePolicy =
                response.statusCode == 206
                    || response.headers["Content-Range"]?.isEmpty == false
                ? .forward
                : .providerDefined
            return PlaybackTransportSelection(
                url: response.url.absoluteString,
                rangePolicy: rangePolicy
            )
        } catch {
            // Compatibility fallback: a bundle may return a valid signed URL
            // whose CDN rejects a one-byte probe. Let libmpv remain the
            // authoritative consumer instead of turning preparation into a
            // new playback failure.
            return nil
        }
    }

    private static func runtimeModulePath(from api: String) -> String? {
        let encodedPath = URLComponents(string: api)?.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let encodedPath, !encodedPath.isEmpty else { return nil }
        let parts = encodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard parts.count >= 3,
              parts[0].lowercased() == "spider" else {
            return nil
        }
        return "/" + parts.prefix(3).joined(separator: "/")
    }

    private static func toastMessage(
        from options: [String: JSONValue]
    ) -> String? {
        for key in ["message", "msg", "text", "title"] {
            if let value = options[key]?.stringValue?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !value.isEmpty {
                return value
            }
        }
        return nil
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

    private static func serverMessage(
        from value: JSONValue,
        depth: Int = 0
    ) -> String? {
        guard depth < 4 else { return nil }
        switch value {
        case .string(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let object):
            for key in ["message", "msg", "error", "errMsg", "detail", "reason"] {
                if let value = object[key],
                   let message = serverMessage(from: value, depth: depth + 1) {
                    return message
                }
            }
            return nil
        case .array(let values):
            for value in values {
                if let message = serverMessage(from: value, depth: depth + 1) {
                    return message
                }
            }
            return nil
        case .integer(let value):
            return String(value)
        case .number(let value):
            return String(value)
        case .bool, .null:
            return nil
        }
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
            "天翼", "移动", "光鸭", "迅雷", "bili",
            "阿里", "阿里云盘"
        ]
        return configurationHints.contains(where: normalized.contains)
            && providerHints.contains(where: normalized.contains)
    }

    private static func isPlaybackAuthorizationMessage(
        _ message: String,
        flag: String
    ) -> Bool {
        if isExpiredQuarkShareTokenMessage(message) { return false }
        if isAuthorizationMessage(message) { return true }
        let normalized = "\(flag) \(message)".lowercased()
        let providerHints = [
            "网盘", "夸克", "uc", "百度", "115", "123",
            "天翼", "移动", "光鸭", "迅雷",
            "阿里", "阿里云盘", "ali", "alipan"
        ]
        let credentialHints = [
            "cookie", "token", "bduss", "未登录", "请先登录", "需要登录",
            "未授权", "授权失效", "登录失效", "登录过期", "扫码登录",
            "require login", "login required", "not logged in",
            "please login", "unauthorized", "credential"
        ]
        if credentialHints.contains(where: normalized.contains) {
            return true
        }
        // The lmentor cloud adapters may deliberately hide the credential
        // detail and return only “获取原画直链失败” with an empty URL. The play
        // source still identifies the cloud provider, so route the user to the
        // bundle's own configuration page instead of opening a 0 KB player.
        let opaqueCloudFailureHints = [
            "获取原画直链失败", "获取播放直链失败", "获取播放地址失败"
        ]
        return providerHints.contains(where: normalized.contains)
            && opaqueCloudFailureHints.contains(where: normalized.contains)
    }

    private static func isStructuredProxyAuthorizationEvent(
        options: [String: JSONValue],
        message: String
    ) -> Bool {
        let statusCode: Int?
        switch options["statusCode"] {
        case .integer(let value):
            statusCode = Int(exactly: value)
        case .number(let value) where value.rounded() == value:
            statusCode = Int(value)
        case .string(let value):
            statusCode = Int(value)
        default:
            statusCode = nil
        }
        if statusCode == 401 || statusCode == 403 {
            return true
        }
        let normalized = message
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let describesMissingMediaAuthorization =
            normalized.contains("无法获取下载链接")
                || normalized.contains("无法获取转码信息")
        return describesMissingMediaAuthorization
            && normalized.contains("检查授权")
    }

    private static func proxyAuthorizationMessage(
        _ message: String,
        provider: String?
    ) -> String {
        let provider = provider?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let provider, !provider.isEmpty else { return message }
        return "网盘代理（\(provider)）：\(message)"
    }

    private static func shouldAwaitLateAuthorizationMessage(
        _ message: String,
        flag: String
    ) -> Bool {
        if isPlaybackAuthorizationMessage(message, flag: flag) {
            return true
        }
        let normalized = message.lowercased()
        return normalized.contains("播放地址为空")
            || normalized.contains("empty play")
            || normalized.contains("empty url")
            || normalized.contains("loading failed")
            || normalized.contains("no playable url")
    }
}
