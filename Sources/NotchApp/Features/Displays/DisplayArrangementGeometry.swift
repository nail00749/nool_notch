import Foundation

enum DisplayArrangementDirection: String, CaseIterable, Identifiable {
    case left, right, above, below
    var id: Self { self }
    var title: String {
        switch self {
        case .left: "Слева"
        case .right: "Справа"
        case .above: "Сверху"
        case .below: "Снизу"
        }
    }
    var symbol: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .above: "arrow.up"
        case .below: "arrow.down"
        }
    }
}

/// CoreGraphics coordinates: increasing y moves down. Drafts stay connected and nonoverlapping.
enum DisplayArrangementGeometry {
    /// Preview panel outlines use EDID physical proportions. The editable draft
    /// remains in CoreGraphics desktop coordinates; it is never sent in mm.
    static func previewFrames(_ frames: [String: CGRect], displays: [DisplayInfo], mainID: String) -> [String: CGRect] {
        let ratios = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.aspectRatio) })
        let outlines = frames.mapValues { $0 }
        func size(_ id: String) -> CGSize {
            guard let frame = outlines[id] else { return .zero }
            let ratio = ratios[id] ?? (frame.width / frame.height)
            return CGSize(width: frame.width, height: frame.width / ratio)
        }
        guard let root = frames[mainID] else { return frames }
        var result = [mainID: CGRect(origin: root.origin, size: size(mainID))]
        var queue = [mainID]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let old = frames[id], let projected = result[id] else { continue }
            for otherID in frames.keys.sorted() where result[otherID] == nil {
                guard let other = frames[otherID], touches(old, other) else { continue }
                let otherSize = size(otherID)
                var relativeY = projected.minY + (other.minY - old.minY) * projected.height / old.height
                var relativeX = projected.minX + (other.minX - old.minX) * projected.width / old.width
                if abs(other.midY - old.midY) <= 0.5 { relativeY = projected.midY - otherSize.height / 2 }
                else if abs(other.maxY - old.maxY) <= 0.5 { relativeY = projected.maxY - otherSize.height }
                if abs(other.midX - old.midX) <= 0.5 { relativeX = projected.midX - otherSize.width / 2 }
                else if abs(other.maxX - old.maxX) <= 0.5 { relativeX = projected.maxX - otherSize.width }
                let origin: CGPoint
                if abs(old.maxX - other.minX) < 0.01 {
                    origin = CGPoint(x: projected.maxX, y: relativeY)
                } else if abs(other.maxX - old.minX) < 0.01 {
                    origin = CGPoint(x: projected.minX - otherSize.width, y: relativeY)
                } else if abs(old.maxY - other.minY) < 0.01 {
                    origin = CGPoint(x: relativeX, y: projected.maxY)
                } else {
                    origin = CGPoint(x: relativeX, y: projected.minY - otherSize.height)
                }
                result[otherID] = CGRect(origin: origin, size: otherSize)
                queue.append(otherID)
            }
        }
        for (id, frame) in frames where result[id] == nil {
            result[id] = CGRect(origin: frame.origin, size: size(id))
        }
        return result
    }

    static func normalized(_ frames: [String: CGRect], mainID: String) -> [String: CGRect] {
        guard let main = frames[mainID] else { return frames }
        return frames.mapValues { $0.offsetBy(dx: -main.minX, dy: -main.minY) }
    }

    /// A small attraction radius, supplied in preview coordinates by the view.
    /// Outside that radius the pointer remains completely free.
    static func magnetizedOrigin(_ id: String, proposedOrigin: CGPoint,
                                 frames: [String: CGRect], tolerance: CGFloat) -> CGPoint {
        guard let moving = frames[id], proposedOrigin.x.isFinite, proposedOrigin.y.isFinite,
              tolerance.isFinite, tolerance > 0 else { return proposedOrigin }
        var x = proposedOrigin.x
        var y = proposedOrigin.y
        var nearestX = tolerance
        var nearestY = tolerance
        let proposed = CGRect(origin: proposedOrigin, size: moving.size)
        for (otherID, target) in frames.sorted(by: { $0.key < $1.key }) where otherID != id {
            // Only attract screens that are already close enough to share an edge.
            guard proposed.insetBy(dx: -tolerance, dy: -tolerance).intersects(target) else { continue }
            for anchor in [target.midX - moving.width / 2, target.minX, target.maxX - moving.width,
                           target.minX - moving.width, target.maxX] {
                let distance = abs(anchor - proposedOrigin.x)
                if distance < nearestX { nearestX = distance; x = anchor }
            }
            for anchor in [target.midY - moving.height / 2, target.minY, target.maxY - moving.height,
                           target.minY - moving.height, target.maxY] {
                let distance = abs(anchor - proposedOrigin.y)
                if distance < nearestY { nearestY = distance; y = anchor }
            }
        }
        return CGPoint(x: x, y: y)
    }

    /// Translate visual alignment back to desktop coordinates, even when a
    /// panel's physical aspect ratio differs from its current desktop mode.
    static func desktopOrigin(_ id: String, previewOrigin: CGPoint,
                              frames: [String: CGRect], outlines: [String: CGRect]) -> CGPoint? {
        guard let moving = frames[id], let outline = outlines[id], outline.width > 0, outline.height > 0 else { return nil }
        var origin = CGPoint(x: moving.minX + (previewOrigin.x - outline.minX) * moving.width / outline.width,
                             y: moving.minY + (previewOrigin.y - outline.minY) * moving.height / outline.height)
        let proposed = CGRect(origin: previewOrigin, size: outline.size)
        for otherID in frames.keys.sorted() where otherID != id {
            guard let target = frames[otherID], let visual = outlines[otherID],
                  proposed.insetBy(dx: -1, dy: -1).intersects(visual) else { continue }
            if abs(proposed.midX - visual.midX) < 0.01 { origin.x = target.midX - moving.width / 2 }
            else if abs(proposed.minX - visual.minX) < 0.01 { origin.x = target.minX }
            else if abs(proposed.maxX - visual.maxX) < 0.01 { origin.x = target.maxX - moving.width }
            if abs(proposed.midY - visual.midY) < 0.01 { origin.y = target.midY - moving.height / 2 }
            else if abs(proposed.minY - visual.minY) < 0.01 { origin.y = target.minY }
            else if abs(proposed.maxY - visual.maxY) < 0.01 { origin.y = target.maxY - moving.height }
        }
        return origin
    }

    static func place(_ id: String, beside targetID: String, direction: DisplayArrangementDirection,
                      frames: [String: CGRect], mainID: String) -> [String: CGRect] {
        guard id != targetID, let moving = frames[id], let target = frames[targetID] else { return frames }
        let origin: CGPoint
        switch direction {
        case .left: origin = CGPoint(x: target.minX - moving.width, y: target.minY)
        case .right: origin = CGPoint(x: target.maxX, y: target.minY)
        case .above: origin = CGPoint(x: target.minX, y: target.minY - moving.height)
        case .below: origin = CGPoint(x: target.minX, y: target.maxY)
        }
        return validatedMove(id, to: origin, frames: frames, mainID: mainID) ?? frames
    }

    static func snapped(_ id: String, proposedOrigin: CGPoint,
                        frames: [String: CGRect], mainID: String) -> [String: CGRect] {
        guard let moving = frames[id], proposedOrigin.x.isFinite, proposedOrigin.y.isFinite else { return frames }
        var candidates: [CGPoint] = []
        for (otherID, target) in frames.sorted(by: { $0.key < $1.key }) where otherID != id {
            // Require a real edge segment in contact rather than a single corner.
            let y = min(target.maxY - 1, max(target.minY - moving.height + 1, proposedOrigin.y))
            let x = min(target.maxX - 1, max(target.minX - moving.width + 1, proposedOrigin.x))
            candidates += [CGPoint(x: target.minX - moving.width, y: y), CGPoint(x: target.maxX, y: y),
                           CGPoint(x: x, y: target.minY - moving.height), CGPoint(x: x, y: target.maxY)]
            candidates += [CGPoint(x: target.minX - moving.width, y: target.minY),
                           CGPoint(x: target.maxX, y: target.minY),
                           CGPoint(x: target.minX, y: target.minY - moving.height),
                           CGPoint(x: target.minX, y: target.maxY)]
        }
        candidates.sort {
            hypot($0.x - proposedOrigin.x, $0.y - proposedOrigin.y) < hypot($1.x - proposedOrigin.x, $1.y - proposedOrigin.y)
        }
        for candidate in candidates {
            if let result = validatedMove(id, to: candidate, frames: frames, mainID: mainID) { return result }
        }
        return frames
    }

    static func isValid(_ frames: [String: CGRect]) -> Bool {
        guard !frames.isEmpty, frames.values.allSatisfy({
            $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }) else { return false }
        let ids = frames.keys.sorted()
        for index in ids.indices {
            for other in ids.dropFirst(index + 1) {
                let overlap = frames[ids[index]]!.intersection(frames[other]!)
                if !overlap.isNull, overlap.width > 0.01, overlap.height > 0.01 { return false }
            }
        }
        var visited: Set<String> = [ids[0]]
        var queue = [ids[0]]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for id in ids where !visited.contains(id) && touches(frames[current]!, frames[id]!) {
                visited.insert(id)
                queue.append(id)
            }
        }
        return visited.count == ids.count
    }

    private static func touches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let verticalOverlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        return ((abs(lhs.maxX - rhs.minX) < 0.01 || abs(rhs.maxX - lhs.minX) < 0.01) && verticalOverlap > 0.01)
            || ((abs(lhs.maxY - rhs.minY) < 0.01 || abs(rhs.maxY - lhs.minY) < 0.01) && horizontalOverlap > 0.01)
    }

    private static func validatedMove(_ id: String, to origin: CGPoint,
                                      frames: [String: CGRect], mainID: String) -> [String: CGRect]? {
        guard var frame = frames[id] else { return nil }
        frame.origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        var proposed = frames
        proposed[id] = frame
        proposed = normalized(proposed, mainID: mainID)
        return isValid(proposed) ? proposed : nil
    }
}
