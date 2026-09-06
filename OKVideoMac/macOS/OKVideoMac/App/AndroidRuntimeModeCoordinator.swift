import AndroidRuntimeKit
import CryptoKit
import Foundation

enum AndroidRuntimeMode: String, Codable, CaseIterable, Sendable {
    case managed
    case external

    var userFacingName: String {
        switch self {
        case .managed: return "OKVideoMac 自动管理"
        case .external: return "现有 Android SDK"
        }
    }
}

enum AndroidRuntimeSelectionSource: String, Codable, Sendable {
    case newUserDefault
    case usableManagedRuntimeMigration
    case legacyExternalMigration
    case userSelectedExternal
    case userSelectedManaged
}

struct AndroidRuntimeModeRecord: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let currentMigrationVersion = 1

    let schemaVersion: Int
    let migrationVersion: Int
    let revision: Int
    let mode: AndroidRuntimeMode
    let externalSDKRoot: String?
    let selectionSource: AndroidRuntimeSelectionSource
    let createdAt: Date
    let updatedAt: Date

    init(
        schemaVersion: Int = supportedSchemaVersion,
        migrationVersion: Int = currentMigrationVersion,
        revision: Int,
        mode: AndroidRuntimeMode,
        externalSDKRoot: String?,
        selectionSource: AndroidRuntimeSelectionSource,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.migrationVersion = migrationVersion
        self.revision = revision
        self.mode = mode
        self.externalSDKRoot = externalSDKRoot
        self.selectionSource = selectionSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AndroidRuntimeModeStoreError: LocalizedError, Equatable {
    case unreadableSelection
    case unsupportedSelectionSchema(Int)
    case externalSDKRequired

    var errorDescription: String? {
        switch self {
        case .unreadableSelection:
            return "Android 运行环境选择记录无法读取"
        case .unsupportedSelectionSchema(let schema):
            return "Android 运行环境选择记录版本不受支持（\(schema)）"
        case .externalSDKRequired:
            return "使用现有 Android SDK 时必须先选择 SDK 文件夹"
        }
    }
}

/// Owns the canonical, atomically-written product choice. The historical
/// UserDefaults key remains migration input and downgrade compatibility only;
/// runtime routing never depends on two independently-written preferences.
struct AndroidRuntimeModeStore {
    static let legacySDKRootDefaultsKey = "OKVideoMac.AndroidSDKRoot"

    let recordURL: URL
    let defaults: UserDefaults
    let fileManager: FileManager
    let now: () -> Date

    init(
        applicationSupportDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        recordURL = applicationSupportDirectory
            .appendingPathComponent("AndroidRuntime", isDirectory: true)
            .appendingPathComponent("runtime-selection.json")
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
    }

    func loadOrMigrate(
        managedRuntimeUsable: Bool
    ) throws -> AndroidRuntimeModeRecord {
        if fileManager.fileExists(atPath: recordURL.path) {
            return try load()
        }

        let legacyRoot = defaults.string(
            forKey: Self.legacySDKRootDefaultsKey
        ).flatMap(Self.normalizedNonemptyPath)
        let mode: AndroidRuntimeMode
        let source: AndroidRuntimeSelectionSource
        if managedRuntimeUsable {
            mode = .managed
            source = .usableManagedRuntimeMigration
        } else if legacyRoot != nil {
            // Presence of the explicit historical OKVideoMac preference is
            // enough to preserve the old product choice. Validation is kept
            // separate so a moved SDK remains visible and repairable.
            mode = .external
            source = .legacyExternalMigration
        } else {
            mode = .managed
            source = .newUserDefault
        }
        let timestamp = canonicalTimestamp()
        let record = AndroidRuntimeModeRecord(
            revision: 1,
            mode: mode,
            externalSDKRoot: legacyRoot,
            selectionSource: source,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try write(record)
        return record
    }

    func load() throws -> AndroidRuntimeModeRecord {
        let record: AndroidRuntimeModeRecord
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            record = try decoder.decode(
                AndroidRuntimeModeRecord.self,
                from: Data(contentsOf: recordURL)
            )
        } catch {
            throw AndroidRuntimeModeStoreError.unreadableSelection
        }
        guard record.schemaVersion == AndroidRuntimeModeRecord
            .supportedSchemaVersion else {
            throw AndroidRuntimeModeStoreError.unsupportedSelectionSchema(
                record.schemaVersion
            )
        }
        if record.mode == .external,
           record.externalSDKRoot?.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty != false {
            throw AndroidRuntimeModeStoreError.externalSDKRequired
        }
        return record
    }

    func committing(
        _ current: AndroidRuntimeModeRecord,
        mode: AndroidRuntimeMode,
        externalSDKRoot: URL?,
        source: AndroidRuntimeSelectionSource
    ) throws -> AndroidRuntimeModeRecord {
        let normalizedRoot = externalSDKRoot.map(Self.normalizedPath)
            ?? current.externalSDKRoot
        if mode == .external, normalizedRoot == nil {
            throw AndroidRuntimeModeStoreError.externalSDKRequired
        }
        let record = AndroidRuntimeModeRecord(
            revision: current.revision + 1,
            mode: mode,
            externalSDKRoot: normalizedRoot,
            selectionSource: source,
            createdAt: current.createdAt,
            updatedAt: canonicalTimestamp()
        )
        try write(record)
        // Canonical routing has already committed atomically. Keep the old
        // key only so a downgrade still sees the user's most recent SDK.
        if let normalizedRoot {
            defaults.set(
                normalizedRoot,
                forKey: Self.legacySDKRootDefaultsKey
            )
        }
        return record
    }

    private func write(_ record: AndroidRuntimeModeRecord) throws {
        try fileManager.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordURL.path
        )
    }

    private static func normalizedNonemptyPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedPath(URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath
        ))
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func canonicalTimestamp() -> Date {
        // ISO-8601 persistence on the deployment range is second-precision.
        // Canonicalizing before returning keeps an in-memory committed record
        // exactly equal to the same record loaded after relaunch.
        Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
    }
}

