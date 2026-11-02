import AppKit
import MetalKit
import QuartzCore

/// Complete Plexus renderer: textures, particles and lines share one render pass.
@MainActor
final class LiveWallpaperMetalPlexusView: MTKView, MTKViewDelegate {
    enum CaptureError: Error {
        case invalidFrame, unavailableResource, commandFailed, imageCreationFailed
    }

    struct Statistics: Sendable {
        var submitted = 0
        var completed = 0
        var presented = 0
        var dropped = 0
        var skippedBusy = 0
        var failed = 0
        var encodingSeconds: Double = 0
        var gpuSeconds: Double = 0
        var firstPresentedTime: Double = 0
        var lastPresentedTime: Double = 0
        var maximumPresentationGap: Double = 0
        /// Bounded samples for cadence percentiles; the maximum above covers the whole interval.
        var presentationIntervals: [Double] = []
        var submissions: Int { submitted }
        var gpuErrors: Int { failed }
    }

    /// A single MTKView clock requests the simulation frame. No second timer or display link.
    var frameProvider: ((TimeInterval) -> LiveWallpaperPlexusFrame)?
    /// Resource/encoding/GPU errors are terminal for this surface. Missing drawables are transient.
    var onFailure: (() -> Void)?
    var statistics: Statistics { completion.snapshot() }

    private struct SpriteInstance {
        var center: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private struct SegmentInstance {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var bucket: UInt32
        var padding: UInt32 = 0
    }

    private struct Uniforms {
        var size: SIMD2<Float>
        var scale: Float
        var padding: Float = 0
    }

    private struct Slot {
        var sprites: MTLBuffer?
        var segments: MTLBuffer?
        var spriteCapacity = 0
        var segmentCapacity = 0
    }

    /// Completion callbacks release slots directly rather than scheduling a main-actor task per frame.
    /// The lock only protects three flags and scalar counters; no Metal operation runs under it.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = [false, false, false]
        private var stats = Statistics()
        private var epoch: UInt64 = 0

        func acquire() -> (slot: Int, epoch: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = busy.firstIndex(of: false) else {
                stats.dropped += 1
                stats.skippedBusy += 1
                return nil
            }
            busy[index] = true
            return (index, epoch)
        }

        func cancel(_ index: Int, failed: Bool = false) {
            lock.lock()
            busy[index] = false
            stats.dropped += 1
            if failed { stats.failed += 1 }
            lock.unlock()
        }

        func submitted(encodingSeconds: Double, epoch: UInt64) {
            lock.lock()
            if epoch == self.epoch {
                stats.submitted += 1
                stats.encodingSeconds += encodingSeconds
            }
            lock.unlock()
        }

        func completed(_ index: Int, failed: Bool, gpuSeconds: Double, epoch: UInt64) {
            lock.lock()
            busy[index] = false
            if epoch == self.epoch {
                stats.completed += 1
                if failed { stats.failed += 1 }
                stats.gpuSeconds += max(0, gpuSeconds)
            }
            lock.unlock()
        }

        func presented(at time: Double, epoch: UInt64) {
            guard time.isFinite, time > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard epoch == self.epoch else { return }
            if stats.firstPresentedTime == 0 { stats.firstPresentedTime = time }
            if stats.lastPresentedTime > 0, time >= stats.lastPresentedTime {
                let gap = time - stats.lastPresentedTime
                stats.maximumPresentationGap = max(stats.maximumPresentationGap, gap)
                if stats.presentationIntervals.count < 4_096 { stats.presentationIntervals.append(gap) }
            }
            stats.lastPresentedTime = max(stats.lastPresentedTime, time)
            stats.presented += 1
        }

        func reset() {
            lock.lock()
            epoch &+= 1
            stats = Statistics()
            lock.unlock()
        }

        func snapshot() -> Statistics {
            lock.lock()
            defer { lock.unlock() }
            return stats
        }
    }

    private let commands: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let additivePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let gradient: MTLTexture
    private let glow: MTLTexture
    private let sampler: MTLSamplerState
    private let completion = Completion()
    private var slots = [Slot(), Slot(), Slot()]
    private var pendingFrame: LiveWallpaperPlexusFrame?
    private var hasFailed = false

