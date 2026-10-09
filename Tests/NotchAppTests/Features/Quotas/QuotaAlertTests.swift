import Foundation
import NotchCore
import XCTest
@testable import NotchApp

final class QuotaAlertPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)
    private var enabled: QuotaAlertOptions { QuotaAlertOptions(enabled: true) }

    private func snapshot(_ remaining: Double, tick: Double = 0, reset: Double = 3600,
                          connection: ProviderConnectionState = .live, providerID: String = "test") -> QuotaSnapshot {
        QuotaSnapshot(providerID: providerID, providerName: "Test", windows: [
            QuotaWindow(id: "weekly", label: "7d", limit: 100, remaining: remaining,
                        resetAt: start.addingTimeInterval(reset), unit: .percentage)
        ], connection: connection, updatedAt: start.addingTimeInterval(tick), sourceURL: nil, message: nil)
    }

    func testThresholdsWarnOnceEachAndSurvivePersistence() throws {
        var policy = QuotaAlertPolicy()
        XCTAssertTrue(policy.consume(snapshot(60), options: enabled, now: start).isEmpty)
        XCTAssertEqual(policy.consume(snapshot(20, tick: 1), options: enabled, now: start).map(\.kind), [.twenty])
        XCTAssertTrue(policy.consume(snapshot(19, tick: 2), options: enabled, now: start).isEmpty)
        policy = try JSONDecoder().decode(QuotaAlertPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(policy.consume(snapshot(18, tick: 3), options: enabled, now: start).isEmpty)
        XCTAssertEqual(policy.consume(snapshot(10, tick: 4), options: enabled, now: start).map(\.kind), [.ten])
        XCTAssertTrue(policy.consume(snapshot(0, tick: 5), options: enabled, now: start).isEmpty)
    }

    func testJumpToCriticalSendsOnlyCritical() {
        var policy = QuotaAlertPolicy()
        XCTAssertEqual(policy.consume(snapshot(5), options: enabled, now: start).map(\.kind), [.ten])
        XCTAssertTrue(policy.consume(snapshot(4, tick: 1), options: enabled, now: start).isEmpty)
    }

    func testRecoveryRequiresFreshObservedIncreaseAndRearmsNewCycle() {
        var policy = QuotaAlertPolicy()
        _ = policy.consume(snapshot(5), options: enabled, now: start)
        XCTAssertTrue(policy.consume(snapshot(100, tick: 10, connection: .stale), options: enabled, now: start).isEmpty)
        XCTAssertTrue(policy.consume(snapshot(100, tick: 3600), options: enabled, now: start.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(policy.consume(snapshot(100, tick: 3601, reset: 7200), options: enabled,
                                      now: start.addingTimeInterval(3601)).map(\.kind), [.recovered])
        XCTAssertTrue(policy.consume(snapshot(99, tick: 3602, reset: 7200), options: enabled,
                                     now: start.addingTimeInterval(3602)).isEmpty)
        XCTAssertEqual(policy.consume(snapshot(20, tick: 3700, reset: 7200), options: enabled,
                                      now: start.addingTimeInterval(3700)).map(\.kind), [.twenty])
    }

    func testDisabledUnavailableOldAndOutOfOrderSamplesDoNotAffectState() {
        var policy = QuotaAlertPolicy()
        XCTAssertTrue(policy.consume(snapshot(5), options: QuotaAlertOptions(), now: start).isEmpty)
        XCTAssertTrue(policy.consume(snapshot(5, connection: .requiresAuthentication), options: enabled, now: start).isEmpty)
        XCTAssertTrue(policy.consume(snapshot(5), options: enabled, now: start.addingTimeInterval(901)).isEmpty)
        XCTAssertTrue(policy.states.isEmpty)
        _ = policy.consume(snapshot(80, tick: 2), options: enabled, now: start)
        XCTAssertTrue(policy.consume(snapshot(5, tick: 1), options: enabled, now: start).isEmpty)
    }

    func testProvidersAndThresholdOptionsAreIndependent() {
        var policy = QuotaAlertPolicy()
        var options = enabled
        options.atTwenty = false
        XCTAssertTrue(policy.consume(snapshot(20), options: options, now: start).isEmpty)
        XCTAssertEqual(policy.consume(snapshot(10, tick: 1), options: options, now: start).map(\.kind), [.ten])
        XCTAssertEqual(policy.consume(snapshot(20, providerID: "other"), options: enabled, now: start).map(\.kind), [.twenty])
    }

    func testSmallFluctuationsDoNotRepeatThresholds() {
        var policy = QuotaAlertPolicy()
        _ = policy.consume(snapshot(20), options: enabled, now: start)
        XCTAssertEqual(policy.consume(snapshot(21, tick: 1), options: enabled, now: start).map(\.kind), [.recovered])
        XCTAssertTrue(policy.consume(snapshot(20, tick: 2), options: enabled, now: start).isEmpty)
        XCTAssertTrue(policy.consume(snapshot(21, tick: 3), options: enabled, now: start).isEmpty)
    }

    func testMissingWindowDoesNotEraseWarningHistory() {
        var policy = QuotaAlertPolicy()
        _ = policy.consume(snapshot(20), options: enabled, now: start)
        let partial = QuotaSnapshot(providerID: "test", providerName: "Test", windows: [], connection: .live,
                                    updatedAt: start.addingTimeInterval(1), sourceURL: nil, message: nil)
        XCTAssertTrue(policy.consume(partial, options: enabled, now: start).isEmpty)
        XCTAssertTrue(policy.consume(snapshot(19, tick: 2), options: enabled, now: start).isEmpty)
    }
}

@MainActor
final class QuotaAlertControllerTests: XCTestCase {
    func testPermissionIsOnlyRequestedByExplicitEnableAndDeniedDoesNotEnable() async throws {
        let name = "QuotaAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let delivery = TestQuotaAlertDelivery()
        let controller = QuotaAlertController(defaults: defaults, delivery: delivery)
        await controller.refreshAuthorization()
        XCTAssertEqual(delivery.requests, 0)
        await controller.enable(true, for: "test")
        XCTAssertEqual(delivery.requests, 1)
        XCTAssertFalse(controller.configuration(for: "test").enabled)
        delivery.status = .allowed
        await controller.enable(true, for: "test")
        XCTAssertTrue(controller.configuration(for: "test").enabled)
        XCTAssertEqual(delivery.requests, 1)
        controller.stop()
        await controller.enable(false, for: "test")
        XCTAssertTrue(controller.configuration(for: "test").enabled)
    }
}

@MainActor
private final class TestQuotaAlertDelivery: QuotaAlertDelivering {
    var status: QuotaAlertAuthorization = .notRequested
    var requests = 0
    var events: [QuotaAlertEvent] = []
    func authorization() async -> QuotaAlertAuthorization { status }
    func requestAuthorization() async throws -> Bool { requests += 1; status = .denied; return false }
    func deliver(_ event: QuotaAlertEvent) async throws { events.append(event) }
}
