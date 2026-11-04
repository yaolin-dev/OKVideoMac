import AppKit
import CoreFoundation
import SwiftUI
import XCTest
import OKVideoCore
@testable import OKVideoMac

final class SubtitleLiveInfoTests: XCTestCase {
    @MainActor func testProgrammeInfoUsesControlVisibilityAndHoldsDuringInteraction() {
        let state = PlayerLiveInfoInteraction()
        func mayHide() -> Bool {
            PlayerControlVisibilityPolicy.shouldAutoHide(isLivePlayback: true,
                controlsHovering: false, isFailed: false,
                keepsControlsVisible: state.holdsControlsVisible, isPlaying: true)
        }
        XCTAssertTrue(mayHide())
        state.hover(true); XCTAssertFalse(mayHide())
        state.hover(false); XCTAssertTrue(mayHide())
        let start = Date(timeIntervalSince1970: 1000)
        let empty = PlayerLiveInfoTimelineSchedule(intervals: [])
        XCTAssertEqual(Array(empty.entries(from: start, mode: .normal)), [start], "No EPG must not keep a refresh clock alive")
        let active = PlayerLiveInfoTimelineSchedule(intervals: [DateInterval(start: start, duration: 135)])
        XCTAssertEqual(Array(active.entries(from: start, mode: .normal)).map { $0.timeIntervalSince(start) }, [0, 60, 120, 135])
        let upcoming = PlayerLiveInfoTimelineSchedule(intervals: [DateInterval(start: start.addingTimeInterval(200), duration: 90)])
        XCTAssertEqual(Array(upcoming.entries(from: start, mode: .normal)).map { $0.timeIntervalSince(start) }, [0, 200, 260, 290])
    }

