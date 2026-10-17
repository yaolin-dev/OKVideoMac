import Foundation
import OKVideoCore

/// Daily API rows retain their own tokens; XMLTV fallback rows remain one
/// coherent resource snapshot. Both use the established finite work scheduler.
public enum EPGGuideTVBoxLoader {
    public static func load(repository: EPGProductionRepository, demand: EPGGuideDemand,
                            httpClient: HTTPClient, xmltvKey: EPGRequestKey?,
                            xmltvAvailability: EPGAvailability = .fresh,
                            retainedSnapshotCost: Int = 0) async throws -> EPGGuideSnapshot {
        guard demand.capability == .tvboxDay, demand.source.kind == .imported else {
            throw EPGGuideFailure.invalidRequest
        }
        var rows: [String: EPGGuideRow] = [:]
        let api = demand.channels.filter { $0.epgAPI != nil }
        if !api.isEmpty {
            let value = try await loadAPI(repository: repository, demand: subset(demand, channels: api, capability: .tvboxDay),
                                          httpClient: httpClient, retainedSnapshotCost: retainedSnapshotCost)
            for row in value.rows { rows[row.id] = row }
        }
        let xml = demand.channels.filter { $0.epgAPI == nil }
        if !xml.isEmpty, let xmltvKey {
            do {
                let value = try await EPGGuideXMLTVLoader.load(repository: repository, key: xmltvKey,
                    demand: subset(demand, channels: xml, capability: .xmltv), availability: xmltvAvailability,
                    retainedSnapshotCost: rows.values.reduce(0) { $0 + EPGGuideCost.row($1) })
                for row in value.rows { rows[row.id] = row }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                for channel in xml { rows[channel.id] = unavailable(channel, state: .failed(.unavailable)) }
            }
        }
        try Task.checkCancellation()
        return try EPGGuideSnapshot(source: demand.source, revision: demand.revision,
            demandRevision: demand.demandRevision, slices: demand.slices, coherence: .perRowToken,
            rows: demand.channels.map { rows[$0.id] ?? unavailable($0, state: .unsupported) })
    }

    public static func nowNext(repository: EPGProductionRepository, source: LiveSourceID, revision: String,
                               channel: LiveChannel, at date: Date, demandRevision: UUID,
                               httpClient: HTTPClient) async throws -> EPGNowNextBatch {
        let value = try await schedule(repository: repository, source: source, revision: revision,
            channel: channel, from: date, to: date.addingTimeInterval(12 * 3600),
            demandRevision: demandRevision, httpClient: httpClient)
        return EPGNowNextBatch(token: value.token, items: [
            .init(match: .init(kind: .exact, channelID: channel.id),
                  current: value.programmes.first { $0.start <= date && date < $0.end },
                  next: value.programmes.first { $0.start > date })
        ], availability: value.availability)
    }

    public static func nowNextAll(repository: EPGProductionRepository, source: LiveSourceID, revision: String,
                                  channels: [LiveChannel], at date: Date, demandRevision: UUID,
                                  httpClient: HTTPClient) async throws -> [(LiveChannel, EPGNowNextBatch)] {
        let bounded = Array(channels.prefix(EPGGuideLimits.maximumDesiredRows))
        var result: [(LiveChannel, EPGNowNextBatch)] = []
        for start in stride(from: 0, to: bounded.count, by: EPGGuideLimits.maximumRunning) {
            try Task.checkCancellation()
            let values = await withTaskGroup(of: (LiveChannel, EPGNowNextBatch?).self) { group in
                for channel in bounded[start..<min(start + EPGGuideLimits.maximumRunning, bounded.count)] {
                    group.addTask {
                        let value = try? await nowNext(repository: repository, source: source, revision: revision,
                            channel: channel, at: date, demandRevision: demandRevision, httpClient: httpClient)
                        return (channel, value)
                    }
                }
                var values: [(LiveChannel, EPGNowNextBatch)] = []
                for await (channel, value) in group { if let value { values.append((channel, value)) } }
                return values
            }
            result.append(contentsOf: values)
        }
        try Task.checkCancellation()
        return result
    }

    private struct Schedule: Sendable {
        let token: EPGResultToken
        let programmes: [EPGProgramme]
        let availability: EPGAvailability
        let incomplete: Bool
    }
    private static func schedule(repository: EPGProductionRepository, source: LiveSourceID, revision: String,
                                 channel: LiveChannel, from: Date, to: Date, demandRevision: UUID,
                                 httpClient: HTTPClient) async throws -> Schedule {
        guard let configuration = channel.epgAPI else { throw EPGGuideFailure.invalidRequest }
        let days = try TVBoxDayEPG.days(configuration: configuration, from: from, to: to)
        let key = EPGRequestKey(source: source, revision: revision, resource: channel.id)
        var daily: [String: EPGChannelDayResult] = [:], incomplete = false
        for day in days {
            try Task.checkCancellation()
            do {
                let value = try await repository.loadTVBoxDay(key: key, day: day, timeZoneID: configuration.timeZoneID,
                                                             demandRevision: demandRevision) {
                    try await TVBoxDayEPG.fetch(configuration: configuration, day: day,
                                              channelID: channel.id, httpClient: httpClient)
                }
                if value.availability == .unsupported { incomplete = true }
                else { daily[day] = value }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                incomplete = true
            }
        }
        try Task.checkCancellation()
        guard !daily.isEmpty else { throw EPGGuideFailure.unavailable }
        var versions: [String] = [], records: [Date: EPGProgramme] = [:], stale = false
        for day in days {
            guard let value = daily[day] else { versions.append("missing:" + day); continue }
            versions.append(value.token.resourceIdentity + "/" + value.token.dataVersion)
            stale = stale || value.availability == .stale
            for programme in value.programmes { records[programme.start] = programme }
        }
        let token = EPGResultToken(serviceIncarnation: repository.incarnation,
            resourceIdentity: "tvbox:" + EPGRequestKey.revision(for: Data((key.source.kind.rawValue + key.source.id.uuidString + "\u{0}" + channel.id).utf8)),
            sourceEpoch: revision, dataVersion: EPGRequestKey.revision(for: Data(versions.joined(separator: "\u{0}").utf8)),
            demandRevision: demandRevision)
        return Schedule(token: token, programmes: records.values.sorted { $0.start < $1.start },
                        availability: stale ? .stale : (records.isEmpty ? .empty : .fresh), incomplete: incomplete)
    }

