import AppKit
import EventKit
import Foundation
import Combine

struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let joinURL: URL?

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarTitle: String,
        joinURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.joinURL = joinURL
    }
}

enum CalendarConferenceLinkResolver {
    private static let supportedDomains: Set<String> = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "teams.cloud.microsoft",
        "webex.com",
        "gotomeet.me",
        "whereby.com",
        "meet.jit.si"
    ]

    static func joinURL(
        eventURL: URL?,
        location: String?,
        notes: String?
    ) -> URL? {
        let candidates = [eventURL].compactMap { $0 }
            + urls(in: location)
            + urls(in: notes)

        return candidates.first(where: isSupportedConferenceURL)
    }

    private static func urls(in text: String?) -> [URL] {
        guard let text, text.isEmpty == false,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
              ) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    private static func isSupportedConferenceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        return supportedDomains.contains(host)
            || supportedDomains.contains { host.hasSuffix(".\($0)") }
    }
}

struct CalendarSnapshot: Equatable, Sendable {
    let upcomingEvents: [CalendarEvent]
    let monthEvents: [CalendarEvent]
    let sidebarUpcomingEvents: [CalendarEvent]

    init(upcomingEvents: [CalendarEvent], monthEvents: [CalendarEvent],
         sidebarUpcomingEvents: [CalendarEvent]? = nil) {
        self.upcomingEvents = upcomingEvents
        self.monthEvents = monthEvents
        self.sidebarUpcomingEvents = sidebarUpcomingEvents ?? upcomingEvents
    }
}

/// The long sidebar horizon is fetched once, then projected into the existing reminder/month
/// windows. Event-store edits invalidate it immediately; the short TTL also catches clock changes.
@MainActor
final class CalendarUpcomingEventCache {
    static let lifetime: TimeInterval = 5 * 60
    private struct Entry {
        let fetchedAt: Date
        let monthStart: Date
        let events: [CalendarEvent]
    }
    private var entry: Entry?
    private var pending: (id: UUID, monthStart: Date, task: Task<[CalendarEvent], Never>)?
    private var revision = UUID()

    func invalidate() {
        revision = UUID()
        entry = nil
        pending?.task.cancel()
        pending = nil
    }

    func snapshot(at now: Date, calendar: Calendar = .current,
                  fetch: @escaping @Sendable (Date, Date, Date) async -> [CalendarEvent]) async -> CalendarSnapshot {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let yearEnd = calendar.date(byAdding: .year, value: 1, to: now),
              let nearEnd = calendar.date(byAdding: .day, value: 14, to: now) else {
            return CalendarSnapshot(upcomingEvents: [], monthEvents: [])
        }
        if let entry, entry.monthStart == month.start,
           now >= entry.fetchedAt, now.timeIntervalSince(entry.fetchedAt) < Self.lifetime {
            return Self.project(entry.events, now: now, nearEnd: nearEnd, yearEnd: yearEnd, month: month)
        }
        let requestRevision = revision
        let request: (id: UUID, monthStart: Date, task: Task<[CalendarEvent], Never>)
        if let pending, pending.monthStart == month.start {
            request = pending
        } else {
            let id = UUID()
            // The buffer preserves conference links for events entering the 14-day window
            // during the cache lifetime, without parsing notes for a whole year's events.
            let detailsThrough = max(month.end, nearEnd.addingTimeInterval(Self.lifetime))
            request = (id, month.start, Task { await fetch(month.start, yearEnd, detailsThrough) })
            pending = request
        }
        let events = await request.task.value
        guard !Task.isCancelled else { return CalendarSnapshot(upcomingEvents: [], monthEvents: []) }
        guard revision == requestRevision else {
            return await snapshot(at: now, calendar: calendar, fetch: fetch)
        }
        if pending?.id == request.id {
            entry = Entry(fetchedAt: now, monthStart: month.start, events: events)
            pending = nil
        }
        return Self.project(events, now: now, nearEnd: nearEnd, yearEnd: yearEnd, month: month)
    }

    private static func project(_ events: [CalendarEvent], now: Date, nearEnd: Date,
                                yearEnd: Date, month: DateInterval) -> CalendarSnapshot {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        let future = sorted.filter { $0.endDate > now && $0.startDate < yearEnd }
        return CalendarSnapshot(upcomingEvents: future.filter { $0.startDate < nearEnd },
                                monthEvents: sorted.filter { $0.endDate > month.start && $0.startDate < month.end },
                                sidebarUpcomingEvents: future)
    }
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

/// EKEventStore queries are documented as safe off the main thread; only value types leave the queue.
private struct CalendarStoreBox: @unchecked Sendable {
    let store: EKEventStore
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
    private let fetchQueue = DispatchQueue(label: "nool.calendar.fetch", qos: .userInitiated)
    private let upcomingCache = CalendarUpcomingEventCache()
    private var storeChanges: AnyCancellable?

    init() {
        storeChanges = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .sink { [weak cache = upcomingCache] _ in
                Task { @MainActor in cache?.invalidate() }
            }
    }

    var canLoadWithoutPrompt: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func loadUpcomingEvents() async -> CalendarLoadState {
        guard await hasFullAccess() else {
            upcomingCache.invalidate()
            return .denied
        }

        let store = CalendarStoreBox(store: store)
        let queue = fetchQueue
        let snapshot = await upcomingCache.snapshot(at: Date()) { start, end, detailsThrough in
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.fetchEvents(in: store.store, from: start, to: end,
                                                                   conferenceDetailsThrough: detailsThrough))
                }
            }
        }
        return .loaded(snapshot)
    }

    func loadEvents(for month: Date) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }

        let monthKey = CalendarMonthKey(date: month)
        return await events(from: monthKey.startDate, to: monthKey.endDate)
    }

    /// `events(matching:)` is synchronous and can take hundreds of milliseconds with Exchange or
    /// subscribed calendars, so the query and link parsing run on a serial background queue.
    private func events(from startDate: Date, to endDate: Date) async -> [CalendarEvent] {
        let store = CalendarStoreBox(store: store)
        return await withCheckedContinuation { continuation in
            fetchQueue.async {
                continuation.resume(returning: Self.fetchEvents(in: store.store, from: startDate, to: endDate))
            }
        }
    }

    nonisolated private static func fetchEvents(in store: EKEventStore, from startDate: Date, to endDate: Date,
                                                conferenceDetailsThrough: Date = .distantFuture) -> [CalendarEvent] {
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
                    calendarTitle: event.calendar.title,
                    joinURL: CalendarConferenceLinkResolver.joinURL(
                        eventURL: event.url,
                        location: event.startDate < conferenceDetailsThrough ? event.location : nil,
                        notes: event.startDate < conferenceDetailsThrough ? event.notes : nil
                    )
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
