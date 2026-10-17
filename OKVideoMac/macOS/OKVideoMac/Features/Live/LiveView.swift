import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI

struct LiveBrowserPreferencePayload: Codable, Equatable {
    var selectedSource: String?
    var groups: [String: String] = [:]
    var channels: [String: String] = [:]
    var routes: [String: [String: String]] = [:]
}

struct LiveBrowserPreferenceStore {
    static let storageKey = "OKVideoMac.LiveBrowserPreference.v1"
    let defaults: UserDefaults
    let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = Self.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func selectedSource() -> LiveSourceID? {
        load().selectedSource.flatMap(Self.decodeSource)
    }

    func setSelectedSource(_ source: LiveSourceID) {
        update { $0.selectedSource = Self.encode(source) }
    }

    func group(for source: LiveSourceID) -> String? { load().groups[Self.encode(source)] }
    func setGroup(_ group: String?, for source: LiveSourceID) {
        update { payload in
            let key = Self.encode(source)
            if let group { payload.groups[key] = group } else { payload.groups[key] = nil }
        }
    }

    func channel(for source: LiveSourceID) -> String? { load().channels[Self.encode(source)] }
    func setChannel(_ channel: String, for source: LiveSourceID) {
        update { $0.channels[Self.encode(source)] = channel }
    }

    func route(for source: LiveSourceID, channelID: String) -> String? {
        load().routes[Self.encode(source)]?[channelID]
    }
    func setRoute(_ route: String?, for source: LiveSourceID, channelID: String) {
        update { payload in
            let key = Self.encode(source)
            var sourceRoutes = payload.routes[key] ?? [:]
            sourceRoutes[channelID] = route
            payload.routes[key] = sourceRoutes.isEmpty ? nil : sourceRoutes
        }
    }

    private func load() -> LiveBrowserPreferencePayload {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(LiveBrowserPreferencePayload.self, from: data) else {
            return LiveBrowserPreferencePayload()
        }
        return value
    }

    private func update(_ mutation: (inout LiveBrowserPreferencePayload) -> Void) {
        var payload = load()
        mutation(&payload)
        if let data = try? JSONEncoder().encode(payload) { defaults.set(data, forKey: storageKey) }
    }

    static func encode(_ source: LiveSourceID) -> String {
        switch source {
        case .imported(let id): return "imported:\(id.uuidString.lowercased())"
        case .xtream(let id): return "xtream:\(id.uuidString.lowercased())"
        }
    }

    static func decodeSource(_ value: String) -> LiveSourceID? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "imported": return .imported(id)
        case "xtream": return .xtream(id)
        default: return nil
        }
    }
}

enum LiveDisplayMode { case channels, guide }

@MainActor
final class LiveBrowserSession: ObservableObject {
    private let preferences: LiveBrowserPreferenceStore
    @Published var selectedSourceID: LiveSourceID? {
        didSet {
            guard selectedSourceID != oldValue, let selectedSourceID else { return }
            preferences.setSelectedSource(selectedSourceID)
            selectedGroupID = preferences.group(for: selectedSourceID)
        }
    }
    var channelAnchors: [String: LiveChannelBrowseAnchor] = [:]
    @Published var searchText = ""
    @Published var selectedGroupID: String? {
        didSet {
            guard selectedGroupID != oldValue, let selectedSourceID else { return }
            preferences.setGroup(selectedGroupID, for: selectedSourceID)
        }
    }
    @Published var showsFavoritesOnly = false
    @Published var showsCatchupList = false
    @Published var catchupChannelID: String?
    @Published private(set) var displayMode: LiveDisplayMode = .channels
    var showsGuide: Bool {
        get { displayMode == .guide }
        set { setDisplayMode(newValue ? .guide : .channels) }
    }
    func setDisplayMode(_ mode: LiveDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        BrowserInteractionTrace.record(mode == .guide ? "guide.mode.guide" : "guide.mode.channels")
    }
    @Published var guideWindowStart = LiveBrowserSession.roundedGuideStart(Date().addingTimeInterval(-3600))
    @Published var guideVisibleRange: Range<Int> = 0..<1
    @Published private(set) var guideRefreshRequest = 0

    func refresh(source: LiveSourceDescriptor, state: AppState) {
        guard !state.isLiveCatalogLoading(source.id) else { return }
        if showsGuide, state.presentedLiveCatalog(for: source.id) != nil {
            guard !state.liveGuide.isRefreshing else { return }
            guideRefreshRequest &+= 1
        } else if source.canRefresh {
            Task { await state.refreshLiveSource(source.id) }
        }
    }

    /// Deliberately not published: changing sections must not invalidate the
    /// mounted live grid. It only gates source-loading side effects.
    private(set) var isActive = false
    private var activeOwner: UUID?
    func activate(owner: UUID) { activeOwner = owner; isActive = true }
    @discardableResult
    func deactivate(owner: UUID) -> Bool {
        guard activeOwner == owner else { return false }
        activeOwner = nil
        isActive = false
        return true
    }

    init(preferences: LiveBrowserPreferenceStore = LiveBrowserPreferenceStore()) {
        self.preferences = preferences
        let source = preferences.selectedSource()
        selectedSourceID = source
        selectedGroupID = source.flatMap { preferences.group(for: $0) }
    }

    func playDefault(channel: LiveChannel, source: LiveSourceID, catalog: AcceptedImportedCatalog?,
                     channels: [LiveChannel], state: AppState) {
        let remembered = rememberedRoute(for: source, channel: channel)
        if case .imported = source {
            let choices = catalog?.selections(for: channel) ?? []
            guard let selection = choices.first(where: {
                importedRouteIdentity(for: $0.stream, in: channel) == remembered
            }) ?? choices.first else { return }
            remember(channel: channel, source: source,
                     route: importedRouteIdentity(for: selection.stream, in: channel))
            Task { await state.playImportedLive(selection, navigationChannels: channels) }
        } else {
            guard let stream = channel.streams.first(where: {
                nativeRouteIdentity(for: $0) == remembered
            }) ?? channel.streams.first else { return }
            remember(channel: channel, source: source, route: nativeRouteIdentity(for: stream))
            Task { await state.playLive(channel: channel, stream: stream, sourceID: source,
                                       navigationChannels: channels) }
        }
    }

    static func roundedGuideStart(_ date: Date) -> Date {
        let interval: TimeInterval = 60 * 60
        return Date(timeIntervalSinceReferenceDate:
            floor(date.timeIntervalSinceReferenceDate / interval) * interval)
    }

    func reconcileSources(_ sources: [LiveSourceDescriptor]) {
        guard !sources.isEmpty else { return }
        if let selectedSourceID,
           sources.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        selectedSourceID = sources.first?.id
    }

    func remember(channel: LiveChannel, source: LiveSourceID, route: String?) {
        preferences.setChannel(channel.id, for: source)
        preferences.setRoute(route, for: source, channelID: channel.id)
    }

    func rememberedChannel(for source: LiveSourceID) -> String? {
        preferences.channel(for: source)
    }

    func rememberedRoute(for source: LiveSourceID, channel: LiveChannel) -> String? {
        preferences.route(for: source, channelID: channel.id)
    }

    func importedRouteIdentity(for stream: LiveStream, in channel: LiveChannel) -> String? {
        let name = stream.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, channel.streams.filter({ $0.name == stream.name }).count == 1 else { return nil }
        return "name:\(name)"
    }

    func nativeRouteIdentity(for stream: LiveStream) -> String? {
        guard case .provider = stream.target else { return nil }
        return "provider:\(stream.id)"
    }

    func reconcileGroups(_ groups: [LiveGroup]) {
        guard let selectedGroupID,
              !groups.contains(where: { $0.id == selectedGroupID }) else {
            return
        }
        self.selectedGroupID = nil
    }
}

