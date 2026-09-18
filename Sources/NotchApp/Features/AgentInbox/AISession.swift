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

enum AISessionAttentionKind: Equatable, Sendable {
    case approval
    case input
}

struct AISessionQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String
    let options: [String]
    let allowsFreeform: Bool
}

struct AISessionAttentionRequest: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AISessionAttentionKind
    let title: String
    let detail: String?
    let context: String?
    let supportsSessionApproval: Bool
    let questions: [AISessionQuestion]
}

enum AISessionResponse: Equatable, Sendable {
    case approveOnce
    case approveForSession
    case deny
    case answers([String: String])
}

struct AISession: Identifiable, Equatable, Sendable {
    let id: AISessionID
    let agentName: String
    let title: String
    let workspacePath: String?
    let modelName: String?
    let status: AISessionStatus
    let startedAt: Date?
    let accumulatedActiveDuration: TimeInterval?
    let activeSince: Date?
    let lastActivity: Date
    let isStale: Bool
    let attentionRequest: AISessionAttentionRequest?

    init(
        id: AISessionID,
        agentName: String,
        title: String,
        workspacePath: String?,
        modelName: String?,
        status: AISessionStatus,
        startedAt: Date? = nil,
        accumulatedActiveDuration: TimeInterval? = nil,
        activeSince: Date? = nil,
        lastActivity: Date,
        isStale: Bool,
        attentionRequest: AISessionAttentionRequest? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.title = title
        self.workspacePath = workspacePath
        self.modelName = modelName
        self.status = status
        self.startedAt = startedAt
        self.accumulatedActiveDuration = accumulatedActiveDuration
        self.activeSince = activeSince
        self.lastActivity = lastActivity
        self.isStale = isStale
        self.attentionRequest = attentionRequest
    }

    var workspaceName: String? {
        guard let workspacePath, workspacePath.isEmpty == false else { return nil }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    func activeDuration(at date: Date = .now) -> TimeInterval? {
        guard let accumulatedActiveDuration else { return nil }
        guard status == .running, let activeSince else {
            return accumulatedActiveDuration
        }
        return accumulatedActiveDuration + max(0, date.timeIntervalSince(activeSince))
    }

    func withActivityTiming(
        accumulatedDuration: TimeInterval?,
        activeSince: Date?
    ) -> AISession {
        AISession(
            id: id,
            agentName: agentName,
            title: title,
            workspacePath: workspacePath,
            modelName: modelName,
            status: status,
            startedAt: startedAt,
            accumulatedActiveDuration: accumulatedDuration,
            activeSince: activeSince,
            lastActivity: lastActivity,
            isStale: isStale,
            attentionRequest: attentionRequest
        )
    }
}

struct AISessionSourceSnapshot: Equatable, Sendable {
    let sourceID: String
    let sessions: [AISession]
    let health: AISessionSourceHealth
    let updatedAt: Date
}
