import AppKit
import ApplicationServices
import Combine

/// AXUIElement is a thread-safe CF reference; the wrapper only moves it between actors.
struct DockAXElement: @unchecked Sendable {
    let element: AXUIElement
}

struct DockMinimizedWindow: Identifiable, Sendable {
    let id: String
    let pid: Int32
    let applicationPath: String
    let title: String
    let window: DockAXElement
}

/// The system Dock's Handoff tile: an activity advertised by a nearby iPhone, iPad or Mac.
struct DockHandoffItem: Equatable, Sendable {
    let title: String
    /// Model identifier from AXStatusLabel, e.g. "com.apple.iphone-15-pro-max-1".
    let deviceIdentifier: String
    /// Installed application matching `title`, when one is found, for the icon.
    let applicationPath: String?
    let element: DockAXElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.deviceIdentifier == rhs.deviceIdentifier
            && lhs.applicationPath == rhs.applicationPath
    }

    /// "com.apple.iphone-15-pro-max-1" → "iPhone 15 Pro Max"; nil when nothing readable remains.
    var deviceName: String? { Self.deviceName(from: deviceIdentifier) }

    static func deviceName(from identifier: String) -> String? {
        var raw = identifier
        if raw.hasPrefix("com.apple.") { raw.removeFirst("com.apple.".count) }
        var tokens = raw.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        // A trailing number after another one is a colour/variant index, not part of the model.
        if tokens.count > 1, tokens.last?.allSatisfy(\.isNumber) == true,
           tokens.dropLast().contains(where: { $0.allSatisfy(\.isNumber) }) {
            tokens.removeLast()
        }
        let brands = ["iphone": "iPhone", "ipad": "iPad", "ipod": "iPod", "macbook": "MacBook",
                      "imac": "iMac", "mac": "Mac", "watch": "Watch", "vision": "Vision"]
        let words = tokens.map { brands[$0.lowercased()] ?? ($0.allSatisfy(\.isNumber) ? $0 : $0.capitalized) }
        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// First installed application whose name equals the Handoff title.
    nonisolated static func applicationPath(named title: String) -> String? {
        guard !title.isEmpty, !title.contains("/") else { return nil }
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return roots.lazy.map { "\($0)/\(title).app" }.first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Features that exist only through Accessibility: notification badges read from the
/// system Dock's own AX tree, and the minimized-windows section. Nothing runs, and no
/// permission prompt appears, until the user grants Accessibility in Dock settings.
@MainActor
final class DockAccessibilityMonitor: ObservableObject {
    struct Options: Equatable {
        var badges = true
        var minimizedWindows = true
        var handoff = true
    }

    /// Application bundle path → badge text ("3", "•").
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var minimizedWindows: [DockMinimizedWindow] = []
    @Published private(set) var handoff: DockHandoffItem?
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    var interval: Duration = .seconds(4)
    /// A hidden Dock shows neither badges nor minimized windows; skip querying other applications.
    var isSuspended = false {
        didSet { if oldValue, !isSuspended { refreshNow() } }
    }
    var isTrustedCheck: () -> Bool = { AXIsProcessTrusted() }
    private var options = Options()
    private var loop: Task<Void, Never>?

    func update(active: Bool, options: Options) {
        self.options = options
        let wanted = active && (options.badges || options.minimizedWindows || options.handoff)
        if !wanted {
            loop?.cancel()
            loop = nil
            if !badges.isEmpty { badges = [:] }
            if !minimizedWindows.isEmpty { minimizedWindows = [] }
            if handoff != nil { handoff = nil }
            return
        }
        if !options.handoff, handoff != nil { handoff = nil }
        if !options.badges, !badges.isEmpty { badges = [:] }
        if !options.minimizedWindows, !minimizedWindows.isEmpty { minimizedWindows = [] }
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refreshNow() {
        guard loop != nil else { return }
        Task { await poll() }
    }

    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        isTrusted = isTrustedCheck()
    }

    func refreshTrust() {
        let value = isTrustedCheck()
        if value != isTrusted { isTrusted = value }
    }

    /// Un-minimizes and raises the window, then brings its application forward.
    func restore(_ window: DockMinimizedWindow) {
        let element = window.window
        minimizedWindows.removeAll { $0.id == window.id }
        Task {
            await Task.detached(priority: .userInitiated) {
                AXUIElementSetAttributeValue(element.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(element.element, kAXRaiseAction as CFString)
            }.value
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
    }

    private func poll() async {
        guard !isSuspended else { return }
        refreshTrust()
        guard isTrusted else {
            if !badges.isEmpty { badges = [:] }
            if !minimizedWindows.isEmpty { minimizedWindows = [] }
            if handoff != nil { handoff = nil }
            return
        }
        let options = options
        let own = ProcessInfo.processInfo.processIdentifier
        let candidates: [(pid: Int32, url: URL)] = options.minimizedWindows
            ? NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != own,
                      let url = app.bundleURL else { return nil }
                return (app.processIdentifier, url)
            } : []
        let dockPID = options.badges || options.handoff
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier : nil
        let result = await Task.detached(priority: .utility) {
            // Symlink resolution touches the file system; keep it off the main actor.
            let applications = candidates.map { ($0.pid, $0.url.standardizedFileURL.resolvingSymlinksInPath().path) }
            let dock = dockPID.map(Self.readDock) ?? ([:], nil)
            return (dock.0, Self.readMinimizedWindows(applications), dock.1)
        }.value
        guard !Task.isCancelled, loop != nil else { return }
        if options.badges, result.0 != badges { badges = result.0 }
        if options.handoff, result.2 != handoff { handoff = result.2 }
        let windows = result.1
        if options.minimizedWindows, windows.map(\.id) != minimizedWindows.map(\.id)
            || zip(windows, minimizedWindows).contains(where: { $0.title != $1.title }) {
            minimizedWindows = windows
        }
    }

    /// Continues the advertised activity: the system Dock itself performs the Handoff.
    func openHandoff(_ item: DockHandoffItem) {
        let element = item.element
        Task.detached(priority: .userInitiated) {
            AXUIElementPerformAction(element.element, kAXPressAction as CFString)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshNow()
        }
    }

    /// The system Dock keeps running (hidden) while NooL replaces it, and exposes each
    /// application tile as AXDockItem with AXURL and AXStatusLabel, and the Handoff tile
    /// as AXHandoffDockItem with the application name and the source device model.
    nonisolated static func readDock(dockPID: Int32) -> (badges: [String: String], handoff: DockHandoffItem?) {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        var badges: [String: String] = [:]
        var handoff: DockHandoffItem?
        for list in children(dock) where string(list, kAXRoleAttribute) == kAXListRole as String {
            for item in children(list).prefix(256) {
                let subrole = string(item, kAXSubroleAttribute)
                if subrole == "AXHandoffDockItem" {
                    if handoff == nil, let title = string(item, kAXTitleAttribute), !title.isEmpty {
                        handoff = DockHandoffItem(title: title, deviceIdentifier: string(item, "AXStatusLabel") ?? "",
                                                  applicationPath: DockHandoffItem.applicationPath(named: title),
                                                  element: DockAXElement(element: item))
                    }
                    continue
                }
                guard subrole == "AXApplicationDockItem",
                      let label = string(item, "AXStatusLabel"), !label.isEmpty,
                      let raw = attribute(item, kAXURLAttribute), CFGetTypeID(raw) == CFURLGetTypeID() else { continue }
                let url = (raw as! CFURL) as URL
                guard url.isFileURL else { continue }
                badges[url.standardizedFileURL.resolvingSymlinksInPath().path] = String(label.prefix(8))
            }
        }
        return (badges, handoff)
    }

    nonisolated static func readMinimizedWindows(_ applications: [(pid: Int32, path: String)]) -> [DockMinimizedWindow] {
        var result: [DockMinimizedWindow] = []
        for application in applications.prefix(64) {
            let element = AXUIElementCreateApplication(application.pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let raw = attribute(element, kAXWindowsAttribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { continue }
            for window in (raw as! [AXUIElement]).prefix(64) {
                guard attribute(window, kAXMinimizedAttribute) as? Bool == true else { continue }
                result.append(DockMinimizedWindow(id: "\(application.pid):\(CFHash(window))", pid: application.pid,
                                                  applicationPath: application.path,
                                                  title: string(window, kAXTitleAttribute) ?? "",
                                                  window: DockAXElement(element: window)))
                if result.count >= 12 { return result }
            }
        }
        return result
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(element, kAXChildrenAttribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return raw as! [AXUIElement]
    }

    private nonisolated static func string(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
