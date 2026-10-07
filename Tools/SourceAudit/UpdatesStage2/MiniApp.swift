import AppKit
import Foundation

@MainActor
final class MiniDelegate: NSObject, NSApplicationDelegate {
    let driver = ProbeDriver()
    private var state = 0
    private var cancelledOnce = false
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProbeLog.record("launched", ["executable": Bundle.main.executablePath!])
        if ProbeLog.version == "2" {
            let persisted = try? String(contentsOf: ProbeLog.root.appendingPathComponent("saved-progress.txt"), encoding: .utf8)
            ProbeLog.record("new_version_verified", ["savedProgress": persisted ?? "missing"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.driver.start() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProbeLog.record("termination_requested")
        if ProbeLog.version == "2" { return .terminateNow }
        if ProbeLog.scenario == "cancel-termination-once", !cancelledOnce {
            cancelledOnce = true
            ProbeLog.record("termination_cancelled_once")
            return .terminateCancel
        }
        if state == 2 { return .terminateNow }
        if state == 1 { return .terminateLater }
        state = 1
        work = Task { @MainActor in
            ProbeLog.record("cleanup_started")
            let delay: UInt64 = ProbeLog.scenario == "timeout" ? 12_000_000_000 : 500_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            try! "position=17.5".write(to: ProbeLog.root.appendingPathComponent("saved-progress.txt"), atomically: true, encoding: .utf8)
            ProbeLog.record("cleanup_completed")
            deadline?.cancel()
            finish()
        }
        deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            work?.cancel()
            ProbeLog.record("cleanup_timeout")
            finish()
        }
        return .terminateLater
    }
    private func finish() {
        precondition(state == 1)
        state = 2
        ProbeLog.record("termination_replied")
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func applicationWillTerminate(_ notification: Notification) { ProbeLog.record("will_terminate") }
}

@main
enum MiniMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MiniDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
