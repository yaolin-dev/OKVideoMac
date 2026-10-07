import AppKit
import Foundation
import OKVideoCore

@MainActor
enum NavigationProbe {
    static let root = URL(fileURLWithPath: "/private/tmp/OKVideoMac-EpisodeNavigation-Native/Run")
    static var started = false
    static func directories() throws -> AppDirectories {
        try AppDirectories(applicationSupport: root.appendingPathComponent("Data/Support"), caches: root.appendingPathComponent("Data/Caches"))
    }
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields; value["event"] = event; value["uptime"] = ProcessInfo.processInfo.systemUptime
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
        let url = root.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url); try! file.seekToEnd(); try! file.write(contentsOf: data); try! file.close()
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.unsupported(message) }
        record("assertion_passed", ["check": message])
    }
    static func wait(_ label: String, seconds: Double = 25, until predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(predicate(), label)
    }
    static func run(_ state: AppState) async {
        guard !started else { return }; started = true
        record("launched", ["executable": Bundle.main.executablePath!])
        do { try await state.navigationProbeRun(); record("PASS") }
        catch { record("FAIL", ["error": String(describing: error), "status": String(describing: state.playerSnapshot.status), "playbackError": String(describing: state.playerPresentedError)]) }
        MainRunLoopAppTerminationRequestScheduler().schedule { NSApp.terminate(nil) }
    }
}

struct NavigationProvider: SiteProvider {
    let fixture: VideoDetail
    let site = SiteConfiguration(key: "navigation-fixture", name: "Navigation fixture", type: 1, api: "https://example.invalid/api")
    let capability: SiteCapability = .standardJSON
    func home() async throws -> SiteHome { SiteHome(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { VideoPage(items: [], pagination: Pagination(page: page, pageCount: 1)) }
    func detail(id: String) async throws -> VideoDetail { fixture }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: "", page: page, filters: [:]) }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult {
        await NavigationProbe.record("provider_resolved", ["url": episodeURL])
        return SitePlaybackResult(url: episodeURL, needsParsing: false, flag: flag, validationPolicy: .playerAuthoritative)
    }
}
