import XCTest
import Foundation
@testable import OKCrashDiagnostics

final class CrashDiagnosticsTests: XCTestCase {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OKCrashTests-" + UUID().uuidString) }
    func record(id: Int = 1, date: Date = Date()) -> CrashRecord {
        .init(id: String(format: "%032x", id), timestamp: date, version: "0.1.0", build: "1", osVersion: "14.8.9", architecture: "arm64", signal: "SIGTRAP", signalCode: "TRAP_BRKPT", threads: [.init(number: 0, crashed: true, frames: [.init(pc: 0x100001004, imageBase: 0x100000000)])], images: [.init(uuid: "12345678-1234-1234-1234-123456789ABC", base: 0x100000000, size: 0x2000, name: "OKVideoMac", vmaddr: 0x100000000)])
    }
    func testAcceptanceAndNormalEventEnvironmentsStaySeparate() {
        let event = SentryUploadWorker.event(record())
#if OKVIDEO_CRASH_ACCEPTANCE
        XCTAssertEqual(event.environment, "okvideomac-crash-integration-acceptance")
#else
        XCTAssertEqual(event.environment, "okvideomac-crash-reports")
#endif
        XCTAssertEqual(event.releaseName, "com.okvideomac.OKVideoMac@0.1.0+1")
        XCTAssertEqual(event.dist, "1")
    }

    func testSerializedEventKeepsOriginalReleaseAndBuildWithoutPrivateFields() throws {
        // Exercise the SDK serializer, not just the Event object's properties.
        // The report predates this app build; uploading it must retain its version.
        let serialized = SentryUploadWorker.event(record()).serialize()
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: serialized)) as! [String: Any]
        XCTAssertEqual(wire["release"] as? String, "com.okvideomac.OKVideoMac@0.1.0+1")
        XCTAssertEqual(wire["dist"] as? String, "1")
        let debugMeta = try XCTUnwrap(wire["debug_meta"] as? [String: Any])
        let images = try XCTUnwrap(debugMeta["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        let debugID = try XCTUnwrap(images.first?["debug_id"] as? String)
        XCTAssertEqual(UUID(uuidString: debugID), UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        let contexts = try XCTUnwrap(wire["contexts"] as? [String: Any])
        XCTAssertEqual(Set(contexts.keys), ["os", "device"])
        for key in ["user", "request", "breadcrumbs", "extra", "message"] {
            XCTAssertNil(wire[key], "Unexpected private field: \(key)")
        }
    }

    func testFreshStoreDeniesUpload() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        let s=try ReportStore(root:r);XCTAssertFalse(s.consent);XCTAssertTrue(try s.records().isEmpty)
    }
    func testConsentPersistsAndRevokes() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        do { let s=try ReportStore(root:r);try s.setConsent(true) }
        do { let s=try ReportStore(root:r);XCTAssertTrue(s.consent);try s.setConsent(false) }
        XCTAssertFalse(try ReportStore(root:r).consent)
    }
    func testCorruptConsentFailsClosed() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        try ReportStore.privateDirectory(r);try Data("garbage".utf8).write(to:r.appendingPathComponent("consent.json"))
        XCTAssertFalse(try ReportStore(root:r).consent)
    }
    func testPendingBoundAndOriginalMetadata() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        let s=try ReportStore(root:r)
        for n in 1...8 { try s.save(record(id:n,date:Date().addingTimeInterval(Double(-n)))) }
        let saved=try s.records();XCTAssertEqual(saved.count,3);XCTAssertEqual(saved.last?.version,"0.1.0");XCTAssertEqual(saved.last?.build,"1")
        XCTAssertEqual(saved.last?.id,record(id:1).id)
    }
    func testExpiryAndCorruptionArePruned() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        let s=try ReportStore(root:r);try s.save(record(date:Date().addingTimeInterval(-8*86400)))
        try Data("broken".utf8).write(to:s.pending.appendingPathComponent("bad.json"))
        XCTAssertTrue(try s.records().isEmpty)
    }
    func testReportPermissionsAndInstanceLease() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        let s=try ReportStore(root:r);try s.save(record())
        XCTAssertThrowsError(try ReportStore(root:r))
        let dirs=try FileManager.default.attributesOfItem(atPath:r.path)
        XCTAssertEqual((dirs[.posixPermissions] as? NSNumber)?.intValue,0o700)
        let file=try FileManager.default.contentsOfDirectory(at:s.pending,includingPropertiesForKeys:nil).first!
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testSDKCacheRemovedWithoutSDKStartup() throws {
        let r=root();defer { try? FileManager.default.removeItem(at:r) }
        try ReportStore.privateDirectory(r.appendingPathComponent("sentry-cache"));try Data("DO_NOT_SEND".utf8).write(to:r.appendingPathComponent("sentry-cache/stale"))
        let s=try ReportStore(root:r);XCTAssertFalse(FileManager.default.fileExists(atPath:s.cache.path));XCTAssertFalse(s.consent)
    }
    func testInvalidRawInputDoesNotBecomeEvent() {
        XCTAssertThrowsError(try CrashMapper.parse(Data("malformed".utf8)))
        XCTAssertThrowsError(try CrashMapper.parse(Data(repeating:0,count:CrashMapper.maxRawBytes+1)))
    }
    func testWhitelistRejectsPrivateModuleAndMetadata() throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record())) as! [String:Any]
        object["version"]="https://private.invalid/token"
        let bad=try JSONDecoder().decode(CrashRecord.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertFalse(bad.isValid)
        object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record())) as! [String:Any]
        var images=object["images"] as! [[String:Any]];images[0]["name"]="/Users/private/video.mov";object["images"]=images
        XCTAssertFalse(try JSONDecoder().decode(CrashRecord.self,from:JSONSerialization.data(withJSONObject:object)).isValid)
    }
    func testMapperCanonicalizesUUIDAndRejectsFreeText() {
        XCTAssertEqual(CrashMapper.uuidString("12345678123412341234123456789abc"),"12345678-1234-1234-1234-123456789ABC")
        XCTAssertNil(CrashMapper.uuidString("private token"));XCTAssertEqual(CrashMapper.allowedCode("https://private.invalid"),"UNKNOWN")
    }
    func testOversizedValidConsentFailsClosed() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        try ReportStore.privateDirectory(r)
        try Data(("true" + String(repeating: " ", count: 8192)).utf8)
            .write(to: r.appendingPathComponent("consent.json"))
        XCTAssertFalse(try ReportStore(root: r).consent)
    }

    func testLinkedDiagnosticRootCannotChangeTargetPermissionsOrContents() throws {
        let parent = root(); defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        let linked = parent.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let marker = target.appendingPathComponent("marker")
        try Data("unchanged".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        XCTAssertThrowsError(try ReportStore(root: linked))
        XCTAssertEqual(try Data(contentsOf: marker), Data("unchanged".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("instance.lock").path))
    }
}
