import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class OriginalResourcePersistenceTests: XCTestCase {
    func testSQLiteReplacementKeepsOneRecordAndOriginalMetadataAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let original = OriginalMediaResource(provider: "baidu", shareID: "share", ownerID: "owner", fileID: "file-13",
            originalFilename: "S01E13.mp4", providerPath: "%2Fsharelink%2FS01E13.mp4", provenance: "wogg-baidu-detail")
        let old = HistoryRecord(configurationID: UUID(), siteKey: "fixture", videoID: "132964", title: "影片",
            sourceName: "嘟嘟无限", episodeName: "第13集", position: 2635.4, duration: 2778)
        var fresh = old
        fresh.sourceKey = "嘟嘟无限2"; fresh.sourceName = fresh.sourceKey
        fresh.watchedAt = old.watchedAt.addingTimeInterval(1)
        fresh.playbackReference = HistoryPlaybackReference(sourceIdentity: "source", resourceIdentity: "resource", originalResource: original)
        do {
            let store = try SQLiteStore(databaseURL: url)
            try await store.saveHistory(old, incognito: false)
            let committed = try await store.saveWatchedHistory(fresh, replacing: old, sessionID: UUID())
            XCTAssertTrue(committed)
        }
        let reopened = try SQLiteStore(databaseURL: url)
        let records = try await reopened.history()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.position, 2635.4)
        XCTAssertEqual(records.first?.playbackReference?.originalResource, original)
    }

    func testLegacyHistoryDecodesWithoutInventingOriginalFilename() throws {
        let old = Data(#"{"version":4,"sourceIdentity":"source-1","resourceIdentity":"resource-1","replayHeaders":{}}"#.utf8)
        let value = try JSONDecoder().decode(HistoryPlaybackReference.self, from: old)
        XCTAssertNil(value.originalResource)
    }
    func testOriginalMetadataRoundTripsAndSanitizesIndependentlyFromLabels() throws {
        let original = OriginalMediaResource(provider: "baidu", shareID: "share", ownerID: "owner", fileID: "file",
            originalFilename: "S01E13.mp4", providerPath: "%2Fsharelink%2FS01E13.mp4", byteSize: 1571407203,
            provenance: "wogg-baidu-detail")
        let reference = HistoryPlaybackReference(sourceIdentity: "source-1", resourceIdentity: "resource-1", originalResource: original)
        let record = HistoryRecord(siteKey: "玩偶", videoID: "132964", title: "影片", sourceName: "嘟嘟无限", episodeName: "第13集",
            playbackReference: reference, position: 2635.4, duration: 2778)
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.playbackReference?.originalResource, original)
        XCTAssertEqual(decoded.position, 2635.4)
        XCTAssertEqual(reference.sanitizedForPersistence()?.originalResource, original)
    }
}
