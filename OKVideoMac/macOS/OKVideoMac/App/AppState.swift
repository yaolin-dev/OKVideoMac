import AppKit
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

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case configurations
    case liveSources
    case playback
    case cache
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

struct CloudAuthorizationAction: Identifiable, Equatable {
    let id: String
    let title: String
}

struct CloudAuthorizationPrompt: Identifiable, Equatable {
    let id: UUID
    var title: String
    var status: String?
    var phase: String?
    var provider: String?
    var hasTextInput: Bool
    var credentialPush: Bool
    var actions: [CloudAuthorizationAction]
    var snapshot: Data?
}

struct NodeWebPresentation: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
    let message: String
    var revision: Int
}

struct SearchSiteOption: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let resultCount: Int
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

private struct ActivePlaybackContext {
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var media: ResolvedMedia
    var playbackResult: SitePlaybackResult?
}

private struct PlaybackHistoryWrite {
    let record: HistoryRecord
    let incognito: Bool
}

private struct PendingCloudPlayback {
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
}

private enum PendingNodeOperation {
    case category(
        siteKey: String,
        id: String,
        page: Int,
        filters: [String: String]
    )
    case detail(VideoSummary)
    case playback(PendingCloudPlayback)
}

@MainActor
final class AppState: ObservableObject {
    static let automaticConfigurationRefreshInterval: TimeInterval = 30 * 60

    @Published var selectedSection: AppSection = .home
    @Published private(set) var isHomeSearchPresented = false
    @Published var selectedSettingsPane: SettingsPane = .general
    @Published private(set) var configurations: [StoredConfiguration] = []
    @Published private(set) var activeConfigurationRecord: StoredConfiguration?
    @Published private(set) var activeConfiguration: FongMiConfiguration?
    @Published private(set) var selectedSiteKey: String?
    @Published private(set) var siteHome: SiteHome?
    @Published private(set) var isHomeLoading = false
    @Published private(set) var homeLoadErrorMessage: String?
    @Published private(set) var hasCompletedStartup = false
    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var categoryPage: VideoPage?
    @Published var searchKeyword = ""
    @Published private(set) var searchResults: [VideoSummary] = []
    @Published private(set) var searchClusters: [SearchResultCluster] = []
    @Published private(set) var searchFailures: [SearchFailure] = []
    @Published private(set) var searchCompletedSiteCount = 0
    @Published private(set) var searchTotalSiteCount = 0
    @Published private(set) var isSearching = false
    @Published private(set) var selectedSearchSiteKey: String?
    @Published private(set) var searchFolderPath: [SearchFolderPage] = []
    @Published private(set) var favorites: [FavoriteRecord] = []
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var liveSources: [StoredLiveSource] = []
    @Published private(set) var loadedLivePlaylists: [UUID: LivePlaylist] = [:]
    @Published private(set) var loadedEPGGuides: [UUID: XMLTVGuide] = [:]
    @Published private(set) var epgFailures: [UUID: String] = [:]
    @Published private(set) var livePlaybackChannel: LiveChannel?
    @Published private(set) var livePlaybackStream: LiveStream?
    @Published private(set) var livePlaybackSourceID: UUID?
    @Published private(set) var selectedDetail: VideoDetail?
    @Published private(set) var pendingDetailSummary: VideoSummary?
    @Published private(set) var incognitoMode = false
    @Published private(set) var historyRetentionDays = 60
    @Published private(set) var appTheme: AppTheme = .system
    @Published private(set) var favoriteLiveChannelIDs: Set<String> = []
    @Published private(set) var playerSnapshot = PlayerSnapshot()
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
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextCategoryPage = false
    @Published private(set) var categoryPaginationError: String?
    @Published var presentedError: UserFacingError?
    @Published var cloudAuthorizationPrompt: CloudAuthorizationPrompt?
    @Published var cloudAuthorizationInput = ""
    @Published private(set) var nodeWebPresentation: NodeWebPresentation?
    @Published private(set) var androidRuntimeStatus: AndroidRuntimeStatus = .checking
    @Published private(set) var isAndroidRuntimeBusy = false

