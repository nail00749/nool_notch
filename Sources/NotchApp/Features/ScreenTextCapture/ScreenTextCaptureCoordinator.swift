import AppKit
import CoreGraphics

@MainActor
protocol ScreenTextCapturePermissionChecking {
    func isAllowed() -> Bool
    func request() -> Bool
}

private struct SystemScreenTextCapturePermissionChecker: ScreenTextCapturePermissionChecking {
    func isAllowed() -> Bool { CGPreflightScreenCaptureAccess() }
    func request() -> Bool { CGRequestScreenCaptureAccess() }
}

@MainActor
final class ScreenTextCaptureCoordinator {
    private enum Phase { case idle, selecting, capturing }
    private enum CaptureOutcome { case image(Data), failure(String) }

    private struct Callbacks {
        let onCapture: (Data) -> Void
        let onFailure: (String) -> Void
        let onCancel: () -> Void
    }

    private let session: ScreenTextCaptureSession
    private let permissions: any ScreenTextCapturePermissionChecking
    private var permissionRequested = false
    private var panels: [CaptureSelectionPanel] = []
    private let observerBag = ScreenCaptureObserverBag()
    private var callbacks: Callbacks?
    private var phase: Phase = .idle
    private var generation = UUID()

    var isActive: Bool { phase != .idle }

    init(captureService: any ScreenTextCapturing = SystemScreenTextCaptureService(),
         permissions: (any ScreenTextCapturePermissionChecking)? = nil) {
        session = ScreenTextCaptureSession(service: captureService)
        self.permissions = permissions ?? SystemScreenTextCapturePermissionChecker()
    }

    func start(onCapture: @escaping (Data) -> Void,
               onFailure: @escaping (String) -> Void,
               onCancel: @escaping () -> Void) {
        cancel()
        guard permissions.isAllowed() else {
            if !permissionRequested {
                permissionRequested = true
                _ = permissions.request()
            }
            onFailure(ScreenTextCaptureError.permissionDenied.localizedDescription)
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            onFailure(ScreenTextCaptureError.noDisplay.localizedDescription)
            return
        }

        let token = UUID()
        generation = token
        callbacks = Callbacks(onCapture: onCapture, onFailure: onFailure, onCancel: onCancel)
        phase = .selecting
        installLifecycleObservers()
        for screen in screens {
            let panel = CaptureSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let selection = CaptureSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            selection.onSelect = { [weak self] rect in
                self?.selected(rect, on: screen, token: token)
            }
            selection.onCancel = { [weak self] in self?.cancelByUser() }
            panel.contentView = selection
            panel.makeFirstResponder(selection)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lifecycle callers use silent cancellation, so a locked or sleeping Mac does not reopen Launcher.
    func cancel() { end(notifyCancel: false) }

    private func cancelByUser() { end(notifyCancel: true) }

    private func selected(_ localRect: CGRect, on screen: NSScreen, token: UUID) {
        guard phase == .selecting, generation == token else { return }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let request = ScreenTextCaptureGeometry.request(
                displayID: displayID,
                screenFrame: screen.frame,
                selectedScreenRect: localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                backingScale: screen.backingScaleFactor
              ) else {
            finish(.failure(ScreenTextCaptureError.invalidSelection.localizedDescription), token: token)
            return
        }
        closePanels()
        phase = .capturing
        session.capture(request) { [weak self] result in
            guard let self, self.generation == token, self.phase == .capturing else { return }
            switch result {
            case .success(let data): self.finish(.image(data), token: token)
            case .failure(let error):
                let message = (error as? ScreenTextCaptureError)?.localizedDescription
                    ?? ScreenTextCaptureError.captureFailed.localizedDescription
                self.finish(.failure(message), token: token)
            }
        }
    }

    private func finish(_ result: CaptureOutcome, token: UUID) {
        guard generation == token else { return }
        let callbacks = self.callbacks
        end(notifyCancel: false)
        switch result {
        case .image(let image): callbacks?.onCapture(image)
        case .failure(let message): callbacks?.onFailure(message)
        }
    }

    private func end(notifyCancel: Bool) {
        guard phase != .idle else { return }
        generation = UUID()
        phase = .idle
        session.cancel()
        closePanels()
        removeLifecycleObservers()
        let callbacks = self.callbacks
        self.callbacks = nil
        if notifyCancel { callbacks?.onCancel() }
    }

    private func closePanels() {
        let closing = panels
        panels.removeAll()
        for panel in closing { panel.orderOut(nil); panel.close() }
    }

    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancel() }
            }
            observerBag.add(center: workspace, token: token)
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSApplication.willTerminateNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancel() }
            }
            observerBag.add(center: center, token: token)
        }
    }

    private func removeLifecycleObservers() {
        observerBag.removeAll()
    }
}

/// The bag unregisters observers even if its owning coordinator is released during selection.
private final class ScreenCaptureObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func add(center: NotificationCenter, token: NSObjectProtocol) {
        lock.withLock { observers.append((center, token)) }
    }

    func removeAll() {
        let tokens = lock.withLock { () -> [(NotificationCenter, NSObjectProtocol)] in
            let tokens = observers
            observers.removeAll()
            return tokens
        }
        for (center, token) in tokens { center.removeObserver(token) }
    }

    deinit { removeAll() }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var dragStart: CGPoint?
    private var selectedRect: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = convert(event.locationInWindow, from: nil)
        selectedRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selectedRect = ScreenTextCaptureGeometry.selection(from: dragStart,
                                                            to: convert(event.locationInWindow, from: nil), in: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        let rect = ScreenTextCaptureGeometry.selection(from: dragStart,
                                                       to: convert(event.locationInWindow, from: nil), in: bounds)
        self.dragStart = nil
        if rect.width >= ScreenTextCaptureGeometry.minimumSelectionPoints,
           rect.height >= ScreenTextCaptureGeometry.minimumSelectionPoints {
            onSelect?(rect)
        } else {
            selectedRect = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.fill(bounds)
        if let selectedRect {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(selectedRect)
            context.restoreGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.stroke(selectedRect.insetBy(dx: 1, dy: 1))
        }
        let hint = "Выделите область для распознавания · Esc — отмена"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        let textRect = CGRect(x: max(12, (bounds.width - size.width) / 2),
                              y: max(12, bounds.height - 58), width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: textRect.insetBy(dx: -12, dy: -8), xRadius: 10, yRadius: 10).fill()
        (hint as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
