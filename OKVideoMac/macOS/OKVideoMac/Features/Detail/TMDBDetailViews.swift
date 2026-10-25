import AppKit
import OKVideoCore
import SwiftUI

struct TMDBAttributionView: View {
    var expanded = false
    static let notice = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: URL(string: "https://www.themoviedb.org")!) {
                HStack(spacing: 10) {
                    Image("TMDBLogo").renderingMode(.original).resizable().scaledToFit().frame(width: 76, height: 14)
                    Text(L10n.string("tmdb.attribution", fallback: "Metadata and images from TMDB"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tmdb.attribution")
            if expanded {
                Text(Self.notice).font(.callout).textSelection(.enabled)
                Text(L10n.string("tmdb.notice.translation", fallback: "TMDB provides metadata and images. It does not endorse, certify, or otherwise approve this application."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TMDBSynopsis: Equatable {
    let title: String
    let facts: String
    let overview: String
}

/// TMDB sometimes supplies a numbered placeholder instead of an episode name.
/// Keep real titles, but do not append the same episode number a second time.
enum TMDBEpisodeTitle {
    static func compose(_ prefix: String, episode: TMDBEpisode?, seasonNumber: Int? = nil) -> String {
        guard let episode, let name = episode.name?.tmdbNonEmpty else { return prefix }
        func normalized(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        }
        let value = normalized(name)
        if value == normalized(prefix) { return prefix }
        if Int(value) == episode.episodeNumber { return prefix }
        let expectedSeason = seasonNumber ?? episode.seasonNumber
        if value.range(of: #"^(?:第[0-9零〇一二两三四五六七八九十百千万]+季[·•._-]*)?第?[0-9零〇一二两三四五六七八九十百千万]+[集话話]$"#, options: .regularExpression) != nil {
            let parsed = PlaybackResourceAnalyzer.analyze(.init(name: value.replacingOccurrences(of: "話", with: "话"), url: ""), categoryName: "电视剧")
            if parsed.episode == episode.episodeNumber,
               parsed.season == nil || expectedSeason == nil || parsed.season == expectedSeason { return prefix }
        }
        let pattern = #"^(?:(?:s|season)([0-9]+)[·._-]*)?(?:episode|ep|e)[._-]*([0-9]+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let episodeRange = Range(match.range(at: 2), in: value), Int(value[episodeRange]) == episode.episodeNumber {
            let namedSeason = Range(match.range(at: 1), in: value).flatMap { Int(value[$0]) }
            if namedSeason == nil || expectedSeason == nil || namedSeason == expectedSeason { return prefix }
        }
        return prefix + " · " + name
    }
}

/// Describes only the selected source resource; it never supplies a playback URL.
struct TMDBEpisodeInformation: Equatable {
    let title: String
    let facts: String
    let overview: String
    var hasOverview = true

    static func make(detail: VideoDetail, work: TMDBWork?, season: TMDBSeason?, source: PlaySource?, episode: PlayEpisode?, mappedEpisode: TMDBEpisode? = nil) -> Self {
        let sourceIndex = episode.flatMap { selected in source?.episodes.firstIndex(where: { $0.id == selected.id }) }
        let mapping = season.map { TMDBEpisodeMapper.episodes(source?.episodes ?? [], category: detail.summary.categoryName, season: $0) } ?? [:]
        let mapped = mappedEpisode ?? sourceIndex.flatMap { mapping[$0] }
        let isSeries = isSeries(detail: detail, work: work, season: season)
        let title: String
        if let mapped, let seasonNumber = mapped.seasonNumber ?? season?.seasonNumber {
            let number = L10n.string("tmdb.episode.heading", fallback: "Season %d · Episode %d", seasonNumber, mapped.episodeNumber)
            title = TMDBEpisodeTitle.compose(number, episode: mapped, seasonNumber: seasonNumber)
        } else if isSeries, let episode {
            title = TMDBEpisodeCards.sourceName(EpisodeNameParser.presentation(for: episode, categoryName: detail.summary.categoryName))
        } else { title = work?.displayTitle.tmdbNonEmpty ?? detail.summary.title }
        var facts: [String] = []
        if let minutes = mapped?.runtime ?? (isSeries ? nil : work?.runtime), minutes > 0 {
            facts.append(L10n.string("tmdb.runtime.minutes", fallback: "%d min", minutes))
        }
        if let date = (mapped?.airDate ?? (isSeries ? nil : work?.releaseDate))?.tmdbNonEmpty { facts.append(date) }
        else if !isSeries, let year = detail.summary.year?.tmdbNonEmpty { facts.append(year) }
        facts += (work?.genres ?? []).prefix(3).map(\.name)
        if let rating = work?.voteAverage, let votes = work?.voteCount, votes > 0 { facts.append(String(format: "TMDB %.1f", rating)) }
        let overview = isSeries && episode != nil
            ? mapped?.overview?.tmdbNonEmpty ?? L10n.string("tmdb.episode.no-overview", fallback: "No synopsis is available for this episode.")
            : work?.chineseOverview ?? detail.synopsis?.tmdbNonEmpty ?? work?.overview?.tmdbNonEmpty ?? ""
        return Self(title: title, facts: facts.joined(separator: " · "), overview: overview, hasOverview: isSeries && episode != nil ? mapped?.overview?.tmdbNonEmpty != nil : !overview.isEmpty)
    }
    static func isSeries(detail: VideoDetail, work: TMDBWork?, season: TMDBSeason?) -> Bool {
        if let work { return work.name != nil }
        return season != nil || PlaybackContentForm.category(detail.summary.categoryName) == .series
            || !PlaybackResourceAnalyzer.explicitSeasons(in: detail.summary.title).isEmpty
    }
    var synopsis: TMDBSynopsis { .init(title: title, facts: facts, overview: overview) }
}

enum TMDBHeroLayout {
    static func height(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        // Follow the backdrop's 16:9 proportion in both windowed and fullscreen
        // layouts. Only cap at the viewport edge so ultrawide windows keep the
        // actions visible instead of reserving a fixed fraction for the shelves.
        max(width < 560 ? 540 : 420, min(width * 9 / 16, max(420, viewportHeight - 24)))
    }
}

/// Anchor artwork at its top edge so increasing width cannot crop off heads.
/// The opaque canvas also covers transparent/blurred edges while artwork loads.
struct TMDBHeroArtwork: View {
    let image: Image
    let blurred: Bool
    var body: some View {
        GeometryReader { geometry in
            image.resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .blur(radius: blurred ? 24 : 0)
                .clipped()
        }.background(AppSurfacePalette.background)
    }
}

struct TMDBHeroView<Actions: View>: View {
    @ObservedObject var metadata: TMDBDetailModel
    let detail: VideoDetail
    let information: TMDBEpisodeInformation
    let width: CGFloat
    let viewportHeight: CGFloat
    let onSynopsis: (TMDBSynopsis) -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme

    private var height: CGFloat { TMDBHeroLayout.height(width: width, viewportHeight: viewportHeight) }
    private var actionWidth: CGFloat { min(260, max(1, width - 56)) }
    private var title: String { detail.summary.title }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                TMDBArtworkView(urls: [metadata.artwork(.backdrop), detail.summary.posterURL].compactMap { $0 }, pixels: 1280, priority: .hero, onDisplayed: { metadata.didDisplayHero($0) }) { image, fallback in
                    TMDBHeroArtwork(image: image, blurred: fallback || metadata.artwork(.backdrop) == nil)
                } placeholder: { AppSurfacePalette.background }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.44), .init(color: AppSurfacePalette.background.opacity(0.68), location: 0.76), .init(color: AppSurfacePalette.background, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                TMDBWorkTitle(title: title, logoURL: metadata.artwork(.logo), width: actionWidth, compact: width < 700)
                if width < 560 {
                    actions().frame(width: actionWidth)
                    currentInformation
                } else {
                    HStack(alignment: .top, spacing: 32) {
                        actions().frame(width: actionWidth)
                        currentInformation.frame(maxWidth: 900, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
        .background(AppSurfacePalette.background)
        .accessibilityIdentifier("tmdb.hero")
    }
    private var currentInformation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(information.title.isEmpty ? title : information.title)
                .font(.system(size: 18, weight: .semibold)).lineLimit(2)
                .frame(height: 44, alignment: .topLeading)
                .accessibilityIdentifier("tmdb.current-episode.title")
            Text(information.facts.isEmpty ? " " : information.facts)
            .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            .frame(height: 34, alignment: .topLeading)
            .accessibilityIdentifier("tmdb.current-episode.facts")
            TMDBSynopsisPreview(text: information.overview, enabled: information.hasOverview) { onSynopsis(information.synopsis) }
                .frame(height: 42)
        }
        .frame(height: 132, alignment: .topLeading)
        // Keep usable source/cached information visible while either channel
        // loads. Metadata progress belongs only to this information region.
        .overlay(alignment: .bottomLeading) {
            if metadata.selection == nil, information.overview.isEmpty {
                if metadata.isPreparing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L10n.string("tmdb.metadata.loading", fallback: "Loading movie information…"))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("tmdb.metadata-loading")
                } else if metadata.isAwaitingSourceIdentity {
                    Text(L10n.string("tmdb.metadata.identity-pending", fallback: "Waiting for provider information to verify the title"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("tmdb.identity-pending")
                }
            }
        }
    }
}

/// Keep the title slot stable while transparent artwork loads or falls back.
struct TMDBWorkTitle: View {
    let title: String
    let logoURL: URL?
    let width: CGFloat
    var compact = false
    var body: some View {
        TMDBArtworkView(urls: [logoURL].compactMap { $0 }, pixels: 500, priority: .visible) { image, _ in
            image.resizable().scaledToFit()
                .frame(maxWidth: width, maxHeight: 76, alignment: .bottom)
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
        } placeholder: {
            Text(title).font(.system(size: compact ? 28 : 36, weight: .bold))
                .lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.primary)
        }
        .frame(width: width, height: 98, alignment: .bottom)
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityIdentifier("tmdb.work-title")
    }
}

/// Shared native text measurement keeps the preview and expanded body honest at every width.
@MainActor enum TMDBTextLayout {
    static func attributed(_ text: String, size: CGFloat = 13, spacing: CGFloat = 3) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = spacing
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: 100_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
    static func preview(_ text: String, width: CGFloat, height: CGFloat = 42) -> NSAttributedString {
        let full = attributed(text)
        guard Self.height(full, width: width) > height else { return full }
        let suffix = "… " + L10n.string("tmdb.synopsis.more", fallback: "More")
        let characters = Array(text); var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if Self.height(attributed(String(characters.prefix(middle)) + suffix), width: width) <= height { low = middle }
            else { high = middle - 1 }
        }
        let result = NSMutableAttributedString(attributedString: attributed(String(characters.prefix(low)) + suffix))
        result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: result.length - (suffix as NSString).length, length: (suffix as NSString).length))
        return result
    }
}

struct TMDBSynopsisPreview: NSViewRepresentable {
    let text: String
    let enabled: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> TMDBSynopsisPreviewControl { TMDBSynopsisPreviewControl() }
    func updateNSView(_ view: TMDBSynopsisPreviewControl, context: Context) {
        view.text = text; view.isEnabled = enabled; view.actionHandler = action
        view.setAccessibilityLabel(text); view.setAccessibilityIdentifier("tmdb.synopsis.preview")
        view.needsDisplay = true
    }
}
final class TMDBSynopsisPreviewControl: NSControl {
    var text = ""
    var actionHandler: () -> Void = {}
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { isEnabled ? .button : .staticText }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; actionHandler(); return true }
    override func mouseUp(with event: NSEvent) { if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { actionHandler() } }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode), isEnabled { actionHandler() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        TMDBTextLayout.preview(text, width: bounds.width).draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

struct TMDBSynopsisPresenter: NSViewRepresentable {
    @Binding var synopsis: TMDBSynopsis?
    func makeNSView(context: Context) -> TMDBSynopsisAnchor { TMDBSynopsisAnchor() }
    func updateNSView(_ view: TMDBSynopsisAnchor, context: Context) {
        view.synopsis = synopsis; view.onDismiss = { synopsis = nil }; view.updatePresentation()
    }
    static func dismantleNSView(_ view: TMDBSynopsisAnchor, coordinator: ()) { view.removePresentation() }
}
final class TMDBSynopsisAnchor: NSView {
    var synopsis: TMDBSynopsis?
    var onDismiss: () -> Void = {}
    private var overlay: TMDBSynopsisOverlay?
    private weak var previousResponder: NSResponder?
    private var keyMonitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePresentation() }
    func updatePresentation() {
        guard let synopsis, let window, let content = window.contentView,
              let container = content.superview else { removePresentation(); return }
        if let overlay {
            overlay.frame = container.convert(content.bounds, from: content)
            overlay.update(synopsis); return
        }
        previousResponder = window.firstResponder
        let view = TMDBSynopsisOverlay(synopsis: synopsis, close: { [weak self] in self?.onDismiss() })
        // NSHostingView routes mouse hits through its SwiftUI tree and can skip
        // AppKit subviews added directly to it. Mount beside it so the window's
        // native hit testing reaches the modal before any underlying content.
        view.frame = container.convert(content.bounds, from: content)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .above, relativeTo: nil); overlay = view
        view.setAccessibilityIdentifier("tmdb.synopsis.overlay"); view.setAccessibilityModal(true)
        WindowModalRegistry.register(view, in: window)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let overlay = self.overlay, event.window === window else { return event }
            if event.keyCode == 53 { self.onDismiss(); return nil }
            if event.keyCode == 48 {
                window?.makeFirstResponder(window?.firstResponder === overlay.closeButton ? overlay.textView : overlay.closeButton)
                return nil
            }
            return event
        }
        DispatchQueue.main.async { [weak self, weak window] in
            if let view = self?.overlay { window?.makeFirstResponder(view.closeButton) }
        }
    }
    func removePresentation() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard let overlay else { return }
        let window = overlay.window
        if let window { WindowModalRegistry.unregister(overlay, in: window) }
        overlay.removeFromSuperview(); self.overlay = nil
        if let previousResponder { window?.makeFirstResponder(previousResponder) }; previousResponder = nil
    }
}
private final class TMDBSynopsisPanel: NSView { override var isFlipped: Bool { true } }
final class TMDBSynopsisOverlay: NSView {
    let closeButton = NSButton()
    let textView = NSTextView()
    private let panel = TMDBSynopsisPanel(), header = TMDBSynopsisPanel(), scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let close: () -> Void
    private var synopsis: TMDBSynopsis
    override var isFlipped: Bool { true }
    init(synopsis: TMDBSynopsis, close: @escaping () -> Void) {
        self.synopsis = synopsis; self.close = close; super.init(frame: .zero)
        wantsLayer = true; panel.wantsLayer = true; header.wantsLayer = true
        panel.layer?.cornerRadius = 12; panel.layer?.masksToBounds = true
        panel.setAccessibilityIdentifier("tmdb.synopsis.dialog")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly; closeButton.title = ""; closeButton.isBordered = false
        closeButton.bezelStyle = .texturedRounded; closeButton.target = self; closeButton.action = #selector(dismiss)
        closeButton.setAccessibilityLabel(L10n.string("common.close", fallback: "Close"))
        closeButton.setAccessibilityIdentifier("tmdb.synopsis.close")
        title.font = .systemFont(ofSize: 14, weight: .semibold); title.alignment = .center; title.maximumNumberOfLines = 2
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.textContainerInset = .zero; textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = textView
        addSubview(panel); panel.addSubview(header); header.addSubview(title); header.addSubview(closeButton); panel.addSubview(scroll)
        update(synopsis)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ synopsis: TMDBSynopsis) {
        let changed = self.synopsis != synopsis
        self.synopsis = synopsis; title.stringValue = synopsis.title
        textView.textStorage?.setAttributedString(TMDBTextLayout.attributed(synopsis.overview, size: 14, spacing: 5))
        if changed { scroll.contentView.scroll(to: .zero) }
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let width = min(600, max(200, bounds.width - 48)), bodyWidth = width - 48
        let naturalHeight = TMDBTextLayout.height(TMDBTextLayout.attributed(synopsis.overview, size: 14, spacing: 5), width: bodyWidth)
        let bodyHeight = min(max(21, naturalHeight), max(40, bounds.height * 0.70 - 98))
        let height = 50 + 48 + bodyHeight
        panel.frame = .init(x: (bounds.width-width)/2, y: (bounds.height-height)/2, width: width, height: height)
        header.frame = .init(x: 0, y: 0, width: width, height: 50)
        closeButton.frame = .init(x: 16, y: 9, width: 32, height: 32)
        title.frame = .init(x: 56, y: 14, width: width - 112, height: 28)
        scroll.frame = .init(x: 24, y: 70, width: bodyWidth, height: bodyHeight)
        textView.frame = .init(x: 0, y: 0, width: bodyWidth, height: max(naturalHeight, bodyHeight))
        textView.textContainer?.containerSize = .init(width: bodyWidth, height: .greatestFiniteMagnitude)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            header.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { close() } }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) { close() }
    @objc private func dismiss() { close() }
}

