import Combine
import Foundation

/// Owns the opt-in preference. Native listeners exist only while the display
/// module is running, configuration is stable and an unaligned edge exists.
@MainActor
final class DisplayCursorCrossingModel: ObservableObject {
    static let preferenceKey = "displays.crossUnalignedEdges.v1"
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isActive = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let service: any DisplayCursorCrossingServing
    private var displays: [DisplayInfo] = []
    private var running = false
    private var suspended = false
    private var failed = false

    init(defaults: UserDefaults = .standard,
         service: any DisplayCursorCrossingServing = UnavailableDisplayCursorCrossingService()) {
        self.defaults = defaults
        self.service = service
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
        service.onFailure = { [weak self] message in
            guard let self, self.running, self.isEnabled, !self.suspended else { return }
            self.failed = true
            self.isActive = false
            self.errorMessage = message
        }
    }

    var statusDescription: String {
        if let errorMessage { return errorMessage }
        guard isEnabled else { return "Выключено. Переход к ближайшему краю соседнего дисплея." }
        guard running else { return "Включится вместе с модулем дисплеев." }
        guard !suspended else { return "Приостановлено на время изменения настроек дисплеев." }
        let screens = DisplayCursorCrossingEligibility.screens(from: displays)
        guard screens.count >= 2 else { return "Ожидает два включённых дисплея без зеркалирования." }
        guard DisplayCursorCrossingGeometry.hasUnalignedEdges(in: screens) else {
            return "Края уже совпадают или дисплеи не соприкасаются. Переход выполняет macOS."
        }
        return "Курсор переходит к ближайшему краю соседнего дисплея. Во время перетаскивания переход выполняет macOS."
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        failed = false
        errorMessage = nil
        reconcile()
    }

    func start(displays: [DisplayInfo]) {
        // A fresh module lifecycle or system wake may recover native state.
        // Ordinary topology refreshes use update and never retry a failed warp.
        running = true
        failed = false
        errorMessage = nil
        update(displays: displays)
    }

    func update(displays: [DisplayInfo]) {
        let old = DisplayCursorCrossingEligibility.screens(from: self.displays)
        let new = DisplayCursorCrossingEligibility.screens(from: displays)
        self.displays = displays
        if old != new {
            failed = false
            errorMessage = nil
        }
        reconcile()
        // statusDescription may change without a preference/runtime transition.
        objectWillChange.send()
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        reconcile()
        objectWillChange.send()
    }

    func stop() {
        running = false
        service.stop()
        isActive = false
        displays = []
        suspended = false
    }

    private func reconcile() {
        guard running, isEnabled, !suspended, !failed else {
            service.stop()
            isActive = false
            return
        }
        do {
            try service.start(displays: displays)
            isActive = service.isRunning
        } catch {
            service.stop()
            failed = true
            isActive = false
            errorMessage = error.localizedDescription
        }
    }
}
