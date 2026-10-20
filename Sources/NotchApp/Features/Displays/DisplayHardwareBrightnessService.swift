import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit

enum DisplayHardwareBackend: String, Sendable {
    case displayServices
    case ddc
}

struct DisplayHardwareTarget: Sendable, Equatable {
    let uuid: String
    let displayID: UInt32
    let isBuiltin: Bool
}

struct DisplayHardwareBrightnessReading: Sendable, Equatable {
    let value: Double
    let backend: DisplayHardwareBackend
}

protocol DisplayHardwareBrightnessServing: Sendable {
    func read(_ target: DisplayHardwareTarget) async throws -> DisplayHardwareBrightnessReading?
    func write(_ value: Double, to target: DisplayHardwareTarget, backend: DisplayHardwareBackend) async throws
}

enum DisplayHardwareBrightnessError: Error, LocalizedError {
    case timeout
    case unavailable
    case disconnected
    case invalidValue
    case communication
    case busy

    var errorDescription: String? {
        switch self {
        case .timeout: "Монитор не ответил вовремя. Аппаратная яркость недоступна до перезапуска приложения."
        case .unavailable: "Аппаратная яркость недоступна для этого дисплея."
        case .disconnected: "Дисплей отключён или изменился."
        case .invalidValue: "Некорректное значение яркости."
        case .communication: "Не удалось изменить аппаратную яркость монитора."
        case .busy: "Управление яркостью занято. Повторите попытку."
        }
    }
}

/// All driver calls share one queue. A timed-out driver may be uninterruptible:
/// trip a permanent circuit breaker instead of creating replacement threads.
final class DynamicDisplayHardwareBrightnessService: DisplayHardwareBrightnessServing, @unchecked Sendable {
    private let executor = DisplayHardwareExecutor()
    // Only accessed on executor's serial queue; handles intentionally live until
    // process exit so a timed-out call can never return into an unloaded image.
    private var symbols: DisplayHardwareSymbols?

    func read(_ target: DisplayHardwareTarget) async throws -> DisplayHardwareBrightnessReading? {
        try await executor.run { [self] active in
            try validate(target)
            let symbols = loadedSymbols()
            if let get = symbols.getBrightness, symbols.setBrightness != nil {
                var value: Float = 0
                if get(target.displayID, &value) == 0, value.isFinite, (0...1).contains(value) {
                    return DisplayHardwareBrightnessReading(value: Double(value), backend: .displayServices)
                }
            }
            guard active(), !target.isBuiltin else { return nil }
            #if arch(arm64)
            guard let service = matchingDDCService(target, symbols: symbols, active: active) else { return nil }
            guard let value = readDDC(service, symbols: symbols, active: active) else { return nil }
            try validate(target)
            return DisplayHardwareBrightnessReading(value: value.normalized, backend: .ddc)
            #else
            return nil
            #endif
        }
    }

    func write(_ value: Double, to target: DisplayHardwareTarget, backend: DisplayHardwareBackend) async throws {
        guard value.isFinite, (0...1).contains(value) else { throw DisplayHardwareBrightnessError.invalidValue }
        try await executor.run { [self] active in
            try validate(target)
            let symbols = loadedSymbols()
            guard active() else { throw CancellationError() }
            switch backend {
            case .displayServices:
                guard let set = symbols.setBrightness else { throw DisplayHardwareBrightnessError.unavailable }
                guard set(target.displayID, Float(value)) == 0 else { throw DisplayHardwareBrightnessError.communication }
            case .ddc:
                #if arch(arm64)
                guard !target.isBuiltin, let service = matchingDDCService(target, symbols: symbols, active: active),
                      let current = readDDC(service, symbols: symbols, active: active),
                      let rawValue = current.rawValue(for: value), let write = symbols.writeI2C else {
                    throw DisplayHardwareBrightnessError.unavailable
                }
                // Revalidate after the read transaction, since disconnect and ID
                // reuse can happen during a slow DDC operation.
                try validate(target)
                guard active() else { throw CancellationError() }
                var packet = DisplayDDC.writePacket(value: rawValue)
                let result = packet.withUnsafeMutableBytes {
                    write(service, 0x37, 0x51, $0.baseAddress, UInt32($0.count))
                }
                guard result == 0 else { throw DisplayHardwareBrightnessError.communication }
                Thread.sleep(forTimeInterval: 0.05)
                #else
                throw DisplayHardwareBrightnessError.unavailable
                #endif
            }
        }
    }

