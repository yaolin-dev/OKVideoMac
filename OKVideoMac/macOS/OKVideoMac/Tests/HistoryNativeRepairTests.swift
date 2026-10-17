import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor
final class HistoryNativeRepairTests: XCTestCase {
    func testContentRowSeparatorsRenderWithoutEmptyViewportGrid() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rows = (0..<3).map { NativeLibraryRow(id: "\($0)", title: "影片 \($0)", subtitle: "来源 · 第34集", posterURL: nil, date: Date()) }
            let host = NSHostingView(rootView: NativeLibraryList(rows: rows, selection: .constant(["1"]), repository: nil,
                openTitle: "播放", onOpen: { _ in }, onDelete: { _, _ in }))
            let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 700, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 60_000_000)
            host.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
            XCTAssertTrue(table.gridStyleMask.isEmpty, "Empty space must not receive phantom row grid lines")
            for index in rows.indices {
                let row = try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true) as? NativeLibrarySelectionRowView)
                row.setBrowserHovered(index == 2)
                row.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                row.cacheDisplay(in: row.bounds, to: bitmap)
                // Full-width tables extend the row beyond the clipped viewport.
                // Sample its visible center, not the clipped outer margin.
                let x = bitmap.pixelsWide / 2
                let middle = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                let edge = [0, 1, bitmap.pixelsHigh - 2, bitmap.pixelsHigh - 1].compactMap {
                    bitmap.colorAt(x: x, y: $0)?.usingColorSpace(.deviceRGB)
                }
                XCTAssertTrue(edge.contains {
                    abs($0.redComponent - middle.redComponent) > 0.025 ||
                    abs($0.alphaComponent - middle.alphaComponent) > 0.025
                },
                    "Separator must be visible for regular, selected, and hovered rows in \(appearance)")
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: "/private/tmp/ok127-separators-\(appearance.rawValue).png"))
        }
    }
    private func fixture() throws -> (AppState, AppEnvironment, StoredConfiguration) {
        let environment = try AppEnvironment.live()
        let configuration = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data("{}".utf8))
        return (AppState(environment: environment), environment, configuration)
    }
    func testPeriodicWritePublishesAndCloseCapturesLastSeconds() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 3.8, duration: 2809)
        state.changeHistoryProgressForTesting(position: 4.8, duration: 2809)
        await state.finishHistoryForTesting()
        XCTAssertEqual(state.history.first?.position, 4.8)
        XCTAssertNotNil(HistoryView.displayedProgress(position: state.history[0].position, duration: state.history[0].duration))
        state.changeHistoryProgressForTesting(position: 5.2, duration: 2809)
        await state.closePlayer()
        let saved = try await environment.database.history()
        XCTAssertEqual(saved.first?.position, 5.2)
        XCTAssertEqual(state.history.first?.position, 5.2)
    }
    func testApplicationShutdownPersistsBeforeInvalidatingOwnership() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 3.4, duration: 100)
        await state.shutdown()
        let records = try await environment.database.history()
        XCTAssertEqual(records.first?.position, 3.4)
    }
    func testDeletionSuppressesQueuedAndFutureWritesAcrossQualitySwitch() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 10, duration: 100)
        await state.persistPlaybackProgress()
        let records = state.history
        state.changeHistoryProgressForTesting(position: 11, duration: 100)
        let success = await state.deleteHistory(records: records)
        XCTAssertTrue(success)
        state.qualityOwnershipForTesting()
        state.changeHistoryProgressForTesting(position: 12, duration: 100)
        await state.persistPlaybackProgress()
        await state.closePlayer()
        let saved = try await environment.database.history()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(state.history.isEmpty)
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 2, duration: 100)
        await state.persistPlaybackProgress()
        let restarted = try await environment.database.history()
        XCTAssertEqual(restarted.first?.position, 2)
    }
    func testRapidTransitionPreservesEachImmutableFinalWrite() async throws {
        let (state, environment, configuration) = try fixture()
        for index in 1...3 {
            state.seedHistoryPlaybackForTesting(configuration: configuration, videoID: "video\(index)", position: Double(index), duration: 100)
            state.transitionHistoryForTesting()
        }
        await state.finishHistoryForTesting()
        let records = try await environment.database.history()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.position)), [1, 2, 3])
    }
    func testQualityTransferKeepsCheckpointAndAllowsRewind() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 80, duration: 100)
        await state.persistPlaybackProgress()
        state.qualityOwnershipForTesting()
        state.changeHistoryProgressForTesting(position: 30, duration: 100)
        await state.persistPlaybackProgress()
        let records = try await environment.database.history()
        XCTAssertEqual(records.first?.position, 30)
    }
    func testUnknownAndNonfiniteProgressHasSafeText() {
        XCTAssertNil(HistoryView.displayedProgress(position: .nan, duration: 100))
        XCTAssertNil(HistoryView.displayedProgress(position: 12, duration: .infinity))
        XCTAssertTrue(HistoryView.progressText(position: 12, duration: 0).contains("00:12"))
        XCTAssertEqual(HistoryView.displayedProgress(position: 300, duration: 100), 1)
        var checkpoint = PlayerHistoryProgressCheckpoint(); let owner = UUID()
        checkpoint.reset(owner: owner)
        checkpoint.observe(.init(status: .playing, position: 5, duration: 0), owner: owner)
        XCTAssertEqual(checkpoint.resolve(position: 0, duration: 0, reliable: false, owner: owner)?.position, 5)
        XCTAssertNil(checkpoint.resolve(position: 9, duration: 10, reliable: true, owner: UUID()))
    }
    func testDeleteTransactionRollsBackHistoryWhenMarkersAreMalformed() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database
        let a = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "a", title: "A")
        let b = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "b", title: "B")
        try await store.saveHistory(a, incognito: false); try await store.saveHistory(b, incognito: false)
        try await store.setSetting(.string("invalid json"), forKey: "playback.completionMarkers.v1")
        let session = UUID()
        do { try await store.deleteWatchedHistory([a,b], suppressing: [session]); XCTFail("must fail") } catch {}
        let unchanged = try await store.history()
        XCTAssertEqual(Set(unchanged.map(\.id)), [a.id,b.id])
        var next = a; next.position = 4; next.watchedAt = Date().addingTimeInterval(1)
        let wrote = try await store.saveWatchedHistory(next, replacing: nil, sessionID: session)
        XCTAssertTrue(wrote, "failed deletion must not suppress the session")
    }
    func testDeleteOriginalIdentityAlsoDeletesCommittedReplacement() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database, session = UUID()
        let original = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "old", title: "A")
        let replacement = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "resolved", title: "A")
        try await store.saveHistory(original, incognito: false)
        _ = try await store.saveWatchedHistory(replacement, replacing: original, sessionID: session)
        try await store.deleteWatchedHistory([original], suppressing: [session])
        let rows = try await store.history()
        XCTAssertTrue(rows.isEmpty)
        let saved = try await store.saveWatchedHistory(replacement, replacing: original, sessionID: session)
        XCTAssertFalse(saved)
    }

    func testLateCheckpointCannotReplaceNewerEpisode() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database
        let a = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "a", title: "A", sourceName: "Line", episodeName: "E1", position: 80, duration: 100, watchedAt: Date(timeIntervalSince1970: 100))
        var b = a; b.episodeName = "E2"; b.position = 3; b.watchedAt = Date(timeIntervalSince1970: 200)
        _ = try await store.saveWatchedHistory(b, replacing: nil, sessionID: UUID())
        _ = try await store.saveWatchedHistory(a, replacing: nil, sessionID: UUID())
        let rows = try await store.history()
        XCTAssertEqual(rows.first?.episodeName, "E2"); XCTAssertEqual(rows.first?.position, 3)
    }
    func testNativeTableFillsWindowAndRetainsSelectionOnProgressRefresh() async throws {
        let first = NativeLibraryRow(id: "one", title: "Title", subtitle: "Source", posterURL: nil, date: Date(), progress: 0.2)
        var selected: Set<String> = ["one"]
        func root(_ row: NativeLibraryRow) -> NativeLibraryList {
            NativeLibraryList(rows: [row], selection: Binding(get: { selected }, set: { selected = $0 }), repository: nil,
                openTitle: "Open", onOpen: { _ in }, onDelete: { _, _ in })
        }
        let host = NSHostingView(rootView: root(first))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 950, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for width in [950.0, 500.0, 1200.0] {
            window.setContentSize(.init(width: width, height: 300))
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeLibraryTableView }.first)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeLibraryCell)
            cell.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(cell.convert(cell.remove.bounds, from: cell.remove).maxX, width - 60)
            var updated = first; updated.progress = 0.8
            host.rootView = root(updated)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
            XCTAssertEqual(selected, ["one"])
        }
    }

    func testLibrarySelectionAppearancePreservesKeyboardAndMultipleSelection() async throws {
        let rows = (0..<3).map { NativeLibraryRow(id: "\($0)", title: "影片 \($0 + 1) · 长标题布局检查", subtitle: "来源名称 · 第 12 集", posterURL: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), progress: 0.6, progressText: "18:00 / 30:00") }
        var selected: Set<String> = ["0", "1"]
        let host = NSHostingView(rootView: NativeLibraryList(rows: rows, selection: Binding(get: { selected }, set: { selected = $0 }),
            repository: nil, openTitle: "继续播放", onOpen: { _ in }, onDelete: { _, _ in }))
        final class AppearanceWindow: NSWindow {
            var presentsActive = true
            override var isKeyWindow: Bool { presentsActive }
        }
        let window = AppearanceWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 1]))
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [500.0, 900.0] {
                window.setContentSize(.init(width: width, height: 320))
                try await Task.sleep(nanoseconds: 30_000_000)
                host.layoutSubtreeIfNeeded()
                let row = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? NativeLibrarySelectionRowView)
                XCTAssertEqual(row.interiorBackgroundStyle, .normal)
                XCTAssertLessThanOrEqual(row.selectionRect.maxX, row.visibleRect.maxX - 9.5)
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeLibraryCell)
                cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.progress.frame.height, 2, accuracy: 0.01)
                XCTAssertGreaterThan(cell.remove.convert(cell.remove.bounds, to: cell).minX, 0)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/ok123-library-\(appearance.rawValue)-\(Int(width)).png"))
            }
        }
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        XCTAssertTrue(table.showsKeyboardFocus)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(selected, ["1"])
        table.selectAll(nil)
        XCTAssertEqual(selected, ["0", "1", "2"])
        window.makeFirstResponder(nil)
        XCTAssertFalse(table.showsKeyboardFocus)
        window.presentsActive = false
        window.resignKey()
        XCTAssertEqual(selected.count, 3)
    }

    func testNativeButtonsOwnTheirEntireBoundsAndRetainStableTarget() {
        let cell = NativeLibraryCell(frame: .init(x: 0, y: 0, width: 900, height: 100))
        var removed: Set<String> = []; var opened = ""
        let row = NativeLibraryRow(id: "first", title: "First", subtitle: "Line", posterURL: nil, date: Date(), progress: 0.1, progressText: "00:10 / 01:40")
        cell.update(row, repository: nil, openTitle: "Open", onOpen: { opened = $0 }, onDelete: { ids, _ in removed = ids })
        cell.layoutSubtreeIfNeeded()
        let button = cell.remove
        for point in [NSPoint(x: 2, y: button.bounds.midY), NSPoint(x: button.bounds.maxX - 2, y: button.bounds.midY)] {
            XCTAssertTrue(button.hitTest(button.convert(point, to: button.superview)) === button)
        }
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        button.performClick(nil)
        XCTAssertEqual(removed, ["first"]); XCTAssertEqual(opened, "")
        cell.open.performClick(nil); XCTAssertEqual(opened, "first")
    }
}

