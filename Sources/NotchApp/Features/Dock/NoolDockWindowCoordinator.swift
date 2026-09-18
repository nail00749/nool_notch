import AppKit
import Combine
import SwiftUI

enum NoolDockLayout {
    static let contentHeight: CGFloat = 88
    static let controlsWidth: CGFloat = 44

    static func frame(visibleFrame: NSRect, contentWidth: CGFloat, scale: Double) -> NSRect {
        let scale = CGFloat(scale.isFinite ? min(1.2, max(0.8, scale)) : 1)
        let width = min(max(1, visibleFrame.width - 24), max(180, contentWidth * scale))
        let height = min(contentHeight * scale, max(1, visibleFrame.height - 24))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 12,
                      width: width, height: height)
    }

    static func triggerFrame(dockFrame: NSRect) -> NSRect {
        NSRect(x: dockFrame.midX - 48, y: dockFrame.minY, width: 96, height: 18)
    }

    static func canAutoHide(hovered: Bool, interacting: Bool, mouseButtons: Int) -> Bool {
        !hovered && !interacting && mouseButtons == 0
    }
}

@MainActor
private final class NoolDockPresentation: ObservableObject {
    @Published var logicalWidth: CGFloat = 1_080
}

private final class NoolDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns only the Dock's two windows. The notch and system Dock keep their own geometry.
@MainActor
final class NoolDockWindowCoordinator {
    let settings: NoolDockSettings
    private let model: NotchViewModel
    private let panel: NSPanel
    private let trigger: NSPanel
    private let presentation = NoolDockPresentation()
    private var screenTimer: Timer?
    private var keyMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var hideTask: Task<Void, Never>?
    private var started = false
    private var revealed = false
    private var hovered = false
    private var interacting = false
    private var targetFrame: NSRect?

    init(settings: NoolDockSettings, model: NotchViewModel,
         openSettings: @escaping () -> Void, openLauncher: @escaping () -> Void) {
        self.settings = settings
        self.model = model
        panel = NoolDockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        trigger = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        configure(panel, title: "Nool Dock")
        configure(trigger, title: "Показать Nool Dock")
        let hosting = NSHostingView(rootView: NoolDockContainer(
            settings: settings, model: model, presentation: presentation,
            openSettings: openSettings, openLauncher: openLauncher,
            openApplication: { [weak self] in self?.openApplication($0) },
            interactionChanged: { [weak self] in self?.setInteracting($0) },
            hoverChanged: { [weak self] in self?.setHovered($0) }
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        let handle = NSHostingView(rootView: NoolDockHandle(
            reveal: { [weak self] in self?.reveal() },
            hoverChanged: { [weak self] in self?.setTriggerHovered($0) }
        ))
        handle.sizingOptions = []
        trigger.contentView = handle
        settings.onChange = { [weak self] in self?.synchronize() }
    }

    func start() {
        guard !started else { return }
        started = true
        synchronize()
    }

    func stop() {
        started = false
        hideTask?.cancel()
        screenTimer?.invalidate()
        screenTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        removeMenuObservers()
        panel.orderOut(nil)
        trigger.orderOut(nil)
        model.setDockWidgets(musicVisible: false, calendarEnabled: false)
    }

    func reposition() {
        guard started, settings.isEnabled else { return }
        synchronize()
    }

    private func configure(_ window: NSPanel, title: String) {
        window.title = title
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovable = false
    }

    private func synchronize() {
        guard started else { return }
        guard settings.isEnabled else {
            hideTask?.cancel()
            screenTimer?.invalidate()
            screenTimer = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            removeMenuObservers()
            panel.orderOut(nil)
            trigger.orderOut(nil)
            revealed = false
            hovered = false
            interacting = false
            model.setDockWidgets(musicVisible: false, calendarEnabled: false)
            return
        }
        installTrackingIfNeeded()
        guard let screen = selectedScreen() else {
            panel.orderOut(nil)
            trigger.orderOut(nil)
            return
        }
        let width = settings.items.reduce(NoolDockLayout.controlsWidth + 16) { $0 + $1.baseWidth + 6 }
        let frame = NoolDockLayout.frame(visibleFrame: screen.visibleFrame, contentWidth: width, scale: settings.scale)
        if targetFrame != frame {
            targetFrame = frame
            presentation.logicalWidth = frame.width / settings.scale
            panel.setFrame(frame, display: true)
            trigger.setFrame(NoolDockLayout.triggerFrame(dockFrame: frame), display: true)
        }
        let showingContent = !settings.autoHide || revealed || interacting
        if showingContent {
            trigger.orderOut(nil)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
            if !trigger.isVisible { trigger.orderFrontRegardless() }
        }
        model.setDockWidgets(
            musicVisible: showingContent && settings.items.contains { $0.kind == .music },
            calendarEnabled: settings.items.contains { $0.kind == .calendar }
        )
        if settings.autoHide && showingContent { scheduleHide() }
    }

    private func selectedScreen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == settings.displayID
        } ?? NSScreen.screens.first
    }

