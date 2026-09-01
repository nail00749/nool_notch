import Foundation

@MainActor
protocol AppPreferencesStoring: AnyObject {
    var hoverExpansionDelay: TimeInterval { get set }
    var lastSelectedPanel: PanelID { get set }
    var panelOrder: [PanelID] { get set }
    var hiddenPanelIDs: Set<PanelID> { get set }
    var startupPanel: PanelID? { get set }
    var hasCompletedPanelSwipe: Bool { get set }
    var quotaProviderOrder: [String] { get set }
    var hiddenQuotaProviderIDs: Set<String> { get set }
    var compactQuotaProviderID: String { get set }
    var jiraBaseURLString: String? { get set }
    var jiraSelectedProjectKeys: Set<String> { get set }
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
    static let hasCompletedPanelSwipeKey = "interaction.hasCompletedPanelSwipe"
    static let quotaProviderOrderKey = "limits.providerOrder"
    static let hiddenQuotaProviderIDsKey = "limits.hiddenProviderIDs"
    static let compactQuotaProviderIDKey = "limits.compactProviderID"
    static let jiraBaseURLKey = "jira.baseURL"
    static let jiraSelectedProjectKeysKey = "jira.selectedProjectKeys"

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
                  let panel = PanelID(rawValue: rawValue) else {
                return .limits
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
            return Self.normalizedPanelOrder(stored.compactMap(PanelID.init(rawValue:)))
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
                    .compactMap(PanelID.init(rawValue:))
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
            return PanelID(rawValue: rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.startupPanelKey)
            } else {
                defaults.removeObject(forKey: Self.startupPanelKey)
            }
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

    private static func clampedDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultHoverExpansionDelay }
        return min(1, max(0, value))
    }

    private static func normalizedPanelOrder(_ panels: [PanelID]) -> [PanelID] {
        var seen: Set<PanelID> = []
        let known = panels.filter { seen.insert($0).inserted }
        return known + PanelID.allCases.filter { seen.insert($0).inserted }
    }

    private static func normalizedQuotaProviderOrder(_ providerIDs: [String]) -> [String] {
        var seen: Set<String> = []
        let stored = providerIDs.filter { $0.isEmpty == false && seen.insert($0).inserted }
        return stored + defaultQuotaProviderOrder.filter { seen.insert($0).inserted }
    }
}
