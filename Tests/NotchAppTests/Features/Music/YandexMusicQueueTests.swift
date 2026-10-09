import Foundation
import XCTest
@testable import NotchApp

final class YandexMusicQueueTests: XCTestCase {
    func testUpcomingBoundaryExcludesHistoryAndCurrentPreservesDuplicateOccurrences() {
        let root = overlay([row("History", id: "1"), .init(role: "AXStaticText", value: "Сейчас играет из плейлиста"), row("Current", id: "2", removable: false), heading, row("Next", id: "3"), row("Next", id: "3")])
        guard case let .loaded(items, partial) = YandexMusicQueueParser.parse(root) else { return XCTFail("Expected queue") }
        XCTAssertEqual(items.map(\.title), ["Next", "Next"])
        XCTAssertEqual(items.map(\.artist), ["Example Artist", "Example Artist"])
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertFalse(partial)
    }

    func testOverlayRequiredAndPlaylistLinksNeverBecomeQueue() {
        let library = YandexMusicQueueNode(children: [heading, row("Library", id: "3")])
        XCTAssertEqual(YandexMusicQueueParser.parse(library), .closed)
        let closed = YandexMusicQueueNode(children: [.init(role: "AXButton", description: "Закрыть"), .init(role: "AXCheckBox", description: "Очередь воспроизведения", value: "0"), heading, row("Library", id: "3")])
        XCTAssertEqual(YandexMusicQueueParser.parse(closed), .closed)
        guard case .failed = YandexMusicQueueParser.parse(overlay([row("History", id: "1")])) else { return XCTFail("Missing boundary must not infer upcoming") }
    }

    func testLimitAndPartialMetadataAreVisible() {
        let state = YandexMusicQueueParser.parse(overlay([heading] + (0..<45).map { row("Track \($0)", id: "\($0)") }))
        guard case let .loaded(items, partial) = state else { return XCTFail("Expected queue") }
        XCTAssertEqual(items.count, 40)
        XCTAssertTrue(partial)
        XCTAssertEqual(YandexMusicQueueParser.parse(overlay([heading]), partial: true), .loaded([], partial: true))
    }

    func testRejectsForeignURLsAmbiguousRowsAndNonTracks() {
        var ambiguous = row("Ambiguous", id: "1")
        ambiguous.children.append(.init(role: "AXLink", description: "Трек Other", url: URL(string: "music-application://desktop/album/track?trackId=2")))
        var foreign = row("Foreign", id: "3")
        foreign.children[1].url = URL(string: "https://example.test/album/track?trackId=3")
        XCTAssertEqual(YandexMusicQueueParser.parse(overlay([heading, ambiguous, foreign])), .loaded([], partial: false))
    }

    func testNestedRemoveControlUsesNearestSemanticRow() {
        var nested = row("Nested", id: "4")
        let remove = nested.children.removeLast()
        nested.children.append(.init(children: [remove]))
        let wrapper = YandexMusicQueueNode(children: [nested])
        guard case let .loaded(items, _) = YandexMusicQueueParser.parse(overlay([heading, wrapper])) else { return XCTFail("Expected queue") }
        XCTAssertEqual(items.map(\.title), ["Nested"])
        XCTAssertTrue(items[0].id.hasSuffix(".0"))
    }

    func testCanonicalTrackURLWithoutQueryIsAcceptedForDisplay() {
        var canonical = row("Canonical", id: "4")
        canonical.children[1].url = URL(string: "music-application://desktop/album/track")
        guard case let .loaded(items, _) = YandexMusicQueueParser.parse(overlay([heading, canonical])) else { return XCTFail("Expected queue") }
        XCTAssertEqual(items.map(\.title), ["Canonical"])
    }

