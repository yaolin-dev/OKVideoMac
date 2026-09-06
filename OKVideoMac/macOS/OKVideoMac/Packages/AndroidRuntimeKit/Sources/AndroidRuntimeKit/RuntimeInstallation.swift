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

public struct RuntimeInstallationProgress: Equatable, Sendable {
    public let phase: RuntimeInstallationPhase
    public let generationID: RuntimeGenerationID
    public let componentID: String?
    public let receivedBytes: Int64
    public let componentBytes: Int64
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(
        phase: RuntimeInstallationPhase,
        generationID: RuntimeGenerationID,
        componentID: String? = nil,
        receivedBytes: Int64 = 0,
        componentBytes: Int64 = 0,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        self.phase = phase
        self.generationID = generationID
        self.componentID = componentID
        self.receivedBytes = receivedBytes
        self.componentBytes = componentBytes
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(
            1,
            max(0, Double(completedBytes + receivedBytes) / Double(totalBytes))
        )
    }
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
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidDownloadResponse(String)
    case downloadSizeMismatch(String)

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
        case let .insufficientDiskSpace(required, available):
            return "Managed Android Runtime needs \(required) bytes but only \(available) bytes are available"
        case .invalidDownloadResponse(let detail):
            return "Runtime download response is invalid: \(detail)"
        case .downloadSizeMismatch(let id):
            return "Runtime component download size does not match the catalog: \(id)"
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

public protocol ProgressReportingRuntimeArtifactDownloading:
    RuntimeArtifactDownloading {
    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
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
    ProgressReportingRuntimeArtifactDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let allowedHosts: Set<String>

    public init(
        configuration: URLSessionConfiguration? = nil,
        allowedHosts: Set<String> = [],
        fileManager: FileManager = .default
    ) {
        let configuration = configuration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7_200
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 3
        self.configuration = configuration
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.fileManager = fileManager
    }

    public func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        try await download(
            component: component,
            to: destination,
            progress: { _, _ in }
        )
    }

    public func download(
        component: RuntimeComponentDescriptor,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let originalHost = component.downloadURL.host?.lowercased() ?? ""
        let hosts = allowedHosts.isEmpty
            ? Set([originalHost])
            : allowedHosts
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let operation = RuntimeResumableDownloadOperation(
                configuration: configuration,
                component: component,
                destination: destination,
                allowedHosts: hosts,
                fileManager: fileManager,
                progress: progress
            )
            do {
                try await operation.run()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                attempt += 1
                try await Task.sleep(
                    nanoseconds: UInt64(attempt) * 1_000_000_000
                )
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .cannotDecodeRawData,
            .cannotDecodeContentData
        ].contains(error.code)
    }
}

