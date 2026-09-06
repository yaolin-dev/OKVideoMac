import Foundation

public struct ManagedRuntimeLicense: Codable, Equatable, Sendable,
    Identifiable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public struct ManagedRuntimeInstallOffer: Codable, Equatable, Sendable {
    public let profileID: String
    public let generationID: RuntimeGenerationID
    public let displayName: String
    public let downloadBytes: Int64
    public let requiredFreeSpace: Int64
    public let licenses: [ManagedRuntimeLicense]
    public let verificationNote: String

    public init(
        profileID: String,
        generationID: RuntimeGenerationID,
        displayName: String,
        downloadBytes: Int64,
        requiredFreeSpace: Int64,
        licenses: [ManagedRuntimeLicense],
        verificationNote: String
    ) {
        self.profileID = profileID
        self.generationID = generationID
        self.displayName = displayName
        self.downloadBytes = downloadBytes
        self.requiredFreeSpace = requiredFreeSpace
        self.licenses = licenses
        self.verificationNote = verificationNote
    }
}

public struct ManagedRuntimeProgressDetail: Equatable, Sendable {
    public let componentID: String?
    public let receivedBytes: Int64
    public let componentBytes: Int64
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(_ progress: RuntimeInstallationProgress) {
        componentID = progress.componentID
        receivedBytes = progress.receivedBytes
        componentBytes = progress.componentBytes
        completedBytes = progress.completedBytes
        totalBytes = progress.totalBytes
    }

    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(
            1,
            max(0, Double(completedBytes + receivedBytes) / Double(totalBytes))
        )
    }
}

public enum ManagedRuntimeFailureCode: String, Codable, Sendable {
    case network
    case integrity
    case diskSpace
    case compatibility
    case cancelled
    case invalidCatalog
    case invalidInstallation
    case internalFailure
}

public struct ManagedRuntimeInstallFailure: Codable, Equatable, Sendable {
    public let code: ManagedRuntimeFailureCode
    public let title: String
    public let message: String
    public let diagnosticCode: String
    public let canRetry: Bool

    public init(
        code: ManagedRuntimeFailureCode,
        title: String,
        message: String,
        diagnosticCode: String,
        canRetry: Bool
    ) {
        self.code = code
        self.title = title
        self.message = message
        self.diagnosticCode = diagnosticCode
        self.canRetry = canRetry
    }
}

public struct ManagedRuntimeReadyState: Equatable, Sendable {
    public let generationID: RuntimeGenerationID
    public let profileID: String

    public init(generationID: RuntimeGenerationID, profileID: String) {
        self.generationID = generationID
        self.profileID = profileID
    }
}

public enum ManagedRuntimeInstallationState: Equatable, Sendable {
    case notInstalled
    case detecting
    case available(ManagedRuntimeInstallOffer)
    case preparing(ManagedRuntimeInstallOffer)
    case downloading(ManagedRuntimeProgressDetail)
    case verifying(ManagedRuntimeProgressDetail)
    case extracting(ManagedRuntimeProgressDetail)
    case installing(ManagedRuntimeProgressDetail)
    case validating(ManagedRuntimeProgressDetail)
    case activating(ManagedRuntimeProgressDetail)
    case ready(ManagedRuntimeReadyState)
    case updateAvailable(
        current: ManagedRuntimeReadyState,
        offer: ManagedRuntimeInstallOffer
    )
    case cancelling
    case cancelled
    case repairing(ManagedRuntimeInstallOffer)
    case damaged(ManagedRuntimeInstallFailure, ManagedRuntimeInstallOffer?)
    case incompatible(ManagedRuntimeInstallFailure)
    case failed(ManagedRuntimeInstallFailure, ManagedRuntimeInstallOffer?)

    public var isBusy: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .extracting, .installing,
             .validating, .activating, .cancelling, .repairing:
            return true
        default:
            return false
        }
    }

    public var progress: Double? {
        switch self {
        case .downloading(let detail):
            return detail.fractionCompleted
        case .ready:
            return 1
        default:
            return nil
        }
    }
}

