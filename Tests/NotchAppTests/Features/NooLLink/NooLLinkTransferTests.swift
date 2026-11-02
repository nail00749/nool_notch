import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class NooLLinkTransferTests: XCTestCase {
    func testExplicitTransferWaitsForMatchingSavedAcknowledgement() async throws {
        let queue = NooLLinkTransferQueue()
        let envelope = makeEnvelope()
        let delivery = Task { try await queue.deliver(envelope) }
        await waitForPending(queue)
        XCTAssertEqual(queue.pending?.id, envelope.id)
        XCTAssertFalse(queue.acknowledge(.init(id: UUID().uuidString, success: true)))
        XCTAssertNotNil(queue.pending)
        XCTAssertTrue(queue.acknowledge(.init(id: envelope.id, success: true)))
        try await delivery.value
        XCTAssertNil(queue.pending)
        XCTAssertFalse(queue.acknowledge(.init(id: envelope.id, success: true)))
    }

    func testReceiverFailureAndRevocationFailDelivery() async {
        for acknowledgeFailure in [true, false] {
            let queue = NooLLinkTransferQueue()
            let envelope = makeEnvelope()
            let delivery = Task { try await queue.deliver(envelope) }
            await waitForPending(queue)
            if acknowledgeFailure { queue.acknowledge(.init(id: envelope.id, success: false)) }
            else { queue.cancel(NooLLinkTransferError.unavailable) }
            do { try await delivery.value; XCTFail("Unconfirmed delivery must fail") }
            catch { XCTAssertNil(queue.pending) }
        }
    }

    func testTransferTimeoutReleasesPendingPayload() async {
        let queue = NooLLinkTransferQueue()
        do {
            try await queue.deliver(makeEnvelope(), timeout: .milliseconds(10))
            XCTFail("A missing acknowledgement must time out")
        } catch NooLLinkTransferError.timedOut {
            XCTAssertNil(queue.pending)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationReleasesPendingPayload() async {
        let queue = NooLLinkTransferQueue()
        let delivery = Task { try await queue.deliver(makeEnvelope()) }
        await waitForPending(queue)
        delivery.cancel()
        do { try await delivery.value; XCTFail("Cancelled delivery must fail") }
        catch is CancellationError { XCTAssertNil(queue.pending) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testBusyQueueDoesNotReplaceUnacknowledgedFiles() async throws {
        let queue = NooLLinkTransferQueue()
        let first = makeEnvelope()
        let delivery = Task { try await queue.deliver(first) }
        await waitForPending(queue)
        do { try await queue.deliver(makeEnvelope()); XCTFail("Queue must remain bounded") }
        catch NooLLinkTransferError.busy { XCTAssertEqual(queue.pending?.id, first.id) }
        queue.acknowledge(.init(id: first.id, success: true))
        try await delivery.value
    }

    private func makeEnvelope() -> NooLLinkEnvelope {
        NooLLinkEnvelope(id: UUID().uuidString, originDeviceID: UUID().uuidString,
                         createdAt: ISO8601DateFormatter().string(from: Date()), kind: "files",
                         files: [.init(name: "report.txt", dataBase64: Data("report".utf8).base64EncodedString())])
    }

    private func waitForPending(_ queue: NooLLinkTransferQueue) async {
        for _ in 0..<1_000 {
            if queue.pending != nil { return }
            await Task.yield()
        }
        XCTFail("Transfer did not enter the queue")
    }
}
