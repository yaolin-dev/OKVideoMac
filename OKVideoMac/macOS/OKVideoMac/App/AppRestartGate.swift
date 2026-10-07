import Foundation

/// One owner across the language relaunch helper and Sparkle's installer.
@MainActor
final class AppRestartGate {
    enum Owner: Equatable { case application, update }
    static let shared = AppRestartGate()
    private(set) var owner: Owner?

    func claim(_ candidate: Owner) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }

    func release(_ candidate: Owner) {
        guard owner == candidate else { return }
        owner = nil
    }
}

struct AppUpdatePresentationContext: Equatable {
    var startupCompleted: Bool
    var playerPresented: Bool
    var applicationActive: Bool
    var modalPresented: Bool
    var fullScreen: Bool

    var allowsUnsolicitedPresentation: Bool {
        startupCompleted && applicationActive && !playerPresented
            && !modalPresented && !fullScreen
    }
}

enum AppUpdateTerminationPolicy {
    case normal, awaitingInstallationChoice, installing

    var permitsTermination: Bool { self != .awaitingInstallationChoice }
    var permitsTimeoutFallback: Bool { self == .normal }
}

struct AppUpdateConfiguration {
    let feedURL: URL
    let channel: String

    init?(info: [String: Any]) {
        guard let raw = info["SUFeedURL"] as? String,
              let url = URL(string: raw), url.user == nil, url.password == nil,
              url.fragment == nil,
              let channel = info["OKUpdateChannel"] as? String,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        let production = channel == "stable" && url.scheme == "https"
            && url.host?.isEmpty == false
        let local = channel == "local-test" && url.scheme == "http"
            && url.host == "127.0.0.1" && url.port != nil
        guard production || local else { return nil }
        self.feedURL = url
        self.channel = channel
    }
}
