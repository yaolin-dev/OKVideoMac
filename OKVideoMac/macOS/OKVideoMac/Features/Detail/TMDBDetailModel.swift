import AppKit
import Foundation
import OKVideoCore
import SwiftUI
import Network
import SystemConfiguration
import CFNetwork
import Security

enum TMDBMatchingPreferences {
    static let key = "detail.tmdb.relaxedMatching"
    static func policy(defaults: UserDefaults = .standard) -> TMDBMatchPolicy {
        defaults.bool(forKey: key) ? .relaxed : .strict
    }
}

private struct TMDBEpisodeMappingInput: Equatable, Sendable {
    let revision: UInt64
    let source: PlaySource
    let category: String?
    let work: TMDBWork
    let match: TMDBMatchInput
    let manualSeason: Int?
    let seasons: [Int: TMDBSeason]

    func prepare() throws -> TMDBPreparedEpisodeMapping {
        try Task.checkCancellation()
        let numbers = TMDBEpisodeMapper.seasonNumbers(work: work, input: match, source: source, manual: manualSeason)
        let context = TMDBEpisodeMapper.season(work: work, input: match, source: source, manual: manualSeason)
        var result: [Int: TMDBEpisode] = [:]
        for number in numbers {
            try Task.checkCancellation()
            guard let season = seasons[number] else { continue }
            for (index, episode) in TMDBEpisodeMapper.episodes(source.episodes, category: category, season: season) {
                try Task.checkCancellation()
                if context == nil || number != context {
                    let item = source.episodes[index]
                    let parsed = PlaybackResourceAnalyzer.analyze(item, categoryName: "电视剧")
                    guard (item.metadata?.season ?? parsed.season) == number else { continue }
                }
                result[index] = episode
            }
        }
        return TMDBPreparedEpisodeMapping(input: self, episodes: result, usedMainThread: Thread.isMainThread)
    }
}

private struct TMDBPreparedEpisodeMapping: Sendable {
    let input: TMDBEpisodeMappingInput
    let episodes: [Int: TMDBEpisode]
    let usedMainThread: Bool
}

@MainActor
final class TMDBDetailModel: ObservableObject {
    @Published private(set) var selection: TMDBCandidate? {
        didSet { if oldValue != selection { invalidateEpisodeMapping() } }
    }
    @Published private(set) var binding: TMDBBinding? {
        didSet { if oldValue?.seasons != binding?.seasons { invalidateEpisodeMapping() } }
    }
    @Published private(set) var candidates: [TMDBCandidate] = []
    @Published private(set) var season: TMDBSeason?
    @Published private(set) var isLoadingSeason = false
    @Published private(set) var seasonError: String?
    private var seasonScope: String?
    @Published private(set) var loadedSeasons: [Int: TMDBSeason] = [:] {
        didSet { if oldValue != loadedSeasons { invalidateEpisodeMapping() } }
    }
    @Published private(set) var episodeMappingInputRevision: UInt64 = 0
    @Published private var preparedEpisodeMapping: TMDBPreparedEpisodeMapping?
    private var episodeMappingTask: (id: UUID, input: TMDBEpisodeMappingInput, task: Task<TMDBPreparedEpisodeMapping, Error>)?
    private let mappingSourceIdentities = TMDBSourceIdentityCache()
    private(set) var episodeMappingComputationCount = 0
    private(set) var episodeMappingComputedOnMain = false
    private var seasonRequestSource: PlaySource?
    private var seasonRequestCategory: String?
    private var seasonTask: Task<Void, Never>?
    @Published private(set) var imageConfiguration: TMDBImageConfiguration?
    @Published private(set) var isSearching = false
    @Published private(set) var actionError: String?
    @Published private(set) var isChoosing = false
    @Published private(set) var originalRequested = false
    var needsMatchConfirmation: Bool {
        selection == nil && !candidates.isEmpty && !isPreparing && !isAwaitingSourceIdentity && !originalRequested
    }
    private var repository: TMDBRepository?
    private var input: TMDBMatchInput? {
        didSet { if oldValue != input { invalidateEpisodeMapping() } }
    }
    private var key: String?
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var seasonGeneration = UUID()

    // The caller freezes an eligible layout at entry. Later link updates do
    // not change this page; explicit presentation choices may change it.
    @Published private(set) var pageMode: TMDBPageMode = .source
    @Published private(set) var usesUnifiedLayout = false
    @Published private(set) var networkRequestsSuspended = false
    var hasStartedEntry: Bool { entryManaged }
    @Published private(set) var isPreparing = false
    @Published private(set) var isAwaitingSourceIdentity = false
    private var resolutionGeneration = UUID()
    private var selectionIsPreview = false
    private(set) var matchPolicy: TMDBMatchPolicy = .strict
    @Published private(set) var navigationID = UUID()
    @Published private(set) var decisionReason = "not-started"
    private var availability: TMDBAvailability?
    private var entryManaged = false
    private var entryTasks: [Task<Void, Never>] = []
    private var resolvingInput: TMDBMatchInput?
    private var entrySummary: VideoSummary?
    private var entryID = UUID()
    private var entryStartedAt: TimeInterval = 0
    private var preparationBudget: TimeInterval = 15

