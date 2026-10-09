import AppKit
import SwiftUI

struct NotchLayoutMetrics: Equatable {
    let physicalNotchSize: CGSize

    var compactSize: CGSize {
        compactSize(isPlaying: true)
    }

    func compactSize(
        isPlaying: Bool,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        showsAgentMascot: Bool = false,
        isHovered: Bool = false
    ) -> CGSize {
        var baseSize = baseCompactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight
        )

        if isHovered {
            baseSize.width += 24
            baseSize.height += 6
        }
        guard showsAgentMascot else { return baseSize }
        return CGSize(
            width: baseSize.width + NotchLayout.compactAgentMascotLaneWidth * 2,
            height: baseSize.height + NotchLayout.compactAgentMascotHeightIncrease
        )
    }

    private func baseCompactSize(
        isPlaying: Bool,
        compactHeight: CGFloat
    ) -> CGSize {
        let interactionHeight = max(NotchLayout.compactInteractionHeight, compactHeight)

        guard physicalNotchSize.width > 0, physicalNotchSize.height > 0 else {
            return CGSize(
                width: NotchLayout.compactContentWidth,
                height: interactionHeight
            )
        }

        guard isPlaying else {
            return CGSize(
                width: physicalNotchSize.width + NotchLayout.compactIdleWingWidth * 2,
                height: max(interactionHeight, physicalNotchSize.height)
            )
        }

        return CGSize(
            width: physicalNotchSize.width + NotchLayout.compactWingWidth * 2,
            height: max(interactionHeight, physicalNotchSize.height)
        )
    }

    var expandedSize: CGSize {
        expandedSize(width: nil)
    }

    func expandedSize(width: CGFloat?) -> CGSize {
        CGSize(width: width ?? NotchLayout.expandedContentSize.width,
               height: NotchLayout.expandedContentSize.height + physicalNotchSize.height)
    }

    var expandedMusicSize: CGSize {
        expandedMusicSize(width: nil)
    }

    func expandedMusicSize(width: CGFloat?) -> CGSize {
        let hasPhysicalNotch = physicalNotchSize.width > 0 && physicalNotchSize.height > 0
        return CGSize(
            width: width ?? NotchLayout.expandedContentSize.width,
            height: hasPhysicalNotch ? 380 : 404
        )
    }

    var expandedCalendarSize: CGSize {
        expandedCalendarSize(width: nil)
    }

    func expandedCalendarSize(width: CGFloat?) -> CGSize {
        CGSize(width: width ?? NotchLayout.expandedCalendarContentSize.width,
               height: NotchLayout.expandedCalendarContentSize.height + physicalNotchSize.height)
    }

    var expandedHeaderWingWidth: CGFloat? {
        expandedHeaderWingWidth(width: nil)
    }

    func expandedHeaderWingWidth(width: CGFloat?) -> CGFloat? {
        guard physicalNotchSize.width > 0, physicalNotchSize.height > 0 else {
            return nil
        }

        let availableWidth = (width ?? expandedSize.width) - physicalNotchSize.width
        guard availableWidth > 0 else { return nil }
        return availableWidth / 2
    }
}

enum NotchLayout {
    static let compactContentWidth: CGFloat = 226
    static let compactHeightRange: ClosedRange<CGFloat> = 39...42
    static let defaultCompactHeight: CGFloat = 40
    static let compactInteractionHeight: CGFloat = 40
    static let compactIdleWingWidth: CGFloat = 18
    static let compactWingWidth: CGFloat = 60
    static let compactAgentMascotLaneWidth: CGFloat = 50
    static let compactAgentMascotHeightIncrease: CGFloat = 12
    static let compactHoverHorizontalPadding: CGFloat = 18
    static let compactHoverBottomPadding: CGFloat = 16
    static let compactBottomRadius: CGFloat = 12
    static let expandedContentSize = CGSize(width: 500, height: 300)
    static let expandedCalendarContentSize = CGSize(width: 500, height: 460)
    static let expandedTopPadding: CGFloat = 24
    static let expandedSideControlLaneWidth: CGFloat = 60
    static let expandedSideControlButtonSize: CGFloat = 42
    static let expandedSideControlSpacing: CGFloat = 10

    static var physicalNotchSize: CGSize { currentMetrics.physicalNotchSize }
    static var compactSize: CGSize { currentMetrics.compactSize }
    static func compactSize(
        isPlaying: Bool,
        compactHeight: CGFloat = defaultCompactHeight,
        showsAgentMascot: Bool = false,
        isHovered: Bool = false
    ) -> CGSize {
        currentMetrics.compactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight,
            showsAgentMascot: showsAgentMascot,
            isHovered: isHovered
        )
    }
    static var expandedSize: CGSize { currentMetrics.expandedSize }
    static var expandedMusicSize: CGSize { currentMetrics.expandedMusicSize }
    static var expandedCalendarSize: CGSize { currentMetrics.expandedCalendarSize }
    static var expandedHeaderWingWidth: CGFloat? { currentMetrics.expandedHeaderWingWidth }

    static func metrics(
        safeAreaTop: CGFloat,
        leftAuxiliaryArea: CGRect?,
        rightAuxiliaryArea: CGRect?
    ) -> NotchLayoutMetrics {
        guard safeAreaTop > 0,
              let leftAuxiliaryArea,
              let rightAuxiliaryArea else {
            return NotchLayoutMetrics(physicalNotchSize: .zero)
        }

        let cutoutWidth = max(0, rightAuxiliaryArea.minX - leftAuxiliaryArea.maxX)
        guard cutoutWidth > 0 else {
            return NotchLayoutMetrics(physicalNotchSize: .zero)
        }

        return NotchLayoutMetrics(
            physicalNotchSize: CGSize(width: cutoutWidth, height: safeAreaTop)
        )
    }

    static var currentMetrics: NotchLayoutMetrics {
        guard let screen = NSScreen.preferredNotchScreen else {
            return NotchLayoutMetrics(physicalNotchSize: .zero)
        }

        return metrics(
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliaryArea: screen.auxiliaryTopLeftArea,
            rightAuxiliaryArea: screen.auxiliaryTopRightArea
        )
    }
}

