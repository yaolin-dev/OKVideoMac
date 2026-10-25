import AppKit
import CryptoKit
import ImageIO
import OKVideoCore
import SwiftUI

struct InlineImageRequest: Equatable {
    let url: URL
    let headers: HTTPHeaders

    static func parse(_ value: URL) -> InlineImageRequest {
        let raw = value.absoluteString
        let supportedHeaders = [
            ("@Referer=", "Referer"),
            ("@User-Agent=", "User-Agent"),
            ("@Cookie=", "Cookie"),
            ("@Origin=", "Origin")
        ]
        let matches = supportedHeaders.compactMap { marker, header -> (String.Index, String, String)? in
            raw.range(of: marker, options: [.caseInsensitive]).map {
                ($0.lowerBound, marker, header)
            }
        }
        .sorted { $0.0 < $1.0 }

        guard let first = matches.first,
              let imageURL = URL(string: String(raw[..<first.0])) else {
            return InlineImageRequest(url: value, headers: [:])
        }

        var headers = HTTPHeaders()
        for (index, match) in matches.enumerated() {
            guard let markerRange = raw.range(
                of: match.1,
                options: [.caseInsensitive],
                range: match.0..<raw.endIndex
            ) else {
                continue
            }
            let end = index + 1 < matches.count
                ? matches[index + 1].0
                : raw.endIndex
            let encodedValue = String(raw[markerRange.upperBound..<end])
            let decodedValue = encodedValue.removingPercentEncoding ?? encodedValue
            if !decodedValue.isEmpty {
                headers[match.2] = decodedValue
            }
        }
        return InlineImageRequest(url: imageURL, headers: headers)
    }
}

struct ImageCacheIdentity: Hashable, Sendable {
    let rawValue: String

    init(url: URL, posterPixels: Int? = nil) {
        let original = Self.nodeImageProxyIdentity(for: url) ?? url.absoluteString
        self.init(normalizedSource: original, posterPixels: posterPixels)
    }

    fileprivate init(normalizedSource: String, posterPixels: Int?) {
        rawValue = posterPixels.map { "poster-fit-v1:\($0):\(normalizedSource)" }
            ?? normalizedSource
    }

    private static func nodeImageProxyIdentity(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              components.path == "/imageProxy",
              let queryItems = components.queryItems,
              let targetURL = queryItems.first(where: { $0.name == "url" })?.value,
              !targetURL.isEmpty else {
            return nil
        }

        let customHeaders = queryItems.first(where: { $0.name == "customHeaders" })?.value
        let stableHeaders = customHeaders.map(canonicalHeaders) ?? ""
        let additionalItems = queryItems
            .filter { item in
                item.name != "url" && item.name != "customHeaders" && item.name != "cache"
            }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        let stableValue = [targetURL, stableHeaders, additionalItems]
            .joined(separator: "\u{1F}")
        return "node-image-proxy-v1:" + digest(stableValue)
    }

    private static func canonicalHeaders(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let canonicalValue = String(data: canonicalData, encoding: .utf8) else {
            return value
        }
        return canonicalValue
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
enum DecodedImageCacheCost {
    static let unknownRepresentationCost = 1 * 1_024 * 1_024
    private static let maximumSafeCost = Int.max / 4

    static func cost(for image: NSImage) -> Int {
        var total = 0
        var foundBitmapRepresentation = false

        for case let representation as NSBitmapImageRep in image.representations {
            foundBitmapRepresentation = true
            let representationCost = cost(
                bytesPerRow: representation.bytesPerRow,
                pixelsWide: representation.pixelsWide,
                pixelsHigh: representation.pixelsHigh
            )
            total = addingSafely(total, representationCost)
        }

        return foundBitmapRepresentation && total > 0
            ? total
            : unknownRepresentationCost
    }

    static func cost(
        bytesPerRow: Int,
        pixelsWide: Int,
        pixelsHigh: Int
    ) -> Int {
        guard pixelsHigh > 0 else {
            return unknownRepresentationCost
        }
        if bytesPerRow > 0 {
            return multiplyingSafely(bytesPerRow, pixelsHigh)
        }
        guard pixelsWide > 0 else {
            return unknownRepresentationCost
        }
        return multiplyingSafely(
            multiplyingSafely(pixelsWide, pixelsHigh),
            4
        )
    }

    private static func multiplyingSafely(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > 0, rhs > 0 else {
            return unknownRepresentationCost
        }
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? maximumSafeCost : min(result, maximumSafeCost)
    }

    private static func addingSafely(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? maximumSafeCost : min(result, maximumSafeCost)
    }
}

@MainActor
private final class ImageMemoryCache {
    private let storage = NSCache<NSString, NSImage>()
    private let posterSourceIdentities = NSCache<NSString, NSString>()
    private var memoryPressure: DispatchSourceMemoryPressure?

    init() {
        storage.countLimit = 300
        storage.totalCostLimit = 128 * 1_024 * 1_024
        posterSourceIdentities.countLimit = 1_024
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.removeAll() }
        }
        pressure.resume()
        memoryPressure = pressure
    }

