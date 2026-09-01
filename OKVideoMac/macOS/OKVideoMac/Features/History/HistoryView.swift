import AppKit
import OKVideoPersistence
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.primaryToolbarLayout) private var toolbarLayout
    @State private var isSelecting = false
    @State private var selectedIDs: Set<HistoryRecord.ID> = []
    @State private var pendingDeletion: HistoryDeletion?
    @State private var focusedID: HistoryRecord.ID?
    private let scrollCoordinateSpace = "history-scroll"

    var body: some View {
        Group {
            if state.history.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: "暂无播放历史",
                    message: "播放成功后会记录进度；历史默认保留 60 天。"
                )
            } else {
                ScrollView {
                    BrowserToolbarScrollMarker(
                        coordinateSpaceName: scrollCoordinateSpace
                    )
                    LazyVStack(spacing: 0) {
                        ForEach(state.history) { item in
                            historyRow(item)
                            Divider()
                                .padding(.leading, isSelecting ? 56 : 20)
                        }
                    }
                }
                .browserToolbarScrollSurface(named: scrollCoordinateSpace)
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: "历史")
            ToolbarItemGroup(placement: .primaryAction) {
                if !state.isDetailPagePresented,
                   !state.history.isEmpty {
                    historyManagementControls
                }
            }
        }
        .alert(
            deletionTitle,
            isPresented: deletionAlertIsPresented
        ) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                performDeletion()
            }
        } message: {
            Text(deletionMessage)
        }
        .onChange(of: state.history.map(\.id)) { availableIDs in
            selectedIDs.formIntersection(availableIDs)
            if focusedID.map({ availableIDs.contains($0) }) != true {
                focusedID = availableIDs.first
            }
            if state.history.isEmpty {
                isSelecting = false
            }
        }
        .onAppear {
            focusedID = focusedID ?? state.history.first?.id
        }
        .background {
            AppKeyCommandMonitor(handler: handleKeyCommand)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func historyRow(_ item: HistoryRecord) -> some View {
        HStack(spacing: 6) {
            Button {
                if isSelecting {
                    toggleSelection(item.id)
                } else {
                    state.requestHistoryPlayback(item)
                }
            } label: {
                HStack(spacing: 14) {
                    if isSelecting {
                        Image(
                            systemName: selectedIDs.contains(item.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            selectedIDs.contains(item.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .frame(width: 22)
                    }

                    historyContent(item)
                }
                .contentShape(Rectangle())
                .padding(.leading, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .appInteractiveHover(
                cornerRadius: 10,
                selected: selectedIDs.contains(item.id) || focusedID == item.id
            )
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeletion = .items([item.id])
                } label: {
                    Label("删除这条历史", systemImage: "trash")
                }
            }

            if !isSelecting {
                Button(role: .destructive) {
                    pendingDeletion = .items([item.id])
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .appInteractiveHover(cornerRadius: 8, destructive: true)
                .foregroundStyle(.secondary)
                .help("删除这条历史")
                .padding(.trailing, 14)
            }
        }
    }

    private func historyContent(_ item: HistoryRecord) -> some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.10)
                    Image(systemName: "film")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(
                    [
                        state.historySiteName(for: item),
                        item.sourceName,
                        item.episodeName
                    ]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                if item.duration > 0 {
                    HistoryProgressBar(
                        progress: item.position / item.duration
                    )
                    .frame(width: 260, height: 5)
                }
            }
            Spacer()
            Text(
                item.watchedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var historyManagementControls: some View {
        if isSelecting {
            switch toolbarLayout {
            case .expanded:
                selectAllButton
                deleteSelectedButton
                finishSelectionButton
            case .compact:
                selectAllButton.labelStyle(.iconOnly)
                deleteSelectedButton.labelStyle(.iconOnly)
                finishSelectionButton
            case .minimal:
                selectionManagementMenu
                finishSelectionButton
            }
        } else {
            switch toolbarLayout {
            case .expanded:
                beginSelectionButton
                clearAllButton
            case .compact:
                beginSelectionButton.labelStyle(.iconOnly)
                clearAllButton.labelStyle(.iconOnly)
            case .minimal:
                normalManagementMenu
            }
        }
    }

    private var selectAllButton: some View {
        Button {
            selectedIDs = allItemsSelected
                ? []
                : Set(state.history.map(\.id))
        } label: {
            Label(
                allItemsSelected ? "取消全选" : "全选",
                systemImage: allItemsSelected
                    ? "checkmark.circle.badge.xmark"
                    : "checkmark.circle"
            )
        }
        .help(allItemsSelected ? "取消全选" : "全选")
    }

    private var deleteSelectedButton: some View {
        Button(role: .destructive) {
            pendingDeletion = .items(selectedIDs)
        } label: {
            Label(
                selectedIDs.isEmpty
                    ? "删除所选"
                    : "删除所选（\(selectedIDs.count)）",
                systemImage: "trash"
            )
        }
        .disabled(selectedIDs.isEmpty)
        .help(selectedIDs.isEmpty ? "请先选择历史" : "删除所选历史")
    }

    private var finishSelectionButton: some View {
        Button("完成") {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    private var beginSelectionButton: some View {
        Button {
            isSelecting = true
        } label: {
            Label("选择", systemImage: "checklist")
        }
        .help("选择历史")
    }

    private var clearAllButton: some View {
        Button(role: .destructive) {
            pendingDeletion = .all
        } label: {
            Label("清空历史", systemImage: "trash")
        }
        .help("清空历史")
    }

    private var selectionManagementMenu: some View {
        Menu {
            selectAllButton
            deleteSelectedButton
        } label: {
            Label("选择操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help("选择操作")
    }

    private var normalManagementMenu: some View {
        Menu {
            beginSelectionButton
            clearAllButton
        } label: {
            Label("管理历史", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help("管理历史")
    }

    private var allItemsSelected: Bool {
        !state.history.isEmpty && selectedIDs.count == state.history.count
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var deletionTitle: String {
        if case .some(.all) = pendingDeletion {
            return "清空全部历史？"
        }
        return "删除历史记录？"
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .some(.all):
            return "将删除当前点播配置下的全部播放历史，此操作无法撤销。"
        case let .some(.items(ids)):
            return "将删除所选的 \(ids.count) 条播放历史，此操作无法撤销。"
        case nil:
            return ""
        }
    }

    private func toggleSelection(_ id: HistoryRecord.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func performDeletion() {
        let deletion = pendingDeletion
        pendingDeletion = nil
        Task {
            switch deletion {
            case .some(.all):
                await state.clearHistory()
            case let .some(.items(ids)):
                await state.deleteHistory(ids: ids)
            case nil:
                break
            }
            selectedIDs.removeAll()
            isSelecting = false
        }
    }

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            isSelecting = true
            selectedIDs = Set(state.history.map(\.id))
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125:
            moveFocus(by: 1)
        case 126:
            moveFocus(by: -1)
        case 36, 76:
            guard let focusedID,
                  let item = state.history.first(where: {
                      $0.id == focusedID
                  }) else { return false }
            if isSelecting {
                toggleSelection(focusedID)
            } else {
                state.requestHistoryPlayback(item)
            }
        case 51, 117:
            guard let focusedID else { return false }
            pendingDeletion = .items(
                isSelecting && !selectedIDs.isEmpty
                    ? selectedIDs : [focusedID]
            )
        case 53:
            guard isSelecting else { return false }
            isSelecting = false
            selectedIDs.removeAll()
        default:
            return false
        }
        return true
    }

    private func moveFocus(by offset: Int) {
        let ids = state.history.map(\.id)
        guard !ids.isEmpty else { return }
        let currentIndex = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusedID = ids[min(max(currentIndex + offset, 0), ids.count - 1)]
    }
}

private enum HistoryDeletion {
    case items(Set<HistoryRecord.ID>)
    case all
}

private struct HistoryProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: proxy.size.width * min(max(progress, 0), 1)
                    )
            }
        }
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100))%")
    }
}
