import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlaybackLoadRaceTests: XCTestCase {
    private final class Gate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func source(_ name: String) -> PlaySource {
        PlaySource(name: name, episodes: (1...3).map { PlayEpisode(name: "E\($0).mp4", url: "fixture:\(name):\($0)") })
    }
    private func replacementDuringLoad(stage: String, close: Bool) async throws {
        let environment = try AppEnvironment.live()
        let app = AppState(environment: environment), first = source("First"), second = source("Second")
        await app.seedEpisodeNavigationForTesting(source: first, current: first.episodes[0])
        let gate = Gate(expectation(description: stage))
        app.resolvedPlaybackMediaLoadForTesting = {}
        app.resolvedPlaybackStageForTesting = { if $0 == stage { await gate.wait() } }
        let old = Task { () -> Bool in
            do { try await app.finishResolvedPlaybackForTesting(); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [gate.entered], timeout: 3)
        if close { await app.closePlayer() }
        else { await app.seedEpisodeNavigationForTesting(source: second, current: second.episodes[1], videoID: "replacement") }
        let expected = app.playbackPresentationID
        gate.release()
        let cancelled = await old.value
        XCTAssertTrue(cancelled, "Superseded load must finish as cancellation")
        XCTAssertEqual(app.playbackPresentationID, expected)
        XCTAssertEqual(app.isPlayerPresented, !close)
        XCTAssertEqual(app.currentPlayerEpisodeID, close ? nil : second.episodes[1].id)
        app.resolvedPlaybackStageForTesting = nil
        await app.closePlayer()
    }
    func testReplacementDuringRulesCannotRestoreOldRequest() async throws { try await replacementDuringLoad(stage: "rules", close: false) }
    func testCloseDuringRulesCannotReopenPlayer() async throws { try await replacementDuringLoad(stage: "rules", close: true) }
    func testReplacementDuringPreviousLeaseReleaseCannotCommitOldPlayback() async throws { try await replacementDuringLoad(stage: "previousLease", close: false) }
    func testCloseDuringPreviousLeaseReleaseCannotRestorePlayback() async throws { try await replacementDuringLoad(stage: "previousLease", close: true) }

    private func failureDuringLoad(replace: Bool, cancel: Bool = false) async throws {
        let app = AppState(environment: try AppEnvironment.live()), first = source("First"), second = source("Second")
        await app.seedEpisodeNavigationForTesting(source: first, current: first.episodes[0])
        let old = app.playbackPresentationID, retained = UUID()
        _ = app.seedTransferForTesting(owner: retained)
        let oldReceipt = app.seedTransferForTesting(owner: old, prepared: true)
        var cleaned: [UUID] = []
        app.transferCleanupForTesting = { cleaned.append($0) }
        let gate = Gate(expectation(description: "load is waiting"))
        app.resolvedPlaybackMediaLoadForTesting = {
            await gate.wait()
            if cancel { throw CancellationError() }
            throw AppError.playback("fixture load failure")
        }
        let load = Task { try? await app.finishResolvedPlaybackForTesting() }
        await fulfillment(of: [gate.entered], timeout: 3)
        if replace {
            await app.seedEpisodeNavigationForTesting(source: second, current: second.episodes[1], videoID: "replacement")
            _ = app.seedTransferForTesting(owner: app.playbackPresentationID)
        }
        let expected = replace || cancel ? app.playbackPresentationID : retained
        if cancel { load.cancel() }
        gate.release(); await load.value
        XCTAssertEqual(app.playbackPresentationID, expected)
        XCTAssertEqual(cleaned, [oldReceipt], "Only the failing operation's own receipt is cleaned")
        XCTAssertTrue(app.transferLeaseOwnersForTesting.contains(retained))
        if replace {
            XCTAssertEqual(app.currentPlayerEpisodeID, second.episodes[1].id)
            XCTAssertTrue(app.transferLeaseOwnersForTesting.contains(expected))
        }
        await app.closePlayer()
    }
    func testCurrentFailureRestoresCapturedPredecessor() async throws { try await failureDuringLoad(replace: false) }
    func testStaleFailureCannotRestorePredecessorOrReleaseReplacement() async throws { try await failureDuringLoad(replace: true) }
    func testCancelledLoadOnlyCleansItsOwnReceipt() async throws { try await failureDuringLoad(replace: true, cancel: true) }
}