    private func installTrackingIfNeeded() {
        if menuObservers.isEmpty {
            menuObservers.append(NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    guard let self,
                          self.panel.isVisible,
                          !self.trackingMenus.isEmpty || self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.trackingMenus.insert(menuID)
                    self.hideTask?.cancel()
                }
            })
            menuObservers.append(NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackingMenus.remove(menuID)
                    self.scheduleHide()
                }
            })
        }
        if screenTimer == nil {
            // visibleFrame can change when the system Dock moves or resizes.
            screenTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reposition() }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = event.window, self.owns(window),
                          let editor = window.firstResponder as? NSTextView,
                          let action = TextEditingAction(event: event) else { return event }
                    action.perform(in: editor)
                    return nil
            }
        }
    }

    private func owns(_ window: NSWindow) -> Bool {
        var candidate: NSWindow? = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent
        }
        return false
    }

    private func removeMenuObservers() {
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.removeAll()
        trackingMenus.removeAll()
    }

    private func setTriggerHovered(_ value: Bool) {
        if value { reveal() }
        else { scheduleHide() }
    }

    private func reveal() {
        hideTask?.cancel()
        revealed = true
        synchronize()
    }

    private func setHovered(_ value: Bool) {
        hovered = value
        if value { hideTask?.cancel() }
        else { scheduleHide() }
    }

    private func setInteracting(_ value: Bool) {
        interacting = value
        if value { hideTask?.cancel() }
        synchronize()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard settings.autoHide, revealed,
              NoolDockLayout.canAutoHide(hovered: hovered, interacting: interacting || !trackingMenus.isEmpty,
                                         mouseButtons: 0) else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            guard NoolDockLayout.canAutoHide(hovered: self.hovered, interacting: self.interacting || !self.trackingMenus.isEmpty,
                                            mouseButtons: NSEvent.pressedMouseButtons) else {
                self.scheduleHide()
                return
            }
            self.revealed = false
            self.synchronize()
        }
    }

    private func openApplication(_ item: NoolDockItem) {
        guard item.kind == .app, settings.items.contains(item), let path = item.applicationPath else { return }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "app", Bundle(url: url) != nil else {
            showApplicationError(item.title)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.showApplicationError(item.title) }
        }
    }

    private func showApplicationError(_ title: String) {
        guard started, settings.isEnabled else { return }
        setInteracting(true)
        let alert = NSAlert()
        alert.messageText = "Не удалось открыть \(title)"
        alert.informativeText = "Возможно, приложение перемещено или удалено. Добавьте его заново в настройках Nool Dock."
        alert.beginSheetModal(for: panel) { [weak self] _ in
            self?.setInteracting(false)
        }
    }
}

private struct NoolDockContainer: View {
    @ObservedObject var settings: NoolDockSettings
    @ObservedObject var model: NotchViewModel
    @ObservedObject var presentation: NoolDockPresentation
    let openSettings: () -> Void
    let openLauncher: () -> Void
    let openApplication: (NoolDockItem) -> Void
    let interactionChanged: (Bool) -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        NoolDockView(settings: settings, model: model, openSettings: openSettings, openLauncher: openLauncher,
                     openApplication: openApplication, interactionChanged: interactionChanged)
            .frame(width: presentation.logicalWidth, height: NoolDockLayout.contentHeight)
            .scaleEffect(settings.scale)
            .frame(width: presentation.logicalWidth * settings.scale, height: NoolDockLayout.contentHeight * settings.scale)
            .onHover(perform: hoverChanged)
            .preferredColorScheme(.dark)
    }
}

private struct NoolDockHandle: View {
    let reveal: () -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        Button(action: reveal) {
            Capsule().fill(NotchPalette.accent.opacity(0.75)).frame(width: 48, height: 4)
                .frame(width: 96, height: 18)
                .background(NotchPalette.surface.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(NotchPalette.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Показать Nool Dock")
        .onHover(perform: hoverChanged)
    }
}
