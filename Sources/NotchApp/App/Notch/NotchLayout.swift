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
        CGSize(
            width: NotchLayout.expandedContentSize.width,
            height: NotchLayout.expandedContentSize.height + physicalNotchSize.height
        )
    }

    var expandedMusicSize: CGSize {
        let hasPhysicalNotch = physicalNotchSize.width > 0 && physicalNotchSize.height > 0
        return CGSize(
            width: NotchLayout.expandedContentSize.width,
            height: hasPhysicalNotch ? 380 : 404
        )
    }

    var expandedCalendarSize: CGSize {
        CGSize(
            width: NotchLayout.expandedCalendarContentSize.width,
            height: NotchLayout.expandedCalendarContentSize.height + physicalNotchSize.height
        )
    }

    var expandedHeaderWingWidth: CGFloat? {
        guard physicalNotchSize.width > 0, physicalNotchSize.height > 0 else {
            return nil
        }

        let availableWidth = expandedSize.width - physicalNotchSize.width
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
        isHovered: Bool = false
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
        guard isShowingSettings == false else { return metrics.expandedSize }

        if selectedPanel == .live || selectedPanel == .music || selectedPanel == .jira {
            return metrics.expandedMusicSize
        }
        if selectedPanel == .calendar, calendarViewMode == .month {
            return metrics.expandedCalendarSize
        }
        return metrics.expandedSize
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
