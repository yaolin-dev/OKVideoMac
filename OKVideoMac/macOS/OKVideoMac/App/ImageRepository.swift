import AppKit
import CryptoKit
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

    init(url: URL) {
        rawValue = Self.nodeImageProxyIdentity(for: url) ?? url.absoluteString
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

private final class ImageMemoryCache {
    private let storage = NSCache<NSString, NSImage>()

    init() {
        storage.countLimit = 300
        storage.totalCostLimit = 128 * 1_024 * 1_024
    }

    @MainActor
    func image(for identity: ImageCacheIdentity) -> NSImage? {
        storage.object(forKey: identity.rawValue as NSString)
    }

    @MainActor
    func insert(_ image: NSImage, for identity: ImageCacheIdentity) {
        storage.setObject(
            image,
            forKey: identity.rawValue as NSString,
            cost: DecodedImageCacheCost.cost(for: image)
        )
    }

    @MainActor
    func removeAll() {
        storage.removeAllObjects()
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
            return try await load.task.value
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
            }
        }
        return try await task.value
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

final class ImageRepository: Sendable {
    private let dataRepository: ImageDataRepository
    @MainActor private let memoryCache = ImageMemoryCache()
    @MainActor private var inFlightImages: [URL: InFlightImageLoad] = [:]

    init(dataRepository: ImageDataRepository) {
        self.dataRepository = dataRepository
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
    func clear() async throws {
        memoryCache.removeAll()
        try await dataRepository.clear()
    }

    @MainActor
    func cancelInFlightLoads() async {
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
            throw AppError.decoding("海报不是有效图片")
        }
        if loaded.origin == .network {
            try await dataRepository.persistValidatedData(loaded.data, for: url)
        }
        memoryCache.insert(image, for: ImageCacheIdentity(url: url))
    }

    @MainActor
    private func cachedImageAfterLoad(for url: URL) throws -> NSImage {
        guard let image = cachedImage(for: url) else {
            throw AppError.decoding("海报不是有效图片")
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
