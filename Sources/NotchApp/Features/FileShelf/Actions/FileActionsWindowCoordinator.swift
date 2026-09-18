import AppKit
import SwiftUI

@MainActor
final class FileActionsWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var store: FileActionStore?
    private var finishingStores: [FileActionStore] = []

    func show(urls: [URL], shelf: FileShelfStore, initialKind: FileActionKind? = nil) {
        guard !urls.isEmpty else { return }
        if let store, store.isRunning { window?.makeKeyAndOrderFront(nil); return }
        let store = FileActionStore(urls: urls) { [weak shelf] originals, results, renamed in
            if renamed { shelf?.replace(urls: originals, with: results) }
            else { shelf?.add(urls: results) }
        }
        self.store = store
        if let initialKind { store.kind = initialKind }
        let panel = window ?? UtilityPanel(title: "Действия с файлами",
                                          contentSize: NSSize(width: 640, height: 560),
                                          minimumSize: NSSize(width: 600, height: 480))
        let host = NSHostingView(rootView: FileActionsView(store: store))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        window = panel
        store.window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store?.cancel()
        finishingStores.removeAll { !$0.isRunning }
        if let store, store.isRunning { finishingStores.append(store) }
        window?.contentView = nil
        store = nil
    }

    func stop() {
        store?.cancel()
        finishingStores.forEach { $0.cancel() }
        window?.close()
    }

    func waitForCompletion() async {
        let pending = finishingStores + [store].compactMap { $0 }
        for operation in pending { await operation.waitForCompletion() }
    }
}
