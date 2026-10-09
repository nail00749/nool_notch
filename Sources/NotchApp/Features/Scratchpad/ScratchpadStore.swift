import Foundation
import Combine

struct ScratchpadNote: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var updatedAt: Date
}

private struct ScratchpadDocument: Codable, Sendable {
    var version = 1
    var notes: [ScratchpadNote]
    var selectedNoteID: UUID?
}

private enum ScratchpadPersistenceError: LocalizedError {
    case invalidDocument
    var errorDescription: String? {
        "Файл заметок повреждён или имеет неподдерживаемый формат. Исходный файл сохранён без изменений."
    }
}

/// One serial owner of disk I/O. Revisions reject a delayed older save.
private actor ScratchpadPersistence {
    let fileURL: URL
    private var writtenRevision: UInt64 = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws -> ScratchpadDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ScratchpadDocument(notes: [], selectedNoteID: nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64_000_000 else {
            throw ScratchpadPersistenceError.invalidDocument
        }
        let document: ScratchpadDocument
        do { document = try JSONDecoder().decode(ScratchpadDocument.self, from: Data(contentsOf: fileURL)) }
        catch { throw ScratchpadPersistenceError.invalidDocument }
        guard document.version == 1, document.notes.count <= 30,
              Set(document.notes.map(\.id)).count == document.notes.count,
              document.notes.allSatisfy({ $0.title.count <= 100_000 && $0.body.count <= 100_000
                  && $0.title.utf8.count <= 256_000 && $0.body.utf8.count <= 256_000 }),
              document.selectedNoteID == nil || document.notes.contains(where: { $0.id == document.selectedNoteID }) else {
            throw ScratchpadPersistenceError.invalidDocument
        }
        return document
    }

    func save(_ document: ScratchpadDocument, revision: UInt64) throws {
        guard revision > writtenRevision else { return }
        let data = try JSONEncoder().encode(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        writtenRevision = revision
    }
}

@MainActor
final class ScratchpadStore: ObservableObject {
    static let maximumNotes = 30
    static let maximumTextLength = 100_000
    static let maximumTextBytes = 256_000
    @Published private(set) var notes: [ScratchpadNote] = []
    @Published private(set) var selectedNoteID: UUID?
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canUndoDeletion = false
    private var readFailed = false
    @Published private var isActive = true
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var deletedNote: (note: ScratchpadNote, index: Int)?
    private var pendingSave: Task<Void, Never>?
    private let persistence: ScratchpadPersistence
    private let debounceNanoseconds: UInt64

    init(fileURL: URL? = nil, debounceNanoseconds: UInt64 = 350_000_000) {
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nool/scratchpad.json")
        persistence = ScratchpadPersistence(fileURL: url)
        self.debounceNanoseconds = debounceNanoseconds
    }

    var canEdit: Bool { isLoaded && !readFailed && isActive }
    var hasUnsavedChanges: Bool { persistedRevision < revision }
    var selectedNote: ScratchpadNote? { notes.first { $0.id == selectedNoteID } }

    func load() async {
        guard !isLoading, !isLoaded || readFailed else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let document = try await persistence.load()
            notes = document.notes
            selectedNoteID = document.selectedNoteID ?? notes.first?.id
            readFailed = false
            errorMessage = nil
        } catch {
            readFailed = true
            errorMessage = error.localizedDescription
        }
        isLoaded = true
    }

    func addNote() {
        guard canEdit, notes.count < Self.maximumNotes else { return }
        let note = ScratchpadNote(id: UUID(), title: "", body: "", updatedAt: Date())
        notes.append(note)
        selectedNoteID = note.id
        changed()
    }

    func selectNote(_ id: UUID) {
        guard canEdit, selectedNoteID != id, notes.contains(where: { $0.id == id }) else { return }
        selectedNoteID = id
        changed()
    }

    func updateTitle(_ value: String) { update(value, title: true) }
    func updateBody(_ value: String) { update(value, title: false) }

    private func update(_ value: String, title: Bool) {
        guard canEdit, let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        let bounded = boundedText(value)
        guard (title ? notes[index].title : notes[index].body) != bounded else { return }
        if title { notes[index].title = bounded } else { notes[index].body = bounded }
        notes[index].updatedAt = Date()
        changed()
    }

    private func boundedText(_ text: String) -> String {
        let prefix = text.prefix(Self.maximumTextLength)
        guard prefix.utf8.count > Self.maximumTextBytes else { return String(prefix) }
        var result = ""
        var byteCount = 0
        for character in prefix {
            let string = String(character)
            let bytes = string.utf8.count
            guard byteCount + bytes <= Self.maximumTextBytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result
    }

    func deleteSelectedNote() {
        guard canEdit, let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        deletedNote = (notes.remove(at: index), index)
        canUndoDeletion = true
        selectedNoteID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
        changed()
    }

    func undoDeletion() {
        guard canEdit, let deletedNote, notes.count < Self.maximumNotes else { return }
        notes.insert(deletedNote.note, at: min(deletedNote.index, notes.count))
        selectedNoteID = deletedNote.note.id
        self.deletedNote = nil
        canUndoDeletion = false
        changed()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { Task { await flush() } }
    }

    private func changed() {
        revision += 1
        pendingSave?.cancel()
        pendingSave = Task { [weak self, debounceNanoseconds] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            await self?.persistLatest()
        }
    }

    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await persistLatest()
    }

    private func persistLatest() async {
        guard isLoaded && !readFailed else { return }
        while persistedRevision < revision {
            let savingRevision = revision
            let document = ScratchpadDocument(notes: notes, selectedNoteID: selectedNoteID)
            do {
                try await persistence.save(document, revision: savingRevision)
                persistedRevision = max(persistedRevision, savingRevision)
                errorMessage = nil
            } catch {
                errorMessage = "Не удалось сохранить заметки: \(error.localizedDescription)"
                return
            }
        }
    }
}