@MainActor
final class BrowserHoverInteractionTests: XCTestCase {
    private final class Target: NSView, BrowserHoverTarget {
        var hovered = false
        var changes = 0
        func setBrowserHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value; changes += 1
        }
    }
    private final class Scroll: BrowserHoverScrollView {
        var pointerTarget: NSView?
        override func hoverTargetUnderMouse() -> NSView? { pointerTarget }
    }
    private func settled() async throws { try await Task.sleep(nanoseconds: 230_000_000) }

    func testTrackingOwnerReceivesAppKitSelectorsWithoutCallingRefreshDirectly() throws {
        let scroll = NSScrollView(), first = Target(), second = Target()
        let controller = BrowserHoverController.attached(to: scroll)
        var target: NSView? = first
        controller.resolveTarget = { target }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for name in ["mouseEntered:", "mouseMoved:", "mouseExited:"] {
            XCTAssertTrue(controller.responds(to: NSSelectorFromString(name)), "Missing AppKit selector \(name)")
        }
        guard controller.responds(to: NSSelectorFromString("mouseEntered:")),
              controller.responds(to: NSSelectorFromString("mouseMoved:")),
              controller.responds(to: NSSelectorFromString("mouseExited:")) else { return }
        controller.perform(NSSelectorFromString("mouseEntered:"), with: event)
        XCTAssertTrue(first.hovered)
        target = second
        controller.perform(NSSelectorFromString("mouseMoved:"), with: event)
        XCTAssertFalse(first.hovered); XCTAssertTrue(second.hovered)
        controller.perform(NSSelectorFromString("mouseExited:"), with: event)
        XCTAssertFalse(second.hovered)
    }


    func testStationaryPointerRestoresOntoNewCardAfterWheelStops() async throws {
        let scroll = Scroll(), old = Target(), next = Target()
        scroll.pointerTarget = old; scroll.refreshBrowserHover()
        XCTAssertTrue(old.hovered)
        scroll.noteHoverScroll(phase: [], momentumPhase: [])
        XCTAssertFalse(old.hovered)
        scroll.pointerTarget = next; scroll.refreshBrowserHover()
        XCTAssertFalse(next.hovered)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(scroll.hoverSuppressed)
        try await settled()
        XCTAssertTrue(next.hovered)
        XCTAssertFalse(old.hovered)
        XCTAssertEqual(old.changes, 2)
        XCTAssertEqual(next.changes, 1)
        scroll.resetBrowserHover()
    }

    func testGesturePauseAndMomentumNeverRestoreEarly() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: .began, momentumPhase: [])
        try await settled()
        XCTAssertTrue(scroll.hoverSuppressed, "Finger held still must not restore hover")
        scroll.noteHoverScroll(phase: .ended, momentumPhase: [])
        scroll.noteHoverScroll(phase: [], momentumPhase: .began)
        try await settled()
        XCTAssertFalse(card.hovered)
        scroll.noteHoverScroll(phase: [], momentumPhase: .changed)
        scroll.noteHoverScroll(phase: [], momentumPhase: .ended)
        try await settled()
        XCTAssertTrue(card.hovered)
        scroll.resetBrowserHover()
    }

    func testRapidReverseAndScrollerDragRestartSettlement() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        for _ in 0..<4 {
            scroll.noteHoverScroll(phase: [], momentumPhase: [])
            try await Task.sleep(nanoseconds: 65_000_000)
            XCTAssertFalse(card.hovered)
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await settled()
        XCTAssertFalse(card.hovered)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await settled()
        XCTAssertTrue(card.hovered)
        scroll.resetBrowserHover()
    }

    func testViewportMoveReevaluatesPointerAndResetCancelsTimer() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(card.hovered)
        scroll.pointerTarget = nil
        try await settled()
        XCTAssertFalse(card.hovered)
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: .began, momentumPhase: [])
        scroll.noteHoverScroll(phase: .cancelled, momentumPhase: [])
        scroll.resetBrowserHover()
        try await settled()
        XCTAssertFalse(card.hovered, "Detached/closed surface must not restore its old target")
    }

    func testHoverOnlyTouchesOldAndNewTargets() {
        let scroll = Scroll(), old = Target(), next = Target()
        scroll.pointerTarget = old
        for _ in 0..<100 { scroll.refreshBrowserHover() }
        XCTAssertEqual(old.changes, 1)
        scroll.pointerTarget = next; scroll.refreshBrowserHover()
        XCTAssertEqual(old.changes, 2); XCTAssertEqual(next.changes, 1)
        scroll.resetBrowserHover()
        XCTAssertEqual(next.changes, 2)
    }

    func testScrollingPreservesPosterKeyboardHighlightAndLibrarySelection() async throws {
        let scroll = Scroll(), poster = PosterNativeCardView(frame: NSRect(x: 0, y: 0, width: 160, height: 280))
        poster.setKeyboardHighlighted(true)
        scroll.pointerTarget = poster; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: [], momentumPhase: [])
        XCTAssertEqual(poster.layer?.borderWidth, 1)
        try await settled()
        XCTAssertEqual(poster.layer?.borderWidth, 1)
        scroll.resetBrowserHover()
        poster.setKeyboardHighlighted(false)
        poster.setBrowserHovered(true)
        XCTAssertEqual(poster.layer?.borderWidth, 0, "Hover uses a quiet fill, not a selection outline")
        let row = NativeLibrarySelectionRowView(); row.isSelected = true
        let live = LiveChannelNativeCard(); live.selected = true
        for target in [row as NSView, live] {
            scroll.pointerTarget = target; scroll.refreshBrowserHover()
            scroll.noteHoverScroll(phase: [], momentumPhase: [])
        }
        XCTAssertTrue(row.isSelected); XCTAssertTrue(live.selected)
        scroll.resetBrowserHover()
    }
}

