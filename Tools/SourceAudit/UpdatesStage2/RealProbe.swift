import AppKit
import Foundation
import OKVideoCore

// Stage 2 prototype only. instrument.py copies it into a disposable Release
// build; the production target does not compile or link any updater code.
@MainActor
enum RealProbe {
    static var started = false
    static let driver = ProbeDriver()

    static func directories() throws -> AppDirectories {
        try AppDirectories(applicationSupport: ProbeLog.root.appendingPathComponent("Data/Support"),
                           caches: ProbeLog.root.appendingPathComponent("Data/Caches"))
    }

    static func run(_ state: AppState) async {
        guard !started else { return }
        started = true
        ProbeLog.record("launched", ["executable": Bundle.main.executablePath!, "realAppState": true])
        do {
            if ProbeLog.version == "2" {
                let records = try await state.updateProbeHistory()
                let position = records.first?.position ?? 0
                ProbeLog.record("new_version_verified", ["historyCount": records.count, "savedPosition": position])
                MainRunLoopAppTerminationRequestScheduler().schedule { NSApp.terminate(nil) }
                return
            }
            try await ProbeRestartGate.verifyWithRealCoordinator()
            try await state.updateProbePreparePlayback()
            driver.beforeInstall = {
                let admitted = ProbeRestartGate.claimUpdate()
                ProbeLog.record("update_restart_admission", ["admitted": admitted])
                return admitted
            }
            driver.didCancelOrFail = { ProbeRestartGate.releaseUpdate() }
            driver.start()
        } catch {
            ProbeLog.record("fixture_failed", ["error": String(describing: error)])
        }
    }
}

@MainActor
enum ProbeRestartGate {
    static var owner: String?
    static func claimUpdate() -> Bool { claim("sparkle") }
    static func releaseUpdate() { release("sparkle") }
    static func claim(_ candidate: String) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }
    static func release(_ candidate: String) {
        if owner == candidate { owner = nil }
    }

    static func verifyWithRealCoordinator() async throws {
        let helper = ProbeHeldHelper()
        let scheduler = ProbeNoTerminationScheduler()
        let coordinator = AppRelaunchCoordinator(helperLauncher: helper, terminationRequest: {
            preconditionFailure("A gate test must never terminate the App")
        }, terminationScheduler: scheduler)
        precondition(claimUpdate())
        do {
            try await coordinator.restartApplication()
            preconditionFailure("Normal relaunch was admitted during update installation")
        } catch AppRelaunchError.updateInstallationInProgress {}
        precondition(helper.calls == 0 && coordinator.state == .idle)
        releaseUpdate()
        let attempt = Task { try await coordinator.restartApplication() }
        while helper.calls == 0 { await Task.yield() }
        precondition(!claimUpdate(), "Sparkle must not race a preparing relaunch helper")
        helper.finish(throwing: true)
        do { try await attempt.value; preconditionFailure("Expected helper failure") }
        catch AppRelaunchError.helperLaunchFailed {}
        precondition(owner == nil && coordinator.state == .idle)
        precondition(claimUpdate()); releaseUpdate()
        let successful = Task { try await coordinator.restartApplication() }
        while helper.calls != 2 { await Task.yield() }
        helper.finish(throwing: false)
        try await successful.value
        precondition(coordinator.state == .terminationRequested && scheduler.calls == 1)
        precondition(!claimUpdate(), "Sparkle must not race an armed relaunch helper")
        // This helper is a deterministic test double and has not spawned a PID.
        release(String(describing: ObjectIdentifier(coordinator)))
        ProbeLog.record("restart_exclusion_verified", ["bothDirections": true, "failureReleasesAdmission": true])
    }
}

@MainActor
private final class ProbeHeldHelper: AppRelaunchHelperLaunching {
    var calls = 0
    var continuation: CheckedContinuation<Void, Error>?
    func prepareRelaunch(_ request: AppRelaunchRequest) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(throwing failed: Bool) {
        let c = continuation!; continuation = nil
        if failed { c.resume(throwing: AppRelaunchError.helperLaunchFailed) }
        else { c.resume() }
    }
}

@MainActor
private final class ProbeNoTerminationScheduler: AppTerminationRequestScheduling {
    var calls = 0
    func schedule(_ request: @escaping @MainActor () -> Void) { calls += 1 }
}