    func testSubtitlePreferencesArePrivateAndDoNotLeakAcrossResources() {
        let suite = "subtitle-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlayerSubtitlePreferenceStore(defaults: defaults)
        let a = PlayerSubtitlePreferenceStore.identity(media: "https://fixture/a?secret=one", external: nil, trackID: 1, title: "Chinese")
        let b = PlayerSubtitlePreferenceStore.identity(media: "https://fixture/b?secret=two", external: nil, trackID: 1, title: "Chinese")
        let external = PlayerSubtitlePreferenceStore.identity(media: "a", external: "https://fixture/sub.srt?token=private", trackID: 3, title: "中文")
        store.save(.init(encoding: .gb18030, fontStyle: .compatible), for: a)
        XCTAssertEqual(store.preference(for: a).encoding, .gb18030)
        XCTAssertEqual(store.preference(for: b), PlayerSubtitlePreference())
        XCTAssertEqual(store.preference(for: external), PlayerSubtitlePreference())
        XCTAssertEqual(external.count, 64)
        let otherExternal = PlayerSubtitlePreferenceStore.identity(media: "b", external: "https://fixture/sub.srt?token=private", trackID: 3, title: "中文")
        XCTAssertNotEqual(external, otherExternal)
        var relay = ResolvedMedia(url: URL(string: "http://127.0.0.1:9978/proxy")!, headers: [:], siteKey: "fixture", sourceName: "fixture", episodeName: "25")
        XCTAssertNotEqual(PlayerSubtitlePreferenceStore.mediaScope(relay, requestID: UUID()), PlayerSubtitlePreferenceStore.mediaScope(relay, requestID: UUID()))
        relay.subtitlePreferenceIdentity = PlayerSubtitlePreferenceStore.opaqueIdentity(["fixture", "series", "25"])
        XCTAssertEqual(PlayerSubtitlePreferenceStore.mediaScope(relay, requestID: UUID()), PlayerSubtitlePreferenceStore.mediaScope(relay, requestID: UUID()))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("secret=one"))
        store.save(.init(), for: a)
        XCTAssertEqual(store.preference(for: a), PlayerSubtitlePreference())
    }

    func testSubtitleDiagnosticsRetainFactsWithoutURLsPathsOrDialogue() throws {
        var diagnostic = PlayerSubtitleDiagnostics()
        XCTAssertFalse(diagnostic.record(prefix: "ffmpeg", text: "open https://private.test/a?token=secret 中文对白"))
        XCTAssertTrue(diagnostic.record(prefix: "sub/ass", text: "fontselect: (Arial, 400, 0) -> /Users/private/font.otf, -1, NotoSansCJKsc-Regular\n"))
        XCTAssertFalse(diagnostic.record(prefix: "sub/ass", text: "fontselect: (X, 400, 0) -> https://private.test/font?token=secret"))
        XCTAssertFalse(diagnostic.record(prefix: "sub/ass", text: "Glyph 0x4E2D not found, selecting one more font"))
        XCTAssertTrue(diagnostic.record(prefix: "sub/ass", text: "fontselect: failed to find any fallback with glyph 0x20000 for font: (private font, 400, 0)"))
        XCTAssertTrue(diagnostic.record(prefix: "lavf", text: "Using subtitle charset: GB18030\n"))
        let report = diagnostic.report(settings: .init(), bundledFont: true)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(report.utf8)))
        for secret in ["private", "secret", "https://", "/Users/", "中文对白"] { XCTAssertFalse(report.contains(secret)) }
        XCTAssertTrue(report.contains("U+20000")); XCTAssertTrue(report.contains("NotoSansCJKsc-Regular"))
    }

    func testBitmapAndEmbeddedSubtitlesDoNotOfferWrongRepairs() {
        var settings = PlayerSubtitleSettings(); settings.trackID = 2
        settings.codec = "ass"
        XCTAssertTrue(settings.canChooseFont); XCTAssertFalse(settings.canChooseEncoding)
        settings.isExternal = true; XCTAssertTrue(settings.canChooseEncoding)
        settings.codec = "hdmv_pgs_subtitle"
        XCTAssertFalse(settings.canChooseEncoding); XCTAssertFalse(settings.canChooseFont)
    }

    @MainActor func testProgrammeSummaryFitsSmallWindowsWithoutActions() throws {
        let now = Date(), source = LiveSourceID.imported(UUID())
        let channel = LiveChannel(groupName: "Fixture", name: "CCTV-5+", tvgID: "1", streams: [])
        let current = EPGProgramme(channelID: "1", title: "实况录像－2026年世界泳联游泳世界杯 乌兹别克斯坦站", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1800))
        let next = EPGProgramme(channelID: "1", title: "国际足球赛场－英超联赛第9轮", start: current.end, end: current.end.addingTimeInterval(3600))
        XCTAssertTrue(PlayerLiveProgrammeCard.isContiguous(current: current, next: next))
        let epg = LiveEPGState(), generation = epg.prepare(source: source, revision: "fixture")
        let demand = UUID(), incarnation = UUID()
        let batch = EPGNowNextBatch(token: EPGResultToken(serviceIncarnation: incarnation, resourceIdentity: "fixture", sourceEpoch: "fixture", dataVersion: "v1", demandRevision: demand),
            items: [.init(match: .init(kind: .exact, channelID: "1"), current: current, next: next)], availability: .fresh)
        XCTAssertTrue(epg.publish(batch, channels: [channel], source: source, revision: "fixture", generation: generation, demandRevision: demand, serviceIncarnation: incarnation))
        for width in [CGFloat(240), CGFloat(344)] {
            let interaction = PlayerLiveInfoInteraction()
            let host = NSHostingView(rootView: PlayerLiveProgrammeCard(epg: epg, interaction: interaction,
                channel: channel, source: source, compact: width < 300)
                .environment(\.colorScheme, .dark).frame(width: width))
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertGreaterThan(size.height, 70); XCTAssertLessThan(size.height, 180)
            XCTAssertTrue(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSButton }.isEmpty,
                "The summary must contain no Details, Back, Hide or information buttons")
            if let folder = ProcessInfo.processInfo.environment["OKVIDEO_SUBTITLE_VISUAL_OUTPUT"] {
                host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("live-\(Int(width))-summary.png"))
            }
        }
    }
}

