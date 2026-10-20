import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

/// Synchronous boundary. The settings service executes it off the main thread.
/// The lock also protects lazy clients when used outside that service.
final class SystemDisplayColorDriver: DisplaySystemColorDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: any DisplaySystemColorRuntime
    private let validate: (DisplayHardwareTarget) throws -> Void

    init() {
        runtime = DynamicDisplaySystemColorRuntime()
        validate = Self.validate
    }

    init(runtime: any DisplaySystemColorRuntime, validate: @escaping (DisplayHardwareTarget) throws -> Void) {
        self.runtime = runtime
        self.validate = validate
    }

    func nightShift() throws -> Bool? { try lock.withLock { try runtime.nightShift() } }
    func trueTone() throws -> Bool? { try lock.withLock { try runtime.trueTone() } }

    func setNightShift(_ enabled: Bool) throws {
        try lock.withLock {
            try change(enabled, read: runtime.nightShift, write: runtime.setNightShift)
        }
    }

    func setTrueTone(_ enabled: Bool) throws {
        try lock.withLock {
            try change(enabled, read: runtime.trueTone, write: runtime.setTrueTone)
        }
    }

    func autoBrightness(for target: DisplayHardwareTarget) throws -> Bool? {
        try lock.withLock {
            try validate(target)
            let value = try runtime.autoBrightness(target.displayID)
            try validate(target)
            return value
        }
    }

    func setAutoBrightness(_ enabled: Bool, for target: DisplayHardwareTarget) throws {
        try lock.withLock {
            try validate(target)
            try change(enabled, read: {
                try self.validate(target)
                let value = try self.runtime.autoBrightness(target.displayID)
                try self.validate(target)
                return value
            }, write: {
                try self.validate(target)
                try self.runtime.setAutoBrightness($0, displayID: target.displayID)
                try self.validate(target)
            })
        }
    }

    private func change(_ enabled: Bool, read: () throws -> Bool?, write: (Bool) throws -> Void) throws {
        guard let previous = try read() else { throw DisplaySystemSettingsError.unavailable }
        guard previous != enabled else { return }
        try write(enabled)
        guard try read() == enabled else { throw DisplaySystemSettingsError.notApplied }
    }

    private static func validate(_ target: DisplayHardwareTarget) throws {
        guard CGDisplayIsOnline(target.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame,
              (CGDisplayIsBuiltin(target.displayID) != 0) == target.isBuiltin else {
            throw DisplaySystemSettingsError.disconnected
        }
    }
}

protocol DisplaySystemColorRuntime {
    func nightShift() throws -> Bool?
    func setNightShift(_ enabled: Bool) throws
    func trueTone() throws -> Bool?
    func setTrueTone(_ enabled: Bool) throws
    func autoBrightness(_ displayID: UInt32) throws -> Bool?
    func setAutoBrightness(_ enabled: Bool, displayID: UInt32) throws
}

/// Exact known ABI only: never invoke a selector merely because its name exists.
/// Layout follows the class-dumped CBBlueLightClient header in displayutil and
/// is checked against the host Objective-C method encoding before allocation.
/// https://github.com/srirangav/displayutil/blob/master/CBBlueLightClient.h
/// Unknown ABI versions deliberately expose no capability.
enum DisplaySystemColorABI {
    static let statusType = "^{?=BBBi{?={?=ii}{?=ii}}QB}"
    static let statusSize = 40

    static func matches(returnType: String, arguments: [String], parameters: [String]) -> Bool {
        returnType == "B" && arguments == ["@", ":"] + parameters
    }

    static func status(_ bytes: [UInt8]) throws -> (enabled: Bool, available: Bool) {
        guard bytes.count == statusSize, bytes[0] <= 1, bytes[1] <= 1, bytes[2] <= 1,
              bytes[32] <= 1 else { throw DisplaySystemSettingsError.notApplied }
        return (bytes[1] != 0, bytes[32] != 0)
    }
}

private final class DynamicDisplaySystemColorRuntime: DisplaySystemColorRuntime {
    typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
    typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
    typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    typealias AmbientHas = @convention(c) (UInt32) -> Bool
    typealias AmbientGet = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Int32
    typealias AmbientSet = @convention(c) (UInt32, Bool) -> Int32

