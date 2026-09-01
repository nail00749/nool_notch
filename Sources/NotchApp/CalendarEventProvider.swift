import AppKit
import EventKit
import Foundation

struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
}

struct CalendarSnapshot: Equatable, Sendable {
    let upcomingEvents: [CalendarEvent]
    let monthEvents: [CalendarEvent]
}

struct CalendarMonthKey: Hashable, Sendable {
    let year: Int
    let month: Int

    init(date: Date) {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
    }

    var startDate: Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: 1)
        ) ?? .now
    }

    var endDate: Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: startDate) ?? startDate
    }
}

enum CalendarLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CalendarSnapshot)
    case denied
}

@MainActor
private final class CalendarAccessRequest {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didResolve = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ granted: Bool) {
        guard didResolve == false else { return }
        didResolve = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: granted)
    }
}

@MainActor
final class CalendarEventProvider: CalendarProviding {
    private let store = EKEventStore()

    func loadUpcomingEvents() async -> CalendarLoadState {
        guard await hasFullAccess() else {
            return .denied
        }

        let startDate = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: 14, to: startDate) else {
            return .loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: []))
        }

        let month = CalendarMonthKey(date: startDate)
        let upcomingEvents = events(from: startDate, to: endDate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)

        return .loaded(
            CalendarSnapshot(
                upcomingEvents: Array(upcomingEvents),
                monthEvents: events(from: month.startDate, to: month.endDate)
            )
        )
    }

    func loadEvents(for month: Date) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }

        let monthKey = CalendarMonthKey(date: month)
        return events(from: monthKey.startDate, to: monthKey.endDate)
    }

    private func events(from startDate: Date, to endDate: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let title = event.title?.isEmpty == false ? event.title! : "Без названия"
                let eventID = event.eventIdentifier ?? title
                let uniqueID = "\(eventID)-\(event.startDate.timeIntervalSinceReferenceDate)"
                return CalendarEvent(
                    id: uniqueID,
                    title: title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title
                )
            }
    }

    private func hasFullAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return await requestFullAccess()
        default:
            return false
        }
    }

    private func requestFullAccess() async -> Bool {
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
            let request = CalendarAccessRequest(continuation: continuation)
            store.requestFullAccessToEvents { granted, _ in
                Task { @MainActor in
                    request.resolve(granted)
                    if previousPolicy == .accessory {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                request.resolve(false)

                if previousPolicy == .accessory {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
