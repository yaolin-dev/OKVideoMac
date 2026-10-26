import AppKit
import OKVideoCore
import SwiftUI

struct AppActivityIndicatorLifecycle: Equatable {
    static let cycleDuration: TimeInterval = 0.85

    private(set) var isVisible = false
    private(set) var reduceMotion = false

    var isAnimating: Bool {
        isVisible && !reduceMotion
    }

    mutating func appear(reduceMotion: Bool) {
        isVisible = true
        self.reduceMotion = reduceMotion
    }

    mutating func updateReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    mutating func disappear() {
        isVisible = false
    }

    func rotationDegrees(at date: Date) -> Double {
        guard isAnimating else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.cycleDuration)
        return elapsed / Self.cycleDuration * 360
    }
}

struct AppActivityIndicator: View {
    enum Size {
        case mini
        case small
        case regular

        var diameter: CGFloat {
            switch self {
            case .mini: return 12
            case .small: return 16
            case .regular: return 28
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .mini: return 1.5
            case .small: return 2
            case .regular: return 3
            }
        }
    }

    let size: Size
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifecycle = AppActivityIndicatorLifecycle()

    init(size: Size = .regular, tint: Color = .accentColor) {
        self.size = size
        self.tint = tint
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: !lifecycle.isAnimating
            )
        ) { timeline in
            Circle()
                .trim(from: 0.08, to: 0.76)
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: size.lineWidth,
                        lineCap: .round
                    )
                )
                .frame(width: size.diameter, height: size.diameter)
                .rotationEffect(
                    .degrees(lifecycle.rotationDegrees(at: timeline.date))
                )
        }
        .frame(width: size.diameter, height: size.diameter)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("common.loading", fallback: "Loading"))
        .onAppear {
            lifecycle.appear(reduceMotion: reduceMotion)
        }
        .onDisappear {
            lifecycle.disappear()
        }
        .onChange(of: reduceMotion) { newValue in
            lifecycle.updateReduceMotion(newValue)
        }
    }
}

struct AppActivityLabel: View {
    let title: String
    let size: AppActivityIndicator.Size

    init(
        _ title: String,
        size: AppActivityIndicator.Size = .regular
    ) {
        self.title = title
        self.size = size
    }

