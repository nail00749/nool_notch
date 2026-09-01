import AppKit
import SwiftUI

struct ExpandedNotch: View {
    @ObservedObject var model: NotchViewModel
    let onOpenSettings: (NotchSettingsSection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeTranslation: CGFloat = 0

    private var contentVisible: Bool {
        model.expandedContentVisible
    }

    private var contentAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .easeOut(duration: 0.34)
    }

    private var carouselAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .interpolatingSpring(stiffness: 260, damping: 32)
    }

    private var expandedSize: CGSize {
        NotchWindowSizingPolicy.size(
            metrics: NotchLayout.currentMetrics,
            isExpanded: true,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ExpandedNotchHeader(
                title: model.selectedPanel.title,
                physicalNotchSize: NotchLayout.physicalNotchSize,
                sideWingWidth: NotchLayout.expandedHeaderWingWidth,
                onShowSettings: { onOpenSettings(.general) }
            )
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible ? 0 : 8)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.06), value: contentVisible)

            PanelSwitcher(
                panels: model.visiblePanels,
                selectedPanel: model.selectedPanel,
                badge: panelBadge,
                onSelect: selectPanel
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible ? 0 : 8)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.15), value: contentVisible)

            SwipeCarousel(
                items: model.visiblePanels,
                selection: model.selectedPanel,
                translation: swipeTranslation
            ) { panel in
                panelPage(panel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible ? 0 : 8)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.24), value: contentVisible)

            footer
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.48))
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible ? 0 : 6)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.33), value: contentVisible)
        }
        .frame(width: expandedSize.width, height: expandedSize.height)
        .background(Color.black)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: 28,
                    bottomTrailing: 28,
                    topTrailing: 0
                ),
                style: .continuous
            )
        )
        .compositingGroup()
        .background {
            HorizontalSwipeMonitor(
                onChanged: updateSwipe,
                onThresholdReached: commitSwipe,
                onEnded: finishSwipe
            )
        }
        .onAppear {
            withAnimation(contentAnimation.delay(reduceMotion ? 0 : 0.06)) {
                model.expandedContentVisible = true
            }
        }
        .onDisappear {
            model.expandedContentVisible = false
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func panelPage(_ panel: PanelID) -> some View {
        switch panel {
        case .limits:
            LimitsPanel(model: model)
        case .calendar:
            CalendarPanel(model: model)
        case .music:
            MusicPanel(model: model)
        case .jira:
            JiraPanel(
                model: model,
                onOpenSettings: { onOpenSettings(.jira) }
            )
        }
    }

    private func selectPanel(_ panel: PanelID) {
        guard panel != model.selectedPanel else { return }
        withAnimation(carouselAnimation) {
            swipeTranslation = 0
            model.selectPanel(panel)
        }
    }

    private func updateSwipe(_ distance: CGFloat) {
        guard reduceMotion == false else { return }
        let direction: HorizontalSwipeDirection = distance > 0 ? .next : .previous
        let resistance: CGFloat = targetPanel(direction) == nil ? 0.16 : 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            swipeTranslation = -distance * resistance
        }
    }

    private func finishSwipe(_ direction: HorizontalSwipeDirection?) {
        guard let direction, let target = targetPanel(direction) else {
            withAnimation(carouselAnimation) {
                swipeTranslation = 0
            }
            return
        }

        withAnimation(carouselAnimation) {
            swipeTranslation = 0
            model.selectPanel(target)
        }
    }

    private func commitSwipe(_ direction: HorizontalSwipeDirection) -> Bool {
        guard targetPanel(direction) != nil else { return false }
        model.acknowledgePanelSwipe()
        NotchHaptics.selectionChanged()
        return true
    }

    private func targetPanel(_ direction: HorizontalSwipeDirection) -> PanelID? {
        let panels = model.visiblePanels
        guard let currentIndex = panels.firstIndex(of: model.selectedPanel) else { return nil }

        let nextIndex = direction == .next ? currentIndex + 1 : currentIndex - 1
        guard panels.indices.contains(nextIndex) else { return nil }
        return panels[nextIndex]
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color.signalMint)
                .frame(width: 6, height: 6)

            Text(freshnessText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.visiblePanels.count > 1 {
                HStack(spacing: 5) {
                    ForEach(model.visiblePanels) { panel in
                        Capsule()
                            .fill(
                                panel == model.selectedPanel
                                    ? Color.signalMint
                                    : Color.white.opacity(0.22)
                            )
                            .frame(width: panel == model.selectedPanel ? 12 : 5, height: 5)
                    }
                }

                if model.hasCompletedPanelSwipe == false {
                    Text("свайп двумя пальцами")
                        .foregroundStyle(Color.signalMint.opacity(0.72))
                }
            }
        }
    }

    private var freshnessText: String {
        guard let date = model.lastUpdatedAt(for: model.selectedPanel) else {
            return "нет свежих данных"
        }
        return "обновлено \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func panelBadge(_ panel: PanelID) -> PanelTabBadge? {
        switch panel {
        case .limits:
            let warningCount = model.numericBadgeCount(for: .limits) ?? 0
            return PanelTabBadge(
                text: String(warningCount),
                color: warningCount > 0 ? Color.signalCoral : Color.white.opacity(0.42)
            )
        case .calendar:
            let todayCount = model.numericBadgeCount(for: .calendar) ?? 0
            return PanelTabBadge(
                text: String(todayCount),
                color: todayCount > 0 ? Color.signalCyan : Color.white.opacity(0.42)
            )
        case .music:
            guard model.nowPlayingSnapshot?.playbackState.isPlaying == true else { return nil }
            return PanelTabBadge(text: nil, color: Color.signalMint)
        case .jira:
            let issues: [JiraIssue]
            switch model.jiraState.list {
            case .loaded(let loaded, _): issues = loaded
            case .loading(let previous), .failed(_, let previous): issues = previous ?? []
            case .idle: issues = []
            }
            let issueCount = model.numericBadgeCount(for: .jira) ?? 0
            let startOfToday = Calendar.current.startOfDay(for: .now)
            let hasOverdue = issues.contains { issue in
                issue.dueDate.map { $0 < startOfToday } ?? false
            }
            return PanelTabBadge(
                text: issueCount > 99 ? "99+" : String(issueCount),
                color: hasOverdue
                    ? Color.signalCoral
                    : issueCount > 0 ? Color.signalMint : Color.white.opacity(0.42)
            )
        }
    }
}

