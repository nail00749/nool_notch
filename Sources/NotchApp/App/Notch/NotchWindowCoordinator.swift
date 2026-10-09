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
    private let moduleRuntime: AppModuleRuntime
    private var moduleChanges: AnyCancellable?
    private let window: NotchPanel
    private let presentation: NotchWindowPresentation
    private let quotaEdgeCoordinator: QuotaEdgeWindowCoordinator
    private let quotaStackCoordinator: QuotaStackWindowCoordinator
    private let settingsCoordinator: SettingsWindowCoordinator
    private let model: NotchViewModel
    private let visualSettings: NotchVisualSettings
    private let customizationSettings: NotchCustomizationSettings
    private let displaySettings: NotchDisplaySettings
    private let launchAtLogin: LaunchAtLoginManager
    private let dockSettings: NoolDockSettings
    private let lidEffect = LidEffectController()
    private let systemMonitor = SystemMonitorStore()
    private var systemMonitorWindow: SystemMonitorWindowCoordinator?
    private var dock: NoolDockWindowCoordinator?
    private let fileActions = FileActionsWindowCoordinator()
    private let textRecognition = TextRecognitionWindowCoordinator()
    private let screenTextCapture = ScreenTextCaptureCoordinator()
    private var lastLayoutWasExpanded = false
    private var targetWindowFrame: NSRect?
    private var layoutAnimationGeneration = 0
    private var applicationBeforeSearch: NSRunningApplication?
    private var displayFollowTimer: Timer?
    private var modelChanges: AnyCancellable?
    private var customizationChanges: AnyCancellable?
    private(set) var isStarted = false
    private var isTerminated = false

    init(launcher: LauncherWindowCoordinator) {
        self.launcher = launcher
        moduleRuntime = AppModuleRuntime(store: launcher.model.modules)
        let quotaDelivery = SystemQuotaAlertDelivery()
        model = NotchViewModel(
            aiSessionStore: AISessionStore(
                sources: [
                    CodexDesktopSessionSource(),
                    LocalAgentSessionSource()
                ]
            ),
            widgetPublisher: QuotaWidgetPublisher.makeIfAvailable(),
            quotaAlerts: QuotaAlertController(delivery: quotaDelivery),
            modules: launcher.model.modules
        )
        visualSettings = NotchVisualSettings()
        customizationSettings = .shared
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
        presentation = NotchWindowPresentation(size: size)
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
            customizationSettings: customizationSettings,
            displaySettings: displaySettings,
            launchAtLogin: launchAtLogin,
            launcher: launcher,
            dockSettings: dockSettings,
            lidEffect: lidEffect,
            systemMonitor: systemMonitor
        )

        super.init()
        systemMonitorWindow = SystemMonitorWindowCoordinator(
            store: systemMonitor,
            displaySettings: displaySettings,
            occupiedFrames: { [weak self] in self?.reservedQuotaFrames() ?? [] },
            openSettings: { [weak self] in self?.showSettingsWindow(section: .systemMonitor) }
        )
        quotaDelivery.onOpenLimits = { [weak self] in self?.model.openQuotaLimits() }
        launcher.model.connectNoolSearch(to: model)
        model.onOpenFileActions = { [weak self] urls in
            guard let self, self.isStarted, self.model.modules.isEnabled(.fileShelf) else { return }
            self.model.isExpanded = false
            self.fileActions.show(urls: urls, shelf: self.model.fileShelfStore)
        }
        launcher.onProcessFiles = { [weak self] urls, kind in
            guard let self, self.isStarted, self.model.modules.isEnabled(.fileShelf) else { return }
            self.fileActions.show(urls: urls, shelf: self.model.fileShelfStore, initialKind: kind)
        }
        let recognize: ([URL]) -> Void = { [weak self, weak launcher] urls in
            guard let self, self.isStarted, self.model.modules.isEnabled(.textRecognition) else { return }
            self.model.isExpanded = false
            self.textRecognition.show(urls: urls) { [weak launcher] text, prompt in
                launcher?.prepareTextRecognitionDraft(text, prompt: prompt) ?? false
            }
        }
        model.onRecognizeText = recognize
        launcher.onRecognizeText = recognize
        launcher.onCaptureScreenText = { [weak self, weak launcher] in
            guard let self, self.isStarted, self.model.modules.isEnabled(.textRecognition) else { return }
            self.model.isExpanded = false
            self.model.isCompactHovered = false
            self.screenTextCapture.start(
                onCapture: { [weak self, weak launcher] data in
                    guard let self, self.isStarted, self.model.modules.isEnabled(.textRecognition) else { return }
                    self.textRecognition.show(imageData: data) { [weak launcher] text, prompt in
                        launcher?.prepareTextRecognitionDraft(text, prompt: prompt) ?? false
                    }
                },
                onFailure: { [weak self, weak launcher] message in
                    guard self?.isStarted == true else { return }
                    launcher?.show()
                    launcher?.model.message = message
                },
                onCancel: { [weak self, weak launcher] in
                    guard self?.isStarted == true else { return }
                    launcher?.show()
                }
            )
        }
        dock = NoolDockWindowCoordinator(
            settings: dockSettings,
            model: model,
            openSettings: { [weak self] in self?.showSettingsWindow(section: .dock) },
            openLauncher: { [weak launcher] in launcher?.show() }
        )

        let contentView = NotchRootView(
            model: model,
            presentation: presentation,
            visualSettings: visualSettings,
            displaySettings: displaySettings,
            customizationSettings: customizationSettings,
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
        // The notch stays black; native controls must remain readable in light app themes.
        window.appearance = NSAppearance(named: .darkAqua)
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
        configureModuleRuntime()
    }

    private func configureModuleRuntime() {
        moduleRuntime.register(.quotas, start: { [weak self] in
            self?.quotaEdgeCoordinator.start()
            self?.quotaStackCoordinator.start()
        }, stop: { [weak self] in
            self?.quotaEdgeCoordinator.stop()
            self?.quotaStackCoordinator.stop()
        })
        moduleRuntime.register(.systemMonitor, start: { [weak self] in
            self?.systemMonitorWindow?.start()
        }, stop: { [weak self] in self?.systemMonitorWindow?.stop() })
        moduleRuntime.register(.dock, start: { [weak self] in self?.dock?.start() },
                               stop: { [weak self] in self?.dock?.stop() })
        moduleRuntime.register(.lidEffect, start: { [weak self] in self?.lidEffect.start() },
                               stop: { [weak self] in self?.lidEffect.pause() })
        moduleRuntime.register(.textRecognition, start: {}, stop: { [weak self] in
            self?.screenTextCapture.cancel()
            self?.textRecognition.stop()
        })
        moduleRuntime.register(.fileShelf, start: {}, stop: { [weak self] in self?.fileActions.stop() })
    }

    func show() {
        guard !isTerminated else { return }
        guard !isStarted else {
            window.orderFrontRegardless()
            synchronizeQuotaPresentation()
            return
        }
        isStarted = true
        if visualSettings.showsExpandedMascot { NoolWavingMascot.prepareAsset() }
        model.timerSource.onCompletion = {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStarted else { return }
                self.synchronizeQuotaPresentation()
            }
        }
        customizationChanges = customizationSettings.layoutChanges
            .sink { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isStarted else { return }
                    self.reposition()
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
        moduleRuntime.start()
        moduleChanges = model.modules.changes.sink { [weak self] _ in
            guard let self, self.isStarted else { return }
            self.dock?.reposition()
            self.synchronizeQuotaPresentation()
        }
    }

    func stop() {
        guard !isTerminated else { return }
        isTerminated = true
        isStarted = false
        layoutAnimationGeneration += 1
        moduleChanges = nil
        moduleRuntime.stop()
        modelChanges?.cancel()
        modelChanges = nil
        customizationChanges?.cancel()
        customizationChanges = nil
        displayFollowTimer?.invalidate()
        displayFollowTimer = nil
        displaySettings.onConfigurationChange = nil
        model.timerSource.onCompletion = nil
        quotaEdgeCoordinator.stop()
        quotaStackCoordinator.stop()
        systemMonitorWindow?.stop()
        settingsCoordinator.stop()
        lidEffect.stop()
        fileActions.stop()
        screenTextCapture.cancel()
        launcher.onCaptureScreenText = nil
        textRecognition.stop()
        dock?.stop()
        model.stop()
        window.orderOut(nil)
        applicationBeforeSearch = nil
    }

    func waitForFileActions() async { await fileActions.waitForCompletion() }

    func waitForQuotaWidgetPersistence() async { await model.waitForQuotaWidgetPersistence() }
    func saveScratchpadBeforeTermination() async -> Bool {
        await model.scratchpad.flush()
        return !model.scratchpad.hasUnsavedChanges
    }
    func waitForLidEffect() async { await lidEffect.waitForStop() }

    func openWidgetLimits() {
        model.openQuotaLimits()
    }

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
        layoutAnimationGeneration += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentation.size = size
            presentation.mountsExpandedContent = model.isExpanded
            model.expansionSurfaceSettled = model.isExpanded
        }
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
        if !isExpanded || !wasExpanded { model.expansionSurfaceSettled = false }

        guard targetWindowFrame != frame else { return }
        targetWindowFrame = frame
        layoutAnimationGeneration += 1
        let generation = layoutAnimationGeneration

        guard reduceMotion == false else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                presentation.size = size
                presentation.mountsExpandedContent = isExpanded
            }
            window.setFrame(frame, display: true)
            model.expansionSurfaceSettled = isExpanded
            return
        }

        // No per-frame NSWindow resize: resizing the host and rendering SwiftUI
        // on separate clocks produces visible judder even with identical easing.
        window.setFrame(NotchWindowEnvelope.frame(containing: window.frame, target: frame), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let animation: Animation
        if !isExpanded && !wasExpanded {
            animation = NotchMotion.compactResizeAnimation(reduceMotion: false)
        } else if isExpanded && wasExpanded {
            animation = .easeInOut(duration: NotchMotion.panelChangeDuration)
        } else {
            animation = NotchMotion.layoutAnimation(isExpanded: isExpanded, reduceMotion: false)
        }
        withAnimation(animation, completionCriteria: .removed) {
            presentation.size = size
        } completion: { [weak self] in
            guard let self, self.isStarted,
                  self.layoutAnimationGeneration == generation,
                  self.model.isExpanded == isExpanded else { return }
            self.window.setFrame(frame, display: true)
            self.model.expansionSurfaceSettled = isExpanded
            // Construct/destroy heavy panel trees only after the geometry stops.
            self.presentation.mountsExpandedContent = isExpanded
        }
    }

    private func targetWindowSize(isExpanded: Bool? = nil) -> NSSize {
        NotchWindowSizingPolicy.panelSize(
            metrics: displaySettings.activeMetrics,
            isExpanded: isExpanded ?? model.isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: model.isShowingSettings,
            compactHeight: displaySettings.effectiveCompactHeight(
                fallback: visualSettings.compactHeight
            ),
            isPlaying: usesWideCompactLayout,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered,
            expandedWidth: customizationSettings.expandedWidth,
            maxExpandedHeight: customizationSettings.maxExpandedHeight,
            hasSideControls: customizationSettings.quickActions.contains { $0.placement != .bottom },
            activeUtility: model.activeUtility
        )
    }

    private var usesWideCompactLayout: Bool {
        let isPlaying = model.modules.isEnabled(.music)
            && model.nowPlayingSnapshot?.playbackState.isPlaying == true
        let showsQuota = customizationSettings.showsQuotaIndicator
            && model.modules.isEnabled(.quotas)
            && model.compactQuotaDisplayMode == .top
            && (isPlaying || customizationSettings.showsQuotaWhenIdle)
        return model.compactMeetingReminder != nil
            || model.compactTimer != nil
            || model.hasCompactLiveActivity
            || (isPlaying && customizationSettings.showsMusicIndicator)
            || showsQuota
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
        systemMonitorWindow?.synchronize()
    }

    private func reservedQuotaFrames() -> [CGRect] {
        guard let screen = displaySettings.activeScreen ?? displaySettings.selectedScreen() else { return [] }
        if model.shouldEnableQuotaEdgePanel {
            let rail = QuotaEdgePanelLayout.railFrame(in: screen.frame, edge: model.quotaPanelEdge,
                                                     providerCount: model.visibleQuotaProviders.count)
            let detailWidth = QuotaEdgePanelLayout.detailWindowSize.width + QuotaEdgePanelLayout.detailGap
            return [CGRect(x: model.quotaPanelEdge == .left ? rail.minX : rail.minX - detailWidth,
                           y: rail.minY, width: rail.width + detailWidth, height: rail.height)]
        }
        if model.shouldEnableQuotaCornerStack {
            return model.visibleQuotaProviders.indices.map {
                QuotaCornerStackLayout.itemFrame(in: screen.frame, corner: model.quotaStackCorner, index: $0)
            }
        }
        return []
    }

    private static func origin(for screen: NSScreen?, size: NSSize) -> NSPoint {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        )
    }
}
