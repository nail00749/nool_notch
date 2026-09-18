import Foundation

struct MeetingReminder: Equatable, Sendable {
    static let leadTime: TimeInterval = 5 * 60

    let event: CalendarEvent

    static func select(
        from events: [CalendarEvent],
        at date: Date = .now
    ) -> MeetingReminder? {
        events
            .filter { event in
                let secondsUntilStart = event.startDate.timeIntervalSince(date)
                return event.isAllDay == false
                    && event.endDate > date
                    && secondsUntilStart > 0
                    && secondsUntilStart <= leadTime
            }
            .min { lhs, rhs in
                lhs.startDate == rhs.startDate
                    ? lhs.id < rhs.id
                    : lhs.startDate < rhs.startDate
            }
            .map(MeetingReminder.init)
    }

    func countdownText(at date: Date = .now) -> String {
        let seconds = max(0, Int(ceil(event.startDate.timeIntervalSince(date))))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
