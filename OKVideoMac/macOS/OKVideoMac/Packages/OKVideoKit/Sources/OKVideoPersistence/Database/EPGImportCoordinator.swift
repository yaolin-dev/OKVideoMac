import Foundation
@_spi(XMLTVStreaming) import OKVideoCore

enum EPGImportAdmissionError: Error, Equatable { case queueFull, paused, closed }

/// One instance per Store; internal developer integration only. A queued entry
/// is a lightweight request and never owns a downloaded file or parser batch.
actor EPGImportCoordinator {
    private final class Entry {
        let id = UUID()
        let key: EPGRequestKey
        let request: XMLTVDownloadRequest
        let control = EPGImportControl()
        var waiters: [UUID: CheckedContinuation<EPGImportReceipt, Error>] = [:]
        var task: Task<Void, Never>?
        init(key: EPGRequestKey, request: XMLTVDownloadRequest) { self.key = key; self.request = request }
    }
    private let store: EPGCacheStore
    private let downloader: XMLTVDownloader
    private let phaseObserver: ((String) -> Void)?
    private let worker = DispatchQueue(label: "com.okvideomac.epg.import", qos: .utility)
    private var active: Entry?
    private var pending: [Entry] = []
    private var paused = false
    private var closed = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    init(store: EPGCacheStore, downloader: XMLTVDownloader, phaseObserver: ((String) -> Void)? = nil) {
        self.store = store; self.downloader = downloader
        self.phaseObserver = phaseObserver
    }
    var operationCount: Int { pending.count + (active == nil ? 0 : 1) }

    func load(key: EPGRequestKey, request: XMLTVDownloadRequest, force: Bool = false) async throws -> EPGImportReceipt {
        let waiter = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(key: key, request: request, force: force, waiter: waiter, continuation: continuation)
            }
        }, onCancel: { Task { await self.cancel(waiter) } })
    }

    private func enqueue(key: EPGRequestKey, request: XMLTVDownloadRequest, force: Bool,
                         waiter: UUID, continuation: CheckedContinuation<EPGImportReceipt, Error>) {
        guard !closed else { continuation.resume(throwing: EPGImportAdmissionError.closed); return }
        guard !paused else { continuation.resume(throwing: EPGImportAdmissionError.paused); return }
        if !force, let entry = ([active].compactMap { $0 } + pending).first(where: {
            $0.key == key && (try? $0.control.check()) != nil
        }) {
            guard entry.waiters.count < 8 else {
                continuation.resume(throwing: EPGImportAdmissionError.queueFull); return
            }
            entry.waiters[waiter] = continuation; return
        }
        // Capacity is checked before revoking accepted work. Same-source queued
        // entries are replaced, so they do not consume the replacement's slot.
        let superseded = pending.filter { $0.key.source == key.source }
        guard active == nil || pending.count - superseded.count < 4 else {
            continuation.resume(throwing: EPGImportAdmissionError.queueFull); return
        }
        for entry in superseded { stopPending(entry, reason: .superseded) }
        if let active, active.key.source == key.source {
            active.control.stop(.superseded); active.task?.cancel()
        }
        let entry = Entry(key: key, request: request)
        entry.waiters[waiter] = continuation
        pending.append(entry); startNext()
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty, !paused, !closed else { return }
        let entry = pending.removeFirst(); active = entry
        let store = store, downloader = downloader, worker = worker, phaseObserver = phaseObserver
        entry.task = Task {
            let result: Result<EPGImportReceipt, Error>
            do {
                let receipt = try await Self.run(entry: entry, store: store, downloader: downloader, worker: worker,
                                                phaseObserver: phaseObserver)
                result = .success(receipt)
            } catch { result = .failure(error) }
            self.finished(entry, result: result)
        }
    }

    private nonisolated static func work<T>(_ queue: DispatchQueue, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private nonisolated static func run(entry: Entry, store: EPGCacheStore,
                                       downloader: XMLTVDownloader, worker: DispatchQueue,
                                       phaseObserver: ((String) -> Void)?) async throws -> EPGImportReceipt {
        let importer = EPGXMLTVImporter(store: store)
        importer.boundaryForTesting = phaseObserver
        try store.acquireImportPipeline()
        defer { store.releaseImportPipeline() }
        // Reuse abandoned pages before admitting a new generation. Each burst
        // is cancellable and yields between slices; active/staging snapshots
        // remain protected by the Store's cleanup predicate.
        var needsCleanup = true
        while needsCleanup {
            needsCleanup = try await work(worker) {
                let started = ProcessInfo.processInfo.systemUptime
                for _ in 0..<4 {
                    try entry.control.check()
                    if try !store.cleanupStep().hasWorkRemaining { return false }
                    if ProcessInfo.processInfo.systemUptime - started >= 0.020 { break }
                }
                return true
            }
            if needsCleanup { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        let handle = try await work(worker) {
            try entry.control.check()
            _ = try downloader.recoverStaleFiles()
            _ = importer.cleanup()
            return try store.begin(entry.key)
        }
        do {
            try entry.control.check()
            phaseObserver?("downloading")
            let file = try await downloader.download(entry.request)
            phaseObserver?("downloaded")
            defer { try? file.release() }
            return try await work(worker) {
                try importer.importDownloaded(file, handle: handle, control: entry.control)
            }
        } catch {
            _ = try? await work(worker) { try store.abandon(handle); _ = importer.cleanup() }
            try entry.control.check() // classify supersede/close independently of transport cancellation
            throw error
        }
    }

    private func finished(_ entry: Entry, result: Result<EPGImportReceipt, Error>) {
        guard active?.id == entry.id else { return }
        active = nil; entry.task = nil
        for continuation in entry.waiters.values { continuation.resume(with: result) }
        entry.waiters.removeAll()
        if closed || paused {
            for continuation in drainWaiters { continuation.resume() }
            drainWaiters.removeAll()
        }
        if !closed && !paused { startNext() }
    }
    private func stopPending(_ entry: Entry, reason: EPGImportStop) {
        pending.removeAll { $0.id == entry.id }
        entry.control.stop(reason)
        for continuation in entry.waiters.values { continuation.resume(throwing: reason) }
        entry.waiters.removeAll()
    }
    private func cancel(_ waiter: UUID) {
        if let active, let continuation = active.waiters.removeValue(forKey: waiter) {
            // The caller owns a subscription, not the shared import. Other
            // subscribers retain work; the last cancellation stops the pipeline.
            if active.waiters.isEmpty {
                active.waiters[waiter] = continuation
                active.control.stop(); active.task?.cancel()
            } else { continuation.resume(throwing: EPGImportStop.cancelled) }
            return
        }
        if let entry = pending.first(where: { $0.waiters[waiter] != nil }),
           let continuation = entry.waiters.removeValue(forKey: waiter) {
            continuation.resume(throwing: EPGImportStop.cancelled)
            if entry.waiters.isEmpty { pending.removeAll { $0.id == entry.id } }
        }
    }
    func setSourceEnabled(_ source: EPGSourceKey, enabled: Bool) async throws {
        for entry in pending.filter({ $0.key.source == source }) { stopPending(entry, reason: .superseded) }
        if let active, active.key.source == source { active.control.stop(.superseded); active.task?.cancel() }
        try await Self.work(worker) { try self.store.setSourceEnabled(source, enabled: enabled) }
    }
    /// Reversible lifecycle suspension. It revokes queued/active work but does
    /// not mutate source epochs or close the Store.
    func pause() async {
        guard !closed else { return }
        paused = true
        for entry in pending { stopPending(entry, reason: .cancelled) }
        if let active {
            active.control.stop(); active.task?.cancel()
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }
    func resume() {
        guard !closed else { return }
        paused = false
        startNext()
    }
    /// Wait for file/parser cleanup before the caller closes its Store.
    func close() async {
        closed = true
        paused = true
        for entry in pending { stopPending(entry, reason: .storeClosing) }
        if let active {
            active.control.stop(.storeClosing); active.task?.cancel()
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }
}
