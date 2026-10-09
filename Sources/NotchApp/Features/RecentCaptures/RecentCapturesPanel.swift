import SwiftUI
import AppKit

struct RecentCapturesPanel: View {
    @ObservedObject var store: RecentCapturesStore
    var onAddToShelf: ((URL) -> Void)? = nil
    var onFolderPickerPresentationChange: (Bool) -> Void = { _ in }
    var dismissalRequest: Int = 0
    @State private var folderPicker: NSOpenPanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Недавние снимки").font(.system(size: 14, weight: .semibold))
                    Text(store.folderURL?.lastPathComponent ?? "Выберите папку со снимками")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.folderURL == nil || store.isLoading)
                    .help("Обновить снимки").accessibilityLabel("Обновить снимки")
                Button("Папка…", action: chooseFolder)
                if store.folderURL != nil {
                    Button { store.forgetFolder() } label: { Image(systemName: "xmark") }
                        .help("Убрать папку").accessibilityLabel("Убрать папку снимков")
                }
            }.buttonStyle(NotchButtonStyle())
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if store.isLoading && store.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(NotchPalette.secondary)
                    Text(store.folderURL == nil ? "Снимки под рукой" : "Изображений пока нет").font(.headline)
                    Text(store.folderURL == nil ? "Выберите папку, в которую сохраняете снимки экрана." : "Появившиеся в этой папке изображения будут показаны здесь.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary).multilineTextAlignment(.center)
                    Button("Выбрать папку", action: chooseFolder).buttonStyle(NotchButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(store.items) { item in captureCard(item) }
                    }
                }
            }
            Text(store.isPartial ? "Папка просмотрена частично: достигнут предел файлов или обработки изображений." : "До 40 недавних изображений из выбранной папки.")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
        }
        .onChange(of: dismissalRequest) { _, _ in folderPicker?.cancel(nil) }
        .onDisappear { folderPicker?.cancel(nil) }
    }

    private func captureCard(_ item: RecentCapture) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { NSWorkspace.shared.open(item.url) } label: {
                Image(decorative: item.thumbnail, scale: 1)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 86)
                    .background(NotchPalette.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть \(item.url.lastPathComponent)")
            Text(item.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(item.date, format: .dateTime.day().month().hour().minute())
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
        }
        .padding(7)
        .background(NotchPalette.raised.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Открыть") { NSWorkspace.shared.open(item.url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let onAddToShelf {
                Button("Добавить на полку") { onAddToShelf(item.url) }
            }
        }
    }

    private func chooseFolder() {
        guard folderPicker == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Выбрать"
        panel.message = "Папка со снимками экрана"
        panel.directoryURL = store.folderURL ?? RecentCapturesStore.suggestedFolder
        folderPicker = panel
        onFolderPickerPresentationChange(true)
        panel.begin { response in
            let selectedURL = response == .OK ? panel.url : nil
            // Start the access before allowing the owning notch to collapse.
            if let selectedURL {
                Task { @MainActor in
                    await store.chooseFolder(selectedURL)
                    folderPicker = nil
                    onFolderPickerPresentationChange(false)
                }
            } else {
                folderPicker = nil
                onFolderPickerPresentationChange(false)
            }
        }
    }
}
