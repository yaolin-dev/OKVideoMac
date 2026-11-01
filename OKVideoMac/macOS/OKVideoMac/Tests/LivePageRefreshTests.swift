import AppKit
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor final class LivePageRefreshTests: XCTestCase {
    private func fixture() throws -> (AppState, LiveBrowserSession, LiveSourceDescriptor, [LiveChannel]) {
        let state = AppState(environment: nil)
        let source = StoredLiveSource(name: "Refresh fixture", sourceKind: .pasted, rawData: Data())
        let channels = (0..<4).map { index in
            LiveChannel(groupName: index < 2 ? "A" : "B", name: "Channel \(index)", streams: [
                LiveStream(name: "Main", url: URL(string: "https://example.invalid/\(index)")!)])
        }
        state.acceptImportedRoutesForTesting(source, playlist: .init(format: .m3u, groups: [
            .init(name: "A", channels: Array(channels.prefix(2))),
            .init(name: "B", channels: [channels[2]]),
            .init(name: "Locked", password: "fixture", channels: [channels[3]])]))
        let descriptor = try XCTUnwrap(state.liveSourceDescriptors.first { $0.id == .imported(source.id) })
        let session = LiveBrowserSession(preferences: .init(storageKey: "LivePageRefresh." + UUID().uuidString))
        session.selectedSourceID = descriptor.id; session.activate(owner: UUID()); session.showsPreviewImages = true
        // A mounted channel page owns the capture gate. Keep this fixture paused
        // so the test does not depend on which app is currently frontmost.
        state.livePreviews.update(owner: session.previewOwner, demands: [], mayCapture: { false })
        session.connectPreviewService(state.livePreviews)
        return (state, session, descriptor, channels)
    }

    func testRefreshUsesExistingCatalogAndAllUnlockedChannelsDespiteFilters() async throws {
        let (state, session, source, channels) = try fixture()
        defer { state.livePreviews.clear(owner: session.previewOwner) }
        let catalog = state.acceptedImportedCatalogs.values.first
        let automatic = session.automaticallyRefreshPreviews
        session.searchText = "no matches"; session.showsFavoritesOnly = true; session.selectedGroupID = "A"
        session.refresh(source: source, state: state)
        XCTAssertEqual(state.livePreviews.activity.presentation?.total, channels.count - 1)
        // Disk restoration is allowed before the paused capture state settles.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state.livePreviews.activity.presentation?.phase, .paused)
        XCTAssertTrue(state.acceptedImportedCatalogs.values.first === catalog)
        XCTAssertFalse(state.isLiveCatalogLoading(source.id))
        XCTAssertNil(session.refreshingPageSourceID)
        XCTAssertEqual(session.guideRefreshRequest, 0)
        XCTAssertEqual(session.automaticallyRefreshPreviews, automatic)
        XCTAssertFalse(source.canRefresh, "A pasted source still supports picture refresh")
        session.refresh(source: source, state: state)
        XCTAssertEqual(state.livePreviews.activity.presentation?.total, 3)
    }

    func testLogosAndGuideDoNotQueuePictureRefresh() throws {
        let (state, session, source, _) = try fixture()
        defer { state.livePreviews.clear(owner: session.previewOwner) }
        session.showsPreviewImages = false
        session.refresh(source: source, state: state)
        XCTAssertFalse(state.livePreviews.refreshing)
        session.showsPreviewImages = true; session.showsGuide = true
        session.refresh(source: source, state: state)
        XCTAssertEqual(session.guideRefreshRequest, 1)
        XCTAssertFalse(state.livePreviews.refreshing)
    }

    func testSourceChangeClearsPreviousSourceRoundImmediately() throws {
        let (state, session, source, _) = try fixture()
        session.refresh(source: source, state: state)
        XCTAssertTrue(state.livePreviews.refreshing)
        session.selectedSourceID = .imported(UUID())
        XCTAssertFalse(state.livePreviews.refreshing)
        XCTAssertNil(state.livePreviews.activity.presentation)
        session.refresh(source: source, state: state)
        XCTAssertNil(state.livePreviews.activity.presentation)
    }

    func testLeavingLivePausesRoundWithoutDiscardingIt() async throws {
        let (state, session, source, _) = try fixture()
        defer { state.livePreviews.clear(owner: session.previewOwner) }
        let owner = UUID(); session.activate(owner: owner)
        session.refresh(source: source, state: state)
        XCTAssertTrue(session.deactivate(owner: owner))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(state.livePreviews.activity.presentation?.phase, .paused)
        XCTAssertEqual(state.livePreviews.activity.presentation?.total, 3)
        XCTAssertTrue(state.livePreviews.refreshing)
    }

    func testMissingCatalogLoadCoalescesAndFailureDoesNotLeaveSpinner() async throws {
        let (_, session, source, _) = try fixture()
        var finish: CheckedContinuation<Void, Never>?
        var downloads = 0
        session.refreshChannelPage(sourceID: source.id) {
            downloads += 1
            await withCheckedContinuation { finish = $0 }
            return false
        }
        session.refreshChannelPage(sourceID: source.id) { downloads += 1; return true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(session.refreshingPageSourceID, source.id)
        session.selectedSourceID = .imported(UUID())
        finish?.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(session.refreshingPageSourceID)
    }
}
