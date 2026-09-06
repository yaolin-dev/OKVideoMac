import Foundation

public enum RuntimeCandidateEnvironmentProfile: String, Codable, Sendable {
    /// No Android Studio, Homebrew Android tools, host JRE, or user SDK is
    /// available to the process running the eventual managed installer.
    case clean
    /// Android Studio, Homebrew Android tools, and/or unrelated JREs exist.
    /// The matrix run must still prove that every selected tool is explicit.
    case contaminated
}

public enum RuntimeCandidatePhase: String, Codable, CaseIterable, Sendable {
    case preflight
    case avdCreation
    case coldBootADBOnline
    case coldBootCompleted
    case bridgeInstall
    case bridgeStart
    case bridgeHealth
    case dexSpiderInvocation
    case idleResourceSample
    case firstShutdown
    case reuseBootADBOnline
    case reuseBootCompleted
    case bridgeReuseHealth
    case finalShutdown
    case environmentPurity
}

public enum RuntimeCandidatePhaseOutcome: String, Codable, Sendable {
    case passed
    case failed
    case skipped
}

public struct RuntimeCandidatePhaseResult: Codable, Equatable, Sendable {
    public let phase: RuntimeCandidatePhase
    public let outcome: RuntimeCandidatePhaseOutcome
    public let durationSeconds: Double?
    public let detail: String

    public init(
        phase: RuntimeCandidatePhase,
        outcome: RuntimeCandidatePhaseOutcome,
        durationSeconds: Double? = nil,
        detail: String
    ) {
        self.phase = phase
        self.outcome = outcome
        self.durationSeconds = durationSeconds
        self.detail = detail
    }
}

public enum RuntimeCandidateADBState: String, Codable, Sendable {
    case missing
    case offline
    case unauthorized
    case device
    case other
}

public struct RuntimeCandidateADBObservation: Codable, Equatable, Sendable {
    public let elapsedSeconds: Double
    public let targetState: RuntimeCandidateADBState
    /// Device serials and states only. Product/user paths and device details
    /// are deliberately excluded from the persistent matrix report.
    public let devices: [String]
    public let emulatorAlive: Bool

    public init(
        elapsedSeconds: Double,
        targetState: RuntimeCandidateADBState,
        devices: [String],
        emulatorAlive: Bool
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.targetState = targetState
        self.devices = devices
        self.emulatorAlive = emulatorAlive
    }
}

public struct RuntimeCandidateResourceSample: Codable, Equatable, Sendable {
    public let elapsedSeconds: Double
    public let residentMemoryBytes: Int64
    public let cpuPercent: Double

    public init(
        elapsedSeconds: Double,
        residentMemoryBytes: Int64,
        cpuPercent: Double
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuPercent = cpuPercent
    }
}

public struct RuntimeCandidateHostDescriptor: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let macOSMajorVersion: Int
    public let architecture: String
    public let hardwareModel: String
    public let environmentProfile: RuntimeCandidateEnvironmentProfile

    public init(
        macOSVersion: String,
        macOSMajorVersion: Int,
        architecture: String,
        hardwareModel: String,
        environmentProfile: RuntimeCandidateEnvironmentProfile
    ) {
        self.macOSVersion = macOSVersion
        self.macOSMajorVersion = macOSMajorVersion
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.environmentProfile = environmentProfile
    }
}

public struct RuntimeCandidateToolchainDescriptor:
    Codable, Equatable, Sendable {
    public let javaVersion: String
    public let commandLineToolsVersion: String
    public let adbVersion: String
    public let emulatorVersion: String
    public let systemImagePackageID: String
    public let bridgeSHA256: String

    public init(
        javaVersion: String,
        commandLineToolsVersion: String,
        adbVersion: String,
        emulatorVersion: String,
        systemImagePackageID: String,
        bridgeSHA256: String
    ) {
        self.javaVersion = javaVersion
        self.commandLineToolsVersion = commandLineToolsVersion
        self.adbVersion = adbVersion
        self.emulatorVersion = emulatorVersion
        self.systemImagePackageID = systemImagePackageID
        self.bridgeSHA256 = bridgeSHA256
    }
}

public struct RuntimeCandidateEvaluationReport:
    Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schema: Int
    public let runID: String
    public let candidate: RuntimeCandidate
    public let startedAt: Date
    public let completedAt: Date
    public let host: RuntimeCandidateHostDescriptor
    public let toolchain: RuntimeCandidateToolchainDescriptor
    public let phases: [RuntimeCandidatePhaseResult]
    public let adbTimeline: [RuntimeCandidateADBObservation]
    public let resourceSamples: [RuntimeCandidateResourceSample]
    public let purityReport: RuntimePurityReport?
    public let evidenceDirectory: String

    public init(
        schema: Int = schemaVersion,
        runID: String,
        candidate: RuntimeCandidate,
        startedAt: Date,
        completedAt: Date,
        host: RuntimeCandidateHostDescriptor,
        toolchain: RuntimeCandidateToolchainDescriptor,
        phases: [RuntimeCandidatePhaseResult],
        adbTimeline: [RuntimeCandidateADBObservation],
        resourceSamples: [RuntimeCandidateResourceSample],
        purityReport: RuntimePurityReport?,
        evidenceDirectory: String
    ) {
        self.schema = schema
        self.runID = runID
        self.candidate = candidate
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.host = host
        self.toolchain = toolchain
        self.phases = phases
        self.adbTimeline = adbTimeline
        self.resourceSamples = resourceSamples
        self.purityReport = purityReport
        self.evidenceDirectory = evidenceDirectory
    }

    public var passed: Bool {
        RuntimeCandidateReportValidator.missingRequiredPhases(in: self).isEmpty
            && phases.allSatisfy { result in
                !RuntimeCandidateReportValidator.requiredPhases.contains(
                    result.phase
                ) || result.outcome == .passed
            }
            && (purityReport?.passed ?? true)
    }
}

