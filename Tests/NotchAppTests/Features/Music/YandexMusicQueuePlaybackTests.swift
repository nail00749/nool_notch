import Foundation
import XCTest
@testable import NotchApp

final class YandexMusicQueuePlaybackTests: XCTestCase {
    func testStableQueueAndUniqueRowExecuteExactlyOneAction() {
        let request = request()
        var actions = 0
        let result = YandexMusicQueuePlaybackGate.perform(request, fresh: .loaded(request.expectedItems, partial: false), scanPartial: false,
                                                         row: request.selected, playButtonCount: 1) { actions += 1; return true }
        XCTAssertEqual(result, .played)
        XCTAssertEqual(actions, 1)
    }

    func testReorderChangedMetadataNewTrackAndPIDNeverExecuteAction() {
        let request = request()
        var actions = 0
        let changed = [request.expectedItems.reversed().map { $0 }, [item("0.1", title: "Changed", track: "1"), request.expectedItems[1]],
                       [item("0.1", track: "new"), request.expectedItems[1]], [item("0.1", pid: 999), request.expectedItems[1]]]
        for fresh in changed {
            let result = YandexMusicQueuePlaybackGate.perform(request, fresh: .loaded(fresh, partial: false), scanPartial: false,
                                                             row: request.selected, playButtonCount: 1) { actions += 1; return true }
            XCTAssertEqual(result, .queueChanged)
        }
        XCTAssertEqual(actions, 0)
    }

    func testClosedLoadingFailedAndTruncatedScanCannotExecuteAction() {
        let request = request()
        var actions = 0
        for fresh in [YandexMusicQueueState.closed, .loading, .failed("Unavailable"), .loaded(request.expectedItems, partial: false)] {
            let scanPartial: Bool
            if case .loaded = fresh { scanPartial = true } else { scanPartial = false }
            let result = YandexMusicQueuePlaybackGate.perform(request, fresh: fresh, scanPartial: scanPartial,
                                                             row: request.selected, playButtonCount: 1) { actions += 1; return true }
            XCTAssertEqual(result, .queueChanged)
        }
        XCTAssertEqual(actions, 0)
    }

    func testMissingMembershipMixedPIDAndDuplicateOccurrenceAreIneligible() {
        let first = item("0.1")
        let second = item("0.2", track: "2")
        let requests = [YandexMusicQueuePlayRequest(expectedItems: [second], selected: first),
                        .init(expectedItems: [first, item("0.2", pid: 999)], selected: first),
                        .init(expectedItems: [first, item("0.2")], selected: first),
                        .init(expectedItems: [first, first], selected: first),
                        .init(expectedItems: [item("0.1", pid: nil)], selected: item("0.1", pid: nil)),
                        .init(expectedItems: [item("0.1", pid: 0)], selected: item("0.1", pid: 0))]
        for request in requests { XCTAssertFalse(YandexMusicQueuePlaybackGate.isEligible(request)) }
    }

    func testSameNameWithDifferentURLIsUnambiguousButQuerylessDuplicateIsRejected() {
        let first = item("0.1", title: "Same", track: "1")
        let second = item("0.2", title: "Same", track: "2")
        XCTAssertTrue(YandexMusicQueuePlaybackGate.isEligible(.init(expectedItems: [first, second], selected: second)))
        let canonical = URL(string: "music-application://desktop/album/track")!
        let a = YandexMusicQueueItem(id: "0.1", title: "Same", artist: "Artist", url: canonical, originPID: 42)
        let b = YandexMusicQueueItem(id: "0.2", title: "Same", artist: "Artist", url: canonical, originPID: 42)
        XCTAssertFalse(YandexMusicQueuePlaybackGate.isEligible(.init(expectedItems: [a, b], selected: a)))
    }

    func testRowReplacementAndAmbiguousPlayControlNeverExecuteAction() {
        let request = request()
        var actions = 0
        for (row, count) in [(nil, 1), (item("0.1", title: "Changed"), 1), (request.selected, 0), (request.selected, 2)] as [(YandexMusicQueueItem?, Int)] {
            let result = YandexMusicQueuePlaybackGate.perform(request, fresh: .loaded(request.expectedItems, partial: false), scanPartial: false,
                                                             row: row, playButtonCount: count) { actions += 1; return true }
            XCTAssertEqual(result, .queueChanged)
        }
        XCTAssertEqual(actions, 0)
    }

    func testStableFortyRowDisplayCapIsAllowedButOversizedRequestRejected() {
        let items = (0..<40).map { item("0.\($0)", title: "Track \($0)", track: "\($0)") }
        let request = YandexMusicQueuePlayRequest(expectedItems: items, selected: items[12])
        XCTAssertTrue(YandexMusicQueuePlaybackGate.matches(request, fresh: .loaded(items, partial: true), scanPartial: false))
        XCTAssertFalse(YandexMusicQueuePlaybackGate.isEligible(.init(expectedItems: items + [item("0.40", track: "40")], selected: items[12])))
    }

    func testActionFailureIsReportedAndRowParserPreservesPID() {
        let request = request()
        guard case .failed = YandexMusicQueuePlaybackGate.perform(request, fresh: .loaded(request.expectedItems, partial: false), scanPartial: false,
                                                                 row: request.selected, playButtonCount: 1, action: { false }) else { return XCTFail("Expected failure") }
        let node = YandexMusicQueueNode(children: [.init(role: "AXButton", description: "Воспроизведение"),
                                                  .init(role: "AXLink", description: "Трек First", url: request.selected.url),
                                                  .init(role: "AXLink", description: "Артист Artist"),
                                                  .init(role: "AXButton", description: "Удалить из очереди")])
        XCTAssertEqual(YandexMusicQueueParser.rowItem(node, id: "0.1", originPID: 42), request.selected)
    }

    private func request() -> YandexMusicQueuePlayRequest {
        let first = item("0.1")
        return .init(expectedItems: [first, item("0.2", title: "Second", track: "2")], selected: first)
    }
    private func item(_ id: String, title: String = "First", track: String = "1", pid: Int32? = 42) -> YandexMusicQueueItem {
        .init(id: id, title: title, artist: "Artist", url: URL(string: "music-application://desktop/album/track?trackId=\(track)")!, originPID: pid)
    }
}