enum NotchWindowSizingPolicy {
    static func compactInteractionSize(
        metrics: NotchLayoutMetrics,
        isPlaying: Bool = true,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        showsAgentMascot: Bool = false,
        isHovered: Bool = false
    ) -> CGSize {
        let visibleSize = metrics.compactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight,
            showsAgentMascot: showsAgentMascot,
            isHovered: isHovered
        )
        return CGSize(
            width: visibleSize.width + NotchLayout.compactHoverHorizontalPadding * 2,
            height: visibleSize.height + NotchLayout.compactHoverBottomPadding
        )
    }

    static func size(
        metrics: NotchLayoutMetrics,
        isExpanded: Bool,
        selectedPanel: PanelID,
        calendarViewMode: CalendarViewMode,
        isShowingSettings: Bool,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        isPlaying: Bool = true,
        showsAgentMascot: Bool = false,
        isHovered: Bool = false,
        expandedWidth: CGFloat? = nil,
        maxExpandedHeight: CGFloat? = nil,
        activeUtility: NotchUtilityPanel? = nil
    ) -> CGSize {
        guard isExpanded else {
            return compactInteractionSize(
                metrics: metrics,
                isPlaying: isPlaying,
                compactHeight: compactHeight,
                showsAgentMascot: showsAgentMascot,
                isHovered: isHovered
            )
        }
        let expandedSize: CGSize
        guard isShowingSettings == false else {
            expandedSize = metrics.expandedSize(width: expandedWidth)
            return Self.clampHeight(expandedSize, maximum: maxExpandedHeight)
        }

        if activeUtility == .overview || activeUtility == .scratchpad || activeUtility == .recentCaptures {
            expandedSize = CGSize(width: expandedWidth ?? metrics.expandedSize.width, height: 420)
        } else if selectedPanel == .ai {
            expandedSize = CGSize(width: expandedWidth ?? metrics.expandedSize.width, height: 440)
        } else if selectedPanel == .live {
            expandedSize = CGSize(width: expandedWidth ?? metrics.expandedSize.width, height: 300)
        } else if selectedPanel == .music || selectedPanel == .jira {
            expandedSize = metrics.expandedMusicSize(width: expandedWidth)
        } else if selectedPanel == .calendar, calendarViewMode == .month {
            expandedSize = metrics.expandedCalendarSize(width: expandedWidth)
        } else {
            expandedSize = metrics.expandedSize(width: expandedWidth)
        }
        return Self.clampHeight(expandedSize, maximum: maxExpandedHeight)
    }

    /// Outer NSPanel size. The expanded content remains centered at its existing
    /// width while the reserved side lanes host the animated round controls.
    static func panelSize(
        metrics: NotchLayoutMetrics,
        isExpanded: Bool,
        selectedPanel: PanelID,
        calendarViewMode: CalendarViewMode,
        isShowingSettings: Bool,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        isPlaying: Bool = true,
        showsAgentMascot: Bool = false,
        isHovered: Bool = false,
        expandedWidth: CGFloat? = nil,
        maxExpandedHeight: CGFloat? = nil,
        hasSideControls: Bool = true,
        activeUtility: NotchUtilityPanel? = nil
    ) -> CGSize {
        let contentSize = size(
            metrics: metrics,
            isExpanded: isExpanded,
            selectedPanel: selectedPanel,
            calendarViewMode: calendarViewMode,
            isShowingSettings: isShowingSettings,
            compactHeight: compactHeight,
            isPlaying: isPlaying,
            showsAgentMascot: showsAgentMascot,
            isHovered: isHovered,
            expandedWidth: expandedWidth,
            maxExpandedHeight: maxExpandedHeight,
            activeUtility: activeUtility
        )
        guard isExpanded, isShowingSettings == false else { return contentSize }
        let sideControlWidth = hasSideControls
            ? NotchLayout.expandedSideControlLaneWidth * 2
            : 0
        return CGSize(width: contentSize.width + sideControlWidth, height: contentSize.height)
    }

    private static func clampHeight(_ size: CGSize, maximum: CGFloat?) -> CGSize {
        guard let maximum, maximum.isFinite, maximum > 0 else { return size }
        return CGSize(width: size.width, height: min(size.height, maximum))
    }
}

struct PhysicalNotchSafeZone: View {
    let size: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            Color.black
                .frame(width: size.width, height: size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