    func beginEntry(repository: TMDBRepository?, key: String?, summary: VideoSummary,
                    availability: TMDBAvailability, startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
                    enabled: Bool, budget: TimeInterval = 15, preserveNavigation: Bool = false, policy: TMDBMatchPolicy = .strict) {
        cancel()
        matchPolicy = policy
        if policy == .strict && binding?.isRelaxed == true {
            selection = nil; binding = nil; season = nil; loadedSeasons = [:]; displayedHeroURL = nil
        }
        entryManaged = true
        networkRequestsSuspended = !enabled
        if !preserveNavigation {
            navigationID = UUID(); selection = nil; season = nil; loadedSeasons = [:]; binding = nil; displayedHeroURL = nil
            imageConfiguration = nil
        }
        self.repository = repository; self.key = key; self.availability = availability
        entrySummary = summary
        input = .init(detail: .init(summary: summary)); resolvingInput = nil
        candidates = []; actionError = nil; originalRequested = false
        usesUnifiedLayout = enabled
        pageMode = selection == nil ? .source : .enhanced
        entryID = UUID(); entryStartedAt = startedAt; preparationBudget = max(0.01, budget)
        decisionReason = "not-started"
        displayedEpisodeArtwork = false
        let token = generation
        logEntry("opened")
        guard enabled, let repository, let key, let input else {
            logEntry("disabled-or-source-unavailable"); return
        }
        isPreparing = true
        entryTasks.append(Task { [weak self] in
            guard let self else { return }
            let cached = await repository.cachedResolution(key: key, input: input, policy: policy)
            guard self.generation == token, !Task.isCancelled, self.resolvingInput == nil else { return }
            if let cached { self.apply(cached); self.logEntry("cache-hit") }
            else { self.logEntry("cache-miss") }
            // Require independently useful year + form evidence before a cold
            // card can display an automatic match. The normal strict matcher
            // still checks aliases, rivals, credits and conflicts in full detail.
            if cached != nil || input.canPrepareFromSummary || (policy == .relaxed && !input.hasConflict) {
                self.prepareMetadata(input, persistBinding: false)
            } else {
                self.isPreparing = false
                self.isAwaitingSourceIdentity = true
                self.logEntry("awaiting-source-identity")
                await repository.prefetch(input: input)
            }
        })
    }

    func receive(detail: VideoDetail, key: String?) {
        guard entryManaged, usesUnifiedLayout, !originalRequested, !networkRequestsSuspended,
              key == self.key, repository != nil, key != nil else { return }
        let value = TMDBMatchInput(detail: detail, fallbackSummary: entrySummary)
        NSLog("[TMDB] source-identity site=%@ title=%@ year=%@ type=%@ cast=%d conflict=%@", detail.summary.siteName, detail.summary.title,
              value.year.map(String.init) ?? "missing", value.type?.rawValue ?? "missing", value.principalActors.count,
              value.hasConflict ? "yes" : "no")
        guard resolvingInput != value else { return }
        input = value; resolvingInput = value
        if let selection {
            let incompatible = binding?.identity.map { !$0.isCompatible(with: value) } ?? false
            let evidence = TMDBMatcher.assess(selection, input: value)
            let relaxed = matchPolicy == .relaxed && binding?.isRelaxed == true
            let conflict = binding?.manual != true && (relaxed
                ? !TMDBMatcher.acceptsRelaxed(selection, input: value)
                : (evidence.conflict || (selectionIsPreview && !evidence.acceptsAutomatically)))
            if incompatible || conflict {
                self.selection = nil; season = nil; loadedSeasons = [:]; seasonGeneration = UUID(); binding = nil; candidates = []; pageMode = .source
            }
        }
        prepareMetadata(value, persistBinding: true)
    }

    private func prepareMetadata(_ value: TMDBMatchInput, persistBinding: Bool) {
        guard !networkRequestsSuspended, let repository, let key else { return }
        resolutionGeneration = UUID()
        let request = resolutionGeneration, token = generation, budget = preparationBudget, policy = matchPolicy
        isPreparing = true; isAwaitingSourceIdentity = false
        entryTasks.append(Task { [weak self] in
            guard let self else { return }
            let cached = await repository.cachedResolution(key: key, input: value, policy: policy)
            guard self.generation == token, self.resolutionGeneration == request, !Task.isCancelled else { return }
            if let cached { self.apply(cached); self.logEntry("cache-hit") }
            self.logEntry("refresh-started")
            do {
                // The repository owns and coalesces bounded work across visits.
                let result = try await repository.prepare(key: key, input: value, timeout: budget, persistBinding: persistBinding, policy: policy)
                guard self.generation == token, self.resolutionGeneration == request, !Task.isCancelled else { return }
                if case .candidates(let candidates) = result {
                    for candidate in candidates.prefix(4) {
                        let evidence = TMDBMatcher.assess(candidate, input: value)
                        NSLog("[TMDB] rejected work=%d title=%@ year=%@ type=%@ cast=%@ director=%@ conflict=%@ directorPending=%@", candidate.reference.id,
                              String(evidence.exactTitle), String(evidence.matchingYear), String(evidence.matchingType), String(evidence.corroboratedCast),
                              String(evidence.corroboratedDirector), String(evidence.conflict), String(evidence.unresolvedDirector))
                    }
                }
                self.apply(result)
                self.selectionIsPreview = !persistBinding && cached == nil && self.binding?.manual != true && self.selection != nil
                self.isPreparing = false
                self.logEntry(self.selection == nil ? "unresolved-identity" : "metadata-ready")
            } catch {
                guard self.generation == token, self.resolutionGeneration == request, !Task.isCancelled else { return }
                self.isPreparing = false
                // A failed refresh never discards the last verified work.
                self.logEntry(self.selection == nil ? "refresh-failed-source-retained" : "refresh-failed-cache-retained")
            }
        })
    }

