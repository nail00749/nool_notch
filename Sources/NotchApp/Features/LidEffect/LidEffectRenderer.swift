import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
@preconcurrency import ScreenCaptureKit

@MainActor
protocol LidEffectRendering: AnyObject {
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func start(screen: NSScreen) async throws
    func update(progress: Double, blurRadius: Double, dimming: Double)
    func stop() async
}

enum LidEffectRendererError: LocalizedError {
    case builtInDisplayUnavailable
    case displayNotFound
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .builtInDisplayUnavailable:
            "Эффект крышки доступен только для встроенного дисплея."
        case .displayNotFound:
            "Не удалось найти встроенный дисплей для захвата."
        case .captureUnavailable:
            "Не удалось получить кадр встроенного дисплея."
        }
    }
}

@MainActor
final class ScreenLidEffectRenderer: LidEffectRendering {
    var onFailure: (@MainActor (String) -> Void)?

    private var panel: LidEffectPanel?
    private var contentView: LidEffectContentView?
    private var stream: SCStream?
    private var frameOutput: LidEffectFrameOutput?
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0
    private var progress = 0.0
    private var blurRadius = 0.0
    private var dimming = 0.0
    private var hasPresentedFrame = false

    init() {}

    func start(screen: NSScreen) async throws {
        await stop()
        try Task.checkCancellation()

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID,
              CGDisplayIsBuiltin(displayID) != 0 else {
            throw LidEffectRendererError.builtInDisplayUnavailable
        }

        generation += 1
        let currentGeneration = generation
        preparePanel(for: screen)

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            try Task.checkCancellation()
            guard currentGeneration == generation else { throw CancellationError() }
            guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                throw LidEffectRendererError.displayNotFound
            }

            let ownApplications = shareableContent.applications.filter { application in
                application.processID == getpid()
                    || application.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            guard !ownApplications.isEmpty else {
                throw LidEffectRendererError.captureUnavailable
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = Self.captureConfiguration(for: display)
            let output = LidEffectFrameOutput(
                onFrame: { [weak self] image in
                    self?.present(image, generation: currentGeneration)
                },
                onClear: { [weak self] in
                    guard let self, currentGeneration == self.generation else { return }
                    self.hideAndClear()
                },
                onError: { [weak self] message in
                    await self?.handleCaptureFailure(message, generation: currentGeneration)
                }
            )
            let captureStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: output
            )
            try captureStream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: output.captureQueue
            )

            frameOutput = output
            stream = captureStream
            output.update(progress: progress, blurRadius: blurRadius, dimming: dimming)
            try await captureStream.startCapture()
            try Task.checkCancellation()
            guard currentGeneration == generation else { throw CancellationError() }

