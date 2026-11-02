import CoreGraphics
import Foundation

struct LiveWallpaperPlexusSegment: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint
    let bucket: Int
}

/// Link tessellation follows the renderer's clock, independently of accelerated particle motion.
struct LiveWallpaperLinkClock {
    private var lastRefresh: TimeInterval?

    mutating func reset() { lastRefresh = nil }

    mutating func shouldRefresh(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        if let lastRefresh, time >= lastRefresh, time - lastRefresh + 1e-9 < 1.0 / 30 {
            return false
        }
        lastRefresh = time
        return true
    }
}

/// Reusable linked-cell scratch space. A cell holds indices into `points`, avoiding a dictionary
/// and a newly allocated array for each occupied cell on every link refresh.
struct LiveWallpaperPlexusLinks {
    static let radius: CGFloat = 170
    private var points: [CGPoint] = []
    private var heads: [Int] = []
    private var next: [Int] = []

    mutating func updatePoints(count: Int, positionAt: (Int) -> CGPoint) {
        points.removeAll(keepingCapacity: true)
        points.reserveCapacity(count)
        for index in 0..<count { points.append(positionAt(index)) }
        if next.count < count { next.append(contentsOf: repeatElement(-1, count: count - next.count)) }
    }

    mutating func forEachLink(_ visit: (CGPoint, CGPoint, Int) -> Void) {
        guard points.count > 1 else { return }
        let radius = Self.radius
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in points {
            minX = min(minX, floor(point.x / radius))
            minY = min(minY, floor(point.y / radius))
            maxX = max(maxX, floor(point.x / radius))
            maxY = max(maxY, floor(point.y / radius))
        }
        // Screen geometry normally needs only a few hundred cells. Keep scratch memory bounded
        // for extreme coordinates, with the same pairwise result as the ordinary grid path.
        guard let columns = Int(exactly: maxX - minX + 1),
              let rows = Int(exactly: maxY - minY + 1),
              columns > 0, rows > 0, columns <= 65_536, rows <= 65_536 / columns else {
            for first in points.indices {
                for second in (first + 1)..<points.count { visitPair(first, second, visit) }
            }
            return
        }
        let cellCount = columns * rows
        if heads.count < cellCount {
            heads.append(contentsOf: repeatElement(-1, count: cellCount - heads.count))
        }
        for index in 0..<cellCount { heads[index] = -1 }
        for index in points.indices {
            let x = Int(floor(points[index].x / radius) - minX)
            let y = Int(floor(points[index].y / radius) - minY)
            let cell = y * columns + x
            next[index] = heads[cell]
            heads[cell] = index
        }
        for first in points.indices {
            let homeX = Int(floor(points[first].x / radius) - minX)
            let homeY = Int(floor(points[first].y / radius) - minY)
            for x in max(0, homeX - 1)...min(columns - 1, homeX + 1) {
                for y in max(0, homeY - 1)...min(rows - 1, homeY + 1) {
                    var second = heads[y * columns + x]
                    while second >= 0 {
                        if second > first { visitPair(first, second, visit) }
                        second = next[second]
                    }
                }
            }
        }
    }

    func forEachPoint(_ visit: (CGPoint) -> Void) {
        for point in points { visit(point) }
    }

    private func visitPair(_ first: Int, _ second: Int, _ visit: (CGPoint, CGPoint, Int) -> Void) {
        let a = points[first], b = points[second]
        let dx = a.x - b.x, dy = a.y - b.y
        let squared = dx * dx + dy * dy
        guard squared < Self.radius * Self.radius else { return }
        let near = Self.radius / 3, middle = Self.radius * 2 / 3
        // Comparing squared thresholds preserves the three opacity bands without a sqrt per edge.
        let bucket = squared < near * near ? 0 : (squared < middle * middle ? 1 : 2)
        visit(a, b, bucket)
    }
}
