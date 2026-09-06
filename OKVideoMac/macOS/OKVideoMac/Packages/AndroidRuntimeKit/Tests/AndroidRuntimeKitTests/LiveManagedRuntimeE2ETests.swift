import Foundation
import XCTest
@testable import AndroidRuntimeKit

/// Opt-in because it downloads the complete, immutable production profile.
/// The normal suite skips it; release validation runs it with an isolated
/// Application Support path and retains that generation for the Emulator
/// Candidate Matrix lifecycle run.
final class LiveManagedRuntimeE2ETests: XCTestCase {
    func testProductionCatalogInstallsIntoAnEmptyManagedRoot() async throws {
        guard let supportPath = ProcessInfo.processInfo.environment[
            "OKVIDEOMAC_MANAGED_RUNTIME_E2E_SUPPORT"
        ], supportPath.hasPrefix("/tmp/") else {
            throw XCTSkip(
                "Set OKVIDEOMAC_MANAGED_RUNTIME_E2E_SUPPORT to an isolated /tmp path"
            )
        }
        let support = URL(
            fileURLWithPath: supportPath,
            isDirectory: true
        ).standardizedFileURL
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: support
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.currentRuntimePointer.path
        ))
        let catalog = try BundledRuntimeCatalog.load()
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: catalog,
            downloader: URLSessionRuntimeArtifactDownloader(
                allowedHosts: Set(catalog.allowedDownloadHosts ?? [])
            ),
            currentAppVersion: "0.4.2"
        )
        let observer = Task {
            let states = await manager.states()
            for await state in states {
                print("MANAGED_RUNTIME_E2E_STATE \(Self.describe(state))")
            }
        }
        defer { observer.cancel() }

        let detected = try await manager.refresh()
        XCTAssertEqual(detected, .notInstalled)
        try await manager.presentInstallOffer()
        try await manager.installDefault(acceptingLicenses: true)

        let selection = try ManagedRuntimeSelection.resolve(
            layout: layout,
            catalog: catalog
        )
        XCTAssertTrue(selection.purity.passed)
        XCTAssertEqual(
            selection.generationID,
            catalog.defaultProfile?.generationID
        )
        print("MANAGED_RUNTIME_E2E_GENERATION \(selection.generationID.rawValue)")
        print("MANAGED_RUNTIME_E2E_SDK \(selection.sdkRoot.path)")
        print("MANAGED_RUNTIME_E2E_JRE \(selection.javaHome.path)")
    }

    private static func describe(
        _ state: ManagedRuntimeInstallationState
    ) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .detecting: return "detecting"
        case .available(let offer):
            return "available bytes=\(offer.downloadBytes)"
        case .preparing: return "preparing"
        case .downloading(let detail):
            return "downloading component=\(detail.componentID ?? "none") bytes=\(detail.completedBytes + detail.receivedBytes)/\(detail.totalBytes)"
        case .verifying(let detail):
            return "verifying component=\(detail.componentID ?? "none")"
        case .extracting(let detail):
            return "extracting component=\(detail.componentID ?? "none")"
        case .installing: return "installing"
        case .validating: return "validating"
        case .activating: return "activating"
        case .ready(let ready):
            return "ready generation=\(ready.generationID.rawValue)"
        case .updateAvailable: return "updateAvailable"
        case .cancelling: return "cancelling"
        case .cancelled: return "cancelled"
        case .repairing: return "repairing"
        case .damaged: return "damaged"
        case .incompatible: return "incompatible"
        case .failed(let failure, _):
            return "failed code=\(failure.diagnosticCode)"
        }
    }
}
