import SwiftUI

/// Keeps both wings outside the physical camera cutout, like the native timer.
struct CompactLiveActivityView: View {
    let activity: LiveActivity
    let physicalNotchSize: CGSize
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                Image(systemName: activity.kind.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: NotchLayout.compactWingWidth)
                if physicalNotchSize.width > 0, physicalNotchSize.height > 0 {
                    PhysicalNotchSafeZone(size: physicalNotchSize)
                        .frame(width: physicalNotchSize.width)
                } else {
                    Text(activity.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(at: context.date))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: NotchLayout.compactWingWidth)
                }
            }
            .foregroundStyle(Color.signalMint)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.title). \(activity.detail ?? ""). Открыть Live")
    }

    private func detail(at date: Date) -> String {
        if let remaining = activity.remainingDuration(at: date) {
            return LiveActivityClock.elapsedText(from: date, to: date.addingTimeInterval(remaining))
        }
        if let progress = activity.progress, progress.isFinite {
            return "\(Int(min(1, max(0, progress)) * 100))%"
        }
        return activity.detail ?? (activity.state == .paused ? "Пауза" : "Live")
    }
}
