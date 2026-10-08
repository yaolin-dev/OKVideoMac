import AppKit
import Foundation
import OKVideoCore
import SwiftUI

private enum DetailPageLayout {
    static let maximumContentWidth: CGFloat = 1600
    static let horizontalPadding: CGFloat = 28
    static let readingWidth: CGFloat = 620
    static let posterWidth: CGFloat = 192
    static let coordinateSpaceName = "browser-detail-scroll"
}

struct DetailLoadingView: View {
    let summary: VideoSummary

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                BrowserToolbarScrollMarker(
                    coordinateSpaceName: DetailPageLayout.coordinateSpaceName
                )
                DetailHeroHeader(summary: summary, availableWidth: min(viewport.size.width, DetailPageLayout.maximumContentWidth), description: {
                    DetailRequestStatusView()
                    .padding(.top, 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.loading-status")
                }, actions: {
                    Color.clear.frame(height: 32).accessibilityHidden(true)
                })
                .frame(maxWidth: DetailPageLayout.maximumContentWidth)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .browserToolbarScrollSurface(named: DetailPageLayout.coordinateSpaceName)
        }
        .background(AppSurfacePalette.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
    }
}

struct DetailRequestStatusView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.detailLoadState == .loading {
                HStack(spacing: 12) {
                    AppActivityIndicator(size: .regular)
                    Text(L10n.string("detail.loading", fallback: "Loading details and streams…"))
                }
            } else if let message = state.detailLoadState.message {
                Text(message).textSelection(.enabled)
                HStack {
                    Button(L10n.string("common.retry", fallback: "Retry")) {
                        Task { await state.refreshDetail() }
                    }
                    .disabled(state.isRefreshingDetail)
                    if state.detailSuggestedSearch != nil {
                        Button(L10n.string("detail.continue-search", fallback: "Continue Searching")) {
                            state.continueDetailSearch()
                        }
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("detail.request-status")
    }
}

/// A secondary action beside the primary Play button.
struct DetailFavoriteButton: View {
    @EnvironmentObject private var state: AppState
    let detail: VideoDetail

    private var isFavorite: Bool {
        state.isFavorite(detail)
    }

    private var title: String {
        isFavorite
            ? L10n.string("detail.unfavorite", fallback: "Remove from Favorites")
            : L10n.string("detail.favorite", fallback: "Add to Favorites")
    }

    var body: some View {
        Button {
            let desired = !isFavorite
            Task { await state.setFavorite(detail, isFavorite: desired) }
        } label: {
            Label(title, systemImage: isFavorite ? "star.fill" : "star")
        }
        .disabled(!state.canChangeFavorite(detail))
        .help(title)
        .accessibilityLabel(title)
        if state.pendingFavoriteRepairID != nil {
            Button(L10n.string("favorites.repair.link", fallback: "Associate with Saved Favorite")) { state.confirmFavoriteRepair(detail) }
            Button(L10n.string(.commonCancel)) { state.cancelFavoriteRepair() }
        }
    }
}

/// Default system control: no custom timeline or rotation animation.
struct DetailRefreshButton: NSViewRepresentable {
    let isLoading: Bool
    var title: String = L10n.string("common.refresh", fallback: "Refresh")
    let action: () -> Void

    func makeNSView(context: Context) -> DetailRefreshControl {
        let view = DetailRefreshControl()
        view.update(isLoading: isLoading, title: title, action: action)
        return view
    }

    func updateNSView(_ view: DetailRefreshControl, context: Context) {
        view.update(isLoading: isLoading, title: title, action: action)
    }
}

/// Keep a single toolbar view across state changes. Replacing a SwiftUI
/// toolbar's root Button with ProgressView can leave its AppKit item stale.
final class DetailRefreshControl: NSView {
    let refreshButton = NSButton()
    let progressIndicator = NSProgressIndicator()
    private var onRefresh: () -> Void = {}

    init() {
        let size = PrimaryToolbarMetrics.iconControlSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        refreshButton.title = ""
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.isBordered = false
        refreshButton.imagePosition = .imageOnly
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.toolTip = L10n.string("common.refresh", fallback: "Refresh")
        refreshButton.setAccessibilityLabel(refreshButton.toolTip)
        refreshButton.setAccessibilityIdentifier("detail.refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel(L10n.string("browser.refresh.loading", fallback: "Loading…"))
        for child in [refreshButton, progressIndicator] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.centerXAnchor.constraint(equalTo: centerXAnchor),
                child.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            refreshButton.widthAnchor.constraint(equalToConstant: size),
            refreshButton.heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: PrimaryToolbarMetrics.iconControlSize, height: PrimaryToolbarMetrics.iconControlSize)
    }

    func update(isLoading: Bool, title: String = L10n.string("common.refresh", fallback: "Refresh"), action: @escaping () -> Void) {
        onRefresh = action
        refreshButton.toolTip = title
        refreshButton.setAccessibilityLabel(title)
        refreshButton.isHidden = isLoading
        refreshButton.isEnabled = !isLoading
        progressIndicator.isHidden = !isLoading
        if isLoading { progressIndicator.startAnimation(nil) }
        else { progressIndicator.stopAnimation(nil) }
    }

    @objc private func refresh() { onRefresh() }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    let detail: VideoDetail
    @AppStorage("detail.lastPlaySourceName") private var lastPlaySourceName = ""
    @State private var selectedSourceIndex = 0
    @State private var episodeSearchKeyword = ""
    @State private var episodeSortOrder: EpisodeSortOrder = .sourceOrder
    @State private var selectedRangeID: String?
    @State private var preparedPresentations: [EpisodePresentation] = []
    @State private var preparedRangeOptions: [EpisodeRangeOption] = []
    @State private var isPreparingEpisodes = false
    @State private var showsAllActors = false
    @State private var showsFullSynopsis = false

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                BrowserToolbarScrollMarker(
                    coordinateSpaceName: DetailPageLayout.coordinateSpaceName
                )
                VStack(alignment: .leading, spacing: 0) {
                    detailHero(availableWidth: min(viewport.size.width, DetailPageLayout.maximumContentWidth))

                    if !detailFacts.isEmpty {
                        Divider().padding(.horizontal, DetailPageLayout.horizontalPadding)
                        detailFactStrip(availableWidth: min(viewport.size.width, DetailPageLayout.maximumContentWidth))
                    }

                    Divider().padding(.horizontal, DetailPageLayout.horizontalPadding)

                    if detail.playSources.isEmpty {
                        EmptyStateView(
                            systemImage: "play.slash",
                            title: L10n.string("detail.no-streams.title", fallback: "No Streams"),
                            message: L10n.string("detail.no-streams.message", fallback: "This provider did not return any playable episodes.")
                        )
                        .frame(minHeight: 260)
                    } else {
                        playbackBrowser
                    }
                }
                .frame(maxWidth: DetailPageLayout.maximumContentWidth)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 30)
            }
            .browserToolbarScrollSurface(named: DetailPageLayout.coordinateSpaceName)
        }
        .background(AppSurfacePalette.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .onAppear {
            performInitialSelection()
            // Report after SwiftUI has mounted the real detail tree and the
            // main run loop gets its next display opportunity.
            DispatchQueue.main.async {
                state.recordDetailFirstRender(detail)
            }
        }
        .task(id: "\(state.detailRevision):\(selectedSource?.id ?? "")") {
            await prepareSelectedSourceEpisodes()
        }
        .onChange(of: state.detailRevision) { _ in
            DispatchQueue.main.async { state.recordDetailFirstRender(detail) }
            if let index = detail.playSources.firstIndex(where: { $0.name == lastPlaySourceName }) {
                if selectedSourceIndex != index { selectedSourceIndex = index }
            } else { performInitialSelection() }
        }
        .onChange(of: selectedSourceIndex) { newValue in
            guard detail.playSources.indices.contains(newValue) else { return }
            lastPlaySourceName = detail.playSources[newValue].name
            episodeSearchKeyword = ""
            episodeSortOrder = .sourceOrder
            selectedRangeID = nil
            preparedPresentations = []
            preparedRangeOptions = []
            isPreparingEpisodes = true
        }
    }

    private func detailHero(availableWidth: CGFloat) -> some View {
        DetailHeroHeader(summary: detail.summary, availableWidth: availableWidth, description: {
            detailDescription
        }, actions: {
            HStack(spacing: 10) {
                Button(action: playPrimaryEpisode) {
                    Label(L10n.string("common.play", fallback: "Play"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(primaryEpisode == nil)
                .help(
                    primaryEpisode == nil
                        ? L10n.string("detail.no-playable-episode", fallback: "No playable episodes")
                        : L10n.string("detail.play-first", fallback: "Play the first available episode")
                )
                DetailFavoriteButton(detail: detail)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .accessibilityIdentifier("detail.primary-actions")
        })
    }

    private var detailDescription: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let synopsis = detail.synopsis?.trimmedNonEmpty {
                DetailSummaryText(title: L10n.string("detail.synopsis-title", fallback: "Synopsis"), text: synopsis, lines: 3,
                    isExpanded: $showsFullSynopsis)
                    .accessibilityIdentifier("detail.synopsis")
            }
            if let actors = displayActors {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("detail.cast", fallback: "Cast"))
                        .font(.callout.weight(.semibold))
                    DetailSummaryText(title: L10n.string("detail.cast", fallback: "Cast"), text: actors, lines: 1,
                        isExpanded: $showsAllActors)
                }
            }

        }
        .frame(maxWidth: DetailPageLayout.readingWidth, alignment: .leading)
    }

    private func detailFactStrip(availableWidth: CGFloat) -> some View {
        let facts = detailFacts
        let cellWidth = max(154, (availableWidth - 2 * DetailPageLayout.horizontalPadding) / CGFloat(max(1, facts.count)))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    DetailFactCell(fact: fact)
                        .frame(width: cellWidth)
                        .overlay(alignment: .trailing) {
                            if index < facts.count - 1 {
                                Color(nsColor: .separatorColor).frame(width: 1, height: 54)
                            }
                        }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, DetailPageLayout.horizontalPadding)
        }
    }

    private var displayActors: String? {
        SpiderDisplayTextNormalizer.people(detail.actors)
    }

    private var playbackBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.string("detail.streams", fallback: "Streams"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.string("detail.stream-count", fallback: "%d streams", detail.playSources.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                ScrollViewReader { sourceProxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(detail.playSources.indices, id: \.self) { index in
                                Button {
                                    selectedSourceIndex = index
                                } label: {
                                    HStack(spacing: 6) {
                                        if selectedSourceIndex == index {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(detail.playSources[index].name)
                                        Text("\(detail.playSources[index].episodes.count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(
                                                selectedSourceIndex == index
                                                    ? .white.opacity(0.8)
                                                    : .secondary
                                            )
                                    }
                                }
                                .buttonStyle(
                                    DetailSourceButtonStyle(
                                        isSelected: selectedSourceIndex == index
                                    )
                                )
                                .accessibilityIdentifier("detail.source.\(index)")
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        sourceProxy.scrollTo(selectedSourceIndex, anchor: .center)
                    }
                    .onChange(of: selectedSourceIndex) { selectedIndex in
                        sourceProxy.scrollTo(selectedIndex, anchor: .center)
                    }
                }

                episodeControls

                if rangeOptions.count > 1 {
                    EpisodeRangePicker(
                        options: rangeOptions,
                        selectedID: $selectedRangeID
                    )
                }
            }
            .padding(.horizontal, DetailPageLayout.horizontalPadding)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, DetailPageLayout.horizontalPadding)

            episodeContent
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var episodeControls: some View {
        if let source = selectedSource, source.episodes.count > 1 {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(L10n.string("detail.episode-search", fallback: "Search episodes or original names"), text: $episodeSearchKeyword)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: 360, minHeight: 30)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18))
                }

                Spacer(minLength: 8)

                Picker(L10n.string("common.sort", fallback: "Sort"), selection: $episodeSortOrder) {
                    ForEach(EpisodeSortOrder.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 126)
                .disabled(!canSortEpisodes)
                .help(
                    canSortEpisodes
                        ? L10n.string("detail.sort.available", fallback: "Sort using reliably detected episode numbers")
                        : L10n.string("detail.sort.unavailable", fallback: "This stream does not contain enough reliable episode numbers")
                )
            }
        }
    }

    @ViewBuilder
    private var episodeContent: some View {
        let visible = filteredPresentations
        let regular = visible.filter { $0.episodeNumber != nil }
        let other = visible.filter { $0.episodeNumber == nil }
        if isPreparingEpisodes {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text(L10n.string("detail.organizing-episodes", fallback: "Organizing %d episodes…", selectedSource?.episodes.count ?? 0))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if visible.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: L10n.string("detail.no-matching-episodes.title", fallback: "No Matching Episodes"),
                message: L10n.string("detail.no-matching-episodes.message", fallback: "Try another search term or episode range.")
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if !regular.isEmpty {
                    EpisodeSection(
                        title: L10n.string("detail.episodes", fallback: "Episodes"),
                        episodes: regular,
                        onPlay: playSelectedEpisode
                    )
                }

                if !other.isEmpty {
                    EpisodeSection(
                        title: isSingleEpisode
                            ? L10n.string("common.play", fallback: "Play")
                            : regular.isEmpty
                                ? L10n.string("detail.playable-resources", fallback: "Playable Resources")
                                : L10n.string("detail.other-resources", fallback: "Other Resources"),
                        episodes: other,
                        onPlay: playSelectedEpisode
                    )
                }
            }
            .padding(.horizontal, DetailPageLayout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private var detailFacts: [DetailFact] {
        var facts = [
            DetailFact(
                title: L10n.string("detail.provider", fallback: "Provider"),
                value: detail.summary.siteName,
                systemImage: "network"
            )
        ]
        if let area = detail.area?.trimmedNonEmpty {
            facts.append(DetailFact(title: L10n.string("detail.area", fallback: "Region"),
                value: area, systemImage: "globe"))
        }
        if let director = SpiderDisplayTextNormalizer.people(detail.director) {
            facts.append(DetailFact(title: L10n.string("detail.director", fallback: "Director"),
                value: director, systemImage: "person"))
        }
        if let year = detail.summary.year?.trimmedNonEmpty {
            facts.append(
                DetailFact(title: L10n.string("detail.year", fallback: "Year"), value: year, systemImage: "calendar")
            )
        }
        if let category = detail.summary.categoryName?.trimmedNonEmpty {
            facts.append(
                DetailFact(title: L10n.string("detail.genre", fallback: "Genre"), value: category, systemImage: "tag")
            )
        }
        if let remarks = VideoCardMetadata.secondaryText(
            from: detail.summary.remarks
        ) {
            facts.append(
                DetailFact(
                    title: L10n.string("common.status", fallback: "Status"),
                    value: remarks,
                    systemImage: "text.badge.checkmark"
                )
            )
        }
        facts.append(
            DetailFact(
                title: L10n.string("detail.streams", fallback: "Streams"),
                value: "\(detail.playSources.count)",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        )
        return facts
    }

    private var selectedSource: PlaySource? {
        guard detail.playSources.indices.contains(selectedSourceIndex) else {
            return detail.playSources.first
        }
        return detail.playSources[selectedSourceIndex]
    }

    private var isSingleEpisode: Bool {
        selectedSource?.episodes.count == 1
    }

    private var allPresentations: [EpisodePresentation] {
        EpisodeListPresentation.filterAndSort(
            preparedPresentations,
            query: episodeSearchKeyword,
            sortOrder: episodeSortOrder
        )
    }

    private var filteredPresentations: [EpisodePresentation] {
        guard let selectedRangeID,
              let option = rangeOptions.first(where: { $0.id == selectedRangeID }) else {
            return allPresentations
        }
        return allPresentations.filter {
            $0.episodeNumber == nil || option.episodeIDs.contains($0.id)
        }
    }

    private var rangeOptions: [EpisodeRangeOption] {
        preparedRangeOptions
    }

    private var canSortEpisodes: Bool {
        allPresentations.lazy.filter { $0.episodeNumber != nil }.prefix(2).count == 2
    }

    private var primaryEpisode: PlayEpisode? {
        selectedSource?.episodes.first
    }

    private func performInitialSelection() {
        guard !detail.playSources.isEmpty else { return }
        if let index = detail.playSources.firstIndex(where: {
            $0.name == lastPlaySourceName
        }) {
            selectedSourceIndex = index
        } else {
            selectedSourceIndex = 0
        }
    }

    @MainActor
    private func prepareSelectedSourceEpisodes() async {
        guard let source = selectedSource else {
            preparedPresentations = []
            preparedRangeOptions = []
            isPreparingEpisodes = false
            return
        }
        let sourceID = source.id
        isPreparingEpisodes = true
        let snapshot = await EpisodePresentationRepository.shared.snapshot(
            videoID: detail.summary.id,
            source: source,
            categoryName: detail.summary.categoryName
        )
        guard !Task.isCancelled, selectedSource?.id == sourceID else { return }
        preparedPresentations = snapshot.values
        preparedRangeOptions = snapshot.rangeOptions
        if let rangeID = selectedRangeID,
           !snapshot.rangeOptions.contains(where: { $0.id == rangeID }) {
            selectedRangeID = nil
        }
        if selectedRangeID == nil,
           EpisodeInitialRangePolicy.shouldSelectRecentRange(
               episodeCount: snapshot.values.count,
               rangeCount: snapshot.rangeOptions.count
           ) {
            selectedRangeID = snapshot.rangeOptions.last?.id
        }
        isPreparingEpisodes = false
    }

    private func playSelectedEpisode(_ presentation: EpisodePresentation) {
        guard let source = selectedSource else { return }
        play(source: source, episode: presentation.episode)
    }

    private func playPrimaryEpisode() {
        guard let source = selectedSource,
              let episode = source.episodes.first else { return }
        play(source: source, episode: episode)
    }

    private func play(source: PlaySource, episode: PlayEpisode) {
        Task {
            await state.startPlayback(
                detail: detail,
                source: source,
                episode: episode
            )
        }
    }
}

private struct DetailPosterView: View {
    let summary: VideoSummary

    var body: some View {
        VideoPosterView(item: summary)
            .compositingGroup()
            .shadow(color: .black.opacity(0.10), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.20), radius: 15, y: 9)
    }
}

private struct DetailFact: Identifiable {
    let title: String
    let value: String
    let systemImage: String

    var id: String { "\(title):\(value)" }
}

private struct DetailFactCell: View {
    let fact: DetailFact

    var body: some View {
        VStack(spacing: 5) {
            Label(fact.title, systemImage: fact.systemImage)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(fact.value)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 54)
        .help(fact.value)
    }
}

private struct DetailMetadataBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.09), in: Capsule())
    }
}

