import Foundation

@MainActor
protocol JiraClientProtocol: AnyObject {
    func currentUser(baseURL: URL, token: String) async throws -> JiraUser
    func projects(baseURL: URL, token: String) async throws -> [JiraProject]
    func issues(baseURL: URL, token: String, projectKeys: Set<String>) async throws -> JiraSearchPage
    func boards(baseURL: URL, token: String) async throws -> [JiraBoard]
    func boardIssues(baseURL: URL, token: String, boardID: String) async throws -> JiraSearchPage
    func projectIssues(baseURL: URL, token: String, projectKey: String) async throws -> JiraSearchPage
    func issue(baseURL: URL, token: String, issueKey: String) async throws -> JiraIssue
    func transitions(baseURL: URL, token: String, issueKey: String) async throws -> [JiraTransition]
    func performTransition(baseURL: URL, token: String, issueKey: String, transitionID: String) async throws
    func addWorklog(
        baseURL: URL,
        token: String,
        issueKey: String,
        timeSpentSeconds: Int,
        comment: String
    ) async throws
}

@MainActor
protocol JiraHTTPTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class JiraSameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowsRedirect(from originalURL: URL, to targetURL: URL) -> Bool {
        guard let original = origin(of: originalURL),
              let target = origin(of: targetURL) else { return false }

        return original.scheme == target.scheme
            && original.host == target.host
            && original.port == target.port
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = response.url,
              let targetURL = request.url,
              Self.allowsRedirect(from: originalURL, to: targetURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func origin(of url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }

        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else if scheme == "https" {
            port = 443
        } else if scheme == "http" {
            port = 80
        } else {
            return nil
        }

        return (scheme, host, port)
    }
}

@MainActor
final class JiraURLSessionTransport: JiraHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: JiraSameOriginRedirectPolicy(),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraAPIError.invalidResponse
        }
        return (data, httpResponse)
    }
}

@MainActor
final class JiraClient: JiraClientProtocol {
    private let transport: JiraHTTPTransport

    init(transport: JiraHTTPTransport? = nil) {
        self.transport = transport ?? JiraURLSessionTransport()
    }

