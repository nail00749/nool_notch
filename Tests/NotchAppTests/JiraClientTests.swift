import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class JiraClientTests: XCTestCase {
    private let baseURL = URL(string: "https://jira.example.test/company")!
    private let token = "secret-value"

    func testSearchPreservesBasePathAndBuildsFilteredJQL() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.searchPage)
        let client = JiraClient(transport: transport)

        _ = try await client.issues(
            baseURL: baseURL,
            token: token,
            projectKeys: ["WEB", "APP"]
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://jira.example.test/company/rest/api/2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try jsonObject(from: request)
        XCTAssertEqual(
            body["jql"] as? String,
            "assignee = currentUser() AND resolution IS EMPTY AND statusCategory != Done AND project IN (\"APP\", \"WEB\") ORDER BY priority DESC, updated DESC"
        )
        XCTAssertEqual(body["maxResults"] as? Int, 50)
        XCTAssertEqual(
            body["fields"] as? [String],
            ["key", "summary", "project", "status", "priority", "duedate", "updated"]
        )
        assertTokenOnlyInAuthorization(request)
    }

    func testSearchWithoutProjectsExcludesDoneStatusCategory() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.searchPage)
        let client = JiraClient(transport: transport)

        _ = try await client.issues(baseURL: baseURL, token: token, projectKeys: [])

        let request = try XCTUnwrap(transport.requests.first)
        let body = try jsonObject(from: request)
        XCTAssertEqual(
            body["jql"] as? String,
            "assignee = currentUser() AND resolution IS EMPTY AND statusCategory != Done ORDER BY priority DESC, updated DESC"
        )
        assertTokenOnlyInAuthorization(request)
    }

    func testSearchEscapesProjectKeysForJQL() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.searchPage)
        let client = JiraClient(transport: transport)

        _ = try await client.issues(
            baseURL: baseURL,
            token: token,
            projectKeys: [#"APP\CORE"#, #"WEB"OPS"#]
        )

        let request = try XCTUnwrap(transport.requests.first)
        let body = try jsonObject(from: request)
        XCTAssertEqual(
            body["jql"] as? String,
            #"assignee = currentUser() AND resolution IS EMPTY AND statusCategory != Done AND project IN ("APP\\CORE", "WEB\"OPS") ORDER BY priority DESC, updated DESC"#
        )
        assertTokenOnlyInAuthorization(request)
    }

    func testCurrentUserPreservesBasePath() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.user)
        let client = JiraClient(transport: transport)

        let user = try await client.currentUser(baseURL: baseURL, token: token)

        XCTAssertEqual(user.displayName, "Ada Lovelace")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://jira.example.test/company/rest/api/2/myself")
        assertTokenOnlyInAuthorization(request)
    }

    func testProjectsPreservesBasePath() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.projects)
        let client = JiraClient(transport: transport)

        let projects = try await client.projects(baseURL: baseURL, token: token)

        XCTAssertEqual(projects, [JiraProject(id: "100", key: "APP", name: "Application")])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://jira.example.test/company/rest/api/2/project")
        assertTokenOnlyInAuthorization(request)
    }

    func testTransitionsEncodeIssueKey() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.transitions)
        let client = JiraClient(transport: transport)

        _ = try await client.transitions(
            baseURL: baseURL,
            token: token,
            issueKey: "APP-184/child"
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        let components = try XCTUnwrap(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        XCTAssertTrue(components.percentEncodedPath.hasSuffix("/issue/APP-184%2Fchild/transitions"))
        assertTokenOnlyInAuthorization(request)
    }

    func testPerformTransitionPostsSelectedIDOnce() async throws {
        let transport = RecordingJiraTransport(data: Data(), statusCode: 204)
        let client = JiraClient(transport: transport)

        try await client.performTransition(
            baseURL: baseURL,
            token: token,
            issueKey: "APP-184",
            transitionID: "31"
        )

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://jira.example.test/company/rest/api/2/issue/APP-184/transitions"
        )
        XCTAssertEqual(
            try jsonObject(from: request) as NSDictionary,
            ["transition": ["id": "31"]] as NSDictionary
        )
        assertTokenOnlyInAuthorization(request)
    }

    func testAddWorklogPostsSecondsCommentAndLeavesEstimate() async throws {
        let transport = RecordingJiraTransport(data: Data(), statusCode: 201)
        let client = JiraClient(transport: transport)

        try await client.addWorklog(
            baseURL: baseURL,
            token: token,
            issueKey: "APP-184/child",
            timeSpentSeconds: 5_400,
            comment: "Implemented cache invalidation."
        )

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let components = try XCTUnwrap(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        XCTAssertTrue(components.percentEncodedPath.hasSuffix("/issue/APP-184%2Fchild/worklog"))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "adjustEstimate", value: "leave")])
        XCTAssertEqual(
            try jsonObject(from: request) as NSDictionary,
            [
                "timeSpentSeconds": 5_400,
                "comment": "Implemented cache invalidation."
            ] as NSDictionary
        )
        assertTokenOnlyInAuthorization(request)
    }

    func testIssueDecodingAllowsMissingPriorityAndDueDate() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.searchPageWithoutOptionals)
        let client = JiraClient(transport: transport)

        let page = try await client.issues(baseURL: baseURL, token: token, projectKeys: [])

        let issue = try XCTUnwrap(page.issues.first)
        XCTAssertNil(issue.priorityName)
        XCTAssertNil(issue.dueDate)
        XCTAssertNotNil(issue.updatedAt)
    }

    func testIssueDecodingRejectsInvalidPresentDueDate() async {
        let transport = RecordingJiraTransport(data: Fixtures.searchPageWithInvalidDueDate)
        let client = JiraClient(transport: transport)

        do {
            _ = try await client.issues(baseURL: baseURL, token: token, projectKeys: [])
            XCTFail("Expected an invalid present due date to fail")
        } catch {
            XCTAssertEqual(error as? JiraAPIError, .decoding)
        }
    }

    func testIssueDecodingRejectsInvalidPresentUpdatedDate() async {
        let transport = RecordingJiraTransport(data: Fixtures.searchPageWithInvalidUpdatedDate)
        let client = JiraClient(transport: transport)

        do {
            _ = try await client.issues(baseURL: baseURL, token: token, projectKeys: [])
            XCTFail("Expected an invalid present updated timestamp to fail")
        } catch {
            XCTAssertEqual(error as? JiraAPIError, .decoding)
        }
    }

    func testIssueDecodingPreservesCustomStatus() async throws {
        let transport = RecordingJiraTransport(data: Fixtures.searchPage)
        let client = JiraClient(transport: transport)

        let page = try await client.issues(baseURL: baseURL, token: token, projectKeys: [])

        let issue = try XCTUnwrap(page.issues.first)
        XCTAssertEqual(issue.status.name, "Ready for Moonshot")
        XCTAssertEqual(issue.status.categoryKey, "custom-flight")
    }

    func testHTTPFailuresMapToSafeErrors() async {
        let cases: [(Int, JiraAPIError)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (429, .rateLimited),
            (503, .server(503)),
            (418, .http(418))
        ]

        for (statusCode, expectedError) in cases {
            let transport = RecordingJiraTransport(
                data: Data(#"{"server":"must not leak"}"#.utf8),
                statusCode: statusCode
            )
            let client = JiraClient(transport: transport)

            do {
                _ = try await client.currentUser(baseURL: baseURL, token: token)
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch {
                XCTAssertEqual(error as? JiraAPIError, expectedError)
            }
        }
    }

    func testMalformedSuccessfulJSONThrowsDecoding() async {
        let transport = RecordingJiraTransport(data: Data("not-json".utf8))
        let client = JiraClient(transport: transport)

        do {
            _ = try await client.currentUser(baseURL: baseURL, token: token)
            XCTFail("Expected malformed JSON to fail")
        } catch {
            XCTAssertEqual(error as? JiraAPIError, .decoding)
        }
    }

    func testTransportFailuresMapToNetworkUnlessAlreadySafe() async {
        for (transportError, expectedError) in [
            (TestTransportError.offline as Error, JiraAPIError.network),
            (JiraAPIError.forbidden as Error, JiraAPIError.forbidden)
        ] {
            let transport = RecordingJiraTransport(error: transportError)
            let client = JiraClient(transport: transport)

            do {
                _ = try await client.currentUser(baseURL: baseURL, token: token)
                XCTFail("Expected transport failure")
            } catch {
                XCTAssertEqual(error as? JiraAPIError, expectedError)
            }
        }
    }

    func testRedirectPolicyAllowsSameOriginPathChanges() {
        XCTAssertTrue(
            JiraSameOriginRedirectPolicy.allowsRedirect(
                from: URL(string: "https://jira.example.test/company/rest/api/2/search")!,
                to: URL(string: "https://JIRA.EXAMPLE.TEST/login")!
            )
        )
    }

    func testRedirectPolicyRejectsCrossOrigin() {
        XCTAssertFalse(
            JiraSameOriginRedirectPolicy.allowsRedirect(
                from: URL(string: "https://jira.example.test/company")!,
                to: URL(string: "https://evil.example/collect")!
            )
        )
    }

    func testRedirectPolicyRejectsDifferentExplicitOrEffectivePorts() {
        XCTAssertFalse(
            JiraSameOriginRedirectPolicy.allowsRedirect(
                from: URL(string: "https://jira.example.test/company")!,
                to: URL(string: "https://jira.example.test:8443/company")!
            )
        )
        XCTAssertFalse(
            JiraSameOriginRedirectPolicy.allowsRedirect(
                from: URL(string: "http://jira.example.test:443/company")!,
                to: URL(string: "https://jira.example.test/company")!
            )
        )
        XCTAssertTrue(
            JiraSameOriginRedirectPolicy.allowsRedirect(
                from: URL(string: "https://jira.example.test:443/company")!,
                to: URL(string: "https://jira.example.test/other")!
            )
        )
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertTokenOnlyInAuthorization(
        _ request: URLRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)",
            file: file,
            line: line
        )
        XCTAssertFalse(request.url?.absoluteString.contains(token) == true, file: file, line: line)
        XCTAssertFalse(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains(token) == true,
            file: file,
            line: line
        )
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "authorization" {
            XCTAssertFalse(value.contains(token), "Token leaked into \(name)", file: file, line: line)
        }
    }
}