private struct DetailExpandButton: View {
    let isExpanded: Bool
    let expandTitle: String
    let collapseTitle: String
    let action: () -> Void

    var body: some View {
        Button(isExpanded ? collapseTitle : expandTitle, action: action)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .appInteractiveHover(cornerRadius: 6)
    }
}

private struct DetailSourceButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        DetailSourceButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct DetailSourceButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundColor(isSelected ? .white : .primary)
            .background(
                isSelected
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                    : isHovering
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.09),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isHovering
                            ? (isSelected
                                ? Color.white.opacity(0.18)
                                : Color.secondary.opacity(0.18))
                            : Color.secondary.opacity(isSelected ? 0 : 0.16),
                        lineWidth: 1
                    )
            }
            .scaleEffect(
                configuration.isPressed ? 0.98 : (isHovering ? 1.018 : 1)
            )
            .shadow(
                color: Color.black.opacity(isHovering ? 0.18 : 0),
                radius: isHovering ? 10 : 0,
                y: isHovering ? 5 : 0
            )
            .zIndex(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

enum EpisodeSortOrder: String, CaseIterable, Identifiable {
    case sourceOrder
    case episodeAscending
    case episodeDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sourceOrder:
            return L10n.string("detail.sort.source-order", fallback: "Provider Order")
        case .episodeAscending:
            return L10n.string("detail.sort.episode-ascending", fallback: "Episode Number: Ascending")
        case .episodeDescending:
            return L10n.string("detail.sort.episode-descending", fallback: "Episode Number: Descending")
        }
    }
}

