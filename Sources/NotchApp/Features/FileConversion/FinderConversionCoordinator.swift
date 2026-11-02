import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class FinderConversionPreferences: ObservableObject {
    static let shared = FinderConversionPreferences()
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "finderConversion.enabled") } }
    @Published var modifier: FinderConversionModifier {
        didSet { defaults.set(modifier.rawValue, forKey: "finderConversion.modifier") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "finderConversion.enabled") as? Bool ?? true
        modifier = FinderConversionModifier(rawValue: defaults.string(forKey: "finderConversion.modifier") ?? "") ?? .command
    }
}

@MainActor
final class FinderConversionModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var formats: [FileConversionFormat] = []
    @Published private(set) var outputs: [URL] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var progressMessage = "Конвертирую…"
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var title: String { urls.count == 1 ? urls[0].lastPathComponent : "Файлов: \(urls.count)" }

    func prepare(_ urls: [URL]) {
        guard !isRunning else { return }
        guard urls.count <= 20 else {
            showError("За один раз можно конвертировать не более 20 файлов.")
            return
        }
        task?.cancel()
        let token = UUID()
        generation = token
        self.urls = urls
        formats = []; outputs = []; error = nil; isPreparing = true
        task = Task { [weak self] in
            let formats = await Task.detached(priority: .userInitiated) {
                FileConversionService.formats(for: urls)
            }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.formats = formats
            self.isPreparing = false
            if formats.isEmpty { self.error = "Для этих файлов нет общего формата конвертации." }
            self.task = nil
        }
    }

    func showError(_ message: String) {
        guard !isRunning else { return }
        task?.cancel(); generation = UUID()
        urls = []; formats = []; outputs = []; isPreparing = false; error = message
    }

    func convert(to format: FileConversionFormat) {
        guard !isRunning, !isPreparing, formats.contains(format), !urls.isEmpty else { return }
        isRunning = true; error = nil; outputs = []
        progressMessage = "Конвертирую…"
        let operationID = UUID()
        generation = operationID
        let sources = urls
        task = Task { [weak self] in
            do {
                let result = try await FileConversionService.convert(urls: sources, to: format) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning, self.generation == operationID else { return }
                        switch progress {
                        case let .recognizingPDF(page, total):
                            self.progressMessage = "Распознаю страницу \(page) из \(total)…"
                        }
                    }
                }
                self?.outputs = result
            } catch is CancellationError {
                self?.error = "Конвертация отменена."
            } catch { self?.error = error.localizedDescription }
            self?.isRunning = false
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }
    func waitForCompletion() async { await task?.value }
}

private final class FinderConversionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FinderConversionCoordinator {
    private let preferences: FinderConversionPreferences
    private let input = FinderConversionInput()
    let model = FinderConversionModel()
    private var panel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var clickMonitor: Any?
    private var localMonitor: Any?
    private var started = false

    init(preferences: FinderConversionPreferences = .shared) {
        self.preferences = preferences
        preferences.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        input.onSelection = { [weak self] urls, point in
            guard let self, !self.model.isRunning else { return }
            self.model.prepare(urls)
            self.show(at: point)
        }
        input.onError = { [weak self] message in
            guard let self, !self.model.isRunning else { return }
            self.model.showError(message)
            self.show(at: NSEvent.mouseLocation)
        }
        input.onDismiss = { [weak self] in self?.dismiss() }
    }

    func start() {
        guard !started else { return }
        started = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type != .keyDown, event.window !== panel { self.dismiss() }
            return event
        }
        synchronize()
    }

    func stop() {
        started = false
        input.stop()
        model.cancel()
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        clickMonitor = nil; localMonitor = nil
    }

    func waitForCompletion() async { await model.waitForCompletion() }

    private func synchronize() {
        input.modifier = preferences.modifier
        if started && preferences.enabled { input.start() }
        else { input.stop(); model.cancel(); panel?.orderOut(nil) }
    }

    private func show(at point: CGPoint) {
        let panel = self.panel ?? FinderConversionPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Конвертация файлов"
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: FinderConversionRadialView(model: model, close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrame(Self.frame(at: point, within: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
    }

    static func frame(at point: CGPoint, within bounds: CGRect) -> CGRect {
        let size: CGFloat = 344
        return CGRect(x: min(max(point.x - size / 2, bounds.minX), max(bounds.minX, bounds.maxX - size)),
                      y: min(max(point.y - size / 2, bounds.minY), max(bounds.minY, bounds.maxY - size)),
                      width: size, height: size)
    }

    private func dismiss() {
        // Dismissal cancels the operation; the backend removes only outputs it created.
        model.cancel()
        panel?.orderOut(nil)
    }
}
