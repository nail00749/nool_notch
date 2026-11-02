import XCTest
@testable import NotchApp

final class SystemProcessGroupingTests: XCTestCase {
    func testOutermostApplicationPathNormalizesNestedElectronHelpers() {
        XCTAssertEqual(SystemProcessGrouping.applicationPath(forExecutablePath:
            "/Applications/Example.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper"),
            "/Applications/Example.app")
        XCTAssertEqual(SystemProcessGrouping.applicationPath(forExecutablePath:
            "/Applications/Unused/../Example.app/Contents/MacOS/Example"), "/Applications/Example.app")
        XCTAssertNil(SystemProcessGrouping.applicationPath(forExecutablePath: "/usr/libexec/helper"))
        XCTAssertNil(SystemProcessGrouping.applicationPath(forExecutablePath: "relative/Example.app/Example"))
    }

    func testHelpersAggregateByBundleAndCurrentParentLineage() throws {
        let processes = [
            process(10, app: "/Applications/Example.app", cpu: 15, memory: 100),
            process(11, executable: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/helper", cpu: 25, memory: 200),
            process(12, parent: 10, executable: "/usr/libexec/child", cpu: 5, memory: 300),
            process(13, parent: 12, cpu: 2, memory: 400)
        ]
        let groups = SystemProcessGrouping.groups(processes: processes, sortedBy: .cpu)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.id, "app:/Applications/Example.app")
        XCTAssertEqual(group.name, "Example")
        XCTAssertEqual(group.processes.map(\.pid), [10, 11, 12, 13])
        XCTAssertEqual(group.cpuPercent, 47)
        XCTAssertEqual(group.residentMemoryBytes, 1_000)
    }

    func testDistinctApplicationKeepsOwnershipEvenWhenParentIsAnotherApplication() {
        let groups = SystemProcessGrouping.groups(processes: [
            process(10, app: "/Applications/First.app"),
            process(11, parent: 10, app: "/Applications/Second.app"),
            process(12, parent: 11)
        ], sortedBy: .memory)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.applicationPath == "/Applications/First.app" }?.processes.map(\.pid), [10])
        XCTAssertEqual(groups.first { $0.applicationPath == "/Applications/Second.app" }?.processes.map(\.pid), [11, 12])
    }

    func testUnrelatedSameNamedProcessesAndLaunchdChildrenStaySeparate() {
        let processes = [
            process(1, name: "launchd"),
            process(10, parent: 1, name: "Helper"),
            process(11, parent: 1, name: "Helper"),
            process(12, parent: 1, name: "WebContent", executable: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/WebContent")
        ]
        let groups = SystemProcessGrouping.groups(processes: processes, sortedBy: .cpu)
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.applicationPath == nil && $0.processes.count == 1 })
        XCTAssertEqual(Set(groups.map(\.name)), ["launchd", "Helper", "WebContent"])
    }

    func testMissingParentsAndCyclesHaveBoundedIndependentFallbacks() {
        let groups = SystemProcessGrouping.groups(processes: [
            process(10, parent: 11), process(11, parent: 10),
            process(12, parent: 999), process(13, parent: 13)
        ], sortedBy: .cpu)
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.applicationPath == nil && $0.processes.count == 1 })
    }

    func testReusedParentPIDCannotClaimAnOlderChildOrPersistOldOwnership() {
        let oldApp = process(10, id: "10:100:0", app: "/Applications/Old.app")
        let child = process(11, id: "11:200:0", parent: 10)
        XCTAssertEqual(SystemProcessGrouping.groups(processes: [oldApp, child], sortedBy: .cpu).count, 1)
        let replacement = process(10, id: "10:300:0", app: "/Applications/New.app")
        let second = SystemProcessGrouping.groups(processes: [replacement, child], sortedBy: .cpu)
        XCTAssertEqual(second.count, 2)
        XCTAssertNil(second.first { $0.processes.contains { $0.pid == 11 } }?.applicationPath)
        let missing = SystemProcessGrouping.groups(processes: [child], sortedBy: .cpu)
        XCTAssertNil(missing.first?.applicationPath)
    }

    func testAmbiguousCurrentPIDDoesNotProvideOwnership() {
        let groups = SystemProcessGrouping.groups(processes: [
            process(10, id: "10:100:0", app: "/Applications/Old.app"),
            process(10, id: "10:300:0", app: "/Applications/New.app"),
            process(11, id: "11:400:0", parent: 10)
        ], sortedBy: .cpu)
        XCTAssertEqual(groups.count, 3)
        XCTAssertNil(groups.first { $0.processes.contains { $0.pid == 11 } }?.applicationPath)
    }

    func testAggregateBeforeLimitAndSortBySelectedMetric() {
        var processes = (1...20).map { number in
            process(Int32(number), app: "/Applications/Many Helpers.app", cpu: 2, memory: 10)
        }
        processes.append(process(100, name: "Single CPU", cpu: 30, memory: 100))
        processes.append(process(101, name: "Single RAM", cpu: 1, memory: 300))
        let cpu = SystemProcessGrouping.groups(processes: processes, sortedBy: .cpu, limit: 1)
        XCTAssertEqual(cpu.first?.applicationPath, "/Applications/Many Helpers.app")
        XCTAssertEqual(cpu.first?.cpuPercent, 40)
        XCTAssertEqual(SystemProcessGrouping.groups(processes: processes, sortedBy: .memory, limit: 1).first?.name, "Single RAM")
        XCTAssertTrue(SystemProcessGrouping.groups(processes: processes, sortedBy: .cpu, limit: 0).isEmpty)
    }

    func testIncompleteCPUStaysUnknownAndResidentMemorySaturatesWithoutOverflow() {
        let groups = SystemProcessGrouping.groups(processes: [
            process(10, app: "/Applications/Warming.app", cpu: 80, memory: .max),
            process(11, app: "/Applications/Warming.app", cpu: nil, memory: 1),
            process(12, name: "Measured", cpu: 1)
        ], sortedBy: .cpu)
        XCTAssertEqual(groups.first?.name, "Measured")
        let warming = groups.first { $0.applicationPath != nil }
        XCTAssertNil(warming?.cpuPercent)
        XCTAssertEqual(warming?.residentMemoryBytes, .max)
        let overflowCPU = SystemProcessGrouping.groups(processes: [
            process(10, app: "/Applications/Overflow.app", cpu: .greatestFiniteMagnitude),
            process(11, app: "/Applications/Overflow.app", cpu: .greatestFiniteMagnitude)
        ], sortedBy: .cpu)
        XCTAssertNil(overflowCPU.first?.cpuPercent)
    }

    func testCalculatorPreservesMetadataAndBackwardCompatibleInitializers() {
        var calculator = SystemProcessCalculator(nanosecondsPerTick: 1)
        let reading = SystemProcessRawReading(id: "42:100:0", pid: 42, name: "Example", userTime: 0,
            systemTime: 0, residentMemoryBytes: 100, parentPID: 10,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example", applicationPath: "/Applications/Example.app")
        let process = calculator.calculate([reading], uptime: 1).first
        XCTAssertEqual(process?.parentPID, 10)
        XCTAssertEqual(process?.executablePath, reading.executablePath)
        XCTAssertEqual(process?.applicationPath, reading.applicationPath)
        let oldReading = SystemProcessRawReading(id: "old", pid: 1, name: "old", userTime: 0, systemTime: 0, residentMemoryBytes: 0)
        XCTAssertNil(oldReading.parentPID)
    }

    private func process(_ pid: Int32, id: String? = nil, parent: Int32? = nil, name: String = "Helper",
                         app: String? = nil, executable: String? = nil, cpu: Double? = 1,
                         memory: UInt64 = 1) -> MonitoredSystemProcess {
        MonitoredSystemProcess(id: id ?? "\(pid):100:0", pid: pid, name: name,
                               cpuPercent: cpu, residentMemoryBytes: memory,
                               parentPID: parent, executablePath: executable, applicationPath: app)
    }
}

