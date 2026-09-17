import AppKit
import ApplicationServices
import Combine

enum LauncherTextAction: String, CaseIterable, Identifiable {
    case translate, shorten, explain, correct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translate: "Перевести на русский"
        case .shorten: "Сократить"
        case .explain: "Объяснить"
        case .correct: "Исправить текст"
        }
    }
    func prompt(_ text: String) -> String {
        let instruction: String
        switch self {
        case .translate: instruction = "Переведи текст на русский язык. Верни только перевод."
        case .shorten: instruction = "Сократи текст, сохранив смысл. Верни только сокращённый текст."
        case .explain: instruction = "Объясни простыми словами, что означает этот текст."
        case .correct: instruction = "Исправь ошибки и улучши ясность текста, сохранив смысл и язык. Верни только исправленный текст."
        }
        return "\(instruction)\n\nТекст для обработки:\n\(text)"
    }
}

/// AX objects are immutable references; all AX access occurs in bounded background reads.
struct LauncherSelectionTarget: Equatable, @unchecked Sendable {
    let element: AXUIElement
    let range: CFRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element) && lhs.range.location == rhs.range.location
            && lhs.range.length == rhs.range.length
    }
}

enum LauncherSelectionRead: Equatable, Sendable {
    case text(String, target: LauncherSelectionTarget), empty, protectedField, tooLong
}

@MainActor
final class LauncherTextSelection: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var message = "Выделите текст в приложении и откройте Launcher."
    @Published private(set) var needsPermission = false
    @Published private(set) var isReading = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var target: LauncherSelectionTarget?
    private let isTrusted: () -> Bool
    private let read: @Sendable (pid_t) -> LauncherSelectionRead

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         read: @escaping @Sendable (pid_t) -> LauncherSelectionRead = LauncherTextSelection.readSelection) {
        self.isTrusted = isTrusted
        self.read = read
    }

    func capture(pid: pid_t?) {
        clear()
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard isTrusted() else {
            needsPermission = true
            message = "Для чтения выделения разрешите Nool в «Универсальный доступ», затем откройте Launcher снова."
            return
        }
        isReading = true
        let token = generation
        let read = read
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { read(pid) }.value
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.isReading = false
            switch result {
            case .text(let value, let target):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                guard value.utf16.count <= 7_000 else { self.message = "Выделение слишком длинное. Выберите до 7 000 символов."; return }
                self.text = value
                self.target = target
                self.message = "Выделено \(value.count) символов"
            case .protectedField: self.message = "Защищённые поля не читаются."
            case .tooLong: self.message = "Выделение слишком длинное. Выберите до 7 000 символов."
            case .empty: break
            }
        }
    }

    func stillMatches(pid: pid_t, expected: String) async -> Bool {
        guard isTrusted(), let target else { return false }
        let read = read
        return await Task.detached(priority: .userInitiated) { read(pid) == .text(expected, target: target) }.value
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        text = nil
        target = nil
        isReading = false
        needsPermission = false
        message = "Выделите текст в приложении и откройте Launcher."
    }

    nonisolated static func readSelection(pid: pid_t) -> LauncherSelectionRead {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .empty }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if subrole as? String == "AXSecureTextField" { return .protectedField }
        var protected: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected)
        if protected as? Bool == true { return .protectedField }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .empty }
        var range = CFRange()
        let value = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0 else { return .empty }
        if range.length > 7_000 { return .tooLong }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return .empty }
        return text.utf16.count <= 7_000 ? .text(text, target: LauncherSelectionTarget(element: element, range: range)) : .tooLong
    }
}
