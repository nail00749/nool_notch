import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct DockWindowApplicationIdentity: Equatable, Sendable {
    let pid: Int32
    let applicationPath: String
    let launchDate: Date
}

/// Frame uses WindowServer/Accessibility coordinates, with the primary display's top left as origin.
struct DockWindowRecord: Identifiable, Equatable, Sendable {
    let id: UInt32
    let application: DockWindowApplicationIdentity
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let captureWindowID: UInt32?
    let accessibilityToken: UUID?
    let availableActions: Set<DockWindowAction>
}

struct DockWindowPreview: Identifiable {
    let record: DockWindowRecord
    var image: NSImage?

    var id: UInt32 { record.id }
    var pid: Int32 { record.application.pid }
    var title: String { record.title.isEmpty ? "Окно без названия" : record.title }
    var frame: CGRect { record.frame }
    var applicationPath: String { record.application.applicationPath }
    var processLaunchDate: Date { record.application.launchDate }
    var isMinimized: Bool { record.isMinimized }
    var availableActions: Set<DockWindowAction> { record.availableActions }
}

protocol DockWindowPreviewBackend: Sendable {
    func windows(for application: DockWindowApplicationIdentity, captureAllowed: Bool,
                 accessibilityAllowed: Bool) async throws -> [DockWindowRecord]
    func thumbnail(for window: DockWindowRecord) async throws -> CGImage?
    func perform(_ action: DockWindowAction, on window: DockWindowRecord,
                 screens: [WindowLayoutScreen]) async throws
}

@MainActor
protocol DockWindowPreviewEnvironment {
    var hasCaptureAccess: Bool { get }
    var hasAccessibilityAccess: Bool { get }
    func application(at path: String) -> DockWindowApplicationIdentity?
    func isCurrent(_ application: DockWindowApplicationIdentity) -> Bool
    func requestCaptureAccess()
    func requestAccessibilityAccess()
    func screens() -> [WindowLayoutScreen]
}