@MainActor
final class SystemProcessGroupedStoreTests: XCTestCase {
    func testGroupsUseTopFifteenAfterAggregationAndRespondToSort() async throws {
        var processes = (1...20).map { number in
            MonitoredSystemProcess(id: "\(number)", pid: Int32(number), name: "Process \(number)",
                                   cpuPercent: Double(number), residentMemoryBytes: UInt64(100 - number))
        }
        processes.append(contentsOf: (101...120).map { number in
            MonitoredSystemProcess(id: "\(number)", pid: Int32(number), name: "Small helper",
                                   cpuPercent: 2, residentMemoryBytes: 10, applicationPath: "/Applications/Grouped.app")
        })
        let store = SystemProcessesStore(sampler: GroupedStoreSampler(processes: processes))
        store.start(sort: .cpu)
        defer { store.stop() }
        for _ in 0..<100 {
            if store.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.groups.count, 15)
        XCTAssertEqual(store.groups.first?.name, "Grouped")
        XCTAssertEqual(store.groups.first?.cpuPercent, 40)
        XCTAssertEqual(store.topProcesses.count, 5)
        XCTAssertEqual(store.topProcesses.first?.pid, 20)
        store.sort = .memory
        XCTAssertEqual(store.groups.first?.residentMemoryBytes, 200)
        XCTAssertEqual(store.groups[1].processes.first?.pid, 1)
        store.stop()
        XCTAssertTrue(store.groups.isEmpty)
    }
}

private actor GroupedStoreSampler: SystemProcessSampling {
    let processes: [MonitoredSystemProcess]
    init(processes: [MonitoredSystemProcess]) { self.processes = processes }
    func reset() {}
    func sample() async -> SystemProcessSnapshot {
        SystemProcessSnapshot(sampledAt: Date(), processes: processes, skippedProcessCount: 0)
    }
}
