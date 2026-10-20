import AppKit
import Combine
import SwiftUI

@MainActor
struct DockCoordinatorEnvironment {
    var mouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var overlap: (CGRect) -> Bool = { DockWindowPreviewService.hasOverlappingWindow(inAppKitFrame: $0) }
    /// The application whose window fills the screen (native or borderless full screen), if any.
    var fullscreenOwner: (CGRect) -> Int32? = { DockWindowPreviewService.fullscreenOwner(onAppKitScreen: $0) }
    /// Games, playing video and excluded applications keep the edge inert.
    var immersive: (Int32, DockImmersiveContent.Options) -> Bool = { DockImmersiveContent.isImmersive(pid: $0, options: $1) }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Fallback for Spaces where WindowServer delivers no mouse-moved events to monitors.
    var edgePollInterval: Duration = .milliseconds(120)
    /// Video starts and pauses without any Space or activation notification.
    var immersivePollInterval: Duration = .milliseconds(1_500)
    /// Full-screen transitions finish after the Space notification; sample once more afterwards.
    var fullscreenSettleDelay: Duration = .milliseconds(800)
    var hideDelay: Duration = .milliseconds(650)
    /// How long the pointer rests on the edge before an auto-hidden Dock appears; zero is immediate.
    var revealDelay: Duration = .milliseconds(220)
    var notificationCenter: NotificationCenter = .default
    var workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    var installEventMonitors = true
    /// Screen geometry; screen notifications that leave it unchanged are ignored.
    var screenSignature: () -> [CGRect] = { DockWindowCoordinator.screenSignature() }
    var screenChangeDelay: Duration = .milliseconds(120)
    /// Genie show/hide; off in tests that assert window visibility synchronously.
    var animatesVisibility = true
}

private final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DockPresentation: ObservableObject {
    @Published var width: CGFloat = 700
    @Published var height: CGFloat = DockLayout.height(scale: 1)
    @Published var recovering = false
    /// Edge the strip sits on inside a panel that also has headroom.
    @Published var alignment: Alignment = .center
}

/// Owns the panel frame and its small edge trigger. Hosting content never
/// resizes a window; app-level system Dock ownership is serialized separately.
@MainActor
final class DockWindowCoordinator {
    let feature: DockFeatureModel
    private let model: NotchViewModel
    private let environment: DockCoordinatorEnvironment
    private let panel: DockPanel
    private let trigger: DockPanel
    private let presentation = DockPresentation()
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [NSObjectProtocol] = []
    private var workspaceObservations: [NSObjectProtocol] = []
    private var menuIDs: Set<ObjectIdentifier> = []
    private var localMonitor: Any?
    private var mouseUpMonitor: Any?
    private var hideTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var overlapTimer: Timer?
    private var started = false
    private var sleeping = false
    private var hovered = false
    private var interacting = false
    private var revealed = false
    private var overlapped = false
    private var overlapNeedsRefresh = true
    private var fullscreenOwner: Int32?
    private var immersive = false
    private var fullscreenNeedsRefresh = true
    private var fullscreenRecheck: Task<Void, Never>?
    private var immersiveMonitor: Task<Void, Never>?
    private var edgePoll: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var fullscreen: Bool { fullscreenOwner != nil }
    private var pointerMonitors: [Any] = []
    private var lastVisibilityMode: DockVisibilityMode?
    private var hasRecovered = false
    private var requestedSystemState: Bool?
    private var targetFrame: CGRect?
    private let hotKey = DockHotKey()
    private var screenChangeTask: Task<Void, Never>?
    private let genie = DockGenieAnimator()
    /// Visible and not collapsing: a hiding Dock already counts as hidden for the edge strip.
    private var panelShown: Bool { panel.isVisible && !genie.isHiding }
    private var animatesVisibility: Bool {
        environment.animatesVisibility && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var screenSignature: [CGRect] = []
    private var synchronizing = false
    private var isPresenting = false
    var ownedPanel: NSPanel { panel }
    var ownedTrigger: NSPanel { trigger }

    init(feature: DockFeatureModel, model: NotchViewModel,
         environment: DockCoordinatorEnvironment = .init()) {
        self.feature = feature
        self.model = model
        self.environment = environment
        screenSignature = environment.screenSignature()
        panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        trigger = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel, title: "NooL Dock")
        configure(trigger, title: "Показать NooL Dock")
        let host = NSHostingView(rootView: DockHostedView(
            feature: feature, model: model, presentation: presentation,
            interactionChanged: { [weak self] in self?.setInteracting($0) },
            hoverChanged: { [weak self] in self?.setHovered($0) }))
        host.sizingOptions = []
        panel.contentView = DockGenieContainerView(content: host)
        // The edge strip never accepts clicks: other applications keep their bottom
        // pixels. Reveal is driven by pointer-move monitors instead.
        trigger.ignoresMouseEvents = true
        trigger.contentView = NSView()
        feature.prefs.onChange = { [weak self] in self?.synchronize() }
        feature.onRestoreSystemDock = { [weak self] in
            Task { @MainActor [weak self] in _ = await self?.restoreSystemDock() }
        }
        hotKey.onPress = { [weak self] in
            guard let self, self.started else { return }
            self.feature.prefs.toggleAutoHide()
        }
        feature.accessibility.$minimizedWindows.removeDuplicates { $0.map(\.id) == $1.map(\.id) }.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        feature.applications.$running.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        feature.systemDock.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        model.modules.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        // Recovery is app-wide, including when the Dock module is disabled.
        queueSystemState(false)
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        synchronize()
    }

