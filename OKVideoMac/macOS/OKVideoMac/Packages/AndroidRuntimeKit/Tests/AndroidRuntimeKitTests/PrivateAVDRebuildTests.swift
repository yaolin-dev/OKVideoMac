import XCTest
@testable import AndroidRuntimeKit

final class PrivateAVDRebuildTests: XCTestCase {
    private struct Fixture {
        let support: URL
        let layout: AndroidRuntimeLayout
        var store: PrivateAVDRebuildStore { PrivateAVDRebuildStore(layout: layout) }
        func cleanup() { try? FileManager.default.removeItem(at: support) }
        func read(_ path: String) throws -> String {
            try String(contentsOf: layout.root.appendingPathComponent(path), encoding: .utf8)
        }
    }
    private func fixture(fingerprint: Bool = true) throws -> Fixture {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("AVDRebuild-\(UUID())")
        let layout = AndroidRuntimeLayout(applicationSupportDirectory: support)
        try FileManager.default.createDirectory(at: layout.avdDirectory, withIntermediateDirectories: true)
        let contents = [
            "avd/OKVideoMac_Runtime.avd/config.ini": "image=default",
            "avd/OKVideoMac_Runtime.avd/userdata-qemu.img": "original-login-state",
            "avd/OKVideoMac_Runtime.ini": "original-companion",
            "avd/avd-manifest.json": "original-manifest",
            "runtime-continuity.json": "original-continuity",
            "runtime-profile.json": "private-adb-profile"
        ]
        for (path, text) in contents { try Data(text.utf8).write(to: layout.root.appendingPathComponent(path)) }
        if fingerprint {
            try Data("original-default-fingerprint".utf8).write(to: layout.avdHome.appendingPathComponent("runtime-compatibility.json"))
        }
        return Fixture(support: support, layout: layout)
    }
    private func createNew(_ f: Fixture) throws {
        try FileManager.default.createDirectory(at: f.layout.avdDirectory, withIntermediateDirectories: true)
        try Data("image=google_apis".utf8).write(to: f.layout.avdDirectory.appendingPathComponent("config.ini"))
        try Data("new-google-apis-fingerprint".utf8).write(to: f.layout.avdHome.appendingPathComponent("runtime-compatibility.json"))
    }
    private func assertRestored(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try f.read("avd/OKVideoMac_Runtime.avd/userdata-qemu.img"), "original-login-state", file: file, line: line)
        XCTAssertEqual(try f.read("avd/OKVideoMac_Runtime.avd/config.ini"), "image=default", file: file, line: line)
        XCTAssertEqual(try f.read("avd/runtime-compatibility.json"), "original-default-fingerprint", file: file, line: line)
        XCTAssertEqual(try f.read("runtime-profile.json"), "private-adb-profile", file: file, line: line)
    }
    func testBackupIncludesFingerprintAndLeavesUnrelatedData() throws {
        let f = try fixture(); defer { f.cleanup() }
        let unrelated = f.layout.avdHome.appendingPathComponent("Studio.avd")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let backup = try f.store.begin(metadataSnapshots: ["runtime-profile.json": Data("profile".utf8), "secret": Data()])
        XCTAssertTrue(backup.movedItemNames.contains("runtime-compatibility.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.layout.avdHome.appendingPathComponent("runtime-compatibility.json").path))
        XCTAssertEqual(try String(contentsOf: backup.directory.appendingPathComponent("runtime-compatibility.json")), "original-default-fingerprint")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.appendingPathComponent("secret").path))
        try createNew(f)
        try f.store.commit()
        XCTAssertFalse(f.store.hasPendingTransaction)
        try f.store.recover() // A boot failure after commit must not restore the old image.
        XCTAssertEqual(try f.read("avd/OKVideoMac_Runtime.avd/config.ini"), "image=google_apis")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.appendingPathComponent("OKVideoMac_Runtime.avd/userdata-qemu.img").path))
    }
    func testLegacyWithoutFingerprintStillBacksUpAndRecovers() throws {
        let f = try fixture(fingerprint: false); defer { f.cleanup() }
        _ = try f.store.begin(); try createNew(f); try f.store.recover()
        XCTAssertEqual(try f.read("avd/OKVideoMac_Runtime.avd/userdata-qemu.img"), "original-login-state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.layout.avdHome.appendingPathComponent("runtime-compatibility.json").path))
    }
    func testEveryBackupMoveFailureRollsBackOriginalPair() throws {
        for index in 1...PrivateAVDRebuildStore.paths.count {
            let f = try fixture(); defer { f.cleanup() }
            var store = f.store
            var count = 0
            store.beforeMove = { _, _ in
                count += 1
                if count == index { throw CocoaError(.fileWriteOutOfSpace) }
            }
            XCTAssertThrowsError(try store.begin())
            try assertRestored(f)
            XCTAssertFalse(store.hasPendingTransaction)
        }
    }
    func testPartialBackupWithFailedRollbackRecoversAfterInterruption() throws {
        let f = try fixture(); defer { f.cleanup() }
        var store = f.store
        var count = 0
        store.beforeMove = { _, _ in
            count += 1
            if count >= 3 { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try store.begin())
        XCTAssertTrue(store.hasPendingTransaction)
        XCTAssertThrowsError(try f.store.requireNoPendingTransaction())
        try f.store.recover()
        try assertRestored(f)
        try f.store.recover() // Idempotent.
    }
    func testNewConfigOrFingerprintFailureQuarantinesNewAndRestoresOld() throws {
        for includeFingerprint in [false, true] {
            let f = try fixture(); defer { f.cleanup() }
            let backup = try f.store.begin()
            try createNew(f)
            if !includeFingerprint { try FileManager.default.removeItem(at: f.layout.avdHome.appendingPathComponent("runtime-compatibility.json")) }
            try f.store.recover()
            try assertRestored(f)
            XCTAssertEqual(try String(contentsOf: backup.directory.appendingPathComponent("FailedRebuild/OKVideoMac_Runtime.avd/config.ini")), "image=google_apis")
        }
    }
    func testEveryRecoveryMoveCanBeInterruptedAndResumed() throws {
        // Two new artifacts are quarantined and five originals restored.
        for index in 1...7 {
            let f = try fixture(); defer { f.cleanup() }
            _ = try f.store.begin(); try createNew(f)
            var store = f.store
            var count = 0
            store.beforeMove = { _, _ in
                count += 1
                if count == index { throw CocoaError(.fileWriteNoPermission) }
            }
            XCTAssertThrowsError(try store.recover())
            XCTAssertTrue(store.hasPendingTransaction)
            try f.store.recover()
            try assertRestored(f)
            XCTAssertFalse(f.store.hasPendingTransaction)
        }
    }
    func testMissingOriginalFailsClosedWithoutMovingNewData() throws {
        let f = try fixture(); defer { f.cleanup() }
        let backup = try f.store.begin(); try createNew(f)
        try FileManager.default.removeItem(at: backup.directory.appendingPathComponent("runtime-compatibility.json"))
        XCTAssertThrowsError(try f.store.recover())
        XCTAssertTrue(f.store.hasPendingTransaction)
        XCTAssertEqual(try f.read("avd/OKVideoMac_Runtime.avd/config.ini"), "image=google_apis")
    }
    func testPendingJournalRejectsSecondRebuild() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try f.store.begin()
        XCTAssertThrowsError(try f.store.begin())
        try f.store.recover(); try assertRestored(f)
    }
    func testCorruptJournalRejectsRecoveryWithoutTouchingOriginal() throws {
        let f = try fixture(); defer { f.cleanup() }
        try Data("invalid".utf8).write(to: f.store.journalURL)
        XCTAssertThrowsError(try f.store.recover())
        try assertRestored(f)
    }
    func testSymlinkedOwnedFingerprintIsRejected() throws {
        let f = try fixture(); defer { f.cleanup() }
        let fingerprint = f.layout.avdHome.appendingPathComponent("runtime-compatibility.json")
        try FileManager.default.removeItem(at: fingerprint)
        try FileManager.default.createSymbolicLink(at: fingerprint, withDestinationURL: f.layout.root.appendingPathComponent("runtime-profile.json"))
        XCTAssertThrowsError(try f.store.begin())
        XCTAssertEqual(try f.read("runtime-profile.json"), "private-adb-profile")
    }
    func testExclusiveMaintenanceLeaseExcludesOtherRebuildAndInstaller() throws {
        let f = try fixture(); defer { f.cleanup() }
        let lease = try RuntimeMaintenanceLease(layout: f.layout, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        XCTAssertThrowsError(try RuntimeMaintenanceLease(layout: f.layout, exclusive: true))
        XCTAssertThrowsError(try RuntimeMaintenanceLease(layout: f.layout))
    }
}