struct TMDBEpisodeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(width: 72, height: 12).frame(height: 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<9) { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)).frame(width: 160, height: 90)
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(width: 125, height: 12)
                        }
                    }
                }.padding(4)
            }
        }.frame(height: 162).accessibilityHidden(true)
    }
}

struct TMDBCastView: View {
    @ObservedObject var metadata: TMDBDetailModel
    let source: VideoSummary
    @Environment(\.tmdbOpenPerson) private var openPerson
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let cast = metadata.selection?.work.cast, !cast.isEmpty {
                TMDBHorizontalShelf(count: cast.count, cardWidth: 88, height: 170, identifier: "tmdb.cast", heading: L10n.string("tmdb.cast", fallback: "Cast & Crew")) { index in
                    let person = cast[index]
                    Button { openPerson(person, source) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TMDBArtworkView(urls: [metadata.imageURL(person.profilePath, kind: .profile)].compactMap { $0 }, pixels: 176, priority: .forward) { image, _ in
                                image.resizable().scaledToFill()
                            } placeholder: { ZStack { Color.secondary.opacity(0.10); Image(systemName: "person.crop.square").foregroundStyle(.secondary) } }
                            .frame(width: 88, height: 88).clipped().cornerRadius(9)
                            TruncationAwareText(text: person.name, font: .system(size: 13, weight: .medium))
                            TruncationAwareText(text: person.role, font: .system(size: 11)).foregroundStyle(.secondary)
                        }.frame(width: 88, alignment: .topLeading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(person.name).accessibilityIdentifier("tmdb.cast.person.\(index)")
                }.id(metadata.selection?.id)
            } else { Color.clear.frame(height: 170).accessibilityHidden(true) }
            TMDBAttributionView().padding(.top, 8)
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 22)
    }
}

