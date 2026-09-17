import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import UniformTypeIdentifiers

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]) == .command,
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "v": editor.paste(nil)
            case "x": editor.cut(nil)
            case "z":
                if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
                else { editor.undoManager?.undo() }
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class LauncherWindowCoordinator: NSObject, NSWindowDelegate {
    let settings: LauncherSettings
    let model: LauncherModel
    var onOpenSettings: (() -> Void)?
    private let hotKey = LauncherHotKey()
    private let panel: LauncherPanel
    private var previousApplication: NSRunningApplication?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var pasteTask: Task<Void, Never>?
    private var isChoosingAttachments = false

    override init() {
        let settings = LauncherSettings()
        self.settings = settings
        model = LauncherModel(settings: settings)
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 492),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Nool Launcher"
        panel.identifier = NSUserInterfaceItemIdentifier("nool.launcher")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        let hosting = NSHostingView(rootView: LauncherView(
            model: model,
            activate: { [weak self] result, paste in self?.activate(result, paste: paste) },
            reveal: { [weak self] result in self?.reveal(result) },
            close: { [weak self] in self?.hide(restoreFocus: true) },
            openSettings: { [weak self] in self?.showSettings() },
            focusInput: { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.focusSearch()
                }
            },
            requestSelectionAccess: { [weak self] in self?.requestSelectionAccess() },
            pasteAIResponse: { [weak self] text in self?.pasteAIResponse(text) },
            chooseAttachments: { [weak self] in self?.chooseAttachments() }
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        hotKey.onPress = { [weak self] in
            guard let self, !self.settings.isRecordingShortcut else { return }
            self.toggle()
        }
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.position()
            }
        }
    }

    func toggle() {
        guard !isChoosingAttachments else { return }
        if panel.isVisible { hide(restoreFocus: true) } else { show() }
    }

    func show() {
        pasteTask?.cancel()
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            focusSearch()
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        previousApplication = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
        model.textSelection.capture(pid: previousApplication?.processIdentifier)
        model.present()
        position()
        panel.makeKeyAndOrderFront(nil)
        focusSearch()
        installDismissMonitors()
    }

    func stop() {
        pasteTask?.cancel()
        hide(restoreFocus: false)
        hotKey.stop()
        model.clipboard.stop()
        model.aiChat.shutdown()
        model.textSelection.clear()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isChoosingAttachments, !hasVisibleChildWindow else { return }
        hide(restoreFocus: false)
    }

    private func chooseAttachments() {
        guard !isChoosingAttachments, !model.aiChat.isStreaming else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = AIChatAttachmentLoader.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        picker.message = "До 4 файлов: изображения, текстовые документы или PDF с текстом."
        picker.prompt = "Прикрепить"
        isChoosingAttachments = true
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.isChoosingAttachments = false
            if response == .OK { self.model.aiChat.importAttachments(picker.urls) }
            self.panel.makeKeyAndOrderFront(nil)
            self.focusSearch()
        }
    }

    private func applySettings() {
        if settings.isRecordingShortcut {
            hotKey.stop()
        } else {
            settings.hotKeyError = hotKey.register(settings.shortcut)
        }
        model.settingsChanged()
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let width = min(680, bounds.width)
        let height = min(492, bounds.height)
        let frame = NSRect(x: bounds.midX - width / 2,
                           y: max(bounds.minY, min(bounds.maxY - height, bounds.midY - height / 2 + bounds.height * 0.1)),
                           width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    private func focusSearch() {
        let identifier = model.category == .ai ? "nool.launcher.chat-composer" : "nool.launcher.search"
        func search(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let field = search(in: content) { panel.makeFirstResponder(field) }
    }

    private func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        removeDismissMonitors()
        panel.orderOut(nil)
        model.dismiss()
        if restoreFocus, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
    }

    private func showSettings() {
        hide(restoreFocus: false)
        onOpenSettings?()
    }

    private func requestSelectionAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        model.textSelection.capture(pid: previousApplication?.processIdentifier)
    }

    private func pasteAIResponse(_ text: String) {
        guard let destination = previousApplication, !destination.isTerminated,
              let expected = model.textSelection.text else { return }
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            let sameSelection = await self.model.textSelection.stillMatches(pid: destination.processIdentifier, expected: expected)
            guard !Task.isCancelled else { return }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { return }
            guard sameSelection else {
                self.model.aiChat.errorMessage = "Выделение изменилось. Ответ скопирован — вставьте его вручную."
                return
            }
            self.pasteIntoPreviousApplication(expectedSelection: expected)
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    guard event.window === self.panel else { return event }
                    if event.keyCode == UInt16(kVK_Escape), self.model.selectedNoolEvent != nil {
                        self.model.selectedNoolEvent = nil
                        self.focusSearch()
                        return nil
                    }
                    if let action = LauncherKeyboardShortcuts.tabAction(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                        switch action {
                        case .select(let category): self.model.category = category
                        case .cycle(let backwards): self.model.cycleCategory(backwards: backwards)
                        }
                        return nil
                    }
                    if self.model.category != .ai, event.keyCode == UInt16(kVK_Return), event.modifierFlags.contains(.command),
                       let result = self.model.selectedResult {
                        self.activate(result, paste: true)
                        return nil
                    }
                } else if event.window !== self.panel, !self.hasVisibleChildWindow {
                    self.hide(restoreFocus: false)
                }
                return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasVisibleChildWindow else { return }
                self.hide(restoreFocus: false)
            }
        }
    }

    private var hasVisibleChildWindow: Bool { panel.childWindows?.contains(where: \.isVisible) == true }

    private func removeDismissMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func activate(_ result: LauncherResult, paste: Bool) {
        guard model.results.contains(result) else { return }
        switch result.payload {
        case .nool(let id, _):
            if model.openNoolResult(id) { hide(restoreFocus: false) }
        case .application(let url):
            hide(restoreFocus: false)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    self?.show()
                    self?.model.message = "Не удалось открыть приложение. Возможно, оно было перемещено."
                }
            }
        case .file(let url):
            if NSWorkspace.shared.open(url) { hide(restoreFocus: false) }
            else { model.message = "Не удалось открыть файл. Проверьте, что он доступен." }
        case .calculation(let value):
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) { model.message = "Результат скопирован" }
            else { model.message = "Не удалось скопировать результат." }
        case .clipboard(let id):
            guard model.clipboard.copy(id) else {
                model.message = "Запись больше недоступна или не удалось скопировать её."
                return
            }
            if paste { pasteIntoPreviousApplication() }
            else { model.message = "Скопировано · ⌘ Enter — вставить в предыдущее приложение" }
        }
    }

    private func reveal(_ result: LauncherResult) {
        guard model.results.contains(result) else { return }
        switch result.payload {
        case .application(let url), .file(let url):
            hide(restoreFocus: false)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default: break
        }
    }

    private func pasteIntoPreviousApplication(expectedSelection: String? = nil) {
        guard let destination = previousApplication, !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            model.message = "Скопировано. Перейдите в нужное приложение и нажмите ⌘V."
            return
        }
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            model.message = "Скопировано. Для автоматической вставки разрешите Nool в «Универсальный доступ» и повторите действие."
            return
        }
        hide(restoreFocus: true)
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            for _ in 0..<12 {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self, !self.panel.isVisible, !destination.isTerminated else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier {
                    if let expectedSelection {
                        let matches = await self.model.textSelection.stillMatches(pid: destination.processIdentifier, expected: expectedSelection)
                        guard !Task.isCancelled, !self.panel.isVisible else { return }
                        guard matches, NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
                            self.show()
                            self.model.aiChat.errorMessage = "Выделение или активное приложение изменилось. Ответ скопирован — вставьте его вручную."
                            return
                        }
                    }
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.postToPid(destination.processIdentifier)
                    up.postToPid(destination.processIdentifier)
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.show()
            self.model.message = "Скопировано, но приложение не получило фокус. Вставьте запись с помощью ⌘V."
        }
    }
}