    func currentUser(baseURL: URL, token: String) async throws -> JiraUser {
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "GET",
            pathComponents: ["rest", "api", "2", "myself"]
        )
        let response: UserResponse = try await decodedResponse(for: request)
        return JiraUser(displayName: response.displayName)
    }

    func projects(baseURL: URL, token: String) async throws -> [JiraProject] {
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "GET",
            pathComponents: ["rest", "api", "2", "project"]
        )
        let response: [ProjectResponse] = try await decodedResponse(for: request)
        return response.map { JiraProject(id: $0.id, key: $0.key, name: $0.name) }
    }

    func issues(
        baseURL: URL,
        token: String,
        projectKeys: Set<String>
    ) async throws -> JiraSearchPage {
        let response = try await searchPage(
            baseURL: baseURL,
            token: token,
            jql: Self.searchJQL(projectKeys: projectKeys),
            startAt: 0,
            maxResults: 50
        )
        return JiraSearchPage(
            issues: try response.issues.map { try Self.makeIssue($0) },
            total: response.total
        )
    }

    func boards(baseURL: URL, token: String) async throws -> [JiraBoard] {
        var startAt = 0
        let maxResults = 50
        var boards: [JiraBoard] = []

        while true {
            let request = try makeRequest(
                baseURL: baseURL,
                token: token,
                method: "GET",
                pathComponents: ["rest", "agile", "1.0", "board"],
                queryItems: [
                    URLQueryItem(name: "startAt", value: String(startAt)),
                    URLQueryItem(name: "maxResults", value: String(maxResults))
                ]
            )
            let response: BoardsResponse = try await decodedResponse(for: request)
            boards.append(contentsOf: response.values.map {
                JiraBoard(id: String($0.id), name: $0.name, type: $0.type)
            })

            let nextStart = startAt + response.values.count
            let reachedTotal = response.total.map { nextStart >= $0 } ?? false
            if response.values.isEmpty || response.isLast == true || reachedTotal {
                break
            }
            startAt = nextStart
        }

        var seen: Set<String> = []
        return boards.filter { seen.insert($0.id).inserted }
    }

    func boardIssues(
        baseURL: URL,
        token: String,
        boardID: String
    ) async throws -> JiraSearchPage {
        var startAt = 0
        let maxResults = 100
        var issues: [JiraIssue] = []
        var total = 0

        while true {
            let request = try makeRequest(
                baseURL: baseURL,
                token: token,
                method: "GET",
                pathComponents: ["rest", "agile", "1.0", "board", boardID, "issue"],
                queryItems: [
                    URLQueryItem(name: "startAt", value: String(startAt)),
                    URLQueryItem(name: "maxResults", value: String(maxResults)),
                    URLQueryItem(name: "fields", value: Self.issueFields.joined(separator: ","))
                ]
            )
            let response: SearchResponse = try await decodedResponse(for: request)
            let page = try response.issues.map(Self.makeIssue)
            issues.append(contentsOf: page)
            total = response.total
            startAt += page.count
            if page.isEmpty || startAt >= response.total { break }
        }

        return JiraSearchPage(issues: Self.uniqueIssues(issues), total: total)
    }

    func projectIssues(
        baseURL: URL,
        token: String,
        projectKey: String
    ) async throws -> JiraSearchPage {
        let escaped = Self.escapedJQLString(projectKey)
        let jql = "project = \"\(escaped)\" ORDER BY priority DESC, updated DESC"
        var startAt = 0
        let maxResults = 100
        var issues: [JiraIssue] = []
        var total = 0

        while true {
            let response = try await searchPage(
                baseURL: baseURL,
                token: token,
                jql: jql,
                startAt: startAt,
                maxResults: maxResults
            )
            let page = try response.issues.map(Self.makeIssue)
            issues.append(contentsOf: page)
            total = response.total
            startAt += page.count
            if page.isEmpty || startAt >= response.total { break }
        }

        return JiraSearchPage(issues: Self.uniqueIssues(issues), total: total)
    }

    func issue(baseURL: URL, token: String, issueKey: String) async throws -> JiraIssue {
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "GET",
            pathComponents: ["rest", "api", "2", "issue", issueKey],
            queryItems: [
                URLQueryItem(name: "fields", value: Self.issueFields.joined(separator: ","))
            ]
        )
        let response: IssueResponse = try await decodedResponse(for: request)
        return try Self.makeIssue(response)
    }

    func transitions(
        baseURL: URL,
        token: String,
        issueKey: String
    ) async throws -> [JiraTransition] {
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "GET",
            pathComponents: ["rest", "api", "2", "issue", issueKey, "transitions"]
        )
        let response: TransitionsResponse = try await decodedResponse(for: request)
        return response.transitions.map {
            JiraTransition(
                id: $0.id,
                name: $0.name,
                toStatus: Self.makeStatus($0.to)
            )
        }
    }

    func performTransition(
        baseURL: URL,
        token: String,
        issueKey: String,
        transitionID: String
    ) async throws {
        let body = TransitionRequest(transition: .init(id: transitionID))
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "POST",
            pathComponents: ["rest", "api", "2", "issue", issueKey, "transitions"],
            body: try JSONEncoder().encode(body)
        )
        _ = try await successfulData(for: request)
    }

    func addWorklog(
        baseURL: URL,
        token: String,
        issueKey: String,
        timeSpentSeconds: Int,
        comment: String
    ) async throws {
        let body = WorklogRequest(
            timeSpentSeconds: timeSpentSeconds,
            comment: comment
        )
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "POST",
            pathComponents: ["rest", "api", "2", "issue", issueKey, "worklog"],
            queryItems: [URLQueryItem(name: "adjustEstimate", value: "leave")],
            body: try JSONEncoder().encode(body)
        )
        _ = try await successfulData(for: request)
    }

    private func makeRequest(
        baseURL: URL,
        token: String,
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try endpointURL(
                baseURL: baseURL,
                pathComponents: pathComponents,
                queryItems: queryItems
            )
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func endpointURL(
        baseURL: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem]? = nil
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw JiraAPIError.invalidBaseURL
        }

        var encodedPath = components.percentEncodedPath
        while encodedPath.count > 1 && encodedPath.hasSuffix("/") {
            encodedPath.removeLast()
        }
        for component in pathComponents {
            guard let encodedComponent = component.addingPercentEncoding(
                withAllowedCharacters: Self.pathSegmentAllowedCharacters
            ) else {
                throw JiraAPIError.invalidBaseURL
            }
            if !encodedPath.hasSuffix("/") { encodedPath += "/" }
            encodedPath += encodedComponent
        }
        components.percentEncodedPath = encodedPath
        components.queryItems = queryItems
        components.fragment = nil

        guard let url = components.url else { throw JiraAPIError.invalidBaseURL }
        return url
    }

    private func decodedResponse<Response: Decodable>(for request: URLRequest) async throws -> Response {
        let data = try await successfulData(for: request)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw JiraAPIError.decoding
        }
    }

    private func searchPage(
        baseURL: URL,
        token: String,
        jql: String,
        startAt: Int,
        maxResults: Int
    ) async throws -> SearchResponse {
        let body = SearchRequest(
            jql: jql,
            startAt: startAt,
            maxResults: maxResults,
            fields: Self.issueFields
        )
        let request = try makeRequest(
            baseURL: baseURL,
            token: token,
            method: "POST",
            pathComponents: ["rest", "api", "2", "search"],
            body: try JSONEncoder().encode(body)
        )
        return try await decodedResponse(for: request)
    }

    private func successfulData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                throw JiraAPIError.unauthorized
            case 403:
                throw JiraAPIError.forbidden
            case 429:
                throw JiraAPIError.rateLimited
            case 500..<600:
                throw JiraAPIError.server(response.statusCode)
            default:
                throw JiraAPIError.http(response.statusCode)
            }
        } catch let error as JiraAPIError {
            throw error
        } catch {
            throw JiraAPIError.network
        }
    }

    private static func searchJQL(projectKeys: Set<String>) -> String {
        var clauses = [
            "assignee = currentUser()",
            "resolution IS EMPTY",
            "statusCategory != Done"
        ]
        if !projectKeys.isEmpty {
            let keys = projectKeys.sorted().map { "\"\(escapedJQLString($0))\"" }
            clauses.append("project IN (\(keys.joined(separator: ", ")))")
        }
        return clauses.joined(separator: " AND ") + " ORDER BY priority DESC, updated DESC"
    }

    private static func escapedJQLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func uniqueIssues(_ issues: [JiraIssue]) -> [JiraIssue] {
        var seen: Set<String> = []
        return issues.filter { seen.insert($0.key).inserted }
    }

    private static let issueFields = [
        "key", "summary", "project", "status", "priority", "duedate", "updated"
    ]

    private static func makeIssue(_ response: IssueResponse) throws -> JiraIssue {
        try JiraIssue(
            id: response.id,
            key: response.key,
            summary: response.fields.summary,
            projectKey: response.fields.project.key,
            projectName: response.fields.project.name,
            status: makeStatus(response.fields.status),
            priorityName: response.fields.priority?.name,
            dueDate: response.fields.dueDate.map { try parseDueDate($0) },
            updatedAt: response.fields.updated.map { try parseUpdatedDate($0) }
        )
    }

    private static func makeStatus(_ response: StatusResponse) -> JiraStatus {
        JiraStatus(
            id: response.id,
            name: response.name,
            categoryKey: response.statusCategory.key
        )
    }

    private static func parseDueDate(_ value: String) throws -> Date {
        guard let date = dueDateFormatter.date(from: value) else {
            throw JiraAPIError.decoding
        }
        return date
    }

    private static func parseUpdatedDate(_ value: String) throws -> Date {
        guard let date = iso8601WithFractionalSeconds.date(from: value)
            ?? iso8601.date(from: value) else {
            throw JiraAPIError.decoding
        }
        return date
    }

    private static let pathSegmentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}

