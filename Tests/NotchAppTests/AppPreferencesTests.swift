import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testPreferencesClampDelayAndRestorePrimaryPanel() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        preferences.hoverExpansionDelay = 2
        preferences.lastSelectedPanel = .music

        let restored = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertEqual(restored.hoverExpansionDelay, 1)
        XCTAssertEqual(restored.lastSelectedPanel, .music)
    }

    func testPreferencesFallBackForMissingAndInvalidValues() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.hoverExpansionDelay, 0.5)
        XCTAssertEqual(preferences.lastSelectedPanel, .ai)

        defaults.set("unknown-panel", forKey: UserDefaultsAppPreferences.lastSelectedPanelKey)
        preferences = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.lastSelectedPanel, .ai)
    }

    func testLegacyLimitsPanelValuesMigrateToAI() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("limits", forKey: UserDefaultsAppPreferences.lastSelectedPanelKey)
        defaults.set(["music", "limits", "jira"], forKey: UserDefaultsAppPreferences.panelOrderKey)
        defaults.set(["limits"], forKey: UserDefaultsAppPreferences.hiddenPanelIDsKey)
        defaults.set("limits", forKey: UserDefaultsAppPreferences.startupPanelKey)

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.lastSelectedPanel, .ai)
        XCTAssertEqual(Array(preferences.panelOrder.prefix(3)), [.music, .ai, .jira])
        XCTAssertEqual(preferences.hiddenPanelIDs, [.ai])
        XCTAssertEqual(preferences.startupPanel, .ai)
    }

    func testAISectionDefaultsAndRoundTrips() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsAppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedAISection, .limits)
        preferences.selectedAISection = .sessions

        XCTAssertEqual(UserDefaultsAppPreferences(defaults: defaults).selectedAISection, .sessions)
    }

    func testNonFiniteHoverDelayFallsBackSafely() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsAppPreferences(defaults: defaults)

        preferences.hoverExpansionDelay = .nan

        XCTAssertEqual(preferences.hoverExpansionDelay, 0.5)
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: .infinity),
            0.5
        )
    }

    func testJiraPreferencesRoundTripBaseURLAndSelectedProjectKeys() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        preferences.jiraBaseURLString = "https://jira.example.test/company"
        preferences.jiraSelectedProjectKeys = ["WEB", "APP"]
        preferences.lastSelectedPanel = .jira

        let restored = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertEqual(restored.jiraBaseURLString, "https://jira.example.test/company")
        XCTAssertEqual(restored.jiraSelectedProjectKeys, ["APP", "WEB"])
        XCTAssertEqual(restored.lastSelectedPanel, .jira)
        XCTAssertEqual(
            defaults.array(forKey: UserDefaultsAppPreferences.jiraSelectedProjectKeysKey) as? [String],
            ["APP", "WEB"]
        )

        preferences.jiraBaseURLString = nil
        XCTAssertNil(preferences.jiraBaseURLString)
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppPreferences.jiraBaseURLKey))
    }
}
