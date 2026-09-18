enum PanelID: String, CaseIterable, Identifiable {
    case ai
    case live
    case calendar
    case music
    case jira

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai:
            "AI"
        case .live:
            "Live"
        case .calendar:
            "Календарь"
        case .music:
            "Музыка"
        case .jira:
            "Jira"
        }
    }

    var iconName: String {
        switch self {
        case .ai:
            "sparkles"
        case .live:
            "bolt.horizontal.circle"
        case .calendar:
            "calendar"
        case .music:
            "waveform"
        case .jira:
            "checkmark.square"
        }
    }
}

enum AISection: String, CaseIterable, Identifiable {
    case limits
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: "Лимиты"
        case .sessions: "Inbox"
        }
    }
}

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case list
    case month

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .list:
            "list.bullet"
        case .month:
            "calendar"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .list:
            "Список событий"
        case .month:
            "Месяц"
        }
    }
}
