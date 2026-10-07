import AppKit
import Foundation
import OKVideoCore

@MainActor
enum ProductionProbe {
    static var started = false
    static func directories() throws -> AppDirectories {
        try AppDirectories(applicationSupport: ProbeLog.root.appendingPathComponent("Data/Support"),
                           caches: ProbeLog.root.appendingPathComponent("Data/Caches"))
    }
    static func run(_ state: AppState) async {
        guard !started else { return }
        started = true
        ProbeLog.record("launched", ["executable": Bundle.main.executablePath!, "productionUpdater": true])
        do {
            if ProbeLog.version == "2" {
                let records = try await state.updateProbeHistory()
                ProbeLog.record("new_version_verified", ["historyCount": records.count,
                    "savedPosition": records.first?.position ?? 0])
                MainRunLoopAppTerminationRequestScheduler().schedule { NSApp.terminate(nil) }
                return
            }
            try await verifyGate()
            try await state.updateProbePreparePlayback()
            AppUpdateCoordinator.shared.updateProbeStart()
        } catch {
            ProbeLog.record("fixture_failed", ["error": String(describing: error)])
        }
    }
    static func verifyGate() async throws {
        let gate = AppRestartGate()
        let helper = HeldHelper()
        let scheduler = HeldScheduler()
        let coordinator = AppRelaunchCoordinator(helperLauncher: helper,
            terminationRequest: { preconditionFailure("Gate fixture must not quit") },
            terminationScheduler: scheduler, restartGate: gate)
        precondition(gate.claim(.update))
        do { try await coordinator.restartApplication(); preconditionFailure("Competing restart admitted") }
        catch AppRelaunchError.updateInProgress {}
        precondition(helper.calls == 0)
        gate.release(.update)
        let failed = Task { try await coordinator.restartApplication() }
        while helper.calls == 0 { await Task.yield() }
        precondition(!gate.claim(.update))
        helper.finish(failed: true)
        do { try await failed.value; preconditionFailure("Expected helper failure") }
        catch AppRelaunchError.helperLaunchFailed {}
        precondition(gate.owner == nil)
        let success = Task { try await coordinator.restartApplication() }
        while helper.calls < 2 { await Task.yield() }
        helper.finish(failed: false)
        try await success.value
        precondition(scheduler.calls == 1 && !gate.claim(.update))
        ProbeLog.record("restart_exclusion_verified", ["bothDirections": true, "productionGate": true])
    }
}

@MainActor
private final class HeldHelper: AppRelaunchHelperLaunching {
    var calls = 0
    var continuation: CheckedContinuation<Void, Error>?
    func prepareRelaunch(_ request: AppRelaunchRequest) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(failed: Bool) {
        let c = continuation!; continuation = nil
        if failed { c.resume(throwing: AppRelaunchError.helperLaunchFailed) }
        else { c.resume() }
    }
}

@MainActor
private final class HeldScheduler: AppTerminationRequestScheduling {
    var calls = 0
    func schedule(_ request: @escaping @MainActor () -> Void) { calls += 1 }
}