    private func logEntry(_ reason: String) {
        decisionReason = reason
        let id = entryID, mode = pageMode.rawValue
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - entryStartedAt) * 1000)
        let selected = selection?.reference.id ?? 0
        let matching = binding?.manual == true ? "manual" : binding?.isRelaxed == true ? "relaxed" : selection != nil ? "strict" : "none"
        let availability = availability
        Task {
            let links = await availability?.snapshot()
            NSLog("[TMDB] entry=%@ mode=%@ reason=%@ elapsedMs=%d work=%d metadata=%@ images=%@ matching=%@",
                  id.uuidString, mode, reason, milliseconds, selected,
                  links?.metadata.state.rawValue ?? "unknown", links?.images.state.rawValue ?? "unknown", matching)
        }
    }

    /// Global appearance choice is independent of saved movie/season bindings.
    /// Synchronous cancellation prevents a late metadata request changing it back.
    func setPresentationEnabled(_ enabled: Bool, detail: VideoDetail?) {
        if enabled, let detail { retryEnhanced(detail: detail) }
        else {
            cancel()
            selection = nil; season = nil; candidates = []
            usesUnifiedLayout = false; networkRequestsSuspended = true; pageMode = .source; originalRequested = false
            if entryManaged { logEntry("settings-original") }
        }
    }

    func setMatchPolicy(_ policy: TMDBMatchPolicy, detail: VideoDetail) {
        guard matchPolicy != policy else { return }
        matchPolicy = policy
        guard usesUnifiedLayout, !originalRequested, !networkRequestsSuspended else { return }
        retryEnhanced(detail: detail)
    }

    func retryEnhanced(detail: VideoDetail) {
        guard let availability else { return }
        beginEntry(repository: repository, key: key, summary: detail.summary,
                   availability: availability, enabled: true, preserveNavigation: true, policy: matchPolicy)
        receive(detail: detail, key: key)
    }

    func load(repository: TMDBRepository?, key: String?, input: TMDBMatchInput, budget: TimeInterval = 15, policy: TMDBMatchPolicy = .strict) async {
        entryManaged = false
        usesUnifiedLayout = true; networkRequestsSuspended = false
        let changed = self.key != key || self.input != input || matchPolicy != policy
        matchPolicy = policy
        generation = UUID(); searchGeneration = UUID(); seasonGeneration = UUID()
        let token = generation
        self.repository = repository; self.key = key; self.input = input
        if changed || repository == nil { selection = nil; binding = nil; season = nil; candidates = []; originalRequested = false }
        actionError = nil; isSearching = false; isChoosing = false
        guard let repository, let key else { return }
        do {
            let value = try await Self.withBudget(budget) { try await repository.resolve(key: key, input: input, policy: policy) }
            guard generation == token, !Task.isCancelled else { return }
            apply(value)
        } catch {
            // Existing source detail is independent. Do not publish its failure
            // state, reset its selection, or remove already displayed good data.
        }
    }

    func loadSeason(source: PlaySource?, category: String?) async {
        guard !networkRequestsSuspended, !Task.isCancelled else { return }
        seasonRequestSource = source
        seasonRequestCategory = category
        seasonGeneration = UUID()
        let token = seasonGeneration
        isLoadingSeason = false; seasonError = nil
        guard let repository, let selection, selection.reference.type == .tv, let input else {
            season = nil; loadedSeasons = [:]; seasonScope = nil; return
        }
        let manual = source.flatMap { binding?.seasons[$0.stableIdentity] }
        let context = TMDBEpisodeMapper.season(work: selection.work, input: input, source: source, manual: manual)
        let numbers = TMDBEpisodeMapper.seasonNumbers(work: selection.work, input: input, source: source, manual: manual)
        season = context.flatMap { loadedSeasons[$0] }
        guard !numbers.isEmpty else { season = nil; logEntry("season-unresolved"); return }
        seasonScope = "\(selection.reference.id):\(numbers)"
        isLoadingSeason = true
        defer { if seasonGeneration == token { isLoadingSeason = false } }
        // Limit concurrency while retaining each season's independent result.
        for start in stride(from: 0, to: numbers.count, by: 2) {
            guard seasonGeneration == token, !Task.isCancelled else { return }
            let batch = Array(numbers[start..<min(start + 2, numbers.count)])
            for number in batch {
                if let cached = await repository.cachedSeason(tvID: selection.reference.id, number: number) {
                    guard seasonGeneration == token, !Task.isCancelled else { return }
                    loadedSeasons[number] = cached
                    if number == context { season = cached }
                }
            }
            await withTaskGroup(of: (Int, TMDBSeason?).self) { group in
                for number in batch {
                    group.addTask {
                        let value = try? await repository.season(tvID: selection.reference.id, number: number, ongoing: selection.work.status != "Ended")
                        return (number, value)
                    }
                }
                for await (number, value) in group {
                    guard seasonGeneration == token, !Task.isCancelled, self.selection?.reference == selection.reference else { group.cancelAll(); return }
                    if let value {
                        loadedSeasons[number] = value
                        if number == context { season = value }
                        logEntry("season-ready-\(number)")
                    } else {
                        seasonError = L10n.string("tmdb.season.failed", fallback: "Episode information is unavailable. Playback remains available.")
                        logEntry("season-request-failed-\(number)")
                    }
                }
            }
        }
        if seasonGeneration == token, let source {
            await prepareEpisodeMapping(source: source, category: category)
            guard seasonGeneration == token, !Task.isCancelled else { return }
            let mapping = episodeMapping(source: source, category: category)
            NSLog("[TMDB] entry=%@ episode-map line=%@ resources=%d mapped=%d missingStill=%d unresolved=%d", entryID.uuidString, source.name,
                  source.episodes.count, mapping.count, mapping.values.filter { $0.stillPath == nil }.count, source.episodes.count - mapping.count)
        }
    }

    /// Rendering reads an already-prepared value; no hashing, filename parsing
    /// or season matching is permitted in a SwiftUI body evaluation.
    func episodeMapping(source: PlaySource?, category: String?) -> [Int: TMDBEpisode] {
        guard let source, let prepared = preparedEpisodeMapping,
              prepared.input.revision == episodeMappingInputRevision,
              prepared.input.source == source,
              prepared.input.category == category else { return [:] }
        return prepared.episodes
    }

    func prepareEpisodeMapping(source: PlaySource?, category: String?) async {
        guard !Task.isCancelled, let source, let selection,
              selection.reference.type == .tv, let input else { return }
        let request = TMDBEpisodeMappingInput(revision: episodeMappingInputRevision,
            source: source, category: category, work: selection.work, match: input,
            manualSeason: binding?.seasons[mappingSourceIdentities.identity(source)],
            seasons: loadedSeasons)
        if preparedEpisodeMapping?.input == request { return }
        let operation: (id: UUID, input: TMDBEpisodeMappingInput, task: Task<TMDBPreparedEpisodeMapping, Error>)
        if let current = episodeMappingTask, current.input == request {
            operation = current
        } else {
            episodeMappingTask?.task.cancel()
            let task = Task.detached(priority: .userInitiated) {
                try request.prepare()
            }
            operation = (UUID(), request, task)
            episodeMappingTask = operation
            episodeMappingComputationCount += 1
        }
        do {
            let prepared = try await operation.task.value
            guard !Task.isCancelled, episodeMappingTask?.id == operation.id,
                  episodeMappingInputRevision == request.revision else { return }
            episodeMappingComputedOnMain = prepared.usedMainThread
            episodeMappingTask = nil
            preparedEpisodeMapping = prepared
        } catch {
            if episodeMappingTask?.id == operation.id { episodeMappingTask = nil }
        }
    }

    private func invalidateEpisodeMapping() {
        episodeMappingTask?.task.cancel()
        episodeMappingTask = nil
        preparedEpisodeMapping = nil
        episodeMappingInputRevision &+= 1
    }

    private func prepareKnownSeason() {
        guard let selection, selection.reference.type == .tv, let input,
              TMDBEpisodeMapper.season(work: selection.work, input: input, source: nil) != nil else { return }
        seasonTask?.cancel()
        let source = seasonRequestSource
        let category = seasonRequestCategory
        seasonTask = Task { [weak self] in
            // The visible line can arrive before this speculative task gets its
            // first actor turn. Never replace that newer source with the nil or
            // previous source captured while metadata was being applied.
            guard let self, self.seasonRequestSource == source,
                  self.seasonRequestCategory == category else { return }
            await self.loadSeason(source: source, category: category)
        }
    }

    func loadImageConfiguration() async {
        guard !networkRequestsSuspended, let repository, selection != nil else { return }
        let token = generation
        if let configuration = try? await repository.imageConfiguration(), generation == token, !Task.isCancelled {
            imageConfiguration = configuration
        }
    }

    func search(_ query: String, type: TMDBMediaType?) async {
        guard !networkRequestsSuspended, let repository else { return }
        searchGeneration = UUID()
        let token = searchGeneration
        actionError = nil; isSearching = true
        defer { if token == searchGeneration { isSearching = false } }
        do {
            let values = try await Self.withBudget(10) { try await repository.search(query: query, type: type) }
            guard token == searchGeneration, !Task.isCancelled else { return }
            candidates = values
            isSearching = false
        } catch {
            guard token == searchGeneration, !Task.isCancelled else { return }
            isSearching = false
            actionError = L10n.string("tmdb.search.failed", fallback: "Metadata is unavailable. Your original details and playback remain available.")
        }
    }

    func choose(_ candidate: TMDBCandidate) async -> Bool {
        guard !networkRequestsSuspended, let repository, let key, let input else { return false }
        generation = UUID()
        let token = generation
        isChoosing = true; isPreparing = false; isAwaitingSourceIdentity = false; actionError = nil
        defer { if generation == token { isChoosing = false } }
        do {
            let result = try await Self.withBudget(10) { try await repository.choose(candidate.reference, key: key, input: input) }
            guard generation == token, !Task.isCancelled else { return false }
            apply(result); originalRequested = false; usesUnifiedLayout = true
            if entryManaged { logEntry("manual-choice") }
            isChoosing = false
            return true
        } catch {
            guard generation == token, !Task.isCancelled else { return false }
            isChoosing = false
            actionError = L10n.string("tmdb.choice.failed", fallback: "Unable to load or save this match. Try again later.")
            return false
        }
    }

    func useOriginal() async {
        guard let repository, let key, let input else { return }
        generation = UUID(); seasonGeneration = UUID(); searchGeneration = UUID()
        isSearching = false; isChoosing = false
        seasonTask?.cancel(); seasonTask = nil; seasonRequestSource = nil
        for task in entryTasks { task.cancel() }; entryTasks = []
        selection = nil; season = nil; candidates = []; originalRequested = true
        pageMode = .source; usesUnifiedLayout = false; isPreparing = false; isAwaitingSourceIdentity = false
        if entryManaged { logEntry("user-original") }
        do { try await repository.useOriginal(key: key, input: input) }
        catch { actionError = L10n.string("tmdb.choice.failed", fallback: "Unable to load or save this match. Try again later.") }
    }

    func selectSeason(_ number: Int?, source: PlaySource?) async {
        guard let repository, let key, let input, let source else { return }
        let token = generation
        do {
            let saved = try await repository.selectSeason(number, sourceID: source.stableIdentity, key: key, input: input, policy: matchPolicy)
            guard token == generation, !Task.isCancelled else { return }
            binding = saved
        } catch { actionError = L10n.string("tmdb.choice.failed", fallback: "Unable to load or save this match. Try again later.") }
    }

    func suspendNetworkRequests() {
        networkRequestsSuspended = true
        cancel(preservingPresentation: true)
    }

    func cancel(preservingPresentation: Bool = false) {
        if !preservingPresentation {
            mappingSourceIdentities.removeAll()
            invalidateEpisodeMapping()
        }
        seasonTask?.cancel(); seasonTask = nil; seasonRequestSource = nil
        for task in entryTasks { task.cancel() }; entryTasks = []
        generation = UUID(); searchGeneration = UUID(); seasonGeneration = UUID()
        isSearching = false; isChoosing = false; isPreparing = false; isLoadingSeason = false
        isAwaitingSourceIdentity = false; resolutionGeneration = UUID()
    }

    func imageURL(_ path: String?, kind: TMDBImageKind) -> URL? {
        let fallback: String
        switch kind {
        case .backdrop: fallback = "w1280"
        case .poster, .logo: fallback = "w500"
        case .still: fallback = "w300"
        case .profile: fallback = "w185"
        }
        return TMDBClient.imageURL(path: path, size: imageConfiguration?.size(for: kind) ?? fallback)
    }

    func artwork(_ kind: TMDBImageKind) -> URL? {
        guard let work = selection?.work else { return nil }
        if kind == .backdrop { return TMDBClient.imageURL(path: work.artworkPath(kind), size: "w1280") }
        return imageURL(work.artworkPath(kind), kind: kind)
    }

    private var displayedHeroURL: URL?
    private var displayedEpisodeArtwork = false
    func didDisplayEpisodeArtwork(_ url: URL) {
        guard selection?.reference.type == .tv, !displayedEpisodeArtwork else { return }
        displayedEpisodeArtwork = true; logEntry("first-episode-artwork-ready")
    }
    func didDisplayHero(_ url: URL) {
        guard url == artwork(.backdrop), displayedHeroURL != url else { return }
        displayedHeroURL = url; logEntry("artwork-ready")
    }

    private func apply(_ result: TMDBResolution) {
        selectionIsPreview = false
        switch result {
        case .matched(let candidate, let saved):
            if selection?.reference != candidate.reference { season = nil; loadedSeasons = [:] }
            selection = candidate; binding = saved; candidates = []; originalRequested = false; pageMode = .enhanced
            prepareKnownSeason()
        case .candidates(let values):
            selection = nil; binding = nil; season = nil; loadedSeasons = [:]; seasonGeneration = UUID(); pageMode = .source
            candidates = values
        case .original: selection = nil; binding = nil; season = nil; loadedSeasons = [:]; seasonGeneration = UUID(); pageMode = .source
        }
    }

    private static func withBudget<Value: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}


