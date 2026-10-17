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

    func testPlayerChannelPickerKeepsPlayingCatalogAndRejectsStaleSource() async throws {
        let (state, catalog, channels, programme) = fixture()
        var urls: [URL] = []
        state.importedRouteLoadForTesting = { _, media, _ in urls.append(media.url) }
        await state.playImportedCatchup(catalog.selections(for: channels[0])[0], programme: programme, navigationChannels: channels)
        XCTAssertEqual(state.playerLiveChannels.map(\.id), channels.map(\.id))
        let source = try XCTUnwrap(state.livePlaybackSourceID)
        await state.selectPlayerLiveChannel(channels[1].id, source: .imported(UUID()))
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        await state.selectPlayerLiveChannel(channels[1].id, source: source)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(state.livePlaybackChannel?.id, channels[1].id)
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

    func testCatchupHeaderKeepsSingleLineWithinNarrowAndWideWindows() throws {
        let output = URL(fileURLWithPath: "/private/tmp/OKVideoMac-Catchup/HeaderRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [640, 1000] {
            let header = CatchupPlayerHeader(title: "Synthetic evening programme with a long title", channel: "Synthetic channel",
                start: Date(timeIntervalSince1970: 1704067200), returnToLive: {})
                .padding(.horizontal, 18).background(Color.black.opacity(0.8))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: header)
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            host.frame = NSRect(x: 0, y: 0, width: width, height: 36)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 36)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("header-\(width).png"))
        }
    }

}

@MainActor final class TVBoxGuideWiringTests: XCTestCase {
    func testInlineImportKeepsCatchupAndDailyEPGWhenReadAgain() throws {
        let live = LiveConfiguration(name: "Synthetic",
            epg: "https://guide.example.invalid/?id={id}&date={date}",
            catchup: .init(source: "?start=${(b)timestamp}"), timeZone: "Asia/Shanghai",
            groups: [.init(name: "Synthetic", channels: [.init(name: "One", urls: ["https://example.invalid/live.ts"], tvgID: "one")])])
        let data = try EmbeddedLiveSourcePolicy.inlineData(for: live)
        let channel = try XCTUnwrap(LiveSourceParser().parse(data).groups.first?.channels.first)
        XCTAssertNotNil(channel.streams[0].catchup)
        XCTAssertEqual(channel.epgAPI?.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(channel.epgAPI?.template, "https://guide.example.invalid/?id=one&date={date}")
        XCTAssertEqual(try LiveSourceDocument.defaults(in: data)?.catchup, live.catchup)
    }

    func testDailyGuideUsesPerRowTokensAndRejectsOldDelivery() throws {
        let source = EPGSourceKey(.imported(UUID())), service = UUID(), first = UUID(), second = UUID()
        let identity = LiveGuideDeliveryIdentity(source: source, revision: "fixture", demandRevision: first,
                                                serviceIncarnation: service, capability: .tvboxDay)
        let state = LiveGuideState()
        let channel = LiveChannel(groupName: "Synthetic", name: "One", streams: [])
        let start = Date(timeIntervalSince1970: 1704067200)
        let token = EPGResultToken(serviceIncarnation: service, resourceIdentity: "synthetic", sourceEpoch: "fixture",
                                  dataVersion: "day-1", demandRevision: first)
        let programme = EPGProgramme(channelID: channel.id, title: "Synthetic programme", start: start, end: start.addingTimeInterval(3600))
        let record = EPGWindowProgramme(id: .init(kind: .tvboxDay, resourceIdentity: token.resourceIdentity,
            sourceEpoch: token.sourceEpoch, dataVersion: token.dataVersion, ordinal: 0), programme: programme)
        let snapshot = try EPGGuideSnapshot(source: source, revision: identity.revision, demandRevision: first,
            slices: [.init(start: start, end: start.addingTimeInterval(12 * 3600))], coherence: .perRowToken,
            rows: [.init(channel: .init(channel), token: token, match: .init(kind: .exact, channelID: channel.id),
                         availability: .fresh, programmes: [record], state: .ready)])
        state.begin(identity, refreshing: true)
        XCTAssertTrue(state.publish(snapshot, identity: identity))
        let newer = LiveGuideDeliveryIdentity(source: source, revision: "fixture", demandRevision: second,
                                             serviceIncarnation: service, capability: .tvboxDay)
        state.begin(newer, refreshing: true)
        XCTAssertFalse(state.publish(snapshot, identity: identity))
    }
}

@MainActor final class NativeArchivePlaybackWiringTests: XCTestCase {
    private func fixture() async throws -> (AppState, LiveChannel, EPGProgramme, LiveSourceID) {
        let descriptor = try XtreamProviderConfiguration(providerID: UUID(), displayName: "Synthetic",
            serverBaseURL: URL(string: "https://native.example.invalid")!)
        let provider = try XtreamSiteProvider(configuration: descriptor,
            credentials: .init(username: "synthetic-user", password: "fixture"),
            httpClient: NativeArchiveMetadataClient(), userAgent: "Synthetic")
        let record = StoredConfiguration(id: descriptor.providerID, name: "Synthetic", sourceKind: .xtream,
            sourceValue: descriptor.serverBaseURL.absoluteString, baseURL: descriptor.serverBaseURL,
            rawData: try descriptor.encoded(), isActive: true)
        let state = AppState(environment: nil)
        state.setLiveConfigurationForTesting(record, providers: [provider.site.key: provider])
        let source = LiveSourceID.xtream(record.id)
        await state.loadLiveSource(source)
        let channel = try XCTUnwrap(state.liveCatalog(for: source)?.groups.first?.channels.first)
        let programme = EPGProgramme(channelID: channel.id, title: "Synthetic history",
            start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600), catchupAvailable: true)
        state.nativeLiveMediaForTesting = { reference, programme, offset, now, legacy in
            try Self.media(reference, programme: programme, offset: offset, now: now, legacy: legacy)
        }
        return (state, channel, programme, source)
    }