struct LiveView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var session: LiveBrowserSession
    @StateObject private var logoURLCache = LiveChannelLogoURLCache()
    @State private var channelSelection = BrowserItemSelection()
    @State private var activationOwner = UUID()
    @State private var isMounted = false
    private let channelScrollCoordinateSpace = "live-channel-scroll"

    var body: some View {
        Group {
            if state.liveSourceDescriptors.isEmpty {
                emptyLibrary
            } else {
                channelContent
                    .frame(minWidth: 520)
            }
        }
        .onAppear {
            isMounted = true
            updateActivation(for: navigation.selectedSection)
        }
        .onDisappear {
            isMounted = false
            if session.deactivate(owner: activationOwner) { updateEPGDemand() }
        }
        .onChange(of: navigation.selectedSection) { section in
            updateActivation(for: section)
        }
        .onChange(of: session.selectedSourceID) { _ in
            state.selectImportedIdentitySource(session.selectedSourceID)
            channelSelection = BrowserItemSelection()
            session.searchText = ""
            session.showsFavoritesOnly = false
            updateEPGDemand()
            guard session.isActive else { return }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: state.liveSourceDescriptors) { _ in
            let previousSourceID = session.selectedSourceID
            selectFirstSourceIfNeeded()
            guard session.isActive,
                  previousSourceID == session.selectedSourceID else {
                return
            }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: selectedCatalog?.groups.filter { $0.password == nil }.map(\.id) ?? []) { _ in
            // A temporary loading state is not evidence that a category was
            // removed. Reconcile only against a completed catalog snapshot.
            if let selectedCatalog {
                session.reconcileGroups(selectedCatalog.groups.filter { $0.password == nil })
            }
        }
        .onChange(of: state.shortcutLiveRefreshRequest) { _ in
            guard session.isActive, let source = selectedSource else { return }
            session.refresh(source: source, state: state)
        }
        .onChange(of: session.selectedGroupID) { _ in updateEPGDemand() }
        .onChange(of: session.searchText) { _ in updateEPGDemand() }
        .onChange(of: session.showsFavoritesOnly) { _ in updateEPGDemand() }
        .onChange(of: session.showsGuide) { enabled in
            updateEPGDemand()
        }
        .onChange(of: state.liveEPGCatalogRevision) { _ in updateEPGDemand() }
        .onChange(of: state.shortcutLiveSourceSelection) { request in
            guard let request,
                  state.liveSourceDescriptors.contains(where: {
                      $0.id == request.sourceID
                  }) else { return }
            state.selectImportedIdentitySource(request.sourceID)
            session.selectedSourceID = request.sourceID
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                systemImage: "dot.radiowaves.left.and.right",
                title: L10n.string("live.no-sources.title", fallback: "No Live TV Sources"),
                message: L10n.string("live.no-sources.message", fallback: "Use the button below to add an M3U, M3U8, TXT, or JSON source from a URL, pasted content, or a local file.")
            )
            Button {
                state.selectedSettingsPane = .liveSources
                state.selectSection(.settings)
            } label: {
                Label(L10n.string("live.open-settings", fallback: "Open Live TV Source Settings"), systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var channelContent: some View {
        if let source = selectedSource {
            if let catalog = state.presentedLiveCatalog(for: source.id) {
                playlistContent(
                    catalog,
                    sourceID: source.id,
                    sourceName: source.name
                )
            } else if state.isLiveCatalogLoading(source.id) {
                Text(L10n.string("live.loading-source", fallback: "Loading Live TV source…"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: L10n.string("live.source.load.failed", fallback: "Live TV Source Failed to Load"),
                        message: state.liveCatalogError(for: source.id)
                            ?? L10n.string("live.choose-source.message", fallback: "Choose a source from the menu above.")
                    )
                    if source.canRefresh {
                        Button {
                            Task { await state.refreshLiveSource(source.id) }
                        } label: {
                            Label(L10n.string("live.refresh-current", fallback: "Refresh Current Live TV Source"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: L10n.string("live.choose-source.title", fallback: "Choose a Live TV Source"),
                message: L10n.string("live.choose-source.message", fallback: "Choose a source from the menu above.")
            )
        }
    }

    @ViewBuilder
    private func playlistContent(
        _ playlist: LiveCatalogSnapshot,
        sourceID: LiveSourceID,
        sourceName: String
    ) -> some View {
        let importedCatalog = importedCatalog(for: sourceID)
        let visibleGroups = playlist.groups.filter { $0.password == nil }
        let channels = filteredChannels(
            visibleGroups.flatMap(\.channels),
            sourceID: sourceID
        )
        if session.showsGuide, !channels.isEmpty {
            LiveGuideScreen(
                guide: state.liveGuide,
                session: session,
                sourceID: sourceID,
                channels: channels,
                importedCatalog: importedCatalog
            )
            .environmentObject(state)
            .id(sourceID)
        } else if channels.isEmpty {
            EmptyStateView(
                systemImage: session.showsFavoritesOnly ? "star" : "magnifyingglass",
                title: session.showsFavoritesOnly
                    ? L10n.string("live.empty.favorites.title", fallback: "No Favorite Channels")
                    : L10n.string("live.empty.filtered.title", fallback: "No Matching Channels"),
                message: session.showsFavoritesOnly
                    ? L10n.string("live.empty.favorites.message", fallback: "Use the star on a channel card to add it to Favorites.")
                    : L10n.string("live.empty.filtered.message", fallback: "Choose another group or search term.")
            ).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativeLiveChannelPage(channels: channels, source: sourceID, sourceName: sourceName,
                catalog: importedCatalog, session: session,
                browseKey: "\(LiveBrowserPreferenceStore.encode(sourceID))/\(session.selectedGroupID ?? "")/\(session.searchText)/\(session.showsFavoritesOnly)")
                .environmentObject(state)
        }
    }


    private var selectedSource: LiveSourceDescriptor? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.liveSourceDescriptors.first { $0.id == selectedSourceID }
    }

    private func importedCatalog(for sourceID: LiveSourceID) -> AcceptedImportedCatalog? {
        guard case .imported(let id) = sourceID else { return nil }
        return state.acceptedImportedCatalogs[id]
    }

    private var selectedCatalog: LiveCatalogSnapshot? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.presentedLiveCatalog(for: selectedSourceID)
    }

    private func filteredChannels<S: Sequence>(
        _ channels: S,
        sourceID: LiveSourceID,
        limit: Int? = nil
    ) -> [LiveChannel] where S.Element == LiveChannel {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = channels.lazy.filter { channel in
            let isDeleted = state.isLiveChannelDeleted(
                sourceID: sourceID,
                channel: channel
            )
            let groupMatches = session.selectedGroupID == nil
                || channel.groupID == session.selectedGroupID
            let favoriteMatches = !session.showsFavoritesOnly
                || state.isLiveFavorite(sourceID: sourceID, channel: channel)
            let queryMatches = query.isEmpty
                || channel.name.localizedCaseInsensitiveContains(query)
                || channel.groupName.localizedCaseInsensitiveContains(query)
                || (channel.tvgName?.localizedCaseInsensitiveContains(query) ?? false)
                || (channel.number?.localizedCaseInsensitiveContains(query) ?? false)
            return !isDeleted
                && groupMatches
                && favoriteMatches
                && queryMatches
        }
        if let limit { return Array(matches.prefix(limit)) }
        return Array(matches)
    }

    private func selectFirstSourceIfNeeded() {
        session.reconcileSources(state.liveSourceDescriptors)
    }

    private func updateActivation(for section: AppSection) {
        guard isMounted else { return }
        if section == .live { session.activate(owner: activationOwner) }
        else if !session.deactivate(owner: activationOwner) { return }
        updateEPGDemand()
        guard session.isActive else { return }

        let previousSourceID = session.selectedSourceID
        selectFirstSourceIfNeeded()
        state.selectImportedIdentitySource(session.selectedSourceID)
        if previousSourceID == session.selectedSourceID {
            Task { await loadSelectedIfNeeded() }
        }
    }

    private func loadSelectedIfNeeded() async {
        defer { updateEPGDemand() }
        guard let source = selectedSource,
              state.liveCatalog(for: source.id) == nil,
              !state.isLiveCatalogLoading(source.id) else {
            return
        }
        await state.loadLiveSource(source.id)
    }

    private func updateEPGDemand() {
        guard session.isActive, let catalog = selectedCatalog else {
            state.setEPGBrowserDemand(source: nil, channels: [])
            return
        }
        let channels = filteredChannels(catalog.groups.lazy.filter { $0.password == nil }.flatMap(\.channels),
                                        sourceID: catalog.sourceID, limit: 8)
        state.setEPGBrowserDemand(source: catalog.sourceID, channels: channels)
    }
}

private struct LiveGuideSelection: Equatable {
    let rowID: String
    let title: String
    let start: Date
    let end: Date
    var catchupAvailable: Bool? = nil
}

struct LiveGuideChannelPager {
    static let pageSize = EPGGuideLimits.maximumDesiredRows

    static func pageCount(total: Int) -> Int {
        max(1, Int(ceil(Double(max(0, total)) / Double(pageSize))))
    }

    static func clampedPage(_ page: Int, total: Int) -> Int {
        min(max(0, page), pageCount(total: total) - 1)
    }

    static func range(page: Int, total: Int) -> Range<Int> {
        let safePage = clampedPage(page, total: total)
        let lower = min(max(0, total), safePage * pageSize)
        let upper = min(max(0, total), lower + pageSize)
        return lower..<upper
    }
}

struct LiveGuideScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var guide: LiveGuideState
    @ObservedObject var session: LiveBrowserSession
    let sourceID: LiveSourceID
    let channels: [LiveChannel]
    let importedCatalog: AcceptedImportedCatalog?
    @State private var selection: LiveGuideSelection?
    @StateObject private var modelPresenter = LiveGuideModelPresenter()
    @State private var channelPage = 0
    @State private var repositionRequest: LiveGuideRepositionRequest?
    @State private var demandOwner: UUID?
    @State private var recoveryAttempted = false
    @State private var showsDatePicker = false

    private var boundedChannels: [LiveChannel] {
        if session.showsCatchupList, let channel = channels.first(where: { $0.id == session.catchupChannelID }) ?? channels.first {
            return [channel]
        }
        return Array(channels[LiveGuideChannelPager.range(page: channelPage, total: channels.count)])
    }

    private var windowEnd: Date {
        session.guideWindowStart.addingTimeInterval(12 * 60 * 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            LiveGuideViewportHost {
                if session.showsCatchupList { catchupList } else { content }
            }
            if let selection {
                Divider()
                detailBar(selection)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let owner = UUID()
            if session.showsGuide, session.selectedSourceID == sourceID,
               state.acquireLiveGuideDemand(owner: owner, navigation: state.navigation.selection) {
                demandOwner = owner
                requestGuide()
            }
            updateGridModel()
        }
        .onDisappear {
            modelPresenter.invalidate()
            if let owner = demandOwner { state.clearLiveGuideDemand(owner: owner) }
            demandOwner = nil
        }
        .onChange(of: session.guideRefreshRequest) { _ in retryGuide() }
        .onChange(of: guide.snapshot) { _ in updateGridModel() }
        .onChange(of: modelPresenter.model) { model in
            guard let selection else { return }
            let retained = model?.rows.first { $0.id == selection.rowID }?.programmes.contains {
                $0.title == selection.title && $0.start == selection.start && $0.end == selection.end
            } == true
            if !retained { self.selection = nil }
        }
        .onChange(of: guide.isRefreshing) { refreshing in
            if !refreshing { updateGridModel() }
        }
        .onChange(of: viewScope) { _ in recoveryAttempted = false; updateGridModel() }
        .onChange(of: session.guideWindowStart) { _ in requestGuide() }
        .onChange(of: channels.map(\.id)) { _ in
            let clamped = LiveGuideChannelPager.clampedPage(channelPage, total: channels.count)
            if channelPage == clamped { requestGuide() } else { channelPage = clamped }
        }
        .onChange(of: session.catchupChannelID) { _ in session.guideVisibleRange = 0..<1; requestGuide() }
        .onChange(of: session.showsCatchupList) { _ in session.guideVisibleRange = 0..<1; requestGuide() }
        .onChange(of: channelPage) { _ in
            session.guideVisibleRange = 0..<1
            selection = nil
            requestGuide()
        }
        .onChange(of: sourceID) { _ in
            channelPage = 0
            session.guideVisibleRange = 0..<1
            selection = nil
            requestGuide()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                Button { showsDatePicker.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "calendar").foregroundColor(.secondary)
                        Text(session.guideWindowStart, format: .dateTime.month().day().weekday(.abbreviated))
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(L10n.string("live.guide.date", fallback: "Guide Date"))
                .popover(isPresented: $showsDatePicker, arrowEdge: .bottom) {
                    DatePicker(L10n.string("live.guide.date", fallback: "Guide Date"),
                        selection: guideDateBinding, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .onChange(of: session.guideWindowStart) { _ in showsDatePicker = false }
                }
                Button { session.showsCatchupList.toggle() } label: {
                    Image(systemName: session.showsCatchupList ? "rectangle.split.3x3" : "list.bullet.rectangle")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("live.catchup.list", fallback: "Channel Catch-up List"))
                Divider().frame(height: 18)
                HStack(spacing: 4) {
                    Button { moveWindow(-12 * 60 * 60) } label: {
                        Image(systemName: "chevron.left").frame(width: 26, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("live.guide.previous", fallback: "Previous 12 Hours"))
                    .accessibilityLabel(L10n.string("live.guide.previous", fallback: "Previous 12 Hours"))
                    Button(L10n.string("live.guide.now", fallback: "Now")) {
                        let now = Date()
                        session.guideWindowStart = LiveBrowserSession.roundedGuideStart(now.addingTimeInterval(-3600))
                        repositionRequest = LiveGuideRepositionRequest(date: now)
                    }
                    .controlSize(.regular)
                    Button { moveWindow(12 * 60 * 60) } label: {
                        Image(systemName: "chevron.right").frame(width: 26, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("live.guide.next", fallback: "Next 12 Hours"))
                    .accessibilityLabel(L10n.string("live.guide.next", fallback: "Next 12 Hours"))
                }
                if geometry.size.width >= 780 {
                    (Text(session.guideWindowStart, format: .dateTime.hour().minute()) + Text(" – ")
                        + Text(windowEnd, format: .dateTime.hour().minute()))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                        .help(session.guideWindowStart.formatted() + " – " + windowEnd.formatted())
                }
                Spacer(minLength: 8)
                if channels.count > LiveGuideChannelPager.pageSize {
                    HStack(spacing: 4) {
                        Text(L10n.string("live.guide.channel-page", fallback: "Channels %d–%d of %d",
                            LiveGuideChannelPager.range(page: channelPage, total: channels.count).lowerBound + 1,
                            LiveGuideChannelPager.range(page: channelPage, total: channels.count).upperBound,
                            channels.count))
                            .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                            .lineLimit(1)
                        Button { channelPage -= 1 } label: { Image(systemName: "chevron.up").frame(width: 24, height: 28) }
                            .buttonStyle(.borderless).disabled(channelPage == 0)
                            .help(L10n.string("live.guide.previous-channels", fallback: "Previous Channels"))
                    .accessibilityLabel(L10n.string("live.guide.previous-channels", fallback: "Previous Channels"))
                        Button { channelPage += 1 } label: { Image(systemName: "chevron.down").frame(width: 24, height: 28) }
                            .buttonStyle(.borderless)
                            .disabled(channelPage + 1 >= LiveGuideChannelPager.pageCount(total: channels.count))
                            .help(L10n.string("live.guide.next-channels", fallback: "Next Channels"))
                    .accessibilityLabel(L10n.string("live.guide.next-channels", fallback: "Next Channels"))
                    }
                }
                if sourceID.isXtream {
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                        .help(L10n.string("live.guide.xtream-nearby-only", fallback: "This source provides nearby programmes only"))
                }
            }
            .padding(.horizontal, 16)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 52)
    }

    private var viewScope: LiveGuideViewScope {
        LiveGuideViewScope(source: EPGSourceKey(sourceID), start: session.guideWindowStart,
                          end: windowEnd, channelIDs: boundedChannels.map(\.id))
    }

    private func updateGridModel() {
        let snapshot = guide.snapshot
        let subtitles = Dictionary(uniqueKeysWithValues: snapshot?.rows.compactMap { row in
            rowSubtitle(row.state).map { (row.id, $0) }
        } ?? [])
        if let snapshot, !viewScope.accepts(snapshot), !guide.isRefreshing {
            if !recoveryAttempted {
                recoveryAttempted = true
                requestGuide(force: true)
            } else {
                modelPresenter.rejectScope()
                return
            }
        }
        modelPresenter.submit(snapshot, scope: viewScope, subtitles: subtitles)
    }

    private var content: some View {
        let scope = viewScope
        let revision = modelPresenter.renderRevision
        let model = modelPresenter.scope == scope ? modelPresenter.model : nil
        return ZStack(alignment: .topTrailing) {
            // This host stays at the same structural identity through all load states.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LiveGuideGridRepresentable(model: model, now: context.date, scope: scope, reposition: repositionRequest,
                    onProgrammeSelected: { row, programme in
                        guard modelPresenter.acceptsCallback(scope: scope, revision: revision) else { return }
                        selection = LiveGuideSelection(rowID: row.id, title: programme.title,
                            start: programme.start, end: programme.end, catchupAvailable: programme.catchupAvailable)
                    },
                    onProgrammeActivated: { row, programme in
                        guard modelPresenter.acceptsCallback(scope: scope, revision: revision) else { return }
                        playProgramme(LiveGuideSelection(rowID: row.id, title: programme.title, start: programme.start, end: programme.end, catchupAvailable: programme.catchupAvailable))
                    },
                    onChannelActivated: { row in
                        guard modelPresenter.acceptsCallback(scope: scope, revision: revision) else { return }
                        playChannel(row.id)
                    },
                    onVisibleRangeChanged: { range in
                        guard range != session.guideVisibleRange else { return }
                        DispatchQueue.main.async {
                            guard modelPresenter.acceptsCallback(scope: scope, revision: revision),
                                  session.guideWindowStart == scope.start,
                                  session.selectedSourceID == sourceID else { return }
                            session.guideVisibleRange = range
                            requestGuide()
                        }
                    })
            }
            statusOverlay(hasModel: model != nil)
        }
    }

    @ViewBuilder
    private func statusOverlay(hasModel: Bool) -> some View {
        switch guide.lifecycle {
        case .unsupported:
            channelFallback(title: L10n.string("live.guide.short.unsupported", fallback: "This source does not provide a full schedule yet."),
                            systemImage: "calendar.badge.exclamationmark")
                .background(Color(nsColor: .windowBackgroundColor))
        case .inactive:
            VStack(spacing: 12) {
                Text(L10n.string("live.guide.inactive", fallback: "Programme guide is not loading."))
                Button(L10n.string("common.retry", fallback: "Retry")) { retryGuide() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 8) {
            Button(L10n.string("common.retry", fallback: "Retry")) { retryGuide() }
            channelFallback(title: L10n.string("live.guide.failed", fallback: "The programme guide could not be loaded. Channel playback is still available."),
                            systemImage: "exclamationmark.triangle")
                .background(Color(nsColor: .windowBackgroundColor))
            }
        default:
            if modelPresenter.conversionFailed {
                VStack(spacing: 12) {
                    Label(L10n.string("live.guide.invalid", fallback: "The programme guide returned an invalid window."),
                          systemImage: "exclamationmark.triangle")
                    Button(L10n.string("common.retry", fallback: "Retry")) { retryGuide() }
                }
                .padding().background(.regularMaterial)
            } else if !hasModel {
                Color.clear.accessibilityHidden(true)
            } else if case .empty = guide.lifecycle {
                Label(L10n.string("live.guide.empty", fallback: "No programme entries in this window"),
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.caption).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(10)
            }
        }
    }

    private func channelFallback(title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .foregroundColor(.secondary)
                .padding(.top, 18)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(boundedChannels) { channel in
                        HStack {
                            Text(channel.name).lineLimit(1)
                            Spacer()
                            Button(L10n.string("live.guide.play-channel", fallback: "Play Channel")) {
                                playChannel(channel.id)
                            }
                            .disabled(!canPlay(channel))
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailBar(_ value: LiveGuideSelection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                (Text(boundedChannels.first(where: { $0.id == value.rowID })?.name ?? "")
                    + Text("  ·  ") + Text(value.start, format: .dateTime.hour().minute())
                    + Text("–") + Text(value.end, format: .dateTime.hour().minute()))
                    .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            programmeButton(value)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.regularMaterial)
    }

    private var catchupList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.string("live.catchup.channel", fallback: "Channel"), selection: Binding(
                get: { session.catchupChannelID ?? channels.first?.id ?? "" },
                set: { session.catchupChannelID = $0 })) {
                ForEach(channels) { Text($0.name).tag($0.id) }
            }
            .padding(.horizontal, 16).padding(.top, 12)
            if modelPresenter.scope == viewScope, let row = modelPresenter.model?.rows.first, !row.programmes.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(row.programmes) { programme in
                            let value = LiveGuideSelection(rowID: row.id, title: programme.title,
                                start: programme.start, end: programme.end, catchupAvailable: programme.catchupAvailable)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(programme.title).font(.headline)
                                    (Text(programme.start, format: .dateTime.month().day().hour().minute())
                                        + Text(" – ") + Text(programme.end, format: .dateTime.hour().minute()))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                programmeButton(value)
                            }
                            .padding(16)
                            Divider()
                        }
                    }
                }
            } else if guide.isRefreshing {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(L10n.string("live.catchup.no-guide", fallback: "No programme guide for this date. Archive support and guide coverage are separate."))
                    .foregroundStyle(.secondary).padding(20)
                Spacer()
            }
        }
    }

    private func programme(_ value: LiveGuideSelection) -> EPGProgramme {
        EPGProgramme(channelID: value.rowID, title: value.title, start: value.start, end: value.end, catchupAvailable: value.catchupAvailable)
    }

    private func availability(_ value: LiveGuideSelection) -> LiveCatchupAvailability {
        guard let channel = boundedChannels.first(where: { $0.id == value.rowID }) else { return .unsupported }
        return LiveCatchupPresentation.availability(channel: channel, programme: programme(value), now: Date())
    }

    private func programmeButton(_ value: LiveGuideSelection) -> some View {
        let availability = availability(value)
        let message = availability == .unsupported && sourceID.isXtream && value.catchupAvailable == false
            ? L10n.string("live.catchup.programme-unavailable", fallback: "Programme Not Available for Catch-up")
            : LiveCatchupPresentation.label(availability)
        return Button { playProgramme(value) } label: {
            Label(message, systemImage: availability == .available ? "clock.arrow.circlepath" : "play.fill")
        }
        .disabled(availability != .available && availability != .current)
    }

    private func playProgramme(_ value: LiveGuideSelection) {
        let availability = availability(value)
        if availability == .current { playChannel(value.rowID); return }
        guard availability == .available, let channel = boundedChannels.first(where: { $0.id == value.rowID }) else { return }
        if sourceID.isXtream {
            guard let stream = channel.streams.first(where: {
                LiveCatchupPolicy.availability(stream: $0, programme: programme(value), now: Date()) == .available
            }) else { return }
            Task { await state.playNativeCatchup(channel: channel, stream: stream, sourceID: sourceID,
                programme: programme(value), navigationChannels: boundedChannels) }
            return
        }
        guard let selection = importedCatalog?.selections(for: channel).first(where: {
                  LiveCatchupPolicy.availability(stream: $0.stream,
                      programme: programme(value), now: Date()) == .available
              }) else { return }
        Task { await state.playImportedCatchup(selection, programme: programme(value), navigationChannels: boundedChannels) }
    }

    private var guideDateBinding: Binding<Date> {
        Binding(get: { session.guideWindowStart }, set: { date in
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: session.guideWindowStart)
            var day = calendar.dateComponents([.year, .month, .day], from: date)
            day.hour = time.hour
            day.minute = time.minute
            session.guideWindowStart = calendar.date(from: day)
                ?? LiveBrowserSession.roundedGuideStart(date)
        })
    }

    private func moveWindow(_ seconds: TimeInterval) {
        session.guideWindowStart = session.guideWindowStart.addingTimeInterval(seconds)
    }

    private func retryGuide() {
        guard session.showsGuide, session.selectedSourceID == sourceID else { return }
        if demandOwner == nil {
            let owner = UUID()
            guard state.acquireLiveGuideDemand(owner: owner, navigation: state.navigation.selection) else { return }
            demandOwner = owner
        }
        recoveryAttempted = false
        requestGuide(force: true)
    }

    private func requestGuide(force: Bool = false) {
        guard let owner = demandOwner, session.showsGuide,
              session.selectedSourceID == sourceID else { return }
        let bounded = boundedChannels
        guard !bounded.isEmpty else {
            state.clearLiveGuideDemand(owner: owner)
            return
        }
        state.setLiveGuideDemand(owner: owner, source: sourceID, channels: bounded,
            windowStart: session.guideWindowStart, windowEnd: windowEnd,
            visibleRange: session.guideVisibleRange, force: force)
    }

    private func canPlay(_ channel: LiveChannel) -> Bool {
        if case .imported = sourceID {
            return !(importedCatalog?.selections(for: channel).isEmpty ?? true)
        }
        return !channel.streams.isEmpty
    }

    private func playChannel(_ channelID: String) {
        guard let channel = boundedChannels.first(where: { $0.id == channelID }) else { return }
        if case .imported = sourceID {
            guard let selection = importedCatalog?.selections(for: channel).first else { return }
            Task { await state.playImportedLive(selection, navigationChannels: boundedChannels) }
        } else {
            guard let stream = channel.streams.first else { return }
            Task {
                await state.playLive(channel: channel, stream: stream,
                                     sourceID: sourceID,
                                     navigationChannels: boundedChannels)
            }
        }
    }

    private func rowSubtitle(_ state: EPGGuideRowState) -> String? {
        switch state {
        case .loading: return L10n.string("live.guide.row.loading", fallback: "Loading…")
        case .empty: return L10n.string("live.guide.row.empty", fallback: "No programmes")
        case .unmatched: return L10n.string("live.guide.row.unmatched", fallback: "Channel not matched")
        case .ambiguous: return L10n.string("live.guide.row.ambiguous", fallback: "Multiple channel matches")
        case .unsupported: return L10n.string("live.guide.row.unsupported", fallback: "Not provided")
        case .failed: return L10n.string("live.guide.row.failed", fallback: "Unavailable")
        case .truncated: return L10n.string("live.guide.row.truncated", fallback: "Partially loaded")
        case .ready: return nil
        }
    }
}

