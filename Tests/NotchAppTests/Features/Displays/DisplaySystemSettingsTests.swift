import XCTest
@testable import NotchApp

@MainActor
final class DisplaySystemSettingsTests: XCTestCase {
    func testThemeButtonCyclesThroughThreeConfirmedModesAndWraps() async {
        let service = SystemSettingsTestService()
        _ = try? await service.writeAppearanceMode(.light)
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        for expected in [DisplayAppearanceMode.dark, .automatic, .light, .dark] {
            await model.cycleAppearanceMode()
            XCTAssertEqual(model.appearanceMode, expected)
        }
        await service.refuseWrites()
        await model.cycleAppearanceMode()
        XCTAssertEqual(model.appearanceMode, .dark, "A rejected write must not advance the cycle")
        XCTAssertNotNil(model.errorMessage)
    }

    func testAutomaticThemeIsDistinctFromItsCurrentDarkAppearance() async {
        let service = SystemSettingsTestService()
        _ = try? await service.writeAppearanceMode(.automatic)
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        XCTAssertEqual(model.appearanceMode, .automatic)
        XCTAssertEqual(model.darkMode.value, true)
        await model.setAppearanceMode(.dark)
        XCTAssertEqual(model.appearanceMode, .dark)
        await model.setAppearanceMode(.light)
        XCTAssertEqual(model.appearanceMode, .light)
        XCTAssertEqual(model.darkMode.value, false)
        await model.setAppearanceMode(.automatic)
        XCTAssertEqual(model.appearanceMode, .automatic)
    }

    func testRefusedThemeModeWriteKeepsLastConfirmedSelection() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        await service.refuseWrites()
        await model.setAppearanceMode(.automatic)
        XCTAssertEqual(model.appearanceMode, .dark)
        XCTAssertNotNil(model.errorMessage)
    }

    func testReadsCapabilitiesAndDoesNotConfuseUnsupportedWithOff() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        XCTAssertEqual(model.darkMode.value, true)
        XCTAssertEqual(model.nightShift.value, false)
        XCTAssertNil(model.trueTone.value)
        XCTAssertNotNil(model.trueTone.unavailableReason)
        XCTAssertEqual(model.autoBrightness(for: screen).value, false)
        let count = await service.writeCount
        XCTAssertEqual(count, 0, "Discovery must not change a system preference")
    }

    func testWritesPublishOnlyVerifiedResult() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        await model.setNightShift(true)
        XCTAssertEqual(model.nightShift.value, true)
        await model.setDarkMode(false)
        XCTAssertEqual(model.darkMode.value, false)
        await model.setAutoBrightness(true, for: screen)
        XCTAssertEqual(model.autoBrightness(for: screen).value, true)
        XCTAssertNil(model.errorMessage)
    }

    func testRefusedWriteDoesNotPretendSwitchChanged() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        await service.refuseWrites()
        await model.setNightShift(true)
        XCTAssertEqual(model.nightShift.value, false)
        XCTAssertNotNil(model.errorMessage)
    }

    func testReadFailureIsUnavailableWithErrorRatherThanFalseState() async {
        let service = SystemSettingsTestService()
        await service.failReads()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        await model.refresh()
        XCTAssertNil(model.darkMode.value)
        XCTAssertNotNil(model.darkMode.unavailableReason)
        XCTAssertNil(model.autoBrightness(for: screen).value)
    }

    func testModuleAndPendingOperationGuardAllWrites() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        await model.setDarkMode(false)
        model.start(displays: [screen])
        model.canModify = { false }
        await model.setDarkMode(false)
        await model.setNightShift(true)
        await model.setAppearanceMode(.automatic)
        await model.setTrueTone(true)
        await model.setAutoBrightness(true, for: screen)
        model.stop()
        await model.setNightShift(true)
        let count = await service.writeCount
        XCTAssertEqual(count, 0)
    }

    func testDisconnectedAndChangedDisplayIDCannotReceiveAutoBrightnessWrite() async {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        defer { model.stop() }
        model.start(displays: [screen])
        model.updateDisplays([])
        await model.setAutoBrightness(true, for: screen)
        let count = await service.writeCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(model.autoBrightness(for: screen).value)
    }

    func testLateWriteAfterStopDoesNotRepopulateState() async throws {
        let service = SystemSettingsTestService()
        let model = DisplaySystemSettingsModel(service: service)
        model.start(displays: [screen])
        await model.refresh()
        await service.holdNextWrite()
        let write = Task { await model.setNightShift(true) }
        for _ in 0..<200 {
            if await service.hasHeldWrite { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.isBusy)
        model.stop()
        await service.releaseWrite()
        await write.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.nightShift.value, false)
    }

    private var screen: DisplayInfo {
        DisplayInfo(id: "system-screen", displayID: 42, name: "Test", isBuiltin: true,
                    isMain: true, mirrorMasterID: nil, modes: [], currentMode: nil)
    }
}

private actor SystemSettingsTestService: DisplaySystemSettingsServing {
    private var values: [DisplaySystemControl: Bool] = [.darkMode: true, .nightShift: false, .autoBrightness: false]
    private(set) var writeCount = 0
    private var refusing = false
    private var readFailure = false
    private var holdWrite = false
    private var appearance: DisplayAppearanceMode?
    private var held: CheckedContinuation<Void, Never>?
    var hasHeldWrite: Bool { held != nil }

    func refuseWrites() { refusing = true }
    func failReads() { readFailure = true }
    func holdNextWrite() { holdWrite = true }
    func releaseWrite() { held?.resume(); held = nil }
    func readAppearanceMode() async throws -> DisplayAppearanceMode? {
        if readFailure { throw DisplaySystemSettingsError.unavailable }
        return appearance ?? values[.darkMode].map { $0 ? .dark : .light }
    }
    func writeAppearanceMode(_ mode: DisplayAppearanceMode) async throws -> DisplayAppearanceMode {
        writeCount += 1
        if refusing { return appearance ?? (values[.darkMode] == true ? .dark : .light) }
        appearance = mode
        if mode != .automatic { values[.darkMode] = mode == .dark }
        return mode
    }
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? {
        if readFailure { throw DisplaySystemSettingsError.unavailable }
        return values[control]
    }
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        writeCount += 1
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { held = $0 }
        }
        if refusing { return values[control] ?? false }
        values[control] = enabled
        return enabled
    }
}
