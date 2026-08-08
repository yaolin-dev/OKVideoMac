import OKVideoCore
import SwiftUI

struct VideoGrid: View {
    let items: [VideoSummary]
    let onSelect: (VideoSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        VideoPosterView(item: item)
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let remarks = VideoCardMetadata.secondaryText(
                            from: item.remarks
                        ) {
                            Text(remarks)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title)，来源 \(item.siteName)")
            }
        }
    }
}

enum VideoCardMetadata {
    static func ratingText(from remarks: String?) -> String? {
        guard let candidate = ratingCandidate(from: remarks),
              candidate.value > 0,
              candidate.value <= 10 else {
            return nil
        }
        return candidate.text
    }

    private static func ratingCandidate(
        from remarks: String?
    ) -> (text: String, value: Double)? {
        guard var text = normalized(remarks) else { return nil }
        for label in ["豆瓣评分", "评分", "豆瓣"] where text.hasPrefix(label) {
            text.removeFirst(label.count)
            text = text.trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":："))
            )
            break
        }
        if text.hasSuffix("分") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty,
              let value = Double(text),
              value.isFinite else {
            return nil
        }
        return (text, value)
    }

    static func secondaryText(from remarks: String?) -> String? {
        guard let text = normalized(remarks) else { return nil }
        return ratingCandidate(from: text) == nil ? text : nil
    }

    private static func normalized(_ remarks: String?) -> String? {
        let text = remarks?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return text.isEmpty ? nil : text
    }
}

struct VideoPosterView: View {
    let item: VideoSummary

    var body: some View {
        PosterView(url: item.posterURL)
            .overlay(alignment: .bottomTrailing) {
                if let rating = VideoCardMetadata.ratingText(
                    from: item.remarks
                ) {
                    Text(rating)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(8)
                        .accessibilityLabel("评分 \(rating)")
                }
            }
    }
}

struct AutomaticPageLoader: View {
    let isLoading: Bool
    let errorMessage: String?
    let viewportHeight: CGFloat
    let coordinateSpaceName: String
    let onLoad: () -> Void
    @State private var hasTriggered = false

    var body: some View {
        Group {
            if isLoading {
                VideoGridSkeleton()
            } else if errorMessage != nil {
                Button("加载失败，点击重试") {
                    onLoad()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .help(errorMessage ?? "下一页加载失败")
            } else if hasTriggered {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备下一页…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                GeometryReader { geometry in
                    let minY = geometry.frame(
                        in: .named(coordinateSpaceName)
                    ).minY
                    Color.clear
                        .task(id: Int(minY.rounded())) {
                            guard minY >= -8,
                                  minY <= viewportHeight + 4 else {
                                return
                            }
                            do {
                                try await Task.sleep(
                                    nanoseconds: 550_000_000
                                )
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, !hasTriggered else {
                                return
                            }
                            hasTriggered = true
                            onLoad()
                        }
                }
                .frame(height: 34)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isLoading ? "正在加载下一页" :
                (errorMessage != nil
                    ? "下一页加载失败，点击重试"
                    : (hasTriggered ? "正在准备下一页" : "继续滚动以加载下一页"))
        )
    }
}

struct PaginationCompletionFooter: View {
    let itemCount: Int

    var body: some View {
        Label("已加载全部，共 \(itemCount) 项", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityLabel("已加载全部，共 \(itemCount) 项")
    }
}

struct VideoGridSkeleton: View {
    var count = 6
    @State private var isPulsing = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.13))
                        .aspectRatio(2 / 3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 92, height: 11)
                }
                .opacity(isPulsing ? 0.42 : 1)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.85)
                    .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }
}

struct PosterView: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            if let url {
                RemoteImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } placeholder: {
                    ProgressView()
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.12))
        }
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.largeTitle)
            .foregroundColor(.secondary)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
