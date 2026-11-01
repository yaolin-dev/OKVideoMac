import Foundation

/// Original provider metadata, separate from the playlist label and UI title.
/// No playback URLs or authorization fields are representable here.
public struct OriginalMediaResource: Codable, Equatable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var provider: String
    public var shareID: String
    public var ownerID: String?
    public var fileID: String?
    public var originalFilename: String?
    /// Verbatim provider path, which may include a provider-generated root or encoding.
    public var providerPath: String?
    /// Set only when the adapter can attest to the path's share-relative meaning.
    public var shareRelativePath: String?
    public var byteSize: Int64?
    public var provenance: String
    public var adapterVersion: Int = 1

    public init(provider: String, shareID: String, ownerID: String? = nil,
                fileID: String? = nil, originalFilename: String? = nil,
                providerPath: String? = nil, shareRelativePath: String? = nil,
                byteSize: Int64? = nil, provenance: String) {
        self.provider = provider; self.shareID = shareID; self.ownerID = ownerID
        self.fileID = fileID; self.originalFilename = originalFilename
        self.providerPath = providerPath; self.shareRelativePath = shareRelativePath
        self.byteSize = byteSize; self.provenance = provenance
    }

    public var validated: OriginalMediaResource? {
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 512
                && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }
        }
        func text(_ value: String?, limit: Int) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= limit && !value.contains("\0")
                && !value.lowercased().contains("://")
        }
        guard schemaVersion == 1, adapterVersion == 1,
              ["baidu", "quark"].contains(provider), identifier(shareID),
              ownerID.map(identifier) ?? true, fileID.map(identifier) ?? true,
              text(originalFilename, limit: 2048), text(providerPath, limit: 8192),
              text(shareRelativePath, limit: 8192),
              byteSize.map({ $0 >= 0 }) ?? true,
              ["wogg-baidu-detail", "wogg-quark-detail", "provider-metadata"].contains(provenance),
              provider != "baidu" || ownerID != nil else { return nil }
        return self
    }

    public var scope: [String] { [provider, ownerID ?? "", shareID] }
    public var fileIdentity: [String]? { fileID.map { scope + [$0] } }

    public enum Match: Equatable { case sameFile, samePath, conflict, unknown }
    public func match(_ candidate: OriginalMediaResource) -> Match {
        guard validated != nil, candidate.validated != nil else { return .unknown }
        guard scope == candidate.scope else { return .conflict }
        if let fileID, let other = candidate.fileID { return fileID == other ? .sameFile : .conflict }
        // Known IDs must not fall back to a filename when the current response
        // omits identity. Only two genuinely ID-less records can use paths.
        guard fileID == nil, candidate.fileID == nil else { return .unknown }
        if let byteSize, let other = candidate.byteSize, byteSize != other { return .conflict }
        guard let path = shareRelativePath, let name = originalFilename,
              path == candidate.shareRelativePath, name == candidate.originalFilename else { return .unknown }
        return .samePath
    }
}
