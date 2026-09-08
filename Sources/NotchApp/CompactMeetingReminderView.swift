import SwiftUI

struct CompactMeetingReminderView: View {
    let reminder: MeetingReminder
    let physicalNotchSize: CGSize
    let onOpenCalendar: () -> Void
    let onJoin: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenCalendar) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(reminder.countdownText(at: context.date))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.signalMint)
                        .frame(width: NotchLayout.compactWingWidth, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .help(reminder.event.title)
            .accessibilityLabel("Скоро встреча: \(reminder.event.title). Открыть календарь")

            if physicalNotchSize.width > 0, physicalNotchSize.height > 0 {
                PhysicalNotchSafeZone(size: physicalNotchSize)
                    .frame(width: physicalNotchSize.width)
            } else {
                Button(action: onOpenCalendar) {
                    Text(reminder.event.title)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                if let url = reminder.event.joinURL { onJoin(url) }
                else { onOpenCalendar() }
            } label: {
                Group {
                    if reminder.event.joinURL != nil {
                        Text("Войти")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    } else {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.signalMint)
                .frame(width: NotchLayout.compactWingWidth, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.event.joinURL != nil
                ? "Подключиться к встрече \(reminder.event.title)"
                : "Открыть событие \(reminder.event.title) в календаре")
        }
    }
}
