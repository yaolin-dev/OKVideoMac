import AppKit
import CoreGraphics
import OKVideoCore
import SwiftUI
import XCTest
@testable import OKVideoMac

/// The material must composite over the same native OpenGL surface used in
/// production. An NSHostingView-only bitmap cannot verify that boundary.
@MainActor final class PlayerGlassRenderingTests: XCTestCase {
    private func waitFor(_ phase: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PlayerGlassRendering", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native glass fixture timed out: \(phase)"])
    }

    private func capture(_ window: NSWindow, name: String) throws -> NSBitmapImageRep {
        let cg = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OKVIDEO_PLAYER_UI_VISUAL_OUTPUT"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    func testGlassAndGroupedPickerOverRealNativeVideo() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"])
        let player = try MPVPlayerClient(teardownMode: .fullDestroy,
            audioPreference: .init(muted: true), mediaProxyResolver: { _ in .direct })
        let pip = PlayerPictureInPictureCoordinator { _, _ in }
        var snapshot = PlayerSnapshot()
        let reader = Task { @MainActor in
            for await event in player.events { if case .snapshot(let value, _) = event { snapshot = value } }
        }
        let window = NSWindow(contentRect: .init(x: 120, y: 150, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = MPVRenderHostView(player: player, pictureInPicture: pip,
            onError: { XCTFail($0.localizedDescription) }, onSurfaceReady: { _ in }, onSurfaceUnavailable: { _ in })
        window.contentView = host
        NSApp.setActivationPolicy(.regular); NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        do {
            try await waitFor("render surface") { host.surface.isReadyForPictureInPicture }
            // App startup can present its main window after this test window.
            // Reassert the test window once the native surface has attached.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Materials deliberately use .active and must also render in an
            // inactive player window. XCTest need not own keyboard focus.
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(window.isMiniaturized)
            try await player.load(ResolvedMedia(url: URL(fileURLWithPath: fixture), headers: [:],
                siteKey: "glass-fixture", sourceName: "Synthetic", episodeName: "Glass Fixture"),
                startPosition: nil, requestID: UUID())
            try await waitFor("decoded video") { snapshot.position > 0.1 && snapshot.videoWidth > 0 }
            try await player.pause()
            let baseline = try capture(window, name: "native-video-baseline")

            let source = LiveSourceID.imported(UUID()), epg = LiveEPGState()
            let channels = (1...84).map { index in
                LiveChannel(groupName: index <= 16 ? "央视" : "卫视", name: index == 18 ? "天津卫视" : "频道 \(index)", number: "\(index)",
                    streams: [.init(name: "Fixture", url: URL(fileURLWithPath: fixture))])
            }
            let card = PlayerOverlayHostingView(rootView:
                PlayerLiveProgrammeCard(epg: epg, interaction: PlayerLiveInfoInteraction(), channel: channels[17], source: source, compact: false)
                    .frame(width: 344).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .environment(\.colorScheme, .dark))
            card.frame = host.bounds; card.autoresizingMask = [.width, .height]
            host.addSubview(card)
            try await Task.sleep(nanoseconds: 350_000_000)
            let glass = try capture(window, name: "native-live-glass")
            XCTAssertEqual(baseline.pixelsWide, glass.pixelsWide)
            let materials = BrowserKeyboardView.descendants(of: card).compactMap { $0 as? NSVisualEffectView }
            XCTAssertTrue(materials.contains { $0.blendingMode == .withinWindow && $0.material == .hudWindow })
            card.removeFromSuperview()

            let memory = PlayerChannelPickerMemory()
            memory.prepare(source: source, initialGroup: .source("卫视"))
            let picker = PlayerOverlayHostingView(rootView:
                PlayerChannelPicker(directory: PlayerChannelDirectory(channels: channels, favoriteIDs: [channels[17].id], recentIDs: [channels[17].id]),
                    currentID: channels[17].id, title: "频道", memory: memory, initialGroup: .source("卫视"), epg: epg, source: source,
                    select: { _, _ in }, close: {})
                    .padding(14).frame(width: 570, height: 490).background(PlayerGlassBackground())
                    .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .environment(\.colorScheme, .dark))
            picker.frame = host.bounds; picker.autoresizingMask = [.width, .height]
            host.addSubview(picker)
            try await Task.sleep(nanoseconds: 350_000_000)
            _ = try capture(window, name: "native-grouped-channels")
            picker.removeFromSuperview()
            host.tearDown(); window.close(); reader.cancel(); await player.shutdown()
        } catch {
            host.tearDown(); window.close(); reader.cancel(); await player.shutdown(); throw error
        }
    }
}
