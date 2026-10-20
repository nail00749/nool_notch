import XCTest
@testable import NotchApp

@MainActor
final class DisplayPresetModelTests: XCTestCase {
    func testCreateRenameDeletePersistAndCaptureStableUUIDSemanticModeAndProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        fixture.model.setDimming(0.72, for: fixture.display)
        var correction = DisplayImageAdjustment.neutral
        correction.gamma = 1.2
        fixture.model.setImageAdjustment(correction, for: fixture.display)
        await fixture.model.savePreset(named: "  Работа  ")
        let preset = try XCTUnwrap(fixture.model.presets.first)
        XCTAssertEqual(preset.name, "Работа")
        let entry = try XCTUnwrap(preset.displays.first)
        XCTAssertEqual(entry.stableUUID, fixture.display.id)
        XCTAssertTrue(try XCTUnwrap(entry.mode).matches(try XCTUnwrap(fixture.display.currentMode)))
        XCTAssertEqual(entry.brightness, 0.72, accuracy: 0.001)
        XCTAssertEqual(entry.colorProfileID, "srgb")
        XCTAssertEqual(entry.imageAdjustment, correction)
        XCTAssertEqual(DisplayPresetStore(defaults: fixture.defaults).load(), [preset])
        let data = try XCTUnwrap(fixture.defaults.data(forKey: DisplayPresetStore.key))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("displayID"))

        fixture.model.renamePreset(id: preset.id, to: "  Вечер  ")
        XCTAssertEqual(DisplayPresetStore(defaults: fixture.defaults).load().first?.name, "Вечер")
        fixture.model.deletePreset(id: preset.id)
        XCTAssertTrue(DisplayPresetStore(defaults: fixture.defaults).load().isEmpty)
        await fixture.cleanup()
    }

    func testLegacyPreferencesRemainReadableAndAreCapturedWithoutLosingSoftwareChoice() async throws {
        let legacy = Data("""
        {"defaultDimming":1,"restoreModesOnReconnect":false,"dimmingByUUID":{"preset-screen":0.42},"modesByUUID":{}}
        """.utf8)
        let fixture = try makeFixture(legacyPreferences: legacy)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        XCTAssertTrue(fixture.model.presets.isEmpty)
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.42, accuracy: 0.001)
        await fixture.model.savePreset(named: "Legacy")
        let entry = try XCTUnwrap(fixture.model.presets.first?.displays.first)
        XCTAssertEqual(entry.brightness, 0.42, accuracy: 0.001)
        XCTAssertTrue(entry.useSoftwareBrightness)
        let migrated = try persistedPreferences(fixture)
        XCTAssertEqual(migrated.defaultDimming, 1)
        XCTAssertEqual(migrated.dimmingByUUID[fixture.display.id], 0.42)
        XCTAssertFalse(migrated.restoreModesOnReconnect)
        XCTAssertTrue(migrated.softwareBrightnessUUIDs?.contains(fixture.display.id) == true)
        await fixture.cleanup()
    }

    func testApplyIsTemporaryUntilConfirmationCommitsPermanently() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))

        XCTAssertEqual(fixture.configuration.applied.map(\.permanently), [false])
        XCTAssertEqual(fixture.profiles.selectedID, "p3")
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.25, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isPending)
        XCTAssertTrue(fixture.controller.isPresented)
        fixture.controller.confirm()
        await fixture.model.waitForOperations()

        XCTAssertEqual(fixture.configuration.applied.map(\.permanently), [false, true])
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertEqual(fixture.configuration.restoreCount, 0)
        let saved = try persistedPreferences(fixture)
        XCTAssertEqual(try XCTUnwrap(saved.dimmingByUUID[fixture.display.id]), 0.25, accuracy: 0.001)
        await fixture.cleanup()
    }

    func testCancelRestoresConfigurationProfileAndBrightnessPreferences() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        fixture.model.setDimming(0.8, for: fixture.display)
        var correction = DisplayImageAdjustment.neutral
        correction.temperature = 0.5
        fixture.model.setImageAdjustment(correction, for: fixture.display)
        let original = try persistedPreferences(fixture)
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))
        fixture.controller.revert()
        await fixture.model.waitForOperations()

        XCTAssertEqual(fixture.configuration.restoreCount, 1)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.8, accuracy: 0.001)
        XCTAssertEqual(fixture.gamma.applied.last?.value, 0.8)
        let restored = try persistedPreferences(fixture)
        XCTAssertEqual(restored.dimmingByUUID, original.dimmingByUUID)
        XCTAssertEqual(restored.softwareBrightnessUUIDs, original.softwareBrightnessUUIDs)
        XCTAssertEqual(fixture.model.imageAdjustment(for: fixture.display), correction)
        XCTAssertFalse(fixture.model.isPending)
        await fixture.cleanup()
    }

    func testUnavailableColorProfileRejectsPresetBeforeConfigurationChanges() async throws {
        let fixture = try makeFixture(includePreset: true, presetProfileID: "missing-profile")
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))

        XCTAssertTrue(fixture.configuration.applied.isEmpty)
        XCTAssertEqual(fixture.configuration.restoreCount, 0)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertNotNil(fixture.model.errorMessage)
        await fixture.cleanup()
    }

    func testConfigurationFailureRollsBackCapturedSnapshotAndAppearance() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.configuration.failTrial = true
        fixture.model.start()
        fixture.model.setDimming(0.8, for: fixture.display)
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))

        XCTAssertEqual(fixture.configuration.applied.map(\.permanently), [false])
        XCTAssertEqual(fixture.configuration.restoreCount, 1)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.8, accuracy: 0.001)
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.model.isApplyingPreset)
        XCTAssertNotNil(fixture.model.errorMessage)
        await fixture.cleanup()
    }

    func testPermanentConfigurationFailureRollsBackTrial() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.configuration.failPermanent = true
        fixture.model.start()
        fixture.model.setDimming(0.8, for: fixture.display)
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))
        fixture.controller.confirm()
        await fixture.model.waitForOperations()

        XCTAssertEqual(fixture.configuration.applied.map(\.permanently), [false, true])
        XCTAssertEqual(fixture.configuration.restoreCount, 1)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.8, accuracy: 0.001)
        XCTAssertFalse(fixture.model.isPending)
        await fixture.cleanup()
    }

    func testStoppingDuringAsyncProfileChangeRestoresOriginalAfterOperationFinishes() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        fixture.model.setDimming(0.8, for: fixture.display)
        fixture.profiles.holdNextSet = true
        let presetID = try XCTUnwrap(fixture.model.presets.first?.id)
        let applying = Task { await fixture.model.applyPreset(id: presetID) }
        for _ in 0..<100 where fixture.profiles.pendingSet == nil { await Task.yield() }
        XCTAssertNotNil(fixture.profiles.pendingSet)
        XCTAssertTrue(fixture.model.isApplyingPreset)
        fixture.model.stop()
        fixture.profiles.completeSet()
        await applying.value
        await fixture.model.waitForOperations()

        XCTAssertEqual(fixture.configuration.restoreCount, 1)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertFalse(fixture.model.enabled)
        XCTAssertFalse(fixture.model.isApplyingPreset)
        XCTAssertFalse(fixture.model.isPending)
        let saved = try persistedPreferences(fixture)
        XCTAssertEqual(try XCTUnwrap(saved.dimmingByUUID[fixture.display.id]), 0.8, accuracy: 0.001)
        await fixture.cleanup()
    }

    func testStoppingStandaloneProfileSelectionRestoresOriginalWithoutConfigurationMutation() async throws {
        let fixture = try makeFixture()
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.refreshColorProfiles()
        XCTAssertEqual(fixture.model.currentColorProfileID(for: fixture.display), "srgb")
        fixture.profiles.holdNextSet = true
        let selecting = Task { await fixture.model.selectColorProfile("p3", for: fixture.display) }
        for _ in 0..<100 where fixture.profiles.pendingSet == nil { await Task.yield() }
        XCTAssertNotNil(fixture.profiles.pendingSet)
        fixture.model.stop()
        fixture.profiles.completeSet()
        await selecting.value
        await fixture.model.waitForOperations()

        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        XCTAssertTrue(fixture.configuration.applied.isEmpty)
        XCTAssertEqual(fixture.configuration.restoreCount, 0)
        XCTAssertFalse(fixture.model.enabled)
        await fixture.cleanup()
    }

    private func persistedPreferences(_ fixture: Fixture) throws -> DisplayPreferences {
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        return try JSONDecoder().decode(DisplayPreferences.self, from: data)
    }

    func testRollbackEnumerationFailureKeepsRecoveryForRetry() async throws {
        let fixture = try makeFixture(includePreset: true)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))
        fixture.configuration.failDisplays = true
        fixture.controller.revert()
        await fixture.model.waitForOperations()
        XCTAssertTrue(fixture.model.isPending)
        XCTAssertTrue(fixture.model.rollbackFailed)
        fixture.configuration.failDisplays = false
        fixture.model.cancelChange()
        await fixture.model.waitForOperations()
        XCTAssertFalse(fixture.model.isPending)
        XCTAssertFalse(fixture.model.rollbackFailed)
        XCTAssertEqual(fixture.profiles.selectedID, "srgb")
        await fixture.cleanup()
    }

    func testHardwarePresetResolvesBackendInsteadOfUsingGammaWhenCacheIsCold() async throws {
        let hardware = PresetModelHardware()
        let fixture = try makeFixture(includePreset: true, presetUsesSoftware: false, hardware: hardware)
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.applyPreset(id: try XCTUnwrap(fixture.model.presets.first?.id))
        XCTAssertTrue(fixture.model.isPending)
        let writes = await hardware.writes
        XCTAssertEqual(writes, [0.25])
        XCTAssertTrue(fixture.model.isHardwareBrightness(for: fixture.display))
        fixture.controller.revert()
        await fixture.model.waitForOperations()
        let restored = await hardware.current()
        XCTAssertEqual(restored, 0.8)
        await fixture.cleanup()
    }

    func testSavingColdHardwareDisplayReadsActualBrightnessAndKeepsBackendChoice() async throws {
        let fixture = try makeFixture(hardware: PresetModelHardware())
        defer { fixture.scheduleCleanup() }
        fixture.model.start()
        await fixture.model.savePreset(named: "Current")
        let saved = try XCTUnwrap(fixture.model.presets.first?.displays.first)
        XCTAssertEqual(saved.brightness, 0.8, accuracy: 0.001)
        XCTAssertFalse(saved.useSoftwareBrightness)
        await fixture.cleanup()
    }

    private func makeFixture(includePreset: Bool = false, presetProfileID: String = "p3",
                             legacyPreferences: Data? = nil, presetUsesSoftware: Bool = true,
                             hardware: (any DisplayHardwareBrightnessServing)? = nil) throws -> Fixture {
        let suite = "DisplayPresetModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let legacyPreferences { defaults.set(legacyPreferences, forKey: UserDefaultsAppPreferences.displayManagementKey) }
        let mode = DisplayModeOption(id: 42, width: 2560, height: 1440,
                                     pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
        let display = DisplayInfo(id: "preset-screen", displayID: 1234, name: "Fixture display", isBuiltin: false,
                                  isMain: true, mirrorMasterID: nil, modes: [mode], currentMode: mode,
                                  frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        if includePreset {
            try DisplayPresetStore(defaults: defaults).save([DisplayPreset(name: "Evening", displays: [
                DisplayPresetEntry(stableUUID: display.id, mode: SavedDisplayMode(mode), isMain: true,
                                   brightness: 0.25, useSoftwareBrightness: presetUsesSoftware, colorProfileID: presetProfileID)
            ])])
        }
        let configuration = PresetModelConfigurationService(display: display)
        let gamma = PresetModelGammaService()
        let profiles = PresetModelColorProfiles()
        let controller = DisplayRevertController(showsWindow: false)
        let model = DisplayFeatureModel(service: configuration, brightness: gamma, defaults: defaults,
                                        revertController: controller, hardware: hardware, colorProfiles: profiles)
        return Fixture(model: model, display: display, configuration: configuration, gamma: gamma,
                       profiles: profiles, controller: controller, defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let model: DisplayFeatureModel
        let display: DisplayInfo
        let configuration: PresetModelConfigurationService
        let gamma: PresetModelGammaService
        let profiles: PresetModelColorProfiles
        let controller: DisplayRevertController
        let defaults: UserDefaults
        let suite: String
        func cleanup() async {
            model.stop()
            profiles.completeSet()
            await model.waitForOperations()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        func scheduleCleanup() {
            model.stop()
            profiles.completeSet()
            controller.dismiss()
            Task {
                await model.waitForOperations()
                defaults.removePersistentDomain(forName: suite)
            }
        }
    }
}

@MainActor
private final class PresetModelConfigurationService: DisplayConfigurationServing {
    struct Applied {
        let preset: DisplayPreset
        let permanently: Bool
    }
    let display: DisplayInfo
    var applied: [Applied] = []
    var restoreCount = 0
    var failTrial = false
    var failPermanent = false
    var failDisplays = false
    init(display: DisplayInfo) { self.display = display }
    func displays() throws -> [DisplayInfo] {
        if failDisplays { throw DisplayServiceError.disconnected }
        return [display]
    }
    func apply(_ change: DisplayChange, permanently: Bool) throws {}
    func applyPreset(_ preset: DisplayPreset, permanently: Bool) throws {
        applied.append(Applied(preset: preset, permanently: permanently))
        if permanently ? failPermanent : failTrial { throw DisplayPresetError.invalidPreset }
    }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        .init(entries: [.init(displayID: display.displayID, uuid: display.id, mode: nil, origin: display.frame.origin,
                             mirrorMasterID: nil, mirrorMasterUUID: nil)])
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws { restoreCount += 1 }
}

private actor PresetModelHardware: DisplayHardwareBrightnessServing {
    var writes: [Double] = []
    private var value = 0.8
    func read(_ target: DisplayHardwareTarget) async throws -> DisplayHardwareBrightnessReading? {
        try await Task.sleep(for: .milliseconds(10))
        return .init(value: value, backend: .ddc)
    }
    func write(_ value: Double, to target: DisplayHardwareTarget, backend: DisplayHardwareBackend) async throws {
        writes.append(value)
        self.value = value
    }
    func current() -> Double { value }
}

@MainActor
private final class PresetModelGammaService: DisplayBrightnessServing {
    var applied: [(value: Double, displayID: UInt32)] = []
    func setDimming(_ factor: Double, displayID: UInt32) throws { applied.append((factor, displayID)) }
    func invalidate() {}
    func restore() {}
}

@MainActor
private final class PresetModelColorProfiles: DisplayColorProfileServing {
    var selectedID = "srgb"
    var holdNextSet = false
    var pendingSet: CheckedContinuation<Void, Never>?
    var writes: [String] = []
    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState {
        .init(options: [.init(id: "factory", name: "Заводской"), .init(id: "srgb", name: "Profile"),
                        .init(id: "p3", name: "Profile")], selectedID: selectedID)
    }
    func setProfile(_ profileID: String, for display: DisplayInfo) async throws {
        writes.append(profileID)
        selectedID = profileID
        if holdNextSet {
            holdNextSet = false
            await withCheckedContinuation { pendingSet = $0 }
        }
    }
    func completeSet() {
        let continuation = pendingSet
        pendingSet = nil
        continuation?.resume()
    }
}
