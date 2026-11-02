import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockMiniGaugeRingTests: XCTestCase {
    func testRingKeepsCenteredThreePointStrokeAndClockwiseTopStart() throws {
        let view = DockMiniGaugeRingNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        view.configure(fraction: 0.25, color: NSColor.green.cgColor, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.track.lineWidth, 3)
        XCTAssertEqual(view.fill.lineWidth, 3)
        XCTAssertEqual(view.fill.lineCap, .round)
        XCTAssertEqual(view.track.path?.boundingBoxOfPath, view.bounds)
        let path = try XCTUnwrap(view.fill.path)
        var start: CGPoint?
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { start = element.pointee.points[0] }
        }
        XCTAssertEqual(try XCTUnwrap(start).x, 14, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(start).y, 28, accuracy: 0.0001)
        XCTAssertFalse(view.clipsToBounds, "The centered stroke extends 1.5 points outside the frame")
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey), "Initial samples do not animate from zero")
    }

    func testSamplesClampHideAndRespectReduceMotion() {
        let view = DockMiniGaugeRingNSView()
        view.configure(fraction: nil, color: NSColor.red.cgColor, reduceMotion: false)
        XCTAssertTrue(view.fill.isHidden)
        view.configure(fraction: -0.5, color: NSColor.red.cgColor, reduceMotion: false)
        XCTAssertEqual(view.fill.strokeEnd, 0)
        view.configure(fraction: 1.5, color: NSColor.red.cgColor, reduceMotion: false)
        XCTAssertEqual(view.fill.strokeEnd, 1)
        view.configure(fraction: 0.5, color: NSColor.red.cgColor, reduceMotion: true)
        XCTAssertEqual(view.fill.strokeEnd, 0.5)
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey))
        view.configure(fraction: nil, color: NSColor.red.cgColor, reduceMotion: false)
        XCTAssertTrue(view.fill.isHidden)
    }

    func testNativeAnimationTimingInterruptionAndVisibility() throws {
        let view = DockMiniGaugeRingNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        let window = panel(content: view)
        defer { window.close() }
        pump(for: 0.1)
        XCTAssertTrue(window.occlusionState.contains(.visible), "Real NSEvent pumping must deliver window visibility")
        view.configure(fraction: 0.2, color: NSColor.green.cgColor, reduceMotion: false)
        view.configure(fraction: 0.8, color: NSColor.red.cgColor, reduceMotion: false)
        let animation = try XCTUnwrap(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey) as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 0.35)
        XCTAssertEqual(animation.fromValue as? Double, 0.2)
        XCTAssertEqual(animation.toValue as? Double, 0.8)
        let color = try XCTUnwrap(view.fill.animation(forKey: DockMiniGaugeRingNSView.colorAnimationKey) as? CABasicAnimation)
        XCTAssertEqual(color.keyPath, "strokeColor")
        XCTAssertEqual(color.duration, 0.35, "Threshold colors fade together with the ring")
        var control: [Float] = [0, 0]
        animation.timingFunction?.getControlPoint(at: 2, values: &control)
        XCTAssertEqual(control[0], 0.58, accuracy: 0.001)
        XCTAssertEqual(control[1], 1)
        pump(for: 0.1)
        let presented = try XCTUnwrap(view.fill.presentation()).strokeEnd
        view.configure(fraction: 0.4, color: NSColor.green.cgColor, reduceMotion: false)
        let interrupted = try XCTUnwrap(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey) as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(interrupted.fromValue as? Double), presented, accuracy: 0.08,
                       "New values continue from what the user currently sees")
        view.isHidden = true
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey))
        view.isHidden = false
        view.configure(fraction: 0.9, color: NSColor.green.cgColor, reduceMotion: false)
        XCTAssertNotNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey))
        window.orderOut(nil)
        pump(for: 0.05)
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey), "Real orderOut stops the animation through KVO")
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.colorAnimationKey))
        view.configure(fraction: 0.1, color: NSColor.green.cgColor, reduceMotion: false)
        XCTAssertNil(view.fill.animation(forKey: DockMiniGaugeRingNSView.animationKey))
    }

    func testStaticNativeRingMatchesSwiftUIAtOneAndTwoTimesScale() throws {
        let fractions: [Double?] = [nil, 0, 0.01, 0.25, 0.5, 0.75, 1]
        for scale in [1.0, 2.0] {
            for fraction in fractions {
                let old = ImageRenderer(content: original(fraction).frame(width: 40, height: 40).background(.black))
                old.scale = scale
                let expected = try XCTUnwrap(old.cgImage)
                let actual = try nativeImage(fraction, scale: scale)
                let difference = meanDifference(expected, actual)
                XCTAssertLessThan(difference, 4, "Ring pixels changed at fraction \(String(describing: fraction)), scale \(scale): \(difference)")
                if let directory = ProcessInfo.processInfo.environment["NOOL_GAUGE_FIXTURE"] {
                    let suffix = "\(fraction.map { String($0) } ?? "nil")-\(Int(scale))x.png"
                    try write(expected, path: directory + "/swiftui-" + suffix)
                    try write(actual, path: directory + "/native-" + suffix)
                }
            }
        }
    }

    private func original(_ fraction: Double?) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            if let fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color(red: 0.2, green: 0.85, blue: 0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.frame(width: 28, height: 28)
    }

    private func nativeImage(_ fraction: Double?, scale: Double) throws -> CGImage {
        let view = DockMiniGaugeRingNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        view.configure(fraction: fraction, color: NSColor(srgbRed: 0.2, green: 0.85, blue: 0.45, alpha: 1).cgColor, reduceMotion: true)
        view.layoutSubtreeIfNeeded()
        let side = Int(40 * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.translateBy(x: 6, y: 6)
        try XCTUnwrap(view.layer).render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func meanDifference(_ first: CGImage, _ second: CGImage) -> Double {
        func rgba(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return pixels
        }
        let a = rgba(first), b = rgba(second)
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    private func write(_ image: CGImage, path: String) throws {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }

    private func panel(content: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 300, y: 260, width: 40, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.orderFrontRegardless()
        return panel
    }

    private func pump(for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: min(until, Date().addingTimeInterval(0.01)),
                                          inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
        }
    }
}
