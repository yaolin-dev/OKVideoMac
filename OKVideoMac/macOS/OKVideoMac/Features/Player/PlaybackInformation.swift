import AppKit
import Foundation
import OKVideoCore
import SwiftUI

struct PlaybackInfoRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String?
}

enum PlaybackInfoPresentation {
    private static func row(_ id: String, _ fallback: String, _ value: String?) -> PlaybackInfoRow {
        PlaybackInfoRow(id: id, label: L10n.string("player.info." + id, fallback: fallback), value: value)
    }
    static func codec(_ value: String?) -> String? {
        guard let value else { return nil }
        return ["h264": "H.264 / AVC", "hevc": "H.265 / HEVC", "av1": "AV1", "vp9": "VP9",
            "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "flac": "FLAC",
            "opus": "Opus", "pcm_s16le": "PCM 16-bit"][value] ?? value.uppercased()
    }
    static func frameRate(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        let number = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return number + " fps"
    }
    static func bitrate(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return String(format: value >= 1_000_000 ? "%.2f Mb/s" : "%.0f kb/s",
            locale: Locale(identifier: "en_US_POSIX"), value / (value >= 1_000_000 ? 1_000_000 : 1000))
    }
    static func resolution(_ info: PlaybackMediaInfo?) -> String? {
        guard let width = info?.width, let height = info?.height else { return nil }
        return "\(width) × \(height)"
    }
    static func summary(_ info: PlaybackMediaInfo?) -> String? {
        guard let info, info.hasSpecifications else { return nil }
        return [resolution(info), codec(info.videoCodec), frameRate(info.nominalFrameRate), codec(info.audioCodec), info.audioChannels]
            .compactMap { $0 }.joined(separator: " · ")
    }
    static func fileRows(_ info: PlaybackMediaInfo?, originalName: String?, duration: TimeInterval) -> [PlaybackInfoRow] {
        let time: String?
        if duration.isFinite, duration > 0, duration < Double(Int.max) {
            let seconds = Int(duration)
            time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60)
                : String(format: "%d:%02d", seconds/60, seconds%60)
        } else { time = nil }
        var rows = [row("filename", "Original Filename", info?.fileName ?? PlaybackMediaInfo.safeFileName(originalName)),
            row("container", "Container", info?.container?.uppercased()), row("duration", "Duration", time)]
        if let size = info?.fileSizeBytes {
            rows.append(row("file-size", "File Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        return rows
    }
    static func videoRows(_ info: PlaybackMediaInfo?) -> [PlaybackInfoRow] {
        if let info, info.videoCodec == nil, info.width == nil, info.audioCodec != nil { return [] }
        return [row("resolution", "Source Resolution", resolution(info)), row("video-codec", "Video Codec", codec(info?.videoCodec)),
            row("frame-rate", "Frame Rate (Media Metadata)", frameRate(info?.nominalFrameRate)),
            row("video-bitrate", "Video Bitrate (Estimated)", bitrate(info?.statistics?.videoBitrate))]
    }
    static func audioRows(_ info: PlaybackMediaInfo?, selectedTrack: MediaTrack?) -> [PlaybackInfoRow] {
        var rows = [row("audio-codec", "Audio Codec", codec(info?.audioCodec)),
            row("audio-channels", "Channels", info?.audioChannels),
            row("sample-rate", "Sample Rate", info?.audioSampleRate.map { String(format: "%.1f kHz", Double($0)/1000) }),
            row("audio-bitrate", "Audio Bitrate (Estimated)", bitrate(info?.statistics?.audioBitrate))]
        if let selectedTrack { rows.insert(row("audio-track", "Selected Audio Track", "#\(selectedTrack.id)"), at: 0) }
        return rows
    }
    static func statisticRows(_ info: PlaybackMediaInfo?) -> [PlaybackInfoRow] {
        let statistics = info?.statistics
        let decoder = statistics?.hardwareDecoder.map { $0 == "no" || $0 == "none"
            ? L10n.string("player.info.software-decoding", fallback: "Software Decoding")
            : L10n.string("player.info.hardware-decoding", fallback: "Hardware Decoding") + " · " + $0 }
        return [row("decoder", "Decoder", decoder),
            row("output-frame-rate", "Output Frame Rate (Estimated)", frameRate(statistics?.measuredFrameRate)),
            row("download-speed", "Download Speed", statistics?.networkBytesPerSecond.map { String(format: "%.2f MB/s", Double($0)/1_000_000) }),
            row("cache-duration", "Buffered Duration", statistics?.cacheDuration.map { L10n.string("player.seconds", fallback: "%.1f sec", $0) }),
            row("dropped-frames", "Dropped Frames", statistics?.droppedFrames.map { String($0) })]
    }
    static func copyText(info: PlaybackMediaInfo?, originalName: String?, duration: TimeInterval, selectedTrack: MediaTrack?) -> String {
        let rows = fileRows(info, originalName: originalName, duration: duration) + videoRows(info)
            + audioRows(info, selectedTrack: selectedTrack) + statisticRows(info)
        return rows.compactMap { row in row.value.map { row.label + ": " + $0 } }.joined(separator: "\n")
    }
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
}

struct PlaybackInformationPanel: View {
    let info: PlaybackMediaInfo?
    let originalName: String?
    let duration: TimeInterval
    let selectedAudioTrack: MediaTrack?
    @State private var showsStatistics = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.string("player.info.title", fallback: "Playback Information"), systemImage: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    PlaybackInfoPresentation.copy(PlaybackInfoPresentation.copyText(info: info, originalName: originalName,
                        duration: duration, selectedTrack: selectedAudioTrack))
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(info == nil)
                .help(L10n.string("player.info.copy", fallback: "Copy Playback Information"))
                .accessibilityLabel(L10n.string("player.info.copy", fallback: "Copy Playback Information"))
                .accessibilityIdentifier("player.info.copy")
            }
            rows(PlaybackInfoPresentation.fileRows(info, originalName: originalName, duration: duration))
            let video = PlaybackInfoPresentation.videoRows(info)
            if !video.isEmpty { Divider(); rows(video) }
            Divider()
            rows(PlaybackInfoPresentation.audioRows(info, selectedTrack: selectedAudioTrack))
            DisclosureGroup(isExpanded: $showsStatistics) {
                rows(PlaybackInfoPresentation.statisticRows(info)).padding(.top, 8)
            } label: {
                Text(L10n.string("player.info.statistics", fallback: "Playback Statistics"))
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(L10n.string("player.info.note", fallback: "Audio parameters use decoder data when available, otherwise selected-track metadata. Bitrate and output frame rate are estimates. Missing values are not supplied by this stream."))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.white.opacity(0.94))
        .accessibilityIdentifier("player.info.panel")
        .onChange(of: info?.fileName) { _ in didCopy = false }
    }
    private func rows(_ values: [PlaybackInfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(values) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.label).foregroundColor(.white.opacity(0.60)).frame(width: 142, alignment: .leading)
                    Text(row.value ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Session-only observations, keyed by the exact source/resource. No technical
/// specs are inferred from titles or persisted alongside expiring playback URLs.
@MainActor final class PlaybackMediaInfoCache: ObservableObject {
    struct Key: Hashable {
        let configurationID: UUID
        let configurationUpdatedAt: Date
        let videoID: String
        let sourceID: String
        let episodeID: String
    }
    @Published private var records: [Key: PlaybackMediaInfo] = [:]
    private var order: [Key] = []
    func store(_ info: PlaybackMediaInfo, for key: Key) {
        guard info.hasSpecifications else { return }
        let value = info.withoutStatistics
        guard records[key] != value else { return }
        if records[key] == nil { order.append(key) }
        records[key] = value
        while order.count > 100 { records.removeValue(forKey: order.removeFirst()) }
    }
    func info(for key: Key) -> PlaybackMediaInfo? { records[key] }
}

struct DetailPlaybackSpecifications: View {
    @ObservedObject var cache: PlaybackMediaInfoCache
    let key: PlaybackMediaInfoCache.Key?
    let episodeName: String
    var body: some View {
        if let key, let summary = PlaybackInfoPresentation.summary(cache.info(for: key)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.caption.weight(.medium))
                Text(L10n.string("player.info.last-played", fallback: "Last played specifications · %@", episodeName))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("detail.playback-specifications")
        }
    }
}