    private func loadedSymbols() -> DisplayHardwareSymbols {
        if let symbols { return symbols }
        let loaded = DisplayHardwareSymbols()
        symbols = loaded
        return loaded
    }

    private func validate(_ target: DisplayHardwareTarget) throws {
        guard CGDisplayIsOnline(target.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame,
              (CGDisplayIsBuiltin(target.displayID) != 0) == target.isBuiltin else {
            throw DisplayHardwareBrightnessError.disconnected
        }
    }

    private func readDDC(_ service: CFTypeRef, symbols: DisplayHardwareSymbols,
                         active: () -> Bool) -> DisplayDDC.Value? {
        guard let write = symbols.writeI2C, let read = symbols.readI2C else { return nil }
        // Bounded retries, paced on the same queue as all reads and writes.
        for _ in 0..<2 {
            guard active() else { return nil }
            Thread.sleep(forTimeInterval: 0.01)
            var request = DisplayDDC.readPacket()
            let sent = request.withUnsafeMutableBytes {
                write(service, 0x37, 0x51, $0.baseAddress, UInt32($0.count))
            }
            guard active() else { return nil }
            Thread.sleep(forTimeInterval: 0.05)
            var reply = [UInt8](repeating: 0, count: 11)
            let received = reply.withUnsafeMutableBytes {
                read(service, 0x37, 0, $0.baseAddress, UInt32($0.count))
            }
            if sent == 0, received == 0, let value = DisplayDDC.decode(reply) { return value }
        }
        return nil
    }

    private func matchingDDCService(_ target: DisplayHardwareTarget, symbols: DisplayHardwareSymbols,
                                    active: () -> Bool) -> CFTypeRef? {
        guard let create = symbols.createService, symbols.readI2C != nil, symbols.writeI2C != nil else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [(entry: io_service_t, identity: DisplayDDCIdentity)] = []
        defer { candidates.forEach { IOObjectRelease($0.entry) } }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            guard active(), property(entry, "Location") as? String == "External",
                  let identity = registryIdentity(entry, target: cgIdentity(target.displayID), active: active) else {
                IOObjectRelease(entry)
                continue
            }
            candidates.append((entry, identity))
        }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        let online = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map(cgIdentity)
        guard let match = DisplayDDCIdentity.uniqueMatch(for: cgIdentity(target.displayID),
                                                        candidates: candidates.map(\.identity), onlineDisplays: online) else { return nil }
        return create(kCFAllocatorDefault, candidates[match].entry)?.takeRetainedValue()
    }

    private func cgIdentity(_ displayID: CGDirectDisplayID) -> DisplayDDCIdentity {
        DisplayDDCIdentity(vendor: CGDisplayVendorNumber(displayID), product: CGDisplayModelNumber(displayID),
                           serial: CGDisplaySerialNumber(displayID))
    }

    private func property(_ entry: io_registry_entry_t, _ name: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func metadataIdentity(_ entry: io_registry_entry_t) -> DisplayDDCIdentity? {
        guard let attributes = property(entry, "DisplayAttributes") as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let vendor = product["LegacyManufacturerID"] as? NSNumber,
              vendor.uint64Value <= UInt64(UInt32.max),
              let modelNumber = product["ProductID"] as? NSNumber,
              modelNumber.uint64Value <= UInt64(UInt32.max),
              let serial = product["SerialNumber"] as? NSNumber,
              serial.uint64Value <= UInt64(UInt32.max) else { return nil }
        return DisplayDDCIdentity(edidUUID: property(entry, "EDID UUID") as? String,
                                  vendor: vendor.uint32Value, product: modelNumber.uint32Value,
                                  serial: serial.uint32Value)
    }

    private func registryIdentity(_ service: io_service_t, target: DisplayDDCIdentity,
                                  active: () -> Bool) -> DisplayDDCIdentity? {
        // Direct ancestry is the first choice. Keep references for a bounded
        // branch search only when metadata is not on any ancestor itself.
        var entry = service
        IOObjectRetain(entry)
        var ancestors: [io_registry_entry_t] = [entry]
        defer { ancestors.forEach { IOObjectRelease($0) } }
        for _ in 0..<32 {
            guard active() else { return nil }
            if let identity = metadataIdentity(entry), target.hasSameFullNumericIdentity(as: identity) { return identity }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            ancestors.append(parent)
            entry = parent
        }
        var proxyID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &proxyID) == KERN_SUCCESS else { return nil }
        // Ancestor branches are nested. Accumulating their visited nodes avoids
        // rescanning the same subtree while keeping one global node budget.
        // An incomplete branch can never match.
        var remainingNodes = 2048
        var visited = Set<UInt64>()
        var proxies = Set<UInt64>()
        var metadata: [DisplayDDCIdentity] = []
        for ancestor in ancestors {
            guard active(), inspectBranch(ancestor, remainingNodes: &remainingNodes, visited: &visited,
                                           proxies: &proxies, metadata: &metadata, active: active) else { return nil }
            if let identity = DisplayDDCBranchAssociation.identity(for: target, proxyID: proxyID,
                                                                   externalProxyIDs: proxies,
                                                                   metadata: metadata, isComplete: true) {
                return identity
            }
            // Every broader ancestor would contain these same multiple proxies.
            if proxies.count > 1 { return nil }
        }
        return nil
    }

