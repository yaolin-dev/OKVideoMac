import Foundation

public struct AndroidRuntimeLayout: Equatable, Sendable {
    public let root: URL

    public init(applicationSupportDirectory: URL) {
        root = applicationSupportDirectory
            .appendingPathComponent("AndroidRuntime", isDirectory: true)
            .standardizedFileURL
    }

    public init(runtimeRoot: URL) {
        root = runtimeRoot.standardizedFileURL
    }

    public var generations: URL {
        root.appendingPathComponent("Generations", isDirectory: true)
    }

    public var currentRuntimePointer: URL {
        root.appendingPathComponent("current-runtime.json")
    }

    public var installationTransaction: URL {
        root.appendingPathComponent("installation-transaction.json")
    }

    public var downloads: URL {
        root.appendingPathComponent("Downloads", isDirectory: true)
    }

    public var staging: URL {
        root.appendingPathComponent("Staging", isDirectory: true)
    }

    public var backups: URL {
        root.appendingPathComponent("Backups", isDirectory: true)
    }

    public var logs: URL {
        root.appendingPathComponent("Logs", isDirectory: true)
    }

    /// AVD data deliberately lives outside Runtime Generations. Its schema is
    /// recorded separately so an SDK tools-only update never resets userdata.
    public var avdHome: URL {
        root.appendingPathComponent("avd", isDirectory: true)
    }

    public var avdDirectory: URL {
        avdHome.appendingPathComponent(
            "OKVideoMac_Runtime.avd",
            isDirectory: true
        )
    }

    public var avdManifest: URL {
        avdHome.appendingPathComponent("avd-manifest.json")
    }

    public var privateHome: URL {
        root.appendingPathComponent("home", isDirectory: true)
    }

    public var privateAndroidHome: URL {
        privateHome.appendingPathComponent(".android", isDirectory: true)
    }

    public var privateADBKey: URL {
        privateAndroidHome.appendingPathComponent("adbkey")
    }

    public func generation(
        _ generationID: RuntimeGenerationID
    ) -> RuntimeGenerationLayout {
        let generationRoot = generations.appendingPathComponent(
            generationID.rawValue,
            isDirectory: true
        )
        return RuntimeGenerationLayout(
            id: generationID,
            root: generationRoot,
            sdk: generationRoot.appendingPathComponent(
                "sdk",
                isDirectory: true
            ),
            jre: generationRoot.appendingPathComponent(
                "jre",
                isDirectory: true
            ),
            manifest: generationRoot.appendingPathComponent(
                "generation-manifest.json"
            )
        )
    }
}

public struct RuntimeGenerationLayout: Equatable, Sendable {
    public let id: RuntimeGenerationID
    public let root: URL
    public let sdk: URL
    public let jre: URL
    public let manifest: URL

    public init(
        id: RuntimeGenerationID,
        root: URL,
        sdk: URL,
        jre: URL,
        manifest: URL
    ) {
        self.id = id
        self.root = root
        self.sdk = sdk
        self.jre = jre
        self.manifest = manifest
    }
}

public enum ManagedRuntimePathError: LocalizedError, Equatable {
    case nonFileURL
    case invalidGenerationID(String)
    case unmanagedBase
    case escapesManagedRoot
    case rootMutationForbidden
    case invalidRelativePath

    public var errorDescription: String? {
        switch self {
        case .nonFileURL:
            return "Managed Android Runtime paths must be file URLs"
        case .invalidGenerationID(let identifier):
            return "Invalid Android Runtime generation identifier: \(identifier)"
        case .unmanagedBase:
            return "The requested base directory is outside AndroidRuntime"
        case .escapesManagedRoot:
            return "The requested path escapes the managed AndroidRuntime root"
        case .rootMutationForbidden:
            return "Mutation of the AndroidRuntime root itself is forbidden"
        case .invalidRelativePath:
            return "The requested AndroidRuntime relative path is invalid"
        }
    }
}

/// All future installer mutations must pass through this boundary. It rejects
/// sibling-prefix tricks, `..`, absolute relative paths, and existing symlinks
/// whose resolved destination escapes the private AndroidRuntime root.
public struct ManagedRuntimePathBoundary: Sendable {
    public let root: URL

    public init(root: URL) throws {
        guard root.isFileURL else { throw ManagedRuntimePathError.nonFileURL }
        self.root = Self.canonicalizingExistingAncestors(root)
    }

    public func validateGenerationID(
        _ generationID: RuntimeGenerationID
    ) throws {
        guard generationID.isValid else {
            throw ManagedRuntimePathError.invalidGenerationID(
                generationID.rawValue
            )
        }
    }

    public func validateReadTarget(_ target: URL) throws -> URL {
        try validate(target, allowRoot: true)
    }

    public func validateMutationTarget(_ target: URL) throws -> URL {
        try validate(target, allowRoot: false)
    }

