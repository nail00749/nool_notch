import XCTest
@testable import NoolCoolingCore

final class CoolingFanModeTransitionTests: XCTestCase {
    func testModeAndTargetAreWrittenImmediatelyBeforeAnyConfirmationPause() throws {
        var mode = 0.0
        var target = 2317.0
        var targetWasWritten = false
        var events: [String] = []
        try CoolingFanModeTransition.applyTarget(rpm: 5600,
            readMode: { events.append("readMode"); return mode },
            readTarget: { events.append("readTarget"); return target },
            writeManual: { events.append("manual"); mode = 1 },
            writeTarget: { events.append("target"); target = 5600; targetWasWritten = true },
            unlock: nil, pause: { _ in
                events.append("pause")
                if !targetWasWritten { mode = 0 }
            })
        XCTAssertEqual(Array(events.prefix(2)), ["manual", "target"])
        XCTAssertEqual(mode, 1)
        XCTAssertEqual(target, 5600)
    }

    func testOverwrittenPairRetriesBothWrites() throws {
        var pairs = 0
        var mode = 0.0
        var target = 2317.0
        try CoolingFanModeTransition.applyTarget(rpm: 5600, readMode: { mode }, readTarget: { target },
            writeManual: { pairs += 1; mode = 1 }, writeTarget: {
                target = pairs >= 2 ? 5600 : 2317
                if pairs == 1 { mode = 0 }
            }, unlock: nil, pause: { _ in })
        XCTAssertEqual(pairs, 2)
    }

    func testPairUnlockHappensOnceBeforeAdjacentWrites() throws {
        var events: [String] = []
        try CoolingFanModeTransition.applyTarget(rpm: 5600, readMode: { 1 }, readTarget: { 5600 },
            writeManual: { events.append("manual") }, writeTarget: { events.append("target") },
            unlock: { events.append("unlock") }, pause: { _ in })
        XCTAssertEqual(events, ["unlock", "manual", "target"])
    }

    func testPairFailureIsBoundedAndPreservesActualReadbackError() {
        var pairs = 0
        var pauses: [TimeInterval] = []
        XCTAssertThrowsError(try CoolingFanModeTransition.applyTarget(rpm: 5600,
            readMode: { 0 }, readTarget: { 2317 }, writeManual: { pairs += 1 }, writeTarget: {},
            unlock: nil, pause: { pauses.append($0) })) { error in
                XCTAssertTrue(error.localizedDescription.contains("2317"))
                XCTAssertTrue(error.localizedDescription.contains("режим 0"))
            }
        XCTAssertEqual(pairs, 4)
        XCTAssertLessThanOrEqual(pauses.reduce(0, +), 1.16)
    }

    func testPairWriteFailurePropagatesAndNeverReportsConfirmation() {
        var targets = 0
        var reads = 0
        XCTAssertThrowsError(try CoolingFanModeTransition.applyTarget(rpm: 5600,
            readMode: { reads += 1; return 1 }, readTarget: { reads += 1; return 5600 },
            writeManual: {}, writeTarget: { targets += 1; throw CoolingError.hardware("target write failed") },
            unlock: nil, pause: { _ in })) { error in
                XCTAssertEqual(error.localizedDescription, "target write failed")
            }
        XCTAssertEqual(targets, 4)
        XCTAssertEqual(reads, 0)
    }

    func testPairUnlockFailurePreventsAllModeAndTargetWrites() {
        var writes = 0
        XCTAssertThrowsError(try CoolingFanModeTransition.applyTarget(rpm: 5600,
            readMode: { 0 }, readTarget: { 2317 }, writeManual: { writes += 1 }, writeTarget: { writes += 1 },
            unlock: { throw CoolingError.hardware("unlock") }, pause: { _ in }))
        XCTAssertEqual(writes, 0)
    }

    func testTargetReadbackWaitsForSettledTargetAndMode() throws {
        var targets = [2317.0, 5618, 2500, 5618, 5618]
        try CoolingFanModeTransition.verifyTarget(rpm: 5618, readTarget: { targets.removeFirst() },
            readMode: { 1 }, pause: { _ in })
        XCTAssertTrue(targets.isEmpty)
    }

    func testRejectedTargetReportsActualReadbackAndIsBounded() {
        var pauses = 0
        XCTAssertThrowsError(try CoolingFanModeTransition.verifyTarget(rpm: 5618, readTarget: { 2317 },
            readMode: { 0 }, pause: { _ in pauses += 1 })) { error in
                XCTAssertTrue(error.localizedDescription.contains("5618"))
                XCTAssertTrue(error.localizedDescription.contains("2317"))
                XCTAssertTrue(error.localizedDescription.contains("режим 0"))
            }
        XCTAssertEqual(pauses, 5)
    }

    func testAutomaticModeWaitsForFirmwareTransition() throws {
        var modes = [1.0, 1, 0, 0]
        var pauses = 0
        try CoolingFanModeTransition.verifyAutomatic(readMode: { modes.removeFirst() }, pause: { _ in pauses += 1 })
        XCTAssertTrue(modes.isEmpty)
        XCTAssertEqual(pauses, 3)
    }

    func testSystemModeAlsoConfirmsAutomaticButTransientAutoDoesNot() throws {
        var modes = [1.0, 0, 1, 3, 3]
        try CoolingFanModeTransition.verifyAutomatic(readMode: { modes.removeFirst() }, pause: { _ in })
        XCTAssertTrue(modes.isEmpty)
    }

    func testAutomaticFailureIsBoundedAndReportsActualMode() {
        var pauses = 0
        XCTAssertThrowsError(try CoolingFanModeTransition.verifyAutomatic(readMode: { 1 }, pause: { _ in pauses += 1 })) { error in
            XCTAssertTrue(error.localizedDescription.contains("прочитано 1"))
        }
        XCTAssertEqual(pauses, 10)
    }

    func testSystemGateWaitsForConfirmedReleaseAndRejectsStuckGate() throws {
        var gates = [1.0, 1, 0, 0]
        try CoolingFanModeTransition.verifySystemGate(readGate: { gates.removeFirst() }, pause: { _ in })
        XCTAssertTrue(gates.isEmpty)
        var pauses = 0
        XCTAssertThrowsError(try CoolingFanModeTransition.verifySystemGate(readGate: { 1 }, pause: { _ in pauses += 1 }))
        XCTAssertEqual(pauses, 10)
    }
}
