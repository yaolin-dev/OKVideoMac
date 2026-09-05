import OKVideoCore
import SwiftUI

struct AppActivityIndicatorLifecycle: Equatable {
    static let cycleDuration: TimeInterval = 0.85

    private(set) var isVisible = false
    private(set) var reduceMotion = false

    var isAnimating: Bool {
        isVisible && !reduceMotion
    }

    mutating func appear(reduceMotion: Bool) {
        isVisible = true
        self.reduceMotion = reduceMotion
    }

    mutating func updateReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    mutating func disappear() {
        isVisible = false
    }

    func rotationDegrees(at date: Date) -> Double {
        guard isAnimating else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.cycleDuration)
        return elapsed / Self.cycleDuration * 360
    }
}

struct AppActivityIndicator: View {
    enum Size {
        case mini
        case small
        case regular

        var diameter: CGFloat {
            switch self {
            case .mini: return 12
            case .small: return 16
            case .regular: return 28
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .mini: return 1.5
            case .small: return 2
            case .regular: return 3
            }
        }
    }

    let size: Size
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifecycle = AppActivityIndicatorLifecycle()

    init(size: Size = .regular, tint: Color = .accentColor) {
        self.size = size
        self.tint = tint
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: !lifecycle.isAnimating
            )
        ) { timeline in
            Circle()
                .trim(from: 0.08, to: 0.76)
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: size.lineWidth,
                        lineCap: .round
                    )
                )
                .frame(width: size.diameter, height: size.diameter)
                .rotationEffect(
                    .degrees(lifecycle.rotationDegrees(at: timeline.date))
                )
        }
        .frame(width: size.diameter, height: size.diameter)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载")
        .onAppear {
            lifecycle.appear(reduceMotion: reduceMotion)
        }
        .onDisappear {
            lifecycle.disappear()
        }
        .onChange(of: reduceMotion) { newValue in
            lifecycle.updateReduceMotion(newValue)
        }
    }
}

struct AppActivityLabel: View {
    let title: String
    let size: AppActivityIndicator.Size

    init(
        _ title: String,
        size: AppActivityIndicator.Size = .regular
    ) {
        self.title = title
        self.size = size
    }

    var body: some View {
        VStack(spacing: 9) {
            AppActivityIndicator(size: size)
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct VideoGrid: View {
    let items: [VideoSummary]
    let onSelect: (VideoSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                VideoCard(item: item) {
                    onSelect(item)
                }
            }
        }
    }
}

/// Shared native-looking segmented navigation treatment for home categories
/// and search result sources. The two screens retain independent overflow and
/// selection policies while sharing the exact same chrome and interaction
/// feedback.
enum BrowseSegmentedNavigationMetrics {
    static let rowHeight: CGFloat = 48
    static let controlHeight: CGFloat = 32
    static let horizontalPadding: CGFloat = 14
    static let minimumSegmentWidth: CGFloat = 62
    static let separatorWidth: CGFloat = 1
    static let containerInset: CGFloat = 2
    static let moreWidth: CGFloat = 66

    static func segmentWidth(textWidth: CGFloat) -> CGFloat {
        max(
            minimumSegmentWidth,
            ceil(textWidth) + horizontalPadding * 2
        )
    }

    static func innerAvailableWidth(_ availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - containerInset * 2)
    }
}

struct BrowseSegmentedNavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(BrowseSegmentedNavigationMetrics.containerInset)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.012))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct BrowseSegmentedNavigationDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.32))
            .frame(
                width: BrowseSegmentedNavigationMetrics.separatorWidth,
                height: 20
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BrowseSegmentedNavigationBottomDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.28))
            .frame(height: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BrowseSegmentedNavigationLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(
                .system(
                    size: 13,
                    weight: isSelected ? .semibold : .medium
                )
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(
                .horizontal,
                BrowseSegmentedNavigationMetrics.horizontalPadding
            )
            .frame(
                minWidth: BrowseSegmentedNavigationMetrics.minimumSegmentWidth,
                minHeight: BrowseSegmentedNavigationMetrics.controlHeight
            )
            .contentShape(Rectangle())
    }
}

struct BrowseSegmentedMoreLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("更多")
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(
            width: BrowseSegmentedNavigationMetrics.moreWidth,
            height: BrowseSegmentedNavigationMetrics.controlHeight
        )
        .contentShape(Rectangle())
    }
}

struct BrowseSegmentedNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        BrowseSegmentedNavigationButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct BrowseSegmentedNavigationButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(
                isSelected
                    ? Color.primary
                    : isHovering
                        ? Color.primary.opacity(0.78)
                        : Color.secondary
            )
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(nsColor: .windowBackgroundColor).opacity(0.72)
                            : isHovering
                                ? Color.primary.opacity(0.055)
                                : Color.clear
                    )
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .stroke(Color.primary.opacity(0.035), lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct VideoCard: View {
    let item: VideoSummary
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                VideoPosterView(item: item)
                    .overlay {
                        if isHovering {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.72), lineWidth: 1.5)
                        }
                    }

                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if let secondaryText {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isHovering
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isHovering
                            ? Color.secondary.opacity(0.18)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.018 : 1)
        .shadow(
            color: .black.opacity(isHovering ? 0.18 : 0),
            radius: isHovering ? 10 : 0,
            y: isHovering ? 5 : 0
        )
        .zIndex(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(item.title)，来源 \(item.siteName)")
    }

    private var secondaryText: String? {
        VideoCardMetadata.secondaryText(from: item.remarks)
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
        Group {
            if item.posterURL != nil {
                PosterView(url: item.posterURL)
            } else if item.isFolder {
                categoryNavigationPoster
            } else {
                PosterView(url: nil)
            }
        }
            .overlay(alignment: .topTrailing) {
                if item.isFolder, item.posterURL != nil {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.62))
                        .clipShape(Circle())
                        .padding(7)
                        .accessibilityLabel("分类导航")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating = VideoCardMetadata.ratingText(
                    from: item.remarks
                ) {
                    Text(rating)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(7)
                        .accessibilityLabel("评分 \(rating)")
                }
            }
    }

    private var categoryNavigationPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("分类导航")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("分类导航")
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
                    AppActivityIndicator(size: .small)
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
                    AppActivityIndicator(size: .regular)
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
