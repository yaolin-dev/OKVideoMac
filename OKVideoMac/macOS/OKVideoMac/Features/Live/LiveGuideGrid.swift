import AppKit
import OKVideoCore
import SwiftUI

struct LiveGuideDemandDebounce: Equatable {
    static let quietInterval: UInt64 = 100_000_000
    static let maximumWait: UInt64 = 250_000_000
    private(set) var startedAt: UInt64?

    mutating func register(at uptime: UInt64) {
        if startedAt == nil { startedAt = uptime }
    }

    func delay(at uptime: UInt64) -> UInt64 {
        guard let startedAt else { return Self.quietInterval }
        let elapsed = uptime >= startedAt ? uptime - startedAt : Self.maximumWait
        let remaining = elapsed < Self.maximumWait ? Self.maximumWait - elapsed : 0
        return min(Self.quietInterval, remaining)
    }

    mutating func reset() { startedAt = nil }
}

enum LiveGuideFreshness: Equatable {
    case fresh
    case stale
}

enum LiveGuideRefreshPhase: Equatable {
    case idle
    case loading
    case backoff
}

struct LiveGuideContentState: Equatable {
    let snapshot: EPGGuideSnapshot
    var freshness: LiveGuideFreshness
    var refreshPhase: LiveGuideRefreshPhase
    let failures: [String: EPGGuideFailure]
}

struct LiveGuideEmptyState: Equatable {
    let snapshot: EPGGuideSnapshot
    var freshness: LiveGuideFreshness
    var refreshPhase: LiveGuideRefreshPhase
}

enum LiveGuideLifecycleState: Equatable {
    case inactive
    case loadingInitial
    case content(LiveGuideContentState)
    case empty(LiveGuideEmptyState)
    case unsupported
    case failed(EPGGuideFailure)
}

struct LiveGuideDeliveryIdentity: Equatable {
    let source: EPGSourceKey
    let revision: String
    let demandRevision: UUID
    let serviceIncarnation: UUID
    let capability: EPGGuideCapability
}

/// Main-actor publication boundary. It owns only one bounded snapshot and
/// rejects every late result using one delivery identity comparison.
@MainActor
final class LiveGuideState: ObservableObject {
    @Published private(set) var lifecycle: LiveGuideLifecycleState = .inactive
    private var expectedIdentity: LiveGuideDeliveryIdentity?

    var snapshot: EPGGuideSnapshot? {
        switch lifecycle {
        case .content(let value): return value.snapshot
        case .empty(let value): return value.snapshot
        default: return nil
        }
    }

    var isRefreshing: Bool {
        switch lifecycle {
        case .loadingInitial: return true
        case .content(let value): return value.refreshPhase == .loading
        case .empty(let value): return value.refreshPhase == .loading
        default: return false
        }
    }

    var retainedSnapshotCost: Int { snapshot?.estimatedByteCost ?? 0 }

    func begin(_ identity: LiveGuideDeliveryIdentity, refreshing: Bool) {
        let retainable = snapshot?.source == identity.source
            && snapshot?.revision == identity.revision
            && snapshot.map { canRetain($0, for: identity) } == true
        expectedIdentity = identity
        guard retainable else {
            lifecycle = .loadingInitial
            return
        }
        setRefreshPhase(refreshing ? .loading : .idle)
    }

    func setUnsupported() {
        expectedIdentity = nil
        lifecycle = .unsupported
    }

    func deactivate() {
        expectedIdentity = nil
        lifecycle = .inactive
    }

    func suspend() {
        expectedIdentity = nil
        switch lifecycle {
        case .content(var value):
            value.freshness = .stale
            value.refreshPhase = .idle
            lifecycle = .content(value)
        case .empty(var value):
            value.freshness = .stale
            value.refreshPhase = .idle
            lifecycle = .empty(value)
        default:
            lifecycle = .inactive
        }
    }

    @discardableResult
    func publish(_ value: EPGGuideSnapshot,
                 identity: LiveGuideDeliveryIdentity) -> Bool {
        guard expectedIdentity == identity,
              value.source == identity.source,
              value.revision == identity.revision,
              value.demandRevision == identity.demandRevision,
              validatesCoherence(value, identity: identity) else { return false }

        let failures = Dictionary(uniqueKeysWithValues: value.rows.compactMap { row in
            if case .failed(let failure) = row.state { return (row.id, failure) }
            return nil
        })
        let usableRows = value.rows.filter { row in
            if case .failed = row.state { return false }
            if row.state == .unsupported { return false }
            return true
        }
        guard !usableRows.isEmpty else {
            lifecycle = value.rows.contains(where: { $0.state == .unsupported })
                ? .unsupported
                : .failed(failures.values.first ?? .unavailable)
            return true
        }
        let freshness: LiveGuideFreshness = value.rows.contains(where: {
            $0.availability == .stale || $0.availability == .failed
        }) ? .stale : .fresh
        if usableRows.allSatisfy({ $0.programmes.isEmpty }) {
            lifecycle = .empty(LiveGuideEmptyState(
                snapshot: value, freshness: freshness, refreshPhase: .idle
            ))
        } else {
            lifecycle = .content(LiveGuideContentState(
                snapshot: value, freshness: freshness,
                refreshPhase: .idle, failures: failures
            ))
        }
        return true
    }

    private func validatesCoherence(_ value: EPGGuideSnapshot,
                                    identity: LiveGuideDeliveryIdentity) -> Bool {
        switch (identity.capability, value.coherence) {
        case (.xmltv, .xmltv(let token)):
            return token.serviceIncarnation == identity.serviceIncarnation
                && token.demandRevision == identity.demandRevision
        case (.xtreamShort, .perRowToken), (.xtreamArchive, .perRowToken), (.tvboxDay, .perRowToken):
            return value.rows.allSatisfy { row in
                guard let token = row.token else { return row.programmes.isEmpty }
                return token.serviceIncarnation == identity.serviceIncarnation
                    && token.demandRevision == identity.demandRevision
            }
        default:
            return false
        }
    }

