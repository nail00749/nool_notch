import CoreGraphics

enum DisplayArrangementPolicy {
    /// CG may silently adjust gaps and overlaps. Reject them before submitting a trial.
    static func validate(_ placements: [DisplayPlacement], displays: [DisplayInfo]) throws {
        let active = displays.filter { $0.isEnabled && $0.mirrorMasterID == nil }
        let expected = Set(active.map(\.id))
        guard !active.isEmpty, placements.count == expected.count,
              Set(placements.map(\.uuid)) == expected,
              Set(placements.map(\.uuid)).count == placements.count,
              let main = active.first(where: \.isMain),
              placements.first(where: { $0.uuid == main.id })?.origin == .zero else {
            throw DisplayServiceError.invalidArrangement
        }
        let origins = Dictionary(uniqueKeysWithValues: placements.map { ($0.uuid, $0.origin) })
        let frames = try active.map { display -> CGRect in
            guard let origin = origins[display.id], validOrigin(origin),
                  display.frame.width.isFinite, display.frame.height.isFinite,
                  display.frame.width > 0, display.frame.height > 0 else {
                throw DisplayServiceError.invalidArrangement
            }
            return CGRect(origin: origin, size: display.frame.size)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                let intersection = frames[i].intersection(frames[j])
                if !intersection.isNull, intersection.width > 0, intersection.height > 0 {
                    throw DisplayServiceError.invalidArrangement
                }
            }
        }
        var reachable: Set<Int> = [0]
        var pending = [0]
        while let index = pending.popLast() {
            for candidate in frames.indices where !reachable.contains(candidate) && sharesEdge(frames[index], frames[candidate]) {
                reachable.insert(candidate)
                pending.append(candidate)
            }
        }
        guard reachable.count == frames.count else { throw DisplayServiceError.invalidArrangement }
    }

    static func validOrigin(_ origin: CGPoint) -> Bool {
        Int32(exactly: origin.x) != nil && Int32(exactly: origin.y) != nil
    }

    private static func sharesEdge(_ first: CGRect, _ second: CGRect) -> Bool {
        let verticalOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        let horizontalOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
        return (verticalOverlap > 0 && (first.maxX == second.minX || second.maxX == first.minX))
            || (horizontalOverlap > 0 && (first.maxY == second.minY || second.maxY == first.minY))
    }
}

enum DisplayPowerPolicy {
    static func validate(displayID: UInt32, enabled: Bool, displays: [DisplayInfo], drawableDisplayIDs: Set<UInt32>? = nil) throws {
        guard let target = displays.first(where: { $0.displayID == displayID }) else { throw DisplayServiceError.disconnected }
        guard !enabled, target.isEnabled else { return }
        // A mirror follower is not an independent surviving desktop if its master is removed.
        guard displays.contains(where: {
            $0.displayID != displayID && $0.isEnabled && $0.mirrorMasterID == nil
                && (drawableDisplayIDs?.contains($0.displayID) ?? true)
        }) else {
            throw DisplayServiceError.lastEnabledDisplay
        }
    }
}
