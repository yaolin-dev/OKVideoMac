import XCTest
import AppKit
import SwiftUI
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class LiveCatchupWiringTests: XCTestCase {
    private func fixture() -> (AppState, AcceptedImportedCatalog, [LiveChannel], EPGProgramme) {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Synthetic", sourceKind: .pasted, rawData: Data())
        let archive = LiveCatchupConfiguration(mode: "append", template: "&start={utc}&end={utcend}", retentionDays: 7, seekPolicy: .request)
        let a = LiveChannel(groupName: "Fixture", name: "A", streams: [
            LiveStream(name: "archive", url: URL(string: "https://example.invalid/live?fixture=1")!, headers: ["User-Agent": "Synthetic"], catchup: archive),
            LiveStream(name: "live-only", url: URL(string: "https://example.invalid/only-live")!)])
        let b = LiveChannel(groupName: "Fixture", name: "B", streams: [LiveStream(name: "other", url: URL(string: "https://example.invalid/other")!, catchup: archive)])
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [.init(name: "Fixture", channels: [a, b])]))
        let programme = EPGProgramme(channelID: a.id, title: "Synthetic historical programme", start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600))
        return (state, state.acceptedImportedCatalogs[source.id]!, [a, b], programme)
    }

    func testHistoricalSelectionRequestsArchiveAndReturnUsesOriginalLiveRoute() async {
        let (state, catalog, channels, programme) = fixture()
        var media: [ResolvedMedia] = []; state.importedRouteLoadForTesting = { _, value, _ in media.append(value) }
        await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels)
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media[0].siteKey, "live-catchup")
        XCTAssertEqual(media[0].headers, HTTPHeaders(channels[0].streams[0].headers))
        XCTAssertTrue(media[0].url.absoluteString.contains("&start="))
        XCTAssertEqual(media[0].playbackDurationLimit ?? 0, programme.end.timeIntervalSince(programme.start), accuracy: 0.01)
        XCTAssertFalse(state.isLivePlayback)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        let previous = state.importedRouteFlowForTesting
        await state.returnToLive()
        XCTAssertNotEqual(state.importedRouteFlowForTesting, previous)
        XCTAssertEqual(media.count, 2)
        XCTAssertEqual(media[1].url, channels[0].streams[0].url)
        XCTAssertNil(media[1].playbackDurationLimit)
        XCTAssertNil(state.liveCatchupProgramme)
        XCTAssertTrue(state.isLivePlayback)
        await state.closePlayer()
    }

    func testArchiveFailureNeverFallsThroughToLiveOrAnotherChannel() async {
        let (state, catalog, channels, programme) = fixture()
        var urls: [URL] = []; state.importedRouteLoadForTesting = { _, media, _ in urls.append(media.url); throw AppError.playback("synthetic failure") }
        await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(state.hasExhaustedLivePlayback)
        XCTAssertEqual(state.livePlaybackChannel?.id, channels[0].id)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        state.failImportedRouteForTesting()
        XCTAssertNil(state.importedRouteRecoveryTaskForTesting)
        XCTAssertEqual(urls.count, 1)
        await state.closePlayer()
    }

    func testRequestSeekRebuildsIntervalAndRetiresOldOwner() async {
        let (state, catalog, channels, programme) = fixture()
        var media: [ResolvedMedia] = []; state.importedRouteLoadForTesting = { _, value, _ in media.append(value) }
        await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels)
        let old = state.importedRouteFlowForTesting
        await state.seek(to: 600)
        XCTAssertEqual(media.count, 2)
        XCTAssertNotEqual(state.importedRouteFlowForTesting, old)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        XCTAssertEqual(media[1].playbackDurationLimit ?? 0, programme.end.timeIntervalSince(programme.start) - 600, accuracy: 0.01)
        XCTAssertNotEqual(media[0].url, media[1].url)
        await state.seek(to: .nan)
        await state.seek(to: 999999)
        XCTAssertEqual(media.count, 2)
        await state.replayCurrentCatchup()
        XCTAssertEqual(media.count, 3)
        XCTAssertEqual(media[2].url, media[0].url)
        XCTAssertEqual(media[2].playbackDurationLimit, media[0].playbackDurationLimit)
        await state.closePlayer()
    }

    func testExpiredFutureAndForeignProgrammeCannotStartPlayback() async {
        let (state, catalog, channels, original) = fixture()
        var loads = 0; state.importedRouteLoadForTesting = { _, _, _ in loads += 1 }
        let selection = catalog.selections(for: channels[0])[0]
        for programme in [EPGProgramme(channelID: channels[0].id, title: "Expired", start: Date().addingTimeInterval(-8 * 86400), end: Date().addingTimeInterval(-8 * 86400 + 3600)), EPGProgramme(channelID: channels[0].id, title: "Future", start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(7200)), EPGProgramme(channelID: channels[1].id, title: "Foreign", start: original.start, end: original.end)] {
            await state.playImportedCatchup(selection, programme: programme, navigationChannels: channels)
        }
        XCTAssertEqual(loads, 0)
        XCTAssertNil(state.liveCatchupProgramme)
        await state.closePlayer()
    }

    func testLateFailedReplayLoadCannotOverwriteNewLiveFlow() async {
        let (state, catalog, channels, programme) = fixture()
        let started = expectation(description: "old replay load began")
        var continuation: CheckedContinuation<Void, Error>?
        state.importedRouteLoadForTesting = { _, media, _ in
            if media.siteKey == "live-catchup" {
                started.fulfill()
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        let oldTask = Task { await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels) }
        await fulfillment(of: [started], timeout: 2)
        await state.playImportedLive(catalog.selections(for: channels[1])[0], navigationChannels: channels)
        let current = state.importedRouteFlowForTesting
        continuation?.resume(throwing: AppError.playback("late fixture error"))
        await oldTask.value
        XCTAssertEqual(state.importedRouteFlowForTesting, current)
        XCTAssertEqual(state.livePlaybackChannel?.id, channels[1].id)
        XCTAssertNil(state.liveCatchupProgramme)
        XCTAssertFalse(state.hasExhaustedLivePlayback)
        await state.closePlayer()
    }

    func testFileLocalProgrammeStopOptionDoesNotLeakToLive() {
        var media = ResolvedMedia(url: URL(string: "https://example.invalid/archive.ts")!, headers: [:], siteKey: "live-catchup", sourceName: "Fixture", episodeName: "Fixture")
        media.playbackDurationLimit = 1800
        XCTAssertTrue(MPVTVBoxPlaybackPolicy.loadCommand(for: media).last?.contains("end=1800.000") == true)
        media.playbackDurationLimit = nil
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.loadCommand(for: media).contains(where: { $0.contains("end=") }))
    }
    func testNativeCardReplayActionAndReuseRespectCapability() throws {
        let card = LiveChannelNativeCard()
        var replayCalls = 0
        card.catchupAction = { replayCalls += 1 }
        let supported = LiveChannel(groupName: "Fixture", name: "Synthetic", streams: [
            LiveStream(name: "Fixture", url: URL(string: "https://example.invalid/PLTV/fixture/index.smil")!)])
        card.bind(channel: supported, favorite: false, urls: [], pixels: 256, repository: nil)
        let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "live.catchup.open"
        })
        XCTAssertFalse(button.isHidden)
        button.performClick(nil)
        XCTAssertEqual(replayCalls, 1)
        card.frame = NSRect(x: 0, y: 0, width: 190, height: 210)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(card.bounds.contains(button.frame))
        var disabled = supported
        disabled.streams[0].catchup = .init(mode: "none", template: "")
        card.bind(channel: disabled, favorite: false, urls: [], pixels: 256, repository: nil)
        XCTAssertTrue(button.isHidden, "A reused card must not retain another route's replay affordance")
    }

    func testHealthyReplayWithIdleResolutionDoesNotShowWaitingOrLoading() async throws {
        let (state, catalog, channels, programme) = fixture()
        state.importedRouteLoadForTesting = { _, _, _ in }
        await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels)
        state.playerSnapshotState.update(PlayerSnapshot(status: .playing, position: 30, duration: 3600))
        XCTAssertEqual(state.playbackResolutionState, .idle, "The live pipeline has no VOD resolution transition")
        let host = NSHostingView(rootView: PlayerView(playerSnapshotState: state.playerSnapshotState,
            onWindowChromeRestored: {}).environmentObject(state))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        // Publish the accessibility tree without covering or focusing the user's player.
        let edge = NSScreen.screens.map { $0.frame.maxX }.max() ?? 2000
        window.setFrameOrigin(NSPoint(x: edge + 500, y: 0))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func labels(_ value: Any, depth: Int = 0) -> [String] {
            guard depth < 40, let element = value as? NSAccessibilityProtocol else { return [] }
            let own = [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
            return own + (element.accessibilityChildren() ?? []).flatMap { labels($0, depth: depth + 1) }
        }
        let text = labels(window)
        XCTAssertTrue(text.contains(where: { $0.contains(programme.title) }), "The real PlayerView accessibility tree must be materialized")
        XCTAssertFalse(text.contains(L10n.string("common.loading", fallback: "Loading")))
        XCTAssertFalse(text.contains(where: { $0.contains("Waiting for media") || $0.contains("等待媒体数据") }))
        window.contentView = nil; window.close()
        await state.closePlayer()
    }

    func testCatchupHeaderRendersTwoLinesWithinNarrowAndWideWindows() throws {
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Catchup/HeaderRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [640, 1000] {
            let header = CatchupPlayerHeader(title: "Synthetic evening programme with a long title", channel: "Synthetic channel",
                start: Date(timeIntervalSince1970: 1704067200), returnToLive: {})
                .padding(.horizontal, 18).background(Color.black.opacity(0.8))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: header)
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            host.frame = NSRect(x: 0, y: 0, width: width, height: 48)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 60)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("header-\(width).png"))
        }
    }

}
