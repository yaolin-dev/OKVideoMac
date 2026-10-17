import Foundation

public enum XtreamSiteProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidCategoryIdentifier
    case invalidVideoIdentifier
    case invalidPlaybackLocator
    case missingMovie
    case missingSeries

    public var errorDescription: String? {
        switch self {
        case .invalidCategoryIdentifier:
            return "The Xtream category identifier is invalid."
        case .invalidVideoIdentifier:
            return "The Xtream video identifier is invalid."
        case .invalidPlaybackLocator:
            return "The Xtream playback reference is invalid."
        case .missingMovie:
            return "The Xtream server did not return the requested movie."
        case .missingSeries:
            return "The Xtream server did not return the requested series."
        }
    }
}

/// Native, credential-isolated Xtream provider.
///
/// Catalog and detail models contain only stable identifiers and metadata.
/// Credential-bearing playback URLs are created only by `player` and are
/// never used as an episode or history identity.
public final class XtreamSiteProvider: SiteProvider, @unchecked Sendable {
    public let site: SiteConfiguration
    public let capability: SiteCapability = .xtream

    private static let providerKind = "xtream"
    private static let providerVersion = 1

    private let configuration: XtreamProviderConfiguration
    private let client: XtreamClient
    private let cache: XtreamCatalogCache
    private let searchIndex = XtreamSearchIndex()
    private let pageSize: Int
    private let userAgent: String
    private let movieSourceName: String
    private let episodesSourceName: String
    private let seasonSourceName: @Sendable (Int) -> String
    private let episodeName: @Sendable (Int) -> String
    private let uncategorizedLiveGroupName: String
    // Runtime-only checks also reject account values embedded in otherwise
    // innocuous-looking artwork paths. They never enter a catalog or cache.
    private let liveArtworkCredentialValues: [String]

    public init(
        configuration: XtreamProviderConfiguration,
        credentials: XtreamCredentials,
        httpClient: HTTPClient,
        userAgent: String,
        catalogResponsePolicy: XtreamCatalogResponsePolicy = .initialSafetyDefault,
        maximumConcurrentRequests: Int = 2,
        pageSize: Int = 60,
        catalogCacheTTL: TimeInterval = 15 * 60,
        movieSourceName: String = "Movie",
        episodesSourceName: String = "Episodes",
        seasonSourceName: @escaping @Sendable (Int) -> String = {
            "Season \($0)"
        },
        episodeName: @escaping @Sendable (Int) -> String = {
            "Episode \($0)"
        },
        uncategorizedLiveGroupName: String = "Uncategorized"
    ) throws {
        guard let site = configuration.providerConfiguration.sites.first else {
            throw XtreamProviderConfigurationError.malformedConfiguration
        }
        self.configuration = configuration
        self.site = site
        let normalizedUserAgent = userAgent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.userAgent = normalizedUserAgent.isEmpty ? "OKVideoMac" : normalizedUserAgent
        client = XtreamClient(
            endpoint: try XtreamEndpoint(
                serverURL: configuration.serverBaseURL
            ),
            credentials: credentials,
            httpClient: httpClient,
            userAgent: self.userAgent,
            catalogResponsePolicy: catalogResponsePolicy,
            maximumConcurrentRequests: maximumConcurrentRequests
        )
        self.pageSize = max(1, min(pageSize, 500))
        self.movieSourceName = movieSourceName
        self.episodesSourceName = episodesSourceName
        self.seasonSourceName = seasonSourceName
        self.episodeName = episodeName
        self.uncategorizedLiveGroupName = uncategorizedLiveGroupName
        liveArtworkCredentialValues = [credentials.username, credentials.password]
            .filter { !$0.isEmpty }
        cache = XtreamCatalogCache(ttl: max(1, catalogCacheTTL))
    }

