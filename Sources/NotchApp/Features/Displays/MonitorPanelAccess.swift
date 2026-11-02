import Darwin
import Foundation
import ObjectiveC.runtime

enum MonitorPanelAccessABI {
    static func matches(returnType: String, arguments: [String], expectedReturn: String) -> Bool {
        returnType == expectedReturn && arguments == ["@", ":"]
    }
}

/// HDR and reference presets share one manager and one native-call gate. Service-level
/// polling and sleeps stay outside this scope; only native objects and their use live inside.
final class MonitorPanelAccess: @unchecked Sendable {
    struct Resource {
        let manager: NSObject
        // No dlclose: MonitorPanel's observers and the shared manager outlive individual services.
        let retainedLibrary: UnsafeMutableRawPointer?
        let lockAccess: () -> Void
        let unlockAccess: () -> Void

        init(manager: NSObject, retainedLibrary: UnsafeMutableRawPointer? = nil,
             lockAccess: @escaping () -> Void = {}, unlockAccess: @escaping () -> Void = {}) {
            self.manager = manager
            self.retainedLibrary = retainedLibrary
            self.lockAccess = lockAccess
            self.unlockAccess = unlockAccess
        }
    }

    static let shared = MonitorPanelAccess(factory: makeSharedManager)

    private let gate = NSLock()
    private let factory: () -> Resource?
    private var initialized = false
    private var resource: Resource?

    init(factory: @escaping () -> Resource?) {
        self.factory = factory
    }

    func withManager<Value: Sendable>(_ operation: (NSObject?) throws -> Value) rethrows -> Value {
        gate.lock()
        defer { gate.unlock() }
        if !initialized {
            resource = autoreleasepool { factory() }
            initialized = true
        }
        resource?.lockAccess()
        defer { resource?.unlockAccess() }
        // Drain temporary MPDisplay/preset objects while the framework's own access lock
        // is still held, before allowing its asynchronous reconfiguration to replace them.
        return try autoreleasepool { try operation(resource?.manager) }
    }

    private static func makeSharedManager() -> Resource? {
        guard let image = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL),
              let cls = NSClassFromString("MPDisplayMgr"),
              let getter = class_getClassMethod(cls, NSSelectorFromString("sharedMgr")) else { return nil }
        guard matches(getter, result: "@") else { return nil }
        typealias SharedManager = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let manager = unsafeBitCast(method_getImplementation(getter), to: SharedManager.self)(
            cls as AnyObject, NSSelectorFromString("sharedMgr"))?.takeUnretainedValue() as? NSObject,
              manager.isKind(of: cls),
              let lock = class_getInstanceMethod(object_getClass(manager), NSSelectorFromString("lockAccess")),
              let unlock = class_getInstanceMethod(object_getClass(manager), NSSelectorFromString("unlockAccess")),
              matches(lock, result: "v"), matches(unlock, result: "v") else { return nil }
        typealias Access = @convention(c) (AnyObject, Selector) -> Void
        let acquire = unsafeBitCast(method_getImplementation(lock), to: Access.self)
        let release = unsafeBitCast(method_getImplementation(unlock), to: Access.self)
        // Local framework inspection verified these methods use the same access lock as
        // serviceReconfigure. The displays getter's separate data lock is not a substitute.
        return Resource(manager: manager, retainedLibrary: image,
                        lockAccess: { acquire(manager, NSSelectorFromString("lockAccess")) },
                        unlockAccess: { release(manager, NSSelectorFromString("unlockAccess")) })
    }

    private static func matches(_ method: Method, result: String) -> Bool {
        let returned = method_copyReturnType(method)
        defer { free(returned) }
        let arguments = (0..<method_getNumberOfArguments(method)).compactMap { index -> String? in
            guard let type = method_copyArgumentType(method, index) else { return nil }
            defer { free(type) }
            return String(cString: type)
        }
        return MonitorPanelAccessABI.matches(returnType: String(cString: returned), arguments: arguments, expectedReturn: result)
    }
}
