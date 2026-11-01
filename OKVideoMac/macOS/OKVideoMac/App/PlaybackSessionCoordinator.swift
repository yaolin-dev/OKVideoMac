import Foundation
import OKVideoCore
import OKVideoPersistence

/// Owns the lifetime of a playback request independently of SwiftUI presentation.
/// A session may retain its identity across an authorization/quality retry while
/// the current request changes. Never merge these two identities.
@MainActor final class PlaybackSessionCoordinator {
    private(set) var requestID = UUID()
    var sessionID = UUID()
    var active: ActivePlaybackContext?
    var pending: PendingCloudPlayback?
    var resolvingRequests = Set<UUID>()
    var presentedErrorRequestIDs = Set<UUID>()
    var nodeRecoveryTask: Task<Void, Never>?
    var hlsPreparation: (requestID: UUID, task: Task<HLSStartupSelection?, Error>)?

    private var closeID: UUID?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    var isClosing: Bool { closeID != nil }

    /// Retires request-owned work synchronously, before the caller can suspend.
    /// Contexts remain available until AppState captures the outgoing history and
    /// resource leases; request replacement must not silently discard them.
    @discardableResult
    func replaceRequest(with id: UUID) -> Bool {
        guard id != requestID else { return false }
        requestID = id
        nodeRecoveryTask?.cancel()
        nodeRecoveryTask = nil
        hlsPreparation?.task.cancel()
        hlsPreparation = nil
        return true
    }

    func ownsTransition(_ id: UUID) -> Bool {
        requestID == id && sessionID == id
    }

    func finishNodeRecovery(requestID id: UUID) {
        guard requestID == id else { return }
        nodeRecoveryTask = nil
    }

    /// One close operation performs teardown; concurrent callers join it.
    func beginClose() -> UUID? {
        guard closeID == nil else { return nil }
        let id = UUID()
        closeID = id
        return id
    }

    func waitForClose() async {
        guard isClosing else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func finishClose(_ id: UUID) {
        guard closeID == id else { return }
        closeID = nil
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    deinit {
        nodeRecoveryTask?.cancel()
        hlsPreparation?.task.cancel()
    }
}

struct ActivePlaybackContext {
    let configurationID: UUID
    var configurationUpdatedAt: Date? = nil
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var media: ResolvedMedia
    var playbackResult: SitePlaybackResult?
    var providerResourceReference: PlaybackResourceReference?
    var replacedHistoryRecord: HistoryRecord? = nil
    var requestID: UUID? = nil
}

struct PendingCloudPlayback {
    let requestID: UUID
    let configurationID: UUID
    var detail: VideoDetail
    var source: PlaySource
    var episode: PlayEpisode
    var origin: PlaybackRequestOrigin = .direct
    var recoveryCheckpoint: NodePlaybackRecoveryCheckpoint? = nil
}