    var body: some View {
        VStack(spacing: 9) {
            AppActivityIndicator(size: size)
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct VideoGrid: View {
    @Environment(\.imageRepository) private var imageRepository
    @Environment(\.displayScale) private var displayScale
    let items: [VideoSummary]
    let onSelect: (VideoSummary) -> Void
    var initialAnchor: PosterBrowseAnchor?
    var presentationRevision: UInt64
    var onBrowse: (PosterBrowseAnchor, Bool, Bool) -> Void
    @State private var restorationID = UUID()
    @State private var observation = PosterBrowseObservation()
    @State private var selection = PosterSelectionModel()
    @State private var columnCount = 1
    @State private var measuredGridWidth: CGFloat = 0

    private let columns = PosterGridMetrics.columns

    init(items: [VideoSummary], initialAnchor: PosterBrowseAnchor? = nil,
         presentationRevision: UInt64 = 0,
         onBrowse: @escaping (PosterBrowseAnchor, Bool, Bool) -> Void = { _, _, _ in },
         onSelect: @escaping (VideoSummary) -> Void) {
        self.items = items
        self.initialAnchor = initialAnchor
        self.presentationRevision = presentationRevision
        self.onBrowse = onBrowse
        self.onSelect = onSelect
    }

    var body: some View {
        let ids = items.map(\.id)
        let imageGeometry: PosterGridImageGeometry? = measuredGridWidth > 0
            ? PosterGridImageGeometry(gridWidth: measuredGridWidth,
                displayScale: displayScale)
            : nil
        // This token changes when SwiftUI receives a new grid value, including
        // a same-count replacement with different poster URLs. It lets the
        // scroll callback skip plan construction without hashing every item.
        let prefetchSource = PosterPrefetchSource()
        let nativeWidth = max(1, measuredGridWidth)
        let nativeColumns = PosterGridMetrics.columnCount(width: nativeWidth)
        let nativeRows = (items.count + nativeColumns - 1) / nativeColumns
        let nativeHeight = CGFloat(nativeRows) *
            PosterGridMetrics.cardHeight(width: PosterGridMetrics.cardWidth(width: nativeWidth)) +
            CGFloat(max(0, nativeRows - 1)) * PosterGridMetrics.rowSpacing
        ScrollViewReader { proxy in
            Group {
                if PosterNativeGridExperiment.isEnabled {
                    PosterNativeGridExperiment(items: items, gridWidth: nativeWidth,
                        repository: imageRepository, pixels: imageGeometry?.pixels ?? 256,
                        onSelect: onSelect)
                        .frame(height: nativeHeight)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: PosterGridMetrics.rowSpacing) {
                        ForEach(items) { item in
                            SelectablePosterCard(item: item, highlight: selection.highlight(for: item.id),
                                      onHover: { selection.hover(item.id, inside: $0) }) {
                                selection.select(item.id)
                                onSelect(item)
                            }
                            .equatable()
                            .id(item.id)
                        }
                    }
                }
            }
            // The viewport's preheater owns visible priority; a LazyVGrid
            // card may remain mounted well outside the actual clip rect.
            .environment(\.posterCardPriority, .reverse)
            .environment(\.posterCardGeometry, imageGeometry)
            .background {
                BrowserKeyboardSurface(handler: { event in
                    guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
                    if [36, 76].contains(event.keyCode), let item = items.first(where: { $0.id == selection.highlightedID }) {
                        selection.select(item.id)
                        onSelect(item)
                        return true
                    }
                    guard [123, 124, 125, 126].contains(event.keyCode) else { return false }
                    let current = items.firstIndex(where: { $0.id == selection.highlightedID })
                    let firstVisible = min(max(0, items.count - 1), observation.firstVisibleIndex)
                    let next = current == nil ? (items.isEmpty ? nil : firstVisible)
                        : BrowserGridNavigation.destination(index: current, count: items.count, columns: columnCount, key: event.keyCode)
                    guard let next else { return true }
                    selection.select(items[next].id)
                    proxy.scrollTo(items[next].id)
                    return true
                }, onWidth: { width in
                    measuredGridWidth = width
                    columnCount = PosterGridMetrics.columnCount(width: width)
                })
            }
            .onChange(of: ids) { selection.reconcile($0) }
            .onChange(of: presentationRevision) { _ in restorationID = UUID() }
            .background {
                PosterScrollObserver(itemIDs: ids, restoration: .init(id: restorationID, anchor: initialAnchor)) { metrics in
                    let interacted = metrics.interactionRevision != observation.lastInteractionRevision
                    observation.lastInteractionRevision = metrics.interactionRevision
                    if let anchor = PosterBrowseAnchor.capture(ids: ids, metrics: metrics) {
                        onBrowse(anchor, metrics.offset <= 1, interacted)
                    }
                    let width = metrics.regionSize.width
                    let columns = PosterGridMetrics.columnCount(width: width)
                    let stride = PosterGridMetrics.cardHeight(width: PosterGridMetrics.cardWidth(width: width)) + PosterGridMetrics.rowSpacing
                    if let oldOffset = observation.lastOffset {
                        if metrics.offset > oldOffset + 1 { observation.direction = .down }
                        if metrics.offset < oldOffset - 1 { observation.direction = .up }
                    }
                    observation.lastOffset = metrics.offset
                    let visibleTop = max(0, metrics.offset - metrics.regionTop)
                    let visibleBottom = min(metrics.regionSize.height, metrics.offset + metrics.viewport.height - metrics.regionTop)
                    let hasVisibleRows = !items.isEmpty && visibleBottom > visibleTop
                    let maximumRow = max(0, (items.count - 1) / columns)
                    let firstRow = min(maximumRow, max(0, Int(floor(visibleTop / stride))))
                    observation.firstVisibleIndex = firstRow * columns
                    let lastRow = min(maximumRow, max(firstRow, Int(floor(max(0, visibleBottom - 0.5) / stride))))
                    let band = PosterPrefetchBand(firstRow: firstRow, lastRow: lastRow, columns: columns,
                        pixels: PosterImageRequest.bucket(max(0, PosterGridMetrics.cardWidth(width: width) - 16) * 1.5 * displayScale),
                        count: items.count, direction: observation.direction, hasVisibleRows: hasVisibleRows)
                    guard observation.prefetchGate.shouldUpdate(
                        band: band, source: prefetchSource
                    ) else { return }
                    if observation.preheater == nil { observation.preheater = PosterPreheater() }
                    observation.preheater?.update(band.plan(items: items), repository: imageRepository)
                }
            }
            .onDisappear {
                observation.preheater?.cancel()
                observation.prefetchGate.reset()
                observation.lastOffset = nil
                observation.direction = .down
            }
        }
    }
}

/// Isolated Release experiment. The outer SwiftUI scroll view, viewport
/// observer, prefetcher, data, and image repository remain in place. Only the
/// repeated SwiftUI card tree is replaced by reusable AppKit items.
private struct PosterNativeGridExperiment: NSViewRepresentable {
    static let isEnabled = ProcessInfo.processInfo.environment["OKVIDEOMAC_POSTER_NATIVE_GRID_LAB"] == "1"
    let items: [VideoSummary]
    let gridWidth: CGFloat
    let repository: ImageRepository?
    let pixels: Int
    let onSelect: (VideoSummary) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSCollectionView {
        let view = NSCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = PosterGridMetrics.columnSpacing
        layout.minimumLineSpacing = PosterGridMetrics.rowSpacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.collectionViewLayout = layout
        view.backgroundColors = [.clear]
        view.isSelectable = false
        view.register(PosterNativeCardItem.self,
            forItemWithIdentifier: PosterNativeCardItem.reuseIdentifier)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSCollectionView, context: Context) {
        context.coordinator.update(view: view, items: items,
            repository: repository, pixels: pixels, onSelect: onSelect)
        let size = NSSize(
            width: PosterGridMetrics.cardWidth(width: gridWidth),
            height: PosterGridMetrics.cardHeight(width:
                PosterGridMetrics.cardWidth(width: gridWidth))
        )
        if let layout = view.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private var items: [VideoSummary] = []
        private var repository: ImageRepository?
        private var pixels = 256
        private var onSelect: (VideoSummary) -> Void = { _ in }

        func update(view: NSCollectionView, items: [VideoSummary],
                    repository: ImageRepository?, pixels: Int,
                    onSelect: @escaping (VideoSummary) -> Void) {
            self.onSelect = onSelect
            guard self.items != items || self.repository !== repository ||
                  self.pixels != pixels else { return }
            self.items = items
            self.repository = repository
            self.pixels = pixels
            view.reloadData()
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: PosterNativeCardItem.reuseIdentifier,
                for: indexPath
            ) as! PosterNativeCardItem
            let index = indexPath.item
            item.bind(summary: items[index], repository: repository,
                pixels: pixels) { [weak self] in
                guard let self, index < self.items.count else { return }
                self.onSelect(self.items[index])
            }
            return item
        }
    }
}

struct PosterNativeHeaderKey: Hashable {
    let categories: [VideoCategory]
    let selectedCategoryID: String?
    let showsRecommendations: Bool
    let filterSelection: [String: String]
    var navigationItems: [BrowseCategoryNavigationItem]? = nil
    var navigationSelectedID: String? = nil
}

struct PosterNativeFooterKey: Hashable {
    let hasMore: Bool
    let isLoading: Bool
    let isRefreshing: Bool
    let errorMessage: String?
    let itemCount: Int
    var hasPendingUpdate: Bool
    var issueKind: CategoryPaginationIssueKind = .failed
    var statusText: String? = nil
    var actionTitle: String? = nil
    var automaticLoading = true
}

/// A default NSScrollView owns the native poster grid. Collection items are
/// reused, while the category bar and footer remain fixed-size document views.
struct PosterNativeCardPresentation: Equatable {
    let id: String
    let subtitle: String
    let sources: [VideoSummary]
}

struct PosterNativePage: NSViewRepresentable {
    @Environment(\.imageRepository) private var repository
    @Environment(\.displayScale) private var displayScale
    @Environment(\.browserToolbarScrollReporter) private var reportScroll
    let items: [VideoSummary]
    let headerKey: PosterNativeHeaderKey
    let headerHeight: CGFloat
    let activeFilters: [HomeActiveFilterToken]
    let footerKey: PosterNativeFooterKey
    let nextPage: Int
    let initialAnchor: PosterBrowseAnchor?
    let presentationRevision: UInt64
    let onCategorySelect: (String?) -> Void
    let onFilterReset: (String) -> Void
    let onClearFilters: () -> Void
    let onAcceptUpdate: () -> Void
    let onBrowse: (PosterBrowseAnchor, Bool, Bool) -> Void
    let onLoad: () async -> Bool
    let onSelect: (VideoSummary) -> Void
    var cardPresentations: [PosterNativeCardPresentation]? = nil
    var onSelectSource: ((VideoSummary) -> Void)? = nil
    var onManualLoad: (() async -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PosterNativePageScrollView {
        let scroll = PosterNativePageScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let collection = PosterNativePageCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = PosterGridMetrics.columnSpacing
        layout.minimumLineSpacing = PosterGridMetrics.rowSpacing
        layout.sectionInset = NSEdgeInsets(top: HomeBrowseGridMetrics.contentPadding,
            left: HomeBrowseGridMetrics.contentPadding,
            bottom: HomeBrowseGridMetrics.contentPadding,
            right: HomeBrowseGridMetrics.contentPadding)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.register(PosterNativeCardItem.self,
            forItemWithIdentifier: PosterNativeCardItem.reuseIdentifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        scroll.documentView = collection
        context.coordinator.attach(scroll: scroll, collection: collection)
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateLayout()
            coordinator?.scheduleViewportChanged()
        }
        return scroll
    }

    func updateNSView(_ view: PosterNativePageScrollView, context: Context) {
        context.coordinator.update(items: items, repository: repository,
            displayScale: displayScale, headerKey: headerKey,
            headerHeight: headerHeight, activeFilters: activeFilters,
            footerKey: footerKey,
            nextPage: nextPage, initialAnchor: initialAnchor,
            presentationRevision: presentationRevision,
            onCategorySelect: onCategorySelect,
            onFilterReset: onFilterReset,
            onClearFilters: onClearFilters,
            onAcceptUpdate: onAcceptUpdate,
            reportScroll: reportScroll, onBrowse: onBrowse, onLoad: onLoad,
            onSelect: onSelect, cardPresentations: cardPresentations, onSelectSource: onSelectSource, onManualLoad: onManualLoad)
    }

    static func dismantleNSView(_ view: PosterNativePageScrollView,
                                coordinator: Coordinator) {
        view.onLayout = nil
        // SwiftUI may retain an outgoing representable through its render
        // transaction. Remove its native document immediately so old search
        // cards cannot remain above the incoming detail/loading surface.
        view.isHidden = true
        coordinator.detach()
        view.documentView = nil
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private weak var scroll: PosterNativePageScrollView?
        private weak var collection: PosterNativePageCollectionView?
        private let headerView = PosterNativeCategoryHeaderView(frame: .zero)
        private let footerView = PosterNativePageFooterView(frame: .zero)
        private var items: [VideoSummary] = []
        private var cardPresentations: [PosterNativeCardPresentation]?
        private var itemIDs: [String] { cardPresentations?.map(\.id) ?? items.map(\.id) }
        private var onSelectSource: ((VideoSummary) -> Void)?
        private var repository: ImageRepository?
        private var displayScale: CGFloat = 1
        private var pixels = 256
        private var headerKey: PosterNativeHeaderKey?
        private var headerHeight: CGFloat = 0
        private var activeFilters: [HomeActiveFilterToken] = []
        private var footerKey: PosterNativeFooterKey?
        private var nextPage = 2
        private var onCategorySelect: (String?) -> Void = { _ in }
        private var onFilterReset: (String) -> Void = { _ in }
        private var onClearFilters: () -> Void = {}
        private var onAcceptUpdate: () -> Void = {}
        private var reportScroll: (Bool) -> Void = { _ in }
        private var onBrowse: (PosterBrowseAnchor, Bool, Bool) -> Void = { _, _, _ in }
        private var onLoad: () async -> Bool = { false }
        private var onManualLoad: (() async -> Bool)?
        private var onSelect: (VideoSummary) -> Void = { _ in }
        private var lastWidth: CGFloat = 0
        private var lastScrolledState: Bool?
        private var lastReportedInteraction: UInt64 = 0
        private var interactionRevision: UInt64 = 0
        private var restorationRevision: UInt64?
        private var pendingRestoration: (anchor: PosterBrowseAnchor?, generation: UInt64)?
        private var observations: [NSObjectProtocol] = []
        private var inputMonitor: Any?
        private var prefetchSource = PosterPrefetchSource()
        private var prefetchGate = PosterPrefetchPlanGate()
        private var preheater = PosterPreheater()
        private var paginationDemand = PosterPaginationDemand()
        private var viewportUpdatePending = false
        private var lastOffset: CGFloat?
        private var direction: PosterScrollDirection = .down
        private var highlightedID: String?

        func attach(scroll: PosterNativePageScrollView,
                    collection: PosterNativePageCollectionView) {
            self.scroll = scroll
            self.collection = collection
            collection.addSubview(headerView)
            collection.addSubview(footerView)
            headerView.setAccessibilityElement(true)
            headerView.setAccessibilityRole(.group)
            footerView.setAccessibilityElement(true)
            footerView.setAccessibilityRole(.group)
            collection.extraAccessibilityChildren = [headerView, footerView]
            collection.handleKey = { [weak self] event in
                self?.handleKey(event) ?? false
            }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main
            ) { [weak self] _ in self?.scheduleViewportChanged() })
        }

        func detach() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            preheater.cancel()
            reportScroll(false)
            scroll?.resetBrowserHover()
            collection?.dataSource = nil
            collection?.delegate = nil
            collection?.extraAccessibilityChildren = []
            collection?.handleKey = nil
            collection = nil
            scroll = nil
        }

