import XCTest
@testable import NotchApp

final class DisplayDDCTests: XCTestCase {
    func testBrightnessWritePacketIncludesAddressAndPayloadChecksum() {
        XCTAssertEqual(DisplayDDC.writePacket(value: 100), [0x84, 0x03, 0x10, 0, 0x64, 0xcc])
        let packet = DisplayDDC.writePacket(value: 0x1234)
        XCTAssertEqual(Array(packet[3...4]), [0x12, 0x34])
        XCTAssertEqual(DisplayDDC.checksum(packet, seed: 0x6e ^ 0x51), 0)
    }

    func testBrightnessReadPacket() {
        XCTAssertEqual(DisplayDDC.readPacket(), [0x82, 0x01, 0x10, 0xfd])
    }

    func testValidReplyUsesReportedMaximum() throws {
        let value = try XCTUnwrap(DisplayDDC.decode(reply(current: 128, maximum: 255)))
        XCTAssertEqual(value.current, 128)
        XCTAssertEqual(value.maximum, 255)
        XCTAssertEqual(value.normalized, 128.0 / 255, accuracy: 0.000_001)
        XCTAssertEqual(value.rawValue(for: 0.5), 128)
        XCTAssertEqual(value.rawValue(for: 1), 255)
    }

    func testSixteenBitMaximumAndNormalizedBounds() throws {
        let value = try XCTUnwrap(DisplayDDC.decode(reply(current: 700, maximum: 1000)))
        XCTAssertEqual(value.normalized, 0.7)
        XCTAssertEqual(value.rawValue(for: 0.42), 420)
        XCTAssertEqual(value.rawValue(for: -2), 0)
        XCTAssertEqual(value.rawValue(for: 2), 1000)
        XCTAssertNil(value.rawValue(for: .nan))
        XCTAssertNil(value.rawValue(for: .infinity))
    }

    func testReplyRejectsCorruptChecksumAndTruncation() {
        var packet = reply(current: 50, maximum: 100)
        packet[10] ^= 1
        XCTAssertNil(DisplayDDC.decode(packet))
        XCTAssertNil(DisplayDDC.decode(Array(packet.dropLast())))
        XCTAssertNil(DisplayDDC.decode([]))
    }

    func testReplyRejectsWrongSourceLengthOperationResultCodeAndType() {
        for (index, replacement): (Int, UInt8) in [(0, 0x51), (1, 0x87), (2, 0x03), (3, 1), (4, 0x12), (5, 1)] {
            var packet = reply(current: 50, maximum: 100)
            packet[index] = replacement
            packet[10] = DisplayDDC.checksum(packet.prefix(10), seed: 0x50)
            XCTAssertNil(DisplayDDC.decode(packet), "Accepted invalid byte at \(index)")
        }
    }

    func testReplyRejectsZeroMaximumAndCurrentAboveMaximum() {
        XCTAssertNil(DisplayDDC.decode(reply(current: 0, maximum: 0)))
        XCTAssertNil(DisplayDDC.decode(reply(current: 101, maximum: 100)))
    }

    func testMatchesOnlyUniqueFullIdentity() {
        let target = identity(serial: 123)
        let other = identity(serial: 124)
        XCTAssertEqual(DisplayDDCIdentity.uniqueMatch(for: target, candidates: [other, target],
                                                    onlineDisplays: [other, target]), 1)
    }

    func testRejectsAmbiguousRegistryAndOnlineDisplayIdentities() {
        let target = identity(serial: 123)
        XCTAssertNil(DisplayDDCIdentity.uniqueMatch(for: target, candidates: [target, target], onlineDisplays: [target]))
        XCTAssertNil(DisplayDDCIdentity.uniqueMatch(for: target, candidates: [target], onlineDisplays: [target, target]))
    }

