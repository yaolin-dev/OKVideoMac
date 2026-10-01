import AppKit
import AndroidRuntimeKit
import Darwin
import Foundation
import OKVideoCore
import OKVideoPersistence
import Security

struct AppEnvironment {
    static func catPawSearchConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 20
        return configuration
    }
    let directories: AppDirectories
    let applicationInstanceLease: ApplicationInstanceLease
    let httpClient: URLSessionHTTPClient
    let aggregateSearchHTTPClient: URLSessionHTTPClient
    let xtreamHTTPClient: URLSessionHTTPClient
    let configurationLoader: ConfigurationLoader
    let liveSourceLoader: LiveSourceLoader
    let database: SQLiteStore
    let recoveredDatabaseDirectory: URL?
    let productionEPGRepository: EPGProductionRepository
    let spiderRuntimeFactory: SpiderRuntimeFactory?
    let nodeBundleRuntime: NodeBundleRuntimeService
    let androidRuntimeManager: AndroidManagedRuntimeManager
    let androidRuntimeModeCoordinator: AndroidRuntimeModeCoordinator
    let androidDexBridge: AndroidDexBridgeClient
    let player: PlayerLifecycleController
    let imageRepository: ImageRepository
    let xtreamCredentialStore: KeychainXtreamCredentialStore

    @MainActor
    static func live() throws -> AppEnvironment {
        let acceptance = try acceptanceWorkspace()
        let directories = try runtimeDirectories()
        let processEnvironment = ProcessInfo.processInfo.environment
        if !isXCTestHost(environment: processEnvironment) {
            try ApplicationInstancePolicy.rejectOtherRunningApplication(
                bundleIdentifier: Bundle.main.bundleIdentifier
                    ?? "com.okvideomac.OKVideoMac",
                currentProcessIdentifier:
                    ProcessInfo.processInfo.processIdentifier
            )
        }
        // This lease is acquired before SQLite is opened, migrated, verified,
        // or recovered. A forced second launch must never reach database code.
        let applicationInstanceLease = try ApplicationInstanceLease(
            lockURL: directories.applicationSupport.appendingPathComponent(
                ".instance.lock",
                isDirectory: false
            )
        )
        let interactiveHTTPClient = URLSessionHTTPClient()
        let aggregateSearchHTTPClient = URLSessionHTTPClient(configuration: Self.catPawSearchConfiguration())
        let xtreamHTTPClient = URLSessionHTTPClient.isolatedEphemeral()
        let imageConfiguration = URLSessionConfiguration.default
        imageConfiguration.httpMaximumConnectionsPerHost = 12
        imageConfiguration.timeoutIntervalForRequest = 15
        imageConfiguration.timeoutIntervalForResource = 20
        let imageHTTPClient = URLSessionHTTPClient(
            configuration: imageConfiguration
        )
        let databaseURL = directories.database.appendingPathComponent("OKVideoMac.sqlite3")
        let databaseResult: SQLiteStore.OpenResult
        if let acceptance {
            databaseResult = try .init(store: SQLiteStore(importedAcceptance: acceptance), quarantinedDatabaseDirectory: nil)
        } else {
            databaseResult = try SQLiteStore.openRecovering(databaseURL: databaseURL)
        }
        let player = PlayerLifecycleController(
            mode: PlayerTeardownMode.configured(),
            audioPreferences: PlaybackAudioPreferenceStore(defaults: .standard)
        )
        let androidRuntimeManager = try AndroidManagedRuntimeManager.live(
            applicationSupportDirectory: directories.applicationSupport
        )
        let runtimeLayout = AndroidRuntimeLayout(
            applicationSupportDirectory: directories.applicationSupport
        )
        let runtimeCatalog = try BundledRuntimeCatalog.load()
        let managedRuntimeUsable = (try? ManagedRuntimeSelection.resolve(
            layout: runtimeLayout,
            catalog: runtimeCatalog
        )) != nil
        let androidSession = AndroidDexBridgeRuntime(
            applicationSupportDirectory: directories.applicationSupport
        )
        let androidRuntimeModeCoordinator = try AndroidRuntimeModeCoordinator(
            store: AndroidRuntimeModeStore(
                applicationSupportDirectory: directories.applicationSupport
            ),
            layout: runtimeLayout,
            catalog: runtimeCatalog,
            externalValidator: ExternalAndroidRuntimeValidator(
                applicationSupportDirectory: directories.applicationSupport
            ),
            managedRuntimeUsableAtMigration: managedRuntimeUsable,
            managedUsability: {
                (try? ManagedRuntimeSelection.resolve(
                    layout: runtimeLayout,
                    catalog: runtimeCatalog
                )) != nil
            },
            ensureManagedReady: {
                try await androidRuntimeManager.ensureReadyForDex()
            },
            cancelManagedAdmission: {
                await androidRuntimeManager.cancel()
            },
            configureSession: { mode, externalSDKRoot in
                await androidSession.setRuntimeSelection(
                    mode: mode,
                    externalSDKRoot: externalSDKRoot
                )
            },
            sessionStatus: {
                await androidSession.status()
            }
        )
        let androidDexBridge = AndroidDexBridgeClient(
            runtime: androidSession,
            runtimePrerequisite: {
                try await androidRuntimeModeCoordinator.prepareRuntime()
            }
        )
        return AppEnvironment(
            directories: directories,
            applicationInstanceLease: applicationInstanceLease,
            httpClient: interactiveHTTPClient,
            aggregateSearchHTTPClient: aggregateSearchHTTPClient,
            xtreamHTTPClient: xtreamHTTPClient,
            configurationLoader: ConfigurationLoader(
                httpClient: interactiveHTTPClient
            ),
            liveSourceLoader: LiveSourceLoader(httpClient: interactiveHTTPClient),
            database: databaseResult.store,
            recoveredDatabaseDirectory: databaseResult.quarantinedDatabaseDirectory,
            productionEPGRepository: EPGProductionRepository(
                cacheDirectory: directories.caches.appendingPathComponent(
                    "EPGCache-v3",
                    isDirectory: true
                )
            ),
            spiderRuntimeFactory: try? QuickJSSpiderRuntimeFactory(),
            nodeBundleRuntime: NodeBundleRuntimeService(
                applicationSupportDirectory: directories.applicationSupport,
                cacheDirectory: directories.caches,
                remoteHTTPClient: interactiveHTTPClient
            ),
            androidRuntimeManager: androidRuntimeManager,
            androidRuntimeModeCoordinator: androidRuntimeModeCoordinator,
            androidDexBridge: androidDexBridge,
            player: player,
            imageRepository: ImageRepository(
                dataRepository: try ImageDataRepository(
                    cacheDirectory: directories.caches.appendingPathComponent(
                        "Posters",
                        isDirectory: true
                    ),
                    httpClient: imageHTTPClient
                )
            ),
            xtreamCredentialStore: KeychainXtreamCredentialStore(service: acceptance == nil
                ? KeychainXtreamCredentialStore.defaultService
                : "com.okvideomac.acceptance.8b3b.\(acceptance!.root.lastPathComponent)")
        )
    }

    /// Unit tests are hosted by the application executable, so constructing
    /// the SwiftUI app also constructs an AppState before the first test runs.
    /// Never let that test host open the user's real Application Support
    /// database. Each bootstrap receives an isolated directory so tests cannot
    /// race a concurrently running installed copy of OKVideoMac either.
    static func runtimeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        fileManager: FileManager = .default
    ) throws -> AppDirectories {
        if let acceptance = try acceptanceWorkspace(environment: environment) {
            return try AppDirectories(applicationSupport: acceptance.support, caches: acceptance.caches, fileManager: fileManager)
        }
        guard isXCTestHost(environment: environment) else {
            return try AppDirectories(fileManager: fileManager)
        }

        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "OKVideoMac-XCTest-\(processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        return try AppDirectories(
            applicationSupport: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            caches: root.appendingPathComponent("Caches", isDirectory: true),
            fileManager: fileManager
        )
    }

    static func isXCTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// A distinct bundle ID isolates UserDefaults, AppStorage, URLSession's
    /// system cache and saved window state without changing Player code.
    static func acceptanceWorkspace(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> ImportedAcceptanceWorkspace? {
        let candidate = bundleIdentifier == "com.okvideomac.OKVideoMac.acceptance8b3b"
        guard candidate || environment["OKVIDEOMAC_8B3B_ROOT"] != nil else { return nil }
        guard candidate, let path = environment["OKVIDEOMAC_8B3B_ROOT"], !path.isEmpty else {
            throw ImportedAcceptanceWorkspace.AcceptanceError.unsafeWorkspace
        }
        return try ImportedAcceptanceWorkspace(root: URL(fileURLWithPath: path))
    }
}

