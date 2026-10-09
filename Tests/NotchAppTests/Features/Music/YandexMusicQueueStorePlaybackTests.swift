import XCTest
@testable import NotchApp

@MainActor
final class YandexMusicQueueStorePlaybackTests: XCTestCase {
    private var item: YandexMusicQueueItem {
        .init(id: "0.1", title: "Synthetic track", artist: "Example",
              url: URL(string: "music-application://desktop/album/track?trackId=1")!, originPID: 123)
    }

    func testOnlyVisibleCurrentRowsCanPlayAndRepeatedClicksAreIgnored() async {
        let source = PlaybackStoreSource(items: [item])
        let store = YandexMusicQueueStore(source: source)
        store.play(item)
        let initialCount = await source.playCount
        XCTAssertEqual(initialCount, 0)
        store.setActive(true)
        await waitUntil { if case .loaded = store.state { return true }; return false }
        let absent = YandexMusicQueueItem(id: "absent", title: "Other", artist: "Example", url: item.url, originPID: 123)
        store.play(absent)
        XCTAssertNil(store.pendingItemID)
        store.play(item)
        store.play(item)
        await waitUntil { await source.playCount == 1 }
        XCTAssertEqual(store.pendingItemID, item.id)
        store.refresh()
        XCTAssertEqual(store.pendingItemID, item.id)
        store.setActive(false)
        await source.finish(.failed("late failure"))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.playbackMessage)
        XCTAssertNil(store.pendingItemID)
    }

    func testChangedQueueShowsExplanationRefreshesAndDoesNotRetryPlayback() async {
        let source = PlaybackStoreSource(items: [item])
        let store = YandexMusicQueueStore(source: source)
        store.setActive(true)
        await waitUntil { if case .loaded = store.state { return true }; return false }
        store.play(item)
        await waitUntil { await source.playCount == 1 }
        await source.finish(.queueChanged)
        await waitUntil { store.playbackMessage != nil && store.pendingItemID == nil }
        await waitUntil { await source.readCount == 2 }
        XCTAssertTrue(store.playbackMessage?.contains("Очередь изменилась") == true)
        let count = await source.playCount
        XCTAssertEqual(count, 1)
        store.setActive(false)
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<300 { if await predicate() { return }; await Task.yield() }
        XCTFail("Expected asynchronous state")
    }
}

private actor PlaybackStoreSource: YandexMusicQueueReading {
    let items: [YandexMusicQueueItem]
    private(set) var playCount = 0
    private(set) var readCount = 0
    private var continuation: CheckedContinuation<YandexMusicQueuePlayResult, Never>?
    init(items: [YandexMusicQueueItem]) { self.items = items }
    func read() async -> YandexMusicQueueState {
        readCount += 1
        return .loaded(items, partial: false)
    }
    func openQueue() async -> YandexMusicQueueState { .closed }
    func play(_ request: YandexMusicQueuePlayRequest) async -> YandexMusicQueuePlayResult {
        playCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: YandexMusicQueuePlayResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
