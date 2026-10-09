import Combine
import Foundation

@MainActor
final class YandexMusicQueueStore: ObservableObject {
    @Published private(set) var state: YandexMusicQueueState = .idle
    @Published private(set) var pendingItemID: String?
    @Published private(set) var playbackMessage: String?
    private let source: any YandexMusicQueueReading
    private let pollNanoseconds: UInt64
    private var active = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var trackIdentity: String?

    init(source: any YandexMusicQueueReading = YandexMusicQueueReader(), pollNanoseconds: UInt64 = 5_000_000_000) {
        self.source = source
        self.pollNanoseconds = pollNanoseconds
    }

    deinit { task?.cancel(); pollTask?.cancel() }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        invalidate()
        pollTask?.cancel()
        pollTask = nil
        guard value else { state = .idle; playbackMessage = nil; return }
        refresh()
        let interval = pollNanoseconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self, self.active else { return }
                if self.task == nil { self.refresh() }
            }
        }
    }

    func updateTrack(_ snapshot: NowPlayingSnapshot?) {
        let next = snapshot.map { "\($0.id)|\($0.title)|\($0.artist)|\($0.applicationBundleIdentifier ?? "")" }
        guard trackIdentity != next else { return }
        trackIdentity = next
        invalidate()
        playbackMessage = nil
        state = .idle
        if active { refresh() }
    }

    func refresh() { request(open: false) }
    func openQueue() { request(open: true) }

    func play(_ item: YandexMusicQueueItem) {
        guard active, pendingItemID == nil,
              case .loaded(let items, _) = state, items.contains(item) else { return }
        invalidate()
        playbackMessage = nil
        pendingItemID = item.id
        let requestGeneration = generation
        let request = YandexMusicQueuePlayRequest(expectedItems: items, selected: item)
        task = Task { [weak self, source] in
            let result = await source.play(request)
            guard let self, !Task.isCancelled, self.active, self.generation == requestGeneration else { return }
            switch result {
            case .played:
                // Allow the player to publish its new queue before reading again.
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard self.active, self.generation == requestGeneration else { return }
            case .queueChanged:
                self.playbackMessage = "Очередь изменилась. Выберите трек из обновлённого списка."
            case .failed(let message):
                self.playbackMessage = message
                self.pendingItemID = nil
                self.task = nil
                return
            }
            self.pendingItemID = nil
            self.task = nil
            self.refresh()
        }
    }

    private func request(open: Bool) {
        guard active, pendingItemID == nil else { return }
        invalidate()
        let requestGeneration = generation
        if case .loaded = state {} else { state = .loading }
        task = Task { [weak self, source] in
            let result = await (open ? source.openQueue() : source.read())
            guard let self, !Task.isCancelled, self.active, self.generation == requestGeneration else { return }
            self.state = result
            self.task = nil
        }
    }

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        pendingItemID = nil
    }
}