    func testMissingSerialAndPartialIdentityNeverSelectsFirstMonitor() {
        let target = identity(serial: 0)
        XCTAssertNil(DisplayDDCIdentity.uniqueMatch(for: target, candidates: [target], onlineDisplays: [target]))
        let identified = identity(serial: 123)
        let otherProduct = DisplayDDCIdentity(vendor: 19501, product: 77, serial: 123)
        XCTAssertNil(DisplayDDCIdentity.uniqueMatch(for: identified, candidates: [otherProduct], onlineDisplays: [identified]))
    }

    func testExactEDIDCanDisambiguateButNeverFallsBackAfterMismatch() {
        let first = DisplayDDCIdentity(edidUUID: "edid-a", vendor: 1, product: 2, serial: 0)
        let second = DisplayDDCIdentity(edidUUID: "EDID-B", vendor: 1, product: 2, serial: 0)
        XCTAssertEqual(DisplayDDCIdentity.uniqueMatch(for: first, candidates: [second, first], onlineDisplays: [first, second]), 1)
        let identified = DisplayDDCIdentity(edidUUID: "edid-a", vendor: 1, product: 2, serial: 123)
        let mismatch = DisplayDDCIdentity(edidUUID: "edid-b", vendor: 1, product: 2, serial: 123)
        XCTAssertNil(DisplayDDCIdentity.uniqueMatch(for: identified, candidates: [mismatch], onlineDisplays: [identified]))
    }

    func testRegistryEDIDIsNeverComparedWithCoreGraphicsUUID() {
        let target = identity(serial: 123)
        let registry = DisplayDDCIdentity(edidUUID: "4C2D19E0-0000-0000-0321-010380772278",
                                          vendor: target.vendor, product: target.product, serial: target.serial)
        XCTAssertEqual(DisplayDDCIdentity.uniqueMatch(for: target, candidates: [registry], onlineDisplays: [target]), 0)
    }

