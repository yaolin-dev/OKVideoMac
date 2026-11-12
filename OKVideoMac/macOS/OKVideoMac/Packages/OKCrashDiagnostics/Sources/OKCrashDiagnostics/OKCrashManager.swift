import Darwin
import Foundation
import CrashReporter

/// Instantiated once by the executable entry point, before SwiftUI and AppState.
public final class OKCrashManager {
    public let store: ReportStore
    private let reporter: PLCrashReporter
    public private(set) var recovered = false
    public private(set) var recoveryFailed = false
    private var trail: CrashOperationTrail?

    public func record(_ kind: CrashOperation.Kind, window: CrashOperation.Window = .none) {
        trail?.record(kind, window: window)
    }

    public init(root: URL, metadata: RunMetadata) throws {
        store = try ReportStore(root: root)
        let raw = root.appendingPathComponent("raw", isDirectory: true)
        try ReportStore.privateDirectory(raw)
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            throw CrashDiagnosticError.unavailable
        }
        // PLCrashReporter 1.12.2's pinned on-disk layout. Precreate its owned
        // directories/slot privately: do not change the process-wide business umask.
        let cache = raw.appendingPathComponent("com.plausiblelabs.crashreporter.data")
        let reports = cache.appendingPathComponent(identifier.replacingOccurrences(of: "/", with: "_"))
        for directory in [cache, reports, reports.appendingPathComponent("queued_reports")] {
            try ReportStore.privateDirectory(directory)
        }
        let slot = reports.appendingPathComponent("live_report.plcrash")
        if FileManager.default.fileExists(atPath: slot.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: slot.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw CrashDiagnosticError.unavailable
            }
        }
        let config = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [],
            shouldRegisterUncaughtExceptionHandler: true, basePath: raw.path,
            maxReportBytes: UInt(CrashMapper.maxRawBytes))
        reporter = PLCrashReporter(configuration: config)
        if reporter.hasPendingCrashReport() {
            do {
                let size = try slot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= CrashMapper.maxRawBytes else { throw CrashDiagnosticError.invalidReport }
                // An empty prepared slot is a clean exit, not a malformed crash.
                if size > 0 {
                    let data = try reporter.loadPendingCrashReportDataAndReturnError()
                    // Preserve the original exception and native metadata before conversion.
                    // Archive failure must not be followed by purging the only remaining copy.
                    try store.archiveRaw(data)
                    do {
                        try store.save(CrashMapper.parse(data, loadOperations: store.operations))
                        recovered = true
                    } catch { recoveryFailed = true }
                }
            } catch {
                recoveryFailed = true
                throw error // Keep the pending native file intact; do not overwrite it on enable.
            }
            try reporter.purgePendingCrashReportAndReturnError()
        }
        let descriptor = Darwin.open(slot.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CrashDiagnosticError.unavailable }
        let permissionResult = fchmod(descriptor, 0o600)
        Darwin.close(descriptor)
        guard permissionResult == 0 else { throw CrashDiagnosticError.unavailable }
        // The native writer frees its previous custom-data buffer when replaced.
        // Install immutable run metadata ONCE, before enabling fatal handlers.
        let session = UUID().uuidString
        var immutableMetadata = metadata
        immutableMetadata.operationSession = session
        reporter.customData = try JSONEncoder().encode(immutableMetadata)
        try reporter.enableAndReturnError()
        let operationStore = store
        trail = CrashOperationTrail { operations in
            // Normal execution only. A crash during atomic replacement leaves
            // the last complete snapshot; no mutable pointer is read by the handler.
            try? operationStore.saveOperations(operations, session: session)
        }
        record(.launch)
    }
}
