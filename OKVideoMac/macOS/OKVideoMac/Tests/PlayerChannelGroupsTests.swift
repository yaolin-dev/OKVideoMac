import AppKit
import SwiftUI
import OKVideoCore
import OKVideoPersistence
import XCTest
@testable import OKVideoMac

@MainActor final class PlayerChannelGroupsTests: XCTestCase {
    private func channel(_ name: String, group: String, number: String? = nil) -> LiveChannel {
        LiveChannel(groupName: group, name: name, number: number,
            streams: [.init(name: "Main", url: URL(string: "https://example.invalid/\(name)")!)])
    }

    func testLargeDirectoryPreservesSourceGroupsAndSearchNeverChangesZapScope() {
        for count in [100, 1_000, 5_000] {
            let channels = (0..<count).map { channel("TV\($0)", group: "Group\($0 % 10)", number: "\($0)") }
            let directory = PlayerChannelDirectory(channels: channels + [channels[0]],
                favoriteIDs: [channels[0].id, channels[3].id],
                recentIDs: [channels[3].id, "missing", channels[0].id, channels[3].id])
            XCTAssertEqual(directory.channels.count, count)
            XCTAssertEqual(directory.groups.count, 13)
            XCTAssertEqual(directory.group(.favorites).channels.map(\.id), [channels[0].id, channels[3].id])
            XCTAssertEqual(directory.group(.recent).channels.map(\.id), [channels[3].id, channels[0].id])
            let group = directory.group(.source("Group3"))
            XCTAssertEqual(group.channels.count, count / 10)
            XCTAssertEqual(PlayerChannelSearch.results(group.channels, query: "TV3").first?.id, channels[3].id)
            XCTAssertEqual(group.channels.count, count / 10, "A temporary query must not shrink channel +/- navigation")
        }
    }

    func testMemoryRetainsGroupAndScrollButResetsForAnotherSource() {
        let memory = PlayerChannelPickerMemory(), first = LiveSourceID.imported(UUID())
        memory.prepare(source: first, initialGroup: .source("Satellite"))
        memory.offsets[.source("Satellite")] = 432.5
        memory.highlightedID = "channel17"
        memory.prepare(source: first, initialGroup: .all)
        XCTAssertEqual(memory.group, .source("Satellite"))
        XCTAssertEqual(memory.offsets[memory.group], 432.5)
        XCTAssertEqual(memory.highlightedID, "channel17")
        memory.prepare(source: .imported(UUID()), initialGroup: .all)
        XCTAssertTrue(memory.offsets.isEmpty)
        XCTAssertNil(memory.highlightedID)
        XCTAssertEqual(memory.group, .all)
    }

    func testSelectingFromGroupKeepsChannelNavigationInThatGroupAndRecentIsSourceScoped() async throws {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Fixture", sourceKind: .pasted, rawData: Data())
        let a = channel("A", group: "Local"), b = channel("B", group: "Satellite"), c = channel("C", group: "Satellite")
        let playlist = LivePlaylist(format: .m3u, groups: [.init(name: "Local", channels: [a]), .init(name: "Satellite", channels: [b, c])])
        state.acceptImportedRoutesForTesting(source, playlist: playlist)
        let catalog = try XCTUnwrap(state.acceptedImportedCatalogs[source.id])
        var played: [URL] = []
        state.importedRouteLoadForTesting = { _, media, _ in played.append(media.url) }
        await state.playImportedLive(catalog.selections(for: a)[0], navigationChannels: [a])
        await state.selectPlayerLiveChannel(a.id, source: .imported(source.id), group: .all)
        XCTAssertEqual(played.count, 1, "Selecting the current channel changes scope without reloading")
        XCTAssertTrue(state.canSwitchLiveChannel)
        await state.selectPlayerLiveChannel(b.id, source: .imported(source.id), group: .source("Satellite"))
        XCTAssertEqual(state.livePlaybackChannel?.id, b.id)
        await state.switchLiveChannel(by: 1)
        XCTAssertEqual(state.livePlaybackChannel?.id, c.id)
        await state.switchLiveChannel(by: 1)
        XCTAssertEqual(state.livePlaybackChannel?.id, b.id, "Wrap inside the selected group, never into Local")
        let previousCount = played.count
        await state.selectPlayerLiveChannel(a.id, source: .imported(source.id), group: .source("Satellite"))
        XCTAssertEqual(played.count, previousCount, "Reject a stale/out-of-group selection")
        XCTAssertEqual(state.playerChannelDirectory.group(.recent).channels.map(\.id), [b.id, c.id, a.id])
        let second = StoredLiveSource(name: "Other", sourceKind: .pasted, rawData: Data())
        state.acceptImportedRoutesForTesting(second, playlist: playlist)
        let secondCatalog = try XCTUnwrap(state.acceptedImportedCatalogs[second.id])
        await state.playImportedLive(secondCatalog.selections(for: a)[0], navigationChannels: [a])
        XCTAssertEqual(state.playerChannelDirectory.group(.recent).channels.map(\.id), [a.id])
        await state.closePlayer()
    }

