import CoreGraphics

/// Live drag order of the Dock strip, like the system Dock: the dragged item leaves a gap
/// that travels between its neighbours while the pointer moves, and is committed on drop.
enum DockLiveReorder {
    /// Fraction of the target cell the pointer has to pass, from the side it came from,
    /// before the gap jumps over it. The part before it is where a dwell groups items.
    static let crossing: CGFloat = 0.6

    /// The order with `dragged` moved past `target`, or nil while the pointer has not crossed it.
    /// `offset` is the pointer position inside the target along the Dock axis.
    static func reordered(_ order: [String], dragged: String, target: String,
                          offset: CGFloat, length: CGFloat) -> [String]? {
        guard dragged != target, length > 0,
              let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target) else { return nil }
        let crossed = from < to ? offset > length * crossing : offset < length * (1 - crossing)
        guard crossed else { return nil }
        var result = order
        result.remove(at: from)
        // Moving forward, removal shifts the target left, so `to` lands right after it.
        result.insert(dragged, at: to)
        return result
    }

    /// The item `dragged` goes before in the committed order; nil means the end of the list.
    static func successor(of dragged: String, in order: [String]) -> String? {
        guard let index = order.firstIndex(of: dragged), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    /// Whether the pointer sits where a drop inserts next to the cell rather than acting on it.
    /// `offset` may be negative or exceed `length` inside an open gap; that still inserts.
    static func insertsAtEdge(offset: CGFloat, length: CGFloat) -> Bool {
        offset < length * 0.2 || offset > length * 0.8
    }
}

/// Where an item from outside the pinned list (Finder, running applications) would land.
struct DockInsertion: Equatable {
    var id: String
    var after: Bool
}
