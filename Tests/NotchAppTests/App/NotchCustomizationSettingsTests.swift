import Combine
import XCTest
@testable import NotchApp

final class NotchCustomizationSettingsTests: XCTestCase {
    @MainActor
    func testLayoutPresetPersistsAndManualDimensionsSwitchToCustom() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        settings.apply(.spacious)

        XCTAssertEqual(settings.expandedWidth, 560)
        XCTAssertEqual(settings.maxExpandedHeight, 560)
        XCTAssertEqual(settings.layoutPreset, .spacious)

        settings.expandedWidth = 700
        XCTAssertEqual(settings.expandedWidth, NotchCustomizationSettings.expandedWidthRange.upperBound)
        XCTAssertEqual(settings.layoutPreset, .custom)

        let restored = NotchCustomizationSettings(defaults: defaults)
        XCTAssertEqual(restored.expandedWidth, 640)
        XCTAssertEqual(restored.layoutPreset, .custom)
    }

    @MainActor
    func testQuickActionsCanBeAddedRenamedMovedAndRestored() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        settings.remove(.timer)
        settings.add(.ai, at: .leading)
        settings.rename(.ai, to: "Мои агенты")
        settings.remove(.sound)
        settings.move(.ai, to: .trailing)

        let restored = NotchCustomizationSettings(defaults: defaults)
        let action = restored.quickActions.first { $0.action == .ai }
        XCTAssertEqual(action?.placement, .trailing)
        XCTAssertEqual(action?.title, "Мои агенты")
        XCTAssertEqual(restored.actions(at: .leading).count, 1)
        XCTAssertEqual(restored.actions(at: .trailing).count, 2)
    }

    @MainActor
    func testActionCapacityAndDuplicateProtection() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        settings.remove(.timer)
        settings.add(.ai, at: .leading)
        settings.add(.ai, at: .trailing)
        settings.add(.jira, at: .leading)

        XCTAssertEqual(settings.actions(at: .leading).count, 2)
        XCTAssertEqual(settings.actions(at: .trailing).count, 2)
        XCTAssertEqual(settings.quickActions.filter { $0.action == .ai }.count, 1)
        XCTAssertFalse(settings.canAdd(.jira, at: .leading))
    }

    @MainActor
    func testBottomActionsHaveCapacityFourAndPersist() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        XCTAssertTrue(settings.actions(at: .bottom).isEmpty)

        for action in [NotchQuickActionID.ai, .live, .calendar, .music] {
            settings.add(action, at: .bottom)
        }
        XCTAssertEqual(settings.actions(at: .bottom).count, 4)
        XCTAssertFalse(settings.canAdd(.jira, at: .bottom))
        settings.add(.jira, at: .bottom)

        let restored = NotchCustomizationSettings(defaults: defaults)
        XCTAssertEqual(restored.actions(at: .bottom).map(\.action), [.ai, .live, .calendar, .music])
    }

    @MainActor
    func testQuickActionCanMoveToBottomWhenCapacityIsAvailable() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        settings.move(.timer, to: .bottom)
        XCTAssertEqual(settings.actions(at: .bottom).map(\.action), [.timer])
        XCTAssertEqual(settings.actions(at: .leading).map(\.action), [.modules])

        let restored = NotchCustomizationSettings(defaults: defaults)
        XCTAssertEqual(restored.actions(at: .bottom).map(\.action), [.timer])
        XCTAssertEqual(restored.actions(at: .leading).map(\.action), [.modules])
    }

    @MainActor
    func testCompactIndicatorAndHapticPreferencesPersist() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        settings.showsMusicIndicator = false
        settings.showsQuotaIndicator = false
        settings.showsQuotaWhenIdle = true
        settings.hapticsEnabled = false

        let restored = NotchCustomizationSettings(defaults: defaults)
        XCTAssertFalse(restored.showsMusicIndicator)
        XCTAssertFalse(restored.showsQuotaIndicator)
        XCTAssertTrue(restored.showsQuotaWhenIdle)
        XCTAssertFalse(restored.hapticsEnabled)
    }

    @MainActor
    func testCompactIndicatorChangesPublishLayoutUpdates() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        let layoutUpdate = expectation(description: "compact indicator changes update window layout")
        let subscription = settings.layoutChanges.sink { layoutUpdate.fulfill() }

        settings.showsQuotaWhenIdle = true

        wait(for: [layoutUpdate], timeout: 0.1)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testRemovingAllQuickActionsPublishesLayoutUpdate() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchCustomizationSettings(defaults: defaults)
        let layoutUpdate = expectation(description: "removing quick actions resizes the outer window")
        layoutUpdate.expectedFulfillmentCount = settings.quickActions.count
        let subscription = settings.layoutChanges.sink { layoutUpdate.fulfill() }

        for action in settings.quickActions.map(\.action) {
            settings.remove(action)
        }

        wait(for: [layoutUpdate], timeout: 0.1)
        XCTAssertTrue(settings.quickActions.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "NotchCustomizationSettingsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
