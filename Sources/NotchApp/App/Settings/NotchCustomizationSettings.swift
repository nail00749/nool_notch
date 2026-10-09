import Combine
import Foundation

enum NotchLayoutPreset: String, CaseIterable, Identifiable, Codable {
    case compact
    case spacious
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Компактный"
        case .spacious: "Просторный"
        case .custom: "Свой размер"
        }
    }
}

enum NotchQuickActionPlacement: String, CaseIterable, Codable, Identifiable {
    case leading
    case trailing
    case bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .leading: "Слева"
        case .trailing: "Справа"
        case .bottom: "Снизу"
        }
    }

    var capacity: Int {
        self == .bottom ? 4 : 2
    }
}

enum NotchQuickActionID: String, CaseIterable, Codable, Identifiable {
    case modules
    case timer
    case settings
    case sound
    case ai
    case live
    case calendar
    case music
    case jira
    case scratchpad
    case recentCaptures

    var id: Self { self }

    var title: String {
        switch self {
        case .modules: "Модули"
        case .timer: "Таймер"
        case .settings: "Настройки"
        case .sound: "Звук macOS"
        case .ai: "AI и агенты"
        case .live: "Активности"
        case .calendar: "Календарь"
        case .music: "Музыка"
        case .jira: "Jira"
        case .scratchpad: "Черновик"
        case .recentCaptures: "Недавние снимки"
        }
    }

    var iconName: String {
        switch self {
        case .modules: "square.grid.2x2.fill"
        case .timer: "timer"
        case .settings: "gearshape.fill"
        case .sound: "speaker.wave.2.fill"
        case .ai: "sparkles"
        case .live: "bolt.horizontal.circle"
        case .calendar: "calendar"
        case .music: "waveform"
        case .jira: "checkmark.square"
        case .scratchpad: "square.and.pencil"
        case .recentCaptures: "photo.on.rectangle"
        }
    }
}

struct NotchQuickAction: Codable, Equatable, Identifiable {
    var action: NotchQuickActionID
    var placement: NotchQuickActionPlacement
    var customTitle: String?

    var id: String { action.rawValue }
    var title: String {
        guard let customTitle, customTitle.isEmpty == false else { return action.title }
        return customTitle
    }
    var iconName: String { action.iconName }
}

@MainActor
final class NotchCustomizationSettings: ObservableObject {
    static let shared = NotchCustomizationSettings()

    private enum Key {
        static let layoutPreset = "notch.customization.layoutPreset.v1"
        static let expandedWidth = "notch.customization.expandedWidth.v1"
        static let maxExpandedHeight = "notch.customization.maxExpandedHeight.v1"
        static let showsOutline = "notch.customization.showsOutline.v1"
        static let quickActions = "notch.customization.quickActions.v1"
        static let showsMusicIndicator = "notch.customization.showsMusicIndicator.v1"
        static let showsQuotaIndicator = "notch.customization.showsQuotaIndicator.v1"
        static let showsQuotaWhenIdle = "notch.customization.showsQuotaWhenIdle.v1"
        static let hapticsEnabled = "notch.customization.hapticsEnabled.v1"
    }

    static let expandedWidthRange: ClosedRange<Double> = 500...640
    static let maxExpandedHeightRange: ClosedRange<Double> = 340...620

    @Published private(set) var layoutPreset: NotchLayoutPreset
    @Published private(set) var quickActions: [NotchQuickAction]

    @Published private var storedExpandedWidth: Double
    @Published private var storedMaxExpandedHeight: Double

    var expandedWidth: Double {
        get { storedExpandedWidth }
        set { setExpandedWidth(newValue, selectsCustomPreset: true) }
    }

    var maxExpandedHeight: Double {
        get { storedMaxExpandedHeight }
        set { setMaxExpandedHeight(newValue, selectsCustomPreset: true) }
    }

