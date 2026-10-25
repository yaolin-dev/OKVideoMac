import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import OKVideoCore

struct LivePreviewInput: Codable, Sendable {
    let url: String
    let headers: [String: String]
    var timeoutSeconds: Double? = nil
    var networkOptions: [String: String]? = nil
    var collectTimings: Bool? = nil
}

enum LivePreviewPolicy {
    static let refresh: TimeInterval = 600
    static let firstAttempt: TimeInterval = 12
    static let slowAttempt: TimeInterval = 25
    static func digest(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func accepts(captured: Date, now: Date, programmeStart: Date?) -> Bool {
        captured <= now // Age and EPG boundaries affect freshness, never displayability.
    }
}

struct LivePreviewDemand {
    let key: String
    let sourceKey: String
    let channelID: String
    let programmeStart: Date?
    let resolve: @MainActor () async throws -> [LivePreviewInput]
    let isValid: @MainActor () -> Bool
    var acquireConnection: (@MainActor () async throws -> LivePreviewConnectionLease)? = nil
    var legacyKey: String? = nil
    var priority: Int = 0
    var mayReuseFrame: @MainActor () -> Bool = { false }
    var currentFrame: (@MainActor () async throws -> Data?)? = nil
}

struct LivePreviewBytes: Codable, Sendable {
    let data: Data
    let captured: Date
    let sourceKey: String
}

actor LivePreviewCache {
    private let directory: URL
    private let limit: Int
    init(directory: URL? = nil, limit: Int = 128 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.okvideomac/live-previews-v1", isDirectory: true)
        self.limit = limit
    }
    private func location(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    func read(_ key: String) -> LivePreviewBytes? {
        guard !Task.isCancelled, key.count == 64, key.allSatisfy({ $0.isHexDigit }),
              let size = try? location(key).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 1_000_000, let data = try? Data(contentsOf: location(key)), data.count < 1_000_000,
              let entry = try? JSONDecoder().decode(LivePreviewBytes.self, from: data) else { return nil }
        // Modification time represents recent use for disk LRU; captured stays immutable.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: location(key).path)
        return entry
    }
    func store(_ entry: LivePreviewBytes, key: String) {
        guard !Task.isCancelled, key.count == 64, key.allSatisfy({ $0.isHexDigit }), entry.data.count < 700_000 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: location(key), options: .atomic) }
        trim()
    }
    func remove(sourceKey: String) {
        for file in files() {
            if let data = try? Data(contentsOf: file),
               let entry = try? JSONDecoder().decode(LivePreviewBytes.self, from: data), entry.sourceKey == sourceKey {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }
    private func trim() {
        let entries = files().compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (file, size, _) in entries {
            total += size
            if total > limit {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

enum LivePreviewCaptureError: Error {
    case deadline, invalidImage, helper(String), connectionBusy, unavailable
    var category: String {
        switch self { case .deadline: return "deadline"; case .invalidImage: return "invalid-image"; case .helper(let stage): return stage; case .connectionBusy: return "connection-busy"; case .unavailable: return "unavailable" }
    }
}

/// One child per attempt. Killing/reaping is confined to this object's process;
/// cancelled tasks cannot leave a decoder or a network connection behind.
final class LivePreviewProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
    }
    func run(_ input: LivePreviewInput, executable: URL, timeout: TimeInterval = 13) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                    child.executableURL = executable
                    child.standardInput = stdin; child.standardOutput = stdout
                    child.standardError = stderr
                    // Do not pass media credentials through argv or environment.
                    child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.lock(); self.timedOut = true; self.lock.unlock(); self.cancel()
                    }
                    defer { deadline.cancel(); try? stdin.fileHandleForWriting.close(); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
                    do {
                        let encoded = try JSONEncoder().encode(input)
                        guard encoded.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
                        self.lock.lock()
                        if self.cancelled { self.lock.unlock(); throw CancellationError() }
                        do { try child.run(); self.process = child; self.lock.unlock() }
                        catch { self.lock.unlock(); throw error }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                        try stdin.fileHandleForWriting.write(contentsOf: encoded)
                        try stdin.fileHandleForWriting.close()
                        var data = Data()
                        while let chunk = try stdout.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                            data.append(chunk)
                            if data.count > 700_000 { self.cancel(); throw CocoaError(.fileReadTooLarge) }
                        }
                        child.waitUntilExit()
                        self.lock.lock(); let cancelled = self.cancelled, timedOut = self.timedOut; self.process = nil; self.lock.unlock()
                        guard !cancelled else {
                            if timedOut { throw LivePreviewCaptureError.deadline }
                            throw CancellationError()
                        }
                        if child.terminationStatus != 0 {
                            let diagnostic = (try? stderr.fileHandleForReading.read(upToCount: 4096)) ?? Data()
                            // Only classify fixed helper labels; never propagate URLs/native logs.
                            let message = String(data: diagnostic, encoding: .utf8) ?? ""
                            if message.contains("preview: load: media") { throw LivePreviewCaptureError.helper("media-failed") }
                            if message.contains("preview: load: timeout") || child.terminationStatus == 2 { throw LivePreviewCaptureError.deadline }
                            throw LivePreviewCaptureError.helper("helper-failed")
                        }
                        guard data.starts(with: [0xff, 0xd8]) else { throw LivePreviewCaptureError.invalidImage }
                        continuation.resume(returning: data)
                    } catch {
                        self.cancel()
                        if child.isRunning { child.waitUntilExit() }
                        self.lock.lock(); self.process = nil; self.lock.unlock()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }
}

/// Reservations are made on the main actor after the account check returns.
/// Concurrent checks cannot all claim the same reported free connection.
@MainActor final class LivePreviewConnectionBudget {
    private var reservations: [String: Set<UUID>] = [:]
    func reserve(sourceKey: String, reportedAvailable: Int) throws -> LivePreviewConnectionLease {
        let existing = reservations[sourceKey] ?? []
        guard reportedAvailable > 0 else {
            if !existing.isEmpty { throw LivePreviewCaptureError.connectionBusy }
            throw LivePreviewCaptureError.unavailable
        }
        guard existing.count < reportedAvailable else { throw LivePreviewCaptureError.connectionBusy }
        let id = UUID()
        reservations[sourceKey, default: []].insert(id)
        return LivePreviewConnectionLease { [weak self] in
            self?.reservations[sourceKey]?.remove(id)
            if self?.reservations[sourceKey]?.isEmpty == true { self?.reservations[sourceKey] = nil }
        }
    }
    func count(sourceKey: String) -> Int { reservations[sourceKey]?.count ?? 0 }
}

@MainActor final class LivePreviewConnectionLease {
    private var onRelease: (() -> Void)?
    init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    func release() { let action = onRelease; onRelease = nil; action?() }
}

@MainActor final class LivePreviewCoordinator: ObservableObject {
    final class ImageEntry {
        let image: NSImage
        let captured: Date
        init(image: NSImage, captured: Date) { self.image = image; self.captured = captured }
    }
    private final class Flight {
        let id = UUID()
        let demand: LivePreviewDemand
        let generation: UUID
        let slow: Bool
        let reuseFrame: Bool
        let startedAt: Date
        var task: Task<Void, Never>?
        var cancellationRequested = false
        var timedOut = false
        init(demand: LivePreviewDemand, generation: UUID, slow: Bool, reuseFrame: Bool, startedAt: Date) {
            self.demand = demand; self.generation = generation
            self.slow = slow; self.reuseFrame = reuseFrame; self.startedAt = startedAt
        }
        func cancel() { cancellationRequested = true; task?.cancel() }
    }
    let changes = PassthroughSubject<Set<String>, Never>()
    let connectionBudget = LivePreviewConnectionBudget()
    @Published private(set) var refreshing = false
    private let cache: LivePreviewCache
    private let clock: () -> Date
    private let memory: NSCache<NSString, ImageEntry>
    private let maximumConcurrentCaptures: Int
    // Displayed bitmaps belong to the actual viewport, not the evictable LRU.
    private var visibleKeys = Set<String>()
    private var visibleImages: [String: ImageEntry] = [:]
    private var demands: [LivePreviewDemand] = []
    private var owner: UUID?
    private var generation = UUID()
    // Cancelling flights retain their slot until their child has actually exited.
    private var flights: [String: Flight] = [:]
    private var timer: Timer?
    private var loaded = Set<String>()
    private var cachedDates: [String: Date] = [:]
    private var sources: [String: String] = [:]
    private var attempts: [String: Int] = [:]
    private var frameAfter: [String: Date] = [:]
    private var deferredUntil: [String: Date] = [:]
    private var capacityWaitUntil: [String: Date] = [:]
    private var refreshKeys = Set<String>()
    private var cacheTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var viewportStableAt = Date.distantPast
    private var changeTask: Task<Void, Never>?
    private var pendingChanges = Set<String>()
    private var mayCapture: @MainActor () -> Bool = { false }
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var suspended = false
    private var draining = 0
    private var autoRefresh = false
    private var lastAutomaticRound = Date.distantPast
    private var quietUntil = Date.distantPast
    private(set) var outcomes: [String: String] = [:]
    var capture: (LivePreviewInput) async throws -> Data

    init(cache: LivePreviewCache = LivePreviewCache(), clock: @escaping () -> Date = Date.init,
         memory: NSCache<NSString, ImageEntry> = NSCache(), maximumConcurrentCaptures: Int = 3,
         capture: ((LivePreviewInput) async throws -> Data)? = nil) {
        self.cache = cache; self.clock = clock; self.memory = memory
        self.maximumConcurrentCaptures = min(4, max(1, maximumConcurrentCaptures))
        self.capture = capture ?? { input in
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OKVideoLivePreview")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.fileNoSuchFile) }
            return try await LivePreviewProcessJob().run(input, executable: executable,
                timeout: (input.timeoutSeconds ?? LivePreviewPolicy.firstAttempt) + 1)
        }
        memory.totalCostLimit = 32 * 1024 * 1024
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.interrupt() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.pump() }
        })
    }
    deinit {
        for flight in flights.values { flight.task?.cancel() }
        cacheTask?.cancel(); viewportTask?.cancel(); changeTask?.cancel(); timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func image(for key: String, programmeStart: Date?, now: Date = Date()) -> ImageEntry? {
        guard let entry = visibleImages[key] ?? memory.object(forKey: key as NSString),
              LivePreviewPolicy.accepts(captured: entry.captured, now: now, programmeStart: programmeStart) else { return nil }
        return entry
    }
    func update(owner: UUID, demands: [LivePreviewDemand], mayCapture: @escaping @MainActor () -> Bool,
                autoRefresh: Bool = false, isActive: Bool = true) {
        if self.owner != owner {
            clearCurrentOwner(); self.owner = owner
            quietUntil = clock().addingTimeInterval(0.25)
        }
        var seen = Set<String>()
        self.demands = demands.filter { seen.insert($0.key).inserted }
        self.mayCapture = mayCapture; self.autoRefresh = autoRefresh; suspended = !isActive
        let keys = Set(self.demands.map(\.key))
        refreshKeys.formIntersection(keys); refreshing = !refreshKeys.isEmpty
        for demand in self.demands { sources[demand.key] = demand.sourceKey }
        retainViewport()
        for flight in flights.values where !self.demands.contains(where: { $0.key == flight.demand.key && $0.isValid() }) {
            flight.cancel()
        }
        loadCache()
        if suspended { interrupt(); timer?.invalidate(); timer = nil }
        if !suspended, timer == nil, !self.demands.isEmpty {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        pump()
    }
    func updateViewport(owner: UUID, visible: Set<String>, nearby: Set<String>) {
        guard self.owner == owner else { return }
        var lanes = [[LivePreviewDemand](), [LivePreviewDemand](), [LivePreviewDemand]()]
        for var demand in demands {
            demand.priority = visible.contains(demand.key) ? 0 : nearby.contains(demand.key) ? 1 : 2
            lanes[demand.priority].append(demand)
        }
        demands = lanes.flatMap { $0 }; retainViewport(); loadCache(); pump()
    }
    private func retainViewport() {
        let next = Set(demands.filter { $0.priority == 0 && $0.isValid() }.map(\.key))
        if next != visibleKeys {
            viewportStableAt = clock().addingTimeInterval(0.25)
            viewportTask?.cancel()
            viewportTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.viewportTask = nil; self.pump()
            }
        }
        visibleKeys = next
        visibleImages = visibleImages.filter { visibleKeys.contains($0.key) }
        for key in visibleKeys where visibleImages[key] == nil {
            if let entry = memory.object(forKey: key as NSString) { visibleImages[key] = entry }
            else if cachedDates[key] != nil { loaded.remove(key) }
        }
    }
    private func retain(_ entry: ImageEntry, for key: String) {
        if visibleKeys.contains(key) { visibleImages[key] = entry }
        memory.setObject(entry, forKey: key as NSString, cost: 640 * 360 * 4)
    }
    private func notify(_ keys: Set<String>) {
        pendingChanges.formUnion(keys)
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self else { return }
            let keys = self.pendingChanges
            self.pendingChanges.removeAll(); self.changeTask = nil
            if !keys.isEmpty { self.changes.send(keys) }
        }
    }
    func requestRefresh() {
        guard owner != nil, refreshKeys.isEmpty else { return }
        refreshKeys = Set(demands.filter { $0.isValid() }.map(\.key))
        for key in refreshKeys where flights[key] == nil { attempts[key] = 0 }
        capacityWaitUntil.removeAll(); deferredUntil.removeAll()
        refreshing = !refreshKeys.isEmpty; loadCache(); pump()
    }
    func suspend(owner: UUID) {
        guard self.owner == owner else { return }
        suspended = true; interrupt(); timer?.invalidate(); timer = nil
    }
    func clear(owner: UUID) { if self.owner == owner { clearCurrentOwner() } }
    private func clearCurrentOwner() {
        owner = nil; demands = []; generation = UUID()
        visibleKeys.removeAll(); visibleImages.removeAll()
        interrupt(); cacheTask?.cancel(); cacheTask = nil
        viewportTask?.cancel(); viewportTask = nil
        changeTask?.cancel(); changeTask = nil; pendingChanges.removeAll()
        loaded.removeAll(); deferredUntil.removeAll(); capacityWaitUntil.removeAll()
        refreshKeys.removeAll(); refreshing = false
        timer?.invalidate(); timer = nil
        if attempts.count > 4096 { attempts.removeAll(); frameAfter.removeAll(); outcomes.removeAll() }
        if cachedDates.count > 4096 { cachedDates.removeAll(); sources.removeAll() }
    }
    func interrupt() { for flight in flights.values { flight.cancel() } }
    func quiesce() async {
        draining += 1
        defer { draining -= 1 }
        let running = Array(flights.values)
        for flight in running { flight.cancel() }
        for flight in running { await flight.task?.value }
    }
    func invalidate(sourceKey: String) {
        let keys = Set(sources.filter { $0.value == sourceKey }.map(\.key))
        for flight in flights.values where flight.demand.sourceKey == sourceKey { flight.cancel() }
        demands.removeAll { $0.sourceKey == sourceKey }
        for key in keys {
            memory.removeObject(forKey: key as NSString); cachedDates[key] = nil
            visibleKeys.remove(key); visibleImages[key] = nil
            sources[key] = nil; loaded.remove(key); attempts[key] = nil
            frameAfter[key] = nil; deferredUntil[key] = nil; outcomes[key] = nil; refreshKeys.remove(key)
        }
        capacityWaitUntil[sourceKey] = nil; refreshing = !refreshKeys.isEmpty
        Task { await cache.remove(sourceKey: sourceKey) }
        notify(keys)
    }
    private func loadCache() {
        guard cacheTask == nil else { return }
        let generation = self.generation
        cacheTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.cacheTask = nil; self.pump() } }
            while let demand = self.demands.first(where: { !self.loaded.contains($0.key) }) {
                guard !Task.isCancelled, generation == self.generation else { return }
                var entry = await self.cache.read(demand.key)
                if entry == nil, let legacy = demand.legacyKey {
                    entry = await self.cache.read(legacy)
                    if let entry { await self.cache.store(entry, key: demand.key) }
                }
                guard !Task.isCancelled, generation == self.generation else { return }
                guard demand.isValid(), self.sources[demand.key] == demand.sourceKey else {
                    self.loaded.insert(demand.key); continue
                }
                if let entry, entry.sourceKey == demand.sourceKey,
                   LivePreviewPolicy.accepts(captured: entry.captured, now: Date(), programmeStart: nil),
                   let image = NSImage(data: entry.data), image.isValid {
                    if entry.captured >= (self.cachedDates[demand.key] ?? .distantPast) {
                        self.cachedDates[demand.key] = entry.captured
                        if self.visibleKeys.contains(demand.key) {
                            self.retain(ImageEntry(image: image, captured: entry.captured), for: demand.key)
                            self.notify([demand.key])
                        }
                    }
                } else {
                    if self.cachedDates[demand.key] != nil || self.outcomes[demand.key] == "success" {
                        self.attempts[demand.key] = 0
                    }
                    self.cachedDates[demand.key] = nil
                }
                self.loaded.insert(demand.key); self.pump()
            }
        }
    }
    private func pump() {
        guard draining == 0, !sleeping, !suspended, owner != nil else { interrupt(); return }
        for flight in flights.values {
            if !mayCapture(), !(flight.reuseFrame && flight.demand.mayReuseFrame()) { flight.cancel() }
        }
        let now = clock()
        guard now >= quietUntil else { return }
        if autoRefresh, cacheTask == nil, now.timeIntervalSince(lastAutomaticRound) >= LivePreviewPolicy.refresh {
            lastAutomaticRound = now
            for demand in demands where demand.priority == 0 && flights[demand.key] == nil
                && cachedDates[demand.key].map({ now.timeIntervalSince($0) >= LivePreviewPolicy.refresh }) == true {
                refreshKeys.insert(demand.key); attempts[demand.key] = 0
            }
            refreshing = !refreshKeys.isEmpty
        }
        // Local pictures are restored before network tasks are admitted.
        guard !demands.contains(where: { $0.priority == 0 && $0.isValid() && !loaded.contains($0.key) }) else { return }
        let eligible = demands.filter {
            loaded.contains($0.key) && $0.isValid() && flights[$0.key] == nil
                && (mayCapture() || $0.mayReuseFrame())
                && (cachedDates[$0.key] == nil || refreshKeys.contains($0.key))
                && (attempts[$0.key] ?? 0) < 2
                && (deferredUntil[$0.key] ?? .distantPast) <= now
                && (capacityWaitUntil[$0.sourceKey] ?? .distantPast) <= now
                && (!$0.mayReuseFrame() || (frameAfter[$0.key] ?? .distantPast) <= now)
        }
        let ordered = eligible.enumerated().sorted { a, b in
            let left = (a.element.priority, attempts[a.element.key] ?? 0, cachedDates[a.element.key] == nil ? 0 : 1, a.offset)
            let right = (b.element.priority, attempts[b.element.key] ?? 0, cachedDates[b.element.key] == nil ? 0 : 1, b.offset)
            return left < right
        }.map(\.element)
        // Preserve valid in-flight results during ordinary scrolls. Only when
        // all slots are stranded offscreen, reserve one for a stable new viewport.
        if flights.count >= maximumConcurrentCaptures, now >= viewportStableAt,
           ordered.contains(where: { $0.priority == 0 }),
           !flights.values.contains(where: { $0.cancellationRequested || visibleKeys.contains($0.demand.key) }) {
            if let victim = flights.values.sorted(by: { $0.demand.key < $1.demand.key }).first(where: { !$0.reuseFrame }) {
                // Let short captures finish instead of discarding nearly-ready frames.
                let grace = victim.startedAt.addingTimeInterval(0.75).timeIntervalSince(now)
                if grace <= 0 {
                    deferredUntil[victim.demand.key] = now.addingTimeInterval(1)
                    victim.cancel()
                } else if viewportTask == nil {
                    viewportTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                        guard !Task.isCancelled, let self else { return }
                        self.viewportTask = nil; self.pump()
                    }
                }
            }
        }
        for demand in ordered {
            guard flights.count < maximumConcurrentCaptures else { break }
            let slow = (attempts[demand.key] ?? 0) > 0
            if slow && flights.values.contains(where: {
                $0.slow || (!$0.slow && (demand.priority > 0 || visibleKeys.contains($0.demand.key)))
            }) { continue }
            // Offscreen work uses one spare slot; it cannot fill the whole pool.
            if demand.priority > 0 && flights.values.contains(where: { !visibleKeys.contains($0.demand.key) }) { continue }
            start(demand, slow: slow)
        }
        if !autoRefresh, cacheTask == nil, flights.isEmpty, ordered.isEmpty,
           !demands.contains(where: {
               $0.isValid() && (attempts[$0.key] ?? 0) < 2
                   && (cachedDates[$0.key] == nil || refreshKeys.contains($0.key))
                   && (mayCapture() || $0.mayReuseFrame())
           }) {
            timer?.invalidate(); timer = nil
        }
    }
    private func start(_ demand: LivePreviewDemand, slow: Bool) {
        // A manual refresh can restart work after the idle timer was stopped.
        // Capacity backoff must still wake even if every current check returns busy.
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        let reuseFrame = demand.mayReuseFrame()
        if reuseFrame { frameAfter[demand.key] = clock().addingTimeInterval(30) }
        let flight = Flight(demand: demand, generation: generation, slow: slow, reuseFrame: reuseFrame, startedAt: clock())
        flights[demand.key] = flight
        flight.task = Task { [weak self] in
            guard let self else { return }
            let budget = slow ? LivePreviewPolicy.slowAttempt : LivePreviewPolicy.firstAttempt
            var lease: LivePreviewConnectionLease?
            let admitted: @MainActor () -> Bool = { [weak self] in
                guard let self, self.owner != nil, !self.sleeping, !self.suspended else { return false }
                return reuseFrame ? demand.mayReuseFrame() : self.mayCapture()
            }
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64((budget + 2) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                flight.timedOut = true; flight.cancel()
            }
            defer {
                deadline.cancel(); lease?.release()
                if self.flights[demand.key]?.id == flight.id { self.flights[demand.key] = nil }
                self.refreshing = !self.refreshKeys.isEmpty; self.pump()
            }
            do {
                try Task.checkCancellation()
                guard flight.generation == self.generation, demand.isValid(), admitted() else { throw CancellationError() }
                var result: Data?
                if reuseFrame { result = try await demand.currentFrame?() }
                else {
                    lease = try await demand.acquireConnection?()
                    try Task.checkCancellation()
                    guard flight.generation == self.generation, demand.isValid(), admitted() else { throw CancellationError() }
                    let inputs = try await demand.resolve()
                    try Task.checkCancellation()
                    guard flight.generation == self.generation, demand.isValid(), admitted() else { throw CancellationError() }
                    guard !inputs.isEmpty else { throw LivePreviewCaptureError.unavailable }
                    var input = slow && inputs.count > 1 ? inputs[1] : inputs[0]
                    input.timeoutSeconds = budget
                    result = try await self.capture(input)
                }
                // run() returns only after the helper process has been reaped.
                lease?.release(); lease = nil
                try Task.checkCancellation()
                guard flight.generation == self.generation, demand.isValid(), admitted() else { throw CancellationError() }
                guard let data = result, let image = NSImage(data: data), image.isValid else { throw LivePreviewCaptureError.invalidImage }
                let captured = self.clock()
                self.cachedDates[demand.key] = captured
                if self.visibleKeys.contains(demand.key) {
                    self.retain(ImageEntry(image: image, captured: captured), for: demand.key)
                    self.notify([demand.key])
                }
                self.attempts[demand.key] = 2; self.refreshKeys.remove(demand.key)
                self.outcomes[demand.key] = "success"
                await self.cache.store(.init(data: data, captured: captured, sourceKey: demand.sourceKey), key: demand.key)
            } catch {
                guard flight.generation == self.generation, demand.isValid() else { return }
                if admitted(), flight.timedOut || !Task.isCancelled {
                    if case LivePreviewCaptureError.connectionBusy = error {
                        self.capacityWaitUntil[demand.sourceKey] = self.clock().addingTimeInterval(1)
                        self.outcomes[demand.key] = "waiting-for-connection"
                    } else if case LivePreviewCaptureError.unavailable = error {
                        self.attempts[demand.key] = 2; self.refreshKeys.remove(demand.key)
                        self.outcomes[demand.key] = "unavailable-or-connection-limit"
                    } else {
                        self.attempts[demand.key] = slow ? 2 : 1
                        self.outcomes[demand.key] = flight.timedOut ? "deadline" : (error as? LivePreviewCaptureError)?.category ?? "resolve-or-decode"
                        if slow { self.refreshKeys.remove(demand.key) }
                    }
                } else {
                    self.outcomes[demand.key] = "cancelled-for-navigation-or-playback"
                }
            }
        }
    }
}



enum LivePreviewImageCodec {
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }
}
