import Foundation

public protocol TMDBServing {
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork]
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage
    func detail(_ reference: TMDBReference) async throws -> TMDBWork
    func season(tvID: Int, number: Int) async throws -> TMDBSeason
    func personIdentity(id: Int) async throws -> TMDBPersonIdentity
    func personCredits(id: Int) async throws -> TMDBPersonCredits
    func imageConfiguration() async throws -> TMDBImageConfiguration
}

public extension TMDBServing {
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        .init(results: try await search(query: query, type: type, year: year))
    }
    func personCredits(id: Int) async throws -> TMDBPersonCredits { throw TMDBError.invalidInput }
    func personIdentity(id: Int) async throws -> TMDBPersonIdentity { throw TMDBError.invalidInput }
}

public enum TMDBError: Error, Equatable { case invalidInput, invalidResponse, credentialMissing, invalidCredential, unavailable(Int), service(Int, retryAfter: TimeInterval?) }

/// Direct, fixed-origin TMDB transport. A caller-owned credential is required;
/// source-provider headers, cookies and arbitrary upstream hosts are never used.
public actor TMDBClient: TMDBServing {
    public static let apiBase = URL(string: "https://api.themoviedb.org/3")!
    public static let imageBase = URL(string: "https://image.tmdb.org/t/p")!
    private let httpClient: HTTPClient
    private let timeout: TimeInterval
    private var credential: TMDBCredential?
    private var generation = 0
    private var requests: [UUID: Task<HTTPResponse, Error>] = [:]
    public init(credential: TMDBCredential? = nil, httpClient: HTTPClient = URLSessionHTTPClient.isolatedEphemeral(reusesBoundedConnections: true), timeout: TimeInterval = 10) { self.credential = credential; self.httpClient = httpClient; self.timeout = timeout }

    public func updateCredential(_ value: TMDBCredential?) {
        generation += 1; credential = value
        for task in requests.values { task.cancel() }
        requests.removeAll()
    }

    public func search(query: String, type: TMDBMediaType?, year: Int? = nil) async throws -> [TMDBWork] {
        try await searchPage(query: query, type: type, year: year).results.filter { $0.id > 0 && $0.mediaType != "person" && !$0.displayTitle.isEmpty }
    }

    public func searchPage(query: String, type: TMDBMediaType?, year: Int? = nil) async throws -> TMDBSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200, year == nil || (1870...2100).contains(year!) else { throw TMDBError.invalidInput }
        var parameters = ["query": query, "language": "zh-CN", "include_adult": "false", "page": "1"]
        if let year, let type { parameters[type == .movie ? "year" : "first_air_date_year"] = String(year) }
        let result: TMDBSearchPage = try await get("search/\(type?.rawValue ?? "multi")", parameters)
        return result
    }

    public func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        guard reference.id > 0 else { throw TMDBError.invalidInput }
        let credits = reference.type == .movie ? "credits" : "aggregate_credits"
        let result: TMDBWork = try await get("\(reference.type.rawValue)/\(reference.id)", [
            "language": "zh-CN", "append_to_response": "\(credits),images,alternative_titles,translations",
            "include_image_language": "zh,en,null"
        ])
        guard result.id == reference.id, !result.displayTitle.isEmpty,
              (reference.type == .movie ? result.title != nil : result.name != nil) else { throw TMDBError.invalidResponse }
        return result
    }

    public func season(tvID: Int, number: Int) async throws -> TMDBSeason {
        guard tvID > 0, (0...10_000).contains(number) else { throw TMDBError.invalidInput }
        let result: TMDBSeason = try await get("tv/\(tvID)/season/\(number)", ["language": "zh-CN"])
        guard result.seasonNumber == number,
              Set(result.episodes.map(\.episodeNumber)).count == result.episodes.count,
              result.episodes.allSatisfy({ $0.id > 0 && $0.episodeNumber > 0 && ($0.seasonNumber == nil || $0.seasonNumber == number) }) else { throw TMDBError.invalidResponse }
        return result
    }

    public func personIdentity(id: Int) async throws -> TMDBPersonIdentity {
        guard id > 0 else { throw TMDBError.invalidInput }
        let value: TMDBPersonIdentity = try await get("person/\(id)", ["language": "zh-CN"])
        guard value.id == id, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TMDBError.invalidResponse }
        return value
    }

    public func personCredits(id: Int) async throws -> TMDBPersonCredits {
        guard id > 0 else { throw TMDBError.invalidInput }
        let value: TMDBPersonCredits = try await get("person/\(id)/combined_credits", ["language": "zh-CN"])
        guard value.id == id else { throw TMDBError.invalidResponse }
        return value
    }

    public func imageConfiguration() async throws -> TMDBImageConfiguration {
        struct Configuration: Decodable { let images: TMDBImageConfiguration }
        let value: Configuration = try await get("configuration", [:])
        guard [value.images.posterSizes, value.images.stillSizes, value.images.backdropSizes].contains(where: { !($0 ?? []).isEmpty }) else { throw TMDBError.invalidResponse }
        return value.images
    }

    public static func imageURL(path: String?, size: String) -> URL? {
        guard let path, path.range(of: #"^/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp|svg)$"#, options: .regularExpression) != nil,
              size == "original" || size.range(of: #"^[wh][1-9][0-9]{1,3}$"#, options: .regularExpression) != nil else { return nil }
        return imageBase.appendingPathComponent(size).appendingPathComponent(String(path.dropFirst()))
    }

    public static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func get<T: Decodable>(_ path: String, _ parameters: [String: String]) async throws -> T {
        try Task.checkCancellation()
        guard let credential else { throw TMDBError.credentialMissing }
        let currentGeneration = generation
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var parameters = parameters
        if let key = credential.apiKey { parameters["api_key"] = key }
        if !parameters.isEmpty { components.queryItems = parameters.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw TMDBError.invalidInput }
        var headers = ["Accept": "application/json"]
        if let token = credential.bearerToken { headers["Authorization"] = "Bearer " + token }
        let request = HTTPRequest(url: url, headers: HTTPHeaders(headers),
            timeout: timeout, maximumResponseBytes: 5 * 1024 * 1024, earlyResponseLimitBytes: 5 * 1024 * 1024,
            maximumRedirects: 0, redirectPolicy: .sameOriginNoDowngrade, retryPolicy: .none, allowsNonSuccessfulStatus: true)
        let id = UUID(), transport = httpClient
        let task = Task { try await transport.send(request) }
        requests[id] = task
        defer { requests[id] = nil }
        let response: HTTPResponse
        do {
            response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch {
            guard generation == currentGeneration, !Task.isCancelled, !task.isCancelled else { throw CancellationError() }
            // Never propagate transport descriptions/URLs (v3 API keys are query parameters).
            switch TMDBLinkOutcome.error(error) {
            case .cancelled: throw CancellationError()
            case .failure(.network, _): throw URLError(.cannotConnectToHost)
            default: throw TMDBError.invalidResponse
            }
        }
        guard generation == currentGeneration, !task.isCancelled else { throw CancellationError() }
        guard response.url.scheme == "https", response.url.host == Self.apiBase.host,
              response.url.port == Self.apiBase.port, response.url.path == url.path else { throw TMDBError.invalidResponse }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw TMDBError.service(response.statusCode, retryAfter: Self.retryAfter(response.headers["Retry-After"])) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(T.self, from: response.body) else { throw TMDBError.invalidResponse }
        return result
    }
}