    func testNestedOverlayControlsSelectContainerIncludingUpcomingRows() {
        let controls = YandexMusicQueueNode(children: [.init(children: [.init(role: "AXButton", description: "Закрыть")]), .init(children: [.init(role: "AXCheckBox", description: "Очередь воспроизведения", value: "1")])])
        let rows = YandexMusicQueueNode(children: [heading, row("Wrapped", id: "4")])
        let root = YandexMusicQueueNode(children: [.init(children: [controls, rows])])
        guard case let .loaded(items, _) = YandexMusicQueueParser.parse(root) else { return XCTFail("Expected queue") }
        XCTAssertEqual(items.map(\.title), ["Wrapped"])
    }

    @MainActor
    func testInactiveMakesNoRequestsAndLateResultCannotRestoreHiddenQueue() async {
        let source = ControlledQueueSource()
        let store = YandexMusicQueueStore(source: source)
        store.refresh()
        store.openQueue()
        await Task.yield()
        let count = await source.count
        XCTAssertEqual(count, 0)
        store.setActive(true)
        await wait(source, count: 1)
        store.setActive(false)
        await source.finish(0, .loaded([], partial: false))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .idle)
    }

    @MainActor
    func testRefreshKeepsLoadedQueueAndTrackChangesRejectStaleResult() async {
        let source = ControlledQueueSource()
        let store = YandexMusicQueueStore(source: source)
        store.updateTrack(snapshot("First"))
        store.setActive(true)
        await wait(source, count: 1)
        await source.finish(0, .loaded([], partial: false))
        for _ in 0..<30 { if store.state != .loading { break }; await Task.yield() }
        store.refresh()
        XCTAssertEqual(store.state, .loaded([], partial: false))
        await wait(source, count: 2)
        store.updateTrack(snapshot("First", elapsed: 100))
        let count = await source.count
        XCTAssertEqual(count, 2)
        store.updateTrack(snapshot("Second"))
        await wait(source, count: 3)
        await source.finish(1, .failed("stale"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .loading)
        await source.finish(2, .closed)
        for _ in 0..<30 { if store.state != .loading { break }; await Task.yield() }
        XCTAssertEqual(store.state, .closed)
        store.setActive(false)
    }

    private var heading: YandexMusicQueueNode { .init(role: "AXStaticText", value: "Далее в очереди") }
    private func overlay(_ rows: [YandexMusicQueueNode]) -> YandexMusicQueueNode {
        .init(children: [.init(role: "AXButton", description: "Закрыть"), .init(role: "AXCheckBox", description: "Очередь воспроизведения", value: "1")] + rows)
    }
    private func row(_ title: String, id: String, removable: Bool = true) -> YandexMusicQueueNode {
        .init(children: [.init(role: "AXButton", description: "Воспроизведение"), .init(role: "AXLink", description: "Трек \(title) ", url: URL(string: "music-application://desktop/album/track?albumId=10&trackId=\(id)")), .init(role: "AXLink", description: "Артист Example Artist")] + (removable ? [.init(role: "AXButton", description: "Удалить из очереди")] : []))
    }
    private func snapshot(_ title: String, elapsed: Double = 0) -> NowPlayingSnapshot {
        .init(id: title, title: title, artist: "Artist", album: nil, appName: "Yandex", applicationBundleIdentifier: YandexMusicQueueReader.bundleIdentifier, artworkData: nil, duration: 200, elapsedTime: elapsed, playbackRate: 1, playbackState: .playing, updatedAt: Date())
    }
    @MainActor private func wait(_ source: ControlledQueueSource, count: Int) async {
        for _ in 0..<200 { if await source.count >= count { return }; await Task.yield() }
        XCTFail("Request did not start")
    }
}

private actor ControlledQueueSource: YandexMusicQueueReading {
    private var requests: [CheckedContinuation<YandexMusicQueueState, Never>] = []
    var count: Int { requests.count }
    func read() async -> YandexMusicQueueState {
        await withCheckedContinuation { requests.append($0) }
    }
    func openQueue() async -> YandexMusicQueueState { await read() }
    func finish(_ index: Int, _ state: YandexMusicQueueState) { requests[index].resume(returning: state) }
}
