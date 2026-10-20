import Foundation
import CoreFoundation
import Darwin

/// Values retain both their property-list type and absence. Bool and integer 1
/// deliberately compare differently; restoring a missing key deletes only that key.
public indirect enum SystemDockValue: Codable, Equatable, Sendable {
    case bool(Bool), integer(Int64), real(Double), string(String), data(Data), date(Date)
    case array([SystemDockValue]), dictionary([String: SystemDockValue])

    public init(propertyList value: Any) throws {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) {
                guard number.doubleValue.isFinite else { throw SystemDockRecoveryError.invalidPreferences }
                self = .real(number.doubleValue)
            } else { self = .integer(number.int64Value) }
        case let value as String: self = .string(value)
        case let value as Data: self = .data(value)
        case let value as Date: self = .date(value)
        case let value as [Any]: self = .array(try value.map(Self.init(propertyList:)))
        case let value as [String: Any]: self = .dictionary(try value.mapValues(Self.init(propertyList:)))
        default: throw SystemDockRecoveryError.invalidPreferences
        }
    }

    public var propertyList: Any {
        switch self {
        case .bool(let value): return NSNumber(value: value)
        case .integer(let value): return NSNumber(value: value)
        case .real(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .data(let value): return value
        case .date(let value): return value
        case .array(let values): return values.map(\.propertyList)
        case .dictionary(let values): return values.mapValues(\.propertyList)
        }
    }
}

public enum SystemDockPreference: Codable, Equatable, Sendable {
    case missing, value(SystemDockValue)
}

public enum SystemDockRecoveryError: Error, LocalizedError, Sendable {
    case invalidPreferences, unsafeJournal, journalBusy, anotherOwner, staleIdentity
    case missingHelper, helperTimeout, operationFailed, processTimeout, changedPreferences

    public var errorDescription: String? {
        switch self {
        case .invalidPreferences: "Не удалось прочитать типы настроек системного Dock."
        case .unsafeJournal: "Журнал восстановления Dock недоступен или имеет небезопасные права."
        case .journalBusy: "Восстановление системного Dock уже выполняется."
        case .anotherOwner: "Системным Dock уже управляет другой запущенный экземпляр NooL."
        case .staleIdentity: "Процесс владельца или помощник восстановления Dock изменился."
        case .missingHelper: "Помощник восстановления Dock недоступен."
        case .helperTimeout: "Помощник восстановления Dock не подтвердил готовность."
        case .operationFailed: "Не удалось изменить настройки системного Dock."
        case .processTimeout: "Перезапуск системного Dock превысил время ожидания."
        case .changedPreferences: "Настройки системного Dock изменились во время включения."
        }
    }
}

public struct SystemDockProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.uid = uid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }

    public static func live(_ pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        guard count == size, info.pbi_pid == UInt32(pid), info.pbi_status != SZOMB,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return .init(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                     startMicroseconds: info.pbi_start_tvusec)
    }
}

public struct SystemDockJournal: Codable, Equatable, Sendable {
    public let version: Int
    public let token: UUID
    public let owner: SystemDockProcessIdentity
    public var helper: SystemDockProcessIdentity?
    public let original: [String: SystemDockPreference]
    public var mutationStarted: Bool

    public init(token: UUID = UUID(), owner: SystemDockProcessIdentity,
                original: [String: SystemDockPreference]) {
        self.version = 1; self.token = token; self.owner = owner
        self.original = original; self.helper = nil; self.mutationStarted = false
    }
}

public protocol SystemDockPreferenceBackend: Sendable {
    func read(_ key: String) throws -> SystemDockPreference
    func write(_ value: SystemDockPreference, for key: String) throws
    func restartDock() throws
}

/// CFPreferences changes only these two current-user, any-host keys. The restart
/// executable receives individual arguments and is restricted to the caller UID.
public struct SystemDockNativePreferences: SystemDockPreferenceBackend {
    public init() {}

