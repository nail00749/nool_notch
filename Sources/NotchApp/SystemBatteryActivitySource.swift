import Foundation
import IOKit.ps

@MainActor
final class SystemBatteryActivitySource: NSObject, LiveActivitySource {
    let id = "system-battery"
    let displayName = "Батарея Mac"
    var onChange: (([LiveActivity]) -> Void)?

    private var refreshTimer: Timer?

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refreshTimer?.tolerance = 3
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        onChange?(Self.currentActivity().map { [$0] } ?? [])
    }

    private static func currentActivity() -> LiveActivity? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any],
                  let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximumCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximumCapacity > 0 else { continue }

            let ratio = min(1, max(0, Double(currentCapacity) / Double(maximumCapacity)))
            let percentage = Int((ratio * 100).rounded())
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let powerState = description[kIOPSPowerSourceStateKey as String] as? String
            let isOnBattery = powerState == (kIOPSBatteryPowerValue as String)
            let detail: String
            if isCharging {
                detail = "\(percentage)% · заряжается"
            } else if isOnBattery {
                detail = "\(percentage)% · от батареи"
            } else {
                detail = "\(percentage)% · питание подключено"
            }

            return LiveActivity(
                id: "mac-battery",
                sourceID: "system-battery",
                kind: .battery,
                title: "Батарея Mac",
                detail: detail,
                state: .active,
                progress: ratio,
                startedAt: nil,
                endsAt: nil,
                updatedAt: .now,
                isCompactEligible: isOnBattery && percentage <= 20
            )
        }
        return nil
    }
}
