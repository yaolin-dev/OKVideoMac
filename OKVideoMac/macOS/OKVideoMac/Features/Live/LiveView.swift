import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSourceID: UUID?
    @State private var searchText = ""
    @State private var selectedGroupName: String?
    @State private var showsFavoritesOnly = false

    var body: some View {
        Group {
            if state.liveSources.isEmpty {
                emptyLibrary
            } else {
                channelContent
                    .frame(minWidth: 520)
            }
        }
        .navigationTitle("直播")
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索频道"
        )
        .toolbar {
            ToolbarItemGroup {
                if let source = selectedSource,
                   let playlist = state.loadedLivePlaylists[source.id] {
                    liveToolbarControls(
                        groups: playlist.groups.filter { $0.password == nil },
                        channelCount: playlist.groups
                            .filter { $0.password == nil }
                            .reduce(0) { $0 + $1.channels.count },
                        sourceID: source.id,
                        sourceName: source.name
                    )
                }
            }
        }
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .task {
            selectFirstSourceIfNeeded()
            await loadSelectedIfNeeded()
        }
        .onChange(of: selectedSourceID) { _ in
            searchText = ""
            selectedGroupName = nil
            showsFavoritesOnly = false
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: state.liveSources) { _ in
            selectFirstSourceIfNeeded()
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                systemImage: "dot.radiowaves.left.and.right",
                title: "尚未添加直播源",
                message: "请前往“设置 → 直播源”导入 M3U、TXT 或 JSON 直播列表。"
            )
            Button {
                state.selectedSettingsPane = .liveSources
                state.selectedSection = .settings
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
            ProgressView("正在加载直播源…")
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
            sourceName: sourceName
        )
        return VStack(spacing: 0) {
            if let failure = state.epgFailures[sourceID] {
                Label(
                    "EPG 暂不可用：\(failure)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.07))
            }

            if channels.isEmpty {
                EmptyStateView(
                    systemImage: showsFavoritesOnly ? "star" : "magnifyingglass",
                    title: showsFavoritesOnly ? "还没有收藏频道" : "没有匹配的频道",
                    message: showsFavoritesOnly
                        ? "点击频道卡片右上角的星标即可收藏。"
                        : "请更换分组或搜索关键词。"
                )
            } else {
                ScrollView {
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
                            LiveChannelCard(
                                channel: channel,
                                sourceID: sourceID,
                                sourceName: sourceName
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
                .background(AppSurfacePalette.background)
            }
        }
    }

    @ViewBuilder
    private func liveToolbarControls(
        groups: [LiveGroup],
        channelCount: Int,
        sourceID: UUID,
        sourceName: String
    ) -> some View {
        Menu {
            ForEach(state.liveSources) { source in
                Button {
                    selectedSourceID = source.id
                } label: {
                    groupMenuLabel(
                        source.name,
                        selected: source.id == selectedSourceID
                    )
                }
            }
        } label: {
            Label {
                Text("\(sourceName) · \(channelCount)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
        .disabled(state.liveSources.count < 2)
        .help("当前直播源：\(sourceName)，共 \(channelCount) 个频道")

        Menu {
            Button {
                selectedGroupName = nil
            } label: {
                groupMenuLabel("全部频道", selected: selectedGroupName == nil)
            }
            Divider()
            ForEach(groups) { group in
                Button {
                    selectedGroupName = group.name
                } label: {
                    groupMenuLabel(
                        "\(group.name)（\(group.channels.count)）",
                        selected: selectedGroupName == group.name
                    )
                }
            }
        } label: {
            Label(selectedGroupName ?? "全部频道", systemImage: "rectangle.3.group")
        }
        .help("筛选频道分组")

        Button {
            showsFavoritesOnly.toggle()
        } label: {
            Label(
                "仅看收藏",
                systemImage: showsFavoritesOnly ? "star.fill" : "star"
            )
        }
        .tint(showsFavoritesOnly ? .yellow : .accentColor)
        .help(showsFavoritesOnly ? "显示全部频道" : "仅显示收藏频道")

        if state.isLoading {
            ProgressView()
                .controlSize(.small)
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
    private func groupMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var selectedSource: StoredLiveSource? {
        guard let selectedSourceID else { return nil }
        return state.liveSources.first { $0.id == selectedSourceID }
    }

    private func filteredChannels(
        _ channels: [LiveChannel],
        sourceName: String
    ) -> [LiveChannel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channel in
            let groupMatches = selectedGroupName == nil
                || channel.groupName == selectedGroupName
            let favoriteMatches = !showsFavoritesOnly
                || state.isLiveFavorite(sourceName: sourceName, channel: channel)
            let queryMatches = query.isEmpty
                || channel.name.localizedCaseInsensitiveContains(query)
                || channel.groupName.localizedCaseInsensitiveContains(query)
                || (channel.tvgName?.localizedCaseInsensitiveContains(query) ?? false)
                || (channel.number?.localizedCaseInsensitiveContains(query) ?? false)
            return groupMatches && favoriteMatches && queryMatches
        }
    }

    private func selectFirstSourceIfNeeded() {
        if let selectedSourceID,
           state.liveSources.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        selectedSourceID = state.liveSources.first?.id
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
    let channel: LiveChannel
    let sourceID: UUID
    let sourceName: String

    @State private var isHovering = false

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
                    .stroke(
                        isHovering
                            ? Color.accentColor.opacity(0.9)
                            : Color.primary.opacity(0.10),
                        lineWidth: isHovering ? 2 : 1
                    )
            }
            .shadow(
                color: Color.black.opacity(isHovering ? 0.22 : 0.10),
                radius: isHovering ? 10 : 4,
                y: isHovering ? 5 : 2
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
        }
    }

    private var channelArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.15, blue: 0.21),
                    Color(red: 0.055, green: 0.065, blue: 0.095)
                ],
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
                urls: LiveChannelLogoResolver.urls(for: channel)
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
                .foregroundColor(.white.opacity(0.78))
                .padding(.horizontal, 18)
            }
        }
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
        if let current = currentAndNext.current {
            return "正在播放：\(current.title)"
        }
        guard channel.streams.count > 1 else { return nil }
        let format = channel.streams.first?.format?.uppercased() ?? "直播"
        return "\(format) · \(channel.streams.count) 条线路"
    }

    private var nextProgramme: String? {
        currentAndNext.next?.title
    }

    private var currentAndNext: (current: EPGProgramme?, next: EPGProgramme?) {
        state.loadedEPGGuides[sourceID]?
            .currentAndNext(for: channel, at: Date()) ?? (nil, nil)
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
                sourceID: sourceID
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加直播源")
                .font(.title2)
            Text("直播源独立于点播配置保存，支持 M3U、TXT 和 JSON。")
                .font(.callout)
                .foregroundColor(.secondary)
            Picker("方式", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            TextField("直播源名称（可选）", text: $name)
            if mode == .remote {
                TextField("https://example.com/channels.m3u", text: $remoteURL)
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
                TextField("相对频道地址的基准 URL（可选）", text: $baseURL)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                Button("添加") {
                    importValue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(22)
    }

    private var canImport: Bool {
        switch mode {
        case .remote:
            guard let url = URL(string: remoteURL),
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

    private func importValue() {
        let input: LiveSourceInput
        switch mode {
        case .remote:
            guard let url = URL(string: remoteURL) else { return }
            input = .remote(url)
        case .pasted:
            input = .pasted(
                text: pastedText,
                baseURL: baseURL.isEmpty ? nil : URL(string: baseURL)
            )
        }
        Task {
            let succeeded = await state.importLiveSource(
                source: input,
                name: name
            )
            if succeeded {
                isPresented = false
            }
        }
    }
}