struct LiveToolbarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.primaryToolbarLayout) private var toolbarLayout
    @ObservedObject var session: LiveBrowserSession

    var body: some View {
        Group {
            if let source = selectedSource {
                // Source selection and retry must survive an absent/failed
                // catalog. Do not condition the toolbar on loading success.
                let groups = (state.presentedLiveCatalog(for: source.id)?.groups ?? [])
                    .filter { $0.password == nil }
                let allChannels = groups.flatMap(\.channels)
                let deletedChannels = allChannels.filter {
                    state.isLiveChannelDeleted(
                        sourceID: source.id,
                        channel: $0
                    )
                }
                let channelCount = allChannels.count - deletedChannels.count
                toolbarControls(
                    source: source,
                    groups: groups,
                    deletedChannels: deletedChannels,
                    channelCount: channelCount
                )
            }
        }
    }

    @ViewBuilder
    private func toolbarControls(
        source: LiveSourceDescriptor,
        groups: [LiveGroup],
        deletedChannels: [LiveChannel],
        channelCount: Int
    ) -> some View {
        HStack(spacing: PrimaryToolbarMetrics.itemSpacing) {
            switch toolbarLayout {
            case .expanded:
                sourceMenu(
                    channelCount: channelCount,
                    sourceName: source.name,
                    compact: false
                )
                .primaryToolbarMenuControl()
                groupMenu(groups, compact: false)
                    .primaryToolbarMenuControl()
                favoritesButton
                    .primaryToolbarIconControl(
                        isSelected: session.showsFavoritesOnly,
                        selectedColor: .yellow
                    )
                guideModeButton
                if !deletedChannels.isEmpty {
                    deletedChannelsMenu(
                        deletedChannels,
                        sourceID: source.id
                    )
                    .primaryToolbarMenuControl()
                }
            case .compact:
                sourceMenu(
                    channelCount: channelCount,
                    sourceName: source.name,
                    compact: true
                )
                .primaryToolbarMenuControl()
                groupMenu(groups, compact: true)
                    .primaryToolbarMenuControl()
                favoritesButton
                    .primaryToolbarIconControl(
                        isSelected: session.showsFavoritesOnly,
                        selectedColor: .yellow
                    )
                guideModeButton
                if !deletedChannels.isEmpty {
                    deletedChannelsMenu(
                        deletedChannels,
                        sourceID: source.id
                    )
                    .primaryToolbarMenuControl()
                }
            case .minimal:
                condensedMenu(
                    source: source,
                    groups: groups,
                    deletedChannels: deletedChannels,
                    channelCount: channelCount
                )
                .primaryToolbarMenuControl()
            }

            PrimaryToolbarDivider()
            LiveBackgroundActivityControl(epgState: state.liveEPG,
                validationToolbar: state.liveValidationActivity.toolbar, source: source)
            LiveRefreshToolbarControl(guide: state.liveGuide, session: session, source: source)
        }
    }

    private func sourceMenu(
        channelCount: Int,
        sourceName: String,
        compact: Bool
    ) -> some View {
        Menu {
            ForEach(state.liveSourceDescriptors) { source in
                Button {
                    state.selectImportedIdentitySource(source.id)
                    session.selectedSourceID = source.id
                } label: {
                    menuLabel(
                        source.name,
                        selected: source.id == session.selectedSourceID
                    )
                }
            }
        } label: {
            Label {
                Text(compact ? sourceName : "\(sourceName) · \(channelCount)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
        .frame(maxWidth: compact ? 132 : 220)
        .controlSize(.regular)
        .disabled(state.liveSourceDescriptors.count < 2)
        .help(L10n.string("live.current-source", fallback: "Current source: %@; %d channels", sourceName, channelCount))
    }

    private func groupMenu(_ groups: [LiveGroup], compact: Bool) -> some View {
        Menu {
            Button {
                session.selectedGroupID = nil
            } label: {
                menuLabel(
                    L10n.string("live.all-channels", fallback: "All Channels"),
                    selected: session.selectedGroupID == nil
                )
            }
            Divider()
            ForEach(groups) { group in
                Button {
                    session.selectedGroupID = group.id
                } label: {
                    menuLabel(
                        L10n.string(
                            "live.group-count",
                            fallback: "%1$@ (%2$lld)",
                            group.name,
                            group.channels.count
                        ),
                        selected: session.selectedGroupID == group.id
                    )
                }
            }
        } label: {
            Label(
                compact
                    ? (selectedGroupName(in: groups) ?? L10n.string("common.all", fallback: "All"))
                    : (selectedGroupName(in: groups) ?? L10n.string("live.all-channels", fallback: "All Channels")),
                systemImage: "rectangle.3.group"
            )
            .lineLimit(1)
        }
        .frame(maxWidth: compact ? 108 : 180)
        .controlSize(.regular)
        .help(L10n.string("live.filter-groups", fallback: "Filter Channel Groups"))
    }

    private func selectedGroupName(in groups: [LiveGroup]) -> String? {
        groups.first { $0.id == session.selectedGroupID }?.name
    }

    private func condensedMenu(
        source: LiveSourceDescriptor,
        groups: [LiveGroup],
        deletedChannels: [LiveChannel],
        channelCount: Int
    ) -> some View {
        Menu {
            sourceMenu(
                channelCount: channelCount,
                sourceName: source.name,
                compact: false
            )
            groupMenu(groups, compact: false)
            Divider()
            favoritesButton
            guideModeMenuItem
            if !deletedChannels.isEmpty {
                deletedChannelsMenu(
                    deletedChannels,
                    sourceID: source.id
                )
            }
        } label: {
            Label(L10n.string("live.options", fallback: "Live TV Options"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("live.options.help", fallback: "Manage Live TV sources, groups, and channels"))
    }

    private var favoritesButton: some View {
        Button {
            session.showsFavoritesOnly.toggle()
        } label: {
            Label(
                L10n.string("live.favorites-only", fallback: "Favorites Only"),
                systemImage: session.showsFavoritesOnly ? "star.fill" : "star"
            )
        }
        .help(
            session.showsFavoritesOnly
                ? L10n.string("live.show-all", fallback: "Show All Channels")
                : L10n.string("live.show-favorites", fallback: "Show Favorite Channels Only")
        )
    }

    private var guideModeHelp: String {
        session.showsGuide
            ? L10n.string("live.channels.show", fallback: "Show channel cards")
            : L10n.string("live.guide.show", fallback: "Show programme guide")
    }

    private func switchDisplayMode() {
        session.setDisplayMode(session.showsGuide ? .channels : .guide)
    }

    private var guideModeButton: some View {
        BrowserToolbarModeButton(selected: session.showsGuide, help: guideModeHelp,
                                 action: switchDisplayMode)
            .frame(width: PrimaryToolbarMetrics.iconControlSize, height: PrimaryToolbarMetrics.iconControlSize)
    }

    private var guideModeMenuItem: some View {
        Button(action: switchDisplayMode) {
            Label(guideModeHelp, systemImage: "calendar")
        }
    }

    private func deletedChannelsMenu(
        _ channels: [LiveChannel],
        sourceID: LiveSourceID
    ) -> some View {
        Menu {
            ForEach(channels) { channel in
                Button {
                    Task {
                        await state.restoreDeletedLiveChannel(
                            sourceID: sourceID,
                            channel: channel
                        )
                    }
                } label: {
                    Label(
                        L10n.string("live.restore-channel", fallback: "Restore %@", channel.name),
                        systemImage: "arrow.uturn.backward"
                    )
                }
            }
            Divider()
            Button {
                Task {
                    await state.restoreAllDeletedLiveChannels(
                        sourceID: sourceID
                    )
                }
            } label: {
                Label(L10n.string("live.restore-all", fallback: "Restore All"), systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label(
                L10n.string("live.deleted-count", fallback: "%d Deleted", channels.count),
                systemImage: "trash"
            )
        }
        .help(L10n.string("live.deleted.help", fallback: "View or restore deleted channels"))
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
                // The toolbar's icon-only style must not hide menu row titles.
                .labelStyle(.titleAndIcon)
        } else {
            Text(title)
        }
    }

    private var selectedSource: LiveSourceDescriptor? {
        guard let selectedSourceID = session.selectedSourceID else {
            return nil
        }
        return state.liveSourceDescriptors.first { $0.id == selectedSourceID }
    }
}


@MainActor
final class LiveEPGState: ObservableObject {
    @Published private(set) var revision = 0
    private struct ChannelKey: Hashable {
        let source: EPGSourceKey
        let channelID: String
    }
    private struct StoredResult {
        let item: EPGNowNextItem
        let token: EPGResultToken
        let availability: EPGAvailability
        let cost: Int
    }
    private var revisions: [EPGSourceKey: String] = [:]
    private var generations: [EPGSourceKey: UUID] = [:]
    private var results: [ChannelKey: StoredResult] = [:]
    private var order: [ChannelKey] = []
    private var statuses: [EPGRequestKey: EPGRepositoryStatus] = [:]
    var isEmpty: Bool { results.isEmpty }

    func tick() { revision &+= 1 }
    func nextBoundary(after date: Date) -> Date? {
        results.values.flatMap {
            [$0.item.current?.end, $0.item.next?.start, $0.item.next?.end]
                .compactMap { $0 }
        }
        .filter { $0 > date }
        .min()
    }
    func status(_ key: EPGRequestKey) -> EPGRepositoryStatus? { statuses[key] }
    func setStatus(_ status: EPGRepositoryStatus) {
        guard revisions[status.key.source] == status.key.revision else { return }
        statuses[status.key] = status
        tick()
    }

    @discardableResult
    func prepare(source: LiveSourceID, revision: String) -> UUID {
        let sourceKey = EPGSourceKey(source)
        if revisions[sourceKey] == revision, let generation = generations[sourceKey] { return generation }
        remove(source)
        revisions[sourceKey] = revision
        let generation = UUID()
        generations[sourceKey] = generation
        return generation
    }

    @discardableResult
    func publish(_ batch: EPGNowNextBatch, channels: [LiveChannel], source: LiveSourceID,
                 revision: String, generation: UUID, demandRevision: UUID,
                 serviceIncarnation: UUID) -> Bool {
        let sourceKey = EPGSourceKey(source)
        guard revisions[sourceKey] == revision, generations[sourceKey] == generation,
              batch.token.serviceIncarnation == serviceIncarnation,
              batch.token.demandRevision == demandRevision,
              batch.items.count == channels.count else { return false }
        if let priorEpoch = results.first(where: { $0.key.source == sourceKey })?.value.token.sourceEpoch,
           priorEpoch != batch.token.sourceEpoch {
            removeResults(sourceKey)
        }
        for key in order where results[key]?.token.resourceIdentity == batch.token.resourceIdentity
            && results[key]?.token.dataVersion != batch.token.dataVersion {
            results[key] = nil
        }
        order.removeAll { results[$0] == nil }
        for (channel, item) in zip(channels, batch.items) {
            let key = ChannelKey(source: sourceKey, channelID: channel.id)
            let cost = Self.cost(item) + batch.token.resourceIdentity.utf8.count
                + batch.token.sourceEpoch.utf8.count + batch.token.dataVersion.utf8.count + 128
            results[key] = StoredResult(item: item, token: batch.token,
                                        availability: batch.availability, cost: cost)
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > 100 || results.values.reduce(0, { $0 + $1.cost }) > 8 * 1_024 * 1_024 {
            results[order.removeFirst()] = nil
        }
        tick()
        return true
    }

    func remove(_ source: LiveSourceID) {
        let key = EPGSourceKey(source)
        removeResults(key)
        statuses = statuses.filter { $0.key.source != key }
        revisions[key] = nil
        generations[key] = nil
        tick()
    }

    func removeAll() {
        revisions.removeAll()
        generations.removeAll()
        results.removeAll()
        statuses.removeAll()
        order.removeAll()
        tick()
    }

    func removeNativeSources() {
        for key in Array(revisions.keys) where key.kind == .xtream {
            remove(.xtream(key.id))
        }
    }

    func nowNext(channel: LiveChannel, source: LiveSourceID, at date: Date) -> EPGNowNextSnapshot {
        let key = ChannelKey(source: EPGSourceKey(source), channelID: channel.id)
        guard let stored = results[key] else { return EPGNowNextSnapshot() }
        var current = stored.item.current, next = stored.item.next
        if let value = current, !(value.start <= date && date < value.end) { current = nil }
        if current == nil, let value = next, value.start <= date && date < value.end {
            current = value; next = nil
        } else if let value = next, value.start <= date { next = nil }
        return EPGNowNextSnapshot(current: current, next: next, availability: stored.availability)
    }

    private func removeResults(_ source: EPGSourceKey) {
        results = results.filter { $0.key.source != source }
        order.removeAll { $0.source == source }
    }

    #if DEBUG || OKVIDEO_PERFORMANCE_TEST
    var storedResultCountForTesting: Int { results.count }
    func containsForTesting(source: LiveSourceID, channel: LiveChannel) -> Bool {
        results[ChannelKey(source: EPGSourceKey(source), channelID: channel.id)] != nil
    }
    #endif

    private static func cost(_ item: EPGNowNextItem) -> Int {
        [item.current, item.next].compactMap { $0 }.reduce(64) {
            $0 + $1.channelID.utf8.count + $1.title.utf8.count + 96
        }
    }
}

/// Presentation clock only: no per-card tasks, requests, or visibility tracking.
struct EPGTimelineSchedule: TimelineSchedule {
    var boundaries: [Date]
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence {
            var next = startDate
            return AnyIterator<Date> {
                let value = next
                next = min(value.addingTimeInterval(mode == .lowFrequency ? 60 : 15),
                           boundaries.filter { $0 > value }.min() ?? .distantFuture)
                return value
            }
        }
    }
}

struct LiveNowNextView: View {
    @ObservedObject var epg: LiveEPGState
    let channel: LiveChannel
    let source: LiveSourceID
    var usesPlayerProgressColors = false

    var body: some View {
        let initial = epg.nowNext(channel: channel, source: source, at: Date())
        let boundaries = [initial.current?.end, initial.next?.start, initial.next?.end].compactMap { $0 }
        TimelineView(EPGTimelineSchedule(boundaries: boundaries)) { context in
            let info = epg.nowNext(channel: channel, source: source, at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                if let current = info.current {
                    Text(L10n.string("live.now-playing", fallback: "Now Playing: %@", current.title))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(current.start, style: .time)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        if let progress = info.progress(at: context.date) {
                            programmeProgress(progress)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(L10n.string("live.epg.progress", fallback: "Programme progress"))
                        }
                        Text(current.end, style: .time)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    if info.availability == .stale {
                        Text(L10n.string("live.epg.cached", fallback: "Cached"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(emptyLabel(info.availability))
                        .foregroundColor(.secondary)
                }
                if let next = info.next {
                    HStack(spacing: 4) {
                        Text(next.start, style: .time)
                        Text(L10n.string("live.next-program", fallback: "Next: %@", next.title))
                    }
                    .lineLimit(1)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                } else {
                    Text(L10n.string("live.epg.no-next", fallback: "Next: —"))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func programmeProgress(_ progress: Double) -> some View {
        if usesPlayerProgressColors {
            ProgressView(value: progress)
                .progressViewStyle(LivePlayerProgrammeProgressStyle())
        } else {
            ProgressView(value: progress).progressViewStyle(.linear)
        }
    }

    private func emptyLabel(_ availability: EPGAvailability) -> String {
        switch availability {
        case .unsupported: return L10n.string("live.epg.unsupported", fallback: "Provider has no programme guide")
        case .failed: return L10n.string("live.epg.unavailable", fallback: "Programme guide unavailable")
        default: return L10n.string("live.epg.no-current", fallback: "No current programme")
        }
    }
}

/// Explicit colors keep the player overlay readable independently of the
/// system accent color; browser programme rows retain their native style.
private struct LivePlayerProgrammeProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let progress = min(1, max(0, configuration.fractionCompleted ?? 0))
            Capsule()
                .fill(.white.opacity(0.20))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: geometry.size.width * progress)
                }
        }
        .frame(height: 6)
    }
}

private struct LiveChannelCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let channel: LiveChannel
    let artworkURLs: [URL]
    let navigationChannels: [LiveChannel]
    let sourceID: LiveSourceID
    let sourceName: String
    let importedCatalog: AcceptedImportedCatalog?
    @ObservedObject var session: LiveBrowserSession

    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                channelArtwork

                HStack(alignment: .top) {
                    if let number = channel.number, !number.isEmpty {
                        badge(number)
                    }
                    Spacer()
                    if LiveCatchupPresentation.canBrowse(channel) {
                        Button {
                            session.catchupChannelID = channel.id
                            session.showsCatchupList = true
                            session.setDisplayMode(.guide)
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                        .buttonStyle(.borderless)
                        .help(L10n.string("live.catchup.list", fallback: "Channel Catch-up List"))
                    }
                    favoriteButton
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(8)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(0.10),
                radius: 4,
                y: 2
            )
            .contentShape(Rectangle())
            .onTapGesture {
                playDefaultRoute()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    playDefaultRoute()
                } label: {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if routeCount > 1 {
                    streamMenu
                } else {
                    Image(systemName: "tv")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help(L10n.string("live.channel", fallback: "Live TV Channel"))
                }
            }

            LiveNowNextView(epg: state.liveEPG, channel: channel, source: sourceID)
        }
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.055 : 0))
                .padding(-6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isHighlighted ? 0.30 : 0),
                    lineWidth: 1
                )
                .padding(-6)
        }
        .scaleEffect(isHighlighted ? 1.015 : 1)
        .offset(y: isHighlighted ? -1 : 0)
        .shadow(
            color: Color.black.opacity(isHighlighted ? 0.11 : 0),
            radius: isHighlighted ? 8 : 0,
            y: isHighlighted ? 4 : 0
        )
        .zIndex(isHighlighted ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
        .onAppear {
            state.setEPGChannelVisibility(source: sourceID, channel: channel, visible: true)
        }
        .onDisappear {
            state.setEPGChannelVisibility(source: sourceID, channel: channel, visible: false)
        }
        .onHover(perform: onHover)
        .contextMenu {
            routeMenuItems
            Divider()
            Button {
                toggleFavorite()
            } label: {
                Label(
                    isFavorite
                        ? L10n.string("live.unfavorite", fallback: "Remove from Favorites")
                        : L10n.string("live.favorite", fallback: "Favorite Channel"),
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            Divider()
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label(L10n.string("live.delete-channel.action", fallback: "Delete Channel…"), systemImage: "trash")
            }
        }
        .confirmationDialog(
            L10n.string("live.delete-channel.title", fallback: "Delete “%@”?", channel.name),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("live.delete-channel.confirm", fallback: "Delete Channel"), role: .destructive) {
                deleteChannel()
            }
            Button(L10n.string(.commonCancel), role: .cancel) {}
        } message: {
            Text(
                L10n.string("live.delete-channel.message", fallback: "This channel will be removed only from the local “%@” source and will not return after a refresh. You can restore it later from Deleted Channels in the toolbar.", sourceName)
            )
        }
    }

    private var channelArtwork: some View {
        ZStack {
            LinearGradient(
                colors: channelArtworkBackgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 240
            )

            RemoteImageCandidates(
                urls: artworkURLs
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .shadow(color: Color.black.opacity(0.34), radius: 4, y: 2)
            } placeholder: {
                VStack(spacing: 7) {
                    Image(systemName: "tv")
                        .font(.system(size: 30, weight: .medium))
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(
                    colorScheme == .dark
                        ? Color.white.opacity(0.82)
                        : Color.primary.opacity(0.72)
                )
                .padding(.horizontal, 18)
            }
        }
    }

    private var channelArtworkBackgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.22, green: 0.24, blue: 0.29),
                Color(red: 0.13, green: 0.15, blue: 0.19)
            ]
        }
        return [
            Color(red: 0.82, green: 0.85, blue: 0.90),
            Color(red: 0.68, green: 0.73, blue: 0.81)
        ]
    }

    private var favoriteButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isFavorite ? .yellow : .white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.44))
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help(
            isFavorite
                ? L10n.string("live.unfavorite", fallback: "Remove from Favorites")
                : L10n.string("live.favorite", fallback: "Favorite Channel")
        )
    }

    private var streamMenu: some View {
        Menu {
            routeMenuItems
        } label: {
            Text(L10n.string("live.stream-count-short", fallback: "%d streams", routeCount))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("live.choose-stream", fallback: "Choose Stream"))
    }

    private var isFavorite: Bool {
        state.isLiveFavorite(sourceID: sourceID, channel: channel)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var routeMenuItems: some View {
        if case .imported = sourceID {
            ForEach(importedCatalog?.selections(for: channel) ?? []) { selection in
                Button { play(selection) } label: {
                    Label(selection.stream.name, systemImage: "play.fill")
                }
            }
        } else {
            // Native route IDs retain their provider locator semantics.
            ForEach(channel.streams) { stream in
                Button { playNative(stream) } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
        }
    }

    private var routeCount: Int {
        if case .imported = sourceID { return importedCatalog?.selections(for: channel).count ?? 0 }
        return channel.streams.count
    }

    private func playDefaultRoute() {
        onSelect()
        session.playDefault(channel: channel, source: sourceID, catalog: importedCatalog,
                            channels: navigationChannels, state: state)
    }

    private func play(_ selection: ImportedRouteSelection) {
        session.remember(
            channel: channel,
            source: sourceID,
            route: session.importedRouteIdentity(for: selection.stream, in: channel)
        )
        Task { await state.playImportedLive(selection, navigationChannels: navigationChannels) }
    }

    private func playNative(_ stream: LiveStream?) {
        guard let stream else { return }
        session.remember(
            channel: channel,
            source: sourceID,
            route: session.nativeRouteIdentity(for: stream)
        )
        Task {
            await state.playLive(
                channel: channel,
                stream: stream,
                sourceID: sourceID,
                navigationChannels: navigationChannels
            )
        }
    }

    private func toggleFavorite() {
        Task {
            await state.toggleLiveFavorite(
                sourceID: sourceID,
                channel: channel
            )
        }
    }

    private func deleteChannel() {
        Task {
            await state.deleteLiveChannel(
                sourceID: sourceID,
                sourceName: sourceName,
                channel: channel
            )
        }
    }
}

enum LiveChannelLogoResolver {
    private static let fallbackBaseURL = URL(
        string: "https://upload.112114.xyz/logo/"
    )!

    static func urls(
        for channel: LiveChannel,
        allowsFallback: Bool = true
    ) -> [URL] {
        var values: [URL] = []
        if let explicit = channel.logoURL {
            values.append(explicit)
        }
        // Provider catalogs already validate their explicit artwork URLs.
        // Never disclose Xtream channel names to the imported-source fallback
        // service or invent third-party artwork requests for these catalogs.
        guard allowsFallback else { return values }

        let names = [channel.tvgID, channel.tvgName, channel.name]
            .compactMap { $0 }
        for name in names {
            guard let key = lookupKey(name) else { continue }
            let url = fallbackBaseURL.appendingPathComponent("\(key).png")
            if !values.contains(url) {
                values.append(url)
            }
        }
        return values
    }

    static func lookupKey(_ rawName: String) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        name = name.replacingOccurrences(
            of: #"^[0-9]{1,4}\s+"#,
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(
            of: #"[（(][^）)]*[）)]"#,
            with: "",
            options: .regularExpression
        )

        let compact = name
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let range = compact.range(
            of: #"CCTV(?:4K|[0-9]{1,2}\+?)"#,
            options: .regularExpression
        ) {
            return String(compact[range])
        }

        name = name.replacingOccurrences(
            of: #"(?i)(超高清|高清|标清|频道|HD)$"#,
            with: "",
            options: .regularExpression
        )
        name = name.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "-_·")
            )
        )
        return name.isEmpty ? nil : name
    }
}

