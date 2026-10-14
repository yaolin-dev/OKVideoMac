import Foundation

/// Transport equality only, never channel ownership or a persisted identifier.
/// Compare the already parsed URL/header bytes without further normalization.
public struct ImportedRouteTransport: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Header: Hashable, Sendable { let name: Data; let value: Data }
    private let url: Data
    private let headers: [Header]
    private let format: Data?
    private let needsParsing: Bool
    private let catchup: LiveCatchupConfiguration?

    public init?(_ stream: LiveStream) {
        guard case .direct(let value) = stream.target else { return nil }
        url = Data(value.absoluteString.utf8)
        headers = stream.headers.map { Header(name: Data($0.key.utf8), value: Data($0.value.utf8)) }
            .sorted { $0.name.lexicographicallyPrecedes($1.name) }
        format = stream.format.map { Data($0.utf8) }
        needsParsing = stream.needsParsing
        catchup = stream.catchup
    }

    public static func same(_ lhs: LiveStream, _ rhs: LiveStream) -> Bool {
        guard let a = Self(lhs), let b = Self(rhs) else { return false }
        return a == b
    }

    /// Stable first occurrence wins for presentation only. Unsupported targets
    /// are preserved; this helper never gives provider routes imported identity.
    public static func deduplicated(_ streams: [LiveStream]) -> [LiveStream] {
        var seen = Set<Self>()
        return streams.filter { stream in
            guard let tuple = Self(stream) else { return true }
            return seen.insert(tuple).inserted
        }
    }

    public var description: String { "ImportedRouteTransport(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Opaque addressing, intentionally not Codable. No public initializer and no
/// hash/URL-based persistent fingerprint. Only its originating context resolves it.
public struct ImportedRouteRuntimeKey: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let sourceID: UUID
    fileprivate let contextID: UUID
    fileprivate let routeID: UUID
    public var description: String { "ImportedRouteRuntimeKey(\(contextID)/\(routeID))" }
    public var debugDescription: String { description }
}

public struct ImportedRouteBinding: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: ImportedRouteRuntimeKey
    public let stream: LiveStream
    public var description: String { "ImportedRouteBinding(\(id), <stream omitted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["key": id.description]) }
}

/// Immutable, run-time catalog scope. The browser may replace its reference,
/// while a playback session retains its previous context. No global registry,
/// lazy allocations, persistence, timers or network work.
public final class ImportedRouteContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let sourceID: UUID
    private let contextID = UUID()
    private let keys: [ImportedRouteTransport: ImportedRouteRuntimeKey]
    private let routes: [ImportedRouteRuntimeKey: LiveStream]
    public var count: Int { keys.count }

    public init?(source: LiveSourceID, streams: [LiveStream]) {
        guard case .imported(let sourceID) = source else { return nil }
        self.sourceID = sourceID
        var keys: [ImportedRouteTransport: ImportedRouteRuntimeKey] = [:]
        var routes: [ImportedRouteRuntimeKey: LiveStream] = [:]
        for stream in streams {
            guard let tuple = ImportedRouteTransport(stream) else { return nil }
            if keys[tuple] != nil { continue }
            let key = ImportedRouteRuntimeKey(sourceID: sourceID, contextID: contextID, routeID: UUID())
            keys[tuple] = key; routes[key] = stream
        }
        self.keys = keys; self.routes = routes
    }

    public func key(for stream: LiveStream) -> ImportedRouteRuntimeKey? {
        ImportedRouteTransport(stream).flatMap { keys[$0] }
    }

    /// Returns the first observed presentation of this transport. A channel's
    /// own label is preserved by bindings(in:), not inherited from another channel.
    public func resolve(_ key: ImportedRouteRuntimeKey) -> LiveStream? {
        guard key.sourceID == sourceID, key.contextID == contextID else { return nil }
        return routes[key]
    }

    public func bindings(in streams: [LiveStream]) -> [ImportedRouteBinding]? {
        var bindings: [ImportedRouteBinding] = []
        for stream in ImportedRouteTransport.deduplicated(streams) {
            guard let key = key(for: stream) else { return nil }
            bindings.append(ImportedRouteBinding(id: key, stream: stream))
        }
        return bindings
    }

    public var description: String { "ImportedRouteContext(\(contextID), routes: \(count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["context": contextID.uuidString, "count": String(count)]) }
}
