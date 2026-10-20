import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockPopoverAnchorTests: XCTestCase {
    func testActualPreviewKeepsAnchorDuringLoadingImagesAndEmptyResult() throws {
        _ = NSApplication.shared
        for count in [0, 2] {
            let service = DockWindowPreviewService(backend: GeometryPreviewBackend(count: count),
                                                   environment: GeometryPreviewEnvironment())
            let state = AnchorState()
            let window = NSPanel(contentRect: NSRect(x: 120, y: 180, width: 620, height: 100),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: GeometryPreviewFixture(state: state, service: service))
            host.sizingOptions = []
            window.contentView = host
            window.orderFrontRegardless()
            defer { state.presented = false; window.close(); service.cancel() }
            host.layoutSubtreeIfNeeded()
            state.presented = true
            var firstRect: CGRect?
            var sawLoading = false
            let deadline = Date().addingTimeInterval(1.6)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                sawLoading = sawLoading || service.isLoading
                guard let preview = NSApp.windows.filter({ $0 !== window && $0.isVisible })
                    .compactMap({ Self.find("dock-test-popup", in: $0.contentView) }).first,
                      let popupWindow = preview.window else { continue }
                let rect = popupWindow.convertToScreen(preview.convert(preview.bounds, to: nil))
                let anchor = try XCTUnwrap(Self.find("dock-test-anchor", in: host))
                let source = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                XCTAssertGreaterThanOrEqual(rect.minY, source.maxY - 2)
                if let firstRect {
                    // The size is frozen at presentation: a resizing popover in a non-activating
                    // panel detaches from its anchor.
                    XCTAssertEqual(rect.size.height, firstRect.size.height, accuracy: 1)
                    XCTAssertEqual(rect.size.width, firstRect.size.width, accuracy: 1)
                    XCTAssertEqual(rect.minY, firstRect.minY, accuracy: 1)
                    XCTAssertEqual(rect.midX, firstRect.midX, accuracy: 1)
                } else { firstRect = rect }
            }
            XCTAssertNotNil(firstRect)
            XCTAssertTrue(sawLoading)
            XCTAssertFalse(service.isLoading)
            XCTAssertEqual(service.windows.count, count)
            XCTAssertTrue(service.windows.allSatisfy { $0.image != nil })
        }
    }

    func testPreviewAnchorsAboveRenderedCellAtDifferentScales() throws {
        _ = NSApplication.shared
        for scale in [0.8, 1.4] {
            let state = AnchorState()
            let window = NSPanel(contentRect: NSRect(x: 120, y: 180, width: 620, height: 180),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AnchorFixture(state: state, scale: scale))
            host.sizingOptions = []
            window.contentView = host
            window.orderFrontRegardless()
            defer {
                state.presented = false
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            state.presented = true
            let deadline = Date().addingTimeInterval(2)
            var popup: NSView?
            while popup == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                popup = NSApp.windows.filter { $0 !== window && $0.isVisible }
                    .compactMap { Self.find("dock-test-popup", in: $0.contentView) }.first
            }
            let anchor = try XCTUnwrap(Self.find("dock-test-anchor", in: host))
            let preview = try XCTUnwrap(popup, "Expected an actual AppKit popover")
            let previewWindow = try XCTUnwrap(preview.window)
            let sourceRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let previewRect = previewWindow.convertToScreen(preview.convert(preview.bounds, to: nil))
            XCTAssertEqual(sourceRect.width, DockLayout.baseCellWidth * scale, accuracy: 1)
            XCTAssertEqual(previewRect.midX, sourceRect.midX, accuracy: 4)
            XCTAssertGreaterThanOrEqual(previewRect.minY, sourceRect.maxY - 2)
        }
    }

    func testLabelsAddOnlyTheirReservedHeight() {
        XCTAssertEqual(DockLayout.height(scale: 1), 64)
        XCTAssertEqual(DockLayout.height(scale: 1, showLabels: true), 78)
    }

    private static func find(_ id: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
}

@MainActor
private final class GeometryPreviewEnvironment: DockWindowPreviewEnvironment {
    var hasCaptureAccess: Bool { true }
    var hasAccessibilityAccess: Bool { true }
    func application(at path: String) -> DockWindowApplicationIdentity? {
        .init(pid: 123, applicationPath: path, launchDate: .distantPast)
    }
    func isCurrent(_ application: DockWindowApplicationIdentity) -> Bool { true }
    func requestCaptureAccess() {}
    func requestAccessibilityAccess() {}
    func screens() -> [WindowLayoutScreen] { [] }
}

private struct GeometryPreviewBackend: DockWindowPreviewBackend {
    let count: Int
    func windows(for application: DockWindowApplicationIdentity, captureAllowed: Bool,
                 accessibilityAllowed: Bool) async throws -> [DockWindowRecord] {
        try await Task.sleep(for: .milliseconds(250))
        return (0..<count).map { index in
            .init(id: UInt32(index + 1), application: application, title: "Window \(index)",
                  frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false,
                  captureWindowID: UInt32(index + 1), accessibilityToken: nil, availableActions: [])
        }
    }
    func thumbnail(for window: DockWindowRecord) async throws -> CGImage? {
        try await Task.sleep(for: .milliseconds(200))
        return CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    func perform(_ action: DockWindowAction, on window: DockWindowRecord,
                 screens: [WindowLayoutScreen]) async throws {}
}

@MainActor
private final class AnchorState: ObservableObject {
    @Published var presented = false
}

private struct AnchorFixture: View {
    @ObservedObject var state: AnchorState
    let scale: CGFloat
    var body: some View {
        HStack {
            Color.clear.frame(width: 150)
            Image(systemName: "terminal")
                .frame(width: DockLayout.baseCellWidth, height: DockLayout.baseHeight)
                .scaleEffect(scale)
                .frame(width: DockLayout.baseCellWidth * scale, height: DockLayout.baseHeight * scale)
                .background(AnchorMarker(id: "dock-test-anchor"))
                .modifier(DockPopoverAnchor(isPresented: $state.presented) {
                    Text("Window preview").frame(width: 220, height: 90)
                        .background(AnchorMarker(id: "dock-test-popup"))
                })
            Spacer()
        }.frame(width: 620, height: 180)
    }
}

private struct AnchorMarker: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct GeometryPreviewFixture: View {
    @ObservedObject var state: AnchorState
    let service: DockWindowPreviewService
    var body: some View {
        Color.clear.frame(width: 64, height: 52)
            .background(AnchorMarker(id: "dock-test-anchor"))
            .modifier(DockPopoverAnchor(isPresented: $state.presented) {
                DockPreviewSurface(service: service, applicationPath: "/Fake.app",
                                   title: "Preview", interactionChanged: { _ in })
                    .background(AnchorMarker(id: "dock-test-popup"))
            })
    }
}
