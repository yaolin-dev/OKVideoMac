import XCTest
@testable import OKVideoCore

final class OriginalMediaResourceTests: XCTestCase {
    func file(_ id: String? = "file-13", path: String? = nil) -> OriginalMediaResource {
        OriginalMediaResource(provider: "baidu", shareID: "share", ownerID: "owner", fileID: id,
            originalFilename: "S01E13.mp4", providerPath: "%2Fsharelink0-13%2FS01E13.mp4",
            shareRelativePath: path, byteSize: 1571407203, provenance: "wogg-baidu-detail")
    }
    func testIdentityIgnoresDisplayAndPathChangesButRejectsFileReplacement() throws {
        let original = file(); var changed = original
        changed.originalFilename = "第13集.mp4"; changed.providerPath = "new-provider-path"
        XCTAssertEqual(original.match(changed), .sameFile)
        XCTAssertEqual(original.match(file("replacement")), .conflict)
        changed.shareID = "other-share"
        XCTAssertEqual(original.match(changed), .conflict)
        XCTAssertEqual(original.match(file(nil)), .unknown)
        let restored = try JSONDecoder().decode(OriginalMediaResource.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, restored)
    }
    func testOnlyVerifiedRelativePathCanRecoverIDLessFiles() {
        XCTAssertEqual(file(nil).match(file(nil)), .unknown)
        XCTAssertEqual(file(nil, path: "folder/S01E13.mp4").match(file(nil, path: "folder/S01E13.mp4")), .samePath)
        XCTAssertEqual(file(nil, path: "folder/S01E13.mp4").match(file(nil, path: "other/S01E13.mp4")), .unknown)
        var other = file(nil, path: "folder/S01E13.mp4"); other.byteSize = 1
        XCTAssertEqual(file(nil, path: "folder/S01E13.mp4").match(other), .conflict)
    }
    func testLegacyEpisodeAndOpaqueReferenceCannotInventMetadata() throws {
        let episode = try JSONDecoder().decode(PlayEpisode.self, from: Data(#"{"name":"第13集","url":"opaque"}"#.utf8))
        XCTAssertNil(episode.originalResource)
        let copy = try JSONDecoder().decode(PlayEpisode.self, from: JSONEncoder().encode(PlayEpisode(name: "第13集", url: "opaque", originalResource: file())))
        XCTAssertEqual(copy.originalResource?.originalFilename, "S01E13.mp4")
        var invalid = file(); invalid.fileID = "https://media.invalid/?token=secret"
        XCTAssertNil(invalid.validated)
    }

    func testBridgeDetailAttachesMetadataWithoutChangingTheSourceLabelOrToken() throws {
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file()))
        let data = try JSONSerialization.data(withJSONObject: ["list": [[
            "vod_id": "132964", "vod_name": "影片", "vod_play_from": "嘟嘟无限2",
            "vod_play_url": "[1.46GB]第13集.mp4$CURRENT_TOKEN#Other$OPAQUE",
            "okvideo_original_resources": [[metadata, NSNull()]]
        ]]])
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let config = try ConfigurationParser().parse(Data(#"{"sites":[{"key":"fixture","name":"Fixture","type":3,"api":"csp_WoGGGuard"}]}"#.utf8))
        let detail = try SpiderResponseMapper.detail(value, site: XCTUnwrap(config.sites.first), baseURL: nil)
        let episodes = try XCTUnwrap(detail.playSources.first).episodes
        XCTAssertEqual(episodes[0].name, "[1.46GB]第13集.mp4")
        XCTAssertEqual(episodes[0].url, "CURRENT_TOKEN")
        XCTAssertEqual(episodes[0].originalResource?.originalFilename, "S01E13.mp4")
        XCTAssertNil(episodes[1].originalResource)
    }
}
