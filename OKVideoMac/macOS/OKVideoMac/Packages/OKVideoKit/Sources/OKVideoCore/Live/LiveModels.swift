import Foundation

public enum LiveSourceFormat: String, Codable, Sendable {
    case m3u
    case text
    case json
}

public struct LivePlaylist: Equatable, Sendable {
    public var format: LiveSourceFormat
    public var groups: [LiveGroup]
    public var epgURL: URL?

    public init(format: LiveSourceFormat, groups: [LiveGroup], epgURL: URL? = nil) {
        self.format = format
        self.groups = groups
        self.epgURL = epgURL
    }

    public func applyingDefaultHeaders(_ headers: [String: String]) -> LivePlaylist {
        guard !headers.isEmpty else { return self }
        var copy = self
        for groupIndex in copy.groups.indices {
            for channelIndex in copy.groups[groupIndex].channels.indices {
                for streamIndex in copy.groups[groupIndex].channels[channelIndex].streams.indices {
                    var merged = headers
                    merged.merge(
                        copy.groups[groupIndex].channels[channelIndex].streams[streamIndex].headers
                    ) { _, streamValue in streamValue }
                    copy.groups[groupIndex].channels[channelIndex].streams[streamIndex].headers = merged
                }
            }
        }
        return copy
    }
}

public struct LiveGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var password: String?
    public var channels: [LiveChannel]

    public init(name: String, password: String? = nil, channels: [LiveChannel] = []) {
        self.name = name
        self.password = password
        self.channels = channels
    }
}

public struct LiveChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(groupName)::\(name)" }
    public var groupName: String
    public var name: String
    public var number: String?
    public var logoURL: URL?
    public var tvgID: String?
    public var tvgName: String?
    public var streams: [LiveStream]

    public init(
        groupName: String,
        name: String,
        number: String? = nil,
        logoURL: URL? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil,
        streams: [LiveStream]
    ) {
        self.groupName = groupName
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.streams = streams
    }
}

public struct LiveStream: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public var name: String
    public var url: URL
    public var headers: [String: String]
    public var format: String?
    public var needsParsing: Bool

    public init(
        name: String,
        url: URL,
        headers: [String: String] = [:],
        format: String? = nil,
        needsParsing: Bool = false
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.format = format
        self.needsParsing = needsParsing
    }
}

public struct EPGChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct EPGProgramme: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(channelID)::\(start.timeIntervalSince1970)::\(title)" }
    public var channelID: String
    public var title: String
    public var start: Date
    public var end: Date

    public init(channelID: String, title: String, start: Date, end: Date) {
        self.channelID = channelID
        self.title = title
        self.start = start
        self.end = end
    }
}

public struct XMLTVGuide: Codable, Equatable, Sendable {
    public var channels: [EPGChannel]
    public var programmes: [EPGProgramme]

    public init(channels: [EPGChannel], programmes: [EPGProgramme]) {
        self.channels = channels
        self.programmes = programmes
    }

    public func currentAndNext(channelID: String, at date: Date) -> (current: EPGProgramme?, next: EPGProgramme?) {
        let sorted = programmes
            .filter { $0.channelID == channelID }
            .sorted { $0.start < $1.start }
        let current = sorted.first { $0.start <= date && date < $0.end }
        let next = sorted.first { $0.start > date }
        return (current, next)
    }

    public func currentAndNext(
        for channel: LiveChannel,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        let candidates = [channel.tvgID, channel.tvgName, channel.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for candidate in candidates {
            if programmes.contains(where: { $0.channelID == candidate }) {
                return currentAndNext(channelID: candidate, at: date)
            }
            if let matched = channels.first(where: {
                $0.displayName.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return currentAndNext(channelID: matched.id, at: date)
            }
        }
        return (nil, nil)
    }
}

/// A read-optimized view of an XMLTV guide.
///
/// Building the index is linearithmic in the size of the guide, while channel
/// lookups avoid repeatedly scanning and sorting the complete programme list.
public struct XMLTVScheduleIndex: Sendable {
    private let programmesByChannelID: [String: [EPGProgramme]]
    private let channelIDByDisplayName: [String: String]

    public init(guide: XMLTVGuide) {
        programmesByChannelID = Dictionary(grouping: guide.programmes, by: \.channelID)
            .mapValues { programmes in
                programmes.sorted { $0.start < $1.start }
            }

        var channelIDs: [String: String] = [:]
        channelIDs.reserveCapacity(guide.channels.count)
        for channel in guide.channels {
            let displayName = Self.normalized(channel.displayName)
            if channelIDs[displayName] == nil {
                channelIDs[displayName] = channel.id
            }
        }
        channelIDByDisplayName = channelIDs
    }

    public func currentAndNext(
        for channel: LiveChannel,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        let candidates = [channel.tvgID, channel.tvgName, channel.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            if let programmes = programmesByChannelID[candidate] {
                return Self.currentAndNext(in: programmes, at: date)
            }
            if let channelID = channelIDByDisplayName[Self.normalized(candidate)],
               let programmes = programmesByChannelID[channelID] {
                return Self.currentAndNext(in: programmes, at: date)
            }
        }
        return (nil, nil)
    }

    private static func currentAndNext(
        in programmes: [EPGProgramme],
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        var lowerBound = 0
        var upperBound = programmes.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if programmes[midpoint].start <= date {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let next = lowerBound < programmes.count ? programmes[lowerBound] : nil
        let current = programmes[..<lowerBound].last { date < $0.end }
        return (current, next)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}

/// Builds the read-optimized XMLTV index on a detached utility task so large
/// guides never sort their programme lists on the app's main actor.
public enum XMLTVScheduleIndexBuilder {
    public static func build(guide: XMLTVGuide) async -> XMLTVScheduleIndex {
        await Task.detached(priority: .utility) {
            XMLTVScheduleIndex(guide: guide)
        }.value
    }
}
