import Foundation

struct AISessionActivityTracker {
    private struct State {
        var accumulatedDuration: TimeInterval
        var activeSince: Date?
        var hasObservedActivity: Bool
    }

    private var states: [AISessionID: State] = [:]

    mutating func update(
        sessions: [AISession],
        sourceHealth: [String: AISessionSourceHealth],
        at date: Date
    ) -> [AISession] {
        let currentIDs = Set(sessions.map(\.id))
        states = states.filter { currentIDs.contains($0.key) }

        return sessions.map { session in
            let shouldCount = session.status == .running
                && session.isStale == false
                && isLive(sourceHealth[session.id.sourceID])
            var state = states[session.id] ?? State(
                accumulatedDuration: session.accumulatedActiveDuration ?? 0,
                activeSince: shouldCount ? date : nil,
                hasObservedActivity: session.accumulatedActiveDuration != nil || shouldCount
            )

            if shouldCount {
                state.hasObservedActivity = true
                if state.activeSince == nil {
                    state.activeSince = date
                }
            } else if let activeSince = state.activeSince {
                state.accumulatedDuration += max(0, date.timeIntervalSince(activeSince))
                state.activeSince = nil
            }

            states[session.id] = state
            return session.withActivityTiming(
                accumulatedDuration: state.hasObservedActivity
                    ? state.accumulatedDuration
                    : nil,
                activeSince: state.activeSince
            )
        }
    }

    private func isLive(_ health: AISessionSourceHealth?) -> Bool {
        if case .live = health { return true }
        return false
    }
}
