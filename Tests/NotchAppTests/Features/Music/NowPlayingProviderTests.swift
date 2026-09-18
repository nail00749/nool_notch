import Foundation
import XCTest
@testable import NotchApp

final class NowPlayingProviderTests: XCTestCase {
    @MainActor
    func testElectedTransportUsesExplicitPlayPauseAndTrackCommands() {
        let playerPath = NSObject()
        var playbackStates = [true, false]
        var receivedCommands: [UInt32] = []
        var receivedPaths: [ObjectIdentifier] = []
        var deliveries: [NowPlayingCommandDelivery] = []
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            getIsPlaying: { completion in
                completion(playbackStates.removeFirst())
                return true
            },
            sendCommand: { command, path, completion in
                receivedCommands.append(command.command)
                receivedPaths.append(ObjectIdentifier(path))
                completion(0)
                return true
            }
        )

        transport.send(.togglePlayPause) { deliveries.append($0) }
        transport.send(.togglePlayPause) { deliveries.append($0) }
        transport.send(.nextTrack) { deliveries.append($0) }
        transport.send(.previousTrack) { deliveries.append($0) }

        XCTAssertEqual(receivedCommands, [1, 0, 4, 5])
        XCTAssertEqual(
            receivedPaths,
            Array(repeating: ObjectIdentifier(playerPath), count: 4)
        )
        XCTAssertEqual(
            deliveries,
            [.delivered, .delivered, .delivered, .delivered]
        )
    }

    @MainActor
    func testToggleDoesNotSendWhenPlaybackStateLookupIsUnavailable() {
        let playerPath = NSObject()
        var sendCount = 0
        var delivery: NowPlayingCommandDelivery?
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            getIsPlaying: { _ in false },
            sendCommand: { _, _, _ in
                sendCount += 1
                return true
            }
        )

        transport.send(.togglePlayPause) { delivery = $0 }

        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(delivery, .unavailable)
    }

    @MainActor
    func testElectedTransportDoesNotSendWithoutAPlayerPath() {
        var sendCount = 0
        var delivery: NowPlayingCommandDelivery?
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(nil)
                return true
            },
            sendCommand: { _, _, _ in
                sendCount += 1
                return true
            }
        )

        transport.send(.nextTrack) { delivery = $0 }

        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(delivery, .noPlayer)
    }

    @MainActor
    func testElectedTransportReportsUnavailablePlayerLookup() {
        var delivery: NowPlayingCommandDelivery?
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { _ in false },
            sendCommand: { _, _, _ in
                XCTFail("send must not run when elected-player lookup is unavailable")
                return true
            }
        )

        transport.send(.togglePlayPause) { delivery = $0 }

        XCTAssertEqual(delivery, .unavailable)
    }

    @MainActor
    func testElectedTransportReportsMediaRemoteSendError() {
        let playerPath = NSObject()
        var delivery: NowPlayingCommandDelivery?
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            getIsPlaying: { completion in
                completion(false)
                return true
            },
            sendCommand: { _, _, completion in
                completion(7)
                return true
            }
        )

        transport.send(.previousTrack) { delivery = $0 }

        XCTAssertEqual(delivery, .rejected(7))
    }

    @MainActor
    func testElectedTransportTimesOutOnceWhenPlayerLookupNeverReplies() async {
        var lookupCompletion: ((AnyObject?) -> Void)?
        var deliveries: [NowPlayingCommandDelivery] = []
        let delivered = expectation(description: "timeout delivered")
        let transport = ElectedPlayerCommandTransport(
            timeout: 0.01,
            getElectedPlayerPath: { completion in
                lookupCompletion = completion
                return true
            },
            sendCommand: { _, _, _ in
                XCTFail("send must not run after lookup timeout")
                return true
            }
        )

        transport.send(.togglePlayPause) {
            deliveries.append($0)
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 0.2)
        lookupCompletion?(NSObject())

        XCTAssertEqual(deliveries, [.timedOut])
    }

    @MainActor
    func testElectedTransportCancellationPreventsLateLookupFromSending() {
        var lookupCompletion: ((AnyObject?) -> Void)?
        var sendCount = 0
        var deliveries: [NowPlayingCommandDelivery] = []
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                lookupCompletion = completion
                return true
            },
            sendCommand: { _, _, _ in
                sendCount += 1
                return true
            }
        )

        let request = transport.send(.nextTrack) { deliveries.append($0) }
        request.cancel()
        lookupCompletion?(NSObject())

        XCTAssertTrue(request.isFinished)
        XCTAssertEqual(sendCount, 0)
        XCTAssertTrue(deliveries.isEmpty)
    }

    @MainActor
    func testElectedTransportRetainsPlayerPathUntilSendCallback() {
        var playerPath: NSObject? = NSObject()
        weak let weakPlayerPath = playerPath
        var sendCompletion: ((UInt32) -> Void)?
        var delivery: NowPlayingCommandDelivery?
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            getIsPlaying: { completion in
                completion(false)
                return true
            },
            sendCommand: { _, _, completion in
                sendCompletion = completion
                return true
            }
        )

        _ = transport.send(.togglePlayPause) { delivery = $0 }
        playerPath = nil

        XCTAssertNotNil(weakPlayerPath)
        sendCompletion?(0)
        XCTAssertNil(weakPlayerPath)
        XCTAssertEqual(delivery, .delivered)
    }

    @MainActor
    func testElectedTransportCancellationRetainsInFlightPathUntilLateCallback() {
        var playerPath: NSObject? = NSObject()
        weak let weakPlayerPath = playerPath
        var sendCompletion: ((UInt32) -> Void)?
        var deliveries: [NowPlayingCommandDelivery] = []
        let transport = ElectedPlayerCommandTransport(
            timeout: 1,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            sendCommand: { _, _, completion in
                sendCompletion = completion
                return true
            }
        )

        let request = transport.send(.nextTrack) { deliveries.append($0) }
        playerPath = nil
        request.cancel()

        XCTAssertNotNil(weakPlayerPath)
        sendCompletion?(0)
        XCTAssertNil(weakPlayerPath)
        XCTAssertTrue(deliveries.isEmpty)
    }

    @MainActor
    func testElectedTransportSendCallbackTimesOutOnceAndIgnoresLateReply() async {
        var playerPath: NSObject? = NSObject()
        weak let weakPlayerPath = playerPath
        var sendCompletion: ((UInt32) -> Void)?
        var deliveries: [NowPlayingCommandDelivery] = []
        let delivered = expectation(description: "send timeout delivered")
        let transport = ElectedPlayerCommandTransport(
            timeout: 0.01,
            getElectedPlayerPath: { completion in
                completion(playerPath)
                return true
            },
            sendCommand: { _, _, completion in
                sendCompletion = completion
                return true
            }
        )

        _ = transport.send(.previousTrack) {
            deliveries.append($0)
            delivered.fulfill()
        }
        playerPath = nil

        await fulfillment(of: [delivered], timeout: 0.2)
        XCTAssertNotNil(weakPlayerPath)
        sendCompletion?(0)

        XCTAssertNil(weakPlayerPath)
        XCTAssertEqual(deliveries, [.timedOut])
    }

    @MainActor
    func testAccessibilityEventsCoalesceIntoOnePromptRefresh() async throws {
        var refreshCount = 0
        let relay = NowPlayingEventRelay(delayNanoseconds: 20_000_000) {
            refreshCount += 1
        }

        relay.signal()
        relay.signal()

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(refreshCount, 1)
    }

    func testPollingIntervals() {
        XCTAssertEqual(NowPlayingPollingMode.visibleMusic.interval, 2)
        XCTAssertEqual(NowPlayingPollingMode.background.interval, 30)
    }

    func testExpectedElapsedClockDriftIsSemanticallyEqualButSeekIsNot() {
        let reference = Date(timeIntervalSinceReferenceDate: 1_000)
        let original = NowPlayingSnapshot.fixture(elapsed: 10, updatedAt: reference)
        let normal = NowPlayingSnapshot.fixture(
            elapsed: 11,
            updatedAt: reference.addingTimeInterval(1)
        )
        let seek = NowPlayingSnapshot.fixture(
            elapsed: 40,
            updatedAt: reference.addingTimeInterval(1)
        )

        XCTAssertTrue(original.isSemanticallyEquivalent(to: normal))
        XCTAssertFalse(original.isSemanticallyEquivalent(to: seek))
        XCTAssertFalse(
            original.isSemanticallyEquivalent(
                to: .fixture(title: "Other Track", elapsed: 11, updatedAt: reference.addingTimeInterval(1))
            )
        )
    }

    func testPublicationPolicySuppressesClockDriftButPublishesRealChanges() {
        let reference = Date(timeIntervalSinceReferenceDate: 1_000)
        let original = NowPlayingSnapshot.fixture(elapsed: 10, updatedAt: reference)
        let normal = NowPlayingSnapshot.fixture(
            elapsed: 11,
            updatedAt: reference.addingTimeInterval(1)
        )
        let seek = NowPlayingSnapshot.fixture(
            elapsed: 40,
            updatedAt: reference.addingTimeInterval(1)
        )

        XCTAssertFalse(NowPlayingPublicationPolicy.shouldPublish(previous: original, next: normal))
        XCTAssertTrue(NowPlayingPublicationPolicy.shouldPublish(previous: original, next: seek))
        XCTAssertTrue(NowPlayingPublicationPolicy.shouldPublish(previous: nil, next: original))
        XCTAssertFalse(NowPlayingPublicationPolicy.shouldPublish(previous: nil, next: nil))
    }

    func testLateAccessibilityArtworkPreservesTrackAndPublishesChange() {
        let original = NowPlayingSnapshot.fixture()
        let artwork = Data([0x01, 0x02, 0x03])

        let updated = original.replacingArtworkData(artwork)

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.title, original.title)
        XCTAssertEqual(updated.artworkData, artwork)
        XCTAssertTrue(
            NowPlayingPublicationPolicy.shouldPublish(previous: original, next: updated)
        )
    }

    func testPausedAccessibilityFallbackIsHiddenWhenSystemNowPlayingIsEmpty() {
        let paused = NowPlayingSnapshot.fixture(playbackState: .paused)

        XCTAssertNil(NowPlayingSourcePolicy.accessibilitySnapshot(paused))
    }

    func testPlayingAccessibilityFallbackRemainsVisible() {
        let playing = NowPlayingSnapshot.fixture(playbackState: .playing)

        XCTAssertEqual(
            NowPlayingSourcePolicy.accessibilitySnapshot(playing),
            playing
        )
    }

    func testOnlyNewestMediaRemoteRequestCanApply() {
        var gate = NowPlayingRefreshGate()
        let older = gate.beginRequest()
        let newer = gate.beginRequest()

        XCTAssertFalse(gate.accepts(older))
        XCTAssertTrue(gate.accepts(newer))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(newer))
    }

    func testDiagnosticsReportActionableHealthStates() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let recent = now.addingTimeInterval(-10)
        let old = now.addingTimeInterval(-61)

        XCTAssertEqual(
            NowPlayingDiagnostics.unavailable.health(at: now),
            .playerNotFound
        )
        XCTAssertEqual(
            NowPlayingDiagnostics(
                source: .accessibility,
                applicationName: nil,
                requiresAccessibilityAccess: true,
                lastSuccessfulUpdate: nil
            ).health(at: now),
            .accessibilityRequired
        )
        XCTAssertEqual(
            NowPlayingDiagnostics(
                source: .mediaRemote,
                applicationName: "Music",
                requiresAccessibilityAccess: false,
                lastSuccessfulUpdate: recent
            ).health(at: now),
            .active
        )
        XCTAssertEqual(
            NowPlayingDiagnostics(
                source: .mediaRemote,
                applicationName: "Music",
                requiresAccessibilityAccess: false,
                lastSuccessfulUpdate: old
            ).health(at: now),
            .stale
        )
    }

    func testSuccessfulObservationRefreshesDiagnosticsTimestamp() {
        let previousUpdate = Date(timeIntervalSinceReferenceDate: 4_000)
        let observationDate = Date(timeIntervalSinceReferenceDate: 5_000)
        let previous = NowPlayingDiagnostics(
            source: .mediaRemote,
            applicationName: "Music",
            requiresAccessibilityAccess: false,
            lastSuccessfulUpdate: previousUpdate
        )

        let updated = previous.recordingObservation(
            source: .mediaRemote,
            applicationName: "Music",
            hasSnapshot: true,
            requiresAccessibilityAccess: false,
            at: observationDate
        )

        XCTAssertEqual(updated.lastSuccessfulUpdate, observationDate)
        XCTAssertEqual(updated.health(at: observationDate), .active)
    }

    @MainActor
    func testApplicationEventObserverRefreshesUntilStopped() async {
        let center = NotificationCenter()
        let launch = Notification.Name("test.player.didLaunch")
        let terminate = Notification.Name("test.player.didTerminate")
        let observer = NowPlayingApplicationEventObserver(
            notificationCenter: center,
            names: [launch, terminate]
        )
        var refreshCount = 0

        observer.start {
            refreshCount += 1
        }
        center.post(name: launch, object: nil)
        center.post(name: terminate, object: nil)
        await Task.yield()

        XCTAssertEqual(refreshCount, 2)

        observer.stop()
        center.post(name: launch, object: nil)
        await Task.yield()
        XCTAssertEqual(refreshCount, 2)
    }
}