public enum RuntimeCandidateReportValidator {
    public static let requiredPhases = Set(RuntimeCandidatePhase.allCases)

    public static func missingRequiredPhases(
        in report: RuntimeCandidateEvaluationReport
    ) -> [RuntimeCandidatePhase] {
        let observed = Set(report.phases.map(\.phase))
        return requiredPhases.subtracting(observed).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    public static func validate(
        _ report: RuntimeCandidateEvaluationReport
    ) -> [String] {
        var failures: [String] = []
        guard report.schema == RuntimeCandidateEvaluationReport.schemaVersion
        else {
            return ["unsupported report schema \(report.schema)"]
        }
        if report.candidate.state != .evaluation {
            failures.append(
                "matrix input must remain evaluation until qualification"
            )
        }
        for phase in missingRequiredPhases(in: report) {
            failures.append("missing phase: \(phase.rawValue)")
        }
        for result in report.phases
            where requiredPhases.contains(result.phase)
                && result.outcome != .passed {
            failures.append(
                "\(result.phase.rawValue): \(result.outcome.rawValue)"
            )
        }
        if let purityReport = report.purityReport, !purityReport.passed {
            failures.append("managed environment purity did not pass")
        }
        if !report.adbTimeline.contains(where: {
            $0.targetState == .device && $0.emulatorAlive
        }) {
            failures.append("ADB timeline never observed a live device")
        }
        if report.resourceSamples.isEmpty {
            failures.append("idle resource samples are missing")
        }
        return failures
    }
}

public enum RuntimeCandidateQualificationState:
    String, Codable, Sendable {
    case pending
    case qualified
    case rejected
}

public struct RuntimeCandidateQualification: Codable, Equatable, Sendable {
    public let candidateID: String
    public let state: RuntimeCandidateQualificationState
    public let missingMacOSMajorVersions: [Int]
    public let missingEnvironmentProfiles: [RuntimeCandidateEnvironmentProfile]
    public let failures: [String]

    public init(
        candidateID: String,
        state: RuntimeCandidateQualificationState,
        missingMacOSMajorVersions: [Int],
        missingEnvironmentProfiles: [RuntimeCandidateEnvironmentProfile],
        failures: [String]
    ) {
        self.candidateID = candidateID
        self.state = state
        self.missingMacOSMajorVersions = missingMacOSMajorVersions
        self.missingEnvironmentProfiles = missingEnvironmentProfiles
        self.failures = failures
    }
}

public enum RuntimeCandidateQualifier {
    public static func qualification(
        candidateID: String,
        reports: [RuntimeCandidateEvaluationReport],
        requiredMacOSMajorVersions: Set<Int> = [12, 13, 14, 15],
        requiredProfiles: Set<RuntimeCandidateEnvironmentProfile> = [
            .clean,
            .contaminated
        ]
    ) -> RuntimeCandidateQualification {
        let matching = reports.filter { $0.candidate.id == candidateID }
        let failing = matching.flatMap { report in
            RuntimeCandidateReportValidator.validate(report).map {
                "\(report.runID): \($0)"
            }
        }
        if !failing.isEmpty {
            return RuntimeCandidateQualification(
                candidateID: candidateID,
                state: .rejected,
                missingMacOSMajorVersions: [],
                missingEnvironmentProfiles: [],
                failures: failing
            )
        }

        let successful = matching.filter(\.passed)
        let observedOS = Set(successful.map(\.host.macOSMajorVersion))
        let observedProfiles = Set(successful.map(\.host.environmentProfile))
        let missingOS = requiredMacOSMajorVersions.subtracting(observedOS)
            .sorted()
        let missingProfiles = requiredProfiles.subtracting(observedProfiles)
            .sorted { $0.rawValue < $1.rawValue }
        return RuntimeCandidateQualification(
            candidateID: candidateID,
            state: missingOS.isEmpty && missingProfiles.isEmpty
                ? .qualified
                : .pending,
            missingMacOSMajorVersions: missingOS,
            missingEnvironmentProfiles: missingProfiles,
            failures: []
        )
    }
}

public struct RuntimeCandidateExecutionPlan: Equatable, Sendable {
    public let candidate: RuntimeCandidate
    public let avdName: String
    public let consolePort: Int
    public let privateADBServerPort: Int
    public let bridgeHostPort: Int

