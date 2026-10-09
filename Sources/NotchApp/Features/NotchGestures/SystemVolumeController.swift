import CoreAudio
import AudioToolbox
import Foundation

enum NotchVolumeAdjustmentResult: Equatable {
    case updated(Double)
    case atLimit(Double)
    case unsupported(String)
    case failed(String)

    var feedback: String {
        switch self {
        case .updated(let value), .atLimit(let value):
            "Громкость \(Int((value * 100).rounded())) %"
        case .unsupported(let reason), .failed(let reason):
            reason
        }
    }

    var compactFeedback: String {
        switch self {
        case .updated(let value), .atLimit(let value): "\(Int((value * 100).rounded())) %"
        case .unsupported, .failed: "Недоступно"
        }
    }
}

protocol SystemVolumeControlling {
    func adjust(by delta: Double) -> NotchVolumeAdjustmentResult
}

struct NotchGestureVolumeHandler {
    let controller: any SystemVolumeControlling

    func adjust(direction: Int, step: Double) -> NotchVolumeAdjustmentResult? {
        guard (direction == -1 || direction == 1), step.isFinite, (0.01...0.10).contains(step) else {
            return nil
        }
        return controller.adjust(by: Double(direction) * step)
    }
}

enum NotchVolumePolicy {
    static func target(current: Double, delta: Double) -> Double? {
        guard current.isFinite, delta.isFinite else { return nil }
        return min(max(current + delta, 0), 1)
    }
}

/// Uses public master-volume properties on the current default output device.
/// Channel-only devices are left untouched so left/right balance cannot change.
struct CoreAudioVolumeController: SystemVolumeControlling {
    func adjust(by delta: Double) -> NotchVolumeAdjustmentResult {
        guard delta.isFinite, delta != 0 else {
            return .failed("Не удалось изменить громкость")
        }
        guard let device = defaultOutputDevice() else {
            return .unsupported("Нет аудиовыхода")
        }

        for selector in [kAudioDevicePropertyVolumeScalar,
                         kAudioHardwareServiceDeviceProperty_VirtualMainVolume] {
            guard let current = writableVolume(device: device, selector: selector) else { continue }
            // These selectors may refer to the same underlying gain. Never retry a write
            // through the other selector after a failed readback.
            return setVolume(device: device, selector: selector, current: current, delta: delta)
        }
        return .unsupported("Этот аудиовыход не поддерживает регулировку громкости")
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func writableVolume(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
        var address = volumeAddress(selector: selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        return readVolume(device: device, selector: selector)
    }

    private func readVolume(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
        var address = volumeAddress(selector: selector)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    private func setVolume(device: AudioDeviceID, selector: AudioObjectPropertySelector,
                           current: Double, delta: Double) -> NotchVolumeAdjustmentResult {
        guard let target = NotchVolumePolicy.target(current: current, delta: delta) else {
            return .failed("Не удалось изменить громкость")
        }
        guard abs(target - current) > 0.0001 else { return .atLimit(current) }
        var address = volumeAddress(selector: selector)
        var value = Float32(target)
        let size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr,
              let actual = readVolume(device: device, selector: selector),
              abs(actual - current) > 0.0001 else {
            return .failed("Аудиовыход не изменил громкость")
        }
        return .updated(actual)
    }

    private func volumeAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
