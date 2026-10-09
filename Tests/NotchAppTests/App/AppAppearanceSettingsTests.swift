import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class AppAppearanceSettingsTests: XCTestCase {
    func testThemePersistsAndSystemClearsForcedAppearance() {
        let suite = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var applied: [NSAppearance.Name?] = []
        let settings = AppAppearanceSettings(defaults: defaults) { applied.append($0?.name) }
        XCTAssertEqual(settings.theme, .system)
        XCTAssertTrue(applied.isEmpty)
        settings.applyCurrentTheme()
        settings.theme = .light
        settings.theme = .dark
        XCTAssertEqual(applied.count, 3)
        XCTAssertNil(applied[0])
        XCTAssertEqual(applied[1], .aqua)
        XCTAssertEqual(applied[2], .darkAqua)

        let restored = AppAppearanceSettings(defaults: defaults) { applied.append($0?.name) }
        XCTAssertEqual(restored.theme, .dark)
        restored.applyCurrentTheme()
        XCTAssertEqual(applied.last!, .darkAqua)
        restored.theme = .system
        XCTAssertNil(applied.last!)
        XCTAssertEqual(defaults.string(forKey: AppAppearanceSettings.preferenceKey), "system")
    }

    func testUnknownSavedThemeFallsBackToSystem() {
        let suite = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: AppAppearanceSettings.preferenceKey)
        let settings = AppAppearanceSettings(defaults: defaults) { XCTAssertNil($0) }
        XCTAssertEqual(settings.theme, .system)
        settings.applyCurrentTheme()
    }
}