    /// Fetches metadata only. This snapshot is deliberately separate from
    /// persisted imported playlists and the Movie/Series detail cache. Each
    /// refresh obtains a fresh catalog and never probes a media URL or EPG.
    public func liveCatalog() async throws -> LiveCatalogSnapshot {
        async let categoryRequest = client.liveCategories()
        async let streamRequest = client.liveStreams()
        let (categories, streams) = try await (categoryRequest, streamRequest)
        try Task.checkCancellation()

        let providerIdentity = configuration.providerID.uuidString.lowercased()
        let groupPrefix = "xtr1.live.group.\(providerIdentity)"
        let fallbackGroupID = "\(groupPrefix).uncategorized"
        var groups: [LiveGroup] = []
        var categoryIndices: [String: Int] = [:]
        for category in categories {
            guard let remoteID = normalized(category.categoryID),
                  XtreamHex.isValidSourceValue(remoteID),
                  categoryIndices[remoteID] == nil else { continue }
            categoryIndices[remoteID] = groups.count
            groups.append(LiveGroup(
                name: normalized(category.categoryName) ?? remoteID,
                explicitID: "\(groupPrefix).category.\(XtreamHex.encode(remoteID))"
            ))
        }

        var fallbackIndex: Int?
        var seenStreamIDs: Set<String> = []
        for (index, stream) in streams.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let remoteID = normalized(stream.streamID),
                  let ts = try? XtreamLivePlaybackLocator(
                    providerID: configuration.providerID,
                    streamID: remoteID,
                    outputFormat: .ts
                  ), seenStreamIDs.insert(remoteID).inserted else { continue }
            let hls = try XtreamLivePlaybackLocator(
                providerID: configuration.providerID,
                streamID: remoteID,
                outputFormat: .m3u8
            )
            let preferredExtension = stream.containerExtension?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            let locators = preferredExtension == "m3u8" ? [hls, ts] : [ts, hls]
            let archive = stream.tvArchive == true ? stream.tvArchiveDuration.flatMap {
                (1...365).contains($0) ? XtreamArchiveCapability(retentionDays: $0) : nil
            } : nil
            let targets = try locators.map { locator in
                try LiveStream(
                    name: locator.outputFormat == .ts ? "TS" : "HLS",
                    target: .provider(.xtreamLive(locator)),
                    format: locator.outputFormat.rawValue,
                    archive: archive
                )
            }

            let groupIndex: Int
            if let categoryID = normalized(stream.categoryID),
               let categoryIndex = categoryIndices[categoryID] {
                groupIndex = categoryIndex
            } else if let fallbackIndex {
                groupIndex = fallbackIndex
            } else {
                groupIndex = groups.count
                fallbackIndex = groupIndex
                groups.append(LiveGroup(
                    name: uncategorizedLiveGroupName,
                    explicitID: fallbackGroupID
                ))
            }
            let groupName = groups[groupIndex].name
            let groupID = groups[groupIndex].id
            groups[groupIndex].channels.append(LiveChannel(
                groupName: groupName,
                name: normalized(stream.name) ?? remoteID,
                number: normalized(stream.number),
                logoURL: safeLiveArtworkURL(stream.streamIcon),
                tvgID: normalized(stream.epgChannelID).flatMap { value in
                    value.count <= 512 && !value.contains("://")
                        && !liveArtworkCredentialValues.contains(where: { value.contains($0) }) ? value : nil
                },
                streams: targets,
                explicitID: "xtr1.live.channel.\(providerIdentity).\(XtreamHex.encode(remoteID))",
                explicitGroupID: groupID
            ))
        }
        try Task.checkCancellation()
        return LiveCatalogSnapshot(
            sourceID: .xtream(configuration.providerID),
            groups: groups,
            epgURL: nil
        )
    }

    /// Resolves only a fully bound Live reference. This constructs the
    /// credential-bearing URL at the point of use and performs no request.
    public func resolveLivePlayback(
        _ reference: PlaybackResourceReference
    ) throws -> SitePlaybackResult {
        guard let locator = reference.xtreamLiveLocator,
              locator.providerID == configuration.providerID,
              reference.configurationIdentity
                == configuration.providerID.uuidString.lowercased(),
              reference.siteIdentity == site.key,
              reference.providerKind == Self.providerKind,
              reference.providerVersion == Self.providerVersion,
              reference.stability == .providerStable,
              reference.expiresAt == nil else {
            throw XtreamSiteProviderError.invalidPlaybackLocator
        }
        let url = try client.playbackURL(
            kind: .live,
            remoteID: locator.streamID,
            containerExtension: locator.outputFormat.rawValue
        )
        return SitePlaybackResult(
            url: url.absoluteString,
            needsParsing: false,
            flag: "",
            headers: HTTPHeaders(["User-Agent": userAgent]),
            format: locator.outputFormat.rawValue,
            validationPolicy: .playerAuthoritative,
            resourceReference: reference
        )
    }

    /// Revalidates the account immediately before a Live playback URL is
    /// materialized. This is metadata authentication only; it never probes or
    /// pre-opens a media path.
    @discardableResult
    public func validateLivePlaybackAccount() async throws -> XtreamAccount {
        try await client.authenticate()
    }

    public func resolveLiveArchive(_ reference: PlaybackResourceReference, programme: EPGProgramme,
                                   offset: TimeInterval, now: Date, serverTimeZoneID: String?) throws -> XtreamArchiveRequest {
        _ = try resolveLivePlayback(reference)
        guard let locator = reference.xtreamLiveLocator else { throw XtreamSiteProviderError.invalidPlaybackLocator }
        return try client.archiveRequest(streamID: locator.streamID, outputFormat: locator.outputFormat.rawValue,
            programme: programme, offset: offset, now: now, serverTimeZoneID: serverTimeZoneID)
    }

    public func home() async throws -> SiteHome {
        // Revalidate the server's explicit account state before loading the
        // catalogue. An Active response remains admissible when exp_date is
        // stale; explicit authentication and status failures still stop here.
        _ = try await client.authenticate()
        async let movieCategories = vodCategories()
        async let seriesCategories = seriesCategories()
        let (movies, series) = try await (movieCategories, seriesCategories)
        return SiteHome(
            categories: movies.compactMap(movieCategory)
                + series.compactMap(seriesCategory),
            recommendations: []
        )
    }

    public func category(
        id: String,
        page: Int,
        filters: [String: String]
    ) async throws -> VideoPage {
        guard page >= 1 else {
            throw XtreamSiteProviderError.invalidCategoryIdentifier
        }
        if let categoryID = XtreamProviderIdentifier.decode(
            id,
            prefix: .movieCategory
        ) {
            let streams = try await vodStreams(categoryID: categoryID)
            return paginated(
                streams.compactMap(movieSummary),
                page: page
            )
        }
        if let categoryID = XtreamProviderIdentifier.decode(
            id,
            prefix: .seriesCategory
        ) {
            let series = try await series(categoryID: categoryID)
            return paginated(
                series.compactMap(seriesSummary),
                page: page
            )
        }
        throw XtreamSiteProviderError.invalidCategoryIdentifier
    }

    public func detail(id: String) async throws -> VideoDetail {
        if let remoteID = XtreamProviderIdentifier.decode(
            id,
            prefix: .movie
        ) {
            return try await movieDetail(remoteID: remoteID)
        }
        if let remoteID = XtreamProviderIdentifier.decode(
            id,
            prefix: .series
        ) {
            return try await seriesDetail(remoteID: remoteID)
        }
        throw XtreamSiteProviderError.invalidVideoIdentifier
    }

    private func movieDetail(remoteID: String) async throws -> VideoDetail {
        let response = try await client.vodInfo(streamID: remoteID)
        let cached = await cache.movie(streamID: remoteID)
        guard response.info != nil || response.movieData != nil || cached != nil else {
            throw XtreamSiteProviderError.missingMovie
        }
        let movieData = response.movieData
        let info = response.info
        let extensionValue = movieData?.containerExtension
            ?? cached?.containerExtension
        let locator = try XtreamPlaybackLocator.movie(
            remoteID: remoteID,
            containerExtension: extensionValue
        )
        let resourceReference = playbackReference(for: locator)
        let title = firstNonEmpty(
            info?.name,
            movieData?.name,
            cached?.name,
            remoteID
        ) ?? remoteID
        let categoryName = await categoryName(
            for: movieData?.categoryID ?? cached?.categoryID,
            kind: .movieCategory
        )
        let summary = VideoSummary(
            siteKey: site.key,
            siteName: site.name,
            videoID: XtreamProviderIdentifier.encode(
                remoteID,
                prefix: .movie
            ),
            title: title,
            posterURL: safeArtworkURL(info?.movieImage)
                ?? safeArtworkURL(cached?.streamIcon),
            remarks: movieRemarks(rating: info?.rating ?? cached?.rating),
            year: year(from: info?.releaseDate),
            categoryName: categoryName
        )
        let episode = PlayEpisode(
            name: title,
            url: locator.encoded,
            referenceIdentity: locator.episodeIdentity,
            providerResourceReference: resourceReference,
            metadata: .init(form: .movie)
        )
        return VideoDetail(
            summary: summary,
            area: info?.genre,
            director: normalized(info?.director),
            actors: normalized(info?.cast),
            synopsis: normalized(info?.plot),
            playSources: [
                PlaySource(
                    name: movieSourceName,
                    episodes: [episode],
                    referenceIdentity: locator.sourceIdentity
                )
            ]
        )
    }

    private func seriesDetail(remoteID: String) async throws -> VideoDetail {
        let response = try await client.seriesInfo(seriesID: remoteID)
        let cached = await cache.series(seriesID: remoteID)
        let hasEpisodes = response.episodesBySeason.values.contains {
            !$0.isEmpty
        }
        guard response.info != nil || cached != nil || hasEpisodes else {
            throw XtreamSiteProviderError.missingSeries
        }
        let info = response.info
        let title = firstNonEmpty(info?.name, cached?.name, remoteID) ?? remoteID
        let categoryName = await categoryName(
            for: info?.categoryID ?? cached?.categoryID,
            kind: .seriesCategory
        )
        let summary = VideoSummary(
            siteKey: site.key,
            siteName: site.name,
            videoID: XtreamProviderIdentifier.encode(
                remoteID,
                prefix: .series
            ),
            title: title,
            posterURL: safeArtworkURL(info?.cover)
                ?? safeArtworkURL(cached?.cover),
            remarks: movieRemarks(rating: info?.rating ?? cached?.rating),
            year: year(from: info?.releaseDate ?? cached?.releaseDate),
            categoryName: categoryName
        )

        var seasonNames: [Int: String] = [:]
        for season in response.seasons {
            guard let number = season.seasonNumber,
                  (0...10_000).contains(number),
                  seasonNames[number] == nil,
                  let name = normalized(season.name) else {
                continue
            }
            seasonNames[number] = name
        }
        var playSources: [PlaySource] = []
        for seasonNumber in response.episodesBySeason.keys.sorted() {
            guard (0...10_000).contains(seasonNumber) else { continue }
            let sortedEpisodes = (response.episodesBySeason[seasonNumber] ?? [])
                .sorted(by: episodeSort)
            let episodes = sortedEpisodes.compactMap { episode in
                try? seriesEpisode(
                    episode,
                    seriesID: remoteID,
                    seasonNumber: seasonNumber
                )
            }
            guard !episodes.isEmpty else { continue }
            let sourceName = seasonNames[seasonNumber]
                ?? (seasonNumber == 0
                    ? episodesSourceName
                    : seasonSourceName(seasonNumber))
            let sourceIdentity = XtreamPlaybackLocator.seriesSourceIdentity(
                seriesID: remoteID,
                seasonNumber: seasonNumber
            )
            playSources.append(
                PlaySource(
                    name: sourceName,
                    episodes: episodes,
                    referenceIdentity: sourceIdentity
                )
            )
        }
        guard !playSources.isEmpty else {
            throw XtreamSiteProviderError.missingSeries
        }
        return VideoDetail(
            summary: summary,
            area: normalized(info?.genre ?? cached?.genre),
            director: normalized(info?.director ?? cached?.director),
            actors: normalized(info?.cast ?? cached?.cast),
            synopsis: normalized(info?.plot ?? cached?.plot),
            playSources: playSources
        )
    }

    private func seriesEpisode(
        _ dto: XtreamEpisodeDTO,
        seriesID: String,
        seasonNumber: Int
    ) throws -> PlayEpisode? {
        guard let remoteID = normalized(dto.id) else { return nil }
        let locator = try XtreamPlaybackLocator.seriesEpisode(
            seriesID: seriesID,
            seasonNumber: seasonNumber,
            remoteID: remoteID,
            containerExtension: dto.containerExtension
        )
        let fallbackName = dto.episodeNumber.map(episodeName)
        let name = firstNonEmpty(dto.title, fallbackName, remoteID) ?? remoteID
        return PlayEpisode(
            name: name,
            url: locator.encoded,
            referenceIdentity: locator.episodeIdentity,
            providerResourceReference: playbackReference(for: locator),
            metadata: .init(form: .series, season: seasonNumber, episode: dto.episodeNumber)
        )
    }

    private func episodeSort(
        _ lhs: XtreamEpisodeDTO,
        _ rhs: XtreamEpisodeDTO
    ) -> Bool {
        let leftNumber = lhs.episodeNumber ?? Int.max
        let rightNumber = rhs.episodeNumber ?? Int.max
        if leftNumber != rightNumber { return leftNumber < rightNumber }
        return (normalized(lhs.id) ?? "") < (normalized(rhs.id) ?? "")
    }

    public func search(
        keyword: String,
        page: Int,
        quick: Bool
    ) async throws -> VideoPage {
        guard page >= 1 else {
            throw XtreamSiteProviderError.invalidCategoryIdentifier
        }
        let query = XtreamSearchIndex.normalized(keyword)
        guard !query.isEmpty else {
            return VideoPage(
                items: [],
                pagination: Pagination(page: page, pageCount: 0)
            )
        }
        async let movieCatalog = allVODStreams()
        async let seriesCatalog = allSeries()
        let (movies, shows) = try await (movieCatalog, seriesCatalog)
        let results = await searchIndex.results(
            movies: movies.values.compactMap(movieSummary),
            series: shows.values.compactMap(seriesSummary),
            keyword: query,
            rebuild: movies.refreshed || shows.refreshed
        )
        return paginated(results, page: page)
    }

    public func player(
        flag: String,
        episodeURL: String
    ) async throws -> SitePlaybackResult {
        guard let locator = XtreamPlaybackLocator(encoded: episodeURL) else {
            throw XtreamSiteProviderError.invalidPlaybackLocator
        }
        let mediaKind: XtreamMediaKind = locator.kind == .movie
            ? .movie
            : .series
        let url = try client.playbackURL(
            kind: mediaKind,
            remoteID: locator.remoteID,
            containerExtension: locator.containerExtension
        )
        return SitePlaybackResult(
            url: url.absoluteString,
            needsParsing: false,
            flag: flag,
            headers: HTTPHeaders(["User-Agent": userAgent]),
            format: locator.containerExtension,
            validationPolicy: .playerAuthoritative,
            networkPolicy: .systemHTTPProxy,
            resourceReference: playbackReference(for: locator)
        )
    }

    public func acceptsPlaybackResourceReference(
        _ reference: PlaybackResourceReference
    ) -> Bool {
        guard reference.resourceKind == .episode,
              reference.schemaVersion == 1,
              reference.configurationIdentity
                == configuration.providerID.uuidString.lowercased(),
              reference.siteIdentity == site.key,
              reference.providerKind == Self.providerKind,
              reference.providerVersion == Self.providerVersion,
              reference.stability == .providerStable,
              reference.expiresAt == nil,
              let locator = XtreamPlaybackLocator(
                encoded: reference.stableResourceLocator
              ),
              reference.sourceIdentity == locator.sourceIdentity,
              reference.episodeIdentity == locator.episodeIdentity else {
            return false
        }
        return PlaybackPersistencePolicy.sanitizedProviderResourceReference(
            reference
        ) == reference
    }

    private func vodCategories() async throws -> [XtreamCategoryDTO] {
        if let cached = await cache.vodCategories() {
            return cached
        }
        let categories = try await client.vodCategories()
        await cache.setVODCategories(categories)
        return categories
    }

    private func vodStreams(categoryID: String) async throws
        -> [XtreamVODStreamDTO] {
        if let cached = await cache.vodStreams(categoryID: categoryID) {
            return cached
        }
        let streams = try await client.vodStreams(categoryID: categoryID)
        await cache.setVODStreams(streams, categoryID: categoryID)
        return streams
    }

    private func allVODStreams() async throws -> (
        values: [XtreamVODStreamDTO],
        refreshed: Bool
    ) {
        if let cached = await cache.vodStreams(categoryID: nil) {
            return (cached, false)
        }
        let streams = try await client.vodStreams()
        await cache.setVODStreams(streams, categoryID: nil)
        return (streams, true)
    }

    private func seriesCategories() async throws -> [XtreamCategoryDTO] {
        if let cached = await cache.seriesCategories() {
            return cached
        }
        let categories = try await client.seriesCategories()
        await cache.setSeriesCategories(categories)
        return categories
    }

    private func series(categoryID: String) async throws -> [XtreamSeriesDTO] {
        if let cached = await cache.series(categoryID: categoryID) {
            return cached
        }
        let series = try await client.series(categoryID: categoryID)
        await cache.setSeries(series, categoryID: categoryID)
        return series
    }

    private func allSeries() async throws -> (
        values: [XtreamSeriesDTO],
        refreshed: Bool
    ) {
        if let cached = await cache.series(categoryID: nil) {
            return (cached, false)
        }
        let series = try await client.series()
        await cache.setSeries(series, categoryID: nil)
        return (series, true)
    }

    private func movieCategory(_ dto: XtreamCategoryDTO) -> VideoCategory? {
        guard let id = normalized(dto.categoryID),
              let name = normalized(dto.categoryName) else {
            return nil
        }
        return VideoCategory(
            id: XtreamProviderIdentifier.encode(id, prefix: .movieCategory),
            name: name
        )
    }

    private func seriesCategory(_ dto: XtreamCategoryDTO) -> VideoCategory? {
        guard let id = normalized(dto.categoryID),
              let name = normalized(dto.categoryName) else {
            return nil
        }
        return VideoCategory(
            id: XtreamProviderIdentifier.encode(id, prefix: .seriesCategory),
            name: name
        )
    }

    private func movieSummary(_ dto: XtreamVODStreamDTO) -> VideoSummary? {
        guard let id = normalized(dto.streamID),
              let title = normalized(dto.name) else {
            return nil
        }
        return VideoSummary(
            siteKey: site.key,
            siteName: site.name,
            videoID: XtreamProviderIdentifier.encode(id, prefix: .movie),
            title: title,
            posterURL: safeArtworkURL(dto.streamIcon),
            remarks: movieRemarks(rating: dto.rating),
            categoryName: nil
        )
    }

    private func seriesSummary(_ dto: XtreamSeriesDTO) -> VideoSummary? {
        guard let id = normalized(dto.seriesID),
              let title = normalized(dto.name) else {
            return nil
        }
        return VideoSummary(
            siteKey: site.key,
            siteName: site.name,
            videoID: XtreamProviderIdentifier.encode(id, prefix: .series),
            title: title,
            posterURL: safeArtworkURL(dto.cover),
            remarks: movieRemarks(rating: dto.rating),
            year: year(from: dto.releaseDate),
            categoryName: nil
        )
    }

    private func categoryName(
        for categoryID: String?,
        kind: XtreamProviderIdentifier.Prefix
    ) async -> String? {
        guard let categoryID = normalized(categoryID) else {
            return nil
        }
        let categories: [XtreamCategoryDTO]
        switch kind {
        case .movieCategory:
            guard let values = try? await vodCategories() else { return nil }
            categories = values
        case .seriesCategory:
            guard let values = try? await seriesCategories() else { return nil }
            categories = values
        case .movie, .series:
            return nil
        }
        return categories.first {
            normalized($0.categoryID) == categoryID
        }.flatMap { normalized($0.categoryName) }
    }

    private func paginated(_ items: [VideoSummary], page: Int) -> VideoPage {
        let pageCount = items.isEmpty
            ? 0
            : Int(ceil(Double(items.count) / Double(pageSize)))
        let start = min(items.count, (page - 1) * pageSize)
        let end = min(items.count, start + pageSize)
        return VideoPage(
            items: Array(items[start..<end]),
            pagination: Pagination(page: page, pageCount: pageCount)
        )
    }

    private func playbackReference(
        for locator: XtreamPlaybackLocator
    ) -> PlaybackResourceReference {
        PlaybackResourceReference(
            configurationIdentity: configuration.providerID.uuidString.lowercased(),
            siteIdentity: site.key,
            providerKind: Self.providerKind,
            providerVersion: Self.providerVersion,
            stableResourceLocator: locator.encoded,
            sourceIdentity: locator.sourceIdentity,
            episodeIdentity: locator.episodeIdentity,
            stability: .providerStable
        )
    }

    private func safeLiveArtworkURL(_ rawValue: String?) -> URL? {
        guard let url = safeArtworkURL(rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil,
              components.queryItems?.contains(where: {
                  let name = $0.name.lowercased()
                  return ["u", "p", "pwd"].contains(name)
                    || ["user", "pass", "credential"].contains(where: name.contains)
              }) != true else { return nil }
        var inspectedValue = url.absoluteString
        for _ in 0..<3 {
            guard !liveArtworkCredentialValues.contains(where: inspectedValue.contains) else {
                return nil
            }
            guard let decoded = inspectedValue.removingPercentEncoding,
                  decoded != inspectedValue else { break }
            inspectedValue = decoded
        }
        return url
    }

    private func safeArtworkURL(_ rawValue: String?) -> URL? {
        guard let value = normalized(rawValue),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              !hasCredentialBearingXtreamPath(components.path),
              components.queryItems?.contains(where: {
                let name = $0.name.lowercased()
                return [
                    "auth", "authorization", "cookie", "key", "password",
                    "secret", "sign", "signature", "token"
                ].contains(where: name.contains)
              }) != true else {
            return nil
        }
        return components.url
    }

    private func hasCredentialBearingXtreamPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map {
            $0.lowercased()
        }
        let routes: Set<String> = ["live", "movie", "series", "timeshift"]
        return components.indices.contains { index in
            routes.contains(components[index])
                && components.indices.contains(index + 3)
        }
    }

    private func movieRemarks(rating: Double?) -> String? {
        guard let rating, rating.isFinite, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    private func year(from value: String?) -> String? {
        guard let value = normalized(value), value.count >= 4 else { return nil }
        let prefix = String(value.prefix(4))
        return Int(prefix) == nil ? nil : prefix
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap(normalized).first
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

private enum XtreamProviderIdentifier {
    enum Prefix: String {
        case movieCategory = "xtr.vod.category"
        case movie = "xtr.movie"
        case seriesCategory = "xtr.series.category"
        case series = "xtr.series"
    }

    static func encode(_ value: String, prefix: Prefix) -> String {
        "\(prefix.rawValue).\(XtreamHex.encode(value))"
    }

    static func decode(_ value: String, prefix: Prefix) -> String? {
        let marker = "\(prefix.rawValue)."
        guard value.hasPrefix(marker) else { return nil }
        return XtreamHex.decode(String(value.dropFirst(marker.count)))
    }
}

private struct XtreamPlaybackLocator: Equatable, Sendable {
    enum Kind: String, Sendable {
        case movie = "m"
        case seriesEpisode = "e"
    }

    let kind: Kind
    let remoteID: String
    let seriesID: String?
    let seasonNumber: Int?
    let containerExtension: String?

    static func movie(
        remoteID: String,
        containerExtension: String?
    ) throws -> Self {
        guard XtreamHex.isValidSourceValue(remoteID) else {
            throw XtreamSiteProviderError.invalidPlaybackLocator
        }
        return Self(
            kind: .movie,
            remoteID: remoteID,
            seriesID: nil,
            seasonNumber: nil,
            containerExtension: normalizedExtension(containerExtension)
        )
    }

    static func seriesEpisode(
        seriesID: String,
        seasonNumber: Int,
        remoteID: String,
        containerExtension: String?
    ) throws -> Self {
        guard XtreamHex.isValidSourceValue(seriesID),
              XtreamHex.isValidSourceValue(remoteID),
              (0...10_000).contains(seasonNumber) else {
            throw XtreamSiteProviderError.invalidPlaybackLocator
        }
        return Self(
            kind: .seriesEpisode,
            remoteID: remoteID,
            seriesID: seriesID,
            seasonNumber: seasonNumber,
            containerExtension: normalizedExtension(containerExtension)
        )
    }

    init?(encoded: String) {
        let values = encoded.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard values.count >= 4,
              values[0] == "xtr1",
              let kind = Kind(rawValue: values[1]) else {
            return nil
        }
        switch kind {
        case .movie:
            guard values.count == 4,
                  let remoteID = XtreamHex.decode(values[2]),
                  XtreamHex.isValidSourceValue(remoteID),
                  let extensionValue = Self.decodeExtension(values[3]) else {
                return nil
            }
            self.kind = kind
            self.remoteID = remoteID
            seriesID = nil
            seasonNumber = nil
            containerExtension = extensionValue
        case .seriesEpisode:
            guard values.count == 6,
                  let seriesID = XtreamHex.decode(values[2]),
                  XtreamHex.isValidSourceValue(seriesID),
                  let seasonNumber = Int(values[3]),
                  (0...10_000).contains(seasonNumber),
                  let remoteID = XtreamHex.decode(values[4]),
                  XtreamHex.isValidSourceValue(remoteID),
                  let extensionValue = Self.decodeExtension(values[5]) else {
                return nil
            }
            self.kind = kind
            self.remoteID = remoteID
            self.seriesID = seriesID
            self.seasonNumber = seasonNumber
            containerExtension = extensionValue
        }
    }

    private init(
        kind: Kind,
        remoteID: String,
        seriesID: String?,
        seasonNumber: Int?,
        containerExtension: String?
    ) {
        self.kind = kind
        self.remoteID = remoteID
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.containerExtension = containerExtension
    }

    var encoded: String {
        let extensionComponent = containerExtension.map(XtreamHex.encode) ?? "~"
        switch kind {
        case .movie:
            return "xtr1.m.\(XtreamHex.encode(remoteID)).\(extensionComponent)"
        case .seriesEpisode:
            return "xtr1.e.\(XtreamHex.encode(seriesID ?? "")).\(seasonNumber ?? 0).\(XtreamHex.encode(remoteID)).\(extensionComponent)"
        }
    }

    var sourceIdentity: String {
        switch kind {
        case .movie:
            return "xtr1.movie.\(XtreamHex.encode(remoteID))"
        case .seriesEpisode:
            return Self.seriesSourceIdentity(
                seriesID: seriesID ?? "",
                seasonNumber: seasonNumber ?? 0
            )
        }
    }

    var episodeIdentity: String {
        switch kind {
        case .movie:
            return sourceIdentity
        case .seriesEpisode:
            return "xtr1.episode.\(XtreamHex.encode(remoteID))"
        }
    }

    static func seriesSourceIdentity(
        seriesID: String,
        seasonNumber: Int
    ) -> String {
        "xtr1.series.\(XtreamHex.encode(seriesID)).season.\(seasonNumber)"
    }

    /// Double optional distinguishes a valid no-extension marker from a
    /// malformed component.
    private static func decodeExtension(_ value: String) -> String?? {
        if value == "~" { return .some(nil) }
        guard let decoded = XtreamHex.decode(value),
              normalizedExtension(decoded) == decoded else {
            return nil
        }
        return .some(decoded)
    }

    private static func normalizedExtension(_ value: String?) -> String? {
        let candidate = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased() ?? ""
        guard !candidate.isEmpty,
              candidate.utf8.count <= 16,
              candidate.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
              }) else {
            return nil
        }
        return candidate
    }
}

