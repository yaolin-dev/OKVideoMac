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
    let player: PlayerClient
    let imageRepository: ImageRepository

    static func live() throws -> AppEnvironment {
        let directories = try AppDirectories()
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
        let player: PlayerClient
        do {
            player = try MPVPlayerClient()
        } catch {
            player = UnavailablePlayerClient(
                reason: "libmpv 不可用：\(LogRedactor.text(error.localizedDescription))"
            )
        }
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
            androidDexBridge: AndroidDexBridgeClient(),
            player: player,
            imageRepository: try ImageRepository(
                cacheDirectory: directories.caches.appendingPathComponent(
                    "Posters",
                    isDirectory: true
                ),
                httpClient: imageHTTPClient
            )
        )
    }
}
