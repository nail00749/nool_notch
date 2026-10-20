import AppKit
import SwiftUI

/// Screen frames of Dock cells, for surfaces that live in their own window (the fan).
@MainActor
final class DockAnchorRegistry {
    private var views: [String: WeakView] = [:]

    private struct WeakView { weak var view: NSView? }

    func register(_ id: String, view: NSView) {
        views[id] = WeakView(view: view)
        if views.count > 64 { views = views.filter { $0.value.view != nil } }
    }

    func screenRect(_ id: String) -> CGRect? {
        guard let view = views[id]?.view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct DockAnchorView: NSViewRepresentable {
    let id: String
    let registry: DockAnchorRegistry

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registry.register(id, view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { registry.register(id, view: nsView) }
}

/// Geometry of the system Dock fan: rows rise on a large arc that bends away from the
/// stack icon, each row tilted along the arc with its label on the left of the icon.
struct DockFanLayout: Equatable {
    static let iconSize: CGFloat = 48
    static let rowHeight: CGFloat = 54
    static let rowWidth: CGFloat = 330
    static let radius: CGFloat = 1_500
    static let maxRows = 10

    /// Files plus the "Открыть в Finder" row on top.
    let rows: Int

    var step: CGFloat { (Self.rowHeight + 4) / Self.radius }
    func angle(_ row: Int) -> CGFloat { (CGFloat(row) + 0.5) * step }
    /// Icon column at the stack icon, in view coordinates (y grows downwards).
    var origin: CGPoint {
        CGPoint(x: Self.rowWidth - Self.iconSize / 2 + 10, y: size.height - 6)
    }
    var maxShift: CGFloat { Self.radius * (1 - cos(angle(rows - 1))) }
    var size: CGSize {
        CGSize(width: Self.rowWidth + 10 + maxShift + 24,
               height: Self.radius * sin(angle(rows - 1) + step / 2) + Self.rowHeight / 2 + 12)
    }

    func iconCenter(_ row: Int) -> CGPoint {
        let theta = angle(row)
        return CGPoint(x: origin.x + Self.radius * (1 - cos(theta)), y: origin.y - Self.radius * sin(theta))
    }

    /// Bottom-left of the fan window so the first icon sits right above the stack cell.
    func windowFrame(anchor: CGRect, dockTop: CGFloat, screen: CGRect) -> CGRect {
        var frame = CGRect(x: anchor.midX - origin.x, y: dockTop + 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.size.height = min(frame.height, max(Self.rowHeight * 2, screen.maxY - frame.minY))
        return frame
    }
}

private final class DockFanPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the fan in a transparent click-through-where-empty window above the Dock.
@MainActor
final class DockFanPresenter {
    private(set) var presentedID: String?
    private var panel: DockFanPanel?
    private var interactionChanged: ((Bool) -> Void)?

    var window: NSWindow? { panel?.isVisible == true ? panel : nil }

    func present(element: DockElement, files: [DockStackFile], provider: DockFileStackProvider,
                 anchor: CGRect, dockTop: CGFloat, screen: CGRect,
                 interactionChanged: @escaping (Bool) -> Void) {
        dismiss()
        let shown = Array(files.prefix(DockFanLayout.maxRows))
        let layout = DockFanLayout(rows: shown.count + 1)
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: DockFanView(
            element: element, files: shown, provider: provider, layout: layout,
            dismiss: { [weak self] in self?.dismiss() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(layout.windowFrame(anchor: anchor, dockTop: dockTop, screen: screen), display: true)
        panel.orderFrontRegardless()
        presentedID = element.id
        self.interactionChanged = interactionChanged
        interactionChanged(true)
    }

    func dismiss() {
        guard presentedID != nil || panel?.isVisible == true else { return }
        presentedID = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        let callback = interactionChanged
        interactionChanged = nil
        callback?(false)
    }

    private static func makePanel() -> DockFanPanel {
        let panel = DockFanPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = "Стопка NooL Dock"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

struct DockFanView: View {
    let element: DockElement
    let files: [DockStackFile]
    let provider: DockFileStackProvider
    let layout: DockFanLayout
    let dismiss: () -> Void
    @StateObject private var thumbnails = DockThumbnailLoader()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                positioned(row: index) {
                    rowContent(title: file.title, highlighted: hovered == file.id) {
                        Image(nsImage: thumbnails.image(for: file.url) ?? provider.icon(for: file))
                            .resizable().scaledToFit()
                    }
                    .dockTapTarget(file.title, fillsFrame: false) {
                        provider.open(file)
                        dismiss()
                    }
                    .onHover { hovered = $0 ? file.id : (hovered == file.id ? nil : hovered) }
                    .modifier(DockStackFileActions(provider: provider, file: file, onDragEnd: dismiss))
                }
            }
            positioned(row: files.count) {
                Button {
                    if let path = element.directoryPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    dismiss()
                } label: {
                    rowContent(title: "Открыть в Finder", highlighted: hovered == "finder") {
                        Image(systemName: "arrow.up.forward.circle.fill").resizable().scaledToFit()
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.white).padding(7)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }.buttonStyle(.plain)
                    .onHover { hovered = $0 ? "finder" : (hovered == "finder" ? nil : hovered) }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .task {
            if reduceMotion { appeared = true } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
            }
            for file in files { await thumbnails.load(file.url, size: CGSize(width: 96, height: 96)) }
        }
    }

    /// Positions a row so its icon center lies on the arc, then tilts it around that icon.
    private func positioned<Content: View>(row: Int, @ViewBuilder _ content: () -> Content) -> some View {
        let point = layout.iconCenter(row)
        let width = DockFanLayout.rowWidth
        let iconX = width - DockFanLayout.iconSize / 2
        // Rows grow out of the stack icon when the fan opens.
        let start = CGPoint(x: layout.origin.x, y: layout.origin.y)
        let target = appeared ? point : start
        return content()
            .frame(width: width, height: DockFanLayout.rowHeight, alignment: .trailing)
            .rotationEffect(.radians(-Double(appeared ? layout.angle(row) : 0)),
                            anchor: UnitPoint(x: iconX / width, y: 0.5))
            .opacity(appeared ? 1 : 0)
            .position(x: target.x - iconX + width / 2, y: target.y)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)
                .delay(Double(row) * 0.012), value: appeared)
    }

    private func rowContent<Icon: View>(title: String, highlighted: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(highlighted ? Color.accentColor : Color.black.opacity(0.62), in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(maxWidth: DockFanLayout.rowWidth - DockFanLayout.iconSize - 18, alignment: .trailing)
            icon()
                .frame(width: DockFanLayout.iconSize, height: DockFanLayout.iconSize)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .scaleEffect(highlighted ? 1.06 : 1)
        }
    }
}
