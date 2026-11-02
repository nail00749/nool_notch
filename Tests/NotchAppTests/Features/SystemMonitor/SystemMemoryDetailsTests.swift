import Dispatch
import XCTest
@testable import NotchApp

final class SystemMemoryDetailsTests: XCTestCase {
    func testPageCountersDescribePhysicalCompressorFileBackedAndWiredMemory() throws {
        let details = try XCTUnwrap(SystemMemoryDetailsCalculator.make(pageSize: 16_384,
            compressorPages: 100, externalPages: 200, wiredPages: 300,
            swapUsedBytes: 4_000, swapTotalBytes: 8_000,
            pressureRawValue: UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue)))
        XCTAssertEqual(details.compressedBytes, 1_638_400)
        XCTAssertEqual(details.cachedBytes, 3_276_800)
        XCTAssertEqual(details.wiredBytes, 4_915_200)
        XCTAssertEqual(details.swapUsedBytes, 4_000)
        XCTAssertEqual(details.swapTotalBytes, 8_000)
        XCTAssertEqual(details.pressure, .warning)
    }

    func testOverflowAndMissingPageSizeCannotProduceFabricatedByteCounts() throws {
        XCTAssertEqual(SystemMemoryDetailsCalculator.bytes(pages: UInt64.max, pageSize: 1), UInt64.max)
        XCTAssertNil(SystemMemoryDetailsCalculator.bytes(pages: UInt64.max, pageSize: 2))
        XCTAssertNil(SystemMemoryDetailsCalculator.bytes(pages: 12, pageSize: 0))
        XCTAssertNil(SystemMemoryDetailsCalculator.bytes(pages: 12, pageSize: nil))
        XCTAssertNil(SystemMemoryDetailsCalculator.bytes(pages: nil, pageSize: 16_384))
        XCTAssertEqual(SystemMemoryDetailsCalculator.bytes(pages: 0, pageSize: 16_384), 0)
        let details = try XCTUnwrap(SystemMemoryDetailsCalculator.make(pageSize: 2,
            compressorPages: UInt64.max, externalPages: 5, wiredPages: UInt64.max))
        XCTAssertNil(details.compressedBytes)
        XCTAssertNil(details.wiredBytes)
        XCTAssertEqual(details.cachedBytes, 10, "One overflowing counter must not hide independent valid counters")
    }

    func testUnavailableDataStaysNilButMeasuredZeroRemainsZero() throws {
        XCTAssertNil(SystemMemoryDetailsCalculator.make())
        XCTAssertNil(SystemMemoryDetailsCalculator.make(pressureRawValue: 0))
        XCTAssertNil(SystemMemoryDetailsCalculator.make(swapUsedBytes: nil, swapTotalBytes: 0))
        let zero = try XCTUnwrap(SystemMemoryDetailsCalculator.make(pageSize: 4_096,
            compressorPages: 0, externalPages: 0, wiredPages: 0, swapUsedBytes: 0, swapTotalBytes: 0))
        XCTAssertEqual(zero.compressedBytes, 0)
        XCTAssertEqual(zero.cachedBytes, 0)
        XCTAssertEqual(zero.wiredBytes, 0)
        XCTAssertEqual(zero.swapUsedBytes, 0)
        XCTAssertEqual(zero.swapTotalBytes, 0)
        XCTAssertNil(zero.pressure, "Zero memory usage does not establish normal memory pressure")
    }

    func testPressureMapsOnlyKnownDispatchLevels() {
        XCTAssertEqual(SystemMemoryDetailsCalculator.pressure(rawValue: 1), .normal)
        XCTAssertEqual(SystemMemoryDetailsCalculator.pressure(rawValue: 2), .warning)
        XCTAssertEqual(SystemMemoryDetailsCalculator.pressure(rawValue: 4), .critical)
        for unknown: UInt32? in [nil, 0, 3, 5, 6, 7, 100, UInt32.max] {
            XCTAssertNil(SystemMemoryDetailsCalculator.pressure(rawValue: unknown), "Never guess pressure from a percentage or unknown value")
        }
        XCTAssertEqual(SystemMemoryPressure.normal.title, "Нормальное")
        XCTAssertEqual(SystemMemoryPressure.warning.title, "Повышенное")
        XCTAssertEqual(SystemMemoryPressure.critical.title, "Критическое")
    }

    func testInvalidSwapReadingDoesNotDiscardIndependentVMOrPressureData() throws {
        let details = try XCTUnwrap(SystemMemoryDetailsCalculator.make(pageSize: 4_096, wiredPages: 2,
            swapUsedBytes: 9, swapTotalBytes: 8, pressureRawValue: 4))
        XCTAssertNil(details.swapUsedBytes)
        XCTAssertNil(details.swapTotalBytes)
        XCTAssertEqual(details.wiredBytes, 8_192)
        XCTAssertEqual(details.pressure, .critical)
        let sysctlOnly = try XCTUnwrap(SystemMemoryDetailsCalculator.make(swapUsedBytes: 1, swapTotalBytes: 2))
        XCTAssertNil(sysctlOnly.compressedBytes)
        XCTAssertNil(sysctlOnly.cachedBytes)
        XCTAssertNil(sysctlOnly.wiredBytes)
        XCTAssertEqual(sysctlOnly.swapUsedBytes, 1)
    }

    func testSnapshotExistingInitializerRemainsCompatibleAndDetailsParticipateInEquality() {
        let date = Date(timeIntervalSince1970: 1)
        let old = SystemMetricsSnapshot(sampledAt: date, cpuFraction: nil, memory: nil, disk: nil, network: nil)
        XCTAssertNil(old.memoryDetails)
        let extended = SystemMetricsSnapshot(sampledAt: date, cpuFraction: nil, memory: nil, disk: nil, network: nil,
            memoryDetails: .init(pressure: .normal))
        XCTAssertNotEqual(old, extended)
    }

    func testOptInLiveMemoryDetailsProbe() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_MEMORY_DETAILS_LIVE_TEST"] == "1" else {
            throw XCTSkip("Opt-in read-only live memory counter probe")
        }
        let snapshot = await SystemMetricsSampler().sample()
        let usage = try XCTUnwrap(snapshot.memory)
        let details = try XCTUnwrap(snapshot.memoryDetails)
        XCTAssertNotNil(details.compressedBytes)
        XCTAssertNotNil(details.cachedBytes)
        XCTAssertNotNil(details.wiredBytes)
        if let compressed = details.compressedBytes { XCTAssertLessThanOrEqual(compressed, usage.totalBytes) }
        if let wired = details.wiredBytes { XCTAssertLessThanOrEqual(wired, usage.totalBytes) }
        if let used = details.swapUsedBytes, let total = details.swapTotalBytes { XCTAssertLessThanOrEqual(used, total) }
    }
}