    private func canRetain(_ value: EPGGuideSnapshot,
                           for identity: LiveGuideDeliveryIdentity) -> Bool {
        switch (identity.capability, value.coherence) {
        case (.xmltv, .xmltv(let token)):
            return token.serviceIncarnation == identity.serviceIncarnation
        case (.xtreamShort, .perRowToken), (.xtreamArchive, .perRowToken), (.tvboxDay, .perRowToken):
            return value.rows.allSatisfy {
                $0.token?.serviceIncarnation == identity.serviceIncarnation
                    || ($0.token == nil && $0.programmes.isEmpty)
            }
        default:
            return false
        }
    }

    func fail(_ failure: EPGGuideFailure,
              identity: LiveGuideDeliveryIdentity) {
        guard expectedIdentity == identity else { return }
        switch lifecycle {
        case .content(var value):
            value.freshness = .stale
            value.refreshPhase = .backoff
            lifecycle = .content(value)
        case .empty(var value):
            value.freshness = .stale
            value.refreshPhase = .backoff
            lifecycle = .empty(value)
        default:
            lifecycle = failure == .cancelled ? .inactive : .failed(failure)
        }
    }

    private func setRefreshPhase(_ phase: LiveGuideRefreshPhase) {
        switch lifecycle {
        case .content(var value):
            value.refreshPhase = phase
            lifecycle = .content(value)
        case .empty(var value):
            value.refreshPhase = phase
            lifecycle = .empty(value)
        default:
            break
        }
    }
}

struct LiveGuideGridProgramme: Equatable, Identifiable, Sendable {
    let id: EPGProgrammeRecordIdentity
    let title: String
    let start: Date
    let end: Date
    let catchupAvailable: Bool?

    init(_ value: EPGWindowProgramme) {
        id = value.id
        title = value.title
        start = value.start
        end = value.end
        catchupAvailable = value.programme.catchupAvailable
    }
}

struct LiveGuideGridRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let state: EPGGuideRowState
    let programmes: [LiveGuideGridProgramme]

    init(id: String, title: String, subtitle: String? = nil,
         state: EPGGuideRowState = .ready, programmes: [LiveGuideGridProgramme]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.programmes = programmes
    }
}

struct LiveGuideGridModel: Equatable, Sendable {
    let windowStart: Date
    let windowEnd: Date
    let timeZone: TimeZone
    let rows: [LiveGuideGridRow]

    init(windowStart: Date, windowEnd: Date, timeZone: TimeZone,
         rows: [LiveGuideGridRow]) throws {
        let programmeCount = rows.reduce(0) { $0 + $1.programmes.count }
        guard windowStart < windowEnd,
              windowEnd.timeIntervalSince(windowStart) <= 24 * 60 * 60,
              !rows.isEmpty, rows.count <= EPGGuideLimits.maximumDesiredRows,
              Set(rows.map(\.id)).count == rows.count,
              programmeCount <= EPGGuideLimits.maximumProgrammes,
              rows.allSatisfy({ row in
                  row.programmes.count <= EPGGuideLimits.maximumProgrammesPerRow
                      && Set(row.programmes.map(\.id)).count == row.programmes.count
                      && row.programmes.allSatisfy { $0.start < $0.end }
              }) else {
            throw EPGGuideValidationError.invalidResult
        }
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.timeZone = timeZone
        self.rows = rows
    }

    init(snapshot: EPGGuideSnapshot, timeZone: TimeZone,
         subtitles: [String: String] = [:]) throws {
        try self.init(
            windowStart: snapshot.slices.first?.start ?? .distantPast,
            windowEnd: snapshot.slices.last?.end ?? .distantFuture,
            timeZone: timeZone,
            rows: snapshot.rows.map { row in
                LiveGuideGridRow(
                    id: row.id,
                    title: row.channel.name,
                    subtitle: subtitles[row.id] ?? row.channel.number,
                    state: row.state,
                    programmes: row.programmes.map(LiveGuideGridProgramme.init)
                )
            }
        )
    }
}

struct LiveGuideViewScope: Equatable {
    let source: EPGSourceKey
    let start: Date
    let end: Date
    let channelIDs: [String]

    func accepts(_ snapshot: EPGGuideSnapshot) -> Bool {
        snapshot.source == source && snapshot.slices.first?.start == start
            && snapshot.slices.last?.end == end
            && Set(snapshot.rows.map(\.id)) == Set(channelIDs)
    }
}

/// One conversion in flight and one replaceable pending input. Refreshes keep
/// the rendered model; a different scope immediately drops its old content.
@MainActor
final class LiveGuideModelPresenter: ObservableObject {
    @Published private(set) var model: LiveGuideGridModel?
    @Published private(set) var conversionFailed = false
    private(set) var scope: LiveGuideViewScope?
    private(set) var renderRevision: UUID?
    private var serial: UInt64 = 0
    private var pending: (EPGGuideSnapshot, [String: String], UInt64)?
    private var worker: Task<Void, Never>?
    private let convert: @Sendable (EPGGuideSnapshot, [String: String]) async -> LiveGuideGridModel?

    init(convert: @escaping @Sendable (EPGGuideSnapshot, [String: String]) async -> LiveGuideGridModel? = { snapshot, subtitles in
        await Task.detached(priority: .userInitiated) {
            try? LiveGuideGridModel(snapshot: snapshot, timeZone: .current, subtitles: subtitles)
        }.value
    }) { self.convert = convert }

    func submit(_ snapshot: EPGGuideSnapshot?, scope: LiveGuideViewScope,
                subtitles: [String: String] = [:]) {
        serial &+= 1
        conversionFailed = false
        pending = nil
        if self.scope != scope || snapshot == nil {
            model = nil
            renderRevision = nil
        }
        self.scope = scope
        guard let snapshot, scope.accepts(snapshot) else { return }
        pending = (snapshot, subtitles, serial)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let (snapshot, subtitles, ticket) = self.pending {
                self.pending = nil
                let candidate = await self.convert(snapshot, subtitles)
                guard self.serial == ticket, self.scope?.accepts(snapshot) == true else { continue }
                self.conversionFailed = candidate == nil
                if let candidate {
                    self.renderRevision = snapshot.demandRevision
                    self.model = candidate
                }
            }
            self.worker = nil
        }
    }

    func acceptsCallback(scope: LiveGuideViewScope, revision: UUID?) -> Bool {
        self.scope == scope && revision != nil && renderRevision == revision && model != nil
    }

    func rejectScope() {
        invalidate()
        conversionFailed = true
    }

    func invalidate() {
        serial &+= 1
        conversionFailed = false
        pending = nil
        scope = nil
        renderRevision = nil
        model = nil
    }
}

