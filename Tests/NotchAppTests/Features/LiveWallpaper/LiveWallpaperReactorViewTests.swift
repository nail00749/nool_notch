import AppKit
import MetalKit
import XCTest
@testable import NotchApp

final class LiveWallpaperReactorViewTests: XCTestCase {
    @MainActor
    func testAnimatedRadarsFitLaptopAndUltrawideComposition() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        let view = try XCTUnwrap(LiveWallpaperReactorView.make(frame: frame))
        var settings = LiveWallpaperSceneSettings()
        settings.cursorMode = .off
        view.settings = settings
        panel.contentView = view
        for (name, size) in [("laptop", CGSize(width: 1_600, height: 1_000)),
                             ("ultrawide", CGSize(width: 5_120, height: 1_440))] {
            view.drawableSize = size
            let calm = try XCTUnwrap(view.snapshot(at: 0))
            let animated = try XCTUnwrap(view.snapshot(at: 3.5))
            for side in [-1.0, 1.0] {
                let activity = radarActivity(calm, animated, side: side)
                XCTAssertGreaterThan(activity.lit, 30, "\(name): radar must remain visible above the metrics")
                XCTAssertGreaterThan(activity.changed, 25, "\(name): radar beam and returns must move")
            }
            if let path = ProcessInfo.processInfo.environment["NOOL_REACTOR_CAPTURE"] {
                let base = URL(fileURLWithPath: path).deletingPathExtension()
                try NSBitmapImageRep(cgImage: calm).representation(using: .png, properties: [:])?
                    .write(to: base.appendingPathExtension("\(name).png"))
                try NSBitmapImageRep(cgImage: animated).representation(using: .png, properties: [:])?
                    .write(to: base.appendingPathExtension("\(name).animated.png"))
            }
        }
    }

    @MainActor
    func testPausedSnapshotAnimationAndDetachResume() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 1_280, height: 720)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        let view = try XCTUnwrap(LiveWallpaperReactorView.make(frame: frame))
        var settings = LiveWallpaperSceneSettings()
        settings.cursorMode = .off
        view.settings = settings
        view.drawableSize = CGSize(width: 1_280, height: 720)
        let initial = try XCTUnwrap(view.snapshot(), "Shader must compile and render a paused initial frame")
        let initialBytes = bytes(initial)
        XCTAssertGreaterThan(Set(initialBytes).count, 80, "Reactor must contain a rich gradient rather than a blank fallback")
        panel.contentView = view
        defer { view.setPlaying(false) }
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        view.setPlaying(true)
        XCTAssertEqual(view.isPaused, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pump(0.25)
        let animated = try XCTUnwrap(view.snapshot())
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotEqual(bytes(animated), initialBytes, "A running reactor must move")
            XCTAssertGreaterThan(view.presentedFrameCount, 0, "The native MTKView clock must actually present frames")
        }
        view.setPlaying(false)
        pump(0.08) // Allow the last already submitted drawable to finish presenting.
        let pausedCount = view.presentedFrameCount
        let paused = bytes(try XCTUnwrap(view.snapshot()))
        pump(0.12)
        XCTAssertEqual(bytes(try XCTUnwrap(view.snapshot())), paused, "A paused capture must preserve phase")
        XCTAssertEqual(view.presentedFrameCount, pausedCount, "Paused native clock must stop presenting")
        let calm = try XCTUnwrap(view.snapshot(at: 0))
        let flare = try XCTUnwrap(view.snapshot(at: 8))
        let later = try XCTUnwrap(view.snapshot(at: 20))
        XCTAssertEqual(bytes(later), bytes(try XCTUnwrap(view.snapshot(at: 2 * .pi * 1_000 + 20))),
                       "Long sessions must preserve periodic phases and rendering precision")
        XCTAssertGreaterThan(changedSidePixels(calm, later), 200,
                             "The environment must animate beyond the central reactor")
        XCTAssertGreaterThan(brightExteriorPixels(flare), brightExteriorPixels(calm) + 15,
                             "A prominence must rise outside the mechanical rings")
        XCTAssertEqual(bytes(try XCTUnwrap(view.snapshot())), paused, "Diagnostic time capture must preserve the live clock")
        XCTAssertNil(view.snapshot(at: -.infinity))
        view.setPlaying(true)
        panel.contentView = nil
        XCTAssertTrue(view.isPaused, "Detached surfaces must stop their native display clock")
        panel.contentView = view
        XCTAssertEqual(view.isPaused, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                       "Reattaching a playing surface must restore its clock unless reduced motion is enabled")
        view.setPlaying(false)
        if let path = ProcessInfo.processInfo.environment["NOOL_REACTOR_CAPTURE"] {
            let representation = NSBitmapImageRep(cgImage: calm)
            try representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            let flarePath = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("flare.png")
            try NSBitmapImageRep(cgImage: flare).representation(using: .png, properties: [:])?.write(to: flarePath)
        }
    }

    private func bytes(_ image: CGImage) -> Data {
        (image.dataProvider?.data as Data?) ?? Data()
    }

    private func radarActivity(_ first: CGImage, _ second: CGImage, side: Double) -> (lit: Int, changed: Int) {
        let a = [UInt8](bytes(first)), b = [UInt8](bytes(second))
        let centerX = Int(Double(first.width) * (0.5 + side * 0.30))
        let centerY = Int(Double(first.height) * 0.20)
        let radius = Int(Double(first.height) * 0.07)
        var lit = 0, changed = 0
        for y in stride(from: centerY-radius, through: centerY+radius, by: 2) {
            for x in stride(from: centerX-radius, through: centerX+radius, by: 2) {
                let offset = y * first.bytesPerRow + x * 4
                if a[offset] > 65, a[offset+1] > 45 { lit += 1 }
                if abs(Int(a[offset])-Int(b[offset])) > 4 ||
                    abs(Int(a[offset+1])-Int(b[offset+1])) > 4 { changed += 1 }
            }
        }
        return (lit, changed)
    }

    private func changedSidePixels(_ first: CGImage, _ second: CGImage) -> Int {
        let a = [UInt8](bytes(first)), b = [UInt8](bytes(second))
        guard first.width == second.width, first.height == second.height else { return 0 }
        var changed = 0
        for y in stride(from: 0, to: first.height, by: 8) {
            for x in stride(from: 0, to: first.width / 5, by: 8) {
                let offset = y * first.bytesPerRow + x * 4
                if abs(Int(a[offset]) - Int(b[offset])) > 1 ||
                    abs(Int(a[offset + 1]) - Int(b[offset + 1])) > 1 { changed += 1 }
            }
        }
        return changed
    }

    private func brightExteriorPixels(_ image: CGImage) -> Int {
        let data = [UInt8](bytes(image))
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let dx = Double(x - image.width / 2) / Double(image.height)
                let dy = Double(y - image.height / 2) / Double(image.height)
                let radius = hypot(dx, dy)
                guard radius > 0.326, radius < 0.43 else { continue }
                let offset = y * image.bytesPerRow + x * 4
                if data[offset] > 95, data[offset + 1] > 65 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }
}