    private let environment: AppEnvironment?
    private var providers: [String: SiteProvider] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchSessionID = UUID()
    private var detailLoadSessionID = UUID()
    private var homeLoadSessionID = UUID()
    private var categoryLoadSessionID = UUID()
    private var playerEventTask: Task<Void, Never>?
    private var cloudAuthorizationPollTask: Task<Void, Never>?
    private var cloudAuthorizationSessionID = UUID()
    private var activePlayback: ActivePlaybackContext?
    private var pendingPlayback: PendingCloudPlayback?
    private var pendingCloudPlayback: PendingCloudPlayback?
    private var pendingNodeOperation: PendingNodeOperation?
    private var playbackSessionID = UUID()
    private var playbackQualitySwitchSessionID = UUID()
    private var lastHistorySaveAt = Date.distantPast
    private var pendingHistoryWrite: PlaybackHistoryWrite?
    private var historyPersistenceTask: Task<Void, Never>?
    private var shouldResumeAfterWake = false
    private var isClosingPlayer = false
    private var prefersPlayerSubtitlesEnabled = false
    private var preferredPlayerSubtitleTrack: PlayerSubtitleTrackPreference?
    private var playerStartedInFullScreen = false
    private var lastAutomaticConfigurationRefreshAttemptAt: Date?
    private var configurationRefreshTask: Task<Bool, Never>?
    private var configurationRefreshSessionID = UUID()

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
        presentedError = startupError
    }

    func start() async {
        guard !hasCompletedStartup, let environment else { return }
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
                loadInBackground: false
            )
            try await reloadUserData()
            startPlayerEventLoop()

            if activeConfigurationUsesNodeRuntime {
                do {
                    try await prepareActiveNodeConfigurationIfNeeded()
                    try loadActiveConfigurationContent()
                } catch {
                    // The cached configuration and home snapshot are already
                    // visible. A failed refresh must not invalidate them.
                }
            }
            await prepareActiveConfigurationHome(reportLoadErrors: false)
        } catch {
            isHomeLoading = false
            show(error, title: "启动失败")
        }
    }

    @discardableResult
    func importConfiguration(
        source: ConfigurationSource,
        name: String?
    ) async -> Bool {
        guard let environment else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await loadConfiguration(source)
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
                name: name?.nonEmpty ?? source.displayName,
                sourceKind: sourceDetails.0,
                sourceValue: sourceDetails.1,
                baseURL: loaded.baseURL,
                rawData: loaded.rawData,
                updatedAt: loaded.loadedAt,
                isActive: true
            )
            try await environment.database.saveConfiguration(record)
            configurations = try await environment.database.configurations()
            configurationRefreshSessionID = UUID()
            configurationRefreshTask?.cancel()
            configurationRefreshTask = nil
            lastAutomaticConfigurationRefreshAttemptAt = loaded.loadedAt
            activeConfigurationRecord = record
            activeConfiguration = loaded.configuration
            rebuildProviders()
            selectedSiteKey = supportedSites.first?.key
            await prepareActiveConfigurationHome()
            try await reloadHistory()
            return true
        } catch {
            show(error, title: "配置导入失败")
            return false
        }
    }

    func refreshActiveConfiguration() async {
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

    static func shouldAutomaticallyRefreshConfiguration(
        sourceKind: StoredConfigurationSourceKind,
        lastAttemptAt: Date?,
        now: Date,
        interval: TimeInterval = automaticConfigurationRefreshInterval
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
                self.siteHome = nil
                self.selectedCategoryID = nil
                self.categoryPage = nil
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

    func activateConfiguration(_ id: UUID) async {
        guard let environment else { return }
        do {
            try await environment.database.activateConfiguration(id: id)
            configurations = try await environment.database.configurations()
            activeConfigurationRecord = try await environment.database.activeConfiguration()
            selectedSiteKey = nil
            try await prepareActiveNodeConfigurationIfNeeded()
            try loadActiveConfigurationContent()
            await prepareActiveConfigurationHome()
            try await reloadHistory()
        } catch {
            show(error, title: "切换配置失败")
        }
    }

    func deleteConfiguration(_ id: UUID) async {
        guard let environment else { return }
        do {
            try await environment.database.deleteConfiguration(id: id)
            configurations = try await environment.database.configurations()
            if activeConfigurationRecord?.id == id {
                activeConfigurationRecord = try await environment.database.activeConfiguration()
                selectedSiteKey = nil
                try await prepareActiveNodeConfigurationIfNeeded()
                try loadActiveConfigurationContent()
                await prepareActiveConfigurationHome()
                try await reloadHistory()
            }
        } catch {
            show(error, title: "删除配置失败")
        }
    }

    func selectSite(_ key: String) async {
        homeLoadSessionID = UUID()
        categoryLoadSessionID = UUID()
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        isHomeLoading = true
        homeLoadErrorMessage = nil
        selectedSiteKey = key
        siteHome = nil
        selectedCategoryID = nil
        categoryPage = nil
        await persistSelectedSitePreference(key)
        await restoreCachedSiteHome()
        await loadSelectedSiteHome()
    }

    func loadCategory(
        id: String,
        page: Int = 1,
        filters: [String: String] = [:]
    ) async {
        guard let key = selectedSiteKey, let provider = providers[key] else { return }
        let sessionID: UUID
        let loadingNextPage = page > 1
        if loadingNextPage {
            guard !isLoadingNextCategoryPage,
                  selectedCategoryID == id,
                  categoryPage?.pagination.page == page - 1,
                  categoryPage?.pagination.hasMore == true else {
                return
            }
            sessionID = categoryLoadSessionID
            isLoadingNextCategoryPage = true
            categoryPaginationError = nil
        } else {
            categoryLoadSessionID = UUID()
            sessionID = categoryLoadSessionID
            selectedCategoryID = id
            categoryPage = nil
            isLoadingNextCategoryPage = false
            categoryPaginationError = nil
            isLoading = true
        }
        defer {
            if loadingNextPage {
                isLoadingNextCategoryPage = false
            } else {
                isLoading = false
            }
        }
        do {
            let loaded = try await provider.category(id: id, page: page, filters: filters)
            guard categoryLoadSessionID == sessionID else { return }
            selectedCategoryID = id
            categoryPage = VideoPageMerger.merge(
                current: page > 1 ? categoryPage : nil,
                loaded: loaded,
                requestedPage: page
            )
            categoryPaginationError = nil
        } catch let authorization as NodeWebAuthorizationRequired {
            guard categoryLoadSessionID == sessionID else { return }
            presentNodeConfiguration(
                authorization,
                pending: .category(
                    siteKey: key,
                    id: id,
                    page: page,
                    filters: filters
                )
            )
        } catch {
            guard categoryLoadSessionID == sessionID else { return }
            if loadingNextPage {
                categoryPaginationError = error.localizedDescription
            } else {
                show(error, title: "分类加载失败")
            }
        }
    }

    func clearCategory() {
        categoryLoadSessionID = UUID()
        isLoadingNextCategoryPage = false
        categoryPaginationError = nil
        selectedCategoryID = nil
        categoryPage = nil
    }

    func loadSelectedSiteHome(
        refreshConfigurationIfNeeded: Bool = true,
        reportErrors: Bool = true
    ) async {
        if refreshConfigurationIfNeeded {
            _ = await refreshActiveConfigurationIfNeeded()
        }
        guard let key = selectedSiteKey,
              let provider = providers[key],
              provider.capability != .unsupportedSpider else {
            isHomeLoading = false
            return
        }
        homeLoadSessionID = UUID()
        let sessionID = homeLoadSessionID
        isHomeLoading = true
        defer { isHomeLoading = false }
        do {
            let loaded = try await provider.home()
            guard homeLoadSessionID == sessionID,
                  selectedSiteKey == key else {
                return
            }
            siteHome = loaded
            homeLoadErrorMessage = nil
            await cacheSiteHome(loaded, siteKey: key)
        } catch {
            guard homeLoadSessionID == sessionID else { return }
            homeLoadErrorMessage = error.localizedDescription
            if reportErrors {
                show(error, title: "站点加载失败")
            }
        }
    }

    func refreshHome() async {
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
        guard selectedSection == .home, !isHomeSearchPresented else { return }
        let changed = await refreshActiveConfigurationIfNeeded()
        guard changed,
              selectedSection == .home,
              !isHomeSearchPresented else {
            return
        }
        await loadSelectedSiteHome(refreshConfigurationIfNeeded: false)
    }

    func loadDetail(_ summary: VideoSummary) async {
        if summary.isFolder {
            openSearchFolder(summary, replacingPath: true)
            return
        }
        if summary.videoID.hasPrefix("msearch:") {
            selectedDetail = nil
            pendingDetailSummary = nil
            presentHomeSearch()
            search(summary.title)
            return
        }
        guard let provider = providers[summary.siteKey] else {
            show(
                AppError.site("来源 \(summary.siteKey) 在当前配置中不可用，记录仍会保留"),
                title: "来源不可用"
            )
            return
        }
        if let action = summary.action?.nonEmpty {
            await performSiteAction(
                action,
                title: summary.title,
                provider: provider
            )
            return
        }
        let sessionID = UUID()
        detailLoadSessionID = sessionID
        selectedDetail = nil
        pendingDetailSummary = summary
        isLoading = true
        defer { isLoading = false }
        do {
            let selection = try await provider.select(id: summary.videoID)
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            switch selection {
            case .detail(let detail):
                selectedDetail = detail
            case .action(let result):
                if let authorization = await waitForCloudAuthorization() {
                    await presentCloudAuthorization(authorization, pending: nil)
                } else {
                    presentedError = UserFacingError(
                        title: summary.title,
                        message: Self.siteActionMessage(result)
                            ?? Self.unconfirmedSiteActionMessage
                    )
                }
            }
        } catch let authorization as NodeWebAuthorizationRequired {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            presentNodeConfiguration(
                authorization,
                pending: .detail(summary)
            )
        } catch let authorization as AndroidBridgeUIRequired {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            await presentCloudAuthorization(authorization.state, pending: nil)
        } catch {
            guard detailLoadSessionID == sessionID else { return }
            pendingDetailSummary = nil
            show(error, title: "详情加载失败")
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
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await provider.action(action)
            if provider.capability == .javaDexSpider,
               let state = await waitForCloudAuthorization() {
                await presentCloudAuthorization(state, pending: nil)
                return
            }
            let message = Self.siteActionMessage(result)
                ?? (provider.capability == .javaDexSpider
                    ? Self.unconfirmedSiteActionMessage
                    : "操作已完成。")
            presentedError = UserFacingError(title: title, message: message)
        } catch let authorization as NodeWebAuthorizationRequired {
            presentNodeConfiguration(authorization, pending: nil)
        } catch let authorization as AndroidBridgeUIRequired {
            await presentCloudAuthorization(authorization.state, pending: nil)
        } catch {
            show(error, title: "\(title)失败")
        }
    }

    private func presentNodeConfiguration(
        _ authorization: NodeWebAuthorizationRequired,
        pending: PendingNodeOperation?
    ) {
        pendingNodeOperation = pending
        nodeWebPresentation = NodeWebPresentation(
            id: UUID(),
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
            let message = "已取消网盘授权"
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
        }
        pendingNodeOperation = nil
        nodeWebPresentation = nil
    }

    func completeNodeConfigurationAndRetry() async {
        let pending = pendingNodeOperation
        pendingNodeOperation = nil
        nodeWebPresentation = nil
        switch pending {
        case .category(let siteKey, let id, let page, let filters):
            guard selectedSiteKey == siteKey else { return }
            await loadCategory(id: id, page: page, filters: filters)
        case .detail(let summary):
            await loadDetail(summary)
        case .playback(let playback):
            await startPlayback(
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode
            )
        case nil:
            break
        }
    }

    private func waitForCloudAuthorization() async -> AndroidBridgeUIState? {
        guard let environment else { return nil }
        // Some configuration spiders create their Android login dialog after
        // returning the placeholder detail response. Keep observing long
        // enough to catch that asynchronous hand-off before reporting that no
        // setup UI appeared.
        for attempt in 0..<24 {
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return nil
                }
            }
            if let state = try? await environment.androidDexBridge.uiState(),
               state.isAuthorizationPrompt {
                return state
            }
        }
        return nil
    }

    func submitCloudAuthorization(action: CloudAuthorizationAction) async {
        guard let environment else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let text = cloudAuthorizationInput.nonEmpty
            guard try await environment.androidDexBridge.submitUI(
                text: text,
                button: action.title,
                controlID: action.id.hasPrefix("legacy:")
                    ? nil
                    : action.id
            ) else {
                throw AppError.spider(
                    "后台授权窗口中没有找到“\(action.title)”按钮"
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            if let state = try? await environment.androidDexBridge.uiState(),
               state.isAuthorizationPrompt {
                await updateCloudAuthorizationPrompt(state)
            }
            startCloudAuthorizationPolling()
        } catch {
            show(error, title: "网盘授权失败")
        }
    }

    func submitCloudCredential() async {
        guard let environment,
              let prompt = cloudAuthorizationPrompt,
              prompt.credentialPush,
              let provider = prompt.provider?.nonEmpty else {
            return
        }
        let credential = cloudAuthorizationInput
        guard credential.nonEmpty != nil else {
            show(AppError.spider("请先粘贴 Cookie 或 Token"), title: "网盘授权失败")
            return
        }

        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await environment.androidDexBridge.pushCredential(
                provider: provider,
                credential: credential
            )
            try await Task.sleep(nanoseconds: 400_000_000)
            await finishCloudAuthorizationAndRetry()
        } catch {
            show(error, title: "网盘授权失败")
            startCloudAuthorizationPolling()
        }
    }

    func cancelCloudAuthorization() {
        let androidDexBridge = environment?.androidDexBridge
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        cloudAuthorizationPrompt = nil
        cloudAuthorizationInput = ""
        if pendingCloudPlayback != nil {
            let message = "已取消网盘授权"
            playbackResolutionState = .failed
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
        }
        pendingCloudPlayback = nil
        Task {
            // The Android dialog is a real native window. Merely hiding the
            // SwiftUI layer leaves it stacked behind the app and causes the
            // next detail/play call to receive the wrong provider prompt.
            try? await androidDexBridge?.resetAuthorizationUI()
        }
    }

    func refreshCloudAuthorization() async {
        guard let environment else { return }
        do {
            let state = try await environment.androidDexBridge.uiState()
            guard state.isAuthorizationPrompt else {
                startCloudAuthorizationPolling()
                return
            }
            await updateCloudAuthorizationPrompt(state)
            startCloudAuthorizationPolling()
        } catch {
            show(error, title: "无法刷新网盘授权")
        }
    }

    private func presentCloudAuthorization(
        _ state: AndroidBridgeUIState,
        pending: PendingCloudPlayback?
    ) async {
        if let pending {
            pendingCloudPlayback = pending
        }
        await updateCloudAuthorizationPrompt(state)
        startCloudAuthorizationPolling()
    }

    private func updateCloudAuthorizationPrompt(
        _ state: AndroidBridgeUIState
    ) async {
        let previous = cloudAuthorizationPrompt
        let credentialPush = state.isCredentialPush
        // Some providers rotate an expired QR code without replacing the
        // Android dialog. Read the small local image on every QR poll and only
        // publish when its bytes actually change.
        let snapshot = state.isQRCode && !credentialPush
            ? (try? await environment?.androidDexBridge.uiSnapshot())
                ?? previous?.snapshot
            : nil
        let upstreamStatus = state.texts?
            .first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0 != state.title
                    && !$0.localizedCaseInsensitiveContains(
                        "/proxy?do=input"
                    )
            })
        let status = state.isRemoteInputQRCode
            ? "当前辅助输入码不适用于 Mac。请直接粘贴 Cookie，或点击“扫描二维码”生成网盘 App 登录码。"
            : credentialPush
            ? "该上游页面不是网盘 APP 登录码。请在下方粘贴 Cookie 或 Token，内容只发送到本机 Android 桥。"
            : upstreamStatus
        let updated = CloudAuthorizationPrompt(
            id: previous?.id ?? UUID(),
            title: state.title.nonEmpty ?? "网盘授权",
            status: status,
            phase: state.phase,
            provider: state.provider,
            hasTextInput: state.inputCount > 0 || credentialPush,
            credentialPush: credentialPush,
            actions: state.actionableControls.map {
                CloudAuthorizationAction(id: $0.id, title: $0.title)
            },
            snapshot: snapshot
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
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard let self,
                      self.cloudAuthorizationSessionID == sessionID,
                      self.cloudAuthorizationPrompt != nil,
                      let environment = self.environment else {
                    return
                }
                do {
                    let state = try await environment.androidDexBridge.uiState()
                    guard self.cloudAuthorizationSessionID == sessionID else {
                        return
                    }
                    if state.isAuthorizationPrompt {
                        hiddenPollCount = 0
                        if state.authenticated == true,
                           self.pendingCloudPlayback != nil {
                            await self.finishCloudAuthorizationAndRetry()
                            return
                        }
                        await self.updateCloudAuthorizationPrompt(state)
                    } else {
                        hiddenPollCount += 1
                        // QR dialogs are created and replaced asynchronously.
                        // Requiring three seconds of absence avoids treating a
                        // normal dialog transition as a completed login.
                        if hiddenPollCount >= 6 {
                            await self.finishCloudAuthorizationAndRetry()
                            return
                        }
                    }
                } catch {
                    // The emulator can briefly refuse requests while an Android
                    // dialog is being replaced. Keep the visible prompt and retry.
                    continue
                }
            }
        }
    }

    private func finishCloudAuthorizationAndRetry() async {
        cloudAuthorizationSessionID = UUID()
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        cloudAuthorizationPrompt = nil
        cloudAuthorizationInput = ""
        let pending = pendingCloudPlayback
        pendingCloudPlayback = nil
        if let pending {
            await startPlayback(
                detail: pending.detail,
                source: pending.source,
                episode: pending.episode
            )
        }
    }

    static let unconfirmedSiteActionMessage =
        "未检测到网盘设置或授权界面，当前操作尚未完成。请稍后重试。"

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

    func openHistory(_ item: HistoryRecord) async {
        guard item.configurationID == activeConfigurationRecord?.id else {
            show(
                AppError.site("该历史记录不属于当前点播配置，请切换回原配置后播放"),
                title: "历史播放失败"
            )
            return
        }
        let siteName = visibleSites.first { $0.key == item.siteKey }?.name
            ?? item.siteKey
        let preparationID = presentHistoryPlaybackShell(
            item,
            siteName: siteName
        )
        guard let provider = providers[item.siteKey] else {
            if await replayCachedHistory(
                item,
                siteName: siteName,
                owningSessionID: preparationID
            ) {
                return
            }
            guard isCurrentHistoryPreparation(preparationID) else { return }
            playerSnapshot.status = .failed("来源暂时不可用")
            playbackResolutionState = .failed
            playbackFailureSummary = "来源 \(siteName) 在当前配置中不可用，无法恢复播放"
            show(
                AppError.site("来源 \(siteName) 在当前配置中不可用，无法恢复播放"),
                title: "历史播放失败"
            )
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await provider.detail(id: item.videoID)
            guard isCurrentHistoryPreparation(preparationID) else { return }
            isLoading = false

            guard let selection = Self.historyPlaybackSelection(
                in: detail,
                record: item
            ) else {
                selectedDetail = detail
                show(
                    AppError.playback("历史中的线路或分集已被站点移除，请重新选择分集"),
                    title: "无法恢复原分集"
                )
                return
            }

            await startPlayback(
                detail: detail,
                source: selection.source,
                episode: selection.episode
            )
            return
        } catch {
            // Search/cloud providers often expose session-scoped video IDs.
            // Continue with the durable episode reference or cached media
            // instead of surfacing a low-level empty-JSON error.
        }

        if let episodeReference = item.episodeReference?.nonEmpty {
            guard isCurrentHistoryPreparation(preparationID) else { return }
            isLoading = false
            let context = Self.historyPlaybackContext(
                record: item,
                siteName: siteName,
                episodeURL: episodeReference
            )
            await startPlayback(
                detail: context.detail,
                source: context.source,
                episode: context.episode
            )
            return
        }

        if await replayCachedHistory(
            item,
            siteName: siteName,
            owningSessionID: preparationID
        ) {
            isLoading = false
            return
        }
        guard isCurrentHistoryPreparation(preparationID) else { return }

        do {
            let page = try await provider.search(
                keyword: item.title,
                page: 1,
                quick: false
            )
            if let summary = Self.historySearchMatch(
                in: page.items,
                record: item
            ) {
                let detail = try await provider.detail(id: summary.videoID)
                guard isCurrentHistoryPreparation(preparationID) else { return }
                if let selection = Self.historyPlaybackSelection(
                    in: detail,
                    record: item
                ) {
                    isLoading = false
                    await startPlayback(
                        detail: detail,
                        source: selection.source,
                        episode: selection.episode
                    )
                    return
                }
            }
        } catch {
            // A search retry is best effort. Present one actionable history
            // message below instead of a second provider decoding error.
        }

        guard isCurrentHistoryPreparation(preparationID) else { return }
        isLoading = false
        playerSnapshot.status = .failed("历史记录恢复失败")
        playbackResolutionState = .failed
        playbackFailureSummary = "该来源暂时无法重新获取详情"
        show(
            AppError.playback(
                "该来源暂时无法重新获取详情，旧记录中的临时播放地址也已失效。"
                    + "请从搜索结果重新打开一次；新产生的历史记录会保存可刷新的分集信息。"
            ),
            title: "历史播放失败"
        )
    }

    private func replayCachedHistory(
        _ item: HistoryRecord,
        siteName: String,
        owningSessionID: UUID? = nil
    ) async -> Bool {
        guard let environment,
              let replay = Self.replayableHistoryPlayback(
                record: item,
                siteName: siteName
              ) else {
            return false
        }
        if ["127.0.0.1", "localhost", "::1"].contains(
            replay.media.url.host?.lowercased() ?? ""
        ) {
            _ = try? await environment.androidDexBridge.uiState()
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
        if let owningSessionID,
           !isCurrentHistoryPreparation(owningSessionID) {
            return false
        }
        do {
            try await loadResolvedPlayback(
                replay.media,
                detail: replay.detail,
                source: replay.source,
                episode: replay.episode
            )
            playbackResolutionState = .playing
            playbackFailureSummary = nil
            return true
        } catch {
            return false
        }
    }

    private func presentHistoryPlaybackShell(
        _ item: HistoryRecord,
        siteName: String
    ) -> UUID {
        let preparationID = UUID()
        playbackSessionID = preparationID
        playbackQualitySwitchSessionID = UUID()
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        activePlayback = nil
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        selectedDetail = nil
        pendingDetailSummary = nil

        let context = Self.historyPlaybackContext(
            record: item,
            siteName: siteName,
            episodeURL: "history-pending://\(preparationID.uuidString.lowercased())"
        )
        pendingPlayback = PendingCloudPlayback(
            detail: context.detail,
            source: context.source,
            episode: context.episode
        )
        playbackResolutionState = .restoringHistory
        currentPlaybackAttempt = nil
        playbackFailureSummary = nil
        playerSnapshot = PlayerSnapshot(
            status: .loading,
            volume: playerSnapshot.volume,
            isMuted: playerSnapshot.isMuted,
            speed: playerSnapshot.speed
        )
        presentPlayer()
        return preparationID
    }

    private func isCurrentHistoryPreparation(_ preparationID: UUID) -> Bool {
        isPlayerPresented && playbackSessionID == preparationID
    }

    func dismissDetail() {
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
    }

    func search(_ keyword: String) {
        searchTask?.cancel()
        let sessionID = UUID()
        searchSessionID = sessionID
        searchResults = []
        searchClusters = []
        searchFailures = []
        searchCompletedSiteCount = 0
        searchTotalSiteCount = 0
        isSearching = false
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

        let searchableProviders = supportedSites.compactMap {
            providers[$0.key]
        }.filter { $0.site.searchable == 1 }
        searchTotalSiteCount = searchableProviders.count
        isSearching = !searchableProviders.isEmpty
        let stream = MultiSiteSearch().search(
            providers: searchableProviders,
            keyword: trimmed
        )
        searchTask = Task { [weak self] in
            for await event in stream {
                guard let self,
                      self.searchSessionID == sessionID else {
                    return
                }
                switch event {
                case .results(_, let items):
                    self.searchCompletedSiteCount += 1
                    let existing = Set(self.searchResults.map(\.id))
                    self.searchResults.append(contentsOf: items.filter { !existing.contains($0.id) })
                    self.searchClusters = SearchResultAggregator.cluster(self.searchResults)
                case .failure(let failure):
                    self.searchCompletedSiteCount += 1
                    self.searchFailures.append(failure)
                case .completed:
                    self.isSearching = false
                }
            }
            if self?.searchSessionID == sessionID {
                self?.isSearching = false
            }
        }
    }

    func presentHomeSearch() {
        selectedSection = .home
        isHomeSearchPresented = true
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
        if section == .home {
            returnFromSearchToHome()
        } else if isHomeSearchPresented {
            cancelSearch()
            isHomeSearchPresented = false
        }
        selectedSection = section
    }

    func cancelSearch() {
        searchSessionID = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
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
        episode: PlayEpisode
    ) async {
        guard let environment, let provider = providers[detail.summary.siteKey] else { return }
        let sessionID = UUID()
        playbackSessionID = sessionID
        playbackQualitySwitchSessionID = UUID()
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        pendingPlayback = PendingCloudPlayback(
            detail: detail,
            source: source,
            episode: episode
        )
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        activePlayback = nil
        detailLoadSessionID = UUID()
        selectedDetail = nil
        pendingDetailSummary = nil
        playbackResolutionState = .resolving
        currentPlaybackAttempt = PlaybackAttempt(
            siteName: detail.summary.siteName,
            sourceName: source.name,
            episodeName: episode.name,
            parserName: nil,
            redactedURL: "<正在获取播放地址>",
            number: 1
        )
        playbackFailureSummary = nil
        playerSnapshot = PlayerSnapshot(
            status: .loading,
            volume: playerSnapshot.volume,
            isMuted: playerSnapshot.isMuted,
            speed: playerSnapshot.speed
        )
        presentPlayer()
        await environment.player.stop()

        do {
            guard detail.playSources.contains(where: { $0.id == source.id }) else {
                throw AppError.playback("当前线路不在详情数据中")
            }
            let episodeIndex = source.episodes.firstIndex(
                where: { $0.id == episode.id }
            )
            let httpClient = configuredHTTPClient(environment: environment)
            let resolver = PlaybackResolver(
                parseExecutor: AppParseExecutor(httpClient: httpClient),
                mediaProbe: DefaultMediaProbe(httpClient: httpClient)
            )
            var failures: [String] = []
            var completedAttempts = 0

            for candidateSource in Self.orderedPlaybackSources(
                detail.playSources,
                selectedSourceID: source.id
            ) {
                try Task.checkCancellation()
                guard playbackSessionID == sessionID else {
                    throw CancellationError()
                }
                let candidateEpisode = candidateSource.episodes.first(
                    where: { $0.name == episode.name }
                ) ?? episodeIndex.flatMap { index in
                    candidateSource.episodes.indices.contains(index)
                        ? candidateSource.episodes[index]
                        : nil
                }
                guard let candidateEpisode else { continue }

                currentPlaybackAttempt = PlaybackAttempt(
                    siteName: detail.summary.siteName,
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
                    result = try await provider.player(
                        flag: candidateSource.name,
                        episodeURL: candidateEpisode.url
                    )
                } catch let authorization as NodeWebAuthorizationRequired {
                    presentNodeConfiguration(
                        authorization,
                        pending: .playback(
                            PendingCloudPlayback(
                                detail: detail,
                                source: source,
                                episode: episode
                            )
                        )
                    )
                    return
                } catch let authorization as AndroidBridgeUIRequired {
                    await presentCloudAuthorization(
                        authorization.state,
                        pending: PendingCloudPlayback(
                            detail: detail,
                            source: source,
                            episode: episode
                        )
                    )
                    return
                } catch {
                    failures.append(
                        "\(candidateSource.name)：\(error.localizedDescription)"
                    )
                    playbackFailureSummary = error.localizedDescription
                    continue
                }

                let candidate = PlaybackCandidate(
                    siteKey: detail.summary.siteKey,
                    siteName: detail.summary.siteName,
                    sourceName: candidateSource.name,
                    episodeName: candidateEpisode.name,
                    result: result
                )
                let remainingAttempts = max(1, 8 - completedAttempts)
                var attemptsInCandidate = 0
                var candidateFailure: String?
                let stream = resolver.resolve(
                    PlaybackResolutionRequest(
                        candidates: [candidate],
                        parsers: activeConfiguration?.parses ?? [],
                        maximumAttempts: remainingAttempts
                    ),
                    mediaLoader: { [weak self] media, _ in
                        guard let self,
                              self.playbackSessionID == sessionID else {
                            throw CancellationError()
                        }
                        try await self.loadResolvedPlayback(
                            media,
                            detail: detail,
                            source: source,
                            episode: episode,
                            playbackResult: result
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
                        playbackFailureSummary = message
                    case .resolved:
                        playbackFailureSummary = nil
                        pendingPlayback = nil
                        return
                    case .failed(let message):
                        candidateFailure = message
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

            let message = failures.suffix(4).joined(separator: "；")
                .nonEmpty ?? "所有线路都无法返回可播放媒体"
            playbackResolutionState = .exhausted
            playbackFailureSummary = message
            playerSnapshot.status = .failed(message)
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
        }
    }

    @discardableResult
    func importLiveSource(
        source: LiveSourceInput,
        name: String?
    ) async -> Bool {
        guard let environment else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await environment.liveSourceLoader.load(source)
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
            try await environment.database.saveLiveSource(record)
            liveSources = try await environment.database.liveSources()
            loadedLivePlaylists[record.id] = loaded.playlist
            await loadEPG(for: record, playlist: loaded.playlist)
            return true
        } catch {
            show(error, title: "直播源加载失败")
            return false
        }
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
            await loadEPG(for: source, playlist: playlist)
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
            epgFailures[id] = nil
            await loadEPG(for: updated, playlist: loaded.playlist)
        } catch {
            show(error, title: "直播源刷新失败")
        }
    }

    func deleteLiveSource(_ id: UUID) async {
        guard let environment else { return }
        do {
            try await environment.database.deleteLiveSource(id: id)
            liveSources = try await environment.database.liveSources()
            loadedLivePlaylists[id] = nil
            loadedEPGGuides[id] = nil
            epgFailures[id] = nil
        } catch {
            show(error, title: "删除直播源失败")
        }
    }

    func playLive(
        channel: LiveChannel,
        stream: LiveStream,
        sourceID: UUID
    ) async {
        guard let environment else { return }
        do {
            let media = ResolvedMedia(
                url: stream.url,
                headers: HTTPHeaders(stream.headers),
                format: stream.format,
                siteKey: "live",
                sourceName: channel.name,
                episodeName: stream.name
            )
            activePlayback = nil
            pendingPlayback = nil
            livePlaybackChannel = channel
            livePlaybackStream = stream
            livePlaybackSourceID = sourceID
            playbackQualitySwitchSessionID = UUID()
            playbackQualities = []
            selectedPlaybackQualityID = nil
            isSwitchingPlaybackQuality = false
            presentPlayer()
            try await environment.player.load(media, startPosition: nil)
        } catch {
            livePlaybackChannel = nil
            livePlaybackStream = nil
            livePlaybackSourceID = nil
            await dismissPlayerSurfaceAndRestoreWindow()
            show(error, title: "直播播放失败")
        }
    }

    func isLiveFavorite(sourceName: String, channel: LiveChannel) -> Bool {
        favoriteLiveChannelIDs.contains(liveFavoriteID(sourceName: sourceName, channel: channel))
    }

    func toggleLiveFavorite(sourceName: String, channel: LiveChannel) async {
        guard let environment else { return }
        let id = liveFavoriteID(sourceName: sourceName, channel: channel)
        if favoriteLiveChannelIDs.contains(id) {
            favoriteLiveChannelIDs.remove(id)
        } else {
            favoriteLiveChannelIDs.insert(id)
        }
        do {
            try await environment.database.setSetting(
                .array(favoriteLiveChannelIDs.sorted().map(JSONValue.string)),
                forKey: "live.favoriteChannels"
            )
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
            _ = try await environment.database.deleteHistory(
                configurationID: configurationID
            )
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
                    videoID: record.videoID
                )
            }
            try await reloadHistory()
        } catch {
            show(error, title: "删除历史失败")
        }
    }

    func exportDiagnostics(to url: URL) throws {
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
        let report: [String: Any] = [
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
        await finishScheduledHistoryPersistence()
        if activePlayback != nil {
            try? await savePlaybackHistory(
                position: playerSnapshot.position,
                duration: playerSnapshot.duration
            )
        }
        cloudAuthorizationPollTask?.cancel()
        cloudAuthorizationPollTask = nil
        playerEventTask?.cancel()
        playerEventTask = nil
        await environment?.player.shutdown()
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
        guard !isClosingPlayer else { return }
        guard isPlayerPresented
                || activePlayback != nil
                || pendingPlayback != nil
                || livePlaybackChannel != nil else {
            return
        }
        isClosingPlayer = true
        defer { isClosingPlayer = false }
        playbackSessionID = UUID()
        playbackQualitySwitchSessionID = UUID()
        // Capture the final position before stop resets the player snapshot.
        await persistPlaybackProgress()
        // Ignore the stop event for history purposes. It otherwise publishes a
        // second, zeroed history update while the player is being dismissed.
        activePlayback = nil
        pendingPlayback = nil
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        playbackQualities = []
        selectedPlaybackQualityID = nil
        isSwitchingPlaybackQuality = false
        await environment?.player.stop()
        await dismissPlayerSurfaceAndRestoreWindow()
        playbackResolutionState = .idle
        currentPlaybackAttempt = nil
        playbackFailureSummary = nil
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
        let target = min(
            max(0, playerSnapshot.position + offset),
            playerSnapshot.duration > 0
                ? playerSnapshot.duration
                : .greatestFiniteMagnitude
        )
        await seek(to: target)
    }

    func seek(to position: TimeInterval) async {
        guard let player = environment?.player else { return }
        guard let target = PlayerSeekPolicy.target(
            requested: position,
            duration: playerSnapshot.duration
        ) else {
            show(AppError.playback("跳转位置无效"), title: "跳转失败")
            return
        }
        let previousPosition = playerSnapshot.position
        // Publish the accepted target immediately. Some network sources delay
        // or coalesce mpv's time-pos notification after a seek, while the
        // decoded video has already moved to the requested frame.
        playerSnapshot.position = target
        do {
            try await player.seek(to: target)
        } catch {
            if playerSnapshot.position == target {
                playerSnapshot.position = previousPosition
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

    var selectedPlaybackQualityName: String? {
        playbackQualities.first { $0.id == selectedPlaybackQualityID }?.name
    }

    func switchPlaybackQuality(_ quality: PlaybackQuality) async {
        guard let environment,
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
            let candidate = PlaybackCandidate(
                siteKey: playback.detail.summary.siteKey,
                siteName: playback.detail.summary.siteName,
                sourceName: playback.source.name,
                episodeName: playback.episode.name,
                result: playbackResult
            )
            var resolvedMedia: ResolvedMedia?
            var failureMessage: String?
            for await event in resolver.resolve(
                PlaybackResolutionRequest(
                    candidates: [candidate],
                    parsers: activeConfiguration?.parses ?? [],
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
            try await environment.player.load(
                resolvedMedia,
                startPosition: previousPosition
            )
            guard playbackQualitySwitchSessionID == switchSessionID,
                  playbackSessionID == owningPlaybackSessionID else {
                throw CancellationError()
            }
            if wasPaused {
                try await environment.player.pause()
            }
            activePlayback = ActivePlaybackContext(
                detail: playback.detail,
                source: playback.source,
                episode: playback.episode,
                media: resolvedMedia,
                playbackResult: playbackResult
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
            currentPlaybackAttempt = nil
            var restoreError: Error?
            if replacementStarted,
               playbackQualitySwitchSessionID == switchSessionID,
               playbackSessionID == owningPlaybackSessionID {
                do {
                    try await environment.player.load(
                        previousMedia,
                        startPosition: previousPosition
                    )
                    if wasPaused {
                        try await environment.player.pause()
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
            episode: playback.source.episodes[nextIndex]
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
            episode: episode
        )
    }

    func reportPlayerRenderError(_ error: Error) {
        show(error, title: "视频渲染失败")
    }

    var visibleSites: [SiteConfiguration] {
        (activeConfiguration?.sites ?? []).filter { $0.hide == 0 }
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
            let message = LogRedactor.text(error.localizedDescription)
            androidRuntimeStatus = .failed(message)
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
            let message = LogRedactor.text(error.localizedDescription)
            androidRuntimeStatus = .failed(message)
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
        environment?.player as? MPVPlayerClient
    }

    var playerRuntimeDescription: String {
        embeddedPlayer?.runtimeDescription ?? "libmpv 不可用"
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
              let sourceID = livePlaybackSourceID,
              let guide = loadedEPGGuides[sourceID] else {
            return (nil, nil)
        }
        return guide.currentAndNext(for: channel, at: Date())
    }

    var playbackStageDescription: String {
        if case .failed = playerSnapshot.status {
            return "播放失败"
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

    var currentPlayerEpisodeID: String? {
        activePlayback?.episode.id ?? pendingPlayback?.episode.id
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

        // Original cloud-drive sources are commonly listed after their smart
        // counterpart. If the local original proxy fails, retry the matching
        // smart source before unrelated lines, regardless of list order.
        if selected.name.contains("原") {
            let family = cloudSourceFamily(selected.name)
            output.append(contentsOf: sources.filter {
                $0.id != selected.id
                    && $0.name.contains("智")
                    && cloudSourceFamily($0.name) == family
            })
        }

        output.append(contentsOf: sources.dropFirst(selectedIndex + 1))
        output.append(contentsOf: sources.prefix(selectedIndex))
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func cloudSourceFamily(_ name: String) -> String {
        String(name.filter { character in
            character != "原" && character != "智" && !character.isNumber
        })
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

    static func historyRecords(
        _ records: [HistoryRecord],
        for configurationID: UUID?
    ) -> [HistoryRecord] {
        guard let configurationID else { return [] }
        return records.filter { $0.configurationID == configurationID }
    }

    static func historyPlaybackSelection(
        in detail: VideoDetail,
        record: HistoryRecord
    ) -> (source: PlaySource, episode: PlayEpisode)? {
        let matchingSources: [PlaySource]
        if let sourceName = record.sourceName?.nonEmpty {
            matchingSources = detail.playSources.filter {
                $0.name.compare(
                    sourceName,
                    options: [.caseInsensitive, .widthInsensitive]
                ) == .orderedSame
            }
        } else {
            matchingSources = detail.playSources
        }

        if let episodeName = record.episodeName?.nonEmpty {
            for source in matchingSources {
                if let episode = source.episodes.first(where: {
                    $0.name.compare(
                        episodeName,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                }) {
                    return (source, episode)
                }
            }

            // A source may be renamed while episode names remain stable.
            for source in detail.playSources where !matchingSources.contains(source) {
                if let episode = source.episodes.first(where: {
                    $0.name.compare(
                        episodeName,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                }) {
                    return (source, episode)
                }
            }
        }

        if matchingSources.count == 1,
           matchingSources[0].episodes.count == 1,
           let episode = matchingSources[0].episodes.first {
            return (matchingSources[0], episode)
        }
        return nil
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
        guard let rawReference = record.mediaReference?.nonEmpty,
              !rawReference.localizedCaseInsensitiveContains("<redacted>"),
              !rawReference.localizedCaseInsensitiveContains("%3credacted%3e"),
              let url = URL(string: rawReference),
              ["http", "https", "file"].contains(
                url.scheme?.lowercased() ?? ""
              ) else {
            return nil
        }
        let context = historyPlaybackContext(
            record: record,
            siteName: siteName,
            episodeURL: record.episodeReference?.nonEmpty ?? rawReference
        )
        let media = ResolvedMedia(
            url: url,
            headers: [:],
            siteKey: record.siteKey,
            sourceName: context.source.name,
            episodeName: context.episode.name
        )
        return (context.detail, context.source, context.episode, media)
    }

    static func historySearchMatch(
        in items: [VideoSummary],
        record: HistoryRecord
    ) -> VideoSummary? {
        if let exact = items.first(where: {
            $0.title.compare(
                record.title,
                options: [
                    .caseInsensitive,
                    .widthInsensitive,
                    .diacriticInsensitive
                ]
            ) == .orderedSame
        }) {
            return exact
        }
        return items.first {
            $0.title.localizedCaseInsensitiveContains(record.title)
                || record.title.localizedCaseInsensitiveContains($0.title)
        }
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
            return
        }
        lastAutomaticConfigurationRefreshAttemptAt = record.updatedAt
        activeConfiguration = try ConfigurationParser().parse(record.rawData)
        rebuildProviders()
        if !supportedSites.contains(where: { $0.key == selectedSiteKey }) {
            selectedSiteKey = supportedSites.first?.key
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
            return try await environment.nodeBundleRuntime
                .loadConfiguration(from: url)
        }
        return try await environment.configurationLoader.load(source)
    }

    private func prepareActiveNodeConfigurationIfNeeded() async throws {
        guard let environment,
              let record = activeConfigurationRecord,
              record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let sourceURL = URL(string: sourceValue),
              NodeBundleRuntimeService.supports(sourceURL) else {
            return
        }
        let loaded = try await environment.nodeBundleRuntime
            .loadConfiguration(from: sourceURL)
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

    private var activeConfigurationUsesNodeRuntime: Bool {
        guard let record = activeConfigurationRecord,
              record.sourceKind == .remote,
              let sourceValue = record.sourceValue,
              let sourceURL = URL(string: sourceValue) else {
            return false
        }
        return NodeBundleRuntimeService.supports(sourceURL)
    }

    private func selectedSiteSettingKey(for configurationID: UUID) -> String {
        "home.selectedSite.\(configurationID.uuidString.lowercased())"
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
              supportedSites.contains(where: { $0.key == preferredKey }) else {
            return
        }
        selectedSiteKey = preferredKey
    }

    private func prepareActiveConfigurationHome(
        reportLoadErrors: Bool = true,
        loadInBackground: Bool = true
    ) async {
        homeLoadSessionID = UUID()
        categoryLoadSessionID = UUID()
        siteHome = nil
        selectedCategoryID = nil
        categoryPage = nil
        categoryPaginationError = nil
        homeLoadErrorMessage = nil
        await restoreSelectedSitePreference()
        await restoreCachedSiteHome()
        guard loadInBackground else {
            isHomeLoading = false
            return
        }
        guard let key = selectedSiteKey,
              siteCapability(for: key) != .unsupportedSpider else {
            isHomeLoading = false
            return
        }
        isHomeLoading = true
        Task { [weak self] in
            await self?.loadSelectedSiteHome(
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

    private func restoreCachedSiteHome() async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id,
              let siteKey = selectedSiteKey,
              let value = try? await environment.database.setting(
                forKey: homeCacheSettingKey(
                    configurationID: configurationID,
                    siteKey: siteKey
                )
              ),
              case .string(let encoded) = value,
              let data = Data(base64Encoded: encoded),
              let cached = try? JSONDecoder().decode(SiteHome.self, from: data) else {
            return
        }
        siteHome = cached
    }

    private func cacheSiteHome(_ home: SiteHome, siteKey: String) async {
        guard let environment,
              let configurationID = activeConfigurationRecord?.id,
              let data = try? JSONEncoder().encode(home) else { return }
        try? await environment.database.setSetting(
            .string(data.base64EncodedString()),
            forKey: homeCacheSettingKey(
                configurationID: configurationID,
                siteKey: siteKey
            )
        )
    }

    private func rebuildProviders() {
        guard let environment else {
            providers = [:]
            return
        }
        let baseURL = activeConfigurationRecord?.baseURL
        let httpClient = configuredHTTPClient(environment: environment)
        providers = Dictionary(
            uniqueKeysWithValues: visibleSites.map { site in
                let provider: SiteProvider
                if NodeHTTPSpiderSiteProvider.canHandle(
                    site: site,
                    baseURL: baseURL
                ), let baseURL {
                    provider = (try? NodeHTTPSpiderSiteProvider(
                        site: site,
                        baseURL: baseURL,
                        httpClient: httpClient
                    )) ?? UnsupportedSiteProvider(site: site)
                } else if [0, 1, 4].contains(site.type) {
                    provider = (try? StandardSiteProvider(
                        site: site,
                        httpClient: httpClient,
                        configurationBaseURL: baseURL
                    )) ?? UnsupportedSiteProvider(site: site)
                } else if site.type == 3,
                          let factory = environment.spiderRuntimeFactory,
                          let scriptURL = javaScriptURL(for: site, baseURL: baseURL) {
                    provider = (try? JavaScriptSpiderSiteProvider(
                        site: site,
                        scriptURL: scriptURL,
                        baseURL: baseURL,
                        httpClient: httpClient,
                        runtimeFactory: factory
                    )) ?? UnsupportedSiteProvider(site: site)
                } else if site.type == 3,
                          site.api.hasPrefix("csp_"),
                          let jarReference = javaDexJarReference(for: site) {
                    provider = (try? AndroidDexSpiderSiteProvider(
                        site: site,
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
        var references: [String] = []
        if let script = site.extra["script"]?.stringValue {
            references.append(script)
        }
        if let script = site.ext?.objectValue?["script"]?.stringValue {
            references.append(script)
        }
        references.append(site.api)
        if let spider = activeConfiguration?.spider {
            references.append(spider)
        }
        for reference in references {
            if let resolved = try? ResourceResolver.resolve(reference, relativeTo: baseURL),
               resolved.path.lowercased().hasSuffix(".js"),
               ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") {
                return resolved
            }
        }
        return nil
    }

    private func javaDexJarReference(for site: SiteConfiguration) -> String? {
        let reference = site.jar ?? activeConfiguration?.spider
        guard let reference,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return reference
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
            epgFailures[source.id] = nil
            return
        }
        do {
            loadedEPGGuides[source.id] = try await environment.epgService.guide(
                for: epgURL
            )
            epgFailures[source.id] = nil
        } catch {
            loadedEPGGuides[source.id] = nil
            epgFailures[source.id] = error.localizedDescription
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
            forKey: "live.favoriteChannels"
        ), case .array(let identifiers) = value {
            favoriteLiveChannelIDs = Set(identifiers.compactMap(\.stringValue))
        }
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
        guard playerEventTask == nil, let player = environment?.player else { return }
        playerEventTask = Task { [weak self] in
            for await event in player.events {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
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
                case .fileLoaded:
                    await self.applyPlayerSubtitlePreference()
                case .ended:
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
                case .error(let message):
                    self.show(AppError.playback(message), title: "播放器错误")
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
            episode: nextEpisode
        )
    }

    private func applyPlayerSubtitlePreference() async {
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
            playerSubtitlesEnabled = false
            return
        }
        do {
            try await environment?.player.selectTrack(
                id: track.id,
                type: .subtitle
            )
            playerSubtitlesEnabled = true
            preferredPlayerSubtitleTrack = PlayerSubtitleTrackPreference(
                track: track
            )
        } catch {
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

    private func loadResolvedPlayback(
        _ media: ResolvedMedia,
        detail: VideoDetail,
        source: PlaySource,
        episode: PlayEpisode,
        playbackResult: SitePlaybackResult? = nil
    ) async throws {
        guard let environment else {
            throw AppError.playback("播放器环境不可用")
        }
        let existing = history.first {
            $0.siteKey == detail.summary.siteKey
                && $0.videoID == detail.summary.videoID
                && $0.sourceName == source.name
                && $0.episodeName == episode.name
        }
        let startPosition: TimeInterval?
        if let existing,
           existing.position > 0,
           existing.duration == 0 || existing.position < existing.duration - 20 {
            startPosition = existing.position
        } else {
            startPosition = nil
        }
        let playback = ActivePlaybackContext(
            detail: detail,
            source: source,
            episode: episode,
            media: media,
            playbackResult: playbackResult
        )
        livePlaybackChannel = nil
        livePlaybackStream = nil
        livePlaybackSourceID = nil
        selectedDetail = nil
        presentPlayer()
        try await environment.player.load(media, startPosition: startPosition)
        activePlayback = playback
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
        guard let playback = activePlayback,
              let configurationID = activeConfigurationRecord?.id else {
            return nil
        }
        let detail = playback.detail
        return PlaybackHistoryWrite(
            record: HistoryRecord(
                configurationID: configurationID,
                siteKey: detail.summary.siteKey,
                videoID: detail.summary.videoID,
                title: detail.summary.title,
                posterURL: detail.summary.posterURL,
                sourceName: playback.source.name,
                episodeName: playback.episode.name,
                episodeReference: playback.episode.url,
                mediaReference: playback.media.url.absoluteString,
                position: position,
                duration: duration
            ),
            incognito: incognitoMode
        )
    }

    private func persistPlaybackHistoryWrite(
        _ write: PlaybackHistoryWrite,
        reloadHistoryAfterSaving: Bool
    ) async throws {
        guard let environment else { return }
        try await environment.database.saveHistory(
            write.record,
            incognito: write.incognito
        )
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

    private func presentPlayer() {
        if !isPlayerPresented {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            playerStartedInFullScreen = window?.styleMask.contains(.fullScreen)
                ?? false
        }
        isPlayerPresented = true
    }

    private func restoreWindowAfterPlayer() async {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let shouldExit = Self.shouldExitFullScreenAfterPlayer(
            startedInFullScreen: playerStartedInFullScreen,
            isFullScreen: isFullScreen
        )
        playerStartedInFullScreen = false
        guard shouldExit, let window else { return }
        window.toggleFullScreen(nil)
        for _ in 0..<40 where window.styleMask.contains(.fullScreen) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func dismissPlayerSurfaceAndRestoreWindow() async {
        isPlayerPresented = false
        // Let SwiftUI hide the player chrome and restore its window
        // configurator before a possible full-screen transition begins. The
        // render surface intentionally stays mounted for the next playback.
        await Task.yield()
        await restoreWindowAfterPlayer()
    }

    static func shouldExitFullScreenAfterPlayer(
        startedInFullScreen: Bool,
        isFullScreen: Bool
    ) -> Bool {
        !startedInFullScreen && isFullScreen
    }

    private func show(_ error: Error, title: String) {
        presentedError = UserFacingError(
            title: title,
            message: error.localizedDescription
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