@MainActor
final class DockWindowPreviewService: ObservableObject {
    @Published private(set) var windows: [DockWindowPreview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCaptureAccess = false
    @Published private(set) var hasAccessibilityAccess = false
    @Published private(set) var presentationID: UUID?

    private let backend: any DockWindowPreviewBackend
    private let environment: any DockWindowPreviewEnvironment
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var selectedPath: String?
    private var actionInProgress = false
    private static let maximumWindows = 24

    init(backend: any DockWindowPreviewBackend = SystemDockWindowPreviewBackend(),
         environment: (any DockWindowPreviewEnvironment)? = nil) {
        self.backend = backend
        self.environment = environment ?? SystemDockWindowPreviewEnvironment()
        refreshPermissions()
    }

    /// Enumeration and snapshots happen only while the corresponding surface is open.
    func show(applicationPath: String) async {
        await show(applicationPath: applicationPath, presentationID: UUID())
    }

    /// A surface owns its presentation, including when the same application is reopened.
    /// A disappearing older surface must not clear the next surface's work or images.
    func show(applicationPath: String, presentationID: UUID) async {
        guard !Task.isCancelled else { return }
        work?.cancel()
        let request = UUID()
        generation = request
        self.presentationID = presentationID
        selectedPath = applicationPath
        windows = []
        errorMessage = nil
        refreshPermissions()
        guard let application = environment.application(at: applicationPath) else {
            isLoading = false
            errorMessage = "Приложение уже завершено."
            return
        }
        guard hasCaptureAccess || hasAccessibilityAccess else {
            isLoading = false
            return
        }
        isLoading = true
        let captureAllowed = hasCaptureAccess
        let accessibilityAllowed = hasAccessibilityAccess
        let task = Task { [weak self, backend] in
            defer {
                if let self, self.generation == request {
                    self.isLoading = false
                    if !self.environment.isCurrent(application) {
                        self.windows = []
                        self.errorMessage = "Приложение уже завершено."
                    }
                }
            }
            do {
                let records = try await backend.windows(for: application, captureAllowed: captureAllowed,
                                                        accessibilityAllowed: accessibilityAllowed)
                guard let self, self.accepts(request, application: application) else { return }
                self.windows = records.prefix(Self.maximumWindows).map { .init(record: $0, image: nil) }
                var firstCaptureError: Error?
                for record in records.prefix(Self.maximumWindows) where captureAllowed && !record.isMinimized {
                    try Task.checkCancellation()
                    // Revoked permissions must stop new requests without prompting again.
                    guard self.environment.hasCaptureAccess else {
                        self.refreshPermissions()
                        self.windows = self.windows.map { .init(record: $0.record, image: nil) }
                        break
                    }
                    do {
                        let image = try await backend.thumbnail(for: record)
                        guard self.accepts(request, application: application) else { return }
                        if let image, let index = self.windows.firstIndex(where: { $0.record == record }) {
                            self.windows[index].image = NSImage(cgImage: image, size: .zero)
                        } else if image == nil {
                            firstCaptureError = firstCaptureError ?? DockWindowPreviewError.captureUnavailable
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard self.accepts(request, application: application) else { return }
                        firstCaptureError = firstCaptureError ?? error
                        self.refreshPermissions()
                        if !self.hasCaptureAccess {
                            self.windows = self.windows.map { .init(record: $0.record, image: nil) }
                            break
                        }
                        // One protected or closed window must not prevent other previews.
                    }
                }
                guard self.accepts(request, application: application) else { return }
                if let firstCaptureError, self.hasCaptureAccess,
                   self.windows.contains(where: { !$0.isMinimized }),
                   self.windows.allSatisfy({ $0.image == nil }) {
                    self.errorMessage = firstCaptureError.localizedDescription
                }
                self.isLoading = false
            } catch {
                guard let self, self.generation == request else { return }
                self.isLoading = false
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancel(presentationID: UUID) {
        guard self.presentationID == presentationID else { return }
        cancel()
    }

    func isPresented(by presentationID: UUID) -> Bool { self.presentationID == presentationID }

    /// Global shutdown/sleep/feature-disable cancellation is intentionally unconditional.
    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        selectedPath = nil
        presentationID = nil
        windows = [] // Images have no disk cache or lifetime beyond the open preview.
        isLoading = false
        errorMessage = nil
    }

    func refreshPermissions() {
        hasCaptureAccess = environment.hasCaptureAccess
        hasAccessibilityAccess = environment.hasAccessibilityAccess
        if !hasCaptureAccess { windows = windows.map { .init(record: $0.record, image: nil) } }
    }

    func requestCaptureAccess() {
        environment.requestCaptureAccess()
        refreshPermissions()
    }

    func requestAccessibilityAccess() {
        environment.requestAccessibilityAccess()
        refreshPermissions()
    }

    func perform(_ action: DockWindowAction, on preview: DockWindowPreview, presentationID: UUID? = nil) async {
        if let presentationID, !isPresented(by: presentationID) { return }
        guard !actionInProgress else { return }
        refreshPermissions()
        guard hasAccessibilityAccess else {
            errorMessage = "Разрешите выбор окна в Универсальном доступе."
            return
        }
        guard windows.contains(where: { $0.record == preview.record }),
              environment.isCurrent(preview.record.application) else {
            errorMessage = "Окно уже изменилось или приложение завершено. Откройте превью ещё раз."
            return
        }
        guard preview.availableActions.contains(action) else {
            errorMessage = "Это действие недоступно для выбранного окна."
            return
        }
        let request = generation
        actionInProgress = true
        defer { actionInProgress = false }
        do {
            try await backend.perform(action, on: preview.record, screens: environment.screens())
            guard generation == request else { return }
            if action == .activate { cancel() }
            else if let selectedPath, let presentationID = self.presentationID {
                await show(applicationPath: selectedPath, presentationID: presentationID)
            }
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func accepts(_ request: UUID, application: DockWindowApplicationIdentity) -> Bool {
        !Task.isCancelled && generation == request && environment.isCurrent(application)
    }

    /// Read-only WindowServer metadata. Does not request Screen Recording or Accessibility access.
    static func hasOverlappingWindow(inAppKitFrame frame: CGRect) -> Bool {
        guard let target = windowServerRect(fromAppKit: frame) else { return false }
        return otherApplicationWindowFrames().contains { $0.intersects(target) }
    }

    /// The process owning a native full-screen window (or a borderless one covering the display).
    static func fullscreenOwner(onAppKitScreen screenFrame: CGRect) -> Int32? {
        guard let display = windowServerRect(fromAppKit: screenFrame) else { return nil }
        let screen = NSScreen.screens.first { $0.frame == screenFrame }
        // On a display with a camera housing, full-screen content starts below the notch strip.
        let topInset = max(screen?.safeAreaInsets.top ?? 0, screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0)
        let windows = otherApplicationWindows().filter { $0.frame.intersects(display) }
        return DockFullscreenDetection.owner(windows: windows, display: display, topInset: topInset)
    }

    private static func windowServerRect(fromAppKit frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) ?? NSScreen.screens.first else { return nil }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func otherApplicationWindowFrames() -> [CGRect] { otherApplicationWindows().map(\.frame) }

    /// On-screen, normal-level, visible windows of other processes in WindowServer coordinates.
    private static func otherApplicationWindows() -> [DockFullscreenDetection.Window] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return rows.compactMap { row in
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return .init(pid: pid, frame: rect)
        }
    }
}

/// WindowServer exposes no public "this Space is full screen" flag. A full-screen Space shows
/// only its application's windows on that display, and one of them spans the display edge to
/// edge, starting at the top or just below the menu bar/notch strip. Requiring a single owner
/// distinguishes it from an ordinary maximized window among other applications' windows.
enum DockFullscreenDetection {
    struct Window: Equatable, Sendable {
        let pid: Int32
        let frame: CGRect
    }

    /// `display` and window frames use WindowServer coordinates (origin top left, y down).
    static func isFullscreen(windows: [Window], display: CGRect, topInset: CGFloat) -> Bool {
        owner(windows: windows, display: display, topInset: topInset) != nil
    }

    static func owner(windows: [Window], display: CGRect, topInset: CGFloat) -> Int32? {
        guard let owner = windows.first?.pid, windows.allSatisfy({ $0.pid == owner }) else { return nil }
        let tolerance: CGFloat = 1
        let fills = windows.contains { window in
            abs(window.frame.minX - display.minX) <= tolerance
                && abs(window.frame.maxX - display.maxX) <= tolerance
                && abs(window.frame.maxY - display.maxY) <= tolerance
                && window.frame.minY >= display.minY - tolerance
                && window.frame.minY <= display.minY + max(0, topInset) + tolerance
        }
        return fills ? owner : nil
    }
}

@MainActor
private struct SystemDockWindowPreviewEnvironment: DockWindowPreviewEnvironment {
    var hasCaptureAccess: Bool { CGPreflightScreenCaptureAccess() }
    var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    func application(at path: String) -> DockWindowApplicationIdentity? {
        NSWorkspace.shared.runningApplications.compactMap(Self.identity).first {
            $0.applicationPath == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    func isCurrent(_ application: DockWindowApplicationIdentity) -> Bool {
        NSRunningApplication(processIdentifier: application.pid).flatMap(Self.identity) == application
    }

    private static func identity(_ app: NSRunningApplication) -> DockWindowApplicationIdentity? {
        guard !app.isTerminated, app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let url = app.bundleURL, let launchDate = app.launchDate else { return nil }
        return .init(pid: app.processIdentifier,
                     applicationPath: url.resolvingSymlinksInPath().standardizedFileURL.path, launchDate: launchDate)
    }

    func requestCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    func requestAccessibilityAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func screens() -> [WindowLayoutScreen] {
        guard let primary = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) ?? NSScreen.screens.first else { return [] }
        func ax(_ frame: CGRect) -> WindowLayoutRect {
            .init(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        }
        return NSScreen.screens.enumerated().map { index, screen in
            .init(id: String(index), frame: ax(screen.frame), visibleFrame: ax(screen.visibleFrame))
        }
    }
}

enum DockWindowPreviewError: LocalizedError, Equatable {
    case unavailable, ambiguous, unsupported, permission, timeout, failed, captureUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Окно уже изменилось или приложение завершено. Откройте превью ещё раз."
        case .ambiguous: "Не удалось однозначно определить окно. Откройте приложение через его иконку."
        case .unsupported: "Приложение не поддерживает это действие с окном."
        case .permission: "Разрешение macOS недоступно. Включите его явно в настройках Dock."
        case .timeout: "Приложение не ответило вовремя. Повторите попытку."
        case .failed: "Не удалось выполнить действие с окном."
        case .captureUnavailable: "Не удалось получить снимок окна. Проверьте доступ к записи экрана и откройте превью ещё раз."
        }
    }
}

actor SystemDockWindowPreviewBackend: DockWindowPreviewBackend {
    private var captureWindows: [UInt32: SCWindow] = [:]
    private let actions = DockWindowActions()

    func windows(for application: DockWindowApplicationIdentity, captureAllowed: Bool,
                 accessibilityAllowed: Bool) async throws -> [DockWindowRecord] {
        captureWindows = [:]
        guard DockWindowActions.isCurrent(application) else { throw DockWindowPreviewError.unavailable }
        let ax = accessibilityAllowed ? await actions.snapshot(application) : []
        try Task.checkCancellation()
        var descriptors = DockWindowServerMetadata.windows(for: application.pid)
        if captureAllowed && CGPreflightScreenCaptureAccess() {
            let content: DockShareableContent?
            do { content = try await Self.content() }
            catch {
                try Task.checkCancellation()
                // A revoked/not-yet-effective capture grant must not discard an available AX list.
                content = nil
            }
            try Task.checkCancellation()
            guard DockWindowActions.isCurrent(application) else { throw DockWindowPreviewError.unavailable }
            let candidates = content?.value.windows.filter {
                $0.owningApplication?.processID == application.pid && $0.windowLayer == 0
                    && $0.frame.width > 1 && $0.frame.height > 1
            } ?? []
            for window in candidates.prefix(128) {
                captureWindows[window.windowID] = window
                if !descriptors.contains(where: { $0.id == window.windowID }) {
                    descriptors.append(.init(id: window.windowID, pid: application.pid, title: window.title ?? "",
                                             frame: window.frame, isOnScreen: window.isOnScreen))
                }
            }
            // ScreenCaptureKit may provide names that WindowServer hides without capture access.
            descriptors = descriptors.map { descriptor in
                guard let window = captureWindows[descriptor.id] else { return descriptor }
                return .init(id: descriptor.id, pid: descriptor.pid, title: window.title ?? descriptor.title,
                             frame: descriptor.frame, isOnScreen: descriptor.isOnScreen,
                             layer: descriptor.layer, alpha: descriptor.alpha)
            }
        }
        let records = DockWindowRecordBuilder.records(application: application, descriptors: descriptors,
                                                      accessibility: ax, captureWindowIDs: Set(captureWindows.keys))
        let visibleCaptureIDs = Set(records.compactMap(\.captureWindowID))
        captureWindows = captureWindows.filter { visibleCaptureIDs.contains($0.key) }
        return records
    }

    func thumbnail(for window: DockWindowRecord) async throws -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { throw DockWindowPreviewError.permission }
        guard !window.isMinimized else { return nil }
        guard DockWindowActions.isCurrent(window.application) else { throw DockWindowPreviewError.unavailable }
        guard let id = window.captureWindowID, let source = captureWindows[id] else {
            throw DockWindowPreviewError.captureUnavailable
        }
        guard source.owningApplication?.processID == window.application.pid,
              DockWindowServerMetadata.isCurrent(window) else { throw DockWindowPreviewError.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: source)
        let configuration = SCStreamConfiguration()
        let ratio = min(480 / max(window.frame.width, 1), 300 / max(window.frame.height, 1), 1)
        configuration.width = max(1, Int(window.frame.width * ratio))
        configuration.height = max(1, Int(window.frame.height * ratio))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let gate = DockPreviewGate<DockCapturedImage>()
        let result: DockCapturedImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image { gate.finish(.success(.init(value: image))) }
                    else { gate.finish(.failure(DockWindowPreviewError.captureUnavailable)) }
                }
                gate.timeout(after: 4)
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw DockWindowPreviewError.permission }
        guard DockWindowActions.isCurrent(window.application),
              DockWindowServerMetadata.isCurrent(window) else { throw DockWindowPreviewError.unavailable }
        return result.value
    }

    func perform(_ action: DockWindowAction, on window: DockWindowRecord,
                 screens: [WindowLayoutScreen]) async throws {
        try await actions.perform(action, on: window, screens: screens)
    }

    private static func content() async throws -> DockShareableContent {
        let gate = DockPreviewGate<DockShareableContent>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                    if let content { gate.finish(.success(.init(value: content))) }
                    else { gate.finish(.failure(error ?? DockWindowPreviewError.failed)) }
                }
                gate.timeout(after: 4)
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }
}

private struct DockShareableContent: @unchecked Sendable { let value: SCShareableContent }
private struct DockCapturedImage: @unchecked Sendable { let value: CGImage }

/// Callback APIs can ignore task cancellation; the gate bounds both wait and late result delivery.
private final class DockPreviewGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed: Result<Value, Error>?
    private var timer: DispatchSourceTimer?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = lock.withLock { () -> Result<Value, Error>? in
            if let completed { return completed }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func finish(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>?, DispatchSourceTimer?) in
            guard completed == nil else { return (nil, nil) }
            completed = result
            let pending = (continuation, timer)
            continuation = nil
            timer = nil
            return pending
        }
        pending.1?.cancel()
        pending.0?.resume(with: result)
    }
    func timeout(after seconds: Double) {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + seconds)
        source.setEventHandler { [weak self] in self?.finish(.failure(DockWindowPreviewError.timeout)) }
        source.resume()
        let finished = lock.withLock { () -> Bool in
            guard completed == nil else { return true }
            timer = source
            return false
        }
        if finished { source.cancel() }
    }
}
