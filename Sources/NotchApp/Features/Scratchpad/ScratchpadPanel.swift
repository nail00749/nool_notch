import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct ScratchpadExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, UTType(filenameExtension: "md") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ScratchpadPanel: View {
    @ObservedObject var store: ScratchpadStore
    var onExportPresentationChange: (Bool) -> Void = { _ in }
    var dismissalRequest: Int = 0
    @State private var showsPreview = false
    @State private var showsExporter = false
    @State private var exportDocument = ScratchpadExportDocument(text: "")
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let error = store.errorMessage ?? exportError {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Повторить") {
                        exportError = nil
                        Task { if store.canEdit { await store.flush() } else { await store.load() } }
                    }.font(.caption).buttonStyle(NotchButtonStyle())
                }
            }
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedNote != nil {
                TextField("Название заметки", text: Binding(
                    get: { store.selectedNote?.title ?? "" }, set: store.updateTitle
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .disabled(!store.canEdit)
                if showsPreview {
                    ScrollView {
                        Text(markdownPreview)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(NotchPalette.raised.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    TextEditor(text: Binding(
                        get: { store.selectedNote?.body ?? "" }, set: store.updateBody
                    ))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(NotchPalette.raised.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(!store.canEdit)
                    .accessibilityLabel("Текст заметки")
                }
                HStack {
                    Text(store.hasUnsavedChanges ? "Сохранение…" : "Сохранено локально")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    Spacer()
                    Text("\(store.selectedNote?.body.count ?? 0) / 100 000")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(NotchPalette.secondary)
                    Text("Быстрые заметки").font(.headline)
                    Text("Текст хранится только на этом Mac.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary)
                    Button("Создать заметку", action: store.addNote)
                        .buttonStyle(NotchButtonStyle()).disabled(!store.canEdit)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if store.canUndoDeletion {
                HStack {
                    Text("Заметка удалена").font(.caption).foregroundStyle(NotchPalette.secondary)
                    Spacer()
                    Button("Отменить удаление", action: store.undoDeletion)
                        .font(.caption).buttonStyle(NotchButtonStyle())
                        .disabled(store.notes.count >= ScratchpadStore.maximumNotes)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task { await store.load() }
        .fileExporter(isPresented: $showsExporter, document: exportDocument,
                      contentType: exportsMarkdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText,
                      defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { exportError = "Не удалось экспортировать: \(error.localizedDescription)" }
        }
        .onChange(of: showsExporter) { _, presented in onExportPresentationChange(presented) }
        .onChange(of: dismissalRequest) { _, _ in showsExporter = false }
        .onDisappear {
            if showsExporter { onExportPresentationChange(false) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.notes) { note in
                    Button { store.selectNote(note.id) } label: {
                        if note.id == store.selectedNoteID { Label(displayTitle(note), systemImage: "checkmark") }
                        else { Text(displayTitle(note)) }
                    }
                }
                if store.notes.isEmpty { Text("Нет заметок") }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "note.text")
                    Text(store.selectedNote.map(displayTitle) ?? "Заметки").lineLimit(1)
                }.font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!store.canEdit)
            Button(action: store.addNote) { Image(systemName: "plus") }
                .frame(width: 40, height: 40)
                .accessibilityLabel("Новая заметка")
                .help("Новая заметка (до 30)")
                .disabled(!store.canEdit || store.notes.count >= ScratchpadStore.maximumNotes)
            Button { showsPreview.toggle() } label: {
                Image(systemName: showsPreview ? "pencil" : "eye")
            }.frame(width: 40, height: 40)
                .accessibilityLabel(showsPreview ? "Редактировать заметку" : "Просмотр Markdown")
                .help(showsPreview ? "Редактировать" : "Просмотр Markdown")
                .disabled(store.selectedNote == nil)
            Menu {
                Button("Копировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.selectedNote?.body ?? "", forType: .string)
                }
                Button("Экспортировать текст…") { beginExport(markdown: false) }
                Button("Экспортировать Markdown…") { beginExport(markdown: true) }
                Divider()
                Button("Удалить заметку", role: .destructive, action: store.deleteSelectedNote)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!store.canEdit || store.selectedNote == nil)
        }
        .buttonStyle(NotchButtonStyle())
    }

    @State private var exportsMarkdown = false
    private var exportFilename: String {
        let title = store.selectedNote.map(displayTitle) ?? "Заметка"
        let safe = String(title.prefix(80)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return safe + (exportsMarkdown ? ".md" : ".txt")
    }

    private func beginExport(markdown: Bool) {
        exportsMarkdown = markdown
        exportDocument = ScratchpadExportDocument(text: store.selectedNote?.body ?? "")
        showsExporter = true
    }

    private func displayTitle(_ note: ScratchpadNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Без названия" : String(title.prefix(80))
    }

    private var markdownPreview: AttributedString {
        let body = store.selectedNote?.body ?? ""
        return (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}
