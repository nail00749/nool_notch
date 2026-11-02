import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockMusicWidgetTests: XCTestCase {
    @MainActor
    func testMarqueeVisualFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOL_MARQUEE_FIXTURE"] else {
            throw XCTSkip("Opt-in native marquee rendering")
        }
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            DockMarqueeText(text: "Длинное название трека — Midnight City", font: .system(size: 11, weight: .semibold), isActive: true)
            DockMarqueeText(text: "Длинное название трека — Midnight City", font: .system(size: 11, weight: .semibold), isActive: false)
            DockMarqueeText(text: "Музыка", font: .system(size: 11, weight: .semibold), isActive: true)
        }.frame(width: 150).padding(20).foregroundStyle(.white).background(.black).preferredColorScheme(.dark))
        let window = fixturePanel(size: CGSize(width: 190, height: 110))
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 190, height: 110)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.display()
        host.layoutSubtreeIfNeeded()
        func flush(_ view: NSView) {
            view.displayIfNeeded()
            for child in view.subviews { flush(child) }
        }
        flush(host)
        CATransaction.flush()
        if let layer = host.layer {
            let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 380, pixelsHigh: 220,
                                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: pixels)).cgContext
            context.translateBy(x: 0, y: 220)
            context.scaleBy(x: 2, y: -2)
            layer.render(in: context)
            try XCTUnwrap(pixels.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + ".layers.png"))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    func testOneTrackChangePerScrollGesture() {
        XCTAssertNil(DockScrollWheelNSView.step(for: 10, consumed: false), "Small nudges do nothing")
        XCTAssertEqual(DockScrollWheelNSView.step(for: 30, consumed: false), 1)
        XCTAssertEqual(DockScrollWheelNSView.step(for: -30, consumed: false), -1)
        XCTAssertNil(DockScrollWheelNSView.step(for: 300, consumed: true), "Momentum doesn't skip several tracks")
    }

    @MainActor
    func testMarqueeScrollsOnlyOverflowingTitlesAtAReadableSpeed() {
        XCTAssertFalse(DockMarqueeText.overflows(textWidth: 60, containerWidth: 67))
        XCTAssertFalse(DockMarqueeText.overflows(textWidth: 60, containerWidth: 0), "Not measured yet")
        XCTAssertTrue(DockMarqueeText.overflows(textWidth: 180, containerWidth: 67))
        let duration = DockMarqueeText.passDuration(textWidth: 180)
        XCTAssertEqual(duration, TimeInterval((180 + DockMarqueeText.gap) / DockMarqueeText.pointsPerSecond))
        XCTAssertGreaterThan(duration, 5, "A long title must stay readable")
    }

    @MainActor
    func testNativeMarqueeRetainsTimingAndStopsWhenInactiveHiddenOrDetached() throws {
        let view = DockMarqueeNSView()
        let window = fixturePanel(size: CGSize(width: 100, height: 20))
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        view.configure(text: "A long readable track title that does not fit", font: .system(size: 11, weight: .semibold), isActive: true)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let animation = try XCTUnwrap(view.marqueeAnimation, "Visible: \(window.isVisible), occlusion: \(window.occlusionState), frame: \(view.frame)")
        let distance = -((try XCTUnwrap(animation.values?.last as? NSNumber)).doubleValue)
        XCTAssertEqual(animation.duration, distance / Double(DockMarqueeText.pointsPerSecond) + DockMarqueeText.pauseBetweenPasses, accuracy: 0.0001)
        let pause = try XCTUnwrap(animation.keyTimes?[1]).doubleValue
        XCTAssertEqual(pause * animation.duration, DockMarqueeText.pauseBetweenPasses, accuracy: 0.0001)
        XCTAssertEqual(animation.repeatCount, .infinity)

        view.configure(text: "A long readable track title that does not fit", font: .system(size: 11, weight: .semibold), isActive: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.marqueeAnimation?.beginTime, animation.beginTime, "Unrelated model refreshes must not restart the title")
        window.setFixtureOccluded(true)
        XCTAssertNil(view.marqueeAnimation, "Covered Dock windows stop decorative motion")
        window.setFixtureOccluded(false)
        XCTAssertNotNil(view.marqueeAnimation)
        view.isHidden = true
        XCTAssertNil(view.marqueeAnimation)
        view.isHidden = false
        XCTAssertNotNil(view.marqueeAnimation)
        view.configure(text: "A long readable track title that does not fit", font: .system(size: 11, weight: .semibold), isActive: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.marqueeAnimation, "Paused playback or Reduce Motion stops decorative motion")
        view.configure(text: "Short", font: .system(size: 11, weight: .semibold), isActive: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.marqueeAnimation, "Fitting titles stay still")
        view.configure(text: "A long readable track title that does not fit", font: .system(size: 11, weight: .semibold), isActive: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.marqueeAnimation)
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(view.marqueeAnimation, "The Dock retains its view when ordered out")
        view.removeFromSuperview()
        XCTAssertNil(view.marqueeAnimation)
    }

    @MainActor
    func testNativeProgressTracksElapsedTimeRateAndStopsWithoutPolling() throws {
        let view = DockMusicProgressNSView()
        let window = fixturePanel(size: CGSize(width: 100, height: 2.5))
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        func snapshot(_ state: NowPlayingPlaybackState, rate: Double = 1, elapsed: Double = 40) -> NowPlayingSnapshot {
            NowPlayingSnapshot(id: "track", title: "Title", artist: "Artist", album: nil, appName: nil,
                               artworkData: nil, duration: 200, elapsedTime: elapsed,
                               playbackRate: rate, playbackState: state, updatedAt: Date())
        }
        view.configure(snapshot: snapshot(.playing, rate: 2))
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let animation = try XCTUnwrap(view.progressAnimation, "Visible: \(window.isVisible), occlusion: \(window.occlusionState), frame: \(view.frame)")
        XCTAssertEqual(animation.duration, 80, accuracy: 0.15)
        XCTAssertEqual((animation.toValue as? NSNumber)?.doubleValue ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(view.progressWidth, 20, accuracy: 0.15)
        view.configure(snapshot: snapshot(.paused))
        XCTAssertNil(view.progressAnimation)
        XCTAssertEqual(view.progressWidth, 20, accuracy: 0.001)
        view.configure(snapshot: snapshot(.playing))
        XCTAssertNotNil(view.progressAnimation)
        window.setFixtureOccluded(true)
        XCTAssertNil(view.progressAnimation)
        window.setFixtureOccluded(false)
        XCTAssertNotNil(view.progressAnimation)
        view.isHidden = true
        XCTAssertNil(view.progressAnimation)
        view.isHidden = false
        XCTAssertNotNil(view.progressAnimation)
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(view.progressAnimation)
        view.removeFromSuperview()
        XCTAssertNil(view.progressAnimation)
    }

    @MainActor
    func testNativeProgressKeepsItsThinFlexibleSwiftUILayout() throws {
        let snapshot = NowPlayingSnapshot(id: "track", title: "Title", artist: "Artist", album: nil,
                                          appName: nil, artworkData: nil, duration: 200, elapsedTime: 40,
                                          playbackRate: 1, playbackState: .paused, updatedAt: Date())
        let host = NSHostingView(rootView: HStack(spacing: 6) {
            Color.white.frame(width: 60, height: 18)
            DockMusicProgressLine(snapshot: snapshot)
        }.frame(width: 180, height: 20))
        host.sizingOptions = []
        let window = fixturePanel(size: CGSize(width: 180, height: 20))
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 20)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func progress(in view: NSView) -> DockMusicProgressNSView? {
            if let progress = view as? DockMusicProgressNSView { return progress }
            return view.subviews.lazy.compactMap { progress(in: $0) }.first
        }
        let native = try XCTUnwrap(progress(in: host))
        XCTAssertEqual(native.bounds.height, 2.5, accuracy: 0.01)
        XCTAssertEqual(native.bounds.width, 114, accuracy: 0.01)
    }

    func testBottomPanelGainsHeadroomAboveTheStripOnly() {
        let strip = CGRect(x: 100, y: 8, width: 600, height: 64)
        let frame = DockLayout.windowFrame(strip: strip, position: .bottom, scale: 1)
        XCTAssertEqual(frame.minY, strip.minY)
        XCTAssertEqual(frame.width, strip.width)
        XCTAssertEqual(frame.height, strip.height + DockLayout.headroom(scale: 1))
        XCTAssertGreaterThan(DockLayout.headroom(scale: 1), 14, "Room for the 14 pt launch bounce")
        let right = DockLayout.windowFrame(strip: CGRect(x: 900, y: 100, width: 76, height: 500), position: .right, scale: 1)
        XCTAssertEqual(right.maxX, 976)
    }

    @MainActor
    private func fixturePanel(size: CGSize) -> DockMusicFixturePanel {
        let panel = DockMusicFixturePanel(contentRect: CGRect(origin: CGPoint(x: 80, y: 140), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// The test runner's windows can remain on an inactive desktop (raw occlusion
/// state 8192), even when ordered front. Control that one OS input explicitly;
/// window ordering, view lifecycle, KVO and layer animation are still real AppKit.
@MainActor
private final class DockMusicFixturePanel: NSPanel {
    private var fixtureOcclusion: NSWindow.OcclusionState = .visible
    override var occlusionState: NSWindow.OcclusionState { fixtureOcclusion }

    func setFixtureOccluded(_ occluded: Bool) {
        fixtureOcclusion = occluded ? [] : .visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }
}
