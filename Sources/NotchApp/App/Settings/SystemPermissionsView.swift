import AppKit
import ApplicationServices
import CoreBluetooth
import EventKit
import SwiftUI
import UserNotifications

enum SystemPermissionStatus: Equatable, Sendable {
    case granted, notDetermined, denied
    /// The state can't be read yet, e.g. the automation target isn't running.
    case unknown

    var title: String {
        switch self {
        case .granted: "Разрешено"
        case .notDetermined: "Не разрешено"
        case .denied: "Запрещено"
        case .unknown: "Неизвестно"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .notDetermined: "questionmark.circle"
        case .denied: "xmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .notDetermined: .secondary
        case .denied: .orange
        case .unknown: .secondary
        }
    }
}

enum SystemPermission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, fullDiskAccess, calendars, notifications, bluetooth
    case automationFinder, automationSystemEvents

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: "Универсальный доступ"
        case .screenRecording: "Запись экрана"
        case .fullDiskAccess: "Полный доступ к диску"
        case .calendars: "Календари"
        case .notifications: "Уведомления"
        case .bluetooth: "Bluetooth"
        case .automationFinder: "Управление Finder"
        case .automationSystemEvents: "Управление System Events"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            "Окна и бейджи в Dock, свёрнутые окна, раскладки окон, выделенный текст в Launcher и резервный источник музыки."
        case .screenRecording: "Миниатюры окон в Dock, эффект крышки и распознавание текста с экрана."
        case .fullDiskAccess: "Состояние Корзины в Dock (пустая или полная)."
        case .calendars: "События календаря в чёлке и в Dock."
        case .notifications: "Предупреждения о лимитах AI-провайдеров."
        case .bluetooth: "Live Activity подключения Bluetooth-наушников."
        case .automationFinder: "Очистка Корзины из Dock."
        case .automationSystemEvents: "Пункт «Открывать при входе» в меню приложений Dock."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .fullDiskAccess: "internaldrive"
        case .calendars: "calendar"
        case .notifications: "bell.badge"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .automationFinder: "face.smiling"
        case .automationSystemEvents: "gearshape.2"
        }
    }

    /// macOS lets an app ask only for some permissions; the rest are granted in System Settings.
    var canRequest: Bool { self != .fullDiskAccess }

    var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .calendars: "Privacy_Calendars"
        case .notifications: "Notifications"
        case .bluetooth: "Privacy_Bluetooth"
        case .automationFinder, .automationSystemEvents: "Privacy_Automation"
        }
        if self == .notifications { return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var automationBundleIdentifier: String? {
        switch self {
        case .automationFinder: "com.apple.finder"
        case .automationSystemEvents: "com.apple.systemevents"
        default: nil
        }
    }
}

/// Reads every privacy permission NooL uses and asks for one only from an explicit button.
@MainActor
final class SystemPermissionsModel: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var statuses: [SystemPermission: SystemPermissionStatus] = [:]
    @Published private(set) var requesting: Set<SystemPermission> = []
    private var bluetooth: CBCentralManager?
    private var refreshTask: Task<Void, Never>?

    func status(_ permission: SystemPermission) -> SystemPermissionStatus { statuses[permission] ?? .unknown }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var result: [SystemPermission: SystemPermissionStatus] = [
                // macOS does not tell "never asked" from "refused" for these two.
                .accessibility: AXIsProcessTrusted() ? .granted : .notDetermined,
                .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
                .calendars: Self.calendarStatus(),
                .bluetooth: Self.bluetoothStatus(),
            ]
            result[.notifications] = await Self.notificationStatus()
            let detached = await Task.detached(priority: .utility) {
                (Self.fullDiskAccessStatus(),
                 Self.automationStatus("com.apple.finder", ask: false),
                 Self.automationStatus("com.apple.systemevents", ask: false))
            }.value
            result[.fullDiskAccess] = detached.0
            result[.automationFinder] = detached.1
            result[.automationSystemEvents] = detached.2
            guard let self, !Task.isCancelled else { return }
            if result != self.statuses { self.statuses = result }
        }
    }

    func request(_ permission: SystemPermission) {
        // A denied permission can't be asked again; macOS only allows changing it in System Settings.
        if status(permission) == .denied, permission != .accessibility, permission != .screenRecording {
            openSettings(permission)
            return
        }
        requesting.insert(permission)
        Task { [weak self] in
            switch permission {
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
            case .calendars:
                _ = try? await EKEventStore().requestFullAccessToEvents()
            case .notifications:
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            case .bluetooth:
                // Creating a central manager is what shows the Bluetooth prompt.
                if let self, self.bluetooth == nil {
                    self.bluetooth = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
                }
            case .automationFinder, .automationSystemEvents:
                if let identifier = permission.automationBundleIdentifier {
                    await Self.launchIfNeeded(identifier)
                    _ = await Task.detached(priority: .userInitiated) { Self.automationStatus(identifier, ask: true) }.value
                }
            case .fullDiskAccess:
                self?.openSettings(permission)
            }
            self?.requesting.remove(permission)
            self?.refresh()
        }
    }

    func openSettings(_ permission: SystemPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private static func calendarStatus() -> SystemPermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .unknown
        }
    }

    private static func bluetoothStatus() -> SystemPermissionStatus {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    private static func notificationStatus() async -> SystemPermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    /// No API reports Full Disk Access; reading the protected TCC database is the standard probe.
    nonisolated static func fullDiskAccessStatus() -> SystemPermissionStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .denied }
        try? handle.close()
        return .granted
    }

    nonisolated static func automationStatus(_ bundleIdentifier: String, ask: Bool) -> SystemPermissionStatus {
        var target = AEAddressDesc()
        let identifier = Array(bundleIdentifier.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), identifier, identifier.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown // procNotFound: the target app isn't running yet
        }
    }

    private static func launchIfNeeded(_ bundleIdentifier: String) async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(for: .milliseconds(600))
    }
}

struct SystemPermissionsView: View {
    @StateObject private var model = SystemPermissionsModel()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Системные разрешения", icon: "lock.shield") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Разрешения запрашиваются только по кнопке. Запрещённые и не запрашиваемые программно включаются в Системных настройках.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).padding(.bottom, 10)
                    ForEach(Array(SystemPermission.allCases.enumerated()), id: \.element) { index, permission in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        row(permission)
                    }
                }.font(.system(size: 12))
            }
        }
        .onAppear(perform: model.refresh)
        .onReceive(timer) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private func row(_ permission: SystemPermission) -> some View {
        let status = model.status(permission)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.symbol).font(.system(size: 15)).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.system(size: 12, weight: .semibold))
                Text(permission.purpose).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Label(status.title, systemImage: status.symbol).font(.system(size: 11))
                    .foregroundStyle(status.color).labelStyle(.titleAndIcon)
                HStack(spacing: 6) {
                    if model.requesting.contains(permission) { ProgressView().controlSize(.small) }
                    if status != .granted, permission.canRequest, status != .denied
                        || permission == .accessibility || permission == .screenRecording {
                        Button("Запросить") { model.request(permission) }
                            .disabled(model.requesting.contains(permission))
                    }
                    Button("Настройки…") { model.openSettings(permission) }
                }.controlSize(.small)
            }
        }
    }
}
