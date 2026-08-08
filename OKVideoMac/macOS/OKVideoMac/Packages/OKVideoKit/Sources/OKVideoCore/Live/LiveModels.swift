import Foundation

public enum LiveSourceFormat: String, Codable {
    case m3u
    case text
    case json
}

public struct LivePlaylist: Equatable {
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

public struct LiveGroup: Codable, Equatable, Identifiable {
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

public struct LiveChannel: Codable, Equatable, Identifiable {
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

public struct LiveStream: Codable, Equatable, Identifiable {
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

public struct EPGChannel: Codable, Equatable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct EPGProgramme: Codable, Equatable, Identifiable {
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

public struct XMLTVGuide: Codable, Equatable {
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
