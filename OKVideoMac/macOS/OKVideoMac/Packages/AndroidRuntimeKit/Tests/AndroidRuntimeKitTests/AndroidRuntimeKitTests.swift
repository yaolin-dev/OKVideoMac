import Foundation
import XCTest
@testable import AndroidRuntimeKit

final class AndroidRuntimeKitTests: XCTestCase {
    private let fixtureSHA256 = String(repeating: "a", count: 64)

    func testBundledCatalogContainsOnlyUnqualifiedRuntimeCandidates() throws {
        let catalog = try BundledRuntimeCatalog.load()

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(
            catalog.candidateMatrix.map(\.apiLevel),
            [28, 30, 31, 35]
        )
        XCTAssertTrue(
            catalog.candidateMatrix.allSatisfy { $0.state == .evaluation }
        )
        XCTAssertTrue(catalog.generations.isEmpty)
    }

    func testCatalogRequiresFullyPinnedJREAndAndroidComponents() throws {
        let generation = generationDescriptor(id: "r1")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-1",
            candidateMatrix: [],
            generations: [generation]
        )

        XCTAssertNoThrow(try RuntimeCatalogLoader.validate(catalog))

        let missingJRE = RuntimeGenerationDescriptor(
            generationID: RuntimeGenerationID(rawValue: "r2"),
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            minimumAppVersion: "0.5.0",
            architecture: .arm64,
            components: generation.components.filter { $0.role != .jre }
        )
        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            RuntimeCatalog(
                schemaVersion: 1,
                catalogVersion: "fixture-2",
                candidateMatrix: [],
                generations: [missingJRE]
            )
        )) { error in
            XCTAssertEqual(
                error as? RuntimeCatalogValidationError,
                .missingRequiredComponent(.jre, "r2")
            )
        }
    }

    func testCatalogRejectsMutableOrUnverifiedComponentIdentity() {
        let invalidJRE = RuntimeComponentDescriptor(
            id: "jre",
            role: .jre,
            vendor: "Fixture",
            version: "latest",
            architecture: .arm64,
            downloadURL: URL(string: "http://example.com/jre.zip")!,
            sha256: "not-a-hash",
            licenseID: "fixture",
            licenseURL: URL(string: "https://example.com/license")!,
            expectedVersionOutput: "17",
            minimumMacOS: "12.0",
            compressedSize: 1,
            installedSize: 1
        )
        var components = generationDescriptor(id: "r1").components
            .filter { $0.role != .jre }
        components.append(invalidJRE)
        let generation = RuntimeGenerationDescriptor(
            generationID: RuntimeGenerationID(rawValue: "r1"),
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            minimumAppVersion: "0.5.0",
            architecture: .arm64,
            components: components
        )

        XCTAssertThrowsError(try RuntimeCatalogLoader.validate(
            RuntimeCatalog(
                schemaVersion: 1,
                catalogVersion: "fixture",
                candidateMatrix: [],
                generations: [generation]
            )
        )) { error in
            XCTAssertEqual(
                error as? RuntimeCatalogValidationError,
                .invalidComponent(
                    "jre",
                    "version must be immutable and fully pinned"
                )
            )
        }
    }

    func testGenerationLayoutKeepsSDKJREAndAVDIndependent() {
        let layout = AndroidRuntimeLayout(
            runtimeRoot: URL(fileURLWithPath: "/tmp/OKVideoMac/AndroidRuntime")
        )
        let generation = layout.generation(
            RuntimeGenerationID(rawValue: "r3")
        )

        XCTAssertEqual(
            generation.sdk.path,
            "/tmp/OKVideoMac/AndroidRuntime/Generations/r3/sdk"
        )
        XCTAssertEqual(
            generation.jre.path,
            "/tmp/OKVideoMac/AndroidRuntime/Generations/r3/jre"
        )
        XCTAssertEqual(
            layout.avdDirectory.path,
            "/tmp/OKVideoMac/AndroidRuntime/avd/OKVideoMac_Runtime.avd"
        )
        XCTAssertFalse(layout.avdDirectory.path.hasPrefix(generation.root.path))
    }

    func testManagedPathBoundaryRejectsRootSiblingTraversalAndSymlinkEscape()
        throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("AndroidRuntime")
        let outside = fixture.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        let boundary = try ManagedRuntimePathBoundary(root: root)

        XCTAssertThrowsError(try boundary.validateMutationTarget(root))
        XCTAssertThrowsError(try boundary.validateMutationTarget(
            fixture.appendingPathComponent("AndroidRuntime-other/file")
        ))
        XCTAssertThrowsError(try boundary.validateMutationTarget(
            link.appendingPathComponent("payload")
        ))
        XCTAssertThrowsError(try boundary.descendant(
            relativePath: "../outside",
            under: root
        ))
        XCTAssertNoThrow(try boundary.descendant(
            relativePath: "Generations/r1/sdk",
            under: root
        ))
    }

    func testDetectorReportsNotInstalledWithoutGenerationPointer() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)

        XCTAssertEqual(
            AndroidRuntimeDetector(layout: layout).detect().status,
            .notInstalled
        )
    }

    func testDetectorRecognizesLegacyFlatSDKWithoutActivatingIt() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        try FileManager.default.createDirectory(
            at: layout.root.appendingPathComponent("sdk"),
            withIntermediateDirectories: true
        )

        let report = AndroidRuntimeDetector(layout: layout).detect()
        XCTAssertEqual(report.status, .legacyManagedLayout)
        XCTAssertEqual(report.issues.map(\.code), [.legacyLayout])
    }

    func testDetectorAcceptsCompleteGenerationAndPointerRollback() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let r1 = RuntimeGenerationID(rawValue: "r1")
        let r2 = RuntimeGenerationID(rawValue: "r2")
        try createInstalledGeneration(r1, layout: layout)
        try createInstalledGeneration(r2, layout: layout)

        try writePointer(r2, layout: layout)
        var report = AndroidRuntimeDetector(layout: layout).detect()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.activeGenerationID, r2)

        // Runtime rollback changes only the pointer. AVD data remains outside
        // both generation directories and is not copied or deleted.
        try writePointer(r1, layout: layout)
        report = AndroidRuntimeDetector(layout: layout).detect()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.activeGenerationID, r1)
        XCTAssertFalse(layout.avdDirectory.path.hasPrefix(
            layout.generation(r1).root.path
        ))
    }

    func testDetectorRejectsComponentPathThatEscapesManagedRoot() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let id = RuntimeGenerationID(rawValue: "r1")
        try createInstalledGeneration(id, layout: layout)
        let generation = layout.generation(id)
        var manifest = try JSONDecoder().decode(
            RuntimeGenerationManifest.self,
            from: Data(contentsOf: generation.manifest)
        )
        let badComponents = manifest.components.map { component in
            guard component.role == .jre else { return component }
            return InstalledRuntimeComponent(
                id: component.id,
                role: component.role,
                version: component.version,
                relativePath: "../../external/java",
                sha256: component.sha256
            )
        }
        manifest = RuntimeGenerationManifest(
            generationID: manifest.generationID,
            catalogVersion: manifest.catalogVersion,
            runtimeSchema: manifest.runtimeSchema,
            avdSchema: manifest.avdSchema,
            bridgeSchema: manifest.bridgeSchema,
            installedAt: manifest.installedAt,
            components: badComponents
        )
        try JSONEncoder().encode(manifest).write(
            to: generation.manifest,
            options: .atomic
        )
        try writePointer(id, layout: layout)

        let report = AndroidRuntimeDetector(layout: layout).detect()
        XCTAssertEqual(report.status, .corrupt)
        XCTAssertEqual(report.issues.map(\.code), [.pathEscapesManagedRoot])
    }

    func testManagedEnvironmentPurityPassesOnlyForOneGeneration() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let id = RuntimeGenerationID(rawValue: "r1")
        let generation = layout.generation(id)
        let environment = managedEnvironment(
            layout: layout,
            generation: generation
        )
        let snapshot = ManagedRuntimeEnvironmentSnapshot(
            generationID: id,
            java: generation.jre.appendingPathComponent("bin/java"),
            sdkManager: generation.sdk.appendingPathComponent(
                "cmdline-tools/latest/bin/sdkmanager"
            ),
            avdManager: generation.sdk.appendingPathComponent(
                "cmdline-tools/latest/bin/avdmanager"
            ),
            adb: generation.sdk.appendingPathComponent("platform-tools/adb"),
            emulator: generation.sdk.appendingPathComponent("emulator/emulator"),
            systemImage: generation.sdk.appendingPathComponent(
                "system-images/android-35/google_apis/arm64-v8a"
            ),
            avd: layout.avdDirectory,
            adbKey: layout.privateADBKey,
            environment: environment,
            expectedPrivateADBServerPort: 50_437,
            actualADBServerPort: 50_437,
            adbServerOwned: true
        )

        let report = ManagedRuntimePurityChecker(layout: layout)
            .evaluate(snapshot)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.entries.allSatisfy { $0.state == .managed })
        XCTAssertFalse(report.entries.map(\.location).joined().contains(
            fixture.path
        ))
    }

    func testManagedEnvironmentPurityRejectsExternalJavaAndSDKEnvironment()
        throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let id = RuntimeGenerationID(rawValue: "r1")
        let generation = layout.generation(id)
        var environment = managedEnvironment(
            layout: layout,
            generation: generation
        )
        environment["ANDROID_SDK_ROOT"] = "/opt/homebrew/share/android-sdk"
        let snapshot = ManagedRuntimeEnvironmentSnapshot(
            generationID: id,
            java: URL(fileURLWithPath: "/usr/bin/java"),
            sdkManager: generation.sdk.appendingPathComponent("sdkmanager"),
            avdManager: generation.sdk.appendingPathComponent("avdmanager"),
            adb: generation.sdk.appendingPathComponent("adb"),
            emulator: generation.sdk.appendingPathComponent("emulator"),
            systemImage: generation.sdk.appendingPathComponent("system-image"),
            avd: layout.avdDirectory,
            adbKey: layout.privateADBKey,
            environment: environment,
            expectedPrivateADBServerPort: 50_437,
            actualADBServerPort: 5_037,
            adbServerOwned: false
        )

        let report = ManagedRuntimePurityChecker(layout: layout)
            .evaluate(snapshot)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(
            report.entries.first(where: { $0.role == .java })?.state,
            .external
        )
        XCTAssertEqual(
            report.entries.first(where: { $0.role == .androidSDKRoot })?.state,
            .external
        )
        XCTAssertEqual(
            report.entries.first(where: { $0.role == .adbServer })?.state,
            .mismatched
        )
    }

    private func generationDescriptor(
        id: String
    ) -> RuntimeGenerationDescriptor {
        RuntimeGenerationDescriptor(
            generationID: RuntimeGenerationID(rawValue: id),
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            minimumAppVersion: "0.5.0",
            architecture: .arm64,
            components: [
                descriptor("jre", .jre),
                descriptor("cmdline", .commandLineTools),
                descriptor("platform-tools", .platformTools),
                descriptor("emulator", .emulator),
                descriptor("system-image", .systemImage)
            ]
        )
    }

    private func descriptor(
        _ id: String,
        _ role: RuntimeComponentRole
    ) -> RuntimeComponentDescriptor {
        RuntimeComponentDescriptor(
            id: id,
            role: role,
            vendor: "Fixture Vendor",
            version: "1.2.3",
            architecture: .arm64,
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: fixtureSHA256,
            licenseID: "fixture-license",
            licenseURL: URL(string: "https://example.com/license")!,
            expectedVersionOutput: "1.2.3",
            minimumMacOS: "12.0",
            packageID: role == .systemImage
                ? "system-images;android-35;google_apis;arm64-v8a"
                : nil,
            compressedSize: 100,
            installedSize: 200
        )
    }

    private func createInstalledGeneration(
        _ id: RuntimeGenerationID,
        layout: AndroidRuntimeLayout
    ) throws {
        let generation = layout.generation(id)
        let relativeComponents: [
            (String, RuntimeComponentRole, String)
        ] = [
            ("jre", .jre, "jre/bin/java"),
            (
                "cmdline",
                .commandLineTools,
                "sdk/cmdline-tools/latest/bin/sdkmanager"
            ),
            (
                "platform-tools",
                .platformTools,
                "sdk/platform-tools/adb"
            ),
            ("emulator", .emulator, "sdk/emulator/emulator"),
            (
                "system-image",
                .systemImage,
                "sdk/system-images/android-35/google_apis/arm64-v8a/system.img"
            )
        ]
        for (_, _, relativePath) in relativeComponents {
            let url = generation.root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: url)
        }
        let manifest = RuntimeGenerationManifest(
            generationID: id,
            catalogVersion: "fixture",
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            installedAt: Date(timeIntervalSince1970: 1),
            components: relativeComponents.map {
                InstalledRuntimeComponent(
                    id: $0.0,
                    role: $0.1,
                    version: "1.2.3",
                    relativePath: $0.2,
                    sha256: fixtureSHA256
                )
            }
        )
        try JSONEncoder().encode(manifest).write(
            to: generation.manifest,
            options: .atomic
        )
    }

    private func writePointer(
        _ id: RuntimeGenerationID,
        layout: AndroidRuntimeLayout
    ) throws {
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        let pointer = CurrentRuntimePointer(
            generationID: id,
            activatedAt: Date(timeIntervalSince1970: 2)
        )
        try JSONEncoder().encode(pointer).write(
            to: layout.currentRuntimePointer,
            options: .atomic
        )
    }

    private func managedEnvironment(
        layout: AndroidRuntimeLayout,
        generation: RuntimeGenerationLayout
    ) -> [String: String] {
        [
            "ANDROID_HOME": generation.sdk.path,
            "ANDROID_SDK_ROOT": generation.sdk.path,
            "ANDROID_AVD_HOME": layout.avdHome.path,
            "ANDROID_USER_HOME": layout.privateAndroidHome.path,
            "ANDROID_EMULATOR_HOME": layout.privateAndroidHome.path,
            "ADB_VENDOR_KEYS": layout.privateADBKey.path,
            "HOME": layout.privateHome.path
        ]
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AndroidRuntimeKitTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
