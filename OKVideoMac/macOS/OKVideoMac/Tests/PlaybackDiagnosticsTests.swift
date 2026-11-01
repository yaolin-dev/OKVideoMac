import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlaybackDiagnosticsTests: XCTestCase {
    func testNativePauseConfirmationIsIndependentAndRetiredRequestsCannotChangeIt() {
        let trace = PlaybackDiagnostics(), request = UUID(), replacement = UUID()
        trace.begin(sessionID: request, requestID: request, kind: .live)
        trace.observePlaybackState(requestID: request, paused: false)
        trace.observePlaybackState(requestID: request, paused: true)
        trace.observePlaybackState(requestID: request, paused: true)
        trace.observePlaybackState(requestID: request, paused: false)
        XCTAssertEqual(trace.snapshot()[0].events.map(\.stage), [.requested, .paused, .resumed])
        trace.begin(sessionID: request, requestID: replacement, kind: .live, retry: .user)
        trace.observePlaybackState(requestID: request, paused: true)
        trace.observePlaybackState(requestID: replacement, paused: false)
        XCTAssertEqual(trace.snapshot()[0].events.last?.stage, .retry)
        trace.observePlaybackState(requestID: replacement, paused: true)
        XCTAssertEqual(trace.snapshot()[0].events.last?.stage, .paused)
        trace.record(requestID: replacement, stage: .closed)
        trace.observePlaybackState(requestID: replacement, paused: false)
        XCTAssertEqual(trace.snapshot()[0].events.last?.stage, .closed)
    }
    func testDurationsRetryAndRetiredRequests() {
        var time: TimeInterval = 10
        let trace = PlaybackDiagnostics(clock: { time })
        let session = UUID(), first = UUID(), retry = UUID()
        trace.begin(sessionID: session, requestID: first, kind: .onDemand)
        time = 11; trace.record(requestID: first, stage: .resolved)
        time = 13; trace.begin(sessionID: session, requestID: retry, kind: .onDemand, retry: .user)
        trace.record(requestID: first, stage: .failed, failure: .network)
        time = 14; trace.record(requestID: retry, stage: .firstFrame)
        let value = trace.snapshot()[0]
        XCTAssertEqual(value.events.map(\.stage), [.requested, .resolved, .retry, .firstFrame])
        XCTAssertEqual(value.events.map(\.stageMilliseconds), [0, 1000, 2000, 1000])
        XCTAssertEqual(value.events.last?.elapsedMilliseconds, 4000)
        XCTAssertEqual(value.events[2].retry, .user)
        trace.record(requestID: retry, stage: .closed)
        trace.record(requestID: retry, stage: .failed, failure: .player)
        XCTAssertEqual(trace.snapshot()[0].events.last?.stage, .closed)
    }
    func testExplicitRetryKeepsOneTraceAndRepeatedInitialBeginIsIdempotent() {
        let trace = PlaybackDiagnostics(), first = UUID(), retry = UUID()
        trace.begin(sessionID: first, requestID: first, kind: .onDemand)
        trace.begin(sessionID: first, requestID: first, kind: .onDemand)
        XCTAssertEqual(trace.snapshot()[0].events.count, 1)
        trace.record(requestID: first, stage: .failed, failure: .network)
        trace.begin(sessionID: retry, requestID: retry, kind: .onDemand, retry: .user, continuingFrom: first)
        trace.record(requestID: retry, stage: .firstFrame)
        XCTAssertEqual(trace.snapshot().count, 1)
        XCTAssertEqual(trace.snapshot()[0].sessionID, first)
        XCTAssertEqual(trace.snapshot()[0].currentRequestID, retry)
        XCTAssertEqual(trace.snapshot()[0].events.map(\.stage), [.requested, .failed, .retry, .firstFrame])
    }
    func testBoundsPreserveFirstAndLatestAndSupersedeOldSession() {
        let trace = PlaybackDiagnostics(maximumSessions: 2, maximumEvents: 4)
        let first = UUID()
        trace.begin(sessionID: first, requestID: first, kind: .live)
        for _ in 0..<20 {
            trace.record(requestID: first, stage: .paused)
            trace.record(requestID: first, stage: .resumed)
        }
        XCTAssertEqual(trace.snapshot()[0].events.count, 4)
        XCTAssertEqual(trace.snapshot()[0].events.first?.stage, .requested)
        XCTAssertEqual(trace.snapshot()[0].droppedEvents, 37)
        let second = UUID(); trace.begin(sessionID: second, requestID: second, kind: .catchup)
        XCTAssertEqual(trace.snapshot()[0].events.last?.stage, .superseded)
        let third = UUID(); trace.begin(sessionID: third, requestID: third, kind: .onDemand)
        XCTAssertEqual(trace.snapshot().map(\.sessionID), [second, third])
    }
    func testClassificationAndSerializedSchemaNeverCopyErrorPayload() throws {
        let trace = PlaybackDiagnostics(), request = UUID()
        trace.begin(sessionID: request, requestID: request, kind: .onDemand)
        let secret = "https://user:SECRET_TOKEN@example.invalid/path?cookie=SECRET_TOKEN"
        trace.record(requestID: request, stage: .failed, failure: .classify(AppError.playback(secret)))
        let data = try JSONEncoder().encode(trace.snapshot())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET_TOKEN"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("example.invalid"))
        XCTAssertEqual(PlaybackDiagnostics.Failure.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(PlaybackDiagnostics.Failure.classify(HTTPClientError.statusCode(403)), .authorization)
        XCTAssertEqual(PlaybackDiagnostics.Failure.classify(CancellationError()), .cancelled)
        XCTAssertEqual(PlaybackDiagnostics.Failure.classify(AppError.database(secret)), .database)
    }
}
