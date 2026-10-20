import AppKit
import Combine

/// Trash in the trailing section, as in the system Dock. Files move to Trash through
/// NSWorkspace (undoable in Finder); emptying is delegated to Finder after confirmation.
@MainActor
final class DockTrashModel: ObservableObject {
    @Published private(set) var isFull = false
    @Published private(set) var errorMessage: String?
    let trashURL: URL
    private let workspace: NSWorkspace
    private var refreshTask: Task<Void, Never>?

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        trashURL = (try? fileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    var icon: NSImage {
        NSImage(named: isFull ? NSImage.trashFullName : NSImage.trashEmptyName)
            ?? workspace.icon(forFile: trashURL.path)
    }

    /// Listing ~/.Trash may require Full Disk Access; without it the last known state stays.
    func refresh() {
        refreshTask?.cancel()
        let url = trashURL
        refreshTask = Task { [weak self] in
            let full = await Task.detached(priority: .utility) { Self.containsItems(url) }.value
            guard !Task.isCancelled, let self, let full else { return }
            if self.isFull != full { self.isFull = full }
        }
    }

    func open() {
        errorMessage = nil
        if !workspace.open(trashURL) { errorMessage = "Не удалось открыть Корзину." }
    }

    func moveToTrash(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        errorMessage = nil
        workspace.recycle(files) { [weak self] moved, error in
            let failed = error?.localizedDescription
            let anyMoved = !moved.isEmpty
            Task { @MainActor [weak self] in
                guard let self else { return }
                if anyMoved {
                    self.isFull = true
                    Self.play("dock/drag to trash.aif")
                }
                if let failed { self.errorMessage = failed }
            }
        }
    }

    /// Asks first, then lets Finder empty Trash with its own behaviour (locked items, progress).
    func emptyAfterConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Очистить Корзину?"
        alert.informativeText = "Объекты в Корзине будут удалены без возможности восстановления."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отменить")
        alert.alertStyle = .warning
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        errorMessage = nil
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) { Self.runFinderEmptyTrash() }.value
            guard let self else { return }
            if status == 0 { self.isFull = false }
            else { self.errorMessage = "Finder не очистил Корзину. Разрешите NooL управлять Finder в настройках Конфиденциальности." }
            self.refresh()
        }
    }

    /// System Dock sounds; missing files (older or trimmed systems) stay silent.
    static func play(_ name: String) {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/" + name
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    nonisolated static func containsItems(_ url: URL) -> Bool? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return names.contains { !$0.hasPrefix(".") }
    }

    private nonisolated static func runFinderEmptyTrash() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
