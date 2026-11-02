import Carbon
import XCTest
@testable import NotchApp

@MainActor
final class LauncherSettingsTests: XCTestCase {
    func testDefaultsAreOptInAndShortcutPersists() throws {
        let suite = "launcher-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LauncherSettings(defaults: defaults)
        XCTAssertFalse(settings.clipboardEnabled)
        XCTAssertEqual(settings.applicationLayout, .list)
        XCTAssertEqual(settings.defaultCurrency, .RUB)
        settings.applicationLayout = .grid
        settings.defaultCurrency = .CNY
        XCTAssertEqual(settings.shortcut, .standard)
        settings.shortcut = LauncherShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
        settings.folderPaths = []
        let restored = LauncherSettings(defaults: defaults)
        XCTAssertEqual(restored.shortcut, settings.shortcut)
        XCTAssertEqual(restored.applicationLayout, .grid)
        XCTAssertEqual(restored.defaultCurrency, .CNY)
        XCTAssertTrue(restored.folders.isEmpty)
    }

    func testInvalidSavedShortcutAndOutOfRangeLimitsAreNormalized() throws {
        let suite = "launcher-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = LauncherShortcut(keyCode: 999, modifiers: 0, keyLabel: "bad")
        defaults.set(try JSONEncoder().encode(invalid), forKey: "nool.launcher.shortcut")
        defaults.set(-10, forKey: "nool.launcher.clipboardLimit")
        defaults.set(900, forKey: "nool.launcher.retentionDays")
        defaults.set("unknown", forKey: "nool.launcher.applicationLayout")
        let settings = LauncherSettings(defaults: defaults)
        XCTAssertEqual(settings.shortcut, .standard)
        XCTAssertEqual(settings.clipboardLimit, 10)
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertEqual(settings.applicationLayout, .list)
        XCTAssertFalse(LauncherShortcut(keyCode: 1, modifiers: UInt32(shiftKey), keyLabel: "S").isValid)
    }
}
