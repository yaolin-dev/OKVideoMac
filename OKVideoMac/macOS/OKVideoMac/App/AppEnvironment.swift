import AppKit
import AndroidRuntimeKit
import Darwin
import Foundation
import OKVideoCore
import OKVideoPersistence

struct AppEnvironment {
    let directories: AppDirectories
    let applicationInstanceLease: ApplicationInstanceLease
    let httpClient: URLSessionHTTPClient
    let aggregateSearchHTTPClient: URLSessionHTTPClient
    let configurationLoader: ConfigurationLoader
    let liveSourceLoader: LiveSourceLoader
    let database: SQLiteStore
    let recoveredDatabaseDirectory: URL?
    let epgService: XMLTVService
    let spiderRuntimeFactory: SpiderRuntimeFactory?
    let nodeBundleRuntime: NodeBundleRuntimeService
    let androidRuntimeManager: AndroidManagedRuntimeManager
    let androidDexBridge: AndroidDexBridgeClient
    let player: PlayerLifecycleController
    let imageRepository: ImageRepository

    @MainActor
    static func live() throws -> AppEnvironment {
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
        let aggregateSearchHTTPClient = URLSessionHTTPClient()
        let imageConfiguration = URLSessionConfiguration.default
        imageConfiguration.httpMaximumConnectionsPerHost = 12
        imageConfiguration.timeoutIntervalForRequest = 15
        imageConfiguration.timeoutIntervalForResource = 20
        let imageHTTPClient = URLSessionHTTPClient(
            configuration: imageConfiguration
        )
        let databaseURL = directories.database.appendingPathComponent("OKVideoMac.sqlite3")
        let databaseResult = try SQLiteStore.openRecovering(databaseURL: databaseURL)
        let player = PlayerLifecycleController(
            mode: PlayerTeardownMode.configured()
        )
        let androidRuntimeManager = try AndroidManagedRuntimeManager.live(
            applicationSupportDirectory: directories.applicationSupport
        )
        return AppEnvironment(
            directories: directories,
            applicationInstanceLease: applicationInstanceLease,
            httpClient: interactiveHTTPClient,
            aggregateSearchHTTPClient: aggregateSearchHTTPClient,
            configurationLoader: ConfigurationLoader(
                httpClient: interactiveHTTPClient
            ),
            liveSourceLoader: LiveSourceLoader(httpClient: interactiveHTTPClient),
            database: databaseResult.store,
            recoveredDatabaseDirectory: databaseResult.quarantinedDatabaseDirectory,
            epgService: try XMLTVService(
                httpClient: interactiveHTTPClient,
                cacheDirectory: directories.caches.appendingPathComponent(
                    "EPG",
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
            androidDexBridge: AndroidDexBridgeClient(
                runtime: AndroidDexBridgeRuntime(
                    applicationSupportDirectory: directories.applicationSupport
                ),
                managedRuntimePrerequisite: {
                    try await androidRuntimeManager.ensureReadyForDex()
                }
            ),
            player: player,
            imageRepository: ImageRepository(
                dataRepository: try ImageDataRepository(
                    cacheDirectory: directories.caches.appendingPathComponent(
                        "Posters",
                        isDirectory: true
                    ),
                    httpClient: imageHTTPClient
                )
            )
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
            "检测到另一个 OKVideoMac 实例正在运行（\(location)）。"
                + "为保护同一数据库，本实例没有打开数据库。"
                + "请关闭旧版本或重复副本后重试。"
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
                prefix: "无法创建应用实例锁",
                code: errno
            )
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK {
                throw AppError.database(
                    "另一个 OKVideoMac 实例正在使用应用数据库。"
                        + "为保护数据，本实例没有打开数据库。"
                )
            }
            throw Self.filesystemError(
                prefix: "无法锁定应用数据库",
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
        return .filesystem("\(prefix)：\(message)")
    }
}
