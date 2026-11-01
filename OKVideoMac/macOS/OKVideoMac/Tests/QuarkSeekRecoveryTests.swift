import XCTest
import OKVideoCore
@testable import OKVideoMac

final class QuarkSeekRecoveryTests: XCTestCase {
    private func media(route: String = "夸父原1", format: String? = "mp4", bridge: Bool = true) -> ResolvedMedia {
        ResolvedMedia(url: URL(string: bridge ? "http://127.0.0.1:19978/proxy/media/test" : "https://example.test/video.mp4")!,
                      headers: HTTPHeaders(), format: format, siteKey: "test", sourceName: route,
                      episodeName: "episode", transportProfile: .tvBox)
    }
    func testQuarkRelayRecoversWithBoundedBufferAndEarlierRefill() {
        let options = MPVTVBoxPlaybackPolicy.loadCommand(for: media()).last!
        for option in ["cache=yes", "cache-pause-initial=yes", "cache-pause-wait=3", "demuxer-hysteresis-secs=30",
                       "demuxer-max-bytes=128MiB", "demuxer-max-back-bytes=32MiB", "cache-secs=60"] {
            XCTAssertTrue(options.contains(option), option)
        }
        XCTAssertTrue(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(media(route: "Quark 原画")))
        XCTAssertTrue(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(media(format: nil)))
        XCTAssertTrue(MPVTVBoxPlaybackPolicy.loadCommand(for: media(), omitFormatHint: true).last!.contains("cache-pause-wait=3"))
    }
    func testOtherRoutesPlaylistLocalAndStandardPlaybackKeepExistingPolicy() {
        for value in [media(route: "优汐智1"), media(route: "夸父智1", format: nil), media(format: "dash"), media(format: "m3u8"), media(format: "mpegts"), media(bridge: false)] {
            XCTAssertFalse(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(value))
            XCTAssertFalse(MPVTVBoxPlaybackPolicy.loadCommand(for: value).last!.contains("cache-pause-wait=3"))
        }
        var value = media(); value.transportProfile = .standard
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(value))
        value = media(); value.url = URL(fileURLWithPath: "/tmp/movie.mp4")
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(value))
        value = media(); value.compatibilityPolicy = .nativeXtreamLive
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(value))
    }
    func testRecoveryDistinguishesFirstProgressRebufferAndContinuousPlayback() {
        var recovery = PlayerSeekRecoveryObservation(started: 100)
        recovery.cachePause(true); recovery.cachePause(true)
        recovery.progress(position: 300, now: 101, playing: false)
        recovery.cachePause(false)
        recovery.progress(position: 300.1, now: 102, playing: true)
        XCTAssertEqual(recovery.firstProgress, 102); XCTAssertEqual(recovery.rebufferCount, 0)
        recovery.cachePause(true); recovery.cachePause(true)
        XCTAssertEqual(recovery.rebufferCount, 1)
        recovery.progress(position: 300.1, now: 108, playing: false)
        recovery.cachePause(false)
        recovery.progress(position: 301, now: 109, playing: true)
        recovery.progress(position: 305, now: 113, playing: true)
        XCTAssertFalse(recovery.stableTenSeconds)
        recovery.progress(position: 311, now: 119, playing: true)
        XCTAssertTrue(recovery.stableTenSeconds)
        XCTAssertTrue(recovery.fields.contains("first_progress_seconds=2.000"))
    }
    func testRecoveryDiagnosticsCoverOtherCloudAndCatPawFilesWithoutBufferOverride() {
        for url in ["https://example.test/file.mp4", "http://127.0.0.1:32567/proxy/quark/src/down/file/.bin",
                    "http://localhost:32567/proxy/ali/src/redirect/file/.bin"] {
            var value = media(route: "UC 原画", format: nil, bridge: false)
            value.transportProfile = .standard
            value.url = URL(string: url)!
            XCTAssertTrue(MPVTVBoxPlaybackPolicy.observesSeekRecovery(value))
            XCTAssertFalse(MPVTVBoxPlaybackPolicy.usesCloudFileBuffering(value))
            XCTAssertFalse(MPVTVBoxPlaybackPolicy.loadCommand(for: value).joined().contains("cache-pause-wait=3"))
        }
    }
    func testAdditionalDiagnosticsExcludeLocalFilesPlaylistsAndNativeLive() {
        for format in ["hls", "dash", "mpegts"] {
            XCTAssertFalse(MPVTVBoxPlaybackPolicy.observesSeekRecovery(media(format: format, bridge: false)))
        }
        var value = media(); value.url = URL(fileURLWithPath: "/tmp/video.mp4")
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.observesSeekRecovery(value))
        value = media(bridge: false); value.compatibilityPolicy = .nativeXtreamLive
        XCTAssertFalse(MPVTVBoxPlaybackPolicy.observesSeekRecovery(value))
        XCTAssertTrue(MPVTVBoxPlaybackPolicy.observesSeekRecovery(media(format: "dash")))
    }
    func testSealedCatPawLegacyCacheUpgradesOfflineAndRejectsModifiedBytes() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OKVIDEOMAC_CATPAW_LEGACY_FIXTURE"] else {
            throw XCTSkip("Exact previously shipped CatPaw artifact is supplied by the local acceptance runner")
        }
        let patch = NodeBundleDeterministicPatch.quarkLifecycleV3
        let legacy = try Data(contentsOf: URL(fileURLWithPath: fixture))
        XCTAssertEqual(NodeBundleRuntimeService.sha256Hex(legacy), "73e5436f3e733e15bd2a6d3e39990277cd190a0da4d0e486cb34a04c57dc8f5d")
        let original = try NodeBundleRuntimeService.unpatchedLegacyData(legacy, patch: patch)
        XCTAssertEqual(NodeBundleRuntimeService.sha256Hex(original), patch.inputSHA256)
        let current = try NodeBundleRuntimeService.applyDeterministicPatch(original, patch: patch, finalScriptURL: patch.immutableScriptURL)
        XCTAssertEqual(NodeBundleRuntimeService.sha256Hex(current), patch.outputSHA256)
        var modified = legacy; modified[0] ^= 1
        let rejected = try NodeBundleRuntimeService.unpatchedLegacyData(modified, patch: patch)
        XCTAssertEqual(rejected, modified)
        XCTAssertThrowsError(try NodeBundleRuntimeService.applyDeterministicPatch(rejected, patch: patch, finalScriptURL: patch.immutableScriptURL))
    }
    func testPausedAndStaleProgressDoNotCountAsRecovery() {
        var recovery = PlayerSeekRecoveryObservation(started: 100)
        recovery.progress(position: 10, now: 90, playing: true)
        recovery.progress(position: 10, now: 101, playing: false)
        recovery.progress(position: 10, now: 115, playing: true)
        XCTAssertNil(recovery.firstProgress); XCTAssertFalse(recovery.stableTenSeconds)
        recovery.progress(position: 11, now: 116, playing: true)
        recovery.progress(position: 12, now: 118, playing: false)
        recovery.progress(position: 13, now: 121, playing: true)
        recovery.progress(position: 17, now: 125, playing: true)
        XCTAssertFalse(recovery.stableTenSeconds)
    }
}
