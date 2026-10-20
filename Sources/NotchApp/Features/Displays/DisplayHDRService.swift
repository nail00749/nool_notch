import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

protocol DisplayHDRServing: Sendable {
    /// Built-in XDR panels have no external HDR mode switch: returns nil.
    func read(_ target: DisplayHardwareTarget) async throws -> Bool?
    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool
    /// Recovery only: caller must own a previously captured original HDR state.
    func restoreHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool
}

extension DisplayHDRServing {
    func restoreHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        try await setHDR(enabled, for: target)
    }
}

enum DisplayHDRError: LocalizedError {
    case unavailable, disconnected, notApplied, timeout, busy

    var errorDescription: String? {
        switch self {
        case .unavailable: "Переключение HDR недоступно для этого дисплея."
        case .disconnected: "Дисплей отключён или изменился."
        case .notApplied: "macOS не подтвердила переключение HDR."
        case .timeout: "Дисплей не ответил на запрос HDR вовремя. Перезапустите NooL, чтобы повторить."
        case .busy: "Переключение HDR занято. Повторите попытку."
        }
    }
}

final class DynamicDisplayHDRService: DisplayHDRServing, @unchecked Sendable {
    private let executor: DisplayHardwareExecutor
    private let driver: SystemDisplayHDRDriver

    // A normal HDR link reconfiguration can take about two seconds. Keep its
    // finite watchdog separate from the shorter brightness/XPC deadline.
    init(executor: DisplayHardwareExecutor = DisplayHardwareExecutor(timeout: 4), driver: SystemDisplayHDRDriver = SystemDisplayHDRDriver()) {
        self.executor = executor
        self.driver = driver
    }

    func read(_ target: DisplayHardwareTarget) async throws -> Bool? {
        try await run { [driver] active in
            guard active() else { throw CancellationError() }
            return try driver.read(target)
        }
    }

    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        try await run { [driver] active in
            try driver.setHDR(enabled, for: target, active: active)
        }
    }

    func restoreHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        try await run { [driver] active in
            try driver.restoreHDR(enabled, for: target, active: active)
        }
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        do { return try await executor.run(operation) }
        catch let error as DisplayHardwareBrightnessError {
            switch error {
            case .timeout: throw DisplayHDRError.timeout
            case .busy: throw DisplayHDRError.busy
            default: throw error
            }
        }
    }
}

struct DisplayHDRNativeState: Equatable {
    let supported: Bool
    let enabled: Bool
    let preferred: Bool
}

protocol DisplayHDRRuntime {
    func state(_ target: DisplayHardwareTarget) throws -> DisplayHDRNativeState?
    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) throws
}

/// Used only on the service's serial background executor. Each read obtains a
/// fresh MPDisplay and checks native HDR state rather than inferred EDR headroom.
final class SystemDisplayHDRDriver: @unchecked Sendable {
    private let runtime: any DisplayHDRRuntime
    private let resolve: (DisplayHardwareTarget, Bool) throws -> DisplayHardwareTarget
    private let pause: () -> Void
    private let attempts: Int

    init() {
        runtime = DynamicDisplayHDRRuntime()
        resolve = Self.resolve
        pause = { Thread.sleep(forTimeInterval: 0.05) }
        attempts = 16
    }

    init(runtime: any DisplayHDRRuntime, attempts: Int = 16,
         resolve: @escaping (DisplayHardwareTarget, Bool) throws -> DisplayHardwareTarget,
         pause: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.resolve = resolve
        self.pause = pause
        self.attempts = max(1, attempts)
    }

    func read(_ target: DisplayHardwareTarget) throws -> Bool? {
        let current = try resolve(target, false)
        guard !current.isBuiltin else { return nil }
        let state = try runtime.state(current)
        _ = try resolve(current, false)
        guard let state, state.supported else { return nil }
        guard state.enabled == state.preferred else { throw DisplayHDRError.notApplied }
        return state.enabled
    }

    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget, active: () -> Bool) throws -> Bool {
        try changeHDR(enabled, for: target, recovering: false, active: active)
    }

    func restoreHDR(_ enabled: Bool, for target: DisplayHardwareTarget, active: () -> Bool) throws -> Bool {
        try changeHDR(enabled, for: target, recovering: true, active: active)
    }

    private func changeHDR(_ enabled: Bool, for target: DisplayHardwareTarget, recovering: Bool, active: () -> Bool) throws -> Bool {
        guard active() else { throw CancellationError() }
        let current = try resolve(target, false)
        guard !current.isBuiltin, let previous = try runtime.state(current), previous.supported else {
            throw DisplayHDRError.unavailable
        }
        _ = try resolve(current, false)
        guard recovering || previous.enabled == previous.preferred else { throw DisplayHDRError.notApplied }
        if previous.enabled == enabled && previous.preferred == enabled { return enabled }
        guard active() else { throw CancellationError() }
        try runtime.setHDR(enabled, for: current)
        // HDR can assign a new runtime ID. Only this post-write path follows
        // the unique UUID; never retry a mutation on a reused numeric ID.
        for attempt in 0..<attempts {
            guard active() else { throw CancellationError() }
            if attempt > 0 { pause() }
            do {
                let refreshed = try resolve(target, true)
                let state = try runtime.state(refreshed)
                _ = try resolve(refreshed, false)
                if let state, state.supported, state.enabled == enabled, state.preferred == enabled { return enabled }
            } catch DisplayHDRError.disconnected {
                // A transient removal during the mode switch is allowed only
                // for bounded readback, never used as permission to write.
                continue
            }
        }
        throw DisplayHDRError.notApplied
    }

    private static func resolve(_ target: DisplayHardwareTarget, _ allowReassignedID: Bool) throws -> DisplayHardwareTarget {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 128 else {
            throw DisplayHDRError.disconnected
        }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw DisplayHDRError.disconnected }
        let matches = ids.prefix(Int(count)).filter { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame
        }
        guard matches.count == 1, let id = matches.first,
              allowReassignedID || id == target.displayID,
              (CGDisplayIsBuiltin(id) != 0) == target.isBuiltin else { throw DisplayHDRError.disconnected }
        return DisplayHardwareTarget(uuid: target.uuid, displayID: id, isBuiltin: target.isBuiltin)
    }
}

