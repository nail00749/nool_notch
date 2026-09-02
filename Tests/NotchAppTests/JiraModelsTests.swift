import Foundation
import XCTest
@testable import NotchApp

final class JiraModelsTests: XCTestCase {
    func testIssueBrowserURLPreservesConfiguredBasePathPrefix() {
        let issue = JiraIssue(
            id: "10001",
            key: "APP-184",
            summary: "Example issue",
            projectKey: "APP",
            projectName: "App",
            status: JiraStatus(id: "1", name: "Open", categoryKey: "new"),
            priorityName: nil,
            dueDate: nil,
            updatedAt: nil
        )

        XCTAssertEqual(
            issue.browserURL(baseURL: "https://jira.example.test/company"),
            URL(string: "https://jira.example.test/company/browse/APP-184")
        )
    }

    func testWorklogDraftConvertsDurationAndNormalizesDescription() {
        let draft = JiraWorklogDraft(
            hours: 1,
            minutes: 30,
            description: "  Implemented cache invalidation.\n"
        )

        XCTAssertEqual(draft.timeSpentSeconds, 5_400)
        XCTAssertEqual(draft.normalizedDescription, "Implemented cache invalidation.")
        XCTAssertTrue(draft.isValid)
    }

    func testWorklogDraftRejectsInvalidDurationOrBlankDescription() {
        XCTAssertFalse(
            JiraWorklogDraft(hours: 0, minutes: 0, description: "Done").isValid
        )
        XCTAssertFalse(
            JiraWorklogDraft(hours: 1, minutes: 0, description: "  \n").isValid
        )
        XCTAssertFalse(
            JiraWorklogDraft(hours: 25, minutes: 0, description: "Done").isValid
        )
        XCTAssertFalse(
            JiraWorklogDraft(hours: 0, minutes: 60, description: "Done").isValid
        )
    }

    func testWorklogDurationOptionsUseFiveMinuteSteps() {
        XCTAssertEqual(JiraWorklogDurationOptions.hourValues, Array(0...24))
        XCTAssertEqual(
            JiraWorklogDurationOptions.minuteValues,
            Array(stride(from: 0, through: 55, by: 5))
        )
    }
}
