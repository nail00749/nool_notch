import XCTest
@testable import NotchApp

final class SystemProcessSamplerTests: XCTestCase {
    func testWarmUpThenReportsOneCoreCPUAndResidentBytes() {
        var calculator = SystemProcessCalculator(nanosecondsPerTick: 1)
        let first = calculator.calculate([reading(user: 1_000_000_000, system: 500_000_000)], uptime: 10)
        XCTAssertNil(first[0].cpuPercent)
        XCTAssertEqual(first[0].residentMemoryBytes, 2_000)

        // 3 CPU seconds in 2 elapsed seconds equals 150% on the per-core scale.
        let second = calculator.calculate([
            reading(user: 3_000_000_000, system: 1_500_000_000)
        ], uptime: 12)
        XCTAssertEqual(second[0].cpuPercent ?? -1, 150, accuracy: 0.001)
    }

    func testPIDReuseAndMissingProcessCannotInheritPreviousCounters() {
        var calculator = SystemProcessCalculator(nanosecondsPerTick: 1)
        _ = calculator.calculate([reading(id: "42:old", user: 1_000, system: 200)], uptime: 10)
        let reused = calculator.calculate([reading(id: "42:new", user: 100, system: 10)], uptime: 11)
        XCTAssertNil(reused[0].cpuPercent)
        let returned = calculator.calculate([reading(id: "42:old", user: 2_000, system: 300)], uptime: 12)
        XCTAssertNil(returned[0].cpuPercent)
    }

    func testCounterDecreaseClockResetAndOverflowDropCPUReading() {
        var calculator = SystemProcessCalculator(nanosecondsPerTick: 1)
        _ = calculator.calculate([reading(user: 1_000, system: 100)], uptime: 10)
        XCTAssertNil(calculator.calculate([reading(user: 999, system: 200)], uptime: 11)[0].cpuPercent)
        XCTAssertNil(calculator.calculate([reading(user: 1_100, system: 300)], uptime: 9)[0].cpuPercent)
        XCTAssertNil(calculator.calculate([reading(user: UInt64.max, system: UInt64.max)], uptime: 10)[0].cpuPercent)
        calculator.reset()
        XCTAssertNil(calculator.calculate([reading(user: 20, system: 10)], uptime: 20)[0].cpuPercent)
    }

    func testTopProcessesSortsBySelectedMetricAndKeepsUnknownCPULast() {
        let snapshot = SystemProcessSnapshot(sampledAt: Date(), processes: [
            process(id: "unknown", cpu: nil, memory: 9_000),
            process(id: "fast", cpu: 120, memory: 1_000),
            process(id: "large", cpu: 10, memory: 8_000)
        ], skippedProcessCount: 2)
        XCTAssertEqual(snapshot.topProcesses(sortedBy: .cpu, limit: 2).map(\.id), ["fast", "large"])
        XCTAssertEqual(snapshot.topProcesses(sortedBy: .memory, limit: 2).map(\.id), ["unknown", "large"])
        XCTAssertTrue(snapshot.topProcesses(sortedBy: .cpu, limit: 0).isEmpty)
    }

    private func reading(
        id: String = "42:1",
        user: UInt64,
        system: UInt64
    ) -> SystemProcessRawReading {
        SystemProcessRawReading(
            id: id, pid: 42, name: "Example", userTime: user, systemTime: system,
            residentMemoryBytes: 2_000
        )
    }

    private func process(id: String, cpu: Double?, memory: UInt64) -> MonitoredSystemProcess {
        MonitoredSystemProcess(id: id, pid: 42, name: id, cpuPercent: cpu, residentMemoryBytes: memory)
    }
}
