import Foundation
import Sentry
import DiagnosticHandlers
import Darwin

/// Runs only in --upload-worker, before installing PLCrashReporter or creating App state.
/// Sentry owns serialization and transport. Exiting this bounded process releases its SDK queues;
/// invalidating a session under a live Sentry queue would crash on late data-task creation.
public enum SentryUploadWorker {
    private static var parentWatchdog: DispatchSourceTimer?
    // The acceptance binary cannot pollute the production event environment.
    static var reportEnvironment: String {
#if OKVIDEO_CRASH_ACCEPTANCE
        "okvideomac-crash-integration-acceptance"
#else
        "okvideomac-crash-reports"
#endif
    }
    struct Input: Codable {
        let record: CrashRecord
        let dsn: String
        let cachePath: String
        let allowLoopback: Bool
        let contaminateScopeForTest: Bool
    }
    public static func main(faultForTests: UploadWorkerFault = .none) -> Never {
        umask(0o077) // This process creates SDK files only; business umask is unchanged.
        let parent = getppid()
        guard parent > 1 else { _exit(0) }
        // Covers parent exit even while stdin has not yet been read (or a partial packet is stalled).
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now(), repeating: .milliseconds(100))
        watchdog.setEventHandler { if getppid() != parent { _exit(0) } }
        parentWatchdog = watchdog
        watchdog.resume()
        #if OKVIDEO_CRASH_ACCEPTANCE
        if faultForTests == .exitBeforeRead { _exit(71) }
        if faultForTests == .noRead { while true { Thread.sleep(forTimeInterval: 0.1) } }
#endif
        do {
            // A newline packet keeps stdin open as a parent-lifetime pipe. No credentials in argv.
            var packet = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 1), !chunk.isEmpty {
                if chunk[0] == 10 { break }
                packet.append(chunk)
                guard packet.count <= CrashMapper.maxRecordBytes + 8192 else { exit(2) }
            }
            let input = try JSONDecoder().decode(Input.self, from: packet)
            guard input.record.isValid else { exit(2) }
            #if OKVIDEO_CRASH_ACCEPTANCE
            try SentryAdapter.validateDSN(input.dsn, allowLoopback: input.allowLoopback)
#else
            guard !input.allowLoopback, !input.contaminateScopeForTest else { exit(2) }
            try SentryAdapter.validateDSN(input.dsn, allowLoopback: false)
#endif
            DispatchQueue.global(qos: .utility).async {
                _ = try? FileHandle.standardInput.readToEnd()
                _exit(0) // Parent crash/exit: never leave a retry worker behind.
            }
            #if OKVIDEO_CRASH_ACCEPTANCE
            if faultForTests == .exitAfterRead { _exit(72) }
            if faultForTests == .noReply { while true { Thread.sleep(forTimeInterval: 0.1) } }
            if faultForTests == .invalidReply { print("invalid"); exit(0) }
            if faultForTests == .oversizedReply {
                FileHandle.standardOutput.write(Data(repeating: 65, count: 65_536)); exit(0)
            }
#endif
            run(input)
        } catch { exit(2) }
    }
    private static func run(_ input: Input) -> Never {
        let record = input.record
        let dsn = input.dsn
        let receipt = Receipt()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        let uploadSession = URLSession(configuration: configuration, delegate: receipt, delegateQueue: nil)
        let handlersBefore = ok_diagnostic_handlers_snapshot()
        let exceptionBefore = exceptionHandlerAddress()
        let options = Options()
        options.dsn = dsn
        options.debug = false
        options.environment = reportEnvironment
        options.sendDefaultPii = false
        options.enableCrashHandler = false
        options.enableUncaughtNSExceptionReporting = false
        options.enableMemoryIntrospection = false
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAppHangTracking = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false
        options.enableAutoPerformanceTracing = false
        options.enablePersistingTracesWhenCrashing = false
        options.tracesSampleRate = 0
        options.tracesSampler = nil
        options.configureProfiling = nil
        options.enableLogs = false
        options.enableMetrics = false
        options.enableSpotlight = false
        options.enableSwizzling = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableAutoBreadcrumbTracking = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableTimeToFullDisplayTracing = false
        options.enableGraphQLOperationTracking = false
        options.enablePropagateTraceparent = false
        options.tracePropagationTargets = []
        options.attachStacktrace = false
        options.attachAllThreads = false
        options.swiftAsyncStacktraces = false
        options.maxBreadcrumbs = UInt(CrashOperation.capacity)
        options.maxFeatureFlags = 0
        options.maxAttachmentSize = 0
        options.maxCacheItems = 1
        options.sendClientReports = false
        options.shutdownTimeInterval = 0
        options.urlSession = uploadSession
        options.cacheDirectoryPath = input.cachePath
        // Never set options.dist: SDK options can override the crashed version after an app update.
        options.beforeSend = { event in
            guard event.eventId.sentryIdString == record.id else { return nil }
            // Rebuild rather than blacklist SDK defaults (user installation ID, current OS, etc.).
            return Self.event(record)
        }
        SentrySDK.start(options: options)
        #if OKVIDEO_CRASH_ACCEPTANCE
        if input.contaminateScopeForTest {
            SentrySDK.configureScope { scope in
                let user = User(); user.email = "DO_NOT_SEND@example.invalid"; user.userId = "DO_NOT_SEND"
                scope.setUser(user)
                scope.setExtra(value: "https://DO_NOT_SEND.invalid/video?token=secret", key: "private")
                scope.setTag(value: "DO_NOT_SEND", key: "video-title")
                let crumb = Breadcrumb(); crumb.message = "DO_NOT_SEND"
                scope.addBreadcrumb(crumb)
            }
        }
        #endif
        SentrySDK.capture(event: Self.event(record))

        SentrySDK.flush(timeout: 5)
        let unchanged = ok_diagnostic_handlers_match(handlersBefore) && exceptionBefore == exceptionHandlerAddress()
        ok_diagnostic_handlers_free(handlersBefore)
        let outcome = SentryAdapter.Outcome(result: "pending", handlersUnchanged: unchanged, httpStatus: receipt.status)
        if let data = try? JSONEncoder().encode(outcome) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
        // Do not call close()/invalidateAndCancel(): close queues another asynchronous SDK flush.
        exit(0)
    }
    private static func exceptionHandlerAddress() -> UInt {
        NSGetUncaughtExceptionHandler().map { unsafeBitCast($0, to: UInt.self) } ?? 0
    }
    nonisolated static func event(_ record: CrashRecord) -> Event {
        let event = Event(level: .fatal)
        event.eventId = SentryId(uuidString: record.id)
        event.timestamp = record.timestamp
        event.platform = "cocoa"
        event.releaseName = "com.okvideomac.OKVideoMac@\(record.version)+\(record.build)"
        event.dist = record.build
        event.environment = reportEnvironment
        event.context = ["os": ["name": "macOS", "version": record.osVersion], "device": ["arch": record.architecture]]
        let ownImageBases = Set(record.images.filter {
            $0.name == "OKVideoMac"
        }.map(\.base))
        event.threads = record.threads.map { thread in
            let t = SentryThread(threadId: NSNumber(value: thread.number))
            t.crashed = NSNumber(value: thread.crashed)
            t.stacktrace = SentryStacktrace(frames: thread.frames.map { frame in
                let f = Frame(); f.instructionAddress = String(format: "0x%llx", frame.pc)
                if let base = frame.imageBase { f.imageAddress = String(format: "0x%llx", base) }
                f.inApp = NSNumber(value: frame.imageBase.map { ownImageBases.contains($0) } ?? false)
                return f
            }, registers: [:])
            return t
        }
        let original = record.exception
        let exception = Exception(value: original?.reason ?? record.signalCode, type: original?.name ?? record.signal)
        let crashedThread = event.threads?.first(where: { $0.crashed?.boolValue == true })
        exception.threadId = crashedThread?.threadId
        // Preserve both: exception.stacktrace is the first throw, threads retain the abort stack.
        if let original, !original.frames.isEmpty {
            exception.stacktrace = SentryStacktrace(frames: original.frames.map { frame in
                let f = Frame(); f.instructionAddress = String(format: "0x%llx", frame.pc)
                if let base = frame.imageBase { f.imageAddress = String(format: "0x%llx", base) }
                f.inApp = NSNumber(value: frame.imageBase.map { ownImageBases.contains($0) } ?? false)
                return f
            }, registers: [:])
        } else { exception.stacktrace = crashedThread?.stacktrace }
        let mechanism = Mechanism(type: "plcrashreporter"); mechanism.handled = false
        exception.mechanism = mechanism
        event.exceptions = [exception]
        if record.imageCount != nil || original != nil || record.operations != nil {
            event.context?["crash_diagnostics"] = [
                "schema": 2, "signal": record.signal, "signal_code": record.signalCode,
                "exception_info_available": original != nil,
                "first_throw_stack_available": !(original?.frames.isEmpty ?? true),
                "image_count": record.imageCount ?? record.images.count,
                "omitted_image_count": record.omittedImageCount ?? 0
            ]
        }
        if let operations = record.operations, !operations.isEmpty {
            event.breadcrumbs = operations.map { operation in
                let crumb = Breadcrumb()
                crumb.level = .info
                crumb.category = "app.operation"
                crumb.type = [.pointerDown, .scroll, .keyboardCommand].contains(operation.kind) ? "user" : "default"
                crumb.message = operation.kind.rawValue
                crumb.timestamp = operation.timestamp
                crumb.setData(value: operation.sequence, key: "sequence")
                crumb.setData(value: operation.uptime, key: "uptime")
                crumb.setData(value: operation.window.rawValue, key: "window")
                return crumb
            }
            if let last = operations.last {
                event.context?["last_operation"] = ["kind": last.kind.rawValue, "window": last.window.rawValue,
                    "sequence": last.sequence, "uptime": last.uptime]
            }
        }
        event.debugMeta = record.images.map { image in
            let meta = DebugMeta(); meta.type = "macho"; meta.debugID = image.uuid
            meta.imageAddress = String(format: "0x%llx", image.base)
            meta.imageSize = NSNumber(value: image.size); meta.codeFile = image.name
            if let vmaddr = image.vmaddr { meta.imageVmAddress = String(format: "0x%llx", vmaddr) }
            return meta
        }
        return event
    }
}
/// URLSession completion-handler tasks still deliver task metrics to their delegate.
/// Only a final 2xx response counts; nil/timeout is retained for retry with the same event ID.
/// An HTTP receipt is not proof of backend symbolication.
private final class Receipt: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int?
    var status: Int? { lock.lock(); defer { lock.unlock() }; return code }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        code = (task.response as? HTTPURLResponse)?.statusCode
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not forward a crash payload to a different host through redirects.
        completionHandler(nil)
    }
}
