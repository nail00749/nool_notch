import AppKit
import SwiftUI

@MainActor
final class SpeedTestWindowCoordinator: NSObject {
    private let session: SpeedTestSession
    private let navigation = SpeedTestNavigation()
    private var panel: UtilityPanel?

    init(session: SpeedTestSession = .shared) {
        self.session = session
        super.init()
    }

    func show(section: SpeedTestSection = .test) {
        navigation.section = section
        if let panel {
            panel.makeKeyAndOrderFront(nil)
        } else {
            let window = UtilityPanel(title: "Speedtest", contentSize: NSSize(width: 760, height: 540),
                                      minimumSize: NSSize(width: 700, height: 480))
            let hosting = NSHostingView(rootView: SpeedTestView(session: session, store: session.http,
                                                               diagnostics: session.diagnostics, navigation: navigation))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            panel = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only explicit application/module shutdown cancels the shared session.
    /// Hiding or closing either presentation leaves the network operation alive.
    func stop() {
        session.cancel()
        panel?.close()
    }

    func waitForCompletion() async { await session.waitForCompletion() }
}
