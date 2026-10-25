import AppKit
import CoreVideo
import CoreText
import Foundation
import OKVideoCore
import OKVideoPersistence
import SwiftUI

enum DanmakuDisplayArea: String, CaseIterable, Identifiable {
    case upperQuarter
    case upperHalf
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upperQuarter: return "顶部 1/4"
        case .upperHalf: return "上半屏"
        case .full: return "全屏"
        }
    }

    var fraction: CGFloat {
        switch self {
        case .upperQuarter: return 0.25
        case .upperHalf: return 0.5
        case .full: return 0.92
        }
    }
}

enum DanmakuDensity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    var laneSpacing: CGFloat {
        switch self {
        case .low: return 13
        case .medium: return 8
        case .high: return 4
        }
    }

    var maximumActiveComments: Int {
        switch self {
        case .low: return 35
        case .medium: return 70
        case .high: return 120
        }
    }
}

@MainActor
final class DanmakuSessionCoordinator: ObservableObject {
    @Published private(set) var loadState: DanmakuLoadState = .disabled
    @Published private(set) var searchState: DanmakuSearchState = .idle
    @Published private(set) var timeline = DanmakuTimeline(comments: [])
    @Published private(set) var timelineRevision: UInt64 = 0
    @Published private(set) var candidates: [DanmakuSourceDescriptor] = []
    @Published private(set) var selectedSource: DanmakuSourceDescriptor?
    @Published private(set) var selectionDescription = ""
    @Published private(set) var recoveryDescription: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                resolveTask?.cancel(); searchTask?.cancel(); loadTask?.cancel()
                epoch = UUID(); searchState = .idle; replaceTimeline(.init(comments: [])); loadState = .disabled
            } else { resumeCurrentSessionIfNeeded() }
        }
    }
    @Published var autoMatchEnabled: Bool {
        didSet { defaults.set(autoMatchEnabled, forKey: Keys.autoMatch); resumeCurrentSessionIfNeeded() }
    }
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: Keys.fontScale) } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: Keys.opacity) } }
    @Published var displayArea: DanmakuDisplayArea { didSet { defaults.set(displayArea.rawValue, forKey: Keys.displayArea) } }
    @Published var density: DanmakuDensity { didSet { defaults.set(density.rawValue, forKey: Keys.density) } }
    @Published var offset: TimeInterval = 0
    @Published var externalServiceURL: String { didSet { defaults.set(externalServiceURL, forKey: Keys.externalServiceURL) } }
    private enum Keys {
        static let enabled = "player.danmaku.enabled"
        static let autoMatch = "player.danmaku.autoMatch"
        static let fontScale = "player.danmaku.fontScale"
        static let opacity = "player.danmaku.opacity"
        static let displayArea = "player.danmaku.displayArea"
        static let density = "player.danmaku.density"
        static let externalServiceURL = "player.danmaku.externalServiceURL"
    }
    private let defaults: UserDefaults
    private let client: DanmakuServiceClient
    private var context: DanmakuPlaybackContext?
    private var playbackSessionID: UUID?
    private var database: SQLiteStore?
    private var selection: DanmakuSessionSelection?
    private var resolveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var epoch = UUID()
    private var searchRevision = UUID()
    private var legacyLocator: StableDanmakuLocator?
    private var preferredWork: String?
    private var pushObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, client: DanmakuServiceClient? = nil) {
        self.defaults = defaults
        self.client = client ?? .cached(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OKVideoMac/Danmaku-v2", isDirectory: true))
        isEnabled = defaults.object(forKey: Keys.enabled) == nil || defaults.bool(forKey: Keys.enabled)
        autoMatchEnabled = defaults.object(forKey: Keys.autoMatch) == nil || defaults.bool(forKey: Keys.autoMatch)
        fontScale = defaults.object(forKey: Keys.fontScale) == nil ? 1 : min(max(defaults.double(forKey: Keys.fontScale), 0.6), 2)
        opacity = defaults.object(forKey: Keys.opacity) == nil ? 0.86 : min(max(defaults.double(forKey: Keys.opacity), 0.2), 1)
        displayArea = DanmakuDisplayArea(rawValue: defaults.string(forKey: Keys.displayArea) ?? "") ?? .upperHalf
        density = DanmakuDensity(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .medium
        externalServiceURL = defaults.string(forKey: Keys.externalServiceURL) ?? ""
        pushObserver = NotificationCenter.default.addObserver(forName: DanmakuPushEvent.notification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.object as? DanmakuPushEvent else { return }
            MainActor.assumeIsolated { self?.acceptPush(event) }
        }
    }
    deinit { if let pushObserver { NotificationCenter.default.removeObserver(pushObserver) } }

    func begin(context: DanmakuPlaybackContext?, playbackSessionID: UUID, database: SQLiteStore) {
        endSession()
        self.context = context; self.playbackSessionID = playbackSessionID; self.database = database
        guard isEnabled, let context else { loadState = isEnabled ? .unavailable : .disabled; return }
        selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
        loadState = .resolvingSource
        let token = epoch
        resolveTask = Task { [weak self] in
            let bindings = (try? await database.danmakuBindings(configurationID: context.contentIdentity.configurationID)) ?? []
            guard let self, self.owns(token) else { return }
            let binding = bindings.first { $0.editionIdentity == context.editionIdentity }
            self.preferredWork = bindings.filter {
                $0.verificationVersion == 2 && $0.authority == .userSelection &&
                $0.editionIdentity.episode.content == context.contentIdentity &&
                $0.editionIdentity.editionID == context.editionIdentity.editionID &&
                $0.editionIdentity.episode.seasonNumber == context.editionIdentity.episode.seasonNumber
            }.max { $0.updatedAt < $1.updatedAt }?.match?.workID
            if let binding, binding.verificationVersion == 2 || binding.locator.kind == .localBookmark {
                self.offset = binding.offset
                if binding.authority == .userSelection || binding.locator.kind == .localBookmark {
                    if let source = self.directSource(binding.locator, context: context) {
                        self.choose(source, authority: .savedBinding); return
                    }
                    if let source = await self.restore(binding, context: context), self.owns(token) {
                        self.choose(source, authority: .savedBinding); return
                    }
                    guard self.owns(token) else { return }
                    self.loadState = .staleBinding(binding.locator); return
                }
            } else if let binding {
                self.legacyLocator = binding.locator
                self.recoveryDescription = "原来源未成功验证，正在重新匹配本集"
            }
            guard self.owns(token) else { return }
            if let requestID = context.upstreamRequestID, let event = DanmakuPushEvent.pending[requestID] {
                self.acceptPush(event)
                if self.selectedSource != nil { return }
            }
            if let source = DanmakuProvidedSourcePolicy.automaticSource(from: context.providedSources) {
                self.choose(source, authority: .providedSource)
            } else if !context.providedSources.isEmpty {
                self.candidates = context.providedSources; self.loadState = .awaitingSelection(context.providedSources)
            } else {
                await self.matchAutomatically(token: token)
            }
        }
    }
    func endSession() {
        resolveTask?.cancel(); loadTask?.cancel(); searchTask?.cancel()
        resolveTask = nil; loadTask = nil; searchTask = nil
        epoch = UUID(); searchRevision = UUID()
        context = nil; playbackSessionID = nil; database = nil; selection = nil
        selectedSource = nil; candidates = []; preferredWork = nil; legacyLocator = nil
        selectionDescription = ""; recoveryDescription = nil
        replaceTimeline(.init(comments: [])); searchState = .idle
        loadState = isEnabled ? .unavailable : .disabled; offset = 0
    }
    private func owns(_ token: UUID) -> Bool { isEnabled && epoch == token && !Task.isCancelled }
    private func resumeCurrentSessionIfNeeded() {
        guard let context, let playbackSessionID, let database else { return }
        begin(context: context, playbackSessionID: playbackSessionID, database: database)
    }
    func select(_ source: DanmakuSourceDescriptor) {
        resolveTask?.cancel(); searchTask?.cancel(); searchRevision = UUID()
        offset = 0
        searchState = candidates.isEmpty ? .idle : .results(candidates)
        choose(source, authority: .userSelection)
    }
    func retry() {
        guard isEnabled else { return }
        if let selectedSource { choose(selectedSource, authority: selection?.authority ?? .userSelection) }
        else { resumeCurrentSessionIfNeeded() }
    }
    func rematch() {
        guard let context, let playbackSessionID, isEnabled else { return }
        resolveTask?.cancel(); loadTask?.cancel(); searchTask?.cancel()
        epoch = UUID(); let token = epoch
        selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
        selectedSource = nil; offset = 0; replaceTimeline(.init(comments: []))
        resolveTask = Task { [weak self] in await self?.matchAutomatically(token: token, explicitlyRequested: true) }
    }
    func importXML(from url: URL) {
        guard let context, url.isFileURL else { return }
        select(.init(stable: .init(kind: .localBookmark, provider: "local", resourceID: url.path, displayName: url.lastPathComponent),
                     runtime: .init(url: url, runtimeGeneration: context.runtimeGeneration)))
    }
    func updateOffset(_ value: TimeInterval) {
        offset = min(max(value.isFinite ? value : 0, -120), 120)
        persistCurrentBinding(authority: .userSelection)
    }
    private func matchAutomatically(token: UUID, explicitlyRequested: Bool = false) async {
        guard owns(token) else { return }
        guard let context, let request = context.matchRequest,
              autoMatchEnabled || explicitlyRequested else { loadState = .unavailable; return }
        let endpoints = await searchEndpoints(context)
        guard owns(token) else { return }
        guard !endpoints.isEmpty, !request.searchTitle.isEmpty else { loadState = .unavailable; return }
        searchState = .searching; loadState = .resolvingSource
        do {
            let result = try await client.search(keyword: request.searchTitle, endpoints: endpoints, generation: context.runtimeGeneration)
            guard owns(token), selection?.authority == DanmakuSelectionAuthority.none else { return }
            guard result.successfulServices > 0 else {
                searchState = .failed(message: "弹幕服务暂不可用，可重试")
                loadState = .failed(nil, message: "弹幕服务暂不可用，可重试"); return
            }
            let matched = DanmakuMatcher.candidates(result.sources, for: request, preferredWork: preferredWork)
            candidates = Array((matched.isEmpty ? result.sources : matched).prefix(24))
            searchState = candidates.isEmpty ? .empty : .results(candidates)
            if let source = DanmakuMatcher.automaticSource(result.sources, for: request, preferredWork: preferredWork) {
                choose(source, authority: .automaticMatch)
            } else {
                loadState = candidates.isEmpty ? .unavailable : .awaitingSelection(candidates)
            }
        } catch {
            guard owns(token) else { return }
            loadState = .failed(nil, message: "弹幕服务暂不可用，可重试")
        }
    }
    func search(_ rawKeyword: String) {
        guard isEnabled, let context else { return }
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        searchTask?.cancel(); searchRevision = UUID()
        let revision = searchRevision, token = epoch
        searchState = .searching
        searchTask = Task { [weak self, client] in
            do {
                guard let self else { return }
                let endpoints = await self.searchEndpoints(context)
                let result = try await client.search(keyword: keyword, endpoints: endpoints, generation: context.runtimeGeneration)
                guard self.owns(token), self.searchRevision == revision else { return }
                self.candidates = result.sources
                self.searchState = result.successfulServices == 0 ? .failed(message: "弹幕服务暂不可用") :
                    (result.sources.isEmpty ? .empty : .results(result.sources))
                if self.selectedSource == nil { self.loadState = .awaitingSelection(result.sources) }
            } catch { }
        }
    }
    private func choose(_ source: DanmakuSourceDescriptor, authority: DanmakuSelectionAuthority) {
        guard isEnabled, let context, let playbackSessionID, var selection else { return }
        guard selection.select(source, authority: authority, playbackSessionID: playbackSessionID,
            runtimeGeneration: context.runtimeGeneration, basedOnRevision: selection.selectionRevision) else { return }
        self.selection = selection; selectedSource = source
        selectionDescription = authority >= .savedBinding ? "手动选择" : (authority == .providedSource ? "源提供" : "自动匹配")
        loadTask?.cancel(); replaceTimeline(.init(comments: [])); loadState = .loading(source)
        let revision = selection.selectionRevision, token = epoch
        loadTask = Task { [weak self, client] in
            do {
                let parsed = try await client.load(source)
                guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
                if parsed.comments.isEmpty, authority == .providedSource, self.autoMatchEnabled {
                    self.selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
                    await self.matchAutomatically(token: token)
                    return
                }
                self.replaceTimeline(parsed)
                self.loadState = parsed.comments.isEmpty ? .empty(source) : .ready(source, parsed)
                if !parsed.comments.isEmpty {
                    self.persistCurrentBinding(authority: authority == .savedBinding ? .userSelection : authority)
                    if self.legacyLocator != nil { self.recoveryDescription = "原来源未成功验证，已重新匹配本集" }
                }
            } catch {
                guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
                self.loadState = .failed(source, message: "弹幕加载失败：\(error.localizedDescription)")
                if authority == .providedSource, self.autoMatchEnabled {
                    self.selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
                    await self.matchAutomatically(token: token)
                }
            }
        }
    }
    private func persistCurrentBinding(authority: DanmakuSelectionAuthority) {
        guard case .ready = loadState, let context, let source = selectedSource, let database else { return }
        var binding = DanmakuBinding(editionIdentity: context.editionIdentity, locator: source.stable, offset: offset)
        binding.verificationVersion = 2; binding.authority = authority; binding.match = source.match
        binding.previousLocator = legacyLocator
        let token = epoch, revision = selection?.selectionRevision
        Task { [weak self] in
            guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
            try? await database.saveDanmakuBinding(binding)
        }
    }
    private func directSource(_ locator: StableDanmakuLocator, context: DanmakuPlaybackContext) -> DanmakuSourceDescriptor? {
        if let source = context.providedSources.first(where: { $0.stable == locator }) { return source }
        if locator.kind == .localBookmark, FileManager.default.fileExists(atPath: locator.resourceID) {
            return .init(stable: locator, runtime: .init(url: URL(fileURLWithPath: locator.resourceID), runtimeGeneration: context.runtimeGeneration))
        }
        return nil
    }
    private func restore(_ binding: DanmakuBinding, context: DanmakuPlaybackContext) async -> DanmakuSourceDescriptor? {
        guard let request = context.matchRequest else { return nil }
        let result = try? await client.search(keyword: request.searchTitle, endpoints: await searchEndpoints(context), generation: context.runtimeGeneration)
        return result?.sources.first { source in
            guard source.stable.provider == binding.locator.provider else { return false }
            if binding.locator.kind == .providerURLIdentity { return source.stable == binding.locator }
            if let video = binding.match?.videoID { return source.match?.videoID == video }
            guard let previous = binding.match, let current = source.match else { return false }
            return previous.workID == current.workID && previous.episode == current.episode && previous.season == current.season
        }
    }
    private func searchEndpoints(_ context: DanmakuPlaybackContext) async -> [DanmakuServiceEndpoint] {
        var values: [DanmakuServiceEndpoint] = []
        for capability in context.searchCapabilities {
            switch capability {
            case .catPawAPI(let url, let headers):
                if let e = DanmakuServiceEndpoint(url: url, headers: headers, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)") { values.append(e) }
            case .configuredEndpoint(let raw):
                for url in Self.urls(raw) {
                    if let endpoint = DanmakuServiceEndpoint(url: url) { values.append(endpoint) }
                    else { values += await client.discover(page: url, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)") }
                }
            case .providerWebPage(let url, let headers):
                values += await client.discover(page: url, headers: headers, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)")
            }
        }
        values += Self.urls(externalServiceURL).compactMap { DanmakuServiceEndpoint(url: $0) }
        var seen = Set<String>()
        return values.filter { seen.insert($0.identity).inserted }
    }
    private static func urls(_ raw: String) -> [URL] {
        if let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme ?? "") { return [url] }
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func collect(_ value: Any, depth: Int) -> [URL] {
            guard depth < 6 else { return [] }
            if let string = value as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { return [url] }
            if let list = value as? [Any] { return list.flatMap { collect($0, depth: depth + 1) } }
            if let object = value as? [String: Any] { return ["url", "api", "endpoint", "search", "urls"].flatMap { object[$0].map { collect($0, depth: depth + 1) } ?? [] } }
            return []
        }
        return collect(json, depth: 0)
    }
    private func acceptPush(_ event: DanmakuPushEvent) {
        guard isEnabled, let context, event.requestID == context.upstreamRequestID,
              event.siteKey == context.contentIdentity.siteKey,
              (selection?.authority ?? .none) <= .providedSource else { return }
        DanmakuPushEvent.pending[event.requestID] = nil
        let sources = DanmakuSourceNormalizer.sources(from: event.payload, provider: "catpaw:\(event.siteKey)",
            baseURL: event.baseURL, runtimeGeneration: context.runtimeGeneration)
        if let source = DanmakuProvidedSourcePolicy.automaticSource(from: sources) { choose(source, authority: .providedSource) }
    }
    private func replaceTimeline(_ value: DanmakuTimeline) { timeline = value; timelineRevision &+= 1 }
    var suggestedSearchQuery: String { context?.matchRequest?.searchTitle ?? context?.contentIdentity.title ?? "" }
    var statusText: String {
        switch loadState {
        case .disabled: return "弹幕已关闭"
        case .resolvingSource: return "正在自动匹配本集弹幕…"
        case .awaitingSelection: return "请确认作品、集数或版本"
        case .loading(let source): return "正在加载 \(source.stable.displayName)…"
        case .ready(let source, let timeline): return "\(selectionDescription)：\(source.stable.displayName) · \(timeline.comments.count) 条"
        case .empty: return "这个来源暂无本集弹幕"
        case .staleBinding: return "已选来源需重新匹配，请重试或选择重新匹配"
        case .failed(_, let message): return message
        case .unavailable: return "暂无可自动匹配的本集弹幕"
        }
    }
    var searchStatusText: String? {
        switch searchState {
        case .empty: return "没有找到匹配的弹幕"
        case .failed(let message): return "搜索失败：\(message)"
        default: return nil
        }
    }
}

struct DanmakuPushEvent: Sendable {
    @MainActor static var pending: [UUID: DanmakuPushEvent] = [:]
    @MainActor static func publish(_ event: DanmakuPushEvent) {
        if pending.count > 16 { pending.removeAll() }
        pending[event.requestID] = event
        NotificationCenter.default.post(name: notification, object: event)
    }
    static let notification = Notification.Name("OKVideoMac.DanmakuPush")
    let requestID: UUID
    let siteKey: String
    let baseURL: URL
    let payload: JSONValue
}

struct DanmakuOverlayRepresentable: NSViewRepresentable {
    let timeline: DanmakuTimeline
    let timelineRevision: UInt64
    let snapshot: PlayerSnapshot
    let offset: TimeInterval
    let fontScale: Double
    let opacity: Double
    let displayArea: DanmakuDisplayArea
    let density: DanmakuDensity

    func makeNSView(context: Context) -> DanmakuOverlayNSView {
        DanmakuOverlayNSView()
    }

    func updateNSView(_ view: DanmakuOverlayNSView, context: Context) {
        view.update(
            timeline: timeline,
            timelineRevision: timelineRevision,
            snapshot: snapshot,
            offset: offset,
            fontScale: fontScale,
            opacity: opacity,
            displayArea: displayArea,
            density: density
        )
    }
}

/// CVDisplayLink supports the app's macOS 12 minimum. The realtime callback
/// never touches AppKit and can enqueue at most one outstanding main-thread frame.
final class DanmakuDisplayDriver {
    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var running = false
    private var revision: UInt64 = 0
    private var pending: UInt64?
    private var targetTime: TimeInterval = 0
    private let frame: (TimeInterval) -> Void
    init(frame: @escaping (TimeInterval) -> Void) { self.frame = frame }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func start(displayID: CGDirectDisplayID) {
        guard !isRunning else { return }
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &created) == kCVReturnSuccess,
              let created else { return }
        guard CVDisplayLinkSetOutputHandler(created, { [weak self] _, _, output, _, _ in
            guard output.pointee.flags & CVTimeStampFlags.hostTimeValid.rawValue != 0 else { return kCVReturnSuccess }
            self?.enqueue(targetTime: Double(output.pointee.hostTime) / CVGetHostClockFrequency())
            return kCVReturnSuccess
        }) == kCVReturnSuccess else { return }
        link = created
        lock.lock(); revision &+= 1; running = true; lock.unlock()
        if CVDisplayLinkStart(created) != kCVReturnSuccess { stop() }
    }
    private func enqueue(targetTime: TimeInterval) {
        lock.lock()
        guard running else { lock.unlock(); return }
        // Coalesce to the newest display deadline while the main thread is busy.
        self.targetTime = targetTime
        guard pending == nil else { lock.unlock(); return }
        let ticket = revision
        pending = ticket
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let deliver = self.running && self.revision == ticket && self.pending == ticket
            let targetTime = self.targetTime
            if self.pending == ticket { self.pending = nil }
            self.lock.unlock()
            // An expired deadline cannot produce a frame for that refresh.
            if deliver, targetTime > ProcessInfo.processInfo.systemUptime { self.frame(targetTime) }
        }
    }
    func stop() {
        lock.lock(); running = false; revision &+= 1; pending = nil; lock.unlock()
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }
    deinit { stop() }
}

