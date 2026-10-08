import AppKit
import Combine
import SwiftUI

@main
struct OKVideoMacApp: App {
    @NSApplicationDelegateAdaptor(OKVideoMacAppDelegate.self)
    private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state: AppState
    private let localizer: AppLocalizer

    init() {
        // Resolve the process language and its explicit resource bundle before
        // AppState formats any user-facing presentation state.
        let localizer = AppLocalizer.shared
        self.localizer = localizer
        _state = StateObject(wrappedValue: AppState.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.navigation)
                .environment(\.imageRepository, state.imageRepository)
                .environment(\.locale, localizer.locale)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.install(appState: state)
                    AppUpdateCoordinator.shared.install(appState: state)
                    AppAppearanceController.apply(state.appTheme)
                }
                .onChange(of: state.appTheme) { theme in
                    AppAppearanceController.apply(theme)
                }
                .task {
                    await state.start()
                    await SeekAcceptanceHarness.runIfRequested(state)
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
                        state.refreshEPGAfterActivation()
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
            SettingsView(navigation: state.settingsNavigation)
                .environmentObject(state)
                .environmentObject(state.navigation)
                .environment(\.locale, localizer.locale)
                .frame(width: 980, height: 650)
        }
    }
}

@MainActor
final class OKVideoMacAppDelegate: NSObject, NSApplicationDelegate {
    static let terminationFallbackTimeout: TimeInterval = 10

    private enum TerminationState {
        case idle
        case waiting
        case completed
    }

    private let mainMenuLocalizer = MainMenuLocalizationController()
    private weak var appState: AppState?
    private var playerWindowController: PlayerPlaybackWindowController?
    private var playerPresentationCancellable: AnyCancellable?
    private var playerWindowCommandCancellable: AnyCancellable?
    private var appWindowLayoutCommandCancellable: AnyCancellable?
    private let mainWindowResetKey = UUID()
    private var terminationState = TerminationState.idle
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var updateShutdownWindow: NSWindow?
    private var allowsTerminationTimeoutFallback = true

    func install(appState: AppState) {
        guard self.appState !== appState
                || playerPresentationCancellable == nil
                || playerWindowCommandCancellable == nil
                || appWindowLayoutCommandCancellable == nil else { return }
        self.appState = appState
        let playerWindowController = PlayerPlaybackWindowController(
            appState: appState
        )
        self.playerWindowController = playerWindowController
        playerPresentationCancellable = appState.$isPlayerPresented
            .removeDuplicates()
            .sink { [weak playerWindowController] isPresented in
                if !isPresented {
                    playerWindowController?.dismiss()
                }
            }
        playerWindowCommandCancellable = appState.$playerWindowCommand
            .compactMap { $0 }
            .sink { [weak playerWindowController] command in
                playerWindowController?.execute(command)
            }
        appWindowLayoutCommandCancellable = appState.$appWindowLayoutCommand
            .compactMap { $0 }
            .sink { [weak self] command in
                self?.executeWindowLayoutCommand(command)
            }
        // Prebuild only the lightweight AppKit window shell. Mounting the
        // SwiftUI player tree here would make its loading animations keep the
        // whole application committing frames while the window is hidden.
        DispatchQueue.main.async { [weak playerWindowController] in
            playerWindowController?.prewarm()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenuLocalizer.start()
#if OKVIDEO_PERFORMANCE_TEST
        Task { await AndroidDexBridgeRuntime.runStartupAcceptanceIfRequested() }
#endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainMenuLocalizer.localizeMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    private func executeWindowLayoutCommand(
        _ command: AppWindowLayoutCommand
    ) {
        switch command.target {
        case .mainWindow:
            resetMainWindowLayout()
        case .playerWindow:
            playerWindowController?.resetLayout()
        }
    }

    private func resetMainWindowLayout() {
        guard let window = AppWindowLayoutPolicy.window(for: .mainWindow) else {
            AppWindowLayoutPolicy.clearSavedFrame(for: .mainWindow)
            return
        }
        WindowTransitionCoordinator.state(for: window).whenStable(
            key: mainWindowResetKey, windowedOnly: true
        ) { stableWindow in
            guard let stableWindow else { return }
            AppWindowLayoutPolicy.restoreDefaultLayout(stableWindow, target: .mainWindow)
        }
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
            let updates = AppUpdateCoordinator.shared
            guard updates.terminationPolicy.permitsTermination else {
                updates.focusInstallationChoice()
                return .terminateCancel
            }
            allowsTerminationTimeoutFallback = updates.terminationPolicy.permitsTimeoutFallback
            guard let appState else { return .terminateNow }
            terminationState = .waiting
            orderOutVisibleWindowsForTermination(sender)
            terminationTask = Task { @MainActor [weak self, weak appState] in
                await appState?.shutdown()
                guard !Task.isCancelled else { return }
                self?.finishTerminationAfterShutdown()
            }
            terminationTimeoutTask = Task { @MainActor [weak self] in
                // The window has already disappeared. Keep a final bound for
                // the background player/history/Node/Android cleanup so a
                // broken child process can never pin application termination.
                try? await Task.sleep(nanoseconds: UInt64(
                    Self.terminationFallbackTimeout * 1_000_000_000
                ))
                guard !Task.isCancelled else { return }
                self?.finishTerminationAfterTimeout()
            }
            return .terminateLater
        }
    }

