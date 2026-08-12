import AppKit
import Combine
import SwiftUI

@main
struct OKVideoMacApp: App {
    @NSApplicationDelegateAdaptor(OKVideoMacAppDelegate.self)
    private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = AppState.bootstrap()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.navigation)
                .environment(\.imageRepository, state.imageRepository)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.install(appState: state)
                    AppAppearanceController.apply(state.appTheme)
                }
                .onChange(of: state.appTheme) { theme in
                    AppAppearanceController.apply(theme)
                }
                .task {
                    await state.start()
                }
                .onOpenURL { url in
                    Task {
                        _ = await state.importConfiguration(
                            source: .localFile(url),
                            name: url.deletingPathExtension().lastPathComponent
                        )
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await state.refreshHomeConfigurationIfNeeded() }
                    } else {
                        Task { await state.persistPlaybackProgress() }
                    }
                }
                .onReceive(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.willSleepNotification
                    )
                ) { _ in
                    Task { await state.handleSystemSleep() }
                }
                .onReceive(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.didWakeNotification
                    )
                ) { _ in
                    Task { await state.handleSystemWake() }
                }
        }
        .commands {
            AppCommands(state: state)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.navigation)
                .frame(width: 980, height: 650)
        }
    }
}

@MainActor
final class OKVideoMacAppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationState {
        case idle
        case waiting
        case completed
    }

    private let mainMenuLocalizer = MainMenuChineseLocalizer()
    private weak var appState: AppState?
    private var playerWindowController: PlayerPlaybackWindowController?
    private var playerPresentationCancellable: AnyCancellable?
    private var terminationState = TerminationState.idle
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?

    func install(appState: AppState) {
        guard self.appState !== appState
                || playerPresentationCancellable == nil else { return }
        self.appState = appState
        let playerWindowController = PlayerPlaybackWindowController(
            appState: appState
        )
        self.playerWindowController = playerWindowController
        playerPresentationCancellable = appState.$isPlayerPresented
            .removeDuplicates()
            .sink { [weak playerWindowController, weak appState] isPresented in
                if isPresented {
                    // Do not build the AppKit/OpenGL hierarchy inline with
                    // the click transaction. Playback can create libmpv and
                    // issue loadfile immediately; the window mounts on the
                    // next main-loop turn and attaches its render context in
                    // parallel with network and demux startup.
                    DispatchQueue.main.async {
                        guard appState?.isPlayerPresented == true else { return }
                        playerWindowController?.present()
                    }
                } else {
                    playerWindowController?.dismiss()
                }
            }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenuLocalizer.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainMenuLocalizer.localizeMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        switch terminationState {
        case .completed:
            return .terminateNow
        case .waiting:
            return .terminateLater
        case .idle:
            guard let appState else { return .terminateNow }
            terminationState = .waiting
            terminationTask = Task { @MainActor [weak self, weak appState] in
                await appState?.shutdown()
                guard !Task.isCancelled else { return }
                self?.finishTerminationAfterShutdown()
            }
            terminationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishTerminationAfterTimeout()
            }
            return .terminateLater
        }
    }

    private func finishTerminationAfterShutdown() {
        guard terminationState == .waiting else { return }
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        replyToTerminationRequest()
    }

    private func finishTerminationAfterTimeout() {
        guard terminationState == .waiting else { return }
        terminationTask?.cancel()
        terminationTask = nil
        replyToTerminationRequest()
    }

    private func replyToTerminationRequest() {
        guard terminationState == .waiting else { return }
        terminationState = .completed
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// Owns playback as a separate AppKit window. The browsing WindowGroup never
/// hosts an mpv surface and is therefore unaffected by video aspect-ratio,
/// full-screen, resize, or render-context lifecycle changes.
@MainActor
final class PlayerPlaybackWindowController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "OKVideoMac.PlayerWindow.v2"
    private weak var appState: AppState?
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var isDismissingFromState = false

    init(appState: AppState) {
        self.appState = appState
    }

    func present() {
        guard let appState else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentSize = initialContentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = NSSize(width: 800, height: 450)
        window.contentAspectRatio = NSSize(width: 16, height: 9)

        let rootView = AnyView(
            PlayerPlaybackWindowRoot(appState: appState)
                .environmentObject(appState)
        )
        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController
        self.hostingController = hostingController
        self.window = window

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let window else { return }
        isDismissingFromState = true
        window.close()
        clearWindowReferences()
        isDismissingFromState = false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        let shouldClosePlayback = !isDismissingFromState
            && appState?.isPlayerPresented == true
        clearWindowReferences()
        if shouldClosePlayback {
            Task { @MainActor [weak appState] in
                await appState?.closePlayer()
            }
        }
    }

    private func clearWindowReferences() {
        window?.delegate = nil
        window = nil
        hostingController = nil
    }

    private func initialContentSize() -> NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return PlayerWindowSizingPolicy.initialContentSize(
            visibleFrame: visibleFrame
        )
    }
}

