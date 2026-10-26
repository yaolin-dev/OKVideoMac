import XCTest
import Darwin
import OKVideoCore
@testable import OKVideoPersistence

final class EPGCacheStoreTests: XCTestCase {
    private var directory: URL!
    private var store: EPGCacheStore!
    private var key: EPGRequestKey!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/EPGCache-" + UUID().uuidString)
        store = try EPGCacheStore(directory: directory)
        key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "a", count: 64), resource: "xmltv")
    }
    override func tearDownWithError() throws {
        store?.close(); store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func record(_ n: Int, title: String = "节目😀", channel: String = "undeclared") -> EPGCacheRecord {
        EPGCacheRecord(ordinal: n, programme: EPGProgramme(channelID: channel, title: title,
            start: Date(timeIntervalSince1970: Double(n) * 60), end: Date(timeIntervalSince1970: Double(n + 1) * 60)))
    }
    private func seal(_ h: EPGCacheImportHandle, count: Int, raw: Int? = nil,
                      channelRecords: Int = 0) throws {
        try store.validate(h, summary: EPGCacheValidation(rawProgrammeCount: raw ?? count,
            emittedProgrammeCount: count,
            minimumStart: count == 0 ? nil : Date(timeIntervalSince1970: 0),
            maximumEnd: count == 0 ? nil : Date(timeIntervalSince1970: Double(count) * 60),
            emittedChannelRecordCount: channelRecords))
    }
    private func db() throws -> EPGCacheDatabase { try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite")) }
    private func publish(count: Int = 1) throws -> EPGCacheImportHandle {
        let h = try store.begin(key)
        if count > 0 { try store.append((0..<count).map { record($0) }, to: h) }
        try seal(h, count: count)
        _ = try store.activate(h)
        return h
    }
    private func assertError(_ expected: EPGCacheError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? EPGCacheError, expected, file: file, line: line)
        }
    }

    func testStagingInvisibleAndActivationSurvivesReopen() throws {
        let h = try store.begin(key)
        try store.append([record(0), record(1)], to: h)
        XCTAssertNil(try store.activeIdentity(for: key))
        try seal(h, count: 2)
        XCTAssertNil(try store.activeIdentity(for: key))
        let active = try store.activate(h)
        store.close(); store = try EPGCacheStore(directory: directory)
        XCTAssertEqual(try store.activeIdentity(for: key), active)
        assertError(.invalidHandle) { try store.abandon(h) }
    }

    func testSupersededWriterCannotAppendValidateOrActivate() throws {
        let a = try store.begin(key)
        try store.append([record(0)], to: a)
        try seal(a, count: 1)
        let b = try store.begin(key)
        assertError(.superseded) { try store.append([record(1)], to: a) }
        assertError(.superseded) { try seal(a, count: 1) }
        assertError(.superseded) { _ = try store.activate(a) }
        try store.abandon(a)
        try seal(b, count: 0)
        XCTAssertEqual(try store.activate(b).programmeCount, 0)
    }

    func testCancelBeforeActivationAndLateCancelAfterCommit() throws {
        let old = try publish()
        let h = try store.begin(key)
        try seal(h, count: 0)
        try store.abandon(h); try store.abandon(h)
        assertError(.superseded) { _ = try store.activate(h) }
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, old.generation)
        let new = try publish(count: 2)
        try store.abandon(new)
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, new.generation)
        assertError(.superseded) { _ = try store.activate(new) }
    }

    func testSourceEpochAndRevisionRevokeOldWork() throws {
        let h = try store.begin(key)
        try seal(h, count: 0)
        try store.setSourceEnabled(key.source, enabled: false)
        assertError(.superseded) { _ = try store.activate(h) }
        assertError(.superseded) { _ = try store.begin(key) }
        try store.setSourceEnabled(key.source, enabled: true)
        _ = try publish()
        let a = try store.begin(key)
        let other = EPGRequestKey(source: .imported(key.source.id), revision: String(repeating: "b", count: 64), resource: "xmltv")
        _ = try store.begin(other)
        assertError(.superseded) { try store.append([record(0)], to: a) }
        XCTAssertNil(try store.activeIdentity(for: key))
    }

    func testSealedGenerationRejectsMutationAndMetadataMismatch() throws {
        let h = try store.begin(key)
        try store.append([record(0)], to: h)
        assertError(.validationFailed) { try seal(h, count: 2) }
        assertError(.invalidState) { _ = try store.activate(h) }
        try seal(h, count: 1)
        assertError(.invalidState) { try store.append([record(1)], to: h) }
        _ = try store.activate(h)
    }

    func testRawOrdinalsMayHaveGapsButNotDuplicatesOrRegression() throws {
        let h = try store.begin(key)
        try store.append([record(2)], to: h)
        assertError(.budgetExceeded) { try store.append([record(2)], to: h) }
        try store.validate(h, summary: EPGCacheValidation(rawProgrammeCount: 3, emittedProgrammeCount: 1,
            minimumStart: Date(timeIntervalSince1970: 120), maximumEnd: Date(timeIntervalSince1970: 180)))
        _ = try store.activate(h)
    }

    func testUTF8BudgetsAndEmbeddedNULAreNotCharacterCounts() throws {
        let h = try store.begin(key)
        assertError(.budgetExceeded) {
            try store.append([record(0, title: String(repeating: "😀", count: 262_144))], to: h)
        }
        assertError(.budgetExceeded) { try store.append((0..<513).map { record($0) }, to: h) }
        let text = "hello\0世界😀"
        try store.append([record(0, title: text)], to: h)
        try seal(h, count: 1)
        XCTAssertEqual(try db().string("SELECT title FROM programmes"), text)
        XCTAssertEqual(try db().string("SELECT channel_reference FROM programmes"), "undeclared")
    }

    func testProgrammeOnlyReferenceCreatesKnownChannelAndIDAlias() throws {
        let h = try store.begin(key)
        try store.append([record(0, channel: "CCTV-1")], to: h)
        try seal(h, count: 1)
        let raw = try db()
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(h.generation)]), 1)
        XCTAssertEqual(try raw.string("SELECT channel_key FROM channels WHERE generation_id=?", [.text(h.generation)]), "CCTV-1")
        XCTAssertEqual(try raw.string("SELECT normalized_alias FROM channel_aliases WHERE generation_id=?", [.text(h.generation)]), "CCTV1")
        XCTAssertEqual(try raw.string("SELECT channel_key FROM programmes WHERE generation_id=?", [.text(h.generation)]), "CCTV-1")
        _ = try store.activate(h)
    }

    func testChannelDeclarationsMergeAliasesAndSealWithProgrammes() throws {
        let h = try store.begin(key)
        try store.appendChannels([
            EPGChannel(id: "caf\u{00E9}", displayName: "Café频道", aliases: ["主频道", "ＣＣＴＶ－１"]),
            EPGChannel(id: "cafe\u{0301}", displayName: "备用名", aliases: ["主频道"])
        ], to: h)
        try store.append([record(0, channel: "cafe\u{0301}")], to: h)
        assertError(.validationFailed) { try seal(h, count: 1, channelRecords: 1) }
        try seal(h, count: 1, channelRecords: 2)
        let raw = try db()
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(h.generation)]), 1)
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM channel_aliases WHERE generation_id=?", [.text(h.generation)]), 5)
        XCTAssertEqual(try raw.integer("SELECT channel_records FROM generations WHERE id=?", [.text(h.generation)]), 2)
        assertError(.invalidState) {
            try store.appendChannels([EPGChannel(id: "late", displayName: "Late")], to: h)
        }
        _ = try store.activate(h)
    }

    func testChannelBatchBudgetsRejectAtomically() throws {
        let h = try store.begin(key)
        assertError(.budgetExceeded) {
            try store.appendChannels((0..<513).map { EPGChannel(id: "id\($0)", displayName: "name\($0)") }, to: h)
        }
        assertError(.budgetExceeded) {
            try store.appendChannels([
                EPGChannel(id: "huge", displayName: String(repeating: "😀", count: 262_145))
            ], to: h)
        }
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(h.generation)]), 0)
        try seal(h, count: 0)
    }

    func testCleanupBudgetIncludesProgrammesAliasesAndChannels() throws {
        let old = try store.begin(key)
        try store.appendChannels([EPGChannel(id: "old", displayName: "Old", aliases: ["Legacy"])], to: old)
        try store.append([record(0, channel: "old")], to: old)
        try seal(old, count: 1, channelRecords: 1)
        _ = try store.activate(old)
        _ = try publish()

        var deleted = 0
        var removed = false
        while !removed {
            let step = try store.cleanupStep(limit: 2)
            let work = step.deletedProgrammes + step.deletedAliases + step.deletedChannels
            XCTAssertLessThanOrEqual(work, 2)
            XCTAssertGreaterThan(work, 0)
            deleted += work
            removed = step.removedGeneration
        }
        XCTAssertGreaterThanOrEqual(deleted, 4)
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM generations"), 1)
    }

    func testFailedBatchRollsBackEveryRowAndCanBeAbandoned() throws {
        let old = try publish()
        let h = try store.begin(key)
        let raw = try db()
        try raw.execute("CREATE TRIGGER fail_second BEFORE INSERT ON programmes WHEN NEW.ordinal=1 BEGIN SELECT RAISE(ABORT,'test'); END")
        XCTAssertThrowsError(try store.append([record(0), record(1)], to: h))
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM programmes WHERE generation_id=?", [.text(h.generation)]), 0)
        XCTAssertEqual(try raw.integer("SELECT count FROM generations WHERE id=?", [.text(h.generation)]), 0)
        try store.abandon(h)
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, old.generation)
    }

    func testActivePointerOverridesDiagnosticStateAndGCIsBounded() throws {
        let old = try publish(count: 10)
        let current = try publish(count: 2)
        let raw = try db()
        try raw.execute("UPDATE generations SET state='abandoned' WHERE id=?", [.text(current.generation)])
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, current.generation)
        XCTAssertEqual(try store.cleanupStep(limit: 3).deletedProgrammes, 3)
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM programmes WHERE generation_id=?", [.text(old.generation)]), 7)
        for _ in 0..<5 { try store.cleanupStep(limit: 3) }
        XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM programmes"), 2)
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, current.generation)
    }

    func testRecoveryDiscardsOrphansAndKeepsActive() throws {
        let old = try publish()
        let pending = try store.begin(key)
        try store.append([record(0)], to: pending)
        try seal(pending, count: 1)
        store.close(); store = try EPGCacheStore(directory: directory)
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, old.generation)
        assertError(.invalidHandle) { _ = try store.activate(pending) }
        try store.cleanupStep()
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM programmes"), 1)
    }

    func testSingleOwnerAndNewerSchemaArePreserved() throws {
        assertError(.alreadyOpen) { _ = try EPGCacheStore(directory: directory) }
        store.close()
        do { let raw = try db(); try raw.execute("PRAGMA user_version=99"); raw.close() }
        assertError(.incompatibleVersion(99)) { _ = try EPGCacheStore(directory: directory) }
        XCTAssertEqual(try db().integer("PRAGMA user_version"), 99)
    }

    func testCorruptCacheRebuildPreservesUnrelatedFilesAndRejectsOldHandles() throws {
        let h = try publish()
        let marker = directory.appendingPathComponent("preferences-do-not-touch")
        try Data("keep".utf8).write(to: marker)
        store.close()
        try Data("not sqlite".utf8).write(to: directory.appendingPathComponent("EPGCache.sqlite"))
        store = try EPGCacheStore(directory: directory)
        XCTAssertTrue(store.rebuiltOnOpen)
        XCTAssertNil(try store.activeIdentity(for: key))
        XCTAssertEqual(try String(contentsOf: marker), "keep")
        assertError(.invalidHandle) { try store.append([record(1)], to: h) }
    }

    func testBusyFailureDoesNotRebuildOrDiscardActive() throws {
        let active = try publish()
        let raw = try db()
        try raw.execute("BEGIN IMMEDIATE")
        defer { try? raw.execute("ROLLBACK") }
        XCTAssertThrowsError(try store.begin(key)) { error in
            guard case EPGCacheError.sqlite(let code) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(code & 0xff, 5)
        }
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, active.generation)
        XCTAssertFalse(store.rebuiltOnOpen)
    }

    func testForeignDatabaseAndSymlinkAreNeverDeleted() throws {
        store.close()
        do { let raw = try db(); try raw.execute("PRAGMA application_id=123"); raw.close() }
        assertError(.foreignDatabase) { _ = try EPGCacheStore(directory: directory) }
        XCTAssertEqual(try db().integer("PRAGMA application_id"), 123)
        let linked = URL(fileURLWithPath: "/private/tmp/EPGCache-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        assertError(.unsafeDirectory) { _ = try EPGCacheStore(directory: linked) }
    }

    func testTwoHundredThousandRowsUseOnlyBoundedBatches() throws {
        let h = try store.begin(key)
        for start in stride(from: 0, to: 200_000, by: 512) {
            try store.append((start..<min(start + 512, 200_000)).map { record($0) }, to: h)
        }
        try seal(h, count: 200_000)
        XCTAssertEqual(try store.activate(h).programmeCount, 200_000)
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM programmes"), 200_000)
        XCTAssertEqual(try db().integer("SELECT SUM(ordinal) FROM programmes"), 19_999_900_000)
    }

    func testConcurrentCancelAndActivateHaveOneLegalOutcome() throws {
        for _ in 0..<30 {
            let h = try store.begin(key)
            try seal(h, count: 0)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { [store] in
                defer { group.leave() }
                do { _ = try store!.activate(h) }
                catch { XCTAssertEqual(error as? EPGCacheError, .superseded) }
            }
            group.enter()
            DispatchQueue.global().async { [store] in
                defer { group.leave() }
                do { try store!.abandon(h) }
                catch { XCTFail("abandon failed: \(error)") }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            let raw = try db()
            let state = try raw.string("SELECT state FROM generations WHERE id=?", [.text(h.generation)])
            if state == "active" { XCTAssertEqual(try store.activeIdentity(for: key)?.generation, h.generation) }
            else { XCTAssertEqual(state, "abandoned"); XCTAssertNotEqual(try store.activeIdentity(for: key)?.generation, h.generation) }
            try store.cleanupStep()
        }
    }

    func testIndependentProcessKillAtTransactionBoundaries() throws {
        store.close()
        for boundary in ["appendBeforeCommit", "validateBeforeCommit", "activateBeforeCommit", "activateAfterCommit", "cleanupBeforeCommit"] {
            let childDirectory = URL(fileURLWithPath: "/private/tmp/EPGCache-crash-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: childDirectory) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "OKVideoPersistenceTests.EPGCacheCrashWorkerTests/testWorker", Bundle(for: Self.self).bundleURL.path]
            var env = ProcessInfo.processInfo.environment
            env["OKVIDEO_EPG_CACHE_CRASH_DIRECTORY"] = childDirectory.path
            env["OKVIDEO_EPG_CACHE_CRASH_BOUNDARY"] = boundary
            env["OKVIDEO_EPG_CACHE_CRASH_SOURCE"] = key.source.id.uuidString
            process.environment = env
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            let result = ended.wait(timeout: .now() + 30)
            if result != .success {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                XCTFail("child timed out at \(boundary)"); continue
            }
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            XCTAssertEqual(process.terminationStatus, SIGKILL)
            XCTAssertEqual(try String(contentsOf: childDirectory.appendingPathComponent("reached")), boundary)
            let recovered = try EPGCacheStore(directory: childDirectory)
            let expected = ["activateAfterCommit", "cleanupBeforeCommit"].contains(boundary) ? 2 : 1
            XCTAssertEqual(try recovered.activeIdentity(for: key)?.programmeCount, expected, boundary)
            for _ in 0..<3 { try recovered.cleanupStep() }
            let raw = try EPGCacheDatabase(url: childDirectory.appendingPathComponent("EPGCache.sqlite"))
            XCTAssertEqual(try raw.integer("SELECT COUNT(*) FROM programmes"), Int64(expected), boundary)
            XCTAssertEqual(try raw.string("PRAGMA quick_check"), "ok")
            raw.close(); recovered.close()
        }
    }

    func testSQLiteFullRollsBackWithoutRebuildingOrLosingActive() throws {
        store.close()
        store = try EPGCacheStore(directory: directory, maximumDatabaseBytes: 65_536)
        let old = try publish()
        let h = try store.begin(key)
        XCTAssertThrowsError(try store.append((0..<100).map { record($0, title: String(repeating: "x", count: 3000)) }, to: h)) { error in
            guard case EPGCacheError.sqlite(let code) = error else { return XCTFail("Expected real SQLITE_FULL, got \(error)") }
            XCTAssertEqual(code & 0xff, 13)
        }
        XCTAssertFalse(store.rebuiltOnOpen)
        XCTAssertEqual(try store.activeIdentity(for: key)?.generation, old.generation)
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM programmes WHERE generation_id=?", [.text(h.generation)]), 0)
        try store.abandon(h)
    }

    func testOldOwnedSchemaRebuildAndClosedStoreRejectsOperations() throws {
        let h = try publish()
        store.close()
        assertError(.closed) { try store.append([record(1)], to: h) }
        do { let raw = try db(); try raw.execute("PRAGMA user_version=0"); raw.close() }
        store = try EPGCacheStore(directory: directory)
        XCTAssertTrue(store.rebuiltOnOpen)
        XCTAssertNil(try store.activeIdentity(for: key))
        assertError(.invalidHandle) { try store.abandon(h) }
    }

    func testCleanupReportsProgressForEmptyAbandonedGenerations() throws {
        for _ in 0..<3 { let h = try store.begin(key); try store.abandon(h) }
        let live = try store.begin(key)
        let first = try store.cleanupStep()
        XCTAssertEqual(first.deletedProgrammes, 0)
        XCTAssertTrue(first.removedGeneration)
        XCTAssertTrue(first.hasWorkRemaining)
        while try store.cleanupStep().hasWorkRemaining {}
        XCTAssertEqual(try db().integer("SELECT COUNT(*) FROM generations"), 1)
        try seal(live, count: 0)
        _ = try store.activate(live)
    }
}

final class EPGCacheCrashWorkerTests: XCTestCase {
    func testWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OKVIDEO_EPG_CACHE_CRASH_DIRECTORY"],
              let boundary = env["OKVIDEO_EPG_CACHE_CRASH_BOUNDARY"],
              let source = env["OKVIDEO_EPG_CACHE_CRASH_SOURCE"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("Only launched by the independent-process recovery test")
        }
        guard path.hasPrefix("/private/tmp/EPGCache-crash-") else { return XCTFail("Invalid fixture root") }
        let directory = URL(fileURLWithPath: path)
        let store = try EPGCacheStore(directory: directory)
        let key = EPGRequestKey(source: .imported(source), revision: String(repeating: "a", count: 64), resource: "xmltv")
        func append(_ h: EPGCacheImportHandle, count: Int) throws {
            try store.append((0..<count).map {
                EPGCacheRecord(ordinal: $0, programme: EPGProgramme(channelID: "x", title: "fixture",
                    start: Date(timeIntervalSince1970: Double($0)), end: Date(timeIntervalSince1970: Double($0 + 1))))
            }, to: h)
        }
        func seal(_ h: EPGCacheImportHandle, count: Int) throws {
            try store.validate(h, summary: EPGCacheValidation(rawProgrammeCount: count, emittedProgrammeCount: count,
                minimumStart: Date(timeIntervalSince1970: 0), maximumEnd: Date(timeIntervalSince1970: Double(count))))
        }
        let first = try store.begin(key)
        try append(first, count: 1); try seal(first, count: 1); _ = try store.activate(first)
        let next = try store.begin(key)
        store.boundaryForTesting = { name in
            guard name == boundary else { return }
            try! Data(name.utf8).write(to: directory.appendingPathComponent("reached"), options: .atomic)
            kill(getpid(), SIGKILL)
        }
        try append(next, count: 2)
        try seal(next, count: 2)
        _ = try store.activate(next)
        try store.cleanupStep()
        XCTFail("Requested crash boundary not reached")
    }
}
