import AppKit
import Combine
import SwiftUI

enum NotchWindowHostingPolicy {
    static let sizingOptions: NSHostingSizingOptions = []
}

enum QuotaEdgeWindowLevel {
    static let rail: NSWindow.Level = .mainMenu + 3
    static let trigger: NSWindow.Level = .mainMenu + 4
}

enum QuotaEdgePanelMotion {
    static let revealOffset: CGFloat = 56
    static let hideOffset: CGFloat = 18
    static let revealInitialAlpha: CGFloat = 0.16
    static let revealDuration: TimeInterval = 0.30
    static let hideDuration: TimeInterval = 0.18
    static let reducedMotionRevealDuration: TimeInterval = 0.16
    static let reducedMotionHideDuration: TimeInterval = 0.12

    static func frame(
        offsetOutwardFrom frame: NSRect,
        edge: QuotaPanelEdge,
        distance: CGFloat
    ) -> NSRect {
        frame.offsetBy(dx: edge == .left ? -distance : distance, dy: 0)
    }
}

@MainActor
final class NotchWindowCoordinator: NSObject {
    private let launcher: LauncherWindowCoordinator
    private let window: NotchPanel
    private let quotaEdgeCoordinator: QuotaEdgeWindowCoordinator
    private let quotaStackCoordinator: QuotaStackWindowCoordinator
    private let settingsCoordinator: SettingsWindowCoordinator
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private let dockSettings: NoolDockSettings
    private var dock: NoolDockWindowCoordinator?
    private let fileActions = FileActionsWindowCoordinator()
    private let textRecognition = TextRecognitionWindowCoordinator()
    private var lastLayoutWasExpanded = false
    private var targetWindowFrame: NSRect?
    private var applicationBeforeSearch: NSRunningApplication?
    private var displayFollowTimer: Timer?
    private var modelChanges: AnyCancellable?
    private(set) var isStarted = false
    private var isTerminated = false

    init(launcher: LauncherWindowCoordinator) {
        self.launcher = launcher
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
        dockSettings = NoolDockSettings()
        displaySettings.refreshConnectedDisplays()
        let initialScreen = displaySettings.selectedScreen()
        displaySettings.setActiveScreen(initialScreen)
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
        quotaEdgeCoordinator = QuotaEdgeWindowCoordinator(model: model, displaySettings: displaySettings)
        quotaStackCoordinator = QuotaStackWindowCoordinator(model: model, displaySettings: displaySettings)
        settingsCoordinator = SettingsWindowCoordinator(
            model: model,
            visualSettings: visualSettings,
            displaySettings: displaySettings,
            launchAtLogin: launchAtLogin,
            launcher: launcher,
            dockSettings: dockSettings
        )

        super.init()
        launcher.model.connectNoolSearch(to: model)
        model.onOpenFileActions = { [weak self] urls in
            guard let self, self.isStarted else { return }
            self.model.isExpanded = false
            self.fileActions.show(urls: urls, shelf: self.model.fileShelfStore)
        }
        launcher.onProcessFiles = { [weak self] urls, kind in
            guard let self, self.isStarted else { return }
            self.fileActions.show(urls: urls, shelf: self.model.fileShelfStore, initialKind: kind)
        }
        let recognize: ([URL]) -> Void = { [weak self, weak launcher] urls in
            guard let self, self.isStarted else { return }
            self.model.isExpanded = false
            self.textRecognition.show(urls: urls) { [weak launcher] text in
                launcher?.prepareTextRecognitionDraft(text) ?? false
            }
        }
        model.onRecognizeText = recognize
        launcher.onRecognizeText = recognize
        dock = NoolDockWindowCoordinator(
            settings: dockSettings,
            model: model,
            openSettings: { [weak self] in self?.showSettingsWindow(section: .dock) },
            openLauncher: { [weak launcher] in launcher?.show() }
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
                guard let self, self.isStarted else { return }
                self.window.acceptsKeyboardFocus = enabled
                if enabled {
                    let previous = NSWorkspace.shared.frontmostApplication
                    self.applicationBeforeSearch = previous?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                        ? nil : previous
                    NSApp.activate(ignoringOtherApps: true)
                    self.window.makeKeyAndOrderFront(nil)
                } else {
                    if self.window.isKeyWindow { self.window.resignKey() }
                    if NSApp.isActive, self.settingsCoordinator.isVisible == false {
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
    }

    func show() {
        guard !isTerminated else { return }
        guard !isStarted else {
            window.orderFrontRegardless()
            synchronizeQuotaPresentation()
            return
        }
        isStarted = true
        model.timerSource.onCompletion = {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStarted else { return }
                self.synchronizeQuotaPresentation()
            }
        }
        displaySettings.onConfigurationChange = { [weak self] in
            guard let self, self.isStarted else { return }
            self.configureDisplayFollowing()
            self.reposition()
        }
        configureDisplayFollowing()
        settingsCoordinator.start()
        window.orderFrontRegardless()
        quotaEdgeCoordinator.start()
        quotaStackCoordinator.start()
        dock?.start()
    }

    func stop() {
        guard !isTerminated else { return }
        isTerminated = true
        isStarted = false
        modelChanges?.cancel()
        modelChanges = nil
        displayFollowTimer?.invalidate()
        displayFollowTimer = nil
        displaySettings.onConfigurationChange = nil
        model.timerSource.onCompletion = nil
        quotaEdgeCoordinator.stop()
        quotaStackCoordinator.stop()
        settingsCoordinator.stop()
        fileActions.stop()
        textRecognition.stop()
        dock?.stop()
        model.stop()
        window.orderOut(nil)
        applicationBeforeSearch = nil
    }

    func waitForFileActions() async { await fileActions.waitForCompletion() }

    func reposition() {
        guard isStarted else { return }
        dock?.reposition()
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
        synchronizeQuotaPresentation()
    }

    func showSettingsWindow(section: NotchSettingsSection) {
        settingsCoordinator.show(section: section)
    }

    private func animateWindow(to isExpanded: Bool, reduceMotion: Bool) {
        guard isStarted else { return }
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
        guard isStarted else { return }
        displayFollowTimer?.invalidate()
        displayFollowTimer = nil
        guard displaySettings.mode == .followPointer else { return }

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted, self.model.isExpanded == false else { return }
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

    private func synchronizeQuotaPresentation() {
        guard isStarted else { return }
        quotaEdgeCoordinator.synchronize()
        quotaStackCoordinator.synchronize()
    }

    private static func origin(for screen: NSScreen?, size: NSSize) -> NSPoint {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        )
    }
}
