import XCTest
@testable import OKVideoCore

final class XMLTVParserTests: XCTestCase {
    func testDateCachePreservesFormatsOffsetsAndPerParserTimeZone() throws {
        let times = ["20260729200000 +0800", "20260729120000+0000",
                     "20260729070000 -0500", "20260729200000"]
        let ends = ["20260729210000 +0800", "20260729130000+0000",
                    "20260729080000 -0500", "20260729210000"]
        let rows = (0..<100).map { n in
            "<programme channel='a' start='\(times[n % 4])' stop='\(ends[n % 4])'><title>T\(n)</title></programme>"
        }.joined()
        let data = Data(("<tv>" + rows + "</tv>").utf8)
        let local = try XMLTVParser(defaultTimeZone: TimeZone(secondsFromGMT: 8 * 3600)).parse(data)
        XCTAssertEqual(local.programmes.count, 100)
        XCTAssertEqual(Set(local.programmes.map(\.start)).count, 1)
        XCTAssertEqual(Set(local.programmes.map(\.end)).count, 1)
        let utc = try XMLTVParser(defaultTimeZone: TimeZone(secondsFromGMT: 0)).parse(data)
        XCTAssertEqual(utc.programmes[3].start.timeIntervalSince(local.programmes[3].start), 8 * 3600)
        XCTAssertEqual(utc.programmes[0].start, local.programmes[0].start)
    }

    func testUniqueDatesEvictWithoutDroppingProgrammes() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let anchor = Date(timeIntervalSince1970: 1_789_862_400)
        let rows = (0..<5_000).map { n in
            let start = formatter.string(from: anchor.addingTimeInterval(Double(n) * 60))
            let end = formatter.string(from: anchor.addingTimeInterval(Double(n + 1) * 60))
            return "<programme channel='a' start='\(start)' stop='\(end)'><title>T\(n)</title></programme>"
        }.joined()
        let parser = XMLParser(data: Data(("<tv>" + rows + "</tv>").utf8))
        var emitted = 0
        let delegate = try XMLTVParser().parseXML(parser, boundsDateTemporaries: true) { programme, _ in
            XCTAssertEqual(programme.start, anchor.addingTimeInterval(Double(emitted) * 60))
            emitted += 1
        }
        XCTAssertEqual(emitted, 5_000)
        XCTAssertEqual(delegate.cachedDateCount, XMLTVDelegate.maximumCachedDates)
    }

    private let compressedFixture = """
    H4sIAAAAAAAC/5WQywqDMBBFfyVkW9qMWfQBY9x1WfoLqU7bQBIlRrF/X0WxForQWZ7LzLkMZp2zrKVQm9KnPNkBzxTGVmH+1N6TZaZI+d10sQnEFRamrqx+bb12pM4jRvFFUUyrCqtQPoJ2jtiEPqdYHXWIKZcg93CQJwnDsA0cAYawrBZZssj6diZaUtfmZk3O5g4jRTE7/9MnK3r5Q3+hLq7KRf/EN6Myf/leAQAA
    """

    func testGzipXMLTVAndCurrentNextLookup() async throws {
        let data = try XCTUnwrap(Data(base64Encoded: compressedFixture))
        XCTAssertTrue(Gzip.isCompressed(data))

        let guide = try XMLTVParser().parse(data)
        XCTAssertEqual(guide.channels, [EPGChannel(id: "fixture", displayName: "Fixture")])
        XCTAssertEqual(guide.programmes.map(\.title), ["Public Fixture", "Next Fixture"])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29,
                    hour: 20,
                    minute: 30
                )
            )
        )
        let currentAndNext = guide.currentAndNext(channelID: "fixture", at: date)
        XCTAssertEqual(currentAndNext.current?.title, "Public Fixture")
        XCTAssertEqual(currentAndNext.next?.title, "Next Fixture")

        let channel = LiveChannel(
            groupName: "Fixture",
            name: "Fixture",
            tvgName: "fixture",
            streams: []
        )
        let indexed = XMLTVScheduleIndex(guide: guide)
            .currentAndNext(for: channel, at: date)
        XCTAssertEqual(indexed.current?.title, "Public Fixture")
        XCTAssertEqual(indexed.next?.title, "Next Fixture")

        let detachedIndex = await XMLTVScheduleIndexBuilder.build(guide: guide)
            .currentAndNext(for: channel, at: date)
        XCTAssertEqual(detachedIndex.current?.title, "Public Fixture")
        XCTAssertEqual(detachedIndex.next?.title, "Next Fixture")
    }

    func testInvalidProgrammeDoesNotDiscardValidEntries() throws {
        let xml = Data(
            """
            <tv>
              <programme channel="fixture" start="invalid" stop="invalid">
                <title>Invalid</title>
              </programme>
              <programme channel="fixture" start="20260729200000 +0800" stop="20260729210000 +0800">
                <title>Valid</title>
              </programme>
            </tv>
            """.utf8
        )
        let guide = try XMLTVParser().parse(xml)
        XCTAssertEqual(guide.programmes.map(\.title), ["Valid"])
    }
}
