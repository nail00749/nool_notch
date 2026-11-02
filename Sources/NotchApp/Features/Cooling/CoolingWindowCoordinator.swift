import AppKit
import SwiftUI

@MainActor
final class CoolingWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = CoolingWindowCoordinator()
    private let store: CoolingStore
    private var panel: UtilityPanel?

    init(store: CoolingStore = .shared) {
        self.store = store
        super.init()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
        } else {
            let window = UtilityPanel(title: "Охлаждение", contentSize: .init(width: 580, height: 690),
                                      minimumSize: .init(width: 550, height: 560))
            let hosting = NSHostingView(rootView: CoolingPanel(store: store))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.delegate = self
            window.center()
            panel = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Presentation never owns control. The helper lease is held by CoolingStore.
    func stop() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        // Removing the hosting view releases its monitoring subscription. An
        // active control session keeps sampling independently in CoolingStore.
        panel?.contentView = nil
        panel = nil
    }
}
