import Foundation

/// No labels, keystrokes, coordinates, URLs, media titles, or stable user identifiers.
public struct CrashOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case launch, bootstrap, ready
        case navigationHome, navigationLive, navigationFavorites, navigationHistory, navigationSettings
        case detailRequested, detailPresented, detailClosed, searchStarted, searchFinished
        case playbackSeek, playbackRequested, playbackPreparing, playbackPlaying, playbackPaused, playbackStopped, playbackFailed
        case windowKey, windowClose, windowResizeBegin, windowResizeEnd
        case windowFullscreenEnter, windowFullscreenExit, windowMiniaturize, windowRestore
        case splitViewResize, pointerDown, scroll, keyboardCommand
    }
    public enum Window: String, Codable, Sendable { case browser, player, other, none }
    public static let capacity = 32
    public let sequence: UInt64
    public let timestamp: Date
    public let uptime: TimeInterval
    public let kind: Kind
    public let window: Window
    var isValid: Bool {
        sequence > 0 && timestamp.timeIntervalSince1970.isFinite && uptime.isFinite && uptime >= 0
    }
}

/// Updated during normal execution, never from a fatal-signal handler. PLCrashReporter
/// copies this bounded snapshot into its report, so a restart cannot substitute new actions.
final class CrashOperationTrail {
    private var entries: [CrashOperation] = []
    private var sequence: UInt64 = 0
    private let lock = NSLock()
    private let publish: ([CrashOperation]) -> Void
    init(publish: @escaping ([CrashOperation]) -> Void) { self.publish = publish }
    func record(_ kind: CrashOperation.Kind, window: CrashOperation.Window,
                now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        // Coalesce noisy input; retain semantic transitions even when adjacent.
        if [.scroll, .pointerDown, .keyboardCommand, .splitViewResize].contains(kind), let last = entries.last,
           last.kind == kind, last.window == window, uptime - last.uptime < 1 { return }
        sequence += 1
        entries.append(.init(sequence: sequence, timestamp: now, uptime: uptime, kind: kind, window: window))
        entries = Array(entries.suffix(CrashOperation.capacity))
        publish(entries)
    }
}
