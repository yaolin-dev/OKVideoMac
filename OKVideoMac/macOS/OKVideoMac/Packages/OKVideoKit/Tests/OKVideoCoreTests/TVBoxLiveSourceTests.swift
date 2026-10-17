import XCTest
@_spi(MigrationDiagnostics) @testable import OKVideoCore

final class TVBoxLiveSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1704157200)
    private var programme: EPGProgramme {
        .init(channelID: "fixture", title: "Synthetic", start: Date(timeIntervalSince1970: 1704067200),
              end: Date(timeIntervalSince1970: 1704069000))
    }

    func testFongMiTokensReplacementQueryAndExplicitTimezone() throws {
        let rule = TVBoxCatchupConfiguration(days: "7", regex: #"/live/\d+"#,
            source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
            replace: #"/live/(\d+),/archive/$1"#)
        let url = URL(string: "https://example.invalid/live/42.ts?token=synthetic")!
        let config = try XCTUnwrap(rule.normalized(for: url, deviceTimeZoneID: "Asia/Shanghai"))
        let stream = LiveStream(name: "Synthetic", url: url, catchup: config)
        XCTAssertEqual(try LiveCatchupPolicy.request(stream: stream, programme: programme, now: now).url.absoluteString,
            "https://example.invalid/archive/42.ts?token=synthetic&playseek=20240101080000-20240101083000")
        XCTAssertEqual(config.seekPolicy, .request)
    }

    func testDefaultTimestampAndLegacyUTCAliases() throws {
        for source in ["https://example.invalid/archive?start=${(b)timestamp}&end=${(e)timestamp}",
                       "https://example.invalid/archive?start=${utc:yyyyMMddHHmmss}&end=${utcend:yyyyMMddHHmmss}"] {
            let url = URL(string: "https://example.invalid/live.ts")!
            let rule = TVBoxCatchupConfiguration(type: "default", source: source, replace: "[,ignored")
            let config = try XCTUnwrap(rule.normalized(for: url))
            let request = try LiveCatchupPolicy.request(stream: .init(name: "Fixture", url: url, catchup: config),
                                                      programme: programme, now: now)
            XCTAssertEqual(request.url.absoluteString, "https://example.invalid/archive?start=1704067200&end=1704069000")
        }
    }

    func testInvalidAndNonmatchingExplicitRulesNeverEnablePLTVFallback() throws {
        let url = URL(string: "https://example.invalid/PLTV/fixture")!
        let rules = [
            TVBoxCatchupConfiguration(type: "none"),
            .init(regex: "unmatched", source: "?start=${(b)timestamp}"),
            .init(regex: "[", source: "?start=${(b)timestamp}"),
            .init(source: "?start=${(b)unsupported}"),
            .init(source: "?start=static"),
            .init(days: "bad", source: "?start=${(b)timestamp}")
        ]
        for rule in rules {
            let config = try XCTUnwrap(rule.normalized(for: url))
            let stream = LiveStream(name: "Synthetic", url: url, catchup: config)
            XCTAssertThrowsError(try LiveCatchupPolicy.request(stream: stream, programme: programme, now: now))
        }
    }

    func testBoundedRegexRejectsExcessiveWorkAndPreservesJavaCaptures() throws {
        XCTAssertEqual(try TVBoxBoundedRegex.replacing("/live/(\\d+)", in: "/live/42", template: "/archive/$1"), "/archive/42")
        XCTAssertThrowsError(try TVBoxBoundedRegex.matches(String(repeating: "x", count: 1025), text: "x"))
        XCTAssertThrowsError(try TVBoxBoundedRegex.replacing("", in: String(repeating: "x", count: 200), template: "y"))
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try TVBoxBoundedRegex.matches("(a+)+$", text: String(repeating: "a", count: 500) + "!"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testJSONChannelOverridesSourceAndDisabledRuleSurvivesCoding() throws {
        let json = #"""
        {"name":"Synthetic","timeZone":"Asia/Shanghai",
         "epg":"https://guide.example.invalid/?id={id}&name={name}&date={date}",
         "catchup":{"type":"append","days":7,"source":"?start=${(b)timestamp}"},
         "header":{"X-Default":"default"},"ua":"Fixture",
         "groups":[{"name":"Synthetic","channel":[
           {"name":"One & Two","tvgId":"id/&","urls":["https://example.invalid/PLTV/1"]},
           {"name":"Two","urls":["https://example.invalid/PLTV/2"],"header":{"X-Local":"local"},
            "catchup":{"type":"none"}},
           {"name":"Three","urls":["https://example.invalid/live/3"],
            "catchup":{"type":"default","source":"https://example.invalid/replay/${(b)timestamp}"}}
         ]}]}
        """#
        let config = try JSONDecoder().decode(LiveConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(try JSONDecoder().decode(LiveConfiguration.self, from: JSONEncoder().encode(config)), config)
        let channels = try LiveSourceParser().parse(json).groups[0].channels
        XCTAssertEqual(channels[0].streams[0].catchup?.retentionDays, 7)
        XCTAssertEqual(channels[1].streams[0].catchup?.mode, "none")
        XCTAssertEqual(channels[2].streams[0].catchup?.template, "https://example.invalid/replay/{utc}")
        XCTAssertEqual(channels[0].epgAPI?.template, "https://guide.example.invalid/?id=id%2F%26&name=One%20%26%20Two&date={date}")
        XCTAssertEqual(channels[0].epgAPI?.timeZoneID, "Asia/Shanghai")
        XCTAssertNil(channels[1].streams[0].headers["X-Default"])
        XCTAssertEqual(channels[1].streams[0].headers["X-Local"], "local")
        XCTAssertEqual(channels[1].streams[0].headers["User-Agent"], "Fixture")
    }

    func testChannelOnlyGroupArrayAndOldCodingRemainCompatible() throws {
        let json = #"[{"name":"Synthetic","channel":[{"name":"One","urls":["https://example.invalid/live.ts"],"epg":"https://guide.example.invalid/?date={date}","catchup":{"source":"?start=${(b)timestamp}"}}]}]"#
        let channel = try XCTUnwrap(LiveSourceParser().parse(json).groups.first?.channels.first)
        XCTAssertNotNil(channel.epgAPI)
        XCTAssertEqual(channel.streams[0].catchup?.mode, "default")
        XCTAssertEqual(try JSONDecoder().decode(LiveChannel.self, from: JSONEncoder().encode(channel)), channel)
        let legacy = #"{"groupName":"Synthetic","name":"Old","streams":[]}"#
        XCTAssertNil(try JSONDecoder().decode(LiveChannel.self, from: Data(legacy.utf8)).epgAPI)
    }

    func testSnapshotKeepsOriginalBytesDefaultsAndParserObservations() throws {
        let original = Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="synthetic" group-title="Fixture",One
        https://example.invalid/live.ts
        #EXTINF:-1 tvg-id="synthetic" group-title="Fixture",One
        https://example.invalid/backup.ts
        """.utf8)
        let defaults = LiveSourceDefaults(LiveConfiguration(name: "Fixture",
            epg: "https://guide.example.invalid/?id={id}&date={date}",
            catchup: .init(source: "?start=${(b)timestamp}"), userAgent: "Fixture"))
        let stored = try LiveSourceDocument.attaching(defaults, to: original)
        XCTAssertEqual(try LiveSourceDocument.originalData(in: stored), original)
        XCTAssertEqual(try LiveSourceDocument.defaults(in: stored), defaults)
        var observations: [LiveParserObservation] = []
        let playlist = try LiveSourceParser().parseObserving(stored) { observations.append($0) }
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(playlist.groups[0].channels[0].streams.count, 2)
        XCTAssertTrue(observations.allSatisfy { $0.streams[0].catchup != nil })
        XCTAssertEqual(try LiveSourceParser().parse(stored), playlist)
        XCTAssertThrowsError(try LiveSourceParser().parse(LiveSourceDocument.attaching(defaults, to: stored)))
    }

    func testExternalM3UExplicitRuleAndHeadersOverrideDefaults() throws {
        let defaults = LiveSourceDefaults(LiveConfiguration(name: "Fixture",
            epg: "https://guide.example.invalid/guide.xml",
            catchup: .init(source: "?start=${(b)timestamp}"), userAgent: "Default"))
        let original = Data("""
        #EXTM3U
        #EXTINF:-1 catchup="none" group-title="Fixture",One
        #EXTVLCOPT:http-user-agent=Channel
        https://example.invalid/PLTV/1
        """.utf8)
        let playlist = try LiveSourceParser().parse(LiveSourceDocument.attaching(defaults, to: original))
        XCTAssertEqual(playlist.epgURL?.host, "guide.example.invalid")
        XCTAssertEqual(playlist.groups[0].channels[0].streams[0].catchup?.mode, "none")
        XCTAssertEqual(playlist.groups[0].channels[0].streams[0].headers["User-Agent"], "Channel")
    }

    func testExternalDescriptorRefreshAndRestartKeepConfiguration() async throws {
        let root = URL(string: "https://configuration.example.invalid/root.json")!
        let nested = URL(string: "https://configuration.example.invalid/live/list.m3u")!
        let descriptor = Data(#"{"lives":[{"name":"Synthetic","url":"./live/list.m3u","catchup":{"source":"?start=${(b)timestamp}"},"epg":"https://guide.example.invalid/?date={date}&name={name}"}]}"#.utf8)
        let m3u = Data("#EXTM3U\n#EXTINF:-1 group-title=\"Fixture\",One\nstream.ts".utf8)
        let loader = LiveSourceLoader(httpClient: FixtureClient(bodies: [root: descriptor, nested: m3u]))
        let loaded = try await loader.load(.remote(root))
        XCTAssertEqual(loaded.source, .remote(root))
        XCTAssertEqual(loaded.playlist.groups[0].channels[0].streams[0].url?.absoluteString,
                       "https://configuration.example.invalid/live/stream.ts")
        XCTAssertNotNil(loaded.playlist.groups[0].channels[0].streams[0].catchup)
        XCTAssertNotNil(loaded.playlist.groups[0].channels[0].epgAPI)
        XCTAssertEqual(try LiveSourceParser().parse(loaded.rawData, baseURL: loaded.baseURL), loaded.playlist)
        let refreshed = try await loader.load(.remote(root), defaults: LiveSourceDocument.defaults(in: loaded.rawData))
        XCTAssertEqual(refreshed.playlist, loaded.playlist)
        XCTAssertEqual(refreshed.rawData, loaded.rawData, "An unchanged source must retain its content identity")
    }

    func testNestedExternalDescriptorsAndAmbiguousRootsAreRejected() async throws {
        let root = URL(string: "https://configuration.example.invalid/root.json")!
        let child = URL(string: "https://configuration.example.invalid/child.json")!
        let loader = LiveSourceLoader(httpClient: FixtureClient(bodies: [
            root: Data(#"{"name":"Synthetic","url":"child.json"}"#.utf8),
            child: Data(#"{"name":"Nested","url":"root.json"}"#.utf8)]))
        do { _ = try await loader.load(.remote(root)); XCTFail("Nested descriptor should fail") } catch {}
        let ambiguous = Data(#"{"lives":[{"name":"One","url":"one.m3u"},{"name":"Two","url":"two.m3u"}]}"#.utf8)
        do { _ = try await loader.load(.pasted(text: String(decoding: ambiguous, as: UTF8.self), baseURL: root)); XCTFail("Must select a source") } catch {}
    }

    func testWireMetadataDiagnosticsRedactPrivateValues() {
        let live = LiveConfiguration(name: "Synthetic", epg: "https://example.invalid/?token=secret",
                                    catchup: .init(source: "?token=secret&${(b)timestamp}"))
        XCTAssertFalse(String(reflecting: live.catchup!).contains("secret"))
        XCTAssertFalse(String(reflecting: LiveSourceDefaults(live)).contains("secret"))
        XCTAssertFalse(String(reflecting: TVBoxEPGConfiguration(template: live.epg!, timeZoneID: "UTC")).contains("secret"))
    }
}

private struct FixtureClient: HTTPClient {
    let bodies: [URL: Data]
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let data = bodies[request.url] else { throw URLError(.resourceUnavailable) }
        return .init(url: request.url, statusCode: 200, headers: [:], body: data)
    }
}
