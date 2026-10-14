import Foundation

/// Technical properties of the selected, loaded media. Display dimensions in
/// PlayerSnapshot remain independent because they also describe aspect overrides.
public struct PlaybackMediaInfo: Equatable, Sendable {
    public let fileName: String?
    public let container: String?
    public let fileSizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let nominalFrameRate: Double?
    public let audioCodec: String?
    public let audioChannels: String?
    public let audioSampleRate: Int?
    public let statistics: PlaybackMediaStatistics?

    /// Read only explicit mpv properties; provider quality labels and display
    /// sizes are never evidence for source resolution, bitrate or frame rate.
    public init(properties: [String: String], includeStatistics: Bool = false,
                isNetwork: Bool = false, includesFileSize: Bool = true) {
        fileName = Self.safeFileName(properties["filename"])
        container = Self.text(properties["file-format"])
        fileSizeBytes = includesFileSize ? Self.positiveInteger(properties["file-size"]) : nil
        width = Self.positiveInt(properties["video-dec-params/w"] ?? properties["video-params/w"])
        height = Self.positiveInt(properties["video-dec-params/h"] ?? properties["video-params/h"])
        videoCodec = Self.text(properties["current-tracks/video/codec"])
        nominalFrameRate = Self.positiveDouble(properties["current-tracks/video/demux-fps"] ?? properties["container-fps"])
        audioCodec = Self.text(properties["current-tracks/audio/codec"])
        audioChannels = Self.text(properties["audio-params/channels"])
            ?? Self.text(properties["current-tracks/audio/demux-channels"])
        audioSampleRate = Self.positiveInt(properties["audio-params/samplerate"])
            ?? Self.positiveInt(properties["current-tracks/audio/demux-samplerate"])
        statistics = includeStatistics ? PlaybackMediaStatistics(properties: properties, isNetwork: isNetwork) : nil
    }

    public var hasSpecifications: Bool {
        (width != nil && height != nil) || videoCodec != nil || audioCodec != nil
    }

    public var withoutStatistics: PlaybackMediaInfo {
        var properties: [String: String] = [:]
        properties["filename"] = fileName
        properties["file-format"] = container
        properties["file-size"] = fileSizeBytes.map { String($0) }
        properties["video-dec-params/w"] = width.map { String($0) }
        properties["video-dec-params/h"] = height.map { String($0) }
        properties["current-tracks/video/codec"] = videoCodec
        properties["container-fps"] = nominalFrameRate.map { String($0) }
        properties["current-tracks/audio/codec"] = audioCodec
        properties["audio-params/channels"] = audioChannels
        properties["audio-params/samplerate"] = audioSampleRate.map { String($0) }
        return PlaybackMediaInfo(properties: properties)
    }

    public static func safeFileName(_ value: String?) -> String? {
        guard let value = text(value) else { return nil }
        // Any qualified stream URL may carry userinfo, including protocols
        // outside HTTP/RTSP. If there is no path basename, expose no filename.
        if value.contains("://") || value.hasPrefix("//") || value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value), !url.lastPathComponent.isEmpty,
                  url.lastPathComponent != "/" else { return nil }
            return safeFileName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        }
        let name = value.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? value
        return text(name.components(separatedBy: CharacterSet(charactersIn: "?#")).first)
    }

    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512,
              clean.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return clean
    }
    static func positiveDouble(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }
    static func positiveInteger(_ value: String?) -> Int64? {
        guard let value, let number = Int64(value), number > 0 else { return nil }
        return number
    }
    static func positiveInt(_ value: String?) -> Int? {
        positiveInteger(value).flatMap(Int.init(exactly:))
    }
    static func nonnegativeInteger(_ value: String?) -> Int64? {
        guard let value, let number = Int64(value), number >= 0 else { return nil }
        return number
    }
}

public struct PlaybackMediaStatistics: Equatable, Sendable {
    public let videoBitrate: Double?
    public let audioBitrate: Double?
    public let measuredFrameRate: Double?
    public let hardwareDecoder: String?
    public let networkBytesPerSecond: Int64?
    public let cacheDuration: Double?
    public let droppedFrames: Int64?

    init(properties: [String: String], isNetwork: Bool) {
        videoBitrate = PlaybackMediaInfo.positiveDouble(properties["video-bitrate"])
        audioBitrate = PlaybackMediaInfo.positiveDouble(properties["audio-bitrate"])
        measuredFrameRate = PlaybackMediaInfo.positiveDouble(properties["estimated-vf-fps"])
        hardwareDecoder = PlaybackMediaInfo.text(properties["hwdec-current"])
        networkBytesPerSecond = isNetwork ? PlaybackMediaInfo.nonnegativeInteger(properties["cache-speed"]) : nil
        cacheDuration = PlaybackMediaInfo.positiveDouble(properties["demuxer-cache-duration"])
        droppedFrames = PlaybackMediaInfo.nonnegativeInteger(properties["frame-drop-count"])
    }
}
