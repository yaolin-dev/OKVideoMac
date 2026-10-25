import XCTest
@testable import OKVideoCore

final class DanmakuCoreTests: XCTestCase {
    func testPlayerDecoderReadsNestedCatPawDanmaku() throws {
        let site = SiteConfiguration(
            key: "catpaw",
            name: "CatPaw",
            type: 3,
            api: "csp_Node"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(#"{"url":"https://media.example/video.mp4","extra":{"danmaku":{"url":"https://dm.example/1.xml"}}}"#.utf8),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.danmaku,
            .object(["url": .string("https://dm.example/1.xml")])
        )
    }

    func testBilibiliXMLParsesSupportedModesAndSortsTimeline() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <i>
          <d p="2.5,5,36,16711680,0,0,hash,top">置顶 &amp; 测试</d>
          <d p="1.0,1,25,16777215,0,0,hash,scroll">滚动</d>
          <d p="3.0,4,18,255,0,0,hash,bottom">底部</d>
          <d p="invalid,1,25,1">丢弃</d>
        </i>
        """

        let timeline = try BilibiliDanmakuXMLParser().parse(Data(xml.utf8))

        XCTAssertEqual(timeline.comments.map(\.text), ["滚动", "置顶 & 测试", "底部"])
        XCTAssertEqual(timeline.comments.map(\.mode), [.scrolling, .top, .bottom])
        XCTAssertEqual(Array(timeline.comments(from: 1.5, through: 3)).map(\.text), ["置顶 & 测试", "底部"])
    }

    func testXMLParserEnforcesDocumentAndCommentLimits() throws {
        XCTAssertThrowsError(
            try BilibiliDanmakuXMLParser(maximumDocumentBytes: 3).parse(Data("<i/>".utf8))
        )
        let xml = "<i><d p=\"1,1,25,1\">一</d><d p=\"2,1,25,1\">二</d></i>"
        let timeline = try BilibiliDanmakuXMLParser(maximumComments: 1).parse(Data(xml.utf8))
        XCTAssertEqual(timeline.comments.map(\.text), ["一"])
    }

    func testCommentJSONParsesServiceFormatWhenXMLIsUnavailable() throws {
        let data = Data(#"{"count":2,"comments":[{"cid":42,"p":"2.5,5,16711680,[qq]","m":"顶部弹幕"},{"cid":43,"p":"1.0,1,25,255,0,0,hash,source","m":"滚动弹幕"}]}"#.utf8)
        let timeline = try DanmakuPayloadParser().parse(data)

        XCTAssertEqual(timeline.comments.map(\.text), ["滚动弹幕", "顶部弹幕"])
        XCTAssertEqual(timeline.comments.map(\.mode), [.scrolling, .top])
        XCTAssertEqual(timeline.comments.map(\.color), [255, 16_711_680])
        XCTAssertEqual(timeline.comments.map(\.fontSize), [25, 25])
    }

    func testCommentJSONReportsServiceErrorInsteadOfEmptyTimeline() {
        let data = Data(#"{"success":false,"errorCode":403,"errorMessage":"弹幕源暂不可用"}"#.utf8)

        XCTAssertThrowsError(try DanmakuPayloadParser().parse(data)) { error in
            XCTAssertEqual(
                error as? DanmakuJSONParserError,
                .serviceFailure("弹幕源暂不可用")
            )
        }
    }

    func testSourceNormalizerHandlesNestedCatPawAndJSONStringShapes() throws {
        let generation: UInt64 = 9
        let value: JSONValue = .object([
            "extra": .object([
                "danmaku": .string(#"[{"name":"线路一","url":"/one.xml","default":true},{"name":"线路二","url":"https://example.com/two.xml"}]"#)
            ]),
            "danmaku": .array([
                .object([
                    "id": .string("remote-3"),
                    "name": .string("线路三"),
                    "url": .string("https://example.com/three.xml"),
                    "headers": .object(["Referer": .string("https://example.com/")])
                ])
            ])
        ])

        let sources = DanmakuSourceNormalizer.sources(
            from: value,
            provider: "catpaw",
            baseURL: URL(string: "https://runtime.example/base/")!,
            runtimeGeneration: generation
        )

        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.contains { $0.runtime.url.absoluteString == "https://runtime.example/one.xml" && $0.isPreferred })
        let third = try XCTUnwrap(sources.first { $0.stable.resourceID == "remote-3" })
        XCTAssertEqual(third.runtime.headers["referer"], "https://example.com/")
        XCTAssertEqual(third.runtime.runtimeGeneration, generation)
    }

    func testRuntimeLocatorCannotBeEncodedThroughStableBinding() throws {
        let content = DanmakuContentIdentity(
            configurationID: UUID(),
            siteKey: "site",
            contentID: "show"
        )
        let episode = DanmakuEpisodeIdentity(content: content, episodeID: "ep-1", title: "第1集")
        let binding = DanmakuBinding(
            editionIdentity: DanmakuEditionIdentity(episode: episode, editionID: "line-a"),
            locator: StableDanmakuLocator(
                kind: .providerEpisode,
                provider: "catpaw",
                resourceID: "123",
                displayName: "弹幕"
            )
        )

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(binding), encoding: .utf8))
        XCTAssertFalse(encoded.contains("127.0.0.1"))
        XCTAssertFalse(encoded.contains("headers"))
        XCTAssertFalse(encoded.contains("runtimeGeneration"))
    }

    func testPresentationMetadataDoesNotChangeStableEpisodeIdentity() {
        let configurationID = UUID()
        let firstContent = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            title: "原片名"
        )
        let renamedContent = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            title: "更新后的片名"
        )
        let first = DanmakuEpisodeIdentity(
            content: firstContent,
            episodeID: "ep-1",
            title: "第 1 集",
            episodeNumber: 1
        )
        let renamed = DanmakuEpisodeIdentity(
            content: renamedContent,
            episodeID: "ep-1",
            title: "EP01",
            episodeNumber: nil
        )

        XCTAssertEqual(first, renamed)
        XCTAssertEqual(Set([first, renamed]).count, 1)
    }

    func testClockUsesPlayerAnchorAndStopsDuringBuffering() {
        var clock = DanmakuClock()
        clock.anchor(
            mediaTime: 10,
            monotonicTime: 100,
            rate: 2,
            isPlaying: true,
            isBuffering: false,
            isSeeking: false,
            generation: 1
        )
        XCTAssertEqual(clock.currentTime(at: 101.5), 13, accuracy: 0.001)

        clock.anchor(
            mediaTime: 13,
            monotonicTime: 101.5,
            rate: 2,
            isPlaying: true,
            isBuffering: true,
            isSeeking: false,
            generation: 1
        )
        XCTAssertEqual(clock.currentTime(at: 110), 13, accuracy: 0.001)
    }

    func testSelectionRejectsLateAndLowerAuthorityResults() {
        let sessionID = UUID()
        var selection = DanmakuSessionSelection(playbackSessionID: sessionID, runtimeGeneration: 5)
        let automatic = source("auto", generation: 5)
        let user = source("user", generation: 5)
        let initialRevision = selection.selectionRevision
        XCTAssertTrue(selection.select(
            user,
            authority: .userSelection,
            playbackSessionID: sessionID,
            runtimeGeneration: 5,
            basedOnRevision: initialRevision
        ))
        XCTAssertFalse(selection.select(
            automatic,
            authority: .automaticMatch,
            playbackSessionID: sessionID,
            runtimeGeneration: 5,
            basedOnRevision: selection.selectionRevision
        ))
        XCTAssertFalse(selection.select(
            automatic,
            authority: .userSelection,
            playbackSessionID: sessionID,
            runtimeGeneration: 4,
            basedOnRevision: selection.selectionRevision
        ))
        XCTAssertEqual(selection.selectedSource?.stable.resourceID, "user")
    }

    func testAmbiguousProvidedSourcesRequireSelection() {
        let sources = [source("one", generation: 1), source("two", generation: 1)]
        XCTAssertNil(DanmakuProvidedSourcePolicy.automaticSource(from: sources))

        var preferred = sources
        preferred[1].isPreferred = true
        XCTAssertEqual(
            DanmakuProvidedSourcePolicy.automaticSource(from: preferred)?.stable.resourceID,
            "two"
        )
    }

    func testLaneSchedulerDropsCollisionInsteadOfDelaying() {
        var scheduler = DanmakuLaneScheduler(laneCount: 1)
        XCTAssertNotNil(scheduler.reserve(at: 1, textWidth: 100, viewportWidth: 500, lifetime: 6))
        XCTAssertNil(scheduler.reserve(at: 1.1, textWidth: 80, viewportWidth: 500, lifetime: 6))
        XCTAssertNotNil(scheduler.reserve(at: 3, textWidth: 80, viewportWidth: 500, lifetime: 6))
    }

    private func source(_ id: String, generation: UInt64) -> DanmakuSourceDescriptor {
        DanmakuSourceDescriptor(
            stable: StableDanmakuLocator(
                kind: .providerEpisode,
                provider: "test",
                resourceID: id,
                displayName: id
            ),
            runtime: RuntimeDanmakuLocator(
                url: URL(string: "https://example.com/\(id).xml")!,
                runtimeGeneration: generation
            )
        )
    }
}

final class DanmakuSmoothClockTests: XCTestCase {
    @discardableResult
    private func observe(_ clock: inout DanmakuClock, position: Double, sample: Double? = nil, now: Double,
                         rate: Double = 1, playing: Bool = true, buffering: Bool = false,
                         seeking: Bool = false, generation: UInt64 = 1) -> Bool {
        clock.synchronize(mediaTime: position, sampleUptime: sample, monotonicTime: now, rate: rate,
            isPlaying: playing, isBuffering: buffering, isSeeking: seeking, generation: generation)
    }
    func testRepeatedSnapshotDoesNotPullClockBack() {
        for sample in [nil, Optional(10.0)] {
            var clock = DanmakuClock()
            observe(&clock, position: 100, sample: sample, now: 10)
            for frame in 1...120 {
                let now = 10 + Double(frame) / 120
                XCTAssertFalse(observe(&clock, position: 100, sample: sample, now: now))
                XCTAssertEqual(clock.currentTime(at: now), 100 + now - 10, accuracy: 0.000001)
            }
        }
    }
    func testDelayedObservationUsesItsSampleTimeAndIgnoresOlderSamples() {
        var clock = DanmakuClock()
        observe(&clock, position: 100, sample: 10, now: 10.2)
        XCTAssertEqual(clock.currentTime(at: 10.2), 100.2, accuracy: 0.000001)
        observe(&clock, position: 100.1, sample: 10.1, now: 10.3)
        XCTAssertEqual(clock.currentTime(at: 10.3), 100.3, accuracy: 0.000001)
        observe(&clock, position: 98, sample: 9, now: 10.4)
        XCTAssertEqual(clock.currentTime(at: 10.4), 100.4, accuracy: 0.000001)
    }
    func testJitterCorrectionIsContinuousAndMonotonicAtSlowAndFastSpeeds() {
        for rate in [0.25, 1, 2] {
            var clock = DanmakuClock()
            observe(&clock, position: 100, sample: 10, now: 10, rate: rate)
            let before = clock.currentTime(at: 10.1)
            XCTAssertFalse(observe(&clock, position: 100 + 0.1 * rate - 0.05, sample: 10.1, now: 10.1, rate: rate))
            XCTAssertEqual(clock.currentTime(at: 10.1), before, accuracy: 0.000001)
            var previous = before
            for frame in 1...240 {
                let value = clock.currentTime(at: 10.1 + Double(frame) / 120)
                XCTAssertGreaterThan(value, previous)
                previous = value
            }
            // An isolated 50 ms observation must not force visible acceleration.
            XCTAssertEqual(previous, 100 + 2.1 * rate, accuracy: 0.02 * rate)
        }
    }
    func testPauseBufferResumeSpeedAndSeekRemainAuthoritative() {
        var clock = DanmakuClock()
        observe(&clock, position: 20, sample: 10, now: 10)
        observe(&clock, position: 20.2, sample: 10.2, now: 10.2, playing: false)
        XCTAssertEqual(clock.currentTime(at: 30), 20.2, accuracy: 0.000001)
        observe(&clock, position: 20.2, sample: 30, now: 30, buffering: true)
        XCTAssertEqual(clock.currentTime(at: 40), 20.2, accuracy: 0.000001)
        observe(&clock, position: 20.2, sample: 40, now: 40, rate: 2)
        XCTAssertEqual(clock.currentTime(at: 41), 22.2, accuracy: 0.000001)
        XCTAssertTrue(observe(&clock, position: 300, sample: 41, now: 41, seeking: true))
        XCTAssertEqual(clock.currentTime(at: 50), 300, accuracy: 0.000001)
        observe(&clock, position: 300, sample: 50, now: 50)
        XCTAssertEqual(clock.currentTime(at: 51), 301, accuracy: 0.000001)
        XCTAssertTrue(observe(&clock, position: 0, sample: 51, now: 51, generation: 2))
        XCTAssertEqual(clock.currentTime(at: 51), 0)
    }
}

final class DanmakuMotionRegressionTests: XCTestCase {
    private func sync(_ clock: inout DanmakuClock, _ position: Double, _ now: Double, rate: Double) {
        clock.synchronize(mediaTime: position, sampleUptime: now, monotonicTime: now, rate: rate,
                          isPlaying: true, isBuffering: false, isSeeking: false, generation: 1)
    }
    func testTransportJitterDoesNotModulateVisibleVelocity() {
        for rate in [0.25, 1, 2] {
            for hz in [60, 120] {
                var clock = DanmakuClock()
                sync(&clock, 100, 10, rate: rate)
                var previous = clock.currentTime(at: 10)
                for frame in 1...(hz * 20) {
                    let now = 10 + Double(frame) / Double(hz)
                    if frame % (hz / 10) == 0 {
                        let error = (frame / (hz / 10)) % 2 == 0 ? 0.05 : -0.05
                        sync(&clock, 100 + (now - 10 + error) * rate, now, rate: rate)
                    }
                    let current = clock.currentTime(at: now)
                    XCTAssertEqual((current - previous) * Double(hz) / rate, 1, accuracy: 0.002)
                    previous = current
                }
            }
        }
    }
    func testPersistentOffsetConvergesWithoutExceedingTwoPercentSlew() {
        for sign in [-1.0, 1.0] {
            var clock = DanmakuClock()
            sync(&clock, 100, 10, rate: 1)
            var previous = clock.currentTime(at: 10)
            for frame in 1...7200 {
                let now = 10 + Double(frame) / 120
                if frame % 12 == 0 { sync(&clock, 100 + now - 10 + sign * 0.20, now, rate: 1) }
                let current = clock.currentTime(at: now)
                XCTAssertEqual((current - previous) * 120, 1, accuracy: 0.020001)
                previous = current
            }
            XCTAssertEqual(previous, 160 + sign * 0.20, accuracy: 0.025)
        }
    }
}
