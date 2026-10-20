import CoreGraphics
import Foundation

@MainActor
protocol DisplayBrightnessServing {
    func setDimming(_ factor: Double, displayID: UInt32) throws
    func setAppearance(dimming: Double, adjustment: DisplayImageAdjustment, displayID: UInt32) throws
    func restore()
    func invalidate()
}

extension DisplayBrightnessServing {
    func setAppearance(dimming: Double, adjustment: DisplayImageAdjustment, displayID: UInt32) throws {
        try setDimming(dimming, displayID: displayID)
    }
}

struct DisplayGammaTable: Equatable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]

    func dimmed(by factor: Double) -> DisplayGammaTable {
        applying(dimming: factor, adjustment: .neutral)
    }

    func applying(dimming: Double, adjustment: DisplayImageAdjustment) -> DisplayGammaTable {
        let correction = adjustment.sanitized
        let safeFactor = Float(dimming.isFinite ? min(1, max(0.1, dimming)) : 1)
        // Preserve every calibration sample exactly when no correction is requested.
        if correction == .neutral {
            guard safeFactor != 1 else { return self }
            return DisplayGammaTable(red: red.map { $0 * safeFactor },
                                     green: green.map { $0 * safeFactor }, blue: blue.map { $0 * safeFactor })
        }
        let warmth = max(0, correction.temperature)
        let coolness = max(0, -correction.temperature)
        let redGain = correction.red * (1 - coolness * 0.3)
        let greenGain = correction.green * (1 - warmth * 0.15 - coolness * 0.1)
        let blueGain = correction.blue * (1 - warmth * 0.4)
        func channel(_ original: [CGGammaValue], gain: Double) -> [CGGammaValue] {
            original.map { sample in
                let value = sample.isFinite ? min(1, max(0, Double(sample))) : 0
                let gamma = pow(value, 1 / correction.gamma)
                let contrast = min(1, max(0, (gamma - 0.5) * correction.contrast + 0.5))
                return Float(min(1, max(0, contrast * gain * Double(safeFactor))))
            }
        }
        return DisplayGammaTable(red: channel(red, gain: redGain), green: channel(green, gain: greenGain),
                                 blue: channel(blue, gain: blueGain))
    }
}

@MainActor
final class GammaDisplayBrightnessService: DisplayBrightnessServing {
    private var baselines: [CGDirectDisplayID: DisplayGammaTable] = [:]

    func setDimming(_ factor: Double, displayID: UInt32) throws {
        try setAppearance(dimming: factor, adjustment: .neutral, displayID: displayID)
    }

    func setAppearance(dimming: Double, adjustment: DisplayImageAdjustment, displayID: UInt32) throws {
        // Enabling the feature at its default value must not touch display calibration.
        if baselines[displayID] == nil, adjustment.isNeutral, !dimming.isFinite || dimming >= 1 { return }
        guard CGDisplayIsOnline(displayID) != 0 else { throw DisplayServiceError.disconnected }
        let baseline: DisplayGammaTable
        if let stored = baselines[displayID] {
            baseline = stored
        } else {
            baseline = try capture(displayID)
        }
        let table = baseline.applying(dimming: dimming, adjustment: adjustment)
        let error = CGSetDisplayTransferByTable(displayID, UInt32(table.red.count), table.red, table.green, table.blue)
        guard error == .success else {
            throw DisplayServiceError.coreGraphics(operation: "изменить изображение дисплея", code: error.rawValue)
        }
        baselines[displayID] = baseline
    }

    func restore() {
        guard !baselines.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        baselines.removeAll()
    }

    func invalidate() {
        // Wake/profile changes may already have restored gamma. Resetting ColorSync also covers
        // screen notifications caused by our own configuration, when gamma may still be dimmed.
        restore()
    }

    private func capture(_ id: CGDirectDisplayID) throws -> DisplayGammaTable {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { throw DisplayServiceError.unavailableGamma }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        let error = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count)
        guard error == .success else {
            throw DisplayServiceError.coreGraphics(operation: "получить калибровку дисплея", code: error.rawValue)
        }
        guard count > 0, count <= capacity else { throw DisplayServiceError.unavailableGamma }
        return DisplayGammaTable(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))),
                                 blue: Array(blue.prefix(Int(count))))
    }
}
