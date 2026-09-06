import Foundation

public enum RuntimeDetectionStatus: String, Codable, Sendable {
    case notInstalled
    case legacyManagedLayout
    case incomplete
    case corrupt
    case incompatible
    case ready
}

public enum RuntimeDetectionIssueCode: String, Codable, Sendable {
    case legacyLayout
    case unreadableCurrentPointer
    case unsupportedPointerSchema
    case invalidGenerationID
    case missingGeneration
    case pathEscapesManagedRoot
    case missingGenerationManifest
    case unreadableGenerationManifest
    case unsupportedGenerationManifestSchema
    case generationIdentityMismatch
    case invalidGenerationSchema
    case missingSDK
    case missingJRE
    case missingComponent
    case unexpectedComponent
    case componentIdentityMismatch
    case unknownCatalogGeneration
}

public struct RuntimeDetectionIssue: Codable, Equatable, Sendable {
    public let code: RuntimeDetectionIssueCode
    public let detail: String

    public init(code: RuntimeDetectionIssueCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct RuntimeDetectionReport: Equatable, Sendable {
    public let status: RuntimeDetectionStatus
    public let activeGenerationID: RuntimeGenerationID?
    public let generationManifest: RuntimeGenerationManifest?
    public let issues: [RuntimeDetectionIssue]

    public init(
        status: RuntimeDetectionStatus,
        activeGenerationID: RuntimeGenerationID?,
        generationManifest: RuntimeGenerationManifest?,
        issues: [RuntimeDetectionIssue]
    ) {
        self.status = status
        self.activeGenerationID = activeGenerationID
        self.generationManifest = generationManifest
        self.issues = issues
    }
}

/// Performs a read-only inspection. It never repairs, removes, migrates, or
/// activates a Runtime Generation.
public struct AndroidRuntimeDetector {
    public let layout: AndroidRuntimeLayout
    private let fileManager: FileManager

    public init(
        layout: AndroidRuntimeLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func detect(
        catalog: RuntimeCatalog? = nil
    ) -> RuntimeDetectionReport {
        guard fileManager.fileExists(atPath: layout.currentRuntimePointer.path)
        else {
            let legacySDK = layout.root.appendingPathComponent(
                "sdk",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: legacySDK.path) {
                return RuntimeDetectionReport(
                    status: .legacyManagedLayout,
                    activeGenerationID: nil,
                    generationManifest: nil,
                    issues: [
                        RuntimeDetectionIssue(
                            code: .legacyLayout,
                            detail: "Legacy managed sdk/ exists without a Runtime Generation pointer"
                        )
                    ]
                )
            }
            return RuntimeDetectionReport(
                status: .notInstalled,
                activeGenerationID: nil,
                generationManifest: nil,
                issues: []
            )
        }

        let pointer: CurrentRuntimePointer
        do {
            pointer = try decode(
                CurrentRuntimePointer.self,
                at: layout.currentRuntimePointer
            )
        } catch {
            return report(
                .corrupt,
                issue: .unreadableCurrentPointer,
                detail: "current-runtime.json cannot be decoded"
            )
        }
        guard pointer.schemaVersion == CurrentRuntimePointer
            .supportedSchemaVersion else {
            return report(
                .incompatible,
                generationID: pointer.generationID,
                issue: .unsupportedPointerSchema,
                detail: "Unsupported current-runtime pointer schema \(pointer.schemaVersion)"
            )
        }
        guard pointer.generationID.isValid else {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                issue: .invalidGenerationID,
                detail: "The active Runtime Generation identifier is invalid"
            )
        }

        let boundary: ManagedRuntimePathBoundary
        do {
            boundary = try ManagedRuntimePathBoundary(root: layout.root)
            try boundary.validateGenerationID(pointer.generationID)
        } catch {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                issue: .pathEscapesManagedRoot,
                detail: "The active Runtime Generation is outside the managed root"
            )
        }
        let generation = layout.generation(pointer.generationID)
        do {
            _ = try boundary.validateReadTarget(generation.root)
            _ = try boundary.validateReadTarget(generation.sdk)
            _ = try boundary.validateReadTarget(generation.jre)
            _ = try boundary.validateReadTarget(generation.manifest)
        } catch {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                issue: .pathEscapesManagedRoot,
                detail: "A Runtime Generation path resolves outside the managed root"
            )
        }

        guard isDirectory(generation.root) else {
            return report(
                .incomplete,
                generationID: pointer.generationID,
                issue: .missingGeneration,
                detail: "The active Runtime Generation directory is missing"
            )
        }
        guard fileManager.fileExists(atPath: generation.manifest.path) else {
            return report(
                .incomplete,
                generationID: pointer.generationID,
                issue: .missingGenerationManifest,
                detail: "generation-manifest.json is missing"
            )
        }

        let manifest: RuntimeGenerationManifest
        do {
            manifest = try decode(
                RuntimeGenerationManifest.self,
                at: generation.manifest
            )
        } catch {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                issue: .unreadableGenerationManifest,
                detail: "generation-manifest.json cannot be decoded"
            )
        }
        guard manifest.schemaVersion == RuntimeGenerationManifest
            .supportedSchemaVersion else {
            return report(
                .incompatible,
                generationID: pointer.generationID,
                manifest: manifest,
                issue: .unsupportedGenerationManifestSchema,
                detail: "Unsupported generation manifest schema \(manifest.schemaVersion)"
            )
        }
        guard manifest.generationID == pointer.generationID else {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                manifest: manifest,
                issue: .generationIdentityMismatch,
                detail: "Pointer and generation manifest identify different generations"
            )
        }
        guard manifest.runtimeSchema > 0,
              manifest.avdSchema > 0,
              manifest.bridgeSchema > 0 else {
            return report(
                .corrupt,
                generationID: pointer.generationID,
                manifest: manifest,
                issue: .invalidGenerationSchema,
                detail: "Runtime, AVD, and Bridge schemas must be managed independently"
            )
        }
        guard isDirectory(generation.sdk) else {
            return report(
                .incomplete,
                generationID: pointer.generationID,
                manifest: manifest,
                issue: .missingSDK,
                detail: "The active generation SDK directory is missing"
            )
        }
        guard isDirectory(generation.jre) else {
            return report(
                .incomplete,
                generationID: pointer.generationID,
                manifest: manifest,
                issue: .missingJRE,
                detail: "The active generation JRE directory is missing"
            )
        }

        if let componentIssue = validateInstalledComponents(
            manifest,
            generation: generation,
            boundary: boundary
        ) {
            return RuntimeDetectionReport(
                status: componentIssue.code == .pathEscapesManagedRoot
                    ? .corrupt
                    : .incomplete,
                activeGenerationID: pointer.generationID,
                generationManifest: manifest,
                issues: [componentIssue]
            )
        }

        if let catalog,
           !catalog.generations.isEmpty {
            guard let descriptor = catalog.generations.first(where: {
                $0.generationID == pointer.generationID
            }) else {
                return report(
                    .incompatible,
                    generationID: pointer.generationID,
                    manifest: manifest,
                    issue: .unknownCatalogGeneration,
                    detail: "The active generation is not present in this App catalog"
                )
            }
            if let catalogIssue = validate(
                manifest,
                against: descriptor
            ) {
                return RuntimeDetectionReport(
                    status: .incompatible,
                    activeGenerationID: pointer.generationID,
                    generationManifest: manifest,
                    issues: [catalogIssue]
                )
            }
        }

        return RuntimeDetectionReport(
            status: .ready,
            activeGenerationID: pointer.generationID,
            generationManifest: manifest,
            issues: []
        )
    }

    private func validateInstalledComponents(
        _ manifest: RuntimeGenerationManifest,
        generation: RuntimeGenerationLayout,
        boundary: ManagedRuntimePathBoundary
    ) -> RuntimeDetectionIssue? {
        let required: Set<RuntimeComponentRole> = [
            .jre,
            .commandLineTools,
            .platformTools,
            .emulator,
            .systemImage
        ]
        let installedRoles = Set(manifest.components.map(\.role))
        if let missing = required.subtracting(installedRoles)
            .sorted(by: { $0.rawValue < $1.rawValue }).first {
            return RuntimeDetectionIssue(
                code: .missingComponent,
                detail: "Missing installed component role: \(missing.rawValue)"
            )
        }
        var ids = Set<String>()
        for component in manifest.components {
            guard ids.insert(component.id).inserted else {
                return RuntimeDetectionIssue(
                    code: .unexpectedComponent,
                    detail: "Duplicate installed component: \(component.id)"
                )
            }
            let path: URL
            do {
                path = try boundary.descendant(
                    relativePath: component.relativePath,
                    under: generation.root
                )
            } catch {
                return RuntimeDetectionIssue(
                    code: .pathEscapesManagedRoot,
                    detail: "Installed component path escapes its generation"
                )
            }
            guard fileManager.fileExists(atPath: path.path) else {
                return RuntimeDetectionIssue(
                    code: .missingComponent,
                    detail: "Installed component is missing: \(component.id)"
                )
            }
        }
        return nil
    }

    private func validate(
        _ manifest: RuntimeGenerationManifest,
        against descriptor: RuntimeGenerationDescriptor
    ) -> RuntimeDetectionIssue? {
        guard manifest.runtimeSchema == descriptor.runtimeSchema,
              manifest.avdSchema == descriptor.avdSchema,
              manifest.bridgeSchema == descriptor.bridgeSchema else {
            return RuntimeDetectionIssue(
                code: .componentIdentityMismatch,
                detail: "Installed Runtime, AVD, or Bridge schema differs from the catalog"
            )
        }
        let installedByID = Dictionary(
            uniqueKeysWithValues: manifest.components.map { ($0.id, $0) }
        )
        for expected in descriptor.components {
            guard let installed = installedByID[expected.id],
                  installed.role == expected.role,
                  installed.version == expected.version,
                  installed.sha256 == expected.sha256 else {
                return RuntimeDetectionIssue(
                    code: .componentIdentityMismatch,
                    detail: "Installed component differs from catalog: \(expected.id)"
                )
            }
        }
        return nil
    }

    private func report(
        _ status: RuntimeDetectionStatus,
        generationID: RuntimeGenerationID? = nil,
        manifest: RuntimeGenerationManifest? = nil,
        issue: RuntimeDetectionIssueCode,
        detail: String
    ) -> RuntimeDetectionReport {
        RuntimeDetectionReport(
            status: status,
            activeGenerationID: generationID,
            generationManifest: manifest,
            issues: [RuntimeDetectionIssue(code: issue, detail: detail)]
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}
