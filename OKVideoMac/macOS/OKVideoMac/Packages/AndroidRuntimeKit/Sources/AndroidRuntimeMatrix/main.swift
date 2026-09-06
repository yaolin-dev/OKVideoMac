import AndroidRuntimeKit
import Darwin
import Foundation

private enum MatrixMode: String {
    case preflight
    case run
}

private struct MatrixOptions {
    let mode: MatrixMode
    let sdkRoot: URL
    let javaHome: URL
    let bridgeAPK: URL
    let fixtureJAR: URL?
    let workspace: URL
    let productionRuntimeRoot: URL
    let candidateIDs: Set<String>
    let environmentProfile: RuntimeCandidateEnvironmentProfile
    let fixturePort: Int
    let adbTimeout: TimeInterval
    let bootTimeout: TimeInterval

    static func parse(_ arguments: [String]) throws -> MatrixOptions {
        guard let modeValue = arguments.first,
              let mode = MatrixMode(rawValue: modeValue) else {
            throw MatrixCLIError.usage
        }
        var values: [String: String] = [:]
        var candidateIDs = Set<String>()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw MatrixCLIError.invalidArgument(flag)
            }
            let value = arguments[index + 1]
            if flag == "--candidate" {
                candidateIDs.insert(value)
            } else {
                guard values[flag] == nil else {
                    throw MatrixCLIError.invalidArgument(flag)
                }
                values[flag] = value
            }
            index += 2
        }
        func requiredPath(_ flag: String) throws -> URL {
            guard let value = values[flag], value.hasPrefix("/") else {
                throw MatrixCLIError.missingArgument(flag)
            }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        let defaultProductionRoot = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/OKVideoMac/AndroidRuntime",
                isDirectory: true
            )
        let profileValue = values["--environment-profile"]
            ?? RuntimeCandidateEnvironmentProfile.contaminated.rawValue
        guard let profile = RuntimeCandidateEnvironmentProfile(
            rawValue: profileValue
        ) else {
            throw MatrixCLIError.invalidArgument("--environment-profile")
        }
        let fixtureJAR = values["--fixture-jar"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if mode == .run, fixtureJAR == nil {
            throw MatrixCLIError.missingArgument("--fixture-jar")
        }
        return MatrixOptions(
            mode: mode,
            sdkRoot: try requiredPath("--sdk-root"),
            javaHome: try requiredPath("--java-home"),
            bridgeAPK: try requiredPath("--bridge-apk"),
            fixtureJAR: fixtureJAR,
            workspace: try requiredPath("--workspace"),
            productionRuntimeRoot: values["--production-runtime-root"].map {
                URL(fileURLWithPath: $0).standardizedFileURL
            } ?? defaultProductionRoot,
            candidateIDs: candidateIDs,
            environmentProfile: profile,
            fixturePort: try integer(
                values["--fixture-port"] ?? "28977",
                flag: "--fixture-port"
            ),
            adbTimeout: TimeInterval(try integer(
                values["--adb-timeout"] ?? "180",
                flag: "--adb-timeout"
            )),
            bootTimeout: TimeInterval(try integer(
                values["--boot-timeout"] ?? "240",
                flag: "--boot-timeout"
            ))
        )
    }

    private static func integer(_ value: String, flag: String) throws -> Int {
        guard let number = Int(value), number > 0 else {
            throw MatrixCLIError.invalidArgument(flag)
        }
        return number
    }
}

