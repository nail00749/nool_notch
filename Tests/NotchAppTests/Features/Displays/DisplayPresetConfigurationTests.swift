import CoreGraphics
import XCTest
@testable import NotchApp

final class DisplayPresetConfigurationTests: XCTestCase {
    func testPresetRoundTripPersistsSemanticModeAndPresentationValues() throws {
        let saved = DisplayPresetEntry(stableUUID: "a", mode: SavedDisplayMode(mode(id: 91)), isMain: true,
                                       brightness: 0.42, useSoftwareBrightness: true, colorProfileID: "profile-id")
        let preset = DisplayPreset(name: "Работа", displays: [saved])
        let data = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(DisplayPreset.self, from: data), preset)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(json["displays"] as? [[String: Any]])
        let persistedMode = try XCTUnwrap(entries.first?["mode"] as? [String: Any])
        XCTAssertNil(persistedMode["id"], "Driver mode IDs must not be persisted across sessions")
        XCTAssertEqual(persistedMode["pixelWidth"] as? Int, 200)
    }

    func testMissingExtraAndDuplicateDisplayIdentitiesAreRejectedBeforePlanning() {
        let live = [display("a", id: 1, main: true), display("b", id: 2)]
        assertPlanError(.displaySetMismatch, preset: preset([entry("a", main: true)]), displays: live)
        assertPlanError(.displaySetMismatch, preset: preset([entry("a", main: true), entry("other", x: 100)]), displays: live)
        assertPlanError(.invalidPreset, preset: preset([entry("a", main: true), entry("a", x: 100)]), displays: live)
        assertPlanError(.invalidPreset, preset: preset([entry("a", main: true)]), displays: [live[0], live[0]])
    }

    func testSemanticModesResolveAfterDriverIDsChange() throws {
        let saved = SavedDisplayMode(mode(id: 10))
        let liveMode = mode(id: 999)
        let live = display("a", id: 7, main: true, modes: [liveMode])
        let preset = preset([entry("a", main: true, mode: saved)])
        let plan = try makePlan(preset, displays: [live])
        XCTAssertEqual(plan.entries.first?.resolvedMode?.id, 999)
    }

    func testUnavailableEnabledModeRejectsEntirePlanEvenWhenAnotherScreenNeedsEnabling() {
        let requested = SavedDisplayMode(mode(id: 5, width: 200))
        let live = [display("a", id: 1, main: true), display("b", id: 2, enabled: false)]
        let preset = preset([entry("a", main: true, mode: requested), entry("b", x: 100)])
        assertPlanError(.modeUnavailable(displayUUID: "a"), preset: preset, displays: live, power: true, eligible: ["b"])
    }

    func testDisabledHiddenModeCatalogDefersResolutionUntilEnabled() throws {
        let requested = SavedDisplayMode(mode(id: 5, width: 200))
        let live = [display("a", id: 1, main: true), display("b", id: 2, enabled: false, modes: [])]
        let preset = preset([entry("a", main: true), entry("b", x: 100, mode: requested)])
        let plan = try makePlan(preset, displays: live, power: true, eligible: ["b"])
        XCTAssertNil(plan.entries.first(where: { $0.saved.stableUUID == "b" })?.resolvedMode)
        XCTAssertEqual(plan.entries.first(where: { $0.saved.stableUUID == "b" })?.targetSize.width, 200)
    }

    func testDisabledDisplayCanStayDisabledWithoutPowerSupportOrReadableMode() throws {
        let disabled = DisplayInfo(id: "b", displayID: 2, name: "b", isBuiltin: false, isMain: false,
                                   mirrorMasterID: nil, modes: [], currentMode: nil, isEnabled: false)
        let preset = preset([entry("a", main: true), entry("b", enabled: false)])
        let plan = try makePlan(preset, displays: [display("a", id: 1, main: true), disabled])
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertTrue(plan.temporaryPlacements.isEmpty)
    }

    func testPowerChangesRequireSupportedRecoverableDisplays() {
        let live = [display("a", id: 1, main: true), display("b", id: 2)]
        let preset = preset([entry("a", main: true), entry("b", enabled: false)])
        assertPlanError(.powerUnavailable(displayUUID: "b"), preset: preset, displays: live)
        assertPlanError(.powerUnavailable(displayUUID: "b"), preset: preset, displays: live, power: true)
        XCTAssertNoThrow(try makePlan(preset, displays: live, power: true, eligible: ["b"]))
    }

    func testNoEnabledScreenOrNoUniqueMainIsRejected() {
        let live = [display("a", id: 1, main: true), display("b", id: 2)]
        assertPlanError(.invalidPreset, preset: preset([entry("a", enabled: false), entry("b", enabled: false)]), displays: live)
        assertPlanError(.invalidPreset, preset: preset([entry("a"), entry("b", x: 100)]), displays: live)
        assertPlanError(.invalidPreset, preset: preset([entry("a", main: true), entry("b", main: true, x: 100)]), displays: live)
    }

    func testMirrorCycleMissingOrDisabledMasterAndMirroredMainAreRejected() {
        let live = [display("a", id: 1, main: true), display("b", id: 2), display("c", id: 3)]
        let variants = [
            [entry("a", main: true), entry("b", master: "c"), entry("c", master: "b")],
            [entry("a", main: true), entry("b", master: "missing"), entry("c", x: 100)],
            [entry("a", main: true), entry("b", master: "c"), entry("c", enabled: false)],
            [entry("a", main: true, master: "b"), entry("b"), entry("c", x: 100)]
        ]
        for entries in variants { assertPlanError(.invalidPreset, preset: preset(entries), displays: live, power: true, eligible: ["c"]) }
    }

    func testMirrorsShareTheirMastersOriginAndNeedOnlyOneLayoutRoot() throws {
        let live = [display("a", id: 1, main: true), display("b", id: 2)]
        XCTAssertNoThrow(try makePlan(preset([entry("a", main: true), entry("b", master: "a")]), displays: live))
        assertPlanError(.invalidPreset, preset: preset([entry("a", main: true), entry("b", x: 100, master: "a")]), displays: live)
    }

    func testLayoutRejectsOverlapGapsNonfiniteFractionalAndNonzeroMainOrigins() {
        let live = [display("a", id: 1, main: true), display("b", id: 2)]
        for x: CGFloat in [99, 101, .infinity, .nan, 100.5] {
            assertPlanError(.invalidPreset, preset: preset([entry("a", main: true), entry("b", x: x)]), displays: live)
        }
        assertPlanError(.invalidPreset, preset: preset([entry("a", main: true, x: 1), entry("b", x: 101)]), displays: live)
    }

    func testTargetModeDimensionsDriveLayoutAndExtrasAreParkedUntilDisabled() throws {
        let wide = mode(id: 3, width: 200)
        let live = [display("a", id: 1, main: true, modes: [wide]), display("b", id: 2), display("c", id: 3)]
        let preset = preset([entry("a", main: true, mode: SavedDisplayMode(wide)), entry("b", x: 200), entry("c", enabled: false)])
        let plan = try makePlan(preset, displays: live, power: true, eligible: ["c"])
        XCTAssertEqual(plan.temporaryPlacements, [DisplayPlacement(uuid: "c", origin: CGPoint(x: 300, y: 0))])
    }

    func testParticipantMappingAcceptsNumericRemapsForSameUUIDs() throws {
        let before = [display("a", id: 1, main: true), display("b", id: 2, enabled: false)]
        let afterEnable = [display("a", id: 101, main: true), display("b", id: 202)]
        let expected = Set(before.map(\.id))
        let mapped = try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: expected, displays: afterEnable)
        XCTAssertEqual(mapped["a"]?.displayID, 101)
        XCTAssertEqual(mapped["b"]?.displayID, 202)
        XCTAssertNoThrow(try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: expected, displays: afterEnable,
                                                                     expectedDisplayIDs: ["a": 101, "b": 202]))
    }

    func testTransactionBindingRejectsIDReuseOrRemappingAfterModeResolution() {
        let swapped = [display("a", id: 2, main: true), display("b", id: 1)]
        XCTAssertThrowsError(try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: ["a", "b"], displays: swapped,
                                                                         expectedDisplayIDs: ["a": 1, "b": 2]))
        let remapped = [display("a", id: 101, main: true), display("b", id: 2)]
        XCTAssertThrowsError(try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: ["a", "b"], displays: remapped,
                                                                         expectedDisplayIDs: ["a": 1, "b": 2]))
    }

    func testParticipantMappingRejectsMissingWrongDuplicateUUIDsAndDuplicateNumericIDs() {
        let invalid = [
            [display("a", id: 1)],
            [display("a", id: 1), display("other", id: 2)],
            [display("a", id: 1), display("a", id: 2)],
            [display("a", id: 1), display("b", id: 1)]
        ]
        for displays in invalid {
            XCTAssertThrowsError(try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: ["a", "b"], displays: displays)) {
                XCTAssertEqual($0 as? DisplayPresetError, .displayChanged)
            }
        }
    }

    private func makePlan(_ preset: DisplayPreset, displays: [DisplayInfo], power: Bool = false,
                          eligible: Set<String> = []) throws -> DisplayPresetConfigurationPlan {
        try .make(preset, displays: displays, supportsDisplayPower: power, powerChangeableUUIDs: eligible)
    }

    private func assertPlanError(_ expected: DisplayPresetError, preset: DisplayPreset, displays: [DisplayInfo],
                                 power: Bool = false, eligible: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try makePlan(preset, displays: displays, power: power, eligible: eligible), file: file, line: line) {
            XCTAssertEqual($0 as? DisplayPresetError, expected, file: file, line: line)
        }
    }

    private func preset(_ entries: [DisplayPresetEntry]) -> DisplayPreset { .init(name: "Test", displays: entries) }
    private func entry(_ uuid: String, enabled: Bool = true, main: Bool = false, x: CGFloat = 0,
                       master: String? = nil, mode: SavedDisplayMode? = nil) -> DisplayPresetEntry {
        .init(stableUUID: uuid, enabled: enabled, mode: mode, origin: CGPoint(x: x, y: 0), isMain: main, mirrorMasterUUID: master)
    }
    private func mode(id: UInt32, width: Int = 100) -> DisplayModeOption {
        .init(id: id, width: width, height: 100, pixelWidth: width * 2, pixelHeight: 200, refreshRate: 60)
    }
    private func display(_ uuid: String, id: UInt32, main: Bool = false, enabled: Bool = true,
                         modes: [DisplayModeOption]? = nil) -> DisplayInfo {
        let options = modes ?? [mode(id: id)]
        return .init(id: uuid, displayID: id, name: uuid, isBuiltin: false, isMain: main, mirrorMasterID: nil,
                     modes: options, currentMode: options.first, frame: CGRect(x: 0, y: 0, width: 100, height: 100), isEnabled: enabled)
    }
}