extension Notification.Name {
    static let tmdbSessionWillChange = Notification.Name("OKVideoMac.TMDB.sessionWillChange")
    static let tmdbSessionDidChange = Notification.Name("OKVideoMac.TMDB.sessionDidChange")
}

protocol TMDBCredentialStoring: Sendable {
    func load() async throws -> TMDBCredential?
    func save(_ value: TMDBCredential) async throws
    func delete() async throws
}

struct TMDBKeychainError: Error { let status: OSStatus }
struct KeychainTMDBCredentialStore: TMDBCredentialStoring {
    let service: String
    init(service: String = "com.okvideomac.OKVideoMac.tmdb.direct.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "TMDB", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> TMDBCredential? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TMDBKeychainError(status: status) }
        guard let data = result as? Data else { throw TMDBError.invalidCredential }
        return try TMDBCredential(keychainData: data)
    }
    func save(_ value: TMDBCredential) throws {
        let data = try value.keychainData()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TMDBKeychainError(status: status) }
        var attributes = query; attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "OKVideoMac TMDB credential"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw TMDBKeychainError(status: added) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TMDBKeychainError(status: status) }
    }
}

@MainActor
final class TMDBNetworkRuntime: ObservableObject {
    static let shared: TMDBNetworkRuntime = {
#if DEBUG || OKVIDEO_PERFORMANCE_TEST
        // The hosted test App must never read the customer's production key.
        if AppEnvironment.isXCTestHost(environment: ProcessInfo.processInfo.environment) {
            return TMDBNetworkRuntime(credentials: TMDBTestCredentialStore())
        }
#endif
        return TMDBNetworkRuntime()
    }()
    let availability = TMDBAvailability()
    let client: TMDBClient
    let service: TMDBObservedService
    private(set) var prober: TMDBLinkProber
    @Published private(set) var credentialKind: TMDBCredential.Kind?
    @Published private(set) var preference: TMDBPresentationPreference
    @Published private(set) var isChangingNetwork = false
    private var networkRevision = UUID()
    private var warmTask: Task<Void, Never>?
    private var networkChangeTask: Task<Void, Never>?
    private var minimumLinkGeneration = 0
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var canCancelOperation = false
    @Published private(set) var isLoadingCredential = true
    private var credentialLoadTask: Task<Void, Never>?
    private var linksTask: Task<Void, Never>?
    private var linksExpiryTask: Task<Void, Never>?
    @Published private(set) var message: String?
    @Published private(set) var links: TMDBAvailabilitySnapshot?
    private var credential: TMDBCredential?
    private let credentials: TMDBCredentialStoring
    private let defaults: UserDefaults
    private let transport: HTTPClient
    private final class RepositoryReference { weak var value: TMDBRepository?; init(_ value: TMDBRepository) { self.value = value } }
    private var repositories: [RepositoryReference] = []
    private let monitor = NWPathMonitor()
    private var store: SCDynamicStore?
    private var sawPath = false
    private var configured = false
    init(credentials: TMDBCredentialStoring? = nil, defaults: UserDefaults = .standard,
         transport: HTTPClient = URLSessionHTTPClient.isolatedEphemeral(reusesBoundedConnections: true)) {
        let credentials = credentials ?? KeychainTMDBCredentialStore()
        self.credentials = credentials; self.defaults = defaults; self.transport = transport
        preference = TMDBPresentationPreference.load(defaults: defaults)
        let isEnabled = defaults.object(forKey: "tmdb.direct.enabled") as? Bool != false
        enabled = isEnabled
        // Security.framework may wait for the user. Explicit detached work
        // also covers synchronous witnesses of the async storage protocol.
        let client = TMDBClient(credential: nil, httpClient: transport)
        self.client = client
        service = TMDBObservedService(base: client, availability: availability)
        prober = TMDBLinkProber(availability: availability, metadata: client, images: transport)
        let availability = self.availability
        linksTask = Task { [weak self] in
            for await snapshot in await availability.updates() {
                guard let self, !Task.isCancelled else { break }
                if !self.isChangingNetwork, snapshot.generation >= self.minimumLinkGeneration { self.acceptLinks(snapshot) }
            }
        }
        busy = true
        credentialLoadTask = Task { [weak self] in
            guard let self else { return }
            await availability.setMetadataRequestsEnabled(false)
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    try await credentials.load()
                }.value
                self.credential = saved; self.credentialKind = saved?.kind
                await client.updateCredential(self.enabled ? saved : nil)
                await availability.setMetadataRequestsEnabled(self.enabled && saved != nil && self.preference == .automatic)
            } catch {
                self.message = Self.text("keychain-error", "Unable to access the credential in Keychain. Try saving it again.")
            }
            self.busy = false
            self.isLoadingCredential = false
            self.credentialLoadTask = nil
            if self.configured { self.warm() }
        }
    }
    deinit { linksTask?.cancel(); linksExpiryTask?.cancel(); credentialLoadTask?.cancel(); warmTask?.cancel(); networkChangeTask?.cancel(); monitor.cancel() }
    private func acceptLinks(_ snapshot: TMDBAvailabilitySnapshot) {
        links = snapshot
        linksExpiryTask?.cancel(); linksExpiryTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard let expiry = [snapshot.metadata, snapshot.images]
            .filter({ $0.state == .available && $0.validUntil > now }).map(\.validUntil).min() else { return }
        let revision = networkRevision
        linksExpiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(3600, max(0.001, expiry - now)) * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.networkRevision == revision else { return }
            let fresh = await self.availability.snapshot()
            guard !Task.isCancelled, self.networkRevision == revision else { return }
            self.acceptLinks(fresh)
        }
    }
    func prepare() async { await credentialLoadTask?.value }
    private static func text(_ key: String, _ fallback: String) -> String { L10n.string("tmdb.direct." + key, fallback: fallback) }
    func register(_ repository: TMDBRepository) {
        repositories.removeAll { $0.value == nil }
        repositories.append(RepositoryReference(repository))
    }
    func configure(images: HTTPClient) {
        guard !configured else { return }; configured = true
        prober = TMDBLinkProber(availability: availability, metadata: client, images: images)
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.sawPath { self.changed() } else { self.sawPath = true }
            }
        }
        monitor.start(queue: DispatchQueue(label: "OKVideoMac.TMDB.network"))
        store = SCDynamicStoreCreate(nil, "OKVideoMac.TMDB" as CFString, { _, _, _ in
            Task { @MainActor in TMDBNetworkRuntime.shared.changed() }
        }, nil)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/Proxies"] as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
        }
        warm()
    }
    @discardableResult private func replaceSession() async -> Bool {
        invalidateNetworkPresentation()
        let revision = networkRevision
        NotificationCenter.default.post(name: .tmdbSessionWillChange, object: self)
        await availability.setMetadataRequestsEnabled(false)
        await client.updateCredential(nil)
        for repository in repositories.compactMap(\.value) { await repository.resetNetworkSession() }
        await client.updateCredential(enabled ? credential : nil)
        await availability.networkChanged()
        await availability.setMetadataRequestsEnabled(enabled && credential != nil && preference == .automatic)
        let snapshot = await availability.snapshot()
        guard revision == networkRevision else { return false }
        minimumLinkGeneration = snapshot.generation
        links = snapshot; isChangingNetwork = false
        NotificationCenter.default.post(name: .tmdbSessionDidChange, object: self)
        return true
    }
    @discardableResult func validateAndSave(kind: TMDBCredential.Kind, value: String) async -> Bool {
        await prepare()
        guard !busy, !Task.isCancelled else { return false }; busy = true; canCancelOperation = true; message = nil
        defer { busy = false; canCancelOperation = false }
        do {
            let candidate = try TMDBCredential(kind: kind, value: value)
            let health = await availability.snapshot().metadata
            if health.failure == .rateLimited, health.state == .unavailable {
                message = Self.text("rate-limit", "TMDB is limiting requests. Wait before trying again.")
                return false
            }
            let validatedRoute = networkRevision
            let networkDeadline = ProcessInfo.processInfo.systemUptime + 15
            let checker = TMDBClient(credential: candidate, httpClient: transport, timeout: 6)
            _ = try await checker.imageConfiguration()
            try Task.checkCancellation()
            // Do not replace a working in-memory session if Keychain persistence fails.
            canCancelOperation = false
            let storage = credentials
            try await Task.detached(priority: .userInitiated) {
                try await storage.save(candidate)
            }.value
            credential = candidate; credentialKind = candidate.kind
            enabled = true; defaults.set(true, forKey: "tmdb.direct.enabled")
            let sameRoute = validatedRoute == networkRevision
            let replaced = await replaceSession()
            if sameRoute && replaced { await availability.finish(availability.ticket(.metadata), outcome: .success) }
            links = await availability.snapshot()
            message = Self.text("saved-checking-images", "Credential saved. Checking the image connection…")
            // Saving is committed; cancellation now only stops the link check.
            canCancelOperation = true
            await runConnectionCheck(force: false, credentialSaved: true, deadline: networkDeadline)
            return true
        } catch {
            if TMDBLinkOutcome.error(error) == .cancelled {
                message = L10n.string("settings.operation.cancelled", fallback: "Cancelled; previous data kept")
                return false
            }
            if case .failure(.rateLimited, let delay) = TMDBLinkOutcome.error(error) {
                await availability.finish(availability.ticket(.metadata), outcome: .failure(.rateLimited, retryAfter: delay))
            }
            message = Self.failureMessage(error)
            return false
        }
    }
    func deleteCredential() async {
        await prepare()
        guard !busy, !Task.isCancelled else { return }; busy = true; defer { busy = false }
        do {
            let storage = credentials
            try await Task.detached(priority: .userInitiated) {
                try await storage.delete()
            }.value
            credential = nil; credentialKind = nil
            await replaceSession()
            message = Self.text("deleted", "Credential removed. Available cached information and source playback remain usable.")
        } catch { message = Self.failureMessage(error) }
    }
    func setEnabled(_ value: Bool) async {
        await prepare()
        guard !busy, !Task.isCancelled, enabled != value else { return }; busy = true; defer { busy = false }
        enabled = value; defaults.set(value, forKey: "tmdb.direct.enabled")
        await replaceSession(); message = nil
        if value { busy = false; warm() }
    }
    var presentationDecision: TMDBPresentationDecision {
        if preference == .automatic, enabled, credential != nil, !isLoadingCredential, busy || isChangingNetwork { return .checking }
        return .evaluate(preference: preference, enabled: enabled, loadingCredential: isLoadingCredential,
                  hasCredential: credential != nil, links: isChangingNetwork || busy ? nil : links)
    }

    /// Snapshot evaluation is synchronous so opening source details never waits
    /// for Keychain or network. Policy also checks the evidence expiry timestamp.
    func decisionForEntry() -> TMDBPresentationDecision {
        let decision = presentationDecision
        warm()
        return decision
    }

    func setPreference(_ value: TMDBPresentationPreference) {
        guard preference != value else { return }
        preference = value; defaults.set(value.rawValue, forKey: TMDBPresentationPreference.key)
        // Both directions update the observed-request permission before probing.
        changed()
    }

    func checkConnections() async {
        await prepare()
        // A network transition is short asynchronous work. Accept the user's
        // check now; runConnectionCheck joins it before issuing new probes.
        guard !busy, !Task.isCancelled else { return }
        guard enabled, credential != nil else {
            message = Self.text("missing", "Enable the service and save your TMDB credential first."); return
        }
        busy = true; canCancelOperation = true; message = nil
        defer { busy = false; canCancelOperation = false }
        await runConnectionCheck(force: true, credentialSaved: false)
    }

    private func runConnectionCheck(force: Bool, credentialSaved: Bool,
                                    deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 15) async {
        await networkChangeTask?.value
        guard !Task.isCancelled else {
            message = credentialSaved
                ? Self.text("saved-check-cancelled", "Credential saved. Connection check cancelled; source details remain available.")
                : Self.text("check-cancelled", "Connection check cancelled.")
            return
        }
        guard !isChangingNetwork else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            message = Self.text("check-timeout", "The connection check timed out. Try again later."); return
        }
        let revision = networkRevision
        await prober.warm(force: force)
        repeat {
            guard revision == networkRevision else {
                message = Self.text("check-route-changed", "Network changed. The connection will be checked again."); return
            }
            links = await availability.snapshot()
            if links?.metadata.checking != true && links?.images.checking != true { break }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        } while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
        guard revision == networkRevision else { return }
        if Task.isCancelled {
            await availability.cancelProbes(); links = await availability.snapshot()
            message = credentialSaved
                ? Self.text("saved-check-cancelled", "Credential saved. Connection check cancelled; source details remain available.")
                : Self.text("check-cancelled", "Connection check cancelled.")
        } else if links?.metadata.checking == true || links?.images.checking == true {
            await availability.cancelProbes(); links = await availability.snapshot()
            message = Self.text("check-timeout", "The connection check timed out. Try again later.")
        } else if links?.ready == true {
            message = Self.text("check-ready", "API and images connected. Automatic mode will use TMDB on the next detail page.")
        } else {
            message = credentialSaved
                ? Self.text("saved-links-unavailable", "Credential saved, but the connection is not ready. Automatic mode will keep using source details.")
                : Self.text("check-unavailable", "The connection is not ready. Automatic mode will keep using source details.")
        }
    }

    func warm() {
        guard !Task.isCancelled, !busy, !isChangingNetwork, enabled, credential != nil, preference == .automatic, warmTask == nil else { return }
        let revision = networkRevision
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.networkRevision == revision { self.warmTask = nil } }
            guard !Task.isCancelled, self.networkRevision == revision,
                  self.enabled, self.preference == .automatic else { return }
            await self.prober.warm()
        }
    }

    private func invalidateNetworkPresentation() {
        networkRevision = UUID(); links = nil; isChangingNetwork = true
        linksExpiryTask?.cancel(); linksExpiryTask = nil
        warmTask?.cancel(); warmTask = nil
        networkChangeTask?.cancel(); networkChangeTask = nil
    }

    func changed() {
        invalidateNetworkPresentation()
        let revision = networkRevision
        NotificationCenter.default.post(name: .tmdbSessionWillChange, object: self)
        networkChangeTask = Task { [weak self] in
            guard let self else { return }
            await self.availability.setMetadataRequestsEnabled(self.enabled && self.credential != nil && self.preference == .automatic)
            await self.availability.networkChanged()
            for repository in self.repositories.compactMap(\.value) { await repository.resetNetworkSession() }
            guard !Task.isCancelled, self.networkRevision == revision else { return }
            let snapshot = await self.availability.snapshot()
            guard !Task.isCancelled, self.networkRevision == revision else { return }
            self.minimumLinkGeneration = snapshot.generation
            self.links = snapshot; self.isChangingNetwork = false
            self.warm()
        }
    }
    private static func failureMessage(_ error: Error) -> String {
        if error is TMDBKeychainError { return text("keychain-error", "Unable to access the credential in Keychain. Try saving it again.") }
        if error as? TMDBError == .invalidCredential { return text("invalid-format", "Paste only the API Read Access Token or API Key, without a Bearer prefix or URL.") }
        switch TMDBLinkOutcome.error(error) {
        case .failure(.configuration, _): return text("auth-error", "TMDB rejected this credential. Check that it is valid and active.")
        case .failure(.network, _): return text("network-error", "Unable to connect to TMDB. Check your network and try again; the existing credential is unchanged.")
        case .failure(.rateLimited, _): return text("rate-limit", "TMDB is limiting requests. Wait before trying again.")
        case .failure(.server, _): return text("server-error", "TMDB is temporarily unavailable. Try again later.")
        default: return text("response-error", "TMDB returned an unexpected response. The credential was not saved.")
        }
    }
}

