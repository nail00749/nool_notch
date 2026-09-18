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
    case snippet(UUID)
    case calculation(String)
    case nool(id: String, kind: LauncherNoolKind)
    case windowAction(WindowLayoutAction)
    case windowLayout(UUID)
    case windowLayoutManager
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
    static func windowCommands(layouts: [SavedWindowLayout], query: String,
                               category: LauncherCategory) -> [LauncherResult] {
        guard category == .all, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return WindowLayoutAction.allCases.map { action in
            LauncherResult(id: "window:\(action.rawValue)", title: "Окно: \(action.title)",
                           subtitle: "Управление окнами · window \(action.rawValue)", payload: .windowAction(action))
        } + [LauncherResult(id: "window:manager", title: "Окна и раскладки",
                            subtitle: "Сохранить и восстановить расположение окон · layouts",
                            payload: .windowLayoutManager)]
          + layouts.map { layout in
              LauncherResult(id: "layout:\(layout.id)", title: "Раскладка: \(layout.name)",
                             subtitle: "Восстановить открытые окна · layout", payload: .windowLayout(layout.id))
          }
    }

    init(nool result: UnifiedSearchResult) {
        let kind: LauncherNoolKind
        switch result { case .issue: kind = .jira; case .session: kind = .session; case .event: kind = .event }
        self.init(id: "nool:\(result.id)", title: result.title, subtitle: result.subtitle,
                  payload: .nool(id: result.id, kind: kind))
    }
}