    deinit { memoryPressure?.cancel() }

    @MainActor
    func image(for identity: ImageCacheIdentity) -> NSImage? {
        storage.object(forKey: identity.rawValue as NSString)
    }

    @MainActor
    func poster(for request: PosterImageRequest) -> NSImage? {
        image(for: posterIdentity(for: request))
    }

    @MainActor
    func insert(_ image: NSImage, for identity: ImageCacheIdentity, decodedCost: Int? = nil) {
        storage.setObject(
            image,
            forKey: identity.rawValue as NSString,
            cost: decodedCost ?? DecodedImageCacheCost.cost(for: image)
        )
    }

    @MainActor
    func insertPoster(_ image: NSImage, for request: PosterImageRequest,
                      decodedCost: Int) {
        insert(image, for: posterIdentity(for: request), decodedCost: decodedCost)
    }

    @MainActor
    private func posterIdentity(for request: PosterImageRequest) -> ImageCacheIdentity {
        let sourceURL = request.url.absoluteString as NSString
        let normalizedSource: String
        if let cached = posterSourceIdentities.object(forKey: sourceURL) {
            normalizedSource = cached as String
        } else {
            normalizedSource = ImageCacheIdentity(url: request.url).rawValue
            posterSourceIdentities.setObject(normalizedSource as NSString,
                forKey: sourceURL)
        }
        return ImageCacheIdentity(normalizedSource: normalizedSource,
            posterPixels: request.pixels)
    }

    @MainActor
    func removeAll() {
        storage.removeAllObjects()
        posterSourceIdentities.removeAllObjects()
    }
}

private enum ImageDataOrigin: Equatable, Sendable {
    case disk
    case network
}

private struct LoadedImageData: Sendable {
    let data: Data
    let origin: ImageDataOrigin
}

private struct InFlightImageDataLoad {
    let id: UUID
    let task: Task<Data, Error>
}

private struct InFlightImageLoad {
    let id: UUID
    let task: Task<Void, Error>
}

