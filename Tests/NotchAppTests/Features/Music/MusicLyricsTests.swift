import Foundation
import XCTest
@testable import NotchApp

final class MusicLyricsTests: XCTestCase {
    func testLRCOffsetsMultipleTimesStableOrderingAndPlainFallback() throws {
        let document = try MusicLyricsParser.document(plain: nil, synced: "[offset:500]\n[00:02.50][00:01.50]repeat\n[00:01.50]second\n[00:99.00]invalid\n[00:00.10]intro")
        XCTAssertEqual(document.timedLines.map(\.time), [0, 1, 1, 2])
        XCTAssertEqual(document.timedLines.map(\.text), ["intro", "repeat", "second", "repeat"])
        XCTAssertEqual(document.activeLineIndex(at: 1), 2)
        XCTAssertNil(document.activeLineIndex(at: -.infinity))
        XCTAssertEqual(document.plainText, "intro\nrepeat\nsecond\nrepeat")
    }

    func testNegativeOffsetDelaysAndTimestampInTextIsPreserved() throws {
        let document = try MusicLyricsParser.document(plain: nil, synced: "[offset:-1000]\n[00:02.00]literal [00:07.00] text")
        XCTAssertEqual(document.timedLines.count, 1)
        XCTAssertEqual(document.timedLines.first?.time, 3)
        XCTAssertEqual(document.timedLines.first?.text, "literal [00:07.00] text")
    }

    func testPlainLyricsAndParserBounds() throws {
        let document = try MusicLyricsParser.document(plain: "  sample\ntext  ", synced: "[ar:metadata]")
        XCTAssertEqual(document.plainText, "sample\ntext")
        XCTAssertTrue(document.timedLines.isEmpty)
        XCTAssertThrowsError(try MusicLyricsParser.document(plain: String(repeating: "x", count: 100_001), synced: nil))
        XCTAssertThrowsError(try MusicLyricsParser.document(plain: nil, synced: String(repeating: "\n", count: 2_001)))
    }

