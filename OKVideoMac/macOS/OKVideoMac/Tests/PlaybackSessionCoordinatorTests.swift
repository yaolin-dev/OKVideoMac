import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlaybackSessionCoordinatorTests: XCTestCase {
    private func recovery() -> Task<Void, Never> {
        Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
    }

    private func preparation() -> Task<HLSStartupSelection?, Error> {
        Task { try await Task.sleep(nanoseconds: 60_000_000_000); return nil }
    }

    func testReplacementCancelsOldWorkWithoutChangingTheEpisodeSession() async {
        let state = PlaybackSessionCoordinator(), node = recovery(), hls = preparation()
        let session = state.sessionID, oldRequest = state.requestID
        state.nodeRecoveryTask = node
        state.hlsPreparation = (oldRequest, hls)
        XCTAssertTrue(state.replaceRequest(with: UUID()))
        XCTAssertEqual(state.sessionID, session, "A retry may retain the episode session")
        XCTAssertTrue(node.isCancelled)
        XCTAssertTrue(hls.isCancelled)
        XCTAssertNil(state.nodeRecoveryTask)
        XCTAssertNil(state.hlsPreparation)
        await node.value
        _ = try? await hls.value
    }

    func testSameRequestDoesNotCancelItsOwnPreparation() async {
        let state = PlaybackSessionCoordinator(), node = recovery(), hls = preparation()
        state.nodeRecoveryTask = node
        state.hlsPreparation = (state.requestID, hls)
        XCTAssertFalse(state.replaceRequest(with: state.requestID))
        XCTAssertFalse(node.isCancelled)
        XCTAssertFalse(hls.isCancelled)
        state.replaceRequest(with: UUID())
        await node.value
        _ = try? await hls.value
    }

    func testLateRecoveryCompletionCannotClearReplacementWork() async {
        let state = PlaybackSessionCoordinator(), old = state.requestID
        state.replaceRequest(with: UUID())
        let task = recovery()
        state.nodeRecoveryTask = task
        state.finishNodeRecovery(requestID: old)
        XCTAssertNotNil(state.nodeRecoveryTask)
        XCTAssertFalse(task.isCancelled)
        state.finishNodeRecovery(requestID: state.requestID)
        XCTAssertNil(state.nodeRecoveryTask)
        task.cancel()
        await task.value
    }

    func testConcurrentCloseJoinsAndStaleCompletionCannotFinishANewClose() async throws {
        let state = PlaybackSessionCoordinator()
        let first = try XCTUnwrap(state.beginClose())
        XCTAssertNil(state.beginClose())
        var completions = 0
        let waiters = (0..<3).map { _ in Task { @MainActor in
            await state.waitForClose()
            completions += 1
        } }
        await Task.yield()
        state.finishClose(UUID())
        XCTAssertTrue(state.isClosing)
        XCTAssertEqual(completions, 0)
        state.finishClose(first)
        for waiter in waiters { await waiter.value }
        XCTAssertEqual(completions, 3)
        let second = try XCTUnwrap(state.beginClose())
        state.finishClose(first)
        XCTAssertTrue(state.isClosing)
        state.finishClose(second)
        XCTAssertFalse(state.isClosing)
    }

    func testCloseTransitionRequiresBothRequestAndSessionOwnership() {
        let state = PlaybackSessionCoordinator(), first = UUID(), second = UUID()
        state.sessionID = first
        state.replaceRequest(with: first)
        XCTAssertTrue(state.ownsTransition(first))
        state.replaceRequest(with: second)
        XCTAssertFalse(state.ownsTransition(first))
        XCTAssertFalse(state.ownsTransition(second))
        state.sessionID = second
        XCTAssertTrue(state.ownsTransition(second))
    }

    func testCoordinatorReleaseCancelsOutstandingWork() async {
        var state: PlaybackSessionCoordinator? = PlaybackSessionCoordinator()
        let node = recovery(), hls = preparation()
        state?.nodeRecoveryTask = node
        state?.hlsPreparation = (state!.requestID, hls)
        state = nil
        XCTAssertTrue(node.isCancelled)
        XCTAssertTrue(hls.isCancelled)
        await node.value
        _ = try? await hls.value
    }
}
