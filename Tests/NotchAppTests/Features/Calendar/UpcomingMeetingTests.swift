import Foundation
import XCTest
@testable import NotchApp

final class UpcomingMeetingTests: XCTestCase {
    func testConferenceURLUsesRecognizedHTTPSLinkFromLocation() {
        let url = CalendarConferenceLinkResolver.joinURL(
            eventURL: nil,
            location: "Zoom: https://acme.zoom.us/j/987654321?pwd=secret",
            notes: nil
        )

        XCTAssertEqual(url?.absoluteString, "https://acme.zoom.us/j/987654321?pwd=secret")
    }

    func testConferenceURLPrefersEventURLOverLocationAndNotes() {
        let url = CalendarConferenceLinkResolver.joinURL(
            eventURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            location: "https://teams.microsoft.com/l/meetup-join/other",
            notes: "https://zoom.us/j/123456789"
        )

        XCTAssertEqual(url?.host, "meet.google.com")
    }

    func testConferenceURLRejectsInsecureAndLookalikeHosts() {
        XCTAssertNil(
            CalendarConferenceLinkResolver.joinURL(
                eventURL: URL(string: "http://zoom.us/j/123456789"),
                location: "https://zoom.us.evil.example/j/123456789",
                notes: "https://notzoom.us/j/123456789"
            )
        )
    }

    func testSelectionPrefersAnOngoingMeetingOverAnEarlierFutureMeeting() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let future = event(
            id: "future",
            start: try date("2026-09-07T12:05:00Z"),
            end: try date("2026-09-07T12:35:00Z")
        )
        let ongoing = event(
            id: "ongoing",
            start: try date("2026-09-07T11:45:00Z"),
            end: try date("2026-09-07T12:30:00Z")
        )

        let meeting = UpcomingMeeting.select(from: [future, ongoing], at: now)

        XCTAssertEqual(meeting?.event.id, "ongoing")
        XCTAssertEqual(meeting?.state(at: now), .ongoing)
    }

    func testSelectionSkipsAllDayAndEndedEvents() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let ended = event(
            id: "ended",
            start: try date("2026-09-07T11:00:00Z"),
            end: try date("2026-09-07T12:00:00Z")
        )
        let allDayEvents = try (0..<5).map { index in
            event(
                id: "all-day-\(index)",
                start: try date("2026-09-07T00:00:00Z"),
                end: try date("2026-09-08T00:00:00Z"),
                isAllDay: true
            )
        }
        let next = event(
            id: "next",
            start: try date("2026-09-07T12:15:00Z"),
            end: try date("2026-09-07T12:45:00Z")
        )

        let meeting = UpcomingMeeting.select(from: [ended] + allDayEvents + [next], at: now)

        XCTAssertEqual(meeting?.event.id, "next")
        XCTAssertEqual(meeting?.state(at: now), .startsIn)
    }

    private func event(
        id: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            calendarTitle: "Работа"
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }
}
