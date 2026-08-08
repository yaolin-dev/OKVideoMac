import Foundation

public struct AppDirectories: Equatable {
    public let applicationSupport: URL
    public let caches: URL
    public let database: URL
    public let configurations: URL
    public let diagnostics: URL

    public init(fileManager: FileManager = .default) throws {
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(
            applicationSupport: supportRoot.appendingPathComponent("OKVideoMac", isDirectory: true),
            caches: cacheRoot.appendingPathComponent("OKVideoMac", isDirectory: true),
            fileManager: fileManager
        )
    }

    public init(
        applicationSupport: URL,
        caches: URL,
        fileManager: FileManager = .default
    ) throws {
        self.applicationSupport = applicationSupport
        self.caches = caches
        database = applicationSupport.appendingPathComponent("Database", isDirectory: true)
        configurations = applicationSupport.appendingPathComponent("Configurations", isDirectory: true)
        diagnostics = applicationSupport.appendingPathComponent("Diagnostics", isDirectory: true)

        for directory in [applicationSupport, caches, database, configurations, diagnostics] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
