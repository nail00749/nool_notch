import XCTest
@testable import NotchApp

final class LauncherDisplayCommandTests: XCTestCase {
    func testResolutionSearchUsesDisplayUUIDAndOnlyOffersAlternativeModes() {
        let current = mode(id: 1, width: 2560, height: 1440)
        let alternative = mode(id: 2, width: 1920, height: 1080)
        let display = DisplayInfo(id: "stable-screen-uuid", displayID: 42, name: "Desk monitor",
                                  isBuiltin: false, isMain: false, mirrorMasterID: nil,
                                  modes: [current, alternative], currentMode: current)
        let commands = LauncherResult.displayCommands(displays: [display], query: "1920x1080", category: .all)

        XCTAssertFalse(commands.contains { $0.payload == .displayMode(displayUUID: display.id, modeID: current.id) })
        XCTAssertEqual(LauncherSearch.ranked(commands, query: "1920x1080").map(\.payload),
                       [.displayMode(displayUUID: display.id, modeID: alternative.id)])
        XCTAssertEqual(LauncherSearch.ranked(commands, query: "главный дисплей").map(\.payload),
                       [.displayMain(displayUUID: display.id)])
    }

    func testMainDisplayCommandIsOmittedForCurrentMainAndOutsideAllCategory() {
        let display = DisplayInfo(id: "main-screen", displayID: 7, name: "Built-in",
                                  isBuiltin: true, isMain: true, mirrorMasterID: nil,
                                  modes: [], currentMode: nil)
        XCTAssertTrue(LauncherResult.displayCommands(displays: [display], query: "дисплей", category: .all).isEmpty)
        XCTAssertTrue(LauncherResult.displayCommands(displays: [display], query: "дисплей", category: .files).isEmpty)
        XCTAssertTrue(LauncherResult.displayCommands(displays: [display], query: "  ", category: .all).isEmpty)
    }

    private func mode(id: UInt32, width: Int, height: Int) -> DisplayModeOption {
        DisplayModeOption(id: id, width: width, height: height, pixelWidth: width * 2,
                          pixelHeight: height * 2, refreshRate: 60)
    }

    func testDisabledScreenDoesNotOfferModesOrMainCommand() {
        let display = DisplayInfo(id: "disabled", displayID: 42, name: "Disabled", isBuiltin: false,
                                  isMain: false, mirrorMasterID: nil, modes: [mode(id: 1, width: 1920, height: 1080)],
                                  currentMode: nil, isEnabled: false)
        XCTAssertTrue(LauncherResult.displayCommands(displays: [display], query: "дисплей", category: .all).isEmpty)
    }
}