private struct ExpandedNotchHeader: View {
    let title: String
    let physicalNotchSize: CGSize
    let sideWingWidth: CGFloat?
    let onShowSettings: () -> Void

    private var sideHeaderHeight: CGFloat {
        max(40, physicalNotchSize.height)
    }

    var body: some View {
        if let sideWingWidth {
            HStack(alignment: .top, spacing: 0) {
                leadingContent
                    .padding(.leading, 22)
                    .frame(
                        width: sideWingWidth,
                        height: sideHeaderHeight,
                        alignment: .leading
                    )

                PhysicalNotchSafeZone(size: physicalNotchSize)
                    .frame(
                        width: physicalNotchSize.width,
                        height: physicalNotchSize.height,
                        alignment: .top
                    )

                trailingContent
                    .padding(.trailing, 18)
                    .frame(
                        width: sideWingWidth,
                        height: sideHeaderHeight,
                        alignment: .trailing
                    )
            }
            .frame(height: sideHeaderHeight, alignment: .top)
            .padding(.bottom, 10)
        } else {
            HStack(spacing: 10) {
                leadingContent
                Spacer()
                trailingContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, NotchLayout.expandedTopPadding)
            .padding(.bottom, 10)
        }
    }

    private var leadingContent: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var trailingContent: some View {
        HeaderButton(
            icon: "gearshape",
            label: "Открыть настройки",
            action: onShowSettings
        )
    }
}

private struct HeaderButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 40, height: 40)
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct PanelSwitcher: View {
    let panels: [PanelID]
    let selectedPanel: PanelID
    let badge: (PanelID) -> PanelTabBadge?
    let onSelect: (PanelID) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(panels) { panel in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        onSelect(panel)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: panel.iconName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(panel.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if let badge = badge(panel) {
                            PanelTabBadgeView(badge: badge)
                        }
                    }
                    .foregroundStyle(selectedPanel == panel ? .white : .white.opacity(0.46))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        selectedPanel == panel ? Color.white.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityAddTraits(selectedPanel == panel ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct PanelTabBadge {
    let text: String?
    let color: Color
}

private struct PanelTabBadgeView: View {
    let badge: PanelTabBadge

    var body: some View {
        Group {
            if let text = badge.text {
                Text(text)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(badge.color.opacity(0.2), in: Capsule())
                    .foregroundStyle(badge.color)
            } else {
                Circle()
                    .fill(badge.color)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PlaceholderPanel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(Color.signalMint)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .padding(20)
    }
}
