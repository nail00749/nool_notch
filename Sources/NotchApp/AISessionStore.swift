import Combine
import Foundation

@MainActor
final class AISessionStore: ObservableObject {
    @Published private(set) var sessions: [AISession] = []
    @Published private(set) var sourceHealth: [String: AISessionSourceHealth] = [:]
    @Published private(set) var lastUpdatedAt: Date?

    private let sources: [String: any AISessionSource]
    private var snapshotsBySource: [String: AISessionSourceSnapshot] = [:]
    private var sourceTasks: [String: Task<Void, Never>] = [:]

    init(sources: [any AISessionSource]) {
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    var attentionCount: Int {
        sessions.filter { $0.status.needsAttention }.count
    }

    func start() {
        for source in sources.values where sourceTasks[source.id] == nil {
            let stream = source.snapshots()
            sourceTasks[source.id] = Task { @MainActor [weak self] in
                for await snapshot in stream {
                    guard Task.isCancelled == false else { return }
                    self?.apply(snapshot)
                }
            }
        }
    }

    func stop() {
        sourceTasks.values.forEach { $0.cancel() }
        sourceTasks.removeAll()
    }

    func open(_ session: AISession) async -> Bool {
        guard let source = sources[session.id.sourceID] else { return false }
        return await source.open(sessionID: session.id.sessionID)
    }

    private func apply(_ snapshot: AISessionSourceSnapshot) {
        guard sources[snapshot.sourceID] != nil else { return }
        snapshotsBySource[snapshot.sourceID] = snapshot
        sourceHealth[snapshot.sourceID] = snapshot.health
        lastUpdatedAt = snapshotsBySource.values.map(\.updatedAt).max()
        sessions = Self.presentationSessions(
            snapshotsBySource.values.flatMap(\.sessions)
        )
    }

    static func presentationSessions(
        _ sessions: [AISession],
        inactiveLimit: Int = 10
    ) -> [AISession] {
        let deduplicated = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { current, candidate in
            candidate.lastActivity > current.lastActivity ? candidate : current
        }).values

        let sorted = deduplicated.sorted { lhs, rhs in
            let leftPriority = statusPriority(lhs.status)
            let rightPriority = statusPriority(rhs.status)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return lhs.lastActivity > rhs.lastActivity
        }

        let active = sorted.filter { $0.status.isActive }
        let inactive = sorted.filter { $0.status.isActive == false }
        return active + inactive.prefix(max(0, inactiveLimit))
    }

    private static func statusPriority(_ status: AISessionStatus) -> Int {
        switch status {
        case .waitingForApproval: 0
        case .waitingForInput: 1
        case .running: 2
        case .failed: 3
        case .completed: 4
        case .unknown: 5
        }
    }
}
