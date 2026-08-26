import Foundation
import OKVideoCore
import OKVideoPersistence

struct AppEnvironment {
    let directories: AppDirectories
    let httpClient: URLSessionHTTPClient
    let configurationLoader: ConfigurationLoader
    let liveSourceLoader: LiveSourceLoader
    let database: SQLiteStore
    let recoveredDatabaseDirectory: URL?
    let epgService: XMLTVService
    let spiderRuntimeFactory: SpiderRuntimeFactory?
    let nodeBundleRuntime: NodeBundleRuntimeService
    let androidDexBridge: AndroidDexBridgeClient
    let player: PlayerLifecycleController
    let imageRepository: ImageRepository

    @MainActor
    static func live() throws -> AppEnvironment {
        let directories = try runtimeDirectories()
        let httpClient = URLSessionHTTPClient()
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
        return AppEnvironment(
            directories: directories,
            httpClient: httpClient,
            configurationLoader: ConfigurationLoader(httpClient: httpClient),
            liveSourceLoader: LiveSourceLoader(httpClient: httpClient),
            database: databaseResult.store,
            recoveredDatabaseDirectory: databaseResult.quarantinedDatabaseDirectory,
            epgService: try XMLTVService(
                httpClient: httpClient,
                cacheDirectory: directories.caches.appendingPathComponent(
                    "EPG",
                    isDirectory: true
                )
            ),
            spiderRuntimeFactory: try? QuickJSSpiderRuntimeFactory(),
            nodeBundleRuntime: NodeBundleRuntimeService(
                applicationSupportDirectory: directories.applicationSupport,
                cacheDirectory: directories.caches,
                remoteHTTPClient: httpClient
            ),
            androidDexBridge: AndroidDexBridgeClient(
                runtime: AndroidDexBridgeRuntime(
                    applicationSupportDirectory: directories.applicationSupport
                )
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
