import XCTest
@testable import OKVideoCore

final class TMDBRepositoryTests: XCTestCase {

    func testPersonAliasCorroborationIsBoundedAndReusedAcrossBindings() async throws {
        let service = TMDBAliasProbe(), directory = try directory()
        let input = TMDBMatchInput(detail: .init(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "翠鸟谋杀案", year: "2026"), actors: "莱丝利·曼维尔 蒂姆·迈克穆兰"))
        let repository = TMDBRepository(client: service, directory: directory)
        let result = try await repository.resolve(key: "a", input: input)
        guard case .matched(let work, _) = result else { return XCTFail("Verified alias should corroborate the second principal") }
        XCTAssertEqual(work.reference.id, 283319)
        let restored = TMDBRepository(client: service, directory: directory)
        let another = try await restored.resolve(key: "b", input: input)
        guard case .matched = another else { return XCTFail("Cached alias was lost") }
        let requests = await service.aliasRequests
        XCTAssertEqual(requests, [15740])
    }

    func testOldAutomaticBindingsAreReverifiedButManualChoicesSurviveMigration() async throws {
        let service = TMDBServiceProbe(), directory = try directory()
        let repository = TMDBRepository(client: service, directory: directory)
        let value = input()
        _ = try await repository.resolve(key: "automatic", input: value)
        _ = try await repository.choose(.init(type: .movie, id: 1), key: "manual", input: value)
        let file = directory.appendingPathComponent("tmdb-v1.json")
        var disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        disk["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: disk).write(to: file)
        let restored = TMDBRepository(client: service, directory: directory)
        let auto = await restored.cachedResolution(key: "automatic", input: value)
        let manual = await restored.binding(key: "manual", input: value)
        XCTAssertNil(auto)
        XCTAssertEqual(manual?.manual, true)
        let result = try await restored.resolve(key: "automatic", input: value)
        guard case .matched = result else { return XCTFail("Retained work cache should support revalidation") }
    }

    func testPrefetchedArtworkSurvivesMemoryAndDiskCompaction() async throws {
        let service = TMDBArtworkRetentionProbe(), directory = try directory()
        let store = TMDBRepository(client: service, directory: directory)
        let full = try await store.detail(.init(type: .movie, id: 1))
        let memory = try await store.detail(.init(type: .movie, id: 1))
        let reopened = TMDBRepository(client: service, directory: directory)
        let disk = try await reopened.detail(.init(type: .movie, id: 1))
        for work in [full, memory, disk] {
            XCTAssertEqual(work.artworkPath(.backdrop), "/13.jpg")
            XCTAssertEqual(work.artworkPath(.poster), "/13.jpg")
            XCTAssertEqual(work.artworkPath(.logo), "/13.jpg")
        }
        XCTAssertEqual(memory.images?.backdrops?.count, 12)
        let calls = await service.calls; XCTAssertEqual(calls, 1)
    }
    func testFilenameCannotConfirmEvenCompleteUniqueSearchResult() async throws {
        for counts in [(1, 1), (2, 1), (21, 2)] {
            let service = MatchingAuditService(total: counts.0, pages: counts.1)
            let store = TMDBRepository(client: service)
            let summary = VideoSummary(siteKey: "wogg", siteName: "Source", videoID: "last", title: "最后孤屋")
            let detail = VideoDetail(summary: summary, playSources: [.init(name: "source", episodes: [.init(name: "The.Last.House.2026.1080p.NF.WEB-DL", url: "opaque:unchanged")])])
            let result = try await store.resolve(key: "cold", input: .init(detail: detail))
            guard case .candidates = result else { return XCTFail("Filenames and result count cannot establish identity") }
        }
    }
    func testAliasSearchPrefetchWarmsDetailsAndPixelsWithoutCreatingBinding() async throws {
        let service = MatchingAuditService(alias: true), recorder = ArtworkAuditRecorder()
        let store = TMDBRepository(client: service, prefetchArtwork: { await recorder.record($0.id) })
        let value = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "黑帮领地", year: "2025", categoryName: "欧美剧")))
        await store.prefetch(input: value)
        let calls = await recorder.ids; XCTAssertEqual(calls, [247718])
        let binding = await store.binding(key: "a", input: value); XCTAssertNil(binding)
        let result = try await store.resolve(key: "a", input: value)
        guard case .matched(let candidate, _) = result else { return XCTFail("Full aliases must unlock the verified work") }
        XCTAssertEqual(candidate.reference.id, 247718)
    }
    func testRejectedFirstQueryStillTriesOriginalName() async throws {
        let service = MatchingAuditService(fallback: true), store = TMDBRepository(client: service)
        let value = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "最后孤屋(The Last House)", year: "2026", categoryName: "电影")))
        let result = try await store.resolve(key: "a", input: value)
        guard case .matched(let candidate, _) = result else { return XCTFail("Unrelated first response must not suppress original-name query") }
        XCTAssertEqual(candidate.reference.id, 1284041)
        let queries = await service.queries; XCTAssertEqual(queries, ["最后孤屋", "The Last House"])
    }

    private func input(_ title: String = "测试电影") -> TMDBMatchInput {
        .init(detail: .init(summary: .init(siteKey: "a", siteName: "Site", videoID: "1", title: title, year: "2023", categoryName: "电影")))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TMDBTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSummaryPreviewVerifiesFullWorkButOnlyDetailPassPersistsBinding() async throws {
        let service = TMDBServiceProbe(), directory = try directory()
        let store = TMDBRepository(client: service, directory: directory)
        let result = try await store.prepare(key: "summary", input: input(), persistBinding: false)
        guard case .matched(let preview, _) = result else { return XCTFail("Strict summary evidence should display metadata") }
        XCTAssertEqual(preview.reference.id, 1)
        let before = await store.binding(key: "summary", input: input())
        XCTAssertNil(before)
        let restored = TMDBRepository(client: service, directory: directory)
        let persisted = await restored.binding(key: "summary", input: input())
        XCTAssertNil(persisted, "Metadata cache must not turn a preview into a saved source association")
        let final = try await store.prepare(key: "summary", input: input())
        guard case .matched = final else { return XCTFail() }
        let after = await store.binding(key: "summary", input: input())
        XCTAssertEqual(after?.reference?.id, 1)
        let calls = await service.counts
        XCTAssertEqual(calls.search, 1); XCTAssertEqual(calls.detail, 1, "Revalidation reuses verified payloads")
    }

    func testPreviewRetainsSameTitleAmbiguityRules() async throws {
        let store = TMDBRepository(client: TMDBServiceProbe(ambiguous: true))
        let result = try await store.prepare(key: "ambiguous", input: input(), persistBinding: false)
        guard case .candidates(let candidates) = result else { return XCTFail("Early results must not choose the first rival") }
        XCTAssertEqual(candidates.count, 5)
        let saved = await store.binding(key: "ambiguous", input: input())
        XCTAssertNil(saved)
    }

    func testPreviewKeepsUndatedExactTitleRivalAsVeto() async throws {
        let store = TMDBRepository(client: TMDBYearSuffixProbe())
        let value = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "同名作品", year: "1997", categoryName: "电视剧")))
        let result = try await store.prepare(key: "undated", input: value, persistBinding: false)
        guard case .candidates(let candidates) = result else { return XCTFail("Missing dates cannot eliminate a same-title rival") }
        XCTAssertTrue(candidates.contains { $0.reference.id == 2 })
        let saved = await store.binding(key: "undated", input: value)
        XCTAssertNil(saved)
    }

    func testAutomaticCacheRevalidatesNewDirectorEvidenceButRespectsManualChoice() async throws {
        let service = TMDBDirectorProbe()
        for manual in [false, true] {
            let store = TMDBRepository(client: service)
            if manual { _ = try await store.choose(.init(type: .movie, id: 1), key: "a", input: input()) }
            else { _ = try await store.resolve(key: "a", input: input()) }
            let changed = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "A", videoID: "1", title: "测试电影", year: "2023", categoryName: "电影"), director: "乙导演"))
            let cached = await store.cachedResolution(key: "a", input: changed)
            if manual { XCTAssertNotNil(cached) } else { XCTAssertNil(cached) }
            let result = try await store.resolve(key: "a", input: changed)
            if manual {
                guard case .matched(_, let binding) = result else { return XCTFail("Explicit choices retain precedence") }
                XCTAssertTrue(binding.manual)
            } else {
                guard case .candidates = result else { return XCTFail("Conflicting director must reject automatic cache") }
                let stale = await store.binding(key: "a", input: input())
                XCTAssertNil(stale)
            }
        }
    }

    func testPreparationCannotCoalesceDifferentCreditRolesWithSameLegacyFingerprint() async throws {
        let store = TMDBRepository(client: TMDBDirectorProbe(delay: 100_000_000))
        let summary = VideoSummary(siteKey: "a", siteName: "A", videoID: "1", title: "测试电影", year: "2023", categoryName: "电影")
        let initial = TMDBMatchInput(detail: .init(summary: summary, director: "甲导演", actors: "乙导演"))
        let updated = TMDBMatchInput(detail: .init(summary: summary, director: "乙导演", actors: "甲导演"))
        XCTAssertEqual(TMDBRepository.fingerprint(initial), TMDBRepository.fingerprint(updated))
        let early = Task { try await store.prepare(key: "roles", input: initial, persistBinding: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let final = try await store.prepare(key: "roles", input: updated)
        _ = try? await early.value
        guard case .candidates = final else { return XCTFail("Same people in different roles must trigger revalidation") }
        let saved = await store.binding(key: "roles", input: initial)
        XCTAssertNil(saved)
    }

    func testCapturedFantaiDetailMatchesWithoutSavedBinding() async throws {
        guard let path = ProcessInfo.processInfo.environment["OKVIDEOMAC_FANTAI_FIXTURES"] else {
            throw XCTSkip("Opt-in private TVBox response replay")
        }
        let root = URL(fileURLWithPath: path)
        for (label, year, reference, leads) in [
            ("fan", 2026, TMDBReference(type: .tv, id: 289078), ["李现", "李一桐"]),
            ("rebo", 2026, TMDBReference(type: .tv, id: 289078), ["李现", "李一桐"]),
            ("movie", 2023, TMDBReference(type: .movie, id: 842675), ["吴京", "刘德华"])
        ] {
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("\(label)-detail.json")))
            let detail = try SpiderResponseMapper.detail(payload, site: .init(key: label, name: "TVBox", type: 3, api: "csp_Test"), baseURL: nil)
            let input = TMDBMatchInput(detail: detail)
            XCTAssertEqual(input.year, year)
            XCTAssertNil(input.type)
            XCTAssertEqual(Array(input.principalActors.prefix(2)), leads)
            let transport = FantaiResponseReplay(root: root, searchFile: label == "fan" ? "tmdb-search.json" : "\(label)-tmdb-search.json")
            let repository = TMDBRepository(client: TMDBClient(credential: try TMDBCredential(kind: .readAccessToken, value: "test-only-token"), httpClient: transport))
            let result = try await repository.prepare(key: "fresh-\(label)", input: input)
            guard case .matched(let candidate, let binding) = result else { XCTFail("Real TVBox detail needs automatic matching: \(label)"); continue }
            XCTAssertEqual(candidate.reference, reference)
            XCTAssertFalse(binding.manual)
            XCTAssertTrue(TMDBMatcher.assess(candidate, input: input).corroboratedCast)
            let requests = await transport.paths
            XCTAssertEqual(requests, reference.type == .tv
                ? ["/3/search/multi", "/3/tv/289078"]
                : ["/3/search/multi", "/3/movie/842675"])
        }
    }

    func testPersonWorksCoalescesPersistsAndKeepsStaleDataWhenRefreshFails() async throws {
        let service = TMDBPersonServiceProbe(), directory = try directory()
        let store = TMDBRepository(client: service, directory: directory)
        async let first = store.personWorks(id: 31)
        async let second = store.personWorks(id: 31)
        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1]); XCTAssertEqual(results[0].count, 1)
        let calls = await service.calls; XCTAssertEqual(calls, 1)
        await service.fail()
        let restored = TMDBRepository(client: service, directory: directory, now: { Date().addingTimeInterval(86401) })
        let cached = await restored.cachedPersonWorks(id: 31); XCTAssertEqual(cached, results[0])
        do { _ = try await restored.personWorks(id: 31, refresh: true); XCTFail() } catch {}
        let retained = await restored.cachedPersonWorks(id: 31); XCTAssertEqual(retained, results[0])
    }

    func testPreparationIsCoalescedAndOutlivesCancelledViewSubscriber() async throws {
        let service = TMDBServiceProbe(searchDelay: 150_000_000)
        let store = TMDBRepository(client: service), value = input()
        let first = Task { try await store.prepare(key: "a", input: value) }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        let second = try await store.prepare(key: "a", input: value)
        guard case .matched = second else { return XCTFail() }
        let calls = await service.counts
        XCTAssertEqual(calls.search, 1); XCTAssertEqual(calls.detail, 1)
    }

    func testPreparationTimeoutDoesNotPersistFalseNoMatch() async throws {
        let service = TMDBServiceProbe(searchDelay: 150_000_000)
        let store = TMDBRepository(client: service)
        do { _ = try await store.prepare(key: "a", input: input(), timeout: 0.03); XCTFail() } catch {}
        let failed = await store.binding(key: "a", input: input())
        XCTAssertNil(failed)
        let second = try await store.prepare(key: "a", input: input(), timeout: 1)
        guard case .matched = second else { return XCTFail("Timeout became a negative cache entry") }
    }

    func testPrefetchWarmsFullCandidateButNeverBindsSource() async throws {
        let service = TMDBServiceProbe(), store = TMDBRepository(client: service)
        await store.prefetch(input: input())
        let before = await service.counts
        XCTAssertEqual(before.search, 1); XCTAssertEqual(before.detail, 1)
        let binding = await store.binding(key: "a", input: input())
        XCTAssertNil(binding)
        _ = try await store.prepare(key: "a", input: input())
        let after = await service.counts
        XCTAssertEqual(after.search, 1); XCTAssertEqual(after.detail, 1)
    }

    func testPrefetchNeverRemovesUnexaminedSameTitleRivals() async throws {
        let service = TMDBServiceProbe(ambiguous: true), store = TMDBRepository(client: service)
        await store.prefetch(input: input())
        let counts = await service.counts
        XCTAssertEqual(counts.detail, 2, "Bound speculative detail traffic")
        let result = try await store.prepare(key: "ambiguous-prefetch", input: input())
        guard case .candidates(let candidates) = result else { return XCTFail("Preloading must not promote the first candidate") }
        XCTAssertEqual(candidates.count, 5)
        let binding = await store.binding(key: "ambiguous-prefetch", input: input())
        XCTAssertNil(binding)
    }

    func testWarmCandidateStillRequiresIndependentSourceIdentity() async throws {
        let service = TMDBServiceProbe(), store = TMDBRepository(client: service)
        await store.prefetch(input: input())
        let sparse = TMDBMatchInput(detail: .init(summary: .init(
            siteKey: "a", siteName: "Site", videoID: "1", title: "测试电影", categoryName: "电影")))
        let pending = try await store.prepare(key: "sparse", input: sparse)
        guard case .candidates = pending else { return XCTFail("A warm candidate cannot supply its own missing source year") }
        let before = await store.binding(key: "sparse", input: sparse)
        XCTAssertNil(before)
        let verified = try await store.prepare(key: "sparse", input: input())
        guard case .matched(let selected, _) = verified else { return XCTFail("Independent source evidence should unlock the warm work") }
        XCTAssertEqual(selected.reference.id, 1)
        let counts = await service.counts
        XCTAssertEqual(counts.detail, 1)
    }

    func testPrefetchSkipsKnownYearConflictAndCannotSatisfyChangedIdentity() async throws {
        let service = TMDBServiceProbe(), store = TMDBRepository(client: service)
        let differentYear = TMDBMatchInput(detail: .init(summary: .init(siteKey: "s", siteName: "s", videoID: "1", title: "测试电影", year: "1997", categoryName: "电影")))
        await store.prefetch(input: differentYear)
        let first = await service.counts
        XCTAssertEqual(first.detail, 0)
        await store.prefetch(input: input())
        let result = try await store.prepare(key: "changed", input: differentYear)
        guard case .candidates = result else { return XCTFail("Warm work cannot bypass year verification") }
        let binding = await store.binding(key: "changed", input: differentYear)
        XCTAssertNil(binding)
    }

    func testPrefetchJobSurvivesCancelledSubscriberAndCoalescesEntry() async throws {
        let service = TMDBServiceProbe(searchDelay: 100_000_000), store = TMDBRepository(client: service)
        let first = Task { await store.prefetch(input: self.input()) }
        while await service.counts.search == 0 { await Task.yield() }
        first.cancel()
        await store.prefetch(input: input())
        await first.value
        _ = try await store.prepare(key: "entered", input: input())
        let counts = await service.counts
        XCTAssertEqual(counts.search, 1); XCTAssertEqual(counts.detail, 1)
    }

    func testAutomaticBindingAndCacheAvoidRepeatSearch() async throws {
        let service = TMDBServiceProbe()
        let store = TMDBRepository(client: service)
        let first = try await store.resolve(key: "source-a", input: input())
        let second = try await store.resolve(key: "source-a", input: input())
        XCTAssertEqual(first, second)
        let counts = await service.counts
        XCTAssertEqual(counts.search, 1)
        XCTAssertEqual(counts.detail, 1)
    }
    func testSourceNamespaceAndChangedContentNeverReuseWrongBinding() async throws {
        XCTAssertNotEqual(TMDBRepository.sourceKey(namespace: "config1", siteKey: "same", videoID: "1"),
                          TMDBRepository.sourceKey(namespace: "config2", siteKey: "same", videoID: "1"))
        let store = TMDBRepository(client: TMDBServiceProbe())
        _ = try await store.choose(.init(type: .movie, id: 2), key: "a", input: input())
        let otherSource = await store.binding(key: "b", input: input())
        let otherContent = await store.binding(key: "a", input: input("另一部"))
        XCTAssertNil(otherSource); XCTAssertNil(otherContent)
    }
    func testManualBindingPersistsWithoutProviderSecretsAndSurvivesOffline() async throws {
        let directory = try directory(), service = TMDBServiceProbe()
        let store = TMDBRepository(client: service, directory: directory)
        _ = try await store.choose(.init(type: .movie, id: 2), key: "hashed-source", input: input())
        let restored = TMDBRepository(client: TMDBServiceProbe(fails: true), directory: directory)
        let result = try await restored.resolve(key: "hashed-source", input: input())
        guard case .matched(let candidate, let binding) = result else { return XCTFail() }
        XCTAssertEqual(candidate.reference.id, 2); XCTAssertTrue(binding.manual)
        let text = try String(contentsOf: directory.appendingPathComponent("tmdb-v1.json"))
        XCTAssertFalse(text.contains("opaque:")); XCTAssertFalse(text.contains("Authorization"))
    }
    func testRestoreOriginalAndPerLineSeasonChoicePersist() async throws {
        let store = TMDBRepository(client: TMDBServiceProbe())
        _ = try await store.choose(.init(type: .movie, id: 1), key: "a", input: input())
        _ = try await store.selectSeason(0, sourceID: "line1", key: "a", input: input())
        let binding = try await store.selectSeason(2, sourceID: "line2", key: "a", input: input())
        XCTAssertEqual(binding?.seasons, ["line1": 0, "line2": 2])
        try await store.useOriginal(key: "a", input: input())
        let result = try await store.resolve(key: "a", input: input())
        guard case .matched(_, let retained) = result else { return XCTFail("Original view must retain the binding") }
        XCTAssertEqual(retained.reference?.id, 1)
        XCTAssertEqual(retained.seasons, ["line1": 0, "line2": 2])
    }
    func testLateAutomaticResponseCannotOverwriteManualCorrection() async throws {
        let service = TMDBServiceProbe(searchDelay: 150_000_000)
        let repository = TMDBRepository(client: service)
        let automatic = Task { try await repository.resolve(key: "a", input: self.input()) }
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = try await repository.choose(.init(type: .movie, id: 2), key: "a", input: input())
        do { _ = try await automatic.value; XCTFail("Old auto match replaced user choice") } catch { XCTAssertTrue(error is CancellationError) }
        let binding = await repository.binding(key: "a", input: input())
        XCTAssertEqual(binding?.reference?.id, 2)
        XCTAssertEqual(binding?.manual, true)
    }
    func testNetworkFailureDoesNotBecomePermanentNoMatch() async throws {
        var date = Date(timeIntervalSince1970: 1000)
        let service = TMDBServiceProbe(fails: true)
        let store = TMDBRepository(client: service, now: { date })
        do { _ = try await store.resolve(key: "a", input: input()); XCTFail() } catch {}
        await service.setFailure(false)
        date.addTimeInterval(61)
        let result = try await store.resolve(key: "a", input: input())
        guard case .matched = result else { return XCTFail("Temporary outage was cached as no match") }
    }
    func testExpiredMetadataRefreshesButManualIdentityIsKept() async throws {
        var date = Date(timeIntervalSince1970: 1000)
        let service = TMDBServiceProbe()
        let repository = TMDBRepository(client: service, now: { date })
        _ = try await repository.choose(.init(type: .movie, id: 2), key: "a", input: input())
        date.addTimeInterval(86400 * 7 + 1)
        _ = try await repository.resolve(key: "a", input: input())
        let counts = await service.counts
        XCTAssertEqual(counts.search, 0); XCTAssertEqual(counts.detail, 2)
    }
    func testManySameNameCandidatesRemainAmbiguousBeyondDetailBudget() async throws {
        let service = TMDBServiceProbe(ambiguous: true)
        let store = TMDBRepository(client: service)
        let result = try await store.resolve(key: "a", input: input())
        guard case .candidates(let candidates) = result else { return XCTFail() }
        XCTAssertEqual(candidates.count, 5)
        let counts = await service.counts
        XCTAssertEqual(counts.detail, 2)
    }

    func testResourceLabelsAndExpandedCastKeepManualBinding() async throws {
        let store = TMDBRepository(client: TMDBServiceProbe())
        _ = try await store.choose(.init(type: .movie, id: 2), key: "a", input: input())
        let changed = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "Site", videoID: "1", title: "测试电影（臻彩·4K）", year: "2023", categoryName: "电影"), actors: "新增演员、另一演员"))
        let binding = await store.binding(key: "a", input: changed)
        XCTAssertEqual(binding?.reference?.id, 2)
        XCTAssertEqual(binding?.manual, true)
        _ = try await store.resolve(key: "a", input: input("另一部"))
        let original = await store.binding(key: "a", input: input())
        XCTAssertEqual(original?.reference?.id, 2, "Identity conflicts must not overwrite a human choice")
    }

    func testExpiredMetadataSurvivesRelaunchAsDisplayCache() async throws {
        let directory = try directory()
        let store = TMDBRepository(client: TMDBServiceProbe(), directory: directory, now: { Date(timeIntervalSince1970: 1000) })
        _ = try await store.choose(.init(type: .movie, id: 2), key: "a", input: input())
        let restored = TMDBRepository(client: TMDBServiceProbe(fails: true), directory: directory, now: { Date(timeIntervalSince1970: 900000) })
        let cached = await restored.cachedResolution(key: "a", input: input())
        guard case .matched(let candidate, _) = cached else { return XCTFail("Expiry must not delete identity-compatible display data") }
        XCTAssertEqual(candidate.reference.id, 2)
    }

    func testLegacyBindingMigratesWithoutLosingManualSeason() async throws {
        let directory = try directory()
        let store = TMDBRepository(client: TMDBServiceProbe(), directory: directory)
        _ = try await store.choose(.init(type: .movie, id: 2), key: "a", input: input())
        _ = try await store.selectSeason(2, sourceID: "line", key: "a", input: input())
        let file = directory.appendingPathComponent("tmdb-v1.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var bindings = try XCTUnwrap(json["bindings"] as? [String: [String: Any]])
        bindings["a"]?.removeValue(forKey: "identity"); bindings["a"]?.removeValue(forKey: "revision")
        json["bindings"] = bindings; json.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let restored = TMDBRepository(client: TMDBServiceProbe(), directory: directory)
        let binding = await restored.binding(key: "a", input: input())
        XCTAssertEqual(binding?.reference?.id, 2); XCTAssertTrue(binding?.manual == true)
        XCTAssertEqual(binding?.seasons["line"], 2); XCTAssertNotNil(binding?.identity)
    }

    func testElapsedDeadlineDoesNotSearchOrCacheNoMatch() async throws {
        let service = TMDBServiceProbe()
        let expired = TMDBRepository(client: service)
        do { _ = try await expired.resolve(key: "a", input: input(), deadline: 0); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await service.counts
        XCTAssertEqual(counts.search, 0)
        let retry = try await expired.resolve(key: "a", input: input())
        guard case .matched = retry else { return XCTFail() }
    }

    func testSharedSearchSurvivesOneCancelledSubscriberAndKeepsSeparateBindings() async throws {
        let service = TMDBServiceProbe(searchDelay: 100_000_000)
        let shared = TMDBRepository(client: service)
        let abandoned = Task { try await shared.resolve(key: "old-page", input: self.input()) }
        let retained = Task { try await shared.resolve(key: "new-page", input: self.input()) }
        try await Task.sleep(nanoseconds: 20_000_000)
        abandoned.cancel()
        let result = try await retained.value
        guard case .matched = result else { return XCTFail() }
        _ = try? await abandoned.value
        let counts = await service.counts
        XCTAssertEqual(counts.search, 1); XCTAssertEqual(counts.detail, 1)
        let old = await shared.binding(key: "old-page", input: input())
        let active = await shared.binding(key: "new-page", input: input())
        XCTAssertNil(old); XCTAssertNotNil(active)
    }

    func testSeasonRequestsCoalesceAndExpiredValueSurvivesFailedRefresh() async throws {
        var date = Date(timeIntervalSince1970: 1000)
        let service = TMDBSeasonRefreshProbe()
        let repository = TMDBRepository(client: service, now: { date })
        async let first = repository.season(tvID: 1, number: 1, ongoing: true)
        async let second = repository.season(tvID: 1, number: 1, ongoing: true)
        _ = try await (first, second)
        let count = await service.calls
        XCTAssertEqual(count, 1)
        date.addTimeInterval(21601)
        await service.fail()
        do { _ = try await repository.season(tvID: 1, number: 1, ongoing: true); XCTFail() } catch {}
        let retained = await repository.cachedSeason(tvID: 1, number: 1)
        XCTAssertEqual(retained?.episodes.first?.episodeNumber, 1)
    }

    func testYearSuffixSearchMergesRivalsAndDoesNotFetchKnownWrongYear() async throws {
        let service = TMDBYearSuffixProbe()
        let store = TMDBRepository(client: service)
        let input = TMDBMatchInput(detail: .init(summary: .init(siteKey: "a", siteName: "Source", videoID: "1", title: "同名作品1997", year: "1997"), actors: "甲演员、乙演员"))
        let result = try await store.resolve(key: "source", input: input)
        guard case .candidates(let candidates) = result else { return XCTFail("Raw-title and undated rivals must prevent automatic binding") }
        XCTAssertEqual(Set(candidates.map(\.reference.id)), [1, 2, 3, 4])
        XCTAssertEqual(candidates.count, 4, "Overlapping searches must not duplicate identities")
        let queries = await service.queries, details = await service.details
        XCTAssertEqual(queries, ["同名作品", "同名作品1997"])
        XCTAssertEqual(Set(details), [1, 4])
    }
}

private actor TMDBYearSuffixProbe: TMDBServing {
    var queries: [String] = [], details: [Int] = []
    func work(_ id: Int) throws -> TMDBWork {
        let title = id == 4 ? "同名作品1997" : "同名作品"
        let date = id == 2 ? "" : id == 3 ? "2003-01-01" : "1997-01-01"
        let data = Data("{\"id\":\(id),\"name\":\"\(title)\",\"media_type\":\"tv\",\"first_air_date\":\"\(date)\",\"aggregate_credits\":{\"cast\":[{\"id\":10,\"name\":\"甲演员\"},{\"id\":11,\"name\":\"乙演员\"}]}}".utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: data)
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        queries.append(query)
        return try (query == "同名作品" ? [1, 2, 3] : [1, 4]).map(work)
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { details.append(reference.id); return try work(reference.id) }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBServiceProbe: TMDBServing {
    var counts = (search: 0, detail: 0)
    var fails: Bool
    let searchDelay: UInt64
    let ambiguous: Bool
    init(fails: Bool = false, searchDelay: UInt64 = 0, ambiguous: Bool = false) {
        self.fails = fails; self.searchDelay = searchDelay; self.ambiguous = ambiguous
    }
    func setFailure(_ fails: Bool) { self.fails = fails }
    func work(_ id: Int) throws -> TMDBWork {
        let data = Data("{\"id\":\(id),\"title\":\"测试电影\",\"release_date\":\"2023-01-01\"}".utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: data)
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        counts.search += 1
        if searchDelay > 0 { try? await Task.sleep(nanoseconds: searchDelay) }
        if fails { throw HTTPClientError.transport("offline") }
        return try (ambiguous ? Array(1...5) : [1]).map(work)
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        counts.detail += 1
        if fails { throw HTTPClientError.transport("offline") }
        return try work(reference.id)
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBSeasonRefreshProbe: TMDBServing {
    var calls = 0
    var failed = false
    func fail() { failed = true }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason {
        calls += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        if failed { throw HTTPClientError.transport("offline") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBSeason.self, from: Data(#"{"season_number":1,"episodes":[{"id":1,"episode_number":1}]}"#.utf8))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBPersonServiceProbe: TMDBServing {
    var calls = 0, failed = false
    func fail() { failed = true }
    func personCredits(id: Int) async throws -> TMDBPersonCredits {
        calls += 1; try await Task.sleep(nanoseconds: 30_000_000)
        if failed { throw HTTPClientError.transport("offline") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBPersonCredits.self, from: Data(#"{"id":31,"cast":[{"id":1,"media_type":"movie","title":"电影"}]}"#.utf8))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { throw TMDBError.invalidInput }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor FantaiResponseReplay: HTTPClient {
    let root: URL
    var paths: [String] = []
    let searchFile: String
    init(root: URL, searchFile: String) { self.root = root; self.searchFile = searchFile }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        paths.append(request.url.path)
        let file: String
        switch request.url.path {
        case "/3/search/multi": file = searchFile
        case "/3/tv/289078": file = "tmdb-detail.json"
        case "/3/tv/313346": file = "tmdb-tv-313346.json"
        case "/3/movie/842675": file = "tmdb-movie-842675.json"
        default: throw TMDBError.invalidInput
        }
        return .init(url: request.url, statusCode: 200, headers: [:], body: try Data(contentsOf: root.appendingPathComponent(file)))
    }
}

private struct TMDBDirectorProbe: TMDBServing {
    var delay: UInt64 = 0
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return [try await detail(.init(type: .movie, id: 1))]
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: Data(#"{"id":1,"title":"测试电影","release_date":"2023-01-01","credits":{"crew":[{"id":99,"name":"甲导演","job":"Director"}]}}"#.utf8))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor ArtworkAuditRecorder {
    var ids: [Int] = []
    func record(_ id: Int) { ids.append(id) }
}
private actor MatchingAuditService: TMDBServing {
    let total: Int, pages: Int, alias: Bool, fallback: Bool
    var queries: [String] = []
    init(total: Int = 1, pages: Int = 1, alias: Bool = false, fallback: Bool = false) {
        self.total = total; self.pages = pages; self.alias = alias; self.fallback = fallback
    }
    private func work(_ json: String) throws -> TMDBWork {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: Data(json.utf8))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { try await searchPage(query: query, type: type, year: year).results }
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        queries.append(query)
        let value: TMDBWork
        if alias { value = try work(#"{"id":247718,"name":"MobLand","original_name":"MobLand","media_type":"tv","first_air_date":"2025-03-30"}"#) }
        else if fallback && query == "最后孤屋" { value = try work(#"{"id":2,"title":"无关电影","original_title":"Unrelated","media_type":"movie","release_date":"2026-01-01"}"#) }
        else { value = try await detail(.init(type: .movie, id: 1284041)) }
        return .init(results: [value], page: 1, totalPages: pages, totalResults: total)
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        if reference.id == 247718 { return try work(#"{"id":247718,"name":"MobLand","original_name":"MobLand","media_type":"tv","first_air_date":"2025-03-30","alternative_titles":{"results":[{"title":"黑帮领地"}]}}"#) }
        if reference.id == 2 { return try work(#"{"id":2,"title":"无关电影","original_title":"Unrelated","media_type":"movie","release_date":"2026-01-01"}"#) }
        return try work(#"{"id":1284041,"title":"最后孤屋","original_title":"The Last House","media_type":"movie","release_date":"2026-08-06"}"#)
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBArtworkRetentionProbe: TMDBServing {
    var calls = 0
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        calls += 1
        let items: [[String: Any]] = (1...13).map { ["file_path": "/\($0).jpg", "width": $0 * 100, "iso_639_1": "zh"] }
        let payload: [String: Any] = ["id": 1, "title": "测试电影", "images": ["backdrops": items, "posters": items, "logos": items]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBAliasProbe: TMDBServing {
    var aliasRequests: [Int] = []
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [try await detail(.init(type: .tv, id: 283319))] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: Data(#"{"id":283319,"name":"翠鸟谋杀案","first_air_date":"2026-09-06","media_type":"tv","aggregate_credits":{"cast":[{"id":72305,"name":"莱丝利·曼维尔"},{"id":15740,"name":"Tim McMullan"}]}}"#.utf8))
    }
    func personIdentity(id: Int) async throws -> TMDBPersonIdentity {
        aliasRequests.append(id)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBPersonIdentity.self, from: Data(#"{"id":15740,"name":"Tim McMullan","also_known_as":["蒂姆·迈克穆兰"]}"#.utf8))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

extension TMDBRepositoryTests {
    func testNetworkSessionResetRejectsLateWorkAndAcceptsNewRequest() async throws {
        let service = TMDBResetService()
        let repo = TMDBRepository(client: service)
        let old = Task { try await repo.detail(.init(type: .movie, id: 1)) }
        while await service.calls == 0 { await Task.yield() }
        await repo.resetNetworkSession()
        do { _ = try await old.value; XCTFail("Cancelled session populated the cache") } catch { XCTAssertTrue(error is CancellationError) }
        let work = try await repo.detail(.init(type: .movie, id: 1))
        XCTAssertEqual(work.title, "new")
        let count = await service.calls
        XCTAssertEqual(count, 2)
    }
}
private actor TMDBResetService: TMDBServing {
    var calls = 0
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        calls += 1; let first = calls == 1
        if first { try? await Task.sleep(nanoseconds: 150_000_000) }
        // Simulate a transport that returns after cancellation.
        return try JSONDecoder().decode(TMDBWork.self, from: Data("{\"id\":1,\"title\":\"\(first ? "old" : "new")\"}".utf8))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

private actor TMDBDirectorAliasProbe: TMDBServing {
    var aliasRequests: [Int] = []
    let alias: String?
    let wrongID: Bool
    let pageComplete: Bool?
    let year: String
    init(alias: String? = "Verified Local Director", wrongID: Bool = false, pageComplete: Bool? = true, year: String = "2025") {
        self.alias = alias; self.wrongID = wrongID; self.pageComplete = pageComplete; self.year = year
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [try await detail(.init(type: .movie, id: 1550223))] }
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        let items = try await search(query: query, type: type, year: year)
        return .init(results: items, page: pageComplete == nil ? nil : 1, totalPages: pageComplete.map { $0 ? 1 : 2 }, totalResults: pageComplete.map { $0 ? 1 : 21 })
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        let json: [String: Any] = ["id": 1550223, "title": "余光珍爱", "media_type": "movie", "release_date": year + "-10-15",
            "credits": ["crew": [["id": 424258, "name": "Adolfo Alix Jr.", "job": "Director", "also_known_as": ["Existing Alias"]]]]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func personIdentity(id: Int) async throws -> TMDBPersonIdentity {
        aliasRequests.append(id)
        guard let alias else { throw TMDBError.unavailable(503) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBPersonIdentity.self, from: JSONSerialization.data(withJSONObject: ["id": wrongID ? 999 : id, "name": "Adolfo Alix Jr.", "also_known_as": [alias]]))
    }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}

extension TMDBRepositoryTests {
    private func directorInput(_ name: String = "Verified Local Director") -> TMDBMatchInput {
        .init(detail: .init(summary: .init(siteKey: "s", siteName: "S", videoID: "remaining", title: "余光珍爱", year: "2025", categoryName: "剧情 悬疑 恐怖"), director: name, actors: "未知"))
    }
    func testDirectorAliasIsQueriedWithoutActorsAndPersistedWithCorrectRole() async throws {
        let client = TMDBDirectorAliasProbe(), folder = try directory(), input = directorInput()
        let repository = TMDBRepository(client: client, directory: folder)
        let result = try await repository.prepare(key: "first", input: input)
        guard case .matched(let candidate, let binding) = result else { return XCTFail("Official alias should confirm the director") }
        XCTAssertFalse(binding.manual); XCTAssertEqual(candidate.reference.id, 1550223)
        XCTAssertTrue(candidate.work.directors[0].alsoKnownAs?.contains("Existing Alias") == true)
        let reopened = TMDBRepository(client: client, directory: folder)
        let cache = await reopened.cachedResolution(key: "first", input: input)
        guard case .matched = cache else { return XCTFail("Director evidence was not retained on disk") }
        let second = try await reopened.resolve(key: "second", input: input)
        guard case .matched = second else { return XCTFail("Enriched director should be reusable") }
        let calls = await client.aliasRequests; XCTAssertEqual(calls, [424258])
    }
    func testDirectorCannotManufactureUniquenessFromIncompleteOrUnknownPages() async throws {
        for complete: Bool? in [false, nil] {
            let store = TMDBRepository(client: TMDBDirectorAliasProbe(pageComplete: complete))
            let result = try await store.resolve(key: "missing-pages", input: directorInput())
            guard case .candidates = result else { return XCTFail("Director-only form inference needs complete search metadata") }
            let binding = await store.binding(key: "missing-pages", input: directorInput()); XCTAssertNil(binding)
        }
    }
    func testDirectorUnverifiedAliasFailureAndWrongPersonNeverAutoBind() async throws {
        for client in [TMDBDirectorAliasProbe(alias: nil), TMDBDirectorAliasProbe(alias: "Different Director"), TMDBDirectorAliasProbe(wrongID: true)] {
            let store = TMDBRepository(client: client)
            let result = try await store.resolve(key: "unknown", input: directorInput())
            guard case .candidates = result else { return XCTFail("Unverified director must require confirmation") }
            let binding = await store.binding(key: "unknown", input: directorInput()); XCTAssertNil(binding)
        }
    }
    func testYearConflictCannotBeRepairedByDirectorAndSkipsPeopleRequests() async throws {
        let client = TMDBDirectorAliasProbe(year: "2024"), store = TMDBRepository(client: client)
        let result = try await store.resolve(key: "wrong-year", input: directorInput())
        guard case .candidates = result else { return XCTFail("Wrong year accepted") }
        let calls = await client.aliasRequests; XCTAssertTrue(calls.isEmpty)
    }
}


private actor TMDBDirectorRivalProbe: TMDBServing {
    var queries: [String] = []
    func work(_ id: Int) throws -> TMDBWork {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json: [String: Any] = ["id": id, "title": "余光珍爱", "original_title": "The Time That Remains", "media_type": "movie", "release_date": "2025-10-15", "credits": ["crew": [["id": 424258, "name": "Adolfo Alix Jr.", "job": "Director"]]]]
        return try decoder.decode(TMDBWork.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { try await searchPage(query: query, type: type, year: year).results }
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        queries.append(query)
        let values = query == "余光珍爱" ? [try work(1550223)] : [try work(1550223), try work(999)]
        return .init(results: values, page: 1, totalPages: 1, totalResults: values.count)
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { try work(reference.id) }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}
extension TMDBRepositoryTests {
    func testDirectorConfirmationChecksAllSourceAliasesBeforeAcceptingUniqueCandidate() async throws {
        let client = TMDBDirectorRivalProbe(), store = TMDBRepository(client: client)
        let input = TMDBMatchInput(detail: .init(summary: .init(siteKey: "s", siteName: "S", videoID: "1", title: "余光珍爱(The Time That Remains)", year: "2025"), director: "Adolfo Alix Jr."))
        let result = try await store.resolve(key: "aliases", input: input)
        guard case .candidates = result else { return XCTFail("A unique first query must not hide the rival in the other title query") }
        let queries = await client.queries; XCTAssertEqual(queries, ["余光珍爱", "The Time That Remains"])
        let binding = await store.binding(key: "aliases", input: input); XCTAssertNil(binding)
    }
}