    var layoutChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $storedExpandedWidth.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $storedMaxExpandedHeight.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $quickActions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $showsMusicIndicator.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $showsQuotaIndicator.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $showsQuotaWhenIdle.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }

    @Published var showsOutline: Bool {
        didSet { defaults.set(showsOutline, forKey: Key.showsOutline) }
    }

    @Published var showsMusicIndicator: Bool {
        didSet { defaults.set(showsMusicIndicator, forKey: Key.showsMusicIndicator) }
    }

    @Published var showsQuotaIndicator: Bool {
        didSet { defaults.set(showsQuotaIndicator, forKey: Key.showsQuotaIndicator) }
    }

    @Published var showsQuotaWhenIdle: Bool {
        didSet { defaults.set(showsQuotaWhenIdle, forKey: Key.showsQuotaWhenIdle) }
    }

    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layoutPreset = NotchLayoutPreset(rawValue: defaults.string(forKey: Key.layoutPreset) ?? "") ?? .compact
        storedExpandedWidth = Self.expandedWidthRange.clamped(defaults.object(forKey: Key.expandedWidth) as? Double ?? 500)
        storedMaxExpandedHeight = Self.maxExpandedHeightRange.clamped(
            defaults.object(forKey: Key.maxExpandedHeight) as? Double ?? 500
        )
        showsOutline = defaults.object(forKey: Key.showsOutline) as? Bool ?? false
        showsMusicIndicator = defaults.object(forKey: Key.showsMusicIndicator) as? Bool ?? true
        showsQuotaIndicator = defaults.object(forKey: Key.showsQuotaIndicator) as? Bool ?? true
        showsQuotaWhenIdle = defaults.object(forKey: Key.showsQuotaWhenIdle) as? Bool ?? false
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        let storedActions = defaults.data(forKey: Key.quickActions).flatMap {
            try? JSONDecoder().decode([NotchQuickAction].self, from: $0)
        }
        quickActions = Self.sanitize(storedActions ?? Self.defaultActions)
    }

    func apply(_ preset: NotchLayoutPreset) {
        switch preset {
        case .compact:
            setExpandedWidth(500, selectsCustomPreset: false)
            setMaxExpandedHeight(500, selectsCustomPreset: false)
        case .spacious:
            setExpandedWidth(560, selectsCustomPreset: false)
            setMaxExpandedHeight(560, selectsCustomPreset: false)
        case .custom:
            break
        }
        layoutPreset = preset
        defaults.set(preset.rawValue, forKey: Key.layoutPreset)
    }

    func actions(at placement: NotchQuickActionPlacement) -> [NotchQuickAction] {
        quickActions.filter { $0.placement == placement }
    }

    func add(_ action: NotchQuickActionID, at placement: NotchQuickActionPlacement) {
        guard quickActions.contains(where: { $0.action == action }) == false,
              actions(at: placement).count < placement.capacity else { return }
        quickActions.append(NotchQuickAction(action: action, placement: placement))
        persistQuickActions()
    }

    func remove(_ action: NotchQuickActionID) {
        let updated = quickActions.filter { $0.action != action }
        guard updated != quickActions else { return }
        quickActions = updated
        persistQuickActions()
    }

    func move(_ action: NotchQuickActionID, to placement: NotchQuickActionPlacement) {
        guard let index = quickActions.firstIndex(where: { $0.action == action }),
              quickActions[index].placement != placement,
              actions(at: placement).count < placement.capacity else { return }
        quickActions[index].placement = placement
        persistQuickActions()
    }

    func move(_ action: NotchQuickActionID, by offset: Int) {
        guard let sourceIndex = quickActions.firstIndex(where: { $0.action == action }) else { return }
        let group = actions(at: quickActions[sourceIndex].placement)
        guard let localIndex = group.firstIndex(where: { $0.action == action }) else { return }
        let targetIndex = localIndex + offset
        guard group.indices.contains(targetIndex) else { return }
        guard let otherIndex = quickActions.firstIndex(where: { $0.action == group[targetIndex].action }) else { return }
        quickActions.swapAt(sourceIndex, otherIndex)
        persistQuickActions()
    }

    func rename(_ action: NotchQuickActionID, to title: String) {
        guard let index = quickActions.firstIndex(where: { $0.action == action }) else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        quickActions[index].customTitle = trimmed == action.title ? nil : trimmed
        persistQuickActions()
    }

    func canAdd(_ action: NotchQuickActionID, at placement: NotchQuickActionPlacement) -> Bool {
        quickActions.contains(where: { $0.action == action }) == false && actions(at: placement).count < placement.capacity
    }

    private func setExpandedWidth(_ width: Double, selectsCustomPreset: Bool) {
        let value = Self.expandedWidthRange.clamped(width)
        guard storedExpandedWidth != value else { return }
        storedExpandedWidth = value
        defaults.set(value, forKey: Key.expandedWidth)
        if selectsCustomPreset { selectCustomPreset() }
    }

    private func setMaxExpandedHeight(_ height: Double, selectsCustomPreset: Bool) {
        let value = Self.maxExpandedHeightRange.clamped(height)
        guard storedMaxExpandedHeight != value else { return }
        storedMaxExpandedHeight = value
        defaults.set(value, forKey: Key.maxExpandedHeight)
        if selectsCustomPreset { selectCustomPreset() }
    }

    private func selectCustomPreset() {
        guard layoutPreset != .custom else { return }
        layoutPreset = .custom
        defaults.set(NotchLayoutPreset.custom.rawValue, forKey: Key.layoutPreset)
    }

    private func persistQuickActions() {
        guard let data = try? JSONEncoder().encode(quickActions) else { return }
        defaults.set(data, forKey: Key.quickActions)
    }

    private static let defaultActions = [
        NotchQuickAction(action: .modules, placement: .leading),
        NotchQuickAction(action: .timer, placement: .leading),
        NotchQuickAction(action: .settings, placement: .trailing),
        NotchQuickAction(action: .sound, placement: .trailing)
    ]

    private static func sanitize(_ actions: [NotchQuickAction]) -> [NotchQuickAction] {
        var result: [NotchQuickAction] = []
        var seen: Set<NotchQuickActionID> = []
        var counts: [NotchQuickActionPlacement: Int] = [:]
        for var action in actions {
            guard !seen.contains(action.action), counts[action.placement, default: 0] < action.placement.capacity else { continue }
            let trimmed = action.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            action.customTitle = trimmed.flatMap {
                $0.isEmpty || $0 == action.action.title ? nil : String($0.prefix(24))
            }
            seen.insert(action.action)
            counts[action.placement, default: 0] += 1
            result.append(action)
        }
        return result
    }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double {
        value.isFinite ? Swift.min(upperBound, Swift.max(lowerBound, value)) : lowerBound
    }
}
