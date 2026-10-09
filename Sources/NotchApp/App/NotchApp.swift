import AppKit

@MainActor
final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: NotchWindowCoordinator!
    private var launcher: LauncherWindowCoordinator!
    private var screenParametersObserver: NSObjectProtocol?
    private var pendingWidgetOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppAppearanceSettings.shared.applyCurrentTheme()
        launcher = LauncherWindowCoordinator()
        coordinator = NotchWindowCoordinator(launcher: launcher)
        launcher.onOpenSettings = { [weak self] in self?.coordinator.showSettingsWindow(section: .launcher) }
        coordinator.show()
        if pendingWidgetOpen {
            coordinator.openWidgetLimits()
            pendingWidgetOpen = false
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coordinator.reposition()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: QuotaWidgetLink.opensLimits) else { return }
        guard let coordinator else {
            pendingWidgetOpen = true
            return
        }
        coordinator.openWidgetLimits()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        launcher?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let launcher else { return .terminateNow }
        Task { @MainActor in
            if let coordinator, !(await coordinator.saveScratchpadBeforeTermination()) {
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "Не удалось сохранить черновик"
                alert.informativeText = "NooL остаётся открытым, чтобы не потерять изменения. Откройте черновик и повторите сохранение."
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
                return
            }
            coordinator?.stop()
            launcher.stop()
            await coordinator.waitForFileActions()
            await coordinator.waitForQuotaWidgetPersistence()
            await coordinator.waitForLidEffect()
            await launcher.model.clipboard.waitForPersistence()
            await launcher.model.snippets.waitForPersistence()
            await launcher.model.aiChat.waitForPersistence()
            // Allow owned CLI processes to finish their bounded TERM -> KILL cleanup.
            try? await Task.sleep(for: .milliseconds(1_200))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct NotchApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = NotchAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
