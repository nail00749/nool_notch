import Foundation

struct SystemProcessGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let applicationPath: String?
    let processes: [MonitoredSystemProcess]
    let cpuPercent: Double?
    let residentMemoryBytes: UInt64
}

enum SystemProcessGrouping {
    /// Uses the outermost app so Electron's nested Helper.app bundles stay with
    /// their application. Path normalization is lexical and does no disk I/O.
    static func applicationPath(forExecutablePath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let normalized = (path as NSString).standardizingPath
        let components = (normalized as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(index + 1)))
    }

    static func groups(processes: [MonitoredSystemProcess], sortedBy sort: SystemProcessSort,
                       limit: Int = 15) -> [SystemProcessGroup] {
        guard limit > 0 else { return [] }
        // An ambiguous PID is never evidence of parent ownership. No mapping is
        // retained across samples, where the same PID can identify a new process.
        let candidates = Dictionary(grouping: processes, by: \.pid)
        let lookup = candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
        var members: [String: [MonitoredSystemProcess]] = [:]
        var applicationPaths: [String: String] = [:]
        for process in processes {
            let app = owningApplication(of: process, lookup: lookup)
            let id = app.map { "app:\($0)" } ?? "process:\(process.id)"
            members[id, default: []].append(process)
            if let app { applicationPaths[id] = app }
        }
        let result = members.map { id, values -> SystemProcessGroup in
            let app = applicationPaths[id]
            let ordered = values.sorted { $0.pid == $1.pid ? $0.id < $1.id : $0.pid < $1.pid }
            var memory: UInt64 = 0
            var cpu = 0.0
            var hasCompleteCPU = true
            for process in ordered {
                let (sum, overflow) = memory.addingReportingOverflow(process.residentMemoryBytes)
                memory = overflow ? .max : sum
                if let value = process.cpuPercent, value.isFinite, value >= 0 {
                    cpu += value
                    if !cpu.isFinite { hasCompleteCPU = false }
                } else {
                    hasCompleteCPU = false
                }
            }
            return SystemProcessGroup(id: id,
                                      name: app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ordered[0].name,
                                      applicationPath: app,
                                      processes: ordered,
                                      cpuPercent: hasCompleteCPU ? cpu : nil,
                                      residentMemoryBytes: memory)
        }
        // Limit only after aggregation: many small helpers can be the largest app.
        return Array(result.sorted { left, right in
            switch sort {
            case .cpu:
                if left.cpuPercent != right.cpuPercent {
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
        }.prefix(limit))
    }

    private static func owningApplication(of process: MonitoredSystemProcess,
                                         lookup: [Int32: MonitoredSystemProcess]) -> String? {
        var current = process
        var visited = Set<String>()
        while visited.insert(current.id).inserted {
            if let app = current.applicationPath.flatMap(applicationPath(forExecutablePath:))
                ?? current.executablePath.flatMap(applicationPath(forExecutablePath:)) {
                return app
            }
            guard let parentPID = current.parentPID, parentPID != current.pid,
                  let parent = lookup[parentPID], parentStartedBeforeChild(parent, child: current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentStartedBeforeChild(_ parent: MonitoredSystemProcess,
                                                 child: MonitoredSystemProcess) -> Bool {
        guard let parentStart = startTime(parent), let childStart = startTime(child) else { return true }
        return parentStart.seconds < childStart.seconds
            || (parentStart.seconds == childStart.seconds && parentStart.microseconds <= childStart.microseconds)
    }

    private static func startTime(_ process: MonitoredSystemProcess) -> (seconds: UInt64, microseconds: UInt64)? {
        let parts = process.id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, Int32(parts[0]) == process.pid,
              let seconds = UInt64(parts[1]), let microseconds = UInt64(parts[2]), microseconds < 1_000_000 else { return nil }
        return (seconds, microseconds)
    }
}
