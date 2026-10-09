import XCTest
@testable import NotchApp

final class SystemMetricsSamplerTests: XCTestCase {
    func testCPUUsesSuccessiveHostTicksAndWarmsUpAfterFailure() {
        var calculator = SystemMetricsCalculator()

        XCTAssertNil(calculator.cpuFraction(ticks: [100, 100, 100, 0]))
        XCTAssertEqual(calculator.cpuFraction(ticks: [110, 120, 130, 0])!, 0.5, accuracy: 0.0001)
        XCTAssertNil(calculator.cpuFraction(ticks: [110, 120, 130, 0]))
        XCTAssertNil(calculator.cpuFraction(ticks: nil))
        XCTAssertNil(calculator.cpuFraction(ticks: [200, 200, 200, 0]))
        XCTAssertEqual(calculator.cpuFraction(ticks: [200, 200, 220, 0])!, 0, accuracy: 0.0001)
    }

    func testCPUTicksHandleUInt32Wrap() {
        var calculator = SystemMetricsCalculator()
        XCTAssertNil(calculator.cpuFraction(ticks: [UInt32.max - 4, 20, 30, 0]))
        XCTAssertEqual(calculator.cpuFraction(ticks: [5, 30, 40, 0])!, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testMemoryExcludesFileCacheAndPurgeablePagesAndClampsToTotal() {
        XCTAssertEqual(
            SystemMetricsCalculator.memoryUsage(
                totalBytes: 1_000, pageSize: 10, activePages: 20, inactivePages: 30,
                wiredPages: 10, compressorPages: 5, purgeablePages: 5, externalPages: 20
            ),
            SystemResourceUsage(usedBytes: 400, totalBytes: 1_000)
        )
        XCTAssertEqual(
            SystemMetricsCalculator.memoryUsage(
                totalBytes: 1_000, pageSize: 10, activePages: 200, inactivePages: 30,
                wiredPages: 10, compressorPages: 5, purgeablePages: 0, externalPages: 0
            )?.usedBytes,
            1_000
        )
        XCTAssertNil(SystemMetricsCalculator.memoryUsage(
            totalBytes: 0, pageSize: 4, activePages: 0, inactivePages: 0,
            wiredPages: 0, compressorPages: 0, purgeablePages: 0, externalPages: 0
        ))
        XCTAssertNil(SystemMetricsCalculator.memoryUsage(
            totalBytes: 1_000, pageSize: 0, activePages: 0, inactivePages: 0,
            wiredPages: 0, compressorPages: 0, purgeablePages: 0, externalPages: 0
        ))
        XCTAssertNil(SystemMetricsCalculator.memoryUsage(
            totalBytes: 1_000, pageSize: UInt64.max, activePages: 2, inactivePages: 0,
            wiredPages: 0, compressorPages: 0, purgeablePages: 0, externalPages: 0
        ))
    }

    func testNetworkCountsOnlyExistingInterfacesAndHandlesChurn() {
        var calculator = SystemMetricsCalculator()
        XCTAssertNil(calculator.networkRate(counters: ["en0": .init(received: 100, sent: 200)], uptime: 10))
        XCTAssertEqual(
            calculator.networkRate(counters: ["en0": .init(received: 300, sent: 250)], uptime: 12),
            SystemNetworkRate(receivedBytesPerSecond: 100, sentBytesPerSecond: 25)
        )
        // A new interface must not contribute all bytes transferred since boot.
        XCTAssertEqual(
            calculator.networkRate(counters: [
                "en0": .init(received: 400, sent: 300),
                "en1": .init(received: 1_000_000, sent: 2_000_000)
            ], uptime: 13),
            SystemNetworkRate(receivedBytesPerSecond: 100, sentBytesPerSecond: 50)
        )
        XCTAssertEqual(
            calculator.networkRate(counters: ["en1": .init(received: 1_000_050, sent: 2_000_025)], uptime: 14),
            SystemNetworkRate(receivedBytesPerSecond: 50, sentBytesPerSecond: 25)
        )
    }

    func testNetworkResetFailureAndLarge64BitCountersDoNotInventSpikes() {
        var calculator = SystemMetricsCalculator()
        XCTAssertNil(calculator.networkRate(counters: ["en0": .init(received: 1_000, sent: 1_000)], uptime: 1))
        XCTAssertNil(calculator.networkRate(counters: ["en0": .init(received: 10, sent: 10)], uptime: 2))
        XCTAssertEqual(
            calculator.networkRate(counters: ["en0": .init(received: 20, sent: 30)], uptime: 3),
            SystemNetworkRate(receivedBytesPerSecond: 10, sentBytesPerSecond: 20)
        )
        XCTAssertNil(calculator.networkRate(counters: nil, uptime: 4))
        XCTAssertNil(calculator.networkRate(counters: ["en0": .init(received: UInt64(UInt32.max) + 1_000, sent: UInt64(UInt32.max) + 2_000)], uptime: 5))
        XCTAssertEqual(
            calculator.networkRate(counters: ["en0": .init(received: UInt64(UInt32.max) + 1_010, sent: UInt64(UInt32.max) + 2_010)], uptime: 6),
            SystemNetworkRate(receivedBytesPerSecond: 10, sentBytesPerSecond: 10)
        )
        calculator.reset()
        XCTAssertNil(calculator.networkRate(counters: ["en0": .init(received: 100, sent: 100)], uptime: 7))
    }

    func testLiveReadIsReadOnlyAndValuesStayInBounds() async {
        let sampler = SystemMetricsSampler()
        let snapshot = await sampler.sample()
        XCTAssertNil(snapshot.cpuFraction)
        XCTAssertNil(snapshot.network)
        if let memory = snapshot.memory {
            XCTAssertGreaterThan(memory.totalBytes, 0)
            XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        }
        if let disk = snapshot.disk {
            XCTAssertGreaterThan(disk.totalBytes, 0)
            XCTAssertLessThanOrEqual(disk.usedBytes, disk.totalBytes)
        }
        await sampler.reset()
        let afterReset = await sampler.sample()
        XCTAssertNil(afterReset.cpuFraction)
        XCTAssertNil(afterReset.network)
    }
}
