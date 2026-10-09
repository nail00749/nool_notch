import Combine
import Foundation

enum AppModuleID: String, CaseIterable, Identifiable, Sendable {
    case aiChat, agentInbox, quotas, calendar, music, jira, liveActivities
    case fileShelf, textRecognition, systemMonitor, networkTools, dock
    case lidEffect, windowManagement, clipboard, gestures
    case scratchpad
    case recentCaptures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aiChat: "AI-чат"
        case .agentInbox: "Агенты и PR/CI"
        case .quotas: "Лимиты AI"
        case .calendar: "Календарь"
        case .music: "Музыка"
        case .jira: "Jira"
        case .liveActivities: "Активности и таймер"
        case .fileShelf: "Полка и обработка файлов"
        case .textRecognition: "Распознавание текста"
        case .systemMonitor: "Мониторинг системы"
        case .networkTools: "Сеть и Speedtest"
        case .dock: "NooL Dock"
        case .lidEffect: "Эффект крышки"
        case .windowManagement: "Окна и рабочие пространства"
        case .clipboard: "Буфер и шаблоны"
        case .gestures: "Жесты"
        case .scratchpad: "Черновик"
        case .recentCaptures: "Недавние снимки"
        }
    }

    var subtitle: String {
        switch self {
        case .aiChat: "Чат, быстрые ответы, перевод и вложения"
        case .agentInbox: "Сессии агентов, запросы внимания и проверки кода"
        case .quotas: "Квоты провайдеров, уведомления и системный виджет"
        case .calendar: "События и напоминания о встречах"
        case .music: "Текущий трек и управление воспроизведением"
        case .jira: "Задачи, закрепления и рабочие действия"
        case .liveActivities: "Таймер, батарея, звонки и загрузки"
        case .fileShelf: "Временная полка, конвертация и переименование"
        case .textRecognition: "Локальный OCR файлов и выбранной области экрана"
        case .systemMonitor: "CPU, память, диск, сеть и процессы"
        case .networkTools: "Замеры скорости, история и диагностика соединения"
        case .dock: "Панель приложений и виджетов"
        case .lidEffect: "Размытие и затемнение при закрытии MacBook"
        case .windowManagement: "Раскладки окон и сохранённые наборы приложений"
        case .clipboard: "Локальная история копирования и текстовые шаблоны"
        case .gestures: "Громкость и управление музыкой с чёлки"
        case .scratchpad: "Локальные заметки с автосохранением и экспортом"
        case .recentCaptures: "Последние изображения из выбранной папки"
        }
    }

    var iconName: String {
        switch self {
        case .aiChat: "sparkles"
        case .agentInbox: "terminal"
        case .quotas: "gauge.with.dots.needle.67percent"
        case .calendar: "calendar"
        case .music: "music.note"
        case .jira: "checkmark.square"
        case .liveActivities: "timer"
        case .fileShelf: "tray"
        case .textRecognition: "text.viewfinder"
        case .systemMonitor: "chart.xyaxis.line"
        case .networkTools: "speedometer"
        case .dock: "dock.rectangle"
        case .lidEffect: "laptopcomputer"
        case .windowManagement: "rectangle.split.2x1"
        case .clipboard: "doc.on.clipboard"
        case .gestures: "hand.draw"
        case .scratchpad: "square.and.pencil"
        case .recentCaptures: "photo.on.rectangle"
        }
    }

    var permissionSummary: String? {
        switch self {
        case .calendar: "Календарь — при подключении"
        case .music, .windowManagement, .gestures: "Универсальный доступ — для отдельных действий"
        case .textRecognition: "Запись экрана — для захвата области"
        case .lidEffect: "Запись экрана — для эффекта"
        case .quotas: "Уведомления — при включении оповещений"
        default: nil
        }
    }

    var surfaces: [String] {
        switch self {
        case .aiChat, .windowManagement, .clipboard, .networkTools: ["Launcher"]
        case .agentInbox, .jira, .calendar: ["Чёлка", "Launcher"]
        case .quotas: ["Чёлка", "Боковая панель", "Стек", "Виджет"]
        case .music, .liveActivities: ["Чёлка", "Dock"]
        case .fileShelf: ["Чёлка", "Launcher"]
        case .textRecognition: ["Launcher", "Полка"]
        case .systemMonitor: ["Боковая панель", "Стек"]
        case .dock: ["Dock"]
        case .lidEffect: ["Экран MacBook"]
        case .gestures: ["Чёлка"]
        case .scratchpad: ["Чёлка"]
        case .recentCaptures: ["Чёлка"]
        }
    }
}

