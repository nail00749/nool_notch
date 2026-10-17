import AppKit
import SwiftUI

/// Owns the settings panel and its SwiftUI content independently of the notch panel.
@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let customizationSettings: NotchCustomizationSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private let launcher: LauncherWindowCoordinator
    private let dockSettings: NoolDockSettings
    private let lidEffect: LidEffectController
    private let liveWallpaper: LiveWallpaperController
    private let systemMonitor: SystemMonitorStore
    private(set) var isStarted = false

    var isVisible: Bool { window.isVisible }
    var ownedPanel: NSPanel { window }

    init(
        model: NotchViewModel,
        visualSettings: NotchVisualSettings,
        customizationSettings: NotchCustomizationSettings,
        displaySettings: NotchDisplaySettings,
        launchAtLogin: LaunchAtLoginManager,
        launcher: LauncherWindowCoordinator,
        dockSettings: NoolDockSettings,
        lidEffect: LidEffectController,
        liveWallpaper: LiveWallpaperController,
        systemMonitor: SystemMonitorStore
    ) {
        self.model = model
        self.visualSettings = visualSettings
        self.customizationSettings = customizationSettings
        self.displaySettings = displaySettings
        self.launchAtLogin = launchAtLogin
        self.launcher = launcher
        self.dockSettings = dockSettings
        self.lidEffect = lidEffect
        self.liveWallpaper = liveWallpaper
        self.systemMonitor = systemMonitor
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 740),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "Настройки NooL App"
        window.contentMinSize = NSSize(width: 780, height: 620)
        window.appearance = nil
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        // SwiftUI content is created on show and released on close: a hidden hosting
        // view keeps observing every store and re-renders all settings pages.
        window.contentView = NSView()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        window.orderOut(nil)
        releaseContent()
        lidEffect.cancelPreview()
    }

    func show(section: NotchSettingsSection) {
        guard isStarted else { return }
        lidEffect.cancelPreview()
        model.cancelScheduledCollapse()
        model.isExpanded = false
        model.isCompactHovered = false
        window.contentView = hostingView(section: section)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        lidEffect.cancelPreview()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.window.isVisible else { return }
            self.releaseContent()
        }
    }

    private func releaseContent() {
        guard window.contentView is NSHostingView<NotchSettingsView> else { return }
        window.contentView = NSView()
    }

    private func hostingView(section: NotchSettingsSection) -> NSHostingView<NotchSettingsView> {
        NSHostingView(rootView: NotchSettingsView(
            model: model,
            settings: visualSettings,
            customizationSettings: customizationSettings,
            displaySettings: displaySettings,
            launchAtLogin: launchAtLogin,
            launcher: launcher,
            dockSettings: dockSettings,
            lidEffect: lidEffect,
            liveWallpaper: liveWallpaper,
            systemMonitor: systemMonitor,
            initialSection: section
        ))
    }
}
