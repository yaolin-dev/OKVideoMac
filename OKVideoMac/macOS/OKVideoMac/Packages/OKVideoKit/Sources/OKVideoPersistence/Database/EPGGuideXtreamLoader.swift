import Foundation
import OKVideoCore

/// Credential-free production context for one Xtream Guide demand. Runtime
/// credentials remain inside the fetch closure and never enter a snapshot.
public struct EPGGuideXtreamContext: Equatable, Sendable {
    public let accountIdentity: String
    public let serverIdentity: String
    public let configurationRevision: String
    public let streamIDByChannelID: [String: String]

    public init(accountIdentity: String, serverIdentity: String,
                configurationRevision: String,
                streamIDByChannelID: [String: String]) {
        self.accountIdentity = accountIdentity
        self.serverIdentity = serverIdentity
        self.configurationRevision = configurationRevision
        self.streamIDByChannelID = streamIDByChannelID
    }
}

/// Projects channel-scoped Xtream short EPG entries through the same bounded
/// Guide coordinator used by XMLTV. Each row keeps its own cache token; no
/// source-wide generation is invented for an API that does not provide one.
public enum EPGGuideXtreamLoader {
    public typealias Fetch = @Sendable (_ streamID: String) async throws -> EPGPayload

    public static func load(
        repository: EPGProductionRepository,
        demand: EPGGuideDemand,
        context: EPGGuideXtreamContext,
        retainedSnapshotCost: Int = 0,
        archive: Bool = false,
        fetch: @escaping Fetch
    ) async throws -> EPGGuideSnapshot {
        guard demand.capability == (archive ? .xtreamArchive : .xtreamShort),
              demand.source.kind == .xtream,
              !context.accountIdentity.isEmpty,
              !context.serverIdentity.isEmpty,
              !context.configurationRevision.isEmpty else {
            throw EPGGuideFailure.invalidRequest
        }

        var restartCount = 0
        while true {
            do {
                return try await loadAttempt(
                    repository: repository,
                    demand: demand,
                    context: context,
                    retainedSnapshotCost: retainedSnapshotCost,
                    archive: archive, fetch: fetch
                )
            } catch AttemptError.rowSnapshotChanged {
                guard restartCount == 0 else { throw EPGGuideFailure.snapshotChanged }
                restartCount = 1
            } catch let failure as EPGGuideFailure {
                throw failure
            } catch is CancellationError {
                throw EPGGuideFailure.cancelled
            } catch {
                throw EPGGuideFailure.unavailable
            }
        }
    }

    private enum AttemptError: Error { case rowSnapshotChanged }

    private struct RowAssembly: Sendable {
        var token: EPGResultToken?
        var match = EPGChannelMatch(kind: .unmatched, channelID: nil)
        var availability: EPGAvailability = .unsupported
        var records: [EPGProgrammeRecordIdentity: EPGWindowProgramme] = [:]
    }

    private enum QueryResult: Sendable {
        case value(EPGXtreamWindowResult)
        case unsupported
        case failure(EPGGuideFailure)
    }

    private struct QueryOutcome: Sendable {
        let assignment: EPGGuideWorkAssignment
        let result: QueryResult
    }

