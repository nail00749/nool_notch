import Foundation

struct JiraBoard: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
}

struct JiraPinnedContainer: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case project
        case board
    }

    let kind: Kind
    let reference: String
    let name: String
    let detail: String

    var id: String { "\(kind.rawValue):\(reference)" }

    static func project(_ project: JiraProject) -> JiraPinnedContainer {
        JiraPinnedContainer(
            kind: .project,
            reference: project.key,
            name: project.name,
            detail: project.key
        )
    }

    static func board(_ board: JiraBoard) -> JiraPinnedContainer {
        JiraPinnedContainer(
            kind: .board,
            reference: board.id,
            name: board.name,
            detail: board.type.capitalized
        )
    }
}

struct JiraPinnedIssue: Identifiable, Codable, Hashable, Sendable {
    let key: String
    let summary: String

    var id: String { key }
}

enum JiraPinnedSourceID: Hashable, Sendable, Identifiable {
    case issues
    case container(String)

    var id: String {
        switch self {
        case .issues:
            "issues"
        case .container(let id):
            id
        }
    }
}

enum JiraPinnedCatalogState: Equatable, Sendable {
    case idle
    case loading(previousProjects: [JiraProject], previousBoards: [JiraBoard])
    case loaded(projects: [JiraProject], boards: [JiraBoard])
    case failed(error: JiraAPIError, previousProjects: [JiraProject], previousBoards: [JiraBoard])

    var projects: [JiraProject] {
        switch self {
        case .idle:
            []
        case .loading(let projects, _), .loaded(let projects, _), .failed(_, let projects, _):
            projects
        }
    }

    var boards: [JiraBoard] {
        switch self {
        case .idle:
            []
        case .loading(_, let boards), .loaded(_, let boards), .failed(_, _, let boards):
            boards
        }
    }
}

enum JiraPinnedSourceLoadState: Equatable, Sendable {
    case idle
    case loading(previous: [JiraIssue]?)
    case loaded(issues: [JiraIssue], total: Int)
    case failed(error: JiraAPIError, previous: [JiraIssue]?)

    var issues: [JiraIssue] {
        switch self {
        case .idle:
            []
        case .loading(let previous), .failed(_, let previous):
            previous ?? []
        case .loaded(let issues, _):
            issues
        }
    }
}

struct JiraPinnedState: Equatable, Sendable {
    var catalog: JiraPinnedCatalogState = .idle
    var containers: [JiraPinnedContainer] = []
    var issues: [JiraPinnedIssue] = []
    var selectedSource: JiraPinnedSourceID?
    var sourceStates: [JiraPinnedSourceID: JiraPinnedSourceLoadState] = [:]
    var pinIssueError: JiraAPIError?
    var isPinningIssue = false

    var availableSources: [JiraPinnedSourceID] {
        (issues.isEmpty ? [] : [.issues]) + containers.map { .container($0.id) }
    }
}
