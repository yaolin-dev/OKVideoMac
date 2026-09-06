import CryptoKit
import Foundation

public enum RuntimeInstallationPhase: String, Codable, Sendable {
    case preparing
    case downloading
    case verifying
    case staging
    case validating
    case committing
    case activating
    case completed
    case failed
    case cancelled
}

public struct RuntimeInstallationTransaction: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let transactionID: String
    public let generationID: RuntimeGenerationID
    public let previousGenerationID: RuntimeGenerationID?
    public let phase: RuntimeInstallationPhase
    public let componentID: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let failure: String?

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        transactionID: String,
        generationID: RuntimeGenerationID,
        previousGenerationID: RuntimeGenerationID?,
        phase: RuntimeInstallationPhase,
        componentID: String? = nil,
        startedAt: Date,
        updatedAt: Date,
        failure: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.generationID = generationID
        self.previousGenerationID = previousGenerationID
        self.phase = phase
        self.componentID = componentID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.failure = failure
    }
}

public enum RuntimeInstallationDisposition: String, Codable, Sendable {
    case installed
    case activatedExisting
    case alreadyCurrent
}

public struct RuntimeInstallationResult: Codable, Equatable, Sendable {
    public let generationID: RuntimeGenerationID
    public let previousGenerationID: RuntimeGenerationID?
    public let disposition: RuntimeInstallationDisposition

    public init(
        generationID: RuntimeGenerationID,
        previousGenerationID: RuntimeGenerationID?,
        disposition: RuntimeInstallationDisposition
    ) {
        self.generationID = generationID
        self.previousGenerationID = previousGenerationID
        self.disposition = disposition
    }
}

public enum RuntimeInstallationError: LocalizedError, Equatable {
    case generationNotInCatalog(String)
    case unsupportedHostArchitecture
    case minimumMacOSNotMet(String)
    case missingInstallationLayout(String)
    case downloadDidNotProduceArtifact(String)
    case artifactHashMismatch(String)
    case archiveExtractionFailed(String)
    case archivePayloadMissing(String)
    case archiveEscapesStaging(String)
    case stagedValidationFailed(String)
    case immutableGenerationConflict(String)
    case committedGenerationInvalid(String)
    case unreadableTransactionJournal
    case unsafeTransactionJournal
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .generationNotInCatalog(let id):
            return "Runtime generation is not present in the catalog: \(id)"
        case .unsupportedHostArchitecture:
            return "The managed Android Runtime does not support this Mac architecture"
        case .minimumMacOSNotMet(let version):
            return "The managed Android Runtime requires macOS \(version) or newer"
        case .missingInstallationLayout(let id):
            return "Runtime component has no installation layout: \(id)"
        case .downloadDidNotProduceArtifact(let id):
            return "Runtime component download produced no artifact: \(id)"
        case .artifactHashMismatch(let id):
            return "Runtime component failed SHA-256 verification: \(id)"
        case .archiveExtractionFailed(let id):
            return "Runtime component could not be extracted: \(id)"
        case .archivePayloadMissing(let id):
            return "Runtime component archive payload is missing: \(id)"
        case .archiveEscapesStaging(let id):
            return "Runtime component archive escapes its staging directory: \(id)"
        case .stagedValidationFailed(let detail):
            return "Staged Android Runtime validation failed: \(detail)"
        case .immutableGenerationConflict(let id):
            return "Runtime generation \(id) already exists but is not valid"
        case .committedGenerationInvalid(let id):
            return "Committed Runtime generation is invalid: \(id)"
        case .unreadableTransactionJournal:
            return "The previous Runtime installation transaction cannot be decoded"
        case .unsafeTransactionJournal:
            return "The previous Runtime installation transaction is unsafe"
        case .processFailed(let executable):
            return "Runtime validation process failed: \(executable)"
        }
    }
}

public protocol RuntimeArtifactDownloading: Sendable {
    /// Implementations must write only to `destination`. The installer passes
    /// a unique managed `.partial` path and publishes it only after hashing.
    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws
}

