import CryptoKit
import Foundation
import XCTest
@testable import AndroidRuntimeKit

final class ManagedRuntimeProductTests: XCTestCase {
    func testProductionCatalogPinsTheVerifiedAPI35Profile() throws {
        let catalog = try BundledRuntimeCatalog.load()
        let profile = try XCTUnwrap(catalog.defaultProfile)
        let generation = try XCTUnwrap(catalog.generations.first(where: {
            $0.generationID == profile.generationID
        }))

        XCTAssertEqual(profile.id, "default-api35-arm64")
        XCTAssertEqual(profile.minimumAppVersion, "0.5.0")
        XCTAssertEqual(profile.minimumMacOS, "12.0")
        XCTAssertEqual(profile.architectures, [.arm64])
        XCTAssertEqual(generation.apiLevel, 35)
        XCTAssertEqual(
            generation.systemImagePackageID,
            "system-images;android-35;google_apis;arm64-v8a"
        )
        XCTAssertEqual(generation.bridgeVersion, "0.3.44 (56)")
        XCTAssertEqual(generation.components.count, 6)
        XCTAssertTrue(generation.components.allSatisfy {
            $0.downloadURL.scheme == "https"
                && $0.sha256.count == 64
                && $0.compressedSize > 0
                && $0.installedSize > 0
                && $0.installation != nil
        })
        XCTAssertEqual(
            Set(generation.components.map { $0.downloadURL.host! }),
            Set(["dl.google.com", "cdn.azul.com"])
        )
    }

    func testManagedAVDCompatibilityReusesAcrossToolsOnlyGeneration()
        throws {
        let generation = try XCTUnwrap(
            ProductFixture().catalog().generations.first
        )
        let manifest = ManagedAVDManifest(
            avdSchema: generation.avdSchema,
            bridgeSchema: generation.bridgeSchema,
            runtimeGenerationID: RuntimeGenerationID(rawValue: "r0-tools"),
            systemImageComponentID: "system-image",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            ManagedAVDCompatibility.evaluate(
                hasExistingAVD: true,
                manifest: manifest,
                expectedGeneration: generation,
                expectedSystemImageComponentID: "system-image",
                configurationMatchesExpectedImage: true
            ).status,
            .refreshMetadata
        )
        XCTAssertEqual(
            ManagedAVDCompatibility.evaluate(
                hasExistingAVD: true,
                manifest: nil,
                expectedGeneration: generation,
                expectedSystemImageComponentID: "system-image",
                configurationMatchesExpectedImage: true
            ).status,
            .adopt
        )
        XCTAssertEqual(
            ManagedAVDCompatibility.evaluate(
                hasExistingAVD: false,
                manifest: nil,
                expectedGeneration: generation,
                expectedSystemImageComponentID: "system-image",
                configurationMatchesExpectedImage: false
            ).status,
            .create
        )
    }

    func testManagedAVDCompatibilityNeverSilentlyChangesUserdataImage()
        throws {
        let generation = try XCTUnwrap(
            ProductFixture().catalog().generations.first
        )
        let wrongSchema = ManagedAVDManifest(
            avdSchema: generation.avdSchema + 1,
            bridgeSchema: generation.bridgeSchema,
            runtimeGenerationID: generation.generationID,
            systemImageComponentID: "system-image",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            ManagedAVDCompatibility.evaluate(
                hasExistingAVD: true,
                manifest: wrongSchema,
                expectedGeneration: generation,
                expectedSystemImageComponentID: "system-image",
                configurationMatchesExpectedImage: true
            ).status,
            .requiresRecoverableRebuild
        )
        XCTAssertEqual(
            ManagedAVDCompatibility.evaluate(
                hasExistingAVD: true,
                manifest: nil,
                expectedGeneration: generation,
                expectedSystemImageComponentID: "system-image",
                configurationMatchesExpectedImage: false
            ).status,
            .requiresRecoverableRebuild
        )
    }

    func testProductStatesExposeOnlyRealDownloadProgress() {
        let generation = RuntimeGenerationID(rawValue: "r1-product-fixture")
        let detail = ManagedRuntimeProgressDetail(RuntimeInstallationProgress(
            phase: .downloading,
            generationID: generation,
            receivedBytes: 25,
            componentBytes: 100,
            completedBytes: 25,
            totalBytes: 100
        ))

        XCTAssertEqual(
            ManagedRuntimeInstallationState.downloading(detail).progress,
            0.5
        )
        XCTAssertTrue(
            ManagedRuntimeInstallationState.downloading(detail).isBusy
        )
        XCTAssertNil(
            ManagedRuntimeInstallationState.verifying(detail).progress
        )
        XCTAssertTrue(
            ManagedRuntimeInstallationState.cancelling.isBusy
        )
        XCTAssertFalse(
            ManagedRuntimeInstallationState.notInstalled.isBusy
        )
        XCTAssertEqual(
            ManagedRuntimeInstallationState.ready(ManagedRuntimeReadyState(
                generationID: generation,
                profileID: "default-product-fixture"
            )).progress,
            1
        )
    }