    private struct Outcome: Sendable {
        let assignment: EPGGuideWorkAssignment
        let value: Schedule?
        let failure: EPGGuideFailure?
    }
    private static func loadAPI(repository: EPGProductionRepository, demand: EPGGuideDemand,
                                httpClient: HTTPClient, retainedSnapshotCost: Int) async throws -> EPGGuideSnapshot {
        var coordinator = try EPGGuideWorkCoordinator(demand: demand, retainedSnapshotCost: retainedSnapshotCost)
        var records = Array(repeating: [EPGProgrammeRecordIdentity: EPGWindowProgramme](), count: demand.channels.count)
        var tokens = Array<EPGResultToken?>(repeating: nil, count: demand.channels.count)
        var availability = Array(repeating: EPGAvailability.empty, count: demand.channels.count)
        var incomplete = Array(repeating: false, count: demand.channels.count)
        while !coordinator.isFinished {
            try Task.checkCancellation()
            let assignments = coordinator.nextAssignments()
            guard !assignments.isEmpty else { throw EPGGuideFailure.queryBudgetExceeded }
            let outcomes = await withTaskGroup(of: Outcome.self) { group in
                for assignment in assignments {
                    group.addTask {
                        do {
                            let value = try await schedule(repository: repository, source: .imported(demand.source.id),
                                revision: demand.revision, channel: assignment.channel,
                                from: demand.slices[0].start, to: demand.slices.last!.end,
                                demandRevision: demand.demandRevision, httpClient: httpClient)
                            return Outcome(assignment: assignment, value: value, failure: nil)
                        } catch {
                            return Outcome(assignment: assignment, value: nil,
                                           failure: Task.isCancelled ? .cancelled : .unavailable)
                        }
                    }
                }
                var values: [Outcome] = []
                for await value in group { values.append(value) }
                return values.sorted { $0.assignment.id.channelIndex < $1.assignment.id.channelIndex }
            }
            try Task.checkCancellation()
            for outcome in outcomes {
                let assignment = outcome.assignment, index = assignment.id.channelIndex
                guard let value = outcome.value else {
                    try coordinator.fail(assignment.id, outcome.failure ?? .unavailable); continue
                }
                if let old = tokens[index], old != value.token { throw EPGGuideFailure.snapshotChanged }
                tokens[index] = value.token; availability[index] = value.availability
                incomplete[index] = value.incomplete
                let matching = value.programmes.enumerated().filter {
                    $0.element.start < assignment.slice.end && $0.element.end > assignment.slice.start
                }
                let remaining = max(0, EPGGuideLimits.maximumProgrammesPerRow - records[index].count)
                let candidates = matching.compactMap { ordinal, programme -> EPGWindowProgramme? in
                    let id = EPGProgrammeRecordIdentity(kind: .tvboxDay, resourceIdentity: value.token.resourceIdentity,
                        sourceEpoch: value.token.sourceEpoch, dataVersion: value.token.dataVersion, ordinal: ordinal)
                    return records[index][id] == nil ? EPGWindowProgramme(id: id, programme: programme) : nil
                }
                let page = Array(candidates.prefix(remaining))
                let accepted = try coordinator.completePage(assignment.id, acceptedProgrammes: page.count,
                    acceptedBytes: page.reduce(0) { $0 + EPGGuideCost.programme($1) }, hasMore: candidates.count > page.count)
                if accepted { for record in page { records[index][record.id] = record } }
            }
        }
        let rows = demand.channels.indices.map { index in
            let original = coordinator.terminalStates[index]
            let state: EPGGuideRowState = incomplete[index] && (original == .ready || original == .empty)
                ? .truncated(.sourceCoverage) : original
            return EPGGuideRow(channel: .init(demand.channels[index]), token: tokens[index],
                match: .init(kind: .exact, channelID: demand.channels[index].id), availability: availability[index],
                programmes: records[index].values.sorted { $0.start < $1.start }, state: state)
        }
        return try EPGGuideSnapshot(source: demand.source, revision: demand.revision, demandRevision: demand.demandRevision,
                                    slices: demand.slices, coherence: .perRowToken, rows: rows)
    }

    private static func subset(_ demand: EPGGuideDemand, channels: [LiveChannel],
                               capability: EPGGuideCapability) throws -> EPGGuideDemand {
        try .init(source: demand.source, revision: demand.revision, demandRevision: demand.demandRevision,
                  capability: capability, channels: channels, visibleRange: 0..<channels.count,
                  focusedChannelID: demand.focusedChannelID, playingChannelID: demand.playingChannelID, slices: demand.slices)
    }
    private static func unavailable(_ channel: LiveChannel, state: EPGGuideRowState) -> EPGGuideRow {
        .init(channel: .init(channel), token: nil, match: .init(kind: .unmatched, channelID: nil),
              availability: .unsupported, programmes: [], state: state)
    }
}
