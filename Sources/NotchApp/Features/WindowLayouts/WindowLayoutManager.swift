import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

private struct WindowLayoutApplication: Sendable {
    let pid: pid_t
    let bundleIdentifier: String
}

private struct WindowCaptureResult: Sendable {
    let windows: [SavedWindowPlacement]
    let skipped: Int
}

private struct WindowRestoreResult: Sendable {
    let restored: Int
    let unavailable: Int
    let unsupported: Int
}

@MainActor
final class WindowLayoutManager: ObservableObject {
    private static let defaultsKey = "nool.windowLayouts.v1"
    private static let maximumLayouts = 12
    private let defaults: UserDefaults
    private let worker = WindowLayoutAXWorker()

    @Published private(set) var layouts: [SavedWindowLayout]
    @Published private(set) var hasAccessibilityAccess: Bool
    @Published private(set) var isBusy = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedWindowLayout].self, from: $0) } ?? []
        layouts = Array(decoded.prefix(Self.maximumLayouts))
        hasAccessibilityAccess = AXIsProcessTrusted()
    }

    func refreshAccessibilityAccess() {
        hasAccessibilityAccess = AXIsProcessTrusted()
    }

    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refreshAccessibilityAccess()
    }

    func perform(_ action: WindowLayoutAction, targetPID: pid_t? = nil) async -> String {
        guard !isBusy else { return "Дождитесь завершения текущей операции с окнами." }
        isBusy = true
        defer { isBusy = false }
        refreshAccessibilityAccess()
        guard hasAccessibilityAccess else { return "Разрешите управление окнами в настройках Универсального доступа." }
        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
            return "Откройте окно другого приложения и повторите действие."
        }
        return await worker.perform(action, pid: pid, screens: Self.screens())
    }

    func saveLayout(name: String) async -> String {
        guard !isBusy else { return "Дождитесь завершения текущей операции с окнами." }
        isBusy = true
        defer { isBusy = false }
        refreshAccessibilityAccess()
        guard hasAccessibilityAccess else { return "Разрешите управление окнами в настройках Универсального доступа." }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 40,
              !cleanName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return "Введите название раскладки длиной от 1 до 40 символов."
        }
        let existingIndex = layouts.firstIndex {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }
        guard existingIndex != nil || layouts.count < Self.maximumLayouts else {
            return "Можно сохранить не более 12 раскладок. Удалите одну из старых."
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { app -> WindowLayoutApplication? in
                guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
                return WindowLayoutApplication(pid: app.processIdentifier,
                                               bundleIdentifier: bundleIdentifier)
            }
        let result = await worker.capture(applications: applications, screens: Self.screens())
        guard !result.windows.isEmpty else {
            return "Не нашлось доступных обычных окон для сохранения."
        }

        let layout = SavedWindowLayout(id: existingIndex.map { layouts[$0].id } ?? UUID(),
                                       name: cleanName, windows: result.windows)
        if let existingIndex {
            layouts[existingIndex] = layout
        } else {
            layouts.append(layout)
        }
        persist()
        let verb = existingIndex == nil ? "Сохранена" : "Обновлена"
        let skipped = result.skipped > 0 ? "; пропущено недоступных окон: \(result.skipped)" : ""
        return "\(verb) раскладка «\(cleanName)»: \(result.windows.count) окон\(skipped)."
    }

    func restoreLayout(id: UUID) async -> String {
        guard !isBusy else { return "Дождитесь завершения текущей операции с окнами." }
        isBusy = true
        defer { isBusy = false }
        refreshAccessibilityAccess()
        guard hasAccessibilityAccess else { return "Разрешите управление окнами в настройках Универсального доступа." }
        guard let layout = layouts.first(where: { $0.id == id }) else { return "Раскладка не найдена." }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { app -> WindowLayoutApplication? in
                guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
                return WindowLayoutApplication(pid: app.processIdentifier,
                                               bundleIdentifier: bundleIdentifier)
            }
        let result = await worker.restore(layout.windows, applications: applications,
                                          screens: Self.screens())
        return "Восстановлено окон: \(result.restored); не найдены: \(result.unavailable); недоступны: \(result.unsupported)."
    }

    func removeLayout(id: UUID) {
        guard !isBusy, layouts.contains(where: { $0.id == id }) else { return }
        layouts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func screens() -> [WindowLayoutScreen] {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == CGMainDisplayID()
        }) ?? screens.first else { return [] }
        let primaryTop = primary.frame.maxY
        return screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                             as? NSNumber)?.uint32Value
            let id: String
            if let displayID,
               let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else {
                id = "display-\(displayID ?? 0)"
            }
            func axRect(_ rect: NSRect) -> WindowLayoutRect {
                WindowLayoutRect(x: rect.minX, y: primaryTop - rect.maxY,
                                 width: rect.width, height: rect.height)
            }
            return WindowLayoutScreen(id: id, frame: axRect(screen.frame),
                                      visibleFrame: axRect(screen.visibleFrame))
        }
    }
}

