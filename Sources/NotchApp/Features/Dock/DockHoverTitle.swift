import AppKit
import SwiftUI

/// A non-interactive title bubble. Unlike a popover it never captures the mouse,
/// takes focus, or competes with the window preview that follows it.
struct DockHoverTitle: ViewModifier {
    let title: String
    let position: DockPosition
    let enabled: Bool
    let generation: Int
    @StateObject private var presenter = DockHoverTitlePresenter()
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(DockTitleAnchor(presenter: presenter))
            .onHover { hovered = $0 }
            .task(id: hovered && enabled) {
                presenter.hide()
                guard hovered && enabled else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, NSEvent.pressedMouseButtons == 0 else { return }
                presenter.show(title: title, position: position)
            }
            .onChange(of: generation) { _, _ in
                hovered = false
                presenter.hide()
            }
            .onChange(of: position) { _, _ in
                hovered = false
                presenter.hide()
            }
            .onDisappear { presenter.hide() }
    }
}

@MainActor
final class DockHoverTitlePresenter: ObservableObject {
    weak var anchor: NSView?
    private(set) var panel: NSPanel?
    private var monitors: [Any] = []

    static func frame(size: CGSize, anchor: CGRect, screen: CGRect, position: DockPosition) -> CGRect {
        var origin: CGPoint
        switch position {
        case .bottom: origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        case .left: origin = CGPoint(x: anchor.maxX + 8, y: anchor.midY - size.height / 2)
        case .right: origin = CGPoint(x: anchor.minX - size.width - 8, y: anchor.midY - size.height / 2)
        }
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - size.width - 4))
        origin.y = max(screen.minY + 4, min(origin.y, screen.maxY - size.height - 4))
        return CGRect(origin: origin, size: size)
    }

    func show(title: String, position: DockPosition) {
        hide()
        guard !title.isEmpty, let anchor, let parent = anchor.window, parent.isVisible,
              let screen = parent.screen else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.lineBreakMode = .byCharWrapping
        // Truncating NSTextField cells report a compressed intrinsic width. Measure
        // the full string instead, and wrap long names within the display bounds.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.alignment = .center
        label.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: label.font!, .paragraphStyle: paragraph, .foregroundColor: NSColor.white
        ])
        label.attributedStringValue = text
        let maxTextWidth = max(1, min(420, screen.visibleFrame.width - 32) - 24)
        let bounds = text.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: min(maxTextWidth + 12, ceil(bounds.width) + 12) + 24,
                          height: max(16, ceil(bounds.height) + 6) + 16)
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bubble = NSPanel(contentRect: Self.frame(size: size, anchor: rect, screen: screen.visibleFrame,
                                                    position: position),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.backgroundColor = .clear
        bubble.isOpaque = false
        bubble.hasShadow = true
        bubble.isReleasedWhenClosed = false
        bubble.ignoresMouseEvents = true
        bubble.level = .popUpMenu
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        label.frame = CGRect(x: 12, y: 8, width: size.width - 24, height: size.height - 16)
        background.addSubview(label)
        bubble.contentView = background
        panel = bubble
        parent.addChildWindow(bubble, ordered: .above)
        bubble.orderFrontRegardless()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.hide()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }) { monitors.append(monitor) }
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }
}

private struct DockTitleAnchor: NSViewRepresentable {
    let presenter: DockHoverTitlePresenter
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        presenter.anchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