struct LiveGuideTimeAxisTick: Equatable {
    let date: Date
    let label: String
}

enum LiveGuideTimeAxisFormatter {
    static func ticks(from start: Date, to end: Date, timeZone: TimeZone,
                      interval: TimeInterval = 30 * 60) -> [LiveGuideTimeAxisTick] {
        guard start < end, interval > 0 else { return [] }
        var dates: [Date] = []
        var value = start
        while value <= end, dates.count < 64 {
            dates.append(value)
            value = value.addingTimeInterval(interval)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let base = dates.map(formatter.string)
        let duplicateLabels = Set(Dictionary(grouping: base, by: { $0 })
            .filter { $0.value.count > 1 }.map(\.key))
        let offset = DateFormatter()
        offset.locale = formatter.locale
        offset.timeZone = timeZone
        offset.dateFormat = "ZZZZZ"
        return zip(dates, base).map { date, label in
            let final = duplicateLabels.contains(label)
                ? "\(label) GMT\(offset.string(from: date))" : label
            return LiveGuideTimeAxisTick(date: date, label: final)
        }
    }
}

struct LiveGuideGridDebugMetrics: Equatable {
    let totalProgrammes: Int
    let visibleProgrammeViews: Int
    let realizedProgrammeViews: Int
    let maximumVisibleProgrammeViews: Int
    let emittedLayoutAttributes: Int
    let cachedTimeLabels: Int
}

struct LiveGuideGridFixedFrames: Equatable {
    let corner: NSRect
    let timeHeader: NSRect
    let channelHeader: NSRect
    let content: NSRect
}

/// Logical time coordinates are independent of paint insets and hit targets.
enum LiveGuideGeometry {
    static let pointsPerHour: CGFloat = 240
    static let hitWidth: CGFloat = 36

    static func timeFrame(start: Date, end: Date, windowStart: Date, windowEnd: Date,
                          row: Int) -> NSRect? {
        let lower = max(start, windowStart), upper = min(end, windowEnd)
        guard lower < upper else { return nil }
        let x = CGFloat(lower.timeIntervalSince(windowStart) / 3_600) * pointsPerHour
        let width = CGFloat(upper.timeIntervalSince(lower) / 3_600) * pointsPerHour
        guard x.isFinite, width.isFinite, width > 0 else { return nil }
        return NSRect(x: x, y: CGFloat(row) * LiveGuideGridView.rowHeight,
                      width: width, height: LiveGuideGridView.rowHeight)
    }

    static func renderFrame(_ time: NSRect) -> NSRect {
        // Subpixel entries remain subpixel; an inset may never erase or widen them.
        time.insetBy(dx: min(2, time.width / 4), dy: 6)
    }

    static func hitFrame(_ time: NSRect, bounds: NSRect) -> NSRect {
        NSRect(x: time.midX - max(time.width, hitWidth) / 2, y: time.minY,
               width: max(time.width, hitWidth), height: time.height).intersection(bounds)
    }
}

enum LiveGuideProgrammePhase {
    case past, current, future
    static func phase(start: Date, end: Date, now: Date) -> Self {
        if end <= now { return .past }
        return start <= now ? .current : .future
    }
}

enum LiveGuideRepositionReason { case initial, sourceChanged, dateChanged, now }

struct LiveGuideRepositionRequest: Equatable {
    let id = UUID()
    let date: Date
}

final class LiveGuideGridView: NSView, BrowserContentKeyTarget {
    var navigationSelection: NavigationSelection?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { grid.keyDown(with: event) }
    static let rowHeight: CGFloat = 72
    static let timeHeaderHeight: CGFloat = 44
    static let channelColumnWidth: CGFloat = 172
    /// A programme's visual width must always describe elapsed media time.
    /// Short entries receive a larger hit target, never a different timeline.
    static let pointsPerHour = LiveGuideGeometry.pointsPerHour
    static let minimumProgrammeHitWidth = LiveGuideGeometry.hitWidth

    private let cornerLabel = NSTextField(labelWithString: "Program Guide")
    private let timeHeader = LiveGuideTimeHeaderView()
    private let channelHeader = LiveGuideChannelHeaderView()
    private let grid = LiveGuideViewportView()
    private let scrollView = NSScrollView()
    private let document = LiveGuideDocumentView()
    private var boundsObserver: NSObjectProtocol?
    private(set) var model: LiveGuideGridModel?
    private var maximumVisibleProgrammeViews = 0
    private var selectedProgrammeIndexPath: IndexPath?
    private var virtualOffset = NSPoint.zero
    private var previousViewportWidth: CGFloat = 0
    private var pendingPositionDate: Date?
    private(set) var lastRepositionReason: LiveGuideRepositionReason?
    var onProgrammeActivated: ((LiveGuideGridRow, LiveGuideGridProgramme) -> Void)?
    var onProgrammeSelected: ((LiveGuideGridRow, LiveGuideGridProgramme) -> Void)?
    var onChannelActivated: ((LiveGuideGridRow) -> Void)? {
        didSet { channelHeader.onChannelActivated = onChannelActivated }
    }
    var onVisibleRangeChanged: ((Range<Int>) -> Void)?
    private var lastVisibleRange: Range<Int>?

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)

        cornerLabel.stringValue = L10n.string("live.guide.channels", fallback: "Channels")
        cornerLabel.alignment = .left
        cornerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cornerLabel.textColor = .secondaryLabelColor
        cornerLabel.lineBreakMode = .byTruncatingTail
        cornerLabel.setAccessibilityRole(.staticText)
        cornerLabel.setAccessibilityLabel(cornerLabel.stringValue)