struct EpisodePresentation: Identifiable, Equatable, Sendable {
    let episode: PlayEpisode
    let displayName: String
    let originalName: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let isSpecial: Bool
    let sourceIndex: Int

    var id: String { episode.id }
}

struct EpisodeRangeOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let episodeIDs: Set<String>
}

struct EpisodePresentationSnapshot: Sendable {
    let values: [EpisodePresentation]
    let valuesByEpisodeID: [String: EpisodePresentation]
    let rangeOptions: [EpisodeRangeOption]
    let playbackOrder: [PlayEpisode]
    let versionOrders: [String: [PlayEpisode]]
    let navigation: PlayerEpisodeNavigationIndex
}

private struct EpisodePresentationRepositoryKey: Hashable, Sendable {
    let rulesVersion: Int = PlaybackResourceAnalyzer.rulesVersion
    let localeIdentifier: String = L10n.locale.identifier
    let categoryName: String?
    let videoID: String
    let sourceID: String
    let episodeCount: Int
    let firstEpisodeID: String?
    let lastEpisodeID: String?
}

actor EpisodePresentationRepository {
    static let shared = EpisodePresentationRepository()

    private struct CachedSnapshot {
        let source: PlaySource
        let snapshot: EpisodePresentationSnapshot
    }
    private var snapshots: [
        EpisodePresentationRepositoryKey: CachedSnapshot
    ] = [:]
    private let capacity = 24

    func snapshot(
        videoID: String,
        source: PlaySource,
        categoryName: String? = nil
    ) -> EpisodePresentationSnapshot {
        let key = EpisodePresentationRepositoryKey(
            categoryName: categoryName,
            videoID: videoID,
            sourceID: source.id,
            episodeCount: source.episodes.count,
            firstEpisodeID: source.episodes.first?.id,
            lastEpisodeID: source.episodes.last?.id
        )
        if let cached = snapshots[key], cached.source == source {
            return cached.snapshot
        }

        let values = EpisodeListPresentation.presentations(
            from: source.episodes,
            query: "",
            sortOrder: .sourceOrder,
            categoryName: categoryName
        )
        let snapshot = EpisodePresentationSnapshot(
            values: values,
            valuesByEpisodeID: Dictionary(
                values.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            ),
            rangeOptions: EpisodeListPresentation.rangeOptions(from: values),
            playbackOrder: PlayerEpisodeAdvancePolicy.orderedEpisodes(in: source.episodes, categoryName: categoryName),
            versionOrders: PlayerEpisodeAdvancePolicy.versionOrders(in: source.episodes, categoryName: categoryName),
            navigation: PlayerEpisodeNavigationIndex(episodes: source.episodes, categoryName: categoryName)
        )
        if snapshots.count >= capacity, let oldestKey = snapshots.keys.first {
            snapshots.removeValue(forKey: oldestKey)
        }
        snapshots[key] = CachedSnapshot(source: source, snapshot: snapshot)
        return snapshot
    }
}

