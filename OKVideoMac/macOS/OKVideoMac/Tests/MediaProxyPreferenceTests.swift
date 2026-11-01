import XCTest
import CFNetwork
import OKVideoCore
@testable import OKVideoMac

final class MediaProxyPreferenceTests: XCTestCase {
    private func media(_ address: String) -> ResolvedMedia {
        ResolvedMedia(url: URL(string: address)!, headers: [:], siteKey: "fixture", sourceName: "Quark", episodeName: "Film")
    }
    private let settings: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8911,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8912, "ExceptionsList": ["*.local", "169.254/16"]]

    func testOffIsExplicitAndSystemHTTPAndHTTPSAreSelectedSeparately() throws {
        for address in ["http://video.example/a.mp4", "https://video.example/a.m3u8"] {
            let off = MediaPlaybackNetworkPlan.make(media: media(address), enabled: false, settings: settings)
            XCTAssertEqual(off.decision, .direct); XCTAssertEqual(off.route, .direct)
            XCTAssertEqual(off.decision?.mpvOptions.first(where: { $0.0 == "stream-lavf-o" })?.1, "http_proxy=")
            let on = MediaPlaybackNetworkPlan.make(media: media(address), enabled: true, settings: settings)
            XCTAssertEqual(on.route, .systemProxy)
            XCTAssertEqual(on.decision, .httpProxy(URL(string: address.hasPrefix("https") ? "http://127.0.0.1:8912" : "http://127.0.0.1:8911")!))
        }
        XCTAssertEqual(MediaPlaybackNetworkPlan.make(media: media("https://video.example/a"), enabled: true, settings: [:]).route, .direct)
        XCTAssertEqual(MediaPlaybackNetworkPlan.make(media: media("http://video.local/a"), enabled: true, settings: settings).route, .direct)
    }
    func testLocalRelayIsNeverReportedAsRemoteDirectAndControlHeaderCannotLeak() throws {
        let remote = media("https://video.example/a.mp4")
        let header = MediaPlaybackNetworkPlan.bridgeHeader
        XCTAssertNil(MediaPlaybackNetworkPlan.make(media: remote, enabled: false, settings: settings).headers([header: "provider-injected"])[header])
        let local = media("http://127.0.0.1:19978/proxy/media/fixture")
        let plan = MediaPlaybackNetworkPlan.make(media: local, enabled: true, settings: settings)
        XCTAssertEqual(plan.decision, .direct); XCTAssertEqual(plan.route, .providerManaged)
        XCTAssertNil(plan.headers(["Cookie": "SESSION", header: "untrusted"])[header])
        let encoded = try XCTUnwrap(plan.bridgePolicy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
        XCTAssertEqual((object["http"] as? [String: Any])?["host"] as? String, "10.0.2.2")
        XCTAssertEqual((object["https"] as? [String: Any])?["port"] as? Int, 8912)
        XCTAssertEqual(plan.headers(["Cookie": "SESSION"])["Cookie"], "SESSION")
        XCTAssertFalse(encoded.contains("SESSION"))
        let catpaw = MediaPlaybackNetworkPlan.make(media: media("http://127.0.0.1:34567/proxy"), enabled: false, settings: [:])
        XCTAssertEqual(catpaw.route, .providerManaged); XCTAssertNil(catpaw.bridgePolicy)
    }
    func testUnsupportedTypesCannotSilentlyFallBackAndFileProtocolsAreUnaffected() throws {
        let unsupported: [[String: Any]] = [["ProxyAutoConfigEnable": 1], ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 9999]]
        for config in unsupported {
            let on = MediaPlaybackNetworkPlan.make(media: media("https://video.example/a"), enabled: true, settings: config)
            XCTAssertEqual(on.route, .unsupportedProxy); XCTAssertThrowsError(try on.validate())
            XCTAssertNoThrow(try MediaPlaybackNetworkPlan.make(media: media("https://video.example/a"), enabled: false, settings: config).validate())
        }
        XCTAssertEqual(MediaPlaybackNetworkPlan.make(media: media("file:///tmp/movie.mp4"), enabled: true, settings: settings).route, .localFile)
        XCTAssertEqual(MediaPlaybackNetworkPlan.make(media: media("rtsp://video.example/live"), enabled: true, settings: settings).route, .otherProtocol)
    }
    func testSnapshotKeepsIntentAndBridgeUsesSelectedRemoteOrigin() throws {
        var enabled = true
        let first = MediaPlaybackNetworkPlan.make(media: media("https://video.example/a"), enabled: enabled, settings: settings)
        enabled = false
        let next = MediaPlaybackNetworkPlan.make(media: media("https://video.example/a"), enabled: enabled, settings: settings)
        XCTAssertEqual(first.enabled, true); XCTAssertEqual(first.route, .systemProxy)
        XCTAssertEqual(next.enabled, false); XCTAssertEqual(next.route, .direct)
        let relay = media("http://127.0.0.1:19978/v1/media?url=https%3A%2F%2Fvideo.example%2Fa")
        let bridged = MediaPlaybackNetworkPlan.make(media: relay, enabled: true, settings: settings)
        XCTAssertEqual(bridged.route, .systemProxy); XCTAssertEqual(bridged.decision, .direct)
        let off = MediaPlaybackNetworkPlan.make(media: relay, enabled: false, settings: settings)
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(off.bridgePolicy)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, false); XCTAssertNil(object["http"])
    }
    func testBridgePreparationPinsAnIndependentCapabilityWithoutMediaHeaders() async throws {
        let original = media("http://127.0.0.1:19978/v1/media?url=https%3A%2F%2Fvideo.example%2Fa")
        let plan = MediaPlaybackNetworkPlan.make(media: original, enabled: true, settings: settings)
        let prepared = try await MediaBridgeNetworkPreparation.prepare(original, plan: plan) { request in
            XCTAssertEqual(request.url?.path, "/v1/media-network")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: MediaPlaybackNetworkPlan.bridgeHeader))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["url"] as? String, original.url.absoluteString)
            XCTAssertEqual(body["policy"] as? String, plan.bridgePolicy)
            XCTAssertEqual(body["cancelOnDisconnect"] as? Bool, true)
            return (Data(#"{"ok":true,"path":"/proxy/media/12345678-1234-1234-1234-123456789abc"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        XCTAssertNotEqual(prepared.url, original.url)
        XCTAssertEqual(prepared.mediaProxyPreference, true)
        XCTAssertEqual(prepared.mediaNetworkRouteOverride, .systemProxy)
        XCTAssertEqual(MediaPlaybackNetworkPlan.make(media: prepared, enabled: true, settings: settings).route, .systemProxy)
        XCTAssertTrue(prepared.headers.dictionary.isEmpty)
        do {
            _ = try await MediaBridgeNetworkPreparation.prepare(original, plan: plan) { request in
                (Data(#"{"ok":true,"path":"https://remote.example/unsafe"}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            XCTFail("A control response must not replace playback with a remote URL")
        } catch { XCTAssertTrue(error is AppError) }
    }

}
