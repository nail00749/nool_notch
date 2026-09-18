import Foundation
import XCTest
@testable import NotchApp

final class CodeReviewProviderTests: XCTestCase {
    func testParsesGitHubSSHRemote() {
        let repository = CodeReviewRemoteParser.repository(
            rootPath: "/tmp/project",
            branch: "feature/pr-panel",
            remoteURL: "git@github.com:example/notch.git"
        )

        XCTAssertEqual(repository?.hostKind, .github)
        XCTAssertEqual(repository?.host, "github.com")
        XCTAssertEqual(repository?.projectPath, "example/notch")
    }

    func testParsesSelfHostedGitLabRemoteWithNestedGroup() {
        let repository = CodeReviewRemoteParser.repository(
            rootPath: "/tmp/project",
            branch: "feature/mr-panel",
            remoteURL: "ssh://git@gitlab.company.test/platform/apps/notch.git"
        )

        XCTAssertEqual(repository?.hostKind, .gitlab)
        XCTAssertEqual(repository?.host, "gitlab.company.test")
        XCTAssertEqual(repository?.projectPath, "platform/apps/notch")
    }

    func testDecodesGitHubChecksConflictAndReviewActivity() throws {
        let data = try XCTUnwrap(#"""
        {
          "number": 42,
          "title": "Add PR panel",
          "url": "https://github.com/example/notch/pull/42",
          "state": "OPEN",
          "isDraft": false,
          "mergeable": "CONFLICTING",
          "mergeStateStatus": "DIRTY",
          "statusCheckRollup": [
            {"status": "COMPLETED", "conclusion": "SUCCESS"},
            {"status": "IN_PROGRESS", "conclusion": null}
          ],
          "comments": [{"id": 1}, {"id": 2}],
          "latestReviews": [{"id": 3}],
          "updatedAt": "2026-09-03T10:00:00Z"
        }
        """#.data(using: .utf8))

        let request = try XCTUnwrap(CodeReviewDecoder.github(data: data))
        XCTAssertEqual(request.number, "42")
        XCTAssertEqual(request.ciState, .pending)
        XCTAssertEqual(request.completedChecks, 1)
        XCTAssertEqual(request.totalChecks, 2)
        XCTAssertEqual(request.mergeState, .conflicting)
        XCTAssertEqual(request.reviewActivityCount, 2)
        XCTAssertEqual(request.diffURL.absoluteString, "https://github.com/example/notch/pull/42/files")
    }

    func testDecodesSelfHostedGitLabPipelineAndComments() throws {
        let data = try XCTUnwrap(#"""
        {
          "iid": 17,
          "title": "Track custom GitLab",
          "web_url": "https://gitlab.company.test/platform/notch/-/merge_requests/17",
          "state": "opened",
          "draft": false,
          "has_conflicts": false,
          "head_pipeline": {"status": "failed"},
          "user_notes_count": 6,
          "updated_at": "2026-09-03T10:00:00Z"
        }
        """#.data(using: .utf8))

        let request = try XCTUnwrap(CodeReviewDecoder.gitlab(data: data))
        XCTAssertEqual(request.number, "17")
        XCTAssertEqual(request.ciState, .failed)
        XCTAssertEqual(request.mergeState, .ready)
        XCTAssertEqual(request.reviewActivityCount, 6)
        XCTAssertEqual(
            request.diffURL.absoluteString,
            "https://gitlab.company.test/platform/notch/-/merge_requests/17/diffs"
        )
    }

    func testGitHubReviewerActivityExcludesAuthorAndKeepsStableInlineIDs() throws {
        let pullRequestData = try XCTUnwrap(#"""
        {
          "number": 7,
          "title": "Review activity",
          "url": "https://github.com/example/notch/pull/7",
          "author": {"login": "feature-author"},
          "mergeable": "MERGEABLE",
          "comments": [
            {"id": 10, "author": {"login": "feature-author"}},
            {"id": 11, "author": {"login": "reviewer"}}
          ],
          "latestReviews": [
            {"id": 12, "body": "", "author": {"login": "reviewer"}},
            {"id": 13, "body": "Please adjust", "author": {"login": "reviewer"}}
          ]
        }
        """#.data(using: .utf8))
        let inlineData = try XCTUnwrap(#"""
        [[
          {"id": 20, "user": {"login": "feature-author"}},
          {"id": 21, "user": {"login": "reviewer"}}
        ]]
        """#.data(using: .utf8))

        let request = try XCTUnwrap(CodeReviewDecoder.github(data: pullRequestData))
        let inlineIDs = CodeReviewDecoder.githubInlineReviewerCommentIDs(
            data: inlineData,
            excluding: request.authorLogin
        )

        XCTAssertEqual(request.reviewerActivityIDs, ["comment:11", "review:13"])
        XCTAssertEqual(inlineIDs, ["inline:21"])
    }
}
