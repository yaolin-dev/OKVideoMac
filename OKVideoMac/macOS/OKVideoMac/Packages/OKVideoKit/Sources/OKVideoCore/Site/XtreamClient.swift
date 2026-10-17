import Foundation
import OSLog

public struct XtreamCatalogResponsePolicy: Equatable, Sendable {
    /// An adjustable initial safety value, not an Xtream protocol limit.
    public static let initialSafetyDefault = XtreamCatalogResponsePolicy(
        maximumResponseBytes: 64 * 1_024 * 1_024
    )

    public var maximumResponseBytes: Int

    public init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }
}

public struct XtreamAccount: Equatable, Sendable {
    public let status: String?
    public let expirationDate: Date?
    public let isTrial: Bool?
    public let activeConnections: Int?
    public let maxConnections: Int?
    public let allowedOutputFormats: [String]
    public let serverTimeZoneID: String?

    public init(
        status: String?,
        expirationDate: Date?,
        isTrial: Bool?,
        activeConnections: Int?,
        maxConnections: Int?,
        allowedOutputFormats: [String],
        serverTimeZoneID: String? = nil
    ) {
        self.status = status
        self.expirationDate = expirationDate
        self.isTrial = isTrial
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.serverTimeZoneID = serverTimeZoneID
    }
}

public enum XtreamClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidAuthenticationResponse
    case authenticationRejected(status: String?)
    case accountUnavailable(status: String)
    case unsupportedAccountStatus(status: String)
    case invalidResourceIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidAuthenticationResponse:
            return "The Xtream server returned an invalid account response."
        case .authenticationRejected:
            return "The Xtream server rejected this account."
        case .accountUnavailable(let status):
            return "The Xtream account is unavailable (\(status))."
        case .unsupportedAccountStatus(let status):
            return "The Xtream server returned an unsupported account status (\(status))."
        case .invalidResourceIdentifier:
            return "The Xtream resource identifier is invalid."
        }
    }
}

public final class XtreamClient: @unchecked Sendable {
    private static let metadataMaximumResponseBytes = 8 * 1_024 * 1_024
    private static let accountLogger = Logger(
        subsystem: "com.okvideomac.OKVideoMac",
        category: "XtreamAccount"
    )

    private let httpClient: HTTPClient
    private let credentials: XtreamCredentials
    private let urlBuilder: XtreamURLBuilder
    private let responseDecoder: XtreamResponseDecoder
    private let catalogResponsePolicy: XtreamCatalogResponsePolicy
    private let userAgent: String
    private let requestLimiter: XtreamRequestLimiter

    public init(
        endpoint: XtreamEndpoint,
        credentials: XtreamCredentials,
        httpClient: HTTPClient,
        userAgent: String,
        catalogResponsePolicy: XtreamCatalogResponsePolicy = .initialSafetyDefault,
        maximumConcurrentRequests: Int = 2
    ) {
        self.httpClient = httpClient
        self.credentials = credentials
        urlBuilder = XtreamURLBuilder(endpoint: endpoint)
        responseDecoder = XtreamResponseDecoder()
        self.catalogResponsePolicy = catalogResponsePolicy
        let normalizedUserAgent = userAgent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.userAgent = normalizedUserAgent.isEmpty ? "OKVideoMac" : normalizedUserAgent
        requestLimiter = XtreamRequestLimiter(
            maximumConcurrentRequests: maximumConcurrentRequests
        )
    }

