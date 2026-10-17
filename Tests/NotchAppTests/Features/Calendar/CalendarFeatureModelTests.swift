import XCTest
@testable import NotchApp

@MainActor
final class CalendarFeatureModelTests: XCTestCase {
    func testBackgroundStartDoesNotRequestCalendarPermission() async {
        let provider = FakeCalendarProvider()
        let model = CalendarFeatureModel(provider: provider)
        model.start(enabled: true)
        model.start(enabled: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(provider.loadUpcomingEventsCallCount, 0)
        model.stop()
    }

    func testStopRejectsLateProviderResultAndFurtherRefreshes() async {
        let provider = FakeCalendarProvider()
        var completion: CheckedContinuation<CalendarLoadState, Never>?
        provider.upcomingLoader = { await withCheckedContinuation { completion = $0 } }
        let model = CalendarFeatureModel(provider: provider)
        model.refreshCalendar()
        for _ in 0..<100 where completion == nil { await Task.yield() }
        XCTAssertNotNil(completion)
        model.stop()
        completion?.resume(returning: .loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: [])))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.calendarState, .loading)
        XCTAssertNil(model.calendarRefreshedAt)
        model.refreshCalendar()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(provider.loadUpcomingEventsCallCount, 1)
    }

    func testRefreshKeepingContentLeavesLoadedSnapshotVisible() async {
        let provider = FakeCalendarProvider()
        let loaded = CalendarLoadState.loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: []))
        provider.upcomingState = loaded
        let model = CalendarFeatureModel(provider: provider)
        model.refreshCalendar()
        for _ in 0..<100 where model.calendarState != loaded { await Task.yield() }
        XCTAssertEqual(model.calendarState, loaded)
        let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
        model.loadCalendarMonthIfNeeded(for: nextMonth)
        for _ in 0..<100 where model.loadingCalendarMonth != nil { await Task.yield() }
        XCTAssertNotNil(model.calendarEventsByMonth[CalendarMonthKey(date: nextMonth)])

        var completion: CheckedContinuation<CalendarLoadState, Never>?
        provider.upcomingLoader = { await withCheckedContinuation { completion = $0 } }
        model.refreshCalendarKeepingContent()
        for _ in 0..<100 where completion == nil { await Task.yield() }
        XCTAssertEqual(model.calendarState, loaded)
        XCTAssertNotNil(model.calendarEventsByMonth[CalendarMonthKey(date: Date())])
        XCTAssertNil(model.calendarEventsByMonth[CalendarMonthKey(date: nextMonth)])
        completion?.resume(returning: loaded)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(provider.loadUpcomingEventsCallCount, 2)
        model.stop()
    }

    func testPendingRequestDoesNotRetainCalendarOwner() async {
        let provider = FakeCalendarProvider()
        var completion: CheckedContinuation<CalendarLoadState, Never>?
        provider.upcomingLoader = { await withCheckedContinuation { completion = $0 } }
        var owner: CalendarFeatureModel? = CalendarFeatureModel(provider: provider)
        weak var released = owner
        owner?.refreshCalendar()
        for _ in 0..<100 where completion == nil { await Task.yield() }
        owner = nil
        XCTAssertNil(released)
        completion?.resume(returning: .denied)
    }
}
