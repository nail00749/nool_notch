import Foundation
import XCTest
@testable import NotchApp

final class MediaRemoteAdapterSourceTests: XCTestCase {
    func testDecoderSplitsChunkedLinesAndIgnoresMalformedJSON() {
        var decoder = MediaRemoteAdapterLineDecoder()

        XCTAssertEqual(decoder.append(Data(#"{"type":"rea"#.utf8)), [])
        let events = decoder.append(Data(
            "dy\",\"version\":1}\nnot json\n{\"type\":\"idle\"}\n{\"type\":\"nowPl".utf8
        ))
        XCTAssertEqual(events, [.ready, .idle])

        let tail = decoder.append(Data(
            #"aying","title":"Video","playing":true}"#.utf8 + [0x0A]
        ))
        guard case .nowPlaying(let payload)? = tail.first else {
            return XCTFail("expected a now-playing event")
        }
        XCTAssertEqual(payload.title, "Video")
        XCTAssertEqual(payload.playing, true)
    }

    func testDecoderDropsOversizedLineAndRecovers() {
        var decoder = MediaRemoteAdapterLineDecoder(maximumLineLength: 32)

        XCTAssertEqual(decoder.append(Data(repeating: 0x41, count: 40)), [])
        XCTAssertEqual(decoder.append(Data("AAAA\n".utf8)), [])
        XCTAssertEqual(decoder.append(Data("{\"type\":\"idle\"}\n".utf8)), [.idle])
    }

    func testDecoderTreatsUntitledNowPlayingAsIdleAndParsesCommands() {
        XCTAssertEqual(
            MediaRemoteAdapterLineDecoder.decode(line: Data(#"{"type":"nowPlaying"}"#.utf8)),
            .idle
        )
        XCTAssertEqual(
            MediaRemoteAdapterLineDecoder.decode(
                line: Data(#"{"type":"command","name":"toggle","ok":true}"#.utf8)
            ),
            .command(name: "toggle", ok: true)
        )
        XCTAssertNil(MediaRemoteAdapterLineDecoder.decode(line: Data(#"{"type":"other"}"#.utf8)))
    }

    func testSnapshotBuilderMapsBrowserPayloadAndKeepsArtworkAcrossFrames() {
        var builder = MediaRemoteAdapterSnapshotBuilder()
        let received = Date(timeIntervalSince1970: 1_000)
        let artwork = Data([1, 2, 3])
        var payload = MediaRemoteAdapterPayload(
            type: "nowPlaying",
            title: "Video",
            artist: "Channel",
            id: "42",
            duration: 600,
            elapsed: 30,
            rate: 0,
            timestamp: 990,
            playing: true,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            artworkId: "3-abc",
            artwork: artwork.base64EncodedString()
        )

        let first = builder.snapshot(from: payload, receivedAt: received)
        XCTAssertEqual(first?.title, "Video")
        XCTAssertEqual(first?.artist, "Channel")
        XCTAssertEqual(first?.applicationBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(first?.appName, "Safari")
        XCTAssertEqual(first?.playbackState, .playing)
        // A playing browser item that reports rate 0 still advances.
        XCTAssertEqual(first?.playbackRate, 1)
        XCTAssertEqual(first?.updatedAt, Date(timeIntervalSince1970: 990))
        XCTAssertEqual(first?.elapsedTime(at: received), 40)
        XCTAssertEqual(first?.artworkData, artwork)

        payload.artwork = nil
        payload.playing = false
        let second = builder.snapshot(from: payload, receivedAt: received)
        XCTAssertEqual(second?.artworkData, artwork)
        XCTAssertEqual(second?.playbackState, .paused)
        XCTAssertEqual(second?.playbackRate, 0)

        payload.artworkId = nil
        XCTAssertNil(builder.snapshot(from: payload, receivedAt: received)?.artworkData)
    }

    func testReadPolicyPrefersActiveAdapterThenInProcessThenAccessibility() {
        XCTAssertEqual(
            NowPlayingReadPolicy.path(adapterState: .active, bridgeIsAvailable: true),
            .adapter
        )
        XCTAssertEqual(
            NowPlayingReadPolicy.path(adapterState: .starting, bridgeIsAvailable: true),
            .inProcessMediaRemote
        )
        XCTAssertEqual(
            NowPlayingReadPolicy.path(adapterState: .unavailable, bridgeIsAvailable: true),
            .inProcessMediaRemote
        )
        XCTAssertEqual(
            NowPlayingReadPolicy.path(adapterState: .unavailable, bridgeIsAvailable: false),
            .accessibility
        )
    }

    @MainActor
    func testSourcePublishesSnapshotsAndRoutesCommandsToProcess() async throws {
        let process = FakeAdapterProcess()
        let source = MediaRemoteAdapterSource(makeProcess: { process })
        var published: [NowPlayingSnapshot?] = []
        source.onSnapshotChange = { published.append($0) }

        XCTAssertFalse(source.send(.togglePlayPause))
        source.start()
        XCTAssertEqual(source.state, .starting)

        process.emit(#"{"type":"ready","version":1}"# + "\n")
        try await waitUntil { source.state == .active }
        process.emit(#"{"type":"nowPlaying","title":"Video","playing":true}"# + "\n")
        try await waitUntil { source.snapshot?.title == "Video" }

        XCTAssertTrue(source.send(.togglePlayPause))
        XCTAssertTrue(source.send(.nextTrack))
        XCTAssertTrue(source.send(.previousTrack))
        XCTAssertTrue(source.send(.seek(to: 12.5)))
        source.requestRefresh()
        XCTAssertEqual(
            process.writtenLines,
            ["toggle", "next", "previous", "seek 12.500", "refresh"]
        )

        process.emit(#"{"type":"idle"}"# + "\n")
        try await waitUntil { source.snapshot == nil }
        XCTAssertEqual(published.map { $0?.title }, ["Video", nil])

        source.stop()
        XCTAssertEqual(source.state, .stopped)
        XCTAssertTrue(process.didTerminate)
    }

    @MainActor
    func testSourceRestartsWithBackoffAndGivesUpAfterRepeatedFailures() async throws {
        var processes: [FakeAdapterProcess] = []
        let delays = DelayRecorder()
        let source = MediaRemoteAdapterSource(
            makeProcess: {
                let process = FakeAdapterProcess()
                processes.append(process)
                return process
            },
            sleep: { await delays.record($0) }
        )
        source.start()
        processes[0].emit(#"{"type":"ready"}"# + "\n")
        try await waitUntil { source.state == .active }

        // A crash after ready restarts; ready again resets the failure count.
        processes[0].exit()
        try await waitUntil { processes.count == 2 }
        processes[1].emit(#"{"type":"ready"}"# + "\n")
        try await waitUntil { source.state == .active }

        for index in 1...MediaRemoteAdapterSource.maximumFailuresBeforeReady {
            processes[index].exit()
            try await waitUntil { processes.count == index + 2 }
        }
        processes.last?.exit()
        try await waitUntil { source.state == .unavailable }

        let recorded = await delays.values
        XCTAssertEqual(recorded, [1, 1, 2, 4, 8])
        XCTAssertEqual(processes.count, MediaRemoteAdapterSource.maximumFailuresBeforeReady + 2)
    }

    @MainActor
    func testSourceIsUnavailableWhenProcessCannotLaunch() {
        let process = FakeAdapterProcess()
        process.launchError = MediaRemoteAdapterLaunchError.hostMissing
        var launches = 0
        let source = MediaRemoteAdapterSource(makeProcess: {
            launches += 1
            return process
        })

        source.start()

        XCTAssertEqual(source.state, .unavailable)
        XCTAssertEqual(launches, 1)
        XCTAssertFalse(source.send(.togglePlayPause))
    }

    @MainActor
    func testAdapterReportingUnavailableStopsWithoutRestart() async throws {
        var launches = 0
        let process = FakeAdapterProcess()
        let source = MediaRemoteAdapterSource(
            makeProcess: {
                launches += 1
                return process
            },
            sleep: { _ in }
        )
        source.start()
        process.emit(#"{"type":"unavailable"}"# + "\n")
        try await waitUntil { source.state == .unavailable }
        process.exit()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(source.state, .unavailable)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(process.didTerminate)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            if Date() > deadline {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}

private final class FakeAdapterProcess: MediaRemoteAdapterProcess, @unchecked Sendable {
    var launchError: Error?
    private(set) var writtenLines: [String] = []
    private(set) var didTerminate = false
    private var onOutput: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable () -> Void)?

    func launch(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        if let launchError { throw launchError }
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func write(line: String) {
        writtenLines.append(line)
    }

    func terminate() {
        didTerminate = true
    }

    func emit(_ text: String) {
        onOutput?(Data(text.utf8))
    }

    func exit() {
        onExit?()
    }
}
