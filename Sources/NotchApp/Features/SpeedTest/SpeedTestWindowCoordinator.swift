import AppKit
import SwiftUI

@MainActor
final class SpeedTestWindowCoordinator: NSObject, NSWindowDelegate {
    private let store = SpeedTestStore()
    private let diagnostics = NetworkDiagnosticsStore()
    private let navigation = SpeedTestNavigation()
    private var panel: UtilityPanel?

    func show(section: SpeedTestSection = .test) {
        navigation.section = section
        if let panel {
            panel.makeKeyAndOrderFront(nil)
        } else {
            let window = UtilityPanel(title: "Speedtest", contentSize: NSSize(width: 760, height: 520),
                                      minimumSize: NSSize(width: 700, height: 480))
            window.delegate = self
            let hosting = NSHostingView(rootView: SpeedTestView(store: store, diagnostics: diagnostics,
                                                               navigation: navigation))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            panel = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.cancel()
        diagnostics.cancel()
    }

    func stop() {
        store.cancel()
        diagnostics.cancel()
        panel?.close()
    }
}
