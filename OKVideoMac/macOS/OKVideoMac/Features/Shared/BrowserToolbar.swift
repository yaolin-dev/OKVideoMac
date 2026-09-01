import AppKit
import SwiftUI

enum BrowserToolbarChromeFill: Equatable {
    case referenceTone
}

struct BrowserToolbarChromeAppearance: Equatable {
    let fill: BrowserToolbarChromeFill
    let separatorOpacity: Double
}

enum BrowserToolbarChromePolicy {
    static func appearance(
        isScrolled: Bool,
        isWindowActive: Bool,
        reduceTransparency: Bool
    ) -> BrowserToolbarChromeAppearance {
        BrowserToolbarChromeAppearance(
            fill: .referenceTone,
            separatorOpacity: isScrolled
                ? (isWindowActive ? 0.30 : 0.20)
                : (isWindowActive ? 0.10 : 0.06)
        )
    }
}

enum PrimaryToolbarLayout: Equatable, Sendable {
    case expanded
    case compact
    case minimal

    var sitePickerWidth: CGFloat {
        switch self {
        case .expanded: return 210
        case .compact: return 150
        case .minimal: return 0
        }
    }

    var configurationPickerWidth: CGFloat {
        switch self {
        case .expanded: return 118
        case .compact: return 96
        case .minimal: return 0
        }
    }
}

enum PrimaryToolbarLayoutPolicy {
    static func layout(contentWidth: CGFloat) -> PrimaryToolbarLayout {
        if contentWidth >= 900 { return .expanded }
        if contentWidth >= 650 { return .compact }
        return .minimal
    }
}

private struct PrimaryToolbarLayoutKey: EnvironmentKey {
    static let defaultValue = PrimaryToolbarLayout.expanded
}

private struct BrowserToolbarScrollReporterKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var primaryToolbarLayout: PrimaryToolbarLayout {
        get { self[PrimaryToolbarLayoutKey.self] }
        set { self[PrimaryToolbarLayoutKey.self] = newValue }
    }

    var browserToolbarScrollReporter: (Bool) -> Void {
        get { self[BrowserToolbarScrollReporterKey.self] }
        set { self[BrowserToolbarScrollReporterKey.self] = newValue }
    }
}

private struct BrowserToolbarScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Place this as the first child of a browser ScrollView. The marker and the
/// scroll-surface modifier below let the shared parent own toolbar chrome,
/// without coupling an individual page to the window toolbar implementation.
struct BrowserToolbarScrollMarker: View {
    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BrowserToolbarScrollOffsetPreferenceKey.self,
                value: proxy.frame(in: .named(coordinateSpaceName)).minY
            )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

private struct BrowserToolbarScrollSurfaceModifier: ViewModifier {
    @Environment(\.browserToolbarScrollReporter) private var reportScroll
    @State private var lastReportedScrollState = false

    let coordinateSpaceName: String

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: coordinateSpaceName)
            .onAppear {
                reportScrollStateIfChanged(false)
            }
            .onPreferenceChange(BrowserToolbarScrollOffsetPreferenceKey.self) {
                reportScrollStateIfChanged($0 < -0.5)
            }
            .onDisappear {
                if lastReportedScrollState {
                    lastReportedScrollState = false
                    reportScroll(false)
                }
            }
    }

    private func reportScrollStateIfChanged(_ isScrolled: Bool) {
        guard isScrolled != lastReportedScrollState else { return }
        // Preference delivery can happen inside SwiftUI's layout update.
        // Defer the state mutation so it cannot recursively invalidate the
        // AppKit hosting view's constraints in the same display cycle.
        DispatchQueue.main.async {
            guard isScrolled != lastReportedScrollState else { return }
            lastReportedScrollState = isScrolled
            reportScroll(isScrolled)
        }
    }
}

/// `List` owns an AppKit NSScrollView and cannot host the geometry marker used
/// by a normal SwiftUI ScrollView without changing row layout. This bridge
/// observes only the native clip-view bounds and preserves List behavior.
private struct BrowserListToolbarScrollObserver: NSViewRepresentable {
    let reportScroll: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(reportScroll: reportScroll)
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onHierarchyChange = { [weak coordinator = context.coordinator,
                                    weak view] in
            guard let coordinator, let view else { return }
            coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.reportScroll = reportScroll
        context.coordinator.attach(from: nsView)
    }

    static func dismantleNSView(
        _ nsView: AttachmentView,
        coordinator: Coordinator
    ) {
        coordinator.detach(reportsTop: true)
        nsView.onHierarchyChange = nil
    }

    final class AttachmentView: NSView {
        var onHierarchyChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.onHierarchyChange?()
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                self?.onHierarchyChange?()
            }
        }
    }

    @MainActor
    final class Coordinator {
        var reportScroll: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lastReportedState = false

        init(reportScroll: @escaping (Bool) -> Void) {
            self.reportScroll = reportScroll
        }

        func attach(from view: NSView) {
            guard let enclosingScrollView = view.enclosingScrollView else {
                return
            }
            guard scrollView !== enclosingScrollView else {
                reportCurrentState()
                return
            }
            detach(reportsTop: false)
            scrollView = enclosingScrollView
            enclosingScrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: enclosingScrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportCurrentState()
                }
            }
            reportCurrentState()
        }

        func detach(reportsTop: Bool) {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            scrollView = nil
            if reportsTop, lastReportedState {
                lastReportedState = false
                reportScroll(false)
            }
        }

        private func reportCurrentState() {
            guard let scrollView else { return }
            let isScrolled = (scrollView.verticalScroller?.floatValue ?? 0) > 0.001
            guard isScrolled != lastReportedState else { return }
            lastReportedState = isScrolled
            reportScroll(isScrolled)
        }
    }
}

private struct BrowserListToolbarScrollSurfaceModifier: ViewModifier {
    @Environment(\.browserToolbarScrollReporter) private var reportScroll

    func body(content: Content) -> some View {
        content
            .background {
                BrowserListToolbarScrollObserver(reportScroll: reportScroll)
                    .frame(width: 0, height: 0)
            }
            .onAppear { reportScroll(false) }
            .onDisappear { reportScroll(false) }
    }
}

extension View {
    func browserToolbarScrollSurface(named coordinateSpaceName: String) -> some View {
        modifier(
            BrowserToolbarScrollSurfaceModifier(
                coordinateSpaceName: coordinateSpaceName
            )
        )
    }

    func browserListToolbarScrollSurface() -> some View {
        modifier(BrowserListToolbarScrollSurfaceModifier())
    }
}

struct BrowserToolbarChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let isScrolled: Bool
    let isWindowActive: Bool

    private var appearance: BrowserToolbarChromeAppearance {
        BrowserToolbarChromePolicy.appearance(
            isScrolled: isScrolled,
            isWindowActive: isWindowActive,
            reduceTransparency: reduceTransparency
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            chrome(content)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            chrome(content)
        }
    }

    private func chrome<ChromeContent: View>(_ content: ChromeContent) -> some View {
        content.overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .opacity(appearance.separatorOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct PrimaryPageToolbarLeadingContent: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BrowserToolbarTitle(title)
        }
        ToolbarItem(placement: .principal) {
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }
}

struct BrowserToolbarTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 19, weight: .semibold))
            .frame(height: 40)
            .offset(x: 10)
            .accessibilityAddTraits(.isHeader)
    }
}