    func testCatalogRejectsNonAllowlistedHostAndDownloadSizeDrift() {
        var fixture = ProductFixture()
        fixture.componentHost = "downloads.example.net"
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))

        fixture = ProductFixture()
        fixture.profileDownloadSizeAdjustment = 1
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))
    }

    func testCatalogRejectsBadSHAURLDuplicateAndTraversal() {
        var fixture = ProductFixture()
        fixture.invalidSHA = true
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))

        fixture = ProductFixture()
        fixture.useHTTP = true
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))

        fixture = ProductFixture()
        fixture.duplicateComponent = true
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))

        fixture = ProductFixture()
        fixture.traversingDestination = true
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            fixture.catalog()
        ))
    }

    func testManagerRejectsAnUnsupportedAppVersionBeforeDownloading()
        async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = ProductCounter()
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: root,
            catalog: ProductFixture().catalog(),
            downloader: ProductDownloader(counter: counter),
            currentAppVersion: "0.4.1",
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: ProductCounter())
        )

        do {
            try await manager.presentInstallOffer()
            XCTFail("Expected the minimum App version gate to reject")
        } catch let error as ManagedRuntimeProductError {
            guard case .profileUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let downloadCount = await counter.current()
        XCTAssertEqual(downloadCount, 0)
    }

    func testTenDexRequestsResumeAfterOneProductInstallation() async throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let downloads = ProductCounter()
        let validations = ProductCounter()
        let catalog = ProductFixture().catalog()
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: catalog,
            downloader: ProductDownloader(counter: downloads),
            currentAppVersion: "0.4.2",
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: validations)
        )
        let requests = (0..<10).map { _ in
            Task { try await manager.ensureReadyForDex() }
        }
        try await waitUntil {
            if case .available = await manager.currentState() { return true }
            return false
        }

        try await manager.installDefault(acceptingLicenses: true)
        for request in requests { try await request.value }

        let generation = try XCTUnwrap(catalog.defaultProfile?.generationID)
        let downloadCount = await downloads.current()
        let validationCount = await validations.current()
        XCTAssertEqual(downloadCount, catalog.generations[0].components.count)
        XCTAssertEqual(validationCount, 1)
        XCTAssertEqual(
            AndroidRuntimeDetector(
                layout: AndroidRuntimeLayout(
                    applicationSupportDirectory: support
                )
            ).detect(catalog: catalog).activeGenerationID,
            generation
        )
        if case .ready(let ready) = await manager.currentState() {
            XCTAssertEqual(ready.generationID, generation)
        } else {
            XCTFail("Expected the joined installation to publish ready")
        }
    }

    func testInstallerSynthesizesPinnedEmulatorPackageMetadata()
        async throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let catalog = ProductFixture().catalog()
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: catalog,
            downloader: ProductDownloader(counter: ProductCounter()),
            currentAppVersion: "0.4.2",
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: ProductCounter())
        )

        try await manager.installDefault(acceptingLicenses: true)

        let generationID = try XCTUnwrap(catalog.defaultProfile?.generationID)
        let packageXML = AndroidRuntimeLayout(
            applicationSupportDirectory: support
        ).generation(generationID).sdk.appendingPathComponent(
            "emulator/package.xml"
        )
        let contents = try String(contentsOf: packageXML, encoding: .utf8)
        XCTAssertTrue(contents.contains("localPackage path=\"emulator\""))
        XCTAssertTrue(contents.contains("<major>1</major>"))
    }

    func testDecliningOfferCancelsEverySuspendedDexRequest() async throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: ProductFixture().catalog(),
            downloader: ProductDownloader(counter: ProductCounter()),
            currentAppVersion: "0.4.2",
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: ProductCounter())
        )
        let requests = (0..<3).map { _ in
            Task { try await manager.ensureReadyForDex() }
        }
        try await waitUntil {
            if case .available = await manager.currentState() { return true }
            return false
        }

        await manager.cancel()

        for request in requests {
            do {
                try await request.value
                XCTFail("Expected the suspended Dex request to be cancelled")
            } catch let error as ManagedRuntimeProductError {
                XCTAssertEqual(error, .installationCancelled)
            }
        }
        if case .cancelled = await manager.currentState() {
            // Expected.
        } else {
            XCTFail("Expected cancelled product state")
        }
    }

    func testRetryUsesThePreservedPartialDownload() async throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let catalog = ProductFixture().catalog()
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: support
        )
        let downloader = ResumingProductDownloader()
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: downloader,
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: ProductCounter())
        )
        let generation = try XCTUnwrap(catalog.defaultProfile?.generationID)

        do {
            _ = try await installer.install(generationID: generation)
            XCTFail("The first network attempt must fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: layout.currentRuntimePointer.path
            ))
        }

        _ = try await installer.install(generationID: generation)

        let resumeOffset = await downloader.resumeOffset()
        XCTAssertGreaterThan(resumeOffset, 0)
        XCTAssertEqual(
            AndroidRuntimeDetector(layout: layout).detect(catalog: catalog)
                .status,
            .ready
        )
    }

    func testFailedRepairRestoresGenerationPointerAndAVDUserdata()
        async throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let catalog = ProductFixture().catalog()
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: catalog,
            downloader: ProductDownloader(counter: ProductCounter()),
            currentAppVersion: "0.4.2",
            materializer: ProductMaterializer(),
            validator: ProductValidator(counter: ProductCounter())
        )
        try await manager.installDefault(acceptingLicenses: true)
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: support
        )
        try FileManager.default.createDirectory(
            at: layout.avdDirectory,
            withIntermediateDirectories: true
        )
        let userdata = layout.avdDirectory.appendingPathComponent("userdata.img")
        try Data("preserve-me".utf8).write(to: userdata)
        let previousPointer = try Data(contentsOf: layout.currentRuntimePointer)
        let failing = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: catalog,
            downloader: ProductDownloader(counter: ProductCounter()),
            currentAppVersion: "0.4.2",
            materializer: ProductMaterializer(),
            validator: FailingProductValidator()
        )

        do {
            try await failing.repair(acceptingLicenses: true)
            XCTFail("Expected repair validation failure")
        } catch {
            XCTAssertEqual(
                try Data(contentsOf: layout.currentRuntimePointer),
                previousPointer
            )
            XCTAssertEqual(
                try String(contentsOf: userdata, encoding: .utf8),
                "preserve-me"
            )
            XCTAssertEqual(
                AndroidRuntimeDetector(layout: layout)
                    .detect(catalog: catalog).status,
                .ready
            )
        }
    }

    func testManagedDiagnosticsArePathFreeAndContainNoSecrets() async throws {
        let support = URL(fileURLWithPath: "/Users/private-user/Library/Application Support/OKVideoMac")
        let manager = AndroidManagedRuntimeManager(
            applicationSupportDirectory: support,
            catalog: ProductFixture().catalog(),
            downloader: ProductDownloader(counter: ProductCounter()),
            currentAppVersion: "0.4.2"
        )
        let data = try JSONEncoder().encode(await manager.diagnosticReport())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("private-user"))
        XCTAssertFalse(text.lowercased().contains("adbkey"))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManagedRuntimeProductTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for state")
    }
}

