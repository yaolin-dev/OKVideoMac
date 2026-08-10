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

private final class ImageMemoryCache {
    private let storage = NSCache<NSURL, NSImage>()

    init() {
        storage.countLimit = 300
        storage.totalCostLimit = 128 * 1_024 * 1_024
    }

    func image(for url: URL) -> NSImage? {
        storage.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL, cost: Int = 0) {
        storage.setObject(image, forKey: url as NSURL, cost: cost)
    }

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

actor ImageDataRepository {
    private let cacheDirectory: URL
    private let httpClient: HTTPClient
    private var inFlight: [URL: Task<Data, Error>] = [:]

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
        let diskURL = cacheDirectory.appendingPathComponent(cacheKey(for: url))
        if let data = try? Data(contentsOf: diskURL) {
            return LoadedImageData(data: data, origin: .disk)
        }
        return LoadedImageData(
            data: try await downloadedData(for: url),
            origin: .network
        )
    }

    func downloadedData(for url: URL) async throws -> Data {
        if let task = inFlight[url] {
            return try await task.value
        }

        let task = Task<Data, Error> {
            let imageRequest = InlineImageRequest.parse(url)
            let response = try await httpClient.send(
                HTTPRequest(
                    url: imageRequest.url,
                    headers: imageRequest.headers,
                    timeout: 20,
                    maximumResponseBytes: 10 * 1_024 * 1_024,
                    retryPolicy: HTTPRetryPolicy(maximumRetries: 1)
                )
            )
            return response.body
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    func persistValidatedData(_ data: Data, for url: URL) throws {
        let diskURL = cacheDirectory.appendingPathComponent(cacheKey(for: url))
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

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".image"
    }
}

final class ImageRepository: Sendable {
    private let dataRepository: ImageDataRepository
    @MainActor private let memoryCache = ImageMemoryCache()
    @MainActor private var inFlightImages: [URL: Task<Void, Error>] = [:]

    init(dataRepository: ImageDataRepository) {
        self.dataRepository = dataRepository
    }

    @MainActor
    func cachedImage(for url: URL) -> NSImage? {
        memoryCache.image(for: url)
    }

    @MainActor
    func image(for url: URL) async throws -> NSImage {
        if let cached = cachedImage(for: url) {
            return cached
        }
        if let task = inFlightImages[url] {
            try await task.value
            return try cachedImageAfterLoad(for: url)
        }

        let task = Task { @MainActor in
            try await loadAndCacheImage(for: url)
        }
        inFlightImages[url] = task
        defer { inFlightImages[url] = nil }
        try await task.value
        return try cachedImageAfterLoad(for: url)
    }

    @MainActor
    func clear() async throws {
        memoryCache.removeAll()
        try await dataRepository.clear()
    }

    @MainActor
    private func loadAndCacheImage(for url: URL) async throws {
        if cachedImage(for: url) != nil {
            return
        }

        var loaded = try await dataRepository.data(for: url)
        if cachedImage(for: url) != nil {
            return
        }

        var image = NSImage(data: loaded.data)
        if image == nil, loaded.origin == .disk {
            loaded = LoadedImageData(
                data: try await dataRepository.downloadedData(for: url),
                origin: .network
            )
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
        memoryCache.insert(
            image,
            for: url,
            cost: loaded.origin == .disk ? loaded.data.count : 0
        )
    }

    @MainActor
    private func cachedImageAfterLoad(for url: URL) throws -> NSImage {
        guard let image = cachedImage(for: url) else {
            throw AppError.decoding("海报不是有效图片")
        }
        return image
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
            image = nil
            loadFailed = false
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
                loadFailed = true
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
