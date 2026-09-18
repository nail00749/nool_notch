import SwiftUI

struct LauncherMeetingDetail: View {
    let event: CalendarEvent
    let back: () -> Void
    let join: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: back) { Label("К результатам", systemImage: "arrow.left") }
                    .buttonStyle(.plain).foregroundStyle(NotchPalette.accent).frame(minHeight: 40)
                Label(event.calendarTitle, systemImage: "calendar").font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                Text(event.title).font(.system(size: 22, weight: .medium)).textSelection(.enabled)
                Text(event.startDate, format: .dateTime.day().month(.wide).year()).font(.system(size: 14))
                if event.isAllDay {
                    Text("Весь день").foregroundStyle(NotchPalette.secondary)
                } else {
                    Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(NotchPalette.secondary)
                }
                if event.joinURL?.scheme?.lowercased() == "https" {
                    Button("Подключиться к встрече", action: join).buttonStyle(.borderedProminent).tint(NotchPalette.accent)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
    }
}
