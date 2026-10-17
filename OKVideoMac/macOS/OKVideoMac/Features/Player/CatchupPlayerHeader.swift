import SwiftUI

struct CatchupPlayerHeader: View {
    let title: String
    let channel: String
    let start: Date
    let returnToLive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 100, height: 1)
                .accessibilityHidden(true)
            PlayerTitleView(title: title, episode: [
                L10n.string("live.catchup.mode", fallback: "Catch-up"), channel,
                start.formatted(.dateTime.month().day().hour().minute())
            ].joined(separator: " · "))
            .frame(maxWidth: .infinity)
            .help(title + " · " + channel + " · " + start.formatted())
            Button(action: returnToLive) {
                Label(L10n.string("live.catchup.return-live", fallback: "Return to Live"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.18))
            .foregroundStyle(.white.opacity(0.88))
            .accessibilityIdentifier("player.catchup.return-live")
            .frame(width: 100)
        }
        .frame(height: 36)
    }
}
