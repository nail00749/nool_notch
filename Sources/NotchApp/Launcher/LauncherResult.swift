import Foundation

enum LauncherCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case applications
    case files
    case clipboard
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .applications: "Приложения"
        case .files: "Файлы"
        case .clipboard: "Буфер обмена"
        case .ai: "AI"
        }
    }
}

struct LauncherResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let payload: LauncherPayload
}

enum LauncherPayload: Hashable, Sendable {
    case application(URL)
    case file(URL)
    case clipboard(UUID)
    case calculation(String)
    case nool(id: String, kind: LauncherNoolKind)
}

enum LauncherNoolKind: String, Hashable, Sendable {
    case jira, session, event
    var title: String {
        switch self { case .jira: "Jira"; case .session: "AI-сессия"; case .event: "Встреча" }
    }
    var symbol: String {
        switch self { case .jira: "checkmark.square"; case .session: "sparkles"; case .event: "calendar" }
    }
}

extension LauncherResult {
    init(nool result: UnifiedSearchResult) {
        let kind: LauncherNoolKind
        switch result { case .issue: kind = .jira; case .session: kind = .session; case .event: kind = .event }
        self.init(id: "nool:\(result.id)", title: result.title, subtitle: result.subtitle,
                  payload: .nool(id: result.id, kind: kind))
    }
}
