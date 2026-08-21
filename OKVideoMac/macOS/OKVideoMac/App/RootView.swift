import AppKit
import SwiftUI
import WebKit

enum AppSurfacePalette {
    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

/// A shared, low-presence hover treatment for the browsing interface. It does
/// not replace selected, destructive, or disabled states; it only adds the
/// small amount of motion and contrast needed to make an interactive surface
/// feel responsive on macOS.
struct AppInteractiveHoverModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let cornerRadius: CGFloat
    let selected: Bool
    let destructive: Bool

    func body(content: Content) -> some View {
        let active = isEnabled && isHovering
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        destructive
                            ? Color.red.opacity(active ? 0.10 : 0)
                            : Color.primary.opacity(active ? (selected ? 0.08 : 0.065) : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color.primary.opacity(active ? 0.075 : 0),
                        lineWidth: 1
                    )
            }
            .scaleEffect(active ? 1.018 : 1)
            .shadow(
                color: Color.black.opacity(active ? 0.10 : 0),
                radius: active ? 7 : 0,
                y: active ? 3 : 0
            )
            .animation(.easeOut(duration: 0.14), value: active)
            .onHover { isHovering = isEnabled && $0 }
    }
}

extension View {
    func appInteractiveHover(
        cornerRadius: CGFloat = 9,
        selected: Bool = false,
        destructive: Bool = false
    ) -> some View {
        modifier(
            AppInteractiveHoverModifier(
                cornerRadius: cornerRadius,
                selected: selected,
                destructive: destructive
            )
        )
    }
}

struct AppHoverTooltipModifier: ViewModifier {
    let text: String
    let delay: TimeInterval

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var hoverGeneration = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if isPresented {
                    tooltip
                        .alignmentGuide(.bottom) { dimensions in
                            dimensions[.top] - 6
                        }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .zIndex(isPresented ? 1_000 : 0)
            .onHover(perform: handleHover)
            .onDisappear {
                hoverGeneration &+= 1
                isHovering = false
                isPresented = false
            }
            .accessibilityHint(text)
    }

    private var tooltip: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Color(nsColor: .labelColor))
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .allowsHitTesting(false)
    }

    private func handleHover(_ inside: Bool) {
        hoverGeneration &+= 1
        let generation = hoverGeneration
        isHovering = inside

        guard inside else {
            isPresented = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isHovering, hoverGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                isPresented = true
            }
        }
    }
}

extension View {
    func appHoverTooltip(
        _ text: String,
        delay: TimeInterval = 0.1
    ) -> some View {
        modifier(AppHoverTooltipModifier(text: text, delay: delay))
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            AppSurfacePalette.background
                .ignoresSafeArea()

            browsingContent
        }
        .alert(item: $state.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(
            isPresented: Binding(
                get: {
                    state.selectedDetail != nil
                        || state.pendingDetailSummary != nil
                },
                set: { if !$0 { state.dismissDetail() } }
            )
        ) {
            if let detail = state.selectedDetail {
                DetailView(detail: detail)
                    .environmentObject(state)
                    .frame(minWidth: 820, minHeight: 600)
            } else if let summary = state.pendingDetailSummary {
                DetailLoadingView(summary: summary)
                    .environmentObject(state)
                    .frame(minWidth: 820, minHeight: 600)
            }
        }
        .overlay {
            if let prompt = state.cloudAuthorizationPrompt,
               state.selectedDetail == nil {
                CloudAuthorizationView(prompt: prompt)
                    .environmentObject(state)
            }
        }
        .overlay {
            if let presentation = state.nodeWebPresentation {
                NodeConfigurationView(presentation: presentation)
                    .environmentObject(state)
            }
        }
        .background {
            WindowCloseObserver {
                Task { await state.closePlayer() }
            }
        }
    }

    @ViewBuilder
    private var browsingContent: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                SectionContentView()
            }
        } else {
            NavigationView {
                SidebarView()
                SectionContentView()
            }
            .navigationViewStyle(.columns)
        }
    }
}

enum PlayerSurfaceMountPolicy {
    static func shouldMount(
        isPlayerPresented: Bool,
        hasRenderPlayer: Bool
    ) -> Bool {
        isPlayerPresented && hasRenderPlayer
    }
}

enum PlayerSurfaceBackdropPolicy {
    static func shouldShow(isPlayerPresented: Bool) -> Bool {
        isPlayerPresented
    }
}

struct NodeConfigurationView: View {
    @EnvironmentObject private var state: AppState
    let presentation: NodeWebPresentation

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.person.crop")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(.headline)
                        Text(presentation.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    Button {
                        state.refreshNodeConfigurationWebsite()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 68)

                Divider()

                NodeConfigurationWebView(
                    url: presentation.url,
                    revision: presentation.revision
                )
                .background(Color(nsColor: .textBackgroundColor))

                Divider()

                HStack(spacing: 12) {
                    Label(
                        "请用对应网盘 App 扫码，页面显示登录成功后再继续。",
                        systemImage: "qrcode.viewfinder"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Spacer()
                    Button("关闭") {
                        state.cancelNodeConfiguration()
                    }
                    Button {
                        Task { await state.completeNodeConfigurationAndRetry() }
                    } label: {
                        Label("授权完成并重试", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 18)
                .frame(height: 64)
            }
            .frame(
                minWidth: 820,
                idealWidth: 1_040,
                maxWidth: 1_160,
                minHeight: 580,
                idealHeight: 760,
                maxHeight: 840
            )
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 36, y: 14)
            .padding(26)
        }
        .zIndex(2_000)
    }
}

