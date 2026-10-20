import AppKit
import SwiftUI

/// Drags files out of stacks and the fan as Finder does: the session offers copy, move and
/// generic, so a destination such as the Dock Trash can take a move. SwiftUI's `onDrag`
/// decides the operations itself, and the Trash then saw only a copy.
@MainActor
final class DockFileDragSource: NSObject, NSDraggingSource {
    static let shared = DockFileDragSource()

    private var dragging = false
    private var onEnd: (() -> Void)?

    /// Starts the session from the mouse-dragged event being handled; repeated calls while the
    /// pointer keeps moving are ignored.
    func begin(_ url: URL, icon: NSImage, onEnd: (() -> Void)? = nil) {
        guard !dragging, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let view = event.window?.contentView else { return }
        dragging = true
        self.onEnd = onEnd
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = view.convert(event.locationInWindow, from: nil)
        let size = CGSize(width: 48, height: 48)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), contents: icon)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated {
            dragging = false
            let callback = onEnd
            onEnd = nil
            callback?()
        }
    }
}

extension View {
    /// Makes a file row draggable through `DockFileDragSource` without blocking its tap.
    func dockFileDrag(_ url: URL, icon: @escaping () -> NSImage, onEnd: (() -> Void)? = nil) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
            DockFileDragSource.shared.begin(url, icon: icon(), onEnd: onEnd)
        })
    }
}
