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

/// One visual rhythm for every primary page in the right-hand browser column.
/// Page-specific actions keep their behavior, while their title, sizing,
/// spacing and hover treatment remain consistent across Home, Live, Favorites,
/// History, Settings and Search.
enum PrimaryToolbarMetrics {
    // NetEase Filmly uses a compact native-titlebar label rather than a page
    // heading. Keep this at the same 15 pt visual scale on every main page.
    static let titleFontSize: CGFloat = 15
    static let itemHeight: CGFloat = 40
    static let controlHeight: CGFloat = 32
    static let iconControlSize: CGFloat = 32
    static let iconFontSize: CGFloat = 15
    static let itemSpacing: CGFloat = 8
    static let dividerHeight: CGFloat = 20
    static let titleLeadingOffset: CGFloat = 0
}

/// Navigation must remain clickable across the entire control, including when
/// the browser is inactive. A native control also keeps titlebar dragging from
/// consuming clicks in the transparent area around the chevron.
struct BrowserToolbarBackButton: NSViewRepresentable {
    let help: String
    let identifier: String
    let action: () -> Void

    func makeNSView(context: Context) -> BrowserToolbarBackNSButton {
        let button = BrowserToolbarBackNSButton()
        update(button)
        return button
    }

    func updateNSView(_ button: BrowserToolbarBackNSButton, context: Context) {
        update(button)
    }

    private func update(_ button: BrowserToolbarBackNSButton) {
        button.configure(help: help, identifier: identifier, action: action)
    }
}

final class BrowserToolbarBackNSButton: NSButton {
    private var onBack: () -> Void = {}

    init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(
            width: PrimaryToolbarMetrics.iconControlSize,
            height: PrimaryToolbarMetrics.iconControlSize
        )))
        title = ""
        setButtonType(.momentaryPushIn)
        bezelStyle = .texturedRounded
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(
            systemSymbolName: "chevron.backward",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: PrimaryToolbarMetrics.iconFontSize,
            weight: .medium
        ))
        target = self
        action = #selector(goBack)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: PrimaryToolbarMetrics.iconControlSize,
            height: PrimaryToolbarMetrics.iconControlSize
        )
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(help: String, identifier: String, action: @escaping () -> Void) {
        toolTip = help
        setAccessibilityLabel(help)
        setAccessibilityIdentifier(identifier)
        // SwiftUI can reuse the native view when the route changes. Always
        // replace its action rather than retaining a previous route closure.
        onBack = action
    }

    @objc private func goBack() { onBack() }
}

/// A stable native hit target, including the transparent padding around the
/// symbol. Mode changes happen in the action, independently of data loading.
struct BrowserToolbarModeButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let selected: Bool
    let help: String
    let action: () -> Void

    func makeNSView(context: Context) -> BrowserToolbarModeNSButton {
        let button = BrowserToolbarModeNSButton()
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ view: BrowserToolbarModeNSButton, context: Context) {
        view.configure(selected: selected, enabled: isEnabled, help: help, action: action)
    }
}

final class BrowserToolbarModeNSButton: NSButton {
    private var onActivate: () -> Void = {}
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        title = ""
        setButtonType(.momentaryPushIn)
        bezelStyle = .texturedRounded
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: PrimaryToolbarMetrics.iconFontSize, weight: .medium))
        target = self
        action = #selector(activateMode)
        setAccessibilityIdentifier("live.guide.mode")
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: PrimaryToolbarMetrics.iconControlSize, height: PrimaryToolbarMetrics.iconControlSize)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(selected: Bool, enabled: Bool, help: String, action: @escaping () -> Void) {
        isEnabled = enabled
        state = selected ? .on : .off
        contentTintColor = selected ? .systemBlue : .secondaryLabelColor
        toolTip = help
        setAccessibilityLabel(help)
        setAccessibilityValue(selected ? 1 : 0)
        onActivate = action
    }
    @objc private func activateMode() {
        BrowserInteractionTrace.record("guide.modeAction")
        onActivate()
    }
}

enum PrimaryToolbarLayout: Equatable, Sendable {
    case expanded
    case compact
    case minimal

    var sitePickerWidth: CGFloat {
        switch self {
        case .expanded: return 190
        case .compact: return 140
        case .minimal: return 0
        }
    }

    var configurationPickerWidth: CGFloat {
        switch self {
        case .expanded: return 104
        case .compact: return 88
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

/// Place this as the first child of a browser ScrollView. The marker and the
/// scroll-surface modifier below let the shared parent own toolbar chrome,
/// without coupling an individual page to the window toolbar implementation.
struct BrowserToolbarScrollMarker: View {
    @Environment(\.browserToolbarScrollReporter) private var reportScroll
    @State private var lastReportedScrollState = false
    let coordinateSpaceName: String

    var body: some View {
        PosterScrollObserver { metrics in
            let isScrolled = metrics.offset > 0.5
            guard isScrolled != lastReportedScrollState else { return }
            lastReportedScrollState = isScrolled
            reportScroll(isScrolled)
        }
        .frame(height: 0)
        .accessibilityHidden(true)
        .onDisappear {
            if lastReportedScrollState {
                lastReportedScrollState = false
                reportScroll(false)
            }
        }
    }
}

private struct BrowserToolbarScrollSurfaceModifier: ViewModifier {
    let coordinateSpaceName: String

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: coordinateSpaceName)
    }
}

/// `List` owns an AppKit NSScrollView and cannot host the zero-height marker
/// used by a normal SwiftUI ScrollView without changing row layout. This bridge
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

/// Keep the background preference on the stable detail host, outside route
/// conditionals. Every page, including native Favorites and History, shares it.
struct BrowserToolbarBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 13.0, *) {
                content.toolbarBackground(.visible, for: .windowToolbar)
            } else {
                content
            }
        }
        .overlay {
            BrowserTitlebarMaterial()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BrowserTitlebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> BrowserTitlebarMaterialView {
        BrowserTitlebarMaterialView()
    }
    func updateNSView(_ view: BrowserTitlebarMaterialView, context: Context) {
        view.needsLayout = true
    }
}

