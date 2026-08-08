import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState

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
                    Button {
                        Task { await state.openFavorite(favorite) }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: favorite.posterURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "film")
                            }
                            .frame(width: 48, height: 72)
                            .background(Color.secondary.opacity(0.12))
                            .clipped()
                            VStack(alignment: .leading) {
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
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("收藏")
    }
}
