import Foundation

public enum EPGGuideValidationError: Error, Equatable, Sendable {
    case invalidDemand
    case invalidTimeSlice
    case invalidResult
}

public enum EPGGuideCapability: String, Equatable, Sendable {
    case xmltv
    case xtreamShort
    case xtreamArchive
    case tvboxDay
}

public struct EPGGuideTimeSlice: Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) throws {
        let duration = end.timeIntervalSince(start)
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              duration > 0, duration <= 12 * 60 * 60 else {
            throw EPGGuideValidationError.invalidTimeSlice
        }
        self.start = start
        self.end = end
    }
}

public struct EPGGuideChannel: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let number: String?

    public init(_ channel: LiveChannel) {
        id = channel.id
        name = channel.name
        number = channel.number
    }
}

public struct EPGGuideDemand: Sendable {
    public let source: EPGSourceKey
    public let revision: String
    public let demandRevision: UUID
    public let capability: EPGGuideCapability
    public let channels: [LiveChannel]
    public let visibleRange: Range<Int>
    public let focusedChannelID: String?
    public let playingChannelID: String?
    public let slices: [EPGGuideTimeSlice]

    public init(source: EPGSourceKey, revision: String, demandRevision: UUID,
                capability: EPGGuideCapability, channels: [LiveChannel],
                visibleRange: Range<Int>, focusedChannelID: String? = nil,
                playingChannelID: String? = nil,
                slices: [EPGGuideTimeSlice]) throws {
        guard !revision.isEmpty, revision.utf8.count <= 8_192,
              !channels.isEmpty, channels.count <= EPGGuideLimits.maximumDesiredRows,
              !slices.isEmpty, slices.count <= EPGGuideLimits.maximumSlices,
              visibleRange.lowerBound >= 0,
              visibleRange.upperBound <= channels.count,
              visibleRange.lowerBound < visibleRange.upperBound,
              Set(channels.map(\.id)).count == channels.count else {
            throw EPGGuideValidationError.invalidDemand
        }
        if slices.count == 2 {
            guard slices[0].end == slices[1].start else {
                throw EPGGuideValidationError.invalidDemand
            }
        }
        self.source = source
        self.revision = revision
        self.demandRevision = demandRevision
        self.capability = capability
        self.channels = channels
        self.visibleRange = visibleRange
        self.focusedChannelID = focusedChannelID
        self.playingChannelID = playingChannelID
        self.slices = slices
    }
}

public enum EPGGuideTruncationReason: String, Equatable, Sendable {
    case perRowLimit
    case globalItemLimit
    case byteBudget
    case sourceCoverage
}

public enum EPGGuideFailure: String, Error, Equatable, Sendable {
    case cancelled
    case busy
    case invalidRequest
    case snapshotChanged
    case queryBudgetExceeded
    case unavailable
}

public enum EPGGuideRowState: Equatable, Sendable {
    case loading
    case ready
    case empty
    case unmatched
    case ambiguous
    case unsupported
    case failed(EPGGuideFailure)
    case truncated(EPGGuideTruncationReason)
}

public struct EPGGuideRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let channel: EPGGuideChannel
    public let token: EPGResultToken?
    public let match: EPGChannelMatch
    public let availability: EPGAvailability
    public let programmes: [EPGWindowProgramme]
    public let state: EPGGuideRowState

    public init(channel: EPGGuideChannel, token: EPGResultToken?,
                match: EPGChannelMatch, availability: EPGAvailability,
                programmes: [EPGWindowProgramme], state: EPGGuideRowState) {
        id = channel.id
        self.channel = channel
        self.token = token
        self.match = match
        self.availability = availability
        self.programmes = programmes
        self.state = state
    }
}

public enum EPGGuideCoherence: Equatable, Sendable {
    case xmltv(EPGResultToken)
    case perRowToken
}

public enum EPGGuideCoherenceDecision: Equatable, Sendable {
    case accepted
    case restartDemand
    case failed(EPGGuideFailure)
}

/// A demand owns one retry budget. Creating a fresh attempt does not create a
/// fresh budget, so a rapidly changing XMLTV generation cannot spin forever.
public struct EPGGuideCoherenceGate: Sendable {
    public let demandRevision: UUID
    public let capability: EPGGuideCapability
    public private(set) var xmltvToken: EPGResultToken?
    public private(set) var restartCount = 0

    public init(demandRevision: UUID, capability: EPGGuideCapability) {
        self.demandRevision = demandRevision
        self.capability = capability
    }

    public mutating func admit(_ token: EPGResultToken) -> EPGGuideCoherenceDecision {
        guard token.demandRevision == demandRevision else {
            return .failed(.invalidRequest)
        }
        guard capability == .xmltv else { return .accepted }
        guard let existing = xmltvToken else {
            xmltvToken = token
            return .accepted
        }
        guard existing == token else {
            return consumeRestart()
        }
        return .accepted
    }

    public mutating func snapshotChanged() -> EPGGuideCoherenceDecision {
        guard capability == .xmltv else { return .failed(.snapshotChanged) }
        return consumeRestart()
    }

