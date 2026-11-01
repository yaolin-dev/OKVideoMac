import AppKit
import SwiftUI
import XCTest
@testable import OKVideoMac

@MainActor final class LiveRefreshAllTests: XCTestCase {
    private func demand(_ name: String, priority: Int = 2) -> LivePreviewDemand {
        var value = LivePreviewDemand(key: LivePreviewPolicy.digest([name]), sourceKey: "all-fixture", channelID: name,
            programmeStart: nil, resolve: { [.init(url: "https://example.invalid/" + name, headers: [:])] }, isValid: { true })
        value.priority = priority
        return value
    }
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 9,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }
    private func cache() -> LivePreviewCache {
        LivePreviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("refresh-all-" + UUID().uuidString))
    }
    private func settle(_ seconds: Double = 0.2) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testManualRoundStartsImmediatelyAndSurvivesEmptyFilterAndGroupChanges() async throws {
        let owner = UUID(), data = try image(), started = expectation(description: "visible starts immediately")
        // The scheduler reserves one slot for newly visible channels while
        // a visible first pass is running: one visible + one background here.
        let firstBatch = expectation(description: "visible and background captures start before either completes")
        firstBatch.expectedFulfillmentCount = 2
        let all = (0..<16).map { demand("channel-\($0)", priority: $0 == 0 ? 0 : 2) }
        var captured: [String] = [], startedNames: [String] = [], gate = false, releaseFirstBatch = false
        let service = LivePreviewCoordinator(cache: cache(), maximumConcurrentCaptures: 3) { input in
            let name = URL(string: input.url)!.lastPathComponent
            startedNames.append(name)
            if startedNames.count <= 2 { firstBatch.fulfill() }
            if name == "channel-0" { started.fulfill() }
            while !releaseFirstBatch { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 80_000_000)
            captured.append(name); return data
        }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: [all[0]], mayCapture: { gate })
        gate = true
        service.requestRefresh(demands: all)
        XCTAssertEqual(service.activity.presentation?.total, 16, "Click publishes the full scope synchronously")
        XCTAssertEqual(service.activity.toolbar.state?.indicator, .active)
        await fulfillment(of: [started, firstBatch], timeout: 1)
        XCTAssertEqual(startedNames.count, 2)
        XCTAssertTrue(startedNames.contains("channel-0"), "The visible channel must be in the first scheduled batch")
        releaseFirstBatch = true
        service.requestRefresh(demands: all)
        service.update(owner: owner, demands: [], mayCapture: { true })
        try await settle(0.15)
        XCTAssertEqual(service.activity.presentation?.total, 16)
        service.update(owner: owner, demands: [all[10]], mayCapture: { true })
        try await settle(1.2)
        XCTAssertEqual(captured.count, 16); XCTAssertEqual(Set(captured).count, 16)
        XCTAssertEqual(service.activity.presentation?.total, 16)
        XCTAssertEqual(service.activity.presentation?.completed, 16)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
        XCTAssertFalse(service.refreshing)
    }

    func testStoppedRoundRejectsLateResultsAndDoesNotRestartOnViewportChanges() async throws {
        let owner = UUID(), data = try image(), started = expectation(description: "capture starts")
        var calls = 0
        let item = demand("stop", priority: 0)
        let service = LivePreviewCoordinator(cache: cache()) { _ in
            calls += 1; if calls == 1 { started.fulfill() }
            // A native decoder can return after its task was cancelled.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return data
        }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: [item], mayCapture: { true })
        service.requestRefresh(demands: [item])
        await fulfillment(of: [started], timeout: 1)
        service.stopRefresh(sourceKey: "wrong-source")
        XCTAssertTrue(service.refreshing)
        service.stopRefresh(sourceKey: "all-fixture")
        XCTAssertEqual(service.activity.presentation?.phase, .stopped)
        service.update(owner: owner, demands: [], mayCapture: { true })
        service.setSurfaceActive(owner: owner, isActive: true, autoRefresh: true)
        try await settle(0.3)
        XCTAssertEqual(calls, 1); XCTAssertNil(service.image(for: item.key, programmeStart: nil))
        XCTAssertEqual(service.activity.presentation?.phase, .stopped)
        XCTAssertEqual(service.activity.toolbar.state?.indicator, .idle)
        service.capture = { _ in calls += 1; return data }
        service.requestRefresh(demands: [item])
        try await settle()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
    }

    func testPausedManualRoundResumesOnlyRemainingChannelsAndKeepsTotal() async throws {
        let owner = UUID(), data = try image(), started = expectation(description: "slow capture starts")
        let all = [demand("fast", priority: 0), demand("slow", priority: 0), demand("waiting")]
        var completed: [String] = [], slowStarts = 0
        let service = LivePreviewCoordinator(cache: cache(), maximumConcurrentCaptures: 1) { input in
            let name = URL(string: input.url)!.lastPathComponent
            if name == "slow" {
                slowStarts += 1
                if slowStarts == 1 { started.fulfill(); try await Task.sleep(nanoseconds: 5_000_000_000) }
            }
            completed.append(name); return data
        }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: [all[0]], mayCapture: { true })
        service.requestRefresh(demands: all)
        await fulfillment(of: [started], timeout: 1)
        service.suspend(owner: owner)
        try await settle()
        XCTAssertEqual(service.activity.presentation?.phase, .paused)
        XCTAssertEqual(service.activity.presentation?.total, 3)
        XCTAssertEqual(service.activity.presentation?.captured, 1)
        service.update(owner: owner, demands: [], mayCapture: { true })
        try await settle(0.35)
        XCTAssertEqual(completed, ["fast", "slow", "waiting"])
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
        XCTAssertEqual(service.activity.presentation?.total, 3)
    }

    func testPartialFailureIsQuietPreservesSavedPictureAndRetriesOnlyFailed() async throws {
        let owner = UUID(), data = try image(), store = cache()
        let all = [demand("good", priority: 0), demand("bad", priority: 0)]
        await store.store(.init(data: data, captured: Date().addingTimeInterval(-60), sourceKey: "all-fixture"), key: all[1].key)
        var calls: [String] = []
        let service = LivePreviewCoordinator(cache: store) { input in
            let name = URL(string: input.url)!.lastPathComponent
            calls.append(name)
            if name == "bad" { throw LivePreviewCaptureError.unavailable }
            return data
        }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: all, mayCapture: { false })
        try await settle()
        let previous = try XCTUnwrap(service.image(for: all[1].key, programmeStart: nil))
        service.update(owner: owner, demands: all, mayCapture: { true })
        service.requestRefresh(demands: all)
        try await settle(0.35)
        XCTAssertEqual(service.activity.presentation?.phase, .partial)
        XCTAssertEqual(service.activity.toolbar.state?.indicator, .idle)
        XCTAssertEqual(service.activity.presentation?.failed, 1)
        XCTAssertEqual(service.image(for: all[1].key, programmeStart: nil)?.captured, previous.captured)
        XCTAssertFalse(service.refreshing)
        service.capture = { input in calls.append(URL(string: input.url)!.lastPathComponent); return data }
        service.retryFailed(sourceKey: "all-fixture")
        try await settle()
        XCTAssertEqual(calls.filter { $0 == "good" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "bad" }.count, 2)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
        XCTAssertEqual(service.activity.presentation?.total, 1)
    }

    func testFullScopeRejectsLateResultsAfterSourceChange() async throws {
        let owner = UUID(), data = try image(), started = expectation(description: "old source running")
        let old = demand("old", priority: 0)
        let service = LivePreviewCoordinator(cache: cache()) { _ in
            started.fulfill(); try? await Task.sleep(nanoseconds: 2_000_000_000); return data
        }
        service.update(owner: owner, demands: [old], mayCapture: { true })
        service.requestRefresh(demands: [old])
        await fulfillment(of: [started], timeout: 1)
        service.clear(owner: owner)
        let nextOwner = UUID()
        defer { service.clear(owner: nextOwner) }
        service.update(owner: nextOwner, demands: [demand("new")], mayCapture: { false })
        try await settle()
        XCTAssertNil(service.image(for: old.key, programmeStart: nil))
        XCTAssertEqual(service.activity.presentation?.total, 1)
        XCTAssertEqual(service.activity.presentation?.captured, 0)
    }

    func testCatalogReplacementRejectsOldClosuresEvenWhenPictureKeysMatch() async throws {
        let owner = UUID(), data = try image()
        var oldValid = true
        let old = LivePreviewDemand(key: LivePreviewPolicy.digest(["same-picture"]), sourceKey: "all-fixture", channelID: "same-picture",
            programmeStart: nil, resolve: { [.init(url: "https://example.invalid/old", headers: [:])] }, isValid: { oldValid })
        let service = LivePreviewCoordinator(cache: cache()) { _ in return data }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: [old], mayCapture: { false })
        service.requestRefresh(demands: [old])
        XCTAssertTrue(service.refreshing)
        oldValid = false
        service.update(owner: owner, demands: [demand("same-picture", priority: 0)], mayCapture: { true })
        try await settle(0.4)
        XCTAssertFalse(service.refreshing)
        XCTAssertEqual(service.activity.presentation?.total, 1)
        XCTAssertEqual(service.activity.presentation?.captured, 1)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
    }

    func testRefreshPausedByPlaybackWakesWithoutAnotherViewportUpdate() async throws {
        let owner = UUID(), data = try image(), item = demand("wake", priority: 0)
        let service = LivePreviewCoordinator(cache: cache()) { _ in return data }
        defer { service.clear(owner: owner) }
        var permit = true
        service.update(owner: owner, demands: [item], mayCapture: { permit })
        service.requestRefresh(demands: [item])
        try await settle(0.3)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
        permit = false
        service.requestRefresh(demands: [item])
        try await settle()
        XCTAssertEqual(service.activity.presentation?.phase, .paused)
        permit = true
        try await settle(1.2)
        XCTAssertEqual(service.activity.presentation?.phase, .completed)
        XCTAssertEqual(service.activity.presentation?.captured, 1)
    }

    func testNativeDetailsFitInBothAppearancesWithoutStartingWork() async throws {
        var actions = 0
        for dark in [false, true] {
            for phase in [LivePreviewActivityPresentation.Phase.capturing, .partial, .stopped] {
                let value = LivePreviewActivityPresentation(sourceKey: "all-fixture", phase: phase,
                    visibleReady: 8, visibleTotal: 12, active: phase == .capturing ? 3 : 0,
                    queued: phase == .capturing ? 37 : 0, completed: phase == .capturing ? 20 : 60,
                    total: 60, captured: phase == .capturing ? 20 : 52, cached: 0, failed: phase == .capturing ? 0 : 8)
                let root = LiveBackgroundActivityDetails(sourceName: "直播源 · 全部频道", epg: nil, validation: nil,
                    catalogLoading: false, catalogFailed: false, hasCatalog: true, nativeEPGEnabled: true,
                    preview: value, retryPreviews: { actions += 1 }, stopPreviews: { actions += 1 }, stop: { _ in })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root), size = NSSize(width: 320, height: 400)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.backgroundColor = .windowBackgroundColor
                let fit = host.fittingSize
                XCTAssertEqual(fit.width, 320, accuracy: 0.5); XCTAssertLessThan(fit.height, 400)
                host.frame = NSRect(origin: .zero, size: fit); host.layoutSubtreeIfNeeded()
                try await settle(0.08)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OKVideoLiveRefreshUI")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    dir.appendingPathComponent("\(phase)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
        XCTAssertEqual(actions, 0)
    }
}
