import Foundation
import XCTest
@testable import NotchApp

final class AISessionJiraLinkTests: XCTestCase {
    func testDoesNotInspectSessionTitleForIssueKeys() {
        let session = makeSession(
            title: "Finish npa-123 integration",
            workspacePath: "/tmp/ABC-9"
        )

        XCTAssertEqual(AISessionJiraLink.issueKey(for: session), "ABC-9")
    }

    func testFindsIssueKeyInGitBranch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory,
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/feature/NPA-456-agent-link\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            AISessionJiraLink.issueKey(for: makeSession(title: "Agent link", workspacePath: root.path)),
            "NPA-456"
        )
    }

    func testBuildsRoundedWorklogFromCompletedSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        let session = AISession(
            id: AISessionID(sourceID: "test", sessionID: "1"),
            agentName: "Codex",
            title: "NPA-42 implementation",
            workspacePath: nil,
            modelName: nil,
            status: .completed,
            startedAt: start,
            accumulatedActiveDuration: 67 * 60,
            lastActivity: start.addingTimeInterval(67 * 60),
            isStale: false
        )

        let draft = AISessionJiraLink.suggestedWorklog(for: session)

        XCTAssertEqual(draft?.hours, 1)
        XCTAssertEqual(draft?.minutes, 10)
        XCTAssertEqual(draft?.description, "Работа с AI-ассистентом")
    }

    func testDoesNotSuggestWorklogWithoutKnownStartTime() {
        let session = makeSession(title: "NPA-42 implementation", workspacePath: nil)

        XCTAssertNil(AISessionJiraLink.suggestedWorklog(for: session))
    }

    func testFindsIssueKeyThroughWorktreeGitFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktree = root.appendingPathComponent("checkout", isDirectory: true)
        let gitDirectory = root.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "gitdir: ../metadata\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/codex/NPA-789-worktree\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            AISessionJiraLink.issueKey(for: makeSession(title: "Worktree", workspacePath: worktree.path)),
            "NPA-789"
        )
    }

    private func makeSession(title: String, workspacePath: String?) -> AISession {
        AISession(
            id: AISessionID(sourceID: "test", sessionID: UUID().uuidString),
            agentName: "Codex",
            title: title,
            workspacePath: workspacePath,
            modelName: nil,
            status: .running,
            lastActivity: .now,
            isStale: false
        )
    }
}
