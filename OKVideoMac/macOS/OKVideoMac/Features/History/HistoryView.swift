import AppKit
import OKVideoPersistence
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var isSelecting = false
    @State private var selectedIDs: Set<HistoryRecord.ID> = []
    @State private var pendingDeletion: HistoryDeletion?
    @State private var focusedID: HistoryRecord.ID?

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
                    LazyVStack(spacing: 0) {
                        ForEach(state.history) { item in
                            historyRow(item)
                            Divider()
                                .padding(.leading, isSelecting ? 56 : 20)
                        }
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup {
                if !state.history.isEmpty {
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
            Button(allItemsSelected ? "取消全选" : "全选") {
                selectedIDs = allItemsSelected
                    ? []
                    : Set(state.history.map(\.id))
            }

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

            Button("完成") {
                isSelecting = false
                selectedIDs.removeAll()
            }
        } else {
            Button {
                isSelecting = true
            } label: {
                Label("选择", systemImage: "checklist")
            }

            Button(role: .destructive) {
                pendingDeletion = .all
            } label: {
                Label("清空历史", systemImage: "trash")
            }
        }
    }

    private var allItemsSelected: Bool {
        !state.history.isEmpty && selectedIDs.count == state.history.count
    }

    private var navigationTitle: String {
        let sourceName = state.activeConfigurationRecord?.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceName, !sourceName.isEmpty else {
            return "历史"
        }
        return "历史 · \(sourceName)"
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
