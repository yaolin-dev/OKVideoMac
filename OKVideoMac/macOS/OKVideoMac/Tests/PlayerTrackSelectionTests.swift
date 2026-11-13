import AppKit
import Combine
import XCTest
import CSQLite
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class PlayerTrackSelectionTests: XCTestCase {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Selection did not reach the expected boundary")
        throw CancellationError()
    }
    private func track(_ id: Int, selected: Bool = false, type: MediaTrackType = .subtitle) -> MediaTrack {
        .init(id: id, type: type, title: "Track \(id)", isSelected: selected)
    }

    func testBurstReturningToConfirmedTrackDoesNotTouchDecoder() async {
        let coordinator = PlayerTrackSelectionCoordinator(), owner = UUID()
        var commands: [Int] = [], commits: [Int] = []
        var last: Task<Void, Never>!
        for id in [2, 3, 2, 1] {
            last = coordinator.submit(owner: owner, type: .audio, trackID: id, confirmedID: 1,
                execute: { commands.append($0.trackID!) }, commit: { commits.append($0.trackID!) }, failed: { _ in XCTFail() })
        }
        await last.value
        XCTAssertEqual(commands, [])
        XCTAssertEqual(commits, [1])
    }

    func testExecutingSwitchKeepsOnlyLastPendingChoiceAndIgnoresDuplicate() async throws {
        let coordinator = PlayerTrackSelectionCoordinator(), owner = UUID()
        var release: CheckedContinuation<Void, Never>?
        var commands: [Int] = [], commits: [Int] = []
        let execute: (PlaybackTrackSelectionToken) async throws -> Void = { token in
            commands.append(token.trackID!)
            if token.trackID == 2 { await withCheckedContinuation { release = $0 } }
        }
        func submit(_ id: Int) -> Task<Void, Never> {
            coordinator.submit(owner: owner, type: .audio, trackID: id, confirmedID: 1,
                execute: execute, commit: { commits.append($0.trackID!) }, failed: { _ in XCTFail() })
        }
        let first = submit(2)
        try await until { release != nil }
        _ = submit(3); _ = submit(4); let duplicate = submit(4)
        release?.resume()
        await duplicate.value; await first.value
        XCTAssertEqual(commands, [2, 4])
        XCTAssertEqual(commits, [4])
        await submit(4).value // Native disagreement must allow retry after an asynchronous engine failure.
        XCTAssertEqual(commands, [2, 4, 4])
    }

    func testABAReusesAlreadyExecutingAWithoutCommittingObsoleteRequest() async throws {
        let c = PlayerTrackSelectionCoordinator(), owner = UUID()
        var release: CheckedContinuation<Void, Never>?, commands: [Int] = [], commits: [Int] = []
        func submit(_ id: Int) -> Task<Void, Never> {
            c.submit(owner: owner, type: .subtitle, trackID: id, confirmedID: 1,
                execute: { token in commands.append(token.trackID!); await withCheckedContinuation { release = $0 } },
                commit: { commits.append($0.trackID!) }, failed: { _ in XCTFail() })
        }
        let a = submit(2)
        try await until { release != nil }
        _ = submit(3); let latest = submit(2)
        release?.resume()
        await latest.value; await a.value
        XCTAssertEqual(commands, [2]); XCTAssertEqual(commits, [2])
    }

    func testSessionChangeRejectsOldCompletionAndPendingCommands() async throws {
        let c = PlayerTrackSelectionCoordinator(), old = UUID(), next = UUID()
        var release: CheckedContinuation<Void, Never>?, oldToken: PlaybackTrackSelectionToken?
        var commands: [UUID] = [], commits: [UUID] = [], errors = 0
        func submit(_ owner: UUID, _ id: Int) -> Task<Void, Never> {
            c.submit(owner: owner, type: .subtitle, trackID: id, confirmedID: 1,
                execute: { token in
                    commands.append(token.requestID)
                    if token.requestID == old {
                        oldToken = token
                        await withCheckedContinuation { release = $0 }
                        throw NSError(domain: "obsolete", code: 1)
                    }
                }, commit: { commits.append($0.requestID) }, failed: { _ in errors += 1 })
        }
        let first = submit(old, 2)
        try await until { release != nil }
        _ = submit(old, 3)
        c.reset(owner: next)
        let last = submit(next, 2)
        XCTAssertFalse(try XCTUnwrap(oldToken).isValid)
        release?.resume(); await first.value; await last.value
        XCTAssertEqual(commands, [old, next]); XCTAssertEqual(commits, [next]); XCTAssertEqual(errors, 0)
    }

    func testAudioAndSubtitleHaveIndependentPendingSlots() async throws {
        let c = PlayerTrackSelectionCoordinator(), owner = UUID()
        var release: CheckedContinuation<Void, Never>?, subtitleCommitted = false
        let audio = c.submit(owner: owner, type: .audio, trackID: 2, confirmedID: 1,
            execute: { _ in await withCheckedContinuation { release = $0 } }, commit: { _ in }, failed: { _ in XCTFail() })
        try await until { release != nil }
        let subtitle = c.submit(owner: owner, type: .subtitle, trackID: 3, confirmedID: -1,
            execute: { _ in }, commit: { _ in subtitleCommitted = true }, failed: { _ in XCTFail() })
        await subtitle.value
        XCTAssertTrue(subtitleCommitted)
        release?.resume(); await audio.value
    }

    func testExplicitToggleIntentAndSelectionPublishOnlyToSubtitleControls() async throws {
        let app = AppState(environment: nil), owner = UUID()
        let tracks = [track(1, selected: true), track(2)]
        app.configureTrackSelectionForTesting(owner: owner, tracks: tracks)
        var commands: [Int] = [], saved: [Int] = [], global = 0, local = 0
        app.trackSelectionExecutorForTesting = { commands.append($0.trackID!) }
        app.trackPreferenceWriterForTesting = { enabled, track, token in
            try token.checkValidity(); saved.append(enabled ? track!.id : -1)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let a = app.objectWillChange.sink { global += 1 }
        let b = app.playerSubtitleState.objectWillChange.sink { local += 1 }
        _ = app.requestPlayerTrack(tracks[1])
        _ = app.requestPlayerSubtitlesEnabled(false)
        let last = app.requestPlayerSubtitlesEnabled(true)
        XCTAssertTrue(app.playerSubtitlesEnabled)
        XCTAssertEqual(app.selectedPlayerSubtitleTrackID, 2)
        await last.value
        XCTAssertEqual(commands, [2]); XCTAssertEqual(saved, [2])
        XCTAssertEqual(global, 0); XCTAssertGreaterThan(local, 0)
        withExtendedLifetime((a,b)) {}
        await app.closePlayer()
    }

    func testAppOldCallbackCannotWritePreferenceOrOverrideNextSession() async throws {
        let app = AppState(environment: nil), old = UUID(), next = UUID()
        let tracks = [track(1, selected: true), track(2), track(3)]
        app.configureTrackSelectionForTesting(owner: old, tracks: tracks)
        var release: CheckedContinuation<Void, Never>?, saved: [UUID] = []
        app.trackSelectionExecutorForTesting = { token in
            if token.requestID == old { await withCheckedContinuation { release = $0 } }
        }
        app.trackPreferenceWriterForTesting = { _, _, token in
            try token.checkValidity(); saved.append(token.requestID)
        }
        let first = app.requestPlayerTrack(tracks[1])
        try await until { release != nil }
        app.configureTrackSelectionForTesting(owner: next, tracks: tracks)
        let latest = app.requestPlayerTrack(tracks[2])
        release?.resume(); await first.value; await latest.value
        XCTAssertEqual(saved, [next]); XCTAssertEqual(app.selectedPlayerSubtitleTrackID, 3)
        await app.closePlayer()
    }

    func testFailureRestoresObservedSelectionAndAllowsRetry() async {
        let app = AppState(environment: nil), owner = UUID()
        let tracks = [track(1, selected: true), track(2)]
        app.configureTrackSelectionForTesting(owner: owner, tracks: tracks)
        var calls = 0, saves = 0
        app.trackSelectionExecutorForTesting = { _ in
            calls += 1
            if calls == 1 { throw CancellationError() }
        }
        app.trackPreferenceWriterForTesting = { _, _, _ in saves += 1 }
        await app.requestPlayerTrack(tracks[1]).value
        XCTAssertEqual(app.selectedPlayerSubtitleTrackID, 1)
        XCTAssertEqual(saves, 0)
        await app.requestPlayerTrack(tracks[1]).value
        XCTAssertEqual(app.selectedPlayerSubtitleTrackID, 2)
        XCTAssertEqual(calls, 2); XCTAssertEqual(saves, 1)
        await app.closePlayer()
    }

    func testDatabaseRejectsRetiredSelectionAndStoresPairAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("track-db-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let old = PlaybackTrackSelectionToken(requestID: UUID(), type: .subtitle, trackID: 1)
        old.invalidate()
        do {
            try await db.setPlaybackSubtitlePreference(enabled: true, track: .string("old"), selection: old)
            XCTFail("Retired database work must be rejected")
        } catch is CancellationError { }
        let empty = try await db.setting(forKey: "playback.subtitlesEnabled")
        XCTAssertNil(empty)
        let current = PlaybackTrackSelectionToken(requestID: UUID(), type: .subtitle, trackID: 2)
        try await db.setPlaybackSubtitlePreference(enabled: false, track: .string("latest"), selection: current)
        let enabled = try await db.setting(forKey: "playback.subtitlesEnabled")
        let selected = try await db.setting(forKey: "playback.subtitleTrack")
        XCTAssertEqual(enabled, .bool(false)); XCTAssertEqual(selected, .string("latest"))
    }
    func testRetirementWhileWaitingForDatabaseLockPreventsCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("track-db-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let db = try SQLiteStore(databaseURL: url)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let token = PlaybackTrackSelectionToken(requestID: UUID(), type: .subtitle, trackID: 2)
        let write = Task {
            try await db.setPlaybackSubtitlePreference(enabled: true, track: .string("retired"), selection: token)
        }
        // The database actor is waiting on another connection's writer lock.
        try await Task.sleep(nanoseconds: 150_000_000)
        token.invalidate()
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        do { try await write.value; XCTFail("Retired intent committed after waiting for the writer lock") }
        catch is CancellationError { }
        let stored = try await db.setting(forKey: "playback.subtitlesEnabled")
        XCTAssertNil(stored)
    }

    func testPreferenceFailureCanRetryWithoutRebuildingSelectedTrack() async {
        let app = AppState(environment: nil), owner = UUID()
        let tracks = [track(1, selected: true), track(2)]
        app.configureTrackSelectionForTesting(owner: owner, tracks: tracks)
        var commands = 0, writes = 0
        app.trackSelectionExecutorForTesting = { _ in commands += 1 }
        app.trackPreferenceWriterForTesting = { _, _, _ in
            writes += 1
            if writes == 1 { throw NSError(domain: "fixture-store", code: 1) }
        }
        await app.requestPlayerTrack(tracks[1]).value
        app.configureTrackSelectionForTesting(owner: owner, tracks: [track(1), track(2, selected: true)])
        await app.requestPlayerTrack(tracks[1]).value
        XCTAssertEqual(commands, 1); XCTAssertEqual(writes, 2)
        await app.closePlayer()
    }

}
