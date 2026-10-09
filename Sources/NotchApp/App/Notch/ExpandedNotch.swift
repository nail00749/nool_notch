import AppKit
import SwiftUI

struct ExpandedNotch: View {
    @ObservedObject var model: NotchViewModel
    let layoutMetrics: NotchLayoutMetrics
    @ObservedObject var customizationSettings: NotchCustomizationSettings
    let showsSettingsMascot: Bool
    let onOpenSettings: (NotchSettingsSection) -> Void
    let onQuickAction: (NotchQuickActionID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeTranslation: CGFloat = 0
    @State private var hasPreparedNeighbors = false

    private var contentVisible: Bool {
        model.expandedContentVisible
    }

    private var contentAnimation: Animation {
        NotchMotion.contentAnimation(reduceMotion: reduceMotion)
    }

    private var carouselAnimation: Animation {
        NotchMotion.panelAnimation(reduceMotion: reduceMotion)
    }

    private var expandedSize: CGSize {
        NotchWindowSizingPolicy.size(
            metrics: layoutMetrics,
            isExpanded: true,
            selectedPanel: model.selectedPanel,
            calendarViewMode: model.calendarViewMode,
            isShowingSettings: false,
            expandedWidth: customizationSettings.expandedWidth,
            maxExpandedHeight: customizationSettings.maxExpandedHeight,
            activeUtility: model.activeUtility
        )
    }

    private var headerTitle: String {
        model.activeUtility?.title ?? (model.visiblePanels.isEmpty ? "Модули" : model.selectedPanel.title)
    }

    private var recognizeTextAction: (([URL]) -> Void)? {
        guard model.modules.isEnabled(.textRecognition) else { return nil }
        return { model.recognizeText($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ExpandedNotchHeader(
                title: headerTitle,
                physicalNotchSize: layoutMetrics.physicalNotchSize,
                sideWingWidth: layoutMetrics.expandedHeaderWingWidth(
                    width: customizationSettings.expandedWidth
                ),
                showsMascot: showsSettingsMascot,
                isPinned: model.isExpansionPinned,
                onTogglePin: model.toggleExpansionPin,
                onShowSettings: { onOpenSettings(.general) }
            )
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : 3)
            .animation(contentAnimation, value: contentVisible)

            navigationBar
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NotchPalette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 22)
                    .allowsHitTesting(false)
            }
            .padding(.bottom, 6)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : 3)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.03), value: contentVisible)

            mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : 3)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.06), value: contentVisible)

            if !customizationSettings.actions(at: .bottom).isEmpty {
                bottomQuickActions
            }

            footer
            .font(.system(size: 10, weight: .medium, design: .default))
            .foregroundStyle(NotchPalette.secondary)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(NotchPalette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 22)
                    .allowsHitTesting(false)
            }
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : 3)
            .animation(contentAnimation.delay(reduceMotion ? 0 : 0.06), value: contentVisible)
        }
        .frame(width: expandedSize.width, height: expandedSize.height)

        .onAppear {
            withAnimation(contentAnimation) {
                model.expandedContentVisible = true
            }
        }
        .onDisappear {
            model.expandedContentVisible = false
        }
        .task {
            // Present the selected page first; prepare swipe neighbors after its fade.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            hasPreparedNeighbors = true
        }
        .contentShape(Rectangle())
    }

    private var navigationBar: some View {
        HStack(spacing: 4) {
            utilityButton(.overview, icon: "square.grid.2x2")
            PanelSwitcher(
                panels: model.visiblePanels,
                selectedPanel: model.activeUtility == nil ? model.selectedPanel : nil,
                badge: panelBadge,
                onSelect: selectPanel
            )
            utilityButton(.search, icon: "magnifyingglass")
            if model.modules.isEnabled(.fileShelf) {
                utilityButton(.files, icon: "tray")
            }
            Button(action: model.requestCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(NotchButtonStyle())
            .accessibilityLabel("Свернуть чёлку")
            .help("Свернуть чёлку и снять закрепление")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.activeUtility == .recentCaptures {
            recentCapturesContent
        } else if model.activeUtility == .scratchpad {
            ScratchpadPanel(store: model.scratchpad,
                            onExportPresentationChange: { presented in
                if presented { model.transientSurfaceDidPresent(.scratchpadExport) }
                else { model.transientSurfaceDidDisappear(.scratchpadExport) }
            }, dismissalRequest: model.transientSurfaceDismissalRequest)
        } else if model.activeUtility == .overview {
            NotchOverviewPanel(model: model, onOpenSettings: { onOpenSettings(.modules) })
        } else if model.activeUtility == .search {
            UnifiedSearchPanel(model: model)
        } else if model.activeUtility == .files {
            FileShelfPanel(store: model.fileShelfStore, onChooseFiles: model.chooseShelfFiles,
                           onProcessFiles: model.openFileActions, onRecognizeText: recognizeTextAction)
        } else if model.visiblePanels.isEmpty {
            emptyModulesState
        } else {
            SwipeCarousel(
                items: model.visiblePanels,
                selection: model.selectedPanel,
                translation: swipeTranslation,
                retainedRadius: hasPreparedNeighbors ? 1 : 0
            ) { panel in panelPage(panel) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                HorizontalSwipeMonitor(
                    onChanged: updateSwipe,
                    onThresholdReached: commitSwipe,
                    onEnded: finishSwipe
                )
            }
        }
    }

    private var recentCapturesContent: some View {
        RecentCapturesPanel(store: model.recentCaptures, onAddToShelf: addCaptureToShelf,
                            onFolderPickerPresentationChange: { presented in
            if presented { model.transientSurfaceDidPresent(.recentCapturesFolderPicker) }
            else { model.transientSurfaceDidDisappear(.recentCapturesFolderPicker) }
        }, dismissalRequest: model.transientSurfaceDismissalRequest)
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    private var addCaptureToShelf: ((URL) -> Void)? {
        guard model.modules.isEnabled(.fileShelf) else { return nil }
        return { model.addRecentCaptureToShelf($0) }
    }

    private var emptyModulesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NotchPalette.secondary)
            Text("Выберите модули для чёлки")
                .font(.system(size: 14, weight: .semibold))
            Text("Включить панели можно в настройках NooL App.")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.secondary)
            Button("Открыть модули") { onOpenSettings(.modules) }
                .buttonStyle(NotchButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func panelPage(_ panel: PanelID) -> some View {
        switch panel {
        case .ai:
            AIPanel(model: model)
        case .live:
            LiveActivitiesPanel(model: model)
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

    private func utilityButton(_ utility: NotchUtilityPanel, icon: String) -> some View {
        Button {
            if model.activeUtility == utility { model.closeUtility() }
            else { model.openUtility(utility) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.activeUtility == utility ? NotchPalette.accent : NotchPalette.secondary)
                .frame(width: 34, height: 40)
                .background(model.activeUtility == utility ? NotchPalette.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if utility == .files, model.fileShelfStore.entries.isEmpty == false {
                        Circle().fill(NotchPalette.accent).frame(width: 5, height: 5).padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(utility.title)
        .help(utility.title)
    }

    private var bottomQuickActions: some View {
        HStack(spacing: 8) {
            ForEach(customizationSettings.actions(at: .bottom)) { action in
                Button { onQuickAction(action.action) } label: {
                    Label(action.title, systemImage: action.iconName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(NotchButtonStyle())
                .help(action.title)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .opacity(contentVisible ? 1 : 0)
    }

    private func selectPanel(_ panel: PanelID) {
        guard panel != model.selectedPanel || model.activeUtility != nil else { return }
        hasPreparedNeighbors = true
        withAnimation(carouselAnimation) {
            swipeTranslation = 0
            model.selectPanel(panel)
        }
    }

    private func updateSwipe(_ distance: CGFloat) {
        guard reduceMotion == false else { return }
        hasPreparedNeighbors = true
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
                .fill(NotchPalette.accent)
                .frame(width: 6, height: 6)

            Text(freshnessText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.activeUtility == nil, model.visiblePanels.count > 1 {
                HStack(spacing: 5) {
                    ForEach(model.visiblePanels) { panel in
                        Capsule()
                            .fill(
                                panel == model.selectedPanel
                                    ? NotchPalette.accent
                                    : NotchPalette.track
                            )
                            .frame(width: panel == model.selectedPanel ? 12 : 5, height: 5)
                    }
                }

                if model.hasCompletedPanelSwipe == false {
                    Text("свайп двумя пальцами")
                        .foregroundStyle(NotchPalette.secondary)
                }
            }
        }
    }

    private var freshnessText: String {
        if model.activeUtility == .overview { return "\(model.visiblePanels.count) панелей в чёлке" }
        if let utility = model.activeUtility { return utility.title }
        guard let date = model.lastUpdatedAt(for: model.selectedPanel) else {
            return "нет свежих данных"
        }
        return "обновлено \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func panelBadge(_ panel: PanelID) -> PanelTabBadge? {
        switch panel {
        case .ai:
            let warningCount = model.numericBadgeCount(for: .ai) ?? 0
            guard warningCount > 0 else { return nil }
            return PanelTabBadge(
                text: String(warningCount),
                color: model.aiAttentionCount > 0 ? Color.signalAmber : Color.signalCoral
            )
        case .live:
            let count = model.numericBadgeCount(for: .live) ?? 0
            guard count > 0 else { return nil }
            return PanelTabBadge(
                text: String(min(count, 99)),
                color: NotchPalette.text.opacity(0.42)
            )
        case .calendar:
            let todayCount = model.numericBadgeCount(for: .calendar) ?? 0
            guard todayCount > 0 else { return nil }
            return PanelTabBadge(
                text: String(todayCount),
                color: NotchPalette.text.opacity(0.42)
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
            guard issueCount > 0 else { return nil }
            let startOfToday = Calendar.current.startOfDay(for: .now)
            let hasOverdue = issues.contains { issue in
                issue.dueDate.map { $0 < startOfToday } ?? false
            }
            return PanelTabBadge(
                text: issueCount > 99 ? "99+" : String(issueCount),
                color: hasOverdue
                    ? Color.signalCoral
                    : NotchPalette.text.opacity(0.42)
            )
        }
    }
}

private struct ExpandedNotchHeader: View {
    let title: String
    let physicalNotchSize: CGSize
    let sideWingWidth: CGFloat?
    let showsMascot: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
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
            .padding(.bottom, 6)
        } else {
            HStack(spacing: 10) {
                leadingContent
                Spacer()
                trailingContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, NotchLayout.expandedTopPadding)
            .padding(.bottom, 6)
        }
    }

    private var leadingContent: some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(NotchPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var trailingContent: some View {
        HStack(spacing: 8) {
            if showsMascot, sideWingWidth.map({ $0 >= 146 }) ?? true {
                NoolWavingMascot()
                    .frame(width: 32, height: 40)
            }

            HeaderButton(
                icon: isPinned ? "pin.fill" : "pin",
                label: isPinned ? "Снять закрепление чёлки" : "Оставить чёлку открытой",
                isSelected: isPinned,
                action: onTogglePin
            )

            HeaderButton(
                icon: "gearshape",
                label: "Открыть настройки",
                action: onShowSettings
            )
        }
    }
}

private struct HeaderButton: View {
    let icon: String
    let label: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? NotchPalette.accent : NotchPalette.text.opacity(0.85))
                .frame(width: 40, height: 40)
                .background(
                    isSelected ? NotchPalette.accent.opacity(0.18) : NotchPalette.raised,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(label)
    }
}

private struct PanelSwitcher: View {
    let panels: [PanelID]
    let selectedPanel: PanelID?
    let badge: (PanelID) -> PanelTabBadge?
    let onSelect: (PanelID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                tabs
            }
            .onAppear { if let selectedPanel { proxy.scrollTo(selectedPanel) } }
            .onChange(of: selectedPanel) { _, panel in
                guard let panel else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(panel)
                }
            }
        }
        .frame(height: 40)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(panels) { panel in
                Button {
                    onSelect(panel)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: panel.iconName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(panel.title)
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .lineLimit(1)
                        if let badge = badge(panel) {
                            PanelTabBadgeView(badge: badge)
                        }
                    }
                    .foregroundStyle(selectedPanel == panel ? NotchPalette.text : NotchPalette.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Capsule().fill(NotchPalette.accent)
                            .frame(height: 3)
                            .padding(.horizontal, 6)
                            .opacity(selectedPanel == panel ? 1 : 0)
                    }
                }
                .buttonStyle(NotchButtonStyle())
                .id(panel)
                .accessibilityAddTraits(selectedPanel == panel ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
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
                    .font(.system(size: 8, weight: .bold, design: .default))
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
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(NotchPalette.text)
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(NotchPalette.text.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .padding(20)
    }
}
