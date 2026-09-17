import Foundation
import IOBluetooth

struct BluetoothAudioDevice: Equatable, Sendable {
    let id: String
    let name: String
    let batteryPercent: Int?
}

enum SystemProfilerBluetoothParser {
    enum ParseError: Error {
        case invalidRoot
    }

    static func devices(from data: Data) throws -> [BluetoothAudioDevice] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard json is [String: Any] || json is [Any] else { throw ParseError.invalidRoot }
        var result: [BluetoothAudioDevice] = []
        walk(json, connected: false, result: &result)
        return Dictionary(grouping: result, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func walk(
        _ value: Any,
        connected: Bool,
        deviceName: String? = nil,
        result: inout [BluetoothAudioDevice]
    ) {
        if let dictionary = value as? [String: Any] {
            if connected, let deviceName, let device = makeDevice(name: deviceName, values: dictionary) {
                result.append(device)
            }
            for (key, child) in dictionary {
                let isConnected = connected || key == "device_connected"
                if isConnected,
                   key != "device_connected",
                   child is [String: Any],
                   key.hasPrefix("device_") == false {
                    walk(child, connected: true, deviceName: key, result: &result)
                } else {
                    walk(child, connected: isConnected, deviceName: deviceName, result: &result)
                }
            }
        } else if let array = value as? [Any] {
            array.forEach { walk($0, connected: connected, deviceName: deviceName, result: &result) }
        }
    }

    private static func makeDevice(name: String, values: [String: Any]) -> BluetoothAudioDevice? {
        let minorType = values["device_minorType"] as? String ?? ""
        let searchable = "\(name) \(minorType)".lowercased()
        let audioKeywords = ["airpods", "beats", "headphone", "headset", "earbud", "науш"]
        guard audioKeywords.contains(where: searchable.contains) else { return nil }

        let address = values["device_address"] as? String
        let id = address?.replacingOccurrences(of: ":", with: "-") ?? name
        let batteryText = values["device_batteryLevelMain"] as? String
        let battery = batteryText.flatMap {
            Int($0.filter(\.isNumber))
        }
        return BluetoothAudioDevice(id: id, name: name, batteryPercent: battery)
    }
}

struct BluetoothActivityTracker: Sendable {
    private struct Record: Sendable {
        var device: BluetoothAudioDevice
        let connectedAt: Date
        var disconnectedAt: Date?
    }

    private var hasSeeded = false
    private var records: [String: Record] = [:]

    mutating func consume(_ devices: [BluetoothAudioDevice], now: Date) -> [LiveActivity] {
        let incoming = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        if hasSeeded == false {
            hasSeeded = true
            records = incoming.mapValues { Record(device: $0, connectedAt: now.addingTimeInterval(-12), disconnectedAt: nil) }
        } else {
            for (id, device) in incoming {
                if var record = records[id], record.disconnectedAt == nil {
                    record.device = device
                    records[id] = record
                } else {
                    records[id] = Record(device: device, connectedAt: now, disconnectedAt: nil)
                }
            }
            for (id, var record) in records where incoming[id] == nil && record.disconnectedAt == nil {
                record.disconnectedAt = now
                records[id] = record
            }
        }

        pruneExpired(at: now)

        return activities(at: now)
    }

    mutating func expire(now: Date) -> [LiveActivity] {
        pruneExpired(at: now)
        return activities(at: now)
    }

    func nextExpiration(after now: Date) -> Date? {
        records.values.compactMap { record in
            if let disconnectedAt = record.disconnectedAt {
                return disconnectedAt.addingTimeInterval(12)
            }
            let expiration = record.connectedAt.addingTimeInterval(12)
            return expiration > now ? expiration : nil
        }.min()
    }

    private mutating func pruneExpired(at now: Date) {
        records = records.filter { _, record in
            guard let disconnectedAt = record.disconnectedAt else { return true }
            return now.timeIntervalSince(disconnectedAt) < 12
        }
    }

    private func activities(at now: Date) -> [LiveActivity] {
        return records.values.map { record in
            let battery = record.device.batteryPercent.map { " · \($0)%" } ?? ""
            if let disconnectedAt = record.disconnectedAt {
                return LiveActivity(
                    id: "headphones-\(record.device.id)", sourceID: "system-bluetooth",
                    kind: .headphones, title: record.device.name, detail: "Отключены",
                    state: .notification, progress: nil, startedAt: record.connectedAt,
                    endsAt: nil, updatedAt: disconnectedAt, isCompactEligible: true
                )
            }
            let fresh = now.timeIntervalSince(record.connectedAt) < 12
            return LiveActivity(
                id: "headphones-\(record.device.id)", sourceID: "system-bluetooth",
                kind: .headphones, title: record.device.name,
                detail: "Подключены\(battery)", state: .active,
                progress: record.device.batteryPercent.map { Double($0) / 100 },
                startedAt: record.connectedAt, endsAt: nil, updatedAt: record.connectedAt,
                isCompactEligible: fresh
            )
        }
    }
}

struct BluetoothRefreshGate: Sendable {
    private(set) var isRunning = false
    private var needsAnotherRefresh = false