    private func orderOutVisibleWindowsForTermination(
        _ application: NSApplication
    ) {
        // Do not call `hide(_:)`: that changes scene phase and starts another
        // playback-persistence task while shutdown is already doing the same
        // work. Ordering windows out is synchronous and keeps cleanup intact.
        for window in application.windows where window.isVisible {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    private func finishTerminationAfterShutdown() {
        guard terminationState == .waiting else { return }
        updateShutdownWindow?.close()
        updateShutdownWindow = nil
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        replyToTerminationRequest()
    }

    private func finishTerminationAfterTimeout() {
        guard terminationState == .waiting else { return }
        guard allowsTerminationTimeoutFallback else {
            showUpdateShutdownWait()
            return
        }
        terminationTask?.cancel()
        terminationTask = nil
        replyToTerminationRequest()
    }

    private func showUpdateShutdownWait() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.string("updates.finishing.title", fallback: "Finishing playback cleanup")
        let label = NSTextField(wrappingLabelWithString: L10n.string("updates.finishing.message", fallback: "The update is waiting for playback and history cleanup. Installation will continue when cleanup finishes."))
        label.frame = NSRect(x: 24, y: 24, width: 412, height: 80)
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        updateShutdownWindow = window
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
    private struct MediaGeometry: Equatable {
        let videoWidth: Int
        let videoHeight: Int
        let override: String?
    }

    private weak var appState: AppState?
    private let preferenceStore: PlayerWindowPreferenceStore
    private var window: NSWindow?
    private weak var playerContentContainer: NSView?
    private var hostingController: NSHostingController<AnyView>?
    private var isDismissingFromState = false
    private var pendingFocusCommandID: UUID?
    private var pendingPresentationCommandID: UUID?
    private var hasDeferredLayoutReset = false
    private var activeGeometryRequestID: UUID?
    private var desiredAspectRatio =
        PlayerWindowPreferencePolicy.fallbackAspectRatio
    private var lastAppliedAspectRatio: Double?
    private var pendingGeometryWorkItem: DispatchWorkItem?
    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var isApplyingProgrammaticFrame = false
    private var programmaticMutationGeneration: UInt64 = 0
    private var lastProgrammaticFrame: NSRect?
    private var isClosingWindow = false
    private var isResettingPreference = false
    private var userOwnsCurrentFrame = false
    private var geometryGeneration: UInt64 = 0
    private let explicitGeometryKey = UUID()
    private let userFrameKey = UUID()
    private var overlayHostingView: PlayerOverlayHostingView<AnyView>?
    private var playerOverlayContainer: PlayerFullscreenOverlayView?
    private let fullscreenPresentation = PlayerFullscreenPresentation()
    private var snapshotGeometryCancellable: AnyCancellable?
    private var windowModeCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        preferenceStore = appState.playerWindowPreferences
        super.init()
        snapshotGeometryCancellable = appState.playerSnapshotState.$snapshot
            .map { snapshot in
                MediaGeometry(
                    videoWidth: snapshot.videoWidth,
                    videoHeight: snapshot.videoHeight,
                    override: appState.playerAspectRatio
                )
            }
            .merge(
                with: appState.$playerAspectRatio.map { override in
                    let snapshot = appState.playerSnapshotState.snapshot
                    return MediaGeometry(
                        videoWidth: snapshot.videoWidth,
                        videoHeight: snapshot.videoHeight,
                        override: override
                    )
                }
            )
            .removeDuplicates()
            .sink { [weak self] geometry in
                self?.updateMediaGeometry(geometry)
            }
        windowModeCancellable = preferenceStore.$preference
            .map(\.mode)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in
                self?.handleModeChange(mode)
            }
    }

    func prewarm() {
        guard window == nil else { return }
        _ = ensureWindowShell()
    }

#if DEBUG || OKVIDEO_PERFORMANCE_TEST
    var windowForTesting: NSWindow? { window }
    var isWindowShellPreparedForTesting: Bool {
        window != nil
    }

    var hasMountedPlayerContentForTesting: Bool {
        hostingController != nil
    }
#endif

    func resetLayout() {
        pendingGeometryWorkItem?.cancel()
        pendingPersistenceWorkItem?.cancel()
        isResettingPreference = true
        preferenceStore.reset()
        isResettingPreference = false
        guard let window else {
            hasDeferredLayoutReset = false
            return
        }
        hasDeferredLayoutReset = true
        desiredAspectRatio = currentEffectiveAspectRatio()
        requestExplicitGeometry(for: window)
    }

    func execute(_ command: PlayerWindowCommand) {
        switch command.kind {
        case .showAndActivate, .focus:
            guard owns(command) else { return }
            beginGeometryRequestIfNeeded(command.requestID)
            showAndActivate(command: command)
        case .showWithoutStealingFocus:
            guard owns(command) else { return }
            beginGeometryRequestIfNeeded(command.requestID)
            showWithoutStealingFocus(command: command)
        case .toggleFullScreen:
            guard owns(command), let window else { return }
            WindowTransitionCoordinator.state(for: window).requestFullScreenToggle()
        case .close:
            dismiss()
        }
    }

    private func owns(_ command: PlayerWindowCommand) -> Bool {
        guard let requestID = command.requestID else { return true }
        return appState?.ownsPlayerWindowRequest(requestID) == true
    }

