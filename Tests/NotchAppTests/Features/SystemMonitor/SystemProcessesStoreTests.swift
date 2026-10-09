import XCTest
@testable import NotchApp

@MainActor
final class SystemProcessesStoreTests: XCTestCase {
    func testTopFiveSortsAvailableCPUAndResidentMemory() async throws {
        let samples: [MonitoredSystemProcess] = (1...7).map { number in
            let cpu: Double? = number == 7 ? nil : Double(number * 25)
            return MonitoredSystemProcess(id: "\(number)", pid: Int32(number), name: "Process \(number)",
                                   cpuPercent: cpu,
                                   residentMemoryBytes: UInt64(number * 1_000))
        }
        let store = SystemProcessesStore(sampler: ProcessStoreTestSampler(processes: samples))
        store.start(sort: .memory)
        defer { store.stop() }
        for _ in 0..<100 {
            if store.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.topProcesses.map(\.pid), [7, 6, 5, 4, 3])
        store.sort = .cpu
        XCTAssertEqual(store.topProcesses.map(\.pid), [6, 5, 4, 3, 2])
        XCTAssertEqual(store.topProcesses.first?.cpuPercent, 150)
        store.stop()
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.topProcesses.isEmpty)
    }

    func testClosingDiscardsInFlightProcessSnapshot() async throws {
        let sampler = ProcessStoreTestSampler(processes: [], blocked: true)
        let store = SystemProcessesStore(sampler: sampler)
        store.start(sort: .cpu)
        for _ in 0..<100 {
            if await sampler.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await sampler.waiting
        XCTAssertTrue(waiting)
        store.stop()
        await sampler.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.sampleCount, 0)
        XCTAssertFalse(store.isRunning)
    }
}

private actor ProcessStoreTestSampler: SystemProcessSampling {
    let processes: [MonitoredSystemProcess]
    let blocked: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    init(processes: [MonitoredSystemProcess], blocked: Bool = false) {
        self.processes = processes
        self.blocked = blocked
    }
    func reset() {}
    func sample() async -> SystemProcessSnapshot {
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return SystemProcessSnapshot(sampledAt: Date(), processes: processes, skippedProcessCount: 0)
    }
    func release() { continuation?.resume(); continuation = nil }
}
