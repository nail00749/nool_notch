import AppKit
import Combine

@MainActor
final class FileActionStore: ObservableObject {
    @Published private(set) var inputURLs: [URL]
    @Published var kind: FileActionKind = .resizeImage { didSet { invalidatePreview() } }
    @Published var options = FileActionOptions() { didSet { invalidatePreview() } }
    @Published var outputDirectory: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputURLs: [URL] = []
    @Published private(set) var renamePlan: [FileRenameEntry] = []
    weak var window: NSWindow?
    private var accessedFiles: [SecurityScopedResource]
    private var destinationAccess: SecurityScopedResource?
    private var worker: Task<Outcome, Error>?
    private let onCompleted: ([URL], [URL], Bool) -> Void

    private enum Outcome: Sendable {
        case preview([FileRenameEntry])
        case files([URL], renamed: Bool)
    }

    init(urls: [URL], onCompleted: @escaping ([URL], [URL], Bool) -> Void = { _, _, _ in }) {
        var seen = Set<String>()
        let inputs = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        inputURLs = inputs
        accessedFiles = inputs.map(SecurityScopedResource.init)
        self.onCompleted = onCompleted
    }

    var selectionSummary: String { "Файлов: \(inputURLs.count)" }

    func run() {
        guard !isRunning, kind != .rename else { return }
        let kind = kind, urls = inputURLs, options = options, directory = outputDirectory
        start {
            .files(try FileActionService.execute(kind: kind, urls: urls, options: options,
                                                  outputDirectory: directory), renamed: false)
        }
    }

    func previewRename() {
        guard !isRunning, kind == .rename else { return }
        let urls = inputURLs, options = options
        start { .preview(try FileActionService.renamePreview(urls: urls, options: options)) }
    }

    func applyRename() {
        guard !isRunning, kind == .rename, !renamePlan.isEmpty else { return }
        let plan = renamePlan
        start { .files(try FileActionService.applyRename(plan), renamed: true) }
    }

    func cancel() { worker?.cancel() }

    func waitForCompletion() async { _ = try? await worker?.value }

    func chooseOutputDirectory() {
        guard !isRunning else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "Выбрать папку"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            self.destinationAccess = SecurityScopedResource(url: url)
            self.outputDirectory = url
        }
        if let window { picker.beginSheetModal(for: window, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }

    private func invalidatePreview() {
        renamePlan = []
        errorMessage = nil
    }

    private func start(_ operation: @escaping @Sendable () throws -> Outcome) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        outputURLs = []
        let originals = inputURLs
        let task = Task.detached(priority: .userInitiated, operation: operation)
        worker = task
        Task {
            defer { isRunning = false; worker = nil }
            do {
                switch try await task.value {
                case .preview(let entries): renamePlan = entries
                case .files(let urls, let renamed):
                    outputURLs = urls
                    renamePlan = []
                    onCompleted(originals, urls, renamed)
                    if renamed {
                        accessedFiles = urls.map(SecurityScopedResource.init)
                        inputURLs = urls
                    }
                }
            } catch is CancellationError {
                errorMessage = "Операция отменена."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
