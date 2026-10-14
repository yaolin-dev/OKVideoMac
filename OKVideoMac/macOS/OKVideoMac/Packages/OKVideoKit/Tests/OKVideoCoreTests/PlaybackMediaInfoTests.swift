import XCTest
@testable import OKVideoCore

final class PlaybackMediaInfoTests: XCTestCase {
    func testSourceDimensionsIgnoreDisplaySizeAndQualityLabels() {
        let info = PlaybackMediaInfo(properties: ["video-dec-params/w": "1920", "video-dec-params/h": "800",
            "dwidth": "3840", "dheight": "2160", "title": "4K Blu-ray", "container-fps": "23.976"])
        XCTAssertEqual(info.width, 1920); XCTAssertEqual(info.height, 800)
        XCTAssertEqual(info.nominalFrameRate, 23.976)
        XCTAssertNil(PlaybackMediaInfo(properties: ["dwidth": "3840", "title": "4K"]).width)
    }
    func testUnavailableMalformedAndNonfiniteNumbersStayUnknown() {
        for value in ["0", "-1", "nan", "inf", "N/A", "999999999999999999999999999"] {
            let info = PlaybackMediaInfo(properties: ["video-dec-params/w": value, "file-size": value,
                "container-fps": value, "audio-params/samplerate": value, "video-bitrate": value], includeStatistics: true)
            XCTAssertNil(info.width); XCTAssertNil(info.fileSizeBytes); XCTAssertNil(info.audioSampleRate)
            if value != "999999999999999999999999999" { XCTAssertNil(info.nominalFrameRate); XCTAssertNil(info.statistics?.videoBitrate) }
        }
    }
    func testStatisticsHaveSeparateUnitsAndAreRemovedForSummary() {
        let info = PlaybackMediaInfo(properties: ["current-tracks/video/codec": "hevc", "video-bitrate": "8000000",
            "audio-bitrate": "192000", "cache-speed": "2000000", "frame-drop-count": "0"], includeStatistics: true, isNetwork: true)
        XCTAssertEqual(info.statistics?.videoBitrate, 8_000_000)
        XCTAssertEqual(info.statistics?.networkBytesPerSecond, 2_000_000)
        XCTAssertEqual(info.statistics?.droppedFrames, 0)
        XCTAssertNil(info.withoutStatistics.statistics)
        XCTAssertEqual(info.withoutStatistics.videoCodec, "hevc")
        XCTAssertNil(PlaybackMediaInfo(properties: ["cache-speed": "2000000"], includeStatistics: true).statistics?.networkBytesPerSecond)
    }
    func testFileNameNeverContainsAnAddressCredentialsOrParentPath() {
        for name in ["https://user:secret@example.invalid/private/movie.mp4?token=secret#fragment",
                     "file:///Users/private/Videos/movie.mp4", "/Users/private/Videos/movie.mp4",
                     "C:\\private\\movie.mp4"] {
            XCTAssertEqual(PlaybackMediaInfo.safeFileName(name), "movie.mp4")
        }
        XCTAssertNil(PlaybackMediaInfo.safeFileName("https://user:secret@example.invalid/"))
        for address in ["rtmps://user:secret@example.invalid", "srt://user:secret@example.invalid:9000",
                        "//user:secret@example.invalid/"] {
            XCTAssertNil(PlaybackMediaInfo.safeFileName(address))
        }
        XCTAssertEqual(PlaybackMediaInfo.safeFileName("rtmps://user:secret@example.invalid/movie.mp4?token=secret"), "movie.mp4")
        XCTAssertEqual(PlaybackMediaInfo.safeFileName("https://example.invalid/%2Fprivate%2Fmovie.mp4?token=secret"), "movie.mp4")
        XCTAssertNil(PlaybackMediaInfo.safeFileName("bad\nname"))
    }
    func testAudioDecoderParametersTakePriorityOverSelectedTrackMetadata() {
        let hints = ["current-tracks/audio/demux-samplerate": "48000", "current-tracks/audio/demux-channels": "5.1"]
        let declared = PlaybackMediaInfo(properties: hints)
        XCTAssertEqual(declared.audioSampleRate, 48000); XCTAssertEqual(declared.audioChannels, "5.1")
        let decoded = PlaybackMediaInfo(properties: hints.merging(["audio-params/samplerate": "44100", "audio-params/channels": "stereo"]) { _, new in new })
        XCTAssertEqual(decoded.audioSampleRate, 44100); XCTAssertEqual(decoded.audioChannels, "stereo")
    }
    func testAudioOnlyAndSizeUnknownRemainRepresentable() {
        let info = PlaybackMediaInfo(properties: ["current-tracks/audio/codec": "aac", "audio-params/channels": "stereo",
            "audio-params/samplerate": "48000", "file-size": "12345"], includesFileSize: false)
        XCTAssertTrue(info.hasSpecifications); XCTAssertNil(info.width); XCTAssertNil(info.fileSizeBytes)
        XCTAssertEqual(info.audioSampleRate, 48_000)
    }
}
