import XCTest
@testable import NoolCoolingCore

final class CoolingControllerTests: XCTestCase {
    private final class Hardware: CoolingHardware {
        var value = CoolingSnapshot(fans: [CoolingFan(id: 0, name: "Left", currentRPM: 2000, minimumRPM: 1500, maximumRPM: 6000, controlSupported: true)],
                                    sensors: [CoolingSensor(id: "TC0P", name: "CPU", celsius: 60)], controlAvailable: true)
        var targets: [Double] = []
        var automatic = 0
        var targetFailure = false
        var targetFailureAt: Int?
        var targetAttempts = 0
        var autoFailures = 0
        var finishFailures = 0
        func snapshot() throws -> CoolingSnapshot { value }
        func setTarget(fanID: Int, rpm: Double) throws {
            targetAttempts += 1
            if targetFailure || targetFailureAt == targetAttempts { throw CoolingError.hardware("write") }; targets.append(rpm)
            if let index = value.fans.firstIndex(where: { $0.id == fanID }) {
                value.fans[index].mode = .manual; value.fans[index].targetRPM = rpm
            }
        }
        func setAutomatic(fanID: Int) throws {
            automatic += 1
            if autoFailures > 0 { autoFailures -= 1; throw CoolingError.hardware("restore") }
            if let index = value.fans.firstIndex(where: { $0.id == fanID }) { value.fans[index].mode = .automatic }
        }
        func finishControl() throws {
            if finishFailures > 0 { finishFailures -= 1; throw CoolingError.hardware("finish") }
        }
    }
    private let session = UUID().uuidString
    func testHardwareReclaimingModeCannotRemainReportedAsManual() throws {
        let hardware = Hardware()
        let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(), now: now, uptime: 100)
        hardware.value.fans[0].mode = .automatic
        engine.tick(now: now.addingTimeInterval(1), uptime: 101)
        let result = try engine.snapshot()
        XCTAssertTrue(result.controlledFanIDs.isEmpty)
        XCTAssertEqual(result.fans.first?.mode, .automatic)
        XCTAssertTrue(result.notice?.contains("SMC изменил") == true)
    }
    private let now = Date(timeIntervalSince1970: 1000)
    private func command(_ mode: CoolingControlMode = .manual, percent: Double? = 50) -> CoolingControlRequest {
        CoolingControlRequest(sessionID: session, fanIDs: [0], mode: mode, targetPercent: percent, durationSeconds: 30)
    }

    func testWritesOwnershipBeforeTargetAndMapsRange() throws {
        let hardware = Hardware(); var journal: [Set<Int>] = []
        let engine = CoolingController(hardware: hardware, persistOwned: { ids in
            if ids == [0] && journal.isEmpty { XCTAssertTrue(hardware.targets.isEmpty) }; journal.append(ids)
        }, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(), now: now, uptime: 100)
        XCTAssertEqual(hardware.targets, [3750]); XCTAssertEqual(journal.first, [0])
        XCTAssertEqual(try engine.snapshot().fans.first?.mode, .manual)
    }

    func testLeaseExpirationRestoresWithoutClient() throws {
        let hardware = Hardware(); let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(), now: now, uptime: 100)
        for time in stride(from: 101.0, through: 112.0, by: 1) { engine.tick(now: now, uptime: time) }
        XCTAssertEqual(hardware.automatic, 1)
    }

    func testBoostDeadlineRestoresAndHeartbeatDoesNotExtendBoost() throws {
        let hardware = Hardware(); let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(.boost), now: now, uptime: 100)
        XCTAssertEqual(hardware.targets, [6000])
        try engine.heartbeat(sessionID: session, uptime: 102)
        engine.tick(now: now.addingTimeInterval(30), uptime: 103)
        XCTAssertEqual(hardware.automatic, 1)
    }

    func testCurveInterpolatesThenRampsAndSensorLossRestores() throws {
        let hardware = Hardware(); let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        let request = CoolingControlRequest(sessionID: session, fanIDs: [0], mode: .curve, sensorID: "TC0P", curve: [
            CoolingCurvePoint(temperature: 40, percent: 0), CoolingCurvePoint(temperature: 80, percent: 100)])
        _ = try engine.apply(request, now: now, uptime: 100)
        XCTAssertEqual(hardware.targets, [3750])
        hardware.value.sensors[0].celsius = 80
        engine.tick(now: now, uptime: 101)
        XCTAssertEqual(hardware.targets.last, 4425)
        hardware.value.sensors = []
        engine.tick(now: now, uptime: 102)
        XCTAssertEqual(hardware.automatic, 1)
    }

    func testFailedFirstWriteAndFailedRestoreRemainRecoverable() throws {
        let hardware = Hardware(); hardware.targetFailure = true; hardware.autoFailures = 1
        var journal: [Set<Int>] = []
        let engine = CoolingController(hardware: hardware, persistOwned: { journal.append($0) }, thermalPressureIsHigh: { false })
        XCTAssertThrowsError(try engine.apply(command(), now: now, uptime: 100))
        XCTAssertEqual(journal.last, [0])
        XCTAssertThrowsError(try engine.apply(command(), now: now, uptime: 100))
        engine.tick(now: now, uptime: 101)
        XCTAssertEqual(hardware.automatic, 2); XCTAssertEqual(journal.last, [])
    }

    func testFinishFailureRetainsJournalAndRetries() throws {
        let hardware = Hardware(); var journal: [Set<Int>] = []
        let engine = CoolingController(hardware: hardware, persistOwned: { journal.append($0) }, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(), now: now, uptime: 100)
        hardware.finishFailures = 1
        XCTAssertThrowsError(try engine.release(sessionID: session))
        XCTAssertEqual(journal.last, [0])
        engine.tick(now: now, uptime: 101)
        XCTAssertEqual(journal.last, [])
    }

    func testPartialLinkedApplyRestoresBothFansAndRetriesRollbackFailure() throws {
        let hardware = Hardware()
        hardware.value.fans.append(CoolingFan(id: 1, name: "Right", currentRPM: 2000, minimumRPM: 1500, maximumRPM: 6000, controlSupported: true))
        hardware.targetFailureAt = 2; hardware.autoFailures = 1
        var journal: [Set<Int>] = []
        let engine = CoolingController(hardware: hardware, persistOwned: { journal.append($0) }, thermalPressureIsHigh: { false })
        var request = command(); request.fanIDs = [0, 1]
        XCTAssertThrowsError(try engine.apply(request, now: now, uptime: 100))
        XCTAssertEqual(hardware.targets.count, 1); XCTAssertEqual(journal.last, [0, 1])
        engine.tick(now: now, uptime: 101)
        XCTAssertEqual(journal.last, []); XCTAssertEqual(hardware.automatic, 4)
    }

    func testUnknownSensorCannotDriveCurve() throws {
        let hardware = Hardware(); hardware.value.sensors[0].controlEligible = false
        let request = CoolingControlRequest(sessionID: session, fanIDs: [0], mode: .curve, sensorID: "TC0P", curve: [
            CoolingCurvePoint(temperature: 40, percent: 0), CoolingCurvePoint(temperature: 80, percent: 100)])
        let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        XCTAssertThrowsError(try engine.apply(request)); XCTAssertTrue(hardware.targets.isEmpty)
    }

    func testThermalPressureRestoresManualAndRejectsNewControl() throws {
        let hardware = Hardware(); var high = false
        let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { high })
        _ = try engine.apply(command(), now: now, uptime: 100)
        high = true; engine.tick(now: now, uptime: 101)
        XCTAssertEqual(hardware.automatic, 1)
        XCTAssertThrowsError(try engine.apply(command(), now: now, uptime: 102))
    }

    func testInvalidCurvesAndOutOfRangeInputsNeverWrite() throws {
        let hardware = Hardware(); let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        XCTAssertThrowsError(try engine.apply(command(percent: .nan)))
        XCTAssertThrowsError(try engine.apply(command(percent: 101)))
        let request = CoolingControlRequest(sessionID: session, fanIDs: [0], mode: .curve, sensorID: "TC0P", curve: [
            CoolingCurvePoint(temperature: 80, percent: 80), CoolingCurvePoint(temperature: 40, percent: 20)])
        XCTAssertThrowsError(try engine.apply(request)); XCTAssertTrue(hardware.targets.isEmpty)
    }

    func testOtherSessionCannotOverrideAndPersistFailurePreventsWrites() throws {
        let hardware = Hardware(); let engine = CoolingController(hardware: hardware, thermalPressureIsHigh: { false })
        _ = try engine.apply(command(), now: now, uptime: 100)
        var other = command(); other.sessionID = UUID().uuidString
        XCTAssertThrowsError(try engine.apply(other, now: now, uptime: 101))
        let denied = Hardware(); let deniedEngine = CoolingController(hardware: denied, persistOwned: { _ in throw CoolingError.hardware("journal") }, thermalPressureIsHigh: { false })
        XCTAssertThrowsError(try deniedEngine.apply(command())); XCTAssertTrue(denied.targets.isEmpty)
    }
}
