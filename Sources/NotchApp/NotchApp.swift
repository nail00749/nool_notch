import AppKit

@MainActor
final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: NotchWindowCoordinator!
    private var launcher: LauncherWindowCoordinator!
    private var screenParametersObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launcher = LauncherWindowCoordinator()
        coordinator = NotchWindowCoordinator(launcher: launcher)
        launcher.onOpenSettings = { [weak self] in self?.coordinator.showSettingsWindow(section: .launcher) }
        coordinator.show()

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

    func applicationWillTerminate(_ notification: Notification) {
        launcher?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let launcher else { return .terminateNow }
        launcher.stop()
        Task { @MainActor in
            await launcher.model.clipboard.waitForPersistence()
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