    private func showAndActivate(command: PlayerWindowCommand) {
        pendingFocusCommandID = command.id
        pendingPresentationCommandID = command.id
        // Player commands are published from SwiftUI actions. Defer all
        // NSWindow mutations, including mounting the NSHostingController, by
        // one main-loop turn so they cannot re-enter the originating
        // List/layout transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.owns(command),
                  self.pendingPresentationCommandID == command.id else {
                return
            }
            guard let window = self.ensureWindow() else { return }
            self.pendingPresentationCommandID = nil
            self.applyPreferredGeometry(to: window, animate: false)
            self.activateAndShow(command: command, window: window)
        }
    }

    private func activateAndShow(
        command: PlayerWindowCommand,
        window: NSWindow
    ) {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        restoreVisibleFrameIfNeeded(window)
        window.makeKeyAndOrderFront(nil)
        if window.isKeyWindow {
            pendingFocusCommandID = nil
        }
        scheduleFocusConfirmation(for: command, window: window)
    }

    private func showWithoutStealingFocus(command: PlayerWindowCommand) {
        pendingPresentationCommandID = command.id
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.owns(command),
                  self.pendingPresentationCommandID == command.id else {
                return
            }
            guard let window = self.ensureWindow() else { return }
            self.pendingPresentationCommandID = nil
            self.applyPreferredGeometry(to: window, animate: false)
            self.restoreVisibleFrameIfNeeded(window)
            guard !window.isMiniaturized, !window.isVisible else { return }
            window.orderFront(nil)
        }
    }

    private func ensureWindow() -> NSWindow? {
        guard let appState else { return nil }
        guard let window = ensureWindowShell() else { return nil }

        if hostingController == nil {
            let rootView = AnyView(
                PlayerPlaybackWindowRoot(appState: appState)
                    .environmentObject(appState)
            )
            let hostingController = NSHostingController(rootView: rootView)
            if #available(macOS 13.0, *) {
                // The player root intentionally expands to the window. Its
                // SwiftUI ideal size can therefore contain an unbounded
                // dimension while the first playback tree is mounting. Do not
                // let NSHostingController feed that value back into NSWindow's
                // frame; the player geometry coordinator is the sole owner of
                // the window size.
                hostingController.sizingOptions = []
            }

            // Do not install the hosting controller through
            // NSWindow.contentViewController. AppKit asks a newly installed
            // controller for its fitting size and immediately feeds that
            // value back into the window frame. PlayerPlaybackWindowRoot is a
            // fill view, so its first SwiftUI sizing pass can legitimately
            // contain an unbounded dimension; macOS 14 then traps while
            // converting that infinity into an NSWindow display region.
            //
            // The window already owns a finite AppKit content view. Mount the
            // retained hosting view inside that container and let autoresizing
            // follow the window instead. PlayerWindowPreferenceStore remains
            // the only code allowed to change the window geometry.
            guard let container = playerContentContainer ?? window.contentView
            else { return nil }
            let hostedView = hostingController.view
            hostedView.translatesAutoresizingMaskIntoConstraints = true
            hostedView.frame = container.bounds
            hostedView.autoresizingMask = [.width, .height]
            container.addSubview(hostedView)
            self.hostingController = hostingController
            if let overlay = playerOverlayContainer {
                let host = PlayerOverlayHostingView(rootView: AnyView(
                    PlayerPlaybackOverlayRoot(appState: appState).environmentObject(appState)
                ))
                if #available(macOS 13.0, *) { host.sizingOptions = [] }
                host.frame = overlay.bounds
                host.autoresizingMask = [.width, .height]
                overlay.addSubview(host)
                overlayHostingView = host
            }
        }
        return window
    }

    private func ensureWindowShell() -> NSWindow? {
        if let window { return window }
        guard appState != nil else { return nil }

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
        WindowTransitionCoordinator.state(for: window).onFullScreenRecovery = { [weak self] window in
            guard let self, self.window === window else { return }
            self.fullscreenPresentation.failed(window: window)
        }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = NSSize(
            width: PlayerWindowPreferencePolicy.minimumContentWidth,
            height: PlayerWindowPreferencePolicy.minimumContentHeight
        )
        window.contentAspectRatio = .zero
        self.window = window
        if let content = window.contentView {
            content.wantsLayer = true
            let composition = PlayerFullscreenContentView(frame: content.bounds)
            content.addSubview(composition)
            playerContentContainer = composition
            let overlay = PlayerFullscreenOverlayView(frame: content.bounds)
            content.addSubview(overlay)
            playerOverlayContainer = overlay
        }

        configureInitialGeometry(for: window)
        return window
    }

    private func scheduleFocusConfirmation(
        for command: PlayerWindowCommand,
        window: NSWindow
    ) {
        DispatchQueue.main.async { [weak self, weak window] in
            self?.confirmFocus(for: command, window: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            [weak self, weak window] in
            self?.confirmFocus(for: command, window: window)
        }
    }

    private func confirmFocus(
        for command: PlayerWindowCommand,
        window: NSWindow?
    ) {
        guard let window else { return }
        let ownsRequest = command.requestID.map {
            appState?.ownsPlayerWindowRequest($0) == true
        } ?? true
        guard PlayerWindowFocusCompensationPolicy.shouldRetry(
            isApplicationActive: NSApp.isActive,
            isWindowKey: window.isKeyWindow,
            ownsRequest: ownsRequest,
            isCommandPending: pendingFocusCommandID == command.id
        ) else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreVisibleFrameIfNeeded(_ window: NSWindow) {
        guard WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallback = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let adjusted = AppWindowLayoutPolicy.adjustedFrame(
            window.frame,
            visibleFrames: visibleFrames,
            fallbackVisibleFrame: fallback
        )
        guard adjusted != window.frame else { return }
        applyProgrammaticFrame(adjusted, to: window, animate: false)
    }

    func dismiss() {
        guard let window else { return }
        pendingFocusCommandID = nil
        pendingPresentationCommandID = nil
        persistUserFrameIfEligible(window)
        preferenceStore.flushPendingUserFrame()
        cancelGeometryWork()
        isDismissingFromState = true
        isClosingWindow = true
        window.close()
        clearWindowReferences()
        isDismissingFromState = false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        persistUserFrameIfEligible(closingWindow)
        preferenceStore.flushPendingUserFrame()
        isClosingWindow = true
        cancelGeometryWork()
        let shouldClosePlayback = !isDismissingFromState
            && appState?.isPlayerPresented == true
        clearWindowReferences()
        if shouldClosePlayback {
            Task { @MainActor [weak appState] in
                await appState?.closePlayer()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let keyWindow = notification.object as? NSWindow,
              keyWindow === window else { return }
        pendingFocusCommandID = nil
        appState?.setPlayerWindowKey(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let resignedWindow = notification.object as? NSWindow,
              resignedWindow === window else { return }
        appState?.setPlayerWindowKey(false)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window,
              !resizedWindow.inLiveResize else { return }
        stageUserFrame(for: resizedWindow)
        scheduleUserFramePersistence(for: resizedWindow)
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === window else { return }
        stageUserFrame(for: movedWindow)
        scheduleUserFramePersistence(for: movedWindow)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        if WindowTransitionCoordinator.state(for: resizedWindow).phase == .windowed,
           !isApplyingProgrammaticFrame {
            userOwnsCurrentFrame = true
        }
        cancelGeometryWork()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        // Notification/delegate ordering is unspecified. Wait until both have
        // returned before reading the final user frame.
        let transition = WindowTransitionCoordinator.state(for: resizedWindow)
        guard transition.phase == .windowed else { return }
        transition.whenStable(key: userFrameKey, windowedOnly: true) { [weak self] stableWindow in
            guard let self, let stableWindow, self.window === stableWindow,
                  self.userOwnsCurrentFrame else { return }
            self.stageUserFrame(for: stableWindow)
            self.persistUserFrameIfEligible(stableWindow)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        WindowTransitionCoordinator.state(for: changedWindow).beginFullScreen(entering: true)
        cancelGeometryWork()
    }

    private func videoSurface(in view: NSView?) -> MPVOpenGLView? {
        guard let view else { return nil }
        if let surface = view as? MPVOpenGLView { return surface }
        for child in view.subviews {
            if let surface = videoSurface(in: child) { return surface }
        }
        return nil
    }

    func customWindowsToEnterFullScreen(for window: NSWindow, on screen: NSScreen) -> [NSWindow]? {
        guard self.window === window,
              appState?.isLivePlayback != true,
              fullscreenPresentation.prepareToEnter(window: window,
                surface: videoSurface(in: window.contentView),
                aspectRatio: currentEffectiveAspectRatio(),
                presentationView: playerContentContainer) else { return nil }
        return [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen,
                withDuration duration: TimeInterval) {
        guard self.window === window else { return }
        fullscreenPresentation.startEntering(window: window, screen: screen, duration: duration)
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        guard self.window === window,
              appState?.isLivePlayback != true,
              fullscreenPresentation.prepareToExit(window: window,
                surface: videoSurface(in: window.contentView),
                aspectRatio: currentEffectiveAspectRatio()) else { return nil }
        return [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        guard self.window === window else { return }
        fullscreenPresentation.startExiting(window: window, duration: duration)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        WindowTransitionCoordinator.state(for: changedWindow).beginFullScreen(entering: false)
        cancelGeometryWork()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        fullscreenPresentation.complete(window: changedWindow, isFullScreen: true)
        WindowTransitionCoordinator.state(for: changedWindow).completeFullScreen(isFullScreen: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        fullscreenPresentation.complete(window: changedWindow, isFullScreen: false)
        WindowTransitionCoordinator.state(for: changedWindow).completeFullScreen(isFullScreen: false)
        userOwnsCurrentFrame = true
        scheduleUserFramePersistence(for: changedWindow)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard self.window === window else { return }
        fullscreenPresentation.failed(window: window)
        WindowTransitionCoordinator.state(for: window).fullScreenDidFail()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard self.window === window else { return }
        fullscreenPresentation.failed(window: window)
        WindowTransitionCoordinator.state(for: window).fullScreenDidFail()
    }

    private func requestExplicitGeometry(for window: NSWindow) {
        WindowTransitionCoordinator.state(for: window).whenStable(
            key: explicitGeometryKey, windowedOnly: true
        ) { [weak self] stableWindow in
            guard let self, let stableWindow, self.window === stableWindow else { return }
            self.hasDeferredLayoutReset = false
            self.userOwnsCurrentFrame = false
            self.lastAppliedAspectRatio = nil
            self.scheduleGeometryApplication(immediate: true)
        }
    }

    private func beginGeometryRequestIfNeeded(_ requestID: UUID?) {
        guard activeGeometryRequestID != requestID else { return }
        activeGeometryRequestID = requestID
        desiredAspectRatio =
            PlayerWindowPreferencePolicy.fallbackAspectRatio
        lastAppliedAspectRatio = nil
        scheduleGeometryApplication(immediate: true)
    }

    private func updateMediaGeometry(_ geometry: MediaGeometry) {
        guard activeGeometryRequestID != nil,
              appState?.isPlayerPresented == true else { return }
        guard let ratio = PlayerWindowAspectPolicy.aspectRatio(
            isLivePlayback: appState?.isLivePlayback ?? false,
            override: geometry.override,
            videoWidth: geometry.videoWidth,
            videoHeight: geometry.videoHeight
        ) else { return }
        guard !PlayerWindowPreferencePolicy.ratiosMatch(
            desiredAspectRatio,
            ratio
        ) else { return }
        desiredAspectRatio = ratio
        scheduleGeometryApplication(immediate: false)
    }

    private func handleModeChange(_ mode: PlayerWindowMode) {
        guard !isResettingPreference, let window else { return }
        if WindowTransitionCoordinator.state(for: window).canChangeGeometry,
           !isClosingWindow {
            preferenceStore.captureModeTransition(to: mode,
                currentContentSize: contentSize(of: window))
        }
        requestExplicitGeometry(for: window)
    }

    private func configureInitialGeometry(for window: NSWindow) {
        let descriptor = AppWindowLayoutPolicy.descriptor(for: .playerWindow)
        window.identifier = descriptor.identifier
        // The player has its own semantic preference store. Leaving AppKit's
        // autosave enabled here would race programmatic aspect adaptation and
        // overwrite the user's viewing width with a derived video height.
        window.setFrameAutosaveName("")

        if !preferenceStore.hasPersistedPreference {
            if let legacyFrame = preferenceStore.legacyFrame() {
                let screen = screen(containing: legacyFrame)
                    ?? NSScreen.main
                let visibleFrame = screen?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
                let adjustedLegacyFrame = AppWindowLayoutPolicy.adjustedFrame(
                    legacyFrame,
                    visibleFrames: NSScreen.screens.map(\.visibleFrame),
                    fallbackVisibleFrame: visibleFrame
                )
                preferenceStore.migrateLegacyFrame(
                    contentSize: window.contentRect(
                        forFrameRect: adjustedLegacyFrame
                    ).size,
                    windowFrame: adjustedLegacyFrame,
                    visibleFrame: visibleFrame,
                    screenIdentifier: screen?.okVideoScreenIdentifier
                )
            } else {
                preferenceStore.clearLegacyFrame()
                preferenceStore.ensurePersisted()
            }
        } else {
            preferenceStore.clearLegacyFrame()
        }
    }

    private func scheduleGeometryApplication(immediate: Bool) {
        guard let window else { return }
        pendingGeometryWorkItem?.cancel()
        geometryGeneration &+= 1
        let generation = geometryGeneration
        guard WindowTransitionCoordinator.state(for: window).canChangeGeometry,
              !userOwnsCurrentFrame,
              !isClosingWindow else { return }

        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.geometryGeneration == generation else { return }
            self.applyPreferredGeometry(to: window, animate: window.isVisible)
        }
        pendingGeometryWorkItem = workItem
        if immediate {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.18,
                execute: workItem
            )
        }
    }

    private func applyPreferredGeometry(
        to window: NSWindow,
        animate: Bool
    ) {
        guard self.window === window,
              WindowTransitionCoordinator.state(for: window).canChangeGeometry,
              !userOwnsCurrentFrame,
              !isClosingWindow else { return }
        pendingGeometryWorkItem = nil

        let preference = preferenceStore.preference
        let ratio = PlayerWindowPreferencePolicy.validAspectRatio(
            desiredAspectRatio
        ) ?? PlayerWindowPreferencePolicy.fallbackAspectRatio

        switch preference.mode {
        case .fixedFrame:
            window.contentAspectRatio = .zero
            window.contentMinSize = NSSize(
                width: CGFloat(
                    PlayerWindowPreferencePolicy.minimumContentWidth
                ),
                height: CGFloat(
                    PlayerWindowPreferencePolicy.minimumContentHeight
                )
            )
        case .automaticAspect:
            window.contentAspectRatio = NSSize(
                width: CGFloat(ratio),
                height: 1
            )
            window.contentMinSize = PlayerWindowPreferencePolicy.minimumContentSize(
                aspectRatio: ratio
            )
        }

        let targetScreen = screen(
            identifier: preference.screenIdentifier
        ) ?? window.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let availableFrame = availableFrame(within: visibleFrame)
        let maximumContentSize = window.contentRect(
            forFrameRect: availableFrame
        ).size
        let desiredContentSize = PlayerWindowPreferencePolicy.contentSize(
            preference: preference,
            aspectRatio: ratio,
            maximum: maximumContentSize
        )
        var desiredFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: desiredContentSize)
        )
        desiredFrame.origin = PlayerWindowPreferencePolicy.frameOrigin(
            frameSize: desiredFrame.size,
            visibleFrame: visibleFrame,
            normalizedCenterX: preference.normalizedCenterX,
            normalizedCenterY: preference.normalizedCenterY
        )
        desiredFrame.origin.x = min(
            max(desiredFrame.minX, availableFrame.minX),
            availableFrame.maxX - desiredFrame.width
        )
        desiredFrame.origin.y = min(
            max(desiredFrame.minY, availableFrame.minY),
            availableFrame.maxY - desiredFrame.height
        )

        let frameAlreadyMatches = framesMatch(window.frame, desiredFrame)
        let ratioAlreadyMatches =
            preference.mode == .fixedFrame
            || PlayerWindowPreferencePolicy.ratiosMatch(
                lastAppliedAspectRatio,
                ratio
            )
        guard !frameAlreadyMatches || !ratioAlreadyMatches else { return }
        lastAppliedAspectRatio = ratio
        applyProgrammaticFrame(
            desiredFrame,
            to: window,
            animate: animate && !frameAlreadyMatches
        )
    }

    private func applyProgrammaticFrame(
        _ frame: NSRect,
        to window: NSWindow,
        animate: Bool
    ) {
        guard WindowTransitionCoordinator.state(for: window).canChangeGeometry,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
        programmaticMutationGeneration &+= 1
        let generation = programmaticMutationGeneration
        isApplyingProgrammaticFrame = true
        lastProgrammaticFrame = frame
        // Keep programmatic aspect changes atomic. NSWindow animation emits a
        // stream of resize callbacks that is indistinguishable from a user's
        // drag and can persist a derived intermediate frame.
        window.setFrame(frame, display: true, animate: false)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  self.programmaticMutationGeneration == generation,
                  self.window === window else { return }
            self.isApplyingProgrammaticFrame = false
        }
    }

    private func scheduleUserFramePersistence(for window: NSWindow) {
        guard shouldPersistUserFrame(window) else { return }
        pendingPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.persistUserFrameIfEligible(window)
        }
        pendingPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.22,
            execute: workItem
        )
    }

    private func stageUserFrame(for window: NSWindow) {
        guard shouldPersistUserFrame(window) else { return }
        userOwnsCurrentFrame = true
        let targetScreen = window.screen
            ?? screen(containing: window.frame)
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        preferenceStore.stageUserFrame(
            contentSize: contentSize(of: window),
            windowFrame: window.frame,
            visibleFrame: visibleFrame,
            screenIdentifier: targetScreen?.okVideoScreenIdentifier
        )
    }

    private func persistUserFrameIfEligible(_ window: NSWindow) {
        guard shouldPersistUserFrame(window) else { return }
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
        let targetScreen = window.screen
            ?? screen(containing: window.frame)
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        preferenceStore.saveUserFrame(
            contentSize: contentSize(of: window),
            windowFrame: window.frame,
            visibleFrame: visibleFrame,
            screenIdentifier: targetScreen?.okVideoScreenIdentifier
        )
        lastProgrammaticFrame = nil
    }

    private func shouldPersistUserFrame(_ window: NSWindow) -> Bool {
        guard self.window === window,
              !isClosingWindow,
              !isApplyingProgrammaticFrame,
              WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return false }
        if let lastProgrammaticFrame,
           framesMatch(window.frame, lastProgrammaticFrame) {
            return false
        }
        return true
    }

    private func cancelGeometryWork() {
        geometryGeneration &+= 1
        pendingGeometryWorkItem?.cancel()
        pendingGeometryWorkItem = nil
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
    }

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    private func screen(identifier: UInt32?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first {
            $0.okVideoScreenIdentifier == identifier
        }
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        guard let candidate = NSScreen.screens.max(by: { lhs, rhs in
            intersectionArea(lhs.visibleFrame.intersection(frame))
                < intersectionArea(rhs.visibleFrame.intersection(frame))
        }), intersectionArea(candidate.visibleFrame.intersection(frame)) > 0
        else { return nil }
        return candidate
    }

    private func currentEffectiveAspectRatio() -> Double {
        guard let appState else {
            return PlayerWindowPreferencePolicy.fallbackAspectRatio
        }
        let snapshot = appState.playerSnapshotState.snapshot
        return PlayerWindowAspectPolicy.aspectRatio(
            isLivePlayback: appState.isLivePlayback,
            override: appState.playerAspectRatio,
            videoWidth: snapshot.videoWidth,
            videoHeight: snapshot.videoHeight
        ) ?? PlayerWindowPreferencePolicy.fallbackAspectRatio
    }

    private func availableFrame(within visibleFrame: NSRect) -> NSRect {
        let horizontalInset = min(
            CGFloat(PlayerWindowPreferencePolicy.screenMargin),
            max(0, (visibleFrame.width - 1) / 2)
        )
        let verticalInset = min(
            CGFloat(PlayerWindowPreferencePolicy.screenMargin),
            max(0, (visibleFrame.height - 1) / 2)
        )
        return visibleFrame.insetBy(
            dx: horizontalInset,
            dy: verticalInset
        )
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func intersectionArea(_ rect: NSRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }

    private func clearWindowReferences() {
        fullscreenPresentation.cancel()
        cancelGeometryWork()
        pendingFocusCommandID = nil
        pendingPresentationCommandID = nil
        hasDeferredLayoutReset = false
        activeGeometryRequestID = nil
        lastAppliedAspectRatio = nil
        appState?.setPlayerWindowKey(false)
        hostingController?.view.removeFromSuperview()
        overlayHostingView?.removeFromSuperview()
        if let window {
            WindowTransitionCoordinator.state(for: window).cancel(explicitGeometryKey)
            WindowTransitionCoordinator.state(for: window).cancel(userFrameKey)
        }
        window?.delegate = nil
        window = nil
        playerContentContainer = nil
        playerOverlayContainer = nil
        overlayHostingView = nil
        hostingController = nil
        lastProgrammaticFrame = nil
        isApplyingProgrammaticFrame = false
        isClosingWindow = false
        userOwnsCurrentFrame = false
    }

    private func initialContentSize() -> NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return AppWindowLayoutPolicy.defaultContentSize(
            for: .playerWindow,
            visibleFrame: visibleFrame
        )
    }
}