public protocol RuntimeComponentMaterializing: Sendable {
    func materialize(
        artifact: URL,
        component: RuntimeComponentDescriptor,
        stagedGeneration: RuntimeGenerationLayout,
        extractionWorkspace: URL
    ) async throws -> InstalledRuntimeComponent
}

public protocol StagedRuntimeValidating: Sendable {
    func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws
}

public final class URLSessionRuntimeArtifactDownloader:
    RuntimeArtifactDownloading, @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
    }

    public func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        let (temporary, response) = try await session.download(
            from: component.downloadURL
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}

public enum RuntimeSHA256 {
    public static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ArchiveRuntimeComponentMaterializer:
    RuntimeComponentMaterializing, Sendable {
    public init() {}

    public func materialize(
        artifact: URL,
        component: RuntimeComponentDescriptor,
        stagedGeneration: RuntimeGenerationLayout,
        extractionWorkspace: URL
    ) async throws -> InstalledRuntimeComponent {
        let fileManager = FileManager.default
        guard let installation = component.installation else {
            throw RuntimeInstallationError.missingInstallationLayout(
                component.id
            )
        }
        let boundary = try ManagedRuntimePathBoundary(
            root: stagedGeneration.root
        )
        _ = try boundary.validateMutationTarget(extractionWorkspace)
        let destination = try boundary.descendant(
            relativePath: installation.destinationRelativePath,
            under: stagedGeneration.root
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RuntimeInstallationError.stagedValidationFailed(
                "duplicate destination for \(component.id)"
            )
        }

        switch installation.archiveFormat {
        case .raw:
            try fileManager.copyItem(at: artifact, to: destination)
        case .zip, .tarGzip:
            let extractionRoot = extractionWorkspace.appendingPathComponent(
                component.id,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: extractionRoot.path) {
                try fileManager.removeItem(at: extractionRoot)
            }
            try fileManager.createDirectory(
                at: extractionRoot,
                withIntermediateDirectories: true
            )
            do {
                let entries: String
                switch installation.archiveFormat {
                case .zip:
                    entries = try await Self.capture(
                        executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                        arguments: ["-Z1", artifact.path]
                    )
                    try Self.validateArchiveEntries(
                        entries,
                        componentID: component.id
                    )
                    try await Self.run(
                        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                        arguments: ["-x", "-k", artifact.path, extractionRoot.path]
                    )
                case .tarGzip:
                    entries = try await Self.capture(
                        executable: URL(fileURLWithPath: "/usr/bin/tar"),
                        arguments: ["-tzf", artifact.path]
                    )
                    try Self.validateArchiveEntries(
                        entries,
                        componentID: component.id
                    )
                    try await Self.run(
                        executable: URL(fileURLWithPath: "/usr/bin/tar"),
                        arguments: [
                            "-xzf", artifact.path, "-C", extractionRoot.path
                        ]
                    )
                case .raw:
                    break
                }
            } catch {
                throw RuntimeInstallationError.archiveExtractionFailed(
                    component.id
                )
            }
            try validateExtractedTree(
                extractionRoot,
                componentID: component.id
            )
            let source = installation.archiveSubpath.map {
                extractionRoot.appendingPathComponent($0)
            } ?? extractionRoot
            guard fileManager.fileExists(atPath: source.path) else {
                throw RuntimeInstallationError.archivePayloadMissing(
                    component.id
                )
            }
            try fileManager.moveItem(at: source, to: destination)
        }

        return InstalledRuntimeComponent(
            id: component.id,
            role: component.role,
            version: component.version,
            relativePath: installation.destinationRelativePath,
            sha256: component.sha256
        )
    }

    private func validateExtractedTree(
        _ root: URL,
        componentID: String
    ) throws {
        let fileManager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw RuntimeInstallationError.archivePayloadMissing(componentID)
        }
        for case let item as URL in enumerator {
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isDescendantOrEqual(resolved, root: canonicalRoot) else {
                throw RuntimeInstallationError.archiveEscapesStaging(
                    componentID
                )
            }
        }
    }

