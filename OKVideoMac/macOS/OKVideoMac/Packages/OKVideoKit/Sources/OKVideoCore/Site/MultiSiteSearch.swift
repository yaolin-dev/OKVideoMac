import Foundation

public struct SearchFailure: Equatable {
    public var siteKey: String
    public var siteName: String
    public var message: String

    public init(siteKey: String, siteName: String, message: String) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.message = message
    }
}

public enum MultiSiteSearchEvent: Equatable {
    case results(siteKey: String, items: [VideoSummary])
    case failure(SearchFailure)
    case completed
}

public struct MultiSiteSearch {
    public let maximumConcurrency: Int
    public let siteTimeout: TimeInterval
    public let maximumPagesPerSite: Int
    public let maximumResultsPerSite: Int

    public init(
        maximumConcurrency: Int = 20,
        siteTimeout: TimeInterval = 30,
        maximumPagesPerSite: Int = 10,
        maximumResultsPerSite: Int = 500
    ) {
        self.maximumConcurrency = max(1, maximumConcurrency)
        self.siteTimeout = max(0.05, siteTimeout)
        self.maximumPagesPerSite = max(1, maximumPagesPerSite)
        self.maximumResultsPerSite = max(1, maximumResultsPerSite)
    }

    public func search(
        providers: [SiteProvider],
        keyword: String,
        quick: Bool = false
    ) -> AsyncStream<MultiSiteSearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                // FongMi's Site.isSearchable() is true only for value 1.
                // Value 2 represents a user-disabled search site.
                let enabled = providers.filter { $0.site.searchable == 1 }
                await withTaskGroup(of: MultiSiteSearchEvent.self) { group in
                    var nextIndex = 0
                    let initialCount = min(maximumConcurrency, enabled.count)
                    for _ in 0..<initialCount {
                        let provider = enabled[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            await searchEvent(
                                provider: provider,
                                keyword: keyword,
                                quick: quick
                            )
                        }
                    }

                    // Keep a moving window of work. The old chunked scheduler
                    // waited for the slowest site in each batch before it
                    // started any later sites, which caused visible 4/32
                    // stalls even when most providers were responsive.
                    while let event = await group.next() {
                        guard !Task.isCancelled else { break }
                        continuation.yield(event)
                        if nextIndex < enabled.count {
                            let provider = enabled[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                await searchEvent(
                                    provider: provider,
                                    keyword: keyword,
                                    quick: quick
                                )
                            }
                        }
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(.completed)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func searchEvent(
        provider: SiteProvider,
        keyword: String,
        quick: Bool
    ) async -> MultiSiteSearchEvent {
        do {
            let items = try await searchWithTimeout(
                provider: provider,
                keyword: keyword,
                quick: quick,
                timeout: Self.effectiveSiteTimeout(
                    base: siteTimeout,
                    capability: provider.capability
                )
            )
            return .results(
                siteKey: provider.site.key,
                items: items
            )
        } catch is CancellationError {
            return .failure(
                SearchFailure(
                    siteKey: provider.site.key,
                    siteName: provider.site.name,
                    message: "已取消"
                )
            )
        } catch {
            return .failure(
                SearchFailure(
                    siteKey: provider.site.key,
                    siteName: provider.site.name,
                    message: error.localizedDescription
                )
            )
        }
    }

    private static func deduplicatedWithinSite(_ items: [VideoSummary]) -> [VideoSummary] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func effectiveSiteTimeout(
        base: TimeInterval,
        capability: SiteCapability
    ) -> TimeInterval {
        // The Android bridge allows up to roughly 70 seconds for a Spider
        // invocation. Cancelling Java/Dex searches at the generic 30-second
        // limit discards valid late responses from cloud/guard providers.
        switch capability {
        case .javaDexSpider, .javaScriptSpider:
            return max(base, 75)
        default:
            return base
        }
    }

    private func searchWithTimeout(
        provider: SiteProvider,
        keyword: String,
        quick: Bool,
        timeout: TimeInterval
    ) async throws -> [VideoSummary] {
        try await withThrowingTaskGroup(of: [VideoSummary].self) { group in
            group.addTask {
                var pageNumber = 1
                var collected: [VideoSummary] = []
                var seen = Set<String>()

                while pageNumber <= maximumPagesPerSite,
                      collected.count < maximumResultsPerSite {
                    try Task.checkCancellation()
                    let page = try await provider.search(
                        keyword: keyword,
                        page: pageNumber,
                        quick: quick
                    )
                    guard !page.items.isEmpty else { break }

                    var newItemCount = 0
                    for item in page.items where seen.insert(item.id).inserted {
                        collected.append(item)
                        newItemCount += 1
                        if collected.count >= maximumResultsPerSite { break }
                    }

                    // A number of JavaScript sources omit pagecount or always
                    // report it as 0/1. Probe the next page once in that case;
                    // sources which ignore pg stop immediately because they
                    // return no new IDs. An explicit larger pagecount remains
                    // authoritative.
                    guard newItemCount > 0 else { break }
                    if let pageCount = page.pagination.pageCount,
                       pageCount > 1,
                       pageNumber >= pageCount {
                        break
                    }
                    pageNumber += 1
                }

                return collected
            }
            group.addTask {
                let nanoseconds = UInt64(
                    min(timeout, 300) * 1_000_000_000
                )
                try await Task.sleep(nanoseconds: nanoseconds)
                throw AppError.site(
                    "搜索超时（\(Int(timeout)) 秒）"
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}