public enum ManagedRuntimeProductError: LocalizedError, Equatable {
    case defaultProfileMissing
    case profileUnavailable(String)
    case licenseAcceptanceRequired
    case installationCancelled
    case purityGateFailed

    public var errorDescription: String? {
        switch self {
        case .defaultProfileMissing:
            return "No default managed Android Runtime profile is available"
        case .profileUnavailable(let reason):
            return "The managed Android Runtime profile is unavailable: \(reason)"
        case .licenseAcceptanceRequired:
            return "The Android compatibility component licenses must be accepted"
        case .installationCancelled:
            return "The managed Android Runtime installation was cancelled"
        case .purityGateFailed:
            return "The managed Android Runtime failed its environment purity gate"
        }
    }
}

public struct ManagedRuntimeSelection: Equatable, Sendable {
    public let generationID: RuntimeGenerationID
    public let sdkRoot: URL
    public let javaHome: URL
    public let java: URL
    public let sdkManager: URL
    public let avdManager: URL
    public let adb: URL
    public let emulator: URL
    public let systemImage: URL
    public let systemImagePackageID: String
    public let environment: [String: String]
    public let purity: RuntimePurityReport

    public static func resolve(
        layout: AndroidRuntimeLayout,
        catalog: RuntimeCatalog,
        privateADBServerPort: Int = 50_437
    ) throws -> ManagedRuntimeSelection {
        let report = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        guard report.status == .ready,
              let generationID = report.activeGenerationID,
              let descriptor = catalog.generations.first(where: {
                  $0.generationID == generationID
              }),
              let packageID = descriptor.systemImagePackageID else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "active generation is not ready"
            )
        }
        let generation = layout.generation(generationID)
        let java = generation.jre.appendingPathComponent("bin/java")
        let sdkManager = generation.sdk.appendingPathComponent(
            "cmdline-tools/latest/bin/sdkmanager"
        )
        let avdManager = generation.sdk.appendingPathComponent(
            "cmdline-tools/latest/bin/avdmanager"
        )
        let adb = generation.sdk.appendingPathComponent("platform-tools/adb")
        let emulator = generation.sdk.appendingPathComponent(
            "emulator/emulator"
        )
        let imagePath = packageID.split(separator: ";").map(String.init)
        guard imagePath.count == 4,
              imagePath[0] == "system-images",
              imagePath.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "the managed system image identity is invalid"
            )
        }
        let systemImage = imagePath.reduce(generation.sdk) { partial, item in
            partial.appendingPathComponent(item, isDirectory: true)
        }
        let requiredExecutables = [java, sdkManager, avdManager, adb, emulator]
        guard requiredExecutables.allSatisfy({
            FileManager.default.isExecutableFile(atPath: $0.path)
        }), FileManager.default.fileExists(atPath: systemImage.path) else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "a required managed executable is missing"
            )
        }
        let privatePaths = [
            generation.jre.appendingPathComponent("bin").path,
            generation.sdk.appendingPathComponent(
                "cmdline-tools/latest/bin"
            ).path,
            generation.sdk.appendingPathComponent("platform-tools").path,
            generation.sdk.appendingPathComponent("emulator").path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ].joined(separator: ":")
        let environment = [
            "JAVA_HOME": generation.jre.path,
            "ANDROID_HOME": generation.sdk.path,
            "ANDROID_SDK_ROOT": generation.sdk.path,
            "ANDROID_AVD_HOME": layout.avdHome.path,
            "ANDROID_USER_HOME": layout.privateAndroidHome.path,
            "ANDROID_EMULATOR_HOME": layout.privateAndroidHome.path,
            "ADB_VENDOR_KEYS": layout.privateADBKey.path,
            "ANDROID_ADB_SERVER_PORT": "\(privateADBServerPort)",
            "HOME": layout.privateHome.path,
            "PATH": privatePaths,
            "LANG": "C",
            "LC_ALL": "C"
        ]
        let snapshot = ManagedRuntimeEnvironmentSnapshot(
            generationID: generationID,
            java: java,
            sdkManager: sdkManager,
            avdManager: avdManager,
            adb: adb,
            emulator: emulator,
            systemImage: systemImage,
            avd: layout.avdDirectory,
            adbKey: layout.privateADBKey,
            environment: environment,
            expectedPrivateADBServerPort: privateADBServerPort,
            actualADBServerPort: nil,
            adbServerOwned: false
        )
        let purity = ManagedRuntimePurityChecker(layout: layout).evaluate(
            snapshot,
            requireRunningADBServer: false
        )
        guard purity.passed else {
            throw ManagedRuntimeProductError.purityGateFailed
        }
        return ManagedRuntimeSelection(
            generationID: generationID,
            sdkRoot: generation.sdk,
            javaHome: generation.jre,
            java: java,
            sdkManager: sdkManager,
            avdManager: avdManager,
            adb: adb,
            emulator: emulator,
            systemImage: systemImage,
            systemImagePackageID: packageID,
            environment: environment,
            purity: purity
        )
    }
}

