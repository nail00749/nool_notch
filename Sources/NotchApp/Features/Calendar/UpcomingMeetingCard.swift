import SwiftUI

struct UpcomingMeetingCard: View {
    let events: [CalendarEvent]
    let onJoin: (URL) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let meeting = UpcomingMeeting.select(from: events, at: context.date) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: meeting.state(at: context.date) == .ongoing
                        ? "video.fill"
                        : "calendar.badge.clock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.signalMint)
                        .frame(width: 28, height: 28)
                        .background(Color.signalMint.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.event.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(meeting.countdownText(at: context.date))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.54))
                            .monospacedDigit()
                    }

                    Spacer(minLength: 4)

                    if let joinURL = meeting.event.joinURL {
                        Button {
                            onJoin(joinURL)
                        } label: {
                            Text("Войти")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.black.opacity(0.78))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 28)
                                .background(Color.signalMint, in: Capsule())
                        }
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel("Подключиться к встрече \(meeting.event.title)")
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.07))
                )
                .accessibilityElement(children: .combine)
            }
        }
    }
}