enum ExternalAndroidRuntimeIssueCode: String, Codable, Sendable {
    case missingSDKRoot
    case missingADB
    case adbNotExecutable
    case unsupportedADBArchitecture
    case missingEmulator
    case emulatorNotExecutable
    case unsupportedEmulatorArchitecture
    case missingInteractiveSystemImage
    case incompleteAVD
    case invalidAVDConfiguration
    case avdSystemImageMissingFromSelectedSDK
    case avdSystemImageMismatch
    case incompatibleAVDFingerprint
    case missingAVDManager
    case missingJava
}

struct ExternalAndroidRuntimeIssue: Codable, Equatable, Sendable {
    let code: ExternalAndroidRuntimeIssueCode
    let detail: String
}

struct ExternalAndroidRuntimeCapability: Codable, Equatable, Sendable {
    let available: Bool
    let detail: String
}

enum AndroidRuntimeAVDSource: String, Codable, Sendable {
    case managed
    case external
}

struct AndroidRuntimeAVDCompatibilityFingerprint:
    Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let avdSchema: Int
    let runtimeSource: AndroidRuntimeAVDSource
    let runtimeIdentity: String
    let systemImagePackageID: String
    let apiLevel: Int
    let abi: String
    let tag: String
    let emulatorRevision: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        schemaVersion: Int = supportedSchemaVersion,
        avdSchema: Int,
        runtimeSource: AndroidRuntimeAVDSource,
        runtimeIdentity: String,
        systemImagePackageID: String,
        apiLevel: Int,
        abi: String,
        tag: String,
        emulatorRevision: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.avdSchema = avdSchema
        self.runtimeSource = runtimeSource
        self.runtimeIdentity = runtimeIdentity
        self.systemImagePackageID = systemImagePackageID
        self.apiLevel = apiLevel
        self.abi = abi
        self.tag = tag
        self.emulatorRevision = emulatorRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func refreshingTimestamps(
        createdAt: Date,
        updatedAt: Date = Date()
    ) -> Self {
        Self(
            avdSchema: avdSchema,
            runtimeSource: runtimeSource,
            runtimeIdentity: runtimeIdentity,
            systemImagePackageID: systemImagePackageID,
            apiLevel: apiLevel,
            abi: abi,
            tag: tag,
            emulatorRevision: emulatorRevision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum AndroidRuntimeAVDFingerprintStatus: Equatable, Sendable {
    case notCreated
    case adoptableLegacy
    case compatible
    case refreshableMetadata
    case incompatible(String)

    var diagnosticName: String {
        switch self {
        case .notCreated: return "notCreated"
        case .adoptableLegacy: return "adoptableLegacy"
        case .compatible: return "compatible"
        case .refreshableMetadata: return "refreshableMetadata"
        case .incompatible(let reason): return "incompatible:\(reason)"
        }
    }
}

struct AndroidRuntimeAVDFingerprintStore {
    let layout: AndroidRuntimeLayout
    let fileManager: FileManager

    var url: URL {
        layout.avdHome.appendingPathComponent("runtime-compatibility.json")
    }

    func inspect(
        expected: AndroidRuntimeAVDCompatibilityFingerprint,
        hasAVD: Bool,
        legacyManagedManifestExists: Bool
    ) -> AndroidRuntimeAVDFingerprintStatus {
        guard hasAVD else { return .notCreated }
        guard fileManager.fileExists(atPath: url.path) else {
            if expected.runtimeSource == .external,
               legacyManagedManifestExists {
                return .incompatible("runtime-source-managed")
            }
            return .adoptableLegacy
        }
        guard let data = try? Data(contentsOf: url),
              let existing = Self.decode(data) else {
            return .incompatible("fingerprint-unreadable")
        }
        guard existing.schemaVersion == AndroidRuntimeAVDCompatibilityFingerprint
            .supportedSchemaVersion else {
            return .incompatible("fingerprint-schema")
        }
        guard existing.runtimeSource == expected.runtimeSource else {
            return .incompatible("runtime-source")
        }
        guard existing.avdSchema == expected.avdSchema else {
            return .incompatible("avd-schema")
        }
        guard existing.systemImagePackageID == expected.systemImagePackageID,
              existing.apiLevel == expected.apiLevel,
              existing.abi == expected.abi,
              existing.tag == expected.tag else {
            return .incompatible("system-image")
        }
        if let existingMajor = Self.majorRevision(existing.emulatorRevision),
           let expectedMajor = Self.majorRevision(expected.emulatorRevision),
           existingMajor != expectedMajor {
            return .incompatible("emulator-major-version")
        }
        if existing.runtimeIdentity != expected.runtimeIdentity {
            return expected.runtimeSource == .managed
                ? .refreshableMetadata
                : .incompatible("external-sdk-identity")
        }
        return .compatible
    }

    func adoptOrRefresh(
        _ expected: AndroidRuntimeAVDCompatibilityFingerprint,
        status: AndroidRuntimeAVDFingerprintStatus
    ) throws {
        switch status {
        case .adoptableLegacy, .refreshableMetadata:
            let existingCreatedAt = (try? Data(contentsOf: url))
                .flatMap(Self.decode)?.createdAt
            try write(expected.refreshingTimestamps(
                createdAt: existingCreatedAt ?? Date()
            ))
        case .compatible, .notCreated:
            return
        case .incompatible(let reason):
            throw AndroidRuntimeModeCoordinatorError.incompatibleAVD(reason)
        }
    }

    func write(
        _ fingerprint: AndroidRuntimeAVDCompatibilityFingerprint
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fingerprint).write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func decode(
        _ data: Data
    ) -> AndroidRuntimeAVDCompatibilityFingerprint? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            AndroidRuntimeAVDCompatibilityFingerprint.self,
            from: data
        )
    }

    private static func majorRevision(_ revision: String?) -> Int? {
        revision?.split(separator: ".").first.flatMap { Int($0) }
    }
}

