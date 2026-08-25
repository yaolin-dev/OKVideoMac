import AppKit
import Foundation
import OKVideoCore
import SwiftUI

struct DetailLoadingView: View {
    @EnvironmentObject private var state: AppState
    let summary: VideoSummary

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VideoPosterView(item: summary)
                    .frame(width: 128)

                VStack(alignment: .leading, spacing: 10) {
                    Text(summary.title)
                        .font(.title)
                    Text("来源：\(summary.siteName)")
                        .foregroundColor(.secondary)
                    if let remarks = VideoCardMetadata.secondaryText(
                        from: summary.remarks
                    ) {
                        Text(remarks)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 10) {
                        AppActivityIndicator(size: .small)
                        Text("正在加载详情和播放线路…")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
                Spacer()
            }
            .padding()

            Divider()

            VStack(spacing: 12) {
                AppActivityIndicator(size: .regular)
                Text("内容载入后会自动显示选集")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            DetailCloseButton {
                state.dismissDetail()
            }
            .padding(14)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    let detail: VideoDetail
    @AppStorage("detail.lastPlaySourceName") private var lastPlaySourceName = ""
    @State private var selectedSourceIndex = 0
    @State private var episodeSearchKeyword = ""
    @State private var episodeSortOrder: EpisodeSortOrder = .sourceOrder
    @State private var selectedRangeID: String?
    @State private var episodeScrollRevision = 0
    @State private var preparedPresentations: [EpisodePresentation] = []
    @State private var preparedRangeOptions: [EpisodeRangeOption] = []
    @State private var isPreparingEpisodes = false
    @State private var showsAllActors = false
    @State private var showsFullSynopsis = false

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            Divider()

            if detail.playSources.isEmpty {
                EmptyStateView(
                    systemImage: "play.slash",
                    title: "没有播放线路",
                    message: "站点详情未提供可用分集。"
                )
            } else {
                playbackBrowser
            }
        }
        .overlay(alignment: .topTrailing) {
            DetailCloseButton {
                state.dismissDetail()
            }
            .padding(14)
        }
        .overlay {
            if let prompt = state.detailCloudAuthorizationPrompt {
                CloudAuthorizationView(prompt: prompt)
                    .environmentObject(state)
            }
        }
        .onAppear(perform: performInitialSelection)
        .task(id: selectedSource?.id) {
            await prepareSelectedSourceEpisodes()
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
            resetEpisodeScroll()
        }
        .onChange(of: selectedRangeID) { _ in
            resetEpisodeScroll()
        }
        .onChange(of: episodeSearchKeyword) { _ in
            resetEpisodeScroll()
        }
        .onChange(of: episodeSortOrder) { _ in
            resetEpisodeScroll()
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VideoPosterView(item: detail.summary)
                .frame(width: 128)

            VStack(alignment: .leading, spacing: 10) {
                Text(detail.summary.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 7) {
                    DetailMetadataBadge(
                        title: detail.summary.siteName,
                        systemImage: "network"
                    )
                    if let year = detail.summary.year?.trimmedNonEmpty {
                        DetailMetadataBadge(
                            title: year,
                            systemImage: "calendar"
                        )
                    }
                    if let category = detail.summary.categoryName?.trimmedNonEmpty {
                        DetailMetadataBadge(
                            title: category,
                            systemImage: "tag"
                        )
                    }
                }

                if let actors = detail.actors?.trimmedNonEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("演员：\(actors)")
                            .font(.callout)
                            .lineLimit(showsAllActors ? nil : 2)
                        if actors.count > 70 {
                            DetailExpandButton(
                                isExpanded: showsAllActors,
                                expandTitle: "展开演员",
                                collapseTitle: "收起演员"
                            ) {
                                showsAllActors.toggle()
                            }
                        }
                    }
                }

                if let synopsis = detail.synopsis?.trimmedNonEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(synopsis)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(showsFullSynopsis ? nil : 4)
                        if synopsis.count > 100 {
                            DetailExpandButton(
                                isExpanded: showsFullSynopsis,
                                expandTitle: "展开简介",
                                collapseTitle: "收起简介"
                            ) {
                                showsFullSynopsis.toggle()
                            }
                        }
                    }
                }

                Button {
                    Task { await state.toggleFavorite(detail) }
                } label: {
                    Label(
                        isFavorite ? "已收藏" : "收藏",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isFavorite ? .yellow : .accentColor)
                .help(isFavorite ? "点击取消收藏" : "点击收藏")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 34)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var playbackBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("播放线路")
                        .font(.headline)
                    Text("共 \(detail.playSources.count) 条")
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
                        withAnimation(.easeOut(duration: 0.16)) {
                            sourceProxy.scrollTo(selectedIndex, anchor: .center)
                        }
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
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            episodeContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var episodeControls: some View {
        if let source = selectedSource, source.episodes.count > 1 {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索集数或原始名称", text: $episodeSearchKeyword)
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

                Picker("排序", selection: $episodeSortOrder) {
                    ForEach(EpisodeSortOrder.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 126)
                .disabled(!canSortEpisodes)
                .help(
                    canSortEpisodes
                        ? "只使用真实识别到的集数排序"
                        : "当前线路没有足够的可靠集数信息"
                )
            }
        }
    }

    @ViewBuilder
    private var episodeContent: some View {
        if isPreparingEpisodes {
            VStack(spacing: 10) {
                AppActivityIndicator(size: .small)
                Text("正在整理 \(selectedSource?.episodes.count ?? 0) 集…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredPresentations.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "没有匹配的分集",
                message: "请更换关键词或选择其他分集区间。"
            )
        } else {
            ScrollViewReader { episodeProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear
                            .frame(height: 0)
                            .id(DetailEpisodeScrollTarget.top)

                        if !regularPresentations.isEmpty {
                            EpisodeSection(
                                title: "剧集",
                                episodes: regularPresentations,
                                onPlay: playSelectedEpisode
                            )
                        }

                        if !otherPresentations.isEmpty {
                            EpisodeSection(
                                title: isSingleEpisode
                                    ? "播放"
                                    : regularPresentations.isEmpty ? "播放资源" : "其他资源",
                                episodes: otherPresentations,
                                onPlay: playSelectedEpisode
                            )
                        }
                    }
                    .padding(20)
                }
                .padding(.top, 8)
                .onChange(of: episodeScrollRevision) { _ in
                    DispatchQueue.main.async {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            episodeProxy.scrollTo(
                                DetailEpisodeScrollTarget.top,
                                anchor: .top
                            )
                        }
                    }
                }
            }
        }
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

    private var regularPresentations: [EpisodePresentation] {
        filteredPresentations.filter { $0.episodeNumber != nil }
    }

    private var otherPresentations: [EpisodePresentation] {
        filteredPresentations.filter { $0.episodeNumber == nil }
    }

    private var rangeOptions: [EpisodeRangeOption] {
        preparedRangeOptions
    }

    private var canSortEpisodes: Bool {
        allPresentations.lazy.filter { $0.episodeNumber != nil }.prefix(2).count == 2
    }

    private var isFavorite: Bool {
        state.favorites.contains { $0.id == detail.summary.id }
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

    private func resetEpisodeScroll() {
        episodeScrollRevision &+= 1
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
            source: source
        )
        guard !Task.isCancelled, selectedSource?.id == sourceID else { return }
        preparedPresentations = snapshot.values
        preparedRangeOptions = snapshot.rangeOptions
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

private struct DetailCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovering ? .white : .primary)
        .background {
            Circle()
                .fill(
                    isHovering
                        ? Color.accentColor
                        : Color(nsColor: .windowBackgroundColor).opacity(0.92)
                )
        }
        .overlay {
            Circle()
                .stroke(
                    isHovering
                        ? Color.accentColor.opacity(0.65)
                        : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(isHovering ? 0.18 : 0.1), radius: 7, y: 2)
        .scaleEffect(isHovering ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("关闭详情")
        .accessibilityLabel("关闭详情")
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
            .foregroundColor(.accentColor)
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
            return "源顺序"
        case .episodeAscending:
            return "集数正序"
        case .episodeDescending:
            return "集数倒序"
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
}

private struct EpisodePresentationRepositoryKey: Hashable, Sendable {
    let videoID: String
    let sourceID: String
    let episodeCount: Int
    let firstEpisodeID: String?
    let lastEpisodeID: String?
}

actor EpisodePresentationRepository {
    static let shared = EpisodePresentationRepository()

    private var snapshots: [
        EpisodePresentationRepositoryKey: EpisodePresentationSnapshot
    ] = [:]
    private let capacity = 24

    func snapshot(
        videoID: String,
        source: PlaySource
    ) -> EpisodePresentationSnapshot {
        let key = EpisodePresentationRepositoryKey(
            videoID: videoID,
            sourceID: source.id,
            episodeCount: source.episodes.count,
            firstEpisodeID: source.episodes.first?.id,
            lastEpisodeID: source.episodes.last?.id
        )
        if let snapshot = snapshots[key] {
            return snapshot
        }

        let values = EpisodeListPresentation.presentations(
            from: source.episodes,
            query: "",
            sortOrder: .sourceOrder
        )
        let snapshot = EpisodePresentationSnapshot(
            values: values,
            valuesByEpisodeID: Dictionary(
                values.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            ),
            rangeOptions: EpisodeListPresentation.rangeOptions(from: values)
        )
        if snapshots.count >= capacity, let oldestKey = snapshots.keys.first {
            snapshots.removeValue(forKey: oldestKey)
        }
        snapshots[key] = snapshot
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

private struct EpisodeSequenceCandidate: Hashable {
    enum Key: Hashable {
        case seasonEpisode(Int)
        case episodeCode
        case explicitUnit
        case bareUnit
        case numericSlot(Int)
    }

    let key: Key
    let number: Int
    let seasonNumber: Int?
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
                    rangeButton(title: "全部", id: nil)
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
            rangeButton(title: "全部", id: nil)

            Text("分集区间")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("分集区间", selection: $selectedID) {
                Text("选择区间").tag(String?.none)
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
            .help("上一分集区间")

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
            .help("下一分集区间")

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

enum DetailEpisodeScrollTarget {
    static let top = "detail-episode-scroll-top"
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
            Button("查看原始名称…") {
                DispatchQueue.main.async {
                    showsOriginalNamePopover = true
                }
            }
            Button("复制原始名称") {
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
        .accessibilityLabel("播放 \(presentation.displayName)")
        .accessibilityHint("右键可以查看或复制原始名称")
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
                Text("文件信息")
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
                .help("关闭")
                .accessibilityLabel("关闭文件信息")
            }

            Text("原始名称")
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
                        didCopy ? "已复制" : "复制名称",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("点击外部或按 Esc 关闭")
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

private final class EpisodeRegexCache: @unchecked Sendable {
    static let shared = EpisodeRegexCache()

    private let cache = NSCache<NSString, NSRegularExpression>()

    func regex(for pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let regex = cache.object(forKey: key) {
            return regex
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        cache.setObject(regex, forKey: key)
        return regex
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
    static func presentation(
        for episode: PlayEpisode,
        sourceIndex: Int = 0
    ) -> EpisodePresentation {
        let original = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameCandidate = original.isEmpty ? episode.url : original
        let compact = compactName(nameCandidate)
        let isMediaFilename = firstMatch(
            in: nameCandidate,
            pattern: #"(?i)\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm)(?:$|[?#\s【\[])"#
        ) != nil

        if let special = specialName(in: compact) {
            return EpisodePresentation(
                episode: episode,
                displayName: special,
                originalName: original.isEmpty ? compact : original,
                seasonNumber: nil,
                episodeNumber: nil,
                isSpecial: true,
                sourceIndex: sourceIndex
            )
        }

        if let values = captures(
            in: compact,
            pattern: #"(?i)(?:^|[^A-Z0-9])S(\d{1,2})[ ._-]*E(\d{1,4})(?:[^0-9]|$)"#,
            captureCount: 2
        ), let season = Int(values[0]), let number = Int(values[1]) {
            return EpisodePresentation(
                episode: episode,
                displayName: "第 \(season) 季 · 第 \(number) 集",
                originalName: original.isEmpty ? compact : original,
                seasonNumber: season,
                episodeNumber: number,
                isSpecial: false,
                sourceIndex: sourceIndex
            )
        }

        // Some providers append the series description after the real file name,
        // for example: "05.mp4【你好，旧时光.全30集】".  Read the number
        // immediately before the media extension before considering descriptive
        // text such as "全30集", otherwise every item is mislabeled as episode 30.
        if isMediaFilename, let values = captures(
            in: compact,
            pattern: #"(?i)(?:^|[/\\._\-\]\s])(\d{1,4})(?=\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm)(?:$|[?#\s【\[]))"#,
            captureCount: 1
        ), let number = Int(values[0]), (1...999).contains(number) {
            return regularPresentation(
                episode: episode,
                compact: compact,
                original: original,
                number: number,
                displayName: "第 \(number) 集",
                sourceIndex: sourceIndex
            )
        }

        if let values = captures(
            in: compact,
            pattern: #"(?i)(?:^|[^A-Z])(?:EP|E)[ ._-]*(\d{1,4})(?:[^0-9]|$)"#,
            captureCount: 1
        ), let number = Int(values[0]) {
            return regularPresentation(
                episode: episode,
                compact: compact,
                original: original,
                number: number,
                displayName: "第 \(number) 集",
                sourceIndex: sourceIndex
            )
        }

        if let values = captures(
            in: compact,
            pattern: #"(?:^|[^全共\d])第?\s*(\d{1,4})\s*(集|话)"#,
            captureCount: 2
        ), let number = Int(values[0]) {
            let unit = values[1] == "话" ? "话" : "集"
            return regularPresentation(
                episode: episode,
                compact: compact,
                original: original,
                number: number,
                displayName: "第 \(number) \(unit)",
                sourceIndex: sourceIndex
            )
        }

        if let values = captures(
            in: compact,
            pattern: #"^(\d{1,4})$"#,
            captureCount: 1
        ), let number = Int(values[0]), (1...999).contains(number) {
            return regularPresentation(
                episode: episode,
                compact: compact,
                original: original,
                number: number,
                displayName: "第 \(number) 集",
                sourceIndex: sourceIndex
            )
        }

        if isMediaFilename, let values = captures(
            in: compact,
            pattern: #"(?:^|[._\-\s])(\d{1,4})$"#,
            captureCount: 1
        ), let number = Int(values[0]), (1...999).contains(number) {
            return regularPresentation(
                episode: episode,
                compact: compact,
                original: original,
                number: number,
                displayName: "第 \(number) 集",
                sourceIndex: sourceIndex
            )
        }

        return EpisodePresentation(
            episode: episode,
            displayName: compact,
            originalName: original.isEmpty ? compact : original,
            seasonNumber: nil,
            episodeNumber: nil,
            isSpecial: false,
            sourceIndex: sourceIndex
        )
    }

    static func compactName(_ rawValue: String) -> String {
        var value = rawValue.removingPercentEncoding ?? rawValue
        if let mediaMatch = firstMatch(
            in: value,
            pattern: #"(?i)\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm|m3u8)(?=$|[?#\s【\[])"#
        ) {
            // Cloud-drive providers append the containing folder after the
            // real file name, for example "S01E01.mkv【Show/4K HDR】".
            // Taking lastPathComponent from the whole label mistakes that
            // descriptive slash for a URL path and discards the episode code.
            // Limit path compaction to the actual media-file portion first.
            let text = value as NSString
            value = text.substring(to: NSMaxRange(mediaMatch.range))
            if let last = value.split(separator: "/").last, !last.isEmpty {
                value = String(last)
            }
        } else if let components = URLComponents(string: value),
                  let url = components.url,
                  !url.lastPathComponent.isEmpty {
            value = url.lastPathComponent
        } else {
            value = value.components(separatedBy: "?").first ?? value
            value = value.components(separatedBy: "#").first ?? value
            if let last = value.split(separator: "/").last {
                value = String(last)
            }
        }
        value = value.replacingOccurrences(
            of: #"\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm|m3u8)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"^\s*\[[^\]]{1,24}\]\s*"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名资源" : trimmed
    }

    fileprivate static func sequenceCandidates(
        for episode: PlayEpisode
    ) -> [EpisodeSequenceCandidate] {
        let original = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameCandidate = original.isEmpty ? episode.url : original
        let compact = compactName(nameCandidate)
        guard specialName(in: compact) == nil else { return [] }

        var candidates: [EpisodeSequenceCandidate] = []
        if let values = captures(
            in: compact,
            pattern: #"(?i)(?:^|[^A-Z0-9])S(\d{1,2})[ ._-]*E(\d{1,4})(?:[^0-9]|$)"#,
            captureCount: 2
        ), let season = Int(values[0]), let number = Int(values[1]),
           isPlausibleEpisodeNumber(number) {
            candidates.append(
                EpisodeSequenceCandidate(
                    key: .seasonEpisode(season),
                    number: number,
                    seasonNumber: season
                )
            )
        }

        if let values = captures(
            in: compact,
            pattern: #"(?i)(?:^|[^A-Z0-9])(?:EP|E)[ ._-]*(\d{1,4})(?:[^0-9]|$)"#,
            captureCount: 1
        ), let number = Int(values[0]), isPlausibleEpisodeNumber(number) {
            candidates.append(
                EpisodeSequenceCandidate(
                    key: .episodeCode,
                    number: number,
                    seasonNumber: nil
                )
            )
        }

        let unitPattern = #"(?:^|[^全共\d])(第)?\s*(\d{1,4})\s*(集|话)"#
        if let regex = EpisodeRegexCache.shared.regex(for: unitPattern) {
            let text = compact as NSString
            let matches = regex.matches(
                in: compact,
                range: NSRange(location: 0, length: text.length)
            )
            for match in matches {
                let prefixRange = match.range(at: 1)
                let numberRange = match.range(at: 2)
                guard numberRange.location != NSNotFound,
                      let number = Int(text.substring(with: numberRange)),
                      isPlausibleEpisodeNumber(number) else {
                    continue
                }
                candidates.append(
                    EpisodeSequenceCandidate(
                        key: prefixRange.location == NSNotFound
                            ? .bareUnit
                            : .explicitUnit,
                        number: number,
                        seasonNumber: nil
                    )
                )
            }
        }

        let stem = filenameStem(from: compact)
        if let regex = EpisodeRegexCache.shared.regex(for: #"\d{1,4}"#) {
            let text = stem as NSString
            let matches = regex.matches(
                in: stem,
                range: NSRange(location: 0, length: text.length)
            )
            var slot = 0
            for match in matches {
                guard let number = Int(text.substring(with: match.range)),
                      isPlausibleEpisodeNumber(number),
                      isGenericEpisodeToken(in: text, range: match.range) else {
                    continue
                }
                candidates.append(
                    EpisodeSequenceCandidate(
                        key: .numericSlot(slot),
                        number: number,
                        seasonNumber: nil
                    )
                )
                slot += 1
            }
        }

        var unique: [EpisodeSequenceCandidate.Key: EpisodeSequenceCandidate] = [:]
        for candidate in candidates where unique[candidate.key] == nil {
            unique[candidate.key] = candidate
        }
        return Array(unique.values)
    }

    private static func filenameStem(from compact: String) -> String {
        guard let match = firstMatch(
            in: compact,
            pattern: #"(?i)\.(?:mkv|mp4|m4v|mov|avi|ts|m2ts|flv|webm)(?:$|[?#\s【\[])"#
        ) else {
            return compact
        }
        let text = compact as NSString
        return text.substring(to: match.range.location)
    }

    private static func isPlausibleEpisodeNumber(_ number: Int) -> Bool {
        (1...999).contains(number)
    }

    private static func isGenericEpisodeToken(
        in text: NSString,
        range: NSRange
    ) -> Bool {
        let before = range.location > 0
            ? text.substring(with: NSRange(location: range.location - 1, length: 1))
            : ""
        let afterLocation = NSMaxRange(range)
        let after = afterLocation < text.length
            ? text.substring(with: NSRange(location: afterLocation, length: 1))
            : ""
        let beforeTwo = range.location > 1
            ? text.substring(with: NSRange(location: range.location - 2, length: 2))
            : before

        if before.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
            || after.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            return false
        }
        if beforeTwo.range(
            of: #"(?i)(?:H\.|X)$"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        return true
    }

    private static func regularPresentation(
        episode: PlayEpisode,
        compact: String,
        original: String,
        number: Int,
        displayName: String,
        sourceIndex: Int
    ) -> EpisodePresentation {
        EpisodePresentation(
            episode: episode,
            displayName: displayName,
            originalName: original.isEmpty ? compact : original,
            seasonNumber: nil,
            episodeNumber: number,
            isSpecial: false,
            sourceIndex: sourceIndex
        )
    }

    private static func specialName(in compact: String) -> String? {
        let specialWords = [
            "番外", "花絮", "预告", "特别篇", "特辑", "彩蛋", "幕后",
            "上篇", "中篇", "下篇", "上集", "下集", "大结局"
        ]
        let containsSpecialWord = specialWords.contains { compact.contains($0) }
        let containsSpecialCode = firstMatch(
            in: compact,
            pattern: #"(?i)(?:^|[^A-Z0-9])(?:SP|OVA)[ ._-]*\d{0,3}(?:[^A-Z0-9]|$)"#
        ) != nil
        guard containsSpecialWord || containsSpecialCode else { return nil }
        return compact
    }

    private static func captures(
        in value: String,
        pattern: String,
        captureCount: Int
    ) -> [String]? {
        guard let match = firstMatch(in: value, pattern: pattern) else { return nil }
        let text = value as NSString
        let captures = (1...captureCount).compactMap { index -> String? in
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return text.substring(with: range)
        }
        return captures.count == captureCount ? captures : nil
    }

    private static func firstMatch(
        in value: String,
        pattern: String
    ) -> NSTextCheckingResult? {
        guard let regex = EpisodeRegexCache.shared.regex(for: pattern) else {
            return nil
        }
        return regex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        )
    }
}

enum EpisodeListPresentation {
    private struct SequenceInference {
        let key: EpisodeSequenceCandidate.Key
        let candidatesByIndex: [Int: EpisodeSequenceCandidate]
        let score: Int
    }

    static func presentations(
        from episodes: [PlayEpisode],
        query: String,
        sortOrder: EpisodeSortOrder
    ) -> [EpisodePresentation] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatesByIndex = episodes.map(EpisodeNameParser.sequenceCandidates)
        let inference = sequenceInference(
            episodeCount: episodes.count,
            candidatesByIndex: candidatesByIndex
        )
        let repeatedBareUnitNumbers = repeatedNumbers(
            for: .bareUnit,
            candidatesByIndex: candidatesByIndex
        )
        var values = episodes.enumerated().map { index, episode in
            let parsed = EpisodeNameParser.presentation(
                for: episode,
                sourceIndex: index
            )
            guard !parsed.isSpecial else { return parsed }

            if let inference,
               let candidate = inference.candidatesByIndex[index] {
                return presentation(
                    replacing: parsed,
                    with: candidate
                )
            }

            if let number = parsed.episodeNumber,
               repeatedBareUnitNumbers.contains(number),
               candidatesByIndex[index].contains(where: {
                   $0.key == .bareUnit && $0.number == number
               }) {
                return presentationWithoutEpisodeNumber(parsed)
            }

            return parsed
        }
        if values.count == 1, let only = values.first {
            values[0] = EpisodePresentation(
                episode: only.episode,
                displayName: "正片",
                originalName: only.originalName,
                seasonNumber: nil,
                episodeNumber: nil,
                isSpecial: false,
                sourceIndex: only.sourceIndex
            )
        }
        if !keyword.isEmpty {
            values = values.filter {
                $0.displayName.localizedCaseInsensitiveContains(keyword)
                    || $0.originalName.localizedCaseInsensitiveContains(keyword)
            }
        }

        switch sortOrder {
        case .sourceOrder:
            return values
        case .episodeAscending:
            return values.sorted { lhs, rhs in
                compare(lhs, rhs, ascending: true)
            }
        case .episodeDescending:
            return values.sorted { lhs, rhs in
                compare(lhs, rhs, ascending: false)
            }
        }
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

    private static func sequenceInference(
        episodeCount: Int,
        candidatesByIndex: [[EpisodeSequenceCandidate]]
    ) -> SequenceInference? {
        guard episodeCount > 1 else { return nil }
        var occurrences: [EpisodeSequenceCandidate.Key: [Int: EpisodeSequenceCandidate]] = [:]
        for (index, candidates) in candidatesByIndex.enumerated() {
            for candidate in candidates {
                occurrences[candidate.key, default: [:]][index] = candidate
            }
        }

        let minimumCoverage = episodeCount == 2
            ? 2
            : max(3, Int(ceil(Double(episodeCount) * 0.5)))
        return occurrences.compactMap { key, byIndex -> SequenceInference? in
            let ordered = byIndex.sorted { $0.key < $1.key }
            guard ordered.count >= minimumCoverage else { return nil }

            let numbers = ordered.map { $0.value.number }
            let differences = zip(numbers, numbers.dropFirst()).map { $1 - $0 }
            guard let firstDifference = differences.first(where: { $0 != 0 }) else {
                return nil
            }
            let direction = firstDifference > 0 ? 1 : -1
            guard differences.allSatisfy({ difference in
                difference != 0 && (difference > 0 ? 1 : -1) == direction
            }) else {
                return nil
            }

            let steps = differences.map { abs($0) }
            if ordered.count == 2 {
                guard steps[0] <= 10 else { return nil }
            } else {
                let consecutiveCount = steps.filter { $0 == 1 }.count
                guard consecutiveCount * 2 >= steps.count else { return nil }
            }

            guard let minimum = numbers.min(), let maximum = numbers.max(),
                  maximum - minimum <= max(100, episodeCount * 3) else {
                return nil
            }

            let consecutiveCount = steps.filter { $0 == 1 }.count
            let gapPenalty = steps.reduce(0) { $0 + max(0, $1 - 1) }
            let score = ordered.count * 100
                + consecutiveCount * 30
                + priority(for: key)
                - min(gapPenalty, 100)
            return SequenceInference(
                key: key,
                candidatesByIndex: byIndex,
                score: score
            )
        }
        .max { lhs, rhs in
            if lhs.score == rhs.score {
                return priority(for: lhs.key) < priority(for: rhs.key)
            }
            return lhs.score < rhs.score
        }
    }

    private static func repeatedNumbers(
        for key: EpisodeSequenceCandidate.Key,
        candidatesByIndex: [[EpisodeSequenceCandidate]]
    ) -> Set<Int> {
        let values = candidatesByIndex.flatMap { candidates in
            candidates.filter { $0.key == key }.map(\.number)
        }
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private static func priority(
        for key: EpisodeSequenceCandidate.Key
    ) -> Int {
        switch key {
        case .seasonEpisode:
            return 50
        case .episodeCode:
            return 40
        case .explicitUnit:
            return 30
        case .bareUnit:
            return 10
        case .numericSlot:
            return 0
        }
    }

    private static func presentation(
        replacing original: EpisodePresentation,
        with candidate: EpisodeSequenceCandidate
    ) -> EpisodePresentation {
        let displayName: String
        if let season = candidate.seasonNumber {
            displayName = "第 \(season) 季 · 第 \(candidate.number) 集"
        } else {
            displayName = "第 \(candidate.number) 集"
        }
        return EpisodePresentation(
            episode: original.episode,
            displayName: displayName,
            originalName: original.originalName,
            seasonNumber: candidate.seasonNumber,
            episodeNumber: candidate.number,
            isSpecial: false,
            sourceIndex: original.sourceIndex
        )
    }

    private static func presentationWithoutEpisodeNumber(
        _ original: EpisodePresentation
    ) -> EpisodePresentation {
        EpisodePresentation(
            episode: original.episode,
            displayName: EpisodeNameParser.compactName(original.originalName),
            originalName: original.originalName,
            seasonNumber: nil,
            episodeNumber: nil,
            isSpecial: false,
            sourceIndex: original.sourceIndex
        )
    }

    static func rangeOptions(
        from presentations: [EpisodePresentation]
    ) -> [EpisodeRangeOption] {
        let numbered = presentations
            .filter { $0.episodeNumber != nil }
            .sorted { compare($0, $1, ascending: true) }
        guard numbered.count > 40 else { return [] }

        return stride(from: 0, to: numbered.count, by: 20).map { start in
            let end = min(start + 20, numbered.count)
            let chunk = Array(numbered[start..<end])
            let first = chunk.first!
            let last = chunk.last!
            let firstNumber = first.episodeNumber!
            let lastNumber = last.episodeNumber!
            let title: String
            if first.seasonNumber == last.seasonNumber,
               let season = first.seasonNumber {
                title = "第 \(season) 季 · \(firstNumber)–\(lastNumber) 集"
            } else {
                title = "\(firstNumber)–\(lastNumber) 集"
            }
            return EpisodeRangeOption(
                id: "\(start)-\(end)",
                title: title,
                episodeIDs: Set(chunk.map(\.id))
            )
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
