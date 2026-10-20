import XCTest
@testable import NotchApp

final class DisplaySystemColorDriverTests: XCTestCase {
    private let target = DisplayHardwareTarget(uuid: "test", displayID: 42, isBuiltin: true)

    func testOnlyExactKnownObjectiveCSignaturesAreAccepted() {
        XCTAssertTrue(DisplaySystemColorABI.matches(returnType: "B", arguments: ["@", ":", "B"], parameters: ["B"]))
        XCTAssertTrue(DisplaySystemColorABI.matches(returnType: "B", arguments: ["@", ":", DisplaySystemColorABI.statusType],
                                                   parameters: [DisplaySystemColorABI.statusType]))
        XCTAssertFalse(DisplaySystemColorABI.matches(returnType: "v", arguments: ["@", ":", "B"], parameters: ["B"]))
        XCTAssertFalse(DisplaySystemColorABI.matches(returnType: "B", arguments: ["@", ":", "i"], parameters: ["B"]))
        XCTAssertFalse(DisplaySystemColorABI.matches(returnType: "B", arguments: ["@", ":", "^v"], parameters: [DisplaySystemColorABI.statusType]))
        XCTAssertFalse(DisplaySystemColorABI.matches(returnType: "B", arguments: ["@", ":", "B", "B"], parameters: ["B"]))
    }

    func testStatusUsesEnabledAndAvailabilityRatherThanActiveOrSchedule() throws {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = 1
        bytes[32] = 1
        var state = try DisplaySystemColorABI.status(bytes)
        XCTAssertFalse(state.enabled)
        XCTAssertTrue(state.available)
        bytes[1] = 1
        bytes[32] = 0
        state = try DisplaySystemColorABI.status(bytes)
        XCTAssertTrue(state.enabled)
        XCTAssertFalse(state.available)
    }

    func testTruncatedOrInvalidStatusNeverBecomesDisabledState() {
        XCTAssertThrowsError(try DisplaySystemColorABI.status([UInt8](repeating: 0, count: 32)))
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[1] = 2
        XCTAssertThrowsError(try DisplaySystemColorABI.status(bytes))
    }

    func testUnsupportedReadRemainsNilAndCannotWrite() throws {
        let runtime = Runtime()
        runtime.night = nil
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in })
        XCTAssertNil(try driver.nightShift())
        XCTAssertThrowsError(try driver.setNightShift(true))
        XCTAssertEqual(runtime.writes, [])
    }

    func testWritesBothGlobalControlsAndVerifiesNativeReadback() throws {
        let runtime = Runtime()
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in })
        try driver.setNightShift(true)
        try driver.setTrueTone(false)
        XCTAssertEqual(try driver.nightShift(), true)
        XCTAssertEqual(try driver.trueTone(), false)
        XCTAssertEqual(runtime.writes, ["night:true", "tone:false"])
    }

    func testAlreadyMatchingControlDoesNotWrite() throws {
        let runtime = Runtime()
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in })
        try driver.setNightShift(false)
        try driver.setTrueTone(true)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testSuccessfulSetterWithUnchangedReadbackThrows() {
        let runtime = Runtime()
        runtime.applies = false
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in })
        XCTAssertThrowsError(try driver.setNightShift(true))
        XCTAssertThrowsError(try driver.setTrueTone(false))
    }

    func testDriverFailureIsNotReportedAsUnsupported() {
        let runtime = Runtime()
        runtime.failRead = true
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in })
        XCTAssertThrowsError(try driver.nightShift())
        XCTAssertThrowsError(try driver.setNightShift(true))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testDisconnectedTargetNeverReachesAmbientDriver() {
        let runtime = Runtime()
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in throw DisplaySystemSettingsError.disconnected })
        XCTAssertThrowsError(try driver.autoBrightness(for: target))
        XCTAssertThrowsError(try driver.setAutoBrightness(true, for: target))
        XCTAssertEqual(runtime.ambientReads, 0)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testTargetIsValidatedAfterReadAndBeforeWrite() {
        let runtime = Runtime()
        var validations = 0
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { _ in
            validations += 1
            if validations == 3 { throw DisplaySystemSettingsError.disconnected }
        })
        XCTAssertThrowsError(try driver.setAutoBrightness(true, for: target))
        XCTAssertEqual(runtime.ambientReads, 1)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testAmbientWriteAndReadbackUseExactTargetAndValidateAfterWrite() throws {
        let runtime = Runtime()
        var validations = 0
        let driver = SystemDisplayColorDriver(runtime: runtime, validate: { target in
            XCTAssertEqual(target.displayID, 42)
            validations += 1
        })
        try driver.setAutoBrightness(true, for: target)
        XCTAssertEqual(runtime.writes, ["ambient:42:true"])
        XCTAssertEqual(runtime.ambientReads, 2)
        XCTAssertEqual(validations, 7)
    }

    private final class Runtime: DisplaySystemColorRuntime {
        var night: Bool? = false
        var tone: Bool? = true
        var ambient: Bool? = false
        var writes: [String] = []
        var ambientReads = 0
        var applies = true
        var failRead = false
        func nightShift() throws -> Bool? {
            if failRead { throw DisplaySystemSettingsError.notApplied }
            return night
        }
        func setNightShift(_ enabled: Bool) throws {
            writes.append("night:\(enabled)")
            if applies { night = enabled }
        }
        func trueTone() throws -> Bool? { tone }
        func setTrueTone(_ enabled: Bool) throws {
            writes.append("tone:\(enabled)")
            if applies { tone = enabled }
        }
        func autoBrightness(_ displayID: UInt32) throws -> Bool? { ambientReads += 1; return ambient }
        func setAutoBrightness(_ enabled: Bool, displayID: UInt32) throws {
            writes.append("ambient:\(displayID):\(enabled)")
            if applies { ambient = enabled }
        }
    }
}