private struct ProductFixture {
    var componentHost = "downloads.example.com"
    var profileDownloadSizeAdjustment: Int64 = 0
    var invalidSHA = false
    var useHTTP = false
    var duplicateComponent = false
    var traversingDestination = false

    func catalog() -> RuntimeCatalog {
        let generationID = RuntimeGenerationID(rawValue: "r1-product-fixture")
        var components = componentDefinitions.map { id, role in
            component(id: id, role: role)
        }
        if duplicateComponent, let first = components.first {
            components.append(first)
        }
        let generation = RuntimeGenerationDescriptor(
            generationID: generationID,
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            minimumAppVersion: "0.4.2",
            architecture: .arm64,
            components: components,
            apiLevel: 35,
            systemImagePackageID:
                "system-images;android-35;google_apis;arm64-v8a",
            bridgeVersion: "0.3.44 (56)"
        )
        let size = components.reduce(Int64(0)) { $0 + $1.compressedSize }
        let profile = RuntimeProfile(
            id: "default-product-fixture",
            displayName: "Android 兼容组件测试环境",
            status: .defaultProfile,
            generationID: generationID,
            expectedDownloadSize: size + profileDownloadSizeAdjustment,
            requiredFreeSpace: max(1_000_000, size * 5),
            minimumAppVersion: "0.4.2",
            minimumMacOS: "12.0",
            architectures: [.arm64],
            verificationNote: "Fixture only"
        )
        return RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "product-fixture-1",
            candidateMatrix: [],
            generations: [generation],
            catalogRevision: 1,
            allowedDownloadHosts: ["downloads.example.com"],
            profiles: [profile]
        )
    }

    private var componentDefinitions: [(String, RuntimeComponentRole)] {
        [
            ("jre", .jre),
            ("command-line-tools", .commandLineTools),
            ("platform-tools", .platformTools),
            ("emulator", .emulator),
            ("system-image", .systemImage)
        ]
    }

    private func component(
        id: String,
        role: RuntimeComponentRole
    ) -> RuntimeComponentDescriptor {
        let payload = Data("artifact-\(id)".utf8)
        let destination: String
        switch role {
        case .jre: destination = "jre"
        case .commandLineTools:
            destination = traversingDestination
                ? "../outside"
                : "sdk/cmdline-tools/latest"
        case .platformTools: destination = "sdk/platform-tools"
        case .emulator: destination = "sdk/emulator"
        case .systemImage:
            destination = "sdk/system-images/android-35/google_apis/arm64-v8a"
        case .platform: destination = "sdk/platforms/android-35"
        }
        return RuntimeComponentDescriptor(
            id: id,
            role: role,
            vendor: "Fixture",
            version: "1.0.0",
            architecture: .arm64,
            downloadURL: URL(
                string: "\(useHTTP ? "http" : "https")://\(componentHost)/\(id).zip"
            )!,
            sha256: invalidSHA ? "bad" : Self.sha256(payload),
            licenseID: "fixture-license",
            licenseURL: URL(string: "https://example.com/license")!,
            expectedVersionOutput: "1.0.0",
            minimumMacOS: "12.0",
            packageID: {
                switch role {
                case .systemImage:
                    return "system-images;android-35;google_apis;arm64-v8a"
                case .emulator:
                    return "emulator"
                default:
                    return nil
                }
            }(),
            compressedSize: Int64(payload.count),
            installedSize: 100,
            installation: RuntimeComponentInstallationDescriptor(
                archiveFormat: .raw,
                destinationRelativePath: destination,
                maximumExtractedSize: 1_000
            )
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor ProductCounter {
    private var value = 0

    func increment() { value += 1 }
    func current() -> Int { value }
}

private struct ProductDownloader: RuntimeArtifactDownloading {
    let counter: ProductCounter

    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        await counter.increment()
        try await Task.sleep(nanoseconds: 15_000_000)
        try Data("artifact-\(component.id)".utf8).write(to: destination)
    }
}

private actor ResumingProductDownloader:
    ProgressReportingRuntimeArtifactDownloading {
    private var mustFail = true
    private var observedResumeOffset: Int64 = 0

    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        try await download(
            component: component,
            to: destination,
            progress: { _, _ in }
        )
    }

    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let payload = Data("artifact-\(component.id)".utf8)
        let existing = (try? Data(contentsOf: destination)) ?? Data()
        if mustFail {
            mustFail = false
            let prefix = payload.prefix(max(1, payload.count / 2))
            try Data(prefix).write(to: destination)
            progress(Int64(prefix.count), Int64(payload.count))
            throw URLError(.networkConnectionLost)
        }
        observedResumeOffset = max(observedResumeOffset, Int64(existing.count))
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
    }

    func resumeOffset() -> Int64 { observedResumeOffset }
}

