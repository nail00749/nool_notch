#if DEBUG
import AppKit
import QuartzCore
import os.signpost

/// Explicit local profiling only. Never starts timers or records user content
/// during normal launches, and is absent from release builds.
@MainActor
final class NotchExpansionProfile: NSObject {
    private let log = OSLog(subsystem: "com.nailuyltyev.NotchApp", category: "ExpansionProfile")
    private var link: CADisplayLink?
    private var task: Task<Void, Never>?
    private var samples: [Double] = []
    private var previous: CFTimeInterval?
    private var results: [[String: Any]] = []

    func start(screen: NSScreen, setExpanded: @escaping (Bool) -> Void) {
        guard ProcessInfo.processInfo.environment["NOOL_PROFILE_EXPANSION"] == "1" else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                self.link = screen.displayLink(target: self, selector: #selector(self.tick(_:)))
                self.link?.add(to: .main, forMode: .common)
                for cycle in 0..<8 {
                    for expanded in [true, false] {
                        self.samples = []
                        self.previous = CACurrentMediaTime()
                        let cpu = Self.cpuTime()
                        let start = CACurrentMediaTime()
                        os_signpost(.begin, log: self.log, name: "Notch transition", "cycle=%d expanded=%d", cycle, expanded ? 1 : 0)
                        setExpanded(expanded)
                        try await Task.sleep(for: .seconds(0.65))
                        os_signpost(.end, log: self.log, name: "Notch transition")
                        let sorted = self.samples.sorted()
                        self.results.append([
                            "cycle": cycle, "expanded": expanded,
                            "wall_ms": (CACurrentMediaTime() - start) * 1000,
                            "cpu_ms": (Self.cpuTime() - cpu) * 1000,
                            "callbacks": sorted.count,
                            "callback_intervals_ms": self.samples,
                            "callback_gap_p95_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                            "callback_gap_max_ms": sorted.last ?? 0,
                            "gaps_over_25ms": sorted.filter { $0 > 25 }.count,
                            "gaps_over_50ms": sorted.filter { $0 > 50 }.count
                        ])
                        self.previous = nil
                        try await Task.sleep(for: .seconds(0.65))
                    }
                }
                self.link?.invalidate()
                self.link = nil
                let idleCPU = Self.cpuTime()
                let idleStart = CACurrentMediaTime()
                try await Task.sleep(for: .seconds(3))
                self.results.append([
                    "phase": "compact_idle",
                    "wall_ms": (CACurrentMediaTime() - idleStart) * 1000,
                    "cpu_ms": (Self.cpuTime() - idleCPU) * 1000
                ])
                let data = try JSONSerialization.data(withJSONObject: self.results, options: [.prettyPrinted, .sortedKeys])
                let path = ProcessInfo.processInfo.environment["NOOL_PROFILE_OUTPUT"] ?? "/tmp/nool-expansion-profile.json"
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                self.link?.invalidate()
                self.link = nil
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let previous else { return }
        let now = CACurrentMediaTime()
        samples.append((now - previous) * 1000)
        self.previous = now
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