struct KeychainXtreamCredentialStore: XtreamCredentialStoring {
    static let defaultService = "com.okvideomac.OKVideoMac.xtream.credentials.v1"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func credentials(for providerID: UUID) async throws -> XtreamCredentials? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            itemQuery(
                providerID: providerID,
                additional: [
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
            ) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw XtreamCredentialStoreError.keychain(
                operation: "read",
                status: status
            )
        }
        guard let data = result as? Data else {
            throw XtreamCredentialStoreError.invalidStoredCredential
        }
        return try XtreamCredentialKeychainCodec.decode(data)
    }

    func save(
        _ credentials: XtreamCredentials,
        for providerID: UUID
    ) async throws {
        let data = try XtreamCredentialKeychainCodec.encode(credentials)
        let query = itemQuery(providerID: providerID)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw XtreamCredentialStoreError.keychain(
                operation: "update",
                status: updateStatus
            )
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "OKVideoMac Xtream account"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XtreamCredentialStoreError.keychain(
                operation: "create",
                status: addStatus
            )
        }
    }

    func deleteCredentials(for providerID: UUID) async throws {
        let status = SecItemDelete(itemQuery(providerID: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw XtreamCredentialStoreError.keychain(
                operation: "delete",
                status: status
            )
        }
    }

    private func itemQuery(
        providerID: UUID,
        additional: [String: Any] = [:]
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: providerID),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        query.merge(additional) { _, new in new }
        return query
    }

    static func account(for providerID: UUID) -> String {
        providerID.uuidString.lowercased()
    }
}

