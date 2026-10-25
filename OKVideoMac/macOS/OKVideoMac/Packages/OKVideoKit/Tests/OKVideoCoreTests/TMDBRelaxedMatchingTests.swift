import XCTest
@testable import OKVideoCore

final class TMDBRelaxedMatchingTests: XCTestCase {
    private func input(title: String = "余光珍爱", year: String? = nil, type: String? = nil, director: String? = nil) -> TMDBMatchInput {
        .init(detail: .init(summary: .init(siteKey: "wogg", siteName: "玩偶哥哥", videoID: "remaining", title: title, year: year, categoryName: type), director: director))
    }
    private func assertUnmatched(_ value: TMDBResolution, file: StaticString = #filePath, line: UInt = #line) {
        if case .matched = value { XCTFail("Unexpected automatic binding", file: file, line: line) }
    }
    func testOptInOnlyAndNoPeopleLookupForUniqueExactTitle() async throws {
        let service = RelaxedProbe(), repository = TMDBRepository(client: service)
        let value = input(year: "2025", director: "小阿多弗·亚历克斯")
        assertUnmatched(try await repository.prepare(key: "strict", input: value))
        let result = try await repository.prepare(key: "relaxed", input: value, policy: .relaxed)
        guard case .matched(let candidate, let binding) = result else { return XCTFail("Unique title must be accepted when opted in") }
        XCTAssertEqual(candidate.reference.id, 1550223); XCTAssertTrue(binding.isRelaxed); XCTAssertFalse(binding.manual)
        let fresh = RelaxedProbe()
        _ = try await TMDBRepository(client: fresh).prepare(key: "fast", input: value, policy: .relaxed)
        let events = await fresh.events
        XCTAssertEqual(events, ["search:余光珍爱:multi:nil", "detail:1550223"])
    }
    func testNoYearOrTypeFilterCanHideOtherCandidates() async throws {
        let service = RelaxedProbe(scenario: .rival), store = TMDBRepository(client: service)
        let value = input(year: "2025", type: "电影", director: "小阿多弗·亚历克斯")
        assertUnmatched(try await store.prepare(key: "a", input: value, policy: .relaxed))
        let events = await service.events
        XCTAssertTrue(events.contains("search:余光珍爱:multi:nil"))
        XCTAssertFalse(events.contains { $0.contains(":movie:") })
    }
    func testIncompleteUnknownMalformedOrMultipleResponsesNeverProveUnique() async throws {
        for scenario in [RelaxedProbe.Scenario.incomplete, .unknownCounts, .malformed, .rival, .twoMedia] {
            let store = TMDBRepository(client: RelaxedProbe(scenario: scenario))
            assertUnmatched(try await store.prepare(key: "a", input: input(), policy: .relaxed))
        }
    }
    func testPeopleAreExcludedAndSameWorkDuplicatesAreDeduplicatedAfterCompletenessCheck() async throws {
        for scenario in [RelaxedProbe.Scenario.person, .duplicate] {
            let result = try await TMDBRepository(client: RelaxedProbe(scenario: scenario)).prepare(key: "a", input: input(), policy: .relaxed)
            guard case .matched(let work, let binding) = result else { return XCTFail("One actual film should remain") }
            XCTAssertEqual(work.reference.id, 1550223); XCTAssertTrue(binding.isRelaxed)
        }
    }
    func testNearTitleAndContradictoryYearTypeDirectorOrSeasonAreRejected() async throws {
        let values = [input(title: "余光之爱"), input(year: "2024"), input(type: "电视剧"),
                      input(director: "A Different Director"), input(title: "余光珍爱 第三季"),
                      input(type: "演唱会"), input(title: "余光珍爱2025", year: "2025")]
        for value in values {
            assertUnmatched(try await TMDBRepository(client: RelaxedProbe()).prepare(key: "a", input: value, policy: .relaxed))
        }
    }
    func testBothBilingualQueriesMustCompleteAndAgree() async throws {
        let value = input(title: "余光珍爱(The Time That Remains)")
        let service = RelaxedProbe(), store = TMDBRepository(client: service)
        guard case .matched = try await store.prepare(key: "ok", input: value, policy: .relaxed) else { return XCTFail() }
        let events = await service.events
        XCTAssertTrue(events.contains("search:The Time That Remains:multi:nil"))
        for scenario in [RelaxedProbe.Scenario.bilingualRival, .secondQueryFails] {
            let store = TMDBRepository(client: RelaxedProbe(scenario: scenario))
            do { assertUnmatched(try await store.prepare(key: "bad", input: value, policy: .relaxed)) }
            catch { /* A failed query must never save a match. */ }
            let binding = await store.binding(key: "bad", input: value, policy: .relaxed); XCTAssertNil(binding)
        }
    }
    func testRelaxedCacheIsOptInPersistsAndExpiresWhileManualChoiceSurvives() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(), value = input()
        let store = TMDBRepository(client: RelaxedProbe(), directory: dir, now: { date })
        _ = try await store.prepare(key: "a", input: value, policy: .relaxed)
        let restored = TMDBRepository(client: RelaxedProbe(), directory: dir, now: { date })
        let strict = await restored.cachedResolution(key: "a", input: value)
        let relaxed = await restored.cachedResolution(key: "a", input: value, policy: .relaxed)
        XCTAssertNil(strict); XCTAssertNotNil(relaxed)
        let expired = TMDBRepository(client: RelaxedProbe(), directory: dir, now: { date.addingTimeInterval(86401) })
        let stale = await expired.cachedResolution(key: "a", input: value, policy: .relaxed); XCTAssertNil(stale)
        assertUnmatched(try await restored.prepare(key: "a", input: value))
        let afterStrict = await restored.binding(key: "a", input: value, policy: .relaxed); XCTAssertNil(afterStrict)
        _ = try await restored.choose(.init(type: .movie, id: 1550223), key: "a", input: value)
        let manual = await restored.binding(key: "a", input: value); XCTAssertTrue(manual?.manual == true)
        let relaxedManual = await restored.binding(key: "a", input: value, policy: .relaxed); XCTAssertTrue(relaxedManual?.manual == true)
    }
    func testLaterSourceConflictInvalidatesRelaxedCache() async throws {
        let store = TMDBRepository(client: RelaxedProbe()), first = input()
        _ = try await store.prepare(key: "a", input: first, policy: .relaxed)
        let conflict = input(year: "2024")
        let cached = await store.cachedResolution(key: "a", input: conflict, policy: .relaxed); XCTAssertNil(cached)
        assertUnmatched(try await store.prepare(key: "a", input: conflict, policy: .relaxed))
        let old = await store.binding(key: "a", input: first, policy: .relaxed); XCTAssertNil(old)
    }
    func testTurningOffDuringInFlightPreparationCannotSaveRelaxedMatch() async throws {
        let service = RelaxedProbe(delay: 100_000_000), store = TMDBRepository(client: service), value = input()
        let first = Task { try await store.prepare(key: "a", input: value, policy: .relaxed) }
        while await service.events.isEmpty { await Task.yield() }
        let strict = try await store.prepare(key: "a", input: value, policy: .strict)
        assertUnmatched(strict)
        _ = try? await first.value
        let binding = await store.binding(key: "a", input: value, policy: .relaxed); XCTAssertNil(binding)
    }
    func testFilenameDoesNotChangeRelaxedIdentityDecision() async throws {
        let summary = VideoSummary(siteKey: "wogg", siteName: "Wogg", videoID: "1", title: "余光之爱")
        let detail = VideoDetail(summary: summary, playSources: [.init(name: "原画", episodes: [.init(name: "余光珍爱.The.Time.That.Remains.2025.1080p", url: "opaque:unchanged")])])
        XCTAssertEqual(TMDBMatchInput(detail: detail), TMDBMatchInput(detail: .init(summary: summary)))
        assertUnmatched(try await TMDBRepository(client: RelaxedProbe()).prepare(key: "a", input: .init(detail: detail), policy: .relaxed))
    }
    func testStrictEvidenceRemainsStrictEvenWhenRelaxedModeIsEnabled() async throws {
        let result = try await TMDBRepository(client: RelaxedProbe()).prepare(key: "a", input: input(year: "2025", type: "电影"), policy: .relaxed)
        guard case .matched(_, let binding) = result else { return XCTFail() }
        XCTAssertFalse(binding.isRelaxed)
    }
}