            output.markCaptureStarted()
            startWatchdog(generation: currentGeneration)
        } catch {
            if currentGeneration == generation {
                hideAndClear()
                frameOutput?.invalidate()
                if let stream {
                    try? await stream.stopCapture()
                    if let frameOutput {
                        try? stream.removeStreamOutput(frameOutput, type: .screen)
                    }
                }
                stream = nil
                frameOutput = nil
                if !(error is CancellationError) {
                    onFailure?(error.localizedDescription)
                }
            }
            throw error
        }
    }

    func update(progress: Double, blurRadius: Double, dimming: Double) {
        let normalizedProgress = min(max(progress, 0), 1)
        self.progress = normalizedProgress
        self.blurRadius = min(max(blurRadius, 0), 80)
        self.dimming = min(max(dimming, 0), 1)
        frameOutput?.update(
            progress: normalizedProgress,
            blurRadius: self.blurRadius,
            dimming: self.dimming
        )

        guard normalizedProgress > 0 else {
            hideAndClear()
            return
        }
        if hasPresentedFrame, contentView?.layer?.contents != nil {
            panel?.orderFrontRegardless()
        }
    }

    func stop() async {
        generation += 1
        watchdogTask?.cancel()
        watchdogTask = nil
        hideAndClear()

        let activeStream = stream
        let activeOutput = frameOutput
        stream = nil
        frameOutput = nil
        activeOutput?.invalidate()

        if let activeStream {
            do {
                try await activeStream.stopCapture()
            } catch {
                // A stopped or permission-revoked stream is already safe to release.
            }
            if let activeOutput {
                try? activeStream.removeStreamOutput(activeOutput, type: .screen)
            }
        }
    }

    private func preparePanel(for screen: NSScreen) {
        let panel: LidEffectPanel
        let view: LidEffectContentView
        if let existingPanel = self.panel, let existingView = contentView {
            panel = existingPanel
            view = existingView
        } else {
            panel = LidEffectPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            view = LidEffectContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            self.panel = panel
            contentView = view
        }

        panel.setFrame(screen.frame, display: false)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isReleasedWhenClosed = false
        panel.orderOut(nil)
        view.layer?.contents = nil
        hasPresentedFrame = false
    }

    private func present(_ image: CGImage, generation frameGeneration: Int) {
        guard frameGeneration == generation, stream != nil else { return }
        guard progress > 0 else {
            hideAndClear()
            return
        }
        contentView?.layer?.contents = image
        hasPresentedFrame = true
        panel?.orderFrontRegardless()
    }

    private func hideAndClear() {
        panel?.orderOut(nil)
        contentView?.layer?.contents = nil
        hasPresentedFrame = false
    }

    private func startWatchdog(generation watchdogGeneration: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self,
                      watchdogGeneration == generation,
                      stream != nil else { return }
                guard progress > 0 else { continue }
                if frameOutput?.hasRecentCaptureHeartbeat(maxAge: .seconds(1)) != true {
                    await handleCaptureFailure(
                        "Поток встроенного дисплея перестал передавать кадры.",
                        generation: watchdogGeneration
                    )
                    return
                }
            }
        }
    }

    private func handleCaptureFailure(_ message: String, generation failedGeneration: Int) async {
        guard failedGeneration == generation, stream != nil else { return }
        hideAndClear()
        onFailure?(message)
        await stop()
    }

    private static func captureConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1_920 / CGFloat(max(display.width, 1)))
        configuration.width = max(1, Int(CGFloat(display.width) * scale))
        configuration.height = max(1, Int(CGFloat(display.height) * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }
}

private final class LidEffectPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LidEffectContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private struct LidEffectParameters: Sendable {
    var progress = 0.0
    var blurRadius = 0.0
    var dimming = 0.0
}

