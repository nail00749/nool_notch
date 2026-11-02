import AppKit
import Combine
import NoolCoolingCore
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockPopoverTests: XCTestCase {
    func testNativePopoverKeepsScaledCellEdgeWhenContentGrowsAndShrinks() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        for edge in [Edge.top, .bottom, .leading, .trailing] {
            for span in 1...3 {
                for scale in [0.8, 1.0, 1.2] {
                    let presentation = PopoverPresentation()
                    let state = PopoverContentState()
                    let frame = panelFrame(screen.visibleFrame, edge: edge)
                    let panel = makePanel(frame)
                    let host = NSHostingView(rootView:
                        PopoverCell(presentation: presentation, state: state, span: span, scale: scale, edge: edge)
                            .frame(width: frame.width, height: frame.height))
                    host.sizingOptions = []
                    panel.contentView = host
                    panel.orderFrontRegardless()
                    host.layoutSubtreeIfNeeded()
                    pump(0.03)
                    let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
                    presentation.shown = true
                    let popup = try waitForPopover(excluding: before)
                    let anchor = try XCTUnwrap(findAnchor(host))
                    let source = panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                    XCTAssertEqual(source.width, DockLayout.width(span: span, scale: scale), accuracy: 1)
                    assertEdge(popup.frame, source: source, edge: edge)
                    let smallHeight = popup.frame.height
                    var editingResponder: NSResponder?
                    if edge == .top, span == 1, scale == 1 {
                        let field = try XCTUnwrap(findTextField(popup.contentView))
                        popup.makeKeyAndOrderFront(nil)
                        XCTAssertTrue(popup.makeFirstResponder(field))
                        editingResponder = popup.firstResponder
                    }

                    // Only the popover's child observes this object. The outer
                    // representable receives no telemetry or binding update.
                    state.height = 420
                    waitUntil { popup.frame.height > smallHeight + 150 }
                    XCTAssertGreaterThan(popup.frame.height, smallHeight + 150)
                    assertEdge(popup.frame, source: source, edge: edge)
                    XCTAssertEqual(panel.frame, frame)
                    XCTAssertEqual(state.appearances, 1, "Resize must not rebuild or close content")
                    if let editingResponder { XCTAssertTrue(popup.firstResponder === editingResponder) }

                    state.height = 160
                    waitUntil { popup.frame.height < smallHeight + 10 }
                    assertEdge(popup.frame, source: source, edge: edge)
                    XCTAssertEqual(panel.frame, frame)
                    XCTAssertEqual(state.appearances, 1)
                    presentation.shown = false
                    waitUntil { !popup.isVisible }
                    XCTAssertFalse(popup.isVisible)
                    waitUntil { state.disappearances == 1 }
                    XCTAssertEqual(state.disappearances, 1)
                    panel.contentView = nil
                    panel.close()
                }
            }
        }
    }

    func testOneCellCoolingManualContentStartsAboveDockAndPreservesSize() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let presentation = PopoverPresentation()
        let snapshot = CoolingSnapshot(fans: [
            .init(id: 0, name: "Левый", currentRPM: 5451, minimumRPM: 2317, maximumRPM: 6800,
                  targetRPM: 5455, mode: .manual, controlSupported: true),
            .init(id: 1, name: "Правый", currentRPM: 5445, minimumRPM: 2317, maximumRPM: 6800,
                  targetRPM: 5455, mode: .manual, controlSupported: true)
        ], sensors: [.init(id: "Tf0E", name: "CPU — зона Tf0E", celsius: 59.5)], controlAvailable: true)
        let store = CoolingStore(previewSnapshot: snapshot)
        let frame = panelFrame(screen.visibleFrame, edge: .top)
        let panel = makePanel(frame)
        let host = NSHostingView(rootView:
            CoolingPopoverCell(presentation: presentation, store: store)
                .frame(width: frame.width, height: frame.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        pump(0.03)
        let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        presentation.shown = true
        let popup = try waitForPopover(excluding: before)
        defer { presentation.shown = false; pump(0.04); panel.contentView = nil; panel.close() }
        pump(0.15)
        let anchor = try XCTUnwrap(findAnchor(host))
        let source = panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        XCTAssertEqual(source.width, DockLayout.width(span: 1, scale: 1), accuracy: 1)
        XCTAssertGreaterThan(popup.frame.height, 400, "Manual slider must be expanded, matching the reported UI")
        assertEdge(popup.frame, source: source, edge: .top)
        XCTAssertEqual(panel.frame, frame)
    }

    func testActualScreenEdgesKeepPopoverOnScreenIncludingFallbackSides() throws {
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let side = DockLayout.baseHeight
        let bottom = NSRect(x: visible.midX - side / 2, y: visible.minY + 8, width: side, height: side)
        let top = NSRect(x: visible.midX - side / 2, y: visible.maxY - side - 8, width: side, height: side)
        let left = NSRect(x: visible.minX + 8, y: visible.midY - side / 2, width: side, height: side)
        let right = NSRect(x: visible.maxX - side - 8, y: visible.midY - side / 2, width: side, height: side)
        for (edge, frame, expected) in [(Edge.top, bottom, Edge.top), (.bottom, top, .bottom),
                                        (.top, top, .bottom), (.bottom, bottom, .top),
                                        (.leading, left, .trailing), (.trailing, right, .leading)] {
            let presentation = PopoverPresentation()
            let state = PopoverContentState()
            let panel = makePanel(frame)
            let host = NSHostingView(rootView: PopoverCell(presentation: presentation, state: state, span: 1, scale: 1, edge: edge))
            host.frame.size = frame.size; host.sizingOptions = []
            panel.contentView = host; panel.orderFrontRegardless(); host.layoutSubtreeIfNeeded(); pump(0.03)
            let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            presentation.shown = true
            let popup = try waitForPopover(excluding: before)
            state.height = 420
            waitUntil { popup.frame.height > 400 }
            let anchor = try XCTUnwrap(findAnchor(host))
            let source = panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            assertEdge(popup.frame, source: source, edge: expected)
            XCTAssertTrue(visible.insetBy(dx: -2, dy: -2).contains(popup.frame))
            XCTAssertEqual(panel.frame, frame)
            presentation.shown = false; pump(0.03)
            panel.contentView = nil; panel.close()
        }
    }

    func testNativeCloseUpdatesBindingAndReopenIsNotDismissedByOldCallback() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let presentation = PopoverPresentation()
        let state = PopoverContentState()
        let frame = panelFrame(screen.visibleFrame, edge: .top)
        let panel = makePanel(frame)
        let host = NSHostingView(rootView: PopoverCell(presentation: presentation, state: state, span: 1, scale: 1, edge: .top))
        host.frame.size = frame.size; host.sizingOptions = []
        panel.contentView = host; panel.orderFrontRegardless(); host.layoutSubtreeIfNeeded(); pump(0.03)
        let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        presentation.shown = true
        let popup = try waitForPopover(excluding: before)
        popup.performClose(nil)
        waitUntil { !presentation.shown }
        XCTAssertFalse(presentation.shown)
        presentation.shown = true
        waitUntil { popup.isVisible }
        XCTAssertTrue(presentation.shown)
        XCTAssertTrue(popup.isVisible)
        presentation.shown = false
        pump(0.04)
        panel.contentView = nil; panel.close()
    }

    func testHidingSourceWindowDismissesPopoverAndUpdatesBinding() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let presentation = PopoverPresentation()
        let frame = panelFrame(screen.visibleFrame, edge: .top)
        let panel = makePanel(frame)
        let host = NSHostingView(rootView: PopoverCell(presentation: presentation, state: PopoverContentState(), span: 1, scale: 1, edge: .top))
        host.frame.size = frame.size; host.sizingOptions = []
        panel.contentView = host; panel.orderFrontRegardless(); host.layoutSubtreeIfNeeded(); pump(0.03)
        let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        presentation.shown = true
        let popup = try waitForPopover(excluding: before)
        panel.orderOut(nil)
        waitUntil { !popup.isVisible && !presentation.shown }
        XCTAssertFalse(popup.isVisible)
        XCTAssertFalse(presentation.shown)
        panel.contentView = nil; panel.close()
    }

    private func makePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func panelFrame(_ visible: NSRect, edge: Edge) -> NSRect {
        let center: NSPoint = switch edge {
        case .top: .init(x: visible.midX, y: visible.minY + 140)
        case .bottom: .init(x: visible.midX, y: visible.maxY - 140)
        case .leading: .init(x: visible.maxX - 250, y: visible.midY)
        case .trailing: .init(x: visible.minX + 250, y: visible.midY)
        }
        return .init(x: center.x - 240, y: center.y - 70, width: 480, height: 140)
    }

    private func assertEdge(_ popup: NSRect, source: NSRect, edge: Edge, file: StaticString = #filePath, line: UInt = #line) {
        switch edge {
        case .top:
            XCTAssertGreaterThanOrEqual(popup.minY, source.maxY - 2, file: file, line: line)
            XCTAssertEqual(popup.midX, source.midX, accuracy: 4, file: file, line: line)
        case .bottom:
            XCTAssertLessThanOrEqual(popup.maxY, source.minY + 2, file: file, line: line)
            XCTAssertEqual(popup.midX, source.midX, accuracy: 4, file: file, line: line)
        // AppKit's side-arrow tip/window border can overlap the source by a
        // few points. Vertical Dock separation remains exact above/below.
        case .leading: XCTAssertLessThanOrEqual(popup.maxX, source.minX + 8, file: file, line: line)
        case .trailing: XCTAssertGreaterThanOrEqual(popup.minX, source.maxX - 8, file: file, line: line)
        }
    }

    private func findAnchor(_ view: NSView) -> NSView? {
        if view.identifier?.rawValue == "dock-popover-anchor" { return view }
        return view.subviews.lazy.compactMap { self.findAnchor($0) }.first
    }
    private func findTextField(_ view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findTextField($0) }.first
    }
    private func waitForPopover(excluding old: Set<Int>) throws -> NSWindow {
        var popup: NSWindow?
        waitUntil { popup = NSApp.windows.first { $0.isVisible && !old.contains($0.windowNumber) }; return popup != nil }
        return try XCTUnwrap(popup, "Expected the actual NSPopover window")
    }
    private func waitUntil(_ condition: () -> Bool) {
        let end = Date().addingTimeInterval(1)
        while !condition(), Date() < end { pump(0.01) }
    }
    private func pump(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}

