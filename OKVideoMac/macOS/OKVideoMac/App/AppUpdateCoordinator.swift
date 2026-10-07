import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdateCoordinator()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var configurationError: String?
    private(set) var terminationPolicy: AppUpdateTerminationPolicy = .normal
    let configuration = AppUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])
    private let gate = AppRestartGate.shared
    private weak var appState: AppState?
    private var timer: AnyCancellable?
    private var observations: [NSKeyValueObservation] = []
    private var updater: SPUUpdater?
    private var driver: AppUpdateUserDriver?

    var context: AppUpdatePresentationContext {
        AppUpdatePresentationContext(
            startupCompleted: appState?.hasCompletedStartup == true,
            playerPresented: appState?.isPlayerPresented == true,
            applicationActive: NSApp.isActive,
            modalPresented: NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil },
            fullScreen: NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.fullScreen) })
    }

    func install(appState: AppState) {
        self.appState = appState
        guard timer == nil, configuration != nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshPresentation() }
        refreshPresentation()
    }

    private func refreshPresentation() {
        if updater == nil && context.allowsUnsolicitedPresentation { start() }
        driver?.presentPendingPermissionIfSafe()
        canCheckForUpdates = updater?.canCheckForUpdates == true && gate.owner != .application
    }

    private func start() {
        guard configuration != nil, updater == nil else { return }
        let standard = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let driver = AppUpdateUserDriver(standard: standard)
        driver.canPresentPermission = { [weak self] in self?.context.allowsUnsolicitedPresentation == true }
        driver.downloadChosen = { [weak self] in self?.terminationPolicy = .awaitingInstallationChoice }
        driver.installChosen = { [weak self] in self?.terminationPolicy = .installing }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.driver = driver
        self.updater = updater
        do { try updater.start() }
        catch { configurationError = error.localizedDescription; return }
        updater.sendsSystemProfile = false
        updater.automaticallyDownloadsUpdates = false
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                Task { @MainActor [weak self] in self?.refreshPresentation() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                let enabled = value.automaticallyChecksForUpdates
                Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = enabled }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] value, _ in
                let date = value.lastUpdateCheckDate
                Task { @MainActor [weak self] in self?.lastCheckDate = date }
            }
        ]
    }

    func checkForUpdates() { guard canCheckForUpdates else { return }; updater?.checkForUpdates() }
    func setAutomaticChecks(_ enabled: Bool) { updater?.automaticallyChecksForUpdates = enabled }
    func focusInstallationChoice() { driver?.showUpdateInFocus() }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { true }
    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let configuration else { throw URLError(.badURL) }
        let urls = [item.fileURL, item.releaseNotesURL, item.infoURL].compactMap { $0 }
        for url in urls {
            let allowed = configuration.channel == "stable"
                ? url.scheme == "https"
                : url.scheme == "http" && url.host == "127.0.0.1" && url.port == configuration.feedURL.port
            guard allowed, url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard gate.claim(.update) else {
            throw NSError(domain: "OKVideoMac.Updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.string("updates.check-busy", fallback: "Finish the current restart before checking for updates.")])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        terminationPolicy = .installing
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Do not surrender restart ownership after the installer is armed.
        if terminationPolicy != .installing || error != nil {
            terminationPolicy = .normal
            gate.release(.update)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        context.allowsUnsolicitedPresentation && immediateFocus
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { availableVersion = nil }
    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil }
}
