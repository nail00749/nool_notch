import Foundation

protocol DisplaySystemAppearanceDriving: Sendable {
    func read() throws -> Bool?
    func setDarkMode(_ enabled: Bool) throws
    func readMode() throws -> DisplayAppearanceMode?
    func setMode(_ mode: DisplayAppearanceMode) throws
}

protocol DisplaySystemColorDriving: Sendable {
    func nightShift() throws -> Bool?
    func setNightShift(_ enabled: Bool) throws
    func trueTone() throws -> Bool?
    func setTrueTone(_ enabled: Bool) throws
    func autoBrightness(for target: DisplayHardwareTarget) throws -> Bool?
    func setAutoBrightness(_ enabled: Bool, for target: DisplayHardwareTarget) throws
}

/// Dynamic private interfaces stay on one serial queue with a finite watchdog.
/// A stuck system call disables this executor rather than spawning more workers.
final class DynamicDisplaySystemSettingsService: DisplaySystemSettingsServing, @unchecked Sendable {
    private let appearance: any DisplaySystemAppearanceDriving
    private let color: any DisplaySystemColorDriving
    private let executor: DisplayHardwareExecutor

    init(appearance: any DisplaySystemAppearanceDriving = SystemDisplayAppearanceDriver(),
         color: any DisplaySystemColorDriving = SystemDisplayColorDriver(),
         executor: DisplayHardwareExecutor = DisplayHardwareExecutor()) {
        self.appearance = appearance
        self.color = color
        self.executor = executor
    }

    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? {
        do {
            return try await executor.run { [self] active in
                guard active() else { throw CancellationError() }
                return try current(control, target: target)
            }
        } catch let error as DisplayHardwareBrightnessError {
            throw DisplaySystemSettingsServiceError.driver(error)
        }
    }

    func readAppearanceMode() async throws -> DisplayAppearanceMode? {
        do {
            return try await executor.run { [self] active in
                guard active() else { throw CancellationError() }
                return try appearance.readMode()
            }
        } catch let error as DisplayHardwareBrightnessError {
            throw DisplaySystemSettingsServiceError.driver(error)
        }
    }

    func writeAppearanceMode(_ mode: DisplayAppearanceMode) async throws -> DisplayAppearanceMode {
        do {
            return try await executor.run { [self] active in
                guard active() else { throw CancellationError() }
                guard try appearance.readMode() != nil else { throw DisplaySystemSettingsError.unavailable }
                guard active() else { throw CancellationError() }
                try appearance.setMode(mode)
                guard active() else { throw CancellationError() }
                guard let actual = try appearance.readMode(), actual == mode else { throw DisplaySystemSettingsError.notApplied }
                return actual
            }
        } catch let error as DisplayHardwareBrightnessError {
            throw DisplaySystemSettingsServiceError.driver(error)
        }
    }

    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        do {
            return try await executor.run { [self] active in
                guard active() else { throw CancellationError() }
                guard try current(control, target: target) != nil else { throw DisplaySystemSettingsError.unavailable }
                guard active() else { throw CancellationError() }
                switch control {
                case .darkMode: try appearance.setDarkMode(enabled)
                case .nightShift: try color.setNightShift(enabled)
                case .trueTone: try color.setTrueTone(enabled)
                case .autoBrightness:
                    guard let target else { throw DisplaySystemSettingsError.disconnected }
                    try color.setAutoBrightness(enabled, for: target)
                }
                guard active() else { throw CancellationError() }
                guard let actual = try current(control, target: target), actual == enabled else {
                    throw DisplaySystemSettingsError.notApplied
                }
                return actual
            }
        } catch let error as DisplayHardwareBrightnessError {
            throw DisplaySystemSettingsServiceError.driver(error)
        }
    }

    private func current(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) throws -> Bool? {
        switch control {
        case .darkMode: return try appearance.read()
        case .nightShift: return try color.nightShift()
        case .trueTone: return try color.trueTone()
        case .autoBrightness:
            guard let target else { throw DisplaySystemSettingsError.disconnected }
            return try color.autoBrightness(for: target)
        }
    }
}

private enum DisplaySystemSettingsServiceError: LocalizedError {
    case driver(DisplayHardwareBrightnessError)
    var errorDescription: String? {
        "Системная настройка не ответила вовремя или занята. Повторите попытку; если ошибка сохраняется, перезапустите NooL."
    }
}
