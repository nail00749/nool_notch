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