    func testSiblingBranchMatchesOnlyItsSingleExternalProxyAndFullIdentity() {
        let target = identity(serial: 123)
        XCTAssertEqual(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                            externalProxyIDs: [42], metadata: [target], isComplete: true), target)
    }

    func testSiblingBranchIgnoresUnrelatedMetadataAndAcceptsDuplicateSameIdentity() {
        let target = identity(serial: 123)
        let unrelated = DisplayDDCIdentity(vendor: 77, product: 88, serial: 99)
        XCTAssertEqual(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                            externalProxyIDs: [42], metadata: [unrelated, target, target],
                                                            isComplete: true), target)
        XCTAssertFalse(target.hasSameFullNumericIdentity(as: unrelated))
    }

    func testSiblingBranchRejectsMultipleExternalProxiesEvenWithOneMatchingIdentity() {
        let target = identity(serial: 123)
        XCTAssertNil(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                         externalProxyIDs: [42, 43], metadata: [target], isComplete: true))
    }

    func testSiblingBranchRejectsMissingOrDifferentProxy() {
        let target = identity(serial: 123)
        for proxies: Set<UInt64> in [[], [43]] {
            XCTAssertNil(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                             externalProxyIDs: proxies, metadata: [target], isComplete: true))
        }
    }

    func testSiblingBranchRejectsMissingSerialAndConflictingMetadata() {
        for target in [identity(serial: 0), identity(serial: 123)] {
            XCTAssertNil(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                             externalProxyIDs: [42], metadata: [identity(serial: 456)],
                                                             isComplete: true))
        }
        let missing = identity(serial: 0)
        XCTAssertNil(DisplayDDCBranchAssociation.identity(for: missing, proxyID: 42,
                                                         externalProxyIDs: [42], metadata: [missing], isComplete: true))
    }

    func testSiblingBranchRejectsDifferentEDIDsWithSameNumericIdentity() {
        let first = DisplayDDCIdentity(edidUUID: "edid-a", vendor: 1, product: 2, serial: 123)
        let second = DisplayDDCIdentity(edidUUID: "edid-b", vendor: 1, product: 2, serial: 123)
        let target = DisplayDDCIdentity(vendor: 1, product: 2, serial: 123)
        XCTAssertNil(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                         externalProxyIDs: [42], metadata: [first, second], isComplete: true))
    }

    func testSiblingBranchRejectsIncompleteTraversal() {
        let target = identity(serial: 123)
        XCTAssertNil(DisplayDDCBranchAssociation.identity(for: target, proxyID: 42,
                                                         externalProxyIDs: [42], metadata: [target], isComplete: false))
    }

    func testDriverTimeoutFailsQueuedAndFutureOperationsWithoutReplacementWorkers() async {
        let executor = DisplayHardwareExecutor(timeout: 0.05)
        let started = expectation(description: "Driver started")
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            try await executor.run { _ in
                started.fulfill()
                release.wait()
                return 1
            }
        }
        // No real hardware involved: model a driver that cannot be cancelled.
        await fulfillment(of: [started], timeout: 1)
        let queued = Task { try await executor.run { _ in 2 } }
        for task in [first, queued] {
            do {
                _ = try await task.value
                XCTFail("Expected driver timeout")
            } catch {
                XCTAssertTrue(error is DisplayHardwareBrightnessError)
            }
        }
        do {
            _ = try await executor.run { _ in 3 }
            XCTFail("Circuit breaker must reject future work")
        } catch {
            XCTAssertTrue(error is DisplayHardwareBrightnessError)
        }
        release.signal()
    }

    func testQueuedMonitorGetsItsOwnExecutionTimeout() async throws {
        let watchdogs = TestDisplayWatchdogs()
        let executor = DisplayHardwareExecutor(timeout: 0.25, watchdogScheduler: { item, _ in watchdogs.record(item) })
        let firstStarted = expectation(description: "first monitor begins execution")
        let secondStarted = expectation(description: "second monitor begins execution")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal(); releaseSecond.signal(); watchdogs.clear() }
        let first = Task {
            try await executor.run { _ in
                firstStarted.fulfill()
                releaseFirst.wait()
                return 1
            }
        }
        await fulfillment(of: [firstStarted], timeout: 3)
        let second = Task {
            try await executor.run { _ in
                secondStarted.fulfill()
                releaseSecond.wait()
                return 2
            }
        }
        // Wait for a state transition, not a short sleep whose timer can be coalesced
        // beyond the executor's timeout on a utility-QoS thread.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while executor.pendingRequestCount < 2, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(executor.pendingRequestCount, 2)
        XCTAssertEqual(watchdogs.count, 1, "Queued work must not start its execution watchdog")
        releaseFirst.signal()
        let firstValue = try await first.value
        await fulfillment(of: [secondStarted], timeout: 3)
        XCTAssertEqual(watchdogs.count, 2, "The second watchdog starts with the second operation")
        watchdogs.fire(0)
        XCTAssertEqual(executor.pendingRequestCount, 1, "A late first watchdog must not cancel the second operation")
        releaseSecond.signal()
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        let nextValue = try await executor.run { _ in 3 }
        XCTAssertEqual(nextValue, 3, "A stale watchdog must not trip the circuit breaker")
    }

    private func identity(serial: UInt32) -> DisplayDDCIdentity {
        DisplayDDCIdentity(vendor: 19501, product: 57369, serial: serial)
    }

    private func reply(current: UInt16, maximum: UInt16) -> [UInt8] {
        let packet: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0,
                              UInt8(maximum >> 8), UInt8(maximum & 0xff), UInt8(current >> 8), UInt8(current & 0xff)]
        return packet + [DisplayDDC.checksum(packet, seed: 0x50)]
    }
}

private final class TestDisplayWatchdogs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DispatchWorkItem] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    func record(_ item: DispatchWorkItem) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    func fire(_ index: Int) {
        lock.lock()
        let item = items[index]
        lock.unlock()
        item.perform()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}
