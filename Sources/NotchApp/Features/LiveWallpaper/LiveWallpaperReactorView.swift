import AppKit
import MetalKit
import OSLog
import QuartzCore

/// A procedural reactor. The GPU owns animation; the CPU submits bounded instanced geometry and one uniform block.
@MainActor
final class LiveWallpaperReactorView: MTKView, MTKViewDelegate {
    var screenFrame = CGRect.zero
    var energy: Double = 0.25
    var settings = LiveWallpaperSceneSettings() {
        didSet { if settings != oldValue, isPaused { draw() } }
    }
    var onFailure: (() -> Void)?
    var presentedFrameCount: Int { presentation.count }

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var cursor: SIMD2<Float>
        var time: Float
        var energy: Float
        var parallax: Float
        var cursorStrength: Float
    }

    private final class Presentation: @unchecked Sendable {
        let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let flarePipeline: MTLRenderPipelineState
    private let orbitalPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let radarPipeline: MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: 3)
    private let presentation = Presentation()
    private var requestedPlaying = false
    private var clockStart: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var hasFailed = false
    private var reducedMotion = false

    static func make(frame: CGRect) -> LiveWallpaperReactorView? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shader, options: nil) }
        catch {
            Logger(subsystem: "com.nool.NotchApp", category: "ReactorWallpaper")
                .error("Unable to compile reactor shader: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "reactorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "reactorFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch {
            Logger(subsystem: "com.nool.NotchApp", category: "ReactorWallpaper")
                .error("Unable to create reactor pipeline: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        descriptor.vertexFunction = library.makeFunction(name: "prominenceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "prominenceFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationAlphaBlendFactor = .one
        guard let flarePipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        func additive(vertex: String, fragment: String) -> MTLRenderPipelineState? {
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            do { return try device.makeRenderPipelineState(descriptor: descriptor) }
            catch {
                Logger(subsystem: "com.nool.NotchApp", category: "ReactorWallpaper")
                    .error("Unable to create \(vertex, privacy: .public) pipeline: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let orbitalPipeline = additive(vertex: "orbitalVertex", fragment: "orbitalFragment"),
              let particlePipeline = additive(vertex: "particleVertex", fragment: "particleFragment"),
              let radarPipeline = additive(vertex: "radarVertex", fragment: "radarFragment") else { return nil }
        return LiveWallpaperReactorView(frame: frame, device: device, queue: queue,
                                       pipeline: pipeline, flarePipeline: flarePipeline,
                                       orbitalPipeline: orbitalPipeline, particlePipeline: particlePipeline,
                                       radarPipeline: radarPipeline)
    }

    private init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue,
                 pipeline: MTLRenderPipelineState, flarePipeline: MTLRenderPipelineState,
                 orbitalPipeline: MTLRenderPipelineState, particlePipeline: MTLRenderPipelineState,
                 radarPipeline: MTLRenderPipelineState) {
        self.queue = queue
        self.pipeline = pipeline
        self.flarePipeline = flarePipeline
        self.orbitalPipeline = orbitalPipeline
        self.particlePipeline = particlePipeline
        self.radarPipeline = radarPipeline
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.002, 0.008, 0.018, 1)
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        isPaused = true
        layer?.isOpaque = true
        delegate = self
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateDrawableScale()
        synchronizeClock()
        if window != nil, isPaused { draw() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableScale()
        if isPaused, window != nil { draw() }
    }

    private func updateDrawableScale() {
        guard window != nil else { return }
        let size = convertToBacking(bounds).size
        if size.width > 0, size.height > 0, drawableSize != size { drawableSize = size }
    }

    @objc private func accessibilityChanged() {
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        synchronizeClock()
        if isPaused, window != nil { draw() }
    }

    func setPlaying(_ playing: Bool) {
        requestedPlaying = playing
        synchronizeClock()
    }

    private func synchronizeClock() {
        let shouldRun = requestedPlaying && window != nil && !hasFailed && !reducedMotion
        if shouldRun, clockStart == nil {
            clockStart = CACurrentMediaTime()
        } else if !shouldRun, let start = clockStart {
            elapsed += max(0, CACurrentMediaTime() - start)
            clockStart = nil
        }
        isPaused = !shouldRun
    }

    private func uniforms(size: CGSize, time: TimeInterval? = nil) -> Uniforms {
        let configuration = settings.sanitized
        let now = elapsed + (clockStart.map { max(0, CACurrentMediaTime() - $0) } ?? 0)
        var cursor = SIMD2<Float>(repeating: 0)
        if configuration.cursorMode != .off, screenFrame.width > 0, screenFrame.height > 0 {
            let point = NSEvent.mouseLocation
            if screenFrame.contains(point) {
                cursor = SIMD2(Float((point.x - screenFrame.midX) / screenFrame.width),
                               Float((point.y - screenFrame.midY) / screenFrame.height))
            }
        }
        let cursorSign: Float = configuration.cursorMode == .repel ? -1 : 1
        // Angular rates are integer multiples of .001, including the environment.
        // A common period keeps Float precision without a visible phase discontinuity.
        let animationTime = (time ?? (reducedMotion ? 0 : now)).truncatingRemainder(dividingBy: 2 * .pi * 1_000)
        return Uniforms(resolution: SIMD2(Float(size.width), Float(size.height)), cursor: cursor,
                        time: Float(animationTime),
                        energy: Float(energy.isFinite ? min(1, max(0, energy)) : 0.25),
                        parallax: reducedMotion ? 0 : Float(configuration.parallax),
                        cursorStrength: reducedMotion ? 0 : Float(configuration.cursorStrength) * cursorSign)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !hasFailed, drawableSize.width > 0, drawableSize.height > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        guard encode(pass: pass, command: command, size: drawableSize) else {
            inFlight.signal()
            fail()
            return
        }
        let inFlight = inFlight
        command.addCompletedHandler { [weak self] command in
            inFlight.signal()
            if command.status == .error { Task { @MainActor [weak self] in self?.fail() } }
        }
        let presentation = presentation
        drawable.addPresentedHandler { _ in presentation.record() }
        command.present(drawable)
        command.commit()
    }

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize,
                        time: TimeInterval? = nil) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = uniforms(size: size, time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(orbitalPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 96 * 6, instanceCount: 5)
        encoder.setRenderPipelineState(particlePipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 96)
        encoder.setRenderPipelineState(flarePipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 32 * 6, instanceCount: 2)
        encoder.setRenderPipelineState(radarPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)
        encoder.endEncoding()
        return true
    }

    private func fail() {
        guard !hasFailed else { return }
        hasFailed = true
        synchronizeClock()
        onFailure?()
    }

    /// Explicit export uses an independent render target and preserves the paused animation time.
    func snapshot() -> CGImage? { capture(at: nil) }

    /// Deterministic visual verification/export; never alters the live or paused animation clock.
    func snapshot(at time: TimeInterval) -> CGImage? {
        guard time.isFinite, time >= 0 else { return nil }
        return capture(at: time)
    }

    private func capture(at time: TimeInterval?) -> CGImage? {
        let size = drawableSize.width > 0 && drawableSize.height > 0 ? drawableSize : bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 16_384, size.height <= 16_384,
              size.width * size.height <= 33_554_432, let device, !hasFailed else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard encode(pass: pass, command: command, size: size, time: time) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                        .union(.byteOrder32Little), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float2 resolution; float2 cursor; float time; float energy; float parallax; float cursorStrength; };
    constant float tau = 6.28318530718;
    constant float3 cyan = float3(0.025, 0.77, 1.0);
    struct Vertex { float4 position [[position]]; float2 p; float3 ray; float3 camera [[flat]]; };
    struct FlareVertex { float4 position [[position]]; float across; float strength [[flat]]; float progress; };

    // One perspective camera is shared by the intersected HUD planes and the true 3D flare ribbons.
    float3x3 cameraBasis(constant Uniforms& u) {
        float yaw = 0.10 + 0.08 * sin(u.time * 0.047) + u.cursor.x * u.parallax * u.cursorStrength * 0.30;
        float pitch = 0.38 + 0.045 * sin(u.time * 0.031) + u.cursor.y * u.parallax * u.cursorStrength * 0.24;
        float sx = sin(pitch), cx = cos(pitch), sy = sin(yaw), cy = cos(yaw);
        return float3x3(float3(cy,0,-sy), float3(sy*sx,cx,cy*sx), float3(sy*cx,-sx,cy*cx));
    }
    vertex Vertex reactorVertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float2 ndc = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
        float2 p = ndc * float2(u.resolution.x / u.resolution.y,1) * 0.5;
        float3x3 basis = cameraBasis(u);
        return { float4(ndc,0,1), p, basis * float3(p,-1.9), basis * float3(0,0,2.6) };
    }
    float hash(float n) { return fract(sin(n * 91.345 + 7.18) * 47453.5453); }
    float arc(float angle, float start, float extent) {
        float x = fract((angle - start) / tau);
        return smoothstep(0.0,0.003,x) * (1.0-smoothstep(extent-0.003,extent,x));
    }
    float ticks(float angle, float count, float duty) {
        float x = fract(angle / tau * count);
        return smoothstep(0.0,0.075,x) * (1.0-smoothstep(duty-0.075,duty,x));
    }
    float emission(float distance, float width, float aa) {
        float d = abs(distance);
        float sharp = 1.0-smoothstep(width,width+aa,d);
        float halo = exp(-d*d/0.000027) * 0.23 + exp(-d*d/0.00022) * 0.048;
        return sharp + halo;
    }
    constant float radii[12] = {0.173,0.187,0.210,0.233,0.248,0.272,0.295,0.317,0.343,0.368,0.391,0.418};
    constant float depths[12] = {0.065,-0.025,0.095,-0.055,0.035,-0.080,0.08,-0.035,0.075,-0.095,0.025,-0.02};
    constant float speeds[12] = {0.052,-0.029,0.041,-0.013,0.018,-0.037,0.027,-0.015,0.011,-0.021,0.014,0.019};
    float3 environment(float2 p, constant Uniforms& u) {
        float t = u.time;
        float r = length(p);
        float2 drift = p + u.cursor*u.parallax*0.014;
        // Broad, moving ion clouds span even ultrawide displays; no texture upload or noise simulation.
        float cloud = sin(drift.x*2.3 + sin(drift.y*3.1+t*0.021)*1.4 + t*0.013);
        cloud += 0.5*sin(drift.x*4.8-drift.y*2.7-t*0.017);
        float fog = smoothstep(-1.2,1.4,cloud);
        float ribbon = exp(-pow((drift.y-0.18*sin(drift.x*1.9+t*0.023))*4.1,2.0));
        float3 color = float3(0.003,0.012,0.025);
        color += float3(0.005,0.035,0.060)*fog*(0.35+0.65*ribbon);
        color += float3(0.003,0.014,0.033)*exp(-abs(drift.y+0.24)*3.0);
        // Two translucent plasma veils at different spatial scales add depth to the broad fog.
        float2 warp = float2(sin(drift.y*2.7+t*0.011),cos(drift.x*1.8-t*0.009))*0.28;
        float veil = sin((drift.x+warp.x)*3.4+t*0.015)*sin((drift.y+warp.y)*3.1-t*0.007);
        veil += 0.34*sin(drift.x*6.7+drift.y*4.3+t*0.019);
        float plasma = pow(smoothstep(-0.65,1.05,veil),2.0);
        float layered = exp(-abs(drift.y-0.14*sin(drift.x*2.2-t*0.017))*1.8);
        color += float3(0.003,0.018,0.052)*plasma*layered;
        float wisps = exp(-pow((veil-0.31)*6.8,2.0));
        color += float3(0.001,0.008,0.021)*wisps*layered;

        // A gently deforming neural lattice: analytic cells keep work bounded at every resolution.
        float2 field = drift*8.0 + float2(sin(t*0.006),cos(t*0.004)-1.0);
        field += float2(sin(drift.y*3.0+t*0.027),sin(drift.x*2.1-t*0.019))*0.18;
        float2 cell = floor(field);
        float2 f = fract(field);
        float2 edge = min(f,1.0-f);
        float aa = 10.0/u.resolution.y;
        float lattice = (1.0-smoothstep(0.002,0.002+aa,min(edge.x,edge.y)))*0.018;
        float diagonal = abs(f.x-f.y)*0.7071;
        float seed = hash(dot(cell,float2(17,83)));
        lattice += (1.0-smoothstep(0.002,0.002+aa,diagonal))*step(0.64,seed)*0.027;
        float2 nearest = floor(field+0.5);
        float nodeSeed = hash(dot(nearest,float2(17,83)));
        float nodeDistance = length(field-nearest);
        float pulse = 0.5+0.5*sin(t*(0.17+floor(nodeSeed*11.0)*0.01)+nodeSeed*tau);
        float nodes = exp(-nodeDistance*nodeDistance/0.0007)*(0.10+0.17*pulse);
        nodes += exp(-nodeDistance*nodeDistance/0.012)*0.025*pulse;
        float outer = smoothstep(0.23,0.43,r);
        color += cyan*(lattice+nodes)*outer;

        // A soft energy wave travels from the reactor across the surrounding field and fades before wrapping.
        float phase = fract(t*0.28/tau);
        float envelope = smoothstep(0.0,0.12,phase)*(1.0-smoothstep(0.72,1.0,phase));
        float waveDistance = r-(0.30+phase*2.5);
        float wave = exp(-waveDistance*waveDistance/0.003)*0.026;
        wave += exp(-waveDistance*waveDistance/0.000025)*0.035;
        color += cyan*wave*envelope*outer;
        // The central aperture stays deep and quiet; telemetry at the sides retains contrast.
        return color*mix(0.24,1.0,smoothstep(0.09,0.19,r));
    }
    fragment float4 reactorFragment(Vertex in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float rScreen = length(in.p);
        float3 color = environment(in.p,u);
        // Only a small central region pays for perspective ring-plane intersections.
        if (rScreen > 0.43) { return float4(color,1); }
        float3 ray = normalize(in.ray);
        float aa = 1.6 / u.resolution.y;
        float breath = 0.94 + 0.06 * sin(u.time*1.35);
        float3 light = 0;
        for (int i=0; i<12; ++i) {
            float fi = float(i);
            // Independent plane normals and genuine depth produce differential perspective/parallax.
            float3 normal = normalize(float3((hash(fi+3)-0.5)*0.11,(hash(fi+8)-0.5)*0.12,1));
            float3 right = normalize(cross(float3(0,1,0),normal));
            float3 up = cross(normal,right);
            float3 origin = float3(0,0,depths[i]);
            float hitTime = dot(origin-in.camera,normal)/dot(ray,normal);
            float3 hit = in.camera + ray*hitTime - origin;
            float2 local = float2(dot(hit,right),dot(hit,up));
            float r = length(local), distance = r-radii[i];
            if (abs(distance) > 0.024) { continue; }
            float a = atan2(local.y,local.x) + u.time*speeds[i];
            float seed = hash(fi+2)*tau;
            float longArc = arc(a,seed,0.37+hash(fi+15)*0.40);
            float shortArc = arc(a,seed+4.8,0.08+hash(fi+20)*0.09);
            float mask = max(longArc,shortArc);
            float width = 0.00055, gain = 0.32;
            if (i == 0) { mask = max(arc(a,0.1,0.80),arc(a,5.6,0.10)); width = 0.0018; gain = 0.94*breath; }
            else if (i == 1) { mask *= ticks(a,95,0.28); width = 0.0022; gain = 0.37; }
            else if (i == 2) {
                // Tiny outlined status cells follow only a partial circumference.
                float cellX = (fract(a/tau*44.0)-0.5)*radii[i]*tau/44.0;
                float2 d = abs(float2(cellX,distance))-float2(0.0051,0.0054);
                float box = length(max(d,0.0)) + min(max(d.x,d.y),0.0);
                light += cyan * emission(box,0.00045,aa) * mask * 0.42;
                continue;
            }
            else if (i == 4) { mask *= ticks(a,128,0.20); width = 0.0025; gain = 0.41; }
            else if (i == 6) { width = 0.0015; gain = 0.73; }
            else if (i == 7) { mask *= ticks(a,55,0.55); width = 0.0018; gain = 0.46; }
            else if (i == 9) { mask *= ticks(a,27,0.58); width = 0.003; gain = 0.60; }
            else if (i == 11) { width = 0.0011; gain = 0.79; }
            float facing = 0.79 + 0.21*clamp(dot(normal,normalize(in.camera)),0.0,1.0);
            float sweep = 0.84 + 0.16*cos(a+fi*1.9);
            light += cyan * emission(distance,width,aa) * mask * gain * facing * sweep;
            // Faint ghost edge reveals a second surface on selected holographic rails.
            if (i == 6 || i == 11) {
                light += cyan * emission(distance+0.004,0.00025,aa) * mask * 0.105;
            }
        }
        // The aperture stays dark and round. Its rim supplies the glow, rather than filling its center.
        color += light * (0.96 + u.energy*0.08);
        color += cyan * exp(-pow((rScreen-0.128)*35.0,2.0))*0.010;
        return float4(clamp(color,0.0,1.0),1);
    }

    float2 project(float3 world, float3x3 basis) {
        float3 local = transpose(basis)*world - float3(0,0,2.6);
        return local.xy * (-1.9/local.z);
    }
    float3 prominencePoint(float s, float phase, float angle, float growth, float t) {
        float3 radial = float3(cos(angle),sin(angle),0);
        float3 tangent = float3(-sin(angle),cos(angle),0);
        float arch = sin(s * tau*0.5);
        float separation = 0.055 + growth*0.017;
        // Footpoints remain anchored; the loop rises outward and toward the camera in actual XYZ space.
        float3 point = radial*(0.292+arch*growth*0.168) + tangent*(cos(s*tau*0.5)*separation);
        point.z = 0.025 + arch*(0.035+growth*0.18);
        point += tangent * sin(s*tau*2.0+t*0.9)*arch*growth*0.006;
        return point;
    }
    vertex FlareVertex prominenceVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                         constant Uniforms& u [[buffer(0)]]) {
        float rate = instance == 0 ? 0.36 : 0.24;
        float offset = instance == 0 ? 0.67 : 0.34;
        float cycle = u.time*rate/tau + offset;
        float phase = fract(cycle);
        if (phase >= 0.23) { return {float4(3,3,0,1),0,0,0}; }
        float progress = phase/0.23;
        float life = smoothstep(0.0,0.18,progress)*(1.0-smoothstep(0.66,1.0,progress));
        float growth = smoothstep(0.0,0.62,progress);
        float angle = (instance == 0 ? 0.79 : 3.95) + hash(floor(cycle)+float(instance)*71.0)*1.1;
        uint segment = id/6;
        uint corner = id%6;
        bool end = corner == 1 || corner == 2 || corner == 4;
        float side = corner == 0 || corner == 1 || corner == 3 ? -1.0 : 1.0;
        float s0 = float(segment)/32.0, s1 = float(segment+1)/32.0;
        float3x3 basis = cameraBasis(u);
        float2 a = project(prominencePoint(s0,phase,angle,growth,u.time),basis);
        float2 b = project(prominencePoint(s1,phase,angle,growth,u.time),basis);
        float2 direction = normalize(b-a);
        float2 normal = float2(-direction.y,direction.x);
        float halfWidth = 0.009;
        float2 p = (end ? b : a) + normal*side*halfWidth;
        float2 ndc = p*float2(2.0*u.resolution.y/u.resolution.x,2.0);
        float strength = life*(0.84+u.energy*0.16);
        return {float4(ndc,0,1),side*halfWidth,strength,end ? s1 : s0};
    }
    fragment float4 prominenceFragment(FlareVertex in [[stage_in]]) {
        float d = abs(in.across);
        float filament = exp(-d*d/0.00000072)*0.88;
        float halo = exp(-d*d/0.000012)*0.27 + exp(-d*d/0.000045)*0.075;
        float taper = 0.48 + 0.52*sin(in.progress*tau*0.5);
        return float4(cyan * (filament+halo) * in.strength * taper,0);
    }

    // The sphere's rails are instanced 3D circles in five differently inclined planes.
    // Only their narrow ribbons shade pixels; there are no sphere/particle loops in the fullscreen pass.
    struct OrbitalVertex { float4 position [[position]]; float across; float visibility; float phase; float radius; };
    constant float inclinations[5] = {0.64,1.10,-0.93,0.30,-1.35};
    constant float orbitalYaws[5] = {0.18,1.27,2.11,-0.64,0.83};
    float3 orbitPoint(float angle, uint instance, float time) {
        float tilt = inclinations[instance];
        float yaw = orbitalYaws[instance] + time*(instance%2 == 0 ? 0.005 : -0.007);
        float r = 0.485+float(instance)*0.004;
        float3 p = float3(cos(angle)*r,sin(angle)*r,0);
        p = float3(p.x,p.y*cos(tilt),p.y*sin(tilt));
        return float3(p.x*cos(yaw)+p.z*sin(yaw),p.y,-p.x*sin(yaw)+p.z*cos(yaw));
    }
    vertex OrbitalVertex orbitalVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                       constant Uniforms& u [[buffer(0)]]) {
        uint segment = id/6, corner = id%6;
        bool end = corner == 1 || corner == 2 || corner == 4;
        float side = corner == 0 || corner == 1 || corner == 3 ? -1.0 : 1.0;
        float phase0 = float(segment)/96.0, phase1 = float(segment+1)/96.0;
        float turn = u.time*(0.011+float(instance)*0.002);
        float3 a3 = orbitPoint(phase0*tau+turn,instance,u.time);
        float3 b3 = orbitPoint(phase1*tau+turn,instance,u.time);
        float3x3 basis = cameraBasis(u);
        float2 a = project(a3,basis), b = project(b3,basis);
        float2 direction = (b-a)/max(length(b-a),0.00001);
        float2 normal = float2(-direction.y,direction.x);
        float halfWidth = 0.005;
        float2 p = (end ? b : a)+normal*side*halfWidth;
        float3 world = end ? b3 : a3;
        float visibility = mix(0.036,0.16,smoothstep(-0.25,0.38,world.z));
        return {float4(p*float2(2.0*u.resolution.y/u.resolution.x,2),0,1),
                side*halfWidth,visibility,end ? phase1 : phase0,length(p)};
    }
    fragment float4 orbitalFragment(OrbitalVertex in [[stage_in]]) {
        float d = abs(in.across);
        float sharp = exp(-d*d/0.00000032);
        float halo = exp(-d*d/0.000005)*0.23;
        float dash = 0.68+0.32*ticks(in.phase*tau,64,0.23);
        // Leave the dark central aperture unobstructed; near and far hemispheres differ in brightness.
        float aperture = smoothstep(0.132,0.162,in.radius);
        return float4(cyan*(sharp+halo)*in.visibility*dash*aperture,0);
    }

    struct ParticleVertex { float4 position [[position]]; float2 uv; float strength [[flat]]; float radius; };
    constant float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(1,1),
                                  float2(-1,-1),float2(1,1),float2(-1,1)};
    float2 quadCorner(uint id) {
        return corners[id];
    }
    float3 streamPoint(float phase, float angle, float seed, bool burst) {
        float r = burst ? mix(0.205,0.89,phase) : mix(0.72,0.183,phase);
        float turn = angle+(burst ? -0.12 : 0.25)*phase;
        return float3(cos(turn)*r,sin(turn)*r,(seed-0.5)*0.24+sin(phase*tau*0.5)*0.08);
    }
    vertex ParticleVertex particleVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                         constant Uniforms& u [[buffer(0)]]) {
        float seed = hash(float(instance)+83.0);
        bool burst = instance >= 72;
        float phase, strength;
        if (burst) {
            float wave = fract(u.time*0.28/tau);
            phase = (wave-0.018)/0.23;
            if (phase <= 0.0 || phase >= 1.0) { return {float4(3,3,0,1),0,0,0}; }
            strength = sin(phase*tau*0.5)*(0.18+seed*0.30);
        } else {
            float rate = 0.27+floor(hash(float(instance)+2.0)*8.0)*0.02;
            phase = fract(u.time*rate/tau+seed);
            strength = pow(max(0.0,sin(phase*tau*0.5)),1.5)*(0.10+seed*0.26);
        }
        float angle = seed*tau + u.time*(burst ? 0.003 : -0.005);
        float3x3 basis = cameraBasis(u);
        float2 p = project(streamPoint(phase,angle,seed,burst),basis);
        float2 previous = project(streamPoint(max(0.0,phase-0.028),angle,seed,burst),basis);
        float2 direction = (p-previous)/max(length(p-previous),0.00001);
        float2 normal = float2(-direction.y,direction.x);
        float2 uv = quadCorner(id);
        float halfLength = burst ? 0.009 : 0.006;
        float2 position = p+direction*uv.y*halfLength+normal*uv.x*0.0032;
        return {float4(position*float2(2.0*u.resolution.y/u.resolution.x,2),0,1),
                uv,strength,length(p)};
    }
    fragment float4 particleFragment(ParticleVertex in [[stage_in]]) {
        float glow = exp(-in.uv.x*in.uv.x*4.5-in.uv.y*in.uv.y*1.9);
        float halo = exp(-dot(in.uv,in.uv)*2.0)*0.19;
        float edge = (1.0-smoothstep(0.72,1.0,abs(in.uv.x)))*(1.0-smoothstep(0.72,1.0,abs(in.uv.y)));
        float aperture = smoothstep(0.131,0.158,in.radius);
        return float4(cyan*(glow+halo)*in.strength*edge*aperture,0);
    }

    struct RadarVertex { float4 position [[position]]; float2 local; float time [[flat]]; float side [[flat]]; };
    vertex RadarVertex radarVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]]) {
        float aspect = u.resolution.x/u.resolution.y;
        float side = instance == 0 ? -1.0 : 1.0;
        float radius = min(0.070,aspect*0.048);
        float2 local = quadCorner(id)*1.08;
        float2 center = float2(side*aspect*0.30,0.30);
        float2 p = center+local*radius;
        return {float4(p*float2(2.0/aspect,2),0,1),local,u.time,side};
    }
    fragment float4 radarFragment(RadarVertex in [[stage_in]]) {
        float r = length(in.local);
        if (r > 1.07) { return float4(0); }
        float a = atan2(in.local.y,in.local.x);
        float sweep = in.time*(in.side < 0 ? 0.18 : -0.13)+in.side*0.7;
        float age = fract((sweep-a)/tau);
        float disc = 1.0-smoothstep(0.97,1.02,r);
        float light = exp(-pow((r-0.98)*110.0,2.0))*0.35;
        light += (exp(-pow((r-0.66)*130.0,2.0))+exp(-pow((r-0.33)*130.0,2.0)))*0.10;
        light += exp(-pow((r-0.92)*85.0,2.0))*ticks(a,60,0.18)*0.24;
        light += (exp(-in.local.x*in.local.x*18000.0)+exp(-in.local.y*in.local.y*18000.0))*0.07*disc;
        light += exp(-age*24.0)*0.085*disc;
        float line = abs(sin(a-sweep))*r;
        light += exp(-line*line/0.000085)*step(0.0,cos(a-sweep))*0.42*disc;
        // Five local return targets. Their motion and brightness follow the scanner, never the OS/network.
        for (int i=0; i<5; ++i) {
            float seed = hash(float(i)+in.side*17.0);
            float angle = seed*tau+in.time*(0.009+float(i)*0.002)*in.side;
            float radius = 0.20+hash(float(i)+11.0)*0.56+0.025*sin(in.time*0.021+seed*tau);
            float2 target = float2(cos(angle),sin(angle))*radius;
            float d = distance(in.local,target);
            float returnAge = fract((sweep-angle)/tau);
            float gain = 0.18+0.65*exp(-returnAge*5.5);
            light += (exp(-d*d/0.00042)+exp(-d*d/0.0036)*0.18)*gain;
        }
        return float4(cyan*light,0);
    }
    """#
}
