import AppKit
import CoreGraphics
import Metal
import QuartzCore

struct DisplayExtraBrightnessCapability: Equatable, Sendable {
    let isSupported: Bool
    let isEnabled: Bool
    let unavailableReason: String?
}

@MainActor
protocol DisplayExtraBrightnessServing: AnyObject {
    var onStateChange: (@MainActor () -> Void)? { get set }
    func capability(for target: DisplayHardwareTarget) -> DisplayExtraBrightnessCapability
    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) throws
    func stop()
    func reconcile(_ targets: [DisplayHardwareTarget])
}

enum DisplayExtraBrightnessError: LocalizedError {
    case unavailable, disconnected, renderingFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Дополнительная яркость недоступна на этом дисплее."
        case .disconnected: "Дисплей отключён или изменился."
        case .renderingFailed: "Дополнительная яркость выключена: macOS не подтвердила вывод изображения. Перезапустите NooL, чтобы повторить."
        }
    }
}

struct DisplayExtraBrightnessScreen: Equatable {
    let target: DisplayHardwareTarget
    let frame: CGRect
    let potentialHeadroom: Double
    let currentHeadroom: Double
}

struct DisplayExtraBrightnessPresentationHealth {
    let startedAt: TimeInterval
    private(set) var lastPresentedAt: TimeInterval?

    mutating func presented(at time: TimeInterval) { lastPresentedAt = time }
    func hasExpired(at time: TimeInterval, latestWorkerPresentation: TimeInterval? = nil) -> Bool {
        time - (latestWorkerPresentation ?? lastPresentedAt ?? startedAt) >= 0.65
    }
}

@MainActor
protocol DisplayExtraBrightnessRendering: AnyObject {
    var hasPendingWork: Bool { get }
    func start() throws
    func close()
}

extension DisplayExtraBrightnessRendering { var hasPendingWork: Bool { false } }

/// The compositor scales desktop content into EDR; this never writes gamma or hardware brightness.
@MainActor
final class MetalDisplayExtraBrightnessService: DisplayExtraBrightnessServing {
    typealias ScreenLookup = @MainActor (DisplayHardwareTarget) -> DisplayExtraBrightnessScreen?
    typealias OverlayFactory = @MainActor (DisplayExtraBrightnessScreen, Double,
        @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) throws -> any DisplayExtraBrightnessRendering

    var onStateChange: (@MainActor () -> Void)?
    private let screenLookup: ScreenLookup
    private let makeOverlay: OverlayFactory
    private let metalAvailable: Bool
    private let gain: Double
    private var capabilities: [String: DisplayExtraBrightnessCapability] = [:]
    private var targets: [String: DisplayHardwareTarget] = [:]
    private var overlays: [String: any DisplayExtraBrightnessRendering] = [:]
    private var retiredOverlays: [String: any DisplayExtraBrightnessRendering] = [:]
    private var generations: [String: UUID] = [:]
    private var blockedTargets: Set<String> = []
    private(set) var presentedFrameCount = 0

    init(gain: Double = 1.25) {
        let device = MTLCreateSystemDefaultDevice()
        self.gain = gain.isFinite ? min(1.25, max(1, gain)) : 1.25
        metalAvailable = device != nil
        screenLookup = Self.liveScreen
        makeOverlay = { screen, factor, presented, failed in
            guard let device else { throw DisplayExtraBrightnessError.unavailable }
            return try DisplayExtraBrightnessOverlay(screen: screen, gain: factor, device: device,
                screenLookup: Self.liveScreen, presented: presented, failed: failed)
        }
    }

    init(gain: Double = 1.25, metalAvailable: Bool = true, screenLookup: @escaping ScreenLookup,
         makeOverlay: @escaping OverlayFactory) {
        self.gain = gain.isFinite ? min(1.25, max(1, gain)) : 1.25
        self.metalAvailable = metalAvailable
        self.screenLookup = screenLookup
        self.makeOverlay = makeOverlay
    }

    func capability(for target: DisplayHardwareTarget) -> DisplayExtraBrightnessCapability {
        guard targets[target.uuid] == target, let capability = capabilities[target.uuid] else {
            return .init(isSupported: false, isEnabled: false, unavailableReason: "Проверяем доступность…")
        }
        return capability
    }