/// Owns only the right pane's titlebar background. The page can scroll beneath
/// it without leaking through AppKit's native split-section separator slot.
final class BrowserTitlebarMaterialView: NSView {
    let materialView = NSVisualEffectView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        materialView.material = .titlebar
        materialView.blendingMode = .behindWindow
        materialView.state = .followsWindowActiveState
        addSubview(materialView)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let window else { materialView.frame = .zero; return }
        let contentTop = convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y
        let bottom = min(bounds.maxY, max(bounds.minY, contentTop))
        materialView.frame = NSRect(x: bounds.minX, y: bottom, width: bounds.width,
                                    height: bounds.maxY - bottom)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct BrowserToolbarChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let isScrolled: Bool
    let isWindowActive: Bool
    var usesSystemChrome = false

    private var appearance: BrowserToolbarChromeAppearance {
        BrowserToolbarChromePolicy.appearance(
            isScrolled: isScrolled,
            isWindowActive: isWindowActive,
            reduceTransparency: reduceTransparency
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesSystemChrome {
            content
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
            .font(
                .system(
                    size: PrimaryToolbarMetrics.titleFontSize,
                    weight: .semibold
                )
            )
            .foregroundColor(Color(nsColor: .labelColor))
            .frame(height: PrimaryToolbarMetrics.itemHeight)
            .offset(x: PrimaryToolbarMetrics.titleLeadingOffset)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PrimaryToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.42))
            .frame(width: 1, height: PrimaryToolbarMetrics.dividerHeight)
            .accessibilityHidden(true)
    }
}

private struct PrimaryToolbarIconControlModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let isSelected: Bool
    let selectedColor: Color
    let destructive: Bool

    private var foregroundColor: Color {
        if destructive && isHovering && isEnabled {
            return .red
        }
        if isSelected {
            return selectedColor
        }
        return .secondary
    }

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .controlSize(.regular)
            .font(
                .system(
                    size: PrimaryToolbarMetrics.iconFontSize,
                    weight: .medium
                )
            )
            .foregroundColor(foregroundColor)
            .frame(
                width: PrimaryToolbarMetrics.iconControlSize,
                height: PrimaryToolbarMetrics.iconControlSize
            )
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        destructive
                            ? Color.red.opacity(isHovering && isEnabled ? 0.09 : 0)
                            : Color.primary.opacity(isHovering && isEnabled ? 0.055 : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0),
                        lineWidth: 0.5
                    )
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.46)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct PrimaryToolbarMenuControlModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.regular)
            .font(
                .system(
                    size: PrimaryToolbarMetrics.iconFontSize,
                    weight: .medium
                )
            )
            .foregroundColor(.secondary)
            .frame(
                width: PrimaryToolbarMetrics.iconControlSize,
                height: PrimaryToolbarMetrics.iconControlSize
            )
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        Color.primary.opacity(
                            isHovering && isEnabled ? 0.055 : 0
                        )
                    )
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.46)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct PrimaryToolbarTextControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .frame(minHeight: PrimaryToolbarMetrics.controlHeight)
    }
}

extension View {
    func primaryToolbarIconControl(
        isSelected: Bool = false,
        selectedColor: Color = .accentColor,
        destructive: Bool = false
    ) -> some View {
        modifier(
            PrimaryToolbarIconControlModifier(
                isSelected: isSelected,
                selectedColor: selectedColor,
                destructive: destructive
            )
        )
    }

    func primaryToolbarMenuControl() -> some View {
        modifier(PrimaryToolbarMenuControlModifier())
    }

    func primaryToolbarTextControl() -> some View {
        modifier(PrimaryToolbarTextControlModifier())
    }
}


struct BrowserRefreshToolbarControl: View {
    let isLoading: Bool
    var error: String? = nil
    var status: String? = nil
    var title: String = L10n.string("common.refresh", fallback: "Refresh")
    var cancel: (() -> Void)? = nil
    var restart: (() -> Void)? = nil
    let action: () -> Void
    @State private var showsError = false

    var body: some View {
        HStack(spacing: 4) {
            DetailRefreshButton(isLoading: isLoading, title: title, action: action)
                .frame(width: PrimaryToolbarMetrics.iconControlSize, height: PrimaryToolbarMetrics.iconControlSize)
            if let cancel {
                Button(action: cancel) { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help(L10n.string("search.stop", fallback: "Stop Search"))
                    .opacity(isLoading ? 1 : 0)
                    .allowsHitTesting(isLoading)
                    .accessibilityHidden(!isLoading)
                    .frame(width: 20)
            }
        }
        .help(error.map { title + " — " + $0 } ?? title)
        .contextMenu {
            Button(title, action: action).disabled(isLoading)
            if let restart {
                Button(L10n.string("browser.refresh.again", fallback: "Refresh All in This Scope"), action: restart)
                    .disabled(isLoading)
            }
            if error != nil || status != nil {
                Button(L10n.string("settings.common.details", fallback: "Details")) { showsError = true }
            }
        }
        .popover(isPresented: $showsError) {
            Text([status, error].compactMap { $0 }.joined(separator: "\n\n")).textSelection(.enabled).padding().frame(width: 360)
        }
    }
}
