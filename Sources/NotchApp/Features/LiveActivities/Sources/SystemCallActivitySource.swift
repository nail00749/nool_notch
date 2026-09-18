import AppKit
import CoreAudio
import Foundation

struct AudioInputProcess: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String

    var isLikelyCallApp: Bool {
        let value = "\(bundleID ?? "") \(name)".lowercased()
        return [
            "facetime", "zoom", "teams", "slack", "telegram", "whatsapp",
            "discord", "meet", "chrome", "chromium", "safari", "arc", "firefox"
        ].contains(where: value.contains)
    }
}

struct CallActivityTracker: Sendable {
    private struct Record: Sendable {
        let process: AudioInputProcess
        let startedAt: Date
        let observedAt: Date
        var endedAt: Date?
    }

    private var hasSeeded = false
    private var records: [pid_t: Record] = [:]

    mutating func consume(_ processes: [AudioInputProcess], now: Date) -> [LiveActivity] {
        let calls = Dictionary(uniqueKeysWithValues: processes.filter(\.isLikelyCallApp).map { ($0.pid, $0) })
        if hasSeeded == false {
            hasSeeded = true
            records = calls.mapValues {
                Record(
                    process: $0,
                    startedAt: now,
                    observedAt: now.addingTimeInterval(-12),
                    endedAt: nil
                )
            }
        } else {
            for (pid, process) in calls where records[pid]?.endedAt != nil || records[pid] == nil {
                records[pid] = Record(
                    process: process,
                    startedAt: now,
                    observedAt: now,
                    endedAt: nil
                )
            }
            for (pid, var record) in records where calls[pid] == nil && record.endedAt == nil {
                record.endedAt = now
                records[pid] = record
            }
        }

        records = records.filter { _, record in
            guard let endedAt = record.endedAt else { return true }
            return now.timeIntervalSince(endedAt) < 12
        }

        return records.values.map { record in
            if let endedAt = record.endedAt {
                return LiveActivity(
                    id: "call-\(record.process.pid)", sourceID: "system-calls",
                    kind: .call, title: "Звонок · \(record.process.name)",
                    detail: "Завершён · \(LiveActivityClock.elapsedText(from: record.startedAt, to: endedAt))",
                    state: .notification, progress: nil, startedAt: record.startedAt,
                    endsAt: endedAt, updatedAt: endedAt, isCompactEligible: true
                )
            }
            return LiveActivity(
                id: "call-\(record.process.pid)", sourceID: "system-calls",
                kind: .call, title: "Звонок · \(record.process.name)",
                detail: LiveActivityClock.elapsedText(from: record.startedAt, to: now),
                state: .active, progress: nil, startedAt: record.startedAt,
                endsAt: nil, updatedAt: record.observedAt, isCompactEligible: true
            )
        }
    }
}

enum CoreAudioInputProcessReader {
    static func runningInputPIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr, byteCount > 0 else { return [] }

        var objects = Array(repeating: AudioObjectID(0), count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &objects
        ) == noErr else { return [] }

        return objects.compactMap { objectID in
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                objectID, &runningAddress, 0, nil, &runningSize, &running
            ) == noErr, running != 0 else { return nil }

            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                objectID, &pidAddress, 0, nil, &pidSize, &pid
            ) == noErr, pid > 0 else { return nil }
            return pid
        }
    }
}

@MainActor
final class SystemCallActivitySource: LiveActivitySource {
    let id = "system-calls"
    let displayName = "Звонки"
    var onChange: (([LiveActivity]) -> Void)?

    private var tracker = CallActivityTracker()
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        let pids = await Task.detached(priority: .utility) {
            CoreAudioInputProcessReader.runningInputPIDs()
        }.value
        guard Task.isCancelled == false else { return }
        let processes = pids.compactMap { pid -> AudioInputProcess? in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return AudioInputProcess(
                pid: pid,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? "Приложение"
            )
        }
        onChange?(tracker.consume(processes, now: .now))
    }
}
