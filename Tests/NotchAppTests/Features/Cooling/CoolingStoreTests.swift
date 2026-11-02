import XCTest
import NoolCoolingCore
@testable import NotchApp

@MainActor
final class CoolingStoreTests: XCTestCase {
    func testServiceUnregistrationRejectsSliderDraftsAndLeavesNoQueuedWrite() async throws {
        let client = FakeCoolingClient()
        var pendingUnregistration: CheckedContinuation<Void, Error>?
        let store = CoolingStore(testClient: client, snapshot: client.value, unregisterService: {
            try await withCheckedThrowingContinuation { pendingUnregistration = $0 }
        })
        store.uninstallControl()
        await waitUntil { pendingUnregistration != nil }
        XCTAssertFalse(store.canControl)
        store.scheduleManual(fanIDs: [0], percent: 90, sourceID: UUID())
        try await Task.sleep(for: .milliseconds(350))
        pendingUnregistration?.resume(); pendingUnregistration = nil
        await waitUntil { !store.isBusy }
        store.apply(fanIDs: [0], mode: .manual, percent: 30)
        await waitUntil { !store.isBusy }
        XCTAssertEqual(client.requests.map(\.targetPercent), [30])
        await store.shutdown()
    }

    func testAutomaticResetStopsHeartbeatEvenWithoutOpenPresentation() async throws {
        let client = FakeCoolingClient()
        let store = CoolingStore(testClient: client, snapshot: client.value)
        store.apply(fanIDs: [0], mode: .manual, percent: 40)
        await waitUntil { !store.isBusy }
        store.allAutomatic()
        await waitUntil { !store.isBusy }
        try await Task.sleep(for: .milliseconds(3_200))
        XCTAssertEqual(client.heartbeats, 0, "No lease RPCs may survive a successful automatic reset")
        await store.shutdown()
    }

