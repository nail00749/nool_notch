import Foundation
import Security
import IOKit
import IOKit.pwr_mgt
import NoolCoolingCore
import Darwin

private final class OwnershipJournal: @unchecked Sendable {
    private let directory = "/var/db/com.nool.cooling-helper"
    private var path: String { directory + "/active.json" }
    init() throws {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EACCES) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_mode & 0o022 == 0 else { throw POSIXError(.EACCES) }
    }
    func read() throws -> Set<Int> {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o077 == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1024 else { throw POSIXError(.EACCES) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw POSIXError(.EIO) }
        let ids = try JSONDecoder().decode([Int].self, from: Data(bytes))
        guard ids.count <= 10, ids.allSatisfy({ (0..<10).contains($0) }) else { throw POSIXError(.EINVAL) }
        return Set(ids)
    }
    func write(_ ids: Set<Int>) throws {
        guard ids.allSatisfy({ (0..<10).contains($0) }) else { throw POSIXError(.EINVAL) }
        let data = try JSONEncoder().encode(ids.sorted())
        let temporary = directory + "/" + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd); unlink(temporary) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary, path) == 0 else { throw POSIXError(.EIO) }
        let dirFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirFD >= 0 { defer { close(dirFD) }; guard fsync(dirFD) == 0 else { throw POSIXError(.EIO) } }
    }
}

private final class Runtime: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.nool.cooling-helper.control")
    let hardware = CoolingSMC()
    let journal: OwnershipJournal
    let controller: CoolingController
    private var recovery: Set<Int>
    private var timer: DispatchSourceTimer?
    init() throws {
        journal = try OwnershipJournal()
        recovery = try journal.read()
        let store = journal
        controller = CoolingController(hardware: hardware, persistOwned: { try store.write($0) })
    }
    func start() {
        queue.sync { recoverIfNeeded() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.recoverIfNeeded()
            if self.recovery.isEmpty { self.controller.tick() }
        }
        self.timer = timer; timer.resume()
    }
    func ensureRecovered() throws {
        guard recovery.isEmpty else { throw CoolingError.hardware("Восстанавливаем автоматическое управление после перезапуска помощника.") }
    }
    @discardableResult
    func restore() -> Bool {
        do { try ensureRecovered(); try controller.restoreAll(); return true }
        catch { return false }
    }
    private func recoverIfNeeded() {
        guard !recovery.isEmpty else { return }
        do { try hardware.recoverControl(fanIDs: recovery.sorted()); try journal.write([]); recovery = [] }
        catch { /* Keep ownership journal and retry next second. Never log metrics or user payloads. */ }
    }
}

// XPC reply blocks may be invoked on the exported object's serial work queue.
private struct XPCReply<Callback>: @unchecked Sendable { let call: Callback }

private final class Endpoint: NSObject, NoolCoolingHelperProtocol, @unchecked Sendable {
    private let runtime: Runtime
    private let lease = CoolingEndpointLease()
    init(runtime: Runtime) { self.runtime = runtime }
    func snapshot(reply: @escaping (Data?, String?) -> Void) {
        let response = XPCReply(call: reply)
        runtime.queue.async { [self] in
            do { try runtime.ensureRecovered(); response.call(try JSONEncoder().encode(runtime.controller.snapshot()), nil) }
            catch { response.call(nil, error.localizedDescription) }
        }
    }
    func apply(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        let response = XPCReply(call: reply)
        runtime.queue.async { [self] in
            do {
                try runtime.ensureRecovered()
                guard request.count <= 16_384 else { throw CoolingError.invalidRequest("Слишком большой запрос управления.") }
                let command = try JSONDecoder().decode(CoolingControlRequest.self, from: request)
                let result = try lease.apply(command, using: runtime.controller)
                response.call(try JSONEncoder().encode(result), nil)
            } catch { response.call(nil, error.localizedDescription) }
        }
    }
    func heartbeat(_ sessionID: String, reply: @escaping (String?) -> Void) {
        let response = XPCReply(call: reply)
        runtime.queue.async { [self] in
            do {
                try lease.heartbeat(sessionID, using: runtime.controller); response.call(nil)
            } catch { response.call(error.localizedDescription) }
        }
    }
    func release(_ sessionID: String, reply: @escaping (String?) -> Void) {
        let response = XPCReply(call: reply)
        runtime.queue.async { [self] in
            do {
                try runtime.ensureRecovered()
                try lease.release(sessionID, using: runtime.controller); response.call(nil)
            } catch { response.call(error.localizedDescription) }
        }
    }
    func disconnected() {
        runtime.queue.async { [self] in
            lease.disconnect(using: runtime.controller)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let runtime: Runtime
    init(runtime: Runtime) { self.runtime = runtime }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let endpoint = Endpoint(runtime: runtime)
        connection.exportedInterface = NSXPCInterface(with: NoolCoolingHelperProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.disconnected() }
        connection.interruptionHandler = { endpoint.disconnected() }
        connection.resume()
        return true
    }
}

private func signingTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let dictionary = information as? [String: Any],
          let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
          !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
    return team
}

private final class PowerObserver {
    let runtime: Runtime
    var root: io_connect_t = 0
    var port: IONotificationPortRef?
    var notifier: io_object_t = 0
    init(runtime: Runtime) {
        self.runtime = runtime
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            // IOMessage.h iokit_common_msg macros are not imported into Swift.
            if message == 0xe0000280 {
                observer.runtime.queue.sync { observer.runtime.restore() }
                IOAllowPowerChange(observer.root, Int(bitPattern: argument))
            } else if message == 0xe0000270 {
                IOAllowPowerChange(observer.root, Int(bitPattern: argument))
            }
        }, &notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

if CommandLine.arguments.dropFirst() == ["--probe"] {
    do {
        let result = try CoolingSMC().snapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(result))
        exit(0)
    } catch { try? FileHandle.standardError.write(contentsOf: Data(error.localizedDescription.utf8)); exit(1) }
}
guard geteuid() == 0, let team = signingTeam() else { exit(77) }
do {
    let runtime = try Runtime()
    runtime.start()
    let listener = NSXPCListener(machServiceName: CoolingService.machServiceName)
    listener.setConnectionCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.nailuyltyev.NotchApp\"")
    let delegate = ListenerDelegate(runtime: runtime)
    listener.delegate = delegate
    let powerObserver = PowerObserver(runtime: runtime)
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: runtime.queue)
    termination.setEventHandler { exit(runtime.restore() ? 0 : 1) }; termination.resume()
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: runtime.queue)
    interrupt.setEventHandler { exit(runtime.restore() ? 0 : 1) }; interrupt.resume()
    listener.activate()
    withExtendedLifetime((delegate, powerObserver, termination, interrupt)) { RunLoop.main.run() }
} catch { exit(78) }