enum EpisodeInitialRangePolicy {
    static let largeEpisodeThreshold = 200

    static func shouldSelectRecentRange(
        episodeCount: Int,
        rangeCount: Int
    ) -> Bool {
        episodeCount > largeEpisodeThreshold && rangeCount > 1
    }
}

private struct EpisodeRangePicker: View {
    let options: [EpisodeRangeOption]
    @Binding var selectedID: String?

    private var presentationMode: EpisodeRangePickerPresentationMode {
        EpisodeRangePickerPolicy.presentationMode(optionCount: options.count)
    }

    var body: some View {
        switch presentationMode {
        case .chips:
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 7) {
                    rangeButton(title: L10n.string("common.all", fallback: "All"), id: nil)
                    ForEach(options) { option in
                        rangeButton(title: option.title, id: option.id)
                    }
                }
                .padding(.trailing, 4)
            }
        case .compactMenu:
            compactPicker
        }
    }

    private var compactPicker: some View {
        HStack(spacing: 8) {
            rangeButton(title: L10n.string("common.all", fallback: "All"), id: nil)

            Text(L10n.string("detail.episode-range", fallback: "Episode Range"))
                .font(.caption)
                .foregroundColor(.secondary)

            Picker(L10n.string("detail.episode-range", fallback: "Episode Range"), selection: $selectedID) {
                Text(L10n.string("detail.choose-range", fallback: "Choose a Range")).tag(String?.none)
                ForEach(options) { option in
                    Text(option.title).tag(Optional(option.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)

            Button {
                selectedID = EpisodeRangePickerPolicy.adjacentID(
                    options: options,
                    selectedID: selectedID,
                    offset: -1
                )
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!EpisodeRangePickerPolicy.canMove(
                options: options,
                selectedID: selectedID,
                offset: -1
            ))
            .help(L10n.string("detail.previous-range", fallback: "Previous Episode Range"))

            Button {
                selectedID = EpisodeRangePickerPolicy.adjacentID(
                    options: options,
                    selectedID: selectedID,
                    offset: 1
                )
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!EpisodeRangePickerPolicy.canMove(
                options: options,
                selectedID: selectedID,
                offset: 1
            ))
            .help(L10n.string("detail.next-range", fallback: "Next Episode Range"))

            Spacer(minLength: 0)
        }
    }

    private func rangeButton(title: String, id: String?) -> some View {
        let isSelected = selectedID == id
        return Button(title) {
            selectedID = id
        }
        .buttonStyle(.plain)
        .font(.caption.weight(isSelected ? .semibold : .regular))
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.09),
            in: Capsule()
        )
        .appInteractiveHover(cornerRadius: 14, selected: isSelected)
    }
}

