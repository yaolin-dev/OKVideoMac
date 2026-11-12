import Foundation
import Darwin
import OKCrashDiagnostics
import CrashExceptionFixture

@main
enum Fixture {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--diagnostics-upload-worker" { SentryUploadWorker.main() }
        guard args.count >= 3 else { exit(64) }
        let manager = try OKCrashManager(root: URL(fileURLWithPath: args[2]),
            metadata: .init(version: "0.9.3", build: "205"))
        if args[1] == "recover" {
            let data = try JSONEncoder().encode(manager.store.records())
            print(String(decoding: data, as: UTF8.self))
        } else if args[1] == "upload" {
            guard args.count == 4, let record = try manager.store.records().first else { exit(65) }
            try manager.store.setConsent(true)
            let adapter = SentryAdapter(store: manager.store)
            let outcome = try await withCheckedThrowingContinuation { continuation in
                do {
                    try adapter.send(record, dsn: args[3], allowLoopback: true, contaminateScopeForTest: true) {
                        continuation.resume(returning: $0)
                    }
                } catch { continuation.resume(throwing: error) }
            }
            print(String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self))
        } else {
            manager.record(.navigationLive, window: .browser)
            manager.record(.windowResizeBegin, window: .browser)
            switch args[1] {
            case "throw": ok_fixture_original_throw()
            case "rethrow": ok_fixture_rethrow()
            case "signal": raise(SIGABRT)
            default: exit(64)
            }
        }
        withExtendedLifetime(manager) {}
    }
}
