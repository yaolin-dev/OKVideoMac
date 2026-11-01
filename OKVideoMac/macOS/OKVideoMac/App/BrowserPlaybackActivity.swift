import AppKit
import Combine
import OKVideoCore
import SwiftUI

private struct BrowserSurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var browserSurfaceVisible: Bool {
        get { self[BrowserSurfaceVisibleKey.self] }
        set { self[BrowserSurfaceVisibleKey.self] = newValue }
    }
}

enum BrowserPlaybackActivityPolicy {
    static func surfaceVisible(attached: Bool, visible: Bool, miniaturized: Bool, occluded: Bool) -> Bool {
        attached && visible && !miniaturized && !occluded
    }
    static func defersBulkRefresh(playerPresented: Bool, snapshot: PlayerSnapshot) -> Bool {
        playerPresented && (snapshot.status == .loading || snapshot.status == .buffering
            || snapshot.isSeeking || snapshot.isPausedForCache)
    }
}

/// The control overlay needs timeline ticks only while visible. Hidden controls
/// still wake for buffering, seeks, failure/end and the first advancing position.
/// Defer reads until after @Published's will-change notification has committed.
@MainActor final class PlayerOverlayObservation: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let source: PlayerSnapshotState
    private var subscription: AnyCancellable?
    private var pending = false
    private var visible = true
    private var lastActivity: Activity
    private struct Activity: Equatable {
        let status: PlayerStatus
        let seeking: Bool
        let buffering: Bool
        let seek: PlayerSeekTransaction?
        let pendingTarget: TimeInterval?
        let hasPosition: Bool
        @MainActor init(_ source: PlayerSnapshotState) {
            let value = source.snapshot
            status = value.status; seeking = value.isSeeking; buffering = value.isPausedForCache
            seek = value.seekTransaction; pendingTarget = source.pendingSeekTarget
            hasPosition = value.position > 0
        }
    }
    init(source: PlayerSnapshotState) {
        self.source = source
        lastActivity = Activity(source)
        subscription = source.objectWillChange.sink { [weak self] in self?.schedule() }
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        lastActivity = Activity(source)
        if value { objectWillChange.send() }
    }
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let activity = Activity(self.source)
            let changed = activity != self.lastActivity
            self.lastActivity = activity
            if self.visible || changed { self.objectWillChange.send() }
        }
    }
}
