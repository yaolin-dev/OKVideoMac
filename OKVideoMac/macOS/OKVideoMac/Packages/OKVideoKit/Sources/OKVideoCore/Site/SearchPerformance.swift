import Foundation
import CryptoKit

public enum SearchAttemptStatus: String, Sendable { case success, failure, timeout, cancelled }

/// Timings start when the scheduler admits the request. Queue time is diagnostic
/// evidence, never a penalty against a provider that has not started yet.
public struct SearchAttemptObservation: Sendable {
    public let siteKey: String
    public let elapsed: TimeInterval
    public let queued: TimeInterval
    public let status: SearchAttemptStatus
    public let hasRelevantResults: Bool
    public init(siteKey: String, elapsed: TimeInterval, queued: TimeInterval = 0,
                status: SearchAttemptStatus, hasRelevantResults: Bool = false) {
        self.siteKey = siteKey; self.elapsed = elapsed; self.queued = queued
        self.status = status; self.hasRelevantResults = hasRelevantResults
    }
}

/// Local, bounded statistics only: no search terms, result IDs, URLs or credentials.
/// The first request after process creation is kept separately from later samples,
/// so starting a runtime cannot overwrite an already learned warm latency.
public final class SearchPerformanceStore: @unchecked Sendable {
    private struct Metric: Codable {
        var initialSeconds: Double = 2
        var warmSeconds: Double?
        var failureRate: Double = 0
        var relevantRate: Double = 0.5
        var samples: Int = 0
        var updated: TimeInterval = 0
        var selected: TimeInterval?
    }
    private struct Disk: Codable { var schema = 1; var metrics: [String: Metric] }
    private let lock = NSLock()
    private let io = DispatchQueue(label: "OKVideoMac.search-statistics", qos: .utility)
    private let file: URL?
    private let now: @Sendable () -> TimeInterval
    private var metrics: [String: Metric] = [:]
    private var seenInProcess = Set<String>()
    private var revision = 0
    private var savedRevision = 0
    private var writeScheduled = false
    private let lifetime: TimeInterval = 14 * 86_400
    public static let maximumEntries = 512

    public init(file: URL? = nil, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.file = file; self.now = now
        if let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 512 * 1024, let data = try? Data(contentsOf: file),
           let disk = try? JSONDecoder().decode(Disk.self, from: data), disk.schema == 1 {
            metrics = disk.metrics.filter { key, value in
                Self.validKey(key) && value.initialSeconds.isFinite && value.initialSeconds >= 0
                    && value.initialSeconds <= 120 && (value.warmSeconds.map { $0.isFinite && $0 >= 0 && $0 <= 120 } ?? true)
                    && (0...1).contains(value.failureRate) && (0...1).contains(value.relevantRate)
                    && value.samples >= 0 && value.updated.isFinite && value.updated <= now() + 300
                    && now() - value.updated < lifetime
            }
            trim()
        }
    }

    public static func key(namespace: String, identity: String) -> String {
        // Length-prefix parts so opaque keys cannot collide through delimiters.
        let value = "\(namespace.utf8.count):\(namespace)\(identity.utf8.count):\(identity)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func validKey(_ key: String) -> Bool { key.count == 64 && key.allSatisfy(\.isHexDigit) }

    public func record(_ observation: SearchAttemptObservation, key: String) {
        guard observation.status != .cancelled, Self.validKey(key), observation.elapsed.isFinite,
              observation.elapsed >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let time = now()
        var metric = metrics[key].flatMap { time - $0.updated < lifetime ? $0 : nil } ?? Metric()
        let seconds = min(observation.elapsed, 120)
        let initial = seenInProcess.insert(key).inserted
        if initial { metric.initialSeconds = seconds }
        else { metric.warmSeconds = metric.warmSeconds.map { $0 * 0.75 + seconds * 0.25 } ?? seconds }
        let failed = observation.status == .success ? 0.0 : 1.0
        metric.failureRate = metric.failureRate * 0.75 + failed * 0.25
        // Empty is a successful lookup, not a transport failure. Relevant hits
        // are a small smoothed signal, never a binary global demotion.
        if observation.status == .success {
            metric.relevantRate = metric.relevantRate * 0.85 + (observation.hasRelevantResults ? 0.15 : 0)
        }
        metric.samples = min(1_000, metric.samples + 1)
        metric.updated = time; metrics[key] = metric
        trim(); changed()
    }

    public func recordSelection(key: String) {
        guard Self.validKey(key) else { return }
        lock.lock(); defer { lock.unlock() }
        var value = metrics[key] ?? Metric()
        value.selected = now(); value.updated = now(); metrics[key] = value
        trim(); changed()
    }

    public func priority(key: String, recentlyUsed: Bool = false) -> Double {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        guard let value = metrics[key], time - value.updated < lifetime else { return recentlyUsed ? 1.5 : 2 }
        // Gradually forget old evidence; an old failure must not permanently
        // bury a repaired source. Every source remains eligible in each search.
        let freshness = pow(0.5, max(0, time - value.updated) / (3 * 86_400))
        let confidence = min(1, Double(value.samples) / 4) * freshness
        let seconds = value.warmSeconds ?? value.initialSeconds
        let expected = seconds * confidence + 2 * (1 - confidence)
        let selectedRecently = value.selected.map { time - $0 < 7 * 86_400 } ?? false
        return expected * (1 + 2 * value.failureRate * freshness)
            / (0.8 + 0.2 * value.relevantRate) * (recentlyUsed || selectedRecently ? 0.75 : 1)
    }

    public var entryCount: Int { lock.lock(); defer { lock.unlock() }; return metrics.count }
    public func flush() throws { try io.sync { try persist() } }

    private func trim() {
        let time = now()
        metrics = metrics.filter { time - $0.value.updated < lifetime }
        if metrics.count > Self.maximumEntries {
            let keep = Set(metrics.sorted { $0.value.updated > $1.value.updated }.prefix(Self.maximumEntries).map(\.key))
            metrics = metrics.filter { keep.contains($0.key) }
        }
        seenInProcess.formIntersection(metrics.keys)
    }
    private func changed() {
        revision += 1
        guard file != nil, !writeScheduled else { return }
        writeScheduled = true
        io.asyncAfter(deadline: .now() + 1) { [weak self] in try? self?.persist() }
    }
    private func persist() throws {
        lock.lock()
        writeScheduled = false
        guard let file, revision != savedRevision else { lock.unlock(); return }
        let snapshot = Disk(metrics: metrics), version = revision
        lock.unlock()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 512 * 1024 else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        lock.lock(); savedRevision = version; lock.unlock()
    }
}
