import Foundation
import XCTest
@testable import AndroidRuntimeKit

final class AndroidRuntimeKitTests: XCTestCase {
    private let fixtureSHA256 = String(repeating: "a", count: 64)

    func testBundledCatalogKeepsCandidatesExplicitAndShipsOneDefaultProfile() throws {
        let catalog = try BundledRuntimeCatalog.load()

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(
            catalog.candidateMatrix.map(\.apiLevel),
            [28, 30, 31, 35]
        )
        XCTAssertTrue(
            catalog.candidateMatrix.allSatisfy { $0.state == .evaluation }
        )
        XCTAssertEqual(catalog.catalogRevision, 1)
        XCTAssertEqual(catalog.generations.count, 1)
        XCTAssertEqual(
            catalog.defaultProfile?.generationID.rawValue,
            "r1-api35-arm64-20260907"
        )
        XCTAssertEqual(catalog.defaultProfile?.status, .defaultProfile)
        XCTAssertEqual(
            catalog.defaultProfile?.expectedDownloadSize,
            catalog.generations[0].components.reduce(Int64(0)) {
                $0 + $1.compressedSize
            }
        )
        XCTAssertEqual(catalog.allowedDownloadHosts?.sorted(), [
            "cdn.azul.com", "dl.google.com"
        ])
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

    func testCandidatePlannerAllocatesIsolatedNamesAndPorts() throws {
        let catalog = try BundledRuntimeCatalog.load()
        let plans = try RuntimeCandidatePlanner.plans(
            for: catalog.candidateMatrix,
            runID: "run-1234"
        )

        XCTAssertEqual(plans.count, 4)
        XCTAssertEqual(Set(plans.map(\.avdName)).count, 4)
        XCTAssertTrue(plans.allSatisfy {
            $0.avdName.hasPrefix("OKVideoMac_Matrix_")
                && $0.consolePort.isMultiple(of: 2)
                && $0.consolePort >= 5_674
                && $0.privateADBServerPort >= 50_451
                && $0.bridgeHostPort >= 29_978
        })
        let everyPort = plans.flatMap {
            [
                $0.consolePort,
                $0.consolePort + 1,
                $0.privateADBServerPort,
                $0.bridgeHostPort
            ]
        }
        XCTAssertEqual(Set(everyPort).count, everyPort.count)
    }

    func testCandidateWorkspaceCannotOverlapProductionRuntime() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let production = fixture.appendingPathComponent(
            "Application Support/OKVideoMac/AndroidRuntime",
            isDirectory: true
        )
        XCTAssertThrowsError(try RuntimeCandidateWorkspaceBoundary(
            workspace: production.appendingPathComponent("Matrix"),
            productionRuntimeRoot: production
        )) { error in
            XCTAssertEqual(
                error as? RuntimeCandidateWorkspaceError,
                .overlapsProductionRuntime
            )
        }

        let workspace = fixture.appendingPathComponent(
            "CandidateMatrix",
            isDirectory: true
        )
        let boundary = try RuntimeCandidateWorkspaceBoundary(
            workspace: workspace,
            productionRuntimeRoot: production
        )
        XCTAssertNoThrow(try boundary.validateMutationTarget(
            workspace.appendingPathComponent("runs/run-1/report.json")
        ))
        XCTAssertThrowsError(try boundary.validateMutationTarget(
            production.appendingPathComponent("current-runtime.json")
        ))
    }

    func testCandidateReportRequiresTheCompleteLifecycleAndPurity() throws {
        let report = candidateReport(
            macOSMajor: 14,
            profile: .contaminated
        )
        XCTAssertTrue(report.passed)
        XCTAssertTrue(RuntimeCandidateReportValidator.validate(report).isEmpty)

        let incomplete = RuntimeCandidateEvaluationReport(
            runID: report.runID,
            candidate: report.candidate,
            startedAt: report.startedAt,
            completedAt: report.completedAt,
            host: report.host,
            toolchain: report.toolchain,
            phases: report.phases.filter {
                $0.phase != .dexSpiderInvocation
            },
            adbTimeline: report.adbTimeline,
            resourceSamples: report.resourceSamples,
            purityReport: report.purityReport,
            evidenceDirectory: report.evidenceDirectory
        )
        XCTAssertFalse(incomplete.passed)
        XCTAssertTrue(
            RuntimeCandidateReportValidator.validate(incomplete).contains {
                $0.contains(RuntimeCandidatePhase.dexSpiderInvocation.rawValue)
            }
        )
    }

