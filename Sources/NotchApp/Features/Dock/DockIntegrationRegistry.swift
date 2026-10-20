import SwiftUI

/// Each built-in module owns its presentation; the strip only knows this catalog.
@MainActor
struct DockIntegration {
    let id: String
    let title: String
    let symbol: String
    let supportedSpans: [Int]
    let isAvailable: (NotchViewModel) -> Bool
    let content: (DockElement, DockIntegrationContext) -> AnyView
}

@MainActor
struct DockIntegrationContext {
    let model: NotchViewModel
    let preferences: DockPreferences
    let interactionChanged: (Bool) -> Void
    let openLauncher: () -> Void
    let openDisplays: () -> Void
}

@MainActor
enum DockIntegrationRegistry {
    static let integrations: [DockIntegration] = [
        DockIntegration(id: "music", title: "Музыка", symbol: "music.note", supportedSpans: [1, 2, 3],
                        isAvailable: { $0.modules.isEnabled(.music) }) {
            AnyView(DockMusicWidget(model: $1.model, span: $0.span, interactionChanged: $1.interactionChanged))
        },
        DockIntegration(id: "calendar", title: "Календарь", symbol: "calendar", supportedSpans: [1, 2, 3],
                        isAvailable: { $0.modules.isEnabled(.calendar) }) {
            AnyView(DockCalendarWidget(model: $1.model, span: $0.span, interactionChanged: $1.interactionChanged))
        },
        DockIntegration(id: "timer", title: "Таймер", symbol: "timer", supportedSpans: [1, 2],
                        isAvailable: { $0.modules.isEnabled(.liveActivities) }) {
            AnyView(DockTimerWidget(source: $1.model.timerSource, span: $0.span,
                                   interactionChanged: $1.interactionChanged))
        },
        DockIntegration(id: "note", title: "Заметка", symbol: "note.text", supportedSpans: [1, 2, 3],
                        isAvailable: { _ in true }) {
            AnyView(DockNoteWidget(preferences: $1.preferences, span: $0.span,
                                  interactionChanged: $1.interactionChanged))
        },
        DockIntegration(id: "launcher", title: "Launcher", symbol: "magnifyingglass", supportedSpans: [1],
                        isAvailable: { _ in true }) { _, context in
            AnyView(DockActionWidget(symbol: "magnifyingglass", title: "Launcher", action: context.openLauncher))
        },
        DockIntegration(id: "displays", title: "Дисплеи", symbol: "display.2", supportedSpans: [1],
                        isAvailable: { $0.modules.isEnabled(.displays) }) { _, context in
            AnyView(DockActionWidget(symbol: "display.2", title: "Дисплеи", action: context.openDisplays))
        }
    ]

    static func integration(_ id: String?) -> DockIntegration? {
        integrations.first { $0.id == id }
    }
}
