import AppKit
import SwiftUI

@MainActor
final class QuotaStackWindowCoordinator {
    private let model: NotchViewModel
    private let displaySettings: NotchDisplaySettings
    private let quotaStackTriggerWindow: NotchPanel
    private var quotaStackItemWindows: [String: NotchPanel] = [:]
    private var quotaStackConfiguration: (corner: QuotaStackCorner, providerIDs: [String])?
    private var quotaStackTriggerConfiguration: QuotaStackCorner?
    private var quotaStackHoveredProviderIDs: Set<String> = []
    private var isQuotaStackTriggerHovered = false
    private var isQuotaStackPresented = false
    private var quotaStackHideTask: Task<Void, Never>?
    private var quotaStackAnimationGeneration = 0
    private var quotaStackTargetFrames: [String: NSRect] = [:]
    private(set) var isStarted = false

    var ownedPanels: [NotchPanel] {
        [quotaStackTriggerWindow] + Array(quotaStackItemWindows.values)
    }

    init(model: NotchViewModel, displaySettings: NotchDisplaySettings) {
        self.model = model
        self.displaySettings = displaySettings
        quotaStackTriggerWindow = QuotaPanelWindowFactory.make(
            ignoresMouseEvents: false, level: QuotaEdgeWindowLevel.trigger
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
        quotaStackHideTask?.cancel()
        quotaStackHideTask = nil
        quotaStackAnimationGeneration &+= 1
        quotaStackHoveredProviderIDs.removeAll()
        isQuotaStackTriggerHovered = false
        isQuotaStackPresented = false
        for panel in ownedPanels {
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
        quotaStackItemWindows.removeAll()
        quotaStackConfiguration = nil
        quotaStackTriggerConfiguration = nil
        quotaStackTargetFrames.removeAll()
    }

    func synchronize() {
        guard isStarted else { return }
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
        QuotaPanelWindowFactory.configure(
            panel,
            ignoresMouseEvents: false,
            level: QuotaEdgeWindowLevel.rail
        )
        return panel
    }

    private func setQuotaStackTriggerHovered(_ hovering: Bool) {
        guard isStarted, isQuotaStackTriggerHovered != hovering else { return }
        isQuotaStackTriggerHovered = hovering
        if hovering {
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            model.refreshQuotaProvidersIfStale()
            synchronize()
        } else {
            scheduleQuotaStackHide()
        }
    }

    private func setQuotaStackItemHovered(_ providerID: String, hovering: Bool) {
        guard isStarted else { return }
        if hovering {
            quotaStackHoveredProviderIDs.insert(providerID)
            quotaStackHideTask?.cancel()
            quotaStackHideTask = nil
            synchronize()
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
            guard let self, self.isStarted else { return }
            self.quotaStackHideTask = nil
            guard self.isQuotaStackTriggerHovered == false,
                  self.quotaStackHoveredProviderIDs.isEmpty else { return }
            self.hideQuotaCornerStack(animated: true)
        }
    }

    private func openQuotaLimitsFromStack() {
        guard isStarted else { return }
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
}
