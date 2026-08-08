import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState

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
                            Button {
                                Task { await state.openHistory(item) }
                            } label: {
                                HStack(spacing: 18) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.title)
                                            .font(.headline)
                                        Text(
                                            [item.sourceName, item.episodeName]
                                                .compactMap { $0 }
                                                .joined(separator: " · ")
                                        )
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                                .contentShape(Rectangle())
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .navigationTitle("历史")
    }
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
