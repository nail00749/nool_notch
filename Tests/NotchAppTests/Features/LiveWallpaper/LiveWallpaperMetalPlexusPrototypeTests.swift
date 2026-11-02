import AppKit
import Darwin
import ImageIO
import MetalKit
import SpriteKit
import XCTest
@testable import NotchApp

/// Opt-in native experiments: never opens benchmark windows during the ordinary test suite.
final class LiveWallpaperMetalPlexusPrototypeTests: XCTestCase {
    @MainActor
    func testInteractivePreview() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_PLEXUS_PREVIEW"] == "1" else {
            throw XCTSkip("Set NOOL_PLEXUS_PREVIEW=1 for a continuous interactive Metal preview")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width }) else {
            throw XCTSkip("Window server unavailable")
        }
        let frame = screen.frame
        var settings = LiveWallpaperSceneSettings()
        settings.density = 2
        settings.framesPerSecond = 60
        settings.cursorMode = .repel
        settings.cursorStrength = 1
        settings.parallax = 1
        let reference = LiveWallpaperParticleScene(size: frame.size, screenFrame: frame,
                                                   content: .scene(.plexus), settings: settings)
        let seed = try XCTUnwrap(reference.exportPlexusSeed())
        let simulation = LiveWallpaperPlexusSimulation(seed: seed)
        simulation.setEnergy(0.35)
        let metal = try XCTUnwrap(LiveWallpaperMetalPlexusView.make(seed: seed))
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = container
        container.addSubview(metal)
        let label = NSTextField(labelWithString: "Metal · живой курсор · непрерывный предпросмотр")
        label.frame = CGRect(x: 24, y: frame.height - 54, width: 460, height: 28)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.drawsBackground = true
        label.alignment = .center
        container.addSubview(label)
        defer { metal.stop(); panel.orderOut(nil); panel.contentView = nil; panel.close() }
        let stop = try outputDirectory().appendingPathComponent("preview.stop")
        if FileManager.default.fileExists(atPath: stop.path) { try FileManager.default.removeItem(at: stop) }
        var observedCursorPositions = Set<String>()
        metal.start { time in
            let global = NSEvent.mouseLocation
            let cursor = frame.contains(global) ? CGPoint(x: global.x - frame.minX, y: global.y - frame.minY) : nil
            if let cursor, observedCursorPositions.count < 512 {
                observedCursorPositions.insert("\(Int(cursor.x / 20)):\(Int(cursor.y / 20))")
            }
            return simulation.advance(at: time, cursor: cursor)
        }
        panel.orderFrontRegardless()
        let ready = try outputDirectory().appendingPathComponent("preview.ready")
        try Data("ready".utf8).write(to: ready)
        defer { try? FileManager.default.removeItem(at: ready) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: stop.path) {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(metal.statistics.failed, 0)
        XCTAssertGreaterThan(metal.statistics.presented, 0)
        print("PLEXUS_PREVIEW cursorCells=\(observedCursorPositions.count) presented=\(metal.statistics.presented) maxGap=\(metal.statistics.maximumPresentationGap)")
    }

    @MainActor
    func testVisualComparison() throws {
        guard ProcessInfo.processInfo.environment["NOOL_PLEXUS_VISUAL"] == "1" else {
            throw XCTSkip("Set NOOL_PLEXUS_VISUAL=1 for GPU image comparison")
        }
        _ = NSApplication.shared
        let size = CGSize(width: 960, height: 540)
        var settings = LiveWallpaperSceneSettings()
        settings.density = 2
        let cursor = CGPoint(x: size.width * 0.48, y: size.height * 0.52)
        let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                               content: .scene(.plexus), settings: settings,
                                               cursorProvider: { cursor })
        let seed = try XCTUnwrap(scene.exportPlexusSeed())
        let simulation = LiveWallpaperPlexusSimulation(seed: seed)
        let metal = try XCTUnwrap(LiveWallpaperMetalPlexusView.make(seed: seed))
        let view = SKView(frame: CGRect(origin: .zero, size: size))
        view.isPaused = true
        view.ignoresSiblingOrder = true
        view.presentScene(scene)
        view.isPaused = true
        scene.isPaused = true
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = view
        defer { view.presentScene(nil); metal.stop(); panel.orderOut(nil); panel.contentView = nil; panel.close() }
        scene.setEnergy(0.35)
        simulation.setEnergy(0.35)
        var frame = simulation.advance(at: 0, cursor: cursor)
        for index in 0...120 {
            let time = Double(index) / 60
            scene.update(time)
            frame = simulation.advance(at: time, cursor: cursor)
        }
        let directory = try outputDirectory()
        let fullFrame = frame
        var checkedScales = Set<CGFloat>()
        for screen in NSScreen.screens where checkedScales.insert(screen.backingScaleFactor).inserted {
        panel.setFrameOrigin(CGPoint(x: screen.frame.minX + 30, y: screen.frame.minY + 60))
        panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(scene.isPaused)
        XCTAssertEqual(scene.completedUpdateCount, 0, "Static image comparison must not advance one backend")
        frame = fullFrame
        scene.setLineRenderer { _, _ in }
        let spriteReference = try XCTUnwrap(view.texture(from: scene)?.cgImage())
        let scale = CGFloat(spriteReference.width) / size.width
        XCTAssertEqual(scale, screen.backingScaleFactor)
        let suffix = "-\(Int(scale))x"
        // Shipping appearance = SpriteKit base/sprites + the actual existing Metal line
        // shader. scene.snapshot() deliberately falls back to legacy SKShapeNode lines.
        let reference = try shippingReference(base: spriteReference, frame: fullFrame, scale: scale)
        let candidate = try metal.snapshot(frame: frame, scale: scale)
        try write(reference, to: directory.appendingPathComponent("spritekit-reference\(suffix).png"))
        try write(candidate, to: directory.appendingPathComponent("metal-prototype\(suffix).png"))
        let difference = try compare(reference, candidate)
        print("PLEXUS_VISUAL full scale=\(scale) \(difference)")
        XCTAssertLessThan(difference.mean, 1.5, "Mean channel error in 8-bit RGB")
        XCTAssertLessThan(difference.p99, 8, "Reject broad color/geometry differences")

        // Isolate texture sampling and additive blending from line composition.
        frame = LiveWallpaperPlexusFrame(size: frame.size, backgroundCenter: frame.backgroundCenter,
            backgroundSize: frame.backgroundSize, sprites: frame.sprites, lines: [])
        let spriteCandidate = try metal.snapshot(frame: frame, scale: CGFloat(spriteReference.width) / size.width)
        try write(spriteReference, to: directory.appendingPathComponent("spritekit-sprites\(suffix).png"))
        try write(spriteCandidate, to: directory.appendingPathComponent("metal-sprites\(suffix).png"))
        let sprites = try compare(spriteReference, spriteCandidate)
        print("PLEXUS_VISUAL sprites scale=\(scale) \(sprites)")
        XCTAssertLessThan(sprites.mean, 0.75)
        XCTAssertLessThan(sprites.p99, 4)
        }
        XCTAssertFalse(checkedScales.isEmpty)
    }

    @MainActor
    func testNativeABBA() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_PLEXUS_BENCHMARK"] == "1" else {
            throw XCTSkip("Set NOOL_PLEXUS_BENCHMARK=1 for the opt-in native benchmark")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width }) else {
            throw XCTSkip("Window server unavailable")
        }
        let fixture = try Fixture(screen: screen)
        defer { fixture.close() }
        let duration = Double(ProcessInfo.processInfo.environment["NOOL_PLEXUS_SECONDS"] ?? "12") ?? 12
        // Warm both pipelines before either measured phase; the earlier async experiment
        // demonstrated that a single cold first pass can manufacture an apparent win.
        for mode in [Mode.spriteKit, .metal] {
            fixture.activate(mode)
            try await Task.sleep(for: .seconds(8))
        }
        var results: [Result] = []
        for mode in [Mode.spriteKit, .metal, .metal, .spriteKit] {
            fixture.activate(mode)
            try await Task.sleep(for: .seconds(3))
            fixture.clock.times.removeAll(keepingCapacity: true)
            fixture.metal.resetStatistics()
            let frames = fixture.scene.completedUpdateCount
            let cpu = Self.cpuTime()
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(duration))
            let wall = ProcessInfo.processInfo.systemUptime - start
            let used = Self.cpuTime() - cpu
            let stats = fixture.metal.statistics
            let count = mode == .spriteKit ? Int(fixture.scene.completedUpdateCount - frames) : stats.submitted
            let times = fixture.clock.times
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            let presentationGaps = stats.presentationIntervals.sorted()
            let result = Result(mode: mode.rawValue, cpu: used / wall * 100, frames: count,
                                fps: Double(count) / wall, p99Gap: gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.99))],
                                maxGap: gaps.last ?? 0, presented: stats.presented,
                                presentedFPS: Double(stats.presented) / wall,
                                presentationP99: presentationGaps.isEmpty ? 0 : presentationGaps[min(presentationGaps.count - 1, Int(Double(presentationGaps.count) * 0.99))],
                                presentationMax: stats.maximumPresentationGap, dropped: stats.dropped, gpuErrors: stats.failed,
                                size: "\(Int(fixture.seed.size.width))x\(Int(fixture.seed.size.height))", scale: screen.backingScaleFactor)
            results.append(result)
            print("PLEXUS_BENCHMARK \(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)")
            XCTAssertGreaterThan(result.fps, 55)
            XCTAssertLessThan(result.fps, 65)
            XCTAssertLessThan(result.p99Gap, 0.035)
            XCTAssertEqual(fixture.lineFailures, 0)
            XCTAssertEqual(result.gpuErrors, 0)
            if mode == .metal {
                XCTAssertGreaterThan(result.presentedFPS, 55, "Confirmed drawable presentation, not only simulation callbacks")
                XCTAssertLessThan(result.presentationP99, 0.035)
                XCTAssertEqual(result.dropped, 0)
            }
        }
        let data = try JSONEncoder().encode(results)
        try data.write(to: outputDirectory().appendingPathComponent("benchmark.json"))
    }

    private enum Mode: String { case spriteKit = "spritekit-plus-metal-lines", metal = "full-metal" }
    private struct Result: Codable {
        let mode: String
        let cpu: Double
        let frames: Int
        let fps: Double
        let p99Gap: Double
        let maxGap: Double
        let presented: Int
        let presentedFPS: Double
        let presentationP99: Double
        let presentationMax: Double
        let dropped: Int
        let gpuErrors: Int
        let size: String
        let scale: CGFloat
    }

    @MainActor
    private final class Clock: NSObject, @preconcurrency SKViewDelegate {
        var times: [Double] = []
        func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
            if times.count < 8_192 { times.append(ProcessInfo.processInfo.systemUptime) }
            return true
        }
    }

    @MainActor
    private final class Fixture {
        let panel: NSPanel
        let seed: LiveWallpaperPlexusSeed
        let scene: LiveWallpaperParticleScene
        let view: SKView
        let lines: LiveWallpaperMetalLineView
        let metal: LiveWallpaperMetalPlexusView
        let clock = Clock()
        var lineFailures = 0

        init(screen: NSScreen) throws {
            let rect = screen.frame
            var settings = LiveWallpaperSceneSettings()
            settings.density = 2
            settings.framesPerSecond = 60
            let cursor = CGPoint(x: rect.width * 0.48, y: rect.height * 0.52)
            scene = LiveWallpaperParticleScene(size: rect.size, screenFrame: rect, content: .scene(.plexus),
                                               settings: settings, cursorProvider: { cursor })
            seed = try XCTUnwrap(scene.exportPlexusSeed())
            metal = try XCTUnwrap(LiveWallpaperMetalPlexusView.make(seed: seed))
            view = SKView(frame: CGRect(origin: .zero, size: rect.size))
            view.isPaused = true
            view.ignoresSiblingOrder = true
            view.allowsTransparency = false
            view.preferredFramesPerSecond = 60
            view.presentScene(scene)
            lines = try XCTUnwrap(LiveWallpaperMetalLineView.make(frame: view.bounds))
            panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            let container = NSView(frame: view.bounds)
            panel.contentView = container
            container.addSubview(view)
            container.addSubview(lines)
            container.addSubview(metal)
            view.delegate = clock
            lines.onFailure = { [weak self] in self?.lineFailures += 1 }
            scene.setLineRenderer { [weak lines] segments, size in lines?.update(segments: segments, logicalSize: size) }
            panel.orderFrontRegardless()
        }

        func activate(_ mode: Mode) {
            view.isPaused = true
            metal.stop()
            lines.clear()
            clock.times.removeAll(keepingCapacity: true)
            if mode == .spriteKit {
                precondition(scene.restorePlexusPrototypeSeed(seed))
                scene.setEnergy(0.35)
                metal.isHidden = true
                view.isHidden = false
                view.isPaused = false
            } else {
                view.isHidden = true
                metal.isHidden = false
                let simulation = LiveWallpaperPlexusSimulation(seed: seed)
                simulation.setEnergy(0.35)
                let cursor = CGPoint(x: seed.size.width * 0.48, y: seed.size.height * 0.52)
                let clock = clock
                metal.start { time in
                    if clock.times.count < 8_192 { clock.times.append(ProcessInfo.processInfo.systemUptime) }
                    return simulation.advance(at: time, cursor: cursor)
                }
            }
        }

        func close() {
            view.isPaused = true
            metal.stop()
            scene.setLineRenderer(nil)
            view.presentScene(nil)
            view.delegate = nil
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func outputDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["NOOL_PLEXUS_OUTPUT"] ?? "/tmp/nool-plexus-metal-prototype"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Reference-only offscreen rendering of the shipping line shader and blend state.
    /// This is outside the timing loop; it never replaces or edits the shader under test.
    @MainActor
    private func shippingReference(base: CGImage, frame: LiveWallpaperPlexusFrame, scale: CGFloat) throws -> CGImage {
        struct Segment { var start: SIMD2<Float>; var end: SIMD2<Float>; var bucket: UInt32; var padding: UInt32 = 0 }
        struct Uniforms { var size: SIMD2<Float>; var scale: Float; var padding: Float = 0 }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: LiveWallpaperMetalLineView.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "plexusVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "plexusFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: base.width, height: base.height, mipmapped: false)
        target.usage = [.renderTarget]
        target.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: target))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        var uniforms = Uniforms(size: SIMD2(Float(frame.size.width), Float(frame.size.height)), scale: Float(scale))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        let segments = frame.lines.map { Segment(start: SIMD2(Float($0.start.x), Float($0.start.y)),
            end: SIMD2(Float($0.end.x), Float($0.end.y)), bucket: UInt32($0.bucket)) }
        if !segments.isEmpty {
            let buffer = try XCTUnwrap(segments.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segments.count)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNotEqual(command.status, .error)
        var bytes = [UInt8](repeating: 0, count: base.width * base.height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: base.width * 4,
            from: MTLRegionMake2D(0, 0, base.width, base.height), mipmapLevel: 0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let overlay = try XCTUnwrap(CGImage(width: base.width, height: base.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: base.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let context = try XCTUnwrap(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
            bytesPerRow: base.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: bounds)
        context.draw(overlay, in: bounds)
        return try XCTUnwrap(context.makeImage())
    }

    private struct Difference: CustomStringConvertible {
        let mean: Double
        let p99: Double
        let max: Int
        var description: String { "mean=\(mean) p99=\(p99) max=\(max)" }
    }

    private func compare(_ lhs: CGImage, _ rhs: CGImage) throws -> Difference {
        XCTAssertEqual(lhs.width, rhs.width)
        XCTAssertEqual(lhs.height, rhs.height)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { throw NSError(domain: "ImageSize", code: 1) }
        func bytes(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try data.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let a = try bytes(lhs), b = try bytes(rhs)
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0, count = 0, maximum = 0
        for index in a.indices where index % 4 != 3 {
            let difference = abs(Int(a[index]) - Int(b[index]))
            histogram[difference] += 1
            sum += difference; count += 1; maximum = max(maximum, difference)
        }
        var cumulative = 0, p99 = 0
        for index in histogram.indices {
            cumulative += histogram[index]
            if cumulative >= Int(Double(count) * 0.99) { p99 = index; break }
        }
        return Difference(mean: Double(sum) / Double(count), p99: Double(p99), max: maximum)
    }
}
