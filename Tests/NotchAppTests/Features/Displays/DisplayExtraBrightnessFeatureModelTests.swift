import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class DisplayExtraBrightnessFeatureModelTests: XCTestCase {
    func testModuleMustBeStartedAndStoppingReleasesActiveBoost() async {
        let f = Fixture()
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertTrue(f.extra.writes.isEmpty)
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertTrue(f.extra.active)
        XCTAssertEqual(f.extra.writes.map(\.enabled), [true])
        f.model.stop()
        XCTAssertFalse(f.extra.active)
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertEqual(f.extra.writes.count, 1)
        await f.cleanup()
    }

    func testSleepAndDisplaySleepNotificationsReleaseBoostWithoutSleepingTheMachine() async throws {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            await f.model.setExtraBrightness(true, for: f.display)
            XCTAssertTrue(f.extra.active)
            NSWorkspace.shared.notificationCenter.post(name: notification, object: nil)
            for _ in 0..<100 where f.extra.active { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(f.extra.active)
        }
        await f.cleanup()
    }

    func testStaleNumericIDCannotEnableBoostAfterSameUUIDRemaps() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        let remapped = f.remappedDisplay(id: 84)
        f.configuration.connected = [remapped]
        f.model.refresh()
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertTrue(f.extra.writes.isEmpty)
        await f.model.setExtraBrightness(true, for: remapped)
        XCTAssertEqual(f.extra.writes.map(\.target.displayID), [84])
        await f.cleanup()
    }

    func testRefreshReconcilesFreshTargetsAndExcludesDisabledDisplays() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.display)
        let remapped = f.remappedDisplay(id: 84)
        let disabled = DisplayInfo(id: "disabled", displayID: 99, name: "Disabled", isBuiltin: false,
            isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil, isEnabled: false)
        f.configuration.connected = [remapped, disabled]
        f.model.refresh()
        XCTAssertEqual(f.extra.reconciled.last, [DisplayHardwareTarget(uuid: remapped.id, displayID: 84, isBuiltin: remapped.isBuiltin)])
        XCTAssertFalse(f.extra.active, "The previous runtime target cannot retain its old surface")
        await f.cleanup()
    }

    func testModeTrialStopsBoostBeforeSynchronousConfigurationAndBlocksReenable() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.display)
        f.events.items.removeAll()
        f.model.request(.mode(displayID: f.display.displayID, modeID: 2), display: f.display)
        XCTAssertEqual(f.events.items.prefix(2), ["extra.stop", "config.apply"])
        XCTAssertFalse(f.extra.active)
        XCTAssertTrue(f.model.isPending)
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertEqual(f.extra.writes.count, 1)
        await f.cleanup()
    }

    func testHDRTrialStopsBoostBeforeNativeWriteAndBlocksReenable() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.display)
        f.events.items.removeAll()
        await f.model.requestHDR(true, for: f.display)
        XCTAssertTrue(f.model.isPending)
        XCTAssertFalse(f.extra.active)
        XCTAssertEqual(f.events.items.prefix(2), ["extra.stop", "hdr.write"])
        await f.model.setExtraBrightness(true, for: f.display)
        XCTAssertEqual(f.extra.writes.count, 1)
        await f.cleanup()
    }

    func testArrangementStopsBoostBeforeGeometryChanges() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        let other = DisplayInfo(id: "other", displayID: 1, name: "Other", isBuiltin: true,
            isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil,
            frame: CGRect(x: 2560, y: 0, width: 1800, height: 1200))
        f.configuration.connected.append(other)
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.display)
        f.events.items.removeAll()
        f.model.requestArrangement([DisplayPlacement(uuid: f.display.id, origin: .zero),
            DisplayPlacement(uuid: other.id, origin: CGPoint(x: 2560, y: 0))])
        XCTAssertEqual(f.events.items.prefix(2), ["extra.stop", "config.apply"])
        XCTAssertFalse(f.extra.active)
        await f.cleanup()
    }

    @MainActor
    private final class Fixture {
        let suite = "DisplayExtraBrightnessFeatureModelTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let display: DisplayInfo
        let events = ExtraModelEvents()
        let extra: ExtraModelService
        let configuration: ExtraModelConfiguration
        let controller = DisplayRevertController(showsWindow: false)
        let model: DisplayFeatureModel

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let a = DisplayModeOption(id: 1, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 120)
            let b = DisplayModeOption(id: 2, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
            display = DisplayInfo(id: "extra-screen", displayID: 42, name: "Fixture", isBuiltin: false,
                isMain: true, mirrorMasterID: nil, modes: [a, b], currentMode: a,
                frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
            extra = ExtraModelService(events: events)
            configuration = ExtraModelConfiguration(display: display, events: events)
            model = DisplayFeatureModel(service: configuration, brightness: ExtraModelGamma(), defaults: defaults,
                revertController: controller,
                systemSettings: DisplaySystemSettingsModel(service: UnavailableDisplaySystemSettingsService()),
                hdr: ExtraModelHDR(events: events), extraBrightness: extra)
        }

        func remappedDisplay(id: UInt32) -> DisplayInfo {
            DisplayInfo(id: display.id, displayID: id, name: display.name, isBuiltin: display.isBuiltin,
                isMain: display.isMain, mirrorMasterID: nil, modes: display.modes,
                currentMode: display.currentMode, frame: display.frame)
        }

        func cleanup() async {
            model.stop()
            await model.waitForOperations()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }

        func scheduleCleanup() { Task { await cleanup() } }
    }
}

