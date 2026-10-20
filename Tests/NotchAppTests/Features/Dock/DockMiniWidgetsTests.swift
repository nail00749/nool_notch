import Foundation
import IOKit.ps
import NotchCore
import XCTest
@testable import NotchApp

final class DockMiniWidgetsTests: XCTestCase {
    func testBluetoothParserReadsOnlyConnectedDevicesAndUsesTheLowerBud() throws {
        let json = """
        {"SPBluetoothDataType": [{
          "device_connected": [
            {"AirPods Pro": {"device_address": "AA:BB:CC:DD:EE:FF", "device_minorType": "Headphones",
                             "device_batteryLevelLeft": "100 %", "device_batteryLevelRight": "64 %",
                             "device_batteryLevelCase": "77 %"}},
            {"Magic Mouse": {"device_address": "11:22:33:44:55:66", "device_minorType": "Mouse",
                             "device_batteryLevelMain": "41 %"}},
            {"Speaker": {"device_minorType": "Speaker"}}
          ],
          "device_not_connected": [
            {"Old Keyboard": {"device_minorType": "Keyboard", "device_batteryLevelMain": "5 %"}}
          ]
        }]}
        """
        let devices = DeviceBatteryParser.bluetoothDevices(from: Data(json.utf8))
            .sorted { $0.name < $1.name }

        XCTAssertEqual(devices.map(\.name), ["AirPods Pro", "Magic Mouse"])
        XCTAssertEqual(devices[0].percent, 64)
        XCTAssertEqual(devices[0].kind, .headphones)
        XCTAssertEqual(devices[0].detail, "Л 100% · П 64% · Кейс 77%")
        XCTAssertEqual(devices[0].id, "bt-AA-BB-CC-DD-EE-FF")
        XCTAssertEqual(devices[1].percent, 41)
        XCTAssertEqual(devices[1].kind, .mouse)
        XCTAssertTrue(DeviceBatteryParser.bluetoothDevices(from: Data("garbage".utf8)).isEmpty)
    }

    func testRegistryAndMacBatteryParsing() throws {
        let keyboard = try XCTUnwrap(DeviceBatteryParser.registryDevice([
            "Product": "Magic Keyboard", "BatteryPercent": NSNumber(value: 12),
            "BatteryStatusFlags": NSNumber(value: 3), "DeviceAddress": "AA-BB"
        ]))
        XCTAssertEqual(keyboard.kind, .keyboard)
        XCTAssertEqual(keyboard.percent, 12)
        XCTAssertTrue(keyboard.isCharging)
        XCTAssertNil(DeviceBatteryParser.registryDevice(["Product": "Mouse"]))

        let mac = try XCTUnwrap(DeviceBatteryParser.macBattery([
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 45, kIOPSMaxCapacityKey: 90,
            kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue
        ]))
        XCTAssertEqual(mac.percent, 50)
        XCTAssertEqual(mac.kind, .mac)
        XCTAssertEqual(mac.detail, "заряжается")
        XCTAssertNil(DeviceBatteryParser.macBattery([kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 1,
                                                     kIOPSMaxCapacityKey: 2]))
    }

    func testMergedListPutsMacFirstThenLowestChargeWithoutDuplicates() {
        func device(_ name: String, _ percent: Int, id: String? = nil) -> DeviceBattery {
            DeviceBattery(id: id ?? name, name: name, kind: .other, percent: percent, isCharging: false, detail: nil)
        }
        let merged = DeviceBatteryParser.merged(
            mac: device("Mac", 80),
            bluetooth: [device("AirPods", 30), device("Magic Mouse", 90, id: "bt")],
            registry: [device("Magic Mouse", 88, id: "hid")]
        )
        XCTAssertEqual(merged.map(\.name), ["Mac", "AirPods", "Magic Mouse"])
        XCTAssertEqual(merged.last?.id, "hid", "IORegistry wins over the profiler copy")
    }