    private func inspectBranch(_ root: io_registry_entry_t, remainingNodes: inout Int,
                               visited: inout Set<UInt64>, proxies: inout Set<UInt64>,
                               metadata: inout [DisplayDDCIdentity], active: () -> Bool) -> Bool {
        IOObjectRetain(root)
        var pending = [root]
        defer { pending.forEach { IOObjectRelease($0) } }
        while let entry = pending.popLast() {
            defer { IOObjectRelease(entry) }
            guard active() else { return false }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return false }
            guard visited.insert(id).inserted else { continue }
            guard remainingNodes > 0 else { return false }
            remainingNodes -= 1
            if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
               property(entry, "Location") as? String == "External" {
                proxies.insert(id)
            }
            if let identity = metadataIdentity(entry) { metadata.append(identity) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                pending.append(child)
                guard pending.count <= 2048 else { return false }
            }
            guard IOIteratorIsValid(children) != 0 else { return false }
        }
        return true
    }
}

private final class DisplayHardwareSymbols {
    typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (UInt32, Float) -> Int32
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32

    let getBrightness: Get?
    let setBrightness: Set?
    let createService: Create?
    let writeI2C: I2C?
    let readI2C: I2C?

    init() {
        let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL)
        getBrightness = Self.load("DisplayServicesGetBrightness", from: displayServices, as: Get.self)
        setBrightness = Self.load("DisplayServicesSetBrightness", from: displayServices, as: Set.self)
        createService = Self.load("IOAVServiceCreateWithService", from: ioKit, as: Create.self)
        writeI2C = Self.load("IOAVServiceWriteI2C", from: ioKit, as: I2C.self)
        readI2C = Self.load("IOAVServiceReadI2C", from: ioKit, as: I2C.self)
        // No dlclose: a call that timed out may still be executing inside a driver.
    }

    private static func load<T>(_ name: String, from handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

final class DisplayHardwareExecutor: @unchecked Sendable {
    typealias WatchdogScheduler = @Sendable (DispatchWorkItem, TimeInterval) -> Void

    private let queue = DispatchQueue(label: "app.nool.display-hardware", qos: .utility)
    private let lock = NSLock()
    private var broken = false
    private var pending: [UUID: @Sendable () -> Void] = [:]
    private let timeout: TimeInterval
    private let watchdogScheduler: WatchdogScheduler

    init(timeout: TimeInterval = 2, watchdogScheduler: @escaping WatchdogScheduler = { watchdog, timeout in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
    }) {
        self.timeout = timeout
        self.watchdogScheduler = watchdogScheduler
    }

    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let request = DisplayHardwareRequest<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.setContinuation(continuation)
                lock.lock()
                guard !broken, pending.count < 16 else {
                    let error: DisplayHardwareBrightnessError = broken ? .timeout : .busy
                    lock.unlock()
                    request.finish(.failure(error))
                    return
                }
                let id = UUID()
                pending[id] = { request.finish(.failure(DisplayHardwareBrightnessError.timeout)) }
                lock.unlock()
                queue.async { [self] in
                    guard request.isActive else { remove(id); return }
                    // Starts when execution starts, not when another monitor is
                    // still using the serial bus. Queue wait is not a driver hang.
                    let watchdog = DispatchWorkItem { [self] in tripBreaker(ifPending: id) }
                    watchdogScheduler(watchdog, timeout)
                    let result = Result { try operation { request.isActive } }
                    watchdog.cancel()
                    remove(id)
                    request.finish(result)
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    private func tripBreaker(ifPending id: UUID) {
        lock.lock()
        guard pending[id] != nil else { lock.unlock(); return }
        broken = true
        let requests = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        requests.forEach { $0() }
    }
}

private final class DisplayHardwareRequest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
