import XCTest
import OKVideoCore
@testable import OKVideoMac

/// AppState integration journeys. Fixtures substitute the provider/decoder;
/// these assertions do not claim to test real network playback or pixels.
@MainActor final class PlaybackUserFlowTests: XCTestCase {
    private let motion = ["video-dec-params/w": "1920", "video-dec-params/h": "1080",
        "current-tracks/video/codec": "h264", "container-fps": "25",
        "current-tracks/video/image": "no", "current-tracks/video/albumart": "no"]

    private func source() -> PlaySource {
        PlaySource(name: "夸克原画", episodes: (1...16).map {
            PlayEpisode(name: "[2.6GB]E\($0).mp3【小程量房2026】", url: "fixture:\($0)")
        })
    }

    func testVideoEvidenceCloseReopenAndLateCallbacksStayInTheirSession() async {
        let app = AppState(environment: nil), line = source()
        await app.seedEpisodeNavigationForTesting(source: line, current: line.episodes[10])
        let first = app.playbackPresentationID
        app.observeEpisodeVideoForTesting(motion, requestID: first)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: -1), .available(line.episodes[9]))
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(line.episodes[11]))
        await app.closePlayer()
        XCTAssertFalse(app.isPlayerPresented)
        XCTAssertFalse(app.hasNextEpisode)
        app.observeEpisodeVideoForTesting(motion, requestID: first)
        XCTAssertTrue(app.playerEpisodes.isEmpty)
        await app.seedEpisodeNavigationForTesting(source: line, current: line.episodes[11])
        XCTAssertNotEqual(app.playbackPresentationID, first)
        app.observeEpisodeVideoForTesting(motion, requestID: first)
        XCTAssertFalse(app.hasNextEpisode, "Previous decoded-video evidence cannot authorize the new queue")
        app.observeEpisodeVideoForTesting(motion, requestID: app.playbackPresentationID)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(line.episodes[12]))
        await app.closePlayer()
    }

    func testRepeatedCloseAndReopenInvalidateEveryOldEpisodeSelection() async {
        let app = AppState(environment: nil), line = source()
        var previousSelections: [UUID] = []
        for index in 0..<20 {
            let current = line.episodes[index % line.episodes.count]
            await app.seedEpisodeNavigationForTesting(source: line, current: current)
            for old in previousSelections {
                XCTAssertNotEqual(app.playerEpisodeSelectionSessionID, old)
                await app.playPlayerEpisode(line.episodes[0], expectedSessionID: old)
                XCTAssertEqual(app.currentPlayerEpisodeID, current.id)
            }
            previousSelections.append(app.playerEpisodeSelectionSessionID)
            await app.closePlayer()
            await app.closePlayer()
            XCTAssertNotEqual(app.playerEpisodeSelectionSessionID, previousSelections.last!)
            XCTAssertFalse(app.isPlayerPresented)
            XCTAssertNil(app.currentPlayerEpisodeID)
            XCTAssertNil(app.playerEpisodeNavigationChoice)
            XCTAssertFalse(app.hasPreviousEpisode)
            XCTAssertFalse(app.hasNextEpisode)
        }
    }

    func testCloseDuringQueuePreparationDoesNotLeakIntoFollowingVideo() async {
        let app = AppState(environment: nil), line = source()
        await app.seedEpisodeNavigationForTesting(source: line, current: line.episodes[10], waitForPreparation: false)
        let old = app.playbackPresentationID
        await app.closePlayer()
        let replacement = PlaySource(name: "Replacement", episodes: (1...3).map {
            PlayEpisode(name: "E\($0).mp4", url: "fixture:new:\($0)")
        })
        await app.seedEpisodeNavigationForTesting(source: replacement, current: replacement.episodes[1], videoID: "new-video")
        app.observeEpisodeVideoForTesting(motion, requestID: old)
        XCTAssertEqual(app.playerEpisodes, replacement.episodes)
        XCTAssertEqual(app.playerEpisodeNavigation(offset: 1), .available(replacement.episodes[2]))
        XCTAssertEqual(Set(app.playerEpisodePresentations.map(\.id)), Set(replacement.episodes.map(\.id)))
        await app.closePlayer()
    }
}
