import AppKit
import SwiftUI
#if DEBUG
import OSLog
private let dockPopoverAnchorLogger = Logger(subsystem: "com.nool.dock", category: "popover-anchor")
#endif

extension View {
    /// Attach to the Dock cell/widget bounds. AppKit converts any outer scale
    /// or transform and retains this anchor as SwiftUI content changes size.
    func dockPopover<Popup: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                                 @ViewBuilder content: () -> Popup) -> some View {
        background {
            DockPopoverPresenter(isPresented: isPresented, arrowEdge: arrowEdge, content: content())
        }
    }
}

struct DockPopoverPresenter<Popup: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: Popup

    func makeNSView(context: Context) -> DockPopoverAnchorView {
        let view = DockPopoverAnchorView()
        view.changed = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.anchorChanged(view)
        }
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func updateNSView(_ view: DockPopoverAnchorView, context: Context) {
        context.coordinator.update(anchor: view, isPresented: $isPresented,
                                   arrowEdge: arrowEdge, content: content)
    }

    static func dismantleNSView(_ view: DockPopoverAnchorView, coordinator: Coordinator) {
        view.changed = nil
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private let popover = NSPopover()
        private let host: DockPopoverHostingController<DockPopoverRoot<Popup>>
        private weak var anchor: DockPopoverAnchorView?
        private var presentation: Binding<Bool>?
        private var edge: Edge = .top
        private var requested = false
        private var epoch = 0
        private var pendingDismissal: Int?
        private var refreshScheduled = false
        private var refreshing = false
        private var refreshAfterLayout = false
        private var stopped = false
        private var hasJoinedWindow = false
        private var lastSize: NSSize?
        private var lastScreenRect: NSRect?
        private var lastEdge: Edge?

        init(content: Popup) {
            host = DockPopoverHostingController(rootView: DockPopoverRoot(content: nil))
            super.init()
            host.sizingOptions = [.preferredContentSize]
            host.sizeChanged = { [weak self] in self?.scheduleRefresh() }
            popover.contentViewController = host
            popover.behavior = .transient
            popover.animates = false
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = self
        }

        func update(anchor: DockPopoverAnchorView, isPresented: Binding<Bool>, arrowEdge: Edge, content: Popup) {
            self.anchor = anchor
            presentation = isPresented
            edge = arrowEdge
            let nextRequested = isPresented.wrappedValue
            if nextRequested != requested {
                epoch += 1
                pendingDismissal = nil
            }
            requested = nextRequested
            if requested {
                // A telemetry update can arrive before AppKit's close has
                // propagated to the binding. Keep that hidden subtree gone.
                if pendingDismissal == nil {
                    host.rootView = DockPopoverRoot(content: content)
                    scheduleRefresh()
                }
            }
            else {
                lastSize = nil; lastScreenRect = nil; lastEdge = nil
                popover.animates = false
                popover.close()
                clearContent()
            }
        }

        func anchorChanged(_ view: DockPopoverAnchorView) {
            guard !stopped else { return }
            if let window = view.window {
                hasJoinedWindow = true
                if popover.isShown && (!window.isVisible || view.isHiddenOrHasHiddenAncestor) { dismiss() }
            }
            else if hasJoinedWindow && requested { dismiss() }
            scheduleRefresh()
        }

        private func scheduleRefresh() {
            guard !stopped, requested, pendingDismissal == nil else { return }
            if refreshing { refreshAfterLayout = true; return }
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }

        private func refresh() {
            guard !stopped, requested, pendingDismissal == nil,
                  presentation?.wrappedValue == true, let anchor, let window = anchor.window else { return }
            hasJoinedWindow = true
            guard window.isVisible, !anchor.isHiddenOrHasHiddenAncestor else {
                if popover.isShown { dismiss() }
                return
            }
            guard anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }
            refreshing = true
            defer {
                refreshing = false
                if refreshAfterLayout { refreshAfterLayout = false; scheduleRefresh() }
            }
            host.view.layoutSubtreeIfNeeded()
            let preferred = host.preferredContentSize
            let fitting = host.view.fittingSize
            let size = Self.valid(preferred) ? preferred : fitting
            guard Self.valid(size) else { return }
            let screenRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            guard !popover.isShown || size != lastSize || screenRect != lastScreenRect || edge != lastEdge else { return }
            lastSize = size; lastScreenRect = screenRect; lastEdge = edge
            if popover.contentSize != size { popover.contentSize = size }
            let nativeEdge: NSRectEdge = switch edge {
            case .top: .maxY
            case .bottom: .minY
            case .leading: .minX
            case .trailing: .maxX
            }
            // Re-showing an open NSPopover updates its positioning view/rect.
            // Resizing content alone can retain the old bottom edge and grow
            // down into the Dock, notably in a one-cell widget's narrow anchor.
            // Animate only the initial presentation. Re-anchoring live content
            // must remain immediate, including during the opening transition.
            popover.animates = !popover.isShown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: nativeEdge)
            popover.animates = false
            #if DEBUG
            dockPopoverAnchorLogger.debug("edge=\(String(describing: self.edge), privacy: .public) source=\(String(describing: screenRect), privacy: .public) popup=\(String(describing: self.host.view.window?.frame), privacy: .public) content=\(String(describing: size), privacy: .public)")
            #endif
        }

        private static func valid(_ size: NSSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }

        private func dismiss() {
            guard requested else { return }
            popover.close()
            publishDismissal()
        }

        private func publishDismissal() {
            let current = epoch
            pendingDismissal = current
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.epoch == current,
                      self.pendingDismissal == current, !self.popover.isShown else { return }
                if self.presentation?.wrappedValue == true { self.presentation?.wrappedValue = false }
            }
        }

        func stop() {
            stopped = true
            epoch += 1
            host.sizeChanged = nil
            presentation = nil
            anchor = nil
            popover.close()
            clearContent()
        }

        func popoverDidClose(_ notification: Notification) {
            guard !stopped, requested else { return }
            clearContent()
            publishDismissal()
        }

        private func clearContent() {
            // NSPopover retains its content controller when it closes. Remove
            // the SwiftUI subtree explicitly so onDisappear releases telemetry,
            // transient-surface tracking and pending drafts while it is hidden.
            host.rootView = DockPopoverRoot(content: nil)
            host.view.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
final class DockPopoverAnchorView: NSView {
    var changed: (() -> Void)?
    private var windowVisibility: NSKeyValueObservation?
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("dock-popover-anchor")
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); changed?() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        windowVisibility = nil
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            windowVisibility = window.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed?() }
            }
        }
        changed?()
    }
    override func viewDidHide() { super.viewDidHide(); changed?() }
    override func viewDidUnhide() { super.viewDidUnhide(); changed?() }
}

@MainActor
private final class DockPopoverHostingController<Content: View>: NSHostingController<Content> {
    var sizeChanged: (() -> Void)?
    override var preferredContentSize: NSSize {
        didSet { if preferredContentSize != oldValue { sizeChanged?() } }
    }
    override func viewDidLayout() { super.viewDidLayout(); sizeChanged?() }
}

private struct DockPopoverRoot<Content: View>: View {
    let content: Content?
    var body: some View {
        if let content { content }
    }
}
