#if DEBUG
import Foundation
import Darwin
import NotchCore

/// The subprocess crash test uses this DEBUG-only file-backed fake. It never
/// instantiates SystemDockNativePreferences or accesses com.apple.dock.
func runSystemDockRecoveryFixture(_ arguments: [String]) -> Never {
    guard arguments.count >= 3 else { exit(64) }
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    guard directory.path.hasPrefix("/private/tmp/nool-system-dock-process-") else {
        try? FileHandle.standardError.write(contentsOf: Data("fixture path rejected: \(directory.path)\n".utf8))
        exit(65)
    }
    let store = SystemDockJournalStore(directory: directory)
    let backend = FixtureDockPreferences(directory: directory)
    let engine = SystemDockRecoveryEngine(store: store, backend: backend)
    do {
        switch arguments[1] {
        case "--fixture-parent":
            guard arguments.count == 3, let owner = SystemDockProcessIdentity.live(getpid()) else { exit(66) }
            try store.withLock { _ in try backend.seed() }
            let journal = try engine.prepare(owner: owner)
            let helper = Process(), output = Pipe()
            helper.executableURL = URL(fileURLWithPath: arguments[0])
            helper.arguments = ["--fixture-watch", directory.path, journal.token.uuidString]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = output
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            let fd = output.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { helper.terminate(); exit(67) }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var ready = Data()
            let expected = Data("READY\n".utf8)
            while ready != expected && helper.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { ready.append(contentsOf: bytes.prefix(count)) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard ready == expected, helper.isRunning else { helper.terminate(); exit(68) }
            try engine.apply(token: journal.token)
            // More than the old fixed retry budget: exercise the independent
            // process through seven transient failures after the parent exits.
            try Data("7".utf8).write(to: directory.appendingPathComponent("fixture-restart-failures"))
            try FileHandle.standardOutput.write(contentsOf: Data("ACTIVE \(helper.processIdentifier)\n".utf8))
            while true { Thread.sleep(forTimeInterval: 1) }
        case "--fixture-watch":
            guard arguments.count == 4, let token = UUID(uuidString: arguments[3]),
                  let identity = SystemDockProcessIdentity.live(getpid()),
                  let journal = try engine.journal(), journal.token == token,
                  journal.owner.pid == getppid(), engine.ownerIsAlive(journal) else { exit(69) }
            try engine.registerHelper(token: token, helper: identity)
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            while engine.ownerIsAlive(journal) { Thread.sleep(forTimeInterval: 0.05) }
            var retry = SystemDockRecoveryRetryPolicy()
            while true {
                do { _ = try engine.restore(token: token, onlyIfOwnerExited: true); exit(0) }
                catch SystemDockRecoveryError.anotherOwner { exit(0) }
                catch { Thread.sleep(forTimeInterval: min(0.01, retry.nextDelay())) }
            }
        default: exit(64)
        }
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data("fixture error: \(error)\n".utf8))
        exit(1)
    }
}

private struct FixtureDockPreferences: SystemDockPreferenceBackend {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("fixture-preferences.json") }
    func seed() throws {
        try save(["autohide": .value(.bool(false)), "autohide-delay": .missing])
    }
    func read(_ key: String) throws -> SystemDockPreference {
        try load()[key] ?? .missing
    }
    func write(_ value: SystemDockPreference, for key: String) throws {
        var state = try load()
        state[key] = value
        try save(state)
    }
    func restartDock() throws {
        // Deliberately does not execute any process or write native preferences.
        let counter = directory.appendingPathComponent("fixture-restart-failures")
        guard let text = try? String(contentsOf: counter, encoding: .utf8), let count = Int(text), count > 0 else { return }
        try Data(String(count - 1).utf8).write(to: counter)
        throw SystemDockRecoveryError.operationFailed
    }
    private func load() throws -> [String: SystemDockPreference] {
        try JSONDecoder().decode([String: SystemDockPreference].self, from: Data(contentsOf: file))
    }
    private func save(_ values: [String: SystemDockPreference]) throws {
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw SystemDockRecoveryError.unsafeJournal }
    }
}
#endif
