import AppKit
import CoreAudio
import CoreWLAN
import Foundation

/// Output volume and mute of the default output device, read and written through
/// public CoreAudio properties. Devices without a master control fall back to
/// their first two channels.
struct SystemAudioState: Equatable, Sendable {
    var volume: Double
    var isMuted: Bool
    var canSetVolume: Bool
    var canMute: Bool
}

protocol SystemTogglesServing: Sendable {
    func wifiPower() -> Bool?
    func setWiFiPower(_ enabled: Bool) throws
    func audioState() -> SystemAudioState?
    func setVolume(_ volume: Double) -> Bool
    func setMuted(_ muted: Bool) -> Bool
}

struct SystemTogglesService: SystemTogglesServing {
    func wifiPower() -> Bool? {
        CWWiFiClient.shared().interface()?.powerOn()
    }

    func setWiFiPower(_ enabled: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw CocoaError(.featureUnsupported)
        }
        try interface.setPower(enabled)
    }

    func audioState() -> SystemAudioState? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        let volume = Self.channels.lazy.compactMap { Self.readFloat(device, kAudioDevicePropertyVolumeScalar, $0) }
        let mute = Self.readUInt32(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard let level = volume.first else {
            return mute.map { SystemAudioState(volume: 1, isMuted: $0 != 0, canSetVolume: false, canMute: true) }
        }
        return SystemAudioState(
            volume: Double(level),
            isMuted: (mute ?? 0) != 0,
            canSetVolume: Self.channels.contains { Self.isSettable(device, kAudioDevicePropertyVolumeScalar, $0) },
            canMute: Self.isSettable(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        )
    }

    func setVolume(_ volume: Double) -> Bool {
        guard let device = Self.defaultOutputDevice() else { return false }
        var value = Float32(min(max(volume, 0), 1))
        var applied = false
        for element in Self.channels where Self.isSettable(device, kAudioDevicePropertyVolumeScalar, element) {
            var address = Self.address(kAudioDevicePropertyVolumeScalar, element)
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                applied = true
                // A master control drives every channel.
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        if applied, value > 0, Self.readUInt32(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) == 1 {
            _ = setMuted(false)
        }
        return applied
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard let device = Self.defaultOutputDevice(),
              Self.isSettable(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static let channels: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func readFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  _ element: AudioObjectPropertyElement) -> Float32? {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   _ element: AudioObjectPropertyElement) -> UInt32? {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Wi-Fi power and output audio for the Dock toggles widget. State is re-read
/// after every change, so a refused write never shows as applied.
@MainActor
final class SystemTogglesStore: ObservableObject {
    static let shared = SystemTogglesStore()
    static let volumeStep = 1.0 / 16

    @Published private(set) var wifiOn: Bool?
    @Published private(set) var audio: SystemAudioState?
    @Published private(set) var errorMessage: String?

    private let service: any SystemTogglesServing
    private let interval: TimeInterval
    private var viewers = 0
    private var pollingTask: Task<Void, Never>?

    init(service: any SystemTogglesServing = SystemTogglesService(), interval: TimeInterval = 3) {
        self.service = service
        self.interval = interval
    }

    func beginViewing() {
        viewers += 1
        guard viewers == 1 else { return }
        let interval = interval
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func endViewing() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        let wifi = service.wifiPower()
        if wifi != wifiOn { wifiOn = wifi }
        let audio = service.audioState()
        if audio != self.audio { self.audio = audio }
    }

    func toggleWiFi() {
        guard let wifiOn else { return }
        do {
            try service.setWiFiPower(!wifiOn)
            errorMessage = nil
        } catch {
            errorMessage = "macOS не дала переключить Wi‑Fi."
        }
        refresh()
    }

    func toggleMute() {
        guard let audio, audio.canMute else { return }
        errorMessage = service.setMuted(!audio.isMuted) ? nil : "Не удалось изменить звук."
        refresh()
    }

    /// Positive steps raise the volume.
    func adjustVolume(by steps: Int) {
        guard let audio, audio.canSetVolume, steps != 0 else { return }
        let target = min(max(audio.volume + Double(steps) * Self.volumeStep, 0), 1)
        errorMessage = service.setVolume(target) ? nil : "Не удалось изменить громкость."
        refresh()
    }
}
