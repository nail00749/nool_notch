import AppKit
import SwiftUI

@MainActor
final class TextRecognitionWindowCoordinator: NSObject, NSWindowDelegate {
    private let modules: AppModuleStore
    private var window: UtilityPanel?
    private var store: TextRecognitionStore?

    var isVisible: Bool { window?.isVisible == true }

    init(modules: AppModuleStore = .shared) {
        self.modules = modules
        super.init()
    }

    func show(urls: [URL], onSendToAI: @escaping (String, String) -> Bool) {
        store?.cancel()
        let store = TextRecognitionStore(
            urls: urls,
            onSendToAI: onSendToAI,
            onClose: { [weak self] in self?.window?.close() }
        )
        show(store: store)
    }

    func show(imageData: Data, onSendToAI: @escaping (String, String) -> Bool) {
        store?.cancel()
        let store = TextRecognitionStore(imageData: imageData, onSendToAI: onSendToAI,
                                         onClose: { [weak self] in self?.window?.close() })
        show(store: store)
    }

    private func show(store: TextRecognitionStore) {
        self.store = store

        let panel = window ?? UtilityPanel(
            title: "Распознавание текста",
            contentSize: NSSize(width: 700, height: 570),
            minimumSize: NSSize(width: 580, height: 470)
        )
        let host = NSHostingView(rootView: TextRecognitionView(store: store, modules: modules))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    func windowWillClose(_ notification: Notification) {
        store?.cancel()
        window?.contentView = nil
        store = nil
    }

    func stop() {
        store?.cancel()
        window?.close()
        store = nil
        window = nil
    }
}
