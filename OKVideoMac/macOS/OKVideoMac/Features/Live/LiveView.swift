import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI

@MainActor
final class LiveBrowserSession: ObservableObject {
    @Published var selectedSourceID: UUID?
    @Published var searchText = ""
    @Published var selectedGroupName: String?
    @Published var showsFavoritesOnly = false

    /// Deliberately not published: changing sections must not invalidate the
    /// mounted live grid. It only gates source-loading side effects.
    var isActive = false
}

struct LiveView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var session: LiveBrowserSession
    @StateObject private var logoURLCache = LiveChannelLogoURLCache()
    private let channelScrollCoordinateSpace = "live-channel-scroll"

    var body: some View {
        Group {
            if state.liveSources.isEmpty {
                emptyLibrary
            } else {
                channelContent
                    .frame(minWidth: 520)
            }
        }
        .onAppear {
            updateActivation(for: navigation.selectedSection)
        }
        .onDisappear {
            session.isActive = false
        }
        .onChange(of: navigation.selectedSection) { section in
            updateActivation(for: section)
        }
        .onChange(of: session.selectedSourceID) { _ in
            session.searchText = ""
            session.selectedGroupName = nil
            session.showsFavoritesOnly = false
            guard session.isActive else { return }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: state.liveSources) { _ in
            let previousSourceID = session.selectedSourceID
            selectFirstSourceIfNeeded()
            guard session.isActive,
                  previousSourceID == session.selectedSourceID else {
                return
            }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: state.shortcutLiveRefreshRequest) { _ in
            guard session.isActive,
                  let source = selectedSource,
                  source.sourceKind == .remote else { return }
            Task { await state.refreshLiveSource(source.id) }
        }
        .onChange(of: state.shortcutLiveSourceSelection) { request in
            guard let request,
                  state.liveSources.contains(where: {
                      $0.id == request.sourceID
                  }) else { return }
            session.selectedSourceID = request.sourceID
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                systemImage: "dot.radiowaves.left.and.right",
                title: "尚未添加直播源",
                message: "点击下方按钮，通过 URL、粘贴内容或本地文件添加 M3U、M3U8、TXT 或 JSON 直播源。"
            )
            Button {
                state.selectedSettingsPane = .liveSources
                state.selectSection(.settings)
            } label: {
                Label("打开直播源设置", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var channelContent: some View {
        if let source = selectedSource,
           let playlist = state.loadedLivePlaylists[source.id] {
            playlistContent(
                playlist,
                sourceID: source.id,
                sourceName: source.name
            )
        } else if state.isLoading {
            AppActivityLabel("正在加载直播源…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: "请选择直播源",
                message: "请从上方来源菜单切换直播源。"
            )
        }
    }

    private func playlistContent(
        _ playlist: LivePlaylist,
        sourceID: UUID,
        sourceName: String
    ) -> some View {
        let visibleGroups = playlist.groups.filter { $0.password == nil }
        let hiddenCount = playlist.groups.count - visibleGroups.count
        let channels = filteredChannels(
            visibleGroups.flatMap(\.channels),
            sourceID: sourceID,
            sourceName: sourceName
        )
        let programmeDate = Date()
        return GeometryReader { viewport in
            ScrollView {
                BrowserToolbarScrollMarker(
                    coordinateSpaceName: channelScrollCoordinateSpace
                )
                VStack(spacing: 0) {
                    liveSourceBackgroundStatus(sourceID: sourceID)

                    if channels.isEmpty {
                        EmptyStateView(
                            systemImage: session.showsFavoritesOnly
                                ? "star"
                                : "magnifyingglass",
                            title: session.showsFavoritesOnly
                                ? "还没有收藏频道"
                                : "没有匹配的频道",
                            message: session.showsFavoritesOnly
                                ? "点击频道卡片右上角的星标即可收藏。"
                                : "请更换分组或搜索关键词。"
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(0, viewport.size.height - 72)
                        )
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 238, maximum: 340),
                                    spacing: 18,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 20
                        ) {
                            ForEach(channels) { channel in
                                let programmes = state.liveProgrammes(
                                    for: channel,
                                    sourceID: sourceID,
                                    at: programmeDate
                                )
                                LiveChannelCard(
                                    channel: channel,
                                    artworkURLs: logoURLCache.urls(for: channel),
                                    navigationChannels: channels,
                                    sourceID: sourceID,
                                    sourceName: sourceName,
                                    currentEPGProgramme: programmes.current,
                                    nextEPGProgramme: programmes.next
                                )
                                .environmentObject(state)
                            }
                        }
                        .padding(20)

                        if hiddenCount > 0 {
                            Label(
                                "\(hiddenCount) 个受保护分组已隐藏",
                                systemImage: "lock"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 20)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .browserToolbarScrollSurface(
                named: channelScrollCoordinateSpace
            )
        }
    }

    @ViewBuilder
    private func liveSourceBackgroundStatus(sourceID: UUID) -> some View {
        if let epgStatus = state.liveSourceEPGStatuses[sourceID] {
            switch epgStatus {
            case .loading:
                backgroundStatusLabel(
                    "正在后台下载并整理节目单…",
                    systemImage: "clock.arrow.circlepath",
                    color: .secondary,
                    showsProgress: true
                )
            case .ready:
                backgroundStatusLabel(
                    "节目单已就绪",
                    systemImage: "checkmark.circle",
                    color: .green
                )
            case .failed(let message):
                backgroundStatusLabel(
                    "EPG 暂不可用：\(message)",
                    systemImage: "exclamationmark.triangle",
                    color: .orange
                )
            }
        }

        if let validation = state.liveSourceValidationStatuses[sourceID] {
            switch validation {
            case .checking(let completed, let total):
                backgroundStatusLabel(
                    "正在后台检测频道 \(completed)/\(total)",
                    systemImage: "waveform.path.ecg",
                    color: .secondary,
                    showsProgress: true
                )
            case .completed(let removed, let total):
                backgroundStatusLabel(
                    removed == 0
                        ? "已检测 \(total) 个频道，未发现明确失效项"
                        : "已检测 \(total) 个频道，清理 \(removed) 个失效项（可恢复）",
                    systemImage: removed == 0
                        ? "checkmark.circle"
                        : "trash.slash",
                    color: .secondary
                )
            case .failed(let message):
                backgroundStatusLabel(
                    "后台频道检测未完成：\(message)",
                    systemImage: "exclamationmark.triangle",
                    color: .orange
                )
            }
        }
    }

    private func backgroundStatusLabel(
        _ title: String,
        systemImage: String,
        color: Color,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                AppActivityIndicator(size: .mini)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(color.opacity(0.07))
    }

    private var selectedSource: StoredLiveSource? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.liveSources.first { $0.id == selectedSourceID }
    }

    private func filteredChannels(
        _ channels: [LiveChannel],
        sourceID: UUID,
        sourceName: String
    ) -> [LiveChannel] {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channel in
            let isDeleted = state.isLiveChannelDeleted(
                sourceID: sourceID,
                channel: channel
            )
            let groupMatches = session.selectedGroupName == nil
                || channel.groupName == session.selectedGroupName
            let favoriteMatches = !session.showsFavoritesOnly
                || state.isLiveFavorite(sourceName: sourceName, channel: channel)
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
    }

    private func selectFirstSourceIfNeeded() {
        if let selectedSourceID = session.selectedSourceID,
           state.liveSources.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        session.selectedSourceID = state.liveSources.first?.id
    }

    private func updateActivation(for section: AppSection) {
        session.isActive = section == .live
        guard session.isActive else { return }

        let previousSourceID = session.selectedSourceID
        selectFirstSourceIfNeeded()
        if previousSourceID == session.selectedSourceID {
            Task { await loadSelectedIfNeeded() }
        }
    }

    private func loadSelectedIfNeeded() async {
        guard let source = selectedSource,
              state.loadedLivePlaylists[source.id] == nil else {
            return
        }
        await state.loadLiveSource(source)
    }
}

struct LiveToolbarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.primaryToolbarLayout) private var toolbarLayout
    @ObservedObject var session: LiveBrowserSession

    var body: some View {
        Group {
            if let source = selectedSource,
               let playlist = state.loadedLivePlaylists[source.id] {
                let groups = playlist.groups.filter { $0.password == nil }
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
            } else if state.isLoading {
                AppActivityIndicator(size: .small)
                    .help("正在加载直播源")
            }
        }
    }

    @ViewBuilder
    private func toolbarControls(
        source: StoredLiveSource,
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
            refreshControl(sourceID: source.id)
                .primaryToolbarIconControl()
        }
    }

    private func sourceMenu(
        channelCount: Int,
        sourceName: String,
        compact: Bool
    ) -> some View {
        Menu {
            ForEach(state.liveSources) { source in
                Button {
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
        .disabled(state.liveSources.count < 2)
        .help("当前直播源：\(sourceName)，共 \(channelCount) 个频道")
    }

    private func groupMenu(_ groups: [LiveGroup], compact: Bool) -> some View {
        Menu {
            Button {
                session.selectedGroupName = nil
            } label: {
                menuLabel(
                    "全部频道",
                    selected: session.selectedGroupName == nil
                )
            }
            Divider()
            ForEach(groups) { group in
                Button {
                    session.selectedGroupName = group.name
                } label: {
                    menuLabel(
                        "\(group.name)（\(group.channels.count)）",
                        selected: session.selectedGroupName == group.name
                    )
                }
            }
        } label: {
            Label(
                compact
                    ? (session.selectedGroupName ?? "全部")
                    : (session.selectedGroupName ?? "全部频道"),
                systemImage: "rectangle.3.group"
            )
            .lineLimit(1)
        }
        .frame(maxWidth: compact ? 108 : 180)
        .controlSize(.regular)
        .help("筛选频道分组")
    }

    private func condensedMenu(
        source: StoredLiveSource,
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
            if !deletedChannels.isEmpty {
                deletedChannelsMenu(
                    deletedChannels,
                    sourceID: source.id
                )
            }
        } label: {
            Label("直播选项", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help("直播源、分组和频道管理")
    }

    private var favoritesButton: some View {
        Button {
            session.showsFavoritesOnly.toggle()
        } label: {
            Label(
                "仅看收藏",
                systemImage: session.showsFavoritesOnly ? "star.fill" : "star"
            )
        }
        .help(session.showsFavoritesOnly ? "显示全部频道" : "仅显示收藏频道")
    }

    private func deletedChannelsMenu(
        _ channels: [LiveChannel],
        sourceID: UUID
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
                        "恢复 \(channel.name)",
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
                Label("全部恢复", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label(
                "已删除 \(channels.count)",
                systemImage: "trash"
            )
        }
        .help("查看或恢复已删除的频道")
    }

    @ViewBuilder
    private func refreshControl(sourceID: UUID) -> some View {
        if state.isLoading {
            AppActivityIndicator(size: .small)
                .help("正在刷新直播源")
        } else {
            Button {
                Task { await state.refreshLiveSource(sourceID) }
            } label: {
                Label("刷新直播源", systemImage: "arrow.clockwise")
            }
            .disabled(selectedSource?.sourceKind != .remote)
            .help("刷新当前直播源")
        }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var selectedSource: StoredLiveSource? {
        guard let selectedSourceID = session.selectedSourceID else {
            return nil
        }
        return state.liveSources.first { $0.id == selectedSourceID }
    }

    private func selectFirstSourceIfNeeded() {
        if let selectedSourceID = session.selectedSourceID,
           state.liveSources.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        session.selectedSourceID = state.liveSources.first?.id
    }

    private func loadSelectedIfNeeded() async {
        guard let source = selectedSource,
              state.loadedLivePlaylists[source.id] == nil else {
            return
        }
        await state.loadLiveSource(source)
    }
}

private struct LiveChannelCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let channel: LiveChannel
    let artworkURLs: [URL]
    let navigationChannels: [LiveChannel]
    let sourceID: UUID
    let sourceName: String
    let currentEPGProgramme: EPGProgramme?
    let nextEPGProgramme: EPGProgramme?

    @State private var isHovering = false
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
                play(channel.streams.first)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    play(channel.streams.first)
                } label: {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if channel.streams.count > 1 {
                    streamMenu
                } else {
                    Image(systemName: "tv")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("直播频道")
                }
            }

            if let programmeSummary {
                Text(programmeSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let nextProgramme {
                Text("接下来：\(nextProgramme)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(isHovering ? 0.055 : 0))
                .padding(-6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isHovering ? 0.30 : 0),
                    lineWidth: 1
                )
                .padding(-6)
        }
        .scaleEffect(isHovering ? 1.015 : 1)
        .offset(y: isHovering ? -1 : 0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.11 : 0),
            radius: isHovering ? 8 : 0,
            y: isHovering ? 4 : 0
        )
        .zIndex(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(channel.streams) { stream in
                Button {
                    play(stream)
                } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
            Divider()
            Button {
                toggleFavorite()
            } label: {
                Label(
                    isFavorite ? "取消收藏" : "收藏频道",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            Divider()
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("删除频道…", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "删除“\(channel.name)”？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除频道", role: .destructive) {
                deleteChannel()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "频道只会从本机的“\(sourceName)”中移除，刷新直播源也不会重新出现；之后可以从工具栏的“已删除频道”恢复。"
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
            Color(red: 0.94, green: 0.95, blue: 0.97),
            Color(red: 0.82, green: 0.85, blue: 0.90)
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
        .help(isFavorite ? "取消收藏" : "收藏频道")
    }

    private var streamMenu: some View {
        Menu {
            ForEach(channel.streams) { stream in
                Button {
                    play(stream)
                } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
        } label: {
            Text("\(channel.streams.count) 线")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择播放线路")
    }

    private var isFavorite: Bool {
        state.isLiveFavorite(sourceName: sourceName, channel: channel)
    }

    private var programmeSummary: String? {
        if let current = currentEPGProgramme {
            return "正在播放：\(current.title)"
        }
        guard channel.streams.count > 1 else { return nil }
        let format = channel.streams.first?.format?.uppercased() ?? "直播"
        return "\(format) · \(channel.streams.count) 条线路"
    }

    private var nextProgramme: String? {
        nextEPGProgramme?.title
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

    private func play(_ stream: LiveStream?) {
        guard let stream else { return }
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
                sourceName: sourceName,
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

    static func urls(for channel: LiveChannel) -> [URL] {
        var values: [URL] = []
        if let explicit = channel.logoURL {
            values.append(explicit)
        }

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
    }

    private var values: [Key: [URL]] = [:]
    private(set) var computationCount = 0

    func urls(for channel: LiveChannel) -> [URL] {
        let key = Key(
            logoURL: channel.logoURL,
            tvgID: channel.tvgID,
            tvgName: channel.tvgName,
            name: channel.name
        )
        if let cached = values[key] {
            return cached
        }
        let urls = LiveChannelLogoResolver.urls(for: channel)
        values[key] = urls
        computationCount += 1
        return urls
    }
}

struct LiveSourceImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote = "URL"
        case pasted = "粘贴内容"

        var id: String { rawValue }
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
            Text("添加直播源")
                .font(.title2)
            Text("直播源独立于点播配置保存，支持 M3U、M3U8、TXT 和 JSON。")
                .font(.callout)
                .foregroundColor(.secondary)
            Picker("方式", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)
            TextField("直播源名称（可选）", text: $name)
                .disabled(isSubmitting)
            if mode == .remote {
                TextField("https://example.com/channels.m3u", text: $remoteURL)
                    .disabled(isSubmitting)
                Text("仅允许 HTTP/HTTPS；响应上限 32 MiB，超时 30 秒。")
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
                TextField("相对频道地址的基准 URL（可选）", text: $baseURL)
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
                Button("取消") {
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
                            Text("添加中")
                        }
                    } else {
                        Text("添加")
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
