import Foundation

enum CompactAgentSignalKind: Int, Hashable, Sendable {
    case waitingForApproval
    case waitingForInput
    case failed
    case completed

    var priority: Int { rawValue }
}

struct CompactAgentSignal: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let sessionID: AISessionID
        let kind: CompactAgentSignalKind
    }

    let sessionID: AISessionID
    let kind: CompactAgentSignalKind
    let observedAt: Date

    var id: ID { ID(sessionID: sessionID, kind: kind) }
}

@MainActor
final class CompactAgentSignalController {
    private struct SessionState {
        let status: AISessionStatus
        let lastActivity: Date
        let isFresh: Bool
    }

    var onChange: ((CompactAgentSignal?) -> Void)?

    private var hasSeeded = false
    private var knownStatuses: [AISessionID: AISessionStatus] = [:]
    private var currentSessions: [AISessionID: SessionState] = [:]
    private var terminalSignals: [CompactAgentSignal.ID: CompactAgentSignal] = [:]
    private var completionTasks: [AISessionID: Task<Void, Never>] = [:]
    private var currentSignal: CompactAgentSignal?

    func consume(_ sessions: [AISession], hasReceivedSnapshot: Bool) {
        guard hasReceivedSnapshot else { return }
        let incoming = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let incomingStates = incoming.mapValues {
            SessionState(
                status: $0.status,
                lastActivity: $0.lastActivity,
                isFresh: !$0.isStale
            )
        }

        if hasSeeded == false {
            hasSeeded = true
            knownStatuses = incoming.reduce(into: [:]) { statuses, entry in
                guard entry.value.isStale == false else { return }
                statuses[entry.key] = entry.value.status
            }
            currentSessions = incomingStates
            publishBestSignal()
            return
        }

        knownStatuses = knownStatuses.filter { incoming[$0.key] != nil }
        for session in sessions {
            guard session.isStale == false else { continue }
            let previous = knownStatuses[session.id]
            if session.status == .completed, previous?.isActive == true {
                publishCompletion(for: session)
            } else if session.status == .failed,
                      previous != nil,
                      previous != .failed {
                let signal = CompactAgentSignal(
                    sessionID: session.id,
                    kind: .failed,
                    observedAt: .now
                )
                terminalSignals[signal.id] = signal
            }
            knownStatuses[session.id] = session.status
        }

        currentSessions = incomingStates
        publishBestSignal()
    }

    func acknowledge(_ signal: CompactAgentSignal) {
        guard signal.kind == .failed,
              terminalSignals[signal.id] == signal else { return }
        terminalSignals[signal.id] = nil
        publishBestSignal()
    }

    private func waitingSignal(for id: AISessionID, state: SessionState) -> CompactAgentSignal? {
        guard state.isFresh else { return nil }
        let kind: CompactAgentSignalKind
        switch state.status {
        case .waitingForApproval:
            kind = .waitingForApproval
        case .waitingForInput:
            kind = .waitingForInput
        default:
            return nil
        }
        return CompactAgentSignal(
            sessionID: id,
            kind: kind,
            observedAt: state.lastActivity
        )
    }

    private func publishBestSignal() {
        let candidates = currentSessions.compactMap { id, state in
            waitingSignal(for: id, state: state)
        }
            + Array(terminalSignals.values)
        let next = candidates.sorted {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            if $0.observedAt != $1.observedAt {
                return $0.observedAt > $1.observedAt
            }
            if $0.sessionID.sourceID != $1.sessionID.sourceID {
                return $0.sessionID.sourceID < $1.sessionID.sourceID
            }
            return $0.sessionID.sessionID < $1.sessionID.sessionID
        }.first
        guard next != currentSignal else { return }
        currentSignal = next
        onChange?(next)
    }

    private func publishCompletion(for session: AISession) {
        completionTasks[session.id]?.cancel()
        let signal = CompactAgentSignal(
            sessionID: session.id,
            kind: .completed,
            observedAt: .now
        )
        terminalSignals[signal.id] = signal
        completionTasks[session.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard Task.isCancelled == false,
                  self?.terminalSignals[signal.id] == signal else { return }
            self?.terminalSignals[signal.id] = nil
            self?.completionTasks[session.id] = nil
            self?.publishBestSignal()
        }
    }
}
