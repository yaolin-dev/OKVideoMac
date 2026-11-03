import XCTest
import OKVideoCore
@testable import OKVideoMac

final class HistoryBridgeReliabilityTests: XCTestCase {
    private func decode(_ body: [String: Any], id: UUID, status: Int = 500) throws -> ConfigurationInteractionTerminalResponse {
        AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: id, data: try JSONSerialization.data(withJSONObject: body),
            response: try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: status, httpVersion: nil, headerFields: nil)), requiresScopedIdentity: true)
    }

    func testLegacyUnscopedFailurePreservesCauseButNeverResultOrCompletion() throws {
        for status in [200, 202, 409, 500, 503] {
            let result = try decode(["ok": false, "error": "SocketException: Connection reset",
                "result": "stale-result", "interaction": ["phase": "completed", "outcome": "completed", "terminal": true]],
                id: UUID(), status: status)
            XCTAssertEqual(result.outcome, .failed)
            XCTAssertEqual(result.error, "SocketException: Connection reset")
            XCTAssertNil(result.providerResult)
            XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.spider(result.error!)))
        }
    }

    func testOwnedFailureRetainsCategoryAndBothIdentities() throws {
        let id = UUID()
        let result = try decode(["ok": false, "error": "ProviderDetailUnavailableAfterRecovery",
            "failureKind": "sourceUnavailable", "interactionID": id.uuidString,
            "interaction": ["interactionID": id.uuidString, "phase": "failed", "outcome": "failed", "terminal": true]], id: id)
        XCTAssertEqual(result.requestID, id)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.error, "ProviderDetailUnavailableAfterRecovery")
        XCTAssertEqual(result.failureKind, "sourceUnavailable")
        XCTAssertNil(result.providerResult)
    }

    func testConflictingOrMalformedOwnersRejectEvenWhenOneMatches() throws {
        let id = UUID()
        for invalid in [UUID().uuidString, "", "not-a-uuid"] {
            for pair in [(id.uuidString, invalid), (invalid, id.uuidString)] {
                for ok in [true, false] {
                    let result = try decode(["ok": ok, "result": "foreign", "error": "foreign-error",
                        "interactionID": pair.0, "interaction": ["interactionID": pair.1, "outcome": "completed"]],
                        id: id, status: ok ? 200 : 500)
                    XCTAssertEqual(result.outcome, .failed)
                    XCTAssertNil(result.providerResult)
                    XCTAssertEqual(result.error, "Java/Dex 桥返回了其他配置操作的结果")
                }
            }
        }
    }

    func testMissingSuccessIdentityIsProtocolFailureNotDifferentRequest() throws {
        let result = try decode(["ok": true, "result": "unscoped"], id: UUID(), status: 200)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.providerResult)
        XCTAssertEqual(result.error, "Java/Dex 桥响应缺少请求编号")
    }

    func testBridgeTransportFailureCannotEstablishMissingOriginalMovie() throws {
        // A missing RPC endpoint / gateway is not proof that a provider's
        // movie ID was deleted. Do not manufacture title-based replacement.
        for status in [404, 410, 500, 503] {
            let result = try decode(["ok": false, "error": "HTTP \(status)"], id: UUID(), status: status)
            XCTAssertFalse(HistoryDetailFailurePolicy.permitsTitleRecovery(AppError.spider(result.error!)))
        }
    }
}