@MainActor
final class BrowserHoverSurfaceTests: XCTestCase {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    func testNativeAndSwiftUICardHitTestingRespectsClippedViewport() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        scroll.documentView = doc
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let card = PosterNativeCardView(frame: NSRect(x: 20, y: 30, width: 140, height: 240))
        doc.addSubview(card)
        let background = BrowserHoverBackground.Background(frame: NSRect(x: 200, y: 30, width: 140, height: 240))
        doc.addSubview(background)
        window.contentView?.layoutSubtreeIfNeeded()
        let controller = BrowserHoverController.attached(to: scroll)
        XCTAssertTrue(controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)) === card, "hit=\(String(describing: controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)))) doc=\(doc.frame) clip=\(scroll.contentView.bounds) card=\(card.frame) point=\(scroll.contentView.convert(card.convert(NSPoint(x: 30, y: 40), to: nil), from: nil)) direct=\(String(describing: card.hitTest(NSPoint(x: 50, y: 70))))")
        XCTAssertTrue(controller.hoverTarget(atWindowPoint: background.convert(NSPoint(x: 30, y: 40), to: nil)) === background)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 260))
        XCTAssertNil(controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)), "Offscreen portion must not hover")
        background.detach()
        controller.resetBrowserHover()
    }

    func testHoverRenderingLightAndDark() throws {
        let output = URL(fileURLWithPath: "/private/tmp/ok126-hover-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let canvas = Flipped(frame: NSRect(x: 0, y: 0, width: 780, height: 360))
            canvas.wantsLayer = true
            canvas.appearance = NSAppearance(named: name)
            canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
                canvas.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            }
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            let poster = PosterNativeCardView(frame: NSRect(x: 20, y: 25, width: 150, height: 270))
            let live = LiveChannelNativeCard()
            live.frame = NSRect(x: 200, y: 25, width: 260, height: LiveChannelCardMetrics.height(width: 260))
            let legacy = BrowserHoverBackground.Background(frame: NSRect(x: 500, y: 25, width: 250, height: 100))
            poster.bind(summary: VideoSummary(siteKey: "fixture", siteName: "示例", videoID: "1", title: "静止时的轻量悬浮"), repository: nil, pixels: 256, onSelect: {})
            live.bind(channel: LiveChannel(groupName: "示例", name: "示例频道", streams: []), favorite: false, urls: [], pixels: 256, repository: nil)
            canvas.addSubview(poster); canvas.addSubview(live); canvas.addSubview(legacy)
            canvas.layoutSubtreeIfNeeded()
            poster.setBrowserHovered(true); live.setBrowserHovered(true); legacy.setBrowserHovered(true)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("hover-\(name.rawValue).png"))
            XCTAssertEqual(poster.layer?.borderWidth, 0)
            window.close()
        }
    }
}