enum XtreamCredentialStoreError: Error, Equatable, LocalizedError {
    case keychain(operation: String, status: OSStatus)
    case invalidStoredCredential

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            return "The Xtream credential Keychain \(operation) failed (OSStatus \(status))."
        case .invalidStoredCredential:
            return "The saved Xtream credential is invalid."
        }
    }
}

enum XtreamCredentialKeychainCodec {
    private struct Payload: Codable {
        let version: Int
        let username: String
        let password: String
    }

    static func encode(_ credentials: XtreamCredentials) throws -> Data {
        try PropertyListEncoder().encode(
            Payload(
                version: 1,
                username: credentials.username,
                password: credentials.password
            )
        )
    }

    static func decode(_ data: Data) throws -> XtreamCredentials {
        let payload: Payload
        do {
            payload = try PropertyListDecoder().decode(Payload.self, from: data)
        } catch {
            throw XtreamCredentialStoreError.invalidStoredCredential
        }
        guard payload.version == 1 else {
            throw XtreamCredentialStoreError.invalidStoredCredential
        }
        return XtreamCredentials(
            username: payload.username,
            password: payload.password
        )
    }
}

enum ApplicationInstancePolicy {
    static func conflictingProcessIdentifier(
        currentProcessIdentifier: pid_t,
        runningProcessIdentifiers: [pid_t]
    ) -> pid_t? {
        runningProcessIdentifiers.first {
            $0 > 0 && $0 != currentProcessIdentifier
        }
    }

    @MainActor
    static func rejectOtherRunningApplication(
        bundleIdentifier: String,
        currentProcessIdentifier: pid_t
    ) throws {
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { !$0.isTerminated }
        guard let conflictPID = conflictingProcessIdentifier(
            currentProcessIdentifier: currentProcessIdentifier,
            runningProcessIdentifiers: runningApplications.map(
                \.processIdentifier
            )
        ) else {
            return
        }
        let conflictingApplication = runningApplications.first {
            $0.processIdentifier == conflictPID
        }
        let location = conflictingApplication?.bundleURL?.path
            ?? "PID \(conflictPID)"
        throw AppError.database(
            L10n.string(
                "app.instance.conflict",
                fallback: "Another OKVideoMac instance is running (%@). This instance did not open the shared database to protect your data. Close the older version or duplicate copy, then try again.",
                location
            )
        )
    }
}

/// Advisory process lease for the complete App Support runtime, retained by
/// AppEnvironment for the lifetime of the application. LaunchServices handles
/// ordinary duplicate launches; this also covers `open -n`, direct executable
/// launches and simultaneous startup races between current versions.
final class ApplicationInstanceLease {
    let lockURL: URL
    private var fileDescriptor: Int32

    init(lockURL: URL) throws {
        self.lockURL = lockURL
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.filesystemError(
                prefix: L10n.string("app.instance.lock-create.failed", fallback: "Unable to create the application instance lock"),
                code: errno
            )
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK {
                throw AppError.database(
                    L10n.string(
                        "app.instance.database-in-use",
                        fallback: "Another OKVideoMac instance is using the application database. This instance did not open it to protect your data."
                    )
                )
            }
            throw Self.filesystemError(
                prefix: L10n.string("app.instance.database-lock.failed", fallback: "Unable to lock the application database"),
                code: code
            )
        }
        fileDescriptor = descriptor
        _ = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
    }

    deinit {
        close()
    }

    func close() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func filesystemError(
        prefix: String,
        code: Int32
    ) -> AppError {
        let message = String(cString: strerror(code))
        return .filesystem(
            prefix
                + L10n.string("common.detail-separator", fallback: ": ")
                + message
        )
    }
}
