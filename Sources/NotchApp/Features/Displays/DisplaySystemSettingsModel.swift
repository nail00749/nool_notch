import AppKit
import Combine

enum DisplaySystemControl: Hashable, Sendable { case darkMode, nightShift, trueTone, autoBrightness }

enum DisplayAppearanceMode: String, CaseIterable, Hashable, Sendable {
    case light, dark, automatic

    var title: String {
        switch self {
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .automatic: "Авто"
        }
    }

    var next: Self {
        switch self {
        case .light: .dark
        case .dark: .automatic
        case .automatic: .light
        }
    }
}

struct DisplaySystemToggleState: Equatable, Sendable {
    let value: Bool?
    let unavailableReason: String?

    static let unavailable = Self(value: nil, unavailableReason: "Недоступно на этом Mac или дисплее")
    static let loading = Self(value: nil, unavailableReason: "Проверяем доступность…")
}

protocol DisplaySystemSettingsServing: Sendable {
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool?
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool
    func readAppearanceMode() async throws -> DisplayAppearanceMode?
    func writeAppearanceMode(_ mode: DisplayAppearanceMode) async throws -> DisplayAppearanceMode
}

extension DisplaySystemSettingsServing {
    func readAppearanceMode() async throws -> DisplayAppearanceMode? {
        try await read(.darkMode, target: nil).map { $0 ? .dark : .light }
    }

    func writeAppearanceMode(_ mode: DisplayAppearanceMode) async throws -> DisplayAppearanceMode {
        guard mode != .automatic else { throw DisplaySystemSettingsError.unavailable }
        let actual = try await write(mode == .dark, control: .darkMode, target: nil)
        return actual ? .dark : .light
    }
}

struct UnavailableDisplaySystemSettingsService: DisplaySystemSettingsServing {
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? { nil }
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        throw DisplaySystemSettingsError.unavailable
    }
}

enum DisplaySystemSettingsError: LocalizedError {
    case unavailable, notApplied, disconnected
    var errorDescription: String? {
        switch self {
        case .unavailable: "Эта настройка недоступна на данном Mac или дисплее."
        case .notApplied: "macOS не подтвердила изменение настройки. Повторите попытку."
        case .disconnected: "Дисплей отключён или изменился."
        }
    }
}

@MainActor
final class DisplaySystemSettingsModel: ObservableObject {
    @Published private(set) var darkMode = DisplaySystemToggleState.loading
    @Published private(set) var appearanceMode: DisplayAppearanceMode?
    @Published private(set) var appearanceUnavailableReason: String? = "Проверяем доступность…"
    @Published private(set) var nightShift = DisplaySystemToggleState.loading
    @Published private(set) var trueTone = DisplaySystemToggleState.loading
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private var automaticBrightness: [String: DisplaySystemToggleState] = [:]

    var canModify: @MainActor () -> Bool = { true }
    var availabilityOverride: @MainActor (DisplaySystemControl, DisplayHardwareTarget?) -> String? = { _, _ in nil }
    private let service: any DisplaySystemSettingsServing
    private var targets: [DisplayHardwareTarget] = []
    private var running = false
    private var visible = false
    private var epoch = 0
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []
    private var refreshing = false
    private var refreshAgain = false

    init(service: any DisplaySystemSettingsServing = UnavailableDisplaySystemSettingsService()) {
        self.service = service
    }

    func start(displays: [DisplayInfo]) {
        guard !running else { updateDisplays(displays); return }
        running = true
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        updateDisplays(displays)
        scheduleRefresh()
        if visible { setVisible(true) }
    }

    func stop() {
        running = false
        visible = false
        epoch += 1
        refreshTask?.cancel(); refreshTask = nil
        pollTask?.cancel(); pollTask = nil
        observations.removeAll()
        targets = []
        automaticBrightness = [:]
        // These are persistent macOS preferences. Turning the module off must
        // not undo an explicit system preference chosen by the user.
    }

