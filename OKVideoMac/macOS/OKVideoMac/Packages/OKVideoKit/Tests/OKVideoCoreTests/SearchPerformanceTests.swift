import Foundation
import XCTest
@testable import OKVideoCore

final class SearchPerformanceTests: XCTestCase {
    private func key(_ identity: String) -> String { SearchPerformanceStore.key(namespace: "test", identity: identity) }
    private func sample(_ seconds: Double, _ status: SearchAttemptStatus = .success, relevant: Bool = true) -> SearchAttemptObservation {
        .init(siteKey: "source", elapsed: seconds, status: status, hasRelevantResults: relevant)
    }

    func testFastEmptyDoesNotBecomeFailureAndCancellationDoesNotTrain() {
        let store = SearchPerformanceStore(), fast = key("fast"), unknown = key("unknown")
        for _ in 0..<4 { store.record(sample(0.2), key: fast) }
        store.record(sample(0.04, relevant: false), key: fast)
        XCTAssertLessThan(store.priority(key: fast), store.priority(key: unknown))
        let before = store.priority(key: fast)
        store.record(sample(60, .cancelled), key: fast)
        XCTAssertEqual(before, store.priority(key: fast), accuracy: 0.001)
        store.record(sample(30, .timeout), key: fast)
        XCTAssertGreaterThan(store.priority(key: fast), before)
    }

    func testRestartPreservesWarmLearningButScopesNeverMix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("statistics.json"), fast = key("configurationA/site/script1")
        let store = SearchPerformanceStore(file: file)
        for _ in 0..<6 { store.record(sample(0.1), key: fast) }
        store.recordSelection(key: fast)
        try store.flush()
        let restored = SearchPerformanceStore(file: file)
        XCTAssertEqual(store.priority(key: fast), restored.priority(key: fast), accuracy: 0.001)
        // The first request after restart includes runtime startup. Keep the
        // previously learned warm latency rather than replacing it with 15 s.
        restored.record(sample(15), key: fast)
        XCTAssertLessThan(restored.priority(key: fast), 1)
        XCTAssertEqual(restored.priority(key: key("configurationB/site/script1")), 2)
        XCTAssertEqual(restored.priority(key: key("configurationA/site/script2")), 2)
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("configurationA"))
        XCTAssertFalse(text.contains("source"))
        XCTAssertLessThan(text.utf8.count, 512 * 1024)
    }

    func testBoundedRetentionExpiryAndCorruptFile() throws {
        let clock = PerformanceClock(1_000_000)
        let store = SearchPerformanceStore(now: { clock.read() })
        for index in 0..<600 {
            clock.advance(1)
            store.record(sample(0.1), key: key("\(index)"))
        }
        XCTAssertEqual(store.entryCount, SearchPerformanceStore.maximumEntries)
        XCTAssertEqual(store.priority(key: key("0")), 2)
        XCTAssertLessThan(store.priority(key: key("599")), 2)
        clock.advance(15 * 86_400)
        XCTAssertEqual(store.priority(key: key("599")), 2)
        store.record(sample(0.1), key: key("fresh"))
        XCTAssertEqual(store.entryCount, 1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid".utf8).write(to: file)
        XCTAssertEqual(SearchPerformanceStore(file: file).entryCount, 0)
    }

    func testOwnTimeoutIsObservedAndQueuedTimeDoesNotPolluteElapsed() async {
        let observations = PerformanceObservations()
        let providers = [PerformanceProvider(key: "slow", delay: 1_000_000_000),
                         PerformanceProvider(key: "fast", delay: 1_000_000)]
        for await _ in MultiSiteSearch(maximumConcurrency: 1, siteTimeout: 0.08, maximumPagesPerSite: 1)
            .search(providers: providers, keyword: "film", onAttempt: { observations.add($0) }) {}
        let all = observations.read()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.status, .timeout)
        XCTAssertEqual(all.last?.status, .success)
        XCTAssertTrue(all.last?.hasRelevantResults == true)
        XCTAssertGreaterThan(all.last?.queued ?? 0, 0.06)
        XCTAssertLessThan(all.last?.elapsed ?? 10, 0.06)
    }
}

private final class PerformanceClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double
    init(_ value: Double) { self.value = value }
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delta: Double) { lock.lock(); defer { lock.unlock() }; value += delta }
}
private final class PerformanceObservations: @unchecked Sendable {
    private let lock = NSLock(); private var values: [SearchAttemptObservation] = []
    func add(_ value: SearchAttemptObservation) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func read() -> [SearchAttemptObservation] { lock.lock(); defer { lock.unlock() }; return values }
}
private struct PerformanceProvider: SiteProvider {
    let site: SiteConfiguration; let delay: UInt64
    let capability: SiteCapability = .standardJSON
    init(key: String, delay: UInt64) { site = .init(key: key, name: key, type: 1, api: "https://fixture.invalid"); self.delay = delay }
    func home() async throws -> SiteHome { .init(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { .init(items: [], pagination: .init(page: page, pageCount: 1)) }
    func detail(id: String) async throws -> VideoDetail { throw AppError.site("unused") }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("unused") }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
        try await Task.sleep(nanoseconds: delay)
        return .init(items: [.init(siteKey: site.key, siteName: site.name, videoID: "one", title: keyword)], pagination: .init(page: page, pageCount: 1))
    }
}
