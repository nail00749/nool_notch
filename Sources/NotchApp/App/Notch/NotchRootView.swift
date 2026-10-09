import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchTransitionStack<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            // AppKit supplies each intermediate frame; do not interpolate it again.
            .animation(nil, value: geometry.size)
        }
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var presentation: NotchWindowPresentation
    @ObservedObject var visualSettings: NotchVisualSettings
    @ObservedObject var displaySettings: NotchDisplaySettings
    @ObservedObject var customizationSettings: NotchCustomizationSettings
    @ObservedObject private var gestureInteraction = NotchGestureInteraction.shared
    let onOpenSettings: (NotchSettingsSection) -> Void
    let onLayoutChange: (_ isExpanded: Bool, _ reduceMotion: Bool) -> Void
    var onKeyboardFocusChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expansionStartedAt: Date?

    private var isCompactPlaybackActive: Bool {
        model.modules.isEnabled(.music)
            && model.nowPlayingSnapshot?.playbackState.isPlaying == true
    }

    private var usesWideCompactLayout: Bool {
        model.compactMeetingReminder != nil
            || model.compactTimer != nil
            || model.hasCompactLiveActivity
            || (isCompactPlaybackActive && customizationSettings.showsMusicIndicator)
            || showsCompactQuotaIndicator
    }

    private var showsCompactQuotaIndicator: Bool {
        customizationSettings.showsQuotaIndicator
            && model.modules.isEnabled(.quotas)
            && model.compactQuotaDisplayMode == .top
            && (isCompactPlaybackActive || customizationSettings.showsQuotaWhenIdle)
    }

    private var compactHeight: CGFloat {
        displaySettings.effectiveCompactHeight(fallback: visualSettings.compactHeight)
    }

    private var layoutMetrics: NotchLayoutMetrics { displaySettings.activeMetrics }

    private var currentSize: CGSize {
        NotchWindowSizingPolicy.panelSize(
            metrics: layoutMetrics,
            isExpanded: model.isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: false,
            compactHeight: compactHeight,
            isPlaying: usesWideCompactLayout,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered,
            expandedWidth: customizationSettings.expandedWidth,
            maxExpandedHeight: customizationSettings.maxExpandedHeight,
            hasSideControls: customizationSettings.quickActions.contains { $0.placement != .bottom },
            activeUtility: model.activeUtility
        )
    }

    private var surfaceShape: NotchSurfaceShape {
        let compactSize = NotchWindowSizingPolicy.compactInteractionSize(
            metrics: layoutMetrics,
            isPlaying: usesWideCompactLayout,
            compactHeight: compactHeight,
            showsAgentMascot: model.compactMascotNotice != nil,
            isHovered: model.isCompactHovered
        )
        let surfaceHeight = model.compactMascotNotice == nil
            ? compactHeight + (model.isCompactHovered ? 6 : 0)
            : compactSize.height - NotchLayout.compactHoverBottomPadding
        let expandedSize = NotchWindowSizingPolicy.size(
            metrics: layoutMetrics, isExpanded: true,
            selectedPanel: model.selectedPanel, calendarViewMode: model.calendarViewMode,
            isShowingSettings: false,
            expandedWidth: customizationSettings.expandedWidth,
            maxExpandedHeight: customizationSettings.maxExpandedHeight,
            activeUtility: model.activeUtility
        )
        return NotchSurfaceShape(
            compactWindowSize: compactSize,
            compactSurfaceHeight: surfaceHeight,
            expandedHeight: expandedSize.height,
            expandedSurfaceWidth: expandedSize.width,
            holdsExpandedShape: model.isExpanded && model.expansionSurfaceSettled
        )
    }

    private var surfaceContent: some View {
        NotchTransitionStack {
            if presentation.mountsExpandedContent {
                ExpandedNotch(
                    model: model,
                    layoutMetrics: layoutMetrics,
                    customizationSettings: customizationSettings,
                    showsSettingsMascot: visualSettings.showsExpandedMascot,
                    onOpenSettings: onOpenSettings,
                    onQuickAction: performQuickAction
                )
                .opacity(model.isExpanded ? 1 : 0)
                .allowsHitTesting(model.isExpanded)
                .accessibilityHidden(!model.isExpanded)
                .transition(.opacity.animation(.easeOut(duration: reduceMotion ? 0.01 : 0.10)))
            }
            if !model.isExpanded || !presentation.mountsExpandedContent {
                CompactNotch(
                    model: model,
                    visualSettings: visualSettings,
                    customizationSettings: customizationSettings,
                    layoutMetrics: layoutMetrics,
                    compactHeight: compactHeight,
                    onExpand: { setExpanded(true) }
                )
                .allowsHitTesting(!model.isExpanded)
                .accessibilityHidden(model.isExpanded)
                .transition(.opacity.animation(.easeOut(duration: reduceMotion ? 0.01 : 0.10)))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.12), value: model.isExpanded)
        .clipShape(surfaceShape)
        .overlay(alignment: .top) {
            sideControls
        }
        .background {
            // Match the physical camera cutout in both states and during transitions.
            surfaceShape.fill(.black)
        }
        .overlay {
            if model.isExpanded, customizationSettings.showsOutline {
                surfaceShape.stroke(NotchPalette.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .tint(NotchPalette.accent)
        .environment(\.colorScheme, .dark)
        .contentShape(
            NotchRootInteractionShape(
                isExpanded: model.isExpanded,
                expandedSurfaceShape: surfaceShape,
                sideControlsTop: layoutMetrics.physicalNotchSize.height + 18,
                leadingButtonCount: customizationSettings.actions(at: .leading).count,
                trailingButtonCount: customizationSettings.actions(at: .trailing).count,
                excludesLeadingMascotLane: model.isExpanded == false
                    && model.compactMascotNotice != nil
            )
        )
    }

    private var sideControls: some View {
        HStack(spacing: 0) {
            sideControlColumn(isLeading: true, direction: -1)
            Spacer(minLength: 0)
            sideControlColumn(isLeading: false, direction: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(model.isExpanded)
        .accessibilityHidden(model.isExpanded == false)
    }

    private func sideControlColumn(
        isLeading: Bool,
        direction: CGFloat
    ) -> some View {
        let placement: NotchQuickActionPlacement = isLeading ? .leading : .trailing
        let actions = customizationSettings.actions(at: placement)
        return VStack(
            alignment: isLeading ? .leading : .trailing,
            spacing: NotchLayout.expandedSideControlSpacing
        ) {
            ForEach(actions) { action in
                let index = actions.firstIndex(where: { $0.id == action.id }) ?? 0
                sideControlButton(
                    action: action,
                    delay: Double(index) * 0.055,
                    direction: direction
                ) {
                    performQuickAction(action.action)
                }
            }
        }
        .frame(
            width: NotchLayout.expandedSideControlLaneWidth,
            alignment: isLeading ? .topLeading : .topTrailing
        )
        .padding(.top, layoutMetrics.physicalNotchSize.height + 18)
    }

    private func sideControlButton(
        action: NotchQuickAction,
        delay: TimeInterval,
        direction: CGFloat,
        perform: @escaping () -> Void
    ) -> some View {
        let controlAnimation = NotchMotion.sideControlAnimation(
            isExpanded: model.isExpanded, delay: delay, reduceMotion: reduceMotion
        )

        return Button(action: perform) {
            Image(systemName: action.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(
                    width: NotchLayout.expandedSideControlButtonSize,
                    height: NotchLayout.expandedSideControlButtonSize
                )
                .background(Color.black, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(action.title)
        .help(action.title)
        .opacity(model.isExpanded ? 1 : 0)
        .scaleEffect(reduceMotion || model.isExpanded ? 1 : 0.86)
        .offset(x: reduceMotion || model.isExpanded ? 0 : direction * 20)
        .animation(controlAnimation, value: model.isExpanded)
    }

    private func performQuickAction(_ action: NotchQuickActionID) {
        switch action {
        case .modules:
            model.openUtility(.overview)
        case .scratchpad:
            if model.modules.isEnabled(.scratchpad) { model.openUtility(.scratchpad) }
            else { onOpenSettings(.modules) }
        case .recentCaptures:
            if model.modules.isEnabled(.recentCaptures) { model.openUtility(.recentCaptures) }
            else { onOpenSettings(.modules) }
        case .settings:
            onOpenSettings(.general)
        case .sound:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings") {
                NSWorkspace.shared.open(url)
            }
        case .timer:
            guard model.modules.isEnabled(.liveActivities) else {
                onOpenSettings(.modules)
                return
            }
            model.openTimer()
        case .ai:
            openPanel(.ai)
        case .live:
            openPanel(.live)
        case .calendar:
            openPanel(.calendar)
        case .music:
            openPanel(.music)
        case .jira:
            openPanel(.jira)
        }
    }

    private func openPanel(_ panel: PanelID) {
        guard model.isPanelAvailable(panel) else {
            onOpenSettings(.modules)
            return
        }
        model.openPanel(panel)
    }

    private var interactiveContent: some View {
        surfaceContent
        .onHover(perform: handleHover)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isFileDropTargeted,
                perform: model.acceptShelfDrop)
        .onChange(of: model.isFileDropTargeted) { _, isTargeted in
            if isTargeted { model.openUtility(.files) }
        }
        .onChange(of: model.activeUtility) { previous, utility in
            let neededFocus = previous?.requiresKeyboardFocus == true
            let needsFocus = utility?.requiresKeyboardFocus == true
            if neededFocus != needsFocus { onKeyboardFocusChange(needsFocus) }
            onLayoutChange(model.isExpanded, reduceMotion)
        }
    }

    private var lifecycleContent: some View {
        NotchVisualViewport(size: presentation.size) {
            interactiveContent
        }
        .task {
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .task(id: model.isCompactHovered && !gestureInteraction.isResolvingCompactClick
              ? model.hoverExpansionDelay : -1) {
            let delay = model.hoverExpansionDelay
            guard model.isCompactHovered, !gestureInteraction.isResolvingCompactClick,
                  delay > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  model.isCompactHovered,
                  !gestureInteraction.isResolvingCompactClick,
                  model.isExpanded == false,
                  model.isTransientSurfaceVisible == false,
                  let screenFrame = displaySettings.activeScreenFrame,
                  NotchHoverPolicy.shouldCollapse(
                    pointerLocation: NSEvent.mouseLocation,
                    screenFrame: screenFrame,
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
        .onChange(of: compactHeight) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: displaySettings.activeDisplayID) { _, _ in
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
            if model.completeRequestedCollapse() { return }
            guard let screenFrame = displaySettings.activeScreenFrame,
                  NotchHoverPolicy.shouldCollapse(
                    pointerLocation: NSEvent.mouseLocation,
                    screenFrame: screenFrame,
                    windowSize: currentSize
                  ) else { return }
            setExpanded(false)
        }
        .onChange(of: model.isExpansionPinned) { _, pinned in
            if !pinned, model.isExpanded { setExpanded(false) }
        }
        .onChange(of: playbackSignal) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
    }

    private func setExpanded(_ isExpanded: Bool) {
        guard model.isExpanded != isExpanded else { return }

        if isExpanded {
            model.cancelScheduledCollapse()
            model.prepareDefaultExpansion()
            expansionStartedAt = Date()
        } else {
            let elapsed = expansionStartedAt.map { Date().timeIntervalSince($0) }
            let expandedWindowSize = currentSize
            model.scheduleCollapse(
                after: NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: elapsed),
                onlyIf: {
                    guard let screenFrame = displaySettings.activeScreenFrame else { return true }
                    return NotchHoverPolicy.shouldCollapse(
                        pointerLocation: NSEvent.mouseLocation,
                        screenFrame: screenFrame,
                        windowSize: expandedWindowSize
                    )
                }
            )
            return
        }

        model.isExpanded = isExpanded
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

struct NotchRootInteractionShape: Shape {
    let isExpanded: Bool
    let expandedSurfaceShape: NotchSurfaceShape
    let sideControlsTop: CGFloat
    let leadingButtonCount: Int
    let trailingButtonCount: Int
    let excludesLeadingMascotLane: Bool

    func path(in rect: CGRect) -> Path {
        if isExpanded {
            var path = expandedSurfaceShape.path(in: rect)
            for buttonFrame in sideControlFrames(in: rect) {
                path.addEllipse(in: buttonFrame)
            }
            return path
        }

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

    private func sideControlFrames(in rect: CGRect) -> [CGRect] {
        let size = NotchLayout.expandedSideControlButtonSize
        let leadingX = rect.minX
        let trailingX = rect.maxX - size
        let firstY = rect.minY + sideControlsTop
        return (0..<leadingButtonCount).map { index in
            CGRect(x: leadingX, y: firstY + CGFloat(index) * (size + NotchLayout.expandedSideControlSpacing),
                   width: size, height: size)
        } + (0..<trailingButtonCount).map { index in
            CGRect(x: trailingX, y: firstY + CGFloat(index) * (size + NotchLayout.expandedSideControlSpacing),
                   width: size, height: size)
        }
    }
}