actor ImageDataRepository {
    private let cacheDirectory: URL
    private let httpClient: HTTPClient
    private var inFlight: [URL: InFlightImageDataLoad] = [:]
    private var consumers: [URL: Set<UUID>] = [:]

    init(cacheDirectory: URL, httpClient: HTTPClient) throws {
        self.cacheDirectory = cacheDirectory
        self.httpClient = httpClient
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cacheDirectory.path
        )
    }

    fileprivate func data(for url: URL) async throws -> LoadedImageData {
        let identity = ImageCacheIdentity(url: url)
        let diskURL = cacheDirectory.appendingPathComponent(cacheKey(for: identity))
        if let data = try? Data(contentsOf: diskURL) {
            return LoadedImageData(data: data, origin: .disk)
        }
        if identity.rawValue != url.absoluteString {
            let legacyDiskURL = cacheDirectory.appendingPathComponent(
                legacyCacheKey(for: url)
            )
            if let data = try? Data(contentsOf: legacyDiskURL) {
                try? persistMigratedData(data, at: diskURL)
                return LoadedImageData(data: data, origin: .disk)
            }
        }
        return LoadedImageData(
            data: try await downloadedData(for: url),
            origin: .network
        )
    }

    func downloadedData(for url: URL) async throws -> Data {
        if let load = inFlight[url] {
            return try await consume(load, for: url)
        }

        let loadID = UUID()
        let task = Task<Data, Error> {
            let imageRequest = InlineImageRequest.parse(url)
            do {
                return try await sendImageRequest(
                    url: imageRequest.url,
                    headers: imageRequest.headers
                )
            } catch let error as HTTPClientError {
                guard case .statusCode(let statusCode) = error,
                      [401, 403, 418].contains(statusCode),
                      !Self.hasReferer(in: imageRequest.headers),
                      let referer = Self.sameOriginReferer(
                        for: imageRequest.url
                      ) else {
                    throw error
                }
                var fallbackHeaders = imageRequest.headers
                fallbackHeaders["Referer"] = referer
                // This is the only compatibility fallback. If it fails, the
                // HTTP client's original typed error (including status code)
                // is propagated unchanged.
                return try await sendImageRequest(
                    url: imageRequest.url,
                    headers: fallbackHeaders
                )
            }
        }
        inFlight[url] = InFlightImageDataLoad(id: loadID, task: task)
        defer {
            if inFlight[url]?.id == loadID {
                inFlight[url] = nil
                consumers[url] = nil
            }
        }
        return try await consume(InFlightImageDataLoad(id: loadID, task: task), for: url)
    }

    private func consume(_ load: InFlightImageDataLoad, for url: URL) async throws -> Data {
        let token = UUID()
        consumers[url, default: []].insert(token)
        defer { release(token, for: url, loadID: load.id) }
        return try await withTaskCancellationHandler(operation: {
            let data = try await load.task.value
            try Task.checkCancellation()
            return data
        }, onCancel: {
            Task { await self.release(token, for: url, loadID: load.id) }
        })
    }

    private func release(_ token: UUID, for url: URL, loadID: UUID) {
        guard inFlight[url]?.id == loadID else { return }
        consumers[url]?.remove(token)
        if consumers[url]?.isEmpty == true {
            inFlight[url]?.task.cancel()
            inFlight[url] = nil
            consumers[url] = nil
        }
    }

    private func sendImageRequest(
        url: URL,
        headers: HTTPHeaders
    ) async throws -> Data {
        let response = try await httpClient.send(
            HTTPRequest(
                url: url,
                headers: headers,
                timeout: 20,
                maximumResponseBytes: 10 * 1_024 * 1_024,
                retryPolicy: HTTPRetryPolicy(maximumRetries: 0)
            )
        )
        return response.body
    }

    private static func hasReferer(in headers: HTTPHeaders) -> Bool {
        guard let value = headers["Referer"] else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sameOriginReferer(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !["127.0.0.1", "localhost", "::1"].contains(host) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url?.absoluteString
    }

    func cancelInFlightLoads() {
        for load in inFlight.values {
            load.task.cancel()
        }
        inFlight.removeAll()
        consumers.removeAll()
    }

    func persistValidatedData(_ data: Data, for url: URL) throws {
        let identity = ImageCacheIdentity(url: url)
        let diskURL = cacheDirectory.appendingPathComponent(cacheKey(for: identity))
        try data.write(to: diskURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: diskURL.path
        )
    }

    func clear() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func cacheKey(for identity: ImageCacheIdentity) -> String {
        let digest = SHA256.hash(data: Data(identity.rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".image"
    }

    private func legacyCacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".image"
    }

    private func persistMigratedData(_ data: Data, at diskURL: URL) throws {
        try data.write(to: diskURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: diskURL.path
        )
    }
}

struct PosterImageRequest: Hashable, Sendable {
    let url: URL
    let pixels: Int
    init(url: URL, pixels: Int) {
        self.url = url
        self.pixels = Self.bucket(CGFloat(pixels))
    }
    static func bucket(_ pixels: CGFloat) -> Int {
        guard pixels.isFinite else { return 512 }
        return max(128, Int(ceil(min(2048, max(0, pixels)) / 128)) * 128)
    }
}

enum PosterImagePriority: Int, Sendable {
    case hero = -2, selected = -1, visible = 0, forward, reverse
    var isImmediate: Bool { rawValue <= 0 }
}

struct PosterImageDemand: Equatable, Sendable, Comparable {
    let priority: PosterImagePriority
    let distance: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.priority.isImmediate || rhs.priority.isImmediate {
            if lhs.priority != rhs.priority { return lhs.priority.rawValue < rhs.priority.rawValue }
        }
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.priority.rawValue < rhs.priority.rawValue
    }
}

private struct DecodedPoster: @unchecked Sendable {
    let image: CGImage
    let usedMainThread: Bool
}

/// Two serial workers keep decode concurrency bounded without blocking a
/// thread on a semaphore or creating a task for every item in a library.
private actor PosterDecodeWorker {
    func decode(_ data: Data, pixels: Int) throws -> DecodedPoster {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else {
            throw AppError.decoding(L10n.string("poster.invalid-image", fallback: "The poster is not a valid image."))
        }
        return DecodedPoster(image: image, usedMainThread: Thread.isMainThread)
    }
}

