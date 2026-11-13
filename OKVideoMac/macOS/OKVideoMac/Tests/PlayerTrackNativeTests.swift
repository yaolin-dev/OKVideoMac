import AppKit
import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlayerTrackNativeTests: XCTestCase {
    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<250 { if await condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Native track condition timed out")
        throw CancellationError()
    }

    func testEmbeddedAudioAndSubtitleSwitchingKeepsPlaybackAdvancingAndRejectsOldOwner() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_TRACK_FIXTURE"],
              let report = ProcessInfo.processInfo.environment["OKVIDEO_TRACK_REPORT"] else {
            throw XCTSkip("Explicit synthetic multitrack fixture and report required")
        }
        let controller = PlayerLifecycleController(mode: .fullDestroy)
        let player = try XCTUnwrap(controller.renderPlayer)
        let app = AppState(environment: nil)
        var owner = UUID(), latest = PlayerSnapshot(), results: [[String: Any]] = []
        var commands: [Int] = []
        app.trackSelectionExecutorForTesting = { token in
            commands.append(token.trackID!)
            try await controller.selectTrack(token)
        }
        app.trackPreferenceWriterForTesting = { _, _, token in try token.checkValidity() }
        let reader = Task { @MainActor in
            for await event in controller.events {
                if case .snapshot(let value, let request) = event, request == owner {
                    latest = value
                    app.configureTrackSelectionForTesting(owner: owner, tracks: value.tracks)
                }
            }
        }
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) },
            onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        surface.collectRenderTimingsForTesting = true
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 960, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        let media = ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:],
                                  siteKey: "track-fixture", sourceName: "Synthetic", episodeName: "Embedded tracks")
        do {
            try await waitFor { surface.isReadyForPictureInPicture }
            try await controller.load(media, startPosition: nil, requestID: owner)
            try await waitFor { latest.tracks.filter { $0.type == .audio }.count == 3 && latest.tracks.filter { $0.type == .subtitle }.count == 3 }
            try await Task.sleep(nanoseconds: 500_000_000)
            let audio = latest.tracks.filter { $0.type == .audio }, subs = latest.tracks.filter { $0.type == .subtitle }
            var rates: [String] = []
            for (index, track) in (Array(audio.dropFirst()) + [audio[0]] + subs).enumerated() {
                let key = track.type == .audio ? "aid" : "sid"
                let start = ProcessInfo.processInfo.systemUptime
                let firstFrame = surface.renderedFramesForTesting
                let timingIndex = surface.renderTimingsForTesting.count
                await app.requestPlayerTrack(track).value
                let commandDuration = ProcessInfo.processInfo.systemUptime - start
                try await waitFor { await player.diagnosticPropertyForTesting(key) == String(track.id) }
                try await waitFor { await player.diagnosticPropertyForTesting("audio-pts") != nil }
                let a = Double(await player.diagnosticPropertyForTesting("audio-pts") ?? "")
                try await Task.sleep(nanoseconds: 750_000_000)
                let b = Double(await player.diagnosticPropertyForTesting("audio-pts") ?? "")
                let frames = surface.renderedFramesForTesting - firstFrame
                let times = surface.renderTimingsForTesting.dropFirst(timingIndex).compactMap { Double($0.split(separator: ",")[0]) }
                let maxGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
                XCTAssertGreaterThan(frames, 20, "Video must continue after switching")
                XCTAssertGreaterThan(try XCTUnwrap(b) - XCTUnwrap(a), 0.4, "Audio clock must continue")
                XCTAssertLessThan(maxGap, 0.5, "Track switching must not leave video stalled")
                let rate = await player.diagnosticPropertyForTesting("audio-params/samplerate") ?? "unavailable"
                if track.type == .audio { rates.append(rate) }
                results.append(["index": index, "type": track.type.rawValue, "trackID": track.id,
                    "commandSeconds": commandDuration, "renderedFrames": frames, "maximumFrameGapSeconds": maxGap,
                    "audioPTSAdvance": (b ?? 0) - (a ?? 0), "sampleRate": rate,
                    "subtitleCodec": latest.subtitleSettings.codec ?? "none"])
            }
            XCTAssertEqual(Set(rates), Set(["44100", "48000"]))
            let before = commands.count
            let current = try XCTUnwrap(latest.tracks.first { $0.type == .audio && $0.isSelected })
            for _ in 0..<30 { _ = app.requestPlayerTrack(current) }
            await app.requestPlayerTrack(current).value
            XCTAssertEqual(commands.count, before, "Repeated current selection must not reach native player")
            let burst = [audio[1], audio[2], audio[1]]
            for track in burst { _ = app.requestPlayerTrack(track) }
            await app.requestPlayerTrack(audio[1]).value
            XCTAssertEqual(commands.count - before, 1, "A synchronous burst should submit only its last target")
            try await controller.pause()
            try await waitFor { await player.diagnosticPropertyForTesting("pause") == "yes" }
            let pausedPosition = await player.diagnosticPropertyForTesting("time-pos")
            await app.requestPlayerTrack(subs[0]).value
            await app.requestPlayerTrack(audio[2]).value
            let afterPosition = await player.diagnosticPropertyForTesting("time-pos")
            let paused = await player.diagnosticPropertyForTesting("pause")
            XCTAssertEqual(afterPosition, pausedPosition); XCTAssertEqual(paused, "yes")

            var release: CheckedContinuation<Void, Never>?, entered = false
            controller.trackCommandSuspensionForTesting = {
                if !entered { entered = true; await withCheckedContinuation { release = $0 } }
            }
            let oldOwner = owner
            let old = app.requestPlayerTrack(subs[1])
            try await waitFor { entered }
            owner = UUID()
            app.configureTrackSelectionForTesting(owner: owner, tracks: [])
            try await controller.load(media, startPosition: nil, requestID: owner)
            try await waitFor { latest.tracks.filter { $0.type == .subtitle }.count == 3 }
            release?.resume(); await old.value
            let oldToken = PlaybackTrackSelectionToken(requestID: oldOwner, type: .subtitle, trackID: subs[1].id)
            do { try await player.selectTrack(oldToken); XCTFail("Native queue must reject an old media owner") }
            catch is CancellationError { }
            let selectedAfterReload = await player.diagnosticPropertyForTesting("sid")
            XCTAssertEqual(selectedAfterReload, "no")
            try JSONSerialization.data(withJSONObject: ["cases": results, "commandIDs": commands,
                "pausedPositionPreserved": afterPosition == pausedPosition,
                "staleOwnerRejected": true, "fixture": "1080p60, three AAC tracks at 48/48/44.1 kHz, embedded SRT/ASS/DVD bitmap subtitles"],
                options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report))
        } catch {
            reader.cancel(); surface.tearDown(); window.close(); await controller.shutdown(); await app.closePlayer(); throw error
        }
        reader.cancel(); surface.tearDown(); window.close(); await controller.shutdown(); await app.closePlayer()
    }
}