    public func read(_ key: String) throws -> SystemDockPreference {
        guard SystemDockRecoveryEngine.writes[key] != nil else { throw SystemDockRecoveryError.invalidPreferences }
        guard CFPreferencesSynchronize("com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        else { throw SystemDockRecoveryError.operationFailed }
        guard let value = CFPreferencesCopyValue(key as CFString, "com.apple.dock" as CFString,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return .missing }
        return .value(try SystemDockValue(propertyList: value))
    }

    public func write(_ value: SystemDockPreference, for key: String) throws {
        guard SystemDockRecoveryEngine.writes[key] != nil, getuid() == geteuid(), getuid() != 0
        else { throw SystemDockRecoveryError.invalidPreferences }
        let native: CFPropertyList?
        switch value {
        case .missing: native = nil
        case .value(let value): native = value.propertyList as CFPropertyList
        }
        CFPreferencesSetValue(key as CFString, native, "com.apple.dock" as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize("com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        else { throw SystemDockRecoveryError.operationFailed }
    }

    public func restartDock() throws {
        guard getuid() == geteuid(), getuid() != 0 else { throw SystemDockRecoveryError.operationFailed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", String(getuid()), "Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw SystemDockRecoveryError.processTimeout
        }
        guard process.terminationStatus == 0 else { throw SystemDockRecoveryError.operationFailed }
    }
}

/// A private 0700 directory and 0600 regular files. All readers/writers use the
/// same flock, including the independent process after the app crashes.
public final class SystemDockJournalStore: @unchecked Sendable {
    public let directory: URL
    public let uid: UInt32

    public init(directory: URL, uid: UInt32 = getuid()) {
        // Keep the caller's spelling until lstat has checked every component.
        // Foundation standardization can alias existing /private/tmp to /tmp,
        // introducing a symlink that was not present in the supplied safe path.
        self.directory = directory; self.uid = uid
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NooL App/SystemDockRecovery", isDirectory: true)
    }

    /// A failed decode/permission check must not make an existing recovery
    /// journal disappear from the UI. Metadata only; never follows the final
    /// symlink or reads untrusted journal contents here.
    public func hasJournalEntry() -> Bool {
        var info = stat()
        return lstat(directory.appendingPathComponent("journal.json").path, &info) == 0
    }

    public func withLock<T>(_ body: (Locked) throws -> T) throws -> T {
        try prepareDirectory()
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw SystemDockRecoveryError.unsafeJournal }
        defer { close(dir) }
        let lock = openat(dir, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw SystemDockRecoveryError.unsafeJournal }
        defer { close(lock) }
        try Self.validate(lock, uid: uid)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw SystemDockRecoveryError.unsafeJournal }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SystemDockRecoveryError.journalBusy }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(lock, LOCK_UN) }
        return try body(.init(directoryFD: dir, uid: uid))
    }

    private func prepareDirectory() throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), uid == getuid() else { throw SystemDockRecoveryError.unsafeJournal }
        // Refuse existing symlinks in every component, including the journal root.
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            cursor.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(cursor.path, &info) != 0 {
                guard errno == ENOENT, mkdir(cursor.path, 0o700) == 0 || errno == EEXIST,
                      lstat(cursor.path, &info) == 0 else { throw SystemDockRecoveryError.unsafeJournal }
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw SystemDockRecoveryError.unsafeJournal }
            if cursor.path == directory.path {
                guard info.st_uid == uid, info.st_mode & 0o077 == 0 else { throw SystemDockRecoveryError.unsafeJournal }
            }
        }
    }

    private static func validate(_ fd: Int32, uid: UInt32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw SystemDockRecoveryError.unsafeJournal }
    }

    public struct Locked {
        fileprivate let directoryFD: Int32
        fileprivate let uid: UInt32

        public func load() throws -> SystemDockJournal? {
            let fd = openat(directoryFD, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { return nil }
            guard fd >= 0 else { throw SystemDockRecoveryError.unsafeJournal }
            defer { close(fd) }
            try SystemDockJournalStore.validate(fd, uid: uid)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 65_536 else { throw SystemDockRecoveryError.unsafeJournal }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            let journal: SystemDockJournal
            do { journal = try JSONDecoder().decode(SystemDockJournal.self, from: data) }
            catch { throw SystemDockRecoveryError.unsafeJournal }
            guard journal.version == 1, journal.owner.uid == uid, journal.owner.pid > 0,
                  journal.owner.startMicroseconds < 1_000_000,
                  Set(journal.original.keys) == Set(SystemDockRecoveryEngine.writes.keys),
                  journal.helper.map({ $0.uid == uid && $0.pid > 0 && $0.startMicroseconds < 1_000_000 }) ?? true
            else { throw SystemDockRecoveryError.unsafeJournal }
            return journal
        }

        public func save(_ journal: SystemDockJournal) throws {
            _ = try load() // Refuse replacing an existing unsafe file.
            let data = try JSONEncoder().encode(journal)
            guard data.count <= 65_536 else { throw SystemDockRecoveryError.invalidPreferences }
            let name = ".journal-\(UUID().uuidString).tmp"
            let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SystemDockRecoveryError.unsafeJournal }
            defer { close(fd); unlinkat(directoryFD, name, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw SystemDockRecoveryError.unsafeJournal }
                    offset += count
                }
            }
            guard fsync(fd) == 0, renameat(directoryFD, name, directoryFD, "journal.json") == 0,
                  fsync(directoryFD) == 0 else { throw SystemDockRecoveryError.unsafeJournal }
        }

        public func remove() throws {
            _ = try load()
            guard unlinkat(directoryFD, "journal.json", 0) == 0 || errno == ENOENT,
                  fsync(directoryFD) == 0 else { throw SystemDockRecoveryError.unsafeJournal }
        }
    }
}