actor PosterImagePipeline {
    struct Stats: Sendable {
        let active: Int
        let queued: Int
        let maximumActive: Int
        let maximumQueued: Int
        let decoded: Int
        let decodedOnMain: Int
    }
    private struct Entry {
        var id: UUID
        let order: UInt64
        var consumers: [UUID: Consumer]
        var task: Task<Void, Never>?
        var preempted = false

        var demand: PosterImageDemand { consumers.values.map(\.demand).min()! }
    }
    private struct Consumer {
        var demand: PosterImageDemand
        var revision: UInt64 = 0
        let continuation: CheckedContinuation<DecodedPoster, Error>
    }
    private struct Running {
        let request: PosterImageRequest
        var demand: PosterImageDemand
        var stopping = false
    }
    private let dataRepository: ImageDataRepository
    private let workers = [PosterDecodeWorker(), PosterDecodeWorker()]
    private var workerIndex = 0
    private var entries: [PosterImageRequest: Entry] = [:]
    private var running: [UUID: Running] = [:]
    private var pendingDemands: [UUID: (revision: UInt64, demand: PosterImageDemand)] = [:]
    private var retiredConsumers: Set<UUID> = []
    private var retiredOrder: [UUID] = []
    private var sequence: UInt64 = 0
    private var maximumActive = 0
    private var maximumQueued = 0
    private var decoded = 0
    private var decodedOnMain = 0
    private let queueLimit = 96

    init(dataRepository: ImageDataRepository) { self.dataRepository = dataRepository }

    fileprivate func image(for request: PosterImageRequest, demand: PosterImageDemand, consumer: UUID) async throws -> DecodedPoster {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let pending = pendingDemands.removeValue(forKey: consumer)
                let currentDemand = pending?.demand ?? demand
                let revision = pending?.revision ?? 0
                if var entry = entries[request] {
                    entry.consumers[consumer] = Consumer(demand: currentDemand, revision: revision, continuation: continuation)
                    entries[request] = entry
                    refreshRunning(for: entry)
                } else {
                    let queued = entries.filter { $0.value.task == nil }
                    if queued.count >= queueLimit {
                        // A visible request can displace speculative work, never another visible consumer.
                        if let victim = queued.filter({ $0.value.demand > currentDemand })
                            .max(by: { $0.value.demand < $1.value.demand })?.key {
                            if let removed = entries.removeValue(forKey: victim) {
                                removed.consumers.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
                            }
                        } else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                    }
                    sequence &+= 1
                    entries[request] = Entry(id: UUID(), order: sequence,
                        consumers: [consumer: Consumer(demand: currentDemand, revision: revision, continuation: continuation)], task: nil)
                }
                drain()
                maximumQueued = max(maximumQueued, entries.values.filter { $0.task == nil }.count)
            }
        }, onCancel: {
            Task { await self.cancel(consumer: consumer, request: request) }
        })
    }

    private func cancel(consumer: UUID, request: PosterImageRequest) {
        pendingDemands[consumer] = nil
        guard var entry = entries[request], let removed = entry.consumers.removeValue(forKey: consumer) else { return }
        removed.continuation.resume(throwing: CancellationError())
        if entry.consumers.isEmpty {
            entries[request] = nil
            entry.task?.cancel()
            if running[entry.id] != nil { running[entry.id]?.stopping = true }
        } else {
            entries[request] = entry
            refreshRunning(for: entry)
        }
        drain()
    }

    func update(consumer: UUID, request: PosterImageRequest, demand: PosterImageDemand, revision: UInt64) {
        guard !retiredConsumers.contains(consumer) else { return }
        guard var entry = entries[request], var value = entry.consumers[consumer] else {
            // An update may overtake the initial actor hop from the preheater.
            if revision > (pendingDemands[consumer]?.revision ?? 0) {
                pendingDemands[consumer] = (revision, demand)
            }
            return
        }
        guard revision > value.revision else { return }
        value.demand = demand
        value.revision = revision
        entry.consumers[consumer] = value
        entries[request] = entry
        refreshRunning(for: entry)
        drain()
    }

    func forget(consumer: UUID) {
        pendingDemands[consumer] = nil
        if retiredConsumers.insert(consumer).inserted { retiredOrder.append(consumer) }
        if retiredOrder.count > 256 {
            for old in retiredOrder.prefix(128) { retiredConsumers.remove(old) }
            retiredOrder.removeFirst(128)
        }
    }

    private func refreshRunning(for entry: Entry) {
        if running[entry.id] != nil { running[entry.id]?.demand = entry.demand }
    }

    func cancelAll() {
        for entry in entries.values {
            entry.consumers.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
            entry.task?.cancel()
            if running[entry.id] != nil { running[entry.id]?.stopping = true }
        }
        entries.removeAll()
        pendingDemands.removeAll()
    }

    func stats() -> Stats {
        Stats(active: running.count, queued: entries.values.filter { $0.task == nil }.count,
              maximumActive: maximumActive, maximumQueued: maximumQueued, decoded: decoded, decodedOnMain: decodedOnMain)
    }

    private func drain() {
        // A request that was visible may become speculative while its network
        // task is still active. Reclaim only the excess slots, preserving all
        // consumer continuations so the request can resume if it is needed.
        let speculative = running.filter { !$0.value.stopping && !$0.value.demand.priority.isImmediate }
        for (id, _) in speculative.sorted(by: { $0.value.demand > $1.value.demand }).prefix(max(0, speculative.count - 2)) {
            preempt(id)
        }
        let visibleWaiting = entries.values.filter { $0.task == nil && $0.demand.priority.isImmediate }.count
        let stopping = running.values.filter(\.stopping).count
        let freeWhenStopped = max(0, 6 - (running.count - stopping))
        for _ in 0..<max(0, visibleWaiting - freeWhenStopped) {
            guard let victim = running.filter({ !$0.value.stopping && !$0.value.demand.priority.isImmediate })
                .max(by: { $0.value.demand < $1.value.demand })?.key else { break }
            preempt(victim)
        }
        while running.count < 6 {
            let speculativeActive = running.values.filter { !$0.demand.priority.isImmediate }.count
            guard let pair = entries.filter({ $0.value.task == nil && ($0.value.demand.priority.isImmediate || speculativeActive < 2) })
                .min(by: { lhs, rhs in
                    lhs.value.demand == rhs.value.demand ? lhs.value.order < rhs.value.order : lhs.value.demand < rhs.value.demand
                }) else { return }
            let request = pair.key
            var entry = pair.value
            let id = UUID()
            entry.id = id
            let demand = entry.demand
            let worker = workers[workerIndex % workers.count]
            workerIndex += 1
            running[id] = Running(request: request, demand: demand)
            maximumActive = max(maximumActive, running.count)
            entry.task = Task { [dataRepository] in
                let result: Result<DecodedPoster, Error>
                do {
                    var loaded = try await dataRepository.data(for: request.url)
                    try Task.checkCancellation()
                    let image: DecodedPoster
                    do { image = try await worker.decode(loaded.data, pixels: request.pixels) }
                    catch {
                        guard loaded.origin == .disk, !Task.isCancelled else { throw error }
                        loaded = LoadedImageData(data: try await dataRepository.downloadedData(for: request.url), origin: .network)
                        image = try await worker.decode(loaded.data, pixels: request.pixels)
                    }
                    try Task.checkCancellation()
                    if loaded.origin == .network { try await dataRepository.persistValidatedData(loaded.data, for: request.url) }
                    result = .success(image)
                } catch { result = .failure(error) }
                finish(request: request, id: id, result: result)
            }
            entries[request] = entry
        }
    }

    private func preempt(_ id: UUID) {
        guard let run = running[id], !run.stopping,
              var entry = entries[run.request], entry.id == id else { return }
        running[id]?.stopping = true
        entry.preempted = true
        entry.task?.cancel()
        entries[run.request] = entry
    }

    private func finish(request: PosterImageRequest, id: UUID, result: Result<DecodedPoster, Error>) {
        running[id] = nil
        if case .success(let value) = result { decoded += 1; if value.usedMainThread { decodedOnMain += 1 } }
        if var entry = entries[request], entry.id == id {
            if entry.preempted, case .failure(let error) = result,
               AsyncCancellationPolicy.isCancellation(error) {
                entry.task = nil
                entry.preempted = false
                entries[request] = entry
            } else {
                entries[request] = nil
                for consumer in entry.consumers.values { consumer.continuation.resume(with: result) }
            }
        }
        drain()
    }
}

