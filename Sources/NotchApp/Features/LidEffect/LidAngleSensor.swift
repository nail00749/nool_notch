import Foundation
import IOKit.hid

enum LidSensorReading: Sendable, Equatable {
    case angle(Double)
    case unavailable(String)
}

@MainActor
protocol LidAngleProviding: AnyObject {
    func start(_ onReading: @escaping @MainActor @Sendable (LidSensorReading) -> Void)
    func stop()
}

enum LidReportDecoder {
    static let reportID: UInt8 = 1

    static func angle(from report: [UInt8]) -> Double? {
        guard report.count >= 3, report[0] == reportID else { return nil }
        let value = Double(UInt16(report[1]) | (UInt16(report[2]) << 8))
        return (0...180).contains(value) ? value : nil
    }
}

@MainActor
final class SystemLidAngleSensor: LidAngleProviding {
    // Reuse one worker across restarts: a stalled driver must not accumulate threads/devices.
    private let worker = LidAnglePollingWorker(reader: HIDLidAngleReader())
    private var generation = UUID()

    func start(_ onReading: @escaping @MainActor @Sendable (LidSensorReading) -> Void) {
        generation = UUID()
        let token = generation
        worker.start { [weak self] reading in
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                onReading(reading)
            }
        }
    }

    func stop() {
        generation = UUID()
        worker.stop()
    }

    deinit { worker.stop() }
}

/// Called only on the polling worker's serial queue, including resource cleanup.
protocol LidAngleReading: AnyObject, Sendable {
    func read() -> LidSensorReading
    func close()
}

final class LidAnglePollingWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nool.notch.lid-sensor", qos: .utility)
    private let reader: any LidAngleReading
    private let lock = NSLock()
    // These three properties are protected by lock; openedGeneration belongs to queue.
    private var generation = UUID()
    private var callback: (@Sendable (LidSensorReading) -> Void)?
    private var polling = false
    private var openedGeneration: UUID?

    init(reader: any LidAngleReading) { self.reader = reader }

    func start(_ onReading: @escaping @Sendable (LidSensorReading) -> Void) {
        lock.lock()
        generation = UUID()
        callback = onReading
        let shouldStart = !polling
        polling = true
        lock.unlock()
        if shouldStart { queue.async { [self] in poll() } }
    }

    func stop() {
        lock.lock()
        generation = UUID()
        callback = nil
        lock.unlock()
    }

    private func poll() {
        lock.lock()
        let token = generation
        let active = callback != nil
        if !active { polling = false }
        lock.unlock()
        guard active else {
            reader.close()
            openedGeneration = nil
            return
        }
        if openedGeneration != token {
            reader.close()
            openedGeneration = token
        }
        // SPU can accept GetReportWithCallback without delivering a completion.
        // The synchronous API works, but has no cancellable timeout. Keep exactly
        // one call off-main; stop invalidates its result and UI has its own deadline.
        let reading = reader.read()
        lock.lock()
        let delivery = generation == token ? callback : nil
        if generation == token, case .unavailable = reading { callback = nil }
        lock.unlock()
        delivery?(reading)
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in poll() }
    }
}

private final class HIDLidAngleReader: LidAngleReading, @unchecked Sendable {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    func read() -> LidSensorReading {
        if device == nil {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDPrimaryUsagePageKey as String: 0x20,
                kIOHIDPrimaryUsageKey as String: 0x8A
            ] as CFDictionary)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return .unavailable("Не удалось открыть датчик крышки.")
            }
            guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
                  let candidate = devices.first else {
                return .unavailable("Датчик крышки не найден.")
            }
            guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return .unavailable("Датчик найден, но недоступен для чтения.")
            }
            device = candidate
        }
        guard let device else { return .unavailable("Датчик крышки недоступен.") }
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                CFIndex(LidReportDecoder.reportID), $0.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess, (3...bytes.count).contains(length),
              let angle = LidReportDecoder.angle(from: Array(bytes.prefix(length))) else {
            return .unavailable("Не удалось прочитать угол крышки. Выключите и включите эффект для повтора.")
        }
        return .angle(angle)
    }

    func close() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }
}
