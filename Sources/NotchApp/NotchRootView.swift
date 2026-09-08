import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchTransitionStack<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var visualSettings: NotchVisualSettings
    let onOpenSettings: (NotchSettingsSection) -> Void
    let onLayoutChange: (_ isExpanded: Bool, _ reduceMotion: Bool) -> Void
    var onKeyboardFocusChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expansionSurfaceSettled = false
    @State private var expansionStartedAt: Date?

    private var stateAnimation: Animation {
        NotchMotion.layoutAnimation(isExpanded: model.isExpanded, reduceMotion: reduceMotion)
    }

    private var isCompactPlaybackActive: Bool {
        model.nowPlayingSnapshot?.playbackState.isPlaying == true
    }

    private var isCompactLiveActivityActive: Bool {
        model.primaryLiveActivity != nil
    }

    private var usesWideCompactLayout: Bool {
        model.usesWideCompactLayout
    }

    private var currentSize: CGSize {
        NotchWindowSizingPolicy.size(
            metrics: NotchLayout.currentMetrics,
            isExpanded: model.isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: false,
            compactHeight: visualSettings.compactHeight,
            isPlaying: usesWideCompactLayout,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered
        )
    }

    private var surfaceShape: NotchSurfaceShape {
        let compactSize = NotchWindowSizingPolicy.compactInteractionSize(
            metrics: NotchLayout.currentMetrics,
            isPlaying: usesWideCompactLayout,
            compactHeight: visualSettings.compactHeight,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered
        )
        let surfaceHeight = model.compactMascotNotice == nil
            ? visualSettings.compactHeight + (model.isCompactHovered ? 6 : 0)
            : compactSize.height - NotchLayout.compactHoverBottomPadding
        let expandedSize = NotchWindowSizingPolicy.size(
            metrics: NotchLayout.currentMetrics, isExpanded: true,
            selectedPanel: model.selectedPanel, calendarViewMode: model.calendarViewMode,
            isShowingSettings: false
        )
        return NotchSurfaceShape(
            compactWindowSize: compactSize,
            compactSurfaceHeight: surfaceHeight,
            expandedHeight: expandedSize.height,
            holdsExpandedShape: model.isExpanded && expansionSurfaceSettled
        )
    }

    private var surfaceContent: some View {
        NotchTransitionStack {
            if model.isExpanded {
                ExpandedNotch(
                    model: model,
                    showsSettingsMascot: visualSettings.showsExpandedMascot,
                    onOpenSettings: onOpenSettings
                )
                .transition(.identity)
            } else {
                CompactNotch(
                    model: model,
                    visualSettings: visualSettings,
                    onExpand: { setExpanded(true) }
                )
                .transition(.opacity.animation(.easeOut(duration: reduceMotion ? 0.01 : 0.10)))
            }
        }
        .background { surfaceShape.fill(.black) }
        .clipShape(surfaceShape)
        .animation(stateAnimation, value: model.isExpanded)
        .animation(NotchMotion.compactResizeAnimation(reduceMotion: reduceMotion), value: model.isCompactHovered)
        .animation(stateAnimation, value: isCompactPlaybackActive)
        .animation(NotchMotion.compactResizeAnimation(reduceMotion: reduceMotion), value: usesWideCompactLayout)
        .animation(stateAnimation, value: isCompactLiveActivityActive)
        .animation(stateAnimation, value: visualSettings.compactHeight)
        .contentShape(
            NotchRootInteractionShape(
                excludesLeadingMascotLane: model.isExpanded == false
                    && model.compactMascotNotice != nil
            )
        )
    }

    private var interactiveContent: some View {
        surfaceContent
        .onHover(perform: handleHover)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isFileDropTargeted,
                perform: model.acceptShelfDrop)
        .onChange(of: model.isFileDropTargeted) { _, isTargeted in
            if isTargeted { model.openUtility(.files) }
        }
        .onChange(of: model.activeUtility) { _, utility in
            onKeyboardFocusChange(utility == .search)
        }
    }

    private var lifecycleContent: some View {
        interactiveContent
        .task {
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .task(id: model.isExpanded) { await settleExpansion() }
        .task(id: model.isCompactHovered ? model.hoverExpansionDelay : -1) {
            let delay = model.hoverExpansionDelay
            guard model.isCompactHovered, delay > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  model.isCompactHovered,
                  model.isExpanded == false,
                  model.isTransientSurfaceVisible == false,
                  let screen = NSScreen.preferredNotchScreen,
                  NotchHoverPolicy.shouldCollapse(
                    pointerLocation: NSEvent.mouseLocation,
                    screenFrame: screen.frame,
                    windowSize: currentSize
                  ) == false else { return }
            setExpanded(true)
        }
    }

    private var layoutContent: some View {
        lifecycleContent
        .onChange(of: model.isExpanded) { _, isExpanded in
            if isExpanded {
                NotchHaptics.notchExpanded()
            } else {
                expansionSurfaceSettled = false
                model.isCompactHovered = false
                expansionStartedAt = nil
            }
            onLayoutChange(isExpanded, reduceMotion)
        }
        .onChange(of: model.isCompactHovered) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.selectedPanel) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.calendarViewMode) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
    }

    var body: some View {
        layoutContent
        .onChange(of: visualSettings.compactHeight) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.compactMascotNotice?.id) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.primaryLiveActivity?.id) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.compactMeetingReminder?.event.id) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.usesWideCompactLayout) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.isTransientSurfaceVisible) { wasVisible, isVisible in
            guard wasVisible, isVisible == false, model.isExpanded else { return }
            guard let screen = NSScreen.preferredNotchScreen,
                  NotchHoverPolicy.shouldCollapse(
                    pointerLocation: NSEvent.mouseLocation,
                    screenFrame: screen.frame,
                    windowSize: currentSize
                  ) else { return }
            setExpanded(false)
        }
        .onChange(of: playbackSignal) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
    }

    @MainActor
    private func settleExpansion() async {
        guard model.isExpanded else { return }
        do {
            if reduceMotion == false {
                try await Task.sleep(for: .seconds(NotchMotion.expansionDuration))
            }
        } catch { return }
        guard Task.isCancelled == false, model.isExpanded else { return }
        expansionSurfaceSettled = true
    }

    private func setExpanded(_ isExpanded: Bool) {
        guard model.isExpanded != isExpanded else { return }

        if isExpanded {
            model.cancelScheduledCollapse()
            expansionStartedAt = Date()
        } else {
            let elapsed = expansionStartedAt.map { Date().timeIntervalSince($0) }
            let expandedWindowSize = currentSize
            model.scheduleCollapse(
                after: NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: elapsed),
                onlyIf: {
                    guard let screen = NSScreen.preferredNotchScreen else { return true }
                    return NotchHoverPolicy.shouldCollapse(
                        pointerLocation: NSEvent.mouseLocation,
                        screenFrame: screen.frame,
                        windowSize: expandedWindowSize
                    )
                }
            )
            return
        }

        withAnimation(NotchMotion.layoutAnimation(isExpanded: isExpanded, reduceMotion: reduceMotion)) {
            model.isExpanded = isExpanded
        }
    }

    private func handleHover(_ isHovering: Bool) {
        // The outgoing compact view must keep its hover size throughout expansion.
        if model.isExpanded == false {
            if isHovering, model.isCompactHovered == false {
                NotchHaptics.compactHoverEntered()
            }
            model.isCompactHovered = isHovering
        }

        switch NotchHoverPolicy.action(
            isHovering: isHovering,
            isExpanded: model.isExpanded,
            hoverExpansionEnabled: false,
            isContextMenuVisible: model.isTransientSurfaceVisible
        ) {
        case .cancelCollapse:
            model.cancelScheduledCollapse()
        case .scheduleCollapse:
            setExpanded(false)
        case .none:
            break
        }
    }

    private var playbackSignal: String {
        guard let snapshot = model.nowPlayingSnapshot else { return "none" }
        return "\(snapshot.id)|\(snapshot.playbackState)"
    }

}

private struct NotchRootInteractionShape: Shape {
    let excludesLeadingMascotLane: Bool

    func path(in rect: CGRect) -> Path {
        guard excludesLeadingMascotLane else {
            return Path(rect)
        }

        return Path(CGRect(
            x: rect.minX
                + NotchLayout.compactHoverHorizontalPadding
                + NotchLayout.compactAgentMascotLaneWidth,
            y: rect.minY,
            width: max(
                0,
                rect.width
                    - NotchLayout.compactHoverHorizontalPadding
                    - NotchLayout.compactAgentMascotLaneWidth
            ),
            height: rect.height
        ))
    }
}
