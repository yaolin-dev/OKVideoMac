import SwiftUI
import OKVideoCore

enum LiveCatchupPresentation {
    static func canBrowse(_ channel: LiveChannel) -> Bool {
        channel.streams.contains { stream in
            guard let config = stream.effectiveCatchup else { return false }
            return ["default", "append"].contains(config.mode) && !config.template.isEmpty
        }
    }
    static func availability(channel: LiveChannel, programme: EPGProgramme, now: Date) -> LiveCatchupAvailability {
        let results = channel.streams.map { LiveCatchupPolicy.availability(configuration: $0.effectiveCatchup, programme: programme, now: now) }
        if results.contains(.available) { return .available }
        if results.contains(.expired) { return .expired }
        return results.first ?? .unsupported
    }
    static func label(_ availability: LiveCatchupAvailability) -> String {
        switch availability {
        case .available: return L10n.string("live.catchup.play", fallback: "Play Catch-up")
        case .current: return L10n.string("live.catchup.watch-live", fallback: "Watch Live")
        case .future: return L10n.string("live.catchup.future", fallback: "Upcoming Programme")
        case .expired: return L10n.string("live.catchup.expired", fallback: "Catch-up Window Expired")
        case .unsupported: return L10n.string("live.catchup.unsupported", fallback: "Source Does Not Provide Catch-up")
        case .invalidConfiguration, .invalidProgramme: return L10n.string("live.catchup.invalid", fallback: "Catch-up Configuration Unavailable")
        }
    }
}