/// Immutable Core Text rasters are prepared on a bounded serial worker. The
/// display callback never measures text, allocates bitmaps, or draws glyphs.
@MainActor
final class DanmakuRasterCache {
    struct Key: Hashable, Sendable {
        let text: String
        let size: Double
        let color: UInt32
        let scale: Double
    }
    struct Raster: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
        let bytes: Int
    }
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.okvideomac.danmaku.rasters", qos: .userInitiated)
        private let lock = NSLock()
        private var revision: UInt64 = 0
        func setRevision(_ value: UInt64) { lock.lock(); revision = value; lock.unlock() }
        func accepts(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return revision == value }
    }
    nonisolated static let maximumBytes = 16 * 1_024 * 1_024
    private let worker = Worker()
    private var revision: UInt64 = 0
    private var entries: [Key: Raster] = [:]
    private var order: [Key] = []
    private var pending: Set<Key> = []
    private var rejected: Set<Key> = []
    private var budgetBlocked: Set<Key> = []
    private(set) var bytes = 0
    private(set) var rasterizationCount = 0
    var onReady: (() -> Void)?

    func reset() {
        revision &+= 1; worker.setRevision(revision)
        entries.removeAll(); order.removeAll(); pending.removeAll(); rejected.removeAll(); budgetBlocked.removeAll(); bytes = 0
    }
    func raster(for key: Key) -> Raster? { entries[key] }
    func prepare(_ keys: [Key]) {
        let wanted = Set(keys)
        rejected.formIntersection(wanted)
        budgetBlocked.formIntersection(wanted)
        var reclaimed = false
        for key in order where !wanted.contains(key) {
            if let removed = entries.removeValue(forKey: key) { bytes -= removed.bytes; reclaimed = true }
        }
        order.removeAll { !wanted.contains($0) }
        if reclaimed { budgetBlocked.removeAll() }
        guard pending.isEmpty else { return }
        var unique = Set<Key>()
        var work: [Key] = []
        for key in keys {
            if entries[key] == nil && !rejected.contains(key) && !budgetBlocked.contains(key)
                && unique.insert(key).inserted {
                work.append(key)
                if work.count == 4 { break }
            }
        }
        guard !work.isEmpty else { return }
        pending = Set(work)
        let ticket = revision, worker = worker
        worker.queue.async { [weak self] in
            var results: [(Key, Raster?)] = []
            for key in work {
                guard worker.accepts(ticket) else { return }
                let raster = autoreleasepool { Self.draw(key) }
                results.append((key, raster))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == ticket else { return }
                self.pending.removeAll()
                for (key, raster) in results {
                    guard let raster else { self.rejected.insert(key); continue }
                    guard self.bytes + raster.bytes <= Self.maximumBytes else {
                        self.budgetBlocked.insert(key); continue
                    }
                    self.entries[key] = raster; self.order.append(key)
                    self.bytes += raster.bytes; self.rasterizationCount += 1
                }
                self.onReady?()
            }
        }
    }
    nonisolated static func draw(_ key: Key, shadow: Bool = true, padding: CGFloat = 4) -> Raster? {
        guard key.size.isFinite, key.scale.isFinite, key.scale > 0 else { return nil }
        guard let base = CTFontCreateUIFontForLanguage(.system, CGFloat(key.size), nil) else { return nil }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.3]
        ] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, CGFloat(key.size), nil, descriptor)
        let color = CGColor(red: CGFloat((key.color >> 16) & 255) / 255,
                            green: CGFloat((key.color >> 8) & 255) / 255,
                            blue: CGFloat(key.color & 255) / 255, alpha: 1)
        let string = NSAttributedString(string: key.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let size = CGSize(width: ceil(width) + padding * 2, height: ceil(ascent + descent + leading) + padding * 2)
        let pixelWidth = Int(ceil(size.width * key.scale)), pixelHeight = Int(ceil(size.height * key.scale))
        guard pixelWidth > 0, pixelWidth <= 16_384, pixelHeight > 0, pixelHeight <= 512 else { return nil }
        let bytes = pixelWidth * pixelHeight * 4
        guard bytes <= maximumBytes / 8,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: key.scale, y: key.scale)
        if shadow { context.setShadow(offset: .zero, blur: 2 * key.scale, color: CGColor(gray: 0, alpha: 0.9)) }
        context.textPosition = CGPoint(x: padding, y: padding + descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, size: size, bytes: bytes)
    }
}

