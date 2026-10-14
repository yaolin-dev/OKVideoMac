import Foundation
@_spi(XMLTVStreaming) import OKVideoCore

enum EPGImportStop: Error, Equatable { case cancelled, superseded, storeClosing }

/// A stop and the final activation compete for this lock. Once activation wins,
/// its database COMMIT result is authoritative, including a subsequent stop.
final class EPGImportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: EPGImportStop?
    func stop(_ value: EPGImportStop = .cancelled) {
        lock.lock(); defer { lock.unlock() }
        if reason == nil { reason = value }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let reason { throw reason }
    }
    func activate<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let reason { throw reason }
        return try operation()
    }
}

/// Finite receipt: no channel array, programme array, URL, headers, or credentials.
struct EPGImportReceipt {
    let active: EPGCacheActiveIdentity
    let rawProgrammes: Int
    let channelFacts: Int
    let expandedBytes: Int
    let peakProgrammeBatch: Int
    let peakChannelBatch: Int
    let peakProgrammeBytes: Int
    let peakChannelBytes: Int
    let wasGzip: Bool
    let cleanupIncomplete: Bool
}

/// Internal 9C.3 implementation, not constructed by App/Repository. Call only
/// on a non-main worker. The asynchronous coordinator owns pipeline admission.
final class EPGXMLTVImporter {
    let store: EPGCacheStore
    private(set) var cleanupFailureCount = 0
    var boundaryForTesting: ((String) throws -> Void)?
    init(store: EPGCacheStore) { self.store = store }

    func importLocal(_ file: XMLTVStagedFile, key: EPGRequestKey,
                     control: EPGImportControl = EPGImportControl()) throws -> EPGImportReceipt {
        defer { try? file.release() }
        try store.acquireImportPipeline()
        defer { store.releaseImportPipeline() }
        try control.check()
        let handle = try store.begin(key)
        return try finish(handle: handle, control: control) { sink in
            try XMLTVParser().parseStagedFile(file, sink: sink)
        }
    }

    func importDownloaded(_ file: XMLTVDownloadedFile, handle: EPGCacheImportHandle,
                          control: EPGImportControl) throws -> EPGImportReceipt {
        defer { try? file.release() }
        return try finish(handle: handle, control: control) { sink in
            let result = try XMLTVParser().parseDownloadedFile(file, sink: sink)
            return (result.xml, result.wasGzip)
        }
    }

    private func finish(handle: EPGCacheImportHandle, control: EPGImportControl,
                        parse: (SQLiteXMLTVSink) throws -> XMLTVFileImportSummary) throws -> EPGImportReceipt {
        try finish(handle: handle, control: control) { sink -> (XMLTVImportSummary, Bool) in
            let result = try parse(sink); return (result.xml, result.wasGzip)
        }
    }

    private func finish(handle: EPGCacheImportHandle, control: EPGImportControl,
                        parse: (SQLiteXMLTVSink) throws -> (XMLTVImportSummary, Bool)) throws -> EPGImportReceipt {
        precondition(!Thread.isMainThread)
        let sink = SQLiteXMLTVSink(store: store, handle: handle, control: control,
                                   boundary: boundaryForTesting)
        do {
            try control.check()
            let (summary, gzip) = try parse(sink)
            try boundaryForTesting?("parsedComplete")
            try control.check()
            try store.validate(handle, summary: EPGCacheValidation(
                rawProgrammeCount: summary.programmeElementCount,
                emittedProgrammeCount: summary.emittedProgrammeCount,
                minimumStart: summary.minProgrammeStart, maximumEnd: summary.maxProgrammeEnd,
                emittedChannelRecordCount: summary.emittedChannelRecordCount), checkCancellation: control.check)
            try boundaryForTesting?("validated")
            do {
                try store.retainCatchupHistory(handle, checkCancellation: control.check)
            } catch EPGCacheError.budgetExceeded {
                // Optional history must not discard a validated fresh guide.
                // The retention transaction rolled back before this fallback.
            }
            let active = try store.activate(handle, control: control)
            // No cancellation checks after COMMIT. Reclamation cannot undo it.
            let cleanupIncomplete = !cleanup()
            return EPGImportReceipt(active: active, rawProgrammes: summary.programmeElementCount,
                channelFacts: summary.emittedChannelRecordCount, expandedBytes: summary.inputBytes,
                peakProgrammeBatch: summary.peakBatchCount, peakChannelBatch: summary.peakChannelBatchCount,
                peakProgrammeBytes: summary.peakBatchEstimatedBytes,
                peakChannelBytes: summary.peakChannelBatchEstimatedBytes,
                wasGzip: gzip, cleanupIncomplete: cleanupIncomplete)
        } catch {
            // Called even when file magic/EOF fails before the parser owns sink.
            do { try store.abandon(handle) } catch { cleanupFailureCount += 1 }
            _ = cleanup()
            throw error
        }
    }

    /// Finite maintenance slice. Remaining work is explicit, never a giant DELETE.
    @discardableResult func cleanup(maximumSteps: Int = 32) -> Bool {
        do {
            for _ in 0..<maximumSteps {
                if try !store.cleanupStep().hasWorkRemaining { return true }
            }
        } catch { cleanupFailureCount += 1; return false }
        return false
    }
}

private final class SQLiteXMLTVSink: XMLTVMetadataBatchSink {
    let store: EPGCacheStore
    let handle: EPGCacheImportHandle
    let control: EPGImportControl
    let boundary: ((String) throws -> Void)?
    init(store: EPGCacheStore, handle: EPGCacheImportHandle, control: EPGImportControl,
         boundary: ((String) throws -> Void)?) {
        self.store = store; self.handle = handle; self.control = control; self.boundary = boundary
    }
    func checkCancellation() throws { try control.check() }
    func consumeTentative(_ values: [XMLTVStreamedProgramme]) throws {
        try control.check()
        try store.append(values.map { EPGCacheRecord(ordinal: $0.ordinal, programme: $0.programme) }, to: handle)
        try boundary?("programmeBatchCommitted")
        try control.check()
    }
    func consumeTentativeChannels(_ values: [EPGChannel]) throws {
        try control.check(); try store.appendChannels(values, to: handle)
        try boundary?("channelBatchCommitted"); try control.check()
    }
    func discardTentative() { /* outer importer owns unconditional abandon */ }
}