@MainActor final class SubtitleNativeTests: XCTestCase {
    private func waitFor(line: UInt = #line, _ predicate: () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Subtitle condition timed out", line: line)
        throw NSError(domain: "SubtitleNative", code: 1)
    }
    func testEncodingFontReloadAndMediaSwitchUseTheRealPlayer() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrase = "简体中文字幕测试；繁體中文字幕測試 English 123"
        let text = "1\n00:00:00,000 --> 00:05:00,000\n\(phrase)\n"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gb = directory.appendingPathComponent("gb18030.srt"), utf = directory.appendingPathComponent("utf8.srt")
        try XCTUnwrap(text.data(using: encoding)).write(to: gb)
        try Data(text.utf8).write(to: utf)
        let player = try MPVPlayerClient(teardownMode: .fullDestroy, audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        let coordinator = PlayerPictureInPictureCoordinator { _, _ in }
        var latest = PlayerSnapshot()
        let reader = Task { @MainActor in
            for await event in player.events { if case .snapshot(let value, _) = event { latest = value } }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 140, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = MPVRenderHostView(player: player, pictureInPicture: coordinator,
            onError: { XCTFail($0.localizedDescription) }, onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        do {
            try await waitFor { host.surface.isReadyForPictureInPicture }
            let media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:], siteKey: "subtitle-fixture", sourceName: "Synthetic", episodeName: "Subtitle fixture")
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await player.addSubtitle(url: gb)
            try await waitFor { latest.subtitleSettings.canChooseEncoding }
            try await waitFor { await player.diagnosticPropertyForTesting("sub-text") == phrase }
            try await player.pause()
            let pausedPosition = await player.diagnosticPropertyForTesting("time-pos")
            let firstID = try XCTUnwrap(latest.subtitleSettings.trackID)
            try await player.setSubtitleEncoding(.utf8)
            try await waitFor { latest.subtitleSettings.encoding == .utf8 }
            let broken = await player.diagnosticPropertyForTesting("sub-text")
            XCTAssertNotEqual(broken, phrase)
            try await player.setSubtitleEncoding(.gb18030)
            try await waitFor { await player.diagnosticPropertyForTesting("sub-text") == phrase }
            try await player.setSubtitleFontStyle(.compatible)
            let override = await player.diagnosticPropertyForTesting("sub-ass-override")
            XCTAssertEqual(override, "strip")
            try await waitFor { await player.diagnosticPropertyForTesting("sub-text") == phrase }
            try await player.addSubtitle(url: utf)
            try await waitFor { latest.subtitleSettings.trackID != firstID && latest.subtitleSettings.trackID != nil }
            XCTAssertEqual(latest.subtitleSettings.encoding, .automatic)
            XCTAssertEqual(latest.subtitleSettings.fontStyle, .original)
            let originalFonts = await player.diagnosticPropertyForTesting("embeddedfonts")
            XCTAssertEqual(originalFonts, "yes")
            try await player.selectTrack(id: firstID, type: .subtitle)
            try await waitFor { latest.subtitleSettings.trackID == firstID }
            XCTAssertEqual(latest.subtitleSettings.encoding, .gb18030)
            XCTAssertEqual(latest.subtitleSettings.fontStyle, .compatible)
            try await waitFor { await player.diagnosticPropertyForTesting("sub-text") == phrase }
            // Reloading the first of multiple external tracks may assign a new
            // native track ID. Preferences must follow the subtitle identity.
            try await player.setSubtitleEncoding(.utf8)
            try await waitFor { latest.subtitleSettings.encoding == .utf8 }
            try await player.setSubtitleEncoding(.gb18030)
            try await waitFor { latest.subtitleSettings.encoding == .gb18030 && latest.subtitleSettings.fontStyle == .compatible }
            try await waitFor { await player.diagnosticPropertyForTesting("sub-text") == phrase }
            let positionAfterChanges = await player.diagnosticPropertyForTesting("time-pos")
            XCTAssertEqual(positionAfterChanges, pausedPosition, "Subtitle repairs must not seek or resume the video")
            if let output = ProcessInfo.processInfo.environment["OKVIDEO_SUBTITLE_VISUAL_OUTPUT"] {
                try await player.screenshot(to: URL(fileURLWithPath: output).appendingPathComponent("subtitle-chinese.png"))
            }
            let diagnostic = try await player.subtitleDiagnostics()
            XCTAssertFalse(diagnostic.contains(directory.path)); XCTAssertFalse(diagnostic.contains(phrase))
            XCTAssertTrue(diagnostic.contains("NotoSansCJKsc-Regular"))
            let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])
            // A deliberately wrong UTF-8 choice can report missing glyphs, so
            // glyph coverage is checked separately with the font render fixture.
            XCTAssertEqual(facts["subtitleLoadFailures"] as? Int, 0)
            try await player.load(media, startPosition: nil, requestID: UUID())
            try await waitFor { latest.subtitleSettings.trackID == nil }
            let reset = await player.diagnosticPropertyForTesting("sub-ass-override")
            XCTAssertEqual(reset, "scale")
            host.tearDown(); window.close(); reader.cancel(); await player.shutdown()
        } catch {
            let diagnostic = (try? await player.subtitleDiagnostics()) ?? "unavailable"
            let subtitleText = await player.diagnosticPropertyForTesting("sub-text") ?? "nil"
            let nativeTracks = await player.diagnosticPropertyForTesting("track-list") ?? "nil"
            NSLog("Synthetic subtitle failure: settings=%@ text=%@ tracks=%@ diagnostics=%@", String(describing: latest.subtitleSettings), subtitleText, nativeTracks, diagnostic)
            host.tearDown(); window.close(); reader.cancel(); await player.shutdown(); throw error
        }
    }
}
