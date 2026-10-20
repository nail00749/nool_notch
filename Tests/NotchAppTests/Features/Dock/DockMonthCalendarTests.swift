import Foundation
import XCTest
@testable import NotchApp

final class DockMonthCalendarTests: XCTestCase {
    func testLeapFebruaryStartsOnCorrectWeekdayAndIncludesEveryDay() throws {
        let calendar = makeCalendar(timeZone: "Europe/Moscow", firstWeekday: 2)
        let grid = DockMonthGrid(month: date(2024, 2, 15, calendar: calendar), calendar: calendar)
        XCTAssertEqual(grid.cells.prefix(3).compactMap { $0 }.count, 0)
        XCTAssertEqual(grid.cells.firstIndex(where: { $0 != nil }), 3)
        XCTAssertEqual(grid.cells.compactMap { $0 }.map { calendar.component(.day, from: $0) }, Array(1...29))
        XCTAssertEqual(grid.rowCount, 5)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(grid.cells.compactMap { $0 }.last)), 29)
    }

    func testCommonFebruaryAndSixRowMonthStayWithinTheirMonth() {
        let calendar = makeCalendar(timeZone: "UTC", firstWeekday: 2)
        let february = DockMonthGrid(month: date(2021, 2, 15, calendar: calendar), calendar: calendar)
        XCTAssertEqual(february.cells.compactMap { $0 }.count, 28)
        XCTAssertEqual(february.rowCount, 5)
        let september = DockMonthGrid(month: date(2024, 9, 20, calendar: calendar), calendar: calendar)
        XCTAssertEqual(september.rowCount, 6)
        XCTAssertEqual(september.cells.firstIndex(where: { $0 != nil }), 6)
        XCTAssertEqual(september.cells.compactMap { $0 }.count, 30)
        XCTAssertTrue(september.cells.compactMap { $0 }.allSatisfy { september.interval.start <= $0 && $0 < september.interval.end })
    }

    func testLocaleAndFirstWeekdayDetermineColumnOrder() {
        var sunday = makeCalendar(timeZone: "UTC", firstWeekday: 1)
        sunday.locale = Locale(identifier: "en_US")
        let american = DockMonthGrid(month: date(2024, 9, 5, calendar: sunday), calendar: sunday)
        XCTAssertEqual(american.weekdayTitles.first, sunday.shortStandaloneWeekdaySymbols[0])
        XCTAssertEqual(american.cells.firstIndex(where: { $0 != nil }), 0)
        var monday = sunday
        monday.firstWeekday = 2
        monday.locale = Locale(identifier: "ru_RU")
        let russian = DockMonthGrid(month: date(2024, 9, 5, calendar: monday), calendar: monday)
        XCTAssertEqual(russian.weekdayTitles.first, monday.shortStandaloneWeekdaySymbols[1])
        XCTAssertEqual(russian.cells.firstIndex(where: { $0 != nil }), 6)
        XCTAssertEqual(russian.weekdayTitles.count, 7)
        XCTAssertTrue(russian.title.contains("2024"))
    }

    func testCalendarDayArithmeticSurvivesSpringAndFallDST() throws {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles", firstWeekday: 1)
        for (month, dayCount, dstDay, expectedHours) in [(3, 31, 10, 23), (11, 30, 3, 25)] {
            let grid = DockMonthGrid(month: date(2024, month, 15, calendar: calendar), calendar: calendar)
            let days = grid.cells.compactMap { $0 }
            XCTAssertEqual(days.count, dayCount)
            XCTAssertEqual(Set(days).count, dayCount)
            XCTAssertEqual(days.map { calendar.component(.day, from: $0) }, Array(1...dayCount))
            XCTAssertTrue(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
            let transition = try XCTUnwrap(days.first { calendar.component(.day, from: $0) == dstDay })
            let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: transition))
            XCTAssertEqual(next.timeIntervalSince(transition), Double(expectedHours * 3600), accuracy: 1)
        }
    }

    func testMonthNavigationNormalizesBeforeCrossingYearAndLeapBoundary() throws {
        let calendar = makeCalendar(timeZone: "Europe/Moscow", firstWeekday: 2)
        let december = DockMonthGrid(month: date(2023, 12, 31, calendar: calendar), calendar: calendar)
        let january = try XCTUnwrap(december.shiftedMonth(by: 1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: january), DateComponents(year: 2024, month: 1, day: 1))
        let march = DockMonthGrid(month: date(2024, 3, 31, calendar: calendar), calendar: calendar)
        let february = try XCTUnwrap(march.shiftedMonth(by: -1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: february), DateComponents(year: 2024, month: 2, day: 1))
        XCTAssertEqual(DockMonthGrid(month: february, calendar: calendar).cells.compactMap { $0 }.count, 29)
    }

    func testSelectedDayEventsRespectExclusiveMidnightAndDeduplicateCachedRecords() {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles", firstWeekday: 1)
        let day = date(2024, 3, 10, calendar: calendar)
        let next = date(2024, 3, 11, calendar: calendar)
        let previous = date(2024, 3, 9, calendar: calendar)
        let allDay = event("all-day", start: day, end: next, allDay: true)
        let endingAtStart = event("previous", start: previous, end: day)
        let beginningAtEnd = event("next", start: next, end: next.addingTimeInterval(3600))
        let spanning = event("overnight", start: previous.addingTimeInterval(23 * 3600), end: day.addingTimeInterval(3600))
        let point = event("point", start: day.addingTimeInterval(2 * 3600), end: day.addingTimeInterval(2 * 3600))
        let matched = DockMonthGrid.events(on: day, from: [allDay, endingAtStart, beginningAtEnd, spanning, point, allDay], calendar: calendar)
        XCTAssertEqual(matched.map(\.id), ["all-day", "overnight", "point"])
        XCTAssertEqual(DockMonthGrid.events(on: next, from: [allDay, beginningAtEnd], calendar: calendar).map(\.id), ["next"])
    }

    private func makeCalendar(timeZone: String, firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, startDate: start, endDate: end, isAllDay: allDay, calendarTitle: "Fixture")
    }
}
