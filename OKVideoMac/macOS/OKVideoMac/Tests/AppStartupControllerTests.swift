import AppKit
import SwiftUI
import Foundation
import OKVideoCore
import OKCrashDiagnostics
import XCTest
@testable import OKVideoMac

@MainActor
final class AppStartupControllerTests: XCTestCase {
    private func fixture() throws -> (AppLaunchSession, ReportStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("OKStartupShell-\(UUID().uuidString)")
        let directories=try AppDirectories(applicationSupport:root.appendingPathComponent("Support"),caches:root.appendingPathComponent("Caches"))
        let context=try AppStartupContext.prepare(directories:directories,
            environment:["XCTestBundlePath":"isolated.xctest"],bundleIdentifier:"com.okvideomac.shell-tests",processIdentifier:42)
        let store=try ReportStore(root:root.appendingPathComponent("Reports"))
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return (AppLaunchSession(startup:.success(context),crashManager:nil),store)
    }

    private func addReport(_ store: ReportStore, id:Int=1) throws {
        let json:[String:Any]=[
            "id":String(format:"%032x",id),"timestamp":Date().timeIntervalSinceReferenceDate,
            "version":"0.8.4","build":"137","osVersion":"14.8.9","architecture":"arm64",
            "signal":"SIGTRAP","signalCode":"TRAP_BRKPT",
            "threads":[["number":0,"crashed":true,"frames":[["pc":4294971396,"imageBase":4294967296]]]],
            "images":[["uuid":"12345678-1234-1234-1234-123456789ABC","base":4294967296,"size":8192,"name":"OKVideoMac","vmaddr":4294967296]]
        ]
        try store.save(JSONDecoder().decode(CrashRecord.self,from:JSONSerialization.data(withJSONObject:json)))
    }

    private func settle(_ controller: AppStartupController) async {
        for _ in 0..<20 { if controller.phase != .starting { return };await Task.yield() }
    }

    func testRecoveryDoesNotCreateBusinessUntilExplicitContinue() async throws {
        let (session,store)=try fixture();try addReport(store)
        var starts=0
        let controller=AppStartupController(session:session,store:store,bootstrap:{starts+=1;return AppState(environment:nil)})
        controller.beginIfReady();await Task.yield()
        XCTAssertEqual(controller.phase,.recovery);XCTAssertEqual(starts,0);XCTAssertNil(controller.business)
        XCTAssertFalse(controller.canRunBusinessEvents)
        controller.continueStartup();controller.continueStartup();controller.beginIfReady();await settle(controller)
        XCTAssertEqual(starts,1);XCTAssertEqual(controller.phase,.ready)
        XCTAssertFalse(store.consent);XCTAssertEqual(try store.records().count,1)
    }

    func testAcknowledgedReportDoesNotBlockNextCleanStartup() async throws {
        let (session,store)=try fixture();try addReport(store);try store.acknowledgeRecoveryPrompt()
        var starts=0
        let controller=AppStartupController(session:session,store:store,bootstrap:{starts+=1;return AppState(environment:nil)})
        XCTAssertEqual(controller.phase,.starting)
        controller.beginIfReady();controller.beginIfReady();await settle(controller)
        XCTAssertEqual(starts,1);XCTAssertEqual(controller.phase,.ready)
    }

    func testNewCrashRepromptsAfterAcknowledgedReport() throws {
        let (session,store)=try fixture();try addReport(store);try store.acknowledgeRecoveryPrompt();try addReport(store,id:2)
        let controller=AppStartupController(session:session,store:store,bootstrap:{XCTFail("Business started early");return AppState(environment:nil)})
        XCTAssertEqual(controller.phase,.recovery);XCTAssertEqual(controller.pendingReports,2)
    }

    func testFailedPromptAcknowledgementStillStartsOnlyOnce() async throws {
        let (session,store)=try fixture();try addReport(store)
        try FileManager.default.createDirectory(at:store.root.appendingPathComponent("recovery-prompt.json"),withIntermediateDirectories:false)
        var starts=0
        let controller=AppStartupController(session:session,store:store,bootstrap:{starts+=1;return AppState(environment:nil)})
        controller.continueStartup();controller.continueStartup();await settle(controller)
        XCTAssertEqual(starts,1);XCTAssertTrue(controller.recoveryWarning)
    }

    func testClosingRecoveryNeverCreatesBusinessAndKeepsUnacknowledgedReport() async throws {
        let (session,store)=try fixture();try addReport(store)
        var starts=0
        let controller=AppStartupController(session:session,store:store,bootstrap:{starts+=1;return AppState(environment:nil)})
        controller.requestTermination();controller.continueStartup();controller.beginIfReady();await Task.yield()
        XCTAssertEqual(starts,0);XCTAssertNil(controller.business);XCTAssertTrue(try store.needsRecoveryPrompt())
    }

