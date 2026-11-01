import AppKit
import XCTest
import OKVideoCore
@testable import OKVideoMac

final class PosterDiskCacheTests: XCTestCase {
    private final class Clock { var time = Date(timeIntervalSince1970: 1_000) }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("poster-budget-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func file(_ directory: URL, _ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%064x.image", index))
    }
    func testBudgetEvictsLeastRecentlyUsedAndRetainsDecodedBytes() throws {
        let dir = try directory(), clock = Clock()
        var cache = PosterDiskCache(directory: dir, policy: .init(maximumBytes: 8, minimumFreeBytes: 0),
            availableBytes: { 100 }, now: { clock.time })
        let a = file(dir, 1), b = file(dir, 2), c = file(dir, 3)
        XCTAssertTrue(cache.store(Data(repeating: 1, count: 4), at: a))
        clock.time += 1; XCTAssertTrue(cache.store(Data(repeating: 2, count: 4), at: b))
        let inUse = try Data(contentsOf: b)
        clock.time += 1; cache.touch(a)
        clock.time += 1; XCTAssertTrue(cache.store(Data(repeating: 3, count: 4), at: c))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(inUse, Data(repeating: 2, count: 4))
    }
    func testExistingCacheIsTrimmedOnReadAfterRestart() throws {
        let dir = try directory(), a = file(dir, 1), b = file(dir, 2)
        try Data(repeating: 1, count: 5).write(to: a)
        try Data(repeating: 2, count: 5).write(to: b)
        var cache = PosterDiskCache(directory: dir, policy: .init(maximumBytes: 5, minimumFreeBytes: 0), availableBytes: { 100 })
        cache.touch(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try Data(contentsOf: b).count, 5)
    }
    func testLowSpaceAndOversizeSkipWritesAndPreserveUnownedFiles() throws {
        let dir = try directory(), other = dir.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: other)
        var cache = PosterDiskCache(directory: dir, policy: .init(maximumBytes: 8, minimumFreeBytes: 10), availableBytes: { 5 })
        XCTAssertFalse(cache.store(Data(repeating: 1, count: 4), at: file(dir, 1)))
        XCTAssertFalse(cache.store(Data(repeating: 1, count: 9), at: file(dir, 2)))
        XCTAssertEqual(try String(contentsOf: other), "keep")
    }
    func testLowSpaceReclaimsOwnedCacheAndOversizedLegacyReadCanBeEvicted() throws {
        let dir = try directory(), a = file(dir, 1)
        var free: Int64 = 100
        var cache = PosterDiskCache(directory: dir, policy: .init(maximumBytes: 8, minimumFreeBytes: 10), availableBytes: { free })
        XCTAssertTrue(cache.store(Data(repeating: 1, count: 8), at: a))
        free = 5
        cache.touch(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        try Data(repeating: 2, count: 12).write(to: a)
        cache.reset(); free = 100
        let retained = try Data(contentsOf: a)
        cache.touch(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(retained.count, 12)
    }
    func testFailedWritesAreOptionalAndUnknownCapacityStillHonorsBudget() throws {
        let dir = try directory(), blocked = file(dir, 1)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        var cache = PosterDiskCache(directory: dir, policy: .init(maximumBytes: 4, minimumFreeBytes: 10), availableBytes: { nil })
        XCTAssertFalse(cache.store(Data([1]), at: blocked))
        XCTAssertTrue(cache.store(Data(repeating: 1, count: 4), at: file(dir, 2)))
        XCTAssertTrue(cache.store(Data(repeating: 2, count: 4), at: file(dir, 3)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir, 2).path))
    }
    @MainActor func testDownloadedImageStillDisplaysWhenCacheCannotWrite() async throws {
        let dir = try directory()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: .init(x: 0, y: 0, width: 4, height: 4)).fill(); image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let source = try ImageDataRepository(cacheDirectory: dir, httpClient: ImageClient(data: data))
        let repository = ImageRepository(dataRepository: source)
        // The directory disappearing is equivalent to an unavailable cache disk.
        try FileManager.default.removeItem(at: dir)
        try Data().write(to: dir)
        let value = try await repository.image(for: URL(string: "https://fixture.invalid/poster")!)
        XCTAssertGreaterThan(value.size.width, 0)
        let unavailable = try ImageDataRepository(cacheDirectory: dir, httpClient: ImageClient(data: data))
        let second = try await ImageRepository(dataRepository: unavailable).image(for: URL(string: "https://fixture.invalid/another")!)
        XCTAssertGreaterThan(second.size.width, 0)
    }
    private struct ImageClient: HTTPClient {
        let data: Data
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: data)
        }
    }
}