    func stop() {
        started = false
        cancelPendingReveal()
        screenChangeTask?.cancel()
        screenChangeTask = nil
        cancelScheduledHide()
        overlapTimer?.invalidate()
        overlapTimer = nil
        fullscreenRecheck?.cancel()
        fullscreenRecheck = nil
        immersiveMonitor?.cancel()
        immersiveMonitor = nil
        edgePoll?.cancel()
        edgePoll = nil
        feature.closeSurfaces()
        feature.stacks.stop()
        feature.applications.stop()
        feature.setActive(false)
        hotKey.stop()
        isPresenting = false
        feature.previews.cancel()
        observations.forEach { environment.notificationCenter.removeObserver($0) }
        observations.removeAll()
        workspaceObservations.forEach { environment.workspaceNotificationCenter.removeObserver($0) }
        workspaceObservations.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        menuIDs.removeAll()
        hovered = false
        interacting = false
        revealed = false
        sleeping = false
        overlapped = false
        overlapNeedsRefresh = true
        fullscreenOwner = nil
        immersive = false
        fullscreenNeedsRefresh = true
        lastVisibilityMode = nil
        genie.cancel(panel.contentView)
        panel.orderOut(nil)
        trigger.orderOut(nil)
        model.setDockWidgets(musicVisible: false, calendarEnabled: false)
        queueSystemState(false)
        synchronize()
    }

    func waitForRestoration() async { await systemTask?.value }

    func restoreSystemDock() async -> Bool {
        requestedSystemState = false
        let previous = systemTask
        let controller = feature.systemDock
        systemTask = Task { @MainActor in
            await previous?.value
            await controller.restore()
        }
        await systemTask?.value
        return !controller.isActive && !controller.recoveryPending && controller.errorMessage == nil
    }

    func reposition() {
        targetFrame = nil
        overlapNeedsRefresh = true
        fullscreenNeedsRefresh = true
        synchronize()
    }