struct TMDBPersonOpenKey: EnvironmentKey {
    static let defaultValue: (TMDBPerson, VideoSummary) -> Void = { _, _ in }
}
extension EnvironmentValues {
    var tmdbOpenPerson: (TMDBPerson, VideoSummary) -> Void {
        get { self[TMDBPersonOpenKey.self] }
        set { self[TMDBPersonOpenKey.self] = newValue }
    }
}

@MainActor final class TMDBRelatedPage: ObservableObject, Identifiable {
    enum Kind { case person, search, detail }
    let id = UUID()
    let kind: Kind
    let title: String
    let source: VideoSummary
    let configurationID: UUID
    let person: TMDBPerson?
    let candidate: TMDBCandidate?
    let metadata = TMDBDetailModel()
    @Published var works: [TMDBCandidate] = []
    @Published var results: [VideoSummary] = []
    @Published var detail: VideoDetail?
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter = "all"
    @Published var displayedCount = 48
    @Published var revision: UInt64 = 0
    var anchor: PosterBrowseAnchor?
    var nextPage = 1
    var hasMore = false
    var searchGeneration = UUID()
    var searchPaging = SearchPagingState()
    var maximumRetained = Int.max
    var maximumPerSite = Int.max
    @Published var totalSites = 0
    @Published var completedSites = 0
    var task: Task<Void, Never>?
    init(kind: Kind, title: String, source: VideoSummary, configurationID: UUID, person: TMDBPerson? = nil, candidate: TMDBCandidate? = nil) {
        self.kind = kind; self.title = title; self.source = source; self.configurationID = configurationID; self.person = person; self.candidate = candidate
    }
    var filteredWorks: [TMDBCandidate] { works.filter { filter == "all" || $0.reference.type.rawValue == filter } }
    var items: [VideoSummary] {
        if kind != .person { return results }
        return filteredWorks.prefix(displayedCount).map { candidate in
            .init(siteKey: "tmdb-person", siteName: "TMDB", videoID: candidate.id, title: candidate.work.displayTitle,
                posterURL: TMDBClient.imageURL(path: candidate.work.posterPath, size: "w500"),
                remarks: candidate.reference.type == .movie ? L10n.string("tmdb.person.movies", fallback: "Movies") : L10n.string("tmdb.person.tv", fallback: "TV Shows"),
                year: candidate.work.year.map(String.init))
        }
    }
    deinit { task?.cancel() }
}