    private static func media(_ reference: PlaybackResourceReference, programme: EPGProgramme?,
                              offset: TimeInterval, now: Date, legacy: Bool) throws -> ResolvedMedia {
        let locator = try XCTUnwrap(reference.xtreamLiveLocator)
        let builder = XtreamURLBuilder(endpoint: try .init(serverURL: URL(string: "https://native.example.invalid")!))
        let credentials = XtreamCredentials(username: "synthetic", password: "fixture")
        if let programme {
            let request = try builder.archiveRequest(credentials: credentials, streamID: locator.streamID,
                outputFormat: locator.outputFormat.rawValue, programme: programme, offset: offset, now: now, serverTimeZoneID: "UTC")
            var media = ResolvedMedia(url: legacy ? request.legacyURL : request.url, headers: [:],
                siteKey: "live-catchup", sourceName: "Synthetic", episodeName: programme.title,
                compatibilityPolicy: .nativeXtreamLive)
            media.playbackDurationLimit = request.remainingDuration + request.leadIn
            media.playbackStartOffset = request.leadIn
            return media
        }
        return ResolvedMedia(url: try builder.playbackURL(kind: .live, remoteID: locator.streamID,
            containerExtension: locator.outputFormat.rawValue, credentials: credentials), headers: [:],
            siteKey: "xtream-live", sourceName: "Synthetic", episodeName: "TS", compatibilityPolicy: .nativeXtreamLive)
    }

    func testNativeArchiveSeekAndReturnRetainProgrammeAndClearFileBounds() async throws {
        let (state, channel, programme, source) = try await fixture()
        var loads: [ResolvedMedia] = []
        state.importedRouteLoadForTesting = { _, media, _ in loads.append(media) }
        await state.playNativeCatchup(channel: channel, stream: channel.streams[0], sourceID: source,
                                      programme: programme, navigationChannels: [channel])
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(loads[0].siteKey, "live-catchup")
        XCTAssertFalse(state.isLivePlayback)
        XCTAssertTrue(state.canSeekPlayback)
        let previous = state.importedRouteFlowForTesting
        await state.seek(to: 600)
        XCTAssertEqual(loads.count, 2)
        XCTAssertNotEqual(state.importedRouteFlowForTesting, previous)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        XCTAssertEqual((loads[1].playbackDurationLimit ?? 0) - (loads[1].playbackStartOffset ?? 0),
                       programme.end.timeIntervalSince(programme.start) - 600, accuracy: 0.001)
        await state.returnToLive()
        XCTAssertEqual(loads.count, 3)
        XCTAssertEqual(loads[2].siteKey, "xtream-live")
        XCTAssertNil(loads[2].playbackDurationLimit)
        XCTAssertNil(loads[2].playbackStartOffset)
        XCTAssertTrue(state.isLivePlayback)
        XCTAssertNil(state.liveCatchupProgramme)
        await state.closePlayer()
    }

    func testNativeArchiveFailureOnlyRetriesSameProgrammeViaLegacyEndpoint() async throws {
        let (state, channel, programme, source) = try await fixture()
        var loads: [ResolvedMedia] = []
        state.importedRouteLoadForTesting = { _, media, _ in
            loads.append(media)
            if media.url.path.contains("/timeshift/") { throw AppError.playback("HTTP 404") }
        }
        await state.playNativeCatchup(channel: channel, stream: channel.streams[0], sourceID: source,
                                      programme: programme, navigationChannels: [channel])
        XCTAssertEqual(loads.count, 2)
        XCTAssertTrue(loads[0].url.path.contains("/timeshift/"))
        XCTAssertEqual(loads[1].url.path, "/streaming/timeshift.php")
        XCTAssertTrue(loads.allSatisfy { $0.siteKey == "live-catchup" && $0.episodeName == programme.title })
        XCTAssertFalse(state.hasExhaustedLivePlayback)
        XCTAssertEqual(state.liveCatchupProgramme, programme)
        state.failImportedRouteForTesting()
        XCTAssertTrue(state.hasExhaustedLivePlayback)
        XCTAssertNil(state.importedRouteRecoveryTaskForTesting)
        XCTAssertEqual(loads.count, 2)
        await state.closePlayer()
    }

