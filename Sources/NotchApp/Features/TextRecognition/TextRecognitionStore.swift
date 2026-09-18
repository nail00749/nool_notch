import AppKit
import Combine
import Foundation

@MainActor
final class TextRecognitionStore: ObservableObject {
    static let maximumAIDraftCharacters = 12_000

    enum Phase: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    typealias Recognizer = @Sendable ([URL], TextRecognitionCancellation) async throws -> String

    let urls: [URL]
    @Published private(set) var phase: Phase = .idle
    @Published var text = "" {
        didSet { refreshMatches(navigate: false) }
    }
    @Published var searchQuery = "" {
        didSet { refreshMatches(navigate: true) }
    }
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var selectedMatchIndex = 0
    @Published private(set) var selectionRevision = 0
    @Published private(set) var actionMessage: String?

    private let onSendToAI: (String) -> Bool
    private let onClose: () -> Void
    private let recognizer: Recognizer
    private var task: Task<Void, Never>?
    private var cancellation: TextRecognitionCancellation?
    private var generation = 0

    var selectedMatchRange: NSRange? {
        matches.indices.contains(selectedMatchIndex) ? matches[selectedMatchIndex] : nil
    }

    init(
        urls: [URL],
        onSendToAI: @escaping (String) -> Bool,
        onClose: @escaping () -> Void,
        recognizer: @escaping Recognizer = { urls, cancellation in
            try await TextRecognitionService.recognize(urls: urls, cancellation: cancellation)
        }
    ) {
        self.urls = urls
        self.onSendToAI = onSendToAI
        self.onClose = onClose
        self.recognizer = recognizer
    }

    deinit {
        task?.cancel()
        cancellation?.cancel()
    }

    func start() {
        cancel()
        phase = .running
        actionMessage = nil
        let currentGeneration = generation
        let token = TextRecognitionCancellation()
        cancellation = token
        let urls = self.urls
        let recognizer = self.recognizer
        task = Task { [weak self] in
            do {
                let result = try await recognizer(urls, token)
                guard let self, self.generation == currentGeneration,
                      !Task.isCancelled else { return }
                self.text = result
                self.phase = .ready
                self.task = nil
                self.cancellation = nil
            } catch is CancellationError {
                // Closing or starting another selection owns the visible state.
            } catch {
                guard let self, self.generation == currentGeneration,
                      !Task.isCancelled else { return }
                self.phase = .failed((error as? TextRecognitionError)?.localizedDescription
                                     ?? "Не удалось распознать текст. Проверьте файл и повторите попытку.")
                self.task = nil
                self.cancellation = nil
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        cancellation?.cancel()
        cancellation = nil
        if phase == .running { phase = .idle }
    }

    func close() { onClose() }

    func copyText() {
        guard phase == .ready, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        actionMessage = pasteboard.setString(text, forType: .string)
            ? "Текст скопирован." : "Не удалось скопировать текст. Повторите попытку."
    }

    func prepareAIDraft() {
        guard phase == .ready else { return }
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            actionMessage = "Добавьте текст перед передачей в AI."
            return
        }
        guard draft.count <= Self.maximumAIDraftCharacters else {
            actionMessage = "AI-черновик принимает до 12 000 символов. Сократите текст или скопируйте его."
            return
        }
        if onSendToAI(draft) {
            onClose()
        } else {
            actionMessage = "Не удалось открыть AI-черновик: текущий чат занят или AI недоступен. Скопируйте текст либо повторите позже."
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex + 1) % matches.count
        selectionRevision &+= 1
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex - 1 + matches.count) % matches.count
        selectionRevision &+= 1
    }

    private func refreshMatches(navigate: Bool) {
        guard !searchQuery.isEmpty, !text.isEmpty else {
            matches = []
            selectedMatchIndex = 0
            if navigate { selectionRevision &+= 1 }
            return
        }
        let source = text as NSString
        var result: [NSRange] = []
        var offset = 0
        while offset < source.length {
            let range = source.range(
                of: searchQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: offset, length: source.length - offset)
            )
            guard range.location != NSNotFound else { break }
            result.append(range)
            offset = NSMaxRange(range)
            if range.length == 0 { offset += 1 }
        }
        matches = result
        selectedMatchIndex = navigate ? 0 : min(selectedMatchIndex, max(0, result.count - 1))
        if navigate { selectionRevision &+= 1 }
    }
}