private struct ProductMaterializer: RuntimeComponentMaterializing {
    func materialize(
        artifact: URL,
        component: RuntimeComponentDescriptor,
        stagedGeneration: RuntimeGenerationLayout,
        extractionWorkspace: URL
    ) async throws -> InstalledRuntimeComponent {
        let installation = try XCTUnwrap(component.installation)
        let destination = stagedGeneration.root.appendingPathComponent(
            installation.destinationRelativePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        switch component.role {
        case .jre:
            try executable("bin/java", under: destination)
        case .commandLineTools:
            try executable("bin/sdkmanager", under: destination)
            try executable("bin/avdmanager", under: destination)
        case .platformTools:
            try executable("adb", under: destination)
        case .emulator:
            try executable("emulator", under: destination)
        case .systemImage:
            try Data((component.packageID ?? "").utf8).write(
                to: destination.appendingPathComponent("package.xml")
            )
            try Data("image".utf8).write(
                to: destination.appendingPathComponent("system.img")
            )
        case .platform:
            try Data("jar".utf8).write(
                to: destination.appendingPathComponent("android.jar")
            )
        }
        return InstalledRuntimeComponent(
            id: component.id,
            role: component.role,
            version: component.version,
            relativePath: installation.destinationRelativePath,
            sha256: component.sha256
        )
    }

    private func executable(_ path: String, under root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

private struct ProductValidator: StagedRuntimeValidating {
    let counter: ProductCounter

    func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws {
        await counter.increment()
    }
}

private struct FailingProductValidator: StagedRuntimeValidating {
    func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws {
        throw RuntimeInstallationError.stagedValidationFailed(
            "intentional product repair failure"
        )
    }
}
