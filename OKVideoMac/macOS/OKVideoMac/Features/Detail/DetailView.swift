import OKVideoCore
import SwiftUI

struct DetailLoadingView: View {
    @EnvironmentObject private var state: AppState
    let summary: VideoSummary

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VideoPosterView(item: summary)
                    .frame(width: 150)

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
                        ProgressView()
                            .controlSize(.small)
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
                ProgressView()
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
            .padding(18)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    let detail: VideoDetail

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VideoPosterView(item: detail.summary)
                    .frame(width: 150)

                VStack(alignment: .leading, spacing: 9) {
                    Text(detail.summary.title)
                        .font(.title)
                    Text("来源：\(detail.summary.siteName)")
                        .foregroundColor(.secondary)
                    if let year = detail.summary.year {
                        Text("年份：\(year)")
                    }
                    if let actors = detail.actors, !actors.isEmpty {
                        Text("演员：\(actors)")
                            .lineLimit(2)
                    }
                    if let synopsis = detail.synopsis, !synopsis.isEmpty {
                        Text(synopsis)
                            .foregroundColor(.secondary)
                            .lineLimit(5)
                    }
                    Button {
                        Task { await state.toggleFavorite(detail) }
                    } label: {
                        Label("收藏/取消收藏", systemImage: "star")
                    }
                }
                Spacer()
            }
            .padding()

            Divider()

            if detail.playSources.isEmpty {
                EmptyStateView(
                    systemImage: "play.slash",
                    title: "没有播放线路",
                    message: "站点详情未提供可用分集。"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(detail.playSources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(source.name)
                                    .font(.headline)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                                    alignment: .leading
                                ) {
                                    ForEach(source.episodes) { episode in
                                        Button(episode.name) {
                                            Task {
                                                await state.startPlayback(
                                                    detail: detail,
                                                    source: source,
                                                    episode: episode
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            DetailCloseButton {
                state.dismissDetail()
            }
            .padding(18)
        }
        .overlay {
            if let prompt = state.cloudAuthorizationPrompt {
                CloudAuthorizationView(prompt: prompt)
                    .environmentObject(state)
            }
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
                .frame(width: 34, height: 34)
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