        func update(items: [VideoSummary], repository: ImageRepository?,
                    displayScale: CGFloat,
                    headerKey: PosterNativeHeaderKey,
                    headerHeight: CGFloat,
                    activeFilters: [HomeActiveFilterToken],
                    footerKey: PosterNativeFooterKey, nextPage: Int,
                    initialAnchor: PosterBrowseAnchor?,
                    presentationRevision: UInt64,
                    onCategorySelect: @escaping (String?) -> Void,
                    onFilterReset: @escaping (String) -> Void,
                    onClearFilters: @escaping () -> Void,
                    onAcceptUpdate: @escaping () -> Void,
                    reportScroll: @escaping (Bool) -> Void,
                    onBrowse: @escaping (PosterBrowseAnchor, Bool, Bool) -> Void,
                    onLoad: @escaping () async -> Bool,
                    onSelect: @escaping (VideoSummary) -> Void,
                    cardPresentations: [PosterNativeCardPresentation]?,
                    onSelectSource: ((VideoSummary) -> Void)?,
                    onManualLoad: (() async -> Bool)?) {
            self.reportScroll = reportScroll
            self.onBrowse = onBrowse
            self.onLoad = onLoad
            self.onManualLoad = onManualLoad
            self.onSelect = onSelect
            self.nextPage = nextPage
            self.onCategorySelect = onCategorySelect
            self.onFilterReset = onFilterReset
            self.onClearFilters = onClearFilters
            self.onAcceptUpdate = onAcceptUpdate
            let headerChanged = self.headerKey != headerKey
            let footerChanged = self.footerKey != footerKey
            self.headerKey = headerKey
            self.footerKey = footerKey
            self.headerHeight = headerHeight
            headerView.isHidden = headerHeight < HomeBrowseGridMetrics.categoryRowHeight
            self.activeFilters = activeFilters
            if headerChanged { configureHeader(headerView) }
            if footerChanged { footerView.isHidden = true }
            if restorationRevision != presentationRevision {
                restorationRevision = presentationRevision
                pendingRestoration = (initialAnchor, interactionRevision)
            }
            let oldIDs = itemIDs
            let presentationsChanged = self.cardPresentations != cardPresentations
            self.cardPresentations = cardPresentations
            self.onSelectSource = onSelectSource
            let oldItems = self.items
            let contentChanged = oldItems != items
            let imageSourceChanged = self.repository !== repository ||
                self.displayScale != displayScale
            self.items = items
            if let highlightedID, !itemIDs.contains(highlightedID) {
                self.highlightedID = nil
            }
            self.repository = repository
            self.displayScale = displayScale
            if contentChanged || imageSourceChanged {
                prefetchSource = PosterPrefetchSource()
                prefetchGate.reset()
            }
            let appending = contentChanged && !oldItems.isEmpty &&
                !imageSourceChanged && items.count > oldItems.count &&
                Array(items.prefix(oldItems.count)) == oldItems
            if appending, let collection {
                let paths = Set((oldItems.count..<items.count).map {
                    IndexPath(item: $0, section: 0)
                })
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    collection.insertItems(at: paths)
                }
                updateLayout()
            } else {
                updateLayout()
                if imageSourceChanged || oldIDs != itemIDs {
                    collection?.reloadData()
                } else if contentChanged || presentationsChanged, let collection {
                    for path in collection.indexPathsForVisibleItems() {
                        if let card = collection.item(at: path) as? PosterNativeCardItem {
                            bind(card, at: path.item)
                        }
                    }
                }
            }
            installInputMonitor()
            scheduleViewportChanged()
        }

        func updateLayout() {
            guard let scroll, let collection,
                  let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let width = max(1, scroll.contentSize.width)
            let gridWidth = max(1, width - 2 * HomeBrowseGridMetrics.contentPadding)
            let cardWidth = PosterGridMetrics.cardWidth(width: gridWidth)
            let itemSize = NSSize(width: cardWidth,
                height: PosterGridMetrics.cardHeight(width: cardWidth, showsSubtitle: cardPresentations != nil))
            let columns = PosterGridMetrics.columnCount(width: gridWidth)
            let rows = (items.count + columns - 1) / columns
            let gridHeight = CGFloat(rows) * itemSize.height +
                CGFloat(max(0, rows - 1)) * PosterGridMetrics.rowSpacing
            let footerGap: CGFloat = 0
            let bottomPadding = HomeBrowseGridMetrics.contentPadding
            let height = max(scroll.contentSize.height,
                headerHeight + gridHeight + bottomPadding)
            let newPixels = PosterImageRequest.bucket(max(0, cardWidth - 2 * PosterGridMetrics.inset) *
                1.5 * displayScale)
            let changedPixels = pixels != newPixels
            pixels = newPixels
            let insets = NSEdgeInsets(top: headerHeight,
                left: HomeBrowseGridMetrics.contentPadding,
                bottom: bottomPadding,
                right: HomeBrowseGridMetrics.contentPadding)
            guard abs(width - lastWidth) > 0.5 ||
                  layout.itemSize != itemSize ||
                  layout.sectionInset.top != insets.top ||
                  layout.sectionInset.left != insets.left ||
                  layout.sectionInset.bottom != insets.bottom ||
                  layout.sectionInset.right != insets.right ||
                  abs(collection.frame.height - height) > 0.5 ||
                  abs(footerView.frame.minY - (headerHeight + gridHeight + footerGap)) > 0.5 ||
                  changedPixels else {
                applyPendingRestoration()
                return
            }
            lastWidth = width
            layout.itemSize = itemSize
            layout.sectionInset = insets
            collection.frame = NSRect(x: 0, y: 0, width: width, height: height)
            headerView.frame = NSRect(x: 0, y: 0,
                width: width, height: headerHeight)
            footerView.frame = NSRect(x: 0,
                y: headerHeight + gridHeight + footerGap,
                width: width, height: 0)
            layout.invalidateLayout()
            if changedPixels, !items.isEmpty { collection.reloadData() }
            applyPendingRestoration()
        }

        private func installInputMonitor() {
            guard inputMonitor == nil else { return }
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .keyDown, .leftMouseDown]
            ) { [weak self] event in
                guard let self, let scroll = self.scroll,
                      event.window === scroll.window else { return event }
                let inside: Bool
                if event.type == .keyDown {
                    inside = (scroll.window?.firstResponder as? NSView)?
                        .isDescendant(of: scroll) == true
                } else {
                    inside = scroll.bounds.contains(
                        scroll.convert(event.locationInWindow, from: nil))
                }
                if inside { self.interactionRevision &+= 1 }
                return event
            }
        }

        private func applyPendingRestoration() {
            guard let pendingRestoration, let scroll, let collection,
                  collection.bounds.width > 1, !items.isEmpty else { return }
            self.pendingRestoration = nil
            guard pendingRestoration.generation == interactionRevision else { return }
            let clip = scroll.contentView
            let gridWidth = max(1, collection.bounds.width -
                2 * HomeBrowseGridMetrics.contentPadding)
            let ids = itemIDs
            let target = pendingRestoration.anchor?.targetOffset(
                ids: ids, width: gridWidth, regionTop: headerHeight, showsSubtitle: cardPresentations != nil
            ) ?? 0
            let maximum = max(0, collection.bounds.height -
                clip.bounds.height + scroll.contentInsets.top +
                scroll.contentInsets.bottom)
            let logical = min(max(0, target), maximum)
            let y = collection.bounds.minY + logical -
                scroll.contentInsets.top
            if abs(clip.bounds.minY - y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
            }
        }

        // Bounds notifications can arrive inside layout/resize. Sample one
        // settled geometry snapshot on the next main-loop turn, never publish
        // or request recursively from NSScrollView.layout.
        func scheduleViewportChanged() {
            guard !viewportUpdatePending else { return }
            viewportUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewportUpdatePending = false
                guard self.scroll?.window != nil else { return }
                self.scroll?.layoutSubtreeIfNeeded()
                self.updateLayout()
                self.collection?.layoutSubtreeIfNeeded()
                self.viewportChanged()
            }
        }

        private func loadNextPage(manual: Bool = false) {
            let page = nextPage
            let load = manual ? (onManualLoad ?? onLoad) : onLoad
            Task { @MainActor [weak self] in
                let succeeded = await load()
                guard let self else { return }
                self.paginationDemand.finish(page: page)
                // Rejection/cancellation frees the slot for the next viewport
                // event but does not spin retry tasks without a state change.
                if succeeded { self.scheduleViewportChanged() }
            }
        }

        private func manuallyLoadNextPage() {
            guard paginationDemand.begin(page: nextPage) else { return }
            loadNextPage(manual: true)
        }

        private func viewportChanged() {
            guard let scroll, let collection, !items.isEmpty,
                  collection.bounds.width > 1 else { return }
            let clip = scroll.contentView
            let offset = max(0, clip.bounds.minY -
                collection.bounds.minY + scroll.contentInsets.top)
            let scrolled = offset > 0.5
            if lastScrolledState != scrolled {
                lastScrolledState = scrolled
                reportScroll(scrolled)
            }
            let width = max(1, collection.bounds.width -
                2 * HomeBrowseGridMetrics.contentPadding)
            let columns = PosterGridMetrics.columnCount(width: width)
            let cardWidth = PosterGridMetrics.cardWidth(width: width)
            let stride = PosterGridMetrics.cardHeight(width: cardWidth, showsSubtitle: cardPresentations != nil) +
                PosterGridMetrics.rowSpacing
            let rows = (items.count + columns - 1) / columns
            let gridHeight = CGFloat(rows) * stride -
                (rows > 0 ? PosterGridMetrics.rowSpacing : 0)
            let metrics = PosterScrollMetrics(
                offset: offset, viewport: clip.bounds.size,
                regionTop: headerHeight,
                regionSize: CGSize(width: width, height: gridHeight),
                interactionRevision: interactionRevision)
            if let anchor = PosterBrowseAnchor.capture(
                ids: itemIDs, metrics: metrics, showsSubtitle: cardPresentations != nil
            ) {
                let interacted = interactionRevision != lastReportedInteraction
                lastReportedInteraction = interactionRevision
                onBrowse(anchor, !scrolled, interacted)
            }
            if let lastOffset {
                if offset > lastOffset + 1 { direction = .down }
                if offset < lastOffset - 1 { direction = .up }
            }
            lastOffset = offset
            let visibleTop = max(0, offset - headerHeight)
            let visibleBottom = min(gridHeight,
                offset + clip.bounds.height - headerHeight)
            let firstRow = min(max(0, rows - 1),
                max(0, Int(floor(visibleTop / stride))))
            let lastRow = min(max(0, rows - 1),
                max(firstRow, Int(floor(max(0, visibleBottom - 0.5) / stride))))
            let band = PosterPrefetchBand(
                firstRow: firstRow, lastRow: lastRow,
                columns: columns, pixels: pixels, count: items.count,
                direction: direction,
                hasVisibleRows: visibleBottom > visibleTop)
            if prefetchGate.shouldUpdate(
                band: band, source: prefetchSource
            ) {
                preheater.update(band.plan(items: items),
                    repository: repository)
            }
            let footerTop = headerHeight + gridHeight
            let footerMetrics = PosterScrollMetrics(
                offset: offset, viewport: clip.bounds.size,
                regionTop: footerTop,
                regionSize: CGSize(width: width,
                    height: 1),
                interactionRevision: interactionRevision)
            let eligible = footerKey?.automaticLoading == true &&
                footerKey?.hasMore == true &&
                footerKey?.isLoading == false &&
                footerKey?.isRefreshing == false &&
                (footerKey?.hasPendingUpdate == false || footerKey?.statusText != nil) &&
                (footerKey?.statusText != nil || footerKey?.errorMessage == nil)
            if paginationDemand.requestIfNeeded(
                metrics: footerMetrics, nextPage: nextPage,
                eligible: eligible
            ) { loadNextPage() }
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(
                [.command, .option, .control, .shift]
            ).isEmpty, let collection, !items.isEmpty else { return false }
            if [36, 76].contains(event.keyCode) {
                guard let highlightedID,
                      let index = itemIDs.firstIndex(of: highlightedID)
                else { return false }
                onSelect(items[index])
                return true
            }
            guard [123, 124, 125, 126].contains(event.keyCode) else {
                return false
            }
            let current = highlightedID.flatMap { id in
                itemIDs.firstIndex(of: id)
            }
            let firstVisible = collection.indexPathsForVisibleItems()
                .map(\.item).min() ?? 0
            let columns = PosterGridMetrics.columnCount(
                width: max(1, collection.bounds.width -
                    2 * HomeBrowseGridMetrics.contentPadding))
            let next = current == nil ? firstVisible :
                BrowserGridNavigation.destination(
                    index: current, count: items.count,
                    columns: columns, key: event.keyCode)
            guard let next, items.indices.contains(next) else { return true }
            highlightedID = itemIDs[next]
            for path in collection.indexPathsForVisibleItems() {
                (collection.item(at: path) as? PosterNativeCardItem)?
                    .setKeyboardHighlighted(path.item == next)
            }
            if let attributes = collection.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: next, section: 0)),
               !collection.visibleRect.contains(attributes.frame) {
                collection.scrollToVisible(attributes.frame)
            }
            return true
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: PosterNativeCardItem.reuseIdentifier,
                for: indexPath
            ) as! PosterNativeCardItem
            bind(item, at: indexPath.item)
            return item
        }

        private func bind(_ item: PosterNativeCardItem, at index: Int) {
            guard items.indices.contains(index) else { return }
            let id = itemIDs[index]
            item.bind(summary: items[index], repository: repository, pixels: pixels) { [weak self] in
                guard let self, let current = self.itemIDs.firstIndex(of: id) else { return }
                self.onSelect(self.items[current])
            }
            item.present(cardPresentations?[index], onSelectSource: onSelectSource)
            item.setKeyboardHighlighted(id == highlightedID)
        }


        private func configureHeader(_ view: PosterNativeCategoryHeaderView?) {
            guard let view, let headerKey else { return }
            view.configure(
                key: headerKey, filters: activeFilters,
                onCategorySelect: { [weak self] id in
                    self?.onCategorySelect(id)
                },
                onFilterReset: { [weak self] id in
                    self?.onFilterReset(id)
                },
                onClearFilters: { [weak self] in
                    self?.onClearFilters()
                })
        }

        private func configureFooter(_ view: PosterNativePageFooterView?) {
            guard let view, let footerKey else { return }
            view.configure(
                key: footerKey,
                onAcceptUpdate: { [weak self] in self?.onAcceptUpdate() },
                onLoad: { [weak self] in self?.manuallyLoadNextPage() })
        }
    }
}