    private static func isDescendantOrEqual(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count)
                .elementsEqual(rootComponents)
    }

    private static func run(
        executable: URL,
        arguments: [String]
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing:
                        RuntimeInstallationError.processFailed(
                            executable.lastPathComponent
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func capture(
        executable: URL,
        arguments: [String]
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Reading while the process is alive prevents large JRE archive
            // listings from filling the pipe and deadlocking validation.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RuntimeInstallationError.processFailed(
                    executable.lastPathComponent
                )
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    private static func validateArchiveEntries(
        _ listing: String,
        componentID: String
    ) throws {
        for entry in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            var path = String(entry)
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.hasPrefix("~"),
                  path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else {
                throw RuntimeInstallationError.archiveEscapesStaging(
                    componentID
                )
            }
        }
    }
}

public struct DefaultStagedRuntimeValidator:
    StagedRuntimeValidating, Sendable {
    public init() {}

    public func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws {
        let fileManager = FileManager.default
        guard descriptor.generationID == manifest.generationID,
              descriptor.runtimeSchema == manifest.runtimeSchema,
              descriptor.avdSchema == manifest.avdSchema,
              descriptor.bridgeSchema == manifest.bridgeSchema else {
            throw RuntimeInstallationError.stagedValidationFailed(
                "generation identity or schema mismatch"
            )
        }
        let boundary = try ManagedRuntimePathBoundary(root: generation.root)
        let installedByID = Dictionary(
            uniqueKeysWithValues: manifest.components.map { ($0.id, $0) }
        )
        for component in descriptor.components {
            guard let installed = installedByID[component.id],
                  installed.role == component.role,
                  installed.version == component.version,
                  installed.sha256 == component.sha256 else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "component identity mismatch: \(component.id)"
                )
            }
            let location = try boundary.descendant(
                relativePath: installed.relativePath,
                under: generation.root
            )
            guard fileManager.fileExists(atPath: location.path) else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "component missing: \(component.id)"
                )
            }
            try await validateCriticalPayload(
                component,
                at: location,
                generation: generation
            )
        }
    }

    private func validateCriticalPayload(
        _ component: RuntimeComponentDescriptor,
        at location: URL,
        generation: RuntimeGenerationLayout
    ) async throws {
        let fileManager = FileManager.default
        switch component.role {
        case .jre:
            try await validateVersion(
                executable: location.appendingPathComponent("bin/java"),
                arguments: ["-version"],
                expected: component.expectedVersionOutput
            )
        case .commandLineTools:
            try await validateVersion(
                executable: location.appendingPathComponent("bin/sdkmanager"),
                arguments: ["--version"],
                expected: component.expectedVersionOutput,
                environment: [
                    "JAVA_HOME": generation.jre.path,
                    "ANDROID_HOME": generation.sdk.path,
                    "ANDROID_SDK_ROOT": generation.sdk.path
                ]
            )
            guard fileManager.isExecutableFile(
                atPath: location.appendingPathComponent("bin/avdmanager").path
            ) else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "avdmanager is missing or not executable"
                )
            }
        case .platformTools:
            try await validateVersion(
                executable: location.appendingPathComponent("adb"),
                arguments: ["version"],
                expected: component.expectedVersionOutput
            )
        case .emulator:
            try await validateVersion(
                executable: location.appendingPathComponent("emulator"),
                arguments: ["-version"],
                expected: component.expectedVersionOutput
            )
        case .systemImage:
            let package = location.appendingPathComponent("package.xml")
            guard let data = try? Data(contentsOf: package),
                  let text = String(data: data, encoding: .utf8),
                  component.packageID.map(text.contains) ?? true else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "system image package identity is missing"
                )
            }
        case .platform:
            guard fileManager.fileExists(
                atPath: location.appendingPathComponent("android.jar").path
            ) else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "Android platform jar is missing"
                )
            }
        }
    }

    private func validateVersion(
        executable: URL,
        arguments: [String],
        expected: String,
        environment: [String: String] = [:]
    ) async throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw RuntimeInstallationError.stagedValidationFailed(
                "\(executable.lastPathComponent) is missing or not executable"
            )
        }
        let output = try await Self.capture(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard output.contains(expected) else {
            throw RuntimeInstallationError.stagedValidationFailed(
                "\(executable.lastPathComponent) version does not match catalog"
            )
        }
    }

    private static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.merging([
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C"
            ]) { current, _ in current }
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing:
                        RuntimeInstallationError.processFailed(
                            executable.lastPathComponent
                        )
                    )
                    return
                }
                continuation.resume(returning:
                    String(data: data, encoding: .utf8) ?? ""
                )
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private actor RuntimeInstallationAdmission {
    static let shared = RuntimeInstallationAdmission()

    private struct Flight {
        let generationID: RuntimeGenerationID
        let token: UUID
        let task: Task<RuntimeInstallationResult, Error>
    }

    private var tasks: [String: Flight] = [:]

    func perform(
        key: String,
        generationID: RuntimeGenerationID,
        operation: @escaping @Sendable () async throws
            -> RuntimeInstallationResult
    ) async throws -> RuntimeInstallationResult {
        if let existing = tasks[key] {
            if existing.generationID == generationID {
                return try await existing.task.value
            }
            // Different generations must serialize, but must never receive
            // one another's result. Wait for the active transaction, then
            // perform admission again atomically.
            _ = try? await existing.task.value
            if tasks[key]?.token == existing.token {
                tasks[key] = nil
            }
            return try await perform(
                key: key,
                generationID: generationID,
                operation: operation
            )
        }
        let task = Task { try await operation() }
        let token = UUID()
        tasks[key] = Flight(
            generationID: generationID,
            token: token,
            task: task
        )
        defer {
            if tasks[key]?.token == token { tasks[key] = nil }
        }
        return try await task.value
    }

    func cancel(key: String) {
        tasks[key]?.task.cancel()
    }
}

