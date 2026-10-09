import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WorkspacesWindowCoordinator {
    private var panel: UtilityPanel?

    func show(store: WorkspaceStore, layouts: WindowLayoutManager) {
        let panel = panel ?? UtilityPanel(title: "Рабочие пространства", contentSize: NSSize(width: 800, height: 580),
                                         minimumSize: NSSize(width: 760, height: 540))
        self.panel = panel
        panel.contentView = NSHostingView(rootView: WorkspacesEditorView(
            store: store,
            layouts: layouts,
            chooseApplications: { [weak self] completion in self?.chooseApplications(completion) },
            chooseFolders: { [weak self] completion in self?.chooseFolders(completion) }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel?.orderOut(nil) }

    private func chooseApplications(_ completion: @escaping ([URL]) -> Void) {
        guard let panel else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.application]
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.message = "Выберите приложения для рабочего пространства."
        picker.prompt = "Добавить"
        picker.beginSheetModal(for: panel) { response in completion(response == .OK ? picker.urls : []) }
    }

    private func chooseFolders(_ completion: @escaping ([URL]) -> Void) {
        guard let panel else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.message = "Выберите папки для рабочего пространства."
        picker.prompt = "Добавить"
        picker.beginSheetModal(for: panel) { response in completion(response == .OK ? picker.urls : []) }
    }
}