struct ExternalAndroidRuntimeValidation: Equatable, Sendable {
    let sdkRoot: URL
    let toolchain: AndroidToolchain?
    let javaRuntime: AndroidJavaRuntime?
    let systemImage: AndroidSystemImage?
    let launchCapability: ExternalAndroidRuntimeCapability
    let createRepairCapability: ExternalAndroidRuntimeCapability
    let avdExists: Bool
    let avdConfigurationExists: Bool
    let avdFingerprintStatus: AndroidRuntimeAVDFingerprintStatus
    let expectedAVDFingerprint: AndroidRuntimeAVDCompatibilityFingerprint?
    let emulatorRevision: String?
    let issues: [ExternalAndroidRuntimeIssue]

    var canPrepareRuntime: Bool {
        if avdConfigurationExists { return launchCapability.available }
        if avdExists { return false }
        return createRepairCapability.available
    }

    /// A complete SDK can still be selected when the shared private AVD needs
    /// an explicit recoverable rebuild. Selection never performs that rebuild;
    /// normal startup remains fail-closed until the user chooses Repair.
    var canSelectEnvironment: Bool {
        canPrepareRuntime || createRepairCapability.available
    }

    var userFacingStatus: String {
        if canPrepareRuntime {
            if launchCapability.available {
                return "可用；可以直接启动现有专用 Android 环境"
            }
            return "可用；首次启动时将创建专用 Android 环境"
        }
        return issues.first?.detail ?? "现有 Android SDK 配置不可用"
    }

    var userFacingSelectionStatus: String {
        if canPrepareRuntime { return userFacingStatus }
        if createRepairCapability.available {
            return "SDK 可用，但现有专用 Android 环境不兼容；切换后需要由用户明确执行备份并重建"
        }
        return userFacingStatus
    }
}

struct ExternalAndroidRuntimeValidator {
    typealias ArchitectureInspector = (URL) -> Bool
    typealias JavaResolver = () -> AndroidJavaRuntime?

    let applicationSupportDirectory: URL
    let homeDirectory: URL
    let environment: [String: String]
    let fileManager: FileManager
    let architectureInspector: ArchitectureInspector
    let javaResolver: JavaResolver

    init(
        applicationSupportDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        architectureInspector: ArchitectureInspector? = nil,
        javaResolver: JavaResolver? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.fileManager = fileManager
        self.architectureInspector = architectureInspector
            ?? Self.hostCanExecute
        self.javaResolver = javaResolver ?? {
            AndroidJavaRuntimeResolver(
                homeDirectory: homeDirectory,
                environment: environment,
                fileManager: fileManager
            ).resolve()
        }
    }

    func validate(sdkRoot requestedRoot: URL) -> ExternalAndroidRuntimeValidation {
        let sdkRoot = requestedRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        let layout = AndroidRuntimeLayout(
            applicationSupportDirectory: applicationSupportDirectory
        )
        var issues: [ExternalAndroidRuntimeIssue] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sdkRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            issues.append(.init(
                code: .missingSDKRoot,
                detail: "以前配置的 Android SDK 文件夹已不存在"
            ))
            return unavailable(
                sdkRoot: sdkRoot,
                layout: layout,
                issues: issues
            )
        }

        let adb = sdkRoot.appendingPathComponent("platform-tools/adb")
        let emulator = sdkRoot.appendingPathComponent("emulator/emulator")
        inspectExecutable(
            adb,
            missing: .missingADB,
            notExecutable: .adbNotExecutable,
            unsupportedArchitecture: .unsupportedADBArchitecture,
            label: "ADB",
            issues: &issues
        )
        inspectExecutable(
            emulator,
            missing: .missingEmulator,
            notExecutable: .emulatorNotExecutable,
            unsupportedArchitecture: .unsupportedEmulatorArchitecture,
            label: "Android Emulator",
            issues: &issues
        )

