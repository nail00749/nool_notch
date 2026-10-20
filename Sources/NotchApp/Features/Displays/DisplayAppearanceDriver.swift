import CoreGraphics
import Darwin
import Foundation

enum SystemDisplayAppearanceError: LocalizedError, Equatable {
    case unavailable
    case sessionUnavailable
    case invalidState
    case verificationFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Переключение системной темы недоступно в этой версии macOS."
        case .sessionUnavailable: "Нет доступа к текущему графическому сеансу macOS."
        case .invalidState: "Не удалось прочитать системную тему macOS."
        case .verificationFailed: "macOS не подтвердила изменение системной темы."
        case .rollbackFailed: "Не удалось восстановить исходный режим системной темы после ошибки. Проверьте настройки оформления macOS."
        }
    }
}

/// Synchronous WindowServer IPC: the owner must call this driver on its background serial worker.
/// It controls the system's Light, Dark, and Automatic appearance modes only.
struct SystemDisplayAppearanceDriver: DisplaySystemAppearanceDriving {
    private let bindings: SystemDisplayAppearanceBindings

    init() { bindings = NativeSystemAppearance.bindings }
    init(bindings: SystemDisplayAppearanceBindings) { self.bindings = bindings }

    /// Nil means unsupported symbols; an inaccessible session is a read failure, never Light mode.
    func read() throws -> Bool? {
        guard let read = bindings.readDarkMode, bindings.writeDarkMode != nil else { return nil }
        guard bindings.hasWindowServerAccess() else { throw SystemDisplayAppearanceError.sessionUnavailable }
        return try read()
    }

    func setDarkMode(_ enabled: Bool) throws {
        try setMode(enabled ? .dark : .light)
    }

    func readMode() throws -> DisplayAppearanceMode? {
        guard bindings.readDarkMode != nil, bindings.writeDarkMode != nil,
              let automatic = bindings.readAutomatic, bindings.writeAutomatic != nil else { return nil }
        guard bindings.hasWindowServerAccess() else { throw SystemDisplayAppearanceError.sessionUnavailable }
        if try automatic() { return .automatic }
        return try bindings.readDarkMode?() == true ? .dark : .light
    }

    func setMode(_ mode: DisplayAppearanceMode) throws {
        guard let read = bindings.readDarkMode, let write = bindings.writeDarkMode,
              let readAutomatic = bindings.readAutomatic, let writeAutomatic = bindings.writeAutomatic else {
            throw SystemDisplayAppearanceError.unavailable
        }
        guard bindings.hasWindowServerAccess() else { throw SystemDisplayAppearanceError.sessionUnavailable }
        let previous = (dark: try read(), automatic: try readAutomatic())
        if mode == .automatic, previous.automatic { return }
        if mode != .automatic, !previous.automatic, previous.dark == (mode == .dark) { return }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        do {
            if mode == .automatic {
                // The system schedule chooses the effective theme; do not force Light or Dark.
                try writeAutomatic(true)
                guard try verify(until: deadline, { try readAutomatic() }) else {
                    throw SystemDisplayAppearanceError.verificationFailed
                }
            } else {
                if previous.automatic {
                    try writeAutomatic(false)
                    guard try verify(until: deadline, { try !readAutomatic() }) else {
                        throw SystemDisplayAppearanceError.verificationFailed
                    }
                }
                try write(mode == .dark)
                guard try verify(until: deadline, { try !readAutomatic() && read() == (mode == .dark) }) else {
                    throw SystemDisplayAppearanceError.verificationFailed
                }
            }
        } catch {
            let originalError = error
            do {
                let rollbackDeadline = ContinuousClock.now.advanced(by: .milliseconds(300))
                if try read() != previous.dark {
                    if try readAutomatic() {
                        try writeAutomatic(false)
                        guard try verify(until: rollbackDeadline, { try !readAutomatic() }) else {
                            throw SystemDisplayAppearanceError.verificationFailed
                        }
                    }
                    try write(previous.dark)
                }
                if try readAutomatic() != previous.automatic { try writeAutomatic(previous.automatic) }
                // Re-enabling Automatic may immediately choose another effective theme.
                // Restore the captured effective value as well, without changing the schedule.
                if try read() != previous.dark { try write(previous.dark) }
                guard try verify(until: rollbackDeadline, {
                    try read() == previous.dark && readAutomatic() == previous.automatic
                }) else { throw SystemDisplayAppearanceError.verificationFailed }
            } catch { throw SystemDisplayAppearanceError.rollbackFailed }
            throw originalError
        }
    }

