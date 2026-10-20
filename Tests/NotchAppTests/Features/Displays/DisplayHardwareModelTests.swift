import XCTest
@testable import NotchApp

@MainActor
final class DisplayHardwareModelTests: XCTestCase {
    func testHardwareProbeKeepsImageCorrectionAndUsesFullSoftwareBrightness() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        let correction = DisplayImageAdjustment(gamma: 1.2, temperature: 0.2)
        fixture.model.setImageAdjustment(correction, for: fixture.display)
        XCTAssertEqual(fixture.gamma.adjustments.last, correction)
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 1)
        fixture.model.refreshBrightness()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: 0.7)
        await settle()
        XCTAssertEqual(fixture.gamma.adjustments.last, correction)
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 1)
        fixture.model.defaultDimming = 0.5
        XCTAssertEqual(fixture.gamma.adjustments.last, correction)
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 1)
    }

    func testStartupReadsHardwareWithoutWritingAndClearsSoftwareDimming() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)

        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.64, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isHardwareBrightness(for: fixture.display))
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "Discovery must not change the monitor's brightness")
        let readCount = await fixture.hardware.recordedReadCount()
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 1,
                       "Hardware brightness must not be multiplied by a previous gamma reduction")
    }

    func testRapidSliderChangesOnlyWriteLatestValueAfterDebounce() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)

        fixture.model.setDimming(0.2, for: fixture.display)
        fixture.model.setDimming(0.4, for: fixture.display)
        fixture.model.setDimming(0.73, for: fixture.display)
        try await waitUntil { await fixture.hardware.recordedWrites().count == 1 }
        try await Task.sleep(for: .milliseconds(120))

        let writes = await fixture.hardware.recordedWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try XCTUnwrap(writes.first).value, 0.73, accuracy: 0.001)
        XCTAssertEqual(writes.first?.target.uuid, fixture.display.id)
        XCTAssertEqual(writes.first?.target.displayID, fixture.display.displayID)
        XCTAssertEqual(writes.first?.backend, .ddc)
    }

    func testReadCompletionAfterDisconnectIsIgnored() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        fixture.configuration.connectedDisplays = []
        fixture.model.refresh()
        let gammaCount = fixture.gamma.applied.count
        await fixture.hardware.completeRead(value: 0.23)
        await settle()

        XCTAssertTrue(fixture.model.displays.isEmpty)
        XCTAssertEqual(fixture.gamma.applied.count, gammaCount)
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 1, accuracy: 0.001)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testReadCompletionAfterStopIsIgnoredAndDebouncedWriteIsCancelled() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.model.start()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        fixture.model.stop()
        let gammaCount = fixture.gamma.applied.count
        await fixture.hardware.completeRead(value: 0.23)
        await settle()
        XCTAssertEqual(fixture.gamma.applied.count, gammaCount)
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 1, accuracy: 0.001)

        try await startAndProbe(fixture, value: 0.64)
        fixture.model.setDimming(0.3, for: fixture.display)
        fixture.model.stop()
        try await Task.sleep(for: .milliseconds(160))
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(fixture.model.enabled)
    }

    func testLateWriteFailureAfterStopCannotReapplyGamma() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        await fixture.hardware.setHoldWrites(true)
        fixture.model.setDimming(0.38, for: fixture.display)
        try await waitUntil { await fixture.hardware.pendingWrites() == 1 }
        fixture.model.stop()
        let gammaCount = fixture.gamma.applied.count
        await fixture.hardware.completeWrite(failing: true)
        await settle()

        XCTAssertEqual(fixture.gamma.applied.count, gammaCount)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.enabled)
    }

    func testHardwareWriteFailureFallsBackToGammaAndPersistsRequestedValue() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        await fixture.hardware.setFailWrites(true)
        fixture.model.setDimming(0.37, for: fixture.display)
        try await waitUntil { fixture.gamma.applied.last?.factor == 0.37 }

        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.37, accuracy: 0.001)
        XCTAssertFalse(fixture.model.isHardwareBrightness(for: fixture.display))
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        let saved = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertEqual(try XCTUnwrap(saved.dimmingByUUID[fixture.display.id]), 0.37, accuracy: 0.001)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertEqual(writes.count, 1)
    }

    func testSoftwareOverrideUsesGammaAndSwitchingBackReadsCurrentHardwareValue() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        fixture.model.useSoftwareBrightness(true, for: fixture.display)
        XCTAssertTrue(fixture.model.isSoftwareBrightnessPreferred(for: fixture.display))
        fixture.model.setDimming(0.36, for: fixture.display)
        try await Task.sleep(for: .milliseconds(160))

        XCTAssertEqual(fixture.gamma.applied.last?.factor, 0.36)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        let saved = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertTrue(saved.softwareBrightnessUUIDs?.contains(fixture.display.id) == true)

        fixture.model.useSoftwareBrightness(false, for: fixture.display)
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: 0.58)
        try await waitUntil { fixture.model.isHardwareBrightness(for: fixture.display) }
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.58, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isHardwareBrightness(for: fixture.display))
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 1)
        let readCount = await fixture.hardware.recordedReadCount()
        XCTAssertEqual(readCount, 2, "Hardware may have changed via macOS keys while software was selected")
    }

    func testLegacyPreferencesKeepExplicitSoftwareDimmingWithoutHardwareWrites() async throws {
        let legacy = Data("""
        {"defaultDimming":1,"restoreModesOnReconnect":false,"dimmingByUUID":{"hardware-screen":0.42},"modesByUUID":{}}
        """.utf8)
        let decoded = try JSONDecoder().decode(DisplayPreferences.self, from: legacy)
        XCTAssertNil(decoded.softwareBrightnessUUIDs)
        let fixture = makeFixture(storedPreferences: legacy)
        defer { fixture.cleanup() }
        fixture.model.start()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: 0.64)
        try await waitUntil { fixture.model.hasHardwareBrightness(for: fixture.display) }

        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.42, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isSoftwareBrightnessPreferred(for: fixture.display))
        XCTAssertFalse(fixture.model.isHardwareBrightness(for: fixture.display))
        XCTAssertEqual(fixture.gamma.applied.last?.factor, 0.42)
        let readCount = await fixture.hardware.recordedReadCount()
        XCTAssertEqual(readCount, 1, "Legacy preference preserves gamma while still discovering capability")
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        fixture.model.setDimming(0.43, for: fixture.display)
        let data = try XCTUnwrap(fixture.defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey))
        let saved = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertTrue(saved.softwareBrightnessUUIDs?.contains(fixture.display.id) == true)
    }

    func testBrightnessRefreshRetainsCachedReadingIsReadOnlyAndSkipsPendingWrites() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        fixture.model.refreshBrightness()
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.64, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isHardwareBrightness(for: fixture.display))
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: 0.51)
        try await waitUntil { abs(fixture.model.dimming(for: fixture.display) - 0.51) < 0.001 }
        let initialWrites = await fixture.hardware.recordedWrites()
        XCTAssertTrue(initialWrites.isEmpty)

        await fixture.hardware.setHoldWrites(true)
        fixture.model.setDimming(0.7, for: fixture.display)
        fixture.model.refreshBrightness()
        try await waitUntil { await fixture.hardware.pendingWrites() == 1 }
        fixture.model.refreshBrightness()
        await settle()
        let pendingReads = await fixture.hardware.pendingReads()
        let readCount = await fixture.hardware.recordedReadCount()
        XCTAssertEqual(pendingReads, 0)
        XCTAssertEqual(readCount, 2, "Refresh must not race a debounced or in-flight brightness write")
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.7, accuracy: 0.001)
        await fixture.hardware.completeWrite(failing: false)
        await settle()
    }

    func testLateRefreshReadCannotOverwriteNewSliderValue() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        fixture.model.refreshBrightness()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        fixture.model.setDimming(0.8, for: fixture.display)
        try await waitUntil { await fixture.hardware.recordedWrites().count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await fixture.hardware.completeRead(value: 0.2)
        await settle()
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.8, accuracy: 0.001)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertEqual(writes.first?.value, 0.8)
    }

    func testChangingDefaultDimmingDoesNotSwitchAnActiveHardwareControlToGamma() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        let gammaCount = fixture.gamma.applied.count
        fixture.model.defaultDimming = 0.5
        XCTAssertTrue(fixture.model.isHardwareBrightness(for: fixture.display))
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 0.64, accuracy: 0.001)
        XCTAssertEqual(fixture.gamma.applied.count, gammaCount)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testLostCapabilityOnRefreshRemovesCachedHardwareControl() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await startAndProbe(fixture, value: 0.64)
        fixture.model.refreshBrightness()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: nil)
        try await waitUntil { !fixture.model.hasHardwareBrightness(for: fixture.display) }
        XCTAssertFalse(fixture.model.isHardwareBrightness(for: fixture.display))
        XCTAssertEqual(fixture.model.dimming(for: fixture.display), 1)
        let writes = await fixture.hardware.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    private func startAndProbe(_ fixture: Fixture, value: Double) async throws {
        fixture.model.start()
        try await waitUntil { await fixture.hardware.pendingReads() == 1 }
        await fixture.hardware.completeRead(value: value)
        try await waitUntil { abs(fixture.model.dimming(for: fixture.display) - value) < 0.001 }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Hardware model did not reach the expected state")
        throw WaitFailure()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private struct WaitFailure: Error {}

    private func makeFixture(storedPreferences: Data? = nil) -> Fixture {
        let suite = "DisplayHardwareModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let storedPreferences { defaults.set(storedPreferences, forKey: UserDefaultsAppPreferences.displayManagementKey) }
        let display = DisplayInfo(id: "hardware-screen", displayID: 42, name: "Hardware monitor",
                                  isBuiltin: false, isMain: true, mirrorMasterID: nil, modes: [], currentMode: nil)
        let configuration = HardwareModelConfigurationService(display: display)
        let gamma = HardwareModelGammaService()
        let hardware = HardwareModelBrightnessService()
        let controller = DisplayRevertController(showsWindow: false)
        let model = DisplayFeatureModel(service: configuration, brightness: gamma, defaults: defaults,
                                        revertController: controller, hardware: hardware)
        return Fixture(model: model, configuration: configuration, gamma: gamma, hardware: hardware,
                       defaults: defaults, suite: suite, display: display)
    }

    @MainActor
    private struct Fixture {
        let model: DisplayFeatureModel
        let configuration: HardwareModelConfigurationService
        let gamma: HardwareModelGammaService
        let hardware: HardwareModelBrightnessService
        let defaults: UserDefaults
        let suite: String
        let display: DisplayInfo
        func cleanup() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
            Task { await hardware.finishPending() }
        }
    }
}