        let resolver = AndroidToolchainResolver(
            applicationSupportDirectory: applicationSupportDirectory,
            homeDirectory: homeDirectory,
            environment: environment,
            userSelectedSDKRoot: sdkRoot.path,
            fileManager: fileManager,
            selectionMode: .external
        )
        let toolchain = issues.contains(where: { issue in
            switch issue.code {
            case .missingADB, .adbNotExecutable, .unsupportedADBArchitecture,
                 .missingEmulator, .emulatorNotExecutable,
                 .unsupportedEmulatorArchitecture:
                return true
            default:
                return false
            }
        }) ? nil : resolver.toolchain(at: sdkRoot)
        let images = toolchain.map {
            resolver.interactiveSystemImages(in: $0)
        } ?? []
        if toolchain != nil, images.isEmpty {
            issues.append(.init(
                code: .missingInteractiveSystemImage,
                detail: "所选 SDK 没有可用的 arm64 Android system image"
            ))
        }
        let java = javaResolver()
        let emulatorRevision = Self.emulatorRevision(in: sdkRoot)
        let avdDirectory = layout.avdDirectory
        let configurationURL = avdDirectory.appendingPathComponent("config.ini")
        let avdExists = fileManager.fileExists(atPath: avdDirectory.path)
        let configExists = fileManager.fileExists(atPath: configurationURL.path)
        var exactImage: AndroidSystemImage?
        var fingerprintStatus: AndroidRuntimeAVDFingerprintStatus = avdExists
            ? .incompatible("avd-not-validated")
            : .notCreated
        var expectedFingerprint: AndroidRuntimeAVDCompatibilityFingerprint?

        if avdExists && !configExists {
            issues.append(.init(
                code: .incompleteAVD,
                detail: "OKVideoMac 专用 Android 环境目录不完整；未自动覆盖现有数据"
            ))
        } else if configExists {
            guard let contents = try? String(
                contentsOf: configurationURL,
                encoding: .utf8
            ), let configuredDirectory = AndroidManagedAVDConfiguration
                .systemImageDirectory(in: contents) else {
                issues.append(.init(
                    code: .invalidAVDConfiguration,
                    detail: "OKVideoMac 专用 Android 环境的 system image 配置无法读取"
                ))
                return result(
                    sdkRoot: sdkRoot,
                    toolchain: toolchain,
                    java: java,
                    image: nil,
                    images: images,
                    layout: layout,
                    avdExists: avdExists,
                    configExists: configExists,
                    fingerprintStatus: fingerprintStatus,
                    expectedFingerprint: nil,
                    emulatorRevision: emulatorRevision,
                    issues: issues
                )
            }
            exactImage = images.first(where: {
                AndroidManagedAVDConfiguration.normalizedSystemImageDirectory(
                    $0.actualRelativeDirectory
                ) == configuredDirectory
            })
            guard let image = exactImage else {
                issues.append(.init(
                    code: .avdSystemImageMissingFromSelectedSDK,
                    detail: "专用 Android 环境引用的 system image 不在所选 SDK 中"
                ))
                return result(
                    sdkRoot: sdkRoot,
                    toolchain: toolchain,
                    java: java,
                    image: nil,
                    images: images,
                    layout: layout,
                    avdExists: avdExists,
                    configExists: configExists,
                    fingerprintStatus: fingerprintStatus,
                    expectedFingerprint: nil,
                    emulatorRevision: emulatorRevision,
                    issues: issues
                )
            }
            if !Self.avdConfiguration(contents, matches: image) {
                issues.append(.init(
                    code: .avdSystemImageMismatch,
                    detail: "专用 Android 环境的 API、ABI、tag 与 system image 元数据不一致"
                ))
            }
            let expected = Self.externalFingerprint(
                sdkRoot: sdkRoot,
                image: image,
                emulatorRevision: emulatorRevision
            )
            expectedFingerprint = expected
            fingerprintStatus = AndroidRuntimeAVDFingerprintStore(
                layout: layout,
                fileManager: fileManager
            ).inspect(
                expected: expected,
                hasAVD: true,
                legacyManagedManifestExists: fileManager.fileExists(
                    atPath: layout.avdManifest.path
                )
            )
            if case .incompatible(let reason) = fingerprintStatus {
                issues.append(.init(
                    code: .incompatibleAVDFingerprint,
                    detail: "专用 Android 环境与现有 SDK 不兼容（\(reason)）；未修改 userdata"
                ))
            }
        } else {
            exactImage = images.first
        }

