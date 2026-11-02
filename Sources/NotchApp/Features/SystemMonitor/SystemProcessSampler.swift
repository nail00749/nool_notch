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
    let parentPID: Int32?
    let executablePath: String?
    let applicationPath: String?

    init(id: String, pid: Int32, name: String, cpuPercent: Double?, residentMemoryBytes: UInt64,
         parentPID: Int32? = nil, executablePath: String? = nil, applicationPath: String? = nil) {
        self.id = id
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.applicationPath = applicationPath
    }
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
    let parentPID: Int32?
    let executablePath: String?
    let applicationPath: String?

    init(id: String, pid: Int32, name: String, userTime: UInt64, systemTime: UInt64,
         residentMemoryBytes: UInt64, parentPID: Int32? = nil,
         executablePath: String? = nil, applicationPath: String? = nil) {
        self.id = id
        self.pid = pid
        self.name = name
        self.userTime = userTime
        self.systemTime = systemTime
        self.residentMemoryBytes = residentMemoryBytes
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.applicationPath = applicationPath
    }
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
            residentMemoryBytes: reading.residentMemoryBytes,
            parentPID: reading.parentPID,
            executablePath: reading.executablePath,
            applicationPath: reading.applicationPath
        )
    }
}

actor SystemProcessSampler: SystemProcessSampling {
    private static let maximumPIDs = 16_384
    private var calculator: SystemProcessCalculator
    private struct PathMetadata {
        let executablePath: String?
        let applicationPath: String?
    }
    // Includes failed lookups; protected processes must not trigger a path read
    // every two seconds. Entries are keyed by PID plus kernel start time.
    private var pathCache: [String: PathMetadata] = [:]

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
            pathCache.removeAll(keepingCapacity: true)
            return SystemProcessSnapshot(sampledAt: sampledAt, processes: [], skippedProcessCount: 0)
        }

        var readings: [SystemProcessRawReading] = []
        readings.reserveCapacity(pids.count)
        var skipped = 0
        for pid in pids {
            if Task.isCancelled {
                calculator.reset()
                pathCache.removeAll(keepingCapacity: true)
                return SystemProcessSnapshot(sampledAt: sampledAt, processes: [], skippedProcessCount: skipped)
            }
            guard let reading = readProcess(pid) else {
                skipped += 1 // Gone or protected by the OS; no guessed values.
                continue
            }
            readings.append(reading)
        }
        let currentIDs = Set(readings.map(\.id))
        pathCache = pathCache.filter { currentIDs.contains($0.key) }
        let processes = calculator.calculate(readings, uptime: ProcessInfo.processInfo.systemUptime)
        return SystemProcessSnapshot(sampledAt: sampledAt, processes: processes, skippedProcessCount: skipped)
    }

    func reset() async {
        calculator.reset()
        pathCache.removeAll(keepingCapacity: true)
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

    private func readProcess(_ pid: Int32) -> SystemProcessRawReading? {
        // One kernel read keeps the name, start time and counters on the same PID.
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard result == size, info.pbsd.pbi_pid == UInt32(pid),
              info.pbsd.pbi_start_tvusec < 1_000_000 else { return nil }

        let name = Self.decodedName(info.pbsd.pbi_name).isEmpty
            ? Self.decodedName(info.pbsd.pbi_comm)
            : Self.decodedName(info.pbsd.pbi_name)
        guard !name.isEmpty else { return nil }
        let id = "\(pid):\(info.pbsd.pbi_start_tvsec):\(info.pbsd.pbi_start_tvusec)"
        let metadata: PathMetadata
        if let cached = pathCache[id] {
            metadata = cached
        } else {
            let executablePath = Self.readExecutablePath(pid, expectedInfo: info.pbsd)
            metadata = PathMetadata(executablePath: executablePath,
                                    applicationPath: executablePath.flatMap(SystemProcessGrouping.applicationPath(forExecutablePath:)))
            if pathCache.count < Self.maximumPIDs { pathCache[id] = metadata }
        }
        return SystemProcessRawReading(
            id: id,
            pid: pid,
            name: (name as NSString).lastPathComponent,
            userTime: info.ptinfo.pti_total_user,
            systemTime: info.ptinfo.pti_total_system,
            residentMemoryBytes: info.ptinfo.pti_resident_size,
            parentPID: info.pbsd.pbi_ppid > 0 ? Int32(exactly: info.pbsd.pbi_ppid) : nil,
            executablePath: metadata.executablePath,
            applicationPath: metadata.applicationPath
        )
    }

    private static func readExecutablePath(_ pid: Int32, expectedInfo: proc_bsdinfo) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN in the public SDK, but
        // that expression macro is not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        // A process may exit and its PID may be reused between the two kernel
        // calls. Do not attach the replacement's executable to the old reading.
        var confirmed = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &confirmed) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size, confirmed.pbi_pid == expectedInfo.pbi_pid,
              confirmed.pbi_start_tvsec == expectedInfo.pbi_start_tvsec,
              confirmed.pbi_start_tvusec == expectedInfo.pbi_start_tvusec else { return nil }
        let path = buffer.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    private static func decodedName<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
