import Foundation

public enum RuntimePurityRole: String, Codable, CaseIterable, Sendable {
    case java
    case sdkManager
    case avdManager
    case adb
    case emulator
    case systemImage
    case avd
    case adbKey
    case androidHome = "ANDROID_HOME"
    case androidSDKRoot = "ANDROID_SDK_ROOT"
    case androidAVDHome = "ANDROID_AVD_HOME"
    case androidUserHome = "ANDROID_USER_HOME"
    case androidEmulatorHome = "ANDROID_EMULATOR_HOME"
    case adbVendorKeys = "ADB_VENDOR_KEYS"
    case processHome = "HOME"
    case adbServer
}

public enum RuntimePurityState: String, Codable, Sendable {
    case managed
    case missing
    case external
    case mismatched
}

public struct RuntimePurityEntry: Codable, Equatable, Sendable {
    public let role: RuntimePurityRole
    public let state: RuntimePurityState
    public let location: String

    public init(
        role: RuntimePurityRole,
        state: RuntimePurityState,
        location: String
    ) {
        self.role = role
        self.state = state
        self.location = location
    }
}

public struct RuntimePurityReport: Codable, Equatable, Sendable {
    public let passed: Bool
    public let generationID: RuntimeGenerationID
    public let entries: [RuntimePurityEntry]

    public init(
        passed: Bool,
        generationID: RuntimeGenerationID,
        entries: [RuntimePurityEntry]
    ) {
        self.passed = passed
        self.generationID = generationID
        self.entries = entries
    }
}

public struct ManagedRuntimeEnvironmentSnapshot: Sendable {
    public let generationID: RuntimeGenerationID
    public let java: URL?
    public let sdkManager: URL?
    public let avdManager: URL?
    public let adb: URL?
    public let emulator: URL?
    public let systemImage: URL?
    public let avd: URL?
    public let adbKey: URL?
    public let environment: [String: String]
    public let expectedPrivateADBServerPort: Int
    public let actualADBServerPort: Int?
    public let adbServerOwned: Bool

    public init(
        generationID: RuntimeGenerationID,
        java: URL?,
        sdkManager: URL?,
        avdManager: URL?,
        adb: URL?,
        emulator: URL?,
        systemImage: URL?,
        avd: URL?,
        adbKey: URL?,
        environment: [String: String],
        expectedPrivateADBServerPort: Int,
        actualADBServerPort: Int?,
        adbServerOwned: Bool
    ) {
        self.generationID = generationID
        self.java = java
        self.sdkManager = sdkManager
        self.avdManager = avdManager
        self.adb = adb
        self.emulator = emulator
        self.systemImage = systemImage
        self.avd = avd
        self.adbKey = adbKey
        self.environment = environment
        self.expectedPrivateADBServerPort = expectedPrivateADBServerPort
        self.actualADBServerPort = actualADBServerPort
        self.adbServerOwned = adbServerOwned
    }
}

/// Produces the public-release "Managed Environment Purity" gate. Reports
/// expose only redacted managed-relative locations or `<external>`; user paths
/// never become diagnostic payloads.
public struct ManagedRuntimePurityChecker: Sendable {
    public let layout: AndroidRuntimeLayout

    public init(layout: AndroidRuntimeLayout) {
        self.layout = layout
    }