final class ImageRepository: Sendable {
    private let dataRepository: ImageDataRepository
    private let posterPipeline: PosterImagePipeline
    @MainActor private let memoryCache = ImageMemoryCache()
    @MainActor private var inFlightImages: [URL: InFlightImageLoad] = [:]

    init(dataRepository: ImageDataRepository) {
        self.dataRepository = dataRepository
        self.posterPipeline = PosterImagePipeline(dataRepository: dataRepository)
    }

    @MainActor
    func cachedPoster(for request: PosterImageRequest) -> NSImage? {
        memoryCache.poster(for: request)
    }

    @MainActor
    func posterImage(for request: PosterImageRequest, priority: PosterImagePriority = .visible,
                     distance: Int = 0, consumer: UUID? = nil) async throws -> NSImage {
        let token = consumer ?? UUID()
        defer { if let consumer { Task { await posterPipeline.forget(consumer: consumer) } } }
        if let cached = cachedPoster(for: request) { return cached }
        let decoded = try await posterPipeline.image(for: request,
            demand: PosterImageDemand(priority: priority, distance: distance), consumer: token)
        try Task.checkCancellation()
        if let cached = cachedPoster(for: request) { return cached }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        memoryCache.insertPoster(image, for: request,
            decodedCost: decoded.image.bytesPerRow * decoded.image.height)
        return image
    }

    func posterPipelineStats() async -> PosterImagePipeline.Stats { await posterPipeline.stats() }

