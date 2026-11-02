import XCTest
@testable import NotchApp

final class ReactorTelemetryHistoryTests: XCTestCase {
    func testHistoryIsBoundedAndDoesNotDuplicateOrInventSamples() {
        var history = ReactorTelemetryHistory()
        for i in 0..<100 { history.append(sample(time: Double(i) * 2)) }
        XCTAssertEqual(history.samples.count, 61)
        XCTAssertEqual(history.samples.first?.date, Date(timeIntervalSince1970: 78))
        history.append(sample(time: 198))
        history.append(sample(time: 196))
        XCTAssertEqual(history.samples.count, 61)
        history.append(sample(time: 210))
        XCTAssertEqual(history.samples.count, 1, "A pause must not draw a fictional connecting trace")
        history.append(nil)
        XCTAssertTrue(history.samples.isEmpty)
        XCTAssertNil(history.networkPeak)
    }

    func testMissingAndInvalidMetricsRemainGaps() {
        var history = ReactorTelemetryHistory()
        history.append(sample(time: 0, cpu: .nan, received: .infinity, sent: -1))
        XCTAssertNil(history.samples.first?.cpu)
        XCTAssertNil(history.networkPeak)
        history.append(sample(time: 2, cpu: 2, received: 0, sent: 0))
        XCTAssertEqual(history.samples.last?.cpu, 1)
        XCTAssertEqual(history.networkPeak, 0)
        history.append(sample(time: 4, received: 200, sent: 300))
        XCTAssertEqual(history.networkPeak, 300)
    }

    private func sample(time: Double, cpu: Double = 0.3, received: Double = 100, sent: Double = 20) -> SystemMetricsSnapshot {
        .init(sampledAt: Date(timeIntervalSince1970: time), cpuFraction: cpu,
              memory: nil, disk: nil, network: .init(receivedBytesPerSecond: received, sentBytesPerSecond: sent))
    }
}