private actor RelaxedProbe: TMDBServing {
    enum Scenario { case unique, incomplete, unknownCounts, malformed, rival, twoMedia, person, duplicate, bilingualRival, secondQueryFails }
    let scenario: Scenario, delay: UInt64
    var events: [String] = []
    init(scenario: Scenario = .unique, delay: UInt64 = 0) { self.scenario = scenario; self.delay = delay }
    private func work(id: Int = 1550223, type: String = "movie", title: String = "余光珍爱") throws -> TMDBWork {
        let data: [String: Any] = ["id": id, "media_type": type, type == "tv" ? "name" : "title": title, "original_title": "The Time That Remains", "release_date": "2025-10-15", "poster_path": "/poster.jpg", "credits": ["crew": [["id":424258,"name":"Adolfo Alix Jr.","job":"Director"]]]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TMDBWork.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { try await searchPage(query: query, type: type, year: year).results }
    func searchPage(query: String, type: TMDBMediaType?, year: Int?) async throws -> TMDBSearchPage {
        events.append("search:\(query):\(type?.rawValue ?? "multi"):\(year.map(String.init) ?? "nil")")
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if scenario == .secondQueryFails && query.contains("The Time") { throw URLError(.timedOut) }
        var items = [try work()]
        switch scenario {
        case .rival: items.append(try work(id: 2))
        case .twoMedia: items.append(try work(type: "tv"))
        case .person: items.append(try work(id: 3, type: "person", title: "Person"))
        case .duplicate: items.append(try work())
        case .malformed: items.append(try work(id: 0, type: "unknown"))
        case .bilingualRival: if query.contains("The Time") { items.append(try work(id: 2)) }
        default: break
        }
        return .init(results: items, page: scenario == .unknownCounts ? nil : 1,
            totalPages: scenario == .unknownCounts ? nil : (scenario == .incomplete ? 2 : 1),
            totalResults: scenario == .unknownCounts ? nil : (scenario == .incomplete ? 21 : items.count))
    }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork {
        events.append("detail:\(reference.id)")
        return try work(id: reference.id, type: reference.type.rawValue)
    }
    func personIdentity(id: Int) async throws -> TMDBPersonIdentity { events.append("person:\(id)"); throw TMDBError.unavailable(404) }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
    func imageConfiguration() async throws -> TMDBImageConfiguration { throw TMDBError.invalidInput }
}