    func testForeignOrUnavailableProgrammesCannotStartNativePlayback() async throws {
        let (state, channel, original, source) = try await fixture()
        var loads = 0
        state.importedRouteLoadForTesting = { _, _, _ in loads += 1 }
        var foreign = original; foreign.channelID = "foreign"
        var denied = original; denied.catchupAvailable = false
        for programme in [foreign, denied] {
            await state.playNativeCatchup(channel: channel, stream: channel.streams[0], sourceID: source,
                                          programme: programme, navigationChannels: [channel])
        }
        XCTAssertEqual(loads, 0)
        XCTAssertNil(state.liveCatchupProgramme)
        await state.closePlayer()
    }

    func testLateNativeArchiveResolutionCannotOverwriteReturnToLive() async throws {
        let (state, channel, programme, source) = try await fixture()
        let started = expectation(description: "archive resolver started")
        var continuation: CheckedContinuation<Void, Error>?
        state.nativeLiveMediaForTesting = { reference, programme, offset, now, legacy in
            if programme != nil {
                started.fulfill()
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return try Self.media(reference, programme: programme, offset: offset, now: now, legacy: legacy)
        }
        var loads: [ResolvedMedia] = []
        state.importedRouteLoadForTesting = { _, media, _ in loads.append(media) }
        let old = Task { await state.playNativeCatchup(channel: channel, stream: channel.streams[0],
            sourceID: source, programme: programme, navigationChannels: [channel]) }
        await fulfillment(of: [started], timeout: 2)
        await state.returnToLive()
        let current = state.importedRouteFlowForTesting
        continuation?.resume(throwing: AppError.playback("late synthetic failure"))
        await old.value
        XCTAssertEqual(state.importedRouteFlowForTesting, current)
        XCTAssertTrue(state.isLivePlayback)
        XCTAssertEqual(loads.map(\.siteKey), ["xtream-live"])
        XCTAssertFalse(state.hasExhaustedLivePlayback)
        await state.closePlayer()
    }

    func testNativeFileOptionsKeepSubMinuteStartAndEndLocalToArchive() {
        var media = ResolvedMedia(url: URL(string: "https://example.invalid/archive.ts")!, headers: [:],
            siteKey: "live-catchup", sourceName: "Synthetic", episodeName: "Synthetic", compatibilityPolicy: .nativeXtreamLive)
        media.playbackStartOffset = 2.5; media.playbackDurationLimit = 5.5
        let archive = MPVTVBoxPlaybackPolicy.loadCommand(for: media)
        XCTAssertTrue(archive.last?.contains("start=2.500") == true)
        XCTAssertTrue(archive.last?.contains("end=5.500") == true)
        XCTAssertTrue(archive.last?.contains("tls-verify=yes") == true)
        media.playbackStartOffset = nil; media.playbackDurationLimit = nil
        let live = MPVTVBoxPlaybackPolicy.loadCommand(for: media)
        XCTAssertFalse(live.contains { $0.contains("start=") || $0.contains("end=") })
    }
}

private struct NativeArchiveMetadataClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let body: String
        switch action {
        case "get_live_categories": body = #"[{"category_id":"7","category_name":"Synthetic"}]"#
        case "get_live_streams": body = #"[{"stream_id":42,"name":"Synthetic","category_id":"7","tv_archive":1,"tv_archive_duration":7}]"#
        default: body = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts","m3u8"]},"server_info":{"timezone":"UTC"}}"#
        }
        return .init(url: request.url, statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

@MainActor final class ArchiveGuideMetadataProjectionTests: XCTestCase {
    func testProgrammeArchiveDenialSurvivesGridProjection() {
        let start = Date(timeIntervalSince1970: 1704067200)
        let record = EPGWindowProgramme(id: .init(kind: .xtream, resourceIdentity: "fixture",
            sourceEpoch: "fixture", dataVersion: "fixture", ordinal: 0),
            programme: .init(channelID: "fixture", title: "Synthetic", start: start,
                             end: start.addingTimeInterval(3600), catchupAvailable: false))
        XCTAssertEqual(LiveGuideGridProgramme(record).catchupAvailable, false)
    }
}