private actor HardwareModelBrightnessService: DisplayHardwareBrightnessServing {
    struct Write: Sendable {
        let value: Double
        let target: DisplayHardwareTarget
        let backend: DisplayHardwareBackend
    }
    private var reads: [CheckedContinuation<DisplayHardwareBrightnessReading?, Error>] = []
    private var writes: [Write] = []
    private var writeCompletions: [CheckedContinuation<Void, Error>] = []
    private var failWrites = false
    private var holdWrites = false
    private var readCount = 0

    func read(_ target: DisplayHardwareTarget) async throws -> DisplayHardwareBrightnessReading? {
        readCount += 1
        return try await withCheckedThrowingContinuation { reads.append($0) }
    }
    func write(_ value: Double, to target: DisplayHardwareTarget, backend: DisplayHardwareBackend) async throws {
        writes.append(Write(value: value, target: target, backend: backend))
        if holdWrites { try await withCheckedThrowingContinuation { writeCompletions.append($0) } }
        else if failWrites { throw Failure() }
    }
    func pendingReads() -> Int { reads.count }
    func pendingWrites() -> Int { writeCompletions.count }
    func recordedWrites() -> [Write] { writes }
    func recordedReadCount() -> Int { readCount }
    func setFailWrites(_ value: Bool) { failWrites = value }
    func setHoldWrites(_ value: Bool) { holdWrites = value }
    func completeRead(value: Double?) {
        guard !reads.isEmpty else { return }
        reads.removeFirst().resume(returning: value.map { DisplayHardwareBrightnessReading(value: $0, backend: .ddc) })
    }
    func completeWrite(failing: Bool) {
        guard !writeCompletions.isEmpty else { return }
        let continuation = writeCompletions.removeFirst()
        if failing { continuation.resume(throwing: Failure()) }
        else { continuation.resume() }
    }
    func finishPending() {
        let pendingReads = reads
        reads.removeAll()
        pendingReads.forEach { $0.resume(returning: nil) }
        let pendingWrites = writeCompletions
        writeCompletions.removeAll()
        pendingWrites.forEach { $0.resume(throwing: CancellationError()) }
    }
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Hardware brightness failed" }
    }
}

@MainActor
private final class HardwareModelConfigurationService: DisplayConfigurationServing {
    var connectedDisplays: [DisplayInfo]
    init(display: DisplayInfo) { connectedDisplays = [display] }
    func displays() throws -> [DisplayInfo] { connectedDisplays }
    func snapshot() throws -> DisplayConfigurationSnapshot { .init() }
    func apply(_ change: DisplayChange, permanently: Bool) throws {}
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {}
}

@MainActor
private final class HardwareModelGammaService: DisplayBrightnessServing {
    var adjustments: [DisplayImageAdjustment] = []
    var applied: [(factor: Double, displayID: UInt32)] = []
    func setDimming(_ factor: Double, displayID: UInt32) throws { applied.append((factor, displayID)) }
    func setAppearance(dimming: Double, adjustment: DisplayImageAdjustment, displayID: UInt32) throws {
        adjustments.append(adjustment)
        try setDimming(dimming, displayID: displayID)
    }
    func restore() {}
    func invalidate() {}
}