/// Installation single-flight. This actor is intentionally unrelated to the
/// Emulator Session admission actor: one serializes immutable generation
/// transactions; the other serializes a running AVD startup.
public struct AndroidRuntimeInstaller: Sendable {
    public let layout: AndroidRuntimeLayout
    public let catalog: RuntimeCatalog

    private let downloader: any RuntimeArtifactDownloading
    private let materializer: any RuntimeComponentMaterializing
    private let validator: any StagedRuntimeValidating

    public init(
        layout: AndroidRuntimeLayout,
        catalog: RuntimeCatalog,
        downloader: any RuntimeArtifactDownloading =
            URLSessionRuntimeArtifactDownloader(),
        materializer: any RuntimeComponentMaterializing =
            ArchiveRuntimeComponentMaterializer(),
        validator: any StagedRuntimeValidating =
            DefaultStagedRuntimeValidator()
    ) {
        self.layout = layout
        self.catalog = catalog
        self.downloader = downloader
        self.materializer = materializer
        self.validator = validator
    }

    public func install(
        generationID: RuntimeGenerationID
    ) async throws -> RuntimeInstallationResult {
        let key = layout.root.standardizedFileURL.path
        return try await RuntimeInstallationAdmission.shared.perform(
            key: key,
            generationID: generationID
        ) {
            try await performInstallation(generationID: generationID)
        }
    }

    public func cancelInstallation() async {
        await RuntimeInstallationAdmission.shared.cancel(
            key: layout.root.standardizedFileURL.path
        )
    }

    public func rollback(
        to generationID: RuntimeGenerationID
    ) async throws -> RuntimeInstallationResult {
        let key = layout.root.standardizedFileURL.path
        return try await RuntimeInstallationAdmission.shared.perform(
            key: key,
            generationID: generationID
        ) {
            let previous = readCurrentPointer()?.generationID
            try validateCommittedGeneration(generationID)
            try writePointer(generationID)
            return RuntimeInstallationResult(
                generationID: generationID,
                previousGenerationID: previous,
                disposition: .activatedExisting
            )
        }
    }

