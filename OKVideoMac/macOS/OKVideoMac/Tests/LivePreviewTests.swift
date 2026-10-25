import AppKit
import SwiftUI
import AVFoundation
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class LivePreviewTests: XCTestCase {
    private func jpeg() throws -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 36))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); image.unlockFocus()
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .jpeg, properties: [:]))
    }
    private func cache() -> LivePreviewCache {
        LivePreviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("LivePreviewTests-" + UUID().uuidString))
    }
    private func demand(_ name: String, valid: @escaping @MainActor () -> Bool = { true }) -> LivePreviewDemand {
        .init(key: LivePreviewPolicy.digest([name]), sourceKey: "fixture", channelID: name, programmeStart: nil,
              resolve: { [.init(url: "https://example.invalid/" + name, headers: [:])] }, isValid: valid)
    }
    private func settle(_ seconds: Double = 1.4) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    func testAllVisiblePicturesSurviveCachePressureWithoutRecapturing() async throws {
        let store = cache(), data = try jpeg(), owner = UUID()
        let requests = (0..<72).map { demand("large-window-\($0)") }
        for request in requests {
            await store.store(.init(data: data, captured: Date().addingTimeInterval(-3600), sourceKey: "fixture"), key: request.key)
        }
        let service = LivePreviewCoordinator(cache: store) { _ in
            XCTFail("Memory pressure must reload disk cache, never open a stream"); return data
        }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: requests, mayCapture: { true })
        try await settle()
        XCTAssertEqual(requests.filter { service.image(for: $0.key, programmeStart: nil) != nil }.count, requests.count)
    }
    func testLogoResolutionRebindCannotEraseSameChannelPreview() throws {
        let card = LiveChannelNativeCard()
        let channel = LiveChannel(groupName: "Fixture", name: "same-channel", streams: [])
        card.bind(channel: channel, favorite: false, urls: [], pixels: 512, repository: nil)
        let image = try XCTUnwrap(NSImage(data: jpeg()))
        card.showPreview(.init(image: image, captured: Date()))
        card.bind(channel: channel, favorite: true, urls: [], pixels: 768, repository: nil)
        XCTAssertTrue(card.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image && !$0.isHidden })
    }
    func testCardRetainsLoadingFrameOnlyForSameSourceAndChannel() throws {
        let card = LiveChannelNativeCard()
        let channel = LiveChannel(groupName: "Fixture", name: "A", streams: [])
        card.bind(channel: channel, favorite: false, urls: [], pixels: 512, repository: nil)
        let image = try XCTUnwrap(NSImage(data: jpeg()))
        let entry = LivePreviewCoordinator.ImageEntry(image: image, captured: Date())
        func displayed() -> Bool { card.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image && !$0.isHidden } }
        card.updatePreview(key: "sourceA/channelA", entry: entry)
        card.updatePreview(key: "sourceA/channelA", entry: nil)
        card.cancelImage()
        XCTAssertTrue(displayed(), "Cache reload and logo cancellation must retain the current channel frame")
        card.updatePreview(key: "sourceB/channelA", entry: nil)
        XCTAssertFalse(displayed(), "The same channel name in another source must not inherit its frame")
        card.updatePreview(key: "sourceB/channelA", entry: entry)
        card.bind(channel: .init(groupName: "Fixture", name: "B", streams: []), favorite: false, urls: [], pixels: 512, repository: nil)
        XCTAssertFalse(displayed(), "A reused card must not show another channel's frame")
        card.updatePreview(key: "sourceB/channelB", entry: entry)
        card.clearPreview()
        XCTAssertFalse(displayed(), "Logo-only mode must explicitly clear the frame")
    }
    func testRapidViewportChangesSurviveDeterministicEvictionAndReleaseOffscreenPins() async throws {
        let store = cache(), data = try jpeg(), owner = UUID()
        let memory = NSCache<NSString, LivePreviewCoordinator.ImageEntry>()
        let requests = (0..<96).map { i -> LivePreviewDemand in
            var value = demand("scroll-\(i)"); value.priority = 2; return value
        }
        for request in requests { await store.store(.init(data: data, captured: Date().addingTimeInterval(-3600), sourceKey: "fixture"), key: request.key) }
        let service = LivePreviewCoordinator(cache: store, memory: memory) { _ in XCTFail("Scrolling cached channels must not open streams"); return data }
        defer { service.clear(owner: owner) }
        service.update(owner: owner, demands: requests, mayCapture: { true })
        try await settle(0.3)
        for step in 0..<60 {
            let count = [3, 8, 21, 41, 6][step % 5], first = (step * 13) % (96 - count)
            let visible = Set(requests[first..<(first + count)].map(\.key))
            service.updateViewport(owner: owner, visible: visible, nearby: [])
            for _ in 0..<40 {
                if visible.allSatisfy({ service.image(for: $0, programmeStart: nil) != nil }) { break }
                try await settle(0.005)
            }
            memory.removeAllObjects()
            XCTAssertTrue(visible.allSatisfy { service.image(for: $0, programmeStart: nil) != nil }, "Visible frames disappeared at viewport \(step), count \(count)")
        }
        let key = requests[0].key
        service.updateViewport(owner: owner, visible: [key], nearby: [])
        try await settle(0.1)
        weak var released = service.image(for: key, programmeStart: nil)
        XCTAssertNotNil(released)
        service.updateViewport(owner: owner, visible: [], nearby: [])
        memory.removeAllObjects()
        XCTAssertNil(released, "Leaving the viewport must release its pinned bitmap")
        service.updateViewport(owner: owner, visible: [key], nearby: [])
        try await settle(0.1)
        XCTAssertNotNil(service.image(for: key, programmeStart: nil))
        service.invalidate(sourceKey: "fixture")
        XCTAssertNil(service.image(for: key, programmeStart: nil))
    }
    func testInactiveSurfaceLoadsLocalPicturesWithoutCaptureOrPlayerScreenshot() async throws {
        let store = cache(), data = try jpeg(), owner = UUID()
        let cached = demand("inactive-cached")
        var playing = demand("inactive-playing")
        var reused = 0, captured = 0
        playing.mayReuseFrame = { true }; playing.currentFrame = { reused += 1; return data }
        await store.store(.init(data: data, captured: Date().addingTimeInterval(-3600), sourceKey: "fixture"), key: cached.key)
        let service = LivePreviewCoordinator(cache: store) { _ in captured += 1; return data }
        defer { service.clear(owner: owner) }
        let requests = [cached, playing, demand("inactive-missing")]
        service.update(owner: owner, demands: requests, mayCapture: { true }, isActive: false)
        try await settle()
        XCTAssertNotNil(service.image(for: cached.key, programmeStart: nil))
        XCTAssertEqual(captured, 0); XCTAssertEqual(reused, 0)
        service.update(owner: owner, demands: requests, mayCapture: { false }, isActive: true)
        try await settle(0.2)
        XCTAssertEqual(captured, 0); XCTAssertEqual(reused, 1)
    }
    func testViewportUsesActualClipAcrossResizingAndRapidScrolling() async throws {
        let state = AppState(environment: nil)
        let session = LiveBrowserSession(preferences: LiveBrowserPreferenceStore(storageKey: "test.viewport." + UUID().uuidString))
        let owner = UUID(); session.activate(owner: owner)
        defer { session.deactivate(owner: owner) }
        let channels = (0..<1000).map { LiveChannel(groupName: "Fixture", name: "Channel \($0)", streams: []) }
        let host = NSHostingView(rootView: NativeLiveChannelPage(channels: channels, source: .xtream(UUID()), sourceName: "Fixture", catalog: nil, session: session, browseKey: "viewport-fixture").environmentObject(state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(0.2)
        let scroll = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? LiveChannelScrollView }.first)
        var counts = Set<Int>(), samples = 0
        for size in [NSSize(width: 620, height: 380), NSSize(width: 1100, height: 720), NSSize(width: 1550, height: 1000), NSSize(width: 820, height: 1200)] {
            window.setContentSize(size); host.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
            try await settle(0.03)
            for y in [0.0, 800.0, 6000.0, 1800.0, 13000.0, 400.0, 9200.0, 0.0] {
                scroll.contentView.scroll(to: .init(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(0.015)
                let viewport = scroll.collection.convert(scroll.contentView.bounds, from: scroll.contentView)
                let layout = try XCTUnwrap(scroll.collection.collectionViewLayout)
                let expected = (0..<channels.count).compactMap { index -> IndexPath? in
                    let path = IndexPath(item: index, section: 0)
                    guard let attributes = layout.layoutAttributesForItem(at: path), attributes.frame.intersects(viewport) else { return nil }
                    return path
                }
                XCTAssertEqual(scroll.viewportIndexPaths, expected, "Viewport differs after resize/scroll at \(size), \(y)")
                XCTAssertFalse(expected.isEmpty)
                counts.insert(expected.count); samples += 1
            }
        }
        XCTAssertEqual(samples, 32); XCTAssertGreaterThan(counts.count, 3)
    }
    func testDigestSeparatesSourcesAndUnambiguouslyEncodesParts() {
        XCTAssertNotEqual(LivePreviewPolicy.digest(["sourceA", "CCTV1"]), LivePreviewPolicy.digest(["sourceB", "CCTV1"]))
        XCTAssertNotEqual(LivePreviewPolicy.digest(["ab", "c"]), LivePreviewPolicy.digest(["a", "bc"]))
        XCTAssertNotEqual(LivePreviewPolicy.digest(["channel", "token1"]), LivePreviewPolicy.digest(["channel", "token2"]))
    }
    func testOldAndPreviousProgrammeImagesRemainDisplayable() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(LivePreviewPolicy.accepts(captured: now.addingTimeInterval(-30), now: now, programmeStart: now.addingTimeInterval(-60)))
        XCTAssertTrue(LivePreviewPolicy.accepts(captured: now.addingTimeInterval(-300), now: now, programmeStart: nil))
        XCTAssertFalse(LivePreviewPolicy.accepts(captured: now.addingTimeInterval(1), now: now, programmeStart: nil))
        XCTAssertTrue(LivePreviewPolicy.accepts(captured: now.addingTimeInterval(-30), now: now, programmeStart: now.addingTimeInterval(-10)))
    }
    func testCacheIsBoundedAndSourceRemovalIsScoped() async throws {
        let store = cache(), data = try jpeg()
        let a = LivePreviewPolicy.digest(["a"]), b = LivePreviewPolicy.digest(["b"])
        await store.store(.init(data: data, captured: Date(), sourceKey: "A"), key: a)
        await store.store(.init(data: data, captured: Date(), sourceKey: "B"), key: b)
        await store.remove(sourceKey: "A")
        let missing = await store.read(a), present = await store.read(b)
        XCTAssertNil(missing); XCTAssertEqual(present?.data, data)
        let tiny = LivePreviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), limit: 1)
        await tiny.store(.init(data: data, captured: Date(), sourceKey: "A"), key: a)
        let evicted = await tiny.read(a); XCTAssertNil(evicted)
        let traversal = await store.read("../outside"); XCTAssertNil(traversal)
    }
    func testQueueUsesOneDecoderAndReusesFreshCache() async throws {
        let data = try jpeg(), store = cache()
        var active = 0, peak = 0, calls = 0
        let service = LivePreviewCoordinator(cache: store) { _ in
            active += 1; peak = max(peak, active); calls += 1
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 30_000_000)
            return data
        }
        let owner = UUID(), demands = (0..<4).map { demand(String($0)) }
        service.update(owner: owner, demands: demands, mayCapture: { true })
        try await settle(1.6)
        XCTAssertEqual(calls, 4); XCTAssertEqual(peak, 1)
        for request in demands { XCTAssertNotNil(service.image(for: request.key, programmeStart: nil)) }
        service.clear(owner: owner)
        let reopened = LivePreviewCoordinator(cache: store) { _ in XCTFail("Fresh cache must avoid another connection"); return data }
        reopened.update(owner: owner, demands: demands, mayCapture: { true })
        try await settle()
        for request in demands { XCTAssertNotNil(reopened.image(for: request.key, programmeStart: nil)) }
        reopened.clear(owner: owner)
    }
    func testChangingSourceCancelsAndRejectsLateOldResults() async throws {
        let data = try jpeg(); var valid = true
        let old = demand("old", valid: { valid }), new = demand("new")
        var calls: [String] = []
        let service = LivePreviewCoordinator(cache: cache()) { input in
            calls.append(input.url)
            if input.url.hasSuffix("old") { try? await Task.sleep(nanoseconds: 800_000_000) }
            return data
        }
        let owner = UUID()
        service.update(owner: owner, demands: [old], mayCapture: { true })
        try await settle(1.1)
        valid = false
        service.update(owner: owner, demands: [new], mayCapture: { true })
        try await settle(1.2)
        XCTAssertNil(service.image(for: old.key, programmeStart: nil))
        XCTAssertNotNil(service.image(for: new.key, programmeStart: nil))
        XCTAssertEqual(calls.count, 2)
        service.clear(owner: owner)
    }
    func testPlaybackAdmissionStopsWorkWithoutRetryOrHistoryEffects() async throws {
        var allowed = true, cancelled = false, calls = 0
        let service = LivePreviewCoordinator(cache: cache()) { _ in
            calls += 1
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = true; throw error }
            return Data()
        }
        let owner = UUID()
        service.update(owner: owner, demands: [demand("A")], mayCapture: { allowed })
        try await settle(1.1)
        allowed = false; service.interrupt()
        try await settle(0.1)
        XCTAssertTrue(cancelled); XCTAssertEqual(calls, 1)
        try await settle(1.1); XCTAssertEqual(calls, 1)
        service.clear(owner: owner)
    }
    func testFiniteRetryDoesNotSpinAndOwnerIsolation() async throws {
        var calls = 0
        let service = LivePreviewCoordinator(cache: cache()) { _ in calls += 1; throw CocoaError(.fileReadUnknown) }
        let owner = UUID()
        service.update(owner: owner, demands: [demand("A")], mayCapture: { true })
        service.clear(owner: UUID())
        try await settle(2.3)
        XCTAssertEqual(calls, 2)
        service.clear(owner: owner)
    }
    func testCardKeepsActionsAndFallbackWhenPreviewChanges() throws {
        let card = LiveChannelNativeCard()
        card.frame = NSRect(x: 0, y: 0, width: 320, height: LiveChannelCardMetrics.height(width: 320))
        let channel = LiveChannel(groupName: "Test", name: "CCTV1", streams: [])
        card.bind(channel: channel, favorite: false, urls: [], pixels: 640, repository: nil)
        var pressed = 0; card.activate = { pressed += 1 }
        card.showPreview(.init(image: try XCTUnwrap(NSImage(data: jpeg())), captured: Date()))
        XCTAssertTrue(card.accessibilityPerformPress())
        card.showPreview(nil)
        XCTAssertTrue(card.accessibilityPerformPress()); XCTAssertEqual(pressed, 2)
        XCTAssertEqual(card.accessibilityLabel(), "CCTV1")
    }
    func testCurrentPlayerFrameIsReusedWithoutOpeningStream() async throws {
        let data = try jpeg(); var reused = 0
        var request = demand("playing")
        request.mayReuseFrame = { true }
        request.currentFrame = { reused += 1; return data }
        let service = LivePreviewCoordinator(cache: cache()) { _ in XCTFail("Must not open another stream"); return data }
        let owner = UUID()
        service.update(owner: owner, demands: [request], mayCapture: { false })
        try await settle()
        XCTAssertEqual(reused, 1)
        XCTAssertNotNil(service.image(for: request.key, programmeStart: nil))
        service.clear(owner: owner)
    }
    func testResolverPreservesHeadersAndHasNoPlaybackSideEffects() async throws {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Preview fixture", sourceKind: .pasted, rawData: Data())
        let streams = [LiveStream(name: "A", url: URL(string: "https://example.invalid/a")!, headers: ["Referer": "https://example.invalid/" , "Authorization": "fixture-only"]),
                       LiveStream(name: "B", url: URL(string: "https://example.invalid/b")!)]
        let channel = LiveChannel(groupName: "G", name: "A", streams: streams)
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "G", channels: [channel])]))
        let request = try XCTUnwrap(state.livePreviewDemand(source: .imported(source.id), channel: channel,
            streams: [streams[1], streams[0]], programmeStart: nil))
        let inputs = try await request.resolve()
        XCTAssertEqual(inputs.map(\.url), streams.reversed().map { $0.url!.absoluteString })
        XCTAssertEqual(inputs.last?.headers, streams[0].headers)
        XCTAssertFalse(state.isPlayerPresented); XCTAssertNil(state.livePlaybackSourceID)
        let foreign = LiveChannel(groupName: "G", name: "other", streams: streams)
        XCTAssertNil(state.livePreviewDemand(source: .imported(source.id), channel: foreign, streams: streams, programmeStart: nil))
        XCTAssertFalse(request.mayReuseFrame())
        state.isPlayerPresented = true
        do { _ = try await request.resolve(); XCTFail("Player must take priority") } catch {}
        state.isPlayerPresented = false
    }
    func testViewportCancellationCannotResetCurrentFrameBudget() async throws {
        let data = try jpeg(); var attempts = 0
        let started = expectation(description: "current-frame screenshot began")
        var active = demand("active-rate-limit")
        active.mayReuseFrame = { true }
        active.currentFrame = {
            attempts += 1
            if attempts == 1 { started.fulfill() }
            // A native screenshot can finish after Swift task cancellation.
            try? await Task.sleep(nanoseconds: 800_000_000)
            return data
        }
        let service = LivePreviewCoordinator(cache: cache()) { _ in
            XCTFail("Active playback must not open another stream"); return data
        }
        let owner = UUID()
        service.update(owner: owner, demands: [active], mayCapture: { false })
        await fulfillment(of: [started], timeout: 3)
        service.update(owner: owner, demands: [active, demand("new-viewport")], mayCapture: { false })
        try await settle(2.2)
        XCTAssertEqual(attempts, 1, "Cancelled frames still consume the screenshot budget")
        service.clear(owner: owner)
    }
    func testPlaybackWaitsForPreviewToExitBeforeLoadingMedia() async throws {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Priority fixture", sourceKind: .pasted, rawData: Data())
        let stream = LiveStream(name: "A", url: URL(string: "https://example.invalid/live")!)
        let channel = LiveChannel(groupName: "G", name: "A", streams: [stream])
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "G", channels: [channel])]))
        let request = try XCTUnwrap(state.livePreviewDemand(source: .imported(source.id), channel: channel, streams: [stream], programmeStart: nil))
        let began = expectation(description: "preview decoder started")
        var active = false, loads = 0
        let data = try jpeg()
        state.livePreviews.capture = { _ in
            active = true; began.fulfill()
            defer { active = false }
            // Simulate a native decoder that requires cleanup after cancellation.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return data
        }
        let owner = UUID()
        state.livePreviews.update(owner: owner, demands: [request], mayCapture: { state.permitsBackgroundLivePreview })
        await fulfillment(of: [began], timeout: 3)
        state.importedRouteLoadForTesting = { _, _, _ in
            XCTAssertFalse(active, "Playback may load only after the preview releases its connection")
            loads += 1
        }
        let catalog = try XCTUnwrap(state.acceptedImportedCatalogs[source.id])
        await state.playImportedLive(try XCTUnwrap(catalog.selections(for: channel).first), navigationChannels: [channel])
        XCTAssertEqual(loads, 1)
        state.livePreviews.clear(owner: owner)
        await state.closePlayer()
    }
    func testRestartLoadsOldPictureBeforeNetworkAndAcrossProgrammeBoundary() async throws {
        let store = cache(), request = demand("old-cache"), data = try jpeg()
        let yesterday = Date().addingTimeInterval(-86400)
        await store.store(.init(data: data, captured: yesterday, sourceKey: "fixture"), key: request.key)
        let service = LivePreviewCoordinator(cache: store) { _ in XCTFail("Old cache is displayable without a new connection"); return data }
        let owner = UUID()
        service.update(owner: owner, demands: [request], mayCapture: { true })
        try await settle()
        XCTAssertEqual(service.image(for: request.key, programmeStart: Date())?.captured, yesterday)
        service.clear(owner: owner)
    }
    func testFailedManualRefreshKeepsOldImageAndRepeatedClicksCoalesce() async throws {
        let store = cache(), request = demand("last-good"), data = try jpeg()
        let captured = Date().addingTimeInterval(-3600)
        await store.store(.init(data: data, captured: captured, sourceKey: "fixture"), key: request.key)
        var calls = 0
        let service = LivePreviewCoordinator(cache: store) { _ in
            calls += 1; try await Task.sleep(nanoseconds: 150_000_000)
            throw LivePreviewCaptureError.deadline
        }
        let owner = UUID()
        service.update(owner: owner, demands: [request], mayCapture: { true })
        try await settle(0.3)
        service.requestRefresh(); service.requestRefresh(); service.requestRefresh()
        try await settle(1.5)
        XCTAssertEqual(calls, 2); XCTAssertFalse(service.refreshing)
        XCTAssertEqual(service.image(for: request.key, programmeStart: nil)?.captured, captured)
        let persisted = await store.read(request.key)
        XCTAssertEqual(persisted?.captured, captured)
        service.clear(owner: owner)
    }
    func testIdlePageDoesNotRecaptureAfterNinetySecondsOrFiveMinutes() async throws {
        var offset = 0.0, calls = 0
        let data = try jpeg(), owner = UUID(), request = demand("no-loop")
        let service = LivePreviewCoordinator(cache: cache(), clock: { Date().addingTimeInterval(offset) }) { _ in calls += 1; return data }
        service.update(owner: owner, demands: [request], mayCapture: { true })
        try await settle()
        for elapsed in [91.0, 301.0, 1800.0] {
            offset = elapsed
            service.update(owner: owner, demands: [request], mayCapture: { true })
            try await settle(0.1)
            XCTAssertNotNil(service.image(for: request.key, programmeStart: nil))
        }
        XCTAssertEqual(calls, 1)
        service.clear(owner: owner)
    }
    func testOptionalAutomaticRoundOnlyUpdatesStaleVisiblePictures() async throws {
        var offset = 0.0, calls: [String] = []
        let store = cache(), data = try jpeg(), owner = UUID()
        let visible = demand("visible-auto")
        var offscreen = demand("offscreen-auto"); offscreen.priority = 2
        for request in [visible, offscreen] { await store.store(.init(data: data, captured: Date(), sourceKey: "fixture"), key: request.key) }
        let service = LivePreviewCoordinator(cache: store, clock: { Date().addingTimeInterval(offset) }) { input in calls.append(input.url); return data }
        service.update(owner: owner, demands: [visible, offscreen], mayCapture: { true }, autoRefresh: true)
        try await settle()
        XCTAssertTrue(calls.isEmpty)
        offset = 601
        service.update(owner: owner, demands: [visible, offscreen], mayCapture: { true }, autoRefresh: true)
        try await settle(0.3)
        XCTAssertEqual(calls, ["https://example.invalid/visible-auto"])
        service.clear(owner: owner)
    }
    func testScrollingReprioritizesWithoutDiscardingInFlightPicture() async throws {
        let data = try jpeg(), owner = UUID(), began = expectation(description: "first capture")
        var calls: [String] = []
        let service = LivePreviewCoordinator(cache: cache()) { input in
            calls.append(input.url)
            if calls.count == 1 { began.fulfill(); try await Task.sleep(nanoseconds: 350_000_000) }
            return data
        }
        let a = demand("A"), b = demand("B"), c = demand("C")
        service.update(owner: owner, demands: [a,b,c], mayCapture: { true })
        await fulfillment(of: [began], timeout: 3)
        var offscreenA = a; offscreenA.priority = 2
        service.update(owner: owner, demands: [c,b,offscreenA], mayCapture: { true })
        try await settle(0.7)
        XCTAssertEqual(calls.map { URL(string: $0)!.lastPathComponent }, ["A","C","B"])
        service.update(owner: owner, demands: [a,b,c], mayCapture: { true })
        try await settle(0.2)
        XCTAssertNotNil(service.image(for: a.key, programmeStart: nil))
        XCTAssertEqual(calls.count, 3)
        service.clear(owner: owner)
    }
    func testVisibleMissingPicturesPrecedeStaleAndOffscreenPictures() async throws {
        let store = cache(), data = try jpeg(), owner = UUID()
        let old = demand("old"), missing = demand("missing")
        var background = demand("background"); background.priority = 2
        await store.store(.init(data: data, captured: Date().addingTimeInterval(-3600), sourceKey: "fixture"), key: old.key)
        var calls: [String] = []
        let service = LivePreviewCoordinator(cache: store) { input in calls.append(URL(string: input.url)!.lastPathComponent); return data }
        service.update(owner: owner, demands: [old,missing,background], mayCapture: { false })
        try await settle(0.2)
        service.requestRefresh()
        service.update(owner: owner, demands: [old,missing,background], mayCapture: { true })
        try await settle()
        XCTAssertEqual(calls, ["missing","old","background"])
        service.clear(owner: owner)
    }
    func testSlowRetryGetsIndependentBudgetAndAlternateAfterVisibleFirstPass() async throws {
        let data = try jpeg(), owner = UUID()
        var slow = demand("slow")
        slow = LivePreviewDemand(key: slow.key, sourceKey: slow.sourceKey, channelID: slow.channelID, programmeStart: nil,
            resolve: { [.init(url: "https://example.invalid/slow", headers: [:]), .init(url: "https://example.invalid/alternate", headers: [:])] }, isValid: { true })
        let fast = demand("fast")
        var background = demand("background"); background.priority = 2
        var calls: [String] = [], budgets: [Double] = []
        let service = LivePreviewCoordinator(cache: cache()) { input in
            calls.append(URL(string: input.url)!.lastPathComponent); budgets.append(input.timeoutSeconds ?? 0)
            if input.url.hasSuffix("slow") { throw LivePreviewCaptureError.deadline }
            return data
        }
        service.update(owner: owner, demands: [slow,fast,background], mayCapture: { true })
        try await settle()
        XCTAssertEqual(calls, ["slow","fast","alternate","background"])
        XCTAssertEqual(budgets, [12,12,25,12])
        XCTAssertNotNil(service.image(for: slow.key, programmeStart: nil))
        service.clear(owner: owner)
    }
    func testCacheSurvivesAgeAndEvictsLeastRecentlyUsedEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = LivePreviewBytes(data: try jpeg(), captured: Date().addingTimeInterval(-86400), sourceKey: "fixture")
        let size = try JSONEncoder().encode(entry).count
        let store = LivePreviewCache(directory: directory, limit: size * 2 + 8)
        let a = LivePreviewPolicy.digest(["a"]), b = LivePreviewPolicy.digest(["b"]), c = LivePreviewPolicy.digest(["c"])
        await store.store(entry, key: a); await store.store(entry, key: b)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: directory.appendingPathComponent(b + ".json").path)
        _ = await store.read(a)
        await store.store(entry, key: c)
        let kept = await store.read(a), removed = await store.read(b), newest = await store.read(c)
        XCTAssertNotNil(kept); XCTAssertNil(removed); XCTAssertNotNil(newest)
    }
    func testCacheIdentitySurvivesSourceReloadProgrammeAndSignedURLRotation() throws {
        let state = AppState(environment: nil)
        var source = StoredLiveSource(name: "Stable", sourceKind: .pasted, rawData: Data())
        let stream = LiveStream(name: "A", url: URL(string: "https://example.invalid/live?token=old")!)
        let first = LiveChannel(groupName: "G", name: "A", streams: [stream])
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "G", channels: [first])]))
        let a = try XCTUnwrap(state.livePreviewDemand(source: .imported(source.id), channel: first, streams: [stream], programmeStart: nil))
        source.updatedAt = Date().addingTimeInterval(100)
        let nextStream = LiveStream(name: "A", url: URL(string: "https://example.invalid/live?token=new")!)
        let next = LiveChannel(groupName: "G", name: "A", streams: [nextStream])
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "G", channels: [next])]))
        let b = try XCTUnwrap(state.livePreviewDemand(source: .imported(source.id), channel: next, streams: [nextStream], programmeStart: Date()))
        XCTAssertEqual(a.key, b.key); XCTAssertFalse(a.isValid()); XCTAssertTrue(b.isValid())
    }
    func testLegacyCacheMigratesWithoutNewCapture() async throws {
        let store = cache(), data = try jpeg(), owner = UUID()
        var request = demand("stable"); request.legacyKey = LivePreviewPolicy.digest(["legacy"])
        await store.store(.init(data: data, captured: Date().addingTimeInterval(-3600), sourceKey: "fixture"), key: request.legacyKey!)
        let service = LivePreviewCoordinator(cache: store) { _ in XCTFail("Migration should preserve the previous picture"); return data }
        service.update(owner: owner, demands: [request], mayCapture: { true })
        try await settle()
        XCTAssertNotNil(service.image(for: request.key, programmeStart: nil))
        let saved = await store.read(request.key); XCTAssertNotNil(saved)
        service.clear(owner: owner)
    }

    func testRealHelperCapturesFrameAndCancellationReapsIt() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OKVideoLivePreview")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Native/DASHSmoke/fixtures/legacy.mp4")
        let image = try await LivePreviewProcessJob().run(.init(url: file.absoluteString, headers: [:]), executable: helper)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: image))
        XCTAssertEqual(decoded.pixelsWide, 640); XCTAssertEqual(decoded.pixelsHigh, 360)
        let blocked = Task { try await LivePreviewProcessJob().run(.init(url: "udp://127.0.0.1:19839", headers: [:]), executable: helper) }
        try await settle(0.2)
        let started = Date(); blocked.cancel()
        do { _ = try await blocked.value; XCTFail("Cancellation must discard output") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}


