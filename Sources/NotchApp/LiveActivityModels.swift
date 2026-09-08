import Foundation

enum LiveActivityKind: String, CaseIterable, Sendable {
    case call
    case timer
    case download
    case delivery
    case headphones
    case battery

    var priority: Int {
        switch self {
        case .call: 600
        case .timer: 500
        case .download: 400
        case .delivery: 300
        case .headphones: 200
        case .battery: 100
        }
    }

    var iconName: String {
        switch self {
        case .call: "phone.fill"
        case .timer: "timer"
        case .download: "arrow.down.circle.fill"
        case .delivery: "shippingbox.fill"
        case .headphones: "airpodspro"
        case .battery: "battery.100percent"
        }
    }
}

enum LiveActivityState: Equatable, Sendable {
    case active
    case paused
    case completed
    case notification
}

struct LiveActivity: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let kind: LiveActivityKind
    let title: String
    let detail: String?
    let state: LiveActivityState
    let progress: Double?
    let startedAt: Date?
    let endsAt: Date?
    let updatedAt: Date
    let isCompactEligible: Bool

    func remainingDuration(at date: Date) -> TimeInterval? {
        guard let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(date))
    }

    func showsNotificationMascot(at date: Date) -> Bool {
        guard isCompactEligible,
              kind != .timer,
              kind != .battery else { return false }
        return date.timeIntervalSince(updatedAt) >= 0
            && date.timeIntervalSince(updatedAt) < 12
    }
}

enum CompactMascotNotice: Equatable, Identifiable, Sendable {
    case agent(CompactAgentSignal)
    case live(LiveActivity)

    var id: String {
        switch self {
        case .agent(let signal):
            "agent:\(signal.sessionID.sourceID):\(signal.sessionID.sessionID):\(signal.kind.rawValue)"
        case .live(let activity):
            "live:\(activity.id):\(activity.updatedAt.timeIntervalSince1970)"
        }
    }
}

enum LiveActivityClock {
    static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum LiveActivityFeed {
    static func primaryCompactActivity(in activities: [LiveActivity]) -> LiveActivity? {
        activities
            .filter { $0.isCompactEligible && $0.state != .completed }
            .sorted {
                if $0.kind.priority != $1.kind.priority {
                    return $0.kind.priority > $1.kind.priority
                }
                return $0.updatedAt > $1.updatedAt
            }
            .first
    }
}

@MainActor
protocol LiveActivitySource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var onChange: (([LiveActivity]) -> Void)? { get set }
    func start()
    func stop()
}
