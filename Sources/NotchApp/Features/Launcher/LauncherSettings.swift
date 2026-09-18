import AppKit
import Carbon
import Combine

struct LauncherShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let standard = LauncherShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyLabel: "Space")

    var isValid: Bool {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return keyCode < 128 && modifiers & ~allowed == 0
            && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
            && !keyLabel.isEmpty && keyLabel.count <= 20
    }

    var title: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + " " + keyLabel
    }

    static func from(_ event: NSEvent) -> LauncherShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Space"
        case kVK_Return: label = "Return"
        case kVK_Tab: label = "Tab"
        case kVK_Delete: label = "Delete"
        default: label = event.charactersIgnoringModifiers?.uppercased() ?? ""
        }
        let shortcut = LauncherShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
}

@MainActor
final class LauncherSettings: ObservableObject {
    @Published var shortcut: LauncherShortcut { didSet { save() } }
    @Published var clipboardEnabled: Bool { didSet { save() } }
    @Published var clipboardLimit: Int { didSet { save() } }
    @Published var retentionDays: Int { didSet { save() } }
    @Published var folderPaths: [String] { didSet { save() } }
    @Published var hotKeyError: String?
    @Published var isRecordingShortcut = false { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private static let prefix = "nool.launcher."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.prefix + "shortcut"),
           let saved = try? JSONDecoder().decode(LauncherShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else {
            shortcut = .standard
        }
        clipboardEnabled = defaults.bool(forKey: Self.prefix + "clipboardEnabled")
        let limit = defaults.object(forKey: Self.prefix + "clipboardLimit") as? Int ?? 100
        clipboardLimit = min(max(limit, 10), 500)
        let days = defaults.object(forKey: Self.prefix + "retentionDays") as? Int ?? 7
        retentionDays = min(max(days, 1), 30)
        folderPaths = defaults.stringArray(forKey: Self.prefix + "folders") ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        ]
    }

    var folders: [URL] {
        Array(Set(folderPaths.filter { $0.hasPrefix("/") })).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func addFolders(_ urls: [URL]) {
        folderPaths = Array(Set(folderPaths + urls.filter(\.isFileURL).map(\.standardizedFileURL.path))).sorted()
    }

    private func save() {
        if shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.prefix + "shortcut")
        }
        defaults.set(clipboardEnabled, forKey: Self.prefix + "clipboardEnabled")
        defaults.set(min(max(clipboardLimit, 10), 500), forKey: Self.prefix + "clipboardLimit")
        defaults.set(min(max(retentionDays, 1), 30), forKey: Self.prefix + "retentionDays")
        defaults.set(folderPaths, forKey: Self.prefix + "folders")
        onChange?()
    }
}
