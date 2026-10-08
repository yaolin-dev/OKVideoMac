import Foundation

/// A recoverable transaction for the private AVD and its identity metadata.
/// The caller must hold the maintenance lease and prove that the AVD is stopped.
/// No process records or private ADB keys are restored by this transaction.
public struct PrivateAVDRebuildStore {
    public struct Backup: Equatable, Sendable {
        public let directory: URL
        public let movedItemNames: [String]
        public let metadataItemNames: [String]
    }

    private struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }
    private struct Journal: Codable {
        enum Phase: String, Codable { case backingUp, creating, committed }
        let schema: Int
        let backupName: String
        let originals: [String: Identity]
        var phase: Phase
    }

    // Fixed paths only; journal content can never select arbitrary user files.
    static let paths = [
        "avd/OKVideoMac_Runtime.avd", "avd/OKVideoMac_Runtime.ini",
        "avd/avd-manifest.json", "avd/runtime-compatibility.json",
        "runtime-continuity.json"
    ]
    static let metadataNames = Set([
        "runtime-manifest.json", "runtime-continuity.json", "runtime-profile.json"
    ])
    private let layout: AndroidRuntimeLayout
    private let fileManager: FileManager
    // Tests inject filesystem faults before real moves, including rollback.
    var beforeMove: ((URL, URL) throws -> Void)?

    public init(layout: AndroidRuntimeLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public var journalURL: URL { layout.root.appendingPathComponent("avd-rebuild.json") }
    public var hasPendingTransaction: Bool {
        (try? fileManager.attributesOfItem(atPath: journalURL.path)) != nil
    }

    public func requireNoPendingTransaction() throws {
        if hasPendingTransaction { throw RuntimeMaintenanceError.pendingRecovery }
    }

    public func begin(
        now: Date = Date(), identifier: String = UUID().uuidString,
        metadataSnapshots: [String: Data] = [:]
    ) throws -> Backup {
        try requireNoPendingTransaction()
        try validatePaths()
        let originals = try Dictionary(uniqueKeysWithValues: Self.paths.compactMap { path in
            try identity(at: active(path)).map { (path, $0) }
        })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(8))
        let name = "OKVideoMac_Runtime-\(formatter.string(from: now))-\(suffix)"
        let backup = layout.backups.appendingPathComponent(name)
        try fileManager.createDirectory(at: layout.backups, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var journal = Journal(schema: 1, backupName: name, originals: originals, phase: .backingUp)
        try write(journal)
        let metadata = metadataSnapshots.filter { Self.metadataNames.contains($0.key) }
        do {
            for path in Self.paths where originals[path] != nil {
                try move(active(path), backup.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
            }
            for (name, data) in metadata.sorted(by: { $0.key < $1.key }) {
                let destination = backup.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
            }
            journal.phase = .creating
            try write(journal)
        } catch {
            do { try recover() }
            catch { throw RuntimeMaintenanceError.pendingRecovery }
            throw error
        }
        return Backup(directory: backup,
                      movedItemNames: originals.keys.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
                      metadataItemNames: metadata.keys.sorted())
    }

    /// Call only after config, fingerprint and Emulator AVD enumeration agree.
    /// Once committed, boot failures must not roll back a valid new environment.
    public func commit() throws {
        var journal = try read()
        guard journal.phase == .creating else { throw RuntimeMaintenanceError.changed }
        journal.phase = .committed
        try write(journal)
        try fileManager.removeItem(at: journalURL)
    }

    /// Idempotent after interruption at any move. Inode checks distinguish old
    /// data already restored from a partially created new AVD. New data is
    /// quarantined, never deleted. An ambiguous/missing original fails closed.
    public func recover() throws {
        guard hasPendingTransaction else { return }
        try validatePaths()
        let journal = try read()
        if journal.phase == .committed {
            try fileManager.removeItem(at: journalURL)
            return
        }
        let backup = layout.backups.appendingPathComponent(journal.backupName)
        let failed = backup.appendingPathComponent("FailedRebuild")
        // Validate every original before moving anything during recovery.
        for (path, original) in journal.originals {
            let archived = backup.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            guard try identity(at: active(path)) == original || identity(at: archived) == original else {
                throw RuntimeMaintenanceError.changed
            }
        }
        for path in Self.paths.reversed() {
            let source = active(path)
            let name = source.lastPathComponent
            let archived = backup.appendingPathComponent(name)
            let current = try identity(at: source)
            if let original = journal.originals[path], current == original { continue }
            if current != nil {
                guard journal.phase == .creating else { throw RuntimeMaintenanceError.changed }
                try fileManager.createDirectory(at: failed, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                try move(source, failed.appendingPathComponent(name))
            }
            if let original = journal.originals[path] {
                guard try identity(at: archived) == original else { throw RuntimeMaintenanceError.changed }
                try fileManager.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try move(archived, source)
            }
        }
        try fileManager.removeItem(at: journalURL)
    }

    private func active(_ path: String) -> URL { layout.root.appendingPathComponent(path) }

    private func identity(at url: URL) throws -> Identity? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard let kind = attributes[.type] as? FileAttributeType,
              kind == .typeDirectory || kind == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw RuntimeMaintenanceError.unsafePath
        }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private func validatePaths() throws {
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        for url in [journalURL, layout.backups] + Self.paths.map(active) {
            _ = try boundary.validateMutationTarget(url)
            // Do not follow even an in-root symlink for owned transaction paths.
            if let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink { throw RuntimeMaintenanceError.unsafePath }
        }
    }

    private func read() throws -> Journal {
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
        catch { throw RuntimeMaintenanceError.corruptJournal }
        guard journal.schema == 1, journal.backupName.hasPrefix("OKVideoMac_Runtime-"),
              journal.backupName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              Set(journal.originals.keys).isSubset(of: Set(Self.paths)) else {
            throw RuntimeMaintenanceError.corruptJournal
        }
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        let backup = layout.backups.appendingPathComponent(journal.backupName)
        for url in [backup, backup.appendingPathComponent("FailedRebuild")] {
            _ = try boundary.validateMutationTarget(url)
            if let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink { throw RuntimeMaintenanceError.unsafePath }
        }
        return journal
    }

    private func write(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func move(_ source: URL, _ destination: URL) throws {
        let boundary = try ManagedRuntimePathBoundary(root: layout.root)
        _ = try boundary.validateMutationTarget(source)
        _ = try boundary.validateMutationTarget(destination)
        try beforeMove?(source, destination)
        try fileManager.moveItem(at: source, to: destination)
    }
}