        grid.onMoveSelection = { [weak self] horizontal, vertical in
            self?.moveSelection(horizontal: horizontal, vertical: vertical)
        }
        grid.onActivateSelection = { [weak self] in self?.activateSelection() }
        grid.onSelectProgramme = { [weak self] programmeIndex, rowIndex, activate in
            self?.selectProgramme(item: programmeIndex, section: rowIndex, activate: activate)
        }
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        timeHeader.nextResponder = scrollView
        channelHeader.nextResponder = scrollView
        document.addSubview(grid)
        grid.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronizeViewport() }
            }
        addSubview(cornerLabel)
        addSubview(timeHeader)
        addSubview(channelHeader)
        addSubview(scrollView)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.labelColor.withAlphaComponent(0.09).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: Self.timeHeaderHeight - 0.5),
            to: NSPoint(x: bounds.width, y: Self.timeHeaderHeight - 0.5))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let headerHeight = min(Self.timeHeaderHeight, bounds.height)
        let columnWidth = min(Self.channelColumnWidth, bounds.width)
        let contentWidth = max(0, bounds.width - columnWidth)
        let contentHeight = max(0, bounds.height - headerHeight)
        cornerLabel.frame = NSRect(x: 16, y: (headerHeight - 16) / 2,
            width: max(0, columnWidth - 28), height: 16)
        timeHeader.frame = NSRect(x: columnWidth, y: 0,
            width: contentWidth, height: headerHeight)
        channelHeader.frame = NSRect(x: 0, y: headerHeight,
            width: columnWidth, height: contentHeight)
        scrollView.frame = NSRect(x: columnWidth, y: headerHeight,
            width: contentWidth, height: contentHeight)
        updateDocumentSize()
        var proposed = virtualOffset
        if let target = pendingPositionDate, let model, contentWidth > 0 {
            proposed.x = CGFloat(target.timeIntervalSince(model.windowStart) / 3600)
                * Self.pointsPerHour - contentWidth * 0.25
            pendingPositionDate = nil
        } else if previousViewportWidth > 0, previousViewportWidth != contentWidth {
            proposed.x += (previousViewportWidth - contentWidth) / 2
        }
        previousViewportWidth = contentWidth
        setVirtualOffset(proposed)
        for child in [timeHeader, channelHeader, grid] { child.needsDisplay = true }
    }

    func apply(_ model: LiveGuideGridModel, now: Date = Date()) {
        let previousModel = self.model
        let previousOffset = virtualOffset
        let topIndex = Int(previousOffset.y / Self.rowHeight)
        let topRowID = previousModel.flatMap { $0.rows.indices.contains(topIndex) ? $0.rows[topIndex].id : nil }
        let topInset = previousOffset.y.truncatingRemainder(dividingBy: Self.rowHeight)
        let selected: (String, LiveGuideGridProgramme)? = selectedProgrammeIndexPath.flatMap { indexPath in
            guard let previousModel,
                  previousModel.rows.indices.contains(indexPath.section),
                  previousModel.rows[indexPath.section].programmes.indices.contains(indexPath.item)
            else { return nil }
            return (previousModel.rows[indexPath.section].id, previousModel.rows[indexPath.section].programmes[indexPath.item])
        }
        let preservesViewport = previousModel?.windowStart == model.windowStart
            && previousModel?.windowEnd == model.windowEnd
            && previousModel?.timeZone == model.timeZone
        self.model = model
        let pointsPerHour = Self.pointsPerHour
        grid.configure(rows: model.rows, windowStart: model.windowStart,
            windowEnd: model.windowEnd, pointsPerHour: pointsPerHour,
            timeZone: model.timeZone, now: now)
        timeHeader.configure(start: model.windowStart, end: model.windowEnd,
            timeZone: model.timeZone, pointsPerHour: pointsPerHour)
        channelHeader.rows = model.rows
        channelHeader.selectedRowID = nil
        timeHeader.now = now
        maximumVisibleProgrammeViews = 0
        selectedProgrammeIndexPath = nil
        if preservesViewport, let selected,
           let restored = model.rows.enumerated().lazy.compactMap({ rowIndex, row -> IndexPath? in
               guard row.id == selected.0 else { return nil }
               return row.programmes.firstIndex(where: {
                   $0.start == selected.1.start && $0.end == selected.1.end && $0.title == selected.1.title
               }).map {
                   IndexPath(item: $0, section: rowIndex)
               }
           }).first {
            selectedProgrammeIndexPath = restored
            grid.selectedProgrammeID = model.rows[restored.section].programmes[restored.item].id
            channelHeader.selectedRowID = model.rows[restored.section].id
        }
        if !preservesViewport { lastVisibleRange = nil }
        if preservesViewport {
            let row = topRowID.flatMap { id in model.rows.firstIndex(where: { $0.id == id }) }
            let y = row.map { CGFloat($0) * Self.rowHeight + topInset } ?? 0
            setVirtualOffset(NSPoint(x: previousOffset.x, y: y))
        } else {
            setVirtualOffset(.zero)
            reposition(to: model.windowStart <= now && now < model.windowEnd ? now : model.windowStart,
                       reason: previousModel == nil ? .initial : .dateChanged)
        }
    }

    func reposition(to date: Date, reason: LiveGuideRepositionReason) {
        guard let model else { return }
        lastRepositionReason = reason
        if grid.bounds.width <= 0 {
            pendingPositionDate = date
            needsLayout = true
        } else {
            let x = CGFloat(date.timeIntervalSince(model.windowStart) / 3600) * Self.pointsPerHour
                - grid.bounds.width * 0.25
            setVirtualOffset(NSPoint(x: x, y: virtualOffset.y))
        }
    }

    func clear() {
        guard model != nil else { return }
        model = nil
        pendingPositionDate = nil
        selectedProgrammeIndexPath = nil
        channelHeader.rows = []
        channelHeader.selectedRowID = nil
        timeHeader.clear()
        grid.configure(rows: [], windowStart: .distantPast, windowEnd: .distantPast,
            pointsPerHour: Self.pointsPerHour, timeZone: .current, now: Date())
        lastVisibleRange = nil
        setVirtualOffset(.zero)
    }

    func updateNow(_ date: Date) {
        timeHeader.now = date
        grid.now = date
        grid.needsDisplay = true
    }

    func scroll(to point: NSPoint) { setVirtualOffset(point) }

    var scrollOffset: NSPoint { virtualOffset }

    var debugFixedFrames: LiveGuideGridFixedFrames {
        LiveGuideGridFixedFrames(corner: cornerLabel.frame, timeHeader: timeHeader.frame,
                                 channelHeader: channelHeader.frame, content: scrollView.frame)
    }

    var debugSelectedIndexPath: IndexPath? { selectedProgrammeIndexPath }

    var debugNowLineX: CGFloat? {
        guard let model, model.windowStart <= grid.now, grid.now <= model.windowEnd else {
            return nil
        }
        return CGFloat(grid.now.timeIntervalSince(model.windowStart) / 3_600)
            * grid.pointsPerHour
    }

    var debugVisibleAccessibilityLabels: [String] {
        grid.visibleAccessibilityLabels
    }

    var debugVisibleProgrammeWidths: [CGFloat] { grid.visibleProgrammeWidths }
    var debugVisibleProgrammeFrames: [NSRect] { grid.visibleProgrammeFrames }

    func debugSelect(item: Int, section: Int) {
        selectProgramme(item: item, section: section, activate: false)
    }

    func debugMoveSelection(horizontal: Int, vertical: Int) {
        moveSelection(horizontal: horizontal, vertical: vertical)
    }

    func debugActivateSelection() { activateSelection() }

    var debugMetrics: LiveGuideGridDebugMetrics {
        let visible = grid.visibleProgrammeCount
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews, visible)
        return LiveGuideGridDebugMetrics(
            totalProgrammes: model?.rows.reduce(0, { $0 + $1.programmes.count }) ?? 0,
            visibleProgrammeViews: visible,
            realizedProgrammeViews: model == nil ? 0 : 1,
            maximumVisibleProgrammeViews: maximumVisibleProgrammeViews,
            emittedLayoutAttributes: visible,
            cachedTimeLabels: timeHeader.cachedLabelCount)
    }

    private var contentSize: NSSize {
        guard let model else { return .zero }
        return NSSize(
            width: CGFloat(model.windowEnd.timeIntervalSince(model.windowStart) / 3_600)
                * grid.pointsPerHour,
            height: CGFloat(model.rows.count) * Self.rowHeight)
    }

    private var maximumOffset: NSPoint {
        NSPoint(x: max(0, contentSize.width - grid.bounds.width),
                y: max(0, contentSize.height - grid.bounds.height))
    }

    private func updateDocumentSize() {
        let size = NSSize(width: max(contentSize.width, scrollView.contentSize.width),
                          height: max(contentSize.height, scrollView.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    /// Only explicit navigation writes the clip position. Wheel phases, momentum
    /// and scrollers are owned entirely by NSScrollView.
    private func setVirtualOffset(_ proposed: NSPoint) {
        updateDocumentSize()
        let maximum = NSPoint(x: max(0, contentSize.width - scrollView.contentSize.width),
                              y: max(0, contentSize.height - scrollView.contentSize.height))
        let point = NSPoint(x: min(max(0, proposed.x), maximum.x),
                            y: min(max(0, proposed.y), maximum.y))
        if scrollView.contentView.bounds.origin != point {
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        synchronizeViewport()
    }

    private func synchronizeViewport() {
        let viewport = scrollView.contentView.bounds
        virtualOffset = viewport.origin
        // The logical document has no backing layer. Only this viewport-sized
        // child draws programme cells, even for thousands of channels.
        grid.frame = viewport
        grid.virtualOffset = virtualOffset
        timeHeader.horizontalOffset = virtualOffset.x
        channelHeader.verticalOffset = virtualOffset.y
        updateVisibleRange()
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews, grid.visibleProgrammeCount)
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    private func updateVisibleRange() {
        guard let rows = model?.rows, !rows.isEmpty, grid.bounds.height > 0 else { return }
        let first = min(rows.count - 1,
            max(0, Int(floor(virtualOffset.y / Self.rowHeight))))
        let last = min(rows.count,
            max(first + 1, Int(ceil((virtualOffset.y + grid.bounds.height) / Self.rowHeight))))
        let range = first..<last
        if range != lastVisibleRange {
            lastVisibleRange = range
            onVisibleRangeChanged?(range)
        }
    }

    private func moveSelection(horizontal: Int, vertical: Int) {
        guard let rows = model?.rows, !rows.isEmpty else { return }
        let current = selectedProgrammeIndexPath
        var section = current?.section ?? 0
        var item = current?.item ?? 0
        if vertical == 0 {
            let count = rows[section].programmes.count
            guard count > 0 else { return }
            item = min(max(0, item + horizontal), count - 1)
        } else {
            let sourceDate: Date
            if rows[section].programmes.indices.contains(item) {
                let value = rows[section].programmes[item]
                sourceDate = midpoint(value)
            } else {
                sourceDate = model?.windowStart ?? Date()
            }
            var target = section + vertical
            while rows.indices.contains(target), rows[target].programmes.isEmpty {
                target += vertical
            }
            guard rows.indices.contains(target), !rows[target].programmes.isEmpty else { return }
            section = target
            item = rows[section].programmes.enumerated().min { left, right in
                abs(midpoint(left.element).timeIntervalSince(sourceDate))
                    < abs(midpoint(right.element).timeIntervalSince(sourceDate))
            }?.offset ?? 0
        }
        selectProgramme(item: item, section: section, activate: false)
        scrollSelectedProgrammeToVisible()
    }

    private func activateSelection() {
        guard let indexPath = selectedProgrammeIndexPath,
              let rows = model?.rows, rows.indices.contains(indexPath.section),
              rows[indexPath.section].programmes.indices.contains(indexPath.item) else { return }
        onProgrammeActivated?(rows[indexPath.section], rows[indexPath.section].programmes[indexPath.item])
    }

    private func selectProgramme(item: Int, section: Int, activate: Bool) {
        guard let rows = model?.rows, rows.indices.contains(section),
              rows[section].programmes.indices.contains(item) else { return }
        selectedProgrammeIndexPath = IndexPath(item: item, section: section)
        window?.makeFirstResponder(grid)
        grid.selectedProgrammeID = rows[section].programmes[item].id
        channelHeader.selectedRowID = rows[section].id
        let row = rows[section]
        let programme = row.programmes[item]
        onProgrammeSelected?(row, programme)
        if activate { onProgrammeActivated?(row, programme) }
    }

    private func scrollSelectedProgrammeToVisible() {
        guard let selectedProgrammeIndexPath,
              let model, model.rows.indices.contains(selectedProgrammeIndexPath.section),
              model.rows[selectedProgrammeIndexPath.section].programmes.indices
                .contains(selectedProgrammeIndexPath.item) else { return }
        let programme = model.rows[selectedProgrammeIndexPath.section]
            .programmes[selectedProgrammeIndexPath.item]
        guard let frame = LiveGuideGeometry.timeFrame(start: programme.start, end: programme.end,
            windowStart: model.windowStart, windowEnd: model.windowEnd,
            row: selectedProgrammeIndexPath.section) else { return }
        let x = frame.minX, width = frame.width, y = frame.minY
        var proposed = virtualOffset
        if x < proposed.x { proposed.x = x }
        if x + width > proposed.x + grid.bounds.width {
            proposed.x = x + width - grid.bounds.width
        }
        if y < proposed.y { proposed.y = y }
        if y + Self.rowHeight > proposed.y + grid.bounds.height {
            proposed.y = y + Self.rowHeight - grid.bounds.height
        }
        setVirtualOffset(proposed)
    }

    private func midpoint(_ value: LiveGuideGridProgramme) -> Date {
        value.start.addingTimeInterval(value.end.timeIntervalSince(value.start) / 2)
    }

}

private struct LiveGuideVisibleProgramme {
    let rowIndex: Int
    let programmeIndex: Int
    let row: LiveGuideGridRow
    let programme: LiveGuideGridProgramme
    let timeFrame: NSRect
    let frame: NSRect
    let hitFrame: NSRect
    let timeRange: String
}

/// A fixed-size viewport whose backing surface is bounded by the window.
/// It virtualizes rows and time horizontally using `virtualOffset`; the
/// potentially very large logical guide never becomes an AppKit view or layer.
private final class LiveGuideDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum LiveGuideAppearance {
    static var divider: NSColor { .labelColor.withAlphaComponent(0.09) }
    static func fill(phase: LiveGuideProgrammePhase, selected: Bool, hovered: Bool) -> NSColor {
        let fraction = selected ? 0.12 : (hovered ? 0.07 : (phase == .current ? 0.055 : (phase == .past ? 0.018 : 0.035)))
        return NSColor.controlBackgroundColor.blended(withFraction: fraction,
            of: selected || phase == .current ? .systemBlue : .labelColor) ?? .controlBackgroundColor
    }
    static func stroke(selected: Bool, hovered: Bool, contrast: Bool) -> NSColor {
        if selected { return NSColor.systemBlue.withAlphaComponent(contrast ? 0.9 : 0.55) }
        return NSColor.labelColor.withAlphaComponent(contrast ? 0.28 : (hovered ? 0.18 : 0.07))
    }
}

private final class LiveGuideViewportView: NSView {
    private(set) var rows: [LiveGuideGridRow] = []
    private(set) var windowStart = Date()
    private(set) var windowEnd = Date()
    private(set) var pointsPerHour = LiveGuideGridView.pointsPerHour
    private var timeZone = TimeZone.current
    var now = Date()
    var virtualOffset = NSPoint.zero {
        didSet { needsDisplay = true; hoveredProgrammeID = nil; toolTip = nil }
    }
    private var showsKeyboardFocus = false
    private var hoveredProgrammeID: EPGProgrammeRecordIdentity?
    private var hoverTrackingArea: NSTrackingArea?
    var selectedProgrammeID: EPGProgrammeRecordIdentity? {
        didSet { if oldValue != selectedProgrammeID { needsDisplay = true } }
    }
    var onMoveSelection: ((Int, Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onSelectProgramme: ((Int, Int, Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.grid)
        setAccessibilityLabel(L10n.string("live.guide.title", fallback: "Program Guide"))
    }

    required init?(coder: NSCoder) { nil }

    func configure(rows: [LiveGuideGridRow], windowStart: Date, windowEnd: Date,
                   pointsPerHour: CGFloat, timeZone: TimeZone, now: Date) {
        self.rows = rows
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.pointsPerHour = pointsPerHour
        self.timeZone = timeZone
        self.now = now
        selectedProgrammeID = nil
        hoveredProgrammeID = nil
        toolTip = nil
        needsDisplay = true
    }

    var visibleProgrammeCount: Int { visibleProgrammes().count }
    var visibleProgrammeWidths: [CGFloat] { visibleProgrammes().map(\.timeFrame.width) }
    var visibleProgrammeFrames: [NSRect] { visibleProgrammes().map(\.frame) }
    var visibleAccessibilityLabels: [String] {
        visibleProgrammes().map { "\($0.row.title), \($0.programme.title)" }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        // Quiet rules keep time and channel alignment readable between cells.
        LiveGuideAppearance.divider.setStroke()
        let firstRow = max(0, Int(floor(virtualOffset.y / LiveGuideGridView.rowHeight)))
        let lastRow = min(rows.count, Int(ceil((virtualOffset.y + bounds.height) / LiveGuideGridView.rowHeight)))
        if firstRow <= lastRow {
            for row in firstRow...lastRow {
                let y = CGFloat(row) * LiveGuideGridView.rowHeight - virtualOffset.y
                let rule = NSBezierPath(); rule.lineWidth = 0.5
                rule.move(to: NSPoint(x: 0, y: y)); rule.line(to: NSPoint(x: bounds.maxX, y: y)); rule.stroke()
            }
        }
        // Draw the time line under the cards so it never cuts through titles.
        if windowStart <= now, now <= windowEnd {
            let x = CGFloat(now.timeIntervalSince(windowStart) / 3_600) * pointsPerHour - virtualOffset.x
            if bounds.minX...bounds.maxX ~= x {
                NSColor.systemRed.withAlphaComponent(0.65).setStroke()
                let path = NSBezierPath(); path.lineWidth = 1
                path.move(to: NSPoint(x: x, y: dirtyRect.minY))
                path.line(to: NSPoint(x: x, y: dirtyRect.maxY)); path.stroke()
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let contrast = NativeNeutralProgressView.increasedContrast(in: effectiveAppearance)
        for value in visibleProgrammes() where value.frame.intersects(dirtyRect) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: value.frame.intersection(bounds)).addClip()
            let selected = value.programme.id == selectedProgrammeID
            let phase = LiveGuideProgrammePhase.phase(start: value.programme.start, end: value.programme.end, now: now)
            let hovered = value.programme.id == hoveredProgrammeID
            let card = NSBezierPath(roundedRect: value.frame.insetBy(dx: min(0.5, value.frame.width / 4), dy: 0.5), xRadius: 6, yRadius: 6)
            LiveGuideAppearance.fill(phase: phase, selected: selected, hovered: hovered).setFill()
            card.fill()
            LiveGuideAppearance.stroke(selected: selected, hovered: hovered, contrast: contrast).setStroke()
            card.lineWidth = selected ? 1 : 0.5; card.stroke()
            if selected && showsKeyboardFocus && window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                card.lineWidth = 2; card.stroke()
            }
            if phase == .current && value.frame.width >= 12 {
                NSColor.systemBlue.withAlphaComponent(0.65).setFill()
                NSBezierPath(roundedRect: NSRect(x: value.frame.minX + 1, y: value.frame.minY + 10,
                    width: 2, height: value.frame.height - 20), xRadius: 1, yRadius: 1).fill()
            }
            // A long programme keeps its title readable when its leading edge
            // scrolls offscreen; vertical text origins remain attached to rows.
            let textX = max(value.frame.minX, bounds.minX) + 10
            let textWidth = max(0, min(value.frame.maxX, bounds.maxX) - textX - 10)
            let foreground: NSColor = phase == .past && !selected ? .secondaryLabelColor : .labelColor
            if textWidth >= 30 {
                value.programme.title.draw(in: NSRect(x: textX, y: value.frame.minY + 10,
                    width: textWidth, height: 19), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : (phase == .current ? .medium : .regular)),
                        .foregroundColor: foreground, .paragraphStyle: paragraph])
            }
            if textWidth >= 82 {
                value.timeRange.draw(in: NSRect(x: textX, y: value.frame.minY + 33,
                    width: textWidth, height: 16), withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            }
        }

    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let value = visibleProgrammes().last { $0.timeFrame.contains(point) }
        if hoveredProgrammeID != value?.programme.id {
            hoveredProgrammeID = value?.programme.id
            toolTip = value.map { "\($0.row.title) · \($0.programme.title)\n\($0.timeRange)" }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredProgrammeID = nil
        toolTip = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        showsKeyboardFocus = true; needsDisplay = true
        switch event.keyCode {
        case 123: onMoveSelection?(-1, 0)
        case 124: onMoveSelection?(1, 0)
        case 125: onMoveSelection?(0, 1)
        case 126: onMoveSelection?(0, -1)
        case 36, 49: onActivateSelection?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        showsKeyboardFocus = false; needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        let visible = visibleProgrammes()
        guard let value = visible.last(where: { $0.timeFrame.contains(point) })
                ?? visible.min(by: { left, right in
                    let leftDistance = left.hitFrame.contains(point)
                        ? abs(left.frame.midX - point.x) : .greatestFiniteMagnitude
                    let rightDistance = right.hitFrame.contains(point)
                        ? abs(right.frame.midX - point.x) : .greatestFiniteMagnitude
                    return leftDistance < rightDistance
                }).flatMap({ $0.hitFrame.contains(point) ? $0 : nil }) else {
            return super.mouseDown(with: event)
        }
        onSelectProgramme?(value.programmeIndex, value.rowIndex, event.clickCount >= 2)
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { showsKeyboardFocus = false; needsDisplay = true }
        return accepted
    }

    override func accessibilityChildren() -> [Any]? {
        visibleProgrammes().map { value in
            let element = LiveGuideProgrammeAccessibilityElement { [weak self, rowID = value.row.id, programmeID = value.programme.id] in
                guard let self, let row = self.rows.firstIndex(where: { $0.id == rowID }),
                      let item = self.rows[row].programmes.firstIndex(where: { $0.id == programmeID }) else { return }
                self.onSelectProgramme?(item, row, true)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(value.row.title), \(value.programme.title)")
            element.setAccessibilityValue(value.timeRange)
            element.setAccessibilitySelected(value.programme.id == selectedProgrammeID)
            let windowFrame = convert(value.hitFrame, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(windowFrame) ?? .zero)
            return element
        }
    }

    private func visibleProgrammes() -> [LiveGuideVisibleProgramme] {
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let firstRow = max(0, Int(floor(virtualOffset.y / LiveGuideGridView.rowHeight)))
        let lastRow = min(rows.count - 1,
            Int(floor((virtualOffset.y + bounds.height - 0.001)
                / LiveGuideGridView.rowHeight)))
        guard firstRow <= lastRow else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let minimumX = virtualOffset.x
        let maximumX = virtualOffset.x + bounds.width
        var result: [LiveGuideVisibleProgramme] = []
        result.reserveCapacity((lastRow - firstRow + 1) * 12)
        for rowIndex in firstRow...lastRow {
            let row = rows[rowIndex]
            for (programmeIndex, programme) in row.programmes.enumerated() {
                guard let logical = LiveGuideGeometry.timeFrame(
                    start: programme.start, end: programme.end, windowStart: windowStart,
                    windowEnd: windowEnd, row: rowIndex),
                    logical.maxX >= minimumX, logical.minX <= maximumX else { continue }
                let timeFrame = logical.offsetBy(dx: -virtualOffset.x, dy: -virtualOffset.y)
                let frame = LiveGuideGeometry.renderFrame(timeFrame)
                guard !frame.isEmpty, frame.intersects(bounds) else { continue }
                let hitFrame = LiveGuideGeometry.hitFrame(timeFrame, bounds: bounds)
                result.append(LiveGuideVisibleProgramme(
                    rowIndex: rowIndex, programmeIndex: programmeIndex,
                    row: row, programme: programme, timeFrame: timeFrame, frame: frame, hitFrame: hitFrame,
                    timeRange: "\(formatter.string(from: programme.start))–\(formatter.string(from: programme.end))"
                ))
            }
        }
        return result
    }
}

/// The SwiftUI parent owns finite page dimensions; the guide never proposes
/// its virtual 12-hour document as its intrinsic size.
struct LiveGuideViewportHost<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            content()
                .frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height))
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }
}

struct LiveGuideGridRepresentable: NSViewRepresentable {
    @Environment(\.browserNavigationSelection) private var navigationSelection
    let model: LiveGuideGridModel?
    let now: Date
    var scope: LiveGuideViewScope? = nil
    var reposition: LiveGuideRepositionRequest? = nil
    let onProgrammeSelected: (LiveGuideGridRow, LiveGuideGridProgramme) -> Void
    let onProgrammeActivated: (LiveGuideGridRow, LiveGuideGridProgramme) -> Void
    let onChannelActivated: (LiveGuideGridRow) -> Void
    let onVisibleRangeChanged: (Range<Int>) -> Void

    final class Coordinator {
        var model: LiveGuideGridModel?
        var scope: LiveGuideViewScope?
        var repositionID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiveGuideGridView {
        let view = LiveGuideGridView()
        connect(view)
        return view
    }

    func updateNSView(_ view: LiveGuideGridView, context: Context) {
        connect(view)
        if context.coordinator.scope?.source != scope?.source {
            view.clear()
            context.coordinator.model = nil
        }
        context.coordinator.scope = scope
        view.isHidden = model == nil
        // Keep the host's position while new rows are converted. The old rows
        // are hidden and cannot receive interaction during a scope change.
        guard let model else { return }
        if context.coordinator.model != model {
            context.coordinator.model = model
            view.apply(model, now: now)
        } else {
            view.updateNow(now)
        }
        if let reposition, context.coordinator.repositionID != reposition.id,
           model.windowStart <= reposition.date, reposition.date < model.windowEnd {
            context.coordinator.repositionID = reposition.id
            view.reposition(to: reposition.date, reason: .now)
        }
    }

    private func connect(_ view: LiveGuideGridView) {
        view.navigationSelection = navigationSelection
        (BrowserKeyboardView.descendants(of: view.window?.contentView).first { $0 is BrowserSidebarOutlineView }
            as? BrowserSidebarOutlineView)?.scheduleContentFocus()
        view.onProgrammeSelected = onProgrammeSelected
        view.onProgrammeActivated = onProgrammeActivated
        view.onChannelActivated = onChannelActivated
        view.onVisibleRangeChanged = onVisibleRangeChanged
    }
}

private final class LiveGuideProgrammeAccessibilityElement: NSAccessibilityElement {
    private let press: () -> Void

    init(press: @escaping () -> Void) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

private final class LiveGuideTimeHeaderView: NSView {
    var now = Date() { didSet { needsDisplay = true } }
    private var start = Date()
    private var end = Date()
    private var timeZone = TimeZone.current
    private var pointsPerHour: CGFloat = LiveGuideGeometry.pointsPerHour
    private var ticks: [LiveGuideTimeAxisTick] = []
    var horizontalOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    var cachedLabelCount: Int { ticks.count }
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Time axis")
    }
    required init?(coder: NSCoder) { nil }

    func clear() { ticks = []; needsDisplay = true }

    func configure(start: Date, end: Date, timeZone: TimeZone, pointsPerHour: CGFloat) {
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.pointsPerHour = pointsPerHour
        ticks = LiveGuideTimeAxisFormatter.ticks(from: start, to: end, timeZone: timeZone)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill(); bounds.intersection(dirtyRect).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor]
        let nowX = CGFloat(now.timeIntervalSince(start) / 3600) * pointsPerHour - horizontalOffset
        let showsNow = start <= now && now < end && nowX >= 0 && nowX <= bounds.width
        let badge = NSRect(x: min(max(nowX - 25, 2), max(2, bounds.width - 52)), y: 9, width: 50, height: 22)
        for tick in ticks {
            let x = CGFloat(tick.date.timeIntervalSince(start) / 3600) * pointsPerHour - horizontalOffset
            guard x >= dirtyRect.minX - 100, x <= dirtyRect.maxX + 10 else { continue }
            let labelWidth = tick.label.size(withAttributes: attributes).width
            let rect = NSRect(x: x + 6, y: 14, width: labelWidth, height: 16)
            if bounds.contains(rect), !showsNow || !rect.intersects(badge.insetBy(dx: -5, dy: 0)) {
                tick.label.draw(at: rect.origin, withAttributes: attributes)
            }
            LiveGuideAppearance.divider.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: bounds.maxY - 6), to: NSPoint(x: x, y: bounds.maxY))
        }
        LiveGuideAppearance.divider.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: bounds.maxY - 0.5), to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        if showsNow {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            let formatter = DateFormatter(); formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
            let text = formatter.string(from: now)
            let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let width = text.size(withAttributes: style).width
            text.draw(at: NSPoint(x: badge.midX - width / 2, y: badge.minY + 4), withAttributes: style)
            NSColor.systemRed.withAlphaComponent(0.65).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: nowX, y: badge.maxY + 2), to: NSPoint(x: nowX, y: bounds.maxY))
        }
    }

}