    @MainActor
    func updatePosterPriority(for request: PosterImageRequest, consumer: UUID,
                              priority: PosterImagePriority, distance: Int, revision: UInt64) {
        Task { await posterPipeline.update(consumer: consumer, request: request,
            demand: PosterImageDemand(priority: priority, distance: distance), revision: revision) }
    }

    @MainActor
    func cachedImage(for url: URL) -> NSImage? {
        memoryCache.image(for: ImageCacheIdentity(url: url))
    }

    @MainActor
    func image(for url: URL) async throws -> NSImage {
        if let cached = cachedImage(for: url) {
            return cached
        }
        if let load = inFlightImages[url] {
            try await load.task.value
            return try cachedImageAfterLoad(for: url)
        }

        let loadID = UUID()
        let task = Task { @MainActor in
            try await loadAndCacheImage(for: url)
        }
        inFlightImages[url] = InFlightImageLoad(id: loadID, task: task)
        defer {
            if inFlightImages[url]?.id == loadID {
                inFlightImages[url] = nil
            }
        }
        try await task.value
        return try cachedImageAfterLoad(for: url)
    }

    @MainActor
    func trimDecodedMemoryCache() { memoryCache.removeAll() }

    @MainActor
    func clear() async throws {
        memoryCache.removeAll()
        try await dataRepository.clear()
    }

    @MainActor
    func cancelInFlightLoads() async {
        await posterPipeline.cancelAll()
        for load in inFlightImages.values {
            load.task.cancel()
        }
        inFlightImages.removeAll()
        await dataRepository.cancelInFlightLoads()
    }

    @MainActor
    private func loadAndCacheImage(for url: URL) async throws {
        if cachedImage(for: url) != nil {
            return
        }

        var loaded = try await dataRepository.data(for: url)
        try Task.checkCancellation()
        if cachedImage(for: url) != nil {
            return
        }

        var image = NSImage(data: loaded.data)
        if image == nil, loaded.origin == .disk {
            loaded = LoadedImageData(
                data: try await dataRepository.downloadedData(for: url),
                origin: .network
            )
            try Task.checkCancellation()
            if cachedImage(for: url) != nil {
                return
            }
            image = NSImage(data: loaded.data)
        }

        guard let image else {
            throw AppError.decoding(
                L10n.string("poster.invalid-image", fallback: "The poster is not a valid image.")
            )
        }
        if loaded.origin == .network {
            try await dataRepository.persistValidatedData(loaded.data, for: url)
        }
        memoryCache.insert(image, for: ImageCacheIdentity(url: url))
    }

    @MainActor
    private func cachedImageAfterLoad(for url: URL) throws -> NSImage {
        guard let image = cachedImage(for: url) else {
            throw AppError.decoding(
                L10n.string("poster.invalid-image", fallback: "The poster is not a valid image.")
            )
        }
        return image
    }
}

enum RemoteImageLoadingPolicy {
    static func shouldClearCurrentImage(for nextURL: URL?) -> Bool {
        nextURL == nil
    }

    static func shouldShowFailure(hasCurrentImage: Bool) -> Bool {
        !hasCurrentImage
    }
}

/// Posters never display an image belonging to a prior URL or size rendition.
#if DEBUG
struct PosterRemoteImage: View {
    @Environment(\.imageRepository) private var repository
    @Environment(\.posterCardPriority) private var priority
    let request: PosterImageRequest
    @State private var loaded: (request: PosterImageRequest, image: NSImage)?
    @State private var failedRequest: PosterImageRequest?

    private var displayed: NSImage? {
        if loaded?.request == request { return loaded?.image }
        return repository?.cachedPoster(for: request)
    }
    var body: some View {
        let imageAtRender = displayed
        Group {
            if let image = imageAtRender {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Group {
                    if failedRequest == request {
                        Image(systemName: "photo").font(.title2)
                            .foregroundColor(.secondary)
                    } else {
                        Color.clear
                    }
                }
                // A hot memory-cache hit never mounts the loading task.
                .task(id: request) {
                    if failedRequest != nil { failedRequest = nil }
                    guard let repository else { return }
                    do {
                        let image = try await repository.posterImage(for: request,
                            priority: priority,
                            distance: priority == .reverse ? Int.max : 0)
                        guard !Task.isCancelled else { return }
                        loaded = (request, image)
                    } catch {
                        guard !Task.isCancelled,
                              !AsyncCancellationPolicy.isCancellation(error) else { return }
                        failedRequest = request
                    }
                }
            }
        }
        .onChange(of: request) { nextRequest in
            if loaded?.request != nextRequest { loaded = nil }
            if failedRequest != nil { failedRequest = nil }
        }
        .onDisappear {
            loaded = nil
            failedRequest = nil
        }
    }
}
#endif

