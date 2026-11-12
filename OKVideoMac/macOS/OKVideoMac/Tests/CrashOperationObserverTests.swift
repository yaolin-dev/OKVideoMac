import AppKit
import Combine
import OKCrashDiagnostics
import OKVideoCore
import XCTest
@testable import OKVideoMac

@MainActor
final class CrashOperationObserverTests: XCTestCase {
    func testNavigationAndPlaybackTransitionsAreRecordedWithoutProgressOrContent() {
        let state = AppState(environment: nil)
        var actions: [CrashOperation.Kind] = []
        let observer = CrashOperationObserver(record: { kind, _ in actions.append(kind) }, observeWindows: false)
        observer.observe(state)
        actions.removeAll()
        state.navigation.select(.live)
        state.navigation.select(.live)
        state.playerSnapshotState.update(PlayerSnapshot(status: .playing, position: 1))
        state.playerSnapshotState.update(PlayerSnapshot(status: .playing, position: 2))
        state.playerSnapshotState.update(PlayerSnapshot(status: .paused, position: 2))
        state.playerSnapshotState.update(PlayerSnapshot(status: .failed("PRIVATE https://private.invalid/token")))
        XCTAssertEqual(actions, [.navigationLive, .playbackPlaying, .playbackPaused, .playbackFailed])
        XCTAssertEqual(state.navigation.selectedSection, .live)
        XCTAssertEqual(state.playerSnapshotState.snapshot.status, .failed("PRIVATE https://private.invalid/token"))
        withExtendedLifetime(observer) {}
    }

    func testWindowNotificationRecordsOnlyRoleAndDoesNotChangeWindow() {
        var actions: [(CrashOperation.Kind, CrashOperation.Window)] = []
        var observer: CrashOperationObserver? = CrashOperationObserver { actions.append(($0, $1)) }
        let window = NSWindow(contentRect: NSRect(x: 1, y: 2, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("OKVideoMac.PlayerWindow")
        window.title = "PRIVATE_TITLE"
        let frame = window.frame
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        XCTAssertEqual(actions.last?.0, .windowResizeBegin)
        XCTAssertEqual(actions.last?.1, .player)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.title, "PRIVATE_TITLE")
        observer = nil
        let count = actions.count
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        XCTAssertEqual(actions.count, count)
        withExtendedLifetime(observer) {}
    }
}
