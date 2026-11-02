import AppKit
import ApplicationServices

enum FinderConversionModifier: String, CaseIterable, Identifiable, Sendable {
    case command, option, control
    var id: String { rawValue }
    var title: String {
        switch self {
        case .command: "Command ⌘"
        case .option: "Option ⌥"
        case .control: "Control ⌃"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        }
    }
}

/// Pure gesture policy. A shortcut or mouse click consumes the current hold, so
/// Command-click selection and Command-C never turn into a conversion gesture.
struct FinderConversionHoldState {
    var delay: TimeInterval = 0.45
    private var startedAt: TimeInterval?
    private var origin: CGPoint?
    private var consumed = false

    mutating func reset() { startedAt = nil; origin = nil; consumed = false }
    mutating func consume() { consumed = true; startedAt = nil; origin = nil }

    mutating func update(time: TimeInterval, pointer: CGPoint, isFinder: Bool,
                         modifierHeld: Bool, hasOtherModifier: Bool, mouseDown: Bool) -> Bool {
        guard modifierHeld else { reset(); return false }
        guard isFinder, !hasOtherModifier, !mouseDown else { consume(); return false }
        guard !consumed else { return false }
        if let origin, hypot(pointer.x - origin.x, pointer.y - origin.y) > 5 {
            self.origin = pointer
            startedAt = time
            return false
        }
        guard let startedAt else {
            self.startedAt = time
            origin = pointer
            return false
        }
        guard time - startedAt >= delay else { return false }
        consume()
        return true
    }
}

/// Only observes input. It never swallows events, changes Finder selection, or
/// requests Accessibility/Automation access as a side effect of a modifier key.
@MainActor
final class FinderConversionInput {
    var onSelection: (([URL], CGPoint) -> Void)?
    var onDismiss: (() -> Void)?
    var onError: ((String) -> Void)?
    var modifier: FinderConversionModifier {
        didSet { if modifier != oldValue { invalidate(); hold.reset() } }
    }

    private var hold = FinderConversionHoldState()
    private var poll: Task<Void, Never>?
    private var lookup: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var generation = UUID()
    private var opened = false
    private let reader = FinderConversionSelectionReader()

    init(modifier: FinderConversionModifier = .command) { self.modifier = modifier }

    func start() {
        guard poll == nil else { return }
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        installGlobalMonitorIfTrusted()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            // App-local mouse events belong to the radial menu. Root handles its
            // buttons/outside click; they must not close it before selection.
            if event.type == .keyDown { self?.inputOccurred(isKey: true) }
            return event
        }
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        invalidate(); hold.reset()
    }

    private func inputOccurred(isKey: Bool) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        if NSEvent.modifierFlags.contains(modifier.flags) {
            hold.consume()
            generation = UUID(); lookup?.cancel(); lookup = nil
        }
        if isKey, opened { opened = false; onDismiss?() }
    }

    private func sample() {
        let application = NSWorkspace.shared.frontmostApplication
        let isFinder = application?.bundleIdentifier == "com.apple.finder"
        // Nonactivating conversion panel keeps Finder frontmost. A real app
        // switch cancels pending lookup and closes any existing surface.
        if !isFinder { invalidate(); hold.consume(); return }
        // Access may have been granted after startup. Reattempt a failed monitor
        // registration so shortcuts are still excluded without an app restart.
        installGlobalMonitorIfTrusted()
        let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let held = flags.contains(modifier.flags)
        if !held, lookup != nil { generation = UUID(); lookup?.cancel(); lookup = nil }
        guard hold.update(time: ProcessInfo.processInfo.systemUptime, pointer: NSEvent.mouseLocation,
                          isFinder: isFinder, modifierHeld: held,
                          hasOtherModifier: !flags.subtracting(modifier.flags).isEmpty,
                          mouseDown: NSEvent.pressedMouseButtons != 0), let application else { return }
        guard AXIsProcessTrusted() else {
            opened = true
            onError?("Разрешите Универсальный доступ в настройках конвертации файлов.")
            return
        }
        let pointer = NSEvent.mouseLocation
        // AX global coordinates start at the primary display's top left.
        let axPoint = CGPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - pointer.y)
        let token = UUID(); generation = token
        let pid = application.processIdentifier
        lookup = Task { [weak self, reader] in
            let result = await reader.selection(pid: pid, point: axPoint)
            guard let self, !Task.isCancelled, self.generation == token,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function]) == self.modifier.flags,
                  NSEvent.pressedMouseButtons == 0,
                  hypot(NSEvent.mouseLocation.x - pointer.x, NSEvent.mouseLocation.y - pointer.y) <= 8 else { return }
            self.lookup = nil
            if let urls = result.urls, !urls.isEmpty {
                self.opened = true
                self.onSelection?(urls, pointer)
            } else if result.unsupportedSelection {
                self.opened = true
                self.onError?("Finder не предоставил адрес выбранного файла через Универсальный доступ. Попробуйте другой режим отображения Finder.")
            }
        }
    }

    private func installGlobalMonitorIfTrusted() {
        guard globalMonitor == nil, AXIsProcessTrusted() else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let isKey = event.type == .keyDown
            Task { @MainActor in self?.inputOccurred(isKey: isKey) }
        }
    }

    private func invalidate() {
        generation = UUID(); lookup?.cancel(); lookup = nil
        if opened { opened = false; onDismiss?() }
    }
}

