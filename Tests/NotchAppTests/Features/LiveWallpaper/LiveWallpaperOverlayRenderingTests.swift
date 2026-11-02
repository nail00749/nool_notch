import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import NotchApp

final class LiveWallpaperOverlayRenderingTests: XCTestCase {
    @MainActor
    func testNativeMetersRetainRingAndCapsuleGeometryAtEveryOverlayScale() {
        for scale in [0.8, 1.0, 1.35] {
            let meter = LiveWallpaperMeterView()
            meter.frame.size = CGSize(width: 72 * scale, height: 72 * scale)
            meter.update(fraction: 0.42, load: 0.42, kind: .ring, scale: scale, reduceMotion: false)
            XCTAssertEqual(meter.valueLayer.path?.boundingBoxOfPath, meter.bounds)
            XCTAssertEqual(meter.valueLayer.lineWidth, 5 * scale)
            XCTAssertEqual(meter.valueLayer.lineCap, .round)
            XCTAssertEqual(meter.valueLayer.strokeEnd, 0.42)
            XCTAssertEqual(meter.valueLayer.path?.currentPoint.x ?? -1, 36 * scale, accuracy: 0.001)
            XCTAssertEqual(meter.valueLayer.path?.currentPoint.y ?? -1, 0, accuracy: 0.001)
            XCTAssertNil(meter.valueLayer.animationKeys(), "First sample is drawn immediately")

            meter.frame.size = CGSize(width: 180 * scale, height: 5 * scale)
            meter.update(fraction: 0.73, load: 0.27, kind: .bar, scale: scale, reduceMotion: false)
            XCTAssertEqual(meter.valueLayer.bounds.width, 180 * scale * 0.73, accuracy: 0.001)
            XCTAssertEqual(meter.valueLayer.bounds.height, 5 * scale)
            XCTAssertEqual(meter.valueLayer.position, .zero)
            XCTAssertEqual(meter.valueLayer.cornerRadius, 2.5 * scale)
            XCTAssertNil(meter.valueLayer.animationKeys())
            meter.update(fraction: 0, load: 1, kind: .bar, scale: scale, reduceMotion: false)
            XCTAssertEqual(meter.valueLayer.bounds.width, 0)
            meter.update(fraction: 1, load: 0, kind: .bar, scale: scale, reduceMotion: false)
            XCTAssertEqual(meter.valueLayer.bounds.width, 180 * scale)
        }
    }

