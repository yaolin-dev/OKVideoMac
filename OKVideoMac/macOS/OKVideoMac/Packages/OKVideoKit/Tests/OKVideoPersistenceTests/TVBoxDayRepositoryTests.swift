import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class TVBoxDayRepositoryTests: XCTestCase {
    func testDailyCacheIsIsolatedByDaySourceChannelAndRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = EPGProductionRepository(cacheDirectory: root)
        let source = UUID(), demand = UUID()
        let counts = FetchCounts()
        func load(_ source: UUID, _ channel: String, _ revision: String, _ day: String) async throws -> EPGChannelDayResult {
            let key = EPGRequestKey(source: .imported(source), revision: revision, resource: channel)
            return try await repository.loadTVBoxDay(key: key, day: day, timeZoneID: "UTC", demandRevision: demand) {
                await counts.increment()
                let start = Date(timeIntervalSince1970: 1704067200)
                return .init(guide: .init(channels: [], programmes: [.init(channelID: channel, title: "Synthetic", start: start, end: start.addingTimeInterval(3600))]))
            }
        }
        let first = try await load(source, "one", "r1", "2024-01-01")
        let again = try await load(source, "one", "r1", "2024-01-01")
        XCTAssertEqual(first.token, again.token)
        _ = try await load(source, "one", "r1", "2024-01-02")
        _ = try await load(source, "two", "r1", "2024-01-01")
        _ = try await load(source, "one", "r2", "2024-01-01")
        _ = try await load(UUID(), "one", "r1", "2024-01-01")
        let total = await counts.value
        XCTAssertEqual(total, 5)
        await repository.close()
    }
    func testDailyCacheRejectsWrongSourceAndOversizedProgrammes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = EPGProductionRepository(cacheDirectory: root)
        let key = EPGRequestKey(source: .xtream(UUID()), revision: "r", resource: "one")
        do {
            _ = try await repository.loadTVBoxDay(key: key, day: "2024-01-01", timeZoneID: "UTC", demandRevision: UUID()) {
                XCTFail("Invalid source must not fetch")
                return .init(guide: .init(channels: [], programmes: []))
            }
            XCTFail("Expected rejection")
        } catch {}
        await repository.close()
    }
}
private actor FetchCounts {
    var value = 0
    func increment() { value += 1 }
}
