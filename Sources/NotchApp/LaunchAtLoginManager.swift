import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var statusMessage: String? {
        if let errorMessage {
            return errorMessage
        }

        switch status {
        case .requiresApproval:
            return "Подтвердите запуск NotchApp в настройках Login Items."
        case .notFound:
            return "Автозапуск недоступен для этого bundle."
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }

        refresh()
    }
}
