import AppKit
import ApplicationServices

protocol YandexMusicQueueReading: Sendable {
    func read() async -> YandexMusicQueueState
    func openQueue() async -> YandexMusicQueueState
    func play(_ request: YandexMusicQueuePlayRequest) async -> YandexMusicQueuePlayResult
}

extension YandexMusicQueueReading {
    func play(_ request: YandexMusicQueuePlayRequest) async -> YandexMusicQueuePlayResult {
        .failed("Этот источник не поддерживает выбор трека в очереди.")
    }
}

struct YandexMusicQueueReader: YandexMusicQueueReading {
    static let bundleIdentifier = "ru.yandex.desktop.music"

    func read() async -> YandexMusicQueueState {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let pids = await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).filter { !$0.isTerminated }.prefix(3).map(\.processIdentifier) }
        guard !pids.isEmpty else { return .notRunning }
        let deadline = Date().addingTimeInterval(4)
        var lastFailure: YandexMusicQueueState?
        for pid in pids {
            guard !Task.isCancelled, Date() < deadline else { break }
            let result = await scan(pid: pid, open: false, deadline: deadline)
            if case .loaded = result { return result }
            if case .failed = result { lastFailure = result }
        }
        return lastFailure ?? .closed
    }

    func openQueue() async -> YandexMusicQueueState {
        // Only an explicit UI action enters this method; polling never activates the app.
        let pids = await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).filter { !$0.isTerminated }.prefix(3).map(\.processIdentifier) }
        guard !pids.isEmpty else {
            await MainActor.run {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
            }
            return .notRunning
        }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let deadline = Date().addingTimeInterval(4)
        var lastResult = YandexMusicQueueState.closed
        for pid in pids {
            guard !Task.isCancelled, Date() < deadline else { return .idle }
            let result = await scan(pid: pid, open: true, deadline: deadline)
            lastResult = result
            if case .failed = result { continue }
            guard !Task.isCancelled else { return .idle }
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first { $0.processIdentifier == pid }?.activate()
            }
            return result
        }
        await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first?.activate() }
        return lastResult
    }

    func play(_ request: YandexMusicQueuePlayRequest) async -> YandexMusicQueuePlayResult {
        guard YandexMusicQueuePlaybackGate.isEligible(request), let pid = request.selected.originPID else { return .queueChanged }
        guard AXIsProcessTrusted() else { return .failed("Разрешите доступ к Универсальному доступу для управления Яндекс Музыкой.") }
        let worker = Task.detached(priority: .utility) { () -> YandexMusicQueuePlayResult in
            do {
                let deadline = Date().addingTimeInterval(4)
                guard await Self.isRunning(pid: pid) else { return .queueChanged }
                try Task.checkCancellation()
                let first = YandexMusicQueueAXScanner(pid: pid, deadline: deadline)
                let firstRoot = try first.snapshot()
                let firstState = YandexMusicQueueParser.parse(firstRoot, partial: first.partial, originPID: pid)
                guard YandexMusicQueuePlaybackGate.matches(request, fresh: firstState, scanPartial: first.partial) else { return .queueChanged }
                // Resolve every handle anew. The second full snapshot catches queue
                // changes while the first read was in progress.
                let second = YandexMusicQueueAXScanner(pid: pid, deadline: deadline)
                let secondRoot = try second.snapshot()
                let fresh = YandexMusicQueueParser.parse(secondRoot, partial: second.partial, originPID: pid)
                guard YandexMusicQueuePlaybackGate.matches(request, fresh: fresh, scanPartial: second.partial),
                      await Self.isRunning(pid: pid) else { return .queueChanged }
                try Task.checkCancellation()
                return try second.play(request, fresh: fresh)
            } catch is CancellationError { return .queueChanged }
            catch { return .failed("Не удалось проверить очередь Яндекс Музыки. Обновите её и попробуйте снова.") }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func isRunning(pid: pid_t) async -> Bool {
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { $0.processIdentifier == pid && !$0.isTerminated }
        }
    }

    private func scan(pid: pid_t, open: Bool, deadline: Date) async -> YandexMusicQueueState {
        let worker = Task.detached(priority: .utility) { () -> YandexMusicQueueState in
            do {
                let scanner = YandexMusicQueueAXScanner(pid: pid, deadline: deadline)
                let root = try scanner.snapshot()
                let state = YandexMusicQueueParser.parse(root, partial: scanner.partial, originPID: pid)
                if !open, scanner.partial, state == .closed {
                    return .failed("Яндекс Музыка не успела показать очередь. Откройте её и нажмите «Обновить».")
                }
                if open, state == .closed {
                    guard !Task.isCancelled else { return .idle }
                    guard try scanner.pressQueueToggle() else {
                        return .failed("Откройте «Коллекция» в Яндекс Музыке, затем её очередь воспроизведения.")
                    }
                    // The app publishes the overlay asynchronously. The next regular
                    // read observes it; this action never retains a stale AX element.
                    return .closed
                }
                return state
            } catch is CancellationError { return .idle }
            catch { return .failed("Не удалось прочитать очередь Яндекс Музыки. Попробуйте обновить её.") }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

}

private final class YandexMusicQueueAXScanner {
    private let root: AXUIElement
    private let pid: pid_t
    private let deadline: Date
    private var count = 0
    private var visited = Set<AXUIElement>()
    private var queueToggle: AXUIElement?
    private var elementsByPath: [String: AXUIElement] = [:]
    private var playControls: [AXUIElement] = []
    private(set) var partial = false

    init(pid: pid_t, deadline: Date) {
        self.pid = pid
        self.deadline = deadline
        root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.075)
        // Electron's documented third-party accessibility contract exposes its
        // renderer tree. Never disable it: another accessibility client may use it.
        let attribute = "AXManualAccessibility" as CFString
        var existing: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, attribute, &existing)
        let alreadyEnabled = status == .success && existing.map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && CFBooleanGetValue(unsafeDowncast($0, to: CFBoolean.self))
        } == true
        if !alreadyEnabled { AXUIElementSetAttributeValue(root, attribute, kCFBooleanTrue) }
    }

    func snapshot() throws -> YandexMusicQueueNode {
        try node(root, depth: 0, path: "0")
    }

    func play(_ request: YandexMusicQueuePlayRequest, fresh: YandexMusicQueueState) throws -> YandexMusicQueuePlayResult {
        try Task.checkCancellation()
        guard Date() < deadline, let rowElement = elementsByPath[request.selected.id] else { return .queueChanged }
        let rowReader = YandexMusicQueueAXScanner(pid: pid, deadline: deadline)
        let row = try rowReader.node(rowElement, depth: 0, path: request.selected.id)
        let item = YandexMusicQueueParser.rowItem(row, id: request.selected.id, originPID: pid)
        guard !rowReader.partial, rowReader.playControls.count == 1, let button = rowReader.playControls.first else { return .queueChanged }
        let current = rowReader.attributes(button)
        guard !rowReader.partial, current.role == "AXButton", current.hasLabel("Воспроизведение") else { return .queueChanged }
        var buttonPID: pid_t = 0
        guard AXUIElementGetPid(button, &buttonPID) == .success, buttonPID == pid else { return .queueChanged }
        try Task.checkCancellation()
        guard Date() < deadline else { return .queueChanged }
        // AX offers no atomic read-and-press transaction. Rechecking the live row,
        // its one play control and the full queue limits the remaining race window.
        return YandexMusicQueuePlaybackGate.perform(request, fresh: fresh, scanPartial: partial,
                                                  row: item, playButtonCount: rowReader.playControls.count) {
            guard !Task.isCancelled, Date() < deadline else { return false }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }

    func pressQueueToggle() throws -> Bool {
        try Task.checkCancellation()
        guard Date() < deadline, let queueToggle else { return false }
        // Revalidate the live control immediately before pressing it.
        let attributes = attributes(queueToggle)
        guard attributes.hasLabel("Очередь воспроизведения"), attributes.value != "1" else { return false }
        return AXUIElementPerformAction(queueToggle, kAXPressAction as CFString) == .success
    }

    private func node(_ element: AXUIElement, depth: Int, path: String) throws -> YandexMusicQueueNode {
        try Task.checkCancellation()
        guard Date() < deadline, count < 6_000, depth < 35, visited.insert(element).inserted else {
            partial = true
            return .init()
        }
        count += 1
        elementsByPath[path] = element
        AXUIElementSetMessagingTimeout(element, 0.075)
        var result = attributes(element)
        if result.role == "AXButton", result.hasLabel("Воспроизведение") { playControls.append(element) }
        if (result.role == "AXButton" || result.role == "AXCheckBox"), result.hasLabel("Очередь воспроизведения") {
            queueToggle = element
        }
        guard Date() < deadline else { partial = true; return result }
        var children: [AXUIElement] = []
        var localVisited = Set<AXUIElement>()
        func appendChildren(attribute: CFString) {
            guard Date() < deadline else { partial = true; return }
            var childrenValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute, &childrenValue)
            if status == .cannotComplete { partial = true }
            guard let childrenValue, CFGetTypeID(childrenValue) == CFArrayGetTypeID() else { return }
            let array = unsafeDowncast(childrenValue, to: CFArray.self)
            let childCount = CFArrayGetCount(array)
            if childCount > 400 { partial = true }
            for index in 0..<min(childCount, 400) {
                let value = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFTypeRef.self)
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
                let child = unsafeDowncast(value, to: AXUIElement.self)
                if localVisited.insert(child).inserted { children.append(child) }
            }
        }
        // Electron's application AXChildren can contain only its menu bar. Windows
        // are exposed separately by the public AXWindows attribute. Read them first.
        if result.role == "AXApplication" { appendChildren(attribute: kAXWindowsAttribute as CFString) }
        appendChildren(attribute: kAXChildrenAttribute as CFString)
        for child in children {
            try Task.checkCancellation()
            guard Date() < deadline, count < 6_000 else { partial = true; break }
            guard !visited.contains(child) else { continue }
            result.children.append(try node(child, depth: depth + 1, path: "\(path).\(result.children.count)"))
        }
        return result
    }

    private func attributes(_ element: AXUIElement) -> YandexMusicQueueNode {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXURL"] as CFArray
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
        guard status == .success, let values else { partial = true; return .init() }
        func value(_ index: Int) -> CFTypeRef? {
            guard index < CFArrayGetCount(values) else { return nil }
            return unsafeBitCast(CFArrayGetValueAtIndex(values, index), to: CFTypeRef.self)
        }
        func string(_ index: Int) -> String {
            guard let value = value(index) else { return "" }
            if CFGetTypeID(value) == CFStringGetTypeID() { return value as! String }
            if CFGetTypeID(value) == CFNumberGetTypeID() { return (value as! NSNumber).stringValue }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)) ? "1" : "0" }
            return ""
        }
        var url: URL?
        if let value = value(4), CFGetTypeID(value) == CFURLGetTypeID() { url = (value as! URL) }
        else if !string(4).isEmpty { url = URL(string: string(4)) }
        else if string(0) == "AXLink", let value = value(3), CFGetTypeID(value) == CFURLGetTypeID() { url = (value as! URL) }
        else if string(0) == "AXLink", string(3).hasPrefix("music-application://") { url = URL(string: string(3)) }
        return .init(role: string(0), title: string(1), description: string(2), value: string(3), url: url)
    }
}
