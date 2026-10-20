import AppKit
import Combine

/// "Открывать при входе" for other applications. macOS has no public API to manage
/// another app's login item, so System Events does it on explicit user action only;
/// the list is never queried before the user first uses the menu item.
@MainActor
final class DockLoginItems: ObservableObject {
    static let usedKey = "nool.dock.loginItemsUsed"
    @Published private(set) var paths: Set<String> = []
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private let runner: @Sendable ([String]) -> (status: Int32, output: String)
    private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         runner: @escaping @Sendable ([String]) -> (status: Int32, output: String) = DockLoginItems.runAppleScript) {
        self.defaults = defaults
        self.runner = runner
    }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Refreshes the cached state for menu checkmarks once the user has used the feature.
    func refreshIfUsed() {
        guard defaults.bool(forKey: Self.usedKey), refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.reload()
            self?.refreshTask = nil
        }
    }

    /// Reads the current list first, so a stale checkmark never inverts the user's intent.
    func toggle(path: String) {
        guard path.hasPrefix("/") else { return }
        defaults.set(true, forKey: Self.usedKey)
        errorMessage = nil
        let runner = runner
        Task { [weak self] in
            let current = await Task.detached(priority: .userInitiated) { runner(Self.listScript) }.value
            guard let self else { return }
            guard current.status == 0 else { self.fail(); return }
            let enabled = Self.parse(current.output).contains(path)
            let script = enabled ? Self.removeScript : Self.addScript
            let result = await Task.detached(priority: .userInitiated) { runner(script + [path]) }.value
            if result.status != 0 { self.fail() }
            await self.reload()
        }
    }

    private func reload() async {
        let runner = runner
        let result = await Task.detached(priority: .utility) { runner(Self.listScript) }.value
        guard result.status == 0 else { return }
        let parsed = Self.parse(result.output)
        if parsed != paths { paths = parsed }
    }

    private func fail() {
        errorMessage = "Не удалось изменить объекты входа. Разрешите NooL управлять «System Events» в настройках Конфиденциальности."
    }

    nonisolated static func parse(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).map {
            let path = String($0).trimmingCharacters(in: .whitespaces)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }.filter { $0.hasPrefix("/") })
    }

    // The path is passed as an argument, never interpolated into the script source.
    nonisolated static let listScript = [
        "-e", "tell application \"System Events\"",
        "-e", "set output to \"\"",
        "-e", "repeat with itemPath in (get path of every login item)",
        "-e", "set output to output & itemPath & linefeed",
        "-e", "end repeat",
        "-e", "return output",
        "-e", "end tell",
    ]
    nonisolated static let addScript = [
        "-e", "on run argv",
        "-e", "tell application \"System Events\" to make login item at end with properties {path:(item 1 of argv), hidden:false}",
        "-e", "end run",
    ]
    nonisolated static let removeScript = [
        "-e", "on run argv",
        "-e", "tell application \"System Events\" to delete (every login item whose path is (item 1 of argv))",
        "-e", "end run",
    ]

    nonisolated static func runAppleScript(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data.prefix(1_000_000), as: UTF8.self))
    }
}