@MainActor
final class DanmakuSmoothRenderingTests: XCTestCase {
    private func timeline() -> DanmakuTimeline {
        .init(comments: (0..<60).map { i in .init(id: "\(i)", time: 1,
            mode: i % 3 == 0 ? .scrolling : (i % 3 == 1 ? .top : .bottom),
            fontSize: 22, color: i % 2 == 0 ? 0xFFFFFF : 0xE0AAFF,
            text: "弹幕缓存与同步测试 \(i) · 流畅移动 ♡") })
    }
    private func makeView() -> (DanmakuOverlayNSView, NSWindow) {
        let view = DanmakuOverlayNSView(frame: .init(x: 0, y: 0, width: 2240, height: 1260))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
    private func update(_ view: DanmakuOverlayNSView, timeline: DanmakuTimeline, snapshot: PlayerSnapshot,
                        revision: UInt64 = 1, opacity: Double = 0.86) {
        view.update(timeline: timeline, timelineRevision: revision, snapshot: snapshot, offset: 0,
                    fontScale: 1, opacity: opacity, displayArea: .full, density: .high)
    }
    func testFramesOnlyMoveCachedSpritesAndRemainMemoryBounded() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = timeline()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = PlayerSnapshot(status: .playing, position: 1)
        snapshot.positionSampleUptime = now
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 60)
        let rasterizations = view.rasterizationCount, bytes = view.rasterBytes
        let layers = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
        let original = layers[0].position
        let start = ProcessInfo.processInfo.systemUptime
        for frame in 1...240 { view.renderFrame(at: now + Double(frame) / 120) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(layers[0].position.x, original.x)
        XCTAssertEqual(view.rasterizationCount, rasterizations)
        XCTAssertEqual(view.rasterBytes, bytes)
        XCTAssertLessThanOrEqual(bytes, DanmakuOverlayNSView.maximumRasterBytes)
        XCTAssertNil(layers[0].animationKeys(), "No implicit per-frame animation may fight media time")
        // A same-snapshot appearance update changes compositing, not the cached text.
        update(view, timeline: timeline, snapshot: snapshot, opacity: 0.5)
        XCTAssertEqual(view.rasterizationCount, rasterizations)
        XCTAssertEqual(layers[0].opacity, 0.5)
        let output = "60 comments, 240 position-only frames: \(elapsed * 1000) ms total; rasterizations=\(rasterizations); bytes=\(bytes)\n"
        try output.write(toFile: "/private/tmp/ok128-danmaku-render-metrics.txt", atomically: true, encoding: .utf8)
        view.renderFrame(at: now + 12)
        XCTAssertEqual(view.activeCommentCount, 0)
        XCTAssertEqual(view.rasterBytes, 0)
    }
    func testPausedSpritesFreezeAndSeekOrNewTimelineClearsOldContents() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = timeline()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = PlayerSnapshot(status: .paused, position: 1)
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 60)
        let layers = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
        let positions = layers.map(\.position)
        view.renderFrame(at: now + 10)
        XCTAssertEqual(layers.map(\.position), positions)
        XCTAssertFalse(view.isDisplayDriverRunning)
        snapshot.isSeeking = true; snapshot.seekTarget = 100
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 0)
        XCTAssertEqual(view.rasterBytes, 0)
        snapshot = .init(status: .paused, position: 1)
        update(view, timeline: timeline, snapshot: snapshot, revision: 2)
        XCTAssertEqual(view.activeCommentCount, 60)
        XCTAssertTrue(layers.allSatisfy { $0.superlayer == nil })
        update(view, timeline: .init(comments: []), snapshot: snapshot, revision: 3)
        XCTAssertEqual(view.rasterBytes, 0)
    }
    func testRetinaRasterShowsLegibleTextAndColor() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = DanmakuTimeline(comments: [.init(id: "top", time: 1, mode: .top, fontSize: 38,
            color: 0xE0AAFF, text: "兰香如故 · 弹幕流畅度测试 128 ♡")])
        update(view, timeline: timeline, snapshot: .init(status: .paused, position: 1))
        let sprite = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first)
        let contents = try XCTUnwrap(sprite.contents)
        let image = contents as! CGImage
        XCTAssertEqual(image.width, Int(ceil(sprite.bounds.width * sprite.contentsScale)))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var visiblePixels = 0, purplePixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                visiblePixels += 1
                if color.blueComponent > color.greenComponent + 0.1 { purplePixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 100)
        XCTAssertGreaterThan(purplePixels, 100)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ok128-danmaku-sprite.png"))
        // Render the real layer tree to verify text orientation and top placement.
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1120, pixelsHigh: 630,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4480, bitsPerPixel: 32)!
        let graphics = NSGraphicsContext(bitmapImageRep: canvas)!
        graphics.cgContext.setFillColor(NSColor.darkGray.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 1120, height: 630))
        // Match AppKit's flipped NSView context when rendering the layer tree.
        graphics.cgContext.translateBy(x: 0, y: 630)
        graphics.cgContext.scaleBy(x: 0.5, y: -0.5)
        view.layer!.render(in: graphics.cgContext)
        try XCTUnwrap(canvas.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ok128-danmaku-layer.png"))
    }
    func testDisplayDriverStopsWithoutDeliveringQueuedFrames() async throws {
        var count = 0
        let driver = DanmakuDisplayDriver { count += 1 }
        driver.start(displayID: CGMainDisplayID())
        XCTAssertTrue(driver.isRunning)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(count, 0)
        driver.stop()
        let stopped = count
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(count, stopped)
        driver.start(displayID: CGMainDisplayID())
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertGreaterThan(count, stopped)
        driver.stop()
    }
}

