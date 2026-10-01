import Foundation
import OKVideoCore

/// Publish the first result immediately and the trailing batch on a timer,
/// even when no further providers return. Cancel when the search owner leaves.
@MainActor final class SearchSnapshotPublisher<Value> {
    private let interval: TimeInterval
    private let publish: (Value) -> Void
    private var lastPublication: TimeInterval?
    private var pending: Value?
    private var timer: Task<Void, Never>?
    init(interval: TimeInterval = 0.12, publish: @escaping (Value) -> Void) {
        self.interval = interval; self.publish = publish
    }
    func submit(_ value: Value) {
        pending = value
        let remaining = interval - (ProcessInfo.processInfo.systemUptime - (lastPublication ?? -.infinity))
        if remaining <= 0 { flush(); return }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        timer?.cancel(); timer = nil
        guard let value = pending else { return }
        pending = nil
        lastPublication = ProcessInfo.processInfo.systemUptime
        publish(value)
    }
    func cancel() { timer?.cancel(); timer = nil; pending = nil }
    deinit { timer?.cancel() }
}

/// Bounded, memory-only CatPaw search data. Profile/account edits advance the
/// generation so an old request cannot repopulate the new account's cache.
final class CatPawSearchMemory: @unchecked Sendable {
    struct Key: Hashable {
        let owner: String
        let keyword: String
        let page: Int
        let quick: Bool
    }
    private struct Entry { let page: VideoPage; let expires: TimeInterval; var accessed: TimeInterval }
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let lifetime: TimeInterval
    private var generation = UUID()
    private var entries: [Key: Entry] = [:]
    private var costs: [String: (seconds: TimeInterval, recorded: TimeInterval)] = [:]
    init(lifetime: TimeInterval = 30, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = lifetime; self.now = now
    }
    func lookup(_ key: Key) -> (UUID, VideoPage?) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key], entry.expires > now() else {
            entries[key] = nil; return (generation, nil)
        }
        entry.accessed = now(); entries[key] = entry
        return (generation, entry.page)
    }
    func insert(_ page: VideoPage, for key: Key, generation expected: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard expected == generation, !page.items.isEmpty, page.items.count <= 200 else { return }
        entries[key] = Entry(page: page, expires: now() + lifetime, accessed: now())
        while entries.count > 64 || entries.values.reduce(0, { $0 + $1.page.items.count }) > 5_000 {
            guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key else { break }
            entries[oldest] = nil
        }
    }
    func invalidate(clearPerformance: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); entries.removeAll()
        if clearPerformance { costs.removeAll() }
    }
    func record(owner: String, elapsed: TimeInterval, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        let sample = succeeded ? max(0, elapsed) : max(20, elapsed)
        costs[owner] = ((costs[owner]?.seconds ?? sample) * 0.3 + sample * 0.7, now())
        if costs.count > 512, let oldest = costs.min(by: { $0.value.recorded < $1.value.recorded })?.key { costs[oldest] = nil }
    }
    func priority(owner: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let cost = costs[owner], now() - cost.recorded < 1_800 else { return 2 }
        return cost.seconds
    }
}

/// No scroll-position publication: recording an anchor must not invalidate the
/// SwiftUI graph during native scrolling. Keys belong to one search session.
@MainActor final class SearchBrowseMemory {
    var anchors: [String: PosterBrowseAnchor] = [:]
    private var presentations: [String: SearchStablePresentation] = [:]
    func presentation(for key: String) -> SearchStablePresentation {
        if let existing = presentations[key] { return existing }
        let result = SearchStablePresentation()
        presentations[key] = result
        return result
    }
    func acceptPendingOrders() { presentations.values.forEach { $0.acceptOrder() } }
    private var sourceOrder: [String] = []
    func orderedSources(_ sources: [SearchSiteOption]) -> [SearchSiteOption] {
        let byKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0) })
        for item in sources where !sourceOrder.contains(item.key) { sourceOrder.append(item.key) }
        return sourceOrder.compactMap { byKey[$0] }
    }
    func reset() { sourceOrder.removeAll(); anchors = anchors.filter { $0.key.hasPrefix("folder:") }; presentations.removeAll() }
}

struct SearchPagingState: Equatable {
    var cursors: [String: SearchPageCursor] = [:]
    var order: [String] = []
    var restricted: Set<String> = []
    var loading = false
    var stopped = false
    var manualContinuation = false
    var lastServed: String?
    var revision = 0

    func keys(selected: String?) -> [String] {
        if let selected { return order.contains(selected) ? [selected] : [] }
        return order
    }

    func eligible(selected: String?, retry: Bool) -> [String] {
        let keys = keys(selected: selected)
        let pivot = lastServed.flatMap { keys.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = Array(keys.dropFirst(pivot)) + Array(keys.prefix(pivot))
        return rotated.filter { key in
            guard let cursor = cursors[key], !cursor.ended,
                  !restricted.contains(key) || cursor.nextPage == 1 else { return false }
            return retry || (cursor.error == nil && !cursor.uncertain)
        }
    }
}

/// Keeps the reading order and representative poster stable while new providers
/// arrive. This object never publishes native scroll events into SwiftUI.
final class SearchStablePresentation {
    var atTop = true
    private(set) var hasPendingOrder = false
    private(set) var displayed: [SearchResultCluster] = []
    private var lastInput: [SearchResultCluster]?
    private var lastAtTop = true
    private var latest: [SearchResultCluster] = []

    func acceptOrder() { displayed = latest; hasPendingOrder = false }

    func update(_ incoming: [SearchResultCluster]) -> [SearchResultCluster] {
        if lastInput == incoming && lastAtTop == atTop { return displayed }
        lastInput = incoming
        lastAtTop = atTop
        let previous = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
        latest = incoming.map { cluster in
            var cluster = cluster
            if let primary = previous[cluster.id]?.primary,
               let index = cluster.sources.firstIndex(where: { $0.id == primary.id }) {
                cluster.sources.remove(at: index)
                cluster.sources.insert(primary, at: 0)
            }
            return cluster
        }
        if atTop || displayed.isEmpty { displayed = latest; hasPendingOrder = false }
        else {
            let byID = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
            let retained = displayed.compactMap { byID[$0.id] }
            let retainedIDs = Set(retained.map(\.id))
            displayed = retained + latest.filter { !retainedIDs.contains($0.id) }
            hasPendingOrder = displayed.map(\.id) != latest.map(\.id)
        }
        return displayed
    }
}

struct SearchPresentationInput: Equatable, Sendable {
    let key: String
    let items: [VideoSummary]
    let keyword: String
    let mergesDuplicates: Bool
    let sortOrder: SearchResultSortOrder
}

actor SearchPresentationWorker {
    func clusters(_ input: SearchPresentationInput) -> [SearchResultCluster] {
        SearchResultPresentation.clusters(from: input.items, keyword: input.keyword,
            mergesDuplicates: input.mergesDuplicates, sortOrder: input.sortOrder)
    }
}

/// A refreshing provider commits atomically on success, including a valid empty
/// result. A failed or unfinished provider keeps every previously loaded page.
enum SearchRefreshSnapshot {
    static func merge(retained: [VideoSummary], incoming: [VideoSummary], successfulKeys: Set<String>) -> [VideoSummary] {
        retained.filter { !successfulKeys.contains($0.siteKey) }
            + incoming.filter { successfulKeys.contains($0.siteKey) }
    }
}
