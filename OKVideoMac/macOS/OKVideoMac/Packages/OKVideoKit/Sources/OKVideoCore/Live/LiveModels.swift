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
                    guard case .direct = copy.groups[groupIndex].channels[channelIndex].streams[streamIndex].target else {
                        continue
                    }
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
    public var id: String { explicitID ?? name }
    public var explicitID: String?
    public var name: String
    public var password: String?
    public var channels: [LiveChannel]

    public init(
        name: String,
        password: String? = nil,
        channels: [LiveChannel] = [],
        explicitID: String? = nil
    ) {
        self.explicitID = explicitID
        self.name = name
        self.password = password
        self.channels = channels
    }
}

public struct LiveChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: String { explicitID ?? "\(groupName)::\(name)" }
    public var groupID: String { explicitGroupID ?? groupName }
    public var explicitID: String?
    public var explicitGroupID: String?
    public var groupName: String
    public var name: String
    public var number: String?
    public var logoURL: URL?
    public var tvgID: String?
    public var tvgName: String?
    public var streams: [LiveStream]
    public var epgAPI: TVBoxEPGConfiguration?

    public init(
        groupName: String,
        name: String,
        number: String? = nil,
        logoURL: URL? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil,
        streams: [LiveStream],
        epgAPI: TVBoxEPGConfiguration? = nil,
        explicitID: String? = nil,
        explicitGroupID: String? = nil
    ) {
        self.explicitID = explicitID
        self.explicitGroupID = explicitGroupID
        self.groupName = groupName
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.streams = streams
        self.epgAPI = epgAPI
    }
}

public enum LiveStreamTarget: Equatable, Sendable {
    case direct(URL)
    case provider(PlaybackResourceReference)
}

public struct LiveStream: Codable, Equatable, Identifiable, Sendable {
    public var id: String {
        switch target {
        case .direct(let url): return url.absoluteString
        case .provider(let reference):
            return reference.xtreamLiveLocator?.encoded ?? "invalid-provider-live-target"
        }
    }
    public var name: String
    public var target: LiveStreamTarget
    public var url: URL? {
        guard case .direct(let url) = target else { return nil }
        return url
    }
    public var headers: [String: String]
    public var format: String?
    public var needsParsing: Bool
    public var catchup: LiveCatchupConfiguration?
    public var archive: XtreamArchiveCapability?

    public init(
        name: String,
        url: URL,
        headers: [String: String] = [:],
        format: String? = nil,
        needsParsing: Bool = false,
        catchup: LiveCatchupConfiguration? = nil,
        archive: XtreamArchiveCapability? = nil
    ) {
        self.name = name
        self.target = .direct(url)
        self.headers = headers
        self.format = format
        self.needsParsing = needsParsing
        self.catchup = catchup
        self.archive = archive
    }

    public init(
        name: String,
        target: LiveStreamTarget,
        headers: [String: String] = [:],
        format: String? = nil,
        needsParsing: Bool = false,
        catchup: LiveCatchupConfiguration? = nil,
        archive: XtreamArchiveCapability? = nil
    ) throws {
        self.name = name
        self.target = target
        self.headers = headers
        self.format = format
        self.needsParsing = needsParsing
        self.catchup = catchup
        self.archive = archive
        try validateProviderTarget()
    }

    /// FongMi's standard IPTV fallback is structural, never based on a source
    /// or channel name. Explicit configuration (including disabled) wins.
    public var effectiveCatchup: LiveCatchupConfiguration? {
        if let catchup { return catchup }
        guard let url, url.path.contains("/PLTV/"),
              ["http", "https", "rtsp"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: "/PLTV/", with: "/TVOD/")
        guard let archive = components.url else { return nil }
        let separator = archive.query == nil ? "?" : "&"
        return LiveCatchupConfiguration(mode: "default",
            template: archive.absoluteString + separator + "playseek={utc:YmdHMS}-{utcend:YmdHMS}",
            retentionDays: 7, timeZoneID: TimeZone.current.identifier, seekPolicy: .request)
    }

