import Foundation
import XCTest
@testable import NotchApp

final class CalendarEventProviderTests: XCTestCase {
    func testSnapshotSidebarDefaultPreservesExistingInitializersAndExplicitEmptyList() {
        let event = event("near", start: date(), duration: 600)
        XCTAssertEqual(CalendarSnapshot(upcomingEvents: [event], monthEvents: []).sidebarUpcomingEvents, [event])
        XCTAssertTrue(CalendarSnapshot(upcomingEvents: [event], monthEvents: [], sidebarUpcomingEvents: [])
            .sidebarUpcomingEvents.isEmpty)
    }

    @MainActor
    func testOneYearQueryRetainsFourteenDayReminderAndCurrentMonthSemantics() async {
        let now = date()
        let calendar = calendar()
        let day: TimeInterval = 86_400
        let past = event("past", start: now.addingTimeInterval(-day), duration: 60)
        let ongoing = event("ongoing", start: now.addingTimeInterval(-600), duration: 1_200)
        let near = event("near", start: now.addingTimeInterval(day), duration: 600)
        let boundary = event("boundary", start: now.addingTimeInterval(14 * day), duration: 600)
        let later = event("later month", start: now.addingTimeInterval(50 * day), duration: 600)
        let afterYear = event("after year", start: now.addingTimeInterval(370 * day), duration: 600)
        let query = CalendarQueryProbe(responses: [[later, near, past, boundary, ongoing, afterYear]])
        let cache = CalendarUpcomingEventCache()
        let snapshot = await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch)
        XCTAssertEqual(snapshot.upcomingEvents.map(\.id), ["ongoing", "near"])
        XCTAssertEqual(snapshot.monthEvents.map(\.id), ["past", "ongoing", "near"])
        XCTAssertEqual(snapshot.sidebarUpcomingEvents.map(\.id), ["ongoing", "near", "boundary", "later month"])
        let requests = await query.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].start, calendar.dateInterval(of: .month, for: now)?.start)
        XCTAssertEqual(requests[0].end, calendar.date(byAdding: .year, value: 1, to: now))
        XCTAssertLessThan(requests[0].detailsThrough, now.addingTimeInterval(32 * day))
    }

    @MainActor
    func testMinuteRefreshReusesYearQueryAndFiltersEventsThatAlreadyEnded() async {
        let now = date()
        let endingSoon = event("ending", start: now.addingTimeInterval(-30), duration: 60)
        let future = event("future", start: now.addingTimeInterval(80 * 86_400), duration: 600)
        let query = CalendarQueryProbe(responses: [[endingSoon, future]])
        let cache = CalendarUpcomingEventCache()
        _ = await cache.snapshot(at: now, calendar: calendar(), fetch: query.fetch)
        let snapshot = await cache.snapshot(at: now.addingTimeInterval(61), calendar: calendar(), fetch: query.fetch)
        XCTAssertTrue(snapshot.upcomingEvents.isEmpty)
        XCTAssertEqual(snapshot.sidebarUpcomingEvents.map(\.id), ["future"])
        let count = await query.requests.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testExpiryAndExplicitStoreInvalidationRefetch() async {
        let now = date()
        let query = CalendarQueryProbe(responses: [[], [], []])
        let cache = CalendarUpcomingEventCache()
        _ = await cache.snapshot(at: now, calendar: calendar(), fetch: query.fetch)
        _ = await cache.snapshot(at: now.addingTimeInterval(CalendarUpcomingEventCache.lifetime),
                                 calendar: calendar(), fetch: query.fetch)
        cache.invalidate()
        _ = await cache.snapshot(at: now.addingTimeInterval(CalendarUpcomingEventCache.lifetime + 1),
                                 calendar: calendar(), fetch: query.fetch)
        let count = await query.requests.count
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testMonthTimezoneAndBackwardClockChangesInvalidateRange() async {
        let query = CalendarQueryProbe(responses: [[], [], [], []])
        let cache = CalendarUpcomingEventCache()
        let january = date(month: 1, day: 31)
        let february = date(month: 2, day: 1)
        _ = await cache.snapshot(at: january, calendar: calendar(), fetch: query.fetch)
        _ = await cache.snapshot(at: february, calendar: calendar(), fetch: query.fetch)
        var shiftedCalendar = calendar()
        shiftedCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        _ = await cache.snapshot(at: february, calendar: shiftedCalendar, fetch: query.fetch)
        _ = await cache.snapshot(at: february.addingTimeInterval(-60), calendar: shiftedCalendar, fetch: query.fetch)
        let count = await query.requests.count
        XCTAssertEqual(count, 4)
    }

    @MainActor
    func testConcurrentLoadsShareSingleYearQuery() async {
        let now = date()
        let query = CalendarQueryProbe(responses: [[event("future", start: now.addingTimeInterval(600), duration: 600)]],
                                       suspendFirst: true)
        let cache = CalendarUpcomingEventCache()
        let calendar = calendar()
        let first = Task { await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch) }
        await query.waitForFirst()
        let second = Task { await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch) }
        for _ in 0..<5 { await Task.yield() }
        await query.releaseFirst()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, secondResult)
        let count = await query.requests.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testStoreInvalidationDuringFetchCannotPublishOrCacheOldResult() async {
        let now = date()
        let old = event("old", start: now.addingTimeInterval(600), duration: 600)
        let fresh = event("fresh", start: now.addingTimeInterval(1_200), duration: 600)
        let query = CalendarQueryProbe(responses: [[old], [fresh]], suspendFirst: true)
        let cache = CalendarUpcomingEventCache()
        let calendar = calendar()
        let first = Task { await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch) }
        await query.waitForFirst()
        cache.invalidate()
        let second = await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch)
        await query.releaseFirst()
        let firstResult = await first.value
        XCTAssertEqual(second.sidebarUpcomingEvents.map(\.id), ["fresh"])
        XCTAssertEqual(firstResult.sidebarUpcomingEvents.map(\.id), ["fresh"])
        let repeated = await cache.snapshot(at: now, calendar: calendar, fetch: query.fetch)
        XCTAssertEqual(repeated.sidebarUpcomingEvents.map(\.id), ["fresh"])
        let count = await query.requests.count
        XCTAssertEqual(count, 2)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(month: Int = 10, day: Int = 20) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    private func event(_ id: String, start: Date, duration: TimeInterval) -> CalendarEvent {
        .init(id: id, title: id, startDate: start, endDate: start.addingTimeInterval(duration),
              isAllDay: false, calendarTitle: "Fixture")
    }
}

private actor CalendarQueryProbe {
    struct Request: Sendable { let start: Date; let end: Date; let detailsThrough: Date }
    var requests: [Request] = []
    let responses: [[CalendarEvent]]
    let suspendFirst: Bool
    var firstContinuation: CheckedContinuation<Void, Never>?
    var firstWaiters: [CheckedContinuation<Void, Never>] = []
    init(responses: [[CalendarEvent]], suspendFirst: Bool = false) {
        self.responses = responses
        self.suspendFirst = suspendFirst
    }
    func fetch(_ start: Date, _ end: Date, _ detailsThrough: Date) async -> [CalendarEvent] {
        let index = requests.count
        requests.append(.init(start: start, end: end, detailsThrough: detailsThrough))
        let response = responses[min(index, responses.count - 1)]
        if suspendFirst && index == 0 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                firstWaiters.forEach { $0.resume() }
                firstWaiters = []
            }
        }
        return response
    }
    func waitForFirst() async {
        if firstContinuation != nil { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }
    func releaseFirst() { firstContinuation?.resume(); firstContinuation = nil }
}
