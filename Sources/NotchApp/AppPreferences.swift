import Foundation

@MainActor
protocol AppPreferencesStoring: AnyObject {
    var hoverExpansionDelay: TimeInterval { get set }
    var lastSelectedPanel: PanelID { get set }
    var panelOrder: [PanelID] { get set }
    var hiddenPanelIDs: Set<PanelID> { get set }
    var startupPanel: PanelID? { get set }
    var selectedAISection: AISection { get set }
    var hasCompletedPanelSwipe: Bool { get set }
    var quotaProviderOrder: [String] { get set }
    var hiddenQuotaProviderIDs: Set<String> { get set }
    var compactQuotaProviderID: String { get set }
    var jiraBaseURLString: String? { get set }
    var jiraSelectedProjectKeys: Set<String> { get set }
    var jiraPinnedContainers: [JiraPinnedContainer] { get set }
    var jiraPinnedIssues: [JiraPinnedIssue] { get set }
}

@MainActor
final class UserDefaultsAppPreferences: AppPreferencesStoring {
    static let defaultQuotaProviderOrder = [
        "chatgpt-subscription",
        "claude-code-subscription",
        "ollama-cloud"
    ]
    static let defaultHoverExpansionDelay: TimeInterval = 0.5
    static let hoverExpansionDelayKey = "interaction.hoverExpansionDelay"
    static let lastSelectedPanelKey = "navigation.lastSelectedPanel"
    static let panelOrderKey = "navigation.panelOrder"
    static let hiddenPanelIDsKey = "navigation.hiddenPanelIDs"
    static let startupPanelKey = "navigation.startupPanel"
    static let selectedAISectionKey = "ai.selectedSection"
    static let hasCompletedPanelSwipeKey = "interaction.hasCompletedPanelSwipe"
    static let quotaProviderOrderKey = "limits.providerOrder"
    static let hiddenQuotaProviderIDsKey = "limits.hiddenProviderIDs"
    static let compactQuotaProviderIDKey = "limits.compactProviderID"
    static let jiraBaseURLKey = "jira.baseURL"
    static let jiraSelectedProjectKeysKey = "jira.selectedProjectKeys"
    static let jiraPinnedContainersKey = "jira.pinnedContainers"
    static let jiraPinnedIssuesKey = "jira.pinnedIssues"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hoverExpansionDelay: TimeInterval {
        get {
            guard defaults.object(forKey: Self.hoverExpansionDelayKey) != nil else {
                return Self.defaultHoverExpansionDelay
            }
            return Self.clampedDelay(defaults.double(forKey: Self.hoverExpansionDelayKey))
        }
        set {
            defaults.set(Self.clampedDelay(newValue), forKey: Self.hoverExpansionDelayKey)
        }
    }

