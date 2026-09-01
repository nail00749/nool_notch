import AppKit
import SwiftUI

@MainActor
final class NotchWindowCoordinator: NSObject {
    private let window: NotchPanel
    private let settingsWindow: NSPanel
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let launchAtLogin: LaunchAtLoginManager

    override init() {
        model = NotchViewModel()
        visualSettings = NotchVisualSettings()
        launchAtLogin = LaunchAtLoginManager()
        let size = NotchLayout.compactSize(
            isPlaying: false,
            compactHeight: visualSettings.compactHeight
        )
        let origin = Self.origin(for: NSScreen.preferredNotchScreen, size: size)
        window = NotchPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .utilityWindow,
                .hudWindow
            ],
            backing: .buffered,
            defer: false
        )
        settingsWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        super.init()

        settingsWindow.title = "Настройки Notch"
        settingsWindow.appearance = NSAppearance(named: .darkAqua)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.isFloatingPanel = true
        settingsWindow.level = .floating
        settingsWindow.hidesOnDeactivate = false
        settingsWindow.backgroundColor = .black
        settingsWindow.contentView = NSHostingView(
            rootView: NotchSettingsView(
                model: model,
                settings: visualSettings,
                launchAtLogin: launchAtLogin,
                initialSection: .general
            )
        )

        let contentView = NotchRootView(
            model: model,
            visualSettings: visualSettings,
            onOpenSettings: { [weak self] section in
                self?.showSettingsWindow(section: section)
            },
            onLayoutChange: { [weak self] isExpanded, reduceMotion in
                self?.animateWindow(to: isExpanded, reduceMotion: reduceMotion)
            }
        )
        .preferredColorScheme(.dark)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.isOpaque = false
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isFloatingPanel = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.level = .mainMenu + 3
        window.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
    }

    func show() {
        window.orderFrontRegardless()
    }

    func reposition() {
        window.setFrameOrigin(Self.origin(for: NSScreen.preferredNotchScreen, size: window.frame.size))
    }

    private func showSettingsWindow(section: NotchSettingsSection) {
        model.cancelScheduledCollapse()
        model.isExpanded = false
        settingsWindow.contentView = NSHostingView(
            rootView: NotchSettingsView(
                model: model,
                settings: visualSettings,
                launchAtLogin: launchAtLogin,
                initialSection: section
            )
        )
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func animateWindow(to isExpanded: Bool, reduceMotion: Bool) {
        let size = NotchWindowSizingPolicy.size(
            metrics: NotchLayout.currentMetrics,
            isExpanded: isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: model.isShowingSettings,
            compactHeight: visualSettings.compactHeight,
            isPlaying: model.nowPlayingSnapshot?.playbackState.isPlaying == true
        )
        let frame = NSRect(
            origin: Self.origin(for: NSScreen.preferredNotchScreen, size: size),
            size: size
        )

        guard reduceMotion == false else {
            window.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = isExpanded ? 0.54 : 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    private static func origin(for screen: NSScreen?, size: NSSize) -> NSPoint {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        )
    }
}
