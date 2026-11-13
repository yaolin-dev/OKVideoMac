import AppKit
import Combine
import SwiftUI
import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class VolumePlaybackTests: XCTestCase {
    private final class AudioSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: Double]] = []
        func append(_ value: [String: Double]) { lock.lock(); values.append(value); lock.unlock() }
        func read() -> [[String: Double]] { lock.lock(); defer { lock.unlock() }; return values }
    }
    @MainActor private final class Model: ObservableObject {
        @Published var volume = 20.0
        var changes = 0
        let controller: PlayerLifecycleController
        init(_ controller: PlayerLifecycleController) { self.controller = controller }
        func set(_ value: Double) {
            volume = value; changes += 1
            controller.rememberVolume(value)
            Task { try await controller.applyAudioPreference() }
        }
    }
    @MainActor private struct Controls: View {
        @ObservedObject var model: Model
        var body: some View {
            Slider(value: Binding(get: { model.volume }, set: model.set), in: 0...130,
                   onEditingChanged: { editing in
                       if editing { model.controller.beginVolumeAdjustment() }
                       else { model.controller.endVolumeAdjustment() }
                   })
                .frame(width: 240).padding(20)
        }
    }

    // Actual libmpv/OpenGL playback under a controlled AppKit tracking loop.
    // Optional physical mouse acceptance uses the visible native SwiftUI slider.
    // A separate common-mode timer samples rendering throughout tracking.
    func testTrackingRunLoopKeepsPlaybackAdvancing() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEO_VOLUME_FIXTURE"],
              let output = ProcessInfo.processInfo.environment["OKVIDEO_VOLUME_REPORT"] else {
            throw XCTSkip("Explicit local playback fixture and report required")
        }
        let manual = ProcessInfo.processInfo.environment["OKVIDEO_VOLUME_MANUAL"] == "1"
        let suite = "volume-native-persistence-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlayerLifecycleController(mode: .fullDestroy,
            audioPreferences: PlaybackAudioPreferenceStore(defaults: defaults))
        let player = try XCTUnwrap(controller.renderPlayer)
        let model = Model(controller)
        let surface = MPVOpenGLView(player: player, onError: { XCTFail($0.localizedDescription) },
            onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        surface.collectRenderTimingsForTesting = true
        let controls = NSHostingView(rootView: Controls(model: model))
        let root = NSView(frame: .init(x: 0, y: 0, width: 960, height: 600))
        surface.frame = .init(x: 0, y: 60, width: 960, height: 540)
        controls.frame = .init(x: 0, y: 0, width: 960, height: 60)
        root.addSubview(surface); root.addSubview(controls)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        window.title = "Volume playback regression (synthetic local video)"
        window.setFrameOrigin(.init(x: 80, y: 100))
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            for _ in 0..<40 where !window.isKeyWindow {
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if manual { XCTAssertTrue(window.isKeyWindow, "Fixture must receive native input") }
            for _ in 0..<100 where !surface.isReadyForPictureInPicture { try await Task.sleep(nanoseconds: 30_000_000) }
            XCTAssertTrue(surface.isReadyForPictureInPicture)
            try await controller.load(.init(url: URL(fileURLWithPath: fixture), headers: [:],
                siteKey: "volume-fixture", sourceName: "Local", episodeName: "Synthetic"), startPosition: nil, requestID: UUID())
            try await Task.sleep(nanoseconds: 1_000_000_000)
            controls.layoutSubtreeIfNeeded()
            let slider = try XCTUnwrap(BrowserKeyboardView.descendants(of: controls).compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(slider.isContinuous)
            let start = ProcessInfo.processInfo.systemUptime
            let initial = surface.renderedFramesForTesting
            let audio = AudioSamples()
            let audioReader = Task.detached {
                while !Task.isCancelled {
                    if let raw = await player.diagnosticPropertyForTesting("audio-pts"), let pts = Double(raw) {
                        audio.append(["elapsed": ProcessInfo.processInfo.systemUptime - start, "pts": pts])
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            defer { audioReader.cancel() }
            var samples: [[String: Double]] = []
            let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                samples.append(["elapsed": elapsed, "frames": Double(surface.renderedFramesForTesting),
                                "updates": Double(surface.renderUpdatesForTesting), "changes": Double(model.changes),
                                "tracking": RunLoop.current.currentMode == .eventTracking ? 1 : 0])
                if !manual, elapsed >= 1.5, elapsed < 4.5 {
                    controller.beginVolumeAdjustment()
                    model.set(65 + 45 * sin((elapsed - 1.5) * 6))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            // XCTest's nested waiter services CF sources but does not run
            // NSApplication's outer event dispatch. Keep normal hit testing
            // and NSSlider's own tracking loop, without calling its action.
            let eventPump = Timer(timeInterval: 0.01, repeats: true) { _ in
                while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                    until: .distantPast, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
            if manual { RunLoop.main.add(eventPump, forMode: .common) }
            // Run the same AppKit tracking mode from a CF timer, not from a
            // main-dispatch block (which would artificially starve that queue).
            let tracking = Timer(timeInterval: 0.02, repeats: false) { _ in
                guard !manual else { return }
                let deadline = Date(timeIntervalSinceNow: 4.5)
                while Date() < deadline {
                    _ = RunLoop.current.run(mode: .eventTracking, before: deadline)
                }
            }
            RunLoop.main.add(tracking, forMode: .default)
            try await Task.sleep(nanoseconds: manual ? 20_000_000_000 : 5_200_000_000)
            timer.invalidate(); eventPump.invalidate(); tracking.invalidate()
            controller.endVolumeAdjustment()
            XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value, controller.audioPreference)
            let frames = surface.renderedFramesForTesting - initial
            let report: [String: Any] = ["input": manual ? "physical mouse" : "controlled AppKit tracking loop", "samples": samples, "audioSamples": audio.read(), "frames": frames, "changes": model.changes,
                "timings": surface.renderTimingsForTesting,
                "audioPTS": await player.diagnosticPropertyForTesting("audio-pts") ?? "unavailable",
                "timePosition": await player.diagnosticPropertyForTesting("time-pos") ?? "unavailable"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
            XCTAssertGreaterThan(model.changes, 30, "Must exercise continuous volume changes")
            for (a, b) in zip(samples, samples.dropFirst()) where b["elapsed"]! - a["elapsed"]! > 0.2 {
                XCTFail("Tracking stalled common-mode servicing for \(b["elapsed"]! - a["elapsed"]!)s")
            }
            let held = samples.last { $0["elapsed"]! < 1.4 }?["frames"] ?? Double(initial)
            XCTAssertGreaterThan(held - Double(initial), 30, "Holding the knob must not stop video")
            let dragged = samples.last { $0["elapsed"]! < 4.4 }?["frames"] ?? held
            XCTAssertGreaterThan(dragged - held, 80, "Dragging must not stop video")
            let duringDrag = audio.read().filter { $0["elapsed"]! > 1.5 && $0["elapsed"]! < 4.4 }
            XCTAssertGreaterThan(duringDrag.count, 20, "Playback core must remain responsive during tracking")
            if let first = duringDrag.first, let last = duringDrag.last {
                XCTAssertGreaterThan(last["pts"]! - first["pts"]!, 2, "Audio clock must keep advancing during tracking")
            }
        } catch {
            surface.tearDown(); window.close(); await controller.shutdown(); throw error
        }
        surface.tearDown(); window.close(); await controller.shutdown()
    }
}

@MainActor final class VolumeStateIsolationTests: XCTestCase {
    func testContinuousVolumeOnlyPublishesToAudioControls() async throws {
        let app = AppState(environment: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        let overlay = PlayerOverlayObservation(source: app.playerSnapshotState)
        var browserChanges = 0, overlayChanges = 0, audioChanges = 0
        let a = app.objectWillChange.sink { browserChanges += 1 }
        let b = overlay.objectWillChange.sink { overlayChanges += 1 }
        let c = app.playerAudioState.objectWillChange.sink { audioChanges += 1 }
        for value in 0...130 { await app.setPlayerVolume(Double(value)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(browserChanges, 0, "Dragging must not invalidate browser grids")
        XCTAssertEqual(overlayChanges, 0, "Dragging must not rebuild the entire player overlay")
        XCTAssertEqual(audioChanges, 131)
        XCTAssertEqual(app.playerAudioPreference.volume, 130)
        await app.setPlayerVolume(130)
        await app.setPlayerVolume(.nan)
        XCTAssertEqual(audioChanges, 131, "Duplicate and invalid input must not publish")
        await app.togglePlayerMute()
        XCTAssertTrue(app.playerAudioPreference.muted)
        await app.setPlayerVolume(0)
        XCTAssertTrue(app.playerAudioPreference.muted)
        await app.setPlayerVolume(35)
        XCTAssertFalse(app.playerAudioPreference.muted)
        XCTAssertEqual(browserChanges, 0)
        withExtendedLifetime((a, b, c)) {}
        await app.closePlayer()
    }

    func testNativeAudioEchoDoesNotRedrawOverlayButPlaybackAndSeekStillDo() async throws {
        var snapshot = PlayerSnapshot(status: .playing, position: 10, duration: 100)
        let source = PlayerSnapshotState(snapshot: snapshot)
        let overlay = PlayerOverlayObservation(source: source)
        var redraws = 0
        let token = overlay.objectWillChange.sink { redraws += 1 }
        for volume in 0..<50 {
            snapshot.volume = Double(volume)
            snapshot.isMuted = volume % 2 == 0
            source.update(snapshot)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(redraws, 0)
        snapshot.position = 11
        source.update(snapshot)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(redraws, 1)
        source.beginSeek(id: UUID(), target: 30)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(redraws, 2)
        source.resetSeek()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(redraws, 3)
        withExtendedLifetime(token) {}
    }
}