    func testQuitBeforeScheduledBootstrapCancelsBusinessCreation() async throws {
        let (session,store)=try fixture();var starts=0
        let controller=AppStartupController(session:session,store:store,bootstrap:{starts+=1;return AppState(environment:nil)})
        controller.beginIfReady();controller.requestTermination();await Task.yield()
        XCTAssertEqual(starts,0);XCTAssertEqual(controller.phase,.terminating)
    }

    func testFileOpensStayBoundedBeforeBusinessAndReleaseOnQuit() throws {
        let (session,store)=try fixture();try addReport(store)
        let controller=AppStartupController(session:session,store:store,bootstrap:{XCTFail("File opened before recovery decision");return AppState(environment:nil)})
        for i in 0..<AppStartupController.maximumQueuedFiles { XCTAssertTrue(controller.openFile(URL(fileURLWithPath:"/private/tmp/config-\(i).json"))) }
        XCTAssertFalse(controller.openFile(URL(fileURLWithPath:"/private/tmp/overflow.json")))
        XCTAssertEqual(controller.pendingFileCount,16);XCTAssertNil(controller.business)
        controller.requestTermination();XCTAssertEqual(controller.pendingFileCount,0)
        XCTAssertFalse(controller.openFile(URL(fileURLWithPath:"/private/tmp/late.json")))
    }

    func testPreflightFailureHasNoBusinessAndRejectsFileOpen() throws {
        enum Failed:Error {case preflight}
        var starts=0
        let controller=AppStartupController(session:AppLaunchSession(startup:.failure(Failed.preflight),crashManager:nil),bootstrap:{starts+=1;return AppState(environment:nil)})
        controller.beginIfReady();controller.continueStartup()
        XCTAssertEqual(controller.phase,.failed);XCTAssertEqual(starts,0);XCTAssertNil(controller.business)
        XCTAssertFalse(controller.openFile(URL(fileURLWithPath:"/private/tmp/late.json")))
    }
}

@MainActor
final class StartupPresentationTests: XCTestCase {
    func testLaunchThemeCacheSupportsEveryThemeAndRejectsInvalidValues() throws {
        let name = "com.okvideomac.launch-theme-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppAppearanceController.cachedTheme(defaults: defaults), .system)
        for theme in AppTheme.allCases {
            AppAppearanceController.cache(theme, defaults: defaults)
            XCTAssertEqual(AppAppearanceController.cachedTheme(defaults: defaults), theme)
        }
        defaults.set("invalid", forKey: AppAppearanceController.launchThemeKey)
        XCTAssertEqual(AppAppearanceController.cachedTheme(defaults: defaults), .system)
    }

    func testContentActivityWaitsForGracePeriodAndLeavesWithPlaceholder() async throws {
        let controller = NSHostingController(rootView: AnyView(StartupContentPlaceholder().accentColor(.blue)))
        let host = controller.view
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 600))
        window.orderFront(nil)
        defer { window.close() }
        func render(_ name: String) throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            image.name = "startup-" + name
            image.lifetime = .keepAlways
            add(image)
            // Poster placeholders are neutral gray. The blue activity ring is
            // a visible output of the actual SwiftUI task, independent of the
            // test host's incomplete virtual accessibility tree on macOS 14.
            var bluePixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.blueComponent > color.redComponent + 0.18,
                       color.blueComponent > color.greenComponent + 0.10 {
                        bluePixels += 1
                    }
                }
            }
            return bluePixels
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let early = try render("fast-restore")
        XCTAssertLessThan(early, 3, "Fast startup must not flash the activity ring")
        try await Task.sleep(nanoseconds: 400_000_000)
        let waiting = try render("slow-restore")
        XCTAssertGreaterThan(waiting, 10, "Slow restore must render the activity ring")
        controller.rootView = AnyView(EmptyView())
        let removed = try render("restore-complete")
        XCTAssertLessThan(removed, 3)
        let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject:
            ["earlyBluePixels": early, "waitingBluePixels": waiting, "removedBluePixels": removed],
            options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        metrics.name = "startup-delay-render-result"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    func testStartupToBrowserKeepsWindowGeometryAndOnlyOneSidebarAccessory() async throws {
        let hosting = NSHostingController(rootView: AnyView(AppStartupBrowserShell().ignoresSafeArea()))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let outline = try XCTUnwrap(descendants(hosting.view).compactMap { $0 as? NSOutlineView }.first)
        let search = try XCTUnwrap(descendants(hosting.view).compactMap { $0 as? NSSearchField }.first)
        XCTAssertEqual(outline.numberOfRows, AppSection.allCases.count)
        XCTAssertFalse(outline.isEnabled)
        XCTAssertFalse(search.isEnabled)
        let before = window.frame
        XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is BrowserSidebarTitlebarController }.count, 1)
        let state = AppState(environment: nil)
        hosting.rootView = AnyView(RootView().environmentObject(state).environmentObject(state.navigation))
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(window.frame, before)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is BrowserSidebarTitlebarController }.count, 1)
        let readyOutline = try XCTUnwrap(descendants(hosting.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertTrue(readyOutline.isEnabled)
        hosting.rootView = AnyView(EmptyView())
        for _ in 0..<10 { await Task.yield() }
    }
}