    func testEmptySearchCanSwitchColumnsButTextKeepsItsCaret() {
        var text = "", columns: [Int] = []
        let field = PlayerChannelSearchField(text: .init(get: { text }, set: { text = $0 }),
            move: { _ in }, submit: {}, escape: {}, horizontal: { columns.append($0) })
        let delegate = field.makeCoordinator(), native = NSSearchField(), editor = NSTextView()
        XCTAssertTrue(delegate.control(native, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertTrue(delegate.control(native, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertEqual(columns, [-1, 1])
        text = "CCTV"
        XCTAssertFalse(delegate.control(native, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        editor.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        text = ""
        XCTAssertFalse(delegate.control(native, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertEqual(columns, [-1, 1])
    }

    func testReopeningPickerRestoresGroupOffsetAndNarrowPanelKeepsSearchInBounds() async throws {
        let channels = (0..<100).map { channel("TV\($0)", group: "Group", number: "\($0)") }
        let memory = PlayerChannelPickerMemory()
        memory.highlightedID = channels[0].id
        memory.offsets[.all] = 738
        for width: CGFloat in [570, 340] {
            let host = NSHostingView(rootView: PlayerChannelPicker(directory: PlayerChannelDirectory(channels: channels),
                currentID: channels[0].id, title: "频道", memory: memory, select: { _, _ in }, close: {})
                .padding(14).frame(width: width, height: 490))
            let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: width, height: 490), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            try await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded()
            let scrolls = BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSScrollView }
            let list = try XCTUnwrap(scrolls.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            XCTAssertEqual(list.contentView.bounds.minY, 738, accuracy: 1, "Reopening must not locate current playback automatically")
            let search = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NSSearchField }.first)
            let rect = search.convert(search.bounds, to: host)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, width)
            window.contentView = nil; window.close()
        }
    }

    func testNativeScrollMemoryRestoresExactOffset() async throws {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 350, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 350, height: 240))
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let document = Flipped(frame: .init(x: 0, y: 0, width: 350, height: 2800))
        let probe = PlayerChannelScrollMemory.Probe(frame: document.bounds)
        probe.initialOffset = 423.5
        document.addSubview(probe); scroll.documentView = document; window.contentView = scroll
        defer { probe.stop(); window.close() }
        var reported: CGFloat?
        probe.onScroll = { reported = $0 }; probe.bindLater()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(scroll.contentView.bounds.minY, 423.5, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(reported), 423.5, accuracy: 0.5)
        scroll.contentView.scroll(to: .init(x: 0, y: 701)); probe.bindLater()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try XCTUnwrap(reported), 701, accuracy: 0.5, "After restore, user scrolling must not snap back")
    }

    func testNativePauseKeepsButtonActivationAndSquareLayoutSlot() {
        final class Target: NSObject {
            var count = 0
            @objc func activate() { count += 1 }
        }
        let target = Target()
        let button = LivePlaybackNSButton(image: NSImage(), target: target, action: #selector(Target.activate))
        button.isBordered = false
        button.frame = .init(x: 0, y: 0, width: 36, height: 36)
        XCTAssertEqual(button.intrinsicContentSize, .init(width: 36, height: 36))
        button.performClick(nil)
        XCTAssertEqual(target.count, 1)
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertEqual(target.count, 1)
    }
}
