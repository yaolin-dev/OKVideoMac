import Foundation

public enum AppError: Error, Equatable, LocalizedError {
    case configuration(String)
    case network(String)
    case decoding(String)
    case site(String)
    case spider(String)
    case javascript(String)
    case parsing(String)
    case playback(String)
    case live(String)
    case database(String)
    case filesystem(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return "配置错误：\(message)"
        case .network(let message): return "网络错误：\(message)"
        case .decoding(let message): return "数据解析错误：\(message)"
        case .site(let message): return "站点错误：\(message)"
        case .spider(let message): return "Spider 错误：\(message)"
        case .javascript(let message): return "JavaScript 错误：\(message)"
        case .parsing(let message): return "播放解析错误：\(message)"
        case .playback(let message): return "播放错误：\(message)"
        case .live(let message): return "直播错误：\(message)"
        case .database(let message): return "数据库错误：\(message)"
        case .filesystem(let message): return "文件错误：\(message)"
        case .unsupported(let message): return "暂不支持：\(message)"
        case .cancelled: return "操作已取消"
        }
    }
}

