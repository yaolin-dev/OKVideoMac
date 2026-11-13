import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class VolumePersistenceIsolationTests: XCTestCase {
    private final class CountingDefaults: UserDefaults {
        var audioWrites = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName == "player.audio.preference.v1" { audioWrites += 1 }
            super.set(value, forKey: defaultName)
        }
    }

    func testGestureKeepsImmediateIntentWithoutAnyDefaultsWriteUntilRelease() throws {
        let suite = "volume-gesture-" + UUID().uuidString
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        store.beginVolumeAdjustment()
        for volume in 0...130 { store.setVolume(Double(volume)) }
        XCTAssertEqual(store.value.volume, 130)
        XCTAssertEqual(store.revision, 131)
        XCTAssertEqual(defaults.audioWrites, 0, "A real defaults domain must receive no per-tick writes")
        store.endVolumeAdjustment()
        XCTAssertEqual(defaults.audioWrites, 1)
        XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value.volume, 130)
        store.endVolumeAdjustment(); store.flush()
        XCTAssertEqual(defaults.audioWrites, 1)
    }

    func testPrivateDomainMigratesOnceWithoutChangingBrowserDefaults() throws {
        let browserSuite = "volume-browser-" + UUID().uuidString
        let audioSuite = "volume-audio-" + UUID().uuidString
        let browser = try XCTUnwrap(CountingDefaults(suiteName: browserSuite))
        let audio = try XCTUnwrap(CountingDefaults(suiteName: audioSuite))
        defer { browser.removePersistentDomain(forName: browserSuite); audio.removePersistentDomain(forName: audioSuite) }
        let legacy = PlaybackAudioPreferenceStore(defaults: browser)
        legacy.setVolume(0); legacy.setMuted(true)
        let legacyData = browser.data(forKey: PlaybackAudioPreferenceStore.key)
        let browserWrites = browser.audioWrites
        let migrated = PlaybackAudioPreferenceStore(defaults: audio, legacyDefaults: browser)
        XCTAssertEqual(migrated.value, .init(volume: 0, muted: true))
        migrated.beginVolumeAdjustment()
        for volume in 0...120 { migrated.setVolume(Double(volume)) }
        migrated.endVolumeAdjustment()
        XCTAssertEqual(browser.audioWrites, browserWrites)
        XCTAssertEqual(browser.data(forKey: PlaybackAudioPreferenceStore.key), legacyData)
        XCTAssertEqual(audio.audioWrites, 2, "One migration write and one completed gesture")
        legacy.setVolume(55)
        let reopened = PlaybackAudioPreferenceStore(defaults: audio, legacyDefaults: browser)
        XCTAssertEqual(reopened.value, .init(volume: 120, muted: false))
    }

    func testShutdownFlushesGestureEvenWithoutMouseUp() async throws {
        let suite = "volume-shutdown-" + UUID().uuidString
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        let player = PlayerLifecycleController(mode: .fullDestroy, audioPreferences: store)
        player.beginVolumeAdjustment()
        player.rememberVolume(0); player.rememberMuted(true)
        XCTAssertEqual(defaults.audioWrites, 0)
        await player.shutdown()
        XCTAssertEqual(defaults.audioWrites, 1)
        XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value, .init(volume: 0, muted: true))
    }
}
