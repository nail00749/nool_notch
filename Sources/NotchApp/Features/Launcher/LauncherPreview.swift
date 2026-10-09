import AppKit
import QuickLookUI

enum LauncherPreviewPreflight: Equatable, Sendable {
    case ready
    case notAFile
    case unavailable

    static func check(_ url: URL) async -> Self {
        guard url.isFileURL else { return .notAFile }
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return Self.unavailable }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                guard values.isRegularFile == true else { return Self.notAFile }
                guard values.isReadable == true else { return Self.unavailable }
                return .ready
            } catch {
                return .unavailable
            }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}

enum LauncherPreviewKeyboardPolicy {
    static func canUseSpace(selected: LauncherResult?, navigatedID: String?, category: LauncherCategory,
                            hasDetail: Bool) -> Bool {
        guard category != .ai, !hasDetail, let selected, selected.id == navigatedID,
              case .file = selected.payload else { return false }
        return true
    }
}

struct LauncherPreviewRequestState {
    private(set) var generation = 0

    mutating func begin() -> Int { generation += 1; return generation }
    mutating func invalidate() { generation += 1 }
    func accepts(_ token: Int) -> Bool { token == generation }
}

@MainActor
final class LauncherPreviewFileAccess {
    private let url: URL
    private let stop: (URL) -> Void
    private var scoped: Bool

    init(url: URL, start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stop = stop
        scoped = start(url)
    }

    func release() {
        guard scoped else { return }
        scoped = false
        stop(url)
    }
}

private final class LauncherPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the Quick Look view and its file access for exactly one visible preview.
@MainActor
final class LauncherPreviewController: NSObject, NSWindowDelegate {
    private let preflight: @Sendable (URL) async -> LauncherPreviewPreflight
    private let makeAccess: @MainActor (URL) -> LauncherPreviewFileAccess
    private(set) var resultID: String?
    private(set) var panel: NSPanel?
    private var previewView: QLPreviewView?
    private var parent: NSWindow?
    private var access: LauncherPreviewFileAccess?
    private(set) var preflightTask: Task<Void, Never>?
    private var requestState = LauncherPreviewRequestState()
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    init(preflight: @escaping @Sendable (URL) async -> LauncherPreviewPreflight = LauncherPreviewPreflight.check,
         makeAccess: @escaping @MainActor (URL) -> LauncherPreviewFileAccess = { LauncherPreviewFileAccess(url: $0) }) {
        self.preflight = preflight
        self.makeAccess = makeAccess
        super.init()
    }

    func present(url: URL, resultID: String, parent: NSWindow) {
        cancel(restoreFocus: false)
        self.resultID = resultID
        self.parent = parent
        access = makeAccess(url)
        let currentGeneration = requestState.begin()
        preflightTask = Task { [weak self] in
            let verdict = await self?.preflight(url) ?? .unavailable
            guard let self, !Task.isCancelled, self.requestState.accepts(currentGeneration),
                  self.resultID == resultID, parent.isVisible else { return }
            self.preflightTask = nil
            switch verdict {
            case .ready:
                self.showPreview(url: url, parent: parent)
            case .notAFile:
                self.cancel(restoreFocus: true)
                self.onError?("Быстрый просмотр доступен только для локальных файлов.")
            case .unavailable:
                self.cancel(restoreFocus: true)
                self.onError?("Файл недоступен для быстрого просмотра.")
            }
        }
    }

    func cancel(restoreFocus: Bool) {
        requestState.invalidate()
        preflightTask?.cancel()
        preflightTask = nil
        if let panel, let parent { parent.removeChildWindow(panel) }
        previewView?.close()
        previewView = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        access?.release()
        access = nil
        resultID = nil
        let parent = self.parent
        self.parent = nil
        if restoreFocus, let parent, parent.isVisible {
            parent.makeKeyAndOrderFront(nil)
            onClose?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancel(restoreFocus: true)
    }

    private func showPreview(url: URL, parent: NSWindow) {
        let width: CGFloat = 600
        let height: CGFloat = 460
        let available = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let rightX = parent.frame.maxX + 12
        let leftX = parent.frame.minX - width - 12
        let x = rightX + width <= available.maxX ? rightX
            : (leftX >= available.minX ? leftX : available.midX - width / 2)
        let frame = NSRect(x: min(max(x, available.minX), max(available.minX, available.maxX - width)),
                           y: min(max(parent.frame.midY - height / 2, available.minY),
                                  max(available.minY, available.maxY - height)),
                           width: min(width, available.width), height: min(height, available.height))
        let panel = LauncherPreviewPanel(contentRect: frame,
                                         styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.identifier = NSUserInterfaceItemIdentifier("nool.launcher.quick-look")
        panel.level = parent.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 260)
        guard let view = QLPreviewView(frame: NSRect(origin: .zero, size: frame.size), style: .normal) else {
            cancel(restoreFocus: true)
            onError?("Не удалось запустить быстрый просмотр файла.")
            return
        }
        view.autoresizingMask = [.width, .height]
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        panel.contentView = view
        panel.delegate = self
        self.panel = panel
        previewView = view
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }
}