    func reconcile(_ current: [DisplayHardwareTarget]) {
        retiredOverlays = retiredOverlays.filter { $0.value.hasPendingWork }
        let counts = Dictionary(grouping: current, by: \.uuid).mapValues(\.count)
        let valid = current.filter { !$0.uuid.isEmpty && counts[$0.uuid] == 1 }
        let next = Dictionary(uniqueKeysWithValues: valid.map { ($0.uuid, $0) })
        for (uuid, old) in targets where next[uuid] != old { remove(uuid) }
        targets = next
        capabilities = capabilities.filter { next[$0.key] != nil }
        for target in valid {
            let enabled = capabilities[target.uuid]?.isEnabled == true && overlays[target.uuid] != nil
            let eligibility = eligibility(for: target)
            if !eligibility.isSupported { remove(target.uuid) }
            capabilities[target.uuid] = .init(isSupported: eligibility.isSupported,
                isEnabled: eligibility.isSupported && enabled, unavailableReason: eligibility.unavailableReason)
        }
        onStateChange?()
    }

    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) throws {
        guard enabled else {
            remove(target.uuid)
            if let old = capabilities[target.uuid] {
                capabilities[target.uuid] = .init(isSupported: old.isSupported, isEnabled: false, unavailableReason: old.unavailableReason)
            }
            onStateChange?()
            return
        }
        guard targets[target.uuid] == target, let screen = screenLookup(target) else { throw DisplayExtraBrightnessError.disconnected }
        if let retired = retiredOverlays[target.uuid] {
            guard !retired.hasPendingWork else { throw DisplayExtraBrightnessError.renderingFailed }
            retiredOverlays.removeValue(forKey: target.uuid)
        }
        guard eligibility(for: target).isSupported else { throw DisplayExtraBrightnessError.unavailable }
        // A second click while the first presentation is pending must not create another surface.
        guard overlays[target.uuid] == nil else { return }
        let uuid = target.uuid, generation = UUID()
        generations[uuid] = generation
        let overlay = try makeOverlay(screen, min(gain, screen.potentialHeadroom), { [weak self] in
            guard let self, self.generations[uuid] == generation, self.overlays[uuid] != nil else { return }
            self.presentedFrameCount += 1
            guard self.capabilities[uuid]?.isEnabled != true else { return }
            self.capabilities[uuid] = .init(isSupported: true, isEnabled: true, unavailableReason: nil)
            self.onStateChange?()
        }, { [weak self] in
            guard let self, self.generations[uuid] == generation else { return }
            self.remove(uuid)
            // A blocked native drawable can outlive its hidden window. Never start replacement
            // workers for this display in this service instance after a rendering failure.
            self.blockedTargets.insert(uuid)
            self.capabilities[uuid] = .init(isSupported: false, isEnabled: false,
                unavailableReason: DisplayExtraBrightnessError.renderingFailed.localizedDescription)
            self.onStateChange?()
        })
        overlays[uuid] = overlay
        do { try overlay.start() }
        catch { remove(uuid); throw error }
    }

    func stop() {
        for uuid in Array(overlays.keys) { remove(uuid) }
        for (uuid, old) in capabilities {
            capabilities[uuid] = .init(isSupported: old.isSupported, isEnabled: false, unavailableReason: old.unavailableReason)
        }
        onStateChange?()
    }

    private func remove(_ uuid: String) {
        generations.removeValue(forKey: uuid)
        if let overlay = overlays.removeValue(forKey: uuid) {
            overlay.close()
            if overlay.hasPendingWork { retiredOverlays[uuid] = overlay }
        }
    }

    private func eligibility(for target: DisplayHardwareTarget) -> DisplayExtraBrightnessCapability {
        guard !blockedTargets.contains(target.uuid) else {
            return .init(isSupported: false, isEnabled: false, unavailableReason: DisplayExtraBrightnessError.renderingFailed.localizedDescription)
        }
        guard metalAvailable else { return .init(isSupported: false, isEnabled: false, unavailableReason: "Metal недоступен") }
        guard let screen = screenLookup(target) else { return .init(isSupported: false, isEnabled: false, unavailableReason: "Дисплей отключён или изменился") }
        guard screen.potentialHeadroom.isFinite, screen.potentialHeadroom > 1.05 else {
            return .init(isSupported: false, isEnabled: false, unavailableReason: screen.target.isBuiltin
                ? "Дисплей не предоставляет запас яркости XDR"
                : "Включите HDR для этого дисплея. Требуется HDR-дисплей.")
        }
        return .init(isSupported: true, isEnabled: false, unavailableReason: nil)
    }

    static func liveScreen(_ target: DisplayHardwareTarget) -> DisplayExtraBrightnessScreen? {
        guard target.displayID != 0, CGDisplayIsActive(target.displayID) != 0,
              (CGDisplayIsBuiltin(target.displayID) != 0) == target.isBuiltin,
              let nativeUUID = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, nativeUUID),
              (text as String).caseInsensitiveCompare(target.uuid) == .orderedSame,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
              }), screen.frame.width > 0, screen.frame.height > 0 else { return nil }
        return .init(target: target, frame: screen.frame,
            potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
            currentHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue))
    }
}

private final class ExtraBrightnessWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DisplayExtraBrightnessOverlay: DisplayExtraBrightnessRendering {
    var hasPendingWork: Bool { renderer.hasPendingWork }
    var presentedFrameCount: Int { renderer.presentationSnapshot.count }
    private let screenLookup: MetalDisplayExtraBrightnessService.ScreenLookup
    private let target: DisplayHardwareTarget
    private let presented: @MainActor () -> Void
    private let failed: @MainActor () -> Void
    private let window: ExtraBrightnessWindow
    private let layer: CAMetalLayer
    private let renderer: ExtraBrightnessMetalRenderer
    private var timer: Timer?
    private var health = DisplayExtraBrightnessPresentationHealth(startedAt: 0)
    private var closed = false
    private var revealed = false

