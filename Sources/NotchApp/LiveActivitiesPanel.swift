import SwiftUI

struct LiveActivitiesPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NoolTimerPanel(source: model.timerSource,
                    onCompact: { model.isExpanded = false })
                LazyVStack(spacing: 8) {
                    ForEach(model.liveActivities.filter { $0.sourceID != model.timerSource.id }) { activity in
                        LiveActivityRow(activity: activity)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 18)
        .padding(.top, 2)
    }
}

private struct LiveActivityRow: View {
    let activity: LiveActivity
    private var accentColor: Color {
        switch activity.kind {
        case .call: .signalCoral
        case .timer: .signalMint
        case .download: .signalCyan
        case .delivery: .signalAmber
        case .headphones: .signalCyan
        case .battery:
            (activity.progress ?? 1) <= 0.2 ? .signalCoral : .signalMint
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.kind.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 34, height: 34)
                .background(accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let detail = activity.detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(accentColor)
                            .contentTransition(.numericText())
                    }
                }

                if let progress = activity.progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                        .scaleEffect(y: 0.65)
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.10), lineWidth: 0.5)
        }
    }

}
