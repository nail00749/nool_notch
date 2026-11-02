import AppKit
import MetalKit
import SpriteKit
import SwiftUI
import XCTest
@testable import NotchApp

final class LiveWallpaperMetalLineTests: XCTestCase {
    @MainActor
    func testActualSceneKeepsAnimatingWithMetalAndSwiftUIOverlayAcrossSnapshotAndPause() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("A window-server display is unavailable") }
        let size = CGSize(width: 420, height: 280)
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        panel.contentView = container
        let view = SKView(frame: container.bounds)
        view.ignoresSiblingOrder = true
        view.allowsTransparency = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        var settings = LiveWallpaperSceneSettings()
        settings.density = 2
        settings.framesPerSecond = 60
        settings.cursorMode = .off
        let scene = LiveWallpaperParticleScene(size: size, screenFrame: frame,
                                               content: .scene(.plexus), settings: settings)
        view.presentScene(scene)
        container.addSubview(view)
        let metal = try makeView()
        metal.frame = container.bounds
        container.addSubview(metal, positioned: .above, relativeTo: view)
        let overlayModel = LiveWallpaperOverlayModel()
        overlayModel.settings.showsSystem = true
        let overlay = NSHostingView(rootView: LiveWallpaperOverlayView(model: overlayModel))
        overlay.frame = container.bounds
        container.addSubview(overlay, positioned: .above, relativeTo: metal)

        var refreshes = 0
        var latest: [LiveWallpaperPlexusSegment] = []
        var failures = 0
        metal.onFailure = { failures += 1 }
        scene.setLineRenderer { segments, logicalSize in
            refreshes += 1
            latest = segments
            metal.update(segments: segments, logicalSize: logicalSize)
        }
        defer {
            view.isPaused = true
            scene.setLineRenderer(nil)
            metal.onFailure = nil
            metal.clear()
            view.presentScene(nil)
            panel.contentView = nil
            panel.close()
        }
        panel.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible)
        let initialRefreshes = refreshes
        scene.resumeClock()
        view.isPaused = false
        try await waitForRenderLoop { refreshes >= initialRefreshes + 3 && !latest.isEmpty }
        let moving = latest
        let beforeMotion = refreshes
        try await waitForRenderLoop { refreshes >= beforeMotion + 3 && latest != moving }
        XCTAssertFalse(metal.isHidden)
        XCTAssertNotNil(metal.currentDrawable, "Exercise an actual Metal drawable in a native window")

        let snapshot = try XCTUnwrap(scene.snapshot(in: view))
        XCTAssertGreaterThanOrEqual(snapshot.width, Int(size.width))
        let afterSnapshot = refreshes
        let snapshotSegments = latest
        try await waitForRenderLoop { refreshes >= afterSnapshot + 3 && latest != snapshotSegments }

        view.isPaused = true
        let pausedRefreshes = refreshes
        let pausedSegments = latest
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refreshes, pausedRefreshes, "Paused scenes perform no line work")
        XCTAssertEqual(latest, pausedSegments)
        scene.resumeClock()
        view.isPaused = false
        try await waitForRenderLoop { refreshes >= pausedRefreshes + 3 && latest != pausedSegments }
        XCTAssertEqual(failures, 0)
    }

    @MainActor
    func testRendererIsTransparentClickThroughAndStrictlyOnDemand() throws {
        let view = try makeView()
        XCTAssertTrue(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertEqual(view.clearColor.alpha, 0)
        XCTAssertFalse(view.layer?.isOpaque ?? true)
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertTrue(view.isHidden)

        // No window/drawable is available here. This must be harmless and retain valid input.
        var failures = 0
        view.onFailure = { failures += 1 }
        view.update(segments: [segment], logicalSize: view.bounds.size)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(failures, 0)
        view.clear()
        XCTAssertTrue(view.isHidden)
        view.update(segments: [], logicalSize: view.bounds.size)
        XCTAssertTrue(view.isHidden)
    }

    @MainActor
    func testInvalidAndDegenerateSegmentsDoNotReachGPU() throws {
        let view = try makeView()
        let invalid = [
            LiveWallpaperPlexusSegment(start: .zero, end: .zero, bucket: 0),
            LiveWallpaperPlexusSegment(start: .zero, end: CGPoint(x: 10, y: 10), bucket: 3),
            LiveWallpaperPlexusSegment(start: CGPoint(x: CGFloat.infinity, y: 0), end: .zero, bucket: 1)
        ]
        view.update(segments: invalid, logicalSize: view.bounds.size)
        XCTAssertTrue(view.isHidden)
        view.update(segments: [segment], logicalSize: .zero)
        XCTAssertTrue(view.isHidden)
    }

    @MainActor
    func testUnboundedInputRequestsFallbackOnceAndNeverRestartsFailedRenderer() throws {
        let view = try makeView()
        var failures = 0
        view.onFailure = { failures += 1 }
        view.update(segments: Array(repeating: segment, count: 16_385), logicalSize: view.bounds.size)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(failures, 1)
        view.update(segments: [segment], logicalSize: view.bounds.size)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    private func makeView() throws -> LiveWallpaperMetalLineView {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device is unavailable") }
        return try XCTUnwrap(LiveWallpaperMetalLineView.make(frame: CGRect(x: 0, y: 0, width: 256, height: 220)),
                             "Compile and validate the actual production Metal pipeline")
    }

    @MainActor
    private func waitForRenderLoop(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "The native SpriteKit loop must deliver moving Plexus links without manual updates")
    }

    private var segment: LiveWallpaperPlexusSegment {
        LiveWallpaperPlexusSegment(start: CGPoint(x: 15, y: 20.25), end: CGPoint(x: 100, y: 20.25), bucket: 0)
    }
}
