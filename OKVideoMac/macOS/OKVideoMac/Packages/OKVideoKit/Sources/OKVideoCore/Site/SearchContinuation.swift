import Foundation

/// Evidence about a page is separate from the scheduler's time/page budget.
public struct SearchPageCursor: Equatable, Sendable {
    public var keyword: String
    public private(set) var nextPage: Int = 1
    public private(set) var seenIDs: Set<String> = []
    // Cursor bookkeeping must not retain every ID from an oversized response
    // after the result pool has discarded it. Recent page signatures also catch
    // providers that repeatedly return the same oversized page in a new order.
    private var recentPageSignatures: [Int] = []
    static let maximumRememberedIDs = 4_096
    public private(set) var ended = false
    public private(set) var uncertain = false
    public var error: String?

    public init(keyword: String) { self.keyword = keyword }

    /// A budget limit is not an upstream end-of-results signal. Re-fetch the
    /// incomplete page on demand; aggregate merging deduplicates retained rows.
    public func replaying(from page: Int) -> SearchPageCursor {
        var cursor = SearchPageCursor(keyword: keyword)
        cursor.nextPage = max(1, page)
        return cursor
    }

    public mutating func fail(_ message: String, uncertain: Bool = false) {
        error = message
        self.uncertain = uncertain
    }

    /// Commit only validated progress. A repeated/contradictory page remains
    /// retryable at the same cursor; an explicit final page may contain repeats.
    @discardableResult
    public mutating func accept(_ page: VideoPage, requestedPage: Int) -> Bool {
        error = nil
        uncertain = false
        let end = page.pagination.continuation == .end ||
            (page.pagination.continuation == nil &&
             page.pagination.pageCount.map { requestedPage >= $0 } == true)
        let declaredMore = page.pagination.continuation == .more ||
            page.pagination.pageCount.map { requestedPage < $0 } == true
        var hasher = Hasher()
        for value in page.items.map({ $0.id.hashValue }).sorted() { hasher.combine(value) }
        let signature = hasher.finalize()
        let hasNewIDs = !recentPageSignatures.contains(signature) && page.items.contains { !seenIDs.contains($0.id) }
        guard page.pagination.page == requestedPage,
              !(end && declaredMore),
              hasNewIDs || end || (page.items.isEmpty && !declaredMore) else {
            uncertain = true
            return false
        }
        if seenIDs.count + min(page.items.count, Self.maximumRememberedIDs) > Self.maximumRememberedIDs {
            seenIDs.removeAll(keepingCapacity: true)
        }
        for item in page.items where seenIDs.count < Self.maximumRememberedIDs { seenIDs.insert(item.id) }
        recentPageSignatures.append(signature)
        if recentPageSignatures.count > 8 { recentPageSignatures.removeFirst() }
        nextPage = requestedPage + 1
        ended = end || (page.items.isEmpty && !declaredMore)
        return true
    }
}

public struct SearchPageProgress: Sendable {
    public let siteKey: String
    public let keyword: String
    public let requestedPage: Int
    public let page: VideoPage
}

public enum SearchPageAttempt: Sendable {
    case success(VideoPage, keyword: String)
    case failure(String, uncertain: Bool)
    case cancelled
}
