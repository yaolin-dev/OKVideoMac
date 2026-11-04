import Foundation

public enum SubtitleTextEncoding: String, Codable, CaseIterable, Sendable {
    case automatic, utf8, gb18030, big5
    public var mpvValue: String {
        switch self {
        case .automatic: return "auto"
        case .utf8: return "+utf-8"
        case .gb18030: return "+gb18030"
        case .big5: return "+big5"
        }
    }
}

public enum SubtitleFontStyle: String, Codable, CaseIterable, Sendable {
    case original, compatible
}

public struct PlayerSubtitleSettings: Equatable, Sendable {
    public var trackID: Int?
    public var isExternal = false
    public var codec: String?
    public var encoding: SubtitleTextEncoding = .automatic
    public var fontStyle: SubtitleFontStyle = .original
    public var warning: String?
    public init() {}
    public var isBitmap: Bool {
        ["hdmv_pgs_subtitle", "pgs", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec ?? "")
    }
    public var canChooseEncoding: Bool { trackID != nil && isExternal && !isBitmap }
    public var canChooseFont: Bool { trackID != nil && !isBitmap }
}