    public init(
        candidate: RuntimeCandidate,
        avdName: String,
        consolePort: Int,
        privateADBServerPort: Int,
        bridgeHostPort: Int
    ) {
        self.candidate = candidate
        self.avdName = avdName
        self.consolePort = consolePort
        self.privateADBServerPort = privateADBServerPort
        self.bridgeHostPort = bridgeHostPort
    }
}

public enum RuntimeCandidatePlanError: LocalizedError, Equatable {
    case invalidRunID
    case invalidConsolePort
    case invalidADBServerPort
    case invalidBridgePort
    case portCollision

    public var errorDescription: String? {
        switch self {
        case .invalidRunID: return "Candidate Matrix run identifier is invalid"
        case .invalidConsolePort: return "Candidate console port is invalid"
        case .invalidADBServerPort: return "Private ADB server port is invalid"
        case .invalidBridgePort: return "Bridge host port is invalid"
        case .portCollision: return "Candidate Matrix ports collide"
        }
    }
}

public enum RuntimeCandidatePlanner {
    public static func plans(
        for candidates: [RuntimeCandidate],
        runID: String,
        firstConsolePort: Int = 5_674,
        firstADBServerPort: Int = 50_451,
        firstBridgeHostPort: Int = 29_978
    ) throws -> [RuntimeCandidateExecutionPlan] {
        let runToken = runID.filter { $0.isLetter || $0.isNumber }
        guard !runToken.isEmpty else {
            throw RuntimeCandidatePlanError.invalidRunID
        }
        var usedPorts = Set<Int>()
        return try candidates.enumerated().map { offset, candidate in
            let console = firstConsolePort + offset * 2
            let adb = firstADBServerPort + offset
            let bridge = firstBridgeHostPort + offset
            guard console >= 5_554, console <= 5_682,
                  console.isMultiple(of: 2) else {
                throw RuntimeCandidatePlanError.invalidConsolePort
            }
            guard (1...65_535).contains(adb) else {
                throw RuntimeCandidatePlanError.invalidADBServerPort
            }
            guard (1...65_535).contains(bridge) else {
                throw RuntimeCandidatePlanError.invalidBridgePort
            }
            for port in [console, console + 1, adb, bridge] {
                guard usedPorts.insert(port).inserted else {
                    throw RuntimeCandidatePlanError.portCollision
                }
            }
            let token = String(runToken.prefix(8))
            return RuntimeCandidateExecutionPlan(
                candidate: candidate,
                avdName: "OKVideoMac_Matrix_\(candidate.apiLevel)_\(token)",
                consolePort: console,
                privateADBServerPort: adb,
                bridgeHostPort: bridge
            )
        }
    }
}

public enum RuntimeCandidateWorkspaceError: LocalizedError, Equatable {
    case nonFileURL
    case unsafeWorkspace
    case overlapsProductionRuntime
    case targetEscapesWorkspace

    public var errorDescription: String? {
        switch self {
        case .nonFileURL:
            return "Candidate Matrix workspace must be a file URL"
        case .unsafeWorkspace:
            return "Candidate Matrix workspace is too broad"
        case .overlapsProductionRuntime:
            return "Candidate Matrix workspace overlaps the production Runtime"
        case .targetEscapesWorkspace:
            return "Candidate Matrix target escapes its workspace"
        }
    }
}

/// Matrix runs are disposable experiments, but their mutations still require
/// an explicit isolated root. In particular, the production AndroidRuntime
/// directory can never be a parent or child of the matrix workspace.
public struct RuntimeCandidateWorkspaceBoundary: Sendable {
    public let workspace: URL
    public let productionRuntimeRoot: URL

    public init(workspace: URL, productionRuntimeRoot: URL) throws {
        guard workspace.isFileURL, productionRuntimeRoot.isFileURL else {
            throw RuntimeCandidateWorkspaceError.nonFileURL
        }
        let workspace = Self.canonical(workspace)
        let production = Self.canonical(productionRuntimeRoot)
        let forbidden = [
            URL(fileURLWithPath: "/", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
        ].map(Self.canonical)
        guard !forbidden.contains(workspace),
              workspace.pathComponents.count >= 3 else {
            throw RuntimeCandidateWorkspaceError.unsafeWorkspace
        }
        guard !Self.contains(workspace, production),
              !Self.contains(production, workspace) else {
            throw RuntimeCandidateWorkspaceError.overlapsProductionRuntime
        }
        self.workspace = workspace
        self.productionRuntimeRoot = production
    }

    public func validateMutationTarget(_ target: URL) throws -> URL {
        guard target.isFileURL else {
            throw RuntimeCandidateWorkspaceError.nonFileURL
        }
        let canonical = Self.canonical(target)
        guard canonical != workspace,
              Self.contains(canonical, workspace) else {
            throw RuntimeCandidateWorkspaceError.targetEscapesWorkspace
        }
        return canonical
    }

    private static func contains(_ child: URL, _ parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count >= parentComponents.count else {
            return false
        }
        return childComponents.prefix(parentComponents.count)
            .elementsEqual(parentComponents)
    }

    private static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in suffix {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }
}
