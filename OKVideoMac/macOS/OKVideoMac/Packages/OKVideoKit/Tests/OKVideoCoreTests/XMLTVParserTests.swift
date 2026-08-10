import XCTest
@testable import OKVideoCore

final class XMLTVParserTests: XCTestCase {
    private let compressedFixture = """
    H4sIAAAAAAAC/5WQywqDMBBFfyVkW9qMWfQBY9x1WfoLqU7bQBIlRrF/X0WxForQWZ7LzLkMZp2zrKVQm9KnPNkBzxTGVmH+1N6TZaZI+d10sQnEFRamrqx+bb12pM4jRvFFUUyrCqtQPoJ2jtiEPqdYHXWIKZcg93CQJwnDsA0cAYawrBZZssj6diZaUtfmZk3O5g4jRTE7/9MnK3r5Q3+hLq7KRf/EN6Myf/leAQAA
    """

    func testGzipXMLTVAndCurrentNextLookup() throws {
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
