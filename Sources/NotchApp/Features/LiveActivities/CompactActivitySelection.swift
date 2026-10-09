import Foundation

enum CompactActivityPage: Hashable, Identifiable {
    case meeting
    case timer
    case music
    case live(String)

    var id: String {
        switch self {
        case .meeting: "meeting"
        case .timer: "timer"
        case .music: "music"
        case .live(let activityID): "live:\(activityID)"
        }
    }
}

enum CompactActivitySelection {
    static func pages(
        hasMeeting: Bool,
        hasTimer: Bool,
        activities: [LiveActivity],
        hasMusic: Bool,
        nativeTimerSourceID: String
    ) -> [CompactActivityPage] {
        var result: [CompactActivityPage] = []
        if hasMeeting { result.append(.meeting) }
        if hasTimer { result.append(.timer) }

        result += activities
            .filter { activity in
                activity.isCompactEligible
                    && activity.state != .completed
                    && activity.state != .notification
                    && activity.sourceID != nativeTimerSourceID
            }
            .sorted {
                if $0.kind.priority != $1.kind.priority {
                    return $0.kind.priority > $1.kind.priority
                }
                return $0.id < $1.id
            }
            .map { .live($0.id) }

        if hasMusic { result.append(.music) }
        return result
    }

    static func selectedID(_ selectedID: String?, from pages: [CompactActivityPage]) -> String? {
        guard let selectedID, pages.contains(where: { $0.id == selectedID }) else {
            return pages.first?.id
        }
        return selectedID
    }

    static func cycledID(
        from selectedID: String?,
        pages: [CompactActivityPage],
        forward: Bool
    ) -> String? {
        guard pages.count > 1 else { return selectedID }
        let currentID = self.selectedID(selectedID, from: pages)
        guard let currentIndex = pages.firstIndex(where: { $0.id == currentID }) else { return nil }
        let nextIndex = forward
            ? (currentIndex + 1) % pages.count
            : (currentIndex - 1 + pages.count) % pages.count
        return pages[nextIndex].id
    }
}