enum EpisodeRangePickerPresentationMode: Equatable {
    case chips
    case compactMenu
}

enum EpisodeRangePickerPolicy {
    static let compactThreshold = 8

    static func presentationMode(
        optionCount: Int
    ) -> EpisodeRangePickerPresentationMode {
        optionCount > compactThreshold ? .compactMenu : .chips
    }

    static func canMove(
        options: [EpisodeRangeOption],
        selectedID: String?,
        offset: Int
    ) -> Bool {
        adjacentID(
            options: options,
            selectedID: selectedID,
            offset: offset
        ) != selectedID
    }

    static func adjacentID(
        options: [EpisodeRangeOption],
        selectedID: String?,
        offset: Int
    ) -> String? {
        guard !options.isEmpty, offset != 0 else { return selectedID }
        guard let selectedID else {
            return offset > 0 ? options.first?.id : nil
        }
        guard let index = options.firstIndex(where: { $0.id == selectedID }) else {
            return offset > 0 ? options.first?.id : nil
        }
        let target = index + offset
        guard options.indices.contains(target) else { return selectedID }
        return options[target].id
    }
}

private struct EpisodeSection: View {
    let title: String
    let episodes: [EpisodePresentation]
    let onPlay: (EpisodePresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.headline)
                Text("\(episodes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(episodes) { presentation in
                    DetailEpisodeButton(
                        presentation: presentation,
                        onPlay: onPlay
                    )
                }
            }
        }
    }
}

