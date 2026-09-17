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
    private let quotaTriggerWindow: NotchPanel
    private let quotaEdgeWindow: NotchPanel
    private let quotaDetailWindow: NotchPanel
    private let quotaStackTriggerWindow: NotchPanel
    private let settingsWindow: NSPanel
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private var lastLayoutWasExpanded = false
    private var targetWindowFrame: NSRect?
    private var applicationBeforeSearch: NSRunningApplication?
    private var displayFollowTimer: Timer?
    private var modelChanges: AnyCancellable?
    private var quotaEdgeHideTask: Task<Void, Never>?
    private var quotaTriggerConfiguration: QuotaPanelEdge?
    private var quotaEdgeConfiguration: (edge: QuotaPanelEdge, providerIDs: [String])?
    private var quotaDetailConfiguration: (edge: QuotaPanelEdge, providerID: String)?
    private var hoveredQuotaProviderID: String?
    private var isQuotaTriggerHovered = false
    private var isQuotaEdgeHovered = false
    private var isQuotaEdgePresented = false
    private var quotaEdgeAnimationGeneration = 0
    private var quotaDetailAnimationGeneration = 0
    private var quotaStackItemWindows: [String: NotchPanel] = [:]
    private var quotaStackConfiguration: (corner: QuotaStackCorner, providerIDs: [String])?
    private var quotaStackTriggerConfiguration: QuotaStackCorner?
    private var quotaStackHoveredProviderIDs: Set<String> = []
    private var isQuotaStackTriggerHovered = false
    private var isQuotaStackPresented = false
    private var quotaStackHideTask: Task<Void, Never>?
    private var quotaStackAnimationGeneration = 0
    private var quotaStackTargetFrames: [String: NSRect] = [:]

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
        quotaTriggerWindow = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        quotaEdgeWindow = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        quotaDetailWindow = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        quotaStackTriggerWindow = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
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
        launcher.model.connectNoolSearch(to: model)

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
                launcher: launcher,
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

        configureQuotaWindow(
            quotaTriggerWindow,
            ignoresMouseEvents: false,
            level: QuotaEdgeWindowLevel.trigger
        )
        configureQuotaWindow(
            quotaEdgeWindow,
            ignoresMouseEvents: false,
            level: QuotaEdgeWindowLevel.rail
        )
        configureQuotaWindow(
            quotaDetailWindow,
            ignoresMouseEvents: true,
            level: QuotaEdgeWindowLevel.rail
        )
        configureQuotaWindow(
            quotaStackTriggerWindow,
            ignoresMouseEvents: false,
            level: QuotaEdgeWindowLevel.trigger
        )

        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeQuotaPresentation()
            }
        }

        displaySettings.onConfigurationChange = { [weak self] in
            self?.configureDisplayFollowing()
            self?.reposition()
        }
    }

    func show() {
        configureDisplayFollowing()
        window.orderFrontRegardless()
        synchronizeQuotaPresentation()
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
        synchronizeQuotaPresentation()
    }

    func showSettingsWindow(section: NotchSettingsSection) {
        model.cancelScheduledCollapse()
        model.isExpanded = false
        model.isCompactHovered = false
        settingsWindow.contentView = NSHostingView(
            rootView: NotchSettingsView(
                model: model,
                settings: visualSettings,
                displaySettings: displaySettings,
                launchAtLogin: launchAtLogin,
                launcher: launcher,
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

    private func configureQuotaWindow(
        _ panel: NotchPanel,
        ignoresMouseEvents: Bool,
        level: NSWindow.Level
    ) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.alphaValue = 0
    }

    private func synchronizeQuotaPresentation() {
        synchronizeQuotaEdgePanel()
        synchronizeQuotaCornerStack()
    }

    private func synchronizeQuotaEdgePanel() {
        guard model.shouldEnableQuotaEdgePanel else {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            isQuotaTriggerHovered = false
            isQuotaEdgeHovered = false
            hoveredQuotaProviderID = nil
            hideQuotaDetailWindow(animated: true)
            hideQuotaEdgeWindow(animated: true)
            hideQuotaTriggerWindow()
            return
        }

        let edge = model.quotaPanelEdge

        let providers = model.visibleQuotaProviders
        let providerIDs = providers.map(\.id)
        let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let railFrame = QuotaEdgePanelLayout.railFrame(
            in: screenFrame,
            edge: edge,
            providerCount: providers.count
        )

        if quotaTriggerConfiguration != edge {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            isQuotaTriggerHovered = false
            isQuotaEdgeHovered = false
            hoveredQuotaProviderID = nil
            hideQuotaDetailWindow(animated: false)
            hideQuotaEdgeWindow(animated: false)

            let rootView = CompactQuotaEdgeTrigger(
                edge: edge,
                onHover: { [weak self] isHovering in
                    self?.setQuotaTriggerHovered(isHovering)
                }
            )
            .preferredColorScheme(.dark)
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
            hostingView.wantsLayer = true
            hostingView.layer?.isOpaque = false
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            quotaTriggerWindow.contentView = hostingView
            quotaTriggerConfiguration = edge
        }

        quotaTriggerWindow.setFrame(
            QuotaEdgePanelLayout.triggerFrame(
                in: screenFrame,
                edge: edge,
                providerCount: providers.count
            ),
            display: true
        )
        showQuotaTriggerWindow()

        switch QuotaEdgeVisibilityPolicy.decision(
            triggerHovered: isQuotaTriggerHovered,
            railHovered: isQuotaEdgeHovered,
            hideScheduled: quotaEdgeHideTask != nil
        ) {
        case .waitForGracePeriod:
            return
        case .hide:
            hoveredQuotaProviderID = nil
            hideQuotaDetailWindow(animated: true)
            hideQuotaEdgeWindow(animated: true)
            return
        case .show:
            break
        }

        quotaEdgeHideTask?.cancel()
        quotaEdgeHideTask = nil

        if quotaEdgeConfiguration?.edge != edge
            || quotaEdgeConfiguration?.providerIDs != providerIDs {
            let rootView = CompactQuotaSidebar(
                model: model,
                edge: edge,
                onOpen: { [weak self] in self?.model.openQuotaLimits() },
                onPanelHover: { [weak self] isHovering in
                    self?.setQuotaEdgeHovered(isHovering)
                },
                onProviderHover: { [weak self] providerID in
                    self?.setHoveredQuotaProvider(providerID)
                }
            )
            .preferredColorScheme(.dark)
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
            hostingView.wantsLayer = true
            hostingView.layer?.isOpaque = false
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            quotaEdgeWindow.contentView = hostingView
            quotaEdgeConfiguration = (edge, providerIDs)
        }

        showQuotaEdgeWindow(targetFrame: railFrame, edge: edge)
        updateQuotaDetailWindow(edge: edge, railFrame: railFrame, screenFrame: screenFrame)
    }

    private func setQuotaTriggerHovered(_ isHovering: Bool) {
        guard isQuotaTriggerHovered != isHovering else { return }
        isQuotaTriggerHovered = isHovering
        if isHovering {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            model.refreshQuotaProvidersIfStale()
            synchronizeQuotaEdgePanel()
        } else {
            scheduleQuotaEdgeHide()
        }
    }

    private func setQuotaEdgeHovered(_ isHovering: Bool) {
        guard isQuotaEdgeHovered != isHovering else { return }
        isQuotaEdgeHovered = isHovering
        if isHovering {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            synchronizeQuotaEdgePanel()
        } else {
            scheduleQuotaEdgeHide()
        }
    }

    private func setHoveredQuotaProvider(_ providerID: String?) {
        guard hoveredQuotaProviderID != providerID else { return }
        hoveredQuotaProviderID = providerID
        if providerID != nil {
            model.refreshQuotaProvidersIfStale()
        }
        synchronizeQuotaEdgePanel()
    }

    private func updateQuotaDetailWindow(
        edge: QuotaPanelEdge,
        railFrame: CGRect,
        screenFrame: CGRect
    ) {
        guard let providerID = hoveredQuotaProviderID,
              let index = model.visibleQuotaProviders.firstIndex(where: { $0.id == providerID }) else {
            hideQuotaDetailWindow(animated: true)
            return
        }

        if quotaDetailConfiguration?.edge != edge
            || quotaDetailConfiguration?.providerID != providerID {
            let rootView = CompactQuotaDetailPanel(
                model: model,
                providerID: providerID,
                edge: edge
            )
            .preferredColorScheme(.dark)
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
            hostingView.wantsLayer = true
            hostingView.layer?.isOpaque = false
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            quotaDetailWindow.contentView = hostingView
            quotaDetailConfiguration = (edge, providerID)
        }

        quotaDetailWindow.setFrame(
            QuotaEdgePanelLayout.detailFrame(
                in: screenFrame,
                railFrame: railFrame,
                edge: edge,
                providerIndex: index
            ),
            display: true
        )
        showQuotaDetailWindow()
    }

    private func scheduleQuotaEdgeHide() {
        guard QuotaEdgeVisibilityPolicy.showsRail(
            triggerHovered: isQuotaTriggerHovered,
            railHovered: isQuotaEdgeHovered
        ) == false,
        quotaEdgeWindow.isVisible,
        quotaEdgeHideTask == nil else { return }

        quotaEdgeHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self else { return }
            self.quotaEdgeHideTask = nil
            guard QuotaEdgeVisibilityPolicy.showsRail(
                triggerHovered: self.isQuotaTriggerHovered,
                railHovered: self.isQuotaEdgeHovered
            ) == false else { return }
            self.hoveredQuotaProviderID = nil
            self.hideQuotaDetailWindow(animated: true)
            self.hideQuotaEdgeWindow(animated: true)
        }
    }

    private func showQuotaTriggerWindow() {
        quotaTriggerWindow.alphaValue = 1
        if quotaTriggerWindow.isVisible == false {
            quotaTriggerWindow.orderFrontRegardless()
        }
    }

    private func hideQuotaTriggerWindow() {
        guard quotaTriggerWindow.isVisible else { return }
        quotaTriggerWindow.orderOut(nil)
        quotaTriggerWindow.alphaValue = 0
    }

    private func showQuotaEdgeWindow(targetFrame: NSRect, edge: QuotaPanelEdge) {
        quotaEdgeAnimationGeneration &+= 1
        let wasPresented = isQuotaEdgePresented
        isQuotaEdgePresented = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if quotaEdgeWindow.isVisible == false {
            quotaEdgeWindow.alphaValue = reduceMotion
                ? 0
                : QuotaEdgePanelMotion.revealInitialAlpha
            quotaEdgeWindow.setFrame(
                reduceMotion
                    ? targetFrame
                    : QuotaEdgePanelMotion.frame(
                        offsetOutwardFrom: targetFrame,
                        edge: edge,
                        distance: QuotaEdgePanelMotion.revealOffset
                    ),
                display: true
            )
            quotaEdgeWindow.orderFrontRegardless()
        } else if wasPresented,
                  quotaEdgeWindow.alphaValue == 1,
                  quotaEdgeWindow.frame.equalTo(targetFrame) {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion
                ? QuotaEdgePanelMotion.reducedMotionRevealDuration
                : QuotaEdgePanelMotion.revealDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.16,
                1,
                0.3,
                1
            )
            quotaEdgeWindow.animator().alphaValue = 1
            if reduceMotion {
                quotaEdgeWindow.setFrame(targetFrame, display: true)
            } else {
                quotaEdgeWindow.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func hideQuotaEdgeWindow(animated: Bool) {
        let wasPresented = isQuotaEdgePresented
        isQuotaEdgePresented = false
        guard quotaEdgeWindow.isVisible else { return }
        guard animated == false || wasPresented else { return }
        quotaEdgeAnimationGeneration &+= 1
        let generation = quotaEdgeAnimationGeneration
        if animated == false {
            quotaEdgeWindow.orderOut(nil)
            quotaEdgeWindow.alphaValue = 0
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let edge = quotaEdgeConfiguration?.edge ?? .right
        let hiddenFrame = QuotaEdgePanelMotion.frame(
            offsetOutwardFrom: quotaEdgeWindow.frame,
            edge: edge,
            distance: QuotaEdgePanelMotion.hideOffset
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion
                ? QuotaEdgePanelMotion.reducedMotionHideDuration
                : QuotaEdgePanelMotion.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            quotaEdgeWindow.animator().alphaValue = 0
            if reduceMotion == false {
                quotaEdgeWindow.animator().setFrame(hiddenFrame, display: true)
            }
        }
        Task { @MainActor [weak self] in
            let duration = reduceMotion
                ? QuotaEdgePanelMotion.reducedMotionHideDuration
                : QuotaEdgePanelMotion.hideDuration
            try? await Task.sleep(for: .seconds(duration + 0.01))
            guard let self, self.quotaEdgeAnimationGeneration == generation else { return }
            self.quotaEdgeWindow.orderOut(nil)
        }
    }

    private func showQuotaDetailWindow() {
        quotaDetailAnimationGeneration &+= 1
        if quotaDetailWindow.isVisible == false {
            quotaDetailWindow.alphaValue = 0
            quotaDetailWindow.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            quotaDetailWindow.animator().alphaValue = 1
        }
    }

    private func hideQuotaDetailWindow(animated: Bool) {
        guard quotaDetailWindow.isVisible else { return }
        quotaDetailAnimationGeneration &+= 1
        let generation = quotaDetailAnimationGeneration
        if animated == false {
            quotaDetailWindow.orderOut(nil)
            quotaDetailWindow.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            quotaDetailWindow.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard let self, self.quotaDetailAnimationGeneration == generation else { return }
            self.quotaDetailWindow.orderOut(nil)
        }
    }

    private func synchronizeQuotaCornerStack() {
        guard model.shouldEnableQuotaCornerStack else {
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            isQuotaStackTriggerHovered = false
            quotaStackHoveredProviderIDs.removeAll()
            hideQuotaCornerStack(animated: true)
            hideQuotaStackTriggerWindow()
            return
        }

        let corner = model.quotaStackCorner
        let providers = model.visibleQuotaProviders
        let providerIDs = providers.map(\.id)
        let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        if quotaStackTriggerConfiguration != corner {
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            isQuotaStackTriggerHovered = false
            quotaStackHoveredProviderIDs.removeAll()
            hideQuotaCornerStack(animated: false)
            hideQuotaStackTriggerWindow()

            let rootView = CompactQuotaCornerTrigger(
                corner: corner,
                onHover: { [weak self] hovering in
                    self?.setQuotaStackTriggerHovered(hovering)
                }
            )
            .preferredColorScheme(.dark)
            quotaStackTriggerWindow.contentView = quotaHostingView(rootView)
            quotaStackTriggerConfiguration = corner
        }

        quotaStackTriggerWindow.setFrame(
            QuotaCornerStackLayout.triggerFrame(in: screenFrame, corner: corner),
            display: true
        )
        showQuotaStackTriggerWindow()

        switch QuotaCornerStackVisibilityPolicy.decision(
            triggerHovered: isQuotaStackTriggerHovered,
            hoveredProviderIDs: quotaStackHoveredProviderIDs,
            hideScheduled: quotaStackHideTask != nil
        ) {
        case .waitForGracePeriod:
            return
        case .hide:
            hideQuotaCornerStack(animated: true)
            return
        case .show:
            break
        }

        quotaStackHideTask?.cancel()
        quotaStackHideTask = nil

        let configurationChanged = quotaStackConfiguration?.corner != corner
            || quotaStackConfiguration?.providerIDs != providerIDs
        if configurationChanged {
            reconcileQuotaStackWindows(providerIDs: providerIDs, corner: corner)
            quotaStackConfiguration = (corner, providerIDs)
        }

        let targetFrames = Dictionary(uniqueKeysWithValues: providerIDs.enumerated().map { index, id in
            (
                id,
                QuotaCornerStackLayout.itemFrame(
                    in: screenFrame,
                    corner: corner,
                    index: index
                )
            )
        })
        let targetFramesChanged = quotaStackFramesMatch(
            quotaStackTargetFrames,
            targetFrames
        ) == false
        if isQuotaStackPresented,
           configurationChanged == false,
           targetFramesChanged == false {
            return
        }
        quotaStackTargetFrames = targetFrames
        showQuotaCornerStack(
            corner: corner,
            providerIDs: providerIDs,
            targetFrames: targetFrames,
            restagger: isQuotaStackPresented == false
        )
    }

    private func quotaStackFramesMatch(
        _ current: [String: NSRect],
        _ expected: [String: NSRect]
    ) -> Bool {
        guard current.count == expected.count else { return false }
        return expected.allSatisfy { providerID, frame in
            current[providerID]?.equalTo(frame) == true
        }
    }

    private func reconcileQuotaStackWindows(
        providerIDs: [String],
        corner: QuotaStackCorner
    ) {
        let retainedIDs = Set(providerIDs)
        let removedProviderIDs = quotaStackItemWindows.keys.filter {
            retainedIDs.contains($0) == false
        }
        for providerID in removedProviderIDs {
            quotaStackItemWindows[providerID]?.orderOut(nil)
            quotaStackItemWindows.removeValue(forKey: providerID)
            quotaStackHoveredProviderIDs.remove(providerID)
        }

        for (index, providerID) in providerIDs.enumerated() {
            let panel = quotaStackItemWindows[providerID] ?? makeQuotaStackItemWindow()
            let rootView = CompactQuotaCornerStackItem(
                model: model,
                providerID: providerID,
                corner: corner,
                index: index,
                onOpen: { [weak self] in self?.openQuotaLimitsFromStack() },
                onHover: { [weak self] hovering in
                    self?.setQuotaStackItemHovered(providerID, hovering: hovering)
                }
            )
            .preferredColorScheme(.dark)
            panel.contentView = quotaHostingView(rootView)
            quotaStackItemWindows[providerID] = panel
        }
    }

    private func quotaHostingView<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        return hostingView
    }

    private func makeQuotaStackItemWindow() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        configureQuotaWindow(
            panel,
            ignoresMouseEvents: false,
            level: QuotaEdgeWindowLevel.rail
        )
        return panel
    }

    private func setQuotaStackTriggerHovered(_ hovering: Bool) {
        guard isQuotaStackTriggerHovered != hovering else { return }
        isQuotaStackTriggerHovered = hovering
        if hovering {
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            model.refreshQuotaProvidersIfStale()
            synchronizeQuotaCornerStack()
        } else {
            scheduleQuotaStackHide()
        }
    }

    private func setQuotaStackItemHovered(_ providerID: String, hovering: Bool) {
        if hovering {
            quotaStackHoveredProviderIDs.insert(providerID)
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            synchronizeQuotaCornerStack()
        } else {
            quotaStackHoveredProviderIDs.remove(providerID)
            scheduleQuotaStackHide()
        }
    }

    private func scheduleQuotaStackHide() {
        guard isQuotaStackTriggerHovered == false,
              quotaStackHoveredProviderIDs.isEmpty,
              isQuotaStackPresented,
              quotaStackHideTask == nil else { return }

        quotaStackHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: QuotaCornerStackMotion.hoverGraceDuration)
            } catch {
                return
            }
            guard let self else { return }
            self.quotaStackHideTask = nil
            guard self.isQuotaStackTriggerHovered == false,
                  self.quotaStackHoveredProviderIDs.isEmpty else { return }
            self.hideQuotaCornerStack(animated: true)
        }
    }

    private func openQuotaLimitsFromStack() {
        quotaStackHideTask?.cancel()
        quotaStackHideTask = nil
        isQuotaStackTriggerHovered = false
        quotaStackHoveredProviderIDs.removeAll()
        hideQuotaCornerStack(animated: true)
        model.openQuotaLimits()
    }

    private func showQuotaStackTriggerWindow() {
        quotaStackTriggerWindow.alphaValue = 1
        if quotaStackTriggerWindow.isVisible == false {
            quotaStackTriggerWindow.orderFrontRegardless()
        }
    }

    private func hideQuotaStackTriggerWindow() {
        guard quotaStackTriggerWindow.isVisible else { return }
        quotaStackTriggerWindow.orderOut(nil)
        quotaStackTriggerWindow.alphaValue = 0
    }

    private func showQuotaCornerStack(
        corner: QuotaStackCorner,
        providerIDs: [String],
        targetFrames: [String: NSRect],
        restagger: Bool
    ) {
        quotaStackAnimationGeneration &+= 1
        let generation = quotaStackAnimationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isQuotaStackPresented = true
        let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        for (index, providerID) in providerIDs.enumerated() {
            guard let panel = quotaStackItemWindows[providerID],
                  let targetFrame = targetFrames[providerID] else { continue }

            if panel.isVisible == false {
                panel.alphaValue = reduceMotion ? 0 : QuotaCornerStackMotion.initialAlpha
                panel.setFrame(
                    reduceMotion
                        ? targetFrame
                        : QuotaCornerStackLayout.collapsedFrame(
                            in: screenFrame,
                            corner: corner
                        ),
                    display: true
                )
                panel.orderFrontRegardless()
            } else if restagger == false,
                      panel.alphaValue == 1,
                      panel.frame.equalTo(targetFrame) {
                continue
            }

            let delay = reduceMotion || restagger == false
                ? 0
                : Double(index) * QuotaCornerStackMotion.revealStagger
            Task { @MainActor [weak self, weak panel] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard let self, let panel,
                      self.quotaStackAnimationGeneration == generation,
                      self.isQuotaStackPresented else { return }
                self.animateQuotaStackPanelIn(
                    panel,
                    targetFrame: targetFrame,
                    reduceMotion: reduceMotion
                )
            }
        }
    }

    private func hideQuotaCornerStack(animated: Bool) {
        let wasPresented = isQuotaStackPresented
        isQuotaStackPresented = false
        let visibleItems = quotaStackItemWindows.values.filter(\.isVisible)
        guard visibleItems.isEmpty == false else { return }
        guard animated == false || wasPresented else { return }
        quotaStackAnimationGeneration &+= 1
        let generation = quotaStackAnimationGeneration

        if animated == false {
            for panel in visibleItems {
                panel.orderOut(nil)
                panel.alphaValue = 0
            }
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let corner = quotaStackConfiguration?.corner ?? model.quotaStackCorner
        let providerIDs = quotaStackConfiguration?.providerIDs ?? []
        let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let collapseFrame = QuotaCornerStackLayout.collapsedFrame(
            in: screenFrame,
            corner: corner
        )

        for (reverseIndex, providerID) in providerIDs.reversed().enumerated() {
            guard let panel = quotaStackItemWindows[providerID], panel.isVisible else { continue }
            let delay = reduceMotion
                ? 0
                : Double(reverseIndex) * QuotaCornerStackMotion.hideStagger
            Task { @MainActor [weak self, weak panel] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard let self, let panel,
                      self.quotaStackAnimationGeneration == generation else { return }
                let duration = reduceMotion
                    ? QuotaCornerStackMotion.reducedMotionDuration
                    : QuotaCornerStackMotion.hideDuration
                self.animateQuotaStackPanelOut(
                    panel,
                    collapseFrame: collapseFrame,
                    reduceMotion: reduceMotion,
                    duration: duration
                )
                try? await Task.sleep(for: .seconds(duration + 0.01))
                guard self.quotaStackAnimationGeneration == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func animateQuotaStackPanelIn(
        _ panel: NotchPanel,
        targetFrame: NSRect,
        reduceMotion: Bool
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion
                ? QuotaCornerStackMotion.reducedMotionDuration
                : QuotaCornerStackMotion.revealDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.16,
                1,
                0.3,
                1
            )
            panel.animator().alphaValue = 1
            if reduceMotion {
                panel.setFrame(targetFrame, display: true)
            } else {
                panel.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func animateQuotaStackPanelOut(
        _ panel: NotchPanel,
        collapseFrame: NSRect,
        reduceMotion: Bool,
        duration: TimeInterval
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if reduceMotion == false {
                panel.animator().setFrame(collapseFrame, display: true)
            }
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
