import Foundation

enum NotchUtilityPanel: Equatable {
    case files
    case search

    var title: String { self == .files ? "Файлы" : "Поиск" }
}

enum UnifiedSearchResult: Identifiable, Equatable {
    case issue(JiraIssue)
    case session(AISession)
    case event(CalendarEvent)

    var id: String {
        switch self {
        case .issue(let issue): "jira:\(issue.key)"
        case .session(let session): "ai:\(session.id.sourceID):\(session.id.sessionID)"
        case .event(let event): "calendar:\(event.id)"
        }
    }

    var title: String {
        switch self {
        case .issue(let issue): "\(issue.key) · \(issue.summary)"
        case .session(let session): session.title
        case .event(let event): event.title
        }
    }

    var subtitle: String {
        switch self {
        case .issue(let issue): "Jira · \(issue.status.name) · \(issue.projectName)"
        case .session(let session): "AI · \(session.agentName) · \(session.workspaceName ?? "Без проекта")"
        case .event(let event): "Календарь · \(event.startDate.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)"
        }
    }

    var iconName: String {
        switch self {
        case .issue: "checkmark.square"
        case .session: "sparkles"
        case .event: "calendar"
        }
    }

    var searchText: String {
        switch self {
        case .issue(let issue): "\(title) \(issue.projectName) \(issue.projectKey) \(issue.status.name)"
        case .session(let session): "\(title) \(session.agentName) \(session.workspacePath ?? "") \(session.modelName ?? "")"
        case .event(let event): "\(title) \(event.calendarTitle)"
        }
    }
}

enum UnifiedSearch {
    static func results(
        query: String, issues: [JiraIssue], sessions: [AISession], events: [CalendarEvent]
    ) -> [UnifiedSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.isEmpty == false else { return [] }
        let candidates = issues.map(UnifiedSearchResult.issue)
            + sessions.map(UnifiedSearchResult.session)
            + events.map(UnifiedSearchResult.event)
        var seen: Set<String> = []
        return candidates.filter { result in
            words.allSatisfy { result.searchText.localizedStandardContains($0) }
                && seen.insert(result.id).inserted
        }.sorted { lhs, rhs in
            let leftTitleMatch = words.allSatisfy { lhs.title.localizedStandardContains($0) }
            let rightTitleMatch = words.allSatisfy { rhs.title.localizedStandardContains($0) }
            if leftTitleMatch != rightTitleMatch { return leftTitleMatch }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
