import Foundation

public struct PlaybackAudioPreference: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var volume: Double
    public var muted: Bool
    public init(volume: Double = 100, muted: Bool = false) {
        self.volume = volume.isFinite ? min(130, max(0, volume)) : 100
        self.muted = muted
    }
}

/// Intent is immediate. A slider gesture saves only its final value, so defaults
/// notifications cannot compete with rendering at mouse-event frequency.
@MainActor
public final class PlaybackAudioPreferenceStore {
    public static let key = "player.audio.preference.v1"
    public private(set) var value: PlaybackAudioPreference
    public private(set) var revision: UInt64 = 0
    private let defaults: UserDefaults?
    private var isAdjustingVolume = false
    private var hasUnsavedChanges = false

    /// A nil store is deliberately in-memory for isolated clients and tests.
    public init(defaults: UserDefaults? = nil, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        func read(_ store: UserDefaults?) -> PlaybackAudioPreference? {
            guard let data = store?.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode(PlaybackAudioPreference.self, from: data),
                  saved.version == 1 else { return nil }
            return .init(volume: saved.volume, muted: saved.muted)
        }
        if let saved = read(defaults) { value = saved }
        else if let legacy = read(legacyDefaults) {
            value = legacy
            hasUnsavedChanges = true
            flush()
        } else { value = .init() }
    }

    public func setVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        var next = value
        next.volume = min(130, max(0, volume))
        if next.volume > 0 { next.muted = false }
        save(next)
    }

    public func setMuted(_ muted: Bool) {
        var next = value
        next.muted = muted
        save(next)
    }

    public func beginVolumeAdjustment() { isAdjustingVolume = true }
    public func endVolumeAdjustment() {
        isAdjustingVolume = false
        flush()
    }
    /// Also called by playback close and application shutdown if the view goes
    /// away before AppKit delivers the slider's final editing callback.
    public func flush() {
        guard hasUnsavedChanges,
              let data = try? JSONEncoder().encode(value) else { return }
        defaults?.set(data, forKey: Self.key)
        hasUnsavedChanges = false
    }

    private func save(_ next: PlaybackAudioPreference) {
        guard next != value else { return }
        value = next
        revision &+= 1
        hasUnsavedChanges = true
        if !isAdjustingVolume { flush() }
    }
}
