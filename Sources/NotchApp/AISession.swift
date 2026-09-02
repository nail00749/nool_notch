import Foundation

struct AISessionID: Hashable, Sendable {
    let sourceID: String
    let sessionID: String
}

enum AISessionStatus: String, Equatable, Sendable {
    case running
    case waitingForApproval
    case waitingForInput
    case completed
    case failed
    case unknown

    var isActive: Bool {
        switch self {
        case .running, .waitingForApproval, .waitingForInput:
            true
        case .completed, .failed, .unknown:
            false
        }
    }

    var needsAttention: Bool {
        self == .waitingForApproval || self == .waitingForInput
    }
}

enum AISessionSourceHealth: Equatable, Sendable {
    case live
    case stale(message: String?)
    case unavailable(message: String?)
}

struct AISession: Identifiable, Equatable, Sendable {
    let id: AISessionID
    let agentName: String
    let title: String
    let workspacePath: String?
    let modelName: String?
    let status: AISessionStatus
    let lastActivity: Date
    let isStale: Bool

    var workspaceName: String? {
        guard let workspacePath, workspacePath.isEmpty == false else { return nil }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }
}

struct AISessionSourceSnapshot: Equatable, Sendable {
    let sourceID: String
    let sessions: [AISession]
    let health: AISessionSourceHealth
    let updatedAt: Date
}