/// AppKit counterpart of HomeCategoryNavigation. No hosting view or scroll view
/// is introduced into the collection's layout path.
struct BrowseCategoryNavigationItem: Hashable, Identifiable {
    let id: String
    let title: String
    let selectionValue: String?
    var help: String? = nil

    init(id: String, title: String, selectionValue: String?, help: String? = nil) {
        self.id = id; self.title = title; self.selectionValue = selectionValue; self.help = help
    }
    init(id: String, title: String, categoryID: String?) {
        self.init(id: id, title: title, selectionValue: categoryID)
    }
}

/// Shared by the SwiftUI recommendation/loading/empty branch and AppKit grids.
/// AppKit owns drawing, focus, hit testing and selection feedback.
final class NativeBrowseCategoryNavigation: NSView {
    private var items: [BrowseCategoryNavigationItem] = []
    private var selectedID: String?
    private var onSelect: (String?) -> Void = { _ in }
    let segments = NSSegmentedControl(frame: .zero)
    let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var lastWidth: CGFloat?
    private var contentWidths: [String: CGFloat] = [:]
    private var segmentExtra: CGFloat = 0
    private var outerExtra: CGFloat = 0
    private var moreWidth: CGFloat = 0
    private var renderedIDs: [String] = []
    private var menuDirty = true
    private(set) var partition = HomeCategoryNavigationPartition(visibleIDs: [], hiddenIDs: [])
    private let gap: CGFloat = 6
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        segments.segmentStyle = .automatic
        segments.trackingMode = .selectOne
        segments.controlSize = .large
        segments.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        segments.target = self
        segments.action = #selector(selectSegment(_:))
        segments.setAccessibilityLabel(L10n.string("video.category-navigation", fallback: "Category Navigation"))
        more.bezelStyle = .rounded
        more.controlSize = .large
        more.identifier = NSUserInterfaceItemIdentifier("home.categories.more")
        more.addItem(withTitle: L10n.string("common.more", fallback: "More"))
        moreWidth = max(66, more.fittingSize.width)
        more.isHidden = true
        addSubview(segments)
        addSubview(more)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: HomeBrowseGridMetrics.categoryRowHeight)
    }

    func configure(items: [BrowseCategoryNavigationItem], selectedID: String?,
                   onSelect: @escaping (String?) -> Void) {
        // Also defend the shared native control: search/custom navigation can
        // reach it without going through SiteHome's provider normalization.
        var seen = Set<String>()
        let items = items.filter { seen.insert($0.id).inserted }
        self.onSelect = onSelect
        guard self.items != items || self.selectedID != selectedID else { return }
        if self.items != items {
            self.items = items
            contentWidths = items.reduce(into: [:]) { widths, item in
                widths[item.id] = max(62, ceil((item.title as NSString).size(withAttributes: [
                    .font: segments.font ?? NSFont.systemFont(ofSize: 13)
                ]).width) + 28)
            }
            // Measure the system's endcaps/separators; don't assume the custom
            // SwiftUI chrome's inset applies to NSSegmentedControl.
            let probe = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
            probe.segmentStyle = segments.segmentStyle
            probe.controlSize = segments.controlSize
            probe.setWidth(80, forSegment: 0)
            probe.setWidth(80, forSegment: 1)
            let two = probe.fittingSize.width
            probe.segmentCount = 1
            let one = probe.fittingSize.width
            segmentExtra = max(0, two - one - 80)
            outerExtra = max(0, one - 80 - segmentExtra)
            renderedIDs = []
        }
        self.selectedID = selectedID
        menuDirty = true
        lastWidth = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard lastWidth != bounds.width else { return }
        lastWidth = bounds.width
        let available = max(0, bounds.width)
        let next = HomeCategoryNavigationLayoutPolicy.partition(
            candidates: items.map { .init(id: $0.id, width: (contentWidths[$0.id] ?? 62) + segmentExtra) },
            selectedID: selectedID, availableWidth: available,
            spacing: 0, containerInset: outerExtra / 2, moreWidth: moreWidth + gap)
        let changed = next != partition
        partition = next
        let hasMore = !partition.hiddenIDs.isEmpty
        segments.isHidden = partition.visibleIDs.isEmpty
        more.isHidden = !hasMore
        if renderedIDs != partition.visibleIDs || segments.segmentCount != partition.visibleIDs.count {
            renderedIDs = partition.visibleIDs
            segments.segmentCount = renderedIDs.count
            for (index, id) in renderedIDs.enumerated() {
                let title = items.first { $0.id == id }?.title ?? ""
                segments.setLabel(title, forSegment: index)
                segments.setToolTip(items.first { $0.id == id }?.help ?? title, forSegment: index)
            }
        }
        let budget = max(0, available - (hasMore ? moreWidth + gap : 0) - outerExtra)
        for (index, id) in renderedIDs.enumerated() {
            segments.setWidth(max(1, min(contentWidths[id] ?? 62, budget - segmentExtra)), forSegment: index)
        }
        let selected = renderedIDs.firstIndex { $0 == selectedID } ?? -1
        if segments.selectedSegment != selected { segments.selectedSegment = selected }
        let size = segments.fittingSize
        segments.frame = NSRect(x: 0, y: floor((bounds.height - size.height) / 2),
            width: min(available, size.width), height: size.height)
        let popupHeight = more.fittingSize.height
        more.frame = NSRect(x: min(available, segments.frame.maxX + gap),
            y: floor((bounds.height - popupHeight) / 2),
            width: min(moreWidth, max(0, available - segments.frame.maxX - gap)), height: popupHeight)
        if changed || menuDirty {
            more.menu = makeOverflowMenu()
            more.toolTip = L10n.string("home.categories.more", fallback: "Show %d more categories", partition.hiddenIDs.count)
            menuDirty = false
        }
    }

    func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        // A pull-down menu's first item is its button title, not a choice.
        menu.addItem(withTitle: L10n.string("common.more", fallback: "More"), action: nil, keyEquivalent: "")
        if let selected = items.first(where: { $0.id == selectedID }) {
            menu.addItem(menuItem(selected, selected: true))
            if !partition.hiddenIDs.isEmpty { menu.addItem(.separator()) }
        }
        for id in partition.hiddenIDs {
            if let item = items.first(where: { $0.id == id }) {
                menu.addItem(menuItem(item, selected: false))
            }
        }
        return menu
    }
    private func menuItem(_ item: BrowseCategoryNavigationItem, selected: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: item.title, action: #selector(selectMenuCategory(_:)), keyEquivalent: "")
        entry.target = self
        entry.toolTip = item.help
        entry.representedObject = item.id
        entry.state = selected ? .on : .off
        return entry
    }
    private func select(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        onSelect(item.selectionValue)
    }
    @objc private func selectSegment(_ sender: NSSegmentedControl) {
        guard renderedIDs.indices.contains(sender.selectedSegment) else { return }
        select(renderedIDs[sender.selectedSegment])
    }
    @objc private func selectMenuCategory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        select(id)
    }
}

