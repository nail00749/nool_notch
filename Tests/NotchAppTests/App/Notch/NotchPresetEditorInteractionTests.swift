import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class NotchPresetEditorInteractionTests: XCTestCase {
    func testPresetEditorReceivesKeyboardFocusAndClosesBeforeNotchCollapse() {
        let model = makeModel()
        defer { model.stop() }
        model.openPanel(.displays)
        XCTAssertFalse(model.requiresNotchKeyboardFocus)
        model.displays.isManagingPresets = true
        XCTAssertTrue(model.requiresNotchKeyboardFocus)
        XCTAssertTrue(model.isTransientSurfaceVisible)

        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.acceptsKeyboardFocus = model.requiresNotchKeyboardFocus
        XCTAssertTrue(panel.canBecomeKey)
        let editor = NSTextView(frame: panel.contentView!.bounds)
        editor.isFieldEditor = true
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.insertText("Работа", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "Работа")

        model.requestCollapse()
        XCTAssertFalse(model.displays.isManagingPresets)
        XCTAssertFalse(model.requiresNotchKeyboardFocus)
        XCTAssertFalse(model.isTransientSurfaceVisible)
        XCTAssertFalse(model.isExpanded)
    }

    func testInactivePresetEditorDoesNotTakeFocusFromOtherPanelsOrCompactNotch() {
        let model = makeModel()
        defer { model.stop() }
        model.openPanel(.displays)
        model.displays.isManagingPresets = true
        model.openUtility(.overview)
        XCTAssertFalse(model.isDisplayPresetEditorVisible)
        XCTAssertEqual(model.requiresNotchKeyboardFocus, NotchUtilityPanel.overview.requiresKeyboardFocus)
        model.closeUtility()
        model.isExpanded = false
        XCTAssertFalse(model.isDisplayPresetEditorVisible)
        XCTAssertFalse(model.requiresNotchKeyboardFocus)
    }

    private func makeModel() -> NotchViewModel {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: module == .displays) }
        return NotchViewModel(providers: [], calendarProvider: FakeCalendarProvider(),
            nowPlayingProvider: FakeNowPlayingProvider(), liveActivityCenter: LiveActivityCenter(additionalSources: []),
            jiraProvider: FakeJiraProvider(), preferences: MemoryAppPreferences(), modules: modules,
            displays: makeTestDisplayFeatureModel())
    }
}