enum DisplayHDRSelectorABI {
    static func matches(returnType: String, arguments: [String], expectedReturn: String, parameters: [String]) -> Bool {
        returnType == expectedReturn && arguments == ["@", ":"] + parameters
    }
}

/// Primary declarations: displayplacer MPDisplay.h/MPDisplayMgr.h; current
/// fastfetch displayserver_apple.c declares the two SkyLight Boolean functions.
/// https://github.com/jakehilborn/displayplacer/tree/master/src/Headers/MonitorPanel.framework/Headers
/// https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/displayserver/displayserver_apple.c
/// No KVC, private structure layouts, or static private framework linkage.
private final class DynamicDisplayHDRRuntime: DisplayHDRRuntime {
    typealias GetObject = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    typealias GetInt = @convention(c) (AnyObject, Selector) -> Int32
    typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
    typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    typealias NativeHDR = @convention(c) (UInt32) -> UInt8

    // Retain loaded images for process lifetime, including any stuck driver.
    private lazy var monitorPanel = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL)
    private lazy var skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)

    func state(_ target: DisplayHardwareTarget) throws -> DisplayHDRNativeState? {
        try autoreleasepool {
            guard let display = try display(target),
                  let supported = method(display, "hasHDRModes", result: "B"),
                  let preferred = method(display, "preferHDRModes", result: "B"),
                  method(display, "setPreferHDRModes:", result: "v", parameters: ["B"]) != nil,
                  let nativeSupport = symbol("SLSDisplaySupportsHDRMode"),
                  let nativeEnabled = symbol("SLSDisplayIsHDRModeEnabled") else { return nil }
            let supports = nativeSupport(target.displayID), enabled = nativeEnabled(target.displayID)
            guard supports <= 1, enabled <= 1 else { throw DisplayHDRError.notApplied }
            return DisplayHDRNativeState(supported: bool(display, supported, "hasHDRModes") && supports == 1,
                                         enabled: enabled == 1, preferred: bool(display, preferred, "preferHDRModes"))
        }
    }

    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) throws {
        try autoreleasepool {
            guard let display = try display(target),
                  let setter = method(display, "setPreferHDRModes:", result: "v", parameters: ["B"]) else {
                throw DisplayHDRError.unavailable
            }
            try validate(target)
            unsafeBitCast(method_getImplementation(setter), to: SetBool.self)(display, NSSelectorFromString("setPreferHDRModes:"), enabled)
        }
    }

    private func display(_ target: DisplayHardwareTarget) throws -> NSObject? {
        guard monitorPanel != nil, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let manager = cls.init()
        guard let getter = method(manager, "displays", result: "@"),
              let objects = object(manager, getter, "displays") as? [NSObject], objects.count <= 128 else { return nil }
        let candidates = objects.filter { display in
            guard let getID = method(display, "displayID", result: "i") else { return false }
            return UInt32(bitPattern: unsafeBitCast(method_getImplementation(getID), to: GetInt.self)(display, NSSelectorFromString("displayID"))) == target.displayID
        }
        guard candidates.count == 1, let display = candidates.first,
              let getUUID = method(display, "uuid", result: "@"),
              let uuid = object(display, getUUID, "uuid") as? NSUUID,
              uuid.uuidString.caseInsensitiveCompare(target.uuid) == .orderedSame,
              let builtin = method(display, "isBuiltIn", result: "B"),
              bool(display, builtin, "isBuiltIn") == target.isBuiltin else { throw DisplayHDRError.disconnected }
        try validate(target)
        return display
    }

    private func validate(_ target: DisplayHardwareTarget) throws {
        guard CGDisplayIsOnline(target.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame,
              (CGDisplayIsBuiltin(target.displayID) != 0) == target.isBuiltin else { throw DisplayHDRError.disconnected }
    }

    private func method(_ object: NSObject, _ name: String, result: String, parameters: [String] = []) -> Method? {
        guard let method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name)) else { return nil }
        let actualReturn = method_copyReturnType(method)
        defer { free(actualReturn) }
        let arguments = (0..<method_getNumberOfArguments(method)).compactMap { index -> String? in
            guard let type = method_copyArgumentType(method, index) else { return nil }
            defer { free(type) }
            return String(cString: type)
        }
        return DisplayHDRSelectorABI.matches(returnType: String(cString: actualReturn), arguments: arguments,
                                             expectedReturn: result, parameters: parameters) ? method : nil
    }

    private func object(_ object: NSObject, _ method: Method, _ name: String) -> AnyObject? {
        unsafeBitCast(method_getImplementation(method), to: GetObject.self)(object, NSSelectorFromString(name))?.takeUnretainedValue()
    }

    private func bool(_ object: NSObject, _ method: Method, _ name: String) -> Bool {
        unsafeBitCast(method_getImplementation(method), to: GetBool.self)(object, NSSelectorFromString(name))
    }

    private func symbol(_ name: String) -> NativeHDR? {
        guard let skyLight, let address = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(address, to: NativeHDR.self)
    }
}
