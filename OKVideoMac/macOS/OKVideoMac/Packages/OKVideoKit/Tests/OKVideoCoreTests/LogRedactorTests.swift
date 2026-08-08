import XCTest
@testable import OKVideoCore

final class LogRedactorTests: XCTestCase {
    func testURLRedactsUserInfoWithoutQueryItems() throws {
        let url = try XCTUnwrap(
            URL(string: "https://account:password@example.invalid/index.js.md5")
        )

        let redacted = LogRedactor.url(url)

        XCTAssertFalse(redacted.contains("account"))
        XCTAssertFalse(redacted.contains("password"))
        XCTAssertTrue(redacted.contains("example.invalid/index.js.md5"))
    }

    func testURLRedactsSensitiveQueryAndUserInfoTogether() throws {
        let url = try XCTUnwrap(
            URL(
                string: "https://user:secret@example.invalid/config"
                    + "?token=value&mode=full"
            )
        )

        let redacted = LogRedactor.url(url)

        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("value"))
        XCTAssertTrue(redacted.contains("mode=full"))
    }
}
