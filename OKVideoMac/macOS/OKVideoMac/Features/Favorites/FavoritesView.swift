import OKVideoPersistence
import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    @State private var isSelecting = false
    @State private var selectedIDs: Set<FavoriteRecord.ID> = []
    @State private var pendingDeletion: FavoriteDeletion?

    var body: some View {
        Group {
            if state.favorites.isEmpty {
                EmptyStateView(
                    systemImage: "star",
                    title: "暂无收藏",
                    message: "在影片详情中选择收藏后会显示在这里。"
                )
            } else {
                List(state.favorites) { favorite in
                    favoriteRow(favorite)
                        .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("收藏")
        .toolbar {
            ToolbarItemGroup {
                if !state.favorites.isEmpty {
                    favoriteManagementControls
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
        .onChange(of: state.favorites.map(\.id)) { availableIDs in
            selectedIDs.formIntersection(availableIDs)
            if state.favorites.isEmpty {
                isSelecting = false
            }
        }
    }

    @ViewBuilder
    private func favoriteRow(_ favorite: FavoriteRecord) -> some View {
        HStack(spacing: 6) {
            Button {
                if isSelecting {
                    toggleSelection(favorite.id)
                } else {
                    Task { await state.openFavorite(favorite) }
                }
            } label: {
                HStack(spacing: 12) {
                    if isSelecting {
                        Image(
                            systemName: selectedIDs.contains(favorite.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            selectedIDs.contains(favorite.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .frame(width: 22)
                    }

                    RemoteImage(url: favorite.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "film")
                    }
                    .frame(width: 48, height: 72)
                    .background(Color.secondary.opacity(0.12))
                    .clipped()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(favorite.title)
                            .font(.headline)
                        Text("站点：\(favorite.siteKey)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let synopsis = favorite.synopsis {
                            Text(synopsis)
                                .lineLimit(2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appInteractiveHover(cornerRadius: 10, selected: selectedIDs.contains(favorite.id))
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeletion = .items([favorite.id])
                } label: {
                    Label("删除这条收藏", systemImage: "trash")
                }
            }

            if !isSelecting {
                Button(role: .destructive) {
                    pendingDeletion = .items([favorite.id])
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .appInteractiveHover(cornerRadius: 8, destructive: true)
                .foregroundStyle(.secondary)
                .help("删除这条收藏")
            }
        }
    }

    @ViewBuilder
    private var favoriteManagementControls: some View {
        if isSelecting {
            Button(allItemsSelected ? "取消全选" : "全选") {
                selectedIDs = allItemsSelected
                    ? []
                    : Set(state.favorites.map(\.id))
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
                Label("清空收藏", systemImage: "trash")
            }
        }
    }

    private var allItemsSelected: Bool {
        !state.favorites.isEmpty && selectedIDs.count == state.favorites.count
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var deletionTitle: String {
        if case .some(.all) = pendingDeletion {
            return "清空全部收藏？"
        }
        return "删除收藏？"
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .some(.all):
            return "将删除全部影片收藏，此操作无法撤销。"
        case let .some(.items(ids)):
            return "将删除所选的 \(ids.count) 条收藏，此操作无法撤销。"
        case nil:
            return ""
        }
    }

    private func toggleSelection(_ id: FavoriteRecord.ID) {
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
                await state.clearFavorites()
            case let .some(.items(ids)):
                await state.deleteFavorites(ids: ids)
            case nil:
                break
            }
            selectedIDs.removeAll()
            isSelecting = false
        }
    }
}

private enum FavoriteDeletion {
    case items(Set<FavoriteRecord.ID>)
    case all
}