struct TMDBEpisodeCards: View {
    static func title(_ item: EpisodePresentation, mapped: TMDBEpisode?) -> String {
        // Use the mapped number only when it belongs to this exact resource.
        // Preserve split/bonus/version names where a plain number loses meaning.
        let original = sourceName(item)
        guard let number = item.episodeNumber,
              original.range(of: #"[上下中]|备用|預告|预告|花絮"#, options: .regularExpression) == nil else {
            return TMDBEpisodeTitle.compose(original, episode: mapped)
        }
        let short = L10n.string("tmdb.episode.number", fallback: "Episode %d", number)
        return TMDBEpisodeTitle.compose(short, episode: mapped)
    }
    static func sourceName(_ item: EpisodePresentation) -> String {
        let name = item.originalName.precomposedStringWithCompatibilityMapping
        if name.range(of: #"第?\s*[0-9零〇一二两三四五六七八九十百]+\s*集\s*[（(]?\s*[上下中]"#, options: .regularExpression) != nil { return item.originalName }
        if let number = Int(name.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 { return L10n.string("tmdb.episode.number", fallback: "Episode %d", number) }
        return item.displayName
    }
    @ObservedObject var metadata: TMDBDetailModel
    let episodes: [EpisodePresentation]
    let sourceIdentity: String
    let sourceEpisodes: [PlayEpisode]
    var sourceName: String = ""
    var sourceReferenceIdentity: String? = nil
    let category: String?
    let selectedID: String?
    let fallbackURL: URL?
    let onSelect: (EpisodePresentation) -> Void
    let onPlay: (EpisodePresentation) -> Void
    @StateObject private var keyboard = TMDBEpisodeKeyboardController()
    var body: some View {
        let mapping = metadata.episodeMapping(source: .init(name: sourceName, episodes: sourceEpisodes, referenceIdentity: sourceReferenceIdentity), category: category)
        TMDBHorizontalShelf(count: episodes.count, cardWidth: 160, height: 170, identifier: "tmdb.episodes", contentInset: 8, revealIndex: episodes.firstIndex(where: { $0.id == selectedID }), heading: metadata.season.map { L10n.string("tmdb.season.number", fallback: "Season %d", $0.seasonNumber) } ?? (metadata.selection?.reference.type == .tv || PlaybackContentForm.category(category) == .series
            ? L10n.string("detail.episodes", fallback: "Episodes") : L10n.string("detail.playable-resources", fallback: "Playable Resources"))) { index in
            let item = episodes[index], mapped = mapping[item.sourceIndex]
            TMDBEpisodeCard(item: item, mapped: mapped, stillURL: metadata.imageURL(mapped?.stillPath, kind: .still),
                fallbackURL: metadata.artwork(.backdrop) ?? fallbackURL,
                selected: item.id == selectedID, loadingMetadata: metadata.isLoadingSeason,
                identifier: "tmdb.episode.\(sourceIdentity).\(item.sourceIndex)",
                onSelect: { keyboard.select(item.id); onSelect(item) }, onPlay: { onPlay(item) }, keyboard: keyboard, onArtworkDisplayed: { metadata.didDisplayEpisodeArtwork($0) })
        }
        .background(TMDBEpisodeKeyboardSurface(controller: keyboard, ids: episodes.map(\.id), selectedID: selectedID,
            onSelect: { id in if let item = episodes.first(where: { $0.id == id }) { onSelect(item) } },
            onPlay: { id in if let item = episodes.first(where: { $0.id == id }) { onPlay(item) } }))
        .id(sourceIdentity + episodes.map(\.id).joined(separator: "|"))
    }
}

struct TMDBEpisodeCard: View {
    let item: EpisodePresentation
    let mapped: TMDBEpisode?
    let stillURL: URL?
    let fallbackURL: URL?
    let selected: Bool
    let loadingMetadata: Bool
    let identifier: String
    let onSelect: () -> Void
    let onPlay: () -> Void
    var keyboard: TMDBEpisodeKeyboardController? = nil
    var onArtworkDisplayed: ((URL) -> Void)? = nil
    @Environment(\.imageRepository) private var repository
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    @State private var failed = false
    @State private var retry = 0
    private var title: String { TMDBEpisodeCards.title(item, mapped: mapped) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if let image = (loadedURL == stillURL ? image : nil) ?? stillURL.flatMap({ repository?.cachedPoster(for: PosterImageRequest(url: $0, pixels: 320)) }) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    TMDBArtworkView(urls: [fallbackURL].compactMap { $0 }, pixels: 1280, priority: .forward) { image, _ in image.resizable().scaledToFill() }
                        placeholder: { Color.secondary.opacity(0.15) }
                    Color.black.opacity(0.46)
                    VStack(spacing: 5) {
                        Text(TMDBEpisodeCards.sourceName(item)).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(fallbackLabel).font(.system(size: 10)).lineLimit(1)
                    }.foregroundStyle(.white).padding(10)
                }
            }
            .frame(width: 160, height: 90).clipped().cornerRadius(8)
            .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 2)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .clear, lineWidth: 2).padding(-3))
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 160, alignment: .leading)
        .accessibilityHidden(true)
        .overlay {
            TMDBEpisodeActivation(label: title, selected: selected, identifier: identifier, onSelect: onSelect, onPlay: onPlay, keyboard: keyboard)
        }
        .overlay(alignment: .topTrailing) {
            if failed {
                Button { failed = false; retry += 1 } label: {
                    Image(systemName: "arrow.clockwise").font(.caption).padding(5).background(.regularMaterial).clipShape(Circle())
                }.buttonStyle(.plain).padding(4)
                    .help(L10n.string("tmdb.image.retry", fallback: "Retry episode artwork"))
                    .accessibilityLabel(L10n.string("tmdb.image.retry", fallback: "Retry episode artwork"))
            }
        }
        .task(id: "\(stillURL?.absoluteString ?? ""):\(retry):\(selected)") {
            failed = false
            if loadedURL != stillURL { image = nil; loadedURL = nil }
            guard let stillURL, let repository else { return }
            if let cached = repository.cachedPoster(for: PosterImageRequest(url: stillURL, pixels: 320)) {
                loadedURL = stillURL; image = cached; onArtworkDisplayed?(stillURL); return
            }
            do {
                let loaded = try await repository.posterImage(for: PosterImageRequest(url: stillURL, pixels: 320), priority: selected ? .selected : .visible)
                guard !Task.isCancelled else { return }; loadedURL = stillURL; image = loaded; onArtworkDisplayed?(stillURL)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
    private var fallbackLabel: String {
        if failed { return L10n.string("tmdb.image.failed", fallback: "Artwork unavailable") }
        if loadingMetadata || (stillURL != nil && image == nil && !failed) { return L10n.string("tmdb.image.loading", fallback: "Loading artwork…") }
        if mapped == nil { return L10n.string("tmdb.episode.unmapped", fallback: "Original resource") }
        return L10n.string("tmdb.image.missing", fallback: "No episode artwork")
    }
}

/// AppKit clickCount lets single clicks select immediately, without waiting for
/// a double-click timeout, and gives double-clicks exactly one playback action.
struct TMDBEpisodeActivation: NSViewRepresentable {
    let label: String
    let selected: Bool
    let identifier: String
    let onSelect: () -> Void
    let onPlay: () -> Void
    var keyboard: TMDBEpisodeKeyboardController? = nil
    func makeNSView(context: Context) -> TMDBEpisodeActivationControl { TMDBEpisodeActivationControl() }
    func updateNSView(_ view: TMDBEpisodeActivationControl, context: Context) {
        view.onSelect = onSelect; view.onPlay = onPlay; view.keyboard = keyboard; view.focusRingType = .none
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(selected ? L10n.string("tmdb.episode.selected", fallback: "Selected") : "")
        view.setAccessibilityHelp(L10n.string("tmdb.episode.click-help", fallback: "Click to select. Double-click or press Return to play."))
        view.setAccessibilityIdentifier(identifier); view.toolTip = nil
    }
}

final class TMDBEpisodeActivationControl: NSControl {
    var onSelect: () -> Void = {}
    var onPlay: () -> Void = {}
    weak var keyboard: TMDBEpisodeKeyboardController?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }
    override func mouseDown(with event: NSEvent) {
        if keyboard?.claimFocus() != true { window?.makeFirstResponder(self) }
    }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate(clickCount: event.clickCount)
    }
    func activate(clickCount: Int) {
        onSelect()
        if clickCount == 2 { onPlay() }
    }
    override func keyDown(with event: NSEvent) {
        if let keyboard, keyboard.handle(event) { _ = keyboard.claimFocus(); return }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 { if !event.isARepeat { onPlay() } }
        else if event.keyCode == 49 { onSelect() }
        else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { onSelect(); return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

}

/// Read native clip bounds for both button and gesture navigation.
/// A stable responder outside the lazy cards keeps arrow-repeat navigation alive
/// when the previously selected card scrolls out of the hierarchy. No window monitor.
@MainActor final class TMDBEpisodeKeyboardController: ObservableObject {
    weak var view: TMDBEpisodeKeyboardView?
    private var ids: [String] = []
    private var renderedSelection: String?
    private(set) var selectedID: String?
    var onSelect: (String) -> Void = { _ in }
    var onPlay: (String) -> Void = { _ in }
    func configure(ids: [String], selectedID: String?) {
        if self.ids != ids || renderedSelection != selectedID { self.selectedID = selectedID }
        self.ids = ids; renderedSelection = selectedID
        if let current = self.selectedID, !ids.contains(current) { self.selectedID = nil }
    }
    func select(_ id: String) { selectedID = id }
    func claimFocus() -> Bool {
        guard let view, let window = view.window else { return false }
        return window.makeFirstResponder(view)
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !ids.isEmpty else { return false }
        switch event.keyCode {
        case 123, 124:
            let current = selectedID.flatMap { ids.firstIndex(of: $0) }
            let index = current.map { min(ids.count - 1, max(0, $0 + (event.keyCode == 123 ? -1 : 1))) } ?? 0
            selectedID = ids[index]; onSelect(ids[index]); return true
        case 36, 76:
            if !event.isARepeat, let selectedID, ids.contains(selectedID) { onPlay(selectedID) }
            return true
        case 49:
            if let selectedID, ids.contains(selectedID) { onSelect(selectedID) }
            return true
        default: return false
        }
    }
}

struct TMDBEpisodeKeyboardSurface: NSViewRepresentable {
    let controller: TMDBEpisodeKeyboardController
    let ids: [String]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onPlay: (String) -> Void
    func makeNSView(context: Context) -> TMDBEpisodeKeyboardView { TMDBEpisodeKeyboardView() }
    func updateNSView(_ view: TMDBEpisodeKeyboardView, context: Context) {
        view.controller = controller; controller.view = view
        controller.configure(ids: ids, selectedID: selectedID)
        controller.onSelect = onSelect; controller.onPlay = onPlay
    }
    static func dismantleNSView(_ view: TMDBEpisodeKeyboardView, coordinator: ()) {
        if view.controller?.view === view { view.controller?.view = nil }
        view.controller = nil
    }
}

final class TMDBEpisodeKeyboardView: NSView {
    weak var controller: TMDBEpisodeKeyboardController?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) {
        if controller?.handle(event) != true { super.keyDown(with: event) }
    }
}

