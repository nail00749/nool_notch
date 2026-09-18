import AppKit
import SwiftUI

/// Owns the settings panel and its SwiftUI content independently of the notch panel.
@MainActor
final class SettingsWindowCoordinator {
    private let window: NSPanel
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private let launcher: LauncherWindowCoordinator
    private let dockSettings: NoolDockSettings
    private(set) var isStarted = false

    var isVisible: Bool { window.isVisible }
    var ownedPanel: NSPanel { window }

    init(
        model: NotchViewModel,
        visualSettings: NotchVisualSettings,
        displaySettings: NotchDisplaySettings,
        launchAtLogin: LaunchAtLoginManager,
        launcher: LauncherWindowCoordinator,
        dockSettings: NoolDockSettings
    ) {
        self.model = model
        self.visualSettings = visualSettings
        self.displaySettings = displaySettings
        self.launchAtLogin = launchAtLogin
        self.launcher = launcher
        self.dockSettings = dockSettings
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Notch"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.backgroundColor = NSColor(NotchPalette.surface)
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView(section: .general)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        window.orderOut(nil)
    }

    func show(section: NotchSettingsSection) {
        guard isStarted else { return }
        model.cancelScheduledCollapse()
        model.isExpanded = false
        model.isCompactHovered = false
        window.contentView = hostingView(section: section)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func hostingView(section: NotchSettingsSection) -> NSHostingView<NotchSettingsView> {
        NSHostingView(rootView: NotchSettingsView(
            model: model,
            settings: visualSettings,
            displaySettings: displaySettings,
            launchAtLogin: launchAtLogin,
            launcher: launcher,
            dockSettings: dockSettings,
            initialSection: section
        ))
    }
}