private enum MatrixCLIError: LocalizedError {
    case usage
    case invalidArgument(String)
    case missingArgument(String)
    case unsafe(String)
    case command(String)
    case timeout(String)
    case processExited(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return Self.usageText
        case .invalidArgument(let value):
            return "Invalid Candidate Matrix argument: \(value)"
        case .missingArgument(let value):
            return "Missing Candidate Matrix argument: \(value)"
        case .unsafe(let detail):
            return "Candidate Matrix safety check failed: \(detail)"
        case .command(let detail):
            return "Candidate Matrix command failed: \(detail)"
        case .timeout(let detail):
            return "Candidate Matrix timed out: \(detail)"
        case .processExited(let detail):
            return "Candidate Matrix process exited: \(detail)"
        case .invalidResponse(let detail):
            return "Candidate Matrix response is invalid: \(detail)"
        }
    }

    static let usageText = """
    Usage:
      android-runtime-matrix preflight|run \\
        --sdk-root /absolute/sdk \\
        --java-home /absolute/jre \\
        --bridge-apk /absolute/bridge.apk \\
        --workspace /absolute/matrix-workspace \\
        [--fixture-jar /absolute/matrix-fixture.jar] \\
        [--candidate api-35-google-apis-arm64] \\
        [--environment-profile clean|contaminated]

    The run command never installs SDK packages and never reads or mutates the
    production AVD. Install candidate images explicitly before running it.
    """
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private final class MatrixCommandRunner {
    func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: TimeInterval = 30
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        if input != nil {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        if let input {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let startedAt = Date()
        var timedOut = false
        while process.isRunning {
            if Date().timeIntervalSince(startedAt) >= timeout {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.25)
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = error.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    func checked(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: TimeInterval = 30
    ) throws -> String {
        let result = try run(
            executable,
            arguments,
            environment: environment,
            input: input,
            timeout: timeout
        )
        guard !result.timedOut else {
            throw MatrixCLIError.timeout(executable.lastPathComponent)
        }
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MatrixCLIError.command(
                "\(executable.lastPathComponent) exited \(result.status): "
                    + String(detail.suffix(1_000))
            )
        }
        return result.stdout
    }
}

private final class LoggedProcess {
    let process: Process
    private let handles: [FileHandle]

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdoutURL: URL,
        stderrURL: URL
    ) throws {
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        handles = [stdout, stderr]
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }
    var pid: Int32 { process.processIdentifier }

    func terminateOwned(grace: TimeInterval = 2) {
        guard process.isRunning else {
            closeHandles()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        closeHandles()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !process.isRunning {
            process.waitUntilExit()
            closeHandles()
            return true
        }
        return false
    }

    private func closeHandles() {
        for handle in handles { try? handle.close() }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
        closeHandles()
    }
}

private struct MatrixToolchain {
    let sdkRoot: URL
    let javaHome: URL
    let java: URL
    let sdkManager: URL
    let avdManager: URL
    let adb: URL
    let emulator: URL
}

private struct MatrixPreflightReport: Encodable {
    let schema = 1
    let generatedAt: Date
    let mode: String
    let candidates: [String]
    let installedCandidates: [String]
    let missingPackages: [String]
    let productionRuntimeObservedRunning: Bool
    let selectedTools: [String: String]
    let environmentProfile: String
    let workspace: String
    let status: String
}

private final class MatrixEvaluator {
    let options: MatrixOptions
    let toolchain: MatrixToolchain
    let host: RuntimeCandidateHostDescriptor
    let toolVersions: (
        java: String,
        commandLine: String,
        adb: String,
        emulator: String,
        bridgeSHA256: String
    )
    let runID: String
    let runRoot: URL
    let boundary: RuntimeCandidateWorkspaceBoundary
    let runner = MatrixCommandRunner()
    let redactor: (String) -> String

    init(options: MatrixOptions) throws {
        self.options = options
        boundary = try RuntimeCandidateWorkspaceBoundary(
            workspace: options.workspace,
            productionRuntimeRoot: options.productionRuntimeRoot
        )
        toolchain = try Self.resolveToolchain(options)
        runID = Self.makeRunID()
        runRoot = options.workspace
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        _ = try boundary.validateMutationTarget(runRoot)
        host = try Self.hostDescriptor(profile: options.environmentProfile)
        let sdkPath = toolchain.sdkRoot.path
        let javaPath = toolchain.javaHome.path
        let workspacePath = options.workspace.path
        let productionPath = options.productionRuntimeRoot.path
        redactor = { value in
            value
                .replacingOccurrences(of: productionPath, with: "<production-runtime>")
                .replacingOccurrences(of: workspacePath, with: "<workspace>")
                .replacingOccurrences(of: sdkPath, with: "<sdk-root>")
                .replacingOccurrences(of: javaPath, with: "<java-home>")
        }
        toolVersions = try Self.toolVersions(
            toolchain: toolchain,
            bridgeAPK: options.bridgeAPK,
            runner: runner
        )
    }

    func selectedCandidates() throws -> [RuntimeCandidate] {
        let catalog = try BundledRuntimeCatalog.load()
        if options.candidateIDs.isEmpty { return catalog.candidateMatrix }
        let candidates = catalog.candidateMatrix.filter {
            options.candidateIDs.contains($0.id)
        }
        let found = Set(candidates.map(\.id))
        let unknown = options.candidateIDs.subtracting(found)
        guard unknown.isEmpty else {
            throw MatrixCLIError.invalidArgument(
                "unknown candidate(s): \(unknown.sorted().joined(separator: ", "))"
            )
        }
        return candidates
    }

    func preflight() throws -> MatrixPreflightReport {
        let candidates = try selectedCandidates()
        let plans = try RuntimeCandidatePlanner.plans(
            for: candidates,
            runID: runID
        )
        guard (1...65_535).contains(options.fixturePort),
              !plans.flatMap({
                  [
                    $0.consolePort,
                    $0.consolePort + 1,
                    $0.privateADBServerPort,
                    $0.bridgeHostPort
                  ]
              }).contains(options.fixturePort) else {
            throw MatrixCLIError.unsafe("fixture port collides with matrix ports")
        }
        let requiredPaths = [
            toolchain.java,
            toolchain.sdkManager,
            toolchain.avdManager,
            toolchain.adb,
            toolchain.emulator,
            options.bridgeAPK
        ]
        for path in requiredPaths {
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw MatrixCLIError.unsafe("missing \(redactor(path.path))")
            }
        }
        if options.mode == .run {
            guard let fixture = options.fixtureJAR,
                  FileManager.default.fileExists(atPath: fixture.path) else {
                throw MatrixCLIError.unsafe("matrix fixture JAR is missing")
            }
            guard FileManager.default.isExecutableFile(
                atPath: "/usr/bin/python3"
            ) else {
                throw MatrixCLIError.unsafe(
                    "developer matrix HTTP server requires /usr/bin/python3"
                )
            }
        }
        for port in plans.flatMap({
            [
                $0.consolePort,
                $0.consolePort + 1,
                $0.privateADBServerPort,
                $0.bridgeHostPort
            ]
        }) + [options.fixturePort] {
            guard !Self.portIsListening(port, runner: runner) else {
                throw MatrixCLIError.unsafe("port \(port) is already listening")
            }
        }
        let installed = candidates.filter(systemImageExists).map(\.id)
        let missing = candidates.filter { !systemImageExists($0) }
            .map(Self.systemImagePackageID)
        return MatrixPreflightReport(
            generatedAt: Date(),
            mode: options.mode.rawValue,
            candidates: candidates.map(\.id),
            installedCandidates: installed,
            missingPackages: missing,
            productionRuntimeObservedRunning: productionRuntimeIsRunning(),
            selectedTools: [
                "java": "<java-home>/bin/java",
                "sdkmanager": "<sdk-root>/" + relativeToSDK(toolchain.sdkManager),
                "avdmanager": "<sdk-root>/" + relativeToSDK(toolchain.avdManager),
                "adb": "<sdk-root>/platform-tools/adb",
                "emulator": "<sdk-root>/emulator/emulator",
                "bridgeAPK": "<bridge-apk>"
            ],
            environmentProfile: options.environmentProfile.rawValue,
            workspace: "<workspace>",
            status: missing.isEmpty ? "READY" : "MISSING_CANDIDATE_IMAGES"
        )
    }

    func run() throws -> [RuntimeCandidateEvaluationReport] {
        let preflight = try preflight()
        guard preflight.missingPackages.isEmpty else {
            throw MatrixCLIError.unsafe(
                "install missing packages first: "
                    + preflight.missingPackages.joined(separator: ", ")
            )
        }
        try FileManager.default.createDirectory(
            at: runRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let candidates = try selectedCandidates()
        let plans = try RuntimeCandidatePlanner.plans(
            for: candidates,
            runID: runID
        )
        let fixtureServer = try startFixtureServer()
        defer { fixtureServer.terminateOwned() }
        var reports: [RuntimeCandidateEvaluationReport] = []
        for plan in plans {
            let report = evaluate(plan)
            reports.append(report)
            try writeJSON(
                report,
                to: runRoot.appendingPathComponent(
                    "\(plan.candidate.id).json"
                )
            )
        }
        let summaryURL = runRoot.appendingPathComponent("matrix-report.json")
        try writeJSON(reports, to: summaryURL)
        return reports
    }

    private func evaluate(
        _ plan: RuntimeCandidateExecutionPlan
    ) -> RuntimeCandidateEvaluationReport {
        let startedAt = Date()
        let candidateRoot = runRoot.appendingPathComponent(
            plan.candidate.id,
            isDirectory: true
        )
        let state = CandidateRunState(
            evaluator: self,
            plan: plan,
            root: candidateRoot
        )
        do {
            try state.run()
        } catch {
            state.recordFailure(error)
        }
        state.cleanup()
        return state.report(startedAt: startedAt, completedAt: Date())
    }

    private func startFixtureServer() throws -> LoggedProcess {
        guard let fixture = options.fixtureJAR else {
            throw MatrixCLIError.missingArgument("--fixture-jar")
        }
        let logRoot = runRoot.appendingPathComponent("fixture-server")
        try FileManager.default.createDirectory(
            at: logRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let process = try LoggedProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-m", "http.server", "\(options.fixturePort)",
                "--bind", "0.0.0.0",
                "--directory", fixture.deletingLastPathComponent().path
            ],
            environment: Self.systemOnlyEnvironment(),
            stdoutURL: logRoot.appendingPathComponent("stdout.log"),
            stderrURL: logRoot.appendingPathComponent("stderr.log")
        )
        let testURL = "http://127.0.0.1:\(options.fixturePort)/"
            + fixture.lastPathComponent
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if let result = try? runner.run(
                URL(fileURLWithPath: "/usr/bin/curl"),
                ["--fail", "--silent", "--max-time", "1", testURL],
                environment: Self.systemOnlyEnvironment(),
                timeout: 2
            ), result.status == 0 {
                return process
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminateOwned()
        throw MatrixCLIError.processExited("fixture HTTP server")
    }

    func systemImageExists(_ candidate: RuntimeCandidate) -> Bool {
        FileManager.default.fileExists(atPath: systemImageDirectory(candidate).path)
    }

    func systemImageDirectory(_ candidate: RuntimeCandidate) -> URL {
        toolchain.sdkRoot.appendingPathComponent(
            Self.systemImagePackageID(candidate)
                .split(separator: ";").joined(separator: "/"),
            isDirectory: true
        )
    }

    static func systemImagePackageID(_ candidate: RuntimeCandidate) -> String {
        "system-images;android-\(candidate.apiLevel);"
            + "\(candidate.systemImageVariant);arm64-v8a"
    }

    func matrixEnvironment(
        root: URL,
        plan: RuntimeCandidateExecutionPlan
    ) -> [String: String] {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let androidHome = home.appendingPathComponent(
            ".android",
            isDirectory: true
        )
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        return [
            "JAVA_HOME": toolchain.javaHome.path,
            "ANDROID_HOME": toolchain.sdkRoot.path,
            "ANDROID_SDK_ROOT": toolchain.sdkRoot.path,
            "ANDROID_AVD_HOME": avdHome.path,
            "ANDROID_USER_HOME": androidHome.path,
            "ANDROID_EMULATOR_HOME": androidHome.path,
            "ADB_VENDOR_KEYS": androidHome.appendingPathComponent("adbkey").path,
            "ANDROID_ADB_SERVER_PORT": "\(plan.privateADBServerPort)",
            "HOME": home.path,
            "TMPDIR": tmp.path,
            "PATH": [
                toolchain.javaHome.appendingPathComponent("bin").path,
                toolchain.sdkRoot.appendingPathComponent("platform-tools").path,
                toolchain.sdkRoot.appendingPathComponent("emulator").path,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ].joined(separator: ":"),
            "LANG": "C",
            "LC_ALL": "C"
        ]
    }

    func toolchainDescriptor(
        for candidate: RuntimeCandidate
    ) -> RuntimeCandidateToolchainDescriptor {
        RuntimeCandidateToolchainDescriptor(
            javaVersion: toolVersions.java,
            commandLineToolsVersion: toolVersions.commandLine,
            adbVersion: toolVersions.adb,
            emulatorVersion: toolVersions.emulator,
            systemImagePackageID: Self.systemImagePackageID(candidate),
            bridgeSHA256: toolVersions.bridgeSHA256
        )
    }

    private func productionRuntimeIsRunning() -> Bool {
        let manifest = options.productionRuntimeRoot.appendingPathComponent(
            "runtime-manifest.json"
        )
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let pid = object["pid"] as? Int,
              pid > 0 else { return false }
        return Darwin.kill(Int32(pid), 0) == 0
    }

    private func relativeToSDK(_ url: URL) -> String {
        let prefix = toolchain.sdkRoot.path + "/"
        return url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent
    }

    private static func resolveToolchain(
        _ options: MatrixOptions
    ) throws -> MatrixToolchain {
        let java = options.javaHome.appendingPathComponent("bin/java")
        let adb = options.sdkRoot.appendingPathComponent("platform-tools/adb")
        let emulator = options.sdkRoot.appendingPathComponent("emulator/emulator")
        let commandLineRoot = options.sdkRoot.appendingPathComponent(
            "cmdline-tools",
            isDirectory: true
        )
        let toolDirectories = (try? FileManager.default.contentsOfDirectory(
            at: commandLineRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.sorted { lhs, rhs in
            if lhs.lastPathComponent == "latest" { return true }
            if rhs.lastPathComponent == "latest" { return false }
            return lhs.lastPathComponent > rhs.lastPathComponent
        } ?? []
        guard let tools = toolDirectories.first(where: {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("bin/sdkmanager").path
            ) && FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("bin/avdmanager").path
            )
        }) else {
            throw MatrixCLIError.unsafe("command-line tools are missing")
        }
        let result = MatrixToolchain(
            sdkRoot: options.sdkRoot,
            javaHome: options.javaHome,
            java: java,
            sdkManager: tools.appendingPathComponent("bin/sdkmanager"),
            avdManager: tools.appendingPathComponent("bin/avdmanager"),
            adb: adb,
            emulator: emulator
        )
        for executable in [java, result.sdkManager, result.avdManager, adb, emulator]
            where !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw MatrixCLIError.unsafe(
                "required executable is missing: \(executable.lastPathComponent)"
            )
        }
        return result
    }

    private static func toolVersions(
        toolchain: MatrixToolchain,
        bridgeAPK: URL,
        runner: MatrixCommandRunner
    ) throws -> (
        java: String,
        commandLine: String,
        adb: String,
        emulator: String,
        bridgeSHA256: String
    ) {
        let environment = systemOnlyEnvironment().merging([
            "JAVA_HOME": toolchain.javaHome.path,
            "ANDROID_HOME": toolchain.sdkRoot.path,
            "ANDROID_SDK_ROOT": toolchain.sdkRoot.path,
            "PATH": toolchain.javaHome.appendingPathComponent("bin").path
                + ":/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, new in new }
        let java = try runner.run(
            toolchain.java,
            ["-version"],
            environment: environment
        )
        let commandLine = try runner.checked(
            toolchain.sdkManager,
            ["--version"],
            environment: environment
        )
        let adb = try runner.checked(toolchain.adb, ["version"], environment: environment)
        let emulator = try runner.run(
            toolchain.emulator,
            ["-version"],
            environment: environment
        )
        let digest = try runner.checked(
            URL(fileURLWithPath: "/usr/bin/shasum"),
            ["-a", "256", bridgeAPK.path],
            environment: systemOnlyEnvironment()
        ).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        func firstVersionLine(_ value: String) -> String {
            value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown"
        }
        return (
            firstVersionLine(java.stderr.isEmpty ? java.stdout : java.stderr),
            firstVersionLine(commandLine),
            firstVersionLine(adb),
            firstVersionLine(emulator.stdout.isEmpty ? emulator.stderr : emulator.stdout),
            digest
        )
    }

    private static func hostDescriptor(
        profile: RuntimeCandidateEnvironmentProfile
    ) throws -> RuntimeCandidateHostDescriptor {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let architecture = try MatrixCommandRunner().checked(
            URL(fileURLWithPath: "/usr/bin/uname"),
            ["-m"],
            environment: systemOnlyEnvironment()
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try MatrixCommandRunner().checked(
            URL(fileURLWithPath: "/usr/sbin/sysctl"),
            ["-n", "hw.model"],
            environment: systemOnlyEnvironment()
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeCandidateHostDescriptor(
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSMajorVersion: version.majorVersion,
            architecture: architecture,
            hardwareModel: model,
            environmentProfile: profile
        )
    }

    private static func portIsListening(
        _ port: Int,
        runner: MatrixCommandRunner
    ) -> Bool {
        guard let result = try? runner.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            environment: systemOnlyEnvironment(),
            timeout: 3
        ) else { return true }
        return result.status == 0 && !result.stdout.isEmpty
    }

    private static func systemOnlyEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": NSTemporaryDirectory()
        ]
    }

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-"
            + String(UUID().uuidString.prefix(8)).lowercased()
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        _ = try boundary.validateMutationTarget(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private final class CandidateRunState {
    let evaluator: MatrixEvaluator
    let plan: RuntimeCandidateExecutionPlan
    let root: URL
    let environment: [String: String]
    let avdHome: URL
    let avdDirectory: URL
    let logs: URL
    var phases: [RuntimeCandidatePhaseResult] = []
    var adbTimeline: [RuntimeCandidateADBObservation] = []
    var resourceSamples: [RuntimeCandidateResourceSample] = []
    var activePhase: RuntimeCandidatePhase?
    var adbServer: LoggedProcess?
    var emulator: LoggedProcess?

    init(
        evaluator: MatrixEvaluator,
        plan: RuntimeCandidateExecutionPlan,
        root: URL
    ) {
        self.evaluator = evaluator
        self.plan = plan
        self.root = root
        environment = evaluator.matrixEnvironment(root: root, plan: plan)
        avdHome = root.appendingPathComponent("avd", isDirectory: true)
        avdDirectory = avdHome.appendingPathComponent(
            "\(plan.avdName).avd",
            isDirectory: true
        )
        logs = root.appendingPathComponent("logs", isDirectory: true)
    }

    func run() throws {
        try createDirectories()
        try measured(.preflight) {
            guard evaluator.systemImageExists(plan.candidate) else {
                throw MatrixCLIError.unsafe("candidate image is missing")
            }
        }
        try measured(.environmentPurity) { try validateEnvironment() }
        try provisionPrivateADBKey()
        try startPrivateADBServer()
        try measured(.avdCreation) { try createAVD() }

        let cold = try launchEmulator(wipeData: true, logStem: "cold-boot")
        emulator = cold
        try measured(.coldBootADBOnline) {
            try waitForADB(process: cold, timeout: evaluator.options.adbTimeout)
        }
        try measured(.coldBootCompleted) {
            try waitForBoot(process: cold, timeout: evaluator.options.bootTimeout)
        }
        try measured(.bridgeInstall) { try installBridge() }
        try measured(.bridgeStart) { try startBridge() }
        try measured(.bridgeHealth) { try waitForBridgeHealth() }
        try measured(.dexSpiderInvocation) { try invokeMatrixSpider() }
        try measured(.idleResourceSample) { try sampleIdleResources(process: cold) }
        try measured(.firstShutdown) { try shutdownEmulator(cold) }
        emulator = nil

        let reuse = try launchEmulator(wipeData: false, logStem: "reuse-boot")
        emulator = reuse
        try measured(.reuseBootADBOnline) {
            try waitForADB(process: reuse, timeout: evaluator.options.adbTimeout)
        }
        try measured(.reuseBootCompleted) {
            try waitForBoot(process: reuse, timeout: evaluator.options.bootTimeout)
        }
        try measured(.bridgeReuseHealth) {
            try startBridge()
            try waitForBridgeHealth()
        }
        try measured(.finalShutdown) { try shutdownEmulator(reuse) }
        emulator = nil
    }

    func recordFailure(_ error: Error) {
        let detail = evaluator.redactor(error.localizedDescription)
        if let activePhase,
           !phases.contains(where: { $0.phase == activePhase }) {
            phases.append(RuntimeCandidatePhaseResult(
                phase: activePhase,
                outcome: .failed,
                detail: detail
            ))
        }
        let observed = Set(phases.map(\.phase))
        for phase in RuntimeCandidatePhase.allCases where !observed.contains(phase) {
            phases.append(RuntimeCandidatePhaseResult(
                phase: phase,
                outcome: .skipped,
                detail: "skipped after earlier failure"
            ))
        }
    }

    func cleanup() {
        if let emulator, emulator.isRunning {
            try? shutdownEmulator(emulator)
        }
        emulator?.terminateOwned()
        emulator = nil
        if adbServer?.isRunning == true {
            _ = try? evaluator.runner.run(
                evaluator.toolchain.adb,
                ["-P", "\(plan.privateADBServerPort)", "kill-server"],
                environment: environment,
                timeout: 5
            )
        }
        adbServer?.terminateOwned()
        adbServer = nil
    }

    func report(
        startedAt: Date,
        completedAt: Date
    ) -> RuntimeCandidateEvaluationReport {
        RuntimeCandidateEvaluationReport(
            runID: evaluator.runID,
            candidate: plan.candidate,
            startedAt: startedAt,
            completedAt: completedAt,
            host: evaluator.host,
            toolchain: evaluator.toolchainDescriptor(for: plan.candidate),
            phases: phases.sorted { lhs, rhs in
                RuntimeCandidatePhase.allCases.firstIndex(of: lhs.phase)!
                    < RuntimeCandidatePhase.allCases.firstIndex(of: rhs.phase)!
            },
            adbTimeline: adbTimeline,
            resourceSamples: resourceSamples,
            purityReport: nil,
            evidenceDirectory: "<workspace>/runs/\(evaluator.runID)/\(plan.candidate.id)"
        )
    }

    private func measured(
        _ phase: RuntimeCandidatePhase,
        _ operation: () throws -> Void
    ) throws {
        activePhase = phase
        let startedAt = Date()
        do {
            try operation()
            phases.append(RuntimeCandidatePhaseResult(
                phase: phase,
                outcome: .passed,
                durationSeconds: Date().timeIntervalSince(startedAt),
                detail: "passed"
            ))
            activePhase = nil
        } catch {
            phases.append(RuntimeCandidatePhaseResult(
                phase: phase,
                outcome: .failed,
                durationSeconds: Date().timeIntervalSince(startedAt),
                detail: evaluator.redactor(error.localizedDescription)
            ))
            activePhase = nil
            throw error
        }
    }

    private func createDirectories() throws {
        for directory in [
            root,
            avdHome,
            logs,
            root.appendingPathComponent("home/.android", isDirectory: true),
            root.appendingPathComponent("tmp", isDirectory: true)
        ] {
            _ = try evaluator.boundary.validateMutationTarget(directory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func validateEnvironment() throws {
        let expected: [String: String] = [
            "JAVA_HOME": evaluator.toolchain.javaHome.path,
            "ANDROID_HOME": evaluator.toolchain.sdkRoot.path,
            "ANDROID_SDK_ROOT": evaluator.toolchain.sdkRoot.path,
            "ANDROID_AVD_HOME": avdHome.path,
            "ANDROID_ADB_SERVER_PORT": "\(plan.privateADBServerPort)"
        ]
        for (key, value) in expected where environment[key] != value {
            throw MatrixCLIError.unsafe("\(key) is not isolated")
        }
        let path = environment["PATH"] ?? ""
        guard !path.contains("homebrew"),
              !path.contains("Android Studio") else {
            throw MatrixCLIError.unsafe("PATH contains an unmanaged toolchain")
        }
        for target in [avdHome, avdDirectory, logs] {
            _ = try evaluator.boundary.validateMutationTarget(target)
        }
    }

    private func provisionPrivateADBKey() throws {
        guard let keyPath = environment["ADB_VENDOR_KEYS"] else {
            throw MatrixCLIError.unsafe("ADB_VENDOR_KEYS is missing")
        }
        let key = URL(fileURLWithPath: keyPath)
        if !FileManager.default.fileExists(atPath: key.path) {
            _ = try evaluator.runner.checked(
                evaluator.toolchain.adb,
                ["keygen", key.path],
                environment: environment,
                timeout: 30
            )
        }
        guard FileManager.default.fileExists(atPath: key.path),
              FileManager.default.fileExists(atPath: key.path + ".pub") else {
            throw MatrixCLIError.unsafe("private ADB keypair was not created")
        }
    }

    private func startPrivateADBServer() throws {
        let server = try LoggedProcess(
            executable: evaluator.toolchain.adb,
            arguments: [
                "-L", "tcp:localhost:\(plan.privateADBServerPort)",
                "server", "nodaemon"
            ],
            environment: environment,
            stdoutURL: logs.appendingPathComponent("adb-server.stdout.log"),
            stderrURL: logs.appendingPathComponent("adb-server.stderr.log")
        )
        adbServer = server
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, server.isRunning {
            let result = try evaluator.runner.run(
                evaluator.toolchain.adb,
                ["-P", "\(plan.privateADBServerPort)", "devices", "-l"],
                environment: environment,
                timeout: 3
            )
            if result.status == 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MatrixCLIError.processExited("private ADB server")
    }

    private func createAVD() throws {
        let packageID = MatrixEvaluator.systemImagePackageID(plan.candidate)
        _ = try evaluator.runner.checked(
            evaluator.toolchain.avdManager,
            [
                "create", "avd",
                "-n", plan.avdName,
                "-k", packageID,
                "-p", avdDirectory.path
            ],
            environment: environment,
            input: Data("no\n".utf8),
            timeout: 60
        )
        let configuration = avdDirectory.appendingPathComponent("config.ini")
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            throw MatrixCLIError.command("avdmanager produced no config.ini")
        }
        var contents = try String(contentsOf: configuration, encoding: .utf8)
        contents = updateConfiguration(contents, updates: [
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "host",
            "hw.lcd.width": "720",
            "hw.lcd.height": "1600",
            "hw.lcd.density": "280",
            "showDeviceFrame": "no",
            "skin.dynamic": "yes"
        ])
        try Data(contents.utf8).write(to: configuration, options: .atomic)
    }

    private func updateConfiguration(
        _ contents: String,
        updates: [String: String]
    ) -> String {
        var seen = Set<String>()
        var lines = contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init).map { line -> String in
            guard let separator = line.firstIndex(of: "=") else { return line }
            let key = String(line[..<separator])
            guard let replacement = updates[key] else { return line }
            seen.insert(key)
            return "\(key)=\(replacement)"
        }
        for key in updates.keys.sorted() where !seen.contains(key) {
            lines.append("\(key)=\(updates[key]!)")
        }
        return lines.joined(separator: "\n")
    }

    private func launchEmulator(
        wipeData: Bool,
        logStem: String
    ) throws -> LoggedProcess {
        var arguments = [
            "-avd", plan.avdName,
            "-port", "\(plan.consolePort)",
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            "-no-metrics",
            "-no-snapshot",
            "-gpu", "host",
            "-accel", "on",
            "-verbose"
        ]
        if wipeData { arguments.append("-wipe-data") }
        if plan.candidate.apiLevel < 30 { arguments.append("-skip-adb-auth") }
        return try LoggedProcess(
            executable: evaluator.toolchain.emulator,
            arguments: arguments,
            environment: environment,
            stdoutURL: logs.appendingPathComponent("\(logStem).stdout.log"),
            stderrURL: logs.appendingPathComponent("\(logStem).stderr.log")
        )
    }

    private func waitForADB(
        process: LoggedProcess,
        timeout: TimeInterval
    ) throws {
        let startedAt = Date()
        let serial = "emulator-\(plan.consolePort)"
        while Date().timeIntervalSince(startedAt) < timeout {
            guard process.isRunning else {
                throw MatrixCLIError.processExited("emulator before ADB online")
            }
            let result = try evaluator.runner.run(
                evaluator.toolchain.adb,
                ["-P", "\(plan.privateADBServerPort)", "devices", "-l"],
                environment: environment,
                timeout: 5
            )
            let parsed = parseADBDevices(result.stdout, target: serial)
            adbTimeline.append(RuntimeCandidateADBObservation(
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                targetState: parsed.state,
                devices: parsed.devices,
                emulatorAlive: process.isRunning
            ))
            if parsed.state == .device { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw MatrixCLIError.timeout("\(serial) never became device")
    }

    private func waitForBoot(
        process: LoggedProcess,
        timeout: TimeInterval
    ) throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < timeout {
            guard process.isRunning else {
                throw MatrixCLIError.processExited("emulator before boot_completed")
            }
            let result = try adb(
                ["shell", "getprop", "sys.boot_completed"],
                timeout: 5,
                checked: false
            )
            if result.status == 0,
               result.stdout.trimmingCharacters(
                    in: .whitespacesAndNewlines
               ) == "1" {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw MatrixCLIError.timeout("sys.boot_completed")
    }

    private func installBridge() throws {
        _ = try adb([
            "install", "-r", evaluator.options.bridgeAPK.path
        ], timeout: 120)
    }

    private func startBridge() throws {
        _ = try? adb([
            "shell", "setprop",
            "debug.wm.disable_deprecated_target_sdk_dialog", "true"
        ], timeout: 8)
        _ = try adb([
            "shell", "am", "start",
            "-n", "com.okvideomac.dexbridge/.BridgeActivity",
            "--es", "okvideomac_runtime_generation",
            "matrix-\(evaluator.runID)-api\(plan.candidate.apiLevel)"
        ], timeout: 15)
        _ = try adb([
            "forward", "tcp:\(plan.bridgeHostPort)", "tcp:9978"
        ], timeout: 10)
        // Keep the fixture transport inside this matrix's private ADB
        // connection. 10.0.2.2 normally reaches the Mac loopback interface,
        // but host firewall and network-filter configurations can reject that
        // route even while the emulator and ADB are otherwise healthy.
        _ = try adb([
            "reverse", "tcp:\(evaluator.options.fixturePort)",
            "tcp:\(evaluator.options.fixturePort)"
        ], timeout: 10)
    }

    private func waitForBridgeHealth() throws {
        let expectedGeneration = "matrix-\(evaluator.runID)-api"
            + "\(plan.candidate.apiLevel)"
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let result = try evaluator.runner.run(
                URL(fileURLWithPath: "/usr/bin/curl"),
                [
                    "--fail", "--silent", "--show-error",
                    "--max-time", "2",
                    "http://127.0.0.1:\(plan.bridgeHostPort)/health"
                ],
                environment: systemEnvironment(),
                timeout: 4
            )
            if result.status == 0,
               let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
               json["ok"] as? Bool == true,
               json["generation"] as? String == expectedGeneration {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw MatrixCLIError.timeout("Bridge health")
    }

    private func invokeMatrixSpider() throws {
        guard let fixture = evaluator.options.fixtureJAR else {
            throw MatrixCLIError.missingArgument("--fixture-jar")
        }
        let fixtureURL = "http://127.0.0.1:\(evaluator.options.fixturePort)/"
            + fixture.lastPathComponent
        let payload: [String: Any] = [
            "configurationID": "runtime-matrix",
            "hosts": [],
            "siteKey": "matrix-api-\(plan.candidate.apiLevel)",
            "api": "csp_MatrixFixture",
            "ext": "",
            "jarURL": fixtureURL,
            "jarMD5": "",
            "method": "home",
            "arguments": [true],
            "providerOwnerID": "runtime-matrix-api-\(plan.candidate.apiLevel)"
        ]
        let payloadURL = root.appendingPathComponent("dex-invoke-request.json")
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: payloadURL, options: .atomic)
        let responseURL = root.appendingPathComponent(
            "dex-invoke-response.json"
        )
        let command = try evaluator.runner.run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            [
                "--silent", "--show-error",
                "--max-time", "30",
                "-H", "Content-Type: application/json",
                "--data-binary", "@\(payloadURL.path)",
                "--output", responseURL.path,
                "--write-out", "%{http_code}",
                "http://127.0.0.1:\(plan.bridgeHostPort)/v1/invoke"
            ],
            environment: systemEnvironment(),
            timeout: 35
        )
        guard command.status == 0 else {
            throw MatrixCLIError.command(
                "DEX Spider transport exited \(command.status): \(command.stderr)"
            )
        }
        let status = Int(command.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )) ?? 0
        let data = try Data(contentsOf: responseURL)
        let result = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw MatrixCLIError.invalidResponse(
                "DEX Spider fixture HTTP \(status)"
            )
        }
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              json["ok"] as? Bool == true,
              let provider = json["result"] as? [String: Any],
              let list = provider["list"] as? [[String: Any]],
              list.first?["vod_name"] as? String
                == "OKVideoMac Matrix PASS",
              list.first?["vod_id"] as? String
                == "api-\(plan.candidate.apiLevel)" else {
            throw MatrixCLIError.invalidResponse("DEX Spider fixture")
        }
    }

    private func sampleIdleResources(process: LoggedProcess) throws {
        Thread.sleep(forTimeInterval: 3)
        let startedAt = Date()
        for _ in 0..<3 {
            guard process.isRunning else {
                throw MatrixCLIError.processExited("emulator during resource sample")
            }
            let output = try evaluator.runner.checked(
                URL(fileURLWithPath: "/bin/ps"),
                ["-p", "\(process.pid)", "-o", "%cpu=,rss="],
                environment: systemEnvironment(),
                timeout: 5
            )
            let values = output.split(whereSeparator: { $0.isWhitespace })
            guard values.count >= 2,
                  let cpu = Double(values[0]),
                  let rssKB = Int64(values[1]) else {
                throw MatrixCLIError.invalidResponse("ps resource sample")
            }
            resourceSamples.append(RuntimeCandidateResourceSample(
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                residentMemoryBytes: rssKB * 1_024,
                cpuPercent: cpu
            ))
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func shutdownEmulator(_ process: LoggedProcess) throws {
        if process.isRunning {
            _ = try? adb(["emu", "kill"], timeout: 8)
        }
        if process.waitForExit(timeout: 15) { return }
        process.terminateOwned(grace: 5)
        guard !process.isRunning else {
            throw MatrixCLIError.timeout("owned matrix Emulator shutdown")
        }
    }

    private func adb(
        _ arguments: [String],
        timeout: TimeInterval,
        checked: Bool = true
    ) throws -> CommandResult {
        let scoped = [
            "-P", "\(plan.privateADBServerPort)",
            "-s", "emulator-\(plan.consolePort)"
        ] + arguments
        let result = try evaluator.runner.run(
            evaluator.toolchain.adb,
            scoped,
            environment: environment,
            timeout: timeout
        )
        if checked {
            guard !result.timedOut else {
                throw MatrixCLIError.timeout("adb \(arguments.first ?? "command")")
            }
            guard result.status == 0 else {
                throw MatrixCLIError.command(
                    "adb \(arguments.first ?? "command") exited \(result.status): "
                        + String(result.stderr.suffix(800))
                )
            }
        }
        return result
    }

    private func parseADBDevices(
        _ output: String,
        target: String
    ) -> (state: RuntimeCandidateADBState, devices: [String]) {
        var state: RuntimeCandidateADBState = .missing
        var devices: [String] = []
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2 else { continue }
            let serial = String(fields[0])
            let rawState = String(fields[1])
            devices.append("\(serial) \(rawState)")
            guard serial == target else { continue }
            switch rawState {
            case "device": state = .device
            case "offline": state = .offline
            case "unauthorized": state = .unauthorized
            default: state = .other
            }
        }
        return (state, devices)
    }

    private func systemEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": environment["HOME"] ?? root.path,
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": environment["TMPDIR"] ?? NSTemporaryDirectory()
        ]
    }
}

private func writeJSONToStandardOutput<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    let options = try MatrixOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let evaluator = try MatrixEvaluator(options: options)
    switch options.mode {
    case .preflight:
        try writeJSONToStandardOutput(evaluator.preflight())
    case .run:
        let reports = try evaluator.run()
        try writeJSONToStandardOutput(reports)
        guard reports.allSatisfy(\.passed) else { exit(2) }
    }
} catch {
    FileHandle.standardError.write(
        Data((error.localizedDescription + "\n").utf8)
    )
    exit(1)
}
