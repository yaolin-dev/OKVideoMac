import XCTest
@testable import OKVideoCore

final class LiveSourceParserTests: XCTestCase {
    func testM3UAttributesHeadersAndMultipleLines() throws {
        let playlist = try LiveSourceParser().parse(
            """
            #EXTM3U tvg-url="https://example.invalid/epg.xml.gz"
            #EXTINF:-1 tvg-id="fixture" tvg-name="Fixture TV" tvg-chno="7" tvg-logo="logo.png" group-title="Public",Fixture Channel
            #EXTVLCOPT:http-user-agent=FixtureAgent
            #EXTVLCOPT:http-referrer=https://example.invalid/
            https://media.example.invalid/live.m3u8|Origin=https%3A%2F%2Forigin.example.invalid
            #EXTINF:-1 tvg-id="fixture" group-title="Public",Fixture Channel
            https://backup.example.invalid/live.m3u8
            """,
            baseURL: URL(string: "https://example.invalid/config/")!
        )

        XCTAssertEqual(playlist.format, .m3u)
        XCTAssertEqual(playlist.epgURL?.absoluteString, "https://example.invalid/epg.xml.gz")
        XCTAssertEqual(playlist.groups.count, 1)
        let channel = try XCTUnwrap(playlist.groups.first?.channels.first)
        XCTAssertEqual(channel.number, "7")
        XCTAssertEqual(channel.logoURL?.absoluteString, "https://example.invalid/config/logo.png")
        XCTAssertEqual(channel.streams.count, 2)
        XCTAssertEqual(channel.streams[0].headers["User-Agent"], "FixtureAgent")
        XCTAssertEqual(channel.streams[0].headers["Referer"], "https://example.invalid/")
        XCTAssertEqual(channel.streams[0].headers["Origin"], "https://origin.example.invalid")
    }

    func testM3UKeepsRTSPRTMPAndUDPChannels() throws {
        let playlist = try LiveSourceParser().parse(
            """
            #EXTM3U
            #EXTINF:-1 group-title="Broadcast",RTSP
            rtsp://192.0.2.1/live
            #EXTINF:-1 group-title="Broadcast",RTMP
            rtmp://192.0.2.2/live
            #EXTINF:-1 group-title="Broadcast",UDP
            udp://@239.0.0.1:1234
            """
        )

        let channels = try XCTUnwrap(playlist.groups.first?.channels)
        XCTAssertEqual(channels.map(\.name), ["RTSP", "RTMP", "UDP"])
        XCTAssertEqual(
            channels.compactMap { $0.streams.first?.url.scheme },
            ["rtsp", "rtmp", "udp"]
        )
    }

    func testM3UNormalizesMalformedPercentEscapesWithoutDroppingChannels() throws {
        let playlist = try LiveSourceParser().parse(
            """
            #EXTM3U
            #EXTINF:-1 group-title="Broadcast",Incomplete Escape
            rtsp://192.0.2.1/live?token=%0%2CEND
            #EXTINF:-1 group-title="Broadcast",Repeated Percent
            rtsp://192.0.2.2/live?token=%%2 value
            """
        )

        let channels = try XCTUnwrap(playlist.groups.first?.channels)
        XCTAssertEqual(channels.map(\.name), [
            "Incomplete Escape",
            "Repeated Percent"
        ])
        XCTAssertEqual(
            channels[0].streams.first?.url.absoluteString,
            "rtsp://192.0.2.1/live?token=%250%2CEND"
        )
        XCTAssertEqual(
            channels[1].streams.first?.url.absoluteString,
            "rtsp://192.0.2.2/live?token=%25%252%20value"
        )
    }

    func testTXTGroupsPasswordMultipleLinesAndHeaders() throws {
        let playlist = try LiveSourceParser().parse(
            """
            Public_1234,#genre#
            ua=FixtureAgent
            Fixture,http://one.example.invalid/live.m3u8|Referer=https%3A%2F%2Fexample.invalid%2F#http://two.example.invalid/live.m3u8
            """,
            baseURL: nil
        )

        XCTAssertEqual(playlist.format, .text)
        XCTAssertEqual(playlist.groups.first?.name, "Public")
        XCTAssertEqual(playlist.groups.first?.password, "1234")
        XCTAssertEqual(playlist.groups.first?.channels.first?.streams.count, 2)
        XCTAssertEqual(
            playlist.groups.first?.channels.first?.streams.first?.headers["User-Agent"],
            "FixtureAgent"
        )
    }

    func testJSONGroupsAndNamedLines() throws {
        let playlist = try LiveSourceParser().parse(
            """
            [
              {
                "name":"Public",
                "channel":[
                  {
                    "name":"Fixture",
                    "urls":[
                      "https://one.example.invalid/live.m3u8$Primary",
                      "https://two.example.invalid/live.m3u8$Backup"
                    ],
                    "ua":"FixtureAgent",
                    "referer":"https://example.invalid/",
                    "origin":"https://origin.example.invalid"
                  }
                ]
              }
            ]
            """
        )

        let streams = try XCTUnwrap(playlist.groups.first?.channels.first?.streams)
        XCTAssertEqual(streams.map(\.name), ["Primary", "Backup"])
        XCTAssertEqual(streams.first?.headers["Referer"], "https://example.invalid/")
        XCTAssertEqual(streams.first?.headers["User-Agent"], "FixtureAgent")
        XCTAssertEqual(streams.first?.headers["Origin"], "https://origin.example.invalid")
    }

    func testMalformedLinesAreIsolated() throws {
        let playlist = try LiveSourceParser().parse(
            """
            Public,#genre#
            invalid
            Fixture,http://example.invalid/live.m3u8
            Broken,not-a-url
            """
        )
        XCTAssertEqual(playlist.groups.first?.channels.map(\.name), ["Fixture"])
    }
}