public struct SystemDockRestoreResult: Equatable, Sendable {
    public var conflicts: [String]
    public init(conflicts: [String] = []) { self.conflicts = conflicts }
}

public enum SystemDockRecoveryStatus: Equatable, Sendable {
    case none, owned, stale, unreadable, anotherOwner

    public var needsRecovery: Bool {
        self == .owned || self == .stale || self == .unreadable
    }
}

/// Recovery stays alive through temporary daemon/disk/restart failures. Attempts
/// are unbounded, but their frequency backs off to one attempt every 30 seconds.
public struct SystemDockRecoveryRetryPolicy: Sendable {
    private var failures = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval {
        let delay = min(30, pow(2, Double(min(failures, 5))))
        failures = min(failures + 1, 6)
        return delay
    }
}

public final class SystemDockRecoveryEngine: @unchecked Sendable {
    public static let writes: [String: SystemDockPreference] = [
        "autohide": .value(.bool(true)), "autohide-delay": .value(.real(1000))
    ]
    public let store: SystemDockJournalStore
    private let backend: any SystemDockPreferenceBackend
    private let identity: @Sendable (Int32) -> SystemDockProcessIdentity?

    public init(store: SystemDockJournalStore, backend: any SystemDockPreferenceBackend,
                identity: @escaping @Sendable (Int32) -> SystemDockProcessIdentity? = SystemDockProcessIdentity.live) {
        self.store = store; self.backend = backend; self.identity = identity
    }

    public func prepare(owner: SystemDockProcessIdentity) throws -> SystemDockJournal {
        try store.withLock { locked in
            guard owner.uid == store.uid, identity(owner.pid) == owner else { throw SystemDockRecoveryError.staleIdentity }
            guard try locked.load() == nil else { throw SystemDockRecoveryError.anotherOwner }
            var original: [String: SystemDockPreference] = [:]
            for key in Self.writes.keys.sorted() { original[key] = try backend.read(key) }
            let journal = SystemDockJournal(owner: owner, original: original)
            try locked.save(journal) // Durable recovery metadata always precedes any preference write.
            return journal
        }
    }

