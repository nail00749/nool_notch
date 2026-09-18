import Foundation

/// Pure geometry in global Accessibility coordinates (origin at the main display's top left).
enum WindowLayoutGeometry {
    static func screen(for rect: WindowLayoutRect, in screens: [WindowLayoutScreen]) -> WindowLayoutScreen? {
        guard !screens.isEmpty else { return nil }
        return screens.max { lhs, rhs in
            let lhsOverlap = overlap(rect, lhs.frame)
            let rhsOverlap = overlap(rect, rhs.frame)
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            let lhsDistance = distanceSquared(rect, lhs.frame)
            let rhsDistance = distanceSquared(rect, rhs.frame)
            return lhsDistance > rhsDistance
        }
    }

    static func target(
        for action: WindowLayoutAction,
        current: WindowLayoutRect,
        screens: [WindowLayoutScreen]
    ) -> WindowLayoutRect? {
        guard let source = screen(for: current, in: screens) else { return nil }
        let visible = source.visibleFrame
        switch action {
        case .left:
            return WindowLayoutRect(x: visible.x, y: visible.y,
                                    width: visible.width / 2, height: visible.height)
        case .right:
            return WindowLayoutRect(x: visible.x + visible.width / 2, y: visible.y,
                                    width: visible.width / 2, height: visible.height)
        case .maximize:
            return visible
        case .center:
            return clamp(WindowLayoutRect(
                x: visible.centerX - current.width / 2,
                y: visible.centerY - current.height / 2,
                width: current.width, height: current.height
            ), to: visible)
        case .nextDisplay:
            guard screens.count > 1,
                  let sourceIndex = screens.firstIndex(where: { $0.id == source.id }) else {
                return nil
            }
            let destination = screens[(sourceIndex + 1) % screens.count].visibleFrame
            return restore(normalize(current, in: visible), to: destination)
        }
    }

    static func normalize(_ rect: WindowLayoutRect, in visible: WindowLayoutRect) -> WindowLayoutRect {
        guard visible.isUsable else { return WindowLayoutRect(x: 0, y: 0, width: 1, height: 1) }
        return WindowLayoutRect(
            x: (rect.x - visible.x) / visible.width,
            y: (rect.y - visible.y) / visible.height,
            width: rect.width / visible.width,
            height: rect.height / visible.height
        )
    }

    static func restore(_ normalized: WindowLayoutRect, to visible: WindowLayoutRect) -> WindowLayoutRect {
        guard normalized.isUsable, visible.isUsable else { return visible }
        return clamp(WindowLayoutRect(
            x: visible.x + normalized.x * visible.width,
            y: visible.y + normalized.y * visible.height,
            width: normalized.width * visible.width,
            height: normalized.height * visible.height
        ), to: visible)
    }

    static func clamp(_ rect: WindowLayoutRect, to visible: WindowLayoutRect) -> WindowLayoutRect {
        guard visible.isUsable else { return rect }
        let width = min(max(rect.width, 1), visible.width)
        let height = min(max(rect.height, 1), visible.height)
        return WindowLayoutRect(
            x: min(max(rect.x, visible.x), visible.maxX - width),
            y: min(max(rect.y, visible.y), visible.maxY - height),
            width: width, height: height
        )
    }

    private static func overlap(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Double {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.x, rhs.x))
            * max(0, min(lhs.maxY, rhs.maxY) - max(lhs.y, rhs.y))
    }

    private static func distanceSquared(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Double {
        let x = lhs.centerX - rhs.centerX
        let y = lhs.centerY - rhs.centerY
        return x * x + y * y
    }
}
