import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var visualSettings: NotchVisualSettings
    let onOpenSettings: (NotchSettingsSection) -> Void
    let onLayoutChange: (_ isExpanded: Bool, _ reduceMotion: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverExpansionEnabled = false
    @State private var playbackBounce = false
    @State private var expansionStartedAt: Date?
    @State private var expansionTask: Task<Void, Never>?

    private var stateAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.56, dampingFraction: 0.88)
    }

    private var isCompactPlaybackActive: Bool {
        model.nowPlayingSnapshot?.playbackState.isPlaying == true
    }

    private var currentSize: CGSize {
        NotchWindowSizingPolicy.size(
            metrics: NotchLayout.currentMetrics,
            isExpanded: model.isExpanded,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: false,
            compactHeight: visualSettings.compactHeight,
            isPlaying: isCompactPlaybackActive
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isExpanded {
                ExpandedNotch(
                    model: model,
                    onOpenSettings: onOpenSettings
                )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                        removal: .offset(y: -12).combined(with: .opacity)
                    ))
            } else {
                CompactNotch(
                    model: model,
                    visualSettings: visualSettings,
                    onExpand: { setExpanded(true) }
                )
            }
        }
        .frame(
            width: currentSize.width,
            height: currentSize.height,
            alignment: .top
        )
        .offset(y: playbackBounce ? -4 : 0)
        .animation(stateAnimation, value: model.isExpanded)
        .animation(stateAnimation, value: isCompactPlaybackActive)
        .animation(stateAnimation, value: visualSettings.compactHeight)
        .contentShape(Rectangle())
        .onHover(perform: handleHover)
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            hoverExpansionEnabled = true
        }
        .onChange(of: model.isExpanded) { _, isExpanded in
            if isExpanded {
                NotchHaptics.selectionChanged()
            } else {
                expansionStartedAt = nil
            }
            onLayoutChange(isExpanded, reduceMotion)
        }
        .onChange(of: model.selectedPanel) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: model.calendarViewMode) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: visualSettings.compactHeight) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
        }
        .onChange(of: playbackSignal) { _, _ in
            onLayoutChange(model.isExpanded, reduceMotion)
            guard isCompactPlaybackActive else { return }
            triggerPlaybackBounce()
        }
        .onDisappear {
            expansionTask?.cancel()
            expansionTask = nil
        }
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

        withAnimation(stateAnimation) {
            model.isExpanded = isExpanded
        }
    }

    private func handleHover(_ isHovering: Bool) {
        if isHovering == false {
            expansionTask?.cancel()
            expansionTask = nil
        }

        switch NotchHoverPolicy.action(
            isHovering: isHovering,
            isExpanded: model.isExpanded,
            hoverExpansionEnabled: hoverExpansionEnabled,
            isContextMenuVisible: model.isContextMenuVisible
        ) {
        case .expand:
            scheduleExpansion()
        case .cancelCollapse:
            expansionTask?.cancel()
            expansionTask = nil
            model.cancelScheduledCollapse()
        case .scheduleCollapse:
            setExpanded(false)
        case .none:
            break
        }
    }

    private func scheduleExpansion() {
        expansionTask?.cancel()
        let delay = NotchHoverPolicy.expansionDelay(
            configuredDelay: model.hoverExpansionDelay
        )
        expansionTask = Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard Task.isCancelled == false, model.isExpanded == false else { return }
            if let screen = NSScreen.preferredNotchScreen {
                let pointerIsOutside = NotchHoverPolicy.shouldCollapse(
                    pointerLocation: NSEvent.mouseLocation,
                    screenFrame: screen.frame,
                    windowSize: NotchLayout.compactSize(
                        isPlaying: isCompactPlaybackActive,
                        compactHeight: visualSettings.compactHeight
                    )
                )
                guard pointerIsOutside == false else { return }
            }
            expansionTask = nil
            setExpanded(true)
        }
    }

    private var playbackSignal: String {
        guard let snapshot = model.nowPlayingSnapshot else { return "none" }
        return "\(snapshot.id)|\(snapshot.playbackState)"
    }

    private func triggerPlaybackBounce() {
        guard reduceMotion == false else { return }

        withAnimation(.spring(response: 0.16, dampingFraction: 0.42)) {
            playbackBounce = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                playbackBounce = false
            }
        }
    }
}
