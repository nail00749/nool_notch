import Foundation
import XCTest
@testable import NotchApp

final class SystemLiveActivityTests: XCTestCase {
    func testSystemProfilerParserFindsConnectedAirPodsWithoutDependingOnDeviceNameKeys() throws {
        let data = Data(
            """
            {
              "SPBluetoothDataType": [{
                "device_connected": [{
                  "Nail AirPods Pro": {
                    "device_address": "AA-BB-CC-DD-EE-FF",
                    "device_batteryLevelMain": "74%",
                    "device_minorType": "Headphones"
                  }
                }]
              }]
            }
            """.utf8
        )

        let devices = try SystemProfilerBluetoothParser.devices(from: data)

        XCTAssertEqual(
            devices,
            [BluetoothAudioDevice(id: "AA-BB-CC-DD-EE-FF", name: "Nail AirPods Pro", batteryPercent: 74)]
        )
    }

    func testAirPodsConnectionAndDisconnectionBecomeTransientCompactNotifications() {
        var tracker = BluetoothActivityTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let airPods = BluetoothAudioDevice(
            id: "AA-BB",
            name: "AirPods Pro",
            batteryPercent: 74
        )

        XCTAssertTrue(tracker.consume([], now: start).isEmpty)

        let connected = tracker.consume([airPods], now: start.addingTimeInterval(1))
        XCTAssertEqual(connected.first?.detail, "Подключены · 74%")
        XCTAssertEqual(connected.first?.isCompactEligible, true)

        let settled = tracker.consume([airPods], now: start.addingTimeInterval(14))
        XCTAssertEqual(settled.first?.isCompactEligible, false)

        let disconnected = tracker.consume([], now: start.addingTimeInterval(15))
        XCTAssertEqual(disconnected.first?.detail, "Отключены")
        XCTAssertEqual(disconnected.first?.state, .notification)
        XCTAssertEqual(disconnected.first?.isCompactEligible, true)

        XCTAssertTrue(tracker.consume([], now: start.addingTimeInterval(28)).isEmpty)
    }

    func testCallTrackerShowsElapsedTimeAndCompletionNotification() {
        var tracker = CallActivityTracker()
        let start = Date(timeIntervalSince1970: 2_000)
        let faceTime = AudioInputProcess(
            pid: 42,
            bundleID: "com.apple.FaceTime",
            name: "FaceTime"
        )

        XCTAssertTrue(tracker.consume([], now: start).isEmpty)

        let active = tracker.consume([faceTime], now: start.addingTimeInterval(1))
        XCTAssertEqual(active.first?.title, "Звонок · FaceTime")
        XCTAssertEqual(active.first?.detail, "00:00")
        XCTAssertEqual(active.first?.isCompactEligible, true)

        let continuing = tracker.consume([faceTime], now: start.addingTimeInterval(66))
        XCTAssertEqual(continuing.first?.detail, "01:05")

        let ended = tracker.consume([], now: start.addingTimeInterval(67))
        XCTAssertEqual(ended.first?.detail, "Завершён · 01:06")
        XCTAssertEqual(ended.first?.state, .notification)
        XCTAssertEqual(ended.first?.isCompactEligible, true)

        XCTAssertTrue(tracker.consume([], now: start.addingTimeInterval(80)).isEmpty)
    }

    func testFreshSystemEventShowsMascotButRunningTimerDoesNot() {
        let now = Date(timeIntervalSince1970: 3_000)
        let call = LiveActivity.systemFixture(
            kind: .call,
            state: .active,
            updatedAt: now.addingTimeInterval(-5)
        )
        let timer = LiveActivity.systemFixture(
            kind: .timer,
            state: .active,
            updatedAt: now
        )

        XCTAssertTrue(call.showsNotificationMascot(at: now))
        XCTAssertFalse(call.showsNotificationMascot(at: now.addingTimeInterval(13)))
        XCTAssertFalse(timer.showsNotificationMascot(at: now))
    }

