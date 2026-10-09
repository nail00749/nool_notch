import AppKit
import SwiftUI

struct SystemMonitorOverlayLayout: Equatable {
    let trigger: CGRect
    let rail: CGRect
    let items: [CGRect]
    let edge: QuotaPanelEdge
    let corner: QuotaStackCorner

    var collapsedStackFrame: CGRect {
        CGRect(x: edge == .left ? trigger.minX : trigger.maxX - QuotaCornerStackLayout.itemWidth,
               y: corner.isTop ? trigger.maxY - QuotaCornerStackLayout.itemHeight : trigger.minY,
               width: QuotaCornerStackLayout.itemWidth, height: QuotaCornerStackLayout.itemHeight)
    }
}

enum SystemMonitorLayout {
    /// Same dimensions and fan as AI quotas. Reserve the full footprint while hidden,
    /// so the trigger does not jump when either overlay is revealed.
    static func overlays(in screenFrame: CGRect, visibleFrame: CGRect,
                         preferences: SystemMonitorPreferences, avoiding occupied: [CGRect] = []) -> SystemMonitorOverlayLayout {
        let count = preferences.metrics.count
        let isTop = preferences.position.isTop
        // Corner stacks are anchored to the physical screen, just like AI limits.
        // Dock/menu-bar insets only constrain the sidebar.
        let placementBounds = preferences.style == .stack ? screenFrame : visibleFrame
        var fallback: SystemMonitorOverlayLayout?
        for left in [preferences.position.isLeft, !preferences.position.isLeft] {
            let edge: QuotaPanelEdge = left ? .left : .right
            let corner: QuotaStackCorner = isTop ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
            let rail = QuotaEdgePanelLayout.railFrame(in: screenFrame, edge: edge, providerCount: count)
            let items = (0..<count).map {
                QuotaCornerStackLayout.itemFrame(in: screenFrame, corner: corner, index: $0)
            }
            let footprint: CGRect
            if preferences.style == .sidebar {
                let detailWidth = QuotaEdgePanelLayout.detailWindowSize.width + QuotaEdgePanelLayout.detailGap
                footprint = CGRect(x: left ? rail.minX : rail.minX - detailWidth,
                                   y: rail.minY, width: rail.width + detailWidth, height: rail.height)
            } else {
                footprint = items.reduce(CGRect.null) { $0.union($1) }
            }
            let minimumY = placementBounds.minY + 8
            let maximumY = max(minimumY, placementBounds.maxY - footprint.height - 8)
            let baseY = min(max(footprint.minY, minimumY), maximumY)
            var alternatives: [CGFloat] = []
            for obstacle in occupied {
                alternatives.append(obstacle.minY - footprint.height - 12)
                alternatives.append(obstacle.maxY + 12)
            }
            alternatives.sort { abs($0 - baseY) < abs($1 - baseY) }
            for proposedY in [baseY] + alternatives {
                let y = min(max(proposedY, minimumY), maximumY)
                let dy = y - footprint.minY
                let shiftedRail = rail.offsetBy(dx: 0, dy: dy)
                let shiftedItems = items.map { $0.offsetBy(dx: 0, dy: dy) }
                let triggerHeight: CGFloat = preferences.style == .sidebar ? rail.height : QuotaCornerStackLayout.triggerHitHeight
                let triggerY: CGFloat
                if preferences.style == .sidebar {
                    triggerY = shiftedRail.minY
                } else {
                    // Retain the true corner hit target unless collision avoidance moved the stack.
                    let original = QuotaCornerStackLayout.triggerFrame(in: screenFrame, corner: corner)
                    triggerY = min(max(original.minY + dy, screenFrame.minY), screenFrame.maxY - triggerHeight)
                }
                let trigger = CGRect(x: left ? screenFrame.minX : screenFrame.maxX - 8,
                                     y: triggerY, width: 8, height: triggerHeight)
                let layout = SystemMonitorOverlayLayout(trigger: trigger, rail: shiftedRail, items: shiftedItems,
                                                        edge: edge, corner: corner)
                if fallback == nil { fallback = layout }
                let shiftedFootprint = footprint.offsetBy(dx: 0, dy: dy)
                if !occupied.contains(where: {
                    $0.insetBy(dx: -6, dy: -6).intersects(shiftedFootprint) || $0.intersects(trigger)
                }) { return layout }
            }
        }
        return fallback!
    }
}

@MainActor
final class SystemMonitorWindowCoordinator {
    private let store: SystemMonitorStore
    private let displaySettings: NotchDisplaySettings
    private let openSettings: () -> Void
    private let occupiedFrames: () -> [CGRect]
    private let screenProvider: (() -> NSScreen?)?
    private let onOpenProcesses: ((SystemProcessSort) -> Void)?
    private let processWindow = SystemProcessesWindowCoordinator()
    private let triggerWindow = QuotaPanelWindowFactory.make(ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.trigger)
    private let railWindow = QuotaPanelWindowFactory.make(ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.rail)
    private let detailWindow = QuotaPanelWindowFactory.make(ignoresMouseEvents: true, level: QuotaEdgeWindowLevel.rail)
    private var itemWindows: [SystemMonitorMetric: NotchPanel] = [:]
    private var hideTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var hoveredSurfaces: Set<String> = []
    private var hoveredMetric: SystemMonitorMetric?
    private var animationGeneration = 0
    private var configurationGeneration = UUID()
    private(set) var isPresented = false
    private var started = false
    private var lastPreferences: SystemMonitorPreferences?
    private var layout: SystemMonitorOverlayLayout?