struct TMDBHorizontalShelf<Content: View>: View {
    let count: Int
    let cardWidth: CGFloat
    let height: CGFloat
    let identifier: String
    var contentInset: CGFloat = 4
    var revealIndex: Int? = nil
    var heading: String? = nil
    @ViewBuilder let content: (Int) -> Content
    @StateObject private var scrolling = TMDBShelfScrollController()
    private let spacing: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let heading { Text(heading).font(.system(size: 15, weight: .semibold)); Text(String(count)).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                pageButton(forward: false, disabled: !scrolling.canGoBack)
                pageButton(forward: true, disabled: !scrolling.canGoForward)
            }.frame(height: 26)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<count, id: \.self) { index in content(index).id(index) }
                    }.padding(contentInset).background(TMDBShelfScrollObserver(controller: scrolling))
                }
                .accessibilityIdentifier(identifier + ".scroll")
                .onAppear { if let revealIndex { proxy.scrollTo(revealIndex) } }
                .onChange(of: revealIndex) { if let index = $0 { proxy.scrollTo(index) } }
            }
        }.frame(height: height)
    }
    private func pageButton(forward: Bool, disabled: Bool) -> some View {
        let label = forward ? L10n.string("tmdb.next-page", fallback: "Next Page") : L10n.string("tmdb.previous-page", fallback: "Previous Page")
        return Button { scrolling.page(forward: forward, stride: cardWidth + spacing) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
        }.buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
            .accessibilityIdentifier(identifier + (forward ? ".next" : ".previous"))
    }
}

