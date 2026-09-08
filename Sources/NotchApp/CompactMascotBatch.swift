import Foundation

struct CompactMascotPresentation: Equatable {
    let id: UUID
    let expiresAt: Date
    var notice: CompactMascotNotice
}

struct CompactMascotBatch {
    private(set) var presentation: CompactMascotPresentation?
    private var lastSeenEvents: [String: Date] = [:]

    mutating func update(_ candidates: [CompactMascotNotice], at now: Date) {
        let eventIDs = Set(candidates.map(\.batchEventID))
        // Retain identities through brief source gaps without keeping event bodies.
        lastSeenEvents = lastSeenEvents.filter { now.timeIntervalSince($0.value) < 60 }
        let hasNewEvents = eventIDs.contains { lastSeenEvents[$0] == nil }
        for id in eventIDs { lastSeenEvents[id] = now }

        if let current = presentation, now >= current.expiresAt {
            presentation = nil
        }
        guard let best = candidates.sorted(by: {
            if $0.batchPriority != $1.batchPriority {
                return $0.batchPriority > $1.batchPriority
            }
            if $0.batchObservedAt != $1.batchObservedAt {
                return $0.batchObservedAt > $1.batchObservedAt
            }
            return $0.batchEventID < $1.batchEventID
        }).first else {
            presentation = nil
            return
        }

        if presentation != nil {
            presentation?.notice = best
        } else if hasNewEvents {
            presentation = CompactMascotPresentation(
                id: UUID(), expiresAt: now.addingTimeInterval(12), notice: best
            )
        }
    }
}

private extension CompactMascotNotice {
    var batchObservedAt: Date {
        switch self {
        case .agent(let signal): signal.observedAt
        case .live(let activity): activity.updatedAt
        }
    }

    var batchEventID: String {
        switch self {
        case .agent: "\(id):\(batchObservedAt.timeIntervalSince1970)"
        case .live(let activity): "\(activity.sourceID):\(id)"
        }
    }

    var batchPriority: Int {
        switch self {
        case .agent(let signal):
            switch signal.kind {
            case .waitingForApproval: 1_000
            case .waitingForInput: 900
            case .failed: 800
            case .completed: 50
            }
        case .live(let activity): activity.kind.priority
        }
    }
}
