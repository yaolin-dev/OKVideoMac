import Foundation
import XCTest
@testable import OKCrashDiagnostics

final class DiagnosticPayloadTests: XCTestCase {
    func record() -> CrashRecord {
        .init(id: String(repeating: "a", count: 32), timestamp: Date(), version: "0.9.2", build: "198",
              osVersion: "27.3", architecture: "arm64", signal: "SIGABRT", signalCode: "UNKNOWN",
              threads: [.init(number: 0, crashed: true, frames: [.init(pc: 0x1020, imageBase: 0x1000)])],
              images: [.init(uuid: "12345678-1234-1234-1234-123456789ABC", base: 0x1000, size: 0x1000,
                             name: "OKVideoMac", vmaddr: 0x1000)])
    }

    func testFirstThrowAndAbortStacksStayDistinctThroughStoreAndSDKSerialization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = record()
        value.exception = .init(name: "NSGenericException", reason: "Repeated Update Constraints in Window",
                                frames: [.init(pc: 0x1110, imageBase: 0x1000), .init(pc: 0x1120, imageBase: 0x1000)])
        value.operations = [.init(sequence: 1, timestamp: value.timestamp, uptime: 50,
                                  kind: .windowResizeBegin, window: .browser)]
        let store = try ReportStore(root: root)
        try store.save(value)
        let restored = try XCTUnwrap(store.records().first)
        XCTAssertEqual(restored, value)
        let wire = SentryUploadWorker.event(restored).serialize()
        let exception = try XCTUnwrap((wire["exception"] as? [String: Any])?["values"] as? [[String: Any]]).first!
        XCTAssertEqual(exception["type"] as? String, "NSGenericException")
        XCTAssertEqual(exception["value"] as? String, value.exception?.reason)
        let frames = try XCTUnwrap((exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.compactMap { $0["instruction_addr"] as? String }, ["0x1110", "0x1120"])
        let threads = try XCTUnwrap((wire["threads"] as? [String: Any])?["values"] as? [[String: Any]])
        let abort = try XCTUnwrap((threads[0]["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(abort[0]["instruction_addr"] as? String, "0x1020")
        XCTAssertEqual(wire["release"] as? String, "com.okvideomac.OKVideoMac@0.9.2+198")
        XCTAssertNotNil(wire["breadcrumbs"])
        XCTAssertNil(wire["user"])
    }

    func testLegacyAndSignalOnlyRecordsKeepTheirOriginalBehavior() throws {
        let data = try JSONEncoder().encode(record())
        let restored = try JSONDecoder().decode(CrashRecord.self, from: data)
        XCTAssertNil(restored.exception)
        XCTAssertNil(restored.operations)
        XCTAssertTrue(restored.isValid)
        let e = SentryUploadWorker.event(restored)
        XCTAssertEqual(e.exceptions?.first?.type, "SIGABRT")
        XCTAssertEqual(e.exceptions?.first?.stacktrace?.frames.first?.instructionAddress, "0x1020")
    }

    func testImagesBeyondOld1024LimitRetainReferencedMappings() {
        let images = (0..<5000).map { i in
            CrashRecord.Image(uuid: "12345678-1234-1234-1234-123456789ABC", base: UInt64(i * 4096), size: 4096,
                              name: "image-12345678-1234-1234-1234-123456789ABC", vmaddr: nil)
        }
        let selected = CrashMapper.selectImages(images, referencedPCs: [UInt64(4999 * 4096 + 24)])
        XCTAssertEqual(selected.count, 4096)
        XCTAssertEqual(selected.first?.base, UInt64(4999 * 4096))
    }

    func testExceptionTextRedactsValuesAndRemainsBoundedAndIdempotent() {
        let raw = "NSWindow failed https://private.invalid/a?token=SECRET /Users/person/video.mov name='PRIVATE_TITLE' email@private.invalid Authorization=SECRET <NSWindow: 0x123 title=PRIVATE>"
        let safe = ExceptionRedactor.reason(raw)
        for secret in ["private.invalid", "SECRET", "PRIVATE_TITLE", "/Users/", "0x123", "title=PRIVATE"] {
            XCTAssertFalse(safe.contains(secret), safe)
        }
        XCTAssertTrue(safe.contains("NSWindow failed"))
        XCTAssertEqual(safe, ExceptionRedactor.reason(safe))
        XCTAssertLessThanOrEqual(ExceptionRedactor.reason(String(repeating: "a", count: 10000)).count, 2048)
        var value = record()
        value.exception = .init(name: "NSGenericException", reason: raw, frames: [])
        XCTAssertFalse(value.isValid)
    }

    func testExceptionTextRedactsAuthenticationHeadersAndQuotedCredentials() {
        let raw = """
        Request failed
        Authorization: Bearer bearer-value
        Proxy-Authorization: Basic basic-value
        Cookie: session=cookie-value; other=second-value
        password="pass phrase with spaces"
        """
        let safe = ExceptionRedactor.reason(raw)
        XCTAssertEqual(safe, "Request failed [CREDENTIAL] [CREDENTIAL] [CREDENTIAL] [CREDENTIAL]")
        XCTAssertEqual(ExceptionRedactor.reason(safe), safe)
    }

    func testTrailIsBoundedOrderedAndCoalescesOnlyNoisyInput() {
        var snapshots: [[CrashOperation]] = []
        let trail = CrashOperationTrail { snapshots.append($0) }
        for i in 0..<50 { trail.record(.navigationHome, window: .browser, uptime: Double(i)) }
        XCTAssertEqual(snapshots.last?.count, 32)
        XCTAssertEqual(snapshots.last?.first?.sequence, 19)
        trail.record(.scroll, window: .browser, uptime: 50)
        trail.record(.scroll, window: .browser, uptime: 50.1)
        XCTAssertEqual(snapshots.count, 51)
        trail.record(.windowResizeBegin, window: .browser, uptime: 50.2)
        XCTAssertEqual(snapshots.last?.last?.kind, .windowResizeBegin)
    }

    func testRawArchiveIsBoundedPrivateAndClearedOnDiscard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReportStore(root: root)
        for i in 0..<6 { try store.archiveRaw(Data("native-\(i)".utf8)) }
        let files = try FileManager.default.contentsOfDirectory(at: store.rawArchive, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(try store.records().isEmpty)
        try store.discard()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.rawArchive.path).isEmpty)
    }

    func testOperationSnapshotsMatchOnlyTheirRunAndRemainBoundedPrivateAndAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReportStore(root: root)
        let session = UUID().uuidString
        let operation = CrashOperation(sequence: 1, timestamp: Date(), uptime: 1, kind: .navigationLive, window: .browser)
        try store.saveOperations([operation], session: session)
        // An interrupted temporary write cannot replace the last complete snapshot.
        try Data("partial".utf8).write(to: store.operationSnapshots.appendingPathComponent("unfinished.tmp"))
        XCTAssertEqual(store.operations(session: session), [operation])
        XCTAssertNil(store.operations(session: UUID().uuidString))
        XCTAssertNil(store.operations(session: "../pending"))
        let path = store.operationSnapshots.appendingPathComponent(session + ".json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        for _ in 0..<5 { try store.saveOperations([operation], session: UUID().uuidString) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.operationSnapshots.path).count, 3)
        try store.discard()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.operationSnapshots.path).isEmpty)
    }
}