        return result(
            sdkRoot: sdkRoot,
            toolchain: toolchain,
            java: java,
            image: exactImage,
            images: images,
            layout: layout,
            avdExists: avdExists,
            configExists: configExists,
            fingerprintStatus: fingerprintStatus,
            expectedFingerprint: expectedFingerprint,
            emulatorRevision: emulatorRevision,
            issues: issues
        )
    }

    private func unavailable(
        sdkRoot: URL,
        layout: AndroidRuntimeLayout,
        issues: [ExternalAndroidRuntimeIssue]
    ) -> ExternalAndroidRuntimeValidation {
        ExternalAndroidRuntimeValidation(
            sdkRoot: sdkRoot,
            toolchain: nil,
            javaRuntime: nil,
            systemImage: nil,
            launchCapability: .init(
                available: false,
                detail: issues.first?.detail ?? "无法启动"
            ),
            createRepairCapability: .init(
                available: false,
                detail: issues.first?.detail ?? "无法创建或修复"
            ),
            avdExists: fileManager.fileExists(atPath: layout.avdDirectory.path),
            avdConfigurationExists: false,
            avdFingerprintStatus: .notCreated,
            expectedAVDFingerprint: nil,
            emulatorRevision: nil,
            issues: issues
        )
    }

    private func result(
        sdkRoot: URL,
        toolchain: AndroidToolchain?,
        java: AndroidJavaRuntime?,
        image: AndroidSystemImage?,
        images: [AndroidSystemImage],
        layout: AndroidRuntimeLayout,
        avdExists: Bool,
        configExists: Bool,
        fingerprintStatus: AndroidRuntimeAVDFingerprintStatus,
        expectedFingerprint: AndroidRuntimeAVDCompatibilityFingerprint?,
        emulatorRevision: String?,
        issues: [ExternalAndroidRuntimeIssue]
    ) -> ExternalAndroidRuntimeValidation {
        let launchBlockingCodes: Set<ExternalAndroidRuntimeIssueCode> = [
            .missingSDKRoot, .missingADB, .adbNotExecutable,
            .unsupportedADBArchitecture, .missingEmulator,
            .emulatorNotExecutable, .unsupportedEmulatorArchitecture,
            .missingInteractiveSystemImage, .incompleteAVD,
            .invalidAVDConfiguration, .avdSystemImageMissingFromSelectedSDK,
            .avdSystemImageMismatch, .incompatibleAVDFingerprint
        ]
        let launchIssue = issues.first { launchBlockingCodes.contains($0.code) }
        let launchAvailable = configExists
            && toolchain != nil
            && image != nil
            && launchIssue == nil

        var createIssues = issues.filter { issue in
            switch issue.code {
            case .missingSDKRoot, .missingADB, .adbNotExecutable,
                 .unsupportedADBArchitecture, .missingEmulator,
                 .emulatorNotExecutable, .unsupportedEmulatorArchitecture,
                 .missingInteractiveSystemImage:
                return true
            default:
                return false
            }
        }
        if toolchain?.avdManager == nil {
            createIssues.append(.init(
                code: .missingAVDManager,
                detail: "创建或修复专用 Android 环境需要 avdmanager"
            ))
        }
        if java == nil {
            createIssues.append(.init(
                code: .missingJava,
                detail: "创建或修复专用 Android 环境需要 Java Runtime"
            ))
        }
        let createAvailable = toolchain != nil
            && !images.isEmpty
            && createIssues.isEmpty
        let combinedIssues = issues + createIssues.filter {
            !issues.contains($0)
        }
        return ExternalAndroidRuntimeValidation(
            sdkRoot: sdkRoot,
            toolchain: toolchain,
            javaRuntime: java,
            systemImage: image,
            launchCapability: .init(
                available: launchAvailable,
                detail: launchAvailable
                    ? "现有专用 Android 环境可直接启动"
                    : (launchIssue?.detail ?? "尚未创建专用 Android 环境")
            ),
            createRepairCapability: .init(
                available: createAvailable,
                detail: createAvailable
                    ? "可以创建或修复专用 Android 环境"
                    : (createIssues.first?.detail ?? "无法创建或修复")
            ),
            avdExists: avdExists,
            avdConfigurationExists: configExists,
            avdFingerprintStatus: fingerprintStatus,
            expectedAVDFingerprint: expectedFingerprint,
            emulatorRevision: emulatorRevision,
            issues: combinedIssues
        )
    }

    private func inspectExecutable(
        _ url: URL,
        missing: ExternalAndroidRuntimeIssueCode,
        notExecutable: ExternalAndroidRuntimeIssueCode,
        unsupportedArchitecture: ExternalAndroidRuntimeIssueCode,
        label: String,
        issues: inout [ExternalAndroidRuntimeIssue]
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            issues.append(.init(code: missing, detail: "所选 SDK 缺少 \(label)"))
            return
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            issues.append(.init(
                code: notExecutable,
                detail: "所选 SDK 的 \(label) 没有执行权限"
            ))
            return
        }
        guard architectureInspector(url) else {
            issues.append(.init(
                code: unsupportedArchitecture,
                detail: "所选 SDK 的 \(label) 不支持当前 Mac 架构"
            ))
            return
        }
    }

    static func avdConfiguration(
        _ contents: String,
        matches image: AndroidSystemImage
    ) -> Bool {
        AndroidManagedAVDConfiguration.matches(image, contents: contents)
            && AndroidManagedAVDConfiguration.value(
                for: "abi.type",
                in: contents
            ) == image.architecture
            && AndroidManagedAVDConfiguration.value(
                for: "tag.id",
                in: contents
            ) == image.variant
            && AndroidManagedAVDConfiguration.targetAPILevel(in: contents)
                == image.apiLevel
    }

    static func externalFingerprint(
        sdkRoot: URL,
        image: AndroidSystemImage,
        emulatorRevision: String?
    ) -> AndroidRuntimeAVDCompatibilityFingerprint {
        AndroidRuntimeAVDCompatibilityFingerprint(
            avdSchema: 1,
            runtimeSource: .external,
            runtimeIdentity: "external:" + sha256(
                sdkRoot.standardizedFileURL.resolvingSymlinksInPath().path
            ),
            systemImagePackageID: image.packageID,
            apiLevel: image.apiLevel,
            abi: image.architecture,
            tag: image.variant,
            emulatorRevision: emulatorRevision
        )
    }

    static func managedFingerprint(
        selection: ManagedRuntimeSelection,
        descriptor: RuntimeGenerationDescriptor
    ) -> AndroidRuntimeAVDCompatibilityFingerprint? {
        guard let packageID = descriptor.systemImagePackageID,
              let apiLevel = descriptor.apiLevel else {
            return nil
        }
        let parts = packageID.split(separator: ";").map(String.init)
        guard parts.count == 4 else { return nil }
        return AndroidRuntimeAVDCompatibilityFingerprint(
            avdSchema: descriptor.avdSchema,
            runtimeSource: .managed,
            runtimeIdentity: "managed:\(selection.generationID.rawValue)",
            systemImagePackageID: packageID,
            apiLevel: apiLevel,
            abi: parts[3],
            tag: parts[2],
            emulatorRevision: emulatorRevision(in: selection.sdkRoot)
        )
    }

    static func emulatorRevision(in sdkRoot: URL) -> String? {
        let source = sdkRoot.appendingPathComponent("emulator/source.properties")
        guard let contents = try? String(contentsOf: source, encoding: .utf8)
        else { return nil }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "Pkg.Revision"
            else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func hostCanExecute(_ url: URL) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["-b", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0,
              let text = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              )?.lowercased() else { return false }
        #if arch(arm64)
        return text.contains("arm64") || text.contains("aarch64")
        #elseif arch(x86_64)
        return text.contains("x86_64")
        #else
        return false
        #endif
    }
}

