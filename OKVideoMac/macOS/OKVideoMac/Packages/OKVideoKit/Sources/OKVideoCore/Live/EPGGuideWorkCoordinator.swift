import Foundation

public struct EPGGuideWorkID: Equatable, Hashable, Sendable {
    public let channelIndex: Int

    public init(channelIndex: Int) { self.channelIndex = channelIndex }
}

public struct EPGGuideWorkAssignment: Equatable, Sendable {
    public let id: EPGGuideWorkID
    public let channel: LiveChannel
    public let slice: EPGGuideTimeSlice
    public let sliceIndex: Int
    public let pageIndex: Int
    public let reservationBytes: Int
    public let availableResultBytes: Int
}

public struct EPGGuideWorkMetrics: Equatable, Sendable {
    public fileprivate(set) var peakRunnable = 0
    public fileprivate(set) var peakRunning = 0
    public fileprivate(set) var startedPages = 0
    public fileprivate(set) var completedRows = 0
}

/// Pure admission state. It never creates Tasks or retains programme payloads;
/// the Repository driver owns cursors and reports only incremental accepted cost.
public struct EPGGuideWorkCoordinator: Sendable {
    private struct Row: Sendable {
        let id: EPGGuideWorkID
        let channel: LiveChannel
        let rank: Int
        var sliceIndex = 0
        var pageIndex = 0
        var programmeCount = 0
        var acceptedCost = 0
        var state: EPGGuideRowState = .loading
        var running = false
        var terminal = false
    }

    public let demandRevision: UUID
    public let capability: EPGGuideCapability
    private let slices: [EPGGuideTimeSlice]
    private var rows: [Row]
    private var runnable: [Int] = []
    private var reservations: [EPGGuideWorkID: Int] = [:]
    private var acceptedProgrammeCount = 0
    private var acceptedCost: Int
    private var retainedCost: Int
    private var droppedRetainedSnapshot = false
    public private(set) var metrics = EPGGuideWorkMetrics()

    public init(demand: EPGGuideDemand, retainedSnapshotCost: Int = 0) throws {
        guard retainedSnapshotCost >= 0,
              retainedSnapshotCost <= EPGGuideLimits.maximumEstimatedBytes else {
            throw EPGGuideValidationError.invalidDemand
        }
        demandRevision = demand.demandRevision
        capability = demand.capability
        slices = demand.slices
        retainedCost = retainedSnapshotCost
        acceptedCost = 256 + demand.revision.utf8.count
            + demand.slices.count * EPGGuideCost.sliceBase
        rows = demand.channels.enumerated().map { index, channel in
            let visible = demand.visibleRange.contains(index)
            let focus = channel.id == demand.focusedChannelID
            let playing = channel.id == demand.playingChannelID
            let rank = focus ? 0 : (playing && visible ? 1 : (visible ? 2 : 3))
            return Row(id: EPGGuideWorkID(channelIndex: index), channel: channel,
                       rank: rank, acceptedCost: EPGGuideCost.rowBase
                        + channel.id.utf8.count + channel.name.utf8.count
                        + (channel.number?.utf8.count ?? 0))
        }
        acceptedCost += rows.reduce(0) { $0 + $1.acceptedCost }
        guard totalCommittedCost <= EPGGuideLimits.maximumEstimatedBytes else {
            throw EPGGuideValidationError.invalidDemand
        }
        refillRunnable()
    }

    public var isFinished: Bool { rows.allSatisfy(\.terminal) && reservations.isEmpty }
    public var terminalStates: [EPGGuideRowState] { rows.map(\.state) }
    public var acceptedEstimatedBytes: Int { acceptedCost }
    public var hasDroppedRetainedSnapshot: Bool { droppedRetainedSnapshot }

    public mutating func nextAssignments() -> [EPGGuideWorkAssignment] {
        refillRunnable()
        var result: [EPGGuideWorkAssignment] = []
        while reservations.count < EPGGuideLimits.maximumRunning, !runnable.isEmpty {
            let index = runnable.removeFirst()
            guard !rows[index].terminal, !rows[index].running else { continue }
            let reservation = capability == .xmltv ? EPGGuideLimits.xmltvReservationBytes
                : (capability == .xtreamShort ? EPGGuideLimits.xtreamReservationBytes : EPGGuideLimits.channelArchiveReservationBytes)
            if totalCommittedCost + reservations.values.reduce(0, +) + reservation
                    > EPGGuideLimits.maximumEstimatedBytes {
                if retainedCost > 0 {
                    retainedCost = 0
                    droppedRetainedSnapshot = true
                    runnable.insert(index, at: 0)
                    continue
                }
                if !reservations.isEmpty {
                    runnable.insert(index, at: 0)
                    break
                }
                rows[index].state = .truncated(.byteBudget)
                rows[index].terminal = true
                metrics.completedRows += 1
                continue
            }
            rows[index].running = true
            reservations[rows[index].id] = reservation
            let available = EPGGuideLimits.maximumEstimatedBytes
                - totalCommittedCost - reservations.values.reduce(0, +) + reservation
            result.append(EPGGuideWorkAssignment(id: rows[index].id,
                channel: rows[index].channel, slice: slices[rows[index].sliceIndex],
                sliceIndex: rows[index].sliceIndex, pageIndex: rows[index].pageIndex,
                reservationBytes: reservation, availableResultBytes: max(0, available)))
            metrics.startedPages += 1
            metrics.peakRunning = max(metrics.peakRunning, reservations.count)
            refillRunnable()
        }
        return result
    }

