import Foundation

struct JiraProject: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let name: String
}

struct JiraStatus: Equatable, Sendable {
    let id: String
    let name: String
    let categoryKey: String
}

struct JiraIssue: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let summary: String
    let projectKey: String
    let projectName: String
    let status: JiraStatus
    let priorityName: String?
    let dueDate: Date?
    let updatedAt: Date?

    func browserURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL),
              components.scheme != nil,
              components.host != nil else { return nil }

        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([prefix, "browse", key]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        return components.url
    }
}

struct JiraTransition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let toStatus: JiraStatus
}

struct JiraUser: Equatable, Sendable {
    let displayName: String
}

struct JiraSearchPage: Equatable, Sendable {
    let issues: [JiraIssue]
    let total: Int
}

enum JiraAPIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case notConfigured
    case unauthorized
    case forbidden
    case rateLimited
    case server(Int)
    case http(Int)
    case invalidResponse
    case decoding
    case network
}

enum JiraConnectionState: Equatable, Sendable {
    case notConfigured
    case ready
    case validating
    case validated(JiraUser)
    case connected(JiraUser)
    case failed(JiraAPIError)
}

enum JiraListState: Equatable, Sendable {
    case idle
    case loading(previous: [JiraIssue]?)
    case loaded(issues: [JiraIssue], total: Int)
    case failed(error: JiraAPIError, previous: [JiraIssue]?)
}

enum JiraTransitionState: Equatable, Sendable {
    case idle
    case loading
    case loaded([JiraTransition])
    case submitting([JiraTransition])
    case failed(error: JiraAPIError, previous: [JiraTransition]?)
}

struct JiraProviderState: Equatable, Sendable {
    var connection: JiraConnectionState
    var projects: [JiraProject]
    var selectedProjectKeys: Set<String>
    var list: JiraListState
    var transitionsByIssueKey: [String: JiraTransitionState]

    init(
        connection: JiraConnectionState = .notConfigured,
        projects: [JiraProject] = [],
        selectedProjectKeys: Set<String> = [],
        list: JiraListState = .idle,
        transitionsByIssueKey: [String: JiraTransitionState] = [:]
    ) {
        self.connection = connection
        self.projects = projects
        self.selectedProjectKeys = selectedProjectKeys
        self.list = list
        self.transitionsByIssueKey = transitionsByIssueKey
    }
}