private final class RuntimeResumableDownloadOperation:
    NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let component: RuntimeComponentDescriptor
    private let destination: URL
    private let allowedHosts: Set<String>
    private let fileManager: FileManager
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var lastReportedBytes: Int64 = -1
    private var didComplete = false

    init(
        configuration: URLSessionConfiguration,
        component: RuntimeComponentDescriptor,
        destination: URL,
        allowedHosts: Set<String>,
        fileManager: FileManager,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.configuration = configuration
        self.component = component
        self.destination = destination
        self.allowedHosts = allowedHosts
        self.fileManager = fileManager
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var offset = Self.fileSize(destination, fileManager: fileManager)
            if offset > component.compressedSize {
                try fileManager.removeItem(at: destination)
                offset = 0
            }
            if !fileManager.fileExists(atPath: destination.path) {
                guard fileManager.createFile(
                    atPath: destination.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            receivedBytes = offset
            var request = URLRequest(url: component.downloadURL)
            request.timeoutInterval = configuration.timeoutIntervalForRequest
            request.cachePolicy = .reloadIgnoringLocalCacheData
            // Runtime artifacts are already compressed archives. Asking the
            // origin and any local HTTP proxy for identity transfer encoding
            // avoids CFNetwork decoding failures and, critically, keeps byte
            // ranges aligned with the catalog's compressed artifact bytes.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            lastReportedBytes = offset
            progress(offset, component.compressedSize)
            task.resume()
        } catch {
            lock.unlock()
            finish(error)
        }
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        if task == nil { finish(CancellationError()) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              allowedHosts.contains(url.host?.lowercased() ?? "") else {
            completionHandler(nil)
            finish(RuntimeInstallationError.invalidDownloadResponse(
                "redirect target is not allowlisted"
            ))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse,
                  let url = response.url,
                  url.scheme?.lowercased() == "https",
                  allowedHosts.contains(url.host?.lowercased() ?? "") else {
                throw RuntimeInstallationError.invalidDownloadResponse(
                    "non-HTTPS or non-allowlisted response"
                )
            }
            let requestedResume = receivedBytes > 0
            if requestedResume && http.statusCode == 200 {
                receivedBytes = 0
                try Data().write(to: destination, options: .atomic)
            } else if requestedResume && http.statusCode != 206 {
                throw RuntimeInstallationError.invalidDownloadResponse(
                    "HTTP \(http.statusCode) did not honor resume"
                )
            } else if !requestedResume && http.statusCode != 200 {
                throw RuntimeInstallationError.invalidDownloadResponse(
                    "HTTP \(http.statusCode)"
                )
            }
            if requestedResume, http.statusCode == 206 {
                let expectedPrefix = "bytes \(receivedBytes)-"
                guard let contentRange = http.value(
                    forHTTPHeaderField: "Content-Range"
                )?.lowercased(), contentRange.hasPrefix(expectedPrefix) else {
                    throw RuntimeInstallationError.invalidDownloadResponse(
                        "resume response has an unexpected Content-Range"
                    )
                }
            }
            if response.expectedContentLength > 0,
               receivedBytes + response.expectedContentLength
                > component.compressedSize {
                throw RuntimeInstallationError.downloadSizeMismatch(
                    component.id
                )
            }
            handle = try FileHandle(forWritingTo: destination)
            try handle?.seekToEnd()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            receivedBytes += Int64(data.count)
            guard receivedBytes <= component.compressedSize else {
                throw RuntimeInstallationError.downloadSizeMismatch(
                    component.id
                )
            }
            try handle?.write(contentsOf: data)
            if receivedBytes == component.compressedSize
                || receivedBytes - lastReportedBytes >= 1_048_576 {
                lastReportedBytes = receivedBytes
                progress(receivedBytes, component.compressedSize)
            }
        } catch {
            task?.cancel()
            finish(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish((error as? URLError)?.code == .cancelled
                ? CancellationError()
                : error)
            return
        }
        guard receivedBytes == component.compressedSize else {
            finish(RuntimeInstallationError.downloadSizeMismatch(component.id))
            return
        }
        finish(nil)
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let continuation = self.continuation
        self.continuation = nil
        let handle = self.handle
        self.handle = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        try? handle?.close()
        session?.finishTasksAndInvalidate()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private static func fileSize(
        _ url: URL,
        fileManager: FileManager
    ) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
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
                        componentID: component.id,
                        allowedTopLevelEntries:
                            installation.allowedTopLevelEntries
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
                        componentID: component.id,
                        allowedTopLevelEntries:
                            installation.allowedTopLevelEntries
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
                componentID: component.id,
                maximumSize: installation.maximumExtractedSize
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
        componentID: String,
        maximumSize: Int64?
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
        var extractedSize: Int64 = 0
        for case let item as URL in enumerator {
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isDescendantOrEqual(resolved, root: canonicalRoot) else {
                throw RuntimeInstallationError.archiveEscapesStaging(
                    componentID
                )
            }
            if let size = try? item.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), size.isRegularFile == true {
                extractedSize += Int64(size.fileSize ?? 0)
                if let maximumSize, extractedSize > maximumSize {
                    throw RuntimeInstallationError.archiveExtractionFailed(
                        componentID
                    )
                }
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
        componentID: String,
        allowedTopLevelEntries: [String]?
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
            if let allowedTopLevelEntries,
               let topLevel = path.split(separator: "/").first,
               !allowedTopLevelEntries.contains(String(topLevel)) {
                throw RuntimeInstallationError.archivePayloadMissing(
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
            try validatePackageIdentity(component, at: location)
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

    private func validatePackageIdentity(
        _ component: RuntimeComponentDescriptor,
        at location: URL
    ) throws {
        guard let packageID = component.packageID else { return }
        let package = location.appendingPathComponent("package.xml")
        guard let data = try? Data(contentsOf: package),
              let text = String(data: data, encoding: .utf8),
              text.contains("localPackage path=\"\(packageID)\"") else {
            throw RuntimeInstallationError.stagedValidationFailed(
                "SDK package identity is missing: \(component.id)"
            )
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
    private let progress: @Sendable (RuntimeInstallationProgress) -> Void

    public init(
        layout: AndroidRuntimeLayout,
        catalog: RuntimeCatalog,
        downloader: any RuntimeArtifactDownloading =
            URLSessionRuntimeArtifactDownloader(),
        materializer: any RuntimeComponentMaterializing =
            ArchiveRuntimeComponentMaterializer(),
        validator: any StagedRuntimeValidating =
            DefaultStagedRuntimeValidator(),
        progress: @escaping @Sendable (RuntimeInstallationProgress) -> Void = {
            _ in
        }
    ) {
        self.layout = layout
        self.catalog = catalog
        self.downloader = downloader
        self.materializer = materializer
        self.validator = validator
        self.progress = progress
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
        let totalBytes = descriptor.components.reduce(Int64(0)) {
            $0 + $1.compressedSize
        }
        progress(RuntimeInstallationProgress(
            phase: .preparing,
            generationID: generationID,
            totalBytes: totalBytes
        ))
        try validateDiskSpace(
            for: descriptor,
            at: layout.root.deletingLastPathComponent()
        )
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
        var completedBytes: Int64 = 0
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
                progress(RuntimeInstallationProgress(
                    phase: phase,
                    generationID: generationID,
                    componentID: component.id,
                    componentBytes: component.compressedSize,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                ))
                try recordTransaction(
                    id: transactionID,
                    generationID: generationID,
                    previous: previous,
                    phase: phase,
                    componentID: component.id,
                    startedAt: startedAt
                )
                let artifact = try await verifiedArtifact(
                    for: component,
                    generationID: generationID,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                )
                try Task.checkCancellation()
                phase = .staging
                progress(RuntimeInstallationProgress(
                    phase: phase,
                    generationID: generationID,
                    componentID: component.id,
                    receivedBytes: component.compressedSize,
                    componentBytes: component.compressedSize,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                ))
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
                completedBytes += component.compressedSize
            }
            try synthesizeMissingSDKPackageMetadata(
                generation: stagedGeneration,
                descriptor: descriptor
            )
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
            progress(RuntimeInstallationProgress(
                phase: phase,
                generationID: generationID,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            ))
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
            progress(RuntimeInstallationProgress(
                phase: phase,
                generationID: generationID,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            ))
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
            progress(RuntimeInstallationProgress(
                phase: phase,
                generationID: generationID,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            ))
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
            progress(RuntimeInstallationProgress(
                phase: phase,
                generationID: generationID,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            ))
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
            progress(RuntimeInstallationProgress(
                phase: finalPhase,
                generationID: generationID,
                componentID: componentID,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ))
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
        for component: RuntimeComponentDescriptor,
        generationID: RuntimeGenerationID,
        completedBytes: Int64,
        totalBytes: Int64
    ) async throws -> URL {
        let fileManager = FileManager.default
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        let artifact = try boundary.descendant(
            relativePath: "\(component.sha256)-\(component.id).artifact",
            under: layout.downloads
        )
        if fileManager.fileExists(atPath: artifact.path) {
            progress(RuntimeInstallationProgress(
                phase: .verifying,
                generationID: generationID,
                componentID: component.id,
                receivedBytes: component.compressedSize,
                componentBytes: component.compressedSize,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ))
            if try RuntimeSHA256.digest(of: artifact) == component.sha256 {
                return artifact
            }
            try fileManager.removeItem(at: artifact)
        }
        let partial = try boundary.descendant(
            relativePath: "\(component.sha256)-\(component.id).partial",
            under: layout.downloads
        )
        let partialSize = ((try? fileManager.attributesOfItem(
            atPath: partial.path
        )[.size]) as? NSNumber)?.int64Value ?? 0
        if partialSize == component.compressedSize {
            progress(RuntimeInstallationProgress(
                phase: .verifying,
                generationID: generationID,
                componentID: component.id,
                receivedBytes: component.compressedSize,
                componentBytes: component.compressedSize,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ))
            if try RuntimeSHA256.digest(of: partial) == component.sha256 {
                try fileManager.moveItem(at: partial, to: artifact)
                return artifact
            }
            try fileManager.removeItem(at: partial)
        }
        do {
            if let reporting = downloader
                as? any ProgressReportingRuntimeArtifactDownloading {
                try await reporting.download(
                    component: component,
                    to: partial
                ) { received, expected in
                    progress(RuntimeInstallationProgress(
                        phase: .downloading,
                        generationID: generationID,
                        componentID: component.id,
                        receivedBytes: received,
                        componentBytes: expected,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes
                    ))
                }
            } else {
                try await downloader.download(
                    component: component,
                    to: partial
                )
            }
        } catch {
            if !(error is CancellationError) {
                let size = ((try? fileManager.attributesOfItem(
                    atPath: partial.path
                )[.size]) as? NSNumber)?.int64Value ?? 0
                if size > component.compressedSize {
                    try? fileManager.removeItem(at: partial)
                }
            }
            throw error
        }
        guard fileManager.fileExists(atPath: partial.path) else {
            throw RuntimeInstallationError.downloadDidNotProduceArtifact(
                component.id
            )
        }
        progress(RuntimeInstallationProgress(
            phase: .verifying,
            generationID: generationID,
            componentID: component.id,
            receivedBytes: component.compressedSize,
            componentBytes: component.compressedSize,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        ))
        let digest = try RuntimeSHA256.digest(of: partial)
        guard digest == component.sha256 else {
            try? fileManager.removeItem(at: partial)
            throw RuntimeInstallationError.artifactHashMismatch(component.id)
        }
        try fileManager.moveItem(at: partial, to: artifact)
        return artifact
    }

    private func validateDiskSpace(
        for descriptor: RuntimeGenerationDescriptor,
        at volumeURL: URL
    ) throws {
        let values = try volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        let compressed = descriptor.components.reduce(Int64(0)) {
            $0 + $1.compressedSize
        }
        let expanded = descriptor.components.reduce(Int64(0)) {
            $0 + $1.installedSize
        }
        let required = Int64(Double(compressed + expanded * 2) * 1.15)
        guard available >= required else {
            throw RuntimeInstallationError.insufficientDiskSpace(
                required: required,
                available: available
            )
        }
    }

    /// The direct Google Emulator archive omits the local SDK `package.xml`
    /// that sdkmanager normally writes after installation. avdmanager refuses
    /// to create an AVD without that record, so the transactional installer
    /// derives it from the already-pinned Catalog identity. Artifact-provided
    /// metadata is never overwritten.
    private func synthesizeMissingSDKPackageMetadata(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor
    ) throws {
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        for component in descriptor.components where component.role == .emulator {
            guard let packageID = component.packageID,
                  let destination = component.installation?
                    .destinationRelativePath else { continue }
            let location = try boundary.descendant(
                relativePath: destination,
                under: generation.root
            )
            let packageXML = location.appendingPathComponent("package.xml")
            guard !FileManager.default.fileExists(
                atPath: packageXML.path
            ) else { continue }
            let revision = component.version.split(separator: "-", maxSplits: 1)
                .first?.split(separator: ".").compactMap { Int($0) } ?? []
            guard let major = revision.first else {
                throw RuntimeInstallationError.stagedValidationFailed(
                    "component revision is invalid: \(component.id)"
                )
            }
            var revisionXML = "<major>\(major)</major>"
            if revision.count > 1 {
                revisionXML += "<minor>\(revision[1])</minor>"
            }
            if revision.count > 2 {
                revisionXML += "<micro>\(revision[2])</micro>"
            }
            let displayName = component.role == .emulator
                ? "Android Emulator"
                : "Android SDK Command-line Tools"
            let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns5="http://schemas.android.com/repository/android/generic/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><localPackage path="\(Self.xmlEscaped(packageID))" obsolete="false"><type-details xsi:type="ns5:genericDetailsType"/><revision>\(revisionXML)</revision><display-name>\(Self.xmlEscaped(displayName))</display-name></localPackage></ns2:repository>
            """
            try Data(xml.utf8).write(to: packageXML, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: packageXML.path
            )
        }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        if fileManager.fileExists(
            atPath: layout.installationTransaction.path
        ) {
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
        }
        let entries = try fileManager.contentsOfDirectory(
            at: layout.staging,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            _ = try boundary.validateMutationTarget(entry)
            try fileManager.removeItem(at: entry)
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