#if DEBUG
private struct PosterLabNativeImageKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PosterLabLegacyImageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var posterLabNativeImage: Bool {
        get { self[PosterLabNativeImageKey.self] }
        set { self[PosterLabNativeImageKey.self] = newValue }
    }

    var posterLabLegacyImage: Bool {
        get { self[PosterLabLegacyImageKey.self] }
        set { self[PosterLabLegacyImageKey.self] = newValue }
    }
}
#endif

/// Isolated image-carrier experiment. The real repository and request remain
/// unchanged; image completion updates AppKit instead of SwiftUI card state.
struct PosterNativeRemoteImage: NSViewRepresentable {
    @Environment(\.imageRepository) private var repository
    @Environment(\.posterCardPriority) private var priority
    let request: PosterImageRequest

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        context.coordinator.update(view: view, request: request,
            repository: repository, priority: priority)
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private weak var repository: ImageRepository?
        private var request: PosterImageRequest?
        private var task: Task<Void, Never>?
        private var generation: UInt64 = 0

        func update(view: NSView, request: PosterImageRequest,
                    repository: ImageRepository?, priority: PosterImagePriority) {
            guard self.view !== view || self.request != request ||
                  self.repository !== repository else { return }
            task?.cancel()
            task = nil
            generation &+= 1
            let currentGeneration = generation
            self.view = view
            self.request = request
            self.repository = repository
            let cached = repository?.cachedPoster(for: request)
            show(cached)
            guard cached == nil, let repository else { return }
            task = Task { [weak self] in
                do {
                    let image = try await repository.posterImage(for: request,
                        priority: priority,
                        distance: priority == .reverse ? Int.max : 0)
                    guard !Task.isCancelled, let self,
                          self.generation == currentGeneration,
                          self.request == request else { return }
                    self.show(image)
                    self.task = nil
                } catch {
                    guard !Task.isCancelled, let self,
                          self.generation == currentGeneration,
                          self.request == request,
                          !AsyncCancellationPolicy.isCancellation(error) else { return }
                    if let layerView = self.view as? PosterLayerImageView {
                        layerView.showFailure()
                    } else {
                        self.show(NSImage(systemSymbolName: "photo",
                            accessibilityDescription: nil))
                    }
                    self.task = nil
                }
            }
        }

        private func show(_ image: NSImage?) {
            if let imageView = view as? NSImageView {
                imageView.image = image
            } else if let layerView = view as? PosterLayerImageView {
                layerView.show(image)
            }
        }

        func cancel() {
            generation &+= 1
            task?.cancel()
            task = nil
            show(nil)
            view = nil
            request = nil
            repository = nil
        }
    }
}

/// This second carrier keeps image changes inside a stable layer-backed view.
/// It has no image-dependent intrinsic size and does not invalidate SwiftUI
/// card state when a decoded poster arrives.
struct PosterLayerRemoteImage: NSViewRepresentable {
    @Environment(\.imageRepository) private var repository
    @Environment(\.posterCardPriority) private var priority
    let request: PosterImageRequest

    func makeCoordinator() -> PosterNativeRemoteImage.Coordinator {
        PosterNativeRemoteImage.Coordinator()
    }

    func makeNSView(context: Context) -> PosterLayerImageView {
        let view = PosterLayerImageView(frame: .zero)
        view.onDetach = { [weak coordinator = context.coordinator] in
            coordinator?.cancel()
        }
        return view
    }

    func updateNSView(_ view: PosterLayerImageView, context: Context) {
        context.coordinator.update(view: view, request: request,
            repository: repository, priority: priority)
    }

    static func dismantleNSView(_ view: PosterLayerImageView,
                                coordinator: PosterNativeRemoteImage.Coordinator) {
        coordinator.cancel()
        view.onDetach = nil
    }
}

final class PosterLayerImageView: NSView {
    var onDetach: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { onDetach?() }
    }

    func show(_ image: NSImage?) {
        layer?.contentsGravity = .resizeAspect
        layer?.contents = image?.cgImage(forProposedRect: nil,
            context: nil, hints: nil)
    }

    func showFailure() {
        layer?.contentsGravity = .center
        layer?.contents = NSImage(systemSymbolName: "photo",
            accessibilityDescription: nil)?.cgImage(forProposedRect: nil,
                context: nil, hints: nil)
    }
}

