import XCTest
import SwiftUI
import AppKit
@testable import NotchApp

final class CalendarSidebarEventsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testMonthIsDefaultAndRenderSidebarFixture() async throws {
        let provider = FakeCalendarProvider()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let next = CalendarEvent(id: "next", title: "Обсуждение нового дизайна",
            startDate: tomorrow, endDate: tomorrow.addingTimeInterval(3600),
            isAllDay: false, calendarTitle: "Работа")
        provider.upcomingState = .loaded(.init(upcomingEvents: [next], monthEvents: [next]))
        let model = NotchViewModel(providers: [], calendarProvider: provider,
            nowPlayingProvider: FakeNowPlayingProvider(),
            liveActivityCenter: LiveActivityCenter(additionalSources: []),
            jiraProvider: FakeJiraProvider(), preferences: MemoryAppPreferences(),
            displays: makeTestDisplayFeatureModel())
        XCTAssertEqual(model.calendarViewMode, .month)
        guard ProcessInfo.processInfo.environment["NOOL_CALENDAR_RENDER_FIXTURE"] == "1" else { return }
        model.refreshCalendar()
        for _ in 0..<20 { await Task.yield() }
        let size = NSSize(width: 560, height: 350)
        let host = NSHostingView(rootView: CalendarPanel(model: model)
            .frame(width: size.width, height: size.height).background(.black).preferredColorScheme(.dark))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/nool-calendar-sidebar.png"))
    }

    func testSkipsEveryEventAlreadyShownForSelectedDay() {
        let today = event("today", offset: 60)
        let laterToday = event("laterToday", offset: 120)
        let tomorrow = event("tomorrow", offset: 86_400)
        XCTAssertEqual(CalendarSidebarEvents.next(in: [tomorrow, today, laterToday],
            excluding: [today, laterToday], at: now)?.id, tomorrow.id)
    }

    func testSelectedFutureDayDoesNotHideEarlierUpcomingEvent() {
        let tomorrow = event("tomorrow", offset: 86_400)
        let selected = event("selected", offset: 172_800)
        XCTAssertEqual(CalendarSidebarEvents.next(in: [selected, tomorrow],
            excluding: [selected], at: now)?.id, tomorrow.id)
    }

    func testPastAndDuplicateCachedEventsDoNotChangeNextEvent() {
        let past = event("past", offset: -3_600)
        let next = event("next", offset: 60)
        XCTAssertEqual(CalendarSidebarEvents.next(in: [past, next, next], excluding: [], at: now)?.id, next.id)
        XCTAssertNil(CalendarSidebarEvents.next(in: [past, next, next], excluding: [next], at: now))
    }

    private func event(_ id: String, offset: TimeInterval) -> CalendarEvent {
        .init(id: id, title: id, startDate: now.addingTimeInterval(offset),
              endDate: now.addingTimeInterval(offset + 60), isAllDay: false, calendarTitle: "Test")
    }
}
