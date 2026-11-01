import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class EPGRefreshPolicyTests: XCTestCase {
    func testExpiredXMLTVDoesNotDownloadAgainUntilCoverageRetryAndManualBypassesIt() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/EPGCache-Refresh-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let clock = EPGRefreshClock(Date().addingTimeInterval(60))
        let server = try EPGImportTestServer(xml: Data("""
            <tv><channel id="a"><display-name>A</display-name></channel>
            <programme channel="a" start="20200101000000 +0000" stop="20200101010000 +0000"><title>Old</title></programme></tv>
            """.utf8), gzip: Data())
        defer { server.close() }
        let repository = EPGProductionRepository(cacheDirectory: root, now: { clock.value })
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "f", count: 64), resource: "xmltv")
        var result = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"))
        XCTAssertEqual(result.nextRetryAt.timeIntervalSince(clock.value), 300, accuracy: 0.01)
        XCTAssertEqual(result.availability, .stale)
        for expectedDelay in [600.0, 900.0, 900.0] {
            let oldVersion = result.summary?.dataVersion
            let deadline = result.nextRetryAt
            clock.value = deadline.addingTimeInterval(-1)
            let cached = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"))
            XCTAssertEqual(cached.summary?.dataVersion, oldVersion, "A successful but expired guide must not cause a download loop")
            clock.value = deadline
            result = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"))
            XCTAssertNotEqual(result.summary?.dataVersion, oldVersion)
            XCTAssertEqual(result.nextRetryAt.timeIntervalSince(clock.value), expectedDelay, accuracy: 0.01)
        }
        let forced = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"), force: true)
        XCTAssertNotEqual(forced.summary?.dataVersion, result.summary?.dataVersion)
        _ = await repository.close()
    }

    func testSimultaneousXMLTVManualRefreshesShareOneImportAndFailureCount() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/EPGCache-Refresh-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let server = try EPGImportTestServer(xml: Data("<tv/>".utf8), gzip: Data())
        defer { server.close() }
        let repository = EPGProductionRepository(cacheDirectory: root)
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "a", count: 64), resource: "xmltv")
        async let first = repository.refreshXMLTV(key: key, url: server.url("fixture.xml"), force: true)
        async let second = repository.refreshXMLTV(key: key, url: server.url("fixture.xml"), force: true)
        let (a, b) = try await (first, second)
        XCTAssertNotNil(a.summary)
        XCTAssertEqual(a.summary?.dataVersion, b.summary?.dataVersion)
        async let bad1 = repository.refreshXMLTV(key: key, url: server.url("missing"), force: true)
        async let bad2 = repository.refreshXMLTV(key: key, url: server.url("missing"), force: true)
        let (c, d) = try await (bad1, bad2)
        XCTAssertEqual(c.consecutiveFailures, 1)
        XCTAssertEqual(d.consecutiveFailures, 1)
        XCTAssertEqual(c.summary?.dataVersion, a.summary?.dataVersion)
        _ = await repository.close()
    }

    func testTVBoxAndXtreamBackoffManualRetryAndRecovery() async throws {
        for tvbox in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/EPGCache-Refresh-" + UUID().uuidString)
            defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
            let clock = EPGRefreshClock(Date(timeIntervalSince1970: 100))
            let repository = EPGProductionRepository(cacheDirectory: root, now: { clock.value })
            let source: LiveSourceID = tvbox ? .imported(UUID()) : .xtream(UUID())
            let key = EPGRequestKey(source: source, revision: "r1", resource: "one")
            let requests = EPGRefreshRequests()
            func load(_ refreshID: UUID? = nil, succeeds: Bool = false) async throws -> EPGAvailability {
                let fetch: @Sendable () async throws -> EPGPayload = {
                    await requests.increment()
                    if !succeeds { throw EPGFetchError.unavailable }
                    return EPGPayload(guide: .init(channels: [], programmes: [
                        .init(channelID: "one", title: "Recovered", start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 10000))
                    ]))
                }
                if tvbox {
                    return try await repository.loadTVBoxDay(key: key, day: "2026-10-31", timeZoneID: "UTC",
                        demandRevision: UUID(), refreshID: refreshID, fetch: fetch).availability
                }
                return try await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server",
                    configurationRevision: "r1", at: clock.value, demandRevision: UUID(), refreshID: refreshID, fetch: fetch).availability
            }
            var count = 0
            for delay in [60.0, 120.0, 240.0, 480.0, 900.0, 900.0] {
                do { _ = try await load(); XCTFail("Expected fetch failure") } catch {}
                count += 1
                let info = await repository.refreshInfo(source: source, revision: "r1", resources: ["one"])
                XCTAssertEqual(try XCTUnwrap(info.retryAt).timeIntervalSince(clock.value), delay, accuracy: 0.01)
                for _ in 0..<3 { _ = try? await load() }
                let actual = await requests.value
                XCTAssertEqual(actual, count, "Normal polling must honor retry backoff")
                clock.value = try XCTUnwrap(info.retryAt)
            }
            let manual = UUID()
            _ = try? await load(manual)
            count += 1
            _ = try? await load(manual)
            let once = await requests.value
            XCTAssertEqual(once, count, "One manual action may span multiple query slices")
            let recovered = try await load(UUID(), succeeds: true)
            XCTAssertEqual(recovered, .fresh)
            let info = await repository.refreshInfo(source: source, revision: "r1", resources: ["one"])
            XCTAssertNil(info.retryAt)
            XCTAssertEqual(info.lastUpdatedAt, clock.value)
            _ = try await load(succeeds: false)
            let after = await requests.value
            XCTAssertEqual(after, count + 1, "Successful recovery restores the normal cache")
            _ = await repository.close()
        }
    }

    func testRefreshMetadataIsScopedToRequestedDayAndArchiveAndNowNextUsesNewArchive() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/EPGCache-Scope-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let clock = EPGRefreshClock(Date(timeIntervalSince1970: 100))
        let repository = EPGProductionRepository(cacheDirectory: root, now: { clock.value })
        let imported = LiveSourceID.imported(UUID()), xtream = LiveSourceID.xtream(UUID())
        let dailyKey = EPGRequestKey(source: imported, revision: "r", resource: "one")
        let key = EPGRequestKey(source: xtream, revision: "r", resource: "one")
        let old = EPGPayload(guide: .init(channels: [], programmes: [
            .init(channelID: "one", title: "Old", start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 200))]))
        let new = EPGPayload(guide: .init(channels: [], programmes: [
            .init(channelID: "one", title: "Updated", start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 200))]))
        _ = try? await repository.loadTVBoxDay(key: dailyKey, day: "2026-10-30", timeZoneID: "UTC", demandRevision: UUID()) { throw EPGFetchError.unavailable }
        _ = try await repository.loadTVBoxDay(key: dailyKey, day: "2026-10-31", timeZoneID: "UTC", demandRevision: UUID()) { new }
        let today = await repository.refreshInfo(source: imported, revision: "r", resources: ["one"],
            dayScope: ["one": ["2026-10-31"]], includeXMLTV: false)
        XCTAssertNil(today.retryAt, "Yesterday's failure must not label today's programme guide as failed")
        XCTAssertEqual(today.lastUpdatedAt, clock.value)
        _ = try await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server", configurationRevision: "r",
            at: clock.value, demandRevision: UUID()) { old }
        _ = try? await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server", configurationRevision: "r",
            at: clock.value, demandRevision: UUID(), force: true) { throw EPGFetchError.unavailable }
        clock.value = clock.value.addingTimeInterval(1)
        _ = try await repository.loadXtreamWindow(key: key, accountIdentity: "account", serverIdentity: "server", configurationRevision: "r",
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1000), demandRevision: UUID(), archive: true, refreshID: UUID()) { new }
        let archive = await repository.refreshInfo(source: xtream, revision: "r", resources: ["one"], archiveOnly: true)
        XCTAssertNil(archive.retryAt)
        let batch = try await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server", configurationRevision: "r",
            at: clock.value, demandRevision: UUID()) { XCTFail("A fresh archive already supplies Now/Next"); return old }
        XCTAssertEqual(batch.items.first?.current?.title, "Updated")
        _ = await repository.close()
    }

    func testTVBoxManualRefreshSharesFlightPreservesOldDataAndCancellationDoesNotBackoff() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/EPGCache-Refresh-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let repository = EPGProductionRepository(cacheDirectory: root)
        let key = EPGRequestKey(source: .imported(UUID()), revision: "r", resource: "one")
        let count = EPGRefreshRequests(), manual = UUID()
        let fetch: @Sendable () async throws -> EPGPayload = {
            await count.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return .init(guide: .init(channels: [], programmes: [
                .init(channelID: "one", title: "Saved", start: Date(), end: Date().addingTimeInterval(3600))]))
        }
        async let first = repository.loadTVBoxDay(key: key, day: "2026-10-31", timeZoneID: "UTC", demandRevision: UUID(), refreshID: manual, fetch: fetch)
        async let second = repository.loadTVBoxDay(key: key, day: "2026-10-31", timeZoneID: "UTC", demandRevision: UUID(), refreshID: manual, fetch: fetch)
        let (a, b) = try await (first, second)
        let fetched = await count.value
        XCTAssertEqual(fetched, 1)
        XCTAssertEqual(a.token.dataVersion, b.token.dataVersion)
        do {
            _ = try await repository.loadTVBoxDay(key: key, day: "2026-10-31", timeZoneID: "UTC", demandRevision: UUID(), refreshID: UUID()) { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .cancelled) }
        let cancelledInfo = await repository.refreshInfo(source: .imported(key.source.id), revision: "r", resources: ["one"])
        XCTAssertNil(cancelledInfo.retryAt)
        let stale = try await repository.loadTVBoxDay(key: key, day: "2026-10-31", timeZoneID: "UTC", demandRevision: UUID(), refreshID: UUID()) { throw EPGFetchError.unavailable }
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertEqual(stale.programmes, a.programmes)
        _ = await repository.close()
    }
}

private final class EPGRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); defer { lock.unlock() }; date = newValue }
    }
}
private actor EPGRefreshRequests {
    var value = 0
    func increment() { value += 1 }
}
