import AppKit
import Carbon

// Carbon delivers the handler on the application event loop. Its callback contains
// no captured Swift state; actor isolation is re-established before invoking UI work.
private func launcherHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == 0x4E4F4F4C else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<LauncherHotKey>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.onPress?() }
    return noErr
}

@MainActor
final class LauncherHotKey {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: LauncherShortcut?

    func register(_ shortcut: LauncherShortcut) -> String? {
        if registeredShortcut == shortcut, hotKey != nil { return nil }
        guard shortcut.isValid else { return "Добавьте ⌘, ⌥ или ⌃ к сочетанию клавиш." }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), launcherHotKeyHandler, 1, &type,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "Не удалось включить глобальную горячую клавишу." }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: 0x4E4F4F4C, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            return "Сочетание занято или недоступно. Выберите другое; панель можно открыть кнопкой ниже."
        }
        registeredShortcut = shortcut
        return nil
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        registeredShortcut = nil
    }
}
