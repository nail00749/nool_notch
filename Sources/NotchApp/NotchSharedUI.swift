import AppKit
import SwiftUI

enum NotchMotion {
    static let compactResizeDuration: TimeInterval = 0.36

    static func compactResizeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.2, 0, 0, 1, duration: compactResizeDuration)
    }

    static func compactResizeTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    }
}

enum PanelID: String, CaseIterable, Identifiable {
    case ai
    case calendar
    case music
    case jira

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai:
            "AI"
        case .calendar:
            "Календарь"
        case .music:
            "Музыка"
        case .jira:
            "Jira"
        }
    }

    var iconName: String {
        switch self {
        case .ai:
            "sparkles"
        case .calendar:
            "calendar"
        case .music:
            "waveform"
        case .jira:
            "checkmark.square"
        }
    }
}

enum AISection: String, CaseIterable, Identifiable {
    case limits
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: "Лимиты"
        case .sessions: "Inbox"
        }
    }
}

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case list
    case month

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .list:
            "list.bullet"
        case .month:
            "calendar"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .list:
            "Список событий"
        case .month:
            "Месяц"
        }
    }
}

struct NotchLayoutMetrics: Equatable {
    let physicalNotchSize: CGSize

    var compactSize: CGSize {
        compactSize(isPlaying: true)
    }

    func compactSize(
        isPlaying: Bool,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        showsAgentMascot: Bool = false
    ) -> CGSize {
        let baseSize = baseCompactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight
        )

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
        showsAgentMascot: Bool = false
    ) -> CGSize {
        currentMetrics.compactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight,
            showsAgentMascot: showsAgentMascot
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

enum NotchHoverAction: Equatable {
    case expand
    case cancelCollapse
    case scheduleCollapse
    case none
}

enum NotchWindowSizingPolicy {
    static func compactInteractionSize(
        metrics: NotchLayoutMetrics,
        isPlaying: Bool = true,
        compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
        showsAgentMascot: Bool = false
    ) -> CGSize {
        let visibleSize = metrics.compactSize(
            isPlaying: isPlaying,
            compactHeight: compactHeight,
            showsAgentMascot: showsAgentMascot
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
        showsAgentMascot: Bool = false
    ) -> CGSize {
        guard isExpanded else {
            return compactInteractionSize(
                metrics: metrics,
                isPlaying: isPlaying,
                compactHeight: compactHeight,
                showsAgentMascot: showsAgentMascot
            )
        }
        guard isShowingSettings == false else { return metrics.expandedSize }

        if selectedPanel == .music || selectedPanel == .jira {
            return metrics.expandedMusicSize
        }
        if selectedPanel == .calendar, calendarViewMode == .month {
            return metrics.expandedCalendarSize
        }
        return metrics.expandedSize
    }
}

enum NotchHoverPolicy {
    static let expansionAnimationDuration: TimeInterval = 0.54
    static let collapseGracePeriod: TimeInterval = 0.18

    static func expansionDelay(configuredDelay: TimeInterval) -> TimeInterval {
        guard configuredDelay.isFinite else { return 0.5 }
        let clamped = min(1, max(0, configuredDelay))
        return (clamped * 10).rounded() / 10
    }

    static func action(
        isHovering: Bool,
        isExpanded: Bool,
        hoverExpansionEnabled: Bool,
        isContextMenuVisible: Bool
    ) -> NotchHoverAction {
        if isHovering {
            if isExpanded {
                return .cancelCollapse
            }
            return hoverExpansionEnabled ? .expand : .none
        }

        guard isExpanded, isContextMenuVisible == false else { return .none }
        return .scheduleCollapse
    }

    static func collapseDelay(elapsedSinceExpansion: TimeInterval?) -> TimeInterval {
        guard let elapsedSinceExpansion else { return collapseGracePeriod }
        let remainingExpansion = max(0, expansionAnimationDuration - elapsedSinceExpansion)
        return remainingExpansion + collapseGracePeriod
    }

    static func shouldCollapse(
        pointerLocation: CGPoint,
        screenFrame: CGRect,
        windowSize: CGSize
    ) -> Bool {
        let windowFrame = CGRect(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        return windowFrame.contains(pointerLocation) == false
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

struct NotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension Color {
    static let signalMint = Color(red: 0.37, green: 0.96, blue: 0.72)
    static let signalCyan = Color(red: 0.34, green: 0.82, blue: 1.0)
    static let signalAmber = Color(red: 1.0, green: 0.72, blue: 0.31)
    static let signalCoral = Color(red: 1.0, green: 0.35, blue: 0.34)
}
