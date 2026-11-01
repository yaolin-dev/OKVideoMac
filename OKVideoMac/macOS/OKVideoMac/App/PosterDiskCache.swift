import Foundation

/// Called only by ImageDataRepository's actor. Decoded images and downloaded
/// Data own their bytes, so eviction never invalidates an image being displayed.
struct PosterDiskCache {
    struct Policy {
        var maximumBytes: Int64 = 512 * 1_024 * 1_024
        var minimumFreeBytes: Int64 = 1_024 * 1_024 * 1_024
    }
    private struct Entry { var bytes: Int64; var lastUsed: Date }
    private let directory: URL
    private let policy: Policy
    private let availableBytes: () -> Int64?
    private let now: () -> Date
    private var entries: [URL: Entry]?
    private var total: Int64 = 0
    private let manager = FileManager.default

    init(directory: URL, policy: Policy = Policy(),
         availableBytes: (() -> Int64?)? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory.standardizedFileURL
        self.policy = policy
        self.now = now
        self.availableBytes = availableBytes ?? {
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }

    mutating func touch(_ file: URL) {
        let file = file.standardizedFileURL
        prepare()
        guard var entry = entries?[file] else { return }
        entry.lastUsed = now()
        entries?[file] = entry
        try? manager.setAttributes([.modificationDate: entry.lastUsed], ofItemAtPath: file.path)
        // The caller already holds a Data copy. Even this file can be evicted
        // if a legacy entry alone exceeds the budget or the disk is nearly full.
        _ = trim(incoming: 0, replacing: nil, protected: [])
    }

    /// Caching is optional. A full/unwritable disk must not turn decoded media
    /// into an image-loading failure. Only owned .image files may be evicted.
    @discardableResult
    mutating func store(_ data: Data, at file: URL) -> Bool {
        let file = file.standardizedFileURL
        prepare()
        let size = Int64(data.count)
        guard owns(file), size <= policy.maximumBytes,
              trim(incoming: size, replacing: file, protected: [file]) else { return false }
        do {
            try data.write(to: file, options: [.atomic])
            let timestamp = now()
            try? manager.setAttributes([.posixPermissions: 0o600, .modificationDate: timestamp], ofItemAtPath: file.path)
            total -= entries?[file]?.bytes ?? 0
            entries?[file] = Entry(bytes: size, lastUsed: timestamp)
            total += size
            return true
        } catch { return false }
    }

    mutating func reset() { entries = nil; total = 0 }

    private func owns(_ file: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && file.pathExtension == "image"
            && file.deletingPathExtension().lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private mutating func prepare() {
        guard entries == nil else { return }
        entries = [:]; total = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for candidate in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [] {
            let file = candidate.standardizedFileURL
            guard owns(file), let value = try? file.resourceValues(forKeys: keys),
                  value.isRegularFile == true, value.isSymbolicLink != true else { continue }
            let size = Int64(value.fileSize ?? 0)
            entries?[file] = Entry(bytes: size, lastUsed: value.contentModificationDate ?? .distantPast)
            total += size
        }
    }

    private mutating func trim(incoming: Int64, replacing: URL?, protected: Set<URL>) -> Bool {
        let previousSize = replacing.flatMap { entries?[$0]?.bytes } ?? 0
        var free = availableBytes()
        func enough() -> Bool {
            total - previousSize + incoming <= policy.maximumBytes
                && (free.map { $0 >= policy.minimumFreeBytes + incoming } ?? true)
        }
        if enough() { return true }
        let candidates = (entries ?? [:]).sorted {
            $0.value.lastUsed == $1.value.lastUsed ? $0.key.path < $1.key.path : $0.value.lastUsed < $1.value.lastUsed
        }
        for (file, entry) in candidates where !protected.contains(file) {
            do {
                try manager.removeItem(at: file)
                entries?[file] = nil; total -= entry.bytes
                if let current = free { free = current + entry.bytes }
            } catch { continue }
            if enough() { return true }
        }
        return enough()
    }
}
