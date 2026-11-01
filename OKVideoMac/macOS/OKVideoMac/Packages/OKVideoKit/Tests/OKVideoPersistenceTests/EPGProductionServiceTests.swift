import Foundation
import XCTest
@testable import OKVideoCore
@testable import OKVideoPersistence

final class EPGProductionServiceTests: XCTestCase {
    private func abandonedCount(_ directory: URL) throws -> Int64 {
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"))
        return try db.integer("SELECT COUNT(*) FROM generations WHERE id NOT IN (SELECT active_generation FROM resources WHERE active_generation IS NOT NULL)")
    }

    private func waitForMaintenance(_ directory: URL) async throws {
        for _ in 0..<100 {
            if try abandonedCount(directory) == 0 { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try abandonedCount(directory), 0, "background cleanup did not drain")
    }

    func testStartupMaintenanceDrainsMultipleBatchesAndResumesAfterPause() async throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "c", count: 64), resource: "xmltv")
        let store = try EPGCacheStore(directory: directory)
        let old = try store.begin(key)
        for batch in 0..<12 {
            try store.append((0..<512).map { offset in
                let n = batch * 512 + offset
                return EPGCacheRecord(ordinal: n, programme: EPGProgramme(channelID: "a", title: "old",
                    start: Date(timeIntervalSince1970: Double(n) * 60),
                    end: Date(timeIntervalSince1970: Double(n + 1) * 60)))
            }, to: old)
        }
        try store.abandon(old)
        let active = try store.begin(key)
        try store.validate(active, summary: EPGCacheValidation(rawProgrammeCount: 0,
            emittedProgrammeCount: 0, minimumStart: nil, maximumEnd: nil))
        _ = try store.activate(active)
        store.close()

        let service = try EPGProductionService(cacheDirectory: directory)
        _ = await service.pause()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(try abandonedCount(directory), 1)
        try await service.resume()
        try await waitForMaintenance(directory)
        let summary = try await service.activeSummary(for: key)
        XCTAssertEqual(summary?.dataVersion, active.generation)
        _ = await service.close()
    }

    func testRefreshFailureCancellationAndRestartDoNotLeaveRetiredGenerations() async throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try EPGImportTestServer(xml: fixture(), gzip: Data())
        defer { server.close() }
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "d", count: 64), resource: "xmltv")
        let service = try EPGProductionService(cacheDirectory: directory)
        for _ in 0..<3 { _ = try await service.refreshXMLTV(key: key, url: server.url("fixture.xml")) }
        let active = try await service.activeSummary(for: key)
        let task = Task { try await service.refreshXMLTV(key: key, url: server.url("slow")) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled import succeeded") } catch { }
        do { _ = try await service.refreshXMLTV(key: key, url: server.url("missing")); XCTFail("invalid import succeeded") } catch { }
        try await waitForMaintenance(directory)
        let after = try await service.activeSummary(for: key)
        XCTAssertEqual(after?.dataVersion, active?.dataVersion)
        _ = await service.close()
        let reopened = try EPGProductionService(cacheDirectory: directory)
        try await waitForMaintenance(directory)
        let restored = try await reopened.activeSummary(for: key)
        XCTAssertEqual(restored?.dataVersion, active?.dataVersion)
        _ = await reopened.close()
    }

    private func cacheDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp/EPGCache-Production-" + UUID().uuidString)
    }

    private func fixture(programmes: Int = 2) -> Data {
        let rows = (0..<programmes).map { index in
            let hour = String(format: "%02d", index)
            let next = String(format: "%02d", index + 1)
            return "<programme channel='a' start='20260920\(hour)0000 +0000' stop='20260920\(next)0000 +0000'><title>T\(index)</title></programme>"
        }.joined()
        return Data(("<tv><channel id='a'><display-name>Alpha</display-name></channel>" + rows + "</tv>").utf8)
    }

    func testProductionServicePublishesOnlyFiniteSummaryAndQueries() async throws {
        let directory = cacheDirectory()
        let server = try EPGImportTestServer(xml: fixture(), gzip: Data())
        defer { server.close() }
        let service = try EPGProductionService(cacheDirectory: directory)
        let source = LiveSourceID.imported(UUID())
        let key = EPGRequestKey(source: source, revision: String(repeating: "a", count: 64), resource: "xmltv")

        let summary = try await service.refreshXMLTV(key: key, url: server.url("fixture.xml"))
        XCTAssertEqual(summary.programmeCount, 2)
        XCTAssertEqual(summary.coverageStart, Date(timeIntervalSince1970: 1_789_862_400))
        XCTAssertEqual(summary.coverageEnd, Date(timeIntervalSince1970: 1_789_869_600))
        XCTAssertFalse(summary.resourceIdentity.contains("http"))

        let demand = UUID()
        let channel = LiveChannel(groupName: "", name: "Alpha", streams: [])
        let batch = try await service.queryNowNext([channel], for: key,
            at: Date(timeIntervalSince1970: 1_789_864_200), demandRevision: demand)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(batch.items[0].current?.title, "T0")
        XCTAssertEqual(batch.items[0].next?.title, "T1")
        XCTAssertEqual(batch.token.serviceIncarnation, service.incarnation)
        XCTAssertEqual(batch.token.resourceIdentity, summary.resourceIdentity)
        XCTAssertEqual(batch.token.sourceEpoch, summary.sourceEpoch)
        XCTAssertEqual(batch.token.dataVersion, summary.dataVersion)
        XCTAssertEqual(batch.token.demandRevision, demand)

        let window = try await service.queryWindow(channel, for: key,
            from: Date(timeIntervalSince1970: 1_789_862_400),
            to: Date(timeIntervalSince1970: 1_789_948_799), limit: 1,
            demandRevision: demand)
        XCTAssertEqual(window.page.programmes.map(\.title), ["T0"])
        XCTAssertEqual(window.page.records.map(\.id.ordinal), [0])
        XCTAssertEqual(window.page.records.first?.id.dataVersion, summary.dataVersion)
        XCTAssertTrue(window.page.hasMore)
        XCTAssertNotNil(window.nextCursor)

        let closed = await service.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
    }

    func testPauseIsReversibleAndTerminalCloseWaitIsBounded() async throws {
        let directory = cacheDirectory()
        let server = try EPGImportTestServer(xml: fixture(), gzip: Data())
        defer { server.close() }
        let service = try EPGProductionService(cacheDirectory: directory)
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "b", count: 64), resource: "xmltv")
        let importTask = Task {
            try await service.refreshXMLTV(key: key, url: server.url("slow"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        let paused = await service.pause(deadlineNanoseconds: 0)
        XCTAssertFalse(paused)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1)
        do { _ = try await importTask.value; XCTFail("paused import published") }
        catch { XCTAssertEqual(error as? EPGProductionServiceError, .cancelled) }
        do {
            _ = try await service.refreshXMLTV(key: key, url: URL(string: "https://example.invalid/epg.xml")!)
            XCTFail("paused service accepted import")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .paused) }

        // Keep the wake suspended until cancellation. An immediately scheduled
        // task may otherwise legitimately finish before cancel() is called.
        let wakeSignal = AsyncStream<Void> { _ in }
        let cancelledResume = Task {
            for await _ in wakeSignal { }
            try await service.resume()
        }
        cancelledResume.cancel()
        do { try await cancelledResume.value; XCTFail("cancelled wake resumed service") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await service.refreshXMLTV(key: key, url: server.url("fixture.xml"))
            XCTFail("cancelled wake reopened service")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .paused) }

        try await service.resume()
        let resumed = try await service.refreshXMLTV(key: key, url: server.url("fixture.xml"))
        XCTAssertEqual(resumed.programmeCount, 2)

        let immediateClose = await service.close(deadlineNanoseconds: 0)
        XCTAssertFalse(immediateClose)
        let closed = await service.close()
        XCTAssertTrue(closed)
        do {
            _ = try await service.activeSummary(for: key)
            XCTFail("closed service accepted query")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .closed) }
        try FileManager.default.removeItem(at: directory)
    }
}
