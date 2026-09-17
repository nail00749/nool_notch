import Foundation
import IOBluetooth
import XCTest
@testable import NotchApp

final class BluetoothExpiryTests: XCTestCase {
    @MainActor
    func testBluetoothCallbacksAcceptBackgroundDeliveryAfterStop() async throws {
        let source = BluetoothAudioActivitySource()
        var published = false
        source.onChange = { _ in published = true }
        source.stop()
        try await Task.detached {
            let device = try XCTUnwrap(IOBluetoothDevice(addressString: "00-00-00-00-00-01"))
            source.deviceDidConnect(nil, device: device)
            source.deviceDidDisconnect(nil, device: device)
        }.value
        await Task.yield()
        XCTAssertFalse(published, "Late system notifications must not restart a stopped source")
    }

    func testActiveConnectionLosesCompactEligibilityWhenExpiryIsRepublished() {
        var tracker = BluetoothActivityTracker()
        let start = Date(timeIntervalSince1970: 10_000)
        let airPods = BluetoothAudioDevice(id: "AA-BB", name: "AirPods Pro", batteryPercent: 74)

        _ = tracker.consume([], now: start)
        let connected = tracker.consume([airPods], now: start.addingTimeInterval(1))
        XCTAssertTrue(connected.first?.isCompactEligible == true)

        let expired = tracker.expire(now: start.addingTimeInterval(13))

        XCTAssertEqual(expired.first?.detail, "Подключены · 74%")
        XCTAssertFalse(expired.first?.isCompactEligible ?? true)
    }

    func testDisconnectedNotificationExpiresWithoutAnotherDeviceSnapshot() {
        var tracker = BluetoothActivityTracker()
        let start = Date(timeIntervalSince1970: 11_000)
        let airPods = BluetoothAudioDevice(id: "AA-BB", name: "AirPods Pro", batteryPercent: nil)

        _ = tracker.consume([], now: start)
        _ = tracker.consume([airPods], now: start.addingTimeInterval(1))
        let disconnected = tracker.consume([], now: start.addingTimeInterval(2))
        XCTAssertEqual(disconnected.first?.detail, "Отключены")

        let expired = tracker.expire(now: start.addingTimeInterval(14))

        XCTAssertTrue(expired.isEmpty)
    }
}