public struct ManagedRuntimeDiagnosticReport: Codable, Equatable, Sendable {
    public let catalogVersion: String
    public let catalogRevision: Int?
    public let profileID: String?
    public let profileStatus: String?
    public let detectionStatus: RuntimeDetectionStatus
    public let activeGenerationID: String?
    public let runtimeSchema: Int?
    public let avdSchema: Int?
    public let bridgeSchema: Int?
    public let apiLevel: Int?
    public let systemImageABI: String?
    public let componentVersions: [String: String]
    public let purity: RuntimePurityReport?
    public let avdStatus: String
    public let avdManifestSchema: Int?
    public let installedAVDSchema: Int?
    public let avdPathManaged: Bool
    public let installationPhase: String
    public let installationFailureCode: String?
    public let transactionID: String?
    public let transactionPhase: RuntimeInstallationPhase?
    public let transactionComponentID: String?
    public let transactionFailure: String?
    public let availableDiskBytes: Int64?
    public let requiredDiskBytes: Int64?
}

/// Product-level installation coordinator. Its task admission is separate from
/// AndroidDexBridgeRuntime's Emulator startup admission. A Dex request can
/// suspend here while the user accepts and installs, then continue in place.
public actor AndroidManagedRuntimeManager {
    public let layout: AndroidRuntimeLayout
    public let catalog: RuntimeCatalog

    private let downloader: any RuntimeArtifactDownloading
    private let materializer: any RuntimeComponentMaterializing
    private let validator: any StagedRuntimeValidating
    private let currentAppVersion: String
    private var state: ManagedRuntimeInstallationState = .detecting
    private var stateContinuations: [
        UUID: AsyncStream<ManagedRuntimeInstallationState>.Continuation
    ] = [:]
    private var dexWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private struct InstallationFlight: Sendable {
        let id: UUID
        let offer: ManagedRuntimeInstallOffer
        let task: Task<ManagedRuntimeReadyState, Error>
    }
    private var installationFlight: InstallationFlight?
    private var licensesAccepted = false

    public init(
        applicationSupportDirectory: URL,
        catalog: RuntimeCatalog,
        downloader: any RuntimeArtifactDownloading,
        currentAppVersion: String = "0.0.0",
        materializer: any RuntimeComponentMaterializing =
            ArchiveRuntimeComponentMaterializer(),
        validator: any StagedRuntimeValidating =
            DefaultStagedRuntimeValidator()
    ) {
        layout = AndroidRuntimeLayout(
            applicationSupportDirectory: applicationSupportDirectory
        )
        self.catalog = catalog
        self.downloader = downloader
        self.currentAppVersion = currentAppVersion
        self.materializer = materializer
        self.validator = validator
    }

    public static func live(
        applicationSupportDirectory: URL
    ) throws -> AndroidManagedRuntimeManager {
        let catalog = try BundledRuntimeCatalog.load()
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        return AndroidManagedRuntimeManager(
            applicationSupportDirectory: applicationSupportDirectory,
            catalog: catalog,
            downloader: URLSessionRuntimeArtifactDownloader(
                allowedHosts: Set(catalog.allowedDownloadHosts ?? [])
            ),
            currentAppVersion: appVersion
        )
    }

    public func states() -> AsyncStream<ManagedRuntimeInstallationState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    public func currentState() -> ManagedRuntimeInstallationState { state }

    @discardableResult
    public func refresh() throws -> ManagedRuntimeInstallationState {
        guard installationFlight == nil else { return state }
        switch state {
        case .available, .failed, .cancelled:
            return state
        default:
            break
        }
        let detection = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        if detection.status == .ready,
           let generationID = detection.activeGenerationID,
           let profile = catalog.profiles?.first(where: {
               $0.generationID == generationID
           }) {
            _ = try ManagedRuntimeSelection.resolve(
                layout: layout,
                catalog: catalog
            )
            let ready = ManagedRuntimeReadyState(
                generationID: generationID,
                profileID: profile.id
            )
            if let defaultProfile = catalog.defaultProfile,
               defaultProfile.generationID != generationID {
                publish(.updateAvailable(
                    current: ready,
                    offer: try offer(for: defaultProfile)
                ))
            } else {
                publish(.ready(ready))
            }
        } else if detection.status == .notInstalled
                    || detection.status == .legacyManagedLayout {
            publish(.notInstalled)
        } else if detection.status == .incompatible {
            publish(.incompatible(ManagedRuntimeInstallFailure(
                code: .compatibility,
                title: "Android 兼容组件与当前版本不兼容",
                message: "可以安装与当前 OKVideoMac 匹配的兼容组件，现有用户数据不会被删除。",
                diagnosticCode: "managed-runtime-incompatible",
                canRetry: true
            )))
        } else {
            let offer = try defaultOffer()
            publish(.damaged(
                ManagedRuntimeInstallFailure(
                    code: .invalidInstallation,
                    title: "Android 兼容组件需要修复",
                    message: "已安装的运行环境不完整，可以保留用户数据并重新安装组件。",
                    diagnosticCode: "managed-runtime-\(detection.status.rawValue)",
                    canRetry: true
                ),
                offer
            ))
        }
        return state
    }

    public func presentInstallOffer() throws {
        if (try? ManagedRuntimeSelection.resolve(
            layout: layout,
            catalog: catalog
        )) != nil {
            _ = try refresh()
            return
        }
        let detection = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        if detection.status == .notInstalled
            || detection.status == .legacyManagedLayout {
            publish(.available(try defaultOffer()))
        } else {
            _ = try refreshFromDetectionFailure(detection)
        }
    }

    public func ensureReadyForDex() async throws {
        if (try? ManagedRuntimeSelection.resolve(
            layout: layout,
            catalog: catalog
        )) != nil {
            _ = try refresh()
            return
        }
        if let flight = installationFlight {
            try await awaitInstallation(flight)
            return
        }
        let offer = try defaultOffer()
        publish(.available(offer))
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                dexWaiters[id] = continuation
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelDexWaiter(id) }
        })
    }

    public func installDefault(acceptingLicenses: Bool) async throws {
        guard acceptingLicenses else {
            throw ManagedRuntimeProductError.licenseAcceptanceRequired
        }
        licensesAccepted = true
        let flight: InstallationFlight
        if let existing = installationFlight {
            flight = existing
        } else {
            let offer = try defaultOffer()
            publish(.preparing(offer))
            let id = UUID()
            let installer = makeInstaller(attemptID: id)
            let task = Task {
                _ = try await installer.install(
                    generationID: offer.generationID
                )
                let selection = try ManagedRuntimeSelection.resolve(
                    layout: layout,
                    catalog: catalog
                )
                return ManagedRuntimeReadyState(
                    generationID: selection.generationID,
                    profileID: offer.profileID
                )
            }
            flight = InstallationFlight(id: id, offer: offer, task: task)
            installationFlight = flight
        }
        try await awaitInstallation(flight)
    }

    private func awaitInstallation(_ flight: InstallationFlight) async throws {
        do {
            let ready = try await flight.task.value
            guard installationFlight?.id == flight.id else { return }
            installationFlight = nil
            // Resolve again on the actor before publishing readiness. This is
            // the product boundary that every joined caller waits through.
            _ = try ManagedRuntimeSelection.resolve(
                layout: layout,
                catalog: catalog
            )
            publish(.ready(ready))
            resumeDexWaiters(with: .success(()))
        } catch {
            guard installationFlight?.id == flight.id else { throw error }
            installationFlight = nil
            let failure = Self.failure(from: error)
            publish(error is CancellationError
                ? .cancelled
                : .failed(failure, flight.offer))
            resumeDexWaiters(with: .failure(error))
            throw error
        }
    }

    public func cancel() async {
        if installationFlight != nil {
            publish(.cancelling)
            await makeInstaller().cancelInstallation()
        } else {
            publish(.cancelled)
            resumeDexWaiters(with: .failure(
                ManagedRuntimeProductError.installationCancelled
            ))
        }
    }

    public func repair(acceptingLicenses: Bool) async throws {
        guard acceptingLicenses || licensesAccepted else {
            throw ManagedRuntimeProductError.licenseAcceptanceRequired
        }
        let offer = try defaultOffer()
        publish(.repairing(offer))
        let generation = layout.generation(offer.generationID)
        var backup: URL?
        let previousPointer = try? Data(
            contentsOf: layout.currentRuntimePointer
        )
        if FileManager.default.fileExists(atPath: generation.root.path) {
            try FileManager.default.createDirectory(
                at: layout.backups,
                withIntermediateDirectories: true
            )
            let value = layout.backups.appendingPathComponent(
                "\(offer.generationID.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            let boundary = try ManagedRuntimePathBoundary(root: layout.root)
            _ = try boundary.validateMutationTarget(generation.root)
            _ = try boundary.validateMutationTarget(value)
            try FileManager.default.moveItem(at: generation.root, to: value)
            backup = value
        }
        do {
            try await installDefault(acceptingLicenses: true)
        } catch {
            if let backup {
                let boundary = try? ManagedRuntimePathBoundary(
                    root: layout.root
                )
                if FileManager.default.fileExists(atPath: generation.root.path),
                   (try? boundary?.validateMutationTarget(
                       generation.root
                   )) != nil {
                    try? FileManager.default.removeItem(at: generation.root)
                }
                if !FileManager.default.fileExists(
                    atPath: generation.root.path
                ) {
                    try? FileManager.default.moveItem(
                        at: backup,
                        to: generation.root
                    )
                }
                if let previousPointer {
                    try? previousPointer.write(
                        to: layout.currentRuntimePointer,
                        options: .atomic
                    )
                }
            }
            throw error
        }
    }

    public func diagnosticReport() -> ManagedRuntimeDiagnosticReport {
        let detection = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        let profile = detection.activeGenerationID.flatMap { id in
            catalog.profiles?.first { $0.generationID == id }
        } ?? catalog.defaultProfile
        let descriptor = detection.activeGenerationID.flatMap { id in
            catalog.generations.first { $0.generationID == id }
        }
        let transaction = try? JSONDecoder().decode(
            RuntimeInstallationTransaction.self,
            from: Data(contentsOf: layout.installationTransaction)
        )
        let purity = try? ManagedRuntimeSelection.resolve(
            layout: layout,
            catalog: catalog
        ).purity
        let components = detection.generationManifest?.components.reduce(
            into: [String: String]()
        ) { result, component in
            result[component.role.rawValue] = component.version
        } ?? [:]
        let available = try? layout.root.deletingLastPathComponent()
            .resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]).volumeAvailableCapacityForImportantUsage
        let avdData = try? Data(contentsOf: layout.avdManifest)
        let avdManifest = avdData.flatMap {
            try? JSONDecoder().decode(ManagedAVDManifest.self, from: $0)
        }
        let avdExists = FileManager.default.fileExists(
            atPath: layout.avdDirectory.path
        )
        let expectedImageID = descriptor?.components.first(where: {
            $0.role == .systemImage
        })?.id
        let avdStatus: String
        if !avdExists {
            avdStatus = "notCreated"
        } else if avdData == nil {
            avdStatus = "untracked"
        } else if avdManifest == nil {
            avdStatus = "manifestUnreadable"
        } else if let avdManifest, let descriptor, let expectedImageID {
            avdStatus = ManagedAVDCompatibility.evaluate(
                hasExistingAVD: true,
                manifest: avdManifest,
                expectedGeneration: descriptor,
                expectedSystemImageComponentID: expectedImageID,
                configurationMatchesExpectedImage: true
            ).status.rawValue
        } else {
            avdStatus = "runtimeUnavailable"
        }
        let imageABI = descriptor?.systemImagePackageID?
            .split(separator: ";").last.map(String.init)
        let avdManaged = (try? ManagedRuntimePathBoundary(root: layout.root))?
            .contains(layout.avdDirectory) ?? false
        return ManagedRuntimeDiagnosticReport(
            catalogVersion: catalog.catalogVersion,
            catalogRevision: catalog.catalogRevision,
            profileID: profile?.id,
            profileStatus: profile?.status.rawValue,
            detectionStatus: detection.status,
            activeGenerationID: detection.activeGenerationID?.rawValue,
            runtimeSchema: detection.generationManifest?.runtimeSchema,
            avdSchema: detection.generationManifest?.avdSchema,
            bridgeSchema: detection.generationManifest?.bridgeSchema,
            apiLevel: descriptor?.apiLevel,
            systemImageABI: imageABI,
            componentVersions: components,
            purity: purity,
            avdStatus: avdStatus,
            avdManifestSchema: avdManifest?.schemaVersion,
            installedAVDSchema: avdManifest?.avdSchema,
            avdPathManaged: avdManaged,
            installationPhase: Self.phaseName(state),
            installationFailureCode: Self.failureCode(state),
            transactionID: transaction?.transactionID,
            transactionPhase: transaction?.phase,
            transactionComponentID: transaction?.componentID,
            transactionFailure: transaction?.failure,
            availableDiskBytes: available ?? nil,
            requiredDiskBytes: profile?.requiredFreeSpace
        )
    }

    private func makeInstaller(attemptID: UUID? = nil) -> AndroidRuntimeInstaller {
        AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: downloader,
            materializer: materializer,
            validator: validator
        ) { [weak self] progress in
            Task { await self?.apply(progress, attemptID: attemptID) }
        }
    }

    private func apply(
        _ progress: RuntimeInstallationProgress,
        attemptID: UUID?
    ) {
        if let attemptID, installationFlight?.id != attemptID { return }
        let detail = ManagedRuntimeProgressDetail(progress)
        switch progress.phase {
        case .preparing: publish((try? defaultOffer()).map {
            .preparing($0)
        } ?? state)
        case .downloading: publish(.downloading(detail))
        case .verifying: publish(.verifying(detail))
        case .staging: publish(.extracting(detail))
        case .validating: publish(.validating(detail))
        case .committing: publish(.installing(detail))
        case .activating: publish(.activating(detail))
        case .completed, .failed, .cancelled:
            break
        }
    }

    private func defaultOffer() throws -> ManagedRuntimeInstallOffer {
        guard let profile = catalog.defaultProfile,
              let generation = catalog.generations.first(where: {
                  $0.generationID == profile.generationID
              }) else {
            throw ManagedRuntimeProductError.defaultProfileMissing
        }
        return try offer(for: profile, generation: generation)
    }

    private func offer(
        for profile: RuntimeProfile,
        generation suppliedGeneration: RuntimeGenerationDescriptor? = nil
    ) throws -> ManagedRuntimeInstallOffer {
        guard let generation = suppliedGeneration ?? catalog.generations
            .first(where: { $0.generationID == profile.generationID }) else {
            throw ManagedRuntimeProductError.defaultProfileMissing
        }
        #if arch(arm64)
        let architecture = RuntimeHostArchitecture.arm64
        #elseif arch(x86_64)
        let architecture = RuntimeHostArchitecture.x86_64
        #else
        throw ManagedRuntimeProductError.profileUnavailable(
            "unsupported architecture"
        )
        #endif
        guard profile.status != .unsupported,
              profile.architectures.contains(architecture),
              generation.architecture == architecture else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "unsupported architecture"
            )
        }
        let actual = ProcessInfo.processInfo.operatingSystemVersion
        let actualVersion = "\(actual.majorVersion).\(actual.minorVersion).\(actual.patchVersion)"
        guard actualVersion.compare(
            profile.minimumMacOS,
            options: .numeric
        ) != .orderedAscending else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "requires macOS \(profile.minimumMacOS)"
            )
        }
        guard Self.version(currentAppVersion, isAtLeast: profile.minimumAppVersion),
              Self.version(currentAppVersion, isAtLeast: generation.minimumAppVersion),
              profile.maximumAppVersion.map({
                  Self.version(currentAppVersion, isAtMost: $0)
              }) ?? true,
              generation.maximumAppVersion.map({
                  Self.version(currentAppVersion, isAtMost: $0)
              }) ?? true else {
            throw ManagedRuntimeProductError.profileUnavailable(
                "not compatible with OKVideoMac \(currentAppVersion)"
            )
        }
        var seen = Set<String>()
        let licenses = generation.components.compactMap { component
            -> ManagedRuntimeLicense? in
            guard seen.insert(component.licenseID).inserted else { return nil }
            return ManagedRuntimeLicense(
                id: component.licenseID,
                title: component.vendor == "Google"
                    ? "Android SDK License"
                    : "Azul Zulu OpenJDK License",
                url: component.licenseURL
            )
        }
        return ManagedRuntimeInstallOffer(
            profileID: profile.id,
            generationID: profile.generationID,
            displayName: profile.displayName,
            downloadBytes: profile.expectedDownloadSize,
            requiredFreeSpace: profile.requiredFreeSpace,
            licenses: licenses,
            verificationNote: profile.verificationNote
        )
    }

    @discardableResult
    private func refreshFromDetectionFailure(
        _ detection: RuntimeDetectionReport
    ) throws -> ManagedRuntimeInstallationState {
        if detection.status == .incompatible {
            publish(.incompatible(ManagedRuntimeInstallFailure(
                code: .compatibility,
                title: "Android 兼容组件与当前版本不兼容",
                message: "可以安装与当前 OKVideoMac 匹配的兼容组件，现有用户数据不会被删除。",
                diagnosticCode: "managed-runtime-incompatible",
                canRetry: true
            )))
        } else {
            publish(.damaged(
                ManagedRuntimeInstallFailure(
                    code: .invalidInstallation,
                    title: "Android 兼容组件需要修复",
                    message: "已安装的运行环境不完整，可以保留用户数据并重新安装组件。",
                    diagnosticCode: "managed-runtime-\(detection.status.rawValue)",
                    canRetry: true
                ),
                try? defaultOffer()
            ))
        }
        return state
    }

    private static func version(
        _ lhs: String,
        isAtLeast rhs: String
    ) -> Bool {
        lhs.compare(rhs, options: .numeric) != .orderedAscending
    }

    private static func version(
        _ lhs: String,
        isAtMost rhs: String
    ) -> Bool {
        lhs.compare(rhs, options: .numeric) != .orderedDescending
    }

    private func publish(_ newState: ManagedRuntimeInstallationState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func cancelDexWaiter(_ id: UUID) {
        dexWaiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func resumeDexWaiters(with result: Result<Void, Error>) {
        let waiters = dexWaiters.values
        dexWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private static func failure(from error: Error) -> ManagedRuntimeInstallFailure {
        if error is CancellationError {
            return ManagedRuntimeInstallFailure(
                code: .cancelled,
                title: "已取消安装",
                message: "下次使用需要 Android 的内容时可以继续。",
                diagnosticCode: "installation-cancelled",
                canRetry: true
            )
        }
        if let installation = error as? RuntimeInstallationError {
            let code: ManagedRuntimeFailureCode
            switch installation {
            case .insufficientDiskSpace: code = .diskSpace
            case .artifactHashMismatch, .downloadSizeMismatch:
                code = .integrity
            case .minimumMacOSNotMet, .unsupportedHostArchitecture:
                code = .compatibility
            case .invalidDownloadResponse, .downloadDidNotProduceArtifact:
                code = .network
            default: code = .invalidInstallation
            }
            return ManagedRuntimeInstallFailure(
                code: code,
                title: "Android 兼容组件安装失败",
                message: Self.userMessage(for: code),
                diagnosticCode: "runtime-installation-\(code.rawValue)",
                canRetry: true
            )
        }
        if error is RuntimeCatalogValidationError {
            return ManagedRuntimeInstallFailure(
                code: .invalidCatalog,
                title: "Android 兼容组件暂不可用",
                message: "安装清单未通过安全校验，应用没有下载或修改任何运行环境。",
                diagnosticCode: "catalog-validation-failed",
                canRetry: false
            )
        }
        if error is URLError {
            return ManagedRuntimeInstallFailure(
                code: .network,
                title: "Android 兼容组件下载失败",
                message: Self.userMessage(for: .network),
                diagnosticCode: "runtime-installation-network",
                canRetry: true
            )
        }
        return ManagedRuntimeInstallFailure(
            code: .internalFailure,
            title: "Android 兼容组件安装失败",
            message: "安装没有生效，原有运行环境保持不变。请重试或导出诊断。",
            diagnosticCode: "installation-internal-failure",
            canRetry: true
        )
    }

    private static func userMessage(
        for code: ManagedRuntimeFailureCode
    ) -> String {
        switch code {
        case .network:
            return "下载未完成，已保留可继传的部分文件。请检查网络后重试。"
        case .integrity:
            return "下载文件未通过完整性校验，未安装该文件。请重试。"
        case .diskSpace:
            return "可用磁盘空间不足。释放空间后可以继续安装。"
        case .compatibility:
            return "这台 Mac 不满足当前 Android 兼容组件的系统要求。"
        default:
            return "安装没有生效，原有运行环境保持不变。请重试或导出诊断。"
        }
    }

    private static func phaseName(
        _ state: ManagedRuntimeInstallationState
    ) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .detecting: return "detecting"
        case .available: return "available"
        case .preparing: return "preparing"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .extracting: return "extracting"
        case .installing: return "installing"
        case .validating: return "validating"
        case .activating: return "activating"
        case .ready: return "ready"
        case .updateAvailable: return "updateAvailable"
        case .cancelling: return "cancelling"
        case .cancelled: return "cancelled"
        case .repairing: return "repairing"
        case .damaged: return "damaged"
        case .incompatible: return "incompatible"
        case .failed: return "failed"
        }
    }

    private static func failureCode(
        _ state: ManagedRuntimeInstallationState
    ) -> String? {
        switch state {
        case .failed(let failure, _), .damaged(let failure, _),
             .incompatible(let failure):
            return failure.diagnosticCode
        default:
            return nil
        }
    }
}
