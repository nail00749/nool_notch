import Combine
import Foundation

@MainActor
final class MusicLyricsStore: ObservableObject {
    @Published private(set) var state: MusicLyricsState = .idle
    @Published private(set) var track: MusicLyricsTrack?
    private let client: MusicLyricsClient
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var rateLimitUntil: Date?

    init(client: MusicLyricsClient = MusicLyricsClient(), now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    deinit { task?.cancel() }

    func updateTrack(_ snapshot: NowPlayingSnapshot?) {
        let next = MusicLyricsTrack(snapshot)
        guard track != next else { return }
        cancel()
        track = next
        state = .idle
    }

    func deactivate() {
        cancel()
        if state == .loading { state = .idle }
    }

    func lookup() {
        guard let track, state != .loading else { return }
        if let rateLimitUntil, rateLimitUntil > now() {
            state = .failed(MusicLyricsFailure("Сервис временно ограничил запросы. Попробуйте позже.", retryAfter: rateLimitUntil))
            return
        }
        cancel()
        let requestGeneration = generation
        state = .loading
        task = Task { [weak self, client] in
            let result: MusicLyricsState
            do { result = try await client.lookup(track) }
            catch is CancellationError { return }
            catch let failure as MusicLyricsFailure { result = .failed(failure) }
            catch {
                guard !Task.isCancelled else { return }
                result = .failed(MusicLyricsFailure("Не удалось загрузить текст. Проверьте подключение и попробуйте снова."))
            }
            guard let self, !Task.isCancelled, self.generation == requestGeneration, self.track == track else { return }
            if case let .failed(failure) = result, let date = failure.retryAfter { self.rateLimitUntil = date }
            self.state = result
            self.task = nil
        }
    }

    private func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
