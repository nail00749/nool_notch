import Foundation
import XCTest
@testable import NotchApp

final class UnifiedSearchTests: XCTestCase {
    func testNonMatchingStaleCopyDoesNotHideMatchingEvent() {
        let stale = CalendarEvent(id: "same", title: "Старое название", startDate: .distantFuture,
            endDate: .distantFuture, isAllDay: false, calendarTitle: "Команда")
        let fresh = CalendarEvent(id: "same", title: "Поиск", startDate: .distantFuture,
            endDate: .distantFuture, isAllDay: false, calendarTitle: "Команда")
        XCTAssertEqual(UnifiedSearch.results(query: "поиск", issues: [], sessions: [],
            events: [stale, fresh]), [.event(fresh)])
    }

    func testSearchFindsAllSourcesAndDeduplicatesLoadedCaches() {
        let event = CalendarEvent(
            id: "event", title: "Обсуждение поиска", startDate: .distantFuture,
            endDate: .distantFuture, isAllDay: false, calendarTitle: "Команда"
        )
        let session = AISession(
            id: AISessionID(sourceID: "test", sessionID: "session"), agentName: "Codex",
            title: "Реализация поиска", workspacePath: "/tmp/project", modelName: nil,
            status: .running, lastActivity: .now, isStale: false
        )
        let results = UnifiedSearch.results(
            query: "ПОИСК", issues: [issue, issue], sessions: [session], events: [event, event]
        )
        XCTAssertEqual(Set(results.map(\.id)), ["jira:TEST-1", "ai:test:session", "calendar:event"])
        XCTAssertEqual(results.count, 3)
    }

    func testWhitespaceQueryHasNoResultsAndAllWordsMustMatch() {
        XCTAssertTrue(UnifiedSearch.results(query: " \n ", issues: [issue], sessions: [], events: []).isEmpty)
        XCTAssertEqual(UnifiedSearch.results(query: "test поиск", issues: [issue], sessions: [], events: []).count, 1)
        XCTAssertTrue(UnifiedSearch.results(query: "test музыка", issues: [issue], sessions: [], events: []).isEmpty)
    }

    private var issue: JiraIssue {
        JiraIssue(
            id: "issue", key: "TEST-1", summary: "Улучшение поиска", projectKey: "TEST",
            projectName: "Test", status: JiraStatus(id: "open", name: "В работе", categoryKey: "indeterminate"),
            priorityName: nil, dueDate: nil, updatedAt: nil
        )
    }
}