    private func verify(until deadline: ContinuousClock.Instant, _ predicate: () throws -> Bool) throws -> Bool {
        for attempt in 0..<20 {
            guard bindings.hasWindowServerAccess() else { throw SystemDisplayAppearanceError.sessionUnavailable }
            if try predicate() { return true }
            guard attempt < 19, ContinuousClock.now < deadline else { return false }
            bindings.wait(0.015)
        }
        return false
    }
}

struct SystemDisplayAppearanceBindings: Sendable {
    let readDarkMode: (@Sendable () throws -> Bool)?
    let writeDarkMode: (@Sendable (Bool) throws -> Void)?
    let readAutomatic: (@Sendable () throws -> Bool)?
    let writeAutomatic: (@Sendable (Bool) throws -> Void)?
    let hasWindowServerAccess: @Sendable () -> Bool
    let wait: @Sendable (TimeInterval) -> Void
}

private enum NativeSystemAppearance {
    // The legacy ABI uses 0/1 in w0; the automatic getter masks its result to a C boolean.
    // The setters are void. They are loaded dynamically to tolerate removal on a future OS.
    private typealias GetTheme = @convention(c) () -> Int32
    private typealias SetTheme = @convention(c) (Int32) -> Void
    private typealias GetAutomatic = @convention(c) () -> Bool
    private typealias SetAutomatic = @convention(c) (Bool) -> Void

    static let bindings = makeBindings()

    private static func makeBindings() -> SystemDisplayAppearanceBindings {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        // The library handle deliberately remains open for the lifetime of these function pointers.
        let get: GetTheme? = handle.flatMap { dlsym($0, "SLSGetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: GetTheme.self) }
        let set: SetTheme? = handle.flatMap { dlsym($0, "SLSSetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: SetTheme.self) }
        let automatic: GetAutomatic? = handle.flatMap { dlsym($0, "SLSGetAppearanceThemeSwitchesAutomatically") }.map { unsafeBitCast($0, to: GetAutomatic.self) }
        let setAutomatic: SetAutomatic? = handle.flatMap { dlsym($0, "SLSSetAppearanceThemeSwitchesAutomatically") }.map { unsafeBitCast($0, to: SetAutomatic.self) }
        var read: (@Sendable () throws -> Bool)?
        if let get {
            read = { @Sendable in
                let state = get()
                guard state == 0 || state == 1 else { throw SystemDisplayAppearanceError.invalidState }
                return state == 1
            }
        }
        var write: (@Sendable (Bool) throws -> Void)?
        if let set {
            write = { @Sendable enabled in set(enabled ? 1 : 0) }
        }
        var readAutomatic: (@Sendable () throws -> Bool)?
        if let automatic {
            readAutomatic = { @Sendable in automatic() }
        }
        var writeAutomatic: (@Sendable (Bool) throws -> Void)?
        if let setAutomatic { writeAutomatic = { @Sendable enabled in setAutomatic(enabled) } }
        return SystemDisplayAppearanceBindings(readDarkMode: read, writeDarkMode: write, readAutomatic: readAutomatic,
            writeAutomatic: writeAutomatic,
            hasWindowServerAccess: {
                var count: UInt32 = 0
                return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
            }, wait: { Thread.sleep(forTimeInterval: $0) })
    }
}