    func testRequestEncodingAndLoadedResponse() async throws {
        let client = MusicLyricsClient(transport: { request in
            XCTAssertEqual(request.url?.host, "lrclib.net")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.timeoutInterval, 12)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "track_name" }?.value, "Track & ?")
            XCTAssertEqual(query.first { $0.name == "artist_name" }?.value, "Artist")
            return MusicLyricsHTTPResponse(data: Data(#"{"plainLyrics":"sample","syncedLyrics":null,"instrumental":false}"#.utf8), statusCode: 200, retryAfter: nil)
        })
        let result = try await client.lookup(track("Track & ?"))
        XCTAssertEqual(result, .loaded(MusicLyricsDocument(plainText: "sample", timedLines: [])))
    }

    func testNotFoundInstrumentalMalformedAndSizeLimit() async throws {
        let missing = MusicLyricsClient(transport: { _ in MusicLyricsHTTPResponse(data: Data(), statusCode: 404, retryAfter: nil) })
        let missingResult = try await missing.lookup(track())
        XCTAssertEqual(missingResult, .notFound)
        let instrumental = MusicLyricsClient(transport: { _ in MusicLyricsHTTPResponse(data: Data(#"{"instrumental":true}"#.utf8), statusCode: 200, retryAfter: nil) })
        let instrumentalResult = try await instrumental.lookup(track())
        XCTAssertEqual(instrumentalResult, .instrumental)
        for data in [Data("invalid".utf8), Data(repeating: 0, count: MusicLyricsClient.maximumResponseBytes + 1)] {
            let client = MusicLyricsClient(transport: { _ in MusicLyricsHTTPResponse(data: data, statusCode: 200, retryAfter: nil) })
            do { _ = try await client.lookup(track()); XCTFail("Expected invalid response rejection") }
            catch { XCTAssertTrue(error is MusicLyricsFailure) }
        }
    }

    func testRateLimitSecondsAndHTTPDate() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for (header, expected) in [("30", now.addingTimeInterval(30)), ("Thu, 01 Jan 1970 00:20:00 GMT", Date(timeIntervalSince1970: 1_200))] {
            let client = MusicLyricsClient(transport: { _ in MusicLyricsHTTPResponse(data: Data(), statusCode: 429, retryAfter: header) }, now: { now })
            do { _ = try await client.lookup(track()); XCTFail("Expected rate limit") }
            catch let failure as MusicLyricsFailure { XCTAssertEqual(failure.retryAfter, expected) }
        }
    }

    @MainActor
    func testExplicitLookupTrackReplacementAndDeactivateRejectStaleCompletion() async throws {
        let transport = LyricsControlledTransport()
        let store = MusicLyricsStore(client: MusicLyricsClient(transport: { request in await transport.send(request) }))
        store.updateTrack(snapshot("First"))
        await Task.yield()
        let initialCount = await transport.count
        XCTAssertEqual(initialCount, 0)
        store.lookup()
        await waitForRequests(transport, count: 1)
        store.updateTrack(snapshot("Second"))
        await transport.finish(index: 0, text: "stale")
        await Task.yield()
        XCTAssertEqual(store.state, .idle)
        store.lookup()
        await waitForRequests(transport, count: 2)
        store.deactivate()
        await transport.finish(index: 1, text: "hidden")
        await Task.yield()
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.track?.title, "Second")
    }

    @MainActor
    func testLoadedStateSurvivesPositionUpdatesAndDeactivation() async throws {
        let store = MusicLyricsStore(client: MusicLyricsClient(transport: { _ in MusicLyricsHTTPResponse(data: Data(#"{"plainLyrics":"sample"}"#.utf8), statusCode: 200, retryAfter: nil) }))
        store.updateTrack(snapshot())
        store.lookup()
        for _ in 0..<100 { if store.state != .loading { break }; await Task.yield() }
        guard case .loaded = store.state else { return XCTFail("Expected loaded") }
        let loaded = store.state
        store.updateTrack(snapshot(elapsed: 20))
        store.deactivate()
        XCTAssertEqual(store.state, loaded)
        store.updateTrack(nil)
        XCTAssertEqual(store.state, .idle)
    }

    @MainActor
    func testRateLimitPreventsManualRetryAcrossTrackChange() async throws {
        let transport = LyricsControlledTransport()
        let now = Date(timeIntervalSince1970: 1_000)
        let store = MusicLyricsStore(client: MusicLyricsClient(transport: { request in await transport.send(request) }, now: { now }), now: { now })
        store.updateTrack(snapshot())
        store.lookup()
        await waitForRequests(transport, count: 1)
        await transport.finishRateLimited(index: 0)
        for _ in 0..<100 { if store.state != .loading { break }; await Task.yield() }
        store.updateTrack(snapshot("Other"))
        store.lookup()
        let count = await transport.count
        XCTAssertEqual(count, 1)
        guard case let .failed(failure) = store.state else { return XCTFail("Expected rate limit") }
        XCTAssertEqual(failure.retryAfter, now.addingTimeInterval(60))
    }

    @MainActor
    private func waitForRequests(_ transport: LyricsControlledTransport, count: Int) async {
        for _ in 0..<1_000 { if await transport.count >= count { return }; await Task.yield() }
        XCTFail("Request was not started")
    }

    private func track(_ title: String = "Track") -> MusicLyricsTrack { MusicLyricsTrack(snapshot(title))! }
    private func snapshot(_ title: String = "Track", elapsed: Double = 0) -> NowPlayingSnapshot {
        NowPlayingSnapshot(id: title, title: title, artist: "Artist", album: "Album", appName: "Player", applicationBundleIdentifier: "test.player", artworkData: nil, duration: 180, elapsedTime: elapsed, playbackRate: 1, playbackState: .playing, updatedAt: Date())
    }
}

private actor LyricsControlledTransport {
    var count: Int { continuations.count }
    private var continuations: [CheckedContinuation<MusicLyricsHTTPResponse, Never>] = []
    func send(_ request: URLRequest) async -> MusicLyricsHTTPResponse {
        await withCheckedContinuation { continuations.append($0) }
    }
    func finish(index: Int, text: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["plainLyrics": text])
        continuations[index].resume(returning: MusicLyricsHTTPResponse(data: data, statusCode: 200, retryAfter: nil))
    }
    func finishRateLimited(index: Int) {
        continuations[index].resume(returning: MusicLyricsHTTPResponse(data: Data(), statusCode: 429, retryAfter: "60"))
    }
}