/// AX references never leave this worker. Selection is accepted only when the
/// hit-tested element belongs to Finder and is the selected item (or its child).
private actor FinderConversionSelectionReader {
    struct Result: Sendable {
        var urls: [URL]?
        var unsupportedSelection = false
    }
    private var deadline: TimeInterval = 0

    func selection(pid: pid_t, point: CGPoint) -> Result {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return .init() }
        deadline = ProcessInfo.processInfo.systemUptime + 1.5
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return .init() }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else { return .init() }
        var chain = [hit]
        for _ in 0..<12 {
            guard let parent = element(chain.last!, kAXParentAttribute),
                  !chain.contains(where: { CFEqual($0, parent) }) else { break }
            chain.append(parent)
        }
        for ancestor in chain {
            guard active else { return .init() }
            let selected = elements(ancestor, kAXSelectedChildrenAttribute)
            guard !selected.isEmpty, selected.count <= 64 else { continue }
            // Equality with a hit ancestor proves pointer membership without a
            // fragile filename/title comparison across duplicate Finder rows.
            guard selected.contains(where: { item in chain.contains(where: { CFEqual(item, $0) }) }) else { continue }
            var urls: [URL] = []
            for item in selected {
                guard let url = uniqueFileURL(item), active else { return .init(unsupportedSelection: true) }
                urls.append(url)
            }
            return .init(urls: FinderConversionSelectionMatching.validated(urls: urls))
        }
        // Icon views can mark individual AXImage elements selected while the
        // group's selected-children attribute is absent. Never silently convert
        // just one item: enumerate selected siblings and require exact membership.
        for item in chain where attribute(item, kAXSelectedAttribute) as? Bool == true {
            guard let parent = element(item, kAXParentAttribute) else { continue }
            let siblings = elements(parent, kAXChildrenAttribute)
            guard siblings.count <= 512 else { return .init(unsupportedSelection: true) }
            let selected = siblings.filter { attribute($0, kAXSelectedAttribute) as? Bool == true }
            guard !selected.isEmpty, selected.count <= 64 else { return .init(unsupportedSelection: true) }
            var urls: [URL] = []
            for selectedItem in selected {
                guard let url = uniqueFileURL(selectedItem), active else { return .init(unsupportedSelection: true) }
                urls.append(url)
            }
            return .init(urls: FinderConversionSelectionMatching.validated(urls: urls))
        }
        return .init()
    }

    private var active: Bool { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }

    private func uniqueFileURL(_ element: AXUIElement) -> URL? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var urls = Set<URL>()
        var count = 0
        while !queue.isEmpty, active, count < 40 {
            let (node, depth) = queue.removeFirst(); count += 1
            if let raw = attribute(node, kAXURLAttribute),
               let url = FinderConversionSelectionMatching.fileURL(raw) { urls.insert(url) }
            if depth < 3 { queue += elements(node, kAXChildrenAttribute).prefix(24).map { ($0, depth + 1) } }
        }
        guard queue.isEmpty, urls.count == 1 else { return nil }
        return urls.first
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard active else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.12)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(source, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func elements(_ source: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(source, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return value as! [AXUIElement]
    }
}

enum FinderConversionSelectionMatching {
    static func fileURL(_ value: Any) -> URL? {
        let url: URL?
        if let value = value as? URL { url = value }
        else if let value = value as? String { url = URL(string: value) }
        else { url = nil }
        guard let url, url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.isEmpty, url.path.hasPrefix("/") else { return nil }
        return url.standardizedFileURL
    }

    static func validated(urls: [URL]) -> [URL]? {
        guard !urls.isEmpty, urls.count <= 64 else { return nil }
        let normalized = urls.compactMap(fileURL)
        guard normalized.count == urls.count else { return nil }
        var seen = Set<URL>()
        return normalized.filter { seen.insert($0).inserted }
    }
}