@MainActor
private final class RecordingJiraTransport: JiraHTTPTransport {
    private let responseData: Data
    private let statusCode: Int
    private let error: Error?
    private(set) var requests: [URLRequest] = []

    init(data: Data = Data(), statusCode: Int = 200, error: Error? = nil) {
        responseData = data
        self.statusCode = statusCode
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (responseData, response)
    }
}

private enum TestTransportError: Error {
    case offline
}

private enum Fixtures {
    static let user = data(
        #"{"self":"https://jira.example.test/rest/api/2/user?accountId=ada","accountId":"ada","displayName":"Ada Lovelace","active":true}"#
    )

    static let projects = data(
        #"[{"self":"https://jira.example.test/rest/api/2/project/100","id":"100","key":"APP","name":"Application","projectTypeKey":"software","simplified":false}]"#
    )

    static let searchPage = searchPageJSON(priority: #"{"id":"2","name":"High","self":"https://jira.example.test/rest/api/2/priority/2","iconUrl":"https://jira.example.test/icons/high.svg"}"#, dueDate: #""2026-09-15""#)
    static let searchPageWithoutOptionals = searchPageJSON(priority: "null", dueDate: "null")
    static let searchPageWithInvalidDueDate = searchPageJSON(
        priority: "null",
        dueDate: #""not-a-date""#
    )
    static let searchPageWithInvalidUpdatedDate = searchPageJSON(
        priority: "null",
        dueDate: "null",
        updated: #""not-a-timestamp""#
    )

    static let transitions = data(
        #"{"expand":"transitions","transitions":[{"id":"31","name":"Done","to":{"self":"https://jira.example.test/rest/api/2/status/10000","description":"Custom workflow status","iconUrl":"https://jira.example.test/icons/done.svg","name":"Ready for Moonshot","id":"10000","statusCategory":{"self":"https://jira.example.test/rest/api/2/statuscategory/4","id":4,"key":"custom-flight","colorName":"green","name":"Flying"}},"hasScreen":false,"isGlobal":true,"isInitial":false,"isAvailable":true}]}"#
    )

    private static func searchPageJSON(
        priority: String,
        dueDate: String,
        updated: String = #""2026-08-31T12:30:00.000+0000""#
    ) -> Data {
        data(
            """
            {
              "startAt": 0,
              "maxResults": 50,
              "total": 1,
              "issues": [{
                "expand": "operations,versionedRepresentations",
                "id": "10001",
                "self": "https://jira.example.test/rest/api/2/issue/10001",
                "key": "APP-184",
                "fields": {
                  "summary": "Ship the task panel",
                  "project": {
                    "self": "https://jira.example.test/rest/api/2/project/100",
                    "id": "100",
                    "key": "APP",
                    "name": "Application",
                    "projectTypeKey": "software",
                    "simplified": false
                  },
                  "status": {
                    "self": "https://jira.example.test/rest/api/2/status/10000",
                    "description": "Custom workflow status",
                    "iconUrl": "https://jira.example.test/icons/status.svg",
                    "name": "Ready for Moonshot",
                    "id": "10000",
                    "statusCategory": {
                      "self": "https://jira.example.test/rest/api/2/statuscategory/4",
                      "id": 4,
                      "key": "custom-flight",
                      "colorName": "yellow",
                      "name": "In Flight"
                    }
                  },
                  "priority": \(priority),
                  "duedate": \(dueDate),
                  "updated": \(updated)
                }
              }]
            }
            """
        )
    }

    private static func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
