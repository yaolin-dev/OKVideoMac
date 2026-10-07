import XCTest
import Sparkle
@testable import OKVideoMac

@MainActor
final class AppUpdateTests: XCTestCase {
    func testSparkleOptionalDelegatesHaveTheExactObjectiveCSelectors() {
        let coordinator = AppUpdateCoordinator()
        for selector in ["updaterShouldPromptForPermissionToCheckForUpdates:",
                         "feedURLStringForUpdater:", "updater:mayPerformUpdateCheck:error:",
                         "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:",
                         "updater:willInstallUpdate:"] {
            XCTAssertTrue(coordinator.responds(to: NSSelectorFromString(selector)), selector)
        }
    }
    func testRestartOwnersAreMutuallyExclusiveAndWrongOwnerCannotRelease() {
        let gate = AppRestartGate()
        XCTAssertTrue(gate.claim(.update))
        XCTAssertFalse(gate.claim(.application))
        gate.release(.application)
        XCTAssertEqual(gate.owner, .update)
        gate.release(.update)
        XCTAssertTrue(gate.claim(.application))
        XCTAssertFalse(gate.claim(.update))
    }

    func testRelaunchDoesNotArmHelperWhileUpdaterOwnsRestart() async {
        let gate = AppRestartGate()
        let helper = Helper()
        XCTAssertTrue(gate.claim(.update))
        let coordinator = coordinator(gate, helper)
        do { try await coordinator.restartApplication(); XCTFail("Must reject competing restart") }
        catch { XCTAssertEqual(error as? AppRelaunchError, .updateInProgress) }
        XCTAssertEqual(helper.calls, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testFailedHelperReleasesOwnershipButArmedHelperRetainsIt() async throws {
        let gate = AppRestartGate()
        let helper = Helper()
        helper.fail = true
        let coordinator = coordinator(gate, helper)
        do { try await coordinator.restartApplication(); XCTFail("Expected helper failure") } catch {}
        XCTAssertNil(gate.owner)
        helper.fail = false
        try await coordinator.restartApplication()
        XCTAssertEqual(gate.owner, .application)
        XCTAssertFalse(gate.claim(.update))
    }

    func testConsentAndScheduledReminderWaitForEveryPresentationCondition() {
        let safe = AppUpdatePresentationContext(startupCompleted: true, playerPresented: false,
            applicationActive: true, modalPresented: false, fullScreen: false)
        XCTAssertTrue(safe.allowsUnsolicitedPresentation)
        var value = safe; value.startupCompleted = false; XCTAssertFalse(value.allowsUnsolicitedPresentation)
        value = safe; value.playerPresented = true; XCTAssertFalse(value.allowsUnsolicitedPresentation)
        value = safe; value.applicationActive = false; XCTAssertFalse(value.allowsUnsolicitedPresentation)
        value = safe; value.modalPresented = true; XCTAssertFalse(value.allowsUnsolicitedPresentation)
        value = safe; value.fullScreen = true; XCTAssertFalse(value.allowsUnsolicitedPresentation)
    }

    func testUpdateCannotUseNormalQuitTimeoutOrQuitBeforeInstallChoice() {
        XCTAssertTrue(AppUpdateTerminationPolicy.normal.permitsTermination)
        XCTAssertTrue(AppUpdateTerminationPolicy.normal.permitsTimeoutFallback)
        XCTAssertFalse(AppUpdateTerminationPolicy.awaitingInstallationChoice.permitsTermination)
        XCTAssertTrue(AppUpdateTerminationPolicy.installing.permitsTermination)
        XCTAssertFalse(AppUpdateTerminationPolicy.installing.permitsTimeoutFallback)
    }

    func testPostponedStagedInstallationReallyCancelsInstallOnQuit() {
        XCTAssertEqual(AppUpdateUserDriver.choice(.dismiss, staged: true), .skip)
        XCTAssertEqual(AppUpdateUserDriver.choice(.dismiss, staged: false), .dismiss)
        XCTAssertEqual(AppUpdateUserDriver.choice(.install, staged: true), .install)
    }

    func testProductionRejectsHTTPAndTestChannelRejectsNonLoopback() {
        var info: [String: Any] = ["SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
                                  "OKUpdateChannel": "stable", "SUFeedURL": "https://example.org/appcast.xml"]
        XCTAssertNotNil(AppUpdateConfiguration(info: info))
        info["SUFeedURL"] = "http://example.org/appcast.xml"
        XCTAssertNil(AppUpdateConfiguration(info: info))
        info["OKUpdateChannel"] = "local-test"
        XCTAssertNil(AppUpdateConfiguration(info: info))
        info["SUFeedURL"] = "http://127.0.0.1:38473/appcast.xml"
        XCTAssertNotNil(AppUpdateConfiguration(info: info))
        info["SUPublicEDKey"] = "invalid"
        XCTAssertNil(AppUpdateConfiguration(info: info))
    }

    private func coordinator(_ gate: AppRestartGate, _ helper: Helper) -> AppRelaunchCoordinator {
        AppRelaunchCoordinator(helperLauncher: helper,
            bundleURLProvider: { URL(fileURLWithPath: "/Applications/OKVideoMac.app") },
            bundleIdentifierProvider: { "com.okvideomac.test" }, terminationRequest: {},
            terminationScheduler: Scheduler(), restartGate: gate)
    }
    private final class Helper: AppRelaunchHelperLaunching {
        var calls = 0
        var fail = false
        func prepareRelaunch(_ request: AppRelaunchRequest) async throws {
            calls += 1
            if fail { throw AppRelaunchError.helperLaunchFailed }
        }
    }
    private struct Scheduler: AppTerminationRequestScheduling {
        func schedule(_ request: @escaping @MainActor () -> Void) {}
    }
}
