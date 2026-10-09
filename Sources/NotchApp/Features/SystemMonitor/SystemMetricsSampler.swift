import Darwin
import Foundation

struct SystemInterfaceCounters: Sendable, Equatable {
    let received: UInt64
    let sent: UInt64
}

// Pure delta handling is kept separate from the OS reads so warm-up, resets,
// interface churn and failed reads can be checked without timing or hardware.
struct SystemMetricsCalculator {
    private var previousCPUTicks: [UInt32]?
    private var previousInterfaces: [String: SystemInterfaceCounters]?
    private var previousNetworkUptime: TimeInterval?

    mutating func reset() {
        previousCPUTicks = nil
        previousInterfaces = nil
        previousNetworkUptime = nil
    }

    mutating func cpuFraction(ticks: [UInt32]?) -> Double? {
        guard let ticks, ticks.count == Int(CPU_STATE_MAX) else {
            previousCPUTicks = nil
            return nil
        }
        defer { previousCPUTicks = ticks }
        guard let previousCPUTicks, previousCPUTicks.count == ticks.count else { return nil }

        // Mach CPU ticks are UInt32 and naturally wrap during long uptimes.
        let differences = zip(ticks, previousCPUTicks).map { $0 &- $1 }
        let total = differences.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return nil }
        let idle = UInt64(differences[Int(CPU_STATE_IDLE)])
        return min(1, max(0, Double(total - idle) / Double(total)))
    }

    static func memoryUsage(
        totalBytes: UInt64,
        pageSize: UInt64,
        activePages: UInt64,
        inactivePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64
    ) -> SystemResourceUsage? {
        guard totalBytes > 0, pageSize > 0 else { return nil }
        let (activeAndInactive, firstOverflow) = activePages.addingReportingOverflow(inactivePages)
        let (withWired, secondOverflow) = activeAndInactive.addingReportingOverflow(wiredPages)
        let (residentPages, thirdOverflow) = withWired.addingReportingOverflow(compressorPages)
        guard !firstOverflow, !secondOverflow, !thirdOverflow else { return nil }
        // File-backed pages are reclaimable cache; purgeable pages are also
        // excluded. This is an estimate, not Activity Monitor memory pressure.
        let afterPurgeable = residentPages - min(residentPages, purgeablePages)
        let usedPages = afterPurgeable - min(afterPurgeable, externalPages)
        let (usedBytes, bytesOverflow) = usedPages.multipliedReportingOverflow(by: pageSize)
        guard !bytesOverflow else { return nil }
        return SystemResourceUsage(
            usedBytes: min(totalBytes, usedBytes),
            totalBytes: totalBytes
        )
    }

    mutating func networkRate(
        counters: [String: SystemInterfaceCounters]?,
        uptime: TimeInterval
    ) -> SystemNetworkRate? {
        guard let counters, uptime.isFinite, uptime >= 0 else {
            previousInterfaces = nil
            previousNetworkUptime = nil
            return nil
        }
        defer {
            previousInterfaces = counters
            previousNetworkUptime = uptime
        }
        guard let previousInterfaces, let previousNetworkUptime else { return nil }
        let elapsed = uptime - previousNetworkUptime
        guard elapsed > 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var compared = false
        for (name, current) in counters {
            guard let previous = previousInterfaces[name],
                  current.received >= previous.received,
                  current.sent >= previous.sent else {
                continue
            }
            compared = true
            let (newReceived, receivedOverflow) = received.addingReportingOverflow(current.received - previous.received)
            let (newSent, sentOverflow) = sent.addingReportingOverflow(current.sent - previous.sent)
            guard !receivedOverflow, !sentOverflow else { return nil }
            received = newReceived
            sent = newSent
        }
        guard compared else { return nil }
        return SystemNetworkRate(
            receivedBytesPerSecond: Double(received) / elapsed,
            sentBytesPerSecond: Double(sent) / elapsed
        )
    }

}