private final class LiveGuideChannelHeaderView: NSView {
    var selectedRowID: String? { didSet { needsDisplay = true } }
    var rows: [LiveGuideGridRow] = [] { didSet { needsDisplay = true } }
    var verticalOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChannelActivated: ((LiveGuideGridRow) -> Void)?
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(L10n.string("live.guide.channels", fallback: "Channels"))
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount >= 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.y + verticalOffset) / LiveGuideGridView.rowHeight))
        guard rows.indices.contains(index) else { return }
        onChannelActivated?(rows[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        LiveGuideAppearance.divider.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: bounds.maxX - 0.5, y: 0),
            to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        let first = max(0, Int(floor((dirtyRect.minY + verticalOffset) / LiveGuideGridView.rowHeight)))
        let last = min(rows.count - 1,
            Int(floor((dirtyRect.maxY + verticalOffset) / LiveGuideGridView.rowHeight)))
        guard first <= last, !rows.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for index in first...last {
            let y = CGFloat(index) * LiveGuideGridView.rowHeight - verticalOffset
            let row = rows[index]
            let selected = row.id == selectedRowID
            if selected {
                NSColor.systemBlue.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: y + 6, width: bounds.width - 16,
                    height: LiveGuideGridView.rowHeight - 12), xRadius: 6, yRadius: 6).fill()
            }
            let titleY = y + (row.subtitle == nil ? 26 : 16)
            let title: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]
            row.title.draw(in: NSRect(x: 16, y: titleY, width: bounds.width - 32, height: 19),
                           withAttributes: title)
            if let subtitle = row.subtitle {
                subtitle.draw(in: NSRect(x: 16, y: y + 39, width: bounds.width - 32, height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                     .foregroundColor: NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
            }
            LiveGuideAppearance.divider.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: 16, y: y + LiveGuideGridView.rowHeight - 0.5),
                                    to: NSPoint(x: bounds.maxX, y: y + LiveGuideGridView.rowHeight - 0.5))
        }
    }
}
