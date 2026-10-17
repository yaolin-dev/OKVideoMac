import XCTest
@testable import OKVideoCore

final class TVBoxDayEPGTests: XCTestCase {
    private func config(_ zone: String = "Asia/Shanghai") -> TVBoxEPGConfiguration {
        .init(template: "https://guide.example.invalid/?channel=synthetic&date={date}", timeZoneID: zone)
    }
    private func decode(_ rows: [[String: String]], day: String = "2024-01-01", zone: String = "Asia/Shanghai") throws -> [EPGProgramme] {
        let data = try JSONSerialization.data(withJSONObject: ["date": day, "epg_data": rows])
        return try TVBoxDayEPG.payload(data: data, day: day, channelID: "fixture", configuration: config(zone)).guide.programmes
    }
    func testDayRequestUsesConfiguredDateAndRejectsUnknownTokens() throws {
        XCTAssertEqual(try TVBoxDayEPG.requestURL(configuration: config(), day: "2024-01-01").query,
                       "channel=synthetic&date=2024-01-01")
        for day in ["2024-02-30", "2024-1-1", "2024-01-01&token=x"] {
            XCTAssertThrowsError(try TVBoxDayEPG.requestURL(configuration: config(), day: day))
        }
        XCTAssertThrowsError(try TVBoxDayEPG.requestURL(configuration: .init(template: "https://example.invalid/{unknown}/{date}", timeZoneID: "UTC"), day: "2024-01-01"))
    }
    func testPreviousDayIsRequestedForOvernightCoverage() throws {
        let from = Date(timeIntervalSince1970: 1704123000) // local Jan 1 23:30
        XCTAssertEqual(try TVBoxDayEPG.days(configuration: config(), from: from, to: from.addingTimeInterval(7200)),
                       ["2023-12-31", "2024-01-01", "2024-01-02"])
    }
    func testCrossMidnightAnd24HourBoundaryHaveRealDurations() throws {
        let rows = try decode([["start":"23:30","end":"00:45","title":"Synthetic overnight"],
                               ["start":"20:00:00","end":"24:00:00","title":"Synthetic late"]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].end.timeIntervalSince(rows[0].start), 4 * 3600)
        XCTAssertEqual(rows[1].end.timeIntervalSince(rows[1].start), 75 * 60)
    }
    func testDSTFoldUsesSecondOccurrenceForAnEarlierEndClock() throws {
        let rows = try decode([["start":"01:50","end":"01:10","title":"Synthetic fold"]],
                              day: "2024-11-03", zone: "America/New_York")
        XCTAssertEqual(rows[0].end.timeIntervalSince(rows[0].start), 20 * 60)
    }
    func testDSTGapIsNotInventedAsAnOvernightProgramme() {
        XCTAssertThrowsError(try decode([["start":"01:30","end":"02:30","title":"Synthetic gap"]],
                                        day: "2024-03-10", zone: "America/New_York"))
        XCTAssertThrowsError(try decode([["start":"02:30","end":"03:30","title":"Synthetic gap"]],
                                        day: "2024-03-10", zone: "America/New_York"))
    }
    func testWrongResponseDateAndAllMalformedRowsDoNotReplaceValidData() throws {
        let data = Data(#"{"date":"2024-01-02","epg_data":[]}"#.utf8)
        XCTAssertThrowsError(try TVBoxDayEPG.payload(data: data, day: "2024-01-01", channelID: "fixture", configuration: config()))
        XCTAssertThrowsError(try decode([["start":"25:00","end":"26:00","title":"Invalid"]]))
        XCTAssertThrowsError(try decode([["start":"10:00","end":"10:00","title":"Zero"]]))
        XCTAssertEqual(try decode([]), [])
    }
    func testDuplicatesAreStableAndInvalidRowsDoNotHideOtherValidRows() throws {
        let rows = try decode([["start":"10:00","end":"11:00","title":"First"],
                               ["start":"10:00","end":"11:00","title":"Duplicate"],
                               ["start":"bad","end":"11:00","title":"Invalid"]])
        XCTAssertEqual(rows.map(\.title), ["First"])
    }
    func testResponseAndRowBudgetsAreEnforced() throws {
        XCTAssertThrowsError(try TVBoxDayEPG.payload(data: Data(repeating: 0, count: TVBoxDayEPG.maximumResponseBytes + 1),
                                                    day: "2024-01-01", channelID: "fixture", configuration: config()))
        XCTAssertThrowsError(try decode(Array(repeating: ["start":"10:00","end":"11:00","title":"Synthetic"], count: 513)))
    }
}
