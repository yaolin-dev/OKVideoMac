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
    static let terminationFallbackTimeout: TimeInterval = 10

    private enum TerminationState {
        case idle
        case waiting
        case completed
    }

    private let mainMenuLocalizer = MainMenuChineseLocalizer()
    private weak var appState: AppState?
    private var playerWindowController: PlayerPlaybackWindowController?
    private var playerPresentationCancellable: AnyCancellable?
    private var playerWindowCommandCancellable: AnyCancellable?
    private var appWindowLayoutCommandCancellable: AnyCancellable?
    private var windowDidExitFullScreenCancellable: AnyCancellable?
    private var pendingMainWindowLayoutReset = false
    private var terminationState = TerminationState.idle
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?

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
        windowDidExitFullScreenCancellable = NotificationCenter.default
            .publisher(for: NSWindow.didExitFullScreenNotification)
            .sink { [weak self] notification in
                self?.completeDeferredMainWindowReset(notification)
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
            pendingMainWindowLayoutReset = false
            return
        }
        if window.styleMask.contains(.fullScreen) {
            AppWindowLayoutPolicy.prepareForDeferredReset(
                window,
                target: .mainWindow
            )
            pendingMainWindowLayoutReset = true
            return
        }
        pendingMainWindowLayoutReset = false
        AppWindowLayoutPolicy.restoreDefaultLayout(
            window,
            target: .mainWindow
        )
    }

    private func completeDeferredMainWindowReset(
        _ notification: Notification
    ) {
        guard pendingMainWindowLayoutReset,
              let window = notification.object as? NSWindow,
              window.identifier
                == AppWindowLayoutPolicy.descriptor(for: .mainWindow).identifier
        else { return }
        pendingMainWindowLayoutReset = false
        AppWindowLayoutPolicy.restoreDefaultLayout(
            window,
            target: .mainWindow
        )
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

#if DEBUG
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
        if window.styleMask.contains(.fullScreen) {
            hasDeferredLayoutReset = true
            return
        }
        hasDeferredLayoutReset = false
        desiredAspectRatio = currentEffectiveAspectRatio()
        lastAppliedAspectRatio = nil
        scheduleGeometryApplication(immediate: true)
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
            window.toggleFullScreen(nil)
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
        playerContentContainer = window.contentView

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
        scheduleUserFramePersistence(for: resizedWindow)
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === window else { return }
        scheduleUserFramePersistence(for: movedWindow)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        persistUserFrameIfEligible(resizedWindow)
        scheduleGeometryApplication(immediate: true)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let fullScreenWindow = notification.object as? NSWindow,
              fullScreenWindow === window else { return }
        pendingGeometryWorkItem?.cancel()
        pendingGeometryWorkItem = nil
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let exitedWindow = notification.object as? NSWindow,
              exitedWindow === window else { return }
        if hasDeferredLayoutReset {
            hasDeferredLayoutReset = false
            lastAppliedAspectRatio = nil
        }
        scheduleGeometryApplication(immediate: true)
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
        guard !isResettingPreference else { return }
        if let window,
           !window.styleMask.contains(.fullScreen),
           !window.inLiveResize,
           !isClosingWindow {
            preferenceStore.captureModeTransition(
                to: mode,
                currentContentSize: contentSize(of: window)
            )
        }
        lastAppliedAspectRatio = nil
        scheduleGeometryApplication(immediate: true)
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
        guard !window.styleMask.contains(.fullScreen),
              !window.inLiveResize,
              !isClosingWindow else { return }

        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
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
              !window.styleMask.contains(.fullScreen),
              !window.inLiveResize,
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
            window.contentMinSize = NSSize(
                width: CGFloat(
                    PlayerWindowPreferencePolicy.minimumContentWidth
                ),
                height: CGFloat(
                    PlayerWindowPreferencePolicy.minimumContentWidth / ratio
                )
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
              !window.styleMask.contains(.fullScreen),
              !window.inLiveResize else { return false }
        if let lastProgrammaticFrame,
           framesMatch(window.frame, lastProgrammaticFrame) {
            return false
        }
        return true
    }

    private func cancelGeometryWork() {
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
        cancelGeometryWork()
        pendingFocusCommandID = nil
        pendingPresentationCommandID = nil
        hasDeferredLayoutReset = false
        activeGeometryRequestID = nil
        lastAppliedAspectRatio = nil
        appState?.setPlayerWindowKey(false)
        hostingController?.view.removeFromSuperview()
        window?.delegate = nil
        window = nil
        playerContentContainer = nil
        hostingController = nil
        lastProgrammaticFrame = nil
        isApplyingProgrammaticFrame = false
        isClosingWindow = false
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
        window.styleMask.insert(.fullSizeContentView)
        // Keep the full-size titlebar so the Sidebar can extend behind the
        // traffic lights, but let AppKit draw the unified toolbar material.
        // A transparent titlebar exposes scrolled posters underneath the real
        // toolbar controls once the old custom overlay is removed.
        window.titlebarAppearsTransparent = false
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
        window.identifier = descriptor.identifier
        window.contentMinSize = descriptor.minimumContentSize

        guard !isAlreadyConfigured else {
            restoreVisibleFrameIfNeeded(window)
            return
        }

        if !window.setFrameUsingName(descriptor.frameAutosaveName) {
            applyDefaultFrame(window, target: target, animate: false)
        }
        window.setFrameAutosaveName(descriptor.frameAutosaveName)
        restoreVisibleFrameIfNeeded(window)
    }

    @MainActor
    static func restoreDefaultLayout(
        _ window: NSWindow,
        target: AppWindowLayoutTarget
    ) {
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

private struct PlayerPlaybackWindowRoot: View {
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

            if appState.isPlayerPresented {
                PlayerView(
                    playerSnapshotState: appState.playerSnapshotState,
                    onWindowChromeRestored: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 450)
        .background(Color.black)
        .alert(item: $appState.playerPresentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
        .appConfigurationSheet(scope: .player)
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
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) {
                index, section in
                Button(section.rawValue) {
                    state.selectSection(section)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))),
                    modifiers: .command
                )
                .disabled(!state.allowsBrowserShortcuts)
            }

            Divider()

            Button("搜索") {
                state.focusGlobalSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button("快速切换…") {
                state.presentQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button("打开点播配置") {
                state.selectedSettingsPane = .configurations
                state.selectSection(.settings)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Divider()

            Button("刷新当前页面") {
                Task { await state.performContextRefresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button("返回") {
                Task { await state.performBackShortcut() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)

            Button("停止当前操作") {
                state.stopCurrentShortcutOperation()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts || !state.isSearching)

            Divider()

            Button("键盘快捷键") {
                state.presentShortcutHelp()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(!state.allowsBrowserShortcuts)
        }

        CommandMenu("播放") {
            Button("播放/暂停") {
                Task { await state.togglePlayPause() }
            }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button("快退 10 秒") {
                Task { await state.seek(by: -10) }
            }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button("快进 10 秒") {
                Task { await state.seek(by: 10) }
            }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button("快退 30 秒") {
                Task { await state.seek(by: -30) }
            }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )
            Button("快进 30 秒") {
                Task { await state.seek(by: 30) }
            }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSeekPlayback
                )

            Divider()

            Button("上一集") {
                Task { await state.playAdjacentEpisode(offset: -1) }
            }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasPreviousEpisode
                )
            Button("下一集") {
                Task { await state.playAdjacentEpisode(offset: 1) }
            }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasNextEpisode
                )

            Divider()

            Button("上一个直播频道") {
                Task { await state.switchLiveChannel(by: -1) }
            }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSwitchLiveChannel
                )
            Button("下一个直播频道") {
                Task { await state.switchLiveChannel(by: 1) }
            }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.canSwitchLiveChannel
                )

            Divider()

            Button("静音/取消静音") {
                Task { await state.togglePlayerMute() }
            }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button("降低音量") {
                Task { await state.adjustPlayerVolume(by: -5) }
            }
                .keyboardShortcut("-", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button("提高音量") {
                Task { await state.adjustPlayerVolume(by: 5) }
            }
                .keyboardShortcut("=", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)

            Divider()

            Button("字幕开关") {
                Task { await state.togglePlayerSubtitles() }
            }
                .keyboardShortcut("c", modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts
                        || !state.hasPlayerSubtitleTracks
                )
            Button("下一个音轨") {
                Task { await state.cyclePlayerAudioTrack() }
            }
                .keyboardShortcut("a", modifiers: [])
                .disabled(
                    !state.allowsPlayerShortcuts || !state.hasPlayerAudioTracks
                )

            Button("降低播放速度") {
                Task { await state.adjustPlayerSpeed(by: -0.25) }
            }
                .keyboardShortcut(",", modifiers: .shift)
                .disabled(!state.allowsPlayerShortcuts || state.isLivePlayback)
            Button("提高播放速度") {
                Task { await state.adjustPlayerSpeed(by: 0.25) }
            }
                .keyboardShortcut(".", modifiers: .shift)
                .disabled(!state.allowsPlayerShortcuts || state.isLivePlayback)

            Divider()

            Button("进入/退出全屏 (F)") {
                state.togglePlayerFullScreen()
            }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!state.allowsPlayerShortcuts)
            Button("进入/退出全屏") {
                state.togglePlayerFullScreen()
            }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!state.allowsPlayerShortcuts)

            Button("关闭面板或退出全屏") {
                state.requestPlayerEscapeHandling()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(!state.allowsPlayerShortcuts)
        }
    }
}
