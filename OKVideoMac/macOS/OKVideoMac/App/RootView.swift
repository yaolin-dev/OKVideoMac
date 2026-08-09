import AppKit
import SwiftUI
import WebKit

enum AppSurfacePalette {
    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var sidebarLayoutRevision = 0

    var body: some View {
        ZStack {
            AppSurfacePalette.background
                .ignoresSafeArea()

            browsingContent
                .opacity(state.isPlayerPresented ? 0 : 1)
                .allowsHitTesting(!state.isPlayerPresented)
                .accessibilityHidden(state.isPlayerPresented)

            if state.isPlayerPresented {
                PlayerView {
                    sidebarLayoutRevision &+= 1
                }
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(10)
            }
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
                    .frame(minWidth: 720, minHeight: 520)
            } else if let summary = state.pendingDetailSummary {
                DetailLoadingView(summary: summary)
                    .environmentObject(state)
                    .frame(minWidth: 720, minHeight: 520)
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
        .animation(.easeInOut(duration: 0.15), value: state.isPlayerPresented)
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
                    .id(sidebarLayoutRevision)
            } detail: {
                SectionContentView()
            }
        } else {
            NavigationView {
                SidebarView()
                    .id(sidebarLayoutRevision)
                SectionContentView()
            }
            .navigationViewStyle(.columns)
        }
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
                    Label("网盘授权", systemImage: "externaldrive.badge.person.crop")
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
                            ProgressView()
                            Text("正在生成二维码…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 280, height: 220)
                        Spacer()
                    }
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

    private let selectionColor = Color(
        red: 0.34,
        green: 0.35,
        blue: 0.56
    )

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
        let isSelected = state.selectedSection == section
        return Button {
            state.selectSection(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 23)
                    .foregroundColor(isSelected ? .white : selectionColor)
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
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.selectedSection {
            case .home:
                HomeView()
            case .live:
                LiveView()
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
