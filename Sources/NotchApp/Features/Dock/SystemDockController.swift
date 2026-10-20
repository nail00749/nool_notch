import Foundation
import Combine
import Darwin
import NotchCore

enum SystemDockOperation: Equatable, Sendable { case enable, restore, recover }
struct SystemDockOperationResult: Sendable {
    var active: Bool
    var error: String? = nil
    var recoveryPending: Bool = false
}
protocol SystemDockOperating: Sendable {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult
}

@MainActor
final class SystemDockController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryPending = false

    private let worker: any SystemDockOperating
    private var queuedOperation: Task<Void, Never>?
    private var operationID: UInt64 = 0

    init() { worker = SystemDockWorker() }
    init(operations: any SystemDockOperating) { worker = operations }

    /// The coordinator calls this only after its own Dock and recovery action
    /// are ready. Old Dock preferences never automatically enable replacement.
    func setEnabled(_ enabled: Bool) async {
        await run(enabled ? .enable : .restore)
    }

    func restore() async { await setEnabled(false) }

    /// Startup cleanup is read/restore only; it never opts the user into hiding.
    func recoverIfNeeded() async {
        guard !isActive, !isBusy else { return }
        await run(.recover)
    }

    private func run(_ operation: SystemDockOperation) async {
        // In particular, a module-stop restore must wait behind an in-flight
        // enable, never get discarded by an isBusy guard.
        let previous = queuedOperation
        operationID &+= 1
        let id = operationID
        isBusy = true
        let task = Task { [self] in
            if let previous { await previous.value }
            errorMessage = nil
            let result = await worker.perform(operation)
            isActive = result.active
            errorMessage = result.error
            recoveryPending = result.recoveryPending
            if operationID == id { queuedOperation = nil; isBusy = false }
        }
        queuedOperation = task
        await task.value
    }
}

/// All disk/CFPreferences/process work is serialized off the main actor. Detached
/// work is deliberately awaited even on cancellation: never abandon a commit or
/// a restore halfway through because the settings view disappeared.
private actor SystemDockWorker: SystemDockOperating {
    private let engine: SystemDockRecoveryEngine
    private var token: UUID?
    private var helper: Process?

    init() {
        engine = SystemDockRecoveryEngine(store: .init(directory: SystemDockJournalStore.defaultDirectory),
                                          backend: SystemDockNativePreferences())
    }

    /// What the worker owns after an operation: the replacement token and the recovery helper.
    private struct Outcome: Sendable {
        var result: SystemDockOperationResult
        var token: UUID? = nil
        var helper: SendableProcess? = nil
    }

    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        let engine = engine
        let owned = Outcome(result: .init(active: token != nil), token: token, helper: helper.map(SendableProcess.init))
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            do {
                switch operation {
                case .enable: return try Self.enable(engine: engine, owned: owned)
                case .restore:
                    let restored = try engine.restore(token: owned.token, onlyIfOwnerExited: owned.token == nil)
                    Self.stop(owned.helper?.process)
                    return Outcome(result: .init(active: false, error: Self.conflictMessage(restored.conflicts)))
                case .recover:
                    let restored = try engine.restore(onlyIfOwnerExited: true)
                    return Outcome(result: .init(active: false, error: Self.conflictMessage(restored.conflicts)))
                }
            } catch {
                return Self.failure(error, engine: engine, token: owned.token, helper: owned.helper)
            }
        }.value
        token = outcome.token
        helper = outcome.helper?.process
        return outcome.result
    }

    private nonisolated static func enable(engine: SystemDockRecoveryEngine, owned: Outcome) throws -> Outcome {
        if let token = owned.token, let current = try engine.journal(), current.token == token {
            return Outcome(result: .init(active: true), token: token, helper: owned.helper)
        }
        // Refuse before even creating a journal if the packaged,
        // independently running recovery executable is unavailable.
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("nool-dock-recovery"),
              FileManager.default.isExecutableFile(atPath: url.path),
              let owner = SystemDockProcessIdentity.live(getpid()) else { throw SystemDockRecoveryError.missingHelper }
        if try engine.journal() != nil {
            let restored = try engine.restore(onlyIfOwnerExited: true)
            if !restored.conflicts.isEmpty {
                return Outcome(result: .init(active: false, error: conflictMessage(restored.conflicts)))
            }
        }
        let journal = try engine.prepare(owner: owner)
        var child: Process?
        do {
            child = try startHelper(url: url, journal: journal, directory: engine.store.directory)
            try engine.apply(token: journal.token)
            return Outcome(result: .init(active: true), token: journal.token, helper: child.map(SendableProcess.init))
        } catch {
            // A failed restoration leaves its helper running and its
            // journal retained, ready for retry or crash recovery.
            do {
                let restored = try engine.restore(token: journal.token)
                stop(child)
                return Outcome(result: .init(active: false, error: describe(error, conflicts: restored.conflicts)))
            } catch {
                return failure(error, engine: engine, token: journal.token, helper: child.map(SendableProcess.init))
            }
        }
    }

    /// Keeps ownership (and the helper) only while a journal still needs recovery.
    private nonisolated static func failure(_ error: Error, engine: SystemDockRecoveryEngine,
                                            token: UUID?, helper: SendableProcess?) -> Outcome {
        let status = engine.recoveryStatus(ownedToken: token)
        if status == .none || status == .anotherOwner { stop(helper?.process) }
        return Outcome(result: .init(active: status == .owned, error: error.localizedDescription,
                                     recoveryPending: status.needsRecovery),
                       token: status == .owned ? token : nil,
                       helper: status.needsRecovery ? helper : nil)
    }

    private nonisolated static func conflictMessage(_ keys: [String]) -> String? {
        keys.isEmpty ? nil : "Настройки системного Dock изменены вне NooL. Сохранены ваши новые значения: \(keys.joined(separator: ", "))."
    }

    private nonisolated static func describe(_ error: Error, conflicts: [String]) -> String {
        [error.localizedDescription, conflictMessage(conflicts)].compactMap { $0 }.joined(separator: " ")
    }

    private nonisolated static func startHelper(url: URL, journal: SystemDockJournal, directory: URL) throws -> Process {
        let process = Process(), output = Pipe()
        process.executableURL = url
        process.arguments = ["--watch", directory.path, journal.token.uuidString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            stop(process); throw SystemDockRecoveryError.helperTimeout
        }
        let expected = Data("READY \(journal.token.uuidString)\n".utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var data = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            if data == expected, process.isRunning { return process }
            if data.count > expected.count || !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop(process)
        throw SystemDockRecoveryError.helperTimeout
    }

    private nonisolated static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// Process is only touched by the serialized worker; this wrapper crosses the detached hop.
private struct SendableProcess: @unchecked Sendable {
    let process: Process
}
