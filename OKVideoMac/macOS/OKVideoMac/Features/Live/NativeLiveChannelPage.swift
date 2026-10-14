import AppKit
import Combine
import OKVideoCore
import SwiftUI

struct LiveChannelBrowseAnchor {
    let id: String
    let inset: CGFloat
    var isAtTop = false

    static func capture(ids: [String], offset: CGFloat, columns: Int, rowHeight: CGFloat) -> Self? {
        guard !ids.isEmpty, columns > 0, rowHeight > 0 else { return nil }
        let offset = max(0, offset)
        let row = max(0, Int(max(0, offset - 20) / rowHeight))
        let index = min(ids.count - 1, row * columns)
        return Self(id: ids[index], inset: offset - 20 - CGFloat(row) * rowHeight,
                    isAtTop: offset <= 0.5)
    }

    func offset(ids: [String], columns: Int, rowHeight: CGFloat) -> CGFloat {
        guard !isAtTop, columns > 0, let index = ids.firstIndex(of: id) else { return 0 }
        return max(0, 20 + CGFloat(index / columns) * rowHeight + inset)
    }
}

/// One AppKit scroll surface; EPG and hover never invalidate the SwiftUI grid.
struct NativeLiveChannelPage: NSViewRepresentable {
    @EnvironmentObject private var state: AppState
    @Environment(\.browserNavigationSelection) private var navigationSelection
    @Environment(\.imageRepository) private var repository
    @Environment(\.browserToolbarScrollReporter) private var reportScroll
    let channels: [LiveChannel]
    let source: LiveSourceID
    let sourceName: String
    let catalog: AcceptedImportedCatalog?
    let session: LiveBrowserSession
    let browseKey: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LiveChannelScrollView {
        let scroll = LiveChannelScrollView()
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: LiveChannelScrollView, context: Context) {
        scroll.collection.navigationSelection = navigationSelection
        context.coordinator.update(self, state: state, repository: repository, report: reportScroll)
    }
    static func dismantleNSView(_ view: LiveChannelScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private weak var scroll: LiveChannelScrollView?
        private var page: NativeLiveChannelPage?
        private weak var state: AppState?
        private var repository: ImageRepository?
        private var channels: [LiveChannel] = []
        private var favorites = Set<String>()
        private var urls: [String: [URL]] = [:]
        private var report: (Bool) -> Void = { _ in }
        private var lastScrolled: Bool?
        private var width: CGFloat = 0
        private var columns = 1
        private var pixels = 512
        private var itemSize = NSSize(width: 260, height: 250)
        private var boundsObserver: NSObjectProtocol?
        private var epgObserver: AnyCancellable?
        private var timer: Timer?
        private var demandTask: Task<Void, Never>?
        private var pendingViewport = false
        private var preheater = PosterPreheater()
        private var currentKey: String?
        private var restoring = false
        private let formatter: DateFormatter = {
            let value = DateFormatter(); value.dateStyle = .none; value.timeStyle = .short; return value
        }()

        func attach(_ scroll: LiveChannelScrollView) {
            self.scroll = scroll
            scroll.collection.dataSource = self
            scroll.collection.delegate = self
            scroll.collection.activate = { [weak self] in
                guard let self, let index = self.scroll?.collection.selectionIndexPaths.first?.item,
                      self.channels.indices.contains(index) else { return }
                self.play(self.channels[index])
            }
            scroll.didLayout = { [weak self] in self?.layout() }
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleViewport() }
            }
        }

        func update(_ page: NativeLiveChannelPage, state: AppState, repository: ImageRepository?, report: @escaping (Bool) -> Void) {
            let changed = channels != page.channels || self.page?.source != page.source
            let nextFavorites = Set(page.channels.filter { state.isLiveFavorite(sourceID: page.source, channel: $0) }.map(\.id))
            let favoritesChanged = nextFavorites != favorites
            let keyChanged = currentKey != page.browseKey
            // Playback history is not a browsing position. A new page starts at its true top.
            let anchor = keyChanged ? page.session.channelAnchors[page.browseKey] : captureAnchor()
            let oldIDs = channels.map(\.id)
            self.page = page; self.state = state; self.repository = repository; self.report = report
            currentKey = page.browseKey; favorites = nextFavorites
            if epgObserver == nil {
                epgObserver = state.liveEPG.objectWillChange.sink { [weak self] in
                    DispatchQueue.main.async { self?.refreshVisible() }
                }
            }
            if page.session.isActive, timer == nil {
                let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshVisible() }
                }
                RunLoop.main.add(timer, forMode: .common); self.timer = timer
            } else if !page.session.isActive {
                timer?.invalidate(); timer = nil
                demandTask?.cancel(); demandTask = nil; preheater.cancel()
            }
            if changed {
                channels = page.channels
                let fallback: Bool
                if case .imported = page.source { fallback = true } else { fallback = false }
                urls = Dictionary(uniqueKeysWithValues: channels.map {
                    ($0.id, LiveChannelLogoResolver.urls(for: $0, allowsFallback: fallback))
                })
                let newIDs = channels.map(\.id)
                if oldIDs != newIDs {
                    let oldSet = Set(oldIDs), newSet = Set(newIDs)
                    if !keyChanged, !oldIDs.isEmpty,
                       oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains) {
                        let removed = Set(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) }.map { IndexPath(item: $0, section: 0) })
                        let added = Set(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) }.map { IndexPath(item: $0, section: 0) })
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0
                            scroll?.collection.performBatchUpdates({
                                self.scroll?.collection.deleteItems(at: removed)
                                self.scroll?.collection.insertItems(at: added)
                            }, completionHandler: nil)
                        }
                    } else { scroll?.collection.reloadData() }
                }
                layout()
                refreshVisible(rebind: true)
            } else if favoritesChanged { refreshVisible(rebind: true) }
            if keyChanged || (changed && oldIDs != channels.map(\.id)) { restore(anchor) }
            scheduleViewport()
        }

        private func layout() {
            guard let scroll else { return }
            let available = max(1, scroll.contentSize.width)
            let nextColumns = max(1, Int((available - 40 + 18) / (238 + 18)))
            let cardWidth = min(340, max(1, (available - 40 - CGFloat(nextColumns - 1) * 18) / CGFloat(nextColumns)))
            let size = NSSize(width: cardWidth, height: LiveChannelCardMetrics.height(width: cardWidth))
            let rows = (channels.count + nextColumns - 1) / nextColumns
            let height = max(scroll.contentSize.height, CGFloat(rows) * (size.height + 20) + 20)
            let nextPixels = PosterImageRequest.bucket(cardWidth * (scroll.window?.backingScaleFactor ?? 2))
            let layoutChanged = abs(width - available) > 0.5 || itemSize != size
            let anchor = width > 0 && layoutChanged ? captureAnchor() : nil
            if layoutChanged {
                width = available; columns = nextColumns; itemSize = size
                let flow = scroll.collection.collectionViewLayout as! NSCollectionViewFlowLayout
                flow.itemSize = size
                flow.minimumInteritemSpacing = 18; flow.minimumLineSpacing = 20
                flow.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
                flow.invalidateLayout()
            }
            if scroll.collection.frame.size != NSSize(width: available, height: height) {
                scroll.collection.setFrameSize(NSSize(width: available, height: height))
            }
            if pixels != nextPixels { pixels = nextPixels; refreshVisible(rebind: true) }
            if let anchor { restore(anchor) }
            scheduleViewport()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { channels.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: LiveChannelNativeItem.identifier, for: indexPath) as! LiveChannelNativeItem
            bind(item, index: indexPath.item)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? LiveChannelNativeItem)?.card.cancelImage()
        }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            if let item = item as? LiveChannelNativeItem { bind(item, index: indexPath.item) }
        }
        private func bind(_ item: LiveChannelNativeItem, index: Int) {
            guard channels.indices.contains(index), let page else { return }
            let channel = channels[index]
            item.card.bind(channel: channel, favorite: favorites.contains(channel.id),
                urls: urls[channel.id] ?? [], pixels: pixels, repository: repository)
            item.card.activate = { [weak self] in self?.play(channel) }
            item.card.favoriteAction = { [weak self] in
                guard let self, let state = self.state else { return }
                Task { await state.toggleLiveFavorite(sourceID: page.source, channel: channel) }
            }
            item.card.catchupAction = { [weak self] in self?.showCatchup(channel) }
            item.card.menuProvider = { [weak self] in self?.menu(channel) ?? NSMenu() }
            updateProgramme(item.card, channel: channel)
        }
        private func updateProgramme(_ card: LiveChannelNativeCard, channel: LiveChannel) {
            guard let page, let state else { return }
            let now = Date()
            let info = state.liveEPG.nowNext(channel: channel, source: page.source, at: now)
            card.showProgramme(info, date: now, formatter: formatter)
        }
        private func refreshVisible(rebind: Bool = false) {
            guard let scroll, !scroll.isHiddenOrHasHiddenAncestor, page?.session.isActive == true else { return }
            for path in scroll.collection.indexPathsForVisibleItems() where channels.indices.contains(path.item) {
                guard let item = scroll.collection.item(at: path) as? LiveChannelNativeItem else { continue }
                if rebind { bind(item, index: path.item) }
                else { updateProgramme(item.card, channel: channels[path.item]) }
            }
        }
        private func scheduleViewport() {
            guard !pendingViewport else { return }
            pendingViewport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingViewport = false
                self.viewportChanged()
            }
        }
        private func viewportChanged() {
            guard let scroll, let page, page.session.isActive else { return }
            let offset = max(0, scroll.contentView.bounds.minY)
            if !restoring, let anchor = captureAnchor() {
                if page.session.channelAnchors.count > 64 { page.session.channelAnchors.removeAll() }
                page.session.channelAnchors[page.browseKey] = anchor
            }
            let scrolled = offset > 0.5
            if lastScrolled != scrolled { lastScrolled = scrolled; report(scrolled) }
            let first = min(channels.count, max(0, Int((offset - 20) / (itemSize.height + 20))) * columns)
            let end = min(channels.count, (Int((offset + scroll.contentSize.height) / (itemSize.height + 20)) + 1) * columns)
            let range = max(0, first - columns)..<min(channels.count, max(first, end) + columns * 2)
            let plan = range.compactMap { index -> PosterPrefetchRequest? in
                guard let url = urls[channels[index].id]?.first else { return nil }
                return PosterPrefetchRequest(request: PosterImageRequest(url: url, pixels: pixels),
                    demand: PosterImageDemand(priority: index >= first && index < end ? .visible : .forward,
                        distance: abs(index - first)))
            }
            preheater.update(PosterPreheater.coalesced(plan), repository: repository)
            // One bounded task samples the latest viewport; continuous scrolling cannot starve it.
            if demandTask == nil {
                demandTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.demandTask = nil
                    self.publishDemand()
                }
            }
        }
        private func publishDemand() {
            guard let page, page.session.isActive, let scroll, let state else { return }
            let indices = scroll.collection.indexPathsForVisibleItems().map(\.item).sorted()
            let visible = indices.filter { channels.indices.contains($0) }.prefix(100).map { channels[$0] }
            state.setEPGBrowserDemand(source: page.source, channels: visible)
        }
        private func captureAnchor() -> LiveChannelBrowseAnchor? {
            guard let scroll, !channels.isEmpty else { return nil }
            return LiveChannelBrowseAnchor.capture(ids: channels.map(\.id),
                offset: scroll.contentView.bounds.minY, columns: columns, rowHeight: itemSize.height + 20)
        }
        private func restore(_ anchor: LiveChannelBrowseAnchor?) {
            guard let scroll else { return }
            let y = anchor?.offset(ids: channels.map(\.id), columns: columns, rowHeight: itemSize.height + 20) ?? 0
            restoring = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, scroll.collection.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            restoring = false
        }
        private func play(_ channel: LiveChannel) {
            guard let page, let state else { return }
            page.session.playDefault(channel: channel, source: page.source, catalog: page.catalog,
                channels: channels, state: state)
        }
        private func showCatchup(_ channel: LiveChannel) {
            guard let page, currentKey == page.browseKey,
                  page.session.selectedSourceID == page.source,
                  channels.contains(where: { $0.id == channel.id }) else { return }
            page.session.catchupChannelID = channel.id
            page.session.showsCatchupList = true
            page.session.setDisplayMode(.guide)
        }
        private func menu(_ channel: LiveChannel) -> NSMenu {
            let menu = NSMenu()
            guard let page, let state else { return menu }
            if case .imported = page.source {
                for selection in page.catalog?.selections(for: channel) ?? [] {
                    menu.addItem(LiveChannelMenuItem(selection.stream.name) { [weak self] in
                        guard let self else { return }
                        page.session.remember(channel: channel, source: page.source,
                            route: page.session.importedRouteIdentity(for: selection.stream, in: channel))
                        Task { await state.playImportedLive(selection, navigationChannels: self.channels) }
                    })
                }
            } else {
                for stream in channel.streams {
                    menu.addItem(LiveChannelMenuItem(stream.name) { [weak self] in
                        guard let self else { return }
                        page.session.remember(channel: channel, source: page.source, route: page.session.nativeRouteIdentity(for: stream))
                        Task { await state.playLive(channel: channel, stream: stream, sourceID: page.source, navigationChannels: self.channels) }
                    })
                }
            }
            menu.addItem(.separator())
            if LiveCatchupPresentation.canBrowse(channel) {
                menu.addItem(LiveChannelMenuItem(L10n.string("live.catchup.list", fallback: "Channel Catch-up List")) { [weak self] in
                    self?.showCatchup(channel)
                })
            }
            menu.addItem(LiveChannelMenuItem(L10n.string(favorites.contains(channel.id) ? "live.unfavorite" : "live.favorite",
                fallback: favorites.contains(channel.id) ? "Remove from Favorites" : "Favorite Channel")) {
                Task { await state.toggleLiveFavorite(sourceID: page.source, channel: channel) }
            })
            menu.addItem(LiveChannelMenuItem(L10n.string("live.delete-channel.action", fallback: "Delete Channel…")) { [weak self] in
                guard let window = self?.scroll?.window else { return }
                let alert = NSAlert()
                alert.messageText = L10n.string("live.delete-channel.title", fallback: "Delete “%@”?", channel.name)
                alert.informativeText = L10n.string("live.delete-channel.message", fallback: "This channel will be removed only from the local “%@” source and will not return after a refresh. You can restore it later from Deleted Channels in the toolbar.", page.sourceName)
                alert.addButton(withTitle: L10n.string("live.delete-channel.confirm", fallback: "Delete Channel"))
                alert.addButton(withTitle: L10n.string(.commonCancel))
                alert.beginSheetModal(for: window) { result in
                    if result == .alertFirstButtonReturn {
                        Task { await state.deleteLiveChannel(sourceID: page.source, sourceName: page.sourceName, channel: channel) }
                    }
                }
            })
            return menu
        }
        func stop() {
            scroll?.resetBrowserHover()
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil; epgObserver = nil; timer?.invalidate(); timer = nil
            demandTask?.cancel(); demandTask = nil; preheater.cancel()
            scroll?.collection.visibleItems().forEach { ($0 as? LiveChannelNativeItem)?.card.cancelImage() }
        }
    }
}

