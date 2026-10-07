import AppKit
import Sparkle

/// Keep Sparkle's native UI, deferring consent until the app is ready and
/// turning a postponed staged install into an actual cancellation.
@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    let standard: SPUStandardUserDriver
    var canPresentPermission: () -> Bool = { false }
    var downloadChosen: () -> Void = {}
    var installChosen: () -> Void = {}
    private var pendingPermission: (() -> Void)?

    init(standard: SPUStandardUserDriver) { self.standard = standard }

    func presentPendingPermissionIfSafe() {
        guard canPresentPermission(), let pending = pendingPermission else { return }
        pendingPermission = nil
        pending()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        pendingPermission = { [standard] in
            standard.show(request, reply: { response in
                reply(SUUpdatePermissionResponse(
                    automaticUpdateChecks: response.automaticUpdateChecks,
                    automaticUpdateDownloading: false, sendSystemProfile: false))
            })
        }
        presentPendingPermissionIfSafe()
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.showUpdateFound(with: item, state: state) { [weak self] choice in
            if choice == .install && !item.isInformationOnlyUpdate {
                if state.stage == .installing { self?.installChosen() }
                else { self?.downloadChosen() }
            }
            reply(Self.choice(choice, staged: state.stage == .installing))
        }
    }
    static func choice(_ choice: SPUUserUpdateChoice, staged: Bool) -> SPUUserUpdateChoice {
        staged && choice == .dismiss ? .skip : choice
    }
    func showUpdateReleaseNotes(with data: SPUDownloadData) { standard.showUpdateReleaseNotes(with: data) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(length) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.showReady { [weak self] choice in
            if choice == .install { self?.installChosen() }
            reply(Self.choice(choice, staged: true))
        }
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
    func showUpdateInFocus() {
        // An explicit menu action may focus existing update UI, but may not
        // force an unanswered automatic-check permission over playback.
        guard pendingPermission == nil else { presentPendingPermissionIfSafe(); return }
        standard.showUpdateInFocus()
    }
}