struct DetailEpisodeButton: View {
    let presentation: EpisodePresentation
    let onPlay: (EpisodePresentation) -> Void
    let originalNamePresentationMode: DetailEpisodeOriginalNamePresentationMode = .anchoredPopover

    @ViewBuilder
    var body: some View {
        switch originalNamePresentationMode {
        case .anchoredPopover:
            DetailEpisodeButtonPopoverInteraction(
                presentation: presentation,
                onPlay: onPlay
            )
        }
    }
}

enum DetailEpisodeOriginalNamePresentationMode: Equatable {
    case anchoredPopover
}

private struct DetailEpisodeButtonPopoverInteraction: View {
    let presentation: EpisodePresentation
    let onPlay: (EpisodePresentation) -> Void
    @State private var showsOriginalNamePopover = false

    var body: some View {
        Button {
            onPlay(presentation)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Text(presentation.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DetailEpisodeButtonStyle())
        .contextMenu {
            Button(L10n.string("detail.original-name.view", fallback: "View Original Name…")) {
                DispatchQueue.main.async {
                    showsOriginalNamePopover = true
                }
            }
            Button(L10n.string("detail.original-name.copy", fallback: "Copy Original Name")) {
                DetailEpisodeOriginalNameActions.copy(presentation.originalName)
            }
        }
        .popover(
            isPresented: $showsOriginalNamePopover,
            arrowEdge: .bottom
        ) {
            DetailEpisodeOriginalNamePopover(
                originalName: presentation.originalName,
                onClose: { showsOriginalNamePopover = false }
            )
        }
        .accessibilityLabel(L10n.string("detail.play-episode", fallback: "Play %@", presentation.displayName))
        .accessibilityHint(L10n.string("detail.original-name.hint", fallback: "Right-click to view or copy the original name"))
    }
}

struct DetailEpisodeOriginalNamePopover: View {
    let originalName: String
    let onClose: () -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                Text(L10n.string("detail.file-info", fallback: "File Information"))
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L10n.string("common.close", fallback: "Close"))
                .accessibilityLabel(L10n.string("detail.file-info.close", fallback: "Close File Information"))
            }

            Text(L10n.string("detail.original-name", fallback: "Original Name"))
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                Text(originalName)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
            }
            .frame(minHeight: 42, maxHeight: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }

            HStack(spacing: 10) {
                Button {
                    DetailEpisodeOriginalNameActions.copy(originalName)
                    didCopy = true
                } label: {
                    Label(
                        didCopy
                            ? L10n.string("common.copied", fallback: "Copied")
                            : L10n.string("detail.copy-name", fallback: "Copy Name"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(L10n.string("detail.popover-dismiss-hint", fallback: "Click outside or press Esc to close"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 370)
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

enum DetailEpisodeOriginalNameActions {
    static func copy(
        _ originalName: String,
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(originalName, forType: .string)
    }
}

private struct DetailEpisodeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DetailEpisodeButtonBody(configuration: configuration)
    }
}

private struct DetailEpisodeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 10)
            .frame(minHeight: 31)
            .foregroundColor(.primary)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isHovering
                            ? Color.secondary.opacity(0.18)
                            : Color.secondary.opacity(0.16),
                        lineWidth: 1
                    )
            }
            .scaleEffect(
                configuration.isPressed ? 0.98 : (isHovering ? 1.018 : 1)
            )
            .shadow(
                color: Color.black.opacity(isHovering ? 0.18 : 0),
                radius: isHovering ? 10 : 0,
                y: isHovering ? 5 : 0
            )
            .zIndex(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

enum EpisodeNameParser {
    static func compactName(_ value: String) -> String {
        let name = PlaybackResourceAnalyzer.compactName(value)
        return name.isEmpty ? L10n.string("detail.unnamed-resource", fallback: "Unnamed Resource") : name
    }

    static func presentation(for episode: PlayEpisode, sourceIndex: Int = 0,
                             categoryName: String? = nil, semantics: PlaybackResourceSemantics? = nil) -> EpisodePresentation {
        let value = semantics ?? PlaybackResourceAnalyzer.analyze(episode, categoryName: categoryName)
        var title = compactName(episode.name)
        if value.role == .main, let number = value.episode {
            if let end = value.endEpisode {
                title = value.season.map { L10n.string("episode.range.season", fallback: "Season %d · Episodes %d–%d", $0, number, end) }
                    ?? L10n.string("episode.range", fallback: "Episodes %d–%d", number, end)
            } else if let season = value.season {
                title = L10n.string("episode.season-and-number", fallback: "Season %d · Episode %d", season, number)
            } else {
                title = L10n.string(value.unit == "话" ? "episode.number.chapter" : "episode.number",
                    fallback: value.unit == "话" ? "Chapter %d" : "Episode %d", number)
            }
            if value.finale { title += " · " + L10n.string("episode.finale", fallback: "Finale") }
        } else if value.role == .main, let issue = value.issue {
            title = L10n.string("episode.issue", fallback: "Issue %d", issue)
        } else if let date = value.date {
            title = date
        }
        return EpisodePresentation(episode: episode, displayName: title,
            originalName: episode.name, seasonNumber: value.season,
            episodeNumber: value.role == .main && value.endEpisode == nil ? value.episode : nil,
            isSpecial: value.role != .main, sourceIndex: sourceIndex)
    }
}

enum EpisodeContentPresentationKind: Equatable {
    case movie, series, unknown
    init(categoryName: String?) {
        switch PlaybackContentForm.category(categoryName) {
        case .movie: self = .movie
        case .series: self = .series
        default: self = .unknown
        }
    }
}

enum EpisodeListPresentation {
    static func presentations(from episodes: [PlayEpisode], query: String,
                              sortOrder: EpisodeSortOrder, categoryName: String? = nil) -> [EpisodePresentation] {
        let semantics = PlaybackResourceAnalyzer.analyzeList(episodes, categoryName: categoryName)
        let mainCount = semantics.filter { $0.role == .main }.count
        var values = episodes.enumerated().map { index, episode in
            let parsed = EpisodeNameParser.presentation(for: episode, sourceIndex: index, categoryName: categoryName, semantics: semantics[index])
            let value = semantics[index]
            guard value.form == .movie, value.role == .main else { return parsed }
            let labels = value.versionLabels.joined(separator: " · ")
            let title: String
            if mainCount == 1 {
                title = L10n.string("episode.feature", fallback: "Feature") + (labels.isEmpty ? "" : " · " + labels)
            } else {
                title = labels.isEmpty ? parsed.displayName : labels
            }
            return renaming(parsed, title)
        }
        // Two versions of the same episode must remain distinguishable in every UI.
        let counts = Dictionary(values.map { ($0.displayName, 1) }, uniquingKeysWith: +)
        values = values.map { value in
            guard counts[value.displayName, default: 0] > 1 else { return value }
            return renaming(value, compactOriginal(value))
        }
        let originalCounts = Dictionary(values.map { ($0.displayName, 1) }, uniquingKeysWith: +)
        values = values.map { value in
            originalCounts[value.displayName, default: 0] > 1
                ? renaming(value, "\(value.displayName) · \(value.sourceIndex + 1)") : value
        }
        return filterAndSort(values, query: query, sortOrder: sortOrder)
    }

    private static func compactOriginal(_ value: EpisodePresentation) -> String {
        EpisodeNameParser.compactName(value.originalName)
    }

    private static func renaming(_ value: EpisodePresentation, _ title: String) -> EpisodePresentation {
        EpisodePresentation(episode: value.episode, displayName: title, originalName: value.originalName,
            seasonNumber: value.seasonNumber, episodeNumber: value.episodeNumber,
            isSpecial: value.isSpecial, sourceIndex: value.sourceIndex)
    }

    static func filterAndSort(
        _ presentations: [EpisodePresentation],
        query: String,
        sortOrder: EpisodeSortOrder
    ) -> [EpisodePresentation] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let values: [EpisodePresentation]
        if keyword.isEmpty {
            values = presentations
        } else {
            values = presentations.filter {
                $0.displayName.localizedCaseInsensitiveContains(keyword)
                    || $0.originalName.localizedCaseInsensitiveContains(keyword)
            }
        }

        switch sortOrder {
        case .sourceOrder:
            return values
        case .episodeAscending:
            return values.sorted { compare($0, $1, ascending: true) }
        case .episodeDescending:
            return values.sorted { compare($0, $1, ascending: false) }
        }
    }

    static func rangeOptions(
        from presentations: [EpisodePresentation]
    ) -> [EpisodeRangeOption] {
        let numbered = presentations
            .filter { $0.episodeNumber != nil }
            .sorted { compare($0, $1, ascending: true) }
        guard numbered.count > 40 else { return [] }

        let seasons = Dictionary(grouping: numbered, by: { $0.seasonNumber ?? -1 })
        return seasons.keys.sorted().flatMap { seasonKey in
            let items = seasons[seasonKey]!
            return stride(from: 0, to: items.count, by: 20).map { start in
                let chunk = Array(items[start..<min(start + 20, items.count)])
                let first = chunk.first!.episodeNumber!, last = chunk.last!.episodeNumber!
                let title = seasonKey >= 0
                    ? L10n.string("episode.range.season", fallback: "Season %d · Episodes %d–%d", seasonKey, first, last)
                    : L10n.string("episode.range", fallback: "Episodes %d–%d", first, last)
                return EpisodeRangeOption(id: "\(seasonKey)-\(start)", title: title, episodeIDs: Set(chunk.map(\.id)))
            }
        }
    }

    private static func compare(
        _ lhs: EpisodePresentation,
        _ rhs: EpisodePresentation,
        ascending: Bool
    ) -> Bool {
        guard let lhsEpisode = lhs.episodeNumber else {
            return rhs.episodeNumber == nil && lhs.sourceIndex < rhs.sourceIndex
        }
        guard let rhsEpisode = rhs.episodeNumber else { return true }
        let lhsKey = (lhs.seasonNumber ?? 0, lhsEpisode)
        let rhsKey = (rhs.seasonNumber ?? 0, rhsEpisode)
        if lhsKey == rhsKey {
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return ascending ? lhsKey < rhsKey : lhsKey > rhsKey
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Loading and loaded pages share viewport-based geometry. No content measurement
/// writes back to state while resizing; expansion state belongs to DetailView.
private struct DetailHeroHeader<Description: View, Actions: View>: View {
    let summary: VideoSummary
    let availableWidth: CGFloat
    @ViewBuilder var description: () -> Description
    @ViewBuilder var actions: () -> Actions

    private var isStacked: Bool { availableWidth < 560 }
    private var posterWidth: CGFloat { DetailPageLayout.posterWidth }
    private var informationWidth: CGFloat {
        min(DetailPageLayout.readingWidth, max(1, availableWidth - 2 * DetailPageLayout.horizontalPadding
            - (isStacked ? 0 : posterWidth + 26)))
    }

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 20) {
                    poster
                    information
                }
            } else {
                HStack(alignment: .top, spacing: 26) {
                    poster
                    information
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DetailPageLayout.horizontalPadding)
        .padding(.vertical, 26)
    }

    private var poster: some View {
        DetailPosterView(summary: summary)
            .frame(width: posterWidth, height: posterWidth * 1.5)
            .accessibilityIdentifier("detail.poster")
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.title)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(2)
                .help(summary.title)
                .frame(height: 68, alignment: .topLeading)
            description()
                .frame(maxHeight: .infinity, alignment: .topLeading)
            actions()
                .frame(height: 32, alignment: .bottomLeading)
        }
        .frame(width: informationWidth, height: posterWidth * 1.5, alignment: .topLeading)
    }
}

/// Measure text at its actual reading width; opening the popover never changes
/// the poster/action geometry or pushes the playback list down the page.
private struct DetailSummaryText: View {
    let title: String
    let text: String
    let lines: Int
    @Binding var isExpanded: Bool

    var body: some View {
        GeometryReader { geometry in
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let height = (text as NSString).boundingRect(with: NSSize(width: max(1, geometry.size.width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: NSFont.systemFontSize))
                    .lineLimit(lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: lineHeight * CGFloat(lines), alignment: .topLeading)
                if height > lineHeight * CGFloat(lines) + 1 {
                    Button(L10n.string("common.more", fallback: "More")) { isExpanded = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(title).font(.headline)
                                    Spacer()
                                    Button { isExpanded = false } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
                                }
                                ScrollView {
                                    Text(text).font(.body).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(20)
                            .frame(width: 440, height: 330)
                        }
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: CGFloat(lines) * ceil(NSFont.systemFont(ofSize: NSFont.systemFontSize).ascender
            - NSFont.systemFont(ofSize: NSFont.systemFontSize).descender
            + NSFont.systemFont(ofSize: NSFont.systemFontSize).leading) + 22)
    }
}