    mutating func requestRefresh() -> Bool {
        guard isRunning else { return true }
        needsAnotherRefresh = true
        return false
    }

    mutating func didStart() {
        isRunning = true
    }

    mutating func didFinish() -> Bool {
        isRunning = false
        defer { needsAnotherRefresh = false }
        return needsAnotherRefresh
    }

    mutating func cancelPendingRefresh() {
        needsAnotherRefresh = false
    }
}

@MainActor
final class BluetoothAudioActivitySource: NSObject, LiveActivitySource {
    let id = "system-bluetooth"
    let displayName = "AirPods и наушники"
    var onChange: (([LiveActivity]) -> Void)?

    private var tracker = BluetoothActivityTracker()
    private var currentDevices: [String: BluetoothAudioDevice] = [:]
    private var reconcileTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshGate = BluetoothRefreshGate()
    private var refreshGeneration = 0
    private var isStarted = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    func start() {
        guard reconcileTask == nil else { return }
        isStarted = true
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
        scheduleRefresh()
        reconcileTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(120))
                guard Task.isCancelled == false else { return }
                self?.scheduleRefresh()
            }
        }
    }

    func stop() {
        isStarted = false
        refreshGeneration += 1
        refreshGate.cancelPendingRefresh()
        reconcileTask?.cancel()
        reconcileTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    private func scheduleRefresh(after delay: Duration = .zero) {
        guard isStarted, refreshGate.requestRefresh() else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard Task.isCancelled == false else { return }
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard isStarted, refreshGate.isRunning == false else { return }
        let generation = refreshGeneration
        refreshGate.didStart()
        let loaded = await Task.detached(priority: .utility) {
            Self.loadDevices()
        }.value
        let shouldRefreshAgain = refreshGate.didFinish()
        refreshTask = nil
        if isStarted, generation == refreshGeneration, let devices = loaded {
            currentDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
            registerDisconnectNotifications(for: devices)
            let now = Date.now
            onChange?(tracker.consume(devices, now: now))
            scheduleExpiry(after: now)
        }
        if shouldRefreshAgain, isStarted {
            scheduleRefresh(after: .milliseconds(150))
        }
    }

    @objc nonisolated func deviceDidConnect(
        _ notification: IOBluetoothUserNotification?,
        device: IOBluetoothDevice
    ) {
        let address = device.addressString
        Task { @MainActor [weak self] in
            guard let self, self.isStarted else { return }
            if let address, let localDevice = IOBluetoothDevice(addressString: address) {
                self.registerDisconnectNotification(for: localDevice)
            }
            self.scheduleRefresh(after: .milliseconds(700))
        }
    }

    @objc nonisolated func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification?,
        device: IOBluetoothDevice
    ) {
        let address = device.addressString
        Task { @MainActor [weak self] in
            guard let self, self.isStarted else { return }
            if let id = address {
                self.disconnectNotifications[id]?.unregister()
                self.disconnectNotifications[id] = nil
                self.currentDevices[id] = nil
                let now = Date.now
                self.onChange?(self.tracker.consume(Array(self.currentDevices.values), now: now))
                self.scheduleExpiry(after: now)
            }
            self.scheduleRefresh(after: .seconds(1))
        }
    }

    private func scheduleExpiry(after now: Date) {
        expiryTask?.cancel()
        guard isStarted, let expiration = tracker.nextExpiration(after: now) else {
            expiryTask = nil
            return
        }
        let delay = max(0, expiration.timeIntervalSince(now))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            self?.publishExpiry(at: Date.now)
        }
    }

    private func publishExpiry(at now: Date) {
        guard isStarted else { return }
        onChange?(tracker.expire(now: now))
        scheduleExpiry(after: now)
    }

    private func registerDisconnectNotifications(for devices: [BluetoothAudioDevice]) {
        for audioDevice in devices where disconnectNotifications[audioDevice.id] == nil {
            guard let device = IOBluetoothDevice(addressString: audioDevice.id) else { continue }
            registerDisconnectNotification(for: device)
        }
    }

    private func registerDisconnectNotification(for device: IOBluetoothDevice) {
        guard let id = device.addressString else { return }
        guard disconnectNotifications[id] == nil else { return }
        disconnectNotifications[id] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:))
        )
    }

    nonisolated private static func loadDevices() -> [BluetoothAudioDevice]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "mini"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return try? SystemProfilerBluetoothParser.devices(from: data)
        } catch {
            return nil
        }
    }
}
