import XCTest
@testable import NotchApp

final class SystemMetricsHistoryTests: XCTestCase {
    private func sample(_ time: Double, cpu: Double? = 0.4) -> SystemMetricsSnapshot {
        .init(sampledAt: Date(timeIntervalSince1970: time), cpuFraction: cpu, memory: nil, disk: nil, network: nil)
    }
    func testHistoryHasBoundedTimeWindowAndCount() {
        var history = SystemMetricsHistory()
        for value in 0..<200 { history.append(sample(Double(value) * 2)) }
        XCTAssertEqual(history.samples.count, 61)
        XCTAssertEqual(history.samples.first?.sampledAt, Date(timeIntervalSince1970: 278))
        for value in 0..<200 { history.append(sample(400 + Double(value) * 0.1)) }
        XCTAssertEqual(history.samples.count, 120)
    }
    func testDuplicateAndBackwardClockDoNotInventMoreHistory() {
        var history = SystemMetricsHistory()
        history.append(sample(50))
        history.append(sample(50, cpu: 0.8))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.last?.cpuFraction, 0.8)
        history.append(sample(40))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.last?.sampledAt, Date(timeIntervalSince1970: 40))
    }
    func testMissingReadingRemainsGapInsteadOfZero() {
        var history = SystemMetricsHistory()
        history.append(sample(50))
        history.append(sample(52, cpu: nil))
        history.append(sample(54))
        XCTAssertEqual(history.samples.count, 3)
        XCTAssertNil(history.samples[1].cpuFraction)
    }
}
