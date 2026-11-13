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

/// Audio intent changes at mouse-tracking frequency. It must not invalidate
/// AppState's browser grids or the complete player overlay on every movement.
@MainActor final class PlayerAudioState: ObservableObject {
    @Published private(set) var preference = PlaybackAudioPreference()
    func update(_ value: PlaybackAudioPreference) {
        guard preference != value else { return }
        preference = value
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
    private var lastSnapshot: PlayerSnapshot
    private struct Activity: Equatable {
        let status: PlayerStatus
        let seeking: Bool
        let buffering: Bool
        let seek: PlayerSeekTransaction?
        let pendingTarget: TimeInterval?
        let hasPosition: Bool
        let presentationRevision: UInt64
        @MainActor init(_ source: PlayerSnapshotState) {
            let value = source.snapshot
            status = value.status; seeking = value.isSeeking; buffering = value.isPausedForCache
            seek = value.seekTransaction; pendingTarget = source.pendingSeekTarget
            hasPosition = value.position > 0
            presentationRevision = source.presentationRevision
        }
    }
    init(source: PlayerSnapshotState) {
        self.source = source
        lastActivity = Activity(source)
        lastSnapshot = source.snapshot
        subscription = source.objectWillChange.sink { [weak self] in self?.schedule() }
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        lastActivity = Activity(source)
        lastSnapshot = source.snapshot
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
            // Volume and mute are observed by the audio controls separately.
            // Their native echoes must not redraw the timeline and menus.
            var previous = self.lastSnapshot
            previous.volume = self.source.snapshot.volume
            previous.isMuted = self.source.snapshot.isMuted
            let playbackChanged = previous != self.source.snapshot
            self.lastSnapshot = self.source.snapshot
            if (self.visible && playbackChanged) || changed { self.objectWillChange.send() }
        }
    }
}
