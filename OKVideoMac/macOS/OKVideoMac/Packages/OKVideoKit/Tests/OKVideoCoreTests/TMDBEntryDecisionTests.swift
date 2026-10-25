import XCTest
@testable import OKVideoCore

final class TMDBEntryDecisionTests: XCTestCase {
    func testDeadlineDoesNotResetAndLateSuccessCannotChangeSourceMode() async {
        let health = TMDBAvailability()
        var decision = TMDBEntryDecision(startedAt: 100, budget: 1.2)
        decision.evaluate(enabled: true, links: await health.snapshot(), workReady: false, noMatch: false, now: 101.21)
        XCTAssertEqual(decision.mode, .source); XCTAssertEqual(decision.reason, "deadline")
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.finish(health.ticket(.images), outcome: .success)
        decision.evaluate(enabled: true, links: await health.snapshot(), workReady: true, noMatch: false, now: 102)
        XCTAssertEqual(decision.mode, .source)
    }
    func testVerifiedWorkDoesNotNeedLiveNetworkEvidence() async {
        let health = TMDBAvailability()
        await health.finish(health.ticket(.images), outcome: .failure(.network))
        var decision = TMDBEntryDecision(startedAt: 100)
        decision.evaluate(enabled: true, links: await health.snapshot(), workReady: true, noMatch: false, now: 100.1)
        XCTAssertEqual(decision.mode, .enhanced)
    }

    func testBudgetCancelsInFlightTransport() async throws {
        let budget = TMDBRequestBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.04)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await budget.perform { try await Task.sleep(nanoseconds: 2_000_000_000); return 1 }
            XCTFail("Preparation exceeded its bound")
        } catch { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5) }
    }

    func testFourRequestBudgetIsSharedAndDoesNotExtendDeadline() async throws {
        let budget = TMDBRequestBudget(deadline: ProcessInfo.processInfo.systemUptime + 1)
        try await budget.admit(search: true); try await budget.admit(search: true)
        do { try await budget.admit(search: true); XCTFail() } catch {}
        try await budget.admit(search: false); try await budget.admit(search: false)
        do { try await budget.admit(search: false); XCTFail() } catch {}
        let expired = TMDBRequestBudget(deadline: 0)
        do { try await expired.admit(search: true); XCTFail() } catch {}
    }
}
