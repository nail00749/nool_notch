import XCTest
@testable import NoolCoolingCore

final class CoolingEndpointLeaseTests: XCTestCase {
    private final class Hardware: CoolingHardware {
        var automaticCalls = 0
        var value = CoolingSnapshot(fans: [CoolingFan(id: 0, name: "Fan", currentRPM: 2000, minimumRPM: 1500,
            maximumRPM: 6000, controlSupported: true)], sensors: [CoolingSensor(id: "CPU", name: "CPU", celsius: 50)], controlAvailable: true)
        func snapshot() throws -> CoolingSnapshot { value }
        func setTarget(fanID: Int, rpm: Double) throws { value.fans[0].mode = .manual; value.fans[0].targetRPM = rpm }
        func setAutomatic(fanID: Int) throws { automaticCalls += 1; value.fans[0].mode = .automatic }
        func finishControl() throws {}
    }

    private func request(_ session: String = UUID().uuidString) -> CoolingControlRequest {
        CoolingControlRequest(sessionID: session, fanIDs: [0], mode: .manual, targetPercent: 50)
    }

    func testNewConnectionCannotReplaceOldLeaseBeforeCleanupEvenWithSameClientUUID() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let old = CoolingEndpointLease(); let new = CoolingEndpointLease(); let command = request()
        try old.apply(command, using: controller)
        XCTAssertThrowsError(try new.apply(command, using: controller))
        XCTAssertEqual(hardware.automaticCalls, 0)
        old.disconnect(using: controller)
        try new.apply(command, using: controller)
        XCTAssertEqual(hardware.automaticCalls, 1)
        XCTAssertEqual(hardware.value.fans[0].mode, .manual)
    }

    func testDelayedOldDisconnectCannotRevokeNewLeaseAfterWatchdogReleasedOldOwner() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let old = CoolingEndpointLease(); let new = CoolingEndpointLease(); let command = request()
        try old.apply(command, using: controller)
        // Deterministically place controller cleanup before a queued old XPC
        // invalidation, then let the reconnected client acquire a fresh lease.
        try controller.restoreAll()
        try new.apply(command, using: controller)
        let restoreCount = hardware.automaticCalls
        old.disconnect(using: controller)
        XCTAssertEqual(hardware.automaticCalls, restoreCount)
        XCTAssertEqual(hardware.value.fans[0].mode, .manual)
        XCTAssertEqual(try controller.snapshot().controlledFanIDs, [0])
        try new.heartbeat(command.sessionID, using: controller)
    }

    func testOldHeartbeatAndReleaseCannotTouchNewConnectionLease() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let old = CoolingEndpointLease(); let new = CoolingEndpointLease(); let command = request()
        try old.apply(command, using: controller)
        try controller.restoreAll()
        try new.apply(command, using: controller)
        XCTAssertThrowsError(try old.heartbeat(command.sessionID, using: controller))
        XCTAssertThrowsError(try old.release(command.sessionID, using: controller))
        XCTAssertEqual(hardware.automaticCalls, 1)
        try new.release(command.sessionID, using: controller)
        XCTAssertEqual(hardware.automaticCalls, 2)
    }

    func testDisconnectedEndpointCannotRunQueuedCommandsAndCleanupIsIdempotent() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let endpoint = CoolingEndpointLease(); let command = request()
        try endpoint.apply(command, using: controller)
        endpoint.disconnect(using: controller); endpoint.disconnect(using: controller)
        XCTAssertThrowsError(try endpoint.apply(command, using: controller))
        XCTAssertThrowsError(try endpoint.heartbeat(command.sessionID, using: controller))
        XCTAssertEqual(hardware.automaticCalls, 1)
    }

    func testClientUUIDStillValidatedBeforeReplacingItWithInternalToken() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let endpoint = CoolingEndpointLease()
        XCTAssertThrowsError(try endpoint.apply(request("invalid"), using: controller))
        let valid = request()
        try endpoint.apply(valid, using: controller)
        XCTAssertThrowsError(try endpoint.apply(request(), using: controller))
        XCTAssertThrowsError(try endpoint.release(UUID().uuidString, using: controller))
        XCTAssertEqual(hardware.automaticCalls, 0)
    }

    func testUnboundEndpointCanReleaseIdleControllerButCannotReleaseActiveOtherEndpoint() throws {
        let hardware = Hardware(); let controller = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let idle = CoolingEndpointLease(); let active = CoolingEndpointLease(); let command = request()
        try idle.release(command.sessionID, using: controller)
        try active.apply(command, using: controller)
        XCTAssertThrowsError(try idle.release(command.sessionID, using: controller))
        XCTAssertEqual(hardware.automaticCalls, 0)
    }
}