    func testManualSliderDebouncesToLastValueAndKeepsLinkedFanIDs() async throws {
        let client = FakeCoolingClient()
        client.value.fans.append(.init(id: 1, name: "Правый", currentRPM: 2200, minimumRPM: 1800,
                                      maximumRPM: 6800, controlSupported: true))
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let source = UUID()
        store.scheduleManual(fanIDs: [0, 1], percent: 20, sourceID: source)
        store.scheduleManual(fanIDs: [0, 1], percent: 40, sourceID: source)
        store.scheduleManual(fanIDs: [0, 1], percent: 70, sourceID: source)
        XCTAssertEqual(client.applies, 0)
        try await Task.sleep(for: .milliseconds(350))
        await waitUntil { !store.isBusy }
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests.first?.targetPercent, 70)
        XCTAssertEqual(client.requests.first?.fanIDs, [0, 1])
        await store.shutdown()
    }

    func testSliderUpdatesDuringApplyKeepLatestValueInsteadOfDroppingIt() async throws {
        let client = FakeCoolingClient()
        client.delayApply = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let source = UUID()
        store.scheduleManual(fanIDs: [0], percent: 20, sourceID: source)
        await waitUntil { client.pendingApply != nil }
        store.scheduleManual(fanIDs: [0], percent: 40, sourceID: source)
        try await Task.sleep(for: .milliseconds(350))
        store.scheduleManual(fanIDs: [0], percent: 80, sourceID: source)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(client.requests.count, 1)
        client.finishApply()
        await waitUntil { client.requests.count == 2 }
        XCTAssertEqual(client.requests.map(\.targetPercent), [20, 80])
        client.finishApply()
        await waitUntil { !store.isBusy }
        await store.shutdown()
    }

    func testAutomaticResetFollowsActiveApplyAndRevokesPendingManual() async throws {
        let client = FakeCoolingClient()
        client.delayApply = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let source = UUID()
        store.apply(fanIDs: [0], mode: .manual, percent: 20)
        await waitUntil { client.pendingApply != nil }
        store.scheduleManual(fanIDs: [0], percent: 90, sourceID: source)
        try await Task.sleep(for: .milliseconds(350))
        store.allAutomatic()
        client.finishApply()
        await waitUntil { client.requests.count == 2 }
        XCTAssertEqual(client.requests.map(\.mode), [.manual, .automatic])
        client.finishApply()
        await waitUntil { !store.isBusy }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(store.snapshot?.fans.first?.mode, .automatic)
        await store.shutdown()
    }

    func testPresentationChangeCancelsOnlyItsPendingDraftIncludingQueuedWrites() async throws {
        let client = FakeCoolingClient()
        client.delayApply = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let firstSource = UUID()
        let otherSource = UUID()
        store.apply(fanIDs: [0], mode: .manual, percent: 20)
        await waitUntil { client.pendingApply != nil }
        store.scheduleManual(fanIDs: [0], percent: 90, sourceID: firstSource)
        try await Task.sleep(for: .milliseconds(350))
        store.cancelPendingManual(sourceID: firstSource)
        store.scheduleManual(fanIDs: [0], percent: 60, sourceID: otherSource)
        store.cancelPendingManual(sourceID: firstSource)
        try await Task.sleep(for: .milliseconds(350))
        client.finishApply()
        await waitUntil { client.requests.count == 2 }
        XCTAssertEqual(client.requests.map(\.targetPercent), [20, 60])
        client.finishApply()
        await waitUntil { !store.isBusy }
        await store.shutdown()
    }

    func testClosingDraftOrShutdownBeforeDebounceDoesNotWriteHardware() async throws {
        let client = FakeCoolingClient()
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let source = UUID()
        store.scheduleManual(fanIDs: [0], percent: 80, sourceID: source)
        store.cancelPendingManual(sourceID: source)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(client.applies, 0)
        store.scheduleManual(fanIDs: [0], percent: 60, sourceID: source)
        await store.shutdown()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(client.applies, 0)
    }

    func testCommandFailureSurvivesSuccessfulTelemetryRefresh() async throws {
        let client = FakeCoolingClient()
        client.rejectApply = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        store.apply(fanIDs: [0], mode: .manual, percent: 40)
        await waitUntil { !store.isBusy }
        let failure = store.message
        XCTAssertNotNil(failure)
        store.startObserving()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.message, failure)
        store.stopObserving()
        await store.shutdown()
    }
    func testBundledUnregisteredServiceCanBeInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(CoolingStore.unregisteredStatus(bundleURL: root), .unavailable)
        let plist = root.appendingPathComponent("Contents/Library/LaunchDaemons/com.nool.cooling-helper.plist")
        let helper = root.appendingPathComponent("Contents/MacOS/NoolCoolingHelper")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: plist)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
        XCTAssertEqual(CoolingStore.unregisteredStatus(bundleURL: root), .unavailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(CoolingStore.unregisteredStatus(bundleURL: root), .notInstalled)
    }

    func testClosingPresentationKeepsLeaseUntilExplicitShutdown() async throws {
        let client = FakeCoolingClient()
        let store = CoolingStore(testClient: client, snapshot: client.value)
        store.startObserving()
        store.apply(fanIDs: [0], mode: .manual, percent: 40)
        await waitUntil { !store.isBusy }
        store.stopObserving()
        try await Task.sleep(for: .milliseconds(3_200))
        XCTAssertGreaterThanOrEqual(client.heartbeats, 1)
        XCTAssertEqual(client.releases, 0, "Closing the panel must not cancel control")
        await store.shutdown()
        XCTAssertEqual(client.releases, 1)
        XCTAssertTrue(client.disconnected)
    }

    func testSnapshotStartedBeforeApplyCannotClearNewManualSession() async {
        let client = FakeCoolingClient()
        client.delaySnapshot = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        store.startObserving()
        await waitUntil { client.pendingSnapshot != nil }
        store.apply(fanIDs: [0], mode: .manual, percent: 60)
        await waitUntil { !store.isBusy }
        client.completeOldAutomaticSnapshot()
        await Task.yield()
        XCTAssertEqual(store.snapshot?.fans.first?.mode, .manual)
        store.stopObserving()
        await store.shutdown()
        XCTAssertEqual(client.releases, 1, "Stale auto readings must not lose ownership of a manual session")
    }

    func testShutdownDrainsPendingApplyThenRestoresAndRejectsNewCommands() async {
        let client = FakeCoolingClient()
        client.delayApply = true
        let store = CoolingStore(testClient: client, snapshot: client.value)
        store.apply(fanIDs: [0], mode: .manual, percent: 30)
        await waitUntil { client.pendingApply != nil }
        let shutdown = Task { await store.shutdown() }
        await Task.yield()
        XCTAssertFalse(store.canControl)
        client.finishApply()
        await shutdown.value
        XCTAssertEqual(client.releases, 1)
        store.apply(fanIDs: [0], mode: .manual, percent: 80)
        XCTAssertEqual(client.applies, 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class FakeCoolingClient: CoolingClientTransport {
    var value = CoolingSnapshot(fans: [.init(id: 0, name: "Левый", currentRPM: 2500, minimumRPM: 2000,
                                             maximumRPM: 6000, controlSupported: true)],
                                sensors: [.init(id: "TC0D", name: "CPU", celsius: 55)], controlAvailable: true)
    var heartbeats = 0
    var releases = 0
    var applies = 0
    var requests: [CoolingControlRequest] = []
    var disconnected = false
    var delaySnapshot = false
    var delayApply = false
    var rejectApply = false
    var pendingSnapshot: CheckedContinuation<CoolingSnapshot, Never>?
    var pendingApply: CheckedContinuation<CoolingSnapshot, Never>?

    func snapshot() async throws -> CoolingSnapshot {
        if delaySnapshot {
            delaySnapshot = false
            return await withCheckedContinuation { pendingSnapshot = $0 }
        }
        return value
    }
    func apply(_ command: CoolingControlRequest) async throws -> CoolingSnapshot {
        applies += 1
        requests.append(command)
        if rejectApply { throw CoolingError.hardware("SMC не подтвердил ручной режим вентилятора.") }
        value.fans[0].mode = command.mode
        value.controlledFanIDs = command.mode == .automatic ? [] : [0]
        if delayApply { return await withCheckedContinuation { pendingApply = $0 } }
        return value
    }
    func heartbeat(_ sessionID: String) async throws { heartbeats += 1 }
    func release(_ sessionID: String) async throws { releases += 1; value.fans[0].mode = .automatic }
    func disconnect() { disconnected = true }
    func completeOldAutomaticSnapshot() {
        var old = value; old.fans[0].mode = .automatic
        old.controlledFanIDs = []
        pendingSnapshot?.resume(returning: old); pendingSnapshot = nil
    }
    func finishApply() { pendingApply?.resume(returning: value); pendingApply = nil }
}
