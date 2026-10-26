import Foundation
import XCTest
import CZlib
import Darwin
@_spi(XMLTVStreaming) @testable import OKVideoCore
@testable import OKVideoPersistence

final class EPGXMLTVImporterTests: XCTestCase {
    var root: String!
    var directory: URL!
    var store: EPGCacheStore!
    var key: EPGRequestKey!
    override func setUpWithError() throws {
        root = "/private/tmp/OKVideoMac-9B." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = URL(fileURLWithPath: "/private/tmp/EPGCache-9C3-" + UUID().uuidString)
        store = try EPGCacheStore(directory: directory)
        key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "a", count: 64), resource: "xmltv")
    }
    override func tearDownWithError() throws {
        store.close(); store = nil
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
        try FileManager.default.removeItem(atPath: root)
        try FileManager.default.removeItem(at: directory)
    }
    func fixture(_ count: Int = 1) -> String {
        "<tv><channel id='a'><display-name>频道</display-name><display-name>A</display-name></channel>" +
        (0..<count).map { "<programme channel='a' start='20260101000000 +0000' stop='20260101010000 +0000'><title>T\($0)</title></programme>" }.joined() + "</tv>"
    }
    func staged(_ data: Data) throws -> XMLTVStagedFile {
        let owner = try XMLTVStagingFile.create(in: root)
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            try owner.write(data.subdata(in: offset..<min(offset + 65_536, data.count)))
        }
        return try owner.finishAndTransfer()
    }
    func gzip(_ data: Data) throws -> Data {
        let z = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        z.initialize(to: z_stream()); defer { z.deinitialize(count: 1); z.deallocate() }
        XCTAssertEqual(deflateInit2_(z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                    zlibVersion(), Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(z) }
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))) + 128)
        let count = data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { out -> Int in
                z.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                z.pointee.avail_in = uInt(input.count)
                z.pointee.next_out = out.baseAddress; z.pointee.avail_out = uInt(out.count)
                XCTAssertEqual(deflate(z, Z_FINISH), Z_STREAM_END)
                return out.count - Int(z.pointee.avail_out)
            }
        }
        return Data(output.prefix(count))
    }
    func run(_ data: Data, control: EPGImportControl = EPGImportControl(),
             boundary: ((String) throws -> Void)? = nil) async throws -> EPGImportReceipt {
        let file = try staged(data), importer = EPGXMLTVImporter(store: store), key = key!
        importer.boundaryForTesting = boundary
        return try await Task.detached { try importer.importLocal(file, key: key, control: control) }.value
    }
    private func historicalXML(_ entries: [(String, Date, Date, String)]) -> Data {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss Z"
        let channels = Set(entries.map { $0.0 }).sorted().map { "<channel id='\($0)'><display-name>\($0)</display-name></channel>" }.joined()
        let programmes = entries.map { "<programme channel='\($0.0)' start='\(formatter.string(from: $0.1))' stop='\(formatter.string(from: $0.2))'><title>\($0.3)</title></programme>" }.joined()
        return Data(("<tv>" + channels + programmes + "</tv>").utf8)
    }

    func testRefreshRetainsObservedHistoryAndFreshOverlappingProgrammeWins() async throws {
        let now = Date()
        _ = try await run(historicalXML([
            ("a", now.addingTimeInterval(-7200), now.addingTimeInterval(-3600), "Observed history"),
            ("a", now, now.addingTimeInterval(3600), "Old current title")]))
        let fresh = try await run(historicalXML([("a", now, now.addingTimeInterval(3600), "Corrected current title")]))
        XCTAssertEqual(fresh.active.programmeCount, 2)
        let channel = LiveChannel(groupName: "", name: "a", tvgID: "a", streams: [])
        let past = try store.queryNowNext([channel], for: key, at: now.addingTimeInterval(-5400))
        XCTAssertEqual(past.entries.first?.current?.title, "Observed history")
        let current = try store.queryNowNext([channel], for: key, at: now.addingTimeInterval(30))
        XCTAssertEqual(current.entries.first?.current?.title, "Corrected current title")
        let repeated = try await run(historicalXML([("a", now, now.addingTimeInterval(3600), "Corrected current title")]))
        XCTAssertEqual(repeated.active.programmeCount, 2, "Repeated refreshes must not duplicate history")
    }

    func testHistoryExpirationAndRemovedChannelsDoNotResurrect() async throws {
        let now = Date()
        _ = try await run(historicalXML([
            ("a", now.addingTimeInterval(-8 * 86400), now.addingTimeInterval(-8 * 86400 + 3600), "Expired"),
            ("b", now.addingTimeInterval(-7200), now.addingTimeInterval(-3600), "Removed channel")]))
        let fresh = try await run(historicalXML([("a", now, now.addingTimeInterval(3600), "Current")]))
        XCTAssertEqual(fresh.active.programmeCount, 1)
        let removed = LiveChannel(groupName: "", name: "b", tvgID: "b", streams: [])
        XCTAssertNil(try store.queryNowNext([removed], for: key, at: now.addingTimeInterval(-5400)).entries.first?.current)
    }

    func testRevisionChangeCannotCarryHistoryFromPreviousResource() async throws {
        let now = Date()
        _ = try await run(historicalXML([("a", now.addingTimeInterval(-7200), now.addingTimeInterval(-3600), "Old resource")]))
        key = EPGRequestKey(source: .imported(key.source.id), revision: String(repeating: "b", count: 64), resource: "xmltv")
        let fresh = try await run(historicalXML([("a", now, now.addingTimeInterval(3600), "New resource")]))
        XCTAssertEqual(fresh.active.programmeCount, 1)
    }

    func testPlainAndGzipPublishEquivalentQueryableGeneration() async throws {
        let data = Data(fixture(600).utf8)
        for payload in [data, try gzip(data)] {
            let receipt = try await run(payload)
            XCTAssertEqual(receipt.active.programmeCount, 600)
            XCTAssertEqual(receipt.channelFacts, 2)
            XCTAssertEqual(receipt.peakProgrammeBatch, 512)
            let channel = LiveChannel(groupName: "", name: "A", streams: [])
            let result = try store.queryNowNext([channel], for: key, at: Date(timeIntervalSince1970: 1767227400))
            XCTAssertEqual(result.entries.first?.current?.title, "T599")
        }
    }
    func testValidEmptyPublishesAndAllInvalidDoesNot() async throws {
        _ = try await run(Data(fixture().utf8))
        let empty = try await run(Data("<tv/>".utf8))
        XCTAssertEqual(empty.active.programmeCount, 0)
        do {
            _ = try await run(Data("<tv><programme><title>bad</title></programme></tv>".utf8))
            XCTFail("invalid document published")
        } catch {}
        XCTAssertEqual(try store.activeIdentity(for: key), empty.active)
    }
    func testMalformedAndCorruptGzipTailNeverReplaceOldActive() async throws {
        let old = try await run(Data(fixture().utf8))
        var corrupt = try gzip(Data(fixture(600).utf8)); corrupt[corrupt.count - 8] ^= 0xff
        for bad in [Data((fixture(600) + "<broken>").utf8), corrupt] {
            do { _ = try await run(bad); XCTFail("bad tail published") } catch {}
            XCTAssertEqual(try store.activeIdentity(for: key), old.active)
        }
        let recovered = try await run(Data(fixture().utf8))
        XCTAssertEqual(recovered.active.programmeCount, 1)
    }
    func testExplicitCancellationAfterCommittedBatchAndBeforePublish() async throws {
        let old = try await run(Data(fixture().utf8))
        for point in ["programmeBatchCommitted", "parsedComplete", "validated"] {
            let control = EPGImportControl()
            do {
                _ = try await run(Data(fixture(600).utf8), control: control) {
                    if $0 == point { control.stop() }
                }
                XCTFail("cancelled import published")
            } catch { XCTAssertEqual(error as? EPGImportStop, .cancelled) }
            XCTAssertEqual(try store.activeIdentity(for: key), old.active)
        }
    }

    func testNetworkPlainGzipRedirectAndTransportRejections() async throws {
        let server = try EPGImportTestServer(xml: Data(fixture(600).utf8), gzip: gzip(Data(fixture(600).utf8)))
        defer { server.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root))
        for path in ["fixture.xml", "fixture.xml.gz", "redirect", "foreign"] {
            let result = try await coordinator.load(key: key,
                request: XMLTVDownloadRequest(url: server.url(path), headers: ["Authorization": "fixture-only", "Range": "bytes=0-2"]))
            XCTAssertEqual(result.active.programmeCount, 600)
        }
        let old = try store.activeIdentity(for: key)
        for path in ["loop", "truncate", "encoded", "invalid", "missing"] {
            do {
                _ = try await coordinator.load(key: key, request: XMLTVDownloadRequest(url: server.url(path)))
                XCTFail("expected rejection: \(path)")
            } catch {}
            XCTAssertEqual(try store.activeIdentity(for: key), old)
        }
        do {
            _ = try await coordinator.load(key: key, request: XMLTVDownloadRequest(url: server.url("slow"), timeout: 0.1, resourceTimeout: 0.2))
            XCTFail("expected timeout")
        } catch { XCTAssertEqual(error as? XMLTVDownloadError, .timeout) }
        await coordinator.close()
        let records = try String(contentsOf: server.directory.appendingPathComponent("requests.jsonl"))
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertTrue(records.allSatisfy { $0["acceptEncoding"] as? String == "identity" && $0["range"] is NSNull })
        let foreign = records.filter { ($0["host"] as? String)?.hasPrefix("localhost:") == true }
        XCTAssertFalse(foreign.isEmpty)
        XCTAssertTrue(foreign.allSatisfy { $0["authorization"] as? Bool == false })
    }

    func testNetworkQueueIsBoundedAndCloseDrainsFiles() async throws {
        let server = try EPGImportTestServer(xml: Data(fixture().utf8), gzip: Data())
        defer { server.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root))
        let slow = XMLTVDownloadRequest(url: server.url("slow"))
        var tasks: [Task<EPGImportReceipt, Error>] = []
        for i in 0..<5 {
            let k = EPGRequestKey(source: .imported(UUID()), revision: key.revision, resource: "xmltv")
            tasks.append(Task { try await coordinator.load(key: k, request: slow) })
            for _ in 0..<100 {
                if await coordinator.operationCount == i + 1 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        do { _ = try await coordinator.load(key: key, request: slow); XCTFail("queue grew") }
        catch { XCTAssertEqual(error as? EPGImportAdmissionError, .queueFull) }
        await coordinator.close()
        for task in tasks {
            do { _ = try await task.value; XCTFail("closed request succeeded") }
            catch { XCTAssertEqual(error as? EPGImportStop, .storeClosing) }
        }
        let count = await coordinator.operationCount
        XCTAssertEqual(count, 0)
    }

    func testNetworkSupersedeAndSharedWaiterCancellation() async throws {
        let server = try EPGImportTestServer(xml: Data(fixture().utf8), gzip: Data())
        defer { server.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root))
        let k = key!, slow = XMLTVDownloadRequest(url: server.url("slow"))
        let first = Task { try await coordinator.load(key: k, request: slow) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let replacement = try await coordinator.load(key: k,
            request: XMLTVDownloadRequest(url: server.url("fixture.xml")), force: true)
        do { _ = try await first.value; XCTFail("superseded succeeded") }
        catch { XCTAssertEqual(error as? EPGImportStop, .superseded) }
        XCTAssertEqual(try store.activeIdentity(for: key), replacement.active)
        let a = Task { try await coordinator.load(key: k, request: slow) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let b = Task { try await coordinator.load(key: k, request: slow) }
        try await Task.sleep(nanoseconds: 50_000_000); a.cancel()
        do { _ = try await a.value; XCTFail("cancelled subscription succeeded") } catch {}
        let shared = try await b.value
        XCTAssertEqual(shared.active.programmeCount, 1)
        await coordinator.close()
    }

    func testSinkFailureSourceRevocationAndLateCancellationRespectDatabase() async throws {
        let old = try await run(Data(fixture().utf8))
        do {
            _ = try await run(Data(fixture(600).utf8)) {
                if $0 == "programmeBatchCommitted" { throw EPGCacheError.sqlite(13) }
            }
            XCTFail("sink failure published")
        } catch { XCTAssertEqual(error as? EPGCacheError, .sqlite(13)) }
        XCTAssertEqual(try store.activeIdentity(for: key), old.active)
        do {
            _ = try await run(Data(fixture().utf8)) { [self] in
                if $0 == "validated" { try store.setSourceEnabled(key.source, enabled: false) }
            }
            XCTFail("revoked source published")
        } catch { XCTAssertEqual(error as? EPGCacheError, .superseded) }
        XCTAssertNil(try store.activeIdentity(for: key))
        try store.setSourceEnabled(key.source, enabled: true)
        let control = EPGImportControl()
        store.boundaryForTesting = { if $0 == "activateAfterCommit" { control.stop() } }
        let result = try await run(Data(fixture().utf8), control: control)
        XCTAssertEqual(try store.activeIdentity(for: key), result.active)
        store.boundaryForTesting = nil
    }

    func testActualSQLiteFullPreservesOldAndRecovers() async throws {
        let old = try await run(Data(fixture().utf8))
        store.close(); store = try EPGCacheStore(directory: directory, maximumDatabaseBytes: 65_536)
        do { _ = try await run(Data(fixture(2000).utf8)); XCTFail("expected SQLITE_FULL") }
        catch {
            guard case EPGCacheError.sqlite(let code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code & 255, 13)
        }
        XCTAssertEqual(try store.activeIdentity(for: key), old.active)
        let result = try await run(Data("<tv/>".utf8))
        XCTAssertEqual(result.active.programmeCount, 0)
    }

    func testValidationSQLCancellationClearsWriterHandler() async throws {
        let old = try await run(Data(fixture().utf8))
        let h = try store.begin(key)
        let p = EPGProgramme(channelID: "a", title: "test", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60))
        try store.append((0..<512).map { EPGCacheRecord(ordinal: $0, programme: p) }, to: h)
        var calls = 0
        XCTAssertThrowsError(try store.validate(h, summary: EPGCacheValidation(rawProgrammeCount: 512,
            emittedProgrammeCount: 512, minimumStart: p.start, maximumEnd: p.end), checkCancellation: {
                calls += 1; if calls >= 3 { throw EPGImportStop.cancelled }
            })) { XCTAssertEqual($0 as? EPGImportStop, .cancelled) }
        XCTAssertGreaterThanOrEqual(calls, 3)
        try store.abandon(h)
        XCTAssertEqual(try store.activeIdentity(for: key), old.active)
        _ = try await run(Data(fixture().utf8))
    }

    func testStagingRecoverySkipsActiveAndForeignChildren() throws {
        let owner = try XMLTVStagingFile.create(in: root)
        try owner.write(Data("<tv/>".utf8))
        let result = try XMLTVStagingFile.recoverStale(in: root)
        XCTAssertEqual(result.removed, 0); XCTAssertEqual(result.skipped, 1)
        let file = try owner.finishAndTransfer()
        XCTAssertEqual(try XMLTVStagingFile.recoverStale(in: root).removed, 0)
        try file.release()
        let stranger = URL(fileURLWithPath: root).appendingPathComponent("xmltv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("foreign".utf8).write(to: stranger.appendingPathComponent("keep"))
        XCTAssertEqual(try XMLTVStagingFile.recoverStale(in: root).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.appendingPathComponent("keep").path))
        try FileManager.default.removeItem(at: stranger)
    }

    func testImporterCrashRecoveryIncludesOwnedStagingFiles() async throws {
        for boundary in ["programmeBatchCommitted", "parsedComplete", "validateBeforeCommit", "activateBeforeCommit", "activateAfterCommit"] {
            let old = try await run(Data(fixture().utf8)); store.close()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "OKVideoPersistenceTests.EPGImportCrashWorkerTests/testWorker", Bundle(for: Self.self).bundleURL.path]
            var env = ProcessInfo.processInfo.environment
            env["EPG9C3_CRASH_DB"] = directory.path; env["EPG9C3_CRASH_ROOT"] = root
            env["EPG9C3_CRASH_SOURCE"] = key.source.id.uuidString; env["EPG9C3_CRASH_AT"] = boundary
            child.environment = env
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            let ended = DispatchSemaphore(value: 0); child.terminationHandler = { _ in ended.signal() }
            try child.run()
            let exited = await Task.detached { waitForCrashProcessExit(ended) }.value
            if !exited {
                kill(child.processIdentifier, SIGKILL); child.waitUntilExit(); XCTFail("crash point timeout")
            }
            XCTAssertEqual(child.terminationReason, .uncaughtSignal); XCTAssertEqual(child.terminationStatus, SIGKILL)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("reached")), boundary)
            store = try EPGCacheStore(directory: directory)
            let active = try XCTUnwrap(store.activeIdentity(for: key))
            if boundary == "activateAfterCommit" { XCTAssertEqual(active.programmeCount, 600) }
            else { XCTAssertEqual(active, old.active, boundary) }
            _ = try XMLTVStagingFile.recoverStale(in: root)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
            let importer = EPGXMLTVImporter(store: store)
            XCTAssertTrue(importer.cleanup(maximumSteps: 32))
            let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"))
            XCTAssertEqual(try db.string("PRAGMA quick_check"), "ok")
            XCTAssertEqual(try db.integer("SELECT COUNT(*) FROM programmes"), Int64(active.programmeCount)); db.close()
        }
    }
}