    private func performInstallation(
        generationID: RuntimeGenerationID
    ) async throws -> RuntimeInstallationResult {
        let fileManager = FileManager.default
        try RuntimeCatalogLoader.validate(catalog)
        guard let descriptor = catalog.generations.first(where: {
            $0.generationID == generationID
        }) else {
            throw RuntimeInstallationError.generationNotInCatalog(
                generationID.rawValue
            )
        }
        try validateHost(for: descriptor)
        let previous = readCurrentPointer()?.generationID
        let detection = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        if detection.status == .ready,
           detection.activeGenerationID == generationID {
            return RuntimeInstallationResult(
                generationID: generationID,
                previousGenerationID: previous,
                disposition: .alreadyCurrent
            )
        }

        try bootstrapDirectories()
        try recoverInterruptedInstallation()
        let finalGeneration = layout.generation(generationID)
        if fileManager.fileExists(atPath: finalGeneration.root.path) {
            do {
                try validateCommittedGeneration(generationID)
                try writePointer(generationID)
                return RuntimeInstallationResult(
                    generationID: generationID,
                    previousGenerationID: previous,
                    disposition: .activatedExisting
                )
            } catch {
                throw RuntimeInstallationError.immutableGenerationConflict(
                    generationID.rawValue
                )
            }
        }

        let transactionID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let transactionRoot = layout.staging.appendingPathComponent(
            transactionID,
            isDirectory: true
        )
        let stagedRoot = transactionRoot.appendingPathComponent(
            generationID.rawValue,
            isDirectory: true
        )
        let stagedGeneration = RuntimeGenerationLayout(
            id: generationID,
            root: stagedRoot,
            sdk: stagedRoot.appendingPathComponent("sdk", isDirectory: true),
            jre: stagedRoot.appendingPathComponent("jre", isDirectory: true),
            manifest: stagedRoot.appendingPathComponent(
                "generation-manifest.json"
            )
        )
        let extractionWorkspace = stagedRoot.appendingPathComponent(
            ".extracted",
            isDirectory: true
        )
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        _ = try boundary.validateMutationTarget(transactionRoot)
        try fileManager.createDirectory(
            at: stagedRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: extractionWorkspace,
            withIntermediateDirectories: true
        )

        var phase = RuntimeInstallationPhase.preparing
        var componentID: String?
        do {
            try recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: phase,
                componentID: nil,
                startedAt: startedAt
            )
            var installed: [InstalledRuntimeComponent] = []
            for component in descriptor.components {
                try Task.checkCancellation()
                componentID = component.id
                phase = .downloading
                try recordTransaction(
                    id: transactionID,
                    generationID: generationID,
                    previous: previous,
                    phase: phase,
                    componentID: component.id,
                    startedAt: startedAt
                )
                let artifact = try await verifiedArtifact(for: component)
                try Task.checkCancellation()
                phase = .staging
                try recordTransaction(
                    id: transactionID,
                    generationID: generationID,
                    previous: previous,
                    phase: phase,
                    componentID: component.id,
                    startedAt: startedAt
                )
                installed.append(try await materializer.materialize(
                    artifact: artifact,
                    component: component,
                    stagedGeneration: stagedGeneration,
                    extractionWorkspace: extractionWorkspace
                ))
            }
            if fileManager.fileExists(atPath: extractionWorkspace.path) {
                try fileManager.removeItem(at: extractionWorkspace)
            }

            let manifest = RuntimeGenerationManifest(
                generationID: generationID,
                catalogVersion: catalog.catalogVersion,
                runtimeSchema: descriptor.runtimeSchema,
                avdSchema: descriptor.avdSchema,
                bridgeSchema: descriptor.bridgeSchema,
                installedAt: Date(),
                components: installed
            )
            try encode(manifest, to: stagedGeneration.manifest)
            phase = .validating
            componentID = nil
            try recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: phase,
                componentID: nil,
                startedAt: startedAt
            )
            try await validator.validate(
                generation: stagedGeneration,
                descriptor: descriptor,
                manifest: manifest
            )
            try Task.checkCancellation()