@MainActor
final class PosterPreheater {
    private struct Job {
        let consumer: UUID
        let task: Task<Void, Never>
        var demand: PosterImageDemand
        var revision: UInt64 = 0
        var finished = false
    }
    private var jobs: [PosterImageRequest: Job] = [:]
    private var lastPlan: [PosterPrefetchRequest] = []
    func update(_ plan: [PosterPrefetchRequest], repository: ImageRepository?) {
        let plan = Self.coalesced(plan)
        guard plan != lastPlan else { return }
        lastPlan = plan
        let demands = Dictionary(uniqueKeysWithValues: plan.map { ($0.request, $0.demand) })
        for key in Array(jobs.keys) where demands[key] == nil { jobs.removeValue(forKey: key)?.task.cancel() }
        guard let repository else { return }
        for item in plan {
            let request = item.request
            if var job = jobs[request] {
                if job.demand != item.demand {
                    job.demand = item.demand
                    job.revision &+= 1
                    jobs[request] = job
                    if !job.finished {
                        repository.updatePosterPriority(for: request, consumer: job.consumer,
                            priority: item.demand.priority, distance: item.demand.distance, revision: job.revision)
                    }
                }
            } else if repository.cachedPoster(for: request) == nil {
                let consumer = UUID()
                let task = Task { [weak self] in
                    _ = try? await repository.posterImage(for: request, priority: item.demand.priority,
                        distance: item.demand.distance, consumer: consumer)
                    self?.markFinished(request: request, consumer: consumer)
                }
                jobs[request] = Job(consumer: consumer, task: task, demand: item.demand)
            }
        }
    }
    /// Several cards can share artwork. Preserve ordering and the strongest demand.
    static func coalesced(_ plan: [PosterPrefetchRequest]) -> [PosterPrefetchRequest] {
        var indices: [PosterImageRequest: Int] = [:]
        var result: [PosterPrefetchRequest] = []
        for item in plan {
            if let index = indices[item.request] {
                if item.demand < result[index].demand { result[index] = item }
            } else {
                indices[item.request] = result.count
                result.append(item)
            }
        }
        return result
    }

    private func markFinished(request: PosterImageRequest, consumer: UUID) {
        guard jobs[request]?.consumer == consumer else { return }
        jobs[request]?.finished = true
    }
    func cancel() {
        jobs.values.forEach { $0.task.cancel() }
        jobs.removeAll()
        lastPlan.removeAll()
    }
    deinit { jobs.values.forEach { $0.task.cancel() } }
}

struct PosterPrefetchRequest: Equatable {
    let request: PosterImageRequest
    let demand: PosterImageDemand
}

private struct PosterCardPriorityKey: EnvironmentKey {
    static let defaultValue: PosterImagePriority = .visible
}

extension EnvironmentValues {
    var posterCardPriority: PosterImagePriority {
        get { self[PosterCardPriorityKey.self] }
        set { self[PosterCardPriorityKey.self] = newValue }
    }
}

private struct ImageRepositoryKey: EnvironmentKey {
    static let defaultValue: ImageRepository? = nil
}

extension EnvironmentValues {
    var imageRepository: ImageRepository? {
        get { self[ImageRepositoryKey.self] }
        set { self[ImageRepositoryKey.self] = newValue }
    }
}

struct RemoteImage<Content: View, Placeholder: View>: View {
    @Environment(\.imageRepository) private var repository
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadFailed = false

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                content(Image(nsImage: image))
            } else if loadFailed {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundColor(.secondary)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            loadFailed = false
            if RemoteImageLoadingPolicy.shouldClearCurrentImage(for: url) {
                image = nil
            }
            guard let url, let repository else { return }
            if let cached = repository.cachedImage(for: url) {
                image = cached
                return
            }
            do {
                let loaded = try await repository.image(for: url)
                guard !Task.isCancelled, self.url == url else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled, self.url == url else { return }
                loadFailed = RemoteImageLoadingPolicy.shouldShowFailure(
                    hasCurrentImage: image != nil || repository.cachedImage(for: url) != nil
                )
            }
        }
    }

    private var displayedImage: NSImage? {
        image ?? url.flatMap { repository?.cachedImage(for: $0) }
    }
}

struct RemoteImageCandidates<Content: View, Placeholder: View>: View {
    @Environment(\.imageRepository) private var repository
    let urls: [URL]
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: NSImage?

    init(
        urls: [URL],
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                content(Image(nsImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            image = nil
            guard let repository else { return }
            if let cached = urls.lazy.compactMap({
                repository.cachedImage(for: $0)
            }).first {
                image = cached
                return
            }
            for candidate in urls {
                guard !Task.isCancelled else { return }
                guard let loaded = try? await repository.image(for: candidate) else {
                    continue
                }
                guard !Task.isCancelled, urls.contains(candidate) else { return }
                image = loaded
                return
            }
        }
    }

    private var displayedImage: NSImage? {
        image ?? urls.lazy.compactMap { repository?.cachedImage(for: $0) }.first
    }
}