struct AndroidRuntimeModeSnapshot: Equatable, Sendable {
    let mode: AndroidRuntimeMode
    let selectionSource: AndroidRuntimeSelectionSource
    let externalSDKRoot: URL?
    let externalValidation: ExternalAndroidRuntimeValidation?
    let managedRuntimeUsable: Bool

    static let initial = AndroidRuntimeModeSnapshot(
        mode: .managed,
        selectionSource: .newUserDefault,
        externalSDKRoot: nil,
        externalValidation: nil,
        managedRuntimeUsable: false
    )
}

struct AndroidRuntimeModeDiagnosticReport: Codable, Equatable, Sendable {
    let mode: String
    let selectionSource: String
    let migrationVersion: Int
    let selectionRevision: Int
    let managedRuntimeUsable: Bool
    let externalSDKConfigured: Bool
    let externalSDKRoot: String?
    let externalValidationState: String
    let externalLaunchCapability: Bool?
    let externalCreateRepairCapability: Bool?
    let adbPath: String?
    let emulatorPath: String?
    let javaSource: String?
    let systemImagePackageID: String?
    let systemImageAPILevel: Int?
    let systemImageABI: String?
    let avdPath: String
    let avdFingerprintStatus: String?
}

enum AndroidRuntimeModeCoordinatorError: LocalizedError, Equatable {
    case externalNotConfigured
    case externalUnavailable(String)
    case incompatibleAVD(String)
    case runtimeMustStop
    case runtimeSelectionChanged
    case managedRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case .externalNotConfigured:
            return "尚未选择现有 Android SDK"
        case .externalUnavailable(let reason):
            return "现有 Android SDK 当前不可用：\(reason)"
        case .incompatibleAVD(let reason):
            return "专用 Android 环境与当前运行环境不兼容（\(reason)）。为保护登录数据，未自动删除或重建。"
        case .runtimeMustStop:
            return "切换 Android 运行环境前，请先停止当前 Android 兼容模块"
        case .runtimeSelectionChanged:
            return "Android 运行环境选择已变化，请重试"
        case .managedRuntimeUnavailable:
            return "OKVideoMac 托管 Android 环境当前不可用"
        }
    }
}

