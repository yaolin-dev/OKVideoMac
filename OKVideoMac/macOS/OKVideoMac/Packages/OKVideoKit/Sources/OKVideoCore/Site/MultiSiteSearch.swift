import Foundation

public struct SearchFailure: Equatable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var message: String

    public init(siteKey: String, siteName: String, message: String) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.message = message
    }
}

public enum MultiSiteSearchEvent: Equatable, Sendable {
    case results(siteKey: String, items: [VideoSummary])
    case failure(SearchFailure)
    case completed
}

private enum SiteSearchOutcome: Sendable {
    case results([VideoSummary])
    case failure(String)
    case cancelled
}

private actor FirstSiteSearchOutcome {
    private var bufferedOutcome: SiteSearchOutcome?
    private var waiter: CheckedContinuation<SiteSearchOutcome, Never>?
    private var isResolved = false

    func wait() async -> SiteSearchOutcome {
        if let bufferedOutcome {
            self.bufferedOutcome = nil
            return bufferedOutcome
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ outcome: SiteSearchOutcome) {
        guard !isResolved else { return }
        isResolved = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: outcome)
        } else {
            bufferedOutcome = outcome
        }
    }
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
        let outcome = await searchWithTimeout(
            provider: provider,
            keyword: keyword,
            quick: quick,
            timeout: Self.effectiveSiteTimeout(
                base: siteTimeout,
                capability: provider.capability
            )
        )
        switch outcome {
        case .results(let items):
            return .results(
                siteKey: provider.site.key,
                items: items
            )
        case .cancelled:
            return .failure(
                SearchFailure(
                    siteKey: provider.site.key,
                    siteName: provider.site.name,
                    message: "已取消"
                )
            )
        case .failure(let message):
            return .failure(
                SearchFailure(
                    siteKey: provider.site.key,
                    siteName: provider.site.name,
                    message: message
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
        // The Android bridge allows up to roughly 70 seconds for a Java/Dex
        // invocation. Keep that exception local to the bridge: JavaScript
        // and local Node providers use the generic timeout so a hung HTTP
        // search cannot leave aggregate progress parked for 75 seconds.
        switch capability {
        case .javaDexSpider:
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
    ) async -> SiteSearchOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let firstOutcome = FirstSiteSearchOutcome()
        let providerTask = Task {
            do {
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

                await firstOutcome.resolve(.results(collected))
            } catch is CancellationError {
                await firstOutcome.resolve(.cancelled)
            } catch {
                await firstOutcome.resolve(.failure(error.localizedDescription))
            }
        }
        let timeoutTask = Task {
            do {
                let nanoseconds = UInt64(
                    min(timeout, 300) * 1_000_000_000
                )
                try await Task.sleep(nanoseconds: nanoseconds)
                await firstOutcome.resolve(
                    .failure("搜索超时（\(Int(timeout)) 秒）")
                )
            } catch {
                // The winning provider result or parent cancellation stops
                // this timer. It must not overwrite the first outcome.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await firstOutcome.wait()
        } onCancel: {
            providerTask.cancel()
            timeoutTask.cancel()
            Task {
                await firstOutcome.resolve(.cancelled)
            }
        }
        providerTask.cancel()
        timeoutTask.cancel()
        return outcome
    }
}
