import AppKit

enum DockLayout {
    static let baseCellWidth: CGFloat = 64
    static let baseSpacing: CGFloat = 6
    static let baseHeight: CGFloat = 52
    static let basePadding: CGFloat = 6
    static let iconSize: CGFloat = 44
    /// Strip padding plus the scroll view's inner inset, before scaling.
    static let chromeWidth: CGFloat = 2 * basePadding + 6

    static func cellWidth(scale: Double) -> CGFloat { baseCellWidth * normalizedScale(scale) }
    static func spacing(scale: Double) -> CGFloat { baseSpacing * normalizedScale(scale) }
    static func contentHeight(showLabels: Bool = false) -> CGFloat { baseHeight + (showLabels ? 14 : 0) }
    static func height(scale: Double, showLabels: Bool = false) -> CGFloat {
        (contentHeight(showLabels: showLabels) + 2 * basePadding) * normalizedScale(scale)
    }
    static func width(span: Int, scale: Double) -> CGFloat {
        let span = CGFloat(max(1, min(64, span)))
        return span * cellWidth(scale: scale) + (span - 1) * spacing(scale: scale)
    }
    /// Separator and fixed cells (Downloads, Trash) after the scrolling application area.
    static func trailingWidth(cells: Int, scale: Double) -> CGFloat {
        guard cells > 0 else { return chromeWidth * normalizedScale(scale) }
        return chromeWidth * normalizedScale(scale) + 1 + spacing(scale: scale)
            + width(span: cells, scale: scale) + spacing(scale: scale)
    }

    /// Length of one item along the Dock axis. A vertical Dock stacks cells by their height.
    static func itemLength(span: Int, scale: Double, showLabels: Bool, vertical: Bool) -> CGFloat {
        vertical ? contentHeight(showLabels: showLabels) * normalizedScale(scale) : width(span: span, scale: scale)
    }

    /// Full strip length along its axis: items, section separators, trailing cells and chrome.
    static func stripLength(spans: [Int], separators: Int, trailingCells: Int, scale: Double,
                            showLabels: Bool, vertical: Bool) -> CGFloat {
        let gap = spacing(scale: scale)
        let unit = itemLength(span: 1, scale: scale, showLabels: showLabels, vertical: vertical)
        let items = spans.reduce(CGFloat(0)) {
            $0 + itemLength(span: vertical ? 1 : $1, scale: scale, showLabels: showLabels, vertical: vertical)
        } + CGFloat(max(0, spans.count - 1)) * gap
        let sections = CGFloat(max(0, separators)) * (1 + gap)
        let trailing = trailingCells > 0
            ? 1 + 2 * gap + CGFloat(trailingCells) * unit + CGFloat(trailingCells - 1) * gap : 0
        return items + sections + trailing + chromeWidth * normalizedScale(scale)
    }

    /// Thickness of a vertical Dock: one cell plus padding.
    static func verticalThickness(scale: Double) -> CGFloat {
        (baseCellWidth + 2 * basePadding) * normalizedScale(scale)
    }

    static func effectiveSpan(_ requested: Int, supported: [Int], availableWidth: CGFloat,
                              scale: Double) -> Int {
        let positive = supported.filter { $0 > 0 }.sorted()
        let fitting = positive.filter { width(span: $0, scale: scale) <= availableWidth }
        return fitting.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 1
    }

    static func frame(screenFrame: CGRect, visibleFrame: CGRect, contentWidth: CGFloat,
                      scale: Double, replacingSystemDock: Bool, showLabels: Bool = false,
                      position: DockPosition = .bottom) -> CGRect {
        let bounds = replacingSystemDock ? screenFrame : visibleFrame
        if position.isVertical {
            let width = min(verticalThickness(scale: scale), max(1, bounds.width - 24))
            let height = min(max(1, bounds.height - 24), max(180, contentWidth))
            let x = position == .left ? bounds.minX + 8 : bounds.maxX - 8 - width
            return CGRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
        }
        let width = min(max(1, bounds.width - 24), max(180, contentWidth))
        let height = min(height(scale: scale, showLabels: showLabels), max(1, bounds.height - 24))
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY + 8,
                      width: width, height: height)
    }

    /// Transparent room on the side away from the screen edge, so a bouncing or magnified
    /// icon rises above the strip instead of being cut by the window. Clicks pass through it.
    static func headroom(scale: Double) -> CGFloat { 20 * normalizedScale(scale) }

    /// The panel frame: the strip plus headroom towards the screen's interior.
    static func windowFrame(strip: CGRect, position: DockPosition, scale: Double) -> CGRect {
        let room = headroom(scale: scale)
        switch position {
        case .bottom: return CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: strip.height + room)
        case .left: return CGRect(x: strip.minX, y: strip.minY, width: strip.width + room, height: strip.height)
        case .right: return CGRect(x: strip.minX - room, y: strip.minY, width: strip.width + room, height: strip.height)
        }
    }

    static func triggerFrame(screenFrame: CGRect, dockFrame: CGRect, position: DockPosition = .bottom) -> CGRect {
        switch position {
        case .bottom: CGRect(x: dockFrame.minX, y: screenFrame.minY, width: dockFrame.width, height: 5)
        case .left: CGRect(x: screenFrame.minX, y: dockFrame.minY, width: 5, height: dockFrame.height)
        case .right: CGRect(x: screenFrame.maxX - 5, y: dockFrame.minY, width: 5, height: dockFrame.height)
        }
    }

    static func canHide(hovered: Bool, interacting: Bool, mouseButtons: Int) -> Bool {
        !hovered && !interacting && mouseButtons == 0
    }

    /// NSScreen.main follows the key window and is not the display marked
    /// primary in macOS. Select by CGMainDisplayID, independent of keyboard focus.
    static func selectedDisplayID(preferredUUID: String, displays: [(id: UInt32, uuid: String)],
                                  primaryID: UInt32) -> UInt32? {
        if !preferredUUID.isEmpty, let explicit = displays.first(where: { $0.uuid == preferredUUID }) {
            return explicit.id
        }
        return displays.first(where: { $0.id == primaryID })?.id ?? displays.first?.id
    }

    private static func normalizedScale(_ value: Double) -> CGFloat {
        CGFloat(value.isFinite ? min(1.4, max(0.7, value)) : 1)
    }
}
