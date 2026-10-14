import XCTest
@testable import OKVideoCore

final class LiveCatchupTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1704157200) // 2024-01-02 01:00 UTC
    func programme(start: TimeInterval = 1704067200, duration: TimeInterval = 1800) -> EPGProgramme {
        EPGProgramme(channelID: "fixture", title: "Synthetic programme", start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + duration))
    }
    func stream(_ config: LiveCatchupConfiguration) -> LiveStream {
        LiveStream(name: "Fixture", url: URL(string: "https://example.invalid/live.ts?token=fixture")!, catchup: config)
    }

    func testM3UInheritsAndOverridesWithoutChangingLiveURL() throws {
        let playlist = try LiveSourceParser().parse("""
        #EXTM3U catchup="append" catchup-source="&start={utc}&end={utcend}" catchup-days="7" catchup-correction="-2.5"
        #EXTINF:-1 tvg-id="fixture" group-title="Test",One
        https://example.invalid/live.ts?token=fixture
        #EXTINF:-1 catchup="default" catchup-source="https://example.invalid/archive/{utc}/{duration}.m3u8" catchup-days="2",Two
        https://example.invalid/two.ts
        #EXTINF:-1 catchup="none",Three
        https://example.invalid/three.ts
        """)
        let channels = playlist.groups.flatMap(\.channels)
        let a = try XCTUnwrap(channels[0].streams.first)
        XCTAssertEqual(a.catchup?.retentionDays, 7)
        XCTAssertEqual(a.catchup?.correctionSeconds, -9000)
        XCTAssertEqual(try LiveCatchupPolicy.request(stream: a, programme: programme(), now: now).url.absoluteString,
                       "https://example.invalid/live.ts?token=fixture&start=1704058200&end=1704060000")
        XCTAssertEqual(channels[1].streams.first?.catchup?.mode, "default")
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: channels[2].streams.first?.catchup, programme: programme(), now: now), .unsupported)
    }

    func testAvailabilityBoundsAreExplicit() {
        let config = LiveCatchupConfiguration(mode: "default", template: "https://example.invalid/{utc}", retentionDays: 1)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(start: now.timeIntervalSince1970 - 86400), now: now), .available)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(start: now.timeIntervalSince1970 - 86401), now: now), .expired)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(start: now.timeIntervalSince1970 - 30), now: now), .current)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(start: now.timeIntervalSince1970 + 30), now: now), .future)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: nil, programme: programme(), now: now), .unsupported)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(duration: -1), now: now), .invalidProgramme)
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: config, programme: programme(start: 1e100), now: now), .invalidProgramme)
    }

    func testCrossMidnightAndExplicitTimeZoneAndCorrection() throws {
        let config = LiveCatchupConfiguration(mode: "default", template: "https://example.invalid/archive?start={utc:Ymd-H-M-S}&end=${end:Ymd-H-M-S}", correctionSeconds: 3600, timeZoneID: "Asia/Shanghai")
        let request = try LiveCatchupPolicy.request(stream: stream(config), programme: programme(start: 1704123000, duration: 7200), now: now)
        XCTAssertEqual(request.url.absoluteString, "https://example.invalid/archive?start=20240102-00-30-00&end=20240102-02-30-00")
    }

    func testDaylightSavingFormatsEachInstantIndependently() throws {
        let config = LiveCatchupConfiguration(mode: "default", template: "https://example.invalid/?start={utc:Ymd-H-M-S}&end={utcend:Ymd-H-M-S}", timeZoneID: "America/New_York")
        let request = try LiveCatchupPolicy.request(stream: stream(config), programme: programme(start: 1710052200, duration: 7200), now: Date(timeIntervalSince1970: 1710063000))
        XCTAssertEqual(request.url.absoluteString, "https://example.invalid/?start=20240310-01-30-00&end=20240310-04-30-00")
    }

    func testRequestSeekKeepsProgrammeIdentityAndRemainingInterval() throws {
        let config = LiveCatchupConfiguration(mode: "append", template: "&start=${start}&duration={duration:60}&now={lutc}", seekPolicy: .request)
        let request = try LiveCatchupPolicy.request(stream: stream(config), programme: programme(), now: now, offset: 600)
        XCTAssertEqual(request.offset, 600)
        XCTAssertEqual(request.remainingDuration, 1200)
        XCTAssertEqual(request.programme, programme())
        XCTAssertTrue(request.url.absoluteString.contains("start=1704067800&duration=20"))
        XCTAssertThrowsError(try LiveCatchupPolicy.request(stream: stream(config), programme: programme(), now: now, offset: 1800))
        XCTAssertThrowsError(try LiveCatchupPolicy.request(stream: stream(config), programme: programme(), now: now, offset: .nan))
    }

    func testUnsupportedStaticAndBrokenTemplatesNeverBecomeLive() {
        for template in ["https://example.invalid/live.ts", "https://example.invalid/{unknown}", "https://example.invalid/{duration:0}", "https://example.invalid/{utc:yyyy}", "file:///tmp/{utc}", "https://example.invalid/{utc}#fragment"] {
            XCTAssertThrowsError(try LiveCatchupPolicy.request(stream: stream(.init(mode: "default", template: template)), programme: programme(), now: now))
            XCTAssertEqual(LiveCatchupPolicy.availability(configuration: .init(mode: "default", template: template), programme: programme(), now: now), .invalidConfiguration)
        }
        for attrs in [["catchup": "append", "catchup-source": "&s={utc}", "catchup-days": "bad"], ["catchup": "append", "catchup-source": "&s={utc}", "catchup-correction": "bad"]] {
            XCTAssertEqual(LiveCatchupPolicy.availability(configuration: .m3u(attributes: attrs), programme: programme(), now: now), .invalidConfiguration)
        }
    }

    func testStartOverRequiresCapabilityAndEndsAtNow() throws {
        let current = programme(start: now.timeIntervalSince1970 - 600, duration: 3600)
        let config = LiveCatchupConfiguration(mode: "append", template: "&start={utc}&end={utcend}&duration={duration}", supportsStartOver: true)
        let request = try LiveCatchupPolicy.request(stream: stream(config), programme: current, now: now)
        XCTAssertEqual(request.remainingDuration, 600)
        XCTAssertTrue(request.url.absoluteString.contains("duration=600"))
    }

    func testLegacyCodingRouteIsolationAndRedactedDiagnostics() throws {
        let original = LiveStream(name: "Fixture", url: URL(string: "https://example.invalid/live.ts")!)
        let oldData = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LiveStream.self, from: oldData), original)
        var replay = original; replay.catchup = .init(mode: "append", template: "&start={utc}&secret=fixture")
        XCTAssertEqual(try JSONDecoder().decode(LiveStream.self, from: JSONEncoder().encode(replay)), replay)
        XCTAssertEqual(ImportedRouteTransport.deduplicated([original, replay]).count, 2)
        XCTAssertFalse(String(reflecting: replay.catchup!).contains("secret"))
    }
    func testStandardIPTVFallbackMatchesFongMiAndExplicitDisableWins() throws {
        var value = LiveStream(name: "Fixture", url: URL(string: "rtsp://example.invalid/PLTV/fixture/index.smil?account=synthetic")!)
        let config = try XCTUnwrap(value.effectiveCatchup)
        XCTAssertEqual(config.retentionDays, 7)
        XCTAssertEqual(config.seekPolicy, .request)
        let request = try LiveCatchupPolicy.request(stream: value, programme: programme(), now: now)
        XCTAssertTrue(request.url.path.contains("/TVOD/"))
        XCTAssertTrue(request.url.absoluteString.contains("?account=synthetic&playseek="))
        XCTAssertFalse(request.url.absoluteString.contains("{utc"))
        value.catchup = .init(mode: "none", template: "")
        XCTAssertEqual(LiveCatchupPolicy.availability(configuration: value.effectiveCatchup, programme: programme(), now: now), .unsupported)
        XCTAssertNil(LiveStream(name: "Fixture", url: URL(string: "rtsp://example.invalid/unrelated/index.smil")!).effectiveCatchup)
    }

}