private final class LidEffectFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let captureQueue = DispatchQueue(label: "com.nailuyltyev.NotchApp.lid-effect.capture", qos: .userInteractive)

    private let lock = NSLock()
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let onFrame: @MainActor @Sendable (CGImage) -> Void
    private let onClear: @MainActor @Sendable () -> Void
    private let onError: @MainActor @Sendable (String) async -> Void
    private var parameters = LidEffectParameters()
    private var isActive = true
    private var deliveryScheduled = false
    private var pendingImage: CGImage?
    private var pendingClear = false
    private var cachedPixelBuffer: CVPixelBuffer?
    private var lastCaptureHeartbeat: ContinuousClock.Instant?
    private var failureDelivered = false
    private var rerenderScheduled = false
    private var needsRerender = false

    init(
        onFrame: @escaping @MainActor @Sendable (CGImage) -> Void,
        onClear: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (String) async -> Void
    ) {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false
            ])
        }
        self.onFrame = onFrame
        self.onClear = onClear
        self.onError = onError
        super.init()
    }

    func update(progress: Double, blurRadius: Double, dimming: Double) {
        lock.lock()
        parameters = LidEffectParameters(
            progress: progress,
            blurRadius: blurRadius,
            dimming: dimming
        )
        if progress <= 0 {
            pendingImage = nil
            needsRerender = false
        } else {
            needsRerender = true
        }
        let shouldSchedule = progress > 0 && !rerenderScheduled
        if shouldSchedule { rerenderScheduled = true }
        lock.unlock()
        if shouldSchedule {
            captureQueue.async { [weak self] in self?.performScheduledRerender() }
        }
    }

    func markCaptureStarted() {
        lock.lock()
        if isActive { lastCaptureHeartbeat = .now }
        lock.unlock()
    }

    func hasRecentCaptureHeartbeat(maxAge: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, let lastCaptureHeartbeat else { return false }
        return lastCaptureHeartbeat.duration(to: .now) <= maxAge
    }

    func invalidate() {
        lock.lock()
        isActive = false
        pendingImage = nil
        pendingClear = false
        cachedPixelBuffer = nil
        lastCaptureHeartbeat = nil
        rerenderScheduled = false
        needsRerender = false
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        deliverFailure(error.localizedDescription)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid,
              let status = frameStatus(sampleBuffer) else { return }

        switch status {
        case .complete:
            guard let pixelBuffer = sampleBuffer.imageBuffer else {
                clearCachedFrame()
                return
            }
            lock.lock()
            guard isActive else {
                lock.unlock()
                return
            }
            cachedPixelBuffer = pixelBuffer
            lastCaptureHeartbeat = .now
            lock.unlock()
            renderCachedFrame()
        case .idle, .started:
            lock.lock()
            if isActive { lastCaptureHeartbeat = .now }
            lock.unlock()
        case .blank, .suspended, .stopped:
            clearCachedFrame()
        @unknown default:
            clearCachedFrame()
        }
    }

    private func renderCachedFrame() {
        let pixelBuffer: CVPixelBuffer
        let effects: LidEffectParameters
        lock.lock()
        guard isActive, parameters.progress > 0, let cachedPixelBuffer else {
            lock.unlock()
            return
        }
        pixelBuffer = cachedPixelBuffer
        effects = parameters
        lock.unlock()

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard !source.extent.isEmpty else { return }
        let blur = effects.blurRadius * effects.progress
        let dimming = min(max(effects.dimming * effects.progress, 0), 1)
        let blurred: CIImage
        if blur > 0.01 {
            blurred = source
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
                .cropped(to: source.extent)
        } else {
            blurred = source
        }
        let output: CIImage
        if dimming > 0.001 {
            output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: dimming))
                .cropped(to: source.extent)
                .composited(over: blurred)
        } else {
            output = blurred
        }
        guard let image = context.createCGImage(
            output,
            from: source.extent,
            format: .BGRA8,
            colorSpace: colorSpace
        ) else { return }
        enqueueForDelivery(image)
    }

    private func performScheduledRerender() {
        lock.lock()
        guard isActive else {
            rerenderScheduled = false
            needsRerender = false
            lock.unlock()
            return
        }
        needsRerender = false
        lock.unlock()

        renderCachedFrame()

        lock.lock()
        let shouldContinue = isActive && needsRerender
        if !shouldContinue { rerenderScheduled = false }
        lock.unlock()
        if shouldContinue {
            captureQueue.async { [weak self] in self?.performScheduledRerender() }
        }
    }

    private func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return nil }
        return status
    }

    private func enqueueForDelivery(_ image: CGImage) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        pendingImage = image
        pendingClear = false
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        Task { @MainActor [weak self] in self?.deliverPendingImage() }
    }

    @MainActor
    private func deliverPendingImage() {
        enum Delivery {
            case image(CGImage)
            case clear
        }

        lock.lock()
        guard isActive else {
            pendingImage = nil
            deliveryScheduled = false
            lock.unlock()
            return
        }
        let delivery: Delivery?
        if pendingClear {
            pendingClear = false
            pendingImage = nil
            delivery = .clear
        } else if let image = pendingImage {
            pendingImage = nil
            delivery = .image(image)
        } else {
            delivery = nil
        }
        lock.unlock()

        switch delivery {
        case let .image(image): onFrame(image)
        case .clear: onClear()
        case nil: break
        }

        lock.lock()
        let shouldContinue = isActive && (pendingImage != nil || pendingClear)
        if !shouldContinue { deliveryScheduled = false }
        lock.unlock()
        if shouldContinue {
            Task { @MainActor [weak self] in self?.deliverPendingImage() }
        }
    }

    private func clearCachedFrame() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        cachedPixelBuffer = nil
        lastCaptureHeartbeat = nil
        pendingImage = nil
        pendingClear = true
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()
        Task { @MainActor [weak self] in self?.deliverPendingImage() }
    }

    private func deliverFailure(_ message: String) {
        lock.lock()
        guard isActive, !failureDelivered else {
            lock.unlock()
            return
        }
        failureDelivered = true
        isActive = false
        pendingImage = nil
        lock.unlock()
        Task { @MainActor [onError] in await onError(message) }
    }
}