    func testQuotaSummariesFollowOrderHideProvidersAndPickTightestWindow() {
        let reset = Date(timeIntervalSince1970: 10_000)
        func snapshot(_ id: String, _ windows: [QuotaWindow], connection: ProviderConnectionState = .live) -> QuotaSnapshot {
            QuotaSnapshot(providerID: id, providerName: id.uppercased(), windows: windows,
                          connection: connection, updatedAt: .distantPast, sourceURL: nil, message: nil)
        }
        let snapshots = [
            "claude": snapshot("claude", [
                QuotaWindow(id: "5h", label: "5 часов", limit: 100, remaining: 80, resetAt: nil, unit: .percentage),
                QuotaWindow(id: "week", label: "Неделя", limit: 100, remaining: 25, resetAt: reset, unit: .percentage)
            ]),
            "codex": snapshot("codex", [], connection: .requiresAuthentication),
            "hidden": snapshot("hidden", [])
        ]
        let summaries = DockQuotaSummary.summaries(snapshots: snapshots, order: ["codex", "claude"],
                                                   hidden: ["hidden"])
        XCTAssertEqual(summaries.map(\.id), ["codex", "claude"])
        XCTAssertEqual(summaries[1].remaining, 0.25)
        XCTAssertEqual(summaries[1].resetAt, reset)
        XCTAssertEqual(summaries[1].windowLabel, "Неделя")
        XCTAssertEqual(summaries[1].percentText, "25%")
        XCTAssertEqual(summaries[0].percentText, "—")

        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DockQuotaSummary.shortReset(now.addingTimeInterval(90), now: now), "1 мин")
        XCTAssertEqual(DockQuotaSummary.shortReset(now.addingTimeInterval(7_300), now: now), "2 ч")
        XCTAssertEqual(DockQuotaSummary.shortReset(now.addingTimeInterval(200_000), now: now), "2 д")
        XCTAssertNil(DockQuotaSummary.shortReset(now.addingTimeInterval(-5), now: now))
    }

    func testLayoutShowsOneGaugePerCellAndCompactRates() {
        XCTAssertEqual(DockMiniWidgetLayout.gaugeCount(span: 1, available: 5), 1)
        XCTAssertEqual(DockMiniWidgetLayout.gaugeCount(span: 3, available: 2), 2)
        XCTAssertEqual(DockMiniWidgetLayout.gaugeCount(span: 3, available: 9), 3)
        XCTAssertEqual(DockSystemLoadWidget.metrics(span: 1), [.cpu])
        XCTAssertEqual(DockSystemLoadWidget.metrics(span: 3), [.cpu, .memory, .disk, .network])
        XCTAssertEqual(DockSystemLoadWidget.compactRate(.init(receivedBytesPerSecond: 1_250_000, sentBytesPerSecond: 0)), "↓1.2M")
        XCTAssertEqual(DockSystemLoadWidget.compactRate(.init(receivedBytesPerSecond: 640_400, sentBytesPerSecond: 0)), "↓640K")
        XCTAssertEqual(DockSystemLoadWidget.compactRate(nil), "—")
        XCTAssertEqual(DockSystemToggle.shown(span: 1).count, 4)
        XCTAssertEqual(DockSystemToggle.shown(span: 3).last, .bluetooth)
    }

    @MainActor
    func testTogglesStoreRereadsStateAfterEveryChange() {
        let service = FakeTogglesService()
        let store = SystemTogglesStore(service: service)
        store.refresh()
        XCTAssertEqual(store.wifiOn, true)

        store.toggleWiFi()
        XCTAssertEqual(service.wifi, false)
        XCTAssertEqual(store.wifiOn, false)

        service.refuseWiFi = true
        store.toggleWiFi()
        XCTAssertEqual(store.wifiOn, false, "A refused write is not shown as applied")
        XCTAssertNotNil(store.errorMessage)

        store.toggleMute()
        XCTAssertEqual(store.audio?.isMuted, true)
        store.adjustVolume(by: 2)
        XCTAssertEqual(service.audio.volume, 0.5 + 2 * SystemTogglesStore.volumeStep, accuracy: 0.0001)
        XCTAssertEqual(store.audio?.isMuted, false, "Raising the volume unmutes")
        store.adjustVolume(by: -100)
        XCTAssertEqual(store.audio?.volume, 0)
    }
}

private final class FakeTogglesService: SystemTogglesServing, @unchecked Sendable {
    var wifi = true
    var refuseWiFi = false
    var audio = SystemAudioState(volume: 0.5, isMuted: false, canSetVolume: true, canMute: true)

    func wifiPower() -> Bool? { wifi }
    func setWiFiPower(_ enabled: Bool) throws {
        if refuseWiFi { throw CocoaError(.featureUnsupported) }
        wifi = enabled
    }
    func audioState() -> SystemAudioState? { audio }
    func setVolume(_ volume: Double) -> Bool {
        audio.volume = volume
        if volume > 0 { audio.isMuted = false }
        return true
    }
    func setMuted(_ muted: Bool) -> Bool {
        audio.isMuted = muted
        return true
    }
}