struct NativeBrowseCategoryNavigationRepresentable: NSViewRepresentable {
    let items: [BrowseCategoryNavigationItem]
    let selectedID: String?
    let onSelect: (String?) -> Void
    func makeNSView(context: Context) -> NativeBrowseCategoryNavigation {
        NativeBrowseCategoryNavigation(frame: .zero)
    }
    func updateNSView(_ view: NativeBrowseCategoryNavigation, context: Context) {
        view.configure(items: items, selectedID: selectedID, onSelect: onSelect)
    }
}

/// Native chrome avoids keeping a SwiftUI hosting graph inside the collection
/// layout path. Categories use a bounded strip with a native overflow menu.
private final class PosterNativeCategoryHeaderView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PosterNativeCategoryHeader")
    private let tabs = NativeBrowseCategoryNavigation(frame: .zero)
    private let filters = NSScrollView(frame: .zero)
    private let filterDocument = NSView(frame: .zero)
    private let divider = NSBox(frame: .zero)
    private var key: PosterNativeHeaderKey?
    private var tokens: [HomeActiveFilterToken] = []
    private var categoryAction: (String?) -> Void = { _ in }
    private var filterAction: (String) -> Void = { _ in }
    private var clearAction: () -> Void = {}
    private var filterIDs: [NSButton: String] = [:]
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureBase()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBase()
    }

    private func configureBase() {
        addSubview(tabs)
        for (scroll, document) in [(filters, filterDocument)] {
            scroll.documentView = document
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
            scroll.horizontalScrollElasticity = .automatic
            addSubview(scroll)
        }
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = NSColor.separatorColor.withAlphaComponent(NSColor.separatorColor.alphaComponent * 0.28)
        addSubview(divider)
    }

    func configure(
        key: PosterNativeHeaderKey,
        filters: [HomeActiveFilterToken],
        onCategorySelect: @escaping (String?) -> Void,
        onFilterReset: @escaping (String) -> Void,
        onClearFilters: @escaping () -> Void
    ) {
        categoryAction = onCategorySelect
        filterAction = onFilterReset
        clearAction = onClearFilters
        guard self.key != key || tokens != filters else { return }
        self.key = key
        tokens = filters
        rebuild()
    }

    private func rebuild() {
        filterDocument.subviews.forEach { $0.removeFromSuperview() }
        filterIDs.removeAll(keepingCapacity: true)
        guard let key else { return }
        let categories = HomeCategoryNavigationLayoutPolicy.items(
            categories: key.categories, showsRecommendations: key.showsRecommendations)
        tabs.configure(items: key.navigationItems ?? categories,
            selectedID: key.navigationItems != nil ? key.navigationSelectedID :
                (key.selectedCategoryID.map { HomeCategoryNavigationLayoutPolicy.navigationID(for: $0) }
                    ?? (key.showsRecommendations ? HomeCategoryNavigationLayoutPolicy.recommendationID : nil)),
            onSelect: { [weak self] in self?.categoryAction($0) })
        var filterX: CGFloat = 0
        for token in tokens {
            let text = L10n.string("home.filter.token", fallback: "%@: %@",
                token.filterName, token.optionName) + "  ×"
            let button = NSButton(title: text, target: self,
                action: #selector(resetFilter(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = L10n.string("home.filter.remove",
                fallback: "Remove filter: %@, %@",
                token.filterName, token.optionName)
            let width = min(240, max(90, button.fittingSize.width + 8))
            button.frame = NSRect(x: filterX, y: 0,
                width: width, height: HomeBrowseGridMetrics.chipHeight)
            filterDocument.addSubview(button)
            filterIDs[button] = token.filterID
            filterX += width + 8
        }
        if !tokens.isEmpty {
            let clear = NSButton(title: L10n.string("home.filter.clear",
                fallback: "Clear Filters"), target: self,
                action: #selector(clearFilters))
            clear.bezelStyle = .inline
            clear.font = .systemFont(ofSize: 11)
            let width = max(75, clear.fittingSize.width + 8)
            clear.frame = NSRect(x: filterX, y: 0, width: width,
                height: HomeBrowseGridMetrics.chipHeight)
            filterDocument.addSubview(clear)
            filterX += width
        }
        filterDocument.frame = NSRect(x: 0, y: 0,
            width: max(1, filterX),
            height: HomeBrowseGridMetrics.chipHeight)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = HomeBrowseGridMetrics.contentPadding
        let leading = HomeBrowseGridMetrics.categoryLeadingInset
        tabs.frame = NSRect(x: inset + leading, y: 0,
            width: max(0, bounds.width - inset * 2 - leading - 8),
            height: HomeBrowseGridMetrics.categoryRowHeight)
        divider.frame = NSRect(x: inset, y: HomeBrowseGridMetrics.categoryRowHeight,
            width: max(0, bounds.width - inset * 2), height: HomeBrowseGridMetrics.dividerHeight)
        filters.frame = NSRect(x: inset, y: HomeBrowseGridMetrics.headerHeight(hasFilters: false),
            width: max(0, bounds.width - inset * 2),
            height: tokens.isEmpty ? 0 : HomeBrowseGridMetrics.chipHeight)
    }

    @objc private func resetFilter(_ sender: NSButton) {
        guard let id = filterIDs[sender] else { return }
        filterAction(id)
    }
    @objc private func clearFilters() { clearAction() }
}

