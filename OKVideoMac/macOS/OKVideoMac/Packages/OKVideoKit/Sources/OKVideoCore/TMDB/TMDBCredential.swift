import Foundation

/// Not Codable: credentials must never become part of a general preferences or backup payload.
public struct TMDBCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Kind: String, CaseIterable, Codable, Sendable { case readAccessToken, apiKey }
    public let kind: Kind
    private let value: String
    public init(kind: Kind, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
              trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              trimmed.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil else { throw TMDBError.invalidCredential }
        self.kind = kind; self.value = trimmed
    }
    var apiKey: String? { kind == .apiKey ? value : nil }
    var bearerToken: String? { kind == .readAccessToken ? value : nil }
    public var description: String { "TMDBCredential(\(kind.rawValue), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue, "value": "<redacted>"]) }
    private struct Stored: Codable { let kind: Kind; let value: String }
    public func keychainData() throws -> Data { try JSONEncoder().encode(Stored(kind: kind, value: value)) }
    public init(keychainData: Data) throws {
        guard keychainData.count <= 8192, let saved = try? JSONDecoder().decode(Stored.self, from: keychainData) else { throw TMDBError.invalidCredential }
        try self.init(kind: saved.kind, value: saved.value)
    }
}
