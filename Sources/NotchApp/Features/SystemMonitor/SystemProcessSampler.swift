import Darwin
import Foundation

enum SystemProcessSort: String, CaseIterable, Sendable {
    case cpu
    case memory

    var title: String {
        switch self {
        case .cpu: "ЦП"
        case .memory: "ОЗУ"
        }
    }
}

struct MonitoredSystemProcess: Identifiable, Sendable, Equatable {
    // The process start timestamp prevents a reused PID from inheriting CPU history.
    let id: String
    let pid: Int32
    let name: String
    // Activity Monitor's per-core convention: a multicore process may exceed 100%.
    let cpuPercent: Double?
    let residentMemoryBytes: UInt64
}

struct SystemProcessSnapshot: Sendable {
    let sampledAt: Date
    let processes: [MonitoredSystemProcess]
    let skippedProcessCount: Int

    func topProcesses(sortedBy sort: SystemProcessSort, limit: Int = 5) -> [MonitoredSystemProcess] {
        Array(processes.sorted { left, right in
            switch sort {
            case .cpu:
                if left.cpuPercent != right.cpuPercent {
                    // Processes without a second CPU sample appear after measured ones.
                    return (left.cpuPercent ?? -.infinity) > (right.cpuPercent ?? -.infinity)
                }
                if left.residentMemoryBytes != right.residentMemoryBytes {
                    return left.residentMemoryBytes > right.residentMemoryBytes
                }
            case .memory:
                if left.residentMemoryBytes != right.residentMemoryBytes {
                    return left.residentMemoryBytes > right.residentMemoryBytes
                }
                if left.cpuPercent != right.cpuPercent {
                    return (left.cpuPercent ?? -.infinity) > (right.cpuPercent ?? -.infinity)
                }
            }
            return left.id < right.id
        }.prefix(max(0, limit)))
    }
}

protocol SystemProcessSampling: Sendable {
    func sample() async -> SystemProcessSnapshot
    func reset() async
}

struct SystemProcessRawReading: Sendable {
    let id: String
    let pid: Int32
    let name: String
    let userTime: UInt64
    let systemTime: UInt64
    let residentMemoryBytes: UInt64
}

// Calculation is independent of libproc so PID reuse, warm-up and counter
// discontinuities can be tested deterministically.
struct SystemProcessCalculator {
    private struct CPUTime {
        let user: UInt64
        let system: UInt64
    }

    private var previous: [String: CPUTime] = [:]
    private var previousUptime: TimeInterval?
    let nanosecondsPerTick: Double

    init(nanosecondsPerTick: Double) {
        self.nanosecondsPerTick = nanosecondsPerTick
    }

    mutating func reset() {
        previous.removeAll(keepingCapacity: true)
        previousUptime = nil
    }

    mutating func calculate(
        _ readings: [SystemProcessRawReading],
        uptime: TimeInterval
    ) -> [MonitoredSystemProcess] {
        guard uptime.isFinite, uptime >= 0 else {
            reset()
            return readings.map { makeProcess($0, cpuPercent: nil) }
        }
        let elapsed = previousUptime.map { uptime - $0 }
        if let elapsed, elapsed <= 0 { reset() }

        var next: [String: CPUTime] = [:]
        next.reserveCapacity(readings.count)
        let processes = readings.map { reading in
            let current = CPUTime(user: reading.userTime, system: reading.systemTime)
            let cpuPercent: Double?
            if let old = previous[reading.id],
               let elapsed, elapsed > 0,
               current.user >= old.user,
               current.system >= old.system {
                let userDelta = current.user - old.user
                let systemDelta = current.system - old.system
                let (ticks, overflow) = userDelta.addingReportingOverflow(systemDelta)
                let percent = Double(ticks) * nanosecondsPerTick / (elapsed * 1_000_000_000) * 100
                cpuPercent = !overflow && percent.isFinite && percent >= 0 ? percent : nil
            } else {
                cpuPercent = nil
            }
            next[reading.id] = current
            return makeProcess(reading, cpuPercent: cpuPercent)
        }
        previous = next
        previousUptime = uptime
        return processes
    }

    private func makeProcess(_ reading: SystemProcessRawReading, cpuPercent: Double?) -> MonitoredSystemProcess {
        MonitoredSystemProcess(
            id: reading.id,
            pid: reading.pid,
            name: reading.name,
            cpuPercent: cpuPercent,
            residentMemoryBytes: reading.residentMemoryBytes
        )
    }
}

actor SystemProcessSampler: SystemProcessSampling {
    private static let maximumPIDs = 16_384
    private var calculator: SystemProcessCalculator

    init() {
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        let scale = result == KERN_SUCCESS && timebase.denom != 0
            ? Double(timebase.numer) / Double(timebase.denom)
            : .nan
        calculator = SystemProcessCalculator(nanosecondsPerTick: scale)
    }

    func sample() async -> SystemProcessSnapshot {
        let sampledAt = Date()
        guard !Task.isCancelled, let pids = Self.listPIDs() else {
            calculator.reset()
            return SystemProcessSnapshot(sampledAt: sampledAt, processes: [], skippedProcessCount: 0)
        }

        var readings: [SystemProcessRawReading] = []
        readings.reserveCapacity(pids.count)
        var skipped = 0
        for pid in pids {
            if Task.isCancelled {
                calculator.reset()
                return SystemProcessSnapshot(sampledAt: sampledAt, processes: [], skippedProcessCount: skipped)
            }
            guard let reading = Self.readProcess(pid) else {
                skipped += 1 // Gone or protected by the OS; no guessed values.
                continue
            }
            readings.append(reading)
        }
        let processes = calculator.calculate(readings, uptime: ProcessInfo.processInfo.systemUptime)
        return SystemProcessSnapshot(sampledAt: sampledAt, processes: processes, skippedProcessCount: skipped)
    }

    func reset() async {
        calculator.reset()
    }

    private static func listPIDs() -> [Int32]? {
        // A fixed upper bound avoids untrusted process counts becoming allocations.
        var pids = [Int32](repeating: 0, count: maximumPIDs)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard count > 0, count < maximumPIDs else { return nil }
        return Array(pids.prefix(Int(count)).filter { $0 > 0 })
    }

    private static func readProcess(_ pid: Int32) -> SystemProcessRawReading? {
        // One kernel read keeps the name, start time and counters on the same PID.
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard result == size, info.pbsd.pbi_pid == UInt32(pid),
              info.pbsd.pbi_start_tvusec < 1_000_000 else { return nil }

        let name = decodedName(info.pbsd.pbi_name).isEmpty
            ? decodedName(info.pbsd.pbi_comm)
            : decodedName(info.pbsd.pbi_name)
        guard !name.isEmpty else { return nil }
        let id = "\(pid):\(info.pbsd.pbi_start_tvsec):\(info.pbsd.pbi_start_tvusec)"
        return SystemProcessRawReading(
            id: id,
            pid: pid,
            name: (name as NSString).lastPathComponent,
            userTime: info.ptinfo.pti_total_user,
            systemTime: info.ptinfo.pti_total_system,
            residentMemoryBytes: info.ptinfo.pti_resident_size
        )
    }

    private static func decodedName<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
