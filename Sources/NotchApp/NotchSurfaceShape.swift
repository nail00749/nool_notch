import SwiftUI

/// One surface follows the hosting view's actual bounds during NSPanel resizing.
/// It must not animate toward a second, independently timed SwiftUI frame.
struct NotchSurfaceShape: Shape {
    let compactWindowSize: CGSize
    let compactSurfaceHeight: CGFloat
    let expandedHeight: CGFloat
    var holdsExpandedShape = false

    func surfaceRect(in rect: CGRect) -> CGRect {
        let progress = expansionProgress(in: rect)
        let sideInset = NotchLayout.compactHoverHorizontalPadding * (1 - progress)
        let bottomInset = max(0, compactWindowSize.height - compactSurfaceHeight) * (1 - progress)
        return CGRect(
            x: rect.minX + sideInset, y: rect.minY,
            width: max(0, rect.width - sideInset * 2),
            height: max(0, rect.height - bottomInset)
        )
    }

    func path(in rect: CGRect) -> Path {
        let radius = NotchLayout.compactBottomRadius
            + (28 - NotchLayout.compactBottomRadius) * expansionProgress(in: rect)
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: radius,
                bottomTrailing: radius, topTrailing: 0
            ), style: .continuous
        ).path(in: surfaceRect(in: rect))
    }

    private func expansionProgress(in rect: CGRect) -> CGFloat {
        if holdsExpandedShape { return 1 }
        let distance = expandedHeight - compactWindowSize.height
        guard distance > 0 else { return 1 }
        return min(1, max(0, (rect.height - compactWindowSize.height) / distance))
    }
}