    init(screen: DisplayExtraBrightnessScreen, gain: Double, device: any MTLDevice,
         screenLookup: @escaping MetalDisplayExtraBrightnessService.ScreenLookup,
         presented: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) throws {
        guard let queue = device.makeCommandQueue() else { throw DisplayExtraBrightnessError.renderingFailed }
        self.target = screen.target
        self.screenLookup = screenLookup; self.presented = presented; self.failed = failed
        window = ExtraBrightnessWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear; window.isOpaque = false
        window.ignoresMouseEvents = true; window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0
        layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.compositingFilter = "multiply"
        layer.drawableSize = CGSize(width: 1, height: 1)
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 2
        layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        renderer = ExtraBrightnessMetalRenderer(layer: layer, commands: queue,
            factor: min(gain, max(1, screen.potentialHeadroom)))
        let host = NSView(frame: layer.frame)
        host.wantsLayer = true; host.layer = layer
        window.contentView = host
    }

    func start() throws {
        guard !closed, screenLookup(target) != nil else { throw DisplayExtraBrightnessError.disconnected }
        health = .init(startedAt: ProcessInfo.processInfo.systemUptime)
        window.orderFrontRegardless()
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        startRendering()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.invalidate(); timer = nil
        renderer.stop()
        window.orderOut(nil)
        window.close()
        window.contentView?.layer = nil
    }

    private func tick() {
        guard !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // No fallback reveal: a missing first presentation leaves the surface invisible.
        guard !health.hasExpired(at: now, latestWorkerPresentation: renderer.presentationSnapshot.time) else { fail(); return }
        guard let screen = screenLookup(target) else { fail(); return }
        updateFrame(screen.frame)
    }

    private func fail() { close(); failed() }

    private func updateFrame(_ frame: CGRect) {
        if window.frame != frame {
            // Never leave a fullscreen surface over a neighboring display after rearrangement.
            window.setFrame(frame, display: false)
            layer.frame = CGRect(origin: .zero, size: frame.size)
        }
    }

    private func startRendering() {
        renderer.start(presented: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if !self.revealed {
                    self.revealed = true
                    self.window.alphaValue = 1
                }
                self.presented()
            }
        }, failed: { [weak self] in Task { @MainActor [weak self] in self?.fail() } })
    }
}

/// nextDrawable can wait inside the graphics driver. Keep it off the main queue so
/// the main-run-loop watchdog can always hide a stalled surface synchronously.
private final class ExtraBrightnessMetalRenderer: @unchecked Sendable {
    private let work = DispatchQueue(label: "app.nool.extra-brightness-render", qos: .userInteractive)
    private let layer: CAMetalLayer
    private let commands: any MTLCommandQueue
    private let factor: Double
    private let cadence: any DispatchSourceTimer
    private let lock = NSLock()
    private var pendingWork = false
    private var stopped = false
    private var lastPresentedAt: TimeInterval?
    private var presentedFrames = 0

    var hasPendingWork: Bool { lock.lock(); defer { lock.unlock() }; return pendingWork }
    private func setPending(_ value: Bool) { lock.lock(); pendingWork = value; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var presentationSnapshot: (time: TimeInterval?, count: Int) {
        lock.lock(); defer { lock.unlock() }; return (lastPresentedAt, presentedFrames)
    }
    private func recordPresentation() {
        lock.lock(); lastPresentedAt = ProcessInfo.processInfo.systemUptime; presentedFrames += 1; lock.unlock()
    }

    init(layer: CAMetalLayer, commands: any MTLCommandQueue, factor: Double) {
        self.layer = layer; self.commands = commands; self.factor = factor
        cadence = DispatchSource.makeTimerSource(queue: work)
        cadence.schedule(deadline: .distantFuture)
        cadence.resume()
    }

    deinit { cadence.cancel() }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        cadence.cancel()
    }

    func start(presented: @escaping @Sendable () -> Void, failed: @escaping @Sendable () -> Void) {
        cadence.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, !self.pendingWork else { self.lock.unlock(); return }
            self.pendingWork = true
            self.lock.unlock()
            // The worker cadence keeps WindowServer compositing even during an unrelated
            // main-thread stall. stop() cancels it before AppKit removes the window.
            guard let drawable = layer.nextDrawable(), let command = commands.makeCommandBuffer() else { setPending(false); failed(); return }
            guard !isStopped else { setPending(false); return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: factor, green: factor, blue: factor, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { setPending(false); failed(); return }
            encoder.endEncoding()
            guard !isStopped else { setPending(false); return }
            drawable.addPresentedHandler { [self] _ in recordPresentation(); presented() }
            command.addCompletedHandler { [self] in setPending(false); if $0.status == .error { failed() } }
            command.present(drawable)
            command.commit()
        }
        cadence.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(10))
    }
}