actor AndroidRuntimeModeCoordinator {
    typealias ManagedUsability = @Sendable () -> Bool
    typealias ManagedAdmission = @Sendable () async throws -> Void
    typealias ManagedCancellation = @Sendable () async -> Void
    typealias ManagedAVDAdmission = @Sendable () throws -> Void
    typealias SessionConfiguration = @Sendable (
        AndroidRuntimeMode,
        URL?
    ) async -> Void
    typealias SessionStatus = @Sendable () async -> AndroidRuntimeStatus

    private let store: AndroidRuntimeModeStore
    private let layout: AndroidRuntimeLayout
    private let catalog: RuntimeCatalog
    private let externalValidator: ExternalAndroidRuntimeValidator
    private let managedUsability: ManagedUsability
    private let ensureManagedReady: ManagedAdmission
    private let cancelManagedAdmission: ManagedCancellation
    private let managedAVDAdmission: ManagedAVDAdmission?
    private let configureSession: SessionConfiguration
    private let sessionStatus: SessionStatus
    private var record: AndroidRuntimeModeRecord
    private var lastExternalValidation: ExternalAndroidRuntimeValidation?

    init(
        store: AndroidRuntimeModeStore,
        layout: AndroidRuntimeLayout,
        catalog: RuntimeCatalog,
        externalValidator: ExternalAndroidRuntimeValidator,
        managedRuntimeUsableAtMigration: Bool,
        managedUsability: @escaping ManagedUsability,
        ensureManagedReady: @escaping ManagedAdmission,
        cancelManagedAdmission: @escaping ManagedCancellation,
        managedAVDAdmission: ManagedAVDAdmission? = nil,
        configureSession: @escaping SessionConfiguration,
        sessionStatus: @escaping SessionStatus
    ) throws {
        self.store = store
        self.layout = layout
        self.catalog = catalog
        self.externalValidator = externalValidator
        self.managedUsability = managedUsability
        self.ensureManagedReady = ensureManagedReady
        self.cancelManagedAdmission = cancelManagedAdmission
        self.managedAVDAdmission = managedAVDAdmission
        self.configureSession = configureSession
        self.sessionStatus = sessionStatus
        record = try store.loadOrMigrate(
            managedRuntimeUsable: managedRuntimeUsableAtMigration
        )
    }

    func prepareRuntime() async throws {
        while true {
            let admitted = record
            switch admitted.mode {
            case .managed:
                await configureSession(.managed, nil)
                do {
                    try await ensureManagedReady()
                } catch {
                    if record.revision != admitted.revision {
                        continue
                    }
                    throw error
                }
                guard record.revision == admitted.revision,
                      record.mode == .managed else {
                    continue
                }
                if let managedAVDAdmission {
                    try managedAVDAdmission()
                } else {
                    try validateAndAdoptManagedAVD()
                }
                return

            case .external:
                guard let root = admitted.externalSDKRoot.map({
                    URL(fileURLWithPath: $0, isDirectory: true)
                }) else {
                    throw AndroidRuntimeModeCoordinatorError
                        .externalNotConfigured
                }
                let validation = externalValidator.validate(sdkRoot: root)
                lastExternalValidation = validation
                guard validation.canPrepareRuntime else {
                    throw AndroidRuntimeModeCoordinatorError
                        .externalUnavailable(validation.userFacingStatus)
                }
                if validation.avdConfigurationExists,
                   let expected = validation.expectedAVDFingerprint {
                    try AndroidRuntimeAVDFingerprintStore(
                        layout: layout,
                        fileManager: .default
                    ).adoptOrRefresh(
                        expected,
                        status: validation.avdFingerprintStatus
                    )
                }
                guard record.revision == admitted.revision,
                      record.mode == .external else {
                    continue
                }
                await configureSession(.external, validation.sdkRoot)
                guard record.revision == admitted.revision,
                      record.mode == .external else {
                    continue
                }
                return
            }
        }
    }

    /// Explicit recoverable rebuilds are allowed to proceed when normal
    /// launch compatibility is the problem, but only if the selected
    /// environment has every create/repair dependency.
    func prepareRuntimeRepair() async throws {
        switch record.mode {
        case .managed:
            await configureSession(.managed, nil)
            try await ensureManagedReady()
        case .external:
            guard let path = record.externalSDKRoot else {
                throw AndroidRuntimeModeCoordinatorError.externalNotConfigured
            }
            let validation = externalValidator.validate(
                sdkRoot: URL(fileURLWithPath: path, isDirectory: true)
            )
            lastExternalValidation = validation
            guard validation.createRepairCapability.available else {
                throw AndroidRuntimeModeCoordinatorError.externalUnavailable(
                    validation.createRepairCapability.detail
                )
            }
            await configureSession(.external, validation.sdkRoot)
        }
    }

    func refresh() async -> AndroidRuntimeModeSnapshot {
        while true {
            let admitted = record
            let validation: ExternalAndroidRuntimeValidation?
            if admitted.mode == .external,
               let path = admitted.externalSDKRoot {
                validation = externalValidator.validate(
                    sdkRoot: URL(fileURLWithPath: path, isDirectory: true)
                )
                await configureSession(.external, validation?.sdkRoot)
            } else {
                // Managed mode must not inspect or execute external tools
                // during routine refresh. A configured path is validated only
                // after an explicit user action or when External is selected.
                validation = nil
                await configureSession(.managed, nil)
            }
            guard record.revision == admitted.revision,
                  record.mode == admitted.mode else {
                continue
            }
            lastExternalValidation = validation
            return snapshot(validation: validation)
        }
    }

    func previewExternalSDK(
        _ url: URL
    ) -> ExternalAndroidRuntimeValidation {
        externalValidator.validate(sdkRoot: url)
    }

    func useExternalSDK(
        _ url: URL
    ) async throws -> AndroidRuntimeModeSnapshot {
        let validation = externalValidator.validate(sdkRoot: url)
        guard validation.canSelectEnvironment else {
            throw AndroidRuntimeModeCoordinatorError.externalUnavailable(
                validation.userFacingStatus
            )
        }
        try await requireStoppedForChange(
            newMode: .external,
            newExternalRoot: validation.sdkRoot
        )
        let previousMode = record.mode
        record = try store.committing(
            record,
            mode: .external,
            externalSDKRoot: validation.sdkRoot,
            source: .userSelectedExternal
        )
        lastExternalValidation = validation
        await configureSession(.external, validation.sdkRoot)
        if previousMode == .managed {
            // Wakes any Dex request suspended in Managed admission. Its
            // coordinator loop observes the new revision and reroutes it.
            await cancelManagedAdmission()
        }
        return snapshot(validation: validation)
    }

    func useConfiguredExternalSDK() async throws -> AndroidRuntimeModeSnapshot {
        guard let path = record.externalSDKRoot else {
            throw AndroidRuntimeModeCoordinatorError.externalNotConfigured
        }
        return try await useExternalSDK(
            URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    func useManagedRuntime() async throws -> AndroidRuntimeModeSnapshot {
        try await requireStoppedForChange(
            newMode: .managed,
            newExternalRoot: nil
        )
        if record.mode != .managed {
            record = try store.committing(
                record,
                mode: .managed,
                externalSDKRoot: nil,
                source: .userSelectedManaged
            )
        }
        lastExternalValidation = nil
        await configureSession(.managed, nil)
        return snapshot(validation: nil)
    }

    func currentSnapshot() -> AndroidRuntimeModeSnapshot {
        snapshot(validation: record.mode == .external
            ? lastExternalValidation
            : nil)
    }

    func diagnosticReport() -> AndroidRuntimeModeDiagnosticReport {
        let validation = record.mode == .external
            ? lastExternalValidation
            : nil
        return AndroidRuntimeModeDiagnosticReport(
            mode: record.mode.rawValue,
            selectionSource: record.selectionSource.rawValue,
            migrationVersion: record.migrationVersion,
            selectionRevision: record.revision,
            managedRuntimeUsable: managedUsability(),
            externalSDKConfigured: record.externalSDKRoot != nil,
            externalSDKRoot: record.externalSDKRoot.map {
                Self.redactedExternalSDKRoot($0)
            },
            externalValidationState: validation.map {
                $0.canPrepareRuntime ? "usable" : "invalid"
            } ?? (record.mode == .managed
                ? "not-inspected-in-managed-mode"
                : "not-validated"),
            externalLaunchCapability: validation?.launchCapability.available,
            externalCreateRepairCapability:
                validation?.createRepairCapability.available,
            adbPath: validation?.toolchain.map { _ in
                "<external-sdk>/platform-tools/adb"
            },
            emulatorPath: validation?.toolchain.map { _ in
                "<external-sdk>/emulator/emulator"
            },
            javaSource: validation?.javaRuntime?.source,
            systemImagePackageID: validation?.systemImage?.packageID,
            systemImageAPILevel: validation?.systemImage?.apiLevel,
            systemImageABI: validation?.systemImage?.architecture,
            avdPath: "<app-support>/AndroidRuntime/avd/OKVideoMac_Runtime.avd",
            avdFingerprintStatus:
                validation?.avdFingerprintStatus.diagnosticName
        )
    }

    private func requireStoppedForChange(
        newMode: AndroidRuntimeMode,
        newExternalRoot: URL?
    ) async throws {
        let sameMode = record.mode == newMode
        let sameRoot: Bool
        if newMode == .external {
            sameRoot = record.externalSDKRoot == newExternalRoot.map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
            }
        } else {
            sameRoot = true
        }
        if sameMode && sameRoot { return }
        let status = await sessionStatus()
        switch status.phase {
        case .running, .starting, .stopping:
            throw AndroidRuntimeModeCoordinatorError.runtimeMustStop
        case .checking, .stopped, .failed, .unavailable:
            return
        }
    }

    private func validateAndAdoptManagedAVD() throws {
        let selection: ManagedRuntimeSelection
        do {
            selection = try ManagedRuntimeSelection.resolve(
                layout: layout,
                catalog: catalog
            )
        } catch {
            throw AndroidRuntimeModeCoordinatorError.managedRuntimeUnavailable
        }
        guard let descriptor = catalog.generations.first(where: {
            $0.generationID == selection.generationID
        }), let expected = ExternalAndroidRuntimeValidator.managedFingerprint(
            selection: selection,
            descriptor: descriptor
        ) else {
            throw AndroidRuntimeModeCoordinatorError.managedRuntimeUnavailable
        }
        let configURL = layout.avdDirectory.appendingPathComponent("config.ini")
        let hasAVD = FileManager.default.fileExists(
            atPath: layout.avdDirectory.path
        )
        guard hasAVD else { return }
        guard let contents = try? String(
            contentsOf: configURL,
            encoding: .utf8
        ) else {
            throw AndroidRuntimeModeCoordinatorError.incompatibleAVD(
                "avd-configuration-unreadable"
            )
        }
        let expectedDirectory = expected.systemImagePackageID
            .split(separator: ";").joined(separator: "/")
        guard AndroidManagedAVDConfiguration.systemImageDirectory(in: contents)
                == expectedDirectory,
              AndroidManagedAVDConfiguration.value(
                  for: "abi.type",
                  in: contents
              ) == expected.abi,
              AndroidManagedAVDConfiguration.value(
                  for: "tag.id",
                  in: contents
              ) == expected.tag,
              AndroidManagedAVDConfiguration.targetAPILevel(in: contents)
                == expected.apiLevel,
              FileManager.default.fileExists(
                  atPath: selection.systemImage.path
              ) else {
            throw AndroidRuntimeModeCoordinatorError.incompatibleAVD(
                "managed-system-image-mismatch"
            )
        }
        let fingerprintStore = AndroidRuntimeAVDFingerprintStore(
            layout: layout,
            fileManager: .default
        )
        let status = fingerprintStore.inspect(
            expected: expected,
            hasAVD: true,
            legacyManagedManifestExists: FileManager.default.fileExists(
                atPath: layout.avdManifest.path
            )
        )
        try fingerprintStore.adoptOrRefresh(expected, status: status)
    }

    private func snapshot(
        validation: ExternalAndroidRuntimeValidation?
    ) -> AndroidRuntimeModeSnapshot {
        AndroidRuntimeModeSnapshot(
            mode: record.mode,
            selectionSource: record.selectionSource,
            externalSDKRoot: record.externalSDKRoot.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            externalValidation: validation,
            managedRuntimeUsable: managedUsability()
        )
    }

    private static func redactedExternalSDKRoot(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        if path == home { return "<home>" }
        if path.hasPrefix(home + "/") {
            return "<home>/" + path.dropFirst(home.count + 1)
        }
        return "<external-sdk>/" + URL(fileURLWithPath: path)
            .lastPathComponent
    }
}