    func testDownloadTrackerKeepsElapsedTimeAndOnlyAnnouncesRealCompletion() {
        var tracker = DownloadActivityTracker()
        let start = Date(timeIntervalSince1970: 4_000)
        let partial = DownloadSnapshot(
            id: "/Downloads/archive.zip.crdownload",
            title: "archive.zip",
            byteCount: 1_500_000,
            finalFileExists: false
        )

        let active = tracker.consume([partial], now: start)
        XCTAssertEqual(active.first?.title, "Загрузка · archive.zip")
        XCTAssertEqual(active.first?.detail, "00:00 · 1,5 МБ")

        let continuing = tracker.consume([partial], now: start.addingTimeInterval(61))
        XCTAssertEqual(continuing.first?.detail, "01:01 · 1,5 МБ")

        let completed = tracker.consume(
            [DownloadSnapshot(
                id: partial.id,
                title: partial.title,
                byteCount: partial.byteCount,
                finalFileExists: true
            )],
            now: start.addingTimeInterval(62)
        )
        XCTAssertEqual(completed.first?.state, .notification)
        XCTAssertEqual(completed.first?.detail, "Готово · 01:02")

        XCTAssertTrue(tracker.consume([], now: start.addingTimeInterval(75)).isEmpty)
    }

    func testExternalBridgeAcceptsDeliveryAndTimerWithoutPrivateSystemAccess() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let data = Data(
            """
            {
              "version": 1,
              "activities": [
                {
                  "id": "order-42",
                  "kind": "delivery",
                  "title": "Доставка",
                  "detail": "Курьер в пути",
                  "progress": 0.75,
                  "updatedAt": 4995,
                  "expiresAt": 5300
                },
                {
                  "id": "stale",
                  "kind": "timer",
                  "title": "Старый таймер",
                  "updatedAt": 4000,
                  "expiresAt": 4999
                }
              ]
            }
            """.utf8
        )

        let activities = try ExternalLiveActivityParser.activities(from: data, now: now)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.kind, .delivery)
        XCTAssertEqual(activities.first?.progress, 0.75)
        XCTAssertEqual(activities.first?.isCompactEligible, true)
    }

    func testExternalBridgeBoundsInputAndDeduplicatesIDs() throws {
        let duplicateEntries = (0..<70).map { index in
            """
            {"id":"same-\(index % 2)","kind":"delivery","title":"\(String(repeating: "X", count: 120))","updatedAt":\(5000 + index)}
            """
        }.joined(separator: ",")
        let data = Data("{\"version\":1,\"activities\":[\(duplicateEntries)]}".utf8)

        let activities = try ExternalLiveActivityParser.activities(
            from: data,
            now: Date(timeIntervalSince1970: 6_000)
        )

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(Set(activities.map(\.id)).count, 2)
        XCTAssertTrue(activities.allSatisfy { $0.title.count == 80 })
        XCTAssertThrowsError(
            try ExternalLiveActivityParser.activities(
                from: Data(repeating: 0x20, count: ExternalLiveActivityParser.maximumDataSize + 1),
                now: .now
            )
        )
    }

    func testBluetoothRefreshGateCoalescesEventsAndStopDropsPendingRefresh() {
        var gate = BluetoothRefreshGate()

        XCTAssertTrue(gate.requestRefresh())
        gate.didStart()
        XCTAssertFalse(gate.requestRefresh())
        XCTAssertTrue(gate.didFinish())

        XCTAssertTrue(gate.requestRefresh())
        gate.didStart()
        XCTAssertFalse(gate.requestRefresh())
        gate.cancelPendingRefresh()
        XCTAssertFalse(gate.didFinish())
    }
}

private extension LiveActivity {
    static func systemFixture(
        kind: LiveActivityKind,
        state: LiveActivityState,
        updatedAt: Date
    ) -> LiveActivity {
        LiveActivity(
            id: "fixture-\(kind.rawValue)",
            sourceID: "fixture",
            kind: kind,
            title: "Fixture",
            detail: nil,
            state: state,
            progress: nil,
            startedAt: nil,
            endsAt: nil,
            updatedAt: updatedAt,
            isCompactEligible: true
        )
    }
}