enum PlayerWindowSizingPolicy {
    static let aspectRatio: CGFloat = 16 / 9

    static func initialContentSize(visibleFrame: NSRect) -> NSSize {
        let maximumWidth = max(800, visibleFrame.width * 0.82)
        let maximumHeight = max(450, visibleFrame.height * 0.86)
        let width = min(maximumWidth, maximumHeight * aspectRatio)
        return NSSize(width: width, height: width / aspectRatio)
    }
}

private struct PlayerPlaybackWindowRoot: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: appState.isPlayerPresented,
                hasRenderPlayer: appState.embeddedPlayer != nil
            ), let player = appState.embeddedPlayer {
                MPVRenderView(player: player) { error in
                    appState.reportPlayerRenderError(error)
                }
                .id(player.renderOwnerID)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            PlayerView(onWindowChromeRestored: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 450)
        .background(Color.black)
    }
}

enum MainMenuChineseLocalization {
    private static let exactTitles: [String: String] = [
        "File": "文件",
        "Edit": "编辑",
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助",
        "Settings…": "设置…",
        "Services": "服务",
        "Hide Others": "隐藏其他应用",
        "Show All": "全部显示",
        "Quit and Keep Windows": "退出并保留窗口",
        "New Window": "新建窗口",
        "Open…": "打开…",
        "Open Recent": "最近打开",
        "Close": "关闭窗口",
        "Close All": "全部关闭",
        "Save": "保存",
        "Save As…": "另存为…",
        "Revert To": "复原到",
        "Page Setup…": "页面设置…",
        "Print…": "打印…",
        "Undo": "撤销",
        "Redo": "重做",
        "Cut": "剪切",
        "Copy": "复制",
        "Paste": "粘贴",
        "Paste and Match Style": "粘贴并匹配样式",
        "Delete": "删除",
        "Select All": "全选",
        "Find": "查找",
        "Find…": "查找…",
        "Find Next": "查找下一个",
        "Find Previous": "查找上一个",
        "Use Selection for Find": "使用所选内容查找",
        "Jump to Selection": "跳到所选内容",
        "Spelling and Grammar": "拼写与语法",
        "Show Spelling and Grammar": "显示拼写与语法",
        "Check Document Now": "立即检查文稿",
        "Check Spelling While Typing": "键入时检查拼写",
        "Check Grammar With Spelling": "检查拼写时检查语法",
        "Correct Spelling Automatically": "自动纠正拼写",
        "Substitutions": "替换",
        "Show Substitutions": "显示替换",
        "Smart Copy/Paste": "智能拷贝/粘贴",
        "Smart Quotes": "智能引号",
        "Smart Dashes": "智能破折号",
        "Smart Links": "智能链接",
        "Data Detectors": "数据检测器",
        "Text Replacement": "文本替换",
        "Transformations": "转换",
        "Make Upper Case": "转换为大写",
        "Make Lower Case": "转换为小写",
        "Capitalize": "首字母大写",
        "Speech": "语音",
        "Start Speaking": "开始朗读",
        "Stop Speaking": "停止朗读",
        "AutoFill": "自动填充",
        "Start Dictation": "开始听写",
        "Start Dictation…": "开始听写…",
        "Emoji & Symbols": "表情与符号",
        "Show Tab Bar": "显示标签页栏",
        "Hide Tab Bar": "隐藏标签页栏",
        "Show All Tabs": "显示所有标签页",
        "Show Toolbar": "显示工具栏",
        "Hide Toolbar": "隐藏工具栏",
        "Customize Toolbar…": "自定义工具栏…",
        "Show Sidebar": "显示边栏",
        "Hide Sidebar": "隐藏边栏",
        "Enter Full Screen": "进入全屏幕",
        "Exit Full Screen": "退出全屏幕",
        "Minimize": "最小化",
        "Minimize All": "全部最小化",
        "Zoom": "缩放",
        "Zoom All": "全部缩放",
        "Fill": "填充",
        "Center": "居中",
        "Move Window to Left Side of Screen": "将窗口移到屏幕左侧",
        "Move Window to Right Side of Screen": "将窗口移到屏幕右侧",
        "Tile Window to Left of Screen": "将窗口平铺到屏幕左侧",
        "Tile Window to Right of Screen": "将窗口平铺到屏幕右侧",
        "Replace Tiled Window": "替换平铺窗口",
        "Remove Window from Set": "从窗口组中移除",
        "Show Previous Tab": "显示上一个标签页",
        "Show Next Tab": "显示下一个标签页",
        "Move Tab to New Window": "将标签页移到新窗口",
        "Merge All Windows": "合并所有窗口",
        "Bring All to Front": "前置全部窗口",
        "Arrange in Front": "前置排列"
    ]