final class CatPawColdHistoryTests: XCTestCase {
    private let configuration = "history-cold-fixture"
    private func provider(_ client: HTTPClient) throws -> NodeHTTPSpiderSiteProvider {
        try NodeHTTPSpiderSiteProvider(site: .init(key: "fixture", name: "CatPawOpen", type: 4,
            api: "/spider/fixture/3", extra: ["okNodeRuntime": .bool(true)]),
            baseURL: URL(string: "http://127.0.0.1:18988/")!, httpClient: client, configurationIdentity: configuration)
    }
    private func persistedReference() async throws -> PlaybackResourceReference {
        let initial = try provider(ColdQuarkClient(tokenVersion: "yesterday"))
        let detail = try await initial.detail(id: "video")
        let reference = try XCTUnwrap(detail.playSources.first?.episodes.first?.providerResourceReference)
        let data = try JSONEncoder().encode(reference)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["yesterday", "shareFidToken", "stoken", "cookie", "passcode"] { XCTAssertFalse(text.contains(forbidden)) }
        return try JSONDecoder().decode(PlaybackResourceReference.self, from: data)
    }
    private func request(_ ref: PlaybackResourceReference, videoID: String = "video") -> PlaybackRefreshRequest {
        .init(videoID: videoID, title: "历史影片", sourceIdentity: ref.sourceIdentity,
            resourceIdentity: ref.episodeIdentity, sourceName: "夸克原画", episodeName: "第64集",
            episodeReference: ref.stableResourceLocator, providerResourceReference: ref)
    }
    func testColdAndRestartedHistoryAlwaysUsesCompleteCurrentFileToken() async throws {
        let persisted = try await persistedReference()
        // Each attempt uses a new runtime/client with an empty play cache.
        for version in ["current", "after-restart", "after-expiry"] {
            let client = ColdQuarkClient(tokenVersion: version, omitsDetailID: true)
            let fresh = try provider(client)
            let replay = try await fresh.refreshPlayback(request(persisted))
            XCTAssertEqual(replay.episode.url, try ColdQuarkClient.episode(version))
            XCTAssertEqual(replay.detail.summary.videoID, "video", "Missing vod_id uses the navigation summary")
            XCTAssertEqual(replay.playbackResult.resourceReference?.stableResourceLocator, persisted.stableResourceLocator)
            let requests = await client.captured()
            XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/detail") }.count, 1)
            XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/play") }.count, 1)
            XCTAssertFalse(requests.contains { $0.url == QuarkEpisodeReference.shareTokenURL || $0.url.path == "/website/api/status" })
        }
    }
    func testExpiredNavigationSearchesAgainButKeepsOriginalFileIdentity() async throws {
        let reference = try await persistedReference(), client = ColdQuarkClient()
        let result = try await provider(client).refreshPlayback(request(reference, videoID: "expired"))
        XCTAssertEqual(result.episode.url, try ColdQuarkClient.episode("current"))
        let requests = await client.captured()
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/search") }.count, 1)
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/play") }.count, 1)
    }
    func testSameNameDifferentFileAndAmbiguousEpisodeNeverAutoPlay() async throws {
        let ref = try await persistedReference()
        for client in [ColdQuarkClient(fileID: "different-file"), ColdQuarkClient(duplicateEpisode: true)] {
            do { _ = try await provider(client).refreshPlayback(request(ref)); XCTFail("An ambiguous or different file must require selection") }
            catch { XCTAssertFalse(error is NodeWebAuthorizationRequired) }
            let requests = await client.captured()
            XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/play") })
        }
    }
    func testMisreportedCookieFailureChecksQuarkStatusOnly() async throws {
        for loggedIn in [true, false] {
            let client = ColdQuarkClient(misreportsCookieFailure: true, loggedIn: loggedIn)
            do { _ = try await provider(client).player(flag: "夸克原画", episodeURL: ColdQuarkClient.episode("current"), transferContext: .init(requestID: UUID(), requestGeneration: 1)); XCTFail("Fixture must fail") }
            catch { XCTAssertEqual(error is NodeWebAuthorizationRequired, !loggedIn) }
            let requests = await client.captured()
            XCTAssertEqual(requests.filter { $0.url.path == "/website/api/status" }.count, 1)
            XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/play") }.count, 1, "No blind repeat of cloud transfer")
            XCTAssertFalse(requests.contains { $0.url.path.contains("credentials") })
        }
    }
    @MainActor
    func testHistorySelectionHonorsSavedFileIdentityAndOffersAmbiguousMatches() async throws {
        let ref = try await persistedReference()
        let record = HistoryRecord(siteKey: "fixture", videoID: "video", title: "历史影片",
            sourceName: "夸克原画", episodeName: "第64集", episodeReference: ref.stableResourceLocator, position: 128)
        for client in [ColdQuarkClient(fileID: "different-file"), ColdQuarkClient(duplicateEpisode: true)] {
            let detail = try await provider(client).detail(id: "video")
            XCTAssertNil(AppState.historyPlaybackSelection(in: detail, record: record))
            let choices = AppState.historyPlaybackChoices(in: detail, record: record)
            XCTAssertEqual(choices.count, client.duplicateEpisode ? 2 : 0)
        }
        let fresh = try await provider(ColdQuarkClient()).detail(id: "video")
        let match = try XCTUnwrap(AppState.historyPlaybackSelection(in: fresh, record: record))
        XCTAssertEqual(match.episode.url, try ColdQuarkClient.episode("current"))
        XCTAssertEqual(record.position, 128)
    }
    func testUnavailableAccountStatusPreservesAuthorizationPrompt() async throws {
        let client = ColdQuarkClient(misreportsCookieFailure: true, statusUnavailable: true)
        do {
            _ = try await provider(client).player(flag: "夸克原画", episodeURL: ColdQuarkClient.episode("current"),
                transferContext: .init(requestID: UUID(), requestGeneration: 1))
            XCTFail("Fixture must fail")
        } catch { XCTAssertTrue(error is NodeWebAuthorizationRequired) }
    }
    func testExplicitFileTokenErrorDoesNotRequestLogin() async throws {
        let client = ColdQuarkClient(explicitFileTokenFailure: true)
        do { _ = try await provider(client).player(flag: "夸克原画", episodeURL: ColdQuarkClient.episode("current"), transferContext: .init(requestID: UUID(), requestGeneration: 1)); XCTFail("Fixture must fail") }
        catch { XCTAssertFalse(error is NodeWebAuthorizationRequired); XCTAssertTrue(error.localizedDescription.contains("token")) }
        let requests = await client.captured()
        XCTAssertFalse(requests.contains { $0.url.path == "/website/api/status" })
    }
}

