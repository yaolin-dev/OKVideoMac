import AppKit
import Foundation

struct AppRelaunchRequest: Equatable, Sendable {
    let parentProcessIdentifier: Int32
    let bundleURL: URL
    let bundleIdentifier: String
    let handshakeToken: String
}

enum AppRelaunchError: Error, Equatable {
    case updateInProgress
    case invalidApplicationBundle
    case helperMissing
    case helperLaunchFailed
    case helperHandshakeFailed
    case helperHandshakeTimedOut
}

@MainActor
protocol AppRelaunchHelperLaunching {
    func prepareRelaunch(_ request: AppRelaunchRequest) async throws
}

@MainActor
protocol AppTerminationRequestScheduling {
    func schedule(_ request: @escaping @MainActor () -> Void)
}

/// Leaves the current Swift concurrency job before entering AppKit's
/// synchronous termination decision loop. AppDelegate is then free to run its
/// MainActor cleanup task and reply to `applicationShouldTerminate`.
@MainActor
struct MainRunLoopAppTerminationRequestScheduler:
    AppTerminationRequestScheduling {
    func schedule(_ request: @escaping @MainActor () -> Void) {
        // `NSApplication.terminate(_:)` enters a nested AppKit event loop when
        // AppDelegate returns `.terminateLater`. A main-dispatch callback is
        // not re-entered by that loop, so scheduling there would starve the
        // MainActor shutdown task that must eventually send the reply. A main
        // RunLoop block has the same execution context as a menu-bar Cmd-Q and
        // allows the nested loop to service MainActor work normally.
        RunLoop.main.perform(inModes: [.common]) {
            request()
        }
    }
}

@MainActor
final class AppRelaunchCoordinator {
    enum State: Equatable {
        case idle
        case preparingHelper
        case terminationRequested
    }

    static let shared = AppRelaunchCoordinator(restartGate: .shared)

    private(set) var state: State = .idle
    private let restartGate: AppRestartGate
    private let helperLauncher: any AppRelaunchHelperLaunching
    private let bundleURLProvider: () -> URL
    private let bundleIdentifierProvider: () -> String?
    private let processIdentifierProvider: () -> Int32
    private let terminationRequest: @MainActor () -> Void
    private let terminationScheduler: any AppTerminationRequestScheduling

    init(
        helperLauncher: (any AppRelaunchHelperLaunching)? = nil,
        bundleURLProvider: @escaping () -> URL = { Bundle.main.bundleURL },
        bundleIdentifierProvider: @escaping () -> String? = {
            Bundle.main.bundleIdentifier
        },
        processIdentifierProvider: @escaping () -> Int32 = {
            ProcessInfo.processInfo.processIdentifier
        },
        terminationRequest: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        },
        terminationScheduler: (any AppTerminationRequestScheduling)? = nil,
        restartGate: AppRestartGate? = nil
    ) {
        self.restartGate = restartGate ?? AppRestartGate()
        self.helperLauncher = helperLauncher ?? ProcessAppRelaunchHelperLauncher()
        self.bundleURLProvider = bundleURLProvider
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.processIdentifierProvider = processIdentifierProvider
        self.terminationRequest = terminationRequest
        self.terminationScheduler = terminationScheduler
            ?? MainRunLoopAppTerminationRequestScheduler()
    }

    /// Arms one process-external relaunch operation before requesting the
    /// existing, cleanup-aware AppDelegate termination path.
    func restartApplication() async throws {
        guard state == .idle else { return }
        let bundleURL = bundleURLProvider().standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "app",
              let bundleIdentifier = bundleIdentifierProvider(),
              !bundleIdentifier.isEmpty else {
            throw AppRelaunchError.invalidApplicationBundle
        }

        guard restartGate.claim(.application) else { throw AppRelaunchError.updateInProgress }
        state = .preparingHelper
        let request = AppRelaunchRequest(
            parentProcessIdentifier: processIdentifierProvider(),
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            handshakeToken: UUID().uuidString
        )
        do {
            try await helperLauncher.prepareRelaunch(request)
        } catch {
            restartGate.release(.application)
            state = .idle
            throw error
        }
        state = .terminationRequested
        let terminationRequest = self.terminationRequest
        terminationScheduler.schedule {
            terminationRequest()
        }
    }
}

@MainActor
final class ProcessAppRelaunchHelperLauncher: AppRelaunchHelperLaunching {
    static let helperName = "OKVideoMacRelauncher"
    static let handshakeTimeout: TimeInterval = 3

    func prepareRelaunch(_ request: AppRelaunchRequest) async throws {
        let helperURL = Self.helperURL(inApplicationBundle: request.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AppRelaunchError.helperMissing
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = [
            "--parent-pid", String(request.parentProcessIdentifier),
            "--bundle-path", request.bundleURL.path,
            "--bundle-id", request.bundleIdentifier,
            "--handshake-token", request.handshakeToken
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppRelaunchError.helperLaunchFailed
        }

        let expectedHandshake = "READY \(request.handshakeToken)"
        do {
            try await Self.waitForHandshake(
                expectedHandshake,
                from: outputPipe.fileHandleForReading,
                process: process
            )
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    static func helperURL(inApplicationBundle bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(Self.helperName, isDirectory: false)
    }

    private static func waitForHandshake(
        _ expectedHandshake: String,
        from handle: FileHandle,
        process: Process
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AppRelaunchHandshakeGate()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var response = Data()
                    while response.count < 4_096 {
                        guard let chunk = try handle.read(upToCount: 512),
                              !chunk.isEmpty else { break }
                        response.append(chunk)
                        if chunk.contains(0x0A) { break }
                    }
                    try? handle.close()
                    let line = String(data: response, encoding: .utf8)?
                        .split(whereSeparator: \Character.isNewline)
                        .first
                        .map(String.init)
                    let result: Result<Void, Error> = line == expectedHandshake
                        ? .success(())
                        : .failure(AppRelaunchError.helperHandshakeFailed)
                    gate.resume(continuation, with: result)
                } catch {
                    gate.resume(
                        continuation,
                        with: .failure(AppRelaunchError.helperHandshakeFailed)
                    )
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + handshakeTimeout
            ) {
                let didResume = gate.resume(
                    continuation,
                    with: .failure(AppRelaunchError.helperHandshakeTimedOut)
                )
                if didResume, process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

private final class AppRelaunchHandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) -> Bool {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return false
        }
        hasResumed = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