/// Serial worker keeps synchronous AX messaging off the main actor.
private actor WindowLayoutAXWorker {
    private static let timeout: Float = 0.25
    private static let maximumApps = 64
    private static let maximumWindows = 120

    func perform(_ action: WindowLayoutAction, pid: pid_t,
                 screens: [WindowLayoutScreen]) -> String {
        guard !Task.isCancelled else { return "Операция отменена." }
        guard !screens.isEmpty else { return "Не найден доступный дисплей." }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        guard let window = Self.elementAttribute(application, kAXFocusedWindowAttribute)
                ?? Self.elementAttribute(application, kAXMainWindowAttribute) else {
            return "У приложения нет активного окна."
        }
        AXUIElementSetMessagingTimeout(window, Self.timeout)
        guard Self.isRegularWindow(window) else { return "Это окно нельзя переместить." }
        guard let current = Self.frame(of: window) else { return "Не удалось прочитать положение окна." }
        guard let target = WindowLayoutGeometry.target(for: action, current: current,
                                                       screens: screens) else {
            return action == .nextDisplay ? "Подключён только один дисплей." : "Не найден доступный дисплей."
        }
        let changeSize = action != .center
            || target.width != current.width || target.height != current.height
        guard Self.canMove(window, changeSize: changeSize) else {
            return "Окно не поддерживает изменение положения или размера."
        }
        return Self.apply(target, to: window, original: current,
                          changeSize: changeSize)
            ? "Окно: \(action.title.lowercased())."
            : "Приложение не разрешило изменить это окно."
    }

    func capture(applications: [WindowLayoutApplication],
                 screens: [WindowLayoutScreen]) -> WindowCaptureResult {
        guard !screens.isEmpty else { return WindowCaptureResult(windows: [], skipped: 0) }
        var placements: [SavedWindowPlacement] = []
        var skipped = max(0, applications.count - Self.maximumApps)
        for app in applications.prefix(Self.maximumApps) {
            if Task.isCancelled { break }
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, Self.timeout)
            for (ordinal, window) in Self.windows(of: application).enumerated() {
                if Task.isCancelled { break }
                if placements.count >= Self.maximumWindows { skipped += 1; continue }
                AXUIElementSetMessagingTimeout(window, Self.timeout)
                guard Self.isRegularWindow(window), Self.canMove(window, changeSize: true),
                      let frame = Self.frame(of: window), frame.isUsable,
                      let screen = WindowLayoutGeometry.screen(for: frame, in: screens) else {
                    skipped += 1
                    continue
                }
                placements.append(SavedWindowPlacement(
                    bundleIdentifier: app.bundleIdentifier,
                    windowTitle: Self.stringAttribute(window, kAXTitleAttribute) ?? "",
                    ordinal: ordinal,
                    displayID: screen.id,
                    normalizedFrame: WindowLayoutGeometry.normalize(frame, in: screen.visibleFrame)
                ))
            }
        }
        return WindowCaptureResult(windows: placements, skipped: skipped)
    }

    func restore(_ placements: [SavedWindowPlacement],
                 applications: [WindowLayoutApplication],
                 screens: [WindowLayoutScreen]) -> WindowRestoreResult {
        guard let fallbackScreen = screens.first else {
            return WindowRestoreResult(restored: 0, unavailable: placements.count, unsupported: 0)
        }
        var windowsByBundle: [String: [(pid: pid_t, ordinal: Int, element: AXUIElement, title: String)]] = [:]
        for app in applications.prefix(Self.maximumApps) {
            if Task.isCancelled { break }
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, Self.timeout)
            for (ordinal, window) in Self.windows(of: application).enumerated() {
                if Task.isCancelled { break }
                AXUIElementSetMessagingTimeout(window, Self.timeout)
                guard Self.isRegularWindow(window) else { continue }
                windowsByBundle[app.bundleIdentifier, default: []].append(
                    (app.pid, ordinal, window, Self.stringAttribute(window, kAXTitleAttribute) ?? "")
                )
            }
        }

        var used: Set<String> = []
        var restored = 0
        var unavailable = 0
        var unsupported = 0
        for placement in placements {
            if Task.isCancelled { break }
            guard let candidates = windowsByBundle[placement.bundleIdentifier] else {
                unavailable += 1
                continue
            }
            let candidate = candidates.first {
                !placement.windowTitle.isEmpty && $0.title == placement.windowTitle
                    && !used.contains("\($0.pid):\($0.ordinal)")
            } ?? candidates.first {
                $0.ordinal == placement.ordinal && !used.contains("\($0.pid):\($0.ordinal)")
            }
            guard let candidate else { unavailable += 1; continue }
            used.insert("\(candidate.pid):\(candidate.ordinal)")
            let destination = screens.first(where: { $0.id == placement.displayID }) ?? fallbackScreen
            let target = WindowLayoutGeometry.restore(placement.normalizedFrame,
                                                      to: destination.visibleFrame)
            guard Self.canMove(candidate.element, changeSize: true),
                  let original = Self.frame(of: candidate.element) else {
                unsupported += 1
                continue
            }
            if Self.apply(target, to: candidate.element, original: original, changeSize: true) {
                restored += 1
            } else {
                unsupported += 1
            }
        }
        return WindowRestoreResult(restored: restored, unavailable: unavailable,
                                   unsupported: unsupported)
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(application, kAXWindowsAttribute),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(raw, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            let rawElement = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFTypeRef.self)
            guard CFGetTypeID(rawElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(rawElement, to: AXUIElement.self)
        }
    }

    private static func isRegularWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(window, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        if let subrole = stringAttribute(window, kAXSubroleAttribute),
           subrole != kAXStandardWindowSubrole as String { return false }
        return boolAttribute(window, kAXMinimizedAttribute) != true
            && boolAttribute(window, "AXFullScreen") != true
    }

    private static func canMove(_ window: AXUIElement, changeSize: Bool) -> Bool {
        var positionSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString,
                                             &positionSettable) == .success,
              positionSettable.boolValue else { return false }
        guard changeSize else { return true }
        var sizeSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString,
                                              &sizeSettable) == .success && sizeSettable.boolValue
    }

    private static func frame(of window: AXUIElement) -> WindowLayoutRect? {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else {
            return nil
        }
        let result = WindowLayoutRect(x: point.x, y: point.y,
                                      width: dimensions.width, height: dimensions.height)
        return result.isUsable ? result : nil
    }

    private static func apply(_ target: WindowLayoutRect, to window: AXUIElement,
                              original: WindowLayoutRect, changeSize: Bool) -> Bool {
        guard target.isUsable else { return false }
        if changeSize {
            var size = CGSize(width: target.width, height: target.height)
            guard let value = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else {
                return false
            }
        }
        var position = CGPoint(x: target.x, y: target.y)
        guard let value = AXValueCreate(.cgPoint, &position),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success else {
            if changeSize {
                var previousSize = CGSize(width: original.width, height: original.height)
                if let previousValue = AXValueCreate(.cgSize, &previousSize) {
                    _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                                     previousValue)
                }
            }
            return false
        }
        return true
    }

    private static func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ key: String) -> Bool? {
        attribute(element, key) as? Bool
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