    func testCandidateRemainsPendingUntilAllOSVersionsAndProfilesPass() {
        let reports = [12, 13, 14, 15].map {
            candidateReport(macOSMajor: $0, profile: .contaminated)
        }
        let pending = RuntimeCandidateQualifier.qualification(
            candidateID: reports[0].candidate.id,
            reports: reports
        )
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.missingEnvironmentProfiles, [.clean])
        XCTAssertTrue(pending.missingMacOSMajorVersions.isEmpty)

        let qualified = RuntimeCandidateQualifier.qualification(
            candidateID: reports[0].candidate.id,
            reports: reports + [candidateReport(
                macOSMajor: 15,
                profile: .clean
            )]
        )
        XCTAssertEqual(qualified.state, .qualified)
    }

    func testCandidateFailureRejectsQualification() {
        let passing = candidateReport(
            macOSMajor: 14,
            profile: .contaminated
        )
        let failing = RuntimeCandidateEvaluationReport(
            runID: "failed-run",
            candidate: passing.candidate,
            startedAt: passing.startedAt,
            completedAt: passing.completedAt,
            host: passing.host,
            toolchain: passing.toolchain,
            phases: passing.phases.map {
                $0.phase == .bridgeHealth
                    ? RuntimeCandidatePhaseResult(
                        phase: $0.phase,
                        outcome: .failed,
                        detail: "fixture failure"
                    )
                    : $0
            },
            adbTimeline: passing.adbTimeline,
            resourceSamples: passing.resourceSamples,
            purityReport: passing.purityReport,
            evidenceDirectory: passing.evidenceDirectory
        )
        let qualification = RuntimeCandidateQualifier.qualification(
            candidateID: passing.candidate.id,
            reports: [passing, failing],
            requiredMacOSMajorVersions: [14],
            requiredProfiles: [.contaminated]
        )
        XCTAssertEqual(qualification.state, .rejected)
        XCTAssertTrue(qualification.failures.contains {
            $0.contains(RuntimeCandidatePhase.bridgeHealth.rawValue)
        })
    }

    func testInstallationSingleFlightSharesOneTransactionAcrossTenCallers()
        async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let descriptor = downloadableGenerationDescriptor(id: "r35")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-install-1",
            candidateMatrix: [],
            generations: [descriptor]
        )
        let downloads = InvocationCounter()
        let validations = InvocationCounter()
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: FixtureDownloader(counter: downloads),
            materializer: FixtureMaterializer(),
            validator: FixtureValidator(counter: validations)
        )
        let secondInstallerInstance = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: FixtureDownloader(counter: downloads),
            materializer: FixtureMaterializer(),
            validator: FixtureValidator(counter: validations)
        )

        let results = try await withThrowingTaskGroup(
            of: RuntimeInstallationResult.self
        ) { group in
            for index in 0..<10 {
                group.addTask {
                    try await (index.isMultiple(of: 2)
                        ? installer
                        : secondInstallerInstance).install(
                        generationID: descriptor.generationID
                    )
                }
            }
            var values: [RuntimeInstallationResult] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0.disposition == .installed })
        let downloadCount = await downloads.value
        let validationCount = await validations.value
        XCTAssertEqual(downloadCount, descriptor.components.count)
        XCTAssertEqual(validationCount, 1)
        let report = AndroidRuntimeDetector(layout: layout).detect(
            catalog: catalog
        )
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.activeGenerationID, descriptor.generationID)
    }

    func testDifferentGenerationRequestsSerializeAndReturnOwnResults()
        async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let first = downloadableGenerationDescriptor(id: "r35a")
        let second = downloadableGenerationDescriptor(id: "r35b")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-serialized-generations",
            candidateMatrix: [],
            generations: [first, second]
        )
        let validations = InvocationCounter()
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: FixtureDownloader(counter: InvocationCounter()),
            materializer: FixtureMaterializer(),
            validator: FixtureValidator(counter: validations)
        )

        async let firstResult = installer.install(
            generationID: first.generationID
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        async let secondResult = installer.install(
            generationID: second.generationID
        )
        let (firstValue, secondValue) = try await (firstResult, secondResult)
        let results = [firstValue, secondValue]

        XCTAssertEqual(results.map(\.generationID), [
            first.generationID,
            second.generationID
        ])
        let validationCount = await validations.currentValue()
        XCTAssertEqual(validationCount, 2)
    }

    func testFailedInstallationPreservesCurrentGenerationAndAVD() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let r1 = RuntimeGenerationID(rawValue: "r1")
        try createInstalledGeneration(r1, layout: layout)
        try writePointer(r1, layout: layout)
        try FileManager.default.createDirectory(
            at: layout.avdDirectory,
            withIntermediateDirectories: true
        )
        let userdata = layout.avdDirectory.appendingPathComponent("userdata.img")
        try Data("keep-userdata".utf8).write(to: userdata)
        let r2 = downloadableGenerationDescriptor(id: "r2")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-install-2",
            candidateMatrix: [],
            generations: [generationDescriptor(id: "r1"), r2]
        )
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: FixtureDownloader(counter: InvocationCounter()),
            materializer: FixtureMaterializer(),
            validator: FailingFixtureValidator()
        )

        do {
            _ = try await installer.install(generationID: r2.generationID)
            XCTFail("Expected staged validation to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("fixture failure"))
        }

        let pointer = try JSONDecoder().decode(
            CurrentRuntimePointer.self,
            from: Data(contentsOf: layout.currentRuntimePointer)
        )
        XCTAssertEqual(pointer.generationID, r1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.generation(r2.generationID).root.path
        ))
        XCTAssertEqual(
            try String(contentsOf: userdata, encoding: .utf8),
            "keep-userdata"
        )
        let transaction = try JSONDecoder().decode(
            RuntimeInstallationTransaction.self,
            from: Data(contentsOf: layout.installationTransaction)
        )
        XCTAssertEqual(transaction.phase, .failed)
        XCTAssertEqual(transaction.previousGenerationID, r1)
    }

    func testRollbackOnlySwitchesPointerAndKeepsAVD() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let r1 = RuntimeGenerationID(rawValue: "r1")
        let r2 = RuntimeGenerationID(rawValue: "r2")
        try createInstalledGeneration(r1, layout: layout)
        try createInstalledGeneration(r2, layout: layout)
        try writePointer(r2, layout: layout)
        try FileManager.default.createDirectory(
            at: layout.avdDirectory,
            withIntermediateDirectories: true
        )
        let userdata = layout.avdDirectory.appendingPathComponent("userdata.img")
        try Data("stable".utf8).write(to: userdata)
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-rollback",
            candidateMatrix: [],
            generations: [
                generationDescriptor(id: "r1"),
                generationDescriptor(id: "r2")
            ]
        )
        let installer = AndroidRuntimeInstaller(layout: layout, catalog: catalog)

        let result = try await installer.rollback(to: r1)

        XCTAssertEqual(result.previousGenerationID, r2)
        XCTAssertEqual(result.generationID, r1)
        XCTAssertEqual(
            try String(contentsOf: userdata, encoding: .utf8),
            "stable"
        )
    }

    func testCancelledInstallationCleansStagingAndDoesNotActivate() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let generation = downloadableGenerationDescriptor(id: "r35")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-cancel",
            candidateMatrix: [],
            generations: [generation]
        )
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: SlowFixtureDownloader(),
            materializer: FixtureMaterializer(),
            validator: FixtureValidator(counter: InvocationCounter())
        )
        let task = Task {
            try await installer.install(generationID: generation.generationID)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await installer.cancelInstallation()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.currentRuntimePointer.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.generation(generation.generationID).root.path
        ))
        let stagingContents = try FileManager.default.contentsOfDirectory(
            atPath: layout.staging.path
        )
        XCTAssertTrue(stagingContents.isEmpty)
        let transaction = try JSONDecoder().decode(
            RuntimeInstallationTransaction.self,
            from: Data(contentsOf: layout.installationTransaction)
        )
        XCTAssertEqual(transaction.phase, .cancelled)
    }

    func testInterruptedTransactionIsRecoveredInsideManagedStaging()
        async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let layout = AndroidRuntimeLayout(runtimeRoot: fixture)
        let generation = downloadableGenerationDescriptor(id: "r35")
        let catalog = RuntimeCatalog(
            schemaVersion: 1,
            catalogVersion: "fixture-recovery",
            candidateMatrix: [],
            generations: [generation]
        )
        try FileManager.default.createDirectory(
            at: layout.staging,
            withIntermediateDirectories: true
        )
        let transactionID = UUID().uuidString.lowercased()
        let abandoned = layout.staging.appendingPathComponent(transactionID)
        try FileManager.default.createDirectory(
            at: abandoned,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: abandoned.appendingPathComponent("payload")
        )
        let interrupted = RuntimeInstallationTransaction(
            transactionID: transactionID,
            generationID: generation.generationID,
            previousGenerationID: nil,
            phase: .staging,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try JSONEncoder().encode(interrupted).write(
            to: layout.installationTransaction,
            options: .atomic
        )
        let installer = AndroidRuntimeInstaller(
            layout: layout,
            catalog: catalog,
            downloader: FixtureDownloader(counter: InvocationCounter()),
            materializer: FixtureMaterializer(),
            validator: FixtureValidator(counter: InvocationCounter())
        )

        _ = try await installer.install(generationID: generation.generationID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(
            AndroidRuntimeDetector(layout: layout).detect(catalog: catalog).status,
            .ready
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
            installedSize: 200,
            installation: installationDescriptor(for: role)
        )
    }

    private func downloadableGenerationDescriptor(
        id: String
    ) -> RuntimeGenerationDescriptor {
        let roles: [(String, RuntimeComponentRole)] = [
            ("jre", .jre),
            ("cmdline", .commandLineTools),
            ("platform-tools", .platformTools),
            ("emulator", .emulator),
            ("system-image", .systemImage)
        ]
        return RuntimeGenerationDescriptor(
            generationID: RuntimeGenerationID(rawValue: id),
            runtimeSchema: 1,
            avdSchema: 1,
            bridgeSchema: 1,
            minimumAppVersion: "0.5.0",
            architecture: .arm64,
            components: roles.map { componentID, role in
                let payload = Data("artifact-\(componentID)".utf8)
                return RuntimeComponentDescriptor(
                    id: componentID,
                    role: role,
                    vendor: "Fixture Vendor",
                    version: "1.2.3",
                    architecture: .arm64,
                    downloadURL: URL(
                        string: "https://example.com/\(componentID).zip"
                    )!,
                    sha256: Self.sha256(payload),
                    licenseID: "fixture-license",
                    licenseURL: URL(string: "https://example.com/license")!,
                    expectedVersionOutput: "1.2.3",
                    minimumMacOS: "12.0",
                    packageID: role == .systemImage
                        ? "system-images;android-35;google_apis;arm64-v8a"
                        : nil,
                    compressedSize: Int64(payload.count),
                    installedSize: 100,
                    installation: installationDescriptor(for: role)
                )
            }
        )
    }

    private func installationDescriptor(
        for role: RuntimeComponentRole
    ) -> RuntimeComponentInstallationDescriptor {
        let destination: String
        switch role {
        case .jre: destination = "jre"
        case .commandLineTools: destination = "sdk/cmdline-tools/latest"
        case .platformTools: destination = "sdk/platform-tools"
        case .emulator: destination = "sdk/emulator"
        case .systemImage:
            destination = "sdk/system-images/android-35/google_apis/arm64-v8a"
        case .platform: destination = "sdk/platforms/android-35"
        }
        return RuntimeComponentInstallationDescriptor(
            archiveFormat: .raw,
            destinationRelativePath: destination
        )
    }

    private static func sha256(_ data: Data) -> String {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try! RuntimeSHA256.digest(of: temporary)
    }

    private func candidateReport(
        macOSMajor: Int,
        profile: RuntimeCandidateEnvironmentProfile
    ) -> RuntimeCandidateEvaluationReport {
        let candidate = RuntimeCandidate(
            id: "api-35-google-apis-arm64",
            apiLevel: 35,
            systemImageVariant: "google_apis",
            architecture: .arm64,
            state: .evaluation
        )
        let purity = RuntimePurityReport(
            passed: true,
            generationID: RuntimeGenerationID(rawValue: "matrixRun"),
            entries: []
        )
        return RuntimeCandidateEvaluationReport(
            runID: "run-\(macOSMajor)-\(profile.rawValue)",
            candidate: candidate,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            host: RuntimeCandidateHostDescriptor(
                macOSVersion: "\(macOSMajor).0",
                macOSMajorVersion: macOSMajor,
                architecture: "arm64",
                hardwareModel: "FixtureMac",
                environmentProfile: profile
            ),
            toolchain: RuntimeCandidateToolchainDescriptor(
                javaVersion: "17.0.1",
                commandLineToolsVersion: "1.0",
                adbVersion: "1.0.41",
                emulatorVersion: "1.0",
                systemImagePackageID:
                    "system-images;android-35;google_apis;arm64-v8a",
                bridgeSHA256: fixtureSHA256
            ),
            phases: RuntimeCandidatePhase.allCases.map {
                RuntimeCandidatePhaseResult(
                    phase: $0,
                    outcome: .passed,
                    durationSeconds: 0.1,
                    detail: "passed"
                )
            },
            adbTimeline: [RuntimeCandidateADBObservation(
                elapsedSeconds: 1,
                targetState: .device,
                devices: ["emulator-5684 device"],
                emulatorAlive: true
            )],
            resourceSamples: [RuntimeCandidateResourceSample(
                elapsedSeconds: 1,
                residentMemoryBytes: 100,
                cpuPercent: 0.5
            )],
            purityReport: purity,
            evidenceDirectory: "<workspace>/runs/run"
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

private actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private struct FixtureDownloader: RuntimeArtifactDownloading {
    let counter: InvocationCounter

    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        await counter.increment()
        try await Task.sleep(nanoseconds: 30_000_000)
        try Data("artifact-\(component.id)".utf8).write(to: destination)
    }
}

private struct SlowFixtureDownloader: RuntimeArtifactDownloading {
    func download(
        component: RuntimeComponentDescriptor,
        to destination: URL
    ) async throws {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Data("artifact-\(component.id)".utf8).write(to: destination)
    }
}

private struct FixtureMaterializer: RuntimeComponentMaterializing {
    func materialize(
        artifact: URL,
        component: RuntimeComponentDescriptor,
        stagedGeneration: RuntimeGenerationLayout,
        extractionWorkspace: URL
    ) async throws -> InstalledRuntimeComponent {
        guard let installation = component.installation else {
            throw RuntimeInstallationError.missingInstallationLayout(
                component.id
            )
        }
        let destination = stagedGeneration.root.appendingPathComponent(
            installation.destinationRelativePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(
            to: destination.appendingPathComponent("fixture")
        )
        return InstalledRuntimeComponent(
            id: component.id,
            role: component.role,
            version: component.version,
            relativePath: installation.destinationRelativePath,
            sha256: component.sha256
        )
    }
}

private struct FixtureValidator: StagedRuntimeValidating {
    let counter: InvocationCounter

    func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws {
        await counter.increment()
    }
}

private struct FailingFixtureValidator: StagedRuntimeValidating {
    func validate(
        generation: RuntimeGenerationLayout,
        descriptor: RuntimeGenerationDescriptor,
        manifest: RuntimeGenerationManifest
    ) async throws {
        throw RuntimeInstallationError.stagedValidationFailed(
            "fixture failure"
        )
    }
}
