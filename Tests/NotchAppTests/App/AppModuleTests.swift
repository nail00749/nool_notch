import Combine
import XCTest
@testable import NotchApp

@MainActor
final class AppModuleTests: XCTestCase {
    func testCatalogPersistsOnlyAvailabilityAndPreservesUnknownFutureIDs() throws {
        let name = "NooLModulesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("saved-account", forKey: "fixture.feature.preferences")
        defaults.set(["futureModule"], forKey: AppModuleStore.disabledKey)
        let store = AppModuleStore(defaults: defaults)
        XCTAssertEqual(store.enabledModules, Set(AppModuleID.allCases))
        store.setEnabled(.jira, enabled: false)
        store.setEnabled(.clipboard, enabled: false)
        let restored = AppModuleStore(defaults: defaults)
        XCTAssertFalse(restored.isEnabled(.jira))
        XCTAssertFalse(restored.isEnabled(.clipboard))
        restored.setEnabled(.jira, enabled: true)
        XCTAssertTrue(AppModuleStore(defaults: defaults).isEnabled(.jira))
        XCTAssertEqual(defaults.string(forKey: "fixture.feature.preferences"), "saved-account")
        XCTAssertTrue(defaults.stringArray(forKey: AppModuleStore.disabledKey)?.contains("futureModule") == true)
    }

    func testPresetEmitsOneCoherentChangeAndAllModulesCanBeDisabled() {
        let store = AppModuleStore(defaults: nil)
        var values: [Set<AppModuleID>] = []
        let subscription = store.changes.sink { next in
            XCTAssertEqual(next, store.enabledModules)
            values.append(next)
        }
        store.applyPreset(.monitoring)
        store.applyPreset(.monitoring)
        XCTAssertEqual(values, [AppModulePreset.monitoring.modules])
        for module in AppModuleID.allCases { store.setEnabled(module, enabled: false) }
        XCTAssertTrue(store.enabledModules.isEmpty)
        store.applyPreset(.all)
        XCTAssertEqual(store.enabledModules, Set(AppModuleID.allCases))
        withExtendedLifetime(subscription) {}
    }

    func testRuntimeSkipsColdDisabledAndBalancesStartsStops() {
        let store = AppModuleStore(defaults: nil)
        store.setEnabled(.music, enabled: false)
        let runtime = AppModuleRuntime(store: store)
        var events: [String] = []
        runtime.register(.music, start: { events.append("music+") }, stop: { events.append("music-") })
        runtime.register(.jira, start: { events.append("jira+") }, stop: { events.append("jira-") })
        runtime.start()
        runtime.start()
        XCTAssertEqual(events, ["jira+"])
        store.applyPreset(.minimal)
        XCTAssertEqual(events, ["jira+", "jira-", "music+"])
        store.setEnabled(.music, enabled: true)
        runtime.stop()
        runtime.stop()
        XCTAssertEqual(events, ["jira+", "jira-", "music+", "music-"])
        store.setEnabled(.jira, enabled: true)
        XCTAssertEqual(events.count, 4, "Stopped owners cannot restart through retained subscriptions")
        runtime.start()
        XCTAssertEqual(Array(events.suffix(2)), ["music+", "jira+"])
        runtime.stop()
    }

    func testDockFiltersDisabledProvidersWithoutRemovingSavedItems() {
        let modules = AppModuleStore(defaults: nil)
        let items = NoolDockItemKind.allCases.map {
            NoolDockItem(id: $0.rawValue, kind: $0, applicationPath: nil, title: $0.title, size: .regular)
        }
        modules.setEnabled(.music, enabled: false)
        modules.setEnabled(.calendar, enabled: false)
        modules.setEnabled(.liveActivities, enabled: false)
        XCTAssertEqual(items.filter { $0.isAvailable(in: modules) }.map(\.kind), [.app, .note])
        modules.applyPreset(.all)
        XCTAssertEqual(items.filter { $0.isAvailable(in: modules) }, items)
    }
}