@MainActor
final class TMDBShelfScrollController: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var maximumOffset: CGFloat = 0
    private weak var scrollView: NSScrollView?
    var canGoBack: Bool { offset > 1 }
    var canGoForward: Bool { offset < maximumOffset - 1 }

    func update(_ scroll: NSScrollView?) {
        scrollView = scroll
        guard let scroll, let document = scroll.documentView else { return }
        let maximum = max(0, document.bounds.width - scroll.contentView.bounds.width)
        let current = min(maximum, max(0, scroll.contentView.bounds.minX - document.bounds.minX))
        if maximumOffset != maximum { maximumOffset = maximum }
        if offset != current { offset = current }
    }

    func page(forward: Bool, stride: CGFloat) {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        // Read again at click time: rapid clicks and trackpad movement can arrive
        // before the coalesced notification updates the buttons.
        update(scroll)
        let distance = max(1, floor(scroll.contentView.bounds.width / max(1, stride))) * max(1, stride)
        let target = min(maximumOffset, max(0, offset + (forward ? distance : -distance)))
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: document.bounds.minX + target, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        update(scroll)
    }
}

private struct TMDBShelfScrollObserver: NSViewRepresentable {
    let controller: TMDBShelfScrollController
    func makeNSView(context: Context) -> TMDBShelfScrollProbe { TMDBShelfScrollProbe() }
    func updateNSView(_ view: TMDBShelfScrollProbe, context: Context) {
        view.controller = controller
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: TMDBShelfScrollProbe, coordinator: ()) { view.stop() }
}

