import XCTest
@testable import OKVideoCore

final class TMDBPresentationPolicyTests: XCTestCase {
    func testMigrationPreservesOriginalAndConvertsLegacyEnabledToConditionalAutomatic() throws {
        for legacy in [nil, false, true] as [Bool?] {
            let suite = "TMDBPresentationPolicyTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let legacy { defaults.set(legacy, forKey: TMDBPresentationPreference.legacyKey) }
            let expected: TMDBPresentationPreference = legacy == false ? .original : .automatic
            XCTAssertEqual(TMDBPresentationPreference.load(defaults: defaults), expected)
            defaults.set(legacy != false, forKey: TMDBPresentationPreference.legacyKey)
            XCTAssertEqual(TMDBPresentationPreference.load(defaults: defaults), expected, "Migration must not overwrite the new preference")
        }
    }

    func testNewPreferenceWinsOverLegacyAndInvalidValueMigratesSafely() throws {
        let suite = "TMDBPresentationPolicyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: TMDBPresentationPreference.legacyKey)
        defaults.set("automatic", forKey: TMDBPresentationPreference.key)
        XCTAssertEqual(TMDBPresentationPreference.load(defaults: defaults), .automatic)
        defaults.set("invalid", forKey: TMDBPresentationPreference.key)
        XCTAssertEqual(TMDBPresentationPreference.load(defaults: defaults), .original)
    }

    func testBothLinksAndConfiguredEnabledServiceAreRequired() async {
        let health = TMDBAvailability()
        func decision(_ links: TMDBAvailabilitySnapshot?, preference: TMDBPresentationPreference = .automatic,
                      enabled: Bool = true, loading: Bool = false, credential: Bool = true) -> TMDBPresentationDecision {
            .evaluate(preference: preference, enabled: enabled, loadingCredential: loading, hasCredential: credential, links: links)
        }
        XCTAssertEqual(decision(nil), .unchecked)
        let unknown = await health.snapshot()
        XCTAssertFalse(decision(unknown).usesTMDB)
        await health.finish(health.ticket(.metadata), outcome: .success)
        let apiOnly = await health.snapshot()
        XCTAssertFalse(decision(apiOnly).usesTMDB)
        await health.finish(health.ticket(.images), outcome: .success)
        let ready = await health.snapshot()
        XCTAssertTrue(decision(ready).usesTMDB)
        XCTAssertEqual(decision(ready, preference: .original), .originalPreference)
        XCTAssertEqual(decision(ready, enabled: false), .serviceDisabled)
        XCTAssertEqual(decision(ready, loading: true), .loadingCredential)
        XCTAssertEqual(decision(ready, credential: false), .missingCredential)
        await health.finish(health.ticket(.metadata), outcome: .failure(.configuration))
        let rejected = await health.snapshot()
        XCTAssertEqual(decision(rejected), .connectionUnavailable)
        await health.networkChanged()
        await health.finish(health.ticket(.images), outcome: .success)
        let imagesOnly = await health.snapshot()
        XCTAssertFalse(decision(imagesOnly).usesTMDB)
    }

    func testExpiredEvidenceAndChangedNetworkCannotEnableAutomaticDetails() async {
        let clock = PresentationClock()
        let health = TMDBAvailability(now: { clock.value })
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.finish(health.ticket(.images), outcome: .success)
        clock.value = 181
        let expired = await health.snapshot()
        XCTAssertFalse(TMDBPresentationDecision.evaluate(preference: .automatic, enabled: true,
            loadingCredential: false, hasCredential: true, links: expired).usesTMDB)
        let staleTicket = await health.ticket(.metadata)
        await health.networkChanged()
        await health.finish(staleTicket, outcome: .success)
        let changed = await health.snapshot()
        XCTAssertFalse(changed.ready)
    }

    func testRetainedSnapshotCannotKeepExpiredSuccessAlive() async {
        let clock = PresentationClock()
        let health = TMDBAvailability(now: { clock.value })
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.finish(health.ticket(.images), outcome: .success)
        let retained = await health.snapshot()
        XCTAssertTrue(TMDBPresentationDecision.evaluate(preference: .automatic, enabled: true,
            loadingCredential: false, hasCredential: true, links: retained, now: 0).usesTMDB)
        XCTAssertFalse(TMDBPresentationDecision.evaluate(preference: .automatic, enabled: true,
            loadingCredential: false, hasCredential: true, links: retained, now: 181).usesTMDB)
    }

    func testCancellingProbesRetainsEvidenceAndServerBackoff() async {
        let health = TMDBAvailability()
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.finish(health.ticket(.images), outcome: .failure(.rateLimited, retryAfter: 120))
        await health.probe(.metadata, force: true) {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .cancelled }
            return .failure(.network)
        }
        await health.cancelProbes()
        let cancelled = await health.snapshot()
        XCTAssertFalse(cancelled.metadata.checking)
        XCTAssertEqual(cancelled.metadata.state, .available)
        XCTAssertEqual(cancelled.images.failure, .rateLimited)
    }

    func testCheckingCannotPromoteLayoutEvenWithPreviousSuccess() async {
        let health = TMDBAvailability()
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.finish(health.ticket(.images), outcome: .success)
        await health.probe(.images, force: true) {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .cancelled }
            return .success
        }
        let checking = await health.snapshot()
        XCTAssertEqual(TMDBPresentationDecision.evaluate(preference: .automatic, enabled: true,
            loadingCredential: false, hasCredential: true, links: checking), .checking)
        await health.networkChanged()
    }
}

private final class PresentationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); defer { lock.unlock() }; current = newValue }
    }
}
