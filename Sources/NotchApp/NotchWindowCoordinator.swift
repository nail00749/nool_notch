import AppKit
import SwiftUI

enum NotchWindowHostingPolicy {
    static let sizingOptions: NSHostingSizingOptions = []
}

@MainActor
final class NotchWindowCoordinator: NSObject {
    private let window: NotchPanel
    private let settingsWindow: NSPanel
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private var lastLayoutWasExpanded = false
    private var targetWindowFrame: NSRect?
    private var applicationBeforeSearch: NSRunningApplication?
    private var displayFollowTimer: Timer?

    override init() {
        model = NotchViewModel(
            aiSessionStore: AISessionStore(
                sources: [
                    CodexDesktopSessionSource(),
                    LocalAgentSessionSource()
                ]
            )
        )
        visualSettings = NotchVisualSettings()
        displaySettings = NotchDisplaySettings()
        launchAtLogin = LaunchAtLoginManager()
        displaySettings.refreshConnectedDisplays()
        let initialScreen = displaySettings.selectedScreen()
        displaySettings.setActiveScreen(initialScreen)
        model.timerSource.onCompletion = {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        let compactHeight = displaySettings.effectiveCompactHeight(
            fallback: visualSettings.compactHeight
        )
        let size = NotchWindowSizingPolicy.compactInteractionSize(
            metrics: displaySettings.activeMetrics,
            isPlaying: false,
            compactHeight: compactHeight
        )
        let origin = Self.origin(for: initialScreen, size: size)
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
                displaySettings: displaySettings,
                launchAtLogin: launchAtLogin,
                initialSection: .general
            )
        )

        let contentView = NotchRootView(
            model: model,
            visualSettings: visualSettings,
            displaySettings: displaySettings,
            onOpenSettings: { [weak self] section in
                self?.showSettingsWindow(section: section)
            },
            onLayoutChange: { [weak self] isExpanded, reduceMotion in
                self?.animateWindow(to: isExpanded, reduceMotion: reduceMotion)
            },
            onKeyboardFocusChange: { [weak self] enabled in
                guard let self else { return }
                self.window.acceptsKeyboardFocus = enabled
                if enabled {
                    let previous = NSWorkspace.shared.frontmostApplication
                    self.applicationBeforeSearch = previous?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                        ? nil : previous
                    NSApp.activate(ignoringOtherApps: true)
                    self.window.makeKeyAndOrderFront(nil)
                } else {
                    if self.window.isKeyWindow { self.window.resignKey() }
                    if NSApp.isActive, self.settingsWindow.isVisible == false {
                        self.applicationBeforeSearch?.activate(options: [])
                    }
                    self.applicationBeforeSearch = nil
                }
            }
        )
        .preferredColorScheme(.dark)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
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

        displaySettings.onConfigurationChange = { [weak self] in
            self?.configureDisplayFollowing()
            self?.reposition()
        }
    }

    func show() {
        configureDisplayFollowing()
        window.orderFrontRegardless()
    }

    func reposition() {
        displaySettings.refreshConnectedDisplays()
        let screen = displaySettings.selectedScreen(
            preserveActiveDisplay: model.isExpanded
        )
        displaySettings.setActiveScreen(screen)
        let size = targetWindowSize()
        let frame = NSRect(
            origin: Self.origin(for: screen, size: size),
            size: size
        )
        targetWindowFrame = frame
        window.setFrame(frame, display: true)
    }

    private func showSettingsWindow(section: NotchSettingsSection) {
        model.cancelScheduledCollapse()
        model.isExpanded = false
        settingsWindow.contentView = NSHostingView(
            rootView: NotchSettingsView(
                model: model,
                settings: visualSettings,
                displaySettings: displaySettings,
                launchAtLogin: launchAtLogin,
                initialSection: section
            )
        )
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func animateWindow(to isExpanded: Bool, reduceMotion: Bool) {
        let size = targetWindowSize(isExpanded: isExpanded)
        let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen()
        let frame = NSRect(
            origin: Self.origin(for: screen, size: size),
            size: size
        )
        let wasExpanded = lastLayoutWasExpanded
        lastLayoutWasExpanded = isExpanded

        guard targetWindowFrame != frame else { return }
        targetWindowFrame = frame

        guard reduceMotion == false else {
            window.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            if isExpanded == false, wasExpanded == false {
                context.duration = NotchMotion.compactResizeDuration
                context.timingFunction = NotchMotion.compactResizeTimingFunction()
            } else {
                context.duration = isExpanded ? NotchMotion.expansionDuration : NotchMotion.collapseDuration
                context.timingFunction = NotchMotion.compactResizeTimingFunction()
            }
            window.animator().setFrame(frame, display: true)
        }
    }

    private func targetWindowSize(isExpanded: Bool? = nil) -> NSSize {
        NotchWindowSizingPolicy.size(
            metrics: displaySettings.activeMetrics,
            isExpanded: isExpanded ?? model.isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: model.isShowingSettings,
            compactHeight: displaySettings.effectiveCompactHeight(
                fallback: visualSettings.compactHeight
            ),
            isPlaying: model.usesWideCompactLayout,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered
        )
    }

    private func configureDisplayFollowing() {
        displayFollowTimer?.invalidate()
        displayFollowTimer = nil
        guard displaySettings.mode == .followPointer else { return }

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.model.isExpanded == false else { return }
                let previousDisplayID = self.displaySettings.activeDisplayID
                let screen = self.displaySettings.selectedScreen()
                self.displaySettings.setActiveScreen(screen)
                guard previousDisplayID != self.displaySettings.activeDisplayID else { return }
                self.reposition()
            }
        }
        displayFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func origin(for screen: NSScreen?, size: NSSize) -> NSPoint {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        )
    }
}
