import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

struct DisplayReferencePresetOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let allowsNightShift: Bool?
    let allowsAutoBrightness: Bool?

    init(id: String, name: String, allowsNightShift: Bool? = nil, allowsAutoBrightness: Bool? = nil) {
        self.id = id; self.name = name
        self.allowsNightShift = allowsNightShift; self.allowsAutoBrightness = allowsAutoBrightness
    }
}

struct DisplayReferencePresetState: Equatable, Sendable {
    let options: [DisplayReferencePresetOption]
    let selectedID: String
}

protocol DisplayReferencePresetServing: Sendable {
    func read(_ target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState?
    func select(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState
    func restore(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState
}

extension DisplayReferencePresetServing {
    func restore(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState {
        try await select(presetID, for: target)
    }
}

enum DisplayReferencePresetError: LocalizedError {
    case unavailable, disconnected, invalidCatalog, notApplied, recoveryFailed, timeout, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: "Режимы Apple XDR недоступны для этого дисплея."
        case .disconnected: "Дисплей отключён или изменился."
        case .invalidCatalog: "macOS не предоставила однозначный список режимов Apple XDR."
        case .notApplied: "macOS не подтвердила выбор режима Apple XDR."
        case .recoveryFailed: "Не удалось подтвердить восстановление режима Apple XDR. Повторите возврат настроек."
        case .timeout: "Дисплей не ответил на запрос режима Apple XDR вовремя. Восстановление не подтверждено."
        case .busy: "Переключение режима Apple XDR занято. Повторите попытку."
        }
    }
}

final class DynamicDisplayReferencePresetService: DisplayReferencePresetServing, @unchecked Sendable {
    private let executor: DisplayHardwareExecutor
    private let driver: SystemDisplayReferencePresetDriver
    init(executor: DisplayHardwareExecutor = DisplayHardwareExecutor(timeout: 4),
         driver: SystemDisplayReferencePresetDriver = SystemDisplayReferencePresetDriver()) {
        self.executor = executor; self.driver = driver
    }

    func read(_ target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState? {
        try await run { [driver] active in
            guard active() else { throw CancellationError() }
            return try driver.read(target)
        }
    }

    func select(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState {
        let cancellation = DisplayReferencePresetCancellation()
        // Cancellation must not discard the original while a native setter is
        // still executing. The detached operation completes recovery first.
        let operation = Task.detached { [self] in
            try await run { [driver] active in
                try driver.select(presetID, for: target, active: { active() && !cancellation.isCancelled },
                                  originalCaptured: { cancellation.capture($0) })
            }
        }
        return try await withTaskCancellationHandler {
            let state = try await operation.value
            if Task.isCancelled {
                if let original = cancellation.originalID {
                    do {
                        _ = try await Task.detached { [self] in
                            try await run { [driver] _ in try driver.restoreFollowingUUID(original, for: target) }
                        }.value
                    } catch { throw DisplayReferencePresetError.recoveryFailed }
                }
                throw CancellationError()
            }
            return state
        } onCancel: { cancellation.cancel() }
    }

    func restore(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState {
        // Explicit recovery remains live even when the owning UI task stopped.
        try await Task.detached { [self] in
            try await run { [driver] _ in try driver.restore(presetID, for: target) }
        }.value
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        do { return try await executor.run(operation) }
        catch let error as DisplayHardwareBrightnessError {
            switch error {
            case .timeout: throw DisplayReferencePresetError.timeout
            case .busy: throw DisplayReferencePresetError.busy
            default: throw error
            }
        }
    }
}

private final class DisplayReferencePresetCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var capturedID: String?
    var isCancelled: Bool { lock.withLock { cancelled } }
    var originalID: String? { lock.withLock { capturedID } }
    func cancel() { lock.withLock { cancelled = true } }
    func capture(_ id: String) { lock.withLock { capturedID = id } }
}

enum DisplayReferencePresetCatalog {
    static func identifier(_ value: Any?) -> String? {
        guard let bytes = value as? Data, bytes.count == 16 else { return nil }
        return "native:" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func allowed(disabled value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if number == 0 { return true }
        if number == 1 { return false }
        return nil
    }

    static func option(isValid: Bool, uniqueID: Any?, name: String, metadata: [String: Any]) throws -> DisplayReferencePresetOption? {
        guard isValid else { return nil }
        guard let id = identifier(uniqueID), !name.isEmpty, name.count <= 512 else {
            throw DisplayReferencePresetError.invalidCatalog
        }
        return .init(id: id, name: name,
            allowsNightShift: allowed(disabled: metadata["PresetHostDisableNightShift"]),
            allowsAutoBrightness: allowed(disabled: metadata["PresetHostDisableAutoBrightness"]))
    }

    static func state(options: [DisplayReferencePresetOption], selectedID: String) throws -> DisplayReferencePresetState {
        guard !options.isEmpty, options.count <= 256,
              Set(options.map(\.id)).count == options.count,
              options.contains(where: { $0.id == selectedID }) else { throw DisplayReferencePresetError.invalidCatalog }
        return .init(options: options, selectedID: selectedID)
    }
}

protocol DisplayReferencePresetRuntime {
    func state(_ target: DisplayHardwareTarget) throws -> DisplayReferencePresetState?
    func select(_ presetID: String, for target: DisplayHardwareTarget) throws
}

/// Confined to the service's serial executor, including automatic rollback.
final class SystemDisplayReferencePresetDriver: @unchecked Sendable {
    private let runtime: any DisplayReferencePresetRuntime
    private let resolve: (DisplayHardwareTarget, Bool) throws -> DisplayHardwareTarget
    private let pause: () -> Void
    private let attempts: Int
    init() {
        runtime = DynamicDisplayReferencePresetRuntime()
        resolve = Self.resolve
        pause = { Thread.sleep(forTimeInterval: 0.05) }
        attempts = 16
    }
    init(runtime: any DisplayReferencePresetRuntime, attempts: Int = 16,
         resolve: @escaping (DisplayHardwareTarget, Bool) throws -> DisplayHardwareTarget,
         pause: @escaping () -> Void = {}) {
        self.runtime = runtime; self.resolve = resolve; self.pause = pause; self.attempts = max(1, attempts)
    }

    func read(_ target: DisplayHardwareTarget) throws -> DisplayReferencePresetState? {
        let current = try resolve(target, false)
        let state = try runtime.state(current)
        _ = try resolve(current, false)
        return state
    }

    func select(_ presetID: String, for target: DisplayHardwareTarget, active: () -> Bool,
                originalCaptured: ((String) -> Void)? = nil) throws -> DisplayReferencePresetState {
        guard active() else { throw CancellationError() }
        let current = try resolve(target, false)
        guard let original = try runtime.state(current) else { throw DisplayReferencePresetError.unavailable }
        guard original.options.contains(where: { $0.id == presetID }) else { throw DisplayReferencePresetError.invalidCatalog }
        _ = try resolve(current, false)
        guard active() else { throw CancellationError() }
        originalCaptured?(original.selectedID)
        if original.selectedID == presetID { return original }
        do {
            try runtime.select(presetID, for: current)
            let selected = try verified(presetID, for: target, active: active)
            guard active() else { throw CancellationError() }
            return selected
        } catch {
            let failure = error
            do { _ = try restore(original.selectedID, for: resolve(target, true)) }
            catch { throw DisplayReferencePresetError.recoveryFailed }
            throw failure
        }
    }

    /// Only used with an original captured by this service's own mutation.
    func restoreFollowingUUID(_ presetID: String, for target: DisplayHardwareTarget) throws -> DisplayReferencePresetState {
        try restore(presetID, for: resolve(target, true))
    }

    func restore(_ presetID: String, for target: DisplayHardwareTarget) throws -> DisplayReferencePresetState {
        let current = try resolve(target, false)
        guard let state = try runtime.state(current), state.options.contains(where: { $0.id == presetID }) else {
            throw DisplayReferencePresetError.unavailable
        }
        _ = try resolve(current, false)
        if state.selectedID != presetID { try runtime.select(presetID, for: current) }
        return try verified(presetID, for: target, active: { true })
    }

    private func verified(_ presetID: String, for target: DisplayHardwareTarget, active: () -> Bool) throws -> DisplayReferencePresetState {
        for attempt in 0..<attempts {
            guard active() else { throw CancellationError() }
            if attempt > 0 { pause() }
            do {
                let current = try resolve(target, true)
                let state = try runtime.state(current)
                _ = try resolve(current, false)
                if let state, state.selectedID == presetID { return state }
            } catch DisplayReferencePresetError.disconnected { continue }
        }
        throw DisplayReferencePresetError.notApplied
    }

    private static func resolve(_ target: DisplayHardwareTarget, _ reassigned: Bool) throws -> DisplayHardwareTarget {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 128 else {
            throw DisplayReferencePresetError.disconnected
        }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw DisplayReferencePresetError.disconnected }
        let matches = ids.prefix(Int(count)).filter { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame
        }
        guard matches.count == 1, let id = matches.first, reassigned || id == target.displayID,
              (CGDisplayIsBuiltin(id) != 0) == target.isBuiltin else { throw DisplayReferencePresetError.disconnected }
        return .init(uuid: target.uuid, displayID: id, isBuiltin: target.isBuiltin)
    }
}

/// MPDisplay/MPDisplayPreset class-dumped declarations in displayplacer:
/// https://github.com/jakehilborn/displayplacer/tree/master/src/Headers/MonitorPanel.framework/Headers
private final class DynamicDisplayReferencePresetRuntime: DisplayReferencePresetRuntime {
    typealias GetObject = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
    typealias GetInt = @convention(c) (AnyObject, Selector) -> Int32
    typealias GetUInt = @convention(c) (AnyObject, Selector) -> UInt32
    typealias GetIndex = @convention(c) (AnyObject, Selector) -> UInt64
    typealias SetPreset = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private lazy var image = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL)
    private struct Record { let option: DisplayReferencePresetOption; let object: NSObject }

    func state(_ target: DisplayHardwareTarget) throws -> DisplayReferencePresetState? {
        try autoreleasepool {
            guard let display = try display(target),
                  let has = method(display, "hasPresets", result: "B"), bool(display, has, "hasPresets"),
                  method(display, "setActivePreset:", result: "B", parameters: ["@"]) != nil,
                  let list = try records(display, target: target),
                  let active = object(display, "activePreset") as? NSObject,
                  let selected = try record(active, target: target) else { return nil }
            try validate(target)
            return try DisplayReferencePresetCatalog.state(options: list.map(\.option), selectedID: selected.option.id)
        }
    }

    func select(_ presetID: String, for target: DisplayHardwareTarget) throws {
        try autoreleasepool {
            guard let display = try display(target), let list = try records(display, target: target),
                  let selected = list.first(where: { $0.option.id == presetID }),
                  let setter = method(display, "setActivePreset:", result: "B", parameters: ["@"]) else {
                throw DisplayReferencePresetError.unavailable
            }
            guard list.filter({ $0.option.id == presetID }).count == 1 else { throw DisplayReferencePresetError.invalidCatalog }
            try validate(target)
            guard unsafeBitCast(method_getImplementation(setter), to: SetPreset.self)(display, NSSelectorFromString("setActivePreset:"), selected.object) else {
                throw DisplayReferencePresetError.notApplied
            }
        }
    }

    private func records(_ display: NSObject, target: DisplayHardwareTarget) throws -> [Record]? {
        guard let list = object(display, "presets") as? [NSObject], list.count <= 256 else { return nil }
        var valid: [Record] = []
        for candidate in list { if let entry = try record(candidate, target: target) { valid.append(entry) } }
        guard Set(valid.map(\.option.id)).count == valid.count else { throw DisplayReferencePresetError.invalidCatalog }
        return valid
    }

    private func record(_ candidate: NSObject, target: DisplayHardwareTarget) throws -> Record? {
        guard let isValid = method(candidate, "isValid", result: "B"), bool(candidate, isValid, "isValid") else { return nil }
        guard let getID = method(candidate, "displayID", result: "I"),
              unsafeBitCast(method_getImplementation(getID), to: GetUInt.self)(candidate, NSSelectorFromString("displayID")) == target.displayID else {
            throw DisplayReferencePresetError.disconnected
        }
        guard let index = method(candidate, "presetIndex", result: "Q"),
              let name = object(candidate, "presetName") as? String, !name.isEmpty, name.count <= 512,
              let dictionary = object(candidate, "presetDictionary") as? [String: Any] else {
            throw DisplayReferencePresetError.invalidCatalog
        }
        // Verify the native scalar ABI even though UI identity is never an index.
        _ = unsafeBitCast(method_getImplementation(index), to: GetIndex.self)(candidate, NSSelectorFromString("presetIndex"))
        guard let option = try DisplayReferencePresetCatalog.option(isValid: true,
            uniqueID: dictionary["PresetUniqueID"], name: name, metadata: dictionary) else { return nil }
        return Record(option: option, object: candidate)
    }

    private func display(_ target: DisplayHardwareTarget) throws -> NSObject? {
        guard image != nil, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let manager = cls.init()
        guard let displays = object(manager, "displays") as? [NSObject], displays.count <= 128 else { return nil }
        let matches = displays.filter { display in
            guard let getID = method(display, "displayID", result: "i") else { return false }
            return UInt32(bitPattern: unsafeBitCast(method_getImplementation(getID), to: GetInt.self)(display, NSSelectorFromString("displayID"))) == target.displayID
        }
        guard matches.count == 1, let display = matches.first, let uuid = object(display, "uuid") as? NSUUID,
              uuid.uuidString.caseInsensitiveCompare(target.uuid) == .orderedSame else { throw DisplayReferencePresetError.disconnected }
        try validate(target)
        return display
    }

    private func validate(_ target: DisplayHardwareTarget) throws {
        guard CGDisplayIsOnline(target.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame,
              (CGDisplayIsBuiltin(target.displayID) != 0) == target.isBuiltin else { throw DisplayReferencePresetError.disconnected }
    }

    private func method(_ object: NSObject, _ name: String, result: String, parameters: [String] = []) -> Method? {
        guard let method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name)) else { return nil }
        let actual = method_copyReturnType(method)
        defer { free(actual) }
        guard String(cString: actual) == result, method_getNumberOfArguments(method) == parameters.count + 2 else { return nil }
        let expected = ["@", ":"] + parameters
        for index in expected.indices {
            guard let argument = method_copyArgumentType(method, UInt32(index)) else { return nil }
            defer { free(argument) }
            guard String(cString: argument) == expected[index] else { return nil }
        }
        return method
    }

    private func object(_ object: NSObject, _ name: String) -> AnyObject? {
        guard let method = method(object, name, result: "@") else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: GetObject.self)(object, NSSelectorFromString(name))?.takeUnretainedValue()
    }
    private func bool(_ object: NSObject, _ method: Method, _ name: String) -> Bool {
        unsafeBitCast(method_getImplementation(method), to: GetBool.self)(object, NSSelectorFromString(name))
    }
}
