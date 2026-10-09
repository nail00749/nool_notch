import XCTest
@testable import NotchApp

final class LidAngleSensorTests: XCTestCase {
    func testRestartDuringBlockedReadUsesOneWorkerAndDiscardsOldResult() async {
        let started = expectation(description: "First read started")
        let latest = expectation(description: "Latest registration receives reading")
        let reader = BlockingReader(started: started)
        let worker = LidAnglePollingWorker(reader: reader)
        worker.start { _ in XCTFail("Retired registration received a reading") }
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<30 {
            worker.stop()
            worker.start { _ in XCTFail("Intermediate registration received a reading") }
        }
        worker.stop()
        worker.start { reading in
            XCTAssertEqual(reading, .angle(90))
            worker.stop()
            latest.fulfill()
        }
        XCTAssertEqual(reader.readCount, 1)
        reader.releaseFirstRead.signal()
        await fulfillment(of: [latest], timeout: 2)
        worker.stop()
        XCTAssertEqual(reader.readCount, 2)
    }

    func testDecodesLittleEndianAngleWithReportID() {
        XCTAssertEqual(LidReportDecoder.angle(from: [1, 90, 0]), 90)
        XCTAssertEqual(LidReportDecoder.angle(from: [1, 0xB4, 0]), 180)
    }

    func testRejectsMalformedOrImplausibleReports() {
        XCTAssertNil(LidReportDecoder.angle(from: []))
        XCTAssertNil(LidReportDecoder.angle(from: [2, 90, 0]))
        XCTAssertNil(LidReportDecoder.angle(from: [1, 90]))
        XCTAssertNil(LidReportDecoder.angle(from: [1, 0xB5, 0]))
        XCTAssertNil(LidReportDecoder.angle(from: [1, 0, 1]))
    }

    private final class BlockingReader: LidAngleReading, @unchecked Sendable {
        let releaseFirstRead = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reads = 0
        private var reading = false
        private let started: XCTestExpectation
        init(started: XCTestExpectation) { self.started = started }
        var readCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
        func read() -> LidSensorReading {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock()
            XCTAssertFalse(reading, "Concurrent device access")
            reading = true
            reads += 1
            let first = reads == 1
            lock.unlock()
            if first {
                started.fulfill()
                _ = releaseFirstRead.wait(timeout: .now() + 3)
            }
            lock.lock()
            reading = false
            lock.unlock()
            return .angle(first ? 123 : 90)
        }
        func close() {
            lock.lock()
            XCTAssertFalse(reading, "Device closed during a read")
            lock.unlock()
        }
    }
}