final class LiveChannelScrollView: BrowserHoverScrollView {
    let collection = LiveChannelCollectionView()
    var didLayout: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = true; autohidesScrollers = true
        let flow = NSCollectionViewFlowLayout()
        collection.collectionViewLayout = flow
        collection.backgroundColors = [.clear]; collection.isSelectable = true
        collection.register(LiveChannelNativeItem.self, forItemWithIdentifier: LiveChannelNativeItem.identifier)
        documentView = collection
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); didLayout?() }
}
final class LiveChannelCollectionView: NSCollectionView, BrowserContentKeyTarget {
    var navigationSelection: NavigationSelection?
    var activate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { activate?() }
        else { super.keyDown(with: event) }
    }
}
private final class LiveChannelNativeItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LiveChannelNativeItem")
    var card: LiveChannelNativeCard { view as! LiveChannelNativeCard }
    override func loadView() { view = LiveChannelNativeCard() }
    override var isSelected: Bool { didSet { card.selected = isSelected } }
    override func prepareForReuse() { super.prepareForReuse(); card.setBrowserHovered(false); card.cancelImage() }
}
private final class LiveChannelMenuItem: NSMenuItem {
    private var invoke: () -> Void
    init(_ title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke; super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { invoke() }
}
final class LiveChannelNativeCard: NSView, BrowserHoverTarget {
    private var hovered = false
    func setBrowserHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value; needsDisplay = true
    }
    private let logo = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let current = NSTextField(labelWithString: "")
    private let next = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let progress = NativeNeutralProgressView()
    private let star = NSButton()
    private let routes = NSButton()
    private let programmeInfo = NSButton()
    private let catchupButton = NSButton()
    private var programmePopover: NSPopover?
    private var imageTask: Task<Void, Never>?
    private var imageKey = ""
    var selected = false { didSet { if oldValue != selected { needsDisplay = true } } }
    var activate: (() -> Void)?
    var favoriteAction: (() -> Void)?
    var catchupAction: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        logo.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        for field in [name, current, next, time] {
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            if field !== name { field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor }
            addSubview(field)
        }
        addSubview(logo); addSubview(star); addSubview(routes); addSubview(progress); addSubview(number); addSubview(programmeInfo)
        addSubview(catchupButton)
        catchupButton.isBordered = false
        catchupButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        catchupButton.target = self; catchupButton.action = #selector(showCatchup)
        catchupButton.toolTip = L10n.string("live.catchup.list", fallback: "Channel Catch-up List")
        catchupButton.setAccessibilityLabel(catchupButton.toolTip)
        catchupButton.identifier = NSUserInterfaceItemIdentifier("live.catchup.open")
        catchupButton.isHidden = true
        next.isHidden = true; time.isHidden = true
        programmeInfo.isBordered = false
        programmeInfo.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        programmeInfo.target = self; programmeInfo.action = #selector(showProgrammeDetails)
        programmeInfo.toolTip = L10n.string("live.programme-details", fallback: "Programme Details")
        programmeInfo.setAccessibilityLabel(programmeInfo.toolTip)
        number.font = .systemFont(ofSize: 11, weight: .semibold)
        number.alignment = .center; number.textColor = .labelColor
        number.isHidden = true
        star.isBordered = false; star.target = self; star.action = #selector(favorite)
        routes.isBordered = false; routes.title = "•••"; routes.target = self; routes.action = #selector(showRoutes)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let artHeight = bounds.width * 9 / 16
        logo.frame = NSRect(x: 20, y: 16, width: max(0, bounds.width - 40), height: max(0, artHeight - 32))
        star.frame = NSRect(x: bounds.width - 38, y: 4, width: 26, height: 26)
        catchupButton.frame = NSRect(x: bounds.width - 70, y: 4, width: 26, height: 26)
        number.frame = NSRect(x: 17, y: 17, width: min(80, max(26, number.intrinsicContentSize.width + 10)), height: 18)
        name.frame = NSRect(x: 8, y: artHeight + 8, width: max(0, bounds.width - 76), height: 20)
        routes.frame = NSRect(x: bounds.width - 36, y: artHeight + 6, width: 28, height: 22)
        programmeInfo.frame = NSRect(x: bounds.width - 64, y: artHeight + 6, width: 26, height: 22)
        current.frame = NSRect(x: 8, y: artHeight + 32, width: max(0, bounds.width - 16), height: 17)
        time.frame = NSRect(x: 8, y: artHeight + 52, width: max(0, bounds.width - 16), height: 16)
        progress.frame = NSRect(x: 8, y: current.frame.maxY + 6, width: max(0, bounds.width - 16), height: 2)
        next.frame = NSRect(x: 8, y: artHeight + 80, width: max(0, bounds.width - 16), height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered && !selected {
            BrowserHoverStyle.color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: BrowserHoverStyle.cornerRadius,
                         yRadius: BrowserHoverStyle.cornerRadius).fill()
        }
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.width * 9 / 16).insetBy(dx: 8, dy: 8)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors: [NSColor] = dark
            ? [NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.29, alpha: 1),
               NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 1)]
            : [NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.90, alpha: 1),
               NSColor(calibratedRed: 0.68, green: 0.73, blue: 0.81, alpha: 1)]
        let artwork = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSGradient(colors: colors)?.draw(in: artwork, angle: 90)
        if selected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.08).setFill()
            artwork.fill()
        }
        if !number.isHidden {
            NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: number.frame.insetBy(dx: -2, dy: -1), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { activate?() }
    override func accessibilityPerformPress() -> Bool { activate?(); return true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    @objc private func favorite() { favoriteAction?() }
    @objc private func showCatchup() { catchupAction?() }
    @objc private func showRoutes() {
        if let menu = menuProvider?() { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: routes.bounds.maxY), in: routes) }
    }
    @objc private func showProgrammeDetails() {
        programmePopover?.close()
        let text = NSTextField(wrappingLabelWithString: [name.stringValue, current.stringValue, time.stringValue, next.stringValue].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        text.font = .systemFont(ofSize: 12)
        text.frame = NSRect(x: 14, y: 14, width: 290, height: 138)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 318, height: 166))
        controller.view.addSubview(text)
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: programmeInfo.bounds, of: programmeInfo, preferredEdge: .maxY)
        programmePopover = popover
    }
    func bind(channel: LiveChannel, favorite: Bool, urls: [URL], pixels: Int, repository: ImageRepository?) {
        if name.stringValue != channel.name { programmePopover?.close() }
        name.stringValue = channel.name
        catchupButton.isHidden = !LiveCatchupPresentation.canBrowse(channel)
        number.stringValue = channel.number ?? ""
        number.isHidden = number.stringValue.isEmpty
        needsLayout = true
        setAccessibilityLabel(channel.name)
        star.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: nil)
        star.contentTintColor = favorite ? .controlAccentColor : .secondaryLabelColor
        star.toolTip = L10n.string(favorite ? "live.unfavorite" : "live.favorite", fallback: favorite ? "Remove from Favorites" : "Favorite Channel")
        star.setAccessibilityLabel(star.toolTip)
        routes.toolTip = L10n.string("live.choose-stream", fallback: "Choose Stream")
        let key = "\(channel.id)/\(pixels)/\(urls)"
        guard imageKey != key else { return }
        cancelImage(); imageKey = key
        logo.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        guard let repository else { return }
        imageTask = Task { [weak self] in
            for url in urls {
                guard !Task.isCancelled else { return }
                let request = PosterImageRequest(url: url, pixels: pixels)
                guard let image = try? await repository.posterImage(for: request, consumer: UUID()) else { continue }
                guard !Task.isCancelled, self?.imageKey == key else { return }
                self?.logo.image = image
                return
            }
        }
    }
    func showProgramme(_ info: EPGNowNextSnapshot, date: Date, formatter: DateFormatter) {
        let emptyTitle: String
        switch info.availability {
        case .unsupported: emptyTitle = L10n.string("live.epg.unsupported", fallback: "Provider has no programme guide")
        case .failed: emptyTitle = L10n.string("live.epg.unavailable", fallback: "Programme guide unavailable")
        default: emptyTitle = L10n.string("live.epg.no-current", fallback: "No current programme")
        }
        let title = info.current.map { L10n.string("live.now-playing", fallback: "Now Playing: %@", $0.title) }
            ?? info.next.map { formatter.string(from: $0.start) + "  " + $0.title }
            ?? emptyTitle
        let nextTitle = info.next.map { formatter.string(from: $0.start) + "  " + $0.title }
            ?? ""
        let times = info.current.map { formatter.string(from: $0.start) + " – " + formatter.string(from: $0.end) } ?? ""
        let displayedTimes = info.availability == .stale && info.current != nil
            ? times + "  ·  " + L10n.string("live.epg.cached", fallback: "Cached") : times
        if current.stringValue != title { current.stringValue = title }
        if next.stringValue != nextTitle { next.stringValue = nextTitle }
        if time.stringValue != displayedTimes { time.stringValue = displayedTimes }
        progress.isHidden = info.progress(at: date) == nil
        programmeInfo.isHidden = info.current == nil && info.next == nil
        current.toolTip = [title, displayedTimes, nextTitle].filter { !$0.isEmpty }.joined(separator: "\n")
        progress.doubleValue = info.progress(at: date) ?? 0
        let progressTitle = L10n.string("live.programme-progress", fallback: "Programme Progress")
        progress.setAccessibilityLabel(progressTitle)
        progress.toolTip = progress.isHidden ? nil : "\(progressTitle) · \(displayedTimes) · \(Int(progress.doubleValue * 100))%"
        setAccessibilityValue(title + "; " + nextTitle)
    }
    func cancelImage() { imageTask?.cancel(); imageTask = nil; imageKey = "" }
    deinit { imageTask?.cancel() }
}


enum LiveChannelCardMetrics {
    static let informationHeight: CGFloat = 58
    static func height(width: CGFloat) -> CGFloat { width * 9 / 16 + informationHeight }
}
