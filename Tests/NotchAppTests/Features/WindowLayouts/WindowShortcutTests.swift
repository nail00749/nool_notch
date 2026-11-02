import Carbon
import XCTest
@testable import NotchApp

@MainActor
final class WindowShortcutTests: XCTestCase {
    func testDefaultsCoverEveryActionWithoutDuplicates() {
        let bindings = WindowShortcutSettings.standardBindings
        XCTAssertEqual(Set(bindings.keys), Set(WindowLayoutAction.allCases.map(\.rawValue)))
        let keys = bindings.values.map { "\($0.keyCode):\($0.modifiers)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(bindings.values.allSatisfy(\.isValid))
        XCTAssertEqual(bindings[WindowLayoutAction.restore.rawValue]?.keyCode, UInt32(kVK_DownArrow))
        XCTAssertEqual(bindings[WindowLayoutAction.maximize.rawValue]?.keyCode, UInt32(kVK_UpArrow))
    }

    func testRecordingHasExclusiveOwnershipAcrossLauncherAndWindowPanels() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LauncherSettings(defaults: defaults)
        let launcherOwner = UUID(), windowOwner = UUID()
        XCTAssertTrue(settings.beginShortcutRecording(owner: launcherOwner))
        XCTAssertFalse(settings.beginShortcutRecording(owner: windowOwner))
        settings.endShortcutRecording(owner: windowOwner)
        XCTAssertTrue(settings.isRecordingShortcut, "Another panel cannot cancel the active recorder")
        settings.endShortcutRecording(owner: launcherOwner)
        XCTAssertFalse(settings.isRecordingShortcut)
        XCTAssertTrue(settings.beginShortcutRecording(owner: windowOwner))
        settings.endShortcutRecording(owner: launcherOwner)
        XCTAssertTrue(settings.isRecordingShortcut)
        settings.endShortcutRecording(owner: windowOwner)
        XCTAssertFalse(settings.isRecordingShortcut)
    }

    func testReassignmentRemovalAndDisabledStatePersist() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowShortcutSettings(defaults: defaults)
        let custom = LauncherShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | controlKey), keyLabel: "L")
        XCTAssertNil(settings.assign(custom, to: .left, launcher: .standard))
        XCTAssertNil(settings.assign(nil, to: .right, launcher: .standard))
        settings.enabled = false
        let restored = WindowShortcutSettings(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .left), custom)
        XCTAssertNil(restored.shortcut(for: .right))
        XCTAssertFalse(restored.enabled)
        restored.reset()
        XCTAssertNotNil(restored.shortcut(for: .right))
    }

    func testCollisionsIgnoreDisplayedKeyLabelAndDoNotOverwriteBinding() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowShortcutSettings(defaults: defaults)
        let original = settings.shortcut(for: .left)
        var right = try XCTUnwrap(settings.shortcut(for: .right))
        right.keyLabel = "Other label"
        XCTAssertNotNil(settings.assign(right, to: .left, launcher: .standard))
        XCTAssertEqual(settings.shortcut(for: .left), original)
        XCTAssertNotNil(settings.assign(.standard, to: .left, launcher: .standard))
        XCTAssertEqual(settings.shortcut(for: .left), original)
    }

    func testRegistrationSuspendsForRecordingDisabledModuleAndStop() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowShortcutSettings(defaults: defaults)
        let launcher = LauncherSettings(defaults: defaults)
        let modules = AppModuleStore(defaults: nil)
        let backend = FakeWindowHotKeys()
        let controller = WindowShortcutController(manager: WindowLayoutManager(defaults: defaults), modules: modules,
            launcherSettings: launcher, settings: settings, registrar: backend)
        defer { controller.stop() }
        XCTAssertEqual(backend.registered.count, WindowLayoutAction.allCases.count)
        settings.recordingAction = .left
        XCTAssertTrue(backend.registered.isEmpty)
        settings.recordingAction = nil
        XCTAssertFalse(backend.registered.isEmpty)
        launcher.isRecordingShortcut = true
        controller.refresh()
        XCTAssertTrue(backend.registered.isEmpty)
        launcher.isRecordingShortcut = false
        controller.refresh()
        modules.setEnabled(.windowManagement, enabled: false)
        XCTAssertTrue(backend.registered.isEmpty)
        modules.setEnabled(.windowManagement, enabled: true)
        XCTAssertFalse(backend.registered.isEmpty)
        settings.enabled = false
        XCTAssertTrue(backend.registered.isEmpty)
        settings.enabled = true
        XCTAssertFalse(backend.registered.isEmpty)
        controller.stop()
        settings.reset()
        XCTAssertTrue(backend.registered.isEmpty, "A stopped owner must not re-register shortcuts")
    }

    func testUnavailableAndLauncherConflictsReportPerActionWithoutDisablingOthers() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowShortcutSettings(defaults: defaults)
        let launcher = LauncherSettings(defaults: defaults)
        launcher.shortcut = try XCTUnwrap(settings.shortcut(for: .left))
        let backend = FakeWindowHotKeys()
        backend.rejectedCode = UInt32(kVK_RightArrow)
        let controller = WindowShortcutController(manager: WindowLayoutManager(defaults: defaults),
            modules: AppModuleStore(defaults: nil), launcherSettings: launcher, settings: settings, registrar: backend)
        defer { controller.stop() }
        XCTAssertNotNil(controller.errors[WindowLayoutAction.left.rawValue])
        XCTAssertNotNil(controller.errors[WindowLayoutAction.right.rawValue])
        XCTAssertNil(controller.errors[WindowLayoutAction.maximize.rawValue])
        XCTAssertFalse(backend.registered.isEmpty)
    }

    private func defaults() throws -> (String, UserDefaults) {
        let suite = "window-shortcuts-\(UUID().uuidString)"
        return (suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }
}

@MainActor
private final class FakeWindowHotKeys: WindowHotKeyRegistering {
    var onPress: ((UInt32) -> Void)?
    var registered: [UInt32: LauncherShortcut] = [:]
    var rejectedCode: UInt32?
    func register(_ shortcut: LauncherShortcut, id: UInt32) -> Bool {
        guard shortcut.keyCode != rejectedCode else { return false }
        registered[id] = shortcut
        return true
    }
    func stop() { registered.removeAll() }
}