    public func authenticate(now: Date = Date()) async throws -> XtreamAccount {
        let response = try await request(
            XtreamAuthenticationResponseDTO.self,
            action: nil,
            parameters: [],
            isCatalog: false
        )
        guard let info = response.userInfo else {
            throw XtreamClientError.invalidAuthenticationResponse
        }
        if info.auth == false {
            throw XtreamClientError.authenticationRejected(status: info.status)
        }
        guard let status = info.status?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else {
            throw XtreamClientError.invalidAuthenticationResponse
        }
        let normalizedStatus = status.lowercased()
        guard normalizedStatus == "active" else {
            if Self.isKnownUnavailableStatus(normalizedStatus) {
                throw XtreamClientError.accountUnavailable(status: status)
            }
            throw XtreamClientError.unsupportedAccountStatus(status: status)
        }
        let expirationDate = info.expirationTimestamp.flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }
        if let expirationDate, expirationDate <= now {
            // The server's explicit Active status remains the admission signal.
            // A past exp_date is a conflict to diagnose, not a local rejection.
            Self.accountLogger.warning(
                "Xtream account reports Active with exp_date \(expirationDate.timeIntervalSince1970, privacy: .public) at local time \(now.timeIntervalSince1970, privacy: .public); retaining expiration metadata and allowing subsequent API requests."
            )
        }
        return XtreamAccount(
            status: info.status,
            expirationDate: expirationDate,
            isTrial: info.isTrial,
            activeConnections: info.activeConnections,
            maxConnections: info.maxConnections,
            allowedOutputFormats: info.allowedOutputFormats,
            serverTimeZoneID: response.serverInfo?.timezone.flatMap { TimeZone(identifier: $0)?.identifier }
        )
    }

    public func archiveRequest(streamID: String, outputFormat: String, programme: EPGProgramme,
                               offset: TimeInterval, now: Date, serverTimeZoneID: String?) throws -> XtreamArchiveRequest {
        try urlBuilder.archiveRequest(credentials: credentials,
            streamID: validIdentifier(streamID), outputFormat: outputFormat, programme: programme,
            offset: offset, now: now, serverTimeZoneID: serverTimeZoneID)
    }

    public func liveCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(XtreamCategoryDTO.self, action: .liveCategories)
    }

    public func shortEPG(streamID: String) async throws -> EPGPayload {
        try await epg(streamID: streamID, archive: false)
    }
    public func archiveEPG(streamID: String) async throws -> EPGPayload {
        try await epg(streamID: streamID, archive: true)
    }
    private func epg(streamID: String, archive: Bool) async throws -> EPGPayload {
        do {
            let data = try await responseData(action: archive ? .simpleDataTable : .shortEPG, parameters:
                [URLQueryItem(name: "stream_id", value: try validIdentifier(streamID))]
                + (archive ? [] : [URLQueryItem(name: "limit", value: "4")]), isCatalog: false)
            let response = try XtreamEPGResponse(data: data)
            var timezone: TimeZone?
            if response.requiresServerTimezone {
                let authentication = try await request(XtreamAuthenticationResponseDTO.self,
                    action: nil, parameters: [], isCatalog: false)
                timezone = authentication.serverInfo?.timezone.flatMap(TimeZone.init(identifier:))
            }
            return try response.payload(streamID: streamID, timezone: timezone,
                                        secrets: [credentials.username, credentials.password])
        } catch HTTPClientError.statusCode(let status) where [404, 405, 501].contains(status) {
            return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []), unsupported: true)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? HTTPClientError) == .cancelled {
                throw CancellationError()
            }
            // Raw transport/decoder errors may contain credential-bearing URLs.
            throw EPGFetchError.unavailable
        }
    }

    public func liveStreams(categoryID: String? = nil) async throws
        -> [XtreamLiveStreamDTO] {
        try await catalog(
            XtreamLiveStreamDTO.self,
            action: .liveStreams,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func vodCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(
            XtreamCategoryDTO.self,
            action: .vodCategories
        )
    }

    public func vodStreams(categoryID: String? = nil) async throws
        -> [XtreamVODStreamDTO] {
        try await catalog(
            XtreamVODStreamDTO.self,
            action: .vodStreams,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func vodInfo(streamID: String) async throws -> XtreamVODInfoResponseDTO {
        try await request(
            XtreamVODInfoResponseDTO.self,
            action: .vodInfo,
            parameters: [
                URLQueryItem(
                    name: "vod_id",
                    value: try validIdentifier(streamID)
                )
            ],
            isCatalog: false
        )
    }

    public func seriesCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(
            XtreamCategoryDTO.self,
            action: .seriesCategories
        )
    }

    public func series(categoryID: String? = nil) async throws
        -> [XtreamSeriesDTO] {
        try await catalog(
            XtreamSeriesDTO.self,
            action: .series,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func seriesInfo(seriesID: String) async throws
        -> XtreamSeriesInfoResponseDTO {
        try await request(
            XtreamSeriesInfoResponseDTO.self,
            action: .seriesInfo,
            parameters: [
                URLQueryItem(
                    name: "series_id",
                    value: try validIdentifier(seriesID)
                )
            ],
            isCatalog: false
        )
    }

    public func playbackURL(
        kind: XtreamMediaKind,
        remoteID: String,
        containerExtension: String?
    ) throws -> URL {
        try urlBuilder.playbackURL(
            kind: kind,
            remoteID: validIdentifier(remoteID),
            containerExtension: containerExtension,
            credentials: credentials
        )
    }

    private func catalog<T: Decodable>(
        _ type: T.Type,
        action: XtreamAction,
        parameters: [URLQueryItem] = []
    ) async throws -> [T] {
        let data = try await responseData(
            action: action,
            parameters: parameters,
            isCatalog: true
        )
        return try responseDecoder.decodeArray(type, from: data)
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        action: XtreamAction?,
        parameters: [URLQueryItem],
        isCatalog: Bool
    ) async throws -> T {
        let data = try await responseData(
            action: action,
            parameters: parameters,
            isCatalog: isCatalog
        )
        return try responseDecoder.decode(type, from: data)
    }

    private func responseData(
        action: XtreamAction?,
        parameters: [URLQueryItem],
        isCatalog: Bool
    ) async throws -> Data {
        let url = try urlBuilder.playerAPIURL(
            credentials: credentials,
            action: action,
            parameters: parameters
        )
        let maximumBytes = [.shortEPG, .simpleDataTable].contains(action) ? 1024 * 1024 : isCatalog
            ? catalogResponsePolicy.maximumResponseBytes
            : Self.metadataMaximumResponseBytes
        let request = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json, text/plain;q=0.9",
                "User-Agent": userAgent
            ],
            timeout: 30,
            maximumResponseBytes: maximumBytes,
            earlyResponseLimitBytes: isCatalog || [.shortEPG, .simpleDataTable].contains(action) ? maximumBytes : nil,
            maximumRedirects: 3,
            redirectPolicy: .sameOriginNoDowngrade,
            retryPolicy: HTTPRetryPolicy(
                maximumRetries: 1,
                initialDelay: 0.25
            )
        )

        try await requestLimiter.acquire()
        do {
            let response = try await httpClient.send(request)
            await requestLimiter.release()
            return response.body
        } catch {
            await requestLimiter.release()
            throw error
        }
    }

    private func categoryParameter(_ categoryID: String?) throws -> [URLQueryItem] {
        guard let categoryID else { return [] }
        return [
            URLQueryItem(
                name: "category_id",
                value: try validIdentifier(categoryID)
            )
        ]
    }

    private func validIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XtreamClientError.invalidResourceIdentifier
        }
        return trimmed
    }

    private static func isKnownUnavailableStatus(_ status: String) -> Bool {
        let unavailableStatuses: Set<String> = [
            "banned", "disabled", "expired", "inactive"
        ]
        if unavailableStatuses.contains(status) {
            return true
        }
        let components = status.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        return components.contains { unavailableStatuses.contains($0) }
    }
}

private actor XtreamRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumConcurrentRequests: Int
    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(maximumConcurrentRequests: Int) {
        let limit = max(1, maximumConcurrentRequests)
        self.maximumConcurrentRequests = limit
        availablePermits = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if availablePermits > 0 {
                    availablePermits -= 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(
                        Waiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
        guard acquired else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits = min(
                maximumConcurrentRequests,
                availablePermits + 1
            )
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
