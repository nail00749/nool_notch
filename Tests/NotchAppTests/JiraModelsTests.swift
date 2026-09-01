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
}