    var lastSelectedPanel: PanelID {
        get {
            guard let rawValue = defaults.string(forKey: Self.lastSelectedPanelKey),
                  let panel = Self.panelID(from: rawValue) else {
                return .ai
            }
            return panel
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.lastSelectedPanelKey)
        }
    }

    var panelOrder: [PanelID] {
        get {
            let stored = defaults.stringArray(forKey: Self.panelOrderKey) ?? []
            return Self.normalizedPanelOrder(stored.compactMap(Self.panelID(from:)))
        }
        set {
            defaults.set(
                Self.normalizedPanelOrder(newValue).map(\.rawValue),
                forKey: Self.panelOrderKey
            )
        }
    }

    var hiddenPanelIDs: Set<PanelID> {
        get {
            var hidden = Set(
                (defaults.stringArray(forKey: Self.hiddenPanelIDsKey) ?? [])
                    .compactMap(Self.panelID(from:))
            )
            if hidden.count >= PanelID.allCases.count,
               let fallback = panelOrder.first ?? PanelID.allCases.first {
                hidden.remove(fallback)
            }
            return hidden
        }
        set {
            var hidden = Set(newValue.filter(PanelID.allCases.contains))
            if hidden.count >= PanelID.allCases.count,
               let fallback = panelOrder.first ?? PanelID.allCases.first {
                hidden.remove(fallback)
            }
            defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenPanelIDsKey)
        }
    }

    var startupPanel: PanelID? {
        get {
            guard let rawValue = defaults.string(forKey: Self.startupPanelKey) else { return nil }
            return Self.panelID(from: rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.startupPanelKey)
            } else {
                defaults.removeObject(forKey: Self.startupPanelKey)
            }
        }
    }

    var selectedAISection: AISection {
        get {
            guard let rawValue = defaults.string(forKey: Self.selectedAISectionKey),
                  let section = AISection(rawValue: rawValue) else {
                return .limits
            }
            return section
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectedAISectionKey)
        }
    }

    var hasCompletedPanelSwipe: Bool {
        get { defaults.bool(forKey: Self.hasCompletedPanelSwipeKey) }
        set { defaults.set(newValue, forKey: Self.hasCompletedPanelSwipeKey) }
    }

    var quotaProviderOrder: [String] {
        get {
            Self.normalizedQuotaProviderOrder(
                defaults.stringArray(forKey: Self.quotaProviderOrderKey) ?? []
            )
        }
        set {
            defaults.set(
                Self.normalizedQuotaProviderOrder(newValue),
                forKey: Self.quotaProviderOrderKey
            )
        }
    }

    var hiddenQuotaProviderIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.hiddenQuotaProviderIDsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.hiddenQuotaProviderIDsKey) }
    }

    var compactQuotaProviderID: String {
        get {
            defaults.string(forKey: Self.compactQuotaProviderIDKey)
                ?? Self.defaultQuotaProviderOrder[0]
        }
        set { defaults.set(newValue, forKey: Self.compactQuotaProviderIDKey) }
    }

    var jiraBaseURLString: String? {
        get { defaults.string(forKey: Self.jiraBaseURLKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.jiraBaseURLKey)
            } else {
                defaults.removeObject(forKey: Self.jiraBaseURLKey)
            }
        }
    }

    var jiraSelectedProjectKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.jiraSelectedProjectKeysKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.jiraSelectedProjectKeysKey) }
    }

    var jiraPinnedContainers: [JiraPinnedContainer] {
        get { decodedPins(forKey: Self.jiraPinnedContainersKey) }
        set { encodePins(Self.unique(newValue), forKey: Self.jiraPinnedContainersKey) }
    }

    var jiraPinnedIssues: [JiraPinnedIssue] {
        get { decodedPins(forKey: Self.jiraPinnedIssuesKey) }
        set { encodePins(Self.unique(newValue), forKey: Self.jiraPinnedIssuesKey) }
    }

    private func decodedPins<Value: Decodable>(forKey key: String) -> [Value] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Value].self, from: data)) ?? []
    }

    private func encodePins<Value: Encodable>(_ values: [Value], forKey key: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }

    private static func clampedDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultHoverExpansionDelay }
        return min(1, max(0, value))
    }

    private static func normalizedPanelOrder(_ panels: [PanelID]) -> [PanelID] {
        var seen: Set<PanelID> = []
        let known = panels.filter { seen.insert($0).inserted }
        return known + PanelID.allCases.filter { seen.insert($0).inserted }
    }

    private static func panelID(from rawValue: String) -> PanelID? {
        if rawValue == "limits" { return .ai }
        return PanelID(rawValue: rawValue)
    }

    private static func normalizedQuotaProviderOrder(_ providerIDs: [String]) -> [String] {
        var seen: Set<String> = []
        let stored = providerIDs.filter { $0.isEmpty == false && seen.insert($0).inserted }
        return stored + defaultQuotaProviderOrder.filter { seen.insert($0).inserted }
    }

    private static func unique<Value: Identifiable>(_ values: [Value]) -> [Value]
    where Value.ID: Hashable {
        var seen: Set<Value.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }
}