final class DanmakuOverlayNSView: NSView {
    private struct ActiveComment {
        let lane: Int
        let startTime: TimeInterval
        let width: CGFloat
        let laneHeight: CGFloat
        let lifetime: TimeInterval
        let mode: DanmakuMode
        let layer: CALayer
        var bytes: Int
        var rasterKey: DanmakuRasterCache.Key
        let originX: CGFloat
        let velocity: CGFloat
    }
    private var timeline = DanmakuTimeline(comments: [])
    private var timelineRevision: UInt64?
    private var clock = DanmakuClock()
    private var generation: UInt64 = 1
    private var lastPresentedMediaTime: TimeInterval?
    private var active: [ActiveComment] = []
    private var lastFrameMediaTime: TimeInterval?
    private var waitingComments: [DanmakuComment] = []
    private let rasters = DanmakuRasterCache()
    private var scrollingScheduler = DanmakuLaneScheduler(laneCount: 0)
    private var displayDriver: DanmakuDisplayDriver?
    private var offset: TimeInterval = 0
    private var fontScale: Double = 1
    private var commentOpacity: Double = 0.86
    private var displayArea: DanmakuDisplayArea = .upperHalf
    private var density: DanmakuDensity = .medium
    private let spriteRoot = CALayer()
    var rasterizationCount: Int { rasters.rasterizationCount }
    var preparedRasterBytes: Int { rasters.bytes }
    private(set) var renderedFrameCount = 0
    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    var frameObserver: ((_ target: TimeInterval, _ delivered: TimeInterval, _ renderDuration: TimeInterval) -> Void)?
    #endif
    private(set) var rasterBytes = 0
    static let maximumRasterBytes = 48 * 1_024 * 1_024
    var activeCommentCount: Int { active.count }
    var isDisplayDriverRunning: Bool { displayDriver?.isRunning == true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        spriteRoot.masksToBounds = true
        // AppKit supplies the flipped view coordinates; do not flip sublayers again.
        layer?.addSublayer(spriteRoot)
        displayDriver = DanmakuDisplayDriver { [weak self] targetTime in
            self?.renderFrame(at: targetTime)
        }
        rasters.onReady = { [weak self] in
            guard let self, self.mayPrepareRasters else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Running playback has exactly one presentation driver. Paused or
            // detached views still need an initial image for capture/accessibility.
            if !self.isDisplayDriverRunning { self.renderFrame(at: now) }
            else { self.prepareRasters(at: self.clock.currentTime(at: now)) }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { displayDriver?.stop(); NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayDriver?.stop()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDisplayChanged), name: name, object: window)
            }
        }
        refreshDriver()
    }
    @objc private func windowDisplayChanged() {
        displayDriver?.stop()
        refreshDriver()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A backing-scale change changes glyph resolution, not media time or
        // trajectories. Keep the old image until its replacement is ready.
        prepareRasters(at: clock.currentTime(at: ProcessInfo.processInfo.systemUptime))
        refreshDriver()
    }
    private func refreshDriver() {
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              clock.isAdvancing, !timeline.comments.isEmpty, bounds.width > 0 else {
            displayDriver?.stop(); return
        }
        let id = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        displayDriver?.start(displayID: id)
    }
    func update(timeline: DanmakuTimeline, timelineRevision: UInt64, snapshot: PlayerSnapshot,
                offset: TimeInterval, fontScale: Double, opacity: Double,
                displayArea: DanmakuDisplayArea, density: DanmakuDensity) {
        let now = ProcessInfo.processInfo.systemUptime
        var reset = self.timelineRevision != timelineRevision || self.offset != offset
            || self.fontScale != fontScale || self.displayArea != displayArea || self.density != density
        if self.timelineRevision != timelineRevision {
            self.timeline = timeline; self.timelineRevision = timelineRevision; generation &+= 1
        }
        self.offset = offset; self.fontScale = fontScale; self.displayArea = displayArea; self.density = density
        commentOpacity = opacity
        let discontinuity = clock.synchronize(mediaTime: snapshot.seekTarget ?? snapshot.position,
            sampleUptime: snapshot.isSeeking ? now : snapshot.positionSampleUptime, monotonicTime: now,
            rate: snapshot.speed, isPlaying: snapshot.status == .playing,
            isBuffering: snapshot.isPausedForCache || snapshot.status == .buffering,
            isSeeking: snapshot.isSeeking, generation: generation)
        reset = reset || discontinuity
        if reset { resetPresentation(at: clock.currentTime(at: now)) }
        refreshDriver()
        prepareRasters(at: clock.currentTime(at: now))
        if !isDisplayDriverRunning { renderFrame(at: now) }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteRoot.frame = bounds
        CATransaction.commit()
        scrollingScheduler.resize(laneCount: scrollingLaneCount)
        refreshDriver()
        if !isDisplayDriverRunning { renderFrame(at: ProcessInfo.processInfo.systemUptime) }
    }
    /// Main-thread frame entry shared by the display link and deterministic rendering tests.
    func renderFrame(at uptime: TimeInterval) {
        guard !timeline.comments.isEmpty, bounds.width > 0 else { return }
        #if DEBUG || OKVIDEO_PERFORMANCE_TEST
        let delivered = ProcessInfo.processInfo.systemUptime
        #endif
        // The previous frame may have targeted a refresh just after a pause
        // observation. Do not move visible glyphs backwards during that handoff.
        let mediaTime = max(lastFrameMediaTime ?? 0, clock.currentTime(at: uptime))
        lastFrameMediaTime = mediaTime
        renderedFrameCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            #if DEBUG || OKVIDEO_PERFORMANCE_TEST
            frameObserver?(uptime, delivered, ProcessInfo.processInfo.systemUptime - delivered)
            #endif
        }
        active.removeAll { item in
            guard mediaTime - item.startTime > item.lifetime else { return false }
            item.layer.removeFromSuperlayer(); rasterBytes -= item.bytes
            return true
        }
        presentComments(through: mediaTime)
        prepareRasters(at: mediaTime)
        for index in active.indices {
            let replacementKey = currentRasterKey(active[index].rasterKey)
            if replacementKey != active[index].rasterKey,
               let raster = rasters.raster(for: replacementKey),
               rasterBytes - active[index].bytes + raster.bytes <= Self.activeRasterBudget {
                rasterBytes += raster.bytes - active[index].bytes
                active[index].bytes = raster.bytes
                active[index].rasterKey = replacementKey
                active[index].layer.contents = raster.image
                active[index].layer.contentsScale = CGFloat(replacementKey.scale)
            }
            let item = active[index]
            let y = item.mode == .bottom
                ? max(0, bounds.height * displayArea.fraction - CGFloat(item.lane + 1) * item.laneHeight)
                : CGFloat(item.lane) * item.laneHeight
            let elapsed = CGFloat(max(0, mediaTime - item.startTime))
            let x = item.mode == .scrolling ? item.originX - elapsed * item.velocity
                : max(0, (bounds.width - item.width) / 2)
            item.layer.position = CGPoint(x: x, y: y)
            item.layer.opacity = Float(commentOpacity)
        }
    }
    private func presentComments(through mediaTime: TimeInterval) {
        let previous = lastPresentedMediaTime ?? max(0, mediaTime - 0.15)
        // A final pause observation can be a few milliseconds behind the last
        // interpolated frame. Keep its sprites; explicit seeks reset in update.
        guard mediaTime >= previous else { return }
        guard mediaTime - previous < 1.5 else {
            resetPresentation(at: mediaTime); return
        }
        let available = max(0, density.maximumActiveComments - active.count - waitingComments.count)
        waitingComments.append(contentsOf: timeline.comments(from: previous - offset + 0.000_001,
            through: mediaTime - offset).prefix(available))
        waitingComments.removeAll { comment in
            // Cold start/seek may need a short preparation window. Never queue
            // seconds of missed comments and release them in a burst later.
            guard mediaTime - comment.time - offset <= max(0.15, 0.35 * clock.rate) else { return true }
            guard let raster = rasters.raster(for: rasterKey(comment)) else { return false }
            add(comment, raster: raster, at: comment.time + offset)
            return true
        }
        lastPresentedMediaTime = mediaTime
    }
    private func rasterKey(_ comment: DanmakuComment) -> DanmakuRasterCache.Key {
        .init(text: comment.text, size: min(max(comment.fontSize * fontScale, 13), 58),
              color: comment.color, scale: Double(window?.backingScaleFactor ?? 2))
    }
    private func currentRasterKey(_ key: DanmakuRasterCache.Key) -> DanmakuRasterCache.Key {
        .init(text: key.text, size: key.size, color: key.color, scale: Double(window?.backingScaleFactor ?? 2))
    }
    private var scrollingLaneCount: Int {
        let height = CGFloat(28 * fontScale) + density.laneSpacing
        return max(1, Int(max(1, bounds.height * displayArea.fraction) / max(1, height)))
    }
    private static let activeRasterBudget = maximumRasterBytes - DanmakuRasterCache.maximumBytes - 8 * 1_024 * 1_024
    private var mayPrepareRasters: Bool {
        guard clock.isAdvancing, let window else { return true }
        return window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    private func prepareRasters(at mediaTime: TimeInterval) {
        guard mayPrepareRasters else { return }
        let upcoming = timeline.comments(from: mediaTime - offset - 0.15,
            through: mediaTime - offset + max(0.5, clock.rate))
        let replacements = active.compactMap { item -> DanmakuRasterCache.Key? in
            let key = currentRasterKey(item.rasterKey)
            return key == item.rasterKey ? nil : key
        }
        rasters.prepare(replacements + (waitingComments + upcoming.prefix(density.maximumActiveComments)).map(rasterKey))
    }
    private func add(_ comment: DanmakuComment, raster: DanmakuRasterCache.Raster, at time: TimeInterval) {
        let width = raster.size.width, height = raster.size.height, bytes = raster.bytes
        guard active.count < density.maximumActiveComments,
              bytes <= Self.activeRasterBudget - rasterBytes else { return }
        let laneHeight = CGFloat(rasterKey(comment).size) + density.laneSpacing
        let laneCount = max(1, Int(max(laneHeight, bounds.height * displayArea.fraction) / laneHeight))
        // Logical points per media second, calibrated to the comfortable small
        // window speed. A larger viewport extends travel time, never velocity.
        let velocity: CGFloat = 140
        let lifetime = comment.mode == .scrolling ? Double((bounds.width + width) / velocity) : 4
        let lane: Int
        if comment.mode == .scrolling {
            guard let reservation = scrollingScheduler.reserve(at: time, textWidth: Double(width),
                viewportWidth: Double(bounds.width), lifetime: lifetime) else { return }
            lane = reservation.lane
        } else {
            let occupied = Set(active.filter { $0.mode == comment.mode }.map(\.lane))
            guard let free = (0..<laneCount).first(where: { !occupied.contains($0) }) else { return }
            lane = free
        }
        let sprite = CALayer()
        sprite.anchorPoint = .zero; sprite.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        sprite.contents = raster.image; sprite.contentsScale = CGFloat(rasterKey(comment).scale)
        sprite.opacity = Float(commentOpacity)
        spriteRoot.addSublayer(sprite)
        rasterBytes += bytes
        active.append(ActiveComment(lane: lane, startTime: time, width: width, laneHeight: laneHeight,
            lifetime: lifetime, mode: comment.mode, layer: sprite, bytes: bytes,
            rasterKey: rasterKey(comment), originX: bounds.width, velocity: velocity))
    }
    private func resetPresentation(at mediaTime: TimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        active.forEach { $0.layer.removeFromSuperlayer() }
        CATransaction.commit()
        active.removeAll(keepingCapacity: true); rasterBytes = 0
        waitingComments.removeAll(); lastFrameMediaTime = nil; rasters.reset()
        scrollingScheduler.reset(laneCount: scrollingLaneCount)
        lastPresentedMediaTime = max(0, mediaTime - 0.15)
    }
}

