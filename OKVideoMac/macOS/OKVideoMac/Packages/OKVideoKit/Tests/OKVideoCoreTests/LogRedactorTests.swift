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

    func testHeadersRedactAuthenticationAndCookieValues() {
        let redacted = LogRedactor.headers([
            "Authorization": "Bearer super-secret",
            "Cookie": "session=private",
            "Accept": "application/json"
        ])

        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["Cookie"], "<redacted>")
        XCTAssertEqual(redacted["Accept"], "application/json")
    }

    func testNestedJSONAndFreeFormTextAreSanitized() throws {
        let object: [String: Any] = [
            "site": "fixture",
            "nested": [
                "token": "nested-secret",
                "url": "http://user:pass@example.invalid/a?stoken=query-secret"
            ]
        ]
        let data = try XCTUnwrap(LogRedactor.jsonData(
            try JSONSerialization.data(withJSONObject: object)
        ))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("nested-secret"))
        XCTAssertFalse(text.contains("query-secret"))
        XCTAssertFalse(text.contains("user"))
        XCTAssertFalse(text.contains("pass"))
        XCTAssertTrue(text.contains("fixture"))

        let line = LogRedactor.text(
            "Authorization: Bearer abc123\npath=/Users/alice/Library/cache token=xyz"
        )
        XCTAssertFalse(line.contains("abc123"))
        XCTAssertFalse(line.contains("alice"))
        XCTAssertFalse(line.contains("xyz"))
        XCTAssertTrue(line.contains("<HOME>"))
    }
}
