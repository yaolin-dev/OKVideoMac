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

actor AndroidDexBridgeRuntime {
    private static let bridgeVersion = "0.3.14"
    private static let bridgeVersionCode = 26
    private static let networkCheckInterval: TimeInterval = 30
    private let sdkRoot = URL(fileURLWithPath: "/Volumes/XcodeDev/AndroidSDK")
    private let compatibilityADB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/OKVideoMac/AndroidPlatformTools/adb"
        )
    private let avdHome = URL(fileURLWithPath: "/Volumes/XcodeDev/AndroidAVD")
    private let runtimeDirectory = URL(
        fileURLWithPath: "/Volumes/XcodeDev/OKVideoMacBuild/AndroidRuntimeApp",
        isDirectory: true
    )
    private let device = "emulator-5554"
    private let hostPort = BridgeServerPort.host
    private var emulatorProcess: Process?
    private var ready = false
    private var acceptsNewerBridge = false
    private var lastNetworkCheck: Date?
    private var readinessTask: Task<Void, Error>?

    private var adbExecutable: URL {
        if FileManager.default.isExecutableFile(atPath: compatibilityADB.path) {
            return compatibilityADB
        }
        return sdkRoot.appendingPathComponent("platform-tools/adb")
    }

    func ensureReady() async throws {
        if ready {
            if let lastNetworkCheck,
               Date().timeIntervalSince(lastNetworkCheck)
                    < Self.networkCheckInterval {
                return
            }
            if await isHealthy(acceptVersionMismatch: acceptsNewerBridge) {
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
        let adb = adbExecutable
        guard FileManager.default.isExecutableFile(atPath: adb.path) else {
            throw AppError.spider("Android ADB 运行时不可用")
        }

        ready = false
        _ = try? run(
            adb,
            [
                "-s", device, "shell", "am", "force-stop",
                "com.okvideomac.dexbridge"
            ]
        )
        try configurePortForwards(adb)
        _ = try? run(
            adb,
            [
                "-s", device, "shell", "am", "start",
                "-n", "com.okvideomac.dexbridge/.BridgeActivity"
            ]
        )
        for _ in 0..<20 {
            if await isHealthy(
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

    private func prepareRuntime() async throws {
        let adb = adbExecutable
        let emulator = sdkRoot.appendingPathComponent("emulator/emulator")
        guard FileManager.default.isExecutableFile(atPath: adb.path),
              FileManager.default.isExecutableFile(atPath: emulator.path) else {
            throw AppError.spider(
                "Java/Dex Android 运行时未安装在 /Volumes/XcodeDev/AndroidSDK"
            )
        }

        if (try? run(adb, ["-s", device, "get-state"])) == nil {
            try launchEmulator(emulator)
        }
        try await waitForBoot(adb)
        let installedVersionCode = installedBridgeVersionCode(adb)
        let hasNewerBridge = installedVersionCode.map {
            $0 > Self.bridgeVersionCode
        } ?? false
        if ready,
           await isHealthy(acceptVersionMismatch: hasNewerBridge),
           let lastNetworkCheck,
           Date().timeIntervalSince(lastNetworkCheck)
                < Self.networkCheckInterval {
            return
        }
        try configurePortForwards(adb)

        let networkWasRepaired: Bool
        if let lastNetworkCheck,
           Date().timeIntervalSince(lastNetworkCheck)
                < Self.networkCheckInterval {
            networkWasRepaired = false
        } else {
            networkWasRepaired = try await ensureEmulatorNetwork(adb)
        }
        if !networkWasRepaired,
           await isHealthy(acceptVersionMismatch: hasNewerBridge) {
            ready = true
            acceptsNewerBridge = hasNewerBridge
            lastNetworkCheck = Date()
            return
        }

        let apk = try bridgeAPK()
        _ = try run(adb, ["-s", device, "install", "-r", apk.path])
        _ = try run(
            adb,
            [
                "-s", device, "shell", "am", "start",
                "-n", "com.okvideomac.dexbridge/.BridgeActivity"
            ]
        )
        for _ in 0..<30 {
            if await isHealthy() {
                ready = true
                acceptsNewerBridge = false
                lastNetworkCheck = Date()
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AppError.spider("Java/Dex Android 桥启动超时")
    }

    private func configurePortForwards(_ adb: URL) throws {
        let forwards = [
            (host: BridgeServerPort.host, guest: BridgeServerPort.guest),
            (
                host: BridgeServerPort.kaiserHost,
                guest: BridgeServerPort.kaiserGuest
            ),
            (
                host: BridgeServerPort.cloudFileHost,
                guest: BridgeServerPort.cloudFileGuest
            )
        ]
        let listing = (try? run(
            adb,
            ["-s", device, "forward", "--list"]
        )) ?? ""
        for forward in forwards {
            if Self.portForwardExists(
                listing: listing,
                device: device,
                host: forward.host,
                guest: forward.guest
            ) {
                continue
            }
            _ = try? run(
                adb,
                [
                    "-s", device, "forward", "--remove",
                    "tcp:\(forward.host)"
                ]
            )
            _ = try run(
                adb,
                [
                    "-s", device, "forward",
                    "tcp:\(forward.host)", "tcp:\(forward.guest)"
                ]
            )
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

    private func ensureEmulatorNetwork(_ adb: URL) async throws -> Bool {
        if networkLooksReady(adb) {
            lastNetworkCheck = Date()
            return false
        }

        _ = try? run(
            adb,
            [
                "-s", device, "shell", "cmd", "wifi",
                "clear-user-disabled-networks"
            ]
        )
        _ = try? run(
            adb,
            [
                "-s", device, "shell", "cmd", "wifi",
                "connect-network", "AndroidWifi", "open"
            ]
        )

        for _ in 0..<60 {
            if networkLooksReady(adb) {
                lastNetworkCheck = Date()
                return true
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AppError.spider("Java/Dex Android 运行时网络连接失败，请稍后重试")
    }

    private func networkLooksReady(_ adb: URL) -> Bool {
        guard let status = try? run(
            adb,
            ["-s", device, "shell", "cmd", "wifi", "status"]
        ), let routes = try? run(
            adb,
            ["-s", device, "shell", "ip", "route", "show", "table", "all"]
        ) else {
            return false
        }
        return Self.networkLooksReady(status: status, routes: routes)
    }

    static func networkLooksReady(status: String, routes: String) -> Bool {
        status.contains("Wifi is connected") && routes.contains("default via")
    }

    private func launchEmulator(_ executable: URL) throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-avd", "OKVideoDexBridge",
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            "-no-metrics",
            "-no-snapshot",
            "-gpu", "off",
            "-accel", "on",
            "-datadir", runtimeDirectory.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_SDK_ROOT"] = sdkRoot.path
        environment["ANDROID_AVD_HOME"] = avdHome.path
        process.environment = environment
        let logURL = runtimeDirectory.appendingPathComponent("emulator.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        emulatorProcess = process
    }

    private func waitForBoot(_ adb: URL) async throws {
        for _ in 0..<240 {
            if let value = try? run(
                adb,
                ["-s", device, "shell", "getprop", "sys.boot_completed"]
            ), value.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
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

    private func installedBridgeVersionCode(_ adb: URL) -> Int? {
        guard let output = try? run(
            adb,
            [
                "-s", device, "shell", "dumpsys", "package",
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
        acceptVersionMismatch: Bool = false
    ) async -> Bool {
        guard let url = URL(
            string: "http://127.0.0.1:\(hostPort)/health"
        ) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let (data, response) = try await URLSession(
                configuration: configuration
            ).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                return false
            }
            return object["ok"] as? Bool == true
                && (
                    object["version"] as? String == Self.bridgeVersion
                        || acceptVersionMismatch
                )
        } catch {
            return false
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AppError.spider(
                "Android 工具失败：\(String(text.prefix(1_000)))"
            )
        }
        return text
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
