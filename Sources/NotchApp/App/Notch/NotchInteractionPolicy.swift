import QuartzCore
import SwiftUI

enum NotchMotion {
    static let compactResizeDuration: TimeInterval = 0.36
    static let expansionDuration: TimeInterval = 0.54
    static let collapseDuration: TimeInterval = 0.30

    static func layoutAnimation(isExpanded: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.2, 0, 0, 1, duration: isExpanded ? expansionDuration : collapseDuration)
    }

    static func compactResizeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.2, 0, 0, 1, duration: compactResizeDuration)
    }

    static func compactResizeTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    }
}

enum NotchHoverAction: Equatable {
    case cancelCollapse
    case scheduleCollapse
    case none
}

enum NotchHoverPolicy {
    static let expansionAnimationDuration: TimeInterval = NotchMotion.expansionDuration
    static let collapseGracePeriod: TimeInterval = 0.18

    static func expansionDelay(configuredDelay: TimeInterval) -> TimeInterval {
        guard configuredDelay.isFinite else { return 0.5 }
        let clamped = min(1.5, max(0, configuredDelay))
        return (clamped * 2).rounded() / 2
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
            return .none
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