private enum XtreamHex {
    static func encode(_ value: String) -> String {
        Data(value.utf8).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ value: String) -> String? {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = end
        }
        return String(data: data, encoding: .utf8)
    }

    static func isValidSourceValue(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        return byteCount > 0
            && byteCount <= 512
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

private actor XtreamCatalogCache {
    private struct Timed<Value: Sendable>: Sendable {
        let value: Value
        let storedAt: Date
    }

    private let ttl: TimeInterval
    private var movieCategories: Timed<[XtreamCategoryDTO]>?
    private var movieStreamsByCategory: [String: Timed<[XtreamVODStreamDTO]>] = [:]
    private var showCategories: Timed<[XtreamCategoryDTO]>?
    private var showsByCategory: [String: Timed<[XtreamSeriesDTO]>] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func vodCategories(now: Date = Date()) -> [XtreamCategoryDTO]? {
        fresh(movieCategories, now: now)
    }

    func setVODCategories(_ value: [XtreamCategoryDTO], now: Date = Date()) {
        movieCategories = Timed(value: value, storedAt: now)
    }

    func vodStreams(
        categoryID: String?,
        now: Date = Date()
    ) -> [XtreamVODStreamDTO]? {
        let key = cacheKey(categoryID)
        if let exact = fresh(movieStreamsByCategory[key], now: now) {
            return exact
        }
        guard let categoryID,
              let complete = fresh(
                movieStreamsByCategory[cacheKey(nil)],
                now: now
              ) else {
            return nil
        }
        return complete.filter { $0.categoryID == categoryID }
    }

    func setVODStreams(
        _ value: [XtreamVODStreamDTO],
        categoryID: String?,
        now: Date = Date()
    ) {
        if categoryID == nil {
            movieStreamsByCategory.removeAll(keepingCapacity: true)
        }
        movieStreamsByCategory[cacheKey(categoryID)] = Timed(
            value: value,
            storedAt: now
        )
    }

    func movie(streamID: String, now: Date = Date()) -> XtreamVODStreamDTO? {
        for entry in movieStreamsByCategory.values {
            guard let streams = fresh(entry, now: now) else { continue }
            if let movie = streams.first(where: { $0.streamID == streamID }) {
                return movie
            }
        }
        return nil
    }

    func seriesCategories(now: Date = Date()) -> [XtreamCategoryDTO]? {
        fresh(showCategories, now: now)
    }

    func setSeriesCategories(_ value: [XtreamCategoryDTO], now: Date = Date()) {
        showCategories = Timed(value: value, storedAt: now)
    }

    func series(
        categoryID: String?,
        now: Date = Date()
    ) -> [XtreamSeriesDTO]? {
        let key = cacheKey(categoryID)
        if let exact = fresh(showsByCategory[key], now: now) {
            return exact
        }
        guard let categoryID,
              let complete = fresh(
                showsByCategory[cacheKey(nil)],
                now: now
              ) else {
            return nil
        }
        return complete.filter { $0.categoryID == categoryID }
    }

    func setSeries(
        _ value: [XtreamSeriesDTO],
        categoryID: String?,
        now: Date = Date()
    ) {
        if categoryID == nil {
            showsByCategory.removeAll(keepingCapacity: true)
        }
        showsByCategory[cacheKey(categoryID)] = Timed(
            value: value,
            storedAt: now
        )
    }

    func series(seriesID: String, now: Date = Date()) -> XtreamSeriesDTO? {
        for entry in showsByCategory.values {
            guard let series = fresh(entry, now: now) else { continue }
            if let value = series.first(where: { $0.seriesID == seriesID }) {
                return value
            }
        }
        return nil
    }

    private func fresh<Value: Sendable>(
        _ entry: Timed<Value>?,
        now: Date
    ) -> Value? {
        guard let entry, now.timeIntervalSince(entry.storedAt) <= ttl else {
            return nil
        }
        return entry.value
    }

    private func cacheKey(_ categoryID: String?) -> String {
        categoryID.map { "category.\(XtreamHex.encode($0))" } ?? "all"
    }
}

private actor XtreamSearchIndex {
    private struct Entry: Sendable {
        let normalizedTitle: String
        let summary: VideoSummary
    }

    private var entries: [Entry] = []
    private var isInitialized = false

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: nil
            )
            .lowercased()
    }

    func results(
        movies: [VideoSummary],
        series: [VideoSummary],
        keyword: String,
        rebuild: Bool
    ) -> [VideoSummary] {
        if rebuild || !isInitialized {
            var seen: Set<String> = []
            entries = (movies + series).compactMap { summary in
                guard seen.insert(summary.id).inserted else { return nil }
                let normalizedTitle = Self.normalized(summary.title)
                guard !normalizedTitle.isEmpty else { return nil }
                return Entry(
                    normalizedTitle: normalizedTitle,
                    summary: summary
                )
            }
            isInitialized = true
        }
        return entries.filter {
            $0.normalizedTitle.contains(keyword)
        }.sorted { lhs, rhs in
            let leftRank = matchRank(lhs.normalizedTitle, keyword: keyword)
            let rightRank = matchRank(rhs.normalizedTitle, keyword: keyword)
            if leftRank != rightRank { return leftRank < rightRank }
            let titleOrder = lhs.summary.title.localizedStandardCompare(
                rhs.summary.title
            )
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.summary.id < rhs.summary.id
        }.map(\.summary)
    }

    private func matchRank(_ title: String, keyword: String) -> Int {
        if title == keyword { return 0 }
        if title.hasPrefix(keyword) { return 1 }
        return 2
    }
}