    /// Pointer position in AppKit screen coordinates. Reveals a hidden Dock when the
    /// pointer reaches its edge strip; the strip itself is click-through.
    func pointerMoved(to location: CGPoint) {
        guard started, trigger.isVisible, !panelShown else { cancelPendingReveal(); return }
        guard isOnTrigger(location) else { cancelPendingReveal(); return }
        let delay = environment.revealDelay
        guard delay > .zero else { reveal(); return }
        // Like the system Dock, a pointer passing through the edge does not pop the Dock up.
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.revealTask = nil
            guard self.started, self.trigger.isVisible, !self.panelShown,
                  self.isOnTrigger(self.environment.pointerLocation()) else { return }
            self.reveal()
        }
    }

    /// Inclusive bounds: the pointer rests exactly on the screen's bottom row.
    private func isOnTrigger(_ location: CGPoint) -> Bool {
        let strip = trigger.frame
        return location.x >= strip.minX && location.x <= strip.maxX
            && location.y >= strip.minY && location.y <= strip.maxY
    }

    private func cancelPendingReveal() {
        revealTask?.cancel()
        revealTask = nil
    }

    private func configure(_ window: NSPanel, title: String) {
        window.title = title
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func synchronize() {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        let enabled = started && feature.prefs.isEnabled && model.modules.isEnabled(.dock)
        guard enabled, !sleeping, let screen = selectedScreen() else {
            cancelScheduledHide()
            overlapTimer?.invalidate()
            overlapTimer = nil
            immersiveMonitor?.cancel()
            immersiveMonitor = nil
            edgePoll?.cancel()
            edgePoll = nil
            genie.cancel(panel.contentView)
            panel.orderOut(nil)
            trigger.orderOut(nil)
            feature.fan.dismiss()
            if !enabled {
                resetInteractionState()
                if isPresenting {
                    isPresenting = false
                    feature.closeSurfaces()
                    feature.applications.stop()
                }
                feature.setActive(false)
                hotKey.setEnabled(false)
                queueSystemState(false)
                // Keep a visible recovery action until macOS Dock is restored,
                // including when its preference write/restart reports failure.
                if feature.systemDock.isActive || feature.systemDock.recoveryPending,
                   !sleeping, let screen = selectedScreen() {
                    presentation.recovering = true
                    // Recovery borrows the panel; the next Dock layout must set its frame again.
                    targetFrame = nil
                    presentation.width = 360
                    presentation.height = 76
                    presentation.alignment = .center
                    let frame = CGRect(x: screen.frame.midX - 180, y: screen.frame.minY + 8,
                                       width: 360, height: 76)
                    panel.setFrame(frame, display: true)
                    panel.orderFrontRegardless()
                }
            }
            model.setDockWidgets(musicVisible: false, calendarEnabled: false)
            return
        }
        if presentation.recovering { presentation.recovering = false; targetFrame = nil }
        isPresenting = true
        feature.applications.start()
        let prefs = feature.prefs
        feature.setActive(true)
        hotKey.setEnabled(prefs.hideHotKeyEnabled)
        if fullscreenNeedsRefresh {
            fullscreenOwner = environment.fullscreenOwner(screen.frame)
            immersive = fullscreenOwner.map { environment.immersive($0, feature.immersiveOptions) } ?? false
            fullscreenNeedsRefresh = false
        }
        // A full-screen application behaves like the system Dock: hidden until the edge is reached.
        // A full-screen game or playing video keeps it hidden; the edge does not summon it.
        let mode: DockVisibilityMode = fullscreen ? .autoHide : prefs.visibility
        let scale = prefs.scale
        let position = prefs.position
        let others = feature.unpinnedApplications.count + feature.recentApplications.count
        let spans = prefs.items.map(\.span) + Array(repeating: 1, count: others)
        let contentWidth = DockLayout.stripLength(spans: spans, separators: !prefs.items.isEmpty && others > 0 ? 1 : 0,
                                                  trailingCells: feature.trailingCellCount, scale: scale,
                                                  showLabels: prefs.showAppLabels, vertical: position.isVertical)
        let frame = DockLayout.frame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                     contentWidth: contentWidth, scale: scale,
                                     replacingSystemDock: feature.systemDock.isActive || fullscreen,
                                     showLabels: prefs.showAppLabels, position: position)
        if frame != targetFrame {
            overlapNeedsRefresh = true
            targetFrame = frame
            presentation.width = frame.width
            presentation.height = frame.height
            presentation.alignment = switch position {
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            }
            feature.availableWidth = position.isVertical ? frame.height : frame.width
            feature.dockFrame = frame
            panel.setFrame(DockLayout.windowFrame(strip: frame, position: position, scale: scale), display: true)
            let triggerBounds = feature.systemDock.isActive || fullscreen ? screen.frame : screen.visibleFrame
            trigger.setFrame(DockLayout.triggerFrame(screenFrame: triggerBounds, dockFrame: frame, position: position),
                             display: true)
        }
        if mode == .intelligent {
            if overlapNeedsRefresh || lastVisibilityMode != .intelligent {
                overlapped = environment.overlap(frame)
                overlapNeedsRefresh = false
            }
        } else { overlapped = false }
        lastVisibilityMode = mode
        // A pressed button retains an already visible Dock during drag. A click elsewhere
        // must not reveal an otherwise hidden Dock on every mouse-down.
        let held = hovered || interacting || !menuIDs.isEmpty
            || (panel.isVisible && environment.mouseButtons() != 0)
        if mode != .always, held { revealed = true }
        let shouldShow = immersive ? held
            : mode == .always || revealed || held || (mode == .intelligent && !overlapped)
        if immersive { revealed = held }
        if shouldShow {
            trigger.orderOut(nil)
            if !panel.isVisible {
                genie.show(panel.contentView, position: position, animated: animatesVisibility)
                panel.orderFrontRegardless()
                feature.accessibility.refreshNow()
            } else if genie.isHiding {
                genie.show(panel.contentView, position: position, animated: animatesVisibility)
            }
        } else {
            if panel.isVisible {
                genie.hide(panel.contentView, position: position, animated: animatesVisibility) { [weak self] in
                    self?.panel.orderOut(nil)
                    self?.updateEdgePolling()
                }
            }
            feature.fan.dismiss()
            if immersive { trigger.orderOut(nil) }
            else if !trigger.isVisible { trigger.orderFrontRegardless() }
        }
        let integrationIDs = Set(prefs.items.compactMap(\.integrationID))
        model.setDockWidgets(musicVisible: shouldShow && integrationIDs.contains("music"),
                             calendarEnabled: integrationIDs.contains("calendar"))
        updateOverlapMonitoring(mode: mode)
        updateImmersiveMonitoring()
        updateEdgePolling()
        // Only after the new panel has a real screen/frame is hiding macOS Dock allowed.
        queueSystemState(prefs.replaceSystemDock)
        if mode != .always, shouldShow { scheduleHide() }
        else { cancelScheduledHide() }
    }

    private var effectiveVisibility: DockVisibilityMode {
        fullscreen ? .autoHide : feature.prefs.visibility
    }

    private func selectedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let displays = screens.compactMap { screen -> (id: UInt32, uuid: String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, Self.uuid(for: screen))
        }
        guard let selected = DockLayout.selectedDisplayID(preferredUUID: feature.prefs.displayUUID,
                                                          displays: displays, primaryID: CGMainDisplayID()) else { return nil }
        return screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selected
        }
    }

    static func uuid(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func queueSystemState(_ desired: Bool) {
        guard requestedSystemState != desired else { return }
        requestedSystemState = desired
        let previous = systemTask
        systemTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if !self.hasRecovered {
                await self.feature.systemDock.recoverIfNeeded()
                self.hasRecovered = true
            }
            // Re-read intent after the earlier transition: a queued enable may
            // have been superseded by module stop while a Process was running.
            let nowDesired = self.requestedSystemState == true && self.started
                && self.feature.prefs.isEnabled && self.model.modules.isEnabled(.dock)
            await self.feature.systemDock.setEnabled(nowDesired)
            self.targetFrame = nil
            self.synchronize()
        }
    }

    private func installObservers() {
        let center = environment.notificationCenter
        observations.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        })
        observations.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            let menuID = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard let self,
                      self.hovered || self.interacting || !self.menuIDs.isEmpty else { return }
                self.menuIDs.insert(menuID)
                self.revealed = true
                self.cancelScheduledHide()
            }
        })
        observations.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            let menuID = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuIDs.remove(menuID)
                self.scheduleHide()
            }
        })
        let workspace = environment.workspaceNotificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = true
                    self?.feature.closeSurfaces()
                    self?.resetInteractionState()
                    self?.synchronize()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = false
                    self?.desktopDidChange()
                }
            })
        }
        workspaceObservations.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.desktopDidChange()
                self?.scheduleFullscreenRecheck()
            }
        })
        // Switching between a full-screen and a regular application can happen on one Space.
        workspaceObservations.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFullscreenRecheck() }
        })
        guard environment.installEventMonitors else { return }
        // Mouse-move monitoring needs no Accessibility permission; key events are not observed globally.
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents, handler: { [weak self] event in
            self?.pointerMoved(to: NSEvent.mouseLocation)
            return event
        }) { pointerMonitors.append(monitor) }
        // Popovers of a non-activating panel never see clicks in other applications, and the
        // fan is its own window: a click anywhere outside the Dock's windows closes them.
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            if let self, !self.ownsWindow(event.window) { self.clickedOutside() }
            return event
        }) { pointerMonitors.append(monitor) }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown { self.scheduleHide(); return event }
            // Floating editors own text focus; never intercept another app's keys.
            if event.keyCode == 53, self.interacting {
                self.feature.closeSurfaces()
                return nil
            }
            if self.interacting, let editor = event.window?.firstResponder as? NSTextView,
               let action = TextEditingAction(event: event) {
                action.perform(in: editor)
                return nil
            }
            return event
        }
    }

    /// Closes stacks, folders, previews and the fan; the Dock itself then follows its hide policy.
    func clickedOutside() {
        guard started, interacting || feature.fan.presentedID != nil else { return }
        feature.closeSurfaces()
        scheduleHide()
    }

    /// The Dock panel, its popovers (child windows, possibly nested) and the fan window.
    func ownsWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === panel || window === trigger || window === feature.fan.window { return true }
        // NSPopover hosts its content in a private window class attached to the Dock panel.
        if String(describing: type(of: window)).contains("Popover") { return true }
        var parent = window.parent
        while let current = parent {
            if current === panel || current === feature.fan.window { return true }
            parent = current.parent
        }
        return false
    }

    /// Samples immediately, then once more after the full-screen animation settles.
    private func scheduleFullscreenRecheck() {
        fullscreenNeedsRefresh = true
        synchronize()
        fullscreenRecheck?.cancel()
        let delay = environment.fullscreenSettleDelay
        fullscreenRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.started else { return }
            self.fullscreenRecheck = nil
            self.fullscreenNeedsRefresh = true
            self.synchronize()
        }
    }

    /// While an application is full screen, re-check whether it plays video. Cheap: one
    /// power-assertion snapshot per interval, no window list or screenshots.
    private func updateImmersiveMonitoring() {
        guard let owner = fullscreenOwner else {
            immersiveMonitor?.cancel()
            immersiveMonitor = nil
            return
        }
        guard immersiveMonitor == nil else { return }
        let interval = environment.immersivePollInterval
        immersiveMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.started, !self.sleeping else { return }
                guard self.fullscreenOwner == owner else {
                    self.immersiveMonitor = nil
                    self.updateImmersiveMonitoring()
                    return
                }
                let value = self.environment.immersive(owner, self.feature.immersiveOptions)
                if value != self.immersive {
                    self.immersive = value
                    self.synchronize()
                }
            }
        }
    }

    /// While the Dock is hidden behind its edge strip, sample the pointer a few times per second.
    private func updateEdgePolling() {
        guard trigger.isVisible, !panelShown else {
            edgePoll?.cancel()
            edgePoll = nil
            return
        }
        guard edgePoll == nil else { return }
        let interval = environment.edgePollInterval
        edgePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.pointerMoved(to: self.environment.pointerLocation())
            }
        }
    }

    /// The revealed panel plus the strip below it: a pointer resting on the screen edge keeps the Dock.
    private func pointerIsInDockZone() -> Bool {
        guard panel.isVisible, let frame = targetFrame else { return false }
        let zone = frame.union(trigger.frame)
        let point = environment.pointerLocation()
        return point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
    }

    private func updateOverlapMonitoring(mode: DockVisibilityMode) {
        guard mode == .intelligent else {
            overlapTimer?.invalidate()
            overlapTimer = nil
            overlapped = false
            return
        }
        guard overlapTimer == nil else { return }
        // Cheap geometry-only reconciliation, never screenshots or app discovery.
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = self.targetFrame, self.started, !self.sleeping else { return }
                let overlap = self.environment.overlap(frame)
                if self.overlapped != overlap {
                    self.overlapped = overlap
                    self.synchronize()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlapTimer = timer
    }

    func reveal() {
        cancelPendingReveal()
        cancelScheduledHide()
        revealed = true
        synchronize()
    }

    func setHovered(_ value: Bool) {
        // SwiftUI may deliver an old surface's enter callback after a Space/screen transition
        // has already hidden it. Only the live panel or its edge trigger can initiate a reveal.
        guard !value || panel.isVisible else { return }
        hovered = value
        if value {
            revealed = true
            cancelScheduledHide()
        } else { scheduleHide() }
        synchronize()
    }

    func setInteracting(_ value: Bool) {
        guard !value || panel.isVisible else { return }
        interacting = value
        if value {
            revealed = true
            cancelScheduledHide()
        }
        synchronize()
    }

    private func resetInteractionState() {
        cancelScheduledHide()
        menuIDs.removeAll()
        hovered = false
        interacting = false
        revealed = false
    }

    /// Spaces/fullscreen/display changes invalidate geometry and transient interaction ownership.
    /// They never wake a sleeping system, and overlap is sampled before any new orderFront.
    /// WindowServer repeats this notification for colour and gamma updates too (for example
    /// software dimming), sometimes many times a second. Only real geometry changes reset the
    /// Dock; a burst is coalesced into one check.
    private func screenParametersDidChange() {
        guard screenChangeTask == nil else { return }
        screenChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.environment.screenChangeDelay ?? .zero)
            guard let self, !Task.isCancelled else { return }
            self.screenChangeTask = nil
            let signature = self.environment.screenSignature()
            guard signature != self.screenSignature else { return }
            self.screenSignature = signature
            self.desktopDidChange()
        }
    }

    static func screenSignature() -> [CGRect] {
        NSScreen.screens.flatMap { [$0.frame, $0.visibleFrame, CGRect(x: $0.backingScaleFactor, y: 0, width: 0, height: 0)] }
    }

    private func desktopDidChange() {
        screenSignature = environment.screenSignature()
        resetInteractionState()
        targetFrame = nil
        overlapNeedsRefresh = true
        fullscreenNeedsRefresh = true
        feature.closeSurfaces()
        synchronize()
    }

    private func cancelScheduledHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide() {
        let mode = effectiveVisibility
        guard mode != .always, panel.isVisible,
              revealed || mode == .autoHide || overlapped,
              DockLayout.canHide(hovered: hovered, interacting: interacting || !menuIDs.isEmpty,
                                 mouseButtons: environment.mouseButtons()) else {
            cancelScheduledHide()
            return
        }
        guard hideTask == nil else { return }
        let delay = environment.hideDelay
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            if self.started, self.pointerIsInDockZone() {
                self.scheduleHide()
                return
            }
            guard self.started,
                  DockLayout.canHide(hovered: self.hovered,
                                     interacting: self.interacting || !self.menuIDs.isEmpty,
                                     mouseButtons: self.environment.mouseButtons()) else { return }
            self.revealed = false
            self.synchronize()
        }
    }
}

private struct DockHostedView: View {
    @ObservedObject var feature: DockFeatureModel
    let model: NotchViewModel
    @ObservedObject var presentation: DockPresentation
    let interactionChanged: (Bool) -> Void
    let hoverChanged: (Bool) -> Void
    var body: some View {
        Group {
            if presentation.recovering {
                DockRecoveryView(controller: feature.systemDock, restore: feature.restoreSystemDock)
            } else {
                DockView(feature: feature, model: model, interactionChanged: interactionChanged,
                         hoverChanged: hoverChanged)
            }
        }.frame(width: presentation.width, height: presentation.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: presentation.alignment)
    }
}

private struct DockRecoveryView: View {
    @ObservedObject var controller: SystemDockController
    let restore: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dock.rectangle").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Системный Dock").font(.headline)
                Text(controller.isBusy ? "Восстановление…" : "Не удалось восстановить")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Вернуть", action: restore)
                .disabled(controller.isBusy)
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .preferredColorScheme(.dark)
        .help(controller.errorMessage ?? "Возврат исходных настроек Dock macOS")
    }
}
