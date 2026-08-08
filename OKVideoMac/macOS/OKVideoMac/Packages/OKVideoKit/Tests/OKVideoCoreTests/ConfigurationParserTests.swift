import XCTest
@testable import OKVideoCore

final class ConfigurationParserTests: XCTestCase {
    func testMinimalConfiguration() throws {
        let data = try fixture("config-minimal", extension: "json")
        let value = try ConfigurationParser().parse(data)

        XCTAssertEqual(value.sites.count, 1)
        XCTAssertEqual(value.sites[0].key, "fixture")
        XCTAssertEqual(value.sites[0].type, 1)
    }

    func testCompleteConfigurationAndUnknownFieldsRoundTrip() throws {
        let data = try fixture("config-complete", extension: "json")
        let parser = ConfigurationParser()
        let value = try parser.parse(data)

        XCTAssertEqual(value.parses.count, 1)
        XCTAssertEqual(value.lives.count, 1)
        XCTAssertEqual(value.extra["futureTopLevel"], .object(["enabled": .bool(true)]))
        XCTAssertEqual(value.sites[0].extra["futureSiteField"], .string("kept"))
        XCTAssertEqual(value.proxy.first?.urls, ["http://127.0.0.1:7890"])
        XCTAssertEqual(value.headers.first?.host, "example.invalid")
        XCTAssertEqual(value.rules.first?.script, ["fixture-script"])

        let encoded = try parser.encode(value)
        let roundTrip = try parser.parse(encoded)
        XCTAssertEqual(roundTrip, value)
    }

    func testExtSupportsAllJSONTypes() throws {
        let data = try fixture("config-ext-types", extension: "json")
        let value = try ConfigurationParser().parse(data)

        XCTAssertEqual(value.sites[0].ext, .string("text"))
        XCTAssertEqual(value.sites[1].ext, .object(["token": .string("fixture")]))
        XCTAssertEqual(value.sites[2].ext, .array([.integer(1), .bool(true), .null]))
    }

    func testDuplicateSiteKeyKeepsLastFongMiEntry() throws {
        let data = try fixture("config-invalid", extension: "json")
        let configuration = try ConfigurationParser().parse(data)

        XCTAssertEqual(configuration.sites.count, 1)
        XCTAssertEqual(configuration.sites[0].key, "same")
        XCTAssertEqual(configuration.sites[0].name, "Second")
        XCTAssertEqual(
            configuration.sites[0].api,
            "https://example.invalid/two"
        )
    }

    func testDuplicateJSONObjectKeyIsRejectedIncludingEscapedSpelling() {
        let data = Data(
            #"{"sites":[],"future":{"name":1,"n\u0061me":2}}"#.utf8
        )
        XCTAssertThrowsError(try ConfigurationParser().parse(data)) { error in
            XCTAssertEqual(
                error as? AppError,
                .configuration("JSON 对象 future 存在重复字段：name")
            )
        }
    }

    func testOversizedConfigurationIsRejectedBeforeDecode() {
        let data = Data(repeating: 0x20, count: ConfigurationParser.maximumConfigurationSize + 1)
        XCTAssertThrowsError(try ConfigurationParser().parse(data))
    }

    func testResourceResolution() throws {
        let base = URL(string: "https://example.invalid/config/")!
        XCTAssertEqual(
            try ResourceResolver.resolve("../live.m3u", relativeTo: base).absoluteString,
            "https://example.invalid/live.m3u"
        )
        let inlinePoster = try ResourceResolver.resolve(
            "https://image.example.invalid/poster.jpg@Referer=https://api.example.invalid/@User-Agent=Fixture Player",
            relativeTo: nil
        )
        XCTAssertTrue(inlinePoster.absoluteString.contains("Fixture%20Player"))
        XCTAssertThrowsError(try ResourceResolver.resolve("live.m3u", relativeTo: nil))
    }

    private func fixture(_ name: String, extension ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
