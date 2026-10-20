import CoreGraphics
import Foundation

struct DisplayCursorCrossingScreen: Equatable, Sendable {
    let uuid: String
    let displayID: UInt32
    let frame: CGRect
}

struct DisplayCursorCrossingDestination: Equatable, Sendable {
    let source: DisplayCursorCrossingScreen
    let target: DisplayCursorCrossingScreen
    let point: CGPoint
}

/// CoreGraphics desktop coordinates: x rightward, y downward. No event state,
/// cursor warping, or native display queries belong in this geometry boundary.
enum DisplayCursorCrossingGeometry {
    private static let edgeTolerance: CGFloat = 1.25
    private static let planeTolerance: CGFloat = 0.5
    private static let inset: CGFloat = 2

    static func destination(location: CGPoint, delta: CGVector,
                            displays: [DisplayCursorCrossingScreen]) -> DisplayCursorCrossingDestination? {
        guard location.x.isFinite, location.y.isFinite, delta.dx.isFinite, delta.dy.isFinite,
              delta.dx != 0 || delta.dy != 0 else { return nil }
        let screens = usable(displays)
        guard let source = screens.first(where: { contains(location, in: $0.frame) }) else { return nil }
        let direction: Direction
        if abs(delta.dx) >= abs(delta.dy) { direction = delta.dx > 0 ? .right : .left }
        else { direction = delta.dy > 0 ? .down : .up }
        guard direction.isAtEdge(location, frame: source.frame) else { return nil }
        let neighbors = adjacent(to: source, direction: direction, screens: screens)
        let position = direction.orthogonal(location)
        // Never replace a route which macOS already handles, including a
        // different neighbor than the nearest projected destination.
        guard !neighbors.contains(where: { direction.span($0.frame).contains(position) }) else { return nil }
        return neighbors.map { target in
            let span = direction.span(target.frame)
            let orthogonal = min(span.upper - inset, max(span.lower + inset, position))
            return DisplayCursorCrossingDestination(source: source, target: target,
                point: direction.destination(orthogonal: orthogonal, frame: target.frame))
        }.min { lhs, rhs in
            let a = distance(location, lhs.point), b = distance(location, rhs.point)
            if a != b { return a < b }
            return lhs.target.uuid < rhs.target.uuid
        }
    }

    static func hasUnalignedEdges(in displays: [DisplayCursorCrossingScreen]) -> Bool {
        let screens = usable(displays)
        for source in screens {
            for direction in Direction.allCases {
                let neighbors = adjacent(to: source, direction: direction, screens: screens)
                guard !neighbors.isEmpty else { continue }
                let edge = direction.span(source.frame)
                let coverage = neighbors.map { direction.span($0.frame) }.map {
                    Span(lower: max(edge.lower, $0.lower), upper: min(edge.upper, $0.upper))
                }.sorted { $0.lower < $1.lower }
                var covered = edge.lower
                for interval in coverage {
                    if interval.lower > covered { return true }
                    covered = max(covered, interval.upper)
                }
                if covered < edge.upper { return true }
            }
        }
        return false
    }

    private struct Span {
        let lower: CGFloat
        let upper: CGFloat
        func contains(_ point: CGFloat) -> Bool { point >= lower && point < upper }
        func overlaps(_ other: Self) -> Bool { min(upper, other.upper) > max(lower, other.lower) }
    }

    private enum Direction: CaseIterable {
        case left, right, up, down
        var horizontal: Bool { self == .left || self == .right }
        func span(_ frame: CGRect) -> Span {
            horizontal ? Span(lower: frame.minY, upper: frame.maxY) : Span(lower: frame.minX, upper: frame.maxX)
        }
        func orthogonal(_ point: CGPoint) -> CGFloat { horizontal ? point.y : point.x }
        func plane(_ frame: CGRect) -> CGFloat {
            switch self {
            case .left: frame.minX
            case .right: frame.maxX
            case .up: frame.minY
            case .down: frame.maxY
            }
        }
        func facingPlane(_ frame: CGRect) -> CGFloat {
            switch self {
            case .left: frame.maxX
            case .right: frame.minX
            case .up: frame.maxY
            case .down: frame.minY
            }
        }
        func isAtEdge(_ point: CGPoint, frame: CGRect) -> Bool {
            abs((horizontal ? point.x : point.y) - plane(frame)) <= edgeTolerance
        }
        func destination(orthogonal: CGFloat, frame: CGRect) -> CGPoint {
            switch self {
            case .left: CGPoint(x: frame.maxX - inset, y: orthogonal)
            case .right: CGPoint(x: frame.minX + inset, y: orthogonal)
            case .up: CGPoint(x: orthogonal, y: frame.maxY - inset)
            case .down: CGPoint(x: orthogonal, y: frame.minY + inset)
            }
        }
    }

    private static func adjacent(to source: DisplayCursorCrossingScreen, direction: Direction,
                                 screens: [DisplayCursorCrossingScreen]) -> [DisplayCursorCrossingScreen] {
        screens.filter { target in
            target.uuid != source.uuid &&
                abs(direction.plane(source.frame) - direction.facingPlane(target.frame)) <= planeTolerance &&
                direction.span(source.frame).overlaps(direction.span(target.frame))
        }
    }

    private static func usable(_ displays: [DisplayCursorCrossingScreen]) -> [DisplayCursorCrossingScreen] {
        let uuids = Dictionary(grouping: displays, by: \.uuid).mapValues(\.count)
        let ids = Dictionary(grouping: displays, by: \.displayID).mapValues(\.count)
        let candidates = displays.filter { screen in
            let f = screen.frame
            return !screen.uuid.isEmpty && screen.displayID != 0 && uuids[screen.uuid] == 1 && ids[screen.displayID] == 1 &&
                f.origin.x.isFinite && f.origin.y.isFinite && f.size.width.isFinite && f.size.height.isFinite &&
                f.size.width >= 8 && f.size.height >= 8 && f.maxX.isFinite && f.maxY.isFinite
        }
        // Reject both participants of an overlap; picking whichever appeared
        // first would make source membership and the destination ambiguous.
        return candidates.filter { screen in
            !candidates.contains { other in
                other.uuid != screen.uuid &&
                    min(screen.frame.maxX, other.frame.maxX) > max(screen.frame.minX, other.frame.minX) &&
                    min(screen.frame.maxY, other.frame.maxY) > max(screen.frame.minY, other.frame.minY)
            }
        }
    }

    private static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let x = a.x - b.x, y = a.y - b.y
        return hypot(x, y)
    }
}
