import AppKit
import MetalKit

/// A single instanced draw replaces the CPU stroke tessellation of the three Plexus paths.
/// SpriteKit still owns the background, particles, animation and cursor physics.
@MainActor
final class LiveWallpaperMetalLineView: MTKView, MTKViewDelegate {
    var onFailure: (() -> Void)?

    private struct GPUPointPair {
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

    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var buffers: [MTLBuffer] = []
    private var busy = [false, false, false]
    private var capacity = 0
    private var logicalSize = CGSize.zero
    private var pendingCount = 0
    private var pendingSlot: Int?
    private var failed = false

    static func make(frame: CGRect) -> LiveWallpaperMetalLineView? {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
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
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        return LiveWallpaperMetalLineView(frame: frame, device: device, commands: commands, pipeline: pipeline)
    }

    private init(frame: CGRect, device: MTLDevice, commands: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.commands = commands
        self.pipeline = pipeline
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        layer?.isOpaque = false
        layer?.backgroundColor = nil
        delegate = self
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(segments: [LiveWallpaperPlexusSegment], logicalSize: CGSize) {
        guard !failed else { return }
        guard !segments.isEmpty, logicalSize.width > 0, logicalSize.height > 0 else { clear(); return }
        // 160 particles have fewer than 13,000 pair/cursor links. Bound pathological input.
        guard segments.count <= 16_384, logicalSize.width.isFinite, logicalSize.height.isFinite else {
            fail(); return
        }
        // Never overwrite memory still being read by the GPU, and never block the scene thread.
        guard let slot = busy.firstIndex(of: false) else { return }
        if segments.count > capacity {
            guard busy.allSatisfy({ !$0 }), let device else { return }
            let nextCapacity = max(512, segments.count.nextPowerOfTwo)
            var replacements: [MTLBuffer] = []
            for _ in 0..<3 {
                guard let buffer = device.makeBuffer(length: nextCapacity * MemoryLayout<GPUPointPair>.stride,
                                                     options: .storageModeShared) else { fail(); return }
                replacements.append(buffer)
            }
            buffers = replacements
            capacity = nextCapacity
        }
        let destination = buffers[slot].contents().bindMemory(to: GPUPointPair.self, capacity: capacity)
        var count = 0
        for segment in segments {
            let start = SIMD2(Float(segment.start.x), Float(segment.start.y))
            let end = SIMD2(Float(segment.end.x), Float(segment.end.y))
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
                  (0..<3).contains(segment.bucket), start != end else { continue }
            destination[count] = GPUPointPair(start: start, end: end, bucket: UInt32(segment.bucket))
            count += 1
        }
        guard count > 0 else { clear(); return }
        self.logicalSize = logicalSize
        pendingCount = count
        pendingSlot = slot
        isHidden = false
        // isPaused + enableSetNeedsDisplay=false: this is the only source of line redraws.
        draw()
    }

    func clear() {
        pendingCount = 0
        pendingSlot = nil
        isHidden = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !failed, pendingCount > 0, let slot = pendingSlot, !busy[slot],
              logicalSize.width > 0, drawableSize.width > 0 else { return }
        // A temporarily unavailable drawable (hidden window/sleep) is not a renderer failure.
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        guard let command = commands.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { fail(); return }
        var uniforms = Uniforms(size: SIMD2(Float(logicalSize.width), Float(logicalSize.height)),
                                scale: Float(drawableSize.width / logicalSize.width))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffers[slot], offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pendingCount)
        encoder.endEncoding()
        busy[slot] = true
        pendingSlot = nil
        command.addCompletedHandler { [weak self] command in
            let error = command.status == .error
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy[slot] = false
                if error { self.fail() }
            }
        }
        command.present(drawable)
        command.commit()
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        clear()
        onFailure?()
    }

    // Internal so the opt-in prototype comparison can render the actual shipping line shader.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Segment { float2 start; float2 end; uint bucket; uint padding; };
    struct Uniforms { float2 size; float scale; float padding; };
    struct VertexOut {
        float4 position [[position]];
        float transverse;
        uint bucket [[flat]];
    };
    vertex VertexOut plexusVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                  device const Segment *segments [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
        const float2 corners[6] = {{-1,-1},{1,-1},{-1,1},{1,-1},{1,1},{-1,1}};
        Segment s = segments[instance];
        float2 delta = s.end - s.start;
        float length = max(metal::length(delta), 0.00001);
        float2 tangent = delta / length;
        float2 normal(-tangent.y, tangent.x);
        float2 local = corners[vid] * float2(length * 0.5, 1.5);
        float2 point = (s.start + s.end) * 0.5 + tangent * local.x + normal * local.y;
        // Match SpriteKit's upper/lower butt-cap raster edge convention at exact pixel centers.
        point.y -= 0.01 / u.scale;
        return {float4(point / u.size * 2.0 - 1.0, 0, 1), local.y, s.bucket};
    }
    fragment float4 plexusFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        // Native SKShapeNode's one-point stroke has a point-space soft fringe, including on
        // Retina displays. This coverage curve matches its edge brightness at both 1x and 2x.
        float coverage = pow(smoothstep(1.0, 0.0, abs(in.transverse)), 1.2);
        float alpha = coverage * (in.bucket == 0 ? 0.22 : (in.bucket == 1 ? 0.14 : 0.07));
        return float4(float3(0.45, 0.85, 1.0) * alpha, alpha);
    }
    """
}

private extension Int {
    var nextPowerOfTwo: Int {
        var result = 1
        while result < self { result *= 2 }
        return result
    }
}