private actor ColdQuarkClient: HTTPClient {
    let tokenVersion: String, fileID: String
    let omitsDetailID: Bool, duplicateEpisode: Bool, misreportsCookieFailure: Bool, loggedIn: Bool, explicitFileTokenFailure: Bool, statusUnavailable: Bool
    private var requests: [HTTPRequest] = []
    init(tokenVersion: String = "current", fileID: String = "file-64", omitsDetailID: Bool = false,
         duplicateEpisode: Bool = false, misreportsCookieFailure: Bool = false, loggedIn: Bool = true, explicitFileTokenFailure: Bool = false, statusUnavailable: Bool = false) {
        self.tokenVersion = tokenVersion; self.fileID = fileID; self.omitsDetailID = omitsDetailID
        self.duplicateEpisode = duplicateEpisode; self.misreportsCookieFailure = misreportsCookieFailure
        self.loggedIn = loggedIn; self.explicitFileTokenFailure = explicitFileTokenFailure; self.statusUnavailable = statusUnavailable
    }
    static func episode(_ version: String, fileID: String = "file-64") throws -> String {
        let token = try JSONSerialization.data(withJSONObject: ["fid": fileID, "shareId": "share-fixture", "stoken": "stoken-\(version)", "shareFidToken": "file-token-\(version)", "fileName": "第64集"], options: [.sortedKeys])
        return try JSONSerialization.data(withJSONObject: ["providerId": "quark", "shareId": "share-fixture", "fileId": fileID, "playToken": String(decoding: token, as: UTF8.self)], options: [.sortedKeys]).base64EncodedString()
    }
    func captured() -> [HTTPRequest] { requests }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        func response(_ body: [String: Any], status: Int = 200) throws -> HTTPResponse {
            .init(url: request.url, statusCode: status, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: body))
        }
        if request.url.path.hasSuffix("/init") { return try response([:], status: 404) }
        if request.url.path == "/website/api/status" {
            if statusUnavailable { return try response([:], status: 404) }
            return try response(["code": 0, "data": ["providers": ["quark": ["configured": true, "login": loggedIn], "baidu": ["configured": true, "login": false]]]])
        }
        if request.url.path.hasSuffix("/search") {
            return try response(["list": [["vod_id": "video", "vod_name": "历史影片"]]])
        }
        if request.url.path.hasSuffix("/detail") {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("expired") { return try response(["error": "detail unavailable"], status: 404) }
            let entry = "第64集$\(try Self.episode(tokenVersion, fileID: fileID))"
            var detail = ["vod_name": "历史影片", "vod_play_from": "夸克原画", "vod_play_url": duplicateEpisode ? "\(entry)#\(entry)" : entry]
            if !omitsDetailID { detail["vod_id"] = "video" }
            return try response(["list": [detail]])
        }
        if request.url.path.hasSuffix("/play") {
            if explicitFileTokenFailure { return try response(["error": "夸克转存文件token校验异常"], status: 500) }
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            let id = body?["id"] as? String ?? ""
            let token = Data(base64Encoded: id).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["playToken"] as? String ?? ""
            // A partial stoken-only reconstruction fails even with a valid account.
            if misreportsCookieFailure || !token.contains("file-token-\(tokenVersion)") {
                return try response(["error": "夸克 Cookie 已失效，请重新登录"], status: 500)
            }
            return try response(["parse": 0, "url": "https://media.example.invalid/movie.m3u8"])
        }
        return try response([:], status: 404)
    }
}

@MainActor
final class HistorySelectionInteractionTests: XCTestCase {
    @MainActor private final class Fixture {
        var selection = Set<String>()
        var rows = (0..<4).map { NativeLibraryRow(id: "\($0)", title: "History \($0)", subtitle: "Line", posterURL: nil, date: Date(), progress: 0.1) }
        var opened: [String] = []
        var deleted = Set<String>()
        func view() -> NativeLibraryList {
            NativeLibraryList(rows: rows, selection: Binding(get: { self.selection }, set: { self.selection = $0 }), repository: nil,
                openTitle: "Play", onOpen: { self.opened.append($0) }, onDelete: { ids, _ in self.deleted = ids })
        }
    }
    private func fixture() async throws -> (Fixture, NSHostingView<NativeLibraryList>, NSWindow, NativeLibraryTableView) {
        let model = Fixture(), window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: model.view())
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
        XCTAssertTrue(window.isKeyWindow)
        return (model, host, window, table)
    }
    private func refresh(_ model: Fixture, _ host: NSHostingView<NativeLibraryList>) {
        host.rootView = model.view(); host.layoutSubtreeIfNeeded()
    }
    private func click(_ table: NativeLibraryTableView, row: Int, count: Int = 1,
                       modifiers: NSEvent.ModifierFlags = [], hold: Double = 0.12, during: (() -> Void)? = nil) throws {
        let window = try XCTUnwrap(table.window)
        let point = table.convert(NSPoint(x: 220, y: table.rect(ofRow: row).midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers,
            timestamp: timestamp + hold, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0))
        var refreshed = false
        let update = Timer(timeInterval: 0.02, repeats: false) { _ in
            MainActor.assumeIsolated { refreshed = true; during?() }
        }
        let postRelease: @MainActor () -> Void = { NSApp.postEvent(up, atStart: true) }
        let release = Timer(timeInterval: hold, repeats: false) { _ in
            MainActor.assumeIsolated { postRelease() }
        }
        RunLoop.main.add(update, forMode: .eventTracking); RunLoop.main.add(release, forMode: .eventTracking)
        defer { update.invalidate(); release.invalidate() }
        table.mouseDown(with: down)
        XCTAssertTrue(refreshed, "The update must run inside AppKit's native mouse tracking loop")
    }
    func testSingleClickSurvivesProgressRefreshBeforeMouseUp() async throws {
        let (model, host, window, table) = try await fixture(); defer { window.close() }
        for hold in [0.06, 0.12, 0.3] {
            for initial: Set<String> in [[], ["0"]] {
                model.selection = initial; refresh(model, host)
                try click(table, row: 2, hold: hold) {
                    XCTAssertEqual(table.selectedRow, 2)
                    model.rows[0].progress = 0.8
                    self.refresh(model, host)
                    XCTAssertEqual(table.selectedRow, 2)
                }
                XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 2))
                XCTAssertEqual(model.selection, ["2"])
                XCTAssertTrue(model.opened.isEmpty, "Single click only selects")
            }
        }
    }
    func testReorderingDuringClickPreservesTheClickedRecord() async throws {
        let (model, host, window, table) = try await fixture(); defer { window.close() }
        try click(table, row: 1) {
            model.rows.swapAt(1, 3); self.refresh(model, host)
            let displayed = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NativeLibraryCell
            XCTAssertEqual(displayed?.title.stringValue, "History 1", "Reordering waits for mouse-up")
        }
        XCTAssertEqual(table.selectedRow, 3)
        XCTAssertEqual(model.selection, ["1"])
        XCTAssertTrue(model.opened.isEmpty)
    }
    func testDeletionDuringClickCannotLeaveAnInvalidSelection() async throws {
        let (model, host, window, table) = try await fixture(); defer { window.close() }
        try click(table, row: 1) {
            model.rows.remove(at: 1); self.refresh(model, host)
            XCTAssertEqual(table.numberOfRows, 4)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }
    func testNativeMultipleSelectionDoubleClickAndButtonsRemainIndependent() async throws {
        let (model, host, window, table) = try await fixture(); defer { window.close() }
        try click(table, row: 0); refresh(model, host)
        try click(table, row: 2, modifiers: .command) { model.rows[0].progress = 0.5; self.refresh(model, host) }
        XCTAssertEqual(model.selection, ["0", "2"])
        refresh(model, host)
        try click(table, row: 1, modifiers: .shift) { self.refresh(model, host) }
        XCTAssertTrue(model.selection.contains("1")); XCTAssertGreaterThan(model.selection.count, 1)
        XCTAssertTrue(model.opened.isEmpty)
        // Test an ordinary double-click separately from the modifier
        // gesture. The existing open command requires one selected row.
        model.selection = []; refresh(model, host)
        try click(table, row: 1) { self.refresh(model, host) }
        try click(table, row: 1, count: 2) { model.rows[0].progress = 0.6; self.refresh(model, host) }
        XCTAssertEqual(model.selection, ["1"])
        XCTAssertEqual(model.opened, ["1"])
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 3, makeIfNecessary: true) as? NativeLibraryCell)
        cell.open.performClick(nil); XCTAssertEqual(model.opened, ["1", "3"])
        cell.remove.performClick(nil); XCTAssertEqual(model.deleted, ["3"])
        XCTAssertEqual(model.opened, ["1", "3"])
    }
    func testExternalSelectAllAndKeyboardSelectionAreStillApplied() async throws {
        let (model, host, window, table) = try await fixture(); defer { window.close() }
        model.selection = Set(model.rows.map(\.id)); refresh(model, host)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(0..<4))
        model.selection = ["1"]; refresh(model, host)
        window.makeFirstResponder(table)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down); XCTAssertEqual(model.selection, ["2"])
        refresh(model, host); XCTAssertEqual(table.selectedRow, 2)
        model.selection = []; refresh(model, host); XCTAssertTrue(table.selectedRowIndexes.isEmpty)
    }
}

