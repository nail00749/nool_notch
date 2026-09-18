import Foundation

struct UpcomingMeeting: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ongoing
        case startsIn
    }

    let event: CalendarEvent

    static func select(
        from events: [CalendarEvent],
        at date: Date = .now
    ) -> UpcomingMeeting? {
        let eligibleEvents = events.filter {
            $0.isAllDay == false && $0.endDate > date
        }

        if let ongoingEvent = eligibleEvents
            .filter({ $0.startDate <= date })
            .min(by: { $0.endDate < $1.endDate }) {
            return UpcomingMeeting(event: ongoingEvent)
        }

        guard let nextEvent = eligibleEvents.min(by: { $0.startDate < $1.startDate }) else {
            return nil
        }
        return UpcomingMeeting(event: nextEvent)
    }

    func state(at date: Date = .now) -> State {
        event.startDate <= date ? .ongoing : .startsIn
    }

    func countdownText(at date: Date = .now) -> String {
        let interval: TimeInterval
        let prefix: String

        switch state(at: date) {
        case .ongoing:
            interval = event.endDate.timeIntervalSince(date)
            prefix = "Закончится через"
        case .startsIn:
            interval = event.startDate.timeIntervalSince(date)
            prefix = "Начнётся через"
        }

        let roundedInterval = max(0, Int(interval.rounded(.down)))
        let hours = roundedInterval / 3_600
        let minutes = (roundedInterval % 3_600) / 60
        let seconds = roundedInterval % 60

        let duration: String
        if hours > 0 {
            duration = "\(hours) ч \(minutes) мин"
        } else if minutes > 0 {
            duration = "\(minutes) мин"
        } else {
            duration = "\(seconds) сек"
        }

        return "\(prefix) \(duration)"
    }
}
