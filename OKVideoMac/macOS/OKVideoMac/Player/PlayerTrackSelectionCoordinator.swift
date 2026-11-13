import Foundation
import OKVideoCore

/// One executing command and one replaceable pending choice per track type.
/// Keep the worker across session changes so a successor cannot overtake it.
@MainActor final class PlayerTrackSelectionCoordinator {
    private struct Request {
        let token: PlaybackTrackSelectionToken
        let execute: (PlaybackTrackSelectionToken) async throws -> Void
        let commit: (PlaybackTrackSelectionToken) async -> Void
        let failed: (Error) -> Void
    }
    private final class Lane {
        var owner: UUID?
        var latest: PlaybackTrackSelectionToken?
        var pending: Request?
        var executing: PlaybackTrackSelectionToken?
        var confirmedID: Int?
        var worker: Task<Void, Never>?
    }
    private var lanes: [MediaTrackType: Lane] = [:]

    func reset(owner: UUID) {
        for lane in lanes.values { reset(lane, owner: owner) }
    }
    private func reset(_ lane: Lane, owner: UUID) {
        lane.latest?.invalidate(); lane.executing?.invalidate()
        lane.pending?.token.invalidate(); lane.pending = nil
        lane.owner = owner; lane.latest = nil; lane.confirmedID = nil
    }
    func hasIntent(owner: UUID, type: MediaTrackType) -> Bool {
        guard let lane = lanes[type], lane.owner == owner else { return false }
        return lane.latest?.isValid == true
    }
    func isPending(owner: UUID, type: MediaTrackType) -> Bool {
        guard let lane = lanes[type], lane.owner == owner else { return false }
        return lane.pending != nil || lane.executing?.requestID == owner
    }
    func desiredID(owner: UUID, type: MediaTrackType) -> Int? {
        guard let lane = lanes[type], lane.owner == owner, lane.latest?.isValid == true else { return nil }
        return lane.latest?.trackID
    }

    @discardableResult
    func submit(owner: UUID, type: MediaTrackType, trackID: Int?, confirmedID: Int?,
                execute: @escaping (PlaybackTrackSelectionToken) async throws -> Void,
                commit: @escaping (PlaybackTrackSelectionToken) async -> Void,
                failed: @escaping (Error) -> Void) -> Task<Void, Never> {
        let lane = lanes[type] ?? Lane()
        lanes[type] = lane
        if lane.owner != owner { reset(lane, owner: owner) }
        let busy = isPending(owner: owner, type: type)
        if let trackID, lane.latest?.trackID == trackID, lane.latest?.isValid == true,
           busy || confirmedID == trackID {
            return lane.worker ?? Task {}
        }
        lane.latest?.invalidate()
        lane.pending?.token.invalidate()
        let token = PlaybackTrackSelectionToken(requestID: owner, type: type, trackID: trackID)
        lane.latest = token
        if !busy { lane.confirmedID = confirmedID }
        lane.pending = Request(token: token, execute: execute, commit: commit, failed: failed)
        if let worker = lane.worker { return worker }
        let worker = Task { @MainActor in
            while let request = lane.pending {
                lane.pending = nil
                let token = request.token
                lane.executing = token
                do {
                    try token.checkValidity()
                    // Unknown targets (e.g. newly loaded subtitles) must execute.
                    if token.trackID == nil || lane.confirmedID != token.trackID {
                        try await request.execute(token)
                    }
                    if lane.owner == token.requestID {
                        // Even a superseded command may already have executed.
                        // Record that fact so A -> B -> A restores A correctly.
                        lane.confirmedID = token.trackID
                        if token.isValid { await request.commit(token) }
                    }
                } catch {
                    if lane.owner == token.requestID {
                        lane.confirmedID = nil
                        if token.isValid {
                            request.failed(error)
                            token.invalidate()
                        }
                    }
                }
                lane.executing = nil
            }
            lane.worker = nil
        }
        lane.worker = worker
        return worker
    }
}