struct PlayerDanmakuLayer: View {
    @ObservedObject var coordinator: DanmakuSessionCoordinator
    @ObservedObject var snapshotState: PlayerSnapshotState

    var body: some View {
        if coordinator.isEnabled, !coordinator.timeline.comments.isEmpty {
            DanmakuOverlayRepresentable(
                timeline: coordinator.timeline,
                timelineRevision: coordinator.timelineRevision,
                snapshot: snapshotState.snapshot,
                offset: coordinator.offset,
                fontScale: coordinator.fontScale,
                opacity: coordinator.opacity,
                displayArea: coordinator.displayArea,
                density: coordinator.density
            )
        }
    }
}

struct PlayerDanmakuPanel: View {
    @ObservedObject var coordinator: DanmakuSessionCoordinator
    let importXML: () -> Void
    @State private var keyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("弹幕")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("", isOn: $coordinator.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Toggle("自动匹配本集", isOn: $coordinator.autoMatchEnabled)
                .toggleStyle(.checkbox)
            Text(coordinator.statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.58))

            if let recovery = coordinator.recoveryDescription {
                Text(recovery).font(.caption).foregroundColor(.white.opacity(0.58))
            }
            HStack {
                Button("重试") { coordinator.retry() }
                Button("重新匹配") { coordinator.rematch() }
            }.buttonStyle(.bordered).controlSize(.small)
            if !coordinator.candidates.isEmpty {
                VStack(spacing: 5) {
                    ForEach(coordinator.candidates) { source in
                        Button {
                            coordinator.select(source)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: coordinator.selectedSource?.id == source.id
                                      ? "checkmark.circle.fill" : "circle")
                                Text(source.stable.displayName)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.84))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(
                                coordinator.selectedSource?.id == source.id
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.white.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 7) {
                TextField("片名 / 集数", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { coordinator.search(keyword) }
                Button("搜索") { coordinator.search(keyword) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("弹幕服务地址（可选）", text: $coordinator.externalServiceURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Button("导入 XML…", action: importXML)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                if case .searching = coordinator.searchState {
                    ProgressView().controlSize(.small)
                }
            }

            if let searchStatusText = coordinator.searchStatusText {
                Text(searchStatusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.58))
            }

            Divider().overlay(Color.white.opacity(0.08))

            settingSlider(
                title: "字号",
                value: $coordinator.fontScale,
                range: 0.7...1.6,
                valueText: "\(Int(coordinator.fontScale * 100))%"
            )
            settingSlider(
                title: "透明度",
                value: $coordinator.opacity,
                range: 0.25...1,
                valueText: "\(Int(coordinator.opacity * 100))%"
            )

            HStack {
                Text("显示区域")
                Spacer()
                Picker("", selection: $coordinator.displayArea) {
                    ForEach(DanmakuDisplayArea.allCases) { area in
                        Text(area.title).tag(area)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HStack {
                Text("密度")
                Spacer()
                Picker("", selection: $coordinator.density) {
                    ForEach(DanmakuDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HStack(spacing: 7) {
                Text("时间校准")
                Spacer()
                Button("−0.5s") { coordinator.updateOffset(coordinator.offset - 0.5) }
                Text(coordinator.offset == 0 ? "同步" : String(format: coordinator.offset > 0 ? "延后%.1fs" : "提前%.1fs", abs(coordinator.offset)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 80)
                Button("+0.5s") { coordinator.updateOffset(coordinator.offset + 0.5) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 13))
        }
        .foregroundColor(.white.opacity(0.9))
        .onAppear {
            if keyword.isEmpty { keyword = coordinator.suggestedSearchQuery }
        }
    }

    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.58))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 13))
    }
}
