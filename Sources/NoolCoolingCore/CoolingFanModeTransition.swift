import Foundation

/// An AppleSMC write acknowledgement does not prove that thermalmonitord has
/// yielded control. Verify a settled mode before touching the target RPM.
enum CoolingFanModeTransition {
    /// Direct-control SMCs may restore system mode before a delayed target
    /// arrives. Keep these two writes adjacent, then verify the complete pair.
    static func applyTarget(
        rpm: Double,
        readMode: () -> Double?,
        readTarget: () -> Double?,
        writeManual: () throws -> Void,
        writeTarget: () throws -> Void,
        unlock: (() throws -> Void)?,
        pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) throws {
        if let unlock { try unlock() }
        var lastError: Error = CoolingError.hardware("SMC не подтвердил управление вентилятором.")
        for attempt in 0..<4 {
            do {
                // No read, wait, or second mode confirmation between writes.
                try writeManual()
                try writeTarget()
                try verifyTarget(rpm: rpm, readTarget: readTarget, readMode: readMode, pause: pause)
                return
            } catch { lastError = error }
            if attempt < 3 { pause(0.05) }
        }
        throw lastError
    }

    static func verifyTarget(rpm: Double, readTarget: () -> Double?, readMode: () -> Double?,
                             pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        var matchingReads = 0
        var lastTarget: Double?
        var lastMode: Double?
        for index in 0..<6 {
            lastTarget = readTarget(); lastMode = readMode()
            let matches = lastMode == 1 && lastTarget.map { $0.isFinite && abs($0 - rpm) <= 50 } == true
            matchingReads = matches ? matchingReads + 1 : 0
            if matchingReads >= 2 { return }
            if index < 5 { pause(0.05) }
        }
        let actualTarget = lastTarget.map { String(format: "%.0f", $0) } ?? "—"
        let actualMode = lastMode.map { String(format: "%.0f", $0) } ?? "—"
        throw CoolingError.hardware("SMC не подтвердил обороты: задано \(String(format: "%.0f", rpm)) RPM, прочитано \(actualTarget) RPM, режим \(actualMode).")
    }

    static func verifyAutomatic(readMode: () -> Double?,
                                pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        var lastMode: Double?
        guard settledValue(attempts: 11, pause: pause, matches: {
            lastMode = readMode()
            return lastMode == 0 || lastMode == 3
        }) else {
            let actual = lastMode.map { String(format: "%.0f", $0) } ?? "—"
            throw CoolingError.hardware("SMC не подтвердил автоматический режим вентилятора (прочитано \(actual)).")
        }
    }

    static func verifySystemGate(readGate: () -> Double?,
                                 pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        guard settledValue(attempts: 11, pause: pause, matches: { readGate() == 0 }) else {
            throw CoolingError.hardware("SMC не подтвердил возврат системного охлаждения (Ftst).")
        }
    }

    private static func settledValue(attempts: Int, pause: (TimeInterval) -> Void, matches: () -> Bool) -> Bool {
        var matchingReads = 0
        for index in 0..<attempts {
            matchingReads = matches() ? matchingReads + 1 : 0
            if matchingReads >= 2 { return true }
            if index + 1 < attempts { pause(0.05) }
        }
        return false
    }

}