final class EPGImportCrashWorkerTests: XCTestCase {
    func testWorker() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let db = env["EPG9C3_CRASH_DB"], let root = env["EPG9C3_CRASH_ROOT"],
              let source = env["EPG9C3_CRASH_SOURCE"].flatMap(UUID.init(uuidString:)), let boundary = env["EPG9C3_CRASH_AT"] else {
            throw XCTSkip("Independent process crash worker only")
        }
        let directory = URL(fileURLWithPath: db), store = try EPGCacheStore(directory: URL(fileURLWithPath: db))
        let owner = try XMLTVStagingFile.create(in: root)
        let p = "<programme channel='a' start='20260101000000 +0000' stop='20260101010000 +0000'><title>T</title></programme>"
        let xml = Data(("<tv>" + String(repeating: p, count: 600) + "</tv>").utf8)
        for offset in stride(from: 0, to: xml.count, by: 65536) { try owner.write(xml.subdata(in: offset..<min(offset+65536, xml.count))) }
        let file = try owner.finishAndTransfer(), importer = EPGXMLTVImporter(store: store)
        let crash: (String) -> Void = { name in
            if name == boundary {
                try! Data(name.utf8).write(to: directory.appendingPathComponent("reached"), options: .atomic)
                kill(getpid(), SIGKILL)
                // Signal delivery is asynchronous across threads. Never allow
                // the worker to reach COMMIT after recording a precommit kill.
                while true { pause() }
            }
        }
        importer.boundaryForTesting = crash; store.boundaryForTesting = crash
        let key = EPGRequestKey(source: .imported(source), revision: String(repeating: "a", count: 64), resource: "xmltv")
        _ = try await Task.detached { try importer.importLocal(file, key: key) }.value
        XCTFail("crash boundary not reached")
    }
}

final class EPGImportTestServer {
    let directory: URL
    let process = Process()
    let port: Int
    private let closeLock = NSLock()
    private var didClose = false
    init(xml: Data, gzip: Data) throws {
        directory = URL(fileURLWithPath: "/private/tmp/EPGImportServer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try xml.write(to: directory.appendingPathComponent("fixture.xml"))
        try gzip.write(to: directory.appendingPathComponent("fixture.xml.gz"))
        let repo = String(#filePath.split(separator: "\n")[0]).components(separatedBy: "/OKVideoMac/macOS/")[0]
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repo + "/Tools/SourceAudit/EPGImportProbe/server.py", directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let value = try? String(contentsOf: portFile), let number = Int(value) else {
            process.terminate(); throw EPGImportAdmissionError.closed
        }
        port = number
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    func close() {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }
        if process.isRunning {
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            process.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 2)
            }
            process.terminationHandler = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}

private func waitForCrashProcessExit(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 30) == .success
}
