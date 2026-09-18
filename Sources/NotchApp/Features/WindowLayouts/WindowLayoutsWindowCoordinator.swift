import AppKit
import SwiftUI

@MainActor
final class WindowLayoutsWindowCoordinator {
    private var panel: TextEditingPanel?

    func show(manager: WindowLayoutManager, targetPID: pid_t?) {
        let wasVisible = panel?.isVisible == true
        let panel = panel ?? UtilityPanel(title: "Окна и раскладки",
                                         contentSize: NSSize(width: 580, height: 540),
                                         minimumSize: NSSize(width: 580, height: 510))
        let view = WindowLayoutsView(manager: manager, targetPID: targetPID)
        if let host = panel.contentView as? NSHostingView<WindowLayoutsView> {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            panel.contentView = host
        }
        self.panel = panel
        if !wasVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel?.close() }
}