final class TMDBShelfScrollProbe: NSView {
    weak var controller: TMDBShelfScrollController?
    private weak var observedClip: NSClipView?
    private weak var observedDocument: NSView?
    private var observations: [NSObjectProtocol] = []
    private var pending = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
    override func layout() { super.layout(); scheduleUpdate() }
    func stop() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        observedClip = nil; observedDocument = nil
    }
    func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard let scroll = self.enclosingScrollView, self.window != nil else { self.stop(); return }
            let clip = scroll.contentView
            if self.observedClip !== clip || self.observedDocument !== scroll.documentView {
                self.stop()
                self.observedClip = clip; self.observedDocument = scroll.documentView
                clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
                scroll.documentView?.postsFrameChangedNotifications = true
                let changes: [(Notification.Name, NSView?)] = [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip), (NSView.frameDidChangeNotification, scroll.documentView)]
                for (name, view) in changes {
                    guard let view else { continue }
                    self.observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
                }
            }
            self.controller?.update(scroll)
        }
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

struct TMDBMatchSheet: View {
    @ObservedObject var metadata: TMDBDetailModel
    let originalTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var type = ""
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("tmdb.match.title", fallback: "Match Movie or Series")).font(.title2.weight(.semibold))
                    Text(originalTitle).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L10n.string("common.done", fallback: "Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(metadata.isChoosing)
            }
            HStack {
                TextField(L10n.string("tmdb.search.placeholder", fallback: "Chinese or original title"), text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Picker(L10n.string("tmdb.type", fallback: "Type"), selection: $type) {
                    Text(L10n.string("tmdb.all-types", fallback: "All Types")).tag("")
                    Text(L10n.string("tmdb.movie", fallback: "Movie")).tag("movie")
                    Text(L10n.string("tmdb.tv", fallback: "TV Series")).tag("tv")
                }.frame(width: 150)
                Button(L10n.string("tmdb.search", fallback: "Search"), action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || metadata.isChoosing)
            }
            if metadata.needsMatchConfirmation {
                Text(L10n.string("tmdb.match.pending-help", fallback: "Candidates found. Review the title, year and director to confirm the correct work."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if metadata.isSearching || metadata.isChoosing { ProgressView().controlSize(.small) }
            if let error = metadata.actionError { Text(error).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(metadata.candidates) { candidate in
                        Button {
                            searchTask?.cancel()
                            searchTask = Task { if await metadata.choose(candidate) { dismiss() } }
                        } label: {
                            HStack(alignment: .top, spacing: 14) {
                                RemoteImageCandidates(urls: [metadata.imageURL(candidate.work.posterPath, kind: .poster)].compactMap { $0 }) { image in image.resizable().scaledToFill() }
                                    placeholder: { Color.secondary.opacity(0.12) }
                                    .frame(width: 60, height: 88).clipped().cornerRadius(6)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(candidate.work.displayTitle).font(.headline)
                                    Text([candidate.work.originalTitle ?? candidate.work.originalName,
                                          candidate.work.year.map(String.init),
                                          candidate.reference.type == .movie ? L10n.string("tmdb.movie", fallback: "Movie") : L10n.string("tmdb.tv", fallback: "TV Series")].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !candidate.work.directors.isEmpty {
                                        Text(L10n.string("detail.director", fallback: "Director") + ": " + candidate.work.directors.map(\.name).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    if !candidate.work.cast.isEmpty { Text(candidate.work.cast.prefix(3).map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                    if let overview = candidate.work.overview { Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.06)).cornerRadius(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(metadata.isChoosing)
                    }
                }
                if metadata.candidates.isEmpty && !metadata.isSearching {
                    Text(L10n.string("tmdb.search.hint", fallback: "Search by title, then choose the correct year and type. Playback always uses your original source."))
                        .foregroundStyle(.secondary).padding(.vertical, 35)
                }
            }
            TMDBAttributionView()
        }.padding(24).frame(width: 690, height: 570)
        .background(AppSurfacePalette.background)
        .onAppear { query = TMDBTitleNormalizer.clean(originalTitle) }
        .onDisappear { searchTask?.cancel() }
    }
    private func search() {
        searchTask?.cancel()
        let requestedQuery = query, requestedType = TMDBMediaType(rawValue: type)
        searchTask = Task { await metadata.search(requestedQuery, type: requestedType) }
    }
}

private extension String {
    var tmdbNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Artwork identity contains only the image URL and display bucket, never a
/// provider, stream, episode resource ID, or signed playback address.
struct TMDBArtworkView<Content: View, Placeholder: View>: View {
    let urls: [URL]
    let pixels: Int
    let priority: PosterImagePriority
    var onDisplayed: (URL) -> Void = { _ in }
    @ViewBuilder let content: (Image, Bool) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @Environment(\.imageRepository) private var repository
    @State private var loaded: NSImage?
    @State private var loadedURL: URL?
    private func request(_ url: URL) -> PosterImageRequest { .init(url: url, pixels: pixels) }
    private var shown: (NSImage, URL)? {
        for url in urls {
            if let cached = repository?.cachedPoster(for: request(url)) { return (cached, url) }
            if loadedURL == url, let loaded { return (loaded, url) }
        }
        return nil
    }
    var body: some View {
        Group {
            if let (image, url) = shown { content(Image(nsImage: image), url != urls.first) }
            else { placeholder() }
        }
        .onAppear { if let shown { onDisplayed(shown.1) } }
        .onChange(of: shown?.1) { if let url = $0 { onDisplayed(url) } }
        .task(id: urls.map(\.absoluteString).joined(separator: "|") + ":\(pixels)") {
            guard let repository else { return }
            if let shown { loaded = shown.0; loadedURL = shown.1 }
            else { loaded = nil; loadedURL = nil }
            // A lower-quality cache hit is a placeholder, not the end of the job.
            for url in urls {
                guard !Task.isCancelled else { return }
                if let image = repository.cachedPoster(for: request(url)) { loaded = image; loadedURL = url; return }
                do {
                    let image = try await repository.posterImage(for: request(url), priority: priority)
                    guard !Task.isCancelled else { return }; loaded = image; loadedURL = url; return
                } catch { if Task.isCancelled { return } }
            }
        }
    }
}

struct TMDBRelatedPageView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var browser: TMDBRelatedBrowser
    @ObservedObject var page: TMDBRelatedPage
    let active: Bool
    var body: some View {
        Group {
            if page.kind == .detail, let detail = page.detail {
                DetailView(detail: detail, metadata: page.metadata)
            } else if active {
                VStack(spacing: 0) {
                    if page.kind == .person {
                        HStack {
                            Text(page.title).font(.title2.weight(.semibold))
                            Spacer()
                            Picker(L10n.string("tmdb.person.filter", fallback: "Works"), selection: $page.filter) {
                                Text(L10n.string("tmdb.person.all", fallback: "All")).tag("all")
                                Text(L10n.string("tmdb.person.movies", fallback: "Movies")).tag("movie")
                                Text(L10n.string("tmdb.person.tv", fallback: "TV Shows")).tag("tv")
                            }.pickerStyle(.segmented).frame(maxWidth: 270)
                        }.padding(.horizontal, 28).padding(.vertical, 16)
                    } else if page.kind == .search {
                        HStack {
                            Text(L10n.string("tmdb.person.search-all", fallback: "Search “%@” across all sites in the current configuration", page.title)).font(.callout)
                            Spacer()
                            if page.isLoading { ProgressView().controlSize(.small) }
                            Text("\(page.completedSites) / \(page.totalSites)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 28).padding(.vertical, 16)
                    }
                    if let error = page.error {
                        HStack { Text(error).font(.callout); Button(L10n.string("common.retry", fallback: "Retry")) { browser.load(page, state: state, refresh: true) } }
                            .padding(16)
                    }
                    if page.items.isEmpty {
                        if page.isLoading {
                            VStack(spacing: 16) {
                                ProgressView().controlSize(.small)
                                Text(L10n.string("common.loading", fallback: "Loading")).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text(L10n.string("tmdb.person.empty", fallback: "No matching titles found."))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        PosterNativePage(items: page.items,
                            headerKey: .init(categories: [], selectedCategoryID: nil, showsRecommendations: false, filterSelection: [:]),
                            headerHeight: 0, activeFilters: [],
                            footerKey: .init(hasMore: page.kind == .person ? page.displayedCount < page.filteredWorks.count : page.hasMore,
                                isLoading: page.isLoading, isRefreshing: false, errorMessage: page.error, itemCount: page.items.count, hasPendingUpdate: false),
                            nextPage: page.nextPage, initialAnchor: page.anchor, presentationRevision: page.revision,
                            onCategorySelect: { _ in }, onFilterReset: { _ in }, onClearFilters: {}, onAcceptUpdate: {},
                            onBrowse: { anchor, _, _ in page.anchor = anchor },
                            onLoad: { await browser.loadMore(page, state: state) },
                            onSelect: { browser.select($0, page: page, state: state) })
                            .id(page.filter)
                    }
                    if page.kind == .person { TMDBAttributionView().padding(.horizontal, 28).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurfacePalette.background)
        .onChange(of: page.filter) { _ in page.anchor = nil; page.displayedCount = 48 }
    }
}
struct TMDBRelatedRefreshButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var browser: TMDBRelatedBrowser
    @ObservedObject var page: TMDBRelatedPage
    var body: some View {
        DetailRefreshButton(isLoading: page.isLoading) { browser.load(page, state: state, refresh: true) }
    }
}


/// Native menu actions are shared by the detail toolbar and hero controls.
@MainActor enum TMDBDetailMenuItem {
    case action(String, enabled: Bool = true, () -> Void)
    case status(String)
    case separator
}

struct TMDBNativeActionButton: NSViewRepresentable {
    let title: String
    var symbol: String? = nil
    let identifier: String
    var prominent = false
    var help: String? = nil
    var menuItems: [TMDBDetailMenuItem] = []
    var action: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TMDBActionSurface {
        let surface = TMDBActionSurface()
        surface.button.target = context.coordinator
        surface.button.action = #selector(Coordinator.activate(_:))
        return surface
    }
    func updateNSView(_ surface: TMDBActionSurface, context: Context) {
        context.coordinator.action = action
        context.coordinator.menuItems = menuItems
        surface.configure(title: title, symbol: symbol, prominent: prominent, enabled: isEnabled,
            help: help, identifier: identifier)
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void = {}
        var menuItems: [TMDBDetailMenuItem] = []
        func makeMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            for (index, item) in menuItems.enumerated() {
                switch item {
                case let .action(title, enabled, _):
                    let entry = NSMenuItem(title: title, action: #selector(selectItem(_:)), keyEquivalent: "")
                    entry.target = self; entry.tag = index; entry.isEnabled = enabled
                    menu.addItem(entry)
                case let .status(title):
                    let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    entry.isEnabled = false; menu.addItem(entry)
                case .separator: menu.addItem(.separator())
                }
            }
            return menu
        }
        @objc func activate(_ sender: NSButton) {
            guard !menuItems.isEmpty else { action(); return }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY), in: sender)
        }
        @objc private func selectItem(_ sender: NSMenuItem) {
            guard menuItems.indices.contains(sender.tag),
                  case let .action(_, enabled, perform) = menuItems[sender.tag], enabled else { return }
            perform()
        }
    }
}


/// NSBox and NSVisualEffectView supply the surface; NSButton retains native
/// input, accessibility and pressed feedback. No custom drawing or hover animation.
/// Keeping the material active avoids changing the palette when another window opens.
final class TMDBActionSurface: NSView {
    let button = NSButton()
    let solidSurface = NSBox()
    let materialSurface = NSVisualEffectView()
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        solidSurface.boxType = .custom
        solidSurface.borderType = .noBorder
        solidSurface.borderWidth = 0
        solidSurface.fillColor = .white
        solidSurface.cornerRadius = 9
        solidSurface.contentViewMargins = .zero
        materialSurface.material = .menu
        materialSurface.blendingMode = .withinWindow
        materialSurface.state = .active
        materialSurface.appearance = NSAppearance(named: .aqua)
        materialSurface.alphaValue = 0.35
        materialSurface.wantsLayer = true
        materialSurface.layer?.cornerRadius = 9
        materialSurface.layer?.masksToBounds = true
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.alignment = .center
        button.appearance = NSAppearance(named: .aqua)
        button.contentTintColor = .black
        button.font = .systemFont(ofSize: 14, weight: .bold)
        addSubview(solidSurface); addSubview(materialSurface); addSubview(button)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        solidSurface.frame = bounds
        materialSurface.frame = bounds
        button.frame = bounds
    }
    func configure(title: String, symbol: String?, prominent: Bool, enabled: Bool, help: String?, identifier: String) {
        solidSurface.isHidden = !prominent
        materialSurface.isHidden = prominent
        button.title = symbol == nil ? title : ""
        if symbol == nil {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.black, .paragraphStyle: paragraph
            ])
        }
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .bold)) }
        button.imagePosition = symbol == nil ? .noImage : .imageOnly
        button.isEnabled = enabled
        button.toolTip = symbol == nil ? nil : (help ?? title)
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }
}
