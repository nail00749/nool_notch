import AppKit
import Carbon
import Combine

@MainActor
protocol WindowHotKeyRegistering: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    func register(_ shortcut: LauncherShortcut, id: UInt32) -> Bool
    func stop()
}

private func windowHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                 _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
          identifier.signature == 0x4E57494E else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<WindowHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { registrar.onPress?(identifier.id) }
    return noErr
}

@MainActor
final class WindowHotKeyRegistrar: WindowHotKeyRegistering {
    var onPress: ((UInt32) -> Void)?
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register(_ shortcut: LauncherShortcut, id: UInt32) -> Bool {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(GetApplicationEventTarget(), windowHotKeyHandler, 1, &type,
                                      Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        }
        var key: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                  EventHotKeyID(signature: 0x4E57494E, id: id), GetApplicationEventTarget(), 0, &key) == noErr,
              let key else { return false }
        keys.append(key)
        return true
    }

    func stop() {
        keys.forEach { UnregisterEventHotKey($0) }
        keys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

@MainActor
final class WindowShortcutController: ObservableObject {
    let settings: WindowShortcutSettings
    let launcherSettings: LauncherSettings
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var lastMessage: String?
    var onAccessRequired: (() -> Void)?
    private let manager: WindowLayoutManager
    private let modules: AppModuleStore
    private let registrar: any WindowHotKeyRegistering
    private var actions: [UInt32: WindowLayoutAction] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var operation: Task<Void, Never>?
    private var stopped = false

    init(manager: WindowLayoutManager, modules: AppModuleStore, launcherSettings: LauncherSettings,
         settings: WindowShortcutSettings = WindowShortcutSettings(),
         registrar: any WindowHotKeyRegistering = WindowHotKeyRegistrar()) {
        self.manager = manager
        self.modules = modules
        self.launcherSettings = launcherSettings
        self.settings = settings
        self.registrar = registrar
        settings.onChange = { [weak self] in self?.refresh() }
        registrar.onPress = { [weak self] id in self?.pressed(id) }
        modules.changes.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func refresh() {
        registrar.stop()
        actions.removeAll()
        errors = [:]
        guard !stopped, settings.enabled, modules.isEnabled(.windowManagement),
              settings.recordingAction == nil, !launcherSettings.isRecordingShortcut else {
            operation?.cancel()
            return
        }
        var registered: [LauncherShortcut] = []
        for (index, action) in WindowLayoutAction.allCases.enumerated() {
            guard let shortcut = settings.shortcut(for: action) else { continue }
            let id = UInt32(index + 1)
            if WindowShortcutSettings.matches(shortcut, launcherSettings.shortcut) {
                errors[action.rawValue] = "Совпадает с сочетанием Launcher."
            } else if registered.contains(where: { WindowShortcutSettings.matches($0, shortcut) }) {
                errors[action.rawValue] = "Совпадает с другим действием окна."
            } else if registrar.register(shortcut, id: id) {
                actions[id] = action
                registered.append(shortcut)
            } else {
                errors[action.rawValue] = "Сочетание занято или недоступно. Назначьте другое."
            }
        }
    }

    func stop() {
        stopped = true
        operation?.cancel()
        registrar.stop()
        actions.removeAll()
        subscriptions.removeAll()
    }

    func waitForOperation() async { await operation?.value }

    private func pressed(_ id: UInt32) {
        guard !stopped, settings.enabled, modules.isEnabled(.windowManagement),
              settings.recordingAction == nil, !launcherSettings.isRecordingShortcut,
              operation == nil, let action = actions[id] else { return }
        manager.refreshAccessibilityAccess()
        guard manager.hasAccessibilityAccess else {
            lastMessage = "Для управления окнами разрешите NooL App в «Универсальном доступе»."
            onAccessRequired?()
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        WindowFullscreenTransfer.trace("Shortcut: \(action.rawValue)")
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            guard !Task.isCancelled, self.settings.enabled, self.modules.isEnabled(.windowManagement),
                  self.settings.recordingAction == nil, !self.launcherSettings.isRecordingShortcut else { return }
            let message = await self.manager.perform(action, targetPID: pid)
            WindowFullscreenTransfer.trace("Shortcut result: \(message)")
            guard !Task.isCancelled else { return }
            self.lastMessage = message
        }
    }
}
