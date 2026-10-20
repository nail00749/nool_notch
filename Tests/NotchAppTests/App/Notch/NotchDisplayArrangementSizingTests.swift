import CoreGraphics
import XCTest
@testable import NotchApp

final class NotchDisplayArrangementSizingTests: XCTestCase {
    private let metrics = NotchLayoutMetrics(physicalNotchSize: CGSize(width: 220, height: 32))

    func testDisplayCardsAndArrangementBothFitAt520Points() {
        XCTAssertEqual(size(isArranging: false), CGSize(width: 500, height: 520))
        XCTAssertEqual(size(isArranging: true), CGSize(width: 500, height: 520))
        XCTAssertEqual(size(isArranging: true, maximum: 380).height, 520)
        XCTAssertEqual(size(isArranging: true, maximum: 560).height, 520)
        XCTAssertEqual(size(isArranging: false, maximum: 300).height, 520)
    }

    func testArrangementHeightDoesNotAffectOtherPanelsUtilitiesOrSettings() {
        XCTAssertEqual(size(isArranging: true, selectedPanel: .music).height, 380)
        XCTAssertEqual(size(isArranging: true, utility: .overview).height, 420)
        XCTAssertEqual(size(isArranging: true, utility: .files).height, 332)
        XCTAssertEqual(size(isArranging: true, settings: true).height, 332)
    }

    func testCompactGeometryDoesNotDependOnArrangementState() {
        let normal = size(isArranging: false, expanded: false)
        XCTAssertEqual(size(isArranging: true, expanded: false), normal)
        XCTAssertEqual(normal, NotchWindowSizingPolicy.compactInteractionSize(metrics: metrics))
    }

    func testOuterPanelAndContentUseSameEditorHeightWithExistingSideLanes() {
        let content = size(isArranging: true)
        let panel = NotchWindowSizingPolicy.panelSize(
            metrics: metrics, isExpanded: true, selectedPanel: .displays,
            calendarViewMode: .list, isShowingSettings: false,
            maxExpandedHeight: 380, isArrangingDisplays: true
        )
        XCTAssertEqual(panel.height, content.height)
        XCTAssertEqual(panel.width, content.width + NotchLayout.expandedSideControlLaneWidth * 2)
        let noSideControls = NotchWindowSizingPolicy.panelSize(
            metrics: metrics, isExpanded: true, selectedPanel: .displays,
            calendarViewMode: .list, isShowingSettings: false,
            hasSideControls: false, isArrangingDisplays: true
        )
        XCTAssertEqual(noSideControls, content)
    }

    private func size(isArranging: Bool, maximum: CGFloat? = nil, selectedPanel: PanelID = .displays,
                      utility: NotchUtilityPanel? = nil, settings: Bool = false, expanded: Bool = true) -> CGSize {
        NotchWindowSizingPolicy.size(
            metrics: metrics, isExpanded: expanded, selectedPanel: selectedPanel,
            calendarViewMode: .list, isShowingSettings: settings,
            maxExpandedHeight: maximum, activeUtility: utility, isArrangingDisplays: isArranging
        )
    }
}
