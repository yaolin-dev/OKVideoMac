import Foundation

/// A preference is not proof that the current credential and route work.
public enum TMDBPresentationPreference: String, Sendable, CaseIterable {
    case automatic, original

    public static let key = "detail.tmdb.presentation"
    public static let legacyKey = "detail.tmdb.enabled"

    /// Migrate once, before any view supplies a default for the new key.
    @discardableResult public static func load(defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: key), let saved = Self(rawValue: raw) { return saved }
        let migrated: Self = defaults.object(forKey: legacyKey) as? Bool == false ? .original : .automatic
        defaults.set(migrated.rawValue, forKey: key)
        return migrated
    }
}

public enum TMDBPresentationDecision: String, Sendable, Equatable {
    case originalPreference, serviceDisabled, loadingCredential, missingCredential
    case unchecked, checking, connectionUnavailable, ready

    public var usesTMDB: Bool { self == .ready }

    /// Use a fresh availability snapshot at entry; never treat cached artwork as
    /// network evidence. The resulting layout belongs to this page entry only.
    public static func evaluate(preference: TMDBPresentationPreference, enabled: Bool,
                                loadingCredential: Bool, hasCredential: Bool,
                                links: TMDBAvailabilitySnapshot?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Self {
        guard preference == .automatic else { return .originalPreference }
        guard enabled else { return .serviceDisabled }
        guard !loadingCredential else { return .loadingCredential }
        guard hasCredential else { return .missingCredential }
        guard let links else { return .unchecked }
        if links.metadata.checking || links.images.checking { return .checking }
        if links.ready, links.metadata.validUntil > now, links.images.validUntil > now { return .ready }
        if links.blocked { return .connectionUnavailable }
        return .unchecked
    }
}
