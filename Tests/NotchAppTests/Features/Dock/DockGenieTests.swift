import QuartzCore
import XCTest
@testable import NotchApp

final class DockGenieTests: XCTestCase {
    private let size = CGSize(width: 600, height: 64)

    private func apply(_ t: CATransform3D, _ point: CGPoint, anchor: CGPoint = .zero) -> CGPoint {
        // Layer-backed views use a (0, 0) anchor: sublayer points are relative to it.
        let x = point.x - anchor.x, y = point.y - anchor.y
        let w = x * t.m14 + y * t.m24 + t.m44
        return CGPoint(x: (x * t.m11 + y * t.m21 + t.m41) / w + anchor.x,
                       y: (x * t.m12 + y * t.m22 + t.m42) / w + anchor.y)
    }

    func testShownStateIsIdentity() {
        XCTAssertTrue(CATransform3DIsIdentity(DockGenieAnimator.transform(
            progress: 0, size: size, position: .bottom, anchor: .zero, flipped: false)))
    }

    func testBottomDockFunnelsIntoTheBottomEdgeCenter() {
        let t = DockGenieAnimator.transform(progress: 0.6, size: size, position: .bottom, anchor: .zero, flipped: false)
        let bottomLeft = apply(t, CGPoint(x: 0, y: 0))
        let bottomRight = apply(t, CGPoint(x: size.width, y: 0))
        let topLeft = apply(t, CGPoint(x: 0, y: size.height))
        let topRight = apply(t, CGPoint(x: size.width, y: size.height))
        XCTAssertEqual((bottomLeft.x + bottomRight.x) / 2, size.width / 2, accuracy: 0.5, "Stays centred on the cell row")
        XCTAssertLessThan(bottomRight.x - bottomLeft.x, size.width * 0.6, "Narrows as it collapses")
        XCTAssertGreaterThan(topRight.x - topLeft.x, bottomRight.x - bottomLeft.x, "Wider away from the edge, like a genie")
        XCTAssertLessThan(bottomLeft.y, 0, "Slides into the screen edge")
        XCTAssertLessThan(topLeft.y, size.height)
    }

    func testSideDocksCollapseTowardsTheirEdge() {
        let vertical = CGSize(width: 64, height: 600)
        let left = DockGenieAnimator.transform(progress: 0.6, size: vertical, position: .left, anchor: .zero, flipped: false)
        let right = DockGenieAnimator.transform(progress: 0.6, size: vertical, position: .right, anchor: .zero, flipped: false)
        XCTAssertLessThan(apply(left, CGPoint(x: 0, y: 300)).x, 0)
        XCTAssertGreaterThan(apply(right, CGPoint(x: 64, y: 300)).x, 64)
        let edgeSpan = apply(left, CGPoint(x: 0, y: 600)).y - apply(left, CGPoint(x: 0, y: 0)).y
        let farSpan = apply(left, CGPoint(x: 64, y: 600)).y - apply(left, CGPoint(x: 64, y: 0)).y
        XCTAssertGreaterThan(farSpan, edgeSpan)
    }

    @MainActor
    func testHideCompletesAndShowReversesWithoutStaleCompletion() {
        let animator = DockGenieAnimator()
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        var hidden = 0
        animator.hide(view, position: .bottom, animated: false) { hidden += 1 }
        XCTAssertEqual(hidden, 1)
        animator.hide(view, position: .bottom, animated: true) { hidden += 1 }
        XCTAssertTrue(animator.isHiding)
        animator.show(view, position: .bottom, animated: true)
        XCTAssertFalse(animator.isHiding)
        RunLoop.main.run(until: Date().addingTimeInterval(DockGenieAnimator.hideDuration + 0.2))
        XCTAssertEqual(hidden, 1, "A show that interrupts the hide cancels its completion")
        animator.cancel(view)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer?.sublayerTransform ?? CATransform3DIdentity))
    }
}