private final class PosterNativePageFooterView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PosterNativePageFooter")
    private var key: PosterNativeFooterKey?
    private var loadAction: () -> Void = {}
    private var acceptAction: () -> Void = {}
    private var detailsPopover: NSPopover?
    override var isFlipped: Bool { true }

    func configure(key: PosterNativeFooterKey,
                   onAcceptUpdate: @escaping () -> Void,
                   onLoad: @escaping () -> Void) {
        acceptAction = onAcceptUpdate
        loadAction = onLoad
        guard self.key != key else { return }
        self.key = key
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let key else { return }
        var views: [NSView] = []
        if let status = key.statusText {
            if key.isLoading {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                views.append(spinner)
            }
            views.append(label(status))
            if let title = key.actionTitle, !key.isLoading {
                views.append(button(title, action: #selector(load)))
            }
            if key.errorMessage != nil {
                views.append(button(L10n.string("settings.common.details", fallback: "Details"), action: #selector(showDetails(_:))))
            }
        } else if key.hasPendingUpdate {
            views.append(button(L10n.string("home.category.view-update",
                fallback: "Content Updated — View"),
                action: #selector(acceptUpdate)))
        } else {
            switch HomePaginationPhase.resolve(
                hasMore: key.hasMore, loading: key.isLoading,
                refreshing: key.isRefreshing, error: key.errorMessage, issueKind: key.issueKind
            ) {
            case .loading, .refreshing:
                let spinner = NSProgressIndicator(frame: .zero)
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                views.append(spinner)
                views.append(label(key.isRefreshing
                    ? L10n.string("common.updating", fallback: "Updating…")
                    : L10n.string("pagination.loading", fallback: "Loading the next page")))
            case .failed, .uncertain:
                views.append(label(key.issueKind == .uncertain
                    ? L10n.string("pagination.uncertain", fallback: "No new titles; the end of results is not confirmed")
                    : L10n.string("pagination.failed", fallback: "The next page could not be loaded")))
                views.append(button(L10n.string("common.retry",
                    fallback: "Try Again"), action: #selector(load)))
                views.append(button(L10n.string("settings.common.details",
                    fallback: "Details"), action: #selector(showDetails(_:))))
            case .complete:
                views.append(label(L10n.string("pagination.complete",
                    fallback: "All %d items loaded", key.itemCount)))
            case .idle:
                views.append(button(L10n.string("pagination.continue",
                    fallback: "Continue Loading"), action: #selector(load)))
            }
        }
        views.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let spacing: CGFloat = 8
        let widths = subviews.map { min(350, max(16, $0.fittingSize.width)) }
        let total = widths.reduce(0, +) +
            CGFloat(max(0, widths.count - 1)) * spacing
        var x = max(0, (bounds.width - total) / 2)
        for (view, width) in zip(subviews, widths) {
            view.frame = NSRect(x: x, y: 9,
                width: width, height: 26)
            x += width + spacing
        }
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11)
        return button
    }
    @objc private func load() { loadAction() }
    @objc private func acceptUpdate() { acceptAction() }
    @objc private func showDetails(_ sender: NSButton) {
        guard let message = key?.errorMessage else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0,
            width: 340, height: 110))
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 12, y: 12,
            width: 316, height: 86)
        content.addSubview(label)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender,
            preferredEdge: .maxY)
        detailsPopover = popover
    }
}

final class PosterNativePageCollectionView: NSCollectionView {
    var extraAccessibilityChildren: [NSView] = []
    var handleKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func accessibilityChildren() -> [Any]? {
        guard extraAccessibilityChildren.count == 2 else {
            return super.accessibilityChildren()
        }
        return [extraAccessibilityChildren[0]] +
            (super.accessibilityChildren() ?? []) +
            [extraAccessibilityChildren[1]]
    }
}

final class PosterNativePageScrollView: BrowserHoverScrollView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class PosterNativeCardItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PosterNativeCardExperiment")

    override func loadView() {
        view = PosterNativeCardView()
    }

    func bind(summary: VideoSummary, repository: ImageRepository?,
              pixels: Int, onSelect: @escaping () -> Void) {
        (view as? PosterNativeCardView)?.bind(summary: summary,
            repository: repository, pixels: pixels, onSelect: onSelect)
    }

    func present(_ presentation: PosterNativeCardPresentation?, onSelectSource: ((VideoSummary) -> Void)?) {
        (view as? PosterNativeCardView)?.present(presentation, onSelectSource: onSelectSource)
    }

    func setKeyboardHighlighted(_ highlighted: Bool) {
        (view as? PosterNativeCardView)?.setKeyboardHighlighted(highlighted)
    }

    override func prepareForReuse() {
        (view as? PosterNativeCardView)?.reset()
        view.removeFromSuperview()
        super.prepareForReuse()
    }
}

final class PosterNativeCardView: NSView, BrowserHoverTarget {
    private let poster = PosterLayerImageView(frame: .zero)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let rating = NSTextField(labelWithString: "")
    private let imageCoordinator = PosterNativeRemoteImage.Coordinator()
    private var onSelect: (() -> Void)?
    private var sources: [VideoSummary] = []
    private var onSelectSource: ((VideoSummary) -> Void)?
    private var isHovered = false { didSet { updateHighlight(); updateTitleToolTip() } }
    private var isKeyboardHighlighted = false { didSet { updateHighlight() } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = BrowserHoverStyle.cornerRadius
        poster.wantsLayer = true
        poster.layer?.cornerRadius = 6
        poster.layer?.masksToBounds = true
        poster.layer?.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.12).cgColor
        addSubview(poster)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)
        rating.font = .systemFont(ofSize: 11, weight: .bold)
        rating.textColor = .white
        rating.alignment = .center
        rating.wantsLayer = true
        rating.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        rating.layer?.cornerRadius = 8
        addSubview(rating)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func bind(summary: VideoSummary, repository: ImageRepository?,
              pixels: Int, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        title.stringValue = summary.title
        clearTitleToolTip()
        subtitle.stringValue = VideoCardMetadata.secondaryText(
            from: summary.remarks) ?? ""
        rating.stringValue = VideoCardMetadata.ratingText(
            from: summary.remarks) ?? ""
        rating.isHidden = rating.stringValue.isEmpty
        setAccessibilityLabel(L10n.string("video.provider-accessibility",
            fallback: "%@, from %@", summary.title, summary.siteName))
        if let url = summary.posterURL {
            imageCoordinator.update(view: poster,
                request: PosterImageRequest(url: url, pixels: pixels),
                repository: repository, priority: .reverse)
        } else {
            imageCoordinator.cancel()
        }
        needsLayout = true
    }

    private var titleTipTag: NSView.ToolTipTag?
    private(set) var titleTipText: NSString?
    private(set) var titleTipRect: NSRect?

    private func clearTitleToolTip() {
        if let titleTipTag { removeToolTip(titleTipTag) }
        titleTipTag = nil; titleTipText = nil; titleTipRect = nil
        toolTip = nil
    }
    private func updateTitleToolTip() {
        let text = isHovered ? BrowserTextOverflow.tooltip(for: title) : nil
        guard titleTipText?.description != text || titleTipRect != (text == nil ? nil : title.frame) else { return }
        clearTitleToolTip()
        if let text {
            let owner = text as NSString
            titleTipText = owner; titleTipRect = title.frame
            titleTipTag = addToolTip(title.frame, owner: owner, userData: nil)
        }
    }

    private var showsSubtitle = false
    func present(_ presentation: PosterNativeCardPresentation?, onSelectSource: ((VideoSummary) -> Void)?) {
        showsSubtitle = presentation != nil
        needsLayout = true
        self.onSelectSource = onSelectSource
        sources = presentation?.sources ?? []
        if let presentation {
            subtitle.stringValue = presentation.subtitle
            setAccessibilityLabel(title.stringValue + ", " + presentation.subtitle)
        }
        menu = nil
        if !sources.isEmpty {
            let menu = NSMenu()
            for (index, source) in sources.enumerated() {
                let item = NSMenuItem(title: source.siteName, action: #selector(selectSource(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
            self.menu = menu
        }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard sources.indices.contains(sender.tag) else { return }
        onSelectSource?(sources[sender.tag])
    }

    func reset() {
        clearTitleToolTip()
        title.stringValue = ""
        setAccessibilityLabel(nil)
        imageCoordinator.cancel()
        onSelect = nil
        onSelectSource = nil
        sources = []
        menu = nil
        isHovered = false
        isKeyboardHighlighted = false
    }

    override func layout() {
        super.layout()
        let inset = PosterGridMetrics.inset
        let posterWidth = max(0, bounds.width - 2 * inset)
        let posterHeight = posterWidth * 1.5
        poster.frame = NSRect(x: inset, y: inset,
            width: posterWidth, height: posterHeight)
        title.frame = NSRect(x: inset,
            y: poster.frame.maxY + PosterGridMetrics.textSpacing,
            width: posterWidth, height: PosterGridMetrics.titleHeight)
        updateTitleToolTip()
        subtitle.frame = NSRect(x: inset,
            y: title.frame.maxY + PosterGridMetrics.textSpacing,
            width: posterWidth, height: PosterGridMetrics.subtitleHeight)
        subtitle.isHidden = subtitle.stringValue.isEmpty
        subtitle.wantsLayer = true
        subtitle.textColor = showsSubtitle ? .secondaryLabelColor : .white
        subtitle.layer?.backgroundColor = showsSubtitle ? NSColor.clear.cgColor : NSColor.black.withAlphaComponent(0.65).cgColor
        subtitle.layer?.cornerRadius = 4
        if !showsSubtitle {
            let available = max(1, posterWidth - (rating.isHidden ? 14 : 60))
            subtitle.frame = NSRect(x: poster.frame.minX + 7, y: poster.frame.maxY - 25,
                width: min(available, subtitle.intrinsicContentSize.width + 6), height: 18)
        }
        let ratingWidth = min(posterWidth - 12,
            max(28, CGFloat(rating.stringValue.count) * 8 + 14))
        rating.frame = NSRect(x: poster.frame.maxX - ratingWidth - 7,
            y: poster.frame.maxY - 27,
            width: ratingWidth, height: 20)
    }

    func setBrowserHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
    }
    func setKeyboardHighlighted(_ highlighted: Bool) {
        isKeyboardHighlighted = highlighted
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let collection = enclosingScrollView?.documentView as? PosterNativePageCollectionView {
            window?.makeFirstResponder(collection)
        }
        onSelect?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }

    private func updateHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isKeyboardHighlighted
                ? NSColor.controlBackgroundColor.cgColor
                : (isHovered ? BrowserHoverStyle.color.cgColor : NSColor.clear.cgColor)
            layer?.borderColor = isKeyboardHighlighted
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
            layer?.borderWidth = isKeyboardHighlighted ? 1 : 0
        }
        CATransaction.commit()
    }

}

private final class PosterBrowseObservation {
    var lastInteractionRevision: UInt64 = 0
    var lastOffset: CGFloat?
    var direction: PosterScrollDirection = .down
    var firstVisibleIndex = 0
    let prefetchGate = PosterPrefetchPlanGate()
    var preheater: PosterPreheater?
}

/// A grid body revision. New values can replace posters without changing the
/// item count or the visible row range.
final class PosterPrefetchSource {}

final class PosterPrefetchPlanGate {
    private weak var source: PosterPrefetchSource?
    private var band: PosterPrefetchBand?

    func shouldUpdate(band: PosterPrefetchBand, source: PosterPrefetchSource) -> Bool {
        guard self.band != band || self.source !== source else { return false }
        self.band = band
        self.source = source
        return true
    }

    func reset() {
        band = nil
        source = nil
    }
}

enum PosterScrollDirection: Equatable { case down, up }

struct PosterPrefetchBand: Equatable {
    let firstRow: Int
    let lastRow: Int
    let columns: Int
    let pixels: Int
    let count: Int
    let direction: PosterScrollDirection
    let hasVisibleRows: Bool

    func plan(items: [VideoSummary]) -> [PosterPrefetchRequest] {
        guard hasVisibleRows, count > 0, columns > 0 else { return [] }
        var result: [PosterPrefetchRequest] = []
        var seen: Set<PosterImageRequest> = []
        func append(row: Int, priority: PosterImagePriority, distance: Int) {
            let start = max(0, row * columns)
            guard start < min(count, items.count) else { return }
            for index in start..<min(min(count, items.count), start + columns) {
                guard let url = items[index].posterURL else { continue }
                let request = PosterImageRequest(url: url, pixels: pixels)
                if seen.insert(request).inserted {
                    result.append(.init(request: request, demand: .init(priority: priority, distance: distance)))
                }
            }
        }
        let rowsAhead = min((48 + columns - 1) / columns, max(1, lastRow - firstRow + 1))
        switch direction {
        case .down:
            for row in Swift.stride(from: lastRow, through: firstRow, by: -1) {
                append(row: row, priority: .visible, distance: lastRow - row)
            }
            for distance in 0..<rowsAhead {
                append(row: lastRow + 1 + distance, priority: .forward, distance: distance)
                if distance == 0, firstRow > 0 {
                    append(row: firstRow - 1, priority: .reverse, distance: distance)
                }
            }
        case .up:
            for row in firstRow...lastRow {
                append(row: row, priority: .visible, distance: row - firstRow)
            }
            for distance in 0..<rowsAhead where firstRow > distance {
                append(row: firstRow - 1 - distance, priority: .forward, distance: distance)
                if distance == 0 { append(row: lastRow + 1, priority: .reverse, distance: distance) }
            }
            if firstRow == 0 { append(row: lastRow + 1, priority: .reverse, distance: 0) }
        }
        return result
    }
}

final class PosterHighlightState: ObservableObject {
    @Published private(set) var isHighlighted: Bool
    private(set) var changes = 0
    init(_ value: Bool) { isHighlighted = value }
    func update(_ value: Bool) {
        guard value != isHighlighted else { return }
        changes += 1
        isHighlighted = value
    }
}

final class PosterSelectionModel {
    private struct WeakHighlight { weak var value: PosterHighlightState? }
    private var boxes: [String: WeakHighlight] = [:]
    private var selection = BrowserItemSelection()
    var highlightedID: String? { selection.highlightedID }
    func highlight(for id: String) -> PosterHighlightState {
        if let existing = boxes[id]?.value { return existing }
        let state = PosterHighlightState(highlightedID == id)
        boxes[id] = WeakHighlight(value: state)
        return state
    }
    private func update(_ action: (inout BrowserItemSelection) -> Void) {
        let old = highlightedID
        action(&selection)
        guard old != highlightedID else { return }
        if let old { boxes[old]?.value?.update(false) }
        if let next = highlightedID { boxes[next]?.value?.update(true) }
    }
    func select(_ id: String) { update { $0.select(id) } }
    func hover(_ id: String, inside: Bool) { update { $0.hover(id, inside: inside) } }
    func reconcile(_ ids: [String]) {
        update { $0.reconcile(ids) }
        let valid = Set(ids)
        boxes = boxes.filter { valid.contains($0.key) && $0.value.value != nil }
    }
}

private struct SelectablePosterCard: View, Equatable {
    let item: VideoSummary
    @ObservedObject var highlight: PosterHighlightState
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.highlight === rhs.highlight
    }

    var body: some View {
        VideoCard(item: item, isHighlighted: highlight.isHighlighted, onHover: onHover, onSelect: onSelect)
    }
}

/// Shared native-looking segmented navigation treatment for home categories
/// and search result sources. The two screens retain independent overflow and
/// selection policies while sharing the exact same chrome and interaction
/// feedback.
enum BrowseSegmentedNavigationMetrics {
    static let rowHeight: CGFloat = 48
    static let controlHeight: CGFloat = 32
    static let horizontalPadding: CGFloat = 14
    static let minimumSegmentWidth: CGFloat = 62
    static let separatorWidth: CGFloat = 1
    static let containerInset: CGFloat = 2
    static let moreWidth: CGFloat = 66

    static func segmentWidth(textWidth: CGFloat) -> CGFloat {
        max(
            minimumSegmentWidth,
            ceil(textWidth) + horizontalPadding * 2
        )
    }

    static func innerAvailableWidth(_ availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - containerInset * 2)
    }
}

struct BrowseSegmentedNavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(BrowseSegmentedNavigationMetrics.containerInset)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.012))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct BrowseSegmentedNavigationDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.32))
            .frame(
                width: BrowseSegmentedNavigationMetrics.separatorWidth,
                height: 20
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BrowseSegmentedNavigationBottomDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.28))
            .frame(height: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BrowseSegmentedNavigationLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(
                .system(
                    size: 13,
                    weight: isSelected ? .semibold : .medium
                )
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(
                .horizontal,
                BrowseSegmentedNavigationMetrics.horizontalPadding
            )
            .frame(
                minWidth: BrowseSegmentedNavigationMetrics.minimumSegmentWidth,
                minHeight: BrowseSegmentedNavigationMetrics.controlHeight
            )
            .contentShape(Rectangle())
    }
}

struct BrowseSegmentedMoreLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Text(L10n.string("common.more", fallback: "More"))
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(
            width: BrowseSegmentedNavigationMetrics.moreWidth,
            height: BrowseSegmentedNavigationMetrics.controlHeight
        )
        .contentShape(Rectangle())
    }
}

struct BrowseSegmentedNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        BrowseSegmentedNavigationButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct BrowseSegmentedNavigationButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(
                isSelected
                    ? Color.primary
                    : isHovering
                        ? Color.primary.opacity(0.78)
                        : Color.secondary
            )
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(nsColor: .windowBackgroundColor).opacity(0.72)
                            : isHovering
                                ? Color.primary.opacity(0.055)
                                : Color.clear
                    )
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .stroke(Color.primary.opacity(0.035), lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// One geometry contract for real cards, placeholders and viewport calculations.
enum PosterGridMetrics {
    static let minimumWidth: CGFloat = 140
    static let maximumWidth: CGFloat = 190
    static let columnSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 16
    static let inset: CGFloat = 8
    static let textSpacing: CGFloat = 6
    static let titleHeight: CGFloat = 17
    static let subtitleHeight: CGFloat = 14
    static let footerHeight: CGFloat = 44
    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumWidth, maximum: maximumWidth),
                  spacing: columnSpacing, alignment: .top)]
    }
    static func columnCount(width: CGFloat) -> Int {
        max(1, Int((max(0, width) + columnSpacing) / (minimumWidth + columnSpacing)))
    }
    static func cardWidth(width: CGFloat) -> CGFloat {
        let count = CGFloat(columnCount(width: width))
        return min(maximumWidth, max(0, (width - (count - 1) * columnSpacing) / count))
    }
    static func cardHeight(width: CGFloat, showsSubtitle: Bool = false) -> CGFloat {
        max(0, width - 2 * inset) * 1.5 + titleHeight + textSpacing + 2 * inset
            + (showsSubtitle ? subtitleHeight + textSpacing : 0)
    }
    static func skeletonCount(width: CGFloat, height: CGFloat) -> Int {
        let rows = max(1, Int(ceil(max(0, height) / (cardHeight(width: cardWidth(width: width)) + rowSpacing))))
        return columnCount(width: width) * min(rows, 6)
    }
}

struct PosterGridImageGeometry: Equatable {
    let posterWidth: CGFloat
    let pixels: Int

    init(gridWidth: CGFloat, displayScale: CGFloat) {
        posterWidth = max(0, PosterGridMetrics.cardWidth(width: gridWidth)
            - 2 * PosterGridMetrics.inset)
        pixels = PosterImageRequest.bucket(posterWidth * 1.5 * displayScale)
    }
}

private struct PosterCardGeometryKey: EnvironmentKey {
    static let defaultValue: PosterGridImageGeometry? = nil
}

extension EnvironmentValues {
    var posterCardGeometry: PosterGridImageGeometry? {
        get { self[PosterCardGeometryKey.self] }
        set { self[PosterCardGeometryKey.self] = newValue }
    }
}

struct VideoCard: View {
    let item: VideoSummary
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: PosterGridMetrics.textSpacing) {
                VideoPosterView(item: item)

                TruncationAwareText(text: item.title, font: .system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: PosterGridMetrics.titleHeight, alignment: .topLeading)


            }
            .contentShape(RoundedRectangle(cornerRadius: BrowserHoverStyle.cornerRadius, style: .continuous))
            .padding(PosterGridMetrics.inset)
            .background {
                RoundedRectangle(cornerRadius: BrowserHoverStyle.cornerRadius, style: .continuous)
                    .fill(
                        isHighlighted
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: BrowserHoverStyle.cornerRadius, style: .continuous)
                    .stroke(
                        isHighlighted
                            ? Color.secondary.opacity(0.18)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .background { BrowserHoverBackground() }
        .accessibilityLabel(L10n.string("video.provider-accessibility", fallback: "%@, from %@", item.title, item.siteName))
    }

    private var secondaryText: String? {
        VideoCardMetadata.secondaryText(from: item.remarks)
    }
}

enum VideoCardMetadata {
    static func ratingText(from remarks: String?) -> String? {
        guard let candidate = ratingCandidate(from: remarks),
              candidate.value > 0,
              candidate.value <= 10 else {
            return nil
        }
        return candidate.text
    }