@MainActor
enum BrowserWindowChromeController {
    static func configure(_ window: NSWindow) {
        let transition = WindowTransitionCoordinator.state(for: window)
        guard !transition.browserChromeConfigured, transition.canChangeGeometry else { return }
        transition.browserChromeConfigured = true
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        // Each split pane supplies its own native material through the titlebar:
        // AppKit's full-height sidebar on the left, .titlebar on the right.
        // Page backgrounds respect the top safe area. A second system titlebar
        // fill would reserve a 1 pt split seam and expose the page underneath.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // Refresh AppKit's own shadow after finalizing the backing surface so
        // it cannot retain a stale outline from the pre-configuration frame.
        window.hasShadow = true
        window.invalidateShadow()
    }
}

/// Explicit persistence survives SwiftUI replacing its generated frame-autosave name.
@MainActor
final class MainWindowGeometryStore {
    static let storageKey = "OKVideoMac.MainWindow.Geometry.v1"
    private static var associationKey: UInt8 = 0
    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?

    static func attach(to window: NSWindow) {
        guard objc_getAssociatedObject(window, &associationKey) == nil else { return }
        let store = MainWindowGeometryStore(window: window)
        objc_setAssociatedObject(window, &associationKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func savedFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let data = defaults.data(forKey: storageKey),
              let frame = try? JSONDecoder().decode(CGRect.self, from: data),
              [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.width >= 300, frame.height >= 200 else { return nil }
        return frame
    }

    init(window: NSWindow, defaults: UserDefaults = .standard) {
        self.window = window
        self.defaults = defaults
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            })
        }
        for (name, object) in [(NSWindow.willCloseNotification, window as AnyObject),
                               (NSApplication.willTerminateNotification, NSApp as AnyObject)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.save()
        }
    }

    func save() {
        guard let window, WindowTransitionCoordinator.state(for: window).canChangeGeometry,
              !window.isMiniaturized, window.frame.width >= 300, window.frame.height >= 200,
              let data = try? JSONEncoder().encode(window.frame) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    deinit {
        saveTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct AppWindowLayoutDescriptor {
    let identifier: NSUserInterfaceItemIdentifier
    let frameAutosaveName: String
    let preferredContentSize: NSSize
    let minimumContentSize: NSSize
    let preservesSixteenByNine: Bool
}

enum AppWindowLayoutPolicy {
    private static let fallbackVisibleFrame = NSRect(
        x: 0,
        y: 0,
        width: 1_440,
        height: 900
    )
    private static let minimumVisibleLength: CGFloat = 80
    private static let screenMargin: CGFloat = 40

    static func descriptor(
        for target: AppWindowLayoutTarget
    ) -> AppWindowLayoutDescriptor {
        switch target {
        case .mainWindow:
            return AppWindowLayoutDescriptor(
                identifier: NSUserInterfaceItemIdentifier(
                    "OKVideoMac.MainWindow"
                ),
                frameAutosaveName: "OKVideoMac.MainWindow.v1",
                preferredContentSize: NSSize(width: 1_240, height: 780),
                minimumContentSize: NSSize(width: 900, height: 600),
                preservesSixteenByNine: false
            )
        case .playerWindow:
            return AppWindowLayoutDescriptor(
                identifier: NSUserInterfaceItemIdentifier(
                    "OKVideoMac.PlayerWindow"
                ),
                frameAutosaveName: "OKVideoMac.PlayerWindow.v2",
                preferredContentSize: NSSize(width: 1_152, height: 648),
                minimumContentSize: NSSize(width: 800, height: 450),
                preservesSixteenByNine: true
            )
        }
    }

    static func defaultContentSize(
        for target: AppWindowLayoutTarget,
        visibleFrame: NSRect
    ) -> NSSize {
        let descriptor = descriptor(for: target)
        let availableWidth = max(1, visibleFrame.width - screenMargin * 2)
        let availableHeight = max(1, visibleFrame.height - screenMargin * 2)

        if descriptor.preservesSixteenByNine {
            let aspectRatio: CGFloat = 16 / 9
            let minimumWidth = min(
                descriptor.minimumContentSize.width,
                availableWidth
            )
            let minimumHeight = min(
                descriptor.minimumContentSize.height,
                availableHeight
            )
            let maximumWidth = min(
                descriptor.preferredContentSize.width,
                availableWidth,
                availableHeight * aspectRatio
            )
            let width = max(
                min(maximumWidth, availableHeight * aspectRatio),
                min(minimumWidth, minimumHeight * aspectRatio)
            )
            return NSSize(width: width, height: width / aspectRatio)
        }

        return NSSize(
            width: fittedDimension(
                preferred: descriptor.preferredContentSize.width,
                minimum: descriptor.minimumContentSize.width,
                available: availableWidth
            ),
            height: fittedDimension(
                preferred: descriptor.preferredContentSize.height,
                minimum: descriptor.minimumContentSize.height,
                available: availableHeight
            )
        )
    }

    @MainActor
    static func configure(
        _ window: NSWindow,
        target: AppWindowLayoutTarget
    ) {
        let descriptor = descriptor(for: target)
        let isAlreadyConfigured = window.identifier == descriptor.identifier
        guard !isAlreadyConfigured,
              WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
        window.identifier = descriptor.identifier
        window.contentMinSize = descriptor.minimumContentSize

        if target == .mainWindow, let frame = MainWindowGeometryStore.savedFrame() {
            window.setFrame(frame, display: false)
        } else if !window.setFrameUsingName(descriptor.frameAutosaveName) {
            applyDefaultFrame(window, target: target, animate: false)
        }
        window.setFrameAutosaveName(descriptor.frameAutosaveName)
        restoreVisibleFrameIfNeeded(window)
        if target == .mainWindow { MainWindowGeometryStore.attach(to: window) }
    }

    @MainActor
    static func restoreDefaultLayout(
        _ window: NSWindow,
        target: AppWindowLayoutTarget
    ) {
        guard WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
        prepareForDeferredReset(window, target: target)
        let descriptor = descriptor(for: target)
        window.identifier = descriptor.identifier
        window.contentMinSize = descriptor.minimumContentSize
        applyDefaultFrame(window, target: target, animate: window.isVisible)
        window.setFrameAutosaveName(descriptor.frameAutosaveName)
    }

    @MainActor
    static func prepareForDeferredReset(
        _ window: NSWindow,
        target: AppWindowLayoutTarget
    ) {
        window.setFrameAutosaveName("")
        clearSavedFrame(for: target)
    }

    static func clearSavedFrame(for target: AppWindowLayoutTarget) {
        if target == .mainWindow {
            UserDefaults.standard.removeObject(forKey: MainWindowGeometryStore.storageKey)
        }
        let autosaveName = descriptor(for: target).frameAutosaveName
        UserDefaults.standard.removeObject(
            forKey: "NSWindow Frame \(autosaveName)"
        )
    }

    @MainActor
    static func window(for target: AppWindowLayoutTarget) -> NSWindow? {
        let identifier = descriptor(for: target).identifier
        return NSApp.windows.first { $0.identifier == identifier }
    }

    @MainActor
    static func restoreVisibleFrameIfNeeded(_ window: NSWindow) {
        guard WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallback = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? fallbackVisibleFrame
        let adjusted = adjustedFrame(
            window.frame,
            visibleFrames: visibleFrames,
            fallbackVisibleFrame: fallback
        )
        guard adjusted != window.frame else { return }
        window.setFrame(adjusted, display: false)
    }

    static func adjustedFrame(
        _ frame: NSRect,
        visibleFrames: [NSRect],
        fallbackVisibleFrame: NSRect
    ) -> NSRect {
        let bestVisibleFrame = visibleFrames.max { lhs, rhs in
            intersectionArea(lhs.intersection(frame))
                < intersectionArea(rhs.intersection(frame))
        }
        let bestIntersection = bestVisibleFrame?.intersection(frame) ?? .zero
        let isSufficientlyVisible = bestIntersection.width
            >= minimumVisibleLength
            && bestIntersection.height >= minimumVisibleLength
        let targetVisibleFrame = isSufficientlyVisible
            ? (bestVisibleFrame ?? fallbackVisibleFrame)
            : fallbackVisibleFrame

        if isSufficientlyVisible,
           frame.width <= targetVisibleFrame.width,
           frame.height <= targetVisibleFrame.height {
            return frame
        }

        var adjusted = frame
        adjusted.size.width = min(adjusted.width, targetVisibleFrame.width)
        adjusted.size.height = min(adjusted.height, targetVisibleFrame.height)
        if isSufficientlyVisible {
            adjusted.origin.x = min(
                max(adjusted.origin.x, targetVisibleFrame.minX),
                targetVisibleFrame.maxX - adjusted.width
            )
            adjusted.origin.y = min(
                max(adjusted.origin.y, targetVisibleFrame.minY),
                targetVisibleFrame.maxY - adjusted.height
            )
        } else {
            adjusted.origin = NSPoint(
                x: targetVisibleFrame.midX - adjusted.width / 2,
                y: targetVisibleFrame.midY - adjusted.height / 2
            )
        }
        return adjusted
    }

    @MainActor
    private static func applyDefaultFrame(
        _ window: NSWindow,
        target: AppWindowLayoutTarget,
        animate: Bool
    ) {
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? fallbackVisibleFrame
        let contentSize = defaultContentSize(
            for: target,
            visibleFrame: visibleFrame
        )
        var frame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        )
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        frame = adjustedFrame(
            frame,
            visibleFrames: [visibleFrame],
            fallbackVisibleFrame: visibleFrame
        )
        window.setFrame(frame, display: true, animate: animate)
    }

    private static func fittedDimension(
        preferred: CGFloat,
        minimum: CGFloat,
        available: CGFloat
    ) -> CGFloat {
        guard available >= minimum else { return available }
        return min(preferred, available)
    }

    private static func intersectionArea(_ rect: NSRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }
}

enum PlayerWindowSizingPolicy {
    static let aspectRatio: CGFloat = 16 / 9

    static func initialContentSize(visibleFrame: NSRect) -> NSSize {
        AppWindowLayoutPolicy.defaultContentSize(
            for: .playerWindow,
            visibleFrame: visibleFrame
        )
    }
}

enum PlayerWindowFrameVisibilityPolicy {
    static func adjustedFrame(
        _ frame: NSRect,
        visibleFrames: [NSRect],
        fallbackVisibleFrame: NSRect
    ) -> NSRect {
        AppWindowLayoutPolicy.adjustedFrame(
            frame,
            visibleFrames: visibleFrames,
            fallbackVisibleFrame: fallbackVisibleFrame
        )
    }
}

struct PlayerPlaybackWindowRoot: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: appState.isPlayerPresented,
                isMountEnabled: appState.isPlayerRenderSurfaceMountEnabled,
                hasRenderPlayer: appState.embeddedPlayer != nil
            ), let player = appState.embeddedPlayer {
                MPVRenderView(
                    player: player,
                    onError: { error in
                        appState.reportPlayerRenderError(error)
                    },
                    onSurfaceReady: { renderOwnerID in
                        appState.playerRenderSurfaceDidBecomeReady(
                            renderOwnerID
                        )
                    },
                    onSurfaceUnavailable: { renderOwnerID in
                        appState.playerRenderSurfaceDidBecomeUnavailable(
                            renderOwnerID
                        )
                    }
                )
                .id(player.renderOwnerID)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if appState.isPlayerPresented, !appState.isLivePlayback {
                PlayerDanmakuLayer(coordinator: appState.danmaku, snapshotState: appState.playerSnapshotState)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)

    }
}

