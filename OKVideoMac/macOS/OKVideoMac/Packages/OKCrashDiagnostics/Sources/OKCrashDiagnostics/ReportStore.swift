import Foundation
import Darwin
import CryptoKit

public final class ReportStore {
    public let root: URL
    public let pending: URL
    public let cache: URL
    public let rawArchive: URL
    let operationSnapshots: URL
    private let consentURL: URL
    private var lease: Int32 = -1
    private let lock = NSLock()
    private var consentValue = false
    public static let maxReports = 3
    public static let retention: TimeInterval = 7 * 86400

    public init(root: URL) throws {
        self.root = root; pending = root.appendingPathComponent("pending", isDirectory: true)
        cache = root.appendingPathComponent("sentry-cache", isDirectory: true)
        rawArchive = root.appendingPathComponent("native-archive", isDirectory: true)
        operationSnapshots = root.appendingPathComponent("operation-snapshots", isDirectory: true)
        consentURL = root.appendingPathComponent("consent.json")
        try Self.privateDirectory(root)
        lease = open(root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { close(lease); lease = -1 }
            throw CrashDiagnosticError.alreadyRunning
        }
        try Self.privateDirectory(pending)
        try Self.privateDirectory(rawArchive)
        try Self.privateDirectory(operationSnapshots)
        let consentSize = (try? consentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        consentValue = consentSize <= 4096 && (try? JSONDecoder().decode(Bool.self, from: Data(contentsOf: consentURL))) == true
        // The application owns retries through bounded, sanitized records. Never replay an SDK cache.
        try removeSDKCache()
        try prune()
    }
    deinit { if lease >= 0 { flock(lease, LOCK_UN); close(lease) } }
    public var consent: Bool { lock.lock(); defer { lock.unlock() }; return consentValue }
    public func setConsent(_ value: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        // Fail closed even if persisting a revocation fails.
        if !value { consentValue = false }
        try Self.write(JSONEncoder().encode(value), to: consentURL)
        consentValue = value
    }
    func saveOperations(_ operations: [CrashOperation], session: String) throws {
        guard UUID(uuidString: session)?.uuidString == session,
              operations.count <= CrashOperation.capacity, operations.allSatisfy(\.isValid) else {
            throw CrashDiagnosticError.invalidReport
        }
        let url = operationSnapshots.appendingPathComponent(session + ".json")
        let first = !FileManager.default.fileExists(atPath: url.path)
        let data = try JSONEncoder().encode(operations)
        guard data.count <= 65_536 else { throw CrashDiagnosticError.invalidReport }
        try Self.write(data, to: url)
        if first { try pruneOperations(now: Date()) }
    }
    func operations(session: String) -> [CrashOperation]? {
        guard UUID(uuidString: session)?.uuidString == session else { return nil }
        let url = operationSnapshots.appendingPathComponent(session + ".json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let data = try? Data(contentsOf: url),
              let operations = try? JSONDecoder().decode([CrashOperation].self, from: data),
              operations.count <= CrashOperation.capacity, operations.allSatisfy(\.isValid) else { return nil }
        return operations
    }
    private func pruneOperations(now: Date) throws {
        var valid: [(URL, Date)] = []
        for url in try FileManager.default.contentsOfDirectory(at: operationSnapshots, includingPropertiesForKeys: nil) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date <= now.addingTimeInterval(86400), now.timeIntervalSince(date) <= Self.retention,
               operations(session: url.deletingPathExtension().lastPathComponent) != nil {
                valid.append((url, date))
            } else { try FileManager.default.removeItem(at: url) }
        }
        for old in valid.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxReports) {
            try FileManager.default.removeItem(at: old.0)
        }
    }
    /// Local recovery only; this directory is never passed to the upload worker.
    public func archiveRaw(_ data: Data, now: Date = Date()) throws {
        guard !data.isEmpty, data.count <= CrashMapper.maxRawBytes else { throw CrashDiagnosticError.invalidReport }
        let id = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        try Self.write(data, to: rawArchive.appendingPathComponent(id + ".plcrash"))
        try pruneRawArchive(now: now)
    }
    private func pruneRawArchive(now: Date) throws {
        var valid: [(URL, Date)] = []
        for url in try FileManager.default.contentsOfDirectory(at: rawArchive, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber, size.intValue <= CrashMapper.maxRawBytes,
               let date = attributes[.modificationDate] as? Date,
               now.timeIntervalSince(date) <= Self.retention, date <= now.addingTimeInterval(86400) {
                valid.append((url, date))
            } else { try FileManager.default.removeItem(at: url) }
        }
        for old in valid.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxReports) {
            try FileManager.default.removeItem(at: old.0)
        }
    }
    public func save(_ record: CrashRecord) throws {
        guard record.isValid else { throw CrashDiagnosticError.invalidReport }
        let data = try JSONEncoder().encode(record)
        guard data.count <= CrashMapper.maxRecordBytes else { throw CrashDiagnosticError.invalidReport }
        try Self.write(data, to: file(record.id))
        try prune()
    }
    public func records() throws -> [CrashRecord] {
        try prune()
        return try files().compactMap { try? JSONDecoder().decode(CrashRecord.self, from: Data(contentsOf: $0)) }.sorted { $0.timestamp < $1.timestamp }
    }
    /// UI acknowledgement is separate from upload consent and HTTP acknowledgement.
    public func needsRecoveryPrompt() throws -> Bool {
        let url = root.appendingPathComponent("recovery-prompt.json")
        let data = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { size in
            size <= 4096 ? try? Data(contentsOf: url) : nil
        }
        let acknowledged = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let ids = Set(acknowledged.prefix(Self.maxReports))
        return try records().contains { !ids.contains($0.id) }
    }
    public func acknowledgeRecoveryPrompt() throws {
        try Self.write(JSONEncoder().encode(records().map(\.id)), to: root.appendingPathComponent("recovery-prompt.json"))
    }
    public func acknowledge(_ record: CrashRecord) throws { try FileManager.default.removeItem(at: file(record.id)) }
    public func discard() throws {
        for url in try files() { try FileManager.default.removeItem(at: url) }
        for directory in [rawArchive, operationSnapshots] {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func removeSDKCache() throws { if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) } }
    private func file(_ id: String) -> URL { pending.appendingPathComponent(id + ".json") }
    private func files() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" } }
    public func prune(now: Date = Date()) throws {
        try pruneRawArchive(now: now)
        try pruneOperations(now: now)
        var valid: [(URL, Date)] = []
        for url in try files() {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= CrashMapper.maxRecordBytes,
               let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(CrashRecord.self, from: data), r.isValid,
               r.timestamp <= now.addingTimeInterval(86400), now.timeIntervalSince(r.timestamp) <= Self.retention {
                valid.append((url, r.timestamp))
            } else { try FileManager.default.removeItem(at: url) }
        }
        for old in valid.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxReports) { try FileManager.default.removeItem(at: old.0) }
    }
    public static func privateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CrashDiagnosticError.unavailable }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