@MainActor
private final class ExtraModelEvents {
    var items: [String] = []
    func record(_ event: String) { items.append(event) }
}

@MainActor
private final class ExtraModelService: DisplayExtraBrightnessServing {
    var onStateChange: (@MainActor () -> Void)?
    var active = false
    var writes: [(enabled: Bool, target: DisplayHardwareTarget)] = []
    var reconciled: [[DisplayHardwareTarget]] = []
    private let events: ExtraModelEvents
    init(events: ExtraModelEvents) { self.events = events }
    func capability(for target: DisplayHardwareTarget) -> DisplayExtraBrightnessCapability {
        .init(isSupported: true, isEnabled: active, unavailableReason: nil)
    }
    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) throws {
        writes.append((enabled, target))
        active = enabled
        onStateChange?()
    }
    func stop() { events.record("extra.stop"); active = false; onStateChange?() }
    func reconcile(_ targets: [DisplayHardwareTarget]) {
        if let previous = reconciled.last, previous != targets { active = false }
        reconciled.append(targets)
        onStateChange?()
    }
}

@MainActor
private final class ExtraModelConfiguration: DisplayConfigurationServing {
    var connected: [DisplayInfo]
    private let original: DisplayInfo
    private let events: ExtraModelEvents
    init(display: DisplayInfo, events: ExtraModelEvents) { connected = [display]; original = display; self.events = events }
    func displays() throws -> [DisplayInfo] { connected }
    func apply(_ change: DisplayChange, permanently: Bool) throws { events.record("config.apply") }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        .init(entries: connected.map { .init(displayID: $0.displayID, uuid: $0.id, mode: nil,
            origin: $0.frame.origin, mirrorMasterID: nil, mirrorMasterUUID: nil) })
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws { connected = [original] }
}

@MainActor
private final class ExtraModelGamma: DisplayBrightnessServing {
    func setDimming(_ factor: Double, displayID: UInt32) throws {}
    func invalidate() {}
    func restore() {}
}

private actor ExtraModelHDR: DisplayHDRServing {
    private var value = false
    private let events: ExtraModelEvents
    init(events: ExtraModelEvents) { self.events = events }
    func read(_ target: DisplayHardwareTarget) async throws -> Bool? { value }
    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        await events.record("hdr.write")
        value = enabled
        return enabled
    }
}
