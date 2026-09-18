import AppKit
import SwiftUI

@MainActor
final class QuotaEdgeWindowCoordinator {
    private let model: NotchViewModel
    private let displaySettings: NotchDisplaySettings
    private let quotaTriggerWindow: NotchPanel
    private let quotaEdgeWindow: NotchPanel
    private let quotaDetailWindow: NotchPanel
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
    private(set) var isStarted = false

    var ownedPanels: [NotchPanel] {
        [quotaTriggerWindow, quotaEdgeWindow, quotaDetailWindow]
    }

    init(model: NotchViewModel, displaySettings: NotchDisplaySettings) {
        self.model = model
        self.displaySettings = displaySettings
        quotaTriggerWindow = QuotaPanelWindowFactory.make(
            ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.trigger
        )
        quotaEdgeWindow = QuotaPanelWindowFactory.make(
            ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.rail
        )
        quotaDetailWindow = QuotaPanelWindowFactory.make(
            ignoresMouseEvents: true, level: QuotaEdgeWindowLevel.rail
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        synchronize()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        quotaEdgeHideTask?.cancel()
        quotaEdgeHideTask = nil
        quotaEdgeAnimationGeneration &+= 1
        quotaDetailAnimationGeneration &+= 1
        hoveredQuotaProviderID = nil
        isQuotaTriggerHovered = false
        isQuotaEdgeHovered = false
        isQuotaEdgePresented = false
        for panel in ownedPanels {
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
    }

    func synchronize() {
        guard isStarted else { return }
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
                onOpen: { [weak self] in
                    guard let self, self.isStarted else { return }
                    self.model.openQuotaLimits()
                },
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
        guard isStarted, isQuotaTriggerHovered != isHovering else { return }
        isQuotaTriggerHovered = isHovering
        if isHovering {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            model.refreshQuotaProvidersIfStale()
            synchronize()
        } else {
            scheduleQuotaEdgeHide()
        }
    }

    private func setQuotaEdgeHovered(_ isHovering: Bool) {
        guard isStarted, isQuotaEdgeHovered != isHovering else { return }
        isQuotaEdgeHovered = isHovering
        if isHovering {
            quotaEdgeHideTask?.cancel()
            quotaEdgeHideTask = nil
            synchronize()
        } else {
            scheduleQuotaEdgeHide()
        }
    }

    private func setHoveredQuotaProvider(_ providerID: String?) {
        guard isStarted, hoveredQuotaProviderID != providerID else { return }
        hoveredQuotaProviderID = providerID
        if providerID != nil {
            model.refreshQuotaProvidersIfStale()
        }
        synchronize()
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
            guard let self, self.isStarted else { return }
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
}

@MainActor
enum QuotaPanelWindowFactory {
    static func make(ignoresMouseEvents: Bool, level: NSWindow.Level) -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        configure(panel, ignoresMouseEvents: ignoresMouseEvents, level: level)
        return panel
    }

    static func configure(
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
}
