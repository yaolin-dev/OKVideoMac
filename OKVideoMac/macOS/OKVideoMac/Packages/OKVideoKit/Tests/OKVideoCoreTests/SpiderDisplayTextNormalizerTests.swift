import XCTest
@testable import OKVideoCore

final class SpiderDisplayTextNormalizerTests: XCTestCase {
    func testPlainPeopleTextKeepsVisibleNames() {
        XCTAssertEqual(
            SpiderDisplayTextNormalizer.people("安格瑞·赖斯、朱莉娅·罗杰斯"),
            "安格瑞·赖斯、朱莉娅·罗杰斯"
        )
    }

    func testCatPawCRAnchorsExposeOnlyLabels() {
        let value = #"[a=cr:{"id":"s-1-a","name":"payload-a"}/]安格瑞&amp;赖斯[/a], [a=cr:{"id":"s-1-b","name":"payload-b"}/]Julia Rogers[/a]"#

        XCTAssertEqual(
            SpiderDisplayTextNormalizer.people(value),
            "安格瑞&赖斯、Julia Rogers"
        )
    }

    func testMixedPeopleTextNormalizesSeparatorsAndRemovesDuplicates() {
        let value = #"普通演员；[a=cr:{"id":"one"}/]演员甲[/a]，演员甲|演员乙"#

        XCTAssertEqual(
            SpiderDisplayTextNormalizer.people(value),
            "普通演员、演员甲、演员乙"
        )
    }

    func testMalformedPayloadDoesNotLeakJSON() {
        let value = #"演员甲, [a=cr:{"id":"secret","name":"不应显示"}]损坏[/a], 演员乙"#
        let normalized = SpiderDisplayTextNormalizer.people(value)

        XCTAssertEqual(normalized, "演员甲、演员乙")
        XCTAssertFalse(normalized?.contains("secret") ?? true)
        XCTAssertFalse(normalized?.contains("id") ?? true)
    }

    func testDanglingClosingMarkerStillKeepsSafeVisibleLabel() {
        let value = #"[a=cr:{"id":"safe"}/]演员甲, 演员乙"#

        XCTAssertEqual(
            SpiderDisplayTextNormalizer.people(value),
            "演员甲、演员乙"
        )
    }

    func testBlankPeopleTextReturnsNil() {
        XCTAssertNil(SpiderDisplayTextNormalizer.people(" \n\t "))
        XCTAssertNil(SpiderDisplayTextNormalizer.people(nil))
    }
}