            phase = .committing
            try recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: phase,
                componentID: nil,
                startedAt: startedAt
            )
            try fileManager.moveItem(
                at: stagedGeneration.root,
                to: finalGeneration.root
            )
            try validateCommittedGeneration(generationID)
            phase = .activating
            try recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: phase,
                componentID: nil,
                startedAt: startedAt
            )
            try writePointer(generationID)
            phase = .completed
            try? recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: phase,
                componentID: nil,
                startedAt: startedAt
            )
            try? fileManager.removeItem(at: transactionRoot)
            return RuntimeInstallationResult(
                generationID: generationID,
                previousGenerationID: previous,
                disposition: .installed
            )
        } catch {
            let finalPhase: RuntimeInstallationPhase = error is CancellationError
                ? .cancelled
                : .failed
            try? recordTransaction(
                id: transactionID,
                generationID: generationID,
                previous: previous,
                phase: finalPhase,
                componentID: componentID,
                startedAt: startedAt,
                failure: sanitizedFailure(error)
            )
            try? fileManager.removeItem(at: transactionRoot)
            throw error
        }
    }

    private func verifiedArtifact(
        for component: RuntimeComponentDescriptor
    ) async throws -> URL {
        let fileManager = FileManager.default
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        let artifact = try boundary.descendant(
            relativePath: "\(component.sha256)-\(component.id).artifact",
            under: layout.downloads
        )
        if fileManager.fileExists(atPath: artifact.path) {
            if try RuntimeSHA256.digest(of: artifact) == component.sha256 {
                return artifact
            }
            try fileManager.removeItem(at: artifact)
        }
        let partial = try boundary.descendant(
            relativePath: "\(UUID().uuidString.lowercased()).partial",
            under: layout.downloads
        )
        defer { try? fileManager.removeItem(at: partial) }
        try await downloader.download(component: component, to: partial)
        guard fileManager.fileExists(atPath: partial.path) else {
            throw RuntimeInstallationError.downloadDidNotProduceArtifact(
                component.id
            )
        }
        let digest = try RuntimeSHA256.digest(of: partial)
        guard digest == component.sha256 else {
            throw RuntimeInstallationError.artifactHashMismatch(component.id)
        }
        try fileManager.moveItem(at: partial, to: artifact)
        return artifact
    }

    private func validateCommittedGeneration(
        _ generationID: RuntimeGenerationID
    ) throws {
        let fileManager = FileManager.default
        guard let descriptor = catalog.generations.first(where: {
            $0.generationID == generationID
        }) else {
            throw RuntimeInstallationError.generationNotInCatalog(
                generationID.rawValue
            )
        }
        let generation = layout.generation(generationID)
        guard let manifest = try? JSONDecoder().decode(
            RuntimeGenerationManifest.self,
            from: Data(contentsOf: generation.manifest)
        ), manifest.generationID == generationID,
           manifest.runtimeSchema == descriptor.runtimeSchema,
           manifest.avdSchema == descriptor.avdSchema,
           manifest.bridgeSchema == descriptor.bridgeSchema else {
            throw RuntimeInstallationError.committedGenerationInvalid(
                generationID.rawValue
            )
        }
        let expected = Dictionary(
            uniqueKeysWithValues: descriptor.components.map { ($0.id, $0) }
        )
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        guard manifest.components.count == descriptor.components.count else {
            throw RuntimeInstallationError.committedGenerationInvalid(
                generationID.rawValue
            )
        }
        for installed in manifest.components {
            guard let component = expected[installed.id],
                  component.role == installed.role,
                  component.version == installed.version,
                  component.sha256 == installed.sha256,
                  let path = try? boundary.descendant(
                    relativePath: installed.relativePath,
                    under: generation.root
                  ),
                  fileManager.fileExists(atPath: path.path) else {
                throw RuntimeInstallationError.committedGenerationInvalid(
                    generationID.rawValue
                )
            }
        }
    }

    private func validateHost(
        for descriptor: RuntimeGenerationDescriptor
    ) throws {
        #if arch(arm64)
        let architecture = RuntimeHostArchitecture.arm64
        #elseif arch(x86_64)
        let architecture = RuntimeHostArchitecture.x86_64
        #else
        throw RuntimeInstallationError.unsupportedHostArchitecture
        #endif
        guard descriptor.architecture == architecture else {
            throw RuntimeInstallationError.unsupportedHostArchitecture
        }
        let actual = ProcessInfo.processInfo.operatingSystemVersion
        let required = descriptor.components
            .map(\.minimumMacOS)
            .max(by: { compareVersions($0, $1) == .orderedAscending })
            ?? "0"
        let actualString = "\(actual.majorVersion).\(actual.minorVersion).\(actual.patchVersion)"
        guard compareVersions(actualString, required) != .orderedAscending else {
            throw RuntimeInstallationError.minimumMacOSNotMet(required)
        }
    }

    private func sanitizedFailure(_ error: Error) -> String {
        if let error = error as? RuntimeInstallationError {
            return error.errorDescription ?? "RuntimeInstallationError"
        }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private func bootstrapDirectories() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: layout.root.path) {
            try fileManager.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )
        }
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        for directory in [
            layout.generations,
            layout.downloads,
            layout.staging,
            layout.logs,
            layout.privateHome,
            layout.privateAndroidHome,
            layout.avdHome
        ] {
            _ = try boundary.validateMutationTarget(directory)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func recoverInterruptedInstallation() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: layout.installationTransaction.path
        ) else { return }
        let transaction: RuntimeInstallationTransaction
        do {
            transaction = try JSONDecoder().decode(
                RuntimeInstallationTransaction.self,
                from: Data(contentsOf: layout.installationTransaction)
            )
        } catch {
            throw RuntimeInstallationError.unreadableTransactionJournal
        }
        guard transaction.schemaVersion == RuntimeInstallationTransaction
            .supportedSchemaVersion,
              UUID(uuidString: transaction.transactionID) != nil,
              transaction.generationID.isValid else {
            throw RuntimeInstallationError.unsafeTransactionJournal
        }
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        let abandoned = try boundary.descendant(
            relativePath: transaction.transactionID,
            under: layout.staging
        )
        if fileManager.fileExists(atPath: abandoned.path) {
            try fileManager.removeItem(at: abandoned)
        }
    }

    private func readCurrentPointer() -> CurrentRuntimePointer? {
        try? JSONDecoder().decode(
            CurrentRuntimePointer.self,
            from: Data(contentsOf: layout.currentRuntimePointer)
        )
    }

    private func writePointer(_ generationID: RuntimeGenerationID) throws {
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        _ = try boundary.validateMutationTarget(layout.currentRuntimePointer)
        try encode(
            CurrentRuntimePointer(
                generationID: generationID,
                activatedAt: Date()
            ),
            to: layout.currentRuntimePointer
        )
    }

    private func recordTransaction(
        id: String,
        generationID: RuntimeGenerationID,
        previous: RuntimeGenerationID?,
        phase: RuntimeInstallationPhase,
        componentID: String?,
        startedAt: Date,
        failure: String? = nil
    ) throws {
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        _ = try boundary.validateMutationTarget(layout.installationTransaction)
        try encode(
            RuntimeInstallationTransaction(
                transactionID: id,
                generationID: generationID,
                previousGenerationID: previous,
                phase: phase,
                componentID: componentID,
                startedAt: startedAt,
                updatedAt: Date(),
                failure: failure
            ),
            to: layout.installationTransaction
        )
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
