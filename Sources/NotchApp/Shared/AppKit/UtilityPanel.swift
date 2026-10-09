import AppKit
import SwiftUI

/// Common appearance and text editing for standalone utility windows.
/// Each feature's coordinator still owns presentation, geometry and lifetime.
final class UtilityPanel: TextEditingPanel {
    init(title: String, contentSize: NSSize, minimumSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = minimumSize
        // Inherit the system appearance so utility windows follow macOS Light/Dark mode.
        appearance = nil
        backgroundColor = .windowBackgroundColor
    }
}