    static func make(seed: LiveWallpaperPlexusSeed) -> LiveWallpaperMetalPlexusView? {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        func pipeline(vertex: String, fragment: String, additive: Bool? = nil) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            if let additive {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .generateMipmaps: false,
                                                      .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let background = pipeline(vertex: "spriteVertex", fragment: "spriteFragment"),
              let additive = pipeline(vertex: "spriteVertex", fragment: "spriteFragment", additive: true),
              let line = pipeline(vertex: "plexusVertex", fragment: "plexusFragment", additive: false),
              let gradient = try? loader.newTexture(cgImage: seed.gradient, options: options),
              let glow = try? loader.newTexture(cgImage: seed.glow, options: options),
              let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        return LiveWallpaperMetalPlexusView(size: seed.size, device: device, commands: commands,
                                           background: background, additive: additive, line: line,
                                           gradient: gradient, glow: glow, sampler: sampler)
    }

    private init(size: CGSize, device: MTLDevice, commands: MTLCommandQueue,
                 background: MTLRenderPipelineState, additive: MTLRenderPipelineState,
                 line: MTLRenderPipelineState, gradient: MTLTexture, glow: MTLTexture, sampler: MTLSamplerState) {
        self.commands = commands
        backgroundPipeline = background
        additivePipeline = additive
        linePipeline = line
        self.gradient = gradient
        self.glow = glow
        self.sampler = sampler
        super.init(frame: CGRect(origin: .zero, size: size), device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        layer?.isOpaque = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start(frameProvider: @escaping (TimeInterval) -> LiveWallpaperPlexusFrame) {
        guard !hasFailed else { return }
        self.frameProvider = frameProvider
        isPaused = false
    }

    func stop() {
        isPaused = true
        frameProvider = nil
    }

    func resetStatistics() { completion.reset() }

    func update(frame: LiveWallpaperPlexusFrame) {
        pendingFrame = frame
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !hasFailed else { return }
        guard let frame = frameProvider?(CACurrentMediaTime()) ?? pendingFrame,
              Self.isValid(frame), let lease = completion.acquire() else { return }
        // A final queued draw after pause must retain the current picture, not the initial seed.
        pendingFrame = frame
        let slot = lease.slot
        let started = CACurrentMediaTime()
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else {
            completion.cancel(slot)
            return
        }
        do {
            try prepare(frame: frame, slot: &slots[slot])
            guard let command = commands.makeCommandBuffer() else { throw CaptureError.unavailableResource }
            try encode(frame: frame, slot: slots[slot], scale: drawableSize.width / frame.size.width,
                       pass: pass, command: command)
            let completion = completion
            command.addCompletedHandler { [weak self] command in
                completion.completed(slot, failed: command.status == .error,
                                     gpuSeconds: command.gpuEndTime - command.gpuStartTime, epoch: lease.epoch)
                if command.status == .error {
                    Task { @MainActor [weak self] in self?.fail() }
                }
            }
            drawable.addPresentedHandler { drawable in
                completion.presented(at: drawable.presentedTime, epoch: lease.epoch)
            }
            command.present(drawable)
            completion.submitted(encodingSeconds: CACurrentMediaTime() - started, epoch: lease.epoch)
            command.commit()
        } catch {
            completion.cancel(slot, failed: true)
            fail()
        }
    }

    private func fail() {
        guard !hasFailed else { return }
        hasFailed = true
        stop()
        onFailure?()
    }

    /// Explicit test/export operation. Its buffers and texture are separate from the live ring.
    /// Only this API waits for GPU completion; no live frame waits for an in-flight buffer.
    func snapshot(frame: LiveWallpaperPlexusFrame, scale: CGFloat = 1) throws -> CGImage {
        guard Self.isValid(frame), scale.isFinite, scale > 0, scale <= 4, let device else {
            throw CaptureError.invalidFrame
        }
        let width = Int((frame.size.width * scale).rounded())
        let height = Int((frame.size.height * scale).rounded())
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 67_108_864 / height else { throw CaptureError.invalidFrame }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = commands.makeCommandBuffer() else { throw CaptureError.unavailableResource }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        var slot = Slot()
        try prepare(frame: frame, slot: &slot)
        try encode(frame: frame, slot: slot, scale: scale, pass: pass, command: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw CaptureError.commandFailed }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw CaptureError.imageCreationFailed
        }
        return image
    }

    private static func isValid(_ frame: LiveWallpaperPlexusFrame) -> Bool {
        let size = frame.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384, frame.sprites.count <= 4_096,
              frame.lines.count <= 16_384,
              Float(frame.backgroundCenter.x).isFinite, Float(frame.backgroundCenter.y).isFinite,
              Float(frame.backgroundSize.width).isFinite, Float(frame.backgroundSize.height).isFinite,
              frame.backgroundSize.width > 0, frame.backgroundSize.height > 0 else { return false }
        return frame.sprites.allSatisfy {
            Float($0.center.x).isFinite && Float($0.center.y).isFinite
                && Float($0.size.width).isFinite && Float($0.size.height).isFinite
                && $0.size.width > 0 && $0.size.height > 0
                && $0.color.x.isFinite && $0.color.y.isFinite && $0.color.z.isFinite && $0.color.w.isFinite
        } && frame.lines.allSatisfy {
            Float($0.start.x).isFinite && Float($0.start.y).isFinite
                && Float($0.end.x).isFinite && Float($0.end.y).isFinite
                && (0..<3).contains($0.bucket)
        }
    }

    private func prepare(frame: LiveWallpaperPlexusFrame, slot: inout Slot) throws {
        guard let device else { throw CaptureError.unavailableResource }
        // Entry zero is the opaque gradient; the rest are the ordered additive sprite instances.
        let spriteCount = frame.sprites.count + 1
        if spriteCount > slot.spriteCapacity {
            let capacity = Self.capacity(for: spriteCount)
            guard let buffer = device.makeBuffer(length: capacity * MemoryLayout<SpriteInstance>.stride,
                                                  options: .storageModeShared) else {
                throw CaptureError.unavailableResource
            }
            slot.sprites = buffer
            slot.spriteCapacity = capacity
        }
        let segmentCount = max(1, frame.lines.count)
        if segmentCount > slot.segmentCapacity {
            let capacity = Self.capacity(for: segmentCount)
            guard let buffer = device.makeBuffer(length: capacity * MemoryLayout<SegmentInstance>.stride,
                                                  options: .storageModeShared) else {
                throw CaptureError.unavailableResource
            }
            slot.segments = buffer
            slot.segmentCapacity = capacity
        }
        guard let sprites = slot.sprites, let segments = slot.segments else { throw CaptureError.unavailableResource }
        let destination = sprites.contents().bindMemory(to: SpriteInstance.self, capacity: slot.spriteCapacity)
        destination[0] = SpriteInstance(center: SIMD2(Float(frame.backgroundCenter.x), Float(frame.backgroundCenter.y)),
                                        size: SIMD2(Float(frame.backgroundSize.width), Float(frame.backgroundSize.height)),
                                        color: SIMD4(repeating: 1))
        for (index, sprite) in frame.sprites.enumerated() {
            destination[index + 1] = SpriteInstance(center: SIMD2(Float(sprite.center.x), Float(sprite.center.y)),
                                                   size: SIMD2(Float(sprite.size.width), Float(sprite.size.height)),
                                                   color: sprite.color)
        }
        let lines = segments.contents().bindMemory(to: SegmentInstance.self, capacity: slot.segmentCapacity)
        for (index, segment) in frame.lines.enumerated() {
            lines[index] = SegmentInstance(start: SIMD2(Float(segment.start.x), Float(segment.start.y)),
                                          end: SIMD2(Float(segment.end.x), Float(segment.end.y)),
                                          bucket: UInt32(segment.bucket))
        }
    }

    private static func capacity(for count: Int) -> Int {
        var value = 64
        while value < count { value *= 2 }
        return value
    }

    private func encode(frame: LiveWallpaperPlexusFrame, slot: Slot, scale: CGFloat,
                        pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass),
              let sprites = slot.sprites, let segments = slot.segments else { throw CaptureError.unavailableResource }
        var uniforms = Uniforms(size: SIMD2(Float(frame.size.width), Float(frame.size.height)), scale: Float(scale))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setVertexBuffer(sprites, offset: 0, index: 0)
        encoder.setFragmentTexture(gradient, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        if !frame.sprites.isEmpty {
            encoder.setRenderPipelineState(additivePipeline)
            encoder.setVertexBuffer(sprites, offset: MemoryLayout<SpriteInstance>.stride, index: 0)
            encoder.setFragmentTexture(glow, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.sprites.count)
        }
        if !frame.lines.isEmpty {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(segments, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.lines.count)
        }
        encoder.endEncoding()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float2 size; float scale; float padding; };
    struct Sprite { float2 center; float2 size; float4 color; };
    struct SpriteOut { float4 position [[position]]; float2 uv; float4 color; };
    vertex SpriteOut spriteVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                  device const Sprite *sprites [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        const float2 corners[6] = {{0,0},{1,0},{0,1},{1,0},{1,1},{0,1}};
        Sprite s = sprites[instance];
        float2 corner = corners[vid];
        float2 point = s.center + (corner - 0.5) * s.size;
        return {float4(point / u.size * 2.0 - 1.0, 0, 1), float2(corner.x, 1.0 - corner.y), s.color};
    }
    fragment float4 spriteFragment(SpriteOut in [[stage_in]], texture2d<float> texture [[texture(0)]],
                                    sampler sample [[sampler(0)]]) {
        float4 texel = texture.sample(sample, in.uv);
        // CGContext glow pixels are premultiplied; tint and node opacity preserve that convention.
        return float4(texel.rgb * in.color.rgb * in.color.a, texel.a * in.color.a);
    }
    struct Segment { float2 start; float2 end; uint bucket; uint padding; };
    struct LineOut { float4 position [[position]]; float transverse; uint bucket [[flat]]; };
    vertex LineOut plexusVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                device const Segment *segments [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        const float2 corners[6] = {{-1,-1},{1,-1},{-1,1},{1,-1},{1,1},{-1,1}};
        Segment s = segments[instance];
        float2 delta = s.end - s.start;
        float length = max(metal::length(delta), 0.00001);
        float2 tangent = delta / length;
        float2 normal(-tangent.y, tangent.x);
        float2 local = corners[vid] * float2(length * 0.5, 1.5);
        float2 point = (s.start + s.end) * 0.5 + tangent * local.x + normal * local.y;
        point.y -= 0.01 / u.scale;
        return {float4(point / u.size * 2.0 - 1.0, 0, 1), local.y, s.bucket};
    }
    fragment float4 plexusFragment(LineOut in [[stage_in]]) {
        float coverage = pow(1.0 - smoothstep(0.0, 1.0, abs(in.transverse)), 1.2);
        float alpha = coverage * (in.bucket == 0 ? 0.22 : (in.bucket == 1 ? 0.14 : 0.07));
        return float4(float3(0.45, 0.85, 1.0) * alpha, alpha);
    }
    """
}