    public var catchupSeekPolicy: LiveCatchupSeekPolicy? {
        if case .provider = target, archive?.isValid == true { return .request }
        return effectiveCatchup?.seekPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, headers, format, needsParsing, catchup, archive
        case targetVersion, providerResourceReference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        catchup = try container.decodeIfPresent(LiveCatchupConfiguration.self, forKey: .catchup)
        archive = try container.decodeIfPresent(XtreamArchiveCapability.self, forKey: .archive)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        if container.contains(.targetVersion) || container.contains(.providerResourceReference) {
            guard !container.contains(.url),
                  try container.decode(Int.self, forKey: .targetVersion) == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .targetVersion, in: container,
                    debugDescription: "Unsupported or ambiguous Live stream target"
                )
            }
            target = .provider(try container.decode(
                PlaybackResourceReference.self, forKey: .providerResourceReference
            ))
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            needsParsing = try container.decodeIfPresent(Bool.self, forKey: .needsParsing) ?? false
            try validateProviderTarget()
        } else {
            target = .direct(try container.decode(URL.self, forKey: .url))
            headers = try container.decode([String: String].self, forKey: .headers)
            needsParsing = try container.decode(Bool.self, forKey: .needsParsing)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validateProviderTarget()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(catchup, forKey: .catchup)
        try container.encodeIfPresent(archive, forKey: .archive)
        try container.encodeIfPresent(format, forKey: .format)
        switch target {
        case .direct(let url):
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
            try container.encode(needsParsing, forKey: .needsParsing)
        case .provider(let reference):
            try container.encode(1, forKey: .targetVersion)
            try container.encode(reference, forKey: .providerResourceReference)
        }
    }

    private func validateProviderTarget() throws {
        guard case .provider(let reference) = target else { return }
        guard let locator = reference.xtreamLiveLocator,
              headers.isEmpty, !needsParsing, catchup == nil,
              (format == nil || format == locator.outputFormat.rawValue),
              archive?.isValid ?? true else {
            throw LiveModelError.invalidProviderTarget
        }
    }
}

public struct EPGChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var aliases: [String]?

    public init(id: String, displayName: String, aliases: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
    }
}

public struct EPGProgramme: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(channelID)::\(start.timeIntervalSince1970)::\(title)" }
    public var channelID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var catchupAvailable: Bool?

    public init(channelID: String, title: String, start: Date, end: Date, catchupAvailable: Bool? = nil) {
        self.channelID = channelID
        self.title = title
        self.start = start
        self.end = end
        self.catchupAvailable = catchupAvailable
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
        XMLTVScheduleIndex(guide: self).currentAndNext(for: channel, at: date)
    }
}

/// A read-optimized view of an XMLTV guide.
///
/// Building the index is linearithmic in the size of the guide, while channel
/// lookups avoid repeatedly scanning and sorting the complete programme list.
public struct XMLTVScheduleIndex: Sendable {
    private let programmesByChannelID: [String: [EPGProgramme]]
    private let matcher: XMLTVChannelMatcher

    public init(guide: XMLTVGuide) {
        programmesByChannelID = Dictionary(grouping: guide.programmes, by: \.channelID)
            .mapValues { $0.sorted { $0.start < $1.start } }
        matcher = XMLTVChannelMatcher(guide: guide)
    }

    public func channelMatch(for channel: LiveChannel) -> EPGChannelMatch { matcher.match(channel) }

    public func currentAndNext(
        for channel: LiveChannel,
        at date: Date
    ) -> (current: EPGProgramme?, next: EPGProgramme?) {
        guard let id = matcher.match(channel).channelID,
              let programmes = programmesByChannelID[id] else { return (nil, nil) }
        return Self.currentAndNext(in: programmes, at: date)
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
