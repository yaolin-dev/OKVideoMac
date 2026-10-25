import Foundation

/// Xtream account secrets deliberately have no Codable conformance so they
/// cannot be embedded in configuration or portable-backup payloads by accident.
public struct XtreamCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public protocol XtreamCredentialStoring: Sendable {
    func credentials(for providerID: UUID) async throws -> XtreamCredentials?
    func previewCredentials(for providerID: UUID) async throws -> XtreamCredentials?
    func save(_ credentials: XtreamCredentials, for providerID: UUID) async throws
    func deleteCredentials(for providerID: UUID) async throws
}

public extension XtreamCredentialStoring {
    /// Background artwork must never trigger a credential authorization dialog.
    func previewCredentials(for providerID: UUID) async throws -> XtreamCredentials? { nil }
}