private struct UserResponse: Decodable {
    let displayName: String
}

private struct ProjectResponse: Decodable {
    let id: String
    let key: String
    let name: String
}

private struct SearchRequest: Encodable {
    let jql: String
    let startAt: Int
    let maxResults: Int
    let fields: [String]
}

private struct BoardsResponse: Decodable {
    let values: [BoardResponse]
    let total: Int?
    let isLast: Bool?
}

private struct BoardResponse: Decodable {
    let id: Int
    let name: String
    let type: String
}

private struct SearchResponse: Decodable {
    let issues: [IssueResponse]
    let total: Int
}

private struct IssueResponse: Decodable {
    let id: String
    let key: String
    let fields: IssueFieldsResponse
}

private struct IssueFieldsResponse: Decodable {
    let summary: String
    let project: ProjectResponse
    let status: StatusResponse
    let priority: PriorityResponse?
    let dueDate: String?
    let updated: String?

    private enum CodingKeys: String, CodingKey {
        case summary
        case project
        case status
        case priority
        case dueDate = "duedate"
        case updated
    }
}

private struct PriorityResponse: Decodable {
    let name: String
}

private struct StatusResponse: Decodable {
    let id: String
    let name: String
    let statusCategory: StatusCategoryResponse
}

private struct StatusCategoryResponse: Decodable {
    let key: String
}

private struct TransitionsResponse: Decodable {
    let transitions: [TransitionResponse]
}

private struct TransitionResponse: Decodable {
    let id: String
    let name: String
    let to: StatusResponse
}

private struct TransitionRequest: Encodable {
    struct Selection: Encodable {
        let id: String
    }

    let transition: Selection
}

private struct WorklogRequest: Encodable {
    let timeSpentSeconds: Int
    let comment: String
}
