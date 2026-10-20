import Foundation
import XCTest
@testable import NotchApp

final class DisplayAppearanceDriverTests: XCTestCase {
    func testUnsupportedSymbolsReturnNilAndWritesFailClearly() throws {
        let driver = SystemDisplayAppearanceDriver(bindings: .init(readDarkMode: nil, writeDarkMode: nil,
            readAutomatic: nil, writeAutomatic: nil, hasWindowServerAccess: { true }, wait: { _ in }))
        XCTAssertNil(try driver.read())
        XCTAssertNil(try driver.readMode())
        XCTAssertThrowsError(try driver.setMode(.automatic)) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .unavailable) }
    }

    func testMissingAutomaticAPIKeepsEffectiveReadButDisablesModeChanges() throws {
        let state = AppearanceTestState(dark: true)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state, automaticAvailable: false))
        XCTAssertEqual(try driver.read(), true)
        XCTAssertNil(try driver.readMode())
        XCTAssertThrowsError(try driver.setDarkMode(false)) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .unavailable) }
        XCTAssertTrue(state.snapshot().events.isEmpty)
    }

    func testMissingGraphicalSessionDoesNotReportLightOrAttemptWrite() {
        let state = AppearanceTestState()
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state, sessionAvailable: false))
        XCTAssertThrowsError(try driver.read()) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .sessionUnavailable) }
        XCTAssertThrowsError(try driver.readMode()) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .sessionUnavailable) }
        XCTAssertThrowsError(try driver.setMode(.dark)) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .sessionUnavailable) }
        XCTAssertTrue(state.snapshot().events.isEmpty)
    }

    func testAutomaticModeIsReportedEvenWhenEffectiveAppearanceIsDark() throws {
        let state = AppearanceTestState(dark: true, automatic: true)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        XCTAssertEqual(try driver.read(), true)
        XCTAssertEqual(try driver.readMode(), .automatic)
    }

    func testManualMatchingThemeStillDisablesAutomaticBeforeSettingTheme() throws {
        let state = AppearanceTestState(dark: true, automatic: true)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        try driver.setDarkMode(true)
        XCTAssertEqual(try driver.readMode(), .dark)
        XCTAssertEqual(state.snapshot().events, ["automatic:false", "dark:true"])
    }

    func testManualLightDisablesAutomaticBeforeChangingEffectiveTheme() throws {
        let state = AppearanceTestState(dark: true, automatic: true)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        try driver.setMode(.light)
        XCTAssertEqual(try driver.read(), false)
        XCTAssertEqual(try driver.readMode(), .light)
        XCTAssertEqual(state.snapshot().events, ["automatic:false", "dark:false"])
    }

    func testAutomaticEnablesScheduleWithoutForcingEffectiveTheme() throws {
        let state = AppearanceTestState(dark: false)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        try driver.setMode(.automatic)
        XCTAssertEqual(try driver.readMode(), .automatic)
        XCTAssertEqual(try driver.read(), false)
        XCTAssertEqual(state.snapshot().events, ["automatic:true"])
    }

    func testSelectingCurrentManualOrAutomaticModeDoesNotWrite() throws {
        let manual = AppearanceTestState(dark: true)
        try SystemDisplayAppearanceDriver(bindings: bindings(state: manual)).setMode(.dark)
        XCTAssertTrue(manual.snapshot().events.isEmpty)
        let automatic = AppearanceTestState(dark: true, automatic: true)
        try SystemDisplayAppearanceDriver(bindings: bindings(state: automatic)).setMode(.automatic)
        XCTAssertTrue(automatic.snapshot().events.isEmpty)
    }

    func testReadbackFailureRestoresOriginalAutomaticAndEffectiveTheme() {
        let state = AppearanceTestState(automatic: true, ignoreThemeWrites: true)
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        XCTAssertThrowsError(try driver.setMode(.dark)) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .verificationFailed) }
        XCTAssertFalse(state.snapshot().dark)
        XCTAssertTrue(state.snapshot().automatic)
        XCTAssertEqual(state.snapshot().events, ["automatic:false", "dark:true", "automatic:true"])
    }

    func testThrownPartialMutationRestoresBothOriginalValues() {
        let state = AppearanceTestState(automatic: true, failAfterThemeWrites: [1])
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        XCTAssertThrowsError(try driver.setMode(.dark)) { XCTAssertTrue($0 is AppearanceTestError) }
        XCTAssertFalse(state.snapshot().dark)
        XCTAssertTrue(state.snapshot().automatic)
        XCTAssertEqual(state.snapshot().events, ["automatic:false", "dark:true", "dark:false", "automatic:true"])
    }

    func testFailedRollbackIsReportedExplicitly() {
        let state = AppearanceTestState(automatic: true, failBeforeThemeWrites: [2], failAfterThemeWrites: [1])
        let driver = SystemDisplayAppearanceDriver(bindings: bindings(state: state))
        XCTAssertThrowsError(try driver.setMode(.dark)) { XCTAssertEqual($0 as? SystemDisplayAppearanceError, .rollbackFailed) }
    }

    private func bindings(state: AppearanceTestState, sessionAvailable: Bool = true,
                          automaticAvailable: Bool = true) -> SystemDisplayAppearanceBindings {
        var readAutomatic: (@Sendable () throws -> Bool)?
        var writeAutomatic: (@Sendable (Bool) throws -> Void)?
        if automaticAvailable {
            readAutomatic = { @Sendable in state.snapshot().automatic }
            writeAutomatic = { @Sendable in state.writeAutomatic($0) }
        }
        return .init(readDarkMode: { state.snapshot().dark }, writeDarkMode: { try state.writeTheme($0) },
                     readAutomatic: readAutomatic, writeAutomatic: writeAutomatic,
                     hasWindowServerAccess: { sessionAvailable }, wait: { _ in })
    }
}

private enum AppearanceTestError: Error { case injected }

private final class AppearanceTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var dark: Bool
    private var automatic: Bool
    private var events: [String] = []
    private var themeWriteCount = 0
    private let ignoreThemeWrites: Bool
    private let failBeforeThemeWrites: Set<Int>
    private let failAfterThemeWrites: Set<Int>

    init(dark: Bool = false, automatic: Bool = false, ignoreThemeWrites: Bool = false,
         failBeforeThemeWrites: Set<Int> = [], failAfterThemeWrites: Set<Int> = []) {
        self.dark = dark
        self.automatic = automatic
        self.ignoreThemeWrites = ignoreThemeWrites
        self.failBeforeThemeWrites = failBeforeThemeWrites
        self.failAfterThemeWrites = failAfterThemeWrites
    }

    func snapshot() -> (dark: Bool, automatic: Bool, events: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (dark, automatic, events)
    }

    func writeTheme(_ value: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        themeWriteCount += 1
        events.append("dark:\(value)")
        if failBeforeThemeWrites.contains(themeWriteCount) { throw AppearanceTestError.injected }
        if !ignoreThemeWrites { dark = value }
        if failAfterThemeWrites.contains(themeWriteCount) { throw AppearanceTestError.injected }
    }

    func writeAutomatic(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        events.append("automatic:\(value)")
        automatic = value
    }
}
