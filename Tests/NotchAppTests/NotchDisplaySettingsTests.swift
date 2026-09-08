import CoreGraphics
import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class NotchDisplaySettingsTests: XCTestCase {
    private let builtIn = NotchDisplayDescriptor(
        id: "built-in",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
        isBuiltIn: true,
        isMain: true
    )
    private let external = NotchDisplayDescriptor(
        id: "external",
        name: "Studio Display",
        frame: CGRect(x: 1_800, y: 0, width: 2_560, height: 1_440),
        isBuiltIn: false,
        isMain: false
    )

    func testAutomaticModePreservesBuiltInDisplayPreference() {
        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .automatic,
            fixedDisplayID: nil,
            displays: [external, builtIn],
            pointerLocation: CGPoint(x: 2_000, y: 700)
        )

        XCTAssertEqual(selected, builtIn.id)
    }

    func testAutomaticModeUsesPointerWhenNoBuiltInDisplayExists() {
        let mainExternal = NotchDisplayDescriptor(
            id: "main-external",
            name: "Main Display",
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            isBuiltIn: false,
            isMain: true
        )
        let pointerExternal = NotchDisplayDescriptor(
            id: "pointer-external",
            name: "Side Display",
            frame: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
            isBuiltIn: false,
            isMain: false
        )

        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .automatic,
            fixedDisplayID: nil,
            displays: [mainExternal, pointerExternal],
            pointerLocation: CGPoint(x: 2_000, y: 700)
        )

        XCTAssertEqual(selected, pointerExternal.id)
    }

    func testFollowPointerSelectsOnlyTheDisplayContainingPointer() {
        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .followPointer,
            fixedDisplayID: nil,
            displays: [builtIn, external],
            pointerLocation: CGPoint(x: 2_000, y: 700)
        )

        XCTAssertEqual(selected, external.id)
    }

    func testExpandedFollowPointerKeepsTheConnectedActiveDisplay() {
        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .followPointer,
            fixedDisplayID: nil,
            displays: [builtIn, external],
            pointerLocation: CGPoint(x: 2_000, y: 700),
            activeDisplayID: builtIn.id,
            isExpanded: true
        )

        XCTAssertEqual(selected, builtIn.id)
    }

    func testExpandedFollowPointerFallsBackWhenActiveDisplayDisconnects() {
        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .followPointer,
            fixedDisplayID: nil,
            displays: [external],
            pointerLocation: CGPoint(x: 2_000, y: 700),
            activeDisplayID: builtIn.id,
            isExpanded: true
        )

        XCTAssertEqual(selected, external.id)
    }

    func testMissingFixedDisplayFallsBackToBuiltInDisplay() {
        let selected = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: .fixed,
            fixedDisplayID: "disconnected-display",
            displays: [external, builtIn],
            pointerLocation: CGPoint(x: 2_000, y: 700)
        )

        XCTAssertEqual(selected, builtIn.id)
    }

    func testDisplayChoiceAndPerDisplayHeightsRoundTrip() {
        let suiteName = "NotchDisplaySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = NotchDisplaySettings(defaults: defaults)
        settings.mode = .fixed
        settings.fixedDisplayID = external.id
        settings.usesPerDisplayCompactHeight = true
        settings.setCompactHeight(42, for: external.id)
        settings.setCompactHeight(38, for: builtIn.id)

        settings = NotchDisplaySettings(defaults: defaults)
        settings.setActiveDisplayID(external.id)

        XCTAssertEqual(settings.mode, .fixed)
        XCTAssertEqual(settings.fixedDisplayID, external.id)
        XCTAssertTrue(settings.usesPerDisplayCompactHeight)
        XCTAssertEqual(settings.effectiveCompactHeight(fallback: 40), 42)

        settings.setActiveDisplayID(builtIn.id)
        XCTAssertEqual(settings.effectiveCompactHeight(fallback: 40), 39)
    }

    func testGlobalCompactHeightRemainsFallbackWhenProfilesAreDisabled() {
        let suiteName = "NotchDisplaySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchDisplaySettings(defaults: defaults)
        settings.setActiveDisplayID(external.id)
        settings.setCompactHeight(42, for: external.id)

        XCTAssertEqual(settings.effectiveCompactHeight(fallback: 40), 40)
    }
}
