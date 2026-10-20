import IOKit.pwr_mgt
import XCTest
@testable import NotchApp

@MainActor
final class DisplayKeepAwakeTests: XCTestCase {
    func testDefaultStartsOnlyOnCommandWithOneHourSystemAssertion() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertFalse(fixture.model.keepsDisplaysAwake)
        XCTAssertTrue(fixture.driver.creations.isEmpty)
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(fixture.driver.creations, [.init(id: 1, displays: false, timeout: 3600)])
        XCTAssertEqual(fixture.model.expiresAt, fixture.clock.date.addingTimeInterval(3600))
        XCTAssertEqual(fixture.scheduler.durations, [3600])
        fixture.model.stop()
    }

    func testSupportedDurationsAndIndefiniteSession() {
        let fixture = Fixture()
        for minutes in [15, 30, 60, 120] {
            fixture.model.start(minutes: minutes)
            XCTAssertEqual(fixture.driver.creations.last?.timeout, Double(minutes * 60))
        }
        fixture.model.start(minutes: nil)
        XCTAssertNil(fixture.driver.creations.last?.timeout)
        XCTAssertNil(fixture.model.expiresAt)
        XCTAssertEqual(fixture.driver.active.count, 1)
        fixture.model.stop()
        XCTAssertTrue(fixture.driver.active.isEmpty)
    }

    func testUnsupportedDurationDoesNotCreateOrReplaceAssertion() {
        let fixture = Fixture()
        fixture.model.start(minutes: 0)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertNotNil(fixture.model.errorMessage)
        fixture.model.start(minutes: 30)
        let deadline = fixture.model.expiresAt
        fixture.model.start(minutes: -1)
        XCTAssertEqual(fixture.driver.creations.count, 1)
        XCTAssertEqual(fixture.model.expiresAt, deadline)
        fixture.model.stop()
    }

    func testModeCanBeChosenWhileInactiveWithoutCreatingAssertion() {
        let fixture = Fixture()
        fixture.model.setKeepsDisplaysAwake(true)
        XCTAssertTrue(fixture.model.keepsDisplaysAwake)
        XCTAssertTrue(fixture.driver.creations.isEmpty)
        fixture.model.start(minutes: nil)
        XCTAssertEqual(fixture.driver.creations.last?.displays, true)
        fixture.model.stop()
    }

    func testModeReplacementCreatesFirstAndKeepsOriginalDeadline() {
        let fixture = Fixture()
        fixture.model.start()
        let deadline = fixture.model.expiresAt
        fixture.clock.date.addTimeInterval(100)
        fixture.model.setKeepsDisplaysAwake(true)
        XCTAssertTrue(fixture.model.keepsDisplaysAwake)
        XCTAssertEqual(fixture.driver.events, ["create:1", "create:2", "release:1"])
        XCTAssertEqual(fixture.driver.creations.last?.timeout, 3500)
        XCTAssertEqual(fixture.model.expiresAt, deadline)
        XCTAssertTrue(fixture.scheduler.tokens[0].cancelled)
        fixture.scheduler.fire(0)
        XCTAssertTrue(fixture.model.isActive, "A cancelled prior timer must not stop the replacement")
        fixture.model.stop()
    }

    func testCreateFailureRetainsOldModeAssertionAndDeadline() {
        let fixture = Fixture()
        fixture.model.start()
        let deadline = fixture.model.expiresAt
        fixture.driver.failCreate = true
        fixture.model.setKeepsDisplaysAwake(true)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertFalse(fixture.model.keepsDisplaysAwake)
        XCTAssertEqual(fixture.model.expiresAt, deadline)
        XCTAssertEqual(fixture.driver.active, [1])
        XCTAssertNotNil(fixture.model.errorMessage)
        fixture.model.stop()
    }

    func testFailedOldReleaseRollsBackReplacementAndStopCanRetry() {
        let fixture = Fixture()
        fixture.model.start()
        fixture.driver.failReleases = [1]
        fixture.model.setKeepsDisplaysAwake(true)
        XCTAssertEqual(fixture.driver.active, [1])
        XCTAssertFalse(fixture.model.keepsDisplaysAwake)
        XCTAssertEqual(fixture.driver.events, ["create:1", "create:2", "release:1", "release:2"])
        fixture.driver.failReleases = []
        fixture.model.stop()
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertTrue(fixture.driver.active.isEmpty)
    }

    func testFailedRollbackRemainsOwnedWithoutAccumulatingMoreAssertions() {
        let fixture = Fixture()
        fixture.model.start()
        fixture.driver.failReleases = [1, 2]
        fixture.model.setKeepsDisplaysAwake(true)
        fixture.model.start()
        XCTAssertEqual(fixture.driver.creations.count, 2)
        XCTAssertEqual(fixture.driver.active, [1, 2])
        fixture.driver.failReleases = []
        fixture.model.shutdown()
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertTrue(fixture.driver.active.isEmpty)
    }

    func testStopReleaseFailureIsVisibleAndRetryable() {
        let fixture = Fixture()
        fixture.model.start()
        fixture.driver.failReleases = [1]
        fixture.model.stop()
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertNotNil(fixture.model.errorMessage)
        fixture.driver.failReleases = []
        fixture.model.stop()
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertNil(fixture.model.expiresAt)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testTransientStopFailureRetriesWithoutNewAssertionsAndStaleRetryIsCancelled() {
        let fixture = Fixture()
        fixture.model.start(minutes: nil)
        fixture.driver.failReleases = [1]
        fixture.model.shutdown()
        XCTAssertEqual(fixture.scheduler.durations, [1])
        fixture.scheduler.fire(0)
        XCTAssertEqual(fixture.scheduler.durations, [1, 2])
        fixture.driver.failReleases = []
        fixture.scheduler.fire(1)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.driver.creations.count, 1)
        XCTAssertTrue(fixture.driver.active.isEmpty)
        fixture.model.start(minutes: nil)
        fixture.scheduler.fire(1)
        XCTAssertEqual(fixture.driver.active, [2])
        fixture.model.stop()
    }

    func testStopCleanupRetryBackoffHasBoundedInterval() {
        let fixture = Fixture()
        fixture.model.start(minutes: nil)
        fixture.driver.failReleases = [1]
        fixture.model.stop()
        for index in 0..<6 { fixture.scheduler.fire(index) }
        XCTAssertEqual(fixture.scheduler.durations, [1, 2, 5, 10, 30, 30, 30])
        XCTAssertEqual(fixture.driver.creations.count, 1)
        fixture.driver.failReleases = []
        fixture.model.stop()
    }

    func testExpiryReleasesAndStaleCallbackCannotStopNewIndefiniteSession() {
        let fixture = Fixture()
        fixture.model.start(minutes: 15)
        fixture.scheduler.fire(0)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertTrue(fixture.driver.active.isEmpty)
        fixture.model.start(minutes: nil)
        fixture.scheduler.fire(0)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(fixture.driver.active, [2])
        fixture.model.stop()
    }

    func testExpiredModeChangeStopsInsteadOfRearmingSession() {
        let fixture = Fixture()
        fixture.model.start(minutes: 15)
        fixture.clock.date.addTimeInterval(901)
        fixture.model.setKeepsDisplaysAwake(true)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertTrue(fixture.model.keepsDisplaysAwake)
        XCTAssertEqual(fixture.driver.creations.count, 1)
    }

    func testDeinitReleasesAssertionAndCancelsTimer() {
        let driver = FakeKeepAwakeDriver()
        let scheduler = KeepAwakeTestScheduler()
        var model: DisplayKeepAwakeModel? = DisplayKeepAwakeModel(driver: driver, schedule: scheduler.schedule)
        model?.start()
        model = nil
        XCTAssertTrue(driver.active.isEmpty)
        XCTAssertTrue(scheduler.tokens[0].cancelled)
    }

    func testPublicAssertionPropertiesDistinguishSystemAndDisplayAndUseOSTimeout() {
        let system = SystemDisplayKeepAwakeDriver.properties(keepsDisplaysAwake: false, timeout: 900)
        let display = SystemDisplayKeepAwakeDriver.properties(keepsDisplaysAwake: true, timeout: nil)
        XCTAssertEqual(system[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleSystemSleep)
        XCTAssertEqual(display[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleDisplaySleep)
        XCTAssertEqual(system[kIOPMAssertionLevelKey] as? Int, kIOPMAssertionLevelOn)
        XCTAssertEqual(system[kIOPMAssertionTimeoutKey] as? Double, 900)
        XCTAssertEqual(system[kIOPMAssertionTimeoutActionKey] as? String, kIOPMAssertionTimeoutActionTurnOff)
        XCTAssertNil(display[kIOPMAssertionTimeoutKey])
    }

    @MainActor
    private final class Fixture {
        let driver = FakeKeepAwakeDriver()
        let clock = KeepAwakeTestClock()
        let scheduler = KeepAwakeTestScheduler()
        lazy var model = DisplayKeepAwakeModel(driver: driver, now: { [clock] in clock.date }, schedule: scheduler.schedule)
    }
}

@MainActor
private final class KeepAwakeTestClock {
    var date = Date(timeIntervalSince1970: 1000)
}

@MainActor
private final class KeepAwakeTestScheduler {
    var durations: [TimeInterval] = []
    var callbacks: [@MainActor @Sendable () -> Void] = []
    var tokens: [KeepAwakeTestCancellation] = []
    func schedule(_ duration: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any DisplayKeepAwakeCancellation {
        durations.append(duration)
        callbacks.append(action)
        let token = KeepAwakeTestCancellation()
        tokens.append(token)
        return token
    }
    func fire(_ index: Int) { callbacks[index]() }
}

private final class KeepAwakeTestCancellation: DisplayKeepAwakeCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private final class FakeKeepAwakeDriver: DisplayKeepAwakeDriving, @unchecked Sendable {
    struct Creation: Equatable {
        let id: UInt32
        let displays: Bool
        let timeout: TimeInterval?
    }
    private let lock = NSLock()
    private(set) var creations: [Creation] = []
    private(set) var active = Set<UInt32>()
    private(set) var events: [String] = []
    var failCreate = false
    var failReleases = Set<UInt32>()
    func create(keepsDisplaysAwake: Bool, timeout: TimeInterval?) throws -> UInt32 {
        try lock.withLock {
            if failCreate { throw Failure.simulated }
            let id = UInt32(creations.count + 1)
            creations.append(Creation(id: id, displays: keepsDisplaysAwake, timeout: timeout))
            events.append("create:\(id)")
            active.insert(id)
            return id
        }
    }
    func release(_ assertionID: UInt32) throws {
        try lock.withLock {
            events.append("release:\(assertionID)")
            if failReleases.contains(assertionID) { throw Failure.simulated }
            active.remove(assertionID)
        }
    }
    private enum Failure: Error { case simulated }
}