@MainActor final class TMDBRelatedBrowser: ObservableObject {
    @Published var pages: [TMDBRelatedPage] = []
    func open(person: TMDBPerson, source: VideoSummary, state: AppState) {
        guard let configuration = state.activeConfigurationRecord?.id else { return }
        let page = TMDBRelatedPage(kind: .person, title: person.name, source: source, configurationID: configuration, person: person)
        pages.append(page); load(page, state: state)
    }
    func select(_ item: VideoSummary, page: TMDBRelatedPage, state: AppState) {
        guard page.kind != .detail else { return }
        if page.kind == .person {
            guard let work = page.filteredWorks.first(where: { $0.id == item.videoID }) else { return }
            let search = TMDBRelatedPage(kind: .search, title: work.work.displayTitle, source: page.source, configurationID: page.configurationID, candidate: work)
            pages.append(search); load(search, state: state)
        } else {
            let detail = TMDBRelatedPage(kind: .detail, title: item.title, source: item, configurationID: page.configurationID)
            pages.append(detail); load(detail, state: state)
        }
    }
    func pop() { guard let page = pages.popLast() else { return }; page.task?.cancel(); page.metadata.cancel() }
    func clear() { for page in pages { page.task?.cancel(); page.metadata.cancel() }; pages = [] }
    func load(_ page: TMDBRelatedPage, state: AppState, refresh: Bool = false) {
        page.task?.cancel(); page.searchGeneration = UUID(); page.isLoading = true; page.error = nil
        page.task = Task { [weak page, weak state] in
            guard let page, let state else { return }
            defer { if !Task.isCancelled { page.isLoading = false } }
            do {
                guard state.activeConfigurationRecord?.id == page.configurationID else { throw CancellationError() }
                switch page.kind {
                case .person:
                    guard let repository = state.tmdbRepository, let person = page.person else { throw TMDBError.invalidInput }
                    if page.works.isEmpty, let cached = await repository.cachedPersonWorks(id: person.id) { page.works = cached }
                    let values = try await repository.personWorks(id: person.id, refresh: refresh)
                    try Task.checkCancellation(); page.works = values
                case .search:
                    try await state.searchRelatedWork(page, refresh: refresh)
                case .detail:
                    let decision = state.tmdbRuntime.decisionForEntry()
                    let detail = try await state.loadRelatedWork(page.source, configurationID: page.configurationID)
                    try Task.checkCancellation(); page.detail = detail
                    if !refresh || !page.metadata.hasStartedEntry {
                        page.metadata.beginEntry(repository: state.tmdbRepository, key: state.relatedTMDBKey(for: detail), summary: detail.summary,
                            availability: state.tmdbRuntime.availability,
                            enabled: decision.usesTMDB && state.tmdbRuntime.presentationDecision.usesTMDB,
                            policy: TMDBMatchingPreferences.policy())
                    }
                    page.metadata.receive(detail: detail, key: state.relatedTMDBKey(for: detail))
                }
                page.revision &+= 1
            } catch {
                if !Task.isCancelled { page.error = L10n.string("tmdb.person.failed", fallback: "Unable to load this page. Try again.") }
            }
        }
    }
    func loadMore(_ page: TMDBRelatedPage, state: AppState) async -> Bool {
        if page.kind == .person { page.displayedCount += 48; return true }
        guard !page.isLoading, page.hasMore else { return false }
        load(page, state: state); await page.task?.value; return page.error == nil
    }
}

/// Scoped to one detail view. Token refreshes invalidate the source value;
/// SwiftUI redraws and episode selection reuse the already-normalized identity.
@MainActor final class TMDBSourceIdentityCache: ObservableObject {
    private var values: [String: (PlaySource, String)] = [:]
    private(set) var computationCount = 0
    func removeAll() { values.removeAll() }
    func identity(_ source: PlaySource) -> String {
        if let entry = values[source.id], entry.0 == source { return entry.1 }
        let value = source.stableIdentity
        values[source.id] = (source, value); computationCount += 1
        return value
    }
}

#if DEBUG || OKVIDEO_PERFORMANCE_TEST
@MainActor private final class TMDBTestCredentialStore: TMDBCredentialStoring {
    private var value: TMDBCredential?
    func load() throws -> TMDBCredential? { value }
    func save(_ value: TMDBCredential) throws { self.value = value }
    func delete() throws { value = nil }
}
#endif
