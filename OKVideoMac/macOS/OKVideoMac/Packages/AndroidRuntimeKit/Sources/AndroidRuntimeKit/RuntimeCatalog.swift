import Foundation

public struct RuntimeGenerationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isValid: Bool {
        guard !rawValue.isEmpty,
              rawValue.count <= 64,
              rawValue != ".",
              rawValue != ".." else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "0123456789._-"
        )
        return rawValue.unicodeScalars.allSatisfy(allowed.contains)
            && rawValue.first?.isLetter == true
    }
}

extension RuntimeGenerationID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RuntimeHostArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64
}

public enum RuntimeCandidateState: String, Codable, Sendable {
    case evaluation
    case qualified
    case rejected
}

public struct RuntimeCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let apiLevel: Int
    public let systemImageVariant: String
    public let architecture: RuntimeHostArchitecture
    public let state: RuntimeCandidateState

    public init(
        id: String,
        apiLevel: Int,
        systemImageVariant: String,
        architecture: RuntimeHostArchitecture,
        state: RuntimeCandidateState
    ) {
        self.id = id
        self.apiLevel = apiLevel
        self.systemImageVariant = systemImageVariant
        self.architecture = architecture
        self.state = state
    }
}

public enum RuntimeComponentRole: String, Codable, CaseIterable, Sendable {
    case jre
    case commandLineTools
    case platformTools
    case emulator
    case systemImage
    case platform
}

public enum RuntimeArchiveFormat: String, Codable, Sendable {
    case zip
    case tarGzip
    case raw
}

/// Describes how an immutable catalog artifact is materialized inside a
/// staged Runtime Generation. Both paths are catalog data, never user input.
public struct RuntimeComponentInstallationDescriptor:
    Codable, Equatable, Sendable {
    public let archiveFormat: RuntimeArchiveFormat
    public let archiveSubpath: String?
    public let destinationRelativePath: String

    public init(
        archiveFormat: RuntimeArchiveFormat,
        archiveSubpath: String? = nil,
        destinationRelativePath: String
    ) {
        self.archiveFormat = archiveFormat
        self.archiveSubpath = archiveSubpath
        self.destinationRelativePath = destinationRelativePath
    }
}

/// Every downloadable artifact is immutable once it appears in a shipped
/// catalog. JRE artifacts intentionally use the same model as Android SDK
/// artifacts so Java can never silently fall back to the host environment.
public struct RuntimeComponentDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let role: RuntimeComponentRole
    public let vendor: String
    public let version: String
    public let architecture: RuntimeHostArchitecture
    public let downloadURL: URL
    public let sha256: String
    public let licenseID: String
    public let licenseURL: URL
    public let expectedVersionOutput: String
    public let minimumMacOS: String
    public let packageID: String?
    public let compressedSize: Int64
    public let installedSize: Int64
    public let installation: RuntimeComponentInstallationDescriptor?

    public init(
        id: String,
        role: RuntimeComponentRole,
        vendor: String,
        version: String,
        architecture: RuntimeHostArchitecture,
        downloadURL: URL,
        sha256: String,
        licenseID: String,
        licenseURL: URL,
        expectedVersionOutput: String,
        minimumMacOS: String,
        packageID: String? = nil,
        compressedSize: Int64,
        installedSize: Int64,
        installation: RuntimeComponentInstallationDescriptor? = nil
    ) {
        self.id = id
        self.role = role
        self.vendor = vendor
        self.version = version
        self.architecture = architecture
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.licenseID = licenseID
        self.licenseURL = licenseURL
        self.expectedVersionOutput = expectedVersionOutput
        self.minimumMacOS = minimumMacOS
        self.packageID = packageID
        self.compressedSize = compressedSize
        self.installedSize = installedSize
        self.installation = installation
    }
}

public struct RuntimeGenerationDescriptor: Codable, Equatable, Sendable {
    public let generationID: RuntimeGenerationID
    public let runtimeSchema: Int
    public let avdSchema: Int
    public let bridgeSchema: Int
    public let minimumAppVersion: String
    public let maximumAppVersion: String?
    public let architecture: RuntimeHostArchitecture
    public let components: [RuntimeComponentDescriptor]

    public init(
        generationID: RuntimeGenerationID,
        runtimeSchema: Int,
        avdSchema: Int,
        bridgeSchema: Int,
        minimumAppVersion: String,
        maximumAppVersion: String? = nil,
        architecture: RuntimeHostArchitecture,
        components: [RuntimeComponentDescriptor]
    ) {
        self.generationID = generationID
        self.runtimeSchema = runtimeSchema
        self.avdSchema = avdSchema
        self.bridgeSchema = bridgeSchema
        self.minimumAppVersion = minimumAppVersion
        self.maximumAppVersion = maximumAppVersion
        self.architecture = architecture
        self.components = components
    }
}

public struct RuntimeCatalog: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let catalogVersion: String
    public let candidateMatrix: [RuntimeCandidate]
    public let generations: [RuntimeGenerationDescriptor]

    public init(
        schemaVersion: Int,
        catalogVersion: String,
        candidateMatrix: [RuntimeCandidate],
        generations: [RuntimeGenerationDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.candidateMatrix = candidateMatrix
        self.generations = generations
    }
}

public enum RuntimeCatalogValidationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateIdentifier(String)
    case invalidGenerationID(String)
    case invalidSchema(String)
    case missingRequiredComponent(RuntimeComponentRole, String)
    case invalidComponent(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            return "Unsupported Android Runtime catalog schema: \(schema)"
        case .duplicateIdentifier(let identifier):
            return "Duplicate Android Runtime catalog identifier: \(identifier)"
        case .invalidGenerationID(let identifier):
            return "Invalid Android Runtime generation identifier: \(identifier)"
        case .invalidSchema(let detail):
            return "Invalid Android Runtime schema: \(detail)"
        case .missingRequiredComponent(let role, let generation):
            return "Generation \(generation) is missing \(role.rawValue)"
        case .invalidComponent(let identifier, let detail):
            return "Invalid component \(identifier): \(detail)"
        }
    }
}

