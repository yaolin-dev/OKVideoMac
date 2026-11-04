import AppKit
import Foundation
import OKVideoCore
import SwiftUI

/// One card, with a lifetime independent of transport controls. Monotonic time
/// keeps hovering/focus from consuming the remaining summary display time.
struct PlayerLiveInfoVisibility: Equatable {
    enum Mode { case hidden, summary, details }
    var mode: Mode = .hidden
    private(set) var remaining: TimeInterval = 4
    private(set) var deadline: TimeInterval?
    mutating func show(now: TimeInterval) { mode = .summary; remaining = 4; deadline = now + 4 }
    mutating func expand() { mode = .details; deadline = nil }
    mutating func close() { mode = .hidden; deadline = nil }
    mutating func hold(_ held: Bool, now: TimeInterval) {
        guard mode == .summary else { return }
        if held, let deadline { remaining = max(0, deadline - now); self.deadline = nil }
        else if !held, deadline == nil { deadline = now + remaining }
    }
    mutating func expire(now: TimeInterval) {
        if mode == .summary, let deadline, now >= deadline { close() }
    }
}

@MainActor final class PlayerLiveInfoPresentation: ObservableObject {
    @Published private(set) var visibility = PlayerLiveInfoVisibility()
    private var timer: Task<Void, Never>?
    private var hovering = false
    private var focused = false
    var visible: Bool { visibility.mode != .hidden }
    var expanded: Bool { visibility.mode == .details }
    var isInteracting: Bool { hovering || focused }
    func show() {
        visibility.show(now: ProcessInfo.processInfo.systemUptime)
        visibility.hold(hovering || focused, now: ProcessInfo.processInfo.systemUptime)
        schedule()
    }
    func expand() { timer?.cancel(); visibility.expand() }
    func close() { timer?.cancel(); hovering = false; focused = false; visibility.close() }
    func hover(_ value: Bool) { hovering = value; interactionChanged() }
    func focus(_ value: Bool) { focused = value; interactionChanged() }
    private func interactionChanged() {
        visibility.hold(hovering || focused, now: ProcessInfo.processInfo.systemUptime)
        schedule()
    }
    private func schedule() {
        timer?.cancel()
        guard let deadline = visibility.deadline else { return }
        let duration = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.visibility.expire(now: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// A local presentation clock, never an EPG request or player-property poll.
/// No guide means a single render; active programmes advance at most once a
/// minute, with exact programme boundaries inserted between those ticks.
struct PlayerLiveInfoTimelineSchedule: TimelineSchedule {
    let intervals: [DateInterval]
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence {
            var next: Date? = startDate
            return AnyIterator<Date> {
                guard let value = next else { return nil }
                let boundary = intervals.flatMap { [$0.start, $0.end] }.filter { $0 > value }.min()
                let minute = intervals.contains { $0.start <= value && value < $0.end }
                    ? value.addingTimeInterval(60) : nil
                next = [boundary, minute].compactMap { $0 }.min()
                return value
            }
        }
    }
}

struct PlayerLiveProgrammeCard: View, Equatable {
    @ObservedObject var epg: LiveEPGState
    @ObservedObject var presentation: PlayerLiveInfoPresentation
    let channel: LiveChannel
    let source: LiveSourceID
    let stream: LiveStream?
    let mediaInfo: PlaybackMediaInfo?
    let compact: Bool
    let maximumHeight: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.epg === rhs.epg && lhs.presentation === rhs.presentation
            && lhs.channel == rhs.channel && lhs.source == rhs.source && lhs.stream == rhs.stream
            && lhs.mediaInfo == rhs.mediaInfo && lhs.compact == rhs.compact && lhs.maximumHeight == rhs.maximumHeight
    }

    var body: some View {
        // nowNext is an O(1) in-memory lookup. This view never asks the EPG
        // repository, network or native player to refresh information.
        let initial = epg.nowNext(channel: channel, source: source, at: Date())
        let intervals = [initial.current, initial.next].compactMap { $0 }.filter { $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
        TimelineView(PlayerLiveInfoTimelineSchedule(intervals: intervals)) { context in
            let info = epg.nowNext(channel: channel, source: source, at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if presentation.expanded {
                        cardAction("player.live-info.back", fallback: "Back to summary", identifier: "player.live.info.back") { presentation.show() }
                        Spacer(minLength: 4)
                        cardAction("player.live-info.close", fallback: "Hide", identifier: "player.live.info.close") { presentation.close() }
                    } else {
                        Text(channel.name).lineLimit(1).layoutPriority(1)
                        if !compact { Text(L10n.string("player.live-info.channel", fallback: "Live channel")).foregroundColor(.white.opacity(0.50)) }
                        Spacer(minLength: 4)
                        cardAction("player.live-info.details", fallback: "Details", identifier: "player.live.info.details") { presentation.expand() }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .buttonStyle(.plain)

                if presentation.expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            programmeTitle(info, expanded: true)
                            if let current = validCurrent(info, at: context.date) { timeRow(current, at: context.date) }
                            Divider().overlay(Color.white.opacity(0.08))
                            detailRow(L10n.string("player.live-info.channel-name", fallback: "Channel"), channel.name)
                            if let mediaInfo {
                                if let w = mediaInfo.width, let h = mediaInfo.height {
                                    detailRow(L10n.string("player.live-info.video", fallback: "Video"), "\(w) × \(h)" + (mediaInfo.nominalFrameRate.map { String(format: " · %.0f FPS", $0) } ?? ""))
                                }
                                if let codec = mediaInfo.videoCodec { detailRow(L10n.string("player.live-info.codec", fallback: "Codec"), codec) }
                                if let channels = mediaInfo.audioChannels { detailRow(L10n.string("player.live-info.audio", fallback: "Audio"), channels) }
                            }
                            if let stream {
                                let index = channel.streams.firstIndex { $0.id == stream.id }.map { $0 + 1 }
                                detailRow(L10n.string("player.live-info.route", fallback: "Playback route"), stream.name + (index.map { " · \($0)/\(channel.streams.count)" } ?? ""))
                            }
                            if let next = info.next { detailRow(L10n.string("player.live-info.next", fallback: "Up next"), next.title) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: max(70, maximumHeight - 68))
                } else {
                    programmeTitle(info, expanded: false)
                    if let current = validCurrent(info, at: context.date) {
                        timeRow(current, at: context.date)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.12))
                                Rectangle().fill(.white.opacity(0.82))
                                    .frame(width: geometry.size.width * (info.progress(at: context.date) ?? 0))
                            }
                        }
                        .frame(height: 2)
                        .accessibilityLabel(L10n.string("player.live-info.progress", fallback: "Programme schedule progress"))
                        .accessibilityValue("\(Int((info.progress(at: context.date) ?? 0) * 100))%")
                    }
                    if !compact, let next = info.next, validCurrent(info, at: context.date) != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.string("player.live-info.next", fallback: "Up next")).foregroundColor(.white.opacity(0.5))
                            if let current = info.current, !Self.isContiguous(current: current, next: next) {
                                Text(next.start, style: .time)
                            }
                            Text(next.title).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.68))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.13, green: 0.145, blue: 0.165).opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.055), lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onHover { presentation.hover($0) }
        .onDisappear { presentation.hover(false); presentation.focus(false) }
        .onExitCommand { presentation.close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.live.programme-card")
    }

    private func cardAction(_ key: String, fallback: String, identifier: String, action: @escaping () -> Void) -> some View {
        PlayerLiveInfoAction(title: L10n.string(key, fallback: fallback), identifier: identifier,
                             onFocus: { presentation.focus($0) }, action: action)
            .fixedSize()
    }
    private func validCurrent(_ info: EPGNowNextSnapshot, at date: Date) -> EPGProgramme? {
        guard let current = info.current, current.start <= date, current.end > date,
              current.end > current.start else { return nil }
        return current
    }
    static func isContiguous(current: EPGProgramme, next: EPGProgramme) -> Bool {
        abs(next.start.timeIntervalSince(current.end)) < 1
    }
    private func programmeTitle(_ info: EPGNowNextSnapshot, expanded: Bool) -> some View {
        Text(info.current?.title ?? L10n.string("player.live-info.empty", fallback: "No programme information"))
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.white.opacity(info.current == nil ? 0.65 : 0.96))
            .lineLimit(expanded ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func timeRow(_ current: EPGProgramme, at date: Date) -> some View {
        HStack(spacing: 4) {
            Text(current.start, style: .time)
            Text("—")
            Text(current.end, style: .time)
            Spacer(minLength: 4)
            if !compact { Text(L10n.string("player.live-info.remaining", fallback: "%d min remaining", max(1, Int(ceil(current.end.timeIntervalSince(date) / 60))))) }
        }
        .font(.system(size: 12)).monospacedDigit().foregroundColor(.white.opacity(0.65))
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundColor(.white.opacity(0.50)).fixedSize()
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).foregroundColor(.white.opacity(0.78))
        }.font(.system(size: 12))
    }
}

/// Native controls accept the first click when the player window is inactive.
/// Keep this local to the information card so transport hit testing is unchanged.
private struct PlayerLiveInfoAction: NSViewRepresentable {
    let title: String
    let identifier: String
    let onFocus: (Bool) -> Void
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> LiveInfoActionButton {
        let button = LiveInfoActionButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.focusRingType = .default
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: LiveInfoActionButton, context: Context) {
        context.coordinator.action = action
        button.onFocus = onFocus
        button.title = title
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ])
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
private final class LiveInfoActionButton: NSButton {
    var onFocus: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus(false) }
        return accepted
    }
}