    public func evaluate(
        _ snapshot: ManagedRuntimeEnvironmentSnapshot,
        requireRunningADBServer: Bool = true
    ) -> RuntimePurityReport {
        guard snapshot.generationID.isValid,
              let boundary = try? ManagedRuntimePathBoundary(root: layout.root)
        else {
            return RuntimePurityReport(
                passed: false,
                generationID: snapshot.generationID,
                entries: RuntimePurityRole.allCases.map {
                    RuntimePurityEntry(
                        role: $0,
                        state: .mismatched,
                        location: "<invalid-runtime-root>"
                    )
                }
            )
        }

        let generation = layout.generation(snapshot.generationID)
        var entries: [RuntimePurityEntry] = []
        entries.append(pathEntry(
            .java,
            observed: snapshot.java,
            expectedRoot: generation.jre,
            boundary: boundary
        ))
        for (role, path) in [
            (RuntimePurityRole.sdkManager, snapshot.sdkManager),
            (.avdManager, snapshot.avdManager),
            (.adb, snapshot.adb),
            (.emulator, snapshot.emulator),
            (.systemImage, snapshot.systemImage)
        ] {
            entries.append(pathEntry(
                role,
                observed: path,
                expectedRoot: generation.sdk,
                boundary: boundary
            ))
        }
        entries.append(pathEntry(
            .avd,
            observed: snapshot.avd,
            expectedRoot: layout.avdHome,
            boundary: boundary
        ))
        entries.append(pathEntry(
            .adbKey,
            observed: snapshot.adbKey,
            expectedRoot: layout.privateAndroidHome,
            boundary: boundary
        ))

        let exactEnvironment: [
            (RuntimePurityRole, String, URL)
        ] = [
            (.androidHome, "ANDROID_HOME", generation.sdk),
            (.androidSDKRoot, "ANDROID_SDK_ROOT", generation.sdk),
            (.androidAVDHome, "ANDROID_AVD_HOME", layout.avdHome),
            (
                .androidUserHome,
                "ANDROID_USER_HOME",
                layout.privateAndroidHome
            ),
            (
                .androidEmulatorHome,
                "ANDROID_EMULATOR_HOME",
                layout.privateAndroidHome
            ),
            (.adbVendorKeys, "ADB_VENDOR_KEYS", layout.privateADBKey),
            (.processHome, "HOME", layout.privateHome)
        ]
        for (role, key, expected) in exactEnvironment {
            entries.append(environmentEntry(
                role,
                value: snapshot.environment[key],
                expected: expected,
                boundary: boundary
            ))
        }

        let adbServerState: RuntimePurityState
        if snapshot.actualADBServerPort == nil && !requireRunningADBServer {
            adbServerState = .managed
        } else if snapshot.actualADBServerPort == nil {
            adbServerState = .missing
        } else if snapshot.actualADBServerPort
                    != snapshot.expectedPrivateADBServerPort
                    || !snapshot.adbServerOwned {
            adbServerState = .mismatched
        } else {
            adbServerState = .managed
        }
        entries.append(RuntimePurityEntry(
            role: .adbServer,
            state: adbServerState,
            location: snapshot.actualADBServerPort.map {
                "private-port:\($0)"
            } ?? (requireRunningADBServer ? "<missing>" : "private-port:pending")
        ))

        return RuntimePurityReport(
            passed: entries.allSatisfy { $0.state == .managed },
            generationID: snapshot.generationID,
            entries: entries
        )
    }

    private func pathEntry(
        _ role: RuntimePurityRole,
        observed: URL?,
        expectedRoot: URL,
        boundary: ManagedRuntimePathBoundary
    ) -> RuntimePurityEntry {
        guard let observed else {
            return RuntimePurityEntry(
                role: role,
                state: .missing,
                location: "<missing>"
            )
        }
        let state: RuntimePurityState
        if !boundary.contains(observed) {
            state = .external
        } else if Self.isDescendantOrEqual(
            observed.standardizedFileURL.resolvingSymlinksInPath(),
            root: expectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        ) {
            state = .managed
        } else {
            state = .mismatched
        }
        return RuntimePurityEntry(
            role: role,
            state: state,
            location: boundary.redactedLocation(for: observed)
        )
    }

    private func environmentEntry(
        _ role: RuntimePurityRole,
        value: String?,
        expected: URL,
        boundary: ManagedRuntimePathBoundary
    ) -> RuntimePurityEntry {
        guard let value, !value.isEmpty else {
            return RuntimePurityEntry(
                role: role,
                state: .missing,
                location: "<missing>"
            )
        }
        let observed = URL(fileURLWithPath: value)
        let state: RuntimePurityState
        if !boundary.contains(observed) {
            state = .external
        } else if observed.standardizedFileURL.resolvingSymlinksInPath()
                    == expected.standardizedFileURL.resolvingSymlinksInPath() {
            state = .managed
        } else {
            state = .mismatched
        }
        return RuntimePurityEntry(
            role: role,
            state: state,
            location: boundary.redactedLocation(for: observed)
        )
    }

    private static func isDescendantOrEqual(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return candidateComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }
}
