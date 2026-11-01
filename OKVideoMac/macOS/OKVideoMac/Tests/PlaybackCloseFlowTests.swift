import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlaybackCloseFlowTests: XCTestCase {
    private final class Gate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func source(_ name: String) -> PlaySource {
        PlaySource(name: name, episodes: (1...3).map {
            PlayEpisode(name: "E\($0).mp4", url: "fixture:\(name):\($0)")
        })
    }

    func testNewPlaybackSurvivesAnOlderSuspendedClose() async {
        let app = AppState(environment: nil), first = source("First"), second = source("Second")
        await app.seedEpisodeNavigationForTesting(source: first, current: first.episodes[0])
        let entered = expectation(description: "old close has retired its request")
        let gate = Gate(entered)
        app.playerCloseSuspensionForTesting = { await gate.wait() }
        let closing = Task { await app.closePlayer() }
        await fulfillment(of: [entered], timeout: 2)
        await app.seedEpisodeNavigationForTesting(source: second, current: second.episodes[1], videoID: "replacement")
        let replacement = app.playbackPresentationID
        app.playerCloseSuspensionForTesting = nil
        gate.release()
        await closing.value
        XCTAssertTrue(app.isPlayerPresented)
        XCTAssertEqual(app.playbackPresentationID, replacement)
        XCTAssertEqual(app.currentPlayerEpisodeID, second.episodes[1].id)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(second.episodes[2]))
        await app.closePlayer()
        XCTAssertFalse(app.isPlayerPresented)
    }

    func testConcurrentCloseWaitsForSingleTeardownAndThenReopens() async {
        let app = AppState(environment: nil), line = source("Line")
        await app.seedEpisodeNavigationForTesting(source: line, current: line.episodes[1])
        let entered = expectation(description: "first close reached suspension")
        let gate = Gate(entered)
        var teardownCount = 0
        app.playerCloseSuspensionForTesting = { teardownCount += 1; await gate.wait() }
        let first = Task { await app.closePlayer() }
        await fulfillment(of: [entered], timeout: 2)
        let secondStarted = expectation(description: "second close requested")
        var secondCompleted = false
        let second = Task {
            secondStarted.fulfill()
            await app.closePlayer()
            secondCompleted = true
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertFalse(secondCompleted, "A duplicate close must wait for the same teardown")
        XCTAssertEqual(teardownCount, 1)
        app.playerCloseSuspensionForTesting = nil
        gate.release()
        await first.value
        await second.value
        XCTAssertFalse(app.isPlayerPresented)
        XCTAssertTrue(app.playerEpisodes.isEmpty)
        await app.seedEpisodeNavigationForTesting(source: line, current: line.episodes[2])
        XCTAssertTrue(app.isPlayerPresented)
        XCTAssertTrue(app.hasPreviousEpisode)
        await app.closePlayer()
    }
}
