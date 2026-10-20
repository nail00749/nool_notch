import XCTest
@testable import NotchApp

@MainActor
final class DisplayFeatureModelTests: XCTestCase {
    func testSystemSettingsCannotWriteDuringDisplayTrialOrAfterModuleStops() async {
        let driver = FeatureSystemSettingsService()
        let system = DisplaySystemSettingsModel(service: driver)
        let fixture = makeFixture(systemSettings: system)
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        await system.setDarkMode(false)
        var count = await driver.writeCount
        XCTAssertEqual(count, 0)
        fixture.model.cancelChange()
        await system.setDarkMode(false)
        count = await driver.writeCount
        XCTAssertEqual(count, 1)
        fixture.model.stop()
        await system.setNightShift(true)
        count = await driver.writeCount
        XCTAssertEqual(count, 1)
    }

    func testImageAdjustmentComposesWithDimmingPersistsAndResetKeepsBrightness() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.setDimming(0.6, for: fixture.display)
        var correction = DisplayImageAdjustment.neutral
        correction.gamma = 1.3
        correction.temperature = 0.4
        fixture.model.setImageAdjustment(correction, for: fixture.display)
        XCTAssertEqual(fixture.brightness.appearances.last?.adjustment, correction)
        XCTAssertEqual(fixture.brightness.appearances.last?.factor, 0.6)
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        let stored = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertEqual(stored.imageAdjustmentsByUUID?[fixture.display.id], correction)
        fixture.model.setDimming(0.4, for: fixture.display)
        XCTAssertEqual(fixture.brightness.appearances.last?.adjustment, correction)
        fixture.model.setImageAdjustment(.neutral, for: fixture.display)
        XCTAssertEqual(fixture.brightness.appearances.last?.factor, 0.4)
        XCTAssertEqual(fixture.model.imageAdjustment(for: fixture.display), .neutral)
    }

    func testImageAdjustmentRejectsStaleDisplayAndPendingConfiguration() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        let count = fixture.brightness.appearances.count
        var correction = DisplayImageAdjustment.neutral
        correction.contrast = 1.4
        fixture.model.setImageAdjustment(correction, for: fixture.display)
        XCTAssertEqual(fixture.brightness.appearances.count, count)
        XCTAssertEqual(fixture.model.imageAdjustment(for: fixture.display), .neutral)
    }

    func testModeTrialIsTemporaryUntilConfirmedAndThenPersistsSemanticMode() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)

        XCTAssertEqual(fixture.service.applied.map(\.permanently), [false])
        XCTAssertTrue(fixture.model.isPending)
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertNil(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))

        fixture.controller.confirm()

        XCTAssertEqual(fixture.service.applied.map(\.permanently), [false, true])
        XCTAssertEqual(fixture.service.applied.map(\.change), [fixture.change, fixture.change])
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertEqual(fixture.service.restored.count, 0)
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        let stored = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertTrue(try XCTUnwrap(stored.modesByUUID[fixture.display.id]).matches(fixture.display.modes[1]))
    }

    func testCancelRestoresSnapshotAndDoesNotPersistTrialMode() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        fixture.controller.revert()

        XCTAssertEqual(fixture.service.applied.map(\.permanently), [false])
        XCTAssertEqual(fixture.service.restored.first?.entries.map(\.uuid), [fixture.display.id])
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertNil(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
    }

    func testDisappearedTrialDisplayRestoresSurvivorsAndClosesConfirmation() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        fixture.service.connectedDisplays = []
        fixture.model.refresh()

        XCTAssertEqual(fixture.service.restored.count, 1)
        XCTAssertEqual(fixture.service.restored[0].entries.map(\.uuid), [fixture.display.id])
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertTrue(fixture.model.displays.isEmpty)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testPermanentConfigurationFailureRestoresTrialAndReportsFailure() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        fixture.service.failPermanentApply = true
        fixture.controller.confirm()

        XCTAssertEqual(fixture.service.applied.map(\.permanently), [false, true])
        XCTAssertEqual(fixture.service.restored.count, 1)
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertEqual(fixture.model.errorMessage, "Permanent configuration failed")
        XCTAssertNil(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
    }

    func testDisablingModuleRestoresPendingConfigurationAndGamma() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.setDimming(0.4, for: fixture.display)
        fixture.model.request(fixture.change, display: fixture.display)
        fixture.model.stop()

        XCTAssertEqual(fixture.service.restored.count, 1)
        XCTAssertEqual(fixture.brightness.restoreCount, 1)
        XCTAssertFalse(fixture.model.enabled)
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertTrue(fixture.model.displays.isEmpty)

        fixture.model.request(fixture.change, display: fixture.display)
        fixture.model.setDimming(0.2, for: fixture.display)
        XCTAssertEqual(fixture.service.applied.count, 1)
        XCTAssertEqual(fixture.brightness.applied.last?.factor, 0.4)
    }

    func testStaleTargetModeAndMismatchedChangeAreRejectedBeforeSnapshot() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(.mode(displayID: fixture.display.displayID, modeID: 999), display: fixture.display)
        fixture.model.request(.main(displayID: 999), display: fixture.display)
        fixture.model.request(.mirror(displayID: fixture.display.displayID, masterID: 999), display: fixture.display)
        fixture.model.request(.mirror(displayID: fixture.display.displayID, masterID: fixture.display.displayID), display: fixture.display)

        // A reconnected screen can reuse the numeric ID, but its UUID is still the boundary.
        fixture.service.connectedDisplays = [DisplayInfo(
            id: "replacement-uuid", displayID: fixture.display.displayID, name: "Replacement",
            isBuiltin: false, isMain: true, mirrorMasterID: nil,
            modes: fixture.display.modes, currentMode: fixture.display.currentMode
        )]
        fixture.model.refresh()
        fixture.model.request(fixture.change, display: fixture.display)

        XCTAssertTrue(fixture.service.applied.isEmpty)
        XCTAssertEqual(fixture.service.snapshotCount, 0)
        XCTAssertFalse(fixture.model.isPending)
    }

    func testLastIndependentDisplayCannotBeDisabledEvenWithMirrorFollower() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.service.supportsDisplayPower = true
        fixture.service.connectedDisplays.append(DisplayInfo(
            id: "mirror", displayID: 43, name: "Mirror", isBuiltin: false, isMain: false,
            mirrorMasterID: fixture.display.displayID, modes: [], currentMode: nil))
        fixture.model.start()

        XCTAssertFalse(fixture.model.canTogglePower(for: fixture.display))
        fixture.model.setDisplayEnabled(false, for: fixture.display)
        XCTAssertTrue(fixture.service.applied.isEmpty)
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertNotNil(fixture.model.errorMessage)
    }

    func testPowerTrialKeepsDisabledDisplayAndCanBeConfirmedOrReenabled() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.service.supportsDisplayPower = true
        fixture.service.mutatesPower = true
        let second = DisplayInfo(id: "second", displayID: 43, name: "Second", isBuiltin: true,
                                 isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil)
        fixture.service.connectedDisplays.append(second)
        fixture.model.start()
        fixture.model.setDisplayEnabled(false, for: fixture.display)

        XCTAssertTrue(fixture.model.isPending)
        XCTAssertFalse(fixture.model.displays.first(where: { $0.id == fixture.display.id })!.isEnabled)
        fixture.controller.confirm()
        XCTAssertFalse(fixture.model.isPending)
        let disabled = fixture.model.displays.first(where: { $0.id == fixture.display.id })!
        XCTAssertTrue(fixture.model.canTogglePower(for: disabled))
        let brightnessCalls = fixture.brightness.applied.count
        fixture.model.setDimming(0.2, for: disabled)
        fixture.model.refreshBrightness()
        XCTAssertEqual(fixture.brightness.applied.count, brightnessCalls)

        fixture.model.setDisplayEnabled(true, for: disabled)
        XCTAssertTrue(fixture.model.isPending)
        fixture.controller.confirm()
        XCTAssertTrue(fixture.model.displays.first(where: { $0.id == disabled.id })!.isEnabled)
    }

    func testArrangementSavesImmediatelyWithoutConfirmationAndRejectsStaleTopology() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let second = DisplayInfo(id: "second", displayID: 43, name: "Second", isBuiltin: true,
                                 isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil)
        fixture.service.connectedDisplays.append(second)
        fixture.model.start()
        let placement = [DisplayPlacement(uuid: fixture.display.id, origin: .zero),
                         DisplayPlacement(uuid: second.id, origin: CGPoint(x: 2560, y: 0))]
        fixture.model.requestArrangement([placement[0]])
        XCTAssertTrue(fixture.service.applied.isEmpty)

        fixture.model.requestArrangement(placement)
        XCTAssertEqual(fixture.service.applied.last?.change, .arrangement(placement))
        XCTAssertTrue(fixture.service.applied.last!.permanently)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertFalse(fixture.model.isPending)
        fixture.service.connectedDisplays = [fixture.display]
        fixture.model.refresh()
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertEqual(fixture.service.restored.count, 0)

        // The view still has the previous list until refresh, but apply must use live identities.
        fixture.service.connectedDisplays = [fixture.display, second]
        fixture.model.refresh()
        fixture.service.connectedDisplays = [fixture.display]
        fixture.model.requestArrangement(placement)
        XCTAssertEqual(fixture.service.applied.count, 1)
    }

    func testFailedArrangementSaveRestoresOriginalWithoutConfirmation() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.service.connectedDisplays.append(DisplayInfo(id: "second", displayID: 43, name: "Second",
            isBuiltin: true, isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil))
        fixture.service.failPermanentApply = true
        fixture.model.start()
        fixture.model.isArranging = true
        fixture.model.requestArrangement([.init(uuid: fixture.display.id, origin: .zero),
                                          .init(uuid: "second", origin: CGPoint(x: 2560, y: 0))])
        XCTAssertEqual(fixture.service.restored.count, 1)
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertTrue(fixture.model.isArranging)
        XCTAssertNotNil(fixture.model.errorMessage)
    }

    func testStopRestoresManagedPowerAndUnsupportedBackendRejectsPowerCommands() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        XCTAssertFalse(fixture.model.canTogglePower(for: fixture.display))
        fixture.model.setDisplayEnabled(false, for: fixture.display)
        XCTAssertTrue(fixture.service.applied.isEmpty)
        fixture.model.stop()
        XCTAssertEqual(fixture.service.managedRestores, 1)
    }

    func testFailedRollbackRetainsSnapshotForExplicitRetry() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        fixture.model.request(fixture.change, display: fixture.display)
        fixture.service.failRestore = true
        fixture.controller.revert()
        XCTAssertTrue(fixture.model.isPending)
        XCTAssertTrue(fixture.model.rollbackFailed)
        XCTAssertFalse(fixture.controller.isPresented)
        fixture.service.failRestore = false
        fixture.model.cancelChange()
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.model.rollbackFailed)
        XCTAssertEqual(fixture.service.restored.count, 2)
    }

    func testPowerTrialAllowsSameUUIDToReceiveNewNumericDisplayID() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.service.supportsDisplayPower = true
        fixture.service.mutatesPower = true
        fixture.service.connectedDisplays.append(DisplayInfo(
            id: "second", displayID: 43, name: "Second", isBuiltin: true,
            isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil))
        fixture.model.start()
        fixture.model.setDisplayEnabled(false, for: fixture.display)
        fixture.service.connectedDisplays = fixture.service.connectedDisplays.map {
            DisplayInfo(id: $0.id, displayID: $0.id == fixture.display.id ? 99 : $0.displayID,
                        name: $0.name, isBuiltin: $0.isBuiltin, isMain: $0.isMain,
                        mirrorMasterID: $0.mirrorMasterID, modes: $0.modes, currentMode: $0.currentMode,
                        frame: $0.frame, isEnabled: $0.isEnabled)
        }
        fixture.model.refresh()
        XCTAssertTrue(fixture.model.isPending)
        fixture.controller.confirm()
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertEqual(fixture.service.applied.last?.change, .enabled(displayID: 99, enabled: false))
        XCTAssertTrue(fixture.service.restored.isEmpty)
    }

    func testScreenParameterBurstRefreshesOnlyWhenDisplayConfigurationChanges() async throws {
        let notifications = NotificationCenter()
        var signature = DisplayScreenSignature(entries: [])
        let fixture = makeFixture(notifications: notifications, screenSignature: { signature })
        defer { fixture.cleanup() }
        fixture.model.start()
        let reads = fixture.service.displayReads
        let writes = fixture.brightness.appearances.count

        // A gamma write posts the notification again; an unchanged configuration ends the loop.
        for _ in 0..<5 { notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.service.displayReads, reads)
        XCTAssertEqual(fixture.brightness.appearances.count, writes)

        signature = DisplayScreenSignature(entries: [.init(
            displayID: 42, isActive: true, isMain: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            mirrorMasterID: 0, modeID: 2, pixelSize: CGSize(width: 3840, height: 2160), refreshRate: 60,
            rotation: 0, colorSpace: nil)])
        for _ in 0..<5 { notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.service.displayReads, reads + 1)
        XCTAssertEqual(fixture.brightness.appearances.count, writes + 1)
    }

    private func makeFixture(systemSettings: DisplaySystemSettingsModel? = nil,
                             notifications: NotificationCenter = NotificationCenter(),
                             screenSignature: @escaping () -> DisplayScreenSignature = { DisplayScreenSignature(entries: []) }) -> Fixture {
        let suiteName = "DisplayFeatureModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let modes = [
            DisplayModeOption(id: 1, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60),
            DisplayModeOption(id: 2, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        ]
        let display = DisplayInfo(id: "screen-uuid", displayID: 42, name: "Test display",
                                  isBuiltin: false, isMain: true, mirrorMasterID: nil,
                                  modes: modes, currentMode: modes[0])
        let service = FakeDisplayConfigurationService(display: display)
        let brightness = FakeDisplayBrightnessService()
        let controller = DisplayRevertController(showsWindow: false)
        let model = DisplayFeatureModel(service: service, brightness: brightness,
                                        defaults: defaults, revertController: controller, systemSettings: systemSettings,
                                        notifications: notifications, screenSignature: screenSignature,
                                        screenChangeDelay: .milliseconds(20))
        return Fixture(model: model, service: service, brightness: brightness, controller: controller,
                       defaults: defaults, suiteName: suiteName, display: display)
    }

    @MainActor
    private struct Fixture {
        let model: DisplayFeatureModel
        let service: FakeDisplayConfigurationService
        let brightness: FakeDisplayBrightnessService
        let controller: DisplayRevertController
        let defaults: UserDefaults
        let suiteName: String
        let display: DisplayInfo
        var change: DisplayChange { .mode(displayID: display.displayID, modeID: display.modes[1].id) }

        func cleanup() {
            model.stop()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private actor FeatureSystemSettingsService: DisplaySystemSettingsServing {
    private(set) var writeCount = 0
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? { false }
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        writeCount += 1
        return enabled
    }
}

@MainActor
private final class FakeDisplayConfigurationService: DisplayConfigurationServing {
    struct Applied {
        let change: DisplayChange
        let permanently: Bool
    }
    var connectedDisplays: [DisplayInfo]
    var applied: [Applied] = []
    var restored: [DisplayConfigurationSnapshot] = []
    var snapshotCount = 0
    var failPermanentApply = false
    var failRestore = false
    var supportsDisplayPower = false
    var mutatesPower = false
    var managedRestores = 0

    var displayReads = 0

    init(display: DisplayInfo) { connectedDisplays = [display] }
    func displays() throws -> [DisplayInfo] { displayReads += 1; return connectedDisplays }
    func apply(_ change: DisplayChange, permanently: Bool) throws {
        applied.append(Applied(change: change, permanently: permanently))
        if permanently, failPermanentApply { throw Failure() }
        if mutatesPower, case let .enabled(id, enabled) = change {
            connectedDisplays = connectedDisplays.map {
                DisplayInfo(id: $0.id, displayID: $0.displayID, name: $0.name, isBuiltin: $0.isBuiltin,
                            isMain: $0.isMain, mirrorMasterID: $0.mirrorMasterID, modes: $0.modes,
                            currentMode: $0.currentMode, frame: $0.frame,
                            isEnabled: $0.displayID == id ? enabled : $0.isEnabled)
            }
        }
    }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        snapshotCount += 1
        return DisplayConfigurationSnapshot(entries: connectedDisplays.map {
            .init(displayID: $0.displayID, uuid: $0.id, mode: nil, origin: .zero,
                  mirrorMasterID: nil, mirrorMasterUUID: nil)
        })
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {
        restored.append(snapshot)
        if failRestore { throw Failure() }
    }
    func restoreManagedDisplays() throws { managedRestores += 1 }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Permanent configuration failed" }
    }
}

@MainActor
private final class FakeDisplayBrightnessService: DisplayBrightnessServing {
    var applied: [(factor: Double, displayID: UInt32)] = []
    var appearances: [(factor: Double, adjustment: DisplayImageAdjustment)] = []
    var restoreCount = 0
    func setDimming(_ factor: Double, displayID: UInt32) throws { applied.append((factor, displayID)) }
    func setAppearance(dimming: Double, adjustment: DisplayImageAdjustment, displayID: UInt32) throws {
        appearances.append((dimming, adjustment))
        try setDimming(dimming, displayID: displayID)
    }
    func restore() { restoreCount += 1 }
    func invalidate() {}
}
