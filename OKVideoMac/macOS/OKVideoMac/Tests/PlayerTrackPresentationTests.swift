import XCTest
import OKVideoCore
@testable import OKVideoMac

@MainActor final class PlayerTrackPresentationTests: XCTestCase {
    func testTrackLabelsKeepUsefulDescriptionsAndLocalizeGenericNames() {
        let generic = PlayerTrackPresentation.label(.init(id: 1, type: .audio, title: "audio 1"))
        XCTAssertFalse(generic.contains("audio 1")); XCTAssertTrue(generic.contains("1"))
        XCTAssertEqual(PlayerTrackPresentation.label(.init(id: 2, type: .audio, title: "Director Commentary")), "Director Commentary")
    }
}