    @discardableResult
    public mutating func completePage(_ id: EPGGuideWorkID, acceptedProgrammes: Int,
                                      acceptedBytes: Int, hasMore: Bool,
                                      terminalState: EPGGuideRowState? = nil) throws -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].running,
              reservations.removeValue(forKey: id) != nil,
              acceptedProgrammes >= 0, acceptedBytes >= 0 else {
            throw EPGGuideValidationError.invalidResult
        }
        rows[index].running = false
        if let terminalState {
            rows[index].state = terminalState
            rows[index].terminal = true
            metrics.completedRows += 1
            refillRunnable()
            return true
        }
        let rowRemaining = EPGGuideLimits.maximumProgrammesPerRow - rows[index].programmeCount
        let globalRemaining = EPGGuideLimits.maximumProgrammes - acceptedProgrammeCount
        guard acceptedProgrammes <= rowRemaining, acceptedProgrammes <= globalRemaining,
              totalCommittedCost <= EPGGuideLimits.maximumEstimatedBytes - acceptedBytes else {
            rows[index].state = .truncated(acceptedProgrammes > rowRemaining
                ? .perRowLimit : (acceptedProgrammes > globalRemaining ? .globalItemLimit : .byteBudget))
            rows[index].terminal = true
            metrics.completedRows += 1
            refillRunnable()
            return false
        }
        rows[index].programmeCount += acceptedProgrammes
        acceptedProgrammeCount += acceptedProgrammes
        rows[index].acceptedCost += acceptedBytes
        acceptedCost += acceptedBytes
        if rows[index].programmeCount == EPGGuideLimits.maximumProgrammesPerRow, hasMore {
            rows[index].state = .truncated(.perRowLimit)
            rows[index].terminal = true
        } else if acceptedProgrammeCount == EPGGuideLimits.maximumProgrammes, hasMore {
            rows[index].state = .truncated(.globalItemLimit)
            rows[index].terminal = true
        } else if hasMore {
            rows[index].pageIndex += 1
        } else if rows[index].sliceIndex + 1 < slices.count {
            rows[index].sliceIndex += 1
            rows[index].pageIndex = 0
        } else {
            rows[index].state = rows[index].programmeCount == 0 ? .empty : .ready
            rows[index].terminal = true
        }
        if rows[index].terminal { metrics.completedRows += 1 }
        refillRunnable()
        return true
    }

    public mutating func fail(_ id: EPGGuideWorkID, _ failure: EPGGuideFailure) throws {
        try completePage(id, acceptedProgrammes: 0, acceptedBytes: 0,
                         hasMore: false, terminalState: .failed(failure))
    }

    public mutating func cancel() {
        reservations.removeAll()
        runnable.removeAll()
        for index in rows.indices where !rows[index].terminal {
            rows[index].running = false
            rows[index].terminal = true
            rows[index].state = .failed(.cancelled)
        }
        metrics.completedRows = rows.count
    }

    private var totalCommittedCost: Int { retainedCost + acceptedCost }

    private mutating func refillRunnable() {
        guard runnable.count < EPGGuideLimits.maximumRunnable else { return }
        let candidates = rows.indices.filter {
            !rows[$0].terminal && !rows[$0].running && !runnable.contains($0)
        }.sorted {
            if rows[$0].pageIndex != rows[$1].pageIndex {
                return rows[$0].pageIndex < rows[$1].pageIndex
            }
            if rows[$0].rank != rows[$1].rank { return rows[$0].rank < rows[$1].rank }
            return rows[$0].id.channelIndex < rows[$1].id.channelIndex
        }
        for index in candidates.prefix(EPGGuideLimits.maximumRunnable - runnable.count) {
            runnable.append(index)
        }
        metrics.peakRunnable = max(metrics.peakRunnable, runnable.count)
    }
}