    private mutating func consumeRestart() -> EPGGuideCoherenceDecision {
        guard restartCount == 0 else { return .failed(.snapshotChanged) }
        restartCount = 1
        xmltvToken = nil
        return .restartDemand
    }
}

public struct EPGGuideSnapshot: Equatable, Sendable {
    public let source: EPGSourceKey
    public let revision: String
    public let demandRevision: UUID
    public let slices: [EPGGuideTimeSlice]
    public let coherence: EPGGuideCoherence
    public let rows: [EPGGuideRow]
    public let estimatedByteCost: Int

    public init(source: EPGSourceKey, revision: String, demandRevision: UUID,
                slices: [EPGGuideTimeSlice], coherence: EPGGuideCoherence,
                rows: [EPGGuideRow]) throws {
        guard !rows.isEmpty, rows.count <= EPGGuideLimits.maximumDesiredRows,
              Set(rows.map(\.id)).count == rows.count,
              rows.reduce(0, { $0 + $1.programmes.count }) <= EPGGuideLimits.maximumProgrammes else {
            throw EPGGuideValidationError.invalidResult
        }
        for row in rows {
            guard row.programmes.count <= EPGGuideLimits.maximumProgrammesPerRow,
                  Set(row.programmes.map(\.id)).count == row.programmes.count else {
                throw EPGGuideValidationError.invalidResult
            }
            if let token = row.token {
                guard token.demandRevision == demandRevision,
                      row.programmes.allSatisfy({
                          $0.id.resourceIdentity == token.resourceIdentity
                              && $0.id.sourceEpoch == token.sourceEpoch
                              && $0.id.dataVersion == token.dataVersion
                      }) else { throw EPGGuideValidationError.invalidResult }
            } else if !row.programmes.isEmpty {
                throw EPGGuideValidationError.invalidResult
            }
        }
        switch coherence {
        case .xmltv(let token):
            guard token.demandRevision == demandRevision,
                  rows.allSatisfy({ $0.token == nil || $0.token == token }) else {
                throw EPGGuideValidationError.invalidResult
            }
        case .perRowToken:
            break
        }
        let cost = EPGGuideCost.snapshot(source: source, revision: revision,
                                         slices: slices, coherence: coherence, rows: rows)
        guard cost <= EPGGuideLimits.maximumEstimatedBytes else {
            throw EPGGuideValidationError.invalidResult
        }
        self.source = source
        self.revision = revision
        self.demandRevision = demandRevision
        self.slices = slices
        self.coherence = coherence
        self.rows = rows
        estimatedByteCost = cost
    }
}

public enum EPGGuideLimits {
    public static let maximumDesiredRows = 48
    public static let maximumRunnable = 8
    public static let maximumRunning = 4
    public static let maximumSlices = 2
    public static let pageSize = 64
    public static let maximumProgrammesPerRow = 256
    public static let maximumProgrammes = 6_144
    public static let maximumEstimatedBytes = 8 * 1_024 * 1_024
    public static let xmltvReservationBytes = 2 * 1_024 * 1_024 + 64 * 1_024
    public static let xtreamReservationBytes = 64 * 1_024 + 16 * 1_024
    public static let channelArchiveReservationBytes = 256 * 1_024 + 16 * 1_024
}

public enum EPGGuideCost {
    public static let programmeBase = 128
    public static let rowBase = 256
    public static let tokenBase = 192
    public static let sliceBase = 128
    public static let cursorBase = 256
    public static let taskDescriptorBase = 160
    public static let failureBase = 96

    public static func token(_ value: EPGResultToken) -> Int {
        tokenBase + value.resourceIdentity.utf8.count + value.sourceEpoch.utf8.count
            + value.dataVersion.utf8.count
    }

    public static func programme(_ value: EPGWindowProgramme) -> Int {
        programmeBase + value.id.resourceIdentity.utf8.count + value.id.sourceEpoch.utf8.count
            + value.id.dataVersion.utf8.count + value.channelID.utf8.count + value.title.utf8.count
    }

    public static func row(_ value: EPGGuideRow) -> Int {
        let channelCost = value.channel.id.utf8.count
            + value.channel.name.utf8.count
            + (value.channel.number?.utf8.count ?? 0)
        let matchCost = value.match.channelID?.utf8.count ?? 0
        let tokenCost = value.token.map(Self.token) ?? 0
        let programmeCost = value.programmes.reduce(0) { partial, programme in
            partial + Self.programme(programme)
        }
        let stateCost = isFailure(value.state) ? failureBase : 0
        return rowBase + channelCost + matchCost + tokenCost + programmeCost + stateCost
    }

    public static func snapshot(source: EPGSourceKey, revision: String,
                                slices: [EPGGuideTimeSlice], coherence: EPGGuideCoherence,
                                rows: [EPGGuideRow]) -> Int {
        var result = 256 + revision.utf8.count + slices.count * sliceBase
        if case .xmltv(let token) = coherence { result += self.token(token) }
        return rows.reduce(result) { $0 + row($1) }
    }

    private static func isFailure(_ state: EPGGuideRowState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
