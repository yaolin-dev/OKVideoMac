import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlayerSeekStabilityTests: XCTestCase {
    private func sample(_ position: Double, id: UUID? = nil, target: Double = 300,
                        phase: PlayerSeekTransaction.Phase = .pending) -> PlayerSnapshot {
        var value = PlayerSnapshot(status: .playing, position: position, duration: 600,
                                   isSeeking: phase == .pending && id != nil)
        if let id { value.seekTransaction = .init(id: id, target: target, phase: phase) }
        return value
    }
    func testCommandAcceptanceAndOldPositionsCannotReleaseTarget() {
        let state = PlayerSnapshotState(snapshot: sample(20)), id = UUID()
        state.beginSeek(id: id, target: 300)
        for position in [20.0, 20.1, 20.2, 299.0] {
            state.update(sample(position, id: id))
            XCTAssertEqual(state.displayedPosition, 300)
            XCTAssertEqual(state.pendingSeekTarget, 300)
            XCTAssertEqual(state.snapshot.position, position, "Real history time must never be replaced with UI intent")
        }
        state.update(sample(300.03, id: id, phase: .completed))
        XCTAssertNil(state.pendingSeekTarget)
        XCTAssertEqual(state.displayedPosition, 300.03)
        state.update(sample(300.13, id: id, phase: .completed))
        XCTAssertEqual(state.displayedPosition, 300.13)
    }
    func testRepeatedSameTargetAndLateFailureBelongToTheirOperation() {
        let state = PlayerSnapshotState(snapshot: sample(20)), first = UUID(), last = UUID()
        state.beginSeek(id: first, target: 300)
        state.beginSeek(id: last, target: 300)
        state.update(sample(300, id: first, phase: .completed))
        state.failSeek(id: first)
        var oldFailure = sample(20, id: first, phase: .failed)
        oldFailure.status = .failed("Superseded network failure")
        state.update(oldFailure)
        XCTAssertEqual(state.snapshot.status, .playing, "Old errors must not flash over the new operation")
        XCTAssertEqual(state.pendingSeekTarget, 300)
        XCTAssertEqual(state.requestedSeek?.id, last)
        state.update(sample(300.02, id: last, phase: .completed))
        XCTAssertNil(state.pendingSeekTarget)
        state.update(sample(21, id: first))
        state.update(sample(21, id: last))
        XCTAssertEqual(state.displayedPosition, 300.02, "Queued old and pending events cannot undo confirmation")
    }
    func testLatestTargetWinsAcrossRapidForwardAndBackwardSeeks() {
        let state = PlayerSnapshotState(snapshot: sample(20))
        let operations = [UUID(), UUID(), UUID()]
        for (id, target) in zip(operations, [300.0, 400, 100]) { state.beginSeek(id: id, target: target) }
        for id in operations.dropLast() {
            state.update(sample(400, id: id, phase: .completed))
            XCTAssertEqual(state.displayedPosition, 100)
        }
        state.update(sample(100, id: operations.last!, target: 100, phase: .completed))
        XCTAssertEqual(state.displayedPosition, 100)
        XCTAssertNil(state.pendingSeekTarget)
    }
    func testFailureAndReplacementReleaseOnlyCurrentPresentation() {
        let state = PlayerSnapshotState(snapshot: sample(20)), id = UUID()
        state.beginSeek(id: id, target: 300)
        state.failSeek(id: id)
        XCTAssertNil(state.pendingSeekTarget)
        XCTAssertEqual(state.displayedPosition, 20)
        state.beginSeek(id: UUID(), target: 400)
        state.resetSeek()
        state.update(sample(0))
        XCTAssertNil(state.requestedSeek)
        XCTAssertEqual(state.displayedPosition, 0)
    }
    func testNativeCompletionAcceptsAdvancingTimeButRejectsBusyOrOldSeek() {
        XCTAssertTrue(PlayerSeekCompletionPolicy.accepts(target: 300, position: 295, nativeSeeking: false, pausedForCache: false, seekRestarted: true))
        for flags in [(true, false, true), (false, true, true), (false, false, false)] {
            XCTAssertFalse(PlayerSeekCompletionPolicy.accepts(target: 300, position: 300, nativeSeeking: flags.0, pausedForCache: flags.1, seekRestarted: flags.2))
        }
        XCTAssertTrue(PlayerSeekCompletionPolicy.accepts(target: 300, position: 300.04, nativeSeeking: false, pausedForCache: false, seekRestarted: true))
        // Regression: the reported 4K stream resumed past the requested time.
        // Native completion must hand the UI its actual frame, not wait forever
        // for a timestamp that playback has already passed.
        let state = PlayerSnapshotState(snapshot: sample(9.206)), id = UUID()
        state.beginSeek(id: id, target: 468.873)
        XCTAssertTrue(PlayerSeekCompletionPolicy.accepts(target: 468.873, position: 482.526,
            nativeSeeking: false, pausedForCache: false, seekRestarted: true))
        state.update(sample(482.526, id: id, target: 468.873, phase: .completed))
        XCTAssertNil(state.pendingSeekTarget)
        XCTAssertEqual(state.displayedPosition, 482.526)
        for format in [nil, "mov", "hls"] as [String?] {
            XCTAssertEqual(MPVPlayerClient.seekCommand(to: 300.125, demuxerFormat: format), ["seek", "300.125", "absolute+keyframes"])
        }
        XCTAssertEqual(MPVPlayerClient.seekCommand(to: 300.125, demuxerFormat: "dash"), ["seek", "300.125", "absolute+exact"])
    }
}