    func updateDisplays(_ displays: [DisplayInfo]) {
        let updated = displays.filter(\.isEnabled).map {
            DisplayHardwareTarget(uuid: $0.id, displayID: $0.displayID, isBuiltin: $0.isBuiltin)
        }
        guard updated != targets else { return }
        epoch += 1
        targets = updated
        automaticBrightness = automaticBrightness.filter { uuid, _ in updated.contains { $0.uuid == uuid } }
        scheduleRefresh()
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        pollTask?.cancel(); pollTask = nil
        guard running, visible else { return }
        scheduleRefresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.running, self.visible else { return }
                self.scheduleRefresh()
            }
        }
    }

    func autoBrightness(for display: DisplayInfo) -> DisplaySystemToggleState {
        guard display.isEnabled else { return .unavailable }
        if let reason = availabilityOverride(.autoBrightness, .init(uuid: display.id, displayID: display.displayID, isBuiltin: display.isBuiltin)) {
            return .init(value: nil, unavailableReason: reason)
        }
        return automaticBrightness[display.id] ?? .loading
    }

    func refresh(displays: [DisplayInfo]) async {
        updateDisplays(displays)
        await refresh()
    }

    func refresh() async {
        guard running, !isBusy else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain, running { refreshAgain = false; scheduleRefresh() }
        }
        let token = epoch
        let snapshot = targets
        do {
            let mode = try await service.readAppearanceMode()
            guard running, token == epoch, !isBusy, !Task.isCancelled else { return }
            appearanceMode = mode
            appearanceUnavailableReason = mode == nil ? DisplaySystemToggleState.unavailable.unavailableReason : nil
        } catch {
            guard running, token == epoch, !isBusy, !Task.isCancelled else { return }
            appearanceMode = nil
            appearanceUnavailableReason = error.localizedDescription
        }
        for control in [DisplaySystemControl.darkMode, .nightShift, .trueTone] {
            let state = await read(control, target: nil)
            guard running, token == epoch, !isBusy, !Task.isCancelled else { return }
            assign(state, control: control)
        }
        for target in snapshot {
            let state = await read(.autoBrightness, target: target)
            guard running, token == epoch, !isBusy, !Task.isCancelled else { return }
            automaticBrightness[target.uuid] = state
        }
    }

    func setDarkMode(_ enabled: Bool) async { await setAppearanceMode(enabled ? .dark : .light) }
    func cycleAppearanceMode() async {
        guard let appearanceMode else { return }
        await setAppearanceMode(appearanceMode.next)
    }
    func setAppearanceMode(_ mode: DisplayAppearanceMode) async {
        guard running, !isBusy, canModify() else { return }
        isBusy = true
        epoch += 1
        let token = epoch
        defer { isBusy = false; scheduleRefresh() }
        do {
            let actual = try await service.writeAppearanceMode(mode)
            guard running, token == epoch else { return }
            guard actual == mode else { throw DisplaySystemSettingsError.notApplied }
            appearanceMode = actual
            appearanceUnavailableReason = nil
            if actual != .automatic { darkMode = .init(value: actual == .dark, unavailableReason: nil) }
            errorMessage = nil
        } catch {
            guard running, token == epoch else { return }
            errorMessage = error.localizedDescription
        }
    }
    func setNightShift(_ enabled: Bool) async { await change(enabled, control: .nightShift) }
    func setTrueTone(_ enabled: Bool) async { await change(enabled, control: .trueTone) }
    func setAutoBrightness(_ enabled: Bool, for display: DisplayInfo) async {
        guard display.isEnabled, let target = targets.first(where: {
            $0.uuid == display.id && $0.displayID == display.displayID
        }) else { return }
        await change(enabled, control: .autoBrightness, target: target)
    }

    private func change(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget? = nil) async {
        guard running, !isBusy, canModify() else { return }
        if let reason = availabilityOverride(control, target) {
            assign(.init(value: nil, unavailableReason: reason), control: control, target: target)
            errorMessage = reason
            return
        }
        isBusy = true
        epoch += 1
        let token = epoch
        defer { isBusy = false; scheduleRefresh() }
        do {
            let actual = try await service.write(enabled, control: control, target: target)
            guard running, token == epoch else { return }
            guard actual == enabled else { throw DisplaySystemSettingsError.notApplied }
            assign(.init(value: actual, unavailableReason: nil), control: control, target: target)
            errorMessage = nil
        } catch {
            guard running, token == epoch else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async -> DisplaySystemToggleState {
        if let reason = availabilityOverride(control, target) { return .init(value: nil, unavailableReason: reason) }
        do {
            guard let value = try await service.read(control, target: target) else { return .unavailable }
            return .init(value: value, unavailableReason: nil)
        } catch { return .init(value: nil, unavailableReason: error.localizedDescription) }
    }

    private func assign(_ state: DisplaySystemToggleState, control: DisplaySystemControl, target: DisplayHardwareTarget? = nil) {
        switch control {
        case .darkMode: darkMode = state
        case .nightShift: nightShift = state
        case .trueTone: trueTone = state
        case .autoBrightness: if let target { automaticBrightness[target.uuid] = state }
        }
    }

    private func scheduleRefresh() {
        guard running else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Coalesce wake, display and appearance notifications.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.refresh()
        }
    }
}
