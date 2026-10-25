import CryptoKit
import Foundation

public struct TMDBBinding: Codable, Equatable, Sendable {
    public var reference: TMDBReference?
    public let fingerprint: String
    public var manual: Bool
    public var disabled: Bool
    public var seasons: [String: Int]
    public var identity: TMDBIdentitySnapshot? = nil
    public var revision: Int? = nil
    public var automaticPolicy: TMDBMatchPolicy? = nil
    public var relaxedUntil: Date? = nil
    public var isRelaxed: Bool { !manual && automaticPolicy == .relaxed }
}

public enum TMDBResolution: Equatable, Sendable {
    case matched(TMDBCandidate, TMDBBinding)
    case candidates([TMDBCandidate])
    case original
}

/// Small metadata-only cache, independent of expiring provider detail/URLs.
/// The caller supplies a hashed source namespace; no source credentials persist.
public actor TMDBRepository {
    private struct Cached<Value: Codable>: Codable {
        let value: Value
        let expires: Date
    }
    private struct DiskState: Codable {
        var schemaVersion: Int? = 3
        var bindings: [String: TMDBBinding] = [:]
        var works: [String: Cached<TMDBWork>] = [:]
        var seasons: [String: Cached<TMDBSeason>] = [:]
        var configuration: Cached<TMDBImageConfiguration>?
        var personIdentities: [String: Cached<TMDBPersonIdentity>]? = [:]
        var people: [String: Cached<[TMDBCandidate]>]? = [:]
    }
    private let client: TMDBServing
    private let file: URL?
    private let now: () -> Date
    private let prefetchArtwork: (@Sendable (TMDBWork) async -> Void)?
    private var disk = DiskState()
    private var revisions: [String: Int] = [:]
    private var activeInputs: [String: TMDBMatchInput] = [:]
    private var activePolicies: [String: TMDBMatchPolicy] = [:]
    private var misses: [String: Date] = [:]
    private var searches: [String: Cached<TMDBSearchPage>] = [:]
    private var searchTasks: [String: Task<TMDBSearchPage, Error>] = [:]
    private var workTasks: [String: Task<TMDBWork, Error>] = [:]
    private var seasonTasks: [String: Task<TMDBSeason, Error>] = [:]
    private var identityTasks: [Int: Task<TMDBPersonIdentity, Error>] = [:]
    private var personTasks: [Int: Task<[TMDBCandidate], Error>] = [:]
    private var configurationTask: Task<TMDBImageConfiguration, Error>?
    private var offlineUntil = Date.distantPast
    private var preparations: [String: (id: UUID, input: TMDBMatchInput, policy: TMDBMatchPolicy, persistBinding: Bool, task: Task<TMDBResolution, Error>)] = [:]
    private var activePreparations = 0
    private var resettingNetwork = false
    private var networkGeneration = 0
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    /// Drain the old credential session before admitting work for the new one.
    /// Verified payloads and user choices remain available; transient misses do not.
    public func resetNetworkSession() async {
        guard !resettingNetwork else { return }
        resettingNetwork = true
        networkGeneration += 1
        defer { resettingNetwork = false }
        for key in revisions.keys { revisions[key, default: 0] += 1 }
        let preparations = Array(self.preparations.values.map(\.task))
        let prefetches = Array(prefetchTasks.values)
        let searches = Array(searchTasks.values), works = Array(workTasks.values)
        let seasons = Array(seasonTasks.values), identities = Array(identityTasks.values)
        let people = Array(personTasks.values), configuration = configurationTask
        preparations.forEach { $0.cancel() }; prefetches.forEach { $0.cancel() }
        searches.forEach { $0.cancel() }; works.forEach { $0.cancel() }; seasons.forEach { $0.cancel() }
        identities.forEach { $0.cancel() }; people.forEach { $0.cancel() }; configuration?.cancel()
        for task in preparations { _ = await task.result }
        for task in prefetches { await task.value }
        for task in searches { _ = await task.result }
        for task in works { _ = await task.result }
        for task in seasons { _ = await task.result }
        for task in identities { _ = await task.result }
        for task in people { _ = await task.result }
        if let configuration { _ = await configuration.result }
        self.preparations.removeAll(); prefetchTasks.removeAll(); searchTasks.removeAll(); workTasks.removeAll()
        seasonTasks.removeAll(); identityTasks.removeAll(); personTasks.removeAll(); configurationTask = nil
        misses.removeAll(); self.searches.removeAll(); offlineUntil = .distantPast
    }
    private func checkSession() throws {
        try Task.checkCancellation()
        guard !resettingNetwork else { throw CancellationError() }
    }

    /// Own work independently from a view's lifetime. Re-entry joins the same
    /// bounded job; source identities are still verified separately.
    public func prepare(key: String, input: TMDBMatchInput, timeout: TimeInterval = 15, persistBinding: Bool = true, policy: TMDBMatchPolicy = .strict) async throws -> TMDBResolution {
        try checkSession()
        try Task.checkCancellation()
        // Role/order changes in credits are identity evidence too. A summary
        // preview cannot satisfy a request to verify and save provider detail.
        if let current = preparations[key], current.input == input, current.policy == policy, current.persistBinding == persistBinding {
            return try await current.task.value
        }
        preparations[key]?.task.cancel()
        let id = UUID()
        let budget = TMDBRequestBudget(deadline: ProcessInfo.processInfo.systemUptime + max(0.01, timeout))
        let task = Task { try await self.performPreparation(key: key, input: input, budget: budget, persistBinding: persistBinding, policy: policy) }
        preparations[key] = (id, input, policy, persistBinding, task)
        defer { if preparations[key]?.id == id { preparations[key] = nil } }
        return try await task.value
    }

    private func performPreparation(key: String, input: TMDBMatchInput, budget: TMDBRequestBudget, persistBinding: Bool, policy: TMDBMatchPolicy) async throws -> TMDBResolution {
        while activePreparations >= 2 {
            guard ProcessInfo.processInfo.systemUptime < budget.deadline else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        activePreparations += 1
        defer { activePreparations -= 1 }
        return try await budget.perform {
            try await self.resolve(key: key, input: input, deadline: budget.deadline, budget: budget, persistBinding: persistBinding, policy: policy)
        }
    }

    /// Discovery prefers exact titles, then warms at most two alias candidates; never a source
    /// binding. The full rival pool remains intact for the strict final match.
    /// Own the bounded job across search-result updates and page transitions.
    public func prefetch(input: TMDBMatchInput) async {
        guard !resettingNetwork, !Task.isCancelled, !input.hasConflict, let name = input.searchNames.first else { return }
        let key = Self.fingerprint(input)
        if let task = prefetchTasks[key] { await task.value; return }
        guard activePreparations == 0, prefetchTasks.isEmpty else { return }
        let task = Task { await self.prefetchCandidates(input: input, name: name) }
        prefetchTasks[key] = task
        await task.value
        prefetchTasks[key] = nil
    }

    private func prefetchCandidates(input: TMDBMatchInput, name: String) async {
        activePreparations += 1
        defer { activePreparations -= 1 }
        let budget = TMDBRequestBudget(deadline: ProcessInfo.processInfo.systemUptime + 8)
        guard let found = try? await search(query: name, type: input.type,
                                            year: input.type == .movie ? input.year : nil, budget: budget) else { return }
        let candidates = found.filter {
            let evidence = TMDBMatcher.assess($0, input: input)
            return !evidence.conflict
        }.sorted { TMDBMatcher.assess($0, input: input).rank > TMDBMatcher.assess($1, input: input).rank }
        let exact = candidates.filter { TMDBMatcher.assess($0, input: input).exactTitle }
        let warm = exact.isEmpty ? candidates : exact
        await withTaskGroup(of: Void.self) { group in
            for candidate in warm.prefix(2) {
                group.addTask {
                    guard let work = try? await self.detail(candidate.reference, budget: budget) else { return }
                    if let prefetchArtwork = self.prefetchArtwork {
                        _ = try? await budget.perform { await prefetchArtwork(work) }
                    }
                }
            }
        }
    }


    public init(client: TMDBServing = TMDBClient(), directory: URL? = nil, now: @escaping () -> Date = Date.init, prefetchArtwork: (@Sendable (TMDBWork) async -> Void)? = nil) {
        self.client = client; self.now = now; self.prefetchArtwork = prefetchArtwork
        file = directory?.appendingPathComponent("tmdb-v1.json")
        if let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(DiskState.self, from: data) {
            disk = saved
            if saved.schemaVersion != 3 {
                // Reverify automatic decisions made with filename evidence,
                // retaining reusable payloads and explicit user choices.
                disk.bindings = saved.bindings.filter { $0.value.manual }
                disk.schemaVersion = 3
            }
        }
    }

    public static func sourceKey(namespace: String, siteKey: String, videoID: String) -> String {
        digest([namespace, siteKey, videoID])
    }
    public static func fingerprint(_ input: TMDBMatchInput) -> String {
        digest([input.title, input.year.map(String.init) ?? "", input.type?.rawValue ?? "", input.people.sorted().joined(separator: "|"), input.season.map(String.init) ?? ""])
    }
    private static func digest(_ components: [String]) -> String {
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func binding(key: String, input: TMDBMatchInput, policy: TMDBMatchPolicy = .strict) -> TMDBBinding? {
        guard var binding = disk.bindings[key] else { return nil }
        if binding.isRelaxed {
            guard policy == .relaxed, let until = binding.relaxedUntil, until > now() else { return nil }
        }
        if let identity = binding.identity {
            guard identity.isCompatible(with: input) else { return nil }
        } else {
            // Legacy hashes cannot be reversed. Upgrade only an exact old identity.
            guard binding.fingerprint == Self.fingerprint(input) else { return nil }
            binding.identity = TMDBIdentitySnapshot(input)
            disk.bindings[key] = binding
            try? persist()
        }
        // A later provider response can add conflicting director/year/type
        // evidence. Never let an automatic cache bypass that evidence.
        if !binding.manual, let ref = binding.reference,
           let work = disk.works["\(ref.type.rawValue):\(ref.id)"]?.value,
           Self.rejectsCached(.init(reference: ref, work: work), input: input, relaxed: binding.isRelaxed) { return nil }
        return binding
    }

    private static func rejectsCached(_ candidate: TMDBCandidate, input: TMDBMatchInput, relaxed: Bool = false) -> Bool {
        if relaxed { return !TMDBMatcher.acceptsRelaxed(candidate, input: input) }
        let value = TMDBMatcher.assess(candidate, input: input)
        return value.conflict || (value.unresolvedDirector && !value.corroboratedCast)
    }

    public func cachedResolution(key: String, input: TMDBMatchInput, policy: TMDBMatchPolicy = .strict) -> TMDBResolution? {
        guard let binding = binding(key: key, input: input, policy: policy) else { return nil }
        if binding.disabled { return .original }
        guard let ref = binding.reference, let work = disk.works["\(ref.type.rawValue):\(ref.id)"]?.value,
              work.id == ref.id, !work.displayTitle.isEmpty else { return nil }
        return .matched(.init(reference: ref, work: work), binding)
    }

    public func resolve(key: String, input: TMDBMatchInput, deadline: TimeInterval = .infinity, budget: TMDBRequestBudget? = nil, persistBinding: Bool = true, policy: TMDBMatchPolicy = .strict) async throws -> TMDBResolution {
        try checkSession()
        try Task.checkCancellation()
        if let active = activeInputs[key], active != input || activePolicies[key] != policy { revisions[key, default: 0] += 1 }
        activeInputs[key] = input; activePolicies[key] = policy
        let revision = revisions[key, default: 0]
        if let binding = binding(key: key, input: input, policy: policy) {
            if binding.disabled { return .original }
            if let reference = binding.reference {
                let work = try await detail(reference, budget: budget)
                try ensureCurrent(key, revision)
                let raw = TMDBCandidate(reference: reference, work: work)
                let candidate = binding.manual || binding.isRelaxed ? raw : await corroboratePeople(raw, input: input, budget: budget)
                try ensureCurrent(key, revision)
                if binding.manual || !Self.rejectsCached(candidate, input: input, relaxed: binding.isRelaxed) {
                    return .matched(candidate, binding)
                }
            }
        }
        // A changed manual identity requires explicit review; never auto-overwrite it.
        if disk.bindings[key]?.manual == true { return .candidates([]) }
        if persistBinding, disk.bindings[key] != nil {
            disk.bindings[key] = nil
            try? persist()
        }
        guard !input.hasConflict else { return .candidates([]) }
        let evidenceKey = Self.digest([Self.fingerprint(input), input.directors.sorted().joined(separator: "|"),
            input.principalActors.joined(separator: "|"), input.yearHints.sorted().map(String.init).joined(separator: "|"),
            String(input.canInferTypeFromCast), input.season.map(String.init) ?? ""])
        let missKey = "v\(TMDBParsedTitle.version):" + policy.rawValue + key + evidenceKey
        if misses[missKey, default: .distantPast] > now() { return .original }
        try checkNetworkCooldown()
        var pool: [TMDBCandidate] = []
        var verified = Set<TMDBReference>()
        var searchedPages: [TMDBSearchPage] = []
        var selected: TMDBCandidate?
        var selectedPolicy = TMDBMatchPolicy.strict
        for name in input.searchNames.prefix(2) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CancellationError() }
            // A source's inaccurate type/year must not manufacture a unique result.
            let searchType = policy == .relaxed ? nil : input.type
            let page = try await searchPage(query: name, type: searchType, year: policy == .strict && input.type == .movie ? input.year : nil, budget: budget)
            searchedPages.append(page)
            var seen = Set(pool.map(\.reference))
            pool.append(contentsOf: Self.candidates(page, type: searchType).filter { seen.insert($0.reference).inserted })
            pool.sort { TMDBMatcher.assess($0, input: input).rank > TMDBMatcher.assess($1, input: input).rank }
            let eligible = pool.filter {
                let evidence = TMDBMatcher.assess($0, input: input)
                return !verified.contains($0.reference) && !evidence.identityConflict
                    && (evidence.matchingYear || input.year == nil || input.season != nil)
            }
            let exact = eligible.filter { TMDBMatcher.assess($0, input: input).exactTitle }
            let toVerify = exact.isEmpty ? eligible : exact
            // Independent candidate detail requests may overlap. Never prune
            // unexamined rivals from the pool to manufacture a unique result.
            // Validate raw response completeness before excluding people/deduplicating.
            // Malformed or unknown media entries cannot count as proof of uniqueness.
            let uniqueSearch = policy == .relaxed && searchedPages.count == min(2, input.searchNames.count)
                && searchedPages.allSatisfy { Self.completeFilmSearch($0) } && pool.count == 1
            let refreshed = try await withThrowingTaskGroup(of: TMDBCandidate.self) { group in
                for candidate in toVerify.prefix(min(input.searchNames.count > 1 && searchedPages.count == 1 ? 1 : 2, max(0, 2 - verified.count))) {
                    group.addTask {
                        let work = try await self.detail(candidate.reference, budget: budget)
                        let full = TMDBCandidate(reference: candidate.reference, work: work)
                        if uniqueSearch && TMDBMatcher.acceptsRelaxed(full, input: input) { return full }
                        return await self.corroboratePeople(full, input: input, budget: budget)
                    }
                }
                var values: [TMDBCandidate] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in refreshed {
                if let index = pool.firstIndex(where: { $0.reference == value.reference }) { pool[index] = value }
                verified.insert(value.reference)
            }
            try ensureCurrent(key, revision)
            let complete = searchedPages.allSatisfy { $0.isComplete != false }
            if complete, let winner = TMDBMatcher.automaticMatch(pool, input: input),
               verified.contains(winner.reference),
               (!TMDBMatcher.assess(winner, input: input).requiresCompleteSearch
                    || (searchedPages.count == min(2, input.searchNames.count) && searchedPages.allSatisfy { $0.isComplete == true })) {
                selected = winner; selectedPolicy = .strict
                if input.titleWithoutAttachedYear == nil { break }
            } else if uniqueSearch, let winner = pool.first, verified.contains(winner.reference),
                      TMDBMatcher.acceptsRelaxed(winner, input: input) {
                selected = winner; selectedPolicy = .relaxed
            } else { selected = nil }
            // A nonempty but rejected response must not suppress the original-name fallback.
        }
        try ensureCurrent(key, revision)
        if let selected {
            let binding = TMDBBinding(reference: selected.reference, fingerprint: Self.fingerprint(input), manual: false, disabled: false, seasons: [:], identity: .init(input), revision: revision, automaticPolicy: selectedPolicy, relaxedUntil: selectedPolicy == .relaxed ? now().addingTimeInterval(86400) : nil)
            if persistBinding { disk.bindings[key] = binding; try? persist() }
            return .matched(selected, binding)
        }
        if pool.isEmpty { misses[missKey] = now().addingTimeInterval(600); return .original }
        return .candidates(pool)
    }

    private func personIdentity(_ id: Int, budget: TMDBRequestBudget?) async throws -> TMDBPersonIdentity {
        try checkSession()
        let requestGeneration = networkGeneration
        let key = String(id)
        if let cached = disk.personIdentities?[key], cached.expires > now() { return cached.value }
        if let task = identityTasks[id] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        let task = Task { try await self.client.personIdentity(id: id) }
        identityTasks[id] = task
        defer { if requestGeneration == networkGeneration { identityTasks[id] = nil } }
        let value: TMDBPersonIdentity
        if let budget { value = try await budget.perform { try await task.value } }
        else { value = try await task.value }
        guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
        guard value.id == id else { throw TMDBError.invalidResponse }
        if disk.personIdentities == nil { disk.personIdentities = [:] }
        disk.personIdentities?[key] = Cached(value: value, expires: now().addingTimeInterval(7 * 86400))
        if let entries = disk.personIdentities, entries.count > 100 {
            disk.personIdentities = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.expires > $1.value.expires }.prefix(100).map { ($0.key, $0.value) })
        }
        try? persist()
        return value
    }

    private func corroboratePeople(_ candidate: TMDBCandidate, input: TMDBMatchInput, budget: TMDBRequestBudget?) async -> TMDBCandidate {
        let evidence = TMDBMatcher.assess(candidate, input: input)
        guard evidence.exactTitle, !evidence.identityConflict, !evidence.acceptsAutomatically else { return candidate }
        let requestGeneration = networkGeneration
        func names(_ person: TMDBPerson) -> Set<String> {
            Set(([person.name, person.originalName].compactMap { $0 } + (person.alsoKnownAs ?? [])).map(TMDBTitleNormalizer.key))
        }
        // Directors are independent evidence; an absent actor list must not skip
        // their verification. Bound both roles and deduplicate shared person IDs.
        var requested: [Int] = []
        if !input.directors.isEmpty && !evidence.corroboratedDirector {
            requested += candidate.work.directors.filter { names($0).isDisjoint(with: input.directors) }.prefix(2).map(\.id)
        }
        if input.principalActors.count >= 2 && !evidence.corroboratedCast {
            let principals = Set(input.principalActors)
            requested += candidate.work.cast.prefix(10).filter { names($0).isDisjoint(with: principals) }.prefix(3).map(\.id)
        }
        var seen = Set<Int>()
        requested = requested.filter { $0 > 0 && seen.insert($0).inserted }
        var identities: [Int: TMDBPersonIdentity] = [:]
        await withTaskGroup(of: TMDBPersonIdentity?.self) { group in
            for id in requested {
                group.addTask { try? await self.personIdentity(id, budget: budget) }
            }
            for await value in group { if let value { identities[value.id] = value } }
        }
        guard !identities.isEmpty, requestGeneration == networkGeneration,
              !resettingNetwork, !Task.isCancelled else { return candidate }
        var work = candidate.work
        func enriched(_ people: [TMDBPerson]?) -> [TMDBPerson]? {
            people?.map { person in
                var result = person
                if let identity = identities[person.id] {
                    result.alsoKnownAs = Array(Set((person.alsoKnownAs ?? []) + [identity.name] + (identity.alsoKnownAs ?? []))).sorted()
                }
                return result
            }
        }
        if var credits = work.credits {
            credits.cast = enriched(credits.cast); credits.crew = enriched(credits.crew); work.credits = credits
        }
        if var credits = work.aggregateCredits {
            credits.cast = enriched(credits.cast); credits.crew = enriched(credits.crew); work.aggregateCredits = credits
        }
        let cacheKey = "\(candidate.reference.type.rawValue):\(candidate.reference.id)"
        if let cached = disk.works[cacheKey] {
            disk.works[cacheKey] = Cached(value: work, expires: cached.expires)
            try? persist()
        }
        return .init(reference: candidate.reference, work: work)
    }

    private static func completeFilmSearch(_ page: TMDBSearchPage) -> Bool {
        page.isComplete == true && page.results.allSatisfy { work in
            work.id > 0 && (work.mediaType == "person" ||
                (work.mediaType.flatMap(TMDBMediaType.init(rawValue:)) != nil && !work.displayTitle.isEmpty))
        }
    }

    private static func candidates(_ page: TMDBSearchPage, type: TMDBMediaType?) -> [TMDBCandidate] {
        var seen = Set<TMDBReference>()
        return page.results.compactMap { work in
            guard work.id > 0, work.mediaType != "person", !work.displayTitle.isEmpty,
                  let kind = type ?? work.mediaType.flatMap(TMDBMediaType.init(rawValue:)) else { return nil }
            let reference = TMDBReference(type: kind, id: work.id)
            guard seen.insert(reference).inserted else { return nil }
            return .init(reference: reference, work: work)
        }
    }

    public func search(query: String, type: TMDBMediaType?, year: Int? = nil, budget: TMDBRequestBudget? = nil) async throws -> [TMDBCandidate] {
        try checkSession()
        return Self.candidates(try await searchPage(query: query, type: type, year: year, budget: budget), type: type)
    }

    private func searchPage(query: String, type: TMDBMediaType?, year: Int?, budget: TMDBRequestBudget?) async throws -> TMDBSearchPage {
        try checkSession()
        let requestGeneration = networkGeneration
        let key = Self.digest([query, type?.rawValue ?? "", year.map(String.init) ?? "", "zh-CN"])
        if let cached = searches[key], cached.expires > now() { return cached.value }
        if let task = searchTasks[key] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        try checkNetworkCooldown()
        try await budget?.admit(search: true)
        guard requestGeneration == networkGeneration else { throw CancellationError() }
        if let task = searchTasks[key] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        let client = self.client
        let task = Task<TMDBSearchPage, Error> {
            if let budget { return try await budget.perform { try await client.searchPage(query: query, type: type, year: year) } }
            return try await client.searchPage(query: query, type: type, year: year)
        }
        searchTasks[key] = task
        defer { if requestGeneration == networkGeneration { searchTasks[key] = nil } }
        do {
            let result = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            searches[key] = Cached(value: result, expires: now().addingTimeInterval(result.results.isEmpty ? 600 : 300))
            if searches.count > 64 { searches = Dictionary(uniqueKeysWithValues: searches.sorted { $0.value.expires > $1.value.expires }.prefix(64).map { ($0.key, $0.value) }) }
            return result
        } catch { recordFailure(error); throw error }
    }

    public func choose(_ reference: TMDBReference, key: String, input: TMDBMatchInput) async throws -> TMDBResolution {
        try checkSession()
        preparations[key]?.task.cancel()
        revisions[key, default: 0] += 1
        let revision = revisions[key, default: 0]
        let work = try await detail(reference)
        try ensureCurrent(key, revision)
        let binding = TMDBBinding(reference: reference, fingerprint: Self.fingerprint(input), manual: true, disabled: false, seasons: disk.bindings[key]?.reference == reference ? disk.bindings[key]?.seasons ?? [:] : [:], identity: .init(input), revision: revision)
        disk.bindings[key] = binding
        try persist()
        return .matched(.init(reference: reference, work: work), binding)
    }

    public func useOriginal(key: String, input: TMDBMatchInput) throws {
        preparations[key]?.task.cancel()
        revisions[key, default: 0] += 1
        // Viewing original details is session-only. Invalidate in-flight automatic
        // binding writes, retaining the user's work and per-line season identity.
    }

    public func selectSeason(_ number: Int?, sourceID: String, key: String, input: TMDBMatchInput, policy: TMDBMatchPolicy = .strict) throws -> TMDBBinding? {
        guard var binding = binding(key: key, input: input, policy: policy), !binding.disabled else { return nil }
        binding.seasons[sourceID] = number
        disk.bindings[key] = binding
        try persist()
        return binding
    }

    public func detail(_ reference: TMDBReference, budget: TMDBRequestBudget? = nil) async throws -> TMDBWork {
        try checkSession()
        let requestGeneration = networkGeneration
        let key = "\(reference.type.rawValue):\(reference.id)"
        if let cached = disk.works[key], cached.expires > now() { return cached.value }
        if let task = workTasks[key] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        try checkNetworkCooldown()
        try await budget?.admit(search: false)
        guard requestGeneration == networkGeneration else { throw CancellationError() }
        if let task = workTasks[key] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        let client = self.client
        let task = Task {
            if let budget { return try await budget.perform { try await client.detail(reference) } }
            return try await client.detail(reference)
        }
        workTasks[key] = task
        defer { if requestGeneration == networkGeneration { workTasks[key] = nil } }
        do {
            let work = try await task.value
        guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            disk.works[key] = Cached(value: compact(work), expires: now().addingTimeInterval(86400 * 7))
            try? persist()
            return work
        } catch { recordFailure(error); throw error }
    }

    public func cachedSeason(tvID: Int, number: Int) -> TMDBSeason? {
        disk.seasons["\(tvID):\(number)"]?.value
    }

    public func season(tvID: Int, number: Int, ongoing: Bool) async throws -> TMDBSeason {
        try checkSession()
        let requestGeneration = networkGeneration
        let key = "\(tvID):\(number)"
        if let cached = disk.seasons[key], cached.expires > now() { return cached.value }
        if let task = seasonTasks[key] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        try checkNetworkCooldown()
        let client = self.client
        let task = Task { try await client.season(tvID: tvID, number: number) }
        seasonTasks[key] = task
        defer { if requestGeneration == networkGeneration { seasonTasks[key] = nil } }
        do {
            let season = try await task.value
        guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            guard season.seasonNumber == number else { throw TMDBError.invalidInput }
            disk.seasons[key] = Cached(value: season, expires: now().addingTimeInterval(ongoing ? 21600 : 604800))
            try? persist()
            return season
        } catch { recordFailure(error); throw error }
    }

    public func cachedPersonWorks(id: Int) -> [TMDBCandidate]? { disk.people?[String(id)]?.value }
    public func personWorks(id: Int, refresh: Bool = false) async throws -> [TMDBCandidate] {
        try checkSession()
        let requestGeneration = networkGeneration
        guard id > 0 else { throw TMDBError.invalidInput }
        if !refresh, let cached = disk.people?[String(id)], cached.expires > now() { return cached.value }
        if let task = personTasks[id] {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        try checkNetworkCooldown()
        let client = self.client
        let task = Task { try await client.personCredits(id: id).works }
        personTasks[id] = task
        defer { if requestGeneration == networkGeneration { personTasks[id] = nil } }
        do {
            let values = try await task.value
        guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            if disk.people == nil { disk.people = [:] }
            disk.people?[String(id)] = Cached(value: values, expires: now().addingTimeInterval(86400))
            if let people = disk.people, people.count > 32 {
                disk.people = Dictionary(uniqueKeysWithValues: people.sorted { $0.value.expires > $1.value.expires }.prefix(32).map { ($0.key, $0.value) })
            }
            try? persist(); return values
        } catch { recordFailure(error); throw error }
    }

    public func imageConfiguration() async throws -> TMDBImageConfiguration {
        try checkSession()
        let requestGeneration = networkGeneration
        if let cached = disk.configuration, cached.expires > now() { return cached.value }
        if let task = configurationTask {
            let value = try await task.value
            guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
            return value
        }
        try checkNetworkCooldown()
        let client = self.client
        let task = Task { try await client.imageConfiguration() }
        configurationTask = task
        defer { if requestGeneration == networkGeneration { configurationTask = nil } }
        let configuration = try await task.value
        guard requestGeneration == networkGeneration, !task.isCancelled else { throw CancellationError() }
        disk.configuration = Cached(value: configuration, expires: now().addingTimeInterval(604800))
        try? persist()
        return configuration
    }

    private func ensureCurrent(_ key: String, _ revision: Int) throws {
        try Task.checkCancellation()
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
    }
    private func checkNetworkCooldown() throws {
        try checkSession()
        if !(client is TMDBObservedService), offlineUntil > now() { throw TMDBError.unavailable(0) }
    }
    private func recordFailure(_ error: Error) {
        if error is CancellationError { return }
        if let error = error as? HTTPClientError {
            if case .statusCode(let status) = error, status != 429 && status < 500 { return }
            if case .cancelled = error { return }
            offlineUntil = now().addingTimeInterval(60)
        }
    }
    private func compact(_ original: TMDBWork) -> TMDBWork {
        var work = original
        if var images = work.images {
            func retain(_ items: [TMDBArtwork]?, kind: TMDBImageKind) -> [TMDBArtwork]? {
                guard let items else { return nil }
                let selected = original.artworkPath(kind)
                // The image prefetched from the full response must survive
                // memory/disk compaction and remain the displayed selection.
                let chosen = items.first { $0.filePath == selected }
                return chosen.map { [$0] + Array(items.filter { $0.filePath != selected }.prefix(11)) } ?? Array(items.prefix(12))
            }
            images.backdrops = retain(images.backdrops, kind: .backdrop)
            images.posters = retain(images.posters, kind: .poster)
            images.logos = retain(images.logos, kind: .logo)
            work.images = images
        }
        if var credits = work.credits {
            credits.cast = credits.cast.map { Array($0.prefix(30)) }
            credits.crew = credits.crew.map { Array(($0.filter(\.isDirector) + $0.filter { !$0.isDirector }).prefix(40)) }
            work.credits = credits
        }
        if var credits = work.aggregateCredits {
            credits.cast = credits.cast.map { Array($0.prefix(30)) }
            credits.crew = credits.crew.map { Array(($0.filter(\.isDirector) + $0.filter { !$0.isDirector }).prefix(40)) }
            work.aggregateCredits = credits
        }
        if var translations = work.translations {
            translations.translations = translations.translations?.filter { ["zh", "en"].contains($0.iso6391 ?? "") }
            work.translations = translations
        }
        return work
    }
    private func persist() throws {
        disk.schemaVersion = 3
        if disk.works.count > 64 { disk.works = Dictionary(uniqueKeysWithValues: disk.works.sorted { $0.value.expires > $1.value.expires }.prefix(64).map { ($0.key, $0.value) }) }
        if disk.seasons.count > 64 { disk.seasons = Dictionary(uniqueKeysWithValues: disk.seasons.sorted { $0.value.expires > $1.value.expires }.prefix(64).map { ($0.key, $0.value) }) }
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(disk).write(to: file, options: .atomic)
    }
}