public enum RuntimeCatalogLoader {
    public static func decode(_ data: Data) throws -> RuntimeCatalog {
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: data)
        try validate(catalog)
        return catalog
    }

    public static func validate(_ catalog: RuntimeCatalog) throws {
        guard catalog.schemaVersion == RuntimeCatalog.supportedSchemaVersion else {
            throw RuntimeCatalogValidationError.unsupportedSchema(
                catalog.schemaVersion
            )
        }
        guard !catalog.catalogVersion.isEmpty else {
            throw RuntimeCatalogValidationError.invalidSchema(
                "catalogVersion is empty"
            )
        }

        var identifiers = Set<String>()
        for candidate in catalog.candidateMatrix {
            guard identifiers.insert(candidate.id).inserted else {
                throw RuntimeCatalogValidationError.duplicateIdentifier(
                    candidate.id
                )
            }
            guard candidate.apiLevel > 0,
                  !candidate.systemImageVariant.isEmpty else {
                throw RuntimeCatalogValidationError.invalidSchema(
                    "candidate \(candidate.id) is incomplete"
                )
            }
        }

        for generation in catalog.generations {
            let generationID = generation.generationID.rawValue
            guard generation.generationID.isValid else {
                throw RuntimeCatalogValidationError.invalidGenerationID(
                    generationID
                )
            }
            guard identifiers.insert(generationID).inserted else {
                throw RuntimeCatalogValidationError.duplicateIdentifier(
                    generationID
                )
            }
            guard generation.runtimeSchema > 0,
                  generation.avdSchema > 0,
                  generation.bridgeSchema > 0 else {
                throw RuntimeCatalogValidationError.invalidSchema(
                    "generation \(generationID) has a non-positive schema"
                )
            }
            let roles = Set(generation.components.map(\.role))
            for required in [
                RuntimeComponentRole.jre,
                .commandLineTools,
                .platformTools,
                .emulator,
                .systemImage
            ] where !roles.contains(required) {
                throw RuntimeCatalogValidationError.missingRequiredComponent(
                    required,
                    generationID
                )
            }
            var componentIDs = Set<String>()
            var destinations = Set<String>()
            for component in generation.components {
                guard componentIDs.insert(component.id).inserted else {
                    throw RuntimeCatalogValidationError.duplicateIdentifier(
                        component.id
                    )
                }
                try validate(component)
                guard component.architecture == generation.architecture else {
                    throw RuntimeCatalogValidationError.invalidComponent(
                        component.id,
                        "architecture differs from its generation"
                    )
                }
                guard let installation = component.installation else {
                    throw RuntimeCatalogValidationError.invalidComponent(
                        component.id,
                        "installation layout is missing"
                    )
                }
                guard destinations.allSatisfy({ existing in
                    !pathsOverlap(
                        existing,
                        installation.destinationRelativePath
                    )
                }) else {
                    throw RuntimeCatalogValidationError.invalidComponent(
                        component.id,
                        "installation destination overlaps another component"
                    )
                }
                destinations.insert(installation.destinationRelativePath)
                if component.role == .systemImage,
                   component.packageID?.isEmpty != false {
                    throw RuntimeCatalogValidationError.invalidComponent(
                        component.id,
                        "system image package identity is missing"
                    )
                }
            }
        }
    }

    private static func validate(
        _ component: RuntimeComponentDescriptor
    ) throws {
        guard !component.id.isEmpty,
              !component.vendor.isEmpty,
              !component.version.isEmpty,
              !component.licenseID.isEmpty,
              !component.expectedVersionOutput.isEmpty,
              !component.minimumMacOS.isEmpty else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "required identity field is empty"
            )
        }
        guard isSafeRelativePath(component.id),
              !component.id.contains("/") else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "identifier must be one safe path component"
            )
        }
        guard component.version.lowercased() != "latest" else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "version must be immutable and fully pinned"
            )
        }
        guard component.downloadURL.scheme?.lowercased() == "https",
              component.licenseURL.scheme?.lowercased() == "https" else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "download and license URLs must use HTTPS"
            )
        }
        let normalizedHash = component.sha256.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard component.sha256 == normalizedHash,
              normalizedHash.count == 64,
              normalizedHash.unicodeScalars.allSatisfy(hexadecimal.contains)
        else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "SHA-256 must be 64 lowercase hexadecimal characters"
            )
        }
        guard component.compressedSize > 0,
              component.installedSize > 0 else {
            throw RuntimeCatalogValidationError.invalidComponent(
                component.id,
                "component sizes must be positive"
            )
        }
        if let installation = component.installation {
            guard isSafeRelativePath(installation.destinationRelativePath),
                  installation.archiveSubpath.map(isSafeRelativePath) ?? true
            else {
                throw RuntimeCatalogValidationError.invalidComponent(
                    component.id,
                    "installation paths must be safe relative paths"
                )
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        let sharedCount = min(left.count, right.count)
        return left.prefix(sharedCount).elementsEqual(right.prefix(sharedCount))
    }
}

public enum BundledRuntimeCatalog {
    public static func load() throws -> RuntimeCatalog {
        guard let url = Bundle.module.url(
            forResource: "RuntimeCandidateMatrix",
            withExtension: "json"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try RuntimeCatalogLoader.decode(Data(contentsOf: url))
    }
}