@MainActor
private final class PopoverPresentation: ObservableObject { @Published var shown = false }
@MainActor
private final class PopoverContentState: ObservableObject {
    @Published var height: CGFloat = 160
    var appearances = 0
    var disappearances = 0
}
private struct PopoverCell: View {
    @ObservedObject var presentation: PopoverPresentation
    let state: PopoverContentState
    let span: Int
    let scale: CGFloat
    let edge: Edge
    var body: some View {
        Color.clear.frame(width: DockLayout.width(span: span, scale: 1), height: DockLayout.baseHeight)
            .dockPopover(isPresented: $presentation.shown, arrowEdge: edge) { ResizablePopover(state: state) }
            .scaleEffect(scale)
            .frame(width: DockLayout.width(span: span, scale: scale), height: DockLayout.baseHeight * scale)
    }
}
private struct ResizablePopover: View {
    @ObservedObject var state: PopoverContentState
    @State private var retainedText = "Local editor draft"
    var body: some View {
        VStack { TextField("Draft", text: $retainedText); Spacer() }
            .padding(12).frame(width: 260, height: state.height)
            .onAppear { state.appearances += 1 }
            .onDisappear { state.disappearances += 1 }
    }
}
private struct CoolingPopoverCell: View {
    @ObservedObject var presentation: PopoverPresentation
    let store: CoolingStore
    var body: some View {
        Color.clear.frame(width: DockLayout.width(span: 1, scale: 1), height: DockLayout.baseHeight)
            .dockPopover(isPresented: $presentation.shown) { DockCoolingDetails(store: store, openFullPanel: {}) }
    }
}