    var ownedPanels: [NotchPanel] { [triggerWindow, railWindow, detailWindow] + Array(itemWindows.values) }

    init(store: SystemMonitorStore, displaySettings: NotchDisplaySettings,
         occupiedFrames: @escaping () -> [CGRect], openSettings: @escaping () -> Void,
         screenProvider: (() -> NSScreen?)? = nil,
         onOpenProcesses: ((SystemProcessSort) -> Void)? = nil) {
        self.store = store
        self.displaySettings = displaySettings
        self.occupiedFrames = occupiedFrames
        self.openSettings = openSettings
        self.screenProvider = screenProvider
        self.onOpenProcesses = onOpenProcesses
    }

    func start() {
        guard !started else { return }
        started = true
        store.onConfigurationChange = { [weak self] in self?.synchronize() }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }
        store.start()
        synchronize()
    }

    func stop() {
        started = false
        store.onConfigurationChange = nil
        store.stop()
        processWindow.stop()
        dismissImmediately()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    func synchronize() {
        guard started else { return }
        guard store.isRunning,
              let screen = screenProvider?() ?? displaySettings.activeScreen ?? displaySettings.selectedScreen() else {
            processWindow.stop()
            dismissImmediately()
            return
        }
        let next = SystemMonitorLayout.overlays(in: screen.frame, visibleFrame: screen.visibleFrame,
                                               preferences: store.preferences, avoiding: occupiedFrames())
        if lastPreferences != store.preferences || layout != next {
            dismissImmediately()
            lastPreferences = store.preferences
            layout = next
            configureContent(next)
        }
        triggerWindow.setFrame(next.trigger, display: true)
        triggerWindow.alphaValue = 1
        if !triggerWindow.isVisible { triggerWindow.orderFrontRegardless() }
        // Crucially, synchronize/start never reveals content. Only the edge trigger does.
    }

    private func configureContent(_ layout: SystemMonitorOverlayLayout) {
        let token = configurationGeneration
        let position: SystemMonitorPosition = store.preferences.style == .sidebar
            ? (layout.edge == .left ? .left : .right)
            : (layout.corner.isTop ? (layout.edge == .left ? .topLeft : .topRight)
               : (layout.edge == .left ? .bottomLeft : .bottomRight))
        triggerWindow.contentView = hosting(SystemMonitorTriggerView(
            style: store.preferences.style, position: position,
            onHover: { [weak self] hovering in
                guard let self, self.configurationGeneration == token else { return }
                self.setSurfaceHovered("trigger", hovering: hovering)
            },
            onOpen: { [weak self] in
                guard let self, self.configurationGeneration == token else { return }
                self.reveal()
            }
        ))
        railWindow.contentView = hosting(SystemMonitorSidebarView(
            store: store, edge: layout.edge,
            onHover: { [weak self] hovering in
                guard let self, self.configurationGeneration == token else { return }
                self.setSurfaceHovered("rail", hovering: hovering)
            },
            onMetricHover: { [weak self] metric in
                guard let self, self.configurationGeneration == token else { return }
                self.setMetricHovered(metric)
            },
            onOpenMetric: { [weak self] metric in
                guard let self, self.configurationGeneration == token else { return }
                self.activateMetric(metric)
            }
        ))
        for panel in itemWindows.values { panel.orderOut(nil) }
        itemWindows.removeAll()
        guard store.preferences.style == .stack else { return }
        for (index, metric) in store.preferences.metrics.enumerated() {
            let panel = QuotaPanelWindowFactory.make(ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.rail)
            panel.contentView = hosting(SystemMonitorStackItemView(
                store: store, metric: metric, corner: layout.corner, index: index,
                onHover: { [weak self] hovering in
                    guard let self, self.configurationGeneration == token else { return }
                    self.setSurfaceHovered(metric.rawValue, hovering: hovering)
                },
                onOpenMetric: { [weak self] metric in
                    guard let self, self.configurationGeneration == token else { return }
                    self.activateMetric(metric)
                }
            ))
            itemWindows[metric] = panel
        }
    }

    private func hosting<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }

    // Internal for focused AppKit lifecycle tests; these are also the view callbacks.
    func setSurfaceHovered(_ id: String, hovering: Bool) {
        guard started, store.isRunning, layout != nil else { return }
        if hovering {
            hoveredSurfaces.insert(id)
            hideTask?.cancel()
            hideTask = nil
            reveal()
        } else {
            hoveredSurfaces.remove(id)
            scheduleHide()
        }
    }

    private func reveal() {
        guard started, store.isRunning, let layout else { return }
        hideTask?.cancel()
        hideTask = nil
        guard !isPresented else { return }
        isPresented = true
        animationGeneration &+= 1
        let generation = animationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if store.preferences.style == .sidebar {
            let initial = QuotaEdgePanelMotion.frame(offsetOutwardFrom: layout.rail, edge: layout.edge,
                                                     distance: QuotaEdgePanelMotion.revealOffset)
            animateIn(railWindow, target: layout.rail, initial: initial, reduceMotion: reduceMotion,
                      duration: QuotaEdgePanelMotion.revealDuration)
        } else {
            for (index, metric) in store.preferences.metrics.enumerated() {
                guard let panel = itemWindows[metric] else { continue }
                let target = layout.items[index]
                Task { @MainActor [weak self, weak panel] in
                    if !reduceMotion {
                        do { try await Task.sleep(for: .seconds(Double(index) * QuotaCornerStackMotion.revealStagger)) }
                        catch { return }
                    }
                    guard let self, let panel, self.animationGeneration == generation, self.isPresented else { return }
                    self.animateIn(panel, target: target, initial: layout.collapsedStackFrame,
                                   reduceMotion: reduceMotion, duration: QuotaCornerStackMotion.revealDuration)
                }
            }
        }
        // Click/VoiceOver activation also dismisses if the pointer never enters.
        scheduleHide()
    }

    private func animateIn(_ panel: NotchPanel, target: CGRect, initial: CGRect,
                           reduceMotion: Bool, duration: TimeInterval) {
        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 0 : 0.08
            panel.setFrame(reduceMotion ? target : initial, display: true)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.16 : duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            if reduceMotion { panel.setFrame(target, display: true) }
            else { panel.animator().setFrame(target, display: true) }
        }
    }

    private func scheduleHide() {
        guard hoveredSurfaces.isEmpty, isPresented, hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: QuotaCornerStackMotion.hoverGraceDuration) } catch { return }
            guard let self, self.hoveredSurfaces.isEmpty else { return }
            self.hideTask = nil
            self.hideContent(animated: true)
        }
    }

    private func hideContent(animated: Bool) {
        isPresented = false
        animationGeneration &+= 1
        let generation = animationGeneration
        setMetricHovered(nil)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panels = store.preferences.style == .sidebar ? [railWindow] :
            store.preferences.metrics.reversed().compactMap { itemWindows[$0] }
        for (index, panel) in panels.enumerated() {
            guard panel.isVisible else { continue }
            guard animated, let layout else { panel.orderOut(nil); panel.alphaValue = 0; continue }
            let target = store.preferences.style == .sidebar
                ? QuotaEdgePanelMotion.frame(offsetOutwardFrom: panel.frame, edge: layout.edge,
                                             distance: QuotaEdgePanelMotion.hideOffset)
                : layout.collapsedStackFrame
            Task { @MainActor [weak self, weak panel] in
                if !reduceMotion {
                    do { try await Task.sleep(for: .seconds(Double(index) * QuotaCornerStackMotion.hideStagger)) }
                    catch { return }
                }
                guard let self, let panel, self.animationGeneration == generation else { return }
                let duration = reduceMotion ? 0.16 : QuotaCornerStackMotion.hideDuration
                self.animateOut(panel, target: target, reduceMotion: reduceMotion, duration: duration)
                do { try await Task.sleep(for: .seconds(duration + 0.01)) } catch { return }
                guard self.animationGeneration == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func animateOut(_ panel: NotchPanel, target: CGRect, reduceMotion: Bool, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }
    }

    private func setMetricHovered(_ metric: SystemMonitorMetric?) {
        guard hoveredMetric != metric else { return }
        hoveredMetric = metric
        guard let metric, isPresented, let layout,
              let index = store.preferences.metrics.firstIndex(of: metric) else {
            detailWindow.orderOut(nil)
            return
        }
        let screen = screenProvider?() ?? displaySettings.activeScreen ?? displaySettings.selectedScreen()
        var frame = QuotaEdgePanelLayout.detailFrame(in: screen?.visibleFrame ?? layout.rail,
                                                     railFrame: layout.rail, edge: layout.edge, providerIndex: index)
        frame.origin.y += (frame.height - 110) / 2
        frame.size.height = 110
        detailWindow.contentView = hosting(SystemMonitorDetailView(store: store, metric: metric))
        detailWindow.setFrame(frame, display: true)
        detailWindow.alphaValue = 1
        detailWindow.orderFrontRegardless()
    }

    private func activateMetric(_ metric: SystemMonitorMetric) {
        guard started, store.isRunning else { return }
        dismissImmediately()
        switch metric {
        case .cpu, .memory:
            let sort: SystemProcessSort = metric == .cpu ? .cpu : .memory
            if let onOpenProcesses { onOpenProcesses(sort) }
            else { processWindow.show(sort: sort) }
        case .disk, .network:
            openSettings()
        }
        synchronize()
    }

    private func dismissImmediately() {
        hideTask?.cancel()
        hideTask = nil
        animationGeneration &+= 1
        configurationGeneration = UUID()
        isPresented = false
        hoveredSurfaces.removeAll()
        hoveredMetric = nil
        for panel in ownedPanels {
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
        lastPreferences = nil
        layout = nil
    }
}
