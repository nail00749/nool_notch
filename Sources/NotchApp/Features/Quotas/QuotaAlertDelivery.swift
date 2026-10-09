import Foundation
import UserNotifications

enum QuotaAlertAuthorization: Sendable { case notRequested, allowed, denied }

@MainActor
protocol QuotaAlertDelivering {
    func authorization() async -> QuotaAlertAuthorization
    func requestAuthorization() async throws -> Bool
    func deliver(_ event: QuotaAlertEvent) async throws
}

@MainActor
final class SystemQuotaAlertDelivery: NSObject, QuotaAlertDelivering, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpenLimits: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func authorization() async -> QuotaAlertAuthorization {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notRequested
        default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ event: QuotaAlertEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = ["noolQuotaAlert": true]
        try await center.add(UNNotificationRequest(identifier: "nool-quota-\(UUID().uuidString)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.userInfo["noolQuotaAlert"] as? Bool == true else { return }
        await openLimits()
    }

    private func openLimits() { onOpenLimits?() }
}