    public func descendant(
        relativePath: String,
        under base: URL
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~") else {
            throw ManagedRuntimePathError.invalidRelativePath
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw ManagedRuntimePathError.invalidRelativePath
        }
        let validatedBase = try validate(base, allowRoot: true)
        var candidate = validatedBase
        for component in components {
            candidate.appendPathComponent(String(component))
        }
        let validatedCandidate = try validate(candidate, allowRoot: false)
        guard Self.isDescendantOrEqual(
            validatedCandidate,
            root: validatedBase
        ) else {
            throw ManagedRuntimePathError.escapesManagedRoot
        }
        return validatedCandidate
    }

    public func contains(_ target: URL) -> Bool {
        (try? validate(target, allowRoot: true)) != nil
    }

    public func redactedLocation(for target: URL?) -> String {
        guard let target else { return "<missing>" }
        guard let canonical = try? validate(target, allowRoot: true) else {
            return "<external>"
        }
        if canonical == root { return "<runtime>" }
        let rootComponents = root.pathComponents
        let relative = canonical.pathComponents.dropFirst(rootComponents.count)
        return "<runtime>/" + relative.joined(separator: "/")
    }

    private func validate(_ target: URL, allowRoot: Bool) throws -> URL {
        guard target.isFileURL else {
            throw ManagedRuntimePathError.nonFileURL
        }
        let canonical = Self.canonicalizingExistingAncestors(target)
        guard Self.isDescendantOrEqual(canonical, root: root) else {
            throw ManagedRuntimePathError.escapesManagedRoot
        }
        guard allowRoot || canonical != root else {
            throw ManagedRuntimePathError.rootMutationForbidden
        }
        return canonical
    }

    private static func isDescendantOrEqual(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return candidateComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }

    /// `URL.resolvingSymlinksInPath()` does not reliably resolve an existing
    /// symlink when one or more final descendants do not exist yet. Installer
    /// targets are commonly new files, so resolve the nearest existing parent
    /// first and then append only the missing lexical suffix.
    private static func canonicalizingExistingAncestors(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: existing.path),
              existing.path != "/" {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }
}

public struct CurrentRuntimePointer: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let generationID: RuntimeGenerationID
    public let activatedAt: Date

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        generationID: RuntimeGenerationID,
        activatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.activatedAt = activatedAt
    }
}

public struct InstalledRuntimeComponent: Codable, Equatable, Sendable {
    public let id: String
    public let role: RuntimeComponentRole
    public let version: String
    public let relativePath: String
    public let sha256: String

    public init(
        id: String,
        role: RuntimeComponentRole,
        version: String,
        relativePath: String,
        sha256: String
    ) {
        self.id = id
        self.role = role
        self.version = version
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

public struct RuntimeGenerationManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let generationID: RuntimeGenerationID
    public let catalogVersion: String
    public let runtimeSchema: Int
    public let avdSchema: Int
    public let bridgeSchema: Int
    public let installedAt: Date
    public let components: [InstalledRuntimeComponent]

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        generationID: RuntimeGenerationID,
        catalogVersion: String,
        runtimeSchema: Int,
        avdSchema: Int,
        bridgeSchema: Int,
        installedAt: Date,
        components: [InstalledRuntimeComponent]
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.catalogVersion = catalogVersion
        self.runtimeSchema = runtimeSchema
        self.avdSchema = avdSchema
        self.bridgeSchema = bridgeSchema
        self.installedAt = installedAt
        self.components = components
    }
}

public struct ManagedAVDManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let avdSchema: Int
    public let bridgeSchema: Int
    public let runtimeGenerationID: RuntimeGenerationID
    public let systemImageComponentID: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        avdSchema: Int,
        bridgeSchema: Int,
        runtimeGenerationID: RuntimeGenerationID,
        systemImageComponentID: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.avdSchema = avdSchema
        self.bridgeSchema = bridgeSchema
        self.runtimeGenerationID = runtimeGenerationID
        self.systemImageComponentID = systemImageComponentID
        self.createdAt = createdAt
    }
}

public enum ManagedAVDCompatibilityStatus: String, Codable, Sendable {
    case create
    case adopt
    case reuse
    case refreshMetadata
    case requiresRecoverableRebuild
}

public struct ManagedAVDCompatibilityReport: Equatable, Sendable {
    public let status: ManagedAVDCompatibilityStatus
    public let reason: String?

    public init(
        status: ManagedAVDCompatibilityStatus,
        reason: String? = nil
    ) {
        self.status = status
        self.reason = reason
    }
}

/// Keeps AVD userdata compatibility independent from Runtime Generation
/// identity. A tools-only generation change is reusable when its AVD schema
/// and system-image component are unchanged; an image/schema change is never
/// silently applied to existing userdata.
public enum ManagedAVDCompatibility {
    public static func evaluate(
        hasExistingAVD: Bool,
        manifest: ManagedAVDManifest?,
        expectedGeneration: RuntimeGenerationDescriptor,
        expectedSystemImageComponentID: String,
        configurationMatchesExpectedImage: Bool
    ) -> ManagedAVDCompatibilityReport {
        guard hasExistingAVD else {
            return ManagedAVDCompatibilityReport(status: .create)
        }
        guard configurationMatchesExpectedImage else {
            return ManagedAVDCompatibilityReport(
                status: .requiresRecoverableRebuild,
                reason: "system-image-mismatch"
            )
        }
        guard let manifest else {
            return ManagedAVDCompatibilityReport(status: .adopt)
        }
        guard manifest.schemaVersion == ManagedAVDManifest
            .supportedSchemaVersion else {
            return ManagedAVDCompatibilityReport(
                status: .requiresRecoverableRebuild,
                reason: "unsupported-manifest-schema"
            )
        }
        guard manifest.avdSchema == expectedGeneration.avdSchema else {
            return ManagedAVDCompatibilityReport(
                status: .requiresRecoverableRebuild,
                reason: "avd-schema-mismatch"
            )
        }
        guard manifest.systemImageComponentID
                == expectedSystemImageComponentID else {
            return ManagedAVDCompatibilityReport(
                status: .requiresRecoverableRebuild,
                reason: "system-image-component-mismatch"
            )
        }
        if manifest.runtimeGenerationID != expectedGeneration.generationID
            || manifest.bridgeSchema != expectedGeneration.bridgeSchema {
            return ManagedAVDCompatibilityReport(status: .refreshMetadata)
        }
        return ManagedAVDCompatibilityReport(status: .reuse)
    }
}