    private static func loadAttempt(
        repository: EPGProductionRepository,
        demand: EPGGuideDemand,
        context: EPGGuideXtreamContext,
        retainedSnapshotCost: Int,
        archive: Bool,
        fetch: @escaping Fetch
    ) async throws -> EPGGuideSnapshot {
        var coordinator = try EPGGuideWorkCoordinator(
            demand: demand,
            retainedSnapshotCost: retainedSnapshotCost
        )
        var rows = Array(repeating: RowAssembly(), count: demand.channels.count)

        while !coordinator.isFinished {
            try Task.checkCancellation()
            let assignments = coordinator.nextAssignments()
            guard !assignments.isEmpty else {
                throw EPGGuideFailure.queryBudgetExceeded
            }

            let outcomes = await withTaskGroup(of: QueryOutcome.self) { group in
                for assignment in assignments {
                    guard let streamID = context.streamIDByChannelID[assignment.channel.id] else {
                        group.addTask {
                            QueryOutcome(assignment: assignment, result: .unsupported)
                        }
                        continue
                    }
                    group.addTask {
                        do {
                            let key = EPGRequestKey(
                                source: .xtream(demand.source.id),
                                revision: demand.revision,
                                resource: streamID
                            )
                            let value = try await repository.loadXtreamWindow(
                                key: key,
                                accountIdentity: context.accountIdentity,
                                serverIdentity: context.serverIdentity,
                                configurationRevision: context.configurationRevision,
                                from: assignment.slice.start,
                                to: assignment.slice.end,
                                demandRevision: demand.demandRevision, archive: archive,
                                fetch: { try await fetch(streamID) }
                            )
                            try Task.checkCancellation()
                            return QueryOutcome(assignment: assignment, result: .value(value))
                        } catch {
                            return QueryOutcome(
                                assignment: assignment,
                                result: .failure(map(error))
                            )
                        }
                    }
                }
                var values: [QueryOutcome] = []
                for await value in group { values.append(value) }
                return values.sorted {
                    $0.assignment.id.channelIndex < $1.assignment.id.channelIndex
                }
            }

            try Task.checkCancellation()
            for outcome in outcomes {
                let assignment = outcome.assignment
                let rowIndex = assignment.id.channelIndex
                switch outcome.result {
                case .unsupported:
                    try coordinator.completePage(
                        assignment.id,
                        acceptedProgrammes: 0,
                        acceptedBytes: 0,
                        hasMore: false,
                        terminalState: .unsupported
                    )
                case .failure(let failure):
                    try coordinator.fail(assignment.id, failure)
                case .value(let value):
                    var assembly = rows[rowIndex]
                    if let existing = assembly.token, existing != value.page.token {
                        throw AttemptError.rowSnapshotChanged
                    }
                    assembly.token = value.page.token
                    assembly.match = value.page.match
                    assembly.availability = value.availability
                    if value.availability == .unsupported {
                        rows[rowIndex] = assembly
                        try coordinator.completePage(
                            assignment.id,
                            acceptedProgrammes: 0,
                            acceptedBytes: 0,
                            hasMore: false,
                            terminalState: .unsupported
                        )
                        continue
                    }

                    var acceptedCount = 0
                    var acceptedBytes = 0
                    for record in value.page.records where assembly.records[record.id] == nil {
                        assembly.records[record.id] = record
                        acceptedCount += 1
                        acceptedBytes += EPGGuideCost.programme(record)
                    }
                    rows[rowIndex] = assembly
                    try coordinator.completePage(
                        assignment.id,
                        acceptedProgrammes: acceptedCount,
                        acceptedBytes: acceptedBytes,
                        hasMore: false
                    )
                }
            }
        }

        let guideRows = zip(demand.channels.indices, coordinator.terminalStates).map { index, state in
            let assembly = rows[index]
            let ordered = assembly.records.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.ordinal < $1.id.ordinal
            }
            let finalState: EPGGuideRowState
            if state == .empty, assembly.availability != .empty {
                // A bounded short guide with entries outside this window does
                // not prove that the requested date has no schedule.
                finalState = .unsupported
            } else {
                finalState = state
            }
            return EPGGuideRow(
                channel: EPGGuideChannel(demand.channels[index]),
                token: assembly.token,
                match: assembly.match,
                availability: assembly.availability,
                programmes: ordered,
                state: finalState
            )
        }
        return try EPGGuideSnapshot(
            source: demand.source,
            revision: demand.revision,
            demandRevision: demand.demandRevision,
            slices: demand.slices,
            coherence: .perRowToken,
            rows: guideRows
        )
    }

    private static func map(_ error: Error) -> EPGGuideFailure {
        if error is CancellationError { return .cancelled }
        guard let error = error as? EPGProductionServiceError else { return .unavailable }
        switch error {
        case .cancelled: return .cancelled
        case .busy: return .busy
        case .invalidRequest: return .invalidRequest
        case .snapshotChanged: return .snapshotChanged
        case .queryBudgetExceeded, .resultTooLarge: return .queryBudgetExceeded
        case .paused, .closed, .noActiveData, .unavailable: return .unavailable
        }
    }
}