    public func registerHelper(token: UUID, helper: SystemDockProcessIdentity) throws {
        try store.withLock { locked in
            guard var journal = try locked.load(), journal.token == token,
                  journal.helper == nil, !journal.mutationStarted,
                  helper.uid == store.uid, identity(helper.pid) == helper,
                  identity(journal.owner.pid) == journal.owner else { throw SystemDockRecoveryError.staleIdentity }
            journal.helper = helper
            try locked.save(journal)
        }
    }

    public func apply(token: UUID) throws {
        try store.withLock { locked in
            guard var journal = try locked.load(), journal.token == token,
                  let helper = journal.helper, identity(helper.pid) == helper,
                  identity(journal.owner.pid) == journal.owner else { throw SystemDockRecoveryError.missingHelper }
            for key in Self.writes.keys.sorted() {
                guard try backend.read(key) == journal.original[key] else { throw SystemDockRecoveryError.changedPreferences }
            }
            journal.mutationStarted = true
            try locked.save(journal)
            do {
                for key in Self.writes.keys.sorted() {
                    // Check again at each write to narrow the external-preference race.
                    guard try backend.read(key) == journal.original[key] else { throw SystemDockRecoveryError.changedPreferences }
                    try backend.write(Self.writes[key]!, for: key)
                    guard try backend.read(key) == Self.writes[key] else { throw SystemDockRecoveryError.operationFailed }
                }
                try backend.restartDock()
                guard identity(helper.pid) == helper else { throw SystemDockRecoveryError.missingHelper }
            } catch {
                // Leave the journal intact if rollback itself fails; the helper retries.
                _ = try restoreLocked(journal, locked: locked)
                throw error
            }
        }
    }

    public func restore(token: UUID? = nil, onlyIfOwnerExited: Bool = false) throws -> SystemDockRestoreResult {
        try store.withLock { locked in
            guard let journal = try locked.load() else { return .init() }
            if let token, token != journal.token { throw SystemDockRecoveryError.anotherOwner }
            if onlyIfOwnerExited, identity(journal.owner.pid) == journal.owner { throw SystemDockRecoveryError.anotherOwner }
            return try restoreLocked(journal, locked: locked)
        }
    }

    public func journal() throws -> SystemDockJournal? { try store.withLock { try $0.load() } }
    public func ownerIsAlive(_ journal: SystemDockJournal) -> Bool { identity(journal.owner.pid) == journal.owner }

    /// Used after a failed operation only. An unreadable existing journal is
    /// attention-worthy without claiming that this instance owns another live
    /// process's replacement. No preferences are read or written.
    public func recoveryStatus(ownedToken: UUID? = nil) -> SystemDockRecoveryStatus {
        do {
            guard let journal = try journal() else { return .none }
            if let ownedToken, journal.token == ownedToken { return .owned }
            return ownerIsAlive(journal) ? .anotherOwner : .stale
        } catch { return store.hasJournalEntry() ? .unreadable : .none }
    }

    private func restoreLocked(_ journal: SystemDockJournal, locked: SystemDockJournalStore.Locked) throws -> SystemDockRestoreResult {
        guard journal.mutationStarted else {
            try locked.remove()
            return .init()
        }
        var conflicts: [String] = []
        for key in Self.writes.keys.sorted() {
            let value = try backend.read(key)
            if value == journal.original[key] { continue }
            guard value == Self.writes[key] else { conflicts.append(key); continue }
            let original = journal.original[key]!
            try backend.write(original, for: key)
            guard try backend.read(key) == original else { throw SystemDockRecoveryError.operationFailed }
        }
        if journal.mutationStarted { try backend.restartDock() }
        try locked.remove()
        return .init(conflicts: conflicts)
    }
}