enum MainMenuLocalization {
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

    private static let englishTitles = Dictionary(
        uniqueKeysWithValues: exactTitles.map { ($1, $0) }
    )

    static func title(
        for original: String,
        language: AppLanguage = L10n.language
    ) -> String {
        switch language {
        case .simplifiedChinese:
            if let exact = exactTitles[original] {
                return exact
            }
        case .english:
            if let exact = englishTitles[original] {
                return exact
            }
        }
        return dynamicTitle(for: original, language: language)
    }

    private static func dynamicTitle(
        for original: String,
        language: AppLanguage
    ) -> String {
        switch language {
        case .simplifiedChinese:
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
        case .english:
            for (chinese, english) in [
                ("关于 ", "About "), ("隐藏 ", "Hide "),
                ("退出 ", "Quit "), ("撤销 ", "Undo "),
                ("重做 ", "Redo ")
            ] where original.hasPrefix(chinese) {
                return english + String(original.dropFirst(chinese.count))
            }
            if original.hasSuffix(" 帮助") {
                return String(original.dropLast(" 帮助".count)) + " Help"
            }
        }
        return original
    }
}

@MainActor
final class MainMenuLocalizationController {
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
            let translatedTitle = MainMenuLocalization.title(
                for: item.title
            )
            if translatedTitle != item.title {
                item.title = translatedTitle
            }
            if let submenu = item.submenu {
                let translatedMenuTitle = MainMenuLocalization.title(
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
    @ObservedObject private var updates = AppUpdateCoordinator.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.string("updates.check", fallback: "Check for Updates…")) { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
            if let version = updates.availableVersion {
                Button(L10n.string("updates.available", fallback: "Update Available") + " \(version)") { updates.checkForUpdates() }
            }
        }
        CommandMenu(L10n.string("menu.navigation", fallback: "Navigate")) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) {
                index, section in
                Button(section.title) {
                    state.selectSection(section)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))),
                    modifiers: .command
                )
                .disabled(!state.allowsBrowserShortcuts)
            }

            Divider()

            Button(L10n.string("menu.navigation.search", fallback: "Search")) {
                state.focusGlobalSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button(L10n.string("menu.navigation.quick-switcher", fallback: "Quick Switcher…")) {
                state.presentQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button(L10n.string("menu.navigation.open-vod-configuration", fallback: "Open VOD Configuration")) {
                state.selectedSettingsPane = .configurations
                state.selectSection(.settings)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Divider()

            Button(L10n.string("menu.navigation.refresh", fallback: "Reload Current Page")) {
                Task { await state.performContextRefresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button(L10n.string("menu.navigation.back", fallback: "Back")) {
                Task { await state.performBackShortcut() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button(L10n.string("menu.navigation.stop", fallback: "Stop Current Operation")) {
                state.stopCurrentShortcutOperation()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts || !state.isSearching)

            Divider()

            Button(L10n.string("menu.navigation.shortcuts", fallback: "Keyboard Shortcuts")) {
                state.presentShortcutHelp()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)
        }

        CommandMenu(L10n.string("menu.playback", fallback: "Playback")) {
            Button(L10n.string("menu.playback.play-pause", fallback: "Play/Pause")) {
                Task { await state.togglePlayPause() }
            }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button(L10n.string("menu.playback.seek-back-10", fallback: "Back 10 Seconds")) {
                Task { await state.seek(by: -10) }
            }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button(L10n.string("menu.playback.seek-forward-10", fallback: "Forward 10 Seconds")) {
                Task { await state.seek(by: 10) }
            }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button(L10n.string("menu.playback.seek-back-30", fallback: "Back 30 Seconds")) {
                Task { await state.seek(by: -30) }
            }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button(L10n.string("menu.playback.seek-forward-30", fallback: "Forward 30 Seconds")) {
                Task { await state.seek(by: 30) }
            }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )

            Divider()

            Button(state.previousPlayerResourceTitle) {
                Task { await state.playAdjacentEpisode(offset: -1) }
            }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasPreviousEpisode
                )
            Button(state.nextPlayerResourceTitle) {
                Task { await state.playAdjacentEpisode(offset: 1) }
            }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasNextEpisode
                )

            Divider()

            Button(L10n.string("menu.playback.previous-channel", fallback: "Previous Live Channel")) {
                Task { await state.switchLiveChannel(by: -1) }
            }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSwitchLiveChannel
                )
            Button(L10n.string("menu.playback.next-channel", fallback: "Next Live Channel")) {
                Task { await state.switchLiveChannel(by: 1) }
            }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSwitchLiveChannel
                )

            Divider()

            Button(L10n.string("menu.playback.toggle-mute", fallback: "Mute/Unmute")) {
                Task { await state.togglePlayerMute() }
            }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button(L10n.string("menu.playback.volume-down", fallback: "Volume Down")) {
                Task { await state.adjustPlayerVolume(by: -5) }
            }
                .keyboardShortcut("-", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button(L10n.string("menu.playback.volume-up", fallback: "Volume Up")) {
                Task { await state.adjustPlayerVolume(by: 5) }
            }
                .keyboardShortcut("=", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)

            Divider()

            Button(L10n.string("menu.playback.toggle-subtitles", fallback: "Toggle Subtitles")) {
                Task { await state.togglePlayerSubtitles() }
            }
                .keyboardShortcut("c", modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts
                        || !state.hasPlayerSubtitleTracks
                )
            Button(L10n.string("menu.playback.next-audio-track", fallback: "Next Audio Track")) {
                Task { await state.cyclePlayerAudioTrack() }
            }
                .keyboardShortcut("a", modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasPlayerAudioTracks
                )

            Button(L10n.string("menu.playback.speed-down", fallback: "Decrease Playback Speed")) {
                Task { await state.adjustPlayerSpeed(by: -0.25) }
            }
                .keyboardShortcut(",", modifiers: .shift)
                .disabled(!state.allowsPlayerShortcuts || state.isLivePlayback)
            Button(L10n.string("menu.playback.speed-up", fallback: "Increase Playback Speed")) {
                Task { await state.adjustPlayerSpeed(by: 0.25) }
            }
                .keyboardShortcut(".", modifiers: .shift)
                .disabled(!state.allowsPlayerShortcuts || state.isLivePlayback)

            Divider()

            Button(L10n.string("menu.playback.toggle-full-screen-f", fallback: "Enter/Exit Full Screen (F)")) {
                state.togglePlayerFullScreen()
            }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button(L10n.string("menu.playback.toggle-full-screen", fallback: "Enter/Exit Full Screen")) {
                state.togglePlayerFullScreen()
            }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!state.allowsPlayerShortcuts)

            Button(L10n.string("menu.playback.close-panel-or-full-screen", fallback: "Close Panel or Exit Full Screen")) {
                state.requestPlayerEscapeHandling()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(!state.allowsPlayerShortcuts)
        }
    }
}

/// Shares the video's window, but not its fullscreen scale transform.
struct PlayerPlaybackOverlayRoot: View {
    @ObservedObject var appState: AppState
    var body: some View {
        Group {
            if appState.isPlayerPresented {
                PlayerView(playerSnapshotState: appState.playerSnapshotState, onWindowChromeRestored: {})
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if let error = appState.playerPresentedError {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(error.title).font(.headline)
                        Text(error.message).font(.callout).textSelection(.enabled)
                    }
                    Button { appState.playerPresentedError = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 560)
                .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                .padding(.top, 54)
                .padding(.horizontal, 20)
            }
        }
        .task(id: appState.playerPresentedError?.id) {
            guard let id = appState.playerPresentedError?.id else { return }
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            if appState.playerPresentedError?.id == id { appState.playerPresentedError = nil }
        }
        .appConfigurationSheet(scope: .player)
    }
}
