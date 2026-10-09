import Foundation

/// Owns one in-memory screenshot request. A cancelled request cannot publish a late image.
@MainActor
final class ScreenTextCaptureSession {
    private let service: any ScreenTextCapturing
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var isActive: Bool { task != nil }

    init(service: any ScreenTextCapturing = SystemScreenTextCaptureService()) {
        self.service = service
    }

    func capture(_ request: ScreenTextCaptureRequest,
                 completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        cancel()
        let token = UUID()
        generation = token
        let service = self.service
        task = Task { @MainActor [weak self] in
            defer {
                if let self, self.generation == token { self.task = nil }
            }
            do {
                let data = try await service.capture(request)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                completion(.success(data))
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