actor SystemMetricsSampler: SystemMetricsSampling {
    private var calculator = SystemMetricsCalculator()
    private var cachedDisk: SystemResourceUsage?
    private var diskSampledAt: TimeInterval?

    init() {}

    func sample() async -> SystemMetricsSnapshot {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let host = mach_host_self()
        defer {
            if host != MACH_PORT_NULL {
                mach_port_deallocate(mach_task_self_, host)
            }
        }
        let cpu = calculator.cpuFraction(ticks: host == MACH_PORT_NULL ? nil : Self.readCPUTicks(host: host))
        let memory = host == MACH_PORT_NULL ? nil : Self.readMemory(host: host)
        let network = calculator.networkRate(counters: Self.readNetworkCounters(), uptime: uptime)

        if diskSampledAt == nil || uptime - (diskSampledAt ?? uptime) >= 30 {
            cachedDisk = Self.readDisk()
            diskSampledAt = uptime
        }
        return SystemMetricsSnapshot(
            sampledAt: now,
            cpuFraction: cpu,
            memory: memory,
            disk: cachedDisk,
            network: network
        )
    }

    func reset() async {
        calculator.reset()
        cachedDisk = nil
        diskSampledAt = nil
    }

    private static func readCPUTicks(host: host_t) -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var count = expectedCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= expectedCount else { return nil }
        return withUnsafeBytes(of: info.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
    }

    private static func readMemory(host: host_t) -> SystemResourceUsage? {
        var info = vm_statistics64_data_t()
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var count = expectedCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard let externalOffset = MemoryLayout<vm_statistics64_data_t>.offset(of: \.external_page_count),
              result == KERN_SUCCESS,
              Int(count) * MemoryLayout<integer_t>.size >= externalOffset + MemoryLayout<natural_t>.size else {
            return nil
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return SystemMetricsCalculator.memoryUsage(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            pageSize: UInt64(pageSize),
            activePages: UInt64(info.active_count),
            inactivePages: UInt64(info.inactive_count),
            wiredPages: UInt64(info.wire_count),
            compressorPages: UInt64(info.compressor_page_count),
            purgeablePages: UInt64(info.purgeable_count),
            externalPages: UInt64(info.external_page_count)
        )
    }

    private static func readDisk() -> SystemResourceUsage? {
        let dataPath = "/System/Volumes/Data"
        let volumePath = FileManager.default.fileExists(atPath: dataPath) ? dataPath : "/"
        let dataVolume = URL(fileURLWithPath: volumePath, isDirectory: true)
        guard let values = try? dataVolume.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity,
            total > 0, available >= 0 else { return nil }
        let totalBytes = UInt64(total)
        return SystemResourceUsage(
            usedBytes: totalBytes - min(totalBytes, UInt64(available)),
            totalBytes: totalBytes
        )
    }

    private static func readNetworkCounters() -> [String: SystemInterfaceCounters]? {
        // NET_RT_IFLIST2 supplies if_data64. getifaddrs supplies if_data with
        // 32-bit byte counters, which can wrap between ordinary UI polls.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, UInt32(pointer.count), nil, &size, nil, 0)
        }
        guard sizeResult == 0, size > 0, size <= 4 * 1_024 * 1_024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let readResult = bytes.withUnsafeMutableBytes { destination in
            mib.withUnsafeMutableBufferPointer { pointer in
                sysctl(pointer.baseAddress, UInt32(pointer.count), destination.baseAddress, &size, nil, 0)
            }
        }
        guard readResult == 0, size <= bytes.count else { return nil }
        var result: [String: SystemInterfaceCounters] = [:]
        let valid = bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < size {
                guard size - offset >= MemoryLayout<UInt16>.size else { return false }
                let messageLength = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= MemoryLayout<UInt16>.size,
                      messageLength <= size - offset else { return false }
                defer { offset += messageLength }
                guard messageLength >= MemoryLayout<if_msghdr2>.size else { continue }
                let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_version == RTM_VERSION,
                      message.ifm_type == RTM_IFINFO2,
                      message.ifm_flags & IFF_UP != 0,
                      message.ifm_flags & IFF_RUNNING != 0,
                      message.ifm_flags & IFF_LOOPBACK == 0 else { continue }
                var nameBytes = [CChar](repeating: 0, count: 64)
                let name = nameBytes.withUnsafeMutableBufferPointer { nameBuffer -> String? in
                    guard let pointer = if_indextoname(UInt32(message.ifm_index), nameBuffer.baseAddress) else {
                        return nil
                    }
                    return String(cString: pointer)
                }
                guard let name, name.hasPrefix("en"),
                      !name.dropFirst(2).isEmpty,
                      name.dropFirst(2).allSatisfy(\.isNumber) else { continue }
                result[name] = SystemInterfaceCounters(
                    received: message.ifm_data.ifi_ibytes,
                    sent: message.ifm_data.ifi_obytes
                )
            }
            return true
        }
        return valid ? result : nil
    }
}