@MainActor
final class DetailPlaybackRetentionTests: XCTestCase {
    private struct Provider: SiteProvider {
        var mediaURL: URL? = nil
        let site = SiteConfiguration(key: "detail-retention", name: "Fixture", type: 1, api: "https://example.invalid/api")
        let capability = SiteCapability.standardJSON
        func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
        func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage {
            VideoPage(items: [], pagination: Pagination(page: page, pageCount: 1))
        }
        func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage {
            VideoPage(items: [], pagination: Pagination(page: page, pageCount: 1))
        }
        func detail(id: String) async throws -> VideoDetail {
            if id == "delayed" { try await Task.sleep(nanoseconds: 150_000_000) }
            let episodes = (1...80).map { PlayEpisode(name: "Episode \($0)", url: "https://example.invalid/\(id)/\($0).mp4") }
            return VideoDetail(summary: VideoSummary(siteKey: site.key, siteName: site.name, videoID: id, title: "Detail \(id)"),
                playSources: [PlaySource(name: "Line A", episodes: episodes), PlaySource(name: "Line B", episodes: episodes)])
        }
        func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
            if let mediaURL {
                return SitePlaybackResult(url: mediaURL.absoluteString, needsParsing: false, flag: flag, validationPolicy: .playerAuthoritative)
            }
            throw AppError.playback("Intentional fixture resolution failure")
        }
    }
    private func fixture() async throws -> (AppState, AppEnvironment, Provider, VideoDetail) {
        let environment = try AppEnvironment.live(), provider = Provider()
        let state = AppState(environment: environment)
        state.seedCategoryHomeForTesting(record: .init(name: "Fixture", sourceKind: .pasted, rawData: Data("{}".utf8)),
            provider: provider, home: try await provider.home())
        let detail = try await provider.detail(id: "a")
        await state.loadDetail(detail.summary)
        return (state, environment, provider, detail)
    }
    func testPlaybackPreparationFailureAndCloseKeepMountedDetail() async throws {
        let (state, environment, _, detail) = try await fixture()
        let host = NSHostingController(rootView: RootView().environmentObject(state).environmentObject(state.navigation))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        window.makeKeyAndOrderFront(nil); defer { window.close() }
        try await Task.sleep(nanoseconds: 150_000_000); host.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(BrowserKeyboardView.descendants(of: host.view).compactMap { $0 as? NSScrollView }
            .first { $0.documentView?.bounds.height ?? 0 > $0.contentSize.height + 60 })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80)); scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        var prepared = false
        environment.player.transitionSuspensionForTesting = { transition in
            if transition == .prepare { prepared = true; XCTAssertEqual(state.selectedDetail, detail) }
        }
        await state.startPlayback(detail: detail, source: detail.playSources[0], episode: detail.playSources[0].episodes[1])
        XCTAssertTrue(prepared)
        XCTAssertTrue(state.isPlayerPresented)
        XCTAssertEqual(state.selectedDetail, detail); XCTAssertTrue(state.isDetailPagePresented)
        XCTAssertNotNil(state.playbackFailureSummary, "Exercise the actual provider resolution failure")
        try await Task.sleep(nanoseconds: 80_000_000); host.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.isDescendant(of: host.view), "The detail scroll view must not be unmounted")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        await state.closePlayer()
        XCTAssertTrue(state.isDetailPagePresented); XCTAssertEqual(state.selectedDetail, detail)
        state.dismissDetail(); XCTAssertFalse(state.isDetailPagePresented)
        await state.shutdown()
    }
    func testHistoryRequestPreservesDetailAndSidebarNavigationStillDismissesIt() async throws {
        let (state, _, provider, detail) = try await fixture()
        let item = HistoryRecord(configurationID: state.activeConfigurationRecord?.id, siteKey: provider.site.key,
            videoID: "a", title: detail.summary.title, sourceName: "Line A", episodeName: "Episode 1")
        state.requestHistoryPlayback(item)
        XCTAssertTrue(state.isPlayerPresented); XCTAssertEqual(state.selectedDetail, detail)
        await state.closePlayer()
        XCTAssertEqual(state.selectedDetail, detail)
        state.selectSection(.history)
        XCTAssertFalse(state.isDetailPagePresented); XCTAssertEqual(state.selectedSection, .history)
        await state.shutdown()
    }
    func testPlaybackDoesNotCancelAnotherDetailRequest() async throws {
        let (state, _, provider, detail) = try await fixture()
        let summary = VideoSummary(siteKey: provider.site.key, siteName: provider.site.name, videoID: "delayed", title: "Detail delayed")
        let loading = Task { await state.loadDetail(summary) }
        for _ in 0..<50 {
            if state.pendingDetailSummary == summary { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.pendingDetailSummary, summary)
        await state.startPlayback(detail: detail, source: detail.playSources[0], episode: detail.playSources[0].episodes[0])
        await loading.value
        XCTAssertEqual(state.selectedDetail?.summary, summary)
        XCTAssertFalse(state.isRefreshingDetail)
        await state.closePlayer(); await state.shutdown()
    }
    func testSuccessfulPlaybackAndEpisodeSwitchKeepDetailUntilExplicitBack() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OKVIDEO_PIP_FIXTURE"])
        let environment = try AppEnvironment.live(), provider = Provider(mediaURL: URL(fileURLWithPath: path))
        let state = AppState(environment: environment)
        await state.start()
        state.seedCategoryHomeForTesting(record: .init(name: "Detail playback fixture", sourceKind: .pasted, rawData: Data("{}".utf8)),
            provider: provider, home: try await provider.home())
        let detail = try await provider.detail(id: "success")
        await state.loadDetail(detail.summary)
        let controller = PlayerPlaybackWindowController(appState: state)
        let commands = state.$playerWindowCommand.compactMap { $0 }.sink { controller.execute($0) }
        let presentation = state.$isPlayerPresented.removeDuplicates().sink { if !$0 { controller.dismiss() } }
        controller.prewarm()
        let window = try XCTUnwrap(controller.windowForTesting)
        window.setContentSize(.init(width: 960, height: 540))
        // XCTest's async wait does not guarantee an AppKit display cycle.
        // Drive the real view's layout/display; readiness still requires a
        // successful libmpv render probe in the production surface.
        let display = Task { @MainActor in
            while !Task.isCancelled {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if let content = window.contentView {
                    for surface in BrowserKeyboardView.descendants(of: content).compactMap({ $0 as? MPVOpenGLView }) {
                        // The first draw can be consumed before the window
                        // becomes visible. Request a real draw while XCTest
                        // owns the run loop, even if mpv has no video yet.
                        surface.needsDisplay = true
                        surface.displayIfNeeded()
                    }
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
        }
        defer { display.cancel(); commands.cancel(); presentation.cancel(); controller.dismiss() }
        for episode in detail.playSources[0].episodes.prefix(2) {
            let timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                let surfaces = window.contentView.map { BrowserKeyboardView.descendants(of: $0).compactMap { $0 as? MPVOpenGLView } } ?? []
                XCTFail("Local fixture playback timed out: visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) bounds=\(window.contentView?.bounds ?? .zero) surfaces=\(surfaces.map(\.readinessDiagnosticsForTesting))")
                await state.closePlayer()
            }
            await state.startPlayback(detail: detail, source: detail.playSources[0], episode: episode)
            timeout.cancel()
            guard state.playbackResolutionState == .playing else {
                XCTFail(state.playbackFailureSummary ?? "Playback did not start")
                await state.shutdown()
                return
            }
            XCTAssertEqual(state.currentPlaybackEpisode?.id, episode.id)
            XCTAssertEqual(state.selectedDetail, detail)
            XCTAssertTrue(state.isDetailPagePresented)
        }
        await state.closePlayer()
        XCTAssertEqual(state.selectedDetail, detail)
        XCTAssertTrue(state.isDetailPagePresented)
        state.dismissDetail(); XCTAssertFalse(state.isDetailPagePresented)
        await state.shutdown()
    }

}

