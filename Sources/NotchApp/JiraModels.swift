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
    let assignee: JiraAssignee?

    init(
        id: String,
        key: String,
        summary: String,
        projectKey: String,
        projectName: String,
        status: JiraStatus,
        priorityName: String?,
        dueDate: Date?,
        updatedAt: Date?,
        assignee: JiraAssignee? = nil
    ) {
        self.id = id
        self.key = key
        self.summary = summary
        self.projectKey = projectKey
        self.projectName = projectName
        self.status = status
        self.priorityName = priorityName
        self.dueDate = dueDate
        self.updatedAt = updatedAt
        self.assignee = assignee
    }

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

struct JiraStatusSelectionPresentation: Equatable, Sendable {
    let currentStatus: JiraStatus
    let availableTransitions: [JiraTransition]

    init(currentStatus: JiraStatus, transitions: [JiraTransition]) {
        self.currentStatus = currentStatus
        availableTransitions = transitions.filter { $0.toStatus.id != currentStatus.id }
    }
}

struct JiraUser: Equatable, Sendable {
    let username: String?
    let displayName: String

    init(username: String? = nil, displayName: String) {
        self.username = username
        self.displayName = displayName
    }
}

struct JiraAssignee: Identifiable, Equatable, Sendable {
    let username: String
    let displayName: String

    var id: String { username }
}

enum JiraAssigneeSelection: Equatable, Sendable {
    case currentUser
    case user(JiraAssignee)
    case unassigned
}

struct JiraSearchPage: Equatable, Sendable {
    let issues: [JiraIssue]
    let total: Int
}

struct JiraWorklogDraft: Equatable, Sendable {
    static let hourRange = 0...24
    static let minuteRange = 0...59

    let hours: Int
    let minutes: Int
    let description: String

    var timeSpentSeconds: Int? {
        guard Self.hourRange.contains(hours),
              Self.minuteRange.contains(minutes) else { return nil }
        let seconds = (hours * 60 + minutes) * 60
        return seconds > 0 ? seconds : nil
    }

    var normalizedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        timeSpentSeconds != nil && !normalizedDescription.isEmpty
    }
}

enum JiraWorklogDurationOptions {
    static let hourValues = Array(JiraWorklogDraft.hourRange)
    static let minuteValues = Array(stride(from: 0, through: 55, by: 5))
}

enum JiraAPIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidWorklog
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

enum JiraAssigneeState: Equatable, Sendable {
    case idle
    case loading(previous: [JiraAssignee]?)
    case loaded([JiraAssignee])
    case submitting([JiraAssignee])
    case failed(error: JiraAPIError, previous: [JiraAssignee]?)
}

struct JiraProviderState: Equatable, Sendable {
    var connection: JiraConnectionState
    var projects: [JiraProject]
    var selectedProjectKeys: Set<String>
    var list: JiraListState
    var transitionsByIssueKey: [String: JiraTransitionState]
    var assigneesByIssueKey: [String: JiraAssigneeState]
    var pinned: JiraPinnedState

    init(
        connection: JiraConnectionState = .notConfigured,
        projects: [JiraProject] = [],
        selectedProjectKeys: Set<String> = [],
        list: JiraListState = .idle,
        transitionsByIssueKey: [String: JiraTransitionState] = [:],
        assigneesByIssueKey: [String: JiraAssigneeState] = [:],
        pinned: JiraPinnedState = JiraPinnedState()
    ) {
        self.connection = connection
        self.projects = projects
        self.selectedProjectKeys = selectedProjectKeys
        self.list = list
        self.transitionsByIssueKey = transitionsByIssueKey
        self.assigneesByIssueKey = assigneesByIssueKey
        self.pinned = pinned
    }
}