final class LiveChannelLogoURLCache: ObservableObject {
    private struct Key: Hashable {
        let logoURL: URL?
        let tvgID: String?
        let tvgName: String?
        let name: String
        let allowsFallback: Bool
    }

    private var values: [Key: [URL]] = [:]
    private(set) var computationCount = 0

    func urls(
        for channel: LiveChannel,
        allowsFallback: Bool = true
    ) -> [URL] {
        let key = Key(
            logoURL: channel.logoURL,
            tvgID: channel.tvgID,
            tvgName: channel.tvgName,
            name: channel.name,
            allowsFallback: allowsFallback
        )
        if let cached = values[key] {
            return cached
        }
        let urls = LiveChannelLogoResolver.urls(
            for: channel,
            allowsFallback: allowsFallback
        )
        values[key] = urls
        computationCount += 1
        return urls
    }
}

struct LiveSourceImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote
        case pasted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remote: return "URL"
            case .pasted: return L10n.string("live.source.pasted", fallback: "Pasted Content")
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    @State private var mode: Mode = .remote
    @State private var name = ""
    @State private var remoteURL = ""
    @State private var pastedText = ""
    @State private var baseURL = ""
    @State private var importPhase: LiveSourceImportPhase?
    @State private var submissionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("live.add.title", fallback: "Add Live TV Source"))
                .font(.title2)
            Text(L10n.string("live.add.subtitle", fallback: "Live TV sources are stored separately from video provider configurations. M3U, M3U8, TXT, and JSON are supported."))
                .font(.callout)
                .foregroundColor(.secondary)
            Picker(L10n.string("common.method", fallback: "Method"), selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)
            TextField(L10n.string("live.add.name.optional", fallback: "Source Name (Optional)"), text: $name)
                .disabled(isSubmitting)
            if mode == .remote {
                TextField("https://example.com/channels.m3u", text: $remoteURL)
                    .disabled(isSubmitting)
                Text(L10n.string("live.add.remote.note", fallback: "HTTP and HTTPS only. Responses are limited to 32 MiB with a 30-second timeout."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                TextEditor(text: $pastedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .disabled(isSubmitting)
                TextField(L10n.string("live.add.base-url.optional", fallback: "Relative Channel Base URL (Optional)"), text: $baseURL)
                    .disabled(isSubmitting)
            }
            Spacer()
            if let importPhase {
                HStack(spacing: 8) {
                    AppActivityIndicator(size: .small)
                    Text(importPhase.title)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.string(.commonCancel)) {
                    submissionTask?.cancel()
                    submissionTask = nil
                    isPresented = false
                }
                .disabled(isCommitInProgress)
                Button {
                    importValue()
                } label: {
                    if isSubmitting {
                        HStack(spacing: 6) {
                            AppActivityIndicator(size: .small)
                            Text(L10n.string("live.add.adding", fallback: "Adding"))
                        }
                    } else {
                        Text(L10n.string("live.add.action", fallback: "Add"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(22)
        .interactiveDismissDisabled(isCommitInProgress)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
        }
    }

    private var canImport: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .remote:
            guard let url = URL(string: normalizedRemoteURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return false
            }
            return true
        case .pasted:
            return !pastedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var isCommitInProgress: Bool {
        guard isSubmitting else { return false }
        return importPhase == .saving || importPhase == .publishing
    }

    private var normalizedRemoteURL: String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importValue() {
        let input: LiveSourceInput
        switch mode {
        case .remote:
            guard let url = URL(string: normalizedRemoteURL) else { return }
            input = .remote(url)
        case .pasted:
            input = .pasted(
                text: pastedText,
                baseURL: baseURL.isEmpty ? nil : URL(string: baseURL)
            )
        }
        importPhase = mode == .remote ? .downloadingAndParsing : .parsing
        submissionTask = Task {
            let succeeded = await state.importLiveSource(
                source: input,
                name: name
            ) { phase in
                importPhase = phase
            }
            guard !Task.isCancelled else { return }
            submissionTask = nil
            if succeeded {
                isPresented = false
            } else {
                importPhase = nil
            }
        }
    }
}

/// The same native 32-point control remains mounted across all refresh phases.
/// Observe the guide directly; its publications do not pass through AppState.
private struct LiveRefreshToolbarControl: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var guide: LiveGuideState
    @ObservedObject var session: LiveBrowserSession
    let source: LiveSourceDescriptor

    var body: some View {
        BrowserRefreshToolbarControl(
            isLoading: state.isLiveCatalogLoading(source.id) || (session.showsGuide && guide.isRefreshing),
            error: refreshError,
            title: L10n.string("common.refresh", fallback: "Refresh")
        ) {
            session.refresh(source: source, state: state)
        }
        .disabled(!source.canRefresh && !session.showsGuide)
    }

    private var refreshError: String? {
        if session.showsGuide {
            switch guide.lifecycle {
            case .failed:
                return L10n.string("live.guide.failed", fallback: "The programme guide could not be loaded. Channel playback is still available.")
            case .content(let value) where !value.failures.isEmpty:
                return L10n.string("live.guide.partial", fallback: "%d rows unavailable", value.failures.count)
            case .content(let value) where value.refreshPhase == .backoff:
                return L10n.string("live.guide.stale", fallback: "Saved schedule")
            case .empty(let value) where value.refreshPhase == .backoff:
                return L10n.string("live.guide.stale", fallback: "Saved schedule")
            default: break
            }
        }
        return state.liveCatalogError(for: source.id)
    }
}