@MainActor final class LivePreviewAcceptanceTests: XCTestCase {
    func testHelperPreservesTopAndBottomOrientation() async throws {
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<180 { for x in 0..<320 {
            let offset = y * stride + x * 4
            pointer[offset] = y < 90 ? 0 : 255; pointer[offset + 1] = 0
            pointer[offset + 2] = y < 90 ? 255 : 0; pointer[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OKVideoLivePreview")
        let data = try await LivePreviewProcessJob().run(.init(url: movie.absoluteString, headers: [:]), executable: helper)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        let top = try XCTUnwrap(image.colorAt(x: 320, y: 20)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(image.colorAt(x: 320, y: 340)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.8); XCTAssertLessThan(top.blueComponent, 0.2)
        XCTAssertGreaterThan(bottom.blueComponent, 0.8); XCTAssertLessThan(bottom.redComponent, 0.2)
    }

    func testRealChannelPreviewRound() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["OKVIDEO_PREVIEW_PLAYLIST"], let output = env["OKVIDEO_PREVIEW_REPORT"] else {
            throw XCTSkip("Explicit local playlist fixture required")
        }
        let playlist = try LiveSourceParser().parse(String(contentsOfFile: file, encoding: .utf8))
        let requested = ["CCTV-1", "CCTV-2", "CCTV-3", "CCTV-4", "CCTV-10", "CCTV-11", "CCTV-13", "CCTV-14"]
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OKVideoLivePreview")
        var report: [[String: Any]] = []
        for name in requested {
            let channel = try XCTUnwrap(playlist.groups.flatMap(\.channels).first(where: { $0.name == name }))
            let streams = Array(channel.streams.prefix(2))
            var success = false, trials: [[String: Any]] = []
            for attempt in 0..<2 {
                let stream = streams[min(attempt, streams.count - 1)]
                var input = LivePreviewInput(url: try XCTUnwrap(stream.url).absoluteString, headers: stream.headers)
                input.timeoutSeconds = attempt == 0 ? 12 : 25
                let started = Date()
                do {
                    let data = try await LivePreviewProcessJob().run(input, executable: helper, timeout: input.timeoutSeconds! + 1)
                    let image = try XCTUnwrap(NSBitmapImageRep(data: data))
                    XCTAssertEqual(image.pixelsWide, 640); XCTAssertEqual(image.pixelsHigh, 360)
                    trials.append(["seconds":Date().timeIntervalSince(started), "outcome":"success", "bytes":data.count])
                    try data.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + ".jpg"))
                    success = true; break
                } catch {
                    trials.append(["seconds":Date().timeIntervalSince(started), "outcome":(error as? LivePreviewCaptureError)?.category ?? "decode"])
                }
            }
            report.append(["channel":name, "passed":success, "attempts":trials])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        XCTAssertEqual(report.filter { $0["passed"] as? Bool == true }.count, requested.count,
            "Inspect the redacted per-channel report for any capture failure")
    }

    func testThirtyMinuteLivePlaybackWithPreviewDemandChurn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["OKVIDEO_LIVE_PREVIEW_SOAK_INPUT"], let output = env["OKVIDEO_LIVE_PREVIEW_SOAK_OUTPUT"] else {
            throw XCTSkip("Explicit live-source soak requires a private input and output path")
        }
        let raw = try JSONDecoder().decode(LivePreviewInput.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        // Private fixtures come from raw playlist text, not a parsed media URL.
        // Use the production parser so malformed percent escapes and valid
        // signed query bytes receive exactly the same treatment as real playback.
        let playlist = try LiveSourceParser().parse("#EXTM3U\n#EXTINF:-1,Private fixture\n" + raw.url + "\n")
        let stream = try XCTUnwrap(playlist.groups.first?.channels.first?.streams.first)
        let request = LivePreviewInput(url: try XCTUnwrap(stream.url).absoluteString,
            headers: raw.headers.merging(stream.headers) { _, parsed in parsed })
        let seconds = Double(env["OKVIDEO_LIVE_PREVIEW_SOAK_SECONDS"] ?? "1800") ?? 1800
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) }, onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        window.contentView = surface; surface.frame = NSRect(x: 0, y: 0, width: 640, height: 360); surface.prepareOpenGL()
        var latest = PlayerSnapshot(), failures = 0, unexpectedEnds = 0
        let reader = Task { @MainActor in
            for await event in player.events {
                if case .snapshot(let snapshot, _) = event { latest = snapshot; if case .failed = snapshot.status { failures += 1 } }
                if case .ended = event { unexpectedEnds += 1 }
            }
        }
        let renderer = Task { @MainActor in
            while !Task.isCancelled {
                autoreleasepool { surface.draw(surface.bounds) }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewSoak-" + UUID().uuidString)
        let previews = LivePreviewCoordinator(cache: LivePreviewCache(directory: cacheURL))
        var backgroundConnections = 0, reusedFrames = 0
        previews.capture = { _ in backgroundConnections += 1; throw CocoaError(.fileReadUnknown) }
        let owner = UUID(), started = Date()
        var samples: [[String: Any]] = [], lastPosition = 0.0, lastProgress = Date(), maximumStall = 0.0, changes = 0
        do {
            try await player.load(ResolvedMedia(url: try XCTUnwrap(URL(string: request.url)), headers: HTTPHeaders(request.headers),
                format: nil, siteKey: "live", sourceName: "Private live fixture", episodeName: "Soak"), startPosition: nil, requestID: UUID())
            while Date().timeIntervalSince(started) < seconds {
                let demands = (0..<16).map { index in
                    LivePreviewDemand(key: LivePreviewPolicy.digest(["soak", String(changes), String(index)]),
                        sourceKey: "soak", channelID: String(index), programmeStart: nil,
                        resolve: { [request] }, isValid: { true })
                }
                var active = LivePreviewDemand(key: LivePreviewPolicy.digest(["active"]), sourceKey: "soak", channelID: "active",
                    programmeStart: nil, resolve: { [] }, isValid: { true })
                active.mayReuseFrame = { latest.status == .playing && !latest.isPausedForCache }
                active.currentFrame = {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("SoakFrame-" + UUID().uuidString + ".png")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try await player.screenshot(to: file)
                    reusedFrames += 1
                    return LivePreviewImageCodec.thumbnail(from: try Data(contentsOf: file))
                }
                previews.update(owner: owner, demands: [active] + demands, mayCapture: { false })
                changes += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if latest.position > lastPosition + 0.1 { lastPosition = latest.position; lastProgress = Date() }
                maximumStall = max(maximumStall, Date().timeIntervalSince(lastProgress))
                if changes % 30 == 0 {
                    let sample: [String: Any] = ["seconds": Date().timeIntervalSince(started), "position": latest.position,
                        "width": latest.videoWidth, "backgroundConnections": backgroundConnections, "failures": failures,
                        "maximumStallSeconds": maximumStall]
                    samples.append(sample)
                    try JSONSerialization.data(withJSONObject: ["status":"running", "samples": samples], options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: output), options: .atomic)
                }
                if failures > 0 || unexpectedEnds > 0 || maximumStall > 30 { break }
            }
            XCTAssertGreaterThan(reusedFrames, 0)
            XCTAssertLessThanOrEqual(reusedFrames, Int(ceil(seconds / 30)) + 1,
                "Rapid viewport changes must not exceed the current-player screenshot budget")
            XCTAssertEqual(backgroundConnections, 0); XCTAssertEqual(failures, 0); XCTAssertEqual(unexpectedEnds, 0)
            XCTAssertLessThan(maximumStall, 30); XCTAssertGreaterThan(latest.videoWidth, 0)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), seconds)
            let success = reusedFrames > 0 && reusedFrames <= Int(ceil(seconds / 30)) + 1 && backgroundConnections == 0 && failures == 0 && unexpectedEnds == 0 && maximumStall < 30 && Date().timeIntervalSince(started) >= seconds
            try JSONSerialization.data(withJSONObject: ["status": success ? "passed" : "failed", "seconds": Date().timeIntervalSince(started),
                "failures": failures, "unexpectedEnds": unexpectedEnds, "backgroundConnections": backgroundConnections,
                "viewportChanges": changes, "reusedFrames": reusedFrames, "maximumStallSeconds": maximumStall, "samples": samples], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        } catch {
            previews.clear(owner: owner); renderer.cancel(); reader.cancel(); surface.tearDown(); window.close(); await player.shutdown(); throw error
        }
        previews.clear(owner: owner); renderer.cancel(); reader.cancel(); surface.tearDown(); window.close(); await player.shutdown()
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
