import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class XtreamArchiveCacheTests: XCTestCase {
    func testFullHistoryNeverReusesShortEPGEntry() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-Xtream-Archive-" + UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let key = EPGRequestKey(source: .xtream(UUID()), revision: "fixture", resource: "42")
        let anchor = Date(timeIntervalSince1970: 1704067200)
        let short = EPGPayload(guide: .init(channels: [], programmes: [.init(channelID: "42", title: "Short", start: anchor, end: anchor.addingTimeInterval(3600))]))
        _ = try await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server",
            configurationRevision: "fixture", at: anchor, demandRevision: UUID(), fetch: { short })
        let full = EPGPayload(guide: .init(channels: [], programmes: (0..<20).map { index in
            EPGProgramme(channelID: "42", title: "Archive \(index)",
                start: anchor.addingTimeInterval(Double(index) * 3600), end: anchor.addingTimeInterval(Double(index + 1) * 3600))
        }))
        let result = try await repository.loadXtreamWindow(key: key, accountIdentity: "account", serverIdentity: "server",
            configurationRevision: "fixture", from: anchor, to: anchor.addingTimeInterval(12 * 3600),
            demandRevision: UUID(), archive: true, fetch: { full })
        XCTAssertEqual(result.page.records.count, 12)
        XCTAssertEqual(result.page.records.first?.title, "Archive 0")
        let unchanged = try await repository.loadXtream(key: key, accountIdentity: "account", serverIdentity: "server",
            configurationRevision: "fixture", at: anchor, demandRevision: UUID(), fetch: {
                XCTFail("Short EPG must retain its own cached entry"); return full
            })
        XCTAssertEqual(unchanged.items.first?.current?.title, "Short")
        _ = await repository.close()
    }
}
