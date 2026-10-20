import AppKit
import Foundation
import IOKit
import IOKit.ps

enum DeviceBatteryKind: String, Equatable, Sendable {
    case mac, headphones, mouse, keyboard, trackpad, gamepad, speaker, other

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .headphones: "airpods"
        case .mouse: "magicmouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gamepad: "gamecontroller"
        case .speaker: "hifispeaker"
        case .other: "battery.75percent"
        }
    }

    static func classify(name: String, type: String) -> DeviceBatteryKind {
        let text = "\(name) \(type)".lowercased()
        if ["airpods", "beats", "headphone", "headset", "earbud", "науш"].contains(where: text.contains) {
            return .headphones
        }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") || text.contains("мыш") { return .mouse }
        if text.contains("keyboard") || text.contains("клавиатур") { return .keyboard }
        if text.contains("gamepad") || text.contains("controller") { return .gamepad }
        if text.contains("speaker") { return .speaker }
        return .other
    }
}

/// One battery-powered device. `percent` is the level worth acting on: for
/// earbuds that is the lower bud, so a widget never overstates the charge.
struct DeviceBattery: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: DeviceBatteryKind
    let percent: Int
    let isCharging: Bool
    let detail: String?

    var fraction: Double { Double(min(max(percent, 0), 100)) / 100 }
}

enum DeviceBatteryParser {
    /// Connected devices from `system_profiler SPBluetoothDataType -json`.
    static func bluetoothDevices(from data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var result: [DeviceBattery] = []
        collectConnected(root, result: &result)
        return result
    }

    private static func collectConnected(_ value: Any, result: inout [DeviceBattery]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "device_connected" {
                    for entry in (child as? [Any]) ?? [child] {
                        guard let devices = entry as? [String: Any] else { continue }
                        for (name, values) in devices {
                            if let values = values as? [String: Any],
                               let device = bluetoothDevice(name: name, values: values) {
                                result.append(device)
                            }
                        }
                    }
                } else if key != "device_not_connected" {
                    collectConnected(child, result: &result)
                }
            }
        } else if let array = value as? [Any] {
            array.forEach { collectConnected($0, result: &result) }
        }
    }

    static func bluetoothDevice(name: String, values: [String: Any]) -> DeviceBattery? {
        let main = percent(values["device_batteryLevelMain"] ?? values["device_batteryLevel"])
        let left = percent(values["device_batteryLevelLeft"])
        let right = percent(values["device_batteryLevelRight"])
        let caseLevel = percent(values["device_batteryLevelCase"])
        let buds = [left, right].compactMap { $0 }
        guard let level = buds.min() ?? main ?? caseLevel else { return nil }

        var parts: [String] = []
        if let left { parts.append("Л \(left)%") }
        if let right { parts.append("П \(right)%") }
        if let caseLevel { parts.append("Кейс \(caseLevel)%") }
        let address = (values["device_address"] as? String)?.replacingOccurrences(of: ":", with: "-")
        return DeviceBattery(
            id: "bt-" + (address ?? name),
            name: name,
            kind: .classify(name: name, type: values["device_minorType"] as? String ?? ""),
            percent: level,
            isCharging: false,
            detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }

    /// HID accessories from IORegistry entries that publish `BatteryPercent`.
    static func registryDevice(_ properties: [String: Any]) -> DeviceBattery? {
        guard let level = (properties["BatteryPercent"] as? NSNumber)?.intValue,
              let name = (properties["Product"] as? String), name.isEmpty == false else { return nil }
        let address = properties["DeviceAddress"] as? String ?? properties["SerialNumber"] as? String
        // Bit 1 of BatteryStatusFlags is "charging" on Magic accessories.
        let flags = (properties["BatteryStatusFlags"] as? NSNumber)?.intValue ?? 0
        return DeviceBattery(
            id: "hid-" + (address?.replacingOccurrences(of: ":", with: "-").lowercased() ?? name),
            name: name,
            kind: .classify(name: name, type: ""),
            percent: level,
            isCharging: flags & 0x2 != 0,
            detail: nil
        )
    }

    static func macBattery(_ description: [String: Any]) -> DeviceBattery? {
        guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String
                || description[kIOPSTypeKey as String] == nil,
              let current = description[kIOPSCurrentCapacityKey as String] as? Int,
              let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
              maximum > 0 else { return nil }
        let percent = Int((min(1, max(0, Double(current) / Double(maximum))) * 100).rounded())
        let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let onAC = description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue as String
        return DeviceBattery(
            id: "mac",
            name: Host.current().localizedName ?? "Mac",
            kind: .mac,
            percent: percent,
            isCharging: charging,
            detail: charging ? "заряжается" : (onAC ? "питание подключено" : "от батареи")
        )
    }

    /// Mac first, then the lowest charge, so the most urgent device leads.
    static func merged(mac: DeviceBattery?, bluetooth: [DeviceBattery], registry: [DeviceBattery]) -> [DeviceBattery] {
        var seenNames = Set<String>()
        var accessories: [DeviceBattery] = []
        for device in registry + bluetooth {
            let key = device.name.lowercased()
            guard seenNames.insert(key).inserted else { continue }
            accessories.append(device)
        }
        accessories.sort {
            $0.percent == $1.percent
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.percent < $1.percent
        }
        return (mac.map { [$0] } ?? []) + accessories
    }

    private static func percent(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        let digits = text.filter(\.isNumber)
        guard digits.isEmpty == false, let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }
}

protocol DeviceBatteryReading: Sendable {
    func read() async -> [DeviceBattery]
}

struct SystemDeviceBatteryReader: DeviceBatteryReading {
    func read() async -> [DeviceBattery] {
        await Task.detached(priority: .utility) {
            let mac = Self.readMac()
            let registry = Self.readRegistry()
            let bluetooth = Self.readBluetooth()
            return DeviceBatteryParser.merged(mac: mac, bluetooth: bluetooth, registry: registry)
        }.value
    }

    private static func readMac() -> DeviceBattery? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any],
                  let battery = DeviceBatteryParser.macBattery(description) else { continue }
            return battery
        }
        return nil
    }

    private static func readRegistry() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DeviceBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let device = DeviceBatteryParser.registryDevice(properties) else { continue }
            result.append(device)
        }
        return result
    }

    private static func readBluetooth() -> [DeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // system_profiler normally answers in a fraction of a second; never hang the poll.
        let deadline = DispatchTime.now() + 8
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DeviceBatteryParser.bluetoothDevices(from: data)
    }
}

/// Polls device batteries only while some widget shows them.
@MainActor
final class DeviceBatteryStore: ObservableObject {
    static let shared = DeviceBatteryStore()

    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var hasLoaded = false

    private let reader: any DeviceBatteryReading
    private let interval: TimeInterval
    private var viewers = 0
    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(reader: any DeviceBatteryReading = SystemDeviceBatteryReader(), interval: TimeInterval = 60) {
        self.reader = reader
        self.interval = interval
    }

    func beginViewing() {
        viewers += 1
        guard viewers == 1 else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartPolling() }
        }
        restartPolling()
    }

    func endViewing() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        pollingTask?.cancel()
        pollingTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func refresh() async {
        let next = await reader.read()
        guard Task.isCancelled == false else { return }
        if next != devices { devices = next }
        hasLoaded = true
    }

    private func restartPolling() {
        pollingTask?.cancel()
        let interval = interval
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}
