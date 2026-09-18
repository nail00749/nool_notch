import Foundation
import XCTest
@testable import NotchApp

final class MeetingReminderTests: XCTestCase {
    func testDoesNotSelectMeetingMoreThanFiveMinutesAway() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "late", startsIn: 301, now: now)

        XCTAssertNil(MeetingReminder.select(from: [meeting], at: now))
    }

    func testSelectsMeetingExactlyFiveMinutesAwayWithFiveMinuteCountdown() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "boundary", startsIn: 300, now: now)

        let reminder = MeetingReminder.select(from: [meeting], at: now)

        XCTAssertEqual(reminder?.event.id, "boundary")
        XCTAssertEqual(reminder?.countdownText(at: now), "05:00")
    }

    func testSelectsMeetingOneSecondAwayWithSecondCountdown() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "imminent", startsIn: 1, now: now)

        let reminder = MeetingReminder.select(from: [meeting], at: now)

        XCTAssertEqual(reminder?.countdownText(at: now), "00:01")
    }

    func testCountdownRoundsPartialSecondsUp() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "fractional", startsIn: 60, now: now)
        let reminder = try XCTUnwrap(MeetingReminder.select(from: [meeting], at: now))

        XCTAssertEqual(reminder.countdownText(at: now.addingTimeInterval(0.1)), "01:00")
    }

    func testDoesNotSelectMeetingAtItsExactStart() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "started", startsIn: 0, now: now)

        XCTAssertNil(MeetingReminder.select(from: [meeting], at: now))
    }

    func testSkipsAllDayMeetings() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let allDay = event(id: "all-day", startsIn: 60, now: now, isAllDay: true)

        XCTAssertNil(MeetingReminder.select(from: [allDay], at: now))
    }

    func testSelectsSoonestEligibleMeeting() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let later = event(id: "later", startsIn: 240, now: now)
        let sooner = event(id: "sooner", startsIn: 90, now: now)

        XCTAssertEqual(
            MeetingReminder.select(from: [later, sooner], at: now)?.event.id,
            "sooner"
        )
    }

    func testBreaksIdenticalStartTimesByEventID() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let laterID = event(id: "zeta", startsIn: 60, now: now)
        let earlierID = event(id: "alpha", startsIn: 60, now: now)

        XCTAssertEqual(
            MeetingReminder.select(from: [laterID, earlierID], at: now)?.event.id,
            "alpha"
        )
    }

    func testSelectsMeetingWithoutJoinURL() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let meeting = event(id: "offline", startsIn: 60, now: now)

        let reminder = MeetingReminder.select(from: [meeting], at: now)

        XCTAssertEqual(reminder?.event.id, "offline")
        XCTAssertNil(reminder?.event.joinURL)
    }

    private func event(
        id: String,
        startsIn seconds: TimeInterval,
        now: Date,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: id,
            startDate: now.addingTimeInterval(seconds),
            endDate: now.addingTimeInterval(seconds + 1_800),
            isAllDay: isAllDay,
            calendarTitle: "Работа"
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }
}
