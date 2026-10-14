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
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(L10n.string("live.catchup.mode", fallback: "Catch-up"))
                    Text("·")
                    Text(channel).lineLimit(1).truncationMode(.tail)
                    Text("·")
                    Text(start, format: .dateTime.month().day().hour().minute())
                        .monospacedDigit().fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
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
        .frame(height: 48)
    }
}
