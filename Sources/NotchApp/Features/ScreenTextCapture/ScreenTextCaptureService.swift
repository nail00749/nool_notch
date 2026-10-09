import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenTextCaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case noDisplay
    case invalidSelection
    case captureFailed
    case contentTimedOut
    case timedOut
    case imageTooLarge
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Разрешите NooL App запись экрана в Системных настройках → Конфиденциальность и безопасность → Запись экрана, затем перезапустите приложение."
        case .noDisplay:
            "Выбранный экран больше недоступен. Повторите выделение области."
        case .invalidSelection:
            "Не удалось определить область. Выделите её ещё раз."
        case .captureFailed:
            "Не удалось сделать снимок области. Проверьте разрешение записи экрана и повторите попытку."
        case .contentTimedOut:
            "Список экранов не был получен за 8 секунд. Повторите попытку."
        case .timedOut:
            "Снимок экрана не был получен за 12 секунд. Повторите попытку."
        case .imageTooLarge:
            "Снимок слишком большой для распознавания. Выделите область поменьше."
        case .encodingFailed:
            "Не удалось подготовить снимок для распознавания."
        }
    }
}

protocol ScreenTextCapturing: Sendable {
    func capture(_ request: ScreenTextCaptureRequest) async throws -> Data
}

struct SystemScreenTextCaptureService: ScreenTextCapturing {
    static let maximumPNGBytes = 20 * 1_024 * 1_024

    func capture(_ request: ScreenTextCaptureRequest) async throws -> Data {
        try Task.checkCancellation()
        let content = try await shareableContent().content
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }),
              abs(CGFloat(display.width) - request.displaySize.width) < 1,
              abs(CGFloat(display.height) - request.displaySize.height) < 1 else {
            throw ScreenTextCaptureError.noDisplay
        }
        let ownApplications = content.applications.filter {
            $0.processID == getpid() || $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        guard !ownApplications.isEmpty else { throw ScreenTextCaptureError.captureFailed }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = request.sourceRect
        configuration.width = request.pixelWidth
        configuration.height = request.pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true

        let gate = ScreenCaptureGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !gate.isFinished, !Task.isCancelled else {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                    guard !gate.isFinished else { return }
                    if let image {
                        do { gate.finish(.success(try Self.encodePNG(image))) }
                        catch { gate.finish(.failure(error)) }
                    } else {
                        gate.finish(.failure(ScreenTextCaptureError.captureFailed))
                    }
                }
                gate.scheduleTimeout(seconds: 12, error: ScreenTextCaptureError.timedOut)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private func shareableContent() async throws -> ShareableContentBox {
        let gate = ScreenCaptureGate<ShareableContentBox>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !gate.isFinished, !Task.isCancelled else {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                    guard !gate.isFinished else { return }
                    if let content { gate.finish(.success(ShareableContentBox(content: content))) }
                    else { gate.finish(.failure(ScreenTextCaptureError.captureFailed)) }
                }
                gate.scheduleTimeout(seconds: 8, error: ScreenTextCaptureError.contentTimedOut)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 20_000, height <= 20_000,
              Int64(width) * Int64(height) <= Int64(ScreenTextCaptureGeometry.maximumPixels) else {
            throw ScreenTextCaptureError.imageTooLarge
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenTextCaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenTextCaptureError.encodingFailed }
        guard output.length <= maximumPNGBytes else { throw ScreenTextCaptureError.imageTooLarge }
        return output as Data
    }
}

/// SCShareableContent's returned enumeration is read-only after its callback; transfer only this snapshot.
private struct ShareableContentBox: @unchecked Sendable {
    let content: SCShareableContent
}

private final class ScreenCaptureGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var timer: DispatchSourceTimer?

    var isFinished: Bool { lock.withLock { result != nil } }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let completed = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<Value, Error>) {
        let (pending, timeout) = lock.withLock { () -> (CheckedContinuation<Value, Error>?, DispatchSourceTimer?) in
            guard self.result == nil else { return (nil, nil) }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let timer = self.timer
            self.timer = nil
            return (continuation, timer)
        }
        timeout?.cancel()
        pending?.resume(with: result)
    }

    func scheduleTimeout(seconds: Double, error: Error) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.finish(.failure(error)) }
        timer.resume()
        let alreadyFinished = lock.withLock { () -> Bool in
            guard result == nil else { return true }
            self.timer = timer
            return false
        }
        if alreadyFinished { timer.cancel() }
    }
}