enum AppModulePreset: String, CaseIterable, Identifiable {
    case minimal, developer, monitoring, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: "Минимальный"
        case .developer: "Разработчик"
        case .monitoring: "Мониторинг"
        case .all: "Все функции"
        }
    }
    var subtitle: String { modules.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ") }
    var modules: Set<AppModuleID> {
        switch self {
        case .minimal: [.calendar, .music]
        case .developer: [.aiChat, .agentInbox, .quotas, .jira, .clipboard, .windowManagement, .textRecognition, .networkTools]
        case .monitoring: [.systemMonitor, .networkTools, .quotas, .liveActivities]
        case .all: Set(AppModuleID.allCases)
        }
    }
}

/// The catalog gates runtime work, independently of each feature's saved configuration.
@MainActor
final class AppModuleStore: ObservableObject {
    static let shared = AppModuleStore()
    static let disabledKey = "nool.modules.disabled.v1"
    @Published private(set) var enabledModules: Set<AppModuleID>
    /// Sent after the value changes, so runtime owners see a coherent catalog.
    let changes = PassthroughSubject<Set<AppModuleID>, Never>()
    private let defaults: UserDefaults?
    private var unknownDisabledIDs: Set<String>

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let disabled = Set(defaults?.stringArray(forKey: Self.disabledKey) ?? [])
        unknownDisabledIDs = disabled.subtracting(AppModuleID.allCases.map(\.rawValue))
        enabledModules = Set(AppModuleID.allCases.filter { !disabled.contains($0.rawValue) })
    }

    func isEnabled(_ module: AppModuleID) -> Bool { enabledModules.contains(module) }

    func setEnabled(_ module: AppModuleID, enabled: Bool) {
        var next = enabledModules
        if enabled { next.insert(module) } else { next.remove(module) }
        setModules(next)
    }

    func applyPreset(_ preset: AppModulePreset) { setModules(preset.modules) }

    private func setModules(_ modules: Set<AppModuleID>) {
        guard enabledModules != modules else { return }
        enabledModules = modules
        let disabled = Set(AppModuleID.allCases).subtracting(modules).map(\.rawValue)
        defaults?.set(Set(disabled).union(unknownDisabledIDs).sorted(), forKey: Self.disabledKey)
        changes.send(modules)
    }
}

/// Each owner registers its own reversible start/stop work. Stops precede starts on preset changes.
@MainActor
final class AppModuleRuntime {
    private struct Hooks { let start: () -> Void; let stop: () -> Void }
    private let store: AppModuleStore
    private var hooks: [AppModuleID: Hooks] = [:]
    private var active: Set<AppModuleID> = []
    private var subscription: AnyCancellable?
    private var isStarted = false

    init(store: AppModuleStore) { self.store = store }

    func register(_ module: AppModuleID, start: @escaping () -> Void, stop: @escaping () -> Void) {
        precondition(!isStarted && hooks[module] == nil)
        hooks[module] = Hooks(start: start, stop: stop)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        subscription = store.changes.sink { [weak self] enabled in self?.reconcile(enabled) }
        reconcile(store.enabledModules)
    }

    func stop() {
        isStarted = false
        subscription = nil
        reconcile([])
    }

    private func reconcile(_ enabled: Set<AppModuleID>) {
        for module in AppModuleID.allCases where active.contains(module) && !enabled.contains(module) {
            active.remove(module)
            hooks[module]?.stop()
        }
        guard isStarted else { return }
        for module in AppModuleID.allCases where !active.contains(module) && enabled.contains(module) {
            guard let hook = hooks[module] else { continue }
            active.insert(module)
            hook.start()
        }
    }
}