    private static func ratingCandidate(
        from remarks: String?
    ) -> (text: String, value: Double)? {
        guard var text = normalized(remarks) else { return nil }
        for label in ["豆瓣评分", "评分", "豆瓣"] where text.hasPrefix(label) {
            text.removeFirst(label.count)
            text = text.trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":："))
            )
            break
        }
        if text.hasSuffix("分") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty,
              let value = Double(text),
              value.isFinite else {
            return nil
        }
        return (text, value)
    }

    static func secondaryText(from remarks: String?) -> String? {
        guard let text = normalized(remarks) else { return nil }
        if let candidate = ratingCandidate(from: text), (0...10).contains(candidate.value) { return nil }
        return text
    }

    private static func normalized(_ remarks: String?) -> String? {
        let text = remarks?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return text.isEmpty ? nil : text
    }
}

struct VideoPosterView: View {
    let item: VideoSummary

    var body: some View {
        Group {
            if item.posterURL != nil {
                PosterView(url: item.posterURL)
            } else if item.isFolder {
                categoryNavigationPoster
            } else {
                PosterView(url: nil)
            }
        }
            .overlay(alignment: .topTrailing) {
                if item.isFolder, item.posterURL != nil {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.62))
                        .clipShape(Circle())
                        .padding(7)
                        .accessibilityLabel(L10n.string("video.category-navigation", fallback: "Category Navigation"))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating = VideoCardMetadata.ratingText(
                    from: item.remarks
                ) {
                    Text(rating)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(7)
                        .accessibilityLabel(L10n.string("video.rating", fallback: "Rating %@", rating))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let remark = VideoCardMetadata.secondaryText(from: item.remarks) {
                    Text(remark).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundColor(.white).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(7)
                }
            }
    }

    private var categoryNavigationPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.string("video.category-navigation", fallback: "Category Navigation"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("video.category-navigation", fallback: "Category Navigation"))
    }
}

struct PosterSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PosterGridMetrics.textSpacing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.10))
                .aspectRatio(2 / 3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(height: 12)
            }
            .frame(height: PosterGridMetrics.titleHeight, alignment: .topLeading)
        }
        .padding(PosterGridMetrics.inset)
        .accessibilityHidden(true)
    }
}

struct PosterInitialSkeleton: View {
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        LazyVGrid(columns: PosterGridMetrics.columns, alignment: .leading, spacing: PosterGridMetrics.rowSpacing) {
            ForEach(0..<PosterGridMetrics.skeletonCount(width: width, height: height), id: \.self) { _ in
                PosterSkeletonCard()
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("home.loading-categories", fallback: "Loading categories…"))
    }
}

enum HomePaginationPhase: Equatable {
    case idle, loading, refreshing, failed, uncertain, complete
    static func resolve(hasMore: Bool, loading: Bool, refreshing: Bool, error: String?,
                        issueKind: CategoryPaginationIssueKind = .failed) -> Self {
        if refreshing { return .refreshing }
        if loading { return .loading }
        if error != nil { return issueKind == .uncertain ? .uncertain : .failed }
        return hasMore ? .idle : .complete
    }
}

/// Reserves only an in-flight attempt. Completion releases the reservation,
/// including rejected/cancelled attempts. Pagination progress lives in the
/// query store, not in a permanent UI page/offset latch.
struct PosterPaginationDemand {
    private(set) var pendingPage: Int?

    mutating func begin(page: Int) -> Bool {
        guard pendingPage == nil else { return false }
        pendingPage = page
        return true
    }

    mutating func finish(page: Int) {
        guard pendingPage == page else { return }
        pendingPage = nil
    }

    mutating func requestIfNeeded(metrics: PosterScrollMetrics, nextPage: Int, eligible: Bool) -> Bool {
        guard eligible, metrics.viewport.height > 0,
              metrics.remaining <= metrics.viewport.height * 2 else { return false }
        return begin(page: nextPage)
    }
}

private final class PosterPaginationDemandBox: ObservableObject {
    var value = PosterPaginationDemand()
}

/// Home-only footer. The shared search/folder loader retains its own policy.
struct HomePaginationFooter: View {
    let hasMore: Bool
    let isLoading: Bool
    let isRefreshing: Bool
    let errorMessage: String?
    let itemCount: Int
    let viewportHeight: CGFloat
    let coordinateSpaceName: String
    var nextPage: Int = 2
    var issueKind: CategoryPaginationIssueKind = .failed
    var hasPendingUpdate = false
    var onAcceptUpdate: () -> Void = {}
    let onLoad: () async -> Bool
    @StateObject private var demand = PosterPaginationDemandBox()
    @State private var showsError = false
    private var phase: HomePaginationPhase {
        .resolve(hasMore: hasMore, loading: isLoading, refreshing: isRefreshing, error: errorMessage, issueKind: issueKind)
    }
    private func manuallyLoad() {
        guard demand.value.begin(page: nextPage) else { return }
        loadReservedPage()
    }
    private func loadReservedPage() {
        let requestedPage = nextPage
        Task { @MainActor in
            let succeeded = await onLoad()
            demand.value.finish(page: requestedPage)
            // Re-render with the current query state, then let the enclosing
            // scroll probe measure after the appended content is laid out.
            if succeeded { demand.objectWillChange.send() }
        }
    }
    var body: some View {
        Color.clear
        .frame(height: 1)
        .accessibilityHidden(true)
        .background {
            PosterScrollObserver { metrics in
                if demand.value.requestIfNeeded(metrics: metrics, nextPage: nextPage, eligible: phase == .idle && !hasPendingUpdate) {
                    loadReservedPage()
                }
            }
        }
    }
}

struct AutomaticPageLoader: View {
    let isLoading: Bool
    let errorMessage: String?
    let viewportHeight: CGFloat
    let coordinateSpaceName: String
    let onLoad: () -> Void
    @State private var hasTriggered = false

    var body: some View {
        Group {
            if isLoading {
                VideoGridSkeleton()
            } else if errorMessage != nil {
                Button(L10n.string("pagination.failed.retry", fallback: "Loading Failed — Try Again")) {
                    onLoad()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .help(errorMessage ?? L10n.string("pagination.failed", fallback: "The next page could not be loaded"))
            } else if hasTriggered {
                HStack(spacing: 8) {
                    AppActivityIndicator(size: .small)
                    Text(L10n.string("pagination.preparing", fallback: "Preparing the next page…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                GeometryReader { geometry in
                    let minY = geometry.frame(
                        in: .named(coordinateSpaceName)
                    ).minY
                    Color.clear
                        .task(id: Int(minY.rounded())) {
                            guard minY >= -8,
                                  minY <= viewportHeight + 4 else {
                                return
                            }
                            do {
                                try await Task.sleep(
                                    nanoseconds: 550_000_000
                                )
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, !hasTriggered else {
                                return
                            }
                            hasTriggered = true
                            onLoad()
                        }
                }
                .frame(height: 34)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isLoading ? L10n.string("pagination.loading", fallback: "Loading the next page") :
                (errorMessage != nil
                    ? L10n.string("pagination.failed.retry", fallback: "Loading Failed — Try Again")
                    : (hasTriggered
                        ? L10n.string("pagination.preparing", fallback: "Preparing the next page…")
                        : L10n.string("pagination.scroll", fallback: "Keep scrolling to load the next page")))
        )
    }
}

struct PaginationCompletionFooter: View {
    let itemCount: Int

    var body: some View {
        Label(L10n.string("pagination.complete", fallback: "All %d items loaded", itemCount), systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityLabel(L10n.string("pagination.complete", fallback: "All %d items loaded", itemCount))
    }
}

struct VideoGridSkeleton: View {
    var count = 6
    @State private var isPulsing = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.13))
                        .aspectRatio(2 / 3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 92, height: 11)
                }
                .opacity(isPulsing ? 0.42 : 1)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.85)
                    .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }
}

struct PosterView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.posterCardGeometry) private var posterCardGeometry
#if DEBUG
    @Environment(\.posterLabStaticImage) private var posterLabStaticImage
    @Environment(\.posterLabNativeImage) private var posterLabNativeImage
    @Environment(\.posterLabLegacyImage) private var posterLabLegacyImage
#endif
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            if let url {
#if DEBUG
                if let posterLabStaticImage {
                    Image(nsImage: posterLabStaticImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    remoteImage(url)
                }
#else
                remoteImage(url)
#endif
            } else {
                placeholder
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.12))
        }
    }

    @ViewBuilder
    private func remoteImage(_ url: URL) -> some View {
        if let posterCardGeometry {
            imageCarrier(PosterImageRequest(url: url,
                pixels: posterCardGeometry.pixels))
                .frame(width: posterCardGeometry.posterWidth,
                    height: posterCardGeometry.posterWidth * 1.5)
        } else {
            GeometryReader { geometry in
                imageCarrier(PosterImageRequest(url: url,
                    pixels: PosterImageRequest.bucket(max(geometry.size.width,
                        geometry.size.height) * displayScale)))
                    .frame(width: geometry.size.width,
                        height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func imageCarrier(_ request: PosterImageRequest) -> some View {
#if DEBUG
        if posterLabLegacyImage {
            PosterRemoteImage(request: request)
        } else if posterLabNativeImage {
            PosterNativeRemoteImage(request: request)
        } else {
            PosterLayerRemoteImage(request: request)
        }
#else
        PosterLayerRemoteImage(request: request)
#endif
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.largeTitle)
            .foregroundColor(.secondary)
    }
}

#if DEBUG
private struct PosterLabStaticImageKey: EnvironmentKey {
    static let defaultValue: NSImage? = nil
}

extension EnvironmentValues {
    var posterLabStaticImage: NSImage? {
        get { self[PosterLabStaticImageKey.self] }
        set { self[PosterLabStaticImageKey.self] = newValue }
    }
}
#endif

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
