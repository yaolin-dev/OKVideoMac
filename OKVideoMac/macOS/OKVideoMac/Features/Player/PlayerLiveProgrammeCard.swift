import Foundation
import OKVideoCore
import SwiftUI

/// The player owns visibility and its single auto-hide timer. The summary has
/// no expanded mode or actions; hovering holds the shared control layer.
@MainActor final class PlayerLiveInfoInteraction: ObservableObject {
    @Published private var hovering = false
    var holdsControlsVisible: Bool { hovering }
    func hover(_ value: Bool) { if hovering != value { hovering = value } }
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
    @ObservedObject var interaction: PlayerLiveInfoInteraction
    let channel: LiveChannel
    let source: LiveSourceID
    let compact: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.epg === rhs.epg && lhs.interaction === rhs.interaction
            && lhs.channel == rhs.channel && lhs.source == rhs.source && lhs.compact == rhs.compact
    }

    var body: some View {
        // Only cached EPG data: no network request or native media-property read.
        let initial = epg.nowNext(channel: channel, source: source, at: Date())
        let intervals = [initial.current, initial.next].compactMap { $0 }.filter { $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
        TimelineView(PlayerLiveInfoTimelineSchedule(intervals: intervals)) { context in
            let info = epg.nowNext(channel: channel, source: source, at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(channel.name).lineLimit(1).layoutPriority(1)
                    if !compact { Text(L10n.string("player.live-info.channel", fallback: "Live channel")).foregroundColor(.white.opacity(0.50)) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                programmeTitle(info)
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
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.13, green: 0.145, blue: 0.165).opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.055), lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onHover { interaction.hover($0) }
        .onDisappear { interaction.hover(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.live.programme-card")
        .playerPresentationProbe("live-programme-summary")
    }

    private func validCurrent(_ info: EPGNowNextSnapshot, at date: Date) -> EPGProgramme? {
        guard let current = info.current, current.start <= date, current.end > date,
              current.end > current.start else { return nil }
        return current
    }
    static func isContiguous(current: EPGProgramme, next: EPGProgramme) -> Bool {
        abs(next.start.timeIntervalSince(current.end)) < 1
    }
    @ViewBuilder private func programmeTitle(_ info: EPGNowNextSnapshot) -> some View {
        if let title = info.current?.title {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.string("player.live-info.current", fallback: "Now"))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.50))
                    .fixedSize(horizontal: true, vertical: false)
                Text(title)
                    .font(.system(size: 16, weight: .medium)).foregroundColor(.white.opacity(0.96))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(L10n.string("player.live-info.empty", fallback: "No programme information"))
                .font(.system(size: 16)).foregroundColor(.white.opacity(0.65))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
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
}