@MainActor
final class HistorySelectionStateBindingTests: XCTestCase {
    @MainActor private final class Rows: ObservableObject {
        @Published var values = (0..<3).map { NativeLibraryRow(id: "\($0)", title: "Item \($0)", subtitle: "", posterURL: nil, date: Date(), progress: 0.1) }
        var selected = Set<String>()
    }
    private struct Surface: View {
        @ObservedObject var rows: Rows
        @State private var selection = Set<String>()
        var body: some View {
            NativeLibraryList(rows: rows.values, selection: $selection, repository: nil, openTitle: "Play",
                onOpen: { _ in XCTFail("Single click must not play") }, onDelete: { _, _ in })
                .onChange(of: selection) { rows.selected = $0 }
                .onChange(of: rows.values.map(\.id)) { selection.formIntersection($0) }
        }
    }
    func testSwiftUIStateBindingKeepsNativeChoiceAcrossProgressAndRemoval() async throws {
        let model = Rows(), host = NSHostingView(rootView: Surface(rows: Rows()))
        host.rootView = Surface(rows: model)
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
        for removing in [false, true] {
            let index = removing ? 2 : 1
            let point = table.convert(NSPoint(x: 220, y: table.rect(ofRow: index).midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.15,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            var didUpdate = false
            let update = Timer(timeInterval: 0.02, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if removing { model.values.remove(at: 2) } else { model.values[0].progress = 0.8 }
                    host.rootView = Surface(rows: model); host.layoutSubtreeIfNeeded(); didUpdate = true
                    XCTAssertEqual(table.selectedRow, index)
                }
            }
            let postRelease: @MainActor () -> Void = { NSApp.postEvent(up, atStart: true) }
            let release = Timer(timeInterval: 0.15, repeats: false) { _ in MainActor.assumeIsolated { postRelease() } }
            RunLoop.main.add(update, forMode: .eventTracking); RunLoop.main.add(release, forMode: .eventTracking)
            table.mouseDown(with: down)
            update.invalidate(); release.invalidate()
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertTrue(didUpdate)
            XCTAssertEqual(model.selected, removing ? [] : ["1"])
            XCTAssertEqual(table.selectedRowIndexes, removing ? [] : IndexSet(integer: 1))
        }
    }
}
