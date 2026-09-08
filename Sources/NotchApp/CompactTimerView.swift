import SwiftUI

struct CompactTimerView: View {
    let timer: NoolTimerSnapshot
    let physicalNotchSize: CGSize
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var isPaused: Bool { timer.state == .paused }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                Text(timer.countdownText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(.orange.opacity(isPaused ? 0.6 : 1))
                    .frame(width: NotchLayout.compactWingWidth, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Таймер \(timer.countdownText). Открыть таймер")
            if physicalNotchSize.width > 0, physicalNotchSize.height > 0 {
                PhysicalNotchSafeZone(size: physicalNotchSize)
                    .frame(width: physicalNotchSize.width)
            } else {
                Button(action: onOpen) {
                    Label(isPaused ? "На паузе" : "Таймер", systemImage: "timer")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onToggle) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: NotchLayout.compactWingWidth, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Продолжить таймер" : "Поставить таймер на паузу")
        }
    }
}