    static func title(for original: String) -> String {
        if let exact = exactTitles[original] {
            return exact
        }
        if original.hasPrefix("About ") {
            return "关于 " + String(original.dropFirst("About ".count))
        }
        if original.hasPrefix("Hide ") {
            return "隐藏 " + String(original.dropFirst("Hide ".count))
        }
        if original.hasPrefix("Quit ") {
            return "退出 " + String(original.dropFirst("Quit ".count))
        }
        if original.hasPrefix("Undo ") {
            return "撤销 " + String(original.dropFirst("Undo ".count))
        }
        if original.hasPrefix("Redo ") {
            return "重做 " + String(original.dropFirst("Redo ".count))
        }
        if original.hasSuffix(" Help") {
            return String(original.dropLast(" Help".count)) + " 帮助"
        }
        return original
    }
}

@MainActor
final class MainMenuChineseLocalizer {
    private var observers: [NSObjectProtocol] = []
    private var pendingMenus: [ObjectIdentifier: NSMenu] = [:]
    private var localizationScheduled = false

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let notifications: [Notification.Name] = [
            NSMenu.didBeginTrackingNotification,
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification
        ]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated {
                    self?.scheduleLocalization(of: menu)
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.localizeMainMenu()
        }
    }

    func localizeMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        localize(mainMenu)
    }

    private func localize(_ menu: NSMenu) {
        for item in menu.items {
            let translatedTitle = MainMenuChineseLocalization.title(
                for: item.title
            )
            if translatedTitle != item.title {
                item.title = translatedTitle
            }
            if let submenu = item.submenu {
                let translatedMenuTitle = MainMenuChineseLocalization.title(
                    for: submenu.title
                )
                if translatedMenuTitle != submenu.title {
                    submenu.title = translatedMenuTitle
                }
                localize(submenu)
            }
        }
    }

    private func scheduleLocalization(of menu: NSMenu) {
        pendingMenus[ObjectIdentifier(menu)] = menu
        guard !localizationScheduled else { return }
        localizationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let menus = Array(self.pendingMenus.values)
            self.pendingMenus.removeAll()
            self.localizationScheduled = false
            for menu in menus {
                self.localize(menu)
            }
        }
    }
}

enum AppAppearanceController {
    static func appearanceName(for theme: AppTheme) -> NSAppearance.Name? {
        switch theme {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    @MainActor
    static func apply(_ theme: AppTheme) {
        NSApplication.shared.appearance = appearanceName(for: theme).flatMap {
            NSAppearance(named: $0)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandMenu("导航") {
            Button("搜索") {
                state.presentHomeSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("打开点播配置") {
                state.selectedSettingsPane = .configurations
                state.selectedSection = .settings
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

            Button("刷新当前站点") {
                Task { await state.refreshHome() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("播放") {
            Button("播放/暂停") {
                Task { await state.togglePlayPause() }
            }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!state.isPlayerPresented)
            Button("快退 10 秒") {
                Task { await state.seek(by: -10) }
            }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!state.isPlayerPresented)
            Button("快进 10 秒") {
                Task { await state.seek(by: 10) }
            }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!state.isPlayerPresented)
            Divider()
            Button("上一个直播频道") {
                Task { await state.switchLiveChannel(by: -1) }
            }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!state.canSwitchLiveChannel)
            Button("下一个直播频道") {
                Task { await state.switchLiveChannel(by: 1) }
            }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!state.canSwitchLiveChannel)
            Divider()
            Button("进入/退出全屏") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!state.isPlayerPresented)
        }
    }
}