private struct NodeConfigurationWebView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.lastRevision = revision
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastRevision != revision else { return }
        context.coordinator.lastRevision = revision
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastRevision = -1

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if Self.isLocalNodeURL(url) {
                decisionHandler(.allow)
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }
            if Self.isLocalNodeURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private static func isLocalNodeURL(_ url: URL) -> Bool {
            ["127.0.0.1", "localhost", "::1"].contains(
                url.host?.lowercased() ?? ""
            )
        }
    }
}

private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> WindowCloseObserverView {
        let view = WindowCloseObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(
        _ nsView: WindowCloseObserverView,
        context: Context
    ) {
        nsView.onClose = onClose
    }
}

private final class WindowCloseObserverView: NSView {
    var onClose: (() -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct CloudAuthorizationView: View {
    @EnvironmentObject private var state: AppState
    let prompt: CloudAuthorizationPrompt

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(
                        prompt.interactionKind == .authorization
                            ? "网盘授权"
                            : "配置操作",
                        systemImage: prompt.interactionKind == .authorization
                            ? "externaldrive.badge.person.crop"
                            : "slider.horizontal.3"
                    )
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        Task { await state.refreshCloudAuthorization() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }

                Text(prompt.title)
                    .font(.headline)

                if prompt.credentialPush {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本机安全提交")
                                .font(.headline)
                            Text("凭据不会写入 Mac 配置，也不会通过局域网传输。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let data = prompt.snapshot,
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .padding(14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.18))
                        }
                        .frame(maxWidth: .infinity)
                } else if prompt.phase == "qr" {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            AppActivityIndicator(size: .regular)
                            Text("正在生成二维码…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 280, height: 220)
                        Spacer()
                    }
                } else if prompt.phase == "waiting"
                    || prompt.phase == "transitioning" {
                    HStack(spacing: 10) {
                        AppActivityIndicator(size: .small)
                        Text("正在等待下一步操作界面")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                } else if prompt.phase == "failed" {
                    Label(
                        "配置操作尚未完成",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                }

                if let status = prompt.status, !status.isEmpty {
                    Text(status)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                if prompt.hasTextInput {
                    SecureField(
                        inputPlaceholder,
                        text: $state.cloudAuthorizationInput
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("内容直接提交给本机 Java/Dex 插件，Mac 端不会另行保存。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if prompt.credentialPush {
                    Button {
                        Task { await state.submitCloudCredential() }
                    } label: {
                        Label("提交授权并重试播放", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        state.cloudAuthorizationInput
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 130), spacing: 8)
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(prompt.actions) { action in
                            Button(action.title) {
                                Task {
                                    await state.submitCloudAuthorization(action: action)
                                }
                            }
                            .disabled(
                                prompt.hasTextInput
                                    && action.title.uppercased() == "OK"
                                    && state.cloudAuthorizationInput
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                            )
                        }
                    }
                }

                HStack {
                    if prompt.allowsRetry {
                        Button {
                            Task { await state.retryCloudAuthorizationOperation() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("关闭") {
                        state.cancelCloudAuthorization()
                    }
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 24)
            .padding()
        }
        .zIndex(1_000)
    }

    private var inputPlaceholder: String {
        let title = prompt.title.lowercased()
        if title.contains("token") || title.contains("阿里") {
            return "粘贴阿里云盘 Token"
        }
        if title.contains("百度") {
            return "粘贴百度网盘 Cookie"
        }
        return "粘贴网盘 Cookie 或 Token"
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @Environment(\.colorScheme) private var colorScheme

    private var selectionColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.38, green: 0.40, blue: 0.72)
        }
        return Color(red: 0.29, green: 0.31, blue: 0.58)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
        }
        .frame(minWidth: 160)
        .background(AppSurfacePalette.background.ignoresSafeArea())
        .modifier(SidebarColumnWidthModifier())
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = navigation.selectedSection == section
        return Button {
            state.selectSection(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 23)
                    .foregroundColor(isSelected ? .white : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? selectionColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 8, selected: isSelected)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarColumnWidthModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 230)
        } else {
            content.frame(idealWidth: 190, maxWidth: 230)
        }
    }
}

private struct SectionContentView: View {
    @EnvironmentObject private var navigation: AppNavigationState
    @StateObject private var liveSession = LiveBrowserSession()

    var body: some View {
        Group {
            switch navigation.selectedSection {
            case .home, .live:
                HomeLiveSectionContainer(liveSession: liveSession)
            case .favorites:
                FavoritesView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurfacePalette.background.ignoresSafeArea())
    }
}

/// Home and live are the two largest browsing trees. Keeping them mounted
/// avoids tearing down dozens of live cards while simultaneously constructing
/// the poster grid. The navigation store is intentionally observed only here,
/// so changing sections does not invalidate either content subtree.
private struct HomeLiveSectionContainer: View {
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var liveSession: LiveBrowserSession

    private var showsHome: Bool {
        navigation.selectedSection == .home
    }

    var body: some View {
        ZStack {
            HomeView()
                .opacity(showsHome ? 1 : 0)
                .allowsHitTesting(showsHome)
                .accessibilityHidden(!showsHome)
                .zIndex(showsHome ? 1 : 0)

            LiveView(session: liveSession)
                .opacity(showsHome ? 0 : 1)
                .allowsHitTesting(!showsHome)
                .accessibilityHidden(showsHome)
                .zIndex(showsHome ? 0 : 1)
        }
        .navigationTitle(navigation.selectedSection.rawValue)
        .toolbar {
            ToolbarItem {
                if showsHome {
                    HomeToolbarView()
                } else {
                    LiveToolbarView(session: liveSession)
                }
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}