    // Handles intentionally retained until process exit; no private static link.
    private lazy var coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)
    private lazy var displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private lazy var blueClient = client("CBBlueLightClient")
    private lazy var toneClient = client("CBTrueToneClient")

    func nightShift() throws -> Bool? {
        guard let blueClient, let cls = object_getClass(blueClient),
              let support = class_getClassMethod(cls, NSSelectorFromString("supportsBlueLightReduction")),
              compatible(support, parameters: []),
              unsafeBitCast(method_getImplementation(support), to: GetBool.self)(cls, NSSelectorFromString("supportsBlueLightReduction")),
              let statusMethod = method(blueClient, "getBlueLightStatus:", parameters: [DisplaySystemColorABI.statusType]),
              method(blueClient, "setEnabled:", parameters: ["B"]) != nil else { return nil }
        var size = 0, alignment = 0
        DisplaySystemColorABI.statusType.dropFirst().withCString { _ = NSGetSizeAndAlignment($0, &size, &alignment) }
        guard size == DisplaySystemColorABI.statusSize, alignment == 8 else { return nil }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        guard unsafeBitCast(method_getImplementation(statusMethod), to: GetStatus.self)(blueClient, NSSelectorFromString("getBlueLightStatus:"), bytes) else {
            throw DisplaySystemSettingsError.notApplied
        }
        let state = try DisplaySystemColorABI.status(Array(UnsafeRawBufferPointer(start: bytes, count: size)))
        return state.available ? state.enabled : nil
    }

    func setNightShift(_ enabled: Bool) throws { try set(enabled, client: blueClient) }

    func trueTone() throws -> Bool? {
        guard let toneClient,
              let supported = method(toneClient, "supported", parameters: []),
              let available = method(toneClient, "available", parameters: []),
              let enabled = method(toneClient, "enabled", parameters: []),
              method(toneClient, "setEnabled:", parameters: ["B"]) != nil else { return nil }
        guard get(toneClient, supported, "supported"), get(toneClient, available, "available") else { return nil }
        return get(toneClient, enabled, "enabled")
    }

    func setTrueTone(_ enabled: Bool) throws { try set(enabled, client: toneClient) }

    func autoBrightness(_ displayID: UInt32) throws -> Bool? {
        // C signatures: Lunar/DDC/Lunar-Bridging-Header.h (DisplayServices).
        guard let has: AmbientHas = symbol("DisplayServicesHasAmbientLightCompensation"),
              let read: AmbientGet = symbol("DisplayServicesAmbientLightCompensationEnabled"),
              let _: AmbientSet = symbol("DisplayServicesEnableAmbientLightCompensation"), has(displayID) else { return nil }
        var value = false
        guard read(displayID, &value) == 0 else { throw DisplaySystemSettingsError.notApplied }
        return value
    }

    func setAutoBrightness(_ enabled: Bool, displayID: UInt32) throws {
        guard let write: AmbientSet = symbol("DisplayServicesEnableAmbientLightCompensation") else {
            throw DisplaySystemSettingsError.unavailable
        }
        guard write(displayID, enabled) == 0 else { throw DisplaySystemSettingsError.notApplied }
    }

    private func client(_ name: String) -> NSObject? {
        guard coreBrightness != nil, let cls = NSClassFromString(name) as? NSObject.Type else { return nil }
        return cls.init()
    }

    private func compatible(_ method: Method, parameters: [String]) -> Bool {
        let result = method_copyReturnType(method)
        defer { free(result) }
        let args = (0..<method_getNumberOfArguments(method)).compactMap { index -> String? in
            guard let type = method_copyArgumentType(method, index) else { return nil }
            defer { free(type) }
            return String(cString: type)
        }
        return DisplaySystemColorABI.matches(returnType: String(cString: result), arguments: args, parameters: parameters)
    }

    private func method(_ object: NSObject, _ name: String, parameters: [String]) -> Method? {
        guard let method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name)),
              compatible(method, parameters: parameters) else { return nil }
        return method
    }

    private func get(_ object: NSObject, _ method: Method, _ name: String) -> Bool {
        unsafeBitCast(method_getImplementation(method), to: GetBool.self)(object, NSSelectorFromString(name))
    }

    private func set(_ enabled: Bool, client: NSObject?) throws {
        guard let client, let method = method(client, "setEnabled:", parameters: ["B"]) else {
            throw DisplaySystemSettingsError.unavailable
        }
        guard unsafeBitCast(method_getImplementation(method), to: SetBool.self)(client, NSSelectorFromString("setEnabled:"), enabled) else {
            throw DisplaySystemSettingsError.notApplied
        }
    }

    private func symbol<T>(_ name: String) -> T? {
        guard let displayServices, let address = dlsym(displayServices, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
