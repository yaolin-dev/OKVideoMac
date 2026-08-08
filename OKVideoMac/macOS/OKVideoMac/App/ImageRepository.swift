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

actor ImageRepository {
    private let memoryCache = NSCache<NSURL, NSImage>()
    private let cacheDirectory: URL
    private let httpClient: HTTPClient
    private var inFlight: [URL: Task<NSImage, Error>] = [:]

    init(cacheDirectory: URL, httpClient: HTTPClient) throws {
        self.cacheDirectory = cacheDirectory
        self.httpClient = httpClient
        memoryCache.countLimit = 300
        memoryCache.totalCostLimit = 128 * 1_024 * 1_024
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

    func image(for url: URL) async throws -> NSImage {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }
        let diskURL = cacheDirectory.appendingPathComponent(cacheKey(for: url))
        if let data = try? Data(contentsOf: diskURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        }
        if let task = inFlight[url] {
            return try await task.value
        }

        let task = Task<NSImage, Error> {
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
            guard let image = NSImage(data: response.body) else {
                throw AppError.decoding("海报不是有效图片")
            }
            try response.body.write(to: diskURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: diskURL.path
            )
            return image
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let image = try await task.value
        memoryCache.setObject(image, forKey: url as NSURL)
        return image
    }

    func clear() throws {
        memoryCache.removeAllObjects()
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
            if let image {
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
            if let image {
                content(Image(nsImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            image = nil
            guard let repository else { return }
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
}