    @MainActor
    func testReadingChangesAnimateNativelyAndIdenticalSamplesDoNotRestartAnimation() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 72, height: 72),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let meter = LiveWallpaperMeterView()
        panel.contentView = meter
        meter.update(fraction: 0.42, load: 0.42, kind: .ring, scale: 1, reduceMotion: false)
        meter.update(fraction: 0.73, load: 0.73, kind: .ring, scale: 1, reduceMotion: false)
        let stroke = try XCTUnwrap(meter.valueLayer.animation(forKey: "strokeEnd") as? CABasicAnimation)
        XCTAssertEqual(stroke.duration, 0.8)
        XCTAssertEqual(stroke.fromValue as? Double, 0.42)
        XCTAssertEqual(stroke.toValue as? Double, 0.73)
        let timing = try XCTUnwrap(stroke.timingFunction)
        var start = [Float](repeating: 0, count: 2)
        var end = start
        timing.getControlPoint(at: 1, values: &start)
        timing.getControlPoint(at: 2, values: &end)
        XCTAssertEqual(start, [0, 0])
        XCTAssertEqual(end[0], 0.58, accuracy: 0.0001)
        XCTAssertEqual(end[1], 1)
        XCTAssertNotNil(meter.valueLayer.animation(forKey: "strokeColor"))
        meter.update(fraction: 0.73, load: 0.73, kind: .ring, scale: 1, reduceMotion: false)
        let unchanged = try XCTUnwrap(meter.valueLayer.animation(forKey: "strokeEnd") as? CABasicAnimation)
        XCTAssertEqual(unchanged.fromValue as? Double, stroke.fromValue as? Double)
        XCTAssertEqual(unchanged.beginTime, stroke.beginTime)
        meter.update(fraction: 0.73, load: 0.73, kind: .ring, scale: 1, reduceMotion: true)
        XCTAssertNil(meter.valueLayer.animationKeys(), "Enabling Reduce Motion also stops an active transition")
        meter.update(fraction: 0.91, load: 0.91, kind: .ring, scale: 1, reduceMotion: true)
        XCTAssertNil(meter.valueLayer.animationKeys())
        meter.update(fraction: 0.5, load: 0.5, kind: .ring, scale: 1, reduceMotion: false)
        XCTAssertNotNil(meter.valueLayer.animationKeys())
        panel.contentView = nil
        XCTAssertNil(meter.valueLayer.animationKeys(), "Detached views retain no animation work")
    }

    @MainActor
    func testBarAnimationAndResizeKeepFinalGeometryWithoutSwiftUIAnimation() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 5),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let meter = LiveWallpaperMeterView()
        panel.contentView = meter
        meter.update(fraction: 0.2, load: 0.8, kind: .bar, scale: 1, reduceMotion: false)
        meter.update(fraction: 0.8, load: 0.2, kind: .bar, scale: 1, reduceMotion: false)
        let width = try XCTUnwrap(meter.valueLayer.animation(forKey: "bounds") as? CABasicAnimation)
        XCTAssertEqual(width.duration, 0.8)
        XCTAssertEqual((width.fromValue as? NSValue)?.rectValue.width, 36)
        XCTAssertEqual((width.toValue as? NSValue)?.rectValue.width, 144)
        meter.frame.size = CGSize(width: 243, height: 6.75)
        meter.update(fraction: 0.8, load: 0.2, kind: .bar, scale: 1.35, reduceMotion: false)
        XCTAssertNil(meter.valueLayer.animationKeys())
        XCTAssertEqual(meter.valueLayer.bounds.width, 243 * 0.8, accuracy: 0.001)
        XCTAssertEqual(meter.valueLayer.bounds.height, 6.75)
        XCTAssertEqual(meter.valueLayer.cornerRadius, 3.375)
    }

    @MainActor
    func testHostedMeterAnimatesInPresentationLayerAndRetargetsWithoutJump() async throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 72, height: 72),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let meter = LiveWallpaperMeterView()
        panel.contentView = meter
        meter.update(fraction: 0.1, load: 0.1, kind: .ring, scale: 1, reduceMotion: false)
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(60))
        meter.update(fraction: 0.9, load: 0.9, kind: .ring, scale: 1, reduceMotion: false)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(150))
        let visible = try XCTUnwrap(meter.valueLayer.presentation()).strokeEnd
        XCTAssertGreaterThan(visible, 0.1)
        XCTAssertLessThan(visible, 0.9)
        meter.update(fraction: 0.5, load: 0.5, kind: .ring, scale: 1, reduceMotion: false)
        let retarget = try XCTUnwrap(meter.valueLayer.animation(forKey: "strokeEnd") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(retarget.fromValue as? Double), visible, accuracy: 0.03)
        XCTAssertEqual(meter.valueLayer.strokeEnd, 0.5)
    }

    @MainActor
    func testOverlayRenderFixture() async throws {
        guard let suffix = ProcessInfo.processInfo.environment["NOOL_OVERLAY_RENDER"] else { return }
        let model = LiveWallpaperOverlayModel()
        model.settings.showsSystem = true
        model.settings.position = .center
        model.settings.opacity = 1
        model.data.system = SystemMetricsSnapshot(sampledAt: Date(), cpuFraction: 0.42,
            memory: SystemResourceUsage(usedBytes: 73, totalBytes: 100),
            disk: SystemResourceUsage(usedBytes: 91, totalBytes: 100), network: nil)
        let host = NSHostingView(rootView: LiveWallpaperOverlayView(model: model).background(.black))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/nool-overlay-\(suffix).png"))
        if suffix == "after", let originalData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/nool-overlay-before.png")),
           let original = NSBitmapImageRep(data: originalData) {
            XCTAssertEqual(original.pixelsWide, bitmap.pixelsWide)
            XCTAssertEqual(original.pixelsHigh, bitmap.pixelsHigh)
            var difference = 0.0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let a = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    difference += abs(a.redComponent - b.redComponent)
                    difference += abs(a.greenComponent - b.greenComponent)
                    difference += abs(a.blueComponent - b.blueComponent)
                }
            }
            let meanDifference = difference / Double(bitmap.pixelsWide * bitmap.pixelsHigh * 3)
            print("Overlay before/after mean RGB difference: \(meanDifference)")
            XCTAssertLessThan(meanDifference, 0.003, "Native rendering retains the original SwiftUI appearance")
        }
    }
}
