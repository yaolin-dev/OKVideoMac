import AppKit
import Foundation
import Sparkle

// Test-only driver: supplies scripted user choices while using the unmodified
// Sparkle download, signature verification, installer and relaunch machinery.
@MainActor
enum ProbeLog {
    static var root: URL {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "OKUpdateProbeRoot") as? String,
              path.hasPrefix("/private/tmp/OKVideoMac-SparkleStage2-"),
              Bundle.main.bundleIdentifier?.hasPrefix("com.okvideomac.") == true else {
            fatalError("This probe requires an explicitly isolated fixture bundle")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String }
    static var scenario: String { Bundle.main.object(forInfoDictionaryKey: "OKUpdateProbeScenario") as? String ?? "normal" }
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["version"] = version
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
        let fd = open(root.appendingPathComponent("events.jsonl").path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        precondition(fd >= 0)
        data.withUnsafeBytes { bytes in precondition(write(fd, bytes.baseAddress, bytes.count) == bytes.count) }
        fsync(fd)
        close(fd)
    }
}

@MainActor
final class ProbeDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    var updater: SPUUpdater!
    var beforeInstall: (() -> Bool)?
    var didCancelOrFail: (() -> Void)?
    func start() {
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            ProbeLog.record("updater_started")
            updater.checkForUpdates()
        } catch { ProbeLog.record("updater_start_failed", ["error": String(describing: error)]) }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        ProbeLog.record("permission_request")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { ProbeLog.record("check_started") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ProbeLog.record("update_found", ["target": appcastItem.versionString])
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { ProbeLog.record("release_notes_received") }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { ProbeLog.record("release_notes_failed", ["error": String(describing: error)]) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        ProbeLog.record("update_not_found", ["error": String(describing: error)])
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        ProbeLog.record("update_error", ["error": String(describing: error)])
        didCancelOrFail?()
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        ProbeLog.record("download_started")
        if ProbeLog.scenario == "cancel-download" {
            cancellation()
            didCancelOrFail?()
            ProbeLog.record("download_cancelled")
        }
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { ProbeLog.record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ProbeLog.record("ready_to_install")
        if ProbeLog.scenario == "cancel-install" || beforeInstall?() == false {
            reply(.skip) // Dismiss can still install on quit. Skip cancels this staged installation.
            didCancelOrFail?()
            ProbeLog.record("install_cancelled")
        } else {
            ProbeLog.record("install_confirmed")
            reply(.install)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        ProbeLog.record("installing", ["applicationTerminated": applicationTerminated])
        if ProbeLog.scenario == "cancel-termination-once", !applicationTerminated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                ProbeLog.record("retry_termination")
                retryTerminatingApplication()
            }
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        ProbeLog.record("installed", ["relaunched": relaunched]); acknowledgement()
    }
    func dismissUpdateInstallation() { ProbeLog.record("dismissed") }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { ProbeLog.record("will_install") }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { ProbeLog.record("will_relaunch") }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        ProbeLog.record("update_aborted", ["error": String(describing: error)])
        didCancelOrFail?()
    }
}
